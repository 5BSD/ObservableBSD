/*
 * Copyright (c) 2026 Kory Heard
 *
 * SPDX-License-Identifier: BSD-2-Clause
 */

// Architecture: x86-only at runtime. Intel RAPL MSR definitions
// and microarchitecture detection. On ARM, RAPLSampler.init?()
// returns nil and all RAPL data is omitted.

// MARK: - MSR addresses

/// Intel RAPL MSR addresses. See Intel SDM Vol. 3B, Chapter 15.10.
enum MSR {
    // Unit scaling factors (read once, apply to all domains).
    static let raplPowerUnit: Int32         = 0x606

    // Package (whole socket).
    static let pkgEnergyStatus: Int32       = 0x611
    static let pkgPowerLimit: Int32         = 0x610
    static let pkgPowerInfo: Int32          = 0x614

    // PP0 — core power plane.
    static let pp0EnergyStatus: Int32       = 0x639

    // PP1 — uncore / GPU power plane (client only).
    static let pp1EnergyStatus: Int32       = 0x641

    // DRAM (server + Haswell+ client).
    static let dramEnergyStatus: Int32      = 0x619

    // Platform / PSys (Skylake+).
    static let platformEnergyStatus: Int32  = 0x64D
}

// MARK: - RAPL domain

/// A measurable RAPL power domain.
enum RAPLDomain: String, CaseIterable, Sendable {
    case package  = "package"
    case pp0      = "pp0"
    case pp1      = "pp1"
    case dram     = "dram"
    case platform = "platform"

    /// Human-readable label for display.
    var label: String {
        switch self {
        case .package:  return "Package (CPU socket)"
        case .pp0:      return "PP0 (cores)"
        case .pp1:      return "PP1 (GPU / uncore)"
        case .dram:     return "DRAM"
        case .platform: return "Platform / PSys"
        }
    }

    /// The MSR address for this domain's energy status register.
    var energyMSR: Int32 {
        switch self {
        case .package:  return MSR.pkgEnergyStatus
        case .pp0:      return MSR.pp0EnergyStatus
        case .pp1:      return MSR.pp1EnergyStatus
        case .dram:     return MSR.dramEnergyStatus
        case .platform: return MSR.platformEnergyStatus
        }
    }
}

// MARK: - CPU model detection

/// Intel CPU microarchitecture family, used to determine which RAPL
/// domains are available. Keyed by CPUID family 6 model numbers.
enum IntelMicroarch: String, Sendable {
    case sandyBridge        = "Sandy Bridge"
    case sandyBridgeEP      = "Sandy Bridge-EP"
    case ivyBridge          = "Ivy Bridge"
    case ivyBridgeEP        = "Ivy Bridge-EP"
    case haswell            = "Haswell"
    case haswellEP          = "Haswell-EP"
    case broadwell          = "Broadwell"
    case broadwellEP        = "Broadwell-EP"
    case skylake            = "Skylake"
    case skylakeX           = "Skylake-X"
    case kabylake           = "Kaby Lake"
    case coffeelake         = "Coffee Lake"
    case cometlake          = "Comet Lake"
    case icelake            = "Ice Lake"
    case icelakeX           = "Ice Lake-X"
    case tigerlake          = "Tiger Lake"
    case alderlake          = "Alder Lake"
    case raptorLake         = "Raptor Lake"
    case meteorlake         = "Meteor Lake"
    case sapphireRapids     = "Sapphire Rapids"
    case emeraldRapids      = "Emerald Rapids"
    case atom               = "Atom"

    /// Which RAPL domains this microarchitecture exposes.
    var supportedDomains: [RAPLDomain] {
        switch self {
        case .sandyBridge, .ivyBridge:
            return [.package, .pp0, .pp1]
        case .sandyBridgeEP, .ivyBridgeEP:
            return [.package, .pp0, .dram]
        case .haswell, .broadwell:
            return [.package, .pp0, .pp1, .dram]
        case .haswellEP, .broadwellEP:
            return [.package, .pp0, .dram]
        case .skylake, .kabylake, .coffeelake, .cometlake,
             .icelake, .tigerlake, .alderlake, .raptorLake,
             .meteorlake:
            return [.package, .pp0, .pp1, .dram, .platform]
        case .skylakeX, .icelakeX, .sapphireRapids, .emeraldRapids:
            return [.package, .pp0, .dram, .platform]
        case .atom:
            return [.package]
        }
    }

    /// Whether this microarchitecture uses a different (fixed) energy
    /// unit for DRAM — 15.3 µJ instead of the CPU energy unit.
    /// Applies to server / EP parts.
    var usesFixedDRAMUnit: Bool {
        switch self {
        case .sandyBridgeEP, .ivyBridgeEP, .haswellEP,
             .broadwellEP, .skylakeX, .icelakeX,
             .sapphireRapids, .emeraldRapids:
            return true
        default:
            return false
        }
    }

    /// Map CPUID family-6 model to microarchitecture.
    static func from(model: UInt32, extendedModel: UInt32) -> IntelMicroarch? {
        // Full display model = (extended_model << 4) | model
        let displayModel = (extendedModel << 4) | model

        switch displayModel {
        // Sandy Bridge
        case 0x2A:          return .sandyBridge
        case 0x2D:          return .sandyBridgeEP
        // Ivy Bridge
        case 0x3A:          return .ivyBridge
        case 0x3E:          return .ivyBridgeEP
        // Haswell
        case 0x3C, 0x45, 0x46: return .haswell
        case 0x3F:          return .haswellEP
        // Broadwell
        case 0x3D, 0x47:    return .broadwell
        case 0x4F, 0x56:    return .broadwellEP
        // Skylake
        case 0x4E, 0x5E, 0x66: return .skylake
        case 0x55:          return .skylakeX
        // Kaby Lake
        case 0x8E, 0x9E:    return .kabylake
        // Coffee Lake (shares model with Kaby Lake in some steppings)
        // Handled by 0x8E/0x9E above — stepping disambiguates but
        // the RAPL domains are identical, so we map to kabylake.
        // Comet Lake
        case 0xA5, 0xA6:    return .cometlake
        // Ice Lake
        case 0x7E, 0x7D:    return .icelake
        case 0x6A, 0x6C:    return .icelakeX
        // Tiger Lake
        case 0x8C, 0x8D:    return .tigerlake
        // Alder Lake
        case 0x97, 0x9A:    return .alderlake
        // Raptor Lake
        case 0xB7, 0xBA, 0xBF: return .raptorLake
        // Meteor Lake
        case 0xAA, 0xAC:    return .meteorlake
        // Sapphire Rapids
        case 0x8F:          return .sapphireRapids
        // Emerald Rapids
        case 0xCF:          return .emeraldRapids
        // Atom (various)
        case 0x1C, 0x26, 0x27, 0x35, 0x36, 0x37, 0x4A, 0x4D,
             0x5A, 0x5D, 0x7A:
            return .atom
        default:
            return nil
        }
    }
}

// MARK: - Power units

/// Decoded RAPL power unit register (MSR 0x606). The register
/// encodes three fixed-point exponents:
///   - Power:  bits 3:0   → unit = 0.5^n watts
///   - Energy: bits 12:8  → unit = 0.5^n joules
///   - Time:   bits 19:16 → unit = 0.5^n seconds
struct RAPLPowerUnit: Sendable {
    /// Joules per energy-status LSB for CPU domains.
    let energyUnit: Double
    /// Joules per energy-status LSB for DRAM on EP/server parts.
    let dramEnergyUnit: Double
    /// Watts per power-limit LSB.
    let powerUnit: Double
    /// Seconds per time-limit LSB.
    let timeUnit: Double

    init(raw: UInt64, usesFixedDRAMUnit: Bool) {
        let powerExp  = Double(raw & 0xF)
        let energyExp = Double((raw >> 8) & 0x1F)
        let timeExp   = Double((raw >> 16) & 0xF)

        // 0.5^n == 1 / 2^n
        self.powerUnit  = 1.0 / Double(1 << Int(powerExp))
        self.energyUnit = 1.0 / Double(1 << Int(energyExp))
        self.timeUnit   = 1.0 / Double(1 << Int(timeExp))

        // Server / EP parts use a fixed DRAM energy unit of 2^-16 J
        // (≈15.3 µJ) regardless of what the power-unit register says.
        self.dramEnergyUnit = usesFixedDRAMUnit
            ? 1.0 / Double(1 << 16)
            : self.energyUnit
    }

    /// Convert a raw energy counter delta to joules for the given domain.
    func joules(rawDelta: UInt64, domain: RAPLDomain) -> Double {
        let unit = domain == .dram ? dramEnergyUnit : energyUnit
        return Double(rawDelta) * unit
    }
}
