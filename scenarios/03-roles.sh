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
note "fix: SET DEFAULT ROLE (or activate_all_roles_on_login = ON)"
mysql_root -e "SET DEFAULT ROLE 'app_read' TO 'bob'@'%'"
mysql_on a bob 'bob-pw' 'SELECT CURRENT_ROLE(); SELECT * FROM shop.orders'
note "MySQL can also grant a privilege straight to a user"
mysql_root -e "GRANT INSERT ON shop.orders TO 'bob'@'%'"
cmd "GRANT INSERT ON shop.orders TO 'bob'@'%'; SHOW GRANTS FOR 'bob'@'%';"
mysql_root --table -e "SHOW GRANTS FOR 'bob'@'%'"

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

step "MongoDB: userAdmin on a database is effectively owner of it"
mongo_admin --eval 'db.getSiblingDB("shop").createUser({user: "ua", pwd: "ua-pw", roles: ["userAdmin"]})' >/dev/null
note "ua only has userAdmin on shop, so it can't read data..."
mongosh_on a "mongodb://ua:ua-pw@$RS_HOSTS/shop?replicaSet=rs0" 'db.orders.findOne()'
note "...but it may grant itself any role on shop"
mongosh_on a "mongodb://ua:ua-pw@$RS_HOSTS/shop?replicaSet=rs0" 'db.grantRolesToUser("ua", ["dbOwner"]); db.orders.findOne()'
