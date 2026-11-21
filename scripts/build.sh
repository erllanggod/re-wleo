#!/bin/bash
set -eo pipefail

KERNEL_DIR="${GITHUB_WORKSPACE}/kernel-source"
OUT_DIR="${KERNEL_DIR}/out"
ZIMAGE_DIR="${OUT_DIR}/arch/arm64/boot"
DEFCONFIG="dumpc2j_defconfig"
BUILD_START=$(date +%s)

LTO="${INPUT_LTO:-default}"
HZ="${INPUT_HZ:-default}"
KERNEL_NAME="${INPUT_KERNEL_NAME:-}"
DEBUG_MODE="${INPUT_DEBUG:-off}"
DROIDSPACES="${INPUT_DROIDSPACES:-off}"
NOMOUNT="${INPUT_NOMOUNT:-off}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

BRAND="$(printf '%s' "${KERNEL_NAME#-}" | tr -c 'A-Za-z0-9._-' '-')"
BRAND="${BRAND:-DumpC2J}"

export ARCH=arm64 SUBARCH=arm64
export KBUILD_BUILD_USER="adennnqt"
export KBUILD_BUILD_HOST="$BRAND"

[ -n "${KBUILD_COMPILER_STRING:-}" ] || { echo "[!] KBUILD_COMPILER_STRING is empty, did the clang setup fail?" >&2; exit 1; }
export KBUILD_COMPILER_STRING
export PATH="${CLANG_PATH}:$PATH"

export CCACHE_DIR="${GITHUB_WORKSPACE}/.ccache"
export CCACHE_BASEDIR="${GITHUB_WORKSPACE}"
export CCACHE_COMPRESS=true
export CCACHE_MAXSIZE=3G
export CCACHE_COMPILERCHECK=content
mkdir -p "$CCACHE_DIR"
ccache -z >/dev/null

KLDFLAGS=""
if [ "$LTO" == "thin" ]; then
  mkdir -p /dev/shm/ldcache
  KLDFLAGS="--thinlto-cache-dir=/dev/shm/ldcache"
fi

cd "$KERNEL_DIR"

if [ -n "$KERNEL_NAME" ]; then
  esc=$(printf '%s' "$KERNEL_NAME" | sed -e 's/[\/&]/\\&/g')
  sed -i "s/^CONFIG_LOCALVERSION=\".*\"/CONFIG_LOCALVERSION=\"$esc\"/" "arch/arm64/configs/$DEFCONFIG"
  grep -qF "CONFIG_LOCALVERSION=\"$KERNEL_NAME\"" "arch/arm64/configs/$DEFCONFIG" \
    || { echo "[!] failed to set CONFIG_LOCALVERSION in $DEFCONFIG" >&2; exit 1; }
fi

MAKE_ARGS=(O="$OUT_DIR" CC="ccache clang" LD=ld.lld AR=llvm-ar NM=llvm-nm
  OBJCOPY=llvm-objcopy OBJDUMP=llvm-objdump STRIP=llvm-strip LLVM=1 LLVM_IAS=1)
[ -n "$KLDFLAGS" ] && MAKE_ARGS+=(LDFLAGS="$KLDFLAGS")

mkdir -p "$OUT_DIR"
make "${MAKE_ARGS[@]}" "$DEFCONFIG"

CFG="$KERNEL_DIR/scripts/config --file $OUT_DIR/.config"

case "$LTO" in
  full) $CFG -d LTO_NONE -d LTO_CLANG_THIN -e LTO_CLANG -e LTO_CLANG_FULL ;;
  thin) $CFG -d LTO_NONE -d LTO_CLANG_FULL -e LTO_CLANG -e LTO_CLANG_THIN ;;
  none) $CFG -d LTO_CLANG -d LTO_CLANG_FULL -d LTO_CLANG_THIN -e LTO_NONE ;;
esac

case "$HZ" in
  powersave) HZ=100 ;;
  balance) HZ=250 ;;
  smooth) HZ=300 ;;
  performance) HZ=500 ;;
  ultra-performance) HZ=1000 ;;
esac

if [ "$HZ" != "default" ]; then
  for h in 100 250 300 500 1000; do $CFG -d "HZ_$h"; done
  $CFG -e "HZ_$HZ" --set-val HZ "$HZ"
  if [ "$HZ" = "100" ]; then $CFG -e RCU_LAZY; else $CFG -d RCU_LAZY; fi
fi

if [ "$DROIDSPACES" == "on" ]; then
  bash "$SCRIPT_DIR/droidspaces.sh" apply "$KERNEL_DIR" "$OUT_DIR"
fi

# NoMount defaults to y in its Kconfig, so always set it explicitly
if [ "$NOMOUNT" == "on" ]; then
  bash "$SCRIPT_DIR/nomount.sh" apply "$KERNEL_DIR" "$OUT_DIR"
else
  "$KERNEL_DIR/scripts/config" --file "$OUT_DIR/.config" -d NOMOUNT
fi

if [ "$DEBUG_MODE" == "on" ]; then
  cur=$(grep '^CONFIG_CMDLINE=' "$OUT_DIR/.config" | sed 's/^CONFIG_CMDLINE="//; s/"$//')
  echo "$cur" | grep -q nokaslr || $CFG --set-str CMDLINE "${cur:+$cur }nokaslr"
fi

make "${MAKE_ARGS[@]}" olddefconfig

if [ "$DROIDSPACES" == "on" ]; then
  bash "$SCRIPT_DIR/droidspaces.sh" verify "$KERNEL_DIR" "$OUT_DIR"
fi
if [ "$NOMOUNT" == "on" ]; then
  bash "$SCRIPT_DIR/nomount.sh" verify "$KERNEL_DIR" "$OUT_DIR"
fi

grep -E '^CONFIG_(LOCALVERSION|LTO_CLANG_[A-Z]+|HZ|DEBUG_INFO_BTF)=' "$OUT_DIR/.config" || true

CPUS=$(nproc --all)
echo "[+] Building Image with ${CPUS} threads using ${KBUILD_COMPILER_STRING}"
make "${MAKE_ARGS[@]}" "-j${CPUS}" Image

ccache -s || true

IMG=""
for img in Image.gz-dtb Image.gz Image; do
  [ -f "$ZIMAGE_DIR/$img" ] && { IMG="$img"; break; }
done
[ -n "$IMG" ] || { echo "[!] kernel image not found" >&2; exit 1; }

cd "$GITHUB_WORKSPACE"
rm -rf anykernel_temp
cp -r "$KERNEL_DIR/anykernel" anykernel_temp
cp -v "$ZIMAGE_DIR/$IMG" anykernel_temp/

KVER=$(awk '/^VERSION =/{v=$3} /^PATCHLEVEL =/{p=$3} /^SUBLEVEL =/{s=$3} END{print v"."p"."s}' "$KERNEL_DIR/Makefile")
TIME=$(date "+%Y%m%d-%H%M")
FEATURES=""
[ "$DROIDSPACES" == "on" ] && FEATURES="Droidspaces"
[ "$NOMOUNT" == "on" ] && FEATURES="${FEATURES:+$FEATURES, }NoMount"
[ "$HZ" != "default" ] && FEATURES="${FEATURES:+$FEATURES, }${HZ}Hz"
ZIP_SUFFIX=""
[ "$DROIDSPACES" == "on" ] && ZIP_SUFFIX="-Droidspaces"
[ "$NOMOUNT" == "on" ] && ZIP_SUFFIX="${ZIP_SUFFIX}-NoMount"
ZIP_NAME="${BRAND}-Vanilla${ZIP_SUFFIX}-${TIME}.zip"
(cd anykernel_temp && zip -r9 "${GITHUB_WORKSPACE}/${ZIP_NAME}" . -x '.git*' -x 'README.md' -x '*placeholder' >/dev/null)
rm -rf anykernel_temp

DIFF=$(( $(date +%s) - BUILD_START ))
{
  echo "ZIP_NAME=$ZIP_NAME"
  echo "ARTIFACT_NAME=${ZIP_NAME%.zip}"
  echo "KERNEL_VER=$KVER"
  echo "BRAND=$BRAND"
  echo "BUILD_DURATION_SEC=$DIFF"
  echo "BUILD_IMAGE=$IMG"
  echo "FEATURES=$FEATURES"
} >> "$GITHUB_ENV"

echo "[+] Build done in $((DIFF / 60))m $((DIFF % 60))s: $ZIP_NAME"
