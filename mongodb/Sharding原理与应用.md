## 1. MongoDB Sharded Cluster 原理

如果你还不了解 MongoDB Sharded cluster，可以先看文档认识一下

- 中文简介：[MongoDB Sharded cluster架构原理](https://yq.aliyun.com/articles/32434?spm=5176.8091938.0.0.myHNU1)
- 英文汇总：https://docs.mongodb.com/manual/sharding/

## 2. 什么时候考虑用 Sharded cluster？

当你考虑使用 Sharded cluster 时，通常是要解决如下2个问题

1. 存储容量受单机限制，即磁盘资源遭遇瓶颈。
2. 读写能力受单机限制（读能力也可以在复制集里加 secondary 节点来扩展），可能是 CPU、内存或者网卡等资源遭遇瓶颈，导致读写能力无法扩展。

如果你没有遇到上述问题，使用 MongoDB 复制集就足够了，管理维护上比 Sharded cluster 要简单很多。

## 3. 如何确定 shard、mongos 数量？

当你决定要使用 Sharded cluster 时，问题来了，应该部署多少个 shard、多少个 mongos？这个问题首富已经指点过我们，『先定一个小目标，比如先部署上1000个 shard』，然后根据需求逐步扩展。

回到正题，shard、mongos 的数量归根结底是由应用需求决定，如果你使用 sharding 只是解决 『海量数据存储』的问题，访问并不多，那么很简单，假设你单个 shard 能存储 M， 需要的存储总量是 N。

```
  numberOfShards = N / M / 0.75    （假设容量水位线为75%）
  numberOfMongos = 2+ （因为对访问要求不高，至少部署2个 mongos 做高可用即可）
```

如果你使用 sharding 是解决高并发写入（或读取）数据的问题，总的数据量其实很小，这时你部署的 shard、mongos 要能满足读写性能需求，而容量上则不是考量的重点。假设单个 shard 最大 qps 为 M，单个 mongos 最大 qps 为 Ms，需要总的 qps 为 N。 (注：mongos、mongod 的服务能力，需要用户根据访问特性来实测得出）

```
numberOfShards = Q * / M * / 0.75    （假设负载水位线为75%）
numberOfMongos = Q * / Ms / 0.75 
```

如果sharding 要解决上述2个问题，则按需求更高的指标来预估；以上估算是基于sharded cluster 里数据及请求都均匀分布的理想情况，但实际情况下，分布可能并不均衡，这里引入一个『不均衡系数 D』的概念（个人 YY 的，非通用概念），意思是系统里『数据（或请求）分布最多的 shard 是平均值的 D 倍』，实际需要的 shard、mongos 数量，在上述预估上再乘上『不均衡系数 D』。

而为了让系统的负载分布尽量均匀，就需要合理的选择 shard key。

## 4. 如何选择shard key ？

MongoDB Sharded cluster 支持2种分片方式，各有优劣

- [范围分片](https://docs.mongodb.com/manual/core/ranged-sharding/)，通常能很好的支持基于 shard key的范围查询
- [Hash 分片](https://docs.mongodb.com/manual/core/hashed-sharding/)，通常能将写入均衡分布到各个 shard

上述2种分片策略都不能解决的问题包括

1. shard key 取值范围太小(low cardinality)，比如将数据中心作为 shard key，而数据中心通常不会很多，分片的效果肯定不好。
2. shard key 某个值的文档特别多，这样导致单个 chunk 特别大（及 jumbo chunk），会影响chunk 迁移及负载均衡。
3. 根据非 shard key 进行查询、更新操作都会变成 scatter-gather 查询，影响效率。

好的 shard key 应该拥有如下特性：

- key 分布足够离散 （sufficient cardinality）
- 写请求均匀分布 （evenly distributed write）
- 尽量避免 scatter-gather 查询 （targeted read）

举个例子，某物联网应用使用 MongoDB Sharded cluster 存储『海量设备』的『工作日志』，假设设备数量在百万级别，设备每10s向 MongoDB汇报一次日志数据，日志包含deviceId，timestamp 信息，应用最常见的查询请求是『查询某个设备某个时间内的日志信息』。（读者可以自行预估下，这个量级，无论从写入还是数据量上看，都应该使用 Sharding，以便能水平扩张）。

- 方案1： 时间戳作为 shard key，范围分片
  - Bad
  - 新的写入都是连续的时间戳，都会请求到同一个 shard，写分布不均
  - 根据 deviceId 的查询会分散到所有 shard 上查询，效率低
- 方案2： 时间戳作为 shard key，hash 分片
  - Bad
  - 写入能均分到多个 shard
  - 根据 deviceId 的查询会分散到所有 shard 上查询，效率低
- 方案3：deviceId 作为 shardKey，hash分片（如果 id 没有明显的规则，范围分片也一样）
  - Bad
  - 写入能均分到多个 shard
  - 同一个 deviceId 对应的数据无法进一步细分，只能分散到同一个 chunk，会造成 jumbo chunk
  - 根据 deviceId的查询只请求到单个 shard，不足的时，请求路由到单个 shard 后，根据时间戳的范围查询需要全表扫描并排序
- 方案4：(deviceId, 时间戳)组合起来作为 shardKey，范围分片（Better）
  - Good
  - 写入能均分到多个 shard
  - 同一个 deviceId 的数据能根据时间戳进一步分散到多个chunk
  - 根据 deviceId 查询时间范围的数据，能直接利用（deviceId, 时间戳）复合索引来完成。

## 5. 关于jumbo chunk及 chunk size

jumbo chunk 的意思是chunk『太大或者文档太多』 且无法分裂。

```
If MongoDB cannot split a chunk that exceeds the specified chunk size or contains a number of documents that exceeds the max, MongoDB labels the chunk as jumbo.
```

MongoDB 默认的 chunk size 为64MB，如果 chunk 超过64MB 并且不能分裂（比如所有文档 的 shard key 都相同），则会被标记为jumbo chunk ，balancer 不会迁移这样的 chunk，从而可能导致负载不均衡，应尽量避免。

一旦出现了 jumbo chunk，如果对负载均衡要求不高，不去关注也没啥影响，并不会影响到数据的读写访问。如果一定要处理，可以尝试[如下方法](https://docs.mongodb.com/manual/tutorial/clear-jumbo-flag/)

1. 对 jumbo chunk 进行 split，一旦 split 成功，mongos 会自动清除 jumbo 标记。
2. 对于不可再分的 chunk，如果该 chunk 已不再是 jumbo chunk，可以尝试手动清除chunk 的 jumbo 标记（注意先备份下 config 数据库，以免误操作导致 config 库损坏）。
3. 最后的办法，调大 chunk size，当 chunk 大小不再超过 chunk size 时，jumbo 标记最终会被清理，但这个是治标不治本的方法，随着数据的写入仍然会再出现 jumbo chunk，根本的解决办法还是合理的规划 shard key。

关于 chunk size 如何设置的问题，绝大部分情况下，请直接使用默认 chunk size ，以下场景可能需要调整 chunk size（取值在1-1024之间）。

- 迁移时 IO 负载太大，可以尝试设置更小的 chunk size
- 测试时，为了方便验证效果，设置较小的 chunk size
- 初始 chunk size 设置不合适，导致出现大量 jumbo chunk，影响负载均衡，此时可以尝试调大 chunk size
- 将『未分片的集合』转换为『分片集合』，如果集合容量太大，可能需要（数据量达到T 级别才有可能遇到）调大 chunk size 才能转换成功。参考[Sharding Existing Collection Data Size](https://docs.mongodb.com/manual/core/sharded-cluster-requirements/)

## 6. Tag aware sharding

[Tag aware sharding](https://docs.mongodb.com/manual/core/tag-aware-sharding/) 是 Sharded cluster 很有用的一个特性，允许用户自定义一些 chunk 的分布规则。Tag aware sharding 原理如下

1. sh.addShardTag() 给shard 设置标签 A
2. sh.addTagRange() 给集合的某个 chunk 范围设置标签 A，最终 MongoDB 会保证设置标签 A 的 chunk 范围（或该范围的超集）分布设置了标签 A 的 shard 上。

Tag aware sharding可应用在如下场景

- 将部署在不同机房的 shard 设置『机房标签』，将不同 chunk 范围的数据分布到指定的机房
- 将服务能力不通的 shard 设置『服务等级标签』，将更多的 chunk分散到服务能力更前的 shard 上去。
- …

使用 Tag aware sharding 需要注意是, chunk 分配到对应标签的 shard 上『不是立即完成，而是在不断 insert、update 后触发 split、moveChunk后逐步完成的，并且需要保证 balancer 是开启的』。所以你可能会观察到，在设置了 tag range 后一段时间后，写入仍然没有分布到tag 相同的 shard 上去。

## 7. 关于负载均衡

MongoDB Sharded cluster 的自动负载均衡目前是由 mongos 的后台线程来做的，并且每个集合同一时刻只能有一个迁移任务，负载均衡主要根据集合在各个 shard 上 chunk 的数量来决定的，相差超过一定阈值（跟 chunk 总数量相关）就会触发chunk迁移。

负载均衡默认是开启的，为了避免 chunk 迁移影响到线上业务，可以通过设置迁移执行窗口，比如只允许凌晨`2:00-6:00`期间进行迁移。

```shell
use config
db.settings.update(
   { _id: "balancer" },
   { $set: { activeWindow : { start : "02:00", stop : "06:00" } } },
   { upsert: true }
)
```

另外，在进行 [sharding 备份](https://docs.mongodb.com/manual/tutorial/backup-sharded-cluster-with-database-dumps/)时（通过 mongos 或者单独备份config server 和所有 shard），需要停止负载均衡，以免备份出来的数据出现状态不一致问题。

```shell
sh.stopBalancer()
```

## 8. moveChunk 归档设置

使用3.0及以前版本的 Sharded cluster 可能会遇到一个问题，停止写入数据后，数据目录里的磁盘空间占用还会一直增加。

上述行为是由`sharding.archiveMovedChunks`配置项决定的，该配置项在3.0及以前的版本默认为 true，即在move chunk 时，源 shard 会将迁移的 chunk 数据归档一份在数据目录里，当出现问题时，可用于恢复。也就是说，chunk 发生迁移时，源节点上的空间并没有释放出来，而目标节点又占用了新的空间。

在3.2版本，该配置项默认值也被设置为 false，默认不会对 moveChunk 的数据在源 shard 上归档。

## 9. recoverShardingState 设置

使用 MongoDB Sharded cluster 时，还可能遇到一个问题，就是启动 shard后，shard 不能正常服务，『Primary 上调用 ismaster 时，结果却为 true，也无法正常执行其他命令』，其状态类似如下：

```shell
mongo-9003:PRIMARY> db.isMaster()
{
	"hosts" : [
		"host1:9003",
		"host2:9003",
		"host3:9003"
	],
	"setName" : "mongo-9003",
	"setVersion" : 9,
	"ismaster" : false,  // primary 的 ismaster 为 false？？？
	"secondary" : true,
	"primary" : "host1:9003",
	"me" : "host1:9003",
	"electionId" : ObjectId("57c7e62d218e9216c70aa3cf"),
	"maxBsonObjectSize" : 16777216,
	"maxMessageSizeBytes" : 48000000,
	"maxWriteBatchSize" : 1000,
	"localTime" : ISODate("2016-09-01T12:29:27.113Z"),
	"maxWireVersion" : 4,
	"minWireVersion" : 0,
	"ok" : 1
}
```

查看其错误日志，会发现 shard 一直无法连接上 config server，上述行为是由 sharding.recoverShardingState 选项决定，默认为 true，也就是说，shard 启动时，其会连接 config server 进行 sharding 状态的一些初始化，而如果 config server 连不上，初始化工作就一直无法完成，导致 shard 状态不正常。

有同学在将 Sharded cluster 所有节点都迁移到新的主机上时遇到了上述问题，因为 config server 的信息发生变化了，而 shard 启动时还会连接之前的 config server，通过在启动命令行加上 `--setParameter recoverShardingState=false`来启动 shard 就能恢复正常了。

上述默认设计的确有些不合理，config server 的异常不应该去影响 shard，而且最终的问题的表象也很不明确，在3.4大版本里，MongoDB 也会对这块进行修改，去掉这个参数，默认不会有 recoverShardingState 的逻辑，具体参考 [SERVER-24465](https://jira.mongodb.org/browse/SERVER-24465)。



## 参考

[Everything You Need to Know About Sharding](https://www.mongodb.com/presentations/webinar-everything-you-need-know-about-sharding?jmp=docs&_ga=1.113926660.2005306875.1453858874)

[MongoDB for Time Series Data: Sharding](https://www.mongodb.com/presentations/mongodb-time-series-data-part-3-sharding?jmp=docs&_ga=1.136350259.2005306875.1453858874)

[Hashed Sharding](https://docs.mongodb.com/manual/core/hashed-sharding/)

[Ranged Sharding](https://docs.mongodb.com/manual/core/ranged-sharding/)

[Dealing with Jumbo Chunks in MongoDB](https://www.percona.com/blog/2016/04/11/dealing-with-jumbo-chunks-in-mongodb/)

[Tag aware sharding](https://docs.mongodb.com/manual/core/tag-aware-sharding/)

[Sharding backup](https://docs.mongodb.com/manual/tutorial/backup-sharded-cluster-with-database-dumps/)
