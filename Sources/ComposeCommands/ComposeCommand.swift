import ArgumentParser

public struct ComposeCommand: ParsableCommand {
  public static let configuration = CommandConfiguration(
    commandName: "compose",
    abstract: "Define and run multi-container applications with Apple Container.",
    version: BuildInfo.version,
    subcommands: [VersionCommand.self, DoctorCommand.self, ConfigCommand.self]
  )

  @OptionGroup
  public var options: RootOptions

  public init() {}

  public mutating func run() throws {
    throw CleanExit.helpRequest(self)
  }
}

public struct StandaloneComposeCommand: ParsableCommand {
  public static let configuration = CommandConfiguration(
    commandName: "container-compose",
    abstract: ComposeCommand.configuration.abstract,
    version: BuildInfo.version,
    subcommands: [VersionCommand.self, DoctorCommand.self, ConfigCommand.self]
  )

  @OptionGroup
  public var options: RootOptions

  public init() {}

  public mutating func run() throws {
    throw CleanExit.helpRequest(self)
  }
}
