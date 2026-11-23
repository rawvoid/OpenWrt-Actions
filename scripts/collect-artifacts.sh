#!/usr/bin/env bash
# Collect built firmware artifacts, compute SHA256 checksums, and generate release notes.
# Usage: ./scripts/collect-artifacts.sh <device.env> [openwrt_dir] [output_dir] [verify_log]

set -euo pipefail

if [ "$#" -lt 1 ]; then
  echo "Usage: $0 <device.env> [openwrt_dir] [output_dir] [verify_log]" >&2
  exit 1
fi

DEVICE_ENV="$1"
OPENWRT_DIR="${2:-openwrt}"
OUTPUT_DIR="${3:-output}"
VERIFY_LOG="${4:-}"

if [ ! -f "$DEVICE_ENV" ]; then
  echo "ERROR: device.env not found: $DEVICE_ENV" >&2
  exit 1
fi

# shellcheck disable=SC1090
source "$DEVICE_ENV"

BIN_DIR="${OPENWRT_DIR}/bin/targets/${TARGET_DIR}"
if [ ! -d "$BIN_DIR" ]; then
  echo "ERROR: Target output directory not found: $BIN_DIR" >&2
  exit 1
fi

matched_files=()
while IFS= read -r f; do
  matched_files+=("$f")
done < <(find "$BIN_DIR" -maxdepth 1 -type f -name "$ARTIFACT_GLOB" | sort)
if [ "${#matched_files[@]}" -eq 0 ]; then
  echo "ERROR: No artifacts matched '${ARTIFACT_GLOB}' in ${BIN_DIR}" >&2
  ls -la "$BIN_DIR" >&2 || true
  exit 1
fi

rm -rf "$OUTPUT_DIR"
mkdir -p "$OUTPUT_DIR"

for src in "${matched_files[@]}"; do
  cp -f "$src" "$OUTPUT_DIR/"
done

sha256_cmd() {
  if command -v sha256sum >/dev/null 2>&1; then
    sha256sum "$@"
  else
    shasum -a 256 "$@"
  fi
}

(
  cd "$OUTPUT_DIR"
  collected_names=()
  for src in "${matched_files[@]}"; do
    collected_names+=("$(basename "$src")")
  done
  sha256_cmd "${collected_names[@]}" > sha256sums
)

if [ -f "${BIN_DIR}/sha256sums" ]; then
  cp -f "${BIN_DIR}/sha256sums" "${OUTPUT_DIR}/sha256sums.full"
fi

if [ -x "${OPENWRT_DIR}/scripts/diffconfig.sh" ] && [ -f "${OPENWRT_DIR}/.config" ]; then
  (
    cd "$OPENWRT_DIR"
    ./scripts/diffconfig.sh
  ) > "${OUTPUT_DIR}/build.seed.config"
fi

effective_ref="${EFFECTIVE_REF:-${UPSTREAM_REF:-unknown}}"
upstream_commit="${UPSTREAM_COMMIT:-unknown}"
if [ "$upstream_commit" = "unknown" ] && [ -d "${OPENWRT_DIR}/.git" ]; then
  upstream_commit="$(git -C "$OPENWRT_DIR" rev-parse --short HEAD 2>/dev/null || echo unknown)"
fi

target_opt="default"
if [ -f "${OPENWRT_DIR}/.config" ]; then
  opt_line="$(grep -E '^CONFIG_TARGET_OPTIMIZATION=' "${OPENWRT_DIR}/.config" || true)"
  if [ -n "$opt_line" ]; then
    target_opt="${opt_line#CONFIG_TARGET_OPTIMIZATION=}"
    target_opt="${target_opt#\"}"
    target_opt="${target_opt%\"}"
  fi
fi

release_body="${OUTPUT_DIR}/release-body.md"
{
  cat <<EOF
## ${DEVICE_TITLE:-$DEVICE_NAME} (\`${DEVICE_NAME}\`)

### Build Summary

- **Flavor**: \`${UPSTREAM_FLAVOR:-unknown}\`
- **Upstream Repo**: ${UPSTREAM_REPO:-unknown}
- **Upstream Ref**: \`${effective_ref}\` (\`${upstream_commit}\`)
- **Target**: \`${TARGET_DIR}\`
- **Package Manager**: \`${PKG_MANAGER:-apk}\`
- **Target Optimization**: \`${target_opt}\`
- **Build Date (UTC)**: \`$(date -u '+%Y-%m-%d %H:%M:%S UTC')\`

### Firmware Images & Checksums

| File | Size | SHA256 |
| --- | --- | --- |
EOF

  while read -r sum fname; do
    [ -n "$sum" ] && [ -n "$fname" ] || continue
    fpath="${OUTPUT_DIR}/${fname}"
    size_bytes="$(wc -c < "$fpath" | tr -d ' ')"
    size_mib="$(awk -v b="$size_bytes" 'BEGIN { printf "%.2f MiB", b / 1048576 }')"
    printf "| \`%s\` | %s | \`%s\` |\n" "$fname" "$size_mib" "$sum"
  done < "${OUTPUT_DIR}/sha256sums"

  if [ -n "$VERIFY_LOG" ] && [ -f "$VERIFY_LOG" ]; then
    printf '\n### Pre-Build Config Verification\n\n'
    printf '<details>\n<summary>verify.sh output (all checks passed)</summary>\n\n```text\n'
    cat "$VERIFY_LOG"
    printf '```\n\n</details>\n'
  fi
} > "$release_body"

echo "Collected ${#matched_files[@]} firmware file(s) into ${OUTPUT_DIR}/"
cat "${OUTPUT_DIR}/sha256sums"
