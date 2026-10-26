import Darwin
import Foundation

struct ProcessResult: Sendable {
    let exitCode: Int32
    let output: String
    let error: String
    func checked() throws -> String {
        guard exitCode == 0 else { throw SwitchError.failed(error.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "The system command failed (\(exitCode))." : error.trimmingCharacters(in: .whitespacesAndNewlines)) }
        return output.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

enum ProcessRunner {
    static func run(executable: String, arguments: [String], input: Data? = nil, timeout: TimeInterval = 12) async throws -> ProcessResult {
        let job = ProcessJob(executable: executable, arguments: arguments, input: input, timeout: timeout)
        return try await withTaskCancellationHandler {
            try await Task.detached(priority: .utility) { try job.run() }.value
        } onCancel: { job.cancel() }
    }
}

private final class ProcessJob: @unchecked Sendable {
    private let lock = NSLock()
    private let process = Process()
    private let input: Data?
    private let timeout: TimeInterval
    private var cancelled = false
    private var timedOut = false
    private var finished = false
    init(executable: String, arguments: [String], input: Data?, timeout: TimeInterval) {
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        self.input = input
        self.timeout = timeout
    }
    func cancel() {
        lock.lock()
        cancelled = true
        let running = process.isRunning
        lock.unlock()
        if running { process.terminate() }
    }
    func run() throws -> ProcessResult {
        lock.lock()
        let stopped = cancelled
        lock.unlock()
        if stopped { throw CancellationError() }
        let output = Pipe(), error = Pipe(), stdin = Pipe()
        process.standardOutput = output
        process.standardError = error
        process.standardInput = input == nil ? FileHandle.nullDevice : stdin
        try process.run()
        lock.lock()
        let cancelledDuringLaunch = cancelled
        lock.unlock()
        if cancelledDuringLaunch { process.terminate() }
        let outputBox = DataBox(), errorBox = DataBox()
        let readers = DispatchGroup()
        for (pipe, box) in [(output, outputBox), (error, errorBox)] {
            readers.enter()
            DispatchQueue.global(qos: .utility).async {
                box.data = pipe.fileHandleForReading.readDataToEndOfFile()
                readers.leave()
            }
        }
        if let input {
            try? stdin.fileHandleForWriting.write(contentsOf: input)
            try? stdin.fileHandleForWriting.close()
        }
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + timeout) { [self] in
            lock.lock()
            let shouldStop = !finished && process.isRunning
            if shouldStop { timedOut = true }
            lock.unlock()
            if shouldStop {
                process.terminate()
                DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 1) { [self] in
                    lock.lock()
                    if !finished && process.isRunning { kill(process.processIdentifier, SIGKILL) }
                    lock.unlock()
                }
            }
        }
        process.waitUntilExit()
        readers.wait()
        lock.lock()
        finished = true
        let exceeded = timedOut, wasCancelled = cancelled
        lock.unlock()
        if wasCancelled { throw CancellationError() }
        if exceeded { throw SwitchError.failed("The system command timed out. Check its permission in System Settings.") }
        return ProcessResult(exitCode: process.terminationStatus, output: String(decoding: outputBox.data, as: UTF8.self), error: String(decoding: errorBox.data, as: UTF8.self))
    }
}

private final class DataBox: @unchecked Sendable { var data = Data() }
