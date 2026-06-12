#!/bin/bash
# NAME: Probe patient (read-only health & bridge triage)
# DESC: Pre-imaging interrogation of a disk within macOS limits: bridge identity, SCSI identity, capacity sanity (vendor-placeholder detection), partition map, SMART where available. Pure reads; writes only a log to the job drive. Codifies the kit's field-notes diagnostics.
# REQUIRES_ROOT: no

set -u
DEST=""; LABEL=""; DEVICE=""
while [ $# -gt 0 ]; do case "$1" in
  --dest)   [ $# -ge 2 ] || { echo "--dest requires a path"; exit 2; }; DEST="$2"; shift 2;;
  --label)  [ $# -ge 2 ] || { echo "--label requires a name"; exit 2; }; LABEL="$2"; shift 2;;
  --device) [ $# -ge 2 ] || { echo "--device requires diskN"; exit 2; }; DEVICE="${2#/dev/}"; shift 2;;
  *) shift;;
esac; done
[ -n "$DEST" ] && [ -n "$LABEL" ] || { echo "need --dest and --label"; exit 2; }

LOGF="$DEST/$LABEL.probe.log"
exec > >(tee -a "$LOGF") 2>&1
ts() { date '+%F %T'; }
echo "[$(ts)] === patient probe ==="

pl() {
  local tmp v
  tmp=$(mktemp "${TMPDIR:-/tmp}/rk_pl.XXXXXX") || return 1
  diskutil info -plist "$1" >"$tmp" 2>/dev/null
  v=$(plutil -extract "$2" raw -o - "$tmp" 2>/dev/null)
  [ -n "$v" ] || v=$(/usr/libexec/PlistBuddy -c "Print :$2" "$tmp" 2>/dev/null)
  rm -f "$tmp"
  printf '%s' "$v"
}

probe_one() {
  local d="$1" sz nm proto smart
  sz=$(pl "$d" TotalSize); nm=$(pl "$d" MediaName); proto=$(pl "$d" BusProtocol)
  smart=$(pl "$d" SMARTStatus)
  echo "----- $d -----"
  echo "  media:    ${nm:-?}"
  echo "  bus:      ${proto:-?}"
  echo "  size:     ${sz:-?} bytes"
  echo "  SMART:    ${smart:-n/a}"
  case "$sz" in
    ''|*[!0-9]*) echo "  VERDICT:  size unreadable — device not answering cleanly";;
    *)
      if [ "$sz" -lt 50000000 ]; then
        echo "  VERDICT:  TINY CAPACITY — vendor placeholder or controller ROM/safe mode."
        echo "            If this persists on direct SATA it is the DRIVE's own ROM identity"
        echo "            (e.g. Phison 'SATAFIRM S11'/'PS3111') -> loader-level lab work."
        echo "            Do NOT initialize, do NOT image this stub as the patient."
      else
        echo "  partition map:"
        diskutil list "$d" 2>/dev/null | sed 's/^/    /'
      fi;;
  esac
}

echo "[$(ts)] USB bridges present:"
ioreg -p IOUSB -l -w0 2>/dev/null \
  | grep -iE '"USB Product Name"|"USB Vendor Name"|"idVendor"|"idProduct"' | sed 's/^ *//;s/^/  /'
echo
echo "[$(ts)] SCSI identities behind bridges:"
ioreg -c IOSCSIPeripheralDeviceNub -l -w0 2>/dev/null \
  | grep -iE '"Vendor Identification"|"Product Identification"' | sed 's/^ *//;s/^/  /' | sort -u
echo

if [ -n "$DEVICE" ]; then
  probe_one "$DEVICE"
else
  echo "[$(ts)] probing all external physical disks:"
  for d in $(diskutil list external physical 2>/dev/null \
              | awk '$1 ~ /^\/dev\/disk[0-9]+$/ {sub(/^\/dev\//,"",$1); print $1}'); do
    probe_one "$d"
  done
fi
echo "[$(ts)] probe complete — log: $LOGF"
