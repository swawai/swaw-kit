[CmdletBinding()]
param([Parameter(Mandatory = $true)][string]$DevPath)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version 2.0

function Assert-ProjNativeSetup {
    param(
        [Parameter(Mandatory = $true)][bool]$Condition,
        [Parameter(Mandatory = $true)][string]$Message
    )
    if (-not $Condition) {
        throw "Proj native setup test failed: $Message"
    }
}

function Invoke-ProjNativeSetup {
    param(
        [Parameter(Mandatory = $true)][string]$Executable,
        [Parameter(Mandatory = $true)][hashtable]$Environment,
        [string[]]$Arguments = @()
    )
    $Info = [Diagnostics.ProcessStartInfo]::new()
    $Info.FileName = $Executable
    $Info.Arguments = [string]::Join(' ', @('command-v1', '.dev/setup') + $Arguments)
    $Info.UseShellExecute = $false
    $Info.CreateNoWindow = $true
    $Info.RedirectStandardOutput = $true
    $Info.RedirectStandardError = $true
    # Windows PowerShell 5.1 initializes this dictionary lazily.
    $null = $Info.EnvironmentVariables
    foreach ($Pair in $Environment.GetEnumerator()) {
        $Info.EnvironmentVariables[[string]$Pair.Key] = [string]$Pair.Value
    }
    $Process = [Diagnostics.Process]::Start($Info)
    try {
        $OutputTask = $Process.StandardOutput.ReadToEndAsync()
        $ErrorOutputTask = $Process.StandardError.ReadToEndAsync()
        if (-not $Process.WaitForExit(30000)) {
            $Process.Kill()
            $Process.WaitForExit()
            throw 'native setup handler timed out'
        }
        $Output = $OutputTask.GetAwaiter().GetResult()
        $ErrorOutput = $ErrorOutputTask.GetAwaiter().GetResult()
        return [pscustomobject]@{
            ExitCode = [int]$Process.ExitCode
            Output = ($Output + $ErrorOutput).TrimEnd()
        }
    } finally {
        $Process.Dispose()
    }
}

$RepoRoot = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..\..\..'))
$Executable = [IO.Path]::GetFullPath($DevPath)
$TemporaryRoot = Join-Path $RepoRoot (
    "data\_test\swawkit-native-setup-$([Guid]::NewGuid().ToString('N'))"
)
try {
    $DataRoot = Join-Path $TemporaryRoot 'data root'
    [void][IO.Directory]::CreateDirectory($DataRoot)
    $SetupRoot = Join-Path $DataRoot 'modules\system\dev\setup'
    [void][IO.Directory]::CreateDirectory($SetupRoot)
    [IO.File]::WriteAllText(
        (Join-Path $SetupRoot '_settings.json'),
        (@{
            schema = 'swawkit.proj-dev-settings/v1'
            bun = @{ mode = 'disabled'; version = ''; sha256 = '' }
            pwsh = @{ mode = 'disabled'; version = ''; sha256 = '' }
            msvc = @{ mode = 'disabled'; channel = '' }
            rust = @{
                mode = 'disabled'
                toolchain = ''
                profile = 'minimal'
                host = 'x86_64-pc-windows-msvc'
            }
        } | ConvertTo-Json -Depth 4),
        [Text.UTF8Encoding]::new($false)
    )
    $Environment = @{
        SWAWKIT_PROJ_CORE_COMMAND_PROTOCOL = '3'
        SWAWKIT_PROJ_CORE_COMMAND_ADDRESS = '.dev/setup'
        SWAWKIT_PROJ_DATA_ROOT = $DataRoot
        SWAWKIT_HOME = $RepoRoot
        SWAWKIT_PROJ_MODULE_ROOTS = (@{
            project = Join-Path $RepoRoot '.swaw'
        } | ConvertTo-Json -Compress)
        SWAWKIT_PROJ_ENTRY_COMMAND = 'fixture'
    }
    $Legacy = Join-Path $DataRoot (
        'modules\system\dev\setup\export\_state.json'
    )
    [void][IO.Directory]::CreateDirectory((Split-Path $Legacy -Parent))
    [IO.File]::WriteAllText($Legacy, '{"legacy":true}')

    $Ready = Invoke-ProjNativeSetup `
        -Executable $Executable `
        -Environment $Environment
    $StatePath = Join-Path $SetupRoot '_state.json'
    Assert-ProjNativeSetup `
        -Condition ($Ready.ExitCode -eq 0 -and [IO.File]::Exists($StatePath)) `
        -Message "the native handler published no provider state: $($Ready.Output)"
    $State = Get-Content -LiteralPath $StatePath `
        -Raw | ConvertFrom-Json
    $EnvironmentExport = Get-Content `
        -LiteralPath (Join-Path $SetupRoot 'export\environment.json') `
        -Raw | ConvertFrom-Json
    Assert-ProjNativeSetup `
        -Condition ($Ready.ExitCode -eq 0 -and
            $Ready.Output.Contains(
                '[OK] The base development environment is ready.'
            ) -and
            $State.status -ceq 'ready' -and
            @($State.exports).Count -eq 1 -and
            [string]$State.exports[0].id -ceq 'environment' -and
            [string]$State.exports[0].contract -ceq
                'swawkit.proj.dev-setup/v4' -and
            $EnvironmentExport.schema -ceq
                'swawkit.proj-dev-environment/v1' -and
            $EnvironmentExport.inputRevision -ceq $State.inputRevision -and
            $EnvironmentExport.publicationToken -ceq $State.token -and
            [IO.File]::Exists((Join-Path $SetupRoot 'export\env.cmd')) -and
            [IO.File]::Exists((Join-Path $SetupRoot 'export\env.ps1')) -and
            -not [IO.File]::Exists($Legacy)) `
        -Message "the native handler did not publish a ready provider: $($Ready.Output)"

    $Before = (
        Get-FileHash -LiteralPath (Join-Path $SetupRoot 'export\env.cmd') `
            -Algorithm SHA256
    ).Hash
    $Rejected = Invoke-ProjNativeSetup `
        -Executable $Executable `
        -Environment $Environment `
        -Arguments @('unexpected')
    $After = (
        Get-FileHash -LiteralPath (Join-Path $SetupRoot 'export\env.cmd') `
            -Algorithm SHA256
    ).Hash
    Assert-ProjNativeSetup `
        -Condition ($Rejected.ExitCode -ne 0 -and
            $Rejected.Output.Contains(
                '.dev/setup does not accept dynamic arguments'
            ) -and $Before -ceq $After) `
        -Message 'argument rejection changed the published environment'
} finally {
    if ([IO.Directory]::Exists($TemporaryRoot)) {
        [IO.Directory]::Delete($TemporaryRoot, $true)
    }
}

Write-Host '[PASS] Proj native .dev/setup handler' -ForegroundColor Green
$global:LASTEXITCODE = 0
