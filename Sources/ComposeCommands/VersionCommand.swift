import ArgumentParser

public struct VersionCommand: ParsableCommand {
  public static let configuration = CommandConfiguration(
    commandName: "version",
    abstract: "Show the Compose implementation version."
  )

  public init() {}

  public mutating func run() {
    print("container-compose \(BuildInfo.version)")
  }
}
