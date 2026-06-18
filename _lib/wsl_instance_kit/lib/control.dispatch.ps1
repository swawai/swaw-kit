function Invoke-VmControl {
    param(
        [string[]]$Rest,
        [string]$Verb = ".vm"
    )

    if ($Rest.Count -eq 0) {
        return Open-WslSettings
    }

    $action = $Rest[0].ToLowerInvariant()
    $tail = @(Get-Slice $Rest 1)

    switch ($action) {
        "status" {
            if ($tail.Count -ne 0) {
                return Show-CommandHelpHint "$Verb status does not accept extra arguments."
            }

            return Show-WslVmStatus
        }
        "-s" {
            if ($tail.Count -ne 0) {
                return Show-CommandHelpHint "$Verb -s does not accept extra arguments."
            }

            return Stop-WslVm
        }
        "show" {
            if ($tail.Count -ne 0) {
                Write-Fail "$Verb show does not accept extra arguments."
                return 1
            }

            return Open-WslWelcome
        }
        "default" {
            if ($tail.Count -ne 0) {
                return Show-CommandHelpHint "$Verb default does not accept extra arguments."
            }

            $nativeArgs = @("--set-default", $script:Config.Name)
            return (Invoke-ControlNativeCommand $nativeArgs)
        }
        "alive" {
            return Invoke-WslVmAlive $tail
        }
        "port" {
            return Invoke-WslVmPort $tail
        }
        default {
            return Show-CommandHelpHint "Unknown .vm command: $action"
        }
    }
}


function Invoke-DirControl {
    param(
        [string[]]$Rest,
        [string]$Verb = ".dir"
    )

    if ($Rest.Count -eq 0) {
        return Show-CommandHelpHint "$Verb requires install, backup, downloads, config, or ssh."
    }

    $target = $Rest[0].ToLowerInvariant()
    $tail = @(Get-Slice $Rest 1)

    switch ($target) {
        "install" {
            return Open-WslInstallDir -Rest $tail
        }
        "backup" {
            return Open-WslBackupDir -Rest $tail
        }
        "downloads" {
            return Open-WslDownloadDir -Rest $tail
        }
        "config" {
            if ($tail.Count -ne 0) {
                return Show-CommandHelpHint "$Verb config does not accept extra arguments."
            }

            return Open-WslInstanceConfig
        }
        "ssh" {
            if ($tail.Count -ne 0) {
                return Show-CommandHelpHint "$Verb ssh does not accept extra arguments."
            }

            return Open-WslSshConfig
        }
        default {
            return Show-CommandHelpHint "Unknown directory target: $target"
        }
    }
}


function Invoke-InstanceManagementCommand {
    param([string[]]$Rest)

    if ($Rest.Count -eq 0) {
        return Show-CommandHelpHint "Instance management command is missing."
    }

    $action = $Rest[0].ToLowerInvariant()
    $tail = @(Get-Slice $Rest 1)

    switch ($action) {
        "t" {
            return Stop-WslResource
        }
        "install" {
            return Install-WslResource $tail
        }
        "backup" {
            return Invoke-BackupControl $tail
        }
        "dir" {
            return Invoke-DirControl -Rest $tail
        }
        "alive" {
            return Invoke-WslAlive $tail
        }
        "port" {
            return Invoke-PortControl $tail
        }
        "user" {
            if ($tail.Count -eq 0) {
                return Show-CommandHelpHint ".user requires a command."
            }

            $userAction = $tail[0].ToLowerInvariant()
            $userTail = @(Get-Slice $tail 1)
            switch ($userAction) {
                "ensure" {
                    return Ensure-WslConfiguredUser $userTail
                }
                "default" {
                    return Set-WslDefaultUser $userTail
                }
                default {
                    return Show-CommandHelpHint "Unknown .user command: $userAction"
                }
            }
        }
        "sshd" {
            if ($tail.Count -eq 0) {
                return Show-CommandHelpHint ".sshd requires a command."
            }

            $sshAction = $tail[0].ToLowerInvariant()
            $sshTail = @(Get-Slice $tail 1)
            switch ($sshAction) {
                "status" {
                    if ($sshTail.Count -ne 0) {
                        return Show-CommandHelpHint ".sshd status does not accept extra arguments."
                    }

                    return Show-WslSshStatus
                }
                "enable" {
                    return Enable-WslSsh $sshTail
                }
                "disable" {
                    if ($sshTail.Count -ne 0) {
                        return Show-CommandHelpHint ".sshd disable does not accept extra arguments."
                    }

                    return Disable-WslSsh
                }
            }

            return Show-CommandHelpHint "Unknown sshd command: $sshAction"
        }
        "systemd" {
            if ($tail.Count -eq 0) {
                return Show-CommandHelpHint ".systemd requires a command."
            }

            $systemdAction = $tail[0].ToLowerInvariant()
            if ($systemdAction -in @("enable", "disable")) {
                return Set-WslSystemd $systemdAction
            }
            if ($systemdAction -eq "status") {
                if ($tail.Count -ne 1) {
                    return Show-CommandHelpHint ".systemd status does not accept extra arguments."
                }

                return Show-WslSystemdStatus
            }

            return Show-CommandHelpHint "Unknown .systemd command: $systemdAction"
        }
        "delete" {
            $removeYes = $false
            $removeUac = $false
            foreach ($item in @($tail)) {
                switch ($item) {
                    "--yes" {
                        $removeYes = $true
                        continue
                    }
                    "--uac" {
                        $removeUac = $true
                        continue
                    }
                    default {
                        Write-Fail "Unknown delete option: $item"
                        return 1
                    }
                }
            }

            if (-not $removeYes) {
                Write-Fail ".delete requires --yes."
                return 1
            }

            $managedPortItems = @(Get-WslManagedPortItems -InstanceName $script:Config.Name)
            if ($managedPortItems.Count -gt 0 -and -not (Test-WslKitAdmin)) {
                if (-not $removeUac) {
                    Write-Fail "Managed port rules require administrator cleanup before removing this instance."
                    Write-Fail "Run again with --uac to request elevation:"
                    Write-Fail "  $(Format-CommandLine $script:Config.CommandName @(".delete", "--yes", "--uac"))"
                    return 1
                }

                return (Invoke-WslKitElevatedCommand -CommandArgs @(".delete", "--yes"))
            }

            $aliveExit = Remove-WslAliveTask -Quiet
            if ($aliveExit -ne 0) {
                return $aliveExit
            }

            if ($managedPortItems.Count -gt 0) {
                $portExit = Remove-WslManagedPortRulesForInstance -InstanceName $script:Config.Name -Quiet
                if ($portExit -ne 0) {
                    return $portExit
                }
            }

            $nativeArgs = @("--unregister", $script:Config.Name)
            return (Invoke-ControlNativeCommand $nativeArgs)
        }
        "moveto" {
            return Invoke-WslMoveTo $tail
        }
        default {
            return Show-CommandHelpHint "Unknown tool command: .$action"
        }
    }
}
