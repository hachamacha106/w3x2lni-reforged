-- Load the process module first so another bee module cannot mask missing links.
local runtime = assert(arg[1], 'Pass the built test-runtime directory')
package.cpath = runtime .. '/?.so;' .. package.cpath
local sp = require 'bee.subprocess'
assert(sp.get_id() > 0)
local time = require 'bee.time'
local thread = require 'bee.thread'
assert(type(time.monotonic()) == 'number')
thread.sleep(0)

-- Exercise file descriptor duplication, separate diagnostics and nonzero status.
local stdout = assert(io.tmpfile())
local stderr = assert(io.tmpfile())
local process = assert(sp.spawn {
    runtime .. '/lua', '-e',
    [[io.stdout:write('process stdout\n'); io.stderr:write('process stderr\n'); os.exit(17)]],
    stdout = stdout, stderr = stderr,
})
assert(process:wait() == 17, 'Child exit status was lost')
assert(stdout:seek('set', 0))
assert(stderr:seek('set', 0))
assert(stdout:read('a') == 'process stdout\n', 'Child stdout was lost')
assert(stderr:read('a') == 'process stderr\n', 'Child stderr was lost')
stdout:close()
stderr:close()
print('PASS fresh subprocess/time/thread modules, redirected diagnostics and child exit status')
