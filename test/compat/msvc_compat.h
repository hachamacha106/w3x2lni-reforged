#pragma once
// Build the unchanged Windows parser dependency for converter tests on Linux.
// This header is used only by build_runtime.py, never by the Windows package.
#include <cstdio>
#include <cstring>
#include <cstdint>
#include <cstdlib>
#include <cmath>
#include <cerrno>
#include <limits>
#ifndef _WIN32
#define __declspec(value)
template <size_t N, typename... Args>
int sprintf_s(char (&buffer)[N], const char* format, Args... args) {
    return std::snprintf(buffer, N, format, args...);
}
#endif
