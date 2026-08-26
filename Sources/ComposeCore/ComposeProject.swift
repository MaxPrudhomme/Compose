import Foundation
import Yams

public struct ComposeProject: Equatable, Sendable {
  public let name: String
  public let workingDirectory: URL
  public let files: [URL]
  public let model: JSONValue
  public let interpolationEnvironment: [String: String]
  public let declaredProfiles: [String]
  public let allowMissingServiceDNS: Bool

  public init(
    name: String,
    workingDirectory: URL,
    files: [URL],
    model: JSONValue,
    interpolationEnvironment: [String: String],
    declaredProfiles: [String],
    allowMissingServiceDNS: Bool = false
  ) {
    self.name = name
    self.workingDirectory = workingDirectory
    self.files = files
    self.model = model
    self.interpolationEnvironment = interpolationEnvironment
    self.declaredProfiles = declaredProfiles
    self.allowMissingServiceDNS = allowMissingServiceDNS
  }

  public var serviceNames: [String] {
    model["services"]?.objectValue?.keys.sorted() ?? []
  }

  public func json(prettyPrinted: Bool = true) throws -> String {
    let data = try JSONEncoder.compose(prettyPrinted: prettyPrinted).encode(model)
    guard let value = String(data: data, encoding: .utf8) else {
      throw ComposeError("could not encode normalized project as UTF-8")
    }
    return value
  }

  public func yaml() throws -> String {
    try dump(object: model.yamlObject, sortKeys: true)
  }
}
