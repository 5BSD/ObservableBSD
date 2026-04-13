/*
 * Copyright (c) 2026 Kory Heard
 *
 * SPDX-License-Identifier: BSD-2-Clause
 */

// Architecture: portable. No hardware dependencies.

/// All telemetry for a single CPU at one point in time.
struct CoreSnapshot: Sendable {
    let cpu: Int
    let temperatureC: Double?
    let frequencyMHz: Int?
    let cstate: CStateInfo?
    let throttled: Bool
}
