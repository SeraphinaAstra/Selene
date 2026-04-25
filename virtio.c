/* virtio.c — VirtIO PCI modern block device driver */
#include <stdint.h>
#include <string.h>
#include "lua.h"
#include "lauxlib.h"

/* PCI config space for device 16 on bus 0 */
#define PCI_CFG_BASE    0x30008000
#define PCI_CMD         0x04
#define PCI_BAR4        0x20
#define PCI_BAR5        0x24

/* BAR4 assigned address */
#define BAR4_ADDR       0x40000000

/* VirtIO capability regions (BAR4 + offset) */
#define COMMON_CFG_BASE (BAR4_ADDR + 0x0000)
#define ISR_BASE        (BAR4_ADDR + 0x1000)
#define DEVICE_CFG_BASE (BAR4_ADDR + 0x2000)
#define NOTIFY_BASE     (BAR4_ADDR + 0x3000)
#define NOTIFY_MULT     4

/* Common config offsets */
#define COMMON_DEVICE_FEAT_SEL  0x00
#define COMMON_DEVICE_FEAT      0x04
#define COMMON_DRIVER_FEAT_SEL  0x08
#define COMMON_DRIVER_FEAT      0x0C
#define COMMON_MSIX_CFG         0x10
#define COMMON_NUM_QUEUES       0x12
#define COMMON_DEVICE_STATUS    0x14
#define COMMON_CFG_GEN          0x15
#define COMMON_QUEUE_SEL        0x16
#define COMMON_QUEUE_SIZE       0x18
#define COMMON_QUEUE_MSIX       0x1A
#define COMMON_QUEUE_ENABLE     0x1C
#define COMMON_QUEUE_NOTIFY_OFF 0x1E
#define COMMON_QUEUE_DESC_LO    0x20
#define COMMON_QUEUE_DESC_HI    0x24
#define COMMON_QUEUE_AVAIL_LO   0x28
#define COMMON_QUEUE_AVAIL_HI   0x2C
#define COMMON_QUEUE_USED_LO    0x30
#define COMMON_QUEUE_USED_HI    0x34

/* Device status bits */
#define VIRTIO_S_ACKNOWLEDGE    1
#define VIRTIO_S_DRIVER         2
#define VIRTIO_S_DRIVER_OK      4
#define VIRTIO_S_FEATURES_OK    8

/* Block request types */
#define VIRTIO_BLK_T_IN     0
#define VIRTIO_BLK_T_OUT    1

/* Descriptor flags */
#define VRING_DESC_F_NEXT   1
#define VRING_DESC_F_WRITE  2

#define QUEUE_SIZE  16
#define PAGE_SIZE   4096

static inline uint32_t pci_read32(uint32_t off) {
    return *(volatile uint32_t *)(PCI_CFG_BASE + off);
}
static inline void pci_write32(uint32_t off, uint32_t val) {
    *(volatile uint32_t *)(PCI_CFG_BASE + off) = val;
}

static inline uint32_t cc_read32(uint32_t off) {
    return *(volatile uint32_t *)(COMMON_CFG_BASE + off);
}
static inline uint16_t cc_read16(uint32_t off) {
    return *(volatile uint16_t *)(COMMON_CFG_BASE + off);
}
static inline uint8_t cc_read8(uint32_t off) {
    return *(volatile uint8_t *)(COMMON_CFG_BASE + off);
}
static inline void cc_write32(uint32_t off, uint32_t val) {
    *(volatile uint32_t *)(COMMON_CFG_BASE + off) = val;
}
static inline void cc_write16(uint32_t off, uint16_t val) {
    *(volatile uint16_t *)(COMMON_CFG_BASE + off) = val;
}
static inline void cc_write8(uint32_t off, uint8_t val) {
    *(volatile uint8_t *)(COMMON_CFG_BASE + off) = val;
}

/* Virtqueue structs */
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
    uint32_t reserved;
    uint64_t sector;
} __attribute__((packed)) BlkReqHdr;

static VirtqDesc descs[QUEUE_SIZE] __attribute__((aligned(PAGE_SIZE)));
static VirtqAvail avail            __attribute__((aligned(PAGE_SIZE)));
static VirtqUsed  used             __attribute__((aligned(PAGE_SIZE)));

static BlkReqHdr req_hdr;
static uint8_t   req_status;
static uint8_t   req_buf[512];

static int virtio_ready = 0;

static int lua_virtio_init(lua_State *L) {
    if (virtio_ready) { lua_pushboolean(L, 1); return 1; }

    /* Assign BAR4 and enable memory space + bus mastering */
    pci_write32(PCI_BAR4, BAR4_ADDR);
    pci_write32(PCI_BAR5, 0);
    pci_write32(PCI_CMD, pci_read32(PCI_CMD) | 0x6);

    /* Reset device */
    cc_write8(COMMON_DEVICE_STATUS, 0);
    __sync_synchronize();

    cc_write8(COMMON_DEVICE_STATUS, VIRTIO_S_ACKNOWLEDGE);
    cc_write8(COMMON_DEVICE_STATUS, VIRTIO_S_ACKNOWLEDGE | VIRTIO_S_DRIVER);

    /* Negotiate no extra features */
    cc_write32(COMMON_DRIVER_FEAT_SEL, 0);
    cc_write32(COMMON_DRIVER_FEAT, 0);
    cc_write32(COMMON_DRIVER_FEAT_SEL, 1);
    cc_write32(COMMON_DRIVER_FEAT, 0);

    cc_write8(COMMON_DEVICE_STATUS,
        VIRTIO_S_ACKNOWLEDGE | VIRTIO_S_DRIVER | VIRTIO_S_FEATURES_OK);

    if (!(cc_read8(COMMON_DEVICE_STATUS) & VIRTIO_S_FEATURES_OK)) {
        lua_pushnil(L); lua_pushstring(L, "FEATURES_OK not set"); return 2;
    }

    /* Set up queue 0 */
    cc_write16(COMMON_QUEUE_SEL, 0);
    uint16_t qmax = cc_read16(COMMON_QUEUE_SIZE);
    if (qmax == 0) { lua_pushnil(L); lua_pushstring(L, "queue size 0"); return 2; }

    uint16_t qsz = (QUEUE_SIZE < qmax) ? QUEUE_SIZE : qmax;
    cc_write16(COMMON_QUEUE_SIZE, qsz);

    memset(descs, 0, sizeof(descs));
    memset(&avail, 0, sizeof(avail));
    memset(&used,  0, sizeof(used));

    cc_write32(COMMON_QUEUE_DESC_LO,  (uint32_t)(uintptr_t)descs);
    cc_write32(COMMON_QUEUE_DESC_HI,  0);
    cc_write32(COMMON_QUEUE_AVAIL_LO, (uint32_t)(uintptr_t)&avail);
    cc_write32(COMMON_QUEUE_AVAIL_HI, 0);
    cc_write32(COMMON_QUEUE_USED_LO,  (uint32_t)(uintptr_t)&used);
    cc_write32(COMMON_QUEUE_USED_HI,  0);

    cc_write16(COMMON_QUEUE_ENABLE, 1);

    cc_write8(COMMON_DEVICE_STATUS,
        VIRTIO_S_ACKNOWLEDGE | VIRTIO_S_DRIVER | VIRTIO_S_FEATURES_OK | VIRTIO_S_DRIVER_OK);

    virtio_ready = 1;
    printf("virtio: ready, qmax=%d qsz=%d\r\n", qmax, qsz);
    lua_pushboolean(L, 1);
    return 1;
}

static int submit_request(void) {
    uint16_t idx = avail.idx % QUEUE_SIZE;
    avail.ring[idx] = 0;
    __sync_synchronize();
    avail.idx++;
    __sync_synchronize();
    __asm__ volatile("fence iorw,iorw" ::: "memory");

    /* Notify queue 0 */
    *(volatile uint32_t *)(NOTIFY_BASE + 0 * NOTIFY_MULT) = 0;
    __asm__ volatile("fence iorw,iorw" ::: "memory");

    uint16_t expected = avail.idx;
    uint32_t timeout = 10000000;
    while (used.idx != expected && timeout-- > 0)
        __sync_synchronize();

    if (timeout == 0) {
        printf("virtio: timeout! used=%d expected=%d status=%d\r\n",
            used.idx, expected, req_status);
        return -1;
    }
    return (req_status == 0) ? 0 : -1;
}

static int lua_virtio_read_sector(lua_State *L) {
    if (!virtio_ready) { lua_pushnil(L); lua_pushstring(L, "not initialised"); return 2; }

    uint64_t sector = (uint64_t)luaL_checkinteger(L, 1);
    req_hdr.type = VIRTIO_BLK_T_IN; req_hdr.reserved = 0; req_hdr.sector = sector;
    req_status = 0xFF;

    descs[0].addr = (uint64_t)(uintptr_t)&req_hdr;
    descs[0].len  = sizeof(BlkReqHdr);
    descs[0].flags = VRING_DESC_F_NEXT; descs[0].next = 1;

    descs[1].addr = (uint64_t)(uintptr_t)req_buf;
    descs[1].len  = 512;
    descs[1].flags = VRING_DESC_F_WRITE | VRING_DESC_F_NEXT; descs[1].next = 2;

    descs[2].addr = (uint64_t)(uintptr_t)&req_status;
    descs[2].len  = 1;
    descs[2].flags = VRING_DESC_F_WRITE; descs[2].next = 0;

    if (submit_request() != 0) {
        lua_pushnil(L); lua_pushstring(L, "device error"); return 2;
    }
    lua_pushlstring(L, (const char *)req_buf, 512);
    return 1;
}

static int lua_virtio_write_sector(lua_State *L) {
    if (!virtio_ready) { lua_pushnil(L); lua_pushstring(L, "not initialised"); return 2; }

    uint64_t sector = (uint64_t)luaL_checkinteger(L, 1);
    size_t len = 0;
    const char *data = luaL_checklstring(L, 2, &len);
    if (len != 512) { lua_pushnil(L); lua_pushstring(L, "need 512 bytes"); return 2; }

    memcpy(req_buf, data, 512);
    req_hdr.type = VIRTIO_BLK_T_OUT; req_hdr.reserved = 0; req_hdr.sector = sector;
    req_status = 0xFF;

    descs[0].addr = (uint64_t)(uintptr_t)&req_hdr;
    descs[0].len  = sizeof(BlkReqHdr);
    descs[0].flags = VRING_DESC_F_NEXT; descs[0].next = 1;

    descs[1].addr = (uint64_t)(uintptr_t)req_buf;
    descs[1].len  = 512;
    descs[1].flags = VRING_DESC_F_NEXT; descs[1].next = 2;

    descs[2].addr = (uint64_t)(uintptr_t)&req_status;
    descs[2].len  = 1;
    descs[2].flags = VRING_DESC_F_WRITE; descs[2].next = 0;

    if (submit_request() != 0) {
        lua_pushnil(L); lua_pushstring(L, "device error"); return 2;
    }
    lua_pushboolean(L, 1);
    return 1;
}

void virtio_register(lua_State *L) {
    lua_register(L, "virtio_init",         lua_virtio_init);
    lua_register(L, "virtio_read_sector",  lua_virtio_read_sector);
    lua_register(L, "virtio_write_sector", lua_virtio_write_sector);
}