Set-StrictMode -Version 2.0

function Test-SshAccessAdministrator {
    $Identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    try {
        if ($null -eq $Identity) {
            throw 'Unable to resolve the current Windows process identity.'
        }
        $Principal = New-Object Security.Principal.WindowsPrincipal($Identity)
        return $Principal.IsInRole(
            [Security.Principal.WindowsBuiltInRole]::Administrator
        )
    } finally {
        if ($null -ne $Identity) {
            $Identity.Dispose()
        }
    }
}

function ConvertTo-SshAccessPowerShellLiteral {
    param([AllowNull()][string]$Value)

    if ($null -eq $Value) {
        $Value = ''
    }
    return "'" + $Value.Replace("'", "''") + "'"
}

function ConvertTo-SshAccessEncodedCommand {
    param([Parameter(Mandatory = $true)][string]$Script)

    return [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($Script))
}

function Resolve-SshAccessNativeWindowsPowerShell {
    $WindowsPaths = Get-SshAccessTrustedWindowsPaths
    $PowerShellPath = Join-Path `
        $WindowsPaths.NativeSystemDirectory `
        'WindowsPowerShell\v1.0\powershell.exe'
    if (-not (Test-Path -LiteralPath $PowerShellPath -PathType Leaf)) {
        throw "Native Windows PowerShell was not found: $PowerShellPath"
    }
    return [IO.Path]::GetFullPath($PowerShellPath)
}

function Start-SshAccessElevatedPowerShell {
    param(
        [Parameter(Mandatory = $true)][string]$Script,
        [Parameter(Mandatory = $true)][string]$DisplayCommand
    )

    Write-SshAccessWarning "Requesting administrator approval for:"
    Write-Host "  $DisplayCommand"

    $Encoded = ConvertTo-SshAccessEncodedCommand -Script $Script
    $PowerShellPath = Resolve-SshAccessNativeWindowsPowerShell
    $WindowsPaths = Get-SshAccessTrustedWindowsPaths
    $CommandProcessor = Join-Path $WindowsPaths.WindowsRoot 'System32\cmd.exe'
    if (-not (Test-Path -LiteralPath $CommandProcessor -PathType Leaf)) {
        throw "The trusted Windows command processor was not found: $CommandProcessor"
    }
    $SavedSystemRoot = [Environment]::GetEnvironmentVariable(
        'SystemRoot',
        [EnvironmentVariableTarget]::Process
    )
    $SavedWindowsDirectory = [Environment]::GetEnvironmentVariable(
        'windir',
        [EnvironmentVariableTarget]::Process
    )
    $SavedCommandProcessor = [Environment]::GetEnvironmentVariable(
        'ComSpec',
        [EnvironmentVariableTarget]::Process
    )
    try {
        $env:SystemRoot = $WindowsPaths.WindowsRoot
        $env:windir = $WindowsPaths.WindowsRoot
        $env:ComSpec = [IO.Path]::GetFullPath($CommandProcessor)
        try {
            $Process = Start-Process `
                -FilePath $PowerShellPath `
                -Verb RunAs `
                -ArgumentList @('-NoLogo', '-NoProfile', '-ExecutionPolicy', 'Bypass', '-EncodedCommand', $Encoded) `
                -Wait `
                -PassThru
        } catch {
            throw "Elevation was cancelled or failed. $($_.Exception.Message)"
        }
    } finally {
        [Environment]::SetEnvironmentVariable(
            'SystemRoot',
            $SavedSystemRoot,
            [EnvironmentVariableTarget]::Process
        )
        [Environment]::SetEnvironmentVariable(
            'windir',
            $SavedWindowsDirectory,
            [EnvironmentVariableTarget]::Process
        )
        [Environment]::SetEnvironmentVariable(
            'ComSpec',
            $SavedCommandProcessor,
            [EnvironmentVariableTarget]::Process
        )
    }

    if ($null -eq $Process -or $null -eq $Process.ExitCode) {
        throw 'The elevated process did not return an exit code.'
    }
    return [int]$Process.ExitCode
}

function Get-SshAccessContextEnvironmentScript {
    param([Parameter(Mandatory = $true)][pscustomobject]$Context)

    return [string]::Join([Environment]::NewLine, [string[]]@(
        "`$env:SSH_ACCESS_PROTOCOL = '1'",
        "`$env:SSH_ACCESS_ENTRY_COMMAND = $(ConvertTo-SshAccessPowerShellLiteral $Context.CommandName)",
        "`$env:SSH_ACCESS_ENTRY_FILE = $(ConvertTo-SshAccessPowerShellLiteral $Context.EntryFile)",
        "`$env:SSH_ACCESS_PRIVATE_KEY_PATH = $(ConvertTo-SshAccessPowerShellLiteral $Context.PrivateKeyPath)",
        "`$env:SSH_ACCESS_USER = $(ConvertTo-SshAccessPowerShellLiteral $Context.UserName)",
        "`$env:SSH_ACCESS_KEY_TYPE = $(ConvertTo-SshAccessPowerShellLiteral $Context.KeyType)",
        "`$env:SSH_ACCESS_KEY_COMMENT = $(ConvertTo-SshAccessPowerShellLiteral $Context.KeyComment)"
    ))
}

function Invoke-SshAccessElevatedCommand {
    param(
        [Parameter(Mandatory = $true)][pscustomobject]$Context,
        [Parameter(Mandatory = $true)]
        [AllowEmptyCollection()]
        [string[]]$Arguments
    )

    if (-not (Test-Path -LiteralPath $Context.KitCommand -PathType Leaf)) {
        throw "Kit command not found; cannot self-elevate: $($Context.KitCommand)"
    }

    $EnvironmentScript = Get-SshAccessContextEnvironmentScript -Context $Context
    $ArgumentText = [string]::Join(' ', [string[]]@(
        $Arguments | ForEach-Object { ConvertTo-SshAccessPowerShellLiteral $_ }
    ))
    # Invoke the CMD adapter as a child process. Calling kit.ps1 directly would
    # let its `exit` terminate this elevated host before the result can be shown.
    $KitLiteral = ConvertTo-SshAccessPowerShellLiteral $Context.KitCommand
    $CommandProcessor = Join-Path $Context.WindowsRoot 'System32\cmd.exe'
    if (-not (Test-Path -LiteralPath $CommandProcessor -PathType Leaf)) {
        throw "The trusted Windows command processor was not found: $CommandProcessor"
    }
    $CommandProcessorLiteral = ConvertTo-SshAccessPowerShellLiteral (
        [IO.Path]::GetFullPath($CommandProcessor)
    )
    $Invocation = if ([string]::IsNullOrWhiteSpace($ArgumentText)) {
        "& $KitLiteral"
    } else {
        "& $KitLiteral $ArgumentText"
    }
    $Script = @"
`$ErrorActionPreference = 'Stop'
[Console]::OutputEncoding = [Text.UTF8Encoding]::new(`$false)
$EnvironmentScript
`$env:ComSpec = $CommandProcessorLiteral
$Invocation
`$ExitCode = if (`$null -eq `$LASTEXITCODE) { 1 } else { [int]`$LASTEXITCODE }
Write-Host ''
Write-Host ('Exit code: ' + `$ExitCode)
[void](Read-Host 'Press Enter to close')
exit `$ExitCode
"@

    $DisplayCommand = Format-SshAccessCommand -CommandName $Context.CommandName -Arguments $Arguments
    return Start-SshAccessElevatedPowerShell -Script $Script -DisplayCommand $DisplayCommand
}

function Invoke-SshAccessAdminCommand {
    param(
        [Parameter(Mandatory = $true)][pscustomobject]$Context,
        [Parameter(Mandatory = $true)]
        [AllowEmptyCollection()]
        [string[]]$Arguments,
        [Parameter(Mandatory = $true)][bool]$Uac
    )

    if (Test-SshAccessAdministrator) {
        return $null
    }
    if (-not $Uac) {
        $Retry = @($Arguments) + '--uac'
        throw "Administrator privileges are required. Run: $(Format-SshAccessCommand -CommandName $Context.CommandName -Arguments $Retry)"
    }

    return Invoke-SshAccessElevatedCommand -Context $Context -Arguments $Arguments
}
