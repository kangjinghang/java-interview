在 Web 应用中，缓存是必不可少的组件。通常我们都会用 Redis 或 memcached 等缓存中间件，拦截大量奔向数据库的请求，以减轻数据库压力。作为一个重要的组件，MyBatis 自然也在内部提供了相应的支持。通过在框架层面增加缓存功能，可减轻数据库的压力，同时又可以提升查询速度，可谓一举两得。MyBatis 缓存结构由一级缓存和二级缓存构成，这两级缓存均是使用 Cache 接口的实现类。因此本章将首先会向大家介绍 Cache 几种实现类的源码，然后再分析一级和二级缓存的实现。

## 1. 缓存类介绍

在 MyBatis 中，Cache 是缓存接口，定义了一些基本的缓存操作，所有缓存类都应该实现该接口。 MyBatis 内部提供了丰富的缓存实现类，比如具有基本缓存功能的 PerpetualCache ，具有 LRU 策略的缓存 LruCache ，以及可保证线程安全的缓存 SynchronizedCache 和具备阻塞功能的缓存 BlockingCache 等。除此之外，还有很多缓存实现类，这里就不一一列举了。需要特别说明的是，MyBatis 在实现缓存模块的过程中，使用了装饰模式。在以上几种缓存实现类中， PerpetualCache 相当于装饰模式中的 ConcreteComponent。LruCache、SynchronizedCache 和 BlockingCache 等相当于装饰模式中的 ConcreteDecorator。它们的关系如下：

<img src="http://blog-1259650185.cosbj.myqcloud.com/img/202203/02/1646191024.jpeg" alt="3" style="zoom: 50%;" />

以上对 Cache 接口的实现类进行了简单的介绍，接下来，我们一起深入到源码中，看看这些缓存类的实现。

### 1.1 PerpetualCache

PerpetualCache 是一个具有基本功能的缓存类，内部使用了 HashMap 实现缓存功能。它的源码如下：

```java
public class PerpetualCache implements Cache {

    private final String id;

    private Map<Object, Object> cache = new HashMap<Object, Object>();

    public PerpetualCache(String id) {
        this.id = id;
    }

    
    public String getId() {
        return id;
    }

    
    public int getSize() {
        return cache.size();
    }

    
    public void putObject(Object key, Object value) {
        // 存储键值对到 HashMap
        cache.put(key, value);
    }

    
    public Object getObject(Object key) {
        // 查找缓存项
        return cache.get(key);
    }

    
    public Object removeObject(Object key) {
        // 移除缓存项
        return cache.remove(key);
    }

    
    public void clear() {
        cache.clear();
    }
    
    // 省略部分代码
}
```

上面是 PerpetualCache 的全部代码，很简单。接下来，我们通过装饰类对该类进行装饰，使其功能变的丰富起来。

### 1.2 LruCache

LruCache，顾名思义，是一种具有 LRU 策略的缓存实现类。除此之外，MyBatis 还提供了具有 FIFO 策略的缓存 FifoCache。不过并未提供 LFU 缓存，如果大家有兴趣，可以自行拓展。接下来，我们来看一下 LruCache 的实现。

```java
public class LruCache implements Cache {

    private final Cache delegate;
    private Map<Object, Object> keyMap;
    private Object eldestKey;

    public LruCache(Cache delegate) {
        this.delegate = delegate;
        setSize(1024);
    }
    
    public int getSize() {
        return delegate.getSize();
    }

    public void setSize(final int size) {
        /*
         * 初始化 keyMap，注意，keyMap 的类型继承自 LinkedHashMap，
         * 并覆盖了 removeEldestEntry 方法
         */
        keyMap = new LinkedHashMap<Object, Object>(size, .75F, true) {
            private static final long serialVersionUID = 4267176411845948333L;

            // 覆盖 LinkedHashMap 的 removeEldestEntry 方法
            
            protected boolean removeEldestEntry(Map.Entry<Object, Object> eldest) {
                boolean tooBig = size() > size;
                if (tooBig) {
                    // 获取将要被移除缓存项的键值
                    eldestKey = eldest.getKey();
                }
                return tooBig;
            }
        };
    }
    
    public void putObject(Object key, Object value) {
        // 存储缓存项
        delegate.putObject(key, value);
        cycleKeyList(key);
    }

    public Object getObject(Object key) {
        // 刷新 key 在 keyMap 中的位置
        keyMap.get(key);
        // 从被装饰类中获取相应缓存项
        return delegate.getObject(key);
    }
    
    public Object removeObject(Object key) {
        // 从被装饰类中移除相应的缓存项
        return delegate.removeObject(key);
    }
    
    public void clear() {
        delegate.clear();
        keyMap.clear();
    }

    private void cycleKeyList(Object key) {
        // 存储 key 到 keyMap 中
        keyMap.put(key, key);
        if (eldestKey != null) {
            // 从被装饰类中移除相应的缓存项
            delegate.removeObject(eldestKey);
            eldestKey = null;
        }
    }
    
    // 省略部分代码
}
```

LruCache 的 keyMap 属性是实现 LRU 策略的关键，该属性类型继承自 LinkedHashMap，并覆盖了 removeEldestEntry 方法。LinkedHashMap 可保持键值对的插入顺序，当插入一个新的键值对时，LinkedHashMap 内部的 tail 节点会指向最新插入的节点。head 节点则指向第一个被插入的键值对，也就是最久未被访问的那个键值对。默认情况下，LinkedHashMap 仅维护键值对的插入顺序。若要基于 LinkedHashMap 实现 LRU 缓存，还需通过构造方法将 LinkedHashMap 的 accessOrder 属性设为 true，此时 LinkedHashMap 会维护键值对的访问顺序。比如，上面代码中 getObject 方法中执行了这样一句代码 `keyMap.get(key)` ，目的是刷新 key 对应的键值对在 LinkedHashMap 的位置。LinkedHashMap 会将 key 对应的键值对移动到链表的尾部，尾部节点表示最久刚被访问过或者插入的节点。除了需将 accessOrder 设为 true，还需覆盖 removeEldestEntry 方法。LinkedHashMap 在插入新的键值对时会调用该方法，以决定是否在插入新的键值对后，移除老的键值对。在上面的代码中，当被装饰类的容量超出了 keyMap 的所规定的容量（由构造方法传入）后，keyMap 会移除最长时间未被访问的键，并将该键保存到 eldestKey 中，然后由 cycleKeyList 方法将 eldestKey 传给被装饰类的 removeObject 方法，移除相应的缓存项目。好了，关于 LruCache 就先分析这么多了。

### 1.3 BlockingCache

BlockingCache 实现了阻塞特性，该特性是基于 Java 重入锁实现的。同一时刻下，BlockingCache 仅允许一个线程访问指定 key 的缓存项，其他线程将会被阻塞住。下面我们来看一下 BlockingCache 的源码。

```java
public class BlockingCache implements Cache {

    private long timeout;
    private final Cache delegate;
    private final ConcurrentHashMap<Object, ReentrantLock> locks;

    public BlockingCache(Cache delegate) {
        this.delegate = delegate;
        this.locks = new ConcurrentHashMap<Object, ReentrantLock>();
    }

    
    public void putObject(Object key, Object value) {
        try {
            // 存储缓存项
            delegate.putObject(key, value);
        } finally {
            // 释放锁
            releaseLock(key);
        }
    }

    
    public Object getObject(Object key) {
        // 请求锁
        acquireLock(key);
        Object value = delegate.getObject(key);
        // 若缓存命中，则释放锁。需要注意的是，未命中则不释放锁
        if (value != null) {
            // 释放锁
            releaseLock(key);
        }
        return value;
    }

    
    public Object removeObject(Object key) {
        // 释放锁
        releaseLock(key);
        return null;
    }

    private ReentrantLock getLockForKey(Object key) {
        ReentrantLock lock = new ReentrantLock();
        // 存储 <key, Lock> 键值对到 locks 中
        ReentrantLock previous = locks.putIfAbsent(key, lock);
        return previous == null ? lock : previous;
    }

    private void acquireLock(Object key) {
        Lock lock = getLockForKey(key);
        if (timeout > 0) {
            try {
                // 尝试加锁
                boolean acquired = lock.tryLock(timeout, TimeUnit.MILLISECONDS);
                if (!acquired) {
                    throw new CacheException("...");
                }
            } catch (InterruptedException e) {
                throw new CacheException("...");
            }
        } else {
            // 加锁
            lock.lock();
        }
    }

    private void releaseLock(Object key) {
        // 获取与当前 key 对应的锁
        ReentrantLock lock = locks.get(key);
        if (lock.isHeldByCurrentThread()) {
            // 释放锁
            lock.unlock();
        }
    }
    
    // 省略部分代码
}
```

如上，查询缓存时，getObject 方法会先获取与 key 对应的锁，并加锁。若缓存命中，getObject 方法会释放锁，否则将一直锁定。getObject 方法若返回 null，表示缓存未命中。此时 MyBatis 会进行数据库查询，并调用 putObject 方法存储查询结果。同时，putObject 方法会将指定 key 对应的锁进行解锁，这样被阻塞的线程即可恢复运行。

上面的描述有点啰嗦，倒是 BlockingCache 类的注释说到比较简单明了。这里引用一下：

> It sets a lock over a cache key when the element is not found in cache.
> This way, other threads will wait until this element is filled instead of hitting the database.

这段话的意思是，当指定 key 对应元素不存在于缓存中时，BlockingCache 会根据 lock 进行加锁。此时，其他线程将会进入等待状态，直到与 key 对应的元素被填充到缓存中。而不是让所有线程都去访问数据库。

在上面代码中，removeObject 方法的逻辑很奇怪，仅调用了 releaseLock 方法释放锁，却没有调用被装饰类的 removeObject 方法移除指定缓存项。这样做是为什么呢？大家可以先思考，答案将在分析二级缓存的相关逻辑时揭晓。

## 2. CacheKey

在 MyBatis 中，引入缓存的目的是为提高查询效率，降低数据库压力。既然 MyBatis 引入了缓存，那么大家思考过缓存中的 key 和 value 的值分别是什么吗？大家可能很容易能回答出 value 的内容，不就是 SQL 的查询结果吗。那 key 是什么呢？是字符串，还是其他什么对象？如果是字符串的话，那么大家首先能想到的是用 SQL 语句作为 key。但这是不对的，比如：

```sql
SELECT * FROM author where id > ?
```

id > 1 和 id > 10 查出来的结果可能是不同的，所以我们不能简单的使用 SQL 语句作为 key。从这里可以看出来，运行时参数将会影响查询结果，因此我们的 key 应该涵盖运行时参数。除此之外呢，如果进行分页查询，查询结果也会不同，因此 key 也应该涵盖分页参数。综上，我们不能使用简单的 SQL 语句作为 key。应该考虑使用一种复合对象，能涵盖可影响查询结果的因子。在 MyBatis 中，这种复合对象就是 CacheKey。下面来看一下它的定义。

```java
public class CacheKey implements Cloneable, Serializable {

    private static final int DEFAULT_MULTIPLYER = 37;
    private static final int DEFAULT_HASHCODE = 17;

    // 乘子，默认为37
    private final int multiplier;
    // CacheKey 的 hashCode，综合了各种影响因子
    private int hashcode;
    // 校验和
    private long checksum;
    // 影响因子个数
    private int count;
    // 影响因子集合
    private List<Object> updateList;
    
    public CacheKey() {
        this.hashcode = DEFAULT_HASHCODE;
        this.multiplier = DEFAULT_MULTIPLYER;
        this.count = 0;
        this.updateList = new ArrayList<Object>();
    }
    
    // 省略其他方法
}
```

如上，除了 multiplier 是恒定不变的 ，其他变量将在更新操作中被修改。下面看一下更新操作的代码。

```java
// CacheKey.java
/** 每当执行更新操作时，表示有新的影响因子参与计算 */
public void update(Object object) {
        int baseHashCode = object == null ? 1 : ArrayUtil.hashCode(object);
    // 自增 count
    count++;
    // 计算校验和
    checksum += baseHashCode;
    // 更新 baseHashCode
    baseHashCode *= count;

    // 计算 hashCode
    hashcode = multiplier * hashcode + baseHashCode;

    // 保存影响因子
    updateList.add(object);
}
```

当不断有新的影响因子参与计算时，hashcode 和 checksum 将会变得愈发复杂和随机。这样可降低冲突率，使 CacheKey 可在缓存中更均匀的分布。CacheKey 最终要作为键存入 HashMap，因此它需要覆盖 equals 和 hashCode 方法。下面我们来看一下这两个方法的实现。

```java
// CacheKey.java
public boolean equals(Object object) {
    // 检测是否为同一个对象
    if (this == object) {
        return true;
    }
    // 检测 object 是否为 CacheKey
    if (!(object instanceof CacheKey)) {
        return false;
    }
    final CacheKey cacheKey = (CacheKey) object;

    // 检测 hashCode 是否相等
    if (hashcode != cacheKey.hashcode) {
        return false;
    }
    // 检测校验和是否相同
    if (checksum != cacheKey.checksum) {
        return false;
    }
    // 检测 coutn 是否相同
    if (count != cacheKey.count) {
        return false;
    }

    // 如果上面的检测都通过了，下面分别对每个影响因子进行比较
    for (int i = 0; i < updateList.size(); i++) {
        Object thisObject = updateList.get(i);
        Object thatObject = cacheKey.updateList.get(i);
        if (!ArrayUtil.equals(thisObject, thatObject)) {
            return false;
        }
    }
    return true;
}

public int hashCode() {
    // 返回 hashcode 变量
    return hashcode;
}
```

equals 方法的检测逻辑比较严格，对 CacheKey 中多个成员变量进行了检测，已保证两者相等。hashCode 方法比较简单，返回 hashcode 变量即可。关于 CacheKey 就先分析到这，CacheKey 在一二级缓存中会被用到，接下来还会看到它的身影。

## 3. ⼀级缓存

在进行数据库查询之前，MyBatis 首先会检查以及缓存中是否有相应的记录，若有的话直接返回即可。一级缓存是数据库的最后一道防护，若一级缓存未命中，查询请求将落到数据库上。一级缓存是在 BaseExecutor 被初始化的，下面我们来看一下相关的初始化逻辑：

```java
public abstract class BaseExecutor implements Executor {
	protected PerpetualCache localCache;
    // 省略其他字段
    
    protected BaseExecutor(Configuration configuration, Transaction transaction) {
        this.localCache = new PerpetualCache("LocalCache");
        // 省略其他字段初始化方法
    }
}
```

如上，一级缓存的类型为 PerpetualCache，没有被其他缓存类装饰过。一级缓存所存储从查询结果会在 MyBatis 执行更新操作（INSERT/UPDATE/DELETE），以及提交和回滚事务时被清空。下面我们来看一下访问一级缓存的逻辑。

```java
// BaseExecutor.java
@Override
public <E> List<E> query(MappedStatement ms, Object parameter, RowBounds rowBounds, ResultHandler resultHandler) throws SQLException {
  BoundSql boundSql = ms.getBoundSql(parameter);
  CacheKey key = createCacheKey(ms, parameter, rowBounds, boundSql);  // 创建 CacheKey
  return query(ms, parameter, rowBounds, resultHandler, key, boundSql);
}

@SuppressWarnings("unchecked")
@Override
public <E> List<E> query(MappedStatement ms, Object parameter, RowBounds rowBounds, ResultHandler resultHandler, CacheKey key, BoundSql boundSql) throws SQLException {
  ErrorContext.instance().resource(ms.getResource()).activity("executing a query").object(ms.getId());
  if (closed) {
    throw new ExecutorException("Executor was closed.");
  }
  if (queryStack == 0 && ms.isFlushCacheRequired()) {
    clearLocalCache();
  }
  List<E> list;
  try {
    queryStack++;
    list = resultHandler == null ? (List<E>) localCache.getObject(key) : null; // 从一级缓存中获取缓存项
    if (list != null) {
      handleLocallyCachedOutputParameters(ms, key, parameter, boundSql); // 存储过程相关处理逻辑，本文不分析存储过程，故该方法不分析了
    } else {
      list = queryFromDatabase(ms, parameter, rowBounds, resultHandler, key, boundSql); // 一级缓存未命中，则从数据库中查询
    }
  } finally {
    queryStack--;
  }
  if (queryStack == 0) {
    for (DeferredLoad deferredLoad : deferredLoads) { // 从一级缓存中延迟加载嵌套查询结果
      deferredLoad.load();
    }
    // issue #601
    deferredLoads.clear();
    if (configuration.getLocalCacheScope() == LocalCacheScope.STATEMENT) {
      // issue #482
      clearLocalCache();
    }
  }
  return list;
}
```

如上，在访问一级缓存之前，MyBatis 首先会调用 createCacheKey 方法创建 CacheKey。下面我们来看一下 createCacheKey 方法的逻辑：

```java
// BaseExecutor.java
@Override
public CacheKey createCacheKey(MappedStatement ms, Object parameterObject, RowBounds rowBounds, BoundSql boundSql) {
  if (closed) {
    throw new ExecutorException("Executor was closed.");
  }
  CacheKey cacheKey = new CacheKey(); // 创建 CacheKey 对象
  cacheKey.update(ms.getId()); // 将 MappedStatement 的 id 作为影响因子进行计算
  cacheKey.update(rowBounds.getOffset()); // RowBounds 用于分页查询，下面将它的两个字段作为影响因子进行计算
  cacheKey.update(rowBounds.getLimit());
  cacheKey.update(boundSql.getSql()); // 获取 sql 语句，并进行计算
  List<ParameterMapping> parameterMappings = boundSql.getParameterMappings();
  TypeHandlerRegistry typeHandlerRegistry = ms.getConfiguration().getTypeHandlerRegistry();
  // mimic DefaultParameterHandler logic
  for (ParameterMapping parameterMapping : parameterMappings) {
    if (parameterMapping.getMode() != ParameterMode.OUT) {
      Object value; // 运行时参数
      String propertyName = parameterMapping.getProperty(); // 当前大段代码用于获取 SQL 中的占位符 #{xxx} 对应的运行时参数，前文有类似分析，这里忽略了
      if (boundSql.hasAdditionalParameter(propertyName)) {
        value = boundSql.getAdditionalParameter(propertyName);
      } else if (parameterObject == null) {
        value = null;
      } else if (typeHandlerRegistry.hasTypeHandler(parameterObject.getClass())) {
        value = parameterObject;
      } else {
        MetaObject metaObject = configuration.newMetaObject(parameterObject);
        value = metaObject.getValue(propertyName);
      }
      cacheKey.update(value); // 让运行时参数参与计算
    }
  }
  if (configuration.getEnvironment() != null) {
    // issue #176
    cacheKey.update(configuration.getEnvironment().getId()); // 获取 Environment id 遍历，并让其参与计算
  }
  return cacheKey;
}
```

在计算 CacheKey 的过程中，有很多影响因子参与了计算。比如 MappedStatement 的 id 字段，SQL 语句，分页参数，运行时变量，Environment 的 id 字段等。通过让这些影响因子参与计算，可以很好的区分不同查询请求。所以，我们可以简单的把 CacheKey 看做是一个查询请求的 id。有了 CacheKey，我们就可以使用它读写缓存了。在上面代码中，若一级缓存为命中，BaseExecutor 会调用 queryFromDatabase 查询数据库，并将查询结果写入缓存中。下面看一下 queryFromDatabase 的逻辑。

```java
private <E> List<E> queryFromDatabase(MappedStatement ms, Object parameter, RowBounds rowBounds, ResultHandler resultHandler, CacheKey key, BoundSql boundSql) throws SQLException {
  List<E> list;
  localCache.putObject(key, EXECUTION_PLACEHOLDER); // 向缓存中存储一个占位符
  try {
    list = doQuery(ms, parameter, rowBounds, resultHandler, boundSql); // 调用 doQuery 进行查询
  } finally {
    localCache.removeObject(key); // 移除占位符
  }
  localCache.putObject(key, list); // 缓存查询结果
  if (ms.getStatementType() == StatementType.CALLABLE) { // 存储过程相关逻辑，忽略
    localOutputParameterCache.putObject(key, parameter);
  }
  return list;
}
```

到此，关于一级缓存相关的逻辑就差不多分析完了。一级缓存的逻辑比较简单，大家可以简单过一遍。

## 4. ⼆级缓存

二级缓存构建在一级缓存之上，在收到查询请求时，MyBatis 首先会查询二级缓存。若二级缓存未命中，再去查询一级缓存。与一级缓存不同，二级缓存和具体的命名空间绑定，一级缓存则是和 SqlSession 绑定。在按照 MyBatis 规范使用 SqlSession 的情况下，一级缓存不存在并发问题。二级缓存则不然，二级缓存可在多个命名空间间共享。这种情况下，会存在并发问题，因此需要针对性的去处理。除了并发问题，二级缓存还存在事务问题，相关问题将在接下来进行分析。下面先来看一下访问二级缓存的逻辑。

```java
// CachingExecutor.java
@Override
public <E> List<E> query(MappedStatement ms, Object parameterObject, RowBounds rowBounds, ResultHandler resultHandler) throws SQLException {
  BoundSql boundSql = ms.getBoundSql(parameterObject); // 获取 BoundSql
  CacheKey key = createCacheKey(ms, parameterObject, rowBounds, boundSql); // 创建 CacheKey
  return query(ms, parameterObject, rowBounds, resultHandler, key, boundSql); // 调用重载方法
}

@Override
public <E> List<E> query(MappedStatement ms, Object parameterObject, RowBounds rowBounds, ResultHandler resultHandler, CacheKey key, BoundSql boundSql)
    throws SQLException {
  Cache cache = ms.getCache(); // 从 MappedStatement 中获取缓存，注意这里的 Cache 并非是在 CachingExecutor 中创建的
  if (cache != null) { // 若映射文件中未配置缓存或参照缓存，此时 cache = null
    flushCacheIfRequired(ms);
    if (ms.isUseCache() && resultHandler == null) {
      ensureNoOutParams(ms, boundSql);
      @SuppressWarnings("unchecked")
      List<E> list = (List<E>) tcm.getObject(cache, key); // 访问二级缓存
      if (list == null) { // 若缓存未命中，则调用被装饰类的 query 方法
        list = delegate.query(ms, parameterObject, rowBounds, resultHandler, key, boundSql); // 向一级缓存或者数据库进行查询
        tcm.putObject(cache, key, list); // issue #578 and #116  缓存查询结果
      }
      return list;
    }
  }
  return delegate.query(ms, parameterObject, rowBounds, resultHandler, key, boundSql); // 调用被装饰类的 query 方法
}
```

如上，注意二级缓存是从 MappedStatement 中获取的，而非由 CachingExecutor 创建。由于 MappedStatement 存在于全局配置中，可以多个 CachingExecutor 获取到，这样就会出现线程安全问题。除此之外，若不加以控制，多个事务共用一个缓存实例，会导致脏读问题。线程安全问题可以通过 SynchronizedCache 装饰类解决，该装饰类会在 Cache 实例构造期间被添加上。至于脏读问题，需要借助其他类来处理，也就是上面代码中 tcm 变量对应的类型。下面分析一下。

```java
// TransactionalCacheManager.java
public class TransactionalCacheManager { // 事务缓存管理器

  private final Map<Cache, TransactionalCache> transactionalCaches = new HashMap<>(); // Cache 与 TransactionalCache 的映射关系表

  public void clear(Cache cache) {
    getTransactionalCache(cache).clear(); // 获取 TransactionalCache 对象，并调用该对象的 clear 方法，下同
  }

  public Object getObject(Cache cache, CacheKey key) {
    return getTransactionalCache(cache).getObject(key);
  }

  public void putObject(Cache cache, CacheKey key, Object value) {
    getTransactionalCache(cache).putObject(key, value);
  }

  public void commit() {
    for (TransactionalCache txCache : transactionalCaches.values()) {
      txCache.commit();
    }
  }

  public void rollback() {
    for (TransactionalCache txCache : transactionalCaches.values()) {
      txCache.rollback();
    }
  }

  private TransactionalCache getTransactionalCache(Cache cache) {
    return MapUtil.computeIfAbsent(transactionalCaches, cache, TransactionalCache::new); // 从映射表中获取 TransactionalCache，TransactionalCache 也是一种装饰类，为 Cache 增加事务功能
  }

}
```

TransactionalCacheManager 内部维护了 Cache 实例与 TransactionalCache 实例间的映射关系，该类也仅负责维护两者的映射关系，真正做事的还是 TransactionalCache。TransactionalCache 是一种缓存装饰器，可以为 Cache 实例增加事务功能。我在之前提到的脏读问题正是由该类进行处理的。下面分析一下该类的逻辑。

```java
public class TransactionalCache implements Cache {

  private static final Log log = LogFactory.getLog(TransactionalCache.class);

  private final Cache delegate;
  private boolean clearOnCommit;
  private final Map<Object, Object> entriesToAddOnCommit; // 在事务被提交前，所有从数据库中查询的结果将缓存在此集合中
  private final Set<Object> entriesMissedInCache; // 在事务被提交前，当缓存未命中时，CacheKey 将会被存储在此集合中

  public TransactionalCache(Cache delegate) {
    this.delegate = delegate;
    this.clearOnCommit = false;
    this.entriesToAddOnCommit = new HashMap<>();
    this.entriesMissedInCache = new HashSet<>();
  }

  @Override
  public String getId() {
    return delegate.getId();
  }

  @Override
  public int getSize() {
    return delegate.getSize();
  }

  @Override
  public Object getObject(Object key) {
    // issue #116
    Object object = delegate.getObject(key); // 查询 delegate 所代表的缓存
    if (object == null) {
      entriesMissedInCache.add(key); // 缓存未命中，则将 key 存入到 entriesMissedInCache 中
    }
    // issue #146
    if (clearOnCommit) {
      return null;
    } else {
      return object;
    }
  }

  @Override
  public void putObject(Object key, Object object) {
    entriesToAddOnCommit.put(key, object); // 将键值对存入到 entriesToAddOnCommit 中，而非 delegate 缓存中
  }

  @Override
  public Object removeObject(Object key) {
    return null;
  }

  @Override
  public void clear() {
    clearOnCommit = true;
    entriesToAddOnCommit.clear(); // 清空 entriesToAddOnCommit，但不清空 delegate 缓存
  }

  public void commit() {
    if (clearOnCommit) { // 根据 clearOnCommit 的值决定是否清空 delegate
      delegate.clear();
    }
    flushPendingEntries(); // 刷新未缓存的结果到 delegate 缓存中
    reset(); // 重置 entriesToAddOnCommit 和 entriesMissedInCache
  }

  public void rollback() {
    unlockMissedEntries();
    reset();
  }

  private void reset() {
    clearOnCommit = false;
    entriesToAddOnCommit.clear(); // 清空集合
    entriesMissedInCache.clear();
  }

  private void flushPendingEntries() {
    for (Map.Entry<Object, Object> entry : entriesToAddOnCommit.entrySet()) { // 将 entriesToAddOnCommit 中的内容转存到 delegate 中
      delegate.putObject(entry.getKey(), entry.getValue());
    }
    for (Object entry : entriesMissedInCache) {
      if (!entriesToAddOnCommit.containsKey(entry)) {
        delegate.putObject(entry, null); // 存入空值
      }
    }
  }

  private void unlockMissedEntries() {
    for (Object entry : entriesMissedInCache) {
      try {
        delegate.removeObject(entry); // 调用 removeObject 进行解锁
      } catch (Exception e) {
        log.warn("Unexpected exception while notifying a rollback to the cache adapter. "
            + "Consider upgrading your cache adapter to the latest version. Cause: " + e);
      }
    }
  }

}
```

在 TransactionalCache 的代码中，我们要重点关注 entriesToAddOnCommit 集合，TransactionalCache 中的很多方法都会与这个集合打交道。该集合用于存储从查询的结果，那为什么要将结果保存在该集合中，而非 delegate 所表示的缓存中呢？主要是因为直接存到 delegate 会导致脏数据问题。下面通过一张图演示一下脏数据问题发生的过程，假设两个线程开启两个不同的事务，它们的执行过程如下：

![4](http://blog-1259650185.cosbj.myqcloud.com/img/202203/03/1646310741.jpeg)

如上图，时刻 2，事务 A 对记录 A 进行了更新。时刻 3，事务 A 从数据库查询记录A，并将记录 A 写入缓存中。时刻 4，事务 B 查询记录 A，由于缓存中存在记录 A，事务 B 直接从缓存中取数据。这个时候，脏数据问题就发生了。事务 B 在事务 A 未提交情况下，读取到了事务 A 所修改的记录。为了解决这个问题，我们可以为每个事务引入一个独立的缓存。查询数据时，仍从 delegate 缓存（以下统称为共享缓存）中查询。若缓存未命中，则查询数据库。存储查询结果时，并不直接存储查询结果到共享缓存中，而是先存储到事务缓存中，也就是 entriesToAddOnCommit 集合。当事务提交时，再将事务缓存中的缓存项转存到共享缓存中。这样，事务 B 只能在事务 A 提交后，才能读取到事务 A 所做的修改，解决了脏读问题。整个过程大致如下：

![5](http://blog-1259650185.cosbj.myqcloud.com/img/202203/03/1646310878.jpeg)

如上，时刻 2，事务 A 和 B 同时查询记录 A。此时共享缓存中还没没有数据，所以两个事务均会向数据库发起查询请求，并将查询结果存储到各自的事务缓存中。时刻 3，事务A 更新记录 A，这里把更新后的记录 A 记为 A′。时刻 4，两个事务再次进行查询。此时，事务 A 读取到的记录为修改后的值，而事务 B 读取到的记录仍为原值。时刻 5，事务 A 被提交，并将事务缓存 A 中的内容转存到共享缓存中。时刻 6，事务 B 再次查询记录 A，由于共享缓存中有相应的数据，所以直接取缓存数据即可。因此得到记录 A′，而非记录 A。但由于事务 A 已经提交，所以事务 B 读取到的记录 A′ 并非是脏数据。MyBatis 引入事务缓存解决了脏读问题，事务间只能读取到其他事务提交后的内容，这相当于事务隔离级别中的“读已提交（Read Committed）”。但需要注意的时，**MyBatis 缓存事务机制只能解决脏读问题**，并不能解决“不可重复读”问题。再回到上图，事务 B 在被提交前进行了三次查询。前两次查询得到的结果为记录 A，最后一次查询得到的结果为 A′。最有一次的查询结果与前两次不同，这就会导致“不可重复读”的问题。MyBatis 的缓存事务机制最高只支持“读已提交”，并不能解决“不可重复读”问题。即使数据库使用了更高的隔离级别解决了这个问题，但因 MyBatis 缓存事务机制级别较低。此时仍然会导致“不可重复读”问题的发生，这个在日常开发中需要注意一下。下面写点测试代码验证 MyBatis 所导致的“不可重复读”问题，首先看一下实体类：

```java
public class Student {
    private Integer id;
    private String name;
    private Integer age;
    
    // 省略 getter/setter
}
```

对应的数据表如下：

```java
       student
+----+----------+------+
| id | name     | age  |
+----+----------+------+
|  1 | coolblog |   20 |
+----+----------+------+
```

Dao 接口与映射文件定义如下：

```java
public interface StudentDao {
    Student findOne(@Param("id") Integer id);
    int update(@Param("id") Integer id, @Param("id") String name);
}
```

```xml
<mapper namespace="xyz.coolblog.dao.StudentDao">

    <!-- 注意要在映射文件中配置缓存 -->
    <cache/>

    <select id="findOne" resultType="xyz.coolblog.model.Student">
        SELECT
            `id`, `name`, `age`
        FROM
            student
        WHERE
            id = #{id}
    </select>

    <update id="update">
        UPDATE
            student
        SET
            `name` = #{name}
        WHERE
            id = #{id}
    </update>
</mapper>
```

测试代码如下：

```java
public class TransactionalCacheTest {

    private SqlSessionFactory sqlSessionFactory;

    private CountDownLatch countDownLatch = new CountDownLatch(1);

    @Before
    public void prepare() throws IOException {
        String resource = "chapter6/mybatis-config.xml";
        InputStream inputStream = Resources.getResourceAsStream(resource);
        sqlSessionFactory = new SqlSessionFactoryBuilder().build(inputStream);
        inputStream.close();
    }

    @Test
    public void testTransactional() throws Exception {
        ExecutorService es = Executors.newFixedThreadPool(2);
        Future<String> fa = es.submit(this::transactionalA);
        Future<String> fb = es.submit(this::transactionalB);

        countDownLatch.countDown();
        es.awaitTermination(6, TimeUnit.SECONDS);

        System.out.println(fa.get());
        System.out.println("\n -------- 分割线 ------- \n");
        System.out.println(fb.get());

        System.out.println();
        System.out.println();
        System.out.println();
    }

    private String transactionalA() throws Exception {
        SqlSession sqlSession = sqlSessionFactory.openSession();
        StudentDao studentDao = sqlSession.getMapper(StudentDao.class);
        countDownLatch.await();

        StringBuilder sb = new StringBuilder();
        sb.append("时刻1：开启事务 A\n");
        sb.append("时刻2：查询记录 A\n");

        Student s1 = studentDao.findOne(1);
        sb.append(s1).append("\n");

        sb.append("时刻3：更新记录 A\n");
        studentDao.update(1, "tianxiaobo");
        sb.append("时刻4：查询记录 A'\n");
        Student s2 = studentDao.findOne(1);
        sb.append(s2).append("\n");

        Thread.sleep(1000);

        sb.append("时刻5：提交事务 A");
        sqlSession.commit();

        return sb.toString();
    }

    private String transactionalB() throws Exception {
        SqlSession sqlSession = sqlSessionFactory.openSession();
        StudentDao studentDao = sqlSession.getMapper(StudentDao.class);
        countDownLatch.await();

        StringBuilder sb = new StringBuilder();
        sb.append("时刻1：开启事务 B\n");
        sb.append("时刻2：查询数据 A\n");
        Student s1 = studentDao.findOne(1);
        sb.append(s1).append("\n");

        sb.append("时刻3：---------\n");
        sb.append("时刻4：查询数据 A\n");
        Student s2 = studentDao.findOne(1);
        sb.append(s2).append("\n");

        Thread.sleep(3000);

        sb.append("时刻5：---------\n");
        sb.append("时刻6：查询数据 A'\n");
        Student s3 = studentDao.findOne(1);
        sb.append(s3).append("\n");

        sb.append("时刻7：提交事务 B");
        sqlSession.commit();
        return sb.toString();
    }
}
```

最后对输出结果进行简单的美化，如下：

<img src="http://blog-1259650185.cosbj.myqcloud.com/img/202203/03/1646311418.jpeg" alt="6" style="zoom: 50%;" />

如上图，事务 B 在时刻 2 和时刻 4 读取到的记录与数据库中的记录一致，表示可重复读。但当事务 A 提交后，事务 B 在时刻 6 读取到的数据则是事务 A 修改的内容，这个时候就出现了“不可重复读”问题。以上测试是基于 MySql 数据可读，MySQL 默认事务级别为“可重复读”。

<img src="http://blog-1259650185.cosbj.myqcloud.com/img/202203/03/1646312060.jpeg" alt="8" style="zoom: 50%;" />

下面在本地开启两个 MySQL 客户端，模拟上面的执行流程。最终结果如下：

<img src="http://blog-1259650185.cosbj.myqcloud.com/img/202203/03/1646312010.jpeg" alt="7" style="zoom: 50%;" />

从测试结果可以看出，不可重复读问题并未发生，事务 B 三次查询结果均相同。到此，关于 MyBatis 二级缓存所引发的问题就分析完了。

接下来，我们再来看一下 entriesMissedInCache 集合，这个集合是用于存储未命中缓存的查询请求所对应的 CacheKey。单独分析与 entriesMissedInCache 相关的逻辑没什么意义，要搞清 entriesMissedInCache 的实际用途，需要把它和 BlockingCache 的逻辑结合起来进行分析。在 BlockingCache，同一时刻仅允许一个线程通过 getObject 方法查询指定 key 对应的缓存项。如果缓存未命中，getObject 方法不会释放锁，导致其他线程被阻塞住。其他线程要想恢复运行，必须进行解锁，解锁逻辑由 BlockingCache 的 putObject 和 removeObject 方法执行。其中 putObject 会在 TransactionalCache 的 flushPendingEntries方法中被调用，removeObject 方法则由 TransactionalCache 的 unlockMissedEntries 方法调用。flushPendingEntries 和 unlockMissedEntries 最终都会遍历 entriesMissedInCache 集合，并将集合元素传给 BlockingCache 的相关方法。这样可以解开指定 key 对应的锁，让阻塞线程恢复运行。

## 5. 本章⼩结

本章对一些缓存类、CacheKey，以及一二级缓存的实现进行了深入的分析。其中，缓存类和 CacheKey 的实现比较简单。在一二级缓存中，一级缓存的实现相对简单，二级缓存则要复杂一些。二级缓存涉及到线程安全，事务等问题。线程安全问题比较好解决，由并发所导致的事务问题处理起来则要麻烦一些。MyBatis 二级缓存的事务级别比较低，这一点需要大家注意一下。

## 参考

[MyBatis 源码分析 - 缓存原理](https://www.tianxiaobo.com/2018/08/25/MyBatis-%E6%BA%90%E7%A0%81%E5%88%86%E6%9E%90-%E7%BC%93%E5%AD%98%E5%8E%9F%E7%90%86/)
