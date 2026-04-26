-- nyx/fs.lua
-- Selene VFS + ext2 driver
-- Block device: virtio (512 byte sectors)
-- Filesystem: ext2, 1024-byte blocks (2 sectors per block)

local fs = {}

local mounted = false

-- ── Helpers ──────────────────────────────────────────────────────────

local function u16(s, i)
    local a, b = s:byte(i, i+1)
    return a + b*256
end

local function u32(s, i)
    local a, b, c, d = s:byte(i, i+3)
    return a + b*256 + c*65536 + d*16777216
end

local function u32_to_bytes(n)
    return string.char(
        n & 0xFF,
        (n >> 8) & 0xFF,
        (n >> 16) & 0xFF,
        (n >> 24) & 0xFF
    )
end

local function read_block(n)
    local s0 = virtio_read_sector(n * 2)
    local s1 = virtio_read_sector(n * 2 + 1)
    if not s0 or not s1 then return nil end
    return s0 .. s1
end

local function write_block(n, data)
    if #data ~= 1024 then return nil, "block must be 1024 bytes" end
    local ok1 = virtio_write_sector(n * 2,     data:sub(1, 512))
    local ok2 = virtio_write_sector(n * 2 + 1, data:sub(513, 1024))
    if not ok1 or not ok2 then return nil, "write failed" end
    return true
end

-- ── Superblock ───────────────────────────────────────────────────────

local sb = {}

local function parse_superblock()
    local s = read_block(1)
    if not s then return nil, "read failed" end
    if u16(s, 57) ~= 0xEF53 then return nil, "bad magic" end

    sb.inode_count      = u32(s, 1)
    sb.block_count      = u32(s, 5)
    sb.block_size       = 1024 * (2 ^ u32(s, 25))
    sb.blocks_per_group = u32(s, 33)
    sb.inodes_per_group = u32(s, 41)
    sb.inode_size       = u16(s, 89)
    sb.group_count      = math.ceil(sb.block_count / sb.blocks_per_group)
    sb.first_free_check = u32(s, 21)  -- first free block hint

    return true
end

-- ── Block Group Descriptor ───────────────────────────────────────────

local function get_group_desc(group)
    local tbl = read_block(2)
    if not tbl then return nil end
    local off = group * 32 + 1
    return {
        block_bitmap = u32(tbl, off),
        inode_bitmap = u32(tbl, off + 4),
        inode_table  = u32(tbl, off + 8),
        free_blocks  = u16(tbl, off + 12),
        free_inodes  = u16(tbl, off + 14),
    }
end

local function set_group_desc(group, gd)
    local tbl = read_block(2)
    if not tbl then return nil, "read failed" end
    local off = group * 32 + 1

    -- Patch free counts
    local function patch16(s, i, v)
        return s:sub(1, i-1) .. string.char(v & 0xFF, (v >> 8) & 0xFF) .. s:sub(i+2)
    end
    tbl = patch16(tbl, off + 12, gd.free_blocks)
    tbl = patch16(tbl, off + 14, gd.free_inodes)
    return write_block(2, tbl)
end

-- ── Inode ────────────────────────────────────────────────────────────

local function get_inode(ino)
    local group = math.floor((ino - 1) / sb.inodes_per_group)
    local index = (ino - 1) % sb.inodes_per_group
    local gd = get_group_desc(group)
    if not gd then return nil end

    local inodes_per_block = math.floor(1024 / sb.inode_size)
    local block_off = math.floor(index / inodes_per_block)
    local block = read_block(gd.inode_table + block_off)
    if not block then return nil end

    local off = (index % inodes_per_block) * sb.inode_size + 1
    local direct = {}
    for i = 0, 11 do
        direct[i+1] = u32(block, off + 40 + i * 4)
    end
    return {
        mode     = u16(block, off),
        size     = u32(block, off + 4),
        blocks   = direct,
        indirect = u32(block, off + 88),
        _group   = group,
        _index   = index,
        _off     = off,
        _boff    = block_off,
        _itbl    = gd.inode_table,
    }
end

local function write_inode(ino, inode)
    local group = inode._group
    local index = inode._index
    local gd = get_group_desc(group)
    if not gd then return nil, "bad group" end

    local inodes_per_block = math.floor(1024 / sb.inode_size)
    local block = read_block(inode._itbl + inode._boff)
    if not block then return nil, "read failed" end

    local off = inode._off

    -- Patch size
    local function patch32(s, i, v)
        return s:sub(1, i-1) .. u32_to_bytes(v) .. s:sub(i+4)
    end

    block = patch32(block, off + 4, inode.size)

    -- Patch direct block pointers
    for i = 0, 11 do
        block = patch32(block, off + 40 + i * 4, inode.blocks[i+1] or 0)
    end

    return write_block(inode._itbl + inode._boff, block)
end

-- ── Block allocation ─────────────────────────────────────────────────

local function alloc_block(group)
    local gd = get_group_desc(group)
    if not gd or gd.free_blocks == 0 then return nil end

    local bitmap = read_block(gd.block_bitmap)
    if not bitmap then return nil end

    -- Find first free bit
    for byte_i = 1, #bitmap do
        local byte = bitmap:byte(byte_i)
        if byte ~= 0xFF then
            for bit = 0, 7 do
                if (byte & (1 << bit)) == 0 then
                    -- Found free block
                    local block_num = (group * sb.blocks_per_group) +
                                      (byte_i - 1) * 8 + bit

                    -- Set bit in bitmap
                    local new_byte = byte | (1 << bit)
                    bitmap = bitmap:sub(1, byte_i-1) ..
                             string.char(new_byte) ..
                             bitmap:sub(byte_i+1)
                    write_block(gd.block_bitmap, bitmap)

                    -- Update group descriptor
                    gd.free_blocks = gd.free_blocks - 1
                    set_group_desc(group, gd)

                    -- Zero the new block
                    write_block(block_num, string.rep("\0", 1024))
                    return block_num
                end
            end
        end
    end
    return nil
end

-- ── Inode allocation ─────────────────────────────────────────────────

local function alloc_inode(group)
    local gd = get_group_desc(group)
    if not gd or gd.free_inodes == 0 then return nil end

    local bitmap = read_block(gd.inode_bitmap)
    if not bitmap then return nil end

    for byte_i = 1, #bitmap do
        local byte = bitmap:byte(byte_i)
        if byte ~= 0xFF then
            for bit = 0, 7 do
                if (byte & (1 << bit)) == 0 then
                    local ino = group * sb.inodes_per_group +
                                (byte_i - 1) * 8 + bit + 1

                    local new_byte = byte | (1 << bit)
                    bitmap = bitmap:sub(1, byte_i-1) ..
                             string.char(new_byte) ..
                             bitmap:sub(byte_i+1)
                    write_block(gd.inode_bitmap, bitmap)

                    gd.free_inodes = gd.free_inodes - 1
                    set_group_desc(group, gd)
                    return ino
                end
            end
        end
    end
    return nil
end

-- ── Directory ────────────────────────────────────────────────────────

local function read_dir(inode)
    local entries = {}
    for _, blk in ipairs(inode.blocks) do
        if blk == 0 then break end
        local data = read_block(blk)
        if not data then break end
        local pos = 1
        while pos < #data do
            local ino  = u32(data, pos)
            local rlen = u16(data, pos + 4)
            local nlen = data:byte(pos + 6)
            if ino == 0 or rlen == 0 then break end
            local name = data:sub(pos + 8, pos + 8 + nlen - 1)
            table.insert(entries, { ino = ino, name = name, pos = pos })
            pos = pos + rlen
        end
    end
    return entries
end

local function add_dir_entry(dir_inode, ino, name, file_type)
    -- Find space in existing blocks
    for bi, blk in ipairs(dir_inode.blocks) do
        if blk == 0 then break end
        local data = read_block(blk)
        if not data then return nil, "read failed" end

        local pos = 1
        while pos <= #data do
            local entry_ino  = u32(data, pos)
            local entry_rlen = u16(data, pos + 4)
            local entry_nlen = data:byte(pos + 6)
            if entry_rlen == 0 then break end

            local actual = 8 + entry_nlen
            actual = actual + ((4 - actual % 4) % 4)  -- align to 4
            local free_space = entry_rlen - actual

            local needed = 8 + #name
            needed = needed + ((4 - needed % 4) % 4)

            if entry_ino == 0 and entry_rlen >= needed then
                -- Empty slot
                local new_entry = u32_to_bytes(ino) ..
                    string.char(entry_rlen & 0xFF, (entry_rlen >> 8) & 0xFF) ..
                    string.char(#name, file_type) ..
                    name ..
                    string.rep("\0", entry_rlen - 8 - #name)
                data = data:sub(1, pos-1) .. new_entry .. data:sub(pos + entry_rlen)
                return write_block(blk, data)
            elseif free_space >= needed then
                -- Shrink current entry and append new one
                local new_rlen = entry_rlen - free_space
                -- patch rlen of existing entry
                data = data:sub(1, pos-1) ..
                    u32_to_bytes(entry_ino) ..
                    string.char(new_rlen & 0xFF, (new_rlen >> 8) & 0xFF) ..
                    data:sub(pos + 6)
                local new_pos = pos + new_rlen
                local new_entry = u32_to_bytes(ino) ..
                    string.char(free_space & 0xFF, (free_space >> 8) & 0xFF) ..
                    string.char(#name, file_type) ..
                    name ..
                    string.rep("\0", free_space - 8 - #name)
                data = data:sub(1, new_pos-1) .. new_entry .. data:sub(new_pos + free_space)
                return write_block(blk, data)
            end
            pos = pos + entry_rlen
        end
    end
    return nil, "no space in directory"
end

-- ── Path resolution ───────────────────────────────────────────────────

local function resolve(path)
    local ino = 2
    if path == "/" then return ino end
    for part in path:gmatch("[^/]+") do
        local inode = get_inode(ino)
        if not inode then return nil end
        local entries = read_dir(inode)
        local found = false
        for _, e in ipairs(entries) do
            if e.name == part then
                ino = e.ino
                found = true
                break
            end
        end
        if not found then return nil end
    end
    return ino
end

local function resolve_parent(path)
    local parent = path:match("^(.*)/[^/]+$") or "/"
    local name   = path:match("[^/]+$")
    if parent == "" then parent = "/" end
    return resolve(parent), name
end

-- ── Public API ────────────────────────────────────────────────────────

function fs.mount()
    local ok, err = virtio_init()
    if not ok then return nil, err end
    local ok2, err2 = parse_superblock()
    if not ok2 then return nil, err2 end
    mounted = true
    print(string.format("fs: ext2 mounted, %d blocks, %d inodes, block_size=%d",
        sb.block_count, sb.inode_count, sb.block_size))
    return true
end

function fs.list(path)
    if not mounted then return nil, "not mounted" end
    local ino = resolve(path or "/")
    if not ino then return nil, "not found" end
    local inode = get_inode(ino)
    if not inode then return nil, "bad inode" end
    local entries = read_dir(inode)
    local names = {}
    for _, e in ipairs(entries) do
        table.insert(names, e.name)
    end
    return names
end

function fs.read(path)
    if not mounted then return nil, "not mounted" end
    local ino = resolve(path)
    if not ino then return nil, "not found: " .. path end
    local inode = get_inode(ino)
    if not inode then return nil, "bad inode" end

    local data = ""
    for _, blk in ipairs(inode.blocks) do
        if blk == 0 then break end
        local b = read_block(blk)
        if not b then break end
        data = data .. b
    end
    return data:sub(1, inode.size)
end

function fs.write(path, data)
    if not mounted then return nil, "not mounted" end

    local ino = resolve(path)
    local inode

    if ino then
        -- File exists — overwrite
        inode = get_inode(ino)
        if not inode then return nil, "bad inode" end
    else
        -- Create new file
        local parent_ino, name = resolve_parent(path)
        if not parent_ino then return nil, "parent dir not found" end

        ino = alloc_inode(0)
        if not ino then return nil, "no free inodes" end

        inode = {
            mode   = 0x81A4,  -- regular file, 0644
            size   = 0,
            blocks = {0,0,0,0,0,0,0,0,0,0,0,0},
            _group = 0,
            _index = (ino - 1) % sb.inodes_per_group,
            _boff  = math.floor(((ino-1) % sb.inodes_per_group) /
                     math.floor(1024 / sb.inode_size)),
            _itbl  = get_group_desc(0).inode_table,
            _off   = ((ino-1) % sb.inodes_per_group %
                     math.floor(1024 / sb.inode_size)) * sb.inode_size + 1,
        }

        -- Add to parent directory
        local ok, err = add_dir_entry(get_inode(parent_ino), ino, name, 1)
        if not ok then return nil, "dir entry failed: " .. tostring(err) end
    end

    -- Write data in 1024-byte blocks
    local block_idx = 1
    local written = 0
    local new_blocks = {}

    for i = 1, math.ceil(#data / 1024) do
        local chunk = data:sub((i-1)*1024 + 1, i*1024)
        if #chunk < 1024 then
            chunk = chunk .. string.rep("\0", 1024 - #chunk)
        end

        local blk = inode.blocks[i]
        if not blk or blk == 0 then
            blk = alloc_block(0)
            if not blk then return nil, "no free blocks" end
        end
        new_blocks[i] = blk
        write_block(blk, chunk)
        written = written + 1
    end

    -- Free any extra blocks if file shrank
    for i = written + 1, 12 do
        new_blocks[i] = 0
    end

    inode.blocks = new_blocks
    inode.size   = #data
    local ok, err = write_inode(ino, inode)
    if not ok then return nil, "inode write failed: " .. tostring(err) end

    return true
end

function fs.exists(path)
    if not mounted then return false end
    return resolve(path) ~= nil
end

function fs.delete(path)
    if not mounted then return nil, "not mounted" end
    
    local parent_ino, name = resolve_parent(path)
    if not parent_ino then return nil, "parent not found" end
    
    local parent_inode = get_inode(parent_ino)
    if not parent_inode then return nil, "bad parent inode" end
    
    local entries = read_dir(parent_inode)
    for _, e in ipairs(entries) do
        if e.name == name then
            -- Found entry, zero it out
            for _, blk in ipairs(parent_inode.blocks) do
                if blk == 0 then break end
                local data = read_block(blk)
                if not data then break end
                
                local pos = e.pos
                -- Zero inode number to mark as deleted
                data = data:sub(1, pos-1) .. string.rep("\0", 4) .. data:sub(pos+5)
                write_block(blk, data)
                return true
            end
        end
    end
    
    return nil, "not found"
end

function fs.mkdir(path)
    if not mounted then return nil, "not mounted" end
    
    local parent_ino, name = resolve_parent(path)
    if not parent_ino then return nil, "parent dir not found" end
    
    -- Check if already exists
    if resolve(path) then return nil, "already exists" end
    
    -- Allocate inode for new directory
    local ino = alloc_inode(0)
    if not ino then return nil, "no free inodes" end
    
    -- Allocate block for directory contents
    local blk = alloc_block(0)
    if not blk then return nil, "no free blocks" end
    
    local dir_inode = {
        mode   = 0x41ED,  -- directory, 0755
        size   = 1024,
        blocks = {blk, 0,0,0,0,0,0,0,0,0,0,0},
        _group = 0,
        _index = (ino - 1) % sb.inodes_per_group,
        _boff  = math.floor(((ino-1) % sb.inodes_per_group) / math.floor(1024 / sb.inode_size)),
        _itbl  = get_group_desc(0).inode_table,
        _off   = ((ino-1) % sb.inodes_per_group % math.floor(1024 / sb.inode_size)) * sb.inode_size + 1,
    }
    
    write_inode(ino, dir_inode)
    
    -- Add directory entry to parent
    local ok, err = add_dir_entry(get_inode(parent_ino), ino, name, 2)
    if not ok then return nil, "dir entry failed: " .. tostring(err) end
    
    return true
end

function fs.info()
    if not mounted then return nil, "not mounted" end
    -- sum free blocks across all groups
    local free_blocks = 0
    local free_inodes = 0
    for g = 0, sb.group_count - 1 do
        local gd = get_group_desc(g)
        if gd then
            free_blocks = free_blocks + gd.free_blocks
            free_inodes = free_inodes + gd.free_inodes
        end
    end
    return {
        block_count      = sb.block_count,
        block_size       = sb.block_size,
        blocks_per_group = sb.blocks_per_group,
        inodes_per_group = sb.inodes_per_group,
        inode_count      = sb.inode_count,
        group_count      = sb.group_count,
        free_blocks      = free_blocks,
        free_inodes      = free_inodes,
    }
end

return fs
