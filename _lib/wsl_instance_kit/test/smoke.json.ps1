function Test-StatusJsonOutput {
    $output = Invoke-Captured $entryFile @(".status", "--json") 0 "entry status json"
    Assert-True (-not $output.Contains("WSL resource:")) "status json should not include text heading."

    try {
        $json = $output | ConvertFrom-Json
    } catch {
        throw "status json should parse: $($_.Exception.Message). Output: $output"
    }

    Assert-True ($json.command -eq "status") "status json should identify the command."
    Assert-True ($json.name -eq "wsl01") "status json should include WSL name."
    Assert-True ($json.user -eq "john") "status json should include WSL user."
    Assert-True (-not [string]::IsNullOrWhiteSpace($json.source)) "status json should include source."
    Assert-True ($null -ne $json.installed) "status json should include installed."
    Assert-True ($null -ne $json.backupBytes) "status json should include backupBytes."
    Assert-True ($null -ne $json.backupRootBytes) "status json should include backupRootBytes."
    Assert-True ($null -ne $json.downloadBytes) "status json should include downloadBytes."
    Assert-True ($null -ne $json.warnings) "status json should include warnings."
}

function Test-DoctorJsonOutput {
    $oldConfig = $script:Config
    try {
        . (Join-Path $kitRoot "lib\common.ps1")
        . (Join-Path $kitRoot "lib\control.doctor.ps1")

        $script:Config = [pscustomobject]@{
            CommandName = "wsl01"
            Name        = "wsl01"
        }

        function Test-WslDoctorNative {
            Add-WslDoctorOk "wsl.exe" "mock"
            return [pscustomobject]@{ Available = $true }
        }
        function Test-WslDoctorEntryConfig {
            Add-WslDoctorOk "WSL_name" "wsl01"
            return [pscustomobject]@{ InstallDir = "D:\x"; BackupDir = "D:\b" }
        }
        function Test-WslDoctorSource {
            Add-WslDoctorOk "WSL_source" "mock"
            return [pscustomobject]@{ Type = "distro"; Source = "mock"; FallbackDownload = $null }
        }
        function Test-WslDoctorInstance {
            param([string]$InstallDir)
            Add-WslDoctorWarn "installed instance" "not registered"
            return [pscustomobject]@{ RuntimeIp = "" }
        }
        function Test-WslDoctorStorage {
            param([pscustomobject]$EntryInfo)
            Add-WslDoctorOk "storage" "mock"
        }
        function Test-WslDoctorPlatform {
            Add-WslDoctorOk "platform" "mock"
        }
        function Test-WslDoctorNetworking {
            param([pscustomobject]$InstanceInfo)
            Add-WslDoctorOk "networkingMode" "nat"
        }
        function Invoke-WslDoctorNetworkChecks {
            param([pscustomobject]$NativeInfo, [pscustomobject]$SourceInfo)
            Add-WslDoctorWarn "network checks" "mock skipped"
        }

        $script:DoctorJsonExitCode = $null
        $output = (& { $script:DoctorJsonExitCode = Invoke-WslDoctor @("--json") } 6>&1 | Out-String)
        Assert-True ($script:DoctorJsonExitCode -eq 0) "doctor json mock should exit zero without FAIL results."
    } finally {
        $script:Config = $oldConfig
    }

    Assert-True (-not $output.Contains("WSL doctor:")) "doctor json should not include text heading."

    try {
        $json = $output | ConvertFrom-Json
    } catch {
        throw "doctor json should parse: $($_.Exception.Message). Output: $output"
    }

    Assert-True ($json.command -eq "doctor") "doctor json should identify the command."
    Assert-True ($json.name -eq "wsl01") "doctor json should include WSL name."
    Assert-True ($null -ne $json.ok) "doctor json should include ok count."
    Assert-True ($null -ne $json.warn) "doctor json should include warn count."
    Assert-True ($null -ne $json.fail) "doctor json should include fail count."
    Assert-True ($json.results.Count -gt 0) "doctor json should include results."
    Assert-True ($null -ne $json.results[0].level) "doctor result should include level."
    Assert-True ($null -ne $json.results[0].label) "doctor result should include label."
}
