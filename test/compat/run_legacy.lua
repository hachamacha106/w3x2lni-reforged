local source = debug.getinfo(1, 'S').source:sub(2):gsub('\\', '/')
local directory = source:match('^(.*)/[^/]+$')
local context = dofile(directory .. '/bootstrap.lua')

-- Historical fixtures assert the original binary/profile layouts and values.
-- Use their upstream defaults, independent of the dataset selected by the app.
-- bootstrap.lua keeps these config changes in memory without saving config.ini.
local config = require 'share.config'
local defaults = (require 'lni')(assert(io.load(
    context.fs.path(context.root) / 'script' / 'share' / 'config.ini')),
    'script/share/config.ini')
for section, values in pairs(defaults) do
    for key, value in pairs(values) do
        config[section][key] = value
    end
end
assert(config.global.data == 'zhCN-1.24.4', 'Historical fixtures require their original dataset')

dofile(context.root .. '/test/unit_test.lua')
