# Shared helpers for lab.sh and scenarios/*.sh (sourced, runs on the host).
LAB=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
cd "$LAB"
if [ -f .env ]; then set -a; . ./.env; set +a; fi

RS_HOSTS=mongo1:27017,mongo2:27017,mongo3:27017
ADMIN_URI="mongodb://admin:${MONGO_ADMIN_PASSWORD:-}@${RS_HOSTS}/?replicaSet=rs0&authSource=admin"
MONGO_NODES="mongo1 mongo2 mongo3"

step() { printf '\n\033[1;35m== %s ==\033[0m\n' "$*"; }
note() { printf '\033[2m# %s\033[0m\n' "$*"; }
cmd()  { printf '\033[36m%s\033[0m\n' "$*"; }

# Print a command as typed on a client box, run it, and report a non-zero exit
# without stopping the scenario (many steps are expected to fail).
#   mongosh_on a "mongodb://alice:pw@mongo1/shop" 'db.orders.findOne()'
mongosh_on() {
  local box=$1 uri=$2 js=$3 rc=0
  cmd "[client-$box]\$ mongosh \"$uri\" --eval '$js'"
  docker exec "authlab-client-$box" mongosh --quiet "$uri" --eval "$js" 2>&1 || rc=$?
  [ "$rc" -eq 0 ] || note "exit code $rc"
}

#   mysql_on a alice 'alice-pw' 'SELECT CURRENT_USER()'
mysql_on() {
  local box=$1 user=$2 pw=$3 sql=$4 rc=0
  cmd "[client-$box]\$ mysql -h mysql -u $user -p -e \"$sql\""
  docker exec -e MYSQL_PWD="$pw" "authlab-client-$box" mysql -h mysql -u "$user" --table --unbuffered -e "$sql" 2>&1 || rc=$?
  [ "$rc" -eq 0 ] || note "exit code $rc"
}

# Admin access for setup steps (not shown as part of the demo).
mysql_root()  { docker exec -i -e MYSQL_PWD="$MYSQL_ROOT_PASSWORD" authlab-client-a mysql -h mysql -u root "$@"; }
mongo_admin() { docker exec -i authlab-mongo1 mongosh --quiet "$ADMIN_URI" "$@"; }
# Admin connection straight to one member, e.g. to step it down.
mongo_admin_direct() {
  local node=$1; shift
  docker exec -i "authlab-$node" mongosh --quiet \
    "mongodb://admin:${MONGO_ADMIN_PASSWORD}@$node:27017/?authSource=admin&directConnection=true" "$@"
}

# hello needs no authentication, so these work in every auth mode.
member_state() {
  docker exec "authlab-$1" mongosh --quiet --eval \
    'const h = db.hello(); print(h.isWritablePrimary ? "PRIMARY" : h.secondary ? "SECONDARY" : "OTHER")' 2>/dev/null || echo DOWN
}
primary_node() {
  local n
  for n in $MONGO_NODES; do [ "$(member_state "$n")" = PRIMARY ] && { echo "$n"; return 0; }; done
  return 1
}

# Wait until a single-member set (cfg, shard1) is writable primary.
wait_primary() {
  local c=$1 i
  for i in $(seq 1 90); do
    [ "$(docker exec "authlab-$c" mongosh --quiet --eval 'db.hello().isWritablePrimary' 2>/dev/null)" = true ] && return 0
    sleep 1
  done
  echo "$c did not become primary within 90s; see: docker logs authlab-$c" >&2
  return 1
}

# Wait until every member is PRIMARY or SECONDARY and one of them is PRIMARY.
wait_rs() {
  local i n ok
  for i in $(seq 1 90); do
    ok=1
    for n in $MONGO_NODES; do
      case "$(member_state "$n")" in PRIMARY|SECONDARY) ;; *) ok=0 ;; esac
    done
    if [ "$ok" = 1 ] && primary_node >/dev/null; then return 0; fi
    sleep 1
  done
  echo "replica set not healthy after 90s" >&2
  return 1
}

# Restart one member in an auth mode (none | transition | keyfile).
# A primary is stepped down first so the restart doesn't cost a failed write.
restart_member() {
  local node=$1 mode=$2
  echo "$mode" > "runtime/state/$node.mode"
  if [ "$(member_state "$node")" = PRIMARY ]; then
    note "$node is primary: stepping it down first"
    mongo_admin_direct "$node" --eval 'rs.stepDown(30)' >/dev/null 2>&1 || true
  fi
  note "restarting $node with auth mode '$mode'"
  docker restart "authlab-$node" >/dev/null
  wait_rs
}

# Last N "Failed to authenticate" entries from the server logs. The client only
# sees a generic error; the log says why (UserNotFound, wrong password, ...).
#   auth_failures [N] [nodes...]
auth_failures() {
  local n=${1:-1}; shift || true
  local nodes=${*:-$MONGO_NODES} node
  for node in $nodes; do
    docker logs --since 2m "authlab-$node" 2>&1 | grep '"msg":"Failed to authenticate"' | sed "s/^/$node /"
  done | python3 -c '
import json, sys
rows = []
for line in sys.stdin:
    node, _, js = line.partition(" ")
    e = json.loads(js); a = e["attr"]
    rows.append((e["t"]["$date"], node, a.get("client"), a.get("user"), a.get("db"), a.get("error")))
for t, node, client, user, db, err in sorted(rows)[-int(sys.argv[1]):]:
    print(f"  [{node} log] client={client} user={user} db={db}\n    error: {err}")
' "$n"
}

# Last N log entries whose msg contains TEXT, showing one attr field.
#   log_attr "unmet authentication restrictions" reason [N]
log_attr() {
  local text=$1 field=$2 n=${3:-1} node
  for node in $MONGO_NODES; do
    docker logs --since 2m "authlab-$node" 2>&1 | grep -F "$text" | sed "s/^/$node /"
  done | python3 -c '
import json, sys
field, n = sys.argv[1], int(sys.argv[2])
rows = []
for line in sys.stdin:
    node, _, js = line.partition(" ")
    e = json.loads(js)
    rows.append((e["t"]["$date"], node, e["msg"], e["attr"].get(field)))
for t, node, msg, val in sorted(rows)[-n:]:
    print(f"  [{node} log] {msg}\n    {field}: {val}")
' "$field" "$n"
}

rs_summary() {
  local n
  for n in $MONGO_NODES; do
    printf '  %-7s %-10s mode=%s\n' "$n" "$(member_state "$n")" "$(cat "runtime/state/$n.mode" 2>/dev/null || echo keyfile)"
  done
}
