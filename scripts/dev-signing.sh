#!/usr/bin/env bash
# Creates a self-signed code signing identity in its own keychain
# (~/Library/Keychains/accio-dev.keychain-db; the login keychain is untouched).
# build.sh signs with it when present, so macOS keeps Accio's Accessibility
# grant across rebuilds. It can't stop the icon hiding: that needs an
# Apple-issued certificate (docs/spikes.md §1d).
set -e

KEYCHAIN="$HOME/Library/Keychains/accio-dev.keychain-db"
PASSWORD="accio-dev"
NAME="Accio Local Development"

if [ -f "$KEYCHAIN" ]; then
    echo "Already set up: $KEYCHAIN"
    exit 0
fi

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

cat > "$WORK/cert.cnf" << CNF
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

openssl req -x509 -newkey rsa:2048 -nodes -days 3650 -config "$WORK/cert.cnf" \
    -keyout "$WORK/key.pem" -out "$WORK/cert.pem" 2> /dev/null
openssl pkcs12 -export -legacy -inkey "$WORK/key.pem" -in "$WORK/cert.pem" \
    -out "$WORK/id.p12" -passout "pass:$PASSWORD" 2> /dev/null \
    || openssl pkcs12 -export -inkey "$WORK/key.pem" -in "$WORK/cert.pem" \
        -out "$WORK/id.p12" -passout "pass:$PASSWORD"

security create-keychain -p "$PASSWORD" "$KEYCHAIN"
security set-keychain-settings "$KEYCHAIN" # never auto-lock
security unlock-keychain -p "$PASSWORD" "$KEYCHAIN"
security import "$WORK/id.p12" -k "$KEYCHAIN" -P "$PASSWORD" -T /usr/bin/codesign > /dev/null
security set-key-partition-list -S apple-tool:,apple: -s -k "$PASSWORD" "$KEYCHAIN" > /dev/null

echo "✅ Created \"$NAME\" in $KEYCHAIN"
