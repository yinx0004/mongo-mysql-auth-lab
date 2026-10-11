#!/usr/bin/env bash
# 07 Rotating the replica set keyfile one member at a time.
# Keyfiles may hold several keys as a YAML list; members accept any of them.
# Only rs0 is rotated: its members get per-node keyfiles under runtime/state,
# the shared runtime/keyfile (also used by the sharded cluster) is left alone.
. "$(dirname "$0")/../scripts/lib.sh"

health() {
  local p; p=$(primary_node) || { echo "  no primary"; return; }
  mongo_admin_direct "$p" --eval \
    'rs.status().members.forEach(m => print(`  ${m.name}  ${m.stateStr}  health=${m.health}`))'
}
roll() {
  local p n
  p=$(primary_node)
  for n in $MONGO_NODES; do [ "$n" = "$p" ] || { "$@" "$n"; restart_member "$n" keyfile; }; done
  "$@" "$p"; restart_member "$p" keyfile
}

set_key() {  # set_key NODE KEY...  -> per-node keyfile with these keys, in order
  local node=$1; shift
  printf -- '- %s\n' "$@" > "runtime/state/$node.key"
}
# rs0's current key: from an earlier rotation if there was one, else the shared key.
if [ -f runtime/state/mongo1.key ]; then
  OLD=$(sed -n 's/^- //p' runtime/state/mongo1.key | tail -1)
else
  OLD=$(tr -d ' \n\t' < runtime/keyfile)
fi
NEW=$(openssl rand -base64 756 | tr -d '\n')
for n in $MONGO_NODES; do echo keyfile > "runtime/state/$n.mode"; set_key "$n" "$OLD"; done

step "Starting point: every member uses the old key"
health

step "What if one member gets only the new key?"
S=$(for n in $MONGO_NODES; do [ "$(member_state "$n")" = SECONDARY ] && echo "$n"; done | head -1)
note "restarting $S with only the new key, then waiting 20s"
set_key "$S" "$NEW"
docker restart "authlab-$S" >/dev/null
sleep 20
health
note "put it back on the old key"
set_key "$S" "$OLD"
restart_member "$S" keyfile

step "1. Roll every member to a keyfile with both keys: old first, new second"
cmd 'keyfile:
- <old key>
- <new key>'
both() { set_key "$1" "$OLD" "$NEW"; }
roll both
health

step "2. Roll every member to a keyfile with only the new key"
only_new() { set_key "$1" "$NEW"; }
roll only_new
health

note "rs0 now runs on the new key (runtime/state/mongo*.key); other clusters keep theirs"
mongo_admin --eval 'db.runCommand({connectionStatus: 1}).authInfo.authenticatedUsers'
