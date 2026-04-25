-- nyx/drivers/virtio.lua
-- VirtIO block device driver (Lua layer over virtio.c)

local virtio = {}
local initialised = false

function virtio.init()
    if initialised then return true end
    local ok, err = virtio_init()
    if not ok then
        return nil, "virtio: " .. tostring(err)
    end
    initialised = true
    print("virtio: block device ready")
    return true
end

function virtio.read(sector)
    local data, err = virtio_read_sector(sector)
    if not data then
        return nil, "virtio: read s" .. sector .. " failed: " .. tostring(err)
    end
    return data
end

function virtio.write(sector, data)
    local ok, err = virtio_write_sector(sector, data)
    if not ok then
        return nil, "virtio: write s" .. sector .. " failed: " .. tostring(err)
    end
    return true
end

return virtio