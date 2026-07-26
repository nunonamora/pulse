#!/bin/bash
# sign-identity.sh — create a self-signed code-signing identity in a dedicated
# keychain, using only CLT tools (openssl + security). Run ONCE.
#
# Why: `codesign -s -` (ad-hoc) produces the designated requirement
#         designated => cdhash H"<hash of this exact build>"
#      so every rebuild is a *different* program to the system: TCC permissions
#      are re-prompted and SMAppService login-item registrations are invalidated.
#      A self-signed cert produces
#         designated => identifier "com.x.y" and certificate leaf = H"<cert hash>"
#      which is stable forever.
set -euo pipefail

NAME="${1:-Pulse Local Signing}"
KC="${2:-$HOME/Library/Keychains/pulse-signing.keychain-db}"
KCPW="${KCPW:-pulse}"
TMP="$(mktemp -d)"

security create-keychain -p "$KCPW" "$KC" 2>/dev/null || true
security set-keychain-settings "$KC"          # no auto-lock timeout
security unlock-keychain -p "$KCPW" "$KC"

openssl req -x509 -newkey rsa:2048 -nodes -days 3650 \
  -keyout "$TMP/key.pem" -out "$TMP/cert.pem" \
  -subj "/CN=$NAME" \
  -addext "basicConstraints=critical,CA:false" \
  -addext "keyUsage=critical,digitalSignature" \
  -addext "extendedKeyUsage=critical,codeSigning" 2>/dev/null

# macOS Security.framework cannot read OpenSSL 3 default PKCS#12 encryption.
# The legacy -certpbe/-keypbe/-macalg flags are REQUIRED.
openssl pkcs12 -export -inkey "$TMP/key.pem" -in "$TMP/cert.pem" \
  -out "$TMP/id.p12" -passout pass:tmp -name "$NAME" \
  -certpbe PBE-SHA1-3DES -keypbe PBE-SHA1-3DES -macalg sha1

security import "$TMP/id.p12" -k "$KC" -P tmp -T /usr/bin/codesign -A

# OBRIGATÓRIO. Sem isto o codesign consegue ver a identidade mas não usar a
# chave privada sem autorização, e o SecurityAgent abre um diálogo modal que
# bloqueia qualquer build não interativo.
security set-key-partition-list -S apple-tool:,apple:,codesign: -s -k "$KCPW" "$KC" >/dev/null 2>&1
rm -rf "$TMP"

# REQUIRED: codesign only finds identities in keychains that are in the *user
# search list*. Passing --keychain alone is NOT enough ("no identity found").
CUR="$(security list-keychains -d user | sed -e 's/^[[:space:]]*"//' -e 's/"$//')"
if ! printf '%s\n' "$CUR" | grep -qF "$KC"; then
  # shellcheck disable=SC2086
  security list-keychains -d user -s $CUR "$KC"
fi
security list-keychains -d user

echo "Identity '$NAME' installed in $KC"
security find-certificate -c "$NAME" "$KC" >/dev/null && echo "verified present"
echo "NOTE: the cert is untrusted (CSSMERR_TP_NOT_TRUSTED). codesign does not care."
