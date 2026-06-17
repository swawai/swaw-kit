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
        "install" {
            return Install-WslResource $tail
        }
        "backup" {
            return Invoke-BackupControl $tail
        }
        "export" {
            return Export-WslResource $tail
        }
        { $_ -in @("download", "downloads") } {
            return Invoke-DownloadControl -Rest $tail -Verb $action
        }
        "config" {
            return Open-WslInstanceConfig
        }
        "settings" {
            if ($tail.Count -ne 0) {
                Write-Fail "ctl settings does not accept extra arguments."
                return 1
            }

            return Open-WslSettings
        }
        "port" {
            return Invoke-PortControl $tail
        }
        "global" {
            if ($tail.Count -eq 0) {
                return Show-CommandHelpHint "$Verb global requires a command."
            }

            $globalAction = $tail[0].ToLowerInvariant()
            switch ($globalAction) {
                "-t" {
                    return Stop-WslGlobal
                }
                "shutdown" {
                    return Stop-WslGlobal
                }
                default {
                    return Show-CommandHelpHint "Unknown control command: $action $globalAction"
                }
            }
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
            $nativeArgs = @("--unregister", $script:Config.Name)
            return (Invoke-ControlNativeCommand $nativeArgs)
        }
        default {
            return Show-CommandHelpHint "Unknown control command: $action"
        }
    }
}
