import Foundation

struct LocalModelFinder: Sendable {
    let home: URL

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
}
