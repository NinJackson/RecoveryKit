#!/bin/bash
# NAME: Deduplicate recovered output
# DESC: Finds byte-identical files in DEST/triage/user_data (or --in <dir>) and MOVES duplicates to DEST/duplicates/, keeping one copy in place. Hardlink-aware (same inode is one file, never touched). Nothing is deleted; carve originals in recovered.N/ are never modified.
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
INDIR="${INDIR:-$DEST/triage/user_data}"
[ -d "$INDIR" ] || { echo "input dir not found: $INDIR (run triage first, or pass --in)"; exit 1; }

DUPDIR="$DEST/duplicates"
LOGF="$DEST/$LABEL.dedupe.log"
exec > >(tee -a "$LOGF") 2>&1
ts() { date '+%F %T'; }
echo "[$(ts)] dedupe of $INDIR (duplicates moved to $DUPDIR)"
caffeinate -dims & CAF=$!
trap 'kill $CAF 2>/dev/null' EXIT
mkdir -p "$DUPDIR"

# Perl: group by size, hash only same-size groups (SHA-256 via shasum),
# treat same-inode entries as one file, move later content-twins out.
find "$INDIR" -type f -print0 2>/dev/null | /usr/bin/perl -0 -ne '
BEGIN { ($DUP, $IN) = @ARGV; @ARGV = (); $n = 0; $moved = 0; $bytes = 0; }
chomp; my @st = lstat($_) or next;
push @{ $bysize{$st[7]} }, [$_, "$st[0]:$st[1]"] if $st[7] > 0;
END {
  for my $sz (keys %bysize) {
    my @g = @{ $bysize{$sz} };
    next if @g < 2;
    my (%seen_inode, %byhash);
    for my $e (@g) {
      next if $seen_inode{$e->[1]}++;        # hardlinks of one inode = one file
      my $out = `shasum -a 256 \Q$e->[0]\E 2>/dev/null`;
      my ($h) = $out =~ /^([0-9a-f]{64})/ or next;
      push @{ $byhash{$h} }, $e->[0];
    }
    for my $h (keys %byhash) {
      my @files = @{ $byhash{$h} };
      next if @files < 2;
      shift @files;                          # keep the first occurrence in place
      for my $f (@files) {
        (my $rel = $f) =~ s/^\Q$IN\E\/?//;
        $rel =~ s{/}{_}g;
        my $t = "$DUP/$rel"; my $i = 0;
        while (-e $t) { $i++; $t = "$DUP/$i.$rel"; }
        if (rename($f, $t)) { $moved++; $bytes += $sz; print "dup: $f\n"; }
      }
    }
  }
  printf STDERR "[done] %d duplicate file(s) moved, %.2f GB reclaimed from the delivery set\n", $moved, $bytes / 1e9;
}
' "$DUPDIR" "$INDIR"
echo "[$(ts)] dedupe complete — review $DUPDIR before discarding anything"
