/* Enroll + verify test for the EH575, entirely in RAM.
 *
 * Enrolls one finger, verifies it against itself, then deletes it. The print
 * lives only in this process's memory and is freed on exit: nothing is written
 * to disk, to fprintd, to PAM, or to the sensor's storage. The driver only
 * issues EGIS read/calibration/capture commands.
 */
#include <libfprint-2/fprint.h>
#include <gio/gio.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

static FpDevice *dev;
static gboolean  done;
static GError   *err;
static FpPrint  *enrolled;
static gboolean  match_result;
static int       match_calls;

static void on_enroll_progress(FpDevice *d, int progress, FpPrint *print,
                               gpointer user_data, GError *error)
{
    (void)d; (void)print; (void)user_data; (void)error;
    printf("\r  enrolling... %d%%", progress);
    fflush(stdout);
}

static void on_enroll_done(GObject *src, GAsyncResult *res, gpointer data)
{
    (void)data;
    enrolled = fp_device_enroll_finish(dev, res, &err);
    printf("\n");
    done = TRUE;
}

static void on_match(FpDevice *d, FpPrint *match, FpPrint *print,
                     gpointer user_data, GError *error)
{
    (void)d; (void)user_data; (void)print; (void)error;
    match_calls++;
    match_result = (match != NULL);
    printf("  match callback: %s\n", match_result ? "MATCH" : "no match");
    fflush(stdout);
}

static void on_verify_done(GObject *src, GAsyncResult *res, gpointer data)
{
    (void)data;
    gboolean m = FALSE;
    fp_device_verify_finish(dev, res, &m, NULL, &err);
    match_result = m;
    done = TRUE;
}

static gboolean pump(int seconds)
{
    gint64 deadline = g_get_monotonic_time() + seconds * G_USEC_PER_SEC;
    while (!done && g_get_monotonic_time() < deadline)
        g_main_context_iteration(NULL, TRUE);
    return done;
}

int main(int argc, char **argv)
{
    int enroll_secs  = argc > 1 ? atoi(argv[1]) : 45;
    int verify_secs  = argc > 2 ? atoi(argv[2]) : 45;

    FpContext *ctx = fp_context_new();
    GPtrArray *devs = fp_context_get_devices(ctx);
    for (guint i = 0; devs && i < devs->len; i++) {
        FpDevice *d = g_ptr_array_index(devs, i);
        const char *drv = fp_device_get_driver(d);
        if (drv && !strcmp(drv, "egis0575")) { dev = d; break; }
    }
    if (!dev) { printf("FAIL: egis0575 not found\n"); return 1; }
    printf("device: %s\n", fp_device_get_device_id(dev));

    fp_device_open(dev, NULL, NULL, NULL);
    gint64 dl = g_get_monotonic_time() + 15 * G_USEC_PER_SEC;
    while (!fp_device_is_open(dev) && g_get_monotonic_time() < dl)
        g_main_context_iteration(NULL, TRUE);
    if (!fp_device_is_open(dev)) { printf("FAIL: open timeout\n"); return 1; }
    printf("opened ok\n\n");

    /* report what the driver claims to support */
    FpDeviceFeature f = fp_device_get_features(dev);
    printf("features: capture=%d identify=%d verify=%d storage=%d\n",
           !!(f & FP_DEVICE_FEATURE_CAPTURE),
           !!(f & FP_DEVICE_FEATURE_IDENTIFY),
           !!(f & FP_DEVICE_FEATURE_VERIFY),
           !!(f & FP_DEVICE_FEATURE_STORAGE));
    printf("enroll stages required: %d\n\n", fp_device_get_nr_enroll_stages(dev));

    /* --- ENROLL --- */
    printf("=== ENROLL: swipe your finger (up to %ds) ===\n", enroll_secs);
    done = FALSE; err = NULL;
    /* image-based drivers require a template describing the finger */
    FpPrint *tmpl = fp_print_new(dev);
    fp_print_set_finger(tmpl, FP_FINGER_RIGHT_INDEX);
    fp_print_set_username(tmpl, "eh575-test");
    fp_device_enroll(dev, tmpl, NULL, on_enroll_progress, NULL, NULL,
                     on_enroll_done, NULL);
    if (!pump(enroll_secs)) {
        printf("ENROLL TIMED OUT (finger never completed the capture sequence)\n");
        return 1;
    }
    if (!enrolled) {
        printf("ENROLL FAILED: %s\n", err ? err->message : "unknown");
        return 1;
    }
    FpImage *ei = fp_print_get_image(enrolled);
    printf("ENROLLED OK: image %ux%u\n", ei ? fp_image_get_width(ei) : 0,
                                            ei ? fp_image_get_height(ei) : 0);
    printf("  minutiae detected: %u\n",
           ei ? fp_image_get_minutiae(ei)->len : 0);
    printf("\n");

    /* --- VERIFY against itself --- */
    printf("=== VERIFY: swipe the SAME finger again (up to %ds) ===\n", verify_secs);
    done = FALSE; err = NULL; match_calls = 0;
    fp_device_verify(dev, enrolled, NULL, on_match, NULL, NULL,
                     on_verify_done, NULL);
    if (!pump(verify_secs)) {
        printf("VERIFY TIMED OUT\n");
        return 1;
    }
    if (err) {
        printf("VERIFY FAILED: %s\n", err->message);
        return 1;
    }
    printf("\nRESULT: %s (match callbacks: %d)\n",
           match_result ? "MATCH - recognition works" : "NO MATCH", match_calls);

    /* --- delete the in-RAM print --- */
    printf("in-RAM print discarded on exit; nothing stored on disk or sensor\n");
    return match_result ? 0 : 2;
}
