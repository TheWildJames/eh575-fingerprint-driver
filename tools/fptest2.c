/* Read-only test harness for EgisTec EH575 (1c7a:0575) via patched libfprint.
 *
 * Usage:
 *   fptest enumerate      list devices libfprint can see
 *   fptest open           open the device, report scan type
 *   fptest capture FILE   one swipe capture -> PGM image
 *
 * Nothing is written to disk except the image you name, no udev rules, no PAM,
 * no persistent storage, no firmware writes. The driver only ever issues EGIS
 * read/calibration/capture command sequences.
 */
#include <libfprint-2/fprint.h>
#include <gio/gio.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <errno.h>

#define TARGET_ID "1c7a:0575"

/* capture completion state */
static FpDevice *cap_dev;
static FpImage  *cap_img;
static GError   *cap_err;
static gboolean  cap_done;

static void capture_cb(GObject *src, GAsyncResult *res, gpointer data)
{
    (void)data;
    cap_img = fp_device_capture_finish(cap_dev, res, &cap_err);
    cap_done = TRUE;
}

static FpDevice *find_device(FpContext *ctx)
{
    GPtrArray *devs = fp_context_get_devices(ctx);
    if (!devs)
        return NULL;
    for (guint i = 0; i < devs->len; i++) {
        FpDevice *d = g_ptr_array_index(devs, i);
        /* The egis0575 driver does not set a device id string (reports "0"),
         * so match on the driver name it registered itself under. */
        const char *drv = fp_device_get_driver(d);
        if (drv && strcmp(drv, "egis0575") == 0)
            return d;
    }
    return NULL;
}

static void dump_devices(FpContext *ctx)
{
    GPtrArray *devs = fp_context_get_devices(ctx);
    printf("devices seen: %u\n", devs ? devs->len : 0);
    if (!devs)
        return;
    for (guint i = 0; i < devs->len; i++) {
        FpDevice *d = g_ptr_array_index(devs, i);
        printf("  %-11s %-30s driver=%s\n",
               fp_device_get_device_id(d) ?: "?",
               fp_device_get_name(d) ?: "?",
               fp_device_get_driver(d) ?: "?");
    }
}

static gboolean save_pgm(FpImage *img, const char *path, GError **err)
{
    guint w = fp_image_get_width(img);
    guint h = fp_image_get_height(img);
    const guchar *data = fp_image_get_data(img, NULL);
    if (!data || !w || !h) {
        g_set_error(err, G_IO_ERROR, G_IO_ERROR_INVALID_DATA, "empty image");
        return FALSE;
    }
    FILE *f = fopen(path, "wb");
    if (!f) {
        g_set_error(err, G_IO_ERROR, g_io_error_from_errno(errno),
                    "cannot open %s", path);
        return FALSE;
    }
    fprintf(f, "P5\n%u %u\n255\n", w, h);
    fwrite(data, 1, (size_t)w * h, f);
    fclose(f);
    return TRUE;
}

int main(int argc, char **argv)
{
    const char *cmd = argc > 1 ? argv[1] : "enumerate";
    FpContext *ctx = fp_context_new();
    if (!ctx) {
        fprintf(stderr, "fp_context_new failed\n");
        return 2;
    }

    FpDevice *dev = find_device(ctx);
    if (!dev) {
        printf("FAIL: %s not enumerated\n", TARGET_ID);
        dump_devices(ctx);
        return 1;
    }
    printf("found %s  name=%s  driver=%s\n",
           fp_device_get_device_id(dev),
           fp_device_get_name(dev) ?: "?",
           fp_device_get_driver(dev) ?: "?");

    if (strcmp(cmd, "enumerate") == 0) {
        dump_devices(ctx);
        return 0;
    }

    /* open is async; pump the main context until the device reports open */
    fp_device_open(dev, NULL, NULL, NULL);
    gint64 deadline = g_get_monotonic_time() + 15 * G_USEC_PER_SEC;
    while (!fp_device_is_open(dev) && g_get_monotonic_time() < deadline)
        g_main_context_iteration(NULL, TRUE);

    if (!fp_device_is_open(dev)) {
        printf("FAIL: open timed out after 15s\n");
        return 1;
    }
    printf("opened ok\n");

    FpScanType st = fp_device_get_scan_type(dev);
    printf("scan type: %s\n",
           st == FP_SCAN_TYPE_SWIPE ? "SWIPE" :
           st == FP_SCAN_TYPE_PRESS ? "PRESS" : "OTHER");

    if (strcmp(cmd, "open") == 0) {
        printf("OK: device functional under the patched driver\n");
        return 0;
    }

    if (strcmp(cmd, "capture") == 0) {
        const char *path = argc > 2 ? argv[2] : "finger.pgm";
        printf("SWIPE your finger steadily across the sensor now...\n");
        fflush(stdout);

        cap_dev = dev;
        cap_done = FALSE;
        fp_device_capture(dev, TRUE, NULL, capture_cb, NULL);

        gint64 cap_deadline = g_get_monotonic_time() + 60 * G_USEC_PER_SEC;
        while (!cap_done && g_get_monotonic_time() < cap_deadline)
            g_main_context_iteration(NULL, TRUE);

        if (!cap_done) {
            printf("FAIL: capture timed out after 60s\n");
            return 1;
        }
        if (!cap_img) {
            printf("FAIL: capture failed: %s\n",
                   cap_err ? cap_err->message : "unknown error");
            return 1;
        }

        guint w = fp_image_get_width(cap_img);
        guint h = fp_image_get_height(cap_img);
        printf("captured image: %ux%u px\n", w, h);

        GError *err = NULL;
        if (!save_pgm(cap_img, path, &err)) {
            printf("FAIL: save: %s\n", err->message);
            return 1;
        }
        printf("saved -> %s\n", path);
        return 0;
    }

    printf("command '%s' not implemented yet\n", cmd);
    return 2;
}
