#!/bin/bash
# NAME: Package customer delivery (manifest + summary)
# DESC: Assembles DEST/delivery_<label>/ from the recovered trees (extracted/, tsk_extracted/, delivery/photos/, triage/user_data/ — whatever exists) via hardlinks, writes MANIFEST.tsv (path, bytes; add --checksums for SHA-256, slow) and a customer README. Originals untouched.
# REQUIRES_ROOT: no

set -u
DEST=""; LABEL=""; SUMS=0
while [ $# -gt 0 ]; do case "$1" in
  --dest)  [ $# -ge 2 ] || { echo "--dest requires a path"; exit 2; }; DEST="$2"; shift 2;;
  --label) [ $# -ge 2 ] || { echo "--label requires a name"; exit 2; }; LABEL="$2"; shift 2;;
  --checksums) SUMS=1; shift;;
  *) shift;;
esac; done
[ -n "$DEST" ] && [ -n "$LABEL" ] || { echo "need --dest and --label"; exit 2; }

PKG="$DEST/delivery_$LABEL"
LOGF="$DEST/$LABEL.package.log"
exec > >(tee -a "$LOGF") 2>&1
ts() { date '+%F %T'; }
echo "[$(ts)] packaging delivery -> $PKG"
caffeinate -dims & CAF=$!
trap 'kill $CAF 2>/dev/null' EXIT
mkdir -p "$PKG"

FOUND=0
for src in "delivery/photos" "extracted" "tsk_extracted" "triage/user_data"; do
  [ -d "$DEST/$src" ] || continue
  FOUND=1
  # When the date-sorted photo tree exists, the same photos must not ship a
  # second time out of triage/user_data/photos — skip that subtree. But only
  # if delivery/photos really is a superset: an interrupted 45_ run leaves a
  # partial tree, and skipping then would silently drop photos from the
  # package. Shipping twice is the safe direction.
  SKIP=""
  if [ "$src" = "triage/user_data" ] && [ -d "$DEST/delivery/photos" ] \
     && [ -d "$DEST/triage/user_data/photos" ]; then
    NP=$(find "$DEST/triage/user_data/photos" -type f 2>/dev/null | wc -l | tr -d ' ')
    ND=$(find "$DEST/delivery/photos" -type f 2>/dev/null | wc -l | tr -d ' ')
    if [ "$ND" -ge "$NP" ]; then
      SKIP="photos/"
      echo "[$(ts)] note: skipping triage/user_data/photos ($NP files already date-sorted in delivery/photos)"
    else
      echo "[$(ts)] WARNING: delivery/photos has $ND files but triage/user_data/photos has $NP —"
      echo "[$(ts)]          date-sort looks incomplete; shipping BOTH trees (duplicates beat data loss)."
      echo "[$(ts)]          Re-run 45_organize_photos and re-package to fix."
    fi
  fi
  name=$(echo "$src" | tr '/' '_')
  echo "[$(ts)] linking $src -> $PKG/$name/"
  find "$DEST/$src" -type f -print0 2>/dev/null | /usr/bin/perl -0 -ne '
BEGIN { use File::Path qw(make_path); use File::Copy qw(copy);
        ($ROOT, $OUT, $SKIP) = @ARGV; @ARGV = (); }
chomp; my $f = $_;
(my $rel = $f) =~ s/^\Q$ROOT\E\/?//;
next if $SKIP ne "" && index($rel, $SKIP) == 0;
my $t = "$OUT/$rel";
(my $d = $t) =~ s{/[^/]+$}{};
make_path($d) unless -d $d;
-e $t or link($f, $t) or copy($f, $t);
' "$DEST/$src" "$PKG/$name" "$SKIP"
done
[ "$FOUND" -eq 1 ] || { echo "[$(ts)] nothing to package — run extraction/triage first"; exit 1; }

echo "[$(ts)] writing MANIFEST.tsv"
if [ "$SUMS" -eq 1 ]; then
  find "$PKG" -type f ! -name 'MANIFEST.tsv' ! -name 'README.txt' -print0 2>/dev/null \
    | while IFS= read -r -d '' f; do
        printf '%s\t%s\t%s\n' "${f#$PKG/}" "$(stat -f%z "$f")" "$(shasum -a 256 "$f" | awk '{print $1}')"
      done > "$PKG/MANIFEST.tsv"
else
  find "$PKG" -type f ! -name 'MANIFEST.tsv' ! -name 'README.txt' -print0 2>/dev/null \
    | while IFS= read -r -d '' f; do
        printf '%s\t%s\n' "${f#$PKG/}" "$(stat -f%z "$f")"
      done > "$PKG/MANIFEST.tsv"
fi

NF=$(wc -l < "$PKG/MANIFEST.tsv" | tr -d ' ')
SZ=$(du -sh "$PKG" 2>/dev/null | awk '{print $1}')
cat > "$PKG/README.txt" <<EOF
Recovered data — job $LABEL
Packaged: $(date '+%F %T')

Contents: $NF files, $SZ total. See MANIFEST.tsv for the full list.

Folder guide:
  delivery_photos/  photos sorted by capture date (undated/ = no date found)
  extracted/ or tsk_extracted/  files with original names and folders
  triage_user_data/ files recovered by content (original names were lost)

Files recovered from a damaged drive may be partially readable. If anything
important does not open, contact the shop — the master image is retained.
EOF
echo "[$(ts)] done: $NF files, $SZ — $PKG"
