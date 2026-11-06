#!/usr/bin/env bash
#
# Repin the Maintainerr Umbrel package to upstream's newest release.
#
# Maintainerr publishes real GitHub releases, so there is a version to follow --
# but the release tag and the container tag are not the same string: git gets
# `v3.32.0`, GHCR gets `3.32.0`. This resolves the newest non-prerelease release,
# maps the tag, checks the image exists for both architectures Umbrel installs
# on, and rewrites the package when it has moved. Without it the package would
# sit on whatever version was current the day it was written.
#
# Exit codes:
#   0  nothing to do, or the package was updated
#   1  a real failure (missing tooling, unexpected API or registry response)
#
# The script never commits. The calling workflow does that.
#
# Requires: curl, jq, and either crane or `docker buildx`.

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
COMPOSE="${REPO_ROOT}/pasithea-maintainerr/docker-compose.yml"
MANIFEST="${REPO_ROOT}/pasithea-maintainerr/umbrel-app.yml"

UPSTREAM_REPO="maintainerr/maintainerr"
IMAGE_REPO="ghcr.io/maintainerr/maintainerr"
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

# Fetch upstream's newest published release as JSON.
fetch_latest_release() {
  curl -fsSL \
    -H "Accept: application/vnd.github+json" \
    ${GITHUB_TOKEN:+-H "Authorization: Bearer $GITHUB_TOKEN"} \
    "${API}/repos/${UPSTREAM_REPO}/releases/latest" \
    || die "GitHub API request for the latest release failed"
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

# Replace releaseNotes with a single-line quoted value.
#
# The manifest may hold the notes either as a one-line scalar (what this script
# writes) or as a `>-` block from a hand-written first release, so the block's
# continuation lines are dropped along with the key. Replacing only the key line
# would leave those indented lines behind and break the YAML.
set_release_notes() {
  local notes="$1"
  python3 - "$MANIFEST" "$notes" <<'PY'
import json, re, sys

path, notes = sys.argv[1], sys.argv[2]
lines = open(path, encoding="utf-8").read().split("\n")
out, i, seen = [], 0, 0
while i < len(lines):
    if re.match(r"^releaseNotes:", lines[i]):
        seen += 1
        out.append("releaseNotes: " + json.dumps(notes))
        i += 1
        while i < len(lines) and re.match(r"^\s", lines[i]):
            i += 1
        continue
    out.append(lines[i])
    i += 1
if seen != 1:
    sys.exit(f"expected exactly one releaseNotes key, found {seen}")
open(path, "w", encoding="utf-8").write("\n".join(out))
PY
}

# --- main --------------------------------------------------------------------

command -v jq >/dev/null 2>&1 || die "jq is required"
command -v curl >/dev/null 2>&1 || die "curl is required"

[[ -f "$COMPOSE" ]] || die "missing ${COMPOSE}"
[[ -f "$MANIFEST" ]] || die "missing ${MANIFEST}"

release_json="$(fetch_latest_release)"
release_tag="$(jq -r '.tag_name // empty' <<<"$release_json")"

[[ -n "$release_tag" ]] || die "the latest-release payload had no tag_name"

# Git tags carry a "v" prefix (v3.32.0); GHCR tags do not (3.32.0).
image_tag="${release_tag#v}"

# Built from the repository slug rather than taken from the API payload, whose
# html_url echoes the owner's capitalisation (Maintainerr/Maintainerr).
release_url="https://github.com/${UPSTREAM_REPO}/releases/tag/${release_tag}"

# Upstream is semver today. A tag this script cannot interpret means the release
# scheme changed and the version written into the manifest would be wrong, so
# stop loudly instead of pinning something meaningless.
[[ "$image_tag" =~ ^[0-9]+\.[0-9]+\.[0-9]+([-+.][0-9A-Za-z.-]+)?$ ]] \
  || die "release tag '${release_tag}' is not a version this script understands"

log "upstream release: ${release_tag} -> image tag ${image_tag}"

ref="${IMAGE_REPO}:${image_tag}"
if ! digest="$(image_digest "$ref")" || [[ -z "$digest" ]]; then
  log "no published image for ${ref} yet (upstream still building) - nothing to do"
  exit 0
fi
log "image digest:     ${digest}"

# Checked before repinning: an image that dropped a platform would break every
# install on that architecture, and the digest alone would not tell us.
require_multi_arch "$ref"

current="$(current_image server)"
current_tag="$(image_tag "$current")"
current_digest="$(image_digest_part "$current")"
version="$(current_version)"

if [[ "$current_tag" == "$image_tag" && "$current_digest" == "$digest" && "$version" == "$image_tag" ]]; then
  log "already pinned to ${image_tag} (${digest:7:12}); nothing to do"
  exit 0
fi

if [[ "$current_tag" != "$image_tag" ]]; then
  # The normal case: upstream cut a release.
  new_version="$image_tag"
  notes="Maintainerr updated to ${image_tag}. Upstream release: ${release_url}"
  log "release moved: ${current_tag:-<none>} -> ${image_tag}"
else
  # Same release, different build behind it (a republished tag), or a manifest
  # version that had drifted from the pin. Either way umbrelOS only offers an
  # update when the version changes, so mark the revision with a patch suffix.
  if [[ "$version" =~ ^(.+)-patch\.([0-9]+)$ ]]; then
    new_version="${BASH_REMATCH[1]}-patch.$((BASH_REMATCH[2] + 1))"
  else
    new_version="${image_tag}-patch.1"
  fi
  notes="Repinned ${image_tag} to the current upstream image (${digest:7:12}). Upstream release: ${release_url}"
  log "digest moved for ${image_tag}; version ${version} -> ${new_version}"
fi

set_service_image server "${ref}@${digest}"
set_version "$new_version"
set_release_notes "$notes"

# A package that no longer resolves to the digest we just wrote is worse than a
# stale one, so verify rather than assume the edits landed.
grep -q "${IMAGE_REPO}:${image_tag}@${digest}" "$COMPOSE" \
  || die "repin did not take effect in ${COMPOSE}"
[[ "$(current_version)" == "$new_version" ]] \
  || die "version rewrite did not take effect in ${MANIFEST}"

log "repinned to ${image_tag} (version ${new_version})."
