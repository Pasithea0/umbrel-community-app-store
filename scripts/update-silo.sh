#!/usr/bin/env bash
#
# Repin the Silo Umbrel package to the newest silo-server main commit.
#
# Upstream publishes no GitHub releases, so there is no version to bump against.
# Instead this follows main: it resolves the head commit, checks that GHCR has
# actually published an image for that exact commit, and repins the package when
# the digest moves. It also refreshes the digests of the bundled PostgreSQL and
# Redis images, whose versioned tags are rebuilt upstream over time.
#
# Exit codes:
#   0  nothing to do, or the package was updated
#   1  a real failure (missing tooling, unexpected API response)
#
# The script never commits. The calling workflow does that.
#
# Requires: curl, jq, and either crane or `docker buildx`.

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
COMPOSE="${REPO_ROOT}/pasithea-silo/docker-compose.yml"
MANIFEST="${REPO_ROOT}/pasithea-silo/umbrel-app.yml"

UPSTREAM_REPO="Silo-Server/silo-server"
SILO_IMAGE="ghcr.io/silo-server/silo-server"
POSTGRES_IMAGE="pgvector/pgvector:pg18"
REDIS_IMAGE="redis:8.2-alpine"

API="https://api.github.com"

log() { printf '%s\n' "$*" >&2; }
die() { log "ERROR: $*"; exit 1; }

# --- image helpers -----------------------------------------------------------

# Print the manifest-list/index digest for an image reference.
image_digest() {
  local ref="$1"
  if command -v crane >/dev/null 2>&1; then
    crane digest "$ref" 2>/dev/null
  elif command -v docker >/dev/null 2>&1; then
    docker buildx imagetools inspect "$ref" --format '{{json .Manifest}}' 2>/dev/null | jq -r '.digest'
  else
    die "need crane or docker buildx to resolve image digests"
  fi
}

# Print the platform list for an image reference, one "os/arch" per line.
image_platforms() {
  local ref="$1"
  if command -v crane >/dev/null 2>&1; then
    crane manifest "$ref" 2>/dev/null | jq -r '.manifests[]? | "\(.platform.os)/\(.platform.architecture)"'
  elif command -v docker >/dev/null 2>&1; then
    docker buildx imagetools inspect "$ref" --format '{{json .Manifest}}' 2>/dev/null \
      | jq -r '.manifests[]? | "\(.platform.os)/\(.platform.architecture)"'
  else
    die "need crane or docker buildx to resolve image manifests"
  fi
}

# Fail unless the image publishes both architectures Umbrel installs on.
require_multi_arch() {
  local ref="$1" platforms
  platforms="$(image_platforms "$ref" || true)"
  [[ -n "$platforms" ]] || die "could not read a platform list for ${ref}"
  for want in linux/amd64 linux/arm64; do
    grep -qx "$want" <<<"$platforms" || die "${ref} does not publish ${want}"
  done
}

# --- upstream helpers --------------------------------------------------------

# Fetch the head commit of upstream's default branch.
latest_upstream_sha() {
  local json
  json="$(curl -fsSL \
    -H "Accept: application/vnd.github+json" \
    ${GITHUB_TOKEN:+-H "Authorization: Bearer ${GITHUB_TOKEN}"} \
    "${API}/repos/${UPSTREAM_REPO}/commits/main")" || die "GitHub API request failed"

  local sha
  sha="$(jq -r '.sha // empty' <<<"$json")"
  [[ "$sha" =~ ^[0-9a-f]{40}$ ]] || die "unexpected commit payload from GitHub API"
  printf '%s\n' "$sha"
}

# --- current package state ---------------------------------------------------

# Read the image reference currently pinned for a service in the compose file.
current_image() {
  local service="$1"
  awk -v svc="  ${service}:" '
    $0 == svc { in_block = 1; next }
    in_block && /^  [a-z]/ { in_block = 0 }
    in_block && /^    image: / { sub(/^    image: /, ""); print; exit }
  ' "$COMPOSE"
}

# Split "repo:tag@sha256:digest" into its parts.
image_tag()    { sed -E 's|^(.+):([^:@/]+)@sha256:[a-f0-9]{64}$|\2|' <<<"$1"; }
image_digest_part() { sed -E 's|^.+@(sha256:[a-f0-9]{64})$|\1|' <<<"$1"; }

current_version() { sed -nE 's/^version: *"?([^"]*)"? *$/\1/p' "$MANIFEST" | head -1; }

# --- rewriting ---------------------------------------------------------------

set_service_image() {
  local service="$1" ref="$2"
  awk -v svc="  ${service}:" -v ref="$ref" '
    $0 == svc { in_block = 1; print; next }
    in_block && /^  [a-z]/ { in_block = 0 }
    in_block && /^    image: / { print "    image: " ref; next }
    { print }
  ' "$COMPOSE" > "${COMPOSE}.tmp"
  mv "${COMPOSE}.tmp" "$COMPOSE"
}

set_version() {
  local version="$1"
  sed -i -E "s|^version: .*|version: \"${version}\"|" "$MANIFEST"
}

set_release_notes() {
  local notes="$1"
  # releaseNotes is a single machine-managed line so it can be rewritten safely.
  python3 - "$MANIFEST" "$notes" <<'PY'
import re, sys
path, notes = sys.argv[1], sys.argv[2]
text = open(path, encoding="utf-8").read()
escaped = notes.replace("\\", "\\\\").replace('"', '\\"')
new, n = re.subn(r'^releaseNotes: .*$', f'releaseNotes: "{escaped}"', text, count=1, flags=re.M)
if n != 1:
    sys.exit("could not find a single releaseNotes line to replace")
open(path, "w", encoding="utf-8").write(new)
PY
}

# --- main --------------------------------------------------------------------

command -v jq >/dev/null 2>&1 || die "jq is required"

sha="$(latest_upstream_sha)"
short_sha="${sha:0:7}"
log "upstream main: ${sha} (${short_sha})"

silo_ref="${SILO_IMAGE}:${sha}"
if ! digest="$(image_digest "$silo_ref")" || [[ -z "$digest" ]]; then
  log "no published image for ${short_sha} yet (upstream CI still building) - nothing to do"
  exit 0
fi
log "image digest:  ${digest}"
require_multi_arch "$silo_ref"

# Resolve dependency digests too; a rebuilt versioned tag is a real update.
pg_ref_digest="$(image_digest "$POSTGRES_IMAGE")" || die "could not resolve ${POSTGRES_IMAGE}"
redis_ref_digest="$(image_digest "$REDIS_IMAGE")" || die "could not resolve ${REDIS_IMAGE}"

current_silo="$(current_image server)"
current_silo_tag="$(image_tag "$current_silo")"
current_silo_digest="$(image_digest_part "$current_silo")"
current_pg_digest="$(image_digest_part "$(current_image postgres)")"
current_redis_digest="$(image_digest_part "$(current_image redis)")"

silo_changed=false
[[ "$current_silo_tag" == "$sha" && "$current_silo_digest" == "$digest" ]] || silo_changed=true

deps_changed=()
[[ "$current_pg_digest" == "$pg_ref_digest" ]] || deps_changed+=("postgres")
[[ "$current_redis_digest" == "$redis_ref_digest" ]] || deps_changed+=("redis")

if [[ "$silo_changed" == false && ${#deps_changed[@]} -eq 0 ]]; then
  log "already pinned to ${short_sha}; no changes"
  exit 0
fi

set_service_image server "${silo_ref}@${digest}"
set_service_image postgres "pgvector/pgvector:pg18@${pg_ref_digest}"
set_service_image redis "redis:8.2-alpine@${redis_ref_digest}"

if [[ "$silo_changed" == true ]]; then
  set_version "$short_sha"
  set_release_notes "Silo updated to upstream commit ${short_sha}. Full changes: https://github.com/${UPSTREAM_REPO}/compare/${current_silo_tag}...${sha}"
  log "silo repinned: ${current_silo_tag} -> ${short_sha}"
else
  # Package-only change: the upstream version is unchanged, so keep it and mark
  # the revision with a patch suffix, as the Umbrel update guide prescribes.
  current="$(current_version)"
  if [[ "$current" =~ ^(.+)-patch\.([0-9]+)$ ]]; then
    new_version="${BASH_REMATCH[1]}-patch.$((BASH_REMATCH[2] + 1))"
  else
    new_version="${current}-patch.1"
  fi
  set_version "$new_version"
  set_release_notes "Refreshed bundled images (${deps_changed[*]})."
  log "dependency images repinned; version ${current} -> ${new_version}"
fi

log "done"
