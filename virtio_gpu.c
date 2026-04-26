/* virtio_gpu.c — legacy virtio-mmio virtio-gpu driver with Lua bindings */

#include <stdint.h>
#include <stddef.h>
#include <string.h>
#include <stdio.h>

#include "lua.h"
#include "lauxlib.h"

#define GPU_BASE               0x10008000UL

#define PAGE_SIZE              4096
#define QUEUE_SIZE             16

#define FB_MAX_WIDTH           1280
#define FB_MAX_HEIGHT          800
#define FB_MAX_SIZE            (FB_MAX_WIDTH * FB_MAX_HEIGHT * 4)

/* virtio-mmio legacy register offsets */
#define MMIO_MAGIC             0x000
#define MMIO_VERSION           0x004
#define MMIO_DEVICE_ID         0x008
#define MMIO_VENDOR_ID         0x00C
#define MMIO_HOST_FEATURES     0x010
#define MMIO_HOST_FEATURES_SEL 0x014
#define MMIO_GUEST_FEATURES    0x020
#define MMIO_GUEST_FEATURES_SEL 0x024
#define MMIO_GUEST_PAGE_SIZE   0x028
#define MMIO_QUEUE_SEL         0x030
#define MMIO_QUEUE_NUM_MAX     0x034
#define MMIO_QUEUE_NUM         0x038
#define MMIO_QUEUE_ALIGN       0x03C
#define MMIO_QUEUE_PFN         0x040
#define MMIO_QUEUE_NOTIFY      0x050
#define MMIO_INTERRUPT_STATUS  0x060
#define MMIO_INTERRUPT_ACK     0x064
#define MMIO_STATUS            0x070

/* status bits */
#define STATUS_ACK             0x01
#define STATUS_DRIVER          0x02
#define STATUS_DRIVER_OK       0x04
#define STATUS_FEATURES_OK     0x08

/* virtqueue descriptor flags */
#define VRING_DESC_F_NEXT      0x1
#define VRING_DESC_F_WRITE     0x2

/* virtio-gpu command IDs */
#define VIRTIO_GPU_CMD_GET_DISPLAY_INFO        0x0100
#define VIRTIO_GPU_CMD_RESOURCE_CREATE_2D      0x0101
#define VIRTIO_GPU_CMD_SET_SCANOUT             0x0103
#define VIRTIO_GPU_CMD_RESOURCE_FLUSH          0x0104
#define VIRTIO_GPU_CMD_TRANSFER_TO_HOST_2D     0x0105
#define VIRTIO_GPU_CMD_RESOURCE_ATTACH_BACKING 0x0106

/* virtio-gpu response IDs */
#define VIRTIO_GPU_RESP_OK_NODATA              0x1100
#define VIRTIO_GPU_RESP_OK_DISPLAY_INFO        0x1101

/* pixel format */
#define VIRTIO_GPU_FORMAT_R8G8B8A8_UNORM       67

typedef struct {
    uint64_t addr;
    uint32_t len;
    uint16_t flags;
    uint16_t next;
} __attribute__((packed)) VirtqDesc;

typedef struct {
    uint16_t flags;
    uint16_t idx;
    uint16_t ring[QUEUE_SIZE];
} __attribute__((packed)) VirtqAvail;

typedef struct {
    uint32_t id;
    uint32_t len;
} __attribute__((packed)) VirtqUsedElem;

typedef struct {
    uint16_t flags;
    uint16_t idx;
    VirtqUsedElem ring[QUEUE_SIZE];
} __attribute__((packed)) VirtqUsed;

typedef struct {
    uint32_t type;
    uint32_t flags;
    uint64_t fence_id;
    uint32_t ctx_id;
    uint32_t padding;
} __attribute__((packed)) GpuCtrlHdr;

typedef struct {
    uint32_t x;
    uint32_t y;
    uint32_t width;
    uint32_t height;
} __attribute__((packed)) GpuRect;

typedef struct {
    GpuRect  r;
    uint32_t enabled;
    uint32_t flags;
} __attribute__((packed)) GpuDisplayOne;

typedef struct {
    GpuCtrlHdr   hdr;
    GpuDisplayOne pmodes[16];
} __attribute__((packed)) GpuRespDisplayInfo;

typedef struct {
    GpuCtrlHdr hdr;
    uint32_t   resource_id;
    uint32_t   format;
    uint32_t   width;
    uint32_t   height;
} __attribute__((packed)) GpuResourceCreate2d;

typedef struct {
    uint64_t addr;
    uint32_t length;
    uint32_t padding;
} __attribute__((packed)) GpuMemEntry;

typedef struct {
    GpuCtrlHdr hdr;
    uint32_t   resource_id;
    uint32_t   nr_entries;
    GpuMemEntry entry;
} __attribute__((packed)) GpuResourceAttachBacking;

typedef struct {
    GpuCtrlHdr hdr;
    GpuRect    r;
    uint32_t   scanout_id;
    uint32_t   resource_id;
} __attribute__((packed)) GpuSetScanout;

typedef struct {
    GpuCtrlHdr hdr;
    GpuRect    r;
    uint64_t   offset;
    uint32_t   resource_id;
    uint32_t   padding;
} __attribute__((packed)) GpuTransferToHost2d;

typedef struct {
    GpuCtrlHdr hdr;
    GpuRect    r;
    uint32_t   resource_id;
    uint32_t   padding;
} __attribute__((packed)) GpuResourceFlush;

/* MMIO helpers */
static inline uint32_t mmio_read32(uint32_t off) {
    return *(volatile uint32_t *)(GPU_BASE + off);
}

static inline void mmio_write32(uint32_t off, uint32_t val) {
    *(volatile uint32_t *)(GPU_BASE + off) = val;
}

/* Queue memory: page 0 = desc + avail, page 1 = used */
static uint8_t gpu_queue_mem[PAGE_SIZE * 2] __attribute__((aligned(PAGE_SIZE)));
static uint8_t framebuffer[FB_MAX_SIZE] __attribute__((aligned(PAGE_SIZE)));

static uint32_t fb_width  = FB_MAX_WIDTH;
static uint32_t fb_height = FB_MAX_HEIGHT;
static int gpu_ready = 0;

static inline VirtqDesc *vq_desc(void) {
    return (VirtqDesc *)(gpu_queue_mem + 0);
}

static inline VirtqAvail *vq_avail(void) {
    return (VirtqAvail *)(gpu_queue_mem + sizeof(VirtqDesc) * QUEUE_SIZE);
}

static inline VirtqUsed *vq_used(void) {
    return (VirtqUsed *)(gpu_queue_mem + PAGE_SIZE);
}

static inline uint32_t fb_bytes(void) {
    return fb_width * fb_height * 4;
}

static void gpu_queue_reset(void) {
    memset(gpu_queue_mem, 0, sizeof(gpu_queue_mem));
}

typedef struct {
    void *ptr;
    uint32_t len;
    uint16_t flags;
} GpuPart;

static uint32_t gpu_submit_parts(const GpuPart *parts, int count) {
    VirtqDesc  *desc  = vq_desc();
    VirtqAvail *avail = vq_avail();
    VirtqUsed  *used   = vq_used();

    if (count <= 0 || count > QUEUE_SIZE) {
        printf("virtio-gpu: bad submit count %d\r\n", count);
        return 0xFFFFFFFFu;
    }

    uint16_t used_before = used->idx;

    for (int i = 0; i < count; i++) {
        desc[i].addr  = (uint64_t)(uintptr_t)parts[i].ptr;
        desc[i].len   = parts[i].len;
        desc[i].flags = parts[i].flags;
        desc[i].next  = (uint16_t)(i + 1);

        if (i + 1 < count) {
            desc[i].flags |= VRING_DESC_F_NEXT;
        } else {
            desc[i].flags &= (uint16_t)~VRING_DESC_F_NEXT;
        }
    }

    __sync_synchronize();

    avail->ring[avail->idx % QUEUE_SIZE] = 0;
    __sync_synchronize();
    avail->idx++;
    __sync_synchronize();

    mmio_write32(MMIO_QUEUE_NOTIFY, 0);
    __asm__ volatile("fence iorw,iorw" ::: "memory");

    uint32_t timeout = 10000000;
    while (used->idx == used_before && timeout-- > 0) {
        __sync_synchronize();
    }

    if (timeout == 0) {
        printf("virtio-gpu: timeout waiting for used idx (before=%u now=%u)\r\n",
               used_before, used->idx);
        return 0xFFFFFFFFu;
    }

    __sync_synchronize();
    return ((GpuCtrlHdr *)parts[count - 1].ptr)->type;
}

static int gpu_init_hw(void) {
    uint32_t magic   = mmio_read32(MMIO_MAGIC);
    uint32_t version = mmio_read32(MMIO_VERSION);
    uint32_t devid   = mmio_read32(MMIO_DEVICE_ID);

    if (magic != 0x74726976) {
        printf("virtio-gpu: bad magic 0x%x\r\n", magic);
        return 0;
    }

    if (version != 1) {
        printf("virtio-gpu: unsupported mmio version %u\r\n", version);
        return 0;
    }

    if (devid != 16) {
        printf("virtio-gpu: device id %u is not gpu\r\n", devid);
        return 0;
    }

    gpu_queue_reset();

    mmio_write32(MMIO_STATUS, 0);
    __sync_synchronize();

    mmio_write32(MMIO_STATUS, STATUS_ACK | STATUS_DRIVER);
    __sync_synchronize();

    mmio_write32(MMIO_GUEST_PAGE_SIZE, PAGE_SIZE);
    __sync_synchronize();

    mmio_write32(MMIO_GUEST_FEATURES_SEL, 0);
    mmio_write32(MMIO_GUEST_FEATURES, 0);
    __sync_synchronize();

    mmio_write32(MMIO_QUEUE_SEL, 0);
    uint32_t qmax = mmio_read32(MMIO_QUEUE_NUM_MAX);
    if (qmax == 0) {
        printf("virtio-gpu: queue size max is 0\r\n");
        return 0;
    }

    uint32_t qsz = (QUEUE_SIZE < qmax) ? QUEUE_SIZE : qmax;
    mmio_write32(MMIO_QUEUE_NUM, qsz);
    mmio_write32(MMIO_QUEUE_ALIGN, PAGE_SIZE);
    mmio_write32(MMIO_QUEUE_PFN, (uint32_t)((uintptr_t)gpu_queue_mem / PAGE_SIZE));
    __sync_synchronize();

    mmio_write32(MMIO_STATUS, STATUS_ACK | STATUS_DRIVER | STATUS_DRIVER_OK);
    __sync_synchronize();

    printf("virtio-gpu: ready, qmax=%u qsz=%u\r\n", qmax, qsz);
    return 1;
}

static int gpu_get_display_info(uint32_t *out_w, uint32_t *out_h) {
    GpuCtrlHdr req;
    GpuRespDisplayInfo resp;

    memset(&req, 0, sizeof(req));
    memset(&resp, 0, sizeof(resp));

    req.type = VIRTIO_GPU_CMD_GET_DISPLAY_INFO;

    GpuPart parts[] = {
        { &req,  sizeof(req),  0 },
        { &resp, sizeof(resp), VRING_DESC_F_WRITE },
    };

    uint32_t rtype = gpu_submit_parts(parts, 2);
    if (rtype != VIRTIO_GPU_RESP_OK_DISPLAY_INFO) {
        printf("virtio-gpu: GET_DISPLAY_INFO failed, resp=0x%x\r\n", rtype);
        return 0;
    }

    uint32_t w = resp.pmodes[0].r.width;
    uint32_t h = resp.pmodes[0].r.height;

    if (w == 0 || h == 0) {
        w = FB_MAX_WIDTH;
        h = FB_MAX_HEIGHT;
    }

    *out_w = w;
    *out_h = h;
    return 1;
}

static int gpu_create_resource(uint32_t resource_id, uint32_t w, uint32_t h) {
    GpuResourceCreate2d req;
    GpuCtrlHdr resp;

    memset(&req, 0, sizeof(req));
    memset(&resp, 0, sizeof(resp));

    req.hdr.type    = VIRTIO_GPU_CMD_RESOURCE_CREATE_2D;
    req.resource_id = resource_id;
    req.format      = VIRTIO_GPU_FORMAT_R8G8B8A8_UNORM;
    req.width       = w;
    req.height      = h;

    GpuPart parts[] = {
        { &req,  sizeof(req),  0 },
        { &resp, sizeof(resp), VRING_DESC_F_WRITE },
    };

    uint32_t rtype = gpu_submit_parts(parts, 2);
    if (rtype != VIRTIO_GPU_RESP_OK_NODATA) {
        printf("virtio-gpu: RESOURCE_CREATE_2D failed, resp=0x%x\r\n", rtype);
        return 0;
    }

    return 1;
}

static int gpu_attach_backing(uint32_t resource_id, void *ptr, uint32_t len) {
    GpuResourceAttachBacking req;
    GpuCtrlHdr resp;

    memset(&req, 0, sizeof(req));
    memset(&resp, 0, sizeof(resp));

    req.hdr.type    = VIRTIO_GPU_CMD_RESOURCE_ATTACH_BACKING;
    req.resource_id = resource_id;
    req.nr_entries  = 1;
    req.entry.addr  = (uint64_t)(uintptr_t)ptr;
    req.entry.length = len;
    req.entry.padding = 0;

    GpuPart parts[] = {
        { &req,  sizeof(req),  0 },
        { &resp, sizeof(resp), VRING_DESC_F_WRITE },
    };

    uint32_t rtype = gpu_submit_parts(parts, 2);
    if (rtype != VIRTIO_GPU_RESP_OK_NODATA) {
        printf("virtio-gpu: RESOURCE_ATTACH_BACKING failed, resp=0x%x\r\n", rtype);
        return 0;
    }

    return 1;
}

static int gpu_set_scanout(uint32_t resource_id, uint32_t w, uint32_t h) {
    GpuSetScanout req;
    GpuCtrlHdr resp;

    memset(&req, 0, sizeof(req));
    memset(&resp, 0, sizeof(resp));

    req.hdr.type    = VIRTIO_GPU_CMD_SET_SCANOUT;
    req.r.x         = 0;
    req.r.y         = 0;
    req.r.width     = w;
    req.r.height    = h;
    req.scanout_id  = 0;
    req.resource_id = resource_id;

    GpuPart parts[] = {
        { &req,  sizeof(req),  0 },
        { &resp, sizeof(resp), VRING_DESC_F_WRITE },
    };

    uint32_t rtype = gpu_submit_parts(parts, 2);
    if (rtype != VIRTIO_GPU_RESP_OK_NODATA) {
        printf("virtio-gpu: SET_SCANOUT failed, resp=0x%x\r\n", rtype);
        return 0;
    }

    return 1;
}

static void gpu_flush_rect(uint32_t x, uint32_t y, uint32_t w, uint32_t h) {
    if (!gpu_ready) return;

    GpuTransferToHost2d tr;
    GpuCtrlHdr tr_resp;

    memset(&tr, 0, sizeof(tr));
    memset(&tr_resp, 0, sizeof(tr_resp));

    tr.hdr.type    = VIRTIO_GPU_CMD_TRANSFER_TO_HOST_2D;
    tr.r.x         = x;
    tr.r.y         = y;
    tr.r.width     = w;
    tr.r.height    = h;
    tr.offset      = (uint64_t)((y * fb_width + x) * 4);
    tr.resource_id = 1;

    GpuPart tr_parts[] = {
        { &tr,      sizeof(tr),      0 },
        { &tr_resp, sizeof(tr_resp), VRING_DESC_F_WRITE },
    };

    uint32_t trtype = gpu_submit_parts(tr_parts, 2);
    if (trtype != VIRTIO_GPU_RESP_OK_NODATA) {
        printf("virtio-gpu: TRANSFER_TO_HOST_2D failed, resp=0x%x\r\n", trtype);
        return;
    }

    GpuResourceFlush fl;
    GpuCtrlHdr fl_resp;

    memset(&fl, 0, sizeof(fl));
    memset(&fl_resp, 0, sizeof(fl_resp));

    fl.hdr.type    = VIRTIO_GPU_CMD_RESOURCE_FLUSH;
    fl.r.x         = x;
    fl.r.y         = y;
    fl.r.width     = w;
    fl.r.height    = h;
    fl.resource_id = 1;

    GpuPart fl_parts[] = {
        { &fl,      sizeof(fl),      0 },
        { &fl_resp, sizeof(fl_resp), VRING_DESC_F_WRITE },
    };

    uint32_t fltype = gpu_submit_parts(fl_parts, 2);
    if (fltype != VIRTIO_GPU_RESP_OK_NODATA) {
        printf("virtio-gpu: RESOURCE_FLUSH failed, resp=0x%x\r\n", fltype);
        return;
    }
}

static int lua_gpu_init(lua_State *L) {
    if (gpu_ready) {
        lua_pushboolean(L, 1);
        return 1;
    }

    if (!gpu_init_hw()) {
        lua_pushnil(L);
        lua_pushstring(L, "virtio-gpu init failed");
        return 2;
    }

    if (!gpu_get_display_info(&fb_width, &fb_height)) {
        lua_pushnil(L);
        lua_pushstring(L, "GET_DISPLAY_INFO failed");
        return 2;
    }

    printf("virtio-gpu: display %ux%u\r\n", fb_width, fb_height);

    if ((uint64_t)fb_width * (uint64_t)fb_height * 4ULL > FB_MAX_SIZE) {
        printf("virtio-gpu: framebuffer too large for static buffer\r\n");
        lua_pushnil(L);
        lua_pushstring(L, "framebuffer too large");
        return 2;
    }

    if (!gpu_create_resource(1, fb_width, fb_height)) {
        lua_pushnil(L);
        lua_pushstring(L, "RESOURCE_CREATE_2D failed");
        return 2;
    }

    if (!gpu_attach_backing(1, framebuffer, fb_bytes())) {
        lua_pushnil(L);
        lua_pushstring(L, "RESOURCE_ATTACH_BACKING failed");
        return 2;
    }

    if (!gpu_set_scanout(1, fb_width, fb_height)) {
        lua_pushnil(L);
        lua_pushstring(L, "SET_SCANOUT failed");
        return 2;
    }

    gpu_ready = 1;
    lua_pushboolean(L, 1);
    return 1;
}

static int lua_fb_ptr(lua_State *L) {
    lua_pushinteger(L, (lua_Integer)(uintptr_t)framebuffer);
    return 1;
}

static int lua_fb_size(lua_State *L) {
    lua_pushinteger(L, (lua_Integer)fb_width);
    lua_pushinteger(L, (lua_Integer)fb_height);
    return 2;
}

static int lua_fb_flush(lua_State *L) {
    uint32_t x = (uint32_t)luaL_optinteger(L, 1, 0);
    uint32_t y = (uint32_t)luaL_optinteger(L, 2, 0);
    uint32_t w = (uint32_t)luaL_optinteger(L, 3, fb_width);
    uint32_t h = (uint32_t)luaL_optinteger(L, 4, fb_height);

    gpu_flush_rect(x, y, w, h);
    return 0;
}

static int lua_fb_poke(lua_State *L) {
    uint32_t x   = (uint32_t)luaL_checkinteger(L, 1);
    uint32_t y   = (uint32_t)luaL_checkinteger(L, 2);
    uint32_t rgba = (uint32_t)luaL_checkinteger(L, 3);

    if (x < fb_width && y < fb_height) {
        uint32_t off = (y * fb_width + x) * 4;
        framebuffer[off + 0] = (rgba >> 24) & 0xFF;
        framebuffer[off + 1] = (rgba >> 16) & 0xFF;
        framebuffer[off + 2] = (rgba >>  8) & 0xFF;
        framebuffer[off + 3] = (rgba >>  0) & 0xFF;
    }

    return 0;
}

static int lua_fb_fill(lua_State *L) {
    uint32_t rgba = (uint32_t)luaL_checkinteger(L, 1);

    uint8_t r = (rgba >> 24) & 0xFF;
    uint8_t g = (rgba >> 16) & 0xFF;
    uint8_t b = (rgba >>  8) & 0xFF;
    uint8_t a = (rgba >>  0) & 0xFF;

    uint32_t pixels = fb_width * fb_height;
    for (uint32_t i = 0; i < pixels; i++) {
        uint32_t off = i * 4;
        framebuffer[off + 0] = r;
        framebuffer[off + 1] = g;
        framebuffer[off + 2] = b;
        framebuffer[off + 3] = a;
    }

    return 0;
}

static int lua_gpu_debug(lua_State *L) {
    lua_newtable(L);

    lua_pushstring(L, "magic");
    lua_pushinteger(L, mmio_read32(MMIO_MAGIC));
    lua_settable(L, -3);

    lua_pushstring(L, "version");
    lua_pushinteger(L, mmio_read32(MMIO_VERSION));
    lua_settable(L, -3);

    lua_pushstring(L, "status");
    lua_pushinteger(L, mmio_read32(MMIO_STATUS));
    lua_settable(L, -3);

    lua_pushstring(L, "avail_idx");
    lua_pushinteger(L, vq_avail()->idx);
    lua_settable(L, -3);

    lua_pushstring(L, "used_idx");
    lua_pushinteger(L, vq_used()->idx);
    lua_settable(L, -3);

    lua_pushstring(L, "ready");
    lua_pushinteger(L, gpu_ready);
    lua_settable(L, -3);

    lua_pushstring(L, "fb_width");
    lua_pushinteger(L, fb_width);
    lua_settable(L, -3);

    lua_pushstring(L, "fb_height");
    lua_pushinteger(L, fb_height);
    lua_settable(L, -3);

    return 1;
}

void virtio_gpu_register(lua_State *L) {
    lua_register(L, "gpu_init",  lua_gpu_init);
    lua_register(L, "fb_ptr",    lua_fb_ptr);
    lua_register(L, "fb_size",   lua_fb_size);
    lua_register(L, "fb_flush",  lua_fb_flush);
    lua_register(L, "fb_poke",   lua_fb_poke);
    lua_register(L, "fb_fill",   lua_fb_fill);
    lua_register(L, "gpu_debug", lua_gpu_debug);
}