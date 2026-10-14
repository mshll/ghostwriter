import Synchronization

enum Deadline {
    static func run<T: Sendable>(
        within timeout: Duration, _ operation: @escaping @Sendable () async -> T
    ) async -> T? {
        await withCheckedContinuation { continuation in
            let once = ResumeOnce(continuation)
            let timer = Task {
                do {
                    try await Task.sleep(for: timeout)
                } catch {
                    return
                }
                once.resume(nil)
            }
            Task {
                let value = await operation()
                timer.cancel()
                once.resume(value)
            }
        }
    }
}

private final class ResumeOnce<T: Sendable>: Sendable {
    private let slot: Mutex<CheckedContinuation<T?, Never>?>

    init(_ continuation: CheckedContinuation<T?, Never>) {
        slot = Mutex(continuation)
    }

    func resume(_ value: T?) {
        slot.withLock { $0.take() }?.resume(returning: value)
    }
}
