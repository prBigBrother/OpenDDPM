#include <stdio.h>
#include <string.h>
#include <stdlib.h>
#include <errno.h>
#include <inttypes.h>
#include "freertos/FreeRTOS.h"
#include "freertos/task.h"
#include "freertos/queue.h"
#include "esp_event.h"
#include "esp_log.h"
#include "esp_netif.h"
#include "esp_wifi.h"
#include "esp_http_server.h"
#include "esp_system.h"
#include "esp_random.h"
#include "esp_timer.h"
#include "driver/gpio.h"
#include "nvs_flash.h"
#include "nvs.h"
#include "os/os_mbuf.h"
#include "mdns.h"
#include "cJSON.h"
#include "wifi_config.h"
#include "nimble/nimble_port.h"
#include "nimble/nimble_port_freertos.h"
#include "host/ble_hs.h"
#include "host/ble_gap.h"
#include "host/ble_gatt.h"
#include "host/ble_store.h"
#include "services/gap/ble_svc_gap.h"
#include "services/gatt/ble_svc_gatt.h"
#include "services/hid/ble_svc_hid.h"
#include "store/config/ble_store_config.h"
void ble_store_config_init(void);

#define MAX_PEERS 2
#define FW_VERSION "2026-10-21-retry-5"
#define COMMAND_DEPTH 8
#define PEER_NAME_BYTES 97
#define RECONNECT_INTERVAL_S 30
#define RECONNECT_ADV_PAUSE_MS 200
static const char *TAG = "bt-wakeup";

typedef struct {
    bool used, encrypted, bonded, subscribed, security_requested;
    uint32_t connected_ms;
    uint16_t conn;
    uint32_t generation;
    ble_addr_t identity;
    char address[18];
    char name[PEER_NAME_BYTES], name_buffer[PEER_NAME_BYTES];
    uint16_t name_handle, name_length;
    uint8_t name_phase, name_attempts;
    uint32_t name_next_ms;
    int name_error;
    bool name_fresh, name_needs_save;
} peer_t;
typedef struct {
    char address[18];
    uint8_t type;
    bool ltk, irk;
    char name[PEER_NAME_BYTES];
    uint32_t last_disconnect_s, disconnect_count;
    int disconnect_reason;
} bond_t;
typedef struct {
    bool synced, pairing, advertising, wake_busy;
    int adv_error, bond_count, last_disconnect;
    uint32_t pairing_changed_s;
    uint32_t reconnect_attempts, last_reconnect_s, next_reconnect_s;
    int reconnect_error;
    char reconnect_reason[16];
    char pairing_reason[32], result[128];
    peer_t peers[MAX_PEERS];
    bond_t bonds[MAX_PEERS];
} state_t;
typedef enum {CMD_PAIR, CMD_CLOSE, CMD_WAKE, CMD_RECONNECT} command_kind_t;
typedef struct { command_kind_t kind; int slot; uint32_t generation; } command_t;

/* Only the NimBLE host mutates state. Other tasks read a complete snapshot. */
static state_t state, snapshot;
static portMUX_TYPE snapshot_lock = portMUX_INITIALIZER_UNLOCKED;
static QueueHandle_t commands;
static struct ble_npl_callout pump_timer, adv_timer, wake_timer;
static bool bonds_dirty;
static uint8_t own_addr_type;
static uint16_t input_handle;
static uint32_t next_generation;
static uint32_t adv_resume_ms;
static bool adv_pause;
/* NimBLE can restore CCCDs before delivering the application's CONNECT event. */
static struct { bool used, notify; uint16_t conn; } pending_subscriptions[MAX_PEERS];
static void clear_pending_subscription(uint16_t conn) {
    for (int i = 0; i < MAX_PEERS; i++)
        if (pending_subscriptions[i].used && pending_subscriptions[i].conn == conn)
            memset(&pending_subscriptions[i], 0, sizeof(pending_subscriptions[i]));
}
static void remember_pending_subscription(uint16_t conn, bool notify) {
    int slot = -1;
    for (int i = 0; i < MAX_PEERS; i++) {
        if (pending_subscriptions[i].used && pending_subscriptions[i].conn == conn) { slot = i; break; }
        if (!pending_subscriptions[i].used) slot = i;
    }
    if (slot >= 0) {
        pending_subscriptions[slot].used = true;
        pending_subscriptions[slot].conn = conn;
        pending_subscriptions[slot].notify = notify;
    }
}
static bool take_pending_subscription(uint16_t conn) {
    bool notify = false;
    for (int i = 0; i < MAX_PEERS; i++)
        if (pending_subscriptions[i].used && pending_subscriptions[i].conn == conn)
            notify = pending_subscriptions[i].notify;
    clear_pending_subscription(conn);
    return notify;
}
static httpd_handle_t server;
static bool mdns_ready;
static esp_reset_reason_t reset_reason;
static nvs_handle_t names_nvs;
static bool names_nvs_ready;
static void read_cached_name(const ble_addr_t *address, char *name);
static void poll_peer_names(void);
static struct {
    int phase, count;
    uint16_t conn[MAX_PEERS];
    uint32_t generation[MAX_PEERS];
    unsigned presses, releases, failed;
    bool key_down[MAX_PEERS];
} wake;
static int gap_event(struct ble_gap_event *ev, void *arg);
static void update_peer(peer_t *p, const struct ble_gap_conn_desc *d);

static const uint8_t keyboard_map[] = {
    0x05,0x01, 0x09,0x06, 0xA1,0x01, 0x85,0x01,
    0x05,0x07, 0x19,0xE0, 0x29,0xE7, 0x15,0x00, 0x25,0x01,
    0x75,0x01, 0x95,0x08, 0x81,0x02, 0x95,0x01, 0x75,0x08,
    0x81,0x01, 0x95,0x06, 0x75,0x08, 0x15,0x00, 0x25,0x65,
    0x05,0x07, 0x19,0x00, 0x29,0x65, 0x81,0x00, 0xC0
};

static uint32_t uptime_s(void) { return (uint32_t)(esp_timer_get_time() / 1000000); }
static void publish(void) {
    portENTER_CRITICAL(&snapshot_lock);
    snapshot = state;
    portEXIT_CRITICAL(&snapshot_lock);
}
static state_t read_snapshot(void) {
    state_t copy;
    portENTER_CRITICAL(&snapshot_lock);
    copy = snapshot;
    portEXIT_CRITICAL(&snapshot_lock);
    return copy;
}
static void result(const char *message) {
    strlcpy(state.result, message, sizeof(state.result));
    ESP_LOGI(TAG, "%s", message);
}
static void format_addr(const ble_addr_t *a, char out[18]) {
    snprintf(out, 18, "%02X:%02X:%02X:%02X:%02X:%02X",
             a->val[5], a->val[4], a->val[3], a->val[2], a->val[1], a->val[0]);
}
static bool addr_equal(const ble_addr_t *a, const ble_addr_t *b) {
    return a->type == b->type && memcmp(a->val, b->val, 6) == 0;
}
static peer_t *find_peer(uint16_t conn) {
    for (int i = 0; i < MAX_PEERS; i++)
        if (state.peers[i].used && state.peers[i].conn == conn) return &state.peers[i];
    return NULL;
}
static bool ready(const peer_t *p) {
    return p->used && p->encrypted && p->bonded && p->subscribed && input_handle;
}
static void refresh_bonds(void) {
    ble_addr_t addresses[MAX_PEERS];
    int count = 0;
    int rc = ble_store_util_bonded_peers(addresses, &count, MAX_PEERS);
    if (rc) { ESP_LOGE(TAG, "Enumerate bonds: %d", rc); return; }
    bond_t previous[MAX_PEERS];
    memcpy(previous, state.bonds, sizeof(previous));
    memset(state.bonds, 0, sizeof(state.bonds));
    state.bond_count = count;
    for (int i = 0; i < count; i++) {
        bond_t *b = &state.bonds[i];
        format_addr(&addresses[i], b->address);
        b->type = addresses[i].type;
        for (int j = 0; j < MAX_PEERS; j++) {
            if (previous[j].type == b->type && !strcmp(previous[j].address, b->address)) {
                b->last_disconnect_s = previous[j].last_disconnect_s;
                b->disconnect_reason = previous[j].disconnect_reason;
                b->disconnect_count = previous[j].disconnect_count;
                break;
            }
        }
        struct ble_store_key_sec key = {.peer_addr = addresses[i]};
        struct ble_store_value_sec ours = {0}, theirs = {0};
        ble_store_read_our_sec(&key, &ours);
        ble_store_read_peer_sec(&key, &theirs);
        b->ltk = ours.ltk_present || theirs.ltk_present;
        b->irk = theirs.irk_present;
        read_cached_name(&addresses[i], b->name);
    }
    bonds_dirty = false;
}
/* Cache is independent of the BLE security store. Never write unchanged names. */
static void name_key(const ble_addr_t *address, char key[16]) {
    snprintf(key, 16, "n%X%02X%02X%02X%02X%02X%02X", address->type,
             address->val[5], address->val[4], address->val[3],
             address->val[2], address->val[1], address->val[0]);
}
static void read_cached_name(const ble_addr_t *address, char *name) {
    name[0] = 0;
    if (!names_nvs_ready) return;
    char key[16]; name_key(address, key);
    size_t length = PEER_NAME_BYTES;
    if (nvs_get_str(names_nvs, key, name, &length) != ESP_OK) name[0] = 0;
}
/* Copy complete UTF-8 codepoints; reject control bytes and malformed sequences. */
static void clean_name(const char *input, size_t length, char out[PEER_NAME_BYTES]) {
    size_t pos = 0, used = 0;
    while (pos < length && used < PEER_NAME_BYTES - 1) {
        unsigned char c = (unsigned char)input[pos];
        size_t n = c < 0x80 ? 1 : c >= 0xc2 && c <= 0xdf ? 2 :
                   c >= 0xe0 && c <= 0xef ? 3 : c >= 0xf0 && c <= 0xf4 ? 4 : 0;
        if (!c) break;
        if (!n) { pos++; continue; }
        if (pos + n > length || used + n > PEER_NAME_BYTES - 1) break;
        bool valid = true;
        for (size_t j = 1; j < n; j++)
            if (((unsigned char)input[pos+j] & 0xc0) != 0x80) valid = false;
        unsigned char second = n > 1 ? (unsigned char)input[pos+1] : 0;
        if ((c == 0xe0 && second < 0xa0) || (c == 0xed && second >= 0xa0) ||
            (c == 0xf0 && second < 0x90) || (c == 0xf4 && second >= 0x90)) valid = false;
        if (!valid) { pos++; continue; }
        if (c >= 0x20 && c != 0x7f) { memcpy(out + used, input + pos, n); used += n; }
        pos += n;
    }
    while (used && out[used-1] == ' ') used--;
    out[used] = 0;
}
static peer_t *name_peer(uint16_t conn, void *arg) {
    peer_t *p = find_peer(conn);
    return p && p->generation == (uint32_t)(uintptr_t)arg ? p : NULL;
}
static int name_value(uint16_t conn, const struct ble_gatt_error *error,
                      struct ble_gatt_attr *attr, void *arg) {
    peer_t *p = name_peer(conn, arg);
    if (!p) return BLE_HS_EDONE;
    if (!error->status && attr && attr->om) {
        size_t offset = attr->offset;
        if (offset < PEER_NAME_BYTES - 1) {
            size_t count = OS_MBUF_PKTLEN(attr->om);
            if (count > PEER_NAME_BYTES - 1 - offset) count = PEER_NAME_BYTES - 1 - offset;
            if (!os_mbuf_copydata(attr->om, 0, count, p->name_buffer + offset) &&
                offset + count > p->name_length) p->name_length = offset + count;
        }
        return 0;
    }
    p->name_phase = 4;
    p->name_error = error->status == BLE_HS_EDONE ? 0 : error->status;
    if (!p->name_error && p->name_length) {
        char cleaned[PEER_NAME_BYTES] = {0};
        clean_name(p->name_buffer, p->name_length, cleaned);
        if (cleaned[0]) {
            strlcpy(p->name, cleaned, sizeof(p->name));
            p->name_fresh = true;
            p->name_needs_save = true;
            ESP_LOGI(TAG, "BLE Device Name %s: %s", p->address, p->name);
        }
    }
    if (!p->name_fresh) ESP_LOGI(TAG, "BLE Device Name unavailable for %s rc=%d", p->address, p->name_error);
    publish();
    return 0;
}
static int name_located(uint16_t conn, const struct ble_gatt_error *error,
                        struct ble_gatt_attr *attr, void *arg) {
    peer_t *p = name_peer(conn, arg);
    if (!p) return BLE_HS_EDONE;
    if (!error->status && attr) {
        p->name_handle = attr->handle;
        p->name_phase = 2; /* Start long read in a later host event. */
        return BLE_HS_EDONE;
    }
    p->name_phase = 4;
    p->name_error = error->status;
    ESP_LOGI(TAG, "BLE Device Name lookup %s rc=%d", p->address, p->name_error);
    publish();
    return 0;
}
static void poll_peer_names(void) {
    if (state.wake_busy) return;
    uint32_t now = (uint32_t)(esp_timer_get_time() / 1000);
    for (int i = 0; i < MAX_PEERS; i++) {
        peer_t *p = &state.peers[i];
        if (!p->used || !p->encrypted || !p->bonded) continue;
        if (p->name_needs_save && names_nvs_ready) {
            p->name_needs_save = false;
            char previous[PEER_NAME_BYTES], key[16];
            read_cached_name(&p->identity, previous);
            if (strcmp(previous, p->name)) {
                name_key(&p->identity, key);
                esp_err_t rc = nvs_set_str(names_nvs, key, p->name);
                if (rc == ESP_OK) rc = nvs_commit(names_nvs);
                if (rc == ESP_OK) bonds_dirty = true;
                else ESP_LOGE(TAG, "Cannot persist device name: %s", esp_err_to_name(rc));
            }
        }
        if (!ready(p) || now - p->connected_ms < 1500 || (p->name_next_ms && (int32_t)(now - p->name_next_ms) < 0)) continue;
        int rc = 0;
        void *arg = (void *)(uintptr_t)p->generation;
        if (p->name_phase == 0) {
            ble_uuid16_t uuid = BLE_UUID16_INIT(0x2a00);
            p->name_phase = 1;
            p->name_attempts++;
            rc = ble_gattc_read_by_uuid(p->conn, 1, 0xffff, (ble_uuid_t *)&uuid, name_located, arg);
        } else if (p->name_phase == 2) {
            p->name_phase = 3;
            p->name_length = 0;
            memset(p->name_buffer, 0, sizeof(p->name_buffer));
            rc = ble_gattc_read_long(p->conn, p->name_handle, 0, name_value, arg);
        }
        if (rc) {
            p->name_error = rc;
            if ((rc == BLE_HS_EBUSY || rc == BLE_HS_ENOMEM || rc == BLE_HS_EAGAIN) && p->name_attempts < 3) {
                p->name_phase = 0;
                p->name_next_ms = now + 1000;
            } else p->name_phase = 4;
            ESP_LOGI(TAG, "Device Name request %s rc=%d", p->address, rc);
        }
    }
}

static bool known_peer(const ble_addr_t *address) {
    ble_addr_t addresses[MAX_PEERS]; int count = 0;
    if (ble_store_util_bonded_peers(addresses, &count, MAX_PEERS)) return false;
    for (int i = 0; i < count; i++) if (addr_equal(address, &addresses[i])) return true;
    return false;
}
static int store_write(int type, const union ble_store_value *value) {
    int rc = ble_store_config_write(type, value);
    if (!rc) bonds_dirty = true;
    else ESP_LOGE(TAG, "Bond store write type=%d rc=%d", type, rc);
    return rc;
}
static int store_delete(int type, const union ble_store_key *key) {
    int rc = ble_store_config_delete(type, key);
    if (!rc) bonds_dirty = true;
    return rc;
}
static int store_status(struct ble_store_status_event *ev, void *arg) {
    (void)arg;
    if (ev->event_code == BLE_STORE_EVENT_FULL) return 0;
    /* Never silently evict either Mac, including on CCCD overflow. */
    if (ev->event_code == BLE_STORE_EVENT_OVERFLOW) {
        result("Bond storage full; saved devices were preserved");
        publish();
        return BLE_HS_ENOMEM;
    }
    return BLE_HS_EUNKNOWN;
}
static void schedule_adv(uint32_t delay_ms) {
    if (state.synced)
        ble_npl_callout_reset(&adv_timer, ble_npl_time_ms_to_ticks32(delay_ms));
}
static void advertise(struct ble_npl_event *event) {
    (void)event;
    if (!state.synced) return;
    if (adv_pause) {
        int32_t remaining = (int32_t)(adv_resume_ms - (uint32_t)(esp_timer_get_time() / 1000));
        if (remaining > 0) { schedule_adv((uint32_t)remaining); return; }
        adv_pause = false;
    }
    /* An existing procedure must not be reconfigured. */
    if (ble_gap_adv_active()) {
        state.advertising = true;
        publish();
        return;
    }
    state.advertising = false;
    int connected = 0;
    for (int i = 0; i < MAX_PEERS; i++) connected += state.peers[i].used;
    if (connected == MAX_PEERS) { publish(); return; }

    struct ble_gap_adv_params params = {0};
    params.conn_mode = BLE_GAP_CONN_MODE_UND;
    params.disc_mode = BLE_GAP_DISC_MODE_GEN;
    params.itvl_min = BLE_GAP_ADV_ITVL_MS(20);
    params.itvl_max = BLE_GAP_ADV_ITVL_MS(20);
    int rc;
    if (!state.pairing) {
        ble_addr_t addresses[MAX_PEERS]; int count = 0;
        rc = ble_store_util_bonded_peers(addresses, &count, MAX_PEERS);
        if (rc) goto failed;
        if (!count) { publish(); return; }
        rc = ble_gap_wl_set(addresses, count);
        if (rc) goto failed;
        params.filter_policy = BLE_HCI_ADV_FILT_CONN;
    }
    struct ble_hs_adv_fields fields = {0};
    const char name[] = "BT-Wakeup";
    ble_uuid16_t hid_uuid = BLE_UUID16_INIT(BLE_SVC_HID_UUID16);
    fields.flags = BLE_HS_ADV_F_DISC_GEN | BLE_HS_ADV_F_BREDR_UNSUP;
    fields.name = (uint8_t *)name;
    fields.name_len = sizeof(name) - 1;
    fields.name_is_complete = 1;
    fields.uuids16 = &hid_uuid;
    fields.num_uuids16 = 1;
    fields.uuids16_is_complete = 1;
    fields.appearance = 0x03C1;
    fields.appearance_is_present = 1;
    rc = ble_gap_adv_set_fields(&fields);
    if (rc) goto failed;
    rc = ble_gap_adv_start(own_addr_type, NULL, BLE_HS_FOREVER, &params, gap_event, NULL);
    if (rc) goto failed;
    state.advertising = true;
    state.adv_error = 0;
    publish();
    return;
failed:
    state.adv_error = rc;
    ESP_LOGE(TAG, "Advertising failed rc=%d; retry in 1s", rc);
    publish();
    schedule_adv(1000);
}
/* Refresh only advertising: connected peers and their security stay intact. */
static int missing_bonds(void) {
    int missing = 0;
    for (int i = 0; i < state.bond_count; i++) {
        bool connected = false;
        for (int j = 0; j < MAX_PEERS; j++) {
            peer_t *p = &state.peers[j];
            if (p->used && p->identity.type == state.bonds[i].type &&
                !strcmp(p->address, state.bonds[i].address)) connected = true;
        }
        if (!connected) missing++;
    }
    return missing;
}
static void refresh_reconnect_advertising(const char *reason) {
    if (!state.synced || state.pairing || state.wake_busy || !missing_bonds()) return;
    state.reconnect_attempts++;
    state.last_reconnect_s = uptime_s();
    state.next_reconnect_s = state.last_reconnect_s + RECONNECT_INTERVAL_S;
    strlcpy(state.reconnect_reason, reason, sizeof(state.reconnect_reason));
    int rc = ble_gap_adv_stop();
    state.reconnect_error = rc == BLE_HS_EALREADY ? 0 : rc;
    if (state.reconnect_error) {
        ESP_LOGW(TAG, "Reconnect advertising stop failed rc=%d", rc);
        return;
    }
    state.advertising = false;
    adv_pause = true;
    adv_resume_ms = (uint32_t)(esp_timer_get_time() / 1000) + RECONNECT_ADV_PAUSE_MS;
    schedule_adv(RECONNECT_ADV_PAUSE_MS);
    ESP_LOGI(TAG, "Reconnect retry #%" PRIu32 " reason=%s missing=%d; refreshing advertising only",
             state.reconnect_attempts, reason, missing_bonds());
    if (!strcmp(reason, "web")) result("Connection retry started; waiting for saved Macs to reconnect");
}
static void poll_reconnect(void) {
    if (!state.synced || state.pairing || !missing_bonds()) {
        state.next_reconnect_s = 0;
        return;
    }
    uint32_t now = uptime_s();
    if (!state.next_reconnect_s) state.next_reconnect_s = now + RECONNECT_INTERVAL_S;
    if ((int32_t)(now - state.next_reconnect_s) >= 0 && !state.wake_busy)
        refresh_reconnect_advertising("automatic");
}

static void set_pairing(bool open) {
    if (state.pairing == open) {
        result("Pairing mode already set");
        schedule_adv(20);
        return;
    }
    int rc = ble_gap_adv_stop();
    if (rc && rc != BLE_HS_EALREADY) {
        state.adv_error = rc;
        result("Cannot stop advertising; pairing mode unchanged");
        return;
    }
    state.advertising = false;
    state.pairing = open;
    adv_pause = false;
    state.next_reconnect_s = 0;
    state.pairing_changed_s = uptime_s();
    strlcpy(state.pairing_reason, open ? "web_open" : "web_close", sizeof(state.pairing_reason));
    result(open ? "Pairing opened from web UI" : "Pairing closed from web UI");
    /* Separate host event: never restart inline after ble_gap_adv_stop(). */
    schedule_adv(20);
}

static int notify_key(peer_t *p, bool press) {
    uint8_t report[8] = {0};
    report[0] = press ? 0x02 : 0;
    struct os_mbuf *om = ble_hs_mbuf_from_flat(report, sizeof(report));
    if (!om) return BLE_HS_ENOMEM;
    return ble_gatts_notify_custom(p->conn, input_handle, om);
}
static void wake_step(struct ble_npl_event *event) {
    (void)event;
    if (!state.wake_busy) return;
    bool press = !(wake.phase & 1);
    for (int i = 0; i < wake.count; i++) {
        peer_t *p = find_peer(wake.conn[i]);
        if (!p || p->generation != wake.generation[i]) {
            wake.key_down[i] = false; /* Original connection is gone. */
            wake.failed++;
            continue;
        }
        if (!ready(p)) {
            if (wake.key_down[i]) {
                /* Subscription/encryption changed after a successful press. */
                ble_gap_terminate(p->conn, BLE_ERR_REM_USER_CONN_TERM);
                wake.key_down[i] = false;
            }
            wake.failed++;
            continue;
        }
        int rc = notify_key(p, press);
        if (rc) {
            wake.failed++;
            ESP_LOGW(TAG, "HID %s failed conn=%u rc=%d", press ? "press" : "release", p->conn, rc);
            /* A failed release must not leave a live link holding Shift. */
            if (!press) {
                if (notify_key(p, false)) ble_gap_terminate(p->conn, BLE_ERR_REM_USER_CONN_TERM);
            }
        } else if (press) { wake.presses++; wake.key_down[i] = true; }
        else { wake.releases++; wake.key_down[i] = false; }
    }
    wake.phase++;
    if (wake.phase < 10) {
        int timer_rc = ble_npl_callout_reset(&wake_timer, ble_npl_time_ms_to_ticks32(press ? 100 : 400));
        if (timer_rc) {
            for (int i = 0; i < wake.count; i++) {
                peer_t *p = find_peer(wake.conn[i]);
                if (p && p->generation == wake.generation[i] && wake.key_down[i]) {
                    if (notify_key(p, false)) ble_gap_terminate(p->conn, BLE_ERR_REM_USER_CONN_TERM);
                }
            }
            state.wake_busy = false;
            result("Wake aborted: timer scheduling failed; keys released or links terminated");
            publish();
        }
    } else {
        state.wake_busy = false;
        snprintf(state.result, sizeof(state.result),
                 "Wake finished: presses=%u releases=%u errors=%u (delivery to BLE stack)",
                 wake.presses, wake.releases, wake.failed);
        ESP_LOGI(TAG, "%s", state.result);
        publish();
    }
}
static void start_wake(const command_t *cmd) {
    if (state.wake_busy) { result("Wake rejected: another sequence is running"); return; }
    memset(&wake, 0, sizeof(wake));
    for (int i = 0; i < MAX_PEERS; i++) {
        peer_t *p = &state.peers[i];
        if (cmd->slot >= 0 && (i != cmd->slot || p->generation != cmd->generation)) continue;
        if (!ready(p)) continue;
        wake.conn[wake.count] = p->conn;
        wake.generation[wake.count++] = p->generation;
    }
    if (!wake.count) { result("Wake rejected: no ready target or connection changed"); return; }
    state.wake_busy = true;
    result("Wake started: 5 Shift taps, 500ms between presses");
    wake_step(NULL);
}
static void pump(struct ble_npl_event *event) {
    (void)event;
    if (!state.synced) return;
    if (bonds_dirty) refresh_bonds();
    /* Give the central time to restore encryption before requesting security.
       Sending a second request on an already encrypted link can time out. */
    for (int i = 0; i < MAX_PEERS; i++) {
        peer_t *p = &state.peers[i];
        if (!p->used || p->encrypted || p->security_requested) continue;
        if ((uint32_t)(esp_timer_get_time() / 1000) - p->connected_ms < 1000) continue;
        struct ble_gap_conn_desc d;
        if (ble_gap_conn_find(p->conn, &d)) continue;
        update_peer(p, &d);
        if (p->encrypted) continue;
        p->security_requested = true;
        uint16_t conn = p->conn;
        int rc = ble_gap_security_initiate(conn);
        if (rc && rc != BLE_HS_EALREADY) {
            result("Cannot start BLE security; disconnecting unencrypted link");
            ble_gap_terminate(conn, BLE_ERR_REM_USER_CONN_TERM);
        }
    }
    poll_peer_names();
    command_t cmd;
    for (int i = 0; i < COMMAND_DEPTH && xQueueReceive(commands, &cmd, 0) == pdTRUE; i++) {
        if (cmd.kind == CMD_PAIR) set_pairing(true);
        else if (cmd.kind == CMD_CLOSE) set_pairing(false);
        else if (cmd.kind == CMD_RECONNECT) {
            if (!missing_bonds()) result("All saved Macs are already connected");
            else if (state.wake_busy || state.pairing) result("Connection retry postponed: wake or pairing is active");
            else refresh_reconnect_advertising("web");
        } else start_wake(&cmd);
    }
    poll_reconnect();
    publish();
    ble_npl_callout_reset(&pump_timer, ble_npl_time_ms_to_ticks32(20));
}
static void update_peer(peer_t *p, const struct ble_gap_conn_desc *d) {
    p->identity = d->peer_id_addr;
    format_addr(&d->peer_id_addr, p->address);
    p->encrypted = d->sec_state.encrypted;
    p->bonded = d->sec_state.bonded;
}
static int gap_event(struct ble_gap_event *ev, void *arg) {
    (void)arg;
    if (ev->type == BLE_GAP_EVENT_CONNECT) {
        state.advertising = false;
        if (!ev->connect.status) {
            struct ble_gap_conn_desc d;
            int rc = ble_gap_conn_find(ev->connect.conn_handle, &d);
            peer_t *p = NULL;
            for (int i = 0; i < MAX_PEERS; i++) if (!state.peers[i].used) { p = &state.peers[i]; break; }
            bool known = !rc && known_peer(&d.peer_id_addr);
            refresh_bonds();
            if (rc || !p || (!state.pairing && !known) ||
                (!known && state.bond_count >= MAX_PEERS)) {
                result("Connection rejected: pairing closed or bond storage full");
                ble_gap_terminate(ev->connect.conn_handle, BLE_ERR_REM_USER_CONN_TERM);
            } else {
                memset(p, 0, sizeof(*p));
                p->used = true;
                p->conn = ev->connect.conn_handle;
                p->subscribed = take_pending_subscription(p->conn);
                p->generation = ++next_generation;
                if (!p->generation) p->generation = ++next_generation;
                update_peer(p, &d);
                read_cached_name(&p->identity, p->name);
                p->connected_ms = (uint32_t)(esp_timer_get_time() / 1000);
                ESP_LOGI(TAG, "Connected %s handle=%u generation=%" PRIu32 " encrypted=%d",
                         p->address, p->conn, p->generation, p->encrypted);
            }
        } else ESP_LOGW(TAG, "Connection failed: %d", ev->connect.status);
        schedule_adv(20);
    } else if (ev->type == BLE_GAP_EVENT_DISCONNECT) {
        peer_t *p = find_peer(ev->disconnect.conn.conn_handle);
        char address[18];
        format_addr(&ev->disconnect.conn.peer_id_addr, address);
        for (int i = 0; i < state.bond_count; i++) {
            bond_t *b = &state.bonds[i];
            if (b->type == ev->disconnect.conn.peer_id_addr.type && !strcmp(b->address, address)) {
                b->last_disconnect_s = uptime_s();
                b->disconnect_reason = ev->disconnect.reason;
                b->disconnect_count++;
            }
        }
        ESP_LOGW(TAG, "Peer %s disconnected at uptime=%" PRIu32 " reason=%d",
                 address, uptime_s(), ev->disconnect.reason);
        state.next_reconnect_s = 0;
        if (p) memset(p, 0, sizeof(*p));
        clear_pending_subscription(ev->disconnect.conn.conn_handle);
        state.last_disconnect = ev->disconnect.reason;
        ESP_LOGW(TAG, "Disconnected handle=%u reason=%d", ev->disconnect.conn.conn_handle, ev->disconnect.reason);
        bonds_dirty = true;
        schedule_adv(20);
    } else if (ev->type == BLE_GAP_EVENT_ENC_CHANGE || ev->type == BLE_GAP_EVENT_IDENTITY_RESOLVED) {
        uint16_t conn = ev->type == BLE_GAP_EVENT_ENC_CHANGE ? ev->enc_change.conn_handle : ev->identity_resolved.conn_handle;
        peer_t *p = find_peer(conn);
        struct ble_gap_conn_desc d;
        if (p && !ble_gap_conn_find(conn, &d)) update_peer(p, &d);
        bonds_dirty = true;
        if (ev->type == BLE_GAP_EVENT_ENC_CHANGE) {
            ESP_LOGI(TAG, "Security conn=%u status=%d encrypted=%d bonded=%d", conn,
                     ev->enc_change.status, p ? p->encrypted : 0, p ? p->bonded : 0);
            if (ev->enc_change.status && (!p || !p->encrypted)) {
                result("Encryption failed on unencrypted link; disconnected");
                ble_gap_terminate(conn, BLE_ERR_REM_USER_CONN_TERM);
            } else if (ev->enc_change.status) {
                ESP_LOGW(TAG, "Security procedure failed but link is encrypted; retaining conn=%u", conn);
            }
        }
    } else if (ev->type == BLE_GAP_EVENT_SUBSCRIBE) {
        peer_t *p = find_peer(ev->subscribe.conn_handle);
        if (ev->subscribe.attr_handle == input_handle) {
            if (p) p->subscribed = ev->subscribe.cur_notify;
            else remember_pending_subscription(ev->subscribe.conn_handle, ev->subscribe.cur_notify);
        }
        ESP_LOGI(TAG, "Subscribe conn=%u attr=%u notify=%d reason=%u",
                 ev->subscribe.conn_handle, ev->subscribe.attr_handle, ev->subscribe.cur_notify, ev->subscribe.reason);
    } else if (ev->type == BLE_GAP_EVENT_REPEAT_PAIRING) {
        struct ble_gap_conn_desc d;
        int rc = ble_gap_conn_find(ev->repeat_pairing.conn_handle, &d);
        if (!rc && state.pairing) {
            rc = ble_store_util_delete_peer(&d.peer_id_addr);
            bonds_dirty = true;
            result(rc ? "Cannot replace stale bond" : "Replacing requesting peer's stale bond");
            return rc ? BLE_GAP_REPEAT_PAIRING_IGNORE : BLE_GAP_REPEAT_PAIRING_RETRY;
        }
        result("Repeat pairing rejected: pairing mode is closed");
        return BLE_GAP_REPEAT_PAIRING_IGNORE;
    } else if (ev->type == BLE_GAP_EVENT_ADV_COMPLETE) {
        state.advertising = false;
        schedule_adv(20);
    }
    publish();
    return 0;
}
static void ble_reset(int reason) {
    ble_npl_callout_stop(&pump_timer);
    ble_npl_callout_stop(&adv_timer);
    ble_npl_callout_stop(&wake_timer);
    memset(state.peers, 0, sizeof(state.peers));
    memset(pending_subscriptions, 0, sizeof(pending_subscriptions));
    state.synced = state.advertising = state.wake_busy = false;
    state.next_reconnect_s = 0;
    adv_pause = false;
    xQueueReset(commands);
    ESP_LOGE(TAG, "BLE host reset reason=%d; pairing=%d", reason, state.pairing);
    result("BLE host reset; waiting for synchronization");
    publish();
}
static void ble_sync(void) {
    int rc = ble_hs_id_infer_auto(0, &own_addr_type);
    if (rc) { result("Cannot initialize BLE identity"); publish(); return; }
    ble_uuid16_t service = BLE_UUID16_INIT(BLE_SVC_HID_UUID16);
    ble_uuid16_t report = BLE_UUID16_INIT(BLE_SVC_HID_CHR_UUID16_RPT);
    rc = ble_gatts_find_chr((ble_uuid_t *)&service, (ble_uuid_t *)&report, NULL, &input_handle);
    if (rc || !input_handle) { result("Cannot find HID input handle"); publish(); return; }
    state.synced = true;
    refresh_bonds();
    for (int i = 0; i < state.bond_count; i++)
        ESP_LOGI(TAG, "Bond %s LTK=%d peer_IRK=%d cached_name=%s", state.bonds[i].address, state.bonds[i].ltk, state.bonds[i].irk, state.bonds[i].name);
    /* Report-only HID removes Protocol Mode. Notify bonded clients to rediscover. */
    ble_svc_gatt_changed(1, 0xffff);
    ESP_LOGI(TAG, "BLE synced firmware=%s input_handle=%u pairing=%d", FW_VERSION, input_handle, state.pairing);
    schedule_adv(20);
    ble_npl_callout_reset(&pump_timer, ble_npl_time_ms_to_ticks32(20));
    publish();
}
static void ble_host_task(void *arg) { (void)arg; nimble_port_run(); nimble_port_freertos_deinit(); }

extern const unsigned char index_html_start[] asm("_binary_index_html_start");
static esp_err_t json_response(httpd_req_t *req, const char *status, const char *body) {
    httpd_resp_set_status(req, status);
    httpd_resp_set_type(req, "application/json; charset=utf-8");
    httpd_resp_set_hdr(req, "Cache-Control", "no-store");
    return httpd_resp_sendstr(req, body);
}
static esp_err_t root(httpd_req_t *req) {
    httpd_resp_set_type(req, "text/html; charset=utf-8");
    httpd_resp_set_hdr(req, "Cache-Control", "no-store");
    return httpd_resp_sendstr(req, (const char *)index_html_start);
}
static esp_err_t status_route(httpd_req_t *req) {
    state_t s = read_snapshot();
    char ip[20] = "unknown";
    esp_netif_ip_info_t info;
    esp_netif_t *net = esp_netif_get_handle_from_ifkey("WIFI_STA_DEF");
    if (net && esp_netif_get_ip_info(net, &info) == ESP_OK) snprintf(ip, sizeof(ip), IPSTR, IP2STR(&info.ip));
    cJSON *obj = cJSON_CreateObject();
    if (!obj) return json_response(req, "503 Service Unavailable", "{\"error\":\"out_of_memory\"}");
    cJSON_AddStringToObject(obj, "firmware", FW_VERSION);
    cJSON_AddStringToObject(obj, "ip", ip);
    cJSON_AddNumberToObject(obj, "uptime_s", uptime_s());
    cJSON_AddNumberToObject(obj, "reset_reason", reset_reason);
    cJSON_AddBoolToObject(obj, "ble_ready", s.synced);
    cJSON_AddBoolToObject(obj, "pairing", s.pairing);
    cJSON_AddStringToObject(obj, "pairing_reason", s.pairing_reason);
    cJSON_AddNumberToObject(obj, "pairing_changed_s", s.pairing_changed_s);
    cJSON_AddBoolToObject(obj, "advertising", s.advertising);
    cJSON_AddNumberToObject(obj, "advertising_error", s.adv_error);
    cJSON_AddBoolToObject(obj, "wake_busy", s.wake_busy);
    cJSON_AddStringToObject(obj, "last_result", s.result);
    cJSON_AddNumberToObject(obj, "last_disconnect_reason", s.last_disconnect);
    cJSON_AddNumberToObject(obj, "reconnect_interval_s", RECONNECT_INTERVAL_S);
    cJSON_AddNumberToObject(obj, "reconnect_attempts", s.reconnect_attempts);
    cJSON_AddNumberToObject(obj, "last_reconnect_s", s.last_reconnect_s);
    uint32_t now_s = uptime_s();
    cJSON_AddNumberToObject(obj, "reconnect_next_in_s", s.next_reconnect_s && (int32_t)(s.next_reconnect_s - now_s) > 0 ? s.next_reconnect_s - now_s : 0);
    cJSON_AddNumberToObject(obj, "reconnect_error", s.reconnect_error);
    cJSON_AddStringToObject(obj, "reconnect_reason", s.reconnect_reason);
    cJSON *paired = cJSON_AddArrayToObject(obj, "paired");
    cJSON *bonds = cJSON_AddArrayToObject(obj, "bonds");
    cJSON *devices = cJSON_AddArrayToObject(obj, "devices");
    for (int i = 0; i < s.bond_count; i++) {
        cJSON_AddItemToArray(paired, cJSON_CreateString(s.bonds[i].address));
        cJSON *b = cJSON_CreateObject();
        cJSON_AddStringToObject(b, "address", s.bonds[i].address);
        cJSON_AddNumberToObject(b, "type", s.bonds[i].type);
        cJSON_AddBoolToObject(b, "ltk", s.bonds[i].ltk);
        cJSON_AddBoolToObject(b, "irk", s.bonds[i].irk);
        cJSON_AddStringToObject(b, "name", s.bonds[i].name);
        cJSON_AddNumberToObject(b, "last_disconnect_s", s.bonds[i].last_disconnect_s);
        cJSON_AddNumberToObject(b, "disconnect_reason", s.bonds[i].disconnect_reason);
        cJSON_AddNumberToObject(b, "disconnect_count", s.bonds[i].disconnect_count);
        cJSON_AddItemToArray(bonds, b);
    }
    for (int i = 0; i < MAX_PEERS; i++) if (s.peers[i].used) {
        peer_t *p = &s.peers[i];
        cJSON *d = cJSON_CreateObject();
        cJSON_AddNumberToObject(d, "slot", i);
        cJSON_AddNumberToObject(d, "generation", p->generation);
        cJSON_AddStringToObject(d, "address", p->address);
        cJSON_AddStringToObject(d, "name", p->name);
        cJSON_AddStringToObject(d, "name_status", p->name_fresh ? "available" : p->name_phase == 4 ? "unavailable" : "pending");
        cJSON_AddBoolToObject(d, "name_cached", p->name[0] && !p->name_fresh);
        cJSON_AddNumberToObject(d, "name_error", p->name_error);
        cJSON_AddBoolToObject(d, "connected", true);
        cJSON_AddBoolToObject(d, "encrypted", p->encrypted);
        cJSON_AddBoolToObject(d, "bonded", p->bonded);
        cJSON_AddBoolToObject(d, "subscribed", p->subscribed);
        /* input_handle is fixed before BLE is published ready. */
        cJSON_AddBoolToObject(d, "ready", p->encrypted && p->bonded && p->subscribed && s.synced);
        cJSON_AddItemToArray(devices, d);
    }
    char *body = cJSON_PrintUnformatted(obj);
    cJSON_Delete(obj);
    if (!body) return json_response(req, "503 Service Unavailable", "{\"error\":\"out_of_memory\"}");
    esp_err_t rc = json_response(req, "200 OK", body);
    free(body);
    return rc;
}
static esp_err_t enqueue(httpd_req_t *req, command_t *cmd) {
    if (!read_snapshot().synced) return json_response(req, "503 Service Unavailable", "{\"error\":\"ble_not_ready\"}");
    if (xQueueSend(commands, cmd, 0) != pdTRUE)
        return json_response(req, "503 Service Unavailable", "{\"error\":\"command_queue_full\"}");
    return json_response(req, "202 Accepted", "{\"accepted\":true}");
}
static esp_err_t pair_route(httpd_req_t *req) { command_t cmd = {.kind = CMD_PAIR}; return enqueue(req, &cmd); }
static esp_err_t close_route(httpd_req_t *req) { command_t cmd = {.kind = CMD_CLOSE}; return enqueue(req, &cmd); }
static esp_err_t reconnect_route(httpd_req_t *req) {
    state_t s = read_snapshot();
    if (s.pairing) return json_response(req, "409 Conflict", "{\"error\":\"pairing_open\"}");
    if (s.wake_busy) return json_response(req, "409 Conflict", "{\"error\":\"wake_busy\"}");
    bool missing = false;
    for (int i = 0; i < s.bond_count; i++) {
        bool connected = false;
        for (int j = 0; j < MAX_PEERS; j++)
            if (s.peers[j].used && s.peers[j].identity.type == s.bonds[i].type &&
                !strcmp(s.peers[j].address, s.bonds[i].address)) connected = true;
        if (!connected) missing = true;
    }
    if (!missing) return json_response(req, "409 Conflict", "{\"error\":\"already_connected\"}");
    command_t cmd = {.kind = CMD_RECONNECT};
    return enqueue(req, &cmd);
}
static bool parse_uint(const char *text, unsigned long max, unsigned long *out) {
    if (!text || !*text) return false;
    for (const char *p = text; *p; p++) if (*p < '0' || *p > '9') return false;
    errno = 0; char *end;
    unsigned long n = strtoul(text, &end, 10);
    if (errno || *end || n > max) return false;
    *out = n;
    return true;
}
static esp_err_t wake_route(httpd_req_t *req) {
    state_t s = read_snapshot();
    if (s.wake_busy) return json_response(req, "409 Conflict", "{\"error\":\"wake_busy\"}");
    char query[96], id[16], generation[16];
    if (httpd_req_get_url_query_str(req, query, sizeof(query)) != ESP_OK ||
        httpd_query_key_value(query, "id", id, sizeof(id)) != ESP_OK)
        return json_response(req, "400 Bad Request", "{\"error\":\"id_required\"}");
    command_t cmd = {.kind = CMD_WAKE, .slot = -1};
    if (strcmp(id, "all")) {
        unsigned long slot, gen;
        if (!parse_uint(id, MAX_PEERS - 1, &slot) ||
            httpd_query_key_value(query, "generation", generation, sizeof(generation)) != ESP_OK ||
            !parse_uint(generation, UINT32_MAX, &gen))
            return json_response(req, "400 Bad Request", "{\"error\":\"invalid_target\"}");
        peer_t *p = &s.peers[slot];
        if (!p->used || p->generation != gen)
            return json_response(req, "409 Conflict", "{\"error\":\"connection_changed\"}");
        if (!p->encrypted || !p->bonded || !p->subscribed)
            return json_response(req, "409 Conflict", "{\"error\":\"hid_not_ready\"}");
        cmd.slot = slot;
        cmd.generation = gen;
    } else {
        bool any = false;
        for (int i = 0; i < MAX_PEERS; i++) any |= s.peers[i].used && s.peers[i].encrypted && s.peers[i].bonded && s.peers[i].subscribed;
        if (!any) return json_response(req, "409 Conflict", "{\"error\":\"no_ready_devices\"}");
    }
    return enqueue(req, &cmd);
}
static esp_err_t web_start(void) {
    if (server) return ESP_OK;
    httpd_config_t config = HTTPD_DEFAULT_CONFIG();
    config.max_uri_handlers = 8;
    config.stack_size = 8192;
    config.lru_purge_enable = true;
    esp_err_t rc = httpd_start(&server, &config);
    if (rc != ESP_OK) return rc;
    httpd_uri_t routes[] = {
        {.uri="/", .method=HTTP_GET, .handler=root},
        {.uri="/api/status", .method=HTTP_GET, .handler=status_route},
        {.uri="/api/pair", .method=HTTP_POST, .handler=pair_route},
        {.uri="/api/stop", .method=HTTP_POST, .handler=close_route},
        {.uri="/api/wake", .method=HTTP_POST, .handler=wake_route},
        {.uri="/api/reconnect", .method=HTTP_POST, .handler=reconnect_route}
    };
    for (size_t i = 0; i < sizeof(routes)/sizeof(routes[0]); i++) {
        rc = httpd_register_uri_handler(server, &routes[i]);
        if (rc != ESP_OK) { httpd_stop(server); server = NULL; return rc; }
    }
    return ESP_OK;
}
static void wifi_event(void *arg, esp_event_base_t base, int32_t id, void *data) {
    (void)arg;
    if (base == WIFI_EVENT && (id == WIFI_EVENT_STA_START || id == WIFI_EVENT_STA_DISCONNECTED)) {
        if (id == WIFI_EVENT_STA_DISCONNECTED) {
            wifi_event_sta_disconnected_t *d = data;
            ESP_LOGW(TAG, "Wi-Fi disconnected reason=%u", d->reason);
        }
        esp_err_t rc = esp_wifi_connect();
        if (rc != ESP_OK) ESP_LOGE(TAG, "Wi-Fi reconnect request failed: %s", esp_err_to_name(rc));
    } else if (base == IP_EVENT && id == IP_EVENT_STA_GOT_IP) {
        esp_err_t rc = ESP_OK;
        if (!mdns_ready) {
            rc = mdns_init();
            if (rc == ESP_OK) {
                rc = mdns_hostname_set("bt-wakeup");
                if (rc == ESP_OK) rc = mdns_instance_name_set("BT Wakeup");
                if (rc == ESP_OK) rc = mdns_service_add("BT Wakeup", "_http", "_tcp", 80, NULL, 0);
                if (rc == ESP_OK) mdns_ready = true;
                else mdns_free();
            }
        }
        if (rc != ESP_OK) ESP_LOGE(TAG, "mDNS initialization failed: %s", esp_err_to_name(rc));
        rc = web_start();
        if (rc == ESP_OK) ESP_LOGI(TAG, "Web UI ready at http://bt-wakeup.local");
        else ESP_LOGE(TAG, "HTTP initialization failed: %s", esp_err_to_name(rc));
    }
}
static void wifi_start(void) {
    ESP_ERROR_CHECK(esp_netif_init());
    ESP_ERROR_CHECK(esp_event_loop_create_default());
    esp_netif_create_default_wifi_sta();
    wifi_init_config_t config = WIFI_INIT_CONFIG_DEFAULT();
    ESP_ERROR_CHECK(esp_wifi_init(&config));
    /* Credentials come from the ignored header, not from repeated NVS writes. */
    ESP_ERROR_CHECK(esp_wifi_set_storage(WIFI_STORAGE_RAM));
    ESP_ERROR_CHECK(esp_event_handler_register(WIFI_EVENT, ESP_EVENT_ANY_ID, wifi_event, NULL));
    ESP_ERROR_CHECK(esp_event_handler_register(IP_EVENT, IP_EVENT_STA_GOT_IP, wifi_event, NULL));
    wifi_config_t wifi = {0};
    strlcpy((char *)wifi.sta.ssid, WIFI_SSID, sizeof(wifi.sta.ssid));
    strlcpy((char *)wifi.sta.password, WIFI_PASSWORD, sizeof(wifi.sta.password));
    wifi.sta.threshold.authmode = WIFI_AUTH_WPA2_PSK;
    ESP_ERROR_CHECK(esp_wifi_set_mode(WIFI_MODE_STA));
    ESP_ERROR_CHECK(esp_wifi_set_config(WIFI_IF_STA, &wifi));
    ESP_ERROR_CHECK(esp_wifi_start());
}
static void boot_button_task(void *arg) {
    (void)arg;
    for (;;) {
        if (!gpio_get_level(GPIO_NUM_0)) {
            vTaskDelay(pdMS_TO_TICKS(40));
            if (!gpio_get_level(GPIO_NUM_0)) {
                command_t cmd = {.kind = CMD_WAKE, .slot = -1};
                if (xQueueSend(commands, &cmd, 0) != pdTRUE) ESP_LOGW(TAG, "BOOT wake rejected: queue full");
                while (!gpio_get_level(GPIO_NUM_0)) vTaskDelay(pdMS_TO_TICKS(20));
                vTaskDelay(pdMS_TO_TICKS(40));
            }
        }
        vTaskDelay(pdMS_TO_TICKS(20));
    }
}
void app_main(void) {
    reset_reason = esp_reset_reason();
    next_generation = esp_random(); /* Reject stale UI targets across reboot, too. */
    strlcpy(state.pairing_reason, "boot", sizeof(state.pairing_reason));
    result("Boot: pairing closed; waiting for BLE synchronization");
    publish();
    ESP_LOGI(TAG, "Firmware %s reset_reason=%d", FW_VERSION, reset_reason);
    esp_err_t rc = nvs_flash_init();
    if (rc != ESP_OK) { ESP_LOGE(TAG, "NVS error %s; stored bonds preserved", esp_err_to_name(rc)); return; }
    esp_err_t name_rc = nvs_open("peer_names", NVS_READWRITE, &names_nvs);
    names_nvs_ready = name_rc == ESP_OK;
    if (!names_nvs_ready) ESP_LOGE(TAG, "Device name cache unavailable: %s", esp_err_to_name(name_rc));
    commands = xQueueCreate(COMMAND_DEPTH, sizeof(command_t));
    if (!commands) { ESP_LOGE(TAG, "Cannot allocate command queue"); return; }
    wifi_start();
    ESP_ERROR_CHECK(nimble_port_init());
    ble_store_config_init();
    ble_hs_cfg.store_write_cb = store_write;
    ble_hs_cfg.store_delete_cb = store_delete;
    ble_hs_cfg.store_status_cb = store_status;
    ble_hs_cfg.sync_cb = ble_sync;
    ble_hs_cfg.reset_cb = ble_reset;
    ble_hs_cfg.sm_our_key_dist = BLE_SM_PAIR_KEY_DIST_ENC | BLE_SM_PAIR_KEY_DIST_ID;
    ble_hs_cfg.sm_their_key_dist = BLE_SM_PAIR_KEY_DIST_ENC | BLE_SM_PAIR_KEY_DIST_ID;
    ble_hs_cfg.sm_bonding = 1;
    ble_hs_cfg.sm_mitm = 0;
    ble_hs_cfg.sm_io_cap = BLE_HS_IO_NO_INPUT_OUTPUT;
    ble_svc_gap_init();
    ble_svc_gatt_init();
    ble_svc_gap_device_name_set("BT-Wakeup");
    ble_svc_gap_device_appearance_set(0x03C1);
    struct ble_svc_hid_params hid = {0};
    hid.report_map_len = sizeof(keyboard_map);
    memcpy(hid.report_map, keyboard_map, sizeof(keyboard_map));
    hid.hid_info = 0x03000111; /* HID 1.11, RemoteWake + NormallyConnectable. */
    hid.proto_mode = 1; /* Report-only device; omit unsupported Boot Protocol. */
    hid.proto_mode_present = 0;
    hid.rpts_len = 1;
    hid.rpts[0].id = 1;
    hid.rpts[0].type = BLE_SVC_HID_RPT_TYPE_INPUT;
    hid.rpts[0].len = 8;
    int hid_rc = ble_svc_hid_add(hid);
    if (hid_rc) { ESP_LOGE(TAG, "HID initialization failed: %d", hid_rc); return; }
    ble_svc_hid_init();
    ble_npl_callout_init(&pump_timer, nimble_port_get_dflt_eventq(), pump, NULL);
    ble_npl_callout_init(&adv_timer, nimble_port_get_dflt_eventq(), advertise, NULL);
    ble_npl_callout_init(&wake_timer, nimble_port_get_dflt_eventq(), wake_step, NULL);
    gpio_config_t gpio = {.pin_bit_mask = 1ULL << GPIO_NUM_0, .mode = GPIO_MODE_INPUT,
                          .pull_up_en = GPIO_PULLUP_ENABLE, .intr_type = GPIO_INTR_DISABLE};
    ESP_ERROR_CHECK(gpio_config(&gpio));
    nimble_port_freertos_init(ble_host_task);
    if (xTaskCreate(boot_button_task, "boot_button", 2048, NULL, 4, NULL) != pdPASS)
        ESP_LOGE(TAG, "Cannot start BOOT task");
}
