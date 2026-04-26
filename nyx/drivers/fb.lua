-- nyx/drivers/fb.lua
-- Framebuffer text renderer for Selene/Nyx
-- Assumes these globals already exist from the GPU driver:
--   gpu_init(), fb_size(), fb_fill(rgba), fb_poke(x, y, rgba), fb_flush([x, y, w, h])

local fb = {}

local CHAR_W = 8
local CHAR_H = 8

local W, H = 0, 0
local COLS, ROWS = 0, 0

local fg = 0xFFFFFFFF
local bg = 0x000000FF

local cursor_x = 0
local cursor_y = 0

local lines = { "" }
local installed = false
local old_print = _G.print

local glyphs = {}

local function setglyph(ch, rows)
    glyphs[ch] = rows
end

-- Space / punctuation
setglyph(" ", {0,0,0,0,0,0,0,0})
setglyph(".", {0,0,0,0,0,0x18,0x18,0x00})
setglyph(",", {0,0,0,0,0,0x18,0x18,0x10})
setglyph(":", {0,0,0x18,0,0,0x18,0,0})
setglyph(";", {0,0,0x18,0,0,0x18,0x18,0x10})
setglyph("!", {0x18,0x18,0x18,0x18,0x18,0,0x18,0})
setglyph("?", {0x3C,0x42,0x02,0x0C,0x18,0,0x18,0})
setglyph("-", {0,0,0,0x7E,0,0,0,0})
setglyph("_", {0,0,0,0,0,0,0,0x7E})
setglyph("+", {0,0x18,0x18,0x7E,0x18,0x18,0,0})
setglyph("=", {0,0,0x7E,0,0x7E,0,0,0})
setglyph("/", {0x02,0x04,0x08,0x10,0x20,0x40,0,0})
setglyph("\\", {0x40,0x20,0x10,0x08,0x04,0x02,0,0})
setglyph("(", {0x0C,0x10,0x20,0x20,0x20,0x10,0x0C,0})
setglyph(")", {0x30,0x08,0x04,0x04,0x04,0x08,0x30,0})
setglyph("[", {0x1E,0x10,0x10,0x10,0x10,0x10,0x1E,0})
setglyph("]", {0x78,0x08,0x08,0x08,0x08,0x08,0x78,0})
setglyph("{", {0x0E,0x10,0x10,0x60,0x10,0x10,0x0E,0})
setglyph("}", {0x70,0x08,0x08,0x06,0x08,0x08,0x70,0})
setglyph("<", {0x08,0x10,0x20,0x40,0x20,0x10,0x08,0})
setglyph(">", {0x20,0x10,0x08,0x04,0x08,0x10,0x20,0})
setglyph("|", {0x18,0x18,0x18,0x18,0x18,0x18,0x18,0})
setglyph("'", {0x18,0x18,0x10,0,0,0,0,0})
setglyph('"', {0x36,0x36,0x24,0,0,0,0,0})
setglyph("`", {0x10,0x08,0,0,0,0,0,0})
setglyph("~", {0,0,0x32,0x4C,0,0,0,0})
setglyph("#", {0x24,0x24,0x7E,0x24,0x7E,0x24,0x24,0})
setglyph("%", {0x62,0x64,0x08,0x10,0x26,0x46,0,0})
setglyph("&", {0x30,0x48,0x48,0x30,0x4A,0x44,0x3A,0})
setglyph("*", {0,0x24,0x18,0x7E,0x18,0x24,0,0})
setglyph("@", {0x3C,0x42,0x5A,0x5A,0x5E,0x40,0x3C,0})
setglyph("$", {0x18,0x3E,0x58,0x3C,0x16,0x7C,0x18,0})
setglyph("^", {0x18,0x24,0x42,0,0,0,0,0})

-- Digits
setglyph("0", {0x3C,0x42,0x46,0x4A,0x52,0x62,0x3C,0})
setglyph("1", {0x18,0x38,0x18,0x18,0x18,0x18,0x3C,0})
setglyph("2", {0x3C,0x42,0x02,0x0C,0x30,0x40,0x7E,0})
setglyph("3", {0x7E,0x04,0x08,0x1C,0x02,0x42,0x3C,0})
setglyph("4", {0x0C,0x14,0x24,0x44,0x7E,0x04,0x04,0})
setglyph("5", {0x7E,0x40,0x7C,0x02,0x02,0x42,0x3C,0})
setglyph("6", {0x1C,0x20,0x40,0x7C,0x42,0x42,0x3C,0})
setglyph("7", {0x7E,0x02,0x04,0x08,0x10,0x10,0x10,0})
setglyph("8", {0x3C,0x42,0x42,0x3C,0x42,0x42,0x3C,0})
setglyph("9", {0x3C,0x42,0x42,0x3E,0x02,0x04,0x38,0})

-- Uppercase letters
setglyph("A", {0x18,0x24,0x42,0x7E,0x42,0x42,0x42,0})
setglyph("B", {0x7C,0x42,0x42,0x7C,0x42,0x42,0x7C,0})
setglyph("C", {0x3C,0x42,0x40,0x40,0x40,0x42,0x3C,0})
setglyph("D", {0x78,0x44,0x42,0x42,0x42,0x44,0x78,0})
setglyph("E", {0x7E,0x40,0x40,0x7C,0x40,0x40,0x7E,0})
setglyph("F", {0x7E,0x40,0x40,0x7C,0x40,0x40,0x40,0})
setglyph("G", {0x3C,0x42,0x40,0x4E,0x42,0x42,0x3C,0})
setglyph("H", {0x42,0x42,0x42,0x7E,0x42,0x42,0x42,0})
setglyph("I", {0x3C,0x08,0x08,0x08,0x08,0x08,0x3C,0})
setglyph("J", {0x0E,0x04,0x04,0x04,0x44,0x44,0x38,0})
setglyph("K", {0x42,0x44,0x48,0x70,0x48,0x44,0x42,0})
setglyph("L", {0x40,0x40,0x40,0x40,0x40,0x40,0x7E,0})
setglyph("M", {0x42,0x66,0x5A,0x42,0x42,0x42,0x42,0})
setglyph("N", {0x42,0x62,0x52,0x4A,0x46,0x42,0x42,0})
setglyph("O", {0x3C,0x42,0x42,0x42,0x42,0x42,0x3C,0})
setglyph("P", {0x7C,0x42,0x42,0x7C,0x40,0x40,0x40,0})
setglyph("Q", {0x3C,0x42,0x42,0x42,0x4A,0x44,0x3A,0})
setglyph("R", {0x7C,0x42,0x42,0x7C,0x48,0x44,0x42,0})
setglyph("S", {0x3C,0x42,0x40,0x3C,0x02,0x42,0x3C,0})
setglyph("T", {0x7E,0x18,0x18,0x18,0x18,0x18,0x18,0})
setglyph("U", {0x42,0x42,0x42,0x42,0x42,0x42,0x3C,0})
setglyph("V", {0x42,0x42,0x42,0x42,0x24,0x24,0x18,0})
setglyph("W", {0x42,0x42,0x42,0x5A,0x5A,0x66,0x42,0})
setglyph("X", {0x42,0x24,0x18,0x18,0x18,0x24,0x42,0})
setglyph("Y", {0x42,0x24,0x18,0x18,0x18,0x18,0x18,0})
setglyph("Z", {0x7E,0x04,0x08,0x10,0x20,0x40,0x7E,0})

-- Fallback
setglyph("?", {0x3C,0x42,0x02,0x0C,0x18,0,0x18,0})

local function ensure_init()
    if W ~= 0 and H ~= 0 then return true end
    if type(gpu_init) ~= "function" then
        error("fb.lua: gpu_init() is not available")
    end
    local ok, err = pcall(gpu_init)
    if not ok or err == nil or err == false then
        error("fb.lua: gpu_init() failed")
    end
    if type(fb_size) ~= "function" then
        error("fb.lua: fb_size() is not available")
    end
    W, H = fb_size()
    COLS = math.floor(W / CHAR_W)
    ROWS = math.floor(H / CHAR_H)
    return true
end

local function clear_internal()
    lines = { "" }
    cursor_x = 0
    cursor_y = 0
end

local function draw_cell(x, y, ch)
    local glyph = glyphs[ch]
    if not glyph then
        ch = string.upper(ch)
        glyph = glyphs[ch] or glyphs["?"]
    end

    for row = 0, CHAR_H - 1 do
        local bits = glyph[row + 1] or 0
        for col = 0, CHAR_W - 1 do
            local mask = 1 << (7 - col)
            local pixel = ((bits & mask) ~= 0) and fg or bg
            fb_poke(x + col, y + row, pixel)
        end
    end
end

local function render_all()
    fb_fill(bg)
    for row = 1, #lines do
        local text = lines[row] or ""
        local py = (row - 1) * CHAR_H
        for i = 1, #text do
            local ch = text:sub(i, i)
            draw_cell((i - 1) * CHAR_W, py, ch)
        end
    end
    fb_flush()
end

local function new_line()
    cursor_x = 0
    cursor_y = cursor_y + 1

    if #lines < ROWS then
        lines[#lines + 1] = ""
    else
        table.remove(lines, 1)
        lines[#lines + 1] = ""
        cursor_y = ROWS - 1
        render_all()
    end
end

function fb.init(opts)
    ensure_init()
    opts = opts or {}
    clear_internal()
    fb_fill(bg)
    fb_flush()
    if opts.install_print then
        fb.install()
    end
    return true
end

function fb.resize()
    ensure_init()
    COLS = math.floor(W / CHAR_W)
    ROWS = math.floor(H / CHAR_H)
    return W, H, COLS, ROWS
end

function fb.set_colors(new_fg, new_bg)
    if new_fg ~= nil then fg = new_fg end
    if new_bg ~= nil then bg = new_bg end
end

function fb.clear()
    ensure_init()
    clear_internal()
    fb_fill(bg)
    fb_flush()
end

function fb.redraw()
    ensure_init()
    render_all()
end

function fb.cursor()
    return cursor_x, cursor_y
end

function fb.set_cursor(x, y)
    ensure_init()
    cursor_x = math.max(0, math.min(COLS - 1, x or 0))
    cursor_y = math.max(0, math.min(ROWS - 1, y or 0))
end

function fb.putc(c)
    ensure_init()

    if c == nil then return end
    c = tostring(c)

    if c == "\n" then
        new_line()
        return
    elseif c == "\r" then
        cursor_x = 0
        lines[cursor_y + 1] = ""
        render_all()
        return
    elseif c == "\t" then
        for _ = 1, 4 do fb.putc(" ") end
        return
    end

    if #c ~= 1 then
        for i = 1, #c do
            fb.putc(c:sub(i, i))
        end
        return
    end

    if cursor_y >= ROWS then
        render_all()
        cursor_y = ROWS - 1
    end

    local row = cursor_y + 1
    lines[row] = (lines[row] or "") .. c
    draw_cell(cursor_x * CHAR_W, cursor_y * CHAR_H, c)

    cursor_x = cursor_x + 1
    if cursor_x >= COLS then
        new_line()
    end
end

function fb.write(str)
    ensure_init()
    str = tostring(str or "")
    for i = 1, #str do
        fb.putc(str:sub(i, i))
    end
    fb_flush()
end

function fb.print(...)
    local n = select("#", ...)
    if n == 0 then
        fb.write("\n")
        return
    end

    local parts = {}
    for i = 1, n do
        parts[i] = tostring(select(i, ...))
    end
    fb.write(table.concat(parts, " ") .. "\n")
end

function fb.install()
    if installed then return true end
    old_print = old_print or _G.print

    _G.print = function(...)
        local n = select("#", ...)
        local parts = {}
        for i = 1, n do
            parts[i] = tostring(select(i, ...))
        end
        fb.write(table.concat(parts, " ") .. "\n")
    end

    installed = true
    return true
end

function fb.uninstall()
    if not installed then return true end
    if old_print then
        _G.print = old_print
    end
    installed = false
    return true
end

function fb.raw_print(...)
    if old_print then
        return old_print(...)
    end
end

return fb