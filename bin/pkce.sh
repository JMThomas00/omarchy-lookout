#!/bin/sh
# Adapted (unchanged logic) from io.github.jeremylanger.omaspotify's
# scripts/pkce.sh (MIT -- see ../THIRD_PARTY_LICENSES.md). Google's Device
# Access OAuth client is a confidential "Web application" type, so PKCE
# isn't strictly required the way it is for a public client -- generated
# anyway as defense in depth, matching this ecosystem's own precedent.
set -eu

umask 077

verifier=$(openssl rand -base64 72 | tr -d '=+/\n' | cut -c1-64)
challenge=$(printf '%s' "$verifier" | openssl dgst -sha256 -binary | openssl base64 -A | tr '+/' '-_' | tr -d '=')
state=$(openssl rand -hex 24)

printf '%s\t%s\t%s\n' "$verifier" "$challenge" "$state"
