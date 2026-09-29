/* Background finger-presence monitor.
 * Polls the sensor's status command for ~90s and logs the finger field so a
 * human can place a finger during the run. Read-only: the status query starts
 * no capture and writes nothing to the device.
 */
#include <gusb.h>
#include <gio/gio.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>

#define VID 0x1c7a
#define PID 0x0575
#define EP_OUT 0x01
#define EP_IN  0x82

int main(int argc, char **argv)
{
    int seconds = argc > 1 ? atoi(argv[1]) : 90;
    GError *error = NULL;
    GUsbContext *ctx = g_usb_context_new(&error);
    GUsbDevice *dev = g_usb_context_find_by_vid_pid(ctx, VID, PID, &error);
    if (!dev) { fprintf(stderr, "device: %s\n", error ? error->message : "?"); return 2; }
    if (!g_usb_device_open(dev, &error)) { fprintf(stderr, "open failed\n"); return 2; }
    if (!g_usb_device_claim_interface(dev, 0, 0, &error)) {
        fprintf(stderr, "claim failed\n"); return 2;
    }
    printf("monitoring finger presence for %d seconds\n", seconds);
    printf("PLACE OR SWIPE YOUR FINGER ON THE SENSOR NOW\n\n");
    fflush(stdout);

    const guchar q[6] = { 0x45, 0x47, 0x49, 0x53, 0x60, 0x01 };
    time_t start = time(NULL);
    unsigned long polls = 0;
    unsigned long nonzero = 0;
    int last = -1;

    while (difftime(time(NULL), start) < seconds) {
        guchar qbuf[6];
        memcpy(qbuf, q, 6);
        gsize wlen = 0, rlen = 0;
        if (!g_usb_device_bulk_transfer(dev, EP_OUT, qbuf, 6, &wlen, 500, NULL, &error)) {
            g_clear_error(&error);
            continue;
        }
        guchar buf[64] = {0};
        if (!g_usb_device_bulk_transfer(dev, EP_IN, buf, 7, &rlen, 500, NULL, &error)) {
            g_clear_error(&error);
            continue;
        }
        polls++;
        if (rlen >= 6) {
            int v = buf[5];
            if (v != 0) nonzero++;
            /* only print on change, to keep the log readable */
            if (v != last) {
                printf("[%3lds] finger field = 0x%02x (%d) %s\n",
                       (long)difftime(time(NULL), start), buf[5], v,
                       v > 3 ? "*** FINGER PRESENT ***" : "(no finger)");
                fflush(stdout);
                last = v;
            }
        }
    }

    printf("\ndone: %lu polls, %lu with nonzero finger field\n", polls, nonzero);
    printf("driver requires > 0x03 (i.e. >= 4) to start capturing\n");
    g_usb_device_release_interface(dev, 0, 0, NULL);
    g_usb_device_close(dev, NULL);
    return 0;
}
