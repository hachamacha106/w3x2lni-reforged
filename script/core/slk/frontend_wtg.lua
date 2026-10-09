-- https://github.com/stijnherfst/HiveWE/wiki/war3map.wtg-Triggers

local lang = require 'lang'
local w2l
local wtg
local state
local chunk
local unpack_index
local read_eca

local arg_type_map = {
    [-1] = lang.lml.DISABLE,
    [0]  = lang.lml.PRESET,
    [1]  = lang.lml.VARIABLE,
    [2]  = lang.lml.CALL,
    [3]  = lang.lml.CONSTANT,
}

local multiple = {
    YDWERegionMultiple = {lang.lml.ACTION},
    YDWEEnumUnitsInRangeMultiple = {lang.lml.ACTION},
    YDWEForLoopLocVarMultiple = {lang.lml.ACTION},
    YDWETimerStartMultiple = {lang.lml.ACTION, lang.lml.ACTION},
    YDWERegisterTriggerMultiple = {lang.lml.EVENT, lang.lml.ACTION, lang.lml.ACTION},
    YDWEExecuteTriggerMultiple = {lang.lml.ACTION},
    IfThenElseMultiple = {lang.lml.CONDITION, lang.lml.ACTION, lang.lml.ACTION},
    ForLoopAMultiple = {lang.lml.ACTION},
    ForLoopBMultiple = {lang.lml.ACTION},
    ForLoopVarMultiple = {lang.lml.ACTION},
    ForGroupMultiple = {lang.lml.ACTION},
    EnumDestructablesInRectAllMultiple = {lang.lml.ACTION},
    EnumDestructablesInCircleBJMultiple = {lang.lml.ACTION},
    ForForceMultiple = {lang.lml.ACTION},
    EnumItemsInRectBJMultiple = {lang.lml.ACTION},
    AndMultiple = {lang.lml.CONDITION},
    OrMultiple = {lang.lml.CONDITION},
}

local function get_ui_define(type, name)
    return state.ui[type][name]
end

local function unpack(fmt)
    local result
    result, unpack_index = ('<' .. fmt):unpack(wtg, unpack_index)
    return result
end

local function is_deleted(list, id)
    return list and (list[id] or list[id & 0xFFFFFF])
end

local function read_head()
    local id  = unpack 'c4'
    assert(id == 'WTG!', lang.script.WTG_ERROR)
    local ver = unpack 'I4'
    if ver <= 7 then
        assert(ver == 7, lang.script.WTG_VERSION_ERROR)
    else
        assert(ver == 0x80000004, lang.script.WTG_VERSION_ERROR)
        chunk.format_version = 1.31
        ver = unpack 'I4'
        assert(ver == 7, lang.script.WTG_VERSION_ERROR)
        chunk.unknown1 = unpack 'I4'
        chunk.unknown2 = unpack 'I4'
        chunk.deleted_maps = {}
        for i = 1, chunk.unknown2 do
            chunk.deleted_maps[i] = unpack 'I4'
        end
        chunk.unknown3 = unpack 'I4'
        chunk.unknown4 = unpack 'I4'
        chunk.deleted_libraries = {}
        for i = 1, chunk.unknown4 do
            chunk.deleted_libraries[i] = unpack 'I4'
        end
    end
end

local function read_counts()
    chunk.category_count = unpack 'I4'
    local deleted_category_count = unpack 'I4'
    chunk.deleted_categories = {}
    for i = 1, deleted_category_count do
        chunk.deleted_categories[unpack 'I4'] = true
    end

    chunk.trigger_count = unpack 'I4'
    local deleted_trigger_count = unpack 'I4'
    chunk.deleted_triggers = {}
    for i = 1, deleted_trigger_count do
        chunk.deleted_triggers[unpack 'I4'] = true
    end

    chunk.trigger_comment_count = unpack 'I4'
    local deleted_comment_count = unpack 'I4'
    chunk.deleted_comments = {}
    for i = 1, deleted_comment_count do
        chunk.deleted_comments[unpack 'I4'] = true
    end

    chunk.custom_script_count = unpack 'I4'
    local deleted_script_count = unpack 'I4'
    chunk.deleted_scripts = {}
    for i = 1, deleted_script_count do
        chunk.deleted_scripts[unpack 'I4'] = true
    end

    chunk.variable_count = unpack 'I4'
    local deleted_variables_count = unpack 'I4'
    chunk.deleted_variables = {}
    for i = 1, deleted_variables_count do
        chunk.deleted_variables[unpack 'I4'] = true
    end

    chunk.unknown5 = unpack 'I4'
    chunk.unknown6 = unpack 'I4'
end

local function read_category()
    local category = {}
    category.obj     = 'category'
    category.id      = unpack 'i4'
    category.name    = unpack 'z'
    category.comment = unpack 'i4'

    if chunk.format_version then
        category.unknown1 = unpack 'i4'
        category.category = unpack 'I4'
        category.childs = {}

        -- 删除掉的目录直接丢掉
        category.deleted = is_deleted(chunk.deleted_categories, category.id)
    end

    if not chunk.format_version then
        chunk.categories[#chunk.categories+1] = category
    end

    return category
end

local function read_categories()
    local count = unpack 'i4'
    for i = 1, count do
        read_category()
    end
end

local function read_var()
    local name    = unpack 'z'
    local type    = unpack 'z'
    local unknow  = unpack 'i4'
    assert(unknow == 1, lang.script.UNKNOWN2_ERROR)
    local array   = unpack 'i4'
    local size    = unpack 'i4'
    local default = unpack 'i4'
    local value   = unpack 'z'

    local var = { name, type }
    if array == 1 then
        var[#var+1] = { lang.lml.ARRAY, size }
    end
    if default == 1 then
        var[#var+1] = { lang.lml.DEFAULT, value }
    end

    if chunk.format_version then
        var.id = unpack 'I4'
        var.category = unpack 'I4'
        if is_deleted(chunk.deleted_variables, var.id) then
            -- 既然有git管理，删除掉的变量直接丢掉
            return nil
        end
    else
        var.category = 0
    end

    return var
end

local function read_vars()
    local unknow = unpack 'i4'
    assert(unknow == 2, lang.script.UNKNOWN1_ERROR)
    local count = unpack 'i4'
    for i = 1, count do
        local var = read_var()
        if var then
            chunk.vars[#chunk.vars+1] = var
        end
    end
end

local type_map = {
    [0] = lang.lml.EVENT,
    [1] = lang.lml.CONDITION,
    [2] = lang.lml.ACTION,
    [3] = lang.lml.CALL,
}

local type_index = {
    [0] = 'event',
    [1] = 'condition',
    [2] = 'action',
    [3] = 'call',
}

local function read_arg()
    local type        = unpack 'i4'
    local value       = unpack 'z'
    local arg

    local insert_call = unpack 'i4'
    if insert_call == 1 then
        arg = (read_eca(false, true))
    end

    local insert_index = unpack 'i4'
    if insert_index == 1 then
        arg = { lang.lml.ARRAY, value, read_arg() }
    end

    if arg then
        return arg
    else
        return { arg_type_map[type], value }
    end
end

local function read_ecas(parent, count, is_child, multi_list)
    local ids = {}
    local max = 0
    local start = #parent+1
    for i = 1, count do
        local eca, type, id = read_eca(is_child)
        local list = parent[id+start]
        if not list then
            list = { type_map[type], false }
            parent[id+start] = list
            ids[#ids+1] = id
            if max < id then
                max = id
            end
        end
        list[#list+1] = eca
    end
    for id = 0, max-1 do
        if not parent[id+start] then
            if multi_list then
                parent[id+start] = { multi_list[id+1] or lang.lml.LIST }
            else
                parent[id+start] = { lang.lml.LIST }
            end
        end
    end
end

function read_eca(is_child, is_arg)
    local type = unpack 'i4'
    local child_id
    if is_child then
        child_id = unpack 'i4'
    end
    local name = unpack 'z'
    local enable = unpack 'i4'

    local eca
    if enable == 0 then
        eca = { lang.lml.DISABLE, name }
    elseif is_arg then
        eca = { type_map[type], name }
    else
        eca = { name, false }
    end
    local args
    local ui = get_ui_define(type_index[type], name)
    if not ui then
        error(lang.script.WTG_UI_NOT_FOUND:format(name))
    end
    if ui.args then
        for _, arg in ipairs(ui.args) do
            if arg.type ~= 'nothing' then
                local arg = read_arg()
                if not args then
                    args = {}
                end
                args[#args+1] = arg
                eca[#eca+1] = arg
            end
        end
    end

    local count = unpack 'i4'
    if count > 0 then
        read_ecas(eca, count, true, multiple[name])
    end
    return eca, type, child_id or type
end

local function read_trigger(deleted)
    local trigger = {}
    trigger.obj      = 'trigger'
    trigger.name     = unpack 'z'
    trigger.des      = unpack 'z'
    trigger.type     = unpack 'i4'
    if chunk.format_version then
        trigger.id   = unpack 'I4'
    end
    trigger.enable   = unpack 'i4'
    trigger.wct      = unpack 'i4'
    trigger.close    = unpack 'i4'
    trigger.run      = unpack 'i4'
    trigger.category = unpack 'i4'

    trigger.trg = { '', false }
    local count = unpack 'i4'
    read_ecas(trigger.trg, count, false, {lang.lml.EVENT, lang.lml.CONDITION, lang.lml.ACTION})

    if chunk.format_version then
        if trigger.type == 0 then
            chunk.wct_count = (chunk.wct_count or 0) + 1
            trigger.wct_index = chunk.wct_count
        end
        trigger.deleted = is_deleted(deleted or chunk.deleted_triggers, trigger.id)
    else
        chunk.triggers[#chunk.triggers+1] = trigger
    end
    return trigger
end

local function read_comment()
    return read_trigger(chunk.deleted_comments)
end

local function read_script()
    return read_trigger(chunk.deleted_scripts)
end

local function read_triggers()
    local count = unpack 'i4'
    for i = 1, count do
        read_trigger()
    end
end

local function read_var_in_element()
    local trgvar = {
        obj      = 'var',
        id       = unpack 'I4',
        name     = unpack 'z',
        category = unpack 'I4',
    }

    -- 删除掉的触发直接丢掉
    trgvar.deleted = is_deleted(chunk.deleted_variables, trgvar.id)
    return trgvar
end

local function read_element(n)
    local classifier = unpack 'i4'
    local ele
    if classifier == 4 then
        ele = read_category()
    elseif classifier == 8 then
        ele = read_trigger()
    elseif classifier == 16 then
        ele = read_comment()
    elseif classifier == 32 then
        ele = read_script()
    elseif classifier == 64 then
        ele = read_var_in_element()
    else
        error(('Unsupported WTG element classifier: %d'):format(classifier))
    end
    if not ele then
        return nil
    end

    -- 新版本中，需要根据顺序手动构造目录结构
    -- WTF Blizzard, the ids between different categories
    -- can be same, so what's the meaning of this id?
    while true do
        local parent = chunk.cate_stack[#chunk.cate_stack]
        if parent.id == ele.category then
            ele.deleted = ele.deleted or parent.deleted
            if not ele.deleted then
                parent.childs[#parent.childs+1] = ele
                if classifier == 4 then
                    chunk.categories[#chunk.categories+1] = ele
                elseif classifier == 64 then
                    chunk.trgvars[#chunk.trgvars+1] = ele
                else
                    chunk.triggers[#chunk.triggers+1] = ele
                end
            elseif classifier == 64 then
                chunk.deleted_variable_elements[ele.id] = true
            end
            if classifier == 4 then
                chunk.cate_stack[#chunk.cate_stack+1] = ele
            end
            break
        end
        assert(parent ~= chunk.root, 'WTG element has no matching parent category')
        chunk.cate_stack[#chunk.cate_stack] = nil
    end

    return ele
end

local function read_elements()
    local count = unpack 'I4' - 1
    chunk.unknown7 = unpack 'i4'
    chunk.unknown8 = unpack 'i4'
    chunk.map_name = unpack 'z'
    chunk.unknown9 = unpack 'i4'
    chunk.unknown10 = unpack 'i4'
    chunk.unknown11 = unpack 'i4'

    chunk.sort = {}
    chunk.trgvars = {}
    chunk.root = { id = chunk.unknown8, childs = {} }
    chunk.cate_stack = { chunk.root }
    chunk.deleted_variable_elements = {}
    for i = 1, count do
        local obj = read_element(i)
        if obj and not obj.deleted then
            chunk.sort[obj] = i
        end
    end
    local vars = {}
    for _, var in ipairs(chunk.vars) do
        if not chunk.deleted_variable_elements[var.id] then
            vars[#vars+1] = var
        end
    end
    chunk.vars = vars
end

return function (w2l_, wtg_)
    w2l = w2l_
    wtg = wtg_
    state = w2l:frontend_trg()
    unpack_index = 1
    chunk = {
        categories = {},
        triggers = {},
        vars = {},
    }

    read_head()
    if chunk.format_version then
        read_counts()
        read_vars()
        read_elements()
    else
        read_categories()
        read_vars()
        read_triggers()
    end

    assert(unpack_index == #wtg + 1, 'Unparsed war3map.wtg data')

    return chunk
end
