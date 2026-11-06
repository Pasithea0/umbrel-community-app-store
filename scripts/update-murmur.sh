#!/usr/bin/env bash
#
# Repin the Murmur (Pasithea) Umbrel package to the newest commit on the `dev`
# branch of the fork it is built from.
#
# This app is not built from an upstream release: Pasithea0/murmur's `dev`
# branch carries the group-conversations work, and its own "Dev image" workflow
# publishes ghcr.io/pasithea0/murmur:dev-<commit sha> for every push there. So
# this follows that branch: it resolves the head commit, checks that GHCR has
# actually published an image for that exact commit, and repins the package when
# the digest moves. It also refreshes the digest of the bundled Hermes image,
# whose versioned tag is rebuilt upstream over time.
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
COMPOSE="${REPO_ROOT}/pasithea-murmur/docker-compose.yml"
MANIFEST="${REPO_ROOT}/pasithea-murmur/umbrel-app.yml"

FORK_REPO="Pasithea0/murmur"
FORK_BRANCH="dev"
MURMUR_IMAGE="ghcr.io/pasithea0/murmur"
HERMES_IMAGE="ghcr.io/getumbrel/hermes-agent-umbrel:v0.22.5-4"

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

# --- fork helpers ------------------------------------------------------------

# Fetch the head commit of the branch this package follows.
latest_fork_sha() {
  local json
  local auth=()
  [[ -n "${GITHUB_TOKEN:-}" ]] && auth=(-H "Authorization: Bearer ${GITHUB_TOKEN}")
  json="$(curl -fsSL \
    -H "Accept: application/vnd.github+json" \
    "${auth[@]}" \
    "${API}/repos/${FORK_REPO}/commits/${FORK_BRANCH}")" || die "GitHub API request failed"

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
image_tag()         { sed -E 's|^(.+):([^:@/]+)@sha256:[a-f0-9]{64}$|\2|' <<<"$1"; }
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

sha="$(latest_fork_sha)"
short_sha="${sha:0:7}"
log "${FORK_REPO} ${FORK_BRANCH}: ${sha} (${short_sha})"

murmur_ref="${MURMUR_IMAGE}:dev-${sha}"
if ! digest="$(image_digest "$murmur_ref")" || [[ -z "$digest" ]]; then
  log "no published image for ${short_sha} yet (the fork's Dev image workflow is still building) - nothing to do"
  exit 0
fi
log "image digest:  ${digest}"
require_multi_arch "$murmur_ref"

# Resolve the bundled Hermes digest too; a rebuilt versioned tag is a real update.
hermes_ref_digest="$(image_digest "$HERMES_IMAGE")" || die "could not resolve ${HERMES_IMAGE}"

current_murmur="$(current_image web)"
current_murmur_tag="$(image_tag "$current_murmur")"
current_murmur_digest="$(image_digest_part "$current_murmur")"
current_hermes_digest="$(image_digest_part "$(current_image hermes)")"

murmur_changed=false
[[ "$current_murmur_tag" == "dev-${sha}" && "$current_murmur_digest" == "$digest" ]] || murmur_changed=true

hermes_changed=false
[[ "$current_hermes_digest" == "$hermes_ref_digest" ]] || hermes_changed=true

if [[ "$murmur_changed" == false && "$hermes_changed" == false ]]; then
  log "already pinned to ${short_sha}; no changes"
  exit 0
fi

set_service_image web "${murmur_ref}@${digest}"
set_service_image hermes "${HERMES_IMAGE}@${hermes_ref_digest}"

if [[ "$murmur_changed" == true ]]; then
  set_version "$short_sha"
  if [[ "$current_murmur_tag" == dev-* && "${current_murmur_tag#dev-}" =~ ^[0-9a-f]{40}$ ]]; then
    from="${current_murmur_tag#dev-}"
    compare="Full changes: https://github.com/${FORK_REPO}/compare/${from}...${sha}"
  else
    compare="Full changes: https://github.com/${FORK_REPO}/commits/${FORK_BRANCH}"
  fi
  set_release_notes "Pasithea's Murmur updated to fork commit ${short_sha}. ${compare}"
  log "murmur repinned: ${current_murmur_tag} -> dev-${sha}"
else
  # Package-only change: the built-from version is unchanged, so keep it and mark
  # the revision with a patch suffix, as the Umbrel update guide prescribes.
  current="$(current_version)"
  if [[ "$current" =~ ^(.+)-patch\.([0-9]+)$ ]]; then
    new_version="${BASH_REMATCH[1]}-patch.$((BASH_REMATCH[2] + 1))"
  else
    new_version="${current}-patch.1"
  fi
  set_version "$new_version"
  set_release_notes "Refreshed the bundled Hermes image (${HERMES_IMAGE})."
  log "bundled Hermes repinned; version ${current} -> ${new_version}"
fi

log "done"
