local fs = require("nyx.fs")
local info, err = fs.info()
if not info then print("df: " .. tostring(err)); return end

local used = info.block_count - info.free_blocks
local pct  = math.floor(used / info.block_count * 100)
local used_kb  = math.floor(used * info.block_size / 1024)
local free_kb  = math.floor(info.free_blocks * info.block_size / 1024)
local total_kb = math.floor(info.block_count * info.block_size / 1024)

print(string.format("%-20s %8s %8s %8s %5s",
    "filesystem", "total", "used", "free", "use%"))
print(string.format("%-20s %7dK %7dK %7dK %4d%%",
    "/dev/vda", total_kb, used_kb, free_kb, pct))