# TorBox API key.
#
# Upstream reads TORBOX_API_KEY from the environment only. It is deliberately
# absent from the app's Settings tab, and the runtime overrides stored in /data
# do not cover it, so it cannot be entered through the web UI. umbrelOS gives a
# user no way to edit a container's environment either.
#
# So the key is read from a file the user creates:
#
#   ~/umbrel/app-data/pasithea-torbox/data/torbox-api-key
#
# That keeps it out of this repository, out of the compose file, and out of the
# app store listing. The value reaches the container as environment at start
# time, so the app has to be restarted after the file is written or changed.
#
# Umbrel sources this file under `set -euo pipefail`, so every step is guarded
# and a missing or unreadable file simply leaves the key empty.

export APP_PASITHEA_TORBOX_API_KEY=""

if [ -n "${EXPORTS_APP_DATA_DIR:-}" ]; then
  torbox_key_file="${EXPORTS_APP_DATA_DIR}/torbox-api-key"
  if [ -r "${torbox_key_file}" ]; then
    torbox_key="$(tr -d '\r\n' < "${torbox_key_file}" 2>/dev/null || true)"
    if [ -n "${torbox_key}" ]; then
      export APP_PASITHEA_TORBOX_API_KEY="${torbox_key}"
    fi
    unset torbox_key
  fi
  unset torbox_key_file
fi
