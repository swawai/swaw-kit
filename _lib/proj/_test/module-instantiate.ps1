[CmdletBinding()]
param([Parameter(Mandatory = $true)][string]$ModulePath)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version 2.0

function Assert-ProjModuleInstantiate {
    param(
        [Parameter(Mandatory = $true)][bool]$Condition,
        [Parameter(Mandatory = $true)][string]$Message
    )
    if (-not $Condition) {
        throw "Module instantiate test failed: $Message"
    }
}

function Invoke-ProjModuleManager {
    param(
        [Parameter(Mandatory = $true)][string]$Executable,
        [Parameter(Mandatory = $true)][string]$Address,
        [Parameter(Mandatory = $true)][string]$ArgumentText,
        [Parameter(Mandatory = $true)][string]$RepoRoot,
        [Parameter(Mandatory = $true)][string]$DataRoot,
        [Parameter(Mandatory = $true)][string]$PoisonRoot
    )

    $Info = [Diagnostics.ProcessStartInfo]::new()
    $Info.FileName = $Executable
    $Info.Arguments = "command-v1 $Address $ArgumentText"
    $Info.UseShellExecute = $false
    $Info.CreateNoWindow = $true
    $Info.RedirectStandardOutput = $true
    $Info.RedirectStandardError = $true
    $null = $Info.EnvironmentVariables
    $Environment = @{
        SWAWKIT_PROJ_CORE_COMMAND_PROTOCOL = '3'
        SWAWKIT_PROJ_CORE_COMMAND_ADDRESS = $Address
        SWAWKIT_PROJ_DATA_ROOT = $DataRoot
        SWAWKIT_HOME = $RepoRoot
        SWAWKIT_PROJ_SYSTEM_ROOT = Join-Path $RepoRoot '_lib\proj\system'
        SWAWKIT_PROJ_MODULE_ROOTS = '{}'
        SWAWKIT_PROJ_ENTRY_COMMAND = 'fixture'
        RUSTC = Join-Path $PoisonRoot 'rustc.exe'
        CARGO_BUILD_RUSTC = Join-Path $PoisonRoot 'rustc.exe'
        CARGO_HOME = Join-Path $PoisonRoot 'cargo'
        RUSTUP_HOME = Join-Path $PoisonRoot 'rustup'
        INCLUDE = Join-Path $PoisonRoot 'include'
        LIB = Join-Path $PoisonRoot 'lib'
        PATH = Join-Path $env:SystemRoot 'System32'
    }
    foreach ($Pair in $Environment.GetEnumerator()) {
        $Info.EnvironmentVariables[[string]$Pair.Key] = [string]$Pair.Value
    }

    $Process = [Diagnostics.Process]::Start($Info)
    try {
        $OutputTask = $Process.StandardOutput.ReadToEndAsync()
        $ErrorTask = $Process.StandardError.ReadToEndAsync()
        if (-not $Process.WaitForExit(900000)) {
            $Process.Kill()
            $Process.WaitForExit()
            throw "Module manager timed out: $Address"
        }
        return [pscustomobject]@{
            ExitCode = [int]$Process.ExitCode
            Stdout = $OutputTask.GetAwaiter().GetResult().Trim()
            Stderr = $ErrorTask.GetAwaiter().GetResult().Trim()
        }
    } finally {
        $Process.Dispose()
    }
}

$RepoRoot = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..\..\..'))
$Executable = [IO.Path]::GetFullPath($ModulePath)
$TemporaryRoot = Join-Path $RepoRoot (
    'data\_test\module-instantiate-' + [Guid]::NewGuid().ToString('N')
)
$ExpectedTestRoot = [IO.Path]::GetFullPath((Join-Path $RepoRoot 'data\_test'))
$ResolvedTemporaryRoot = [IO.Path]::GetFullPath($TemporaryRoot)
if (-not $ResolvedTemporaryRoot.StartsWith(
    $ExpectedTestRoot + [IO.Path]::DirectorySeparatorChar,
    [StringComparison]::OrdinalIgnoreCase
)) {
    throw "Unsafe Module instantiate fixture path: $ResolvedTemporaryRoot"
}

try {
    $DataRoot = Join-Path $ResolvedTemporaryRoot 'data-root'
    $PoisonRoot = Join-Path $ResolvedTemporaryRoot 'not-a-toolchain'
    [void][IO.Directory]::CreateDirectory($DataRoot)

    $Instantiate = Invoke-ProjModuleManager `
        -Executable $Executable `
        -Address '.module/instantiate' `
        -ArgumentText '.context' `
        -RepoRoot $RepoRoot `
        -DataRoot $DataRoot `
        -PoisonRoot $PoisonRoot
    Assert-ProjModuleInstantiate `
        -Condition ($Instantiate.ExitCode -eq 0) `
        -Message (
            "instantiate failed without .dev/setup:`n" +
            $Instantiate.Stdout + "`n" + $Instantiate.Stderr
        )
    Assert-ProjModuleInstantiate `
        -Condition (-not [IO.Directory]::Exists((Join-Path $DataRoot (
            'modules\system\dev'
        )))) `
        -Message 'instantiate created or consumed a .dev publication'

    $Status = Invoke-ProjModuleManager `
        -Executable $Executable `
        -Address '.module/status' `
        -ArgumentText '.context --json' `
        -RepoRoot $RepoRoot `
        -DataRoot $DataRoot `
        -PoisonRoot $PoisonRoot
    Assert-ProjModuleInstantiate `
        -Condition ($Status.ExitCode -eq 0) `
        -Message "status failed after instantiate: $($Status.Stderr)"
    $Document = $Status.Stdout | ConvertFrom-Json
    Assert-ProjModuleInstantiate `
        -Condition (
            $Document.protocol -ceq 'swawkit.module-status/v1' -and
            $Document.address -ceq '.context' -and
            $Document.owner -ceq '.context' -and
            $Document.state -ceq 'current' -and
            [string]$Document.releaseId -cmatch '^[a-f0-9]{64}$'
        ) `
        -Message 'status did not report the independently built Release as current'
} finally {
    if ([IO.Directory]::Exists($ResolvedTemporaryRoot)) {
        Remove-Item -LiteralPath $ResolvedTemporaryRoot -Recurse -Force
    }
}

Write-Host '[PASS] Proj Module instantiate uses the Bootstrap builder' `
    -ForegroundColor Green
$global:LASTEXITCODE = 0
