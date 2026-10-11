#!/usr/bin/env bash
# Starts mongod (or mongos when ROLE=mongos) with the auth mode set in
# runtime/state/<node>.mode: none | transition | keyfile (default).
# A per-node keyfile runtime/state/<node>.key overrides the shared one,
# which is how key rotation is rolled out one member at a time.
set -euo pipefail
NODE=${NODE:?NODE not set}
STATE=/lab/runtime/state
MODE=$(cat "$STATE/$NODE.mode" 2>/dev/null || echo keyfile)
KEY=$STATE/$NODE.key
[ -f "$KEY" ] || KEY=/lab/runtime/keyfile

auth=()
if [ "$MODE" != none ]; then
  # mongod refuses a keyfile that is readable by others, so copy it with 400.
  install -o mongodb -g mongodb -m 400 "$KEY" /tmp/keyfile
  auth=(--keyFile /tmp/keyfile)
  if [ "$MODE" = transition ]; then auth+=(--transitionToAuth); fi
fi
echo "[$NODE] auth mode: $MODE, keyfile: $KEY"

if [ "${ROLE:-}" = mongos ]; then
  exec gosu mongodb mongos --bind_ip_all --port 27017 "${auth[@]}" "$@"
fi
chown -R mongodb:mongodb /data/db
exec gosu mongodb mongod --bind_ip_all --port 27017 --wiredTigerCacheSizeGB 0.25 "${auth[@]}" "$@"
