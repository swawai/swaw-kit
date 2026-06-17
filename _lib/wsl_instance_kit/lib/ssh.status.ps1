function Show-WslSshStatus {
    $entryPort = Resolve-WslSshPort @() -AllowEmpty
    if ($null -eq $entryPort) {
        return 1
    }
    $entryPortText = if ([string]::IsNullOrWhiteSpace($entryPort)) { "(explicit argument only)" } else { [string]$entryPort }

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
        Write-Host "  Windows public key:     (not found from WSL_SSH_public_key)"
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
    [ "`$(ps -p 1 -o comm= 2>/dev/null | tr -d ' ')" = "systemd" ] &&
        command -v systemctl >/dev/null 2>&1 &&
        systemctl list-unit-files --no-pager >/dev/null 2>&1
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
        port=`$("`$bin" -T 2>/dev/null | sed -n 's/^port //p' | head -n 1)
        if [ -n "`$port" ]; then
            printf '%s\n' "`$port"
            return
        fi
    fi

    if [ -f "`$sshd_config" ]; then
        port=`$(
            while IFS= read -r line || [ -n "`$line" ]; do
                set -- `$line
                [ "`$#" -gt 0 ] || continue
                case "`$1" in
                    [Pp][Oo][Rr][Tt])
                        printf '%s\n' "`$2"
                        ;;
                esac
            done < "`$sshd_config" | tail -n 1
        )
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
        if ss -ltn 2>/dev/null | grep -Eq ":`$port[[:space:]]"; then
            printf '%s\n' yes
        else
            printf '%s\n' no
        fi
        return
    fi
    if command -v netstat >/dev/null 2>&1; then
        if netstat -ltn 2>/dev/null | grep -Eq ":`$port[[:space:]]"; then
            printf '%s\n' yes
        else
            printf '%s\n' no
        fi
        return
    fi
    if pgrep -x sshd >/dev/null 2>&1; then
        printf '%s\n' "unknown (sshd running)"
    else
        printf '%s\n' unknown
    fi
}

detect_ips() {
    ips=`$(hostname -I 2>/dev/null | tr ' ' '\n' | grep -v '^fe80:' | tr '\n' ' ' | sed 's/[[:space:]]*`$//')
    if [ -n "`$ips" ]; then
        printf '%s\n' "`$ips"
        return
    fi
    if command -v ip >/dev/null 2>&1; then
        ips=`$(
            ip -o -4 addr show scope global 2>/dev/null |
                while IFS= read -r line || [ -n "`$line" ]; do
                    set -- `$line
                    addr="`$4"
                    printf '%s\n' "`${addr%%/*}"
                done |
                tr '\n' ' ' |
                sed 's/[[:space:]]*`$//'
        )
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

    home_dir=`$(getent passwd "`$target_user" | cut -d: -f6)
    if [ -z "`$home_dir" ]; then
        print_kv "authorized_keys" "home not found"
        return
    fi

    auth_file="`$home_dir/.ssh/authorized_keys"
    if [ ! -f "`$auth_file" ]; then
        print_kv "authorized_keys" "`$auth_file (missing)"
        return
    fi

    count=`$(grep -c '[^[:space:]]' "`$auth_file" 2>/dev/null || true)
    [ -n "`$count" ] || count=0
    if [ -z "`$pubkey_b64" ]; then
        print_kv "authorized_keys" "`$auth_file (`$count key line(s))"
        print_kv "configured key" "not found from WSL_SSH_public_key"
        return
    fi

    key=`$(printf '%s' "`$pubkey_b64" | base64 -d 2>/dev/null | sed -n 's/\r`$//; /^[[:space:]]*`$/d; p; q')
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
print_kv "enable port" "`$entry_port"
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

