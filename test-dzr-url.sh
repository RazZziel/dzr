#!/bin/sh
# Regression test for dzr-url stale-session handling.
#
# Reproduces the failure that happens when a long-running dzr keeps reusing a
# Deezer session that has expired server-side (after ~1 day): song.getListData
# then returns an `error` object or null `.results.data`, which used to make
# dzr-url iterate over null in jq and emit a confusing
#   "jq: error (at <stdin>:0): Cannot iterate over null (null)"
# followed by the "USAGE: dzr-url ..." spam loop.
#
# dzr-url must instead exit with the dedicated stale-session code (3) and a
# specific message, with no jq null-iteration noise.

set -u
HERE=$(CDPATH= cd "$(dirname "$0")" && pwd)
DZR_URL="$HERE/dzr-url"
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
fails=0

# Build a fake FETCH that prints the contents of $STUB_BODY for any request,
# ignoring URL/headers/data. This lets us drive dzr-url with canned gw responses
# without any network access.
cat > "$TMP/fakefetch" <<'EOF'
#!/bin/sh
cat "$STUB_BODY"
EOF
chmod +x "$TMP/fakefetch"

run_case() {
	# $1=name  $2=json body returned by every fetch  $3=expected exit code
	name="$1"; body="$2"; want="$3"
	printf '%s' "$body" > "$TMP/body.json"
	# Provide a "valid" inherited session so dzr-url takes the reuse path and goes
	# straight to song.getListData (the call that returns the stale response).
	out=$(STUB_BODY="$TMP/body.json" \
		FETCH="$TMP/fakefetch" \
		DZR_SID=sid DZR_API_TOK=tok DZR_LIC=lic DZR_ARL=deadbeef \
		"$DZR_URL" 12345 2>&1)
	code=$?
	ok=1
	[ "$code" = "$want" ] || { echo "FAIL [$name]: exit=$code want=$want"; ok=0; }
	if printf '%s' "$out" | grep -q 'Cannot iterate over null'; then
		echo "FAIL [$name]: leaked jq null-iteration error"; ok=0
	fi
	if [ "$want" = 3 ] && ! printf '%s' "$out" | grep -qi 'session expired or invalid'; then
		echo "FAIL [$name]: missing specific stale-session message"; ok=0
	fi
	[ "$ok" = 1 ] && echo "PASS [$name]" || { fails=$((fails+1)); echo "  output: $out"; }
}

# Stale session: gw-light returns an error object (e.g. expired token).
run_case "error-object" '{"error":{"VALID_TOKEN_REQUIRED":"Invalid CSRF token"},"results":{}}' 3
# Stale session: results present but data is null (anonymous fallback).
run_case "null-data" '{"error":[],"results":{"data":null}}' 3

[ "$fails" = 0 ] && { echo "ALL TESTS PASSED"; exit 0; } || { echo "$fails TEST(S) FAILED"; exit 1; }
