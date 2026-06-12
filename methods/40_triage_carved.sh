#!/bin/bash
# NAME: Triage carved files (user data vs junk)
# DESC: Classifies PhotoRec output in DEST/carved into user data / review / junk using content heuristics (camera EXIF, image dimensions, sqlite table names, text markers) and hardlinks results into DEST/triage/<tier>/<category>/ — originals untouched, near-zero extra space. Writes a TSV report + summary.
# REQUIRES_ROOT: no
#
# Optional: --carved <dir> to triage a different carve output directory.
# Tiers:  user_data  = high-confidence customer files (photos w/ EXIF, docs,
#                      videos, message/photo databases, mail)
#         review     = plausible user data needing a human eye (large images
#                      without EXIF, photo derivatives, free text, archives)
#         junk       = OS/app/cache noise (plists, UI images, fonts, logs)
#
# Classifier v2 (job-68930 audit lessons): EXIF-less jpgs >=50KB go to
# review/image_derivatives, not junk — PhotoStream renditions, X-rays/scans
# and edited exports live there, and on a partially-encrypted disk they can
# be the only surviving copies. PNGs >=500KB are user screenshots/scans
# (OS resources at the same pixel dims stay under 500KB). Camera-make
# matching ignores "Copyright <vendor>" strings (Photos derivatives carry
# "Copyright Apple Inc." and are NOT camera originals). Truncated carves
# (4-32KB camera formats, videos without a moov/moof atom) are demoted;
# oversized plists (>=2MB) are carve overruns/encrypted noise, not prefs;
# multi-MB tiffs whose header claims icon dims are over-carved UI assets.
# Untagged short audio is app SFX/TTS cache, not music.

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
  # 3-letter makes (HTC, DJI) are NOT here: case-insensitive over a 64KB
  # binary peek they false-positive on ~3% of files. camera_make() matches
  # them separately with EXIF-style NUL framing.
  $cam = qr/(Apple|Canon|Nikon|SONY|samsung|FUJIFILM|Panasonic|OLYMPUS|GoPro|Google|HUAWEI|Motorola|RICOH|PENTAX|KODAK|Hasselblad|Leica|SIGMA|Xiaomi|OnePlus)/i;
  $n = 0;
}
chomp; my $f = $_;
my ($ext) = $f =~ /\.([^.\/]+)$/; $ext = lc($ext // "none");
my $sz = (lstat($f))[7] // 0;
my ($tier, $cat, $why);

sub peek { my ($f, $len) = @_; my $b = ""; if (open(my $fh, "<", $f)) { read($fh, $b, $len); close $fh; } return $b; }
sub peek_tail { my ($f, $len) = @_; my $b = ""; my $s = (lstat($f))[7] // 0;
  if (open(my $fh, "<", $f)) { seek($fh, $s > $len ? $s - $len : 0, 0); read($fh, $b, $len); close $fh; }
  return $b; }
# Camera make, ignoring copyright notices: Photos-library derivatives embed
# "Copyright Apple Inc." which is NOT camera provenance. Short makes need a
# trailing NUL (EXIF strings are NUL-terminated) to not match random bytes.
sub camera_make { my ($b) = @_; (my $s = $b) =~ s/Copyright[\x20-\x7e]{0,80}//g;
  return $1 if $s =~ $cam;
  return $1 if $s =~ /(HTC|DJI)\x00/;
  return ""; }
# Walk top-level ISO-BMFF boxes looking for a moov/moof index. A grep of
# head+tail windows misses long recordings whose moov tables exceed the
# window; the box walk follows the declared mdat size straight to it.
sub bmff_has_index {
  my ($f) = @_;
  open(my $fh, "<", $f) or return 0; binmode $fh;
  my $sz = (stat($fh))[7] // 0;
  my ($pos, $n) = (0, 0);
  while ($pos + 8 <= $sz && $n++ < 64) {
    seek($fh, $pos, 0) or last;
    my $hdr = ""; last if read($fh, $hdr, 16) < 8;
    my ($len, $typ) = (unpack("N", substr($hdr, 0, 4)), substr($hdr, 4, 4));
    last unless $typ =~ /^[\x20-\x7e]{4}$/;          # garbage = not a box chain
    if ($typ eq "moov" || $typ eq "moof") { close $fh; return 1; }
    if    ($len == 0) { last; }                       # box runs to EOF
    elsif ($len == 1) {                               # 64-bit size
      last if length($hdr) < 16;
      my ($hi, $lo) = unpack("NN", substr($hdr, 8, 8));
      $len = $hi * 4294967296 + $lo;
      last if $len < 16;
    }
    last if $len < 8;
    $pos += $len;
  }
  close $fh; return 0;
}
# JPEG pixel dims: walk segments from SOI so the EXIF APP1 blob (which holds
# a thumbnail with its own SOF) is skipped, not matched.
sub jpeg_dims {
  my ($b) = @_; my $L = length($b);
  return (0, 0) unless $L >= 4 && substr($b, 0, 2) eq "\xFF\xD8";
  my $i = 2;
  while ($i + 9 <= $L) {
    if (substr($b, $i, 1) ne "\xFF") { last; }
    my $m = ord(substr($b, $i + 1, 1));
    if ($m == 0xFF) { $i++; next; }                       # fill byte
    if ($m == 0x01 || ($m >= 0xD0 && $m <= 0xD8)) { $i += 2; next; }  # standalone
    last if $m == 0xD9 || $m == 0xDA;                     # EOI / scan start
    my $len = unpack("n", substr($b, $i + 2, 2)) // 0;
    last if $len < 2;
    if ($m >= 0xC0 && $m <= 0xCF && $m != 0xC4 && $m != 0xC8 && $m != 0xCC) {
      return (unpack("n", substr($b, $i + 7, 2)) // 0, unpack("n", substr($b, $i + 5, 2)) // 0);
    }
    $i += 2 + $len;
  }
  return (0, 0);
}
# TIFF pixel dims from the first IFD (tags 256/257), both byte orders.
sub tiff_dims {
  my ($b) = @_; my $L = length($b);
  return (0, 0) unless $L >= 8;
  my $end = substr($b, 0, 2);
  return (0, 0) unless $end eq "II" || $end eq "MM";
  my ($l32, $l16) = $end eq "II" ? ("V", "v") : ("N", "n");
  my $off = unpack($l32, substr($b, 4, 4)) // 0;
  return (0, 0) if $off < 8 || $off + 2 > $L;
  my $cnt = unpack($l16, substr($b, $off, 2)) // 0;
  my ($w, $h) = (0, 0);
  for my $k (0 .. ($cnt > 64 ? 63 : $cnt - 1)) {
    my $e = $off + 2 + 12 * $k;
    last if $e + 12 > $L;
    my $tag = unpack($l16, substr($b, $e, 2));
    my $typ = unpack($l16, substr($b, $e + 2, 2));
    my $val = $typ == 3 ? unpack($l16, substr($b, $e + 8, 2)) : unpack($l32, substr($b, $e + 8, 4));
    $w = $val if $tag == 256; $h = $val if $tag == 257;
    last if $w && $h;
  }
  return ($w, $h);
}

if (exists $sq{$f}) { ($tier, $cat, $why) = @{$sq{$f}}; }
elsif ($ext =~ /^(heic|heif|dng|nef|cr2|arw|orf|raf)$/) {
  # a 4-32KB "camera format" file is a truncated carve, not a photo
  ($tier,$cat,$why) = $sz < 32768 ? ("junk","image_cache","truncated $ext carve")
                                  : ("user_data","photos","camera format");
}
elsif ($ext =~ /^(mov|mp4|m4v|avi|mts|3gp)$/) {
  if ($ext eq "avi" || $ext eq "mts") { ($tier,$cat,$why)=("user_data","videos","video"); }
  else {
    # ISO-BMFF without a moov/moof atom has no index — unplayable fragment
    if (bmff_has_index($f) || peek_tail($f, 65536) =~ /moov|moof/)
         { ($tier,$cat,$why)=("user_data","videos","video"); }
    else { ($tier,$cat,$why)=("review","truncated_media","no moov atom (truncated/encrypted; repair candidate)"); }
  }
}
elsif ($ext =~ /^(m4a|mp3|wav|aiff|aac|flac)$/) {
  my $b = peek($f, 65536); my $t = peek_tail($f, 128);
  if ($b =~ /^ID3/ || $t =~ /^TAG/ || $b =~ /\xA9(?:nam|ART|alb)|covr|aART/
      || ($ext eq "flac" && $b =~ /^fLaC/ && $b =~ /(?:TITLE|ARTIST|ALBUM)=/i))
       { ($tier,$cat,$why)=("user_data","audio","tagged music"); }
  elsif ($sz >= 2097152) { ($tier,$cat,$why)=("review","audio","untagged, large"); }
  elsif ($ext eq "m4a" && $sz >= 512000)
       { ($tier,$cat,$why)=("review","audio","untagged m4a (voice memo?)"); }
  else { ($tier,$cat,$why)=("junk","app_sounds","untagged short clip (app/system sound)"); }
}
elsif ($ext =~ /^(pdf|docx?|xlsx?|pptx?|pages|numbers|key|psd|epub)$/) {
  # sub-20KB carved PDFs are nearly all vector/icon assets, not documents
  ($tier,$cat,$why) = ($ext eq "pdf" && $sz < 20480)
    ? ("review","documents","tiny pdf (often vector/icon asset)")
    : ("user_data","documents","document");
}
elsif ($ext =~ /^(rtfd?|ai)$/) { ($tier,$cat,$why)=("review","documents","$ext (often app/design resource)"); }
elsif ($ext eq "csv") { ($tier,$cat,$why)=("review","text","csv (often misdetected fragment)"); }
elsif ($ext eq "vcf") {
  my $b = peek($f, 4096);
  ($tier,$cat,$why) = $b =~ /TipCard/ ? ("junk","web_assets","Apple TipCard vcard")
                                      : ("user_data","mail_contacts","contact card");
}
elsif ($ext eq "ics") {
  my $b = peek($f, 65536);   # VTIMEZONE blocks can push the first VEVENT deep
  ($tier,$cat,$why) = $b =~ /BEGIN:VEVENT/ ? ("user_data","mail_contacts","calendar events")
                                           : ("junk","logs_caches","alarm/no-event ics fragment");
}
elsif ($ext =~ /^(eml|emlx)$/) { ($tier,$cat,$why)=("user_data","mail_contacts","mail/contact"); }
elsif ($ext eq "jpg" || $ext eq "jpeg") {
  if ($sz < 32768) { ($tier,$cat,$why)=("junk","image_cache","thumbnail-size"); }
  else {
    my $b = peek($f, 65536);
    my $mk = camera_make($b);
    if ($mk)                              { ($tier,$cat,$why)=("user_data","photos","camera EXIF: $mk"); }
    elsif ($b =~ /Exif/ && $sz >= 262144) { ($tier,$cat,$why)=("user_data","photos","EXIF present"); }
    else {
      my ($w, $h) = jpeg_dims($b);
      my $d = ($w && $h) ? "${w}x${h}" : "dims unknown";
      # EXIF-less >=50KB jpgs are PhotoStream/Photos renditions, X-rays,
      # scans, edited exports — possibly the only surviving copy. Human eye.
      if    ($sz >= 2097152) { ($tier,$cat,$why)=("review","images","large, no EXIF, $d"); }
      elsif ($sz >= 51200)   { ($tier,$cat,$why)=("review","image_derivatives","no EXIF, $d"); }
      else                   { ($tier,$cat,$why)=("junk","image_cache","no EXIF, small, $d"); }
    }
  }
}
elsif ($ext eq "png") {
  my $b = peek($f, 24);
  my ($w, $h) = (length($b) >= 24) ? unpack("NN", substr($b, 16, 8)) : (0, 0);
  my $ok = ($w >= 1 && $h >= 1 && $w <= 20000 && $h <= 20000);
  my $min = $w < $h ? $w : $h;
  # >=500KB separates user screenshots/scans from OS resources at equal dims
  if    ($ok && $sz >= 512000) { ($tier,$cat,$why)=("user_data","screenshots","${w}x${h} screenshot/scan"); }
  elsif (!$ok)                 { ($tier,$cat,$why) = $sz >= 512000
                                   ? ("review","images","undecodable png header")
                                   : ("junk","system_images","corrupt png header"); }
  elsif ($min >= 600)          { ($tier,$cat,$why)=("review","images","${w}x${h}"); }
  else                         { ($tier,$cat,$why)=("junk","system_images","${w}x${h} UI asset"); }
}
elsif ($ext =~ /^(tif|tiff)$/) {
  if ($sz < 32768) { ($tier,$cat,$why)=("junk","system_images","small tiff"); }
  else {
    my $b = peek($f, 65536);
    my $mk = camera_make($b);
    my ($w, $h) = tiff_dims($b);
    my $max = $w > $h ? $w : $h; my $min = $w < $h ? $w : $h;
    if    ($mk)        { ($tier,$cat,$why)=("user_data","photos","camera EXIF: $mk"); }
    elsif ($min >= 960){ ($tier,$cat,$why)=("review","images","${w}x${h} tiff"); }
    elsif ($sz >= 1048576 && $max && $max < 256)
                       { ($tier,$cat,$why)=("junk","system_images","icon tiff (over-carve, ${w}x${h})"); }
    elsif ($sz >= 1048576)
                       { ($tier,$cat,$why)=("review","images","large tiff"); }
    else               { ($tier,$cat,$why)=("junk","system_images","small tiff"); }
  }
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
elsif ($ext eq "plist") {
  # real prefs are KB-scale; multi-MB "plists" are signature misfires
  # carving encrypted-region noise or over-carve overruns
  ($tier,$cat,$why) = $sz >= 2097152
    ? ("junk","carve_noise","oversized plist (carve overrun/encrypted noise)")
    : ("junk","plists","preferences/config");
}
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
echo "[$(ts)] start with:   user_data/photos, user_data/screenshots, user_data/documents, user_data/databases"
echo "[$(ts)] then skim:    review/image_derivatives (EXIF-less renditions — often real photos),"
echo "[$(ts)]               review/images, review/truncated_media, review/text, review/archives"
