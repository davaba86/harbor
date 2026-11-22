#!/usr/bin/env bash
# Harbor: App Store Connect / TestFlight status fetch. Sourced by poll.sh.
# Mirrors common.sh's one-JSON-object-per-call contract: prints a
# TestFlightStatus-shaped object on success, or prints nothing and returns
# 1 (stale) / 2 (auth error) / 3 (missing key file) on failure.
#
# Harbor never stores or manages Apple credentials itself, same posture as
# the gh/glab CLIs it already defers to for CI/CD: it only reads the .p8 key
# from the standard location Apple's own tooling (Xcode, fastlane, altool)
# already expects. Config carries only the non-secret identifiers
# (bundle_id, key_id, issuer_id) — see config.example.json's apple_apps.

set -uo pipefail

HARBOR_APPLE_KEYS_DIR="${HARBOR_APPLE_KEYS_DIR:-$HOME/.appstoreconnect/private_keys}"
HARBOR_APPLE_API="https://api.appstoreconnect.apple.com"

harbor::_b64url() {
  openssl base64 -A | tr '+/' '-_' | tr -d '='
}

# harbor::_der_int_to_jose_half <hex>
# One ASN.1 INTEGER's hex value -> a fixed 32-byte (64 hex char) half of a
# JOSE ES256 signature. DER strips leading zero bytes (and adds exactly one
# back when the top bit is set, to keep the INTEGER non-negative) — both
# cases must collapse back to the same fixed width here, so strip any
# leading "00" byte-pairs down to 64 hex chars before padding back up.
harbor::_der_int_to_jose_half() {
  local h="$1"
  while [ "${#h}" -gt 64 ] && [ "${h:0:2}" = "00" ]; do h="${h:2}"; done
  printf '%064s' "$h" | tr ' ' '0'
}

# harbor::_der_sig_to_jose <der_signature_file>
# Converts an ECDSA DER signature (as openssl dgst -sign emits) to the raw
# r||s base64url form a JOSE ES256 signature needs.
harbor::_der_sig_to_jose() {
  local der_file="$1" r s
  r=$(openssl asn1parse -inform DER -in "$der_file" 2>/dev/null | awk -F: '/INTEGER/{print $4; exit}')
  s=$(openssl asn1parse -inform DER -in "$der_file" 2>/dev/null | awk -F: '/INTEGER/{c++; if (c==2) {print $4; exit}}')
  r=$(harbor::_der_int_to_jose_half "$r")
  s=$(harbor::_der_int_to_jose_half "$s")
  printf '%s%s' "$r" "$s" | xxd -r -p | harbor::_b64url
}

# harbor::apple_jwt <key_id> <issuer_id> <key_path>
# Builds a short-lived ES256 JWT for the App Store Connect API (max
# lifetime is 20 minutes; this uses ~18 to leave room for request latency).
harbor::apple_jwt() {
  local key_id="$1" issuer_id="$2" key_path="$3"
  local now exp header payload signing_input sig_der sig_jose
  now=$(date +%s)
  exp=$((now + 1080))
  header=$(printf '{"alg":"ES256","kid":"%s","typ":"JWT"}' "$key_id" | harbor::_b64url)
  payload=$(printf '{"iss":"%s","iat":%d,"exp":%d,"aud":"appstoreconnect-v1"}' "$issuer_id" "$now" "$exp" | harbor::_b64url)
  signing_input="${header}.${payload}"

  sig_der=$(mktemp)
  printf '%s' "$signing_input" | openssl dgst -sha256 -sign "$key_path" -out "$sig_der" 2>/dev/null
  sig_jose=$(harbor::_der_sig_to_jose "$sig_der")
  rm -f "$sig_der"

  printf '%s.%s' "$signing_input" "$sig_jose"
}

# harbor::fetch_apple <name> <bundle_id> <key_id> <issuer_id>
# Prints a normalized TestFlightStatus JSON object, or returns 1 (stale) /
# 2 (auth error) / 3 (missing key file).
harbor::fetch_apple() {
  local name="$1" bundle_id="$2" key_id="$3" issuer_id="$4"
  local key_path="$HARBOR_APPLE_KEYS_DIR/AuthKey_${key_id}.p8"

  if [ ! -f "$key_path" ]; then
    echo "$(date -u +%FT%TZ) [$name] missing ASC key: $key_path" >> "$ERROR_LOG"
    return 3
  fi

  local jwt resp code body
  jwt=$(harbor::apple_jwt "$key_id" "$issuer_id" "$key_path")

  resp=$(curl -s -w '\n%{http_code}' "$HARBOR_APPLE_API/v1/apps?filter%5BbundleId%5D=$bundle_id" \
    -H "Authorization: Bearer $jwt")
  code=$(echo "$resp" | tail -1)
  body=$(echo "$resp" | sed '$d')
  if [ "$code" = "401" ] || [ "$code" = "403" ]; then return 2; fi
  [ "$code" = "200" ] || return 1
  local app_id
  app_id=$(echo "$body" | jq -r '.data[0].id // empty')
  [ -z "$app_id" ] && return 1

  resp=$(curl -s -w '\n%{http_code}' \
    "$HARBOR_APPLE_API/v1/builds?filter%5Bapp%5D=$app_id&sort=-uploadedDate&limit=1&include=preReleaseVersion,betaAppReviewSubmission" \
    -H "Authorization: Bearer $jwt")
  code=$(echo "$resp" | tail -1)
  body=$(echo "$resp" | sed '$d')
  if [ "$code" = "401" ] || [ "$code" = "403" ]; then return 2; fi
  [ "$code" = "200" ] || return 1
  [ "$(echo "$body" | jq '.data | length')" -eq 0 ] && return 1

  local processing_state build_number build_version review_state url now
  processing_state=$(echo "$body" | jq -r '.data[0].attributes.processingState // "INVALID" | ascii_downcase')
  build_number=$(echo "$body" | jq -r '.data[0].attributes.version // empty')
  build_version=$(echo "$body" | jq -r '[.included[]? | select(.type=="preReleaseVersions")][0].attributes.version // empty')
  [ -z "$build_version" ] && build_version="$build_number"
  # betaReviewState is absent until the first beta review is actually
  # submitted for this build — not every build has one, so this stays
  # optional (null) rather than a guessed default state.
  review_state=$(echo "$body" | jq -r '[.included[]? | select(.type=="betaAppReviewSubmissions")][0].attributes.betaReviewState // empty | ascii_downcase')
  url="https://appstoreconnect.apple.com/apps/$app_id/testflight/ios"
  now=$(date -u +%FT%TZ)

  jq -n \
    --arg name "$name" --arg bundle_id "$bundle_id" --arg processing_state "$processing_state" \
    --arg review_state "$review_state" --arg build_version "$build_version" --arg build_number "$build_number" \
    --arg url "$url" --arg updated_at "$now" \
    '{name: $name, bundle_id: $bundle_id, processing_state: $processing_state,
      beta_review_status: (if $review_state == "" then null else $review_state end),
      build_version: $build_version, build_number: $build_number, url: $url, updated_at: $updated_at}'
}
