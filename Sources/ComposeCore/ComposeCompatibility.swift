import Foundation

public enum CompatibilityState: String, Codable, Equatable, Sendable {
  case native
  case emulated
  case rejected
  case planned
}

public struct ComposeCompatibilityMatrix: Codable, Equatable, Sendable {
  public struct Baseline: Codable, Equatable, Sendable {
    public let appleContainer: String
    public let dockerComposeOracle: String
    public let schemaVersion: Int
  }

  public let baseline: Baseline
  public let features: [String: CompatibilityState]
  public let states: [CompatibilityState]
}

public struct CompatibilityIssue: Equatable, Sendable {
  public let service: String?
  public let field: String
  public let state: CompatibilityState
  public let reason: String

  public init(service: String?, field: String, state: CompatibilityState, reason: String) {
    self.service = service
    self.field = field
    self.state = state
    self.reason = reason
  }

  public var description: String {
    let scope = service.map { "service '\($0)' " } ?? ""
    return "\(scope)field '\(field)' is \(state.rawValue): \(reason)"
  }
}

public enum ComposeCompatibility {
  public static func publishedMatrix() throws -> ComposeCompatibilityMatrix {
    let url = Bundle.module.url(
      forResource: "compose-compatibility", withExtension: "json", subdirectory: nil)
    guard let url else { throw ComposeError("bundled compatibility matrix is missing") }
    return try JSONDecoder().decode(ComposeCompatibilityMatrix.self, from: Data(contentsOf: url))
  }

  public static func issues(in project: ComposeProject) -> [CompatibilityIssue] {
    let issues = issues(in: project.model)
    guard project.allowMissingServiceDNS else { return issues }
    return issues.filter { $0.service != nil || $0.field != "serviceNameDNS" }
  }

  public static func warnings(in project: ComposeProject) -> [String] {
    guard project.allowMissingServiceDNS, project.serviceNames.count > 1 else { return [] }
    return [
      "Apple Container does not provide Compose-style bare service-name discovery on project networks; proceeding because x-apple-container.allow-missing-service-dns is true"
    ]
  }

  public static func issues(in model: JSONValue) -> [CompatibilityIssue] {
    var issues: [CompatibilityIssue] = []
    guard let services = model["services"]?.objectValue else { return issues }
    let supportedServiceFields: Set<String> = [
      "image", "build", "environment", "ports", "volumes", "networks", "command",
      "entrypoint", "mem_limit", "cpus", "platform", "labels", "user", "working_dir",
      "init", "read_only", "cap_add", "cap_drop", "dns", "dns_search", "dns_opt",
      "shm_size", "ulimits", "stdin_open", "tty", "container_name", "depends_on",
      "profiles", "restart", "deploy", "healthcheck", "privileged", "network_mode",
      "devices", "ipc", "pid", "gpus", "security_opt", "sysctls", "configs", "secrets",
    ]
    var volumeUsers: [String: [String]] = [:]

    if model["configs"] != nil {
      issues.append(
        .init(
          service: nil, field: "configs", state: .planned,
          reason: "config materialization is not implemented"))
    }
    if model["secrets"] != nil {
      issues.append(
        .init(
          service: nil, field: "secrets", state: .planned,
          reason: "secret materialization is not implemented"))
    }
    if services.count > 1 {
      issues.append(
        .init(
          service: nil, field: "serviceNameDNS", state: .rejected,
          reason:
            "Apple Container does not provide Compose-style bare service-name discovery on project networks"
        ))
    }

    for (name, value) in services.sorted(by: { $0.key < $1.key }) {
      guard let service = value.objectValue else { continue }
      for field in service.keys.sorted() where !supportedServiceFields.contains(field) {
        issues.append(
          .init(
            service: name, field: field, state: .planned,
            reason: "this field has no verified Apple Container translation"))
      }
      if let restart = service["restart"]?.stringValue,
        !restart.isEmpty, restart != "no"
      {
        issues.append(
          .init(
            service: name, field: "restart", state: .rejected,
            reason: "Apple Container has no persistent restart-policy controller"))
      }
      if service["privileged"] == .bool(true) {
        issues.append(
          .init(
            service: name, field: "privileged", state: .rejected,
            reason: "Apple Container exposes no equivalent privileged mode"))
      }
      if service["network_mode"] != nil {
        issues.append(
          .init(
            service: name, field: "network_mode", state: .rejected,
            reason: "host and shared network namespaces cannot be preserved"))
      }
      if let cpus = service["cpus"],
        !(cpus.integerValue.map { $0 > 0 } ?? false)
      {
        issues.append(
          .init(
            service: name, field: "cpus", state: .rejected,
            reason: "Apple Container accepts a positive whole vCPU count, not a fractional quota"))
      }
      if service["devices"]?.arrayValue?.isEmpty == false {
        issues.append(
          .init(
            service: name, field: "devices", state: .rejected,
            reason: "device mappings are not exposed by the Apple Container CLI"))
      }
      if let replicas = service["deploy"]?["replicas"], replicas != .integer(1) {
        issues.append(
          .init(
            service: name, field: "deploy.replicas", state: .rejected,
            reason: "v1 supports one container per service"))
      }
      for field in service["deploy"]?.objectValue?.keys.sorted() ?? [] where field != "replicas" {
        issues.append(
          .init(
            service: name, field: "deploy.\(field)", state: .planned,
            reason: "deploy orchestration settings are not implemented"))
      }
      if service["healthcheck"] != nil {
        issues.append(
          .init(
            service: name, field: "healthcheck", state: .planned,
            reason: "Apple Container does not expose ongoing Compose health state"))
      }
      for field in ["command", "entrypoint"]
      where service[field]?.stringValue != nil {
        issues.append(
          .init(
            service: name, field: field, state: .rejected,
            reason: "string-form command-line splitting is not implemented; use list syntax"))
      }
      for field in ["command", "entrypoint"] {
        if let values = service[field]?.arrayValue,
          values.contains(where: { $0.stringValue == nil })
        {
          issues.append(
            .init(
              service: name, field: field, state: .rejected,
              reason: "list form must contain only strings"))
        }
      }
      for (index, port) in (service["ports"]?.arrayValue ?? []).enumerated() {
        if port["published"]?.stringValue == nil {
          issues.append(
            .init(
              service: name, field: "ports[\(index)].published", state: .rejected,
              reason: "Apple Container cannot preserve automatic host-port allocation"))
        }
        if port["mode"]?.stringValue != "ingress" {
          issues.append(
            .init(
              service: name, field: "ports[\(index)].mode", state: .rejected,
              reason: "only ingress port publishing maps to Apple Container"))
        }
        let supportedPortFields: Set<String> = [
          "target", "published", "protocol", "host_ip", "mode",
        ]
        for field in port.objectValue?.keys.sorted() ?? []
        where !supportedPortFields.contains(field) {
          issues.append(
            .init(
              service: name, field: "ports[\(index)].\(field)", state: .planned,
              reason: "this port option has no verified CLI translation"))
        }
      }
      for (dependency, declaration) in service["depends_on"]?.objectValue ?? [:] {
        let condition = declaration["condition"]?.stringValue ?? "service_started"
        if condition != "service_started" {
          issues.append(
            .init(
              service: name, field: "depends_on.\(dependency).condition", state: .planned,
              reason: "only service_started ordering is implemented"))
        }
      }
      for (network, attachment) in service["networks"]?.objectValue ?? [:]
      where attachment["aliases"] != nil {
        issues.append(
          .init(
            service: name, field: "networks.\(network).aliases", state: .rejected,
            reason: "Apple Container has no network-alias option"))
      }
      for (network, attachment) in service["networks"]?.objectValue ?? [:] {
        for field in attachment.objectValue?.keys.sorted() ?? [] where field != "aliases" {
          issues.append(
            .init(
              service: name, field: "networks.\(network).\(field)", state: .planned,
              reason: "this network attachment option has no verified CLI translation"))
        }
      }
      for volume in service["volumes"]?.arrayValue ?? [] {
        if volume["type"] == .string("volume"), let source = volume["source"]?.stringValue {
          volumeUsers[source, default: []].append(name)
        } else if volume["type"] == .string("volume"), volume["source"] == nil {
          issues.append(
            .init(
              service: name, field: "volumes", state: .rejected,
              reason: "anonymous volumes cannot yet be preserved across recreate"))
        }
        for optionsField in ["bind", "volume"] {
          if let options = volume[optionsField]?.objectValue, !options.isEmpty {
            issues.append(
              .init(
                service: name, field: "volumes.\(optionsField)", state: .planned,
                reason: "advanced mount options are not translated"))
          }
        }
      }
      if let build = service["build"]?.objectValue {
        let supportedBuildFields: Set<String> = [
          "context", "dockerfile", "args", "target", "no_cache",
        ]
        for field in build.keys.sorted() where !supportedBuildFields.contains(field) {
          issues.append(
            .init(
              service: name, field: "build.\(field)", state: .planned,
              reason: "this build option has no verified Apple Container translation"))
        }
        for (key, value) in build["args"]?.objectValue ?? [:] where value == .null {
          issues.append(
            .init(
              service: name, field: "build.args.\(key)", state: .rejected,
              reason: "host-inherited build arguments cannot be preserved"))
        }
      }
      for field in ["ipc", "pid", "gpus", "security_opt", "sysctls"]
      where service[field] != nil {
        issues.append(
          .init(
            service: name, field: field, state: .rejected,
            reason: "the Apple Container CLI cannot preserve this Compose semantic"))
      }
      for field in ["configs", "secrets"] where service[field] != nil {
        issues.append(
          .init(
            service: name, field: field, state: .planned,
            reason: "materialization is not implemented"))
      }
    }
    for (volume, users) in volumeUsers where users.count > 1 {
      issues.append(
        .init(
          service: nil, field: "volumes.\(volume)", state: .rejected,
          reason:
            "named volume is shared by services \(users.sorted().joined(separator: ", ")) but Apple Container cannot safely attach it to multiple service VMs"
        ))
    }
    return issues
  }

  public static func validateForExecution(_ project: ComposeProject) throws {
    let issues = issues(in: project)
    guard issues.isEmpty else {
      throw ComposeError(
        "project uses unsupported Compose semantics:\n"
          + issues.map { "- \($0.description)" }.joined(separator: "\n"))
    }
  }
}
