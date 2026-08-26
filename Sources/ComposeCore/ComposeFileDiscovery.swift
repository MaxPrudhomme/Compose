import Foundation

public struct ComposeLoadOptions: Equatable, Sendable {
  public var files: [String]
  public var projectName: String?
  public var projectDirectory: String?
  public var environmentFiles: [String]
  public var profiles: Set<String>
  public var currentDirectory: String
  public var environment: [String: String]

  public init(
    files: [String] = [],
    projectName: String? = nil,
    projectDirectory: String? = nil,
    environmentFiles: [String] = [],
    profiles: Set<String> = [],
    currentDirectory: String = FileManager.default.currentDirectoryPath,
    environment: [String: String] = ProcessInfo.processInfo.environment
  ) {
    self.files = files
    self.projectName = projectName
    self.projectDirectory = projectDirectory
    self.environmentFiles = environmentFiles
    self.profiles = profiles
    self.currentDirectory = currentDirectory
    self.environment = environment
  }
}

public enum ComposeFileDiscovery {
  public static let candidates = [
    "compose.yaml",
    "compose.yml",
    "docker-compose.yaml",
    "docker-compose.yml",
  ]

  public static func discover(options: ComposeLoadOptions, environment: [String: String]) throws
    -> [URL]
  {
    if !options.files.isEmpty {
      return try options.files.map { try resolve(path: $0, relativeTo: options.currentDirectory) }
    }

    if let composeFile = environment["COMPOSE_FILE"], !composeFile.isEmpty {
      let separator = environment["COMPOSE_PATH_SEPARATOR"].flatMap(\.first) ?? ":"
      return try composeFile.split(separator: separator).map {
        try resolve(path: String($0), relativeTo: options.currentDirectory)
      }
    }

    var directory = URL(
      fileURLWithPath: options.projectDirectory ?? options.currentDirectory, isDirectory: true
    ).standardizedFileURL
    while true {
      for candidate in candidates {
        let url = directory.appendingPathComponent(candidate)
        if FileManager.default.fileExists(atPath: url.path) {
          return [url.resolvingSymlinksInPath()]
        }
      }
      let parent = directory.deletingLastPathComponent()
      if parent.path == directory.path { break }
      directory = parent
    }

    throw ComposeError("no Compose file found in this directory or its parents")
  }

  public static func resolve(path: String, relativeTo directory: String) throws -> URL {
    let expanded = NSString(string: path).expandingTildeInPath
    let url = URL(
      fileURLWithPath: expanded, relativeTo: URL(fileURLWithPath: directory, isDirectory: true)
    )
    .standardizedFileURL
    .resolvingSymlinksInPath()
    guard FileManager.default.fileExists(atPath: url.path) else {
      throw ComposeError("Compose file does not exist: \(url.path)")
    }
    return url
  }
}
