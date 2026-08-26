import CryptoKit
import Foundation

public enum ServiceConfigHasher {
  public static func hash(service: JSONValue, resolvedImageIdentity: String? = nil) throws -> String
  {
    var canonical = service
    if let resolvedImageIdentity {
      canonical = canonical.setting(
        "x-apple-container-resolved-image", to: .string(resolvedImageIdentity))
    }
    let data = try JSONEncoder.compose(prettyPrinted: false).encode(canonical)
    return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
  }
}

public enum ComposeLabels {
  public static let project = "com.apple.container.compose.project"
  public static let service = "com.apple.container.compose.service"
  public static let containerNumber = "com.apple.container.compose.container-number"
  public static let oneoff = "com.apple.container.compose.oneoff"
  public static let workingDirectory = "com.apple.container.compose.project.working-dir"
  public static let configFiles = "com.apple.container.compose.project.config-files"
  public static let configHash = "com.apple.container.compose.config-hash"
  public static let schemaVersion = "com.apple.container.compose.schema-version"
  public static let network = "com.apple.container.compose.network"
  public static let volume = "com.apple.container.compose.volume"

  public static func container(
    projectName: String,
    serviceName: String,
    number: Int = 1,
    oneoff: Bool = false,
    workingDirectory: URL,
    files: [URL],
    hash: String
  ) -> [String: String] {
    [
      project: projectName,
      service: serviceName,
      containerNumber: String(number),
      self.oneoff: String(oneoff),
      self.workingDirectory: workingDirectory.path,
      configFiles: files.map(\.path).joined(separator: ","),
      configHash: hash,
      schemaVersion: "1",
    ]
  }
}
