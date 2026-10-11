# MySQL vs MongoDB access control lab

本地实验环境，用来对照 MySQL 和 MongoDB 的账号、认证和授权模型。每个场景脚本对应文章的一节，可以重复运行，输出里保留真实的命令和报错。

## 环境

| 组件 | 版本 / 地址 | 说明 |
|---|---|---|
| MySQL | 8.4（`mysql:8.4`），172.30.0.5 | 默认 caching_sha2_password |
| MongoDB 副本集 rs0 | 8.0.4（`mongo:8.0.4`），mongo1-3 = 172.30.0.11-13 | keyfile 内部认证 |
| client-a / client-b | 172.30.0.21 / 172.30.0.22 | 都装了 mongosh 和 mysql 客户端，用来演示按 IP 限制登录 |
| 分片集群（可选） | cfg 172.30.0.31，shard1 172.30.0.32，mongos 172.30.0.33 | compose profile `sharded` |

MongoDB 固定在 8.0.4：后来的 8.0 镜像（比如 8.0.32）在 Linux 内核 ≥ 6.19 上会拒绝启动（[SERVER-121912](https://jira.mongodb.org/browse/SERVER-121912)），OrbStack 当前的内核就是这种。容器里设置了 `GLIBC_TUNABLES=glibc.pthread.rseq=0`，和官方 8.0 的 systemd unit 一样，用来消除 tcmalloc 的 rseq 启动警告。

没有映射任何端口到宿主机，所有连接都在容器之间进行。

## 用法

```bash
./lab.sh up            # MySQL + rs0 + 两个客户端；首次运行会生成 .env 和 keyfile
./lab.sh up-sharded    # 再加上分片集群（cfg、shard1、mongos）
./lab.sh run 01        # 运行场景 01（共 00 到 11）
./lab.sh status        # 各成员状态和认证模式
./lab.sh down          # 停止，保留数据
./lab.sh destroy       # 停止并删除所有数据
```

`.env`（MySQL root 和 MongoDB admin 的随机密码）和 `runtime/keyfile` 由 `lab.sh` 生成，已加入 `.gitignore`。场景里的演示用户使用固定的演示密码（如 `alice-shop`），方便在文章里引用。

每个 MongoDB 成员启动时读取 `runtime/state/<node>.mode`（`none` / `transition` / `keyfile`，默认 `keyfile`），存在 `runtime/state/<node>.key` 时用它代替共享 keyfile。场景 05、06、07 通过改这两个文件再重启成员来切换认证方式。

## 场景

| 脚本 | 内容 | 关键结论 |
|---|---|---|
| `00-authn-vs-authz.sh` | 认证和授权 | MySQL 必须先认证才有会话；MongoDB 开启访问控制后未认证的连接也能建立，只能执行 hello、ping 等命令。MongoDB 授权（`security.authorization`）是单独的开关，关闭时密码照样验证，但权限不检查，只读用户也能写入（用一个临时的无认证单机 mongod 演示） |
| `01-account-model.sh` | MySQL `'user'@'host'` 对比 MongoDB 用户 + 认证库 | MySQL 里同名不同 host 是两个账号；MongoDB 里同名不同认证库是两个用户。URI 路径里的库名会被当作默认 authSource，不写库名则默认 admin |
| `02-ip-restriction.sh` | 按来源 IP 限制登录 | MySQL 写在账号的 host 里；MongoDB 用 `authenticationRestrictions.clientSource`。MongoDB 客户端只看到 Authentication failed，原因在服务端另一条日志里 |
| `03-roles.sh` | 角色 | MySQL 8 的角色授予后要激活：`SET ROLE` 只作用于当前会话，`SET DEFAULT ROLE` 作用于以后的登录；MySQL 也能直接给用户授权；8.0 起 `SUPER` 被拆成动态权限（只能 `ON *.*`，存在 `mysql.global_grants`）；MongoDB 权限只能放在角色里，授予后立即生效。`userAdmin` 可以给自己授予该库任意角色。MongoDB 没有默认角色，`roles` 必填，`roles: []` 的用户只能通过认证 |
| `04-field-level.sh` | 隐藏列 / 字段 | MySQL 支持列级权限；MongoDB 没有字段级权限，用视图 + 只授权视图实现，用户不需要底层集合的权限 |
| `05-localhost-exception.sh` | 第一个用户怎么建（**会清空 rs0**） | 开启认证但没有用户时，本机连接可以 `rs.initiate` 和创建第一个用户，但不能读写数据；创建后例外立即关闭 |
| `06-transition-to-auth.sh` | 不停机开启认证（**会清空 rs0**） | 先建用户 → 滚动切到 `--transitionToAuth` → 客户端换成带账号 → 滚动切到 `--keyFile`。带账号的写入全程 0 错误；直接从无认证跳到 keyfile 的成员会失联 |
| `07-keyfile-rotation.sh` | keyfile 轮换（只轮换 rs0） | keyfile 可以写成 YAML 列表放多个 key。先滚动到 [旧, 新]，再滚动到 [新]，全程副本集健康；只给一个成员换新 key 会失联。新 key 写在 `runtime/state/mongo*.key`，共享 keyfile 和分片集群不受影响 |
| `08-sharded-users.sh` | 分片集群的用户（会自动启动 sharded profile） | 通过 mongos 建的用户存在 config server 上，直连分片用不了；分片自己没有用户时，本机例外仍然开放，应建分片本地管理员 |
| `09-privilege-changes.sh` | 权限变更什么时候生效 | MySQL 的 GRANT、REVOKE 立即生效，不需要 FLUSH PRIVILEGES；直接 UPDATE 授权表要 FLUSH 才生效。已打开的会话里：表级权限、动态全局权限、已激活的角色，收回后下一条语句就失效；静态全局权限（如 `SELECT ON *.*`）收回后在原会话里仍然有效；库级权限如果是会话当前所在的库（已 `USE`），要到下一次 `USE` 才失效。MongoDB 收回角色对已打开的连接立即生效；新加的登录来源限制会让已打开的、来源不符的连接变成未认证。对比：MySQL 用 `RENAME USER` 改主机，已打开的会话不断开，但权限跟着账号走，下一条语句被拒 |
| `10-mysql-80-vs-84.sh` | MySQL 8.0 和 8.4 的认证差异（临时起一个 mysql:8.0 容器） | 8.4 默认禁用 `mysql_native_password`，去掉了 `default_authentication_plugin` 和 `SHOW SLAVE STATUS` 等旧复制语法；`REPLICATION SLAVE` 权限名在两个版本都没变，`REPLICATION REPLICA` 都是语法错误 |
| `11-replication-user.sh` | MySQL 复制账号需要哪些权限（临时起一个 mysql:8.4 从库） | 只有 `REPLICATION SLAVE` 时复制完全正常；`REPLICATION CLIENT` 只是让账号能执行 `SHOW BINARY LOG STATUS`、`SHOW BINARY LOGS` 这类查看状态的语句，监控和高可用工具会用到 |

### 实验中观察到的细节

- 副本集成员之间用 keyfile 认证时，服务端日志记录的是 `__system@local` 用户、SCRAM-SHA-256 机制。
- mongosh 连接后会在后台执行 `admin.atlascli` 聚合和 `getParameter`，权限有限的用户会因此在服务端日志里留下 "Checking authorization failed"，可以忽略。
- 删除最后一个用户后，localhost exception 不会马上重新打开，要等 mongod 重启（场景 08 的清理步骤就是这样处理的）。
- MySQL `SELECT *` 碰到无权限的列时报的是表级错误 1142；明确选了无权限的列才会报列级错误 1143。
