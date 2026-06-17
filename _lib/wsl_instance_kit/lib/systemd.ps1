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
    ls -1t /etc/wsl.conf.bak.* 2>/dev/null |
        awk -v keep="`$keep" 'NR > keep { print }' |
        while IFS= read -r old_backup; do
            rm -f -- "`$old_backup"
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
awk -v value="$value" '
BEGIN {
    in_boot = 0
    seen_boot = 0
    seen_systemd = 0
}
function emit_systemd_if_needed() {
    if (in_boot && !seen_systemd) {
        print "systemd=" value
        seen_systemd = 1
    }
}
/^[[:space:]]*\[[^]]+\][[:space:]]*$/ {
    emit_systemd_if_needed()
    section = `$0
    sub(/^[[:space:]]*\[/, "", section)
    sub(/\][[:space:]]*$/, "", section)
    in_boot = (section == "boot")
    if (in_boot) {
        seen_boot = 1
    }
    print
    next
}
{
    if (in_boot && `$0 ~ /^[[:space:]]*systemd[[:space:]]*=/) {
        if (!seen_systemd) {
            print "systemd=" value
            seen_systemd = 1
        }
        next
    }
    print
}
END {
    emit_systemd_if_needed()
    if (!seen_boot) {
        print ""
        print "[boot]"
        print "systemd=" value
    }
}
' "`$conf" > "`$tmp"

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
