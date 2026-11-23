#!/usr/bin/env bash
# Fail-Fast .config verification script for devices/n3160-i210.
# Usage: ./verify.sh [path/to/.config]

set -euo pipefail

CONFIG_FILE="${1:-.config}"

if [ ! -f "$CONFIG_FILE" ]; then
  echo "ERROR: Config file not found: $CONFIG_FILE" >&2
  exit 1
fi

failures=0

pass() {
  printf '  [PASS] %s\n' "$1"
}

fail() {
  printf '  [FAIL] %s\n' "$1" >&2
  failures=$((failures + 1))
}

require_cfg() {
  local sym="$1"
  if grep -qxF "${sym}=y" "$CONFIG_FILE"; then
    pass "${sym}=y"
  else
    fail "Missing required symbol: ${sym}=y"
  fi
}

require_cfg_exact() {
  local line="$1"
  if grep -qxF "$line" "$CONFIG_FILE"; then
    pass "$line"
  else
    fail "Missing required setting: $line"
  fi
}

forbid_cfg() {
  local sym="$1"
  if grep -qxF "${sym}=y" "$CONFIG_FILE"; then
    fail "Forbidden symbol enabled: ${sym}=y"
  else
    pass "Not enabled: ${sym}"
  fi
}

forbid_cfg_regex() {
  local label="$1"
  local pattern="$2"
  local matches
  matches="$(grep -E "$pattern" "$CONFIG_FILE" || true)"
  if [ -n "$matches" ]; then
    fail "Forbidden pattern matched (${label}): $(printf '%s' "$matches" | tr '\n' ' ')"
  else
    pass "No forbidden ${label} symbols enabled"
  fi
}

echo "=== Verifying n3160-i210 configuration: $CONFIG_FILE ==="

# 1. Target & image format
require_cfg "CONFIG_TARGET_x86_64"
require_cfg "CONFIG_TARGET_x86_64_DEVICE_generic"
require_cfg "CONFIG_TARGET_ROOTFS_SQUASHFS"
require_cfg "CONFIG_GRUB_EFI_IMAGES"
require_cfg_exact "CONFIG_TARGET_ROOTFS_PARTSIZE=512"

# 2. Compiler options & Braswell/Airmont optimization flags
require_cfg "CONFIG_DEVEL"
require_cfg "CONFIG_TARGET_OPTIONS"
require_cfg "CONFIG_CCACHE"

opt_line="$(grep -E '^CONFIG_TARGET_OPTIMIZATION=' "$CONFIG_FILE" || true)"
if [ -z "$opt_line" ]; then
  fail "Missing CONFIG_TARGET_OPTIMIZATION"
else
  if printf '%s' "$opt_line" | grep -q -- '-march=silvermont'; then
    pass "CONFIG_TARGET_OPTIMIZATION includes -march=silvermont"
  else
    fail "CONFIG_TARGET_OPTIMIZATION missing -march=silvermont: $opt_line"
  fi
  if printf '%s' "$opt_line" | grep -Eq '(-O3|goldmont|x86-64-v3|-mavx)'; then
    fail "CONFIG_TARGET_OPTIMIZATION contains unsupported/disallowed flag: $opt_line"
  else
    pass "CONFIG_TARGET_OPTIMIZATION avoids -O3/goldmont/x86-64-v3/AVX"
  fi
fi

# 3. Required hardware drivers, kernel modules & packages
required_packages=(
  kmod-igb
  kmod-itco-wdt
  intel-microcode
  kmod-hwmon-coretemp
  lm-sensors
  pciutils
  ethtool-full
  kmod-crypto-gcm
  kmod-crypto-sha256
  kmod-tcp-bbr
  kmod-tun
  ppp
  ppp-mod-pppoe
  luci-proto-ppp
  odhcp6c
  odhcpd-ipv6only
  luci-proto-ipv6
  miniupnpd-nftables
  luci
  luci-ssl-openssl
  luci-app-wol
  luci-app-vlmcsd
  luci-app-upnp
  luci-app-ddns
  ddns-scripts
  ddns-scripts-aliyun
  ddns-scripts-cloudflare
  bind-host
  openssl-util
  luci-app-zerotier
  luci-theme-argon
  luci-app-argon-config
  luci-theme-bootstrap
  luci-i18n-base-zh-cn
  luci-i18n-firewall-zh-cn
  luci-i18n-package-manager-zh-cn
  luci-i18n-wol-zh-cn
  luci-i18n-vlmcsd-zh-cn
  luci-i18n-upnp-zh-cn
  luci-i18n-ddns-zh-cn
  luci-i18n-zerotier-zh-cn
  luci-i18n-argon-config-zh-cn
  htop
  vim-full
  openssh-sftp-server
  curl
  ca-bundle
  ip-full
  tcpdump-mini
  iperf3
  mtr-nojson
  bind-dig
)

for pkg in "${required_packages[@]}"; do
  require_cfg "CONFIG_PACKAGE_${pkg}"
done

# 4. Forbidden wireless stack, conflicting/unwanted packages, and VM image formats
forbid_cfg_regex "wireless/Wi-Fi" \
  '^CONFIG_PACKAGE_(kmod-mac80211|kmod-cfg80211|wireless-regdb|iw|iw-full|iwinfo|wpad.*|hostapd.*|wpa-supplicant.*)=y$'

forbidden_symbols=(
  CONFIG_PACKAGE_luci-app-ddns-go
  CONFIG_PACKAGE_ethtool
  CONFIG_PACKAGE_vim
  CONFIG_PACKAGE_ip-tiny
  CONFIG_PACKAGE_miniupnpd-iptables
  CONFIG_PACKAGE_zram-swap
  CONFIG_PACKAGE_irqbalance
  CONFIG_TARGET_ROOTFS_EXT4FS
  CONFIG_TARGET_ROOTFS_TARGZ
  CONFIG_GRUB_IMAGES
  CONFIG_ISO_IMAGES
  CONFIG_VDI_IMAGES
  CONFIG_VMDK_IMAGES
  CONFIG_VHDX_IMAGES
  CONFIG_QCOW2_IMAGES
  CONFIG_PACKAGE_kmod-e1000
  CONFIG_PACKAGE_kmod-e1000e
  CONFIG_PACKAGE_kmod-igc
  CONFIG_PACKAGE_kmod-ixgbe
  CONFIG_PACKAGE_kmod-i40e
  CONFIG_PACKAGE_kmod-r8125
  CONFIG_PACKAGE_kmod-r8126
  CONFIG_PACKAGE_kmod-r8127
  CONFIG_PACKAGE_kmod-r8168
  CONFIG_PACKAGE_kmod-r8169
  CONFIG_PACKAGE_kmod-vmxnet3
)

for sym in "${forbidden_symbols[@]}"; do
  forbid_cfg "$sym"
done

echo "=== Verification finished with ${failures} failure(s) ==="
if [ "$failures" -gt 0 ]; then
  exit 1
fi
