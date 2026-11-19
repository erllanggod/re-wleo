#!/bin/bash
# Droidspaces support.
#   droidspaces.sh apply  <kernel_dir> <out_dir>   kABI patch + config (run before olddefconfig)
#   droidspaces.sh verify <kernel_dir> <out_dir>   check the final .config (run after olddefconfig)
set -eo pipefail

MODE="${1:?usage: droidspaces.sh apply|verify <kernel_dir> <out_dir>}"
KERNEL_DIR="${2:?kernel dir}"
OUT_DIR="${3:?out dir}"
PATCH="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/patches/droidspaces-sysvipc-kabi.patch"
CONF="$OUT_DIR/.config"

REQUIRED=(SYSVIPC POSIX_MQUEUE NAMESPACES UTS_NS IPC_NS PID_NS NET_NS FHANDLE DEVTMPFS
          MACVLAN IP6_NF_NAT IP6_NF_TARGET_MASQUERADE)
OPTIONAL=(TMPFS_POSIX_ACL TMPFS_XATTR CGROUP_DEVICE CGROUP_PIDS VETH BRIDGE OVERLAY_FS TUN
          NETFILTER_XT_MATCH_ADDRTYPE NETFILTER_XT_TARGET_LOG NETFILTER_XT_MATCH_RECENT
          IP_SET IP_SET_HASH_IP IP_SET_HASH_NET NETFILTER_XT_SET IP6_NF_IPTABLES)

case "$MODE" in
  apply)
    cd "$KERNEL_DIR"
    SCHED=include/linux/sched.h
    if grep -q 'ANDROID_KABI_USE(3, struct sysv_sem sysvsem)' "$SCHED"; then
      echo "[=] SysV IPC kABI patch already applied"
    else
      # --fuzz=3: this tree uses ANDROID_KABI_USE in slots 1-2, so only the leading context differs
      patch -p1 --fuzz=3 --dry-run < "$PATCH" >/dev/null \
        || { echo "[!] SysV IPC kABI patch does not apply to this tree" >&2; exit 1; }
      patch -p1 --fuzz=3 < "$PATCH"
      grep -q 'ANDROID_KABI_USE(3, struct sysv_sem sysvsem)' "$SCHED" \
        && grep -q '// struct sysv_sem' "$SCHED" \
        || { echo "[!] SysV IPC kABI patch left sched.h in an unexpected state" >&2; exit 1; }
    fi
    CFG="$KERNEL_DIR/scripts/config --file $CONF"
    for s in "${REQUIRED[@]}" "${OPTIONAL[@]}"; do $CFG -e "$s"; done
    echo "[+] Droidspaces: kABI patch + ${#REQUIRED[@]} required / ${#OPTIONAL[@]} optional options set"
    ;;
  verify)
    miss=0
    for s in "${REQUIRED[@]}"; do
      grep -q "^CONFIG_${s}=y" "$CONF" || { echo "[!] Droidspaces: CONFIG_${s} is not enabled after olddefconfig" >&2; miss=1; }
    done
    for s in "${OPTIONAL[@]}"; do
      grep -qE "^CONFIG_${s}=[ym]" "$CONF" || echo "[~] Droidspaces: optional CONFIG_${s} is not enabled"
    done
    [ "$miss" = 0 ] || exit 1
    echo "[+] Droidspaces: all required options are enabled"
    ;;
  *) echo "usage: droidspaces.sh apply|verify <kernel_dir> <out_dir>" >&2; exit 2 ;;
esac
