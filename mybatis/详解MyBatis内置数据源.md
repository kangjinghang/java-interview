本篇文章将向大家介绍 MyBatis 内置数据源的实现逻辑。MyBatis 支持三种数据源配置，分别为 UNPOOLED、POOLED 和 JNDI。并提供了两种数据源实现，分别是 UnpooledDataSource 和 PooledDataSource 。 在这三种数据源配置中， UNPOOLED 和 POOLED 是我们最常用的两种配置，这两种数据源也是本章要重点分析的对象。至于 JNDI， MyBatis 提供这种数据源的目的是为了让其能够运行在 EJB 或应用服务器等容器中，这一点官方文档中有所说明。由于 JNDI 数据源在日常开发中使用甚少，因此，本篇文章不打算分析 JNDI 数据源相关源码。

## 1. 内置数据源初始化过程

在详细分析 UnpooledDataSource 和 PooledDataSource 两种数据源实现之前，我们先来了解一下数据源的配置与初始化过程。先来看一下数据源配置方法，如下：

```xml
<dataSource type="UNPOOLED|POOLED">
    <property name="driver" value="com.mysql.cj.jdbc.Driver"/>
    <property name="url" value="jdbc:mysql..."/>
    <property name="username" value="root"/>
    <property name="password" value="1234"/>
</dataSource>
```

数据源的配置是内嵌在\<environment\>节点中的，MyBatis 在解析\<environment\>节点时，会一并解析数据源的配置。MyBatis 会根据具体的配置信息，为不同的数据源创建相应工厂类，通过工厂类即可创建数据源实例。关于数据源配置的解析以及数据源工厂类的创建过程，本书第二章分析过，这里就不赘述了。下面我们来看一下数据源工厂类的实现逻辑。

```java
public class UnpooledDataSourceFactory implements DataSourceFactory {

  private static final String DRIVER_PROPERTY_PREFIX = "driver.";
  private static final int DRIVER_PROPERTY_PREFIX_LENGTH = DRIVER_PROPERTY_PREFIX.length();

  protected DataSource dataSource;

  public UnpooledDataSourceFactory() {
    this.dataSource = new UnpooledDataSource(); // 创建 UnpooledDataSource 对象
  }

  @Override
  public void setProperties(Properties properties) {
    Properties driverProperties = new Properties();
    MetaObject metaDataSource = SystemMetaObject.forObject(dataSource); // 为 dataSource 创建元信息对象
    for (Object key : properties.keySet()) { // 遍历 properties 键列表，properties 由配置文件解析器传入
      String propertyName = (String) key;
      if (propertyName.startsWith(DRIVER_PROPERTY_PREFIX)) { // 检测 propertyName 是否以 "driver." 开头
        String value = properties.getProperty(propertyName);
        driverProperties.setProperty(propertyName.substring(DRIVER_PROPERTY_PREFIX_LENGTH), value); // 存储配置信息到 driverProperties 中
      } else if (metaDataSource.hasSetter(propertyName)) {
        String value = (String) properties.get(propertyName);
        Object convertedValue = convertValue(metaDataSource, propertyName, value);  // 按需转换 value 类型
        metaDataSource.setValue(propertyName, convertedValue); // 设置转换后的值到 UnpooledDataSourceFactory 指定属性中
      } else {
        throw new DataSourceException("Unknown DataSource property: " + propertyName);
      }
    }
    if (driverProperties.size() > 0) {
      metaDataSource.setValue("driverProperties", driverProperties); // 设置 driverProperties 到 UnpooledDataSource 的 driverProperties 属性中
    }
  }

  @Override
  public DataSource getDataSource() {
    return dataSource;
  }

  private Object convertValue(MetaObject metaDataSource, String propertyName, String value) {
    Object convertedValue = value;
    Class<?> targetType = metaDataSource.getSetterType(propertyName); // 获取属性对应的 setter 方法的参数类型
    if (targetType == Integer.class || targetType == int.class) { // 按照 setter 方法的参数类型进行类型转换
      convertedValue = Integer.valueOf(value);
    } else if (targetType == Long.class || targetType == long.class) {
      convertedValue = Long.valueOf(value);
    } else if (targetType == Boolean.class || targetType == boolean.class) {
      convertedValue = Boolean.valueOf(value);
    }
    return convertedValue;
  }

}
```

在 UnpooledDataSourceFactory 的源码中，除了 setProperties 方法稍复杂一点，其他的都比较简单。下面看看 PooledDataSourceFactory 的源码。

```java
public class PooledDataSourceFactory extends UnpooledDataSourceFactory {

  public PooledDataSourceFactory() {
    this.dataSource = new PooledDataSource(); // 创建 PooledDataSource
  }

}
```

以上就是 PooledDataSource 类的所有源码， PooledDataSourceFactory 继承自 UnpooledDataSourceFactory，复用了父类的逻辑，因此它的实现很简单。关于两种数据源的创建过程就先分析到这，接下来，我们去探究一下两种数据源是怎样实现的。

## 2. UnpooledDataSource

UnpooledDataSource，从名称上即可知道，该种数据源不具有池化特性。该种数据源每次会返回一个新的数据库连接，而非复用旧的连接。由于 UnpooledDataSource 无需提供连接池功能，因此它的实现非常简单。核心的方法有三个，分别如下：

1. initializeDriver - 初始化数据库驱动。

2. doGetConnection - 获取数据连接。

3. configureConnection - 配置数据库连接。

下面将按照顺序分节对相关方法进行分析，由于 configureConnection 方法比较简单，因此我把它和 doGetConnection 放在一节中进行分析。

### 2.1 初始化数据库驱动

回顾我们一开始学习使用 JDBC 访问数据库时的情景，在执行 SQL 之前，通常都是先获取数据库连接。一般步骤都是加载数据库驱动，然后通过 DriverManager 获取数据库连接。UnpooledDataSource 也是使用 JDBC 访问数据库的，因此它获取数据库连接的过程也大致如此，只不过会稍有不同。下面我们一起看一下。

```java
// UnpooledDataSource.java
private synchronized void initializeDriver() throws SQLException {
  if (!registeredDrivers.containsKey(driver)) { // 检测缓存中是否包含了与 driver 对应的驱动实例
    Class<?> driverType;
    try {
      if (driverClassLoader != null) {
        driverType = Class.forName(driver, true, driverClassLoader); // 加载驱动类型
      } else {
        driverType = Resources.classForName(driver); // 通过其他 ClassLoader 加载驱动
      }
      // DriverManager requires the driver to be loaded via the system ClassLoader.
      // http://www.kfu.com/~nsayer/Java/dyn-jdbc.html
      Driver driverInstance = (Driver) driverType.getDeclaredConstructor().newInstance(); // 通过反射创建驱动实例
      // 注册驱动，注意这里是将 Driver 代理类 DriverProxy 对象注册，而非 Driver 对象本身。DriverProxy 中并没什么特别的逻辑，就不分析。
      DriverManager.registerDriver(new DriverProxy(driverInstance));
      registeredDrivers.put(driver, driverInstance); // 缓存驱动类名和实例
    } catch (Exception e) {
      throw new SQLException("Error setting driver on UnpooledDataSource. Cause: " + e);
    }
  }
}
```

如上，initializeDriver 方法主要包含三步操作，分别如下：

1. 加载驱动。

2. 通过反射创建驱动实例。

3. 注册驱动实例。

这三步都是都是常规操作，比较容易理解。上面代码中出现了缓存相关的逻辑，这个是用于避免重复注册驱动。因为 initializeDriver 方法并不是在 UnpooledDataSource 初始化时被调用的，而是在获取数据库连接时被调用的。因此这里需要做个检测，避免每次获取数据库连接时都重新注册驱动。这个是一个比较小的点，大家看代码时注意一下即可。下面看一下获取数据库连接的逻辑。

### 2.2 获取数据库连接

在使用 JDBC 时，我们都是通过 DriverManager 的接口方法获取数据库连接。本节所要分析的源码也不例外，一起看一下吧。

```java
// UnpooledDataSource.java
@Override
public Connection getConnection() throws SQLException {
  return doGetConnection(username, password);
}

private Connection doGetConnection(String username, String password) throws SQLException {
  Properties props = new Properties();
  if (driverProperties != null) {
    props.putAll(driverProperties);
  }
  if (username != null) {
    props.setProperty("user", username); // 存储 user 配置
  }
  if (password != null) {
    props.setProperty("password", password); // 存储 password 配置
  }
  return doGetConnection(props); // 调用重载方法
}

private Connection doGetConnection(Properties properties) throws SQLException {
  initializeDriver(); // 初始化驱动
  Connection connection = DriverManager.getConnection(url, properties); // 获取连接
  configureConnection(connection); // 配置连接，包括自动ᨀ交以及事务等级
  return connection;
}

private void configureConnection(Connection conn) throws SQLException {
  if (defaultNetworkTimeout != null) {
    conn.setNetworkTimeout(Executors.newSingleThreadExecutor(), defaultNetworkTimeout);
  }
  if (autoCommit != null && autoCommit != conn.getAutoCommit()) {
    conn.setAutoCommit(autoCommit); // 设置自动提交
  }
  if (defaultTransactionIsolationLevel != null) {
    conn.setTransactionIsolation(defaultTransactionIsolationLevel); // 设置事务隔离级别
  }
}
```

如上，上面方法将一些配置信息放入到 Properties 对象中，然后将数据库连接和 Properties 对象传给 DriverManager 的 getConnection 方法即可获取到数据库连接。

## 3. PooledDataSource

PooledDataSource 内部实现了连接池功能，用于复用数据库连接。因此，从效率上来说，PooledDataSource 要高于 UnpooledDataSource。PooledDataSource 需要借助一些辅助类帮助它完成连接池的功能，所以接下来，我们先来认识一下相关的辅助类。

### 3.1 辅助类介绍

PooledDataSource 需要借助两个辅助类帮其完成功能，这两个辅助类分别是 PoolState 和 PooledConnection。PoolState 用于记录连接池运行时的状态，比如连接获取次数，无效连接数量等。同时 PoolState 内部定义了两个 PooledConnection 集合，用于存储空闲连接和活跃连接。PooledConnection 内部定义了一个 Connection 类型的变量，用于指向真实的数据库连接。以及一个 Connection 的代理类，用于对部分方法调用进行拦截。至于为什么要拦截，随后将进行分析。除此之外，PooledConnection 内部也定义了一些字段，用于记录数据库连接的一些运行时状态。接下来，我们来看一下 PooledConnection 的定义。

```java
class PooledConnection implements InvocationHandler {

    private static final String CLOSE = "close";
    private static final Class<?>[] IFACES = new Class<?>[]{Connection.class};

    private final int hashCode;
    private final PooledDataSource dataSource;
    // 真实的数据库连接
    private final Connection realConnection;
    // 数据库连接代理
    private final Connection proxyConnection;
    
    // 从连接池中取出连接时的时间戳
    private long checkoutTimestamp;
    // 数据库连接创建时间
    private long createdTimestamp;
    // 数据库连接最后使用时间
    private long lastUsedTimestamp;
    // connectionTypeCode = (url + username + password).hashCode()
    private int connectionTypeCode;
    // 表示连接是否有效
    private boolean valid;

    public PooledConnection(Connection connection, PooledDataSource dataSource) {
        this.hashCode = connection.hashCode();
        this.realConnection = connection;
        this.dataSource = dataSource;
        this.createdTimestamp = System.currentTimeMillis();
        this.lastUsedTimestamp = System.currentTimeMillis();
        this.valid = true;
        // 创建 Connection 的代理类对象
        this.proxyConnection = (Connection) Proxy.newProxyInstance(Connection.class.getClassLoader(), IFACES, this);
    }
    
    
    public Object invoke(Object proxy, Method method, Object[] args) throws Throwable {...}
    
    // 省略部分代码
}
```

下面再来看看 PoolState 的定义。

```java
public class PoolState {

    protected PooledDataSource dataSource;

    // 空闲连接列表
    protected final List<PooledConnection> idleConnections = new ArrayList<PooledConnection>();
    // 活跃连接列表
    protected final List<PooledConnection> activeConnections = new ArrayList<PooledConnection>();
    // 从连接池中获取连接的次数
    protected long requestCount = 0;
    // 请求连接总耗时（单位：毫秒）
    protected long accumulatedRequestTime = 0;
    // 连接执行时间总耗时
    protected long accumulatedCheckoutTime = 0;
    // 执行时间超时的连接数
    protected long claimedOverdueConnectionCount = 0;
    // 超时时间累加值
    protected long accumulatedCheckoutTimeOfOverdueConnections = 0;
    // 等待时间累加值
    protected long accumulatedWaitTime = 0;
    // 等待次数
    protected long hadToWaitCount = 0;
    // 无效连接数
    protected long badConnectionCount = 0;
}
```

上面对 PooledConnection 和 PoolState 的定义进行了一些注释，这两个类中有很多字段用来记录运行时状态。但在这些字段并非核心，因此大家知道每个字段的用途就行了。

### 3.2 获取连接

前面已经说过，PooledDataSource 会将用过的连接进行回收，以便可以复用连接。因此从 PooledDataSource 获取连接时，如果空闲链接列表里有连接时，可直接取用。那如果没有空闲连接怎么办呢？此时有两种解决办法，要么创建新连接，要么等待其他连接完成任务。具体怎么做，需视情况而定。下面我们深入到源码中一探究竟。

```java
// PooledDataSource.java
private PooledConnection popConnection(String username, String password) throws SQLException {
  boolean countedWait = false;
  PooledConnection conn = null;
  long t = System.currentTimeMillis();
  int localBadConnectionCount = 0;

  while (conn == null) {
    synchronized (state) {
      if (!state.idleConnections.isEmpty()) { // 检测空闲连接集合（idleConnections）是否为空
        // Pool has available connection
        conn = state.idleConnections.remove(0); // idleConnections 不为空，表示有空闲连接可以使用
        if (log.isDebugEnabled()) {
          log.debug("Checked out connection " + conn.getRealHashCode() + " from pool.");
        }
      } else {
        // Pool does not have available connection
        if (state.activeConnections.size() < poolMaximumActiveConnections) { // 暂无空闲连接可用，但如果活跃连接数还未超出限制，则可创建新的连接
          // Can create new connection
          conn = new PooledConnection(dataSource.getConnection(), this); // 创建新连接
          if (log.isDebugEnabled()) {
            log.debug("Created connection " + conn.getRealHashCode() + ".");
          }
        } else {
          // Cannot create new connection 连接池已满，不能创建新连接
          PooledConnection oldestActiveConnection = state.activeConnections.get(0); // 取出运行时间最长的连接
          long longestCheckoutTime = oldestActiveConnection.getCheckoutTime(); // 获取运行时长
          if (longestCheckoutTime > poolMaximumCheckoutTime) { // 检测运行时长是否超出限制，即超时
            // Can claim overdue connection
            state.claimedOverdueConnectionCount++; // 累加超时相关的统计字段
            state.accumulatedCheckoutTimeOfOverdueConnections += longestCheckoutTime;
            state.accumulatedCheckoutTime += longestCheckoutTime;
            state.activeConnections.remove(oldestActiveConnection); // 从活跃连接集合中移除超时连接
            if (!oldestActiveConnection.getRealConnection().getAutoCommit()) { // 若连接未设置自动提交，此处进行回滚操作
              try {
                oldestActiveConnection.getRealConnection().rollback();
              } catch (SQLException e) {
                /*
                   Just log a message for debug and continue to execute the following
                   statement like nothing happened.
                   Wrap the bad connection with a new PooledConnection, this will help
                   to not interrupt current executing thread and give current thread a
                   chance to join the next competition for another valid/good database
                   connection. At the end of this loop, bad {@link @conn} will be set as null.
                 */
                log.debug("Bad connection. Could not roll back");
              }
            }
            conn = new PooledConnection(oldestActiveConnection.getRealConnection(), this); // 创建一个新的 PooledConnection，注意，此处复用oldestActiveConnection 的 realConnection 变量
            // 复用 oldestActiveConnection 的一些信息，注意 PooledConnection 中的 createdTimestamp 用于记录
            // real Connection 的创建时间，而非 PooledConnection 的创建时间。所以这里要复用原连接的时间信息。
            conn.setCreatedTimestamp(oldestActiveConnection.getCreatedTimestamp());
            conn.setLastUsedTimestamp(oldestActiveConnection.getLastUsedTimestamp());
            oldestActiveConnection.invalidate(); // 设置连接为无效状态
            if (log.isDebugEnabled()) {
              log.debug("Claimed overdue connection " + conn.getRealHashCode() + ".");
            }
          } else { // 运行时间最长的连接并未超时
            // Must wait
            try {
              if (!countedWait) {
                state.hadToWaitCount++;
                countedWait = true;
              }
              if (log.isDebugEnabled()) {
                log.debug("Waiting as long as " + poolTimeToWait + " milliseconds for connection.");
              }
              long wt = System.currentTimeMillis();
              state.wait(poolTimeToWait); // 当前线程进入等待状态
              state.accumulatedWaitTime += System.currentTimeMillis() - wt; // 线程被唤醒后累加等待时间统计字段
            } catch (InterruptedException e) {
              break;
            }
          }
        }
      }
      if (conn != null) {
        // 检测连接是否有效，isValid 方法除了会检测 valid 是否为 true，还会通过 PooledConnection 的 pingConnection
        // 方法执行 SQL 语句，检测连接是否可用。pingConnection 方法的逻辑不复杂，大家自行分析。
        // ping to server and check the connection is valid or not
        if (conn.isValid()) {
          if (!conn.getRealConnection().getAutoCommit()) {
            conn.getRealConnection().rollback(); // 进行回滚操作
          }
          conn.setConnectionTypeCode(assembleConnectionTypeCode(dataSource.getUrl(), username, password));
          conn.setCheckoutTimestamp(System.currentTimeMillis()); // 设置统计字段
          conn.setLastUsedTimestamp(System.currentTimeMillis());
          state.activeConnections.add(conn);
          state.requestCount++;
          state.accumulatedRequestTime += System.currentTimeMillis() - t;
        } else { // 连接无效，此时累加无效连接相关的统计字段
          if (log.isDebugEnabled()) {
            log.debug("A bad connection (" + conn.getRealHashCode() + ") was returned from the pool, getting another connection.");
          }
          state.badConnectionCount++;
          localBadConnectionCount++;
          conn = null;
          if (localBadConnectionCount > (poolMaximumIdleConnections + poolMaximumLocalBadConnectionTolerance)) {
            if (log.isDebugEnabled()) {
              log.debug("PooledDataSource: Could not get a good connection to the database.");
            }
            throw new SQLException("PooledDataSource: Could not get a good connection to the database.");
          }
        }
      }
    }

  }

  if (conn == null) {
    if (log.isDebugEnabled()) {
      log.debug("PooledDataSource: Unknown severe error condition.  The connection pool returned a null connection.");
    }
    throw new SQLException("PooledDataSource: Unknown severe error condition.  The connection pool returned a null connection.");
  }

  return conn;
}
```

上面代码冗长，过程比较复杂，下面把代码逻辑梳理一下。从连接池中获取连接首先会遇到两种情况：

1. 连接池中有空闲连接。

2. 连接池中无空闲连接。

对于第一种情况，处理措施就很简单了，把连接取出返回即可。对于第二种情况，则要进行细分，会有如下的情况。

1. 活跃连接数没有超出最大活跃连接数。

2. 活跃连接数超出最大活跃连接数。

对于上面两种情况，第一种情况比较好处理，直接创建新的连接即可。至于第二种情况，需要再次进行细分。

1. 活跃连接的运行时间超出限制，即超时了。

2. 活跃连接未超时。

对于第一种情况，我们直接将超时连接强行中断，并进行回滚，然后复用部分字段重新创建 PooledConnection 即可。对于第二种情况，目前没有更好的处理方式了，只能等待了。

下面用一段伪代码演示各种情况及相应的处理措施，如下：

```java
if (连接池中有空闲连接) {
    1. 将连接从空闲连接集合中移除
} else {
    if (活跃连接数未超出限制) {
        1. 创建新连接
    } else {
        1. 从活跃连接集合中取出第一个元素
        2. 获取连接运行时长
        
        if (连接超时) {
            1. 将连接从活跃集合中移除
            2. 复用原连接的成员变量，并创建新的 PooledConnection 对象
        } else {
            1. 线程进入等待状态
            2. 线程被唤醒后，重新执行以上逻辑
        }
    }
}

1. 将连接添加到活跃连接集合中
2. 返回连接
```

最后用一个流程图大致描绘 popConnection 的逻辑，如下：

![2](http://blog-1259650185.cosbj.myqcloud.com/img/202203/02/1646187645.jpeg)

### 3.3 回收连接

相比获取连接，回收连接的逻辑要简单的多。回收连接成功与否只取决于空闲连接集合的状态，所需处理情况很少，因此比较简单。下面看一下相关的代码。

```java
// PooledDataSource.java
protected void pushConnection(PooledConnection conn) throws SQLException {

  synchronized (state) {
    state.activeConnections.remove(conn); // 从活跃连接池中移除连接
    if (conn.isValid()) {
      if (state.idleConnections.size() < poolMaximumIdleConnections && conn.getConnectionTypeCode() == expectedConnectionTypeCode) { // 空闲连接集合未满
        state.accumulatedCheckoutTime += conn.getCheckoutTime();
        if (!conn.getRealConnection().getAutoCommit()) { // 回滚未提交的事务
          conn.getRealConnection().rollback();
        }
        PooledConnection newConn = new PooledConnection(conn.getRealConnection(), this); // 创建新的 PooledConnection
        state.idleConnections.add(newConn);
        newConn.setCreatedTimestamp(conn.getCreatedTimestamp()); // 复用时间信息
        newConn.setLastUsedTimestamp(conn.getLastUsedTimestamp());
        conn.invalidate(); // 将原连接置为无效状态
        if (log.isDebugEnabled()) {
          log.debug("Returned connection " + newConn.getRealHashCode() + " to pool.");
        }
        state.notifyAll(); // 唤醒处于睡眠中的线程
      } else { // 空闲连接集合已满
        state.accumulatedCheckoutTime += conn.getCheckoutTime();
        if (!conn.getRealConnection().getAutoCommit()) { // 回滚未提交的事务
          conn.getRealConnection().rollback();
        }
        conn.getRealConnection().close(); // 关闭数据库连接
        if (log.isDebugEnabled()) {
          log.debug("Closed connection " + conn.getRealHashCode() + ".");
        }
        conn.invalidate(); // 将原连接置为无效状态
      }
    } else {
      if (log.isDebugEnabled()) {
        log.debug("A bad connection (" + conn.getRealHashCode() + ") attempted to return to the pool, discarding connection.");
      }
      state.badConnectionCount++;
    }
  }
}
```

上面代码首先将连接从活跃连接集合中移除，然后再根据空闲集合是否有空闲空间进行后续处理。如果空闲集合未满，此时复用原连接的字段信息创建新的连接，并将其放入空闲集合中即可。若空闲集合已满，此时无需回收连接，直接关闭即可。pushConnection 方法的逻辑并不复杂，就不多说了。

我们知道获取连接的方法 popConnection 是由 getConnection 方法调用的，那回收连接的方法 pushConnection 是由谁调用的呢？答案是 PooledConnection 中的代理逻辑。相关代码如下：

```java
// PooledConnection.java
@Override
public Object invoke(Object proxy, Method method, Object[] args) throws Throwable {
  String methodName = method.getName();
  if (CLOSE.equals(methodName)) { // 检测 close 方法是否被调用，若被调用则拦截之
    dataSource.pushConnection(this); // 将回收连接中，而不是直接将连接关闭
    return null;
  }
  try {
    if (!Object.class.equals(method.getDeclaringClass())) {
      // issue #579 toString() should never fail
      // throw an SQLException instead of a Runtime
      checkConnection();
    }
    return method.invoke(realConnection, args); // 调用真实连接的目标方法
  } catch (Throwable t) {
    throw ExceptionUtil.unwrapThrowable(t);
  }

}
```

在上一节中，getConnection 方法返回的是 Connection 代理对象，不知道大家有没有注意到。代理对象中的方法被调用时，会被上面的代理逻辑所拦截。如果代理对象的 close 方法被调用，MyBatis 并不会直接调用真实连接的 close 方法关闭连接，而是调用pushConnection 方法回收连接。同时会唤醒处于睡眠中的线程，使其恢复运行，整个过程并不复杂。 

## 4. 本章⼩结

本篇文章对 MyBatis 两种内置数据源进行了较为详细的分析，总的来说，这两种数据源的源码都不是很难理解。大家在阅读源码的过程中，首先应搞懂源码的主要逻辑，然后再去分析一些边边角角的逻辑。不要一开始就陷入各种细节中，容易迷失方向。

## 参考

[MyBatis 源码分析 - 内置数据源](https://www.tianxiaobo.com/2018/08/19/MyBatis-%E6%BA%90%E7%A0%81%E5%88%86%E6%9E%90-%E5%86%85%E7%BD%AE%E6%95%B0%E6%8D%AE%E6%BA%90/)
