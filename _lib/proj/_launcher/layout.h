#ifndef SWAWKIT_PROJ_LAUNCHER_LAYOUT_H
#define SWAWKIT_PROJ_LAUNCHER_LAYOUT_H

#define WIN32_LEAN_AND_MEAN
#include <windows.h>

#define ENTRY_ID_MISSING 0u
#define ENTRY_ID_VALID 1u
#define ENTRY_ID_INVALID 2u

BOOL locate_entry_layout(const WCHAR *entry_path);
DWORD read_layout_entry_id(void);
BOOL resolve_layout_current_core(void);
BOOL layout_is_manager_entry(void);
const WCHAR *layout_bootstrap_path(void);
const WCHAR *layout_core_path(void);
const WCHAR *layout_entry_id(void);

#endif
