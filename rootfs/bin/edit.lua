-- /bin/edit.lua
-- Selene screen editor

local function editor(path)
    local fs = require("nyx.fs")

    local lines = {}
    if _mounted and fs.exists(path) then
        local data = fs.read(path)
        if data then
            for line in (data .. "\n"):gmatch("([^\n]*)\n") do
                table.insert(lines, line)
            end
            if #lines > 0 and lines[#lines] == "" then
                table.remove(lines)
            end
        end
    end
    if #lines == 0 then lines = {""} end

    local cx, cy  = 1, 1
    local scroll  = 0
    local dirty   = false
    local running = true
    local status  = ""

    local W, H   = 80, 24
    local EDIT_H = H - 2

    local function clamp(v, lo, hi)
        return math.max(lo, math.min(hi, v))
    end

    local function draw()
        putstr("\27[2J\27[H")
        -- Header
        putstr("\27[1;1H")
        local title = "  edit: " .. path .. (dirty and " [+]" or "")
        local hint  = " ^S save  ^Q quit "
        local pad   = string.rep(" ", math.max(0, W - #title - #hint))
        putstr("\27[7m" .. title .. pad .. hint .. "\27[0m")

        -- Text
        for i = 1, EDIT_H do
            local li = i + scroll
            putstr("\27[" .. (i+1) .. ";1H")
            if li <= #lines then
                local line = lines[li]:sub(1, W)
                putstr(line .. "\27[K")
            else
                putstr("\27[K")
            end
        end

        -- Status
        putstr("\27[" .. H .. ";1H")
        local pos  = string.format("  Ln %d/%d  Col %d  ", cy, #lines, cx)
        local spad = string.rep(" ", math.max(0, W - #pos - #status))
        putstr("\27[7m" .. status .. spad .. pos .. "\27[0m")

        -- Cursor
        putstr("\27[" .. (cy - scroll + 1) .. ";" .. cx .. "H")
        status = ""
    end

    local function save()
        local data = table.concat(lines, "\n") .. "\n"
        local ok, err = fs.write(path, data)
        if ok then
            dirty  = false
            status = "  saved " .. #data .. " bytes"
        else
            status = "  save failed: " .. tostring(err)
        end
    end

    local function cur_line() return lines[cy] or "" end
    local function set_line(s) lines[cy] = s; dirty = true end

    while running do
        draw()
        local key = readkey()

        if key == "UP" then
            cy = clamp(cy - 1, 1, #lines)
            cx = clamp(cx, 1, #cur_line() + 1)
            if cy <= scroll then scroll = cy - 1 end

        elseif key == "DOWN" then
            cy = clamp(cy + 1, 1, #lines)
            cx = clamp(cx, 1, #cur_line() + 1)
            if cy > scroll + EDIT_H then scroll = cy - EDIT_H end

        elseif key == "LEFT" then
            if cx > 1 then cx = cx - 1
            elseif cy > 1 then cy = cy - 1; cx = #cur_line() + 1 end

        elseif key == "RIGHT" then
            if cx <= #cur_line() then cx = cx + 1
            elseif cy < #lines then cy = cy + 1; cx = 1 end

        elseif key == "HOME" then
            cx = 1

        elseif key == "END" then
            cx = #cur_line() + 1

        elseif key == "\r" or key == "\n" then
            local l      = cur_line()
            local before = l:sub(1, cx - 1)
            local after  = l:sub(cx)
            set_line(before)
            table.insert(lines, cy + 1, after)
            cy = cy + 1; cx = 1
            if cy > scroll + EDIT_H then scroll = cy - EDIT_H end

        elseif key == "\127" or key == "\8" then
            if cx > 1 then
                local l = cur_line()
                set_line(l:sub(1, cx-2) .. l:sub(cx))
                cx = cx - 1
            elseif cy > 1 then
                local l    = cur_line()
                table.remove(lines, cy)
                cy = cy - 1
                cx = #cur_line() + 1
                set_line(cur_line() .. l)
                if cy <= scroll then scroll = clamp(cy-1, 0, #lines) end
            end

        elseif key == "DEL" then
            local l = cur_line()
            if cx <= #l then
                set_line(l:sub(1, cx-1) .. l:sub(cx+1))
            elseif cy < #lines then
                local next = table.remove(lines, cy+1)
                set_line(cur_line() .. next)
                dirty = true
            end

        elseif key == "\19" then  -- ^S
            save()

        elseif key == "\17" then  -- ^Q
            if dirty then
                status = "  unsaved -- ^Q again to quit"
                draw()
                if readkey() == "\17" then running = false end
            else
                running = false
            end

        elseif #key == 1 and key:byte(1) >= 32 then
            local l = cur_line()
            set_line(l:sub(1, cx-1) .. key .. l:sub(cx))
            cx = cx + 1
        end
    end

    putstr("\27[2J\27[H")
    putstr("edit: closed " .. path .. "\r\n")
end

local path = ...
if path then
    editor(path)
else
    print("usage: edit(path)")
end