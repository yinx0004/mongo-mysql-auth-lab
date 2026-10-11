#!/usr/bin/env bash
# 08 Users in a sharded cluster: cluster users (via mongos, stored on the config
# servers) vs shard-local users. Starts the sharded profile if needed.
. "$(dirname "$0")/../scripts/lib.sh"

if ! docker ps --format '{{.Names}}' | grep -q '^authlab-mongos$'; then
  ./lab.sh up-sharded >/dev/null 2>&1
fi
MONGOS_ADMIN="mongodb://admin:${MONGO_ADMIN_PASSWORD}@mongos:27017/?authSource=admin"
mongos_admin() { docker exec -i authlab-mongos mongosh --quiet "$MONGOS_ADMIN" "$@"; }

step "Setup: a hashed-sharded collection sales.orders, and a cluster user"
mongos_admin --eval '
  try { db.getSiblingDB("admin").dropUser("analyst") } catch (e) {}
  sh.shardCollection("sales.orders", {_id: "hashed"})
  const o = db.getSiblingDB("sales").orders;
  if (o.countDocuments() === 0) o.insertMany(Array.from({length: 20}, (_, i) => ({_id: i, amount: i * 10})))
  db.getSiblingDB("admin").createUser({user: "analyst", pwd: "analyst-pw", roles: [{role: "read", db: "sales"}]})' >/dev/null
# Re-runs: drop the shard-local user so shard1 starts with no users again.
docker exec authlab-client-a mongosh --quiet \
  "mongodb://shardadmin:shardadmin-pw@shard1:27017/?authSource=admin&directConnection=true" \
  --eval 'db.getSiblingDB("admin").dropUser("shardadmin")' >/dev/null 2>&1 || true
# mongod remembers that users existed: the localhost exception only reopens
# after a restart, even when the last user has been dropped.
docker restart authlab-shard1 >/dev/null
wait_primary shard1 || exit 1
cmd 'mongos> db.getSiblingDB("admin").createUser({user: "analyst", pwd: "analyst-pw", roles: [{role: "read", db: "sales"}]})'

step "A user created through mongos works through mongos..."
mongosh_on a "mongodb://analyst:analyst-pw@mongos:27017/sales?authSource=admin" 'db.orders.countDocuments()'
note "...because it is stored on the config server replica set"
mongos_admin --eval 'db.getSiblingDB("admin").system.users.find({}, {_id: 1}).toArray()'

step "...but not on a direct connection to the shard"
mongosh_on a "mongodb://analyst:analyst-pw@shard1:27017/sales?authSource=admin&directConnection=true" 'db.orders.countDocuments()'
for n in shard1; do docker logs --since 1m "authlab-$n" 2>&1 | grep '"msg":"Failed to authenticate"' | tail -1 | python3 -c '
import json, sys
for l in sys.stdin: print("  [shard1 log] error:", json.loads(l)["attr"]["error"])'; done

step "The shard has no users of its own, so its localhost exception is still open"
cmd "[shard1]\$ mongosh admin --eval 'db.createUser({user: \"shardadmin\", pwd: \"shardadmin-pw\", roles: [\"root\"]})'"
docker exec authlab-shard1 mongosh --quiet admin --eval '
  try { db.createUser({user: "shardadmin", pwd: "shardadmin-pw", roles: ["root"]}).ok }
  catch (e) { print(e.message) }' 2>&1
note "this shard-local user exists only on shard1, and mongos doesn't know it"
mongosh_on a "mongodb://shardadmin:shardadmin-pw@shard1:27017/?authSource=admin&directConnection=true" \
  'db.getSiblingDB("admin").system.users.find({}, {_id: 1}).toArray()'
mongosh_on a "mongodb://shardadmin:shardadmin-pw@mongos:27017/?authSource=admin" 'db.getName()'
