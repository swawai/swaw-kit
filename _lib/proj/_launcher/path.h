#ifndef SWAWKIT_PROJ_LAUNCHER_PATH_H
#define SWAWKIT_PROJ_LAUNCHER_PATH_H

#define WIN32_LEAN_AND_MEAN
#include <windows.h>

#define PROJ_PATH_CAPACITY 32768u

BOOL copy_extended_absolute_path(
    const WCHAR *source,
    WCHAR *destination,
    DWORD capacity
);
BOOL copy_dos_absolute_path(
    const WCHAR *source,
    WCHAR *destination,
    DWORD capacity
);
BOOL is_extended_absolute_path(const WCHAR *path);

#endif
