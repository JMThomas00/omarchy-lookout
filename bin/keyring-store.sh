#!/bin/sh
# Adapted from io.github.jeremylanger.omaspotify's scripts/keyring-store.sh
# (MIT -- see ../THIRD_PARTY_LICENSES.md). Same shape: the secret is read
# from stdin, never argv, and handed straight to secret-tool. Lookout stores
# one JSON blob (client_id + client_secret + refresh_token) under a fixed
# `service lookout` attribute set instead of OmaSpotify's per-client-id
# attribute, since there is exactly one Google account this plugin ever
# associates with -- "log in once," per its own design.
set -eu

IFS= read -r credentials_json
if [ -z "$credentials_json" ]; then
  exit 3
fi

printf '%s' "$credentials_json" | secret-tool store \
  --label='Lookout Google Device Access credentials' \
  service lookout \
  kind google-credentials \
  account default
