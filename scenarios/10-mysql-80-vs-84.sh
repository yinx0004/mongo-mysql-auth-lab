#!/usr/bin/env bash
# 10 MySQL 8.0 vs 8.4: authentication-related differences. Starts a throwaway
# mysql:8.0 container next to the lab's 8.4 and runs the same statements.
. "$(dirname "$0")/../scripts/lib.sh"

docker rm -f authlab-mysql80 >/dev/null 2>&1
docker run -d --rm --name authlab-mysql80 --hostname mysql80 --network authlab_authlab \
  -e MYSQL_ROOT_PASSWORD=mysql80-root-pw mysql:8.0 >/dev/null
note "waiting for mysql:8.0 to initialize"
for _ in $(seq 1 90); do
  docker exec authlab-mysql80 mysqladmin ping -h 127.0.0.1 -uroot -pmysql80-root-pw --silent >/dev/null 2>&1 && break
  sleep 2
done
sleep 3

both() {  # both "SQL" : run as root on 8.0 and 8.4
  local sql=$1
  cmd "mysql> $sql"
  printf '  8.0: '; docker exec -e MYSQL_PWD=mysql80-root-pw authlab-client-a mysql -h mysql80 -uroot -N -e "$sql" 2>&1 | tr '\n\t' '  '; echo
  printf '  8.4: '; docker exec -e MYSQL_PWD="$MYSQL_ROOT_PASSWORD" authlab-client-a mysql -h mysql -uroot -N -e "$sql" 2>&1 | tr '\n\t' '  '; echo
}

step "Versions and authentication plugins"
both "SELECT VERSION()"
both "SELECT PLUGIN_STATUS FROM information_schema.PLUGINS WHERE PLUGIN_NAME = 'mysql_native_password'"
both "SELECT @@default_authentication_plugin"
both "SELECT @@authentication_policy"

step "An account with mysql_native_password"
both "DROP USER IF EXISTS 'legacy'@'%'; CREATE USER 'legacy'@'%' IDENTIFIED WITH mysql_native_password BY 'legacy-pw'; SELECT 'created'"

step "Replication: old syntax, and the privilege name"
both "SHOW SLAVE STATUS; SELECT 'ok'"
both "DROP USER IF EXISTS 'repl'@'%'; CREATE USER 'repl'@'%' IDENTIFIED BY 'repl-pw'; GRANT REPLICATION SLAVE ON *.* TO 'repl'@'%'; SHOW GRANTS FOR 'repl'@'%'"
both "DROP USER IF EXISTS 'repl2'@'%'; CREATE USER 'repl2'@'%' IDENTIFIED BY 'repl-pw'; GRANT REPLICATION REPLICA ON *.* TO 'repl2'@'%'; SELECT 'granted'"

docker exec -e MYSQL_PWD="$MYSQL_ROOT_PASSWORD" authlab-client-a mysql -h mysql -uroot -e \
  "DROP USER IF EXISTS 'legacy'@'%', 'repl'@'%', 'repl2'@'%'" 2>/dev/null
docker rm -f authlab-mysql80 >/dev/null
