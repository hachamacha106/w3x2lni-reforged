-- Windows: bin\w3x2lni-lua.exe make\import-game-data.lua <raw-directory> <dataset> [--allow-partial]
-- The raw directory contains Units, Doodads, UI and Scripts, optionally Custom_V1.
local source = debug.getinfo(1, 'S').source:sub(2):gsub('\\', '/')
local repository = source:match('^(.*)/make/import%-game%-data.lua$') or '.'
package.path = repository .. '/script/?.lua;' .. repository .. '/script/?/init.lua;' .. package.path
local test_runtime = os.getenv('W2L_TEST_RUNTIME')
if test_runtime then package.cpath = test_runtime .. '/?.so;' .. package.cpath end
package.cpath = repository .. '/bin/?.dll;' .. package.cpath
local fs = require 'bee.filesystem'
local original_directory = fs.current_path()
repository = fs.absolute(fs.path(repository))
package.path = repository:string() .. '/script/?.lua;'
    .. repository:string() .. '/script/?/init.lua;' .. package.path
package.cpath = repository:string() .. '/bin/?.dll;' .. package.cpath
if test_runtime then
    dofile(repository:string():gsub('\\', '/') .. '/test/compat/bootstrap.lua')
else
    fs.current_path(repository / 'script')
    require 'utility'
end

local input_argument, dataset = arg[1], arg[2]
if not input_argument or not dataset then
    io.stderr:write('Usage: import-game-data.lua <raw-directory> <dataset-name> [--allow-partial] [--build <build>] [--locale <locale>]\n')
    os.exit(2)
end
assert(dataset:match '^[%w_.%-]+$' and dataset ~= '.' and dataset ~= '..', 'Invalid dataset name')
local options = {name = dataset}
local i = 3
while i <= #arg do
    if arg[i] == '--allow-partial' then
        options.allow_partial = true
    elseif arg[i] == '--build' or arg[i] == '--locale' then
        local key = arg[i] == '--build' and 'game_build' or 'locale'
        i = i + 1
        options[key] = assert(arg[i], 'Missing value for ' .. arg[i - 1])
    else
        error('Unknown argument: ' .. tostring(arg[i]))
    end
    i = i + 1
end
local input = fs.path(input_argument)
if not input:is_absolute() then input = fs.absolute(original_directory / input) end
assert(fs.is_directory(input), 'Raw archive directory does not exist: ' .. input:string())
local output = repository / 'data' / dataset
local function read_bytes(file)
    local handle = io.open(file:string(), 'rb')
    if not handle then return nil end
    local content = handle:read 'a'
    handle:close()
    return content
end
function options.loader(name) return read_bytes(input / name) end
local core = require 'backend.sandbox_core'
local w2l = core()
w2l:set_messager(function(kind, ...)
    if kind == 'text' then print(...) end
end)
options.fixer = w2l:parse_lni(assert(io.load(repository / 'script/core/defined/metadata.ini')))
local result = require 'prebuilt.directory'.build(w2l, options)
print(result.report)
if not result.built then os.exit(2) end
if not result.complete and fs.exists(output / 'version') then
    error('An incomplete QA import cannot overwrite a selectable dataset. Choose a different dataset name.')
end

-- Stage raw bytes too before writing anything. This also preserves extra files
-- not yet understood by the current converter, including new game definitions.
local staged = {}
local function scan(folder, relative)
    for entry in fs.pairs(folder) do
        local leaf = entry:filename():string()
        local name = relative == '' and leaf or (relative .. '/' .. leaf)
        if fs.is_directory(entry) then
            scan(entry, name)
        else
            local normalized = name:gsub('\\', '/'):lower()
            assert(not staged['mpq/' .. normalized], 'Duplicate raw path ignoring case: ' .. name)
            staged['mpq/' .. normalized] = assert(read_bytes(entry))
        end
    end
end
scan(input, '')
for filename, content in pairs(result.files) do staged[filename] = content end
local filenames = {}
for filename in pairs(staged) do
    if filename ~= 'version' then filenames[#filenames + 1] = filename end
end
table.sort(filenames)
if staged.version then filenames[#filenames + 1] = 'version' end
for _, filename in ipairs(filenames) do
    local destination = output / filename
    -- Avoid touching raw files when rebuilding a dataset in place.
    if read_bytes(destination) ~= staged[filename] then
        fs.create_directories(destination:parent_path())
        local file = assert(io.open(destination:string(), 'wb'))
        assert(file:write(staged[filename]))
        assert(file:close())
    end
end
print(('Saved %d files to %s'):format(#filenames, output:string()))
if not result.complete then
    print('Partial QA dataset saved without a selectable version marker.')
end
