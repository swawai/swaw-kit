function Resolve-WslStatusPath {
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


function Show-WslConfiguredStatus {
    $envFile = Resolve-WslEnvironmentFilePath
    if ([string]::IsNullOrWhiteSpace($envFile)) {
        Write-Host "  WSL_env_file:        (not configured)"
    } else {
        Write-Host "  WSL_env_file:        $envFile"
    }

    if ([string]::IsNullOrWhiteSpace($script:Config.SshPublicKey)) {
        Write-Host "  WSL_SSH_public_key:  (not configured)"
        Write-Host "  SSH key hint:        set WSL_SSH_public_key before .sshd enable"
        return
    }

    $sshPublicKey = Resolve-WslStatusPath $script:Config.SshPublicKey
    if (Test-Path -LiteralPath $sshPublicKey -PathType Leaf) {
        Write-Host "  WSL_SSH_public_key:  $sshPublicKey"
    } else {
        Write-Host "  WSL_SSH_public_key:  (not found) $sshPublicKey" -ForegroundColor Yellow
    }
}


function Get-WslUserPasswordStatus {
    param([AllowNull()] [string]$RuntimeState)

    if ([string]::IsNullOrWhiteSpace($script:Config.User)) {
        return [pscustomobject]@{
            Text = "(not checked; WSL_user is empty)"
            Color = ""
            Hint = ""
        }
    }

    if ($RuntimeState -ine "Running") {
        return [pscustomobject]@{
            Text = "not checked (instance not running)"
            Color = ""
            Hint = ""
        }
    }

    $result = Invoke-WslNativeTextCommand @("-d", $script:Config.Name, "-u", "root", "--", "passwd", "-S", $script:Config.User)
    if ($result.ExitCode -ne 0 -or $result.Output.Count -eq 0) {
        return [pscustomobject]@{
            Text = "unknown"
            Color = "Yellow"
            Hint = ""
        }
    }

    $parts = @(([string]$result.Output[0]).Trim() -split "\s+")
    $code = if ($parts.Count -gt 1) { $parts[1] } else { "" }
    switch ($code) {
        "P" {
            return [pscustomobject]@{
                Text = "set"
                Color = "Green"
                Hint = ""
            }
        }
        "L" {
            return [pscustomobject]@{
                Text = "locked"
                Color = "Yellow"
                Hint = "$($script:Config.CommandName) .user passwd"
            }
        }
        "NP" {
            return [pscustomobject]@{
                Text = "not set"
                Color = "Yellow"
                Hint = "$($script:Config.CommandName) .user passwd"
            }
        }
        default {
            return [pscustomobject]@{
                Text = "unknown ($code)"
                Color = "Yellow"
                Hint = ""
            }
        }
    }
}


function Show-WslUserPasswordStatus {
    param([AllowNull()] [string]$RuntimeState)

    $status = Get-WslUserPasswordStatus $RuntimeState
    if ([string]::IsNullOrWhiteSpace($status.Color)) {
        Write-Host "  User password:       $($status.Text)"
    } else {
        Write-Host "  User password:       $($status.Text)" -ForegroundColor $status.Color
    }
    if (-not [string]::IsNullOrWhiteSpace($status.Hint)) {
        Write-Host "  Password next:       $($status.Hint)" -ForegroundColor Yellow
    }
}
