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
-- Inspection can retain only a prefix of a malformed table. Analysis may
-- report those records, but absent metadata must not become invented members
-- or permit a rewrite of an archive whose inventory cannot be proved.
do
    local original, fixture_names, fixture_provider = fixture()
    local function preserve_failure(parsed, before, bytes)
        assert(not parsed.complete and not parsed.eligible, 'Partial MPQ metadata became a complete inventory')
        for _, explanation in ipairs(before) do rejected(parsed, explanation) end
        local compressed = false
        local accepted, explanation = pcall(mpq.encode, parsed, 4096, function(payload)
            compressed = true
            return payload
        end)
        assert(not accepted and explanation:find('Cannot encode an unverified inventory', 1, true)
            and not compressed, 'Partial metadata reached archive encoding')
        assert(parsed.bytes == bytes and original == fixture(), 'Malformed inventory changed the original archive bytes')
    end
    for _, malformed_index in ipairs {0, 4} do
        local damaged = changed_table(original, '(block table)', function(table_bytes)
            local first = malformed_index * 16 + 1
            return table_bytes:sub(1, first - 1) .. string.pack('<I4', #original) .. table_bytes:sub(first + 4)
        end)
        local parsed = mpq.inspect(damaged)
        assert(#parsed.hashes == parsed.hash_count and #parsed.blocks == malformed_index + 1,
            'Malformed block fixture did not leave the intended partial block table')
        rejected(parsed, 'File block exceeds the MPQ boundary')
        local before, called = {}, {}
        for _, explanation in ipairs(parsed.reasons) do before[#before + 1] = explanation end
        mpq.inventory(parsed, fixture_names, function(name)
            for index, fixture_name in ipairs(fixture_names) do
                if name == fixture_name then
                    assert(index <= #parsed.blocks, 'Provider was called for missing block metadata')
                    called[index] = true
                    return fixture_provider(name)
                end
            end
            error('Provider received an invented archive name')
        end)
        rejected(parsed, 'MPQ block-table metadata is unavailable')
        for index = #parsed.blocks + 1, #fixture_names do
            assert(not called[index] and not parsed.by_block[index - 1], 'Absent block metadata became a member')
        end
        preserve_failure(parsed, before, damaged)
        local accepted, explanation = pcall(mpq.inventory, mpq.inspect(damaged), fixture_names,
            function() error('Cancelled inventory reached its provider') end, function() return true end)
        assert(not accepted and explanation:find('Optimization cancelled', 1, true),
            'Partial block-table inventory ignored cancellation')
    end
    local damaged = changed_table(original, '(hash table)', function(table_bytes)
        for first = 1, #table_bytes, 16 do
            if string.unpack('<I4', table_bytes, first + 12) < 0xFFFFFFFE then
                return table_bytes:sub(1, first + 11) .. string.pack('<I4', #fixture_names) .. table_bytes:sub(first + 16)
            end
        end
        error('No live hash-table entry in fixture')
    end)
    local parsed = mpq.inspect(damaged)
    assert(#parsed.hashes < parsed.hash_count and #parsed.blocks == 0,
        'Malformed hash fixture did not leave the intended partial hash table')
    rejected(parsed, 'Hash entry references a missing block')
    local before, partial_names = {}, {}
    for _, explanation in ipairs(parsed.reasons) do before[#before + 1] = explanation end
    for _, name in ipairs(fixture_names) do partial_names[#partial_names + 1] = name end
    -- Begin directly in the unparsed suffix, rather than relying on a live
    -- filename's probe chain to happen to reach a missing candidate.
    for index = 1, 100 do
        local name = 'unparsed-hash-candidate-' .. index
        if (mpq.hash(name, 0) & (parsed.hash_count - 1)) + 1 > #parsed.hashes then
            partial_names[#partial_names + 1] = name
            break
        end
    end
    assert(#partial_names == #fixture_names + 1, 'No name probes the missing hash suffix')
    mpq.inventory(parsed, partial_names, function() error('Provider was called without any block metadata') end)
    rejected(parsed, 'MPQ hash-table metadata is unavailable')
    rejected(parsed, 'MPQ block-table metadata is unavailable')
    assert(#parsed.files == 0 and next(parsed.by_block) == nil, 'Partial hash table manufactured archive members')
    preserve_failure(parsed, before, damaged)
    local accepted, explanation = pcall(mpq.inventory, mpq.inspect(damaged), partial_names,
        function() error('Cancelled inventory reached its provider') end, function() return true end)
    assert(not accepted and explanation:find('Optimization cancelled', 1, true),
        'Partial hash-table inventory ignored cancellation')
    -- Zero payloads do not prove that the entire hash table was inspected.
    -- Removing a parsed sentinel models unavailable table metadata without a
    -- live reference that could otherwise force the member count incomplete.
    local empty_hash_bytes = mpq.table_crypt(string.rep('\255', 16 * 16), mpq.hash('(hash table)', 3), true)
    local empty_bytes = 'MPQ\26' .. string.pack('<I4I4I2I2I4I4I4I4', 32, 32 + #empty_hash_bytes, 0, 7,
        32, 32 + #empty_hash_bytes, 16, 0) .. empty_hash_bytes
    local empty = mpq.inspect(empty_bytes)
    assert(empty.eligible and #empty.hashes == 16 and #empty.blocks == 0)
    empty.hashes[16] = nil
    mpq.inventory(empty, {}, function() error('Empty inventory reached its provider') end)
    rejected(empty, 'MPQ hash-table metadata is unavailable')
    preserve_failure(empty, {}, empty_bytes)
end
print('PASS partial MPQ table diagnostics, unresolved member guards, rewrite refusal and cancellation')

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

-- Read-only LNI analysis uses the real escaped directory traversal and real
-- analysis logic; no map assembly or archive writes are available in this seam.
function path_mt:filename() return test_path(self.value:match('[^/]+$') or '') end
local entry_types, canonical_paths, unreadable, read_paths = {}, {}, {}, {}
function test_fs.canonical(path) return test_path(canonical_paths[path:string()] or path:string()) end
function test_fs.symlink_status(path)
    local kind = entry_types[path:string()] or (dirs[path:string()] and 'directory')
        or (disks[path:string()] and 'regular') or 'not_found'
    return {type = function() return kind end}
end
function test_fs.pairs(path)
    assert(not unreadable[path:string()], 'injected unreadable project directory')
    local prefix, names, seen = path:string() .. '/', {}, {}
    for _, entries in ipairs {disks, dirs, entry_types} do
        for name in pairs(entries) do
            if name:sub(1, #prefix) == prefix and not name:sub(#prefix + 1):find('/', 1, true) and not seen[name] then
                names[#names + 1], seen[name] = test_path(name), true
            end
        end
    end
    table.sort(names, function(a, b) return a:string() < b:string() end)
    local index = 0
    return function() index = index + 1; return names[index] end
end
local directory_deps = {['bee.filesystem'] = test_fs, ['map-builder.path_filter'] = function() end}
local directory = assert(loadfile(root .. '/script/map-builder/archive_dir.lua', 't', setmetatable({
    require = function(name) return assert(directory_deps[name], name) end}, {__index = _G})))()
runtime_deps['map-builder.archive_dir'] = directory
runtime_deps['share.check_lni_mark'] = assert(loadfile(root .. '/script/share/check_lni_mark.lua'))()
runtime_deps['share.lang'] = {w3i = {MAP = 'map', SCRIPT_TYPE = 'script_type'}}
local native_open = test_io.open
function test_io.open(path, mode)
    assert(mode == 'rb', 'LNI analysis attempted a file write')
    read_paths[path] = true
    if unreadable[path] then return nil, 'injected unreadable project member' end
    if path:sub(-9) == 'large.bin' then
        return {seek = function(_, where) return where == 'end' and runtime.max_input_bytes + 1 or 0 end,
            read = function() error('Oversized project member was read') end, close = function() return true end}
    end
    return native_open(path, mode)
end
local lni_root = '/maps/Exported LNI'
for _, dir in ipairs {'', '/map', '/resource', '/resource/Textures', '/sound', '/scripts', '/table', '/trigger', '/w3x2lni', '/.git'} do
    dirs[lni_root .. dir] = true
end
local valid_jass = 'function main takes nothing returns nothing\nendfunction\n'
local import_bytes, language_bytes = 'test-import-list', 'test-JASS-language'
local lni_files = {
    ['.w3x'] = 'HM3W' .. string.rep(string.char(0), 4) .. 'W2L' .. string.char(1) .. 'unknown marker bytes',
    ['map/war3map.j'] = valid_jass, ['war3map.j'] = 'project-only root script must not replace the map script',
    ['map/unknown.sidecar'] = string.char(0, 255) .. 'opaque', ['resource/Textures/a.blp'] = 'same texture',
    ['resource/Textures/b.blp'] = 'same texture', ['resource/texture$24tag.blp'] = 'escaped filename',
    ['resource/texture$2fpart.blp'] = 'forward slash filename',
    ['sound/theme.wav'] = 'sound bytes', ['scripts/common.j'] = 'map-bundled declarations',
    ['table/imp.ini'] = import_bytes, ['table/w3i.ini'] = language_bytes,
    ['trigger/unknown.lml'] = 'project trigger source', ['w3x2lni/unknown.cache'] = 'preserved auxiliary file',
}
local original_lni, total = {}, 0
for name, bytes in pairs(lni_files) do
    disks[lni_root .. '/' .. name] = bytes
    original_lni[lni_root .. '/' .. name] = bytes
    total = total + #bytes
end
disks[lni_root .. '/.git/config'] = 'development metadata ignored by the existing LNI archive rules'
local checker_options, checker_script, checked = nil, nil, 0
runtime_deps['backend.jass_verify'] = {
    check = function(_, provider, phase, options)
        checked = checked + 1
        checker_options, checker_script = options, provider:get('war3map.j')
        assert(provider:get('common.j') == nil and provider:get('scripts\\common.j') == 'map-bundled declarations')
        return {phase = phase, status = options.script_type == 'Lua' and 'Skipped' or 'Failed',
            diagnostics = {'deliberately report-only'}, raw_output = ''}
    end,
    report = function(_, result) assert(result.status == 'Skipped') end,
}
runtime_deps['lni'] = function(bytes)
    if bytes == import_bytes then return {import = {'Textures\\a.blp', 'theme.wav', 'texture$tag.blp', 'texture/part.blp', 'missing.bin'}} end
    if bytes == language_bytes then return {map = {script_type = 'JASS'}} end
    if bytes == 'test-Lua-language' then return {map = {script_type = 'Lua'}} end
    if bytes == 'test-localized-Lua-language' then return {project_map = {project_language = 'Lua'}} end
    if bytes == 'test-legacy-import-list' then return {root = {import = {'Textures\\a.blp'}}} end
    if bytes == 'test-invalid-import-list' then return {import = {[1] = 'Textures\\a.blp', [3] = 'missing.bin'}} end
    if bytes == 'test-invalid-import-root' then return {root = 5} end
    error('injected malformed LNI metadata')
end
local w2l = {setting = {data = 'warcraft-current'}}
local folder_info = runtime.analyze(lni_root, {w2l = w2l})
assert(folder_info.input_type == 'lni' and folder_info.complete and not folder_info.eligible)
assert(#folder_info.files == 14 and folder_info.input_size == total and #folder_info.duplicates == 1)
assert(folder_info.duplicates[1].names[1] == 'resource\\Textures\\a.blp')
assert(#folder_info.import_issues == 1 and folder_info.import_issues[1] == 'Missing imported file: missing.bin')
assert(checker_script == valid_jass and checker_options.script_type == 'JASS' and folder_info.pjass.status == 'Failed')
assert(folder_info.provider('unknown.sidecar') == string.char(0, 255) .. 'opaque')
assert(folder_info.provider('texture$tag.blp') == 'escaped filename' and folder_info.provider('texture/part.blp') == 'forward slash filename')
assert(folder_info.provider('unknown.cache') == nil and folder_info.provider('w3x2lni\\unknown.cache') == 'preserved auxiliary file')
assert(not read_paths[lni_root .. '/.git/config'], 'Development metadata became map content')
for path, bytes in pairs(original_lni) do assert(disks[path] == bytes, 'Analyze changed exported project bytes') end
local accepted, message = pcall(runtime.optimize, lni_root, '/maps/LNI must not optimize.w3x', {w2l = w2l})
assert(not accepted and message:find('LNI folders are analysis only', 1, true) and not disks['/maps/LNI must not optimize.w3x'])
-- The iterator explicitly disqualifies linked/special/outside-root entries.
entry_types[lni_root .. '/external link'] = 'symlink'
entry_types[lni_root .. '/special fifo'] = 'fifo'
disks[lni_root .. '/map/outside.bin'] = 'must not be read'
canonical_paths[lni_root .. '/map/outside.bin'] = '/outside/map-data.bin'
folder_info = runtime.analyze(lni_root, {w2l = w2l})
assert(not folder_info.complete and not read_paths['/outside/map-data.bin'])
rejected(folder_info, 'symlink'); rejected(folder_info, 'fifo'); rejected(folder_info, 'outside the input folder')
entry_types[lni_root .. '/external link'], entry_types[lni_root .. '/special fifo'] = nil, nil
disks[lni_root .. '/map/outside.bin'], canonical_paths[lni_root .. '/map/outside.bin'] = nil, nil
local skipped = {}
local finished = directory(test_path(lni_root), true):foreach_file(function() end,
    {max_entries = 2, skipped = function(name, reason) skipped[#skipped + 1] = reason end})
assert(not finished and skipped[1]:find('entry safety limit', 1, true), 'Directory inventory ignored its entry bound')
finished = directory(test_path(lni_root), true):foreach_file(function() end,
    {max_depth = 0, skipped = function(name, reason) skipped[#skipped + 1] = reason end})
assert(finished and skipped[#skipped]:find('nesting exceeds', 1, true))
assert(not pcall(directory(test_path(lni_root), false).foreach_file,
    directory(test_path(lni_root), false), function() end), 'Writable directory exposed diagnostic traversal')
-- Wrongly placed file types keep the same logical names as core.proxy.
disks[lni_root .. '/map/misplaced.blp'] = 'misplaced asset retained'
folder_info = runtime.analyze(lni_root, {w2l = w2l})
assert(folder_info.provider('misplaced.blp') == nil and folder_info.provider('map\\misplaced.blp') == 'misplaced asset retained')
disks[lni_root .. '/map/misplaced.blp'] = nil
-- map/scripts/common.j and scripts/common.j both pack as scripts\common.j.
dirs[lni_root .. '/map/scripts'] = true
disks[lni_root .. '/map/scripts/common.j'] = 'conflicting declarations'
folder_info = runtime.analyze(lni_root)
assert(not folder_info.complete and folder_info.provider('scripts\\common.j') == nil)
rejected(folder_info, 'Ambiguous logical map filename')
disks[lni_root .. '/map/scripts/common.j'] = nil
disks[lni_root .. '/map/scripts/war3map.j'] = 'different nested JASS script'
disks[lni_root .. '/scripts/war3map.j'] = valid_jass
folder_info = runtime.analyze(lni_root, {w2l = w2l})
assert(not folder_info.complete and folder_info.pjass.status == 'Skipped')
assert(folder_info.pjass.diagnostics[1]:find('Conflicting exported script filenames', 1, true))
disks[lni_root .. '/map/scripts/war3map.j'], disks[lni_root .. '/scripts/war3map.j'] = nil, nil
dirs[lni_root .. '/map/scripts'] = nil
unreadable[lni_root .. '/map/unknown.sidecar'] = true
folder_info = runtime.analyze(lni_root)
assert(not folder_info.complete); rejected(folder_info, 'could not be read')
unreadable[lni_root .. '/map/unknown.sidecar'] = nil
disks[lni_root .. '/map/large.bin'] = 'size supplied independently by the file handle'
folder_info = runtime.analyze(lni_root)
assert(not folder_info.complete and folder_info.largest[1].decoded_size == runtime.max_input_bytes + 1)
rejected(folder_info, '256 MiB'); disks[lni_root .. '/map/large.bin'] = nil
local observations = 0
local cancelled_folder, cancellation_error = pcall(runtime.analyze, lni_root,
    {cancelled = function() observations = observations + 1; return observations > 8 end})
assert(not cancelled_folder and cancellation_error:find('Optimization cancelled', 1, true))
disks[lni_root .. '/table/imp.ini'] = 'test-legacy-import-list'
folder_info = runtime.analyze(lni_root)
assert(folder_info.complete and #folder_info.import_issues == 0)
disks[lni_root .. '/table/imp.ini'] = 'test-invalid-import-list'
folder_info = runtime.analyze(lni_root)
assert(#folder_info.import_issues == 1 and folder_info.import_issues[1]:find('Cannot fully analyze LNI imports', 1, true))
disks[lni_root .. '/table/imp.ini'] = 'test-invalid-import-root'
folder_info = runtime.analyze(lni_root)
assert(folder_info.import_issues[1]:find('Cannot fully analyze LNI imports', 1, true))
disks[lni_root .. '/table/imp.ini'] = import_bytes
disks[lni_root .. '/table/w3i.ini'] = 'test-Lua-language'
folder_info = runtime.analyze(lni_root, {w2l = w2l})
assert(folder_info.script_type == 'Lua' and checker_options.script_type == 'Lua' and folder_info.pjass.status == 'Skipped')
dirs[lni_root .. '/w3x2lni/locale'] = true
disks[lni_root .. '/w3x2lni/locale/w3i.lng'] = '[MAP]\r\nproject_map\r\n[SCRIPT_TYPE]\r\nproject_language\r\n[OTHER]\r\nunused'
disks[lni_root .. '/table/w3i.ini'] = 'test-localized-Lua-language'
folder_info = runtime.analyze(lni_root, {w2l = w2l})
assert(folder_info.script_type == 'Lua' and checker_options.script_type == 'Lua')
assert(runtime_deps['share.lang'].w3i.MAP == 'map', 'Project locale changed the global application language')
disks[lni_root .. '/w3x2lni/locale/w3i.lng'], dirs[lni_root .. '/w3x2lni/locale'] = nil, nil
local previous_checks = checked
disks[lni_root .. '/table/w3i.ini'] = 'malformed metadata'
folder_info = runtime.analyze(lni_root, {w2l = w2l})
assert(folder_info.pjass.status == 'Skipped' and checked == previous_checks)
assert(folder_info.pjass.diagnostics[1]:find('Cannot read LNI script-language metadata', 1, true))
disks[lni_root .. '/table/w3i.ini'] = language_bytes
disks[lni_root .. '/.w3x'] = 'unrecognized marker'
assert(not pcall(runtime.analyze, lni_root), 'An unrelated directory was accepted as LNI')
disks[lni_root .. '/.w3x'] = original_lni[lni_root .. '/.w3x']
for path, bytes in pairs(original_lni) do assert(disks[path] == bytes, 'Folder diagnostics changed project files') end
print('PASS read-only LNI physical inventory, logical mapping, duplicates, imports, language, traversal bounds and archive refusal')

local folder_exit, folder_log
function test_fs.is_regular_file(path) return disks[path:string()] ~= nil end
function test_fs.create_directories() end
local folder_messager = {title = function() end, progress = function() end, report = function() end,
    exit = function(kind, content) folder_exit = {kind = kind, content = content} end}
local folder_cli_deps = {
    ['bee.filesystem'] = test_fs, ['backend.w2l_path'] = test_path('/package'),
    ['backend.base_path'] = test_path('/maps'), ['backend.command'] = {},
    ['share.messager'] = folder_messager, ['bee.time'] = {monotonic = function() return 100 end},
    ['backend.unpack_setting'] = function()
        return {input = test_path(lni_root), output = test_path('/maps/refused-folder.w3x')}
    end,
    ['backend.sandbox_core'] = function()
        return {setting = w2l.setting, set_messager = function() end, set_setting = function() end}
    end,
    ['backend.lossless'] = runtime,
}
local folder_cli = assert(loadfile(root .. '/script/backend/lossless_cli.lua', 't', setmetatable({
    io = {save = function(_, bytes) folder_log = bytes; return true end},
    require = function(name) return assert(folder_cli_deps[name], name) end}, {__index = _G})))()
folder_cli('analyze')
assert(folder_exit.kind == 'success' and folder_exit.content == 'Analysis complete')
assert(folder_log:find('LNI project size:', 1, true) and folder_log:find('optimization: analysis only', 1, true))
assert(folder_log:find('archive optimization is unavailable', 1, true) and not folder_log:find(' - 0', 1, true))
folder_cli('optimize')
assert(folder_exit.kind == 'error' and folder_log:find('Optimize requires a packed .w3x or .w3m map file', 1, true))
assert(not disks['/maps/refused-folder.w3x'], 'CLI assembled a folder during archive optimization')
for path, bytes in pairs(original_lni) do assert(disks[path] == bytes, 'CLI diagnostics changed project files') end
print('PASS LNI Analyze CLI reports project sizes and analysis-only scope; Optimize refuses folders')
