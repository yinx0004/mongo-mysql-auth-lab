#!/usr/bin/env bash
# 00 Authentication vs authorization: MySQL ties them together, MongoDB
# lets a connection exist unauthenticated and has a separate switch for
# authorization. Uses a throwaway standalone mongod without access control.
. "$(dirname "$0")/../scripts/lib.sh"

step "MySQL: no session without authentication"
cmd "[client-a]\$ mysql -h mysql -e 'SELECT 1'"
docker exec authlab-client-a mysql -h mysql -e 'SELECT 1' 2>&1 || note "exit code $?"

step "MongoDB with access control: unauthenticated connections exist, but can do little"
mongosh_on a "mongodb://mongo1:27017/?directConnection=true" \
  'print("ping:", db.adminCommand({ping: 1}).ok); print("hello.me:", db.hello().me); db.adminCommand({listDatabases: 1})'

step "MongoDB without access control: passwords are checked, privileges are not"
note "setup: standalone mongod 'noauth' without --auth, user reader with only read on shop"
docker rm -f authlab-noauth >/dev/null 2>&1
docker run -d --rm --name authlab-noauth --hostname noauth --network authlab_authlab \
  -e GLIBC_TUNABLES=glibc.pthread.rseq=0 mongo:8.0.4 >/dev/null
for _ in $(seq 1 30); do
  docker exec authlab-noauth mongosh --quiet --eval 'db.adminCommand("ping").ok' >/dev/null 2>&1 && break
  sleep 1
done
docker exec authlab-noauth mongosh --quiet --eval \
  'db.getSiblingDB("shop").createUser({user: "reader", pwd: "reader-pw", roles: [{role: "read", db: "shop"}]})' >/dev/null
mongosh_on a "mongodb://reader:wrong-pw@noauth:27017/shop" 'db.orders.countDocuments()'
mongosh_on a "mongodb://reader:reader-pw@noauth:27017/shop" \
  'print(JSON.stringify(db.runCommand({connectionStatus: 1}).authInfo.authenticatedUsers)); db.orders.insertOne({item: "pen"}).acknowledged'
note "is authorization on? (nothing under security means no)"
mongosh_on a "mongodb://reader:reader-pw@noauth:27017/shop" \
  'JSON.stringify(db.adminCommand({getCmdLineOpts: 1}).parsed)'
docker rm -f authlab-noauth >/dev/null
