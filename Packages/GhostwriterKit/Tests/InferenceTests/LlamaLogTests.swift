import Testing
@testable import Inference

@Suite struct LlamaLogTests {
    @Test(arguments: [
        "graph_compute: ggml_backend_sched_graph_compute_async failed with error 1\n",
        "process_ubatch: failed to compute graph, compute status: 1\n",
        "decode: removing memory module entries for seq_id = 3, pos = [668, +inf)\n",
        "llama_decode: failed to decode, ret = 2\n",
    ])
    func abortedDecodeIsRecognized(message: String) {
        #expect(LlamaBackend.isAbortReport(message))
    }

    @Test(arguments: [
        "graph_compute: ggml_backend_sched_graph_compute_async failed with error -1\n",
        "process_ubatch: failed to compute graph, compute status: -2\n",
        "llama_decode: failed to decode, ret = -3\n",
        "decode: failed to find a memory slot for batch of size 512\n",
    ])
    func realFailuresAreNot(message: String) {
        #expect(!LlamaBackend.isAbortReport(message))
    }
}
