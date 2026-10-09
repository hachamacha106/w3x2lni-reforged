local gui = require 'yue.gui'
local ca = require 'gui.new.common_attribute'

return function(t, data)
    local edit = gui.TextEdit.create()
    local text = ''
    local updating = false

    local function set_text(value)
        text = value
        updating = true
        edit:settext(value)
        updating = false
    end

    if t.readonly then
        -- Keep the bound report authoritative if native read-only setup cannot
        -- acquire focus. Programmatic loads/restores emit changes synchronously.
        -- Never round-trip the log through the old native gettext length limit.
        function edit:ontextchange()
            if updating then
                return
            end
            local first, last = self:getselectionrange()
            updating = true
            self:settext(text)
            self:selectrange(first, last)
            updating = false
        end
        function edit:shouldinsertnewline()
            return false
        end
    end

    function edit:onkeydown(event)
        local modifiers = event.modifiers
        local key = event.key:lower()
        if modifiers & gui.Event.maskcontrol ~= 0
            and modifiers & (gui.Event.maskalt | gui.Event.maskmeta) == 0 then
            if key == 'a' then
                self:selectall()
                return true
            elseif key == 'c' or key == 'insert' then
                self:copy()
                return true
            end
        end
        -- This Yue version treats Tab as text input in a TextEdit. Let report
        -- controls provide a focus destination instead of trapping the keyboard.
        if key == 'tab' and modifiers & (gui.Event.maskcontrol | gui.Event.maskalt | gui.Event.maskmeta) == 0
            and t.on and t.on.tab then
            t.on.tab(self, event)
            return true
        end
        return false
    end

    if t.style then
        edit:setstyle(t.style)
    end
    -- RichEdit wraps by default; a horizontal scrollbar would hide long lines.
    edit:setscrollbarpolicy(t.hpolicy or 'never', t.vpolicy or 'automatic')
    if t.text_color then
        edit:setcolor(t.text_color)
    end
    ca.font(edit, t)
    ca.label_color(edit, t, data, {})

    if t.bind and t.bind.text then
        local binding
        binding = data:bind(t.bind.text, function()
            set_text(binding:get())
        end)
        set_text(binding:get())
    else
        set_text(t.text or '')
    end
    return edit
end
