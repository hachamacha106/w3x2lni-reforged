-- Exercise the real crash reporter and messagebox wrapper with simulated
-- Windows stderr bytes. Only filesystem, clock and Win32/Unicode calls are
-- mocked; no Windows GUI or native binary is executed by this test.
-- Run: lua /absolute/path/to/w3x2lni/test/compat/crashreport.lua
local source = debug.getinfo(1, 'S').source:sub(2):gsub('\\', '/')
local root = assert(source:match('^(.*)/test/compat/crashreport.lua$'),
    'Run crashreport.lua by its absolute path')

local path_mt = {}
path_mt.__index = path_mt
local function path(value) return setmetatable({value = value}, path_mt) end
function path_mt:string() return self.value end
function path_mt:__div(suffix) return path(self.value .. '/' .. suffix) end

local separator = string.rep('-', 40)
local message = "backend/example.lua:17: sample failure\nstack traceback:\n\t[C]: in function 'error'"
local prefix = 'E:/WTF2TEST/w3x2lni-current-preview/bin/w3x2lni-lua.exe:'

local function run_report(stderr, silent)
    local observed = {dialogs = {}, writes = {}}
    local function load_actual(relative, dependencies, globals)
        local environment = setmetatable(globals or {}, {__index = _G})
        environment.require = function(name)
            local result = dependencies[name]
            if result == nil then error('Unavailable dependency: ' .. name) end
            return result
        end
        return assert(loadfile(root .. '/script/' .. relative, 't', environment))()
    end

    local messagebox = load_actual('ffi/messagebox.lua', {
        ffi = {
            cdef = function() end,
            C = {MessageBoxW = function(hwnd, text, caption)
                assert(hwnd == 0 and caption == 'Error')
                -- Win32 accepts a terminated wide string, not its Lua length.
                -- Without the fix the visible message ends at the exe prefix.
                observed.dialogs[#observed.dialogs + 1] = text:match('^[^\0]*')
                return 1
            end},
        },
        ['ffi.unicode'] = {u2w = function(text) return text end},
    })

    local filesystem = {
        path = path,
        absolute = function(value)
            assert(value:string() == '..')
            return path('/preview')
        end,
        create_directories = function(value)
            assert(value:string() == '/preview/log/error')
        end,
    }
    local globals = {
        arg = silent and {'-s'} or {},
        os = {date = function(format)
            if format == 'Date: %Y-%m-%d %H:%M:%S' then
                return 'Date: 2026-10-08 23:15:30'
            end
            assert(format == '%Y-%m-%d %H-%M-%S')
            return '2026-10-08 23-15-30'
        end},
        io = {
            stdin = {read = function(_, format)
                assert(format == 'a')
                return stderr
            end},
            open = function(filename, mode)
                assert(filename == '/preview/log/error/2026-10-08 23-15-30.log')
                assert(mode == 'w')
                return {
                    write = function(_, text)
                        observed.writes[#observed.writes + 1] = text
                    end,
                    close = function() observed.closed = true end,
                }
            end,
        },
    }
    load_actual('crashreport/init.lua', {
        ['ffi.messagebox'] = messagebox,
        ['share.lang'] = {ui = {ERROR = 'Error'}},
        ['share.changelog'] = {{version = 'compat-test'}},
        ['share.brand'] = {name = 'W3x2lni Reforged'},
        ['bee.filesystem'] = filesystem,
    }, globals)
    assert(observed.closed and #observed.writes == 1)
    local log = observed.writes[1]
    assert(log:find('Product: W3x2lni Reforged', 1, true), 'Report lost product identity')
    assert(not log:find('\0', 1, true), 'Saved report still contains a NUL')
    assert(log:find(message, 1, true), 'Saved report lost the actual error/traceback')
    assert(log:sub(-#separator) == separator, 'Saved report lost its closing separator')
    if silent then
        assert(#observed.dialogs == 0, 'Silent reporting unexpectedly displayed a dialog')
    else
        assert(#observed.dialogs == 1)
        assert(observed.dialogs[1] == log, 'The dialog truncated the saved diagnostic')
    end
    return log
end

-- The upstream runtime writes "%s: " and "%s\n" using snprintf buffers one
-- byte too short. Their last characters become NUL bytes on the stderr pipe.
local nul_report = run_report(prefix .. '\0' .. message .. '\0')
assert(nul_report:find(prefix .. '\n' .. message .. '\n', 1, true))
print('PASS Windows stderr fragments reveal the full error, traceback and closing separator')

local ordinary = prefix .. ' ' .. message .. '\n'
local ordinary_report = run_report(ordinary)
assert(ordinary_report:find(separator .. '\n' .. ordinary .. '\n' .. separator, 1, true),
    'Ordinary diagnostic text changed')
print('PASS ordinary diagnostics remain intact in the saved log and dialog')

assert(run_report(prefix .. '\0' .. message .. '\0', true) == nul_report)
print('PASS silent reporting saves the complete normalized diagnostic without a dialog')
