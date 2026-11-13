import Foundation
import GWCore
import llama
import os

public struct FoundModel: Sendable, Hashable, Identifiable {
    public enum Source: String, Sendable {
        case huggingFace = "Hugging Face cache"
        case llamaCpp = "llama.cpp"
        case lmStudio = "LM Studio"
        case ollama = "Ollama"
    }

    public var url: URL
    public var fileName: String
    public var displayName: String
    public var source: Source
    public var sizeBytes: Int64

    public var id: String { url.path }
}

public struct LocalModelFinder: Sendable {
    private static let log = Logger.gw("finder")
    private static let excludedWords: Set<String> = [
        "it", "instruct", "chat", "sft", "dpo", "rlhf", "assistant", "embed", "embedding", "rerank", "reranker", "mmproj",
    ]
    private static let baseWords: Set<String> = ["base", "pt", "text"]

    public let home: URL

    public init(home: URL = FileManager.default.homeDirectoryForCurrentUser) {
        self.home = home
    }

    func candidates(for spec: ModelSpec) -> [URL] {
        guard let sha256 = spec.sha256, !spec.repo.isEmpty else { return [] }
        let flatRepo = spec.repo.replacingOccurrences(of: "/", with: "_")
        return [
            home.appending(path: ".cache/huggingface/hub/models--\(spec.repo.replacingOccurrences(of: "/", with: "--"))/blobs/\(sha256)"),
            home.appending(path: "Library/Caches/llama.cpp/\(flatRepo)_\(spec.fileName)"),
            home.appending(path: ".lmstudio/models/\(spec.repo)/\(spec.fileName)"),
            home.appending(path: ".cache/lm-studio/models/\(spec.repo)/\(spec.fileName)"),
            home.appending(path: ".ollama/models/blobs/sha256-\(sha256)"),
        ]
    }

    public func baseModels() -> [FoundModel] {
        let curatedSizes = Set(ModelCatalog.curated.map(\.sizeBytes))
        var seen = Set<String>()
        return entries()
            .filter { seen.insert($0.url.path).inserted }
            .compactMap(Self.describe)
            .filter { !curatedSizes.contains($0.sizeBytes) }
            .sorted { $0.displayName.localizedStandardCompare($1.displayName) == .orderedAscending }
    }

    struct Entry {
        var url: URL
        var fileName: String
        var source: FoundModel.Source
        var label: String?
    }

    func entries() -> [Entry] {
        var entries: [Entry] = []
        let hub = home.appending(path: ".cache/huggingface/hub")
        for repo in Self.children(of: hub) where repo.lastPathComponent.hasPrefix("models--") {
            for snapshot in Self.children(of: repo.appending(path: "snapshots")) {
                entries += Self.ggufFiles(under: snapshot).map { Entry(url: $0, fileName: $0.lastPathComponent, source: .huggingFace) }
            }
        }
        entries += Self.children(of: home.appending(path: "Library/Caches/llama.cpp"))
            .filter { $0.pathExtension.lowercased() == "gguf" }
            .map { Entry(url: $0, fileName: $0.lastPathComponent, source: .llamaCpp) }
        for root in [".lmstudio/models", ".cache/lm-studio/models"] {
            entries += Self.ggufFiles(under: home.appending(path: root)).map { Entry(url: $0, fileName: $0.lastPathComponent, source: .lmStudio) }
        }
        entries += ollamaEntries()
        return entries.map { entry in
            var entry = entry
            entry.url = entry.url.resolvingSymlinksInPath()
            return entry
        }
    }

    private func ollamaEntries() -> [Entry] {
        let models = home.appending(path: ".ollama/models")
        let manifests = models.appending(path: "manifests")
        guard let enumerator = FileManager.default.enumerator(at: manifests, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]) else { return [] }
        return enumerator.compactMap { item -> Entry? in
            guard let manifest = item as? URL else { return nil }
            let parts = Array(manifest.pathComponents.suffix(3))
            guard parts.count == 3, let digest = Self.modelDigest(in: manifest) else { return nil }
            let (namespace, model, tag) = (parts[0], parts[1], parts[2])
            let label = namespace == "library" ? "\(model):\(tag)" : "\(namespace)/\(model):\(tag)"
            return Entry(
                url: models.appending(path: "blobs/\(digest.replacingOccurrences(of: ":", with: "-"))"),
                fileName: "\(model)-\(tag).gguf", source: .ollama, label: label
            )
        }
    }

    private static func modelDigest(in manifest: URL) -> String? {
        struct Manifest: Decodable {
            struct Layer: Decodable { var mediaType: String; var digest: String }
            var layers: [Layer]
        }
        do {
            let parsed = try JSONDecoder().decode(Manifest.self, from: Data(contentsOf: manifest))
            return parsed.layers.first { $0.mediaType == "application/vnd.ollama.image.model" }?.digest
        } catch {
            log.debug("Skipping Ollama manifest \(manifest.lastPathComponent, privacy: .private): \(error.localizedDescription, privacy: .public)")
            return nil
        }
    }

    static func describe(_ entry: Entry) -> FoundModel? {
        guard entry.fileName.firstMatch(of: /-\d{5}-of-\d{5}\.gguf$/) == nil,
              let size = fileSize(entry.url),
              let metadata = GGUFMetadata(url: entry.url),
              metadata.type ?? "model" == "model",
              !(metadata.architecture ?? "").contains("bert"), metadata.architecture != "clip"
        else { return nil }
        let labels = [entry.label, metadata.name, metadata.finetune, entry.fileName].compactMap(\.self)
        guard isBaseModel(labels: labels, requiresBaseWord: entry.source == .ollama) else { return nil }
        let name = entry.label ?? metadata.name ?? entry.url.deletingPathExtension().lastPathComponent
        return FoundModel(url: entry.url, fileName: entry.fileName, displayName: name, source: entry.source, sizeBytes: size)
    }

    static func isBaseModel(labels: [String], requiresBaseWord: Bool) -> Bool {
        let words = Set(labels.flatMap { $0.lowercased().split { !$0.isLetter && !$0.isNumber }.map(String.init) })
        guard words.isDisjoint(with: excludedWords) else { return false }
        return !requiresBaseWord || !words.isDisjoint(with: baseWords)
    }

    private static func children(of folder: URL) -> [URL] {
        guard FileManager.default.fileExists(atPath: folder.path) else { return [] }
        do {
            return try FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles])
        } catch {
            log.error("Listing \(folder.lastPathComponent, privacy: .public) failed: \(error.localizedDescription, privacy: .public)")
            return []
        }
    }

    private static func ggufFiles(under folder: URL) -> [URL] {
        guard let enumerator = FileManager.default.enumerator(at: folder, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]) else { return [] }
        return enumerator.compactMap { $0 as? URL }.filter { $0.pathExtension.lowercased() == "gguf" }
    }

    private static func fileSize(_ url: URL) -> Int64? {
        do {
            let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
            guard attributes[.type] as? FileAttributeType == .typeRegular else { return nil }
            return (attributes[.size] as? NSNumber)?.int64Value
        } catch {
            log.debug("Skipping \(url.lastPathComponent, privacy: .private): \(error.localizedDescription, privacy: .public)")
            return nil
        }
    }
}

struct GGUFMetadata {
    var type: String?
    var architecture: String?
    var name: String?
    var finetune: String?

    init?(url: URL) {
        guard Self.hasMagic(url),
              let context = gguf_init_from_file(url.path, gguf_init_params(no_alloc: true, ctx: nil))
        else { return nil }
        defer { gguf_free(context) }
        func string(_ key: String) -> String? {
            let id = gguf_find_key(context, key)
            guard id >= 0, gguf_get_kv_type(context, id) == GGUF_TYPE_STRING, let value = gguf_get_val_str(context, id) else { return nil }
            return String(cString: value)
        }
        type = string("general.type")
        architecture = string("general.architecture")
        name = string("general.name")
        finetune = string("general.finetune")
    }

    private static func hasMagic(_ url: URL) -> Bool {
        do {
            let handle = try FileHandle(forReadingFrom: url)
            defer { try? handle.close() }
            return try handle.read(upToCount: 4) == Data("GGUF".utf8)
        } catch {
            Logger.gw("finder").debug("Reading \(url.lastPathComponent, privacy: .private) failed: \(error.localizedDescription, privacy: .public)")
            return false
        }
    }
}
