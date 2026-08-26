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
- Apple Container executable discovery, version parsing, status diagnostics, and a
  versioned machine-readable compatibility matrix.
- Public JSON runtime discovery, canonical service hashing and ownership labels, and a
  pure dependency-aware reconciliation planner.
- Plugin metadata in `config.toml` and shared `compose` / `container-compose` entry
  points.

Lifecycle commands are not wired yet. Unsupported `include` and cross-file `extends`
fail explicitly instead of losing semantics.

Apple Container owns every runtime resource. This CLI invokes only the public
`container` executable with argument arrays; it has no daemon or secondary state
database.
