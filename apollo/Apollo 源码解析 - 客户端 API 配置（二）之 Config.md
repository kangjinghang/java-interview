# 1. 概述

> 老艿艿：本系列假定胖友已经阅读过 [《Apollo 官方 wiki 文档》](https://github.com/ctripcorp/apollo/wiki/) ，特别是 [《Java 客户端使用指南》](https://github.com/ctripcorp/apollo/wiki/Apollo开放平台) 。

本文接 [《Apollo 源码解析 —— 客户端 API 配置（一）之一览》](http://www.iocoder.cn/Apollo/client-config-api-1/?self) 一文，分享 Config 接口，及其子类，如下图：

<img src="http://blog-1259650185.cosbj.myqcloud.com/img/202204/08/1649432153.png" alt="Config 类图" style="zoom: 67%;" />

# 2. Config

在 [《Apollo 源码解析 —— 客户端 API 配置（一）之一览》](http://www.iocoder.cn/Apollo/client-config-api-1/?self) 的 [「3.1 Config」](https://www.iocoder.cn/Apollo/client-config-api-2/#) 中，有详细分享。

# 3. AbstractConfig

`com.ctrip.framework.apollo.internals.AbstractConfig` ，实现 Config 接口，Config 抽象类，实现了1）缓存读取属性值、2）异步通知监听器、3）计算属性变化等等**特性**。

## 3.1 构造方法

```java
public abstract class AbstractConfig implements Config {
  private static final Logger logger = LoggerFactory.getLogger(AbstractConfig.class);
  // ExecutorService 对象，用于配置变化时，异步通知 ConfigChangeListener 监听器们。静态属性，所有 Config 共享该线程池。
  private static final ExecutorService m_executorService;
  // ConfigChangeListener 集合
  private final List<ConfigChangeListener> m_listeners = Lists.newCopyOnWriteArrayList();
  private final Map<ConfigChangeListener, Set<String>> m_interestedKeys = Maps.newConcurrentMap();
  private final Map<ConfigChangeListener, Set<String>> m_interestedKeyPrefixes = Maps.newConcurrentMap();
  private final ConfigUtil m_configUtil;
  private volatile Cache<String, Integer> m_integerCache;
  private volatile Cache<String, Long> m_longCache;
  private volatile Cache<String, Short> m_shortCache;
  private volatile Cache<String, Float> m_floatCache;
  private volatile Cache<String, Double> m_doubleCache;
  private volatile Cache<String, Byte> m_byteCache;
  private volatile Cache<String, Boolean> m_booleanCache;
  private volatile Cache<String, Date> m_dateCache;
  private volatile Cache<String, Long> m_durationCache;
  private final Map<String, Cache<String, String[]>> m_arrayCache; // 数组属性 Cache Map。KEY：分隔符。KEY2：属性键
  private final List<Cache> allCaches; // 上述 Cache 对象集合
  private final AtomicLong m_configVersion; //indicate config version. 缓存版本号，用于解决更新缓存可能存在的并发问题。详细见 {@link #getValueAndStoreToCache(String, Function, Cache, Object)} 方法

  protected PropertiesFactory propertiesFactory;

  static {
    m_executorService = Executors.newCachedThreadPool(ApolloThreadFactory
        .create("Config", true));
  }

  public AbstractConfig() {
    m_configUtil = ApolloInjector.getInstance(ConfigUtil.class);
    m_configVersion = new AtomicLong();
    m_arrayCache = Maps.newConcurrentMap();
    allCaches = Lists.newArrayList();
    propertiesFactory = ApolloInjector.getInstance(PropertiesFactory.class);
  }
  
  // ... 省略其他接口和属性
}
```

- 字段解释，见代码注释。

- Cache 对象，使用 `#newCache()` 方法创建，代码如下：

  ```
  private <T> Cache<String, T> newCache() {
      // 创建 Cache 对象
      Cache<String, T> cache = CacheBuilder.newBuilder()
              .maximumSize(m_configUtil.getMaxConfigCacheSize()) // 500
              .expireAfterAccess(m_configUtil.getConfigCacheExpireTime(), // 1 分钟
                      m_configUtil.getConfigCacheExpireTimeUnit())
              .build();
      // 添加到 Cache 集合
      allCaches.add(cache);
      return cache;
  }
  ```

- `allCaches` 字段，上述 Cache 对象集合，用于 `#clearConfigCache()` 方法，清空缓存。代码如下：

  ```
  protected void clearConfigCache() {
      synchronized (this) {
          // 过期缓存
          for (Cache c : allCaches) {
              if (c != null) {
                  c.invalidateAll();
              }
          }
          // 新增版本号
          m_configVersion.incrementAndGet();
      }
  }
  ```

  - **synchronized** ，用于和 `#getValueAndStoreToCache(...)` 方法，在更新缓存时的**互斥**，避免并发。
  - 每次过期完所有的缓存后，版本号 **+ 1** 。

## 3.2 获得属性值

AbstractConfig 实现了**所有**的获得属性值的方法，除了 `#getProperty(key, defaultValue)` 方法。我们以 `#getIntProperty(key, defaultValue)` 方法，举例子。代码如下：

```java
@Override
public Integer getIntProperty(String key, Integer defaultValue) {
  try {
    if (m_integerCache == null) { // 初始化缓存
      synchronized (this) {
        if (m_integerCache == null) {
          m_integerCache = newCache();
        }
      }
    }

    return getValueFromCache(key, Functions.TO_INT_FUNCTION, m_integerCache, defaultValue); // 从缓存中，读取属性值
  } catch (Throwable ex) {
    Tracer.logError(new ApolloConfigException(
        String.format("getIntProperty for %s failed, return default value %d", key,
            defaultValue), ex));
  }
  return defaultValue;
}
```

- 调用 `#getValueFromCache(key, Function, cache, defaultValue)` 方法，从缓存中，读取属性值。比较特殊的是 **Function** 方法参数，我们下面详细解析。

------

`#getValueFromCache(key, Function, cache, defaultValue)` 方法，代码如下：

```java
private <T> T getValueFromCache(String key, Function<String, T> parser, Cache<String, T> cache, T defaultValue) {
  T result = cache.getIfPresent(key); // 获得属性值

  if (result != null) { // 若存在，则返回
    return result;
  }
  // 获得值，并更新到缓存
  return getValueAndStoreToCache(key, parser, cache, defaultValue);
}
```

- 优先，从缓存中，获得属性值。若获取不到，调用 `#getValueAndStoreToCache(key, Function, cache, defaultValue)` 方法，获得值，**并更新到缓存**。

------

`#getValueAndStoreToCache(key, Function, cache, defaultValue)` 方法，代码如下：

```java
private <T> T getValueAndStoreToCache(String key, Function<String, T> parser, Cache<String, T> cache, T defaultValue) {
  long currentConfigVersion = m_configVersion.get();  // 获得当前版本号
  String value = getProperty(key, null); // 获得属性值

  if (value != null) { // 若获得到属性，返回该属性值
    T result = parser.apply(value);  // 解析属性值

    if (result != null) {
      synchronized (this) {
        if (m_configVersion.get() == currentConfigVersion) { // 若版本号未变化，则更新到缓存，从而解决并发的问题
          cache.put(key, result);
        }
      }
      return result; // 返回属性值
    }
  }

  return defaultValue; // 获得不到属性值，返回默认值
}
```

### 3.2.1 Functions

`com.ctrip.framework.apollo.util.function.Functions` ，枚举了所有解析**字符串**成对应数据类型的 Function 。代码如下：

````java
public interface Functions {
  Function<String, Integer> TO_INT_FUNCTION = new Function<String, Integer>() {
    @Override
    public Integer apply(String input) {
      return Integer.parseInt(input);
    }
  };
  Function<String, Long> TO_LONG_FUNCTION = new Function<String, Long>() {
    @Override
    public Long apply(String input) {
      return Long.parseLong(input);
    }
  };
  Function<String, Short> TO_SHORT_FUNCTION = new Function<String, Short>() {
    @Override
    public Short apply(String input) {
      return Short.parseShort(input);
    }
  };
  Function<String, Float> TO_FLOAT_FUNCTION = new Function<String, Float>() {
    @Override
    public Float apply(String input) {
      return Float.parseFloat(input);
    }
  };
  Function<String, Double> TO_DOUBLE_FUNCTION = new Function<String, Double>() {
    @Override
    public Double apply(String input) {
      return Double.parseDouble(input);
    }
  };
  Function<String, Byte> TO_BYTE_FUNCTION = new Function<String, Byte>() {
    @Override
    public Byte apply(String input) {
      return Byte.parseByte(input);
    }
  };
  Function<String, Boolean> TO_BOOLEAN_FUNCTION = new Function<String, Boolean>() {
    @Override
    public Boolean apply(String input) {
      return Boolean.parseBoolean(input);
    }
  };
  Function<String, Date> TO_DATE_FUNCTION = new Function<String, Date>() {
    @Override
    public Date apply(String input) {
      try {
        return Parsers.forDate().parse(input);
      } catch (ParserException ex) {
        throw new ApolloConfigException("Parse date failed", ex);
      }
    }
  };
  Function<String, Long> TO_DURATION_FUNCTION = new Function<String, Long>() {
    @Override
    public Long apply(String input) {
      try {
        return Parsers.forDuration().parseToMillis(input);
      } catch (ParserException ex) {
        throw new ApolloConfigException("Parse duration failed", ex);
      }
    }
  };
}
````

- 因为 Function 在 JDK 1.8 才支持，所以此处使用的是 `com.google.common.base.Function` 。
- `TO_DATE_FUNCTION` 和 `TO_DURATION_FUNCTION` ，具体的解析，使用 `com.ctrip.framework.apollo.util.parser.Parsers` 。

## 3.3 计算配置变更集合

```java
List<ConfigChange> calcPropertyChanges(String namespace, Properties previous,
                                       Properties current) {
  if (previous == null) {
    previous = propertiesFactory.getPropertiesInstance();
  }

  if (current == null) {
    current =  propertiesFactory.getPropertiesInstance();
  }

  Set<String> previousKeys = previous.stringPropertyNames();
  Set<String> currentKeys = current.stringPropertyNames();

  Set<String> commonKeys = Sets.intersection(previousKeys, currentKeys);  // 交集
  Set<String> newKeys = Sets.difference(currentKeys, commonKeys); // 新集合 - 交集 = 新增
  Set<String> removedKeys = Sets.difference(previousKeys, commonKeys);// 老集合 - 交集 = 移除

  List<ConfigChange> changes = Lists.newArrayList();
  // 计算新增的
  for (String newKey : newKeys) {
    changes.add(new ConfigChange(namespace, newKey, null, current.getProperty(newKey),
        PropertyChangeType.ADDED));
  }
  // 计算移除的
  for (String removedKey : removedKeys) {
    changes.add(new ConfigChange(namespace, removedKey, previous.getProperty(removedKey), null,
        PropertyChangeType.DELETED));
  }
  // 计算修改的
  for (String commonKey : commonKeys) {
    String previousValue = previous.getProperty(commonKey);
    String currentValue = current.getProperty(commonKey);
    if (Objects.equal(previousValue, currentValue)) {
      continue;
    }
    changes.add(new ConfigChange(namespace, commonKey, previousValue, currentValue,
        PropertyChangeType.MODIFIED));
  }

  return changes;
}
```

## 3.4 添加配置变更监听器

```java
@Override
public void addChangeListener(ConfigChangeListener listener) {
  addChangeListener(listener, null);
}

@Override
public void addChangeListener(ConfigChangeListener listener, Set<String> interestedKeys) {
  addChangeListener(listener, interestedKeys, null);
}

@Override
public void addChangeListener(ConfigChangeListener listener, Set<String> interestedKeys, Set<String> interestedKeyPrefixes) {
  if (!m_listeners.contains(listener)) {
    m_listeners.add(listener);
    if (interestedKeys != null && !interestedKeys.isEmpty()) {
      m_interestedKeys.put(listener, Sets.newHashSet(interestedKeys));
    }
    if (interestedKeyPrefixes != null && !interestedKeyPrefixes.isEmpty()) {
      m_interestedKeyPrefixes.put(listener, Sets.newHashSet(interestedKeyPrefixes));
    }
  }
}
```

## 3.5 触发配置变更监听器们

```java
protected void fireConfigChange(final ConfigChangeEvent changeEvent) {
  final List<ConfigChangeListener> listeners = this
      .findMatchedConfigChangeListeners(changeEvent.changedKeys());

  // notify those listeners
  for (ConfigChangeListener listener : listeners) {
    this.notifyAsync(listener, changeEvent);
  }
}

private List<ConfigChangeListener> findMatchedConfigChangeListeners(Set<String> changedKeys) {
  final List<ConfigChangeListener> configChangeListeners = new ArrayList<>();
  for (ConfigChangeListener configChangeListener : this.m_listeners) {
    // check whether the listener is interested in this change event
    if (this.isConfigChangeListenerInterested(configChangeListener, changedKeys)) {
      configChangeListeners.add(configChangeListener);
    }
  }
  return configChangeListeners;
}

private void notifyAsync(final ConfigChangeListener listener, final ConfigChangeEvent changeEvent) {
  m_executorService.submit(new Runnable() {
    @Override
    public void run() {
      String listenerName = listener.getClass().getName();
      Transaction transaction = Tracer.newTransaction("Apollo.ConfigChangeListener", listenerName);
      try {
        listener.onChange(changeEvent);
        transaction.setStatus(Transaction.SUCCESS);
      } catch (Throwable ex) {
        transaction.setStatus(ex);
        Tracer.logError(ex);
        logger.error("Failed to invoke config change listener {}", listenerName, ex);
      } finally {
        transaction.complete();
      }
    }
  });
}
```

- 提交到线程池中，异步并发通知监听器们，从而避免有些监听器**执行时间过长**。

# 4. DefaultConfig

`com.ctrip.framework.apollo.internals.DefaultConfig` ，实现 RepositoryChangeListener 接口，继承 AbstractConfig 抽象类，**默认** Config 实现类。

## 4.1 构造方法

```java
public class DefaultConfig extends AbstractConfig implements RepositoryChangeListener {

  private static final Logger logger = DeferredLoggerFactory.getLogger(DefaultConfig.class);
  private final String m_namespace;// Namespace 的名字
  private final Properties m_resourceProperties;// 项目下，Namespace 对应的配置文件的 Properties
  private final AtomicReference<Properties> m_configProperties;// 配置 Properties 的缓存引用
  private final ConfigRepository m_configRepository;// 配置 Repository
  private final RateLimiter m_warnLogRateLimiter;// 打印告警限流器。当读取不到属性值，会打印告警日志。通过该限流器，避免打印过多日志

  private volatile ConfigSourceType m_sourceType = ConfigSourceType.NONE;

  /**
   * Constructor.
   *
   * @param namespace        the namespace of this config instance
   * @param configRepository the config repository for this config instance
   */
  public DefaultConfig(String namespace, ConfigRepository configRepository) {
    m_namespace = namespace;
    m_resourceProperties = loadFromResource(m_namespace);
    m_configRepository = configRepository;
    m_configProperties = new AtomicReference<>();
    m_warnLogRateLimiter = RateLimiter.create(0.017); // 1 warning log output per minute
    initialize(); // 初始化
  }
  // ... 省略其他接口和属性
}
```

- `m_namespace` 字段，Namespace 的名字。

- `m_configProperties` 字段，配置 Properties 的缓存**引用**。

- `m_configRepository` 字段，配置 **Repository** 。DefaultConfig 会从 ConfigRepository 中，加载配置 Properties ，并更新到 `m_configProperties` 中。

  - 为什么 DefaultConfig **实现** RepositoryChangeListener 接口？ConfigRepository 的一个实现类 RemoteConfigRepository ，会从远程 Config Service 加载配置。但是 Config Service 的配置**不是**一成不变，可以在 Portal 进行修改。所以 RemoteConfigRepository 会在配置变更时，从 Admin Service 重新加载配置。为了实现 Config 监听配置的变更，所以需要将 DefaultConfig 注册为 ConfigRepository 的监听器。因此，DefaultConfig **需要实现** RepositoryChangeListener 接口。详细解析，见 [《Apollo 源码解析 —— Client 轮询配置》](http://www.iocoder.cn/Apollo/client-polling-config/?self) 。

  - `#initialize()` 方法，初始拉取 ConfigRepository 的配置，更新到 `m_configProperties` 中，并注册自己到 ConfigRepository 为监听器。代码如下：

    ```java
    private void initialize() {
      try {
        updateConfig(m_configRepository.getConfig(), m_configRepository.getSourceType());
      } catch (Throwable ex) {
        Tracer.logError(ex);
        logger.warn("Init Apollo Local Config failed - namespace: {}, reason: {}.",
            m_namespace, ExceptionUtil.getDetailMessage(ex));
      } finally {
        //register the change listener no matter config repository is working or not
        //so that whenever config repository is recovered, config could get changed
        // 注册到 ConfigRepository 中，从而实现每次配置发生变更时，更新配置缓存 m_configProperties
        m_configRepository.addChangeListener(this);
      }
    }
    
    private void updateConfig(Properties newConfigProperties, ConfigSourceType sourceType) {
      m_configProperties.set(newConfigProperties); // 初始化 m_configProperties
      m_sourceType = sourceType;
    }
    ```

- `m_resourceProperties` 字段，**项目下**，Namespace 对应的配置文件的 Properties 。代码如下：

  ```java
  private Properties loadFromResource(String namespace) {
      // 生成文件名
      String name = String.format("META-INF/config/%s.properties", namespace);
      // 读取 Properties 文件
      InputStream in = ClassLoaderUtil.getLoader().getResourceAsStream(name);
      Properties properties = null;
      if (in != null) {
          properties = new Properties();
          try {
              properties.load(in);
          } catch (IOException ex) {
              Tracer.logError(ex);
              logger.error("Load resource config for namespace {} failed", namespace, ex);
          } finally {
              try {
                  in.close();
              } catch (IOException ex) {
                  // ignore
              }
          }
      }
      return properties;
  }
  ```

  - 😈 读取属性的优先级上，`m_configProperties` > `m_resourceProperties` 。

## 4.2 获得属性值

```java
@Override
public String getProperty(String key, String defaultValue) {
  // step 1: check system properties, i.e. -Dkey=value。 从系统 Properties 获得属性，例如，JVM 启动参数。
  String value = System.getProperty(key);

  // step 2: check local cached properties file。 从缓存 Properties 获得属性
  if (value == null) {
    value = this.getPropertyFromRepository(key);
  }

  /*
   * step 3: check env variable, i.e. PATH=... 。从环境变量中获得属性
   * normally system environment variables are in UPPERCASE, however there might be exceptions.
   * so the caller should provide the key in the right case
   */
  if (value == null) {
    value = System.getenv(key);
  }

  // step 4: check properties file from classpath。从类路径 classpath 中获得属性
  if (value == null) {
    value = this.getPropertyFromAdditional(key);
  }
  // 打印告警日志
  this.tryWarnLog(value);
  // 若为空，使用默认值
  return value == null ? defaultValue : value;
}

protected void tryWarnLog(String value) {
  if (value == null && m_configProperties.get() == null && m_warnLogRateLimiter.tryAcquire()) {
    logger.warn(
        "Could not load config for namespace {} from Apollo, please check whether the configs are released in Apollo! Return default value now!",
        m_namespace);
  }
}
```

- 有**四个**属性源，胖友看下代码注释。

## 4.3 获得属性名集合

```java
@Override
public Set<String> getPropertyNames() {
  // propertyNames include system property and system env might cause some compatibility issues, though that looks like the correct implementation.
  Set<String> fromRepository = this.getPropertyNamesFromRepository();
  Set<String> fromAdditional = this.getPropertyNamesFromAdditional();
  if (fromRepository == null || fromRepository.isEmpty()) {
    return fromAdditional;
  }
  if (fromAdditional == null || fromAdditional.isEmpty()) {
    return fromRepository;
  }
  Set<String> propertyNames = Sets
      .newLinkedHashSetWithExpectedSize(fromRepository.size() + fromAdditional.size());
  propertyNames.addAll(fromRepository);
  propertyNames.addAll(fromAdditional);
  return propertyNames;
}

/**
 * get property names from cached repository properties file
 *
 * @return property names
 */
protected Set<String> getPropertyNamesFromRepository() {
  Properties properties = m_configProperties.get();
  if (properties == null) {
    return Collections.emptySet();
  }
  return this.stringPropertyNames(properties);
}

/**
 * get property names from additional properties file on classpath
 *
 * @return property names
 */
protected Set<String> getPropertyNamesFromAdditional() {
  Properties properties = m_resourceProperties;
  if (properties == null) {
    return Collections.emptySet();
  }
  return this.stringPropertyNames(properties);
}
```

## 4.4 计算配置变更集合

因为 DefaultConfig 有**多个**属性源，所以需要在 `AbstractConfig#updateAndCalcConfigChanges(...)` 方法的基础上，**进一步计算**。代码如下：

```java
// 因为 DefaultConfig 有多个属性源，所以需要在 AbstractConfig#updateAndCalcConfigChanges(...) 方法的基础上，进一步计算
private Map<String, ConfigChange> updateAndCalcConfigChanges(Properties newConfigProperties,
    ConfigSourceType sourceType) {
  List<ConfigChange> configChanges =  // 计算配置变更集合
      calcPropertyChanges(m_namespace, m_configProperties.get(), newConfigProperties);
  // 结果
  ImmutableMap.Builder<String, ConfigChange> actualChanges =
      new ImmutableMap.Builder<>();

  /** === Double check since DefaultConfig has multiple config sources ==== **/

  //1. use getProperty to update configChanges's old value. 重新设置每个 ConfigChange 的【旧】值
  for (ConfigChange change : configChanges) {
    change.setOldValue(this.getProperty(change.getPropertyName(), change.getOldValue()));
  }

  //2. update m_configProperties. 更新到 m_configProperties 中
  updateConfig(newConfigProperties, sourceType);
  clearConfigCache();

  //3. use getProperty to update configChange's new value and calc the final changes
  for (ConfigChange change : configChanges) {
    change.setNewValue(this.getProperty(change.getPropertyName(), change.getNewValue())); // 重新设置每个 ConfigChange 的【新】值
    switch (change.getChangeType()) { // 重新计算变化类型
      case ADDED:
        if (Objects.equals(change.getOldValue(), change.getNewValue())) { // 相等，忽略
          break;
        }
        if (change.getOldValue() != null) {  // 老值非空，修改为变更类型
          change.setChangeType(PropertyChangeType.MODIFIED);
        }
        actualChanges.put(change.getPropertyName(), change); // 添加过结果
        break;
      case MODIFIED:
        if (!Objects.equals(change.getOldValue(), change.getNewValue())) { // 若不相等，说明依然是变更类型，添加到结果
          actualChanges.put(change.getPropertyName(), change);
        }
        break;
      case DELETED:
        if (Objects.equals(change.getOldValue(), change.getNewValue())) { // 相等，忽略
          break;
        }
        if (change.getNewValue() != null) { // 新值非空，修改为变更类型
          change.setChangeType(PropertyChangeType.MODIFIED);
        }
        actualChanges.put(change.getPropertyName(), change); // 添加过结果
        break;
      default:
        //do nothing
        break;
    }
  }
  return actualChanges.build();
}
```

- 🙂 比较易懂，胖友自己看下代码注释。

## 4.5 onRepositoryChange

`#onRepositoryChange(namespace, newProperties)` 方法，当 ConfigRepository 读取到配置发生变更时，计算配置变更集合，并通知监听器们。代码如下：

```java
@Override
public synchronized void onRepositoryChange(String namespace, Properties newProperties) {
  if (newProperties.equals(m_configProperties.get())) {  // 忽略，若未变更
    return;
  }

  ConfigSourceType sourceType = m_configRepository.getSourceType();
  Properties newConfigProperties = propertiesFactory.getPropertiesInstance(); // 读取新的 Properties 对象
  newConfigProperties.putAll(newProperties);
  // 计算配置变更集合
  Map<String, ConfigChange> actualChanges = updateAndCalcConfigChanges(newConfigProperties,
      sourceType);

  //check double checked result
  if (actualChanges.isEmpty()) {
    return;
  }
  // 通知监听器们
  this.fireConfigChange(m_namespace, actualChanges);

  Tracer.logEvent("Apollo.Client.ConfigChanges", m_namespace);
}
```

- 🙂 比较易懂，胖友自己看下代码注释。

# 5. SimpleConfig

`com.ctrip.framework.apollo.internals.SimpleConfig` ，实现 RepositoryChangeListener 接口，继承 AbstractConfig 抽象类，**精简的** Config 实现类。

从目前代码看来下，用于单元测试。相比 DefaultConfig 来说，少一些特性，大体是相同的。



# 参考

[Apollo 源码解析 —— 客户端 API 配置（二）之 Config](https://www.iocoder.cn/Apollo/client-config-api-2/)
