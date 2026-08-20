#define WIN32_LEAN_AND_MEAN
#define UNICODE
#define _UNICODE
#include <windows.h>

#include "layout.h"
#include "path.h"

#define TEXT_CAPACITY PROJ_PATH_CAPACITY
#define INVALID_INDEX 0xffffffffu

static const WCHAR *entry_file;
static WCHAR home_root[TEXT_CAPACITY];
static WCHAR data_parent[TEXT_CAPACITY];
static WCHAR data_root[TEXT_CAPACITY];
static WCHAR runtime_root[TEXT_CAPACITY];
static WCHAR releases_root[TEXT_CAPACITY];
static WCHAR selected_core[TEXT_CAPACITY];
static WCHAR selector[TEXT_CAPACITY];
static WCHAR identity_path[TEXT_CAPACITY];
static WCHAR bootstrap[TEXT_CAPACITY];
static WCHAR identity[65u];
static CHAR identity_record[66u];
static CHAR release_selector[66u];
static BOOL manager_entry;

static DWORD wide_length(const WCHAR *value)
{
    DWORD length = 0u;
    while (value[length] != L'\0') {
        ++length;
    }
    return length;
}

static DWORD last_separator_before(const WCHAR *value, DWORD before)
{
    while (before > 0u) {
        --before;
        if (value[before] == L'\\' || value[before] == L'/') {
            return before;
        }
    }
    return INVALID_INDEX;
}

static BOOL copy_path_with_suffix(
    const WCHAR *source,
    DWORD prefix_length,
    const WCHAR *suffix,
    WCHAR *destination
)
{
    DWORD suffix_length = wide_length(suffix);
    DWORD index;

    if (prefix_length + suffix_length + 1u > TEXT_CAPACITY) {
        return FALSE;
    }
    for (index = 0u; index < prefix_length; ++index) {
        destination[index] = source[index];
    }
    for (index = 0u; index <= suffix_length; ++index) {
        destination[prefix_length + index] = suffix[index];
    }
    return TRUE;
}

static BOOL append_text(WCHAR *destination, DWORD *length, const WCHAR *value)
{
    DWORD source = 0u;
    while (value[source] != L'\0') {
        if (*length + 1u >= TEXT_CAPACITY) {
            return FALSE;
        }
        destination[(*length)++] = value[source++];
    }
    destination[*length] = L'\0';
    return TRUE;
}

static BOOL append_slice(
    WCHAR *destination,
    DWORD *length,
    const WCHAR *value,
    DWORD start,
    DWORD count
)
{
    DWORD source;
    if (*length + count + 1u > TEXT_CAPACITY) {
        return FALSE;
    }
    for (source = 0u; source < count; ++source) {
        destination[(*length)++] = value[start + source];
    }
    destination[*length] = L'\0';
    return TRUE;
}

static BOOL copy_path(WCHAR *destination, const WCHAR *source)
{
    return copy_path_with_suffix(source, wide_length(source), L"", destination);
}

static BOOL is_file(const WCHAR *path)
{
    DWORD attributes = GetFileAttributesW(path);
    return attributes != INVALID_FILE_ATTRIBUTES
        && (attributes & (FILE_ATTRIBUTE_DIRECTORY | FILE_ATTRIBUTE_REPARSE_POINT)) == 0u;
}

static BOOL is_directory(const WCHAR *path)
{
    DWORD attributes = GetFileAttributesW(path);
    return attributes != INVALID_FILE_ATTRIBUTES
        && (attributes & FILE_ATTRIBUTE_DIRECTORY) != 0u
        && (attributes & FILE_ATTRIBUTE_REPARSE_POINT) == 0u;
}

static BOOL is_lowercase_hex_record(const CHAR *record, DWORD bytes_read)
{
    DWORD index;
    if (bytes_read != 65u || record[64u] != '\n') {
        return FALSE;
    }
    for (index = 0u; index < 64u; ++index) {
        CHAR value = record[index];
        if (!((value >= '0' && value <= '9')
            || (value >= 'a' && value <= 'f'))) {
            return FALSE;
        }
    }
    return TRUE;
}

static BOOL is_manager_file(DWORD file_start, DWORD file_length)
{
    static const WCHAR manager_name[] = L"swawkit.exe";
    DWORD index;
    if (file_length != 11u) {
        return FALSE;
    }
    for (index = 0u; index < file_length; ++index) {
        WCHAR actual = entry_file[file_start + index];
        if (actual >= L'A' && actual <= L'Z') {
            actual += L'a' - L'A';
        }
        if (actual != manager_name[index]) {
            return FALSE;
        }
    }
    return TRUE;
}

static BOOL has_exe_suffix(DWORD file_start, DWORD file_length)
{
    DWORD suffix;
    if (file_length <= 4u) {
        return FALSE;
    }
    suffix = file_start + file_length - 4u;
    return entry_file[suffix] == L'.'
        && (entry_file[suffix + 1u] == L'e' || entry_file[suffix + 1u] == L'E')
        && (entry_file[suffix + 2u] == L'x' || entry_file[suffix + 2u] == L'X')
        && (entry_file[suffix + 3u] == L'e' || entry_file[suffix + 3u] == L'E');
}

BOOL locate_entry_layout(const WCHAR *entry_path)
{
    static const WCHAR data_prefix[] = L"\\data\\proj.";
    static const WCHAR data_suffix[] = L"\\data";
    static const WCHAR runtime_suffix[] = L"\\runtime";
    static const WCHAR releases_suffix[] = L"\\releases";
    static const WCHAR selector_suffix[] = L"\\current";
    static const WCHAR identity_suffix[] = L"\\entry.id";
    static const WCHAR bootstrap_suffix[] = L"\\_lib\\proj\\bootstrap.ps1";
    DWORD entry_length = wide_length(entry_path);
    DWORD home_length = last_separator_before(entry_path, entry_length);
    DWORD home_path_length;
    DWORD file_start;
    DWORD file_length;
    DWORD entry_name_length;
    DWORD length;

    if (!is_extended_absolute_path(entry_path)
        || home_length == INVALID_INDEX) {
        return FALSE;
    }
    home_path_length = home_length;
    if (home_length > 0u && entry_path[home_length - 1u] == L':') {
        ++home_path_length;
    }
    entry_file = entry_path;
    file_start = home_length + 1u;
    file_length = entry_length - file_start;
    if (!has_exe_suffix(file_start, file_length)) {
        return FALSE;
    }
    entry_name_length = file_length - 4u;
    manager_entry = is_manager_file(file_start, file_length);

    if (!copy_path_with_suffix(entry_path, home_path_length, L"", home_root)
        || !copy_path_with_suffix(entry_path, home_length, data_suffix, data_parent)
        || !copy_path_with_suffix(entry_path, home_length, data_prefix, data_root)) {
        return FALSE;
    }
    length = wide_length(data_root);
    if (manager_entry) {
        if (!append_text(data_root, &length, L"swawkit")) {
            return FALSE;
        }
    } else if (!append_slice(
        data_root,
        &length,
        entry_path,
        file_start,
        entry_name_length
    )) {
        return FALSE;
    }
    if (!copy_path(runtime_root, data_root)) {
        return FALSE;
    }
    length = wide_length(runtime_root);
    if (!append_text(runtime_root, &length, runtime_suffix)
        || !copy_path(releases_root, runtime_root)) {
        return FALSE;
    }
    length = wide_length(releases_root);
    if (!append_text(releases_root, &length, releases_suffix)
        || !copy_path(selector, runtime_root)) {
        return FALSE;
    }
    length = wide_length(selector);
    if (!append_text(selector, &length, selector_suffix)
        || !copy_path(identity_path, data_root)) {
        return FALSE;
    }
    length = wide_length(identity_path);
    return append_text(identity_path, &length, identity_suffix)
        && copy_path_with_suffix(entry_path, home_length, bootstrap_suffix, bootstrap);
}

DWORD read_layout_entry_id(void)
{
    DWORD attributes;
    DWORD error;
    HANDLE file;
    DWORD bytes_read = 0u;
    DWORD index;

    SetLastError(ERROR_SUCCESS);
    if (!is_directory(home_root)) {
        return ENTRY_ID_INVALID;
    }
    attributes = GetFileAttributesW(data_parent);
    if (attributes == INVALID_FILE_ATTRIBUTES) {
        error = GetLastError();
        return error == ERROR_FILE_NOT_FOUND || error == ERROR_PATH_NOT_FOUND
            ? ENTRY_ID_MISSING
            : ENTRY_ID_INVALID;
    }
    if ((attributes & FILE_ATTRIBUTE_DIRECTORY) == 0u
        || (attributes & FILE_ATTRIBUTE_REPARSE_POINT) != 0u) {
        return ENTRY_ID_INVALID;
    }

    SetLastError(ERROR_SUCCESS);
    attributes = GetFileAttributesW(data_root);
    if (attributes == INVALID_FILE_ATTRIBUTES) {
        error = GetLastError();
        return error == ERROR_FILE_NOT_FOUND || error == ERROR_PATH_NOT_FOUND
            ? ENTRY_ID_MISSING
            : ENTRY_ID_INVALID;
    }
    if ((attributes & FILE_ATTRIBUTE_DIRECTORY) == 0u
        || (attributes & FILE_ATTRIBUTE_REPARSE_POINT) != 0u) {
        return ENTRY_ID_INVALID;
    }

    SetLastError(ERROR_SUCCESS);
    attributes = GetFileAttributesW(identity_path);
    if (attributes == INVALID_FILE_ATTRIBUTES) {
        error = GetLastError();
        return error == ERROR_FILE_NOT_FOUND || error == ERROR_PATH_NOT_FOUND
            ? ENTRY_ID_MISSING
            : ENTRY_ID_INVALID;
    }
    if ((attributes & (FILE_ATTRIBUTE_DIRECTORY | FILE_ATTRIBUTE_REPARSE_POINT)) != 0u) {
        return ENTRY_ID_INVALID;
    }
    file = CreateFileW(
        identity_path,
        GENERIC_READ,
        FILE_SHARE_READ | FILE_SHARE_WRITE | FILE_SHARE_DELETE,
        NULL,
        OPEN_EXISTING,
        FILE_ATTRIBUTE_NORMAL | FILE_FLAG_OPEN_REPARSE_POINT,
        NULL
    );
    if (file == INVALID_HANDLE_VALUE
        || !ReadFile(file, identity_record, sizeof(identity_record), &bytes_read, NULL)) {
        if (file != INVALID_HANDLE_VALUE) {
            CloseHandle(file);
        }
        return ENTRY_ID_INVALID;
    }
    CloseHandle(file);
    if (!is_lowercase_hex_record(identity_record, bytes_read)) {
        return ENTRY_ID_INVALID;
    }
    for (index = 0u; index < 64u; ++index) {
        identity[index] = (WCHAR)identity_record[index];
    }
    identity[64u] = L'\0';
    return ENTRY_ID_VALID;
}

BOOL resolve_layout_current_core(void)
{
    static const WCHAR release_separator[] = L"\\";
    static const WCHAR core_suffix[] = L"\\swawkit-proj.exe";
    DWORD attributes;
    HANDLE file;
    DWORD bytes_read = 0u;
    DWORD index;
    DWORD destination;

    selected_core[0] = L'\0';
    if (!is_directory(home_root)
        || !is_directory(data_parent)
        || !is_directory(data_root)
        || !is_directory(runtime_root)
        || !is_directory(releases_root)) {
        return FALSE;
    }
    attributes = GetFileAttributesW(selector);
    if (attributes == INVALID_FILE_ATTRIBUTES
        || (attributes & (FILE_ATTRIBUTE_DIRECTORY | FILE_ATTRIBUTE_REPARSE_POINT)) != 0u) {
        return FALSE;
    }
    file = CreateFileW(
        selector,
        GENERIC_READ,
        FILE_SHARE_READ | FILE_SHARE_WRITE | FILE_SHARE_DELETE,
        NULL,
        OPEN_EXISTING,
        FILE_ATTRIBUTE_NORMAL | FILE_FLAG_OPEN_REPARSE_POINT,
        NULL
    );
    if (file == INVALID_HANDLE_VALUE
        || !ReadFile(file, release_selector, sizeof(release_selector), &bytes_read, NULL)) {
        if (file != INVALID_HANDLE_VALUE) {
            CloseHandle(file);
        }
        return FALSE;
    }
    CloseHandle(file);
    if (!is_lowercase_hex_record(release_selector, bytes_read)
        || !copy_path(selected_core, releases_root)) {
        return FALSE;
    }
    destination = wide_length(selected_core);
    if (!append_text(selected_core, &destination, release_separator)
        || destination + 64u + 1u > TEXT_CAPACITY) {
        return FALSE;
    }
    for (index = 0u; index < 64u; ++index) {
        selected_core[destination++] = (WCHAR)release_selector[index];
    }
    selected_core[destination] = L'\0';
    if (!is_directory(selected_core)
        || !append_text(selected_core, &destination, core_suffix)) {
        return FALSE;
    }
    return is_file(selected_core);
}

BOOL layout_is_manager_entry(void)
{
    return manager_entry;
}

const WCHAR *layout_bootstrap_path(void)
{
    return bootstrap;
}

const WCHAR *layout_core_path(void)
{
    return selected_core;
}

const WCHAR *layout_entry_id(void)
{
    return identity;
}
