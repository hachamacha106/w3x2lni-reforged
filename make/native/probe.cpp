// Native API/ABI probe against the actual pinned headers and rebuilt DLL.
#include <StormLib.h>
#include <zlib.h>
#include <cstddef>
#include <cstdio>
#include <cstring>
#include <iostream>
#include <stdexcept>
#include <string>
#include <vector>

static void require(bool ok, const char* op) { if (!ok) throw std::runtime_error(op); }
static void write_member(HANDLE archive, const char* name, const std::string& bytes) {
    HANDLE file = NULL;
    require(SFileCreateFile(archive, name, 123456789, (DWORD)bytes.size(), 0,
        MPQ_FILE_COMPRESS, &file), "SFileCreateFile");
    bool written = SFileWriteFile(file, bytes.data(), (DWORD)bytes.size(), MPQ_COMPRESSION_ZLIB);
    bool finished = SFileFinishFile(file);
    require(written && finished, "SFileWriteFile/SFileFinishFile");
}
static void check_member(HANDLE archive, const char* name, const std::string& expected) {
    HANDLE file = NULL;
    require(SFileOpenFileEx(archive, name, SFILE_OPEN_FROM_MPQ, &file), "SFileOpenFileEx");
    DWORD hi = 0, size = SFileGetFileSize(file, &hi), read = 0;
    std::vector<char> bytes(size ? size : 1);
    bool loaded = SFileReadFile(file, bytes.data(), size, &read, NULL);
    bool closed = SFileCloseFile(file);
    require(loaded && closed && hi == 0 && read == size &&
        std::string(bytes.data(), read) == expected, "Decoded bytes changed");
}
#ifdef _WIN32
static std::wstring wide_path(const std::string& path) {
    int count = MultiByteToWideChar(CP_UTF8, MB_ERR_INVALID_CHARS, path.data(), (int)path.size(), NULL, 0);
    require(count > 0, "UTF-8 path conversion");
    std::wstring result(count, 0);
    require(MultiByteToWideChar(CP_UTF8, MB_ERR_INVALID_CHARS, path.data(),
        (int)path.size(), &result[0], count) == count, "UTF-8 path conversion");
    return result;
}
#endif
static bool smoke_archive(const std::string& dir, DWORD sector) {
    const std::string path = dir + "/probe-" + std::to_string(sector) + ".mpq";
    SFILE_CREATE_MPQ info = {};
    info.cbSize = sizeof(info);
    info.dwMpqVersion = MPQ_FORMAT_VERSION_1;
    info.dwFileFlags1 = MPQ_FILE_DEFAULT_INTERNAL;
    info.dwFileFlags2 = MPQ_FILE_DEFAULT_INTERNAL;
    info.dwAttrFlags = MPQ_ATTRIBUTE_CRC32 | MPQ_ATTRIBUTE_FILETIME | MPQ_ATTRIBUTE_MD5;
    info.dwSectorSize = sector;
    info.dwMaxFileCount = 16;
    HANDLE archive = NULL;
#ifdef _WIN32
    auto wide = wide_path(path);
    require(SFileCreateArchive2(wide.c_str(), &info, &archive), "SFileCreateArchive2");
#else
    require(SFileCreateArchive2(path.c_str(), &info, &archive), "SFileCreateArchive2");
#endif
    std::string bytes;
    for (int i = 0; i < 150000; ++i) bytes += (char)((i / 64) % 251);
    write_member(archive, "data\\sample.bin", bytes);
    write_member(archive, "empty.bin", "");
    const char* unicode_name = "textures\\\xc4\x8d\xc3\xad\xc5\x88\xc3\xa1.bin";
    write_member(archive, unicode_name, "opaque import");
    require(SFileCloseArchive(archive), "SFileCloseArchive(write)");
#ifdef _WIN32
    bool reopened = SFileOpenArchive(wide.c_str(), 0, MPQ_OPEN_READ_ONLY, &archive);
    DWORD reopen_error = reopened ? ERROR_SUCCESS : GetLastError();
#else
    bool reopened = SFileOpenArchive(path.c_str(), 0, MPQ_OPEN_READ_ONLY, &archive);
    DWORD reopen_error = reopened ? ERROR_SUCCESS : SErrGetLastError();
#endif
    if (sector == 512) {
        // Pinned 9.40 rejects header.wSectorSize == 0 despite allowing creation.
        require(!reopened && reopen_error == ERROR_BAD_FORMAT, "Unexpected 512-byte sector behavior");
        return false;
    }
    require(reopened, "SFileOpenArchive");
    DWORD actual_sector = 0;
    require(SFileGetFileInfo(archive, SFileMpqSectorSize, &actual_sector,
        sizeof(actual_sector), NULL) && actual_sector == sector, "Sector size changed");
    check_member(archive, "data\\sample.bin", bytes);
    check_member(archive, "empty.bin", "");
    check_member(archive, unicode_name, "opaque import");
    DWORD checksum = 0;
    char md5[16] = {};
    require(SFileGetFileChecksums(archive, "data\\sample.bin", &checksum, md5) &&
        checksum == crc32(0, (const Bytef*)bytes.data(), (uInt)bytes.size()),
        "SFileGetFileChecksums ABI/checksum mismatch");
    require(SFileCloseArchive(archive), "SFileCloseArchive(read)");
    // Keep probe artifacts for diagnostics; their fresh directory is controlled by Python.
    return true;
}
static void compression_probe() {
    std::string source(10000, 'x');
    std::vector<char> encoded(source.size()), decoded(source.size());
    int encoded_size = (int)encoded.size(), decoded_size = (int)decoded.size();
    require(SCompCompress(encoded.data(), &encoded_size, &source[0], (int)source.size(),
        MPQ_COMPRESSION_ZLIB, 0, 0) != 0, "SCompCompress");
    require(encoded_size < (int)source.size() && SCompDecompress(decoded.data(), &decoded_size,
        encoded.data(), encoded_size) != 0 && decoded_size == (int)source.size() &&
        std::string(decoded.data(), decoded.size()) == source, "Compression round trip");
}
#define ARCHIVE_EXPORTS(X) \
    X(SFileCreateArchive2) \
    X(SFileOpenArchive) \
    X(SFileCompactArchive) \
    X(SFileCloseArchive) \
    X(SFileAddFileEx) \
    X(SFileExtractFile) \
    X(SFileHasFile) \
    X(SFileSetMaxFileCount) \
    X(SFileCreateFile) \
    X(SFileWriteFile) \
    X(SFileFinishFile) \
    X(SFileOpenFileEx) \
    X(SFileReadFile) \
    X(SFileGetFileSize) \
    X(SFileCloseFile) \
    X(SFileRemoveFile) \
    X(SFileGetFileInfo) \
    X(SFileGetLocale) \
    X(SCompCompress) \
    X(SCompDecompress) \
    X(SFileFindFirstFile) \
    X(SFileFindNextFile) \
    X(SFileFindClose) \
    X(SFileEnumLocales) \
    X(SFileGetFileChecksums) \
    X(SFileVerifyFile)
#define FIELD(type, name) std::cout << "\"" #name "\":" << offsetof(type, name)
#define W2L_ABI_CONSTANT(name) std::cout << "\"" #name "\":" << (unsigned long long)(name)
static int run_probe(const std::string& directory) {
    try {
        require(std::strcmp(STORMLIB_VERSION_STRING, "9.40") == 0, "Wrong StormLib header");
        require(std::strcmp(zlibVersion(), "1.3.2") == 0, "Wrong linked zlib");
        // Reference every API used by the production FFI and diagnostic bridge.
#define EXPORT_ADDRESS(name) (const void*)&name,
        const void* volatile exports[] = { ARCHIVE_EXPORTS(EXPORT_ADDRESS) };
#undef EXPORT_ADDRESS
        for (const auto& entry : exports) require(entry != NULL, "Missing exports");
#ifdef _WIN32
        // Lua resolves plain names dynamically; import-library linking is insufficient.
        HMODULE module = GetModuleHandleW(L"StormLib.dll");
        require(module != NULL, "Rebuilt StormLib module not loaded");
#define EXPORT_LOOKUP(name) require(GetProcAddress(module, #name) != NULL, "Missing DLL export: " #name);
        ARCHIVE_EXPORTS(EXPORT_LOOKUP)
#undef EXPORT_LOOKUP
#endif
        compression_probe();
        require(!smoke_archive(directory, 512), "512-byte sectors unexpectedly supported");
        require(smoke_archive(directory, 4096) && smoke_archive(directory, 65536), "Supported-sector roundtrip failed");
        std::cout << "{\"schema_version\":1,\"status\":\"passed\",\"versions\":{\"stormlib\":\""
            << STORMLIB_VERSION_STRING << "\",\"zlib\":\"" << zlibVersion()
            << "\"},\"pointer_size\":" << sizeof(void*) << ",\"dword_size\":" << sizeof(DWORD)
            << ",\"sizes\":{\"SFILE_CREATE_MPQ\":" << sizeof(SFILE_CREATE_MPQ)
            << ",\"SFILE_FIND_DATA\":" << sizeof(SFILE_FIND_DATA)
            << "},\"offsets\":{\"create\":{";
        FIELD(SFILE_CREATE_MPQ, cbSize); std::cout << ',';
        FIELD(SFILE_CREATE_MPQ, dwMpqVersion); std::cout << ',';
        FIELD(SFILE_CREATE_MPQ, pvUserData); std::cout << ',';
        FIELD(SFILE_CREATE_MPQ, cbUserData); std::cout << ',';
        FIELD(SFILE_CREATE_MPQ, dwStreamFlags); std::cout << ',';
        FIELD(SFILE_CREATE_MPQ, dwFileFlags1); std::cout << ',';
        FIELD(SFILE_CREATE_MPQ, dwFileFlags2); std::cout << ',';
        FIELD(SFILE_CREATE_MPQ, dwFileFlags3); std::cout << ',';
        FIELD(SFILE_CREATE_MPQ, dwAttrFlags); std::cout << ',';
        FIELD(SFILE_CREATE_MPQ, dwSectorSize); std::cout << ',';
        FIELD(SFILE_CREATE_MPQ, dwRawChunkSize); std::cout << ',';
        FIELD(SFILE_CREATE_MPQ, dwMaxFileCount); std::cout << "},\"find\":{";
        FIELD(SFILE_FIND_DATA, cFileName); std::cout << ',';
        FIELD(SFILE_FIND_DATA, szPlainName); std::cout << ',';
        FIELD(SFILE_FIND_DATA, dwHashIndex); std::cout << ',';
        FIELD(SFILE_FIND_DATA, dwBlockIndex); std::cout << ',';
        FIELD(SFILE_FIND_DATA, dwFileSize); std::cout << ',';
        FIELD(SFILE_FIND_DATA, dwFileFlags); std::cout << ',';
        FIELD(SFILE_FIND_DATA, dwCompSize); std::cout << ',';
        FIELD(SFILE_FIND_DATA, dwFileTimeLo); std::cout << ',';
        FIELD(SFILE_FIND_DATA, dwFileTimeHi); std::cout << ',';
        FIELD(SFILE_FIND_DATA, lcLocale); std::cout << "}},\"constants\":{";
        W2L_ABI_CONSTANT(SFileMpqHeaderOffset); std::cout << ','; W2L_ABI_CONSTANT(SFileMpqArchiveSize64); std::cout << ',';
        W2L_ABI_CONSTANT(SFileMpqNumberOfFiles); std::cout << ','; W2L_ABI_CONSTANT(SFileMpqSectorSize); std::cout << ',';
        W2L_ABI_CONSTANT(SFileMpqFlags); std::cout << ','; W2L_ABI_CONSTANT(SFileInfoLocale); std::cout << ',';
        W2L_ABI_CONSTANT(SFileInfoFileIndex); std::cout << ','; W2L_ABI_CONSTANT(SFileInfoByteOffset); std::cout << ',';
        W2L_ABI_CONSTANT(SFileInfoFileTime); std::cout << ','; W2L_ABI_CONSTANT(SFileInfoFileSize); std::cout << ',';
        W2L_ABI_CONSTANT(SFileInfoCompressedSize); std::cout << ','; W2L_ABI_CONSTANT(SFileInfoFlags); std::cout << ',';
        W2L_ABI_CONSTANT(MPQ_FLAG_WAR3_MAP); std::cout << ','; W2L_ABI_CONSTANT(MPQ_FLAG_MALFORMED); std::cout << ',';
        W2L_ABI_CONSTANT(MPQ_FILE_COMPRESS); std::cout << ','; W2L_ABI_CONSTANT(MPQ_FILE_ENCRYPTED); std::cout << ',';
        W2L_ABI_CONSTANT(MPQ_FILE_KEY_V2); std::cout << ','; W2L_ABI_CONSTANT(MPQ_COMPRESSION_ZLIB);
        std::cout << "},\"exports\":[";
        bool first_export = true;
#define EXPORT_JSON(name) if (!first_export) std::cout << ','; std::cout << "\"" #name "\""; first_export = false;
        ARCHIVE_EXPORTS(EXPORT_JSON)
#undef EXPORT_JSON
        std::cout << "],\"smoke\":{\"attempted_sector_sizes\":[512,4096,65536],"
            "\"sector_sizes\":[4096,65536],\"unsupported_sector_sizes\":[512],"
            "\"sector_rejections\":[{\"sector_size\":512,\"error\":" << ERROR_BAD_FORMAT <<
            ",\"reason\":\"StormLib 9.40 rejects zero sector shift\"}],"
            "\"payloads_equal\":true,\"empty_file\":true,\"unicode_member\":true,\"zlib_roundtrip\":true}}\n";
        return 0;
    } catch (const std::exception& error) { std::cerr << error.what() << '\n'; return 1; }
}

#ifdef _WIN32
int wmain(int argc, wchar_t** argv) {
    if (argc != 2) { std::cerr << "Pass a fresh probe directory\n"; return 1; }
    const std::wstring path(argv[1]);
    int size = WideCharToMultiByte(CP_UTF8, WC_ERR_INVALID_CHARS, path.data(),
        (int)path.size(), NULL, 0, NULL, NULL);
    if (size <= 0) { std::cerr << "Invalid Unicode probe path\n"; return 1; }
    std::string utf8(size, 0);
    if (WideCharToMultiByte(CP_UTF8, WC_ERR_INVALID_CHARS, path.data(),
            (int)path.size(), &utf8[0], size, NULL, NULL) != size) return 1;
    return run_probe(utf8);
}
#else
int main(int argc, char** argv) {
    if (argc != 2) { std::cerr << "Pass a fresh probe directory\n"; return 1; }
    return run_probe(argv[1]);
}
#endif
