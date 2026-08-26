import AppleContainerDriver
import ArgumentParser
import Foundation

public struct DoctorCommand: ParsableCommand {
  public static let configuration = CommandConfiguration(
    commandName: "doctor",
    abstract: "Check the Apple Container CLI and supported capabilities."
  )

  @Option(name: .long, help: "Output format: plain or json.")
  public var format = "plain"

  public init() {}

  public mutating func validate() throws {
    guard ["plain", "json"].contains(format) else {
      throw ValidationError("--format must be plain or json")
    }
  }

  public mutating func run() throws {
    let executable = try ContainerExecutableResolver().resolve()
    let report = try ContainerCLI(executable: executable, runner: FoundationProcessRunner())
      .doctor()
    if format == "json" {
      let encoder = JSONEncoder()
      encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
      let data = try encoder.encode(report)
      print(String(decoding: data, as: UTF8.self))
    } else {
      print("container executable: \(report.executable)")
      print("container version: \(report.version)")
      print("version supported: \(report.versionSupported ? "yes" : "no")")
      print("system available: \(report.systemAvailable ? "yes" : "no")")
      if !report.systemDetail.isEmpty { print("system detail: \(report.systemDetail)") }
      print("service aliases: unsupported")
      print("restart policies: unsupported")
      print("ongoing health: unsupported")
    }
    if !report.versionSupported || !report.systemAvailable {
      throw ExitCode.failure
    }
  }
}
