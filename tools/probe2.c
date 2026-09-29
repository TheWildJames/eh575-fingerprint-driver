/* Raw probe of the EH575 finger-presence query.
 * Sends the same 6-byte EGIS command the driver uses to ask "is a finger
 * present?" and prints the 7-byte response. Read-only diagnostic: this is
 * the sensor's own status query, it starts no capture and writes nothing.
 */
#include <gusb.h>
#include <gio/gio.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#define VID 0x1c7a
#define PID 0x0575
#define EP_OUT 0x01
#define EP_IN  0x82

int main(int argc, char **argv)
{
    int polls = argc > 1 ? atoi(argv[1]) : 20;
    GError *error = NULL;
    GUsbContext *ctx = g_usb_context_new(&error);
    if (!ctx) { fprintf(stderr, "ctx: %s\n", error ? error->message : "null"); return 2; }

    GUsbDevice *dev = g_usb_context_find_by_vid_pid(ctx, VID, PID, &error);
    if (!dev) { fprintf(stderr, "device: %s\n", error ? error->message : "null"); return 2; }

    if (!g_usb_device_open(dev, &error)) {
        fprintf(stderr, "open: %s\n", error ? error->message : "null"); return 2;
    }
    if (!g_usb_device_claim_interface(dev, 0, 0, &error)) {
        fprintf(stderr, "claim FAILED: %s\n", error ? error->message : "unknown"); return 2;
    }
    printf("device open, interface 0 claimed\n\n");

    /* EGIS finger-presence query, byte-for-byte as the driver sends it */
    const guchar q[6] = { 0x45, 0x47, 0x49, 0x53, 0x60, 0x01 };

    for (int i = 0; i < polls; i++) {
        guchar qbuf[6];
        memcpy(qbuf, q, 6);
        gsize wlen = 0;
        gboolean wok = g_usb_device_bulk_transfer(dev, EP_OUT, qbuf, 6,
                                                 &wlen, 2000, NULL, &error);
        if (!wok) {
            fprintf(stderr, "poll %d write: %s\n", i, error ? error->message : "null");
            g_clear_error(&error);
            break;
        }

        guchar buf[64] = {0};
        gsize rlen = 0;
        gboolean rok = g_usb_device_bulk_transfer(dev, EP_IN, buf, sizeof buf,
                                                  &rlen, 2000, NULL, &error);
        if (!rok) {
            fprintf(stderr, "poll %d read: %s\n", i, error ? error->message : "null");
            g_clear_error(&error);
            break;
        }

        printf("poll %2d: wrote %zu, read %zu bytes:", i, wlen, rlen);
        for (gsize b = 0; b < rlen && b < 16; b++)
            printf(" %02x", buf[b]);
        printf("\n");

        if (rlen >= 6) {
            guchar v = buf[5];
            printf("          -> buffer[5] = 0x%02x (%u) : driver sees %s, treats as %s\n",
                   v, v,
                   v <= 0x03 ? "<=0x03" : "> 0x03",
                   v <= 0x03 ? "NO FINGER (loops back)" : "FINGER PRESENT (captures)");
        }
    }

    g_usb_device_release_interface(dev, 0, 0, NULL);
    g_usb_device_close(dev, NULL);
    printf("\nprobe done\n");
    return 0;
}
