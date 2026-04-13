/*
 * CCpuctl — shim header that pulls in <sys/cpuctl.h> with the
 * integer types it needs, plus the <sys/ioctl.h> ioctl(2) prototype.
 *
 * FreeBSD's <sys/cpuctl.h> uses uint64_t / uint32_t but does not
 * include <stdint.h> itself, so we provide the prerequisite here.
 *
 * The _IOWR-based macros don't bridge to Swift, so we re-export
 * them as static constants.
 *
 * SPDX-License-Identifier: BSD-2-Clause
 */

#ifndef CCPUCTL_H
#define CCPUCTL_H

#include <stdint.h>
#include <sys/types.h>
#include <sys/ioctl.h>
#include <sys/cpuctl.h>

/* Re-export ioctl constants as values Swift can see. */
static const unsigned long CCPUCTL_RDMSR        = CPUCTL_RDMSR;
static const unsigned long CCPUCTL_WRMSR        = CPUCTL_WRMSR;
static const unsigned long CCPUCTL_CPUID        = CPUCTL_CPUID;
static const unsigned long CCPUCTL_CPUID_COUNT  = CPUCTL_CPUID_COUNT;

#endif /* CCPUCTL_H */
