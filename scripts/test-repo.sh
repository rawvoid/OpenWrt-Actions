#!/usr/bin/env bash
# Repository integrity, linting, workflow sync, and verify.sh unit tests.
# Can be run locally and in GitHub Actions without cloning OpenWrt sources.

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO_ROOT"

failures=0

log_section() {
  printf '\n==> %s\n' "$1"
}

pass() {
  printf '  [PASS] %s\n' "$1"
}

fail() {
  printf '  [FAIL] %s\n' "$1" >&2
  failures=$((failures + 1))
}

require_tool() {
  if ! command -v "$1" >/dev/null 2>&1; then
    echo "ERROR: Required tool not found in PATH: $1" >&2
    exit 1
  fi
}

require_tool sh
require_tool bash
require_tool shellcheck
require_tool python3

# 1. Check LF line endings across all repository files
log_section "Checking LF line endings"
crlf_files="$(python3 - <<'PY'
import pathlib

bad = []
for p in sorted(pathlib.Path(".").rglob("*")):
    if not p.is_file() or ".git" in p.parts:
        continue
    data = p.read_bytes()
    if b"\r" in data:
        bad.append(str(p))
print("\n".join(bad))
PY
)"
if [ -n "$crlf_files" ]; then
  fail "Files containing CR/CRLF line endings: $(printf '%s' "$crlf_files" | tr '\n' ' ')"
else
  pass "All files use LF line endings"
fi

# 2. Check executable permissions on scripts and target boot scripts
log_section "Checking executable permissions"
exec_targets=()
while IFS= read -r f; do
  exec_targets+=("$f")
done < <(
  find scripts devices common -type f \( \
    -path 'scripts/*.sh' -o \
    -path 'devices/*/verify.sh' -o \
    -path 'devices/*/pre-defconfig.sh' -o \
    -path 'common/files/etc/uci-defaults/*' -o \
    -path 'common/files/etc/init.d/*' -o \
    -path 'devices/*/files/etc/uci-defaults/*' -o \
    -path 'devices/*/files/etc/init.d/*' -o \
    -path 'devices/*/files/etc/rc.local' \
  \) | sort
)

for f in "${exec_targets[@]}"; do
  if [ -x "$f" ]; then
    pass "Executable (+x): $f"
  else
    fail "Missing +x permission: $f"
  fi
done

# 3. Ensure no legacy opkg references exist in common or apk-based device scripts
log_section "Checking apk-clean uci-defaults (no opkg)"
if [ -d common/files/etc/uci-defaults ]; then
  while IFS= read -r f; do
    if grep -Eiq '\bopkg\b' "$f"; then
      fail "Forbidden 'opkg' reference in $f"
    else
      pass "No 'opkg' in $f"
    fi
  done < <(find common/files/etc/uci-defaults -type f | sort)
fi

for dev_dir in devices/*; do
  [ -d "$dev_dir" ] || continue
  if [ -f "${dev_dir}/device.env" ]; then
    pkg_mgr="$(
      # shellcheck disable=SC1091
      source "${dev_dir}/device.env"
      printf '%s' "${PKG_MANAGER:-apk}"
    )"
    if [ "$pkg_mgr" = "apk" ] && [ -d "${dev_dir}/files/etc/uci-defaults" ]; then
      while IFS= read -r f; do
        if grep -Eiq '\bopkg\b' "$f"; then
          fail "Forbidden 'opkg' reference in apk-based device script: $f"
        else
          pass "No 'opkg' in $f"
        fi
      done < <(find "${dev_dir}/files/etc/uci-defaults" -type f | sort)
    fi
  fi
done

# 4. Basic secret leak guard scan
log_section "Running secret-leak guard scan"
secret_hits="$(python3 - <<'PY'
import pathlib, re

patterns = [
    re.compile(r"-----BEGIN [A-Z ]*PRIVATE KEY-----"),
    re.compile(r"(?i)(pppoe_pass|api_key|api_secret|access_key_secret|zerotier_network_id)\s*=\s*['\"]?[A-Za-z0-9_/+=-]{6,}"),
]
hits = []
for p in sorted(pathlib.Path(".").rglob("*")):
    if not p.is_file() or ".git" in p.parts:
        continue
    if p == pathlib.Path("scripts/test-repo.sh"):
        continue
    try:
        text = p.read_text(encoding="utf-8")
    except UnicodeDecodeError:
        continue
    for idx, line in enumerate(text.splitlines(), 1):
        for pat in patterns:
            if pat.search(line):
                hits.append(f"{p}:{idx}")
print("\n".join(hits))
PY
)"
if [ -n "$secret_hits" ]; then
  fail "Potential hardcoded secret detected at: $(printf '%s' "$secret_hits" | tr '\n' ' ')"
else
  pass "No private keys or hardcoded credentials found"
fi

# 5. Validate GitHub Actions YAML & sync between devices/ and build.yml options
log_section "Validating workflows and device options sync"
if python3 -c "import yaml" >/dev/null 2>&1; then
  for wf in .github/workflows/*.yml; do
    [ -f "$wf" ] || continue
    if python3 - "$wf" <<'PY'
import sys, yaml
with open(sys.argv[1], "r", encoding="utf-8") as fh:
    yaml.safe_load(fh)
PY
    then
      pass "Valid YAML: $wf"
    else
      fail "Invalid YAML syntax: $wf"
    fi
  done

  if python3 - <<'PY'
import pathlib, sys, yaml

with open(".github/workflows/build.yml", "r", encoding="utf-8") as fh:
    wf = yaml.safe_load(fh)

on_cfg = wf.get("on", wf.get(True, {}))
dev_input = on_cfg["workflow_dispatch"]["inputs"]["device"]
wf_options = sorted(dev_input.get("options", []))
wf_default = dev_input.get("default")
disk_devices = sorted(p.name for p in pathlib.Path("devices").iterdir() if p.is_dir())

if wf_options != disk_devices:
    print(f"Mismatch: build.yml options={wf_options} vs devices/={disk_devices}", file=sys.stderr)
    sys.exit(1)
if wf_default not in wf_options:
    print(f"Default device '{wf_default}' is not in options={wf_options}", file=sys.stderr)
    sys.exit(1)
PY
  then
    pass "build.yml device choices match devices/ directory"
  else
    fail "build.yml device choices are out of sync with devices/"
  fi
else
  fail "PyYAML is required to validate .github/workflows/*.yml"
fi

# 6. Validate each device profile metadata
log_section "Validating device profiles"
for dev_dir in devices/*; do
  [ -d "$dev_dir" ] || continue
  dev_name="$(basename "$dev_dir")"

  if [ ! -f "${dev_dir}/device.env" ]; then
    fail "Missing ${dev_dir}/device.env"
    continue
  fi
  if [ ! -f "${dev_dir}/seed.config" ]; then
    fail "Missing ${dev_dir}/seed.config"
  fi

  if (
    set -euo pipefail
    # shellcheck disable=SC1091
    source "${dev_dir}/device.env"
    [ "${DEVICE_NAME:-}" = "$dev_name" ]
    [ -n "${UPSTREAM_FLAVOR:-}" ]
    [ -n "${UPSTREAM_REPO:-}" ]
    [ -n "${UPSTREAM_REF:-}" ]
    [ -n "${TARGET_DIR:-}" ]
    [ -n "${ARTIFACT_GLOB:-}" ]
    [ -n "${PKG_MANAGER:-}" ]
    if [ -n "${DEFAULT_LAN_IP:-}" ]; then
      ./scripts/configure-lan-ip.sh validate "${DEFAULT_LAN_IP}"
    fi
  ); then
    pass "Valid device.env metadata for ${dev_name}"
  else
    fail "Invalid or incomplete device.env in ${dev_dir}"
  fi
done

# 7. Syntax check and ShellCheck for target (POSIX sh) and host (bash) scripts
log_section "Running shell syntax checks and ShellCheck"
while IFS= read -r f; do
  if sh -n "$f" && shellcheck -s sh "$f"; then
    pass "POSIX sh + shellcheck: $f"
  else
    fail "POSIX sh / shellcheck failed: $f"
  fi
done < <(
  find common devices -type f \( \
    -path 'common/files/etc/uci-defaults/*' -o \
    -path 'common/files/etc/init.d/*' -o \
    -path 'devices/*/files/etc/uci-defaults/*' -o \
    -path 'devices/*/files/etc/init.d/*' -o \
    -path 'devices/*/files/etc/rc.local' \
  \) | sort
)

while IFS= read -r f; do
  if bash -n "$f" && shellcheck -s bash "$f"; then
    pass "bash + shellcheck: $f"
  else
    fail "bash / shellcheck failed: $f"
  fi
done < <(
  find scripts devices -type f \( \
    -path 'scripts/*.sh' -o \
    -path 'devices/*/verify.sh' -o \
    -path 'devices/*/pre-defconfig.sh' \
  \) | sort
)

# 8. Unit-test devices/n3160-i210/verify.sh against synthetic fixtures
log_section "Unit-testing devices/n3160-i210/verify.sh"
tmp_dir="$(mktemp -d)"
trap 'rm -rf "$tmp_dir"' EXIT

cp devices/n3160-i210/seed.config "${tmp_dir}/pass.config"

if devices/n3160-i210/verify.sh "${tmp_dir}/pass.config" >/dev/null 2>&1; then
  pass "verify.sh accepts valid n3160-i210 seed.config"
else
  fail "verify.sh unexpectedly rejected valid n3160-i210 seed.config"
fi

run_negative_fixture() {
  local name="$1"
  local cfg_path="$2"
  if devices/n3160-i210/verify.sh "$cfg_path" >/dev/null 2>&1; then
    fail "verify.sh failed to reject negative fixture: ${name}"
  else
    pass "verify.sh rejected negative fixture: ${name}"
  fi
}

sed 's/-march=silvermont/-march=goldmont/' "${tmp_dir}/pass.config" > "${tmp_dir}/bad_arch.config"
run_negative_fixture "goldmont arch" "${tmp_dir}/bad_arch.config"

sed 's/-O2/-O3/' "${tmp_dir}/pass.config" > "${tmp_dir}/bad_o3.config"
run_negative_fixture "-O3 flag" "${tmp_dir}/bad_o3.config"

sed 's/CONFIG_GRUB_TIMEOUT="3"/CONFIG_GRUB_TIMEOUT="0"/' "${tmp_dir}/pass.config" > "${tmp_dir}/bad_grub_timeout.config"
run_negative_fixture "GRUB_TIMEOUT=0" "${tmp_dir}/bad_grub_timeout.config"

grep -vxF 'CONFIG_GRUB_IMAGES=y' "${tmp_dir}/pass.config" > "${tmp_dir}/missing_legacy_grub.config"
run_negative_fixture "missing CONFIG_GRUB_IMAGES" "${tmp_dir}/missing_legacy_grub.config"

for bad_sym in \
  "CONFIG_PACKAGE_kmod-mac80211=y" \
  "CONFIG_PACKAGE_wpad-basic-openssl=y" \
  "CONFIG_PACKAGE_luci-app-ddns-go=y" \
  "CONFIG_PACKAGE_ethtool=y" \
  "CONFIG_PACKAGE_miniupnpd-iptables=y" \
  "CONFIG_PACKAGE_iptables-zz-legacy=y" \
  "CONFIG_VDI_IMAGES=y" \
  "CONFIG_PACKAGE_zram-swap=y" \
  "CONFIG_PACKAGE_irqbalance=y" \
  "CONFIG_PACKAGE_automount=y" \
  "CONFIG_PACKAGE_kmod-drm-i915=y" \
  "CONFIG_PACKAGE_i915-firmware-dmc=y"; do
  fixture_file="${tmp_dir}/bad_${bad_sym//=/_}.config"
  cp "${tmp_dir}/pass.config" "$fixture_file"
  printf '%s\n' "$bad_sym" >> "$fixture_file"
  run_negative_fixture "$bad_sym" "$fixture_file"
done

# 8b. Unit-test devices/redmi-ax6-stock/verify.sh against synthetic fixtures
log_section "Unit-testing devices/redmi-ax6-stock/verify.sh"
cp devices/redmi-ax6-stock/seed.config "${tmp_dir}/ax6_pass.config"

if devices/redmi-ax6-stock/verify.sh "${tmp_dir}/ax6_pass.config" >/dev/null 2>&1; then
  pass "verify.sh accepts valid redmi-ax6-stock seed.config"
else
  fail "verify.sh unexpectedly rejected valid redmi-ax6-stock seed.config"
fi

run_ax6_negative_fixture() {
  local script_path="$1"
  local name="$2"
  local cfg_path="$3"
  if "$script_path" "$cfg_path" >/dev/null 2>&1; then
    fail "${script_path} failed to reject negative fixture: ${name}"
  else
    pass "${script_path} rejected negative fixture: ${name}"
  fi
}

sed 's/-Os/-O2/' "${tmp_dir}/ax6_pass.config" > "${tmp_dir}/ax6_bad_opt.config"
run_ax6_negative_fixture devices/redmi-ax6-stock/verify.sh "missing -Os flag" "${tmp_dir}/ax6_bad_opt.config"

sed 's/-mcpu=cortex-a53+crc+crypto/-march=silvermont/' "${tmp_dir}/ax6_pass.config" > "${tmp_dir}/ax6_bad_cpu.config"
run_ax6_negative_fixture devices/redmi-ax6-stock/verify.sh "wrong x86 arch" "${tmp_dir}/ax6_bad_cpu.config"

for bad_sym in \
  "CONFIG_TARGET_qualcommax_ipq807x_DEVICE_redmi_ax6=y" \
  "CONFIG_TARGET_ROOTFS_INITRAMFS=y" \
  "CONFIG_PACKAGE_vim-full=y" \
  "CONFIG_PACKAGE_vim-runtime=y" \
  "CONFIG_PACKAGE_nano=y" \
  "CONFIG_PACKAGE_bind-host=y" \
  "CONFIG_PACKAGE_luci-theme-argon=y" \
  "CONFIG_PACKAGE_luci-app-autoreboot=y" \
  "CONFIG_PACKAGE_luci-app-smartdns=y" \
  "CONFIG_PACKAGE_luci-app-ttyd=y" \
  "CONFIG_PACKAGE_socat=y" \
  "CONFIG_PACKAGE_luci-app-usteer=y" \
  "CONFIG_PACKAGE_miniupnpd-iptables=y" \
  "CONFIG_PACKAGE_iptables-zz-legacy=y" \
  "CONFIG_PACKAGE_automount=y" \
  "CONFIG_PACKAGE_kmod-usb3=y" \
  "CONFIG_PACKAGE_kmod-phy-aquantia=y"; do
  fixture_file="${tmp_dir}/ax6_bad_${bad_sym//=/_}.config"
  cp "${tmp_dir}/ax6_pass.config" "$fixture_file"
  printf '%s\n' "$bad_sym" >> "$fixture_file"
  run_ax6_negative_fixture devices/redmi-ax6-stock/verify.sh "$bad_sym" "$fixture_file"
done

# 8c. Unit-test devices/redmi-ax6-stock-nss/verify.sh against synthetic fixtures
log_section "Unit-testing devices/redmi-ax6-stock-nss/verify.sh"
cp devices/redmi-ax6-stock-nss/seed.config "${tmp_dir}/ax6_nss_pass.config"

if devices/redmi-ax6-stock-nss/verify.sh "${tmp_dir}/ax6_nss_pass.config" >/dev/null 2>&1; then
  pass "verify.sh accepts valid redmi-ax6-stock-nss seed.config"
else
  fail "verify.sh unexpectedly rejected valid redmi-ax6-stock-nss seed.config"
fi

grep -vxF 'CONFIG_NSS_MEM_PROFILE_MEDIUM=y' "${tmp_dir}/ax6_nss_pass.config" > "${tmp_dir}/ax6_nss_no_512m.config"
run_ax6_negative_fixture devices/redmi-ax6-stock-nss/verify.sh "missing 512M NSS profile" "${tmp_dir}/ax6_nss_no_512m.config"

grep -vxF 'CONFIG_PACKAGE_sqm-scripts-nss=y' "${tmp_dir}/ax6_nss_pass.config" > "${tmp_dir}/ax6_nss_no_sqm.config"
run_ax6_negative_fixture devices/redmi-ax6-stock-nss/verify.sh "missing sqm-scripts-nss" "${tmp_dir}/ax6_nss_no_sqm.config"

for bad_sym in \
  "CONFIG_TARGET_qualcommax_ipq807x_DEVICE_redmi_ax6=y" \
  "CONFIG_NSS_MEM_PROFILE_HIGH=y" \
  "CONFIG_ATH11K_MEM_PROFILE_1G=y" \
  "CONFIG_FEED_nss_packages=y" \
  "CONFIG_FEED_sqm_scripts_nss=y" \
  "CONFIG_PACKAGE_e2fsprogs=y" \
  "CONFIG_PACKAGE_f2fs-tools=y" \
  "CONFIG_PACKAGE_kmod-ath11k-pci=y" \
  "CONFIG_PACKAGE_kmod-phy-aquantia=y" \
  "CONFIG_PACKAGE_vim-full=y" \
  "CONFIG_PACKAGE_bind-host=y" \
  "CONFIG_PACKAGE_luci-theme-argon=y" \
  "CONFIG_PACKAGE_luci-app-autoreboot=y"; do
  fixture_file="${tmp_dir}/ax6_nss_bad_${bad_sym//=/_}.config"
  cp "${tmp_dir}/ax6_nss_pass.config" "$fixture_file"
  printf '%s\n' "$bad_sym" >> "$fixture_file"
  run_ax6_negative_fixture devices/redmi-ax6-stock-nss/verify.sh "$bad_sym" "$fixture_file"
done

# 9. Unit-test scripts/collect-artifacts.sh against synthetic output
log_section "Unit-testing scripts/collect-artifacts.sh"
mock_owrt="${tmp_dir}/mock_openwrt"
mock_bin="${mock_owrt}/bin/targets/x86/64"
mock_out="${tmp_dir}/mock_out"
mkdir -p "$mock_bin" "${mock_owrt}/scripts"
printf 'dummy-legacy-image\n' > "${mock_bin}/immortalwrt-25.12.2-x86-64-generic-squashfs-combined.img.gz"
printf 'dummy-efi-image\n' > "${mock_bin}/immortalwrt-25.12.2-x86-64-generic-squashfs-combined-efi.img.gz"
printf 'dummy-rootfs-only\n' > "${mock_bin}/immortalwrt-25.12.2-x86-64-generic-squashfs-rootfs.img.gz"
printf 'CONFIG_TARGET_OPTIMIZATION="-O2 -pipe -march=silvermont -maes -mpclmul"\n' > "${mock_owrt}/.config"
printf 'All checks passed\n' > "${tmp_dir}/verify.log"

# shellcheck disable=SC2016
if EFFECTIVE_REF="v25.12.2" UPSTREAM_COMMIT="abc1234" \
  EFFECTIVE_LAN_IP="10.11.1.1" \
  ./scripts/collect-artifacts.sh devices/n3160-i210/device.env "$mock_owrt" "$mock_out" "${tmp_dir}/verify.log" >/dev/null && \
  [ -f "${mock_out}/sha256sums" ] && \
  [ -f "${mock_out}/release-body.md" ] && \
  [ -f "${mock_out}/immortalwrt-25.12.2-x86-64-generic-squashfs-combined.img.gz" ] && \
  [ -f "${mock_out}/immortalwrt-25.12.2-x86-64-generic-squashfs-combined-efi.img.gz" ] && \
  [ ! -e "${mock_out}/immortalwrt-25.12.2-x86-64-generic-squashfs-rootfs.img.gz" ] && \
  grep -q 'generic-squashfs-combined.img.gz' "${mock_out}/release-body.md" && \
  grep -q 'generic-squashfs-combined-efi.img.gz' "${mock_out}/release-body.md" && \
  grep -q 'march=silvermont' "${mock_out}/release-body.md" && \
  grep -qF '**Default LAN IP**: `10.11.1.1`' "${mock_out}/release-body.md"; then
  pass "collect-artifacts.sh collects dual Legacy+UEFI firmware, checksums, and release notes"
else
  fail "collect-artifacts.sh synthetic run failed"
fi

mock_ax6_owrt="${tmp_dir}/mock_openwrt_ax6"
mock_ax6_bin="${mock_ax6_owrt}/bin/targets/qualcommax/ipq807x"
mock_ax6_out="${tmp_dir}/mock_out_ax6"
mkdir -p "$mock_ax6_bin" "${mock_ax6_owrt}/scripts"
printf 'dummy-factory-ubi\n' > "${mock_ax6_bin}/libwrt-25.12.2-qualcommax-ipq807x-redmi_ax6-stock-squashfs-factory.ubi"
printf 'dummy-sysupgrade-bin\n' > "${mock_ax6_bin}/libwrt-25.12.2-qualcommax-ipq807x-redmi_ax6-stock-squashfs-sysupgrade.bin"
printf 'dummy-initramfs\n' > "${mock_ax6_bin}/libwrt-25.12.2-qualcommax-ipq807x-redmi_ax6-stock-initramfs-uImage.itb"
printf 'CONFIG_TARGET_OPTIMIZATION="-Os -pipe -mcpu=cortex-a53+crc+crypto"\n' > "${mock_ax6_owrt}/.config"

# shellcheck disable=SC2016
if EFFECTIVE_REF="v25.12.2" UPSTREAM_COMMIT="def5678" \
  EFFECTIVE_LAN_IP="192.168.10.1" \
  ./scripts/collect-artifacts.sh devices/redmi-ax6-stock-nss/device.env "$mock_ax6_owrt" "$mock_ax6_out" "${tmp_dir}/verify.log" >/dev/null && \
  [ -f "${mock_ax6_out}/libwrt-25.12.2-qualcommax-ipq807x-redmi_ax6-stock-squashfs-factory.ubi" ] && \
  [ -f "${mock_ax6_out}/libwrt-25.12.2-qualcommax-ipq807x-redmi_ax6-stock-squashfs-sysupgrade.bin" ] && \
  [ ! -e "${mock_ax6_out}/libwrt-25.12.2-qualcommax-ipq807x-redmi_ax6-stock-initramfs-uImage.itb" ] && \
  grep -q 'redmi_ax6-stock-squashfs-factory.ubi' "${mock_ax6_out}/release-body.md" && \
  grep -q 'redmi_ax6-stock-squashfs-sysupgrade.bin' "${mock_ax6_out}/release-body.md" && \
  grep -q 'mcpu=cortex-a53+crc+crypto' "${mock_ax6_out}/release-body.md" && \
  grep -qF '**Default LAN IP**: `192.168.10.1`' "${mock_ax6_out}/release-body.md"; then
  pass "collect-artifacts.sh collects Redmi AX6 factory.ubi + sysupgrade.bin and skips initramfs"
else
  fail "collect-artifacts.sh synthetic Redmi AX6 run failed"
fi

rm -f "${mock_bin}"/*.img.gz
if ./scripts/collect-artifacts.sh devices/n3160-i210/device.env "$mock_owrt" "${tmp_dir}/mock_empty_out" >/dev/null 2>&1; then
  fail "collect-artifacts.sh should fail when no files match ARTIFACT_GLOB"
else
  pass "collect-artifacts.sh fails clearly when no firmware matches ARTIFACT_GLOB"
fi

# 10. Unit-test scripts/configure-lan-ip.sh (validation & config_generate patching)
log_section "Unit-testing scripts/configure-lan-ip.sh"
for good_ip in "10.11.1.1" "192.168.1.1" "192.168.50.254" "172.16.0.1" "172.31.255.1"; do
  if ./scripts/configure-lan-ip.sh validate "$good_ip" >/dev/null 2>&1; then
    pass "configure-lan-ip.sh accepts valid RFC1918 IP: ${good_ip}"
  else
    fail "configure-lan-ip.sh rejected valid RFC1918 IP: ${good_ip}"
  fi
done

for bad_ip in \
  "" \
  "10.11.1.0" \
  "10.11.1.255" \
  "10.11.1.1/24" \
  "10.11.1.256" \
  "010.11.1.1" \
  "10.11.1" \
  "8.8.8.8" \
  "127.0.0.1" \
  "0.0.0.0" \
  "169.254.1.1" \
  "172.32.0.1" \
  " 10.11.1.1"; do
  if ./scripts/configure-lan-ip.sh validate "$bad_ip" >/dev/null 2>&1; then
    fail "configure-lan-ip.sh failed to reject invalid IP: '${bad_ip}'"
  else
    pass "configure-lan-ip.sh rejected invalid IP: '${bad_ip}'"
  fi
done

mock_cg_file="${tmp_dir}/config_generate"
cat > "$mock_cg_file" <<'EOF'
#!/bin/sh
generate_network() {
	case "$protocol" in
		static)
			local ipad netm prefix
			case "$1" in
				lan) ipad=${ipaddr:-"192.168.1.1"} ;;
				*) ipad=${ipaddr:-"192.168.$((addr_offset++)).1"} ;;
			esac
			netm=${netmask:-"255.255.255.0"}
			;;
	esac
}
EOF
chmod +x "$mock_cg_file"

# shellcheck disable=SC2016
if ./scripts/configure-lan-ip.sh apply "$mock_cg_file" "10.11.1.1" >/dev/null && \
  [ -x "$mock_cg_file" ] && \
  grep -qF 'lan) ipad=${ipaddr:-"10.11.1.1"} ;;' "$mock_cg_file" && \
  grep -qF '*) ipad=${ipaddr:-"192.168.$((addr_offset++)).1"} ;;' "$mock_cg_file"; then
  pass "configure-lan-ip.sh updates config_generate LAN IP without touching non-LAN branch"
else
  fail "configure-lan-ip.sh failed to patch standard config_generate"
fi

# shellcheck disable=SC2016
if ./scripts/configure-lan-ip.sh apply "$mock_cg_file" "192.168.1.1" >/dev/null && \
  grep -qF 'lan) ipad=${ipaddr:-"192.168.1.1"} ;;' "$mock_cg_file"; then
  pass "configure-lan-ip.sh supports overriding back to 192.168.1.1"
else
  fail "configure-lan-ip.sh failed when overriding back to 192.168.1.1"
fi

mock_bad_cg_file="${tmp_dir}/bad_config_generate"
printf '#!/bin/sh\necho no ip here\n' > "$mock_bad_cg_file"
if ./scripts/configure-lan-ip.sh apply "$mock_bad_cg_file" "10.11.1.1" >/dev/null 2>&1; then
  fail "configure-lan-ip.sh should fail when config_generate lacks LAN IP pattern"
else
  pass "configure-lan-ip.sh fails clearly when config_generate lacks LAN IP pattern"
fi

printf '\n=== Repository check finished with %d failure(s) ===\n' "$failures"
if [ "$failures" -gt 0 ]; then
  exit 1
fi
