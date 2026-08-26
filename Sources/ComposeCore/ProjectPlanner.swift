import Foundation

public struct CurrentContainer: Equatable, Sendable {
  public enum State: String, Equatable, Sendable {
    case running
    case stopped
  }

  public let id: String
  public let state: State
  public let labels: [String: String]

  public init(id: String, state: State, labels: [String: String]) {
    self.id = id
    self.state = state
    self.labels = labels
  }
}

public enum ReconciliationAction: Equatable, Sendable {
  case create(service: String, hash: String, labels: [String: String])
  case start(service: String, containerID: String)
  case recreate(service: String, containerID: String, hash: String, labels: [String: String])
  case noOp(service: String, containerID: String)
  case removeOrphan(service: String, containerID: String)
}

public struct ReconciliationOptions: Equatable, Sendable {
  public var forceRecreate: Bool
  public var noRecreate: Bool
  public var removeOrphans: Bool

  public init(forceRecreate: Bool = false, noRecreate: Bool = false, removeOrphans: Bool = false) {
    self.forceRecreate = forceRecreate
    self.noRecreate = noRecreate
    self.removeOrphans = removeOrphans
  }
}

public struct ProjectPlanner {
  public init() {}

  public func plan(
    project: ComposeProject,
    currentContainers: [CurrentContainer],
    refreshedServices: Set<String> = [],
    options: ReconciliationOptions = .init()
  ) throws -> [ReconciliationAction] {
    guard !options.forceRecreate || !options.noRecreate else {
      throw ComposeError("--force-recreate and --no-recreate are mutually exclusive")
    }
    guard let services = project.model["services"]?.objectValue else {
      throw ComposeError("normalized project does not contain services")
    }

    let owned = currentContainers.filter { $0.labels[ComposeLabels.project] == project.name }
    var actions: [ReconciliationAction] = []
    for serviceName in try dependencyOrder(services: services) {
      guard services[serviceName] != nil else { continue }
      let matches = owned.filter {
        $0.labels[ComposeLabels.service] == serviceName && $0.labels[ComposeLabels.oneoff] != "true"
      }
      guard matches.count <= 1 else {
        throw ComposeError(
          "service '\(serviceName)' has \(matches.count) owned containers; explicit recovery is required"
        )
      }

      let hash = try ServiceConfigHasher.hash(project: project, serviceName: serviceName)
      let labels = ComposeLabels.container(
        projectName: project.name,
        serviceName: serviceName,
        workingDirectory: project.workingDirectory,
        files: project.files,
        hash: hash
      )
      guard let existing = matches.first else {
        actions.append(.create(service: serviceName, hash: hash, labels: labels))
        continue
      }

      let matchesConfiguration = existing.labels[ComposeLabels.configHash] == hash
      if options.forceRecreate || (refreshedServices.contains(serviceName) && !options.noRecreate) {
        actions.append(
          .recreate(service: serviceName, containerID: existing.id, hash: hash, labels: labels))
      } else if matchesConfiguration {
        actions.append(
          existing.state == .running
            ? .noOp(service: serviceName, containerID: existing.id)
            : .start(service: serviceName, containerID: existing.id))
      } else if options.noRecreate {
        throw ComposeError(
          "service '\(serviceName)' configuration changed and --no-recreate was requested")
      } else {
        actions.append(
          .recreate(service: serviceName, containerID: existing.id, hash: hash, labels: labels))
      }
    }

    if options.removeOrphans {
      let declared = Set(services.keys)
      for orphan in owned where orphan.labels[ComposeLabels.oneoff] != "true" {
        guard let service = orphan.labels[ComposeLabels.service], !declared.contains(service) else {
          continue
        }
        actions.append(.removeOrphan(service: service, containerID: orphan.id))
      }
    }
    return actions
  }

  public func dependencyOrder(services: [String: JSONValue]) throws -> [String] {
    var temporary = Set<String>()
    var permanent = Set<String>()
    var ordered: [String] = []

    func visit(_ service: String, chain: [String]) throws {
      if permanent.contains(service) { return }
      guard temporary.insert(service).inserted else {
        throw ComposeError(
          "dependency cycle detected: \((chain + [service]).joined(separator: " -> "))")
      }
      defer { temporary.remove(service) }

      let dependencies = dependencyNames(from: services[service]?["depends_on"])
      for dependency in dependencies.sorted() {
        guard services[dependency] != nil else {
          throw ComposeError("service '\(service)' depends on undefined service '\(dependency)'")
        }
        try visit(dependency, chain: chain + [service])
      }
      permanent.insert(service)
      ordered.append(service)
    }

    for service in services.keys.sorted() {
      try visit(service, chain: [])
    }
    return ordered
  }

  private func dependencyNames(from value: JSONValue?) -> [String] {
    switch value {
    case .array(let values): return values.compactMap(\.stringValue)
    case .object(let values): return Array(values.keys)
    default: return []
    }
  }
}
