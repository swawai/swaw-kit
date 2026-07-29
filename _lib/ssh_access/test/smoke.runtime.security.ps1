[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version 2.0

. (Join-Path $PSScriptRoot 'support.ps1')
. (Join-Path $script:SshAccessTestKitRoot 'runtime\bootstrap.ps1')

$EnvironmentNames = @(
    'SSH_ACCESS_PROTOCOL',
    'SSH_ACCESS_ENTRY_COMMAND',
    'SSH_ACCESS_ENTRY_FILE',
    'SSH_ACCESS_PRIVATE_KEY_PATH',
    'SSH_ACCESS_USER',
    'SSH_ACCESS_KEY_TYPE',
    'SSH_ACCESS_KEY_COMMENT',
    'SystemRoot',
    'windir',
    'ComSpec',
    'PSModulePath'
)
$SavedEnvironment = Save-SshAccessTestEnvironment -Names $EnvironmentNames
$ScratchRoot = New-SshAccessTestScratchRoot

try {
    $PrivatePath = Join-Path $ScratchRoot 'identity\id_ed25519'
    Set-SshAccessTestValidEnvironment -PrivateKeyPath $PrivatePath
    $Context = New-SshAccessContext -KitRoot $script:SshAccessTestKitRoot

    $ExpectedWindowsRoot = [IO.Path]::GetFullPath(
        [Environment]::GetFolderPath([Environment+SpecialFolder]::Windows)
    )
    $ExpectedSystemDirectory = [IO.Path]::GetFullPath(
        [Environment]::SystemDirectory
    )
    $ExpectedCommandProcessor = [IO.Path]::GetFullPath(
        (Join-Path $ExpectedSystemDirectory 'cmd.exe')
    )
    $ExpectedModulePath = [IO.Path]::GetFullPath(
        (Join-Path $PSHOME 'Modules')
    )

    Write-Host '[TEST] Trusted process environment'
    $TrustedEnvironmentNames = @(
        'SystemRoot',
        'windir',
        'ComSpec',
        'PSModulePath'
    )
    $SavedTrustedEnvironment = Save-SshAccessTestEnvironment `
        -Names $TrustedEnvironmentNames
    try {
        $env:SystemRoot = Join-Path $ScratchRoot 'poison-system-root'
        $env:windir = Join-Path $ScratchRoot 'poison-windir'
        $env:ComSpec = Join-Path $ScratchRoot 'poison-cmd.exe'
        $env:PSModulePath = Join-Path $ScratchRoot 'poison-modules'
        $InitializedEnvironment = Initialize-SshAccessTrustedProcessEnvironment
        $ObservedTrustedEnvironment = [pscustomobject]@{
            SystemRoot = $env:SystemRoot
            WindowsRoot = $env:windir
            ComSpec = $env:ComSpec
            ModulePath = $env:PSModulePath
        }
    } finally {
        Restore-SshAccessTestEnvironment -Saved $SavedTrustedEnvironment
    }
    Assert-SshAccessTestEqual `
        $InitializedEnvironment.WindowsRoot `
        $ExpectedWindowsRoot `
        'The bootstrap should derive WindowsRoot from the trusted Windows API.'
    Assert-SshAccessTestEqual `
        $ObservedTrustedEnvironment.SystemRoot `
        $ExpectedWindowsRoot `
        'The bootstrap should replace a poisoned SystemRoot.'
    Assert-SshAccessTestEqual `
        $ObservedTrustedEnvironment.WindowsRoot `
        $ExpectedWindowsRoot `
        'The bootstrap should replace a poisoned windir.'
    Assert-SshAccessTestEqual `
        $ObservedTrustedEnvironment.ComSpec `
        $ExpectedCommandProcessor `
        'The bootstrap should replace a poisoned ComSpec.'
    Assert-SshAccessTestEqual `
        $ObservedTrustedEnvironment.ModulePath `
        $ExpectedModulePath `
        'The bootstrap should restrict PSModulePath to the current trusted PowerShell home.'

    Write-Host '[TEST] Trusted Windows path resolution'
    $SavedSystemRoot = [Environment]::GetEnvironmentVariable(
        'SystemRoot',
        [EnvironmentVariableTarget]::Process
    )
    try {
        $env:SystemRoot = Join-Path $ScratchRoot 'untrusted-system-root'
        $TrustedContext = New-SshAccessContext `
            -KitRoot $script:SshAccessTestKitRoot
        $NativePowerShell = Resolve-SshAccessNativeWindowsPowerShell
    } finally {
        [Environment]::SetEnvironmentVariable(
            'SystemRoot',
            $SavedSystemRoot,
            [EnvironmentVariableTarget]::Process
        )
    }
    Assert-SshAccessTestEqual `
        $TrustedContext.WindowsRoot `
        $ExpectedWindowsRoot `
        'A spoofed SystemRoot must not change the runtime context.'
    Assert-SshAccessTestTrue `
        (Test-Path -LiteralPath $NativePowerShell -PathType Leaf) `
        'Elevation should resolve an existing native Windows PowerShell.'

    Write-Host '[TEST] Direct 32-bit host is rejected'
    if ([Environment]::Is64BitOperatingSystem) {
        $WowPowerShell = Join-Path `
            $ExpectedWindowsRoot `
            'SysWOW64\WindowsPowerShell\v1.0\powershell.exe'
        $OldErrorActionPreference = $ErrorActionPreference
        try {
            $ErrorActionPreference = 'Continue'
            $WowOutput = (
                & $WowPowerShell `
                    -NoLogo `
                    -NoProfile `
                    -ExecutionPolicy Bypass `
                    -File $Context.KitScript `
                    '.help' 2>&1 |
                    Out-String
            )
            $WowExitCode = $LASTEXITCODE
        } finally {
            $ErrorActionPreference = $OldErrorActionPreference
        }
        Assert-SshAccessTestEqual `
            $WowExitCode `
            1 `
            'Direct 32-bit execution on 64-bit Windows should fail closed.'
        Assert-SshAccessTestContains `
            $WowOutput `
            '32-bit PowerShell on 64-bit Windows' `
            'The architecture failure should identify the rejected host.'
        Assert-SshAccessTestContains `
            $WowOutput `
            'kit.cmd' `
            'The architecture failure should direct callers through the native adapter.'
    }

    Write-Host '[TEST] Elevated process environment is trusted'
    $SavedElevationEnvironment = Save-SshAccessTestEnvironment `
        -Names @('SystemRoot', 'windir', 'ComSpec')
    $script:CapturedElevationEnvironment = $null
    function Start-Process {
        param(
            [string]$FilePath,
            [string]$Verb,
            [object[]]$ArgumentList,
            [switch]$Wait,
            [switch]$PassThru
        )

        $script:CapturedElevationEnvironment = [pscustomobject]@{
            FilePath = $FilePath
            SystemRoot = $env:SystemRoot
            WindowsRoot = $env:windir
            ComSpec = $env:ComSpec
        }
        return [pscustomobject]@{ ExitCode = 23 }
    }
    try {
        $PoisonSystemRoot = Join-Path $ScratchRoot 'elevation-system-root'
        $PoisonWindowsRoot = Join-Path $ScratchRoot 'elevation-windir'
        $PoisonCommandProcessor = Join-Path $ScratchRoot 'elevation-cmd.exe'
        $env:SystemRoot = $PoisonSystemRoot
        $env:windir = $PoisonWindowsRoot
        $env:ComSpec = $PoisonCommandProcessor
        $TrustedElevationCode = Start-SshAccessElevatedPowerShell `
            -Script 'exit 0' `
            -DisplayCommand 'sshaccess.test .global client install'
        $RestoredElevationEnvironment = [pscustomobject]@{
            SystemRoot = $env:SystemRoot
            WindowsRoot = $env:windir
            ComSpec = $env:ComSpec
        }
    } finally {
        Remove-Item Function:\Start-Process -Force -ErrorAction SilentlyContinue
        Restore-SshAccessTestEnvironment -Saved $SavedElevationEnvironment
    }
    Assert-SshAccessTestEqual `
        $TrustedElevationCode `
        23 `
        'The trusted elevation launcher should forward the child exit code.'
    Assert-SshAccessTestEqual `
        $script:CapturedElevationEnvironment.FilePath `
        $NativePowerShell `
        'Elevation should launch the trusted native Windows PowerShell.'
    Assert-SshAccessTestEqual `
        $script:CapturedElevationEnvironment.SystemRoot `
        $ExpectedWindowsRoot `
        'Elevation should temporarily replace a poisoned SystemRoot.'
    Assert-SshAccessTestEqual `
        $script:CapturedElevationEnvironment.WindowsRoot `
        $ExpectedWindowsRoot `
        'Elevation should temporarily replace a poisoned windir.'
    Assert-SshAccessTestEqual `
        $script:CapturedElevationEnvironment.ComSpec `
        (Join-Path $ExpectedWindowsRoot 'System32\cmd.exe') `
        'Elevation should temporarily replace a poisoned ComSpec.'
    Assert-SshAccessTestEqual `
        $RestoredElevationEnvironment.SystemRoot `
        $PoisonSystemRoot `
        'Elevation should restore the caller SystemRoot.'
    Assert-SshAccessTestEqual `
        $RestoredElevationEnvironment.WindowsRoot `
        $PoisonWindowsRoot `
        'Elevation should restore the caller windir.'
    Assert-SshAccessTestEqual `
        $RestoredElevationEnvironment.ComSpec `
        $PoisonCommandProcessor `
        'Elevation should restore the caller ComSpec.'

    Write-Host '[TEST] Elevated command preserves the result host'
    $script:ElevatedScript = $null
    function Start-SshAccessElevatedPowerShell {
        param(
            [string]$Script,
            [string]$DisplayCommand
        )

        $script:ElevatedScript = $Script
        return 17
    }
    $ElevationCode = Invoke-SshAccessElevatedCommand `
        -Context $Context `
        -Arguments @('.global', 'client', 'install')
    Assert-SshAccessTestEqual `
        $ElevationCode `
        17 `
        'The elevation transport should forward the elevated host exit code.'
    Assert-SshAccessTestContains `
        $script:ElevatedScript `
        'kit.cmd' `
        'The elevated host should invoke kit.cmd as a child process.'
    Assert-SshAccessTestContains `
        $script:ElevatedScript `
        'Press Enter to close' `
        'The elevated host should keep the result visible.'
    Assert-SshAccessTestContains `
        $script:ElevatedScript `
        '$ExitCode = if ($null -eq $LASTEXITCODE) { 1 }' `
        'A missing elevated child exit code should fail closed.'
    Assert-SshAccessTestContains `
        $script:ElevatedScript `
        ('$env:ComSpec = ' + (
            ConvertTo-SshAccessPowerShellLiteral (
                (Join-Path $ExpectedWindowsRoot 'System32\cmd.exe')
            )
        )) `
        'The elevated host should select trusted cmd.exe before kit.cmd.'
} finally {
    Restore-SshAccessTestEnvironment -Saved $SavedEnvironment
    Remove-SshAccessTestScratchRoot -Path $ScratchRoot
}

Write-Host 'ssh access runtime security tests: PASS' -ForegroundColor Green
