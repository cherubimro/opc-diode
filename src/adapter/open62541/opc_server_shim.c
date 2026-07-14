//  opc-diode -- a high-assurance Ada/SPARK OPC UA PubSub data-diode relay.
//  Copyright (C) 2026  Alin Anton <alin.anton@upt.ro>
//  SPDX-License-Identifier: AGPL-3.0-or-later

/*  opc_server_shim.c -- open62541 shadow server behind the Ada Opc_Server
 *  interface.  Same contract as the S2OPC server shim, different stack.  Nodes
 *  must exist in the address space (loaded from the nodeset XML the config
 *  helper builds, or added out of band); od_ua_srv_write decodes the arriving
 *  bytes to a DataValue and writes it.  The server runs on its own thread so
 *  Ada's UDP loop is not blocked.  Compiles against the amalgamation; end-to-end
 *  needs a real address space + subscriber to validate.
 */

#include <stdint.h>
#include <string.h>
#include <pthread.h>
#include <time.h>
#include "open62541.h"

static UA_Server*  g_server;
static pthread_t   g_thread;
static volatile UA_Boolean g_run;
static int g_ready;

/* Own the whole server lifecycle on this one thread -- startup, the iterate
   loop, and shutdown.  Calling run_startup here AND in the caller left the
   listener half-open, so connections timed out. */
static void* serve(void* arg)
{
    (void) arg;
    UA_Server_run_startup(g_server);
    while (g_run) {
        UA_Server_run_iterate(g_server, true);
    }
    UA_Server_run_shutdown(g_server);
    return NULL;
}

int od_ua_srv_start(const char* server_cfg, const char* addr_space_cfg)
{
    (void) server_cfg; (void) addr_space_cfg;   /* default config; nodeset TBD */
    if (g_ready) return 0;
    g_server = UA_Server_new();
    if (g_server == NULL) return -1;
    UA_ServerConfig_setDefault(UA_Server_getConfig(g_server));
    g_run = true;
    if (pthread_create(&g_thread, NULL, serve, NULL) != 0) return -1;

    /* Let startup bind the listener before Add_Node/Write or a client arrive
       (multithreading is on, so those calls are then thread-safe). */
    struct timespec ts = { 0, 400L * 1000L * 1000L };
    nanosleep(&ts, NULL);
    g_ready = 1;
    return 0;
}

/* Create a writable Double variable node (parented under Objects). */
int od_ua_srv_add_node(const char* node)
{
    if (!g_ready || node == NULL) return -1;
    UA_NodeId nid;
    if (UA_NodeId_parse(&nid, UA_STRING((char*) node)) != UA_STATUSCODE_GOOD)
        return -1;

    UA_VariableAttributes attr = UA_VariableAttributes_default;
    UA_Double zero = 0.0;
    UA_Variant_setScalar(&attr.value, &zero, &UA_TYPES[UA_TYPES_DOUBLE]);
    attr.accessLevel = UA_ACCESSLEVELMASK_READ | UA_ACCESSLEVELMASK_WRITE;

    UA_QualifiedName bn = UA_QUALIFIEDNAME(1, (char*) node);
    UA_StatusCode st = UA_Server_addVariableNode(
        g_server, nid,
        UA_NODEID_NUMERIC(0, UA_NS0ID_OBJECTSFOLDER),
        UA_NODEID_NUMERIC(0, UA_NS0ID_ORGANIZES),
        bn, UA_NODEID_NUMERIC(0, UA_NS0ID_BASEDATAVARIABLETYPE),
        attr, NULL, NULL);
    UA_NodeId_clear(&nid);
    /* AlreadyExists is fine (node came from a nodeset). */
    return (st == UA_STATUSCODE_GOOD ||
            st == UA_STATUSCODE_BADNODEIDEXISTS) ? 0 : -1;
}

int od_ua_srv_write(const char* node, const uint8_t* val, int len)
{
    if (!g_ready || node == NULL || val == NULL || len <= 0) return -1;
    UA_NodeId nid;
    if (UA_NodeId_parse(&nid, UA_STRING((char*) node)) != UA_STATUSCODE_GOOD)
        return -1;

    UA_ByteString src;
    src.length = (size_t) len;
    src.data   = (uint8_t*) val;

    UA_DataValue dv;
    UA_DataValue_init(&dv);
    int rc = -1;
    if (UA_decodeBinary(&src, &dv, &UA_TYPES[UA_TYPES_DATAVALUE], NULL)
            == UA_STATUSCODE_GOOD) {
        if (UA_Server_writeDataValue(g_server, nid, dv) == UA_STATUSCODE_GOOD)
            rc = 0;
    }
    UA_DataValue_clear(&dv);
    UA_NodeId_clear(&nid);
    return rc;
}

void od_ua_srv_stop(void)
{
    if (!g_ready) return;
    g_run = false;
    pthread_join(g_thread, NULL);
    UA_Server_run_shutdown(g_server);
    UA_Server_delete(g_server);
    g_ready = 0;
}
