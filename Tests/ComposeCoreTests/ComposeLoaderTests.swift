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
            x-service-note: removed
            environment:
              <<: *shared_environment
              SECOND: overridden
              x-flag: kept
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

      XCTAssertEqual(project.name, "exampleproject")
      XCTAssertEqual(project.serviceNames, ["app"])
      XCTAssertEqual(project.declaredProfiles, ["debug"])
      XCTAssertEqual(project.model["services"]?["app"]?["environment"]?["FIRST"], .string("one"))
      XCTAssertEqual(
        project.model["services"]?["app"]?["environment"]?["SECOND"], .string("overridden"))
      XCTAssertEqual(
        project.model["services"]?["app"]?["environment"]?["x-flag"], .string("kept"))
      XCTAssertNil(project.model["services"]?["app"]?["x-service-note"])
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
      XCTAssertEqual(project.model["services"]?["app"]?["environment"]?["BASE"], .string("yes"))
      XCTAssertEqual(project.model["services"]?["app"]?["environment"]?["CHILD"], .string("yes"))
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

  func testEmptyComposeFileListIsRejectedBeforeLoading() throws {
    try withTemporaryDirectory { directory in
      XCTAssertThrowsError(
        try ComposeFileDiscovery.discover(
          options: .init(currentDirectory: directory.path, environment: [:]),
          environment: ["COMPOSE_FILE": ":"])
      ) { error in
        XCTAssertTrue(String(describing: error).contains("does not contain a Compose file path"))
      }
    }
  }

  func testProjectDirectoryDotEnvCanSelectAComposeFile() throws {
    try withTemporaryDirectory { directory in
      let caller = directory.appendingPathComponent("caller", isDirectory: true)
      let projectDirectory = directory.appendingPathComponent("project", isDirectory: true)
      try FileManager.default.createDirectory(at: caller, withIntermediateDirectories: true)
      try FileManager.default.createDirectory(
        at: projectDirectory, withIntermediateDirectories: true)
      try write("COMPOSE_FILE=selected.yaml\n", to: projectDirectory.appendingPathComponent(".env"))
      let selected = projectDirectory.appendingPathComponent("selected.yaml")
      try write("services:\n  app:\n    image: alpine\n", to: selected)

      let project = try ComposeLoader().load(
        options: .init(
          projectDirectory: projectDirectory.path,
          currentDirectory: caller.path,
          environment: [:]
        ))

      XCTAssertEqual(project.files, [selected])
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

  func testUsesComposeBooleanRulesAndResolvedEnvironmentForPassthrough() throws {
    try withTemporaryDirectory { directory in
      try write("PASSTHROUGH=from-dotenv\n", to: directory.appendingPathComponent(".env"))
      try write(
        """
        services:
          app:
            image: alpine
            environment:
              YES: yes
              NO: no
              ON: on
              OFF: off
              TRUE: true
              FALSE: false
              PASSTHROUGH:
              MISSING:
        """,
        to: directory.appendingPathComponent("compose.yaml")
      )

      let project = try ComposeLoader().load(
        options: .init(currentDirectory: directory.path, environment: [:]))
      let environment = project.model["services"]?["app"]?["environment"]

      XCTAssertEqual(environment?["YES"], .string("yes"))
      XCTAssertEqual(environment?["NO"], .string("no"))
      XCTAssertEqual(environment?["ON"], .string("on"))
      XCTAssertEqual(environment?["OFF"], .string("off"))
      XCTAssertEqual(environment?["TRUE"], .string("true"))
      XCTAssertEqual(environment?["FALSE"], .string("false"))
      XCTAssertEqual(environment?["PASSTHROUGH"], .string("from-dotenv"))
      XCTAssertEqual(environment?["MISSING"], .null)
    }
  }

  func testEnvironmentFileStripsOnlyUnquotedTrailingComments() throws {
    try withTemporaryDirectory { directory in
      let file = directory.appendingPathComponent("values.env")
      try write(
        "DOUBLE=\"two words\" # comment\nSINGLE='one # value' # comment\nPLAIN=value # comment\nHASH=value#literal\n",
        to: file)

      let environment = try EnvironmentFile.load(url: file)

      XCTAssertEqual(environment["DOUBLE"], "two words")
      XCTAssertEqual(environment["SINGLE"], "one # value")
      XCTAssertEqual(environment["PLAIN"], "value")
      XCTAssertEqual(environment["HASH"], "value#literal")
    }
  }

  func testDotEnvCanInterpolateProcessAndEarlierFileValues() throws {
    try withTemporaryDirectory { directory in
      try write(
        "BASE=${HOST_VALUE}\nCHAIN=${BASE}-two\n",
        to: directory.appendingPathComponent(".env"))
      try write(
        "services:\n  app:\n    image: alpine\n    environment:\n      VALUE: ${CHAIN}\n",
        to: directory.appendingPathComponent("compose.yaml"))

      let project = try ComposeLoader().load(
        options: .init(
          currentDirectory: directory.path,
          environment: ["HOST_VALUE": "one"]
        ))

      XCTAssertEqual(
        project.model["services"]?["app"]?["environment"]?["VALUE"], .string("one-two"))
    }
  }

  func testDiscoversAndMergesDefaultOverrideFile() throws {
    try withTemporaryDirectory { directory in
      try write(
        """
        services:
          app:
            image: alpine
            environment:
              BASE: one
              OVERRIDDEN: base
        """,
        to: directory.appendingPathComponent("compose.yaml")
      )
      let override = directory.appendingPathComponent("compose.override.yaml")
      try write(
        """
        services:
          app:
            environment:
              OVERRIDDEN: override
        """,
        to: override
      )

      let project = try ComposeLoader().load(
        options: .init(currentDirectory: directory.path, environment: [:]))

      XCTAssertEqual(project.files.count, 2)
      XCTAssertEqual(project.files.last?.path, override.path)
      XCTAssertEqual(project.model["services"]?["app"]?["environment"]?["BASE"], .string("one"))
      XCTAssertEqual(
        project.model["services"]?["app"]?["environment"]?["OVERRIDDEN"],
        .string("override")
      )
    }
  }

  func testMergeNormalizesListAndMappingSyntaxBeforeMerging() throws {
    try withTemporaryDirectory { directory in
      let base = directory.appendingPathComponent("base.yaml")
      let override = directory.appendingPathComponent("override.yaml")
      try write(
        """
        services:
          app:
            image: alpine
            environment:
              - FROM_BASE=1
            depends_on: [db]
          db:
            image: alpine
        """,
        to: base
      )
      try write(
        """
        services:
          app:
            environment:
              FROM_OVERRIDE: "2"
            depends_on:
              db:
                condition: service_started
        """,
        to: override
      )

      let project = try ComposeLoader().load(
        options: .init(
          files: [base.path, override.path], currentDirectory: directory.path, environment: [:]))
      let app = project.model["services"]?["app"]

      XCTAssertEqual(app?["environment"]?["FROM_BASE"], .string("1"))
      XCTAssertEqual(app?["environment"]?["FROM_OVERRIDE"], .string("2"))
      XCTAssertEqual(app?["depends_on"]?["db"]?["condition"], .string("service_started"))
      XCTAssertEqual(app?["depends_on"]?["db"]?["required"], .bool(true))
    }
  }

  func testResetRemovesMergedValue() throws {
    try withTemporaryDirectory { directory in
      let base = directory.appendingPathComponent("base.yaml")
      let override = directory.appendingPathComponent("override.yaml")
      try write(
        """
        services:
          app:
            image: alpine
            environment:
              KEEP: yes
              REMOVE: me
        """,
        to: base
      )
      try write(
        """
        services:
          app:
            environment: !reset null
        """,
        to: override
      )

      let project = try ComposeLoader().load(
        options: .init(
          files: [base.path, override.path], currentDirectory: directory.path, environment: [:]))

      XCTAssertNil(project.model["services"]?["app"]?["environment"])
    }
  }

  func testResetInFirstFileRemovesTheField() throws {
    try withTemporaryDirectory { directory in
      try write(
        "services:\n  app:\n    image: alpine\n    environment: !reset null\n",
        to: directory.appendingPathComponent("compose.yaml"))

      let project = try ComposeLoader().load(
        options: .init(currentDirectory: directory.path, environment: [:]))

      XCTAssertNil(project.model["services"]?["app"]?["environment"])
    }
  }

  func testNormalizesPortRangesIPv6VolumesAndDependencies() throws {
    try withTemporaryDirectory { directory in
      try write(
        """
        services:
          app:
            image: alpine
            ports:
              - "8000-8002:8000-8002"
              - "[::1]:8080:80"
              - target: 81
                published: 8081
            volumes:
              - "./src:/app/src:ro"
              - "data:/data"
              - "/anonymous"
            depends_on: [db]
          db:
            image: alpine
        volumes:
          data:
        """,
        to: directory.appendingPathComponent("compose.yaml")
      )

      let project = try ComposeLoader().load(
        options: .init(currentDirectory: directory.path, environment: [:]))
      let app = project.model["services"]?["app"]
      let ports = app?["ports"]?.arrayValue
      let volumes = app?["volumes"]?.arrayValue

      XCTAssertEqual(ports?.count, 5)
      XCTAssertEqual(ports?[1]["published"], .string("8001"))
      XCTAssertEqual(ports?[3]["host_ip"], .string("::1"))
      XCTAssertEqual(ports?[3]["target"], .integer(80))
      XCTAssertEqual(ports?[4]["published"], .string("8081"))
      XCTAssertEqual(ports?[4]["target"], .integer(81))
      XCTAssertEqual(volumes?[0]["type"], .string("bind"))
      XCTAssertEqual(
        volumes?[0]["source"],
        .string(directory.appendingPathComponent("src").standardizedFileURL.path)
      )
      XCTAssertEqual(volumes?[0]["read_only"], .bool(true))
      XCTAssertEqual(volumes?[1]["type"], .string("volume"))
      XCTAssertEqual(volumes?[2]["target"], .string("/anonymous"))
      XCTAssertEqual(app?["depends_on"]?["db"]?["required"], .bool(true))
    }
  }

  func testProjectNameDeletesInvalidCharactersAndRejectsLongGeneratedNames() throws {
    try withTemporaryDirectory { directory in
      try write(
        "name: name.with.dots\nservices:\n  app:\n    image: alpine\n",
        to: directory.appendingPathComponent("compose.yaml"))

      let project = try ComposeLoader().load(
        options: .init(currentDirectory: directory.path, environment: [:]))
      XCTAssertEqual(project.name, "namewithdots")

      XCTAssertThrowsError(
        try ComposeLoader().load(
          options: .init(
            projectName: "é",
            currentDirectory: directory.path,
            environment: [:]
          )))

      XCTAssertThrowsError(
        try ComposeLoader().load(
          options: .init(
            projectName: String(repeating: "a", count: 56),
            currentDirectory: directory.path,
            environment: [:]
          ))
      ) { error in
        XCTAssertTrue(String(describing: error).contains("63-byte limit"))
      }
    }
  }

  func testBinaryMemorySuffixesUseComposeMultipliers() throws {
    try withTemporaryDirectory { directory in
      try write(
        "services:\n  app:\n    image: alpine\n    mem_limit: 1mb\n",
        to: directory.appendingPathComponent("compose.yaml"))

      let project = try ComposeLoader().load(
        options: .init(currentDirectory: directory.path, environment: [:]))

      XCTAssertEqual(project.model["services"]?["app"]?["mem_limit"], .string("1048576"))
    }
  }

  func testCollectionSourceLocationSurvivesInterpolation() throws {
    try withTemporaryDirectory { directory in
      let file = directory.appendingPathComponent("compose.yaml")
      try write(
        "services:\n  app:\n    image: alpine\n    profiles: [1, '${PROFILE:-2}']\n",
        to: file)

      XCTAssertThrowsError(
        try ComposeLoader().load(
          options: .init(currentDirectory: directory.path, environment: [:]))
      ) { error in
        let composeError = error as? ComposeError
        XCTAssertEqual(composeError?.location?.file, file.path)
        XCTAssertEqual(composeError?.location?.line, 4)
      }
    }
  }

  func testCompatibilityRejectsAmbiguousCommandsAndAnonymousVolumes() throws {
    try withTemporaryDirectory { directory in
      try write(
        """
        services:
          app:
            image: alpine
            command: [echo, 1]
            entrypoint: /bin/sh -c
            volumes: [/cache]
        """,
        to: directory.appendingPathComponent("compose.yaml"))

      let project = try ComposeLoader().load(
        options: .init(currentDirectory: directory.path, environment: [:]))
      let fields = ComposeCompatibility.issues(in: project).map(\.field)

      XCTAssertTrue(fields.contains("command"))
      XCTAssertTrue(fields.contains("entrypoint"))
      XCTAssertTrue(fields.contains("volumes"))
      XCTAssertThrowsError(try ComposeCompatibility.validateForExecution(project))
    }
  }

  func testProfileDisabledRequiredDependencyFailsDuringLoad() throws {
    try withTemporaryDirectory { directory in
      try write(
        """
        services:
          app:
            image: alpine
            depends_on: [debug]
          debug:
            image: alpine
            profiles: [debug]
        """,
        to: directory.appendingPathComponent("compose.yaml")
      )

      XCTAssertThrowsError(
        try ComposeLoader().load(options: .init(currentDirectory: directory.path, environment: [:]))
      ) { error in
        XCTAssertTrue(String(describing: error).contains("disabled by profiles"))
      }
    }
  }

  func testExplicitSymlinkPathIsNotCanonicalized() throws {
    try withTemporaryDirectory { directory in
      let actual = directory.appendingPathComponent("actual", isDirectory: true)
      let link = directory.appendingPathComponent("link", isDirectory: true)
      try FileManager.default.createDirectory(at: actual, withIntermediateDirectories: true)
      try FileManager.default.createSymbolicLink(at: link, withDestinationURL: actual)
      try write(
        "services:\n  app:\n    build: .\n",
        to: actual.appendingPathComponent("compose.yaml")
      )

      let project = try ComposeLoader().load(
        options: .init(files: [link.appendingPathComponent("compose.yaml").path], environment: [:]))

      XCTAssertEqual(project.workingDirectory.path, link.path)
      XCTAssertEqual(project.model["services"]?["app"]?["build"]?["context"], .string(link.path))
    }
  }

  func testCompatibilityPolicyReportsCorrectnessAffectingFields() throws {
    try withTemporaryDirectory { directory in
      try write(
        """
        services:
          app:
            image: alpine
            restart: always
            privileged: true
            network_mode: host
            devices: [/dev/null:/dev/null]
            deploy:
              replicas: 3
            cap_add: [SYS_ADMIN]
        """,
        to: directory.appendingPathComponent("compose.yaml")
      )

      let project = try ComposeLoader().load(
        options: .init(currentDirectory: directory.path, environment: [:]))
      let fields = Set(ComposeCompatibility.issues(in: project).map(\.field))

      XCTAssertTrue(
        fields.isSuperset(of: [
          "restart", "privileged", "network_mode", "devices", "deploy.replicas",
        ]))
      XCTAssertFalse(fields.contains("cap_add"), "cap_add maps directly to container create")
      XCTAssertThrowsError(try ComposeCompatibility.validateForExecution(project))
    }
  }

  func testUndefinedNetworksAndVolumesFailDuringConfigLoad() throws {
    try withTemporaryDirectory { directory in
      try write(
        """
        services:
          app:
            image: alpine
            networks: [missing]
            volumes: [missing:/data]
        """,
        to: directory.appendingPathComponent("compose.yaml"))

      XCTAssertThrowsError(
        try ComposeLoader().load(
          options: .init(currentDirectory: directory.path, environment: [:]))
      ) { error in
        XCTAssertTrue(String(describing: error).contains("undefined network 'missing'"))
      }
    }
  }

  func testPublishedCompatibilityMatrixIsBundledAndDecodable() throws {
    let matrix = try ComposeCompatibility.publishedMatrix()
    XCTAssertEqual(matrix.baseline.dockerComposeOracle, "5.4.0")
    XCTAssertEqual(matrix.features["restartPolicies"], .rejected)
    XCTAssertEqual(matrix.features["capabilities"], .native)
    XCTAssertEqual(matrix.features["networks"], .native)
    XCTAssertEqual(matrix.features["namedVolumes"], .native)
  }

  func testExecutionRejectsFractionalCPUsAndMissingServiceNameDNS() throws {
    try withTemporaryDirectory { directory in
      try write(
        """
        services:
          app:
            image: alpine
            cpus: 0.5
          db:
            image: postgres
        """,
        to: directory.appendingPathComponent("compose.yaml"))

      let project = try ComposeLoader().load(
        options: .init(currentDirectory: directory.path, environment: [:]))
      let fields = Set(ComposeCompatibility.issues(in: project).map(\.field))

      XCTAssertTrue(fields.contains("cpus"))
      XCTAssertTrue(fields.contains("serviceNameDNS"))
      XCTAssertThrowsError(try ComposeCompatibility.validateForExecution(project))
    }
  }
}

private func withTemporaryDirectory(_ body: (URL) throws -> Void) throws {
  let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
    "cc-\(UUID().uuidString.prefix(8))", isDirectory: true)
  try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
  defer { try? FileManager.default.removeItem(at: directory) }
  try body(directory)
}

private func write(_ value: String, to url: URL) throws {
  try Data(value.utf8).write(to: url)
}
