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
  func run(executable: String, arguments: [String], environment: [String: String]?) throws
    -> ProcessResult
}

public struct FoundationProcessRunner: ProcessRunning {
  public init() {}

  public func run(
    executable: String,
    arguments: [String],
    environment: [String: String]? = nil
  ) throws -> ProcessResult {
    let process = Process()
    let stdout = Pipe()
    let stderr = Pipe()
    process.executableURL = URL(fileURLWithPath: executable)
    process.arguments = arguments
    process.environment = environment
    process.standardOutput = stdout
    process.standardError = stderr

    do {
      try process.run()
    } catch {
      throw ProcessRunnerError.couldNotLaunch(
        executable: executable, underlying: String(describing: error))
    }

    let output = CapturedData()
    let errors = CapturedData()
    let readers = DispatchGroup()
    readers.enter()
    DispatchQueue.global().async {
      output.set(stdout.fileHandleForReading.readDataToEndOfFile())
      readers.leave()
    }
    readers.enter()
    DispatchQueue.global().async {
      errors.set(stderr.fileHandleForReading.readDataToEndOfFile())
      readers.leave()
    }
    process.waitUntilExit()
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

  public var description: String {
    switch self {
    case .couldNotLaunch(let executable, let underlying):
      return "could not launch \(executable): \(underlying)"
    }
  }
}

extension ProcessRunnerError: LocalizedError {
  public var errorDescription: String? { description }
}
