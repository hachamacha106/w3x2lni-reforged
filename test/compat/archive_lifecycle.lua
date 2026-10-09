-- Exercises the actual Lua CASC wrapper and Warcraft archive selector using
-- explicit mocks for FFI/DLL, Unicode, MPQ, version, config and filesystem APIs.
-- It does not load native Windows DLLs or prove their ABI/game compatibility.
-- Run: lua /absolute/path/to/w3x2lni/test/compat/archive_lifecycle.lua
local source = debug.getinfo(1, 'S').source:sub(2):gsub('\\', '/')
local root = assert(source:match('^(.*)/test/compat/archive_lifecycle.lua$'),
    'Run archive_lifecycle.lua by its absolute path')

local function load_actual(relative, dependencies)
    local environment = setmetatable({require = function(name)
        return assert(dependencies[name], 'Unexpected dependency: ' .. name)
    end}, {__index = _G})
    return assert(loadfile(root .. '/script/' .. relative, 't', environment))()
end

local path_mt = {}
path_mt.__index = path_mt
local function path(value) return setmetatable({value = value}, path_mt) end
function path_mt:string() return self.value end
function path_mt:__tostring() return self.value end
function path_mt:__div(suffix) return path(self.value .. '/' .. suffix) end

local directories = {
    ['/game/old'] = true,
    ['/game/modern'] = true,
    ['/game/pre_reforged_casc'] = true,
    ['/game/failed'] = true,
    ['/game/no_locale'] = true,
    ['/game/unknown'] = true,
}
local executables = {
    ['/game/old/Game.dll'] = {major = 1, minor = 27, revision = 1},
    ['/game/modern/_retail_/x86_64/Warcraft III.exe'] = {major = 3, minor = 0, revision = 1},
    ['/game/pre_reforged_casc/War3.exe'] = {major = 1, minor = 29, revision = 2},
    ['/game/failed/Warcraft III.exe'] = {major = 3, minor = 0, revision = 1},
    ['/game/no_locale/x86_64/Warcraft III.exe'] = {major = 3, minor = 0, revision = 1},
}
local filesystem = {
    exists = function(value) return executables[value:string()] ~= nil end,
    is_directory = function(value) return directories[value:string()] == true end,
}

local locale_prefix = 'war3.w3mod:_locales\\enUS.w3mod:'
local stores = {
    ['/game/modern'] = {files = {
        [locale_prefix .. 'config.txt'] = 'LANGID=0x00000409',
        [locale_prefix .. 'data.txt'] = 'modern localized data',
        ['war3.w3mod:data.txt'] = 'modern base data',
        ['war3.w3mod:base.txt'] = 'modern base only',
        ['war3.w3mod:read_failure.txt'] = 'unreadable',
    }},
    ['/game/pre_reforged_casc'] = {files = {
        [locale_prefix .. 'config.txt'] = 'LANGID=0x00000409',
        ['war3.w3mod:data.txt'] = 'pre-reforged CASC data',
    }},
    ['/game/no_locale'] = {files = {['war3.w3mod:data.txt'] = 'no locale data'}},
}
local storage_handles, file_handles = {}, {}
local next_handle = 100
local last_storage
local function allocate()
    next_handle = next_handle + 1
    return next_handle
end

local dll = {}
function dll.CascOpenStorage(wide_path, flags, output)
    assert(flags == 0 and wide_path:sub(1, 5) == 'wide:')
    local name = wide_path:sub(6)
    local store = stores[name]
    if not store then return false end
    local handle = allocate()
    storage_handles[handle] = {name = name, store = store, close_count = 0}
    output[0] = handle
    last_storage = handle
    return true
end
function dll.CascCloseStorage(handle)
    assert(type(handle) == 'number', 'Storage closer needs the handle, not an output pointer')
    local storage = assert(storage_handles[handle], 'Wrong handle type passed to CascCloseStorage')
    assert(storage.close_count == 0, 'Storage closed more than once')
    storage.close_count = storage.close_count + 1
    return true
end
function dll.CascOpenFile(storage_handle, name, locale, flags, output)
    local storage = assert(storage_handles[storage_handle])
    assert(storage.close_count == 0, 'Read attempted through a closed CASC storage')
    assert(locale == 0 and flags == 0)
    local content = storage.store.files[name]
    if content == nil then return false end
    local handle = allocate()
    file_handles[handle] = {name = name, content = content, close_count = 0}
    output[0] = handle
    return true
end
function dll.CascGetFileSize(handle, high)
    local file = assert(file_handles[handle])
    assert(file.close_count == 0)
    high[0] = 0
    return #file.content
end
function dll.CascReadFile(handle, buffer, requested, count)
    local file = assert(file_handles[handle])
    assert(file.close_count == 0)
    if file.name == 'war3.w3mod:read_failure.txt' then return false end
    buffer.content = file.content:sub(1, requested)
    count[0] = #buffer.content
    return true
end
function dll.CascCloseFile(handle)
    local file = assert(file_handles[handle], 'A storage handle was incorrectly sent to CascCloseFile')
    assert(file.close_count == 0, 'File closed more than once')
    file.close_count = file.close_count + 1
    return true
end

local declarations
local ffi = {
    cdef = function(value) declarations = value end,
    load = function(name) assert(name == 'casclib'); return dll end,
    new = function(type, value)
        if type == 'char[?]' then return {size = value} end
        assert(type == 'uint32_t[1]' or type == 'long[1]' or type == 'unsigned long[1]')
        return {[0] = value or 0}
    end,
    string = function(buffer, size)
        assert(size <= buffer.size)
        return buffer.content:sub(1, size)
    end,
}
local loaded_dlls = 0
local casc = load_actual('ffi/casclib.lua', {
    ffi = ffi,
    ['ffi.loaddll'] = function(name) assert(name == 'casclib'); loaded_dlls = loaded_dlls + 1 end,
    ['ffi.unicode'] = {u2w = function(value) return 'wide:' .. value end},
    ['bee.filesystem'] = filesystem,
})
assert(loaded_dlls == 1)
assert(declarations:find('CascCloseStorage%(uint32_t hStorage%)'),
    'CascCloseStorage declaration must receive a scalar storage handle')

-- File handles and storage handles require distinct close calls, each once.
local archive = assert(casc.open('/game/modern'))
local handle = archive.handle
local file = assert(archive:open_file('war3.w3mod:base.txt'))
local file_handle = file.handle
assert(file:read() == 'modern base only')
file:close()
file:close()
assert(file_handles[file_handle].close_count == 1)
assert(storage_handles[handle].close_count == 0)
assert(archive:load_file('war3.w3mod:read_failure.txt') == nil)
assert(archive:has_file(locale_prefix .. 'config.txt'))
assert(not archive:has_file('missing.txt'))
archive:close()
archive:close()
assert(storage_handles[handle].close_count == 1 and archive.handle == 0)
assert(archive:load_file('war3.w3mod:base.txt') == nil)
assert(archive:open_file('war3.w3mod:base.txt') == nil)
assert(not archive:has_file('war3.w3mod:base.txt'))

local auto_handle
do
    local auto <close> = assert(casc.open('/game/modern'))
    auto_handle = auto.handle
end
assert(storage_handles[auto_handle].close_count == 1)
do
    local auto <close> = assert(casc.open('/game/modern'))
    auto_handle = auto.handle
    auto:close()
end
assert(storage_handles[auto_handle].close_count == 1)
assert(casc.open('/game/failed') == nil)

local mpq_handles = {}
local mpq_files = {
    ['/game/old/War3Patch.mpq'] = {['config.txt'] = 'LANGID=0x00000409', ['data.txt'] = 'old patch data'},
    ['/game/old/War3.mpq'] = {['data.txt'] = 'old base data', ['old_only.txt'] = 'old only data'},
}
local stormlib = {open = function(filename, readonly)
    assert(readonly == true)
    local files = mpq_files[filename:string()]
    if not files then return nil end
    local mpq = {close_count = 0}
    function mpq:close()
        assert(self.close_count == 0, 'MPQ closed more than once')
        self.close_count = self.close_count + 1
    end
    function mpq:has_file(name)
        assert(self.close_count == 0, 'Read attempted from a previously closed MPQ')
        return files[name] ~= nil
    end
    function mpq:load_file(name)
        assert(self.close_count == 0, 'Read attempted from a previously closed MPQ')
        return files[name]
    end
    mpq_handles[#mpq_handles+1] = mpq
    return mpq
end}

local war3 = load_actual('share/war3.lua', {
    ['ffi.file_version'] = function(filename) return assert(executables[filename]) end,
    ['ffi.stormlib'] = stormlib,
    ['ffi.casclib'] = casc,
    ['share.config'] = {global = {lang = 'enUS'}},
    ['bee.filesystem'] = filesystem,
})
local function clean_state()
    for _, key in ipairs {'mpqs', 'casc', 'casc_paths', 'name', 'ver', 'reforge'} do
        assert(war3[key] == nil, 'Stale archive state: ' .. key)
    end
    assert(war3:readfile('data.txt') == nil)
end

war3:close()
clean_state()
assert(war3:open(path('/game/old')))
assert(war3.name == 'enUS-1.27.1' and not war3.reforge)
assert(war3:readfile('data.txt') == 'old patch data')
assert(war3:readfile('old_only.txt') == 'old only data')
assert(#mpq_handles == 2)

-- MPQ -> CASC: old MPQs must close and cannot take precedence on later reads.
assert(war3:open(path('/game/modern')))
assert(mpq_handles[1].close_count == 1 and mpq_handles[2].close_count == 1)
assert(war3.mpqs == nil and war3.reforge == true and war3.name == 'enUS-3.0.1')
assert(war3:readfile('data.txt') == 'modern localized data')
assert(war3:readfile('base.txt') == 'modern base only')
assert(war3:readfile('old_only.txt') == nil)
local modern_handle = war3.casc.handle

-- CASC -> MPQ clears Reforged/version/path state and closes the storage once.
assert(war3:open(path('/game/old')))
assert(storage_handles[modern_handle].close_count == 1)
assert(war3.casc == nil and war3.casc_paths == nil and not war3.reforge)
assert(war3.name == 'enUS-1.27.1' and war3.ver.major == 1)
assert(war3:readfile('data.txt') == 'old patch data')
assert(war3:open(path('/game/modern')))
assert(mpq_handles[3].close_count == 1 and mpq_handles[4].close_count == 1)

-- A failed CASC open releases the preceding storage and leaves no read path.
modern_handle = war3.casc.handle
assert(war3:open(path('/game/failed')) == false)
assert(storage_handles[modern_handle].close_count == 1)
clean_state()
war3:close()
war3:close()

-- A storage with no supported locale is closed immediately, also after MPQ.
assert(war3:open(path('/game/old')))
assert(war3:open(path('/game/no_locale')) == false)
assert(storage_handles[last_storage].name == '/game/no_locale')
assert(storage_handles[last_storage].close_count == 1)
assert(mpq_handles[5].close_count == 1 and mpq_handles[6].close_count == 1)
clean_state()

-- Reopening modern -> pre-Reforged CASC resets the Reforged flag as well.
assert(war3:open(path('/game/modern')))
modern_handle = war3.casc.handle
assert(war3:open(path('/game/pre_reforged_casc')))
assert(storage_handles[modern_handle].close_count == 1)
assert(not war3.reforge and war3.name == 'enUS-1.29.2')
assert(war3:readfile('data.txt') == 'pre-reforged CASC data')
local previous_handle = war3.casc.handle
assert(war3:open(path('/game/unknown')) == false)
assert(storage_handles[previous_handle].close_count == 1)
clean_state()
assert(war3:open(path('/game/modern')))
previous_handle = war3.casc.handle
assert(war3:open(nil) == false)
assert(storage_handles[previous_handle].close_count == 1)
clean_state()

for _, storage in pairs(storage_handles) do assert(storage.close_count == 1) end
for _, opened_file in pairs(file_handles) do assert(opened_file.close_count == 1) end
for _, mpq in ipairs(mpq_handles) do assert(mpq.close_count == 1) end
print('PASS archive lifecycle with explicit Lua mocks (native DLL compatibility not tested)')
