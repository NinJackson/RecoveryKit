#!/bin/bash
# Install RecoveryKit's optional third-party command-line tools into tools/bin.
# Bash 3.2-safe for macOS 10.14.6.

set -u
set -o pipefail

TOOLS_DIR="$(cd "$(dirname "$0")" && pwd)"
BIN="$TOOLS_DIR/bin"
CACHE="$TOOLS_DIR/cache"
DDRESCUE_VERSION="${DDRESCUE_VERSION:-1.30}"
DDRESCUE_URL="${DDRESCUE_URL:-https://ftp.gnu.org/gnu/ddrescue/ddrescue-${DDRESCUE_VERSION}.tar.lz}"
TESTDISK_VERSION="${TESTDISK_VERSION:-7.2}"
TESTDISK_URL="${TESTDISK_URL:-https://www.cgsecurity.org/Download_and_donate.php/testdisk-${TESTDISK_VERSION}.mac_intel_x86_64.tar.bz2}"

mkdir -p "$BIN" "$CACHE"

ts() { date '+%F %T'; }
log() { echo "[$(ts)] deps: $*"; }
die() { log "FATAL: $*"; exit 1; }

usage() {
  cat <<EOF
Usage: bash tools/install_dependencies.sh [--all] [--require TOOL...]

Tools:
  ddrescue      installs ddrescue and ddrescuelog
  photorec      installs PhotoRec from TestDisk/PhotoRec

Environment overrides:
  DDRESCUE_URL, DDRESCUE_VERSION
  TESTDISK_URL, TESTDISK_VERSION
EOF
}

installed() { [ -x "$BIN/$1" ]; }

copy_from_path() {
  local name src
  name="$1"
  src=$(command -v "$name" 2>/dev/null || true)
  [ -n "$src" ] || return 1
  case "$src" in "$BIN/"*) return 0;; esac
  cp "$src" "$BIN/$name" && chmod 755 "$BIN/$name"
}

download() {
  local url out
  url="$1"; out="$2"
  log "downloading $url"
  if command -v curl >/dev/null 2>&1; then
    curl -fL --retry 3 --connect-timeout 20 "$url" -o "$out"
  elif command -v python >/dev/null 2>&1; then
    python - "$url" "$out" <<'PY'
import sys
try:
    from urllib.request import urlopen
except ImportError:
    from urllib2 import urlopen
url, out = sys.argv[1], sys.argv[2]
r = urlopen(url, timeout=60)
try:
    data = r.read()
finally:
    r.close()
f = open(out, "wb")
try:
    f.write(data)
finally:
    f.close()
PY
  else
    return 1
  fi
}

brew_cmd() {
  if command -v brew >/dev/null 2>&1; then
    command -v brew
    return 0
  fi
  [ -x /opt/homebrew/bin/brew ] && { echo /opt/homebrew/bin/brew; return 0; }
  [ -x /usr/local/bin/brew ] && { echo /usr/local/bin/brew; return 0; }
  return 1
}

run_brew() {
  local brew user
  brew=$(brew_cmd) || return 1
  user="${SUDO_USER:-}"
  if [ "$(id -u)" -eq 0 ] && [ -n "$user" ] && [ "$user" != "root" ]; then
    su -l "$user" -c "$(printf '%q ' "$brew" "$@")"
  else
    "$brew" "$@"
  fi
}

install_from_brew() {
  local formula tool
  formula="$1"; shift
  brew_cmd >/dev/null 2>&1 || return 1
  log "trying Homebrew formula: $formula"
  run_brew list "$formula" >/dev/null 2>&1 || run_brew install "$formula" || return 1
  for tool in "$@"; do
    copy_from_path "$tool" || return 1
  done
}

build_ddrescue_from_source() {
  local archive work src
  command -v lzip >/dev/null 2>&1 || return 1
  command -v make >/dev/null 2>&1 || return 1
  command -v clang++ >/dev/null 2>&1 || command -v c++ >/dev/null 2>&1 || return 1

  archive="$CACHE/ddrescue-${DDRESCUE_VERSION}.tar.lz"
  [ -f "$archive" ] || download "$DDRESCUE_URL" "$archive" || return 1

  work=$(mktemp -d "${TMPDIR:-/tmp}/rk_ddrescue.XXXXXX") || return 1
  ( cd "$work" &&
    lzip -dc "$archive" | tar -xf - &&
    src=$(find . -maxdepth 1 -type d -name 'ddrescue-*' | head -1) &&
    [ -n "$src" ] &&
    cd "$src" &&
    ./configure CXX="${CXX:-clang++}" CXXFLAGS="${CXXFLAGS:--O2}" LDFLAGS="${LDFLAGS:-}" &&
    make &&
    cp ddrescue ddrescuelog "$BIN/" &&
    chmod 755 "$BIN/ddrescue" "$BIN/ddrescuelog"
  )
  local rc=$?
  rm -rf "$work"
  return "$rc"
}

install_ddrescue() {
  if installed ddrescue && installed ddrescuelog; then
    log "ddrescue already bundled"
    return 0
  fi
  if copy_from_path ddrescue && copy_from_path ddrescuelog; then
    log "copied ddrescue/ddrescuelog from PATH"
    return 0
  fi
  if install_from_brew ddrescue ddrescue ddrescuelog; then
    log "installed ddrescue/ddrescuelog via Homebrew"
    return 0
  fi
  if build_ddrescue_from_source; then
    log "built ddrescue/ddrescuelog from GNU source"
    return 0
  fi
  die "could not install ddrescue. Install Xcode Command Line Tools plus lzip, or place ddrescue and ddrescuelog in $BIN"
}

install_rosetta_if_needed() {
  [ "$(uname -m)" = "arm64" ] || return 0
  /usr/bin/pgrep oahd >/dev/null 2>&1 && return 0
  [ -x /usr/sbin/softwareupdate ] || return 0
  log "installing Rosetta for Intel PhotoRec binary"
  /usr/sbin/softwareupdate --install-rosetta --agree-to-license >/dev/null 2>&1 || true
}

install_photorec_from_cgsecurity() {
  local archive work found
  archive="$CACHE/testdisk-${TESTDISK_VERSION}.mac_intel_x86_64.tar.bz2"
  [ -f "$archive" ] || download "$TESTDISK_URL" "$archive" || return 1

  work=$(mktemp -d "${TMPDIR:-/tmp}/rk_testdisk.XXXXXX") || return 1
  ( cd "$work" && tar -xjf "$archive" ) || { rm -rf "$work"; return 1; }
  found=$(find "$work" -type f \( -name photorec -o -name photorec_static \) | head -1)
  [ -n "$found" ] || { rm -rf "$work"; return 1; }
  cp "$found" "$BIN/photorec" && chmod 755 "$BIN/photorec"
  rm -rf "$work"
}

install_photorec() {
  if installed photorec; then
    log "photorec already bundled"
    return 0
  fi
  if copy_from_path photorec; then
    log "copied photorec from PATH"
    return 0
  fi
  if install_from_brew testdisk photorec; then
    log "installed photorec via Homebrew testdisk"
    return 0
  fi
  install_rosetta_if_needed
  if install_photorec_from_cgsecurity; then
    log "installed photorec from CGSecurity TestDisk/PhotoRec archive"
    return 0
  fi
  die "could not install photorec. Place photorec in $BIN or install the TestDisk/PhotoRec package manually"
}

[ $# -gt 0 ] || set -- --all
while [ $# -gt 0 ]; do
  case "$1" in
    --all) install_ddrescue; install_photorec; shift;;
    --require) shift; [ $# -gt 0 ] || die "--require needs at least one tool";;
    ddrescue) install_ddrescue; shift;;
    ddrescuelog) install_ddrescue; shift;;
    photorec) install_photorec; shift;;
    -h|--help) usage; exit 0;;
    *) die "unknown dependency: $1";;
  esac
done
