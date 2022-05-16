## 1. 概念

此属性控制在记录消息之前连接可能离开池的时间量，单位毫秒，默认为0，表明可能存在连接泄漏。
如果大于0且不是单元测试，则进一步判断：(leakDetectionThreshold < SECONDS.toMillis(2) or (leakDetectionThreshold > maxLifetime && maxLifetime > 0)，会被重置为0。即如果要生效则必须>0，而且不能小于2秒，而且当maxLifetime > 0时不能大于maxLifetime（默认值1800000毫秒=30分钟）。

> **leakDetectionThreshold** 
> This property controls the amount of time that a connection can be out of the pool before a message is logged indicating a possible connection leak. A value of 0 means leak detection is disabled. Lowest acceptable value for enabling leak detection is 2000 (2 seconds). Default: 0

## 2. 源码解析

我们首先来看一下leakDetectionThreshold用在了哪里的纲要图：

### 2.1 Write

还记得上一篇文章[【追光者系列】HikariCP源码分析之从validationTimeout来讲讲Hikari 2.7.5版本的那些故事](http://mp.weixin.qq.com/s?__biz=MzUzNTY4NTYxMA==&mid=2247483754&idx=1&sn=e8929409d902d972a63372db9f3c7bb6&chksm=fa80f1efcdf778f9b4fa9ae746e347c4e918f31bf509a276b94106e2672060bcce8061cfdfb5&scene=21#wechat_redirect)提到：我们可以看到在两处看到validationTimeout的写入，一处是PoolBase构造函数，另一处是HouseKeeper线程。
leakDetectionThreshold的用法可以说是异曲同工，除了构造函数之外，也用了HouseKeeper线程去处理。

#### 2.1.1 HikariConfig

在com.zaxxer.hikari.HikariConfig中进行了leakDetectionThreshold初始化工作，

```java
@Override
   public void setLeakDetectionThreshold(long leakDetectionThresholdMs)
   {
      this.leakDetectionThreshold = leakDetectionThresholdMs;
   }
```

validateNumerics方法中则是解释了上文及官方文档中该值validate的策略。

```java
if (leakDetectionThreshold > 0 && !unitTest) {
   if (leakDetectionThreshold < SECONDS.toMillis(2) || (leakDetectionThreshold > maxLifetime && maxLifetime > 0)) {
      LOGGER.warn("{} - leakDetectionThreshold is less than 2000ms or more than maxLifetime, disabling it.", poolName);
      leakDetectionThreshold = 0;
   }
}
```

该方法会被HikariConfig#validate所调用，而HikariConfig#validate会在HikariDataSource的specified configuration的构造函数使用到

```java
 /**
  * Construct a HikariDataSource with the specified configuration.  The
  * {@link HikariConfig} is copied and the pool is started by invoking this
  * constructor.
  *
  * The {@link HikariConfig} can be modified without affecting the HikariDataSource
  * and used to initialize another HikariDataSource instance.
  *
  * @param configuration a HikariConfig instance
  */
 public HikariDataSource(HikariConfig configuration)
 {
    configuration.validate();
    configuration.copyStateTo(this);
    LOGGER.info("{} - Starting...", configuration.getPoolName());
    pool = fastPathPool = new HikariPool(this);
    LOGGER.info("{} - Start completed.", configuration.getPoolName());
    this.seal();
 }
```

也在每次getConnection的时候用到了，

```java
// ***********************************************************************
//                          DataSource methods
// ***********************************************************************
/** {@inheritDoc} */
@Override
public Connection getConnection() throws SQLException
{
  if (isClosed()) {
     throw new SQLException("HikariDataSource " + this + " has been closed.");
  }
  if (fastPathPool != null) {
     return fastPathPool.getConnection();
  }
  // See http://en.wikipedia.org/wiki/Double-checked_locking#Usage_in_Java
  HikariPool result = pool;
  if (result == null) {
     synchronized (this) {
        result = pool;
        if (result == null) {
           validate();
           LOGGER.info("{} - Starting...", getPoolName());
           try {
              pool = result = new HikariPool(this);
              this.seal();
           }
           catch (PoolInitializationException pie) {
              if (pie.getCause() instanceof SQLException) {
                 throw (SQLException) pie.getCause();
              }
              else {
                 throw pie;
              }
           }
           LOGGER.info("{} - Start completed.", getPoolName());
        }
     }
  }
  return result.getConnection();
}
```

这里要特别提一下一个很牛逼的Double-checked_locking的实现，大家可以看一下这篇文章 https://en.wikipedia.org/wiki/Double-checked_locking#Usage_in_Java

```java
// Works with acquire/release semantics for volatile in Java 1.5 and later
// Broken under Java 1.4 and earlier semantics for volatile
class Foo {
    private volatile Helper helper;
    public Helper getHelper() {
        Helper localRef = helper;
        if (localRef == null) {
            synchronized(this) {
                localRef = helper;
                if (localRef == null) {
                    helper = localRef = new Helper();
                }
            }
        }
        return localRef;
    }
    // other functions and members...
}
```

#### 2.1.2 HouseKeeper

我们再来看一下com.zaxxer.hikari.pool.HikariPool这个代码,该线程尝试在池中维护的最小空闲连接数，并不断刷新的通过MBean调整的connectionTimeout和validationTimeout等值，leakDetectionThreshold这个值也是通过这个HouseKeeper的leakTask.updateLeakDetectionThreshold(config.getLeakDetectionThreshold())去管理的。

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
          leakTask.updateLeakDetectionThreshold(config.getLeakDetectionThreshold());
          final long idleTimeout = config.getIdleTimeout();
          final long now = currentTime();
          // Detect retrograde time, allowing +128ms as per NTP spec.
          if (plusMillis(now, 128) < plusMillis(previous, HOUSEKEEPING_PERIOD_MS)) {
             LOGGER.warn("{} - Retrograde clock change detected (housekeeper delta={}), soft-evicting connections from pool.",
                         poolName, elapsedDisplayString(previous, now));
             previous = now;
             softEvictConnections();
             fillPool();
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
             int removed = 0;
             for (PoolEntry entry : notInUse) {
                if (elapsedMillis(entry.lastAccessed, now) > idleTimeout && connectionBag.reserve(entry)) {
                   closeConnection(entry, "(connection has passed idleTimeout)");
                   if (++removed > config.getMinimumIdle()) {
                      break;
                   }
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

这里补充说一下这个HouseKeeper，它是在com.zaxxer.hikari.pool.HikariPool的构造函数中初始化的：this.houseKeepingExecutorService = initializeHouseKeepingExecutorService();

```java
/**
  * Create/initialize the Housekeeping service {@link ScheduledExecutorService}.  If the user specified an Executor
  * to be used in the {@link HikariConfig}, then we use that.  If no Executor was specified (typical), then create
  * an Executor and configure it.
  *
  * @return either the user specified {@link ScheduledExecutorService}, or the one we created
  */
 private ScheduledExecutorService initializeHouseKeepingExecutorService()
 {
    if (config.getScheduledExecutor() == null) {
       final ThreadFactory threadFactory = Optional.ofNullable(config.getThreadFactory()).orElse(new DefaultThreadFactory(poolName + " housekeeper", true));
       final ScheduledThreadPoolExecutor executor = new ScheduledThreadPoolExecutor(1, threadFactory, new ThreadPoolExecutor.DiscardPolicy());
       executor.setExecuteExistingDelayedTasksAfterShutdownPolicy(false);
       executor.setRemoveOnCancelPolicy(true);
       return executor;
    }
    else {
       return config.getScheduledExecutor();
    }
 }
```

这里简要说明一下，ScheduledThreadPoolExecutor是ThreadPoolExecutor类的子类，因为继承了ThreadPoolExecutor类所有的特性。但是，Java推荐仅在开发定时任务程序时采用ScheduledThreadPoolExecutor类。

在调用shutdown()方法而仍有待处理的任务需要执行时，可以配置ScheduledThreadPoolExecutor的行为。默认的行为是不论执行器是否结束，待处理的任务仍将被执行。但是，通过调用ScheduledThreadPoolExecutor类的setExecuteExistingDelayedTasksAfterShutdownPolicy()方法则可以改变这个行为。**传递false参数给这个方法，执行shutdown()方法之后，待处理的任务将不会被执行。**

取消任务后，判断是否需要从阻塞队列中移除任务。其中removeOnCancel参数通过setRemoveOnCancelPolicy()设置。之所以要在取消任务后移除阻塞队列中任务，**是为了防止队列中积压大量已被取消的任务**。

从这两个参数配置大家可以了解到作者的对于HouseKeeper的配置初衷。

#### 2.1.3 小结

Hikari通过构造函数和HouseKeeper对于一些配置参数进行初始化及动态赋值，动态赋值依赖于HikariConfigMXbean以及使用任务调度线程池ScheduledThreadPoolExecutor来不断刷新配置的。

我们仅仅以com.zaxxer.hikari.HikariConfig来做下小结，允许在运行时进行动态修改的主要有：

```java
// Properties changeable at runtime through the HikariConfigMXBean
//
private volatile long connectionTimeout;
private volatile long validationTimeout;
private volatile long idleTimeout;
private volatile long leakDetectionThreshold;
private volatile long maxLifetime;
private volatile int maxPoolSize;
private volatile int minIdle;
private volatile String username;
private volatile String password;
```

不允许在运行时进行改变的主要有

```java
// Properties NOT changeable at runtime
//
private long initializationFailTimeout;
private String catalog;
private String connectionInitSql;
private String connectionTestQuery;
private String dataSourceClassName;
private String dataSourceJndiName;
private String driverClassName;
private String jdbcUrl;
private String poolName;
private String schema;
private String transactionIsolationName;
private boolean isAutoCommit;
private boolean isReadOnly;
private boolean isIsolateInternalQueries;
private boolean isRegisterMbeans;
private boolean isAllowPoolSuspension;
private DataSource dataSource;
private Properties dataSourceProperties;
private ThreadFactory threadFactory;
private ScheduledExecutorService scheduledExecutor;
private MetricsTrackerFactory metricsTrackerFactory;
private Object metricRegistry;
private Object healthCheckRegistry;
private Properties healthCheckProperties;
```

### 2.2 Read

#### 2.2.1 getConnection

在com.zaxxer.hikari.pool.HikariPool的核心方法getConnection返回的时候调用了poolEntry.createProxyConnection(leakTaskFactory.schedule(poolEntry), now)
注意，创建代理连接的时候关联了ProxyLeakTask。
连接泄漏检测的原理就是：**连接有借有还，hikari是每借用一个connection则会创建一个延时的定时任务，在归还或者出异常的或者用户手动调用evictConnection的时候cancel掉这个task**

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

#### 2.2.2 leakTaskFactory、ProxyLeakTaskFactory、ProxyLeakTask

在HikariPool构造函数里，初始化了leakTaskFactory，以及houseKeepingExecutorService。

```java
this.houseKeepingExecutorService = initializeHouseKeepingExecutorService();
this.leakTaskFactory = new ProxyLeakTaskFactory(config.getLeakDetectionThreshold(), houseKeepingExecutorService);
this.houseKeeperTask = houseKeepingExecutorService.scheduleWithFixedDelay(new HouseKeeper(), 100L, HOUSEKEEPING_PERIOD_MS, MILLISECONDS);
```

com.zaxxer.hikari.pool.ProxyLeakTaskFactory是作者惯用的设计，我们看一下源码：

```java
/**
 * A factory for {@link ProxyLeakTask} Runnables that are scheduled in the future to report leaks.
 *
 * @author Brett Wooldridge
 * @author Andreas Brenk
 */
class ProxyLeakTaskFactory
{
   private ScheduledExecutorService executorService;
   private long leakDetectionThreshold;
   ProxyLeakTaskFactory(final long leakDetectionThreshold, final ScheduledExecutorService executorService)
   {
      this.executorService = executorService;
      this.leakDetectionThreshold = leakDetectionThreshold;
   }
   ProxyLeakTask schedule(final PoolEntry poolEntry)
   {
      return (leakDetectionThreshold == 0) ? ProxyLeakTask.NO_LEAK : scheduleNewTask(poolEntry);
   }
   void updateLeakDetectionThreshold(final long leakDetectionThreshold)
   {
      this.leakDetectionThreshold = leakDetectionThreshold;
   }
   private ProxyLeakTask scheduleNewTask(PoolEntry poolEntry) {
      ProxyLeakTask task = new ProxyLeakTask(poolEntry);
      task.schedule(executorService, leakDetectionThreshold);
      return task;
   }
}
```

如果leakDetectionThreshold=0，即禁用连接泄露检测，schedule返回的是ProxyLeakTask.NO_LEAK，否则则新建一个ProxyLeakTask，在leakDetectionThreshold时间后触发

再看一下com.zaxxer.hikari.pool.ProxyLeakTask的源码

```java
/**
 * A Runnable that is scheduled in the future to report leaks.  The ScheduledFuture is
 * cancelled if the connection is closed before the leak time expires.
 *
 * @author Brett Wooldridge
 */
class ProxyLeakTask implements Runnable
{
   private static final Logger LOGGER = LoggerFactory.getLogger(ProxyLeakTask.class);
   static final ProxyLeakTask NO_LEAK;
   private ScheduledFuture<?> scheduledFuture;
   private String connectionName;
   private Exception exception;
   private String threadName; 
   private boolean isLeaked;
   static
   {
      NO_LEAK = new ProxyLeakTask() {
         @Override
         void schedule(ScheduledExecutorService executorService, long leakDetectionThreshold) {}
         @Override
         public void run() {}
         @Override
         public void cancel() {}
      };
   }
   ProxyLeakTask(final PoolEntry poolEntry)
   {
      this.exception = new Exception("Apparent connection leak detected");
      this.threadName = Thread.currentThread().getName();
      this.connectionName = poolEntry.connection.toString();
   }
   private ProxyLeakTask()
   {
   }
   void schedule(ScheduledExecutorService executorService, long leakDetectionThreshold)
   {
      scheduledFuture = executorService.schedule(this, leakDetectionThreshold, TimeUnit.MILLISECONDS);
   }
   /** {@inheritDoc} */
   @Override
   public void run()
   {
      isLeaked = true;
      final StackTraceElement[] stackTrace = exception.getStackTrace(); 
      final StackTraceElement[] trace = new StackTraceElement[stackTrace.length - 5];
      System.arraycopy(stackTrace, 5, trace, 0, trace.length);
      exception.setStackTrace(trace);
      LOGGER.warn("Connection leak detection triggered for {} on thread {}, stack trace follows", connectionName, threadName, exception);
   }
   void cancel()
   {
      scheduledFuture.cancel(false);
      if (isLeaked) {
         LOGGER.info("Previously reported leaked connection {} on thread {} was returned to the pool (unleaked)", connectionName, threadName);
      }
   }
}
```

NO_LEAK类里头的方法都是空操作。
一旦该task被触发，则抛出Exception("Apparent connection leak detected")

我们想起了什么，是不是想起了[【追光者系列】HikariCP源码分析之allowPoolSuspension](http://mp.weixin.qq.com/s?__biz=MzUzNTY4NTYxMA==&mid=2247483735&idx=1&sn=d8ed8446ebc5e3c3df02afb2c6c3ed77&chksm=fa80f1d2cdf778c4da61d53d37aa7123d603fc1a4abe0804cc7c03c20f83d91436301deb3fa6&scene=21#wechat_redirect)那篇文章里有着一摸一样的设计？

```java
this.suspendResumeLock = config.isAllowPoolSuspension() ? new SuspendResumeLock() : SuspendResumeLock.FAUX_LOCK;
```

#### 2.2.3 close

连接有借有还，连接检测的task也是会关闭的。
我们看一下com.zaxxer.hikari.pool.ProxyConnection源码

```java
// **********************************************************************
//              "Overridden" java.sql.Connection Methods
// **********************************************************************
/** {@inheritDoc} */
@Override
public final void close() throws SQLException
{
  // Closing statements can cause connection eviction, so this must run before the conditional below
  closeStatements();
  if (delegate != ClosedConnection.CLOSED_CONNECTION) {
     leakTask.cancel();
     try {
        if (isCommitStateDirty && !isAutoCommit) {
           delegate.rollback();
           lastAccess = currentTime();
           LOGGER.debug("{} - Executed rollback on connection {} due to dirty commit state on close().", poolEntry.getPoolName(), delegate);
        }
        if (dirtyBits != 0) {
           poolEntry.resetConnectionState(this, dirtyBits);
           lastAccess = currentTime();
        }
        delegate.clearWarnings();
     }
     catch (SQLException e) {
        // when connections are aborted, exceptions are often thrown that should not reach the application
        if (!poolEntry.isMarkedEvicted()) {
           throw checkException(e);
        }
     }
     finally {
        delegate = ClosedConnection.CLOSED_CONNECTION;
        poolEntry.recycle(lastAccess);
     }
  }
}
```

在connection的close的时候,delegate != ClosedConnection.CLOSED_CONNECTION时会调用leakTask.cancel();取消检测连接泄露的task。

在closeStatements中也会关闭：

```java
@SuppressWarnings("EmptyTryBlock")
private synchronized void closeStatements()
{
  final int size = openStatements.size();
  if (size > 0) {
     for (int i = 0; i < size && delegate != ClosedConnection.CLOSED_CONNECTION; i++) {
        try (Statement ignored = openStatements.get(i)) {
           // automatic resource cleanup
        }
        catch (SQLException e) {
           LOGGER.warn("{} - Connection {} marked as broken because of an exception closing open statements during Connection.close()",
                       poolEntry.getPoolName(), delegate);
           leakTask.cancel();
           poolEntry.evict("(exception closing Statements during Connection.close())");
           delegate = ClosedConnection.CLOSED_CONNECTION;
        }
     }
     openStatements.clear();
  }
}
```

在checkException中也会关闭

```java
final SQLException checkException(SQLException sqle)
{
  SQLException nse = sqle;
  for (int depth = 0; delegate != ClosedConnection.CLOSED_CONNECTION && nse != null && depth < 10; depth++) {
     final String sqlState = nse.getSQLState();
     if (sqlState != null && sqlState.startsWith("08") || ERROR_STATES.contains(sqlState) || ERROR_CODES.contains(nse.getErrorCode())) {
        // broken connection
        LOGGER.warn("{} - Connection {} marked as broken because of SQLSTATE({}), ErrorCode({})",
                    poolEntry.getPoolName(), delegate, sqlState, nse.getErrorCode(), nse);
        leakTask.cancel();
        poolEntry.evict("(connection is broken)");
        delegate = ClosedConnection.CLOSED_CONNECTION;
     }
     else {
        nse = nse.getNextException();
     }
  }
  return sqle;
}
```

在com.zaxxer.hikari.pool.HikariPool的evictConnection中，也会关闭任务

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

## 3. 测试模拟

我们可以根据本文对于leakDetectionThreshold的分析用测试包里的com.zaxxer.hikari.pool.MiscTest代码进行适当参数调整模拟连接泄漏情况，测试代码如下：

```java
/**
 * @author Brett Wooldridge
 */
public class MiscTest
{
   @Test
   public void testLogWriter() throws SQLException
   {
      HikariConfig config = newHikariConfig();
      config.setMinimumIdle(0);
      config.setMaximumPoolSize(4);
      config.setDataSourceClassName("com.zaxxer.hikari.mocks.StubDataSource");
      setConfigUnitTest(true);
      try (HikariDataSource ds = new HikariDataSource(config)) {
         PrintWriter writer = new PrintWriter(System.out);
         ds.setLogWriter(writer);
         assertSame(writer, ds.getLogWriter());
         assertEquals("testLogWriter", config.getPoolName());
      }
      finally
      {
         setConfigUnitTest(false);
      }
   }
   @Test
   public void testInvalidIsolation()
   {
      try {
         getTransactionIsolation("INVALID");
         fail();
      }
      catch (Exception e) {
         assertTrue(e instanceof IllegalArgumentException);
      }
   }
   @Test
   public void testCreateInstance()
   {
      try {
         createInstance("invalid", null);
         fail();
      }
      catch (RuntimeException e) {
         assertTrue(e.getCause() instanceof ClassNotFoundException);
      }
   }
   @Test
   public void testLeakDetection() throws Exception
   {
      ByteArrayOutputStream baos = new ByteArrayOutputStream();
      try (PrintStream ps = new PrintStream(baos, true)) {
         setSlf4jTargetStream(Class.forName("com.zaxxer.hikari.pool.ProxyLeakTask"), ps);
         setConfigUnitTest(true);
         HikariConfig config = newHikariConfig();
         config.setMinimumIdle(0);
         config.setMaximumPoolSize(4);
         config.setThreadFactory(Executors.defaultThreadFactory());
         config.setMetricRegistry(null);
         config.setLeakDetectionThreshold(TimeUnit.SECONDS.toMillis(4));
         config.setDataSourceClassName("com.zaxxer.hikari.mocks.StubDataSource");
         try (HikariDataSource ds = new HikariDataSource(config)) {
            setSlf4jLogLevel(HikariPool.class, Level.DEBUG);
            getPool(ds).logPoolState();
            try (Connection connection = ds.getConnection()) {
               quietlySleep(SECONDS.toMillis(4));
               connection.close();
               quietlySleep(SECONDS.toMillis(1));
               ps.close();
               String s = new String(baos.toByteArray());
               assertNotNull("Exception string was null", s);
               assertTrue("Expected exception to contain 'Connection leak detection' but contains *" + s + "*", s.contains("Connection leak detection"));
            }
         }
         finally
         {
            setConfigUnitTest(false);
            setSlf4jLogLevel(HikariPool.class, Level.INFO);
         }
      }
   }
}
```

当代码执行到了quietlySleep(SECONDS.toMillis(4));时直接按照预期抛异常Apparent connection leak detected。

![16](http://blog-1259650185.cosbj.myqcloud.com/img/202205/14/1652541350.jpeg)

```java
23:30:36,925153 [seq  1] [main            ] DEBUG HikariConfig      - testLogWriter - configuration:
23:30:36,942176 [seq  2] [main            ] DEBUG HikariConfig      - allowPoolSuspension.............false
23:30:36,942636 [seq  3] [main            ] DEBUG HikariConfig      - autoCommit......................true
23:30:36,942864 [seq  4] [main            ] DEBUG HikariConfig      - catalog.........................none
23:30:36,943069 [seq  5] [main            ] DEBUG HikariConfig      - connectionInitSql...............none
23:30:36,943239 [seq  6] [main            ] DEBUG HikariConfig      - connectionTestQuery.............none
23:30:36,943414 [seq  7] [main            ] DEBUG HikariConfig      - connectionTimeout...............30000
23:30:36,943587 [seq  8] [main            ] DEBUG HikariConfig      - dataSource......................none
23:30:36,944324 [seq  9] [main            ] DEBUG HikariConfig      - dataSourceClassName............."com.zaxxer.hikari.mocks.StubDataSource"
23:30:36,944540 [seq 10] [main            ] DEBUG HikariConfig      - dataSourceJNDI..................none
23:30:36,945340 [seq 11] [main            ] DEBUG HikariConfig      - dataSourceProperties............{password=<masked>}
23:30:36,945580 [seq 12] [main            ] DEBUG HikariConfig      - driverClassName.................none
23:30:36,945742 [seq 13] [main            ] DEBUG HikariConfig      - exceptionOverrideClassName......none
23:30:36,945912 [seq 14] [main            ] DEBUG HikariConfig      - healthCheckProperties...........{}
23:30:36,946066 [seq 15] [main            ] DEBUG HikariConfig      - healthCheckRegistry.............none
23:30:36,946283 [seq 16] [main            ] DEBUG HikariConfig      - idleTimeout.....................600000
23:30:36,946479 [seq 17] [main            ] DEBUG HikariConfig      - initializationFailTimeout.......1
23:30:36,946672 [seq 18] [main            ] DEBUG HikariConfig      - isolateInternalQueries..........false
23:30:36,946826 [seq 19] [main            ] DEBUG HikariConfig      - jdbcUrl.........................none
23:30:36,946977 [seq 20] [main            ] DEBUG HikariConfig      - keepaliveTime...................0
23:30:36,947149 [seq 21] [main            ] DEBUG HikariConfig      - leakDetectionThreshold..........0
23:30:36,947301 [seq 22] [main            ] DEBUG HikariConfig      - maxLifetime.....................1800000
23:30:36,947455 [seq 23] [main            ] DEBUG HikariConfig      - maximumPoolSize.................4
23:30:36,947623 [seq 24] [main            ] DEBUG HikariConfig      - metricRegistry..................none
23:30:36,947790 [seq 25] [main            ] DEBUG HikariConfig      - metricsTrackerFactory...........none
23:30:36,947937 [seq 26] [main            ] DEBUG HikariConfig      - minimumIdle.....................0
23:30:36,948082 [seq 27] [main            ] DEBUG HikariConfig      - password........................<masked>
23:30:36,948230 [seq 28] [main            ] DEBUG HikariConfig      - poolName........................"testLogWriter"
23:30:36,948407 [seq 29] [main            ] DEBUG HikariConfig      - readOnly........................false
23:30:36,948574 [seq 30] [main            ] DEBUG HikariConfig      - registerMbeans..................false
23:30:36,948722 [seq 31] [main            ] DEBUG HikariConfig      - scheduledExecutor...............none
23:30:36,948867 [seq 32] [main            ] DEBUG HikariConfig      - schema..........................none
23:30:36,949017 [seq 33] [main            ] DEBUG HikariConfig      - threadFactory...................internal
23:30:36,949145 [seq 34] [main            ] DEBUG HikariConfig      - transactionIsolation............default
23:30:36,949289 [seq 35] [main            ] DEBUG HikariConfig      - username........................none
23:30:36,949436 [seq 36] [main            ] DEBUG HikariConfig      - validationTimeout...............5000
23:30:36,950510 [seq 37] [main            ] INFO  HikariDataSource  - testLogWriter - Starting...
23:30:36,983556 [seq 38] [main            ] DEBUG PoolBase          - testLogWriter - Closing connection com.zaxxer.hikari.mocks.StubConnection@18e8eb59: (initialization check complete and minimumIdle is zero)
23:30:36,987920 [seq 39] [main            ] INFO  HikariDataSource  - testLogWriter - Start completed.
23:30:36,988384 [seq 40] [main            ] INFO  HikariDataSource  - testLogWriter - Shutdown initiated...
23:30:36,988607 [seq 41] [main            ] DEBUG HikariPool        - testLogWriter - Before shutdown stats (total=0, active=0, idle=0, waiting=0)
23:30:36,990539 [seq 42] [main            ] DEBUG HikariPool        - testLogWriter - After shutdown stats (total=0, active=0, idle=0, waiting=0)
23:30:36,990804 [seq 43] [main            ] INFO  HikariDataSource  - testLogWriter - Shutdown completed.
23:30:37,006826 [seq 44] [main            ] DEBUG HikariConfig      - testLeakDetection - configuration:
23:30:37,008449 [seq 45] [main            ] DEBUG HikariConfig      - allowPoolSuspension.............false
23:30:37,008759 [seq 46] [main            ] DEBUG HikariConfig      - autoCommit......................true
23:30:37,008958 [seq 47] [main            ] DEBUG HikariConfig      - catalog.........................none
23:30:37,009132 [seq 48] [main            ] DEBUG HikariConfig      - connectionInitSql...............none
23:30:37,009308 [seq 49] [main            ] DEBUG HikariConfig      - connectionTestQuery.............none
23:30:37,009472 [seq 50] [main            ] DEBUG HikariConfig      - connectionTimeout...............30000
23:30:37,009637 [seq 51] [main            ] DEBUG HikariConfig      - dataSource......................none
23:30:37,009804 [seq 52] [main            ] DEBUG HikariConfig      - dataSourceClassName............."com.zaxxer.hikari.mocks.StubDataSource"
23:30:37,009989 [seq 53] [main            ] DEBUG HikariConfig      - dataSourceJNDI..................none
23:30:37,010238 [seq 54] [main            ] DEBUG HikariConfig      - dataSourceProperties............{password=<masked>}
23:30:37,010435 [seq 55] [main            ] DEBUG HikariConfig      - driverClassName.................none
23:30:37,010636 [seq 56] [main            ] DEBUG HikariConfig      - exceptionOverrideClassName......none
23:30:37,010808 [seq 57] [main            ] DEBUG HikariConfig      - healthCheckProperties...........{}
23:30:37,010959 [seq 58] [main            ] DEBUG HikariConfig      - healthCheckRegistry.............none
23:30:37,011134 [seq 59] [main            ] DEBUG HikariConfig      - idleTimeout.....................600000
23:30:37,011282 [seq 60] [main            ] DEBUG HikariConfig      - initializationFailTimeout.......1
23:30:37,011464 [seq 61] [main            ] DEBUG HikariConfig      - isolateInternalQueries..........false
23:30:37,011609 [seq 62] [main            ] DEBUG HikariConfig      - jdbcUrl.........................none
23:30:37,011756 [seq 63] [main            ] DEBUG HikariConfig      - keepaliveTime...................0
23:30:37,011902 [seq 64] [main            ] DEBUG HikariConfig      - leakDetectionThreshold..........1000
23:30:37,012047 [seq 65] [main            ] DEBUG HikariConfig      - maxLifetime.....................1800000
23:30:37,012189 [seq 66] [main            ] DEBUG HikariConfig      - maximumPoolSize.................4
23:30:37,012331 [seq 67] [main            ] DEBUG HikariConfig      - metricRegistry..................none
23:30:37,012472 [seq 68] [main            ] DEBUG HikariConfig      - metricsTrackerFactory...........none
23:30:37,012612 [seq 69] [main            ] DEBUG HikariConfig      - minimumIdle.....................0
23:30:37,012765 [seq 70] [main            ] DEBUG HikariConfig      - password........................<masked>
23:30:37,012926 [seq 71] [main            ] DEBUG HikariConfig      - poolName........................"testLeakDetection"
23:30:37,013173 [seq 72] [main            ] DEBUG HikariConfig      - readOnly........................false
23:30:37,013349 [seq 73] [main            ] DEBUG HikariConfig      - registerMbeans..................false
23:30:37,013497 [seq 74] [main            ] DEBUG HikariConfig      - scheduledExecutor...............none
23:30:37,013645 [seq 75] [main            ] DEBUG HikariConfig      - schema..........................none
23:30:37,013797 [seq 76] [main            ] DEBUG HikariConfig      - threadFactory...................java.util.concurrent.Executors$DefaultThreadFactory@3b2c8bda
23:30:37,013927 [seq 77] [main            ] DEBUG HikariConfig      - transactionIsolation............default
23:30:37,014072 [seq 78] [main            ] DEBUG HikariConfig      - username........................none
23:30:37,014217 [seq 79] [main            ] DEBUG HikariConfig      - validationTimeout...............5000
23:30:37,014442 [seq 80] [main            ] INFO  HikariDataSource  - testLeakDetection - Starting...
23:30:37,015185 [seq 81] [main            ] DEBUG PoolBase          - testLeakDetection - Closing connection com.zaxxer.hikari.mocks.StubConnection@647ff23e: (initialization check complete and minimumIdle is zero)
23:30:37,015547 [seq 82] [main            ] INFO  HikariDataSource  - testLeakDetection - Start completed.
23:30:37,016277 [seq 83] [main            ] DEBUG HikariPool        - testLeakDetection - stats (total=0, active=0, idle=0, waiting=0)
23:30:37,017130 [seq 84] [pool-4-thread-2 ] DEBUG HikariPool        - testLeakDetection - Added connection com.zaxxer.hikari.mocks.StubConnection@a6db0ad
23:30:37,119456 [seq 85] [pool-4-thread-1 ] DEBUG HikariPool        - testLeakDetection - Before cleanup stats (total=1, active=1, idle=0, waiting=0)
23:30:37,119922 [seq 86] [pool-4-thread-1 ] DEBUG HikariPool        - testLeakDetection - After cleanup  stats (total=1, active=1, idle=0, waiting=0)
23:30:37,120065 [seq 87] [pool-4-thread-1 ] DEBUG HikariPool        - testLeakDetection - Fill pool skipped, pool has sufficient level or currently being filled (queueDepth=0).
23:30:42,057245 [seq 88] [main            ] INFO  HikariDataSource  - testLeakDetection - Shutdown initiated...
23:30:42,058551 [seq 89] [main            ] DEBUG HikariPool        - testLeakDetection - Before shutdown stats (total=1, active=0, idle=1, waiting=0)
23:30:42,063104 [seq 90] [pool-4-thread-3 ] DEBUG PoolBase          - testLeakDetection - Closing connection com.zaxxer.hikari.mocks.StubConnection@a6db0ad: (connection evicted)
23:30:42,064987 [seq 91] [main            ] DEBUG HikariPool        - testLeakDetection - After shutdown stats (total=0, active=0, idle=0, waiting=0)
23:30:42,065377 [seq 92] [main            ] INFO  HikariDataSource  - testLeakDetection - Shutdown completed.
```

紧接着在close的过程中执行到了delegate != ClosedConnection.CLOSED_CONNECTION来进行leakTask.cancel()

![17](http://blog-1259650185.cosbj.myqcloud.com/img/202205/14/1652543365.jpeg)

完整的测试输出模拟过程如下所示：

![18](http://blog-1259650185.cosbj.myqcloud.com/img/202205/14/1652543474.jpeg)



## 参考

[【追光者系列】HikariCP源码分析之leakDetectionThreshold及实战解决Spark/Scala连接池泄漏](https://mp.weixin.qq.com/s/_ghOnuwbLHOkqGKgzWdLVw)
