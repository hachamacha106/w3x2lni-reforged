-- Private regression entry for the retired archive experiment.
-- It is not dispatched by w2l.exe and is not part of the conversion GUI.
-- Keep its preservation/cancellation tests while testing the new StormLib DLL.
local source = debug.getinfo(1, 'S').source:sub(2):gsub('\\', '/')
local root = assert(source:match('^(.*)/test/release/archive_worker.lua$'),
    'Run the private archive regression entry by its absolute path')
package.path = root .. '/script/?.lua;' .. root .. '/script/?/init.lua;' .. package.path
package.cpath = root .. '/bin/?.dll;' .. package.cpath
local fs = require 'bee.filesystem'
fs.current_path(fs.path(root .. '/script'))
local action = assert(arg[1], 'Archive regression action required')
assert(action == 'analyze' or action == 'optimize', 'Unsupported archive regression action')
require 'utility'
require 'backend.lossless_cli' (action)
