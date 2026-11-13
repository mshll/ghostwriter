import Foundation
import Testing
@testable import Inference

@Suite struct LocalModelFinderTests {
    let home = FileManager.default.temporaryDirectory.appending(path: "gw-finder-\(UUID().uuidString)", directoryHint: .isDirectory)

    func gguf(_ metadata: [String: String]) -> Data {
        var data = Data("GGUF".utf8)
        func append<T: FixedWidthInteger>(_ value: T) { withUnsafeBytes(of: value.littleEndian) { data.append(contentsOf: $0) } }
        func append(_ string: String) {
            append(UInt64(string.utf8.count))
            data.append(contentsOf: string.utf8)
        }
        append(UInt32(3))
        append(UInt64(0))
        append(UInt64(metadata.count))
        for (key, value) in metadata.sorted(by: { $0.key < $1.key }) {
            append(key)
            append(UInt32(8))
            append(value)
        }
        return data
    }

    @discardableResult
    func place(_ data: Data, at path: String) throws -> URL {
        let url = home.appending(path: path)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: url)
        return url
    }

    @Test func candidatesFollowEachToolsLayout() {
        let spec = ModelSpec(
            id: "m", displayName: "M", family: .gemma4, repo: "org/repo-GGUF", fileName: "m.Q5.gguf",
            sizeBytes: 1, sha256: "abc", minMemoryGB: 0, minTier: 0
        )
        let paths = LocalModelFinder(home: URL(filePath: "/h")).candidates(for: spec).map(\.path)
        #expect(paths == [
            "/h/.cache/huggingface/hub/models--org--repo-GGUF/blobs/abc",
            "/h/Library/Caches/llama.cpp/org_repo-GGUF_m.Q5.gguf",
            "/h/.lmstudio/models/org/repo-GGUF/m.Q5.gguf",
            "/h/.cache/lm-studio/models/org/repo-GGUF/m.Q5.gguf",
            "/h/.ollama/models/blobs/sha256-abc",
        ])
    }

    @Test(arguments: [
        (["Gemma 3 1b Pt", "pt", "gemma-3-1b-pt.Q4_K_M.gguf"], false, true),
        (["Qwen3 0.6B Base", "Base"], false, true),
        (["Models", "Meta-Llama-3.1-8B.Q2_K.gguf"], false, true),
        (["Gemma 3 1b It", "it"], false, false),
        (["qwen2.5-0.5b-instruct"], false, false),
        (["Qwen3 Embedding 0.6B"], false, false),
        (["mmproj-model-f16.gguf"], false, false),
        (["gemma3:4b"], true, false),
        (["llama3:text"], true, true),
    ])
    func classifiesBaseModels(labels: [String], requiresBaseWord: Bool, expected: Bool) {
        #expect(LocalModelFinder.isBaseModel(labels: labels, requiresBaseWord: requiresBaseWord) == expected)
    }

    @Test func readsMetadataAndRejectsOtherFormats() throws {
        let model = try place(gguf(["general.name": "Tiny", "general.finetune": "pt", "general.architecture": "llama"]), at: "a.gguf")
        let metadata = try #require(GGUFMetadata(url: model))
        #expect(metadata.name == "Tiny" && metadata.finetune == "pt" && metadata.architecture == "llama" && metadata.type == nil)
        let encrypted = try place(Data([0x9f, 0x2d, 0xc0, 0x28]) + Data(count: 64), at: "b.gguf")
        #expect(GGUFMetadata(url: encrypted) == nil)
    }

    @Test func findsBaseModelsInEachToolsFolder() throws {
        let base = gguf(["general.name": "Tiny Base", "general.finetune": "pt"])
        let blob = try place(base, at: ".cache/huggingface/hub/models--org--tiny-GGUF/blobs/0123")
        let snapshot = home.appending(path: ".cache/huggingface/hub/models--org--tiny-GGUF/snapshots/abc/tiny.gguf")
        try FileManager.default.createDirectory(at: snapshot.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: snapshot, withDestinationURL: blob)
        try place(base + Data(count: 1), at: "Library/Caches/llama.cpp/org_tiny-GGUF_tiny.gguf")
        try place(base + Data(count: 2), at: ".lmstudio/models/org/tiny-GGUF/tiny-lm.gguf")
        try place(base + Data(count: 3), at: ".ollama/models/blobs/sha256-feed")
        try place(Data(#"{"layers":[{"mediaType":"application/vnd.ollama.image.model","digest":"sha256:feed"}]}"#.utf8),
                  at: ".ollama/models/manifests/registry.ollama.ai/library/tiny/1b-text")

        let found = LocalModelFinder(home: home).baseModels()
        #expect(Set(found.map(\.source)) == [.huggingFace, .llamaCpp, .lmStudio, .ollama])
        let hub = try #require(found.first { $0.source == .huggingFace })
        #expect(hub.url == blob.resolvingSymlinksInPath() && hub.fileName == "tiny.gguf" && hub.displayName == "Tiny Base")
        let ollama = try #require(found.first { $0.source == .ollama })
        #expect(ollama.displayName == "tiny:1b-text" && ollama.fileName == "tiny-1b-text.gguf")
    }

    @Test func skipsInstructSplitAndUnreadableFiles() throws {
        try place(gguf(["general.name": "Tiny It", "general.finetune": "it"]), at: ".lmstudio/models/org/a/tiny-it.gguf")
        try place(gguf(["general.name": "Tiny"]), at: ".lmstudio/models/org/b/tiny-00001-of-00002.gguf")
        try place(Data([0x9f, 0x2d, 0xc0, 0x28]) + Data(count: 64), at: ".lmstudio/models/org/c/sealed.gguf")
        try place(gguf(["general.name": "Tiny", "general.type": "adapter"]), at: ".lmstudio/models/org/d/lora.gguf")
        try place(gguf(["general.name": "Tiny"]), at: ".ollama/models/blobs/sha256-beef")
        try place(Data(#"{"layers":[{"mediaType":"application/vnd.ollama.image.model","digest":"sha256:beef"}]}"#.utf8),
                  at: ".ollama/models/manifests/registry.ollama.ai/library/tiny/latest")
        #expect(LocalModelFinder(home: home).baseModels().isEmpty)
    }
}
