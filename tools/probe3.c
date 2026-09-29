/* Is the EH575 actually responding, or just echoing a fixed frame?
 * Sends several different EGIS commands and prints each response so we can
 * tell a real reply apart from a canned echo. Read-only diagnostics only:
 * every command here is one the sensor's own status/calibration protocol
 * already uses, and none of them write to non-volatile storage.
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

static GUsbDevice *dev;

static void show(const char *label, const guchar *q, int qlen, int rlen_expect)
{
    guchar qbuf[64];
    memcpy(qbuf, q, qlen);
    gsize wlen = 0, rlen = 0;
    GError *error = NULL;

    printf("\n== %s\n", label);
    printf("   TX:");
    for (int i = 0; i < qlen; i++) printf(" %02x", q[i]);
    printf("\n");

    if (!g_usb_device_bulk_transfer(dev, EP_OUT, qbuf, qlen, &wlen, 2000, NULL, &error)) {
        printf("   TX FAILED: %s\n", error->message);
        g_clear_error(&error);
        return;
    }

    guchar buf[512] = {0};
    if (!g_usb_device_bulk_transfer(dev, EP_IN, buf, rlen_expect, &rlen, 2000, NULL, &error)) {
        printf("   RX FAILED/timeout: %s\n", error->message);
        g_clear_error(&error);
        return;
    }

    printf("   RX (%zu):", rlen);
    for (gsize i = 0; i < rlen && i < 24; i++) printf(" %02x", buf[i]);
    printf("\n");

    if (rlen >= 4) {
        char magic[5] = { (char)buf[0], (char)buf[1], (char)buf[2], (char)buf[3], 0 };
        printf("   magic as ASCII: '%s'", magic);
        if (strncmp(magic, "EGIS", 4) == 0)
            printf("  (matches driver expectation)\n");
        else if (strncmp(magic, "SIGE", 4) == 0)
            printf("  (BYTE-REVERSED 'EGIS' - suspicious)\n");
        else
            printf("  (unrecognised)\n");
    }
}

int main(void)
{
    GError *error = NULL;
    GUsbContext *ctx = g_usb_context_new(&error);
    if (!ctx) { fprintf(stderr, "ctx failed\n"); return 2; }
    dev = g_usb_context_find_by_vid_pid(ctx, VID, PID, &error);
    if (!dev) { fprintf(stderr, "device: %s\n", error->message); return 2; }
    if (!g_usb_device_open(dev, &error)) {
        fprintf(stderr, "open: %s\n", error->message); return 2;
    }
    if (!g_usb_device_claim_interface(dev, 0, 0, &error)) {
        fprintf(stderr, "claim: %s\n", error->message); return 2;
    }
    printf("device open, interface claimed\n");

    /* the driver's finger-presence poll */
    const guchar q_finger[6] = { 0x45, 0x47, 0x49, 0x53, 0x60, 0x01 };
    show("finger presence poll (driver's own command)", q_finger, 6, 7);

    /* a byte-swapped variant, to test the reversal theory */
    const guchar q_swap[6] = { 0x53, 0x49, 0x47, 0x45, 0x60, 0x01 };
    show("same but magic byte-reversed (test of reversal theory)", q_swap, 6, 7);

    /* a different EGIS subcommand, same length - a real reply should differ */
    const guchar q_other[6] = { 0x45, 0x47, 0x49, 0x53, 0x60, 0x2d };
    show("different subcommand 0x2d (calibration phase 2 cmd)", q_other, 6, 7);

    /* calibration packet 1 from the driver's table */
    const guchar q_cal[7] = { 0x45, 0x47, 0x49, 0x53, 0x73, 0x14, 0xec };
    show("calibration packet 1 (0x73 0x14 0xec)", q_cal, 7, 7);

    g_usb_device_release_interface(dev, 0, 0, NULL);
    g_usb_device_close(dev, NULL);
    printf("\ndone\n");
    return 0;
}
