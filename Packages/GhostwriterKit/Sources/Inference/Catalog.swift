import Foundation
import os
import GWCore

public struct HardwareProfile: Sendable, Hashable {
    public var chip: String
    public var tier: Int
    public var memoryGB: Int

    public init(chip: String, tier: Int, memoryGB: Int) {
        self.chip = chip
        self.tier = tier
        self.memoryGB = memoryGB
    }

    public static var current: HardwareProfile {
        let chip = sysctlString("machdep.cpu.brand_string") ?? ""
        return HardwareProfile(
            chip: chip,
            tier: tier(forChip: chip),
            memoryGB: Int(ProcessInfo.processInfo.physicalMemory >> 30)
        )
    }

    public var generation: Int? {
        guard let parsed = Self.parse(chip), parsed.family == "m" else { return nil }
        return parsed.generation
    }

    public static func tier(forChip chip: String) -> Int {
        guard let parsed = parse(chip), parsed.family == "m" else { return 0 }
        switch parsed.variant {
        case "max", "ultra": return 3
        case "pro": return [1, 3].contains(parsed.generation) ? 1 : 2
        default: return parsed.generation >= 2 ? 1 : 0
        }
    }

    private static func parse(_ chip: String) -> (family: String, generation: Int, variant: String?)? {
        let lowered = chip.lowercased()
        guard lowered.contains("apple"),
              let match = lowered.firstMatch(of: /\b(m|a)([1-9][0-9]*)\s*(pro|max|ultra)?\b/),
              let generation = Int(match.2)
        else { return nil }
        return (String(match.1), generation, match.3.map(String.init))
    }

    private static func sysctlString(_ name: String) -> String? {
        var size = 0
        guard sysctlbyname(name, nil, &size, nil, 0) == 0, size > 0 else { return nil }
        var buffer = [CChar](repeating: 0, count: size)
        guard sysctlbyname(name, &buffer, &size, nil, 0) == 0 else { return nil }
        return String(decoding: buffer.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
    }
}

public struct ModelSpec: Sendable, Hashable, Codable, Identifiable {
    public enum Family: String, Sendable, Codable { case gemma4, gemma3, custom }

    public var id: String
    public var displayName: String
    public var summary: String
    public var family: Family
    public var repo: String
    public var fileName: String
    public var sizeBytes: Int64
    public var sha256: String?
    public var minMemoryGB: Int
    public var minTier: Int
    public var revision: String?

    public init(
        id: String, displayName: String, summary: String = "", family: Family, repo: String, fileName: String,
        sizeBytes: Int64, sha256: String?, minMemoryGB: Int, minTier: Int, revision: String? = nil
    ) {
        self.id = id
        self.displayName = displayName
        self.summary = summary
        self.family = family
        self.repo = repo
        self.fileName = fileName
        self.sizeBytes = sizeBytes
        self.sha256 = sha256
        self.minMemoryGB = minMemoryGB
        self.minTier = minTier
        self.revision = revision
    }

    public var localURL: URL { AppPaths.models.appending(path: fileName) }
    public var isInstalled: Bool { FileManager.default.fileExists(atPath: localURL.path) }

    public var downloadURL: URL? {
        guard !repo.isEmpty else { return nil }
        return URL(string: "https://huggingface.co/\(repo)/resolve/\(revision ?? "main")/\(fileName)?download=true")
    }
}

public enum ModelCatalog {
    public static let curated: [ModelSpec] = [
        ModelSpec(
            id: "gemma-4-e2b", displayName: "Gemma 4 E2B",
            summary: "Fast and accurate. The best fit for most Macs.", family: .gemma4,
            repo: "mradermacher/gemma-4-E2B-i1-GGUF", fileName: "gemma-4-E2B.i1-Q5_K_M.gguf", sizeBytes: 3_630_270_176,
            sha256: "b646de7f13ecb4c47183d3d6452722b4ee8b38a22e52231468b60f659790b7f7", minMemoryGB: 16, minTier: 0,
            revision: "a9bf638e53783fc93778f357cc5c672eab5393b1"
        ),
        ModelSpec(
            id: "gemma-4-e4b", displayName: "Gemma 4 E4B",
            summary: "The most accurate, and the slowest. For fast Macs with plenty of memory.", family: .gemma4,
            repo: "mradermacher/gemma-4-E4B-i1-GGUF", fileName: "gemma-4-E4B.i1-Q5_K_M.gguf", sizeBytes: 5_762_896_640,
            sha256: "6672b7962494139138c4c98b498ceb97c06c00dc9000e5fc1760046522ac6351", minMemoryGB: 24, minTier: 2,
            revision: "8d1efb45cd65f46a70ac918584e2f0244117465f"
        ),
        ModelSpec(
            id: "gemma-3-4b", displayName: "Gemma 3 4B",
            summary: "As accurate as Gemma 4 E2B with a smaller download, but a little slower.", family: .gemma3,
            repo: "mradermacher/gemma-3-4b-pt-i1-GGUF", fileName: "gemma-3-4b-pt.i1-Q4_K_M.gguf", sizeBytes: 2_489_756_704,
            sha256: "dd8d55199c411d004b356ee927ae72748544ea4a98cd4b44133bc17029afae10", minMemoryGB: 16, minTier: 0,
            revision: "8cc4d48c12abc6e22e32e647fa6786c13527d5bb"
        ),
        ModelSpec(
            id: "gemma-3-1b", displayName: "Gemma 3 1B",
            summary: "The smallest and fastest. For Macs with 8 GB of memory.", family: .gemma3,
            repo: "mradermacher/gemma-3-1b-pt-i1-GGUF", fileName: "gemma-3-1b-pt.i1-Q4_K_M.gguf", sizeBytes: 806_057_088,
            sha256: "182cedf70c9b8ca472ccc4300b5ead82a9fa9b917416543b66217db761373da9", minMemoryGB: 0, minTier: 0,
            revision: "109e1bbbc3d5e27c50a81afae2da2004e2a0924e"
        ),
    ]

    public static func recommended(for hardware: HardwareProfile) -> ModelSpec? {
        let id: String =
            if hardware.memoryGB >= 24, hardware.tier >= 2 || (hardware.generation ?? 0) >= 4 {
                "gemma-4-e4b"
            } else if hardware.memoryGB >= 16 {
                "gemma-4-e2b"
            } else {
                "gemma-3-1b"
            }
        return curated.first { $0.id == id }
    }

    public static func installed() -> [ModelSpec] {
        let installed = curated.filter(\.isInstalled)
        let known = Set(curated.map(\.fileName))
        let files: [URL]
        do {
            files = try FileManager.default.contentsOfDirectory(
                at: AppPaths.models, includingPropertiesForKeys: [.fileSizeKey], options: [.skipsHiddenFiles]
            )
        } catch CocoaError.fileReadNoSuchFile {
            return installed
        } catch {
            Logger.gw("catalog").error("Listing models failed: \(error.localizedDescription, privacy: .public)")
            return installed
        }
        let custom = files
            .filter { $0.pathExtension.lowercased() == "gguf" && !known.contains($0.lastPathComponent) }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
            .map { url in
                let name = url.deletingPathExtension().lastPathComponent
                let size = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize).flatMap { $0 } ?? 0
                return ModelSpec(
                    id: "custom:\(url.lastPathComponent)", displayName: name, family: .custom, repo: "",
                    fileName: url.lastPathComponent, sizeBytes: Int64(size), sha256: nil, minMemoryGB: 0, minTier: 0
                )
            }
        return installed + custom
    }
}
