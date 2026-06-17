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
        "if ! id -u $userArg >/dev/null 2>&1; then if command -v useradd >/dev/null 2>&1; then if [ -x /bin/bash ]; then useradd -m -s /bin/bash $userArg; else useradd -m -s /bin/sh $userArg; fi",
        "elif command -v adduser >/dev/null 2>&1; then if adduser --help 2>&1 | grep -q -- `"--disabled-password`"; then if [ -x /bin/bash ]; then adduser --disabled-password --gecos `"`" --shell /bin/bash $userArg; else adduser --disabled-password --gecos `"`" --shell /bin/sh $userArg; fi",
        "else if [ -x /bin/bash ]; then adduser -D -s /bin/bash $userArg; else adduser -D -s /bin/sh $userArg; fi",
        "fi",
        "else echo `"No useradd/adduser command found.`" >&2",
        "exit 1",
        "fi",
        "fi",
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
