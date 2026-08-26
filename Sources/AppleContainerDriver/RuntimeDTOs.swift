import Foundation

public struct RuntimeContainer: Decodable, Equatable, Sendable {
  public struct Configuration: Decodable, Equatable, Sendable {
    public let id: String
    public let labels: [String: String]

    public init(id: String, labels: [String: String]) {
      self.id = id
      self.labels = labels
    }

    private enum CodingKeys: String, CodingKey {
      case id
      case labels
    }

    public init(from decoder: Decoder) throws {
      let values = try decoder.container(keyedBy: CodingKeys.self)
      id = try values.decode(String.self, forKey: .id)
      labels = try values.decodeIfPresent([String: String].self, forKey: .labels) ?? [:]
    }
  }

  public struct Status: Decodable, Equatable, Sendable {
    public let state: String

    public init(state: String) {
      self.state = state
    }
  }

  public let id: String
  public let configuration: Configuration
  public let status: Status
}

public struct RuntimeNetwork: Decodable, Equatable, Sendable {
  public struct Configuration: Decodable, Equatable, Sendable {
    public let name: String
    public let labels: [String: String]

    public init(name: String, labels: [String: String]) {
      self.name = name
      self.labels = labels
    }

    private enum CodingKeys: String, CodingKey {
      case name
      case labels
    }

    public init(from decoder: Decoder) throws {
      let values = try decoder.container(keyedBy: CodingKeys.self)
      name = try values.decode(String.self, forKey: .name)
      labels = try values.decodeIfPresent([String: String].self, forKey: .labels) ?? [:]
    }
  }

  public let id: String
  public let configuration: Configuration
}

public struct RuntimeVolume: Decodable, Equatable, Sendable {
  public struct Configuration: Decodable, Equatable, Sendable {
    public let name: String
    public let labels: [String: String]

    public init(name: String, labels: [String: String]) {
      self.name = name
      self.labels = labels
    }

    private enum CodingKeys: String, CodingKey {
      case name
      case labels
    }

    public init(from decoder: Decoder) throws {
      let values = try decoder.container(keyedBy: CodingKeys.self)
      name = try values.decode(String.self, forKey: .name)
      labels = try values.decodeIfPresent([String: String].self, forKey: .labels) ?? [:]
    }
  }

  public let id: String
  public let configuration: Configuration
}

public enum RuntimeOutputDecoder {
  public static func decode<T: Decodable>(
    _ type: T.Type,
    from data: Data,
    command: [String],
    containerVersion: String
  ) throws -> T {
    do {
      return try JSONDecoder().decode(type, from: data)
    } catch {
      let excerpt = String(decoding: data.prefix(2_048), as: UTF8.self)
        .trimmingCharacters(in: .whitespacesAndNewlines)
      throw RuntimeOutputError(
        command: command,
        containerVersion: containerVersion,
        detail: String(describing: error),
        responseExcerpt: excerpt
      )
    }
  }
}

public struct RuntimeOutputError: Error, Equatable, Sendable, CustomStringConvertible {
  public let command: [String]
  public let containerVersion: String
  public let detail: String
  public let responseExcerpt: String

  public var description: String {
    let rendered = (["container"] + command).map { "\"\($0)\"" }.joined(separator: " ")
    return
      "could not decode Apple Container output from [\(rendered)] using \(containerVersion): \(detail); response: \(responseExcerpt)"
  }
}

extension RuntimeOutputError: LocalizedError {
  public var errorDescription: String? { description }
}
