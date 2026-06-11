#!/bin/bash
# RescueKit — classic GUI, portable to macOS 10.14.6 (Mojave) through current.
#
# Pure bash 3.2 + osascript + Terminal: no Swift, no compiled code, no runtime
# version dependencies — the same file works on an old Intel bench Mac and on
# Apple Silicon. Double-click in Finder; native dialogs collect the job
# parameters, then the chosen recovery method runs (with sudo) right here in
# this Terminal window so you watch live ddrescue progress.
#
# On first launch Gatekeeper may block it: right-click → Open, or
#   xattr -d com.apple.quarantine rescue_gui_classic.command
set -u

KIT="$(cd "$(dirname "$0")" && pwd)"
[ -d "$KIT/methods" ] || KIT="$HOME/RecoveryKit"
METHODS="$KIT/methods"

alert() { /usr/bin/osascript -e "display alert \"RescueKit\" message \"$1\"" >/dev/null 2>&1; }

# choose_from PROMPT  (items on stdin, one per line) -> prints chosen line
choose_from() {
  local prompt="$1" items
  items=$(cat | sed '/^[[:space:]]*$/d; s/\\/\\\\/g; s/"/\\"/g')
  /usr/bin/osascript <<EOF
set theText to "$items"
set theItems to paragraphs of theText
set c to choose from list theItems with prompt "$prompt" without multiple selections allowed
if c is false then return ""
return item 1 of c
EOF
}

# ask_text PROMPT DEFAULT -> prints entered text, or "__CANCEL__"
ask_text() {
  /usr/bin/osascript <<EOF
try
  return text returned of (display dialog "$1" default answer "$2")
on error number -128
  return "__CANCEL__"
end try
EOF
}

# ask_image -> prints chosen .img path, "" for default, or "__CANCEL__"
ask_image() {
  local choice
  choice=$(/usr/bin/osascript <<'EOF'
try
  return button returned of (display dialog "Disk image for Extract/Carve:" buttons {"Cancel", "Choose file…", "Use default"} default button "Use default")
on error number -128
  return "Cancel"
end try
EOF
)
  case "$choice" in
    "Choose file…")
      /usr/bin/osascript -e 'try
  return POSIX path of (choose file with prompt "Choose a recovered .img file")
on error number -128
  return ""
end try' ;;
    Cancel) printf '__CANCEL__' ;;
    *) printf '' ;;   # use default DEST/LABEL.img
  esac
}

# --- 1. method --------------------------------------------------------------
names=""; i=0
PATHS=()
for f in "$METHODS"/*.sh; do
  [ -f "$f" ] || continue
  n=$(awk '/^# NAME:/{sub(/^# NAME:[[:space:]]*/,"");print;exit}' "$f")
  [ -n "$n" ] || n=$(basename "$f")
  names="${names}${n}
"
  PATHS[$i]="$f"; i=$((i+1))
done
[ "$i" -gt 0 ] || { alert "No methods found in $METHODS"; exit 1; }

pick=$(printf '%s' "$names" | choose_from "Recovery method:")
[ -n "$pick" ] || exit 0
method=""; j=0
for f in "$METHODS"/*.sh; do
  [ -f "$f" ] || continue
  n=$(awk '/^# NAME:/{sub(/^# NAME:[[:space:]]*/,"");print;exit}' "$f")
  [ -n "$n" ] || n=$(basename "$f")
  [ "$n" = "$pick" ] && method="$f"
  j=$((j+1))
done
[ -n "$method" ] || { alert "Could not resolve method."; exit 1; }

# --- 2. destination (a mounted job volume) ----------------------------------
dests=""
for v in /Volumes/*; do
  [ -d "$v" ] || continue
  b=$(basename "$v")
  case "$b" in .*) continue;; esac
  dests="${dests}${b}
"
done
dest=$(printf '%s' "$dests" | choose_from "Destination job volume (image is written here):")
[ -n "$dest" ] || exit 0

# --- 3. source disk (optional; Auto-detect waits for the patient) -----------
srcs="Auto-detect (wait for the disk to appear)
"
for d in $(diskutil list external physical 2>/dev/null \
            | awk '$1 ~ /^\/dev\/disk[0-9]+$/ && /external/ { sub(/^\/dev\//,"",$1); print $1 }'); do
  t=$(mktemp "${TMPDIR:-/tmp}/rk.XXXXXX")
  diskutil info -plist "$d" >"$t" 2>/dev/null
  sz=$(plutil -extract TotalSize raw -o - "$t" 2>/dev/null)
  [ -n "$sz" ] || sz=$(/usr/libexec/PlistBuddy -c "Print :TotalSize" "$t" 2>/dev/null)
  nm=$(plutil -extract MediaName raw -o - "$t" 2>/dev/null)
  [ -n "$nm" ] || nm=$(/usr/libexec/PlistBuddy -c "Print :MediaName" "$t" 2>/dev/null)
  rm -f "$t"
  gb=$(awk -v s="${sz:-0}" 'BEGIN{printf "%.1f", s/1e9}')
  srcs="${srcs}${d} — ${gb} GB — ${nm}
"
done
srcpick=$(printf '%s' "$srcs" | choose_from "Source disk (the failing drive). Leave on Auto-detect if it isn't up yet:")
[ -n "$srcpick" ] || exit 0
device=""
case "$srcpick" in
  Auto-detect*) device="";;
  disk*) device="${srcpick%% *}";;
esac

# --- 4. label, optional image, extra args -----------------------------------
label=$(ask_text "Job label (basename for the image / map / log files):" "rescue_$(date +%Y%m%d)")
[ "$label" = "__CANCEL__" ] && exit 0
[ -n "$label" ] || label="rescue_$(date +%Y%m%d)"

# Only methods that declare "# ACCEPTS: image" can take a specific .img.
image=""
if grep -q '^# ACCEPTS:.*image' "$method"; then
  image=$(ask_image)
  [ "$image" = "__CANCEL__" ] && exit 0
fi

extra=$(ask_text "Extra options (optional), e.g. --size-gb 251 --yes :" "")
[ "$extra" = "__CANCEL__" ] && exit 0

# --- 5. run the method here, with sudo, live ------------------------------
set --
set -- bash "$method" --dest "/Volumes/$dest" --label "$label"
[ -n "$device" ] && set -- "$@" --device "$device"
[ -n "$image" ]  && set -- "$@" --image "$image"

echo "============================================================"
echo " RescueKit — running: $pick"
echo " method:  $method"
echo " dest:    /Volumes/$dest"
echo " label:   $label"
[ -n "$device" ] && echo " source:  $device"
[ -n "$image" ]  && echo " image:   $image"
[ -n "$extra" ]  && echo " extra:   $extra"
echo "============================================================"
echo "You will be asked for your password (sudo)."
echo
# extra is intentionally unquoted so multiple flags word-split
exec sudo "$@" $extra
