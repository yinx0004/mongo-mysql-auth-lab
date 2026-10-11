#!/usr/bin/env bash
# 05 The localhost exception: how the first MongoDB user gets created.
# Resets rs0 to an empty cluster (all MongoDB data is deleted), then rebuilds it.
. "$(dirname "$0")/../scripts/lib.sh"

local_on() {  # run mongosh inside a member, i.e. a localhost connection
  local node=$1 js=$2 rc=0
  cmd "[$node]\$ mongosh --eval '$js'"
  docker exec "authlab-$node" mongosh --quiet --eval "$js" 2>&1 || rc=$?
  [ "$rc" -eq 0 ] || note "exit code $rc"
}

step "Reset rs0: access control on (keyfile), no replica set config, no users"
docker compose rm -sf mongo1 mongo2 mongo3 >/dev/null 2>&1
docker volume rm authlab_mongo1-data authlab_mongo2-data authlab_mongo3-data >/dev/null
rm -f runtime/state/mongo*.mode runtime/state/mongo*.key
docker compose up -d --wait mongo1 mongo2 mongo3 2>&1 | grep -c Healthy | sed 's/^/healthy members: /'

step "A remote client can't do anything that needs a user"
mongosh_on a "mongodb://mongo1:27017/?directConnection=true" 'rs.initiate()'

step "A localhost connection may initiate the set..."
local_on mongo1 'rs.initiate({_id: "rs0", members: [{_id: 0, host: "mongo1:27017"}, {_id: 1, host: "mongo2:27017"}, {_id: 2, host: "mongo3:27017"}]}).ok'
wait_rs
P=$(primary_node)
note "primary is $P"

step "...but it still can't read or write data"
local_on "$P" 'db.getSiblingDB("shop").orders.insertOne({item: "book"})'

step "It may create the first user, and that closes the exception"
cmd "[$P]\$ mongosh admin --eval 'db.createUser({user: \"admin\", pwd: \"...\", roles: [\"root\"]})'"
docker exec -e PW="$MONGO_ADMIN_PASSWORD" "authlab-$P" mongosh --quiet admin --eval \
  'db.createUser({user: "admin", pwd: process.env.PW, roles: ["root"]}).ok' 2>&1
local_on "$P" 'db.getSiblingDB("admin").createUser({user: "second", pwd: "second-pw", roles: ["root"]})'

note "from now on every connection, local or not, has to authenticate"
mongo_admin --eval 'db.runCommand({connectionStatus: 1}).authInfo.authenticatedUsers'
