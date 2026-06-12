#!/bin/bash
# NAME: Extract files from image WITHOUT mounting (Sleuth Kit)
# DESC: Filesystem-aware extraction from DEST/LABEL.img using bundled Sleuth Kit (mmls + tsk_recover) — recovers names and folder structure with NO kernel mount, so a corrupt filesystem cannot panic the host. Use when 20_ is too risky and 30_ (carve) would lose names. Output: DEST/tsk_extracted/.
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
OUT="$DEST/tsk_extracted"
LOGF="$DEST/$LABEL.tsk.log"
[ -f "$IMG" ] || { echo "image not found: $IMG"; exit 1; }

TB=/Users/service/RecoveryKit/tools/bin
for t in mmls tsk_recover fls; do
  [ -x "$TB/$t" ] || { echo "Sleuth Kit tool '$t' missing from $TB — build it first (see ~/TDM_Recovery/build_tsk_universal.sh)"; exit 1; }
done

exec > >(tee -a "$LOGF") 2>&1
ts() { date '+%F %T'; }
echo "[$(ts)] Sleuth Kit no-mount extraction from $IMG"
caffeinate -dims & CAF=$!
trap 'kill $CAF 2>/dev/null' EXIT
mkdir -p "$OUT"

echo "[$(ts)] partition map:"
"$TB/mmls" "$IMG" 2>&1 | sed 's/^/  /'

# Walk every allocated partition; tsk_recover -a copies allocated (live) files
# with names/paths. APFS pools enumerate their volumes via the pool layer.
"$TB/mmls" -M "$IMG" 2>/dev/null | awk '$1 ~ /^[0-9]+:/ && $NF !~ /Unallocated|Meta/ {print $3}' \
| while read -r START; do
  case "$START" in ''|*[!0-9]*) continue;; esac
  PD="$OUT/offset_$START"
  echo "[$(ts)] extracting partition at sector $START -> $PD"
  mkdir -p "$PD"
  "$TB/tsk_recover" -a -o "$START" "$IMG" "$PD" 2>&1 | tail -3 | sed 's/^/  /'
done

echo "[$(ts)] extraction finished:"
du -sh "$OUT"/* 2>/dev/null | sed 's/^/  /'
echo "[$(ts)] note: tsk_recover -a copies LIVE files; rerun with -e (edit script) for deleted-file recovery attempts."
