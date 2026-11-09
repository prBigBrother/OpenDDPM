#!/usr/bin/env python3
"""Compile the firmware's actual retry policy with clock/radio stubs; no hardware writes."""
from pathlib import Path
import subprocess
import tempfile

source = (Path(__file__).resolve().parents[1] / 'main/main.c').read_text()
types = source[source.index('typedef struct {'):source.index('typedef enum {')]
policy = source[source.index('static int missing_bonds(void)'):source.index('static void set_pairing(bool open)')]
preamble = r'''
#include <stdbool.h>
#include <stdint.h>
#include <inttypes.h>
#include <string.h>
#include <stdio.h>
#include <assert.h>
#define MAX_PEERS 2
#define PEER_NAME_BYTES 97
#define RECONNECT_INTERVAL_S 30
#define RECONNECT_ADV_PAUSE_MS 200
#define BLE_HS_EALREADY 2
#define ESP_LOGI(...) ((void)0)
#define ESP_LOGW(...) ((void)0)
typedef struct {uint8_t type; uint8_t val[6];} ble_addr_t;
'''
stubs = r'''
static state_t state;
static uint32_t now, adv_resume_ms, scheduled_delay;
static bool adv_pause;
static int stops, stop_result;
static const char *TAG;
static uint32_t uptime_s(void) {return now;}
static int64_t esp_timer_get_time(void) {return (int64_t)now*1000000;}
static int ble_gap_adv_stop(void) {stops++;return stop_result;}
static void schedule_adv(uint32_t ms) {scheduled_delay=ms;}
static void result(const char *s) {(void)s;}
'''
checks = r'''
int main(void) {
 (void)TAG;
 state.synced=true;state.bond_count=2;
 strcpy(state.bonds[0].address,"A");strcpy(state.bonds[1].address,"B");
 state.peers[0].used=true;state.peers[0].conn=77;strcpy(state.peers[0].address,"A");
 assert(missing_bonds()==1);
 now=100;poll_reconnect();assert(state.next_reconnect_s==130 && stops==0);
 now=129;poll_reconnect();assert(stops==0);
 now=130;poll_reconnect();assert(stops==1 && state.reconnect_attempts==1 && state.next_reconnect_s==160);
 assert(adv_pause && scheduled_delay==200 && adv_resume_ms==130200);
 assert(state.peers[0].used && state.peers[0].conn==77);
 now=159;poll_reconnect();assert(stops==1);
 now=160;poll_reconnect();assert(stops==2);
 state.wake_busy=true;now=190;poll_reconnect();assert(stops==2);
 state.wake_busy=false;poll_reconnect();assert(stops==3);
 state.pairing=true;now=220;poll_reconnect();assert(stops==3 && state.next_reconnect_s==0);
 state.pairing=false;poll_reconnect();assert(state.next_reconnect_s==250);
 state.peers[1].used=true;state.peers[1].conn=88;strcpy(state.peers[1].address,"B");
 poll_reconnect();assert(missing_bonds()==0 && state.next_reconnect_s==0 && stops==3);
 refresh_reconnect_advertising("web");assert(stops==3);
 state.peers[1].used=false;refresh_reconnect_advertising("web");assert(stops==4);
 assert(!strcmp(state.reconnect_reason,"web"));
 assert(state.peers[0].used && state.peers[0].conn==77);
 stop_result=9;refresh_reconnect_advertising("web");assert(stops==5 && state.reconnect_error==9);
 state.synced=false;poll_reconnect();assert(state.next_reconnect_s==0 && stops==5);
 return 0;
}
'''
with tempfile.TemporaryDirectory(prefix='bt-retry-') as d:
    path=Path(d)/'retry.c'
    path.write_text(preamble+types+stubs+policy+checks)
    subprocess.run(['cc','-std=c11','-Wall','-Wextra','-Werror',str(path),'-o',str(Path(d)/'check')],check=True)
    subprocess.run([str(Path(d)/'check')],check=True)
print('PASS: 30s retry timing, 200ms pause, active-link preservation, wake/pairing gates, no-op when connected, and error handling')
