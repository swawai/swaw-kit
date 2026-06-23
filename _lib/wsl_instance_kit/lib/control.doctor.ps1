$doctorDir = Join-Path $PSScriptRoot "doctor"
. (Join-Path $doctorDir "core.ps1")
. (Join-Path $doctorDir "checks.ps1")


function Invoke-WslDoctorChecks {
    $nativeInfo = Test-WslDoctorNative
    $entryInfo = Test-WslDoctorEntryConfig
    $sourceInfo = Test-WslDoctorSource
    $instanceInfo = Test-WslDoctorInstance $entryInfo.InstallDir
    Test-WslDoctorStorage $entryInfo
    Test-WslDoctorPlatform
    Test-WslDoctorNetworking $instanceInfo
    Invoke-WslDoctorNetworkChecks $nativeInfo $sourceInfo
}


function Write-WslDoctorJson {
    $data = [ordered]@{
        command = "doctor"
        entry   = [string]$script:Config.CommandName
        name    = [string]$script:Config.Name
        ok      = [int]$script:WslDoctorStats.OK
        warn    = [int]$script:WslDoctorStats.WARN
        fail    = [int]$script:WslDoctorStats.FAIL
        results = @($script:WslDoctorResults)
    }

    Write-CompactJson ([pscustomobject]$data) 5
}


function Invoke-WslDoctor {
    param([string[]]$Rest)

    $json = $false
    if ($Rest.Count -eq 1 -and $Rest[0] -ieq "--json") {
        $json = $true
    } elseif ($Rest.Count -ne 0) {
        return Show-CommandHelpHint ".doctor does not accept extra arguments."
    }

    Initialize-WslDoctorState
    $script:WslDoctorJsonMode = $json
    if (-not $json) {
        Write-Host "WSL doctor: $($script:Config.CommandName)"
        Write-Host "Local checks are printed first. Network checks run last and may take a moment."
    }

    try {
        Invoke-WslDoctorChecks
    } finally {
        $script:WslDoctorJsonMode = $false
    }

    if ($json) {
        Write-WslDoctorJson
    } else {
        Write-WslDoctorSection "Summary"
        Write-Host ("  OK: {0}  WARN: {1}  FAIL: {2}" -f $script:WslDoctorStats.OK, $script:WslDoctorStats.WARN, $script:WslDoctorStats.FAIL)
    }

    if ([int]$script:WslDoctorStats.FAIL -gt 0) {
        return 1
    }

    return 0
}
