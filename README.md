# Pasithea Umbrel Community App Store

A [Umbrel](https://umbrel.com) Community App Store.

## Add this store to umbrelOS

1. Open your Umbrel dashboard.
2. Go to **App Store**, then open the **⋯** menu and choose **Community App Stores**.
3. Paste this URL and confirm:

   ```
   https://github.com/Pasithea0/umbrel-community-app-store
   ```

The store then appears as **Pasithea App Store** in the sidebar.

## Apps

### Silo

Self-hosted media streaming server. Silo runs with its own bundled PostgreSQL
(with pgvector) and Redis, so there is nothing else to install.

- Upstream: <https://siloserver.org> · <https://github.com/Silo-Server/silo-server>
- Install guide: <https://siloserver.org/docs/install>

Two things differ from the upstream Docker Compose instructions, both because
this is a managed Umbrel package rather than a hand-run stack:

- **Media paths.** Umbrel mounts your media at `/media` and `/downloads` inside
  Silo, not `/mnt/media`. Use those paths when you add a library. Pick a folder
  with the **Media Library** app setting, or drop files in Umbrel's Downloads
  folder.
- **Compatibility ports.** Silo's Jellyfin/Emby listener and its Audiobookshelf
  listener are published on **18096** and **13379** instead of upstream's 8096
  and 13378, because the official Jellyfin and Audiobookshelf Umbrel apps
  already own those ports. Point Jellyfin/Emby clients at 18096 and
  Audiobookshelf clients at 13379.

Secrets (`SECRET_KEY`, the PostgreSQL password) are derived from Umbrel's device
seed by `pasithea-silo/exports.sh`, so they are stable across restarts and
updates and never stored in this repository.

## Updates are automatic

`pasithea-silo` is kept current by
[`.github/workflows/update-silo.yml`](.github/workflows/update-silo.yml), which
runs daily and on demand. There is no upstream release to bump against: Silo
publishes no GitHub releases or version tags, so its images are built from
`main` and tagged with the commit they came from.

Each run:

1. Resolves the head commit of `Silo-Server/silo-server` main.
2. Checks that GHCR has actually published an image for that exact commit, and
   that it covers both `linux/amd64` and `linux/arm64`. If upstream CI has not
   finished building, the run does nothing and the next one picks it up.
3. Repins `pasithea-silo/docker-compose.yml` to that commit's tag and digest.
4. Refreshes the pinned digests of the bundled PostgreSQL and Redis images.
5. Lints the package with Umbrel's own linter, then commits.

Manifest `version` follows the pinned upstream commit, which is what makes
umbrelOS offer the update. When only a bundled dependency image moves and
upstream itself has not, the version gains a `-patch.N` suffix so the update is
still offered without claiming a new upstream revision.

To update a user's install, umbrelOS needs the app-store manifest to change; the
update then lands the next time they check for app updates. Nothing needs to be
done by hand.

### Running it yourself

```sh
./scripts/update-silo.sh
```

It needs `curl`, `jq`, and either [`crane`](https://github.com/google/go-containerregistry)
or `docker buildx`. It prints what it found and either repins the package or
reports that it is already current. It never commits — review `git diff` and
commit yourself.

## Validating a change

This store vendors Umbrel's official app linter, so packages are checked with
the same rules the official App Store uses:

```sh
npm install
npm run lint:apps -- --all --check-images
```

`--check-images` reaches out to the registries to confirm every pinned digest is
publicly pullable and multi-architecture. CI runs the same command on every push
and pull request.

### Known lint warnings

`npm run lint:apps` reports three `access.host_mount` warnings for
`/proc/meminfo`, `/proc/stat`, and `/proc/loadavg`. These are intentional.
Upstream mounts them so Silo reports its own CPU, load, and memory rather than
the physical machine's, which matters when the Docker host is itself an LXC
container. They are read-only single-file mounts, and on bare metal or a VM they
are the same files Silo would read anyway.

## Layout

```
umbrel-app-store.yml          store id and display name
pasithea-silo/                the Silo app package
  umbrel-app.yml              app manifest
  docker-compose.yml          service definitions
  exports.sh                  derived secrets
  data/                       committed bind-mount sources
scripts/update-silo.sh        the repin logic the workflow calls
.tools/lint-apps.mjs          vendored Umbrel linter
```
