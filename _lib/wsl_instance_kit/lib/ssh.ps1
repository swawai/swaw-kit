function Resolve-WslSshPort {
    param(
        [string[]]$Rest,
        [switch]$AllowEmpty
    )

    $rawPort = if ($Rest.Count -gt 0 -and -not [string]::IsNullOrWhiteSpace($Rest[0])) {
        $Rest[0]
    } else {
        $script:Config.SshPort
    }

    if ([string]::IsNullOrWhiteSpace($rawPort)) {
        if ($AllowEmpty) {
            return ""
        }

        return 22
    }

    $port = 0
    if (-not [int]::TryParse($rawPort.Trim(), [ref]$port) -or $port -lt 1 -or $port -gt 65535) {
        Write-Fail "SSH port must be an integer from 1 to 65535."
        return $null
    }

    return $port
}

function Resolve-WindowsSshPublicKeyPath {
    $rawPath = $script:Config.SshKey
    if ([string]::IsNullOrWhiteSpace($rawPath)) {
        return ""
    }

    $expanded = [Environment]::ExpandEnvironmentVariables($rawPath.Trim())
    if (-not [System.IO.Path]::IsPathRooted($expanded)) {
        $expanded = [System.IO.Path]::GetFullPath((Join-Path $script:Config.EntryDir $expanded))
    } else {
        $expanded = [System.IO.Path]::GetFullPath($expanded)
    }

    $candidates = @()
    if ($expanded.EndsWith(".pub", [System.StringComparison]::OrdinalIgnoreCase)) {
        $candidates += $expanded
    } else {
        $candidates += "$expanded.pub"
    }

    foreach ($candidate in $candidates) {
        if (Test-Path -LiteralPath $candidate -PathType Leaf) {
            return $candidate
        }
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
    Write-Fail "Choose another WSL_SSH_port or stop the Windows-side listener first."
    return $false
}

function Test-WslTcpPortAvailable {
    param([int]$Port)

    $scriptText = @"
set -u
port="$Port"
if command -v ss >/dev/null 2>&1; then
    lines=`$(ss -ltnp 2>/dev/null | awk -v suffix=":`$port" 'NR > 1 && `$4 ~ suffix "$" { print }')
elif command -v netstat >/dev/null 2>&1; then
    lines=`$(netstat -ltnp 2>/dev/null | awk -v suffix=":`$port" 'NR > 2 && `$4 ~ suffix "$" { print }')
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
    Write-Fail "Choose another WSL_SSH_port or stop the WSL-side listener first."
    return $false
}

function Test-WslSshSystemdEntryEnabled {
    $value = $script:Config.Systemd
    if ([string]::IsNullOrWhiteSpace($value) -or $value.Trim().ToLowerInvariant() -ne "enable") {
        Write-Fail "ctl ssh enable requires WSL_systemd=enable in the entry file."
        Write-Fail "SSH enable is systemd-managed; update the entry file, then run ctl ssh enable again."
        return $false
    }

    return $true
}

function Test-WslSystemdConfigEnabled {
    $scriptText = @'
awk '
BEGIN { in_boot = 0; found = 0 }
/^[[:space:]]*\[[^]]+\][[:space:]]*$/ {
    section = $0
    sub(/^[[:space:]]*\[/, "", section)
    sub(/\][[:space:]]*$/, "", section)
    in_boot = (section == "boot")
    next
}
in_boot && /^[[:space:]]*systemd[[:space:]]*=/ {
    value = $0
    sub(/^[^=]*=/, "", value)
    gsub(/^[[:space:]]+|[[:space:]]+$/, "", value)
    if (tolower(value) == "true") {
        found = 1
    }
}
END { exit found ? 0 : 1 }
' /etc/wsl.conf 2>/dev/null
'@

    $runner = New-Base64ShRunner $scriptText
    $nativeArgs = @("-d", $script:Config.Name, "-u", "root", "--", "sh", "-lc", $runner)
    return ((Invoke-External "wsl.exe" $nativeArgs) -eq 0)
}

function Test-WslSystemdRuntimeActive {
    $scriptText = '[ "$(ps -p 1 -o comm= 2>/dev/null | tr -d '' '')" = systemd ] && command -v systemctl >/dev/null 2>&1'
    $nativeArgs = @("-d", $script:Config.Name, "-u", "root", "--", "sh", "-lc", $scriptText)
    return ((Invoke-External "wsl.exe" $nativeArgs) -eq 0)
}

function Ensure-WslSshSystemdReady {
    if (-not (Test-WslSshSystemdEntryEnabled)) {
        return $false
    }

    if (-not (Test-WslSystemdConfigEnabled)) {
        Write-Host "Applying /etc/wsl.conf systemd=true because WSL_systemd=enable."
        $exitCode = Set-WslSystemd "enable"
        if ($exitCode -ne 0) {
            return $false
        }
    }

    if (-not (Test-WslSystemdRuntimeActive)) {
        Write-Fail "systemd is configured but not active in this WSL instance yet."
        Write-Fail "Restart WSL, then run ctl ssh enable again: $($script:Config.CommandName) ctl global shutdown"
        return $false
    }

    return $true
}

function Show-WslSshStatus {
    $entryPort = Resolve-WslSshPort @() -AllowEmpty
    if ($null -eq $entryPort) {
        return 1
    }
    $entryPortText = if ([string]::IsNullOrWhiteSpace($entryPort)) { "(not set)" } else { [string]$entryPort }

    if ($null -eq (Get-WslDistributionRecord)) {
        Write-Fail "WSL instance is not installed: $($script:Config.Name)"
        return 1
    }

    $publicKey = Get-WindowsSshPublicKeyBase64 -Optional
    if ($null -eq $publicKey) {
        $publicKey = [pscustomobject]@{
            Path = ""
            Base64 = ""
        }
    }

    Write-Host "WSL SSH status: $($script:Config.Name)"
    if ([string]::IsNullOrWhiteSpace($publicKey.Path)) {
        Write-Host "  Windows public key:     (not found from WSL_SSH_key)"
    } else {
        Write-Host "  Windows public key:     $($publicKey.Path)"
    }

    $user = $script:Config.User
$scriptText = @"
set -u
entry_port="$entryPortText"
target_user="$user"
pubkey_b64="$($publicKey.Base64)"
sshd_config=/etc/ssh/sshd_config

print_kv() {
    label="`$1"
    value="`$2"
    printf '  %-23s %s\n' "`$label:" "`$value"
}

find_sshd_bin() {
    if command -v sshd >/dev/null 2>&1; then
        command -v sshd
        return
    fi
    if [ -x /usr/sbin/sshd ]; then
        printf '%s\n' /usr/sbin/sshd
        return
    fi
    printf '\n'
}

detect_package_status() {
    if command -v dpkg-query >/dev/null 2>&1; then
        if dpkg-query -W -f='`${db:Status-Abbrev}' openssh-server 2>/dev/null | grep -q '^ii '; then
            printf '%s\n' installed
        else
            printf '%s\n' "not installed"
        fi
        return
    fi
    if command -v rpm >/dev/null 2>&1; then
        if rpm -q openssh-server >/dev/null 2>&1; then
            printf '%s\n' installed
        else
            printf '%s\n' "not installed"
        fi
        return
    fi
    if command -v apk >/dev/null 2>&1; then
        if apk info -e openssh-server >/dev/null 2>&1; then
            printf '%s\n' installed
        else
            printf '%s\n' "not installed"
        fi
        return
    fi
    if [ -n "`$(find_sshd_bin)" ]; then
        printf '%s\n' "installed (sshd found)"
    else
        printf '%s\n' unknown
    fi
}

has_systemd() {
    [ "`$(ps -p 1 -o comm= 2>/dev/null | tr -d ' ')" = "systemd" ] && command -v systemctl >/dev/null 2>&1
}

detect_systemd_ssh_unit() {
    if systemctl list-unit-files ssh.service --no-pager 2>/dev/null | grep -q '^ssh\.service'; then
        printf '%s\n' ssh
        return
    fi
    if systemctl list-unit-files sshd.service --no-pager 2>/dev/null | grep -q '^sshd\.service'; then
        printf '%s\n' sshd
        return
    fi
    printf '%s\n' ssh
}

detect_service_status() {
    if has_systemd; then
        unit=`$(detect_systemd_ssh_unit)
        active=`$(systemctl is-active "`$unit" 2>/dev/null || true)
        enabled=`$(systemctl is-enabled "`$unit" 2>/dev/null || true)
        [ -n "`$active" ] || active=unknown
        [ -n "`$enabled" ] || enabled=unknown
        print_kv "service manager" systemd
        print_kv "service unit" "`$unit"
        print_kv "service active" "`$active"
        print_kv "service enabled" "`$enabled"
        return
    fi

    print_kv "service manager" "service/pid"
    status=unknown
    if command -v service >/dev/null 2>&1; then
        if service ssh status >/dev/null 2>&1; then
            status=active
        elif service sshd status >/dev/null 2>&1; then
            status=active
        fi
    fi
    if [ "`$status" = unknown ] && pgrep -x sshd >/dev/null 2>&1; then
        status=active
    fi
    print_kv "service active" "`$status"
}

detect_port() {
    bin=`$(find_sshd_bin)
    if [ -n "`$bin" ]; then
        port=`$("`$bin" -T 2>/dev/null | awk 'tolower(`$1) == "port" { print `$2; exit }')
        if [ -n "`$port" ]; then
            printf '%s\n' "`$port"
            return
        fi
    fi

    if [ -f "`$sshd_config" ]; then
        port=`$(awk '
            /^[[:space:]]*#/ { next }
            tolower(`$1) == "port" { value = `$2 }
            END { if (value != "") print value }
        ' "`$sshd_config" 2>/dev/null)
        if [ -n "`$port" ]; then
            printf '%s\n' "`$port"
            return
        fi
    fi

    printf '%s\n' 22
}

detect_listening() {
    port="`$1"
    if command -v ss >/dev/null 2>&1; then
        ss -ltn 2>/dev/null | awk -v suffix=":`$port" '
            NR > 1 && `$4 ~ suffix "$" { found = 1 }
            END { print found ? "yes" : "no" }
        '
        return
    fi
    if command -v netstat >/dev/null 2>&1; then
        netstat -ltn 2>/dev/null | awk -v suffix=":`$port" '
            NR > 2 && `$4 ~ suffix "$" { found = 1 }
            END { print found ? "yes" : "no" }
        '
        return
    fi
    if pgrep -x sshd >/dev/null 2>&1; then
        printf '%s\n' "unknown (sshd running)"
    else
        printf '%s\n' unknown
    fi
}

detect_ips() {
    ips=`$(hostname -I 2>/dev/null | awk '{ for (i = 1; i <= NF; i++) if (`$i !~ /^fe80:/) print `$i }' | paste -sd ' ' -)
    if [ -n "`$ips" ]; then
        printf '%s\n' "`$ips"
        return
    fi
    if command -v ip >/dev/null 2>&1; then
        ips=`$(ip -o -4 addr show scope global 2>/dev/null | awk '{ sub(/\/.*/, "", `$4); print `$4 }' | paste -sd ' ' -)
        [ -n "`$ips" ] && printf '%s\n' "`$ips" && return
    fi
    printf '%s\n' unknown
}

show_authorized_keys_status() {
    if [ -z "`$target_user" ]; then
        print_kv "WSL_user" "(default)"
        print_kv "authorized_keys" "not checked"
        return
    fi

    print_kv "WSL_user" "`$target_user"
    if ! id "`$target_user" >/dev/null 2>&1; then
        print_kv "authorized_keys" "user not found"
        return
    fi

    home_dir=`$(getent passwd "`$target_user" | awk -F: '{ print `$6 }')
    if [ -z "`$home_dir" ]; then
        print_kv "authorized_keys" "home not found"
        return
    fi

    auth_file="`$home_dir/.ssh/authorized_keys"
    if [ ! -f "`$auth_file" ]; then
        print_kv "authorized_keys" "`$auth_file (missing)"
        return
    fi

    count=`$(awk 'NF { count++ } END { print count + 0 }' "`$auth_file" 2>/dev/null)
    if [ -z "`$pubkey_b64" ]; then
        print_kv "authorized_keys" "`$auth_file (`$count key line(s))"
        print_kv "configured key" "not found from WSL_SSH_key"
        return
    fi

    key=`$(printf '%s' "`$pubkey_b64" | base64 -d 2>/dev/null | awk 'NF { sub(/\r$/, ""); print; exit }')
    if [ -n "`$key" ] && grep -qxF "`$key" "`$auth_file" 2>/dev/null; then
        key_status=present
    else
        key_status=missing
    fi
    print_kv "authorized_keys" "`$auth_file (`$count key line(s))"
    print_kv "configured key" "`$key_status"
}

sshd_bin=`$(find_sshd_bin)
port=`$(detect_port)

print_kv "openssh-server" "`$(detect_package_status)"
if [ -n "`$sshd_bin" ]; then
    print_kv "sshd binary" "`$sshd_bin"
else
    print_kv "sshd binary" "not found"
fi
if [ -f "`$sshd_config" ]; then
    print_kv "sshd_config" "`$sshd_config"
else
    print_kv "sshd_config" "`$sshd_config (missing)"
fi
print_kv "entry port" "`$entry_port"
print_kv "effective port" "`$port"
print_kv "listening" "`$(detect_listening "`$port")"
print_kv "WSL IP" "`$(detect_ips)"
detect_service_status
show_authorized_keys_status
"@

    return Invoke-WslSshScript $scriptText
}

function Open-WslSshConfig {
    if ($null -eq (Get-WslDistributionRecord)) {
        Write-Fail "WSL instance is not installed: $($script:Config.Name)"
        return 1
    }

    $nativeArgs = @("-d", $script:Config.Name, "-u", "root", "--", "sh", "-lc", "mkdir -p /etc/ssh; test -e /etc/ssh/sshd_config || : > /etc/ssh/sshd_config")
    $exitCode = Invoke-External "wsl.exe" $nativeArgs
    if ($exitCode -ne 0) {
        return $exitCode
    }

    $candidates = @(
        "\\wsl.localhost\$($script:Config.Name)\etc\ssh",
        ('\\wsl$\' + $script:Config.Name + '\etc\ssh')
    )

    foreach ($path in $candidates) {
        if (Test-Path -LiteralPath $path -PathType Container) {
            return Open-WindowsFolder $path
        }
    }

    return Open-WindowsFolder $candidates[0]
}

function Invoke-WslSshScript {
    param([string]$ScriptText)

    $runner = New-Base64ShRunner $ScriptText
    $nativeArgs = @("-d", $script:Config.Name, "-u", "root", "--", "sh", "-lc", $runner)
    return (Invoke-ControlNativeCommand $nativeArgs)
}

function Enable-WslSsh {
    param([string[]]$Rest)

    $port = Resolve-WslSshPort $Rest -AllowEmpty
    if ($null -eq $port) {
        return 1
    }
    if (-not (Ensure-WslSshSystemdReady)) {
        return 1
    }

    if ([string]::IsNullOrWhiteSpace($port)) {
        Write-Fail "WSL_SSH_port is empty. Set it in the entry file or run: $($script:Config.CommandName) ctl ssh enable <port>"
        return 1
    }

    if (-not (Test-WindowsTcpPortAvailable ([int]$port))) {
        return 1
    }

    if (-not (Test-WslTcpPortAvailable ([int]$port))) {
        return 1
    }

    $user = $script:Config.User
    if (-not [string]::IsNullOrWhiteSpace($user) -and -not (Test-LinuxUserName $user)) {
        Write-Fail "Invalid Linux username: $user"
        return 1
    }

    $publicKey = Get-WindowsSshPublicKeyBase64
    if ($null -eq $publicKey) {
        return 1
    }

    if (-not [string]::IsNullOrWhiteSpace($publicKey.Path)) {
        Write-Host "Using SSH public key: $($publicKey.Path)"
    }

$scriptText = @"
set -eu
port_input="$port"
target_user="$user"
pubkey_b64="$($publicKey.Base64)"
sshd_config=/etc/ssh/sshd_config
key_tmp=

prune_backups() {
    path="`$1"
    keep=3
    dir=`$(dirname "`$path")
    name=`$(basename "`$path")
    ls -1t "`$dir/`$name".bak.* 2>/dev/null |
        awk -v keep="`$keep" 'NR > keep { print }' |
        while IFS= read -r old_backup; do
            rm -f -- "`$old_backup"
        done
}

backup_file() {
    path="`$1"
    [ -f "`$path" ] || return 0
    base="`$path.bak.`$(date +%Y%m%d%H%M%S).`$`$"
    candidate="`$base"
    i=0
    while [ -e "`$candidate" ]; do
        i=`$((i + 1))
        candidate="`$base.`$i"
    done
    cp -p "`$path" "`$candidate"
    prune_backups "`$path"
    printf 'Backup: %s\n' "`$candidate"
}

sshd_config_includes_dropins() {
    config_file="`$1"
    [ -f "`$config_file" ] || return 1
    awk '
        /^[[:space:]]*#/ { next }
        tolower(`$1) == "include" {
            for (i = 2; i <= NF; i++) {
                if (`$i ~ /(^|\/)sshd_config\.d\/\*\.conf$/) {
                    found = 1
                }
            }
        }
        END { exit found ? 0 : 1 }
    ' "`$config_file"
}

has_systemd() {
    [ "`$(ps -p 1 -o comm= 2>/dev/null | tr -d ' ')" = "systemd" ] && command -v systemctl >/dev/null 2>&1
}

detect_systemd_ssh_unit() {
    if systemctl list-unit-files ssh.service --no-pager 2>/dev/null | grep -q '^ssh\.service'; then
        printf '%s\n' ssh
        return
    fi
    if systemctl list-unit-files sshd.service --no-pager 2>/dev/null | grep -q '^sshd\.service'; then
        printf '%s\n' sshd
        return
    fi
    printf '%s\n' ssh
}

find_sshd_bin() {
    if command -v sshd >/dev/null 2>&1; then
        command -v sshd
        return
    fi
    if [ -x /usr/sbin/sshd ]; then
        printf '%s\n' /usr/sbin/sshd
        return
    fi

    printf '\n'
}

openssh_server_package_installed() {
    if dpkg-query -W -f='`${db:Status-Abbrev}' openssh-server 2>/dev/null | grep -q '^ii '; then
        return 0
    fi

    if command -v rpm >/dev/null 2>&1 && rpm -q openssh-server >/dev/null 2>&1; then
        return 0
    fi

    return 1
}

ensure_ssh_host_keys() {
    if command -v ssh-keygen >/dev/null 2>&1; then
        ssh-keygen -A
    fi
}

install_openssh_server_with_apt() {
    policy_created=0
    if [ ! -e /usr/sbin/policy-rc.d ]; then
        printf '%s\n' '#!/bin/sh' 'exit 101' > /usr/sbin/policy-rc.d
        chmod 755 /usr/sbin/policy-rc.d
        policy_created=1
    fi

    cleanup_policy_rcd() {
        if [ "`$policy_created" -eq 1 ]; then
            rm -f /usr/sbin/policy-rc.d
        fi
    }

    apt-get update || {
        status=`$?
        cleanup_policy_rcd
        exit "`$status"
    }

    DEBIAN_FRONTEND=noninteractive apt-get install -y openssh-server || {
        status=`$?
        cleanup_policy_rcd
        exit "`$status"
    }

    cleanup_policy_rcd
}

install_openssh_server_with_rpm_manager() {
    if command -v dnf >/dev/null 2>&1; then
        dnf install -y openssh-server
        return
    fi

    if command -v yum >/dev/null 2>&1; then
        yum install -y openssh-server
        return
    fi

    if command -v microdnf >/dev/null 2>&1; then
        microdnf install -y openssh-server
        return
    fi

    return 127
}

ensure_openssh_server() {
    if [ -n "`$(find_sshd_bin)" ]; then
        ensure_ssh_host_keys
        return 0
    fi

    if openssh_server_package_installed; then
        echo "openssh-server package is installed but sshd was not found." >&2
        exit 1
    fi

    if command -v apt-get >/dev/null 2>&1; then
        install_openssh_server_with_apt
    elif command -v dnf >/dev/null 2>&1 || command -v yum >/dev/null 2>&1 || command -v microdnf >/dev/null 2>&1; then
        install_openssh_server_with_rpm_manager
    else
        echo "openssh-server auto-install currently supports apt-get, dnf, yum, or microdnf." >&2
        exit 1
    fi

    if [ -z "`$(find_sshd_bin)" ]; then
        echo "openssh-server install finished but sshd was not found." >&2
        exit 1
    fi

    ensure_ssh_host_keys
}

configure_sshd_port() {
    mkdir -p /etc/ssh
    [ -f "`$sshd_config" ] || : > "`$sshd_config"
    backup_file "`$sshd_config"

    tmp=`$(mktemp /etc/ssh/sshd_config.tmp.XXXXXX 2>/dev/null || mktemp)
    trap 'rm -f "`$tmp" "`$key_tmp"' EXIT
    awk -v port="`$port" '
    BEGIN { seen = 0 }
    /^[[:space:]]*#?[[:space:]]*Port[[:space:]]+/ {
        if (!seen) {
            print "Port " port
            seen = 1
        }
        next
    }
    { print }
    END {
        if (!seen) {
            print "Port " port
        }
    }
    ' "`$sshd_config" > "`$tmp"

    mode=`$(stat -c '%a' "`$sshd_config" 2>/dev/null || printf '0644')
    owner=`$(stat -c '%u:%g' "`$sshd_config" 2>/dev/null || printf '0:0')
    chmod "`$mode" "`$tmp" 2>/dev/null || true
    chown "`$owner" "`$tmp" 2>/dev/null || true
    mv "`$tmp" "`$sshd_config"
    tmp=
}

ensure_pubkey_authentication() {
    if [ -z "`$pubkey_b64" ]; then
        return 0
    fi

    if ! sshd_config_includes_dropins "`$sshd_config"; then
        echo "sshd_config does not include sshd_config.d/*.conf; skip PubkeyAuthentication drop-in." >&2
        return 0
    fi

    dropin=/etc/ssh/sshd_config.d/00-wsl-instance-kit-pubkey-auth.conf
    desired="# Managed by wsl_instance_kit ctl ssh enable
PubkeyAuthentication yes"
    current=
    if [ -f "`$dropin" ]; then
        current=`$(cat "`$dropin")
    fi
    if [ "`$current" = "`$desired" ]; then
        return 0
    fi

    mkdir -p /etc/ssh/sshd_config.d
    backup_file "`$dropin"
    tmp=`$(mktemp /etc/ssh/sshd_config.d/00-wsl-instance-kit-pubkey-auth.conf.tmp.XXXXXX 2>/dev/null || mktemp)
    printf '%s\n' "`$desired" > "`$tmp"
    chmod 0644 "`$tmp" 2>/dev/null || true
    chown root:root "`$tmp" 2>/dev/null || true
    mv "`$tmp" "`$dropin"
    tmp=
}

install_authorized_key() {
    [ -n "`$pubkey_b64" ] || return 0
    if [ -z "`$target_user" ]; then
        echo "WSL_user is empty; skip SSH public key import." >&2
        return 0
    fi
    if ! id "`$target_user" >/dev/null 2>&1; then
        echo "Linux user not found for SSH public key import: `$target_user" >&2
        exit 1
    fi

    home_dir=`$(getent passwd "`$target_user" | awk -F: '{ print `$6 }')
    if [ -z "`$home_dir" ]; then
        echo "Cannot resolve home directory for `$target_user" >&2
        exit 1
    fi

    group_name=`$(id -gn "`$target_user")
    ssh_dir="`$home_dir/.ssh"
    auth_file="`$ssh_dir/authorized_keys"
    mkdir -p "`$ssh_dir"
    touch "`$auth_file"
    chown "`$target_user:`$group_name" "`$ssh_dir" "`$auth_file"
    chmod 700 "`$ssh_dir"
    chmod 600 "`$auth_file"

    key_tmp=`$(mktemp)
    printf '%s' "`$pubkey_b64" | base64 -d > "`$key_tmp"
    while IFS= read -r key_line || [ -n "`$key_line" ]; do
        clean_key=`$(printf '%s' "`$key_line" | tr -d '\r')
        [ -n "`$clean_key" ] || continue
        if ! grep -qxF "`$clean_key" "`$auth_file"; then
            printf '%s\n' "`$clean_key" >> "`$auth_file"
        fi
    done < "`$key_tmp"
    rm -f "`$key_tmp"
    key_tmp=

    chown "`$target_user:`$group_name" "`$auth_file"
    chmod 600 "`$auth_file"
}

start_ssh_service() {
    mkdir -p /run/sshd
    if has_systemd; then
        unit=`$(detect_systemd_ssh_unit)
        systemctl enable "`$unit"
        start_log=`$(mktemp)
        if systemctl restart "`$unit" >"`$start_log" 2>&1; then
            rm -f "`$start_log"
            return
        fi

        cat "`$start_log" >&2
        rm -f "`$start_log"
        echo "Failed to start/restart SSH service on port `$port." >&2
        echo "If the port is already in use, try: $($script:Config.CommandName) ctl ssh enable 2222" >&2
        systemctl status "`$unit" --no-pager -l >&2 || true
        exit 1
    fi

    echo "systemd is not active in this WSL instance." >&2
    echo "Run: $($script:Config.CommandName) ctl systemd enable" >&2
    echo "Then restart WSL: $($script:Config.CommandName) ctl global shutdown" >&2
    exit 1
}

ensure_openssh_server
if ! has_systemd; then
    echo "systemd is not active in this WSL instance." >&2
    echo "Restart WSL, then run ctl ssh enable again: $($script:Config.CommandName) ctl global shutdown" >&2
    exit 1
fi
port="`$port_input"
configure_sshd_port
ensure_pubkey_authentication
install_authorized_key
start_ssh_service
printf 'SSH enabled on port %s\n' "`$port"
"@

    return Invoke-WslSshScript $scriptText
}

function Disable-WslSsh {
    $user = $script:Config.User
    if (-not [string]::IsNullOrWhiteSpace($user) -and -not (Test-LinuxUserName $user)) {
        Write-Fail "Invalid Linux username: $user"
        return 1
    }

    $publicKey = Get-WindowsSshPublicKeyBase64
    if ($null -eq $publicKey) {
        $publicKey = [pscustomobject]@{
            Path = ""
            Base64 = ""
        }
    }

    if (-not [string]::IsNullOrWhiteSpace($publicKey.Path)) {
        Write-Host "Removing SSH public key: $($publicKey.Path)"
    }

    $scriptText = @"
set -eu
target_user="$user"
pubkey_b64="$($publicKey.Base64)"
key_tmp=
auth_tmp=

remove_authorized_key() {
    [ -n "`$pubkey_b64" ] || return 0
    if [ -z "`$target_user" ]; then
        echo "WSL_user is empty; skip SSH public key removal." >&2
        return 0
    fi
    if ! id "`$target_user" >/dev/null 2>&1; then
        echo "Linux user not found for SSH public key removal: `$target_user" >&2
        return 0
    fi

    home_dir=`$(getent passwd "`$target_user" | awk -F: '{ print `$6 }')
    if [ -z "`$home_dir" ]; then
        echo "Cannot resolve home directory for `$target_user; skip SSH public key removal." >&2
        return 0
    fi

    ssh_dir="`$home_dir/.ssh"
    auth_file="`$ssh_dir/authorized_keys"
    if [ ! -f "`$auth_file" ]; then
        echo "authorized_keys not found, nothing to remove."
        return 0
    fi

    pubkey=`$(printf '%s' "`$pubkey_b64" | base64 -d | awk 'NF { sub(/\r$/, ""); print; exit }')
    if [ -z "`$pubkey" ]; then
        echo "Configured SSH public key is empty; skip removal." >&2
        return 0
    fi

    auth_tmp=`$(mktemp "`$ssh_dir/.authorized_keys.tmp.XXXXXX")
    chmod 600 "`$auth_tmp"
    awk -v key="`$pubkey" '
        {
            line = `$0
            sub(/\r$/, "", line)
            if (line != key) {
                print `$0
            }
        }
    ' "`$auth_file" > "`$auth_tmp"

    group_name=`$(id -gn "`$target_user")
    chown "`$target_user:`$group_name" "`$auth_tmp" 2>/dev/null || true
    chmod 600 "`$auth_tmp"
    mv "`$auth_tmp" "`$auth_file"
    auth_tmp=
    echo "SSH public key removed from `$auth_file"
}

cleanup() {
    if [ -n "`$key_tmp" ] && [ -f "`$key_tmp" ]; then
        rm -f "`$key_tmp"
    fi
    if [ -n "`$auth_tmp" ] && [ -f "`$auth_tmp" ]; then
        rm -f "`$auth_tmp"
    fi
    return 0
}
trap cleanup EXIT

has_systemd() {
    [ "`$(ps -p 1 -o comm= 2>/dev/null | tr -d ' ')" = "systemd" ] && command -v systemctl >/dev/null 2>&1
}

detect_systemd_ssh_unit() {
    if systemctl list-unit-files ssh.service --no-pager 2>/dev/null | grep -q '^ssh\.service'; then
        printf '%s\n' ssh
        return
    fi
    if systemctl list-unit-files sshd.service --no-pager 2>/dev/null | grep -q '^sshd\.service'; then
        printf '%s\n' sshd
        return
    fi
    printf '%s\n' ssh
}

if has_systemd; then
    unit=`$(detect_systemd_ssh_unit)
    systemctl disable --now "`$unit" 2>/dev/null || true
    systemctl disable --now ssh.socket 2>/dev/null || true
    systemctl stop ssh.socket 2>/dev/null || true
else
    if command -v service >/dev/null 2>&1; then
        service ssh stop 2>/dev/null || service sshd stop 2>/dev/null || true
    else
        pkill -x sshd 2>/dev/null || true
    fi
fi

remove_authorized_key
printf 'SSH disabled\n'
"@

    return Invoke-WslSshScript $scriptText
}
