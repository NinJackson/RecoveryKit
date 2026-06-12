#!/bin/bash
# NAME: Organize recovered photos by date
# DESC: Turns flat carve output (f12345678.jpg ...) into a customer-browsable archive: reads each photo's capture date (EXIF, via sips) and hardlinks into DEST/delivery/photos/YYYY/MM/. Undated photos go to .../undated/. Originals untouched. Slow but one-time (one sips call per photo).
# REQUIRES_ROOT: no

set -u
DEST=""; LABEL=""; INDIR=""
while [ $# -gt 0 ]; do case "$1" in
  --dest)  [ $# -ge 2 ] || { echo "--dest requires a path"; exit 2; }; DEST="$2"; shift 2;;
  --label) [ $# -ge 2 ] || { echo "--label requires a name"; exit 2; }; LABEL="$2"; shift 2;;
  --in)    [ $# -ge 2 ] || { echo "--in requires a path"; exit 2; }; INDIR="$2"; shift 2;;
  *) shift;;
esac; done
[ -n "$DEST" ] && [ -n "$LABEL" ] || { echo "need --dest and --label"; exit 2; }
INDIR="${INDIR:-$DEST/triage/user_data/photos}"
[ -d "$INDIR" ] || { echo "input dir not found: $INDIR (run triage first, or pass --in)"; exit 1; }

OUT="$DEST/delivery/photos"
LOGF="$DEST/$LABEL.photos.log"
exec > >(tee -a "$LOGF") 2>&1
ts() { date '+%F %T'; }
echo "[$(ts)] organizing photos from $INDIR -> $OUT (by capture date)"
caffeinate -dims & CAF=$!
trap 'kill $CAF 2>/dev/null' EXIT
mkdir -p "$OUT/undated"

N=0; DATED=0
# No extension filter: everything triage put in user_data/photos IS a photo,
# and 60_package skips triage/user_data/photos when this tree exists — any
# format missed here would silently vanish from the customer package.
# Formats sips can't read just land in undated/.
find "$INDIR" -type f -print0 2>/dev/null \
| while IFS= read -r -d '' f; do
  N=$((N + 1)); [ $((N % 2000)) -eq 0 ] && echo "[progress] $N photos processed"
  # sips reads the EXIF creation date: "creation: 2021:06:12 10:33:21"
  CD=$(sips -g creation "$f" 2>/dev/null | awk '/creation:/ {print $2}')
  case "$CD" in
    [12][0-9][0-9][0-9]:[01][0-9]*)
      Y=${CD%%:*}; REST=${CD#*:}; M=${REST%%:*}
      D="$OUT/$Y/$M"
      DATED=$((DATED + 1));;
    *) D="$OUT/undated";;
  esac
  mkdir -p "$D"
  B=$(basename "$f")
  T="$D/$B"; i=0
  # same inode = this photo is already in the tree (re-run after adding
  # rescue keepers must not double-link everything); only suffix true
  # name collisions between different files
  while [ -e "$T" ]; do
    [ "$(stat -f%i "$T" 2>/dev/null)" = "$(stat -f%i "$f")" ] && continue 2
    i=$((i + 1)); T="$D/${i}_$B"
  done
  ln "$f" "$T" 2>/dev/null || cp "$f" "$T"
done
echo "[$(ts)] done — tree:"
du -sh "$OUT"/* 2>/dev/null | sed 's/^/  /'
