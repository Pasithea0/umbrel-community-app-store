# Derived secrets for the Murmur (Pasithea) package.
#
# Both values come from Umbrel's device seed, so they are stable across
# restarts and app updates, and different on every Umbrel install. Deriving them
# here means the package never ships a secret and never writes one to disk.
#
# Murmur's container signs in to the Hermes that ships beside it with these, and
# nothing else ever sees them: that Hermes is not published, is not behind
# app_proxy, and answers only on the app's private network.
export APP_PASITHEA_MURMUR_HERMES_PASSWORD="$(derive_entropy "${app_entropy_identifier}-hermes-password")"

# The key that keeps Murmur signed in to that Hermes across Hermes restarts.
# A separate derivation on purpose: one value signing in and another keeping the
# session alive must not be the same secret.
export APP_PASITHEA_MURMUR_HERMES_SECRET="$(derive_entropy "${app_entropy_identifier}-hermes-session-secret")"
