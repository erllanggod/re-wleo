#!/bin/bash
set -e

if [ -z "${TELEGRAM_TOKEN:-}" ] || [ -z "${TELEGRAM_CHAT_ID:-}" ]; then
  echo "[!] TELEGRAM_TOKEN/TELEGRAM_CHAT_ID kosong, skip notifikasi."
  exit 0
fi

KERNEL_DIR="${GITHUB_WORKSPACE}/kernel-source"
COMMIT=$(git -C "$KERNEL_DIR" rev-parse --short HEAD 2>/dev/null || echo "-")
DUR=$(( ${BUILD_DURATION_SEC:-0} ))

CAPTION="${BRAND} ${KERNEL_VER}
${KBUILD_COMPILER_STRING}
Image: ${BUILD_IMAGE}
Source: ${COMMIT}
Build time: $((DUR / 60))m $((DUR % 60))s"

curl -sS --max-time 300 \
  -F chat_id="$TELEGRAM_CHAT_ID" \
  -F document=@"${GITHUB_WORKSPACE}/${ZIP_NAME}" \
  -F caption="$CAPTION" \
  "https://api.telegram.org/bot${TELEGRAM_TOKEN}/sendDocument" > /tmp/tg.json
grep -q '"ok":true' /tmp/tg.json && echo "[+] Telegram notification sent." || { echo "[!] Telegram gagal:"; cat /tmp/tg.json; exit 1; }
