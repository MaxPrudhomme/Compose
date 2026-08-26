import ComposeCore
import Foundation
import XCTest

final class PlanningTests: XCTestCase {
  func testProjectLockRejectsConcurrentMutationAndCanBeReleased() throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
      "cc-lock-\(UUID().uuidString.prefix(8))", isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }

    let first = try ProjectLock.acquire(
      projectName: "example", command: "up", workingDirectory: "/project",
      lockDirectory: directory)
    XCTAssertThrowsError(
      try ProjectLock.acquire(
        projectName: "example", command: "down", workingDirectory: "/project",
        lockDirectory: directory)
    ) { error in
      let detail = String(describing: error)
      XCTAssertTrue(detail.contains("already being modified"))
      XCTAssertTrue(detail.contains("\"command\":\"up\""))
    }

    first.unlock()
    let second = try ProjectLock.acquire(
      projectName: "example", command: "down", workingDirectory: "/project",
      lockDirectory: directory)
    second.unlock()
  }

  func testCanonicalHashIgnoresMappingOrderAndDetectsChanges() throws {
    let first: JSONValue = .object([
      "image": .string("alpine:3.22"),
      "environment": .object(["A": .string("one"), "B": .string("two")]),
    ])
    let equivalent: JSONValue = .object([
      "environment": .object(["B": .string("two"), "A": .string("one")]),
      "image": .string("alpine:3.22"),
    ])
    let changed = equivalent.setting("image", to: .string("alpine:3.23"))

    XCTAssertEqual(
      try ServiceConfigHasher.hash(service: first),
      try ServiceConfigHasher.hash(service: equivalent))
    XCTAssertNotEqual(
      try ServiceConfigHasher.hash(service: first), try ServiceConfigHasher.hash(service: changed))
  }

  func testProjectHashIncludesReferencedNetworkAndVolumeDefinitions() throws {
    let service: JSONValue = .object([
      "image": .string("alpine"),
      "networks": .object(["backend": .null]),
      "volumes": .array([
        .object([
          "type": .string("volume"), "source": .string("data"),
          "target": .string("/data"),
        ])
      ]),
    ])
    let first = makeProject(
      services: ["app": service],
      networks: ["backend": .object(["name": .string("demo_backend")])],
      volumes: ["data": .object(["name": .string("demo_data")])]
    )
    let renamedNetwork = makeProject(
      services: ["app": service],
      networks: ["backend": .object(["name": .string("shared_backend")])],
      volumes: ["data": .object(["name": .string("demo_data")])]
    )
    let renamedVolume = makeProject(
      services: ["app": service],
      networks: ["backend": .object(["name": .string("demo_backend")])],
      volumes: ["data": .object(["name": .string("shared_data")])]
    )

    let firstHash = try ServiceConfigHasher.hash(project: first, serviceName: "app")
    XCTAssertNotEqual(
      firstHash, try ServiceConfigHasher.hash(project: renamedNetwork, serviceName: "app"))
    XCTAssertNotEqual(
      firstHash, try ServiceConfigHasher.hash(project: renamedVolume, serviceName: "app"))
  }

  func testExplicitImageRefreshRecreatesUnlessNoRecreateWasRequested() throws {
    let services = ["app": JSONValue.object(["image": .string("alpine")])]
    let project = makeProject(services: services)
    let current = try [
      matchingContainer(
        project: project, service: "app", specification: services["app"]!, state: .running)
    ]

    let refreshed = try ProjectPlanner().plan(
      project: project, currentContainers: current, refreshedServices: ["app"])
    XCTAssertTrue(refreshed.contains { if case .recreate = $0 { true } else { false } })

    let preserved = try ProjectPlanner().plan(
      project: project,
      currentContainers: current,
      refreshedServices: ["app"],
      options: .init(noRecreate: true)
    )
    XCTAssertTrue(preserved.contains { if case .noOp = $0 { true } else { false } })
  }

  func testPlannerCreatesInDependencyOrder() throws {
    let project = makeProject(services: [
      "web": .object(["image": .string("web"), "depends_on": .array([.string("db")])]),
      "db": .object(["image": .string("postgres")]),
    ])

    let actions = try ProjectPlanner().plan(project: project, currentContainers: [])

    XCTAssertEqual(actions.map(\.serviceName), ["db", "web"])
    XCTAssertTrue(actions.allSatisfy { if case .create = $0 { true } else { false } })
  }

  func testPlannerNoOpsStartsAndRecreatesNarrowly() throws {
    let services: [String: JSONValue] = [
      "running": .object(["image": .string("alpine:3.22")]),
      "stopped": .object(["image": .string("alpine:3.22")]),
      "drifted": .object(["image": .string("alpine:3.23")]),
    ]
    let project = makeProject(services: services)
    let current = try [
      matchingContainer(
        project: project, service: "running", specification: services["running"]!, state: .running),
      matchingContainer(
        project: project, service: "stopped", specification: services["stopped"]!, state: .stopped),
      matchingContainer(
        project: project, service: "drifted",
        specification: .object(["image": .string("alpine:old")]), state: .running),
    ]

    let actions = try ProjectPlanner().plan(project: project, currentContainers: current)

    XCTAssertTrue(
      actions.contains {
        if case .noOp(service: "running", containerID: _) = $0 { true } else { false }
      })
    XCTAssertTrue(
      actions.contains {
        if case .start(service: "stopped", containerID: _) = $0 { true } else { false }
      })
    XCTAssertTrue(
      actions.contains {
        if case .recreate(service: "drifted", containerID: _, hash: _, labels: _) = $0 {
          true
        } else {
          false
        }
      })
  }

  func testOrphansAreOptInAndDuplicateOwnershipIsRejected() throws {
    let project = makeProject(services: ["app": .object(["image": .string("alpine")])])
    let orphan = CurrentContainer(
      id: "orphan-id",
      state: .stopped,
      labels: [ComposeLabels.project: "demo", ComposeLabels.service: "removed"]
    )
    XCTAssertFalse(
      try ProjectPlanner().plan(project: project, currentContainers: [orphan]).contains {
        if case .removeOrphan = $0 { true } else { false }
      })
    XCTAssertTrue(
      try ProjectPlanner().plan(
        project: project,
        currentContainers: [orphan],
        options: .init(removeOrphans: true)
      ).contains {
        if case .removeOrphan(service: "removed", containerID: "orphan-id") = $0 {
          true
        } else {
          false
        }
      })

    let duplicateLabels = [ComposeLabels.project: "demo", ComposeLabels.service: "app"]
    let duplicates = [
      CurrentContainer(id: "one", state: .running, labels: duplicateLabels),
      CurrentContainer(id: "two", state: .running, labels: duplicateLabels),
    ]
    XCTAssertThrowsError(try ProjectPlanner().plan(project: project, currentContainers: duplicates))
  }

  func testDependencyCyclesFailBeforeActionsAreReturned() {
    let project = makeProject(services: [
      "one": .object(["depends_on": .array([.string("two")])]),
      "two": .object(["depends_on": .array([.string("one")])]),
    ])
    XCTAssertThrowsError(try ProjectPlanner().plan(project: project, currentContainers: []))
  }
}

extension ReconciliationAction {
  fileprivate var serviceName: String {
    switch self {
    case .create(let service, _, _), .start(let service, _), .recreate(let service, _, _, _),
      .noOp(let service, _), .removeOrphan(let service, _):
      return service
    }
  }
}

private func makeProject(
  services: [String: JSONValue],
  networks: [String: JSONValue] = [:],
  volumes: [String: JSONValue] = [:]
) -> ComposeProject {
  var model: [String: JSONValue] = ["name": .string("demo"), "services": .object(services)]
  if !networks.isEmpty { model["networks"] = .object(networks) }
  if !volumes.isEmpty { model["volumes"] = .object(volumes) }
  return ComposeProject(
    name: "demo",
    workingDirectory: URL(fileURLWithPath: "/tmp/demo"),
    files: [URL(fileURLWithPath: "/tmp/demo/compose.yaml")],
    model: .object(model),
    interpolationEnvironment: [:],
    declaredProfiles: []
  )
}

private func matchingContainer(
  project: ComposeProject,
  service: String,
  specification: JSONValue,
  state: CurrentContainer.State
) throws -> CurrentContainer {
  let historicalProject = makeProject(services: [service: specification])
  let hash = try ServiceConfigHasher.hash(project: historicalProject, serviceName: service)
  return CurrentContainer(
    id: "\(service)-id",
    state: state,
    labels: ComposeLabels.container(
      projectName: project.name,
      serviceName: service,
      workingDirectory: project.workingDirectory,
      files: project.files,
      hash: hash
    )
  )
}
