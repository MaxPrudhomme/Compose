import Foundation
import Yams

public struct ComposeLoader {
  public init() {}

  public func load(options: ComposeLoadOptions = .init()) throws -> ComposeProject {
    let currentDirectory = URL(fileURLWithPath: options.currentDirectory, isDirectory: true)
      .standardizedFileURL
    let implicitEnvironmentFile = currentDirectory.appendingPathComponent(".env")

    var discoveryEnvironment: [String: String] = [:]
    if FileManager.default.fileExists(atPath: implicitEnvironmentFile.path) {
      discoveryEnvironment = try EnvironmentFile.load(url: implicitEnvironmentFile)
    }
    discoveryEnvironment.merge(options.environment) { _, processValue in processValue }

    let files = try ComposeFileDiscovery.discover(
      options: options, environment: discoveryEnvironment)
    let workingDirectory: URL
    if let explicitDirectory = options.projectDirectory {
      workingDirectory = URL(fileURLWithPath: explicitDirectory, relativeTo: currentDirectory)
        .standardizedFileURL
        .resolvingSymlinksInPath()
    } else {
      workingDirectory = files[0].deletingLastPathComponent()
    }

    var interpolationEnvironment: [String: String] = [:]
    if options.environmentFiles.isEmpty {
      let projectEnvironmentFile = workingDirectory.appendingPathComponent(".env")
      if FileManager.default.fileExists(atPath: projectEnvironmentFile.path) {
        interpolationEnvironment = try EnvironmentFile.load(url: projectEnvironmentFile)
      }
    } else {
      for path in options.environmentFiles {
        let url = URL(fileURLWithPath: path, relativeTo: currentDirectory).standardizedFileURL
        interpolationEnvironment = try EnvironmentFile.load(
          url: url, base: interpolationEnvironment)
      }
    }
    interpolationEnvironment.merge(options.environment) { _, processValue in processValue }

    var merged: JSONValue = .object([:])
    var sourceLocations: [[String]: SourceLocation] = [:]
    for file in files {
      let parsed = try parse(file: file, environment: interpolationEnvironment)
      merged = merge(base: merged, override: parsed.value, path: [], directives: parsed.directives)
      sourceLocations.merge(parsed.locations) { _, newer in newer }
    }

    let projectName = try resolveProjectName(
      explicit: options.projectName,
      environment: interpolationEnvironment,
      model: merged,
      workingDirectory: workingDirectory
    )
    let normalized = try normalize(
      merged,
      projectName: projectName,
      workingDirectory: workingDirectory,
      profiles: options.profiles,
      sourceLocations: sourceLocations
    )

    return ComposeProject(
      name: projectName,
      workingDirectory: workingDirectory,
      files: files,
      model: normalized.model,
      interpolationEnvironment: interpolationEnvironment,
      declaredProfiles: normalized.profiles
    )
  }
}

extension ComposeLoader {
  fileprivate enum MergeDirective {
    case reset
    case override
  }

  fileprivate struct ParsedFile {
    let value: JSONValue
    let directives: [[String]: MergeDirective]
    let locations: [[String]: SourceLocation]
  }

  fileprivate struct NormalizedProject {
    let model: JSONValue
    let profiles: [String]
  }

  fileprivate func parse(file: URL, environment: [String: String]) throws -> ParsedFile {
    let yaml: String
    do {
      yaml = try String(contentsOf: file, encoding: .utf8)
    } catch {
      throw ComposeError("could not read Compose file as UTF-8: \(file.path)")
    }

    let root: Node
    do {
      guard let parsed = try compose(yaml: yaml) else {
        throw ComposeError("Compose file is empty")
      }
      root = try interpolate(node: parsed, environment: environment, file: file)
    } catch let error as ComposeError {
      throw error
    } catch {
      throw ComposeError("invalid YAML: \(error)")
    }

    guard case .mapping = root else {
      throw ComposeError(
        "top-level Compose value must be a mapping", location: location(for: root, file: file))
    }

    var directives: [[String]: MergeDirective] = [:]
    var locations: [[String]: SourceLocation] = [:]
    collectMetadata(
      node: root, path: [], file: file, directives: &directives, locations: &locations)
    return ParsedFile(
      value: try JSONValue(any: root.any), directives: directives, locations: locations)
  }

  fileprivate func interpolate(node: Node, environment: [String: String], file: URL) throws -> Node
  {
    switch node {
    case .scalar(var scalar):
      guard scalar.string.contains("$") else { return node }
      let tag = scalar.tag
      scalar.string = try Interpolator(environment: environment).interpolate(
        scalar.string,
        location: location(for: node, file: file)
      )
      scalar.tag = tag
      return .scalar(scalar)
    case .sequence(let sequence):
      let children = try sequence.map {
        try interpolate(node: $0, environment: environment, file: file)
      }
      return Node(children, sequence.tag, sequence.style, sequence.anchor)
    case .mapping(let mapping):
      let pairs = try mapping.map { pair in
        (pair.key, try interpolate(node: pair.value, environment: environment, file: file))
      }
      return Node(pairs, mapping.tag, mapping.style, mapping.anchor)
    case .alias:
      return node
    }
  }

  fileprivate func collectMetadata(
    node: Node,
    path: [String],
    file: URL,
    directives: inout [[String]: MergeDirective],
    locations: inout [[String]: SourceLocation]
  ) {
    if let location = location(for: node, file: file) {
      locations[path] = location
    }
    switch node.tag.rawValue {
    case "!reset": directives[path] = .reset
    case "!override": directives[path] = .override
    default: break
    }

    switch node {
    case .mapping(let mapping):
      for pair in mapping {
        guard let key = pair.key.string else { continue }
        collectMetadata(
          node: pair.value,
          path: path + [key],
          file: file,
          directives: &directives,
          locations: &locations
        )
      }
    case .sequence(let sequence):
      for (index, child) in sequence.enumerated() {
        collectMetadata(
          node: child,
          path: path + ["[\(index)]"],
          file: file,
          directives: &directives,
          locations: &locations
        )
      }
    case .scalar, .alias:
      break
    }
  }

  fileprivate func location(for node: Node, file: URL) -> SourceLocation? {
    node.mark.map { SourceLocation(file: file.path, line: $0.line, column: $0.column) }
  }

  fileprivate func merge(
    base: JSONValue,
    override: JSONValue,
    path: [String],
    directives: [[String]: MergeDirective]
  ) -> JSONValue {
    if directives[path] != nil {
      return override
    }

    switch (base, override) {
    case (.object(let baseObject), .object(let overrideObject)):
      var result = baseObject
      for (key, value) in overrideObject {
        if let existing = result[key] {
          result[key] = merge(
            base: existing, override: value, path: path + [key], directives: directives)
        } else {
          result[key] = value
        }
      }
      return .object(result)
    case (.array(let baseArray), .array(let overrideArray)):
      if replacesSequence(at: path) {
        return override
      }
      if let kind = uniqueResourceKind(at: path) {
        return .array(mergeUnique(base: baseArray, override: overrideArray, kind: kind))
      }
      return .array(baseArray + overrideArray)
    default:
      return override
    }
  }

  fileprivate func replacesSequence(at path: [String]) -> Bool {
    path.suffix(1) == ["command"] || path.suffix(1) == ["entrypoint"]
      || path.suffix(2) == ["healthcheck", "test"]
  }

  fileprivate func uniqueResourceKind(at path: [String]) -> String? {
    guard let last = path.last, ["ports", "volumes", "secrets", "configs"].contains(last) else {
      return nil
    }
    return last
  }

  fileprivate func mergeUnique(base: [JSONValue], override: [JSONValue], kind: String)
    -> [JSONValue]
  {
    var result = base
    var indices: [String: Int] = [:]
    for (index, value) in result.enumerated() {
      indices[uniqueKey(for: value, kind: kind)] = index
    }
    for value in override {
      let key = uniqueKey(for: value, kind: kind)
      if let index = indices[key] {
        result[index] = value
      } else {
        indices[key] = result.count
        result.append(value)
      }
    }
    return result
  }

  fileprivate func uniqueKey(for value: JSONValue, kind: String) -> String {
    if case .object(let object) = value {
      switch kind {
      case "ports":
        return ["ip", "target", "published", "protocol"].map {
          object[$0].map(String.init(describing:)) ?? ""
        }.joined(separator: "|")
      case "volumes", "secrets", "configs":
        return object["target"].map(String.init(describing:)) ?? String(describing: value)
      default:
        break
      }
    }
    if case .string(let string) = value, kind == "volumes" {
      return string.split(separator: ":").dropFirst().first.map(String.init) ?? string
    }
    return String(describing: value)
  }
}

extension ComposeLoader {
  fileprivate func resolveProjectName(
    explicit: String?,
    environment: [String: String],
    model: JSONValue,
    workingDirectory: URL
  ) throws -> String {
    let candidate =
      explicit ?? environment["COMPOSE_PROJECT_NAME"] ?? model["name"]?.stringValue
      ?? workingDirectory.lastPathComponent
    let normalized = candidate.lowercased()
      .map { character in
        character.isLetter || character.isNumber || character == "_" || character == "-"
          ? character : "-"
      }
      .drop { !$0.isLetter && !$0.isNumber }
    let value = String(normalized)
    guard !value.isEmpty else {
      throw ComposeError(
        "project name cannot be normalized to a valid Apple Container resource prefix")
    }
    return value
  }

  fileprivate func normalize(
    _ value: JSONValue,
    projectName: String,
    workingDirectory: URL,
    profiles enabledProfiles: Set<String>,
    sourceLocations: [[String]: SourceLocation]
  ) throws -> NormalizedProject {
    guard case .object(var root) = value else {
      throw ComposeError("top-level Compose value must be a mapping")
    }
    if root["include"] != nil {
      throw ComposeError(
        "top-level 'include' is parsed but not supported yet",
        location: sourceLocations[["include"]])
    }
    root.removeValue(forKey: "version")
    root = removeExtensions(from: root)

    guard case .object(let rawServices)? = root["services"], !rawServices.isEmpty else {
      throw ComposeError(
        "Compose project must define at least one service", location: sourceLocations[["services"]])
    }
    let extendedServices = try resolveExtends(rawServices, locations: sourceLocations)

    var declaredProfiles = Set<String>()
    var services: [String: JSONValue] = [:]
    for (name, rawService) in extendedServices {
      guard case .object(var service) = rawService else {
        throw ComposeError(
          "service '\(name)' must be a mapping", location: sourceLocations[["services", name]])
      }
      let profiles = try profileNames(
        from: service["profiles"], service: name,
        location: sourceLocations[["services", name, "profiles"]])
      declaredProfiles.formUnion(profiles)
      if !profiles.isEmpty, enabledProfiles.isDisjoint(with: profiles) {
        continue
      }
      service = removeExtensions(from: service)
      services[name] = try normalizeService(service, name: name, projectDirectory: workingDirectory)
    }
    root["name"] = .string(projectName)
    root["services"] = .object(services)
    root["networks"] = normalizeNetworks(
      root["networks"], projectName: projectName,
      needsDefault: services.values.contains { $0["networks"]?["default"] != nil })
    if let volumes = root["volumes"] {
      root["volumes"] = normalizeNamedResources(volumes, projectName: projectName)
    }
    return NormalizedProject(model: .object(root), profiles: declaredProfiles.sorted())
  }

  fileprivate func resolveExtends(
    _ services: [String: JSONValue], locations: [[String]: SourceLocation]
  ) throws -> [String: JSONValue] {
    var resolved: [String: JSONValue] = [:]
    var active = Set<String>()

    func resolve(_ name: String) throws -> JSONValue {
      if let cached = resolved[name] { return cached }
      guard let raw = services[name], case .object(var service) = raw else {
        throw ComposeError("extended service '\(name)' does not exist")
      }
      guard active.insert(name).inserted else {
        throw ComposeError("cycle detected while resolving extends for service '\(name)'")
      }
      defer { active.remove(name) }

      if let extends = service.removeValue(forKey: "extends") {
        guard case .object(let specification) = extends,
          let parent = specification["service"]?.stringValue
        else {
          throw ComposeError(
            "service '\(name)' has an invalid extends declaration",
            location: locations[["services", name, "extends"]])
        }
        if specification["file"] != nil {
          throw ComposeError(
            "cross-file extends is parsed but not supported yet",
            location: locations[["services", name, "extends"]])
        }
        let parentService = try resolve(parent)
        service = merge(
          base: parentService, override: .object(service), path: ["services", name], directives: [:]
        ).objectValue!
      }
      let result = JSONValue.object(service)
      resolved[name] = result
      return result
    }

    for name in services.keys {
      _ = try resolve(name)
    }
    return resolved
  }

  fileprivate func profileNames(from value: JSONValue?, service: String, location: SourceLocation?)
    throws -> Set<String>
  {
    guard let value else { return [] }
    switch value {
    case .array(let values):
      let strings = values.compactMap(\.stringValue)
      guard strings.count == values.count else {
        throw ComposeError(
          "profiles for service '\(service)' must contain only strings", location: location)
      }
      return Set(strings)
    case .string(let value):
      return [value]
    default:
      throw ComposeError(
        "profiles for service '\(service)' must be a string or list", location: location)
    }
  }

  fileprivate func normalizeService(
    _ input: [String: JSONValue], name: String, projectDirectory: URL
  ) throws -> JSONValue {
    var service = input
    service["environment"] = try normalizeEnvironment(
      envFile: service.removeValue(forKey: "env_file"),
      environment: service["environment"],
      projectDirectory: projectDirectory
    )

    if let build = service["build"] {
      service["build"] = try normalizeBuild(build, projectDirectory: projectDirectory)
    }
    if let ports = service["ports"] {
      service["ports"] = try normalizePorts(ports, service: name)
    }
    if let memory = service["mem_limit"]?.stringValue {
      service["mem_limit"] = .string(try normalizeByteSize(memory))
    }
    if service["networks"] == nil {
      service["networks"] = .object(["default": .null])
    } else {
      service["networks"] = try normalizeServiceNetworks(service["networks"]!, service: name)
    }
    if service["command"] == nil { service["command"] = .null }
    if service["entrypoint"] == nil { service["entrypoint"] = .null }
    return .object(service)
  }

  fileprivate func normalizeEnvironment(
    envFile: JSONValue?, environment: JSONValue?, projectDirectory: URL
  ) throws -> JSONValue {
    var result: [String: String] = [:]
    if let envFile {
      let paths: [String]
      switch envFile {
      case .string(let path): paths = [path]
      case .array(let values):
        paths = try values.map {
          guard let value = $0.stringValue else {
            throw ComposeError("env_file entries must be strings")
          }
          return value
        }
      default:
        throw ComposeError("env_file must be a string or list of strings")
      }
      for path in paths {
        let url = URL(fileURLWithPath: path, relativeTo: projectDirectory).standardizedFileURL
        result = try EnvironmentFile.load(url: url, base: result)
      }
    }

    if let environment {
      switch environment {
      case .object(let values):
        for (key, value) in values {
          if case .null = value {
            result[key] = ProcessInfo.processInfo.environment[key] ?? ""
          } else {
            result[key] = scalarString(value)
          }
        }
      case .array(let values):
        for value in values {
          guard let entry = value.stringValue else {
            throw ComposeError("environment list entries must be strings")
          }
          let pair = entry.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
          let key = String(pair[0])
          result[key] =
            pair.count == 2 ? String(pair[1]) : ProcessInfo.processInfo.environment[key] ?? ""
        }
      default:
        throw ComposeError("environment must be a mapping or list")
      }
    }
    return .object(result.mapValues(JSONValue.string))
  }

  fileprivate func scalarString(_ value: JSONValue) -> String {
    switch value {
    case .string(let value): return value
    case .integer(let value): return String(value)
    case .number(let value): return String(value)
    case .bool(let value): return value ? "true" : "false"
    case .null: return ""
    case .array, .object: return String(describing: value)
    }
  }

  fileprivate func normalizeBuild(_ value: JSONValue, projectDirectory: URL) throws -> JSONValue {
    var build: [String: JSONValue]
    switch value {
    case .string(let context):
      build = ["context": .string(context)]
    case .object(let object):
      build = object
    default:
      throw ComposeError("build must be a path or mapping")
    }
    let context = build["context"]?.stringValue ?? "."
    build["context"] = .string(
      URL(fileURLWithPath: context, relativeTo: projectDirectory).standardizedFileURL.path)
    if build["dockerfile"] == nil { build["dockerfile"] = .string("Dockerfile") }
    return .object(build)
  }

  fileprivate func normalizePorts(_ value: JSONValue, service: String) throws -> JSONValue {
    guard case .array(let ports) = value else {
      throw ComposeError("ports for service '\(service)' must be a list")
    }
    return .array(
      try ports.map { port in
        guard case .string(let short) = port else { return port }
        let protocolParts = short.split(
          separator: "/", maxSplits: 1, omittingEmptySubsequences: false)
        let protocolName = protocolParts.count == 2 ? String(protocolParts[1]) : "tcp"
        let address = String(protocolParts[0])
        let parts = address.split(separator: ":", omittingEmptySubsequences: false)
        guard let targetText = parts.last, let target = Int64(targetText) else {
          throw ComposeError("invalid published port '\(short)' for service '\(service)'")
        }
        var object: [String: JSONValue] = [
          "mode": .string("ingress"),
          "target": .integer(target),
          "protocol": .string(protocolName),
        ]
        if parts.count >= 2 { object["published"] = .string(String(parts[parts.count - 2])) }
        if parts.count >= 3 {
          object["host_ip"] = .string(parts.dropLast(2).joined(separator: ":"))
        }
        return .object(object)
      })
  }

  fileprivate func normalizeByteSize(_ value: String) throws -> String {
    let lower = value.lowercased()
    let units: [(String, Int64)] = [
      ("kib", 1_024), ("mib", 1_048_576), ("gib", 1_073_741_824),
      ("kb", 1_000), ("mb", 1_000_000), ("gb", 1_000_000_000),
      ("k", 1_024), ("m", 1_048_576), ("g", 1_073_741_824), ("b", 1),
    ]
    for (suffix, multiplier) in units where lower.hasSuffix(suffix) {
      let number = lower.dropLast(suffix.count)
      guard let amount = Double(number) else { break }
      return String(Int64(amount * Double(multiplier)))
    }
    guard let amount = Int64(lower) else {
      throw ComposeError("invalid byte size '\(value)'")
    }
    return String(amount)
  }

  fileprivate func normalizeServiceNetworks(_ value: JSONValue, service: String) throws -> JSONValue
  {
    switch value {
    case .array(let networks):
      var object: [String: JSONValue] = [:]
      for network in networks {
        guard let name = network.stringValue else {
          throw ComposeError("networks for service '\(service)' must contain strings")
        }
        object[name] = .null
      }
      return .object(object)
    case .object:
      return value
    default:
      throw ComposeError("networks for service '\(service)' must be a mapping or list")
    }
  }

  fileprivate func normalizeNetworks(_ value: JSONValue?, projectName: String, needsDefault: Bool)
    -> JSONValue
  {
    var networks = value?.objectValue ?? [:]
    if needsDefault, networks["default"] == nil { networks["default"] = .object([:]) }
    for (key, value) in networks {
      var network = value.objectValue ?? [:]
      let isExternal = network["external"] == .bool(true)
      if !isExternal, network["name"] == nil { network["name"] = .string("\(projectName)_\(key)") }
      if network["ipam"] == nil { network["ipam"] = .object([:]) }
      networks[key] = .object(network)
    }
    return .object(networks)
  }

  fileprivate func normalizeNamedResources(_ value: JSONValue, projectName: String) -> JSONValue {
    guard case .object(var resources) = value else { return value }
    for (key, value) in resources {
      var resource = value.objectValue ?? [:]
      if resource["external"] != .bool(true), resource["name"] == nil {
        resource["name"] = .string("\(projectName)_\(key)")
      }
      resources[key] = .object(resource)
    }
    return .object(resources)
  }

  fileprivate func removeExtensions(from object: [String: JSONValue]) -> [String: JSONValue] {
    object.filter { !$0.key.hasPrefix("x-") }.mapValues(removeNestedExtensions)
  }

  fileprivate func removeNestedExtensions(_ value: JSONValue) -> JSONValue {
    switch value {
    case .object(let object): return .object(removeExtensions(from: object))
    case .array(let array): return .array(array.map(removeNestedExtensions))
    default: return value
    }
  }
}
