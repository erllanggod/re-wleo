#!/bin/bash
set -e

if [ -z "${TELEGRAM_TOKEN:-}" ] || [ -z "${TELEGRAM_CHAT_ID:-}" ]; then
  echo "[!] TELEGRAM_TOKEN/TELEGRAM_CHAT_ID is empty, skipping notification."
  exit 0
fi

KERNEL_DIR="${GITHUB_WORKSPACE}/kernel-source"
ZIP_PATH="${GITHUB_WORKSPACE}/${ZIP_NAME}"

esc() { printf '%s' "$1" | sed -e 's/&/\&amp;/g' -e 's/</\&lt;/g' -e 's/>/\&gt;/g'; }

FILE_SIZE=$(du -h "$ZIP_PATH" | cut -f1)
SHA256_FULL=$(sha256sum "$ZIP_PATH" | cut -d' ' -f1)
KERNEL_COMMIT_SHORT=$(git -C "$KERNEL_DIR" rev-parse --short=7 HEAD 2>/dev/null || echo "-")
BUILDER_COMMIT_SHORT="${GITHUB_SHA:0:7}"
BUILDER_COMMIT_URL="${GITHUB_SERVER_URL}/${GITHUB_REPOSITORY}/commit/${GITHUB_SHA}"
RUN_URL="${GITHUB_SERVER_URL}/${GITHUB_REPOSITORY}/actions/runs/${GITHUB_RUN_ID}"
BUILD_DATE=$(date -u "+%Y-%m-%d %H:%M UTC")
DUR=$(( ${BUILD_DURATION_SEC:-0} ))
DUR_TEXT="$((DUR / 60))m $((DUR % 60))s"

CAPTION="${BRAND:-DumpC2J} ${KERNEL_VER}"

SEND_DOC=$(curl -s --max-time 300 -X POST "https://api.telegram.org/bot${TELEGRAM_TOKEN}/sendDocument" \
  -F chat_id="${TELEGRAM_CHAT_ID}" \
  -F parse_mode="HTML" \
  -F caption="${CAPTION}" \
  -F document=@"${ZIP_PATH}")

if ! echo "$SEND_DOC" | grep -q '"ok":true'; then
  echo "[!] Failed to upload file to Telegram. Response:"
  echo "$SEND_DOC"
  exit 1
fi

MSG_ID=$(echo "$SEND_DOC" | jq -r '.result.message_id')

DETAIL="📋 <b>Build Detail</b>

<b>Build Info:</b>
⚙️ Clang: $(esc "${KBUILD_COMPILER_STRING}")
${FEATURES:+🧩 Features: $(esc "$FEATURES")
}🖼️ Image: ${BUILD_IMAGE}
💾 Size: ${FILE_SIZE}
🔐 SHA256: <code>${SHA256_FULL}</code>
⏱️ Duration: ${DUR_TEXT}
📅 Date: ${BUILD_DATE}
🧬 Kernel Commit: ${KERNEL_COMMIT_SHORT}
🛠️ Builder Commit: <a href=\"${BUILDER_COMMIT_URL}\">${BUILDER_COMMIT_SHORT}</a>
🏃 Run: <a href=\"${RUN_URL}\">#${GITHUB_RUN_NUMBER}</a>"

SEND_DETAIL=$(curl -s -X POST "https://api.telegram.org/bot${TELEGRAM_TOKEN}/sendMessage" \
  -d chat_id="${TELEGRAM_CHAT_ID}" \
  -d parse_mode="HTML" \
  -d reply_to_message_id="${MSG_ID}" \
  -d disable_web_page_preview=true \
  --data-urlencode text="${DETAIL}")

echo "$SEND_DETAIL" | grep -q '"ok":true' && echo "[+] Telegram notification sent." || { echo "[!] Telegram detail message failed:"; echo "$SEND_DETAIL"; exit 1; }
