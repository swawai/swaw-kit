function Initialize-ConsoleEncoding {
    try {
        $utf8NoBom = New-Object System.Text.UTF8Encoding($false)
        [Console]::OutputEncoding = $utf8NoBom
        $OutputEncoding = $utf8NoBom
    } catch {
    }
}

function Get-EnvOrEmpty {
    param([string]$Name)

    $value = [Environment]::GetEnvironmentVariable($Name, "Process")
    if ($null -eq $value) {
        return ""
    }

    return $value
}

function Get-KitArgumentsFromEnvironment {
    $countText = Get-EnvOrEmpty "WSL_KIT_ARG_COUNT"
    $count = 0
    if (-not [int]::TryParse($countText, [ref]$count) -or $count -le 0) {
        return @()
    }

    $items = New-Object System.Collections.ArrayList
    for ($i = 1; $i -le $count; $i++) {
        [void]$items.Add((Get-EnvOrEmpty "WSL_KIT_ARG_$i"))
    }

    return @($items)
}

function Test-Truthy {
    param([AllowNull()] [string]$Value)

    if ([string]::IsNullOrWhiteSpace($Value)) {
        return $false
    }

    return $Value.Trim() -match '^(1|true|yes|on|debug)$'
}

function Write-Fail {
    param([string]$Message)

    Write-Host "[ERROR] $Message" -ForegroundColor Red
}

function Write-Warn {
    param([string]$Message)

    Write-Host $Message -ForegroundColor Yellow
}

function Format-Arg {
    param([AllowNull()] [string]$Value)

    if ($null -eq $Value -or $Value -eq "") {
        return '""'
    }

    if ($Value -notmatch '[\s"]') {
        return $Value
    }

    $builder = New-Object System.Text.StringBuilder
    $backslashChar = [char]92
    $quoteChar = [char]34
    $backslashCount = 0

    [void]$builder.Append($quoteChar)
    foreach ($char in $Value.ToCharArray()) {
        if ($char -eq $backslashChar) {
            $backslashCount += 1
            continue
        }

        if ($char -eq $quoteChar) {
            [void]$builder.Append(([string]$backslashChar) * (($backslashCount * 2) + 1))
            [void]$builder.Append($quoteChar)
            $backslashCount = 0
            continue
        }

        if ($backslashCount -gt 0) {
            [void]$builder.Append(([string]$backslashChar) * $backslashCount)
            $backslashCount = 0
        }

        [void]$builder.Append($char)
    }

    if ($backslashCount -gt 0) {
        [void]$builder.Append(([string]$backslashChar) * ($backslashCount * 2))
    }

    [void]$builder.Append($quoteChar)
    return $builder.ToString()
}

function Format-CommandLine {
    param(
        [string]$File,
        [string[]]$CommandArgs
    )

    $parts = New-Object System.Collections.ArrayList
    [void]$parts.Add((Format-Arg $File))
    foreach ($arg in @($CommandArgs)) {
        [void]$parts.Add((Format-Arg $arg))
    }

    return ($parts -join " ")
}

function Get-ProcessArgumentLine {
    param([string[]]$CommandArgs)

    if ($null -eq $CommandArgs -or $CommandArgs.Count -eq 0) {
        return ""
    }

    return (($CommandArgs | ForEach-Object { Format-Arg $_ }) -join " ")
}

function Invoke-External {
    param(
        [string]$File,
        [string[]]$CommandArgs,
        [switch]$AlwaysShow
    )

    if ($AlwaysShow -or $script:Config.Verbose) {
        Write-Host (Format-CommandLine $File $CommandArgs) -ForegroundColor DarkGray
    }

    $startParams = @{
        FilePath    = $File
        Wait        = $true
        NoNewWindow = $true
        PassThru    = $true
    }

    $argumentLine = Get-ProcessArgumentLine $CommandArgs
    if (-not [string]::IsNullOrWhiteSpace($argumentLine)) {
        $startParams.ArgumentList = $argumentLine
    }

    try {
        $process = Start-Process @startParams
    } catch {
        Write-Fail "Failed to start native command: $File"
        Write-Fail $_.Exception.Message
        return 1
    }

    if ($null -eq $process -or $null -eq $process.ExitCode) {
        return 0
    }

    return [int]$process.ExitCode
}

function Start-ExternalDetached {
    param(
        [string]$File,
        [string[]]$CommandArgs,
        [switch]$AlwaysShow
    )

    if ($AlwaysShow -or $script:Config.Verbose) {
        Write-Host (Format-CommandLine $File $CommandArgs) -ForegroundColor DarkGray
    }

    $argumentLine = Get-ProcessArgumentLine $CommandArgs
    $startParams = @{
        FilePath = $File
    }
    if (-not [string]::IsNullOrWhiteSpace($argumentLine)) {
        $startParams.ArgumentList = $argumentLine
    }

    Start-Process @startParams | Out-Null
    return 0
}

function Show-NativeCommand {
    param(
        [string]$File,
        [string[]]$CommandArgs
    )

    Write-Host (Format-CommandLine $File $CommandArgs)
}

function New-Base64ShRunner {
    param([string]$ScriptText)

    $lfScript = $ScriptText -replace "`r`n", "`n"
    $encodedScript = [Convert]::ToBase64String([System.Text.Encoding]::UTF8.GetBytes($lfScript))
    return "printf '%s' '$encodedScript' | base64 -d | sh"
}

function Get-Slice {
    param(
        [string[]]$Items,
        [int]$Start
    )

    if ($null -eq $Items -or $Items.Count -le $Start) {
        return @()
    }

    return @($Items[$Start..($Items.Count - 1)])
}

function Test-WindowsPathLike {
    param([AllowNull()] [string]$Value)

    if ([string]::IsNullOrWhiteSpace($Value)) {
        return $false
    }

    $trimmed = $Value.Trim()
    if ($trimmed -match '^[a-zA-Z]:[\\/]' -or $trimmed -match '^[\\/]{2}') {
        return $true
    }

    if ($trimmed -match '[\\/]' -or $trimmed.StartsWith(".")) {
        return $true
    }

    $lower = $trimmed.ToLowerInvariant()
    foreach ($suffix in @(".tar", ".tar.gz", ".tar.xz", ".tgz", ".vhd", ".vhdx")) {
        if ($lower.EndsWith($suffix)) {
            return $true
        }
    }

    return $false
}

function Test-WslBackupArchivePath {
    param([AllowNull()] [string]$Path)

    if ([string]::IsNullOrWhiteSpace($Path)) {
        return $false
    }

    $lower = $Path.Trim().ToLowerInvariant()
    foreach ($suffix in @(".tar", ".tar.gz", ".tar.xz", ".tgz", ".vhd", ".vhdx")) {
        if ($lower.EndsWith($suffix)) {
            return $true
        }
    }

    return $false
}

function Test-WslVhdArchivePath {
    param([AllowNull()] [string]$Path)

    if ([string]::IsNullOrWhiteSpace($Path)) {
        return $false
    }

    $lower = $Path.Trim().ToLowerInvariant()
    return ($lower.EndsWith(".vhd") -or $lower.EndsWith(".vhdx"))
}

function Resolve-EntryPath {
    param([AllowNull()] [string]$Path)

    if ([string]::IsNullOrWhiteSpace($Path)) {
        return ""
    }

    $expanded = [Environment]::ExpandEnvironmentVariables($Path.Trim())
    if ([System.IO.Path]::IsPathRooted($expanded)) {
        return [System.IO.Path]::GetFullPath($expanded)
    }

    return [System.IO.Path]::GetFullPath((Join-Path $script:Config.EntryDir $expanded))
}

function Resolve-OutputPath {
    param([string]$Path)

    $expanded = [Environment]::ExpandEnvironmentVariables($Path)
    if ([System.IO.Path]::IsPathRooted($expanded)) {
        return [System.IO.Path]::GetFullPath($expanded)
    }

    return [System.IO.Path]::GetFullPath((Join-Path (Get-Location) $expanded))
}

function Ensure-Directory {
    param([string]$Path)

    if ([string]::IsNullOrWhiteSpace($Path)) {
        return
    }

    if (-not (Test-Path -LiteralPath $Path -PathType Container)) {
        New-Item -ItemType Directory -Force -Path $Path | Out-Null
    }
}
