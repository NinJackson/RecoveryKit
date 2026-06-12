#!/bin/bash
# NAME: Verify image (hash + rescue-map health report)
# DESC: Post-imaging integrity check of DEST/LABEL.img: SHA-256 (stored as .sha256; reruns compare against it and flag corruption/bit-rot) plus a rescue-map report — % rescued, bad-sector extent count and worst regions from the ddrescue mapfile. Read-only except its own outputs.
# REQUIRES_ROOT: no
# ACCEPTS: image

set -u
DEST=""; LABEL=""; IMAGE=""
while [ $# -gt 0 ]; do case "$1" in
  --dest)  [ $# -ge 2 ] || { echo "--dest requires a path"; exit 2; }; DEST="$2"; shift 2;;
  --label) [ $# -ge 2 ] || { echo "--label requires a name"; exit 2; }; LABEL="$2"; shift 2;;
  --image) [ $# -ge 2 ] || { echo "--image requires a path"; exit 2; }; IMAGE="$2"; shift 2;;
  *) shift;;
esac; done
[ -n "$DEST" ] && [ -n "$LABEL" ] || { echo "need --dest and --label"; exit 2; }

IMG="${IMAGE:-$DEST/$LABEL.img}"
MAP="${IMG%.img}.map"
SHA="$IMG.sha256"
LOGF="$DEST/$LABEL.verify.log"
[ -f "$IMG" ] || { echo "image not found: $IMG"; exit 1; }
exec > >(tee -a "$LOGF") 2>&1
ts() { date '+%F %T'; }

DLOG=""
for p in /Users/service/RecoveryKit/tools/bin /Users/service/TDM_Recovery/tools/bin /usr/local/bin /opt/homebrew/bin; do
  [ -x "$p/ddrescuelog" ] && DLOG="$p/ddrescuelog" && break
done

caffeinate -dims & CAF=$!
trap 'kill $CAF 2>/dev/null' EXIT

echo "[$(ts)] verifying $IMG ($(stat -f%z "$IMG") bytes)"

if [ -f "$MAP" ] && [ -n "$DLOG" ]; then
  echo "[$(ts)] --- rescue-map health ---"
  "$DLOG" -t "$MAP" 2>/dev/null
  BAD=$("$DLOG" -t "$MAP" 2>/dev/null | awk -F: '/bad-sector/ {print $2}' | sed 's/^ *//')
  echo "[$(ts)] unrecovered (bad-sector): ${BAD:-unknown}"
else
  echo "[$(ts)] (no mapfile/ddrescuelog — skipping map report)"
fi

echo "[$(ts)] --- SHA-256 (this can take a while on a large image) ---"
NEW=$(shasum -a 256 "$IMG" | awk '{print $1}')
echo "[$(ts)] sha256: $NEW"
if [ -f "$SHA" ]; then
  OLD=$(awk '{print $1}' "$SHA")
  if [ "$NEW" = "$OLD" ]; then
    echo "[$(ts)] MATCH — image is byte-identical to when the hash was recorded."
  else
    echo "[$(ts)] *** MISMATCH *** recorded $OLD"
    echo "[$(ts)] the image changed since the hash was recorded (further ddrescue"
    echo "[$(ts)] passes legitimately change it — re-record after the final pass)."
  fi
else
  echo "$NEW  $(basename "$IMG")" > "$SHA"
  echo "[$(ts)] hash recorded: $SHA"
fi
echo "[$(ts)] verify complete"
