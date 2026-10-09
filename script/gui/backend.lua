local process = require 'bee.subprocess'
local proto = require 'share.protocol'
local lang = require 'share.lang'
local fs = require 'bee.filesystem'
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
        local res = proto.recv(self.proto_s, bytes)
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
        return
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
        return
    end
    self.err_rd:close()
    self.err_rd = nil
end

function mt:update_pipe()
    self:update_out()
    self:update_err()
    if not self.process:is_running() then
        self:unpack_out()
        if self.err_rd then
            self.error = self.error .. self.err_rd:read 'a'
        end
        self.exit_code = self.process:wait()
        self.process:kill()
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
        while #self.output > 0 do
            self:update_message()
        end
        self.output = {}
        if self.out_rd then
            self.out_rd:close()
            self.out_rd = nil
        end
        backend.message = lang.ui.FAILED
    end
    if self.closed then
        while #self.output > 0 do
            self:update_message()
        end
        self.exited = true
        return true
    end
    return false
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
    local p = process.spawn {
        self.application:string(),
        '-E',
        '-e', ('package.cpath=[[%s]]'):format(package.cpath),
        entry,
        commandline,
        console = 'disable',
        stdout = true,
        stderr = true,
        cwd = self.currentdir:string(),
    }
    if not p then
        cleanup_cancel(folder, marker)
        return
    end
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
