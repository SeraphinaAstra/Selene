local function snake()

    math.randomseed(12345)

    local W, H = 40, 20

    local GREEN = "\27[32m"
    local BRIGHT = "\27[92m"
    local RED = "\27[31m"
    local RESET = "\27[0m"

    local function at(x,y)
        return "\27["..y..";"..x.."H"
    end

    local CLEAR = "\27[2J\27[H"

    -- =========================
    -- STATE
    -- =========================
    local snake = {}
    local food = nil

    local dir = {x=1,y=0}
    local next_dir = dir

    local running = true

    local SPEED = 6
    local tick = 0

    -- =========================
    -- FOOD SPAWN (SAFE)
    -- =========================
    local function spawn_food()

        local occ = {}

        for _, s in ipairs(snake) do
            occ[s.y] = occ[s.y] or {}
            occ[s.y][s.x] = true
        end

        local free = {}

        for y = 2, H-1 do
            for x = 2, W-1 do
                if not (occ[y] and occ[y][x]) then
                    free[#free+1] = {x=x,y=y}
                end
            end
        end

        return free[math.random(#free)] or {x=2,y=2}
    end

    -- =========================
    -- RESET
    -- =========================
    local function reset()

        snake = {
            {x=10,y=10},
            {x=9,y=10},
            {x=8,y=10},
        }

        dir = {x=1,y=0}
        next_dir = dir
        running = true

        food = spawn_food()

        putstr(CLEAR)
    end

    -- =========================
    -- COLLISION
    -- =========================
    local function collide(x,y)
        for _, s in ipairs(snake) do
            if s.x == x and s.y == y then
                return true
            end
        end
        return false
    end

    -- =========================
    -- STEP
    -- =========================
    local function step()

        dir = next_dir

        local head = snake[1]
        local nx = head.x + dir.x
        local ny = head.y + dir.y

        if nx <= 1 or nx >= W or ny <= 1 or ny >= H then
            running = false
            return
        end

        if collide(nx, ny) then
            running = false
            return
        end

        table.insert(snake, 1, {x=nx,y=ny})

        if food and nx == food.x and ny == food.y then
            food = spawn_food()
        else
            table.remove(snake)
        end
    end

    -- =========================
    -- INPUT
    -- =========================
    local function input(k)

        if k == "UP" and dir.y ~= 1 then
            next_dir = {x=0,y=-1}
        elseif k == "DOWN" and dir.y ~= -1 then
            next_dir = {x=0,y=1}
        elseif k == "LEFT" and dir.x ~= 1 then
            next_dir = {x=-1,y=0}
        elseif k == "RIGHT" and dir.x ~= -1 then
            next_dir = {x=1,y=0}
        elseif k == "R" or k == "r" then
            reset()
        elseif k == "Q" or k == "q" then
            return "quit"
        end
    end

    -- =========================
    -- FULL SAFE RENDER (NO GHOSTING)
    -- =========================
    local function draw()

        putstr("\27[H")

        -- border + grid fully overwritten every frame
        for y = 1, H do
            for x = 1, W do

                local ch = " "

                if x == 1 or x == W or y == 1 or y == H then
                    ch = "#"

                elseif food and x == food.x and y == food.y then
                    ch = RED .. "*" .. RESET

                else
                    for i, s in ipairs(snake) do
                        if s.x == x and s.y == y then
                            ch = (i == 1)
                                and (BRIGHT .. "@" .. RESET)
                                or (GREEN .. "o" .. RESET)
                            break
                        end
                    end
                end

                putstr(at(x,y) .. ch)
            end
        end

        putstr(at(1,H+1) ..
            "Score: " .. (#snake - 3) ..
            "   (R restart, Q quit)")
    end

    -- =========================
    -- START
    -- =========================
    reset()
    draw()

    -- =========================
    -- LOOP
    -- =========================
    while true do

        if kbhit() then
            local k = readkey()
            local res = input(k)
            if res == "quit" then
                putstr("\27[2J\27[H")
                return
            end
        end

        tick = tick + 1

        if tick >= SPEED then
            tick = 0

            if running then
                step()
                draw()
            else
                putstr(at(1,H+2) .. "GAME OVER - R restart / Q quit")
            end
        end

        for i = 1, 200000 do end
    end
end

snake()