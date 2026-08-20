[CmdletBinding()]
param([string]$LauncherPath = '')

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version 2.0

function Assert-LauncherLongPath {
    param(
        [Parameter(Mandatory = $true)][bool]$Condition,
        [Parameter(Mandatory = $true)][string]$Message
    )
    if (-not $Condition) {
        throw "Launcher long-path assertion failed: $Message"
    }
}

function Invoke-LongPathLauncher {
    param(
        [Parameter(Mandatory = $true)][string]$Executable,
        [Parameter(Mandatory = $true)][string]$Arguments,
        [Parameter(Mandatory = $true)][string]$WorkingDirectory
    )

    $StartInfo = [Diagnostics.ProcessStartInfo]::new()
    $StartInfo.FileName = $Executable
    $StartInfo.Arguments = $Arguments
    $StartInfo.WorkingDirectory = $WorkingDirectory
    $StartInfo.UseShellExecute = $false
    $StartInfo.CreateNoWindow = $true
    $StartInfo.RedirectStandardOutput = $true
    $StartInfo.RedirectStandardError = $true
    $StartInfo.StandardOutputEncoding = [Text.UTF8Encoding]::new($false)
    $StartInfo.StandardErrorEncoding = [Text.UTF8Encoding]::new($false)
    $Process = [Diagnostics.Process]::new()
    try {
        $Process.StartInfo = $StartInfo
        if (-not $Process.Start()) {
            throw "Launcher process did not start: $Executable"
        }
        $StandardOutput = $Process.StandardOutput.ReadToEnd()
        $StandardError = $Process.StandardError.ReadToEnd()
        $Process.WaitForExit()
        return [pscustomobject][ordered]@{
            ExitCode = [int]$Process.ExitCode
            StandardOutput = $StandardOutput
            StandardError = $StandardError
        }
    } finally {
        $Process.Dispose()
    }
}

if ($null -eq ('ProjLauncherLongPathNative' -as [type])) {
    Add-Type -TypeDefinition @'
using System;
using System.ComponentModel;
using System.Runtime.InteropServices;
using System.Text;

public static class ProjLauncherLongPathNative
{
    [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
    private struct StartupInfo
    {
        public uint cb;
        public string reserved;
        public string desktop;
        public string title;
        public uint x;
        public uint y;
        public uint xSize;
        public uint ySize;
        public uint xCountChars;
        public uint yCountChars;
        public uint fillAttribute;
        public uint flags;
        public ushort showWindow;
        public ushort reserved2;
        public IntPtr reservedBytes;
        public IntPtr standardInput;
        public IntPtr standardOutput;
        public IntPtr standardError;
    }

    [StructLayout(LayoutKind.Sequential)]
    private struct ProcessInformation
    {
        public IntPtr process;
        public IntPtr thread;
        public uint processId;
        public uint threadId;
    }

    [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
    private static extern bool CreateProcess(
        string application,
        StringBuilder commandLine,
        IntPtr processAttributes,
        IntPtr threadAttributes,
        bool inheritHandles,
        uint creationFlags,
        IntPtr environment,
        string currentDirectory,
        ref StartupInfo startupInfo,
        out ProcessInformation processInformation
    );

    [DllImport("kernel32.dll", SetLastError = true)]
    private static extern uint WaitForSingleObject(IntPtr handle, uint milliseconds);

    [DllImport("kernel32.dll", SetLastError = true)]
    private static extern bool GetExitCodeProcess(IntPtr process, out uint exitCode);

    [DllImport("kernel32.dll")]
    private static extern bool CloseHandle(IntPtr handle);

    public static int Run(string application, string arguments, string currentDirectory)
    {
        StartupInfo startup = new StartupInfo();
        startup.cb = (uint)Marshal.SizeOf(typeof(StartupInfo));
        ProcessInformation process;
        StringBuilder commandLine = new StringBuilder(
            "\"" + application + "\" " + arguments
        );
        if (!CreateProcess(
            application,
            commandLine,
            IntPtr.Zero,
            IntPtr.Zero,
            true,
            0,
            IntPtr.Zero,
            currentDirectory,
            ref startup,
            out process
        )) {
            throw new Win32Exception(Marshal.GetLastWin32Error());
        }
        try {
            if (WaitForSingleObject(process.process, UInt32.MaxValue) != 0) {
                throw new Win32Exception(Marshal.GetLastWin32Error());
            }
            uint exitCode;
            if (!GetExitCodeProcess(process.process, out exitCode)) {
                throw new Win32Exception(Marshal.GetLastWin32Error());
            }
            return unchecked((int)exitCode);
        } finally {
            CloseHandle(process.thread);
            CloseHandle(process.process);
        }
    }
}
'@
}

function Write-LongPathHexRecord {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][string]$Value
    )

    [void][IO.Directory]::CreateDirectory((Split-Path -Path $Path -Parent))
    [IO.File]::WriteAllText(
        $Path,
        ($Value + "`n"),
        [Text.UTF8Encoding]::new($false)
    )
}

function New-LauncherLongHome {
    param(
        [Parameter(Mandatory = $true)][string]$Root,
        [Parameter(Mandatory = $true)][string]$Prefix,
        [int]$Length = 240
    )

    $Base = Join-Path $Root $Prefix
    if ($Base.Length -ge $Length) {
        throw "Long-path fixture root is unexpectedly long: $Base"
    }
    return $Base + ('x' * ($Length - $Base.Length))
}

function Add-LongEntryRuntime {
    param(
        [Parameter(Mandatory = $true)][string]$EntryHome,
        [Parameter(Mandatory = $true)][string]$Name,
        [Parameter(Mandatory = $true)][string]$ReleaseId
    )

    $DataRoot = Join-Path $EntryHome "data\proj.$Name"
    $RuntimeRoot = Join-Path $DataRoot 'runtime'
    $ReleaseRoot = Join-Path $RuntimeRoot "releases\$ReleaseId"
    [void][IO.Directory]::CreateDirectory($ReleaseRoot)
    Write-LongPathHexRecord `
        -Path (Join-Path $RuntimeRoot 'current') `
        -Value $ReleaseId
    [IO.File]::Copy(
        (Join-Path ([Environment]::SystemDirectory) 'cmd.exe'),
        (Join-Path $ReleaseRoot 'swawkit-proj.exe'),
        $false
    )
    return [pscustomobject][ordered]@{
        DataRoot = $DataRoot
        RuntimeRoot = $RuntimeRoot
        ReleaseRoot = $ReleaseRoot
    }
}

$RepoRoot = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..\..\..'))
if ([string]::IsNullOrWhiteSpace($LauncherPath)) {
    . (Join-Path $RepoRoot '_lib\proj\_bootstrap\layout.ps1')
    $Layout = Get-ProjBootstrapLayout
    $LauncherPath = $Layout.LauncherCandidatePath
}
$LauncherPath = [IO.Path]::GetFullPath($LauncherPath)
if (-not [IO.File]::Exists($LauncherPath)) {
    throw "Launcher candidate does not exist: $LauncherPath"
}

$TemporaryRoot = Join-Path $RepoRoot (
    "data\_test\swawkit-proj-launcher-long-$([Guid]::NewGuid().ToString('N'))"
)
$Invocation = Join-Path $TemporaryRoot 'invocation'
$Command = '/d /s /c "set SWAWKIT_PROJ_CORE_LAUNCH & echo CORE=%CMDCMDLINE% & exit /b 37"'

try {
    [void][IO.Directory]::CreateDirectory($Invocation)
    $EntryHome = New-LauncherLongHome -Root $TemporaryRoot -Prefix 'entry-'
    [void][IO.Directory]::CreateDirectory($EntryHome)
    $ReleaseId = '1' * 64
    $Runtime = Add-LongEntryRuntime `
        -EntryHome $EntryHome `
        -Name 'long' `
        -ReleaseId $ReleaseId
    $Entry = Join-Path $EntryHome 'long.exe'
    [IO.File]::Copy($LauncherPath, $Entry, $false)
    $SelectorPath = Join-Path $Runtime.RuntimeRoot 'current'
    $CorePath = Join-Path $Runtime.ReleaseRoot 'swawkit-proj.exe'
    Assert-LauncherLongPath `
        -Condition (
            $Entry.Length -lt 260 -and
            $SelectorPath.Length -gt 260 -and
            $CorePath.Length -gt 260
        ) `
        -Message 'ordinary Entry fixture did not cross MAX_PATH'
    $Run = Invoke-LongPathLauncher `
        -Executable $Entry `
        -Arguments $Command `
        -WorkingDirectory $Invocation
    Assert-LauncherLongPath `
        -Condition (
            $Run.ExitCode -eq 37 -and
            $Run.StandardOutput.Contains(
                "SWAWKIT_PROJ_CORE_LAUNCH_ENTRY_FILE=$Entry"
            ) -and
            -not $Run.StandardOutput.Contains('ENTRY_FILE=\\?\') -and
            -not $Run.StandardOutput.Contains('CORE_LAUNCH_ENTRY_ID') -and
            $Run.StandardOutput.Contains($ReleaseId)
        ) `
        -Message (
            "ordinary >260 Runtime failed (exit $($Run.ExitCode)): " +
            "$($Run.StandardOutput) $($Run.StandardError)"
        )

    $DeepHome = New-LauncherLongHome `
        -Root $TemporaryRoot `
        -Prefix 'deep-' `
        -Length 280
    [void][IO.Directory]::CreateDirectory($DeepHome)
    [void](Add-LongEntryRuntime `
        -EntryHome $DeepHome `
        -Name 'deep' `
        -ReleaseId ('3' * 64))
    $DeepEntry = Join-Path $DeepHome 'deep.exe'
    [IO.File]::Copy($LauncherPath, $DeepEntry, $false)
    $DeepOutput = Join-Path $TemporaryRoot 'deep-entry-env.txt'
    $DeepCommand = Join-Path $TemporaryRoot 'deep-entry.cmd'
    [IO.File]::WriteAllText(
        $DeepCommand,
        (
            "@echo off`r`n" +
            "set SWAWKIT_PROJ_CORE_LAUNCH > $DeepOutput`r`n" +
            "exit /b 43`r`n"
        ),
        [Text.Encoding]::ASCII
    )
    $DeepArguments = "/d /c `"$DeepCommand`""
    $ExtendedDeepEntry = "\\?\$DeepEntry"
    $DeepExitCode = [ProjLauncherLongPathNative]::Run(
        $ExtendedDeepEntry,
        $DeepArguments,
        $Invocation
    )
    $DeepEnvironment = [IO.File]::ReadAllText(
        $DeepOutput,
        [Text.Encoding]::Default
    )
    Assert-LauncherLongPath `
        -Condition (
            $DeepEntry.Length -gt 260 -and
            $DeepExitCode -eq 43 -and
            $DeepEnvironment.Contains(
                "SWAWKIT_PROJ_CORE_LAUNCH_ENTRY_FILE=$DeepEntry"
            ) -and
            -not $DeepEnvironment.Contains('ENTRY_FILE=\\?\') -and
            -not $DeepEnvironment.Contains('CORE_LAUNCH_ENTRY_ID')
        ) `
        -Message (
            "GetModuleFileName did not preserve a >260 Entry identity " +
            "(entryLength=$($DeepEntry.Length), exit=$DeepExitCode): " +
            $DeepEnvironment
        )

    $ManagerHome = New-LauncherLongHome -Root $TemporaryRoot -Prefix 'manager-'
    $ManagerEntry = Join-Path $ManagerHome 'swawkit.exe'
    $ManagerBootstrap = Join-Path $ManagerHome '_lib\proj\bootstrap.ps1'
    $ManagerMarker = Join-Path $ManagerHome 'bootstrap-ran.txt'
    [void][IO.Directory]::CreateDirectory((Split-Path $ManagerBootstrap -Parent))
    [IO.File]::Copy($LauncherPath, $ManagerEntry, $false)
    $ManagerFixture = @"
`$ErrorActionPreference = 'Stop'
`$ManagerRoot = [IO.Path]::GetFullPath((Join-Path `$PSScriptRoot '..\..'))
`$DataRoot = Join-Path `$ManagerRoot 'data\proj.swawkit'
`$RuntimeRoot = Join-Path `$DataRoot 'runtime'
`$ReleaseId = '2' * 64
`$ReleaseRoot = Join-Path `$RuntimeRoot "releases\`$ReleaseId"
[void][IO.Directory]::CreateDirectory(`$ReleaseRoot)
[IO.File]::WriteAllText((Join-Path `$RuntimeRoot 'current'), (`$ReleaseId + [char]10), [Text.UTF8Encoding]::new(`$false))
[IO.File]::Copy((Join-Path ([Environment]::SystemDirectory) 'cmd.exe'), (Join-Path `$ReleaseRoot 'swawkit-proj.exe'), `$false)
[IO.File]::WriteAllText('$($ManagerMarker.Replace("'", "''"))', 'ran')
"@
    [IO.File]::WriteAllText(
        $ManagerBootstrap,
        $ManagerFixture,
        [Text.UTF8Encoding]::new($false)
    )
    Assert-LauncherLongPath `
        -Condition ($ManagerBootstrap.Length -gt 260) `
        -Message 'manager Bootstrap fixture did not cross MAX_PATH'
    $ManagerRun = Invoke-LongPathLauncher `
        -Executable $ManagerEntry `
        -Arguments $Command `
        -WorkingDirectory $Invocation
    Assert-LauncherLongPath `
        -Condition (
            $ManagerRun.ExitCode -eq 37 -and
            [IO.File]::Exists($ManagerMarker)
        ) `
        -Message "manager >260 cold Bootstrap failed: $($ManagerRun.StandardError)"
} finally {
    if ([IO.Directory]::Exists($TemporaryRoot) -and
        $TemporaryRoot.StartsWith(
            (Join-Path $RepoRoot 'data\_test') + '\',
            [StringComparison]::OrdinalIgnoreCase
        )) {
        [IO.Directory]::Delete($TemporaryRoot, $true)
    }
}

Write-Host '[PASS] Proj native Launcher long paths' -ForegroundColor Green
$global:LASTEXITCODE = 0
