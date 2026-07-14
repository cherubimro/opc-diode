//  opc-diode -- a high-assurance Ada/SPARK OPC UA PubSub data-diode relay.
//  Copyright (C) 2026  Alin-Adrian Anton <alin.anton@upt.ro>
//  SPDX-License-Identifier: AGPL-3.0-or-later

/*  od_dpdk_shim.c -- non-inline C wrappers over DPDK's static-inline data path.
 *
 *  WHY THIS FILE MUST EXIST
 *  ------------------------
 *  DPDK's packet loop -- rte_eth_rx_burst(), rte_eth_tx_burst() and the whole
 *  rte_pktmbuf_* family -- is `static inline` in the headers, so it exports NO
 *  symbols (`nm` confirms: zero) and Ada's `Import, Convention => C` cannot
 *  reach it.  The *setup* calls are real symbols; the data path is not.  Hence
 *  this translation unit: it turns the inline API into real symbols Ada imports
 *  exactly as od_receiver imports the socket calls today.
 *
 *  ASSURANCE (docs/ASSURANCE.md)
 *  -----------------------------
 *  This file is inside the TCB and on the data path.  It is kept small and
 *  total so it can be reviewed line by line:
 *    - mbuf lifetime NEVER escapes this file.  RX copies whole diode packets
 *      out and frees every mbuf; TX allocates, fills, transmits and frees on
 *      failure.  Ada therefore never holds a DPDK pointer.
 *    - RX is bounded: it writes at most max_pkts * OD_MAX_PKT bytes, and
 *      max_pkts is clamped to OD_BURST regardless of the caller.
 *    - Frames that are not ours (wrong EtherType, wrong length) are dropped
 *      here, so Ada receives only well-formed candidate diode packets.
 *
 *  Unlike the gnat-lt-pro shim, diode packets are VARIABLE length (a diode
 *  packet is 25 + frag_len bytes), so RX returns a per-packet length array and
 *  TX takes an explicit length.
 *
 *  WIRE FORMAT
 *  -----------
 *      | rte_ether_hdr (14) | diode packet (<= 1425 bytes, verbatim) |
 *  EtherType 0x88B7 (an IEEE "local experimental" value, distinct from the
 *  0x88B6 gnat-lt-pro uses, so both can share a lab segment).  The diode packet
 *  rides raw: no IP, no UDP.
 */

#include <stdint.h>
#include <string.h>
#include <stdio.h>

#include <rte_eal.h>
#include <rte_errno.h>
#include <rte_ethdev.h>
#include <rte_mbuf.h>
#include <rte_ether.h>

#define OD_MAX_PKT    1425                             /* Diode_Wire.Max_Packet */
#define OD_ETHERTYPE  0x88B7
#define OD_MAX_FRAME  (RTE_ETHER_HDR_LEN + OD_MAX_PKT)
#define OD_BURST      64                               /* = Od_Dpdk.Batch       */

static struct rte_mempool   *od_pool;
static uint16_t              od_port;
static int                   od_ready;
static struct rte_ether_addr od_src;
static struct rte_ether_addr od_dst = {                /* default: broadcast    */
    .addr_bytes = { 0xff, 0xff, 0xff, 0xff, 0xff, 0xff }
};

static int od_port_init(uint16_t port)
{
    struct rte_eth_conf conf;
    uint16_t nrx = 1024, ntx = 1024;

    memset(&conf, 0, sizeof conf);
    if (rte_eth_dev_configure(port, 1, 1, &conf) != 0)             return -1;
    if (rte_eth_dev_adjust_nb_rx_tx_desc(port, &nrx, &ntx) != 0)   return -1;
    if (rte_eth_rx_queue_setup(port, 0, nrx,
            rte_eth_dev_socket_id(port), NULL, od_pool) < 0)       return -1;
    if (rte_eth_tx_queue_setup(port, 0, ntx,
            rte_eth_dev_socket_id(port), NULL) < 0)                return -1;
    if (rte_eth_dev_start(port) < 0)                               return -1;

    rte_eth_promiscuous_enable(port);                  /* we filter, not the NIC */
    if (rte_eth_macaddr_get(port, &od_src) != 0)                   return -1;
    return 0;
}

int od_dpdk_wait_link(int timeout_ms)
{
    struct rte_eth_link link;
    int waited = 0;
    if (!od_ready) return 0;
    while (waited < timeout_ms) {
        memset(&link, 0, sizeof link);
        if (rte_eth_link_get_nowait(od_port, &link) == 0 &&
            link.link_status == RTE_ETH_LINK_UP)
            return 1;
        rte_delay_ms(50);
        waited += 50;
    }
    return 0;
}

int od_dpdk_init(int argc, char **argv)
{
    uint16_t p;
    if (od_ready) return 0;

    if (rte_eal_init(argc, argv) < 0) {
        fprintf(stderr, "[dpdk] rte_eal_init: %s\n", rte_strerror(rte_errno));
        return -1;
    }
    if (rte_eth_dev_count_avail() == 0) {
        fprintf(stderr, "[dpdk] no ethdev port available "
                        "(did you pass --vdev=... or bind a NIC?)\n");
        return -1;
    }
    od_pool = rte_pktmbuf_pool_create("OD_MBUF", 8191, 256, 0,
                                      RTE_MBUF_DEFAULT_BUF_SIZE, rte_socket_id());
    if (od_pool == NULL) {
        fprintf(stderr, "[dpdk] mbuf pool: %s\n", rte_strerror(rte_errno));
        return -1;
    }
    od_port = 0;
    RTE_ETH_FOREACH_DEV(p) { od_port = p; break; }
    if (od_port_init(od_port) != 0) {
        fprintf(stderr, "[dpdk] port %u init failed\n", (unsigned) od_port);
        return -1;
    }
    od_ready = 1;
    return 0;
}

int od_dpdk_set_dst(const char *mac)
{
    struct rte_ether_addr a;
    if (mac == NULL || rte_ether_unformat_addr(mac, &a) != 0)
        return -1;
    od_dst = a;
    return 0;
}

/* Poll one burst.  Copies up to max_pkts diode packets into `out` (each in its
   own OD_MAX_PKT-byte slot), writing each packet's true length into out_lens.
   Returns the count. */
int od_dpdk_rx_burst(unsigned char *out, int *out_lens, int max_pkts)
{
    struct rte_mbuf *m[OD_BURST];
    uint16_t n, i;
    int k = 0;

    if (!od_ready || out == NULL || out_lens == NULL || max_pkts <= 0)
        return 0;
    if (max_pkts > OD_BURST)
        max_pkts = OD_BURST;

    n = rte_eth_rx_burst(od_port, 0, m, (uint16_t) max_pkts);

    for (i = 0; i < n; i++) {
        const struct rte_ether_hdr *eh =
            rte_pktmbuf_mtod(m[i], const struct rte_ether_hdr *);
        uint16_t dlen = rte_pktmbuf_data_len(m[i]);

        if (dlen > RTE_ETHER_HDR_LEN &&
            (size_t)(dlen - RTE_ETHER_HDR_LEN) <= OD_MAX_PKT &&
            eh->ether_type == rte_cpu_to_be_16(OD_ETHERTYPE)) {
            int plen = (int) (dlen - RTE_ETHER_HDR_LEN);
            memcpy(out + (size_t) k * OD_MAX_PKT,
                   (const unsigned char *) eh + RTE_ETHER_HDR_LEN,
                   (size_t) plen);
            out_lens[k] = plen;
            k++;
        }
        rte_pktmbuf_free(m[i]);
    }
    return k;
}

/* Transmit one diode packet of `len` bytes.  1 = handed to the driver, 0 = dropped. */
int od_dpdk_tx(const unsigned char *pkt, int len)
{
    struct rte_mbuf *m;
    struct rte_ether_hdr *eh;
    char *p;
    int frame;

    if (!od_ready || pkt == NULL || len <= 0 || len > OD_MAX_PKT)
        return 0;
    frame = RTE_ETHER_HDR_LEN + len;

    m = rte_pktmbuf_alloc(od_pool);
    if (m == NULL) return 0;

    p = rte_pktmbuf_append(m, frame);
    if (p == NULL) { rte_pktmbuf_free(m); return 0; }

    eh = (struct rte_ether_hdr *) p;
    rte_ether_addr_copy(&od_dst, &eh->dst_addr);
    rte_ether_addr_copy(&od_src, &eh->src_addr);
    eh->ether_type = rte_cpu_to_be_16(OD_ETHERTYPE);
    memcpy(p + RTE_ETHER_HDR_LEN, pkt, (size_t) len);

    if (rte_eth_tx_burst(od_port, 0, &m, 1) == 0) {
        rte_pktmbuf_free(m);
        return 0;
    }
    return 1;
}

void od_dpdk_fini(void)
{
    if (!od_ready) return;
    rte_eth_dev_stop(od_port);
    rte_eth_dev_close(od_port);
    rte_eal_cleanup();
    od_ready = 0;
}
