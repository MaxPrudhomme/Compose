# container-compose

An independent Compose-compatible CLI for Apple's `container` runtime.

The project is early. Its current executable foundation provides the same command
implementation through two products:

```console
swift run compose version
swift run container-compose version
swift run container-compose -f compose.yaml config --format json
swift run container-compose doctor
```

Implemented so far:

- Compose file discovery, `.env` loading, variable interpolation, anchors, aliases,
  YAML merge keys, multi-file merging, profiles, and same-file `extends`.
- Normalized YAML/JSON config output and service/profile/environment queries.
- Apple Container executable discovery, version parsing, status diagnostics, a
  versioned [machine-readable compatibility matrix](Sources/ComposeCore/Resources/compose-compatibility.json),
  and fail-closed runtime validation for semantics Apple Container cannot preserve.
- Public JSON runtime discovery, canonical service hashing and ownership labels, and a
  pure dependency-aware reconciliation planner.
- Plugin metadata in `config.toml` and shared `compose` / `container-compose` entry
  points.

The first detached lifecycle slice is available through `up -d`, `create`, `start`,
`stop`, `restart`, `down`, and `ps`. It delegates builds and resource operations to the
native Apple CLI, uses ownership labels for discovery, locks project mutations, and
rejects fields whose semantics cannot yet be preserved. Unsupported `include` and
cross-file `extends` also fail explicitly.

Apple Container 1.2 does not provide Compose-style service-name discovery, so lifecycle
commands currently reject multi-service projects instead of starting a stack whose
services cannot reach each other by name.

Apple Container owns every runtime resource. This CLI invokes only the public
`container` executable with argument arrays; it has no daemon or secondary state
database.

## Development

Apple Container requires macOS 26 and the matching Xcode toolchain. If Command Line
Tools is selected globally, run SwiftPM with the repository's Xcode explicitly:

```console
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift build -c release
```

The static differential harness compares normalized configuration only; it never
starts or builds Docker containers:

```console
Scripts/differential-config.sh
```

Lifecycle `--dry-run` performs read-only runtime discovery so its plan reflects
existing containers, networks, and volumes. It does not invoke mutating native commands.
