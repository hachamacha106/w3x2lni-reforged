local source = debug.getinfo(1, 'S').source:sub(2):gsub('\\', '/')
local context = dofile(source:match('^(.*)/[^/]+$') .. '/bootstrap.lua')
local factory = require 'backend.sandbox_core'
local lang = require 'share.lang'
lang:set_lang('enUS')

local function converter(files)
    local w2l = factory()
    local errors = {}
    w2l:set_messager { report = function(_, level, message, detail)
        if level == 1 then errors[#errors + 1] = tostring(message) .. ': ' .. tostring(detail) end
    end }
    w2l:set_setting {
        mode = 'slk', data = 'warcraft-current', optimize_jass = true,
        confused = true, confusion = 'ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789_',
    }
    w2l.input_ar = {}
    function w2l:file_load(_, name) return files[name:lower()] end
    function w2l:file_save(_, name, buffer) files[name:lower()] = buffer end
    function w2l:mpq_load(name)
        return io.load(context.fs.path(context.root .. '/data/warcraft-current/mpq/' .. name))
    end
    return w2l, errors
end

local files = { ['war3map.j'] = [[
function UnusedFunction takes nothing returns nothing
    call DisplayTextToPlayer(Player(0), 0, 0, "unused")
endfunction
function main takes nothing returns nothing
    local unit hero = CreateUnit(Player(0), 'Hpal', 0, 0, 270)
    local item equipped = BlzGetEquippedItem()
    call BlzResetUnitTalents(hero)
    call RemoveItem(equipped)
    set hero = null
    set equipped = null
endfunction
function config takes nothing returns nothing
    call SetMapName("Current native test")
    call SetPlayers(1)
    call SetTeams(1)
endfunction
]] }
local w2l, errors = converter(files)
w2l:backend_optimizejass()
assert(#errors == 0, table.concat(errors, '\n'))
local optimized = files['war3map.j']
assert(optimized:find('BlzGetEquippedItem', 1, true))
assert(optimized:find('BlzResetUnitTalents', 1, true))
assert(not optimized:find('UnusedFunction', 1, true))
package.path = context.root .. '/script/core/?.lua;' .. package.path
package.loaded.lang = lang
local parser = require 'parser.init'
local options = {}
parser.parser(w2l:mpq_load('scripts\\common.j'), 'common.j', options)
parser.parser(w2l:mpq_load('scripts\\blizzard.j'), 'blizzard.j', options)
local ast, _, diagnostics = parser.parser(optimized, 'optimized.j', options)
assert(ast)
for _, diagnostic in ipairs(diagnostics or {}) do
    assert(diagnostic.level ~= 'error', tostring(diagnostic.err))
end
print('PASS current common.j/Blizzard.j natives and JASS optimization/obfuscation')

-- Reuse the same optimizer module across cases so per-invocation state leaks
-- are observable. Check callback routing explicitly: pjass cannot resolve
-- dynamically constructed function names and therefore cannot prove this behavior.
local optimizer = require 'optimizer.init'
local function parse_script(script, label)
    local parsed = {}
    parser.parser(w2l:mpq_load('scripts\\common.j'), 'common.j', parsed)
    parser.parser(w2l:mpq_load('scripts\\blizzard.j'), 'blizzard.j', parsed)
    local script_ast, _, errors = parser.parser(script, 'war3map.j', parsed)
    assert(script_ast, label .. ': no JASS AST')
    for _, diagnostic in ipairs(errors or {}) do
        assert(diagnostic.level ~= 'error', label .. ': ' .. tostring(diagnostic.err))
    end
    return script_ast, parsed.state
end
local obfuscation_cases = dofile(context.root .. '/test/compat/obfuscation_cases.lua')
obfuscation_cases(function(script, config)
    local script_ast, state = parse_script(script, 'optimizer input')
    return optimizer(script_ast, state, config)
end, parse_script)

local lua = 'function main() print(GetLocalizedString("TRIGSTR_" .. "900")) end\n'
files = { ['war3map.lua'] = lua }
w2l, errors = converter(files)
local wts = w2l:frontend_wts('STRING 0\n{\nFirst\n}\n\nSTRING 900\n{\nKeep this\n}\n')
assert(w2l:save_wts(wts, 'New text', 'test') == 'TRIGSTR_901')
local serialized = w2l:refresh_wts(wts)
local reread = w2l:frontend_wts(serialized)
assert(reread[0].text == 'First')
assert(reread[900].text == 'Keep this')
assert(reread[901].text == 'New text')
w2l:backend_optimizejass()
w2l:backend_convertjass(wts)
assert(#errors == 0, table.concat(errors, '\n'))
assert(files['war3map.lua'] == lua)
print('PASS Lua script preservation and sparse/dynamic WTS references without ID collisions')

-- The supplied 3.0.1 editor map contains conversation.json with an explicit
-- war3map.wts reference. Treat its contents as opaque and keep every original
-- string ID, including when a JASS map has no reference to the dialogue text.
local conversation = '{"stringTablePath":"war3map.wts","conversation":{"fixture":{"stringId":900}}}'
files = {
    ['war3map.j'] = 'function main takes nothing returns nothing\nendfunction\n',
    ['conversation.json'] = conversation,
}
w2l, errors = converter(files)
wts = w2l:frontend_wts('STRING 1\n{\nMap name\n}\n\nSTRING 900\n{\nDialogue only\n}\n')
assert(w2l:save_wts(wts, 'Additional text', 'test') == 'TRIGSTR_901')
local conversation_wts = w2l:frontend_wts(w2l:refresh_wts(wts))
assert(conversation_wts[1].text == 'Map name')
assert(conversation_wts[900].text == 'Dialogue only')
assert(conversation_wts[901].text == 'Additional text')
assert(files['conversation.json'] == conversation and #errors == 0)
print('PASS current conversation files preserve original WTS IDs on JASS maps')

local long_original = string.rep('Original object text ', 80) .. '}\nStill the same text'
files = {
    ['war3map.lua'] = lua,
    ['war3map.wts'] = 'STRING 9000\n{\n' .. long_original .. '\n}\n',
}
w2l, errors = converter(files)
wts = w2l:frontend_wts(files['war3map.wts'])
local next_before = wts.next_index
assert(w2l:save_wts(wts, long_original, 'test') == 'TRIGSTR_9000')
assert(wts.next_index == next_before)
assert(wts.mark[9001] == long_original)
assert(w2l:save_wts(wts, 'New independent text', 'test') == 'TRIGSTR_9001')

-- Exercise the real binary reader -> unknown-field preservation -> writer.
-- Minimal parent/metadata tables isolate WTS handling from incomplete defaults.
w2l.default_data = {unit = {hfoo = {_code = 'hfoo'}}}
w2l.cache_metadata = {unit = {}}
local fixture = string.pack('<i4i4i4c4c4i4i4c4i4zi4',
    3, 0, 1, 'hfoo', 'H000', 0, 1, 'zz99', 3, 'TRIGSTR_9000', 0)
local data = w2l:frontend_obj('unit', fixture, wts)
w2l:frontend_updateobj('unit', data, w2l:get_default().unit)
assert(data.H000._object_extras[1][5] == long_original)
data.H000._mark = true
local object_output = w2l:backend_obj('unit', data, wts)
assert(object_output:find('TRIGSTR_9000\0', 1, true))
local restored_wts = w2l:frontend_wts(w2l:refresh_wts(wts))
local restored_object = w2l:frontend_obj('unit', object_output, restored_wts)
assert(restored_object.H000.zz99[1] == long_original)
assert(restored_wts[9000].text == long_original)
assert(restored_wts[9001].text == 'New independent text')
assert(files['war3map.lua'] == lua)
assert(#errors == 0, table.concat(errors, '\n'))
print('PASS exact original WTS reuse, braces, and long unknown object strings on Lua maps')

-- JASS rewrites can allocate different IDs, but valid source text must still
-- remain unchanged when it is moved into the rebuilt WTS.
w2l, errors = converter({})
wts = w2l:frontend_wts('STRING 9000\n{\n' .. long_original .. '\n}\n')
assert(w2l:save_wts(wts, long_original, 'test') == 'TRIGSTR_000')
assert(w2l:frontend_wts(w2l:refresh_wts(wts))[0].text == long_original)
assert(#errors == 0, table.concat(errors, '\n'))
print('PASS valid original WTS text preserved when string IDs are rebuilt')

-- LNI stores the decoded opaque field as text. Retain its original WTS too so
-- the following binary conversion can recognize valid source text with braces.
w2l, errors = converter({})
w2l.setting.mode = 'lni'
w2l.default_data = {unit = {hfoo = {_code = 'hfoo'}}}
w2l.cache_metadata = {unit = {}}
wts = w2l:frontend_wts('STRING 9000\n{\n' .. long_original .. '\n}\n')
data = w2l:frontend_obj('unit', fixture, wts)
w2l:frontend_updateobj('unit', data, w2l:get_default().unit)
data.H000._mark = true
local lni_object = w2l:backend_lni('unit', data)
local lni_wts = w2l:refresh_wts(wts)
assert(w2l:frontend_wts(lni_wts)[9000].text == long_original)
local rebuilt = converter({})
rebuilt.setting.mode = 'obj'
rebuilt.default_data = {unit = {hfoo = {_code = 'hfoo'}}}
rebuilt.cache_metadata = {unit = {}}
local rebuilt_wts = rebuilt:frontend_wts(lni_wts)
local rebuilt_data = rebuilt:frontend_lni('unit', lni_object, 'unit')
rebuilt_data.H000._mark = true
local rebuilt_object = rebuilt:backend_obj('unit', rebuilt_data, rebuilt_wts)
local final_wts = rebuilt:frontend_wts(rebuilt:refresh_wts(rebuilt_wts))
assert(rebuilt:frontend_obj('unit', rebuilt_object, final_wts).H000.zz99[1] == long_original)
print('PASS non-Lua W3X to LNI to OBJ preserves original long WTS text with braces')

local malformed = 'STRING 900\n{\nMissing closing brace'
files = {['war3map.lua'] = lua, ['war3map.wts'] = malformed}
w2l, errors = converter(files)
local ok, err = pcall(function()
    local parsed = w2l:frontend_wts(files['war3map.wts'])
    files['war3map.wts'] = w2l:refresh_wts(parsed)
end)
assert(not ok and err:find('Cannot safely convert invalid war3map.wts', 1, true))
assert(files['war3map.wts'] == malformed and files['war3map.lua'] == lua)
assert(#errors == 1)
print('PASS malformed existing WTS fails before Lua references or string files can be lost')
