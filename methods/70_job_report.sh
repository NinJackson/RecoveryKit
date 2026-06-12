#!/bin/bash
# NAME: Generate final job report
# DESC: One command that reads everything the other methods left on the job drive (imaging log + mapfile stats, verify/carve/extract/triage logs and TSV) and writes a single technician-readable DEST/LABEL.report.txt summarizing the whole recovery.
# REQUIRES_ROOT: no

set -u
DEST=""; LABEL=""
while [ $# -gt 0 ]; do case "$1" in
  --dest)  [ $# -ge 2 ] || { echo "--dest requires a path"; exit 2; }; DEST="$2"; shift 2;;
  --label) [ $# -ge 2 ] || { echo "--label requires a name"; exit 2; }; LABEL="$2"; shift 2;;
  *) shift;;
esac; done
[ -n "$DEST" ] && [ -n "$LABEL" ] || { echo "need --dest and --label"; exit 2; }

R="$DEST/$LABEL.report.txt"
DLOG=""
for p in /Users/service/RecoveryKit/tools/bin /Users/service/TDM_Recovery/tools/bin /usr/local/bin /opt/homebrew/bin; do
  [ -x "$p/ddrescuelog" ] && DLOG="$p/ddrescuelog" && break
done

{
  echo "================================================================"
  echo " RECOVERY JOB REPORT — $LABEL"
  echo " Generated: $(date '+%F %T')   Job drive: $DEST"
  echo "================================================================"

  IMG="$DEST/$LABEL.img"; MAP="$DEST/$LABEL.map"
  if [ -f "$IMG" ]; then
    echo; echo "--- IMAGING ---"
    echo "image: $IMG ($(stat -f%z "$IMG") bytes)"
    [ -f "$IMG.sha256" ] && echo "sha256: $(awk '{print $1}' "$IMG.sha256")"
    if [ -f "$MAP" ] && [ -n "$DLOG" ]; then
      "$DLOG" -t "$MAP" 2>/dev/null
    fi
    [ -f "$DEST/$LABEL.log" ] && {
      echo "imaging cycles:"
      grep -E "cycle [0-9]+/|ddrescue exited|all readable" "$DEST/$LABEL.log" | tail -12 | sed 's/^/  /'
    }
  fi

  [ -f "$DEST/$LABEL.probe.log" ] && {
    echo; echo "--- PATIENT PROBE (last verdicts) ---"
    grep -E "VERDICT|media:|bus:" "$DEST/$LABEL.probe.log" | tail -9 | sed 's/^/  /'
  }

  if [ -d "$DEST/carved" ]; then
    echo; echo "--- CARVING ---"
    echo "carved files: $(find "$DEST/carved" -type f ! -name 'photorec.log' ! -name 'report.xml' 2>/dev/null | wc -l | tr -d ' ')  ($(du -sh "$DEST/carved" 2>/dev/null | awk '{print $1}'))"
  fi

  for d in extracted tsk_extracted; do
    [ -d "$DEST/$d" ] && {
      echo; echo "--- ${d} ---"
      echo "files: $(find "$DEST/$d" -type f 2>/dev/null | wc -l | tr -d ' ')  ($(du -sh "$DEST/$d" 2>/dev/null | awk '{print $1}'))"
    }
  done

  TSV="$DEST/$LABEL.triage.tsv"
  if [ -f "$TSV" ]; then
    echo; echo "--- TRIAGE (user data vs junk) ---"
    awk -F'\t' '
      { n[$2]++; b[$2]+=$5; nc[$2 "/" $3]++; bc[$2 "/" $3]+=$5 }
      END {
        for (t in n) printf "%-10s %8d files  %8.1f GB\n", t, n[t], b[t]/1e9;
        print "  ---";
        for (c in nc) printf "  %-30s %8d  %8.1f GB\n", c, nc[c], bc[c]/1e9;
      }' "$TSV" | sort
  fi

  PKG="$DEST/delivery_$LABEL"
  [ -d "$PKG" ] && {
    echo; echo "--- DELIVERY PACKAGE ---"
    echo "$PKG: $(find "$PKG" -type f 2>/dev/null | wc -l | tr -d ' ') files ($(du -sh "$PKG" 2>/dev/null | awk '{print $1}'))"
  }

  echo; echo "--- ARTIFACT INDEX ---"
  ls -lh "$DEST/$LABEL".* 2>/dev/null | awk '{print "  " $9 "  (" $5 ")"}'
  echo "================================================================"
} > "$R"

cat "$R"
echo
echo "report written: $R"
