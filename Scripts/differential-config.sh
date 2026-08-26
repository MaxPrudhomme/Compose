#!/usr/bin/env bash
set -euo pipefail

repository="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
compose_binary="${CONTAINER_COMPOSE:-${repository}/.build/release/container-compose}"

if [[ ! -x "${compose_binary}" ]]; then
  echo "missing executable: ${compose_binary}" >&2
  echo "build it with: swift build -c release" >&2
  exit 2
fi

command -v docker >/dev/null || { echo "docker CLI not found" >&2; exit 2; }
command -v jq >/dev/null || { echo "jq not found" >&2; exit 2; }

fixture="${repository}/Tests/Fixtures/differential/merge"
diff -u \
  <(docker compose --project-directory "${fixture}" config --format json | jq -S .) \
  <("${compose_binary}" --project-directory "${fixture}" config --format json | jq -S .)

environment_fixture="${repository}/Tests/Fixtures/differential/env-precedence"
diff -u \
  <(docker compose --project-directory "${environment_fixture}" config --format json | jq -S .) \
  <("${compose_binary}" --project-directory "${environment_fixture}" config --format json | jq -S .)

ironink="${repository}/Examples/ironink"
diff -u \
  <(docker compose --project-directory "${ironink}" config --format json | jq -S .) \
  <("${compose_binary}" --project-directory "${ironink}" config --format json | jq -S .)

echo "Docker Compose config parity passed for differential and Ironink fixtures (static config only; no containers started)."
