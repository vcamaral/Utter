#!/bin/bash
# Creates (once per Mac) the local "Utter Local Signing" certificate in the login Keychain.
# It keeps the app's signature stable across builds, so Keychain/Accessibility don't ask again.
set -euo pipefail

NAME="Utter Local Signing"
if security find-identity -p codesigning | grep -q "$NAME"; then
    echo "Certificate '$NAME' already exists."
    exit 0
fi

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

cat > "$TMP/cert.cnf" <<CNF
[req]
distinguished_name = dn
x509_extensions = ext
prompt = no
[dn]
CN = $NAME
[ext]
basicConstraints = critical,CA:false
keyUsage = critical,digitalSignature
extendedKeyUsage = critical,codeSigning
CNF

openssl req -x509 -newkey rsa:2048 -nodes -days 3650 \
    -keyout "$TMP/key.pem" -out "$TMP/cert.pem" -config "$TMP/cert.cnf" 2>/dev/null

PASS=$(openssl rand -hex 16)
# Legacy format (3DES/SHA1) because `security import` can't read OpenSSL 3's default.
openssl pkcs12 -export -inkey "$TMP/key.pem" -in "$TMP/cert.pem" -out "$TMP/cert.p12" \
    -passout "pass:$PASS" -name "$NAME" \
    -keypbe PBE-SHA1-3DES -certpbe PBE-SHA1-3DES -macalg sha1 2>/dev/null \
  || openssl pkcs12 -export -inkey "$TMP/key.pem" -in "$TMP/cert.pem" -out "$TMP/cert.p12" \
    -passout "pass:$PASS" -name "$NAME"

security import "$TMP/cert.p12" -k ~/Library/Keychains/login.keychain-db -P "$PASS" -T /usr/bin/codesign
echo "Certificate '$NAME' created."
