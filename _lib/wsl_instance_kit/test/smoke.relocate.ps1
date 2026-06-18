function New-FakeWslDistributionRecord {
    param(
        [string]$Name,
        [string]$BasePath
    )

    $keyPath = Join-Path "HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Lxss" ("{" + [guid]::NewGuid().ToString() + "}")
    New-Item -Path $keyPath -Force | Out-Null
    New-ItemProperty -Path $keyPath -Name "DistributionName" -PropertyType String -Value $Name -Force | Out-Null
    New-ItemProperty -Path $keyPath -Name "BasePath" -PropertyType String -Value $BasePath -Force | Out-Null
    New-ItemProperty -Path $keyPath -Name "State" -PropertyType DWord -Value 1 -Force | Out-Null
    New-ItemProperty -Path $keyPath -Name "Version" -PropertyType DWord -Value 2 -Force | Out-Null
    New-ItemProperty -Path $keyPath -Name "DefaultUid" -PropertyType DWord -Value 0 -Force | Out-Null
    New-ItemProperty -Path $keyPath -Name "Flags" -PropertyType DWord -Value 15 -Force | Out-Null
    New-ItemProperty -Path $keyPath -Name "VhdFileName" -PropertyType String -Value "ext4.vhdx" -Force | Out-Null
    return $keyPath
}


function Test-WslRelocateSmoke {
    param(
        [string]$EntryFile,
        [string]$TempRoot,
        [string]$ArgsFile
    )

    $relocateEntryFile = $null
    $sameRelocateEntryFile = $null
    $fakeRegistryKeys = New-Object System.Collections.ArrayList

    try {
        $relocateName = "wsl.smoke-relocate-" + [guid]::NewGuid().ToString("N").Substring(0, 8)
        $relocateSourceDir = Join-Path $TempRoot "relocate-source"
        $relocateTargetDir = Join-Path $TempRoot "relocate-target"
        $relocateBackupDir = Join-Path $TempRoot "relocate-backup"
        $relocateEntryFile = New-WslSmokeEntryFile -Name $relocateName -InstallDir $relocateTargetDir -BackupDir $relocateBackupDir -User "john"
        [void]$fakeRegistryKeys.Add((New-FakeWslDistributionRecord -Name $relocateName -BasePath ([System.IO.Path]::GetFullPath($relocateSourceDir))))

        Remove-Item -LiteralPath $ArgsFile -Force -ErrorAction SilentlyContinue
        $relocateDryRunOutput = Invoke-Captured $relocateEntryFile @(".relocate", "--dry-run") 0 "relocate dry-run"
        Assert-True ($relocateDryRunOutput.Contains("Relocate source:")) "relocate dry-run should show source path."
        Assert-True ($relocateDryRunOutput.Contains("Relocate target:")) "relocate dry-run should show target path."
        Assert-True ($relocateDryRunOutput.Contains([System.IO.Path]::GetFullPath($relocateSourceDir))) "relocate dry-run should show registry source path."
        Assert-True ($relocateDryRunOutput.Contains([System.IO.Path]::GetFullPath($relocateTargetDir))) "relocate dry-run should show WSL_install_dir target path."
        Assert-True ($relocateDryRunOutput.Contains("--export $relocateName")) "relocate dry-run should export the current instance."
        Assert-True ($relocateDryRunOutput.Contains("--unregister $relocateName")) "relocate dry-run should unregister the old instance."
        Assert-True ($relocateDryRunOutput.Contains("--import $relocateName")) "relocate dry-run should import the same instance name."
        Assert-True (-not $relocateDryRunOutput.Contains("--manage $relocateName --move")) "relocate should not use native move."
        Assert-MockWslNotCalled $ArgsFile "relocate dry-run"

        Invoke-Checked $relocateEntryFile @(".relocate", $relocateTargetDir) 1 "relocate rejects positional target"

        $sameRelocateName = "wsl.smoke-relocate-same-" + [guid]::NewGuid().ToString("N").Substring(0, 8)
        $sameRelocateDir = Join-Path $TempRoot "relocate-same"
        $sameRelocateEntryFile = New-WslSmokeEntryFile -Name $sameRelocateName -InstallDir $sameRelocateDir -BackupDir (Join-Path $TempRoot "relocate-same-backup") -User "john"
        [void]$fakeRegistryKeys.Add((New-FakeWslDistributionRecord -Name $sameRelocateName -BasePath ([System.IO.Path]::GetFullPath($sameRelocateDir))))
        $sameRelocateOutput = Invoke-Captured $sameRelocateEntryFile @(".relocate", "--dry-run") 1 "relocate rejects unchanged target"
        Assert-True ($sameRelocateOutput.Contains("already matches WSL_install_dir")) "relocate should reject unchanged target."
    } finally {
        if ($relocateEntryFile -and (Test-Path -LiteralPath $relocateEntryFile)) {
            Remove-Item -LiteralPath $relocateEntryFile -Force
        }
        if ($sameRelocateEntryFile -and (Test-Path -LiteralPath $sameRelocateEntryFile)) {
            Remove-Item -LiteralPath $sameRelocateEntryFile -Force
        }
        foreach ($keyPath in @($fakeRegistryKeys)) {
            if (Test-Path -LiteralPath $keyPath) {
                Remove-Item -LiteralPath $keyPath -Recurse -Force
            }
        }
    }
}
