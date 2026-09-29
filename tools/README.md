# Test tools

Small harnesses used to bring this driver up on real hardware. All are
read-only with respect to the sensor: they only ever send the EGIS read,
calibration, and capture command sequences the driver itself uses. None of them
writes to the sensor's non-volatile storage.

Build them against your local libfprint prefix. Adjust `PFX` to match.

```sh
PFX=$HOME/fp-prefix
export LD_LIBRARY_PATH=$PFX/lib
CFLAGS="-I$PFX/include -I$PFX/include/libfprint-2 -I$PFX/include/gusb-1 \
        $(pkg-config --cflags gio-unix-2.0 gobject-2.0 glib-2.0 json-glib-1.0)"
LIBS="$(pkg-config --libs libfprint-2 gusb gio-unix-2.0)"

gcc -O1 -o fptest     fptest2.c     $CFLAGS $LIBS
gcc -O1 -o probe      probe2.c      $CFLAGS $LIBS
gcc -O1 -o probe3     probe3.c      $CFLAGS $LIBS
gcc -O1 -o monitor    monitor.c     $CFLAGS $LIBS
gcc -O1 -o enroll-test enroll-test.c $CFLAGS $LIBS
```

Note the include paths. The public headers install to
`$PFX/include/libfprint-2/` but the umbrella header is `fprint.h`, not
`libfprint-2.h`, and gusb's is at `$PFX/include/gusb-1/gusb.h`. The `.pc` files
do not cover this, so the extra `-I` flags are required.

## fptest (`fptest2.c`)

The main harness. Wraps the modern async libfprint API, which needs a
`GMainLoop` - there are no synchronous convenience calls left in the public API.

```sh
./fptest enumerate            # list devices libfprint can see
./fptest open                 # open, report scan type
./fptest capture finger.pgm   # one swipe, write a PGM
```

It matches the device by **driver name** (`egis0575`), not device id. The driver
never calls `fp_device_set_device_id()`, so the device reports its id as the
string `"0"`. That is a small bug in MR !357, and it matters for anything that
keys off the device id, such as fprintd or GNOME.

## probe (`probe2.c`)

Sends the raw 6-byte finger-presence query and prints the 7-byte reply:

```sh
./probe 15
```

The driver reads its finger field from `buffer[5]`.

Caveat worth knowing: run standalone, this reports `0x01`. Run through the
driver, which first executes its full init sequence, it reports `0x00`. The init
packets change sensor state and therefore what the status field returns. Do not
conclude the sensor is unresponsive from raw-probe results alone.

## probe3 (`probe3.c`)

Sends several different EGIS commands to tell a genuine reply apart from a
canned echo. Useful because the EH575 mirrors its magic in responses: it replies
`53 49 47 45` ("SIGE") to a request for `45 47 49 53` ("EGIS"). That reversal is
a device quirk, not a protocol error - byte-reversed requests time out, and
different subcommands return different replies.

## monitor (`monitor.c`)

Polls the finger-presence field for a fixed period and reports how many polls
saw a finger. Use this to tell "you missed the window" apart from "the driver
failed":

```sh
./monitor 90
```

## capture-test.sh

Runs N capture windows with a large banner at the start of each, then reports per
window whether an image was produced and whether the sensor ever detected a
finger.

```sh
./capture-test.sh 5 30     # 5 windows, 30s each
```

**Swipe on the banner.** A terminal bell is not reliable - many terminals have
it disabled - so this prints plain text instead.

Gotcha: `G_MESSAGES_DEBUG` only emits when stderr is a TTY. If you redirect the
tool output to a file, the driver log comes back empty and any poll counting done
against it is meaningless. The script handles this.

## enroll-test (`enroll-test.c`)

Attempts enrollment, then verifies against itself, entirely in RAM.

```sh
./enroll-test 60 60    # 60s enroll window, 60s verify window
```

**Expect this to time out.** The driver implements no enroll vfunc, so
`fp_device_enroll()` falls through to a base-class stub that never completes.
The test is included because that is the finding: it demonstrates the
limitation rather than working around it.

If you are adapting this for a driver that *does* implement enrollment, note that
image-based drivers require a print template:

```c
FpPrint *tmpl = fp_print_new(dev);
fp_print_set_finger(tmpl, FP_FINGER_RIGHT_INDEX);
fp_print_set_username(tmpl, "eh575-test");
fp_device_enroll(dev, tmpl, NULL, progress_cb, NULL, NULL, done_cb, NULL);
```

Passing `NULL` gives `User did not pass a print template!`.

## A note on swipe technique

This is a swipe sensor. It needs one slow, steady motion of the whole fingertip
across the small sensor window. The driver captures 10 consecutive 52px strips
with a 50ms delay between them (`EGIS0575_CONSECUTIVE_CAPTURES` and
`EGIS0575_CAPTURE_DELAY` in the header) and stitches them.

Fast or partial swipes yield images with ridge flow but no resolvable minutiae,
which then fail with `No minutiae found`. That accounts for most failed captures
and is not a driver bug.
