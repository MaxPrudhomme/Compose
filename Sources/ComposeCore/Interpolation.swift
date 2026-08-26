import Foundation

public struct Interpolator: Sendable {
  public let environment: [String: String]

  public init(environment: [String: String]) {
    self.environment = environment
  }

  public func interpolate(_ input: String, location: SourceLocation? = nil) throws -> String {
    var output = ""
    var index = input.startIndex

    while index < input.endIndex {
      guard input[index] == "$" else {
        output.append(input[index])
        index = input.index(after: index)
        continue
      }

      let next = input.index(after: index)
      guard next < input.endIndex else {
        output.append("$")
        break
      }

      if input[next] == "$" {
        output.append("$")
        index = input.index(after: next)
        continue
      }

      if input[next] == "{" {
        let expressionStart = input.index(after: next)
        guard let expressionEnd = matchingBrace(in: input, from: expressionStart) else {
          throw ComposeError("invalid interpolation: missing closing brace", location: location)
        }
        let expression = String(input[expressionStart..<expressionEnd])
        output += try evaluate(expression, location: location)
        index = input.index(after: expressionEnd)
        continue
      }

      if isVariableStart(input[next]) {
        var end = input.index(after: next)
        while end < input.endIndex, isVariableContinuation(input[end]) {
          end = input.index(after: end)
        }
        let name = String(input[next..<end])
        output += environment[name] ?? ""
        index = end
        continue
      }

      output.append("$")
      index = next
    }

    return output
  }

  private func matchingBrace(in input: String, from start: String.Index) -> String.Index? {
    var index = start
    var nested = 0
    while index < input.endIndex {
      if input[index] == "$" {
        let next = input.index(after: index)
        if next < input.endIndex, input[next] == "{" {
          nested += 1
          index = input.index(after: next)
          continue
        }
      }
      if input[index] == "}" {
        if nested == 0 { return index }
        nested -= 1
      }
      index = input.index(after: index)
    }
    return nil
  }

  private func evaluate(_ expression: String, location: SourceLocation?) throws -> String {
    guard let first = expression.first, isVariableStart(first) else {
      throw ComposeError("invalid interpolation expression", location: location)
    }

    var split = expression.startIndex
    split = expression.index(after: split)
    while split < expression.endIndex, isVariableContinuation(expression[split]) {
      split = expression.index(after: split)
    }

    let name = String(expression[..<split])
    let remainder = String(expression[split...])
    let current = environment[name]
    let isSet = current != nil
    let isNonEmpty = !(current ?? "").isEmpty

    let operation: String
    let operand: String
    if remainder.hasPrefix(":-") || remainder.hasPrefix(":+") || remainder.hasPrefix(":?") {
      operation = String(remainder.prefix(2))
      operand = String(remainder.dropFirst(2))
    } else if let first = remainder.first, "-+?".contains(first) {
      operation = String(first)
      operand = String(remainder.dropFirst())
    } else if remainder.isEmpty {
      operation = ""
      operand = ""
    } else {
      throw ComposeError("invalid interpolation operator for \(name)", location: location)
    }

    switch operation {
    case "":
      return current ?? ""
    case "-":
      return isSet ? current! : try interpolate(operand, location: location)
    case ":-":
      return isNonEmpty ? current! : try interpolate(operand, location: location)
    case "+":
      return isSet ? try interpolate(operand, location: location) : ""
    case ":+":
      return isNonEmpty ? try interpolate(operand, location: location) : ""
    case "?":
      guard isSet else {
        throw ComposeError(operand.isEmpty ? "\(name) is required" : operand, location: location)
      }
      return current!
    case ":?":
      guard isNonEmpty else {
        throw ComposeError(
          operand.isEmpty ? "\(name) is required and cannot be empty" : operand, location: location)
      }
      return current!
    default:
      preconditionFailure("validated interpolation operation")
    }
  }

  private func isVariableStart(_ character: Character) -> Bool {
    character == "_" || character.isLetter
  }

  private func isVariableContinuation(_ character: Character) -> Bool {
    isVariableStart(character) || character.isNumber
  }
}
