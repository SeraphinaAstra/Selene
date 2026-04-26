-- from REPL: echo("hello") passes one string arg
-- from scripts: echo("a", "b", "c") joins with spaces
local args = {...}
if #args == 0 then
    print("")
    return
end
local parts = {}
for _, v in ipairs(args) do
    table.insert(parts, tostring(v))
end
print(table.concat(parts, " "))