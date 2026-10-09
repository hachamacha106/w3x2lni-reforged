local brand = {
    name = 'W3x2lni Reforged',
    maintainer = 'hachamacha106',
    repository = 'https://github.com/hachamacha106/w3x2lni-Reforged',
}

local modes = {
    W3x2Lni = 'LNI',
    W3x2Slk = 'SLK',
    W3x2Obj = 'OBJ',
    War3Dump = 'Game data',
}

function brand.window_title(mode)
    local label = modes[mode]
    return label and (brand.name .. ' - ' .. label) or brand.name
end

return brand
