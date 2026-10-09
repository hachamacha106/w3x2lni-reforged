local lang = require 'share.lang'
local config = require 'share.config'
local root = require 'backend.w2l_path'
local fs = require 'bee.filesystem'
local writer = require 'prebuilt.objectwriter'

return function (w2l, war3, version)
    w2l.messager.text(lang.script.CONVERT_ONE .. version)

    if war3.casc then
        w2l:set_setting
        {
            data      = config.global.data,
            data_ui   = '${DATA}',
            data_meta = '${DATA}',
            data_wes  = '${DATA}',
            version   = version,
        }
    else
        w2l:set_setting
        {
            data      = config.global.data,
            data_ui   = config.global.data_ui,
            data_meta = config.global.data_meta,
            data_wes  = config.global.data_wes,
            version   = version,
        }
    end

    local prebuilt_path = root / 'data' / config.global.data / 'prebuilt' / version
    fs.create_directories(prebuilt_path)

    local slk = w2l:frontend_buildslk()
    for type, data in pairs(slk) do
        io.save(prebuilt_path / (type .. '.ini'), writer(data))
    end
    return slk
end
