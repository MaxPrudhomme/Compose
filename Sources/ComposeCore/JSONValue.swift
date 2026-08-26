import Foundation

public enum JSONValue: Equatable, Sendable {
  case object([String: JSONValue])
  case array([JSONValue])
  case string(String)
  case integer(Int64)
  case number(Double)
  case bool(Bool)
  case null

  public init(any value: Any) throws {
    switch value {
    case let value as [String: Any]:
      self = .object(try value.mapValues(JSONValue.init(any:)))
    case let value as [AnyHashable: Any]:
      var object: [String: JSONValue] = [:]
      for (key, item) in value {
        guard let key = key as? String else {
          throw ComposeError("YAML mapping keys must be strings")
        }
        object[key] = try JSONValue(any: item)
      }
      self = .object(object)
    case let value as [Any]:
      self = .array(try value.map(JSONValue.init(any:)))
    case let value as String:
      self = .string(value)
    case let value as Bool:
      self = .bool(value)
    case let value as Int:
      self = .integer(Int64(value))
    case let value as Int64:
      self = .integer(value)
    case let value as UInt64 where value <= UInt64(Int64.max):
      self = .integer(Int64(value))
    case let value as Double:
      self = .number(value)
    case is NSNull:
      self = .null
    default:
      throw ComposeError("unsupported YAML value of type \(String(describing: type(of: value)))")
    }
  }

  public var objectValue: [String: JSONValue]? {
    guard case .object(let value) = self else { return nil }
    return value
  }

  public var arrayValue: [JSONValue]? {
    guard case .array(let value) = self else { return nil }
    return value
  }

  public var stringValue: String? {
    guard case .string(let value) = self else { return nil }
    return value
  }

  public subscript(key: String) -> JSONValue? {
    guard case .object(let object) = self else { return nil }
    return object[key]
  }

  public func setting(_ key: String, to value: JSONValue?) -> JSONValue {
    guard case .object(var object) = self else { return self }
    object[key] = value
    return .object(object)
  }

  public var yamlObject: Any {
    switch self {
    case .object(let object):
      return object.mapValues(\.yamlObject)
    case .array(let array):
      return array.map(\.yamlObject)
    case .string(let value):
      return value
    case .integer(let value):
      return value
    case .number(let value):
      return value
    case .bool(let value):
      return value
    case .null:
      return NSNull()
    }
  }
}

extension JSONValue: Codable {
  public init(from decoder: Decoder) throws {
    let container = try decoder.singleValueContainer()
    if container.decodeNil() {
      self = .null
    } else if let value = try? container.decode(Bool.self) {
      self = .bool(value)
    } else if let value = try? container.decode(Int64.self) {
      self = .integer(value)
    } else if let value = try? container.decode(Double.self) {
      self = .number(value)
    } else if let value = try? container.decode(String.self) {
      self = .string(value)
    } else if let value = try? container.decode([JSONValue].self) {
      self = .array(value)
    } else {
      self = .object(try container.decode([String: JSONValue].self))
    }
  }

  public func encode(to encoder: Encoder) throws {
    var container = encoder.singleValueContainer()
    switch self {
    case .object(let value): try container.encode(value)
    case .array(let value): try container.encode(value)
    case .string(let value): try container.encode(value)
    case .integer(let value): try container.encode(value)
    case .number(let value): try container.encode(value)
    case .bool(let value): try container.encode(value)
    case .null: try container.encodeNil()
    }
  }
}

extension JSONEncoder {
  public static func compose(prettyPrinted: Bool = true) -> JSONEncoder {
    let encoder = JSONEncoder()
    encoder.outputFormatting =
      prettyPrinted
      ? [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
      : [.sortedKeys, .withoutEscapingSlashes]
    return encoder
  }
}
