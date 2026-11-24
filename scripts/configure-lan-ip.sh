#!/usr/bin/env bash
# Validate and apply a custom default LAN IPv4 address to config_generate.
# Usage:
#   ./scripts/configure-lan-ip.sh validate <ipv4>
#   ./scripts/configure-lan-ip.sh apply <config_generate_path> <ipv4>

set -euo pipefail

usage() {
  cat >&2 <<EOF
Usage:
  $0 validate <ipv4>
  $0 apply <config_generate_path> <ipv4>
EOF
  exit 1
}

validate_lan_ip() {
  local ip="${1:-}"
  local a b c d

  if [[ ! "$ip" =~ ^(0|[1-9][0-9]{0,2})\.(0|[1-9][0-9]{0,2})\.(0|[1-9][0-9]{0,2})\.(0|[1-9][0-9]{0,2})$ ]]; then
    echo "ERROR: Invalid IPv4 format: '${ip}'" >&2
    return 1
  fi

  a="${BASH_REMATCH[1]}"
  b="${BASH_REMATCH[2]}"
  c="${BASH_REMATCH[3]}"
  d="${BASH_REMATCH[4]}"

  if (( a > 255 || b > 255 || c > 255 || d > 255 )); then
    echo "ERROR: IPv4 octet out of range: '${ip}'" >&2
    return 1
  fi

  if ! (( a == 10 || (a == 172 && b >= 16 && b <= 31) || (a == 192 && b == 168) )); then
    echo "ERROR: LAN IP must be an RFC1918 private address: '${ip}'" >&2
    return 1
  fi

  if (( d == 0 || d == 255 )); then
    echo "ERROR: LAN IP cannot end in .0 or .255: '${ip}'" >&2
    return 1
  fi
}

apply_lan_ip() {
  local target_file="${1:-}"
  local ip="${2:-}"
  local matches tmp_file

  validate_lan_ip "$ip"

  if [ ! -f "$target_file" ]; then
    echo "ERROR: config_generate not found: ${target_file}" >&2
    return 1
  fi

  # shellcheck disable=SC2016
  matches="$(grep -Ec 'lan\)[[:space:]]+ipad=\$\{ipaddr:-"[^"]+"\}[[:space:]]*;;' "$target_file" || true)"
  if [ "$matches" -ne 1 ]; then
    echo "ERROR: Expected 1 LAN IP line in ${target_file}, found ${matches}" >&2
    return 1
  fi

  tmp_file="$(mktemp)"
  # shellcheck disable=SC2016
  if ! sed -E 's|(lan\)[[:space:]]+ipad=\$\{ipaddr:-")[^"]+("\}[[:space:]]*;;)|\1'"${ip}"'\2|' "$target_file" > "$tmp_file" || \
     ! cat "$tmp_file" > "$target_file"; then
    rm -f "$tmp_file"
    return 1
  fi
  rm -f "$tmp_file"

  if ! grep -Fq "ipad=\${ipaddr:-\"${ip}\"}" "$target_file"; then
    echo "ERROR: Failed to verify updated LAN IP '${ip}' in ${target_file}" >&2
    return 1
  fi

  echo "Configured default LAN IP in ${target_file}: ${ip}"
}

if [ "$#" -lt 1 ]; then
  usage
fi

cmd="$1"
shift

case "$cmd" in
  validate)
    [ "$#" -eq 1 ] || usage
    validate_lan_ip "$1"
    ;;
  apply)
    [ "$#" -eq 2 ] || usage
    apply_lan_ip "$1" "$2"
    ;;
  *)
    usage
    ;;
esac
