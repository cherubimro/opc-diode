//  SPDX-License-Identifier: AGPL-3.0-or-later
//  Test-only OPC UA reader (open62541): connect, read one Double node, print it.
//  Used by tools/opcua-test.sh to check the shadow server received the value.
#include <stdio.h>
#include <unistd.h>
#include "open62541.h"

int main(int argc, char** argv)
{
    if (argc < 3) { printf("usage: opcua_read <url> <nodeid>\n"); return 2; }
    UA_Client* c = UA_Client_new();
    UA_ClientConfig_setDefault(UA_Client_getConfig(c));
    if (UA_Client_connect(c, argv[1]) != UA_STATUSCODE_GOOD) {
        printf("connect-fail\n"); UA_Client_delete(c); return 2;
    }
    UA_NodeId nid;
    if (UA_NodeId_parse(&nid, UA_STRING(argv[2])) != UA_STATUSCODE_GOOD) {
        printf("VALUE=badnode\n"); return 2;
    }
    /* Retry a few times: the first read may land before any value arrives. */
    for (int i = 0; i < 10; i++) {
        UA_Variant v; UA_Variant_init(&v);
        UA_StatusCode st = UA_Client_readValueAttribute(c, nid, &v);
        if (st == UA_STATUSCODE_GOOD &&
            UA_Variant_hasScalarType(&v, &UA_TYPES[UA_TYPES_DOUBLE])) {
            double d = *(UA_Double*) v.data;
            UA_Variant_clear(&v);
            if (d != 0.0) {                 /* got a live value */
                printf("VALUE=%f\n", d);
                UA_NodeId_clear(&nid);
                UA_Client_disconnect(c); UA_Client_delete(c);
                return 0;
            }
        } else {
            UA_Variant_clear(&v);
        }
        usleep (300000);
    }
    printf("VALUE=zero\n");
    UA_NodeId_clear(&nid);
    UA_Client_disconnect(c); UA_Client_delete(c);
    return 0;
}
