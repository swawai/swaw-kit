function Set-WslSystemd {
    param([ValidateSet("enable", "disable")] [string]$Action)

    $value = if ($Action -eq "enable") { "true" } else { "false" }
    $scriptText = @"
set -eu
conf=/etc/wsl.conf
existed=0
backup=

next_backup_path() {
    base="`$conf.bak.`$(date +%Y%m%d%H%M%S).`$`$"
    candidate="`$base"
    i=0
    while [ -e "`$candidate" ]; do
        i=`$((i + 1))
        candidate="`$base.`$i"
    done
    printf '%s\n' "`$candidate"
}

prune_backups() {
    keep=3
    count=0
    ls -1t /etc/wsl.conf.bak.* 2>/dev/null |
        while IFS= read -r old_backup; do
            count=`$((count + 1))
            if [ "`$count" -gt "`$keep" ]; then
                rm -f -- "`$old_backup"
            fi
        done
}

if [ -e "`$conf" ]; then
    existed=1
    backup=`$(next_backup_path)
    cp -p "`$conf" "`$backup"
    prune_backups
else
    : > "`$conf"
    chmod 0644 "`$conf" 2>/dev/null || true
fi

tmp=`$(mktemp /etc/wsl.conf.tmp.XXXXXX 2>/dev/null || mktemp)
trap 'rm -f "`$tmp"' EXIT
in_boot=0
seen_boot=0
seen_systemd=0

emit_systemd_if_needed() {
    if [ "`$in_boot" -eq 1 ] && [ "`$seen_systemd" -eq 0 ]; then
        printf 'systemd=%s\n' "$value"
        seen_systemd=1
    fi
}

{
    while IFS= read -r line || [ -n "`$line" ]; do
        compact=`$(printf '%s' "`$line" | tr -d '[:space:]')
        case "`$compact" in
            "["*"]")
                emit_systemd_if_needed
                section=`${compact#\[}
                section=`${section%%\]*}
                if [ "`$section" = boot ]; then
                    in_boot=1
                    seen_boot=1
                else
                    in_boot=0
                fi
                printf '%s\n' "`$line"
                ;;
            systemd=*)
                if [ "`$in_boot" -eq 1 ]; then
                    if [ "`$seen_systemd" -eq 0 ]; then
                        printf 'systemd=%s\n' "$value"
                        seen_systemd=1
                    fi
                else
                    printf '%s\n' "`$line"
                fi
                ;;
            *)
                printf '%s\n' "`$line"
                ;;
        esac
    done < "`$conf"

    emit_systemd_if_needed
    if [ "`$seen_boot" -eq 0 ]; then
        printf '\n[boot]\n'
        printf 'systemd=%s\n' "$value"
    fi
} > "`$tmp"

if [ "`$existed" -eq 1 ]; then
    mode=`$(stat -c '%a' "`$conf" 2>/dev/null || printf '0644')
    owner=`$(stat -c '%u:%g' "`$conf" 2>/dev/null || printf '0:0')
    chmod "`$mode" "`$tmp" 2>/dev/null || true
    chown "`$owner" "`$tmp" 2>/dev/null || true
else
    chmod 0644 "`$tmp" 2>/dev/null || true
fi

mv "`$tmp" "`$conf"
trap - EXIT

if [ "`$existed" -eq 1 ]; then
    printf 'Backup: %s\n' "`$backup"
fi
"@

    $runner = New-Base64ShRunner $scriptText
    $nativeArgs = @("-d", $script:Config.Name, "-u", "root", "--", "sh", "-lc", $runner)
    return (Invoke-ControlNativeCommand $nativeArgs)
}
