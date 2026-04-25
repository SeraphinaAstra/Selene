-- nyx/shell.lua
-- Selene interactive REPL
-- Minimal: single line input, error recovery, that's it

while true do
    io.write("> ")
    io.flush()

    local line = io.read("l")
    if not line then break end

    if #line > 0 then
        local fn, err = load(line)
        if fn then
            local ok, res = pcall(fn)
            if not ok then
                print("Error: " .. tostring(res))
            elseif res ~= nil then
                print(res)
            end
        else
            print("Error: " .. tostring(err))
        end
    end
end