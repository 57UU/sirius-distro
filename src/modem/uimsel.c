/*
 * uimsel - 直接发 QMI UIM ChangeProvisioningSession，不经过 qmicli 的
 * "先 power-off SIM" 步骤（那一步在本机 modem 上返回 QMI error 3/26）。
 */
#include <gio/gio.h>
#include <libqmi-glib.h>
#include <libqrtr-glib.h>
#include <string.h>
#include <stdio.h>

static GMainLoop *loop = NULL;
static guint g_slot = 1;

static gboolean
parse_hex (const char *s, guint8 *out, gsize *out_len)
{
    gsize n = 0;
    int hi = -1;
    for (; *s; s++) {
        int v;
        if (*s == ':' || *s == ' ') continue;
        if (*s >= '0' && *s <= '9') v = *s - '0';
        else if (*s >= 'a' && *s <= 'f') v = *s - 'a' + 10;
        else if (*s >= 'A' && *s <= 'F') v = *s - 'A' + 10;
        else return FALSE;
        if (hi < 0) hi = v;
        else { if (n >= 32) return FALSE; out[n++] = (guint8)((hi << 4) | v); hi = -1; }
    }
    if (hi >= 0) return FALSE;
    *out_len = n;
    return TRUE;
}

static void
change_ready (QmiClientUim *client, GAsyncResult *res, gpointer user_data)
{
    GError *error = NULL;
    QmiMessageUimChangeProvisioningSessionOutput *out;

    out = qmi_client_uim_change_provisioning_session_finish (client, res, &error);
    if (!out) {
        g_printerr ("FAILED (transport): %s\n", error ? error->message : "unknown");
        if (error) g_error_free (error);
        g_main_loop_quit (loop);
        return;
    }
    {
        GError *qmi_err = NULL;
        if (!qmi_message_uim_change_provisioning_session_output_get_result (out, &qmi_err)) {
            g_printerr ("FAILED (QMI): %s\n", qmi_err ? qmi_err->message : "unknown");
            if (qmi_err) g_error_free (qmi_err);
        } else {
            g_print ("SUCCESS: provisioning session changed\n");
        }
    }
    qmi_message_uim_change_provisioning_session_output_unref (out);
    g_main_loop_quit (loop);
}

static void
client_ready (QmiDevice *device, GAsyncResult *res, gpointer user_data)
{
    GError *error = NULL;
    QmiClient *client;
    QmiClientUim *uim;
    QmiMessageUimChangeProvisioningSessionInput *input;
    GArray *aid_arr;
    guint8 aid[32];
    gsize aid_len = 0;
    const char *aid_hex = g_getenv ("UIMSEL_AID");
    const char *st_env = g_getenv ("UIMSEL_ST");
    QmiUimSessionType stype = QMI_UIM_SESSION_TYPE_PRIMARY_GW_PROVISIONING;
    gboolean do_activate = TRUE;
    GError *e = NULL;

    if (st_env)
        stype = (QmiUimSessionType)g_ascii_strtoull (st_env, NULL, 10);
    if (g_getenv ("UIMSEL_DEACT"))
        do_activate = FALSE;

    client = qmi_device_allocate_client_finish (device, res, &error);
    if (!client) {
        g_printerr ("allocate_client failed: %s\n", error ? error->message : "unknown");
        if (error) g_error_free (error);
        g_main_loop_quit (loop);
        return;
    }
    uim = QMI_CLIENT_UIM (client);

    input = qmi_message_uim_change_provisioning_session_input_new ();
    if (!qmi_message_uim_change_provisioning_session_input_set_session_change (
            input, stype, do_activate, &e)) {
        g_printerr ("set session_change failed: %s\n", e->message);
        g_error_free (e);
        g_main_loop_quit (loop);
        return;
    }

    if (aid_hex && *aid_hex) {
        if (!parse_hex (aid_hex, aid, &aid_len)) {
            g_printerr ("bad AID\n");
            g_main_loop_quit (loop);
            return;
        }
        aid_arr = g_array_new (FALSE, FALSE, sizeof (guint8));
        g_array_append_vals (aid_arr, aid, aid_len);
        if (!qmi_message_uim_change_provisioning_session_input_set_application_information (
                input, (guint8)g_slot, aid_arr, &e)) {
            g_printerr ("set application_information failed: %s\n", e->message);
            g_error_free (e);
            g_main_loop_quit (loop);
            return;
        }
    } else {
        aid_arr = NULL;
    }

    g_print ("sending: stype=%d activate=%d slot=%u aid_len=%zu\n",
             (int)stype, do_activate, g_slot, (size_t)aid_len);
    qmi_client_uim_change_provisioning_session (uim, input, 30, NULL,
                                                (GAsyncReadyCallback)change_ready, NULL);
    qmi_message_uim_change_provisioning_session_input_unref (input);
    if (aid_arr)
        g_array_unref (aid_arr);
}

static void
open_ready (QmiDevice *device, GAsyncResult *res, gpointer user_data)
{
    GError *error = NULL;
    if (!qmi_device_open_finish (device, res, &error)) {
        g_printerr ("device open failed: %s\n", error ? error->message : "unknown");
        if (error) g_error_free (error);
        g_main_loop_quit (loop);
        return;
    }
    qmi_device_allocate_client (device, QMI_SERVICE_UIM, QMI_CID_NONE, 30, NULL,
                                (GAsyncReadyCallback)client_ready, NULL);
}

static void
device_ready (GObject *src, GAsyncResult *res, gpointer user_data)
{
    GError *error = NULL;
    QmiDevice *device;

    device = qmi_device_new_from_node_finish (res, &error);
    if (!device) {
        g_printerr ("device_new_from_node failed: %s\n", error ? error->message : "unknown");
        if (error) g_error_free (error);
        g_main_loop_quit (loop);
        return;
    }
    qmi_device_open (device, QMI_DEVICE_OPEN_FLAGS_NONE, 30, NULL,
                     (GAsyncReadyCallback)open_ready, NULL);
}

static void
bus_ready (GObject *src, GAsyncResult *res, gpointer user_data)
{
    GError *error = NULL;
    QrtrBus *bus;
    QrtrNode *node;

    bus = qrtr_bus_new_finish (res, &error);
    if (!bus) {
        g_printerr ("bus_new failed: %s\n", error ? error->message : "unknown");
        if (error) g_error_free (error);
        g_main_loop_quit (loop);
        return;
    }
    node = qrtr_bus_get_node (bus, 0);
    if (!node) {
        g_printerr ("no qrtr node 0\n");
        g_main_loop_quit (loop);
        return;
    }
    qmi_device_new_from_node (node, NULL, device_ready, NULL);
}

int main (int argc, char **argv)
{
    if (argc > 1)
        g_slot = (guint)g_ascii_strtoull (argv[1], NULL, 10);

    loop = g_main_loop_new (NULL, FALSE);
    qrtr_bus_new (10000, NULL, bus_ready, NULL);
    g_main_loop_run (loop);
    return 0;
}
