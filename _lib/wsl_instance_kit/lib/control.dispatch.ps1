function Invoke-VmControl {
    param(
        [string[]]$Rest,
        [string]$Verb = "vm"
    )

    if ($Rest.Count -eq 0) {
        return Show-CommandHelpHint "$Verb requires a command."
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
        "-t" {
            if ($tail.Count -ne 0) {
                return Show-CommandHelpHint "$Verb -t does not accept extra arguments."
            }

            return Stop-WslVm
        }
        "shutdown" {
            if ($tail.Count -ne 0) {
                return Show-CommandHelpHint "$Verb shutdown does not accept extra arguments."
            }

            return Stop-WslVm
        }
        "settings" {
            if ($tail.Count -ne 0) {
                Write-Fail "$Verb settings does not accept extra arguments."
                return 1
            }

            return Open-WslSettings
        }
        "welcome" {
            if ($tail.Count -ne 0) {
                Write-Fail "$Verb welcome does not accept extra arguments."
                return 1
            }

            return Open-WslWelcome
        }
        "alive" {
            return Invoke-WslVmAlive $tail
        }
        default {
            return Show-CommandHelpHint "Unknown VM command: $action"
        }
    }
}


function Invoke-Control {
    param(
        [string[]]$Rest,
        [string]$Verb = "ctl"
    )

    if ($Rest.Count -eq 0) {
        return Show-CommandHelpHint "$Verb requires a command."
    }

    $action = $Rest[0].ToLowerInvariant()
    $tail = @(Get-Slice $Rest 1)

    switch ($action) {
        "-t" {
            return Stop-WslResource
        }
        "status" {
            return Show-WslResourceStatus
        }
        "doctor" {
            return Invoke-WslDoctor $tail
        }
        "install" {
            return Invoke-InstallControl $tail
        }
        "backup" {
            return Invoke-BackupControl $tail
        }
        "export" {
            return Export-WslResource $tail
        }
        "restore" {
            return Restore-WslResource $tail
        }
        "alive" {
            return Invoke-WslAlive $tail
        }
        { $_ -in @("download", "downloads") } {
            return Invoke-DownloadControl -Rest $tail -Verb $action
        }
        "config" {
            if ($tail.Count -eq 0) {
                return Show-CommandHelpHint "$Verb config requires dir."
            }

            $configAction = $tail[0].ToLowerInvariant()
            if ($configAction -eq "dir") {
                if ($tail.Count -ne 1) {
                    return Show-CommandHelpHint "$Verb config dir does not accept extra arguments."
                }

                return Open-WslInstanceConfig
            }

            return Show-CommandHelpHint "Unknown control command: $action $configAction"
        }
        "port" {
            return Invoke-PortControl $tail
        }
        "user" {
            if ($tail.Count -eq 0) {
                return Show-CommandHelpHint "$Verb user requires a command."
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
                    return Show-CommandHelpHint "Unknown control command: $action $userAction"
                }
            }
        }
        "ssh" {
            if ($tail.Count -eq 0) {
                return Show-CommandHelpHint "$Verb ssh requires a command."
            }

            $sshAction = $tail[0].ToLowerInvariant()
            $sshTail = @(Get-Slice $tail 1)
            switch ($sshAction) {
                "status" {
                    return Show-WslSshStatus
                }
                "config" {
                    return Open-WslSshConfig
                }
                "enable" {
                    return Enable-WslSsh $sshTail
                }
                "disable" {
                    return Disable-WslSsh
                }
            }

            return Show-CommandHelpHint "Unknown control command: $action $sshAction"
        }
        "systemd" {
            if ($tail.Count -eq 0) {
                return Show-CommandHelpHint "$Verb systemd requires a command."
            }

            $systemdAction = $tail[0].ToLowerInvariant()
            if ($systemdAction -in @("enable", "disable")) {
                return Set-WslSystemd $systemdAction
            }
            if ($systemdAction -eq "status") {
                if ($tail.Count -ne 1) {
                    return Show-CommandHelpHint "$Verb systemd status does not accept extra arguments."
                }

                return Show-WslSystemdStatus
            }

            return Show-CommandHelpHint "Unknown control command: $action $systemdAction"
        }
        "default" {
            $nativeArgs = @("--set-default", $script:Config.Name)
            return (Invoke-ControlNativeCommand $nativeArgs)
        }
        "terminate" {
            return Stop-WslResource
        }
        "remove" {
            if (-not (Require-Yes "$Verb remove" $tail)) {
                return 1
            }
            $aliveExit = Remove-WslAliveTask -Quiet
            if ($aliveExit -ne 0) {
                return $aliveExit
            }
            $nativeArgs = @("--unregister", $script:Config.Name)
            return (Invoke-ControlNativeCommand $nativeArgs)
        }
        default {
            return Show-CommandHelpHint "Unknown control command: $action"
        }
    }
}
