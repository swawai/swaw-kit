function Enable-WslSsh {
    param([string[]]$Rest)

    $port = Resolve-WslSshPort $Rest
    if ($null -eq $port) {
        return 1
    }
    if (-not (Ensure-WslSshSystemdReady)) {
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
    count=0
    dir=`$(dirname "`$path")
    name=`$(basename "`$path")
    ls -1t "`$dir/`$name".bak.* 2>/dev/null |
        while IFS= read -r old_backup; do
            count=`$((count + 1))
            if [ "`$count" -gt "`$keep" ]; then
                rm -f -- "`$old_backup"
            fi
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
    while IFS= read -r line || [ -n "`$line" ]; do
        set -- `$line
        [ "`$#" -gt 0 ] || continue
        case "`$1" in
            \#*) continue ;;
            [Ii][Nn][Cc][Ll][Uu][Dd][Ee])
                shift
                for item in "`$@"; do
                    case "`$item" in
                        */sshd_config.d/\*.conf|sshd_config.d/\*.conf) return 0 ;;
                    esac
                done
                ;;
        esac
    done < "`$config_file"
    return 1
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
    seen=0
    while IFS= read -r line || [ -n "`$line" ]; do
        compact=`$(printf '%s' "`$line" | tr -d '[:space:]')
        case "`$compact" in
            [Pp][Oo][Rr][Tt]*|\#[Pp][Oo][Rr][Tt]*)
                if [ "`$seen" -eq 0 ]; then
                    printf 'Port %s\n' "`$port"
                    seen=1
                fi
                ;;
            *)
                printf '%s\n' "`$line"
                ;;
        esac
    done < "`$sshd_config" > "`$tmp"
    if [ "`$seen" -eq 0 ]; then
        printf 'Port %s\n' "`$port" >> "`$tmp"
    fi

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

    home_dir=`$(getent passwd "`$target_user" | cut -d: -f6)
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
    echo "Then restart WSL: $($script:Config.CommandName) vm -s" >&2
    exit 1
}

ensure_openssh_server
if ! has_systemd; then
    echo "systemd is not active in this WSL instance." >&2
    echo "Restart WSL, then run ctl ssh enable again: $($script:Config.CommandName) vm -s" >&2
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
