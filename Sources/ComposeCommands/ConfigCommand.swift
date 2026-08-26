import AppleContainerDriver
import ArgumentParser
import ComposeCore
import Foundation

public struct ConfigCommand: ParsableCommand {
  public static let configuration = CommandConfiguration(
    commandName: "config",
    abstract: "Parse, merge, interpolate, and normalize the Compose project."
  )

  @OptionGroup
  public var options: RootOptions

  @Option(name: .long, help: "Output format: yaml or json.")
  public var format = "yaml"

  @Flag(name: .long, help: "Print service names, one per line.")
  public var services = false

  @Flag(name: .long, help: "Print declared profile names, one per line.")
  public var profiles = false

  @Flag(name: .long, help: "Print the interpolation environment.")
  public var environment = false

  @Flag(name: .long, help: "Print capabilities for the installed Apple Container CLI.")
  public var capabilities = false

  public init() {}

  public mutating func validate() throws {
    guard ["yaml", "json"].contains(format) else {
      throw ValidationError("--format must be yaml or json")
    }
    let modes = [services, profiles, environment, capabilities].filter { $0 }.count
    guard modes <= 1 else {
      throw ValidationError(
        "--services, --profiles, --environment, and --capabilities are mutually exclusive")
    }
  }

  public mutating func run() throws {
    if capabilities {
      try printCapabilities()
      return
    }

    let project = try ComposeLoader().load(options: options.loadOptions())
    for warning in ComposeCompatibility.warnings(in: project) {
      FileHandle.standardError.write(Data("warning: \(warning)\n".utf8))
    }
    for issue in ComposeCompatibility.issues(in: project) {
      FileHandle.standardError.write(Data("warning: \(issue.description)\n".utf8))
    }
    if services {
      for service in project.serviceNames { print(service) }
    } else if profiles {
      for profile in project.declaredProfiles { print(profile) }
    } else if environment {
      for (key, value) in project.interpolationEnvironment.sorted(by: { $0.key < $1.key }) {
        print("\(key)=\(value)")
      }
    } else if format == "json" {
      print(try project.json())
    } else {
      print(try project.yaml(), terminator: "")
    }
  }

  private func printCapabilities() throws {
    let executable = try ContainerExecutableResolver().resolve()
    let cli = ContainerCLI(executable: executable, runner: FoundationProcessRunner())
    let capabilities = CapabilityReport(
      appleContainer: ContainerCapabilities.known(for: try cli.version()),
      compose: try ComposeCompatibility.publishedMatrix()
    )
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    print(String(decoding: try encoder.encode(capabilities), as: UTF8.self))
  }
}

private struct CapabilityReport: Codable {
  let appleContainer: ContainerCapabilities
  let compose: ComposeCompatibilityMatrix
}
