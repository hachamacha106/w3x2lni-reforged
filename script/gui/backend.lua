local process = require 'bee.subprocess'
local proto = require 'share.protocol'
local lang = require 'share.lang'
local fs = require 'bee.filesystem'
local time = require 'bee.time'
local cancel_sequence = 0

local function cleanup_cancel(folder, marker)
    if marker then pcall(fs.remove, marker) end
    if folder then pcall(fs.remove, folder) end -- Only an owned, empty directory.
end

local function cancel_folder()
    local base = fs.absolute(fs.temp_directory_path() / 'w2l-cancel-parent'):parent_path()
    for _ = 1, 100 do
        cancel_sequence = cancel_sequence + 1
        local folder = base / ('w2l-cancel-%d-%d-%d'):format(process.get_id(), os.time(), cancel_sequence)
        if fs.create_directory(folder) then return folder, folder / 'cancel' end
    end
    error('Cannot create an operation cancellation directory')
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

function mt:update_out()
    if not self.out_rd then
        return
    end
    local n = process.peek(self.out_rd)
    if n == nil then
        self.out_rd:close()
        self.out_rd = nil
        return
    end
    if n == 0 or n == nil then
        return
    end
    local r = self.out_rd:read(n)
    if r then
        self:unpack_out(r)
        return #r > 0
    end
    self.out_rd:close()
    self.out_rd = nil
end

function mt:update_err()
    if not self.err_rd then
        return
    end
    local n = process.peek(self.err_rd)
    if n == nil then
        self.err_rd:close()
        self.err_rd = nil
        return
    end
    if n == 0 then
        return
    end
    local r = self.err_rd:read(n)
    if r then
        self.error = self.error .. r
        return #r > 0
    end
    self.err_rd:close()
    self.err_rd = nil
end

function mt:update_pipe()
    self:update_out()
    self:update_err()
    if not self.process:is_running() then
        -- A descendant may retain a writer after the child ends. Drain only
        -- currently available bytes rather than waiting for pipe EOF.
        while self:update_out() do end
        while self:update_err() do end
        self:unpack_out()
        if self.out_rd then self.out_rd:close(); self.out_rd = nil end
        if self.err_rd then self.err_rd:close(); self.err_rd = nil end
        self.exit_code = self.process:wait()
        cleanup_cancel(self.cancel_folder, self.cancel_file)
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

local function drain_failed_pipes(worker)
    -- A failed pipe must not prevent polling the other pipe or the child.
    for _, update in ipairs {worker.update_out, worker.update_err} do
        while true do
            local ok, read = pcall(update, worker)
            if not ok then recovery_note(worker, read); break end
            if not read then break end
        end
    end
end

function mt:drain_failure()
    if self.exited then return true end
    drain_failed_pipes(self)
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
    drain_failed_pipes(self)
    local waited, code = pcall(self.process.wait, self.process)
    if waited then self.exit_code = code
    else recovery_note(self, code); self.exit_code = 1 end
    for _, name in ipairs {'out_rd', 'err_rd'} do
        if self[name] then
            local closed, err = pcall(self[name].close, self[name])
            if not closed then recovery_note(self, err) end
            self[name] = nil
        end
    end
    if self.process.close then pcall(self.process.close, self.process) end
    cleanup_cancel(self.cancel_folder, self.cancel_file)
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
    local folder, marker
    if commandline[1] == 'analyze' or commandline[1] == 'optimize' then
        local ok
        ok, folder, marker = pcall(cancel_folder)
        if not ok then return nil, folder end
        local forwarded = {}
        for i, value in ipairs(commandline) do forwarded[i] = value end
        forwarded[#forwarded + 1] = '-cancel-file=' .. marker:string()
        commandline = forwarded
    end
    local ok, p, err = pcall(process.spawn, {
        self.application:string(),
        '-E',
        '-e', ('package.cpath=[[%s]]'):format(package.cpath),
        entry,
        commandline,
        console = 'disable',
        stdout = true,
        stderr = true,
        cwd = self.currentdir:string(),
    })
    if not ok then err, p = p, nil end
    if not p then
        cleanup_cancel(folder, marker)
        return nil, err or 'The worker process could not be started.'
    end
    -- peek returns byte counts. CRT text translation would make read(n)
    -- wait for extra bytes when protocol/diagnostics contain CRLF.
    if p.stdout then process.filemode(p.stdout, 'b') end
    if p.stderr then process.filemode(p.stderr, 'b') end
    self:clean()
    return setmetatable({
        process = p,
        out_rd = p.stdout,
        err_rd = p.stderr,
        output = {},
        error = '',
        proto_s = {},
        cancel_folder = folder, cancel_file = marker,
    }, mt)
end

return backend
