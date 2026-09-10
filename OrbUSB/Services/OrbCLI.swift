import Foundation
import OSLog
import Darwin

enum OrbStackError: Error, LocalizedError, Sendable, Equatable {
    case executableNotFound
    case commandFailed(String)
    case parseFailed(String)
    case deviceNotFound
    case orbStackNotRunning
    case timedOut
    case outputTooLarge

    var errorDescription: String? {
        switch self {
        case .executableNotFound: "OrbStack CLI not found"
        case .commandFailed(let detail):
            if detail.localizedCaseInsensitiveContains("busy") { "Device is busy" }
            else if detail.localizedCaseInsensitiveContains("permission") { "Permission required — open OrbStack" }
            else { "Unable to complete the request" }
        case .parseFailed: "Unable to read USB devices"
        case .deviceNotFound: "Device is no longer connected"
        case .orbStackNotRunning: "OrbStack is not running"
        case .timedOut: "OrbStack is not responding"
        case .outputTooLarge: "OrbStack returned too much data"
        }
    }

    var diagnostic: String {
        switch self {
        case .commandFailed(let text), .parseFailed(let text): text
        default: errorDescription ?? "Unknown error"
        }
    }

    static func commandFailure(_ stderr: String) -> OrbStackError {
        let message = stderr.lowercased()
        if message.contains("not running") || message.contains("failed to connect") || message.contains("connection refused") {
            return .orbStackNotRunning
        }
        if (message.contains("device") && message.contains("not found")) || message.contains("no such device") {
            return .deviceNotFound
        }
        return .commandFailed(stderr.trimmingCharacters(in: .whitespacesAndNewlines))
    }
}

struct CLIResult: Sendable {
    let stdout: String
    let stderr: String
    let terminationStatus: Int32
    let duration: TimeInterval
}

struct OrbCLI: Sendable {
    func findOrbExecutable() async throws -> URL {
        let paths = [
            "/usr/local/bin/orb",
            "/opt/homebrew/bin/orb",
            "/Applications/OrbStack.app/Contents/MacOS/bin/orb",
            FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Applications/OrbStack.app/Contents/MacOS/bin/orb").path
        ]
        for path in paths where FileManager.default.isExecutableFile(atPath: path) {
            return URL(fileURLWithPath: path)
        }
        if let result = try? await run(executable: URL(fileURLWithPath: "/usr/bin/which"), arguments: ["orb"], timeout: 3),
           result.terminationStatus == 0,
           let path = result.stdout.split(separator: "\n").first.map(String.init),
           path.hasPrefix("/"), FileManager.default.isExecutableFile(atPath: path) {
            return URL(fileURLWithPath: path)
        }
        throw OrbStackError.executableNotFound
    }

    func run(executable: URL, arguments: [String], timeout: TimeInterval = 12) async throws -> CLIResult {
        let execution = CommandExecution()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                execution.start(executable: executable, arguments: arguments, timeout: timeout, continuation: continuation)
            }
        } onCancel: {
            execution.cancel()
        }
    }
}

// All process and pipe state lives on one private queue. Nonblocking pipe reads
// prevent both full-pipe deadlocks and orphaned readers if a child inherits a pipe.
private final class CommandExecution: @unchecked Sendable {
    private let queue = DispatchQueue(label: "dev.orbusb.process")
    private let process = Process()
    private var continuation: CheckedContinuation<CLIResult, any Error>?
    private var output = Data()
    private var errorOutput = Data()
    private var outputEnded = false
    private var errorEnded = false
    private var readers: [DispatchSourceRead] = []
    private var status: Int32?
    private var cancelled = false
    private var finished = false
    private var started = Date()
    private var deadline: DispatchWorkItem?
    private let limit = 4 * 1024 * 1024

    func start(executable: URL, arguments: [String], timeout: TimeInterval,
               continuation: CheckedContinuation<CLIResult, any Error>) {
        queue.async { [self] in
            self.continuation = continuation
            if self.cancelled {
                self.finish(.failure(CancellationError()))
                return
            }
            self.started = Date()
            self.process.executableURL = executable
            self.process.arguments = arguments
            var environment = ProcessInfo.processInfo.environment
            environment["LC_ALL"] = "en_US.UTF-8"
            environment["NO_COLOR"] = "1"
            self.process.environment = environment
            self.process.standardInput = FileHandle.nullDevice
            let stdout = Pipe()
            let stderr = Pipe()
            self.process.standardOutput = stdout
            self.process.standardError = stderr
            self.process.terminationHandler = { [weak self] process in
                guard let self else { return }
                self.queue.async {
                    self.status = process.terminationStatus
                    self.completeIfReady()
                }
            }
            do {
                try self.process.run()
                self.read(stdout.fileHandleForReading, isError: false)
                self.read(stderr.fileHandleForReading, isError: true)
                let deadline = DispatchWorkItem { [weak self] in
                    self?.stop(because: OrbStackError.timedOut)
                }
                self.deadline = deadline
                self.queue.asyncAfter(deadline: .now() + timeout, execute: deadline)
            } catch {
                self.finish(.failure(error))
            }
        }
    }

    func cancel() {
        queue.async { [self] in
            self.cancelled = true
            // Cancellation may arrive before start installs the continuation.
            if self.continuation != nil { self.stop(because: CancellationError()) }
        }
    }

    private func read(_ handle: FileHandle, isError: Bool) {
        let fd = handle.fileDescriptor
        let flags = fcntl(fd, F_GETFL)
        _ = fcntl(fd, F_SETFL, flags | O_NONBLOCK)
        let source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: queue)
        source.setEventHandler { [weak self] in
            guard let self, !self.finished else { return }
            var buffer = [UInt8](repeating: 0, count: 16_384)
            while !self.finished {
                let count = Darwin.read(fd, &buffer, buffer.count)
                if count > 0 {
                    let size = isError ? self.errorOutput.count : self.output.count
                    guard size + count <= self.limit else {
                        self.stop(because: OrbStackError.outputTooLarge)
                        return
                    }
                    if isError { self.errorOutput.append(contentsOf: buffer.prefix(count)) }
                    else { self.output.append(contentsOf: buffer.prefix(count)) }
                } else if count == 0 {
                    self.readers.first(where: { $0.handle == fd })?.cancel()
                    if isError { self.errorEnded = true } else { self.outputEnded = true }
                    self.completeIfReady()
                    return
                } else if errno == EINTR {
                    continue
                } else if errno == EAGAIN || errno == EWOULDBLOCK {
                    return
                } else {
                    self.stop(because: OrbStackError.commandFailed("Unable to read command output"))
                }
            }
        }
        source.setCancelHandler { try? handle.close() }
        readers.append(source)
        source.resume()
    }

    private func stop(because error: any Error) {
        guard !finished else { return }
        if process.isRunning {
            process.terminate()
            let process = self.process
            queue.asyncAfter(deadline: .now() + 0.5) {
                if process.isRunning { kill(process.processIdentifier, SIGKILL) }
            }
        }
        finish(.failure(error))
    }

    private func completeIfReady() {
        guard !finished, let status, outputEnded, errorEnded else { return }
        let result = CLIResult(stdout: String(decoding: output, as: UTF8.self),
                               stderr: String(decoding: errorOutput, as: UTF8.self),
                               terminationStatus: status, duration: Date().timeIntervalSince(started))
        #if DEBUG
        Log.cli.debug("Command \(self.process.arguments?.joined(separator: " ") ?? "", privacy: .private) completed in \(result.duration) s; status \(status)")
        Log.cli.debug("stdout: \(result.stdout, privacy: .private) stderr: \(result.stderr, privacy: .private)")
        #endif
        finish(.success(result))
    }

    private func finish(_ result: Result<CLIResult, any Error>) {
        guard !finished else { return }
        finished = true
        deadline?.cancel()
        deadline = nil
        readers.forEach { $0.cancel() }
        readers.removeAll()
        process.terminationHandler = nil
        continuation?.resume(with: result)
        continuation = nil
    }
}
