-- /bin/edit.lua
-- Selene fullscreen text editor

local function editor(path)
    local fs = require("nyx.fs")

    -- ========================= Config =========================
    local W, H = 80, 24
    local EDIT_H = H - 2
    local TAB_W = 4
    local ENABLE_HIGHLIGHT = true

    -- ========================= ANSI =========================
    local RESET = "\27[0m"
    local function C(code) return "\27[" .. code .. "m" end

    local COLORS = {
        control = C("34"),   -- blue
        decl    = C("35"),   -- magenta
        logic   = C("36"),   -- cyan
        const   = C("32"),   -- green
        string  = C("33"),   -- yellow
        number  = C("31"),   -- red
        comment = C("90"),   -- gray
    }

    -- ========================= Keywords =========================
    local kw_control = { ["if"]=true, ["then"]=true, ["else"]=true, ["elseif"]=true,
                         ["do"]=true, ["end"]=true, ["for"]=true, ["while"]=true,
                         ["repeat"]=true, ["until"]=true, ["break"]=true }

    local kw_decl    = { ["local"]=true, ["function"]=true, ["return"]=true }
    local kw_logic   = { ["and"]=true, ["or"]=true, ["not"]=true, ["in"]=true }
    local kw_const   = { ["nil"]=true, ["true"]=true, ["false"]=true }

    -- ========================= Helpers =========================
    local function clamp(v, lo, hi)
        return math.max(lo, math.min(hi, v))
    end

    local function safe_sub(s, start, finish)
        if start < 1 then start = 1 end
        if finish < start then return "" end
        return s:sub(start, finish)
    end

    local function expand_tabs(line)
        local col = 1
        local out = {}
        for i = 1, #line do
            if line:sub(i,i) == "\t" then
                local spaces = TAB_W - ((col - 1) % TAB_W)
                out[#out+1] = string.rep(" ", spaces)
                col = col + spaces
            else
                out[#out+1] = line:sub(i,i)
                col = col + 1
            end
        end
        return table.concat(out)
    end

    local function visual_x(line, cx)
        local col = 1
        for i = 1, cx - 1 do
            if line:sub(i,i) == "\t" then
                col = col + TAB_W - ((col-1) % TAB_W)
            else
                col = col + 1
            end
        end
        return col
    end

    -- ========================= Load File =========================
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
    if #lines == 0 then lines = {""} end

    -- ========================= State =========================
    local cx, cy = 1, 1        -- cursor position (1-based)
    local scroll = 0           -- vertical scroll
    local scrollx = 1          -- horizontal scroll
    local dirty = false
    local running = true
    local status = ""

    local function cur_line() return lines[cy] or "" end
    local function set_line(s) lines[cy] = s; dirty = true end

    local function ensure_cursor_visible()
        local visible_lines = EDIT_H   -- should be 22 if H=24

        local max_scroll = math.max(0, #lines - visible_lines)

        -- Scroll much more responsively — keep cursor in the middle-third of the screen
        local top_margin = 3
        local bottom_margin = 3

        if cy < scroll + top_margin then
            scroll = cy - top_margin
        elseif cy > scroll + visible_lines - bottom_margin then
            scroll = cy - (visible_lines - bottom_margin)
        end

        scroll = clamp(scroll, 0, max_scroll)

        -- Horizontal scrolling
        local vx = visual_x(cur_line(), cx)
        if vx < scrollx then
            scrollx = vx
        elseif vx >= scrollx + W - 4 then        -- start scrolling a bit earlier horizontally too
            scrollx = vx - W + 5
        end

        scrollx = clamp(scrollx, 1, 999)
    end

    -- ========================= Highlighting (Fixed) =========================
    local function highlight_line(line)
        if not ENABLE_HIGHLIGHT then return line end

        local out = {}
        local i = 1

        while i <= #line do
            local ch = line:sub(i, i)

            -- Comment
            if line:sub(i, i+1) == "--" then
                out[#out+1] = COLORS.comment .. line:sub(i) .. RESET
                break

            -- String
            elseif ch == '"' or ch == "'" then
                local q = ch
                local j = i + 1
                while j <= #line do
                    local c = line:sub(j,j)
                    if c == "\\" and j < #line then
                        j = j + 2
                    elseif c == q then
                        j = j + 1
                        break
                    else
                        j = j + 1
                    end
                end
                out[#out+1] = COLORS.string .. line:sub(i, j) .. RESET
                i = j

            -- Number
            elseif ch:match("%d") then
                local j = i
                while j <= #line and line:sub(j,j):match("[%d%.]") do j = j + 1 end
                out[#out+1] = COLORS.number .. line:sub(i, j-1) .. RESET
                i = j - 1

            -- Keyword / Identifier
            elseif ch:match("[%a_]") then
                local j = i
                while j <= #line and line:sub(j,j):match("[%w_]") do j = j + 1 end
                local word = line:sub(i, j-1)

                if kw_control[word] then
                    out[#out+1] = COLORS.control .. word .. RESET
                elseif kw_decl[word] then
                    out[#out+1] = COLORS.decl .. word .. RESET
                elseif kw_logic[word] then
                    out[#out+1] = COLORS.logic .. word .. RESET
                elseif kw_const[word] then
                    out[#out+1] = COLORS.const .. word .. RESET
                else
                    out[#out+1] = word
                end
                i = j - 1

            else
                out[#out+1] = ch
            end

            i = i + 1
        end

        return table.concat(out)
    end

    -- ========================= Draw =========================
    local function draw()
        putstr(RESET .. "\27[2J\27[H")

        -- Header
        local title = " edit: " .. path .. (dirty and " [+]" or "")
        local hint  = " ^S:save ^Q:quit ^T:highlight "
        local pad   = string.rep(" ", math.max(0, W - #title - #hint))
        putstr("\27[7m" .. title .. pad .. hint .. "\27[0m")

        -- Text content
        for i = 1, EDIT_H do
            local li = i + scroll
            putstr("\27[" .. (i + 1) .. ";1H")
            if li <= #lines then
                local expanded = expand_tabs(lines[li])
                local visible = safe_sub(expanded, scrollx, scrollx + W - 1)
                putstr(highlight_line(visible) .. RESET .. "\27[K")
            else
                putstr("\27[K")
            end
        end

        -- Status bar
        local pos = string.format(" Ln %d/%d  Col %d ", cy, #lines, cx)
        local spad = string.rep(" ", math.max(0, W - #status - #pos))
        putstr("\27[" .. H .. ";1H\27[7m" .. status .. spad .. pos .. "\27[0m")

        -- Place cursor
        local vx = visual_x(cur_line(), cx)
        local screen_x = vx - scrollx + 1
        putstr("\27[" .. (cy - scroll + 1) .. ";" .. screen_x .. "H")
        status = ""
    end

    -- ========================= Save =========================
    local function save()
        local data = table.concat(lines, "\n") .. "\n"
        local ok, err = fs.write(path, data)
        if ok then
            dirty = false
            status = "Saved " .. #data .. " bytes"
        else
            status = "Save failed: " .. tostring(err)
        end
    end

    -- ========================= Main Loop =========================
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
            if cx > 1 then cx = cx - 1
            elseif cy > 1 then cy = cy - 1; cx = #cur_line() + 1 end
        elseif key == "RIGHT" then
            if cx <= #cur_line() then cx = cx + 1
            elseif cy < #lines then cy = cy + 1; cx = 1 end
        elseif key == "HOME" then cx = 1
        elseif key == "END"  then cx = #cur_line() + 1

        elseif key == "\t" or key == "TAB" then
            local l = cur_line()
            set_line(l:sub(1, cx-1) .. "\t" .. l:sub(cx))
            cx = cx + 1

        elseif key == "\r" or key == "\n" or key == "ENTER" then
            local l = cur_line()
            local before = l:sub(1, cx-1)
            local after  = l:sub(cx)
            set_line(before)
            table.insert(lines, cy + 1, after)
            cy = cy + 1
            cx = 1

        elseif key == "\127" or key == "\8" or key == "BACKSPACE" then
            if cx > 1 then
                local l = cur_line()
                set_line(l:sub(1, cx-2) .. l:sub(cx))
                cx = cx - 1
            elseif cy > 1 then
                local prev = lines[cy-1] or ""
                local curr = cur_line()
                table.remove(lines, cy)
                cy = cy - 1
                lines[cy] = prev .. curr
                dirty = true
                cx = #prev + 1
            end

        elseif key == "DEL" or key == "DELETE" then
            local l = cur_line()
            if cx <= #l then
                set_line(l:sub(1, cx-1) .. l:sub(cx+1))
            elseif cy < #lines then
                local nextl = table.remove(lines, cy + 1) or ""
                lines[cy] = cur_line() .. nextl
                dirty = true
            end

        elseif key == "\19" then -- Ctrl+S
            save()
        elseif key == "\20" then -- Ctrl+T
            ENABLE_HIGHLIGHT = not ENABLE_HIGHLIGHT
            status = ENABLE_HIGHLIGHT and " Highlight ON" or " Highlight OFF"
        elseif key == "\17" then -- Ctrl+Q
            if dirty then
                status = " Unsaved! ^Q again to quit"
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

    -- Clean exit
    putstr(RESET .. "\27[2J\27[H")
    putstr("edit: closed " .. path .. "\r\n")
end

-- ========================= Entry Point =========================
local path = ...
if not path then
    print("usage: edit <filename>")
    return
end

editor(path)