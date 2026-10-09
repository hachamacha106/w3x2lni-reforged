-- Build a dataset from an already extracted archive tree. This module performs
-- no filesystem writes: callers receive staged output only after every build
-- step succeeds. It never fills gaps from another Warcraft installation.
local create_metadata = require 'prebuilt.metadata'
local create_keydata = require 'prebuilt.keydata'
local create_titles = require 'prebuilt.slktitle'
local create_search = require 'prebuilt.search'
local write_objects = require 'prebuilt.objectwriter'
local data_version = require 'share.data_version'

local directory = {}
local types = {'ability', 'buff', 'unit', 'item', 'upgrade', 'doodad', 'destructable', 'misc', 'txt'}

local function path(name)
    return (name:gsub('\\', '/'):gsub('/+', '/'):gsub('^/', ''):lower())
end

local function count(table)
    local n = 0
    for _ in pairs(table) do n = n + 1 end
    return n
end

local function source_reader(loader)
    local cache = {}
    return function(name)
        name = path(name)
        if cache[name] == nil then
            cache[name] = loader(name) or false
        end
        return cache[name] or nil
    end
end

local function requirements(w2l, reforge)
    local required = {}
    local function add(name, essential)
        name = path(name)
        if required[name] == nil or essential then
            required[name] = essential or false
        end
    end
    for kind, files in pairs(w2l.info.slk) do
        for _, filename in ipairs(files) do add(filename, true) end
        local folder = kind == 'doodad' and 'doodads/' or 'units/'
        add(folder .. w2l.info.metadata[kind], true)
    end
    add('units/miscmetadata.slk', true)
    add('ui/uniteditordata.txt', true)
    for _, filename in ipairs(w2l.info.misc) do add(filename, true) end
    for _, filename in ipairs(w2l.info.txt) do add(filename) end
    if reforge then
        for _, filename in ipairs(w2l.info.reforge) do add(filename) end
    end
    for _, filename in ipairs {
        'scripts/common.j', 'scripts/blizzard.j', 'ui/triggerdata.txt',
        'ui/triggerstrings.txt', 'ui/worldeditstrings.txt', 'ui/worldeditgamestrings.txt',
    } do add(filename) end
    return required
end

local function report(result)
    local lines = {
        'Warcraft III extracted-data import',
        'Dataset: ' .. result.name,
        'Game build: ' .. (result.game_build or 'unverified'),
        'Locale: ' .. (result.locale or 'unverified'),
        'Status: ' .. (result.complete and 'required input files present' or 'INCOMPLETE'),
        'Game and World Editor validation: not performed by this importer',
    }
    if #result.missing > 0 then
        lines[#lines + 1] = ''
        lines[#lines + 1] = 'Missing input files from the same game build and locale:'
        for _, filename in ipairs(result.missing) do
            lines[#lines + 1] = '  ' .. filename
        end
    end
    if not result.custom_balance then
        lines[#lines + 1] = ''
        lines[#lines + 1] = 'No Custom_V1 balance overrides were supplied; Custom uses the supplied base tables.'
        lines[#lines + 1] = 'Export the balance layer too if the installation provides different custom-game defaults.'
    end
    if result.built then
        lines[#lines + 1] = ''
        for _, variant in ipairs {'Melee', 'Custom'} do
            local parts = {}
            for _, kind in ipairs(types) do
                parts[#parts + 1] = kind .. '=' .. result.counts[variant][kind]
            end
            lines[#lines + 1] = variant .. ': ' .. table.concat(parts, ', ')
        end
    end
    if not result.complete then
        lines[#lines + 1] = ''
        lines[#lines + 1] = 'No selectable version marker is generated for incomplete data.'
        if result.built then
            lines[#lines + 1] = 'Generated defaults are for compatibility QA only; localized names and trigger labels may be absent.'
        else
            lines[#lines + 1] = 'No generated files were written. --allow-partial is available for explicit QA builds.'
        end
    end
    return table.concat(lines, '\r\n') .. '\r\n'
end

function directory.build(w2l, options)
    options = options or {}
    local raw = source_reader(assert(options.loader, 'A raw archive file loader is required'))
    local function load_source(filename)
        local content = raw(filename)
        if content then return (content:gsub('^\239\187\191', '')) end
    end
    local reforge = options.reforge
    if reforge == nil then reforge = raw('units/unitskin.txt') ~= nil end
    local result = {
        name = options.name or 'warcraft-current',
        game_build = options.game_build,
        locale = options.locale,
        missing = {}, missing_essential = {}, files = {}, counts = {},
        custom_balance = false, built = false,
    }
    for filename, essential in pairs(requirements(w2l, reforge)) do
        if not raw(filename) then
            result.missing[#result.missing + 1] = filename
            if essential then result.missing_essential[#result.missing_essential + 1] = filename end
        end
        if raw('custom_v1/' .. filename) then result.custom_balance = true end
    end
    table.sort(result.missing)
    table.sort(result.missing_essential)
    result.complete = #result.missing == 0
    if #result.missing_essential > 0 or (not result.complete and not options.allow_partial) then
        result.report = report(result)
        return result
    end

    local files = {}
    local war3 = {reforge = reforge, casc = reforge}
    files['prebuilt/metadata.ini'] = create_metadata(w2l, options.fixer, war3, load_source)
    w2l.cache_metadata = w2l:parse_lni(files['prebuilt/metadata.ini'])
    files['prebuilt/keydata.ini'] = create_keydata(w2l, war3, load_source)
    files['prebuilt/slktitle.ini'] = create_titles(w2l, load_source)
    files['prebuilt/search.ini'] = create_search(w2l, load_source)
    if reforge then files['prebuilt/reforge.ini'] = '' end

    -- Use the freshly generated metadata and these raw inputs for every lookup.
    -- The converter's previous configured dataset is never a fallback.
    w2l.setting.data = result.name
    w2l.setting.data_meta = '${DATA}'
    w2l.setting.data_ui = '${DATA}'
    w2l.setting.data_wes = '${DATA}'
    w2l.cache_keydata = w2l:parse_lni(files['prebuilt/keydata.ini'])
    w2l.cache_slktitle = w2l:parse_lni(files['prebuilt/slktitle.ini'])
    w2l.editstring, w2l.default_data = nil, nil
    function w2l:data_load(filename)
        filename = path(filename)
        if files[filename] ~= nil then return files[filename] end
        if filename:sub(1, 4) == 'mpq/' then
            return load_source(filename:sub(5))
        end
        return load_source(filename)
    end
    for _, variant in ipairs {'Melee', 'Custom'} do
        w2l.setting.version = variant
        w2l.default_data = nil
        if variant == 'Custom' then
            w2l.mpq_path:open 'Custom_V1'
        else
            w2l.mpq_path:close 'Custom_V1'
        end
        local defaults = w2l:frontend_buildslk()
        result.counts[variant] = {}
        for _, kind in ipairs(types) do
            result.counts[variant][kind] = count(defaults[kind])
            files['prebuilt/' .. variant:lower() .. '/' .. kind .. '.ini'] = write_objects(defaults[kind])
        end
    end
    -- The normal UI loader expects these two definitions outside mpq/ as well.
    for _, filename in ipairs {'ui/triggerdata.txt', 'ui/triggerstrings.txt'} do
        if raw(filename) then files[filename] = raw(filename) end
    end
    if result.complete then files.version = table.concat(data_version, '\r\n') end
    result.built = true
    result.report = report(result)
    files['import-report.txt'] = result.report
    result.files = files
    return result
end

return directory
