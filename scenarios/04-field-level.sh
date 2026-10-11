#!/usr/bin/env bash
# 04 Hiding columns/fields: MySQL column privileges vs MongoDB views.
. "$(dirname "$0")/../scripts/lib.sh"

step "MySQL: privileges down to the column"
mysql_root <<'SQL'
DROP USER IF EXISTS 'carol'@'%';
CREATE DATABASE IF NOT EXISTS shop;
CREATE TABLE IF NOT EXISTS shop.customers (id INT PRIMARY KEY, name VARCHAR(50), phone VARCHAR(20), email VARCHAR(50));
INSERT IGNORE INTO shop.customers VALUES (1, 'Ann', '555-0101', 'ann@example.com');
CREATE USER 'carol'@'%' IDENTIFIED BY 'carol-pw';
GRANT SELECT (id, name) ON shop.customers TO 'carol'@'%';
SQL
note "GRANT SELECT (id, name) ON shop.customers TO 'carol'@'%';"
mysql_on a carol 'carol-pw' 'SELECT id, name FROM shop.customers'
mysql_on a carol 'carol-pw' 'SELECT * FROM shop.customers'
mysql_on a carol 'carol-pw' 'SELECT name, phone FROM shop.customers'

step "MongoDB: no field-level privilege, so grant a view instead"
cmd 'db.getSiblingDB("shop").createView("customers_public", "customers", [{$project: {phone: 0, email: 0}}])'
cmd 'db.getSiblingDB("shop").createRole({role: "publicReader", roles: [],
  privileges: [{resource: {db: "shop", collection: "customers_public"}, actions: ["find"]}]})'
mongo_admin --eval '
  const s = db.getSiblingDB("shop");
  try { s.dropUser("carol") } catch (e) {}
  try { s.dropRole("publicReader") } catch (e) {}
  s.customers_public.drop(); s.customers.drop()
  s.customers.insertOne({_id: 1, name: "Ann", phone: "555-0101", email: "ann@example.com"})
  s.createView("customers_public", "customers", [{$project: {phone: 0, email: 0}}])
  s.createRole({role: "publicReader", roles: [],
    privileges: [{resource: {db: "shop", collection: "customers_public"}, actions: ["find"]}]})
  s.createUser({user: "carol", pwd: "carol-pw", roles: ["publicReader"]})' >/dev/null
note "carol reads the view without any privilege on the underlying collection"
mongosh_on a "mongodb://carol:carol-pw@$RS_HOSTS/shop?replicaSet=rs0" 'db.customers_public.find().toArray()'
mongosh_on a "mongodb://carol:carol-pw@$RS_HOSTS/shop?replicaSet=rs0" 'db.customers.find().toArray()'
