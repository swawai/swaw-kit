function Invoke-ControlNativeCommand {
    param(
        [string[]]$NativeArgs
    )

    return (Invoke-External "wsl.exe" $NativeArgs)
}


function Set-WslDefaultUser {
    param([string[]]$Rest)

    $user = if ($Rest.Count -gt 0 -and -not [string]::IsNullOrWhiteSpace($Rest[0])) { $Rest[0] } else { $script:Config.User }
    if ([string]::IsNullOrWhiteSpace($user)) {
        Write-Fail "No user provided and WSL_user is empty."
        return 1
    }

    $nativeArgs = @("--manage", $script:Config.Name, "--set-default-user", $user)
    return (Invoke-ControlNativeCommand $nativeArgs)
}


function Require-Yes {
    param(
        [string]$Action,
        [string[]]$Rest
    )

    if ($Rest -contains "--yes") {
        return $true
    }

    Write-Fail "$Action requires --yes."
    return $false
}


function Stop-WslResource {
    $nativeArgs = @("--terminate", $script:Config.Name)
    return (Invoke-ControlNativeCommand $nativeArgs)
}


function Stop-WslGlobal {
    return (Invoke-ControlNativeCommand @("--shutdown"))
}

