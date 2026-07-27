if (-not ("SwawKit.EditorKit.NativeWindows" -as [type])) {
    Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
using System.Text;

namespace SwawKit.EditorKit {
    public static class NativeWindows {
        public delegate bool EnumWindowsProc(IntPtr hWnd, IntPtr lParam);

        [StructLayout(LayoutKind.Sequential)]
        public struct POINT {
            public int X;
            public int Y;
        }

        [StructLayout(LayoutKind.Sequential)]
        public struct RECT {
            public int Left;
            public int Top;
            public int Right;
            public int Bottom;
        }

        [StructLayout(LayoutKind.Sequential)]
        public struct WINDOWPLACEMENT {
            public int length;
            public int flags;
            public int showCmd;
            public POINT ptMinPosition;
            public POINT ptMaxPosition;
            public RECT rcNormalPosition;
        }

        [DllImport("user32.dll")]
        public static extern bool EnumWindows(EnumWindowsProc callback, IntPtr lParam);

        [DllImport("user32.dll")]
        public static extern bool IsWindowVisible(IntPtr hWnd);

        [DllImport("user32.dll")]
        public static extern uint GetWindowThreadProcessId(IntPtr hWnd, out uint processId);

        [DllImport("user32.dll", CharSet = CharSet.Unicode)]
        public static extern int GetClassName(IntPtr hWnd, StringBuilder className, int maxCount);

        [DllImport("user32.dll")]
        public static extern bool GetWindowPlacement(IntPtr hWnd, ref WINDOWPLACEMENT placement);

        [DllImport("user32.dll")]
        public static extern bool GetWindowRect(IntPtr hWnd, out RECT bounds);

        [DllImport("dwmapi.dll")]
        public static extern int DwmGetWindowAttribute(IntPtr hWnd, int attribute, out RECT value, int valueSize);

        [DllImport("user32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
        public static extern bool SetProp(IntPtr hWnd, string name, IntPtr value);

        [DllImport("user32.dll", CharSet = CharSet.Unicode)]
        public static extern IntPtr GetProp(IntPtr hWnd, string name);

        [DllImport("user32.dll", CharSet = CharSet.Unicode)]
        public static extern IntPtr RemoveProp(IntPtr hWnd, string name);
    }
}
'@
}

function Get-EditorProcessName {
    param([string]$Tool)

    if ($Tool -eq "code") {
        return "Code"
    }
    if ($Tool -eq "cursor") {
        return "Cursor"
    }
    throw "Unsupported editor tool: $Tool"
}

function Get-EditorKitWindows {
    param([string]$Tool)

    $processName = Get-EditorProcessName $Tool
    $processes = @{}
    Get-Process -Name $processName -ErrorAction SilentlyContinue | ForEach-Object {
        try {
            $processes[[int]$_.Id] = [pscustomobject]@{
                Pid = [int]$_.Id
                Started = $_.StartTime.ToUniversalTime().Ticks.ToString([Globalization.CultureInfo]::InvariantCulture)
            }
        } catch {
            # A process that exits while the snapshot is built is not a live window candidate.
        }
    }

    if ($processes.Count -eq 0) {
        return @()
    }

    $windows = [Collections.Generic.List[object]]::new()
    $callback = [SwawKit.EditorKit.NativeWindows+EnumWindowsProc]{
        param([IntPtr]$handle, [IntPtr]$unused)

        if (-not [SwawKit.EditorKit.NativeWindows]::IsWindowVisible($handle)) {
            return $true
        }

        [uint32]$ownerPid = 0
        [void][SwawKit.EditorKit.NativeWindows]::GetWindowThreadProcessId($handle, [ref]$ownerPid)
        $process = $processes[[int]$ownerPid]
        if (-not $process) {
            return $true
        }

        $className = [Text.StringBuilder]::new(256)
        [void][SwawKit.EditorKit.NativeWindows]::GetClassName($handle, $className, $className.Capacity)
        if (-not $className.ToString().StartsWith("Chrome_WidgetWin_", [StringComparison]::Ordinal)) {
            return $true
        }

        $placement = New-Object SwawKit.EditorKit.NativeWindows+WINDOWPLACEMENT
        $placement.length = [Runtime.InteropServices.Marshal]::SizeOf($placement)
        $hasPlacement = [SwawKit.EditorKit.NativeWindows]::GetWindowPlacement($handle, [ref]$placement)
        $normal = $placement.rcNormalPosition
        $frame = New-Object SwawKit.EditorKit.NativeWindows+RECT
        $frameSize = [Runtime.InteropServices.Marshal]::SizeOf($frame)
        $hasFrame = [SwawKit.EditorKit.NativeWindows]::DwmGetWindowAttribute($handle, 9, [ref]$frame, $frameSize) -eq 0
        if (-not $hasFrame) {
            $hasFrame = [SwawKit.EditorKit.NativeWindows]::GetWindowRect($handle, [ref]$frame)
        }

        $windows.Add([pscustomobject]@{
            Hwnd = $handle.ToInt64()
            Pid = $process.Pid
            Started = $process.Started
            HasPlacement = $hasPlacement
            Left = $normal.Left
            Top = $normal.Top
            Width = $normal.Right - $normal.Left
            Height = $normal.Bottom - $normal.Top
            HasFrame = $hasFrame
            FrameLeft = $frame.Left
            FrameTop = $frame.Top
            FrameWidth = $frame.Right - $frame.Left
            FrameHeight = $frame.Bottom - $frame.Top
        })
        return $true
    }

    [void][SwawKit.EditorKit.NativeWindows]::EnumWindows($callback, [IntPtr]::Zero)
    return @($windows)
}
