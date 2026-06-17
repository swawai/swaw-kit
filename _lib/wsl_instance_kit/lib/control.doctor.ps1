$doctorDir = Join-Path $PSScriptRoot "doctor"
. (Join-Path $doctorDir "core.ps1")
. (Join-Path $doctorDir "checks.ps1")


function Invoke-WslDoctor {
    param([string[]]$Rest)

    if ($Rest.Count -ne 0) {
        return Show-CommandHelpHint "doctor does not accept extra arguments."
    }

    Initialize-WslDoctorState
    Write-Host "WSL doctor: $($script:Config.CommandName)"
    Write-Host "Local checks are printed first. Network checks run last and may take a moment."

    $nativeInfo = Test-WslDoctorNative
    $entryInfo = Test-WslDoctorEntryConfig
    $sourceInfo = Test-WslDoctorSource
    $instanceInfo = Test-WslDoctorInstance $entryInfo.InstallDir
    Test-WslDoctorStorage $entryInfo
    Test-WslDoctorPlatform
    Test-WslDoctorNetworking $instanceInfo
    Invoke-WslDoctorNetworkChecks $nativeInfo $sourceInfo

    Write-WslDoctorSection "Summary"
    Write-Host ("  OK: {0}  WARN: {1}  FAIL: {2}" -f $script:WslDoctorStats.OK, $script:WslDoctorStats.WARN, $script:WslDoctorStats.FAIL)

    if ([int]$script:WslDoctorStats.FAIL -gt 0) {
        return 1
    }

    return 0
}
