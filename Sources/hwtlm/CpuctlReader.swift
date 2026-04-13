/*
 * Copyright (c) 2026 Kory Heard
 *
 * SPDX-License-Identifier: BSD-2-Clause
 */

// Architecture: x86-only at runtime. MSR and CPUID access via
// cpuctl(4). Falls back to sysctl hw.ncpu for CPU count on ARM.

import CCpuctl
import Glibc

// MARK: - Errors

enum HWError: Error, CustomStringConvertible {
    case cpuctlNotLoaded
    case openFailed(cpu: Int, errno: Int32)
    case msrReadFailed(cpu: Int, msr: Int32, errno: Int32)
    case cpuidFailed(cpu: Int, errno: Int32)

    var description: String {
        switch self {
        case .cpuctlNotLoaded:
            return "cpuctl kernel module is not loaded. Run: sudo kldload cpuctl"
        case .openFailed(let cpu, let errno):
            return "failed to open /dev/cpuctl\(cpu): \(String(cString: strerror(errno)))"
        case .msrReadFailed(let cpu, let msr, let errno):
            return "failed to read MSR 0x\(String(msr, radix: 16)) on cpu\(cpu): \(String(cString: strerror(errno)))"
        case .cpuidFailed(let cpu, let errno):
            return "CPUID failed on cpu\(cpu): \(String(cString: strerror(errno)))"
        }
    }
}

// MARK: - CpuctlReader

/// Low-level reader for MSR and CPUID via FreeBSD's cpuctl(4) device.
/// Each instance wraps one `/dev/cpuctl<N>` file descriptor.
struct CpuctlReader: ~Copyable {
    let cpu: Int
    private let fd: Int32

    /// Open `/dev/cpuctl<cpu>` for reading.
    init(cpu: Int) throws {
        self.cpu = cpu
        let path = "/dev/cpuctl\(cpu)"
        let fd = Glibc.open(path, O_RDONLY)
        guard fd >= 0 else {
            let err = errno
            if err == ENOENT {
                throw HWError.cpuctlNotLoaded
            }
            throw HWError.openFailed(cpu: cpu, errno: err)
        }
        self.fd = fd
    }

    deinit {
        Glibc.close(fd)
    }

    /// Read a model-specific register.
    func readMSR(_ msr: Int32) throws -> UInt64 {
        var args = cpuctl_msr_args_t(msr: msr, data: 0)
        guard ioctl(fd, CCpuctl.CCPUCTL_RDMSR, &args) == 0 else {
            throw HWError.msrReadFailed(cpu: cpu, msr: msr, errno: errno)
        }
        return args.data
    }

    /// Execute CPUID leaf and return (eax, ebx, ecx, edx).
    func cpuid(leaf: Int32) throws -> (UInt32, UInt32, UInt32, UInt32) {
        var args = cpuctl_cpuid_args_t(level: leaf, data: (0, 0, 0, 0))
        guard ioctl(fd, CCpuctl.CCPUCTL_CPUID, &args) == 0 else {
            throw HWError.cpuidFailed(cpu: cpu, errno: errno)
        }
        return (args.data.0, args.data.1, args.data.2, args.data.3)
    }

    // MARK: - Discovery

    /// Detect the number of logical CPUs by probing /dev/cpuctl<N>.
    /// Falls back to sysctl hw.ncpu if cpuctl is not loaded.
    static func detectCPUCount() -> Int {
        var n = 0
        while true {
            let path = "/dev/cpuctl\(n)"
            if access(path, F_OK) != 0 { break }
            n += 1
        }
        if n > 0 { return n }

        // Fallback when cpuctl is not loaded
        return SysctlReader.cpuCount()
    }

    /// Identify the Intel microarchitecture via CPUID on cpu 0.
    /// Returns nil if cpuctl is unavailable or CPU is not Intel.
    static func detectMicroarch() -> IntelMicroarch? {
        guard let reader = try? CpuctlReader(cpu: 0) else {
            return nil
        }

        guard let (_, ebx, ecx, edx) = try? reader.cpuid(leaf: 0) else {
            return nil
        }

        // "GenuineIntel"
        guard ebx == 0x756E_6547 && edx == 0x4965_6E69 && ecx == 0x6C65_746E else {
            return nil
        }

        guard let (eax1, _, _, _) = try? reader.cpuid(leaf: 1) else {
            return nil
        }
        let family        = (eax1 >> 8)  & 0xF
        let model         = (eax1 >> 4)  & 0xF
        let extendedModel = (eax1 >> 16) & 0xF

        guard family == 6 else { return nil }

        return IntelMicroarch.from(model: model, extendedModel: extendedModel)
    }
}
