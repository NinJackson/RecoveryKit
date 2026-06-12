#!/bin/bash
# NAME: Rescue real photos from junk tier (re-screen)
# DESC: Re-screens images an earlier triage filed as junk/image_cache — EXIF-stripped PhotoStream renditions, X-rays/scans, edited exports hide there — by decoding pixel dimensions, and hardlinks candidates into DEST/triage/rescued/<bucket>/ for a fast human eyeball. Originals untouched; nothing leaves junk/. Use after a classifier upgrade or for an extra-careful delivery. Writes DEST/LABEL.rescue.tsv.
# REQUIRES_ROOT: no
#
# Buckets (checked in order):
#   phone_screen  exact phone/tablet screen dims  -> screenshots of records etc.
#   hires         min side >= 1800 px             -> X-rays/scans AND modern
#                 camera-resolution photos (no decode-only signal separates them)
#   camera        >= 1.0 megapixel, min side <1800 -> older camera dims
#   derivative    >= 50 KB, smaller dims          -> PhotoStream/Photos renditions
#   thumbs        < 50 KB, photo-shaped           -> only with --thumbs (bulky, low value)
#
# Reads the triage TSV (rows: path<TAB>tier<TAB>category<TAB>reason<TAB>size)
# to find junk image_cache rows; falls back to scanning triage/junk/image_cache
# (force the scan with --scan, e.g. when carved/ was purged after triage —
# the TSV records carved/ paths, which would all be missing).

set -u
DEST=""; LABEL=""; TSVIN=""; THUMBS=0; SCAN=0
while [ $# -gt 0 ]; do case "$1" in
  --dest)   [ $# -ge 2 ] || { echo "--dest requires a path"; exit 2; }; DEST="$2"; shift 2;;
  --label)  [ $# -ge 2 ] || { echo "--label requires a name"; exit 2; }; LABEL="$2"; shift 2;;
  --tsv)    [ $# -ge 2 ] || { echo "--tsv requires a path"; exit 2; }; TSVIN="$2"; shift 2;;
  --thumbs) THUMBS=1; shift;;
  --scan)   SCAN=1; shift;;
  *) shift;;   # tolerate args meant for other methods
esac; done
[ -n "$DEST" ] && [ -n "$LABEL" ] || { echo "need --dest and --label"; exit 2; }

TSVIN="${TSVIN:-$DEST/$LABEL.triage.tsv}"
RESCUED="$DEST/triage/rescued"
OUT_TSV="$DEST/$LABEL.rescue.tsv"
LOGF="$DEST/$LABEL.rescue.log"

RLOCK="$DEST/$LABEL.rescue.lock"
if ! mkdir "$RLOCK" 2>/dev/null; then
  if [ ! -f "$RLOCK/pid" ]; then sleep 2; fi   # owner may be between mkdir and pid-write
  if [ -f "$RLOCK/pid" ] && kill -0 "$(cat "$RLOCK/pid" 2>/dev/null)" 2>/dev/null; then
    echo "another rescue for label '$LABEL' is active (pid $(cat "$RLOCK/pid"))"; exit 1
  fi
  rm -rf "$RLOCK"; mkdir "$RLOCK" || exit 1
fi
echo $$ > "$RLOCK/pid"

exec > >(tee -a "$LOGF") 2>&1
ts() { date '+%F %T'; }
caffeinate -dims & CAF=$!
trap 'kill $CAF 2>/dev/null; wait $CAF 2>/dev/null; rm -rf "$RLOCK"' EXIT

mkdir -p "$RESCUED"
: > "$OUT_TSV"

# Candidate list: TSV junk/image_cache rows (NUL-separated for safety),
# else a directory scan of the junk tree.
list_candidates() {
  if [ "$SCAN" -eq 0 ] && [ -f "$TSVIN" ]; then
    echo "[$(ts)] candidates from TSV: $TSVIN" >&2
    # perl, not awk: BSD awk cannot reliably print NUL separators
    /usr/bin/perl -ne 'chomp; my @c = split /\t/, $_, 4;
      print "$c[0]\0" if @c >= 3 && $c[1] eq "junk" && $c[2] eq "image_cache";' "$TSVIN"
  else
    echo "[$(ts)] scanning $DEST/triage/junk/image_cache" >&2
    find "$DEST/triage/junk/image_cache" -type f -print0 2>/dev/null
  fi
}

echo "[$(ts)] rescue re-screen -> $RESCUED  (thumbs: $THUMBS)"
list_candidates | /usr/bin/perl -0 -ne '
BEGIN {
  use File::Path qw(make_path); use File::Copy qw(copy);
  ($RESCUED, $OUT, $THUMBS) = @ARGV; @ARGV = ();
  open($out, ">>", $OUT) or die "tsv: $!";
  # phone/tablet screen dims, normalized min x max
  %SCREEN = map { $_ => 1 } qw(
    640x960 640x1136 750x1334 828x1792 1080x1920 1080x2340 1125x2436
    1170x2532 1179x2556 1242x2208 1242x2688 1284x2778 1290x2796
    768x1024 1536x2048 1620x2160 1640x2360 1668x2224 1668x2388 2048x2732
  );
  $n = 0; $kept = 0; $miss = 0;
}
sub peek { my ($f, $len) = @_; my $b = ""; if (open(my $fh, "<", $f)) { read($fh, $b, $len); close $fh; } return $b; }
sub jpeg_dims {
  my ($b) = @_; my $L = length($b);
  return (0, 0) unless $L >= 4 && substr($b, 0, 2) eq "\xFF\xD8";
  my $i = 2;
  while ($i + 9 <= $L) {
    last if substr($b, $i, 1) ne "\xFF";
    my $m = ord(substr($b, $i + 1, 1));
    if ($m == 0xFF) { $i++; next; }
    if ($m == 0x01 || ($m >= 0xD0 && $m <= 0xD8)) { $i += 2; next; }
    last if $m == 0xD9 || $m == 0xDA;
    my $len = unpack("n", substr($b, $i + 2, 2)) // 0;
    last if $len < 2;
    if ($m >= 0xC0 && $m <= 0xCF && $m != 0xC4 && $m != 0xC8 && $m != 0xCC) {
      return (unpack("n", substr($b, $i + 7, 2)) // 0, unpack("n", substr($b, $i + 5, 2)) // 0);
    }
    $i += 2 + $len;
  }
  return (0, 0);
}
chomp; my $f = $_;
unless (-f $f) { $miss++; next; }
my $sz = (lstat($f))[7] // 0;
$n++; print STDERR "[progress] $n screened, $kept rescued\n" if $n % 5000 == 0;

my ($w, $h) = (0, 0);
if ($f =~ /\.jpe?g$/i) { ($w, $h) = jpeg_dims(peek($f, 65536)); }
elsif ($f =~ /\.png$/i) {
  my $b = peek($f, 24);
  ($w, $h) = (length($b) >= 24) ? unpack("NN", substr($b, 16, 8)) : (0, 0);
  ($w, $h) = (0, 0) if $w > 20000 || $h > 20000;
}
my $min = $w < $h ? $w : $h;
my $max = $w > $h ? $w : $h;

my $bucket = "";
if    ($min && $SCREEN{"${min}x${max}"})            { $bucket = "phone_screen"; }
elsif ($min >= 1800)                                { $bucket = "hires"; }
elsif ($w * $h >= 1000000)                          { $bucket = "camera"; }
elsif ($sz >= 51200)                                { $bucket = "derivative"; }
elsif ($THUMBS && $min >= 100 && $max && $min / $max >= 0.4) { $bucket = "thumbs"; }
next unless $bucket;

my ($parent) = $f =~ m{([^/]+)/[^/]+$};
my ($base)   = $f =~ m{([^/]+)$};
my $dir = "$RESCUED/$bucket";
make_path($dir) unless -d $dir;
my $t = "$dir/${parent}_$base";
my $i = 0;
while (-e $t && (lstat($t))[7] != $sz) { $i++; $t = "$dir/${i}_${parent}_$base"; }
unless (-e $t) {
  unless (link($f, $t) or (copy($f, "$t.part") and rename("$t.part", $t))) {
    print STDERR "[err] rescue copy failed: $f: $!\n"; unlink("$t.part"); next;
  }
}
$kept++;
print $out join("\t", $f, $bucket, ($w && $h ? "${w}x${h}" : "dims unknown"), $sz), "\n";
END {
  close $out;
  print STDERR "[done] $n screened, $kept rescued" . ($miss ? ", $miss MISSING" : "") . "\n";
  if ($miss && $miss >= $n) {
    print STDERR "[warn] every TSV path was missing — carved/ may have been purged.\n";
    print STDERR "[warn] re-run with --scan to screen triage/junk/image_cache directly.\n";
  }
}
' "$RESCUED" "$OUT_TSV" "$THUMBS"

echo
echo "================ RESCUE SUMMARY =================="
awk -F'\t' '
  { n[$2]++; b[$2] += $4 }
  END { for (k in n) printf "%-14s %8d files  %8.2f GB\n", k, n[k], b[k]/1e9 }
' "$OUT_TSV" | sort
echo "=================================================="
echo "[$(ts)] eyeball the buckets in: $RESCUED"
echo "[$(ts)] keepers: move (or re-link) into $DEST/triage/user_data/<category>/"
echo "[$(ts)]          — the delivery packager ships triage/user_data/ wholesale"
echo "[$(ts)] report:  $OUT_TSV"
