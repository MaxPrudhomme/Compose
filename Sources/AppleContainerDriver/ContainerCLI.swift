import Foundation

public struct ContainerExecutableResolver {
  public init() {}

  public func resolve(environment: [String: String] = ProcessInfo.processInfo.environment) throws
    -> String
  {
    if let override = environment["CONTAINER_CLI"], !override.isEmpty {
      guard FileManager.default.isExecutableFile(atPath: override) else {
        throw ContainerCLIError.notExecutable(override)
      }
      return URL(fileURLWithPath: override).standardizedFileURL.path
    }

    if let path = environment["PATH"] {
      for directory in path.split(separator: ":", omittingEmptySubsequences: false) {
        let base = directory.isEmpty ? FileManager.default.currentDirectoryPath : String(directory)
        let candidate = URL(fileURLWithPath: base, isDirectory: true).appendingPathComponent(
          "container"
        ).path
        if FileManager.default.isExecutableFile(atPath: candidate) {
          return URL(fileURLWithPath: candidate).standardizedFileURL.resolvingSymlinksInPath().path
        }
      }
    }

    for candidate in ["/opt/homebrew/bin/container", "/usr/local/bin/container"] {
      if FileManager.default.isExecutableFile(atPath: candidate) {
        return URL(fileURLWithPath: candidate).resolvingSymlinksInPath().path
      }
    }
    throw ContainerCLIError.notFound
  }
}

public struct ContainerVersion: Equatable, Sendable {
  public let rawValue: String
  public let major: Int
  public let minor: Int
  public let patch: Int

  public init(rawValue: String) throws {
    self.rawValue = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
    let components = rawValue.split { !$0.isNumber }.compactMap { Int($0) }
    guard components.count >= 3 else {
      throw ContainerCLIError.unexpectedVersion(rawValue)
    }
    major = components[0]
    minor = components[1]
    patch = components[2]
  }

  public var isSupported: Bool {
    major == 1 && minor >= 2
  }
}

public struct ContainerCapabilities: Codable, Equatable, Sendable {
  public let structuredListOutput: Bool
  public let labels: Bool
  public let networks: Bool
  public let namedVolumes: Bool
  public let serviceAliases: Bool
  public let restartPolicies: Bool
  public let ongoingHealth: Bool

  public static func known(for version: ContainerVersion) -> ContainerCapabilities {
    ContainerCapabilities(
      structuredListOutput: version.isSupported,
      labels: version.isSupported,
      networks: version.isSupported,
      namedVolumes: version.isSupported,
      serviceAliases: false,
      restartPolicies: false,
      ongoingHealth: false
    )
  }
}

public struct ContainerDoctorReport: Codable, Equatable, Sendable {
  public let executable: String
  public let version: String
  public let versionSupported: Bool
  public let systemAvailable: Bool
  public let systemDetail: String
  public let capabilities: ContainerCapabilities
}

public struct ContainerCLI<Runner: ProcessRunning> {
  public let executable: String
  private let runner: Runner

  public init(executable: String, runner: Runner) {
    self.executable = executable
    self.runner = runner
  }

  public func invoke(_ arguments: [String]) throws -> ProcessResult {
    try runner.run(executable: executable, arguments: arguments, environment: nil)
  }

  public func version() throws -> ContainerVersion {
    let result = try invoke(["--version"])
    guard result.exitCode == 0 else {
      throw ContainerCLIError.commandFailed(
        arguments: result.arguments, exitCode: result.exitCode, detail: bounded(result.stderr))
    }
    return try ContainerVersion(rawValue: result.stdout)
  }

  public func doctor() throws -> ContainerDoctorReport {
    let version = try version()
    let status = try invoke(["system", "status", "--format", "json"])
    let detail = status.exitCode == 0 ? bounded(status.stdout) : bounded(status.stderr)
    return ContainerDoctorReport(
      executable: executable,
      version: version.rawValue,
      versionSupported: version.isSupported,
      systemAvailable: status.exitCode == 0,
      systemDetail: detail,
      capabilities: .known(for: version)
    )
  }

  public func listContainers() throws -> [RuntimeContainer] {
    try list(
      ["list", "--all", "--format", "json"],
      as: [RuntimeContainer].self
    )
  }

  public func listNetworks() throws -> [RuntimeNetwork] {
    try list(
      ["network", "list", "--format", "json"],
      as: [RuntimeNetwork].self
    )
  }

  public func listVolumes() throws -> [RuntimeVolume] {
    try list(
      ["volume", "list", "--format", "json"],
      as: [RuntimeVolume].self
    )
  }

  private func list<T: Decodable>(_ arguments: [String], as type: T.Type) throws -> T {
    let version = try version()
    let result = try invoke(arguments)
    guard result.exitCode == 0 else {
      throw ContainerCLIError.commandFailed(
        arguments: result.arguments, exitCode: result.exitCode, detail: bounded(result.stderr))
    }
    return try RuntimeOutputDecoder.decode(
      type, from: result.standardOutput, command: arguments, containerVersion: version.rawValue)
  }

  private func bounded(_ value: String, limit: Int = 2_048) -> String {
    String(value.trimmingCharacters(in: .whitespacesAndNewlines).prefix(limit))
  }
}

public enum ContainerCLIError: Error, Equatable, CustomStringConvertible {
  case notFound
  case notExecutable(String)
  case unexpectedVersion(String)
  case commandFailed(arguments: [String], exitCode: Int32, detail: String)

  public var description: String {
    switch self {
    case .notFound:
      return "Apple Container CLI not found; set CONTAINER_CLI or install 'container' on PATH"
    case .notExecutable(let path):
      return "CONTAINER_CLI is not executable: \(path)"
    case .unexpectedVersion(let value):
      return "could not parse Apple Container CLI version: \(value)"
    case .commandFailed(let arguments, let exitCode, let detail):
      let command = (["container"] + arguments).map { "\"\($0)\"" }.joined(separator: " ")
      return
        "Apple Container command failed with exit code \(exitCode): [\(command)]\(detail.isEmpty ? "" : ": \(detail)")"
    }
  }
}

extension ContainerCLIError: LocalizedError {
  public var errorDescription: String? { description }
}
