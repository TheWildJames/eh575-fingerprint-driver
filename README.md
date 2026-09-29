# EgisTec EH575 fingerprint sensor driver for libfprint (1c7a:0575)

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

## Build

```sh
git clone https://gitlab.freedesktop.org/libfprint/libfprint.git
cd libfprint

# apply the driver (this patch also makes the finger-detection threshold
# configurable via EGIS0575_FINGER_THRESHOLD, defaulting to upstream's 0x03)
git apply /path/to/this/repo/patches/0001-add-egis0575-driver.patch

# build into a local prefix so your system libfprint is untouched
meson setup build --prefix=$HOME/fp-prefix \
    -D doc=false -D introspection=false -D drivers=all \
    -D udev_rules=disabled -D udev_hwdb=disabled
ninja -C build
ninja -C build install
```

If `meson` fails with `Dependency 'glib-2.0' tool variable 'glib_mkenums'
contains erroneous value`, the `glib-mkenums` helper is missing (it ships in
`glib2-devel`). Either install that package, or drop a copy into your prefix and
point `PKG_CONFIG_PATH` at a local `glib-2.0.pc` with the corrected path.

## Permissions

libusb needs **write** access to the raw USB node. By default it is root-only:

```
crw-rw-r-- 1 root root 189, 259 ... /dev/bus/usb/003/004
```

A temporary grant, for testing, which a reboot clears:

```sh
sudo setfacl -m u:$USER:rw /dev/bus/usb/003/004
```

Revoke with `sudo setfacl -x u:$USER /dev/bus/usb/003/004`.

The bus and device numbers change across reboots, so a permanent udev rule is
better if you decide to keep this. No udev rule is installed by this project.

## Usage

Confirm the driver claims your device:

```sh
LD_LIBRARY_PATH=$HOME/fp-prefix/lib \
    $HOME/fp-prefix/bin/fprint-list-supported-devices | grep 0575
```

Then use the tools in `tools/`. See [tools/README.md](tools/README.md) for build
commands and what each one does.

The short version:

```sh
export LD_LIBRARY_PATH=$HOME/fp-prefix/lib
gcc -o fptest tools/fptest2.c -I$HOME/fp-prefix/include \
    -I$HOME/fp-prefix/include/libfprint-2 -I$HOME/fp-prefix/include/gusb-1 \
    $(pkg-config --cflags gio-unix-2.0 gobject-2.0 glib-2.0) \
    $(pkg-config --libs libfprint-2 gusb gio-unix-2.0)

./fptest open
./fptest capture finger.pgm
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
