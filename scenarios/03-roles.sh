#!/usr/bin/env bash
# 03 Roles: MySQL GRANT + roles that must be activated vs MongoDB roles only.
. "$(dirname "$0")/../scripts/lib.sh"

step "MySQL: a granted role does nothing until it is active"
mysql_root <<'SQL'
DROP USER IF EXISTS 'bob'@'%';
DROP ROLE IF EXISTS 'app_read';
CREATE DATABASE IF NOT EXISTS shop;
CREATE TABLE IF NOT EXISTS shop.orders (id INT PRIMARY KEY, item VARCHAR(50));
INSERT IGNORE INTO shop.orders VALUES (1, 'book');
CREATE ROLE 'app_read';
GRANT SELECT ON shop.* TO 'app_read';
CREATE USER 'bob'@'%' IDENTIFIED BY 'bob-pw';
GRANT 'app_read' TO 'bob'@'%';
SQL
note "CREATE ROLE 'app_read'; GRANT SELECT ON shop.* TO 'app_read'; GRANT 'app_read' TO 'bob'@'%';"
mysql_on a bob 'bob-pw' 'SHOW GRANTS; SELECT CURRENT_ROLE(); SELECT * FROM shop.orders'
note "SET ROLE activates it, for this session only"
mysql_on a bob 'bob-pw' "SET ROLE 'app_read'; SELECT CURRENT_ROLE(); SELECT * FROM shop.orders"
note "a new session starts without it"
mysql_on a bob 'bob-pw' 'SELECT CURRENT_ROLE()'
note "SET DEFAULT ROLE (or activate_all_roles_on_login = ON) activates it at every login"
mysql_root -e "SET DEFAULT ROLE 'app_read' TO 'bob'@'%'"
mysql_on a bob 'bob-pw' 'SELECT CURRENT_ROLE(); SELECT * FROM shop.orders'
note "MySQL can also grant a privilege straight to a user"
mysql_root -e "GRANT INSERT ON shop.orders TO 'bob'@'%'"
cmd "GRANT INSERT ON shop.orders TO 'bob'@'%'; SHOW GRANTS FOR 'bob'@'%';"
mysql_root --table -e "SHOW GRANTS FOR 'bob'@'%'"

step "MySQL: SUPER is split into dynamic privileges"
mysql_root -e "DROP USER IF EXISTS 'ops'@'%'; CREATE USER 'ops'@'%' IDENTIFIED BY 'ops-pw'"
mysql_on a root "$MYSQL_ROOT_PASSWORD" "GRANT SUPER ON *.* TO 'ops'@'%'; SHOW WARNINGS"
mysql_on a root "$MYSQL_ROOT_PASSWORD" "GRANT BINLOG_ADMIN ON shop.* TO 'ops'@'%'"
mysql_on a root "$MYSQL_ROOT_PASSWORD" "REVOKE SUPER ON *.* FROM 'ops'@'%'; GRANT SYSTEM_VARIABLES_ADMIN, CONNECTION_ADMIN ON *.* TO 'ops'@'%'; SELECT * FROM mysql.global_grants WHERE USER = 'ops'"

step "MongoDB: privileges only exist inside roles"
cmd 'db.getSiblingDB("shop").createRole({role: "orderReader", roles: [],
  privileges: [{resource: {db: "shop", collection: "orders"}, actions: ["find"]}]})'
mongo_admin --eval '
  const s = db.getSiblingDB("shop");
  for (const u of ["bob", "ua"]) { try { s.dropUser(u) } catch (e) {} }
  try { s.dropRole("orderReader") } catch (e) {}
  s.customers.drop(); s.customers.insertOne({_id: 1, name: "Ann"})
  s.createRole({role: "orderReader", roles: [],
    privileges: [{resource: {db: "shop", collection: "orders"}, actions: ["find"]}]})' >/dev/null
note "createUser has no field for privileges"
cmd 'db.getSiblingDB("shop").createUser({user: "bob", pwd: "bob-pw", roles: [],
  privileges: [{resource: {db: "shop", collection: "orders"}, actions: ["find"]}]})'
mongo_admin --eval '
  try {
    db.getSiblingDB("shop").createUser({user: "bob", pwd: "bob-pw", roles: [],
      privileges: [{resource: {db: "shop", collection: "orders"}, actions: ["find"]}]})
  } catch (e) { print(e.name + ": " + e.message) }'
mongo_admin --eval 'db.getSiblingDB("shop").createUser({user: "bob", pwd: "bob-pw", roles: ["orderReader"]})' >/dev/null
note "createUser({user: \"bob\", pwd: \"bob-pw\", roles: [\"orderReader\"]}) — active at once, nothing to switch on"
mongosh_on a "mongodb://bob:bob-pw@$RS_HOSTS/shop?replicaSet=rs0" 'db.orders.findOne()'
mongosh_on a "mongodb://bob:bob-pw@$RS_HOSTS/shop?replicaSet=rs0" 'db.customers.findOne()'

step "MongoDB: roles is required, and there is no default role"
cmd '> db.getSiblingDB("shop").runCommand({createUser: "nobody", pwd: "nobody-pw"})'
mongo_admin --eval '
  try { db.getSiblingDB("shop").dropUser("nobody") } catch (e) {}
  const r = db.getSiblingDB("shop").runCommand({createUser: "nobody", pwd: "nobody-pw"});
  print(r.ok ? "ok" : "MongoServerError: " + r.errmsg)' 2>&1 | sed 's/^MongoServerError: MongoServerError: /MongoServerError: /'
cmd '> db.getSiblingDB("shop").createUser({user: "nobody", pwd: "nobody-pw", roles: []})'
mongo_admin --eval 'db.getSiblingDB("shop").createUser({user: "nobody", pwd: "nobody-pw", roles: []}).ok'
note "nobody can authenticate, and do almost nothing else"
mongosh_on a "mongodb://nobody:nobody-pw@$RS_HOSTS/shop?replicaSet=rs0" 'db.runCommand({connectionStatus: 1}).authInfo'
mongosh_on a "mongodb://nobody:nobody-pw@$RS_HOSTS/shop?replicaSet=rs0" 'db.orders.findOne()'
mongosh_on a "mongodb://nobody:nobody-pw@$RS_HOSTS/shop?replicaSet=rs0" 'db.changeUserPassword("nobody", "new-pw")'

step "MongoDB: userAdmin on a database is effectively owner of it"
mongo_admin --eval 'db.getSiblingDB("shop").createUser({user: "ua", pwd: "ua-pw", roles: ["userAdmin"]})' >/dev/null
note "ua only has userAdmin on shop, so it can't read data..."
mongosh_on a "mongodb://ua:ua-pw@$RS_HOSTS/shop?replicaSet=rs0" 'db.orders.findOne()'
note "...but it may grant itself any role on shop"
mongosh_on a "mongodb://ua:ua-pw@$RS_HOSTS/shop?replicaSet=rs0" 'db.grantRolesToUser("ua", ["dbOwner"]); db.orders.findOne()'
