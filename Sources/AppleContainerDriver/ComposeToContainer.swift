import ComposeCore
import Foundation

public enum ComposeToContainer {
  public static func imageReference(
    project: ComposeProject,
    serviceName: String,
    service: JSONValue
  ) throws -> String {
    if let image = service["image"]?.stringValue, !image.isEmpty { return image }
    guard service["build"] != nil else {
      throw ComposeError("service '\(serviceName)' must define image or build")
    }
    return "\(project.name)-\(serviceName):latest"
  }

  public static func buildArguments(
    project: ComposeProject,
    serviceName: String,
    progress: String = "auto",
    pull: Bool = false
  ) throws -> [String]? {
    guard let service = project.model["services"]?[serviceName],
      let build = service["build"]?.objectValue
    else {
      return nil
    }
    guard let context = build["context"]?.stringValue else {
      throw ComposeError("service '\(serviceName)' has no normalized build context")
    }

    var arguments = ["build"]
    let dockerfile = build["dockerfile"]?.stringValue ?? "Dockerfile"
    let dockerfilePath =
      dockerfile.hasPrefix("/")
      ? dockerfile
      : URL(
        fileURLWithPath: dockerfile, relativeTo: URL(fileURLWithPath: context, isDirectory: true)
      )
      .standardizedFileURL.path
    arguments += ["--file", dockerfilePath]
    arguments += [
      "--tag",
      try imageReference(
        project: project, serviceName: serviceName, service: service),
    ]
    if let platform = service["platform"]?.stringValue {
      arguments += ["--platform", platform]
    }
    if let target = build["target"]?.stringValue { arguments += ["--target", target] }
    if build["no_cache"] == .bool(true) { arguments.append("--no-cache") }
    if pull { arguments.append("--pull") }
    if progress == "quiet" {
      arguments.append("--quiet")
    } else {
      let nativeProgress = progress == "tty" ? "tty" : progress == "plain" ? "plain" : "auto"
      arguments += ["--progress", nativeProgress]
    }
    for (key, value) in build["args"]?.objectValue?.sorted(by: { $0.key < $1.key }) ?? [] {
      if case .null = value {
        throw ComposeError(
          "service '\(serviceName)' build arg '\(key)' requires host inheritance, which Apple Container build cannot preserve"
        )
      }
      arguments += ["--build-arg", "\(key)=\(scalar(value))"]
    }
    arguments.append(context)
    return arguments
  }

  public static func createArguments(
    project: ComposeProject,
    serviceName: String,
    labels ownershipLabels: [String: String]
  ) throws -> [String] {
    guard let service = project.model["services"]?[serviceName] else {
      throw ComposeError("service '\(serviceName)' is not defined")
    }
    let image = try imageReference(project: project, serviceName: serviceName, service: service)
    let name = service["container_name"]?.stringValue ?? "\(project.name)-\(serviceName)-1"
    guard name.utf8.count <= 63 else {
      throw ComposeError("container name '\(name)' exceeds Apple Container's 63-byte limit")
    }

    var arguments = ["create", "--name", name]
    for (key, value) in service["environment"]?.objectValue?.sorted(by: { $0.key < $1.key }) ?? [] {
      guard case .null = value else {
        arguments += ["--env", "\(key)=\(scalar(value))"]
        continue
      }
    }

    var labels = ownershipLabels
    for (key, value) in service["labels"]?.objectValue ?? [:] {
      labels[key] = scalar(value)
    }
    for (key, value) in labels.sorted(by: { $0.key < $1.key }) {
      arguments += ["--label", "\(key)=\(value)"]
    }

    for port in service["ports"]?.arrayValue ?? [] {
      guard let published = port["published"]?.stringValue,
        let target = port["target"]?.integerValue
      else {
        throw ComposeError(
          "service '\(serviceName)' has a port that cannot be translated to Apple Container")
      }
      let host =
        port["host_ip"]?.stringValue.map {
          $0.contains(":") ? "[\($0)]:" : "\($0):"
        } ?? ""
      let protocolName = port["protocol"]?.stringValue ?? "tcp"
      arguments += ["--publish", "\(host)\(published):\(target)/\(protocolName)"]
    }

    for (network, _) in service["networks"]?.objectValue?.sorted(by: { $0.key < $1.key }) ?? [] {
      guard let resourceName = project.model["networks"]?[network]?["name"]?.stringValue else {
        throw ComposeError("service '\(serviceName)' references undefined network '\(network)'")
      }
      arguments += ["--network", resourceName]
    }

    for volume in service["volumes"]?.arrayValue ?? [] {
      guard let type = volume["type"]?.stringValue,
        let target = volume["target"]?.stringValue
      else {
        throw ComposeError("service '\(serviceName)' has an invalid normalized volume")
      }
      let readOnly = volume["read_only"] == .bool(true) ? ",readonly" : ""
      switch type {
      case "bind":
        guard let source = volume["source"]?.stringValue else {
          throw ComposeError("service '\(serviceName)' bind mount is missing a source")
        }
        arguments += ["--mount", "type=bind,source=\(source),target=\(target)\(readOnly)"]
      case "volume":
        let source: String?
        if let logicalName = volume["source"]?.stringValue {
          source = project.model["volumes"]?[logicalName]?["name"]?.stringValue
          guard source != nil else {
            throw ComposeError(
              "service '\(serviceName)' references undefined volume '\(logicalName)'")
          }
        } else {
          source = nil
        }
        arguments += [
          "--mount",
          "type=volume" + (source.map { ",source=\($0)" } ?? "")
            + ",target=\(target)\(readOnly)",
        ]
      case "tmpfs":
        arguments += ["--tmpfs", target]
      default:
        throw ComposeError("service '\(serviceName)' uses unsupported volume type '\(type)'")
      }
    }

    appendScalarOption("--cpus", value: service["cpus"], to: &arguments)
    appendScalarOption("--memory", value: service["mem_limit"], to: &arguments)
    appendScalarOption("--platform", value: service["platform"], to: &arguments)
    appendScalarOption("--user", value: service["user"], to: &arguments)
    appendScalarOption("--workdir", value: service["working_dir"], to: &arguments)
    appendScalarOption("--shm-size", value: service["shm_size"], to: &arguments)
    if service["platform"]?.stringValue?.contains("/amd64") == true {
      arguments.append("--rosetta")
    }
    if service["init"] == .bool(true) { arguments.append("--init") }
    if service["read_only"] == .bool(true) { arguments.append("--read-only") }
    if service["stdin_open"] == .bool(true) { arguments.append("--interactive") }
    if service["tty"] == .bool(true) { arguments.append("--tty") }
    appendRepeated("--cap-add", value: service["cap_add"], to: &arguments)
    appendRepeated("--cap-drop", value: service["cap_drop"], to: &arguments)
    appendRepeated("--dns", value: service["dns"], to: &arguments)
    appendRepeated("--dns-search", value: service["dns_search"], to: &arguments)
    appendRepeated("--dns-option", value: service["dns_opt"], to: &arguments)
    appendUlimits(service["ulimits"], to: &arguments)

    var command = try commandArguments(service["command"], serviceName: serviceName)
    switch service["entrypoint"] {
    case .string:
      throw ComposeError(
        "service '\(serviceName)' uses string-form entrypoint; use list syntax for v1")
    case .array(let values):
      let entrypoint = values.compactMap(\.stringValue)
      guard entrypoint.count == values.count, let executable = entrypoint.first else {
        throw ComposeError("service '\(serviceName)' has an invalid entrypoint")
      }
      arguments += ["--entrypoint", executable]
      command = Array(entrypoint.dropFirst()) + command
    case .null, nil:
      break
    default:
      throw ComposeError("service '\(serviceName)' has an invalid entrypoint")
    }
    arguments.append(image)
    arguments += command
    return arguments
  }

  public static func networkCreateArguments(
    logicalName: String,
    network: JSONValue,
    projectName: String
  ) throws -> [String] {
    guard let name = network["name"]?.stringValue else {
      throw ComposeError("network '\(logicalName)' has no normalized name")
    }
    var arguments = ["network", "create"]
    if network["internal"] == .bool(true) { arguments.append("--internal") }
    let labels = [
      ComposeLabels.project: projectName,
      ComposeLabels.network: logicalName,
      ComposeLabels.schemaVersion: "1",
    ]
    for (key, value) in labels.sorted(by: { $0.key < $1.key }) {
      arguments += ["--label", "\(key)=\(value)"]
    }
    if let subnet = network["ipam"]?["config"]?.arrayValue?.first?["subnet"]?.stringValue {
      arguments += [subnet.contains(":") ? "--subnet-v6" : "--subnet", subnet]
    }
    arguments.append(name)
    return arguments
  }

  public static func volumeCreateArguments(
    logicalName: String,
    volume: JSONValue,
    projectName: String
  ) throws -> [String] {
    guard let name = volume["name"]?.stringValue else {
      throw ComposeError("volume '\(logicalName)' has no normalized name")
    }
    var arguments = ["volume", "create"]
    let labels = [
      ComposeLabels.project: projectName,
      ComposeLabels.volume: logicalName,
      ComposeLabels.schemaVersion: "1",
    ]
    for (key, value) in labels.sorted(by: { $0.key < $1.key }) {
      arguments += ["--label", "\(key)=\(value)"]
    }
    for (key, value) in volume["driver_opts"]?.objectValue?.sorted(by: { $0.key < $1.key }) ?? [] {
      arguments += ["--opt", "\(key)=\(scalar(value))"]
    }
    arguments.append(name)
    return arguments
  }

  private static func commandArguments(_ value: JSONValue?, serviceName: String) throws -> [String]
  {
    switch value {
    case .string:
      throw ComposeError(
        "service '\(serviceName)' uses string-form command; use list syntax for v1")
    case .array(let values):
      let command = values.compactMap(\.stringValue)
      guard command.count == values.count else {
        throw ComposeError("service '\(serviceName)' command list must contain only strings")
      }
      return command
    default: return []
    }
  }

  private static func appendScalarOption(
    _ flag: String,
    value: JSONValue?,
    to arguments: inout [String]
  ) {
    guard let value, value != .null else { return }
    arguments += [flag, scalar(value)]
  }

  private static func appendRepeated(
    _ flag: String,
    value: JSONValue?,
    to arguments: inout [String]
  ) {
    switch value {
    case .array(let values):
      for value in values { arguments += [flag, scalar(value)] }
    case .string:
      arguments += [flag, scalar(value!)]
    default:
      break
    }
  }

  private static func appendUlimits(_ value: JSONValue?, to arguments: inout [String]) {
    for (name, limit) in value?.objectValue?.sorted(by: { $0.key < $1.key }) ?? [] {
      if let object = limit.objectValue,
        let soft = object["soft"], let hard = object["hard"]
      {
        arguments += ["--ulimit", "\(name)=\(scalar(soft)):\(scalar(hard))"]
      } else {
        arguments += ["--ulimit", "\(name)=\(scalar(limit))"]
      }
    }
  }

  private static func scalar(_ value: JSONValue) -> String {
    switch value {
    case .string(let value): return value
    case .integer(let value): return String(value)
    case .number(let value): return String(value)
    case .bool(let value): return String(value)
    case .null: return ""
    case .array, .object: return String(describing: value)
    }
  }
}
