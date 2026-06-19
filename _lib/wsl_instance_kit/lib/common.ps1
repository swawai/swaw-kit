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

function Resolve-NativeCommandPath {
    param([string]$File)

    if ([string]::IsNullOrWhiteSpace($File)) {
        return $File
    }
    if ([System.IO.Path]::IsPathRooted($File) -and (Test-Path -LiteralPath $File -PathType Leaf)) {
        return [System.IO.Path]::GetFullPath($File)
    }

    $extensions = @("")
    if ([string]::IsNullOrWhiteSpace([System.IO.Path]::GetExtension($File))) {
        $extensions = @((Get-EnvOrEmpty "PATHEXT").Split(";") | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
        if ($extensions.Count -eq 0) {
            $extensions = @(".COM", ".EXE", ".BAT", ".CMD")
        }
    }

    foreach ($dir in @((Get-EnvOrEmpty "PATH").Split(";"))) {
        if ([string]::IsNullOrWhiteSpace($dir)) {
            continue
        }

        foreach ($extension in $extensions) {
            $candidate = Join-Path $dir ($File + $extension)
            if (Test-Path -LiteralPath $candidate -PathType Leaf) {
                return [System.IO.Path]::GetFullPath($candidate)
            }
        }
    }

    return $File
}

function Get-CommandScriptLineEndingStatus {
    param(
        [string]$Label,
        [AllowNull()] [string]$Path
    )

    if ([string]::IsNullOrWhiteSpace($Path)) {
        return [pscustomobject]@{
            Label = $Label
            Path = ""
            Status = "not configured"
            Warning = $false
            Message = "not configured"
        }
    }

    try {
        if ($Path.IndexOfAny([System.IO.Path]::GetInvalidPathChars()) -ge 0) {
            $displayPath = $Path -replace '[\x00-\x1F]', '?'
            return [pscustomobject]@{
                Label = $Label
                Path = $displayPath
                Status = "invalid path"
                Warning = $true
                Message = "invalid path; expected CRLF for cmd.exe"
            }
        }

        $expandedPath = [Environment]::ExpandEnvironmentVariables($Path)
        if ($expandedPath.IndexOfAny([System.IO.Path]::GetInvalidPathChars()) -ge 0) {
            $displayPath = $expandedPath -replace '[\x00-\x1F]', '?'
            return [pscustomobject]@{
                Label = $Label
                Path = $displayPath
                Status = "invalid path"
                Warning = $true
                Message = "invalid path; expected CRLF for cmd.exe"
            }
        }

        $resolvedPath = [System.IO.Path]::GetFullPath($expandedPath)
    } catch {
        $displayPath = ([string]$Path) -replace '[\x00-\x1F]', '?'
        return [pscustomobject]@{
            Label = $Label
            Path = $displayPath
            Status = "invalid path"
            Warning = $true
            Message = "invalid path; expected CRLF for cmd.exe"
            Error = $_.Exception.Message
        }
    }

    if (-not (Test-Path -LiteralPath $resolvedPath -PathType Leaf)) {
        return [pscustomobject]@{
            Label = $Label
            Path = $resolvedPath
            Status = "not found"
            Warning = $false
            Message = "not found"
        }
    }

    $bytes = [System.IO.File]::ReadAllBytes($resolvedPath)
    $lfCount = 0
    $crlfCount = 0
    for ($i = 0; $i -lt $bytes.Length; $i++) {
        if ($bytes[$i] -ne 10) {
            continue
        }

        $lfCount += 1
        if ($i -gt 0 -and $bytes[$i - 1] -eq 13) {
            $crlfCount += 1
        }
    }

    $bareLfCount = $lfCount - $crlfCount
    $status = if ($lfCount -eq 0) {
        "no line endings"
    } elseif ($bareLfCount -eq 0) {
        "CRLF"
    } elseif ($crlfCount -eq 0) {
        "LF"
    } else {
        "mixed"
    }
    $warning = ($bareLfCount -gt 0)
    $message = if ($warning) {
        "$status; expected CRLF for cmd.exe"
    } else {
        $status
    }

    return [pscustomobject]@{
        Label = $Label
        Path = $resolvedPath
        Status = $status
        Warning = $warning
        Message = $message
        LfCount = $lfCount
        CrlfCount = $crlfCount
        BareLfCount = $bareLfCount
    }
}

function Get-WslCommandScriptLineEndingStatuses {
    $items = New-Object System.Collections.ArrayList

    if ($null -ne $script:Config -and -not [string]::IsNullOrWhiteSpace($script:Config.EntryFile)) {
        [void]$items.Add((Get-CommandScriptLineEndingStatus "WSL_ENTRY_FILE" $script:Config.EntryFile))
    }

    $kitPath = (Get-EnvOrEmpty "WSL_KIT").Trim()
    if (-not [string]::IsNullOrWhiteSpace($kitPath)) {
        [void]$items.Add((Get-CommandScriptLineEndingStatus "WSL_KIT" $kitPath))
    }

    return @($items)
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
