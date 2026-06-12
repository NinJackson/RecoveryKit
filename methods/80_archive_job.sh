#!/bin/bash
# NAME: Archive job artifacts (verified second copy)
# DESC: Copies the irreplaceable artifacts — LABEL.img, .map, .sha256, all logs/TSVs/report — to a second location (--to /Volumes/Archive) before the patient or job drive leaves the bench. Verifies the image copy by size and, when a .sha256 exists, by re-hashing the copy.
# REQUIRES_ROOT: no

set -u
DEST=""; LABEL=""; TO=""
while [ $# -gt 0 ]; do case "$1" in
  --dest)  [ $# -ge 2 ] || { echo "--dest requires a path"; exit 2; }; DEST="$2"; shift 2;;
  --label) [ $# -ge 2 ] || { echo "--label requires a name"; exit 2; }; LABEL="$2"; shift 2;;
  --to)    [ $# -ge 2 ] || { echo "--to requires a path"; exit 2; }; TO="$2"; shift 2;;
  *) shift;;
esac; done
[ -n "$DEST" ] && [ -n "$LABEL" ] || { echo "need --dest and --label"; exit 2; }
[ -n "$TO" ] || { echo "need --to <archive volume/folder> (put it in Extra args in the GUI)"; exit 2; }
[ -d "$TO" ] || { echo "archive destination not mounted: $TO"; exit 1; }

ARC="$TO/${LABEL}_archive"
LOGF="$DEST/$LABEL.archive.log"
exec > >(tee -a "$LOGF") 2>&1
ts() { date '+%F %T'; }
echo "[$(ts)] archiving job '$LABEL' -> $ARC"
caffeinate -dims & CAF=$!
trap 'kill $CAF 2>/dev/null' EXIT
mkdir -p "$ARC"

IMG="$DEST/$LABEL.img"
if [ -f "$IMG" ]; then
  NEED=$(stat -f%z "$IMG")
  FREE=$(df -k "$TO" | awk 'NR==2 {print $4 * 1024}')
  [ "$FREE" -ge "$NEED" ] || { echo "[$(ts)] FATAL: need $NEED bytes free at $TO, have $FREE"; exit 1; }
fi

COPIED=0
for f in "$DEST/$LABEL".*; do
  [ -f "$f" ] || continue
  case "$f" in *.lock) continue;; esac
  B=$(basename "$f")
  echo "[$(ts)] copying $B ($(stat -f%z "$f") bytes)"
  cp "$f" "$ARC/$B.part" && mv "$ARC/$B.part" "$ARC/$B" && COPIED=$((COPIED + 1))
done

# Verify the image copy — it is the artifact that cannot be regenerated.
if [ -f "$IMG" ] && [ -f "$ARC/$LABEL.img" ]; then
  S1=$(stat -f%z "$IMG"); S2=$(stat -f%z "$ARC/$LABEL.img")
  [ "$S1" = "$S2" ] || { echo "[$(ts)] FATAL: image copy size mismatch ($S1 vs $S2)"; exit 1; }
  if [ -f "$IMG.sha256" ]; then
    echo "[$(ts)] re-hashing the archived image (slow but worth it)..."
    WANT=$(awk '{print $1}' "$IMG.sha256")
    GOT=$(shasum -a 256 "$ARC/$LABEL.img" | awk '{print $1}')
    if [ "$WANT" = "$GOT" ]; then echo "[$(ts)] archive image hash VERIFIED"
    else echo "[$(ts)] FATAL: archived image hash mismatch — do not trust this copy"; exit 1; fi
  else
    echo "[$(ts)] (no .sha256 recorded — size check only; run method 15_ first for hash verification)"
  fi
fi
echo "[$(ts)] archived $COPIED artifact(s) to $ARC"
