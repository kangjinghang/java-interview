# 1. 概述

> 老艿艿：本系列假定胖友已经阅读过 [《Apollo 官方 wiki 文档》](https://github.com/ctripcorp/apollo/wiki/) ，特别是 [《Java 客户端使用指南》](https://github.com/ctripcorp/apollo/wiki/Apollo开放平台) 。

本文，我们来**一览** Apollo **客户端**配置的 Java API 的实现，从而对它有**整体**的认识。再在之后的文章，我会写每个组件的具体代码实现。

涉及类如下图：<img src="http://blog-1259650185.cosbj.myqcloud.com/img/202204/08/1649403399.png" alt="类" style="zoom:50%;" />

# 2. ConfigService

`com.ctrip.framework.apollo.ConfigService` ，客户端配置**服务**，作为配置使用的**入口**。

## 2.1 构造方法

```java
/**
 * 单例
 */
private static final ConfigService s_instance = new ConfigService();

private volatile ConfigManager m_configManager;
private volatile ConfigRegistry m_configRegistry;
```

- `s_instance` **静态**，单例。

- `m_configManager` 属性，通过 `#getManager()` 方法获得。代码如下：

  ```java
  private ConfigManager getManager() {
      // 若 ConfigManager 未初始化，进行获得
      if (m_configManager == null) {
          synchronized (this) {
              if (m_configManager == null) {
                  m_configManager = ApolloInjector.getInstance(ConfigManager.class);
              }
          }
      }
      // 返回 ConfigManager
      return m_configManager;
  }
  ```

  - 调用 `ApolloInjector#getInstance(Class<T>)` 方法，获得 ConfigManager **单例**。详细解析，在 [「5.4 ApolloInjector」](https://www.iocoder.cn/Apollo/client-config-api-1/#) 中。

- `m_configRegistry` 属性，通过 `#getRegistry()` 方法获得。代码如下：

  ```java
  private ConfigRegistry getRegistry() {
      // 若 ConfigRegistry 未初始化，进行获得
      if (m_configRegistry == null) {
          synchronized (this) {
              if (m_configRegistry == null) {
                  m_configRegistry = ApolloInjector.getInstance(ConfigRegistry.class);
              }
          }
      }
      // 返回 ConfigRegistry 
      return m_configRegistry;
  }
  ```

- ConfigManager 和 ConfigRegistry 是什么？不用捉急，下面会分享。

## 2.2 获得配置对象

在 Apollo 客户端中，有两种**形式**的配置对象的接口：

- Config ，配置接口
- ConfigFile ，配置**文件**接口

实际情况下，我们使用 **Config** 居多。另外，有一点需要注意，Config 和 ConfigFile **差异在于形式**，而不是类型。🙂 如果不理解，没关系，下面会具体解释。

### 2.2.1 获得 Config 对象

```java
/**
 * Get Application's config instance.
 *
 * @return config instance
 */
public static Config getAppConfig() {
    return getConfig(ConfigConsts.NAMESPACE_APPLICATION);
}

/**
 * Get the config instance for the namespace.
 *
 * @param namespace the namespace of the config
 * @return config instance
 */
public static Config getConfig(String namespace) {
    return s_instance.getManager().getConfig(namespace);
}
```

- 调用 `ConfigManager#getConfig(namespace)` 方法，获得 **Namespace** 对应的 Config 对象。在这里，我们可以看出，ConfigManager 是 Config 的**管理器**。

### 2.2.2 获得 ConfigFile 对象

```java
public static ConfigFile getConfigFile(String namespace, ConfigFileFormat configFileFormat) {
    return s_instance.getManager().getConfigFile(namespace, configFileFormat);
}
```

- 调用 `ConfigManager#getConfigFile(namespace, ConfigFileFormat)` 方法，获得 **Namespace** 对应的 ConfigFile 对象。在这里，我们可以看出，ConfigManager **也**是 ConfigFile 的**管理器**。

- 相比 `#getConfig(namespace)` 方法，多了一个类型为 ConfigFileFormat 的方法参数，实际是**一致的**。因为 ConfigManager 会在方法中，将 ConfigFileFormat 拼接到 `namespace` 中。代码如下：

  ```java
  // ConfigManager#getConfigFile(namespace, configFileFormat)
  String namespaceFileName = String.format("%s.%s", namespace, configFileFormat.getValue());
  ```

## 2.3 设置 Config 对象

```java
static void setConfig(Config config) {
    setConfig(ConfigConsts.NAMESPACE_APPLICATION, config);
}

/**
 * Manually set the config for the namespace specified, use with caution.
 *
 * @param namespace the namespace
 * @param config    the config instance
 */
static void setConfig(String namespace, final Config config) {
    s_instance.getRegistry().register(namespace, new ConfigFactory() {

        @Override
        public Config create(String namespace) {
            return config;
        }

        @Override
        public ConfigFile createConfigFile(String namespace, ConfigFileFormat configFileFormat) {
            return null; // 空
        }

    });
}
```

- 按道理说，应该是将 Config 对象，设置到 ConfigManager 才对呀！这是笔者**一开始**的理解。在 Apollo 的设计中，ConfigManager **不允许**设置 Namespace 对应的 Config 对象，而是通过 ConfigFactory **统一**创建，虽然此时的创建是**假**的，直接返回了 `config` 方法参数。

## 2.4 设置 ConfigFactory 对象

```java
static void setConfigFactory(ConfigFactory factory) {
    setConfigFactory(ConfigConsts.NAMESPACE_APPLICATION, factory);
}

/**
 * Manually set the config factory for the namespace specified, use with caution.
 *
 * @param namespace the namespace
 * @param factory   the factory instance
 */
static void setConfigFactory(String namespace, ConfigFactory factory) {
    s_instance.getRegistry().register(namespace, factory);
}
```

- 和 [「2.3 设置 Config 对象」](https://www.iocoder.cn/Apollo/client-config-api-1/#) **类似**，也是**注册**到 ConfigRegistry 中。

# 3. Config && ConfigFile

## 3.1 Config

`com.ctrip.framework.apollo.Config` ，Config **接口**。子类如下图：

<img src="http://blog-1259650185.cosbj.myqcloud.com/img/202204/08/1649404523.png" alt="类" style="zoom: 67%;" />

子类的具体实现，本文暂时不分享，避免信息量过大。

### 3.1.1 获得属性

```java
String getProperty(String key, String defaultValue);

Integer getIntProperty(String key, Integer defaultValue);

Long getLongProperty(String key, Long defaultValue);

Short getShortProperty(String key, Short defaultValue);

Float getFloatProperty(String key, Float defaultValue);

Double getDoubleProperty(String key, Double defaultValue);

Byte getByteProperty(String key, Byte defaultValue);

Boolean getBooleanProperty(String key, Boolean defaultValue);

String[] getArrayProperty(String key, String delimiter, String[] defaultValue);

Date getDateProperty(String key, Date defaultValue);

Date getDateProperty(String key, String format, Date defaultValue);

Date getDateProperty(String key, String format, Locale locale, Date defaultValue);

<T extends Enum<T>> T getEnumProperty(String key, Class<T> enumType, T defaultValue);

/**
 * Return the duration property value(in milliseconds) with the given name, or {@code
 * defaultValue} if the name doesn't exist. Please note the format should comply with the follow
 * example (case insensitive). Examples:
 * <pre>
 *    "123MS"          -- parses as "123 milliseconds"
 *    "20S"            -- parses as "20 seconds"
 *    "15M"            -- parses as "15 minutes" (where a minute is 60 seconds)
 *    "10H"            -- parses as "10 hours" (where an hour is 3600 seconds)
 *    "2D"             -- parses as "2 days" (where a day is 24 hours or 86400 seconds)
 *    "2D3H4M5S123MS"  -- parses as "2 days, 3 hours, 4 minutes, 5 seconds and 123 milliseconds"
 * </pre>
 *
 * @param key          the property name
 * @param defaultValue the default value when name is not found or any error occurred
 * @return the parsed property value(in milliseconds)
 */
long getDurationProperty(String key, long defaultValue);
```

- 提供了**多样**的获得属性的方法，特别有趣的是 `#getDurationProperty(key, defaultValue)` 方法。

### 3.1.2 获得属性名集合

```java
Set<String> getPropertyNames();
```

### 3.1.3 添加配置变化监听器

```java
void addChangeListener(ConfigChangeListener listener);
```

使用实例，参见 [《Apollo应用之动态调整线上数据源(DataSource)》](http://www.kailing.pub/article/index/arcid/198.html) 文章。

#### 3.1.3.1 ConfigChangeListener

`com.ctrip.framework.apollo.ConfigChangeListener` **接口**，代码如下：

```java
public interface ConfigChangeListener {
  /**
   * Invoked when there is any config change for the namespace.
   * @param changeEvent the event for this change
   */
  void onChange(ConfigChangeEvent changeEvent);
}
```

#### 3.1.3.2 ConfigChangeEvent

`com.ctrip.framework.apollo.model.ConfigChangeEvent` ，Config 变化事件，代码如下：

```java
public class ConfigChangeEvent {
    
    /**
     * Namespace 名字
     */
    private final String m_namespace;
    /**
     * 变化属性的集合
     *
     * KEY：属性名
     * VALUE：配置变化
     */
    private final Map<String, ConfigChange> m_changes;
}
```

#### 3.1.3.3 ConfigChange

`com.ctrip.framework.apollo.model.ConfigChange` ，配置**每个属性**变化的信息。代码如下：

```java
public class ConfigChange {

    /**
     * Namespace 名字
     */
    private final String namespace;
    /**
     * 属性名
     */
    private final String propertyName;
    /**
     * 老值
     */
    private String oldValue;
    /**
     * 新值
     */
    private String newValue;
    /**
     * 变化类型
     */
    private PropertyChangeType changeType;
}
```

#### 3.1.3.4 PropertyChangeType

`com.ctrip.framework.apollo.enums.PropertyChangeType` ，属性变化类型枚举。代码如下：

```java
public enum PropertyChangeType {

    ADDED, // 添加
    MODIFIED, // 修改
    DELETED // 删除

}
```

## 3.2 ConfigFile

`com.ctrip.framework.apollo.ConfigFile` ，ConfigFile **接口**。子类如下图：

<img src="http://blog-1259650185.cosbj.myqcloud.com/img/202204/08/1649405357.png" alt="类" style="zoom:50%;" />

子类的具体实现，本文暂时不分享，避免信息量过大。

### 3.2.1 获得内容

```java
String getContent();

boolean hasContent();
```

- 获得配置文件的内容。这个是 Config 和 Config **最大**的差异。

### 3.2.2 获得 Namespace 名字

```java
String getNamespace();

ConfigFileFormat getConfigFileFormat();
```

### 3.2.3 添加配置文件变化监听器

```java
void addChangeListener(ConfigFileChangeListener listener);
```

#### 3.2.3.1 ConfigFileChangeListener

`com.ctrip.framework.apollo.ConfigFileChangeListener` **接口**，代码如下：

```java
public interface ConfigFileChangeListener {
  /**
   * Invoked when there is any config change for the namespace.
   * @param changeEvent the event for this change
   */
  void onChange(ConfigFileChangeEvent changeEvent);
}
```

#### 3.2.3.2 ConfigFileChangeEvent

`com.ctrip.framework.apollo.model.ConfigFileChangeEvent` ，**配置文件**改变事件。代码如下：

```java
public class ConfigFileChangeEvent {

    /**
     * Namespace 名字
     */
    private final String namespace;
    /**
     * 老值
     */
    private final String oldValue;
    /**
     * 新值
     */
    private String newValue;
    /**
     * 变化类型
     */
    private final PropertyChangeType changeType;
}
```

# 4. ConfigManager

`com.ctrip.framework.apollo.internals.ConfigManager` ，配置**管理器**接口。提供获得 Config 和 ConfigFile 对象的接口，代码如下：

```java
public interface ConfigManager {

    /**
     * Get the config instance for the namespace specified.
     *
     * @param namespace the namespace
     * @return the config instance for the namespace
     */
    Config getConfig(String namespace);

    /**
     * Get the config file instance for the namespace specified.
     *
     * @param namespace        the namespace
     * @param configFileFormat the config file format
     * @return the config file instance for the namespace
     */
    ConfigFile getConfigFile(String namespace, ConfigFileFormat configFileFormat);

}
```

## 4.1 DefaultConfigManager

`com.ctrip.framework.apollo.internals.DefaultConfigManager` ，实现 ConfigManager 接口，**默认**配置管理器**实现类**。

### 4.1.1 构造方法

```java
public class DefaultConfigManager implements ConfigManager {
  private ConfigFactoryManager m_factoryManager;

  private Map<String, Config> m_configs = Maps.newConcurrentMap(); // Config 对象的缓存
  private Map<String, ConfigFile> m_configFiles = Maps.newConcurrentMap(); // ConfigFile 对象的缓存

  public DefaultConfigManager() {
    m_factoryManager = ApolloInjector.getInstance(ConfigFactoryManager.class);
  }

  // ... 省略其他接口和属性
}
```

- 当需要获得的 Config 或 ConfigFile 对象**不在缓存**中时，通过 ConfigFactoryManager ，获得对应的 ConfigFactory 对象，从而创建 Config 或 ConfigFile 对象。

### 4.1.2 获得 Config 对象

```java
@Override
public Config getConfig(String namespace) {
  Config config = m_configs.get(namespace); // 获得 Config 对象
  // 若不存在，进行创建
  if (config == null) {
    synchronized (this) {
      config = m_configs.get(namespace); // 获得 Config 对象

      if (config == null) {
        ConfigFactory factory = m_factoryManager.getFactory(namespace); // 获得对应的 ConfigFactory 对象
        // 创建 Config 对象
        config = factory.create(namespace);
        m_configs.put(namespace, config);  // 添加到缓存
      }
    }
  }

  return config;
}
```

### 4.1.3 获得 ConfigFile 对象

```java
@Override
public ConfigFile getConfigFile(String namespace, ConfigFileFormat configFileFormat) {
  String namespaceFileName = String.format("%s.%s", namespace, configFileFormat.getValue()); // 拼接 Namespace 名字
  ConfigFile configFile = m_configFiles.get(namespaceFileName); // 将 ConfigFileFormat 拼接到 namespace 中

  if (configFile == null) { // 若不存在，进行创建
    synchronized (this) {
      configFile = m_configFiles.get(namespaceFileName);  // 获得 ConfigFile 对象

      if (configFile == null) { // 若不存在，进行创建
        ConfigFactory factory = m_factoryManager.getFactory(namespaceFileName); // 获得对应的 ConfigFactory 对象
        // 创建 ConfigFile 对象
        configFile = factory.createConfigFile(namespaceFileName, configFileFormat);
        m_configFiles.put(namespaceFileName, configFile); // 添加到缓存
      }
    }
  }

  return configFile;
}
```

- 和 `#getConfig(namespace)` 方法，**基本一致**。

# 5. “工厂”们

本小节的标题，严格来说，是不严谨的，但是考虑到更好的归类，因此就这么叫啦。😈

## 5.1 ConfigFactoryManager

`com.ctrip.framework.apollo.spi.ConfigFactoryManager` ，ConfigFactory **管理器**接口。代码如下：

````java
public interface ConfigFactoryManager {

    /**
     * Get the config factory for the namespace.
     *
     * @param namespace the namespace
     * @return the config factory for this namespace
     */
    ConfigFactory getFactory(String namespace);

}
````

- ConfigFactoryManager 管理的是 ConfigFactory ，而 ConfigManager 管理的是 Config 。

### 5.1.1 DefaultConfigFactoryManager

`com.ctrip.framework.apollo.spi.DefaultConfigFactoryManager` ，ConfigFactoryManager 接口，默认 ConfigFactory 管理器实现类。代码如下：

```java
public class DefaultConfigFactoryManager implements ConfigFactoryManager {
  private ConfigRegistry m_registry;
  // ConfigFactory 对象的缓存
  private Map<String, ConfigFactory> m_factories = Maps.newConcurrentMap();

  public DefaultConfigFactoryManager() {
    m_registry = ApolloInjector.getInstance(ConfigRegistry.class);
  }

  @Override
  public ConfigFactory getFactory(String namespace) {
    // step 1: check hacked factory. 从 ConfigRegistry 中，获得 ConfigFactory 对象
    ConfigFactory factory = m_registry.getFactory(namespace);

    if (factory != null) {
      return factory;
    }

    // step 2: check cache. 从缓存中，获得 ConfigFactory 对象
    factory = m_factories.get(namespace);

    if (factory != null) {
      return factory;
    }

    // step 3: check declared config factory. 从 ApolloInjector 中，获得指定 Namespace 的 ConfigFactory 对象
    factory = ApolloInjector.getInstance(ConfigFactory.class, namespace);

    if (factory != null) {
      return factory;
    }

    // step 4: check default config factory. 从 ApolloInjector 中，获得默认的 ConfigFactory 对象
    factory = ApolloInjector.getInstance(ConfigFactory.class);
    // 更新到缓存中
    m_factories.put(namespace, factory);

    // factory should not be null
    return factory;
  }
}
```

- 总的来说，DefaultConfigFactoryManager 的 ConfigFactory**来源**有两个：
  - ConfigRegistry
  - ApolloInjector ，**优先**指定 Namespace **自定义**的 ConfigFactory 对象，否则**默认**的 ConfigFactory 对象。

大多数情况下，使用 `step 2` 和 `step 4` 从 ApolloInjector 中，获得**默认**的 ConfigFactory 对象。

## 5.2 ConfigFactory

`com.ctrip.framework.apollo.spi.ConfigFactory` ，配置工厂**接口**，其每个接口方法和 ConfigManager **一一**对应。代码如下：

```java
public interface ConfigFactory {

    /**
     * Create the config instance for the namespace.
     *
     * @param namespace the namespace
     * @return the newly created config instance
     */
    Config create(String namespace);

    /**
     * Create the config file instance for the namespace
     *
     * @param namespace the namespace
     * @return the newly created config file instance
     */
    ConfigFile createConfigFile(String namespace, ConfigFileFormat configFileFormat);

}
```

### 5.2.1 DefaultConfigFactory

`com.ctrip.framework.apollo.spi.DefaultConfigFactory` ，实现 ConfigFactory 接口，默认配置工厂实现类。

#### 5.2.1.1 构造方法

```java
public class DefaultConfigFactory implements ConfigFactory {

  private static final Logger logger = LoggerFactory.getLogger(DefaultConfigFactory.class);
  private final ConfigUtil m_configUtil;

  public DefaultConfigFactory() {
    m_configUtil = ApolloInjector.getInstance(ConfigUtil.class);
  }
  // ... 省略其他接口和属性
}
```

#### 5.2.1.2 创建 Config 对象

```java
@Override
public Config create(String namespace) {
  ConfigFileFormat format = determineFileFormat(namespace);

  ConfigRepository configRepository = null;

  // although ConfigFileFormat.Properties are compatible with themselves we
  // should not create a PropertiesCompatibleFileConfigRepository for them
  // calling the method `createLocalConfigRepository(...)` is more suitable
  // for ConfigFileFormat.Properties
  if (ConfigFileFormat.isPropertiesCompatible(format) &&
      format != ConfigFileFormat.Properties) {
    configRepository = createPropertiesCompatibleFileConfigRepository(namespace, format);
  } else {
    configRepository = createConfigRepository(namespace);
  }

  logger.debug("Created a configuration repository of type [{}] for namespace [{}]",
      configRepository.getClass().getName(), namespace);

  return this.createRepositoryConfig(namespace, configRepository);
}

protected Config createRepositoryConfig(String namespace, ConfigRepository configRepository) {
  return new DefaultConfig(namespace, configRepository);
}
```

- 调用 `#createLocalConfigRepository(name)` 方法，创建 LocalConfigRepository 对象。作为后面创建的 DefaultConfig 对象的 Config**Repository** 。

#### 5.2.1.3 创建 FileConfig 对象

```java
@Override
public ConfigFile createConfigFile(String namespace, ConfigFileFormat configFileFormat) {
  ConfigRepository configRepository = createConfigRepository(namespace); // 创建 ConfigRepository 对象
  switch (configFileFormat) { // 创建对应的 ConfigFile 对象
    case Properties:
      return new PropertiesConfigFile(namespace, configRepository);
    case XML:
      return new XmlConfigFile(namespace, configRepository);
    case JSON:
      return new JsonConfigFile(namespace, configRepository);
    case YAML:
      return new YamlConfigFile(namespace, configRepository);
    case YML:
      return new YmlConfigFile(namespace, configRepository);
    case TXT:
      return new TxtConfigFile(namespace, configRepository);
  }

  return null;
}
```

- 调用 `#createLocalConfigRepository(name)` 方法，创建 LocalConfigRepository 对象。作为后面创建的 XXXConfigFile 对象的 Config**Repository** 。

#### 5.2.1.4 创建 LocalConfigRepository 对象

```java
ConfigRepository createConfigRepository(String namespace) {
  if (m_configUtil.isPropertyFileCacheEnabled()) { // 本地模式，使用 LocalFileConfigRepository 对象
    return createLocalConfigRepository(namespace);
  }
  return createRemoteConfigRepository(namespace);  // 非本地模式，使用 LocalFileConfigRepository + RemoteConfigRepository 对象
}
```

- 根据是否为**本地模式**，**单独**使用 LocalFileConfigRepository 还是**组合**使用 LocalFileConfigRepository + RemoteConfigRepository 。

- 那么什么是本地模式呢？`ConfigUtil#isPropertyFileCacheEnabled()` 方法，代码如下：

  ```java
  // ConfigUtil.java
  public boolean isPropertyFileCacheEnabled() {
    return propertyFileCacheEnabled;
  }
  
  private void initPropertyFileCacheEnabled() {
    propertyFileCacheEnabled = getPropertyBoolean(ApolloClientSystemConsts.APOLLO_CACHE_FILE_ENABLE,
            ApolloClientSystemConsts.APOLLO_CACHE_FILE_ENABLE_ENVIRONMENT_VARIABLES,
            propertyFileCacheEnabled);
  }
  ```

- 那么什么是 ConfigRepository 是什么呢？这里我们可以简单( *但不完全准确* )理解成配置的 **Repository** ，负责从远程的 Config Service 读取配置。详细解析，见 [《Apollo 源码解析 —— 客户端 API 配置（四）之 ConfigRepository》](http://www.iocoder.cn/Apollo/client-config-api-4/self) 。

## 5.3 ConfigRegistry

`com.ctrip.framework.apollo.spi.ConfigRegistry` ，Config **注册表**接口。其中，KEY 为 Namespace 的名字，VALUE 为 ConfigFactory 对象。代码如下：

```java
public interface ConfigRegistry {
  /**
   * Register the config factory for the namespace specified.
   *
   * @param namespace the namespace
   * @param factory   the factory for this namespace
   */
  void register(String namespace, ConfigFactory factory);

  /**
   * Get the registered config factory for the namespace.
   *
   * @param namespace the namespace
   * @return the factory registered for this namespace
   */
  ConfigFactory getFactory(String namespace);
}
```

### 5.3.1 DefaultConfigRegistry

`com.ctrip.framework.apollo.spi.DefaultConfigRegistry` ，实现 ConfigRegistry 接口，默认 ConfigFactory **管理器**实现类。代码如下：

```java
public class DefaultConfigRegistry implements ConfigRegistry {
  private static final Logger s_logger = LoggerFactory.getLogger(DefaultConfigRegistry.class);
  private Map<String, ConfigFactory> m_instances = Maps.newConcurrentMap();

  @Override
  public void register(String namespace, ConfigFactory factory) {
    if (m_instances.containsKey(namespace)) { // 覆盖的情况，打印警告日志
      s_logger.warn("ConfigFactory({}) is overridden by {}!", namespace, factory.getClass());
    }

    m_instances.put(namespace, factory);
  }

  @Override
  public ConfigFactory getFactory(String namespace) {
    ConfigFactory config = m_instances.get(namespace);

    return config;
  }
}
```

## 5.4 ApolloInjector

`com.ctrip.framework.apollo.build.ApolloInjector` ，Apollo 注入器，实现依赖注入( **DI**，全称“**Dependency Injection**” ) 。

**构造方法**

```java
private static volatile Injector s_injector; // 注入器
private static final Object lock = new Object(); // 锁
```

- `s_injector` **静态**属性，**真正**的注入器对象。通过 `#getInjector()` **静态**方法获得。代码如下：

  ```java
  private static Injector getInjector() {
      // 若 Injector 不存在，则进行获得
      if (s_injector == null) {
          synchronized (lock) {
              // 若 Injector 不存在，则进行获得
              if (s_injector == null) {
                  try {
                      // 基于 JDK SPI 加载对应的 Injector 实现对象
                      s_injector = ServiceBootstrap.loadFirst(Injector.class);
                  } catch (Throwable ex) {
                      ApolloConfigException exception = new ApolloConfigException("Unable to initialize Apollo Injector!", ex);
                      Tracer.logError(exception);
                      throw exception;
                  }
              }
          }
      }
      return s_injector;
  }
  ```

  - 调用 `com.ctrip.framework.foundation.internals.ServiceBootstrap#loadFirst(Class<S>)` 方法，基于 **JDK SPI** 机制，加载指定服务的**首个**对象。代码如下：

    ```java
    public class ServiceBootstrap {
    
        /**
         * 加载指定服务的首个对象
         *
         * @param clazz 服务类
         * @param <S> 泛型
         * @return 对象
         */
        public static <S> S loadFirst(Class<S> clazz) {
            Iterator<S> iterator = loadAll(clazz);
            if (!iterator.hasNext()) {
                throw new IllegalStateException(String.format("No implementation defined in /META-INF/services/%s, please check whether the file exists and has the right implementation class!", clazz.getName()));
            }
            return iterator.next();
        }
    
        /**
         * 基于 JDK SPI ，加载指定类的所有对象
         *
         * @param clazz 服务类
         * @param <S> 泛型
         * @return 所有对象
         */
        private static <S> Iterator<S> loadAll(Class<S> clazz) {
            ServiceLoader<S> loader = ServiceLoader.load(clazz); // JDK SPI
            return loader.iterator();
        }
    
    }
    ```

    - 在 `META-INF/services/com.ctrip.framework.apollo.internals.Injector` 中，配置 Injector 的实现类为 DefaultInjector ，如下：

      ```properties
      com.ctrip.framework.apollo.internals.DefaultInjector
      ```

------

**获得实例**

```java
public static <T> T getInstance(Class<T> clazz) {
    try {
        return getInjector().getInstance(clazz);
    } catch (Throwable ex) {
        Tracer.logError(ex);
        throw new ApolloConfigException(String.format("Unable to load instance for type %s!", clazz.getName()), ex);
    }
}

public static <T> T getInstance(Class<T> clazz, String name) {
    try {
        return getInjector().getInstance(clazz, name);
    } catch (Throwable ex) {
        Tracer.logError(ex);
        throw new ApolloConfigException(
                String.format("Unable to load instance for type %s and name %s !", clazz.getName(), name), ex);
    }
}
```

### 5.4.1 Injector

`com.ctrip.framework.apollo.internals.Injector` ，注入器接口。代码如下：

```java
public interface Injector {

    /**
     * Returns the appropriate instance for the given injection type
     */
    <T> T getInstance(Class<T> clazz);

    /**
     * Returns the appropriate instance for the given injection type and name
     */
    <T> T getInstance(Class<T> clazz, String name);

}
```

### 5.4.2 DefaultInjector

`com.ctrip.framework.apollo.internals.DefaultInjector` ，实现 DefaultInjector 接口，基于 **Guice** 的注入器实现类。

考虑到 Apollo 会被**引入**项目中，尽量减少对 Spring 的依赖。但是呢，自身又有 **DI** 特性的需要，那么引入 Google Guice 是非常好的选择。不了解的胖友，可以阅读 [《通过 Guice 进行依赖项注入》](https://www.ibm.com/developerworks/cn/java/j-guice.html) 。

**构造方法**

```java
public class DefaultInjector implements Injector {
  private final com.google.inject.Injector m_injector;
  private final List<ApolloInjectorCustomizer> m_customizers;

  public DefaultInjector() {
    try {
      m_injector = Guice.createInjector(new ApolloModule());
      m_customizers = ServiceBootstrap.loadAllOrdered(ApolloInjectorCustomizer.class);
    } catch (Throwable ex) {
      ApolloConfigException exception = new ApolloConfigException("Unable to initialize Guice Injector!", ex);
      Tracer.logError(exception);
      throw exception;
    }
  }
  // ... 省略其他接口和属性
}
```

- 使用 ApolloModule 类，告诉 Guice 需要 **DI** 的配置。代码如下：

  ```java
  private static class ApolloModule extends AbstractModule {
    @Override
    protected void configure() {
      bind(ConfigManager.class).to(DefaultConfigManager.class).in(Singleton.class);
      bind(ConfigFactoryManager.class).to(DefaultConfigFactoryManager.class).in(Singleton.class);
      bind(ConfigRegistry.class).to(DefaultConfigRegistry.class).in(Singleton.class);
      bind(ConfigFactory.class).to(DefaultConfigFactory.class).in(Singleton.class);
      bind(ConfigUtil.class).in(Singleton.class);
      bind(HttpClient.class).to(DefaultHttpClient.class).in(Singleton.class);
      bind(ConfigServiceLocator.class).in(Singleton.class);
      bind(RemoteConfigLongPollService.class).in(Singleton.class);
      bind(YamlParser.class).in(Singleton.class);
      bind(PropertiesFactory.class).to(DefaultPropertiesFactory.class).in(Singleton.class);
    }
  }
  ```

------

**获得实例**

```java
@Override
public <T> T getInstance(Class<T> clazz) {
  try {
    for (ApolloInjectorCustomizer customizer : m_customizers) {
      T instance = customizer.getInstance(clazz);
      if (instance != null) {
        return instance;
      }
    }
    return m_injector.getInstance(clazz);
  } catch (Throwable ex) {
    Tracer.logError(ex);
    throw new ApolloConfigException(
        String.format("Unable to load instance for %s!", clazz.getName()), ex);
  }
}

@Override
public <T> T getInstance(Class<T> clazz, String name) {
  try {
    for (ApolloInjectorCustomizer customizer : m_customizers) {
      T instance = customizer.getInstance(clazz, name);
      if (instance != null) {
        return instance;
      }
    }
    //Guice does not support get instance by type and name
    return null;
  } catch (Throwable ex) {
    Tracer.logError(ex);
    throw new ApolloConfigException(
        String.format("Unable to load instance for %s with name %s!", clazz.getName(), name), ex);
  }
}
```

- 🙂 指定 `name` 的暂时未实现，因为 Guice does not support get instance by type and name 。



# 参考

[Apollo 源码解析 —— 客户端 API 配置（一）之一览](https://www.iocoder.cn/Apollo/client-config-api-1/)







