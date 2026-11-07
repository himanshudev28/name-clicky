#!/bin/bash
# One-time: creates a self-signed code-signing certificate "MacPilot Dev" in your
# login keychain, so rebuilt copies of MacPilot keep their macOS permissions.
# It's only trusted for code signing on this Mac. Remove it any time in Keychain Access.
set -euo pipefail
NAME="MacPilot Dev"
if security find-identity -p codesigning | grep -q "\"$NAME\""; then
    echo "\"$NAME\" already exists."; exit 0
fi
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
cat > "$TMP/cert.cnf" <<EOF
[req]
distinguished_name = dn
x509_extensions = ext
prompt = no
[dn]
CN = $NAME
[ext]
keyUsage = critical, digitalSignature
extendedKeyUsage = critical, codeSigning
basicConstraints = critical, CA:false
EOF
openssl req -x509 -newkey rsa:2048 -nodes -days 3650 -config "$TMP/cert.cnf" \
    -keyout "$TMP/key.pem" -out "$TMP/cert.pem" 2>/dev/null
openssl pkcs12 -export -legacy -inkey "$TMP/key.pem" -in "$TMP/cert.pem" \
    -out "$TMP/id.p12" -passout pass:macpilot -name "$NAME" 2>/dev/null \
  || openssl pkcs12 -export -inkey "$TMP/key.pem" -in "$TMP/cert.pem" \
    -out "$TMP/id.p12" -passout pass:macpilot -name "$NAME"
security import "$TMP/id.p12" -k ~/Library/Keychains/login.keychain-db -P macpilot -T /usr/bin/codesign
# Trust it for code signing (macOS asks for your password once).
security add-trusted-cert -r trustRoot -p codeSign -k ~/Library/Keychains/login.keychain-db "$TMP/cert.pem"
echo "✓ Created \"$NAME\". Run scripts/build-app.sh again."
