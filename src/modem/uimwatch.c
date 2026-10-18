/*
 * uimwatch - 同时注册 UIM 的三种事件，验证 modem 到底会上报哪一种。
 *
 * qmicli 的 --uim-monitor-slot-status 只订阅 physical-slot-status(1<<4)，
 * 本机实测注册成功但从不触发。这个程序把 card-status(1<<0)、
 * extended-card-status(1<<2)、physical-slot-status(1<<4) 一起注册。
 *
 * 收到任何事件就打印 EVENT <名字> 并调用 sirius-modem-uim。
 */
#include <gio/gio.h>
#include <libqmi-glib.h>
#include <libqrtr-glib.h>
#include <stdlib.h>
#include <stdio.h>

static GMainLoop *loop = NULL;

static void
on_event (QmiClientUim *client, gpointer output, gpointer user_data)
{
    const char *name = (const char *)user_data;
    printf ("EVENT %s\n", name);
    fflush (stdout);
    /* 事件触发后做正事（后台跑，不阻塞事件循环） */
    if (system ("/usr/local/bin/sirius-modem-uim >/dev/null 2>&1 &") < 0)
        perror ("system");
}

static void
register_ready (QmiClientUim *client, GAsyncResult *res, gpointer user_data)
{
    GError *error = NULL;
    QmiMessageUimRegisterEventsOutput *out;

    out = qmi_client_uim_register_events_finish (client, res, &error);
    if (!out) {
        fprintf (stderr, "register_events failed: %s\n", error ? error->message : "?");
        if (error) g_error_free (error);
        return;
    }
    {
        GError *e = NULL;
        if (!qmi_message_uim_register_events_output_get_result (out, &e)) {
            fprintf (stderr, "register_events QMI error: %s\n", e ? e->message : "?");
            if (e) g_error_free (e);
        } else {
            printf ("events registered (mask=0x15)\n");
            fflush (stdout);
        }
    }
    qmi_message_uim_register_events_output_unref (out);
}

static void
client_ready (QmiDevice *device, GAsyncResult *res, gpointer user_data)
{
    GError *error = NULL;
    QmiClient *client;
    QmiMessageUimRegisterEventsInput *input;
    GError *e = NULL;
    QmiUimEventRegistrationFlag mask;

    client = qmi_device_allocate_client_finish (device, res, &error);
    if (!client) {
        fprintf (stderr, "allocate_client: %s\n", error ? error->message : "?");
        if (error) g_error_free (error);
        g_main_loop_quit (loop);
        return;
    }

    /* 事件回调：名字不存在时 g_signal_connect 会给警告，但不崩 */
    if (g_signal_lookup ("card-status", QMI_TYPE_CLIENT_UIM))
        g_signal_connect (client, "card-status", G_CALLBACK (on_event), (gpointer)"card-status");
    else
        fprintf (stderr, "no 'card-status' signal in libqmi\n");

    if (g_signal_lookup ("extended-card-status", QMI_TYPE_CLIENT_UIM))
        g_signal_connect (client, "extended-card-status", G_CALLBACK (on_event), (gpointer)"extended-card-status");

    if (g_signal_lookup ("slot-status", QMI_TYPE_CLIENT_UIM))
        g_signal_connect (client, "slot-status", G_CALLBACK (on_event), (gpointer)"slot-status");
    else
        fprintf (stderr, "no 'slot-status' signal in libqmi\n");

    mask = QMI_UIM_EVENT_REGISTRATION_FLAG_CARD_STATUS |
           QMI_UIM_EVENT_REGISTRATION_FLAG_EXTENDED_CARD_STATUS |
           QMI_UIM_EVENT_REGISTRATION_FLAG_PHYSICAL_SLOT_STATUS;

    input = qmi_message_uim_register_events_input_new ();
    if (!qmi_message_uim_register_events_input_set_event_registration_mask (input, mask, &e)) {
        fprintf (stderr, "set mask: %s\n", e ? e->message : "?");
        if (e) g_error_free (e);
        g_main_loop_quit (loop);
        return;
    }
    qmi_client_uim_register_events (QMI_CLIENT_UIM (client), input, 30, NULL,
                                    (GAsyncReadyCallback)register_ready, NULL);
    qmi_message_uim_register_events_input_unref (input);
}

static void
open_ready (QmiDevice *device, GAsyncResult *res, gpointer user_data)
{
    GError *error = NULL;
    if (!qmi_device_open_finish (device, res, &error)) {
        fprintf (stderr, "open: %s\n", error ? error->message : "?");
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
    QmiDevice *device = qmi_device_new_from_node_finish (res, &error);
    if (!device) {
        fprintf (stderr, "device: %s\n", error ? error->message : "?");
        g_main_loop_quit (loop);
        return;
    }
    qmi_device_open (device, QMI_DEVICE_OPEN_FLAGS_EXPECT_INDICATIONS, 30, NULL,
                     (GAsyncReadyCallback)open_ready, NULL);
}

static void
bus_ready (GObject *src, GAsyncResult *res, gpointer user_data)
{
    GError *error = NULL;
    QrtrBus *bus = qrtr_bus_new_finish (res, &error);
    QrtrNode *node;

    if (!bus) {
        fprintf (stderr, "bus: %s\n", error ? error->message : "?");
        g_main_loop_quit (loop);
        return;
    }
    node = qrtr_bus_get_node (bus, 0);
    if (!node) {
        fprintf (stderr, "no node 0\n");
        g_main_loop_quit (loop);
        return;
    }
    qmi_device_new_from_node (node, NULL, device_ready, NULL);
}

int main (void)
{
    setbuf (stdout, NULL);
    loop = g_main_loop_new (NULL, FALSE);
    qrtr_bus_new (10000, NULL, bus_ready, NULL);
    g_main_loop_run (loop);
    return 0;
}
