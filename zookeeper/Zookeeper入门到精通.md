# 第1章 Zookeeper入门

## 1.1 Zookeeper概述

Zookeeper 是一个开源的分布式的，为分布式框架提供协调服务的 Apache 项目。ZooKeeper 的设计目标是将那些复杂且容易出错的分布式一致性服务封装起来，构成一个高效可靠的原语集，并以一系列简单易用的接口提供给用户使用。

<img src="http://blog-1259650185.cosbj.myqcloud.com/img/202110/13/1634054597.png" alt="image-20211013000312033" style="zoom: 33%;" />

**ZooKeeper 发展历史**

ZooKeeper 最早起源于雅虎研究院的一个研究小组。在当时，研究人员发现，在雅虎内部很多大型系统基本都需要依赖一个类似的系统来进行分布式协同，但是这些系统往往都存在分布式单点问题。
所以，雅虎的开发人员就开发了一个通用的无单点问题的分布式协调框架，这就是 ZooKeeper。ZooKeeper 之后在开源界被大量使用，下面列出了 3 个著名开源项目是如何使用 ZooKeeper：

- Hadoop：使用 ZooKeeper 做Namenode的高可用。
- HBase：保证集群中只有一个 master，保存 hbase:meta表的位置，保存集群中的 RegionServer 列表。
- Kafka：集群成员管理，controller 节点选举。



**Zookeeper工作机制**

Zookeeper从设计模式角度来理解：是一个基于观察者模式设计的分布式服务管理框架，它**负责存储和管理大家都关心的数据**，然后**接受观察者的注册**，一旦这些数据的状态发生变化，Zookeeper就将**负责通知已经在Zookeeper上注册的那些观察者**做出相应的反应。基本流程如下：

1. 服务端启动时去注册信息（创建都是临时节点）
2. 客户端获取到当前在线服务器列表，并且注册监听
3. 当服务器节点下线后
4. 通知客户端：服务器节点上下线事件
5. 客户端重新再去获取服务器列表，并注册监听



## 1.2 Zookeeper特点

<img src="http://blog-1259650185.cosbj.myqcloud.com/img/202110/13/1634055244.png" alt="image-20211013001404862" style="zoom:50%;" />



1. Zookeeper：一个领导者（Leader），多个跟随者（Follower）组成的集群。 
2. 集群中只要有**半数以上**节点存活，Zookeeper集群就能正常服务。所以Zookeeper适合安装奇数台服务器。
3. 全局数据一致：每个Server保存一份相同的数据副本，Client无论连接到哪个Server，数据都是一致的。
4. 更新请求顺序执行，来自同一个Client的更新请求按其发送顺序依次执行。
5. 数据更新原子性，一次数据更新要么成功，要么失败。
6. 实时性，在**一定时间范围内**（follower同步数据的过程），Client能读到最新数据。



## 1.3 Zookeeper数据结构

ZooKeeper 数据模型的结构与 **Unix 文件系统很类似**，整体上可以看作是一棵树，每个节点称做一个 ZNode。每一个 ZNode 默认能够存储 **1MB** 的数据，每个 ZNode 都可以**通过其路径唯一标识**。

<img src="http://blog-1259650185.cosbj.myqcloud.com/img/202110/13/1634055606.png" alt="image-20211013002006625" style="zoom:50%;" />

ZooKeeper 的数据模型是层次模型（Google Chubby也是这么做的）。层次模型常见于文件系统。层次模型和 key-value模型是两种主流的数据模型。ZooKeeper 使用文件系统模型主要基于以下两点考虑：
1. 文件系统的树形结构便于表达数据之间的层次关系。
2. 文件系统的树形结构便于为不同的应用分配独立的命名空间（namespace），这样各个应用之间不会互相依赖。

ZooKeeper 的层次模型称作 data tree。Data tree  的每个节点叫作 znode。不同于文件系统，每个节点都可以保存数据。每个节点都有一个版本  (version)。版本从 0 开始计数。

### 1.3.1 data tree接口

ZooKeeper 对外提供一个用来访问 data tree的简化文件系统 API：

- 使用 UNIX 风格的路径名来定位 znode,例如 /A/X 表示 znode A的子节点 X。
- znode的数据只支持全量写入和读取，没有像通用文件系统那样支持部分写入和读取。
- data tree的所有 API 都是 wait-free的，正在执行中的 API 调用不会影响其他 API 的完成。
- data tree的 API 都是对文件系统的 wait-free操作，不直接提供锁这样的分布式协同机制。但 是 data tree的 API 非常强大，可以用来实现多种分布式协同机制。

### 1.3.2 znode分类

一个 znode 可以使持久性的，也可以是临时性的：
1. 持久性的 znode (PERSISTENT): ZooKeeper 宕机，或者 client 宕机，这个 znode一旦创建就不会丢失。

2. 临时性的 znode (EPHEMERAL): ZooKeeper 宕机了，或者 client 在指定的 timeout 时间内没有连接 server ，都会被认为丢失。
znode节点也可以是顺序性的。每一个顺序性的 znode 关联一个唯一的单调递增整数。这个单调递增整数是 znode 名字的后缀。如果上面两种 znode 如果具备顺序性，又有以下两种 znode：

3. 持久顺序性的 znode(PERSISTENT_SEQUENTIAL): znode 除了具备持久性 znode 的特点之外，znode 的名字具备顺序性。

4. 临时顺序性的 znode(EPHEMERAL_SEQUENTIAL): znode 除了具备临时性 znode 的特点之外，znode的名字具备顺序性。

ZooKeeper 主要有以上 4 种 znode。

### 1.3.3 ZooKeeper 节点本地存储架构

<img src="http://blog-1259650185.cosbj.myqcloud.com/img/202110/23/1634986612.png" alt="image-20211023185652182" style="zoom:50%;" />

### 1.3.4 zxid

每一个对 ZooKeeper data tree 都会作为一个事务执行。每一个事务都有一个 zxid。zxid 是一个 64 位的整数（Java long 类型）。zxid 有两个组成部分，高 4 个字节保存的是 epoch ， 低 4 个字节保存的是 counter 。

<img src="http://blog-1259650185.cosbj.myqcloud.com/img/202110/23/1634986688.png" alt="image-20211023185808484" style="zoom:50%;" />

  

## 1.4 Zookeeper应用场景

提供的服务包括：统一命名服务、统一配置管理（configurationmanagement）、统一集群管理理（groupmembership）、服务器节点动态上下线、软负载均衡等。

### 1.4.1 统一命名服务

在分布式环境下，经常需要对应用/服务进行统一命名，便于识别。
例如：IP不容易记住，而域名容易记住。

<img src="http://blog-1259650185.cosbj.myqcloud.com/img/202110/13/1634055738.png" alt="image-20211013002218700" style="zoom:50%;" />

### 1.4.2 统一配置管理

分布式环境下，配置文件同步非常常见。

- 一般要求一个集群中，所有节点的配置信息是一致的，比如 Kafka 集群。

- 对配置文件修改后，希望能够快速同步到各个节点上。

配置管理可交由ZooKeeper实现。

1. 可将配置信息写入ZooKeeper上的一个Znode。
2. 各个客户端服务器监听这个Znode。
3. 一旦Znode中的数据被修改，ZooKeeper将通知各个客户端服务器。

<img src="http://blog-1259650185.cosbj.myqcloud.com/img/202110/13/1634055948.png" alt="image-20211013002548252" style="zoom:50%;" />

### 1.4.3 统一集群管理

分布式环境中，实时掌握每个节点的状态是必要的。可根据节点实时状态做出一些调整。

ZooKeeper可以实现实时监控节点状态变化。

1. 可将节点信息写入ZooKeeper上的一个ZNode。
2. 监听这个ZNode可获取它的实时状态变化。

<img src="http://blog-1259650185.cosbj.myqcloud.com/img/202110/13/1634056075.png" alt="image-20211013002755782" style="zoom:50%;" />

### 1.4.4 服务器动态上下线

客户端能实时洞察到服务器上下线的变化。

<img src="http://blog-1259650185.cosbj.myqcloud.com/img/202110/13/1634056145.png" alt="image-20211013002905508" style="zoom:50%;" />

### 1.4.5 软负载均衡

在Zookeeper中记录每台服务器的访问数，让访问数最少的服务器去处理最新的客户端请求。

<img src="http://blog-1259650185.cosbj.myqcloud.com/img/202110/21/1634829839.png" alt="1634056194" style="zoom:50%;" />



## 1.6 ZooKeeper 总体架构

应用使用  ZooKeeper 客户端库使用 ZooKeeper 服务。 ZooKeeper 客户端负责和 ZooKeeper 集群的交互。 ZooKeeper 集群可以有两种模式：**standalone** 模式和 **quorum**模式。处于 standalone  模式的 ZooKeeper 集群只有一个独立运行的 ZooKeeper 节点。处于 quorum 模式的 ZooKeeper 集群包换多个 ZooKeeper 节点。

<img src="http://blog-1259650185.cosbj.myqcloud.com/img/202110/22/1634832972.png" alt="image-20211022001612207" style="zoom:50%;" />

### 1.6.1 Session

ZooKeeper 客户端库和 ZooKeeper 集群中的节点创建一个 session。客户端可以主动关闭 session。另外如果ZooKeeper 节点没有在 session关联的 timeout 时间内收到客户端的数据的话， ZooKeeper 节点也会关闭 session。另外ZooKeeper 客户端库如果发现连接的 ZooKeeper 出错，会自动的和其他 ZooKeeper 节点建立连接。

<img src="http://blog-1259650185.cosbj.myqcloud.com/img/202110/22/1634833035.png" alt="image-20211022001715250" style="zoom:50%;" />

### 1.6.2 Quorum模式

处于 Quorum 模式的 ZooKeeper 集群包含多个 ZooKeeper 节点。 下图的 ZooKeeper 集群有 3 个节点，其中节点 1 是 leader 节点，节点 2 和节点 3 是 follower 节点。 leader 节点可以处理读写请求，follower 只可以处理读请求。 follower 在接到写请求时会把写请求转发给 leader 来处理。

<img src="http://blog-1259650185.cosbj.myqcloud.com/img/202110/22/1634833094.png" alt="image-20211022001814831" style="zoom:50%;" />

### 1.6.3 数据一致性

- 可线性化（Linearizable）写入：先到达 leader 的写请求会被先处理，leader 决定写请求的执行顺序。 
- 客户端 FIFO顺序：来自给定客户端的请求按照发送顺序执行。



# 第2章 配置参数解读

Zookeeper中的配置文件zoo.cfg中参数含义解读如下：

1. tickTime = 2000：通信心跳时间，Zookeeper服务器与客户端心跳时间，单位毫秒。

   <img src="http://blog-1259650185.cosbj.myqcloud.com/img/202110/13/1634056357.png" alt="image-20211013003237793" style="zoom:50%;" />

2. initLimit = 10：Leader、Follower初始通信时限。

   <img src="http://blog-1259650185.cosbj.myqcloud.com/img/202110/13/1634056416.png" alt="image-20211013003336140" style="zoom:50%;" />

   Leader和Follower**初始连接**时能容忍的最多心跳数（tickTime的数量）

3. syncLimit = 5：Leader、Follower同步通信时限

   <img src="http://blog-1259650185.cosbj.myqcloud.com/img/202110/13/1634056416.png" alt="image-20211013003336140" style="zoom:50%;" />

   Leader和Follower之间通信时间如果超过syncLimit * tickTime，Leader认为Follwer死掉，从服务器列表中删除Follwer。

4. dataDir：来保存快照文件的目录。如果没有设置 dataLogDir ，事务日志文件也会保存到这个目录。

   注意：默认的tmp目录，容易被Linux系统定期删除，所以一般不用默认的tmp目录。

5. dataLogDir：用来保存事务日志文件的目录。因为 ZooKeeper 在提交一个事务之前，需要保证事务日志记录的落盘，所以需要为 dataLogDir 分配一个独占的存储设备。

6. clientPort = 2181：ZooKeeper 对客户端提供服务的端口，通常不做修改。



# 第3章 Zookeeper集群操作

## 3.1 集群配置解读

zoo.cfg增加如下配置：

````
#######################cluster##########################
server.2=hadoop102:2888:3888
server.3=hadoop103:2888:3888
server.4=hadoop104:2888:3888
````

`server.A=B:C:D `

- A 是一个数字，表示这个是第几号服务器；集群模式下配置一个文件 myid，这个文件在 dataDir 目录下，这个文件里面有一个数据
  就是 A 的值，Zookeeper 启动时读取此文件，拿到里面的数据与 zoo.cfg 里面的配置信息比
  较从而判断到底是哪个 server。
- B 是这个服务器的地址；
- C 是这个服务器 Follower 与集群中的 Leader 服务器交换信息的端口；
- D 是万一集群中的 Leader 服务器挂了，需要一个端口来重新进行选举，选出一个新的 Leader，而这个端口就是用来执行选举时服务器相互通信的端口。



## 3.2 如何进行 ZooKeeper 的监控

### 3.2.1 The Four Letter Words

一组检查 ZooKeeper 节点状态的命令。每个命令由四个字母组成，可以通过 telnet 或 ncat使用客户端端口向 ZooKeeper 发出命令。

### 3.2.2 JMX

ZooKeeper 很好的支持了 JMX ，大量的监控和管理工作多可以通过 JMX 来做。

`echo ruok | netcat 10.10.201.101 2181`



## 3.3 选举机制

### 3.3.1 第一次启动

<img src="http://blog-1259650185.cosbj.myqcloud.com/img/202110/13/1634140762.png" alt="image-20211013235922433" style="zoom:50%;" />

**名次解释**：

- SID：**服务器ID**。用来唯一标识一台 ZooKeeper 集群中的机器，每台机器不能重复，**和 myid 一致**。
- ZXID：事务ID。**ZXID 是一个事务ID，用来标识一次服务器状态的变更**。在某一时刻，集群中的每台机器的 ZXID 值不一定完全一
  致，这和 ZooKeeper 服务器对于客户端“更新请求”的处理逻辑有关。
- Epoch：**每个 Leader 任期的代号**。没有 Leader 时同一轮投票过程中的逻辑时钟值是相同的。每投完一次票这个数据就会增加。

**选举流程**：

1. 服务器1启动，发起一次选举。服务器1投自己一票。此时服务器1票数一票，不够半数以上（3票），选举无法完成，服务器1状态保持为 LOOKING。
2. 服务器2启动，再发起一次选举。服务器1和2分别投自己一票并交换选票信息：**此时服务器1发现服务器2的myid比自己目前投票推举的（服务器1） 大，更改选票为推举服务器2**。此时服务器1票数0票，服务器2票数2票，没有半数以上结果，选举无法完成，服务器1，2状态保持 LOOKING。
3. 服务器3启动，发起一次选举。此时服务器1和2都会更改选票为服务器3。此次投票结果：服务器1为0票，服务器2为0票，服务器3为3票。此时服务器3的票数已经超过半数，服务器3当选 Leader。服务器1，2更改状态为 FOLLOWING，服务器3更改状态 LEADING。
4. 服务器4启动，发起一次选举。此时服务器1，2，3已经不是 LOOKING 状态，不会更改选票信息。交换选票信息结果：服务器3为3票，服务器4为 1票。此时服务器4服从多数，更改选票信息为服务器3，并更改状态为 FOLLOWING。
5. 服务器5启动，同4一样当小弟。

### 3.3.2 非第一次启动

<img src="http://blog-1259650185.cosbj.myqcloud.com/img/202110/14/1634141101.png" alt="image-20211014000501814" style="zoom:50%;" />

**选举流程**：

1. 当ZooKeeper集群中的一台服务器出现以下两种情况之一时，就会开始进入Leader选举：

   - 服务器初始化启动。
   - 服务器运行期间无法和Leader保持连接。

2. 而当一台机器进入Leader选举流程时，当前集群也可能会处于以下两种状态：

   - 集群中本来就已经存在一个 Leader。

     对于第一种已经存在 Leader 的情况，机器试图去选举 Leader 时，因为需要达到半数以上，会与其他服务器进行通讯，会被告知当前服务器的 Leader 信息，对于该机器来说，仅仅需要和Leader机器建立连接，直到连接上为止，并进行状态同步即可。

   - **集群中确实不存在Leader**。

     假设ZooKeeper由5台服务器组成，SID分别为1、2、3、4、5，ZXID分别为8、8、8、7、7，并且此时SID为3的服务器是Leader。某一时刻，3和5服务器出现故障，因此开始进行Leader选举。

     ​													    （EPOCH，ZXID，SID ）       （EPOCH，ZXID，SID ）    （EPOCH，ZXID，SID ）

     SID为1、2、4的机器投票情况： （1，8，1）                             （1，8，2）                         （1，7，4） 

     选举Leader规则： 

     1. EPOCH大的直接胜出 
     2. EPOCH相同，事务id大的胜出
     3. 事务id相同，服务器id大的胜出

     因此，服务器2胜出，变为 Leader。



## 3.4 客户端命令行操作

### 3.4.1 命令行语法

| 命令基本语法 | 功能描述                                                     |
| ------------ | ------------------------------------------------------------ |
| help         | 显示所有操作命令                                             |
| ls path      | 使用 ls 命令来查看当前 znode 的子节点 [可监听] <br />-w 监听子节点变化<br />-s 附加次级信息 |
| create       | 普通创建<br />-s 含有序列<br />-e 临时（重启或者超时消失）   |
| get path     | 获得节点的值 [可监听] <br />-w 监听节点内容变化<br />-s 附加次级信息 |
| set          | 设置节点的具体值                                             |
| stat         | 查看节点状态                                                 |
| delete       | 删除节点                                                     |
| deleteall    | 递归删除节点                                                 |

**启动客户端**

```shell
[atguigu@hadoop102 zookeeper-3.5.7]$ bin/zkCli.sh -server 
hadoop102:2181
```

**显示所有操作命令**

```shell
[zk: hadoop102:2181(CONNECTED) 1] help
```

### 3.4.2  znode 节点数据信息

**查看当前znode中所包含的内容**

```shell
[zk: hadoop102:2181(CONNECTED) 0] ls /
[zookeeper]
```

**查看当前节点详细数据**

```shell
[zk: hadoop102:2181(CONNECTED) 5] ls -s /
[zookeeper]cZxid = 0x0
ctime = Thu Jan 01 08:00:00 CST 1970
mZxid = 0x0
mtime = Thu Jan 01 08:00:00 CST 1970
pZxid = 0x0
cversion = -1
dataVersion = 0
aclVersion = 0
ephemeralOwner = 0x0
dataLength = 0
numChildren = 1
```

1. **czxid：创建节点的事务 zxid**。
   每次修改 ZooKeeper 状态都会产生一个 ZooKeeper 事务 ID。事务 ID 是 ZooKeeper 中所有修改总的次序。每次修改都有唯一的 zxid，如果 zxid1 小于 zxid2，那么 zxid1 在 zxid2 之前发生。
2. ctime：znode 被创建的毫秒数（从 1970 年开始）。
3. mzxid：znode 最后更新的事务 zxid。
4. mtime：znode 最后修改的毫秒数（从 1970 年开始）。
5. **pZxid：znode 最后更新的子节点 zxid**。
6. cversion：znode 子节点变化号，znode 子节点修改次数。
7. **dataversion：znode 数据变化号**。
8. aclVersion：znode 访问控制列表的变化号。
9. ephemeralOwner：如果是临时节点，这个是 znode 拥有者的 session id。如果不是临时节点则是 0。
10. **dataLength：znode 的数据长度**。
11. **numChildren：znode 子节点数量**。

### 3.4.3 节点类型（持久/临时/有序号/无序号）

<img src="http://blog-1259650185.cosbj.myqcloud.com/img/202110/14/1634142470.png" alt="image-20211014002750295" style="zoom:50%;" />

- 持久（Persistent）：客户端和服务器端断开连接后，创建的节点不删除。
- 临时（Ephemeral）：客户端和服务器端断开连接后，创建的节点自己删除。

说明：创建znode时如果设置顺序标识的话，znode名称后会附加一个值，顺序号是一个单调递增的计数器，由父节点维护。

**注意：在分布式系统中，顺序号可以被用于为所有的事件进行全局排序，这样客户端可以通过顺序号推断事件的顺序。**

4种节点类型：

1. 持久化目录节点：客户端与Zookeeper断开连接后，该节点依旧存在。
2. 持久化顺序编号目录节点：客户端与Zookeeper断开连接后，该节点依旧存在，只是Zookeeper给该节点名称进行顺序编号。
3. 临时目录节点：客户端与Zookeeper断开连接后，该节点被删除。
4. 客户端与 Zookeeper 断开连接后 ，该节点被删除 ，只是Zookeeper给该节点名称进行顺序编号。

**分别创建2个普通节点（永久节点 + 不带序号）**

```shell
[zk: localhost:2181(CONNECTED) 3] create /sanguo "diaochan"
Created /sanguo
[zk: localhost:2181(CONNECTED) 4] create /sanguo/shuguo "liubei"
Created /sanguo/shuguo
```

注意：创建节点时，要赋值。

**获得节点的值**

```shell

[zk: localhost:2181(CONNECTED) 5] get -s /sanguo
diaochan
cZxid = 0x100000003
ctime = Wed Aug 29 00:03:23 CST 2018
mZxid = 0x100000003
mtime = Wed Aug 29 00:03:23 CST 2018
pZxid = 0x100000004
cversion = 1
dataVersion = 0
aclVersion = 0
ephemeralOwner = 0x0
dataLength = 7
numChildren = 1

[zk: localhost:2181(CONNECTED) 6] get -s /sanguo/shuguo
liubei
cZxid = 0x100000004
ctime = Wed Aug 29 00:04:35 CST 2018
mZxid = 0x100000004
mtime = Wed Aug 29 00:04:35 CST 2018
pZxid = 0x100000004
cversion = 0
dataVersion = 0
aclVersion = 0
ephemeralOwner = 0x0
dataLength = 6
numChildren = 0
```

**创建带序号的节点（永久节点 + 带序号）**

先创建一个普通的根节点/sanguo/weiguo：

```shell
[zk: localhost:2181(CONNECTED) 1] create /sanguo/weiguo 
"caocao"
Created /sanguo/weiguo
```

创建带序号的节点：

```shell
[zk: localhost:2181(CONNECTED) 2] create -s /sanguo/weiguo/zhangliao "zhangliao"
Created /sanguo/weiguo/zhangliao0000000000

[zk: localhost:2181(CONNECTED) 3] create -s /sanguo/weiguo/zhangliao "zhangliao"
Created /sanguo/weiguo/zhangliao0000000001

[zk: localhost:2181(CONNECTED) 4] create -s /sanguo/weiguo/xuchu "xuchu"
Created /sanguo/weiguo/xuchu0000000002
```

如果原来没有序号节点，序号从 0 开始依次递增。如果原节点下已有 2 个节点，则再排序时从 2 开始，以此类推。

注意：带序号的节点可以重复的创建，多个带序号的节点之间使用序号来区分，不带序号的节点不能重复创建，只能创建一次。

**创建临时节点（临时节点 + 不带序号 or 带序号）**

创建临时的不带序号的节点：

```shell
[zk: localhost:2181(CONNECTED) 7] create -e /sanguo/wuguo "zhouyu"
Created /sanguo/wuguo
```

创建临时的带序号的节点：

```shell
[zk: localhost:2181(CONNECTED) 2] create -e -s /sanguo/wuguo "zhouyu"
Created /sanguo/wuguo0000000001
```

在当前客户端是能查看到的：

```shell
[zk: localhost:2181(CONNECTED) 3] ls /sanguo 
[wuguo, wuguo0000000001, shuguo]
```

退出当前客户端然后再重启客户端：

```shell
[zk: localhost:2181(CONNECTED) 12] quit
[atguigu@hadoop104 zookeeper-3.5.7]$ bin/zkCli.sh
```

再次查看根目录下临时节点已经删除：

```shell
[zk: localhost:2181(CONNECTED) 0] ls /sanguo
[shuguo]
```

### 3.4.4 修改节点数据值

```shell
[zk: localhost:2181(CONNECTED) 6] set /sanguo/weiguo "simayi"
```

### 3.4.5 节点删除与查看

**删除节点**

```shell
[zk: localhost:2181(CONNECTED) 4] delete /sanguo/jin
```

**递归删除节点**

```she
[zk: localhost:2181(CONNECTED) 15] deleteall /sanguo/shuguo

**查看节点状态**

​```shell
[zk: localhost:2181(CONNECTED) 17] stat /sanguo
cZxid = 0x100000003
ctime = Wed Aug 29 00:03:23 CST 2018
mZxid = 0x100000011
mtime = Wed Aug 29 00:21:23 CST 2018
pZxid = 0x100000014
cversion = 9
dataVersion = 1
aclVersion = 0
ephemeralOwner = 0x0
dataLength = 4
numChildren = 1
```



## 3.5 监听器原理

客户端注册监听它关心的目录节点，当目录节点发生变化（数据改变、节点删除、子目录节点增加删除）时，ZooKeeper 会通知客户端。监听机制保证 ZooKeeper 保存的任何的数据的任何改变都能快速的响应到监听了该节点的应用程序。

<img src="http://blog-1259650185.cosbj.myqcloud.com/img/202110/14/1634143517.png" alt="image-20211014004517478" style="zoom:50%;" />

原理详解：

1. 首先要有一个 main() 线程
2. 在main线程中创建Zookeeper客户端，这时就会创建两个线程，一个负责网络连接通信（connet），一个负责监听（listener）。
3. 通过connect线程将注册的监听事件发送给Zookeeper。
4. 在Zookeeper的注册监听器列表中将注册的监听事件添加到列表中。
5. Zookeeper监听到有数据或路径变化，就会将这个消息发送给listener线程。
6. listener线程内部调用了process()方法。

常见的监听：

1. 监听节点数据的变化：
   get path [watch]
2. 监听子节点增减的变化：
   ls path [watch]

### 3.5.1 节点的值变化监听

在 hadoop104 主机上注册监听/sanguo 节点数据变化：

```shell
[zk: localhost:2181(CONNECTED) 26] get -w /sanguo
```

在 hadoop103 主机上修改/sanguo 节点的数据：

```shell
[zk: localhost:2181(CONNECTED) 1] set /sanguo "xisi"
```

观察 hadoop104 主机收到数据变化的监听：

```shell
WATCHER::
WatchedEvent state:SyncConnected type:NodeDataChanged 
path:/sanguo
```

注意：在hadoop103再多次修改/sanguo的值，hadoop104上不会再收到监听。因为注册一次，只能监听一次。想再次监听，需要再次注册。

### 3.5.2 节点的子节点变化监听（路径变化）

在 hadoop104 主机上注册监听/sanguo 节点的子节点变化：

```shell
[zk: localhost:2181(CONNECTED) 1] ls -w /sanguo
[shuguo, weiguo]
```

在 hadoop103 主机/sanguo 节点上创建子节点：

```shell
[zk: localhost:2181(CONNECTED) 2] create /sanguo/jin "simayi"
Created /sanguo/jin
```

观察 hadoop104 主机收到子节点变化的监听：

```shell
WATCHER::
WatchedEvent state:SyncConnected type:NodeChildrenChanged 
path:/sanguo
```

注意：节点的路径变化，也是注册一次，生效一次。想多次生效，就需要多次注册。



## 3.6 客户端 API 操作

ZooKeeper Java 代码主要使用 org.apache.zookeeper.ZooKeeper 这个类使用 ZooKeeper 服务。

`ZooKeeper(connectString, sessionTimeout, watcher)`

connectString：使用逗号分隔的列表，每个 ZooKeeper 节点是一个 host:port 对，host 是机器名或者 IP地址，port 是 ZooKeeper 节点使用的端口号。 会任意选取 connectString 中的一个节点建立连接。

sessionTimeout：session timeout 时间。

watcher: 用于接收到来自 ZooKeeper 集群的所有事件。

### 3.6.1 创建 ZooKeeper 客户端

```java
private final String connectString = "localhost:2181,localhost:2182,localhost:2183";

private final int sessionTimeout = 2000;

private ZooKeeper zkClient;

@Before
public void init() throws IOException {
    zkClient = new ZooKeeper(connectString, sessionTimeout, event -> {
        // 收到事件通知后的回调函数（用户的业务逻辑）
        System.out.println(event.getType() + "--" + event.getPath());
        // 再次启动监听
        try {
            List<String> children = zkClient.getChildren("/", true);
            for (String child : children) {
                System.out.println(child);
            }
        } catch (Exception e) {
            e.printStackTrace();
        }
    });
}

@Test
public void testStart() {
    
}
```

### 3.6.2 创建子节点

```java
@Test
public void create() throws InterruptedException, KeeperException {
    // 参数 1：要创建的节点的路径； 参数 2：节点数据 ； 参数 3：节点权限 ； 参数 4：节点的类型
    String nodeCreated = zkClient.create("/lijingyuan", "ss.avi".getBytes(StandardCharsets.UTF_8),
            ZooDefs.Ids.OPEN_ACL_UNSAFE, CreateMode.PERSISTENT);
    System.out.println(nodeCreated);
}
```

测试：在 Zookeeper 服务的 zk 客户端上查看创建节点情况

```shell
[zk: localhost:2181(CONNECTED) 1]  get /lijingyuan
ss.avi
```

### 3.6.3 获取子节点并监听节点变化

```java
@Test
public void getChildren() throws InterruptedException, KeeperException {
    zkClient.getChildren("/", true);
    // 延时阻塞
    Thread.sleep(Long.MAX_VALUE);
}
```

在 IDEA 控制台上看到如下节点：

```shell
None--null
zookeeper
kafka
lijingyuan
```

在  Zookeeper 服务 的客户端上创建再创建一个节点 /test1，观察 IDEA 控制台：

```java
NodeChildrenChanged--/
zookeeper
test1
kafka
lijingyua
```

在  Zookeeper 服务 的客户端上删除节点 /test1，观察 IDEA 控制台：

```shell
NodeChildrenChanged--/
zookeeper
kafka
lijingyuan
```

### 3.6.4 判断 Znode 是否存在

```java
@Test
public void exists() throws InterruptedException, KeeperException {
    Stat stat = zkClient.exists("/lijingyuan", false);
    System.out.println(stat == null ? "not exist" : "exist");
}
```

### 3.6.5 ZooKeeper 主要方法

- create(path, data, flags): 创建一个给定路径的 znode，并在 znode 保存 data[] 的数据，flags 指定 znode 的类型。
- delete(path, version):如果给定 path 上的 znode 的版本和给定的 version 匹配，删除 znode。
- exists(path, watch):判断给定 path 上的 znode 是否存在，并在 znode 设置一个 watch。 
- getData(path, watch):返回给定 path 上的 znode 数据，并在 znode 设置一个 watch。 
- setData(path, data, version):如果给定 path 上的 znode 的版本和给定的 version 匹配，设置 znode 数据。 
- getChildren(path, watch):返回给定 path 上的 znode 的孩子 znode 名字，并在 znode 设置一个 watch。 
- sync(path):把客户端 session 连接节点和 leader 节点进行同步。

**方法说明**

- 所有获取 znode 数据的 API 都可以设置一个 watch 用来监控 znode 的变化。 
- 所有更新 znode 数据的 API 都有两个版本: 无条件更新版本和条件更新版本。如果 version 为 -1，更新为条件更新。否则只有给定的 version 和 znode 当前的 version 一样，才会进行更新，这样的更新是条件更新。
- 所有的方法都有同步和异步两个版本。同步版本的方法发送请求给 ZooKeeper 并等待服务器的响应。异步版本把请求放入客户端的请求队列，然后马上返回。异步版本通过 callback 来接受来自服务端的响应。

### 3.6.6 ZooKeeper 代码异常处理

所有同步执行的 API 方法都有可能抛出以下两个异常：

- KeeperException: 表示 ZooKeeper 服务端出错。 KeeperException 的子类 ConnectionLossException 表示客户端和当前连接的 ZooKeeper 节点断开了连接。网络分区和 ZooKeeper 节点失败都会导致这个异常出现。发生此异常的时机可能是在 ZooKeeper 节点处理客户端请求之前，也可能是在 ZooKeeper 节点处理客户端请求之后。出现 ConnectionLossException 异常之后，客户端会进行自动重新连接，但是我们必须要检查我们以前的客户端请求是否被成功执行。 
- InterruptedException：表示方法被中断了。我们可以使用 Thread.interrupt() 来中断 API 的执行。

### 3.7.7 watch

watch 提供一个让客户端获取最新数据的机制。如果没有 watch 机制，客户端需要不断的轮询 ZooKeeper 来查看是否有数据更新，这在分布式环境中是非常耗时的。客户端可以在读取数据的时候设置一个 watcher，这样在数据更新时，客户端就会收到通知。

<img src="http://blog-1259650185.cosbj.myqcloud.com/img/202110/22/1634833892.png" alt="image-20211022003132866" style="zoom:50%;" />

### 3.7.8 条件更新

设想用 znode /c 实现一个 counter，使用 set 命令来实现自增 1 操作。条件更新场景：
1. 客户端 1 把 /c 更新到版本 1，实现 /c 的自增 1 。
2. 客户端 2 把 /c 更新到版本 2，实现 /c 的自增 1 。
3. 客户端 1 不知道 /c 已经被客户端 2 更新过了，还用过时的版本 1 是去更新 /c，更新失败。如果客户端 1 使用的是无条件更新，/c 就会更新为 2，没有实现自增 1 。

使用条件更新可以避免对数据基于过期的数据进行数据更新操作。

<img src="http://blog-1259650185.cosbj.myqcloud.com/img/202110/22/1634833963.png" alt="image-20211022003243893" style="zoom:50%;" />



## 3.7 客户端向服务端写数据流程

写流程之写入请求直接发送给 Leader 节点：

只要有半数节点（包括自己）写入，应答数超过半数，就可以给客户端发送 ACK 了。

<img src="http://blog-1259650185.cosbj.myqcloud.com/img/202110/15/1634227604.png" alt="image-20211015000643848" style="zoom:50%;" />

写流程之写入请求发送给 follower 节点：

follower 相当于客户端和 leader 之间的传声筒。

<img src="http://blog-1259650185.cosbj.myqcloud.com/img/202110/15/1634227637.png" alt="image-20211015000717772" style="zoom:50%;" />



# 第4章 服务器动态上下线监听案例

## 4.1 需求

某分布式系统中，主节点可以有多台，可以动态上下线，任意一台客户端都能实时感知到主节点服务器的上下线。



## 4.2 需求分析

<img src="http://blog-1259650185.cosbj.myqcloud.com/img/202110/15/1634227933.png" alt="image-20211015001213726" style="zoom:50%;" />



## 4.3 具体实现

1）先在集群上创建/servers 节点。

```java
[zk: localhost:2181(CONNECTED) 8] create /servers servers
Created /servers
```



2）服务端代码。

```java
public class DistributedServer {

    private final String connectString = "localhost:2181,localhost:2182,localhost:2183";

    private final int sessionTimeout = 2000;

    private ZooKeeper zk;

    private String parentNode = "/servers";

    private void connect() throws IOException {
        zk = new ZooKeeper(connectString, sessionTimeout, event -> {

        });
    }

    private void register(String hostname) throws InterruptedException, KeeperException {
        String path = zk.create( parentNode + "/server", hostname.getBytes(StandardCharsets.UTF_8), ZooDefs.Ids.OPEN_ACL_UNSAFE,
                CreateMode.EPHEMERAL_SEQUENTIAL);
        System.out.println(hostname + " is online " + path);
    }

    private void business(String hostname) throws InterruptedException {
        System.out.println(hostname + " is working ...");
        Thread.sleep(Long.MAX_VALUE);
    }

    public static void main(String[] args) throws IOException, InterruptedException, KeeperException {
        // 1.获取 zk 连接
        DistributedServer server = new DistributedServer();
        server.connect();
        // 2.利用 zk 连接注册服务器信息
        server.register(args[0]);
        // 3.启动业务功能
        server.business(args[0]);
    }

}
```



3）客户端代码。

```jar
public class DistributedClient {

    private final String connectString = "localhost:2181,localhost:2182,localhost:2183";

    private final int sessionTimeout = 2000;

    private ZooKeeper zk;

    private String parentNode = "/servers";

    private void connect() throws IOException {
        zk = new ZooKeeper(connectString, sessionTimeout, event -> {
            try {
                getServerList();
            } catch (InterruptedException | KeeperException e) {
                e.printStackTrace();
            }
        });
    }

    private void getServerList() throws InterruptedException, KeeperException {
        // 1.获取服务器子节点信息，并且对父节点进行监听
        List<String> children = zk.getChildren(parentNode, true);
        // 2.存储服务器信息列表
        ArrayList<String> servers = new ArrayList<>();
        // 3.遍历所有节点，获取节点中的主机名称信息
        for (String child : children) {
            byte[] data = zk.getData(parentNode + "/" + child, false, null);
            servers.add(new String(data));
        }
        // 4.打印服务器列表信息
        System.out.println(servers);
    }

    private void business() throws InterruptedException {
        Thread.sleep(Long.MAX_VALUE);
    }

    public static void main(String[] args) throws IOException, InterruptedException, KeeperException {
        // 1.获取 zk 连接
        DistributedClient client = new DistributedClient();
        client.connect();
        // 2.获取 servers 的子节点信息，从中获取服务器信息列表
        client.getServerList();
        // 3.启动业务功能
        client.business();
    }

}



4）测试。

首先启动一个客户端，然后启动多个服务端，然后依次关闭服务端，查看客户端日志。

​```shell
[lijingyuan1]
[lijingyuan2, lijingyuan1]
[lijingyuan3, lijingyuan2, lijingyuan1]
[lijingyuan2, lijingyuan1]
[lijingyuan2]
[]
```



# 第5章 ZooKeeper 实现 Master-Worker 协同

## 5.1 master-worker 架构

master-work 是一个广泛使用的分布式架构。master-work 架构中有一个master负责监控 worker 的状态，并为 worker 分配任务。

1. 在任何时刻，系统中最多只能有一个 master ，不可以出现两个 master 的情况，多个 master 共存会导致脑裂。
2. 系统中除了处于 active 状态的 master 还有一个 bakcup master ，如果 active master 失败了，backup master 可以很快的进入 active 状态。
3. master 实时监控 worker 的状态，能够及时收到 worker 成员变化的通知。master 在收到 worker 成员变化的时候，通常重新进行任务的重新分配。

<img src="http://blog-1259650185.cosbj.myqcloud.com/img/202110/22/1634832279.png" alt="image-20211022000439596" style="zoom:50%;" />



## 5.2 master-worker 架构示例1 - HBase

HBase 采用的是 master-worker 的架构。HMBase 是系统中的master，HRegionServer 是系统中的 worker。

HMBase 监控 HBaseCluster 中worker的成员变化，把 region 分配给各个 HRegionServer 。系统中有一个 HMaster 处于 active 状态，其他 HMaster 处于备用状态。

<img src="http://blog-1259650185.cosbj.myqcloud.com/img/202110/22/1634832435.png" alt="image-20211022000715868" style="zoom:50%;" />



## 5.3 master-worker 架构示例2 - Kafka

一个 Kafka 集群由多个 broker 组成，这些borker是系统中的 worker 。Kafka 会从这些 worker 选举出一个 controller ，这个 controller 是系统中的 master，负责把 topic partition 分配给各个 broker。

<img src="http://blog-1259650185.cosbj.myqcloud.com/img/202110/22/1634832526.png" alt="image-20211022000846487" style="zoom:50%;" />



### 5.4 master-worker 架构示例3 - HDFS

HDFS采用的也是一个 master-worker 的架构，NameNode 是系统中的 master，DataNode 是系统中的 worker 。
NameNode 用来保存整个分布式文件系统的 metadata ，并把数据块分配给 cluster 中的 DataNode 进行保存。

<img src="http://blog-1259650185.cosbj.myqcloud.com/img/202110/22/1634832613.png" alt="image-20211022001013174" style="zoom:50%;" />



### 5.5 如何使用ZooKeeper实现 master-worker

1）使用一个临时节点 /master 表示 master 。master 在行使 master 的职能之前，首先要创建这个 znode。如果能创建成功，进入active状态，开始行使 master 职能。否则的话，进入 backup 状态，使用watch机制监控 /master。假设系统中有一个 active master 和一个 backup master。如果 active master 失败，它创建的 /master 就会被 ZooKeeper 自动删除。这时 backup master 就会收到通知，通过再次创建 /master 节点成为新的 active master 。
2）worker通过在 /workers 下面创建临时节点来加入集群。

3）处于 active 状态的 master 会通过 watch 机制监控 /workers 下面 znode 列表来实时获取 worker 成员的变化。

<img src="http://blog-1259650185.cosbj.myqcloud.com/img/202110/22/1634832788.png" alt="image-20211022001308275" style="zoom:50%;" />



# 第6章 ZooKeeper Recipes 实现分布式锁

什么叫做分布式锁呢？

比如说"进程 1"在使用该资源的时候，会先去获得锁，"进程 1"获得锁以后会对该资源保持独占，这样其他进程就无法访问该资源，"进程 1"用完该资源以后就将锁释放掉，让其他进程来获得锁，那么通过这个锁机制，我们就能保证了分布式系统中多个进程能够有序的访问该临界资源。那么我们把这个分布式环境下的这个锁叫作分布式锁。

<img src="http://blog-1259650185.cosbj.myqcloud.com/img/202110/15/1634229740.png" alt="image-20211015004220805" style="zoom:50%;" />

**避免羊群效应（herd effect）**

把锁请求者按照后缀数字进行排队，后缀数字小的锁请求者先获取锁。如果所有的锁请求者都 watch 锁持有者，当代表锁请求者的 znode 被删除以后，所有的锁请求者都会通知到，但是只有一个锁请求者能拿到锁。这就是羊群效应。

为了避免羊群效应，每个锁请求者 watch 它前面的锁请求者。每次锁被释放，只会有一个锁请求者会被通知到。这样做还让锁的分配具有公平性，锁定的分配遵循先到先得的原则。



## 6.1 原生 Zookeeper 实现分布式锁案例

### 6.1.1 分布式锁实现

创建两个线程：

```java
public class DistributedLock {

    private final String connectString = "localhost:2181,localhost:2182,localhost:2183";

    private final int sessionTimeout = 2000;

    private ZooKeeper zk;

    private CountDownLatch connectLatch = new CountDownLatch(1);

    private CountDownLatch waitLatch = new CountDownLatch(1);

    private String rootPath = "/locks";

    private String waitPath;

    private String current;

    public DistributedLock() throws IOException, InterruptedException, KeeperException {
        // 获取连接
        zk = new ZooKeeper(connectString, sessionTimeout, event -> {
            if (event.getState() == Watcher.Event.KeeperState.SyncConnected) {
                connectLatch.countDown();
            }
            // waitPath需要释放
            if (event.getType() == Watcher.Event.EventType.NodeDeleted && event.getPath().equals(waitPath)) {
                waitLatch.countDown();
            }
        });
        // 等待zk正常连接后，往下运行程序
        connectLatch.await();
        // 判断根节点/locks是否存在
        Stat stat = zk.exists(rootPath, false);
        if (stat == null) {
            // 创建根节点
            zk.create(rootPath, rootPath.getBytes(), ZooDefs.Ids.OPEN_ACL_UNSAFE, CreateMode.PERSISTENT);
        }
    }

    /**
     * 加锁
     */
    public void lock() throws InterruptedException, KeeperException {
        // 创建对应的临时带序号节点
        current = zk.create(rootPath + "/seq-", null, ZooDefs.Ids.OPEN_ACL_UNSAFE, CreateMode.EPHEMERAL_SEQUENTIAL);
        // 判断创建的节点是否是最小的节点，如果是，则获取到锁；如果不是，监听前面的那一个节点
        List<String> children = zk.getChildren(rootPath, false);
        // 如果children只有一个值，那就直接获取锁，如果有多个节点，需要判断，谁最小
        if (children.size() == 1) {
            return;
        } else {
            Collections.sort(children);
            // 获取节点名称，seq-00000000
            String thisNode = current.substring((rootPath + "/").length());
            // 通过 seq-00000000 获取该节点在children集合的位置
            int index = children.indexOf(thisNode);
            if (index == -1) {
                System.out.println("数据异常");
            } else if (index == 0) {
                // 获取到锁
                return;
            } else {
                // 需要判断前一个节点的变化
                waitPath = rootPath + "/" + children.get(index - 1);
                zk.getData(waitPath, true, null);
                // 等待监听
                waitLatch.await();
                return;
            }
        }
    }

    /**
     * 释放锁
     */
    public void release() throws InterruptedException, KeeperException {
        // 删除节点
        zk.delete(current, -1);
    }

}
```

### 6.1.2 分布式锁测试

```java
public class DistributedLockTest {

    public static void main(String[] args) throws IOException, InterruptedException, KeeperException {
        DistributedLock lock1 = new DistributedLock();
        DistributedLock lock2 = new DistributedLock();
        new Thread(() -> {
            try {
                lock1.lock();
                System.out.println(Thread.currentThread().getName() + "启动，获取到锁");
                TimeUnit.SECONDS.sleep(5);
                lock1.release();
                System.out.println(Thread.currentThread().getName() + "释放锁");
            } catch (InterruptedException | KeeperException e) {
                e.printStackTrace();
            }
        }).start();
        new Thread(() -> {
            try {
                lock2.lock();
                System.out.println(Thread.currentThread().getName() + "启动，获取到锁");
                TimeUnit.SECONDS.sleep(5);
                lock2.release();
                System.out.println(Thread.currentThread().getName() + "释放锁");
            } catch (InterruptedException | KeeperException e) {
                e.printStackTrace();
            }
        }).start();
    }

}
```

观察控制台变化：

```shell
Thread-0启动，获取到锁
Thread-0释放锁
Thread-1启动，获取到锁
Thread-1释放锁
```



## 6.2 Curator 框架实现分布式锁案例

### 6.2.1 原生的 Java API 开发存在的问题

- 会话连接是异步的，需要自己去处理。比如使用 CountDownLatch
- Watch 需要重复注册，不然就不能生效
- 开发的复杂性还是比较高的
- 不支持多节点删除和创建。需要自己去递归

Curator 是一个专门解决分布式锁的框架，解决了原生 JavaAPI 开发分布式遇到的问题。详情请查看官方文档：https://curator.apache.org/index.html。

<img src="http://blog-1259650185.cosbj.myqcloud.com/img/202110/23/1634920707.png" alt="image-20211023003827668" style="zoom:50%;" />

- Client：封装了 ZooKeeper 类，管理和 ZooKeeper 集群的连接，并提供了重建连接机制。
- Framework：为所有的 ZooKeeper 操作提供了重试机制，对外提供了一个 Fluent 风格的 API 。
- Recipes：使用 framework 实现了大量的 ZooKeeper 协同服务。
- Extensions：扩展模块。



初始化一个 client 分成两个步骤：1.创建 client 。2.启动 client 。以下是两种创建 client 的方法：

```java
RetryPolicy retryPolicy = new ExponentialBackoffRetry(1000, 3);
// 1.创建 client 
// 使用Factory方法

CuratorFramework zkc = CuratorFrameworkFactory.newClient(connectString, retryPolicy);

// Fluent风格

CuratorFramework zkc = CuratorFrameworkFactory.buidler()

										.connectString(connectString)

										.retryPolicy(retryPolicy)

										.build()
  
// 2.启动 client：
zkc.start();
```

**Fluent 风格 API**

```java
// 同步版本
client.create().withMode(CreateMode.PERSISTENT).forPath(path, data);
// 异步版本
client.create().withMode(CreateMode.PERSISTENT).inBackground().forPath(path, data);
// 使用watch
client.getData().watched().forPath(path);
```



### 6.2.2 Curator 案例实操

添加依赖：

```xml
<dependency>
    <groupId>org.apache.curator</groupId>
    <artifactId>curator-recipes</artifactId>
    <version>5.2.0</version>
</dependency>
```

代码实现：

```java
public class CuratorLockTest {

    private static final String rootNode = "/locks";

    private static final String connectString = "localhost:2181,localhost:2182,localhost:2183";

    private static final int sessionTimeout = 2000;

    public static void main(String[] args) {
        InterProcessMultiLock lock1 = new InterProcessMultiLock(getCuratorFramework(), Collections.singletonList(rootNode));
        InterProcessMultiLock lock2 = new InterProcessMultiLock(getCuratorFramework(), Collections.singletonList(rootNode));

        new Thread(() -> {
            try {
                lock1.acquire();
                System.out.println(Thread.currentThread().getName() + "启动，获取到锁");
                lock1.acquire();
                System.out.println(Thread.currentThread().getName() + "再次获取到锁");
                TimeUnit.SECONDS.sleep(5);
                lock1.release();
                System.out.println(Thread.currentThread().getName() + "释放锁");
                lock1.release();
                System.out.println(Thread.currentThread().getName() + "再次释放锁");
            } catch (Exception e) {
                e.printStackTrace();
            }
        }).start();
        new Thread(() -> {
            try {
                lock2.acquire();
                System.out.println(Thread.currentThread().getName() + "启动，获取到锁");
                lock2.acquire();
                System.out.println(Thread.currentThread().getName() + "再次获取到锁");
                TimeUnit.SECONDS.sleep(5);
                lock2.release();
                System.out.println(Thread.currentThread().getName() + "释放锁");
                lock2.release();
                System.out.println(Thread.currentThread().getName() + "再次释放锁");
            } catch (Exception e) {
                e.printStackTrace();
            }
        }).start();
    }

    public static CuratorFramework getCuratorFramework() {
        RetryPolicy policy = new ExponentialBackoffRetry(3000, 3);
        CuratorFramework client = CuratorFrameworkFactory.builder()
                .connectString(connectString).connectionTimeoutMs(sessionTimeout)
                .sessionTimeoutMs(sessionTimeout)
                .retryPolicy(policy).build();
        // 启动客户端
        client.start();
        System.out.println("zookeeper 启动成功");
        return client;
    }

}
```

观察控制台变化：

```shell
zookeeper 启动成功
zookeeper 启动成功
Thread-2启动，获取到锁
Thread-2再次获取到锁
Thread-2释放锁
Thread-2再次释放锁
Thread-1启动，获取到锁
Thread-1再次获取到锁
Thread-1释放锁
Thread-1再次释放锁
```



# 第7章 ZooKeeper Recipes 实现分布式队列

## 7.1 设计

使用路径为 /queue 的 znode 下的节点表示队列中的元素。/queue 下的节点都是顺序持久化 znode。这些 znode 名字的后缀数字表示了对应队列元素在队列中的位置。Znode 名字后缀数字越小，对应队列元素在队列中的位置越靠前。Recipe 说明：[Queues](http://zookeeper.apache.org/doc/r3.7.0/recipes.html#sc_recipes_Queues)。

<img src="http://blog-1259650185.cosbj.myqcloud.com/img/202110/22/1634917612.png" alt="image-20211022234652175" style="zoom:50%;" />



## 7.2 主要方法

### 7.2.1 offer 方法

offer 方法在 /queue 下面创建一个顺序 znode。因为 znode 的后缀数字是/queue 下面现有 znode 最大后缀数字加 1，所以该 znode 对应的队列元素处于队尾。

```java
/**
 * Inserts data into queue.
 * @param data
 * @return true if data was successfully added
 */
public boolean offer(byte[] data) throws KeeperException, InterruptedException {
    for (; ; ) {
        try {
            zookeeper.create(dir + "/" + prefix, data, acl, CreateMode.PERSISTENT_SEQUENTIAL);
            return true;
        } catch (KeeperException.NoNodeException e) {
            zookeeper.create(dir, new byte[0], acl, CreateMode.PERSISTENT);
        }
    }

}
```



### 7.2.2 element 方法

```java
/**
 * Return the head of the queue without modifying the queue.
 * @return the data at the head of the queue.
 * @throws NoSuchElementException
 * @throws KeeperException
 * @throws InterruptedException
 */
public byte[] element() throws NoSuchElementException, KeeperException, InterruptedException {
    Map<Long, String> orderedChildren;

    // element, take, and remove follow the same pattern.
    // We want to return the child node with the smallest sequence number.
    // Since other clients are remove()ing and take()ing nodes concurrently,
    // the child with the smallest sequence number in orderedChildren might be gone by the time we check.
    // We don't call getChildren again until we have tried the rest of the nodes in sequence order.
    while (true) {
        try {
            orderedChildren = orderedChildren(null);
        } catch (KeeperException.NoNodeException e) {
            throw new NoSuchElementException();
        }
        if (orderedChildren.size() == 0) {
            throw new NoSuchElementException();
        }

        for (String headNode : orderedChildren.values()) {
            if (headNode != null) {
                try {
                    return zookeeper.getData(dir + "/" + headNode, false, null);
                } catch (KeeperException.NoNodeException e) {
                    //Another client removed the node first, try next
                }
            }
        }

    }
}

/**
 * Returns a Map of the children, ordered by id.
 * @param watcher optional watcher on getChildren() operation.
 * @return map from id to child name for all children
 */
private Map<Long, String> orderedChildren(Watcher watcher) throws KeeperException, InterruptedException {
    Map<Long, String> orderedChildren = new TreeMap<>();

    List<String> childNames;
    childNames = zookeeper.getChildren(dir, watcher);

    for (String childName : childNames) {
        try {
            //Check format
            if (!childName.regionMatches(0, prefix, 0, prefix.length())) {
                LOG.warn("Found child node with improper name: {}", childName);
                continue;
            }
            String suffix = childName.substring(prefix.length());
            Long childId = Long.parseLong(suffix);
            orderedChildren.put(childId, childName);
        } catch (NumberFormatException e) {
            LOG.warn("Found child node with improper format : {}", childName, e);
        }
    }

    return orderedChildren;
}
```



element 方法有以下两种返回的方式，我们下面说明这两种方式都是正确的。

1. throw new NoSuchElementException()：因为 element 方法读取到了队列为空的状态，所以抛出 NoSuchElementException 是正确的。
2. return zookeeper.getData(dir+“/”+headNode, false, null)： childNames 保存的是队列内容的一个快照。这个 return 语句返回快照中还没出队。如果队列快照的元素都出队了，重试。

<img src="http://blog-1259650185.cosbj.myqcloud.com/img/202110/22/1634917736.png" alt="image-20211022234856274" style="zoom:50%;" />

### 7.2.3 remove 方法

remove 方法和 element 方法类似。值得注意的是getData的成功执行不意味着出队成功，原因是该队列元素可能会被其他用户出队。

```java
/**
 * Attempts to remove the head of the queue and return it.
 * @return The former head of the queue
 * @throws NoSuchElementException
 * @throws KeeperException
 * @throws InterruptedException
 */
public byte[] remove() throws NoSuchElementException, KeeperException, InterruptedException {
    Map<Long, String> orderedChildren;
    // Same as for element.  Should refactor this.
    while (true) {
        try {
            orderedChildren = orderedChildren(null);
        } catch (KeeperException.NoNodeException e) {
            throw new NoSuchElementException();
        }
        if (orderedChildren.size() == 0) {
            throw new NoSuchElementException();
        }

        for (String headNode : orderedChildren.values()) {
            String path = dir + "/" + headNode;
            try {
                byte[] data = zookeeper.getData(path, false, null);
                zookeeper.delete(path, -1);
                return data;
            } catch (KeeperException.NoNodeException e) {
                // Another client deleted the node first.
            }
        }

    }
}
```



```java
byte[] data = zookeeper.getData(path, false, null);
zookeeper.delete(path, -1);
```

<img src="http://blog-1259650185.cosbj.myqcloud.com/img/202110/22/1634917791.png" alt="image-20211022234951251" style="zoom:50%;" />



# 第7章 ZooKeeper Recipes 实现选举

## 7.1 设计

使用临时顺序 znode 来表示选举请求，创建最小后缀数字 znode 的选举请求成功。在协同设计上和分布式锁是一样的，不同之处在于具体实现。不同于分布式锁，选举的具体实现对选举的各个阶段做了监控。Recipe 说明：[Leader Election](http://zookeeper.apache.org/doc/current/recipes.html#sc_leaderElection) 。

<img src="http://blog-1259650185.cosbj.myqcloud.com/img/202110/23/1634920348.png" alt="image-20211023003228579" style="zoom:50%;" />



# 第8章 通过 ZooKeeper Observer 实现跨区域部署

ZooKeeper 处理写请求时序：

节点1、节点3是follower，节点2是leader。



<img src="http://blog-1259650185.cosbj.myqcloud.com/img/202110/23/1634982274.png" alt="image-20211023174434331" style="zoom:50%;" />



## 8.1 什么是 Observer？

Observer 和 ZooKeeper 机器其他节点唯一的交互是接收来自 leader 的 inform 消息，更新自己的本地存储，不参与提交和选举的投票过程。

<img src="http://blog-1259650185.cosbj.myqcloud.com/img/202110/23/1634982371.png" alt="image-20211023174611751" style="zoom:50%;" />



## 8.2 Observer 应用场景 - 读性能提升

Observer 和 ZooKeeper 机器其他节点唯一的交互是接收来自 leader 的 inform 消息，更新自己的本地存储，不参与提交和选举的投票过程。因此可以通过往集群里面添加 Observer 节点来提高整个集群的读性能。

节点1是observer，节点2是leader，节点3是follower，节点1收到写请求，转发给节点2 leader处理，leader节点只需要给节点3（因为节点1是 observer不参与事务提交过程）发送propose ，收到节点3的 accept 后就可以像节点1和节点3发送commit，然后节点1回复客户端。这样的话，只需要向节点3发送 propose 就够了，就不用像上面的图中一样像节点1和3都发送 propose 了。

<img src="http://blog-1259650185.cosbj.myqcloud.com/img/202110/23/1634982443.png" alt="image-20211023174723195" style="zoom:50%;" />



## 8.3 Observer 应用场景 - 跨数据中心部署

我们需要部署一个北京和香港两地都可以使用的 ZooKeeper 服务。我们要求北京和香港的客户端的读请求的延迟都低。因此，我们需要在北京和香港都部署 ZooKeeper 节点。我们假设 leader 节点在北京。那么每个写请求要涉及 leader 和每个香港 follower 节点之间的
propose 、ack 和 commit 三个跨区域消息。

解决的方案是把香港的节点都设置成 observer 。上面提的 propose 、ack 和 commit 消息三个消息就变成了 inform 一个跨区域消息消息。

<img src="http://blog-1259650185.cosbj.myqcloud.com/img/202110/23/1634983010.png" alt="image-20211023175650785" style="zoom:50%;" />



# 第9章 使用 ZooKeeper 实现服务发现

## 9.1 服务发现

服务发现主要应用于微服务架构和分布式架构场景下。在这些场景下，一个服务通常需要松耦合的多个组件的协同才能完成。服务发现就是让组件发现相关的组件。服务发现要提供的功能有以下3点：

- 服务注册
- 服务实例的获取
- 服务变化的通知机制

Curator 有一个扩展叫作 curator-x-discovery 。curator-x-discovery 基于 ZooKeeper 实现了服务发现。



## 9.2 curator-x-discovery 设计

使用一个 base path 作为整个服务发现的根目录。在这个根目录下是各个服务的的目录。服务目录下面是服务实例。实例是服务实例的 JSON 序列化数据。服务实例对应的 znode 节点可以根据需要设置成持久性、临时性和顺序性。

<img src="http://blog-1259650185.cosbj.myqcloud.com/img/202110/23/1634986994.png" alt="image-20211023190314724" style="zoom:50%;" />

## 9.3 核心接口

下图列出了服务发现用户代码要使用的 curator-x-discovery 接口。最主要的有以下三个接口：

- ServiceProvider：在服务 cache 之上支持服务发现操作，封装了一些服务发现策略。
- ServiceDiscovery：服务注册，也支持直接访问 ZooKeeper 的服务发现操作。
- ServiceCache：服务 cache 。

<img src="http://blog-1259650185.cosbj.myqcloud.com/img/202110/23/1634987100.png" alt="image-20211023190500734" style="zoom:50%;" />

### 9.3.1 ServiceInstance

用来表示服务实例的 POJO，除了包含一些服务实例常用的成员之外，还提供一个 payload 成员让用户存自定义的信息。

### 9.3.2 ServiceDiscovery

从一个 ServiceDiscovery ，可以创建多个 ServiceProvider 和多个 ServiceCache 。

<img src="http://blog-1259650185.cosbj.myqcloud.com/img/202110/23/1634987596.png" alt="image-20211023191316368" style="zoom:50%;" />

### 9.3.3 ServiceProvider

ServiceProvider 提供服务发现 high-level API 。ServiceProvider 是封装 ProviderStraegy 和 InstanceProvider 的 facade 。 InstanceProvider 的数据来自一个服务 Cache 。服务 cache 是 ZooKeeper 数据的一个本地 cache ，服务 cache 里面的数据可能会比 ZooKeeper 里面的数据旧一些。ProviderStraegy 提供了三种策略：轮询, 随机和 sticky 。

<img src="http://blog-1259650185.cosbj.myqcloud.com/img/202110/23/1634987728.png" alt="image-20211023191528098" style="zoom:50%;" />

ServiceProvider 除了提供服务发现的方法( getInstance 和 getAllInstances )以外，还通过 noteError 提供了一个让服务使用者把服务使用情况反馈给 ServiceProvider 的机制。

### 9.3.4 ServiceCache

### 9.3.5 ZooKeeper 交互

ServiceDiscovery 提供的服务注册方法是对 znode 的更新操作，服务发现方法是 znode 的读取操作。同时它也是最核心的类，所有的服务发现操作都要从这个类开始。

另外服务 Cache 会接受来自 ZooKeeper 的更新通知，读取服务信息（也就是读取 znode 信息）。

### 9.3.6 ServiceDiscovery、ServiceCache、ServiceProvider 说明

- 都有一个对应的 builder。这些 builder 提供一个创建这三个类的 fluent API 。
- 在使用之前都要调用 start 方法。
- 在使用之后都要调用 close 方法。close 方法只会释放自己创建的资源，不会释放上游关联的资源。
  例如 ServiceDiscovery 的 close 方法不会去调用 CuratorFramework 的 close 方法。

### 9.3.7 Node Cache

Node Cache 是 curator 的一个 recipe ，用来本地 cache 一个 znode 的数据。Node Cache 通过监控一个 znode 的 update / create / delete 事件来更新本地的 znode 数据。用户可以在 Node Cache 上面注册一个 listener 来获取 cache 更新的通知。

### 9.3.8 Path Cache

Path Cache 和 Node Cache 一样，不同之处是在于 Path Cache 缓存一个 znode 目录下所有子节点。

### 9.3.9 container 节点

container 节点是一种新引入的 znode ，目的在于下挂子节点。当一个 container 节点的所有子节点被删除之后，ZooKeeper 会删除掉这个 container 节点。服务发现的 base path 节点和服务节点就是 containe 节点。

<img src="http://blog-1259650185.cosbj.myqcloud.com/img/202110/23/1634988007.png" alt="image-20211023192007571" style="zoom:50%;" />

### 9.3.10 ServiceCacheImpl

ServiceCacheImpl 使用一个 PathChildrenCache 来维护一个 instances 。这个 instances也是对 znode 数据的一个 cache 。

<img src="http://blog-1259650185.cosbj.myqcloud.com/img/202110/24/1635005620.png" alt="image-20211024001339976" style="zoom:50%;" />

### 9.3.11 ServiceProviderImpl

如下图所示，ServiceProviderImpl 是多个对象的 facade 。

<img src="http://blog-1259650185.cosbj.myqcloud.com/img/202110/24/1635005695.png" alt="image-20211024001455299" style="zoom:50%;" />

### 9.3.12 ProviderStrategy



# 第10章 企业面试真题

## 10.1 选举机制

半数机制，超过半数的投票通过，即通过。

- 第一次启动选举规则：
  投票过半数时，服务器 id 大的胜出
- 第二次启动选举规则：
  1. EPOCH 大的直接胜出
  2. EPOCH 相同，事务 id 大的胜出
  3. 事务 id 相同，服务器 id 大的胜出

## 10.2 生产集群安装多少 zk 合适？

安装奇数台。
生产经验：

- 10 台服务器：3 台 zk；

- 20 台服务器：5 台 zk；

- 100 台服务器：11 台 zk；

- 200 台服务器：11 台 zk

服务器台数多：好处，提高可靠性；坏处：提高通信延时

## 10.3 常用命令

ls、get、create、delete