## 1. 问题描述

2018年4月19日早上，有业务方反馈每半小时都会打出如下异常：

```java
HikariPool-1 - Failed to validate connection com.mysql.jdbc.JDBC4Connection@7174224b (No operations allowed after connection closed.)
```

业务方的需求是：这种日志需要配置能够消除？我能如何调优参数才能关闭这些日志？是不是我的 hikariCP 的 connectionTimeout 是不是每个业务的查询超时时间？

首先解释一下 connectionTimeout 的意思，这并不是获取连接的超时时间，而是从连接池返回连接的超时时间。SQL 执行的超时时间，JDBC 可以直接使用 Statement.setQueryTimeout，Spring 可以使用 @Transactional(timeout=10)。

维护 HikariCP 相关的中间件也有8个月的时间了，我知道该异常其实是不影响业务的，但是这8个月期间经常不断的有业务方咨询同一个问题，所以我觉得很有必要认真地梳理一下该问题源码级的具体原理及根本原因来给业务方一个合理的交代。

## 2.望闻问切

进行了一波详细的勘查，又拿到了如下信息

- 该业务没有上线，在线下环境暴露出的问题
- 线上服务查了几个服务没有这样的问题
- 业务方一开始说线下环境50～100QPS，但是实际业务方并没有调用
- springboot微服务的health check我司每10秒执行一次，可以理解为进行一次getConnection操作
- 业务方没有做任何配置，hikariCP的默认maxLifetime是30分钟，和业务方的表象吻合
- **波及业务线下扫出了五个应用有同样的问题**
- 拉取业务方代码debug，maxLifetime调整为20分钟，该异常也平均是20分钟输出一次
- hikariCP的maximumPoolSize为10，按理说异常也应该是10，但是实际是大多落在8左右，也有可能是9，极小情况是11。当调小maxLifetime为一分钟时，异常数目每阶段时间出现暴增现象。

采用了kibana协助排查问题，得到的信息如下：

如下图所示，平均每半小时出现一波异常，规律性很强，20:00时由于我将maxLifetime调整为一分钟，异常数目飙升，之后我把maxLifetime调整为二十分钟，就呈现出每20分钟出现一波异常

```java
HikariPool-1 - Failed to validate connection com.mysql.jdbc.JDBC4Connection@7174224b (No operations allowed after connection closed.)
```

<img src="http://blog-1259650185.cosbj.myqcloud.com/img/202205/16/1652665792.jpeg" alt="6" style="zoom:67%;" />

具体异常我抽样以后展示如下，按照时间倒序排列，之前是默认30分钟，后面调整为20分钟：

<img src="http://blog-1259650185.cosbj.myqcloud.com/img/202205/16/1652665843.jpeg" alt="7" style="zoom:67%;" />

## 3. brettw如是说

在stackoverflow已经有用户提出了同样类似的问题：

https://stackoverflow.com/questions/41008350/no-operations-allowed-after-connection-closed-errors-in-slick-hikaricp

<img src="http://blog-1259650185.cosbj.myqcloud.com/img/202205/16/1652665968.jpeg" alt="8" style="zoom:67%;" />

该用户每3秒运行一次查询，每次查询的时间都小于0.4s。起初一切运行正常，但大约2小时后，HikariCP开始关闭连接，导致关于'no operations allowed after connection closed'的错误：

```java
15:20:38.288 DEBUG [] [rdsConfig-8] com.zaxxer.hikari.pool.HikariPool - rdsConfig - Timeout failure stats (total=30, active=0, idle=30, waiting=0)
15:20:38.290 DEBUG [] [rdsConfig connection closer] com.zaxxer.hikari.pool.PoolBase - rdsConfig - Closing connection com.mysql.jdbc.JDBC4Connection@229960c: (connection is evicted or dead)
15:20:38.333 DEBUG [] [rdsConfig connection closer] com.zaxxer.hikari.pool.PoolBase - rdsConfig - Closing connection com.mysql.jdbc.JDBC4Connection@229960c failed
com.mysql.jdbc.exceptions.jdbc4.MySQLNonTransientConnectionException: No operations allowed after connection closed.
    at sun.reflect.NativeConstructorAccessorImpl.newInstance0(Native Method) ~[na:1.8.0_77]
    at sun.reflect.NativeConstructorAccessorImpl.newInstance(Unknown Source) ~[na:1.8.0_77]
    at sun.reflect.DelegatingConstructorAccessorImpl.newInstance(Unknown Source) ~[na:1.8.0_77]
    at java.lang.reflect.Constructor.newInstance(Unknown Source) ~[na:1.8.0_77]
```

该用户也是期望怎么配置来避免此情况？这和我的业务方的诉求是完全一致的。该用户并不理解 HikariCP 关闭连接的原理，非常困惑。所以我们很有必要给用户一个交代。

作者表示，HikariCP 在使用时不会关闭连接。如果使用中的连接到达最大存活时间，maxLifetime 它将被标记为驱逐，并且在下一次线程尝试借用它时将被驱逐。

<img src="http://blog-1259650185.cosbj.myqcloud.com/img/202205/16/1652666080.jpeg" alt="9" style="zoom:67%;" />

如上图所示，作者说明在五种情况下 HikariCP 会关闭连接，分别是连接验证失败、连接闲置时间超过 idleTimeout、一个连接到达了它maxLifetime、用户手动驱逐连接、一个JDBC调用抛出一个不可恢复的 SQLException。每一种情况都会打印不一样的异常，

有人去看医生，说他拉肚子了，那医生能开一样的药么？引起腹泻原因很多,比如肚子受凉、饮食不卫生、消化不良、食物过敏、感染病毒。针对不同的症状要采用不同的治疗手段。

同理，虽然都是No operations allowed after connection closed，该用户是打出了connection is evicted or dead，属于第三种情况 **A connection reached its maxLifetime**，而我们的异常是这样的，和该用户的提问其实不一样的，我们命中的是第一种情况 **The connection failed validation**

```java
HikariPool-1 - Failed to validate connection com.mysql.jdbc.JDBC4Connection@50962fdc (No operations allowed after connection closed.)
```

作者提及This is invisible to your application.这对应用程序是不可见的，可见这不是一个问题。

但是总让业务方打日志也不是一个办法？不给业务方一个交代也是不行的。更何况只有线下才有这样频繁的日志，线上是没有的，这其中必有猫腻。

我们按照这个思路也来分解一下：

1. 是不是这几个服务依赖的中间件版本不同导致的？
2. 是不是数据库给断掉了？
3. 两种情况：被外部关闭了、有代码操作了内部的connection对象，是哪种情况干的？
4. 异常是哪里抛出来的？

针对这些疑点，我们来分析一下：

1. 半年来经常有业务方咨询此问题，根据出问题的五个应用，发现分布在三种主流版本里
2. 登陆业务方数据库，show variables like '%timeout%’，发现mysql参数并没有问题，咨询了DBA，线下也没有做什么修改
3. 基本可以排除第一种情况，操作了内部的connection对象可能性比较大
4. 异常是setNetworkTimeout里面抛出来的，实现类是JDBC4Connection connectionimpl ping的时候报错了。mysql把isvalid方法里的错误吃掉了比较坑，isvalid方法里面报错了会调用close方法，然后hikari外层又调了一次settimeout就触发了这个warn

<img src="http://blog-1259650185.cosbj.myqcloud.com/img/202205/16/1652668384.jpeg" alt="10" style="zoom:67%;" />

## 4. 大胆猜想

1. HikariCP使用List来保存打开的Statement，当Statement关闭或Connection关闭时需要将对应的Statement从List中移除。FastList是从数组的尾部开始遍历。CopyOnWriteArrayList负责存放ConcurrentBag中全部用于出借的资源，getConnection方法borrow正是ConcurrentBag的CopyOnWriteArrayList，copyonwrite是拿的数组首。所以健康检测下低QPS下连接池取出对象永远是从CopyOnWriteArrayList sharedList数组的首部取出的那个？
2. 结合第一点猜想，数组中的其他连接（除了队首的），可能在10～20分钟之内已经被mysql断掉了？
3. 需要把源码中核心操作流程里的对象都打印出来，去观察拿到更多的信？
4. 一分钟没事，20分钟 30分钟有事，是不是因为一分钟数据库没有断掉？而20～30分钟的却已经断掉了？需要结合mysql的信息去看
5. 线上高QPS所有连接都处于和数据库活跃的连接及切换状态，所以异常远远小于线下的原因是，只有数组首部取出的那个和数据库交互的流程？
6. 数组首以外的一些连接是否被内部的connection操作了

## 5. 直奔疑点

首先我直接怀疑是不是数据库断掉了连接，于是登上了数据库查询了数据库参数，结果是没毛病。
为了稳妥起见，我又咨询了DBA，DBA说线下环境和线上环境参数一样，并帮我看了，没有任何问题。

<img src="http://blog-1259650185.cosbj.myqcloud.com/img/202205/16/1652668582.jpeg" alt="11" style="zoom:67%;" />

为什么我直接奔向这个疑点，因为《Solr权威指南》的作者兰小伟大佬曾经和我分享过一个案例：
他前段时间也遇到类似的问题，他用的是c3p0，碰到和我一样的碰到一样的exception，那个异常是服务器主动关闭了链接，而客户端还拿那个链接去操作，大佬加个testQuery，保持心跳即可解决。c3p0设置一个周期，是定时主动检测的。
估计是mysql服务器端链接缓存时间设置的太短，服务器端主动销毁了链接，一般做法是客户端连接池配置testQuery。
testQuery我觉得比较影响hikariCP的性能，所以我决定跟一下源码了解一下原理并定位问题。

## 6. 拨开迷雾

按着上一篇的推测，我们在Hikari核心源码中打一些日志记录。

第一处，在com.zaxxer.hikari.pool.HikariPool#getConnection中增加IDEA log expression

```java
  public Connection getConnection(final long hardTimeout) throws SQLException
   {
      suspendResumeLock.acquire();
      final long startTime = currentTime();
      try {
         long timeout = hardTimeout;
         PoolEntry poolEntry = null;
         try {
            do {
               poolEntry = connectionBag.borrow(timeout, MILLISECONDS);
               if (poolEntry == null) {
                  break; // We timed out... break and throw exception
               }
               final long now = currentTime();
               if (poolEntry.isMarkedEvicted() || (elapsedMillis(poolEntry.lastAccessed, now) > ALIVE_BYPASS_WINDOW_MS && !isConnectionAlive(poolEntry.connection))) {
                  closeConnection(poolEntry, "(connection is evicted or dead)"); // Throw away the dead connection (passed max age or failed alive test)
                  timeout = hardTimeout - elapsedMillis(startTime);
               }
               else {
                  metricsTracker.recordBorrowStats(poolEntry, startTime);
                  return poolEntry.createProxyConnection(leakTask.schedule(poolEntry), now);
               }
            } while (timeout > 0L);
            metricsTracker.recordBorrowTimeoutStats(startTime);
         }
         catch (InterruptedException e) {
            if (poolEntry != null) {
               poolEntry.recycle(startTime);
            }
            Thread.currentThread().interrupt();
            throw new SQLException(poolName + " - Interrupted during connection acquisition", e);
         }
      }
      finally {
         suspendResumeLock.release();
      }
      throw createTimeoutException(startTime);
   }
```

我们对于直接抛异常的代码的条件判断入口处增加调试信息

```java
if (poolEntry.isMarkedEvicted() || (elapsedMillis(poolEntry.lastAccessed, now) > ALIVE_BYPASS_WINDOW_MS && !isConnectionAlive(poolEntry.connection)))
String.format("Evicted: %s; enough time elapse: %s;poolEntrt: %s;", poolEntry.isMarkedEvicted(), elapsedMillis(poolEntry.lastAccessed, now) > ALIVE_BYPASS_WINDOW_MS,poolEntry);
```

第二处、在com.zaxxer.hikari.pool.HikariPool#softEvictConnection处增加调试信息

```java
private boolean softEvictConnection(final PoolEntry poolEntry, final String reason, final boolean owner)
   {
      poolEntry.markEvicted();
      if (owner || connectionBag.reserve(poolEntry)) {
         closeConnection(poolEntry, reason);
         return true;
      }
      return false;
   }
String.format("Scheduled soft eviction for connection %s is due; owner %s is;", poolEntry.connection,owner)
```

为什么要打在softEvictConnection这里呢？因为在createPoolEntry的时候注册了一个延时任务，并通过poolEntry.setFutureEol设置到poolEntry中
softEvictConnection，首先标记markEvicted。然后如果是用户自己调用的，则直接关闭连接；如果从connectionBag中标记不可borrow成功，则关闭连接。
这个定时任务是在每次createPoolEntry的时候，根据maxLifetime随机设定一个variance，在maxLifetime - variance之后触发evict。

```java
   /**
    * Creating new poolEntry.
    */
   private PoolEntry createPoolEntry()
   {
      try {
         final PoolEntry poolEntry = newPoolEntry();
         final long maxLifetime = config.getMaxLifetime();
         if (maxLifetime > 0) {
            // variance up to 2.5% of the maxlifetime
            final long variance = maxLifetime > 10_000 ? ThreadLocalRandom.current().nextLong( maxLifetime / 40 ) : 0;
            final long lifetime = maxLifetime - variance;
            poolEntry.setFutureEol(houseKeepingExecutorService.schedule(
               () -> {
                  if (softEvictConnection(poolEntry, "(connection has passed maxLifetime)", false /* not owner */)) {
                     addBagItem(connectionBag.getWaitingThreadCount());
                  }
               },
               lifetime, MILLISECONDS));
         }
         return poolEntry;
      }
      catch (Exception e) {
         if (poolState == POOL_NORMAL) {
            LOGGER.debug("{} - Cannot acquire connection from data source", poolName, (e instanceof ConnectionSetupException ? e.getCause() : e));
         }
         return null;
      }
   }
```

## 7. 守株待兔

做了如上处理之后我们就安心得等结果

<img src="http://blog-1259650185.cosbj.myqcloud.com/img/202205/16/1652668933.jpeg" alt="12" style="zoom:67%;" />

很快来了一组数据，我们可以看到确实poolEntry.isMarkedEvicted()一直都是false,(elapsedMillis(poolEntry.lastAccessed, now) > ALIVE_BYPASS_WINDOW_MS这个判断为true。

sharedlist 是 CopyOnWriteArrayList，每次getConnection都是数组首

softEvictConnection这里的信息在20分钟到了的时候也出现了

<img src="http://blog-1259650185.cosbj.myqcloud.com/img/202205/16/1652669139.jpeg" alt="13" style="zoom:67%;" />

从这张图我们可以看到，owner是false，第一个触发定时任务的也正好是第一个连接。删除的那个就是每次微服务健康检测healthcheck连接用的那个。

<img src="http://blog-1259650185.cosbj.myqcloud.com/img/202205/16/1652669272.jpeg" alt="14" style="zoom:67%;" />

我仔细数了一下，确实一共创建了十次SSL，也就是本次周期确实重新连了十次数据库TCP连接。那么问题来了，为什么每次正好是8次或者9次异常日志？

## 8. 抽丝剥茧

定时任务的执行时间是多少？

这个定时任务是在每次createPoolEntry的时候，根据maxLifetime随机设定一个variance，在maxLifetime - variance之后触发evict。
maxLifetime我现在设置的是20分钟，

```java
// variance up to 2.5% of the maxlifetime
            final long variance = maxLifetime > 10_000 ? ThreadLocalRandom.current().nextLong( maxLifetime / 40 ) : 0;
            final long lifetime = maxLifetime - variance
```

按照20分钟1200秒来算，这个evict的操作是1170秒左右,按理说离20分钟差30秒左右。

但是通过观察，好像第一个连接创建的时间比其他连接快4秒。

<img src="http://blog-1259650185.cosbj.myqcloud.com/img/202205/16/1652669338.jpeg" alt="15" style="zoom:67%;" />

也就是说时间上被错开了，本来10个连接是相近的时间close的，第一个连接先被定时器close了，其他连接是getconnection的时候close的，这样就造成了一个循环。其他连接是getconnection的时候几乎同时被关闭的，就是哪些warn日志出现的时候。

这猜想和我debug得到的结果是一致的，第一个getConnection健康监测是被定时器close的，close之后立马fillpool，所以warn的是小于10的。和我们看到的历史数据一样，8为主，也有9。

<img src="http://blog-1259650185.cosbj.myqcloud.com/img/202205/16/1652669372.jpeg" alt="16" style="zoom:67%;" />

定时器close之后的那个新连接，会比其他的连接先进入定时器的调度，其他的9个被循环报错关闭。

<img src="http://blog-1259650185.cosbj.myqcloud.com/img/202205/16/1652669393.jpeg" alt="17" style="zoom:67%;" />

getconnection时报错关闭的那些连接，跟被定时器关闭的连接的定时器时间错开，如上图所示，有两个连接已经处于remove的状态了。

9次是比较好解释的，第一个连接是同步创建的，构造函数里调用checkFailFast会直接建一个连接，其他连接是 housekeeper里异步fillpool创建的。

做了一次测试，这一波果然打了9次日志

![18](http://blog-1259650185.cosbj.myqcloud.com/img/202205/16/1652669423.jpeg)

那么9次就可以这么合理的解释了。

8次的解释应该就是如上图所示2个已经被remove掉的可能性情况。

## 9. 柳暗花明

这时小手一抖，netstat了一把

<img src="http://blog-1259650185.cosbj.myqcloud.com/img/202205/16/1652669448.jpeg" alt="19" style="zoom:67%;" />

<img src="http://blog-1259650185.cosbj.myqcloud.com/img/202205/16/1652669465.jpeg" alt="20" style="zoom:67%;" />

发现很快就closewait了，而closewait代表已经断开了，基本不能再用了。其实就是被对方断开了。

这时我又找了DBA，告诉他我得到的结论，DBA再次帮我确认之后，焦急的等待以后，屏幕那头给我这么一段回复：

<img src="http://blog-1259650185.cosbj.myqcloud.com/img/202205/16/1652669489.jpeg" alt="21" style="zoom:67%;" />

这时叫了一下配置中心的同学一起看了一下这个数据库的地址，一共有5个配置连到了这个废弃的proxy，和我们线上出问题的数目和应用基本一致！

配置中心的同学和DBA说这个proxy曾经批量帮业务方改过，有些业务方居然又改回去了。。。。这时业务方的同学也说话了，“难怪我navicate 在proxy上edit一个表要等半天。。stable环境就秒出”

## 10. 真相大白

修改了这个废弃的proxy改为真正的数据库地址以后，第二天业务方的同学给了我们反馈：

<img src="http://blog-1259650185.cosbj.myqcloud.com/img/202205/16/1652669549.jpeg" alt="22" style="zoom:67%;" />

图左边2个绿色箭头，下面那个是调整过配置的环境，上面是没有调整的，调整过的今天已经没有那个日志了，那17.6%是正常的业务日志。



## 参考

[【追光者系列】HikariCP诡异问题拨开迷雾推理破案实录（上）](https://mp.weixin.qq.com/s/vm-1bDnVrxbjdWd-3I-4uA)

[【追光者系列】HikariCP诡异问题拨开迷雾推理破案实录（下）](https://mp.weixin.qq.com/s/ZImQievDPLAfOv26HZOiQg)
