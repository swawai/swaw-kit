#define WIN32_LEAN_AND_MEAN
#define UNICODE
#define _UNICODE
#include <windows.h>

#include "layout.h"
#include "path.h"

#define TEXT_CAPACITY PROJ_PATH_CAPACITY
#define LAUNCH_PROTOCOL_VALUE L"5"

static const WCHAR launch_protocol_name[] =
    L"SWAWKIT_PROJ_CORE_LAUNCH_PROTOCOL";

static WCHAR raw_entry_path[TEXT_CAPACITY];
static WCHAR entry_path[TEXT_CAPACITY];
static WCHAR entry_protocol_path[TEXT_CAPACITY];
static WCHAR powershell_path[TEXT_CAPACITY];
static WCHAR bootstrap_argument_path[TEXT_CAPACITY];
static WCHAR child_command_line[TEXT_CAPACITY];
static STARTUPINFOW startup_info;
static PROCESS_INFORMATION process_info;

__declspec(noreturn) void __cdecl __report_rangecheckfailure(void)
{
    ExitProcess(1u);
}

static DWORD wide_length(const WCHAR *value)
{
    DWORD length = 0u;
    while (value[length] != L'\0') {
        ++length;
    }
    return length;
}

static DWORD narrow_length(const CHAR *value)
{
    DWORD length = 0u;
    while (value[length] != '\0') {
        ++length;
    }
    return length;
}

static void fail(BOOL host_mode, const WCHAR *dialog_text, const CHAR *console_text)
{
    HANDLE error_handle = GetStdHandle(STD_ERROR_HANDLE);
    DWORD written = 0u;
    BOOL reported = FALSE;

    if (!host_mode && error_handle != NULL && error_handle != INVALID_HANDLE_VALUE) {
        reported = WriteFile(
            error_handle,
            console_text,
            narrow_length(console_text),
            &written,
            NULL
        );
    }
    if (!reported) {
        MessageBoxW(
            NULL,
            dialog_text,
            L"Swaw Kit Proj Launcher",
            MB_OK | MB_ICONERROR
        );
    }
    ExitProcess(1u);
}

static BOOL environment_variable_exists(const WCHAR *name)
{
    WCHAR value;
    DWORD length;

    SetLastError(ERROR_SUCCESS);
    length = GetEnvironmentVariableW(name, &value, 1u);
    return length > 0u || GetLastError() != ERROR_ENVVAR_NOT_FOUND;
}

static BOOL prepare_startup_info(BOOL inherit_handles)
{
    startup_info.cb = sizeof(startup_info);
    startup_info.dwFlags = 0u;
    startup_info.hStdInput = NULL;
    startup_info.hStdOutput = NULL;
    startup_info.hStdError = NULL;
    if (!inherit_handles) {
        return TRUE;
    }
    startup_info.hStdInput = GetStdHandle(STD_INPUT_HANDLE);
    startup_info.hStdOutput = GetStdHandle(STD_OUTPUT_HANDLE);
    startup_info.hStdError = GetStdHandle(STD_ERROR_HANDLE);
    if (startup_info.hStdInput == NULL
        || startup_info.hStdInput == INVALID_HANDLE_VALUE
        || startup_info.hStdOutput == NULL
        || startup_info.hStdOutput == INVALID_HANDLE_VALUE
        || startup_info.hStdError == NULL
        || startup_info.hStdError == INVALID_HANDLE_VALUE) {
        return FALSE;
    }
    startup_info.dwFlags = STARTF_USESTDHANDLES;
    return TRUE;
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

static BOOL is_file(const WCHAR *path)
{
    DWORD attributes = GetFileAttributesW(path);
    return attributes != INVALID_FILE_ATTRIBUTES
        && (attributes & (FILE_ATTRIBUTE_DIRECTORY | FILE_ATTRIBUTE_REPARSE_POINT)) == 0u;
}

static BOOL locate_windows_powershell(void)
{
    static const WCHAR suffix[] =
        L"\\System32\\WindowsPowerShell\\v1.0\\powershell.exe";
    DWORD length = GetWindowsDirectoryW(powershell_path, TEXT_CAPACITY);

    return length > 0u
        && length < TEXT_CAPACITY
        && copy_path_with_suffix(powershell_path, length, suffix, powershell_path)
        && is_file(powershell_path);
}

static BOOL build_bootstrap_command_line(void)
{
    static const WCHAR options[] =
        L"\" -NoLogo -NoProfile -NonInteractive "
        L"-ExecutionPolicy Bypass -File \"";
    const WCHAR *bootstrap_path = bootstrap_argument_path;
    DWORD powershell_length = wide_length(powershell_path);
    DWORD options_length = wide_length(options);
    DWORD bootstrap_length = wide_length(bootstrap_path);
    DWORD index = 0u;
    DWORD source;

    if (powershell_length + options_length + bootstrap_length + 3u
        > TEXT_CAPACITY) {
        return FALSE;
    }
    child_command_line[index++] = L'\"';
    for (source = 0u; source < powershell_length; ++source) {
        child_command_line[index++] = powershell_path[source];
    }
    for (source = 0u; source < options_length; ++source) {
        child_command_line[index++] = options[source];
    }
    for (source = 0u; source < bootstrap_length; ++source) {
        child_command_line[index++] = bootstrap_path[source];
    }
    child_command_line[index++] = L'\"';
    child_command_line[index] = L'\0';
    return TRUE;
}

static BOOL run_bootstrap(BOOL host_mode)
{
    const WCHAR *bootstrap_path = layout_bootstrap_path();
    DWORD creation_flags = host_mode ? CREATE_NO_WINDOW : 0u;
    BOOL inherit_handles = host_mode ? FALSE : TRUE;
    DWORD wait_result;
    DWORD exit_code;

    if (!is_file(bootstrap_path)
        || !copy_dos_absolute_path(
            bootstrap_path,
            bootstrap_argument_path,
            TEXT_CAPACITY
        )
        || !locate_windows_powershell()
        || !build_bootstrap_command_line()
        || !prepare_startup_info(inherit_handles)
        || !CreateProcessW(
            powershell_path,
            child_command_line,
            NULL,
            NULL,
            inherit_handles,
            creation_flags,
            NULL,
            NULL,
            &startup_info,
            &process_info
        )) {
        return FALSE;
    }
    CloseHandle(process_info.hThread);
    wait_result = WaitForSingleObject(process_info.hProcess, INFINITE);
    if (wait_result != WAIT_OBJECT_0
        || !GetExitCodeProcess(process_info.hProcess, &exit_code)) {
        CloseHandle(process_info.hProcess);
        return FALSE;
    }
    CloseHandle(process_info.hProcess);
    return exit_code == 0u;
}

static const WCHAR *raw_argument_tail(void)
{
    const WCHAR *cursor = GetCommandLineW();
    BOOL quoted = FALSE;

    while (*cursor == L' ' || *cursor == L'\t') {
        ++cursor;
    }
    while (*cursor != L'\0') {
        if (*cursor == L'\"') {
            quoted = !quoted;
        } else if (!quoted && (*cursor == L' ' || *cursor == L'\t')) {
            break;
        }
        ++cursor;
    }
    while (*cursor == L' ' || *cursor == L'\t') {
        ++cursor;
    }
    return cursor;
}

static BOOL build_child_command_line(const WCHAR *argument_tail)
{
    const WCHAR *core_path = layout_core_path();
    DWORD core_length = wide_length(core_path);
    DWORD tail_length = wide_length(argument_tail);
    DWORD index = 0u;
    DWORD source;

    if (core_length + tail_length + 4u > TEXT_CAPACITY) {
        return FALSE;
    }
    child_command_line[index++] = L'\"';
    for (source = 0u; source < core_length; ++source) {
        child_command_line[index++] = core_path[source];
    }
    child_command_line[index++] = L'\"';
    if (tail_length > 0u) {
        child_command_line[index++] = L' ';
        for (source = 0u; source < tail_length; ++source) {
            child_command_line[index++] = argument_tail[source];
        }
    }
    child_command_line[index] = L'\0';
    return TRUE;
}

static BOOL prepare_environment(BOOL host_mode)
{
    return SetEnvironmentVariableW(launch_protocol_name, LAUNCH_PROTOCOL_VALUE)
        && SetEnvironmentVariableW(
            L"SWAWKIT_PROJ_CORE_LAUNCH_ENTRY_FILE",
            entry_protocol_path
        )
        && SetEnvironmentVariableW(
            L"SWAWKIT_PROJ_CORE_LAUNCH_ENTRY_ID",
            layout_entry_id()
        )
        && SetEnvironmentVariableW(
            L"SWAWKIT_PROJ_CORE_LAUNCH_MODE",
            host_mode ? L"internal-host" : L"cli"
        );
}

void WINAPI launcher_entry(void)
{
    const WCHAR *argument_tail = raw_argument_tail();
    const WCHAR *core_path;
    BOOL host_mode = *argument_tail == L'\0';
    DWORD entry_length = GetModuleFileNameW(NULL, raw_entry_path, TEXT_CAPACITY);
    DWORD entry_id_status;
    DWORD creation_flags;
    BOOL inherit_handles;
    DWORD wait_result;
    DWORD exit_code;

    if (environment_variable_exists(L"SWAWKIT_PROJ_CORE_COMMAND_PROTOCOL")) {
        fail(
            FALSE,
            L"Cannot start a Swaw Kit Entry from inside another Entry command.",
            "[ERROR] Cannot start a Swaw Kit Entry from inside another Entry command.\r\n"
        );
    }
    if (entry_length == 0u || entry_length >= TEXT_CAPACITY - 1u) {
        fail(
            host_mode,
            L"Cannot read the Launcher executable path.",
            "[ERROR] Cannot read the Launcher executable path.\r\n"
        );
    }
    if (!copy_extended_absolute_path(
            raw_entry_path,
            entry_path,
            TEXT_CAPACITY
        )
        || !copy_dos_absolute_path(
            raw_entry_path,
            entry_protocol_path,
            TEXT_CAPACITY
        )) {
        fail(
            host_mode,
            L"Cannot normalize the Launcher executable path.",
            "[ERROR] Cannot normalize the Launcher executable path.\r\n"
        );
    }
    if (!locate_entry_layout(entry_path)) {
        fail(
            host_mode,
            L"Cannot resolve the Entry Runtime layout. "
            L"Keep the Launcher directly in SWAWKIT_HOME.",
            "[ERROR] Cannot resolve the Entry Runtime layout. "
            "Keep the Launcher directly in SWAWKIT_HOME.\r\n"
        );
    }

    entry_id_status = read_layout_entry_id();
    if (entry_id_status == ENTRY_ID_INVALID) {
        fail(
            host_mode,
            L"The Entry identity is malformed or unsafe.",
            "[ERROR] The Entry identity is malformed or unsafe.\r\n"
        );
    }
    if (entry_id_status != ENTRY_ID_VALID || !resolve_layout_current_core()) {
        if (!layout_is_manager_entry()) {
            fail(
                host_mode,
                L"The Entry Runtime is missing or invalid. "
                L"Open swawkit.exe to create or repair this Entry.",
                "[ERROR] The Entry Runtime is missing or invalid. "
                "Open swawkit.exe to create or repair this Entry.\r\n"
            );
        }
        if (!run_bootstrap(host_mode)
            || read_layout_entry_id() != ENTRY_ID_VALID
            || !resolve_layout_current_core()) {
            fail(
                host_mode,
                L"Bootstrap could not prepare the manager Entry Runtime.",
                "[ERROR] Bootstrap could not prepare the manager Entry Runtime.\r\n"
            );
        }
    }
    if (!build_child_command_line(argument_tail)
        || !prepare_environment(host_mode)) {
        fail(
            host_mode,
            L"Cannot prepare the Entry Runtime Core launch.",
            "[ERROR] Cannot prepare the Entry Runtime Core launch.\r\n"
        );
    }

    if (host_mode) {
        FreeConsole();
    }
    core_path = layout_core_path();
    creation_flags = host_mode ? CREATE_NO_WINDOW : 0u;
    inherit_handles = host_mode ? FALSE : TRUE;
    if (!prepare_startup_info(inherit_handles)
        || !CreateProcessW(
            core_path,
            child_command_line,
            NULL,
            NULL,
            inherit_handles,
            creation_flags,
            NULL,
            NULL,
            &startup_info,
            &process_info
        )) {
        fail(
            host_mode,
            L"Cannot start the selected Entry Runtime Core.",
            "[ERROR] Cannot start the selected Entry Runtime Core.\r\n"
        );
    }

    CloseHandle(process_info.hThread);
    if (host_mode) {
        CloseHandle(process_info.hProcess);
        ExitProcess(0u);
    }
    wait_result = WaitForSingleObject(process_info.hProcess, INFINITE);
    if (wait_result != WAIT_OBJECT_0
        || !GetExitCodeProcess(process_info.hProcess, &exit_code)) {
        CloseHandle(process_info.hProcess);
        fail(
            FALSE,
            L"Cannot read the Entry Runtime Core result.",
            "[ERROR] Cannot read the Entry Runtime Core result.\r\n"
        );
    }
    CloseHandle(process_info.hProcess);
    ExitProcess(exit_code);
}
