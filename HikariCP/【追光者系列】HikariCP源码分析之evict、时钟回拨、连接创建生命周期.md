## 1. 概念

evict定义在com.zaxxer.hikari.pool.PoolEntry中，evict的汉语意思是驱逐、逐出，用来标记连接池中的连接不可用。

```java
private volatile boolean evict;
boolean isMarkedEvicted()
   {
      return evict;
   }
   void markEvicted()
   {
      this.evict = true;
   }
```

## 2. getConnection

在每次getConnection的时候，borrow连接（PoolEntry）的时候，如果是标记evict的，则会关闭连接，更新timeout的值，重新循环继续获取连接

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
       do {
          PoolEntry poolEntry = connectionBag.borrow(timeout, MILLISECONDS);
          if (poolEntry == null) {
             break; // We timed out... break and throw exception
          }
          final long now = currentTime();
          if (poolEntry.isMarkedEvicted() || (elapsedMillis(poolEntry.lastAccessed, now) > ALIVE_BYPASS_WINDOW_MS && !isConnectionAlive(poolEntry.connection))) {
             closeConnection(poolEntry, poolEntry.isMarkedEvicted() ? EVICTED_CONNECTION_MESSAGE : DEAD_CONNECTION_MESSAGE);
             timeout = hardTimeout - elapsedMillis(startTime);
          }
          else {
             metricsTracker.recordBorrowStats(poolEntry, startTime);
             return poolEntry.createProxyConnection(leakTaskFactory.schedule(poolEntry), now);
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

如下我们聚焦一下源码，hardTimeout默认值是30000，这个值实际上就是connectionTimeout，构造器默认值是SECONDS.toMillis(30) = 30000，默认配置validate之后的值是30000，validate重置以后是如果小于250毫秒，则被重置回30秒。

> **connectionTimeout** 
> This property controls the maximum number of milliseconds that a client (that's you) will wait for a connection from the pool. If this time is exceeded without a connection becoming available, a SQLException will be thrown. Lowest acceptable connection timeout is 250 ms. Default: 30000 (30 seconds)

```java
if (poolEntry.isMarkedEvicted() || (elapsedMillis(poolEntry.lastAccessed, now) > ALIVE_BYPASS_WINDOW_MS && !isConnectionAlive(poolEntry.connection))) {
   closeConnection(poolEntry, poolEntry.isMarkedEvicted() ? EVICTED_CONNECTION_MESSAGE : DEAD_CONNECTION_MESSAGE);
   timeout = hardTimeout - elapsedMillis(startTime);
}
```

关闭连接这块的源码如下，从注释可以看到（阅读hikari源码强烈建议看注释），这是永久关闭真实（底层）连接（吃掉任何异常）：

```java
 private static final String EVICTED_CONNECTION_MESSAGE = "(connection was evicted)";
 private static final String DEAD_CONNECTION_MESSAGE = "(connection is dead)";
 /**
  * Permanently close the real (underlying) connection (eat any exception).
  *
  * @param poolEntry poolEntry having the connection to close
  * @param closureReason reason to close
  */
 void closeConnection(final PoolEntry poolEntry, final String closureReason)
 {
    if (connectionBag.remove(poolEntry)) {
       final Connection connection = poolEntry.close();
       closeConnectionExecutor.execute(() -> {
          quietlyCloseConnection(connection, closureReason);
          if (poolState == POOL_NORMAL) {
             fillPool();
          }
       });
    }
 }
```

吃掉体现在quietlyCloseConnection，这是吃掉Throwable的

```java
// ***********************************************************************
//                           JDBC methods
// ***********************************************************************
void quietlyCloseConnection(final Connection connection, final String closureReason)
{
  if (connection != null) {
     try {
        LOGGER.debug("{} - Closing connection {}: {}", poolName, connection, closureReason);
        try {
           setNetworkTimeout(connection, SECONDS.toMillis(15));
        }
        finally {
           connection.close(); // continue with the close even if setNetworkTimeout() throws
        }
     }
     catch (Throwable e) {
        LOGGER.debug("{} - Closing connection {} failed", poolName, connection, e);
     }
  }
}
```

## 3. createPoolEntry

这段代码强烈建议看一下注释，maxLifetime默认是1800000=30分钟，就是让每个连接的最大存活时间错开一点，防止同时过期，加一点点随机因素，防止一件事情大量同时发生（C大语录）。

```java
// ***********************************************************************
 //                           Private methods
 // ***********************************************************************
 /**
  * Creating new poolEntry.  If maxLifetime is configured, create a future End-of-life task with 2.5% variance from
  * the maxLifetime time to ensure there is no massive die-off of Connections in the pool.
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
       if (poolState == POOL_NORMAL) { // we check POOL_NORMAL to avoid a flood of messages if shutdown() is running concurrently
          LOGGER.debug("{} - Cannot acquire connection from data source", poolName, (e instanceof ConnectionSetupException ? e.getCause() : e));
       }
       return null;
    }
 }
```

如果maxLifetime大于10000就是大于10秒钟，就走这个策略，用maxLifetime的2.5%的时间和0之间的随机数来随机设定一个variance，在maxLifetime - variance之后触发evict。

在创建poolEntry的时候，注册一个延时任务，在连接存活将要到达maxLifetime之前触发evit，用来防止出现大面积的connection因maxLifetime同一时刻失效。

标记为evict只是表示连接池中的该连接不可用，但还在连接池当中，还会被borrow出来，只是getConnection的时候判断了，如果是isMarkedEvicted，则会从连接池中移除该连接，然后close掉。

## 4. evict Related

### 4.1 evictConnection

可以主动调用evictConnection，这里也是判断是不是用户自己调用的或者从connectionBag中标记不可borrow成功，则关闭连接

```java
/**
  * Evict a Connection from the pool.
  *
  * @param connection the Connection to evict (actually a {@link ProxyConnection})
  */
 public void evictConnection(Connection connection)
 {
    ProxyConnection proxyConnection = (ProxyConnection) connection;
    proxyConnection.cancelLeakTask();
    try {
       softEvictConnection(proxyConnection.getPoolEntry(), "(connection evicted by user)", !connection.isClosed() /* owner */);
    }
    catch (SQLException e) {
       // unreachable in HikariCP, but we're still forced to catch it
    }
 }
```

### 4.2 softEvictConnection

```java
  /**
    * "Soft" evict a Connection (/PoolEntry) from the pool.  If this method is being called by the user directly
    * through {@link com.zaxxer.hikari.HikariDataSource#evictConnection(Connection)} then {@code owner} is {@code true}.
    *
    * If the caller is the owner, or if the Connection is idle (i.e. can be "reserved" in the {@link ConcurrentBag}),
    * then we can close the connection immediately.  Otherwise, we leave it "marked" for eviction so that it is evicted
    * the next time someone tries to acquire it from the pool.
    *
    * @param poolEntry the PoolEntry (/Connection) to "soft" evict from the pool
    * @param reason the reason that the connection is being evicted
    * @param owner true if the caller is the owner of the connection, false otherwise
    * @return true if the connection was evicted (closed), false if it was merely marked for eviction
    */
   private boolean softEvictConnection(final PoolEntry poolEntry, final String reason, final boolean owner)
   {
      poolEntry.markEvicted();
      if (owner || connectionBag.reserve(poolEntry)) {
         closeConnection(poolEntry, reason);
         return true;
      }
      return false;
   }
```

com.zaxxer.hikari.util.ConcurrentBag

```java
 /**
  * The method is used to make an item in the bag "unavailable" for
  * borrowing.  It is primarily used when wanting to operate on items
  * returned by the <code>values(int)</code> method.  Items that are
  * reserved can be removed from the bag via <code>remove(T)</code>
  * without the need to unreserve them.  Items that are not removed
  * from the bag can be make available for borrowing again by calling
  * the <code>unreserve(T)</code> method.
  *
  * @param bagEntry the item to reserve
  * @return true if the item was able to be reserved, false otherwise
  */
 public boolean reserve(final T bagEntry)
 {
    return bagEntry.compareAndSet(STATE_NOT_IN_USE, STATE_RESERVED);
 }
```

### 4.3 softEvictConnections

HikariPool中还提供了HikariPoolMXBean的实现，实际上是调用softEvictConnection，owner指定false（ not owner ）

```java
public void softEvictConnections()
{
  connectionBag.values().forEach(poolEntry -> softEvictConnection(poolEntry, "(connection evicted)", false /* not owner */));
}
```

Mbean的softEvictConnections方法真正执行的是com.zaxxer.hikari.pool.HikariPool中softEvictConnections方法，这是一种“软”驱逐池中连接的方法，如果调用方是owner身份，或者连接处于空闲状态，可以立即关闭连接。否则，我们将其“标记”为驱逐，以便下次有人试图从池中获取它时将其逐出。

```java
public void softEvictConnections()
 {
    connectionBag.values().forEach(poolEntry -> softEvictConnection(poolEntry, "(connection evicted)", false /* not owner */));
 }
/**
  * "Soft" evict a Connection (/PoolEntry) from the pool.  If this method is being called by the user directly
  * through {@link com.zaxxer.hikari.HikariDataSource#evictConnection(Connection)} then {@code owner} is {@code true}.
  *
  * If the caller is the owner, or if the Connection is idle (i.e. can be "reserved" in the {@link ConcurrentBag}),
  * then we can close the connection immediately.  Otherwise, we leave it "marked" for eviction so that it is evicted
  * the next time someone tries to acquire it from the pool.
  *
  * @param poolEntry the PoolEntry (/Connection) to "soft" evict from the pool
  * @param reason the reason that the connection is being evicted
  * @param owner true if the caller is the owner of the connection, false otherwise
  * @return true if the connection was evicted (closed), false if it was merely marked for eviction
  */
 private boolean softEvictConnection(final PoolEntry poolEntry, final String reason, final boolean owner)
 {
    poolEntry.markEvicted();
    if (owner || connectionBag.reserve(poolEntry)) {
       closeConnection(poolEntry, reason);
       return true;
    }
    return false;
 }
```

执行此方法时我们的owner默认传false(not owner)，调用com.zaxxer.hikari.util.ConcurrentBag的reserve对方进行保留。

```java
/**
  * The method is used to make an item in the bag "unavailable" for
  * borrowing.  It is primarily used when wanting to operate on items
  * returned by the <code>values(int)</code> method.  Items that are
  * reserved can be removed from the bag via <code>remove(T)</code>
  * without the need to unreserve them.  Items that are not removed
  * from the bag can be make available for borrowing again by calling
  * the <code>unreserve(T)</code> method.
  *
  * @param bagEntry the item to reserve
  * @return true if the item was able to be reserved, false otherwise
  */
 public boolean reserve(final T bagEntry)
 {
    return bagEntry.compareAndSet(STATE_NOT_IN_USE, STATE_RESERVED);
 }
```

除了 HikariPoolMXBean的调用，softEvictConnections在housekeeper中也有使用

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

聚焦一下,这段代码也是检测时钟回拨，如果时钟在规定范围外回拨了，就驱除连接，并重置时间。

```java
// Detect retrograde time, allowing +128ms as per NTP spec.
          if (plusMillis(now, 128) < plusMillis(previous, HOUSEKEEPING_PERIOD_MS)) {
             LOGGER.warn("{} - Retrograde clock change detected (housekeeper delta={}), soft-evicting connections from pool.",
                         poolName, elapsedDisplayString(previous, now));
             previous = now;
             softEvictConnections();
             return;
          }
/**
  * Return the specified opaque time-stamp plus the specified number of milliseconds.
  *
  * @param time an opaque time-stamp
  * @param millis milliseconds to add
  * @return a new opaque time-stamp
  */
 static long plusMillis(long time, long millis) {
    return CLOCK.plusMillis0(time, millis);
 }
```

说到时钟回拨，是不是想起了snowflake里的时钟回拨的处理？让我们一起温习一下！

```java
/**
 * 自生成Id生成器.
 * 
 * <p>
 * 长度为64bit,从高位到低位依次为
 * </p>
 * 
 * <pre>
 * 1bit   符号位 
 * 41bits 时间偏移量从2016年11月1日零点到现在的毫秒数
 * 10bits 工作进程Id
 * 12bits 同一个毫秒内的自增量
 * </pre>
 * 
 * <p>
 * 工作进程Id获取优先级: 系统变量{@code sjdbc.self.id.generator.worker.id} 大于环境变量{@code SJDBC_SELF_ID_GENERATOR_WORKER_ID}
 * ,另外可以调用@{@code CommonSelfIdGenerator.setWorkerId}进行设置
 * </p>
 * 
 * @author gaohongtao
 */
@Getter
@Slf4j
public class CommonSelfIdGenerator implements IdGenerator {
    public static final long SJDBC_EPOCH;//时间偏移量，从2016年11月1日零点开始
    private static final long SEQUENCE_BITS = 12L;//自增量占用比特
    private static final long WORKER_ID_BITS = 10L;//工作进程ID比特
    private static final long SEQUENCE_MASK = (1 << SEQUENCE_BITS) - 1;//自增量掩码（最大值）
    private static final long WORKER_ID_LEFT_SHIFT_BITS = SEQUENCE_BITS;//工作进程ID左移比特数（位数）
    private static final long TIMESTAMP_LEFT_SHIFT_BITS = WORKER_ID_LEFT_SHIFT_BITS + WORKER_ID_BITS;//时间戳左移比特数（位数）
    private static final long WORKER_ID_MAX_VALUE = 1L << WORKER_ID_BITS;//工作进程ID最大值
    @Setter
    private static AbstractClock clock = AbstractClock.systemClock();
    @Getter
    private static long workerId;//工作进程ID
    static {
        Calendar calendar = Calendar.getInstance();
        calendar.set(2016, Calendar.NOVEMBER, 1);
        calendar.set(Calendar.HOUR_OF_DAY, 0);
        calendar.set(Calendar.MINUTE, 0);
        calendar.set(Calendar.SECOND, 0);
        calendar.set(Calendar.MILLISECOND, 0);
        SJDBC_EPOCH = calendar.getTimeInMillis();
        initWorkerId();
    }
    private long sequence;//最后自增量
    private long lastTime;//最后生成编号时间戳，单位：毫秒
    static void initWorkerId() {
        String workerId = System.getProperty("sjdbc.self.id.generator.worker.id");
        if (!Strings.isNullOrEmpty(workerId)) {
            setWorkerId(Long.valueOf(workerId));
            return;
        }
        workerId = System.getenv("SJDBC_SELF_ID_GENERATOR_WORKER_ID");
        if (Strings.isNullOrEmpty(workerId)) {
            return;
        }
        setWorkerId(Long.valueOf(workerId));
    }
    /**
     * 设置工作进程Id.
     * 
     * @param workerId 工作进程Id
     */
    public static void setWorkerId(final Long workerId) {
        Preconditions.checkArgument(workerId >= 0L && workerId < WORKER_ID_MAX_VALUE);
        CommonSelfIdGenerator.workerId = workerId;
    }
    /**
     * 生成Id.
     * 
     * @return 返回@{@link Long}类型的Id
     */
    @Override
    public synchronized Number generateId() {
    //保证当前时间大于最后时间。时间回退会导致产生重复id
        long time = clock.millis();
        Preconditions.checkState(lastTime <= time, "Clock is moving backwards, last time is %d milliseconds, current time is %d milliseconds", lastTime, time);
        // 获取序列号
        if (lastTime == time) {
            if (0L == (sequence = ++sequence & SEQUENCE_MASK)) {
                time = waitUntilNextTime(time);
            }
        } else {
            sequence = 0;
        }
        // 设置最后时间戳
        lastTime = time;
        if (log.isDebugEnabled()) {
            log.debug("{}-{}-{}", new SimpleDateFormat("yyyy-MM-dd HH:mm:ss.SSS").format(new Date(lastTime)), workerId, sequence);
        }
        // 生成编号
        return ((time - SJDBC_EPOCH) << TIMESTAMP_LEFT_SHIFT_BITS) | (workerId << WORKER_ID_LEFT_SHIFT_BITS) | sequence;
    }
    //不停获得时间，直到大于最后时间
    private long waitUntilNextTime(final long lastTime) {
        long time = clock.millis();
        while (time <= lastTime) {
            time = clock.millis();
        }
        return time;
    }
}
```

通过这段代码可以看到当当的时钟回拨在单机上是做了处理的了，不但会抛出Clock is moving backwards balabalabala的IllegalStateException，而且也做了waitUntilNextTime一直等待的处理。

除了housekeeper，在shutdown中也做了处理。

```java
/**
  * Shutdown the pool, closing all idle connections and aborting or closing
  * active connections.
  *
  * @throws InterruptedException thrown if the thread is interrupted during shutdown
  */
 public synchronized void shutdown() throws InterruptedException
 {
    try {
       poolState = POOL_SHUTDOWN;
       if (addConnectionExecutor == null) { // pool never started
          return;
       }
       logPoolState("Before shutdown ");
       if (houseKeeperTask != null) {
          houseKeeperTask.cancel(false);
          houseKeeperTask = null;
       }
       softEvictConnections();
       addConnectionExecutor.shutdown();
       addConnectionExecutor.awaitTermination(getLoginTimeout(), SECONDS);
       destroyHouseKeepingExecutorService();
       connectionBag.close();
       final ExecutorService assassinExecutor = createThreadPoolExecutor(config.getMaximumPoolSize(), poolName + " connection assassinator",
                                                                         config.getThreadFactory(), new ThreadPoolExecutor.CallerRunsPolicy());
       try {
          final long start = currentTime();
          do {
             abortActiveConnections(assassinExecutor);
             softEvictConnections();
          } while (getTotalConnections() > 0 && elapsedMillis(start) < SECONDS.toMillis(10));
       }
       finally {
          assassinExecutor.shutdown();
          assassinExecutor.awaitTermination(10L, SECONDS);
       }
       shutdownNetworkTimeoutExecutor();
       closeConnectionExecutor.shutdown();
       closeConnectionExecutor.awaitTermination(10L, SECONDS);
    }
    finally {
       logPoolState("After shutdown ");
       unregisterMBeans();
       metricsTracker.close();
    }
 }
```

## 5. Hikari 物理连接取用生命周期

上面提到了很多概念，比如HikariDataSource、HikariPool、ConcurrentBag、ProxyFactory、PoolEntry等等，那么这里的关系是什么呢？

这里推荐一下这篇文章 http://www.cnblogs.com/taisenki/p/7717912.html ，我引用一下部分内容：

HikariCP中的连接取用流程如下：

![3](http://blog-1259650185.cosbj.myqcloud.com/img/202205/15/1652587870.png)

HikariPool负责对资源连接进行管理，而ConcurrentBag则是作为物理连接的共享资源站，PoolEntry则是对物理连接的一对一封装。

PoolEntry通过connectionBag的borrow方法从bag中取出，，之后通过PoolEntry.createProxyConnection调用工厂类生成HikariProxyConnection返回。











## 参考

[【追光者系列】HikariCP源码分析之evict、时钟回拨、连接创建生命周期](https://mp.weixin.qq.com/s/PjJVYkMY67i7T-93tPpK7g)
