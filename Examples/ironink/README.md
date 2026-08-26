# Ironink example

This fixture expects a local `puncto-ironink:dev` image. It intentionally exercises only
the Compose fields currently mapped to Apple Container. Unsupported health-check and
restart-policy declarations are covered by compatibility diagnostics instead of being
silently ignored.
