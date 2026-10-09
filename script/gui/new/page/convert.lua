local save_dialog = require 'ffi.save_file_dialog'
local backend = require 'gui.backend'
local timer = require 'gui.timer'
local messagebox = require 'ffi.messagebox'
local lang = require 'share.lang'
local config = require 'share.config'
local ui = require 'gui.new.template'
local databinding = require 'gui.new.databinding'
local ev = require 'gui.event'
local fs = require 'bee.filesystem'

local root = fs.current_path()
local worker
local recovering = false
local recovery_error
local view
local data
local element

local function getexe()
    local i = 0
    while arg[i] ~= nil do
        i = i - 1
    end
    return fs.path(arg[i + 1])
end

local function update_show()
    data.report.visible = not not backend.lastword
    data.progress.visible = (not not worker) and not data.report.visible
    data.cancel.visible = worker and not worker.exited and (recovering or not backend.lastword)
        and (window._mode == 'analyze' or window._mode == 'optimize') or false
end

local function update_result()
    data.message = backend.message
    if backend.lastword then
        data.report.text = backend.lastword.content
        if backend.lastword.type == 'failed' or backend.lastword.type == 'error' then
            data.report.color = '#C33'
        elseif backend.lastword.type == 'warning' then
            data.report.color = '#FC3'
        else
            data.report.color = window._color
        end
    end
    data.progress.value = (backend.progress or 0) / 100
    update_show()
end

local function update()
    worker:update()
    update_result()
    if worker.exited then
        if worker.exit_code == 0 then
            return 1000, 0
        else
            return 0, worker.exit_code
        end
    end
end

local function start_recovery()
    local ok, err = xpcall(function() worker:recover(recovery_error) end, debug.traceback)
    if ok then recovery_error = nil
    else backend:failure(recovery_error .. '\n' .. err) end
    return ok
end

local function delayedtask(t)
    if recovering then
        if recovery_error and not start_recovery() then update_result(); return end
        local ok, finished = xpcall(function() return worker:drain_failure() end, debug.traceback)
        if not ok then backend:failure(finished)
        elseif finished then recovering = false; t:remove() end
        update_result()
        return
    end
    local ok, r, code = xpcall(update, debug.traceback)
    if not ok then
        recovering = true
        recovery_error = r
        start_recovery()
        update_result()
        return
    end
    if r then t:remove() end
end

local template = ui.container {
    style = { FlexGrow = 1, Padding = 4 },
    font = { size = 18 },
    -- upper
    ui.container {
        id = 'config',
        style = { FlexGrow = 1, JustifyContent = 'flex-start' },
        -- filename
        ui.button {
            style = { Height = 36, MarginTop = 4, MarginBottom = 16 },
            bind = {
                title = 'filename',
                color = 'theme'
            },
        }
    },
    -- lower
    ui.container {
        style = { FlexGrow = 1, JustifyContent = 'flex-end' },
        -- message
        ui.label {
            style = { Height = 20, MarginBottom = 8 },
            text_color = '#CCC',
            align = 'start',
            bind = {
                text = 'message',
            },
        },
        -- progress
        ui.progress {
            style = { Height = 30, MarginBottom = 8, FlexDirection = 'row' },
            bind = {
                value = 'progress.value',
                visible = 'progress.visible',
                color = 'theme'
            },
        },
        -- report
        ui.button {
            style = { Height = 30, MarginBottom = 8 },
            bind = {
                title = 'report.text',
                color = 'report.color',
                visible = 'report.visible',
            },
            on = {
                click = function ()
                    window:show_page 'report'
                end
            },
        },
        ui.button {
            title = lang.ui.CANCEL_OPERATION,
            style = { Height = 30, MarginBottom = 8 },
            bind = { visible = 'cancel.visible' },
            on = { click = function()
                if worker and not worker.exited and worker.cancel then
                    local ok, err = worker:cancel()
                    if ok then data.message = lang.ui.CANCELLING
                    else messagebox(lang.ui.ERROR, '%s', tostring(err)) end
                end
            end },
        },
        -- start
        ui.button {
            title = lang.ui.START,
            style = { Height = 50 },
            bind = {
                color = 'theme'
            },
            on = {
                click = function ()
                    local ok, err = xpcall(function()
                        if worker and not worker.exited then
                            return
                        end
                        local arguments = {window._mode, window._filename:string()}
                        if window._mode == 'optimize' then
                            local destination, dialog_error = save_dialog {
                                title = lang.ui.OPTIMIZE_SAVE,
                                filename = window._filename:stem():string() .. '.optimized' .. window._filename:extension():string(),
                                folder = window._filename:parent_path():string(),
                            }
                            if dialog_error then error(dialog_error, 0) end
                            if not destination then return end
                            arguments[3] = destination
                            if fs.exists(fs.path(arguments[3])) then
                                messagebox(lang.ui.ERROR, '%s', lang.ui.OPTIMIZE_NEW_PATH)
                                return
                            end
                        end
                        recovering, recovery_error = false, nil
                        backend:init(getexe(), fs.current_path())
                        local open_error
                        worker, open_error = backend:open('backend\\init.lua', arguments)
                        if not worker then error(open_error or 'The worker process could not be started.', 0) end
                        backend.message = lang.ui.INIT
                        backend.progress = 0
                        data.progress.value = backend.progress / 100
                        data.progress.visible = true
                        data.report.visible = false
                        data.cancel.visible = window._mode == 'analyze' or window._mode == 'optimize'
                        timer.loop(100, delayedtask)
                        window._worker = worker
                    end, debug.traceback)
                    if not ok then
                        backend:clean()
                        backend:failure(err)
                        update_result()
                    end
                end,
            },
        },
    },
}

view, data, element = ui.create(template, {
    filename = '',
    message  = '',
    theme = window._color,
    report   = {
        text  = '',
        color = window._color,
        visible = false
    },
    cancel = { visible = false },
    progress = {
        value = 0,
        visible = false
    }
})

function view:on_show()
    update_show()
    data.filename = window._filename:filename():string()
    if window._mode == 'analyze' then
        data.message = lang.ui.ANALYZE_HINT
    elseif window._mode == 'optimize' then
        data.message = lang.ui.OPTIMIZE_HINT
    end
end

local function checkbox(t)
    t.on = {
        mouseenter = 'update_tip(self.tip)',
        mouseleave = 'update_tip()'
    }
    t.style = { MarginTop = 4, MarginBottom = 4 }
    if t.bind then
        t.bind.color = 'theme'
    else
        t.bind = { color = 'theme' }
    end
    return ui.checkbox(t)
end

local configData = databinding {
    theme = window._color,
    config = config,
    update_tip = function(tip)
        if worker and not worker.exited then
            return
        end
        if tip then
            data.message = tip
        else
            data.message = ''
        end
    end
}

local function lni()
    local template = ui.container {
        font = { size = 18 },
        checkbox {
            text = lang.ui.READ_SLK,
            tip = lang.ui.READ_SLK_HINT,
            bind = {
                value = 'config.lni.read_slk'
            }
        },
        ui.tree {
            text = lang.ui.ADVANCED,
            style = { MarginTop = 4, MarginBottom = 4 },
            bind = {
                color = 'theme'
            },
            checkbox {
                text = lang.ui.EXPORT_LUA,
                tip = lang.ui.EXPORT_LUA_HINT,
                bind = {
                    value = 'config.lni.export_lua'
                }
            },
            checkbox {
                text = lang.ui.EXTRA_CHECK,
                tip = lang.ui.EXTRA_CHECK_HINT,
                bind = {
                    value = 'config.lni.extra_check'
                }
            }
        }
    }
    return ui.createEx(template, configData)
end

local function slk()
    local template = ui.container {
        font = { size = 18 },
        checkbox {
            text = lang.ui.REMOVE_UNUSED_OBJECT,
            tip = lang.ui.REMOVE_UNUSED_OBJECT_HINT,
            bind = {
                value = 'config.slk.remove_unuse_object'
            }
        },
        checkbox {
            text = lang.ui.OPTIMIZE_JASS,
            tip = lang.ui.OPTIMIZE_JASS_HINT,
            bind = {
                value = 'config.slk.optimize_jass'
            }
        },
        checkbox {
            text = lang.ui.MDX_SQUF,
            tip = lang.ui.MDX_SQUF_HINT,
            bind = {
                value = 'config.slk.mdx_squf'
            }
        },
        checkbox {
            text = lang.ui.REMOVE_WE_ONLY,
            tip = lang.ui.REMOVE_WE_ONLY_HINT,
            bind = {
                value = 'config.slk.remove_we_only'
            }
        },
        ui.tree {
            text = lang.ui.ADVANCED,
            style = { MarginTop = 4, MarginBottom = 4 },
            bind = {
                color = 'theme'
            },
            checkbox {
                text = lang.ui.SLK_DOODAD,
                tip = lang.ui.SLK_DOODAD_HINT,
                bind = {
                    value = 'config.slk.slk_doodad'
                }
            },
            checkbox {
                text = lang.ui.CONFUSION,
                tip = lang.ui.CONFUSION_HINT,
                bind = {
                    value = 'config.slk.confused'
                }
            },
            checkbox {
                text = lang.ui.EXTRA_CHECK,
                tip = lang.ui.EXTRA_CHECK_HINT,
                bind = {
                    value = 'config.slk.extra_check'
                }
            }
        }
    }
    return ui.createEx(template, configData)
end

local function obj()
    local template = ui.container {
        font = { size = 18 },
        checkbox {
            text = lang.ui.READ_SLK,
            tip = lang.ui.READ_SLK_HINT,
            bind = {
                value = 'config.obj.read_slk'
            }
        },
        ui.tree {
            text = lang.ui.ADVANCED,
            style = { MarginTop = 4, MarginBottom = 4 },
            bind = {
                color = 'theme'
            },
            checkbox {
                text = lang.ui.EXTRA_CHECK,
                tip = lang.ui.EXTRA_CHECK_HINT,
                bind = {
                    value = 'config.obj.extra_check'
                }
            }
        }
    }
    return ui.createEx(template, configData)
end

local function mpq()
    return ui.create(ui.container { }, {})
end

local current_page
local pages = {}

ev.on('update theme', function(color, title)
    data.theme = color
    data.report.color = color
    backend.lastword = nil
    data.message = ''
    data.cancel.visible = false
    worker = nil
    recovering, recovery_error = false, nil

    configData.proxy.theme = color

    if current_page then
        current_page:setvisible(false)
    end
    if not pages[title] then
        if title == 'W3x2Lni' then
            pages[title] = lni()
        elseif title == 'W3x2Slk' then
            pages[title] = slk()
        elseif title == 'W3x2Obj' then
            pages[title] = obj()
        elseif title == 'War3Dump' or title == 'Analyze' or title == 'Optimize' then
            pages[title] = mpq()
        end
        element.config:addchildview(pages[title])
    end
    current_page = pages[title]
    current_page:setvisible(true)
end)

return view
