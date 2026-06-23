function Test-LinuxUserName {
    param([AllowNull()] [string]$User)

    if ([string]::IsNullOrWhiteSpace($User)) {
        return $false
    }

    return $User -match '^[a-z_][a-z0-9_-]*[$]?$'
}

function Get-EnsureWslUserScript {
    param([string]$User)

    $userArg = "'$User'"
    $parts = @(
        "set -eu",
        "created_user=0",
        "if ! id -u $userArg >/dev/null 2>&1; then if command -v useradd >/dev/null 2>&1; then if [ -x /bin/bash ]; then useradd -m -s /bin/bash $userArg; else useradd -m -s /bin/sh $userArg; fi; created_user=1",
        "elif command -v adduser >/dev/null 2>&1; then if adduser --help 2>&1 | grep -q -- `"--disabled-password`"; then if [ -x /bin/bash ]; then adduser --disabled-password --gecos `"`" --shell /bin/bash $userArg; else adduser --disabled-password --gecos `"`" --shell /bin/sh $userArg; fi; created_user=1",
        "else if [ -x /bin/bash ]; then adduser -D -s /bin/bash $userArg; else adduser -D -s /bin/sh $userArg; fi; created_user=1",
        "fi",
        "else echo `"No useradd/adduser command found.`" >&2",
        "exit 1",
        "fi",
        "fi",
        "if [ `"`$created_user`" = 1 ] && command -v passwd >/dev/null 2>&1; then passwd -d $userArg >/dev/null 2>&1 || true; fi",
        "if command -v usermod >/dev/null 2>&1; then if [ -x /bin/bash ] && [ `"`$(getent passwd $userArg | cut -d: -f7)`" != /bin/bash ]; then usermod -s /bin/bash $userArg; elif [ ! -x /bin/bash ] && [ -x /bin/sh ] && [ `"`$(getent passwd $userArg | cut -d: -f7)`" != /bin/sh ]; then usermod -s /bin/sh $userArg; fi; if command -v getent >/dev/null 2>&1 && getent group sudo >/dev/null 2>&1 && ! id -nG $userArg | tr ' ' '\n' | grep -qx sudo; then usermod -aG sudo $userArg; fi",
        "fi"
    )

    return ($parts -join "; ")
}

function Get-EnsureWslUserNativeCommands {
    param([string]$User)

    $script = Get-EnsureWslUserScript $User
    $runner = New-Base64ShRunner $script
    return @(
        [pscustomobject]@{
            File = "wsl.exe"
            Args = @("-d", $script:Config.Name, "-u", "root", "--", "sh", "-lc", $runner)
        }
    )
}

function Invoke-EnsureWslUser {
    param(
        [string]$User,
        [switch]$DryRun
    )

    if ([string]::IsNullOrWhiteSpace($User)) {
        return 0
    }

    if (-not (Test-LinuxUserName $User)) {
        Write-Fail "Invalid Linux username: $User"
        return 1
    }

    foreach ($command in @(Get-EnsureWslUserNativeCommands $User)) {
        if ($DryRun) {
            Show-NativeCommand $command.File $command.Args
            continue
        }

        $exitCode = Invoke-External $command.File $command.Args
        if ($exitCode -ne 0) {
            return $exitCode
        }
    }

    return 0
}

function Set-WslUserPassword {
    param([string[]]$Rest)

    $user = ""
    $envName = ""
    $i = 0
    while ($i -lt $Rest.Count) {
        $item = [string]$Rest[$i]
        if ($item -eq "--env") {
            if (-not [string]::IsNullOrWhiteSpace($envName)) {
                Write-Fail ".user passwd accepts at most one --env option."
                return 1
            }
            $i += 1
            if ($i -ge $Rest.Count -or [string]::IsNullOrWhiteSpace($Rest[$i])) {
                Write-Fail ".user passwd --env requires an environment variable name."
                return 1
            }
            $envName = [string]$Rest[$i]
        } elseif ($item.StartsWith("-")) {
            Write-Fail "Unknown .user passwd option: $item"
            return 1
        } elseif ([string]::IsNullOrWhiteSpace($user)) {
            $user = $item
        } else {
            Write-Fail ".user passwd accepts at most one user argument."
            return 1
        }

        $i += 1
    }

    if ([string]::IsNullOrWhiteSpace($user)) {
        $user = $script:Config.User
    }
    if ([string]::IsNullOrWhiteSpace($user)) {
        Write-Fail "No user provided and WSL_user is empty."
        return 1
    }
    if (-not (Test-LinuxUserName $user)) {
        Write-Fail "Invalid Linux username: $user"
        return 1
    }

    if ([string]::IsNullOrWhiteSpace($envName)) {
        $nativeArgs = @("-d", $script:Config.Name, "-u", "root", "--", "passwd", $user)
        return (Invoke-ControlNativeCommand $nativeArgs)
    }

    if ($envName -notmatch '^[A-Za-z_][A-Za-z0-9_]*$') {
        Write-Fail "Invalid environment variable name: $envName"
        return 1
    }

    $password = [Environment]::GetEnvironmentVariable($envName, "Process")
    if ([string]::IsNullOrEmpty($password)) {
        Write-Fail "Environment variable is empty or not found: $envName"
        return 1
    }
    if ($password.Contains("`n") -or $password.Contains("`r")) {
        Write-Fail "Environment variable contains a newline and cannot be used as a password: $envName"
        return 1
    }

    $passwordInput = "${user}:$password`n"
    $password = $null
    $nativeArgs = @("-d", $script:Config.Name, "-u", "root", "--", "sh", "-lc", "chpasswd")
    $exitCode = Invoke-ExternalWithInput "wsl.exe" $nativeArgs $passwordInput
    $passwordInput = $null
    return $exitCode
}

function Ensure-WslConfiguredUser {
    param(
        [string[]]$Rest,
        [switch]$DryRun,
        [switch]$AllowEmpty
    )

    $user = if ($Rest.Count -gt 0 -and -not [string]::IsNullOrWhiteSpace($Rest[0])) {
        $Rest[0]
    } else {
        $script:Config.User
    }

    if ([string]::IsNullOrWhiteSpace($user)) {
        if ($AllowEmpty) {
            return 0
        }

        Write-Fail "No user provided and WSL_user is empty."
        return 1
    }

    return (Invoke-EnsureWslUser -User $user -DryRun:$DryRun)
}
