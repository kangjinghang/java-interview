![4](http://blog-1259650185.cosbj.myqcloud.com/img/202205/13/1652452840.jpeg)

今晚给大家讲一个故事，如上图所示，Hikari作者brettwooldridge先生非常无奈的在issue里回复了一句“阿门，兄弟”，到底发生了什么有趣的故事呢？这是一篇风格不同于以往的文章，就让我来带大家从源码validationTimeout分析角度一起揭开这个故事的面纱吧～

## 1. 概念

此属性控制连接测试活动的最长时间。这个值必须小于connectionTimeout。最低可接受的验证超时时间为250 ms。 默认值：5000。

> **validationTimeout** 
> This property controls the maximum amount of time that a connection will be tested for aliveness. This value must be less than the connectionTimeout. Lowest acceptable validation timeout is 250 ms. Default: 5000

## 2. 源码解析

我们首先来看一下validationTimeout用在了哪里的纲要图。

### 2.1 Write

我们可以看到在两处看到validationTimeout的写入，一处是PoolBase构造函数，另一处是HouseKeeper线程。

#### 2.1.1 PoolBase

在com.zaxxer.hikari.pool.PoolBase中的构造函数声明了validationTimeout的初始值，而该值真正来自于com.zaxxer.hikari.HikariConfig的Default constructor，默认值为

```java
private static final long VALIDATION_TIMEOUT = SECONDS.toMillis(5);
```

但是在HikariConfig的set方法中又做了处理

```java
/** {@inheritDoc} */
@Override
public void setValidationTimeout(long validationTimeoutMs)
{
   if (validationTimeoutMs < SOFT_TIMEOUT_FLOOR) {
      throw new IllegalArgumentException("validationTimeout cannot be less than " + SOFT_TIMEOUT_FLOOR + "ms");
   }

   this.validationTimeout = validationTimeoutMs;
}
```

这就是概念一栏所说的**如果小于250毫秒，则会被重置回5秒**的原因。

#### 2.1.2 HouseKeeper

我们再来看一下com.zaxxer.hikari.pool.HikariPool这个代码，该线程尝试在池中维护的最小空闲连接数，并不断刷新的通过MBean调整的connectionTimeout和validationTimeout等值。

HikariCP有除了这个HouseKeeper线程之外，还有新建连接和关闭连接的线程。

```java
private final class HouseKeeper implements Runnable
{
   private volatile long previous = plusMillis(currentTime(), -housekeepingPeriodMs);
   @SuppressWarnings("AtomicFieldUpdaterNotStaticFinal")
   private final AtomicReferenceFieldUpdater<PoolBase, String> catalogUpdater = AtomicReferenceFieldUpdater.newUpdater(PoolBase.class, String.class, "catalog");

   @Override
   public void run()
   {
      try {
         // refresh values in case they changed via MBean
         connectionTimeout = config.getConnectionTimeout();
         validationTimeout = config.getValidationTimeout();
         leakTaskFactory.updateLeakDetectionThreshold(config.getLeakDetectionThreshold());

         if (config.getCatalog() != null && !config.getCatalog().equals(catalog)) {
            catalogUpdater.set(HikariPool.this, config.getCatalog());
         }

         final var idleTimeout = config.getIdleTimeout();
         final var now = currentTime();

         // Detect retrograde time, allowing +128ms as per NTP spec.
         if (plusMillis(now, 128) < plusMillis(previous, housekeepingPeriodMs)) {
            logger.warn("{} - Retrograde clock change detected (housekeeper delta={}), soft-evicting connections from pool.",
                        poolName, elapsedDisplayString(previous, now));
            previous = now;
            softEvictConnections();
            return;
         }
         else if (now > plusMillis(previous, (3 * housekeepingPeriodMs) / 2)) {
            // No point evicting for forward clock motion, this merely accelerates connection retirement anyway
            logger.warn("{} - Thread starvation or clock leap detected (housekeeper delta={}).", poolName, elapsedDisplayString(previous, now));
         }

         previous = now;

         var afterPrefix = "Pool ";
         if (idleTimeout > 0L && config.getMinimumIdle() < config.getMaximumPoolSize()) {
            logPoolState("Before cleanup ");
            afterPrefix = "After cleanup  ";

            final var notInUse = connectionBag.values(STATE_NOT_IN_USE);
            var toRemove = notInUse.size() - config.getMinimumIdle();
            for (PoolEntry entry : notInUse) {
               if (toRemove > 0 && elapsedMillis(entry.lastAccessed, now) > idleTimeout && connectionBag.reserve(entry)) {
                  closeConnection(entry, "(connection has passed idleTimeout)");
                  toRemove--;
               }
            }
         }

         logPoolState(afterPrefix);

         fillPool(true); // Try to maintain minimum connections
      }
      catch (Exception e) {
         logger.error("Unexpected exception in housekeeping task", e);
      }
   }
}
```

### 2.2 Read

#### 2.2.1 getConnection

在com.zaxxer.hikari.pool.HikariPool的核心方法getConnection中用到了validationTimeout，我们看一下源码，**borrow**到poolEntry之后，如果不是isMarkedEvicted，则会调用isConnectionAlive来判断连接的有效性，再强调一下**hikari是在borrow连接的时候校验连接的有效性**：

```java
/**
  * Get a connection from the pool, or timeout after the specified number of milliseconds.
  *
  * @param hardTimeout the maximum time to wait for a connection from the pool
  * @return a java.sql.Connection instance
  * @throws SQLException thrown if a timeout occurs trying to obtain a connection
  */
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

我们具体来看一下isConnectionAlive的实现：

```java
 boolean isConnectionAlive(final Connection connection)
 {
    try {
       try {
          setNetworkTimeout(connection, validationTimeout);
          final int validationSeconds = (int) Math.max(1000L, validationTimeout) / 1000;
          if (isUseJdbc4Validation) {
             return connection.isValid(validationSeconds);
          }
          try (Statement statement = connection.createStatement()) {
             if (isNetworkTimeoutSupported != TRUE) {
                setQueryTimeout(statement, validationSeconds);
             }
             statement.execute(config.getConnectionTestQuery());
          }
       }
       finally {
          setNetworkTimeout(connection, networkTimeout);
          if (isIsolateInternalQueries && !isAutoCommit) {
             connection.rollback();
          }
       }
       return true;
    }
    catch (Exception e) {
       lastConnectionFailure.set(e);
       LOGGER.warn("{} - Failed to validate connection {} ({})", poolName, connection, e.getMessage());
       return false;
    }
 }
 /**
  * Set the network timeout, if <code>isUseNetworkTimeout</code> is <code>true</code> and the
  * driver supports it.
  *
  * @param connection the connection to set the network timeout on
  * @param timeoutMs the number of milliseconds before timeout
  * @throws SQLException throw if the connection.setNetworkTimeout() call throws
  */
 private void setNetworkTimeout(final Connection connection, final long timeoutMs) throws SQLException
 {
    if (isNetworkTimeoutSupported == TRUE) {
       connection.setNetworkTimeout(netTimeoutExecutor, (int) timeoutMs);
    }
 }

/**
  * Set the query timeout, if it is supported by the driver.
  *
  * @param statement a statement to set the query timeout on
  * @param timeoutSec the number of seconds before timeout
  */
 private void setQueryTimeout(final Statement statement, final int timeoutSec)
 {
    if (isQueryTimeoutSupported != FALSE) {
       try {
          statement.setQueryTimeout(timeoutSec);
          isQueryTimeoutSupported = TRUE;
       }
       catch (Throwable e) {
          if (isQueryTimeoutSupported == UNINITIALIZED) {
             isQueryTimeoutSupported = FALSE;
             LOGGER.info("{} - Failed to set query timeout for statement. ({})", poolName, e.getMessage());
          }
       }
    }
 }
```

从如下代码可以看到，validationTimeout的默认值是5000毫秒，所以默认情况下validationSeconds的值应该在1-5毫秒之间，又由于validationTimeout的值必须小于connectionTimeout（默认值30000毫秒，如果小于250毫秒，则被重置回30秒），所以默认情况下，调整validationTimeout却不调整connectionTimeout情况下，validationSeconds的默认峰值应该是30毫秒。

```java
final int validationSeconds = (int) Math.max(1000L, validationTimeout) / 1000;
```

如果是jdbc4的话，如果使用isUseJdbc4Validation(就是config.getConnectionTestQuery() == null的时候)

```java
this.isUseJdbc4Validation = config.getConnectionTestQuery() == null;
```

用connection.isValid(validationSeconds)来验证连接的有效性，否则的话则用connectionTestQuery查询语句来查询验证。

> 这里说一下java.sql.Connection的isValid()和isClosed()的区别：
>
> isValid：如果连接尚未关闭并且仍然有效，则返回 true。驱动程序将提交一个关于该连接的查询，或者使用其他某种能确切验证在调用此方法时连接是否仍然有效的机制。由驱动程序提交的用来验证该连接的查询将在当前事务的上下文中执行。
> 参数：timeout - 等待用来验证连接是否完成的数据库操作的时间，以秒为单位。如果在操作完成之前超时期满，则此方法返回 false。0 值表示不对数据库操作应用超时值。
> 返回：如果连接有效，则返回 true，否则返回 false 
>
> isClosed：查询此 Connection 对象是否已经被关闭。如果在连接上调用了 close 方法或者发生某些严重的错误，则连接被关闭。只有在调用了Connection.close 方法之后被调用时，此方法才保证返回true。通常不能调用此方法确定到数据库的连接是有效的还是无效的。通过捕获在试图进行某一操作时可能抛出的异常，典型的客户端可以确定某一连接是无效的。
> 返回：如果此 Connection 对象是关闭的，则返回 true；如果它仍然处于打开状态，则返回 false。

#### 2.2.2 newConnection

在com.zaxxer.hikari.pool.PoolBase的newConnection#setupConnection() 中，对于validationTimeout超时时间也做了getAndSetNetworkTimeout等的处理。

## 3. Hikari 2.7.5的故事

从validationTimeout我们刚才讲到了有一个HouseKeeper线程干着不断刷新的通过MBean调整的connectionTimeout和validationTimeout等值的事情。这就是2.7.4到2.7.5版本的一个很重要的改变，为什么这么说？

### 3.1 两个关键的Mbean

首先Hikari有两个Mbean，分别是HikariPoolMXBean和HikariConfigMXBean，我们看一下代码，这两个代码的功能不言而喻：

```java
/**
 * The javax.management MBean for a Hikari pool instance.
 *
 * @author Brett Wooldridge
 */
public interface HikariPoolMXBean 
{
   int getIdleConnections();
   int getActiveConnections();
   int getTotalConnections();
   int getThreadsAwaitingConnection();
   void softEvictConnections();
   void suspendPool();
   void resumePool();
}
```

```java
public interface HikariConfigMXBean
{
   long getConnectionTimeout();

   void setConnectionTimeout(long connectionTimeoutMs);

   long getValidationTimeout();

   void setValidationTimeout(long validationTimeoutMs);

   long getIdleTimeout();

   void setIdleTimeout(long idleTimeoutMs);

   long getLeakDetectionThreshold();

   void setLeakDetectionThreshold(long leakDetectionThresholdMs);

   long getMaxLifetime();

   void setMaxLifetime(long maxLifetimeMs);

   int getMinimumIdle();

   void setMinimumIdle(int minIdle);

   int getMaximumPoolSize();

   void setMaximumPoolSize(int maxPoolSize);

   void setPassword(String password);

   void setUsername(String username);

   String getPoolName();

   String getCatalog();

   void setCatalog(String catalog);
}
```

### 3.2 2.7.5迎来了不可变设计

作者在18年1月5日做了一次代码提交：

<img src="http://blog-1259650185.cosbj.myqcloud.com/img/202205/13/1652457387.jpeg" alt="5" style="zoom:50%;" />

导致大多数方法都不允许动态更新了：

<img src="http://blog-1259650185.cosbj.myqcloud.com/img/202205/13/1652457532.jpeg" alt="6" style="zoom: 50%;" />

可以这么认为，2.7.4是支持的，2.7.5作者搞了一下就变成了不可变设计，sb2.0默认支持2.7.6。

这会带来什么影响呢？如果你想运行时使用代码动态更新Hikari的Config除非命中可修改参数，否则直接给你抛异常了；当然，你更新代码写得不好也可能命中作者的这段抛异常逻辑。作者非常推荐使用Mbean去修改，不过你自己重新创建一个数据源使用CAP（Compare And Swap）也是可行的，所以我就只能如下改了一下，顺应了一下SB 2.0的时代：

<img src="http://blog-1259650185.cosbj.myqcloud.com/img/202205/13/1652457571.jpeg" alt="7" style="zoom: 67%;" />

如上图，左侧的字段都是Hikari在2.7.5以前亲测过可以动态更改的，不过jdbcurl不在这个范围之内，所以这就是为什么作者要做这么一个比较安全的不可变模式的导火索。

### 3.3 且看大神论道

某用户在1.1日给作者提了一个issue，就是jdbcurl无法动态修改的事情：
https://github.com/brettwooldridge/HikariCP/issues/1053

<img src="http://blog-1259650185.cosbj.myqcloud.com/img/202205/14/1652457761.jpeg" alt="8" style="zoom: 67%;" />

作者予以了回复，意思就是运行时可以更改的唯一池配置是通过HikariConfigMXBean，并增强的抛出一个IllegalStateException异常。两人达成一致，Makes sense，觉得非常Perfect，另外会完善一下JavaDoc。So,Sealed configuration makes it much harder to configure Hikari。

<img src="http://blog-1259650185.cosbj.myqcloud.com/img/202205/14/1652457834.jpeg" alt="9" style="zoom:67%;" />

然后俩人又开了一个ISSUE：
https://github.com/brettwooldridge/HikariCP/issues/231
但是在这里，俩人产生了一些设计相关的分歧，很有意思。

<img src="http://blog-1259650185.cosbj.myqcloud.com/img/202205/14/1652457886.jpeg" alt="10" style="zoom:67%;" />

<img src="http://blog-1259650185.cosbj.myqcloud.com/img/202205/14/1652457903.jpeg" alt="11" style="zoom:67%;" />

作者表明他的一些改变增加代码的复杂性，而不是增加它的价值，而作者对于Hikari的初衷是追求极致性能、追求极简设计。

<img src="http://blog-1259650185.cosbj.myqcloud.com/img/202205/14/1652457941.jpeg" alt="12" style="zoom:67%;" />

该用户建议作者提供add the ability to copy the configuration of one HikariDataSource into another的能力。作者予以了反驳：

<img src="http://blog-1259650185.cosbj.myqcloud.com/img/202205/14/1652457979.jpeg" alt="13" style="zoom:67%;" />

作者还是一如既往得追求他大道至简的思想以及两个Mbean的主张。

该用户继续着他的观点，

<img src="http://blog-1259650185.cosbj.myqcloud.com/img/202205/14/1652458008.jpeg" alt="14" style="zoom:67%;" />

<img src="http://blog-1259650185.cosbj.myqcloud.com/img/202205/14/1652458037.jpeg" alt="15" style="zoom:67%;" />

可是作者貌似还是很坚持他的Hikari观点，作为吃瓜群众，看着大神论道，还是非常有意思的。

最后说说我的观点吧，我觉得作者对于Hikari，既然取名为光，就是追求极致，那些过度设计什么的他都会尽量摈弃的，我使用Hikari以及阅读源码的过程中也能感觉到，所以我觉得作者不会继续做这个需求，后续请关注我的真情实感的从实战及源码分析角度的体会《为什么HikariCP这么快》（不同于网上的其他文章）。

接下来说，我作为Hikari的使用者，我也是有能力完成Hikari的wrapper工作，我也可以去写外层的HouseKeeper，所以我觉得这并不是什么太大的问题，这次2.7.5的更新，很鸡肋的一个功能，但是却让我，作为一名追光者，走近了作者一点，走近了Hikari一点 ：）



## 参考

[【追光者系列】HikariCP源码分析之从validationTimeout来讲讲Hikari 2.7.5版本的那些故事](https://mp.weixin.qq.com/s/zZCnM-IFwAwc6lQ_NvL-1A)
