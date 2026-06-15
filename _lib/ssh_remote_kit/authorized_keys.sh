#!/usr/bin/env bash
set -euo pipefail
export LC_ALL=C
export LANG=C

action="${1:-}"
pubkey_file="${2:-}"
sshd_mode="${3:-check-sshd}"

if [ "$action" != "add" ] && [ "$action" != "remove" ] && [ "$action" != "fix" ]; then
  echo "[ERROR] Unknown action: $action" >&2
  exit 1
fi

if [ "$sshd_mode" != "check-sshd" ] && [ "$sshd_mode" != "fix-sshd" ] && [ "$sshd_mode" != "skip-sshd" ]; then
  echo "[ERROR] Unknown sshd mode: $sshd_mode" >&2
  exit 1
fi

pubkey=""
if [ "$action" != "fix" ]; then
  if [ ! -f "$pubkey_file" ]; then
    echo "[ERROR] Public key file not found: $pubkey_file" >&2
    exit 1
  fi

  pubkey="$(awk 'NF { sub(/\r$/, ""); print; exit }' "$pubkey_file")"
  if [ -z "$pubkey" ]; then
    echo "[ERROR] Public key file is empty: $pubkey_file" >&2
    exit 1
  fi
fi

ssh_dir="$HOME/.ssh"
authorized_keys="$ssh_dir/authorized_keys"
tmp_file=""
sshd_changed_path=""
sshd_backup_path=""
sshd_created_path="no"

cleanup() {
  if [ -n "$tmp_file" ] && [ -f "$tmp_file" ]; then
    rm -f "$tmp_file"
  fi
}
trap cleanup EXIT

find_sshd_bin() {
  local candidate
  for candidate in "$(command -v sshd 2>/dev/null || true)" /usr/sbin/sshd /usr/local/sbin/sshd /sbin/sshd; do
    if [ -n "$candidate" ] && [ -x "$candidate" ]; then
      printf '%s\n' "$candidate"
      return 0
    fi
  done

  return 1
}

remote_client_addr() {
  local client_addr ssh_client
  ssh_client="${SSH_CLIENT:-}"
  client_addr="${ssh_client%% *}"
  if [ -n "$client_addr" ]; then
    printf '%s\n' "$client_addr"
  else
    printf '127.0.0.1\n'
  fi
}

remote_host_name() {
  hostname -f 2>/dev/null || hostname 2>/dev/null || printf 'localhost\n'
}

get_sshd_effective_config() {
  local sshd_bin="$1"
  local client_addr host_name remote_user

  client_addr="$(remote_client_addr)"
  host_name="$(remote_host_name)"
  remote_user="${USER:-}"
  if [ -z "$remote_user" ]; then
    remote_user="$(id -un 2>/dev/null || printf 'unknown')"
  fi

  "$sshd_bin" -T -C "user=$remote_user,host=$host_name,addr=$client_addr" 2>/dev/null || "$sshd_bin" -T 2>/dev/null
}

get_effective_sshd_value() {
  local key="$1"
  awk -v key="$key" 'tolower($1) == key { $1 = ""; sub(/^[[:space:]]+/, ""); print; exit }'
}

count_effective_sshd_values() {
  local key="$1"
  awk -v key="$key" 'tolower($1) == key { count++ } END { print count + 0 }'
}

can_run_root() {
  if [ "$(id -u)" -eq 0 ]; then
    return 0
  fi

  command -v sudo >/dev/null 2>&1 && sudo -n true >/dev/null 2>&1
}

run_root() {
  if [ "$(id -u)" -eq 0 ]; then
    "$@"
  else
    sudo -n "$@"
  fi
}

rollback_sshd_fix() {
  local sshd_bin="${1:-}"

  if [ -z "$sshd_changed_path" ]; then
    return 0
  fi

  echo "[WARN] Rolling back sshd config change: $sshd_changed_path" >&2

  if [ -n "$sshd_backup_path" ]; then
    run_root cp -p "$sshd_backup_path" "$sshd_changed_path"
    echo "[INFO] Restored sshd config backup: $sshd_backup_path"
  elif [ "$sshd_created_path" = "yes" ]; then
    run_root rm -f "$sshd_changed_path"
    echo "[INFO] Removed newly-created sshd config: $sshd_changed_path"
  fi

  if [ -n "$sshd_bin" ]; then
    if run_root "$sshd_bin" -t; then
      if reload_sshd_service; then
        echo "[INFO] Reloaded sshd service after rollback."
      else
        echo "[WARN] Could not reload sshd service after rollback. Please reload sshd manually." >&2
      fi
    else
      echo "[ERROR] sshd config test still fails after rollback. Please inspect sshd config manually." >&2
    fi
  fi

  sshd_changed_path=""
  sshd_backup_path=""
  sshd_created_path="no"
}

prune_remote_kit_backups() {
  local base_path="$1"
  local keep="${2:-3}"
  local backup_dir backup_name backup_prefix backups count remove_count backup

  if [ -z "$base_path" ]; then
    return 0
  fi

  backup_dir="$(dirname "$base_path")"
  backup_name="$(basename "$base_path")"
  backup_prefix="$backup_name.remote-kit-bak-"

  backups="$(
    run_root sh -c '
      for path in "$1"/"$2"*; do
        [ -f "$path" ] && printf "%s\n" "$path"
      done
    ' sh "$backup_dir" "$backup_prefix" | sort || true
  )"

  count="$(printf '%s\n' "$backups" | awk 'NF { c++ } END { print c + 0 }')"
  if [ "$count" -le "$keep" ]; then
    return 0
  fi

  remove_count=$((count - keep))
  echo "[INFO] Pruning old remote_kit sshd backups for $base_path; keeping newest $keep."

  printf '%s\n' "$backups" | awk -v n="$remove_count" 'NF && ++seen <= n { print }' |
  while IFS= read -r backup; do
    if run_root rm -f "$backup"; then
      echo "[INFO] Pruned old remote_kit sshd backup: $backup"
    else
      echo "[WARN] Failed to prune old remote_kit sshd backup: $backup" >&2
    fi
  done
}

sshd_config_includes_dropins() {
  local config_file="$1"

  awk '
    /^[[:space:]]*#/ { next }
    tolower($1) == "include" {
      for (i = 2; i <= NF; i++) {
        if ($i ~ /(^|\/)sshd_config\.d\/\*\.conf$/) {
          found = 1
        }
      }
    }
    END { exit found ? 0 : 1 }
  ' "$config_file"
}

sshd_config_has_existing_dropins() {
  run_root sh -c '
    for dropin in /etc/ssh/sshd_config.d/*.conf; do
      [ -f "$dropin" ] && exit 0
    done

    exit 1
  '
}

assert_main_pubkey_auth_fix_is_simple() {
  local config_file="$1"
  local pre_match_count post_match_count first_pre_match first_post_match

  read -r pre_match_count post_match_count first_pre_match first_post_match <<EOF
$(awk '
  BEGIN {
    in_match = 0
    pre = 0
    post = 0
    first_pre = 0
    first_post = 0
  }
  /^[[:space:]]*#/ { next }
  tolower($1) == "match" {
    in_match = 1
    next
  }
  tolower($1) == "pubkeyauthentication" {
    if (in_match) {
      post++
      if (!first_post) {
        first_post = NR
      }
    } else {
      pre++
      if (!first_pre) {
        first_pre = NR
      }
    }
  }
  END {
    printf "%d %d %d %d\n", pre, post, first_pre, first_post
  }
' "$config_file")
EOF

  if [ "$post_match_count" -gt 0 ]; then
    echo "[ERROR] Refusing to auto-edit PubkeyAuthentication inside or after a Match block; first occurrence is at $config_file:$first_post_match." >&2
    return 1
  fi

  if [ "$pre_match_count" -gt 1 ]; then
    echo "[ERROR] Refusing to auto-edit multiple global PubkeyAuthentication directives in $config_file; first occurrence is at line $first_pre_match." >&2
    return 1
  fi
}

write_pubkey_auth_dropin() {
  local dropin_file="/etc/ssh/sshd_config.d/00-remote-kit-pubkey-auth.conf"
  local local_tmp backup timestamp

  local_tmp="$(mktemp)"
  timestamp="$(date +%Y%m%d%H%M%S)"
  backup="$dropin_file.remote-kit-bak-$timestamp"

  {
    printf '# Managed by remote_kit key.fix/key.add.fix\n'
    printf 'PubkeyAuthentication yes\n'
  } > "$local_tmp"

  run_root mkdir -p /etc/ssh/sshd_config.d
  if run_root test -f "$dropin_file"; then
    run_root cp -p "$dropin_file" "$backup"
    echo "[INFO] Backed up existing sshd drop-in: $backup"
    sshd_backup_path="$backup"
    sshd_created_path="no"
  else
    sshd_backup_path=""
    sshd_created_path="yes"
  fi

  run_root cp "$local_tmp" "$dropin_file"
  rm -f "$local_tmp"
  sshd_changed_path="$dropin_file"
  echo "[INFO] Wrote sshd drop-in: $dropin_file"
}

rewrite_pubkey_auth_in_main_config() {
  local config_file="$1"
  local local_tmp backup timestamp

  if [ ! -f "$config_file" ]; then
    echo "[ERROR] sshd config file not found: $config_file" >&2
    return 1
  fi

  if ! assert_main_pubkey_auth_fix_is_simple "$config_file"; then
    return 1
  fi

  local_tmp="$(mktemp)"
  timestamp="$(date +%Y%m%d%H%M%S)"
  backup="$config_file.remote-kit-bak-$timestamp"

  awk '
    BEGIN {
      done = 0
      inserted = 0
    }
    !done && /^[[:space:]]*[Pp][Uu][Bb][Kk][Ee][Yy][Aa][Uu][Tt][Hh][Ee][Nn][Tt][Ii][Cc][Aa][Tt][Ii][Oo][Nn][[:space:]]+/ {
      print "PubkeyAuthentication yes"
      done = 1
      inserted = 1
      next
    }
    !done && !inserted && /^[[:space:]]*[Mm][Aa][Tt][Cc][Hh][[:space:]]+/ {
      print "PubkeyAuthentication yes"
      inserted = 1
    }
    { print }
    END {
      if (!done && !inserted) {
        print "PubkeyAuthentication yes"
      }
    }
  ' "$config_file" > "$local_tmp"

  run_root cp -p "$config_file" "$backup"
  echo "[INFO] Backed up sshd config: $backup"

  run_root cp "$local_tmp" "$config_file"
  rm -f "$local_tmp"
  sshd_changed_path="$config_file"
  sshd_backup_path="$backup"
  sshd_created_path="no"
  echo "[INFO] Updated sshd config: $config_file"
}

reload_sshd_service() {
  if command -v systemctl >/dev/null 2>&1; then
    run_root systemctl reload sshd 2>/dev/null && return 0
    run_root systemctl reload ssh 2>/dev/null && return 0
  fi

  if command -v service >/dev/null 2>&1; then
    run_root service sshd reload 2>/dev/null && return 0
    run_root service ssh reload 2>/dev/null && return 0
  fi

  if [ -x /etc/init.d/sshd ]; then
    run_root /etc/init.d/sshd reload && return 0
  fi

  if [ -x /etc/init.d/ssh ]; then
    run_root /etc/init.d/ssh reload && return 0
  fi

  return 1
}

fix_pubkey_authentication() {
  local sshd_bin="$1"
  local config_file="/etc/ssh/sshd_config"

  if ! can_run_root; then
    echo "[ERROR] PubkeyAuthentication is disabled, but this user cannot run root commands with sudo -n." >&2
    return 1
  fi

  if [ -f "$config_file" ] && sshd_config_includes_dropins "$config_file" && sshd_config_has_existing_dropins; then
    if ! write_pubkey_auth_dropin; then
      return 1
    fi
  else
    if [ -f "$config_file" ] && sshd_config_includes_dropins "$config_file"; then
      echo "[INFO] No existing sshd drop-in files found; updating main sshd config instead."
    fi

    if ! rewrite_pubkey_auth_in_main_config "$config_file"; then
      return 1
    fi
  fi

  if ! run_root "$sshd_bin" -t; then
    echo "[ERROR] sshd config test failed after PubkeyAuthentication fix." >&2
    rollback_sshd_fix "$sshd_bin"
    return 1
  fi

  if reload_sshd_service; then
    echo "[INFO] Reloaded sshd service."
  else
    echo "[WARN] Could not reload sshd service automatically. Please reload sshd manually." >&2
  fi
}

check_or_fix_sshd_config() {
  local mode="$1"
  local sshd_bin effective_config pubkey_auth authorized_keys_file pubkey_auth_count authorized_keys_file_count

  if [ "$mode" = "skip-sshd" ]; then
    return 0
  fi

  echo "[STEP] Checking remote sshd public-key authentication settings."

  if ! sshd_bin="$(find_sshd_bin)"; then
    echo "[WARN] sshd binary not found; cannot inspect PubkeyAuthentication." >&2
    return 0
  fi

  effective_config="$(get_sshd_effective_config "$sshd_bin" || true)"
  if [ -z "$effective_config" ]; then
    echo "[WARN] sshd -T failed; cannot inspect effective PubkeyAuthentication." >&2
    return 0
  fi

  pubkey_auth="$(printf '%s\n' "$effective_config" | get_effective_sshd_value "pubkeyauthentication")"
  authorized_keys_file="$(printf '%s\n' "$effective_config" | get_effective_sshd_value "authorizedkeysfile")"
  pubkey_auth_count="$(printf '%s\n' "$effective_config" | count_effective_sshd_values "pubkeyauthentication")"
  authorized_keys_file_count="$(printf '%s\n' "$effective_config" | count_effective_sshd_values "authorizedkeysfile")"

  if [ "$pubkey_auth_count" -gt 1 ]; then
    echo "[WARN] sshd -T reported multiple PubkeyAuthentication values; using the first effective value: $pubkey_auth" >&2
  fi

  if [ "$authorized_keys_file_count" -gt 1 ]; then
    echo "[WARN] sshd -T reported multiple AuthorizedKeysFile values; using the first effective value: $authorized_keys_file" >&2
  fi

  if [ "$pubkey_auth" = "yes" ]; then
    echo "[INFO] PubkeyAuthentication is enabled."
  elif [ "$pubkey_auth" = "no" ]; then
    if [ "$mode" = "fix-sshd" ]; then
      echo "[WARN] PubkeyAuthentication is disabled; attempting to set it to yes."
      if ! fix_pubkey_authentication "$sshd_bin"; then
        return 1
      fi

      effective_config="$(get_sshd_effective_config "$sshd_bin" || true)"
      pubkey_auth="$(printf '%s\n' "$effective_config" | get_effective_sshd_value "pubkeyauthentication")"
      if [ "$pubkey_auth" != "yes" ]; then
        echo "[ERROR] PubkeyAuthentication still appears disabled after the fix. A Match block or included config may override it." >&2
        rollback_sshd_fix "$sshd_bin"
        return 1
      fi

      echo "[INFO] PubkeyAuthentication is enabled after fix."
      prune_remote_kit_backups "$sshd_changed_path" 3
    else
      echo "[WARN] PubkeyAuthentication is disabled. Run key.fix or key.add.fix to attempt an automatic fix." >&2
    fi
  elif [ -n "$pubkey_auth" ]; then
    echo "[WARN] Unexpected PubkeyAuthentication value: $pubkey_auth" >&2
  else
    echo "[WARN] PubkeyAuthentication was not reported by sshd -T." >&2
  fi

  if [ -n "$authorized_keys_file" ]; then
    case "$authorized_keys_file" in
      *".ssh/authorized_keys"*)
        echo "[INFO] AuthorizedKeysFile includes .ssh/authorized_keys."
        ;;
      *)
        echo "[WARN] AuthorizedKeysFile is '$authorized_keys_file'; sshd may not read $authorized_keys." >&2
        ;;
    esac
  fi
}

if [ "$action" = "fix" ]; then
  check_or_fix_sshd_config "$sshd_mode"
  exit 0
fi

if [ "$action" = "add" ]; then
  mkdir -p "$ssh_dir"
  chmod 700 "$ssh_dir"

  if [ ! -f "$authorized_keys" ]; then
    touch "$authorized_keys"
  fi
  chmod 600 "$authorized_keys"

  if grep -Fxq "$pubkey" "$authorized_keys"; then
    echo "[INFO] Public key already exists."
  else
    grep_code="$?"
    if [ "$grep_code" -ne 1 ]; then
      echo "[ERROR] Failed to read authorized_keys: $authorized_keys" >&2
      exit "$grep_code"
    fi
    printf '%s\n' "$pubkey" >> "$authorized_keys"
    echo "[INFO] Public key added."
  fi

  chmod 600 "$authorized_keys"
  check_or_fix_sshd_config "$sshd_mode"
  exit 0
fi

if [ ! -f "$authorized_keys" ]; then
  echo "[WARN] authorized_keys not found, nothing to remove."
  exit 0
fi

tmp_file="$(mktemp "$ssh_dir/.authorized_keys.tmp.XXXXXX")"
chmod 600 "$tmp_file"

if ! awk -v key="$pubkey" '
  {
    line = $0
    sub(/\r$/, "", line)
    if (line != key) {
      print $0
    }
  }
' "$authorized_keys" > "$tmp_file"; then
  echo "[ERROR] Failed to rewrite authorized_keys safely: $authorized_keys" >&2
  exit 1
fi

mv "$tmp_file" "$authorized_keys"
tmp_file=""
chmod 600 "$authorized_keys"
echo "[INFO] Public key removed."
