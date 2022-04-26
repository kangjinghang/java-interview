# 第1章 etcd 介绍

etcd 是一个高可用的分布式 KV 系统，可以用来实现各种分布式协同服务。etcd 采用的一致性算法是 raft，基于 Go 语言实现。

etcd 最初由 CoreOS 的团队研发，目前是 Could Native 基金会的孵化项目。

为什么叫 etcd：etc来源于 UNIX 的 /etc 配置文件目录，d 代表 distributed system。

典型应用场景：

- Kubernetes 使用 etcd 来做服务发现和配置信息管理。
- Openstack 使用 etcd 来做配置管理和分布式锁。
- ROOK 使用 etcd 研发编排引擎。

etcd 和 ZooKeeper 覆盖基本一样的协同服务场景。ZooKeeper 因为需要把所有的数据都要加载到内存，一般存储几百MB的数据。etcd使用bbolt存储引擎，可以处理几个GB的数据。



# 第2章 etcd 原理

## 2.1 MVCC

etcd 的数据模型是 KV模型，所有的 key 构成了一个扁平的命名空间，所有的 key 通过字典序排序。

**整个 etcd 的 KV 存储维护一个递增的64位整数**。**etcd 使用这个整数位为每一次 KV 更新分配一个 revision**。每一个 key 可以有多个 revision。每一次更新操作都会生成一个新的 revision。删除操作会生成一个 tombstone 的新的 revision。如果 etcd 进行了compaction，etcd 会对 compaction revision 之前的 key-value 进行清理。**整个KV 上最新的一次更新操作的 revision 叫作整个 KV 的 revision。**

| Key  | CreateRevision | ModRevision | Version | Value |
| ---- | -------------- | ----------- | ------- | ----- |
| foo  | 10             | 10          | 1       | one   |
| foo  | 10             | 11          | 2       | two   |
| foo  | 10             | 12          | 3       | three |

CreateRevision 是创建 key 的 revision；ModRevsion 是更新 key 值的 revision；**Version 是 key 的版本号，从 1 开始**。

## 2.2 etcd 状态机

可以把 etcd 看做一个状态机。Etcd 的状态是所有的 key-value，revision 是状态的编号，每一个状态转换是若干个 key 的更新操作。

<img src="http://blog-1259650185.cosbj.myqcloud.com/img/202110/24/1635009476.png" alt="image-20211024011755982" style="zoom:50%;" />

## 2.3 etcd 数据存储

etcd 使用 bbolt 进行 KV 的存储。bbolt 使用持久化的 B+-tree 保存 key-value 。**三元组（major、sub、type）是 B+-tree 的 key**，major 是的 revision，sub 用来区别一次更新中的各个 key，type 保存可选的特殊值（例如 type 取值为 t 代表这个三元组对应的是一个
tombstone）。这样做的目的是为加速某一个 revision 上的 range 查找。

另外 etcd 还维护一个 in-memory 的 B-tree 索引，这个索引中的 key 是 key-value 中的key 。

## 2.4 安装配置 etcd

下面列出的是在 macOS 上安装配置 etcd 的步骤：

1. 从 https://github.com/etcd-io/etcd/releases 下载 etcd-v3.4.1-darwin-amd64.zip。
2. 把 etcd-v3.4.1-darwin-amd64.zip 加压到一个本地目录 {etcd-dir} 。
3. 把 {etcd-dir} 加到 PATH 环境变量。
4. 创建一个目录 {db-dir} 用来保存 etcd 的数据文件。
5. 因为我们要使用最新的 v3 API，把 export ETCDCTL_API=3 加到 ~/.zshrc。

在 {db-dir} 目录运行 etcd 启动 etcd 服务，让后在另外一个终端运行：

- etcdctl put foo bar
- etcdctl get foo
- etcdctl del foo

`etcdctl get "" --prefix=true` 可以用来扫描 etcd 的所有数据。

`etcdctl del "" --prefix=true` 可以用来删除 etcd 中的所有数据。

## 2.5 使用 etcd HTTP API

除了使用 etcdctl 工具访问 etcd，我们可以使用 etcd HTTP Rest API。

- http POST http://localhost:2379/v3/kv/put <<< '{"key": "Zm9v", "value": "YmFy"}'
- http POST http://localhost:2379/v3/kv/range <<< '{"key": "Zm9v"}'

Zm9v 是 foo 的 base64 编码， YmFy 是 bar 的 base64 编码。和 etcdctl 相比，etcd HTTP API 返回的数据更多，可以帮助我们学习 etcd API 的行为。



# 第3章 etcd API

etcd 使用 gRPC 提供对外 API。Etcd 官方提供一个 Go 客户端库。 Go 客户端库是对 gRPC 调用的封装，对于其他常见语言也有第三方提供的客户端库。另外 etcd 还用 gRPC gateway 对外提供了 HTTP API。可见 etcd 提供了丰富的客户端接入方式。ZooKeeper 的 RPC 是基于 jute 的，客户端只有 Java 版和 C 语言版，接入方式相少一些。

<img src="http://blog-1259650185.cosbj.myqcloud.com/img/202110/24/1635075245.png" alt="image-20211024193404998" style="zoom:50%;" />

和 ZooKeeper 的客户端库不同，etcd 的客户端不会自动和服务器端建立一个 session，但是可以使用 Lease API 来实现 session。

etcd 使用 gRPC 提供对外 API。etcd 的 API 分为三大类：

- KV：key-value 的创建、更新、读取和删除。
- Watch：提供监控数据更新的机制。
- Lease：用来支持来自客户端的 keep-alive 消息。

**Response Header**

所有的 RPC 响应都有一个 response header，Protobuf response header 包含以下信息：

- cluster_id: 创建响应的etcd集群 ID。
- member_id: 创建响应的etcd节点 ID。
- revision: 创建响应时 etcd KV 的 revision。
- raft_term：创建响应时的 raft term。

**KeyValue**

Key-value 是 etcd API 处理的最小数据单元，一个 Protobuf KeyValue 消息包含如下信息：

- key：key 的类型为字节 slice。
- create_revision：key-value 的创建 revision。
- mod_revision：key-value 的修改 revision。
- version：key-value 的版本，从1开始。
- value：value 的类型为字节 slice。
- lease：和 key-value 关联的 lease ID。0代表没有关联的 lease。

**Key Range**

key range [key, range_end) 代表从 key (包含) 到 range_end (不包含) 的 key 的区间。etcd API 使用可以 range 来检索 key-value。

- [x, x+‘\x00’) 代表单个 key a，例如 [‘a’, ‘a\x00’) 代表单个 key ‘a’。对应 ZooKeeper， 可以用 [‘/a’, ‘/a\x00’) 表示 ‘/a’ 这个节点。
- [x, x+1) 代表前缀为 x 的 key，例如 [‘a’, ‘b’) 代表所有前缀为 ‘a‘ 的 key。对应 ZooKeeper，可以用 [’/a/’, ‘/a0’) 来表示目录 ‘/a‘ 下所有的子孙节点，但是没有办法使用 range 表示 ‘/a‘ 下的所有孩子节点。
- [‘\x00’, ‘\x00’) 代表整个的 key 空间。
- [a, ‘\x00’) 代表所有不小于 a(非‘\x00’) 的 key。

## 3.1 KV 服务

KV 服务主要包含以下 API：

- Range：返回 range 区间中的 key-value。
- Put：写入一个 key-value。
- DeleteRange：删除 range 区间中的 key-value。
- Txn：提供一个 If/Then/Else 的原子操作，提供了一定程度的事务支持。

Range 和 DeleteRange 操作的对象是一个 key range，Put 操作的对象是单个的 key，Txn 的 If 中进行比较的对象也是单个的 key。

### 3.1.1 Range API

etcd 的 Range 默认执行 linearizable read，但是可以配置成 serializable read。ZooKeeper 的数据读取 API 只支持 serializable read。

### 3.1.2 Put API



## 3.2 Watch 和 Lease 部分

### 3.2.1 Txn API

Txn 是 etcd kv 上面的 If/Then/Else 原子操作。如果 If 中的 Compare 的交为 true，执行 Then 中的若干 RequestOp，否则执行 Else 中的若干 RequestOp。 

- 多个 Compare 可以使用多个 key。
- 多个 RequestOp 可以用来操作不同的 key，后面的 RequestOp 能读到前面 RequestOp 的执行结果。所有的更新 RequestOp 对应一个 revision。不能有多个更新的 RequestOp 操作一个 key。


Txn API 提供一个更新整个 etcd kv 的原子操作。Txn 的 If 语句检查 etcd kv 中若干 key 的状态，然后根据检查的结果更新整个 etcd kv。

### 3.2.2 Txn API 语法图

下图是简化的 Txn API 语法图。因为你缺少某个语句和语句为空是等价的，省略了缺少 If 语句、Then 语句和 Else 语句的情况。

- 如果 Then 为空或者 Else 为空，Txn 只有一个分支。
- 如果 If 为空的话，If 的结果为 true。

<img src="http://blog-1259650185.cosbj.myqcloud.com/img/202110/24/1635076637.png" alt="image-20211024195717348" style="zoom:50%;" />

ZooKeeper 对应 etcd Txn API 的 API 是条件更新。条件更新对应的语法图如下图所示。可以看出 Txn 要比条件更新灵活很多。条件更新只能对一个节点 A 的版本做比较，如果比较成功对 A 节点做 setData 或者 delete 操作。

<img src="http://blog-1259650185.cosbj.myqcloud.com/img/202110/24/1635076659.png" alt="image-20211024195739311" style="zoom:50%;" />

ZooKeeper 另外还有一个 Transaction API，可以原子执行一个操作序列，但是没有 Txn API 的条件执行操作的机制。

### 3.2.3 Watch API

Watch API 提供一个监控 etcd KV 更新事件的机制。etcd Watch 可以从一个历史的 revision 或者当前的 revision 开始监控一个 key range 的更新。

ZooKeeper 的 Watch 机制只能监控一个节点的当前时间之后的更新事件，但是 ZooKeeper 的 Watch 支持提供了对子节点更新的原生支持。etcd 没有对应的原生支持，但是可以用通过一个key range 来监控一个目录下所有子孙的更新。

### 3.2.4 Lease API

Lease 是用来检测客户端是否在线的机制。客户端可以通过发送 LeaseGrantRequest 消息向 etcd 集群申请 lease，每个 lease 有一个 TTL（time-to-live）。客户端可以通过发送 LeaseKeepAliveRequest 消息来延长自己的的 lease。如果 etcd 集群在 TTL 时间内没有收到来自客户端的 keep alive 消息，lease 就会过期。另外客户端也可以通过发送 LeaseRevokeRequest 消息给 etcd 集群来主动的放弃自己的租约。

可以把一个 lease 和一个 key 绑定在一起。在 lease 过期之后，关联的 key 会被删除，这个删除操作会生成一个 revision。

客户端可以通过不断发送 LeaseKeepAliveRequest 来维持一个和 etcd 集群的 session。和 lease 关联的 key 和 ZooKeeper 的临时性节点类似。



# 第4章 如何搭建一个 etcd 生产环境

一个 etcd 集群通常由奇数个节点组成。节点之间默认使用 TCP 2380 端口进行通讯，每个节点默认使用 2379 对外提供 gRPC 服务。

<img src="http://blog-1259650185.cosbj.myqcloud.com/img/202110/24/1635077443.png" alt="image-20211024201043662" style="zoom:50%;" />

## 4.1 clientv3-grpc1.23 架构

客户端有一个内置的 balancer。这个 balancer 和每一个 etcd 集群中的节点预先建立一个 TCP 连接。balancer 使用轮询策略向集群中的节点发送 RPC 请求。

<img src="http://blog-1259650185.cosbj.myqcloud.com/img/202110/24/1635077483.png" alt="image-20211024201123912" style="zoom:50%;" />

## 4.2 etcd gateway

etcd gateway 是一个4层代理。客户端可以通过 etcd gateway 访问 etcd 集群中的各个节点。这样在集群中成员节点发生变化，只要在 etcd gateway 上面更新一次 etcd 集群节点访问地址就可以了，用不重要每个客户端都更新。

对于来自客户端的每一个 TCP 连接，etcd gateway 采用轮询方式的选择一个 etcd 节点，把这个 TCP 连接代理到这个节点上。

<img src="http://blog-1259650185.cosbj.myqcloud.com/img/202110/24/1635077521.png" alt="image-20211024201201622" style="zoom:50%;" />

## 4.3 gRPC proxy

gRPC proxy 是一个7层代理，可以用来减少 etcd 集群的负载。gRPC proxy 除了合并客户端的watch API 和 lease API 的请求,并且会 cache 来自 etcd 集群的响应。gRPC proxy 会随机的选取选取集群中的一个节点建立连接。如果当前连接的节点失败， gRPC proxy 才会切换到集群中另外一个节点。

<img src="http://blog-1259650185.cosbj.myqcloud.com/img/202110/24/1635077559.png" alt="image-20211024201239379" style="zoom:50%;" />

