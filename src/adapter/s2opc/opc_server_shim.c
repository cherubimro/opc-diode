//  opc-diode -- a high-assurance Ada/SPARK OPC UA PubSub data-diode relay.
//  Copyright (C) 2026  Alin Anton <alin.anton@upt.ro>
//  SPDX-License-Identifier: AGPL-3.0-or-later

/*  opc_server_shim.c -- S2OPC shadow server behind the Ada Opc_Server interface.
 *
 *  Starts an OPC UA server from XML config (endpoint + address space), then
 *  writes recovered values into its nodes via the local write service.  The
 *  value bytes are the encoded SOPC_DataValue that arrived as a DataSetMessage;
 *  we decode it and write it to the node named by its NodeId string.  The whole
 *  server stack -- and the subscribers' sessions -- stay on the low side.
 *
 *  NOTE: compiles against S2OPC; end-to-end behaviour needs a real address-space
 *  XML and a subscriber to validate.
 */

#include <stdint.h>
#include <string.h>
#include <stdio.h>

#include "libs2opc_common_config.h"
#include "libs2opc_server.h"
#include "libs2opc_server_config.h"
#include "libs2opc_server_config_custom.h"
#include "libs2opc_request_builder.h"

#include "sopc_buffer.h"
#include "sopc_types.h"
#include "sopc_encoder.h"
#include "sopc_builtintypes.h"
#include "sopc_mem_alloc.h"

static int g_ready;

static void stopped_cb(SOPC_ReturnStatus status) { (void) status; }

int od_srv_start(const char* server_cfg, const char* addr_space_cfg)
{
    if (g_ready) return 0;
    if (SOPC_CommonHelper_Initialize(NULL, NULL) != SOPC_STATUS_OK) return -1;
    if (SOPC_ServerConfigHelper_Initialize() != SOPC_STATUS_OK)     return -1;
    /* NOTE: the address-space XML's server namespace (NamespaceArray[1]) must
       equal the ApplicationUri in the server config XML, or ConfigureFromXML
       fails -- see tests/s2opc-data/server_none.xml. */
    if (SOPC_ServerConfigHelper_ConfigureFromXML(server_cfg, addr_space_cfg,
                                                 NULL, NULL) != SOPC_STATUS_OK)
        return -1;
    if (SOPC_ServerHelper_StartServer(stopped_cb) != SOPC_STATUS_OK) return -1;
    g_ready = 1;
    return 0;
}

/* Write a value (encoded SOPC_DataValue in `val`, `len` bytes) to node `node`. */
int od_srv_write(const char* node, const uint8_t* val, int len)
{
    if (!g_ready || node == NULL || val == NULL || len <= 0) return -1;

    SOPC_NodeId* nid = SOPC_NodeId_FromCString(node);
    if (nid == NULL) return -1;

    SOPC_DataValue dv;
    SOPC_DataValue_Initialize(&dv);

    SOPC_Buffer* b = SOPC_Buffer_Create((uint32_t) len);
    int rc = -1;
    if (b != NULL &&
        SOPC_Buffer_Write(b, val, (uint32_t) len) == SOPC_STATUS_OK &&
        SOPC_Buffer_SetPosition(b, 0) == SOPC_STATUS_OK &&
        SOPC_DataValue_Read(&dv, b, 0) == SOPC_STATUS_OK)
    {
        OpcUa_WriteRequest* req = SOPC_WriteRequest_Create(1);
        if (req != NULL &&
            SOPC_WriteRequest_SetWriteValue(req, 0, nid,
                SOPC_AttributeId_Value, NULL, &dv) == SOPC_STATUS_OK)
        {
            OpcUa_WriteResponse* resp = NULL;
            if (SOPC_ServerHelper_LocalServiceSync(req, (void**) &resp)
                    == SOPC_STATUS_OK)
            {
                rc = 0;
                if (resp != NULL) {
                    SOPC_EncodeableObject_Delete(&OpcUa_WriteResponse_EncodeableType, (void**) &resp);
                }
            }
        }
    }

    SOPC_Buffer_Delete(b);
    SOPC_DataValue_Clear(&dv);
    SOPC_NodeId_Clear(nid);
    SOPC_Free(nid);
    return rc;
}

void od_srv_stop(void)
{
    if (!g_ready) return;
    SOPC_ServerHelper_StopServer();
    SOPC_ServerConfigHelper_Clear();
    SOPC_CommonHelper_Clear();
    g_ready = 0;
}
