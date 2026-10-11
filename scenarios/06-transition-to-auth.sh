#!/usr/bin/env bash
# 06 Turning on access control for a running replica set without downtime,
# with --transitionToAuth. Resets rs0 to a cluster without access control.
. "$(dirname "$0")/../scripts/lib.sh"

# Background writers on client-a: one without credentials, one as app user.
start_writers() {
  docker exec authlab-client-a sh -c 'pkill -f writer.js; rm -f /tmp/anon.log /tmp/app.log' || true
  docker exec -d -e W=anon -e SECS=900 authlab-client-a sh -c \
    "mongosh --quiet 'mongodb://$RS_HOSTS/?replicaSet=rs0' /lab/scripts/writer.js > /tmp/anon.log 2>&1"
  docker exec -d -e W=app -e SECS=900 authlab-client-a sh -c \
    "mongosh --quiet 'mongodb://app:app-pw@$RS_HOSTS/shop?replicaSet=rs0' /lab/scripts/writer.js > /tmp/app.log 2>&1"
}
MARK_ANON=0; MARK_APP=0
mark() {
  MARK_ANON=$(docker exec authlab-client-a sh -c 'wc -l < /tmp/anon.log')
  MARK_APP=$(docker exec authlab-client-a sh -c 'wc -l < /tmp/app.log')
}
# Sum the per-second lines written since the last mark.
report() {
  local w m
  for w in anon app; do
    m=$([ $w = anon ] && echo "$MARK_ANON" || echo "$MARK_APP")
    docker exec authlab-client-a sh -c "tail -n +$((m + 1)) /tmp/$w.log" | python3 -c '
import re, sys
ok = err = 0; errs = {}
for line in sys.stdin:
    m = re.match(r"\S+ ok=(\d+) err=(\d+) ?(.*)", line.strip())
    if not m: continue
    ok += int(m[1]); err += int(m[2])
    if m[3]: errs[m[3]] = errs.get(m[3], 0) + 1
print(f"  writer {sys.argv[1]:<4}  ok={ok:<5} err={err}" + "".join(f"\n      {e}" for e in errs))
' "$w"
  done
  mark
}
# Restart secondaries first, the primary last.
roll_to() {
  local mode=$1 p n
  p=$(primary_node)
  for n in $MONGO_NODES; do [ "$n" = "$p" ] || restart_member "$n" "$mode"; done
  restart_member "$p" "$mode"
}

step "Reset rs0 without access control: the MongoDB default"
docker exec authlab-client-a sh -c 'pkill -f writer.js' || true
docker compose rm -sf mongo1 mongo2 mongo3 >/dev/null 2>&1
docker volume rm authlab_mongo1-data authlab_mongo2-data authlab_mongo3-data >/dev/null
rm -f runtime/state/mongo*.key
for n in $MONGO_NODES; do echo none > "runtime/state/$n.mode"; done
docker compose up -d --wait mongo1 mongo2 mongo3 >/dev/null 2>&1
docker exec authlab-mongo1 mongosh --quiet --eval 'rs.initiate({_id: "rs0", members: [
  {_id: 0, host: "mongo1:27017"}, {_id: 1, host: "mongo2:27017"}, {_id: 2, host: "mongo3:27017"}]}).ok' >/dev/null
wait_rs
rs_summary
note "anyone who can reach the port can do anything"
mongosh_on b "mongodb://$RS_HOSTS/?replicaSet=rs0" 'db.getSiblingDB("admin").runCommand({listDatabases: 1}).databases.map(d => d.name)'

step "1. Create users first, while access control is still off"
docker exec -e PW="$MONGO_ADMIN_PASSWORD" authlab-mongo1 mongosh --quiet "mongodb://$RS_HOSTS/?replicaSet=rs0" --eval '
  db.getSiblingDB("admin").createUser({user: "admin", pwd: process.env.PW, roles: ["root"]})
  db.getSiblingDB("shop").createUser({user: "app", pwd: "app-pw", roles: ["readWrite"]})' >/dev/null
note "created admin (root) and app (readWrite on shop); nothing is enforced yet"
start_writers
sleep 5; mark; sleep 5
note "two writers on client-a, one without credentials and one as app:"
report

step "What if a member jumps straight to keyfile?"
restart_member_nowait() { echo "$2" > "runtime/state/$1.mode"; docker restart "authlab-$1" >/dev/null; }
S=$(for n in $MONGO_NODES; do [ "$(member_state "$n")" = SECONDARY ] && echo "$n"; done | head -1)
note "restarting $S with --keyFile only, then waiting 20s"
restart_member_nowait "$S" keyfile
sleep 20
P=$(primary_node)
docker exec "authlab-$P" mongosh --quiet --eval \
  'rs.status().members.forEach(m => print(`  ${m.name}  ${m.stateStr}  health=${m.health}  ${m.lastHeartbeatMessage || ""}`))'
note "the others can't authenticate to it and it can't authenticate to them: put it back"
restart_member "$S" none
mark

step "2. Roll every member to --keyFile --transitionToAuth"
roll_to transition
rs_summary
report
note "members now authenticate to each other with the keyfile, clients may still skip auth"

step "3. Switch every client to credentials, then roll to --keyFile"
note "(the anon writer stands for a client that was missed)"
roll_to keyfile
sleep 3
rs_summary
report

docker exec authlab-client-a sh -c 'pkill -f writer.js' || true
note "writers stopped; rs0 is back to the default lab state (keyfile, admin user)"
