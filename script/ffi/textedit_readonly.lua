local ffi = require 'ffi'

ffi.cdef[[
    void* __stdcall GetFocus(void);
    intptr_t __stdcall SendMessageW(void* hwnd, unsigned int message,
                                   uintptr_t wparam, intptr_t lparam);
]]

local EM_SETREADONLY = 0x00CF

return function(edit)
    -- The shipped Yue TextEdit owns a native RichEdit child window. Its
    -- hasfocus() compares that exact HWND with GetFocus() on this UI thread.
    -- Only address the supplied, already-focused control; never search windows.
    if not edit:hasfocus() then
        return false
    end
    local hwnd = ffi.C.GetFocus()
    if hwnd == nil or hwnd == ffi.NULL or not edit:hasfocus() then
        return false
    end
    return tonumber(ffi.C.SendMessageW(hwnd, EM_SETREADONLY, 1, 0)) ~= 0
end
