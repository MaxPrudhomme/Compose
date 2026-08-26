import AppleContainerDriver
import ArgumentParser
import ComposeCore
import Foundation

public struct UpCommand: ParsableCommand {
  public static let configuration = CommandConfiguration(
    commandName: "up", abstract: "Create and start services using Apple Container.")

  @OptionGroup public var options: RootOptions
  @Flag(name: [.customShort("d"), .long], help: "Run services in the background.")
  public var detach = false
  @Flag(name: .long, help: "Build images before creating containers.") public var build = false
  @Flag(name: .long, help: "Never build images.") public var noBuild = false
  @Option(name: .long, help: "Pull policy: always, missing, never, or build.")
  public var pull = "missing"
  @Flag(name: .long, help: "Recreate containers even when configuration matches.")
  public var forceRecreate = false
  @Flag(name: .long, help: "Fail instead of recreating changed containers.")
  public var noRecreate = false
  @Flag(name: .long, help: "Remove containers for undeclared services.")
  public var removeOrphans = false
  @Flag(name: .long, help: "Do not include service dependencies.") public var noDeps = false
  @Argument(help: "Services to start. Defaults to all enabled services.") public var services:
    [String] = []

  public init() {}

  public mutating func validate() throws {
    guard detach else { throw ValidationError("attached up is not implemented; use --detach") }
    guard !build || !noBuild else {
      throw ValidationError("--build and --no-build are mutually exclusive")
    }
    guard !forceRecreate || !noRecreate else {
      throw ValidationError("--force-recreate and --no-recreate are mutually exclusive")
    }
    guard ["always", "missing", "never", "build"].contains(pull) else {
      throw ValidationError("--pull must be always, missing, never, or build")
    }
  }

  public mutating func run() throws {
    let project = try ComposeLoader().load(options: options.loadOptions())
    printCompatibilityWarnings(for: project)
    try ComposeCompatibility.validateForExecution(project)
    try withProjectLock(project: project, command: "up", dryRun: options.dryRun) {
      let lifecycle = try makeLifecycle()
      var events = try lifecycle.ensureSystem(
        bootstrapIfNeeded: isStandaloneInvocation, dryRun: options.dryRun)
      events += try lifecycle.up(
        project: project,
        services: services,
        noDependencies: noDeps,
        options: .init(
          build: build,
          noBuild: noBuild,
          pull: pull,
          forceRecreate: forceRecreate,
          noRecreate: noRecreate,
          removeOrphans: removeOrphans,
          dryRun: options.dryRun,
          progress: options.progress,
          start: true
        )
      )
      try printEvents(events, options: options)
    }
  }
}

public struct CreateCommand: ParsableCommand {
  public static let configuration = CommandConfiguration(
    commandName: "create", abstract: "Create services without starting them.")

  @OptionGroup public var options: RootOptions
  @Flag(name: .long) public var build = false
  @Flag(name: .long) public var noBuild = false
  @Option(name: .long) public var pull = "missing"
  @Flag(name: .long) public var forceRecreate = false
  @Flag(name: .long) public var noRecreate = false
  @Flag(name: .long) public var noDeps = false
  @Argument public var services: [String] = []

  public init() {}

  public mutating func validate() throws {
    guard !build || !noBuild else {
      throw ValidationError("--build and --no-build are mutually exclusive")
    }
    guard !forceRecreate || !noRecreate else {
      throw ValidationError("--force-recreate and --no-recreate are mutually exclusive")
    }
    guard ["always", "missing", "never", "build"].contains(pull) else {
      throw ValidationError("--pull must be always, missing, never, or build")
    }
  }

  public mutating func run() throws {
    let project = try ComposeLoader().load(options: options.loadOptions())
    printCompatibilityWarnings(for: project)
    try ComposeCompatibility.validateForExecution(project)
    try withProjectLock(project: project, command: "create", dryRun: options.dryRun) {
      let lifecycle = try makeLifecycle()
      var events = try lifecycle.ensureSystem(
        bootstrapIfNeeded: isStandaloneInvocation, dryRun: options.dryRun)
      events += try lifecycle.up(
        project: project,
        services: services,
        noDependencies: noDeps,
        options: .init(
          build: build,
          noBuild: noBuild,
          pull: pull,
          forceRecreate: forceRecreate,
          noRecreate: noRecreate,
          dryRun: options.dryRun,
          progress: options.progress,
          start: false
        )
      )
      try printEvents(events, options: options)
    }
  }
}

public struct StartCommand: ParsableCommand {
  public static let configuration = CommandConfiguration(
    commandName: "start", abstract: "Start existing service containers.")
  @OptionGroup public var options: RootOptions
  @Flag(name: .long) public var noDeps = false
  @Argument public var services: [String] = []
  public init() {}
  public mutating func run() throws {
    try runExistingOperation("start", options: options, services: services, noDeps: noDeps)
  }
}

public struct StopCommand: ParsableCommand {
  public static let configuration = CommandConfiguration(
    commandName: "stop", abstract: "Stop service containers in reverse dependency order.")
  @OptionGroup public var options: RootOptions
  @Option(name: [.customShort("t"), .long], help: "Seconds before forceful termination.")
  public var timeout = 5
  @Flag(name: .long) public var noDeps = false
  @Argument public var services: [String] = []
  public init() {}
  public mutating func validate() throws {
    guard timeout >= 0 else { throw ValidationError("--timeout cannot be negative") }
  }
  public mutating func run() throws {
    try runExistingOperation(
      "stop", options: options, services: services, noDeps: noDeps, timeout: timeout)
  }
}

public struct RestartCommand: ParsableCommand {
  public static let configuration = CommandConfiguration(
    commandName: "restart", abstract: "Stop then start existing service containers.")
  @OptionGroup public var options: RootOptions
  @Option(name: [.customShort("t"), .long], help: "Seconds before forceful termination.")
  public var timeout = 5
  @Flag(name: .long) public var noDeps = false
  @Argument public var services: [String] = []
  public init() {}
  public mutating func validate() throws {
    guard timeout >= 0 else { throw ValidationError("--timeout cannot be negative") }
  }
  public mutating func run() throws {
    try runExistingOperation(
      "restart", options: options, services: services, noDeps: noDeps, timeout: timeout)
  }
}

public struct DownCommand: ParsableCommand {
  public static let configuration = CommandConfiguration(
    commandName: "down", abstract: "Stop and delete project containers and networks.")
  @OptionGroup public var options: RootOptions
  @Flag(name: [.customShort("v"), .long], help: "Also delete project-owned named volumes.")
  public var volumes = false
  @Option(name: [.customShort("t"), .long], help: "Seconds before forceful termination.")
  public var timeout = 5
  public init() {}
  public mutating func validate() throws {
    guard timeout >= 0 else { throw ValidationError("--timeout cannot be negative") }
  }
  public mutating func run() throws {
    let project = try ComposeLoader().load(options: options.loadOptions())
    try withProjectLock(project: project, command: "down", dryRun: options.dryRun) {
      let lifecycle = try makeLifecycle()
      var events = try lifecycle.ensureSystem(
        bootstrapIfNeeded: isStandaloneInvocation, dryRun: options.dryRun)
      events += try lifecycle.down(
        project: project, removeVolumes: volumes, timeout: timeout, dryRun: options.dryRun)
      try printEvents(events, options: options)
    }
  }
}

public struct PsCommand: ParsableCommand {
  public static let configuration = CommandConfiguration(
    commandName: "ps", abstract: "List project containers from runtime labels.")
  @OptionGroup public var options: RootOptions
  @Option(name: .long, help: "Output format: plain or json.") public var format = "plain"
  public init() {}
  public mutating func validate() throws {
    guard ["plain", "json"].contains(format) else {
      throw ValidationError("--format must be plain or json")
    }
  }
  public mutating func run() throws {
    let project = try ComposeLoader().load(options: options.loadOptions())
    let lifecycle = try makeLifecycle()
    _ = try lifecycle.ensureSystem(bootstrapIfNeeded: false, dryRun: false)
    let rows = try lifecycle.projectContainers(projectName: project.name).map(PsRow.init).sorted {
      ($0.service, $0.id) < ($1.service, $1.id)
    }
    if format == "json" {
      let encoder = JSONEncoder.compose()
      print(String(decoding: try encoder.encode(rows), as: UTF8.self))
    } else if options.progress != "quiet" {
      for row in rows { print("\(row.service)\t\(row.state)\t\(row.id)") }
    }
  }
}

private struct PsRow: Codable {
  let id: String
  let service: String
  let state: String

  init(_ container: RuntimeContainer) {
    id = container.id
    service = container.configuration.labels[ComposeLabels.service] ?? ""
    state = container.status.state
  }
}

private var isStandaloneInvocation: Bool {
  URL(fileURLWithPath: CommandLine.arguments[0]).lastPathComponent == "container-compose"
}

private func makeLifecycle() throws -> ComposeLifecycle<FoundationProcessRunner> {
  let executable = try ContainerExecutableResolver().resolve()
  return ComposeLifecycle(
    cli: ContainerCLI(executable: executable, runner: FoundationProcessRunner()))
}

private func withProjectLock(
  project: ComposeProject,
  command: String,
  dryRun: Bool,
  body: () throws -> Void
) throws {
  guard !dryRun else { return try body() }
  let lock = try ProjectLock.acquire(
    projectName: project.name,
    command: command,
    workingDirectory: project.workingDirectory.path
  )
  defer { lock.unlock() }
  try body()
}

private func runExistingOperation(
  _ operation: String,
  options: RootOptions,
  services: [String],
  noDeps: Bool,
  timeout: Int = 5
) throws {
  let project = try ComposeLoader().load(options: options.loadOptions())
  try withProjectLock(project: project, command: operation, dryRun: options.dryRun) {
    let lifecycle = try makeLifecycle()
    var events = try lifecycle.ensureSystem(
      bootstrapIfNeeded: isStandaloneInvocation, dryRun: options.dryRun)
    events += try lifecycle.operate(
      operation,
      project: project,
      services: services,
      noDependencies: noDeps,
      timeout: timeout,
      dryRun: options.dryRun
    )
    try printEvents(events, options: options)
  }
}

private func printEvents(_ events: [LifecycleEvent], options: RootOptions) throws {
  guard options.progress != "quiet" else { return }
  if options.progress == "json" {
    let encoder = JSONEncoder.compose()
    print(String(decoding: try encoder.encode(events), as: UTF8.self))
    return
  }
  for event in events {
    let scope = event.service.map { "\($0): " } ?? ""
    if options.dryRun, let arguments = event.arguments {
      let data = try JSONEncoder.compose(prettyPrinted: false).encode(["container"] + arguments)
      print("DRY-RUN \(scope)\(String(decoding: data, as: UTF8.self))")
    } else {
      print("\(scope)\(event.action)")
    }
  }
}

private func printCompatibilityWarnings(for project: ComposeProject) {
  for warning in ComposeCompatibility.warnings(in: project) {
    FileHandle.standardError.write(Data("warning: \(warning)\n".utf8))
  }
}
