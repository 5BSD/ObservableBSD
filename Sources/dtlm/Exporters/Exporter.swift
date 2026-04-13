/*
 * Copyright (c) 2026 Kory Heard
 *
 * SPDX-License-Identifier: BSD-2-Clause
 */

// Re-export the shared OTelExport module so the rest of dtlm can
// use Exporter, ProbeEvent, AggregationSnapshot, etc. without
// qualifying every reference.
@_exported import OTelExport
