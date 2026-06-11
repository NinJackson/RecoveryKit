#!/bin/bash
# NAME: Recover files from UNREADABLE image (carve)
# DESC: For when the OS can't mount DEST/LABEL.img (corrupt/partial filesystem). Scans the raw image byte-by-byte with PhotoRec and recovers files by content signature into DEST/carved/ — no filesystem, no kernel mount. Recovers file CONTENT by type; original names/folders are lost.
# REQUIRES_ROOT: no
# ACCEPTS: image

set -u
DEST=""; LABEL=""; IMAGE=""
while [ $# -gt 0 ]; do case "$1" in
  --dest)  [ $# -ge 2 ] || { echo "--dest requires a path"; exit 2; }; DEST="$2"; shift 2;;
  --label) [ $# -ge 2 ] || { echo "--label requires a name"; exit 2; }; LABEL="$2"; shift 2;;
  --image) [ $# -ge 2 ] || { echo "--image requires a path"; exit 2; }; IMAGE="$2"; shift 2;;
  *) shift;;   # tolerate args meant for other methods
esac; done
[ -n "$DEST" ] && [ -n "$LABEL" ] || { echo "need --dest and --label"; exit 2; }

# --image points at any recovered .img; otherwise use the kit's DEST/LABEL.img.
IMG="${IMAGE:-$DEST/$LABEL.img}"
OUT="$DEST/carved"
RECUP="$OUT/recovered"
LOGF="$DEST/$LABEL.carve.log"
[ -f "$IMG" ] || { echo "image not found: $IMG"; exit 1; }

exec > >(tee -a "$LOGF") 2>&1
ts() { date '+%F %T'; }

# Locate the bundled universal PhotoRec.
PR=""
for p in /Users/service/RecoveryKit/tools/bin /usr/local/bin /opt/homebrew/bin; do
  [ -x "$p/photorec" ] && PR="$p/photorec" && break
done
[ -n "$PR" ] || { echo "photorec not found (expected in RecoveryKit/tools/bin)"; exit 1; }

mkdir -p "$OUT"
echo "[$(ts)] carving $IMG"
echo "[$(ts)] tool: $("$PR" /version 2>/dev/null | head -1)"
echo "[$(ts)] output: $RECUP   (this can take a long while on a large image)"
echo "[$(ts)] note: carving recovers file CONTENT by type; names/paths are not preserved."

caffeinate -dims & CAF=$!
trap 'kill $CAF 2>/dev/null' EXIT

# Batch (non-interactive) PhotoRec. partition_none = ignore the partition table
# and scan the whole image, so a broken/partial filesystem doesn't matter.
# It only ever reads the local image file — never the failing drive.
cd "$OUT" || exit 1
: > photorec.log
TERM=dumb "$PR" /log /d "$RECUP" /cmd "$IMG" partition_none,search >/dev/null 2>&1 &
PRPID=$!
# PhotoRec's own /log is clean plain text; follow it for live progress.
tail -f photorec.log 2>/dev/null & TPID=$!
disown "$TPID" 2>/dev/null || true   # no job-control "Terminated" notice on kill
wait "$PRPID"; RC=$?
kill "$TPID" 2>/dev/null

N=$(find "$RECUP"* -type f ! -name 'report.xml' 2>/dev/null | wc -l | tr -d ' ')
echo "[$(ts)] PhotoRec exited rc=$RC"
echo "[$(ts)] recovered $N file(s) under ${RECUP}*"
echo "[$(ts)] breakdown by type:"
find "$RECUP"* -type f ! -name 'report.xml' 2>/dev/null \
  | sed 's/.*\.//' | tr 'A-Z' 'a-z' | sort | uniq -c | sort -rn | head -25
echo "[$(ts)] open the results:  open '$OUT'"
