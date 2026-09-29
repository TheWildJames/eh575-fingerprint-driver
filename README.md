# EgisTec EH575 fingerprint sensor driver for libfprint (1c7a:0575)

[![build](https://github.com/TheWildJames/eh575-fingerprint-driver/actions/workflows/build.yml/badge.svg)](https://github.com/TheWildJames/eh575-fingerprint-driver/actions/workflows/build.yml)

A working **capture** driver for the EgisTec EH575 swipe fingerprint sensor, ported
from the unmerged upstream [libfprint MR !357](https://gitlab.freedesktop.org/libfprint/libfprint/-/merge_requests/357)
onto current libfprint master.

Tested on an **Acer Swift SFX14-41G** (CachyOS, kernel 7.2.2).

## Status: capture works, fingerprint login does not

Being precise, because the distinction matters:

| Operation | Status |
|---|---|
| Device detection | Works |
| Image capture (swipe) | **Works** - 7 successful captures across 4 test runs |
| Enrollment | **Not implemented** |
| Verification / identification | **Not implemented** |

The driver as merged in MR !357 implements **capture only**. It registers
`img_open`, `img_close`, `activate`, `deactivate` and nothing else - there is no
enroll, verify, or identify vfunc. `struct _FpImageDeviceClass` in current
libfprint has no such members for an image device to implement, so enrollment
falls through to a base-class stub that never completes.

Note that libfprint will still advertise `FP_DEVICE_FEATURE_VERIFY` for this
device. That flag is derived from `FpDeviceClass` vfuncs in
`fpi_device_class_auto_initialize_features()`, which the driver does not set, so
the advertised capability overstates what the code actually does. Do not trust
that flag on this device.

This is a **code** limitation, not a hardware one. The sensor itself produces
good images.

## What the sensor gives you

- 103 x 52 px per frame, stitched from 10 consecutive strips into ~136 x 100-165 px
- Output width is padded to 136 because PIXMAN requires a stride that is a
  multiple of 4
- Real ridge flow is recoverable, including loop patterns and visible minutiae
- Roughly 4 usable captures per 5 attempts with prompt signalling
- Captures sometimes fail with `No minutiae found` - see
  [libfprint#271](https://gitlab.freedesktop.org/libfprint/libfprint/-/issues/271)
  and [#272](https://gitlab.freedesktop.org/libfprint/libfprint/-/issues/272),
  which track whether images this small can be matched at all

The 103x52 resolution is the fundamental ceiling. Individual minutiae are
frequently not resolvable, and image analysis of captures ranges from "clear loop
with ridge endings and a bifurcation" to "ridge flow visible, no minutiae
present at all", depending on swipe quality.

## Requirements

- libfprint master (1.94.100+)
- `libgusb` (>= 0.2.0), `libusb-1.0`, glib-2.0 >= 2.68, pixman, cairo
- meson >= 0.62, ninja, a C compiler

You do **not** need to replace your system libfprint. Everything below builds
into a local prefix.

## Install

```sh
git clone https://github.com/TheWildJames/eh575-fingerprint-driver.git
cd eh575-fingerprint-driver
./install.sh
```

That is the whole thing. The script:

- checks dependencies via `pkg-config` (it will not install packages for you)
- builds `libgusb` into the prefix if your distro's `libgusb` has no
  pkg-config entry, and shims `glib-mkenums` if the binary is missing while
  `glib-2.0.pc` still advertises it (both are known packaging gaps)
- clones libfprint, applies the driver, builds **only** `egis0575` into
  `$PREFIX` (default `~/.local/share/eh575`)
- builds the test tools and an `eh575-env.sh` to set the library paths
- verifies the driver is actually in the binary before reporting success

It installs nothing system-wide and does not replace your system libfprint.
Re-running is safe.

Then:

```sh
source ~/.local/share/eh575/bin/eh575-env.sh
fptest open
fptest capture /tmp/finger.pgm
```

`fptest open` should print `scan type: SWIPE` and
`OK: device functional under the patched driver`.

You will need USB access, since the raw device node is root-only:

```sh
sudo setfacl -m u:$USER:rw /dev/bus/usb/XXX/YYY
```

Find `XXX/YYY` with `lsusb -d 1c7a:0575` and `lsusb -t`. This is cleared on
reboot; the numbers change between boots.

## Build from source manually

<details>
<summary>If you would rather not use the script</summary>

```sh
git clone https://gitlab.freedesktop.org/libfprint/libfprint.git
cd libfprint

# apply the driver (this patch also makes the finger-detection threshold
# configurable via EGIS0575_FINGER_THRESHOLD, defaulting to upstream's 0x03)
git apply /path/to/this/repo/patches/0001-add-egis0575-driver.patch

# build into a local prefix so your system libfprint is untouched
meson setup build --prefix=$HOME/fp-prefix \
    --buildtype=release \
    -D doc=false \
    -D introspection=false \
    -D drivers=egis0575 \
    -D udev_rules=disabled \
    -D udev_hwdb=disabled
ninja -C build
ninja -C build install
```

Notes:

- Build `-D drivers=egis0575`, **not** `-D drivers=all`. `all` pulls in the
  SPI drivers, which hard-require gudev and abort configure with
  `udev is required for SPI support`.
- Do not pass `-D vapi=` or `-D docs=`; those options belong to libgusb, not
  libfprint, and meson rejects unknown options.
- meson must be >= 0.62.0. Some distros (Ubuntu 22.04) ship 0.61.2.
- On Debian/Ubuntu the library installs to `lib/x86_64-linux-gnu`, not `lib`.
  Find the real path rather than assuming it:
  ```sh
  PCDIR=$(dirname "$(find $HOME/fp-prefix -name libfprint-2.pc -print -quit)")
  export PKG_CONFIG_PATH="$PCDIR${PKG_CONFIG_PATH:+:$PKG_CONFIG_PATH}"
  export LD_LIBRARY_PATH="$(dirname "$PCDIR")${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}"
  ```
- The public headers install to `include/libfprint-2/`, and the umbrella header
  is `fprint.h`, **not** `libfprint-2.h`.
- If configure fails with `tool variable 'glib_mkenums' contains erroneous
  value`, your `glib-2.0.pc` advertises a `glib-mkenums` that is not
  installed. `install.sh` handles this automatically.

</details>

Confirm the driver claims your device:

```sh
LD_LIBRARY_PATH=$HOME/fp-prefix/lib \
    $HOME/fp-prefix/bin/fprint-list-supported-devices | grep 0575
```

Then use the tools in `tools/`. See [tools/README.md](tools/README.md) for what
each one does.

The short version:

```sh
export PKG_CONFIG_PATH=$HOME/fp-prefix/lib/pkgconfig
export LD_LIBRARY_PATH=$HOME/fp-prefix/lib
gcc -o fptest tools/fptest2.c \
    -I$HOME/fp-prefix/include -I$HOME/fp-prefix/include/libfprint-2 \
    $(pkg-config --cflags gio-unix-2.0 gobject-2.0 glib-2.0) \
    $(pkg-config --libs libfprint-2 gusb gio-unix-2.0)
```

A swipe sensor needs a **slow, steady swipe of the whole fingertip**. Partial
or fast swipes produce images with no usable ridge detail.

## The finger-detection threshold

MR !357 contains a comment/code mismatch:

```c
// if value is less then 0x01 then there is no finger on the sensor
if(transfer->buffer[5] <= 0x03)   // code actually rejects up to 0x03
```

The patch makes the threshold configurable via `EGIS0575_FINGER_THRESHOLD`,
**defaulting to the original `0x03`**, so default behaviour is unchanged. Set
`EGIS0575_FINGER_THRESHOLD=0x00` to proceed on any nonzero reading, which is
useful for probing hardware that encodes finger presence differently.

For the record: on the EH575 tested here the field reads `0x00` through the
driver, so `0x00` and `0x03` behave identically. The mismatch is untidy upstream
code, but it was not the reason capture initially appeared to fail - the
original timeouts were simply windows with no finger on the sensor.

## Credits and licensing

The driver is **not mine**. It is the work of:

- **Animesh Sahu** - original reverse engineering and driver
- **Nils Schötteler** - calibration reliability fix

Both are retained in the source headers. The driver is licensed
**LGPL-2.1-or-later**, matching libfprint; `COPYING` is included.

This repository contains a port of their unmerged work to current libfprint
master, plus the threshold patch and the test tooling.

- Upstream MR: https://gitlab.freedesktop.org/libfprint/libfprint/-/merge_requests/357
- Earlier effort: https://github.com/Animeshz/EgisTec-EH575
- AUR package of the MR branch: `libfprint-egis-0575`

## Not included

- `fprintd` / PAM / GNOME integration. Nothing here is wired into system
  authentication, and no templates are stored anywhere.
- Persistent storage. The driver has no working NVM-write path, by design in
  the MR; calibration bytes are read from the sensor each session.

## Continuous integration

`.github/workflows/build.yml` runs on every push and pull request, on
Ubuntu 24.04 and 22.04, and weekly on Mondays whether or not anything changed.

It exists for one reason: **MR !357 is unmerged**, so libfprint master moves
underneath this patch. When upstream changes something the patch depends on,
CI fails at the apply step and says so, instead of a user hitting a broken
build.

The workflow verifies more than "it compiles":

- the patch applies cleanly to current master
- the `egis0575` object file is actually produced by the build
- the GType is registered in the shared library
- the threshold override from this repo is present in the binary
- `1c7a:0575` appears in `fprint-list-supported-devices`
- all five test tools still compile against the patched library
- the capture-only limitation still holds, warning if upstream ever adds
  enroll/verify so this README gets updated

A green badge means the patch still builds against today's master. It says
nothing about whether the sensor works, which only real hardware can confirm.

