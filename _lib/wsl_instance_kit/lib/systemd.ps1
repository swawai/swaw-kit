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
    $exitCode = Invoke-ControlNativeCommand $nativeArgs
    if ($exitCode -ne 0) {
        Write-Fail "Failed to update systemd setting in /etc/wsl.conf."
        return $exitCode
    }

    $stateText = if ($Action -eq "enable") { "enabled" } else { "disabled" }
    Write-Host "Systemd $stateText in /etc/wsl.conf."
    Write-Host "Restart WSL to apply: $($script:Config.CommandName) .vm -s"
    return 0
}

function Show-WslSystemdStatus {
    if ($null -eq (Get-WslDistributionRecord)) {
        Write-Fail "WSL instance is not installed: $($script:Config.Name)"
        return 1
    }

    Write-Host "WSL systemd status: $($script:Config.Name)"

$scriptText = @'
set -u
conf=/etc/wsl.conf
configured="(not set)"
conf_status="missing"

print_kv() {
    label="$1"
    value="$2"
    printf '  %-23s %s\n' "$label:" "$value"
}

if [ -f "$conf" ]; then
    conf_status="$conf"
    in_boot=0
    while IFS= read -r line || [ -n "$line" ]; do
        no_comment=${line%%#*}
        no_comment=${no_comment%%;*}
        compact=$(printf '%s' "$no_comment" | tr -d '[:space:]')
        [ -n "$compact" ] || continue
        case "$compact" in
            "["*"]")
                section=${compact#\[}
                section=${section%%\]*}
                section=$(printf '%s' "$section" | tr '[:upper:]' '[:lower:]')
                if [ "$section" = boot ]; then
                    in_boot=1
                else
                    in_boot=0
                fi
                ;;
            [Ss][Yy][Ss][Tt][Ee][Mm][Dd]=*)
                if [ "$in_boot" -eq 1 ]; then
                    configured=${compact#*=}
                fi
                ;;
        esac
    done < "$conf"
fi

init=$(ps -p 1 -o comm= 2>/dev/null | tr -d ' ')
[ -n "$init" ] || init=unknown

systemd_active=no
if [ "$init" = systemd ]; then
    systemd_active=yes
fi

systemctl_usable=no
if command -v systemctl >/dev/null 2>&1 && systemctl list-unit-files --no-pager >/dev/null 2>&1; then
    systemctl_usable=yes
fi

configured_lc=$(printf '%s' "$configured" | tr '[:upper:]' '[:lower:]')
restart_needed=no
case "$configured_lc:$systemd_active" in
    true:no|1:no|yes:no)
        restart_needed="yes (enable pending)"
        ;;
    false:yes|0:yes|no:yes)
        restart_needed="yes (disable pending)"
        ;;
esac

print_kv "wsl.conf" "$conf_status"
print_kv "configured systemd" "$configured"
print_kv "runtime init" "$init"
print_kv "systemd active" "$systemd_active"
print_kv "systemctl usable" "$systemctl_usable"
print_kv "restart needed" "$restart_needed"
'@

    $runner = New-Base64ShRunner $scriptText
    $nativeArgs = @("-d", $script:Config.Name, "-u", "root", "--", "sh", "-lc", $runner)
    return (Invoke-ControlNativeCommand $nativeArgs)
}
