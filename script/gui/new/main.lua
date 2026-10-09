local gui = require 'yue.gui'
local ext = require 'yue-ext'
local timer = require 'gui.timer'
local ev = require 'gui.event'
local ui = require 'gui.new.template'
local fs = require 'bee.filesystem'
local brand = require 'share.brand'

window = {}

ext.on_timer = timer.update
function ext.on_dropfile(filename)
    if window._worker and not window._worker.exited then
        return
    end
    local check_lni_mark = require 'share.check_lni_mark'
    local builder = require 'map-builder'
    local war3 = require 'share.war3'
    local path = fs.path(filename)
    if war3:open(path) then
        window._filename = path
        window._mode = 'mpq'
        window:set_theme('War3Dump', '#9CD')
        window:show_page('convert')
        window:set_theme('War3Dump', '#9CD')
        return
    end
    if path:filename():string() == '.w3x' then
        if check_lni_mark(io.load(path)) then
            path = fs.absolute(path:parent_path())
        end
    end
    local map = builder.load(path)
    if not map then
        return
    end
    map:close()
    window._filename = path
    window:show_page('select')
end

local function create_mainview(win)
    local template = ui.container {
        color = '#222',
        style = { Padding = 1 },
        ui.container {
            id = 'caption',
            style = { Height = 40, FlexShrink = 0, FlexDirection = 'row' },
            bind = {
                color = 'theme'
            },
            ui.label {
                id = 'title',
                style = { FlexGrow = 1, MarginLeft = 6 },
                align = 'start',
                font = { name = 'Constantia', size = 24, weight = 'bold' },
                bind = {
                    text = 'title'
                }
            }
        }
    }
    
    local view, data = ui.create(template, {
        title = brand.name,
        theme = '#00ADD9',
    })
    
    ev.on('update theme', function(color, title)
        data.theme = color
        -- Keep the original mode token on the event bus; conversion settings
        -- use it to select the right page independently of the product name.
        data.title = brand.window_title(title)
        win:settitle(data.title)
    end)
    return view
end

function window:create(t)
    -- Use the native frame for resize borders, maximize/restore and the system menu.
    local win = gui.Window.create { frame = true }
    function win.onclose()
        if window._worker and not window._worker.exited and window._worker.cancel_file then
            pcall(window._worker.cancel, window._worker)
        end
        gui.MessageLoop.quit()
    end
    -- The unchanged native extension locates the window by this initial title.
    win:settitle('w3x2lni')
    ext.register_window('w3x2lni')
    ext.set_icon((fs.exe_path():parent_path() / 'w3x2lni.ico'):string())
    win:sethasshadow(true)
    win:setresizable(true)
    win:setmaximizable(true)
    win:setminimizable(true)
    win:setcontentsizeconstraints({ width = 400, height = 600 }, {})
    win:setcontentview(create_mainview(win))
    win:setcontentsize { width = t.width, height = t.height }
    win:center()
    win:activate()
    self._window = win
end

function window:set_theme(title, color)
    self._color = color
    ev.emit('update theme', color, title)
end

function window:show_page(name)
    local view = self._window:getcontentview()
    if self._page then
        self._page:setvisible(false)
    end
    self._page = require('gui.new.page.' .. name)
    self._page:setvisible(true)
    view:addchildview(self._page)
    if self._page.on_show then
        self._page:on_show()
    end
end

local view = window:create {
    width = 720,
    height = 600,
}

window:set_theme('W3x2Lni', '#00ADD9')
window:show_page('index')

gui.MessageLoop.run()
