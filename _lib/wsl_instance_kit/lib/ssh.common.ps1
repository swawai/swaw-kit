function Resolve-WslSshPort {
    param(
        [string[]]$Rest,
        [switch]$AllowEmpty
    )

    $portArgs = @($Rest)
    if ($portArgs.Count -gt 1) {
        Write-Fail ".sshd enable accepts exactly one port argument."
        return $null
    }

    $rawPort = if ($portArgs.Count -gt 0) { $portArgs[0] } else { "" }
    if ([string]::IsNullOrWhiteSpace($rawPort)) {
        if ($AllowEmpty) {
            return ""
        }

        Write-Fail "SSH port is required. Run: $($script:Config.CommandName) .sshd enable <port>"
        return $null
    }

    $port = 0
    if (-not [int]::TryParse($rawPort.Trim(), [ref]$port) -or $port -lt 1 -or $port -gt 65535) {
        Write-Fail "SSH port must be an integer from 1 to 65535."
        return $null
    }

    return $port
}


function Resolve-WindowsSshPublicKeyPath {
    $rawPath = $script:Config.SshPublicKey
    if ([string]::IsNullOrWhiteSpace($rawPath)) {
        return ""
    }

    $expanded = [Environment]::ExpandEnvironmentVariables($rawPath.Trim())
    if (-not [System.IO.Path]::IsPathRooted($expanded)) {
        $expanded = [System.IO.Path]::GetFullPath((Join-Path $script:Config.EntryDir $expanded))
    } else {
        $expanded = [System.IO.Path]::GetFullPath($expanded)
    }

    if (Test-Path -LiteralPath $expanded -PathType Leaf) {
        return $expanded
    }

    return ""
}


function Get-WindowsSshPublicKeyBase64 {
    param([switch]$Optional)

    $publicKeyPath = Resolve-WindowsSshPublicKeyPath
    if ([string]::IsNullOrWhiteSpace($publicKeyPath)) {
        return [pscustomobject]@{
            Path = ""
            Base64 = ""
        }
    }

    $line = Get-Content -LiteralPath $publicKeyPath | Where-Object { -not [string]::IsNullOrWhiteSpace($_) } | Select-Object -First 1
    if (-not $line) {
        if ($Optional) {
            return [pscustomobject]@{
                Path = $publicKeyPath
                Base64 = ""
            }
        }

        Write-Fail "SSH public key file is empty: $publicKeyPath"
        return $null
    }

    $line = ([string]$line -replace "^\uFEFF", "") -replace "`r$", ""
    $bytes = [System.Text.Encoding]::UTF8.GetBytes($line)
    return [pscustomobject]@{
        Path = $publicKeyPath
        Base64 = [Convert]::ToBase64String($bytes)
    }
}


function Test-WindowsTcpPortAvailable {
    param([int]$Port)

    $listeners = @(Get-NetTCPConnection -LocalPort $Port -State Listen -ErrorAction SilentlyContinue)
    if ($listeners.Count -eq 0) {
        return $true
    }

    Write-Fail "Windows is already listening on TCP port $Port."
    foreach ($listener in $listeners) {
        $process = Get-Process -Id $listener.OwningProcess -ErrorAction SilentlyContinue
        $processName = if ($null -eq $process) { "pid $($listener.OwningProcess)" } else { "$($process.ProcessName) (pid $($listener.OwningProcess))" }
        Write-Fail "  $($listener.LocalAddress):$($listener.LocalPort) $processName"
    }
    Write-Fail "Choose another SSH port or stop the Windows-side listener first."
    return $false
}


function Test-WslTcpPortAvailable {
    param([int]$Port)

    $scriptText = @"
set -u
port="$Port"
if command -v ss >/dev/null 2>&1; then
    lines=`$(ss -ltnp 2>/dev/null | grep -E ":`$port[[:space:]]" || true)
elif command -v netstat >/dev/null 2>&1; then
    lines=`$(netstat -ltnp 2>/dev/null | grep -E ":`$port[[:space:]]" || true)
else
    lines=
fi

if [ -z "`$lines" ]; then
    exit 0
fi

if printf '%s\n' "`$lines" | grep -q 'sshd'; then
    exit 0
fi

printf '%s\n' "`$lines" >&2
exit 2
"@

    $runner = New-Base64ShRunner $scriptText
    $nativeArgs = @("-d", $script:Config.Name, "-u", "root", "--", "sh", "-lc", $runner)
    $exitCode = Invoke-External "wsl.exe" $nativeArgs
    if ($exitCode -eq 0) {
        return $true
    }

    Write-Fail "WSL is already listening on TCP port $Port."
    Write-Fail "Choose another SSH port or stop the WSL-side listener first."
    return $false
}


function Test-WslSystemdRuntimeActive {
    $scriptText = '[ "$(ps -p 1 -o comm= 2>/dev/null | tr -d '' '')" = systemd ] && command -v systemctl >/dev/null 2>&1 && systemctl list-unit-files --no-pager >/dev/null 2>&1'
    $nativeArgs = @("-d", $script:Config.Name, "-u", "root", "--", "sh", "-lc", $scriptText)
    return ((Invoke-External "wsl.exe" $nativeArgs) -eq 0)
}


function Ensure-WslSshSystemdReady {
    if (-not (Test-WslSystemdRuntimeActive)) {
        Write-Fail ".sshd enable requires active systemd in this WSL instance."
        Write-Fail "Run: $($script:Config.CommandName) .systemd enable"
        Write-Fail "Then restart WSL: $($script:Config.CommandName) .vm -s"
        Write-Fail "After restart, run .sshd enable again."
        return $false
    }

    return $true
}


function Invoke-WslSshScript {
    param([string]$ScriptText)

    $runner = New-Base64ShRunner $ScriptText
    $nativeArgs = @("-d", $script:Config.Name, "-u", "root", "--", "sh", "-lc", $runner)
    return (Invoke-ControlNativeCommand $nativeArgs)
}
