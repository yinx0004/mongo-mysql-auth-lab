#!/usr/bin/env bash
# MySQL vs MongoDB access control lab. Run ./lab.sh help for commands.
set -euo pipefail
cd "$(dirname "$0")"

init() {
  mkdir -p runtime/state
  if [ ! -f runtime/keyfile ]; then
    openssl rand -base64 756 | tr -d '\n' > runtime/keyfile
    chmod 600 runtime/keyfile
    echo "created runtime/keyfile"
  fi
  if [ ! -f .env ]; then
    printf 'MYSQL_ROOT_PASSWORD=%s\nMONGO_ADMIN_PASSWORD=%s\n' "$(openssl rand -hex 12)" "$(openssl rand -hex 12)" > .env
    chmod 600 .env
    echo "created .env with generated admin passwords"
  fi
}

init
# shellcheck source=scripts/lib.sh
. scripts/lib.sh

# Initiate rs0 and create the first admin user through the localhost exception:
# access control is on, no user exists yet, so a connection from inside a
# member is allowed to do exactly this.
rs_bootstrap() {
  if [ -z "$(docker exec authlab-mongo1 mongosh --quiet --eval 'db.hello().setName ?? ""')" ]; then
    docker exec authlab-mongo1 mongosh --quiet --eval '
      rs.initiate({_id: "rs0", members: [
        {_id: 0, host: "mongo1:27017"}, {_id: 1, host: "mongo2:27017"}, {_id: 2, host: "mongo3:27017"}]})' >/dev/null
    echo "initiated rs0"
  fi
  wait_rs
  if ! mongo_admin --eval 1 >/dev/null 2>&1; then
    local p; p=$(primary_node)
    docker exec -e PW="$MONGO_ADMIN_PASSWORD" "authlab-$p" mongosh --quiet admin --eval \
      'db.createUser({user: "admin", pwd: process.env.PW, roles: ["root"]})' >/dev/null
    echo "created admin user on rs0 (localhost exception on $p)"
  fi
}

sharded_bootstrap() {
  docker compose --profile sharded up -d --wait cfg shard1
  docker exec authlab-cfg mongosh --quiet --eval \
    'if (!db.hello().setName) rs.initiate({_id: "cfg", configsvr: true, members: [{_id: 0, host: "cfg:27017"}]})' >/dev/null
  docker exec authlab-shard1 mongosh --quiet --eval \
    'if (!db.hello().setName) rs.initiate({_id: "sh1", members: [{_id: 0, host: "shard1:27017"}]})' >/dev/null
  wait_primary cfg
  wait_primary shard1
  docker compose --profile sharded up -d --wait mongos
  local uri="mongodb://admin:${MONGO_ADMIN_PASSWORD}@mongos:27017/?authSource=admin"
  if ! docker exec authlab-mongos mongosh --quiet "$uri" --eval 1 >/dev/null 2>&1; then
    # Users created through mongos are stored on the config servers.
    docker exec -e PW="$MONGO_ADMIN_PASSWORD" authlab-mongos mongosh --quiet admin --eval \
      'db.createUser({user: "admin", pwd: process.env.PW, roles: ["root"]})' >/dev/null
    echo "created cluster admin user through mongos"
  fi
  docker exec authlab-mongos mongosh --quiet "$uri" --eval \
    'if (!db.getSiblingDB("config").shards.findOne({_id: "sh1"})) sh.addShard("sh1/shard1:27017")' >/dev/null
  echo "sharded cluster ready: mongos -> cfg, sh1"
}

case "${1:-help}" in
  up)
    docker compose up -d --build --wait
    rs_bootstrap
    echo "ready: mysql, rs0 (mongo1-3), client-a 172.30.0.21, client-b 172.30.0.22"
    ;;
  up-sharded)
    sharded_bootstrap
    ;;
  run)
    f=$(ls scenarios/"${2:?usage: ./lab.sh run NN}"-*.sh 2>/dev/null | head -1)
    [ -n "$f" ] || { echo "no scenario $2"; exit 1; }
    bash "$f"
    ;;
  status)
    echo "rs0:"; rs_summary
    docker exec authlab-mysql mysql --version 2>/dev/null | sed 's/^/mysql: /' || echo "mysql: down"
    if docker ps --format '{{.Names}}' | grep -q '^authlab-mongos$'; then echo "sharded: mongos, cfg, shard1 running"; fi
    ;;
  down)
    docker compose --profile sharded down
    ;;
  destroy)
    docker compose --profile sharded down -v
    rm -f runtime/state/*
    ;;
  help|*)
    cat <<'EOF'
./lab.sh up            start MySQL, the rs0 replica set and two clients
./lab.sh up-sharded    also start the sharded cluster (cfg, shard1, mongos)
./lab.sh run NN        run scenarios/NN-*.sh (see README)
./lab.sh status        replica set members and auth modes
./lab.sh down          stop everything, keep data
./lab.sh destroy       stop everything and delete all data
EOF
    ;;
esac
