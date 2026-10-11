#!/usr/bin/env bash
# 02 Restricting where a user may log in from.
. "$(dirname "$0")/../scripts/lib.sh"

step "MySQL: the allowed host is written into the account"
mysql_root <<'SQL'
DROP USER IF EXISTS 'report'@'172.30.0.21';
CREATE USER 'report'@'172.30.0.21' IDENTIFIED BY 'report-pw';
SQL
note "CREATE USER 'report'@'172.30.0.21' IDENTIFIED BY 'report-pw';"
mysql_on a report 'report-pw' 'SELECT CURRENT_USER()'
mysql_on b report 'report-pw' 'SELECT CURRENT_USER()'

step "MongoDB: authenticationRestrictions.clientSource"
cmd 'db.getSiblingDB("admin").createUser({user: "report", pwd: "report-pw",
  roles: [{role: "read", db: "reports"}],
  authenticationRestrictions: [{clientSource: ["172.30.0.21"]}]})'
mongo_admin --eval '
  const a = db.getSiblingDB("admin");
  try { a.dropUser("report") } catch (e) {}
  a.createUser({user: "report", pwd: "report-pw", roles: [{role: "read", db: "reports"}],
    authenticationRestrictions: [{clientSource: ["172.30.0.21"]}]})' >/dev/null
mongosh_on a "mongodb://report:report-pw@$RS_HOSTS/?replicaSet=rs0&authSource=admin" 'db.runCommand({connectionStatus: 1}).authInfo.authenticatedUsers'
mongosh_on b "mongodb://report:report-pw@$RS_HOSTS/?replicaSet=rs0&authSource=admin" 'db.runCommand({connectionStatus: 1}).authInfo.authenticatedUsers'
auth_failures 1
note "the generic error hides the reason; a separate log line has it"
log_attr "unmet authentication restrictions" reason

note "the restriction is part of the user document, so usersInfo shows it"
mongo_admin --eval 'printjson(db.getSiblingDB("admin").getUser("report", {showAuthenticationRestrictions: true}).authenticationRestrictions)'
