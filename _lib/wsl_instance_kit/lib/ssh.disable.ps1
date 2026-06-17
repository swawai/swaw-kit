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

    home_dir=`$(getent passwd "`$target_user" | cut -d: -f6)
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

    pubkey=`$(printf '%s' "`$pubkey_b64" | base64 -d | sed -n 's/\r`$//; /^[[:space:]]*`$/d; p; q')
    if [ -z "`$pubkey" ]; then
        echo "Configured SSH public key is empty; skip removal." >&2
        return 0
    fi

    auth_tmp=`$(mktemp "`$ssh_dir/.authorized_keys.tmp.XXXXXX")
    chmod 600 "`$auth_tmp"
    while IFS= read -r line || [ -n "`$line" ]; do
        clean_line=`$(printf '%s' "`$line" | tr -d '\r')
        if [ "`$clean_line" != "`$pubkey" ]; then
            printf '%s\n' "`$line"
        fi
    done < "`$auth_file" > "`$auth_tmp"

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
