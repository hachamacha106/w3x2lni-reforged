-- Standalone lossless archive tools. They do not invoke object conversion,
-- plugins, pruning, script optimization, editor-file removal, or model rewriting.
local fs = require 'bee.filesystem'
local mpq = require 'backend.lossless_mpq'
local M = {max_input_bytes = 256 * 1024 * 1024}
local sequence = 0

local function read(path, limit)
    local file, err = io.open(path:string(), 'rb')
    assert(file, err)
    local size = assert(file:seek('end'))
    assert(file:seek('set'))
    if limit and size > limit then file:close(); return nil, size end
    local bytes = file:read 'a'
    local closed, close_error = file:close()
    assert(closed, close_error)
    assert(bytes and #bytes == size, 'Incomplete file read')
    return bytes, size
end

local function write(path, bytes)
    local file, err = io.open(path:string(), 'wb')
    assert(file, err)
    local written, write_error = file:write(bytes)
    local closed, close_error = file:close()
    assert(written, write_error)
    assert(closed, close_error)
end

local function stop(options)
    if options.cancelled and options.cancelled() then error('Optimization cancelled') end
end

local function names_from_list(bytes)
    local names = {}
    for name in (bytes or ''):gmatch('[^\r\n]+') do names[#names + 1] = name end
    names[#names + 1], names[#names + 2], names[#names + 3] = '(listfile)', '(attributes)', '(signature)'
    return names
end

local known = {'war3map.j', 'scripts\\war3map.j', 'war3map.lua', 'scripts\\war3map.lua',
    'war3map.w3i', 'war3map.imp', 'war3map.wts', 'common.j', 'blizzard.j',
    'scripts\\common.j', 'scripts\\blizzard.j'}

local crc_table = {}
for i = 0, 255 do
    local crc = i
    for _ = 1, 8 do crc = (crc >> 1) ~ (crc & 1 ~= 0 and 0xEDB88320 or 0) end
    crc_table[i] = crc
end
local function crc32(bytes, cancelled)
    local crc = 0xFFFFFFFF
    for i = 1, #bytes do
        if i & 65535 == 0 and cancelled and cancelled() then error('Optimization cancelled') end
        crc = (crc >> 8) ~ crc_table[(crc ~ bytes:byte(i)) & 255]
    end
    return crc ~ 0xFFFFFFFF
end

local function summary(info, options)
    options = options or {}
    info.largest, info.duplicates, info.import_issues, info.model_issues = {}, {}, {}, {}
    local by_name, buckets = {}, {}
    for _, member in ipairs(info.files) do
        local name = member.name
        if info.input_type == 'lni' then name = member.logical_name end
        if name and member.bytes and not (info.logical_conflicts and info.logical_conflicts[mpq.normalized(name)]) then
            by_name[mpq.normalized(name)] = member.bytes
        end
        info.largest[#info.largest + 1] = {name = member.name, decoded_size = member.decoded_size, stored_size = member.stored_size}
        if member.bytes then
            if member.name:lower():sub(-4) == '.mdx' then
                local version = #member.bytes >= 16 and member.bytes:sub(1, 8) == 'MDLXVERS'
                    and string.unpack('<I4', member.bytes, 9) == 4 and string.unpack('<I4', member.bytes, 13)
                if version ~= 800 then
                    info.model_issues[#info.model_issues + 1] = ('Model retained unchanged: %s; format: %s'):format(
                        member.name, version and ('MDX ' .. version) or 'unrecognized/truncated MDX')
                end
            end
            local key = #member.bytes .. ':' .. crc32(member.bytes, options.cancelled)
            local bucket = buckets[key] or {}
            buckets[key] = bucket
            local group
            for _, candidate in ipairs(bucket) do
                if candidate.bytes == member.bytes then group = candidate; break end
            end
            if group then group.names[#group.names + 1] = member.name
            else bucket[#bucket + 1] = {bytes = member.bytes, names = {member.name}} end
        end
    end
    for _, bucket in pairs(buckets) do
        for _, group in ipairs(bucket) do
            if #group.names > 1 then
                table.sort(group.names)
                info.duplicates[#info.duplicates + 1] = {names = group.names, decoded_size = #group.bytes,
                    potential_decoded_bytes = #group.bytes * (#group.names - 1)}
            end
        end
    end
    table.sort(info.duplicates, function(a, b) return a.names[1] < b.names[1] end)
    table.sort(info.largest, function(a, b)
        if a.decoded_size == b.decoded_size then return a.name < b.name end
        return a.decoded_size > b.decoded_size
    end)
    while #info.largest > 20 do info.largest[#info.largest] = nil end
    local function import_reference(path)
        if info.logical_conflicts and info.logical_conflicts[mpq.normalized(path)] then
            info.import_issues[#info.import_issues + 1] = 'Ambiguous imported file: ' .. path
        elseif not by_name[mpq.normalized(path)] then
            info.import_issues[#info.import_issues + 1] = 'Missing imported file: ' .. path
        end
    end
    local imports = by_name['WAR3MAP.IMP']
    if imports then
        local ok, err = pcall(function()
            local version, count, pos = string.unpack('<I4I4', imports)
            assert(version == 1 and count <= #imports, 'Unsupported import table header')
            for _ = 1, count do
                local flag, name
                flag, name, pos = string.unpack('Bz', imports, pos)
                if flag ~= 5 and flag ~= 8 and flag ~= 10 and flag ~= 13 then
                    info.import_issues[#info.import_issues + 1] = 'Unknown import flag preserved for: ' .. name
                end
                import_reference((flag == 5 or flag == 8) and ('war3mapImported\\' .. name) or name)
            end
            assert(pos == #imports + 1, 'Import table has unexplained trailing bytes')
        end)
        if not ok then info.import_issues[#info.import_issues + 1] = 'Cannot fully analyze imports: ' .. tostring(err) end
    elseif info.input_type ~= 'lni' then
        info.import_issues[#info.import_issues + 1] = 'war3map.imp is absent; no import-reference completeness claim is made.'
    end
    if info.input_type == 'lni' then
        if info.lni_imports then
            for _, name in ipairs(info.lni_imports) do import_reference(name) end
        elseif info.lni_import_error then
            info.import_issues[#info.import_issues + 1] = 'Cannot fully analyze LNI imports: ' .. info.lni_import_error
        elseif not imports then
            info.import_issues[#info.import_issues + 1] = 'LNI import metadata is absent; no import-reference completeness claim is made.'
        end
    end
    info.provider = function(name) return by_name[mpq.normalized(name)] end
end

local function lni_map_name(name)
    -- Match core.proxy:pairs/save without converting any project data. Only
    -- these exported directories contain directly preserved packed-map files.
    local lower = name:lower()
    local dir = lower:match('^([^\\]+)\\')
    if dir ~= 'map' and dir ~= 'resource' and dir ~= 'sound' and dir ~= 'scripts' and dir ~= 'w3x2lni' then return end
    local ext = lower:match('[^%.]+$')
    local kind
    if dir == 'w3x2lni' then kind = dir
    elseif ext == 'mdx' or ext == 'mdl' or ext == 'blp' or ext == 'tga' or ext == 'dds' or ext == 'tif' then kind = 'resource'
    elseif ext == 'mp3' or ext == 'wav' then kind = 'sound'
    elseif lower == 'scripts\\war3map.j' then kind = 'map'
    elseif dir == 'scripts' then kind = dir
    else kind = 'map' end
    if dir == kind and kind ~= 'scripts' and kind ~= 'w3x2lni' then return name:sub(#dir + 2) end
    return name
end

local function collect_lni(path, options)
    stop(options)
    local folder = fs.canonical(path)
    local marker = folder / '.w3x'
    assert(fs.symlink_status(marker):type() == 'regular', 'Choose an exported LNI folder with a regular .w3x marker')
    assert(fs.canonical(marker):parent_path():string():lower() == folder:string():lower(), 'LNI marker resolves outside the input folder')
    local marker_bytes = read(marker, 65536)
    assert(require('share.check_lni_mark')(marker_bytes), 'The folder does not contain a valid LNI .w3x marker')
    local info = {input_type = 'lni', input = path, input_size = 0, eligible = false, complete = true,
        reasons = {'LNI folder: archive optimization is unavailable; analyze the packed .w3x or .w3m to compare MPQ storage.'},
        files = {}, logical_conflicts = {}}
    local physical, logical, decoded_total = {}, {}, 0
    local function partial(name, reason)
        info.complete = false
        info.reasons[#info.reasons + 1] = reason .. ': ' .. name
    end
    local directory = require('map-builder.archive_dir')(folder, true)
    local ok, err = xpcall(function()
        directory:foreach_file(function(name, filename)
            stop(options)
            local loaded, bytes, size = pcall(read, filename, M.max_input_bytes - decoded_total)
            if not loaded then partial(name, 'Project file could not be read: ' .. tostring(bytes)); return end
            info.input_size = info.input_size + size
            if not bytes then partial(name, 'Project decoded bytes exceed the 256 MiB in-memory safety limit')
            else decoded_total = decoded_total + #bytes end
            local logical_name = lni_map_name(name)
            local member = {name = name, logical_name = logical_name, bytes = bytes,
                decoded_size = size, stored_size = size}
            info.files[#info.files + 1] = member
            local key = mpq.normalized(name)
            if physical[key] then physical[key] = false; partial(name, 'Ambiguous exported filename')
            elseif physical[key] ~= false then physical[key] = member end
            if logical_name then
                key = mpq.normalized(logical_name)
                if logical[key] then
                    info.logical_conflicts[key] = true
                    partial(name, 'Ambiguous logical map filename also exported as ' .. logical[key])
                else logical[key] = name end
            end
            if options.progress then options.progress(math.min(0.9, decoded_total / M.max_input_bytes)) end
        end, {cancelled = options.cancelled, skipped = partial, max_entries = 65536, max_depth = 128})
    end, debug.traceback)
    if not ok then partial(path:string(), 'Project inventory could not finish: ' .. tostring(err)) end
    stop(options)
    local function metadata(kind, fallback)
        local paths = options.w2l and options.w2l.info and options.w2l.info.lni_dir and options.w2l.info.lni_dir[kind] or fallback
        local selected
        for _, name in ipairs(paths) do
            local member = physical[mpq.normalized(name)]
            assert(member ~= false, 'Ambiguous LNI metadata: ' .. name)
            if member then
                assert(member.bytes, 'LNI metadata could not be read: ' .. name)
                assert(#member.bytes <= 16 * 1024 * 1024, 'LNI metadata exceeds the parser safety limit: ' .. name)
                assert(not selected or selected.bytes == member.bytes, 'Conflicting LNI metadata copies: ' .. name)
                selected = selected or member
            end
        end
        if not selected then return end
        if options.w2l and options.w2l.parse_lni then return options.w2l:parse_lni(selected.bytes, selected.name) end
        return require('lni')(selected.bytes, selected.name)
    end
    local parsed, imports = pcall(metadata, 'imp', {'table\\imp.ini', 'war3map.imp.ini'})
    if not parsed then info.lni_import_error = tostring(imports)
    elseif imports then
        local valid, list = pcall(function()
            assert(type(imports) == 'table', 'LNI import metadata is not a table')
            local list = imports.import or type(imports.root) == 'table' and imports.root.import
            assert(type(list) == 'table', 'LNI import metadata has no import list')
            assert(#list <= 65536, 'LNI import list exceeds the safety limit')
            local count = 0
            for key, name in pairs(list) do
                stop(options)
                count = count + 1
                assert(type(key) == 'number' and key % 1 == 0 and key >= 1 and key <= #list,
                    'LNI import list has nonsequential keys')
                assert(type(name) == 'string' and name ~= '' and not name:find('\0', 1, true), 'Invalid LNI import filename')
            end
            assert(count == #list, 'LNI import list has missing entries')
            return list
        end)
        if valid then info.lni_imports = list else info.lni_import_error = tostring(list) end
    end
    local parsed, language = pcall(function()
        local w3i = metadata('w3i', {'table\\w3i.ini', 'war3map.w3i.ini'})
        if not w3i then return end
        local keys = require('share.lang').w3i
        local locale = physical['W3X2LNI\\LOCALE\\W3I.LNG']
        assert(locale ~= false, 'Ambiguous project W3I locale dictionary')
        if locale then
            assert(locale.bytes and #locale.bytes <= 16 * 1024 * 1024, 'Project W3I locale dictionary is unreadable or too large')
            -- The converter uses this exported dictionary when loading LNI.
            -- Read its two required keys locally; do not alter global language.
            keys = {}
            local key
            local lines = locale.bytes:gsub('^\239\187\191', ''):gsub('\r\n', '\n'):gsub('\r', '\n')
            for line in (lines .. '\n'):gmatch('(.-)\n') do
                local section = line:match('^%[(.+)%]$')
                if section then key = section
                elseif key == 'MAP' or key == 'SCRIPT_TYPE' then
                    keys[key] = keys[key] and (keys[key] .. '\r\n' .. line) or line
                end
            end
            assert(keys.MAP and keys.MAP ~= '', 'Project W3I locale dictionary has no map key')
            assert(keys.SCRIPT_TYPE and keys.SCRIPT_TYPE ~= '', 'Project W3I locale dictionary has no script-language key')
        end
        assert(type(w3i) == 'table' and type(w3i[keys.MAP]) == 'table', 'LNI map metadata has no recognized map section')
        return w3i[keys.MAP][keys.SCRIPT_TYPE]
    end)
    if not parsed then info.script_type_error = 'Cannot read LNI script-language metadata: ' .. tostring(language)
    else info.script_type = language end
    for _, name in ipairs {'war3map.j', 'scripts\\war3map.j', 'war3map.lua', 'scripts\\war3map.lua'} do
        if info.logical_conflicts[mpq.normalized(name)] then
            info.script_type_error = 'Conflicting exported script filenames prevent script selection: ' .. name
            break
        end
    end
    summary(info, options)
    return info
end

local function collect(path, options)
    stop(options)
    local bytes, size = read(path, M.max_input_bytes)
    if not bytes then
        return {eligible = false, complete = false, reasons = {'Map exceeds the 256 MiB in-memory safety limit'},
            files = {}, largest = {}, duplicates = {}, import_issues = {}, input_size = size, input = path}
    end
    local info = mpq.inspect(bytes, options.cancelled)
    info.input_size, info.input = size, path
    local storm = options.storm or require 'ffi.stormlib'
    local archive, open_error = storm.open(path, true)
    if not archive then
        mpq.reason(info, 'StormLib cannot open the input archive: ' .. tostring(open_error or 'open failed'))
        summary(info, options)
        return info
    end
    local loaded, failure = xpcall(function()
        local listfile = archive:load_file('(listfile)', 16 * 1024 * 1024)
        if not listfile then mpq.reason(info, 'A readable listfile is required for a complete inventory') end
        local names = names_from_list(listfile)
        local cache, decoded_total = {}, 0
        local function provider(name)
            stop(options)
            local norm = mpq.normalized(name)
            if cache[norm] == nil then
                local payload = archive:load_file(name, M.max_input_bytes - decoded_total)
                cache[norm] = payload or false
                if payload then decoded_total = decoded_total + #payload end
            end
            return cache[norm] or nil
        end
        mpq.inventory(info, names, provider, options.cancelled)
        -- A partial analysis also discovers standard scripts even when the map's
        -- listfile does not name them. This never makes the optimizer eligible.
        local seen = {}
        for _, member in ipairs(info.files) do seen[mpq.normalized(member.name)] = true end
        for _, name in ipairs(known) do
            if not seen[mpq.normalized(name)] then
                local payload = provider(name)
                if payload then
                    info.files[#info.files + 1] = {name = name, bytes = payload, decoded_size = #payload, stored_size = nil}
                end
            end
        end
        mpq.validate_payloads(info, options.cancelled)
        summary(info, options)
    end, debug.traceback)
    local closed, close_error = archive:close()
    if closed == false then mpq.reason(info, 'Cannot close input archive: ' .. tostring(close_error)) end
    if not loaded then
        mpq.reason(info, 'Analysis could not finish: ' .. tostring(failure))
        summary(info, options)
    end
    stop(options)
    return info
end

local function pjass(info, options, phase)
    if options.w2l then
        local checker = require 'backend.jass_verify'
        if info.script_type_error then
            info.pjass = {phase = phase, dataset = options.w2l.setting and options.w2l.setting.data,
                status = 'Skipped', raw_output = '', diagnostics = {info.script_type_error}}
            checker.report(options.w2l, info.pjass)
        elseif info.provider then
            info.pjass = checker.check(options.w2l, {get = function(_, name) return info.provider(name) end},
                phase, {cancelled = options.cancelled, script_type = info.script_type})
        else
            info.pjass = {phase = phase, dataset = options.w2l.setting and options.w2l.setting.data,
                status = 'Unavailable', raw_output = '', diagnostics = {
                    'JASS verification requires readable archive contents; the analysis memory limit was reached.'}}
            checker.report(options.w2l, info.pjass)
        end
        return info.pjass
    end
end

function M.analyze(path, options)
    options = options or {}
    local now = options.now or os.clock
    local start = now()
    path = fs.path(path)
    local info = fs.is_directory(path) and collect_lni(path, options) or collect(path, options)
    pjass(info, options, 'Analyze input')
    info.elapsed = now() - start
    return info
end

local function same(original, candidate)
    assert(candidate.eligible and candidate.complete, 'Candidate inventory or framing is not eligible: ' .. table.concat(candidate.reasons, '; '))
    assert(candidate.prefix == original.prefix, 'Candidate changed the outer map header')
    assert(candidate.hash_bytes == original.hash_bytes and candidate.block_count == original.block_count,
        'Candidate changed filename identities or block indices')
    for index = 0, original.block_count - 1 do
        local before, after = original.by_block[index], candidate.by_block[index]
        assert(after and before.name == after.name and before.locale == after.locale and before.bytes == after.bytes,
            'Candidate changed a map file or bookkeeping payload: ' .. before.name)
    end
end
M.verify_candidate = same

local function temp_folder(parent)
    local pid = require('bee.subprocess').get_id()
    for _ = 1, 100 do
        sequence = sequence + 1
        local folder = parent / ('.w2l-optimize-%d-%d-%d'):format(pid, os.time(), sequence)
        if fs.create_directory(folder) then return folder end
    end
    error('Cannot create an optimizer temporary directory')
end

function M.optimize(input, output, options)
    options = options or {}
    local now = options.now or os.clock
    local start = now()
    input, output = fs.absolute(fs.path(input)), fs.absolute(fs.path(output))
    assert(not fs.is_directory(input), 'Optimize requires a packed MPQ map; LNI folders are analysis only')
    assert(input:string():lower() ~= output:string():lower(), 'Optimize requires a separate output path')
    assert(not fs.exists(output), 'Optimize will not overwrite an existing output')
    assert(fs.is_directory(output:parent_path()), 'The output parent folder must already exist')
    local info = collect(input, options)
    pjass(info, options, 'Optimize input')
    info.savings, info.output_size, info.candidates = 0, info.input_size, {}
    if not info.eligible then info.elapsed = now() - start; return info end
    local storm = options.storm or require 'ffi.stormlib'
    local folder = (options.temp_folder or temp_folder)(output:parent_path())
    local ok, err = xpcall(function()
        local best
        for i, sector_size in ipairs {512, 4096, 65536} do
            stop(options)
            local supported, unsupported_reason = true
            if storm.supports_sector_size then supported, unsupported_reason = storm.supports_sector_size(sector_size) end
            if not supported then
                info.candidates[#info.candidates + 1] = {sector_size = sector_size, verified = false, skipped = true, reason = unsupported_reason}
                if options.progress then options.progress(i / 3) end
            else
                local candidate_path = folder / ('candidate-%d.w3x'):format(sector_size)
                local candidate_bytes = mpq.encode(info, sector_size, storm.compress, options.cancelled, function(value)
                    if options.progress then options.progress((i - 1 + value) / 3) end
                end)
                write(candidate_path, candidate_bytes)
                local candidate = collect(candidate_path, options)
                same(info, candidate)
                local size = #candidate_bytes
                info.candidates[#info.candidates + 1] = {sector_size = sector_size, size = size, verified = true}
                if size < (best and best.size or info.input_size) then best = {path = candidate_path, size = size, sector_size = sector_size} end
                candidate, candidate_bytes = nil, nil
            end
        end
        stop(options)
        if best then
            -- Verify the source again before accepting output if another program
            -- edited the input while the candidates were being measured.
            local final = collect(best.path, options)
            same(info, final)
            info.pjass_output = pjass(final, options, 'Optimize output')
            stop(options)
            assert(read(best.path, M.max_input_bytes) == final.bytes, 'Candidate changed after verification')
            assert(read(input, M.max_input_bytes) == info.bytes, 'Input changed while optimization was running')
            assert(not fs.exists(output), 'Output was created by another program; no file was overwritten')
            -- The explicit Win32 MoveFileW adapter refuses an existing target.
            -- bee.filesystem rename may use a replacing STL implementation.
            local promote = assert(options.promote or storm.promote, 'No safe output-promotion adapter is available')
            local promoted, move_error = promote(best.path, output)
            assert(promoted ~= false and not move_error, move_error or 'Output promotion failed')
            assert(fs.exists(output) and not fs.exists(best.path), 'Output promotion did not complete')
            info.output, info.output_size, info.sector_size = output, best.size, best.sector_size
            info.savings = info.input_size - best.size
        end
    end, debug.traceback)
    -- The generated folder is an immediate child of the named output directory.
    if folder:parent_path():string() == output:parent_path():string() then pcall(fs.remove_all, folder) end
    if not ok then error(err) end
    info.elapsed = now() - start
    return info
end

return M