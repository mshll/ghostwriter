import Foundation
import GWCore
import llama
import os
import Synchronization

enum LlamaBackend {
    private static let initialized: Void = {
        llama_log_set({ level, text, _ in
            guard level == GGML_LOG_LEVEL_WARN || level == GGML_LOG_LEVEL_ERROR, let text else { return }
            let message = String(cString: text)
            if isAbortReport(message) {
                Logger.gw("llama").debug("\(message, privacy: .public)")
            } else {
                Logger.gw("llama").warning("\(message)")
            }
        }, nil)
        llama_backend_init()
    }()

    static func ensureInitialized() { initialized }

    static func isAbortReport(_ message: String) -> Bool {
        let line = message.trimmingCharacters(in: .whitespacesAndNewlines)
        return abortReports.contains(line) || line.hasPrefix("decode: removing memory module entries for seq_id")
    }

    private static let abortReports: Set<String> = [
        "graph_compute: ggml_backend_sched_graph_compute_async failed with error 1",
        "process_ubatch: failed to compute graph, compute status: 1",
        "llama_decode: failed to decode, ret = 2",
    ]
}

final class AbortSignal: Sendable {
    private let issued = Atomic<Int>(0)
    private let running = Atomic<Int>(0)

    var ticket: Int { issued.load(ordering: .relaxed) }
    var isCancelled: Bool { issued.load(ordering: .relaxed) != running.load(ordering: .relaxed) }

    func cancel() { _ = issued.wrappingAdd(1, ordering: .relaxed) }
    func begin(_ ticket: Int) { running.store(ticket, ordering: .relaxed) }
}

/// Owns a loaded model. Read-only after load, so it can be shared across threads.
final class LlamaModel: @unchecked Sendable {
    let pointer: OpaquePointer
    let vocab: OpaquePointer

    init(url: URL, gpuLayers: Int, vocabularyOnly: Bool = false) throws {
        LlamaBackend.ensureInitialized()
        var params = llama_model_default_params()
        params.n_gpu_layers = Int32(gpuLayers)
        params.load_mode = LLAMA_LOAD_MODE_MMAP
        params.vocab_only = vocabularyOnly
        guard let model = llama_model_load_from_file(url.path, params) else {
            throw InferenceError.modelLoadFailed(url.lastPathComponent)
        }
        if !vocabularyOnly,
           llama_model_is_recurrent(model) || llama_model_is_hybrid(model) || llama_model_is_diffusion(model)
            || llama_model_has_encoder(model)
        {
            llama_model_free(model)
            throw InferenceError.unsupportedModel("recurrent, hybrid, diffusion and encoder models cannot trim their prompt cache")
        }
        guard let vocab = llama_model_get_vocab(model) else {
            llama_model_free(model)
            throw InferenceError.modelLoadFailed(url.lastPathComponent)
        }
        pointer = model
        self.vocab = vocab
    }

    deinit { llama_model_free(pointer) }

    func metadata(_ key: String) -> String? {
        var buffer = [CChar](repeating: 0, count: 256)
        let length = llama_model_meta_val_str(pointer, key, &buffer, buffer.count)
        guard length >= 0 else { return nil }
        return String(decoding: buffer.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
    }
}

struct DecodeEntry {
    var token: Int32
    var position: Int
    var sequence: Int32
    var wantsLogits: Bool
}

protocol DecodeContext: AnyObject {
    var batchCapacity: Int { get }
    var contextSize: Int { get }
    func decode(_ entries: [DecodeEntry]) throws
    /// Logits of the last decode for its entry at `index`, which must have wanted logits (llama_get_logits_ith);
    /// negative values count outputs from the end, -1 being the last.
    func logits(at index: Int) -> UnsafeMutablePointer<Float>?
    func removeTokens(sequence: Int32, from position: Int) -> Bool
    func clearSequence(_ sequence: Int32)
    func copySequence(_ source: Int32, to destination: Int32)
    func maxPosition(sequence: Int32) -> Int
    func clearAll()
}

final class LlamaContext: DecodeContext {
    let pointer: OpaquePointer
    private let model: LlamaModel
    private let memory: OpaquePointer
    private var batch: llama_batch
    let batchCapacity: Int
    let microBatchSize: Int
    let contextSize: Int

    init(model: LlamaModel, config: EngineConfig, sequences: Int, abort: AbortSignal) throws {
        let microBatch = config.microBatchSize ?? (ProcessInfo.processInfo.physicalMemory < 20 << 30 ? 256 : 512)
        var params = llama_context_default_params()
        params.n_ctx = UInt32(config.contextSize)
        params.n_batch = UInt32(config.batchSize)
        params.n_ubatch = UInt32(min(microBatch, config.batchSize))
        params.n_seq_max = UInt32(sequences)
        params.n_threads = Int32(config.threads)
        params.n_threads_batch = Int32(config.batchThreads)
        params.flash_attn_type = config.flashAttention ? LLAMA_FLASH_ATTN_TYPE_AUTO : LLAMA_FLASH_ATTN_TYPE_DISABLED
        params.type_k = GGML_TYPE_F16
        params.type_v = GGML_TYPE_F16
        params.swa_full = true
        params.kv_unified = true
        params.no_perf = true
        params.abort_callback = { data in
            guard let data else { return false }
            return Unmanaged<AbortSignal>.fromOpaque(data).takeUnretainedValue().isCancelled
        }
        params.abort_callback_data = Unmanaged.passUnretained(abort).toOpaque()
        guard let context = llama_init_from_model(model.pointer, params) else { throw InferenceError.contextCreationFailed }
        guard let memory = llama_get_memory(context) else {
            llama_free(context)
            throw InferenceError.contextCreationFailed
        }
        pointer = context
        self.model = model
        self.memory = memory
        batchCapacity = Int(llama_n_batch(context))
        microBatchSize = Int(llama_n_ubatch(context))
        contextSize = Int(llama_n_ctx(context))
        batch = llama_batch_init(Int32(batchCapacity), 0, 1)
    }

    deinit {
        llama_batch_free(batch)
        llama_free(pointer)
    }

    func decode(_ entries: [DecodeEntry]) throws {
        precondition(entries.count <= batchCapacity, "batch overflow")
        for (index, entry) in entries.enumerated() {
            batch.token[index] = entry.token
            batch.pos[index] = Int32(entry.position)
            batch.n_seq_id[index] = 1
            batch.seq_id[index]?.pointee = entry.sequence
            batch.logits[index] = entry.wantsLogits ? 1 : 0
        }
        batch.n_tokens = Int32(entries.count)
        let status = llama_decode(pointer, batch)
        switch status {
        case 0: return
        case 2: throw CancellationError()
        default: throw InferenceError.decodeFailed(status)
        }
    }

    func logits(at index: Int) -> UnsafeMutablePointer<Float>? {
        llama_get_logits_ith(pointer, Int32(index))
    }

    func removeTokens(sequence: Int32, from position: Int) -> Bool {
        llama_memory_seq_rm(memory, sequence, Int32(position), -1)
    }

    func clearSequence(_ sequence: Int32) {
        _ = llama_memory_seq_rm(memory, sequence, -1, -1)
    }

    func copySequence(_ source: Int32, to destination: Int32) {
        llama_memory_seq_cp(memory, source, destination, -1, -1)
    }

    func maxPosition(sequence: Int32) -> Int {
        Int(llama_memory_seq_pos_max(memory, sequence))
    }

    func clearAll() {
        llama_memory_clear(memory, true)
    }
}
