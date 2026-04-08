import Foundation

// MARK: - ProcessRunnerError

/// Errors that can occur when running an external process through ``ProcessRunner``.
enum ProcessRunnerError: Error, Sendable {
    /// The executable was not found or is not executable at the given path.
    case executableNotFound(String)
    /// The process failed to launch due to an underlying error.
    case launchFailed(Error)
    /// The process exceeded the allowed time limit.
    case timeout(tool: String, seconds: TimeInterval)
    /// The process produced more output than the allowed limit.
    case outputTooLarge
    /// The task was cancelled before the process completed.
    case cancelled
}

// MARK: - ProcessResult

/// The outcome of running an external process.
struct ProcessResult: Sendable {
    /// The raw bytes captured from the process's standard output.
    let stdout: Data
    /// The raw bytes captured from the process's standard error.
    let stderr: Data
    /// The exit code returned by the process.
    let exitCode: Int32
}

// MARK: - ProcessHandle

/// A `Sendable` wrapper around `Foundation.Process` for safe transfer across
/// isolation boundaries.
///
/// `Foundation.Process` is not `Sendable`. This wrapper uses `@unchecked Sendable`
/// so the handle can be captured inside `@Sendable` closures such as
/// `withTaskCancellationHandler(operation:onCancel:)`.
/// The caller is responsible for ensuring thread-safe access to the underlying process.
private final class ProcessHandle: @unchecked Sendable {
    let process: Process
    init(_ process: Process) { self.process = process }
}

// MARK: - ProcessRunner

/// A safe, actor-isolated wrapper around `Foundation.Process` for running
/// external command-line tools.
///
/// All methods are `async` and support cooperative cancellation. The actor
/// never calls `waitUntilExit()` — instead it uses `terminationHandler`
/// paired with `withCheckedThrowingContinuation` so the calling task can
/// be suspended without blocking a thread.
///
/// ## Features
/// - Path validation before launch
/// - Configurable timeout with automatic termination
/// - Cooperative cancellation via structured concurrency
/// - Output size limit (10 MB) to prevent runaway memory growth
/// - Line-by-line streaming variant for progressive output handling
///
/// ## Usage
/// ```swift
/// let runner = ProcessRunner()
/// let result = try await runner.run(
///     executablePath: "/usr/bin/du",
///     arguments: ["-sh", "/Users"],
///     timeout: 30
/// )
/// ```
actor ProcessRunner {

    // MARK: - Constants

    /// Maximum allowed size for captured stdout data (10 MB).
    private static let maxOutputSize: Int = 10 * 1024 * 1024

    // MARK: - Initialization

    init() {}

    // MARK: - Public API

    /// Runs an external process and captures its complete output.
    ///
    /// The process is launched asynchronously and monitored via its
    /// `terminationHandler`. If the task is cancelled before the process
    /// exits, the process is terminated immediately. If the configured
    /// timeout elapses, the process is also terminated.
    ///
    /// - Parameters:
    ///   - executablePath: Absolute path to the executable binary.
    ///   - arguments: Command-line arguments to pass to the process.
    ///   - timeout: Maximum wall-clock time in seconds. Pass `nil` for no limit.
    /// - Returns: A ``ProcessResult`` containing stdout, stderr, and the exit code.
    /// - Throws: ``ProcessRunnerError`` if the executable is missing, launch fails,
    ///   the timeout expires, output exceeds the limit, or the task is cancelled.
    func run(
        executablePath: String,
        arguments: [String] = [],
        timeout: TimeInterval? = nil
    ) async throws -> ProcessResult {
        try validateExecutable(at: executablePath)

        let process = Process()
        process.executableURL = URL(fileURLWithPath: executablePath)
        process.arguments = arguments

        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe

        let handle = ProcessHandle(process)

        // Accumulated output buffers — accessed only from the readabilityHandler
        // callbacks which Foundation serializes per-FileHandle.
        let stdoutAccumulator = OutputAccumulator(limit: Self.maxOutputSize)
        let stderrAccumulator = OutputAccumulator(limit: Self.maxOutputSize)

        stdoutPipe.fileHandleForReading.readabilityHandler = { fileHandle in
            let data = fileHandle.availableData
            if !data.isEmpty {
                stdoutAccumulator.append(data)
            }
        }

        stderrPipe.fileHandleForReading.readabilityHandler = { fileHandle in
            let data = fileHandle.availableData
            if !data.isEmpty {
                stderrAccumulator.append(data)
            }
        }

        return try await launchAndAwait(
            handle: handle,
            stdoutPipe: stdoutPipe,
            stderrPipe: stderrPipe,
            stdoutAccumulator: stdoutAccumulator,
            stderrAccumulator: stderrAccumulator,
            timeout: timeout,
            toolName: executablePath
        )
    }

    /// Runs an external process and streams its standard output line by line.
    ///
    /// Each complete line (delimited by `\n`) is passed to the `onLine` closure
    /// as it arrives. The closure is called on a background thread from the
    /// pipe's `readabilityHandler` — callers must handle synchronization if needed.
    ///
    /// After the process exits, the complete captured stdout and stderr are
    /// returned in a ``ProcessResult``.
    ///
    /// - Parameters:
    ///   - executablePath: Absolute path to the executable binary.
    ///   - arguments: Command-line arguments to pass to the process.
    ///   - timeout: Maximum wall-clock time in seconds. Pass `nil` for no limit.
    ///   - onLine: A closure invoked for each complete line of stdout output.
    ///     Called on a background thread.
    /// - Returns: A ``ProcessResult`` containing the full stdout, stderr, and exit code.
    /// - Throws: ``ProcessRunnerError`` if the executable is missing, launch fails,
    ///   the timeout expires, output exceeds the limit, or the task is cancelled.
    func runWithLineOutput(
        executablePath: String,
        arguments: [String] = [],
        timeout: TimeInterval? = nil,
        onLine: @escaping @Sendable (String) -> Void
    ) async throws -> ProcessResult {
        try validateExecutable(at: executablePath)

        let process = Process()
        process.executableURL = URL(fileURLWithPath: executablePath)
        process.arguments = arguments

        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe

        let handle = ProcessHandle(process)

        let stdoutAccumulator = OutputAccumulator(limit: Self.maxOutputSize)
        let stderrAccumulator = OutputAccumulator(limit: Self.maxOutputSize)

        // Line parsing state — accessed only from the single readabilityHandler
        // callback for stdoutPipe, which Foundation serializes.
        let lineParser = LineParser(onLine: onLine)

        stdoutPipe.fileHandleForReading.readabilityHandler = { fileHandle in
            let data = fileHandle.availableData
            if !data.isEmpty {
                stdoutAccumulator.append(data)
                lineParser.feed(data)
            } else {
                // EOF — flush any trailing partial line.
                lineParser.flush()
            }
        }

        stderrPipe.fileHandleForReading.readabilityHandler = { fileHandle in
            let data = fileHandle.availableData
            if !data.isEmpty {
                stderrAccumulator.append(data)
            }
        }

        return try await launchAndAwait(
            handle: handle,
            stdoutPipe: stdoutPipe,
            stderrPipe: stderrPipe,
            stdoutAccumulator: stdoutAccumulator,
            stderrAccumulator: stderrAccumulator,
            timeout: timeout,
            toolName: executablePath
        )
    }

    // MARK: - Private Helpers

    /// Validates that the file at `path` exists and is executable.
    private func validateExecutable(at path: String) throws {
        guard FileManager.default.isExecutableFile(atPath: path) else {
            throw ProcessRunnerError.executableNotFound(path)
        }
    }

    /// Launches the process, installs cancellation/timeout handlers, and awaits
    /// termination through a continuation.
    ///
    /// This is the shared implementation for both ``run`` and ``runWithLineOutput``.
    private func launchAndAwait(
        handle: ProcessHandle,
        stdoutPipe: Pipe,
        stderrPipe: Pipe,
        stdoutAccumulator: OutputAccumulator,
        stderrAccumulator: OutputAccumulator,
        timeout: TimeInterval?,
        toolName: String
    ) async throws -> ProcessResult {
        // nonisolated(unsafe) is needed because the continuation and timeout task
        // are captured inside @Sendable closures but we guarantee single-resume
        // semantics through the TerminationState helper.
        let terminationState = TerminationState()

        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                // Wire up termination handler before launching.
                handle.process.terminationHandler = { _ in
                    // Clean up readability handlers to stop reading.
                    stdoutPipe.fileHandleForReading.readabilityHandler = nil
                    stderrPipe.fileHandleForReading.readabilityHandler = nil

                    // Read any remaining buffered data.
                    let trailingStdout = stdoutPipe.fileHandleForReading.readDataToEndOfFile()
                    if !trailingStdout.isEmpty {
                        stdoutAccumulator.append(trailingStdout)
                    }
                    let trailingStderr = stderrPipe.fileHandleForReading.readDataToEndOfFile()
                    if !trailingStderr.isEmpty {
                        stderrAccumulator.append(trailingStderr)
                    }

                    guard terminationState.claimResume() else { return }

                    if stdoutAccumulator.overflowed {
                        continuation.resume(throwing: ProcessRunnerError.outputTooLarge)
                        return
                    }

                    let result = ProcessResult(
                        stdout: stdoutAccumulator.data,
                        stderr: stderrAccumulator.data,
                        exitCode: handle.process.terminationStatus
                    )
                    continuation.resume(returning: result)
                }

                // Attempt launch.
                do {
                    try handle.process.run()
                } catch {
                    stdoutPipe.fileHandleForReading.readabilityHandler = nil
                    stderrPipe.fileHandleForReading.readabilityHandler = nil
                    guard terminationState.claimResume() else { return }
                    continuation.resume(throwing: ProcessRunnerError.launchFailed(error))
                    return
                }

                // Install timeout if requested.
                if let timeout {
                    let capturedHandle = handle
                    let capturedState = terminationState
                    Task.detached {
                        try? await Task.sleep(for: .seconds(timeout))
                        if capturedHandle.process.isRunning {
                            capturedHandle.process.terminate()
                            guard capturedState.claimResume() else { return }
                            continuation.resume(
                                throwing: ProcessRunnerError.timeout(
                                    tool: toolName,
                                    seconds: timeout
                                )
                            )
                        }
                    }
                }
            }
        } onCancel: {
            if handle.process.isRunning {
                handle.process.terminate()
            }
            if terminationState.claimResume() {
                // The continuation will be resumed by terminationHandler
                // after terminate() triggers it. But if the process already
                // exited and terminationHandler already ran, we need to
                // release the claim so we don't double-resume.
                // In practice, terminate() synchronously triggers the
                // terminationHandler on a background thread, so this path
                // guards against the race where both fire.
                terminationState.releaseResume()
            }
        }
    }
}

// MARK: - TerminationState

/// Thread-safe one-shot flag that ensures only one code path resumes the continuation.
///
/// Multiple sources can race to resume:
/// - The normal `terminationHandler`
/// - A timeout `Task`
/// - The cancellation handler
///
/// `claimResume()` returns `true` exactly once. All subsequent calls return `false`.
private final class TerminationState: @unchecked Sendable {
    private let lock = NSLock()
    private var resumed = false

    /// Attempts to claim the right to resume the continuation.
    ///
    /// - Returns: `true` if this call won the race, `false` if another path already claimed it.
    func claimResume() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        if resumed { return false }
        resumed = true
        return true
    }

    /// Releases a previously claimed resume right.
    ///
    /// Used when the cancellation handler claims resume but then decides
    /// to let the termination handler actually perform the resume.
    func releaseResume() {
        lock.lock()
        defer { lock.unlock() }
        resumed = false
    }
}

// MARK: - OutputAccumulator

/// Thread-safe buffer for accumulating process output with a size limit.
///
/// `readabilityHandler` callbacks are serialized per `FileHandle` by Foundation,
/// but the accumulated data is also read from the `terminationHandler` callback.
/// The lock ensures safe access across these two contexts.
private final class OutputAccumulator: @unchecked Sendable {
    private let lock = NSLock()
    private var buffer = Data()
    private let limit: Int
    private(set) var overflowed = false

    init(limit: Int) {
        self.limit = limit
    }

    /// Appends data to the buffer. If the total exceeds the limit,
    /// sets ``overflowed`` to `true` and stops accumulating.
    func append(_ newData: Data) {
        lock.lock()
        defer { lock.unlock() }
        guard !overflowed else { return }
        if buffer.count + newData.count > limit {
            overflowed = true
            return
        }
        buffer.append(newData)
    }

    /// Returns a copy of the accumulated data.
    var data: Data {
        lock.lock()
        defer { lock.unlock() }
        return buffer
    }
}

// MARK: - LineParser

/// Splits a stream of `Data` chunks into newline-delimited strings
/// and forwards each complete line to a callback.
///
/// Handles partial lines that span across multiple `readabilityHandler`
/// invocations by buffering incomplete trailing content.
private final class LineParser: @unchecked Sendable {
    private let onLine: @Sendable (String) -> Void
    private var remainder = Data()

    init(onLine: @escaping @Sendable (String) -> Void) {
        self.onLine = onLine
    }

    /// Processes incoming data, extracting and emitting complete lines.
    func feed(_ data: Data) {
        remainder.append(data)
        emitCompleteLines()
    }

    /// Emits any remaining partial line as a final line.
    func flush() {
        guard !remainder.isEmpty else { return }
        if let line = String(data: remainder, encoding: .utf8) {
            onLine(line)
        }
        remainder.removeAll()
    }

    private func emitCompleteLines() {
        let newline = UInt8(ascii: "\n")
        while let newlineIndex = remainder.firstIndex(of: newline) {
            let lineData = remainder[remainder.startIndex..<newlineIndex]
            if let line = String(data: lineData, encoding: .utf8) {
                onLine(line)
            }
            remainder = Data(remainder[remainder.index(after: newlineIndex)...])
        }
    }
}
