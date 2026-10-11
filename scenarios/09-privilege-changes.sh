#!/usr/bin/env bash
# 09 When do privilege changes take effect? FLUSH PRIVILEGES, sessions that
# are already open, and MongoDB's user cache.
. "$(dirname "$0")/../scripts/lib.sh"

step "MySQL: GRANT and REVOKE need no FLUSH PRIVILEGES"
mysql_root <<'SQL'
DROP USER IF EXISTS 'dave'@'%', 'erin'@'%';
CREATE DATABASE IF NOT EXISTS shop;
CREATE TABLE IF NOT EXISTS shop.orders (id INT PRIMARY KEY, item VARCHAR(50));
INSERT IGNORE INTO shop.orders VALUES (1, 'book');
CREATE USER 'dave'@'%' IDENTIFIED BY 'dave-pw';
SQL
mysql_on a dave 'dave-pw' 'SELECT * FROM shop.orders'
mysql_root -e "GRANT SELECT ON shop.orders TO 'dave'@'%'"
note "GRANT SELECT ON shop.orders TO 'dave'@'%';   -- no FLUSH PRIVILEGES"
mysql_on a dave 'dave-pw' 'SELECT * FROM shop.orders'

step "MySQL: editing the grant tables directly does need it"
mysql_root -e "UPDATE mysql.user SET account_locked = 'Y' WHERE user = 'dave'"
note "UPDATE mysql.user SET account_locked = 'Y' WHERE user = 'dave';"
mysql_on a dave 'dave-pw' 'SELECT CURRENT_USER()'
mysql_root -e "FLUSH PRIVILEGES"
note "FLUSH PRIVILEGES;"
mysql_on a dave 'dave-pw' 'SELECT CURRENT_USER()'
mysql_root -e "ALTER USER 'dave'@'%' ACCOUNT UNLOCK"

step "MySQL: sessions that are already open"
mysql_root <<'SQL'
DROP USER IF EXISTS 'erin'@'%', 'gina'@'%', 'hank'@'%', 'ivy'@'%', 'jack'@'%';
DROP ROLE IF EXISTS 'shop_read';
GRANT SELECT ON shop.orders TO 'dave'@'%';
CREATE USER 'hank'@'%' IDENTIFIED BY 'hank-pw';
GRANT SELECT ON shop.* TO 'hank'@'%';
CREATE USER 'ivy'@'%' IDENTIFIED BY 'ivy-pw';
GRANT SELECT ON shop.* TO 'ivy'@'%';
CREATE USER 'erin'@'%' IDENTIFIED BY 'erin-pw';
GRANT SELECT ON *.* TO 'erin'@'%';
CREATE USER 'gina'@'%' IDENTIFIED BY 'gina-pw';
GRANT SESSION_VARIABLES_ADMIN ON *.* TO 'gina'@'%';
CREATE ROLE 'shop_read';
GRANT SELECT ON shop.* TO 'shop_read';
CREATE USER 'jack'@'%' IDENTIFIED BY 'jack-pw';
GRANT 'shop_read' TO 'jack'@'%';
SET DEFAULT ROLE 'shop_read' TO 'jack'@'%';
SQL
cat <<'EOF'
# each user opens one session, runs a statement, sleeps 4s, runs it again;
# at 2s their privilege is revoked
#   dave  table privilege       SELECT ON shop.orders
#   hank  database privilege    SELECT ON shop.*, session did USE shop
#   ivy   database privilege    SELECT ON shop.*, no USE
#   erin  static global         SELECT ON *.*
#   gina  dynamic global        SESSION_VARIABLES_ADMIN
#   jack  role                  shop_read (SELECT ON shop.*), active by default
EOF
session() {  # session USER DEFAULT_DB "STATEMENT" ["STATEMENT AFTER"]
  local u=$1 db=$2 q=$3 q2=${4:-$3}
  docker exec -e MYSQL_PWD="$u-pw" authlab-client-a mysql -h mysql -u "$u" -N --unbuffered $db -e \
    "$q; SELECT SLEEP(4) INTO @x; $q2" > "/tmp/authlab-$u.out" 2>&1 &
}
session dave ""   "SELECT 'before', COUNT(*) FROM shop.orders" "SELECT 'after', COUNT(*) FROM shop.orders"
session hank shop "SELECT 'before', COUNT(*) FROM orders" "SELECT 'after', COUNT(*) FROM orders; USE shop; SELECT 'after USE', COUNT(*) FROM orders"
session ivy  ""   "SELECT 'before', COUNT(*) FROM shop.orders" "SELECT 'after', COUNT(*) FROM shop.orders"
session erin ""   "SELECT 'before', COUNT(*) FROM shop.orders" "SELECT 'after', COUNT(*) FROM shop.orders"
session gina ""   "SET SESSION sql_log_bin = 1; SELECT 'before: SET ok'" "SET SESSION sql_log_bin = 1; SELECT 'after: SET ok'"
session jack ""   "SELECT 'before', COUNT(*) FROM shop.orders" "SELECT 'after', COUNT(*) FROM shop.orders"
sleep 2
mysql_root <<'SQL'
REVOKE SELECT ON shop.orders FROM 'dave'@'%';
REVOKE SELECT ON shop.* FROM 'hank'@'%';
REVOKE SELECT ON shop.* FROM 'ivy'@'%';
REVOKE SELECT ON *.* FROM 'erin'@'%';
REVOKE SESSION_VARIABLES_ADMIN ON *.* FROM 'gina'@'%';
REVOKE 'shop_read' FROM 'jack'@'%';
SQL
wait
for u in dave hank ivy erin gina jack; do
  cmd "[$u, same session]"
  sed 's/^/  /' "/tmp/authlab-$u.out"; rm -f "/tmp/authlab-$u.out"
done
note "a new session for erin"
mysql_on a erin 'erin-pw' 'SELECT COUNT(*) FROM shop.orders'

step "MongoDB: a revoked role stops working on connections that are already open"
mongo_admin --eval '
  const s = db.getSiblingDB("shop");
  try { s.dropUser("frank") } catch (e) {}
  s.createUser({user: "frank", pwd: "frank-pw", roles: ["read"]})' >/dev/null
note "frank reads, sleeps 4s, reads again on the same connection; at 2s the read role is revoked"
docker exec authlab-client-a mongosh --quiet "mongodb://frank:frank-pw@$RS_HOSTS/shop?replicaSet=rs0" --eval '
  print("before:", db.orders.countDocuments());
  sleep(4000);
  try { print("after:", db.orders.countDocuments()) } catch (e) { print("after:", e.message.split(",")[0]) }' \
  > /tmp/authlab-frank.out 2>&1 &
sleep 2
mongo_admin --eval 'db.getSiblingDB("shop").revokeRolesFromUser("frank", ["read"])' >/dev/null
wait
cmd "[frank, same connection]"
sed 's/^/  /' /tmp/authlab-frank.out; rm -f /tmp/authlab-frank.out

step "MongoDB: a new login restriction applies to connections that are already open"
mongo_admin --eval '
  const s = db.getSiblingDB("shop");
  try { s.dropUser("kim") } catch (e) {}
  s.createUser({user: "kim", pwd: "kim-pw", roles: ["read"]})' >/dev/null
note "kim reads from client-b, sleeps 4s, reads again; at 2s kim is restricted to client-a"
docker exec authlab-client-b mongosh --quiet "mongodb://kim:kim-pw@$RS_HOSTS/shop?replicaSet=rs0" --eval '
  print("before:", db.orders.countDocuments());
  sleep(4000);
  try { print("after:", db.orders.countDocuments()) } catch (e) { print("after:", e.message) }' \
  > /tmp/authlab-kim.out 2>&1 &
sleep 2
cmd '> db.getSiblingDB("shop").updateUser("kim", {authenticationRestrictions: [{clientSource: ["172.30.0.21"]}]})'
mongo_admin --eval 'db.getSiblingDB("shop").updateUser("kim", {authenticationRestrictions: [{clientSource: ["172.30.0.21"]}]})' >/dev/null
wait
cmd "[kim on client-b, same connection]"
sed 's/^/  /' /tmp/authlab-kim.out; rm -f /tmp/authlab-kim.out
log_attr "Removed user with unmet authentication restrictions" user 1

step "MySQL, for contrast: changing an account's host while its session is open"
mysql_root <<'SQL'
DROP USER IF EXISTS 'lee'@'%', 'lee'@'172.30.0.21';
CREATE USER 'lee'@'%' IDENTIFIED BY 'lee-pw';
GRANT SELECT ON shop.orders TO 'lee'@'%';
SQL
note "lee reads from client-b, sleeps 4s, reads again; at 2s 'lee'@'%' is renamed to 'lee'@'172.30.0.21'"
docker exec -e MYSQL_PWD=lee-pw authlab-client-b mysql -h mysql -u lee -N --unbuffered -e \
  "SELECT 'before', CURRENT_USER(), COUNT(*) FROM shop.orders; SELECT SLEEP(4) INTO @x; SELECT 'after', CURRENT_USER(), COUNT(*) FROM shop.orders;" \
  > /tmp/authlab-lee.out 2>&1 &
sleep 2
cmd "mysql> RENAME USER 'lee'@'%' TO 'lee'@'172.30.0.21';"
mysql_root -e "RENAME USER 'lee'@'%' TO 'lee'@'172.30.0.21'"
wait
cmd "[lee on client-b, same session]"
sed 's/^/  /' /tmp/authlab-lee.out; rm -f /tmp/authlab-lee.out
note "a new session from client-b"
mysql_on b lee 'lee-pw' 'SELECT 1'
