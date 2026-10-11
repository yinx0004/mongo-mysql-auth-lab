#!/usr/bin/env bash
# 11 Which privileges does a MySQL replication user need? Starts a throwaway
# mysql:8.4 replica (server-id 2) that replicates from the lab's mysql.
. "$(dirname "$0")/../scripts/lib.sh"

src() { docker exec -e MYSQL_PWD="$MYSQL_ROOT_PASSWORD" authlab-client-a mysql -h mysql -uroot "$@" 2>&1; }
rep() { docker exec -e MYSQL_PWD=replica-root-pw authlab-client-a mysql -h replica -uroot "$@" 2>&1; }
as_repl() { docker exec -e MYSQL_PWD=repl-pw authlab-client-a mysql -h mysql -u repl "$@" 2>&1; }

docker rm -f authlab-replica >/dev/null 2>&1
docker run -d --rm --name authlab-replica --hostname replica --network authlab_authlab \
  -e MYSQL_ROOT_PASSWORD=replica-root-pw mysql:8.4 --server-id=2 >/dev/null
note "waiting for the replica to initialize"
for _ in $(seq 1 90); do
  docker exec authlab-replica mysqladmin ping -h 127.0.0.1 -uroot -preplica-root-pw --silent >/dev/null 2>&1 && break
  sleep 2
done
sleep 3

step "Replication user with only REPLICATION SLAVE"
src -e "DROP USER IF EXISTS 'repl'@'%'; DROP DATABASE IF EXISTS repltest;
        CREATE USER 'repl'@'%' IDENTIFIED BY 'repl-pw';
        GRANT REPLICATION SLAVE ON *.* TO 'repl'@'%';"
src --table -e "SHOW GRANTS FOR 'repl'@'%'"
read -r FILE POS <<<"$(src -N -e "SHOW BINARY LOG STATUS" | awk '{print $1, $2}')"
cmd "replica> CHANGE REPLICATION SOURCE TO SOURCE_HOST='mysql', SOURCE_USER='repl', SOURCE_PASSWORD='repl-pw',
           SOURCE_LOG_FILE='$FILE', SOURCE_LOG_POS=$POS, GET_SOURCE_PUBLIC_KEY=1;
replica> START REPLICA;"
rep -e "CHANGE REPLICATION SOURCE TO SOURCE_HOST='mysql', SOURCE_USER='repl', SOURCE_PASSWORD='repl-pw',
        SOURCE_LOG_FILE='$FILE', SOURCE_LOG_POS=$POS, GET_SOURCE_PUBLIC_KEY=1; START REPLICA;"
sleep 3
note "write two rows on the source"
src -e "CREATE DATABASE repltest; CREATE TABLE repltest.t (id INT PRIMARY KEY); INSERT INTO repltest.t VALUES (1), (2);"
sleep 3
cmd "replica> SHOW REPLICA STATUS\\G"
rep -e "SHOW REPLICA STATUS\G" | grep -E "Source_User:|Replica_IO_Running:|Replica_SQL_Running:|Last_IO_Error:|Last_SQL_Error:"
cmd "replica> SELECT COUNT(*) FROM repltest.t;"
rep -N -e "SELECT COUNT(*) FROM repltest.t" | sed 's/^/  /'

step "What REPLICATION CLIENT adds: status statements on the source"
for q in "SHOW BINARY LOG STATUS" "SHOW BINARY LOGS" "SHOW REPLICAS"; do
  cmd "[repl]\$ mysql -h mysql -u repl -p -e \"$q\""
  as_repl --table -e "$q" | head -5
done
note "GRANT REPLICATION CLIENT ON *.* TO 'repl'@'%';"
src -e "GRANT REPLICATION CLIENT ON *.* TO 'repl'@'%'"
cmd "[repl]\$ mysql -h mysql -u repl -p -e \"SHOW BINARY LOG STATUS\""
as_repl --table -e "SHOW BINARY LOG STATUS"

rep -e "STOP REPLICA" >/dev/null
docker rm -f authlab-replica >/dev/null
src -e "DROP USER IF EXISTS 'repl'@'%'; DROP DATABASE IF EXISTS repltest;" >/dev/null
