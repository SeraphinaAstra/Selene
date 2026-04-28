-- /bin/edit.lua
-- Selene screen editor
-- features: tabs, horizontal scrolling, Lua highlighting, safe ANSI rendering

local function editor(path)
    local fs = require("nyx.fs")

    -- =========================
    -- Config
    -- =========================
    local W, H   = 80, 24
    local EDIT_H  = H - 2
    local TAB_W   = 4
    local ENABLE_HIGHLIGHT = true

    -- =========================
    -- ANSI
    -- =========================
    local RESET = "\27[0m"
    local function C(code)
        return "\27[" .. code .. "m"
    end

    local COLORS = {
        control = C("34"), -- blue
        decl    = C("35"), -- magenta
        logic   = C("36"), -- cyan
        const   = C("32"), -- green
        string  = C("33"), -- yellow
        number  = C("31"), -- red
        comment = C("90"), -- gray
    }

    -- =========================
    -- Keyword groups
    -- =========================
    local kw_control = {
        ["if"] = true, ["then"] = true, ["else"] = true, ["elseif"] = true,
        ["do"] = true, ["end"] = true, ["for"] = true, ["while"] = true,
        ["repeat"] = true, ["until"] = true, ["break"] = true,
    }

    local kw_decl = {
        ["local"] = true, ["function"] = true, ["return"] = true,
    }

    local kw_logic = {
        ["and"] = true, ["or"] = true, ["not"] = true, ["in"] = true,
    }

    local kw_const = {
        ["nil"] = true, ["true"] = true, ["false"] = true,
    }

    -- =========================
    -- Helpers
    -- =========================
    local function clamp(v, lo, hi)
        return math.max(lo, math.min(hi, v))
    end

    local function safe_sub(s, a, b)
        if a < 1 then a = 1 end
        if b < a then return "" end
        return s:sub(a, b)
    end

    local function expand_tabs(line)
        local col = 1
        local out = {}

        for i = 1, #line do
            local ch = line:sub(i, i)
            if ch == "\t" then
                local spaces = TAB_W - ((col - 1) % TAB_W)
                out[#out + 1] = string.rep(" ", spaces)
                col = col + spaces
            else
                out[#out + 1] = ch
                col = col + 1
            end
        end

        return table.concat(out)
    end

    local function visual_x(line, cx)
        local col = 1
        for i = 1, cx - 1 do
            local ch = line:sub(i, i)
            if ch == "\t" then
                local spaces = TAB_W - ((col - 1) % TAB_W)
                col = col + spaces
            else
                col = col + 1
            end
        end
        return col
    end

    -- =========================
    -- Load file
    -- =========================
    local lines = {}

    if fs.exists(path) then
        local data = fs.read(path)
        if data then
            for line in (data .. "\n"):gmatch("([^\n]*)\n") do
                lines[#lines + 1] = line:gsub("\r$", "")
            end
            if #lines > 0 and lines[#lines] == "" then
                table.remove(lines)
            end
        end
    end

    if #lines == 0 then
        lines = { "" }
    end

    -- =========================
    -- State
    -- =========================
    local cx, cy  = 1, 1          -- raw cursor position
    local scroll  = 0             -- vertical scroll, 0-based
    local scrollx = 1             -- horizontal scroll, 1-based visual column
    local dirty   = false
    local running = true
    local status  = ""

    local function cur_line()
        return lines[cy] or ""
    end

    local function set_line(s)
        lines[cy] = s
        dirty = true
    end

    local function ensure_cursor_visible()
        local max_scroll = math.max(0, #lines - EDIT_H)

        if cy <= scroll then
            scroll = cy - 1
        elseif cy > scroll + EDIT_H then
            scroll = cy - EDIT_H
        end

        scroll = clamp(scroll, 0, max_scroll)

        local vx = visual_x(cur_line(), cx)
        if vx < scrollx then
            scrollx = vx
        elseif vx >= scrollx + W then
            scrollx = vx - W + 1
        end

        if scrollx < 1 then
            scrollx = 1
        end
    end

    -- =========================
    -- Syntax highlighting
    -- =========================
    local function highlight_line(line)
        if not ENABLE_HIGHLIGHT then
            return line
        end

        local out = {}
        local i = 1

        while i <= #line do
            local ch = line:sub(i, i)

            -- comment
            if line:sub(i, i + 1) == "--" then
                out[#out + 1] = COLORS.comment .. line:sub(i) .. RESET
                break

            -- string
            elseif ch == '"' or ch == "'" then
                local q = ch
                local j = i + 1

                while j <= #line do
                    local c = line:sub(j, j)
                    if c == "\\" then
                        if j < #line then
                            j = j + 2
                        else
                            j = j + 1
                        end
                    elseif c == q then
                        break
                    else
                        j = j + 1
                    end
                end

                if j > #line then
                    j = #line
                end

                out[#out + 1] = COLORS.string .. line:sub(i, j) .. RESET
                i = j

            -- number
            elseif ch:match("%d") then
                local j = i
                while j <= #line and line:sub(j, j):match("[%d%.]") do
                    j = j + 1
                end
                out[#out + 1] = COLORS.number .. line:sub(i, j - 1) .. RESET
                i = j - 1

            -- identifier / keyword
            elseif ch:match("[%a_]") then
                local j = i
                while j <= #line and line:sub(j, j):match("[%w_]") do
                    j = j + 1
                end

                local word = line:sub(i, j - 1)

                if kw_control[word] then
                    out[#out + 1] = COLORS.control .. word .. RESET
                elseif kw_decl[word] then
                    out[#out + 1] = COLORS.decl .. word .. RESET
                elseif kw_logic[word] then
                    out[#out + 1] = COLORS.logic .. word .. RESET
                elseif kw_const[word] then
                    out[#out + 1] = COLORS.const .. word .. RESET
                else
                    out[#out + 1] = word
                end

                i = j - 1

            else
                out[#out + 1] = ch
            end

            i = i + 1
        end

        return table.concat(out)
    end

    -- =========================
    -- Draw
    -- =========================
    local function draw()
        putstr(RESET)
        putstr("\27[2J\27[H")

        -- Header
        putstr("\27[1;1H")
        local title = "  edit: " .. path .. (dirty and " [+]" or "")
        local hint  = " ^S save ^Q quit ^T highlight "
        local pad   = string.rep(" ", math.max(0, W - #title - #hint))
        putstr("\27[7m" .. title .. pad .. hint .. "\27[0m")

        -- Text area
        for i = 1, EDIT_H do
            local li = i + scroll
            putstr("\27[" .. (i + 1) .. ";1H")

            if li <= #lines then
                local expanded = expand_tabs(lines[li])
                local visible = safe_sub(expanded, scrollx, scrollx + W - 1)
                local colored = highlight_line(visible)
                putstr(colored .. RESET .. "\27[K")
            else
                putstr("\27[K")
            end
        end

        -- Status bar
        putstr("\27[" .. H .. ";1H")
        local pos  = string.format("  Ln %d/%d  Col %d  ", cy, #lines, cx)
        local spad = string.rep(" ", math.max(0, W - #pos - #status))
        putstr("\27[7m" .. status .. spad .. pos .. "\27[0m")

        -- Cursor
        local vx = visual_x(cur_line(), cx)
        local screen_x = vx - scrollx + 1
        putstr("\27[" .. (cy - scroll + 1) .. ";" .. screen_x .. "H")

        status = ""
    end

    -- =========================
    -- Save
    -- =========================
    local function save()
        local data = table.concat(lines, "\n") .. "\n"
        local ok, err = fs.write(path, data)

        if ok then
            dirty = false
            status = "  saved " .. #data .. " bytes"
        else
            status = "  save failed: " .. tostring(err)
        end
    end

    -- =========================
    -- Main loop
    -- =========================
    while running do
        ensure_cursor_visible()
        draw()

        local key = readkey()

        if key == "UP" then
            cy = clamp(cy - 1, 1, #lines)
            cx = clamp(cx, 1, #cur_line() + 1)

        elseif key == "DOWN" then
            cy = clamp(cy + 1, 1, #lines)
            cx = clamp(cx, 1, #cur_line() + 1)

        elseif key == "LEFT" then
            if cx > 1 then
                cx = cx - 1
            elseif cy > 1 then
                cy = cy - 1
                cx = #cur_line() + 1
            end

        elseif key == "RIGHT" then
            if cx <= #cur_line() then
                cx = cx + 1
            elseif cy < #lines then
                cy = cy + 1
                cx = 1
            end

        elseif key == "HOME" then
            cx = 1

        elseif key == "END" then
            cx = #cur_line() + 1

        elseif key == "\t" or key == "TAB" then
            local l = cur_line()
            set_line(l:sub(1, cx - 1) .. "\t" .. l:sub(cx))
            cx = cx + 1

        elseif key == "\r" or key == "\n" or key == "ENTER" then
            local l = cur_line()
            local before = l:sub(1, cx - 1)
            local after  = l:sub(cx)

            set_line(before)
            table.insert(lines, cy + 1, after)
            cy = cy + 1
            cx = 1

        elseif key == "\127" or key == "\8" or key == "BACKSPACE" then
            if cx > 1 then
                local l = cur_line()
                set_line(l:sub(1, cx - 2) .. l:sub(cx))
                cx = cx - 1
            elseif cy > 1 then
                local prev = lines[cy - 1] or ""
                local l = cur_line()
                table.remove(lines, cy)
                cy = cy - 1
                lines[cy] = prev .. l
                dirty = true
                cx = #prev + 1
            end

        elseif key == "DEL" or key == "DELETE" then
            local l = cur_line()
            if cx <= #l then
                set_line(l:sub(1, cx - 1) .. l:sub(cx + 1))
            elseif cy < #lines then
                local next_line = table.remove(lines, cy + 1)
                lines[cy] = cur_line() .. (next_line or "")
                dirty = true
            end

        elseif key == "\19" then -- ^S
            save()

        elseif key == "\20" then -- ^T
            ENABLE_HIGHLIGHT = not ENABLE_HIGHLIGHT
            status = ENABLE_HIGHLIGHT and "  highlight ON" or "  highlight OFF"

        elseif key == "\17" then -- ^Q
            if dirty then
                status = "  unsaved -- ^Q again to quit"
                ensure_cursor_visible()
                draw()
                if readkey() == "\17" then
                    running = false
                end
            else
                running = false
            end

        elseif #key == 1 and key:byte(1) >= 32 then
            local l = cur_line()
            set_line(l:sub(1, cx - 1) .. key .. l:sub(cx))
            cx = cx + 1
        end
    end

    putstr(RESET .. "\27[2J\27[H")
    putstr("edit: closed " .. path .. "\r\n")
end

local path = ...
if path then
    editor(path)
else
    print("usage: edit(path)")
end