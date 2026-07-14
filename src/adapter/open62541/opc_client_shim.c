//  opc-diode -- a high-assurance Ada/SPARK OPC UA PubSub data-diode relay.
//  Copyright (C) 2026  Alin Anton <alin.anton@upt.ro>
//  SPDX-License-Identifier: AGPL-3.0-or-later

/*  opc_client_shim.c -- open62541 client behind the Ada Opc_Client interface.
 *  Same contract as the S2OPC shim (od_cli_*), different stack.  The client
 *  stack stays on the high side; only one-way UADP leaves.  Compiles against the
 *  open62541 amalgamation; end-to-end needs a live server to validate.
 */

#include <stdint.h>
#include <string.h>
#include <pthread.h>
#include "open62541.h"

#define OD_MAX_DS 1300
#define OD_RING   256

typedef struct { uint16_t wid; uint32_t len; uint8_t data[OD_MAX_DS]; } od_upd;
static od_upd g_ring[OD_RING];
static int g_head, g_tail;
static pthread_mutex_t g_lock = PTHREAD_MUTEX_INITIALIZER;

static UA_Client* g_client;
static UA_UInt32  g_sub_id;
static int g_ready;

static void push(uint16_t wid, const uint8_t* d, uint32_t n)
{
    if (n > OD_MAX_DS) n = OD_MAX_DS;
    pthread_mutex_lock(&g_lock);
    int nxt = (g_head + 1) % OD_RING;
    if (nxt != g_tail) {
        g_ring[g_head].wid = wid; g_ring[g_head].len = n;
        memcpy(g_ring[g_head].data, d, n); g_head = nxt;
    }
    pthread_mutex_unlock(&g_lock);
}

/* Data-change callback: encode the DataValue to OPC UA binary and buffer it. */
static void dc_cb(UA_Client* c, UA_UInt32 subId, void* subCtx,
                  UA_UInt32 monId, void* monCtx, UA_DataValue* value)
{
    (void) c; (void) subId; (void) subCtx; (void) monId;
    uint16_t wid = (uint16_t) (uintptr_t) monCtx;
    UA_ByteString buf = UA_BYTESTRING_NULL;
    if (UA_encodeBinary(value, &UA_TYPES[UA_TYPES_DATAVALUE], &buf, NULL) == UA_STATUSCODE_GOOD) {
        push(wid, buf.data, (uint32_t) buf.length);
        UA_ByteString_clear(&buf);
    }
}

int od_ua_init(const char* endpoint)
{
    if (g_ready) return 0;
    g_client = UA_Client_new();
    if (g_client == NULL) return -1;
    UA_ClientConfig_setDefault(UA_Client_getConfig(g_client));
    if (UA_Client_connect(g_client, endpoint) != UA_STATUSCODE_GOOD) return -1;

    UA_CreateSubscriptionRequest req = UA_CreateSubscriptionRequest_default();
    UA_CreateSubscriptionResponse resp =
        UA_Client_Subscriptions_create(g_client, req, NULL, NULL, NULL);
    if (resp.responseHeader.serviceResult != UA_STATUSCODE_GOOD) return -1;
    g_sub_id = resp.subscriptionId;
    g_ready = 1;
    return 0;
}

int od_ua_subscribe(const char* node, uint16_t wid)
{
    if (!g_ready || node == NULL) return -1;
    UA_NodeId nid;
    if (UA_NodeId_parse(&nid, UA_STRING((char*) node)) != UA_STATUSCODE_GOOD)
        return -1;
    UA_MonitoredItemCreateRequest mreq = UA_MonitoredItemCreateRequest_default(nid);
    UA_MonitoredItemCreateResult r = UA_Client_MonitoredItems_createDataChange(
        g_client, g_sub_id, UA_TIMESTAMPSTORETURN_BOTH, mreq,
        (void*) (uintptr_t) wid, dc_cb, NULL);
    UA_NodeId_clear(&nid);
    return (r.statusCode == UA_STATUSCODE_GOOD) ? 0 : -1;
}

int od_ua_poll(uint16_t* wid, uint8_t* out, int maxlen)
{
    /* pump the client so callbacks fire, then drain one entry */
    if (g_ready) UA_Client_run_iterate(g_client, 0);
    int len = 0;
    if (out == NULL || wid == NULL) return 0;
    pthread_mutex_lock(&g_lock);
    if (g_tail != g_head) {
        od_upd* u = &g_ring[g_tail];
        len = (int) u->len; if (len > maxlen) len = maxlen;
        *wid = u->wid; memcpy(out, u->data, (size_t) len);
        g_tail = (g_tail + 1) % OD_RING;
    }
    pthread_mutex_unlock(&g_lock);
    return len;
}

void od_ua_fini(void)
{
    if (!g_ready) return;
    UA_Client_disconnect(g_client);
    UA_Client_delete(g_client);
    g_ready = 0;
}
