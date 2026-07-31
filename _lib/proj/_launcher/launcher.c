#define WIN32_LEAN_AND_MEAN
#define UNICODE
#define _UNICODE
#include <windows.h>

void WINAPI launcher_entry(void)
{
    int result = MessageBoxW(
        NULL,
        L"Hello, world!",
        L"Swaw Kit Proj Launcher",
        MB_OK | MB_ICONINFORMATION
    );

    ExitProcess(result == 0 ? 1u : 0u);
}
