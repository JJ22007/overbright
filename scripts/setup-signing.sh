#!/usr/bin/env bash
# One-time setup for people who build Overbright from source.
#
# Problem: an ad-hoc signed app gets a new identity on every build, so macOS
# drops its Accessibility permission each time (and the switch in System
# Settings may still look on). Fix: sign every build with the same local,
# self-signed certificate. You then grant the permission once and it sticks.
#
# What this script does:
#   1. creates a self-signed code-signing certificate named
#      "Overbright Local Signing" in your login keychain (it is only ever used
#      to sign your own builds)
#   2. clears stale Accessibility entries left by earlier builds
#   3. rebuilds, installs and launches Overbright
#
# macOS may ask for your login password the first time codesign uses the new
# key. Choose "Always Allow".
#
# To undo: delete "Overbright Local Signing" in Keychain Access.
set -euo pipefail
cd "$(dirname "$0")/.."

NAME="Overbright Local Signing"
KEYCHAIN="${SIGN_KEYCHAIN:-$HOME/Library/Keychains/login.keychain-db}"

if security find-identity -p codesigning "$KEYCHAIN" 2>/dev/null | grep -q "\"$NAME\""; then
  echo "Signing identity already exists."
else
  TMP="$(mktemp -d)"
  trap 'rm -rf "$TMP"' EXIT
  cat > "$TMP/cert.cnf" <<CNF
[req]
distinguished_name = dn
x509_extensions = ext
prompt = no
[dn]
CN = $NAME
[ext]
basicConstraints = critical, CA:false
keyUsage = critical, digitalSignature
extendedKeyUsage = critical, codeSigning
CNF
  # /usr/bin/openssl is LibreSSL, whose PKCS#12 output the keychain can read
  /usr/bin/openssl req -x509 -newkey rsa:2048 -nodes -days 3650 \
    -keyout "$TMP/key.pem" -out "$TMP/cert.pem" -config "$TMP/cert.cnf" 2>/dev/null
  /usr/bin/openssl pkcs12 -export -inkey "$TMP/key.pem" -in "$TMP/cert.pem" \
    -out "$TMP/identity.p12" -name "$NAME" -passout pass:overbright 2>/dev/null
  security import "$TMP/identity.p12" -k "$KEYCHAIN" -P overbright -T /usr/bin/codesign >/dev/null
  echo "Created signing identity \"$NAME\"."
fi

if [[ -z "${SIGN_KEYCHAIN:-}" ]]; then
  tccutil reset Accessibility io.github.overbright >/dev/null 2>&1 || true
  bash scripts/install.sh
  echo
  echo "Done. Grant the Accessibility permission once more; it will now survive rebuilds."
fi
