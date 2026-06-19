function Test-HelpTemplateShape {
    $zhLines = [System.IO.File]::ReadAllLines((Join-Path $kitRoot "help\zh-CN.txt"))
    $enLines = [System.IO.File]::ReadAllLines((Join-Path $kitRoot "help\en.txt"))
    $zhBlankCount = @($zhLines | Where-Object { [string]::IsNullOrWhiteSpace($_) }).Count
    $enBlankCount = @($enLines | Where-Object { [string]::IsNullOrWhiteSpace($_) }).Count
    $zhText = $zhLines -join "`n"
    $enText = $enLines -join "`n"

    Assert-True ($zhLines.Count -eq $enLines.Count) "help templates should keep the same line count. zh-CN=$($zhLines.Count), en=$($enLines.Count)."
    Assert-True ($zhBlankCount -eq $enBlankCount) "help templates should keep the same blank-line count. zh-CN=$zhBlankCount, en=$enBlankCount."
    Assert-True (-not $zhText.Contains("{{COMMAND}}.cmd")) "zh-CN help should use the entry-file placeholder instead of hand-built command.cmd text."
    Assert-True (-not $enText.Contains("{{COMMAND}}.cmd")) "English help should use the entry-file placeholder instead of hand-built command.cmd text."
}

function Test-EntryTemplateShape {
    param([string]$EntryTemplate)

    Assert-True (-not $EntryTemplate.Contains("WSL_systemd")) "entry template should not declare WSL_systemd."
    Assert-True (-not $EntryTemplate.Contains("WSL_network")) "entry template should not declare WSL_network settings."
    Assert-True (-not $EntryTemplate.Contains("WSL_SSH_port")) "entry template should not declare WSL_SSH_port."
    Assert-True (-not $EntryTemplate.Contains("WSL_SSH_key")) "entry template should not declare WSL_SSH_key."
    Assert-True ($EntryTemplate.Contains("WSL_SSH_public_key")) "entry template should declare WSL_SSH_public_key."
    Assert-True ($EntryTemplate.Contains("WSL_env_file")) "entry template should declare WSL_env_file."
    Assert-True (-not ($EntryTemplate -match '(?m)^\s*set\s+"WSL_env_file=')) "entry template should leave WSL_env_file disabled by default."
}

function Test-GitAttributesCommandLineEndings {
    $attributesPath = Join-Path $repoRoot ".gitattributes"
    Assert-True (Test-Path -LiteralPath $attributesPath -PathType Leaf) ".gitattributes should declare command-script line endings."

    $attributesText = [System.IO.File]::ReadAllText($attributesPath)
    Assert-True ($attributesText -match '(?m)^\*\.cmd\s+.*\btext\b.*\beol=crlf\b') ".gitattributes should force .cmd files to CRLF."
    Assert-True ($attributesText -match '(?m)^\*\.bat\s+.*\btext\b.*\beol=crlf\b') ".gitattributes should force .bat files to CRLF."
}

function Test-EntryCommandLineEndings {
    param([string[]]$Paths)

    foreach ($path in @($Paths)) {
        $bytes = [System.IO.File]::ReadAllBytes($path)
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

        Assert-True ($lfCount -eq $crlfCount) "$path should use CRLF line endings for cmd.exe."
    }
}

function Test-LineEndingDiagnosticInvalidPath {
    . (Join-Path $kitRoot "lib\common.ps1")

    $invalidPath = "bad$([char]0)path.cmd"
    try {
        $status = Get-CommandScriptLineEndingStatus "BROKEN_CMD" $invalidPath
    } catch {
        throw "line-ending diagnostic should report invalid paths without throwing: $($_.Exception.Message)"
    }

    Assert-True ($status.Warning) "line-ending diagnostic should warn for an invalid path."
    Assert-True ($status.Status -eq "invalid path") "line-ending diagnostic should identify invalid paths."
    Assert-True ($status.Message.Contains("expected CRLF")) "line-ending diagnostic should keep the CRLF remediation hint."
}

function New-WslNameValidationEntryFile {
    param(
        [string]$EntryName,
        [string]$WslName
    )

    $path = Join-Path $repoRoot ("$EntryName.cmd")
    $content = [System.IO.File]::ReadAllText($entryFile)
    $content = Set-EntryLine $content "WSL_name" $WslName
    $content = $content -replace "`r?`n", "`r`n"
    [System.IO.File]::WriteAllText($path, $content, [System.Text.UTF8Encoding]::new($false))
    return $path
}

function Test-WslNameValidationSlowPath {
    $invalidEntryFile = $null
    try {
        $entryName = "wsl.smoke-invalid-name-" + [guid]::NewGuid().ToString("N")
        $invalidEntryFile = New-WslNameValidationEntryFile -EntryName $entryName -WslName "bad name"

        $output = Invoke-Captured $invalidEntryFile @(".status") 1 "invalid WSL_name slow path"
        Assert-True ($output.Contains("Invalid WSL_name")) "slow path should reject invalid WSL_name."
        Assert-True ($output.Contains("A-Z a-z 0-9 . _ -")) "slow path should explain the WSL_name character set."
    } finally {
        if ($invalidEntryFile -and (Test-Path -LiteralPath $invalidEntryFile)) {
            Remove-Item -LiteralPath $invalidEntryFile -Force
        }
    }
}

function Test-WslNameValidationFastPath {
    param([string]$ArgsFile)

    $invalidEntryFile = $null
    try {
        $entryName = "wsl.smoke-invalid-fast-name-" + [guid]::NewGuid().ToString("N")
        $invalidEntryFile = New-WslNameValidationEntryFile -EntryName $entryName -WslName "bad+name"

        Remove-Item -LiteralPath $ArgsFile -Force -ErrorAction SilentlyContinue
        $output = Invoke-Captured $invalidEntryFile @() 1 "invalid WSL_name fast path"
        Assert-True ($output.Contains("Invalid WSL_name")) "fast path should reject invalid WSL_name."
        Assert-True ($output.Contains("A-Z a-z 0-9 . _ -")) "fast path should explain the WSL_name character set."
        Assert-MockWslNotCalled $ArgsFile "invalid WSL_name fast path"
    } finally {
        if ($invalidEntryFile -and (Test-Path -LiteralPath $invalidEntryFile)) {
            Remove-Item -LiteralPath $invalidEntryFile -Force
        }
    }
}

function Test-WslNameValidationHelpFastPath {
    param([string]$ArgsFile)

    $invalidEntryFile = $null
    try {
        $entryName = "wsl.smoke-invalid-help-name-" + [guid]::NewGuid().ToString("N")
        $invalidEntryFile = New-WslNameValidationEntryFile -EntryName $entryName -WslName "bad name"

        Remove-Item -LiteralPath $ArgsFile -Force -ErrorAction SilentlyContinue
        $output = Invoke-Captured $invalidEntryFile @(".help") 1 "invalid WSL_name help fast path"
        Assert-True ($output.Contains("Invalid WSL_name")) "help fast path should reject invalid WSL_name."
        Assert-True (-not $output.Contains("Usage:")) "help fast path should not show help when WSL_name is invalid."
        Assert-MockWslNotCalled $ArgsFile "invalid WSL_name help fast path"
    } finally {
        if ($invalidEntryFile -and (Test-Path -LiteralPath $invalidEntryFile)) {
            Remove-Item -LiteralPath $invalidEntryFile -Force
        }
    }
}

function Test-WslNameRequiredHelpFastPath {
    param([string]$ArgsFile)

    $invalidEntryFile = $null
    try {
        $entryName = "wsl.smoke-missing-help-name-" + [guid]::NewGuid().ToString("N")
        $invalidEntryFile = New-WslNameValidationEntryFile -EntryName $entryName -WslName ""

        Remove-Item -LiteralPath $ArgsFile -Force -ErrorAction SilentlyContinue
        $output = Invoke-Captured $invalidEntryFile @(".help") 1 "missing WSL_name help fast path"
        Assert-True ($output.Contains("Invalid WSL_name")) "help fast path should reject missing WSL_name."
        Assert-True (-not $output.Contains("Usage:")) "help fast path should not show help when WSL_name is missing."
        Assert-MockWslNotCalled $ArgsFile "missing WSL_name help fast path"
    } finally {
        if ($invalidEntryFile -and (Test-Path -LiteralPath $invalidEntryFile)) {
            Remove-Item -LiteralPath $invalidEntryFile -Force
        }
    }
}

function New-SmokeLineEndingEntryFile {
    param(
        [string]$Name,
        [switch]$AddBareLfProbe
    )

    $path = Join-Path $repoRoot ("$Name.cmd")
    $content = [System.IO.File]::ReadAllText($entryFile)
    $content = Set-EntryLine $content "WSL_name" $Name
    $content = Set-EntryLine $content "WSL_env_file" ""
    $content = $content -replace "`r?`n", "`r`n"
    if ($AddBareLfProbe) {
        $content += ":: bare LF probe`n"
    }
    [System.IO.File]::WriteAllText($path, $content, [System.Text.UTF8Encoding]::new($false))
    return $path
}

function Test-EntryLineEndingStatusDiagnostics {
    $mixedEntryFile = $null
    try {
        $name = "wsl.smoke-mixed-eol-" + [guid]::NewGuid().ToString("N")
        $mixedEntryFile = New-SmokeLineEndingEntryFile -Name $name -AddBareLfProbe

        $statusOutput = Invoke-Captured $mixedEntryFile @(".status") 0 "mixed-EOL entry status"
        Assert-True ($statusOutput.Contains("Line endings:")) "status should show a line-ending warning for mixed-EOL cmd files."
        Assert-True ($statusOutput.Contains("WSL_ENTRY_FILE")) "status warning should identify the entry file."
        Assert-True ($statusOutput.Contains("expected CRLF")) "status warning should explain the expected cmd.exe line ending."
    } finally {
        if ($mixedEntryFile -and (Test-Path -LiteralPath $mixedEntryFile)) {
            Remove-Item -LiteralPath $mixedEntryFile -Force
        }
    }
}
