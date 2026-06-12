#!/bin/bash
# NAME: Triage carved files (user data vs junk)
# DESC: Classifies PhotoRec output in DEST/carved into user data / review / junk using content heuristics (camera EXIF, image dimensions, sqlite table names, text markers) and hardlinks results into DEST/triage/<tier>/<category>/ — originals untouched, near-zero extra space. Writes a TSV report + summary.
# REQUIRES_ROOT: no
#
# Optional: --carved <dir> to triage a different carve output directory.
# Tiers:  user_data  = high-confidence customer files (photos w/ EXIF, docs,
#                      videos, message/photo databases, mail)
#         review     = plausible user data needing a human eye (large images
#                      without EXIF, free text, big archives, odd types)
#         junk       = OS/app/cache noise (plists, UI images, fonts, logs)

set -u
DEST=""; LABEL=""; CARVED=""
while [ $# -gt 0 ]; do case "$1" in
  --dest)   [ $# -ge 2 ] || { echo "--dest requires a path"; exit 2; }; DEST="$2"; shift 2;;
  --label)  [ $# -ge 2 ] || { echo "--label requires a name"; exit 2; }; LABEL="$2"; shift 2;;
  --carved) [ $# -ge 2 ] || { echo "--carved requires a path"; exit 2; }; CARVED="$2"; shift 2;;
  *) shift;;   # tolerate args meant for other methods
esac; done
[ -n "$DEST" ] && [ -n "$LABEL" ] || { echo "need --dest and --label"; exit 2; }
CARVED="${CARVED:-$DEST/carved}"
[ -d "$CARVED" ] || { echo "carve output not found: $CARVED (run the carve method first)"; exit 1; }

TRIAGE="$DEST/triage"
TSV="$DEST/$LABEL.triage.tsv"
LOGF="$DEST/$LABEL.triage.log"
SQLV="$TRIAGE/.sqlite_verdicts.tsv"
# Per-label lock: a second triage on the same job truncates the TSV/verdicts
# the first one is still writing.
TLOCK="$DEST/$LABEL.triage.lock"
if ! mkdir "$TLOCK" 2>/dev/null; then
  if [ -f "$TLOCK/pid" ] && kill -0 "$(cat "$TLOCK/pid" 2>/dev/null)" 2>/dev/null; then
    echo "another triage for label '$LABEL' is active (pid $(cat "$TLOCK/pid"))"; exit 1
  fi
  rm -rf "$TLOCK"; mkdir "$TLOCK" || exit 1
fi
echo $$ > "$TLOCK/pid"

exec > >(tee -a "$LOGF") 2>&1
ts() { date '+%F %T'; }
echo "[$(ts)] triage of $CARVED -> $TRIAGE"
mkdir -p "$TRIAGE"
: > "$TSV"; : > "$SQLV"

caffeinate -dims & CAF=$!
trap 'kill $CAF 2>/dev/null; rm -rf "$TLOCK"' EXIT

# --- Pass 1: sqlite databases (needs the sqlite3 CLI; ~1k files, cheap) ----
# Carved app databases are junk except the ones holding user content;
# those are identified by their table names.
USERDB_RE='ZASSET|ZGENERICASSET|message|chat|whats_app|client_messages|client_threads|client_contacts|ZICCLOUD|ZICNOTE|ZNOTE|ABPERSON|ZCONTACT|ZCALENDAR|CalendarItem|mailbox|ZMAILMESSAGE|history_items|bookmarks|call_history'
echo "[$(ts)] pass 1: scanning sqlite databases..."
DBN=0
find "$CARVED" -type f -name "*.sqlite" -print0 2>/dev/null \
| while IFS= read -r -d '' f; do
  DBN=$((DBN + 1)); [ $((DBN % 200)) -eq 0 ] && echo "[progress] $DBN databases scanned" >&2
  sz=$(stat -f%z "$f" 2>/dev/null || echo 0)
  # -readonly: a carved DB with a hot journal must NOT be replayed in place —
  # the originals on the job drive stay byte-identical.
  t=$(sqlite3 -readonly "$f" ".tables" 2>/dev/null)
  if [ -n "$t" ] && echo "$t" | grep -qiE "$USERDB_RE"; then
    printf '%s\tuser_data\tdatabases\tuser-content tables\n' "$f"
  elif [ -z "$t" ] && [ "$sz" -ge 1048576 ]; then
    printf '%s\treview\tdatabases\tunreadable but large\n' "$f"
  else
    printf '%s\tjunk\tapp_databases\tapp/cache tables\n' "$f"
  fi
done >> "$SQLV"
echo "[$(ts)] pass 1 done: $(wc -l < "$SQLV" | tr -d ' ') databases classified"

# --- Pass 2: everything, single Perl process (fast; no per-file spawns) ----
# Perl is stock on every macOS including 10.14. It classifies by extension,
# peeks at content where that decides the tier (JPEG EXIF camera make, PNG
# dimensions, text markers), hardlinks into the triage tree (link() syscall;
# copies if linking fails), and emits one TSV row per file.
echo "[$(ts)] pass 2: classifying + linking all files..."
find "$CARVED" -type f ! -name "photorec.log" ! -name "report.xml" -print0 2>/dev/null \
| /usr/bin/perl -0 -ne '
BEGIN {
  use File::Path qw(make_path); use File::Copy qw(copy);
  ($TRIAGE, $TSV, $SQLV) = @ARGV; @ARGV = ();
  open($tsv, ">>", $TSV) or die "tsv: $!";
  if (open(my $sv, "<", $SQLV)) {
    local $/ = "\n";   # main loop runs under -0 (NUL records); this file is line-based
    while (<$sv>) { chomp; my @c = split /\t/, $_, 4; $sq{$c[0]} = [@c[1..3]] if @c == 4; }
    close $sv;
  }
  $cam = qr/(Apple|Canon|Nikon|SONY|samsung|FUJIFILM|Panasonic|OLYMPUS|GoPro|DJI|Google|HUAWEI|Motorola|HTC|RICOH|PENTAX|KODAK|Hasselblad|Leica|SIGMA|Xiaomi|OnePlus)/i;
  $n = 0;
}
chomp; my $f = $_;
my ($ext) = $f =~ /\.([^.\/]+)$/; $ext = lc($ext // "none");
my $sz = (lstat($f))[7] // 0;
my ($tier, $cat, $why);

sub peek { my ($f, $len) = @_; my $b = ""; if (open(my $fh, "<", $f)) { read($fh, $b, $len); close $fh; } return $b; }

if (exists $sq{$f}) { ($tier, $cat, $why) = @{$sq{$f}}; }
elsif ($ext =~ /^(heic|heif|dng|nef|cr2|arw|orf|raf)$/) { ($tier,$cat,$why)=("user_data","photos","camera format"); }
elsif ($ext =~ /^(mov|mp4|m4v|avi|mts|3gp)$/) { ($tier,$cat,$why)=("user_data","videos","video"); }
elsif ($ext =~ /^(m4a|mp3|wav|aiff|aac|flac)$/) { ($tier,$cat,$why)=("user_data","audio","audio"); }
elsif ($ext =~ /^(pdf|docx?|xlsx?|pptx?|pages|numbers|key|rtfd?|csv|ai|psd|epub)$/) { ($tier,$cat,$why)=("user_data","documents","document"); }
elsif ($ext =~ /^(eml|emlx|vcf|ics)$/) { ($tier,$cat,$why)=("user_data","mail_contacts","mail/contact"); }
elsif ($ext eq "jpg" || $ext eq "jpeg") {
  if ($sz < 32768) { ($tier,$cat,$why)=("junk","image_cache","thumbnail-size"); }
  else {
    my $b = peek($f, 16384);
    if ($b =~ $cam)                          { ($tier,$cat,$why)=("user_data","photos","camera EXIF: $1"); }
    elsif ($b =~ /Exif/ && $sz >= 262144)    { ($tier,$cat,$why)=("user_data","photos","EXIF present"); }
    elsif ($sz >= 2097152)                   { ($tier,$cat,$why)=("review","images","large, no EXIF"); }
    else                                     { ($tier,$cat,$why)=("junk","image_cache","no EXIF, small"); }
  }
}
elsif ($ext eq "png") {
  my $b = peek($f, 24);
  my ($w, $h) = (length($b) >= 24) ? unpack("NN", substr($b, 16, 8)) : (0, 0);
  my $min = $w < $h ? $w : $h;
  if ($min >= 600 || $sz >= 1048576) { ($tier,$cat,$why)=("review","images","${w}x${h}"); }
  else                               { ($tier,$cat,$why)=("junk","system_images","${w}x${h} UI asset"); }
}
elsif ($ext =~ /^(tif|tiff)$/) {
  my $b = peek($f, 16384);
  if ($b =~ $cam)            { ($tier,$cat,$why)=("user_data","photos","camera EXIF: $1"); }
  elsif ($sz >= 1048576)     { ($tier,$cat,$why)=("review","images","large tiff"); }
  else                       { ($tier,$cat,$why)=("junk","system_images","small tiff"); }
}
elsif ($ext eq "txt") {
  my $b = peek($f, 2048);
  if ($b =~ /Copyright|Licen[sc]e|<\?xml|<!DOCTYPE|#include|\bfunction\s*\(|^\s*[\{\[]/i)
       { ($tier,$cat,$why)=("junk","text_system","license/markup/code"); }
  else { ($tier,$cat,$why)=("review","text","free text"); }
}
elsif ($ext eq "gz")  { ($tier,$cat,$why) = $sz >= 1048576 ? ("review","archives","large gz") : ("junk","logs_caches","rotated log/cache"); }
elsif ($ext =~ /^(zip|dmg|tar|7z|rar)$/) { ($tier,$cat,$why)=("review","archives","archive"); }
elsif ($ext eq "gif") { ($tier,$cat,$why) = $sz >= 1048576 ? ("review","images","large gif") : ("junk","web_assets","small gif"); }
elsif ($ext eq "plist") { ($tier,$cat,$why)=("junk","plists","preferences/config"); }
elsif ($ext =~ /^(icns|ico|ttf|otf|woff2?|car|nib)$/) { ($tier,$cat,$why)=("junk","fonts_ui","UI resource"); }
elsif ($ext =~ /^(html?|css|js|xml|svg|json|strings)$/) { ($tier,$cat,$why)=("junk","web_assets","web/markup"); }
elsif ($ext =~ /^(java|h|c|cpp|hpp|m|mm|pm|pl|py|sh|rb|f|swift|go)$/) { ($tier,$cat,$why)=("junk","source_code","OS/dev source"); }
elsif ($ext =~ /^(caf|sqlite-wal|sqlite-shm|db|log)$/) { ($tier,$cat,$why)=("junk","logs_caches","system/cache"); }
else { ($tier,$cat,$why)=("review","other",".$ext"); }

my ($parent) = $f =~ m{([^/]+)/[^/]+$};
my ($base)   = $f =~ m{([^/]+)$};
my $dir = "$TRIAGE/$tier/$cat";
make_path($dir) unless -d $dir;
my $target = "$dir/${parent}_$base";
# -e first: reruns after an interrupted pass must skip, not copy-on-EEXIST
-e $target or link($f, $target) or copy($f, $target);
print $tsv join("\t", $f, $tier, $cat, $why, $sz), "\n";
print STDERR "[progress] $n files\n" if ++$n % 25000 == 0;
END { close $tsv; print STDERR "[done] $n files classified\n"; }
' "$TRIAGE" "$TSV" "$SQLV"

echo "[$(ts)] pass 2 done"

# --- Summary ----------------------------------------------------------------
echo
echo "================= TRIAGE SUMMARY ================="
awk -F'\t' '
  { n[$2]++; b[$2]+=$5; nc[$2 "/" $3]++; bc[$2 "/" $3]+=$5 }
  END {
    for (t in n) printf "%-10s %8d files  %8.1f GB\n", t, n[t], b[t]/1e9;
    print "--------------------------------------------------";
    for (c in nc) printf "%-32s %8d  %8.1f GB\n", c, nc[c], bc[c]/1e9;
  }' "$TSV" | sort
echo "=================================================="
echo "[$(ts)] sorted tree:  $TRIAGE/{user_data,review,junk}/<category>/"
echo "[$(ts)] full report:  $TSV"
echo "[$(ts)] start with:   user_data/photos, user_data/documents, user_data/databases"
echo "[$(ts)] then skim:    review/images (screenshots etc.), review/text, review/archives"
