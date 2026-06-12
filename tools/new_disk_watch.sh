#!/bin/bash
# new_disk_watch.sh [min_gb] [max_minutes] — exit 0 the moment a NEW external
# physical whole-disk (>= min_gb, default 30) appears vs. the baseline taken
# at launch. Baseline entries are identity-keyed (diskN/bytes) so a recycled
# disk number with a different drive behind it still registers as new.
# Generic kit utility; no root needed.
MIN_GB=${1:-30}; MAX_MIN=${2:-120}

disk_ids() {
  diskutil list external physical 2>/dev/null \
    | awk '$1 ~ /^\/dev\/disk[0-9]+$/ {sub(/^\/dev\//,"",$1); print $1}'
}
disk_size() {  # $1 = diskN -> bytes (empty if unreadable)
  local t sz
  t=$(mktemp "${TMPDIR:-/tmp}/ndw.XXXXXX"); diskutil info -plist "$1" >"$t" 2>/dev/null
  sz=$(plutil -extract TotalSize raw -o - "$t" 2>/dev/null)
  [ -n "$sz" ] || sz=$(/usr/libexec/PlistBuddy -c "Print :TotalSize" "$t" 2>/dev/null)
  rm -f "$t"
  printf '%s' "$sz"
}

BASE=""
for d in $(disk_ids); do
  BASE="$BASE $d/$(disk_size "$d")"
done
echo "baseline:$BASE"

i=0
while [ $i -lt $((MAX_MIN * 30)) ]; do
  i=$((i+1))
  for d in $(disk_ids); do
    sz=$(disk_size "$d")
    case "$BASE" in *" $d/$sz"*) continue;; esac
    case "$sz" in ''|*[!0-9]*) continue;; esac
    if [ "$sz" -ge $((MIN_GB * 1000000000)) ]; then
      t=$(mktemp "${TMPDIR:-/tmp}/ndw.XXXXXX"); diskutil info -plist "$d" >"$t" 2>/dev/null
      nm=$(plutil -extract MediaName raw -o - "$t" 2>/dev/null)
      [ -n "$nm" ] || nm=$(/usr/libexec/PlistBuddy -c "Print :MediaName" "$t" 2>/dev/null)
      rm -f "$t"
      echo "=== NEW DISK: $d  $(awk -v s="$sz" 'BEGIN{printf "%.1f GB", s/1e9}')  ${nm} === $(date)"
      diskutil list "$d"
      exit 0
    fi
  done
  sleep 2
done
echo "=== TIMEOUT: no new disk in $MAX_MIN minutes ==="
exit 1
