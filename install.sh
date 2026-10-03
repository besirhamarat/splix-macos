#!/bin/bash
#
#  SpliX for macOS — Xerox Phaser 3140 / 3155
#
#  Builds SpliX's open-source `rastertoqpdl` CUPS filter from upstream source
#  and installs it with the matching PPD, so these printers work on modern
#  macOS where no vendor driver is available.
#
#  Usage:
#      bash install.sh                    auto-detect a Phaser 3140/3155
#      bash install.sh --list             list the SpliX PPDs this build can drive
#      bash install.sh --ppd ml1910       use another SpliX PPD (untested models)
#      bash install.sh --uri <device-uri> give the device URI explicitly
#      bash install.sh --queue <name>     choose the print queue name
#      bash install.sh --uninstall        remove the filter
#
#  Requirements: Xcode Command Line Tools (or Xcode). Nothing else.
#
#  License: GPL-2.0-only, the same as SpliX itself (see LICENSE).
#

set -u

REPO="https://github.com/OpenPrinting/splix"
# The upstream revision the patches were written and tested against.
SPLIX_COMMIT="4854286334346059e7fec6f5f2328a23fa5fa774"

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WORK="${SPLIX_MACOS_WORK:-$HOME/Library/Caches/splix-macos}"
SRCDIR="$WORK/splix"
FILTER_DIR="/usr/libexec/cups/filter"
PPD_DIR="/Library/Printers/PPDs/Contents/Resources"

G=$'\033[1;32m'; R=$'\033[1;31m'; Y=$'\033[1;33m'; B=$'\033[1m'; O=$'\033[0m'
ok(){   printf "%s  ok  %s%s\n" "$G" "$*" "$O"; }
bad(){  printf "%s  !!  %s%s\n" "$R" "$*" "$O" >&2; }
warn(){ printf "%s  ..  %s%s\n" "$Y" "$*" "$O"; }
step(){ printf "\n%s==  %s  ==%s\n" "$B" "$*" "$O"; }
die(){  bad "$*"; exit 1; }

# In-place substitution that behaves the same with BSD and GNU sed.
subst(){ sed "$1" "$2" > "$2.tmp" && mv "$2.tmp" "$2"; }

# cupsCompression 19 (0x13) and 21 (0x15) are the JBIG algorithms, which this
# build leaves out.
needs_jbig(){ grep -qE 'cupsCompression (19|21)([^0-9]|$)' "$1"; }

URI=""; PPD=""; QUEUE=""; ACTION="install"

while [ $# -gt 0 ]; do
  case "$1" in
    --uri)       URI="${2:-}";   shift 2 ;;
    --ppd)       PPD="${2:-}";   shift 2 ;;
    --queue)     QUEUE="${2:-}"; shift 2 ;;
    --list)      ACTION="list";      shift ;;
    --uninstall) ACTION="uninstall"; shift ;;
    -h|--help)   sed -n '2,20p' "$0" | sed 's/^# \{0,2\}//'; exit 0 ;;
    *) die "Unknown option: $1  (try --help)" ;;
  esac
done

# ── uninstall ───────────────────────────────────────────────────────────────
if [ "$ACTION" = "uninstall" ]; then
  step "Uninstalling"
  sudo rm -f "$FILTER_DIR/rastertoqpdl" && ok "removed $FILTER_DIR/rastertoqpdl"
  echo "PPDs in $PPD_DIR were left in place; delete them by hand if you like."
  echo "Remove the print queue in System Settings > Printers & Scanners."
  exit 0
fi

# ── source ──────────────────────────────────────────────────────────────────
fetch_source(){
  command -v git >/dev/null 2>&1 || die "git not found (it ships with the Xcode Command Line Tools)."
  mkdir -p "$WORK" || die "Cannot create $WORK"
  if [ ! -d "$SRCDIR/.git" ]; then
    git init -q "$SRCDIR" || die "git init failed"
    git -C "$SRCDIR" remote add origin "$REPO"
  fi
  if ! git -C "$SRCDIR" cat-file -e "$SPLIX_COMMIT^{commit}" 2>/dev/null; then
    echo "  Fetching SpliX ${SPLIX_COMMIT:0:12} ..."
    git -C "$SRCDIR" fetch -q --depth 1 origin "$SPLIX_COMMIT" || die "Download failed."
  fi
  # Always start from the pristine upstream tree so the patches apply cleanly.
  git -C "$SRCDIR" reset -q --hard "$SPLIX_COMMIT" || die "Cannot check out $SPLIX_COMMIT"
  git -C "$SRCDIR" clean -qfdx
}

# ── list ────────────────────────────────────────────────────────────────────
if [ "$ACTION" = "list" ]; then
  fetch_source
  echo "SpliX PPDs this build can drive (no JBIG required). Only the Phaser"
  echo "3140 has been tested; pass the name in the first column to --ppd."
  echo
  for f in "$SRCDIR"/ppd/*.ppd; do
    case "$f" in *fr.ppd|*pt.ppd) continue ;; esac
    needs_jbig "$f" && continue
    printf "  %-14s %s\n" "$(basename "$f" .ppd)" \
      "$(grep -m1 '^\*ModelName:' "$f" | cut -d'"' -f2)"
  done
  exit 0
fi

# ── 1. toolchain ────────────────────────────────────────────────────────────
step "1/6  Toolchain"

xcode-select -p >/dev/null 2>&1 || {
  warn "Xcode Command Line Tools are missing; opening Apple's installer."
  xcode-select --install 2>/dev/null
  die "Finish that installation, then run this script again."
}
ok "Xcode Command Line Tools"

# An unaccepted Xcode licence makes clang stop at an interactive prompt.
if xcrun --sdk macosx --show-sdk-path 2>&1 </dev/null | grep -qi 'license'; then
  bad "The Xcode licence has not been accepted."
  echo "      Run:  sudo xcodebuild -license accept"
  echo "      then run this script again."
  exit 1
fi

SDK="$(xcrun --sdk macosx --show-sdk-path 2>/dev/null </dev/null)"
[ -n "${SDK:-}" ] && [ -d "$SDK" ] || SDK=""
if [ -z "$SDK" ]; then
  for c in /Library/Developer/CommandLineTools/SDKs/MacOSX*.sdk \
           /Applications/Xcode.app/Contents/Developer/Platforms/MacOSX.platform/Developer/SDKs/MacOSX*.sdk; do
    [ -d "$c" ] && { SDK="$c"; break; }
  done
fi
SYSROOT=""; [ -n "$SDK" ] && { SYSROOT="-isysroot $SDK"; ok "SDK: $SDK"; }

TMPD="$(mktemp -d)"
cat > "$TMPD/probe.c" <<'PROBE'
#include <cups/raster.h>
int main(void){ cups_raster_t *r = cupsRasterOpen(0, CUPS_RASTER_READ); (void)r; return 0; }
PROBE
clang $SYSROOT -o "$TMPD/probe" "$TMPD/probe.c" -lcups -lcupsimage 2>"$TMPD/log" </dev/null \
  || { bad "Cannot compile against CUPS:"; sed 's/^/      /' "$TMPD/log" >&2; exit 1; }
rm -rf "$TMPD"
ok "cups/raster.h + libcupsimage usable"

# ── 2. source ───────────────────────────────────────────────────────────────
step "2/6  SpliX source"
fetch_source
cd "$SRCDIR" || die "Cannot enter $SRCDIR"
ok "SpliX ${SPLIX_COMMIT:0:12}"

# ── 3. printer + ppd ────────────────────────────────────────────────────────
step "3/6  Printer and PPD"

if [ -z "$URI" ]; then
  echo "  Looking for the printer (sudo may ask for your password)..."
  URI="$(sudo lpinfo -v 2>/dev/null | awk '/usb:|socket:|dnssd:|ipp:/{print $2}' \
        | grep -iE 'phaser.*(3140|3155)' | head -1)"
fi
[ -n "$URI" ] || die "No Phaser 3140/3155 found. Check that it is switched on and
      connected, then run again — or pass the address yourself:
          bash install.sh --uri '<device-uri>'
      'sudo lpinfo -v' lists the addresses macOS can see."
ok "Device URI: $URI"

if [ -z "$PPD" ]; then
  # Both models announce themselves over USB as "Phaser 3140 and 3155", and
  # their PPDs are identical apart from the name.
  case "$(printf '%s' "$URI" | tr 'A-Z' 'a-z')" in
    *3140*) PPD="ph3140" ;;
    *3155*) PPD="ph3155" ;;
    *) die "Cannot tell the model from the URI; choose a PPD with --ppd
      (see 'bash install.sh --list')." ;;
  esac
fi
case "$PPD" in
  /*)     PPDFILE="$PPD" ;;
  *.ppd)  PPDFILE="$SRCDIR/ppd/$(basename "$PPD")" ;;
  *)      PPDFILE="$SRCDIR/ppd/$PPD.ppd" ;;
esac
[ -f "$PPDFILE" ] || die "PPD not found: $PPDFILE  (see 'bash install.sh --list')"
needs_jbig "$PPDFILE" && die "$(basename "$PPDFILE") needs JBIG compression, which this build leaves out."
ok "PPD: $(basename "$PPDFILE")  ($(grep -m1 '^\*ModelName:' "$PPDFILE" | cut -d'"' -f2))"

[ -n "$QUEUE" ] || QUEUE="$(grep -m1 '^\*ModelName:' "$PPDFILE" | cut -d'"' -f2 | sed 's/[^A-Za-z0-9]/_/g')"
[ -n "$QUEUE" ] || QUEUE="SpliX_printer"
ok "Queue name: $QUEUE"

# ── 4. patches ──────────────────────────────────────────────────────────────
step "4/6  macOS patches"

# (1) Temporary files: honour TMPDIR instead of a hard-coded /tmp, which the
#     CUPS sandbox on macOS does not let a filter write to.
patch -p1 -s --forward < "$HERE/patches/0001-cache-honour-TMPDIR.patch" \
  || die "patch 0001 did not apply"
ok "0001  cache: honour TMPDIR"

# (2) include/semaphore.h shadows the system <semaphore.h> for everything
#     compiled with -Iinclude. Give SpliX's class header a unique name.
mv include/semaphore.h include/splixsem.h || die "rename failed"
for f in $(grep -rl '#include "semaphore.h"' src include); do
  subst 's|#include "semaphore.h"|#include "splixsem.h"|' "$f"
done
ok "0002  semaphore.h -> splixsem.h"

# (3) JBIG is compiled out (-DDISABLE_JBIG), which removes the only external
#     library. The selected PPD was checked above not to need it.
ok "0003  JBIG compiled out"

# ── 5. build ────────────────────────────────────────────────────────────────
step "5/6  Build"

SRC="src/rastertoqpdl.cpp src/request.cpp src/printer.cpp src/qpdl.cpp
     src/document.cpp src/core.cpp src/compress.cpp src/algorithm.cpp
     src/ppdfile.cpp src/page.cpp src/colors.cpp src/band.cpp
     src/bandplane.cpp src/cache.cpp src/rendering.cpp src/semaphore.cpp
     src/algo0x0d.cpp src/algo0x0e.cpp src/algo0x11.cpp src/algo0x13.cpp
     src/algo0x15.cpp"

clang++ -w -std=gnu++14 -o "$WORK/rastertoqpdl" $SRC \
  -DDISABLE_JBIG -DTHREADS=2 -DCACHESIZE=30 \
  -Iinclude -I. $SYSROOT -lcups -lcupsimage -lz -lpthread </dev/null \
  || die "Build failed."
ok "built: $WORK/rastertoqpdl"
file "$WORK/rastertoqpdl" 2>/dev/null | sed 's/^/      /'

# ── 6. install ──────────────────────────────────────────────────────────────
step "6/6  Install (sudo)"

sudo cp "$WORK/rastertoqpdl" "$FILTER_DIR/rastertoqpdl" || die "Cannot install the filter."
sudo chown root:wheel "$FILTER_DIR/rastertoqpdl"
sudo chmod 755        "$FILTER_DIR/rastertoqpdl"
ok "$FILTER_DIR/rastertoqpdl"

sudo mkdir -p "$PPD_DIR"
sudo cp "$PPDFILE" "$PPD_DIR/" || die "Cannot install the PPD."
ok "$PPD_DIR/$(basename "$PPDFILE")"

sudo lpadmin -p "$QUEUE" -E -v "$URI" -P "$PPD_DIR/$(basename "$PPDFILE")" \
     -o printer-is-shared=false || die "lpadmin failed."
ok "queue '$QUEUE' added"

printf "\n%sDone.%s  Print a test page from any application.\n\n" "$G$B" "$O"
echo "A major macOS update can remove the filter. To put it back, re-run this"
echo "script, or copy the cached binary:"
echo "    sudo cp \"$WORK/rastertoqpdl\" $FILTER_DIR/"
