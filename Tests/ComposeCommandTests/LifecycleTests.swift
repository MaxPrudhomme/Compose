import AppleContainerDriver
import ComposeCommands
import ComposeCore
import Foundation
import XCTest

final class LifecycleTests: XCTestCase {
  func testDryRunPlansNativeCreateWithoutMutatingRuntime() throws {
    try withProject(
      """
      services:
        app:
          image: alpine:3.22
          environment:
            SECRET: do-not-print
          ports: ['8080:80']
      """
    ) { project in
      let runner = RecordingRunner(results: inventoryResults())
      let lifecycle = ComposeLifecycle(
        cli: ContainerCLI(executable: "/fake/container", runner: runner))

      let events = try lifecycle.up(
        project: project,
        options: .init(dryRun: true)
      )

      XCTAssertEqual(events.map(\.action), ["create-network", "create", "start"])
      XCTAssertTrue(events.flatMap { $0.arguments ?? [] }.contains("SECRET=<redacted>"))
      XCTAssertFalse(events.flatMap { $0.arguments ?? [] }.contains("SECRET=do-not-print"))
      XCTAssertEqual(
        runner.invocations.map(\.arguments),
        [
          ["--version"],
          ["network", "list", "--format", "json"],
          ["volume", "list", "--format", "json"],
          ["list", "--all", "--format", "json"],
        ]
      )
    }
  }

  func testUnchangedUpIsNoOp() throws {
    try withProject("services:\n  app:\n    image: alpine:3.22\n") { project in
      let hash = try ServiceConfigHasher.hash(project: project, serviceName: "app")
      let labels = ComposeLabels.container(
        projectName: project.name,
        serviceName: "app",
        workingDirectory: project.workingDirectory,
        files: project.files,
        hash: hash
      )
      let runner = RecordingRunner(
        results: inventoryResults(
          containers: [runtimeContainer(id: "existing", state: "running", labels: labels)],
          networks: [runtimeNetwork(name: "\(project.name)_default", project: project.name)]
        ))
      let lifecycle = ComposeLifecycle(
        cli: ContainerCLI(executable: "/fake/container", runner: runner))

      let events = try lifecycle.up(project: project)

      XCTAssertEqual(events, [.init(action: "no-op", service: "app")])
      XCTAssertFalse(runner.invocations.contains { $0.arguments.first == "create" })
    }
  }

  func testChangedServiceRecreatesAfterPrerequisites() throws {
    try withProject("services:\n  app:\n    image: alpine:3.22\n") { project in
      let labels = ComposeLabels.container(
        projectName: project.name,
        serviceName: "app",
        workingDirectory: project.workingDirectory,
        files: project.files,
        hash: "old"
      )
      let runner = RecordingRunner(
        results: inventoryResults(
          containers: [runtimeContainer(id: "existing", state: "running", labels: labels)],
          networks: [runtimeNetwork(name: "\(project.name)_default", project: project.name)]
        ))
      let lifecycle = ComposeLifecycle(
        cli: ContainerCLI(executable: "/fake/container", runner: runner))

      let events = try lifecycle.up(project: project)

      XCTAssertEqual(events.map(\.action), ["stop", "delete", "create", "start"])
      let mutationArguments = runner.invocations.map(\.arguments).filter {
        !["--version", "network", "volume", "list"].contains($0.first ?? "")
      }
      XCTAssertEqual(mutationArguments[0], ["stop", "existing"])
      XCTAssertEqual(mutationArguments[1], ["delete", "existing"])
      XCTAssertEqual(mutationArguments.last, ["start", "\(project.name)-app-1"])
    }
  }

  func testStoppedChangedServiceIsDeletedWithoutAStopAttempt() throws {
    try withProject("services:\n  app:\n    image: alpine:3.22\n") { project in
      let labels = ComposeLabels.container(
        projectName: project.name,
        serviceName: "app",
        workingDirectory: project.workingDirectory,
        files: project.files,
        hash: "old"
      )
      let runner = RecordingRunner(
        results: inventoryResults(
          containers: [runtimeContainer(id: "existing", state: "stopped", labels: labels)],
          networks: [runtimeNetwork(name: "\(project.name)_default", project: project.name)]
        ))
      let lifecycle = ComposeLifecycle(
        cli: ContainerCLI(executable: "/fake/container", runner: runner))

      let events = try lifecycle.up(project: project)

      XCTAssertEqual(events.map(\.action), ["delete", "create", "start"])
      XCTAssertFalse(runner.invocations.contains { $0.arguments.first == "stop" })
    }
  }

  func testPullAlwaysRefreshesAnExistingService() throws {
    try withProject("services:\n  app:\n    image: alpine:3.22\n") { project in
      let hash = try ServiceConfigHasher.hash(project: project, serviceName: "app")
      let labels = ComposeLabels.container(
        projectName: project.name,
        serviceName: "app",
        workingDirectory: project.workingDirectory,
        files: project.files,
        hash: hash
      )
      let runner = RecordingRunner(
        results: inventoryResults(
          containers: [runtimeContainer(id: "existing", state: "running", labels: labels)],
          networks: [runtimeNetwork(name: "\(project.name)_default", project: project.name)]
        ))
      let lifecycle = ComposeLifecycle(
        cli: ContainerCLI(executable: "/fake/container", runner: runner))

      let events = try lifecycle.up(project: project, options: .init(pull: "always"))

      XCTAssertEqual(events.map(\.action), ["pull", "stop", "delete", "create", "start"])
    }
  }

  func testDownPreservesVolumesByDefault() throws {
    try withProject("services:\n  app:\n    image: alpine:3.22\n") { project in
      let labels = ComposeLabels.container(
        projectName: project.name,
        serviceName: "app",
        workingDirectory: project.workingDirectory,
        files: project.files,
        hash: "hash"
      )
      let runner = RecordingRunner(
        results: inventoryResults(
          containers: [runtimeContainer(id: "existing", state: "running", labels: labels)],
          networks: [runtimeNetwork(name: "\(project.name)_default", project: project.name)],
          volumes: [runtimeVolume(name: "\(project.name)_data", project: project.name)]
        ))
      let lifecycle = ComposeLifecycle(
        cli: ContainerCLI(executable: "/fake/container", runner: runner))

      let events = try lifecycle.down(
        project: project, removeVolumes: false, timeout: 7, dryRun: false)

      XCTAssertEqual(events.map(\.action), ["stop", "delete", "delete-network"])
      XCTAssertFalse(
        runner.invocations.contains { $0.arguments.prefix(2) == ["volume", "delete"] })
    }
  }

  func testUserStopTimeoutExtendsTheProcessDeadline() throws {
    try withProject("services:\n  app:\n    image: alpine:3.22\n") { project in
      let labels = ComposeLabels.container(
        projectName: project.name,
        serviceName: "app",
        workingDirectory: project.workingDirectory,
        files: project.files,
        hash: "hash"
      )
      let runner = RecordingRunner(
        results: inventoryResults(
          containers: [runtimeContainer(id: "existing", state: "running", labels: labels)]))
      let lifecycle = ComposeLifecycle(
        cli: ContainerCLI(executable: "/fake/container", runner: runner))

      _ = try lifecycle.operate("stop", project: project, timeout: 300)

      let invocation = try XCTUnwrap(
        runner.invocations.first { $0.arguments.first == "stop" })
      XCTAssertEqual(invocation.arguments, ["stop", "--time", "300", "existing"])
      XCTAssertEqual(invocation.options.timeout, 310)
    }
  }

  func testStandaloneBootstrapUsesHeadlessSystemStart() throws {
    let runner = RecordingRunner(results: [
      key(["--version"]): result(
        ["--version"], stdout: "container CLI version 1.2.2 (build: release)\n"),
      key(["system", "status", "--format", "json"]): result(
        ["system", "status", "--format", "json"],
        exitCode: 1,
        stdout: "{\"status\":\"unregistered\"}\n"),
    ])
    let lifecycle = ComposeLifecycle(
      cli: ContainerCLI(executable: "/fake/container", runner: runner))

    let events = try lifecycle.ensureSystem(bootstrapIfNeeded: true, dryRun: false)

    XCTAssertEqual(events.map(\.arguments), [["system", "start", "--enable-kernel-install"]])
    XCTAssertTrue(
      runner.invocations.contains {
        $0.arguments == ["system", "start", "--enable-kernel-install"]
          && $0.options.standardIO == .inherited
          && $0.options.forwardSignals
      })
  }

  func testComposeTranslationUsesNativeCreateFlags() throws {
    try withProject(
      """
      services:
        app:
          image: example/app:latest
          platform: linux/amd64
          cpus: 2
          mem_limit: 1g
          environment:
            TOKEN: literal
          ports:
            - target: 80
              published: 8080
              host_ip: 127.0.0.1
          cap_add: [SYS_ADMIN]
          read_only: true
          init: true
      """
    ) { project in
      let arguments = try ComposeToContainer.createArguments(
        project: project,
        serviceName: "app",
        labels: [ComposeLabels.project: project.name]
      )

      XCTAssertEqual(arguments.prefix(3), ["create", "--name", "\(project.name)-app-1"])
      XCTAssertTrue(arguments.containsSubsequence(["--env", "TOKEN=literal"]))
      XCTAssertTrue(arguments.containsSubsequence(["--publish", "127.0.0.1:8080:80/tcp"]))
      XCTAssertTrue(arguments.containsSubsequence(["--platform", "linux/amd64"]))
      XCTAssertTrue(arguments.contains("--rosetta"))
      XCTAssertTrue(arguments.containsSubsequence(["--cap-add", "SYS_ADMIN"]))
      XCTAssertTrue(arguments.contains("--read-only"))
      XCTAssertTrue(arguments.contains("--init"))
      XCTAssertEqual(arguments.last, "example/app:latest")
    }
  }
}

private final class RecordingRunner: ProcessRunning {
  struct Invocation {
    let arguments: [String]
    let options: ProcessOptions
  }

  private let lock = NSLock()
  private let results: [String: ProcessResult]
  private(set) var invocations: [Invocation] = []

  init(results: [String: ProcessResult]) {
    self.results = results
  }

  func run(
    executable: String,
    arguments: [String],
    environment: [String: String]?,
    options: ProcessOptions
  ) throws -> ProcessResult {
    lock.withLock { invocations.append(.init(arguments: arguments, options: options)) }
    return results[key(arguments)] ?? result(arguments)
  }
}

private func inventoryResults(
  containers: [String] = [],
  networks: [String] = [],
  volumes: [String] = []
) -> [String: ProcessResult] {
  [
    key(["--version"]): result(
      ["--version"], stdout: "container CLI version 1.2.2 (build: release)\n"),
    key(["list", "--all", "--format", "json"]): result(
      ["list", "--all", "--format", "json"], stdout: "[\(containers.joined(separator: ","))]"),
    key(["network", "list", "--format", "json"]): result(
      ["network", "list", "--format", "json"], stdout: "[\(networks.joined(separator: ","))]"),
    key(["volume", "list", "--format", "json"]): result(
      ["volume", "list", "--format", "json"], stdout: "[\(volumes.joined(separator: ","))]"),
  ]
}

private func runtimeContainer(id: String, state: String, labels: [String: String]) -> String {
  let labelsData = try! JSONEncoder.compose(prettyPrinted: false).encode(labels)
  let labelsJSON = String(decoding: labelsData, as: UTF8.self)
  return
    "{\"id\":\"\(id)\",\"configuration\":{\"id\":\"\(id)\",\"labels\":\(labelsJSON)},\"status\":{\"state\":\"\(state)\"}}"
}

private func runtimeNetwork(name: String, project: String) -> String {
  "{\"id\":\"\(name)\",\"configuration\":{\"name\":\"\(name)\",\"labels\":{\"\(ComposeLabels.project)\":\"\(project)\"}}}"
}

private func runtimeVolume(name: String, project: String) -> String {
  "{\"id\":\"\(name)\",\"configuration\":{\"name\":\"\(name)\",\"labels\":{\"\(ComposeLabels.project)\":\"\(project)\"}}}"
}

private func result(
  _ arguments: [String],
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

private func key(_ arguments: [String]) -> String {
  arguments.joined(separator: "\u{0}")
}

private func withProject(_ yaml: String, body: (ComposeProject) throws -> Void) throws {
  let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
    "cc-lifecycle-\(UUID().uuidString.prefix(8))", isDirectory: true)
  try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
  defer { try? FileManager.default.removeItem(at: directory) }
  try Data(yaml.utf8).write(to: directory.appendingPathComponent("compose.yaml"))
  let project = try ComposeLoader().load(
    options: .init(currentDirectory: directory.path, environment: [:]))
  try body(project)
}

extension Array where Element == String {
  fileprivate func containsSubsequence(_ subsequence: [String]) -> Bool {
    guard subsequence.count <= count else { return false }
    return indices.contains { index in
      let end = index + subsequence.count
      return end <= count && Array(self[index..<end]) == subsequence
    }
  }
}
