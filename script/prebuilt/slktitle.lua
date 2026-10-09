local loader
local schema = require 'core.slk.schema'

local function sortpairs(t)
    local sort = {}
    for k, v in pairs(t) do
        sort[#sort+1] = {k, v}
    end
    table.sort(sort, function (a, b)
        return a[1] < b[1]
    end)
    local n = 1
    return function()
        local v = sort[n]
        if not v then
            return
        end
        n = n + 1
        return v[1], v[2]
    end
end

local function fmtstring(s)
    if s:find '[^%w_]' then
        return ('%q'):format(s)
    end
    return s
end

local function create_slktitle(w2l, slkname, slktitle)
    local slk = loader(slkname)
    local titles = schema.titles(slk)
    slktitle[slkname] = titles
end

local function stringify(f, name, t)
    if not t then
        return
    end
    f[#f+1] = ('%s = {'):format(fmtstring(name))
    for _, v in ipairs(t) do
        f[#f+1] = ('%s,'):format(fmtstring(v))
    end
    f[#f+1] = '}'
end

return function(w2l, loader_)
    loader = loader_
    local slktitle = {}
    for _, type in ipairs {'ability', 'buff', 'unit', 'item', 'upgrade', 'doodad', 'destructable'} do
        for _, slkname in pairs(w2l.info.slk[type]) do
            create_slktitle(w2l, slkname, slktitle)
        end
    end
    local f = {}
    for k, v in sortpairs(slktitle) do
        stringify(f, k, v)
    end
    return table.concat(f, '\r\n')
end
