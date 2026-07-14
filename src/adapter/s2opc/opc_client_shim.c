//  opc-diode -- a high-assurance Ada/SPARK OPC UA PubSub data-diode relay.
//  Copyright (C) 2026  Alin Anton <alin.anton@upt.ro>
//  SPDX-License-Identifier: AGPL-3.0-or-later

/*  opc_client_shim.c -- S2OPC client behind the Ada Opc_Client interface.
 *
 *  Connects to an OPC UA server, subscribes to variables, and on each data
 *  change encodes the SOPC_DataValue to OPC UA binary and buffers it in a
 *  mutex-protected ring.  Ada polls the ring (od_s2opc_poll) and frames each
 *  entry with the proven Uadp.Encode.  The whole client stack lives here, on
 *  the high side -- only one-way UADP leaves the process.
 *
 *  NOTE: compiles against S2OPC; end-to-end behaviour needs a live server to
 *  validate.  Security is None/None (a diode's high side is already trusted);
 *  add a security policy + PKI here if the source server requires one.
 */

#include <stdint.h>
#include <string.h>
#include <stdio.h>

#include "libs2opc_common_config.h"
#include "libs2opc_client.h"
#include "libs2opc_client_config.h"
#include "libs2opc_client_config_custom.h"
#include "libs2opc_request_builder.h"

#include "sopc_buffer.h"
#include "sopc_mutexes.h"
#include "sopc_types.h"
#include "sopc_encodeabletype.h"
#include "sopc_encoder.h"

#define OD_MAX_DS   1300      /* = Opc_Client.Max_Ds */
#define OD_RING     256       /* buffered updates     */

typedef struct {
    uint16_t wid;
    uint32_t len;
    uint8_t  data[OD_MAX_DS];
} od_upd;

static od_upd        g_ring[OD_RING];
static volatile int  g_head, g_tail;      /* tail = next to read, head = next write */
static SOPC_Mutex    g_lock;

static SOPC_SecureConnection_Config* g_cfg;
static SOPC_ClientConnection*        g_conn;
static SOPC_ClientHelper_Subscription* g_sub;
static int g_ready;

static void push(uint16_t wid, const uint8_t* d, uint32_t n)
{
    if (n > OD_MAX_DS) n = OD_MAX_DS;
    SOPC_Mutex_Lock(&g_lock);
    int nxt = (g_head + 1) % OD_RING;
    if (nxt != g_tail) {                    /* drop if full (diode: loss ok) */
        g_ring[g_head].wid = wid;
        g_ring[g_head].len = n;
        memcpy(g_ring[g_head].data, d, n);
        g_head = nxt;
    }
    SOPC_Mutex_Unlock(&g_lock);
}

/* Subscription data-change callback (runs on an S2OPC thread). */
static void notif_cb(const SOPC_ClientHelper_Subscription* sub,
                     SOPC_StatusCode status,
                     SOPC_EncodeableType* notifType,
                     uint32_t nbElts,
                     const void* notification,
                     uintptr_t* ctxArray)
{
    (void) sub;
    if (!SOPC_IsGoodStatus(status) || notification == NULL ||
        notifType != &OpcUa_DataChangeNotification_EncodeableType)
        return;

    const OpcUa_DataChangeNotification* dcn = notification;
    int n = dcn->NoOfMonitoredItems;
    if (n < 0) n = 0;
    if ((uint32_t) n > nbElts) n = (int) nbElts;

    for (int i = 0; i < n; i++) {
        uint16_t wid = (uint16_t) ctxArray[i];
        SOPC_Buffer* b = SOPC_Buffer_Create(OD_MAX_DS);
        if (b != NULL) {
            if (SOPC_DataValue_Write(&dcn->MonitoredItems[i].Value, b, 0)
                    == SOPC_STATUS_OK) {
                push(wid, b->data, b->length);
            }
            SOPC_Buffer_Delete(b);
        }
    }
}

static void conn_event_cb(SOPC_ClientConnection* c,
                          SOPC_ClientConnectionEvent event,
                          SOPC_StatusCode status)
{
    (void) c; (void) event; (void) status;   /* diode: no reconnection logic */
}

int od_s2opc_init(const char* endpoint)
{
    if (g_ready) return 0;
    if (SOPC_Mutex_Initialization(&g_lock) != SOPC_STATUS_OK) return -1;

    if (SOPC_CommonHelper_Initialize(NULL, NULL) != SOPC_STATUS_OK) return -1;
    if (SOPC_ClientConfigHelper_Initialize() != SOPC_STATUS_OK)     return -1;

    /* An application description is required before a secure channel is set up. */
    if (SOPC_ClientConfigHelper_SetApplicationDescription(
            "urn:opc-diode:adapter", "urn:opc-diode",
            "opc-diode adapter", "en", OpcUa_ApplicationType_Client)
        != SOPC_STATUS_OK) return -1;

    /* None security, anonymous user.  Note the two easy traps: the policy is the
       SOPC_SecurityPolicy_URI enum value SOPC_SecurityPolicy_None (NOT the
       _None_ID of the other enum), and UpdateUserPolicyId must follow SetAnonymous
       so the user token matches the server's advertised policy -- without it the
       server closes the session. */
    g_cfg = SOPC_ClientConfigHelper_CreateSecureConnection(
                "od-adapter", endpoint,
                OpcUa_MessageSecurityMode_None, SOPC_SecurityPolicy_None);
    if (g_cfg == NULL) return -1;
    if (SOPC_SecureConnectionConfig_SetAnonymous(g_cfg, "anonymous")
            != SOPC_STATUS_OK) return -1;
    if (SOPC_SecureConnectionConfig_UpdateUserPolicyId(g_cfg) != SOPC_STATUS_OK)
        return -1;

    if (SOPC_ClientHelper_Connect(g_cfg, conn_event_cb, &g_conn)
            != SOPC_STATUS_OK) return -1;

    OpcUa_CreateSubscriptionRequest* sr =
        SOPC_CreateSubscriptionRequest_CreateDefault();
    if (sr == NULL) return -1;
    g_sub = SOPC_ClientHelper_CreateSubscription(g_conn, sr, notif_cb, 0);
    if (g_sub == NULL) return -1;

    g_ready = 1;
    return 0;
}

int od_s2opc_subscribe(const char* node, uint16_t wid)
{
    if (!g_ready || node == NULL) return -1;

    uint32_t subId = 0;
    if (SOPC_ClientHelper_GetSubscriptionId(g_sub, &subId) != SOPC_STATUS_OK)
        return -1;

    char* nodes[1] = { (char*) node };
    OpcUa_CreateMonitoredItemsRequest* req =
        SOPC_CreateMonitoredItemsRequest_CreateDefaultFromStrings(
            subId, 1, nodes, OpcUa_TimestampsToReturn_Both);
    if (req == NULL) return -1;

    uintptr_t ctx[1] = { (uintptr_t) wid };
    OpcUa_CreateMonitoredItemsResponse resp;
    OpcUa_CreateMonitoredItemsResponse_Initialize(&resp);

    SOPC_ReturnStatus st =
        SOPC_ClientHelper_Subscription_CreateMonitoredItems(g_sub, req, ctx, &resp);
    OpcUa_CreateMonitoredItemsResponse_Clear(&resp);
    return (st == SOPC_STATUS_OK) ? 0 : -1;
}

/* Drain one update.  Returns its length (0 if none); writes wid + bytes out. */
int od_s2opc_poll(uint16_t* wid, uint8_t* out, int maxlen)
{
    int len = 0;
    if (out == NULL || wid == NULL) return 0;
    SOPC_Mutex_Lock(&g_lock);
    if (g_tail != g_head) {
        od_upd* u = &g_ring[g_tail];
        len = (int) u->len;
        if (len > maxlen) len = maxlen;
        *wid = u->wid;
        memcpy(out, u->data, (size_t) len);
        g_tail = (g_tail + 1) % OD_RING;
    }
    SOPC_Mutex_Unlock(&g_lock);
    return len;
}

void od_s2opc_fini(void)
{
    if (!g_ready) return;
    if (g_sub != NULL) SOPC_ClientHelper_DeleteSubscription(&g_sub);
    if (g_conn != NULL) SOPC_ClientHelper_Disconnect(&g_conn);
    SOPC_ClientConfigHelper_Clear();
    SOPC_CommonHelper_Clear();
    g_ready = 0;
}
