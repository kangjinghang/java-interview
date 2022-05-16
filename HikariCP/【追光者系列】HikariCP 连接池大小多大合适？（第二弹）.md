首先推荐大家可以看一下 [【追光者系列】Hikari连接池配多大合适？](http://mp.weixin.qq.com/s?__biz=MzUzNTY4NTYxMA==&mid=2247483731&idx=1&sn=b81013c6af5e6e62d5ac8d8a26e2b848&chksm=fa80f1d6cdf778c03aec5b9db0e539b5ad0efae471324a8735828762998b6703a8bb8b226ac4&scene=21#wechat_redirect)

fixed pool designHow to set minimumIdle参考资料

## 1. fixed pool design

在启动时，HikariCP使用配置的最大连接数maximumPoolSize填充池，并在池的使用期限内维护它们。这可以在com.zaxxer.hikari.pool.HikariPool的HouseKeeper里看到，这个task在第一次执行的时候，直接执行fillPool。

```java
/**
    * The house keeping task to retire and maintain minimum idle connections.
    */
   private final class HouseKeeper implements Runnable
   {
      private volatile long previous = plusMillis(currentTime(), -HOUSEKEEPING_PERIOD_MS);
      @Override
      public void run()
      {
         try {
            // refresh timeouts in case they changed via MBean
            connectionTimeout = config.getConnectionTimeout();
            validationTimeout = config.getValidationTimeout();
            leakTaskFactory.updateLeakDetectionThreshold(config.getLeakDetectionThreshold());
            final long idleTimeout = config.getIdleTimeout();
            final long now = currentTime();
            // Detect retrograde time, allowing +128ms as per NTP spec.
            if (plusMillis(now, 128) < plusMillis(previous, HOUSEKEEPING_PERIOD_MS)) {
               LOGGER.warn("{} - Retrograde clock change detected (housekeeper delta={}), soft-evicting connections from pool.",
                           poolName, elapsedDisplayString(previous, now));
               previous = now;
               softEvictConnections();
               return;
            }
            else if (now > plusMillis(previous, (3 * HOUSEKEEPING_PERIOD_MS) / 2)) {
               // No point evicting for forward clock motion, this merely accelerates connection retirement anyway
               LOGGER.warn("{} - Thread starvation or clock leap detected (housekeeper delta={}).", poolName, elapsedDisplayString(previous, now));
            }
            previous = now;
            String afterPrefix = "Pool ";
            if (idleTimeout > 0L && config.getMinimumIdle() < config.getMaximumPoolSize()) {
               logPoolState("Before cleanup ");
               afterPrefix = "After cleanup  ";
               final List<PoolEntry> notInUse = connectionBag.values(STATE_NOT_IN_USE);
               int toRemove = notInUse.size() - config.getMinimumIdle();
               for (PoolEntry entry : notInUse) {
                  if (toRemove > 0 && elapsedMillis(entry.lastAccessed, now) > idleTimeout && connectionBag.reserve(entry)) {
                     closeConnection(entry, "(connection has passed idleTimeout)");
                     toRemove--;
                  }
               }
            }
            logPoolState(afterPrefix);
            fillPool(); // Try to maintain minimum connections
         }
         catch (Exception e) {
            LOGGER.error("Unexpected exception in housekeeping task", e);
         }
      }
   }
```

fillPool，在初始化时刻，minimumIdle与maximumPoolSize值一样，totalConnections与idleConnections都为0，那么connectionsToAdd的值就是maximumPoolSize，也就是说这个task会添加maximumPoolSize大小连接。

```
  /**
    * Fill pool up from current idle connections (as they are perceived at the point of execution) to minimumIdle connections.
    */
   private synchronized void fillPool()
   {
      final int connectionsToAdd = Math.min(config.getMaximumPoolSize() - getTotalConnections(), config.getMinimumIdle() - getIdleConnections())
                                   - addConnectionQueue.size();
      for (int i = 0; i < connectionsToAdd; i++) {
         addConnectionExecutor.submit((i < connectionsToAdd - 1) ? POOL_ENTRY_CREATOR : POST_FILL_POOL_ENTRY_CREATOR);
      }
   }
```

作者不推荐使用minimumIdle，该属性控制HikariCP尝试在池中维护的最小空闲连接数。如果空闲连接低于此值并且池中的总连接数少于maximumPoolSize，HikariCP将尽最大努力快速高效地添加其他连接。但是，为了获得最佳性能和响应尖峰需求，我们建议不要设置此值，而是允许HikariCP充当固定大小的连接池。 默认值：与maximumPoolSize相同

> **maximumPoolSize**
> This property controls the maximum size that the pool is allowed to reach, including both idle and in-use connections. Basically this value will determine the maximum number of actual connections to the database backend. A reasonable value for this is best determined by your execution environment. When the pool reaches this size, and no idle connections are available, calls to getConnection() will block for up to connectionTimeout milliseconds before timing out. Please read about pool sizing. Default: 10

此属性控制池允许达到的最大大小，包括空闲和正在使用的连接。基本上这个值将决定到数据库后端的最大实际连接数。对此的合理价值最好由您的执行环境决定。当池达到此大小并且没有可用的空闲连接时，对getConnection()的调用将connectionTimeout在超时前阻塞达几毫秒。 默认值：10

> **minimumIdle** 
> This property controls the minimum number of idle connections that HikariCP tries to maintain in the pool. If the idle connections dip below this value and total connections in the pool are less than maximumPoolSize, HikariCP will make a best effort to add additional connections quickly and efficiently. However, for maximum performance and responsiveness to spike demands, we recommend not setting this value and instead allowing HikariCP to act as a fixed size connection pool. Default: same as maximumPoolSize

该属性控制HikariCP尝试在池中维护的最小空闲连接数。如果空闲连接低于此值并且池中的总连接数少于maximumPoolSize，HikariCP将尽最大努力快速高效地添加其他连接。但是，为了获得最佳性能和响应尖峰需求，我们建议不要设置此值，而是允许HikariCP充当固定大小的连接池。 默认值：与maximumPoolSize相同

作者认为如果minimumIdle小于maximumPoolSize的话，在流量激增的时候需要额外的连接，此时在请求方法里头再去处理新建连接会造成性能损失，即会导致数据库一方面降低连接建立的速度，另一方面也会影响既有的连接事务的完成，间接影响了这些既有连接归还到连接池的速度。
作者认为minimumIdle与maximumPoolSize设置成一样，多余的空闲连接不会对整体的性能有什么严重影响。

作者的如上观点可以参见 https://www.postgresql.org/message-id/1395487594923-5797135.post@n5.nabble.com

> And I didn't see a pool of a few dozen
> connections actually impacting performance much when half of them are idle
> and half are executing transactions (ie. the idle ones don't impact the
> overall performance much).

全文如下：

> Speaking to David's point…
> Reaching the maxPoolSize from the minPoolSize means creating the connections at the crucial moment where the client application is in the desperate need of completing an important query/transaction which the primary responsibility since it cannot hold the data collected.
>
> This was one of the reasons I was proposing the fixed pool design. In my
> experience, even in pools that maintain a minimum number of idle
> connections, responding to spike demands is problematic. If you have a pool
> with say 30 max. connections, and a 10 minimum idle connection goal, a
> sudden spike demand for 20 connections means the pool can satisfy 10
> instantly but then is left to [try to] establish 10 connections before the
> application's connectionTimeout (read acquisition timeout from the pool) is
> reached. This in turn generates a spike demand on the database slowing down
> not only the connection establishments themselves but also slowing down the
> completion of transactions that might actually return connections to the
> pool.
>
> As I think Tom noted is a slidestack I read somewhere, there is a "knee" in
> the performance curve beyond which additional connections cause a drop in
> TPS. While users think it is a good idea to have 10 idle connections but a
> maxPoolSize of 100, the reality is, they can retire/reuse connections faster
> with a much smaller maxPoolSize. And I didn't see a pool of a few dozen
> connections actually impacting performance much when half of them are idle
> and half are executing transactions (ie. the idle ones don't impact the
> overall performance much).
>
> Finally, one of my contentions was, either your database server has
> resources or it doesn't. Either it has enough memory and processing power
> for N connections or it doesn't. If the pool is set below, near, or at that
> capacity what is the purpose of releasing connections in that case? Yes, it
> frees up memory, but that memory is not really available for other use given
> that at any instant the maximum capacity of the pool may be demanded.
> Instead releasing resources only to try to reallocate them during a demand
> peak seems counter-productive.
>
> -Brett

当然如果你不想使用作者强烈推荐的建议，minimumIdle也是可以调整的，以控制闲置时段的连接数量。

HikariCP的初始版本只支持固定大小的池。作者初衷是，HikariCP是专门为具有相当恒定负载的系统而设计的，并且在倾向连接池大小于保持其运行时允许达到的最大大小，所以作者认为没有必要将代码复杂化以支持动态调整大小。毕竟你的系统会闲置很久么？另外作者认为配置项越多，用户配置池的难度就越大。但是呢，确实有一些用户需要动态调整连接池大小，并且没有就不行，所以作者就增加了这个功能。但是原则上，作者并不希望缺乏动态的大小支持会剥夺用户享受HikariCP的可靠性和正确性的好处。

小结一下就是，minIdle来指定空闲连接的最小数量，maxPoolSize指定连接池连接最大值，默认初始化的时候，是初始化minIdle大小的连接，如果minIdle与maxPoolSize值相等那就是初始化时把连接池填满。idleTimeout用来指定空闲连接的时长，maxLifetime用来指定所有连接的时长。com.zaxxer.hikari.housekeeping.periodMs用来指定连接池空闲连接处理及连接池数补充的HouseKeeper任务的调度时间间隔。所有的连接在maxLifetime之后都得重连一次，保证连接池的活性。

## 2. How to set minimumIdle

用户的场景如下所示：

I have three nodes + one backup node of my application. And all of them i configured to use 20 connections in the pool. To maintain 4 nodes i need 20*4 = 60 connections. When all 4 nodes are enabled in production then only 5-6 connection needed (for node), but if some nodes are down for maintenance then count of required connection grows. But most of time all nodes are active and we have 35 idle connection. We use pg_pool which configured to share connections between clients, and this 35 connection can`t be shared to other clients (other apps) because they are stay in Hikari pool.

Only using minimumIdle can solve this problem? Is there any recommended value for this option?

还记得 [【追光者系列】Hikari连接池配多大合适？](http://mp.weixin.qq.com/s?__biz=MzUzNTY4NTYxMA==&mid=2247483731&idx=1&sn=b81013c6af5e6e62d5ac8d8a26e2b848&chksm=fa80f1d6cdf778c03aec5b9db0e539b5ad0efae471324a8735828762998b6703a8bb8b226ac4&scene=21#wechat_redirect) 第一篇提及的我们公司的默认配置

```
maximumPoolSize: 20
minimumIdle: 10
```

针对这个问题，作者是这么回复的：

Do you have "spike" demands in traffic? For example, a node normally needs 5-6 connections but sometimes needs 10-15 quickly?

If you don't have spike demands:

If you have 3 active nodes (and 1 backup), and in production each node normally needs 5-6 connections, possibly set maximumPoolSize to 20, minimumIdle to 2, and idleTimeout to something like 2 minutes (120000ms).

If you do have moderate spike demands:

Try maximumPoolSize at 20, minimumIdle at 5-10, and again idleTimeout of something like 2 minutes (120000ms).

用户现象进一步描述：

In our current configuration maximum connections in pg_pool is setted to 860 (we have ~15 applications). We have "spike" demands in traffic in rush hours. If we set idleTimeout (to 2 minutes) then connection count will grow on requests or it will fall to actual count after 2 minutes? Can we use "overselling"? Can sum of maximumPoolSize be bigger then max connections in pg_pool?
When client makes request a connection and all connections are busy then does hikari immediately increase pool size if he can? Is there any option that configures time delay before establishing new connection to database?s

这里作者解释了idleTimeout的用处，The only thing idleTimeout helps with is reducing the pool size after a higher demand load.

> **idleTimeout**
> This property controls the maximum amount of time that a connection is allowed to sit idle in the pool. This setting only applies when minimumIdle is defined to be less than maximumPoolSize. Idle connections will not be retired once the pool reaches minimumIdle connections. Whether a connection is retired as idle or not is subject to a maximum variation of +30 seconds, and average variation of +15 seconds. A connection will never be retired as idle before this timeout. A value of 0 means that idle connections are never removed from the pool. The minimum allowed value is 10000ms (10 seconds). Default: 600000 (10 minutes)

默认是600000毫秒，即10分钟。如果idleTimeout+1秒>maxLifetime 且 maxLifetime>0，则会被重置为0；如果idleTimeout!=0且小于10秒，则会被重置为10秒。如果idleTimeout=0则表示空闲的连接在连接池中永远不被移除。
只有当minimumIdle小于maximumPoolSize时，这个参数才生效，当空闲连接数超过minimumIdle，而且空闲时间超过idleTimeout，则会被移除。

hikari内置的HouseKeeper是一个定时任务，在HikariPool构造器里头初始化，默认的是初始化后100毫秒执行，之后每执行完一次之后隔HOUSEKEEPING_PERIOD_MS(30秒)时间执行。
这个定时任务的作用就是根据idleTimeout的值，移除掉空闲超时的连接。
首先检测时钟是否倒退，如果倒退了则立即对过期的连接进行标记evict；之后当idleTimeout>0且配置的minimumIdle<maximumPoolSize时才开始处理超时的空闲连接。
取出状态是STATE_NOT_IN_USE的连接数，如果大于minimumIdle，则遍历STATE_NOT_IN_USE的连接的连接，将空闲超时达到idleTimeout的连接从connectionBag移除掉，若移除成功则关闭该连接，然后toRemove--。
在空闲连接移除之后，再调用fillPool，尝试补充空间连接数到minimumIdle值。

而hikari的连接泄露是每次getConnection的时候单独触发一个延时任务来处理，而空闲连接的清除则是使用HouseKeeper定时任务来处理，其运行间隔由com.zaxxer.hikari.housekeeping.periodMs环境变量控制，默认为30秒。

minimumIdle试图确保minimumIdle池中至少有可用的连接。池“补充”每30秒左右发生一次。（源码上文有提到），如果在 “补充”运行的时刻所有连接都被消耗（0空闲连接），则补充将添加5个新连接。当5个活动连接关闭时，池将有10个空闲连接。该idleTimeout（或maxLifetime）将关闭连接，并且池最终会返回到5个空闲连接。
如果希望游泳池迅速收缩，请设置idleTimeout为30秒，并maxLifetime等待1分钟。

作者完整答复如下：

The only thing idleTimeout helps with is reducing the pool size after a higher demand load.

Imagine that you have a minimumIdle of 2, and a maximumPoolSize of 20. When the pool starts, and there are no client request, the pool will look like this:

```
Total: 2, Idle: 2, Active: 0
```

Now, if three requests come in concurrently:

- The 2 idle connections are immediately used
- A new connection is created to handle the third request
- And then 2 additional connections are created to satisfy a minimumIdle of 2 (but this is not instantaneous)

The pool would then (possibly) look like this:

```
Total: 5, Idle: 2, Active: 3
```

Immediately after the three requests are complete, the pool would like this:

```
Total: 5, Idle: 5, Active: 0
```

If idleTimeout is set to 2 minutes, assuming no activity, then after 2 minutes the pool would again look like the initial condition (Total: 2, Idle: 2, Active: 0).

Basically, minimumIdle tries to ensure that there are at least minimumIdle connections available in the pool. If minimumIdle is 5, the number of connections in an idle pool will be 5. "As soon as" a request comes in and consumes one of the connections, there is now only 4 idle connections, so the pool will try to add a new connection to bring the idle connection count back up to 5.

The good news is, this is not an instantaneous action. The pool "refill" occurs every 30 seconds or so. So, if there are 5 idle connections and a request comes in and consumes one of them, leaving 4 idle, if the request completes and the connection is returned before the "refill", the pool will again have 5 idle connections and will not grow.

The "bad news" is, if at the instant that the "refill" runs all connections are consumed (0 idle connections), then the refill will add 5 new connections. When the 5 active connections are closed, the pool will then have 10 idle connections. The idleTimeout (or maxLifetime) will close connections, and the pool will eventually return back to 5 idle connections.

If you want the pool to shrink quickly, set idleTimeout to 30 seconds, and maxLifetime to something like 1 minute.

Now, getting to "overselling". According to the pgpool documentation:

```
... pgpool-II also has a limit on the maximum number of connections, but extra connections will be queued instead of returning an error immediately.
```

This means you could configure the sum of the HikariCP maximumPoolSize to be higher than the pgpool maximum connection limit. With the understanding that HikariCP will still throw SQLExceptions to a client if getConnection() is called and cannot be satisfied within connectionTimeout. The connectionTimeout applied to getConnection() is decoupled from the creation of new connections, which occurs asynchronously, so even if pgpool connection attempts were timing out the error is not necessarily passed through to HikariCP clients (if Connections are being returned to the pool by other threads within the connectionTimeout period).

Does that make sense?

最终该用户的连接池参数调整为set maximumPoolSize to 20, minimumIdle to 5, and idleTimeout to 2 minutes.



## 参考

[【追光者系列】Hikari连接池大小多大合适？（第二弹）](https://mp.weixin.qq.com/s/IgumHSMFvR4TxcuZn01L6w)
