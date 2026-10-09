-- Converter test harness for Linux. Native Lua parsers are built from the pinned
-- dependencies; only Windows paths, native-long width and UI locale calls are
-- adapted. This does not exercise the Windows GUI, CASC, MPQ DLLs, or the game.
local source = debug.getinfo(1, 'S').source:sub(2):gsub('\\', '/')
local root = assert(source:match('^(.*)/test/compat/bootstrap.lua$'),
    'Load bootstrap.lua by its absolute path')
local runtime = assert(os.getenv('W2L_TEST_RUNTIME'), 'Set W2L_TEST_RUNTIME')
package.cpath = runtime .. '/?.so;' .. package.cpath
package.path = root .. '/script/?.lua;' .. root .. '/script/?/init.lua;' .. package.path
local fs = require 'bee.filesystem'
local native_path = fs.path
local native_exists = fs.exists
local native_pairs = fs.pairs
local native_open = io.open
local cache = {}

local function slash(path)
    return tostring(path):gsub('\\', '/')
end

local function resolve(path)
    path = slash(path)
    if cache[path] then return cache[path] end
    if native_exists(native_path(path)) then return path end
    local base = path:sub(1, 1) == '/' and '/' or '.'
    for part in path:gmatch('[^/]+') do
        local nextpath = native_path(base) / part
        if not native_exists(nextpath) and part ~= '.' and part ~= '..'
            and native_exists(native_path(base)) then
            for candidate in native_pairs(native_path(base)) do
                if candidate:filename():string():lower() == part:lower() then
                    nextpath = candidate
                    break
                end
            end
        end
        base = nextpath:string()
    end
    cache[path] = base
    return base
end

function io.open(path, mode)
    return native_open(resolve(path), mode)
end
function io.load(path)
    local f, err = io.open(path, 'rb')
    if not f then return false, err end
    local content = f:read 'a'
    f:close()
    return (content:gsub('^\239\187\191', ''))
end
function io.save(path, content)
    -- Existing tests update config.global in memory. Keep the real config file.
    if slash(path) == root .. '/config.ini' then return true end
    cache[slash(path)] = nil
    local f, err = io.open(path, 'wb')
    if not f then return false, err end
    f:write(content)
    f:close()
    return true
end
function fs.path(path) return native_path(slash(path)) end
for _, name in ipairs {'exists', 'is_directory', 'is_regular_file',
    'create_directory', 'create_directories', 'pairs', 'remove', 'remove_all'} do
    local native = fs[name]
    fs[name] = function(path, ...)
        return native(native_path(resolve(path)), ...)
    end
end

if string.packsize('l') ~= 4 then
    local pack, unpack, packsize = string.pack, string.unpack, string.packsize
    local function format(fmt) return (fmt:gsub('l', 'i4'):gsub('L', 'I4')) end
    function string.pack(fmt, ...) return pack(format(fmt), ...) end
    function string.unpack(fmt, ...) return unpack(format(fmt), ...) end
    function string.packsize(fmt) return packsize(format(fmt)) end
end
package.preload['ffi.unicode'] = function()
    return setmetatable({}, { __index = function() return function(s) return s end end })
end
package.preload['ffi.language'] = function() return function() return 'enUS' end end
fs.current_path(native_path(root .. '/script'))
return { root = root, fs = fs, resolve = resolve,
    core = function() return require 'backend.sandbox_core' end }
