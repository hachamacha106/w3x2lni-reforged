-- Pure Lua regression tests: execute with Lua 5.4 by absolute path. Native
-- compression/reopening is covered separately by packaged Windows smoke tests.
local source = debug.getinfo(1, 'S').source:sub(2):gsub('\\', '/')
local root = assert(source:match('^(.*)/test/compat/lossless.lua$'))
package.path = root .. '/script/?.lua;' .. package.path
local mpq = require 'backend.lossless_mpq'
assert(mpq.hash('(hash table)', 3) == 0xC3AF3770 and mpq.hash('(block table)', 3) == 0xEC83B3A3,
    'MPQ table keys differ from the independent format constants')
assert(mpq.hash('war3map.j', 1) == 0xC99707E7 and mpq.hash('war3map.j', 2) == 0x95B8144E)
assert(mpq.hash('textures/a.blp', 1) ~= mpq.hash('textures\\a.blp', 1),
    'MPQ v1 HashStringSlash identities were collapsed')
local function rejected(info, pattern)
    assert(not info.eligible, 'Unsafe archive was eligible')
    for _, text in ipairs(info.reasons) do if text:find(pattern, 1, true) then return end end
    error('Missing eligibility explanation: ' .. pattern .. ': ' .. table.concat(info.reasons, '; '))
end
local function fixture(options)
    options = options or {}
    local names = {'war3map.j', 'textures\\a.blp', 'textures\\b.blp', 'unknown.sidecar', '(listfile)', '(attributes)'}
    local values = {'function main takes nothing returns nothing\nendfunction\n', 'opaque texture bytes',
        'opaque texture bytes', '\0\255unknown bytes', table.concat(names, '\r\n'), ''}
    local count, flags = #names, options.attr_flags or 7
    local attrs = {string.pack('<I4I4', options.attr_version or 100, flags)}
    for _, group in ipairs {{1, 4}, {2, 8}, {4, 16}} do
        if flags & group[1] ~= 0 then
            for index = 1, count do attrs[#attrs + 1] = string.rep(string.char(index), group[2]) end
        end
    end
    values[count] = table.concat(attrs) .. (options.attr_suffix or '')
    if options.script then values[1] = options.script end
    local hashes, block_records, chunks, offset, hash_count = {}, {}, {}, 32, 16
    for i = 1, hash_count do hashes[i] = string.rep('\255', 16) end
    for index, name in ipairs(names) do
        local slot = (mpq.hash(name, 0) & (hash_count - 1)) + 1
        while hashes[slot] ~= string.rep('\255', 16) do slot = slot % hash_count + 1 end
        hashes[slot] = string.pack('<I4I4I2BBI4', mpq.hash(name, 1), mpq.hash(name, 2),
            index == 2 and (options.locale or 0) or 0, options.platform or 0, 0, index - 1)
        local payload, block_flags = values[index], 0x80000000
        if index == 1 and options.file_flags then block_flags = block_flags | options.file_flags end
        block_records[index] = string.pack('<I4I4I4I4', offset, #payload, #payload, block_flags)
        chunks[#chunks + 1], offset = payload, offset + #payload
    end
    if options.renamed_list then
        values[5] = options.renamed_list
        chunks[5] = values[5]
        -- Rebuild all positions after the altered listfile payload.
        offset = 32
        for index, payload in ipairs(chunks) do
            block_records[index] = string.pack('<I4I4I4I4', offset, #payload, #payload, 0x80000000)
            offset = offset + #payload
        end
    end
    local gap = options.gap or string.rep('\0', 128)
    chunks[#chunks + 1], offset = gap, offset + #gap
    local hash_pos, block_pos = offset, offset + hash_count * 16
    local hash_bytes = mpq.table_crypt(table.concat(hashes), mpq.hash('(hash table)', 3), true)
    local block_bytes = mpq.table_crypt(table.concat(block_records), mpq.hash('(block table)', 3), true)
    local archive_size = block_pos + #block_bytes
    local header = 'MPQ\26' .. string.pack('<I4I4I2I2I4I4I4I4', 32, archive_size, options.version or 0, 7,
        hash_pos, block_pos, hash_count, count)
    local prefix = options.prefix or ''
    local bytes = prefix .. header .. table.concat(chunks) .. hash_bytes .. block_bytes .. (options.suffix or '')
    local lookup = {}
    for i, name in ipairs(names) do lookup[mpq.normalized(name)] = values[i] end
    return bytes, names, function(name) return lookup[mpq.normalized(name)] end
end
local function inspect(options)
    local bytes, names, provider = fixture(options)
    local info = mpq.inspect(bytes)
    mpq.inventory(info, names, provider)
    mpq.validate_payloads(info)
    return info
end
local info = inspect()
assert(info.eligible and info.complete and #info.files == 6)
local candidate_bytes = mpq.encode(info, 512, function(bytes) return bytes end)
local candidate = mpq.inspect(candidate_bytes)
local names = {}
for _, member in ipairs(info.files) do names[#names + 1] = member.name end
mpq.inventory(candidate, names, function(name)
    for _, member in ipairs(info.files) do if member.name == name then return member.bytes end end
end)
mpq.validate_payloads(candidate)
assert(candidate.eligible and #candidate_bytes < #info.bytes)
assert(candidate.hash_bytes == info.hash_bytes and candidate.block_count == info.block_count)
for i = 0, info.block_count - 1 do
    assert(candidate.by_block[i].bytes == info.by_block[i].bytes, 'Payload or metadata changed')
end
local prefix = 'HM3W\0\0\0\0Map\0' .. string.pack('<I4I4', 0xFFFFFFFF, 2)
prefix = prefix .. string.rep('\0', 512 - #prefix)
local headed = inspect {prefix = prefix}
assert(headed.eligible and mpq.encode(headed, 4096, function(bytes) return bytes end):sub(1, 512) == prefix)
rejected(inspect {prefix = string.rep('?', 512)}, 'before the MPQ')
rejected(inspect {suffix = 'unknown trailing bytes'}, 'Trailing data')
rejected(inspect {gap = 'opaque unreferenced data'}, 'Unexplained nonzero bytes')
rejected(inspect {locale = 1033}, 'Additional locales')
rejected(inspect {platform = 1}, 'Additional locales')
rejected(inspect {file_flags = 0x10000}, 'Encrypted files')
rejected(inspect {file_flags = 0x4000000}, 'Unsupported file flags')
rejected(inspect {version = 1}, 'Only MPQ v1')
rejected(inspect {attr_flags = 8}, 'Unsupported attributes')
rejected(inspect {attr_version = 101}, 'Unsupported attributes')
rejected(inspect {attr_suffix = '\0'}, 'Unsupported attributes')
local incomplete_bytes, _, incomplete_provider = fixture()
local incomplete = mpq.inspect(incomplete_bytes)
mpq.inventory(incomplete, {'war3map.j', '(listfile)', '(attributes)'}, incomplete_provider)
rejected(incomplete, 'inventory is incomplete')
local malformed = mpq.inspect('MPQ\26' .. string.pack('<I4', 32) .. string.rep('\0', 24))
rejected(malformed, 'Malformed archive')
local cancelled = pcall(mpq.encode, info, 512, function(bytes) return bytes end, function() return true end)
assert(not cancelled, 'Cancelled optimization continued encoding')

local function changed_table(bytes, table_name, change)
    local _, _, _, _, hash_pos, block_pos, hash_count, block_count = string.unpack('<I4I4I2I2I4I4I4I4', bytes, 5)
    local pos = table_name == '(hash table)' and hash_pos or block_pos
    local count = table_name == '(hash table)' and hash_count or block_count
    local key = mpq.hash(table_name, 3)
    local plain = mpq.table_crypt(bytes:sub(pos + 1, pos + count * 16), key)
    local rewritten = mpq.table_crypt(change(plain), key, true)
    return bytes:sub(1, pos) .. rewritten .. bytes:sub(pos + count * 16 + 1)
end
local alias = changed_table(info.bytes, '(hash table)', function(table_bytes)
    for pos = 1, #table_bytes, 16 do
        if string.unpack('<I4', table_bytes, pos + 12) == 1 then
            return table_bytes:sub(1, pos + 11) .. string.pack('<I4', 0) .. table_bytes:sub(pos + 16)
        end
    end
    error('Missing fixture hash')
end)
rejected(mpq.inspect(alias), 'alias the same block')
local orphan = changed_table(info.bytes, '(block table)', function(table_bytes)
    return table_bytes:sub(1, 12) .. string.pack('<I4', 0) .. table_bytes:sub(17)
end)
rejected(mpq.inspect(orphan), 'Orphan or deleted')
local overlap = changed_table(info.bytes, '(block table)', function(table_bytes)
    return string.pack('<I4', 33) .. table_bytes:sub(5)
end)
rejected(mpq.inspect(overlap), 'Overlapping MPQ')
local source_compressed = inspect {script = string.rep('A', 512)}
local compressed_bytes = mpq.encode(source_compressed, 512, function(bytes)
    if bytes == string.rep('A', 512) then
        return '\2' .. ('789c73741c05231900004a9e8201'):gsub('..', function(pair) return string.char(tonumber(pair, 16)) end)
    end
    return bytes
end)
local compressed_info = mpq.inspect(compressed_bytes)
local compressed_names = {}
for _, member in ipairs(source_compressed.files) do compressed_names[#compressed_names + 1] = member.name end
mpq.inventory(compressed_info, compressed_names, function(name)
    for _, member in ipairs(source_compressed.files) do if member.name == name then return member.bytes end end
end)
mpq.validate_payloads(compressed_info)
assert(compressed_info.eligible and compressed_info.by_block[0].block.flags & 0x200 ~= 0)

print('PASS lossless MPQ inventory, opaque-data guards, metadata bytes, map-header preservation and cancellation')

local function unhex(hex) return (hex:gsub('..', function(pair) return string.char(tonumber(pair, 16)) end)) end
local zlib = unhex('789c73741c05231900004a9e8201')
assert(mpq.zlib_exact(zlib, string.rep('A', 512)))
assert(not pcall(mpq.zlib_exact, zlib .. 'ignored suffix', string.rep('A', 512)))
assert(not pcall(mpq.zlib_exact, zlib:sub(1, -2), string.rep('A', 512)))
assert(not pcall(mpq.zlib_exact, zlib, string.rep('B', 512)))
assert(not pcall(mpq.zlib_exact, zlib, string.rep('A', 511)))
-- BCD and CAE have identical Adler32 and length; only exact bytes are proof.
assert(not pcall(mpq.zlib_exact, unhex('789c7372760100019300ca'), 'CAE'))
local long_stream = unhex('789cedc13101000000c2a06ceb5fcac31a4001000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000dc00762f079f')
local polls = 0
local finished, cancelled_error = pcall(mpq.zlib_exact, long_stream, string.rep('A', 131072), function()
    polls = polls + 1
    return true
end)
assert(not finished and polls > 0 and cancelled_error:find('Optimization cancelled', 1, true),
    'Long-member DEFLATE validation did not respond to cancellation')
print('PASS exact zlib stream boundaries and decoded checksums reject ignored suffixes')

-- Execute the production archive wrapper against an injected native boundary.
local fail, calls = {}, {}
local native = setmetatable({}, {__index = function(_, name)
    return function(...)
        calls[name] = (calls[name] or 0) + 1
        if name == 'SFileCreateArchive2' or name == 'SFileOpenArchive' then
            local args = {...}; args[#args][0] = 10
        elseif name == 'SFileCreateFile' then local args = {...}; args[#args][0] = 20 end
        return not fail[name]
    end
end})
local ffi = {
    cdef = function() end, sizeof = function() return 48 end, load = function() return native end,
    new = function() return {[0] = 0} end,
    C = {GetLastError = function() return 77 end, GetSystemTime = function() end,
        SystemTimeToFileTime = function() return 0 end},
}
local dependencies = {ffi = ffi, ['ffi.loaddll'] = function() end, ['bee.filesystem'] = {},
    ['ffi.unicode'] = {u2w = function(path) return path end}}
local environment = setmetatable({require = function(name) return assert(dependencies[name], name) end}, {__index = _G})
local storm = assert(loadfile(root .. '/script/ffi/stormlib.lua', 't', environment))()
local path = {string = function() return 'test.w3x' end}
local readonly = assert(storm.open(path, true))
assert(readonly:close())
assert(not calls.SFileCompactArchive, 'Read-only close attempted compaction')
for _, operation in ipairs {'SFileCreateFile', 'SFileWriteFile', 'SFileFinishFile'} do
    fail, calls = {[operation] = true}, {}
    local archive = assert(storm.create(path, 16))
    local ok, err = archive:save_file('unknown.sidecar', 'preserve me', 0)
    assert(ok == false and err:find(operation, 1, true), 'Failed write was reported as success: ' .. operation)
    if operation == 'SFileWriteFile' then assert(calls.SFileFinishFile == 1, 'Failed write leaked an open member') end
end
for _, operation in ipairs {'SFileCompactArchive', 'SFileCloseArchive'} do
    fail, calls = {[operation] = true}, {}
    local archive = assert(storm.create(path, 16))
    local ok, err = archive:close()
    assert(ok == false and err:find(operation, 1, true))
    assert(calls.SFileCloseArchive == 1, 'Compaction failure prevented handle cleanup')
end
print('PASS real archive wrapper propagates create/write/finish/compact/close failures and closes read-only safely')

local dependencies_outer = {['share.lang'] = {}, ['bee.filesystem'] = {is_directory = function() return false end},
    ['map-builder.archive_mpq'] = function()
        return {save = function() return true end,
            save_file = function(_, name) return false, 'injected write error' end,
            close = function() return true end}
    end, ['map-builder.archive_dir'] = {}}
local outer = assert(loadfile(root .. '/script/map-builder/archive.lua', 't', setmetatable({
    require = function(name) return assert(dependencies_outer[name], name) end}, {__index = _G})))()
local archive = outer({}, 'w')
archive:set('broken.sidecar', 'bytes')
local saved, err = archive:save(nil, nil, {setting = {}, progress = function() end})
assert(not saved and err:find('broken.sidecar', 1, true), 'Outer save ignored member failure')
local save_map = assert(loadfile(root .. '/script/map-builder/save_map.lua', 't', setmetatable({
    require = function() return {script = {}} end}, {__index = _G})))()
local ok, err = pcall(save_map, {setting = {}, failed = function(_, text) error(text) end}, nil, nil,
    {close = function() return true end}, {save = function() return true end,
        close = function() return false, 'injected output close failure' end})
assert(not ok and err:find('injected output close failure', 1, true))
print('PASS outer archive writer reports member and finalization failures')
-- Exercise the actual optimizer lifecycle with a deterministic MPQ boundary.
-- The injected codec stores raw sectors; archive parsing and candidate acceptance
-- remain production code. Real codecs and DLL ABI are tested in Windows smoke.
local disks, dirs = {}, {['/maps'] = true}
local path_mt = {}
path_mt.__index = path_mt
function path_mt:string() return self.value end
function path_mt:parent_path() return setmetatable({value = self.value:match('^(.*)/[^/]+$') or '/'}, path_mt) end
function path_mt:__div(name) return setmetatable({value = self.value .. '/' .. tostring(name)}, path_mt) end
local function test_path(value)
    if type(value) == 'table' then return value end
    return setmetatable({value = value}, path_mt)
end
local test_fs = {
    path = test_path, absolute = test_path,
    exists = function(path) return disks[path:string()] ~= nil or dirs[path:string()] == true end,
    is_directory = function(path) return dirs[path:string()] == true end,
    create_directory = function(path)
        if dirs[path:string()] then return false end
        dirs[path:string()] = true; return true
    end,
    rename = function(from, to)
        if disks[to:string()] ~= nil then return nil, 'destination already exists' end
        disks[to:string()], disks[from:string()] = disks[from:string()], nil
    end,
    remove_all = function(folder)
        local prefix = folder:string() .. '/'
        for name in pairs(disks) do if name:sub(1, #prefix) == prefix then disks[name] = nil end end
        dirs[folder:string()] = nil
    end,
}
local test_io = {open = function(path, mode)
    local position, data = 0, disks[path]
    if mode == 'rb' and data == nil then return nil, 'missing fixture' end
    return {
        seek = function(_, where)
            if where == 'end' then position = #data else position = 0 end
            return position
        end,
        read = function() return data end,
        write = function(_, bytes) disks[path] = bytes; return true end,
        close = function() return true end,
    }
end}
local test_storm = {compress = function(bytes) return bytes end, promote = test_fs.rename}
function test_storm.open(path, readonly)
    assert(readonly, 'Optimizer opened an input or candidate for writing')
    local parsed = mpq.inspect(assert(disks[path:string()]))
    return {
        load_file = function(_, name, max_size)
            if not parsed.hashes then return nil end
            for _, hash in ipairs(parsed.hashes) do
                if hash.block < 0xFFFFFFFE and hash.a == mpq.hash(name, 1) and hash.b == mpq.hash(name, 2) then
                    local block = parsed.blocks[hash.block + 1]
                    if max_size and block.decoded_size > max_size then return nil end
                    assert(block.flags & 0x200 == 0, 'Fixture boundary expects raw stored members')
                    return parsed.bytes:sub(parsed.offset + block.offset + 1, parsed.offset + block.offset + block.stored_size)
                end
            end
        end,
        close = function() return true end,
    }
end
local verification_phases = {}
local runtime_deps = {['bee.filesystem'] = test_fs, ['backend.lossless_mpq'] = mpq,
    ['bee.subprocess'] = {get_id = function() return 1 end},
    ['backend.jass_verify'] = {check = function(_, provider, phase)
        assert(provider:get('war3map.j'), 'JASS verification did not receive script bytes')
        verification_phases[#verification_phases + 1] = phase
        return {status = 'Failed', diagnostics = {'deliberately report-only'}}
    end}}
local runtime = assert(loadfile(root .. '/script/backend/lossless.lua', 't', setmetatable({io = test_io,
    require = function(name) return assert(runtime_deps[name], name) end}, {__index = _G})))()
local original = fixture()
disks['/maps/source.w3x'] = original
local analysis = runtime.analyze('/maps/source.w3x', {storm = test_storm, w2l = {}})
assert(analysis.eligible and analysis.complete and #analysis.duplicates == 1)
assert(analysis.duplicates[1].names[1] == 'textures\\a.blp' and analysis.pjass.status == 'Failed')
assert(disks['/maps/source.w3x'] == original and not disks['/maps/output.w3x'])
local optimized = runtime.optimize('/maps/source.w3x', '/maps/output.w3x', {storm = test_storm, w2l = {}})
assert(optimized.output and optimized.savings == 128 and #optimized.candidates == 3)
assert(optimized.pjass_output.status == 'Failed', 'Failed pjass result blocked verified output')
assert(disks['/maps/source.w3x'] == original)
for name in pairs(disks) do assert(not name:find('.w2l-optimize', 1, true), 'Candidate cleanup failed') end
local raced = pcall(runtime.optimize, '/maps/source.w3x', '/maps/raced.w3x', {storm = test_storm,
    promote = function(from, to)
        disks[to:string()] = 'another program owns this file'
        return test_fs.rename(from, to)
    end})
assert(not raced and disks['/maps/raced.w3x'] == 'another program owns this file',
    'A destination race replaced an unrelated output')
local previous = disks['/maps/output.w3x']
assert(not pcall(runtime.optimize, '/maps/source.w3x', '/maps/output.w3x', {storm = test_storm}))
assert(disks['/maps/output.w3x'] == previous, 'Existing output was overwritten')
assert(not pcall(runtime.optimize, '/maps/source.w3x', '/maps/source.w3x', {storm = test_storm}))
disks['/maps/no-slack.w3x'] = fixture {gap = ''}
local unchanged = runtime.optimize('/maps/no-slack.w3x', '/maps/no-savings.w3x', {storm = test_storm})
assert(unchanged.savings == 0 and not unchanged.output and not disks['/maps/no-savings.w3x'])
local events = 0
local cancelled = pcall(runtime.optimize, '/maps/source.w3x', '/maps/cancelled.w3x', {storm = test_storm,
    cancelled = function() return events > 0 end, progress = function() events = events + 1 end})
assert(not cancelled and not disks['/maps/cancelled.w3x'] and disks['/maps/source.w3x'] == original)
local failed = pcall(runtime.optimize, '/maps/source.w3x', '/maps/failed.w3x', {
    storm = {open = test_storm.open, compress = function() return nil, 'injected compression failure' end}})
assert(not failed and not disks['/maps/failed.w3x'])
local verification_failure = pcall(runtime.optimize, '/maps/source.w3x', '/maps/unverified.w3x', {
    storm = {compress = test_storm.compress, open = function(path, readonly)
        local archive = test_storm.open(path, readonly)
        local load = archive.load_file
        if path:string():find('candidate-', 1, true) then
            archive.load_file = function(self, name, limit)
                if name == 'unknown.sidecar' then return 'CORRUPTED BY TEST' end
                return load(self, name, limit)
            end
        end
        return archive
    end}})
assert(not verification_failure and not disks['/maps/unverified.w3x'])
for name in pairs(disks) do assert(not name:find('.w2l-optimize', 1, true), 'Failure left a partial candidate') end
print('PASS Analyze read-only behavior, duplicates, smaller-only output, report-only pjass, cancellation and verification failure cleanup')
-- The graphical worker owns a cancellation marker. The CLI only observes it;
-- it must not delete an arbitrary user-supplied path or mislabel other failures.
for _, action in ipairs {'analyze', 'optimize'} do
    local marker_present, removed, exit_result, log_bytes = false, false
    local cli_fs = {
        path = test_path, absolute = test_path,
        create_directories = function() end,
        is_regular_file = function() return true end,
        exists = function(path) return path:string() == '/maps/cancel.signal' and marker_present end,
        remove = function() removed = true; error('CLI must not remove cancellation markers') end,
    }
    local cli_messager = {title = function() end, progress = function() end, report = function() end,
        exit = function(kind, content) exit_result = {kind = kind, content = content} end}
    local cli_deps = {
        ['bee.filesystem'] = cli_fs, ['backend.w2l_path'] = test_path('/package'),
        ['backend.base_path'] = test_path('/maps'), ['backend.command'] = {['cancel-file'] = '/maps/cancel.signal'},
        ['share.messager'] = cli_messager, ['bee.time'] = {monotonic = function() return 100 end},
        ['backend.unpack_setting'] = function()
            return {input = test_path('/maps/source.w3x'), output = test_path('/maps/new-output.w3x')}
        end,
        ['backend.sandbox_core'] = function()
            return {set_messager = function() end, set_setting = function() end}
        end,
    }
    local function operation(_, options_or_output, optimize_options)
        local options = optimize_options or options_or_output
        assert(not options.cancelled(), 'A nonexistent marker cancelled the operation')
        marker_present = true
        assert(options.cancelled(), 'CLI did not observe the cancellation marker')
        marker_present = false
        assert(options.cancelled(), 'Cancellation was not latched after being requested')
        error('Optimization cancelled')
    end
    cli_deps['backend.lossless'] = {analyze = operation, optimize = operation}
    local cli = assert(loadfile(root .. '/script/backend/lossless_cli.lua', 't', setmetatable({
        io = {save = function(_, bytes) log_bytes = bytes; return true end},
        require = function(name) return assert(cli_deps[name], name) end}, {__index = _G})))()
    cli(action)
    assert(exit_result.kind == 'warning' and exit_result.content == 'Cancelled')
    assert(log_bytes:find('Operation cancelled', 1, true) and not removed)
    -- A cancelled report-only pjass call can return Unavailable normally. The
    -- CLI still observes cancellation after the operation has returned.
    local function completed(_, options_or_output, optimize_options)
        marker_present = true
        return {input_size = 100, complete = true, eligible = true, elapsed = 0,
            reasons = {}, largest = {}, duplicates = {}, import_issues = {}, candidates = {}}
    end
    cli_deps['backend.lossless'][action] = completed
    cli(action)
    assert(exit_result.kind == 'warning' and exit_result.content == 'Cancelled',
        'Cancellation during a report-only checker was ignored')
    assert(marker_present and not removed, 'The CLI removed a marker owned by its caller')
    -- A promoted output is complete and must stay accepted when a late marker
    -- arrives. Reporting it as cancelled would contradict the saved map.
    if action == 'optimize' then
        cli_deps['backend.lossless'].optimize = function(...)
            local info = completed(...)
            info.output = test_path('/maps/completed.w3x')
            info.output_size, info.savings = 90, 10
            return info
        end
        cli(action)
        assert(exit_result.kind == 'success', 'A completed atomic output was mislabeled cancellation')
    end
    cli_deps['backend.lossless'][action] = function(_, options_or_output, optimize_options)
        local options = optimize_options or options_or_output
        marker_present = true
        assert(options.cancelled())
        error('injected unrelated archive failure')
    end
    cli(action)
    assert(exit_result.kind == 'error', 'An unrelated archive failure was hidden by a cancellation marker')
    cli_deps['backend.command']['cancel-file'] = nil
    cli(action)
    assert(exit_result.kind == 'error', 'An ordinary failure was mislabeled cancellation')
end
print('PASS Analyze/Optimize CLI cancellation, post-checker marker, completed output and marker ownership')
