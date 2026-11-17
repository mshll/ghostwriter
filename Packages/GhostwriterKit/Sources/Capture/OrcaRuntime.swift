import Darwin
import Foundation
import GWCore
import os

/// Reads the active terminal of a running Orca app through the local socket its `orca` command-line tool uses.
/// Orca reports the text typed into a coding agent's prompt as the terminal's draft. It reports no draft at a shell
/// prompt, and none for an empty agent prompt either.
enum OrcaRuntime {
    struct Terminal: Equatable {
        var draft: String?
        var screen: [String]
    }

    private static let log = Logger.gw("capture.orca")
    private static let runtimeFile = URL.applicationSupportDirectory.appending(path: "orca/orca-runtime.json")
    private static let timeout = timeval(tv_sec: 0, tv_usec: 150_000)
    private static let responseLimit = 1 << 20

    static func activeTerminal(pid: pid_t) -> Terminal? {
        guard let runtime = runtime(pid: pid) else { return nil }
        guard let handle = call(runtime, ResolveActive.self, method: "terminal.resolveActive", params: [:])?.handle else {
            return nil
        }
        let read = call(runtime, Read.self, method: "terminal.read", params: ["terminal": handle, "screen": true])
        guard let terminal = read?.terminal else { return nil }
        return Terminal(draft: terminal.draft, screen: terminal.tail ?? [])
    }

    // MARK: Protocol

    private struct RuntimeFile: Decodable {
        struct Transport: Decodable {
            var kind: String
            var endpoint: String
        }

        var pid: Int32
        var authToken: String
        var transports: [Transport]
    }

    private struct Runtime {
        var socketPath: String
        var token: String
    }

    private struct Response<Result: Decodable>: Decodable {
        var ok: Bool
        var result: Result?
    }

    private struct ResolveActive: Decodable {
        var handle: String?
    }

    private struct Read: Decodable {
        struct TerminalRead: Decodable {
            var draft: String?
            var tail: [String]?
        }

        var terminal: TerminalRead?
    }

    private static func runtime(pid: pid_t) -> Runtime? {
        let file: RuntimeFile
        do {
            file = try JSONDecoder().decode(RuntimeFile.self, from: Data(contentsOf: runtimeFile))
        } catch {
            log.error("Reading the Orca runtime file failed: \(error.localizedDescription, privacy: .public)")
            return nil
        }
        guard file.pid == pid else {
            log.info("The Orca runtime file belongs to another process")
            return nil
        }
        guard let socket = file.transports.first(where: { $0.kind == "unix" }) else {
            log.info("Orca offers no local socket")
            return nil
        }
        return Runtime(socketPath: socket.endpoint, token: file.authToken)
    }

    private static func call<Result: Decodable>(
        _ runtime: Runtime, _ type: Result.Type, method: String, params: [String: any Sendable]
    ) -> Result? {
        let request: Data
        do {
            let body: [String: Any] = ["id": UUID().uuidString, "authToken": runtime.token, "method": method, "params": params]
            request = try JSONSerialization.data(withJSONObject: body) + Data("\n".utf8)
        } catch {
            log.error("Encoding \(method, privacy: .public) failed: \(error.localizedDescription, privacy: .public)")
            return nil
        }
        guard let reply = exchange(request, path: runtime.socketPath) else {
            log.info("\(method, privacy: .public) got no reply from Orca")
            return nil
        }
        do {
            let response = try JSONDecoder().decode(Response<Result>.self, from: reply)
            guard response.ok else {
                log.info("Orca refused \(method, privacy: .public)")
                return nil
            }
            return response.result
        } catch {
            log.error("Decoding \(method, privacy: .public) failed: \(error.localizedDescription, privacy: .public)")
            return nil
        }
    }

    private static func exchange(_ request: Data, path: String) -> Data? {
        let descriptor = socket(AF_UNIX, SOCK_STREAM, 0)
        guard descriptor >= 0 else { return nil }
        defer { close(descriptor) }
        var timeout = timeout
        setsockopt(descriptor, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
        setsockopt(descriptor, SOL_SOCKET, SO_SNDTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
        setsockopt(descriptor, SOL_SOCKET, SO_NOSIGPIPE, [Int32(1)], socklen_t(MemoryLayout<Int32>.size))

        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        let capacity = MemoryLayout.size(ofValue: address.sun_path)
        guard path.utf8.count < capacity else { return nil }
        withUnsafeMutableBytes(of: &address.sun_path) { buffer in
            buffer.copyBytes(from: path.utf8)
        }
        let connected = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                connect(descriptor, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard connected == 0 else { return nil }

        let sent = request.withUnsafeBytes { send(descriptor, $0.baseAddress, $0.count, 0) }
        guard sent == request.count else { return nil }

        var reply = Data()
        var buffer = [UInt8](repeating: 0, count: 64 * 1024)
        while reply.last != UInt8(ascii: "\n"), reply.count < responseLimit {
            let received = recv(descriptor, &buffer, buffer.count, 0)
            guard received > 0 else { return nil }
            reply.append(contentsOf: buffer[0..<received])
        }
        return reply.last == UInt8(ascii: "\n") ? reply : nil
    }
}
