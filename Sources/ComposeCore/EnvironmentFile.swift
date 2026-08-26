import Foundation

public enum EnvironmentFile {
  public static func load(url: URL, base: [String: String] = [:]) throws -> [String: String] {
    guard FileManager.default.fileExists(atPath: url.path) else {
      throw ComposeError("environment file does not exist: \(url.path)")
    }

    let contents: String
    do {
      contents = try String(contentsOf: url, encoding: .utf8)
    } catch {
      throw ComposeError("could not read environment file as UTF-8: \(url.path)")
    }

    var environment = base
    for (offset, rawLine) in contents.split(
      omittingEmptySubsequences: false, whereSeparator: \Character.isNewline
    ).enumerated() {
      var line = rawLine.trimmingCharacters(in: .whitespaces)
      guard !line.isEmpty, !line.hasPrefix("#") else { continue }
      if line.hasPrefix("export ") {
        line.removeFirst("export ".count)
      }

      guard let equals = line.firstIndex(of: "=") else {
        throw ComposeError(
          "expected KEY=VALUE in environment file",
          location: SourceLocation(file: url.path, line: offset + 1, column: 1)
        )
      }
      let key = line[..<equals].trimmingCharacters(in: .whitespaces)
      guard isValidName(key) else {
        throw ComposeError(
          "invalid environment variable name",
          location: SourceLocation(file: url.path, line: offset + 1, column: 1)
        )
      }

      var value = String(line[line.index(after: equals)...]).trimmingCharacters(in: .whitespaces)
      if value.count >= 2, value.first == "'", value.last == "'" {
        value = String(value.dropFirst().dropLast())
      } else {
        if value.count >= 2, value.first == "\"", value.last == "\"" {
          value = String(value.dropFirst().dropLast())
          value =
            value
            .replacingOccurrences(of: "\\n", with: "\n")
            .replacingOccurrences(of: "\\r", with: "\r")
            .replacingOccurrences(of: "\\t", with: "\t")
        } else if let comment = inlineCommentStart(in: value) {
          value = String(value[..<comment]).trimmingCharacters(in: .whitespaces)
        }
        value = try Interpolator(environment: environment).interpolate(value)
      }
      environment[String(key)] = value
    }
    return environment
  }

  private static func isValidName(_ value: String) -> Bool {
    guard let first = value.first, first == "_" || first.isLetter else { return false }
    return value.dropFirst().allSatisfy { $0 == "_" || $0.isLetter || $0.isNumber }
  }

  private static func inlineCommentStart(in value: String) -> String.Index? {
    var previousWasWhitespace = false
    for index in value.indices {
      if value[index] == "#", previousWasWhitespace {
        return index
      }
      previousWasWhitespace = value[index].isWhitespace
    }
    return nil
  }
}
