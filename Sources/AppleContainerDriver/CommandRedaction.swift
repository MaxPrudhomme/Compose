import Foundation

public enum CommandRedaction {
  public static func redact(_ arguments: [String]) -> [String] {
    let sensitiveFlags: Set<String> = [
      "--env", "-e", "--build-arg", "--secret", "--password", "--token",
    ]
    var result: [String] = []
    var redactNext = false
    for argument in arguments {
      if redactNext {
        let first = argument.split(
          separator: "=", maxSplits: 1, omittingEmptySubsequences: false
        ).first.map(String.init)
        let key = first?.isEmpty == false ? first! : "value"
        result.append("\(key)=<redacted>")
        redactNext = false
      } else if sensitiveFlags.contains(argument) {
        result.append(argument)
        redactNext = true
      } else if let flag = sensitiveFlags.first(where: { argument.hasPrefix("\($0)=") }) {
        result.append("\(flag)=<redacted>")
      } else {
        result.append(argument)
      }
    }
    return result
  }
}
