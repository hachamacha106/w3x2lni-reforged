-- Bounded MPQ v1 inspection and sector-layout encoding. MPQ table cryptography
-- follows StormLib's documented format; optimization and reopen-verification
-- ideas are credited to devoltzz / Devo's Map Doctor (MIT), reviewed at
-- 6ea6991f5c15907a284c38dce8e8fd929082dfe8. See docs/licenses/map-doctor-MIT.txt.
-- This module never decodes archive content or mutates the input archive.
local M = {}
local MASK = 0xFFFFFFFF
local EXISTS, COMPRESS, SINGLE = 0x80000000, 0x200, 0x01000000
local crypt = {}
local seed = 0x100001
for i = 0, 255 do
    for j = 0, 4 do
        seed = (seed * 125 + 3) % 0x2AAAAB
        local high = (seed & 0xFFFF) << 16
        seed = (seed * 125 + 3) % 0x2AAAAB
        crypt[j * 256 + i] = high | (seed & 0xFFFF)
    end
end

-- StormLib9.40 creates/opens MPQ v1 with HashStringSlash, which preserves
-- forward slashes. HashString (a different exported internal routine) folds
-- slashes; using it here would incorrectly reconcile distinct hash identities.
function M.hash(name, kind)
    local a, b = 0x7FED7FED, 0xEEEEEEEE
    for i = 1, #name do
        local ch = name:byte(i)
        if ch >= 97 and ch <= 122 then ch = ch - 32 end
        a = (crypt[kind * 256 + ch] ~ ((a + b) & MASK)) & MASK
        b = (ch + a + b + (b << 5) + 3) & MASK
    end
    return a
end

function M.table_crypt(bytes, key, encrypt, cancelled)
    assert(#bytes % 4 == 0, 'Truncated MPQ table')
    local result, state = {}, 0xEEEEEEEE
    for pos = 1, #bytes, 4 do
        if (pos - 1) & 65535 == 0 and cancelled and cancelled() then error('Optimization cancelled') end
        state = (state + crypt[0x400 + (key & 0xFF)]) & MASK
        local value = string.unpack('<I4', bytes, pos)
        local converted = (value ~ ((key + state) & MASK)) & MASK
        result[#result + 1] = string.pack('<I4', converted)
        key = ((((~key << 21) + 0x11111111) | (key >> 11))) & MASK
        local plain = encrypt and value or converted
        state = (plain + state + (state << 5) + 3) & MASK
    end
    return table.concat(result)
end

local function reason(info, text)
    if not info.reason_set[text] then
        info.reason_set[text] = true
        info.reasons[#info.reasons + 1] = text
    end
    info.eligible = false
end
M.reason = reason

local function slice(bytes, offset, size)
    assert(offset >= 0 and size >= 0 and offset + size <= #bytes, 'MPQ range exceeds input length')
    return bytes:sub(offset + 1, offset + size)
end

local function inspect(bytes, info, cancelled)
    local offset
    if bytes:sub(1, 4) == 'MPQ\26' then offset = 0
    elseif bytes:sub(513, 516) == 'MPQ\26' then offset = 512
    else
        for pos = 512, math.min(#bytes - 32, 2097152), 512 do
            if bytes:sub(pos + 1, pos + 4) == 'MPQ\26' then offset = pos; break end
        end
    end
    assert(offset, 'No supported aligned MPQ header found')
    info.offset, info.prefix = offset, bytes:sub(1, offset)
    if offset ~= 0 then
        local ending = bytes:find('\0', 9, true)
        if offset ~= 512 or bytes:sub(1, 8) ~= 'HM3W\0\0\0\0'
            or not ending or ending + 8 > 512 or bytes:sub(ending + 9, 512):find('[^\0]') then
            reason(info, 'Nonstandard or unexplained bytes before the MPQ header')
        end
    end
    local header_size, archive_size, version, shift, hash_pos, block_pos, hash_count, block_count =
        string.unpack('<I4I4I2I2I4I4I4I4', slice(bytes, offset + 4, 28))
    info.archive_size, info.version, info.sector_size = archive_size, version, 512 << math.min(shift, 16)
    if version ~= 0 or header_size ~= 32 then
        reason(info, 'Only MPQ v1 with an exact 32-byte header is eligible')
        return
    end
    assert(shift <= 7, 'Unsupported or invalid MPQ sector shift')
    assert(archive_size >= 32 and offset + archive_size <= #bytes, 'Invalid MPQ archive length')
    if offset + archive_size ~= #bytes then reason(info, 'Trailing data or an archive signature is present') end
    assert(hash_count <= 65536, 'MPQ hash table exceeds the 65536-record safety limit')
    assert(hash_count > 0 and hash_count & (hash_count - 1) == 0, 'Invalid MPQ hash table count')
    assert(block_count <= hash_count, 'Invalid MPQ block table count')
    local hash_bytes = slice(bytes, offset + hash_pos, hash_count * 16)
    local hashes = M.table_crypt(hash_bytes, M.hash('(hash table)', 3), false, cancelled)
    local blocks = M.table_crypt(slice(bytes, offset + block_pos, block_count * 16), M.hash('(block table)', 3), false, cancelled)
    info.hash_bytes, info.hashes, info.blocks = hash_bytes, {}, {}
    info.hash_count, info.block_count = hash_count, block_count
    local references, ranges = {}, {{0, 32}, {hash_pos, hash_pos + #hash_bytes}, {block_pos, block_pos + #blocks}}
    for index = 0, hash_count - 1 do
        local a, b, locale, platform, reserved, block = string.unpack('<I4I4I2BBI4', hashes, index * 16 + 1)
        local entry = {a = a, b = b, locale = locale, platform = platform, reserved = reserved, block = block, index = index}
        info.hashes[index + 1] = entry
        if block < 0xFFFFFFFE then
            assert(block < block_count, 'Hash entry references a missing block')
            -- StormLib initializes the unused byte to 0xFF; both normal
            -- sentinel values remain byte-for-byte in the retained hash table.
            if locale ~= 0 or platform ~= 0 or (reserved ~= 0 and reserved ~= 0xFF) then
                reason(info, 'Additional locales or platform metadata are present')
            end
            references[block] = (references[block] or 0) + 1
            if references[block] > 1 then reason(info, 'Multiple hash entries alias the same block') end
        end
    end
    local allowed = EXISTS | COMPRESS | SINGLE
    for index = 0, block_count - 1 do
        local pos, stored, decoded, flags = string.unpack('<I4I4I4I4', blocks, index * 16 + 1)
        local block = {index = index, offset = pos, stored_size = stored, decoded_size = decoded, flags = flags}
        info.blocks[index + 1] = block
        if not references[index] or flags & EXISTS == 0 then reason(info, 'Orphan or deleted block-table records are present') end
        if flags & 0x30000 ~= 0 then reason(info, 'Encrypted files or fixed encryption keys are present') end
        if flags & ~allowed ~= 0 then
            reason(info, 'Unsupported file flags, sector checksums, patch data, or compression are present')
        end
        assert(pos >= 32 and pos + stored <= archive_size, 'File block exceeds the MPQ boundary')
        if stored > 0 then ranges[#ranges + 1] = {pos, pos + stored} end
    end
    table.sort(ranges, function(a, b) return a[1] < b[1] end)
    local finish = 0
    for _, range in ipairs(ranges) do
        assert(range[1] >= finish and range[2] <= archive_size, 'Overlapping MPQ file/table ranges')
        if slice(bytes, offset + finish, range[1] - finish):find('[^\0]') then
            reason(info, 'Unexplained nonzero bytes between MPQ structures')
        end
        finish = range[2]
    end
    if slice(bytes, offset + finish, archive_size - finish):find('[^\0]') then
        reason(info, 'Unexplained nonzero bytes after MPQ structures')
    end
end

function M.inspect(bytes, cancelled)
    local info = {eligible = true, reasons = {}, reason_set = {}, files = {}, bytes = bytes}
    local ok, err = pcall(inspect, bytes, info, cancelled)
    if not ok then reason(info, 'Malformed archive: ' .. tostring(err):gsub('^.-:%d+: ', '')) end
    return info
end

local function normalized(name)
    return name:gsub('[a-z]', string.upper)
end
M.normalized = normalized

function M.inventory(info, names, provider, cancelled)
    info.complete = false
    if not info.hashes then return end
    local declared, matched, matched_hashes = {}, {}, {}
    local hash_metadata_complete = #info.hashes == info.hash_count
    local block_metadata_complete = info.blocks ~= nil and #info.blocks == info.block_count
    local metadata_complete = hash_metadata_complete and block_metadata_complete
    if not hash_metadata_complete then
        reason(info, 'The file inventory is incomplete: MPQ hash-table metadata is unavailable')
    end
    if not block_metadata_complete then
        reason(info, 'The file inventory is incomplete: MPQ block-table metadata is unavailable')
    end
    for _, name in ipairs(names) do
        if cancelled and cancelled() then error('Optimization cancelled') end
        if #name == 0 or #name > 4096 or name:find('[\0\r\n]') or name:match('^[Ff][Ii][Ll][Ee]%d%d%d%d%d%d%d%d%.') then
            reason(info, 'Unresolved or invalid listfile names are present')
        else
            local norm = normalized(name)
            if not declared[norm] then
                declared[norm] = true
                local a, b = M.hash(name, 1), M.hash(name, 2)
                local hash, collisions
                -- Follow the actual linear probe chain; an unreachable hash match
                -- cannot be used as proof that a name identifies a live file.
                local start = M.hash(name, 0) & (info.hash_count - 1)
                for i = 0, info.hash_count - 1 do
                    local candidate = info.hashes[((start + i) & (info.hash_count - 1)) + 1]
                    if not candidate then
                        metadata_complete = false
                        -- Inspection can stop partway through a malformed table.
                        -- Missing records are never evidence of a live member.
                        reason(info, 'The file inventory is incomplete: MPQ hash-table metadata is unavailable')
                        break
                    end
                    if candidate.block == MASK then break end
                    if candidate.block < 0xFFFFFFFE and candidate.a == a and candidate.b == b then
                        if hash then collisions = true end
                        hash = candidate
                    end
                end
                if hash then
                    if collisions or matched[hash.block] then reason(info, 'Ambiguous filename hashes or aliases are present') end
                    local block = info.blocks and info.blocks[hash.block + 1]
                    if not block then
                        metadata_complete = false
                        reason(info, 'The file inventory is incomplete: MPQ block-table metadata is unavailable')
                    else
                        local payload = provider(name)
                        if type(payload) ~= 'string' or #payload ~= block.decoded_size then
                            reason(info, 'Cannot read the complete member: ' .. name)
                        else
                            local member = {name = name, bytes = payload, block = block, stored_size = block.stored_size,
                                decoded_size = block.decoded_size, locale = hash.locale}
                            info.files[#info.files + 1] = member
                            matched[hash.block] = member
                            if not collisions then matched_hashes[hash.index] = true end
                            if norm == '(SIGNATURE)' then reason(info, 'An archive signature is present') end
                        end
                    end
                elseif norm ~= '(ATTRIBUTES)' and norm ~= '(SIGNATURE)' then
                    reason(info, 'Listfile references a missing archive member: ' .. name)
                end
            end
        end
    end
    local complete = metadata_complete
    for _, hash in ipairs(info.hashes) do
        if hash.block < 0xFFFFFFFE and not matched_hashes[hash.index] then
            complete = false
            reason(info, 'The file inventory is incomplete')
        end
    end
    for index = 0, info.block_count - 1 do if not matched[index] then complete = false end end
    info.by_block = matched
    for _, member in ipairs(info.files) do
        if normalized(member.name) == '(ATTRIBUTES)' then
            local payload = member.bytes
            if #payload < 8 then reason(info, 'Truncated attributes metadata')
            else
                local version, flags = string.unpack('<I4I4', payload)
                local unit = (flags & 1 ~= 0 and 4 or 0) + (flags & 2 ~= 0 and 8 or 0) + (flags & 4 ~= 0 and 16 or 0)
                if version ~= 100 or flags & ~7 ~= 0 or #payload ~= 8 + info.block_count * unit then
                    reason(info, 'Unsupported attributes version, flags, or record length')
                end
            end
        end
    end
    info.complete = complete and #info.files == info.block_count
end

-- Validate the exact zlib/DEFLATE framing, including end-of-stream consumption.
-- StormLib accepts some streams with ignored suffixes; those suffix bytes must
-- not disappear during a claimed lossless rewrite. Every literal and back
-- reference is checked against decoded bytes, beyond length/Adler checks.
local function zlib_exact(encoded, decoded, cancelled)
    assert(#encoded >= 6, 'Truncated zlib stream')
    local cmf, flg = encoded:byte(1, 2)
    assert(cmf & 15 == 8 and cmf >> 4 <= 7 and (cmf * 256 + flg) % 31 == 0 and flg & 32 == 0,
        'Unsupported zlib header')
    local bitpos, produced, next_poll = 16, 0, 65536
    local function checkpoint()
        if produced >= next_poll then
            next_poll = produced + 65536
            if cancelled and cancelled() then error('Optimization cancelled') end
        end
    end
    local function bits(count)
        assert(bitpos + count <= (#encoded - 4) * 8, 'Truncated DEFLATE stream')
        local value = 0
        for i = 0, count - 1 do
            value = value | (((encoded:byte((bitpos >> 3) + 1) >> (bitpos & 7)) & 1) << i)
            bitpos = bitpos + 1
        end
        return value
    end
    local function tree(lengths)
        local counts, nextcode, lookup = {}, {}, {}
        for _, length in ipairs(lengths) do
            assert(length >= 0 and length <= 15, 'Invalid Huffman code length')
            counts[length] = (counts[length] or 0) + 1
        end
        counts[0] = 0
        local code = 0
        for length = 1, 15 do
            code = (code + (counts[length - 1] or 0)) << 1
            assert(code + (counts[length] or 0) <= 1 << length, 'Oversubscribed Huffman tree')
            nextcode[length], lookup[length] = code, {}
        end
        for symbol, length in ipairs(lengths) do
            if length > 0 then
                lookup[length][nextcode[length]] = symbol - 1
                nextcode[length] = nextcode[length] + 1
            end
        end
        return lookup
    end
    local function symbol(lookup)
        local code = 0
        for length = 1, 15 do
            code = (code << 1) | bits(1)
            if lookup[length][code] ~= nil then return lookup[length][code] end
        end
        error('Invalid Huffman symbol')
    end
    local length_base = {3,4,5,6,7,8,9,10,11,13,15,17,19,23,27,31,35,43,51,59,67,83,99,115,131,163,195,227,258}
    local length_extra = {0,0,0,0,0,0,0,0,1,1,1,1,2,2,2,2,3,3,3,3,4,4,4,4,5,5,5,5,0}
    local distance_base = {1,2,3,4,5,7,9,13,17,25,33,49,65,97,129,193,257,385,513,769,1025,1537,2049,3073,4097,6145,8193,12289,16385,24577}
    local distance_extra = {0,0,0,0,1,1,2,2,3,3,4,4,5,5,6,6,7,7,8,8,9,9,10,10,11,11,12,12,13,13}
    local final
    repeat
        final = bits(1)
        local kind = bits(2)
        if kind == 0 then
            local padding = (-bitpos) & 7
            assert(bits(padding) == 0, 'Unexplained DEFLATE padding bits')
            local len, inverse = bits(16), bits(16)
            assert((len ~ inverse) == 0xFFFF, 'Invalid uncompressed DEFLATE block')
            assert(bitpos + len * 8 <= (#encoded - 4) * 8, 'Truncated uncompressed DEFLATE data')
            local first = (bitpos >> 3) + 1
            assert(encoded:sub(first, first + len - 1) == decoded:sub(produced + 1, produced + len),
                'Uncompressed DEFLATE bytes differ from decoded member')
            bitpos, produced = bitpos + len * 8, produced + len
        elseif kind == 1 or kind == 2 then
            local literal, distance = {}, {}
            if kind == 1 then
                for i = 0, 287 do literal[i + 1] = i <= 143 and 8 or (i <= 255 and 9 or (i <= 279 and 7 or 8)) end
                for i = 1, 32 do distance[i] = 5 end
            else
                local nlit, ndist, ncode = bits(5) + 257, bits(5) + 1, bits(4) + 4
                assert(nlit <= 286, 'Reserved DEFLATE literal codes')
                local order, lengths = {16,17,18,0,8,7,9,6,10,5,11,4,12,3,13,2,14,1,15}, {}
                for i = 1, 19 do lengths[i] = 0 end
                for i = 1, ncode do lengths[order[i] + 1] = bits(3) end
                local codes, all = tree(lengths), {}
                while #all < nlit + ndist do
                    local value = symbol(codes)
                    if value <= 15 then all[#all + 1] = value
                    else
                        local repeat_count, repeated
                        if value == 16 then
                            assert(#all > 0, 'Huffman repeat without previous length')
                            repeat_count, repeated = bits(2) + 3, all[#all]
                        elseif value == 17 then repeat_count, repeated = bits(3) + 3, 0
                        else repeat_count, repeated = bits(7) + 11, 0 end
                        assert(#all + repeat_count <= nlit + ndist, 'Huffman repeat exceeds table')
                        for _ = 1, repeat_count do all[#all + 1] = repeated end
                    end
                end
                for i = 1, nlit do literal[i] = all[i] end
                for i = 1, ndist do distance[i] = all[nlit + i] end
                assert(literal[257] > 0, 'Missing DEFLATE end marker')
            end
            local literals, distances = tree(literal), tree(distance)
            while true do
                local value = symbol(literals)
                if value < 256 then
                    assert(decoded:byte(produced + 1) == value, 'DEFLATE literal differs from decoded member')
                    produced = produced + 1
                elseif value == 256 then break
                else
                    local index = value - 256
                    assert(length_base[index], 'Reserved DEFLATE length')
                    local length = length_base[index] + bits(length_extra[index])
                    local d = symbol(distances) + 1
                    assert(distance_base[d], 'Reserved DEFLATE distance')
                    local back = distance_base[d] + bits(distance_extra[d])
                    assert(back <= produced and back <= 1 << ((cmf >> 4) + 8), 'Invalid DEFLATE back reference')
                    local pattern = decoded:sub(produced - back + 1, produced - back + math.min(back, length))
                    local expected = pattern:rep((length + #pattern - 1) // #pattern):sub(1, length)
                    assert(decoded:sub(produced + 1, produced + length) == expected,
                        'DEFLATE back reference differs from decoded member')
                    produced = produced + length
                end
                checkpoint()
                assert(produced <= #decoded, 'DEFLATE exceeds the decoded member')
            end
        else error('Reserved DEFLATE block type') end
        checkpoint()
        assert(produced <= #decoded, 'DEFLATE exceeds the decoded member')
    until final == 1
    local padding = (-bitpos) & 7
    assert(bits(padding) == 0 and bitpos == (#encoded - 4) * 8, 'Unexplained bytes after the DEFLATE stream')
    assert(produced == #decoded, 'DEFLATE decoded length mismatch')
    local a, b = 1, 0
    for i = 1, #decoded do
        if i & 65535 == 0 and cancelled and cancelled() then error('Optimization cancelled') end
        a = (a + decoded:byte(i)) % 65521; b = (b + a) % 65521
    end
    assert(string.unpack('>I4', encoded, #encoded - 3) == (b << 16) | a, 'Zlib checksum mismatch')
    return true
end
M.zlib_exact = zlib_exact

local function validate_member(info, member, cancelled)
    local block = member.block
    local encoded = slice(info.bytes, info.offset + block.offset, block.stored_size)
    if block.flags & COMPRESS == 0 then
        assert(encoded == member.bytes, 'Uncompressed member has unexplained bytes')
        return
    end
    if #member.bytes == 0 then assert(#encoded == 0, 'Empty member has unexplained bytes'); return end
    local sectors, offsets = {}, {}
    if block.flags & SINGLE ~= 0 then
        sectors[1] = {encoded, member.bytes}
    else
        local count = (#member.bytes + info.sector_size - 1) // info.sector_size
        local table_size = (count + 1) * 4
        assert(#encoded >= table_size, 'Truncated sector-offset table')
        for i = 1, count + 1 do offsets[i] = string.unpack('<I4', encoded, (i - 1) * 4 + 1) end
        assert(offsets[1] == table_size and offsets[count + 1] == #encoded, 'Unexplained bytes around MPQ sectors')
        for i = 1, count do
            assert(offsets[i + 1] >= offsets[i], 'Invalid sector offset order')
            sectors[i] = {slice(encoded, offsets[i], offsets[i + 1] - offsets[i]),
                member.bytes:sub((i - 1) * info.sector_size + 1, i * info.sector_size)}
        end
    end
    for _, sector in ipairs(sectors) do
        if cancelled and cancelled() then error('Optimization cancelled') end
        local stored, decoded = sector[1], sector[2]
        if #stored == #decoded then assert(stored == decoded, 'Raw sector bytes differ from decoded member')
        else
            assert(#stored < #decoded and stored:byte(1) == 2, 'Only raw or zlib-compressed sectors are eligible')
            zlib_exact(stored:sub(2), decoded, cancelled)
        end
    end
end

function M.validate_payloads(info, cancelled)
    if not info.eligible then return end
    for _, member in ipairs(info.files) do
        local ok, err = pcall(validate_member, info, member, cancelled)
        if not ok then reason(info, 'Unsupported member framing: ' .. member.name .. ': ' .. tostring(err):gsub('^.-:%d+: ', '')) end
    end
end

function M.encode(info, sector_size, compress, cancelled, progress)
    assert(info.eligible and info.complete, 'Cannot encode an unverified inventory')
    assert(sector_size == 512 or sector_size == 4096 or sector_size == 65536, 'Unsupported candidate sector size')
    local chunks, blocks, position = {}, {}, 32
    for index = 0, info.block_count - 1 do
        if cancelled and cancelled() then error('Optimization cancelled') end
        local member = assert(info.by_block[index])
        local payload, flags = member.bytes, EXISTS
        if #payload > 0 then
            local sectors, offsets, size = {}, {}, (((#payload + sector_size - 1) // sector_size) + 1) * 4
            for first = 1, #payload, sector_size do
                if cancelled and cancelled() then error('Optimization cancelled') end
                offsets[#offsets + 1] = string.pack('<I4', size)
                local encoded, err = compress(payload:sub(first, first + sector_size - 1))
                assert(encoded, err or 'Sector compression failed')
                assert(#encoded <= math.min(sector_size, #payload - first + 1), 'Unexpected sector compression growth')
                sectors[#sectors + 1] = encoded
                size = size + #encoded
            end
            offsets[#offsets + 1] = string.pack('<I4', size)
            local compressed = table.concat(offsets) .. table.concat(sectors)
            if #compressed < #payload then payload, flags = compressed, EXISTS | COMPRESS end
        end
        chunks[#chunks + 1] = payload
        blocks[#blocks + 1] = string.pack('<I4I4I4I4', position, #payload, #member.bytes, flags)
        position = position + #payload
        if progress then progress((index + 1) / info.block_count) end
    end
    local hash_pos, block_pos = position, position + #info.hash_bytes
    local block_bytes = M.table_crypt(table.concat(blocks), M.hash('(block table)', 3), true)
    local shift, n = 0, sector_size
    while n > 512 do shift, n = shift + 1, n // 2 end
    local archive_size = block_pos + #block_bytes
    assert(archive_size < 0x100000000, 'Candidate exceeds the MPQ v1 size limit')
    local header = 'MPQ\26' .. string.pack('<I4I4I2I2I4I4I4I4', 32, archive_size, 0, shift,
        hash_pos, block_pos, info.hash_count, info.block_count)
    return info.prefix .. header .. table.concat(chunks) .. info.hash_bytes .. block_bytes
end

return M