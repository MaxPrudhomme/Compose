import ArgumentParser
import ComposeCore
import Foundation

public struct RootOptions: ParsableArguments {
  @Option(
    name: [.customShort("f"), .customLong("file")], help: "Compose file path. May be repeated.")
  public var files: [String] = []

  @Option(name: [.customShort("p"), .customLong("project-name")], help: "Project name.")
  public var projectName: String?

  @Option(name: .customLong("env-file"), help: "Interpolation environment file. May be repeated.")
  public var environmentFiles: [String] = []

  @Option(name: .customLong("profile"), help: "Enable a profile. May be repeated.")
  public var profiles: [String] = []

  @Option(name: .customLong("project-directory"), help: "Alternate project directory.")
  public var projectDirectory: String?

  @Flag(name: .customLong("dry-run"), help: "Plan without mutating runtime resources.")
  public var dryRun = false

  @Option(name: .customLong("progress"), help: "Output mode: auto, tty, plain, json, or quiet.")
  public var progress = "auto"

  @Option(name: .customLong("parallel"), help: "Maximum independent operations.")
  public var parallel = 2

  public init() {}

  public func loadOptions(
    currentDirectory: String = FileManager.default.currentDirectoryPath,
    environment: [String: String] = ProcessInfo.processInfo.environment
  ) -> ComposeLoadOptions {
    ComposeLoadOptions(
      files: files,
      projectName: projectName,
      projectDirectory: projectDirectory,
      environmentFiles: environmentFiles,
      profiles: Set(profiles),
      currentDirectory: currentDirectory,
      environment: environment
    )
  }

  public mutating func validate() throws {
    guard parallel > 0 else {
      throw ValidationError("--parallel must be greater than zero")
    }
    guard ["auto", "tty", "plain", "json", "quiet"].contains(progress) else {
      throw ValidationError("--progress must be auto, tty, plain, json, or quiet")
    }
  }
}
