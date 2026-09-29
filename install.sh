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

# ------------------------------------------------- glib-mkenums shim
# Some distros ship a glib-2.0.pc that advertises glib_mkenums=/usr/bin/glib-mkenums
# even though the binary is not installed (it lives in the -dev/-devel package).
# meson then hard-fails with "tool variable 'glib_mkenums' contains erroneous
# value". Detect that and shim a working copy into the prefix, with a local
# .pc that points at it. Only done when the binary is genuinely absent.
ensure_mkenums() {
  if command -v glib-mkenums &>/dev/null; then
    say "glib-mkenums found in PATH"
    return 0
  fi
  MKENUM_PATH=$(pkg-config --variable=glib_mkenums glib-2.0 2>/dev/null || true)
  if [ -n "$MKENUM_PATH" ] && [ -x "$MKENUM_PATH" ]; then
    say "glib-mkenums present via pkg-config"
    return 0
  fi

  say "glib-mkenums missing (packaging gap); shimming it into the prefix"
  command -v curl &>/dev/null || die "curl is needed to fetch glib sources"

  GLIB_VER=$(pkg-config --modversion glib-2.0 2>/dev/null || echo 2.88.3)
  GLIB_SRCDIR="$HOME/.cache/eh575-build/glib-$GLIB_VER"
  if [ ! -d "$GLIB_SRCDIR" ]; then
    mkdir -p "$(dirname "$GLIB_SRCDIR")"
    curl -fsSL -o "/tmp/glib-$GLIB_VER.tar.xz" \
      "https://download.gnome.org/sources/glib/${GLIB_VER%.*}/glib-$GLIB_VER.tar.xz" \
      || die "could not download glib $GLIB_VER sources"
    tar xf "/tmp/glib-$GLIB_VER.tar.xz" -C "$(dirname "$GLIB_SRCDIR")" \
      || die "could not unpack glib sources"
  fi

  local script
  script=$(find "$GLIB_SRCDIR" -name 'glib-mkenums.in' -print -quit)
  [ -n "$script" ] || die "glib-mkenums.in not found in the glib source tree"

  mkdir -p "$PREFIX/bin" "$PREFIX/lib/pkgconfig"
  # The only substitution glib-mkenums.in needs is the interpreter shebang.
  local py
  py=$(command -v python3 || echo /usr/bin/python3)
  sed "1s|^#!.*|#!$py|" "$script" > "$PREFIX/bin/glib-mkenums"
  chmod +x "$PREFIX/bin/glib-mkenums" || die "could not make glib-mkenums executable"
  "$PREFIX/bin/glib-mkenums" --help >/dev/null 2>&1 \
    || die "the glib-mkenums shim does not run"

  # Shadow glib-2.0.pc with a copy whose glib_mkenums points at the shim.
  local syspc
  syspc=$(pkg-config --variable=pcfiledir glib-2.0 2>/dev/null)/glib-2.0.pc
  [ -f "$syspc" ] || die "could not locate the system glib-2.0.pc"
  sed "s|\${bindir}/glib-mkenums|$PREFIX/bin/glib-mkenums|" "$syspc" \
    > "$PREFIX/lib/pkgconfig/glib-2.0.pc" \
    || die "could not write the patched glib-2.0.pc"

  export PKG_CONFIG_PATH="$PREFIX/lib/pkgconfig${PKG_CONFIG_PATH:+:$PKG_CONFIG_PATH}"
  export PATH="$PREFIX/bin:$PATH"
  say "glib-mkenums shim installed at $PREFIX/bin/glib-mkenums"
}
ensure_mkenums

# ------------------------------------------------------- libfprint
if [ ! -d "$SRC/.git" ]; then
  say "Cloning libfprint"
  mkdir -p "$(dirname "$SRC")"
  git clone --filter=blob:none https://gitlab.freedesktop.org/libfprint/libfprint.git "$SRC"
else
  say "Updating existing libfprint checkout"
  # The driver files are untracked in this checkout (they come from a patch,
  # not a commit), so `git reset --hard` will NOT remove them. Remove them
  # explicitly, otherwise a re-run fails with "already exists in working
  # directory" and the meson hunks end up applied twice.
  rm -f "$SRC/libfprint/drivers/egis0575.c" "$SRC/libfprint/drivers/egis0575.h"
  git -C "$SRC" checkout -- meson.build libfprint/meson.build 2>/dev/null || true
  git -C "$SRC" fetch -q origin
  git -C "$SRC" reset -q --hard origin/master
fi
say "libfprint at $(git -C "$SRC" rev-parse --short HEAD)"

PATCH_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/patches"
say "Applying egis0575 driver"
# The checkout is guaranteed clean at this point (either freshly cloned, or
# reset with the driver files explicitly removed above), so a plain apply is
# correct and idempotent across re-runs.
git -C "$SRC" apply "$PATCH_DIR/0001-add-egis0575-driver.patch" \
  || die "patch did not apply. libfprint master may have changed; see the repo README."
say "patch applied"

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

# NOTE: every `nm ... | grep -q` below is written without pipefail trouble.
# Under `set -o pipefail`, `grep -q` exits as soon as it matches, which SIGPIPEs
# nm and makes the whole pipeline report failure. Redirect to a variable and
# test that instead.

# --------------------------------------------------------- verify
say "Verifying"
LIB=$(find "$PREFIX" -name 'libfprint-2.so.2.*' -type f -print -quit)
test -n "$LIB" || die "shared library not found under $PREFIX"

# The driver registers its GType as a *local* symbol, so it will not appear in
# the dynamic symbol table (nm -D) and a release build may not leave the name
# in the string table either. Check for the object file and the local symbol.
DRVOBJ=$(find "$HOME/.cache/eh575-build/libfprint" -name '*egis0575*.o' -print -quit)
test -n "$DRVOBJ" || die "egis0575 object file was never compiled"
echo "  driver object: ${DRVOBJ#$HOME/}"

SYMS=$(nm "$LIB" 2>/dev/null || true)
case "$SYMS" in
  *fpi_device_egis0575_get_type*) echo "  driver GType present in the library" ;;
  *) die "driver GType missing from $LIB" ;;
esac

# The threshold override from this repo must have made it into the binary.
case "$(strings "$LIB")" in
  *EGIS0575_FINGER_THRESHOLD*) echo "  threshold override present" ;;
  *) die "threshold override missing from $LIB" ;;
esac

# And the user-visible promise: the device is advertised as supported.
SD="$HOME/.cache/eh575-build/libfprint/build-local/libfprint/fprint-list-supported-devices"
if [ -x "$SD" ]; then
  if printf '%s' "$("$SD")" | grep -q '1c7a:0575'; then
    echo "  1c7a:0575 listed as supported"
  else
    die "1c7a:0575 is not in the supported device list"
  fi
fi

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
