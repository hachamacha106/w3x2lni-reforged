-- Read the source schema instead of assuming the columns of one Warcraft build.
local schema = {}

local function fields(line)
    local result = {}
    local start = 1
    local quoted = false
    local i = 1
    while i <= #line do
        local char = line:sub(i, i)
        if char == '"' then
            if quoted and line:sub(i + 1, i + 1) == '"' then
                i = i + 1
            else
                quoted = not quoted
            end
        elseif char == ';' and not quoted then
            result[#result + 1] = line:sub(start, i - 1)
            start = i + 1
        end
        i = i + 1
    end
    result[#result + 1] = line:sub(start)
    return result
end

function schema.titles(buffer)
    local titles = {}
    local x, y = 1, 1
    for line in (buffer or ''):gmatch '[^\r\n]+' do
        if line:sub(1, 2) == 'C;' then
            local values = fields(line)
            for _, value in ipairs(values) do
                local kind = value:sub(1, 1)
                if kind == 'X' then
                    x = tonumber(value:sub(2)) or x
                elseif kind == 'Y' then
                    y = tonumber(value:sub(2)) or y
                end
            end
            if y == 1 then
                for _, value in ipairs(values) do
                    if value:sub(1, 1) == 'K' then
                        value = value:sub(2)
                        if value:sub(1, 1) == '"' and value:sub(-1) == '"' then
                            value = value:sub(2, -2):gsub('""', '"')
                        end
                        titles[x] = value
                    end
                end
            end
        end
    end
    -- A valid object SLK has a contiguous header row. Do not renumber sparse
    -- source columns: doing so would associate values with the wrong fields.
    return titles
end

function schema.columns(titles)
    local columns = {}
    for _, title in pairs(titles) do
        columns[title:lower()] = title
    end
    return columns
end

function schema.level_count(columns, field)
    local prefix = field:lower()
    local count = 0
    for column in pairs(columns) do
        if column:sub(1, #prefix) == prefix then
            local suffix = column:sub(#prefix + 1)
            if suffix:match '^%d+$' then
                count = math.max(count, tonumber(suffix))
            end
        end
    end
    return count
end

function schema.level_field(field, level, doodad)
    if doodad then
        return ('%s%02d'):format(field, level)
    end
    return field .. level
end

return schema
