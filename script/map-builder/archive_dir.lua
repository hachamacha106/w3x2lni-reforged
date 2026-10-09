local path_filter = require 'map-builder.path_filter'
local fs = require 'bee.filesystem'

local ignore = {}
for _, name in ipairs {'.git', '.svn', '.vscode', '.gitignore'} do
    ignore[name] = true
end

local esc_map = {}
local loaded_map = {}
for c in ('/:*?"<>|$'):gmatch '.' do
    esc_map[c] = ('$%02x'):format(c:byte())
end
for i = 0, 31 do
    esc_map[string.char(i)] = ('$%02x'):format(i)
end
for k, v in pairs(esc_map) do
    loaded_map[v] = k
end
local function esced_name(name)
    name = name:gsub('[^\\]*', function (path)
        if path == '' then
            return '$'
        end
        return path:gsub('.', esc_map)
    end)
    return name
end

local function loaded_name(name)
    name = name:gsub('[^\\]*', function (path)
        if path == '$' then
            return ''
        end
        return path:gsub('$..', loaded_map)
    end)
    return name
end

local function scan_dir(dir, callback)
    if not fs.exists(dir) then
        return
    end
    for path in fs.pairs(dir) do
        if not ignore[path:filename():string()] then
            if fs.is_directory(path) then
                scan_dir(path, callback)
            else
                callback(path)
            end
        end
    end
end

local mt = {}
mt.__index = mt

function mt:save(path, dirs)
    return true
end

function mt:close()
end

function mt:list_file()
    if not self._list_file then
        self._list_file = {}
        local len = #self.path:string()
        scan_dir(self.path, function (path)
            local name = path:string():sub(len+2):gsub('/', '\\')
            self._list_file[#self._list_file+1] = loaded_name(name)
        end)
    end
    return self._list_file
end

-- Read-only inventory with physical paths for bounded diagnostics. Conversion
-- keeps its existing list_file traversal and filename escaping behavior.
function mt:foreach_file(callback, options)
    assert(self.read, 'Directory diagnostics require a read-only archive')
    options = options or {}
    local root = fs.canonical(self.path)
    local prefix = root:string():gsub('\\', '/'):gsub('/+$', '') .. '/'
    local count = 0
    local function skipped(name, reason)
        if options.skipped then options.skipped(name, reason) end
    end
    local function scan(dir, depth)
        if options.cancelled and options.cancelled() then error('Optimization cancelled') end
        for path in fs.pairs(dir) do
            if options.cancelled and options.cancelled() then error('Optimization cancelled') end
            if not ignore[path:filename():string()] then
                count = count + 1
                local raw = path:string():gsub('\\', '/')
                local name = loaded_name(raw:sub(#prefix + 1):gsub('/', '\\'))
                if count > (options.max_entries or 65536) then
                    skipped(name, ('Project inventory exceeds the %d-entry safety limit'):format(options.max_entries or 65536))
                    return false
                end
                local kind = fs.symlink_status(path):type()
                if kind ~= 'directory' and kind ~= 'regular' then
                    skipped(name, 'Linked or nonregular project entry was not read: ' .. kind)
                else
                    local physical = fs.canonical(path)
                    local key = physical:string():gsub('\\', '/')
                    if raw:sub(1, #prefix) ~= prefix or key:sub(1, #prefix) ~= prefix then
                        skipped(name, 'Project entry resolves outside the input folder')
                    elseif kind == 'directory' then
                        if depth >= (options.max_depth or 128) then
                            skipped(name, 'Project directory nesting exceeds the safety limit')
                        elseif not scan(path, depth + 1) then return false end
                    else
                        callback(name, physical)
                    end
                end
            end
        end
        return true
    end
    return scan(root, 0)
end

function mt:number_of_files()
    return #self:list_file()
end

function mt:flush()
    local reserved = path_filter {'/table/', '/trigger/', '/w3x2lni/', '/map/war3map.*'}
    local len = #self.path:string()
    for _, dir in ipairs {'table', 'trigger', 'w3x2lni', 'map'} do
        scan_dir(self.path / dir, function (path)
            local name = path:string():sub(len+2):gsub('/', '\\')
            if not self.read and reserved(name) then
                fs.remove(path)
            end
        end)
    end
end

function mt:extract(name, path)
    return fs.copy_file(self.path / esced_name(name), path, fs.copy_options.overwrite_existing)
end

function mt:has_file(name)
    return fs.exists(self.path / esced_name(name))
end

function mt:remove_file(name)
    fs.remove(self.path / esced_name(name))
end

function mt:load_file(name)
    local new_name = esced_name(name)
    local f = io.open((self.path / new_name):string(), 'rb')
    if not f then
        return nil
    end
    local buf = f:read 'a'
    f:close()
    return buf
end

function mt:save_file(name, buf, filetime)
    local new_name = esced_name(name)
    local dir = (self.path / new_name):parent_path()
    if not fs.exists(dir) then
        fs.create_directories(dir)
    end
    io.save(self.path / new_name, buf)
    return true
end

return function (input, read)
    return setmetatable({ path = input, read = read }, mt)
end
