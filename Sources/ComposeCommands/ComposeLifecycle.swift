import AppleContainerDriver
import ComposeCore
import Foundation

public struct LifecycleEvent: Codable, Equatable, Sendable {
  public let action: String
  public let service: String?
  public let arguments: [String]?

  public init(action: String, service: String? = nil, arguments: [String]? = nil) {
    self.action = action
    self.service = service
    self.arguments = arguments
  }
}

public struct UpLifecycleOptions: Equatable, Sendable {
  public var build: Bool
  public var noBuild: Bool
  public var pull: String
  public var forceRecreate: Bool
  public var noRecreate: Bool
  public var removeOrphans: Bool
  public var dryRun: Bool
  public var progress: String
  public var start: Bool

  public init(
    build: Bool = false,
    noBuild: Bool = false,
    pull: String = "missing",
    forceRecreate: Bool = false,
    noRecreate: Bool = false,
    removeOrphans: Bool = false,
    dryRun: Bool = false,
    progress: String = "auto",
    start: Bool = true
  ) {
    self.build = build
    self.noBuild = noBuild
    self.pull = pull
    self.forceRecreate = forceRecreate
    self.noRecreate = noRecreate
    self.removeOrphans = removeOrphans
    self.dryRun = dryRun
    self.progress = progress
    self.start = start
  }
}

public final class ComposeLifecycle<Runner: ProcessRunning> {
  private let cli: ContainerCLI<Runner>

  public init(cli: ContainerCLI<Runner>) {
    self.cli = cli
  }

  public func ensureSystem(
    bootstrapIfNeeded: Bool,
    dryRun: Bool
  ) throws -> [LifecycleEvent] {
    let report = try cli.doctor()
    guard report.versionSupported else {
      throw ComposeError("unsupported Apple Container version: \(report.version)")
    }
    guard !report.systemAvailable else { return [] }
    guard bootstrapIfNeeded else {
      throw ComposeError(
        "Apple Container system is unavailable: \(report.systemDetail.isEmpty ? "unknown status" : report.systemDetail)"
      )
    }
    let arguments = ["system", "start", "--enable-kernel-install"]
    guard !dryRun else {
      throw ComposeError(
        "Apple Container system is unavailable; dry-run cannot bootstrap it. Run 'container system start' first."
      )
    }
    try cli.invokeChecked(
      arguments,
      options: .init(standardIO: .inherited, timeout: 180, forwardSignals: true))
    return [LifecycleEvent(action: "bootstrap", arguments: arguments)]
  }

  public func up(
    project sourceProject: ComposeProject,
    services selectedServices: [String] = [],
    noDependencies: Bool = false,
    options: UpLifecycleOptions = .init()
  ) throws -> [LifecycleEvent] {
    try ComposeCompatibility.validateForExecution(sourceProject)
    let project = try selectedProject(
      sourceProject, services: selectedServices, includeDependencies: !noDependencies)
    try validatePreflight(project)
    if !selectedServices.isEmpty, options.removeOrphans {
      throw ComposeError("--remove-orphans cannot be combined with selected services in v1")
    }

    var events: [LifecycleEvent] = []
    let refreshedServices = try prepareImages(
      project: project, options: options, events: &events)

    let currentNetworks = try cli.listNetworks()
    let currentVolumes = try cli.listVolumes()
    try prepareNetworks(
      project: project, current: currentNetworks, dryRun: options.dryRun, events: &events)
    try prepareVolumes(
      project: project, current: currentVolumes, dryRun: options.dryRun, events: &events)

    let currentContainers = try cli.listContainers().map(CurrentContainer.init)
    let runningContainerIDs = Set(
      currentContainers.filter { $0.state == .running }.map(\.id))
    let actions = try ProjectPlanner().plan(
      project: project,
      currentContainers: currentContainers,
      refreshedServices: refreshedServices,
      options: .init(
        forceRecreate: options.forceRecreate,
        noRecreate: options.noRecreate,
        removeOrphans: options.removeOrphans
      )
    )
    for action in actions {
      try apply(
        action,
        project: project,
        start: options.start,
        runningContainerIDs: runningContainerIDs,
        dryRun: options.dryRun,
        events: &events
      )
    }
    return events
  }

  public func operate(
    _ operation: String,
    project sourceProject: ComposeProject,
    services selectedServices: [String] = [],
    noDependencies: Bool = false,
    timeout: Int = 5,
    dryRun: Bool = false
  ) throws -> [LifecycleEvent] {
    let project = try selectedProject(
      sourceProject, services: selectedServices, includeDependencies: !noDependencies)
    guard let services = project.model["services"]?.objectValue else { return [] }
    let order = try ProjectPlanner().dependencyOrder(services: services)
    let owned = try ownedContainers(projectName: project.name)
    var byService: [String: CurrentContainer] = [:]
    for container in owned {
      guard let service = container.labels[ComposeLabels.service], services[service] != nil else {
        continue
      }
      guard byService[service] == nil else {
        throw ComposeError("service '\(service)' has multiple owned containers")
      }
      byService[service] = container
    }

    var events: [LifecycleEvent] = []
    let stopOrder = order.reversed()
    switch operation {
    case "start":
      for service in order {
        guard let container = byService[service], container.state == .stopped else { continue }
        try perform(
          ["start", container.id], action: "start", service: service,
          dryRun: dryRun, events: &events)
      }
    case "stop":
      for service in stopOrder {
        guard let container = byService[service], container.state == .running else { continue }
        try perform(
          ["stop", "--time", String(timeout), container.id], action: "stop", service: service,
          dryRun: dryRun, processTimeout: max(120, TimeInterval(timeout) + 10), events: &events)
      }
    case "restart":
      for service in stopOrder {
        guard let container = byService[service], container.state == .running else { continue }
        try perform(
          ["stop", "--time", String(timeout), container.id], action: "stop", service: service,
          dryRun: dryRun, processTimeout: max(120, TimeInterval(timeout) + 10), events: &events)
      }
      for service in order {
        guard let container = byService[service] else { continue }
        try perform(
          ["start", container.id], action: "start", service: service,
          dryRun: dryRun, events: &events)
      }
    default:
      throw ComposeError("unsupported lifecycle operation '\(operation)'")
    }
    return events
  }

  public func down(
    project: ComposeProject,
    removeVolumes: Bool,
    timeout: Int,
    dryRun: Bool
  ) throws -> [LifecycleEvent] {
    let containers = try ownedContainers(projectName: project.name)
    let services = project.model["services"]?.objectValue ?? [:]
    let declaredOrder = try ProjectPlanner().dependencyOrder(services: services).reversed()
    let orderedIDs = Dictionary(grouping: containers) {
      $0.labels[ComposeLabels.service] ?? ""
    }
    var ordered = declaredOrder.flatMap { orderedIDs[$0] ?? [] }
    let knownIDs = Set(ordered.map(\.id))
    ordered += containers.filter { !knownIDs.contains($0.id) }

    var events: [LifecycleEvent] = []
    for container in ordered {
      let service = container.labels[ComposeLabels.service]
      if container.state == .running {
        try perform(
          ["stop", "--time", String(timeout), container.id], action: "stop", service: service,
          dryRun: dryRun, processTimeout: max(120, TimeInterval(timeout) + 10), events: &events)
      }
      try perform(
        ["delete", container.id], action: "delete", service: service,
        dryRun: dryRun, events: &events)
    }

    for network in try cli.listNetworks()
    where network.configuration.labels[ComposeLabels.project] == project.name {
      try perform(
        ["network", "delete", network.configuration.name], action: "delete-network",
        dryRun: dryRun, events: &events)
    }
    if removeVolumes {
      for volume in try cli.listVolumes()
      where volume.configuration.labels[ComposeLabels.project] == project.name {
        try perform(
          ["volume", "delete", volume.configuration.name], action: "delete-volume",
          dryRun: dryRun, events: &events)
      }
    }
    return events
  }

  public func projectContainers(projectName: String) throws -> [RuntimeContainer] {
    try cli.listContainers().filter {
      $0.configuration.labels[ComposeLabels.project] == projectName
    }
  }

  private func prepareImages(
    project: ComposeProject,
    options: UpLifecycleOptions,
    events: inout [LifecycleEvent]
  ) throws -> Set<String> {
    guard let services = project.model["services"]?.objectValue else { return [] }
    var refreshedServices = Set<String>()
    let order = try ProjectPlanner().dependencyOrder(services: services)
    for name in order {
      guard let service = services[name] else { continue }
      let mustBuild = service["build"] != nil && (options.build || service["image"] == nil)
      if mustBuild {
        guard !options.noBuild else {
          throw ComposeError("service '\(name)' requires a build but --no-build was requested")
        }
        if let arguments = try ComposeToContainer.buildArguments(
          project: project,
          serviceName: name,
          progress: options.progress,
          pull: options.pull == "always" || options.pull == "build"
        ) {
          try perform(
            arguments, action: "build", service: name, dryRun: options.dryRun,
            longRunning: true, events: &events)
          refreshedServices.insert(name)
        }
      } else if options.pull == "always" {
        let image = try ComposeToContainer.imageReference(
          project: project, serviceName: name, service: service)
        var arguments = ["image", "pull"]
        if let platform = service["platform"]?.stringValue {
          arguments += ["--platform", platform]
        }
        arguments.append(image)
        try perform(
          arguments, action: "pull", service: name, dryRun: options.dryRun,
          longRunning: true, events: &events)
        refreshedServices.insert(name)
      } else if options.pull == "never" {
        let image = try ComposeToContainer.imageReference(
          project: project, serviceName: name, service: service)
        try perform(
          ["image", "inspect", image], action: "inspect-image", service: name,
          dryRun: options.dryRun, events: &events)
      }
    }
    return refreshedServices
  }

  private func prepareNetworks(
    project: ComposeProject,
    current: [RuntimeNetwork],
    dryRun: Bool,
    events: inout [LifecycleEvent]
  ) throws {
    let referenced = Set(
      project.model["services"]?.objectValue?.values.flatMap {
        $0["networks"]?.objectValue?.keys ?? [String: JSONValue]().keys
      } ?? [])
    for logicalName in referenced.sorted() {
      guard let network = project.model["networks"]?[logicalName],
        let name = network["name"]?.stringValue
      else {
        throw ComposeError("network '\(logicalName)' is not defined")
      }
      let matches = current.filter { $0.configuration.name == name }
      guard matches.count <= 1 else { throw ComposeError("network '\(name)' is ambiguous") }
      if let existing = matches.first {
        if network["external"] != .bool(true),
          existing.configuration.labels[ComposeLabels.project] != project.name
        {
          throw ComposeError(
            "network '\(name)' exists but is not owned by project '\(project.name)'")
        }
        continue
      }
      if network["external"] == .bool(true) {
        throw ComposeError("external network '\(name)' does not exist")
      }
      try perform(
        ComposeToContainer.networkCreateArguments(
          logicalName: logicalName, network: network, projectName: project.name),
        action: "create-network", dryRun: dryRun, events: &events)
    }
  }

  private func prepareVolumes(
    project: ComposeProject,
    current: [RuntimeVolume],
    dryRun: Bool,
    events: inout [LifecycleEvent]
  ) throws {
    let referenced = Set(
      project.model["services"]?.objectValue?.values.flatMap { service in
        service["volumes"]?.arrayValue?.compactMap { $0["source"]?.stringValue } ?? []
      } ?? [])
    for logicalName in referenced.sorted() {
      guard let volume = project.model["volumes"]?[logicalName],
        let name = volume["name"]?.stringValue
      else { continue }
      let matches = current.filter { $0.configuration.name == name }
      guard matches.count <= 1 else { throw ComposeError("volume '\(name)' is ambiguous") }
      if let existing = matches.first {
        if volume["external"] != .bool(true),
          existing.configuration.labels[ComposeLabels.project] != project.name
        {
          throw ComposeError(
            "volume '\(name)' exists but is not owned by project '\(project.name)'")
        }
        continue
      }
      if volume["external"] == .bool(true) {
        throw ComposeError("external volume '\(name)' does not exist")
      }
      try perform(
        ComposeToContainer.volumeCreateArguments(
          logicalName: logicalName, volume: volume, projectName: project.name),
        action: "create-volume", dryRun: dryRun, events: &events)
    }
  }

  private func apply(
    _ action: ReconciliationAction,
    project: ComposeProject,
    start: Bool,
    runningContainerIDs: Set<String>,
    dryRun: Bool,
    events: inout [LifecycleEvent]
  ) throws {
    switch action {
    case .create(let service, _, let labels):
      try create(
        service: service, labels: labels, project: project, start: start,
        dryRun: dryRun, events: &events)
    case .start(let service, let containerID):
      if start {
        try perform(
          ["start", containerID], action: "start", service: service,
          dryRun: dryRun, events: &events)
      } else {
        events.append(.init(action: "no-op", service: service))
      }
    case .recreate(let service, let containerID, _, let labels):
      if runningContainerIDs.contains(containerID) {
        try perform(
          ["stop", containerID], action: "stop", service: service,
          dryRun: dryRun, events: &events)
      }
      try perform(
        ["delete", containerID], action: "delete", service: service,
        dryRun: dryRun, events: &events)
      try create(
        service: service, labels: labels, project: project, start: start,
        dryRun: dryRun, events: &events)
    case .noOp(let service, _):
      events.append(.init(action: "no-op", service: service))
    case .removeOrphan(let service, let containerID):
      if runningContainerIDs.contains(containerID) {
        try perform(
          ["stop", containerID], action: "stop-orphan", service: service,
          dryRun: dryRun, events: &events)
      }
      try perform(
        ["delete", containerID], action: "delete-orphan", service: service,
        dryRun: dryRun, events: &events)
    }
  }

  private func create(
    service: String,
    labels: [String: String],
    project: ComposeProject,
    start: Bool,
    dryRun: Bool,
    events: inout [LifecycleEvent]
  ) throws {
    let arguments = try ComposeToContainer.createArguments(
      project: project, serviceName: service, labels: labels)
    try perform(
      arguments, action: "create", service: service, dryRun: dryRun, events: &events)
    if start {
      let name =
        project.model["services"]?[service]?["container_name"]?.stringValue
        ?? "\(project.name)-\(service)-1"
      try perform(
        ["start", name], action: "start", service: service,
        dryRun: dryRun, events: &events)
    }
  }

  private func perform(
    _ arguments: [String],
    action: String,
    service: String? = nil,
    dryRun: Bool,
    longRunning: Bool = false,
    processTimeout: TimeInterval = 120,
    events: inout [LifecycleEvent]
  ) throws {
    events.append(
      .init(
        action: action, service: service, arguments: CommandRedaction.redact(arguments)))
    guard !dryRun else { return }
    let options =
      longRunning
      ? ProcessOptions(standardIO: .inherited, timeout: nil, forwardSignals: true)
      : ProcessOptions(standardIO: .captured, timeout: processTimeout, forwardSignals: true)
    try cli.invokeChecked(arguments, options: options)
  }

  private func validatePreflight(_ project: ComposeProject) throws {
    guard let services = project.model["services"]?.objectValue else { return }
    var ports = Set<String>()
    var volumeUsers: [String: [String]] = [:]
    for (name, service) in services {
      if let context = service["build"]?["context"]?.stringValue,
        !FileManager.default.fileExists(atPath: context)
      {
        throw ComposeError("service '\(name)' build context does not exist: \(context)")
      }
      for volume in service["volumes"]?.arrayValue ?? [] {
        if volume["type"] == .string("bind"), let source = volume["source"]?.stringValue,
          !FileManager.default.fileExists(atPath: source)
        {
          throw ComposeError("service '\(name)' bind source does not exist: \(source)")
        }
        if volume["type"] == .string("volume"), let source = volume["source"]?.stringValue {
          volumeUsers[source, default: []].append(name)
        }
      }
      for port in service["ports"]?.arrayValue ?? [] {
        guard let published = port["published"]?.stringValue else { continue }
        let key = [
          port["host_ip"]?.stringValue ?? "0.0.0.0",
          published,
          port["protocol"]?.stringValue ?? "tcp",
        ].joined(separator: "|")
        guard ports.insert(key).inserted else {
          throw ComposeError("published port \(published) is declared more than once")
        }
      }
    }
    for (volume, users) in volumeUsers where users.count > 1 {
      throw ComposeError(
        "named volume '\(volume)' is shared by services \(users.sorted().joined(separator: ", ")); Apple Container cannot attach it safely to multiple service VMs"
      )
    }
    _ = try ProjectPlanner().dependencyOrder(services: services)
  }

  private func selectedProject(
    _ project: ComposeProject,
    services requested: [String],
    includeDependencies: Bool
  ) throws -> ComposeProject {
    guard !requested.isEmpty else { return project }
    guard let all = project.model["services"]?.objectValue else { return project }
    var selected = Set<String>()

    func add(_ name: String) throws {
      guard let service = all[name] else {
        throw ComposeError("no such service: \(name)")
      }
      guard selected.insert(name).inserted else { return }
      if includeDependencies {
        for dependency in service["depends_on"]?.objectValue?.keys ?? Dictionary().keys {
          try add(dependency)
        }
      }
    }
    for name in requested { try add(name) }

    var services: [String: JSONValue] = [:]
    for name in selected {
      guard var service = all[name]?.objectValue else { continue }
      if !includeDependencies { service.removeValue(forKey: "depends_on") }
      services[name] = .object(service)
    }
    let model = project.model.setting("services", to: .object(services))
    return ComposeProject(
      name: project.name,
      workingDirectory: project.workingDirectory,
      files: project.files,
      model: model,
      interpolationEnvironment: project.interpolationEnvironment,
      declaredProfiles: project.declaredProfiles
    )
  }

  private func ownedContainers(projectName: String) throws -> [CurrentContainer] {
    try cli.listContainers().map(CurrentContainer.init).filter {
      $0.labels[ComposeLabels.project] == projectName
        && $0.labels[ComposeLabels.oneoff] != "true"
    }
  }
}

extension CurrentContainer {
  fileprivate init(_ runtime: RuntimeContainer) {
    self.init(
      id: runtime.id,
      state: runtime.status.state == "running" ? .running : .stopped,
      labels: runtime.configuration.labels
    )
  }
}
