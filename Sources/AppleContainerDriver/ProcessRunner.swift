import Darwin
import Foundation

public struct ProcessResult: Equatable, Sendable {
  public let executable: String
  public let arguments: [String]
  public let exitCode: Int32
  public let standardOutput: Data
  public let standardError: Data

  public init(
    executable: String,
    arguments: [String],
    exitCode: Int32,
    standardOutput: Data,
    standardError: Data
  ) {
    self.executable = executable
    self.arguments = arguments
    self.exitCode = exitCode
    self.standardOutput = standardOutput
    self.standardError = standardError
  }

  public var stdout: String {
    String(decoding: standardOutput, as: UTF8.self)
  }

  public var stderr: String {
    String(decoding: standardError, as: UTF8.self)
  }
}

public protocol ProcessRunning {
  func run(
    executable: String,
    arguments: [String],
    environment: [String: String]?,
    options: ProcessOptions
  ) throws
    -> ProcessResult
}

public enum ProcessStandardIO: Equatable, Sendable {
  case captured
  case inherited
}

public struct ProcessOptions: Equatable, Sendable {
  public var standardIO: ProcessStandardIO
  public var timeout: TimeInterval?
  public var forwardSignals: Bool

  public init(
    standardIO: ProcessStandardIO = .captured,
    timeout: TimeInterval? = 30,
    forwardSignals: Bool = false
  ) {
    self.standardIO = standardIO
    self.timeout = timeout
    self.forwardSignals = forwardSignals
  }
}

extension ProcessRunning {
  public func run(
    executable: String,
    arguments: [String],
    environment: [String: String]? = nil
  ) throws -> ProcessResult {
    try run(
      executable: executable,
      arguments: arguments,
      environment: environment,
      options: .init()
    )
  }
}

public struct FoundationProcessRunner: ProcessRunning {
  public init() {}

  public func run(
    executable: String,
    arguments: [String],
    environment: [String: String]? = nil,
    options: ProcessOptions = .init()
  ) throws -> ProcessResult {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: executable)
    process.arguments = arguments
    process.environment = environment

    let stdout: Pipe?
    let stderr: Pipe?
    switch options.standardIO {
    case .captured:
      stdout = Pipe()
      stderr = Pipe()
      process.standardOutput = stdout
      process.standardError = stderr
    case .inherited:
      stdout = nil
      stderr = nil
      process.standardInput = FileHandle.standardInput
      process.standardOutput = FileHandle.standardOutput
      process.standardError = FileHandle.standardError
    }

    let terminated = DispatchSemaphore(value: 0)
    process.terminationHandler = { _ in terminated.signal() }

    do {
      try process.run()
    } catch {
      throw ProcessRunnerError.couldNotLaunch(
        executable: executable, underlying: String(describing: error))
    }

    let signalForwarder = options.forwardSignals ? SignalForwarder(process: process) : nil
    defer { signalForwarder?.cancel() }

    let output = CapturedData()
    let errors = CapturedData()
    let readers = DispatchGroup()
    if let stdout {
      readers.enter()
      DispatchQueue.global().async {
        output.set(stdout.fileHandleForReading.readDataToEndOfFile())
        readers.leave()
      }
    }
    if let stderr {
      readers.enter()
      DispatchQueue.global().async {
        errors.set(stderr.fileHandleForReading.readDataToEndOfFile())
        readers.leave()
      }
    }

    let waitResult: DispatchTimeoutResult
    if let timeout = options.timeout {
      waitResult = terminated.wait(timeout: .now() + timeout)
    } else {
      terminated.wait()
      waitResult = .success
    }
    if waitResult == .timedOut {
      process.terminate()
      if terminated.wait(timeout: .now() + 2) == .timedOut {
        kill(process.processIdentifier, SIGKILL)
        terminated.wait()
      }
      readers.wait()
      throw ProcessRunnerError.timedOut(
        executable: executable, arguments: arguments, timeout: options.timeout ?? 0)
    }
    readers.wait()

    return ProcessResult(
      executable: executable,
      arguments: arguments,
      exitCode: process.terminationStatus,
      standardOutput: output.value,
      standardError: errors.value
    )
  }
}

private final class CapturedData: @unchecked Sendable {
  private let lock = NSLock()
  private var storage = Data()

  var value: Data {
    lock.withLock { storage }
  }

  func set(_ value: Data) {
    lock.withLock { storage = value }
  }
}

public enum ProcessRunnerError: Error, Equatable, CustomStringConvertible {
  case couldNotLaunch(executable: String, underlying: String)
  case timedOut(executable: String, arguments: [String], timeout: TimeInterval)

  public var description: String {
    switch self {
    case .couldNotLaunch(let executable, let underlying):
      return "could not launch \(executable): \(underlying)"
    case .timedOut(let executable, let arguments, let timeout):
      let command = ([executable] + CommandRedaction.redact(arguments))
        .map { "\"\($0)\"" }.joined(separator: " ")
      return "process timed out after \(timeout) seconds: [\(command)]"
    }
  }
}

private final class SignalForwarder {
  private let interruptSource: DispatchSourceSignal
  private let terminateSource: DispatchSourceSignal
  private let previousInterrupt: sig_t
  private let previousTerminate: sig_t

  init(process: Process) {
    previousInterrupt = Darwin.signal(SIGINT, SIG_IGN)
    previousTerminate = Darwin.signal(SIGTERM, SIG_IGN)
    interruptSource = DispatchSource.makeSignalSource(signal: SIGINT, queue: .global())
    terminateSource = DispatchSource.makeSignalSource(signal: SIGTERM, queue: .global())
    interruptSource.setEventHandler {
      if process.isRunning { Darwin.kill(process.processIdentifier, SIGINT) }
    }
    terminateSource.setEventHandler {
      if process.isRunning { Darwin.kill(process.processIdentifier, SIGTERM) }
    }
    interruptSource.resume()
    terminateSource.resume()
  }

  func cancel() {
    interruptSource.cancel()
    terminateSource.cancel()
    Darwin.signal(SIGINT, previousInterrupt)
    Darwin.signal(SIGTERM, previousTerminate)
  }
}

extension ProcessRunnerError: LocalizedError {
  public var errorDescription: String? { description }
}
