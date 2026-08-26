import Foundation
import Yams

public struct ComposeLoader {
  public init() {}

  public func load(options: ComposeLoadOptions = .init()) throws -> ComposeProject {
    let currentDirectory = URL(fileURLWithPath: options.currentDirectory, isDirectory: true)
      .standardizedFileURL
    let discoveryDirectory =
      options.projectDirectory.map {
        URL(fileURLWithPath: $0, relativeTo: currentDirectory).standardizedFileURL
      } ?? currentDirectory
    let implicitEnvironmentFile = discoveryDirectory.appendingPathComponent(".env")

    var discoveryEnvironment: [String: String] = [:]
    if FileManager.default.fileExists(atPath: implicitEnvironmentFile.path) {
      discoveryEnvironment = try EnvironmentFile.load(
        url: implicitEnvironmentFile, base: options.environment)
    }
    discoveryEnvironment.merge(options.environment) { _, processValue in processValue }

    let files = try ComposeFileDiscovery.discover(
      options: options, environment: discoveryEnvironment)
    let workingDirectory: URL
    if let explicitDirectory = options.projectDirectory {
      workingDirectory =
        URL(fileURLWithPath: explicitDirectory, relativeTo: currentDirectory)
        .standardizedFileURL
    } else {
      workingDirectory = files[0].deletingLastPathComponent()
    }

    var interpolationEnvironment: [String: String] = [:]
    if options.environmentFiles.isEmpty {
      let projectEnvironmentFile = workingDirectory.appendingPathComponent(".env")
      if FileManager.default.fileExists(atPath: projectEnvironmentFile.path) {
        interpolationEnvironment = try EnvironmentFile.load(
          url: projectEnvironmentFile, base: options.environment)
      }
    } else {
      interpolationEnvironment = options.environment
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
      let normalizedFile = try normalizeMergeSyntax(
        parsed.value,
        projectDirectory: workingDirectory,
        environment: interpolationEnvironment,
        directives: parsed.directives
      )
      merged = merge(
        base: merged, override: normalizedFile, path: [], directives: parsed.directives)
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
      environment: interpolationEnvironment,
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
  fileprivate enum MergeDirective: Equatable {
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
      let resolver = try Resolver.default.replacing(
        .bool, with: "^(?:true|True|TRUE|false|False|FALSE)$")
      guard let parsed = try compose(yaml: yaml, resolver) else {
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
      return .sequence(
        .init(children, sequence.tag, sequence.style, sequence.mark, sequence.anchor))
    case .mapping(let mapping):
      let pairs = try mapping.map { pair in
        (pair.key, try interpolate(node: pair.value, environment: environment, file: file))
      }
      return .mapping(.init(pairs, mapping.tag, mapping.style, mapping.mark, mapping.anchor))
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
    if directives[path] == .override {
      return override
    }

    switch (base, override) {
    case (.object(let baseObject), .object(let overrideObject)):
      var result = baseObject
      for (key, value) in overrideObject {
        if directives[path + [key]] == .reset {
          result.removeValue(forKey: key)
          continue
        }
        if let existing = result[key] {
          result[key] = merge(
            base: existing, override: value, path: path + [key], directives: directives)
        } else if case .object = value {
          result[key] = merge(
            base: .object([:]), override: value, path: path + [key], directives: directives)
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
        return ["host_ip", "target", "published", "protocol"].map {
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
  fileprivate func normalizeMergeSyntax(
    _ value: JSONValue,
    projectDirectory: URL,
    environment: [String: String],
    directives: [[String]: MergeDirective]
  ) throws -> JSONValue {
    guard case .object(var root) = value,
      case .object(var services)? = root["services"]
    else {
      return value
    }

    for (name, value) in services {
      guard case .object(var service) = value else { continue }
      func isReset(_ key: String) -> Bool {
        directives[["services", name, key]] == .reset
      }

      if !isReset("env_file"), let envFile = service["env_file"] {
        service["env_file"] = try normalizeEnvFileSyntax(envFile, service: name)
      }
      if !isReset("environment"), let environmentValue = service["environment"] {
        service["environment"] = try normalizeEnvironment(
          envFile: nil,
          environment: environmentValue,
          projectDirectory: projectDirectory,
          interpolationEnvironment: environment
        )
      }
      if !isReset("build"), let build = service["build"] {
        service["build"] = try normalizeBuildForMerge(
          build, service: name, projectDirectory: projectDirectory)
      }
      if !isReset("ports"), let ports = service["ports"] {
        service["ports"] = try normalizePorts(ports, service: name)
      }
      if !isReset("volumes"), let volumes = service["volumes"] {
        service["volumes"] = try normalizeVolumes(
          volumes, service: name, projectDirectory: projectDirectory)
      }
      if !isReset("depends_on"), let dependsOn = service["depends_on"] {
        service["depends_on"] = try normalizeDependsOn(dependsOn, service: name)
      }
      if !isReset("networks"), let networks = service["networks"] {
        service["networks"] = try normalizeServiceNetworks(networks, service: name)
      }
      if !isReset("labels"), let labels = service["labels"] {
        let normalized = try normalizeStringMap(labels, field: "labels", service: name)
        service["labels"] = .object(removeExtensions(from: normalized.objectValue ?? [:]))
      }
      services[name] = .object(service)
    }
    root["services"] = .object(services)
    return .object(root)
  }

  fileprivate func resolveProjectName(
    explicit: String?,
    environment: [String: String],
    model: JSONValue,
    workingDirectory: URL
  ) throws -> String {
    let candidate =
      explicit ?? environment["COMPOSE_PROJECT_NAME"] ?? model["name"]?.stringValue
      ?? workingDirectory.lastPathComponent
    let allowed = Set("abcdefghijklmnopqrstuvwxyz0123456789_-")
    let normalized = candidate.lowercased().filter { allowed.contains($0) }
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
    environment: [String: String],
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
      services[name] = try normalizeService(
        service,
        name: name,
        projectDirectory: workingDirectory,
        environment: environment
      )
    }
    for (name, service) in services {
      for dependency in service["depends_on"]?.objectValue ?? [:] {
        let isRequired = dependency.value["required"] != .bool(false)
        if isRequired, services[dependency.key] == nil {
          throw ComposeError(
            "service '\(name)' depends on service '\(dependency.key)' which is undefined or disabled by profiles",
            location: sourceLocations[["services", name, "depends_on"]]
          )
        }
      }
    }
    root["name"] = .string(projectName)
    root["services"] = .object(services)
    root["networks"] = try normalizeNetworks(
      root["networks"], projectName: projectName,
      needsDefault: services.values.contains { $0["networks"]?["default"] != nil })
    if let volumes = root["volumes"] {
      root["volumes"] = try normalizeNamedResources(
        volumes, projectName: projectName, kind: "volume")
    }
    let declaredNetworks = root["networks"]?.objectValue ?? [:]
    let declaredVolumes = root["volumes"]?.objectValue ?? [:]
    for (name, service) in services {
      for network in service["networks"]?.objectValue?.keys ?? Dictionary().keys
      where declaredNetworks[network] == nil {
        throw ComposeError(
          "service '\(name)' references undefined network '\(network)'",
          location: sourceLocations[["services", name, "networks"]])
      }
      for volume in service["volumes"]?.arrayValue ?? []
      where volume["type"] == .string("volume") {
        if let source = volume["source"]?.stringValue, declaredVolumes[source] == nil {
          throw ComposeError(
            "service '\(name)' references undefined volume '\(source)'",
            location: sourceLocations[["services", name, "volumes"]])
        }
      }
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
    _ input: [String: JSONValue],
    name: String,
    projectDirectory: URL,
    environment interpolationEnvironment: [String: String]
  ) throws -> JSONValue {
    var service = input
    for field in ["deploy", "healthcheck"] {
      if let object = service[field]?.objectValue {
        service[field] = .object(removeExtensions(from: object))
      }
    }
    if service["env_file"] != nil || service["environment"] != nil {
      service["environment"] = try normalizeEnvironment(
        envFile: service.removeValue(forKey: "env_file"),
        environment: service["environment"],
        projectDirectory: projectDirectory,
        interpolationEnvironment: interpolationEnvironment
      )
    }

    if let build = service["build"] {
      service["build"] = try normalizeBuild(build, projectDirectory: projectDirectory)
    }
    if let ports = service["ports"] {
      service["ports"] = try normalizePorts(ports, service: name)
    }
    if let volumes = service["volumes"] {
      service["volumes"] = try normalizeVolumes(
        volumes, service: name, projectDirectory: projectDirectory)
    }
    if let dependsOn = service["depends_on"] {
      service["depends_on"] = try normalizeDependsOn(dependsOn, service: name)
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
    envFile: JSONValue?,
    environment: JSONValue?,
    projectDirectory: URL,
    interpolationEnvironment: [String: String]
  ) throws -> JSONValue {
    var result: [String: JSONValue] = [:]
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
        let loaded = try EnvironmentFile.load(
          url: url,
          base: result.compactMapValues(\.stringValue)
        )
        result.merge(loaded.mapValues(JSONValue.string)) { _, newer in newer }
      }
    }

    if let environment {
      switch environment {
      case .object(let values):
        for (key, value) in values {
          if case .null = value {
            result[key] = interpolationEnvironment[key].map(JSONValue.string) ?? .null
          } else {
            result[key] = .string(scalarString(value))
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
            pair.count == 2
            ? .string(String(pair[1]))
            : interpolationEnvironment[key].map(JSONValue.string) ?? .null
        }
      default:
        throw ComposeError("environment must be a mapping or list")
      }
    }
    return .object(result)
  }

  fileprivate func normalizeEnvFileSyntax(_ value: JSONValue, service: String) throws -> JSONValue {
    switch value {
    case .string(let path):
      return .array([.string(path)])
    case .array(let entries):
      guard entries.allSatisfy({ $0.stringValue != nil }) else {
        throw ComposeError("env_file for service '\(service)' must contain only paths")
      }
      return .array(entries)
    default:
      throw ComposeError("env_file for service '\(service)' must be a path or list of paths")
    }
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
      build = removeExtensions(from: object)
    default:
      throw ComposeError("build must be a path or mapping")
    }
    let context = build["context"]?.stringValue ?? "."
    build["context"] = .string(
      URL(fileURLWithPath: context, relativeTo: projectDirectory).standardizedFileURL.path)
    if build["dockerfile"] == nil { build["dockerfile"] = .string("Dockerfile") }
    return .object(build)
  }

  fileprivate func normalizeBuildForMerge(
    _ value: JSONValue,
    service: String,
    projectDirectory: URL
  ) throws -> JSONValue {
    switch value {
    case .string(let context):
      return .object(["context": .string(absolutePath(context, relativeTo: projectDirectory))])
    case .object(var build):
      if let context = build["context"]?.stringValue {
        build["context"] = .string(absolutePath(context, relativeTo: projectDirectory))
      }
      if let args = build["args"] {
        build["args"] = try normalizeStringMap(args, field: "build.args", service: service)
      }
      return .object(build)
    default:
      throw ComposeError("build must be a path or mapping")
    }
  }

  fileprivate func normalizePorts(_ value: JSONValue, service: String) throws -> JSONValue {
    guard case .array(let ports) = value else {
      throw ComposeError("ports for service '\(service)' must be a list")
    }
    return .array(try ports.flatMap { try normalizePort($0, service: service) })
  }

  fileprivate func normalizePort(_ value: JSONValue, service: String) throws -> [JSONValue] {
    if case .object(var port) = value {
      port = removeExtensions(from: port)
      guard let target = integerPort(port["target"]) else {
        throw ComposeError("long-syntax port for service '\(service)' requires a numeric target")
      }
      port["target"] = .integer(target)
      if let published = port["published"] {
        guard let value = scalarPort(published), !value.contains("-") else {
          throw ComposeError(
            "long-syntax published port for service '\(service)' must be one fixed port")
        }
        port["published"] = .string(value)
      }
      if port["protocol"] == nil { port["protocol"] = .string("tcp") }
      if port["mode"] == nil { port["mode"] = .string("ingress") }
      return [.object(port)]
    }
    guard case .string(let short) = value else {
      throw ComposeError("port entries for service '\(service)' must be strings or mappings")
    }
    let protocolParts = short.split(separator: "/", maxSplits: 1, omittingEmptySubsequences: false)
    let protocolName = protocolParts.count == 2 ? String(protocolParts[1]).lowercased() : "tcp"
    let address = String(protocolParts[0])

    let hostIP: String?
    let fields: [Substring]
    if address.hasPrefix("["), let closingBracket = address.firstIndex(of: "]") {
      hostIP = String(address[address.index(after: address.startIndex)..<closingBracket])
      let remainder = address[address.index(after: closingBracket)...]
      guard remainder.first == ":" else {
        throw ComposeError("invalid published port '\(short)' for service '\(service)'")
      }
      fields = remainder.dropFirst().split(separator: ":", omittingEmptySubsequences: false)
    } else {
      let parts = address.split(separator: ":", omittingEmptySubsequences: false)
      guard parts.count <= 3 else {
        throw ComposeError(
          "IPv6 host addresses in ports must be enclosed in brackets: '\(short)'")
      }
      hostIP = parts.count == 3 ? String(parts[0]) : nil
      fields = Array(parts.suffix(parts.count == 3 ? 2 : parts.count))
    }

    guard let targetText = fields.last else {
      throw ComposeError("invalid published port '\(short)' for service '\(service)'")
    }
    let targets = try portRange(String(targetText), original: short, service: service)
    let published =
      fields.count == 2
      ? try portRange(String(fields[0]), original: short, service: service)
      : []
    if !published.isEmpty, published.count != targets.count {
      throw ComposeError(
        "published and target port ranges must contain the same number of ports in '\(short)'")
    }

    return targets.enumerated().map { index, target in
      var object: [String: JSONValue] = [
        "mode": .string("ingress"),
        "target": .integer(target),
        "protocol": .string(protocolName),
      ]
      if !published.isEmpty { object["published"] = .string(String(published[index])) }
      if let hostIP { object["host_ip"] = .string(hostIP) }
      return .object(object)
    }
  }

  fileprivate func integerPort(_ value: JSONValue?) -> Int64? {
    switch value {
    case .integer(let value) where (1...65_535).contains(value): return value
    case .string(let value): return Int64(value).flatMap { (1...65_535).contains($0) ? $0 : nil }
    default: return nil
    }
  }

  fileprivate func scalarPort(_ value: JSONValue) -> String? {
    switch value {
    case .integer(let value) where (1...65_535).contains(value): return String(value)
    case .string(let value): return value
    default: return nil
    }
  }

  fileprivate func portRange(_ value: String, original: String, service: String) throws -> [Int64] {
    let bounds = value.split(separator: "-", maxSplits: 1, omittingEmptySubsequences: false)
    guard let start = bounds.first.flatMap({ Int64($0) }), (1...65_535).contains(start) else {
      throw ComposeError("invalid published port '\(original)' for service '\(service)'")
    }
    guard bounds.count == 2 else { return [start] }
    guard let end = Int64(bounds[1]), start <= end, end <= 65_535 else {
      throw ComposeError("invalid published port '\(original)' for service '\(service)'")
    }
    return Array(start...end)
  }

  fileprivate func normalizeVolumes(
    _ value: JSONValue,
    service: String,
    projectDirectory: URL
  ) throws -> JSONValue {
    guard case .array(let volumes) = value else {
      throw ComposeError("volumes for service '\(service)' must be a list")
    }
    return .array(
      try volumes.map { volume in
        switch volume {
        case .string(let short):
          return try normalizeVolumeShortSyntax(
            short, service: service, projectDirectory: projectDirectory)
        case .object(var object):
          object = removeExtensions(from: object)
          for field in ["bind", "volume"] {
            if let options = object[field]?.objectValue {
              object[field] = .object(removeExtensions(from: options))
            }
          }
          if object["type"] == .string("bind"), let source = object["source"]?.stringValue {
            object["source"] = .string(absolutePath(source, relativeTo: projectDirectory))
            if object["bind"] == nil { object["bind"] = .object([:]) }
          } else if object["type"] == .string("volume"), object["volume"] == nil {
            object["volume"] = .object([:])
          }
          return .object(object)
        default:
          throw ComposeError("volume entries for service '\(service)' must be strings or mappings")
        }
      })
  }

  fileprivate func normalizeVolumeShortSyntax(
    _ value: String,
    service: String,
    projectDirectory: URL
  ) throws -> JSONValue {
    let fields = value.split(separator: ":", omittingEmptySubsequences: false).map(String.init)
    guard (1...3).contains(fields.count) else {
      throw ComposeError("invalid volume '\(value)' for service '\(service)'")
    }
    let target = fields.count == 1 ? fields[0] : fields[1]
    guard target.hasPrefix("/") else {
      throw ComposeError("volume target must be an absolute path in '\(value)'")
    }

    let source = fields.count >= 2 ? fields[0] : nil
    let isBind = source.map(isBindSource) ?? false
    var object: [String: JSONValue] = [
      "type": .string(isBind ? "bind" : "volume"),
      "target": .string(target),
      isBind ? "bind" : "volume": .object([:]),
    ]
    if let source, !source.isEmpty {
      object["source"] = .string(
        isBind ? absolutePath(source, relativeTo: projectDirectory) : source)
    }
    if fields.count == 3 {
      let modes = Set(fields[2].split(separator: ",").map(String.init))
      let knownModes: Set<String> = ["ro", "rw", "z", "Z", "nocopy"]
      let unknownModes = modes.subtracting(knownModes)
      guard unknownModes.isEmpty else {
        throw ComposeError(
          "unsupported volume mode(s) \(unknownModes.sorted().joined(separator: ", ")) in '\(value)'"
        )
      }
      if modes.contains("ro") { object["read_only"] = .bool(true) }
      if isBind, modes.contains("z") || modes.contains("Z") {
        object["bind"] = .object(["selinux": .string(modes.contains("Z") ? "Z" : "z")])
      }
      if !isBind, modes.contains("nocopy") {
        object["volume"] = .object(["nocopy": .bool(true)])
      }
    }
    return .object(object)
  }

  fileprivate func isBindSource(_ value: String) -> Bool {
    value == "." || value == ".." || value.hasPrefix("./") || value.hasPrefix("../")
      || value.hasPrefix("/") || value.hasPrefix("~")
  }

  fileprivate func absolutePath(_ value: String, relativeTo directory: URL) -> String {
    let expanded = NSString(string: value).expandingTildeInPath
    return URL(fileURLWithPath: expanded, relativeTo: directory).standardizedFileURL.path
  }

  fileprivate func normalizeDependsOn(_ value: JSONValue, service: String) throws -> JSONValue {
    switch value {
    case .array(let dependencies):
      var result: [String: JSONValue] = [:]
      for dependency in dependencies {
        guard let name = dependency.stringValue else {
          throw ComposeError("depends_on for service '\(service)' must contain service names")
        }
        result[name] = .object([
          "condition": .string("service_started"),
          "required": .bool(true),
        ])
      }
      return .object(result)
    case .object(let dependencies):
      var result: [String: JSONValue] = [:]
      for (name, value) in dependencies {
        var dependency = removeExtensions(from: value.objectValue ?? [:])
        if dependency["condition"] == nil {
          dependency["condition"] = .string("service_started")
        }
        if dependency["required"] == nil { dependency["required"] = .bool(true) }
        result[name] = .object(dependency)
      }
      return .object(result)
    default:
      throw ComposeError("depends_on for service '\(service)' must be a list or mapping")
    }
  }

  fileprivate func normalizeStringMap(_ value: JSONValue, field: String, service: String) throws
    -> JSONValue
  {
    switch value {
    case .object(let attachments):
      return .object(
        attachments.mapValues { attachment in
          guard let object = attachment.objectValue else { return attachment }
          return .object(removeExtensions(from: object))
        })
    case .array(let entries):
      var result: [String: JSONValue] = [:]
      for entry in entries {
        guard let string = entry.stringValue else {
          throw ComposeError("\(field) for service '\(service)' must contain strings")
        }
        let pair = string.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
        result[String(pair[0])] = .string(pair.count == 2 ? String(pair[1]) : "")
      }
      return .object(result)
    default:
      throw ComposeError("\(field) for service '\(service)' must be a mapping or list")
    }
  }

  fileprivate func normalizeByteSize(_ value: String) throws -> String {
    let lower = value.lowercased()
    let units: [(String, Int64)] = [
      ("kib", 1_024), ("mib", 1_048_576), ("gib", 1_073_741_824),
      ("kb", 1_024), ("mb", 1_048_576), ("gb", 1_073_741_824),
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
    throws -> JSONValue
  {
    var networks = value?.objectValue ?? [:]
    if needsDefault, networks["default"] == nil { networks["default"] = .object([:]) }
    for (key, value) in networks {
      var network = removeExtensions(from: value.objectValue ?? [:])
      let isExternal = network["external"] == .bool(true)
      if !isExternal, network["name"] == nil { network["name"] = .string("\(projectName)_\(key)") }
      if let name = network["name"]?.stringValue {
        try validateResourceName(name, kind: "network")
      }
      if network["ipam"] == nil { network["ipam"] = .object([:]) }
      networks[key] = .object(network)
    }
    return .object(networks)
  }

  fileprivate func normalizeNamedResources(_ value: JSONValue, projectName: String, kind: String)
    throws -> JSONValue
  {
    guard case .object(var resources) = value else { return value }
    for (key, value) in resources {
      var resource = removeExtensions(from: value.objectValue ?? [:])
      if resource["external"] != .bool(true), resource["name"] == nil {
        resource["name"] = .string("\(projectName)_\(key)")
      }
      if let name = resource["name"]?.stringValue {
        try validateResourceName(name, kind: kind)
      }
      resources[key] = .object(resource)
    }
    return .object(resources)
  }

  fileprivate func validateResourceName(_ value: String, kind: String) throws {
    guard value.utf8.count <= 63 else {
      throw ComposeError(
        "Apple Container \(kind) name '\(value)' exceeds the 63-byte limit; use a shorter project or resource name"
      )
    }
  }

  fileprivate func removeExtensions(from object: [String: JSONValue]) -> [String: JSONValue] {
    object.filter { !$0.key.hasPrefix("x-") }
  }
}
