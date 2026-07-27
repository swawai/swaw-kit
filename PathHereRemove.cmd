<# :
@echo off
chcp 65001 >nul
if not "%~1"=="" (
    echo [ERROR] PathHereRemove.cmd does not accept arguments.
    exit /b 64
)
setlocal DisableDelayedExpansion
set "SWAW_KIT_SELF=%~f0"
powershell -NoProfile -ExecutionPolicy Bypass -Command "& { & ([scriptblock]::Create([IO.File]::ReadAllText($env:SWAW_KIT_SELF))) }"
exit /b %ERRORLEVEL%
#>$ErrorActionPreference = 'Stop'
[Console]::OutputEncoding = New-Object System.Text.UTF8Encoding $false

$ScriptFile = $env:SWAW_KIT_SELF
$ScriptDir = Split-Path -Parent $ScriptFile
$DataDir = Join-Path $ScriptDir 'data'
$BackupFile = Join-Path $DataDir 'PathHere.backup.log'

function Trim-PathTail {
    param([Parameter(Mandatory = $true)][string]$Path)

    $Trimmed = $Path.Trim().Trim('"').TrimEnd('\', '/')
    if ($Trimmed -match '^[A-Za-z]:$') {
        return "$Trimmed\"
    }
    return $Trimmed
}

function Get-PathKey {
    param([Parameter(Mandatory = $true)][string]$Path)

    $Expanded = [Environment]::ExpandEnvironmentVariables($Path.Trim().Trim('"'))
    try {
        $FullPath = [IO.Path]::GetFullPath($Expanded)
    }
    catch {
        $FullPath = $Expanded
    }

    return (Trim-PathTail $FullPath).ToLowerInvariant()
}

function Get-UserPathEntries {
    param([string]$PathValue)

    if ([string]::IsNullOrWhiteSpace($PathValue)) {
        return @()
    }

    return @($PathValue -split ';')
}

function Get-UserPathRecord {
    $Key = [Microsoft.Win32.Registry]::CurrentUser.OpenSubKey('Environment', $false)
    $ValueName = 'Path'
    $Value = ''
    $Kind = [Microsoft.Win32.RegistryValueKind]::ExpandString

    if ($null -ne $Key) {
        try {
            $ExistingName = @($Key.GetValueNames() | Where-Object { $_ -ieq 'Path' } | Select-Object -First 1)
            if ($ExistingName.Count -gt 0) {
                $ValueName = [string]$ExistingName[0]
                $RawValue = $Key.GetValue($ValueName, '', [Microsoft.Win32.RegistryValueOptions]::DoNotExpandEnvironmentNames)
                if ($null -ne $RawValue) {
                    $Value = [string]$RawValue
                }
                $Kind = $Key.GetValueKind($ValueName)
            }
        }
        finally {
            $Key.Close()
        }
    }

    if ($Kind -ne [Microsoft.Win32.RegistryValueKind]::String -and $Kind -ne [Microsoft.Win32.RegistryValueKind]::ExpandString) {
        $Kind = [Microsoft.Win32.RegistryValueKind]::ExpandString
    }

    return [pscustomobject]@{
        Name = $ValueName
        Value = $Value
        Kind = $Kind
    }
}

function Set-UserPathRecord {
    param(
        [Parameter(Mandatory = $true)]$Record,
        [Parameter(Mandatory = $true)][string]$Value
    )

    $Key = [Microsoft.Win32.Registry]::CurrentUser.CreateSubKey('Environment')
    try {
        $Key.SetValue($Record.Name, $Value, $Record.Kind)
    }
    finally {
        $Key.Close()
    }
}

function Send-EnvironmentChanged {
    $TypeName = 'SwawKit.NativeMethods'
    if (-not ($TypeName -as [type])) {
        Add-Type -Namespace SwawKit -Name NativeMethods -MemberDefinition @'
[System.Runtime.InteropServices.DllImport("user32.dll", SetLastError=true, CharSet=System.Runtime.InteropServices.CharSet.Auto)]
public static extern System.IntPtr SendMessageTimeout(
    System.IntPtr hWnd,
    uint Msg,
    System.UIntPtr wParam,
    string lParam,
    uint fuFlags,
    uint uTimeout,
    out System.UIntPtr lpdwResult);
'@
    }

    $Result = [UIntPtr]::Zero
    [void][SwawKit.NativeMethods]::SendMessageTimeout(
        [IntPtr]0xffff,
        0x001A,
        [UIntPtr]::Zero,
        'Environment',
        0x0002,
        1000,
        [ref]$Result
    )
}

$TargetPath = Trim-PathTail ([IO.Path]::GetFullPath($ScriptDir))
$TargetKey = Get-PathKey $TargetPath
$PathRecord = Get-UserPathRecord
$CurrentUserPath = $PathRecord.Value
if ([string]::IsNullOrWhiteSpace($CurrentUserPath)) {
    Write-Host "[SKIP] Current user PATH is empty." -ForegroundColor Yellow
    exit 0
}

$Entries = Get-UserPathEntries $CurrentUserPath
$Remaining = @()
$RemovedCount = 0

foreach ($Entry in $Entries) {
    if (-not [string]::IsNullOrWhiteSpace($Entry) -and (Get-PathKey $Entry) -eq $TargetKey) {
        $RemovedCount++
        continue
    }
    $Remaining += $Entry
}

Write-Host "Remove this path from your user PATH"
Write-Host $TargetPath
Write-Host

if ($RemovedCount -eq 0) {
    Write-Host "[SKIP] Target path was not found in current user PATH." -ForegroundColor Yellow
    exit 0
}

$Stamp = Get-Date -Format 'yyyy-MM-dd HH:mm:ss zzz'
[IO.Directory]::CreateDirectory($DataDir) | Out-Null
Add-Content -LiteralPath $BackupFile -Encoding UTF8 -Value "USER-PATH_PRE-DEL [$Stamp] $CurrentUserPath"

$NewUserPath = [string]::Join(';', $Remaining)
Set-UserPathRecord -Record $PathRecord -Value $NewUserPath
Send-EnvironmentChanged

Write-Host "[OK] Removed $RemovedCount matching entries from current user PATH." -ForegroundColor Green
Write-Host "Backup: $BackupFile"
Write-Host "Tip: Reopen terminals or Win+R before relying on the updated PATH."

