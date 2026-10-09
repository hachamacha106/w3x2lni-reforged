-- The retained Yue SaveDialog binding is unsafe on the shipped Lua runtime.
-- Use the Windows common dialog directly; choosing a path never writes a map.
local ffi = require 'ffi'
local unicode = require 'ffi.unicode'
ffi.cdef[[
    typedef struct {
        unsigned int lStructSize;
        void* hwndOwner;
        void* hInstance;
        const wchar_t* lpstrFilter;
        wchar_t* lpstrCustomFilter;
        unsigned int nMaxCustFilter;
        unsigned int nFilterIndex;
        wchar_t* lpstrFile;
        unsigned int nMaxFile;
        wchar_t* lpstrFileTitle;
        unsigned int nMaxFileTitle;
        const wchar_t* lpstrInitialDir;
        const wchar_t* lpstrTitle;
        unsigned int Flags;
        unsigned short nFileOffset;
        unsigned short nFileExtension;
        const wchar_t* lpstrDefExt;
        intptr_t lCustData;
        void* lpfnHook;
        const wchar_t* lpTemplateName;
        void* pvReserved;
        unsigned int dwReserved;
        unsigned int FlagsEx;
    } W2L_OPENFILENAMEW;
    int __stdcall GetSaveFileNameW(W2L_OPENFILENAMEW* options);
    unsigned int __stdcall CommDlgExtendedError(void);
    void* __stdcall GetActiveWindow(void);
]]
local common = ffi.load 'comdlg32'
local user = ffi.load 'user32'
local MAX_FILE = 32768
local FLAGS = 0x00080000 | 0x00000008 | 0x00000800 | 0x00000004
    | 0x00010000 | 0x00800000 | 0x02000000

local function wide(text)
    assert(type(text) == 'string' and not text:find('\0', 1, true), 'Invalid Save As text')
    return unicode.u2w(text)
end

return function(options, native)
    -- The injected boundary permits native ABI/Unicode tests without an
    -- interactive window. Production always calls the OS dialog below.
    native = native or {show = common.GetSaveFileNameW,
        error = common.CommDlgExtendedError, owner = user.GetActiveWindow}
    local size = ffi.sizeof('W2L_OPENFILENAMEW')
    assert(size == (ffi.sizeof('void*') == 4 and 88 or 152), 'Unexpected Windows Save As ABI')
    local name, length = wide(assert(options.filename))
    assert(length < MAX_FILE, 'The suggested output name is too long')
    local alive = {
        file = ffi.new('wchar_t[?]', MAX_FILE),
        title = wide(options.title or ''), folder = wide(options.folder or ''),
        extension = wide(options.filename:match('%.([^%.\\/]+)$') or 'w3x'),
        filter = unicode.u2w('Warcraft III maps\0*.w3x;*.w3m\0\0'),
    }
    ffi.copy(alive.file, name, (length + 1) * ffi.sizeof('wchar_t'))
    local record = ffi.new('W2L_OPENFILENAMEW[1]')
    record[0].lStructSize, record[0].hwndOwner = size, native.owner()
    record[0].lpstrFilter, record[0].nFilterIndex = alive.filter, 1
    record[0].lpstrFile, record[0].nMaxFile = alive.file, MAX_FILE
    record[0].lpstrInitialDir, record[0].lpstrTitle = alive.folder, alive.title
    record[0].lpstrDefExt, record[0].Flags = alive.extension, FLAGS
    local accepted = native.show(record)
    if not accepted or accepted == 0 then
        local code = tonumber(native.error())
        if code == 0 then return nil end -- User cancellation is not a failure.
        return nil, ('Windows Save As failed (0x%04X).'):format(code)
    end
    local count = 0
    while count < MAX_FILE and alive.file[count] ~= 0 do count = count + 1 end
    assert(count > 0 and count < MAX_FILE, 'Windows returned an invalid output path')
    return unicode.w2u(alive.file, count)
end
