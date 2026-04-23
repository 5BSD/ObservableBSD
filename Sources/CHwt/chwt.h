/*
 * CHwt -- shim header that pulls in <sys/hwt.h> with the types it
 * needs, plus the <sys/ioctl.h> ioctl(2) prototype.
 *
 * The _IOW-based macros don't bridge to Swift, so we re-export them
 * as static constants.
 *
 * SPDX-License-Identifier: BSD-2-Clause
 */

#ifndef CHWT_H
#define CHWT_H

#include <sys/types.h>
#include <sys/param.h>
#include <sys/cpuset.h>
#include <sys/ioctl.h>
#include <sys/mman.h>
#include <sys/hwt.h>

/*
 * PT backend config — copied from <amd64/pt/pt.h> which is not
 * installed as a public header.  Must be sent via HWT_IOC_SET_CONFIG
 * before HWT_IOC_START or the PT backend will NULL-deref ctx->config.
 */
#define CHWT_PT_IP_FILTER_MAX_RANGES 2

struct chwt_pt_cpu_config {
    uint64_t    rtit_ctl;
    register_t  cr3_filter;
    int         nranges;
    struct {
        vm_offset_t start;
        vm_offset_t end;
    } ip_ranges[CHWT_PT_IP_FILTER_MAX_RANGES];
    uint32_t    mtc_freq;
    uint32_t    cyc_thresh;
    uint32_t    psb_freq;
};

/* Re-export ioctl constants as values Swift can see. */
static const unsigned long CHWT_IOC_ALLOC       = HWT_IOC_ALLOC;
static const unsigned long CHWT_IOC_START       = HWT_IOC_START;
static const unsigned long CHWT_IOC_STOP        = HWT_IOC_STOP;
static const unsigned long CHWT_IOC_RECORD_GET  = HWT_IOC_RECORD_GET;
static const unsigned long CHWT_IOC_BUFPTR_GET  = HWT_IOC_BUFPTR_GET;
static const unsigned long CHWT_IOC_SET_CONFIG  = HWT_IOC_SET_CONFIG;
static const unsigned long CHWT_IOC_WAKEUP      = HWT_IOC_WAKEUP;
static const unsigned long CHWT_IOC_SVC_BUF     = HWT_IOC_SVC_BUF;

/* Mode constants. */
static const int CHWT_MODE_THREAD = HWT_MODE_THREAD;
static const int CHWT_MODE_CPU    = HWT_MODE_CPU;

#endif /* CHWT_H */
