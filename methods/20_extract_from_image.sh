#!/bin/bash
# NAME: Extract files from image
# DESC: Attaches DEST/LABEL.img read-only, mounts each data volume inside it, copies all readable files to DEST/extracted/<Volume>/, then detaches. Run after imaging completes.
# REQUIRES_ROOT: yes
# ACCEPTS: image

set -u
DEST=""; LABEL=""; IMAGE=""
while [ $# -gt 0 ]; do case "$1" in
  --dest) [ $# -ge 2 ] || { echo "--dest requires a path"; exit 2; }; DEST="$2"; shift 2;;
  --label) [ $# -ge 2 ] || { echo "--label requires a name"; exit 2; }; LABEL="$2"; shift 2;;
  --image) [ $# -ge 2 ] || { echo "--image requires a path"; exit 2; }; IMAGE="$2"; shift 2;;
  *) shift;;   # tolerate args meant for other methods
esac; done
[ -n "$DEST" ] && [ -n "$LABEL" ] || { echo "need --dest and --label"; exit 2; }
[ "$(id -u)" -eq 0 ] || { echo "run with sudo"; exit 1; }

# --image points at any recovered .img; otherwise use the kit's DEST/LABEL.img.
IMG="${IMAGE:-$DEST/$LABEL.img}"
OUT="$DEST/extracted"
LOGF="$DEST/$LABEL.extract.log"
[ -f "$IMG" ] || { echo "image not found: $IMG"; exit 1; }
exec > >(tee -a "$LOGF") 2>&1
ts() { date '+%F %T'; }
echo "[$(ts)] extracting from $IMG"

caffeinate -dims & CAF=$!

ATTACHED=""
MOUNTED=""
cleanup() {
  kill "$CAF" 2>/dev/null
  for v in $MOUNTED; do
    diskutil unmount "$v" >/dev/null 2>&1
  done
  [ -n "$ATTACHED" ] && hdiutil detach "$ATTACHED" >/dev/null 2>&1
}
trap cleanup EXIT

# Attach without mounting; the kit's fstab guards (same volume UUIDs as the
# patient) keep diskarbitration from touching these volumes on its own, but
# still allow our manual readOnly mounts below.
ATTACHED=$(hdiutil attach -imagekey diskimage-class=CRawDiskImage -readonly -nomount "$IMG" \
            | awk '/^\/dev\/disk/ {print $1; exit}')
[ -n "$ATTACHED" ] || { echo "hdiutil attach failed"; exit 1; }
WHOLE="${ATTACHED#/dev/}"
echo "[$(ts)] image attached as $WHOLE"
sleep 5   # give APFS time to synthesize containers from the image

# Portable plist scalar read (plutil on modern macOS, PlistBuddy on 10.14).
pl() {
  local tmp v
  tmp=$(mktemp "${TMPDIR:-/tmp}/rk_pl.XXXXXX") || return 1
  diskutil info -plist "$1" >"$tmp" 2>/dev/null
  v=$(plutil -extract "$2" raw -o - "$tmp" 2>/dev/null)
  [ -n "$v" ] || v=$(/usr/libexec/PlistBuddy -c "Print :$2" "$tmp" 2>/dev/null)
  rm -f "$tmp"
  printf '%s' "$v"
}

# Volumes = plain slices of the attached disk + volumes of any APFS container
# whose physical store lives on it. Helper volumes carry no customer data.
SKIP="VM|Preboot|Recovery|EFI|Update|xART|iSCPreboot|Hardware"
VOLS=$(
  diskutil list "$WHOLE" 2>/dev/null \
    | awk '{print $NF}' | grep -oE '^disk[0-9]+s[0-9]+$'
  # End-of-line fields: non-last containers carry a leading "|" column that
  # shifts $1..$4 in diskutil apfs list output.
  diskutil apfs list 2>/dev/null | awk -v phys="$WHOLE" '
    /\+-- Container disk[0-9]+/ {ph=0}
    /\+-< Physical Store disk[0-9]+/ {n=$(NF-1); sub(/(s[0-9]+)+$/,"",n); if (n==phys) ph=1}
    ph && /\+-> Volume disk[0-9]+/ {print $(NF-1)}
  '
)

COPIED=0
for v in $VOLS; do
  NAME=$(pl "$v" VolumeName); [ -n "$NAME" ] || continue
  # Exact-name match only: customer volumes like "Recovery Photos" must not be skipped.
  echo "$NAME" | grep -qxE "($SKIP)" && { echo "[$(ts)] skip helper volume $v ($NAME)"; continue; }
  if ! diskutil mount readOnly "$v" >/dev/null 2>&1; then
    echo "[$(ts)] WARN: could not mount $v ($NAME) — skipping"
    continue
  fi
  MOUNTED="$MOUNTED $v"
  MP=$(pl "$v" MountPoint)
  [ -n "$MP" ] || {
    echo "[$(ts)] WARN: no mountpoint for $v"
    diskutil unmount "$v" >/dev/null 2>&1
    continue
  }
  SAFE=$(printf '%s' "$NAME" | tr -c 'A-Za-z0-9._ -' '_')
  echo "[$(ts)] copying '$NAME' ($v) -> $OUT/$SAFE/"
  mkdir -p "$OUT/$SAFE"
  rsync -rlptD -v \
    --exclude '.Spotlight-V100' --exclude '.fseventsd' --exclude '.Trashes' \
    --exclude '.DocumentRevisions-V100' --exclude '.TemporaryItems' \
    "$MP"/ "$OUT/$SAFE/"
  RC=$?
  # rsync 23/24 = some files unreadable/vanished: expected on a damaged image
  echo "[$(ts)] rsync for '$NAME' exited rc=$RC (0=clean, 23/24=partial)"
  COPIED=$((COPIED + 1))
  diskutil unmount "$v" >/dev/null 2>&1
done

echo "[$(ts)] extraction finished — $COPIED volume(s) copied to $OUT"
du -sh "$OUT"/* 2>/dev/null
