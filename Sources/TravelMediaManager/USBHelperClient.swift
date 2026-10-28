import Foundation
import Darwin
import TravelArchiveCore

/// A private, serialized pipe protocol. The helper is bundled with the app;
/// starting the application never installs software or contacts a device.
final class USBHelperClient: @unchecked Sendable {
    private let queue = DispatchQueue(label: "travelarchive.usb-helper", qos: .userInitiated)
    private let lock = NSLock()
    private var process: Process?
    private var input: FileHandle?
    private var output: FileHandle?
    private var buffered = Data()

    struct Empty: Decodable, Sendable {}

    private final class RequestState: @unchecked Sendable {
        private let lock = NSLock()
        private var cancelled = false
        private var finished = false
        func cancel() { lock.lock(); cancelled = true; lock.unlock() }
        func finish() { lock.lock(); finished = true; lock.unlock() }
        var isCancelled: Bool { lock.lock(); defer { lock.unlock() }; return cancelled }
        var isPending: Bool { lock.lock(); defer { lock.unlock() }; return !finished }
    }

    func call<T: Decodable & Sendable>(_ command: String, arguments: [String: String] = [:],
                                      integers: [String: Int64] = [:],
                                      lists: [String: [String]] = [:],
                                      timeout: TimeInterval = 120,
                                      progress: @escaping @Sendable (ScanProgress) -> Void = { _ in }) async throws -> T {
        try Task.checkCancellation()
        let id = UUID().uuidString
        var request: [String: Any] = arguments
        for (key, value) in integers { request[key] = value }
        for (key, value) in lists { request[key] = value }
        request["command"] = command
        request["id"] = id
        let encoded = try JSONSerialization.data(withJSONObject: request) + Data([10])
        guard encoded.count <= 8 * 1_048_576 else {
            throw ArchiveError.invalid("单次归档清单过大，请缩小日期或地点范围。")
        }
        let state = RequestState()
        return try await withTaskCancellationHandler {
            let result: T = try await withCheckedThrowingContinuation { continuation in
                queue.async {
                    defer { state.finish() }
                    do {
                        if state.isCancelled { throw CancellationError() }
                        let process = try self.ensureProcess()
                        if state.isCancelled { self.cancel(); throw CancellationError() }
                        let timer = DispatchSource.makeTimerSource(queue: .global(qos: .utility))
                        timer.schedule(deadline: .now() + timeout)
                        timer.setEventHandler { [weak process] in
                            guard let process, state.isPending else { return }
                            self.terminate(process)
                        }
                        timer.resume()
                        defer { timer.cancel() }
                        guard let input = self.input else { throw ArchiveError.invalid("手机读取组件尚未就绪。") }
                        try input.write(contentsOf: encoded)
                        while true {
                            let data = try self.readLine()
                            guard let envelope = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                                  envelope["id"] as? String == id else {
                                throw ArchiveError.invalid("手机读取响应不一致，请重新扫描。")
                            }
                            if envelope["event"] as? String == "progress" {
                                progress(ScanProgress(visitedFiles: envelope["visitedFiles"] as? Int ?? 0,
                                                      currentFile: envelope["message"] as? String ?? "读取手机索引"))
                                continue
                            }
                            guard envelope["ok"] as? Bool == true else {
                                throw ArchiveError.invalid(envelope["error"] as? String ?? "无法读取 iPhone，请解锁并检查数据线。")
                            }
                            guard let payload = envelope["result"] else {
                                throw ArchiveError.invalid("手机读取组件返回了不完整的结果。")
                            }
                            let value = try JSONDecoder().decode(T.self, from: JSONSerialization.data(withJSONObject: payload))
                            continuation.resume(returning: value)
                            return
                        }
                    } catch {
                        // A failed request cannot leave an ambiguous stream or a
                        // live device session available to the next operation.
                        self.cancel()
                        self.input = nil
                        self.output = nil
                        self.buffered.removeAll(keepingCapacity: false)
                        continuation.resume(throwing: error)
                    }
                }
            }
            try Task.checkCancellation()
            return result
        } onCancel: { state.cancel(); self.cancel() }
    }

    func cancel() {
        lock.lock()
        let active = process
        process = nil
        lock.unlock()
        if let active { terminate(active) }
    }

    private func terminate(_ active: Process) {
        if active.isRunning { active.terminate() }
        // SIGTERM is handled by the helper to close AFC and StopSession. A
        // bounded fallback is necessary if a disconnected USB service hangs.
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 12) {
            if active.isRunning { kill(active.processIdentifier, SIGKILL) }
        }
    }

    private func ensureProcess() throws -> Process {
        lock.lock()
        if let active = process, active.isRunning { lock.unlock(); return active }
        lock.unlock()
        let helper = Bundle.main.bundleURL.appendingPathComponent("Contents/Helpers/USBHelper.app/Contents/MacOS/iphone-usb-helper")
        let bundled = Bundle.main.resourceURL?.appendingPathComponent("USBHelper/iphone-usb-helper")
        let development = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            .appendingPathComponent("work/usb-helper/dist/iphone-usb-helper/iphone-usb-helper")
        // Installed applications use their signed, bundled component only.
        // The working-directory fallback is for an unbundled Swift build.
        var candidates = [helper, bundled].compactMap { $0 }
        if Bundle.main.bundleURL.pathExtension != "app" { candidates.append(development) }
        guard let executable = candidates.first(where: {
            FileManager.default.isExecutableFile(atPath: $0.path)
        }) else { throw ArchiveError.invalid("应用缺少手机读取组件，请使用完整构建的应用。") }
        let active = Process()
        active.executableURL = executable
        // Keep transient index snapshots within the parent's sandbox container.
        var environment = ProcessInfo.processInfo.environment
        environment["TMPDIR"] = FileManager.default.temporaryDirectory.path
        active.environment = environment
        let stdinPipe = Pipe(), stdoutPipe = Pipe()
        active.standardInput = stdinPipe
        active.standardOutput = stdoutPipe
        // Protocol errors are returned as sanitized JSON; private framework
        // diagnostics must not leak filenames, coordinates, or device IDs.
        active.standardError = FileHandle.nullDevice
        try active.run()
        lock.lock()
        process = active
        lock.unlock()
        input = stdinPipe.fileHandleForWriting
        output = stdoutPipe.fileHandleForReading
        buffered = Data()
        return active
    }

    private func readLine() throws -> Data {
        while true {
            if let newline = buffered.firstIndex(of: 10) {
                let line = buffered.prefix(upTo: newline)
                buffered.removeSubrange(...newline)
                return Data(line)
            }
            guard buffered.count <= 32 * 1_048_576, let output else {
                throw ArchiveError.invalid("手机读取已中断或超时，请保持 iPhone 解锁，检查数据线后重新扫描。")
            }
            var bytes = [UInt8](repeating: 0, count: 64 * 1024)
            let count = Darwin.read(output.fileDescriptor, &bytes, bytes.count)
            if count < 0 && errno == EINTR { continue }
            guard count > 0 else {
                throw ArchiveError.invalid("手机读取已中断或超时，请保持 iPhone 解锁，检查数据线后重新扫描。")
            }
            buffered.append(contentsOf: bytes.prefix(count))
        }
    }

    deinit { cancel() }
}
