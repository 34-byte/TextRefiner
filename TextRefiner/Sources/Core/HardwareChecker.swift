import Foundation

/// Verifies the user's machine meets minimum requirements for local LLM inference.
/// TextRefiner requires Apple Silicon (M1+) and at least 8 GB of RAM.
struct HardwareChecker {

    /// Minimum RAM required: 8 GB
    static let minimumRAMBytes: UInt64 = 8_589_934_592

    /// Returns true if running on Apple Silicon (M1+).
    static var isAppleSilicon: Bool {
        var cputype: cpu_type_t = 0
        var size = MemoryLayout<cpu_type_t>.size
        let result = sysctlbyname("hw.cputype", &cputype, &size, nil, 0)
        return result == 0 && cputype == CPU_TYPE_ARM64
    }

    /// Total physical RAM in bytes.
    static var totalRAM: UInt64 {
        ProcessInfo.processInfo.physicalMemory
    }

    /// RAM in GB (for display purposes).
    static var totalRAMGB: Double {
        Double(totalRAM) / 1_073_741_824
    }

    /// True if the machine meets all requirements (Apple Silicon + 8 GB+ RAM).
    static var meetsRequirements: Bool {
        isAppleSilicon && totalRAM >= minimumRAMBytes
    }

    /// Returns a human-readable description of why the machine is incompatible,
    /// or nil if it meets requirements.
    static var incompatibilityReason: String? {
        var reasons: [String] = []

        if !isAppleSilicon {
            reasons.append("TextRefiner requires an Apple Silicon Mac (M1 or later). Your Mac uses an Intel processor and is not supported.")
        }

        if totalRAM < minimumRAMBytes {
            let ramGB = String(format: "%.0f", totalRAMGB)
            reasons.append("TextRefiner requires at least 8 GB of RAM. Your Mac has \(ramGB) GB.")
        }

        return reasons.isEmpty ? nil : reasons.joined(separator: "\n\n")
    }
}
