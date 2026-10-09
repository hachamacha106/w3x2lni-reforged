-- Actual packaged Windows FFI/codec tests, called by windows_native.lua. The
-- synthetic archive is a storage fixture, not a playable Warcraft map.
return function(folder_name, action)
    local fs = require 'bee.filesystem'
    local storm = require 'ffi.stormlib'
    local lossless = require 'backend.lossless'
    local folder = fs.path(folder_name) / '地图 hráč'
    fs.create_directories(folder)
    local input, output = folder / '来源 hráč.w3x', folder / '优化 output.w3x'
    local function read(path)
        local file = assert(io.open(path:string(), 'rb'))
        local bytes = assert(file:read 'a')
        assert(file:close())
        return bytes
    end
    local function write(path, bytes)
        local file = assert(io.open(path:string(), 'wb'))
        assert(file:write(bytes)); assert(file:close())
    end
    local files = {
        ['war3map.j'] = 'function config takes nothing returns nothing\r\nendfunction\r\nfunction main takes nothing returns nothing\r\nendfunction\r\n',
        ['war3map.imp'] = string.pack('<I4I4Bz', 1, 1, 13, 'textures\\重复.blp'),
        ['textures\\重复.blp'] = ('BLP0\0byte sensitive texture\r\n'):rep(1000),
        ['textures\\same.blp'] = ('BLP0\0byte sensitive texture\r\n'):rep(1000),
        ['opaque.sidecar'] = '\0\255\0\128unknown preserved bytes',
        ['models\\modern.mdx'] = 'MDLXVERS' .. string.pack('<I4I4', 4, 1100) .. 'UNKN' .. string.pack('<I4', 4) .. '????',
        ['war3map.wtg'] = 'WTG! opaque editor bytes',
    }
    if action ~= 'verify-cli' then
        fs.remove(input); fs.remove(output)
        local prefix = 'HM3W\0\0\0\0Synthetic Unicode map\0' .. string.pack('<I4I4', 0xFFFFFFFF, 2)
        prefix = prefix .. string.rep('\0', 512 - #prefix)
        write(input, prefix)
        local writer = assert(storm.create(input, 32, false, {signature_flags = 0}))
        for name, bytes in pairs(files) do assert(writer:save_file(name, bytes, 0)) end
        assert(writer:close())
        local original = read(input)
        local analysis = lossless.analyze(input)
        assert(analysis.eligible and analysis.complete and #analysis.duplicates >= 1)
        local optimized = lossless.optimize(input, output)
        assert(optimized.output and optimized.savings > 0 and #optimized.candidates == 3)
        assert(optimized.candidates[1].sector_size == 512 and optimized.candidates[1].skipped,
            'Unsupported 512-byte layout was not reported')
        assert(optimized.candidates[2].verified and optimized.candidates[3].verified)
        assert(read(output):sub(1, 512) == original:sub(1, 512), 'Unknown outer map flags changed')
        assert(read(input) == original, 'Analyze/Optimize modified the input')
        assert(not pcall(lossless.optimize, input, output), 'Existing output was overwritten')
        local raced = folder / 'raced.w3x'; fs.remove(raced)
        assert(not pcall(lossless.optimize, input, raced, {promote = function(from, to)
            write(to, 'another program owns this output')
            return storm.promote(from, to)
        end}))
        assert(read(raced) == 'another program owns this output', 'Output race replaced another file')
        local events, cancelled = 0, folder / 'cancelled.w3x'; fs.remove(cancelled)
        assert(not pcall(lossless.optimize, input, cancelled, {
            cancelled = function() return events > 0 end,
            progress = function() events = events + 1 end}))
        assert(not fs.exists(cancelled), 'Cancelled optimization produced output')
        local compressed_sectors = 0
        local mid_cancelled = folder / 'mid-member-cancelled.w3x'; fs.remove(mid_cancelled)
        local boundary = {open = storm.open, supports_sector_size = storm.supports_sector_size, promote = storm.promote,
            compress = function(bytes)
                if #bytes == 4096 then compressed_sectors = compressed_sectors + 1 end
                return storm.compress(bytes)
            end}
        assert(not pcall(lossless.optimize, input, mid_cancelled, {storm = boundary,
            cancelled = function() return compressed_sectors >= 2 end}))
        assert(compressed_sectors == 2 and not fs.exists(mid_cancelled), 'Mid-member cancellation did not stop encoding')

        for entry in fs.pairs(folder) do
            assert(not entry:filename():string():find('.w2l-optimize', 1, true), 'Partial candidate cleanup failed')
        end
        print(('LOSSLESS_NATIVE saved=%d size=%d sector=%d'):format(optimized.savings, optimized.output_size, optimized.sector_size))
        print('PASS native archive codec/readback, Unicode paths, exact map header, unknown/editor/HD data, race and cancellation')
    else output = folder / 'CLI 优化.w3x' end
    local before, after = assert(storm.open(input, true)), assert(storm.open(output, true))
    for name, bytes in pairs(files) do
        assert(before:load_file(name) == bytes and after:load_file(name) == bytes, 'Payload changed: ' .. name)
    end
    for _, name in ipairs {'(listfile)', '(attributes)'} do
        assert(before:load_file(name) == after:load_file(name), 'Bookkeeping bytes changed: ' .. name)
    end
    assert(before:close()); assert(after:close())
    return {input = input:string(), output = output:string()}
end