#!/usr/bin/env bash
#
# Build and install the egis0575 driver into a private prefix.
#
# This does NOT replace your system libfprint and does NOT install anything
# system-wide. Everything lands in $PREFIX (default ~/.local/share/eh575).
#
# What you get: a working fingerprint image capture tool.
# What you do NOT get: fingerprint login. The driver has no enroll/verify
# implementation, so this cannot be used for authentication.
#
set -euo pipefail

PREFIX="${PREFIX:-$HOME/.local/share/eh575}"
SRC="${SRC:-$HOME/.cache/eh575-build/libfprint}"
JOBS="$(nproc 2>/dev/null || echo 4)"
REPO_URL="https://github.com/TheWildJames/eh575-fingerprint-driver.git"

say()  { printf '\033[1;34m==>\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m warn:\033[0m %s\n' "$*"; }
die()  { printf '\033[1;31merror:\033[0m %s\n' "$*" >&2; exit 1; }

# ---------------------------------------------------------------- deps
# Check what actually matters - whether pkg-config can resolve each library -
# rather than guessing distro package names, which differ between Arch and
# Debian and were wrong often enough to be worth avoiding.
say "Checking build dependencies"
NEEDED_PC=(gusb gio-unix-2.0 gobject-2.0 glib-2.0 cairo pixman-1 json-glib-1.0)
MISSING_PC=()
MISSING_BIN=()
for m in meson ninja gcc git curl tar; do
  command -v "$m" &>/dev/null || MISSING_BIN+=("$m")
done
for p in "${NEEDED_PC[@]}"; do
  pkg-config --exists "$p" 2>/dev/null || MISSING_PC+=("$p")
done

if [ ${#MISSING_BIN[@]} -gt 0 ] || [ ${#MISSING_PC[@]} -gt 0 ]; then
  [ ${#MISSING_BIN[@]} -gt 0 ] && warn "missing programs: ${MISSING_BIN[*]}"
  [ ${#MISSING_PC[@]} -gt 0 ] && warn "missing pkg-config modules: ${MISSING_PC[*]}"
  warn ""
  warn "On Arch/CachyOS the usual culprits are:"
  warn "  sudo pacman -S base-devel meson ninja glib2 libgusb pixman cairo json-glib"
  warn ""
  warn "This script will not install packages for you."
  read -r -p "Continue anyway and try to build? [y/N] " a
  [[ "$a" == [yY] ]] || die "aborted"
fi

# ------------------------------------------------------- gusb fallback
# libgusb is sometimes missing its .pc entry on Arch (a glib2 packaging bug:
# glib-2.0.pc points at /usr/bin/glib-mkenums, which glib2-devel owns).
# Detect it and build libgusb into the prefix if needed.
if ! pkg-config --exists gusb 2>/dev/null; then
  if ! command -v meson &>/dev/null; then
    die "libgusb is not visible to pkg-config and meson is unavailable to build it.
     On Arch/CachyOS:  sudo pacman -S meson libgusb"
  fi
  say "libgusb not found via pkg-config, building it into the prefix"
  GUSB_SRC="$HOME/.cache/eh575-build/libgusb-0.4.9"
  if [ ! -d "$GUSB_SRC" ]; then
    mkdir -p "$(dirname "$GUSB_SRC")"
    curl -fsSL -o /tmp/libgusb-0.4.9.tar.xz \
      https://github.com/hughsie/libgusb/releases/download/0.4.9/libgusb-0.4.9.tar.xz \
      || die "could not download libgusb"
    tar xf /tmp/libgusb-0.4.9.tar.xz -C "$(dirname "$GUSB_SRC")"
  fi
  say "configuring libgusb"
  meson setup "$GUSB_SRC/build" "$GUSB_SRC" --prefix="$PREFIX" \
      --buildtype=release -D docs=false -D introspection=false -D vapi=false \
      || die "libgusb configure failed (run without the redirect to see why)"
  ninja -C "$GUSB_SRC/build" || die "libgusb build failed"
  ninja -C "$GUSB_SRC/build" install || die "libgusb install failed"
  export PKG_CONFIG_PATH="$PREFIX/lib/pkgconfig${PKG_CONFIG_PATH:+:$PKG_CONFIG_PATH}"
  export LD_LIBRARY_PATH="$PREFIX/lib${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}"
  pkg-config --exists gusb || die "libgusb still not visible after install"
  say "libgusb installed into prefix"
fi

# ------------------------------------------------------------ meson
MESON_VERSION=$(meson --version 2>/dev/null || echo 0)
if ! meson --version >/dev/null 2>&1 || \
   [ "$(printf '%s\n1.2.0\n' "$MESON_VERSION" | sort -V | head -1)" != "1.2.0" ]; then
  say "meson too old or missing ($MESON_VERSION), libfprint needs >= 0.62"
  warn "install a current meson, e.g. from your distro, then re-run"
  die "cannot continue without a suitable meson"
fi

# ------------------------------------------------------- libfprint
if [ ! -d "$SRC/.git" ]; then
  say "Cloning libfprint"
  mkdir -p "$(dirname "$SRC")"
  git clone --filter=blob:none https://gitlab.freedesktop.org/libfprint/libfprint.git "$SRC"
else
  say "Updating existing libfprint checkout"
  git -C "$SRC" fetch -q origin
  git -C "$SRC" reset -q --hard origin/master
fi
say "libfprint at $(git -C "$SRC" rev-parse --short HEAD)"

PATCH_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/patches"
say "Applying egis0575 driver"
git -C "$SRC" apply "$PATCH_DIR/0001-add-egis0575-driver.patch" \
  || die "patch did not apply. libfprint master may have changed; see the repo README."

say "Configuring (egis0575 only; avoids the SPI drivers' gudev dependency)"
rm -rf "$SRC/build" "$SRC/build-local"
meson setup "$SRC/build-local" "$SRC" \
  --prefix="$PREFIX" \
  --buildtype=release \
  -D doc=false \
  -D introspection=false \
  -D drivers=egis0575 \
  -D udev_rules=disabled \
  -D udev_hwdb=disabled \
  || die "configure failed"

say "Building with $JOBS jobs (this takes a minute)"
ninja -C "$SRC/build-local" -j "$JOBS" || die "build failed"

say "Installing into $PREFIX"
ninja -C "$SRC/build-local" install >/dev/null || die "install failed"

# ------------------------------------------------------------ tools
say "Building the test tools"
PCDIR=$(dirname "$(find "$PREFIX" -name 'libfprint-2.pc' -print -quit)")
test -d "$PCDIR" || die "libfprint-2.pc not found under $PREFIX"
LIBDIR=$(dirname "$PCDIR")
export PKG_CONFIG_PATH="$PCDIR${PKG_CONFIG_PATH:+:$PKG_CONFIG_PATH}"
export LD_LIBRARY_PATH="$LIBDIR${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}"

GUSBC=$(pkg-config --cflags gusb)
CFLAGS="-I$PREFIX/include -I$PREFIX/include/libfprint-2 $GUSBC \
        $(pkg-config --cflags gio-unix-2.0 gobject-2.0 glib-2.0 json-glib-1.0)"
LIBS="$(pkg-config --libs libfprint-2 gusb gio-unix-2.0)"

TOOLDIR="$PREFIX/bin"
mkdir -p "$TOOLDIR"
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
for src in fptest2.c probe2.c probe3.c monitor.c; do
  [ -f "$HERE/tools/$src" ] || continue
  gcc -O1 -o "$TOOLDIR/${src%.c}" "$HERE/tools/$src" $CFLAGS $LIBS \
    || die "failed to build $src"
done

cat > "$TOOLDIR/eh575-env.sh" <<EOF
# Source this to use the tools:  source $TOOLDIR/eh575-env.sh
export LD_LIBRARY_PATH="$LIBDIR\${LD_LIBRARY_PATH:+:\$LD_LIBRARY_PATH}"
export PKG_CONFIG_PATH="$PCDIR\${PKG_CONFIG_PATH:+:\$PKG_CONFIG_PATH}"
export EGIS0575_FINGER_THRESHOLD="\${EGIS0575_FINGER_THRESHOLD:-0x03}"
EOF

# --------------------------------------------------------- verify
say "Verifying"
LIB=$(find "$PREFIX" -name 'libfprint-2.so.2.*' -type f -print -quit)
strings "$LIB" | grep -q 'fpi_device_egis0575_get_type' \
  || die "driver GType missing from $LIB"
echo "  driver is present in the built library"

cat <<EOF

$(say "Done.")

  Prefix:  $PREFIX

  Next steps:

    1. Grant USB access (temporary, cleared on reboot):
         sudo setfacl -m u:\$USER:rw /dev/bus/usb/XXX/YYY
       Find XXX/YYY with:
         lsusb -d 1c7a:0575
         lsusb -t | grep -A2 1c7a

    2. Test it:
         source $TOOLDIR/eh575-env.sh
         fptest open
         fptest capture /tmp/finger.pgm

       The tool binaries are: fptest, probe, probe3, monitor

$(warn "This gives you image CAPTURE only.")
$(warn "The driver has no enroll/verify implementation, so this cannot")
$(warn "be used for fingerprint login. See the repo README.")

EOF
