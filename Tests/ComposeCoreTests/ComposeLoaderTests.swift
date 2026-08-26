import ComposeCore
import Foundation
import XCTest

final class ComposeLoaderTests: XCTestCase {
  func testLoadsInterpolatesAndNormalizesProject() throws {
    try withTemporaryDirectory { directory in
      let compose = directory.appendingPathComponent("compose.yaml")
      try write(
        """
        name: Example.Project
        x-environment: &shared_environment
          FIRST: '${FIRST:-one}'
          SECOND: two
        services:
          app:
            image: alpine:3.22
            environment:
              <<: *shared_environment
              SECOND: overridden
            ports:
              - '8080:80'
            unknown_future_field: kept
          debug:
            image: alpine:3.22
            profiles: [debug]
        """,
        to: compose
      )

      let project = try ComposeLoader().load(
        options: .init(currentDirectory: directory.path, environment: [:]))

      XCTAssertEqual(project.name, "example-project")
      XCTAssertEqual(project.serviceNames, ["app"])
      XCTAssertEqual(project.declaredProfiles, ["debug"])
      XCTAssertEqual(project.model["services"]?["app"]?["environment"]?["FIRST"], .string("one"))
      XCTAssertEqual(
        project.model["services"]?["app"]?["environment"]?["SECOND"], .string("overridden"))
      XCTAssertEqual(project.model["services"]?["app"]?["unknown_future_field"], .string("kept"))
      XCTAssertNil(project.model["x-environment"])
      XCTAssertEqual(project.model["services"]?["app"]?["ports"]?.arrayValue?.count, 1)
    }
  }

  func testProfilesAndSameFileExtends() throws {
    try withTemporaryDirectory { directory in
      try write(
        """
        services:
          base:
            image: alpine:3.22
            environment:
              BASE: yes
          app:
            extends:
              service: base
            profiles: [app]
            environment:
              CHILD: yes
        """,
        to: directory.appendingPathComponent("compose.yml")
      )

      let project = try ComposeLoader().load(
        options: .init(profiles: ["app"], currentDirectory: directory.path, environment: [:]))
      XCTAssertEqual(project.serviceNames, ["app", "base"])
      XCTAssertEqual(project.model["services"]?["app"]?["image"], .string("alpine:3.22"))
      XCTAssertEqual(project.model["services"]?["app"]?["environment"]?["BASE"], .string("true"))
      XCTAssertEqual(project.model["services"]?["app"]?["environment"]?["CHILD"], .string("true"))
    }
  }

  func testProjectWithOnlyDisabledProfilesStillReportsProfiles() throws {
    try withTemporaryDirectory { directory in
      try write(
        """
        services:
          debug:
            image: alpine:3.22
            profiles: [debug]
        """,
        to: directory.appendingPathComponent("compose.yml")
      )

      let project = try ComposeLoader().load(
        options: .init(currentDirectory: directory.path, environment: [:]))
      XCTAssertEqual(project.serviceNames, [])
      XCTAssertEqual(project.declaredProfiles, ["debug"])
    }
  }

  func testMultipleFilesAndOverrideTag() throws {
    try withTemporaryDirectory { directory in
      let base = directory.appendingPathComponent("base.yml")
      let override = directory.appendingPathComponent("override.yml")
      try write(
        """
        services:
          app:
            image: alpine:3.22
            environment:
              FIRST: one
            ports: ['8000:80']
        """,
        to: base
      )
      try write(
        """
        services:
          app:
            environment:
              SECOND: two
            ports: !override ['9000:90']
        """,
        to: override
      )

      let project = try ComposeLoader().load(
        options: .init(
          files: [base.path, override.path], currentDirectory: directory.path, environment: [:]))
      let app = project.model["services"]?["app"]
      XCTAssertEqual(app?["environment"]?["FIRST"], .string("one"))
      XCTAssertEqual(app?["environment"]?["SECOND"], .string("two"))
      XCTAssertEqual(app?["ports"]?.arrayValue?.count, 1)
      XCTAssertEqual(app?["ports"]?.arrayValue?.first?["target"], .integer(90))
    }
  }

  func testDiscoverySearchesParents() throws {
    try withTemporaryDirectory { directory in
      try write(
        "services:\n  app:\n    image: alpine\n",
        to: directory.appendingPathComponent("compose.yaml"))
      let child = directory.appendingPathComponent("one/two", isDirectory: true)
      try FileManager.default.createDirectory(at: child, withIntermediateDirectories: true)

      let project = try ComposeLoader().load(
        options: .init(currentDirectory: child.path, environment: [:]))
      XCTAssertEqual(
        project.files.first?.path, directory.appendingPathComponent("compose.yaml").path)
    }
  }

  func testUnsupportedIncludeHasSourceLocation() throws {
    try withTemporaryDirectory { directory in
      let file = directory.appendingPathComponent("compose.yaml")
      try write("include: other.yml\nservices:\n  app:\n    image: alpine\n", to: file)

      XCTAssertThrowsError(
        try ComposeLoader().load(options: .init(currentDirectory: directory.path, environment: [:]))
      ) { error in
        let composeError = error as? ComposeError
        XCTAssertTrue(composeError?.message.contains("not supported yet") == true)
        XCTAssertEqual(composeError?.location?.file, file.path)
        XCTAssertEqual(composeError?.location?.line, 1)
      }
    }
  }
}

private func withTemporaryDirectory(_ body: (URL) throws -> Void) throws {
  let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
    "container-compose-tests-\(UUID().uuidString)", isDirectory: true)
  try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
  defer { try? FileManager.default.removeItem(at: directory) }
  try body(directory)
}

private func write(_ value: String, to url: URL) throws {
  try Data(value.utf8).write(to: url)
}
