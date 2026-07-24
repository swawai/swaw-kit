$ErrorActionPreference = 'Stop'
Set-StrictMode -Version 2.0

$KitRoot = Get-Item (Join-Path $PSScriptRoot '..')
. (Join-Path $KitRoot.FullName 'bootstrap.ps1')

function Assert-True {
    param(
        [Parameter(Mandatory = $true)][bool]$Condition,
        [Parameter(Mandatory = $true)][string]$Message
    )
    if (-not $Condition) {
        throw "Assertion failed: $Message"
    }
}

function Assert-Equal {
    param(
        [AllowNull()][object]$Actual,
        [AllowNull()][object]$Expected,
        [Parameter(Mandatory = $true)][string]$Message
    )
    if ([string]$Actual -ne [string]$Expected) {
        throw "Assertion failed: $Message`nExpected: $Expected`nActual:   $Actual"
    }
}

function Assert-Throws {
    param(
        [Parameter(Mandatory = $true)][scriptblock]$Action,
        [Parameter(Mandatory = $true)][string]$Message
    )
    $Thrown = $false
    try {
        & $Action
    } catch {
        $Thrown = $true
    }
    Assert-True $Thrown $Message
}

function Write-TestFile {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [string]$Content = 'fixture'
    )
    [void][IO.Directory]::CreateDirectory((Split-Path $Path -Parent))
    [IO.File]::WriteAllText($Path, $Content, [Text.UTF8Encoding]::new($false))
}

function New-TestZip {
    param(
        [Parameter(Mandatory = $true)][string]$Root,
        [Parameter(Mandatory = $true)][string]$ZipPath,
        [Parameter(Mandatory = $true)][string[]]$Files
    )
    $Source = Join-Path $Root ([Guid]::NewGuid().ToString('N'))
    [void][IO.Directory]::CreateDirectory($Source)
    try {
        foreach ($RelativePath in $Files) {
            Write-TestFile -Path (Join-Path $Source $RelativePath)
        }
        [IO.Compression.ZipFile]::CreateFromDirectory($Source, $ZipPath)
    } finally {
        Remove-Item -LiteralPath $Source -Recurse -Force
    }
}

function Get-TreeSnapshot {
    param([Parameter(Mandatory = $true)][string]$Root)

    if (-not [IO.Directory]::Exists($Root)) {
        return '<missing>'
    }
    $RootPath = Get-XvenvFullPath $Root
    $Rows = foreach ($Item in Get-ChildItem -LiteralPath $Root -Recurse -Force | Sort-Object FullName) {
        $Relative = $Item.FullName.Substring($RootPath.Length)
        if ($Item.PSIsContainer) {
            "$Relative|directory"
        } else {
            "$Relative|file|$($Item.Length)|$((Get-FileHash -LiteralPath $Item.FullName -Algorithm SHA256).Hash)"
        }
    }
    if ($null -eq $Rows) {
        return ''
    }
    return [string]::Join("`n", [string[]]$Rows)
}

function Save-TestEnvironment {
    $Names = @(
        'Path', 'XVENV_GENERATION_ID', 'XVENV_PROJECT_ROOT', 'XVENV_ENV_ROOT',
        'XVENV_PROJECT_HOME', 'XVENV_HOME', 'XVENV_BUN_HOME',
        'XVENV_PWSH_HOME', 'XVENV_UV_HOME', 'XVENV_SHELL_KIND', 'XVENV_SHELL_EXE',
        'XVENV_GO_HOME', 'UV_PROJECT_ENVIRONMENT', 'UV_CACHE_DIR',
        'UV_PYTHON_INSTALL_DIR', 'VIRTUAL_ENV', 'VIRTUAL_ENV_PROMPT', 'CONDA_PREFIX',
        'CONDA_DEFAULT_ENV', 'CONDA_SHLVL', 'CONDA_PROMPT_MODIFIER', 'PROMPT',
        'XVENV_LINK_ENTRY', 'XVENV_LINK_POWERSHELL', 'XVENV_LINK_PROJECT_ROOT',
        'VIRTUAL_ENV_DISABLE_PROMPT', '_OLD_VIRTUAL_PATH', '_OLD_VIRTUAL_PROMPT',
        '_OLD_VIRTUAL_PYTHONHOME', 'PYTHONHOME', 'GOROOT', 'GOPATH', 'GOCACHE'
    )
    $Saved = @{}
    foreach ($Name in $Names) {
        $Value = [Environment]::GetEnvironmentVariable($Name, [EnvironmentVariableTarget]::Process)
        $Saved[$Name] = if ($null -eq $Value) {
            [pscustomobject]@{ Exists = $false; Value = $null }
        } else {
            [pscustomobject]@{ Exists = $true; Value = [string]$Value }
        }
    }
    return $Saved
}

function Restore-TestEnvironment {
    param([Parameter(Mandatory = $true)][hashtable]$Saved)

    foreach ($Name in $Saved.Keys) {
        if ($Saved[$Name].Exists) {
            [Environment]::SetEnvironmentVariable($Name, $Saved[$Name].Value, [EnvironmentVariableTarget]::Process)
        } else {
            [Environment]::SetEnvironmentVariable($Name, $null, [EnvironmentVariableTarget]::Process)
        }
    }
}
