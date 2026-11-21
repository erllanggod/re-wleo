#!/bin/bash
# NoMount support (self-contained: fs/nomount plus one Makefile line and one Kconfig line).
#   nomount.sh apply  <kernel_dir> <out_dir>   sync sources and enable CONFIG_NOMOUNT
#   nomount.sh verify <kernel_dir> <out_dir>   check CONFIG_NOMOUNT after olddefconfig
set -eo pipefail

MODE="${1:?usage: nomount.sh apply|verify <kernel_dir> <out_dir>}"
KERNEL_DIR="${2:?kernel dir}"
OUT_DIR="${3:?out dir}"
CONF="$OUT_DIR/.config"
REPO="${NOMOUNT_REPO:-https://github.com/maxsteeel/nomount.git}"
REF="${NOMOUNT_REF:-dev}"
DEST="$KERNEL_DIR/fs/nomount"

case "$MODE" in
  apply)
    WORK="$(mktemp -d)"; trap 'rm -rf "$WORK"' EXIT
    SRC="tree copy"
    if timeout 180 git clone -q --depth 1 -b "$REF" "$REPO" "$WORK/up" 2>/dev/null \
       && [ -f "$WORK/up/kernel/src/Kconfig" ] && [ -f "$WORK/up/kernel/src/Makefile" ]; then
      rm -rf "$DEST"; mkdir -p "$DEST"; cp -a "$WORK/up/kernel/src/." "$DEST/"
      SRC="upstream $REF@$(git -C "$WORK/up" rev-parse --short HEAD)"
    else
      echo "[!] NoMount upstream unavailable or its layout changed, falling back to the copy in the tree" >&2
      [ -f "$DEST/Kconfig" ] && [ -f "$DEST/Makefile" ] \
        || { echo "[!] No NoMount sources in the tree either" >&2; exit 1; }
    fi
    grep -q 'nomount' "$KERNEL_DIR/fs/Makefile" || printf '\nobj-$(CONFIG_NOMOUNT) += nomount/\n' >> "$KERNEL_DIR/fs/Makefile"
    if ! grep -q 'source "fs/nomount/Kconfig"' "$KERNEL_DIR/fs/Kconfig"; then
      awk '/^endmenu/ { last = NR } { l[NR] = $0 }
           END { for (i = 1; i <= NR; i++) { if (i == last) print "source \"fs/nomount/Kconfig\""; print l[i] } }' \
        "$KERNEL_DIR/fs/Kconfig" > "$KERNEL_DIR/fs/Kconfig.tmp" && mv "$KERNEL_DIR/fs/Kconfig.tmp" "$KERNEL_DIR/fs/Kconfig"
    fi
    "$KERNEL_DIR/scripts/config" --file "$CONF" -e NOMOUNT
    echo "[+] NoMount: $SRC, version $(sed -n 's/^#define NOMOUNT_BASE_VERSION "\(.*\)"/\1/p' "$DEST/nomount.h" | head -1)"
    ;;
  verify)
    grep -q '^CONFIG_NOMOUNT=y' "$CONF" \
      || { echo "[!] NoMount: CONFIG_NOMOUNT is not enabled after olddefconfig" >&2; exit 1; }
    echo "[+] NoMount: CONFIG_NOMOUNT=y"
    ;;
  *) echo "usage: nomount.sh apply|verify <kernel_dir> <out_dir>" >&2; exit 2 ;;
esac
