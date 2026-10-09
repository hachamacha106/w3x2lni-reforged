local gui = require 'yue.gui'
local backend = require 'gui.backend'
local timer = require 'gui.timer'
local messagebox = require 'ffi.messagebox'
local lang = require 'share.lang'
local config = require 'share.config'
local ui = require 'gui.new.template'
local databinding = require 'gui.new.databinding'
local ev = require 'gui.event'
local fs = require 'bee.filesystem'
local theme = require 'gui.new.theme'

local root = fs.current_path()
local worker
local recovering = false
local recovery_error
local view
local data
local element
local configData

local function getexe()
    local i = 0
    while arg[i] ~= nil do
        i = i - 1
    end
    return fs.path(arg[i + 1])
end

local function update_show()
    local busy = window._closing or worker and not worker.exited
    data.actions.enabled = not busy
    data.actions.start_text = busy and lang.ui.PROCESSING or lang.ui.START
    if configData then configData.proxy.enabled = not busy end
    data.report.visible = not not backend.lastword
    data.progress.visible = (not not worker) and not data.report.visible
end

local function update_result()
    data.message = backend.message
    if backend.lastword then
        data.report.text = backend.lastword.content
        if backend.lastword.type == 'failed' or backend.lastword.type == 'error' then
            data.report.color = theme.error
        elseif backend.lastword.type == 'warning' then
            data.report.color = theme.warning
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
    style = { FlexGrow = 1, Padding = 16 },
    font = { name = 'Segoe UI', size = 14 },
    -- upper
    ui.container {
        id = 'config',
        style = { FlexGrow = 1, JustifyContent = 'flex-start' },
        ui.container {
            color = theme.surface,
            style = { Height = 48, Padding = 10, MarginBottom = 16, FlexShrink = 0 },
            ui.label {
                id = 'filename',
                align = 'start',
                style = { FlexGrow = 1 },
                bind = { text = 'filename' },
            },
        },
        ui.label {
            id = 'options_heading',
            text = lang.ui.CONVERSION_OPTIONS,
            align = 'start',
            style = { Height = 32, MarginBottom = 8 },
            font = { name = 'Segoe UI', size = 17, weight = 'bold' },
        },
    },
    -- lower
    ui.container {
        style = { FlexShrink = 0, JustifyContent = 'flex-end' },
        -- message
        ui.label {
            id = 'status_message',
            style = { Height = 44, MarginBottom = 8 },
            text_color = theme.muted,
            font = { name = 'Segoe UI', size = 13 },
            align = 'start',
            bind = {
                text = 'message',
            },
        },
        -- progress
        ui.progress {
            style = { Height = 12, MarginBottom = 12, FlexDirection = 'row' },
            bind = {
                value = 'progress.value',
                visible = 'progress.visible',
                color = 'theme'
            },
        },
        -- report
        ui.button {
            style = { Height = 40, MarginBottom = 12 },
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
        ui.container {
            style = { Height = 44, FlexDirection = 'row', FlexShrink = 0 },
            ui.button {
                id = 'change_format',
                title = lang.ui.CHANGE_FORMAT,
                color = theme.raised,
                style = { Width = 160, MarginRight = 12 },
                bind = { enabled = 'actions.enabled' },
                on = { click = function()
                    if window._closing or worker and not worker.exited then return end
                    window:show_page 'select'
                end },
            },
            -- start
            ui.button {
                id = 'start',
                style = { FlexGrow = 1 },
                bind = {
                    title = 'actions.start_text',
                    enabled = 'actions.enabled',
                    color = 'theme'
                },
                on = {
                    click = function ()
                        local ok, err = xpcall(function()
                            if window._closing or worker and not worker.exited then
                                return
                            end
                            local arguments = {window._mode, window._filename:string()}
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
                            timer.loop(100, delayedtask)
                            window._worker = worker
                            update_show()
                        end, debug.traceback)
                        if not ok and not window._closing then
                            backend:clean()
                            backend:failure(err)
                            update_result()
                        end
                    end,
                },
            },
        },
    },
}

view, data, element = ui.create(template, {
    filename = '',
    message  = '',
    theme = window._color,
    actions = { enabled = true, start_text = lang.ui.START },
    report   = {
        text  = '',
        color = window._color,
        visible = false
    },
    progress = {
        value = 0,
        visible = false
    }
})

function view:on_show()
    update_show()
    data.filename = window._filename:filename():string()
end

local function checkbox(t)
    t.on = {
        mouseenter = 'update_tip(self.tip)',
        mouseleave = 'update_tip()'
    }
    t.style = { Height = 30, MarginTop = 2, MarginBottom = 2 }
    if t.bind then
        t.bind.enabled = 'enabled'
    else
        t.bind = { enabled = 'enabled' }
    end
    return ui.checkbox(t)
end

configData = databinding {
    theme = window._color,
    panel = theme.surface,
    enabled = true,
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
        font = { name = 'Segoe UI', size = 14 },
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
                color = 'panel'
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
        font = { name = 'Segoe UI', size = 14 },
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
                color = 'panel'
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
        font = { name = 'Segoe UI', size = 14 },
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
                color = 'panel'
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
    worker = nil
    recovering, recovery_error = false, nil
    update_show()

    configData.proxy.theme = color

    if current_page then
        current_page:setvisible(false)
    end
    if title ~= 'W3x2Lni' and title ~= 'W3x2Slk' and title ~= 'W3x2Obj' and title ~= 'War3Dump' then return end
    if not pages[title] then
        if title == 'W3x2Lni' then
            pages[title] = lni()
        elseif title == 'W3x2Slk' then
            pages[title] = slk()
        elseif title == 'W3x2Obj' then
            pages[title] = obj()
        elseif title == 'War3Dump' then
            pages[title] = mpq()
        end
        element.config:addchildview(pages[title])
    end
    current_page = pages[title]
    current_page:setvisible(true)
end)

return view
