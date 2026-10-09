-- Exercise the actual core frontend/backend/save pipeline on extracted MPQ
-- members. The companion Python test uses real StormLib for extraction/repack.
-- Windows GUI and Windows FFI execution are separate acceptance checks.
local source = debug.getinfo(1, 'S').source:sub(2):gsub('\\', '/')
local context = dofile(source:match('^(.*)/[^/]+$') .. '/bootstrap.lua')
local fs = context.fs
local input_directory = assert(arg[1], 'Input directory required')
local output_directory = assert(arg[2], 'Output directory required')
local input_mode = assert(arg[3], 'Input mode required')
local mode = assert(arg[4], 'Output mode required')
local profile = arg[5] or 'editor'
local report_file = assert(arg[6], 'Report path required')
assert(input_directory:sub(1, 1) == '/' and output_directory:sub(1, 1) == '/')
assert(input_mode == 'obj' or input_mode == 'lni')
assert(mode == 'obj' or mode == 'lni' or mode == 'slk')
assert(profile == 'editor' or profile == 'default' or profile == 'obfuscated')

local function archive(directory, storage)
    local files, cases = {}, {}
    local function read_tree(folder, prefix)
        for entry in fs.pairs(fs.path(folder)) do
            local leaf = entry:filename():string()
            local name = prefix == '' and leaf or prefix .. '\\' .. leaf
            if fs.is_directory(entry) then
                read_tree(entry:string(), name)
            else
                local key = name:lower()
                assert(not files[key], 'Duplicate archive path ignoring case: ' .. name)
                local file = assert(io.open(entry:string(), 'rb'))
                files[key] = assert(file:read 'a')
                assert(file:close())
                cases[key] = name
            end
        end
    end
    if directory then read_tree(directory, '') end
    local object = {}
    function object:get(name) return files[name:lower()] end
    function object:has(name) return files[name:lower()] ~= nil end
    function object:set(name, content)
        files[name:lower()] = content
        cases[name:lower()] = name
    end
    function object:remove(name) files[name:lower()] = nil end
    function object:get_type() return storage end
    function object:list_file()
        local names = {}
        for key in pairs(files) do names[#names + 1] = cases[key] end
        table.sort(names)
        return names
    end
    function object:number_of_files() return #self:list_file() end
    setmetatable(object, {__pairs = function()
        local key
        return function()
            key = next(files, key)
            if key then return cases[key], files[key] end
        end
    end})
    return object
end

local logs, errors, warnings = {}, 0, 0
local w2l = context.core()()
local lang = require 'share.lang'
lang:set_lang 'enUS'
w2l:set_messager {report = function(kind, level, message, detail)
    if level == 1 then errors = errors + 1 end
    if level == 2 then warnings = warnings + 1 end
    logs[#logs + 1] = ('[%s:%s] %s%s'):format(tostring(level), tostring(kind),
        tostring(message), detail and ('\n' .. tostring(detail)) or '')
end}
local setting = {
    mode = mode, data = 'warcraft-current', data_meta = '${DATA}',
    data_ui = '${DATA}', data_wes = '${DATA}', read_slk = true,
}
if profile == 'editor' then
    setting.remove_we_only = false
    setting.optimize_jass = false
elseif profile == 'obfuscated' then
    setting.confused = true
    setting.confusion = 'ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789_'
end
w2l:set_setting(setting)
w2l.input_mode = input_mode
w2l.input_ar = archive(input_directory, input_mode == 'lni' and 'dir' or 'mpq')
w2l.output_ar = archive(nil, mode == 'lni' and 'dir' or 'mpq')
local ok, failure = xpcall(function()
    w2l:frontend()
    w2l:backend()
    w2l:save()
end, debug.traceback)
local report = assert(io.open(report_file, 'wb'))
report:write(('Input: %s\nOutput mode: %s\nProfile: %s\nErrors: %d\nWarnings: %d\n\n')
    :format(input_mode, mode, profile, errors, warnings))
report:write(table.concat(logs, '\n\n'))
if not ok then report:write('\n\nFAILURE\n' .. tostring(failure)) end
report:close()
assert(ok, failure)
assert(errors == 0, ('Conversion reported %d errors; see %s'):format(errors, report_file))
local names = w2l.output_ar:list_file()
for _, name in ipairs(names) do
    local destination = fs.path(output_directory .. '/' .. name:gsub('\\', '/'))
    fs.create_directories(destination:parent_path())
    local file = assert(io.open(destination:string(), 'wb'))
    assert(file:write(w2l.output_ar:get(name)))
    assert(file:close())
end
print(('PASS real map pipeline: %s -> %s (%s), %d output members, %d errors, %d warnings')
    :format(input_mode, mode, profile, #names, errors, warnings))
