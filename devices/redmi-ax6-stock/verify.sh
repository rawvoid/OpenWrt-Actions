#!/usr/bin/env bash
# Fail-Fast .config verification script for devices/redmi-ax6-stock.
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

forbid_cfg() {
  local sym="$1"
  if grep -qxF "${sym}=y" "$CONFIG_FILE"; then
    fail "Forbidden symbol enabled: ${sym}=y"
  else
    pass "Not enabled: ${sym}"
  fi
}

echo "=== Verifying redmi-ax6-stock configuration: $CONFIG_FILE ==="

# 1. Target platform & stock layout safety guard
require_cfg "CONFIG_TARGET_qualcommax"
require_cfg "CONFIG_TARGET_qualcommax_ipq807x"
require_cfg "CONFIG_TARGET_qualcommax_ipq807x_DEVICE_redmi_ax6-stock"
require_cfg "CONFIG_TARGET_ROOTFS_SQUASHFS"
forbid_cfg "CONFIG_TARGET_qualcommax_ipq807x_DEVICE_redmi_ax6"

# 2. Compiler options & ARMv8 Cortex-A53 optimization flags
require_cfg "CONFIG_DEVEL"
require_cfg "CONFIG_TARGET_OPTIONS"
require_cfg "CONFIG_CCACHE"

opt_line="$(grep -E '^CONFIG_TARGET_OPTIMIZATION=' "$CONFIG_FILE" || true)"
if [ -z "$opt_line" ]; then
  fail "Missing CONFIG_TARGET_OPTIMIZATION"
else
  if printf '%s' "$opt_line" | grep -q -- '-mcpu=cortex-a53+crc+crypto'; then
    pass "CONFIG_TARGET_OPTIMIZATION includes -mcpu=cortex-a53+crc+crypto"
  else
    fail "CONFIG_TARGET_OPTIMIZATION missing -mcpu=cortex-a53+crc+crypto: $opt_line"
  fi
  if printf '%s' "$opt_line" | grep -q -- '-Os'; then
    pass "CONFIG_TARGET_OPTIMIZATION uses compact -Os for stock NAND"
  else
    fail "CONFIG_TARGET_OPTIMIZATION missing -Os: $opt_line"
  fi
  if printf '%s' "$opt_line" | grep -Eq '(-O3|-march=silvermont|-mavx)'; then
    fail "CONFIG_TARGET_OPTIMIZATION contains unsupported/disallowed flag: $opt_line"
  else
    pass "CONFIG_TARGET_OPTIMIZATION avoids -O3/x86 flags"
  fi
fi

# 3. Required hardware drivers, Wi-Fi 6, primary router plugins & utilities
required_packages=(
  kmod-qca-nss-dp
  kmod-ath11k-ahb
  ath11k-firmware-ipq8074
  ipq-wifi-redmi_ax6
  wpad-openssl
  uboot-envtools
  autocore
  luci-app-cpufreq
  luci-i18n-cpufreq-zh-cn
  kmod-tcp-bbr
  kmod-sched-cake
  kmod-tun
  ppp
  ppp-mod-pppoe
  luci-proto-ppp
  odhcp6c
  odhcpd-ipv6only
  luci-proto-ipv6
  luci-app-upnp
  luci-i18n-upnp-zh-cn
  miniupnpd-nftables
  luci-app-ddns
  luci-i18n-ddns-zh-cn
  ddns-scripts
  ddns-scripts-aliyun
  ddns-scripts-cloudflare
  openssl-util
  luci-app-wol
  luci-i18n-wol-zh-cn
  luci-app-vlmcsd
  luci-i18n-vlmcsd-zh-cn
  luci-app-sqm
  luci-i18n-sqm-zh-cn
  luci-app-watchcat
  luci-i18n-watchcat-zh-cn
  luci-proto-wireguard
  wireguard-tools
  kmod-wireguard
  luci-app-zerotier
  luci-i18n-zerotier-zh-cn
  luci-app-nlbwmon
  luci-i18n-nlbwmon-zh-cn
  luci-app-arpbind
  luci-i18n-arpbind-zh-cn
  luci
  luci-ssl-openssl
  luci-theme-bootstrap
  default-settings-chn
  luci-i18n-base-zh-cn
  luci-i18n-firewall-zh-cn
  luci-i18n-package-manager-zh-cn
  openssh-sftp-server
  curl
  ca-bundle
  htop
  iperf3
  tcpdump-mini
  ip-full
  vim
)

for pkg in "${required_packages[@]}"; do
  require_cfg "CONFIG_PACKAGE_${pkg}"
done

# 4. Forbidden bloat, excluded plugins, unused hardware drivers & conflicting packages
forbidden_symbols=(
  CONFIG_TARGET_ROOTFS_INITRAMFS
  CONFIG_TARGET_ROOTFS_EXT4FS
  CONFIG_TARGET_ROOTFS_TARGZ
  CONFIG_PACKAGE_automount
  CONFIG_PACKAGE_block-mount
  CONFIG_PACKAGE_losetup
  CONFIG_PACKAGE_kmod-usb3
  CONFIG_PACKAGE_kmod-usb-dwc3
  CONFIG_PACKAGE_kmod-usb-dwc3-qcom
  CONFIG_PACKAGE_kmod-phy-aquantia
  CONFIG_PACKAGE_miniupnpd-iptables
  CONFIG_PACKAGE_iptables-zz-legacy
  CONFIG_PACKAGE_bind-host
  CONFIG_PACKAGE_luci-app-ddns-go
  CONFIG_PACKAGE_luci-app-autoreboot
  CONFIG_PACKAGE_luci-app-smartdns
  CONFIG_PACKAGE_smartdns
  CONFIG_PACKAGE_luci-app-ttyd
  CONFIG_PACKAGE_socat
  CONFIG_PACKAGE_luci-app-usteer
  CONFIG_PACKAGE_dawn
  CONFIG_PACKAGE_luci-theme-argon
  CONFIG_PACKAGE_luci-app-argon-config
  CONFIG_PACKAGE_ip-tiny
  CONFIG_PACKAGE_vim-full
  CONFIG_PACKAGE_vim-fuller
  CONFIG_PACKAGE_vim-runtime
  CONFIG_PACKAGE_nano
)

for sym in "${forbidden_symbols[@]}"; do
  forbid_cfg "$sym"
done

echo "=== Verification finished with ${failures} failure(s) ==="
if [ "$failures" -gt 0 ]; then
  exit 1
fi
