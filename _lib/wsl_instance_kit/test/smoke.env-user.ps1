function New-WslSmokeEnvEntryFile {
    param(
        [string]$TempRoot,
        [string]$Name,
        [string]$EnvFile,
        [string]$User = "john"
    )

    $entryPath = Join-Path $repoRoot ("$Name.cmd")
    $content = [System.IO.File]::ReadAllText($entryFile)
    $content = Set-EntryLine $content "WSL_name" $Name
    $content = Set-EntryLine $content "WSL_user" $User

    $envLine = 'set "WSL_env_file=' + $EnvFile + '"'
    if ($content -match '(?m)^(::|rem)\s*set "WSL_env_file=.*"\r?$') {
        $content = [regex]::Replace($content, '(?m)^(::|rem)\s*set "WSL_env_file=.*"\r?$', [System.Text.RegularExpressions.MatchEvaluator]{ param($match) $envLine })
    } elseif ($content -match '(?m)^set "WSL_env_file=.*"\r?$') {
        $content = Set-EntryLine $content "WSL_env_file" $EnvFile
    } else {
        $content = [regex]::Replace($content, '(?m)^(::\s*set "WSL_KIT_HELP_LANG=.*"\r?$)', [System.Text.RegularExpressions.MatchEvaluator]{ param($match) "$($match.Value)`r`n$envLine" })
    }

    $content = $content -replace "`r?`n", "`r`n"
    [System.IO.File]::WriteAllText($entryPath, $content, [System.Text.UTF8Encoding]::new($false))
    return $entryPath
}

function Initialize-SmokeUserProfile {
    param([string]$UserProfile)

    $secretsDir = Join-Path $UserProfile "secrets"
    New-Item -ItemType Directory -Path $secretsDir -Force | Out-Null
    [System.IO.File]::WriteAllText((Join-Path $secretsDir "wsl01.env"), "# smoke env`r`n", [System.Text.UTF8Encoding]::new($false))
}

function Test-EnvFileAndUserPasswdSmoke {
    param(
        [string]$TempRoot,
        [string]$ArgsFile,
        [string]$RawCommandLineFile
    )

    $passwordVar = "WSLKIT_SMOKE_PASSWORD"
    $missingPasswordVar = "WSLKIT_SMOKE_MISSING_PASSWORD"
    $password = "smokeSecret!42"
    $entryName = "wsl.smoke-env-" + [guid]::NewGuid().ToString("N").Substring(0, 8)
    $envFile = Join-Path $TempRoot "wslkit.env"
    $stdinFile = Join-Path $TempRoot "stdin.txt"
    $stdinBytesFile = Join-Path $TempRoot "stdin.bytes.b64"
    $oldPassword = [Environment]::GetEnvironmentVariable($passwordVar, "Process")
    $oldMissingPassword = [Environment]::GetEnvironmentVariable($missingPasswordVar, "Process")
    $oldStdinPath = $env:MOCK_WSL_STDIN_PATH
    $oldStdinBytesPath = $env:MOCK_WSL_STDIN_BYTES_PATH
    $envEntryFile = $null
    $missingEnvEntryFile = $null
    $fakeRegistryKey = $null

    try {
        [Environment]::SetEnvironmentVariable($passwordVar, $null, "Process")
        [Environment]::SetEnvironmentVariable($missingPasswordVar, $null, "Process")
        [System.IO.File]::WriteAllText($envFile, "# smoke env`r`n$passwordVar=$password`r`n", [System.Text.UTF8Encoding]::new($false))

        $envEntryFile = New-WslSmokeEnvEntryFile -TempRoot $TempRoot -Name $entryName -EnvFile $envFile -User "john"
        $fakeRegistryKey = New-FakeWslDistributionRecord -Name $entryName -BasePath (Join-Path $TempRoot "fake-base")

        $envStatusOutput = Invoke-Captured $envEntryFile @(".status") 0 "env file status"
        Assert-True ($envStatusOutput.Contains("WSL_env_file:        $([System.IO.Path]::GetFullPath($envFile))")) "status should show the resolved WSL_env_file."
        Assert-True ($envStatusOutput.Contains("WSL_SSH_public_key:")) "status should show WSL_SSH_public_key."
        Assert-True ($envStatusOutput.Contains("User password:       not checked (instance not running)")) "status should not start WSL to check password."

        Remove-Item -LiteralPath $ArgsFile -Force -ErrorAction SilentlyContinue
        Remove-Item -LiteralPath $RawCommandLineFile -Force -ErrorAction SilentlyContinue
        Remove-Item -LiteralPath $stdinFile -Force -ErrorAction SilentlyContinue
        Remove-Item -LiteralPath $stdinBytesFile -Force -ErrorAction SilentlyContinue
        $env:MOCK_WSL_STDIN_PATH = $stdinFile
        $env:MOCK_WSL_STDIN_BYTES_PATH = $stdinBytesFile

        Invoke-Checked $envEntryFile @(".user", "passwd", "--env", $passwordVar) 0 "user passwd env file"
        $actual = Read-MockWslArgs $ArgsFile
        Assert-ArrayEqual $actual @("-d", $entryName, "-u", "root", "--", "sh", "-lc", "chpasswd") "user passwd env args"

        $stdinText = [System.IO.File]::ReadAllText($stdinFile)
        Assert-True ($stdinText -eq "john:$password`n") "user passwd env should write chpasswd input to stdin."
        $expectedStdinBytes = [Convert]::ToBase64String([System.Text.UTF8Encoding]::new($false).GetBytes("john:$password`n"))
        $actualStdinBytes = [System.IO.File]::ReadAllText($stdinBytesFile)
        Assert-True ($actualStdinBytes -eq $expectedStdinBytes) "user passwd env should write UTF-8 stdin without a BOM. Expected $expectedStdinBytes, got $actualStdinBytes."
        $argText = $actual -join " "
        Assert-True (-not $argText.Contains($password)) "user passwd env should not put the password in wsl.exe args."
        $rawCommandLine = [System.IO.File]::ReadAllText($RawCommandLineFile)
        Assert-True (-not $rawCommandLine.Contains($password)) "user passwd env should not put the password in the Windows command line."

        $env:MOCK_WSL_STDIN_PATH = $null
        $env:MOCK_WSL_STDIN_BYTES_PATH = $null
        Remove-Item -LiteralPath $ArgsFile -Force -ErrorAction SilentlyContinue
        Invoke-Checked $envEntryFile @(".user", "passwd") 0 "user passwd interactive"
        $actual = Read-MockWslArgs $ArgsFile
        Assert-ArrayEqual $actual @("-d", $entryName, "-u", "root", "--", "passwd", "john") "user passwd interactive args"

        Remove-Item -LiteralPath $ArgsFile -Force -ErrorAction SilentlyContinue
        $missingOutput = Invoke-Captured $envEntryFile @(".user", "passwd", "--env", $missingPasswordVar) 1 "user passwd missing env"
        Assert-True ($missingOutput.Contains("Environment variable is empty or not found: $missingPasswordVar")) "missing env var should be reported."
        Assert-MockWslNotCalled $ArgsFile "missing env var"

        $missingEnvFile = Join-Path $TempRoot "missing.env"
        $missingEnvEntryFile = New-WslSmokeEnvEntryFile -TempRoot $TempRoot -Name ($entryName + "-missing") -EnvFile $missingEnvFile -User "john"
        $missingEnvOutput = Invoke-Captured $missingEnvEntryFile @(".status") 1 "missing explicit env file"
        Assert-True ($missingEnvOutput.Contains("Environment file not found:")) "missing explicit env file should be reported."
    } finally {
        [Environment]::SetEnvironmentVariable($passwordVar, $oldPassword, "Process")
        [Environment]::SetEnvironmentVariable($missingPasswordVar, $oldMissingPassword, "Process")
        $env:MOCK_WSL_STDIN_PATH = $oldStdinPath
        $env:MOCK_WSL_STDIN_BYTES_PATH = $oldStdinBytesPath
        if ($envEntryFile -and (Test-Path -LiteralPath $envEntryFile)) {
            Remove-Item -LiteralPath $envEntryFile -Force
        }
        if ($missingEnvEntryFile -and (Test-Path -LiteralPath $missingEnvEntryFile)) {
            Remove-Item -LiteralPath $missingEnvEntryFile -Force
        }
        if ($fakeRegistryKey) {
            Remove-Item -Path $fakeRegistryKey -Recurse -Force -ErrorAction SilentlyContinue
        }
    }
}
