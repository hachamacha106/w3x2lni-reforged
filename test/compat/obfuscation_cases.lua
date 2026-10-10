-- Minimal JASS fixtures for optimizer semantics. They are parsed and checked;
-- none of these scripts is executed by the tests.
local default_alphabet = 'ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789_'
local function config(confused, alphabet)
    return {confused = confused, confusion = alphabet or default_alphabet}
end
local function contains(buffer, text, message)
    assert(buffer:find(text, 1, true), message or ('Missing preserved JASS: ' .. text))
end
local function preserves_callbacks(buffer)
    contains(buffer, 'function FooCallback takes nothing returns nothing',
        'Optimization removed a callback discovered through another dynamic dispatcher')
    contains(buffer, 'function BarDispatcher takes nothing returns nothing')
    contains(buffer, 'function BazDispatcher takes nothing returns nothing')
    contains(buffer, 'call ExecuteFunc("Foo"+')
    contains(buffer, 'call ExecuteFunc("Bar"+')
    contains(buffer, 'call ExecuteFunc("Baz"+')
end
local ordinary_globals = [[globals
integer score = 0
integer other = 0
endglobals
function main takes nothing returns nothing
    set score = score + 1
    set other = other + 1
endfunction
function config takes nothing returns nothing
endfunction
]]
local literal_callback = [[function Callback takes nothing returns nothing
    call BJDebugMsg("Called")
endfunction
function main takes nothing returns nothing
    call ExecuteFunc("Callback")
endfunction
function config takes nothing returns nothing
endfunction
]]
local transitive_callbacks = [[function FooCallback takes nothing returns nothing
    call BJDebugMsg("Called")
endfunction
function BarDispatcher takes nothing returns nothing
    local string suffix = "Callback"
    call ExecuteFunc("Foo" + suffix)
endfunction
function BazDispatcher takes nothing returns nothing
    local string suffix = "Dispatcher"
    call ExecuteFunc("Bar" + suffix)
endfunction
function main takes nothing returns nothing
    local string suffix = "Dispatcher"
    call ExecuteFunc("Baz" + suffix)
endfunction
function config takes nothing returns nothing
endfunction
]]
local function unconfused_globals(buffer)
    contains(buffer, 'integer score=0', 'An invalid alphabet must leave identifier names unchanged')
    contains(buffer, 'integer other=0', 'An invalid alphabet must leave identifier names unchanged')
end
local cases = {
    {
        name = 'retained real global cannot collide with generated identifiers',
        script = [[globals
real B = 0.
integer score = 0
endglobals
function main takes nothing returns nothing
    set score = score + 1
    call TriggerRegisterVariableEvent(CreateTrigger(), "B", EQUAL, 0.)
    set B = B + 1.
endfunction
function config takes nothing returns nothing
endfunction
]],
        config = config(true),
        validate = function(buffer)
            contains(buffer, 'real B=0.')
            contains(buffer, 'TriggerRegisterVariableEvent(CreateTrigger(),"B",EQUAL,0.)')
            assert(not buffer:find('integer B=', 1, true),
                'Obfuscation reused the retained variable-event global name')
        end,
    },
    {
        name = 'overlapping ExecuteFunc prefixes retain both callback routes',
        script = [[function ABCallback takes nothing returns nothing
    call BJDebugMsg("Called")
endfunction
function main takes nothing returns nothing
    local string suffix = "Callback"
    local string suffix2 = "BCallback"
    call ExecuteFunc("A" + suffix2)
    call ExecuteFunc("AB" + suffix)
endfunction
function config takes nothing returns nothing
endfunction
]],
        config = config(true),
        validate = function(buffer)
            contains(buffer, 'function ABCallback takes nothing returns nothing',
                'The callback shared by overlapping prefixes must keep its original name')
            contains(buffer, 'call ExecuteFunc("A"+')
            contains(buffer, 'call ExecuteFunc("AB"+')
        end,
    },
    {
        name = 'transitive dynamic callbacks with obfuscation enabled',
        script = transitive_callbacks, config = config(true), validate = preserves_callbacks,
    },
    {
        name = 'transitive dynamic callbacks with obfuscation disabled',
        script = transitive_callbacks, config = config(false), validate = preserves_callbacks,
    },
    {
        name = 'fully dynamic and prefixed ExecuteFunc keep original callback names',
        script = [[function Callback takes nothing returns nothing
    call BJDebugMsg("Called")
endfunction
function PotentialCallback takes nothing returns nothing
    call BJDebugMsg("Potential dynamic target")
endfunction
function main takes nothing returns nothing
    local string callbackName = "Callback"
    local string suffix = "allback"
    call ExecuteFunc(callbackName)
    call ExecuteFunc("C" + suffix)
endfunction
function config takes nothing returns nothing
endfunction
]],
        config = config(true),
        validate = function(buffer)
            contains(buffer, 'function Callback takes nothing returns nothing')
            contains(buffer, 'function PotentialCallback takes nothing returns nothing',
                'Fully dynamic ExecuteFunc must retain every possible callback')
            contains(buffer, 'call ExecuteFunc("C"+')
        end,
    },
    -- Keep these adjacent and use one optimizer module instance. The second
    -- invocation must not inherit the first invocation's confuser or ExecuteFunc state.
    {
        name = 'literal callback with obfuscation enabled',
        script = literal_callback, config = config(true),
        validate = function(buffer)
            local callback = assert(buffer:match('call ExecuteFunc%("([%w_]+)"%)'))
            assert(callback ~= 'Callback', 'Enabled obfuscation must still rename statically known callbacks')
            contains(buffer, 'function ' .. callback .. ' takes nothing returns nothing',
                'Literal ExecuteFunc must name an emitted callback')
        end,
    },
    {
        name = 'disabled obfuscation after an enabled invocation',
        script = literal_callback, config = config(false),
        validate = function(buffer)
            contains(buffer, 'function Callback takes nothing returns nothing',
                'Disabled obfuscation inherited a prior invocation\'s renamed function')
            contains(buffer, 'call ExecuteFunc("Callback")')
        end,
    },
    -- A preceding config function can leave a local scope in the serializer.
    -- Its line number is deliberately below the following global initializer.
    {
        name = 'config local scope before another optimizer invocation',
        script = [[function main takes nothing returns nothing
endfunction
function config takes nothing returns nothing
    local integer seed = 7
    call BJDebugMsg(I2S(seed))
endfunction
]],
        config = config(true),
        validate = function(buffer)
            contains(buffer, 'BJDebugMsg(I2S(')
        end,
    },
    {
        name = 'global initializer cannot inherit a previous config local',
        script = 'globals\n' .. string.rep('\n', 12) .. [[integer seed = 7
integer copied = seed
endglobals
function main takes nothing returns nothing
    call BJDebugMsg(I2S(copied))
endfunction
function config takes nothing returns nothing
endfunction
]],
        config = config(false),
        validate = function(buffer)
            contains(buffer, 'integer seed=7')
            contains(buffer, 'integer copied=seed',
                'Global initializer resolved an earlier operation\'s config local instead of its own global')
        end,
    },
    {
        name = 'duplicate alphabet characters cannot duplicate identifier names',
        script = ordinary_globals, config = config(true, 'ABBA1'),
        validate = function(buffer)
            local first, second = buffer:match('integer ([%w_]+)=0\r?\ninteger ([%w_]+)=0')
            assert(first and second and first ~= second, 'Duplicate alphabet characters generated duplicate globals')
            assert(first ~= 'score' and second ~= 'other', 'A valid deduplicated alphabet must retain enabled obfuscation')
        end,
    },
    {
        name = 'two-character alphabet leaves identifiers unchanged',
        script = ordinary_globals, config = config(true, 'AB'), validate = unconfused_globals,
    },
    {
        name = 'one distinct letter leaves identifiers unchanged',
        script = ordinary_globals, config = config(true, 'AA1'), validate = unconfused_globals,
    },
}

return function(optimize, verify)
    for _, case in ipairs(cases) do
        if verify then verify(case.script, case.name .. ': input') end
        local output = assert(optimize(case.script, case.config), case.name .. ': no output')
        assert(type(output) == 'string', case.name .. ': output must be JASS text')
        case.validate(output)
        if verify then verify(output, case.name .. ': output') end
        print('PASS JASS obfuscation regression: ' .. case.name)
    end
end
