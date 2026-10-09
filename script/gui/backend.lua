local process = require 'bee.subprocess'
local proto = require 'share.protocol'
local lang = require 'share.lang'
local fs = require 'bee.filesystem'
local time = require 'bee.time'
local worker_sequence = 0
local capture_chunk = 64 * 1024
local drain_chunks = 16

local function cleanup_capture(folder, marker, out_path, err_path)
    local errors = {}
    for _, filename in ipairs {marker or false, out_path or false, err_path or false, folder or false} do
        if filename then
            local checked, exists = pcall(fs.exists, filename)
            if not checked then errors[#errors + 1] = tostring(exists)
            elseif exists then
                local removed, result, err = pcall(fs.remove, filename)
                if not removed or not result then
                    errors[#errors + 1] = 'Could not remove owned worker output ' .. filename:string()
                        .. ': ' .. tostring(removed and err or result)
                end
            end
        end
    end
    -- Remove only known files and then the owned, empty directory; never recurse.
    return table.concat(errors, '\n')
end

local function worker_folder()
    local base = fs.absolute(fs.temp_directory_path() / 'w2l-worker-parent'):parent_path()
    for _ = 1, 100 do
        worker_sequence = worker_sequence + 1
        local folder = base / ('w2l-worker-%d-%d-%d'):format(process.get_id(), os.time(), worker_sequence)
        if fs.create_directory(folder) then return folder end
    end
    error('Cannot create a worker output directory')
end

local function close_file(file)
    if not file then return end
    local ok, closed, err = pcall(file.close, file)
    if not ok then return closed end
    if not closed then return err or 'Could not close worker output file' end
end

local function diagnostics(...)
    local notes = {}
    for i = 1, select('#', ...) do
        local note = select(i, ...)
        if note and note ~= '' then notes[#notes + 1] = tostring(note) end
    end
    return table.concat(notes, '\n')
end

local backend = {}
backend.message = ''
backend.title = ''
backend.progress = nil
backend.report = {}

local mt = {}
mt.__index = mt

-- New archive actions cancel cooperatively so the worker can clean candidates.
function mt:cancel()
    if self.exited or not self.cancel_file then return false, 'This worker cannot be cancelled' end
    if self.cancel_requested then return true end
    local file, err = io.open(self.cancel_file:string(), 'wb')
    if not file then return false, err end
    local written, write_error = file:write('cancel')
    local closed, close_error = file:close()
    if not written or not closed then return false, write_error or close_error end
    self.cancel_requested = true
    return true
end

function mt:unpack_out(bytes)
    while true do
        if self.protocol_failed then return end
        local ok, res = pcall(proto.recv, self.proto_s, bytes)
        if not ok then
            self.protocol_failed = true
            self.error = self.error .. '\nGUI worker protocol error: ' .. tostring(res)
            return
        end
        if not res then
            break
        end
        bytes = ''
        self.output[#self.output+1] = res
    end
end

local function read_capture(worker, name)
    local filename = worker[name .. '_path']
    if not filename then return end
    -- The retained pipe wrapper can hide fread's buffered bytes from peek.
    -- Independent, freshly opened readers never move the child writer cursor.
    local file, err = io.open(filename:string(), 'rb')
    if not file then error(err or 'Could not read worker output', 0) end
    local offset = worker[name .. '_offset']
    local ok, bytes = pcall(function()
        local length = assert(file:seek('end'))
        assert(length >= offset, 'Worker output was unexpectedly truncated')
        local count = math.min(length - offset, capture_chunk)
        if count == 0 then return end
        assert(file:seek('set', offset))
        local content = assert(file:read(count))
        assert(#content == count, 'Could not read complete worker output')
        return content
    end)
    local close_error = close_file(file)
    if not ok then error(bytes, 0) end
    if close_error then error(close_error, 0) end
    if bytes then worker[name .. '_offset'] = offset + #bytes end
    return bytes
end

function mt:update_out()
    local bytes = read_capture(self, 'out')
    if bytes then self:unpack_out(bytes); return true end
end

function mt:update_err()
    local bytes = read_capture(self, 'err')
    if bytes then self.error = self.error .. bytes; return true end
end

local function drain_capture(worker, update, limit)
    for _ = 1, limit do
        if not update(worker) then return true end
    end
    return false
end

function mt:cleanup_capture()
    local err = cleanup_capture(self.spool_folder, self.cancel_file, self.out_path, self.err_path)
    if err ~= '' then self.error = self.error .. (#self.error > 0 and '\n' or '') .. err end
    self.out_path, self.err_path = nil, nil
end

function mt:update_pipe()
    self:update_out()
    self:update_err()
    if not self.process:is_running() then
        -- Bound work per tick, then finish draining on a subsequent tick.
        local out_done = drain_capture(self, self.update_out, drain_chunks)
        local err_done = drain_capture(self, self.update_err, drain_chunks)
        if not out_done or not err_done then return false end
        self:unpack_out()
        if not self.protocol_failed and (self.proto_s.length ~= nil
            or self.proto_s.bytes and self.proto_s.bytes ~= '') then
            self.protocol_failed = true
            self.error = self.error .. '\nGUI worker ended with an incomplete protocol frame.'
        end
        self.exit_code = self.process:wait()
        if self.process.close then pcall(self.process.close, self.process) end
        self:cleanup_capture()
        return true
    end
    return false
end

local function push_report(type, level, value, tip)
    local name = level .. type
    if not backend.report[name] then
        backend.report[name] = {}
    end
    table.insert(backend.report[name], {value, tip})
end

function mt:update_message()
    while true do
        local msg = table.remove(self.output, 1)
        if not msg then
            break
        end
        local key, value = msg.type, msg.args
        if key == 'progress' then
            backend.progress = value * 100
        elseif key == 'report' then
            push_report(value.type, value.level, value.content, value.tip)
        elseif key == 'title' then
            backend.title = value
        elseif key == 'text' then
            backend.message = value
        elseif key == 'exit' then
            backend.lastword = value
        end
    end
end

function mt:update()
    if self.exited then
        return
    end
    if not self.closed then
        self.closed = self:update_pipe()
    end
    if #self.output > 0 then
        self:update_message()
    end
    if #self.error > 0 then
        -- Keep draining stdout: diagnostics must not discard the final report.
        backend.message = lang.ui.FAILED
    end
    if self.closed then
        while #self.output > 0 do
            self:update_message()
        end
        self.exited = true
        if #self.error > 0 or self.exit_code ~= 0 or not backend.lastword then
            backend:failure(#self.error > 0 and self.error
                or ('Worker ended without a complete result (exit code %s).'):format(tostring(self.exit_code)))
        end
        return true
    end
    return false
end

local function recovery_note(worker, details)
    details = tostring(details)
    worker.recovery_notes = worker.recovery_notes or {}
    if not worker.recovery_notes[details] then
        worker.recovery_notes[details] = true
        worker.error = worker.error .. (#worker.error > 0 and '\n' or '') .. details
    end
    backend:failure(worker.error)
end

function mt:recover(details)
    if self.recovering then return end
    self.recovery_started = time.monotonic()
    self.recovering = true
    self.protocol_failed = true
    self.output = {} -- Late success frames cannot replace the visible failure.
    recovery_note(self, details)
    if self.cancel_file then
        local ok, requested, err = pcall(self.cancel, self)
        if not ok or not requested then
            recovery_note(self, 'Could not request cooperative cancellation: ' .. tostring(ok and err or requested))
        end
    end
end

local function drain_failed_captures(worker, limit)
    local complete = true
    -- A failed capture must not prevent polling the other capture or child.
    for _, update in ipairs {worker.update_out, worker.update_err} do
        local done = false
        for _ = 1, limit do
            local ok, read = pcall(update, worker)
            if not ok then recovery_note(worker, read); done = true; break end
            if not read then done = true; break end
        end
        if not done then complete = false end
    end
    return complete
end

function mt:drain_failure()
    if self.exited then return true end
    drain_failed_captures(self, 1)
    local polled, running = pcall(self.process.is_running, self.process)
    if not polled then recovery_note(self, running) end
    local stopped = polled and not running
    if not stopped and time.monotonic() - self.recovery_started >= 30000 then
        if not self.forced_termination then
            self.forced_termination = true
            recovery_note(self, 'The worker did not finish during cancellation recovery. '
                .. 'Forced termination was requested; temporary candidate cleanup could not be verified.')
        end
        local killed, result = pcall(self.process.kill, self.process)
        if killed and result then stopped = true
        else
            recovery_note(self, 'The owned worker could not be terminated: ' .. tostring(result))
            -- Do not release a still-running worker or permit concurrent retry.
            return false
        end
    end
    if not stopped then backend:failure(self.error); return false end
    -- Collect diagnostics written between the first drain and confirmed exit.
    if not drain_failed_captures(self, drain_chunks) then return false end
    local waited, code = pcall(self.process.wait, self.process)
    if waited then self.exit_code = code
    else recovery_note(self, code); self.exit_code = 1 end
    if self.process.close then pcall(self.process.close, self.process) end
    self:cleanup_capture()
    self.closed, self.exited = true, true
    backend:failure(self.error)
    return true
end

function backend:init(application, currentdir)
    self.application = application
    self.currentdir = currentdir
end

function backend:clean()
    self.message = ''
    self.progress = nil
    self.report = {}
    self.lastword = nil
    self.report_text = nil
end

function backend:failure(details)
    self.message = lang.ui.FAILED
    self.progress = self.progress or 0
    self.lastword = {type = 'error', content = lang.ui.FAILED}
    -- The upstream Lua host inserts NUL separators in stderr. Keep all
    -- diagnostics visible in the native text control instead of truncating.
    local text = tostring(details):gsub('%z', '\r\n')
    local lines, keys = {lang.ui.FAILED, text}, {}
    for key in pairs(self.report) do keys[#keys + 1] = key end
    table.sort(keys)
    for _, key in ipairs(keys) do
        for _, entry in ipairs(self.report[key]) do
            lines[#lines + 1] = tostring(entry[1]) .. (entry[2] and (' - ' .. tostring(entry[2])) or '')
        end
    end
    -- Startup/native worker errors may never reach report.log. Keep this result
    -- in memory so Report and Copy all still show the current diagnostics.
    self.report_text = table.concat(lines, '\r\n')
end

function backend:open(entry, commandline)
    local ok, folder = pcall(worker_folder)
    if not ok then return nil, folder end
    local out_path, err_path = folder / 'stdout', folder / 'stderr'
    local marker
    if commandline[1] == 'analyze' or commandline[1] == 'optimize' then
        marker = folder / 'cancel'
        local forwarded = {}
        for i, value in ipairs(commandline) do forwarded[i] = value end
        forwarded[#forwarded + 1] = '-cancel-file=' .. marker:string()
        commandline = forwarded
    end
    local opened, stdout, err = pcall(io.open, out_path:string(), 'wb')
    if not opened then err, stdout = stdout, nil end
    local stderr
    if stdout then
        opened, stderr, err = pcall(io.open, err_path:string(), 'wb')
        if not opened then err, stderr = stderr, nil end
    end
    if not stdout or not stderr then
        local out_close, err_close = close_file(stdout), close_file(stderr)
        local cleanup_error = cleanup_capture(folder, marker, out_path, err_path)
        return nil, diagnostics(err or 'Could not create worker output files', out_close, err_close, cleanup_error)
    end
    local p
    ok, p, err = pcall(process.spawn, {
        self.application:string(),
        '-E',
        '-e', ('package.cpath=[[%s]]'):format(package.cpath),
        entry,
        commandline,
        console = 'disable',
        stdout = stdout,
        stderr = stderr,
        cwd = self.currentdir:string(),
    })
    if not ok then err, p = p, nil end
    local out_close, err_close = close_file(stdout), close_file(stderr)
    if not p then
        local cleanup_error = cleanup_capture(folder, marker, out_path, err_path)
        return nil, diagnostics(err or 'The worker process could not be started.', out_close, err_close, cleanup_error)
    end
    self:clean()
    -- Keep ownership if closing a parent writer failed after spawn. The child
    -- still gets reaped and its owned files cleaned through the normal worker.
    return setmetatable({
        process = p,
        out_path = out_path, err_path = err_path,
        out_offset = 0, err_offset = 0,
        spool_folder = folder,
        output = {},
        error = diagnostics(out_close, err_close),
        proto_s = {},
        cancel_folder = marker and folder or nil, cancel_file = marker,
    }, mt)
end

return backend
