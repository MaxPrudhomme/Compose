import Foundation

public struct SourceLocation: Equatable, Sendable, CustomStringConvertible {
  public let file: String
  public let line: Int
  public let column: Int

  public init(file: String, line: Int, column: Int) {
    self.file = file
    self.line = line
    self.column = column
  }

  public var description: String {
    "\(file):\(line):\(column)"
  }
}

public struct ComposeError: Error, Equatable, Sendable, CustomStringConvertible {
  public let message: String
  public let location: SourceLocation?

  public init(_ message: String, location: SourceLocation? = nil) {
    self.message = message
    self.location = location
  }

  public var description: String {
    if let location {
      return "\(location): error: \(message)"
    }
    return "error: \(message)"
  }
}

extension ComposeError: LocalizedError {
  public var errorDescription: String? { description }
}
