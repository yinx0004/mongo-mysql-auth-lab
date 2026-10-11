#!/usr/bin/env bash
# 01 Account model: MySQL 'user'@'host' vs MongoDB user + authentication database.
. "$(dirname "$0")/../scripts/lib.sh"

step "MySQL: the host is part of the account"
note "setup: two different accounts both named alice, with different passwords"
mysql_root <<'SQL'
DROP USER IF EXISTS 'alice'@'%', 'alice'@'172.30.0.21';
CREATE USER 'alice'@'%' IDENTIFIED BY 'alice-any-host';
CREATE USER 'alice'@'172.30.0.21' IDENTIFIED BY 'alice-client-a';
SQL
mysql_root --table -e "SELECT user, host FROM mysql.user WHERE user = 'alice'"

note "from client-a the more specific host matches first, so only its password works"
mysql_on a alice 'alice-client-a' 'SELECT USER(), CURRENT_USER()'
mysql_on a alice 'alice-any-host' 'SELECT USER(), CURRENT_USER()'
note "from client-b only 'alice'@'%' matches"
mysql_on b alice 'alice-any-host' 'SELECT USER(), CURRENT_USER()'

step "MongoDB: a user belongs to the database it was created in"
note "setup: alice in shop and alice in admin are two different users"
mongo_admin --eval '
  for (const d of ["shop", "admin"]) { try { db.getSiblingDB(d).dropUser("alice") } catch (e) {} }
  db.getSiblingDB("shop").createUser({user: "alice", pwd: "alice-shop", roles: [{role: "readWrite", db: "shop"}]})
  db.getSiblingDB("admin").createUser({user: "alice", pwd: "alice-admin", roles: [{role: "read", db: "reports"}]})
  db.getSiblingDB("shop").orders.drop()
  db.getSiblingDB("shop").orders.insertOne({_id: 1, item: "book"})' >/dev/null
note "all users live in admin.system.users; the _id is <authentication db>.<name>"
mongo_admin --eval '
  db.getSiblingDB("admin").system.users.find({user: "alice"}, {_id: 1, user: 1, db: 1, roles: 1})
    .forEach(u => print(JSON.stringify(u)))'

note "no host in the identity: client-b logs in exactly like client-a"
mongosh_on b "mongodb://alice:alice-shop@$RS_HOSTS/shop?replicaSet=rs0" 'db.orders.findOne()'

step "MongoDB: authSource, and the URI path that quietly sets it"
note "the database in the URI path doubles as the default authSource: shop here, which is right"
mongosh_on a "mongodb://alice:alice-shop@$RS_HOSTS/shop?replicaSet=rs0" 'db.orders.findOne()'
note "no database in the path: authSource falls back to admin, where alice has another password"
mongosh_on a "mongodb://alice:alice-shop@$RS_HOSTS/?replicaSet=rs0" 'db.getSiblingDB("shop").orders.findOne()'
auth_failures 1
note "fix: name the authentication database"
mongosh_on a "mongodb://alice:alice-shop@$RS_HOSTS/?replicaSet=rs0&authSource=shop" 'db.getSiblingDB("shop").orders.findOne()'

note "the reverse trap: the path names the database to work in, and becomes authSource too"
mongosh_on a "mongodb://alice:alice-admin@$RS_HOSTS/reports?replicaSet=rs0" 'db.getName()'
auth_failures 1
mongosh_on a "mongodb://alice:alice-admin@$RS_HOSTS/reports?replicaSet=rs0&authSource=admin" 'db.getName()'
