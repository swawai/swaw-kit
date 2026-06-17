function Resolve-WslSshPort {
    param([string[]]$Rest)

    $rawPort = if ($Rest.Count -gt 0 -and -not [string]::IsNullOrWhiteSpace($Rest[0])) {
        $Rest[0]
    } else {
        $script:Config.SshPort
    }

    if ([string]::IsNullOrWhiteSpace($rawPort)) {
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
    $publicKeyPath = Resolve-WindowsSshPublicKeyPath
    if ([string]::IsNullOrWhiteSpace($publicKeyPath)) {
        return [pscustomobject]@{
            Path = ""
            Base64 = ""
        }
    }

    $line = Get-Content -LiteralPath $publicKeyPath | Where-Object { -not [string]::IsNullOrWhiteSpace($_) } | Select-Object -First 1
    if (-not $line) {
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

function Invoke-WslSshScript {
    param([string]$ScriptText)

    $runner = New-Base64ShRunner $ScriptText
    $nativeArgs = @("-d", $script:Config.Name, "-u", "root", "--", "sh", "-lc", $runner)
    return (Invoke-ControlNativeCommand $nativeArgs)
}

function Enable-WslSsh {
    param([string[]]$Rest)

    $port = Resolve-WslSshPort $Rest
    if ($null -eq $port) {
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
port="$port"
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

ensure_openssh_server() {
    if ! command -v apt-get >/dev/null 2>&1; then
        if command -v sshd >/dev/null 2>&1 || [ -x /usr/sbin/sshd ]; then
            return 0
        fi
        echo "openssh-server auto-install currently supports Debian/Ubuntu apt-get only." >&2
        exit 1
    fi

    if dpkg-query -W -f='`${db:Status-Abbrev}' openssh-server 2>/dev/null | grep -q '^ii '; then
        return 0
    fi

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
        systemctl enable --now "`$unit"
        return
    fi

    if command -v service >/dev/null 2>&1; then
        if service ssh restart 2>/dev/null; then
            return
        fi
        if service ssh --full-restart 2>/dev/null; then
            return
        fi
        if service sshd restart 2>/dev/null; then
            return
        fi
    fi

    if [ -x /usr/sbin/sshd ]; then
        /usr/sbin/sshd
        return
    fi

    echo "Unable to start ssh service." >&2
    exit 1
}

ensure_openssh_server
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
