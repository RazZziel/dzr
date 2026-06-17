#!/bin/sh
# Regression test for dzr's stale-session self-heal and Flow-loop termination.
#
# Background: a long-running dzr reuses its gw-light session, which Deezer expires
# server-side after ~1 day. Content calls (e.g. radio.getUserRadio for Flow) then
# return {"results":{"data":null}}, which used to:
#   - make `jq` emit "Cannot iterate over null", and
#   - spin the `∞` Flow loop forever because an empty track list ("/track/" ->
#     basename "track") still looked non-empty and was fed to dzr-url.
#
# This test checks the two predicates dzr now relies on:
#   1) gw_stale(): detect a dead/expired session from the actual response.
#   2) play()'s ID gating: only a comma-separated list of numeric IDs is playable,
#      so an empty/exhausted Flow result stops the loop instead of looping.

set -u
fails=0
GW_FMT_TRKS='"/track/"+([.results.data[]|.SNG_ID]|map(tostring)|join(","))'

# -- gw_stale: exact predicate used in dzr --
gw_stale() {
	printf "%s" "$1" | jq -e '
		(.error|type=="object" and (.|length>0))
		or ((.results|type=="object") and (.results.data==null) and (.results|has("data")))
		or (.results==null) or (.results=="")
	' >/dev/null 2>&1
}
chk_stale() { # name json expect(stale|ok)
	gw_stale "$2" && got=stale || got=ok
	[ "$got" = "$3" ] && echo "PASS [stale:$1] $got" || { echo "FAIL [stale:$1] got=$got want=$3"; fails=$((fails+1)); }
}
chk_stale "valid"        '{"results":{"data":[{"SNG_ID":1}]}}'              ok
chk_stale "empty-array"  '{"results":{"data":[]}}'                          ok
chk_stale "null-data"    '{"error":[],"results":{"data":null}}'            stale
chk_stale "error-object" '{"error":{"VALID_TOKEN_REQUIRED":"x"},"results":{}}' stale
chk_stale "null-results" '{"results":null}'                                 stale

# -- play() ID gating: derive what play() sees and apply the same regex gate --
playable() { # json -> "play" if dzr would play it, "stop" otherwise
	ids=$(printf "%s" "$1" | jq "$GW_FMT_TRKS" | xargs basename 2>/dev/null)
	echo "$ids" | grep -Eq '^[0-9]+(,[0-9]+)*$' && echo play || echo stop
}
chk_play() { # name json expect(play|stop)
	got=$(playable "$2")
	[ "$got" = "$3" ] && echo "PASS [play:$1] $got" || { echo "FAIL [play:$1] got=$got want=$3"; fails=$((fails+1)); }
}
chk_play "tracks"       '{"results":{"data":[{"SNG_ID":1},{"SNG_ID":2}]}}' play
chk_play "empty-flow"   '{"results":{"data":[]}}'                          stop  # was the infinite-loop trigger

[ "$fails" = 0 ] && { echo "ALL TESTS PASSED"; exit 0; } || { echo "$fails TEST(S) FAILED"; exit 1; }
