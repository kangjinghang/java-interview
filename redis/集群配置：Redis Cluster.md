在数据库领域，当数据量大到一定程度后，我们总是绕不开分布式这个话题。这个问题牵扯很多方面，

- **分片策略（Sharding）**：分库分表？水平切片？垂直切片？
- **数据备份**：数据备份什么时候做？粒度是什么？怎样备份？
- **数据迁移**：当数据分布发生拓扑变化的时候，怎么把数据从原来的节点迁移到新的节点上？
- **集群管理**：如何管理整个集群，如何把用户请求定向到某个特定的节点上？

这些问题很很多不同的解法，在不同的使用场景，不同的数据库设计结构下有不同的选择。大体上讲，因为相对简单，NoSQL在这个方面的解决方案较传统SQL数据库使用更广泛。我们不妨来看看开源社区中使用最普遍的分布式解决方案之一：**Redis Cluster**，看看它是如何解决分布式的问题。

## Redis Cluster集群

Redis Cluster是一个Redis的分布式部署形式，使用数据分片的办法把数据分配到不同的节点；每个节点可以有自己的备份节点（一个或多个）。整个集群之上另有一个叫做Redis Sentinel的分布式组件用以提供更丰富的HA能力。

下面我们就前一个章节提到的问题来看看Redis Cluster的解决方案。

### 数据分片

Redis Cluster使用 **Slot** 的概念：作为一个KV系统，它把每个`key`的值`hash`成`0 ~ 16383`之间的一个数。这个`hash`值被用来确定对应的数据存储在哪个节点中。集群中的每个节点都存储了一份类似路由表的东西，描述每个节点所拥有的 `Slots`；当用户请求一个不在本机的key的时候，它可以根据这个路由表找到正确的服务节点，然后回复给用户一个`moved`，告知用户正确的服务节点。

- `slot = CRC16(key) % 16383`；
- 是集群内数据管理和迁移的最小单位，保证数据管理的粒度易于管理；
- 每个节点都知道`slot`在集群中的分布，并能把对应信息回复给无法服务的请求。
- 节点之间保持`Gossip`通信

下面图例就是一个简单的、最小的3节点Redis Cluster数据分配例子。

![Figure-1: Redis Cluster Example](http://blog-1259650185.cosbj.myqcloud.com/img/202203/31/1648717968.png)

### 数据备份

Redis的备份是最简单的`Master-Slave`备份。每个主节点都可以有若干个从节点跟随；从节点（`Replica`）可以提供高可靠性（`HA`)，也可以用作只读节点提供高吞吐量。

通过加入针对每个节点的复制备份能力，Redis Cluster在单个数据粒度上提供了高可用性。整个部署架构从前一张图中的简单分布式Sharding结构演变为下图中所示的结构。

![Figure-2: Redis Cluster with Replication](http://blog-1259650185.cosbj.myqcloud.com/img/202203/31/1648717969.png)

数据备份架构中，主节点把自己的状态通过`AOF`异步（缺省方式）传送给从节点。**多个从节点可以使用级联的方式传输数据**，而不用全部都从主节点获得，以此减轻对主节点的性能压力。从节点不光可以用来备份数据保证高可用，也可以担任只读节点的任务，提供压力分流。

### 数据迁移

Redis Cluster中的数据迁移又称作`Reshard`，一般是因为有节点的变化或者是做`load balancing`。简单的讲，Reshard就是把一些`slots`从一个节点转移到另一个节点。

`Reshard`的原理并不复杂：

1. 外部工具向某分片发出`migrate`命令，触发一个或者多个（3.2开始支持）key的迁移。
2. 接收到`migrate`命令的分片，即迁出分片，将对应的key进行序列化后发往迁入分片，并阻塞等待迁入分片的返回。
3. 迁入分片通过`restore-asking`命令将收到的key进行应用，并返回成功给迁出分片。
4. 迁出分片收到应答后，删除对应的key，并将`migrate`命令转化为`del`命令并同步给同步和记录到AOF中供replicas消费，完成迁移。

![Figure-3: Redis Cluster with Replication](http://blog-1259650185.cosbj.myqcloud.com/img/202203/31/1648717970.png)

上面图例就是一个Reshard的流程示意，我们用一个`string b`来指代若干个`slots`；图中的数字代表步骤的顺序。

### 集群管理

Redis Cluster集群管理引入了一个新的组件，叫做Redis Sentinel，在整个集群的纬度上提供高可用的能力。简单的讲，它类似一个集群的Registry，包含监控、报警、自动切换、配置管理等常见功能。另外，Sentinel本身也是分布式部署，采用多数派算法维持状态的一致性。

- Sentinels监视所有的数据节点
- Sentinels监视所有其他Sentinels
- 当Sentinels对节点宕机达成共识之后，选举出一个新的master（升级）并完成各种配置方面的联动

以我们在上面《数据备份》小节中的系统架构为基础，加上Sentinel，以及高可用的代理节点（HAProxy），就是一个典型的Redis Cluster部署形态。

<img src="http://mysql.taobao.org/monthly/pic/202004/2020-04-27-shu-redis-cluster-full.png" alt="Figure-4: Redis Cluster Typical Deployment" style="zoom:67%;" />

## 设计思路

### 性能为第一目标

- 每一次数据处理都是由负责当前slot的Master直接处理的，没有额外的网络开销

### 提高可用性

- **水平扩展**能力 ：由于slot的存在，增加机器节点时只需要将之前由其他节点处理的一部分slot重新分配给新增节点。**slot可以看做机器节点和用户数据之间的一个抽象层**。
- **故障恢复**：Slave会在需要的时候自动提升为Master

### 损失一致性

- Master与Slave之之间**异步复制**，即Master先向用户返回结果后再异步将数据同步给Slave，这就导致Master宕机后一部分已经返回用户的数据在新Master上不存在
- **网络分区**时，由于开始Failover前的超时时间，会有一部分数据继续写到马上要失效的Master上

## **功能实现**

### 1. 数据分片

我们已经知道数据会按照key哈希到不同的slot，而每个节点仅负责一部分的slot，客户端根据slot将请求交给不同的节点。将slots划分给不同节点的过程称为数据分片，对应的还可以进行分片的重新分配。这部分功能依赖外部调用命令：

#### 分片

- 对每个集群执行`CLUSTER ADDSLOTS slot [slot ...]`
- RedisCluster将命令指定的slots作为自己负责的部分

#### 再分配

再分配要做的是将一些slots从当前节点(**source**)迁移到其他节点(**target**)

- 对**target**执行`CLUSTER SETSLOT slot IMPORTING [node-id]`，target节点将对应slots记为importing状态；
- 对**source**执行`CLUSTER SETSLOT MIGRATING [node-id]`，source节点将对应slots记为migrating状态，与importing状态一同在之后的请求重定向中使用
- 获取所有要迁移slot对应的keys，`CLUSTER GETKEYSINSLOT slot count`
- 对**source** 执行`MIGRATE host port key db timeout REPLACE [KEYS key [key ...]]`
- MIGRATE命令会将所有的指定的key通过`RESTORE key ttl serialized-value REPLACE`迁移给**target**
- 对所有节点执行`CLUSTER SETSLOT slot NODE [node-id]`，申明**target**对这些slots的负责，并退出importing或migrating

### 2. 请求重定向

由于每个节点只负责部分slot，以及slot可能从一个节点迁移到另一节点，造成客户端有可能会向错误的节点发起请求。因此需要有一种机制来对其进行发现和修正，这就是请求重定向。有两种不同的重定向场景：

#### 2.1 MOVE

- ‘我’并不负责‘你’要的key，告诉’你‘正确的吧。
- 返回`CLUSTER_REDIR_MOVED`错误，和正确的节点。
- 客户端向该节点重新发起请求，注意这次依然又发生重定向的可能。

#### 2.2 ASK

- ‘我’负责请求的key，但不巧的这个key当前在migraging状态，且‘我’这里已经取不到了。告诉‘你’importing他的‘家伙’吧，去碰碰运气。
- 返回`CLUSTER_REDIR_ASK`，和importing该key的节点。
- 客户端向新节点发送`ASKING`，之后再次发起请求
- 新节点对发送过`ASKING`，且key已经migrate过来的请求进行响应

#### 2.3 区别

区分这两种重定向的场景是非常有必要的：

- MOVE，申明的是slot所有权的转移，收到的客户端需要更新其key-node映射关系
- ASK，申明的是一种**临时的状态**，所有权还并没有转移，客户端并不更新其映射关系。前面的加的ASKING命令也是申明其理解当前的这种临时状态

### 3. 状态检测及维护

Cluster中的每个节点都维护一份在自己看来当前整个集群的状态，主要包括：

- 当前集群状态
- 集群中各节点所负责的slots信息，及其migrate状态
- 集群中各节点的master-slave状态
- 集群中各节点的存活状态及不可达投票

当集群状态变化时，如新节点加入、slot迁移、节点宕机、slave提升为新Master，我们希望这些变化尽快的被发现，传播到整个集群的所有节点并达成一致。节点之间相互的心跳（PING，PONG，MEET）及其携带的数据是集群状态传播最主要的途径。

#### 3.1 心跳时机

Redis节点会记录其向每一个节点上一次发出ping和收到pong的时间，心跳发送时机与这两个值有关。通过下面的方式既能保证及时更新集群状态，又不至于使心跳数过多：

- 每次Cron向所有未建立链接的节点发送ping或meet
- 每1秒从所有已知节点中随机选取5个，向其中上次收到pong最久远的一个发送ping
- 每次Cron向收到pong超过timeout/2的节点发送ping
- 收到ping或meet，立即回复pong

#### 3.2 心跳数据

- Header，发送者自己的信息
  - 所负责slots的信息
  - 主从信息
  - ip port信息
  - 状态信息
- Gossip，发送者所了解的部分其他节点的信息
  - ping_sent， pong_received
  - ip， port信息
  - 状态信息，比如发送者认为该节点已经不可达，会在状态信息中标记其为PFAIL或FAIL

#### 3.3 心跳处理

1. 新节点加入

   - 发送meet包加入集群

   - 从pong包中的gossip得到未知的其他节点

   - 循环上述过程，直到最终加入集群

2. Slots信息

   - 判断发送者声明的slots信息，跟本地记录的是否有不同

   - 如果不同，且发送者epoch较大，更新本地记录

   - 如果不同，且发送者epoch小，发送Update信息通知发送者

3. Master slave信息
   - 发现发送者的master、slave信息变化，更新本地状态

4. 节点Fail探测

   - 超过超时时间仍然没有收到pong包的节点会被当前节点标记为PFAIL

   - PFAIL标记会随着gossip传播

   - 每次收到心跳包会检测其中对其他节点的PFAIL标记，当做对该节点FAIL的投票维护在本机

   - 对某个节点的PFAIL标记达到大多数时，将其变为FAIL标记并广播FAIL消息

> 注：Gossip的存在使得集群状态的改变可以更快的达到整个集群。每个心跳包中会包含多个Gossip包，那么多少个才是合适的呢，redis的选择是N/10，其中N是节点数，这样可以保证在PFAIL投票的过期时间内，节点可以收到80%机器关于失败节点的gossip，从而使其顺利进入FAIL状态。

#### 3.4 广播

当需要发布一些非常重要需要立即送达的信息时，上述心跳加Gossip的方式就显得捉襟见肘了，这时就需要向所有集群内机器的广播信息，使用广播发的场景：

- **节点的Fail信息**：当发现某一节点不可达时，探测节点会将其标记为PFAIL状态，并通过心跳传播出去。当某一节点发现这个节点的PFAIL超过半数时修改其为FAIL并发起广播。
- **Failover Request信息**：slave尝试发起FailOver时广播其要求投票的信息
- **新Master信息**：Failover成功的节点向整个集群广播自己的信息

### 4. 故障恢复（Failover）

当slave发现自己的master变为FAIL状态时，便尝试进行Failover，以期成为新的master。由于挂掉的master可能会有多个slave。Failover的过程需要经过类Raft协议的过程在整个集群内达到一致， 其过程如下：

- slave发现自己的master变为FAIL
- 将自己记录的集群currentEpoch加1，并广播Failover Request信息
- 其他节点收到该信息，只有master响应，判断请求者的合法性，并发送FAILOVER_AUTH_ACK，对每一个epoch只发送一次ack
- 尝试failover的slave收集FAILOVER_AUTH_ACK
- 超过半数后变成新Master
- 广播Pong通知其他集群节点

## 源码

### 1. 数据结构

##### clusterState, 从当前节点的视角来看的集群状态，每个节点维护一份

- myself：指针指向自己的clusterNode
- currentEpoch：当前节点见过的最大epoch，可能在心跳包的处理中更新
- nodes：当前节点感知到的所有节点，为clusterNode指针数组
- slots：slot与clusterNode指针映射关系
- migrating_slots_to, importing_slots_from：记录slots的迁移信息
- failover_auth_time, failover_auth_count, failover_auth_sent, failover_auth_rank, failover_auth_epoch：Failover相关

##### clusterNode，代表集群中的一个节点

- slots：位图，由当前clusterNode负责的slot为1
- salve, slaveof：主从关系信息
- ping_sent, pong_received：心跳包收发时间
- clusterLink *link：Node间的联接
- list *fail_reports：收到的节点不可达投票

##### clusterLink，负责处理网络上的一条链接来的内容

### 2. Redis启动过程中与Cluster相关内容

- 初始化或从文件中恢复cluster结构
- 注册集群间通信消息的处理函数：clusterProcessPacket
- 增加Cluster相关的Cron函数：clusterCron

### 3. 客户端请求重定向

- redis处理客户端命令的函数processCommand增加cluster的重定向内容
- 事务或多key中若落在不同slots，直接返回CLUSTER_REDIR_CROSS_SLOT
- 如果当前存在于migration状态，且有key不再当前节点，返回CLUSTER_REDIR_ASK
- 如果当前是import状态且客户端在ASKING状态，则返回可以处理，或者CLUSTER_REDIR_UNSTABLE
- 如果不是myself，则返回CLUSTER_REDIR_MOVED

### 4. 定时任务 clusterCron

- 对handshake节点建立Link，发送Ping或Meet
- 选择合适的clusterNode发送Ping
- 如果是从查看是否需要做Failover
- 统计并决定是否进行slave的迁移，来平衡不同master的slave数
- 判断所有pfail报告数是否过半数

### 5. 集群消息处理 clusterProcessPacket

- 根据收到的消息更新自己的epoch和slave的offset信息
- 处理MEET消息，使加入集群
- 从goosip中发现未知节点，发起handshake
- 对PING，MEET回复PONG
- 根据收到的心跳信息更新自己clusterState中的master-slave，slots信息
- 对FAILOVER_AUTH_REQUEST消息，检查并投票
- 处理FAIL，FAILOVER_AUTH_ACK，UPDATE信息

## 小结

**Less is more** 这个概念重要且真实。Redis Cluster的分布式设计非常简单，也正因为如此非常容易维护。它的每个组件都很简单，功能不多；可以很简单的实现分布式设计。整个系统设计方面，它省略了很多一致性方面的考虑，用以换取高性能和健壮性。



## 参考

[Redis · 最佳实践 · 集群配置：Redis Cluster](http://mysql.taobao.org/monthly/2020/04/07/)

Tutorial：[Redis Cluster Tutorial](http://redis.io/topics/cluster-tutorial)

Specification: [Redis Cluster Specification](http://redis.io/topics/cluster-spec)

Source Code：[Github](https://github.com/antirez/redis)

[Life in a Redis Cluster: Meet and Gossip with your neighbors](http://cristian.regolo.cc/2015/09/05/life-in-a-redis-cluster.html)
