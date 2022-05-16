## 1. 业务方关注哪些数据库指标？

首先分享一下自己之前的一段笔记（找不到引用出处了）

- 系统中多少个线程在进行与数据库有关的工作？其中，而多少个线程正在执行 SQL 语句？这可以让我们评估数据库是不是系统瓶颈。
- 多少个线程在等待获取数据库连接？获取数据库连接需要的平均时长是多少？数据库连接池是否已经不能满足业务模块需求？如果存在获取数据库连接较慢，如大于 100ms，则可能说明配置的数据库连接数不足，或存在连接泄漏问题。
- 哪些线程正在执行 SQL 语句？执行了的 SQL 语句是什么？数据库中是否存在系统瓶颈或已经产生锁？如果个别 SQL 语句执行速度明显比其它语句慢，则可能是数据库查询逻辑问题，或者已经存在了锁表的情况，这些都应当在系统优化时解决。
- 最经常被执行的 SQL 语句是在哪段源代码中被调用的？最耗时的 SQL 语句是在哪段源代码中被调用的？在浩如烟海的源代码中找到某条 SQL 并不是一件很容易的事。而当存在问题的 SQL 是在底层代码中，我们就很难知道是哪段代码调用了这个 SQL，并产生了这些系统问题。

在研究HikariCP的过程中，这些业务关注点我发现在连接池这层逐渐找到了答案。

## 2. 监控指标

| HikariCP指标                        |                       说明 |    类型 |                        备注                         |
| :---------------------------------- | -------------------------: | ------: | :-------------------------------------------------: |
| hikaricp_connection_timeout_total   | 连接池中总共超时的连接数量 | Counter |                                                     |
| hikaricp_pending_threads            |   当前排队获取连接的线程数 |   GAUGE |             关键指标，大于10则 **报警**             |
| hikaricp_connection_acquired_nanos  |         连接获取的等待时间 | Summary |                pool.Wait 关注99极值                 |
| hikaricp_active_connections         |       当前正在使用的连接数 |   GAUGE |                                                     |
| hikaricp_connection_creation_millis |         创建连接成功的耗时 | Summary |                     关注99极值                      |
| hikaricp_idle_connections           |             当前空闲连接数 |   GAUGE | 关键指标，默认10，因为降低为0会大大增加连接池创建开 |
| hikaricp_connection_usage_millis    |       连接被复用的间隔时长 | Summary |                pool.Usage 关注99极值                |
| hikaricp_connections                |         连接池的总共连接数 |   GAUGE |                                                     |

## 3. 重点关注

### 3.1 hikaricp_pending_threads

该指标持续飙高，说明DB连接池中基本已无空闲连接。
拿之前业务方应用pisces不可用的例子来说(如下图所示)，当时所有线程都在排队等待，该指标已达172，此时调用方已经产生了大量超时及熔断，虽然业务方没有马上找到拿不到连接的根本原因，但是这个告警出来之后及时进行了重启，避免产生更大的影响。

<img src="http://blog-1259650185.cosbj.myqcloud.com/img/202205/12/1652371077.jpeg" alt="3" style="zoom:50%;" />

### 3.2 hikaricp_connection_acquired_nanos（取99位数）

下图是Hikari源码com.zaxxer.hikari.pool.HikariPool#getConnection部分，

```java
public Connection getConnection(final long hardTimeout) throws SQLException
{
   suspendResumeLock.acquire();
   final var startTime = currentTime();

   try {
      var timeout = hardTimeout;
      do {
         var poolEntry = connectionBag.borrow(timeout, MILLISECONDS);
         if (poolEntry == null) { // 走到这，说明已经超时了
            break; // We timed out... break and throw exception
         }

         final var now = currentTime();
         if (poolEntry.isMarkedEvicted() || (elapsedMillis(poolEntry.lastAccessed, now) > aliveBypassWindowMs && isConnectionDead(poolEntry.connection))) { // 拿到一个poolEntry后先判断是否已经被标记为待清理或已经超过了设置的最大存活时间（应用配置的最大存活时间不应超过DBA在DB端配置的最大连接存活时间）
            closeConnection(poolEntry, poolEntry.isMarkedEvicted() ? EVICTED_CONNECTION_MESSAGE : DEAD_CONNECTION_MESSAGE); // 若是直接关闭继续循环调用 borrow
            timeout = hardTimeout - elapsedMillis(startTime);
         }
         else {
            metricsTracker.recordBorrowStats(poolEntry, startTime); // 记录获取连接的等待时间监控指标
            return poolEntry.createProxyConnection(leakTaskFactory.schedule(poolEntry));
         }
      } while (timeout > 0L);

      metricsTracker.recordBorrowTimeoutStats(startTime);
      throw createTimeoutException(startTime);
   }
   catch (InterruptedException e) {
      Thread.currentThread().interrupt();
      throw new SQLException(poolName + " - Interrupted during connection acquisition", e);
   }
   finally {
      suspendResumeLock.release();
   }
}
```

从上述代码可以看到，suspendResumeLock.acquire() 走到 poolEntry == null 时已经超时了，拿到一个 poolEntry 后先判断是否已经被标记为待清理或已经超过了设置的最大存活时间（应用配置的最大存活时间不应超过DBA在DB端配置的最大连接存活时间），若是直接关闭继续调用 borrow，否则才会返回该连接，metricsTracker.recordBorrowTimeoutStats(startTime);该段代码的意义就是此指标的记录处。
Vesta模版中该指标单位配为了毫秒，此指标和排队线程数结合，可以初步提出 **增大连接数** 或 **优化慢查询／慢事务** 的优化方案等。

- 当 **排队线程数多** 而 **获取连接的耗时较短** 时，可以考虑增大连接数
- 当 **排队线程数少** 而 **获取连接的耗时较长** 时，此种场景不常见，举例来说，可能是某个接口QPS较低，连接数配的小于这个QPS，而这个连接中有较慢的查询或事务，这个需要具体问题具体分析
- 当 **排队线程数多** 且 **获取连接的耗时较长**时，这种场景比较危险，有可能是某个时间点DB压力大或者网络抖动造成的，排除这些场景，若长时间出现这种情况则可认为 **连接配置不合理／程序是没有达到上线标准** ，如果可以从业务逻辑上优化慢查询／慢事务是最好的，否则可以尝试 **增大连接数** 或 **应用扩容** 。

### 3.3 hikaricp_idle_connections

Hikari是可以配置最小空闲连接数的，当此指标长期比较高（等于最大连接数）时，可以适当减小配置项中最小连接数。

### 3.4 hikaricp_active_connections

此指标长期在设置的最大连接数上下波动时，或者长期保持在最大线程数时，可以考虑增大最大连接数。

### 3.5 hikaricp_connection_usage_millis（取99位数）

该配置的意义在于表明 连接池中的一个连接从 **被返回连接池** 到 **再被复用** 的时间间隔，对于使用较少的数据源，此指标可能会达到秒级，可以结合流量高峰期的此项指标与激活连接数指标来确定是否需要减小最小连接数，若高峰也是秒级，说明对比数据源使用不频繁，可考虑减小连接数。

### 3.6 hikaricp_connection_timeout_total

该配置的意义在于表明 连接池中总共超时的连接数量，此处的超时指的是连接创建超时。经常连接创建超时，一个排查方向是和运维配合检查下网络是否正常。

### 3.7 hikaricp_connection_creation_millis（取99位数）

该配置的意义在于表明 创建一个连接的耗时。主要反映当前机器到数据库的网络情况，在IDC意义不大，除非是网络抖动或者机房间通讯中断才会有异常波动。

## 4. 监控指标部分实战案例

以下连接风暴和慢SQL两种场景是可以采用HikariCP连接池监控的。

### 4.1 连接风暴

连接风暴，也可称为网络风暴，当应用启动的时候，经常会碰到各应用服务器的连接数异常飙升，这是大规模应用集群很容易碰到的问题。先来描述一个场景

> 在项目发布的过程中，我们需要重启应用，当应用启动的时候，经常会碰到各应用服务器的连接数异常飙升。假设连接数的设置为：min值3，max值10。正常的业务使用连接数在5个左右，当重启应用时，各应用连接数可能会飙升到10个，瞬间甚至还有可能部分应用会报取不到连接。启动完成后接下来的时间内，连接开始慢慢返回到业务的正常值。这种场景，就是碰到了所谓的连接风暴。

连接风暴可能带来的危害主要有：

- 在多个应用系统同时启动时，系统大量占用数据库连接资源，可能导致数据库连接数耗尽
- 数据库创建连接的能力是有限的，并且是非常耗时和消耗CPU等资源的，突然大量请求落到数据库上，极端情况下可能导致数据库异常crash。
- 对于应用系统来说，多一个连接也就多占用一点资源。在启动的时候，连接会填充到max值，并有可能导致瞬间业务请求失败。

与连接风暴类似的还有：

- 启动时的preparedstatement风暴
- 缓存穿透。在缓存使用的场景中，缓存KEY值失效的风暴（单个KEY值失效，PUT时间较长，导致穿透缓存落到DB上，对DB造成压力）。可以采用 **布隆过滤器** 、**单独设置个缓存区域存储空值，对要查询的key进行预先校验** 、**缓存降级**等方法。
- 缓存雪崩。上条的恶化，所有原本应该访问缓存的请求都去查询数据库了，而对数据库CPU和内存造成巨大压力，严重的会造成数据库宕机。从而形成一系列连锁反应，造成整个系统崩溃。可以采用 **加锁排队**、 **设置过期标志更新缓存** 、 **设置过期标志更新缓存** 、**二级缓存（引入一致性问题）**、 **预热**、 **缓存与服务降级**等解决方法。

#### 案例一 某公司订单业务

> 我们那时候采用弹性伸缩，数据库连接池是默认的，有点业务出了点异常，导致某个不重要的业务弹出N台机器，导致整个数据库连接不可用，影响订单主业务。

该案例就可以理解为是一次连接风暴，当时刚好那个服务跟订单合用一个数据库了，订单服务只能申请到默认连接数，访问订单TPS上不去，老刘同学说“损失惨重才能刻骨铭心呀”。

#### 案例二 切库

我司在切库的时候产生过连接风暴，瞬间所有业务全部断开重连，造成连接风暴，暂时通过加大连接数解决此问题。当然，单个应用重启的时候可以忽略不计，因为，一个库的依赖服务不可能同时重启。

#### 案例三 机房出故障

以前机房出故障的时候，应用全部涌进来，有过一次连接炸掉的情况。

### 4.2 慢SQL

我司的瓶颈其实不在连接风暴，我们的并发并不是很高，和电商不太一样。复杂 SQL 很多，清算、对账的复杂SQL都不少，部分业务的SQL比较复杂。比如之前有过一次催收线上故障，就是由于慢SQL导致Hikari连接池占满，排队线程指标飙升，当时是无法看到整个连接池的历史趋势的，也很难看到连接池实时指标，有了本监控大盘工具之后，业务方可以更方便得排查类似问题。

## 5. 如何调优

### 5.1 经验配置连接池参数及监控告警

首先分享一个小故事《扁鹊三兄弟》

> 春秋战国时期，有位神医被尊为“医祖”，他就是“扁鹊”。一次，魏文王问扁鹊说：“你们家兄弟三人，都精于医术，到底哪一位最好呢？”扁鹊答：“长兄最好，中兄次之，我最差。”文王又问：“那么为什么你最出名呢？”扁鹊答：“长兄治病，是治病于病情发作之前，由于一般人不知道他事先能铲除病因，所以他的名气无法传出去；中兄治病，是治病于病情初起时，一般人以为他只能治轻微的小病，所以他的名气只及本乡里；而我是治病于病情严重之时，一般人都看到我在经脉上穿针管放血，在皮肤上敷药等大手术，所以以为我的医术高明，名气因此响遍全国。”

正文罗列的几种监控项可以配上告警，这样，能够在业务方发现问题之前第一时间发现问题，这就是扁鹊三兄弟大哥、二哥的做法，我们正是要努力成为扁鹊的大哥、二哥那样的人。
根据日常的运维经验，大多数线上应用可以使用如下的Hikari的配置：

```
maximumPoolSize: 20
minimumIdle: 10
connectionTimeout: 30000
idleTimeout: 600000
maxLifetime: 1800000
```

连接池连接数有动态和静态两种策略。动态即每隔一定时间就对连接池进行检测，如果发现连接数量小于最小连接数，则补充相应数量的新连接以保证连接池的正常运转。静态是发现空闲连接不够时再去检查。这里提一下minimumIdle，hikari实际上是不推荐用户去更改Hikari默认连接数的。

> This property controls the minimum number of idle connections that HikariCP tries to maintain in the pool. If the idle connections dip below this value and total connections in the pool are less than maximumPoolSize, HikariCP will make a best effort to add additional connections quickly and efficiently. However, for maximum performance and responsiveness to spike demands, we recommend not setting this value and instead allowing HikariCP to act as a fixed size connection pool. Default: same as maximumPoolSize

该属性的默认值为10，Hikari为了追求最佳性能和相应尖峰需求，hikari不希望用户使用动态连接数，因为动态连接数会在空闲的时候减少连接、有大量请求过来会创建连接，但是但是创建连接耗时较长会影响RT。还有一个考虑就是隐藏风险，比如平时都是空载的 10个机器就是100个连接，其实数据库最大连接数比如是150个，等满载的时候就会报错了，这其实就是关闭动态调节的能力，跟 jvm 线上 xmx和xms 配一样是一个道理。动态调节不是完全没用，比如不同服务连一个db然后，业务高峰是错开的，这样的情况其实比较少。

更多配置解析请参见本系列第二篇《【追光者系列】HikariCP连接池配置项》

### 5.2 压测

连接池的分配与释放，对系统的性能有很大的影响。合理的分配与释放，可以提高连接的复用度，从而降低建立新连接的开销，同时还可以加快用户的访问速度。
连接池的大小设置多少合适呢？再分配多了效果也不大，一个是应用服务器维持这个连接数需要内存支持，并且维护大量的连接进行分配使用对cpu也是一个不小的负荷，因此不宜太大，虽然sleep线程增多对DBA来说目前线上已经可以忽略，但是能处理一下当然最好。如果太小，那么在上述规模项目的并发量以及数据量上来以后会造成排队现象，系统会变慢，数据库连接会经常打开和关闭，性能上有压力，用户体验也不好。
如何评估数据库连接池的性能是有专门的算法公式的，【追光者系列】后续会更新，不过经验值一般没有压测准，连接池太大、太小都会存在问题。具体设置多少，要看系统的访问量，可通过反复测试，找到最佳点。

## 6. HikariCP默认配置

根据spring-boot-autoconfigure 的 spring-configuration-metadata.json 文件研究一下HikariCP的默认配置。

```json
      {
      "sourceType": "org.springframework.boot.autoconfigure.jdbc.DataSourceConfiguration$Hikari",
      "name": "spring.datasource.hikari",
      "sourceMethod": "dataSource(org.springframework.boot.autoconfigure.jdbc.DataSourceProperties)",
      "type": "com.zaxxer.hikari.HikariDataSource"
    },
      {
      "sourceType": "com.zaxxer.hikari.HikariDataSource",
      "name": "spring.datasource.hikari.allow-pool-suspension",
      "type": "java.lang.Boolean"
    },
    {
      "sourceType": "com.zaxxer.hikari.HikariDataSource",
      "name": "spring.datasource.hikari.auto-commit",
      "type": "java.lang.Boolean"
    },
    {
      "sourceType": "com.zaxxer.hikari.HikariDataSource",
      "name": "spring.datasource.hikari.catalog",
      "type": "java.lang.String"
    },
    {
      "sourceType": "com.zaxxer.hikari.HikariDataSource",
      "name": "spring.datasource.hikari.connection-init-sql",
      "type": "java.lang.String"
    },
    {
      "sourceType": "com.zaxxer.hikari.HikariDataSource",
      "name": "spring.datasource.hikari.connection-test-query",
      "type": "java.lang.String"
    },
    {
      "sourceType": "com.zaxxer.hikari.HikariDataSource",
      "name": "spring.datasource.hikari.connection-timeout",
      "type": "java.lang.Long"
    },
    {
      "sourceType": "com.zaxxer.hikari.HikariDataSource",
      "name": "spring.datasource.hikari.data-source-class-name",
      "type": "java.lang.String"
    },
    {
      "sourceType": "com.zaxxer.hikari.HikariDataSource",
      "name": "spring.datasource.hikari.data-source-j-n-d-i",
      "type": "java.lang.String"
    },
    {
      "sourceType": "com.zaxxer.hikari.HikariDataSource",
      "name": "spring.datasource.hikari.data-source-properties",
      "type": "java.util.Properties"
    },
    {
      "sourceType": "com.zaxxer.hikari.HikariDataSource",
      "name": "spring.datasource.hikari.driver-class-name",
      "type": "java.lang.String"
    },
    {
      "sourceType": "com.zaxxer.hikari.HikariDataSource",
      "name": "spring.datasource.hikari.health-check-properties",
      "type": "java.util.Properties"
    },
    {
      "sourceType": "com.zaxxer.hikari.HikariDataSource",
      "name": "spring.datasource.hikari.health-check-registry",
      "type": "java.lang.Object"
    },
    {
      "sourceType": "com.zaxxer.hikari.HikariDataSource",
      "name": "spring.datasource.hikari.idle-timeout",
      "type": "java.lang.Long"
    },
    {
      "sourceType": "com.zaxxer.hikari.HikariDataSource",
      "deprecated": true,
      "name": "spring.datasource.hikari.initialization-fail-fast", //initializationFailTimeout > 0
      "type": "java.lang.Boolean",
      "deprecation": {}
    },
    {
      "sourceType": "com.zaxxer.hikari.HikariDataSource",
      "name": "spring.datasource.hikari.initialization-fail-timeout",
      "type": "java.lang.Long"
    },
    {
      "sourceType": "com.zaxxer.hikari.HikariDataSource",
      "name": "spring.datasource.hikari.isolate-internal-queries",
      "type": "java.lang.Boolean"
    },
    {
      "sourceType": "com.zaxxer.hikari.HikariDataSource",
      "name": "spring.datasource.hikari.jdbc-url",
      "type": "java.lang.String"
    },
    {
      "sourceType": "com.zaxxer.hikari.HikariDataSource",
      "deprecated": true,
      "name": "spring.datasource.hikari.jdbc4-connection-test", //废弃
      "type": "java.lang.Boolean",
      "deprecation": {}
    },
    {
      "sourceType": "com.zaxxer.hikari.HikariDataSource",
      "name": "spring.datasource.hikari.leak-detection-threshold",
      "type": "java.lang.Long"
    },
    {
      "sourceType": "com.zaxxer.hikari.HikariDataSource",
      "name": "spring.datasource.hikari.login-timeout", //在HikariDataSource及PoolBase中
      "type": "java.lang.Integer"
    },
    {
      "sourceType": "com.zaxxer.hikari.HikariDataSource",
      "name": "spring.datasource.hikari.max-lifetime",
      "type": "java.lang.Long"
    },
    {
      "sourceType": "com.zaxxer.hikari.HikariDataSource",
      "name": "spring.datasource.hikari.maximum-pool-size",
      "type": "java.lang.Integer"
    },
    {
      "sourceType": "com.zaxxer.hikari.HikariDataSource",
      "name": "spring.datasource.hikari.metric-registry",
      "type": "java.lang.Object"
    },
    {
      "sourceType": "com.zaxxer.hikari.HikariDataSource",
      "name": "spring.datasource.hikari.metrics-tracker-factory",
      "type": "com.zaxxer.hikari.metrics.MetricsTrackerFactory"
    },
    {
      "sourceType": "com.zaxxer.hikari.HikariDataSource",
      "name": "spring.datasource.hikari.minimum-idle",
      "type": "java.lang.Integer"
    },
    {
      "sourceType": "com.zaxxer.hikari.HikariDataSource",
      "name": "spring.datasource.hikari.password",
      "type": "java.lang.String"
    },
    {
      "sourceType": "com.zaxxer.hikari.HikariDataSource",
      "name": "spring.datasource.hikari.pool-name",
      "type": "java.lang.String"
    },
    {
      "sourceType": "com.zaxxer.hikari.HikariDataSource",
      "name": "spring.datasource.hikari.read-only",
      "type": "java.lang.Boolean"
    },
    {
      "sourceType": "com.zaxxer.hikari.HikariDataSource",
      "name": "spring.datasource.hikari.register-mbeans",
      "type": "java.lang.Boolean"
    },
    {
      "sourceType": "com.zaxxer.hikari.HikariDataSource",
      "name": "spring.datasource.hikari.scheduled-executor",
      "type": "java.util.concurrent.ScheduledExecutorService"
    },
    {
      "sourceType": "com.zaxxer.hikari.HikariDataSource",
      "deprecated": true,
      "name": "spring.datasource.hikari.scheduled-executor-service",
      "type": "java.util.concurrent.ScheduledThreadPoolExecutor",
      "deprecation": {}
    },
    {
      "sourceType": "com.zaxxer.hikari.HikariDataSource",
      "name": "spring.datasource.hikari.schema",
      "type": "java.lang.String"
    },
    {
      "sourceType": "com.zaxxer.hikari.HikariDataSource",
      "name": "spring.datasource.hikari.transaction-isolation", //transactionIsolationName
      "type": "java.lang.String"
    },
    {
      "sourceType": "com.zaxxer.hikari.HikariDataSource",
      "name": "spring.datasource.hikari.username",
      "type": "java.lang.String"
    },
    {
      "sourceType": "com.zaxxer.hikari.HikariDataSource",
      "name": "spring.datasource.hikari.validation-timeout",
      "type": "java.lang.Long"
    },
```

主要参数是在com.zaxxer.hikari.HikariConfig中初始化的，部分参数是在com.zaxxer.hikari.pool.PoolBase中初始化的。
Springboot 2.0的autoconfig是采用BeanUtils的反射来初始化HikariDataSource，走的是默认构造器，因此校验就依赖set方法及后续的getConnection方法（HikariConfig类中在set方法添加了参数校验，同时在configuration的构造器以及getConnection方法中也调用了validate方法）。

| name                      | 构造器默认值                   | 默认配置validate之后的值 | validate重置                                                 |
| ------------------------- | ------------------------------ | ------------------------ | ------------------------------------------------------------ |
| minIdle                   | -1                             | 10                       | minIdle<0或者minIdle>maxPoolSize,则被重置为maxPoolSize       |
| maxPoolSize               | -1                             | 10                       | 如果maxPoolSize小于1，则会被重置。当minIdle<=0被重置为DEFAULT_POOL_SIZE则为10;如果minIdle>0则重置为minIdle的值 |
| maxLifetime               | MINUTES.toMillis(30) = 1800000 | 1800000                  | 如果不等于0且小于30秒则会被重置回30分钟                      |
| connectionTimeout         | SECONDS.toMillis(30) = 30000   | 30000                    | 如果小于250毫秒，则被重置回30秒                              |
| validationTimeout         | SECONDS.toMillis(5) = 5000     | 5000                     | 如果小于250毫秒，则会被重置回5秒                             |
| loginTimeout              | 10                             | 30                       | Math.max(1, (int) MILLISECONDS.toSeconds(500L + connectionTimeout))，为connectionTimeout+500ms转为秒数取整 与 1 取最大者 |
| idleTimeout               | MINUTES.toMillis(10) = 600000  | 600000                   | 如果idleTimeout+1秒>maxLifetime 且 maxLifetime>0，则会被重置为0；如果idleTimeout!=0且小于10秒，则会被重置为10秒 |
| leakDetectionThreshold    | 0                              | 0                        | 如果大于0且不是单元测试，则进一步判断：(leakDetectionThreshold < SECONDS.toMillis(2) or (leakDetectionThreshold > maxLifetime && maxLifetime > 0)，会被重置为0 . 即如果要生效则必须>0，而且不能小于2秒，而且当maxLifetime > 0时不能大于maxLifetime |
| initializationFailTimeout | 1                              | 1                        | -                                                            |
| isAutoCommit              | true                           | true                     | -                                                            |
| isReadOnly                | false                          | fasle                    | -                                                            |
| isAllowPoolSuspension     | false                          | false                    | -                                                            |
| isIsolateInternalQueries  | false                          | false                    | -                                                            |
| isRegisterMbeans          | false                          | false                    | -                                                            |
| sealed                    | false                          | true                     | 运行启动后这个标志为true，表示不再运行修改                   |
| poolName                  | null                           | HikariPool-1             | -                                                            |
| catalog                   | null                           | null                     | -                                                            |
| connectionInitSql         | null                           | null                     | -                                                            |
| connectionTestQuery       | null                           | null                     | -                                                            |
| dataSourceClassName       | null                           | null                     | -                                                            |
| schema                    | null                           | null                     | -                                                            |
| transactionIsolationName  | null                           | null                     | -                                                            |
| dataSource                | null                           | null                     | -                                                            |
| dataSourceProperties      | {}                             | {}                       | -                                                            |
| threadFactory             | null                           | null                     | -                                                            |
| scheduledExecutor         | null                           | null                     | -                                                            |
| metricsTrackerFactory     | null                           | null                     | -                                                            |
| metricRegistry            | null                           | null                     | -                                                            |
| healthCheckRegistry       | null                           | null                     | -                                                            |
| healthCheckProperties     | {}                             | {}                       | -                                                            |

## 7. Hikari连接池配多大合适？

首先声明一下观点：How big should HikariCP be? Not how big but rather how small！连接池的大小不是设置多大，不是越多越好，而是应该少到恰到好处。
本文提及的是客户端的线程池大小，数据库服务器另有不同的估算方法。

1. 经验值&FlexyPool
2. Less Is More
   - 2.1 公式：connections =（（core_count * 2）+ effective_spindle_count）
   - 2.2 公理：You want a small pool, saturated with threads waiting for connections.
3.  Pool-locking 池锁
4. 具体问题具体分析

### 7.1 经验值&FlexyPool

我所在公司260多个应用的线上连接池默认经验值是如下配置的：

```
maximumPoolSize: 20
minimumIdle: 10
```

而Hikari的默认值是maximumPoolSize为10，而minimumIdle强烈建议不要配置、默认值与maximumPoolSize相同。我公司maximumPoolSize基本上这个值将决定到数据库后端的最大实际连接数，对此的合理价值最好由实际的执行环境决定；我公司保留minimumIdle的值（并不是不设置）是为了防止空闲很久时创建连接耗时较长从而影响RT。
不过我还是比较倾向作者的观点，尽量不要minimumIdle，允许HikariCP充当固定大小的连接池，毕竟我相信追求极致的Hikari一定可以尽最大努力快速高效地添加其他连接，从而获得最佳性能和响应尖峰需求

> **minimumIdle** 
> This property controls the minimum number of idle connections that HikariCP tries to maintain in the pool. If the idle connections dip below this value and total connections in the pool are less than maximumPoolSize, HikariCP will make a best effort to add additional connections quickly and efficiently. However, for maximum performance and responsiveness to spike demands, we recommend not setting this value and instead allowing HikariCP to act as a fixed size connection pool. Default: same as maximumPoolSize
>
> **maximumPoolSize**
> This property controls the maximum size that the pool is allowed to reach, including both idle and in-use connections. Basically this value will determine the maximum number of actual connections to the database backend. A reasonable value for this is best determined by your execution environment. When the pool reaches this size, and no idle connections are available, calls to getConnection() will block for up to connectionTimeout milliseconds before timing out. Please read about pool sizing. Default: 10

HikariCP的初始版本只支持固定大小的池。作者初衷是，HikariCP是专门为具有相当恒定负载的系统而设计的，并且在倾向连接池大小于保持其运行时允许达到的最大大小，所以作者认为没有必要将代码复杂化以支持动态调整大小。毕竟你的系统会闲置很久么？另外作者认为配置项越多，用户配置池的难度就越大。但是呢，确实有一些用户需要动态调整连接池大小，并且没有就不行，所以作者就增加了这个功能。但是原则上，作者并不希望缺乏动态的大小支持会剥夺用户享受HikariCP的可靠性和正确性的好处。

如果想要支持动态调整不同负载的最佳池大小设置，可以配合Hikari使用同为the Mutual Admiration Society成员的Vlad Mihalcea研究的FlexyPool。当然，连接池上限受到数据库最优并发查询容量的限制，这正是Hikari关于池大小的起作用的地方。然而，在池的最小值和最大值之间，FlexyPool不断尝试递增，确保该池大小在服务提供服务的过程中动态负载是一直正确的。

FlexyPool是一种reactive的连接池。其作者认为确定连接池大小不是前期设计决策的，在大型企业系统中，需要适应性和监控是做出正确决策的第一步。

FlexyPool具有以下默认策略

- 在超时时递增池。此策略将增加连接获取超时时的目标连接池最大大小。连接池具有最小的大小，并可根据需要增长到最大大小。该溢出是多余的连接，让连接池增长超过其初始的缓冲区最大尺寸。每当检测到连接获取超时时，如果池未增长到其最大溢出大小，则当前请求将不会失败。
- 重试尝试。此策略对于那些缺少连接获取重试机制的连接池非常有用。

由于本文主要谈Hikari，所以FlexyPool请各位读者自行阅读
https://github.com/vladmihalcea/flexy-pool
https://vladmihalcea.com/
http://www.importnew.com/12342.html

### 7.2 Less Is More

众所周知，一个CPU核心的计算机可以同时执行数十或数百个线程，其实这只是操作系统的一个把戏-time-slicing（时间切片）。实际上，该单核只能一次执行一个线程，然后操作系统切换上下文，并且该内核为另一个线程执行代码，依此类推。这是一个基本的计算法则，给定一个CPU资源，按顺序执行A和B 总是比通过时间片“同时” 执行A和B要快。一旦线程数量超过了CPU核心的数量，添加更多的线程就会变慢，而不是更快。
某用户做过测试（见参考资料），得到结论**1个线程写10个记录比10个线程各写1个记录快。**使用jvisualvm监控程序运行时，也可以看出来thread等待切换非常多。设计多线程是为了尽可能利用CPU空闲等待时间（等IO，等交互…），它的代价就是要增加部分CPU时间来实现线程切换。假如CPU空闲等待时间已经比线程切换更短，（线程越多，切换消耗越大）那么线程切换会非常影响性能，成为系统瓶颈。

其实还有一些因素共同作用，数据库的主要瓶颈是CPU，磁盘，网络（内存还不算最主要的）。

**公式：connections =（（core_count * 2）+ effective_spindle_count）**

effective_spindle_count is the number of disks in a RAID.就是磁盘列阵中的硬盘数，hard disk.某PostgreSQL项目做过测试，一个硬盘的小型4核i7服务器连接池大小设置为： 9 = ((4 * 2) + 1)。这样的连接池大小居然可以轻松处理3000个前端用户在6000 TPS下运行简单查询。

我们公司线上机器标准是2核，有需求可以申请4核、8核，16核一般不开。虚拟机一般都是线程，宿主机一般是2个逻辑CPU。虚拟机默认就一块硬盘，物理机有十几块。

**公理：You want a small pool, saturated with threads waiting for connections.**

在公式的配置上，如果加大压力，TPS会下降，RT会上升，你可以适当根据情况进行调整加大。**这时考虑整体系统性能，考虑线程执行需要的等待时间，设计合理的线程数目**。但是，**不要过度配置你的数据库**。

### 7.3 Pool-locking 池锁

增大连接池大小可以缓解池锁问题，**但是扩大池之前是可以先检查一下应用层面能够调优，不要直接调整连接池大小**。
避免池锁是有一个公式的：

> pool size = Tn x (Cm - 1) + 1

T n是线程的最大数量，C m是单个线程持有的同时连接的最大数量。
例如，设想三个线程（T n = 3），每个线程需要四个连接来执行某个任务（C m = 4）。确保永不死锁的池大小是： 3 x（4 - 1）+ 1 = 10。
另一个例子，你最多有8个线程（T n = 8），每个线程需要三个连接来执行一些任务（C m = 3）。确保死锁永远不可能的池大小是： 8×（3-1）+ 1 = 17

- 这不一定是最佳池大小，但是是避免死锁所需的最低限度。
- 在某些环境中，使用JTA（Java事务管理器）可以显着减少从同一个Connection返回getConnection()到当前事务中已经存储Connection的线程所需的连接数。

### 7.4 具体问题具体分析

混合了长时间运行事务和非常短的事务的系统通常是最难调整任何连接池的系统。在这些情况下，创建两个池实例可以很好地工作（例如，一个用于长时间运行的作业，另一个用于“实时”查询）。
如果长期运行的外部系统，例如只允许一定数量的作业同时运行的作业执行队列，这是作业队列大小就是连接池非常合适的大小。

最后，我要说的是：

**连接池大家是综合每个应用系统的业务逻辑特性，加上应用硬件配置，加上应用部署数量，再加上db硬件配置和最大允许连接数测试出来的。很难有一个简单公式进行计算。连接数及超时时间设置不正确经常会带来较大的性能问题，并影响整个服务能力的稳定性。具体设置多少，要看系统的访问量，可通过反复测试，找到最佳点。压测很重要。**

# 

## 参考

[【追光者系列】HikariCP连接池监控指标实战](https://mp.weixin.qq.com/s/LwHd5dUGHmOsNoPEj6l1cA)

[【追光者系列】HikariCP默认配置](https://mp.weixin.qq.com/s/oWCi7aTISaYWMlRllxghxg)

[【追光者系列】Hikari连接池配多大合适？](https://mp.weixin.qq.com/s/WbBIJHbLNKfZ77_pPVT1qw)

