#!/usr/bin/env bash
#
# Repin the TorBox Client Umbrel package to the image upstream currently ships.
#
# Upstream publishes the `latest` tag only -- no releases and no commit tags --
# so the digest is the only thing that actually pins a build. This resolves the
# digest that `latest` points at right now, checks that it is published for both
# architectures Umbrel installs on, and rewrites the package when it has moved.
#
# Because the tag alone proves nothing, a moving `latest` with no updater would
# leave the app frozen on an old build forever. This keeps it current without
# anyone touching the repository.
#
# Exit codes:
#   0  nothing to do, or the package was updated
#   1  a real failure (missing tooling, unexpected registry response)
#
# The script never commits. The calling workflow does that.
#
# Requires: curl, jq, and either crane or `docker buildx`.

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP_ID="pasithea-torbox"
COMPOSE="${REPO_ROOT}/${APP_ID}/docker-compose.yml"
MANIFEST="${REPO_ROOT}/${APP_ID}/umbrel-app.yml"

IMAGE_REPO="ghcr.io/devblaze/torbox-client"
IMAGE_TAG="latest"

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

# --- main --------------------------------------------------------------------

main() {
  local ref="${IMAGE_REPO}:${IMAGE_TAG}"

  [[ -f "$COMPOSE" ]] || die "missing ${COMPOSE}"
  [[ -f "$MANIFEST" ]] || die "missing ${MANIFEST}"

  # Checked before repinning: an image that dropped a platform would break every
  # install on that architecture, and the digest alone would not tell us.
  require_multi_arch "$ref"

  local digest
  digest="$(image_digest "$ref")"
  [[ -n "$digest" && "$digest" == sha256:* ]] || die "could not resolve a digest for ${ref}"

  local current
  current="$(grep -oE "${IMAGE_REPO//\//\\/}:${IMAGE_TAG}@sha256:[a-f0-9]+" "$COMPOSE" \
    | grep -oE 'sha256:[a-f0-9]+$' | head -1 || true)"

  if [[ "$current" == "$digest" ]]; then
    log "Already pinned to ${digest:0:19}...; nothing to do."
    return 0
  fi

  log "Digest moved: ${current:-<not pinned>} -> ${digest}"

  # Replace only the TorBox image's digest, leaving every other line untouched.
  sed -i -E "s|(${IMAGE_REPO//\//\\/}:${IMAGE_TAG})@sha256:[a-f0-9]+|\1@${digest}|" "$COMPOSE"

  # Upstream exposes no version to follow, so the pack is dated instead. It only
  # changes when the digest does, so umbrelOS offers an update exactly once per
  # upstream build.
  local today
  today="$(date -u +%Y.%m.%d)"
  sed -i -E "s|^version: .*|version: \"${today}\"|" "$MANIFEST"
  sed -i -E "s|^releaseNotes: >-$|releaseNotes: >-\n  Repinned to the current upstream image (${digest:7:12}).|" "$MANIFEST"

  # A package that no longer resolves to the digest we just wrote is worse than
  # a stale one, so verify rather than assume the edit landed.
  grep -q "@${digest}" "$COMPOSE" || die "repin did not take effect in ${COMPOSE}"

  log "Repinned to ${digest} (version ${today})."
}

main "$@"
