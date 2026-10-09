local lang = require 'lang'
local w2l
local wtg
local wts
local state
local hex

local pack_eca

local CALL     = lang.lml.CALL:match '^(.-)%s*$'
local DISABLE  = lang.lml.DISABLE:match '^(.-)%s*$'
local PRESET   = lang.lml.PRESET:match '^(.-)%s*$'
local VARIABLE = lang.lml.VARIABLE:match '^(.-)%s*$'
local CONSTANT = lang.lml.CONSTANT:match '^(.-)%s*$'
local ARRAY    = lang.lml.ARRAY:match '^(.-)%s*$'
local DEFAULT  = lang.lml.DEFAULT:match '^(.-)%s*$'

local type_map = {
    [lang.lml.LIST] = -1,
    [lang.lml.EVENT] = 0,
    [lang.lml.CONDITION] = 1,
    [lang.lml.ACTION] = 2,
    [CALL] = 3,
}

local type_key = {
    [lang.lml.EVENT] = 'event',
    [lang.lml.CONDITION] = 'condition',
    [lang.lml.ACTION] = 'action',
    [CALL] = 'call',
}

local arg_type_map = {
    [DISABLE] = -1,
    [PRESET] = 0,
    [VARIABLE] = 1,
    [CALL] = 2,
    [CONSTANT] = 3,
}


local function pack(fmt, ...)
    hex[#hex+1] = ('<' .. fmt):pack(...)
end

local function pack_head()
    pack('c4', 'WTG!')
    if wtg.format_version then
        local deleted_maps = wtg.deleted_maps or {}
        local deleted_libraries = wtg.deleted_libraries or {}
        assert(#deleted_maps == wtg.unknown2 and #deleted_libraries == wtg.unknown4,
            'WTG deleted map/library counts do not match their IDs')
        pack('I4I4I4I4'
            , 0x80000004
            , 7
            , wtg.unknown1
            , #deleted_maps
        )
        for _, id in ipairs(deleted_maps) do
            pack('I4', id)
        end
        pack('I4I4', wtg.unknown3, #deleted_libraries)
        for _, id in ipairs(deleted_libraries) do
            pack('I4', id)
        end
    else
        pack('I4', 7)
    end
end

local function pack_counts()
    local trigger_count = 0
    local comment_count = 0
    local script_count = 0
    for _, trg in ipairs(wtg.triggers) do
        if trg.type == 0 then
            trigger_count = trigger_count + 1
        elseif trg.wct == 1 then
            script_count = script_count + 1
        else
            comment_count = comment_count + 1
        end
    end

    pack('I4I4', #wtg.categories, 0)
    pack('I4I4', trigger_count, 0)
    pack('I4I4', comment_count, 0)
    pack('I4I4', script_count, 0)
    pack('I4I4', #wtg.vars, 0)
    pack('I4I4'
        , wtg.unknown5
        , wtg.unknown6
    )
end

local function pack_category()
    pack('i4', #wtg.categories)
    for _, cate in ipairs(wtg.categories) do
        pack('i4zi4', cate.id, cate.name, cate.comment)
    end
end

local function pack_var(var)
    local name = var[1]
    local type = var[2]
    local unknow = 1
    local array = 0
    local size = 1
    local default = 0
    local value = ''
    for i = 3, #var do
        local k, v = var[i][1], var[i][2]
        if k == ARRAY then
            array = 1
            size = v
        elseif k == DEFAULT then
            default = 1
            value = v
        end
    end
    pack('zzi4i4i4i4z'
        , name
        , type
        , unknow
        , array
        , size
        , default
        , value
    )

    if wtg.format_version then
        pack('I4I4'
            , var.id
            , var.category
        )
    end
end

local function pack_vars()
    pack('i4i4', 2, #wtg.vars)
    for i = 1, #wtg.vars do
        pack_var(wtg.vars[i])
    end
end

local function pack_arg(arg)
    local type = arg[1]
    local value = arg[2]
    local array = false
    if type_map[type] then
        type = CALL
        if type_map[type] ~= CALL then
            value = ''
        end
    elseif type == ARRAY then
        array = true
        type = VARIABLE
    end
    if type == CONSTANT then
        value = w2l:load_wts(wts, value, 299, lang.script.TEXT_TOO_LONG_IN_WTG)
    end
    pack('i4z', arg_type_map[type], value)
    if type == CALL then
        pack('i4', 1)
        pack_eca(arg)
    else
        pack('i4', 0)
    end
    if array then
        pack('i4', 1)
        pack_arg(arg[3])
    else
        pack('i4', 0)
    end
end

local arg_count = {}
local function get_ui_arg_count(ui)
    if not arg_count[ui] then
        local count = 0
        if ui.args then
            for _, arg in ipairs(ui.args) do
                if arg.type ~= 'nothing' then
                    count = count + 1
                end
            end
        end
        arg_count[ui] = count
    end
    return arg_count[ui]
end

local function pack_args(ui, eca)
    local eca_arg_count = 0
    for i = 3, #eca do
        if eca[i][2] then
            eca_arg_count = eca_arg_count + 1
            pack_arg(eca[i])
        end
    end

    if ui then
        if eca_arg_count ~= get_ui_arg_count(ui) then
            error(lang.script.WTG_ERROR_ARG:format(ui.name, get_ui_arg_count(ui), eca_arg_count))
        end
    end
end

local function pack_list(lists, root)
    local child_count = 0
    for i = 3, #lists do
        if not lists[i][2] and type_map[lists[i][1]] and #lists[i] > 2 then
            child_count = child_count + #lists[i] - 2
        end
    end
    pack('i4', child_count)
    local child_id = -1
    for i = 3, #lists do
        if not lists[i][2] and type_map[lists[i][1]] then
            child_id = child_id + 1
            local list = lists[i]
            local type = list[1]
            for i = 3, #list do
                if root then
                    pack_eca(list[i], nil, type)
                else
                    pack_eca(list[i], child_id, type)
                end
            end
        end
    end
end

function pack_eca(eca, child_id, eca_type)
    local name
    local type = eca_type or CALL
    local enable = 1
    if eca[2] then
        name = eca[2]
        if eca[1] == DISABLE then
            enable = 0
        elseif type_map[eca[1]] then
            type = eca[1]
        else
            w2l.messager.text(lang.script.WTG_UNKNOWN_ACTION_STATE:format(eca[1], #hex))
        end
    else
        name = eca[1]
    end
    local ui
    if state then
        ui = state.ui[type_key[type]][name]
        if not ui then
            error(lang.script.WTG_UI_NOT_FOUND:format(name))
        end
    end
    if child_id then
        pack('i4i4zi4', type_map[type], child_id, name, enable)
    else
        pack('i4zi4', type_map[type], name, enable)
    end
    pack_args(ui, eca)
    pack_list(eca)
end

local function pack_trigger(trg)
    pack('zzi4'
        , trg.name
        , trg.des
        , trg.type
    )
    if wtg.format_version then
        pack('I4', trg.id)
    end
    pack('i4i4i4i4i4'
        , trg.enable
        , trg.wct
        , trg.close
        , trg.run
        , trg.category
    )
    pack_list(trg.trg, true)
end

local function pack_triggers()
    pack('i4', #wtg.triggers)
    for i = 1, #wtg.triggers do
        pack_trigger(wtg.triggers[i], i)
    end
end

local function pack_category_in_element(cat)
    pack('i4i4zi4i4I4'
        , 4
        , cat.id
        , cat.name
        , cat.comment
        , 1
        , cat.category
    )
end

local function pack_var_in_element(var)
    pack('I4I4zI4'
        , 64
        , var.id
        , var[1]
        , var.category
    )
end

local function pack_trigger_in_element(trg)
    if trg.type == 0 then
        pack('I4', 8)
    elseif trg.wct == 1 then
        pack('I4', 32)
    else
        pack('I4', 16)
    end
    pack_trigger(trg)
end

local function pack_elements()
    pack('I4i4i4zi4i4i4'
        , 1 + #wtg.objs
        , wtg.unknown7
        , wtg.unknown8
        , w2l.slk and w2l.slk.w3i[lang.w3i.MAP][lang.w3i.MAP_NAME] or 'Unknown'
        , wtg.unknown9
        , wtg.unknown10
        , wtg.unknown11
    )
    for _, obj in ipairs(wtg.objs) do
        if obj.obj == 'category' then
            pack_category_in_element(obj)
        elseif obj.obj == 'var' then
            pack_var_in_element(obj)
        elseif obj.obj == 'trigger' then
            pack_trigger_in_element(obj)
        end
    end
end

return function (w2l_, wtg_, wts_)
    w2l = w2l_
    wtg = wtg_
    wts = wts_
    state = w2l:frontend_trg()
    hex = {}
    arg_count = {}

    pack_head()
    if wtg.format_version then
        pack_counts()
        pack_vars()
        pack_elements()
    else
        pack_category()
        pack_vars()
        pack_triggers()
    end

    return table.concat(hex)
end
