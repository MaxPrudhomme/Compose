import AppleContainerDriver
import Foundation
import XCTest

final class ContainerCLITests: XCTestCase {
  func testFoundationRunnerUsesArgumentVectorsAndSeparatesOutput() throws {
    let result = try FoundationProcessRunner().run(
      executable: "/usr/bin/python3",
      arguments: [
        "-c", "import sys; print(sys.argv[1]); print('error', file=sys.stderr)",
        "$(touch should-not-run)",
      ],
      environment: nil
    )

    XCTAssertEqual(result.exitCode, 0)
    XCTAssertEqual(result.stdout, "$(touch should-not-run)\n")
    XCTAssertTrue(result.stderr.hasSuffix("error\n"))
  }

  func testFoundationRunnerDrainsLargeOutputsWithoutDeadlocking() throws {
    let result = try FoundationProcessRunner().run(
      executable: "/usr/bin/python3",
      arguments: [
        "-c", "import sys; sys.stdout.write('o' * 262144); sys.stderr.write('e' * 262144)",
      ],
      environment: ["TMPDIR": "/tmp"]
    )

    XCTAssertEqual(result.exitCode, 0)
    XCTAssertEqual(result.standardOutput.count, 262_144)
    XCTAssertEqual(result.standardError.count, 262_144)
  }

  func testVersionAndCapabilities() throws {
    let runner = FakeRunner(results: [
      "--version": result(
        arguments: ["--version"], stdout: "container CLI version 1.2.2 (build: release)\n")
    ])
    let version = try ContainerCLI(executable: "/fake/container", runner: runner).version()

    XCTAssertEqual(version.major, 1)
    XCTAssertEqual(version.minor, 2)
    XCTAssertEqual(version.patch, 2)
    XCTAssertTrue(version.isSupported)
    XCTAssertFalse(ContainerCapabilities.known(for: version).serviceAliases)
  }

  func testDoctorReportsStoppedSystemWithoutThrowing() throws {
    let runner = FakeRunner(results: [
      "--version": result(
        arguments: ["--version"], stdout: "container CLI version 1.2.2 (build: release)\n"),
      "system status --format json": result(
        arguments: ["system", "status", "--format", "json"],
        exitCode: 1,
        stderr: "system is stopped\n"
      ),
    ])
    let report = try ContainerCLI(executable: "/fake/container", runner: runner).doctor()

    XCTAssertFalse(report.systemAvailable)
    XCTAssertEqual(report.systemDetail, "system is stopped")
  }

  func testExecutableOverrideMustBeExecutable() throws {
    XCTAssertThrowsError(
      try ContainerExecutableResolver().resolve(environment: ["CONTAINER_CLI": "/does/not/exist"]))
    XCTAssertEqual(
      try ContainerExecutableResolver().resolve(environment: ["CONTAINER_CLI": "/usr/bin/true"]),
      "/usr/bin/true"
    )
  }

  func testContainerListDecodesRequiredFieldsAndIgnoresAdditions() throws {
    let json = """
      [{
        "id": "app-id",
        "configuration": {
          "id": "app-id",
          "labels": {"com.apple.container.compose.project": "demo"},
          "futureField": {"anything": true}
        },
        "status": {"state": "running", "networks": []},
        "futureTopLevel": 42
      }]
      """
    let runner = FakeRunner(results: [
      "--version": result(
        arguments: ["--version"], stdout: "container CLI version 1.2.2 (build: release)\n"),
      "list --all --format json": result(
        arguments: ["list", "--all", "--format", "json"], stdout: json),
    ])

    let containers = try ContainerCLI(executable: "/fake/container", runner: runner)
      .listContainers()

    XCTAssertEqual(containers.count, 1)
    XCTAssertEqual(containers[0].id, "app-id")
    XCTAssertEqual(containers[0].status.state, "running")
    XCTAssertEqual(
      containers[0].configuration.labels["com.apple.container.compose.project"], "demo")
  }

  func testMalformedRuntimeOutputIncludesBoundedDiagnostics() throws {
    let runner = FakeRunner(results: [
      "--version": result(
        arguments: ["--version"], stdout: "container CLI version 1.2.2 (build: release)\n"),
      "list --all --format json": result(
        arguments: ["list", "--all", "--format", "json"], stdout: "[{\"id\":42}]"),
    ])

    XCTAssertThrowsError(
      try ContainerCLI(executable: "/fake/container", runner: runner).listContainers()
    ) { error in
      let outputError = error as? RuntimeOutputError
      XCTAssertEqual(outputError?.command, ["list", "--all", "--format", "json"])
      XCTAssertTrue(outputError?.containerVersion.contains("1.2.2") == true)
      XCTAssertTrue(outputError?.responseExcerpt.contains("\"id\":42") == true)
    }
  }
}

private struct FakeRunner: ProcessRunning {
  let results: [String: ProcessResult]

  func run(executable: String, arguments: [String], environment: [String: String]?) throws
    -> ProcessResult
  {
    guard let result = results[arguments.joined(separator: " ")] else {
      throw ProcessRunnerError.couldNotLaunch(
        executable: executable, underlying: "unexpected arguments")
    }
    return result
  }
}

private func result(
  arguments: [String],
  exitCode: Int32 = 0,
  stdout: String = "",
  stderr: String = ""
) -> ProcessResult {
  ProcessResult(
    executable: "/fake/container",
    arguments: arguments,
    exitCode: exitCode,
    standardOutput: Data(stdout.utf8),
    standardError: Data(stderr.utf8)
  )
}
