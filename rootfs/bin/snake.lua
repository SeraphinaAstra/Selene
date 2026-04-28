local function snake()
    math.randomseed(os.time and os.time() or 1234)

    local W, H = 40, 20

    local snake = {
        {x=10,y=10},
        {x=9,y=10},
        {x=8,y=10},
    }

    local dir = {x=1,y=0}
    local next_dir = dir

    local food = {x=20,y=10}
    local running = true

    -- ANSI colors
    local RESET = "\27[0m"
    local GREEN = "\27[32m"
    local BRIGHT_GREEN = "\27[92m"
    local RED = "\27[31m"
    local WHITE = "\27[37m"

    local function collide(x,y)
        for _,s in ipairs(snake) do
            if s.x == x and s.y == y then
                return true
            end
        end
        return false
    end

    local function spawn_food()
        while true do
            local f = {
                x = math.random(2, W-1),
                y = math.random(2, H-1)
            }
            if not collide(f.x,f.y) then
                return f
            end
        end
    end

    local function draw()
        putstr(RESET .. "\27[2J\27[H")

        for y=1,H do
            putstr("\27["..y..";1H")

            for x=1,W do
                local ch = " "

                -- WALLS
                if x == 1 or x == W or y == 1 or y == H then
                    ch = WHITE .. "#" .. RESET

                -- FOOD
                elseif x == food.x and y == food.y then
                    ch = RED .. "*" .. RESET

                else
                    for i,s in ipairs(snake) do
                        if s.x == x and s.y == y then
                            if i == 1 then
                                ch = BRIGHT_GREEN .. "@" .. RESET
                            else
                                ch = GREEN .. "o" .. RESET
                            end
                            break
                        end
                    end
                end

                putstr(ch)
            end
        end

        putstr("\27["..(H+1)..";1H")
        putstr(WHITE .. "Score: " .. (#snake-3) .. RESET)
    end

    local function step()
        dir = next_dir

        local head = snake[1]
        local nx = head.x + dir.x
        local ny = head.y + dir.y

        -- WALL collision
        if nx <= 1 or nx >= W or ny <= 1 or ny >= H then
            running = false
            return
        end

        -- SELF collision
        if collide(nx,ny) then
            running = false
            return
        end

        table.insert(snake, 1, {x=nx,y=ny})

        if nx == food.x and ny == food.y then
            food = spawn_food()
        else
            table.remove(snake)
        end
    end

    local function handle_input(k)
        if k == "UP" and dir.y ~= 1 then
            next_dir = {x=0,y=-1}
        elseif k == "DOWN" and dir.y ~= -1 then
            next_dir = {x=0,y=1}
        elseif k == "LEFT" and dir.x ~= 1 then
            next_dir = {x=-1,y=0}
        elseif k == "RIGHT" and dir.x ~= -1 then
            next_dir = {x=1,y=0}
        elseif k == "\17" then
            running = false
        end
    end

    draw()

    while running do
        local key = readkey()

        handle_input(key)
        step()
        draw()
    end

    putstr("\27[2J\27[H")
    print("game over! score:", #snake-3)
end

snake()