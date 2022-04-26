## 1. 基本用法

Guava Cache是一款非常优秀的本地缓存框架，使用起来非常灵活，功能也十分强大。Guava Cache说简单点就是一个支持LRU的ConcurrentHashMap，并提供了基于容量，时间和引用的缓存回收方式。

Guava Cache 通过简单好用的 Client 可以快速构造出符合需求的 Cache 对象，不需要过多复杂的配置，大多数情况就像构造一个 POJO 一样的简单。Guava Cache提供了非常友好的基于Builder构建者模式的构造器，用户只需要根据需求设置好各种参数即可使用。Guava Cache提供了两种方式创建一个Cache。这里介绍两种构造 Cache 对象的方式：`CacheLoader` 和 `Callable`。

### 1.1 CacheLoader

CacheLoader可以理解为一个固定的加载器，构造 LoadingCache 的关键在于实现 load 方法，也就是在需要**访问的缓存项不存在的时候 Cache 会自动调用 load 方法将数据加载到 Cache** **中**。这里你肯定会想假如有多个线程过来访问这个不存在的缓存项怎么办，也就是缓存的并发问题如何怎么处理是否需要人工介入，这些在下文中也会介绍到。

除了实现 load 方法之外还可以配置缓存相关的一些性质，比如过期加载策略、刷新策略 。

```java

private static final LoadingCache<String, String> CACHE = CacheBuilder
    .newBuilder()
    // 最大容量为 100 超过容量有对应的淘汰机制，下文详述
    .maximumSize(100)
    // 缓存项写入后多久过期，下文详述
    .expireAfterWrite(60 * 5, TimeUnit.SECONDS)
    // 缓存写入后多久自动刷新一次，下文详述
    .refreshAfterWrite(60, TimeUnit.SECONDS)
    //key使用弱引用-WeakReference
    .weakKeys()
    //当Entry被移除时的监听器
    .removalListener(notification -> log.info("notification={}", GsonUtil.toJson(notification)))
    // 创建一个 CacheLoader，load 表示缓存不存在的时候加载到缓存并返回
    .build(new CacheLoader<String, String>() {
        // 加载缓存数据的方法
        @Override
        public String load(String key) {
            return "cache [" + key + "]";
        }
    });

public void getTest() throws Exception {
    CACHE.get("KEY_25487");
}
```

### 1.2 Callable

在上面的build方法中是可以不用创建CacheLoader的，不管有没有CacheLoader，都是支持Callable的。除了在构造 Cache 对象的时候指定 load 方法来加载缓存外，我们亦可以在**获取缓存项时指定载入缓存的方法**，并且可以根据使用场景在不同的位置采用不同的加载方式。

比如在某些位置可以通过二级缓存加载不存在的缓存项，而有些位置则可以直接从 DB 加载缓存项。

```java
// 注意返回值是 Cache
private static final Cache<String, String> SIMPLE_CACHE = CacheBuilder
    .newBuilder()
    .build();

public void getTest1() throws Exception {
    String key = "KEY_25487";
    // get 缓存项的时候指定 callable 加载缓存项
    SIMPLE_CACHE.get(key, () -> "cache [" + key + "]");
}
```
### 1.3 其他用法

显式插入：

支持loadingCache.put(key, value)方法直接覆盖key的值。

显式失效：

支持loadingCache.invalidate(key) 或 loadingCache.invalidateAll() 方法，手动使缓存失效。

------

## 2. 缓存项加载机制

如果某个缓存过期了或者缓存项不存在于缓存中，而恰巧此此时有大量请求过来请求这个缓存项，如果没有保护机制就会导致**大量的线程同时请求数据源加载数据并生成缓存项，这就是所谓的 “缓存击穿”** 。

举个简单的例子，某个时刻有 100 个请求同时请求 KEY_25487 这个缓存项，而不巧这个缓存项刚好失效了，那么这 100 个线程（如果有这么多机器和流量的话）就会同时从 DB 加载这个数据，很可怕的点在于就算某一个线程率先获取到数据生成了缓存项，**其他的线程还是继续请求 DB 而不会走到缓存**。

<img src="http://blog-1259650185.cosbj.myqcloud.com/img/202204/15/1650006189.png" alt="缓存击穿" style="zoom:50%;" />

看到上面这个图或许你已经有方法解这个问题了，如果多个线程过来如果**我们只让一个线程去加载数据生成缓存项，其他线程等待然后读取生成好的缓存项**岂不是就完美解决。那么恭喜你在这个问题上，和 Google 工程师的思路是一致的。不过采用这个方案，问题是解了但没有完全解，后面会说到它的缺陷。

其实 Guava Cache 在 load 的时候做了并发控制，在多个线程请求一个不存在或者过期的缓存项时保证只有一个线程进入 load 方法，其他线程等待直到缓存项被生成，这样就避免了大量的线程击穿缓存直达 DB 。不过试想下如果有上万 QPS 同时过来会有**大量的线程阻塞导致线程无法释放，甚至会出现线程池满的尴尬场景，这也是说为什么这个方案解了 “缓存击穿” 问题但又没完全解**。

上述机制其实就是 expireAfterWrite/expireAfterAccess 来控制的，这两个配置的区别前者记录写入时间，后者记录写入或访问时间，内部分别用writeQueue和accessQueue维护。如果你配置了过期策略对应的缓存项在过期后被访问就会走上述流程来加载缓存项。

------

## 3. 缓存项刷新机制

缓存项的刷新和加载看起来是相似的，都是让缓存数据处于最新的状态。区别在于：

1. **缓存项加载是一个被动**的过程，而**缓存刷新是一个主动触发**动作。如果缓存项不存在或者过期只有下次 get 的时候才会触发新值加载。而缓存刷新则更加主动替换缓存中的老值。
2. 另外一个很重要点的在于，**缓存刷新的项目一定是存在缓存中**的，他是对老值的替换而非是对 NULL 值的替换。

由于缓存项刷新的前提是该缓存项存在于缓存中，那么缓存的刷新就不用像缓存加载的流程一样让其他线程等待而是允许一个线程去数据源获取数据，**其他线程都先返回老值直到异步线程生成了新缓存项**。

这个方案完美解决了上述遇到的 “缓存击穿” 问题，不过**他的前提是已经生成缓存项了**。在实际生产情况下我们可以做**缓存预热** ，提前生成缓存项，避免流量洪峰造成的线程堆积。

这套机制在 Guava Cache 中是通过 refreshAfterWrite 实现的，在配置刷新策略后，对应的缓存项会按照设定的时间定时刷新，避免线程阻塞的同时保证缓存项处于最新状态。

但他也不是完美的，比如他的限制是缓存项已经生成，并且**如果恰巧你运气不好，大量的缓存项同时需要刷新或者过期， 就会有大量的线程请求 DB，这就是常说的 “缓存雪崩”**。

------

## 4. 缓存项异步刷新机制

上面说到缓存项大面积失效或者刷新会导致雪崩，那么就只能限制访问 DB 的数量了，位置有三个地方：

1. 源头：因为加载缓存的线程就是前台请求线程，所以如果**控制请求线程数量**的确是减少大面积失效对 DB 的请求，那这样一来就不存在高并发请求，就算不用缓存都可以。
2. 中间层缓冲：因为请求线程和访问 DB 的线程是同一个，假如在**中间加一层缓冲，通过一个后台线程池去异步刷新缓存**所有请求线程直接返回老值，这样对于 DB 的访问的流量就可以被后台线程池的池大小控住。
3. 底层：直接**控 DB 连接池的池大小**，这样访问 DB 的连接数自然就少了，但是如果大量请求到连接池发现获取不到连接程序一样会出现连接池满的问题，会有大量连接被拒绝的异常。

所以比较合适的方式是通过添加一个异步线程池异步刷新数据，在 **Guava Cache 中实现方案是重写 CacheLoader 的 reload 方法**。

PS：只有重写了 reload 方法才有“异步加载”的效果。默认的 reload 方法就是同步去执行 load 方法。

```java
private static final LoadingCache<String, String> ASYNC_CACHE = CacheBuilder.newBuilder()
    .build(
    CacheLoader.asyncReloading(new CacheLoader<String, String>() {
        @Override
        public String load(String key) {
            return key;
        }

        @Override
        public ListenableFuture<String> reload(String key, String oldValue) throws Exception {
            return super.reload(key, oldValue);
        }
    }, new ThreadPoolExecutor(5, Integer.MAX_VALUE,
                              60L, TimeUnit.SECONDS,
                              new SynchronousQueue<>()))
);
```

大家都应该对各个失效/刷新机制有一定的理解，清楚在各个场景可以使用哪个配置，简单总结一下：

expireAfterWrite 是允许一个线程进去load方法，其他线程阻塞等待。

refreshAfterWrite 是允许一个线程进去load方法，其他线程返回旧的值。

在上一点基础上做成异步，即回源线程不是请求线程。异步刷新是用线程异步加载数据，期间所有请求返回旧的缓存值。

------

## 5. LocalCache数据结构

Guava Cache的数据结构跟JDK1.7的ConcurrentHashMap类似，如下图所示：

<img src="http://blog-1259650185.cosbj.myqcloud.com/img/202204/16/1650071570.png" alt="图片" style="zoom:67%;" />

需要说明的是：

- 每一个Segment中的有效队列（废弃队列不算）的个数最多可能不止一个
- 上图与ConcurrentHashMap及其类似，其中的ReferenceEntry[i]用于存放key-value
- 每一个ReferenceEntry[i]都会存放一个链表，当然采用的也是Entry替换的方式。
- 队列用于实现LRU缓存回收算法
- 多个Segment之间互不打扰，可以并发执行
- 各个Segment的扩容只需要扩自己的就好，与其他Segment无关
- 根据需要设置好初始化容量与并发水平参数，可以有效避免扩容带来的昂贵代价，但是设置的太大了，又会耗费很多内存，要衡量好

后边三条与ConcurrentHashMap一样。

**guava cache的数据结构的构建流程：**

1）构建CacheBuilder实例cacheBuilder

2）cacheBuilder实例指定缓存器LocalCache的初始化参数

3）cacheBuilder实例使用build()方法创建LocalCache实例（简单说成这样，实际上复杂一些）

3.1）首先为各个类变量赋值（通过第二步中cacheBuilder指定的初始化参数以及原本就定义好的一堆常量）

3.2）之后创建Segment数组

3.3）最后初始化每一个Segment[i]

3.3.1）为Segment属性赋值

3.3.2）初始化Segment中的table，即一个ReferenceEntry数组（每一个key-value就是一个ReferenceEntry）

3.3.3）根据之前类变量的赋值情况，创建相应队列，用于LRU缓存回收算法

### 5.1 LoadingCache

LoadingCache即是我们API Builder返回的类型，类继承图如下：

<img src="http://blog-1259650185.cosbj.myqcloud.com/img/202204/15/1650010282.jpeg" alt="图片" style="zoom:67%;" />

### 5.2 LocalCache

LoadingCache这些类表示获取Cache的方式，可以有多种方式，但是它们的方法最终调用到LocalCache的方法，LocalCache是Guava Cache的核心类。看看LocalCache的定义：

```java
@SuppressWarnings("GoodTime") // lots of violations (nanosecond math)
@GwtCompatible(emulated = true)
class LocalCache<K, V> extends AbstractMap<K, V> implements ConcurrentMap<K, V> {
```

通过这个继承关系可以看出 Guava Cache 的本质就是 ConcurrentMap。

LocalCache的重要属性：

```java
 // Map的数组
 final Segment<K, V>[] segments;
 // 并发量，即segments数组的大小
 final int concurrencyLevel;
 // key的比较策略，跟key的引用类型有关
 final Equivalence<Object> keyEquivalence;
 // value的比较策略，跟value的引用类型有关
 final Equivalence<Object> valueEquivalence;
 // key的强度，即引用类型的强弱
 final Strength keyStrength;
 // value的强度，即引用类型的强弱
 final Strength valueStrength;
 // 访问后的过期时间，设置了expireAfterAccess就有
 final long expireAfterAccessNanos;
 // 写入后的过期时间，设置了expireAfterWrite就有
 final long expireAfterWriteNa就有nos;
 // 刷新时间，设置了refreshAfterWrite就有
 final long refreshNanos;
 // removal的事件队列，缓存过期后先放到该队列
 final Queue<RemovalNotification<K, V>> removalNotificationQueue;
 // 设置的removalListener
 final RemovalListener<K, V> removalListener;
 // 时间器
 final Ticker ticker;
 // 创建Entry的工厂，根据引用类型不同
 final EntryFactory entryFactory;
```

### 5.3 Segment

从上面可以看出LocalCache这个Map就是维护一个Segment数组。Segment是一个ReentrantLock

```java
static class Segment<K, V> extends ReentrantLock
```

看看Segment的重要属性：

```java
// LocalCache
final LocalCache<K, V> map;
// segment存放元素的数量
volatile int count;
// 修改、更新的数量，用来做弱一致性
int modCount;
// 扩容用
int threshold;
// segment维护的数组，用来存放Entry。这里使用AtomicReferenceArray是因为要用CAS来保证原子性
volatile @MonotonicNonNull AtomicReferenceArray<ReferenceEntry<K, V>> table;
// 如果key是弱引用的话，那么被GC回收后，就会放到ReferenceQueue，要根据这个queue做一些清理工作
final @Nullable ReferenceQueue<K> keyReferenceQueue;
// 如果value是弱引用的话，那么被GC回收后，就会放到ReferenceQueue，要根据这个queue做一些清理工作
final @Nullable ReferenceQueue<V> valueReferenceQueue;
// 如果一个元素新写入，则会记到这个队列的尾部，用来做expire
@GuardedBy("this")
final Queue<ReferenceEntry<K, V>> writeQueue;
// 读、写都会放到这个队列，用来进行LRU替换算法
@GuardedBy("this")
final Queue<ReferenceEntry<K, V>> accessQueue;
// 记录哪些entry被访问，用于accessQueue的更新
final Queue<ReferenceEntry<K, V>> recencyQueue;
```

### 5.4 ReferenceEntry

ReferenceEntry就是一个Entry的引用，有几种引用类型：

<img src="http://blog-1259650185.cosbj.myqcloud.com/img/202204/16/1650073015.png" alt="图片" style="zoom: 67%;" />

我们拿StrongEntry为例，看看有哪些属性：

```java
final K key;
final int hash;
// 指向下一个Entry，说明这里用的链表（从上图可以看出）
final @Nullable ReferenceEntry<K, V> next;
// value
volatile ValueReference<K, V> valueReference = unset();
```

------

## 6. LocalCache 源码分析

在看源码之前先理一下流程，先理清思路。如果想直接看源码理解流程可以先跳过这张图 ~

<img src="http://blog-1259650185.cosbj.myqcloud.com/img/202204/15/1650010463.png" alt="图片" style="zoom: 67%;" />

### 5.1 get

#### 5.1.1 get主流程

我们从LoadingCache的get(key)方法入手：

```java
// LocalLoadingCache的get方法，直接调用LocalCache
@Override
public V get(K key) throws ExecutionException {
  return localCache.getOrLoad(key);
}
```

LocalCache：

```java
V getOrLoad(K key) throws ExecutionException {
  return get(key, defaultLoader);
}

V get(K key, CacheLoader<? super K, V> loader) throws ExecutionException {
    int hash = hash(checkNotNull(key)); // 根据key获取hash值
    // 根据 hash 获取对应的 segment 然后从 segment 的get方法获取具体值
    return segmentFor(hash).get(key, hash, loader);
}
```

Segment：

```java
V get(K key, int hash, CacheLoader<? super K, V> loader) throws ExecutionException {
    checkNotNull(key);
    checkNotNull(loader);
    try {
        // count 表示在这个 segment 中存活的项目个数，这里是进行快速判断，如果count != 0则说明已经有数据
        if (count != 0) {
            // 定位到 segment 中的第一个 Entry (ReferenceEntry) 包含正在 load 的数据
            ReferenceEntry<K, V> e = getEntry(key, hash);
            if (e != null) {
                long now = map.ticker.read();
                // // 获取缓存值，如果 ReferenceEntry 是 invalid, partially-collected, loading 或 expired 状态的话会返回 null，同时检查是否过期了，过期移除并返回 null
                V value = getLiveValue(e, now);
                if (value != null) { // 说明 ReferenceEntry 还没过期
                    // 记录访问时间
                    recordRead(e, now);
                    // 记录缓存命中一次
                    statsCounter.recordHits(1);
                    // 判断是否需要刷新，如果需要刷新，那么会去异步刷新，且返回旧值
                    return scheduleRefresh(e, key, hash, value, now, loader);
                }
                ValueReference<K, V> valueReference = e.getValueReference();
                // 如果 ReferenceEntry 过期了并且 LoadingValueReference 在 loading，则等待直到加载完成
                if (valueReference.isLoading()) {
                    return waitForLoadingValue(e, key, valueReference);
                }
            }
        }

        // 走到这说明从来没写入过值 或者 值为 null 或者 过期（数据还没做清理），后面展开
        return lockedGetOrLoad(key, hash, loader);
    } catch (ExecutionException ee) {
        Throwable cause = ee.getCause();
        if (cause instanceof Error) {
            throw new ExecutionError((Error) cause);
        } else if (cause instanceof RuntimeException) {
            throw new UncheckedExecutionException(cause);
        }
        throw ee;
    } finally {
        postReadCleanup();
    }
}

V getLiveValue(ReferenceEntry<K, V> entry, long now) {
  if (entry.getKey() == null) { // 被GC回收了
    tryDrainReferenceQueues();
    return null;
  }
  V value = entry.getValueReference().get();
  if (value == null) { // 被GC回收了
    tryDrainReferenceQueues();
    return null;
  }

  if (map.isExpired(entry, now)) { // 判断是否过期
    tryExpireEntries(now);
    return null;
  }
  return value;
}

boolean isExpired(ReferenceEntry<K, V> entry, long now) {
  checkNotNull(entry);
  if (expiresAfterAccess() && (now - entry.getAccessTime() >= expireAfterAccessNanos)) { // 如果配置了 expireAfterAccess，用当前时间跟 entry 的 accessTime 比较
    return true;
  }
  if (expiresAfterWrite() && (now - entry.getWriteTime() >= expireAfterWriteNanos)) { // 如果配置了 expireAfterWrite，用当前时间跟 entry 的 writeTime 比较
    return true;
  }
  return false;
}

void tryExpireEntries(long now) {
  if (tryLock()) {
    try {
      expireEntries(now);
    } finally {
      unlock();
      // don't call postWriteCleanup as we're in a read
    }
  }
}

@GuardedBy("this")
void expireEntries(long now) {
  drainRecencyQueue();

  ReferenceEntry<K, V> e;
  while ((e = writeQueue.peek()) != null && map.isExpired(e, now)) {
    if (!removeEntry(e, e.getHash(), RemovalCause.EXPIRED)) { // 尝试进行过期删除
      throw new AssertionError();
    }
  }
  while ((e = accessQueue.peek()) != null && map.isExpired(e, now)) {
    if (!removeEntry(e, e.getHash(), RemovalCause.EXPIRED)) { // 尝试进行过期删除
      throw new AssertionError();
    }
  }
}

@VisibleForTesting
@GuardedBy("this")
boolean removeEntry(ReferenceEntry<K, V> entry, int hash, RemovalCause cause) {
  int newCount = this.count - 1; // 获取当前缓存的总数量，自减一
  AtomicReferenceArray<ReferenceEntry<K, V>> table = this.table;
  int index = hash & (table.length() - 1);
  ReferenceEntry<K, V> first = table.get(index);

  for (ReferenceEntry<K, V> e = first; e != null; e = e.getNext()) {
    if (e == entry) {
      ++modCount;
      ReferenceEntry<K, V> newFirst =
          removeValueFromChain(
              first,
              e,
              e.getKey(),
              hash,
              e.getValueReference().get(),
              e.getValueReference(),
              cause);
      newCount = this.count - 1; // 删除并将更新的总数赋值到 count
      table.set(index, newFirst);
      this.count = newCount; // write-volatile
      return true;
    }
  }

  return false;
}

@Nullable
ReferenceEntry<K, V> removeValueFromChain(
    ReferenceEntry<K, V> first,
    ReferenceEntry<K, V> entry,
    @Nullable K key,
    int hash,
    V value,
    ValueReference<K, V> valueReference,
    RemovalCause cause) {
  enqueueNotification(key, hash, value, valueReference.getWeight(), cause); // 会将回收的缓存（包含了 key，value）以及回收原因包装成之前定义的事件接口加入到一个本地队列中
  writeQueue.remove(entry);
  accessQueue.remove(entry);

  if (valueReference.isLoading()) {
    valueReference.notifyNewValue(null);
    return first;
  } else {
    return removeEntryFromChain(first, entry);
  }
}

@GuardedBy("this")
void enqueueNotification(
    @Nullable K key, int hash, @Nullable V value, int weight, RemovalCause cause) {
  totalWeight -= weight;
  if (cause.wasEvicted()) {
    statsCounter.recordEviction();
  }
  if (map.removalNotificationQueue != DISCARDING_QUEUE) {
    RemovalNotification<K, V> notification = RemovalNotification.create(key, value, cause);
    map.removalNotificationQueue.offer(notification); // 添加到 removalNotificationQueue;
  }
}
```

Guava 并没有按照之前猜想的另起一个线程来维护过期数据。

应该是以下原因：

- 新起线程需要资源消耗。
- 维护过期数据还要获取额外的锁，增加了消耗。

而在查询时候顺带做了这些事情，但是如果该缓存迟迟没有访问也会存在数据不能被回收的情况，不过这对于一个高吞吐的应用来说也不是问题。

#### 5.1.2 Segment#scheduleRefresh

从get的流程得知，如果entry还没过期，则会进入此方法，尝试去刷新数据。

```java
// com.google.common.cache.LocalCache.Segment#scheduleRefresh

V scheduleRefresh(
    ReferenceEntry<K, V> entry,
    K key,
    int hash,
    V oldValue,
    long now,
    CacheLoader<? super K, V> loader) {
    
    if (
        // 配置了刷新策略 refreshAfterWrite
        map.refreshes()
        // 到刷新时间了
        && (now - entry.getWriteTime() > map.refreshNanos)
        // 没在 loading，如果是则没必要再进行刷新
        && !entry.getValueReference().isLoading()) {
        // 异步刷新数据
        V newValue = refresh(key, hash, loader, true);
        if (newValue != null) { // 如果上一步异步刷新还没有返回结果，不会进入 if 语句，最终返回旧值
            return newValue;
        }
    }
    return oldValue; // 否则返回旧值
}


// com.google.common.cache.LocalCache.Segment#refresh

V refresh(K key, int hash, CacheLoader<? super K, V> loader, boolean checkTime) {
    // 为key插入一个LoadingValueReference，实质是把对应 Entry 的 ValueReference 替换为新建的 LoadingValueReference
    final LoadingValueReference<K, V> loadingValueReference =
        insertLoadingValueReference(key, hash, checkTime);
    // 说明原来的 ValueReference 已经是 loading 状态（有其他线程在刷新了）或者还没到刷新时间，那么返回 null
    if (loadingValueReference == null) {
        return null;
    }

    // 通过loader异步加载数据，这里返回的是 Future
    ListenableFuture<V> result = loadAsync(key, hash, loadingValueReference, loader);
    // 这里【立即】判断Future是否已经完成，如果是则返回结果。否则返回 null。因为是可能返回 immediateFuture 或者 ListenableFuture
    if (result.isDone()) { 
        try {
            return Uninterruptibles.getUninterruptibly(result);
        } catch (Throwable t) {
            // don't let refresh exceptions propagate; error was already logged
        }
    }
    return null;
}

@Nullable
LoadingValueReference<K, V> insertLoadingValueReference(
    final K key, final int hash, boolean checkTime) {
  ReferenceEntry<K, V> e = null;
  lock();  // 把 segment 上锁
  try {
    long now = map.ticker.read();
    preWriteCleanup(now); // 做一些清理工作

    AtomicReferenceArray<ReferenceEntry<K, V>> table = this.table;
    int index = hash & (table.length() - 1);
    ReferenceEntry<K, V> first = table.get(index);

    // Look for an existing entry.
    for (e = first; e != null; e = e.getNext()) { // 如果 key 对应的 entry 存在
      K entryKey = e.getKey();
      if (e.getHash() == hash
          && entryKey != null
          && map.keyEquivalence.equivalent(key, entryKey)) { // 通过 key 定位到 entry
        // We found an existing entry.

        ValueReference<K, V> valueReference = e.getValueReference();
        if (valueReference.isLoading()
            || (checkTime && (now - e.getWriteTime() < map.refreshNanos))) { // 如果是 loading，或者还没达到刷新时间，则返回 null
          // refresh is a no-op if loading is pending
          // if checkTime, we want to check *after* acquiring the lock if refresh still needs
          // to be scheduled
          return null;
        }

        // continue returning old value while loading
        ++modCount;
        LoadingValueReference<K, V> loadingValueReference =
            new LoadingValueReference<>(valueReference);  // new 一个 LoadingValueReference，然后把 entry 的 valueReference 替换掉
        e.setValueReference(loadingValueReference);
        return loadingValueReference;
      }
    }
    // 如果key对应的entry不存在，则新建一个Entry，操作跟上面一样。
    ++modCount;
    LoadingValueReference<K, V> loadingValueReference = new LoadingValueReference<>();
    e = newEntry(key, hash, first);
    e.setValueReference(loadingValueReference);
    table.set(index, e);
    return loadingValueReference;
  } finally {
    unlock();
    postWriteCleanup();
  }
}

// com.google.common.cache.LocalCache.Segment#loadAsync
ListenableFuture<V> loadAsync(
    final K key,
    final int hash,
    final LoadingValueReference<K, V> loadingValueReference,
    CacheLoader<? super K, V> loader) {
    // 通过 loader 异步加载数据，返回 ListenableFuture
    final ListenableFuture<V> loadingFuture = loadingValueReference.loadFuture(key, loader);
    loadingFuture.addListener(
        new Runnable() {
            @Override
            public void run() {
                try {
                   // 这里主要是把 newValue set到 entry 中。还涉及其他一系列操作
                    getAndRecordStats(key, hash, loadingValueReference, loadingFuture);
                } catch (Throwable t) {
                    logger.log(Level.WARNING, "Exception thrown during refresh", t);
                    loadingValueReference.setException(t);
                }
            }
        },
        directExecutor());
    return loadingFuture;
}

// com.google.common.cache.LocalCache.LoadingValueReference#loadFuture
public ListenableFuture<V> loadFuture(K key, CacheLoader<? super K, V> loader) {
  try {
    stopwatch.start();
    // oldValue 指在插入 LoadingValueReference 之前的 ValueReference 的值，
    // 如果这个位置之前没有值 oldValue 会被赋值为 UNSET，UNSET.get() 值为 null
    V previousValue = oldValue.get();
    if (previousValue == null) { // 说明缓存项从来没有进入缓存，需要【同步load】。所以针对这种情况，如果在系统刚启动时就来了高并发请求的话，那么除了一个请求之外的所有请求都会【阻塞】在这里，那么提前给热点数据预加热是很有必要的
      V newValue = loader.load(key);
      return set(newValue) ? futureValue : Futures.immediateFuture(newValue); // 也有可能是 immediateFuture
    } // 否则，使用 reload 进行异步加载
    ListenableFuture<V> newValue = loader.reload(key, previousValue);  // 异步 load
    if (newValue == null) {
      return Futures.immediateFuture(null);
    }
    // To avoid a race, make sure the refreshed value is set into loadingValueReference
    // *before* returning newValue from the cache query.
    return transform(
        newValue,
        new com.google.common.base.Function<V, V>() {
          @Override
          public V apply(V newValue) {
            LoadingValueReference.this.set(newValue);
            return newValue;
          }
        },
        directExecutor());
  } catch (Throwable t) {
    ListenableFuture<V> result = setException(t) ? futureValue : fullyFailedFuture(t);
    if (t instanceof InterruptedException) {
      Thread.currentThread().interrupt();
    }
    return result;
  }
}
```

#### 5.1.3 Segment#waitForLoadingValue

```java

V waitForLoadingValue(ReferenceEntry<K, V> e, K key, ValueReference<K, V> valueReference)
    throws ExecutionException {
    // 首先你要是一个 loading 节点
    if (!valueReference.isLoading()) {
        throw new AssertionError();
    }

    checkState(!Thread.holdsLock(e), "Recursive load of: %s", key);
    // don't consider expiration as we're concurrent with loading
    try {
        V value = valueReference.waitForValue();
        if (value == null) {
            throw new InvalidCacheLoadException("CacheLoader returned null for key " + key + ".");
        }
        // re-read ticker now that loading has completed
        long now = map.ticker.read();
        recordRead(e, now);
        return value;
    } finally {
        statsCounter.recordMisses(1);
    }
}

// com.google.common.cache.LocalCache.LoadingValueReference#waitForValue
public V waitForValue() throws ExecutionException {
    return getUninterruptibly(futureValue);
}

// com.google.common.util.concurrent.Uninterruptibles#getUninterruptibly
public static <V> V getUninterruptibly(Future<V> future) throws ExecutionException {
    boolean interrupted = false;
    try {
        while (true) {
            try {
                // hang 住，如果该线程被打断了继续回去 hang 住等结果，直到有结果返回
                return future.get();
            } catch (InterruptedException e) {
                interrupted = true;
            }
        }
    } finally {
        if (interrupted) {
            Thread.currentThread().interrupt();
        }
    }
}
```

#### 5.1.4 Segment#lockedGetOrLoad

```java
V lockedGetOrLoad(K key, int hash, CacheLoader<? super K, V> loader) throws ExecutionException {
  ReferenceEntry<K, V> e;
  ValueReference<K, V> valueReference = null;
  LoadingValueReference<K, V> loadingValueReference = null;
  boolean createNewEntry = true; // 用来判断是否需要创建一个新的 Entry

  lock();  // 要对 segment 写操作 ，先加锁
  try {
    // re-read ticker once inside the lock
    long now = map.ticker.read();
    preWriteCleanup(now); // 做一些清理工作

    int newCount = this.count - 1; // 这里基本就是 HashMap 的代码，如果没有 segment 的数组下标冲突了就拉一个链表
    AtomicReferenceArray<ReferenceEntry<K, V>> table = this.table;
    int index = hash & (table.length() - 1);
    ReferenceEntry<K, V> first = table.get(index);

    for (e = first; e != null; e = e.getNext()) { // 通过key 定位 entry
      K entryKey = e.getKey();
      if (e.getHash() == hash
          && entryKey != null
          && map.keyEquivalence.equivalent(key, entryKey)) {
        valueReference = e.getValueReference();
        if (valueReference.isLoading()) { // 如果在加载中，不需要重复创建 entry，不做任何处理
          createNewEntry = false;
        } else { // 说明不是在加载中
          V value = valueReference.get();
          if (value == null) { // 如果缓存项为 null 数据已经被删除，通知对应的 queue
            enqueueNotification(
                entryKey, hash, value, valueReference.getWeight(), RemovalCause.COLLECTED);
          } else if (map.isExpired(e, now)) { // 这个是 double check 如果缓存项过期 数据没被删除，通知对应的 queue
            // This is a duplicate check, as preWriteCleanup already purged expired
            // entries, but let's accommodate an incorrect expiration queue.
            enqueueNotification(
                entryKey, hash, value, valueReference.getWeight(), RemovalCause.EXPIRED);
          } else { // 再次看到的时候这个位置有值了直接返回
            recordLockedRead(e, now);
            statsCounter.recordHits(1);
            // 进入 lockedGetOrLoad 方法的条件是数据已经过期 || 数据不是在加载中，但是在lock之前都有可能发生并发，进而改变 entry 的状态，
            // 所以在上面中再次判断了isLoading和isExpired。所以来到这步说明，原来数据是过期的且在加载中，lock的前一刻加载完成了，到了这步就有值了，那么正是我们想要的，返回就好了
            // we were concurrent with loading; don't consider refresh
            return value;
          }

          // immediately reuse invalid entries
          writeQueue.remove(e);
          accessQueue.remove(e);
          this.count = newCount; // write-volatile
        }
        break;
      }
    }

    if (createNewEntry) { // 没有 loading ，创建一个 loading 节点
      loadingValueReference = new LoadingValueReference<>();

      if (e == null) {
        e = newEntry(key, hash, first); // e 赋值为新创建的 entry，作为后面的同步锁
        e.setValueReference(loadingValueReference);
        table.set(index, e);
      } else {
        e.setValueReference(loadingValueReference);
      }
    }
  } finally {
    unlock();
    postWriteCleanup();
  }

  if (createNewEntry) {
    try {
      // Synchronizes on the entry to allow failing fast when a recursive load is
      // detected. This may be circumvented when an entry is copied, but will fail fast most
      // of the time.
      synchronized (e) { // 锁住 entry
        return loadSync(key, hash, loadingValueReference, loader); // 同步 load
      }
    } finally {
      statsCounter.recordMisses(1);
    }
  } else {
    // The entry already exists. Wait for loading.
    return waitForLoadingValue(e, key, valueReference);
  }
}
```

通过分析get的主流程代码，我们来画一下流程图：

![图片](http://blog-1259650185.cosbj.myqcloud.com/img/202204/17/1650129399.png)

## 5.2 put

看懂了get的代码后，put的代码就显得很简单了。

Segment的put方法：

```java
// com.google.common.cache.LocalCache.Segment#put
@Nullable
V put(K key, int hash, V value, boolean onlyIfAbsent) {
  lock(); // Segment上锁
  try {
    long now = map.ticker.read();
    preWriteCleanup(now);

    int newCount = this.count + 1;
    if (newCount > this.threshold) { // ensure capacity
      expand();
      newCount = this.count + 1;
    }

    AtomicReferenceArray<ReferenceEntry<K, V>> table = this.table;
    int index = hash & (table.length() - 1);
    ReferenceEntry<K, V> first = table.get(index);

    // Look for an existing entry.
    for (ReferenceEntry<K, V> e = first; e != null; e = e.getNext()) { // 根据 key 找 entry
      K entryKey = e.getKey();
      if (e.getHash() == hash
          && entryKey != null
          && map.keyEquivalence.equivalent(key, entryKey)) {
        // We found an existing entry.

        ValueReference<K, V> valueReference = e.getValueReference(); // 定位到entry
        V entryValue = valueReference.get();

        if (entryValue == null) {  // value 为 null说明 entry 已经过期且被回收或清理掉
          ++modCount;
          if (valueReference.isActive()) {
            enqueueNotification(
                key, hash, entryValue, valueReference.getWeight(), RemovalCause.COLLECTED);
            setValue(e, key, value, now); // 设值
            newCount = this.count; // count remains unchanged
          } else {
            setValue(e, key, value, now);
            newCount = this.count + 1;
          }
          this.count = newCount; // write-volatile
          evictEntries(e);
          return null;
        } else if (onlyIfAbsent) {  // 如果是 onlyIfAbsent 选项则返回旧值
          // Mimic
          // "if (!map.containsKey(key)) ...
          // else return map.get(key);
          recordLockedRead(e, now);
          return entryValue;
        } else { // 不是 onlyIfAbsent，设值
          // clobber existing entry, count remains unchanged
          ++modCount;
          enqueueNotification(
              key, hash, entryValue, valueReference.getWeight(), RemovalCause.REPLACED);
          setValue(e, key, value, now);
          evictEntries(e);
          return entryValue;
        }
      }
    }

    // Create a new entry. // 没有找到 entry，则新建一个 Entry 并设值
    ++modCount;
    ReferenceEntry<K, V> newEntry = newEntry(key, hash, first);
    setValue(newEntry, key, value, now);
    table.set(index, newEntry);
    newCount = this.count + 1;
    this.count = newCount; // write-volatile
    evictEntries(newEntry);
    return null;
  } finally {
    unlock();
    postWriteCleanup();
  }
}
```

------

## 6. 总结

结合上面图以及源码我们发现在整个流程中 GuavaCache 是**没有额外的线程去做数据清理和刷新的，基本都是通过 Get 方法来触发这些动作**，减少了设计的复杂性和降低了系统开销。

那么只使用 refreshAfterWrite 或配置不当的话，会带来一个问题：如果一个  key 很长时间没有访问，这时来一个请求的话会返回旧值，这个好像不是很符合我们的预想，在并发下返回旧值是为了不阻塞，但是在这个场景下，感觉有足够的时间和资源让我们去刷新数据。

简单回顾下 Get 的流程以及在每个阶段做的事情，返回的值。**首先判断缓存是否过期然后判断是否需要刷新，如果过期了就调用 loading 去同步加载数据（其他线程阻塞），如果是仅仅需要刷新调用 reloading 异步加载（其他线程返回老值）**。

所以如果 refreshTime > expireTime 意味着永远走不到缓存刷新逻辑，缓存刷新是为了在缓存有效期内尽量保证缓存数据一致性所以在配置刷新策略和过期策略时一定保证 refreshTime < expireTime 。

用一张时间轴图简单表示：

<img src="http://blog-1259650185.cosbj.myqcloud.com/img/202204/17/1650130468.png" alt="图片" style="zoom:50%;" />

设计一个可用的 Cache 绝对不是一个普通的 Map 这么简单，联系第一篇关于 Cache 的文章，这里小结一下关于 Guava Cache 的知识。

回归到读 LocalCache 的源头，我是希望可以了解 **设计一个缓存要考虑什么？**，*局部性原理* 是一个系统性能提升的最直接的方式(编程上，硬件上当然也可以)，缓存的出现就是根据 *局部性原理* 所设计的。



![img](http://blog-1259650185.cosbj.myqcloud.com/img/202204/17/1650209824.awebp)



缓存作为存储金字塔的一部分，一定需要考虑以下几个问题：

1. 何时加载

在设计何时加载的问题上，Guava Cache 提供了一个 Loader 接口，让用户可以自定义加载过程，在由 Cache 在找不到对象的时候主动调用 Loader 去加载，还通过一个巧妙的方法，既保证了 Loader 的只运行一次，还能保证锁粒度极小，保证并发加载时，安全且高性能。

2. 何时失效

失效处理上，Guava Cache 提供了基于容量、有限时间(读有限时、写有限时)等失效策略，在官方文档上也写明，在基于限时的情况下，并不是使用一个线程去单独清理过期 K-V，而是把这个清理工作，均摊到每次访问中。假如需要定时清理，也可以调用 CleanUp 方法，定时调用就可以了。

3. 如何保持热点数据有效性

在 Cache 容量有限时， LRU 算法是一个通用的解决方案，在源码中，Guava Cache 并不是严格地保证全局 LRU 的，只是针对一个 Segment 实现 LRU 算法。这个前提是 Segment 对用户来说是随机的，所以全局的 LRU 算法和单个 Segment 的算法是基本一致的。

4. 写回策略

在 Guava Cache 里，并没有实现任何的写回策略。原因在于，Guava Cache 是一个本地缓存，直接修改对象的数据，Cache 的数据就已经是最新的了，所以在数据能够写入 DB 后，数据就已经完成一致了。

最后关于 Guava Cache 的使用建议 (最佳实践) ：

1. 如果刷新时间配置的较短一定要重载 reload 异步加载数据的方法，传入一个自定义线程池保护 DB
2. 失效时间一定要大于刷新时间
3. 如果是常驻内存的一些少量数据失效时间可以配置的较长刷新时间配置短一点 (根据业务对缓存失效容忍度)



## 参考

[Guava Cache 原理分析与最佳实践](https://mp.weixin.qq.com/s/teGvFv-X3BTfJOD5OFr7Yg)

[Guava Cache 实现原理及最佳实践](https://mp.weixin.qq.com/s/YczkXueLgHsnsGFbVvhY1Q)

[Google guava cache源码解析1--构建缓存器（2）](https://sq.sf.163.com/blog/article/233355704088748032)

[Google Guava Cache 全解析](https://www.jianshu.com/p/38bd5f1cf2f2)
