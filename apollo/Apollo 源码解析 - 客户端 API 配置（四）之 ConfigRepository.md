# 1. 概述

> 老艿艿：本系列假定胖友已经阅读过 [《Apollo 官方 wiki 文档》](https://github.com/ctripcorp/apollo/wiki/) ，特别是 [《Java 客户端使用指南》](https://github.com/ctripcorp/apollo/wiki/Apollo开放平台) 。

本文接 [《Apollo 源码解析 —— 客户端 API 配置（二）之一览》](http://www.iocoder.cn/Apollo/client-config-api-2/?self) 一文，分享 ConfigRepository 接口，及其子类，如下图：

<img src="http://blog-1259650185.cosbj.myqcloud.com/img/202204/09/1649475883.png" alt="ConfigRepository 类图" style="zoom:67%;" />

- ConfigRepository、AbstractConfigRepository、RemoteConfigRepository ，在 [《Apollo 源码解析 —— Client 轮询配置》](http://www.iocoder.cn/Apollo/client-polling-config/?self) 中已经完整解析，所以本文**仅分享** LocalConfigRepository 的实现。

在 [《Apollo 源码解析 —— 客户端 API 配置（一）之一览》](http://www.iocoder.cn/Apollo/client-config-api-1/?self) 的 [「5.2.1.4 创建 LocalConfigRepository 对象」](https://www.iocoder.cn/Apollo/client-config-api-4/#) 中，我们简单定义 ConfigRepository 如下：

> 这里我们可以简单( *但不完全准确* )理解成配置的 **Repository** ，负责从远程的 Config Service 读取配置。

- 为什么笔者会说 *但不完全准确* 呢？答案在 LocalConfigRepository 的实现中。

# 2. LocalFileConfigRepository

`com.ctrip.framework.apollo.internals.LocalFileConfigRepository` ，*实现 RepositoryChangeListener 接口*，继承 AbstractConfigRepository 抽象类，**本地文件**配置 Repository 实现类。

> 重点在 [「2. 6 sync」](https://www.iocoder.cn/Apollo/client-config-api-4/#) 方法。

## 2.1 构造方法

````java
public class LocalFileConfigRepository extends AbstractConfigRepository
    implements RepositoryChangeListener {
  private static final Logger logger = DeferredLoggerFactory.getLogger(LocalFileConfigRepository.class);
  private static final String CONFIG_DIR = "/config-cache"; // 配置文件目录
  private final String m_namespace; // Namespace 名字
  private File m_baseDir; // 本地缓存配置文件目录
  private final ConfigUtil m_configUtil;
  private volatile Properties m_fileProperties; // 配置文件 Properties
  private volatile ConfigRepository m_upstream; // 上游的 ConfigRepository 对象。一般情况下，使用 RemoteConfigRepository 对象，读取远程 Config Service 的配置

  private volatile ConfigSourceType m_sourceType = ConfigSourceType.LOCAL;

  /**
   * Constructor.
   *
   * @param namespace the namespace
   */
  public LocalFileConfigRepository(String namespace) {
    this(namespace, null);
  }

  public LocalFileConfigRepository(String namespace, ConfigRepository upstream) {
    m_namespace = namespace;
    m_configUtil = ApolloInjector.getInstance(ConfigUtil.class);
    this.setLocalCacheDir(findLocalCacheDir(), false); // 获得本地缓存配置文件的目录
    this.setUpstreamRepository(upstream);  // 设置 m_upstream 属性
    this.trySync(); // 同步配置
  }
  
  // ... 省略其他接口和属性
}
````

- `m_baseDir` 字段，**本地缓存**配置文件**目录**( 😈 *比较好奇的是，为什么不直接是配置文件，而是配置文件目录，从代码看下来是非目录啊* )。在构造方法中，进行初始化，胖友先跳到 [「2.2 findLocalCacheDir」](https://www.iocoder.cn/Apollo/client-config-api-4/#) 和 [「2.3 setLocalCacheDir」](https://www.iocoder.cn/Apollo/client-config-api-4/#) 。
- `m_fileProperties` 字段，配置文件 Properties 。
- `m_upstream` 字段，**上游**的 ConfigRepository 对象。一般情况下，使用 **RemoteConfigRepository** 对象，读取远程 Config Service 的配置。在构造方法中，调用 `#setUpstreamRepository(ConfigRepository)` 方法，设置 `m_upstream` 属性，**初始**拉取 Config Service 的配置，并**监听**配置变化。详细解析，胖友先跳到 [「2.4 setUpstreamRepository」](https://www.iocoder.cn/Apollo/client-config-api-4/#) 。
- 调用 `#trySync()` 方法，同步配置。详细解析，见 [「2.6 sync」](https://www.iocoder.cn/Apollo/client-config-api-4/#) 。

## 2.2 findLocalCacheDir

`#findLocalCacheDir()` 方法，获得本地缓存目录。代码如下：

```java
private File findLocalCacheDir() {
  try {
    String defaultCacheDir = m_configUtil.getDefaultLocalCacheDir(); // 获得默认缓存配置目录
    Path path = Paths.get(defaultCacheDir); // 若不存在该目录，进行创建
    if (!Files.exists(path)) {
      Files.createDirectories(path);
    }
    if (Files.exists(path) && Files.isWritable(path)) { // 返回该目录下的 CONFIG_DIR 目录
      return new File(defaultCacheDir, CONFIG_DIR);
    }
  } catch (Throwable ex) {
    //ignore
  }
  // 若失败，使用 ClassPath 下的 CONFIG_DIR 目录
  return new File(ClassLoaderUtil.getClassPath(), CONFIG_DIR);
}
```

- 调用 `ConfigUtil#getDefaultLocalCacheDir()` 方法，获得**默认**缓存配置目录。代码如下：

  ```
  public String getDefaultLocalCacheDir() {
      String cacheRoot = isOSWindows() ? "C:\\opt\\data\\%s" : "/opt/data/%s";
      return String.format(cacheRoot, getAppId()); // appId
  }
  ```

  - 在非 Windows 的环境下，是`/opt/data/${appId}`目录。
    - 调用 `Files#exists(path)` 方法，判断若**默认**缓存配置目录不存在，进行创建。😈**但是**，可能我们的应用程序没有该目录的权限，此时会导致创建失败。那么就有会出现两种情况：
  - 第一种，**有权限**，使用 `/opt/data/${appId}/` + `config-cache` 目录。
  - 第二种，**无权限**，使用 **ClassPath/** + `config-cache` 目录。这个目录，应用程序下，肯定是有权限的。

## 2.3 setLocalCacheDir

调用 `#setLocalCacheDir(baseDir, syncImmediately)` 方法，设置 `m_baseDir` 字段。代码如下：

```java
void setLocalCacheDir(File baseDir, boolean syncImmediately) {
    m_baseDir = baseDir;
    // 获得本地缓存配置文件的目录
    this.checkLocalConfigCacheDir(m_baseDir);
    // 若需要立即同步，则进行同步
    if (syncImmediately) {
        this.trySync();
    }
}
```

- 调用 `#checkLocalConfigCacheDir(baseDir)` 方法，校验本地缓存**配置目录**是否存在。若不存在，则进行创建。详细解析，见 [「2.3.1 checkLocalConfigCacheDir」](https://www.iocoder.cn/Apollo/client-config-api-4/#) 。
- 若 `syncImmediately = true` ，则进行同步。目前仅在**单元测试**中，会出现这种情况。正式的代码，`syncImmediately = false` 。

### 2.3.1 checkLocalConfigCacheDir

`#checkLocalConfigCacheDir(baseDir)` 方法，校验本地缓存**配置目录**是否存在。若不存在，则进行创建。代码如下：

```java
private void checkLocalConfigCacheDir(File baseDir) {
  if (baseDir.exists()) { // 若本地缓存配置文件的目录已经存在，则返回
    return;
  }
  Transaction transaction = Tracer.newTransaction("Apollo.ConfigService", "createLocalConfigDir");
  transaction.addData("BaseDir", baseDir.getAbsolutePath());
  try {
    Files.createDirectory(baseDir.toPath()); // 创建本地缓存配置目录
    transaction.setStatus(Transaction.SUCCESS);
  } catch (IOException ex) {
    ApolloConfigException exception =
        new ApolloConfigException(
            String.format("Create local config directory %s failed", baseDir.getAbsolutePath()),
            ex);
    Tracer.logError(exception);
    transaction.setStatus(exception);
    logger.warn(
        "Unable to create local config cache directory {}, reason: {}. Will not able to cache config file.",
        baseDir.getAbsolutePath(), ExceptionUtil.getDetailMessage(ex));
  } finally {
    transaction.complete();
  }
}
```

- 是不是有点懵逼？该方法**校验**和**创建**的 `config-cache` 目录。这个目录在 `#findLocalCacheDir()` 方法中，**并未**创建。

### 2.3.2 assembleLocalCacheFile

那么完整的缓存配置文件到底路径是什么呢？`${baseDir}/config-cache/` + `${appId}+${cluster} + ${namespace}.properties` ，即 `#assembleLocalCacheFile(baseDir, namespace)` 方法，拼接完整的本地缓存配置文件的地址。代码如下：

```java
File assembleLocalCacheFile(File baseDir, String namespace) {
    String fileName = String.format("%s.properties", Joiner.on(ConfigConsts.CLUSTER_NAMESPACE_SEPARATOR) // + 号分隔
            .join(m_configUtil.getAppId(), m_configUtil.getCluster(), namespace));
    return new File(baseDir, fileName);
}
```

- 这也是笔者疑惑的，【配置文件】是可以固定下来的。

### 2.3.3 loadFromLocalCacheFile

`#loadFromLocalCacheFile(baseDir, namespace)` 方法，**从**缓存配置文件，**读取** Properties 。代码如下：

```java
private Properties loadFromLocalCacheFile(File baseDir, String namespace) throws IOException {
  Preconditions.checkNotNull(baseDir, "Basedir cannot be null");
  // 拼接本地缓存的配置文件 File 对象
  File file = assembleLocalCacheFile(baseDir, namespace);
  Properties properties = null;
  // 从文件中，读取 Properties
  if (file.isFile() && file.canRead()) {
    InputStream in = null;

    try {
      in = new FileInputStream(file);
      properties = propertiesFactory.getPropertiesInstance();
      properties.load(in);  // 读取
      logger.debug("Loading local config file {} successfully!", file.getAbsolutePath());
    } catch (IOException ex) {
      Tracer.logError(ex);
      throw new ApolloConfigException(String
          .format("Loading config from local cache file %s failed", file.getAbsolutePath()), ex);
    } finally {
      try {
        if (in != null) {
          in.close();
        }
      } catch (IOException ex) {
        // ignore
      }
    }
  } else {
    throw new ApolloConfigException(
        String.format("Cannot read from local cache file %s", file.getAbsolutePath()));
  }

  return properties;
}
```

### 2.3.4 persistLocalCacheFile

`#loadFromLocalCacheFile(baseDir, namespace)` 方法，**向**缓存配置文件，写入 Properties 。代码如下：

> 和 `#loadFromLocalCacheFile(baseDir, namespace)` 方法，相反。

```
void persistLocalCacheFile(File baseDir, String namespace) {
  if (baseDir == null) {
    return;
  }
  File file = assembleLocalCacheFile(baseDir, namespace); // 拼接本地缓存的配置文件 File 对象
  // 向文件中，写入 Properties
  OutputStream out = null;

  Transaction transaction = Tracer.newTransaction("Apollo.ConfigService", "persistLocalConfigFile");
  transaction.addData("LocalConfigFile", file.getAbsolutePath());
  try {
    out = new FileOutputStream(file);
    m_fileProperties.store(out, "Persisted by DefaultConfig"); // 写入
    transaction.setStatus(Transaction.SUCCESS);
  } catch (IOException ex) {
    ApolloConfigException exception =
        new ApolloConfigException(
            String.format("Persist local cache file %s failed", file.getAbsolutePath()), ex);
    Tracer.logError(exception);
    transaction.setStatus(exception);
    logger.warn("Persist local cache file {} failed, reason: {}.", file.getAbsolutePath(),
        ExceptionUtil.getDetailMessage(ex));
  } finally {
    if (out != null) {
      try {
        out.close();
      } catch (IOException ex) {
        //ignore
      }
    }
    transaction.complete();
  }
}
```

### 2.3.5 updateFileProperties

`#updateFileProperties(newProperties)` 方法，若 Properties 发生**变化**，**向**缓存配置文件，写入 Properties 。代码如下：

> 老艿艿：在 `#persistLocalCacheFile(baseDir, namespace)` 方法，进一步封装。

```java
private synchronized void updateFileProperties(Properties newProperties, ConfigSourceType sourceType) {
  this.m_sourceType = sourceType;
  if (newProperties.equals(m_fileProperties)) { // 忽略，若未变更
    return;
  }
  this.m_fileProperties = newProperties; // 设置新的 Properties 到 m_fileProperties 中。
  persistLocalCacheFile(m_baseDir, m_namespace); // 持久化到本地缓存配置文件
}
```

## 2.4 setUpstreamRepository

`#setUpstreamRepository(ConfigRepository)` 方法，设置 `m_upstream` 属性，**初始**拉取 Config Service 的配置，并**监听**配置变化。代码如下：

> 老艿艿：此处 ConfigRepository 以 RemoteConfigRepository 举例子。实际代码实现里，也是它。

```java
@Override
public void setUpstreamRepository(ConfigRepository upstreamConfigRepository) {
  if (upstreamConfigRepository == null) {
    return;
  }
  //clear previous listener  // 从老的 m_upstream 移除自己
  if (m_upstream != null) {
    m_upstream.removeChangeListener(this);
  }
  m_upstream = upstreamConfigRepository;  // 设置新的 m_upstream
  upstreamConfigRepository.addChangeListener(this);  // 向新的 m_upstream 注册自己
}
```

- 第 6 至 10 行：调用 `ConfigRepository#removeChangeListener(RepositoryChangeLister)` 方法，从**老**的 `m_upstream` 中，移除自己( 监听器 )。否则，会**错误**监听。
- 第 12 行：设置**新**的 `m_upstream` 。
- 第 14 行：调用 `#trySyncFromUpstream()` 方法，从 `m_upstream` 拉取**初始**配置。详细解析，见 [「2.5 trySyncFromUpstream」](https://www.iocoder.cn/Apollo/client-config-api-4/#) 。
- 第 16 行：调用 `ConfigRepository#addChangeListener(RepositoryChangeLister)` 方法，向**新**的 `m_upstream` 中，注册自己( 监听器 ) 。从而实现 Config Service 配置**变更**的监听。这也是为什么 LocalFileConfigRepository 实现了 RepositoryChangeListener 接口的**原因**。整体的监听和通知如下图：![流程](http://blog-1259650185.cosbj.myqcloud.com/img/202204/09/1649477426.png)

## 2.5 trySyncFromUpstream

`#trySyncFromUpstream()` 方法，从 `m_upstream` 拉取**初始**配置，并返回**是否**拉取成功。代码如下：

```java
private boolean trySyncFromUpstream() {
  if (m_upstream == null) {
    return false;
  }
  try {
    updateFileProperties(m_upstream.getConfig(), m_upstream.getSourceType()); // 从 m_upstream 拉取配置 Properties，更新到 m_fileProperties 中
    return true; // 返回同步成功
  } catch (Throwable ex) {
    Tracer.logError(ex);
    logger
        .warn("Sync config from upstream repository {} failed, reason: {}", m_upstream.getClass(),
            ExceptionUtil.getDetailMessage(ex));
  }
  return false;
}
```

- 第 2 至 4 行：当 `m_upstream` 为空时，返回拉取**失败** `false` 。
- 第 7 行：调用 `ConfigRepository#getConfig()` 方法，从 `m_upstream` 拉取配置 Properties 。
- 第 9 行：调用 `#updateFileProperties(properties)` 方法，更新到 `m_fileProperties` 中。
- 第 11 行：返回同步**成功** `true` 。
- 第 17 行：返回同步**失败** `false` 。

那么，为什么要返回**同步结果**呢？答案在 [「2.6 sync」](https://www.iocoder.cn/Apollo/client-config-api-4/#) 中。

## 2.6 sync

埋了这么多的伏笔( 代码 )，我们将要本文最重要的方法 `#sync()` ！！！

在**非本地模式**的情况下，LocalFileConfigRepository 在**初始化**时，会首先从远程 Config Service **同步**( 加载 )配置。若**同步**(加载)**失败**，则读取本地**缓存**的配置文件。

在**本地模式**的情况下，则**只读取**本地**缓存**的配置文件。当然，严格来说，也不一定是**缓存**，可以是开发者，手动**创建**的配置文件。

实现代码如下：

```java
@Override
protected void sync() { // 在非本地模式的情况下，LocalFileConfigRepository 在初始化时，会首先从远程 Config Service 同步( 加载 )配置。若同步(加载)失败，则读取本地缓存的配置文件
  //sync with upstream immediately // 从 m_upstream 同步配置
  boolean syncFromUpstreamResultSuccess = trySyncFromUpstream();
  // 若成功，则直接返回
  if (syncFromUpstreamResultSuccess) {
    return;
  }
  // 若失败，读取本地缓存的配置文件
  Transaction transaction = Tracer.newTransaction("Apollo.ConfigService", "syncLocalConfig");
  Throwable exception = null;
  try {
    transaction.addData("Basedir", m_baseDir.getAbsolutePath());
    m_fileProperties = this.loadFromLocalCacheFile(m_baseDir, m_namespace);  // 加载本地缓存的配置文件
    m_sourceType = ConfigSourceType.LOCAL; // 来源模式设置为本地模式
    transaction.setStatus(Transaction.SUCCESS);
  } catch (Throwable ex) {
    Tracer.logEvent("ApolloConfigException", ExceptionUtil.getDetailMessage(ex));
    transaction.setStatus(ex);
    exception = ex;
    //ignore
  } finally {
    transaction.complete();
  }

  if (m_fileProperties == null) { // 若未读取到缓存的配置文件，抛出异常
    m_sourceType = ConfigSourceType.NONE;
    throw new ApolloConfigException(
        "Load config from local config failed!", exception);
  }
}
```

- 结合代码**注释** + 上述说明，理解下具体的代码。

## 2.7 onRepositoryChange

当 RemoteRepositoryConfig 读取到配置变更时，调用 `#onRepositoryChange(name, newProperties)` 方法，更新 `m_fileProperties` ，并通知监听器们。代码如下：

```java
@Override
public void onRepositoryChange(String namespace, Properties newProperties) {
  if (newProperties.equals(m_fileProperties)) {  // 忽略，若未变更
    return;
  }
  Properties newFileProperties = propertiesFactory.getPropertiesInstance(); // 读取新的 Properties 对象
  newFileProperties.putAll(newProperties);
  updateFileProperties(newFileProperties, m_upstream.getSourceType()); // 更新到 m_fileProperties 中
  this.fireRepositoryChange(namespace, newProperties); // 发布 Repository 的配置发生变化，触发对应的监听器们
}

private synchronized void updateFileProperties(Properties newProperties, ConfigSourceType sourceType) {
  this.m_sourceType = sourceType;
  if (newProperties.equals(m_fileProperties)) { // 忽略，若未变更
    return;
  }
  this.m_fileProperties = newProperties; // 设置新的 Properties 到 m_fileProperties 中。
  persistLocalCacheFile(m_baseDir, m_namespace); // 持久化到本地缓存配置文件
}
```

## 2.8 getConfig

```java
@Override
public Properties getConfig() {
  if (m_fileProperties == null) { // 如果 m_fileProperties 为空，强制同步
    sync();
  }
  Properties result = propertiesFactory.getPropertiesInstance();
  result.putAll(m_fileProperties); // 返回新创建的 m_fileProperties 对象，避免原有对象被修改
  return result;
}
```



# 参考

[Apollo 源码解析 —— 客户端 API 配置（四）之 ConfigRepository](https://www.iocoder.cn/Apollo/client-config-api-4/)
