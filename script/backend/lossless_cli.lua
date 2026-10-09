local fs = require 'bee.filesystem'
local root = require 'backend.w2l_path'
local messager = require 'share.messager'
local unpack_setting = require 'backend.unpack_setting'
local command = require 'backend.command'
local base = require 'backend.base_path'
local core = require 'backend.sandbox_core'
local lossless = require 'backend.lossless'

local function display(text)
    return tostring(text):gsub('[^\32-\126]', function(c) return ('\\x%02X'):format(c:byte()) end)
end

return function(action)
    local w2l, lines = core(), {}
    w2l:set_messager(messager)
    messager.title(action == 'analyze' and 'Analyze' or 'Optimize')
    messager.progress(0)
    local setting = unpack_setting(w2l, action)
    w2l:set_setting(setting)
    w2l.log_path = root / 'log'
    fs.create_directories(w2l.log_path)
    local previous_report = messager.report
    function messager.report(kind, level, content, tip)
        lines[#lines + 1] = content .. (tip ~= '' and (' - ' .. tip) or '')
        previous_report(kind, level, content, tip)
    end
    local function emit(content, tip)
        messager.report('Lossless archive tools', 8, content, tip or '')
    end
    local time = require 'bee.time'
    local options = {w2l = w2l, progress = messager.progress, now = function() return time.monotonic() / 1000 end}
    local cancellation_requested = false
    local ok, result = xpcall(function()
        if command['cancel-file'] then
            assert(type(command['cancel-file']) == 'string', 'cancel-file requires a marker path')
            local marker = fs.absolute(fs.path(command['cancel-file']), base)
            options.cancelled = function()
                if fs.exists(marker) then cancellation_requested = true end
                return cancellation_requested
            end
        end
        assert(setting.input and fs.is_regular_file(setting.input), 'Choose an existing .w3x or .w3m map file')
        local info
        if action == 'analyze' then
            info = lossless.analyze(setting.input, options)
        else
            assert(setting.output, 'Optimize requires a new output path: w2l.exe optimize input.w3x output.w3x')
            info = lossless.optimize(setting.input, setting.output, options)
        end
        -- A report-only checker can return Unavailable after being cancelled.
        -- Observe its marker again, but retain a completed atomic promotion.
        if (action == 'analyze' or not info.output) and options.cancelled and options.cancelled() then
            error('Optimization cancelled', 0)
        end
        return info
    end, debug.traceback)
    if ok then
        emit(('Map size: %d bytes; inventory: %s; optimization: %s'):format(result.input_size,
            result.complete and 'complete' or 'partial', result.eligible and 'eligible' or 'analysis only'))
        for _, reason in ipairs(result.reasons) do emit('Skipped: ' .. display(reason)) end
        for i, member in ipairs(result.largest) do
            emit(('%d. %s'):format(i, display(member.name)), ('Decoded: %d bytes; stored: %s'):format(
                member.decoded_size, member.stored_size and (member.stored_size .. ' bytes') or 'unknown'))
        end
        for _, duplicate in ipairs(result.duplicates) do
            local names = {}
            for _, name in ipairs(duplicate.names) do names[#names + 1] = display(name) end
            emit('Identical payloads: ' .. table.concat(names, ', '),
                ('%d decoded bytes each; %d potential decoded duplicate bytes (not promised archive savings)'):format(
                    duplicate.decoded_size, duplicate.potential_decoded_bytes))
        end
        for _, issue in ipairs(result.import_issues) do emit(display(issue)) end
        for _, issue in ipairs(result.model_issues or {}) do emit(display(issue)) end
        if action == 'optimize' then
            for _, candidate in ipairs(result.candidates or {}) do
                if candidate.skipped then
                    emit(('Skipped %d-byte sectors'):format(candidate.sector_size), candidate.reason)
                else emit(('Verified %d-byte sectors: %d bytes'):format(candidate.sector_size, candidate.size)) end
            end
            if result.output then
                emit(('Saved %d bytes (%.2f%%)'):format(result.savings, result.savings * 100 / result.input_size),
                    'New map: ' .. result.output:string())
            else emit('No optimized map was created.', 'No eligible, verified candidate was smaller than the input.') end
        end
        emit(('Processing time: %.3f seconds'):format(result.elapsed))
        messager.progress(1)
        messager.exit('success', action == 'analyze' and 'Analysis complete' or 'Optimization complete')
    elseif cancellation_requested and tostring(result):match('^[^\r\n]*'):match('Optimization cancelled$') then
        emit('Operation cancelled', 'Input map unchanged; no optimized map was accepted.')
        messager.exit('warning', 'Cancelled')
    else
        emit('Archive operation failed', display(result))
        messager.exit('error', 'Archive operation failed; the source map was not modified')
    end
    io.save(w2l.log_path / 'report.log', table.concat(lines, '\r\n'))
    messager.report = previous_report
end