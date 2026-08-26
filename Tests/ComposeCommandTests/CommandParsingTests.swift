import ArgumentParser
import ComposeCommands
import XCTest

final class CommandParsingTests: XCTestCase {
  func testGlobalOptionsBeforeSubcommandReachConfig() throws {
    let parsed = try ComposeCommand.parseAsRoot([
      "-f", "compose.yml", "--profile", "debug", "config", "--format", "json",
    ])
    let command = try XCTUnwrap(parsed as? ConfigCommand)

    XCTAssertEqual(command.options.files, ["compose.yml"])
    XCTAssertEqual(command.options.profiles, ["debug"])
    XCTAssertEqual(command.format, "json")
  }

  func testGlobalOptionsAfterSubcommandReachConfig() throws {
    let parsed = try ComposeCommand.parseAsRoot([
      "config", "-f", "compose.yml", "--project-name", "demo",
    ])
    let command = try XCTUnwrap(parsed as? ConfigCommand)

    XCTAssertEqual(command.options.files, ["compose.yml"])
    XCTAssertEqual(command.options.projectName, "demo")
  }

  func testUpDoesNotRequireDetachFlag() throws {
    let parsed = try ComposeCommand.parseAsRoot(["up"])
    let command = try XCTUnwrap(parsed as? UpCommand)

    XCTAssertFalse(command.detach)
  }
}
