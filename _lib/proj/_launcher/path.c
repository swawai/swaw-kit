#define WIN32_LEAN_AND_MEAN
#define UNICODE
#define _UNICODE
#include <windows.h>

#include "path.h"

static DWORD wide_length(const WCHAR *value)
{
    DWORD length = 0u;
    while (value[length] != L'\0') {
        ++length;
    }
    return length;
}

static BOOL ascii_equal_ignore_case(WCHAR actual, WCHAR expected)
{
    if (actual >= L'a' && actual <= L'z') {
        actual -= L'a' - L'A';
    }
    return actual == expected;
}

static BOOL is_drive_absolute(const WCHAR *path, DWORD length)
{
    WCHAR drive = path[0];
    return length >= 3u
        && ((drive >= L'A' && drive <= L'Z')
        || (drive >= L'a' && drive <= L'z'))
        && path[1] == L':'
        && path[2] == L'\\';
}

static BOOL is_extended_unc(const WCHAR *path, DWORD length)
{
    return length >= 9u
        && path[0] == L'\\'
        && path[1] == L'\\'
        && path[2] == L'?'
        && path[3] == L'\\'
        && ascii_equal_ignore_case(path[4], L'U')
        && ascii_equal_ignore_case(path[5], L'N')
        && ascii_equal_ignore_case(path[6], L'C')
        && path[7] == L'\\'
        && path[8] != L'\0';
}

BOOL is_extended_absolute_path(const WCHAR *path)
{
    DWORD length;
    if (path == NULL) {
        return FALSE;
    }
    length = wide_length(path);
    if (is_extended_unc(path, length)) {
        return TRUE;
    }
    return length >= 7u
        && path[0] == L'\\'
        && path[1] == L'\\'
        && path[2] == L'?'
        && path[3] == L'\\'
        && is_drive_absolute(path + 4u, length - 4u);
}

static BOOL copy_parts(
    const WCHAR *prefix,
    const WCHAR *source,
    DWORD source_start,
    WCHAR *destination,
    DWORD capacity
)
{
    DWORD prefix_length = wide_length(prefix);
    DWORD source_length = wide_length(source);
    DWORD destination_index = 0u;
    DWORD source_index;

    if (source_start > source_length
        || prefix_length + source_length - source_start + 1u > capacity) {
        return FALSE;
    }
    for (source_index = 0u; source_index < prefix_length; ++source_index) {
        destination[destination_index++] = prefix[source_index];
    }
    for (source_index = source_start; source_index <= source_length; ++source_index) {
        destination[destination_index++] = source[source_index];
    }
    return TRUE;
}

BOOL copy_extended_absolute_path(
    const WCHAR *source,
    WCHAR *destination,
    DWORD capacity
)
{
    static const WCHAR extended_prefix[] = L"\\\\?\\";
    static const WCHAR unc_prefix[] = L"\\\\?\\UNC\\";
    DWORD source_length;

    if (source == NULL || destination == NULL || capacity == 0u) {
        return FALSE;
    }
    source_length = wide_length(source);
    if (is_extended_absolute_path(source)) {
        return copy_parts(L"", source, 0u, destination, capacity);
    }
    if (is_drive_absolute(source, source_length)) {
        return copy_parts(extended_prefix, source, 0u, destination, capacity);
    }
    if (source_length >= 3u
        && source[0] == L'\\' && source[1] == L'\\'
        && source[2] != L'?' && source[2] != L'.' && source[2] != L'\0') {
        return copy_parts(unc_prefix, source, 2u, destination, capacity);
    }
    return FALSE;
}

BOOL copy_dos_absolute_path(
    const WCHAR *source,
    WCHAR *destination,
    DWORD capacity
)
{
    DWORD source_length;

    if (source == NULL || destination == NULL || capacity == 0u) {
        return FALSE;
    }
    source_length = wide_length(source);
    if (is_drive_absolute(source, source_length)
        || (source_length >= 3u
            && source[0] == L'\\'
            && source[1] == L'\\'
            && source[2] != L'?'
            && source[2] != L'.')) {
        return copy_parts(L"", source, 0u, destination, capacity);
    }
    if (is_extended_unc(source, source_length)) {
        return copy_parts(L"\\\\", source, 8u, destination, capacity);
    }
    if (source_length >= 7u
        && source[0] == L'\\'
        && source[1] == L'\\'
        && source[2] == L'?'
        && source[3] == L'\\'
        && is_drive_absolute(source + 4u, source_length - 4u)) {
        return copy_parts(L"", source, 4u, destination, capacity);
    }
    return FALSE;
}
