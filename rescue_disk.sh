#!/bin/bash
# rescue_disk.sh — safely image a failing external/TDM disk with GNU ddrescue.
#
# Designed for intermittent, dying drives: waits for the disk to enumerate,
# blocks macOS from auto-mounting/fsck-ing it, images raw blocks (never
# mounts the source), and auto-resumes across drive dropouts, host reboots,
# and re-enumeration under a different disk number.
#
# Usage:
#   sudo bash rescue_disk.sh --dest "/Volumes/12345 - Customer" [options]
#
# Options:
#   --dest PATH       Destination folder (the job drive). Required.
#   --label NAME      Basename for image/map/log files (default rescue_YYYYMMDD).
#   --device diskN    Skip detection, use this whole-disk identifier.
#   --size-gb N       Only accept a disk of ~N GB (matches within 2%).
#   --retries N       Retry passes on bad areas in later cycles (default 3).
#   --max-cycles N    Max attach/image cycles before giving up (default 15).
#   --timeout-secs N  Abort a pass if no successful read for N secs (default 300).
#   --yes             No confirmation prompt (needed when run unattended).
#   --force           Skip the destination free-space check.
#   --cleanup-fstab   Remove this kit's /etc/fstab guard lines, then exit.
#
# After imaging, work only from the image:
#   hdiutil attach -imagekey diskimage-class=CRawDiskImage -readonly -nomount IMG

set -u
set -o pipefail

DEST=""; LABEL="rescue_$(date +%Y%m%d)"; DEVICE=""; SIZE_GB=""
RETRIES=3; MAXCYCLES=15; TMAX=300; YES=0; FORCE=0; CLEANUP=0

while [ $# -gt 0 ]; do case "$1" in
  --dest) [ $# -ge 2 ] || { echo "--dest requires a path"; exit 2; }; DEST="$2"; shift 2;;
  --label) [ $# -ge 2 ] || { echo "--label requires a name"; exit 2; }; LABEL="$2"; shift 2;;
  --device) [ $# -ge 2 ] || { echo "--device requires diskN"; exit 2; }; DEVICE="${2#/dev/}"; shift 2;;
  --size-gb) [ $# -ge 2 ] || { echo "--size-gb requires a number"; exit 2; }; SIZE_GB="$2"; shift 2;;
  --retries) [ $# -ge 2 ] || { echo "--retries requires a number"; exit 2; }; RETRIES="$2"; shift 2;;
  --max-cycles) [ $# -ge 2 ] || { echo "--max-cycles requires a number"; exit 2; }; MAXCYCLES="$2"; shift 2;;
  --timeout-secs) [ $# -ge 2 ] || { echo "--timeout-secs requires a number"; exit 2; }; TMAX="$2"; shift 2;;
  --yes) YES=1; shift;;
  --force) FORCE=1; shift;;
  --cleanup-fstab) CLEANUP=1; shift;;
  -h|--help) sed -n '2,24p' "$0"; exit 0;;
  *) echo "unknown argument: $1 (try --help)"; exit 2;;
esac; done

ts() { date '+%F %T'; }
log() { echo "[$(ts)] $*"; }
die() { log "FATAL: $*"; exit 1; }
is_uint() { case "$1" in ''|*[!0-9]*) return 1;; *) return 0;; esac; }

is_uint "$RETRIES" || die "--retries must be a non-negative integer"
is_uint "$MAXCYCLES" || die "--max-cycles must be a non-negative integer"
is_uint "$TMAX" || die "--timeout-secs must be a non-negative integer"
if [ -n "$SIZE_GB" ]; then
  awk -v g="$SIZE_GB" 'BEGIN{exit !(g+0>0 && g ~ /^[0-9]+([.][0-9]+)?$/)}' \
    || die "--size-gb must be a positive number"
fi

[ "$(id -u)" -eq 0 ] || die "run with sudo (raw device access and fstab guards need root)"

if [ "$CLEANUP" -eq 1 ]; then
  sed -i '' '/# rescuekit:/d' /etc/fstab 2>/dev/null
  echo "rescuekit fstab guard lines removed."
  exit 0
fi

[ -n "$DEST" ] || die "--dest is required"
[ -d "$DEST" ] || die "destination not mounted: $DEST"

IMG="$DEST/$LABEL.img"; MAP="$DEST/$LABEL.map"
STATE="$DEST/$LABEL.target"; LOGF="$DEST/$LABEL.log"
exec > >(tee -a "$LOGF") 2>&1
log "=== rescue_disk start; label=$LABEL dest=$DEST ==="

# plutil -extract with stdin input prints to stdout; -o - made explicit anyway.
pl() { diskutil info -plist "$1" 2>/dev/null | plutil -extract "$2" raw -o - - 2>/dev/null; }
wholeof() { echo "${1#/dev/}" | sed -E 's/(s[0-9]+)+$//'; }
externals() {
  diskutil list -plist external physical 2>/dev/null \
    | plutil -extract WholeDisks json -o - - 2>/dev/null \
    | tr -d '[]" ' | tr ',' ' '
}

DDR=""; DLOG=""
for p in /Users/service/RecoveryKit/tools/bin /Users/service/TDM_Recovery/tools/bin /usr/local/bin /opt/homebrew/bin; do
  [ -x "$p/ddrescue" ] && DDR="$p/ddrescue" && DLOG="$p/ddrescuelog" && break
done
[ -n "$DDR" ] || die "ddrescue not found (expected in RecoveryKit/tools/bin)"
[ -x "$DLOG" ] || die "ddrescuelog not found next to ddrescue"
log "using $("$DDR" --version | head -1)"

# Never offer the destination's own disk (or its APFS physical stores) as a target.
EXCL=""
PW=$(pl "$DEST" ParentWholeDisk); [ -n "$PW" ] && EXCL="$PW"
for d in $(diskutil info -plist "$DEST" 2>/dev/null \
             | plutil -extract APFSPhysicalStores json -o - - 2>/dev/null \
             | grep -oE 'disk[0-9]+(s[0-9]+)?'); do
  EXCL="$EXCL $(wholeof "$d")"
done
excluded() { case " $EXCL " in *" $1 "*) return 0;; *) return 1;; esac; }

candidates() { for d in $(externals); do excluded "$d" || echo "$d"; done; }

if [ -n "$DEVICE" ]; then
  DEVICE=$(wholeof "$DEVICE")
  excluded "$DEVICE" && die "--device $DEVICE is the destination's own disk"
fi

size_ok() {  # within 2% of --size-gb, if given
  [ -z "$SIZE_GB" ] && return 0
  awk -v s="$1" -v g="$SIZE_GB" 'BEGIN{t=g*1e9; d=s>t?s-t:t-s; exit !(d<=t*0.02)}'
}

confirm() {  # $1 = disk id
  local sz name proto
  sz=$(pl "$1" TotalSize); name=$(pl "$1" MediaName); proto=$(pl "$1" BusProtocol)
  log "candidate: $1  size=${sz:-?} bytes  media='${name:-?}'  bus=${proto:-?}"
  [ "$YES" -eq 1 ] && return 0
  local ans=""
  read -r -p "Image $1 ('$name')? [y/N] " ans </dev/tty || ans=""
  [ "$ans" = "y" ] || [ "$ans" = "Y" ]
}

find_target() {  # echoes disk id; uses saved DiskUUID/size to survive renumbering
  local d uuid sz
  # Saved identity wins over --device: after a dropout the patient may
  # re-enumerate under a different number than the one the tech picked.
  if [ ! -f "$STATE" ] && [ -n "$DEVICE" ]; then
    if [ -e "/dev/$DEVICE" ] && ! excluded "$DEVICE"; then
      echo "$DEVICE"; return 0
    fi
    return 1
  fi
  if [ -f "$STATE" ]; then
    # shellcheck disable=SC1090
    . "$STATE"
    for d in $(candidates); do
      uuid=$(pl "$d" DiskUUID)
      [ -n "${SAVED_UUID:-}" ] && [ "$uuid" = "${SAVED_UUID}" ] && { echo "$d"; return 0; }
    done
    for d in $(candidates); do
      sz=$(pl "$d" TotalSize)
      [ -n "${SAVED_SIZE:-}" ] && [ "$sz" = "${SAVED_SIZE}" ] && { echo "$d"; return 0; }
    done
    return 1
  fi
  for d in $(candidates); do
    sz=$(pl "$d" TotalSize)
    size_ok "${sz:-0}" && { echo "$d"; return 0; }
  done
  return 1
}

guard_and_unmount() {  # $1 = physical whole disk
  local d="$1" devid uuid fstype cont
  # fstab noauto per volume UUID: diskarbitration then leaves the patient alone.
  for devid in $(diskutil list -plist "$d" 2>/dev/null \
                   | plutil -extract AllDisksAndPartitions json -o - - 2>/dev/null \
                   | grep -oE '"DeviceIdentifier" *: *"disk[0-9]+(s[0-9]+)?"' \
                   | grep -oE 'disk[0-9]+(s[0-9]+)?'); do
    uuid=$(pl "$devid" VolumeUUID); [ -n "$uuid" ] || continue
    fstype=$(pl "$devid" FilesystemType); [ -n "$fstype" ] || fstype=apfs
    grep -q "$uuid" /etc/fstab 2>/dev/null \
      || echo "UUID=$uuid none $fstype ro,noauto # rescuekit:$LABEL" >> /etc/fstab
  done
  # APFS containers synthesize a sibling disk; guard its volumes and unmount it too.
  diskutil apfs list 2>/dev/null | awk -v phys="$d" '
    /\+-- Container disk/ {cont=$3; ph=0}
    /\+-< Physical Store/ {n=$4; sub(/(s[0-9]+)+$/,"",n); if (n==phys) ph=1}
    ph && /\+-> Volume disk/ {print cont, $3, $4}
  ' | while read -r cont vol uuid; do
    grep -q "$uuid" /etc/fstab 2>/dev/null \
      || echo "UUID=$uuid none apfs ro,noauto # rescuekit:$LABEL" >> /etc/fstab
    echo "$cont" >> "/tmp/rescuekit_containers.$$"
  done
  if [ -f "/tmp/rescuekit_containers.$$" ]; then
    sort -u "/tmp/rescuekit_containers.$$" | while read -r cont; do
      diskutil unmountDisk force "$cont" >/dev/null 2>&1
    done
    rm -f "/tmp/rescuekit_containers.$$"
  fi
  diskutil unmountDisk force "$d" >/dev/null 2>&1
  log "fstab guards written; $d and synthesized siblings unmounted"
}

remaining_work() {  # 0 means every block was tried/trimmed/scraped
  local out
  [ -e "$MAP" ] || { echo 1; return; }
  out=$("$DLOG" -t "$MAP" 2>/dev/null) || { echo 1; return; }
  echo "$out" | awk '
    /non-tried|non-trimmed|non-scraped/ && $0 !~ /: *0 B/ { left++ }
    END { print left + 0 }
  '
}

mdutil -i off "$DEST" >/dev/null 2>&1
caffeinate -dims & CAF=$!
trap 'kill $CAF 2>/dev/null' EXIT

CYCLE=0
while :; do
  CYCLE=$((CYCLE + 1))
  [ "$CYCLE" -gt "$MAXCYCLES" ] && { log "max cycles reached"; break; }
  log "--- cycle $CYCLE/$MAXCYCLES: waiting for target disk (power-cycle the patient if needed) ---"

  TARGET=""
  for _ in $(seq 1 3600); do
    TARGET=$(find_target) && [ -n "$TARGET" ] && break
    sleep 1
  done
  [ -n "$TARGET" ] || { log "no target appeared within 60 min"; break; }

  if [ ! -f "$STATE" ]; then
    confirm "$TARGET" || die "declined; rerun with --device diskN or --size-gb N"
    SAVED_UUID=$(pl "$TARGET" DiskUUID)
    SAVED_SIZE=$(pl "$TARGET" TotalSize)
    SAVED_BS=$(pl "$TARGET" DeviceBlockSize)
    case "${SAVED_BS:-}" in ''|*[!0-9]*) SAVED_BS=512;; esac
    printf 'SAVED_UUID=%s\nSAVED_SIZE=%s\nSAVED_BS=%s\n' \
      "$SAVED_UUID" "$SAVED_SIZE" "$SAVED_BS" > "$STATE"
    if [ "$FORCE" -ne 1 ] && [ ! -e "$IMG" ]; then
      FREE=$(df -k "$DEST" | awk 'NR==2 {print $4 * 1024}')
      [ "$FREE" -ge "$SAVED_SIZE" ] \
        || die "need $SAVED_SIZE bytes free on $DEST, have $FREE (use --force to override)"
    fi
  else
    . "$STATE"
  fi

  log "target is $TARGET (uuid=${SAVED_UUID:-?} size=${SAVED_SIZE:-?} bs=${SAVED_BS:-?})"
  guard_and_unmount "$TARGET"

  if [ "$CYCLE" -eq 1 ] && [ ! -e "$MAP" ]; then
    PASSFLAGS="--no-scrape"           # grab the easy blocks first, fail fast past bad areas
  else
    PASSFLAGS="--retry-passes=$RETRIES --reopen-on-error"
  fi
  log "ddrescue pass: $PASSFLAGS"
  "$DDR" --sector-size="$SAVED_BS" --timeout="${TMAX}s" $PASSFLAGS \
         "/dev/r$TARGET" "$IMG" "$MAP"
  RC=$?
  log "ddrescue exited rc=$RC"

  LEFT=$(remaining_work)
  if [ "$LEFT" -eq 0 ] && [ "$CYCLE" -gt 1 ]; then
    log "all readable areas processed"
    break
  fi
  if [ "$LEFT" -eq 0 ] && [ "$CYCLE" -eq 1 ] && [ "$RC" -eq 0 ]; then
    log "fast pass complete; starting retry/scrape cycle"
    continue
  fi
  if [ ! -e "/dev/$TARGET" ]; then
    log "target dropped off the bus — waiting for it to come back"
    continue
  fi
  [ "$RC" -eq 0 ] && continue
  log "pass ended with errors; will retry (cycle $CYCLE)"
  sleep 5
done

log "=== final status ==="
"$DLOG" -t "$MAP" 2>/dev/null || true
log "image: $IMG"
log "map:   $MAP (keep it — reruns resume automatically)"
log "next:  hdiutil attach -imagekey diskimage-class=CRawDiskImage -readonly -nomount '$IMG'"
log "then:  diskutil list  → mount volumes readOnly from the image, extract files"
log "note:  remove fstab guards later with: sudo bash $0 --cleanup-fstab"
