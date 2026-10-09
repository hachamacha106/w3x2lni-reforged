local ffi = require 'ffi'
local loaddll = require 'ffi.loaddll'

ffi.cdef[[
    struct SFILE_CREATE_MPQ {
        uint32_t cbSize;         // Size of this structure, in bytes
        uint32_t dwMpqVersion;   // Version of the MPQ to be created
        void*         pvUserData;     // Reserved, must be NULL
        uint32_t cbUserData;     // Reserved, must be 0
        uint32_t dwStreamFlags;  // Stream flags for creating the MPQ
        uint32_t dwFileFlags1;   // File flags for (listfile). 0 = default
        uint32_t dwFileFlags2;   // File flags for (attributes). 0 = default
        uint32_t dwFileFlags3;   // File flags for (signature). 0 = default
        uint32_t dwAttrFlags;    // Flags for the (attributes) file. If 0, no attributes will be created
        uint32_t dwSectorSize;   // Sector size for compressed files
        uint32_t dwRawChunkSize; // Size of raw data chunk
        uint32_t dwMaxFileCount; // File limit for the MPQ
    };
    
    bool __stdcall SFileCreateArchive2(const wchar_t* szMpqName, struct SFILE_CREATE_MPQ* pCreateInfo, uintptr_t* phMpq);
    bool __stdcall SFileOpenArchive(const wchar_t* szMpqName, uint32_t dwPriority, uint32_t dwFlags, uintptr_t* phMpq);
    bool __stdcall SFileCompactArchive(uintptr_t hMpq, const wchar_t* szListFile, bool bReserved);
    bool __stdcall SFileCloseArchive(uintptr_t hMpq);
    bool __stdcall SFileAddFileEx(uintptr_t hMpq, const wchar_t* szFileName, const char* szArchivedName, uint32_t dwFlags, uint32_t dwCompression, uint32_t dwCompressionNext);
    bool __stdcall SFileExtractFile(uintptr_t hMpq, const char* szToExtract, const wchar_t* szExtracted, uint32_t dwSearchScope);
    bool __stdcall SFileHasFile(uintptr_t hMpq, const char* szFileName);
    bool __stdcall SFileSetMaxFileCount(uintptr_t hMpq, uint32_t dwMaxFileCount);
    
    bool __stdcall SFileCreateFile(uintptr_t hMpq, const char* szArchivedName, uint64_t FileTime, uint32_t dwFileSize, uint32_t lcLocale, uint32_t dwFlags, uintptr_t* phFile);
    bool __stdcall SFileWriteFile(uintptr_t hFile, const void* pvData, uint32_t dwSize, uint32_t dwCompression);
    bool __stdcall SFileFinishFile(uintptr_t hFile);
    bool __stdcall SFileOpenFileEx(uintptr_t hMpq, const char* szFileName, uint32_t dwSearchScope, uintptr_t* phFile);
    bool __stdcall SFileReadFile(uintptr_t hFile, void* lpBuffer, uint32_t dwToRead, uint32_t* pdwRead, void* lpOverlapped);
    uint32_t __stdcall SFileGetFileSize(uintptr_t hFile, uint32_t* pdwFileSizeHigh);
    bool __stdcall SFileCloseFile(uintptr_t hFile);
    bool __stdcall SFileRemoveFile(uintptr_t hMpq, const char* szFileName, uint32_t dwSearchScope);

    bool __stdcall SFileGetFileInfo(uintptr_t hMpqOrFile, int InfoClass, void * pvFileInfo, uint32_t cbFileInfo, uint32_t* pcbLengthNeeded);

    uint32_t __stdcall SFileGetLocale();
    int __stdcall SCompCompress(void* output, int* output_size, const void* input, int input_size, uint32_t mask, int type, int level);
    int __stdcall SCompDecompress(void* output, int* output_size, const void* input, int input_size);

    uint32_t __stdcall GetLastError();
]]
ffi.cdef[[
    struct SYSTEMTIME {
        unsigned short wYear;
        unsigned short wMonth;
        unsigned short wDayOfWeek;
        unsigned short wDay;
        unsigned short wHour;
        unsigned short wMinute;
        unsigned short wSecond;
        unsigned short wMilliseconds;
    };
    struct FILETIME {
        unsigned long dwLowDateTime;
        unsigned long dwHighDateTime;
    };
    void __stdcall GetSystemTime(struct SYSTEMTIME* lpSystemTime);
    int __stdcall SystemTimeToFileTime(const struct SYSTEMTIME* lpSystemTime, struct FILETIME*lpFileTime);
    int __stdcall MoveFileW(const wchar_t* source, const wchar_t* destination);
]]

local SFileMpqNumberOfFiles = 36

loaddll 'stormlib'
local fs = require 'bee.filesystem'
local uni = require 'ffi.unicode'
local stormlib = ffi.load('stormlib')

local function current_filetime()
    local systemtime = ffi.new('struct SYSTEMTIME')
    local filetime = ffi.new('struct FILETIME')
    ffi.C.GetSystemTime(systemtime)
    if ffi.C.SystemTimeToFileTime(systemtime, filetime) == 0 then
        return 0
    end
    return filetime.dwLowDateTime | (filetime.dwHighDateTime << 32)
end


local wfile = {}
wfile.__index = wfile

function wfile:close()
    if self.handle == 0 then
        return true
    end
    local ok = stormlib.SFileFinishFile(self.handle)
    local err = not ok and ('SFileFinishFile failed (%d)'):format(ffi.C.GetLastError()) or nil
    self.handle = 0
    return ok, err
end

function wfile:write(buf)
    if self.handle == 0 then
        return false
    end
    return stormlib.SFileWriteFile(self.handle, buf, #buf, 0x02)
end

local rfile = {}
rfile.__index = rfile

function rfile:close()
    if self.handle == 0 then
        return true
    end
    local ok = stormlib.SFileCloseFile(self.handle)
    local err = not ok and ('SFileCloseFile failed (%d)'):format(ffi.C.GetLastError()) or nil
    self.handle = 0
    return ok, err
end

function rfile:size()
    if self.handle == 0 then
        return 0
    end
    local size_hi = ffi.new('unsigned long[1]', 0)
    local size_lo = stormlib.SFileGetFileSize(self.handle, size_hi)
    if size_lo == 0xFFFFFFFF then
        return nil, ('SFileGetFileSize failed or member is too large (%d)'):format(ffi.C.GetLastError())
    end
    return size_lo | (size_hi[0] << 32)
end

function rfile:read(n)
    if self.handle == 0 then
        return nil
    end
    if not n then
        n = self:size()
    end
    if not n then return nil, 'Cannot determine member size' end
    if n == 0 then return '' end
    local buf = ffi.new('char[?]', n)
    local pread = ffi.new('unsigned long[1]', 0)
    if not stormlib.SFileReadFile(self.handle, buf, n, pread, nil) then
        return nil
    end
    if pread[0] ~= n then return nil end
    return ffi.string(buf, pread[0])
end

local archive = {}
archive.__index = archive

function archive:close()
    if self.handle == 0 then
        return true
    end
    local compacted, compact_error = true
    if not self.readonly then
        compacted = stormlib.SFileCompactArchive(self.handle, nil, false)
        if not compacted then
            compact_error = ('SFileCompactArchive failed (%d)'):format(ffi.C.GetLastError())
        end
    end
    local closed = stormlib.SFileCloseArchive(self.handle)
    local close_error = not closed and ('SFileCloseArchive failed (%d)'):format(ffi.C.GetLastError()) or nil
    self.handle = 0
    if not compacted then return false, compact_error end
    return closed, close_error
end

function archive:add_file(name, path)
    if self.handle == 0 then
        return false
    end
    local wpath = uni.u2w(path:string())
    return stormlib.SFileAddFileEx(self.handle, wpath, name,
            0x00000200 | 0x80000000, -- MPQ_FILE_COMPRESS | MPQ_FILE_REPLACEEXISTING,
            0x02, -- MPQ_COMPRESSION_ZLIB,
            0x02 --MPQ_COMPRESSION_ZLIB
            )
end

function archive:extract(name, path)
    if self.handle == 0 then
        return false
    end
    local dir = path:parent_path()
    if not fs.exists(dir) then
        fs.create_directories(dir)
    end
    local wpath = uni.u2w(path:string())
    return stormlib.SFileExtractFile(self.handle, name, wpath,
            0 --SFILE_OPEN_FROM_MPQ
            )
end

function archive:has_file(name)
    if self.handle == 0 then
        return false
    end
    return stormlib.SFileHasFile(self.handle, name)
end

function archive:remove_file(name)
    if self.handle == 0 then
        return false
    end
    return stormlib.SFileRemoveFile(self.handle, name, 0)
end

function archive:open_file(name)
    if self.handle == 0 then
        return nil
    end
    local phandle = ffi.new('uintptr_t[1]', 0)
    if not stormlib.SFileOpenFileEx(self.handle, name, 0, phandle) then
        return nil
    end
    return setmetatable({ handle = phandle[0] }, rfile)
end

function archive:create_file(name, size, filetime)
    if self.handle == 0 then
        return nil
    end
    if not filetime then
        filetime = current_filetime()
    end
    local phandle = ffi.new('uintptr_t[1]', 0)
    if not stormlib.SFileCreateFile(self.handle, name, filetime, size, stormlib.SFileGetLocale(), 0x00000200 | 0x80000000, phandle) then
        return nil
    end
    return setmetatable({ handle = phandle[0] }, wfile)
end

function archive:load_file(name, max_size)
    if self.handle == 0 then
        return nil
    end
    local file = self:open_file(name)
    if not file then
        return nil
    end
    local size, size_error = file:size()
    if not size or (max_size and size > max_size) then
        file:close()
        return nil, size_error or 'Member exceeds the analysis memory limit'
    end
    local content, read_error = file:read(size)
    local closed, close_error = file:close()
    if not closed then return nil, close_error end
    return content, read_error
end

function archive:save_file(name, buf, filetime)
    if self.handle == 0 then
        return false
    end
    local file = self:create_file(name, #buf, filetime)
    if not file then
        return false, ('SFileCreateFile failed (%d)'):format(ffi.C.GetLastError())
    end
    local written = file:write(buf)
    local write_error = not written and ('SFileWriteFile failed (%d)'):format(ffi.C.GetLastError()) or nil
    local finished, finish_error = file:close()
    if not written then return false, write_error end
    return finished, finish_error
end

function archive:number_of_files()
    if self.handle == 0 then
        return 0
    end
    local pinfo = ffi.new('uint32_t[1]', 0)
    if not stormlib.SFileGetFileInfo(self.handle, SFileMpqNumberOfFiles, pinfo, 4, nil) then
        return 0
    end
    return pinfo[0]
end

local m = {}
function m.open(path, readonly, filecount)
    local wpath = uni.u2w(path:string())
    local phandle = ffi.new('uintptr_t[1]', 0)
    local flag = 0
    if readonly then
        flag = 0x100
    end
    if not stormlib.SFileOpenArchive(wpath, 0, flag, phandle) then
        return nil, ('SFileOpenArchive failed (%d)'):format(ffi.C.GetLastError())
    end
    if filecount and not stormlib.SFileSetMaxFileCount(phandle[0], filecount) then
        local err = ('SFileSetMaxFileCount failed (%d)'):format(ffi.C.GetLastError())
        stormlib.SFileCloseArchive(phandle[0])
        return nil, err
    end
    return setmetatable({ handle = phandle[0], readonly = readonly }, archive)
end
function m.create(path, filecount, encrypt, options)
    options = options or {}
    local wpath = uni.u2w(path:string())
    local phandle = ffi.new('uintptr_t[1]', 0)
    local info = ffi.new('struct SFILE_CREATE_MPQ')
    info.cbSize = ffi.sizeof('struct SFILE_CREATE_MPQ')
    info.dwMpqVersion   = 0 --MPQ_FORMAT_VERSION_1
    info.pvUserData     = nil
    info.cbUserData     = 0
    info.dwStreamFlags  = 0 --STREAM_PROVIDER_FLAT | BASE_PROVIDER_FILE
    if encrypt then
        info.dwFileFlags1   = 0
        info.dwFileFlags2   = 0
        info.dwFileFlags3   = 0
    else
        info.dwFileFlags1   = 0x80000000 --MPQ_FILE_EXISTS
        info.dwFileFlags2   = 0x80000000 --MPQ_FILE_EXISTS
        info.dwFileFlags3   = 0x80000000 --MPQ_FILE_EXISTS
    end
    info.dwFileFlags1 = options.listfile_flags or info.dwFileFlags1
    info.dwFileFlags2 = options.attributes_flags or info.dwFileFlags2
    info.dwFileFlags3 = options.signature_flags or info.dwFileFlags3
    info.dwAttrFlags    = options.attribute_types or 7 --MPQ_ATTRIBUTE_CRC32 | MPQ_ATTRIBUTE_FILETIME | MPQ_ATTRIBUTE_MD5
    info.dwSectorSize   = options.sector_size or 0x10000
    info.dwRawChunkSize = 0
    info.dwMaxFileCount = filecount
    if not stormlib.SFileCreateArchive2(wpath, info, phandle) then
        return nil, ('SFileCreateArchive2 failed (%d)'):format(ffi.C.GetLastError())
    end
    return setmetatable({ handle = phandle[0] }, archive)
end
function m.attach(handle)
    return setmetatable({ handle = handle }, archive)
end

-- Atomically promote within the same volume, refusing an existing destination.
-- std::filesystem::rename can replace a file, so do not use it for this guard.
function m.promote(source, destination)
    local wsource = uni.u2w(source:string())
    local wdestination = uni.u2w(destination:string())
    if ffi.C.MoveFileW(wsource, wdestination) == 0 then
        return nil, ('Cannot promote optimized map without overwriting (%d)'):format(ffi.C.GetLastError())
    end
    return true
end

-- StormLib9.40 explicitly rejects header.wSectorSize == 0 during open.
-- This is the 512-byte layout; never produce it as an accepted output.
function m.supports_sector_size(size)
    if size == 512 then return false, 'StormLib rejects the 512-byte sector header (ERROR_BAD_FORMAT)' end
    return size == 4096 or size == 65536, 'Unsupported candidate sector size'
end

-- MPQ sector encoding for the bounded lossless writer. StormLib includes the
-- compression mask in the result and returns original bytes when not smaller.
function m.compress(buf)
    if #buf == 0 then return buf end
    local size = ffi.new('int[1]', #buf)
    local output = ffi.new('char[?]', #buf)
    if stormlib.SCompCompress(output, size, buf, #buf, 0x02, 0, 0) == 0 then
        return nil, 'SCompCompress failed'
    end
    local encoded = ffi.string(output, size[0])
    if #encoded >= #buf then return buf end
    local decoded_size = ffi.new('int[1]', #buf)
    local decoded = ffi.new('char[?]', #buf)
    if stormlib.SCompDecompress(decoded, decoded_size, encoded, #encoded) == 0
        or decoded_size[0] ~= #buf or ffi.string(decoded, decoded_size[0]) ~= buf then
        return nil, 'Compressed sector failed byte verification'
    end
    return encoded
end
return m
