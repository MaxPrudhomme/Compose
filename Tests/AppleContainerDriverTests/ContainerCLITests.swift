import AppleContainerDriver
import Foundation
import XCTest

final class ContainerCLITests: XCTestCase {
  func testEmittedFlagsExistInPinnedAppleContainerHelpContract() throws {
    struct Contract: Decodable {
      let version: String
      let capturedWith: [String]
      let commands: [String: [String]]
    }

    let testsDirectory = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
    let repository = testsDirectory.deletingLastPathComponent().deletingLastPathComponent()
    let contractURL = repository.appendingPathComponent(
      "Tests/Fixtures/apple-container-1.2.2/cli-help-contract.json")
    let contract = try JSONDecoder().decode(
      Contract.self, from: Data(contentsOf: contractURL))
    let source = try String(
      contentsOf: repository.appendingPathComponent(
        "Sources/AppleContainerDriver/ComposeToContainer.swift"),
      encoding: .utf8)
    let expression = try NSRegularExpression(pattern: "--[a-z][a-z0-9-]+")
    let range = NSRange(source.startIndex..., in: source)
    let emittedFlags = Set(
      expression.matches(in: source, range: range).compactMap { match in
        Range(match.range, in: source).map { String(source[$0]) }
      })
    let documentedFlags = Set(contract.commands.values.flatMap { $0 })

    XCTAssertEqual(contract.version, "1.2.2")
    XCTAssertEqual(contract.capturedWith.count, 10)
    XCTAssertTrue(
      emittedFlags.isSubset(of: documentedFlags),
      "translator emits flags absent from pinned container help: \(emittedFlags.subtracting(documentedFlags).sorted())"
    )
    XCTAssertTrue(contract.commands["system start"]?.contains("--enable-kernel-install") == true)
    XCTAssertTrue(contract.commands["stop"]?.contains("--time") == true)
    XCTAssertTrue(contract.commands["image pull"]?.contains("--platform") == true)
  }

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

  func testFoundationRunnerTimesOutAndReapsChild() throws {
    XCTAssertThrowsError(
      try FoundationProcessRunner().run(
        executable: "/bin/sleep",
        arguments: ["10"],
        environment: nil,
        options: .init(timeout: 0.05)
      )
    ) { error in
      guard case .timedOut(_, let arguments, _) = error as? ProcessRunnerError else {
        return XCTFail("unexpected error: \(error)")
      }
      XCTAssertEqual(arguments, ["10"])
    }
  }

  func testFoundationRunnerForwardsSignalsWithDefaultHandlers() throws {
    let result = try FoundationProcessRunner().run(
      executable: "/usr/bin/true",
      arguments: [],
      environment: nil,
      options: .init(forwardSignals: true)
    )

    XCTAssertEqual(result.exitCode, 0)
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
    XCTAssertEqual(
      report.systemDetail,
      "system is stopped\nRun 'container system start' to initialize the Apple Container system.")
  }

  func testDoctorKeepsJSONDiagnosticPrintedToStandardOutputOnFailure() throws {
    let runner = FakeRunner(results: [
      "--version": result(
        arguments: ["--version"], stdout: "container CLI version 1.2.2 (build: release)\n"),
      "system status --format json": result(
        arguments: ["system", "status", "--format", "json"],
        exitCode: 1,
        stdout: "{\"status\":\"unregistered\"}\n"
      ),
    ])

    let report = try ContainerCLI(executable: "/fake/container", runner: runner).doctor()

    XCTAssertTrue(report.systemDetail.contains("unregistered"))
    XCTAssertTrue(report.systemDetail.contains("container system start"))
  }

  func testListCallsReuseDetectedVersion() throws {
    let counter = CountingRunner(results: [
      "--version": result(
        arguments: ["--version"], stdout: "container CLI version 1.2.2 (build: release)\n"),
      "list --all --format json": result(
        arguments: ["list", "--all", "--format", "json"], stdout: "[]"),
      "network list --format json": result(
        arguments: ["network", "list", "--format", "json"], stdout: "[]"),
    ])
    let cli = ContainerCLI(executable: "/fake/container", runner: counter)

    _ = try cli.listContainers()
    _ = try cli.listNetworks()

    XCTAssertEqual(counter.invocationCount(for: ["--version"]), 1)
  }

  func testExecutableOverrideMustBeExecutable() throws {
    XCTAssertThrowsError(
      try ContainerExecutableResolver().resolve(environment: ["CONTAINER_CLI": "/does/not/exist"]))
    XCTAssertEqual(
      try ContainerExecutableResolver().resolve(environment: ["CONTAINER_CLI": "/usr/bin/true"]),
      "/usr/bin/true"
    )
  }

  func testRedactionNeverExposesSensitiveValuesOrUsesAnEmptyKey() {
    XCTAssertEqual(
      CommandRedaction.redact([
        "--env", "SECRET=value", "--password=plain", "--token", "=bare",
      ]),
      ["--env", "SECRET=<redacted>", "--password=<redacted>", "--token", "value=<redacted>"]
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

  func run(
    executable: String,
    arguments: [String],
    environment: [String: String]?,
    options: ProcessOptions
  ) throws
    -> ProcessResult
  {
    guard let result = results[arguments.joined(separator: " ")] else {
      throw ProcessRunnerError.couldNotLaunch(
        executable: executable, underlying: "unexpected arguments")
    }
    return result
  }
}

private final class CountingRunner: ProcessRunning {
  private let lock = NSLock()
  private let results: [String: ProcessResult]
  private var invocations: [[String]] = []

  init(results: [String: ProcessResult]) {
    self.results = results
  }

  func run(
    executable: String,
    arguments: [String],
    environment: [String: String]?,
    options: ProcessOptions
  ) throws
    -> ProcessResult
  {
    lock.withLock { invocations.append(arguments) }
    guard let result = results[arguments.joined(separator: " ")] else {
      throw ProcessRunnerError.couldNotLaunch(
        executable: executable, underlying: "unexpected arguments")
    }
    return result
  }

  func invocationCount(for arguments: [String]) -> Int {
    lock.withLock { invocations.filter { $0 == arguments }.count }
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
