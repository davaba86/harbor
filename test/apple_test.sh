#!/usr/bin/env bash
# Scripted assertions for bin/lib/apple.sh. Run: bash test/apple_test.sh
#
# No network calls here (same reasoning as poll_single_repo_test.sh) — the
# JWT/signature math is tested against an ephemeral throwaway key instead
# of hitting the real App Store Connect API.
set -uo pipefail
cd "$(dirname "$0")/.."
source bin/lib/apple.sh

fail=0
assert_eq() {
  local desc="$1" expected="$2" actual="$3"
  if [ "$expected" != "$actual" ]; then
    echo "FAIL: $desc (expected '$expected', got '$actual')"
    fail=1
  else
    echo "ok: $desc"
  fi
}

SCRATCH=$(mktemp -d)
trap '/bin/rm -rf "$SCRATCH"' EXIT

openssl ecparam -name prime256v1 -genkey -noout -out "$SCRATCH/key.pem" 2>/dev/null
openssl ec -in "$SCRATCH/key.pem" -pubout -out "$SCRATCH/pub.pem" 2>/dev/null

# --- harbor::apple_jwt: header/payload claims ---

jwt=$(harbor::apple_jwt "TESTKEY1" "11111111-2222-3333-4444-555555555555" "$SCRATCH/key.pem")
IFS='.' read -r header_b64 payload_b64 sig_b64 <<< "$jwt"

decode_b64url() {
  local b64="${1//-/+}"
  b64="${b64//_//}"
  case $(( ${#b64} % 4 )) in
    2) b64="${b64}==" ;;
    3) b64="${b64}=" ;;
  esac
  printf '%s' "$b64" | base64 -D 2>/dev/null
}

header_json=$(decode_b64url "$header_b64")
payload_json=$(decode_b64url "$payload_b64")

assert_eq "JWT has 3 dot-separated parts" "3" "$(echo "$jwt" | awk -F'.' '{print NF}')"
assert_eq "header alg is ES256" "ES256" "$(echo "$header_json" | jq -r '.alg')"
assert_eq "header kid is the key_id" "TESTKEY1" "$(echo "$header_json" | jq -r '.kid')"
assert_eq "payload iss is the issuer_id" "11111111-2222-3333-4444-555555555555" "$(echo "$payload_json" | jq -r '.iss')"
assert_eq "payload aud is appstoreconnect-v1" "appstoreconnect-v1" "$(echo "$payload_json" | jq -r '.aud')"

exp_minus_iat=$(( $(echo "$payload_json" | jq -r '.exp') - $(echo "$payload_json" | jq -r '.iat') ))
if [ "$exp_minus_iat" -gt 0 ] && [ "$exp_minus_iat" -le 1200 ]; then
  echo "ok: exp is within Apple's 20-minute JWT lifetime limit"
else
  echo "FAIL: expected 0 < exp-iat <= 1200, got $exp_minus_iat"
  fail=1
fi

# --- harbor::_der_sig_to_jose: round-trips to a verifiable signature ---
#
# Rebuilds a DER signature from the JOSE r||s this function produces (the
# textbook minimal-DER INTEGER encoding: strip leading zero bytes, add
# exactly one back if the high bit would otherwise flip the sign) and
# confirms openssl still verifies it against the original message — this
# proves the r/s split and zero-padding logic round-trips correctly rather
# than just asserting some hardcoded byte string.
encode_der_integer() {
  local hex="$1"
  while [ "${#hex}" -gt 2 ] && [ "${hex:0:2}" = "00" ]; do hex="${hex:2}"; done
  local first_val=$(( 16#${hex:0:2} ))
  [ "$first_val" -ge 128 ] && hex="00${hex}"
  printf '02%02x%s' "$(( ${#hex} / 2 ))" "$hex"
}

message="harbor-apple-jwt-roundtrip-test"
der_sig="$SCRATCH/sig.der"
printf '%s' "$message" | openssl dgst -sha256 -sign "$SCRATCH/key.pem" -out "$der_sig"

jose_sig=$(harbor::_der_sig_to_jose "$der_sig")
assert_eq "JOSE signature is 86 base64url chars (64 raw bytes, no padding)" "86" "${#jose_sig}"

jose_hex=$(decode_b64url "$jose_sig" | xxd -p | tr -d '\n')
r_hex="${jose_hex:0:64}"
s_hex="${jose_hex:64:64}"

body="$(encode_der_integer "$r_hex")$(encode_der_integer "$s_hex")"
rebuilt_hex=$(printf '30%02x%s' "$(( ${#body} / 2 ))" "$body")
echo "$rebuilt_hex" | xxd -r -p > "$SCRATCH/rebuilt.der"

if printf '%s' "$message" | openssl dgst -sha256 -verify "$SCRATCH/pub.pem" -signature "$SCRATCH/rebuilt.der" 2>&1 | grep -q "Verified OK"; then
  echo "ok: DER->JOSE signature round-trips to a verifiable signature"
else
  echo "FAIL: rebuilt signature did not verify against the original message"
  fail=1
fi

exit $fail
