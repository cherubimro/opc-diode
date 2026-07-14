//  SPDX-License-Identifier: AGPL-3.0-or-later
//  Test-only source OPC UA server (open62541): exposes ns=1;s=x (Double) and
//  increments it every 200 ms.  Used by tools/opcua-test.sh as the high-side
//  source the adapter subscribes to.  Not part of the product build.
#include <stdlib.h>
#include <signal.h>
#include "open62541.h"

static volatile UA_Boolean g_run = true;
static void stop(int s) { (void) s; g_run = false; }

static void tick(UA_Server* srv, void* ctx)
{
    (void) ctx;
    static double v = 0.0;
    v += 1.0;
    UA_Variant val;
    UA_Variant_setScalar(&val, &v, &UA_TYPES[UA_TYPES_DOUBLE]);
    UA_Server_writeValue(srv, UA_NODEID_STRING(1, "x"), val);
}

int main(int argc, char** argv)
{
    int port = (argc > 1) ? atoi(argv[1]) : 4841;
    signal(SIGINT, stop); signal(SIGTERM, stop);

    UA_Server* s = UA_Server_new();
    UA_ServerConfig_setMinimal(UA_Server_getConfig(s), (UA_UInt16) port, NULL);

    UA_VariableAttributes attr = UA_VariableAttributes_default;
    UA_Double z = 0.0;
    UA_Variant_setScalar(&attr.value, &z, &UA_TYPES[UA_TYPES_DOUBLE]);
    attr.accessLevel = UA_ACCESSLEVELMASK_READ | UA_ACCESSLEVELMASK_WRITE;
    UA_Server_addVariableNode(
        s, UA_NODEID_STRING(1, "x"),
        UA_NODEID_NUMERIC(0, UA_NS0ID_OBJECTSFOLDER),
        UA_NODEID_NUMERIC(0, UA_NS0ID_ORGANIZES),
        UA_QUALIFIEDNAME(1, "x"),
        UA_NODEID_NUMERIC(0, UA_NS0ID_BASEDATAVARIABLETYPE), attr, NULL, NULL);

    UA_Server_addRepeatedCallback(s, tick, NULL, 200, NULL);
    UA_Server_run(s, &g_run);
    UA_Server_delete(s);
    return 0;
}
