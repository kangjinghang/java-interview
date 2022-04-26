# 1. 概述

> 老艿艿：本系列假定胖友已经阅读过 [《Apollo 官方 wiki 文档》](https://github.com/ctripcorp/apollo/wiki/) 。

本文接 [《Apollo 源码解析 —— Config Service 通知配置变化》](http://www.iocoder.cn/Apollo/config-service-notifications//?self) 一文，分享 Config Service 配置读取的**接口**的实现。在上文，我们看到通知变化**接口**，**仅**返回**通知**相关的信息，而不包括**配置**相关的信息。所以 Config Service 需要提供配置读取的**接口**。

😈 为什么不在通知变化的同时，返回**最新的**配置信息呢？老艿艿请教了作者，下一篇文章进行分享。

OK，让我们开始看看具体的代码实现。

# 2. ConfigController

`com.ctrip.framework.apollo.configservice.controller.ConfigController` ，配置 Controller ，**仅**提供 `configs/{appId}/{clusterName}/{namespace:.+}` 接口，提供配置读取的功能。

## 2.1 构造方法

```java
@RestController
@RequestMapping("/configs")
public class ConfigController {
  private static final Splitter X_FORWARDED_FOR_SPLITTER = Splitter.on(",").omitEmptyStrings()
      .trimResults();
  private final ConfigService configService;
  private final AppNamespaceServiceWithCache appNamespaceService;
  private final NamespaceUtil namespaceUtil;
  private final InstanceConfigAuditUtil instanceConfigAuditUtil;
  private final Gson gson;

  private static final Type configurationTypeReference = new TypeToken<Map<String, String>>() {
      }.getType();

  public ConfigController(
      final ConfigService configService,
      final AppNamespaceServiceWithCache appNamespaceService,
      final NamespaceUtil namespaceUtil,
      final InstanceConfigAuditUtil instanceConfigAuditUtil,
      final Gson gson) {
    this.configService = configService;
    this.appNamespaceService = appNamespaceService;
    this.namespaceUtil = namespaceUtil;
    this.instanceConfigAuditUtil = instanceConfigAuditUtil;
    this.gson = gson;
  }
  // ... 省略其他方法

}
```

## 2.2 queryConfig

```java
@GetMapping(value = "/{appId}/{clusterName}/{namespace:.+}")
public ApolloConfig queryConfig(@PathVariable String appId, @PathVariable String clusterName,
                                @PathVariable String namespace,
                                @RequestParam(value = "dataCenter", required = false) String dataCenter,
                                @RequestParam(value = "releaseKey", defaultValue = "-1") String clientSideReleaseKey,
                                @RequestParam(value = "ip", required = false) String clientIp,
                                @RequestParam(value = "label", required = false) String clientLabel,
                                @RequestParam(value = "messages", required = false) String messagesAsString,
                                HttpServletRequest request, HttpServletResponse response) throws IOException {
  String originalNamespace = namespace;
  //strip out .properties suffix // 若 Namespace 名以 .properties 结尾，移除该结尾，并设置到 ApolloConfigNotification 中。例如 application.properties => application
  namespace = namespaceUtil.filterNamespaceName(namespace);
  //fix the character case issue, such as FX.apollo <-> fx.apollo // 获得归一化的 Namespace 名字。因为，客户端 Namespace 会填写错大小写
  namespace = namespaceUtil.normalizeNamespace(appId, namespace);
  // 若 clientIp 未提交，从 Request 中获取
  if (Strings.isNullOrEmpty(clientIp)) {
    clientIp = tryToGetClientIp(request);
  }
  // 解析 messagesAsString 参数，创建 ApolloNotificationMessages 对象
  ApolloNotificationMessages clientMessages = transformMessages(messagesAsString);
  // 创建 Release 数组
  List<Release> releases = Lists.newLinkedList();
  // 获得 Namespace 对应的 Release 对象
  String appClusterNameLoaded = clusterName;
  if (!ConfigConsts.NO_APPID_PLACEHOLDER.equalsIgnoreCase(appId)) {
    Release currentAppRelease = configService.loadConfig(appId, clientIp, clientLabel, appId, clusterName, namespace,
        dataCenter, clientMessages); // 获得 Release 对象

    if (currentAppRelease != null) {
      releases.add(currentAppRelease); // 添加到 Release 数组中
      //we have cluster search process, so the cluster name might be overridden
      appClusterNameLoaded = currentAppRelease.getClusterName(); // 获得 Release 对应的 Cluster 名字
    }
  }

  //if namespace does not belong to this appId, should check if there is a public configuration
  if (!namespaceBelongsToAppId(appId, namespace)) { // 若 Namespace 为关联类型，则获取关联的 Namespace 的 Release 对象
    Release publicRelease = this.findPublicConfig(appId, clientIp, clientLabel, clusterName, namespace,
        dataCenter, clientMessages); // 获得 Release 对象
    if (Objects.nonNull(publicRelease)) {
      releases.add(publicRelease); // 添加到 Release 数组中
    }
  }

  if (releases.isEmpty()) { // 若获得不到 Release ，返回状态码为 404 的响应
    response.sendError(HttpServletResponse.SC_NOT_FOUND,
        String.format(
            "Could not load configurations with appId: %s, clusterName: %s, namespace: %s",
            appId, clusterName, originalNamespace));
    Tracer.logEvent("Apollo.Config.NotFound",
        assembleKey(appId, clusterName, originalNamespace, dataCenter));
    return null;
  }
  // 记录 InstanceConfig
  auditReleases(appId, clusterName, dataCenter, clientIp, releases);
  // 计算 Config Service 的合并 ReleaseKey
  String mergedReleaseKey = releases.stream().map(Release::getReleaseKey)
          .collect(Collectors.joining(ConfigConsts.CLUSTER_NAMESPACE_SEPARATOR));

  if (mergedReleaseKey.equals(clientSideReleaseKey)) { // 对比 Client 的合并 Release Key 。若相等，说明没有改变，返回状态码为 304 的响应
    // Client side configuration is the same with server side, return 304
    response.setStatus(HttpServletResponse.SC_NOT_MODIFIED);
    Tracer.logEvent("Apollo.Config.NotModified",
        assembleKey(appId, appClusterNameLoaded, originalNamespace, dataCenter));
    return null;
  }
  // 创建 ApolloConfig 对象
  ApolloConfig apolloConfig = new ApolloConfig(appId, appClusterNameLoaded, originalNamespace,
      mergedReleaseKey);
  apolloConfig.setConfigurations(mergeReleaseConfigurations(releases));  // 合并 Release 的配置，并将结果设置到 ApolloConfig 中

  Tracer.logEvent("Apollo.Config.Found", assembleKey(appId, appClusterNameLoaded,
      originalNamespace, dataCenter));
  return apolloConfig;
}
```

- **GET `/configs/{appId}/{clusterName}/{namespace:.+}` 接口**，**指定 Namespace** 的配置读取。在 [《Apollo 官方文档 —— 其它语言客户端接入指南 —— 1.3 通过不带缓存的Http接口从Apollo读取配置》](https://github.com/ctripcorp/apollo/wiki/其它语言客户端接入指南#13-通过不带缓存的http接口从apollo读取配置) 中，有该接口的接口定义说明。

- `clientSideReleaseKey` 请求参数，客户端侧的 Release Key ，用于和获得的 Release 的 `releaseKey` 对比，判断是否有**配置**更新。

- `clientIp` 请求参数，客户端 IP ，用于**灰度发布**的功能。🙂 本文会跳过和灰度发布相关的内容，后续文章单独分享。

- `messagesAsString` 请求参数，客户端**当前请求的 Namespace** 的通知消息明细，在【第 23 行】中，调用 `#transformMessages(messagesAsString)` 方法，解析 `messagesAsString` 参数，创建 **ApolloNotificationMessages** 对象。在 [《Apollo 源码解析 —— Config Service 通知配置变化》](http://www.iocoder.cn/Apollo/config-service-notifications//?self) 中，我们已经看到**通知变更接口**返回的就包括 **ApolloNotificationMessages** 对象。`#transformMessages(messagesAsString)` 方法，代码如下：

  ```java
  ApolloNotificationMessages transformMessages(String messagesAsString) {
      ApolloNotificationMessages notificationMessages = null;
      if (!Strings.isNullOrEmpty(messagesAsString)) {
          try {
              notificationMessages = gson.fromJson(messagesAsString, ApolloNotificationMessages.class);
          } catch (Throwable ex) {
              Tracer.logError(ex);
          }
      }
      return notificationMessages;
  }
  ```

- 第 12 行：调用 `NamespaceUtil#filterNamespaceName(namespaceName)` 方法，若 Namespace 名以 `".properties"` 结尾，移除该结尾。

- 第 15 行：调用 `NamespaceUtil#normalizeNamespace(appId, originalNamespace)` 方法，获得**归一化**的 Namespace 名字。因为，客户端 Namespace 会填写错大小写。

- 第 17 至 20 行：若客户端未提交 `clientIp` ，调用 `#tryToGetClientIp(HttpServletRequest)` 方法，获取 IP 。详细解析，见 [「2.3 tryToGetClientIp」](https://www.iocoder.cn/Apollo/config-service-config-query-api/#) 方法。

- ========== 分割线 ==========

- 第 26 行：创建 Release 数组。

- 第 27 至 39 行：获得 **Namespace**对应的**最新的**Release 对象。

  - 第 31 行：调用 `ConfigService#loadConfig(appId, clientIp, appId, clusterName, namespace, dataCenter, clientMessages)` 方法，获得 Release 对象。详细解析，见 [「3. ConfigService」](https://www.iocoder.cn/Apollo/config-service-config-query-api/#) 方法。
  - 第 34 行：添加到 Release 书中。
  - 第 37 行：获得 Release 对应的 Cluster 名字。因为，在 `ConfigService#loadConfig(appId, clientIp, appId, clusterName, namespace, dataCenter, clientMessages)` 方法中，会根据 `clusterName` 和 `dataCenter` **分别**查询 Release 直到找到一个，所以需要根据**结果的** Release 获取真正的 **Cluster 名**。

- 第 40 至 49 行：若 Namespace 为**关联类型**，则获取**关联的 Namespace** 的**最新的** Release 对象。

  - 第 42 行：调用 `#namespaceBelongsToAppId(appId, namespace)` 方法，判断 Namespace 是否当前 App 下的，这是关联类型的**前提**。代码如下：

    ```java
    private boolean namespaceBelongsToAppId(String appId, String namespaceName) {
        // Namespace 非 'application' ，因为每个 App 都有
        // Every app has an 'application' namespace
        if (Objects.equals(ConfigConsts.NAMESPACE_APPLICATION, namespaceName)) {
            return true;
        }
        // App 编号非空
        // if no appId is present, then no other namespace belongs to it
        if (ConfigConsts.NO_APPID_PLACEHOLDER.equalsIgnoreCase(appId)) {
            return false;
        }
        // 非当前 App 下的 Namespace
        AppNamespace appNamespace = appNamespaceService.findByAppIdAndNamespace(appId, namespaceName);
        return appNamespace != null;
    }
    ```

  - 第 44 行：调用 `#findPublicConfig(...)` 方法，获得**公用类型**的 Namespace 的 Release 对象。代码如下：

    ```java
    private Release findPublicConfig(String clientAppId, String clientIp, String clusterName,
                                     String namespace, String dataCenter, ApolloNotificationMessages clientMessages) {
        // 获得公用类型的 AppNamespace 对象
        AppNamespace appNamespace = appNamespaceService.findPublicNamespaceByName(namespace);
        // 判断非当前 App 下的，那么就是关联类型。
        // check whether the namespace's appId equals to current one
        if (Objects.isNull(appNamespace) || Objects.equals(clientAppId, appNamespace.getAppId())) {
            return null;
        }
        String publicConfigAppId = appNamespace.getAppId();
        // 获得 Namespace 最新的 Release 对象
        return configService.loadConfig(clientAppId, clientIp, publicConfigAppId, clusterName, namespace, dataCenter, clientMessages);
    }
    ```

    - 在其内部，也是调用 `ConfigService#loadConfig(appId, clientIp, appId, clusterName, namespace, dataCenter, clientMessages)` 方法，获得 Namespace **最新的** Release 对象。

  - 第 45 至 48 行：添加到 Release 数组中。

- 第 50 至 56 行：若获得不到 Release ，返回状态码为 **404** 的响应。

- ========== 分割线 ==========

- 第 59 行：调用 `#auditReleases(...)` 方法，记录 InstanceConfig 。详细解析，见 [《Apollo 源码解析 —— Config Service 记录 Instance》](http://www.iocoder.cn/Apollo/config-service-audit-instance/?self) 。

- ========== 分割线 ==========

- 第 62 行：计算 Config Service 的**合并** ReleaseKey 。当有多个 Release 时，使用 `"+"` 作为**字符串的分隔**。

- 第 64 至 69 行：对比 Client 的**合并** Release Key 。若相等，说明配置**没有改变**，返回状态码为 **302** 的响应。

- ========== 分割线 ==========

- 第 72 行：创建 ApolloConfig 对象。详细解析，见 [「3. ApolloConfig」](https://www.iocoder.cn/Apollo/config-service-config-query-api/#) 方法。

- 第 74 行：调用 `#mergeReleaseConfigurations(List<Release)` 方法，合并**多个** Release 的配置集合，并将结果设置到 ApolloConfig 中。详细解析，见 [「2.4 mergeReleaseConfigurations」](https://www.iocoder.cn/Apollo/config-service-config-query-api/#) 方法。

- 第 77 行：Tracer 日志

- 第 78 行：返回 ApolloConfig 对象。

## 2.3 tryToGetClientIp

`#tryToGetClientIp(HttpServletRequest)` 方法，从请求中获取 IP 。代码如下：

```java
private String tryToGetClientIp(HttpServletRequest request) {
    String forwardedFor = request.getHeader("X-FORWARDED-FOR");
    if (!Strings.isNullOrEmpty(forwardedFor)) {
        return X_FORWARDED_FOR_SPLITTER.splitToList(forwardedFor).get(0);
    }
    return request.getRemoteAddr();
}
```

- 关于 `"X-FORWARDED-FOR"` Header ，详细解析见 [《HTTP 请求头中的 X-Forwarded-For》](https://imququ.com/post/x-forwarded-for-header-in-http.html) 。

## 2.4 mergeReleaseConfigurations

`#mergeReleaseConfigurations(List<Release)` 方法，合并**多个** Release 的配置集合。代码如下：

```java
Map<String, String> mergeReleaseConfigurations(List<Release> releases) {
    Map<String, String> result = Maps.newHashMap();
    // 反转 Release 数组，循环添加到 Map 中。
    for (Release release : Lists.reverse(releases)) {
        result.putAll(gson.fromJson(release.getConfigurations(), configurationTypeReference));
    }
    return result;
}
```

- 为什么要**反转**数组？因为**关联类型**的 Release **后**添加到 Release 数组中。但是，**App 下** 的 Release 的优先级**更高**，所以进行反转。

# 3. ConfigService

`com.ctrip.framework.apollo.configservice.service.config.ConfigService` ，实现 ReleaseMessageListener 接口，配置 Service **接口**。代码如下：

```java
public interface ConfigService extends ReleaseMessageListener {

    /**
     * Load config
     *
     * 读取指定 Namespace 的最新的 Release 对象
     *
     * @param clientAppId       the client's app id
     * @param clientIp          the client ip
     * @param configAppId       the requested config's app id
     * @param configClusterName the requested config's cluster name
     *                          Cluster 的名字
     * @param configNamespace   the requested config's namespace name
     * @param dataCenter        the client data center
     *                          数据中心的 Cluster 的名字
     * @param clientMessages    the messages received in client side
     * @return the Release
     */
    Release loadConfig(String clientAppId, String clientIp, String configAppId, String
            configClusterName, String configNamespace, String dataCenter, ApolloNotificationMessages clientMessages);

}
```

子类如下图所示：

<img src="http://blog-1259650185.cosbj.myqcloud.com/img/202204/05/1649157972.png" alt="类图" style="zoom: 67%;" />

最终有两个子类，差异点在于**是否使用缓存**，通过 ServerConfig `"config-service.cache.enabled"` 配置，默认**关闭**。开启后能提高性能，但是会增大内存消耗！

在 ConfigServiceAutoConfiguration 中，**初始化**使用的 ConfigService 实现类，代码如下：

```java
@Bean
public ConfigService configService() {
  if (bizConfig.isConfigServiceCacheEnabled()) {  // 开启缓存，使用 ConfigServiceWithCache
    return new ConfigServiceWithCache();
  }
  return new DefaultConfigService(); // 不开启缓存，使用 DefaultConfigService
}
```

## 3.1 AbstractConfigService

`com.ctrip.framework.apollo.configservice.service.config.AbstractConfigService` ，实现 ConfigService 接口，配置 Service 抽象类，实现公用的获取配置的逻辑，并暴露抽象方法，让子类实现。**抽象方法**如下：

```java
/**
 * 获得指定编号，并且有效的 Release 对象
 *
 * Find active release by id
 *
 * @param id Release 编号
 */
protected abstract Release findActiveOne(long id, ApolloNotificationMessages clientMessages);

/**
 * 获得最新的，并且有效的 Release 对象
 *
 * Find active release by app id, cluster name and namespace name
 */
protected abstract Release findLatestActiveRelease(String configAppId, String configClusterName,
                                                   String configNamespaceName, ApolloNotificationMessages clientMessages);
```

### 3.1.1 loadConfig

`#loadConfig(...)` **实现**方法，代码如下：

```java
@Override
public Release loadConfig(String clientAppId, String clientIp, String clientLabel, String configAppId, String configClusterName,
    String configNamespace, String dataCenter, ApolloNotificationMessages clientMessages) {
  // load from specified cluster first // 优先，获得指定 Cluster 的 Release 。若存在，直接返回
  if (!Objects.equals(ConfigConsts.CLUSTER_NAME_DEFAULT, configClusterName)) {
    Release clusterRelease = findRelease(clientAppId, clientIp, clientLabel, configAppId, configClusterName, configNamespace,
        clientMessages);

    if (Objects.nonNull(clusterRelease)) {
      return clusterRelease;
    }
  }

  // try to load via data center // 其次，获得所属 IDC 的 Cluster 的 Release 。若存在，直接返回
  if (!Strings.isNullOrEmpty(dataCenter) && !Objects.equals(dataCenter, configClusterName)) {
    Release dataCenterRelease = findRelease(clientAppId, clientIp, clientLabel, configAppId, dataCenter, configNamespace,
        clientMessages);
    if (Objects.nonNull(dataCenterRelease)) {
      return dataCenterRelease;
    }
  }

  // fallback to default release // 最后，获得默认 Cluster 的 Release
  return findRelease(clientAppId, clientIp, clientLabel, configAppId, ConfigConsts.CLUSTER_NAME_DEFAULT, configNamespace,
      clientMessages);
}
```

- 第 4 至 12 行：优先，获得**指定** Cluster 的 Release 。若存在，直接返回。
- 第 14 至 21 行：其次，获得**所属 IDC** 的 Cluster 的 Release 。若存在，直接返回。
- 第 25 行：最后，获得**默认**的 Cluster 的 Release 。
- 每一次获取，都调用了 `#findRelease(...)` 方法，获取对应的 Release 对象。详细解析，见 [「3.2 findRelease」](https://www.iocoder.cn/Apollo/config-service-config-query-api/#) 方法。
- 关于多 Cluster 的读取**顺序**，可参见 [《Apollo 配置中心介绍 —— 4.4.1 应用自身配置的获取规则》](https://github.com/ctripcorp/apollo/wiki/Apollo配置中心介绍#442-公共组件配置的获取规则) 。这块的代码，就是实现该**顺序**，如下图：![读取顺序](http://blog-1259650185.cosbj.myqcloud.com/img/202204/05/1649167074.png)

### 3.1.2 findRelease

```java
/**
 * Find release. 获得 Release 对象
 *
 * @param clientAppId the client's app id
 * @param clientIp the client ip
 * @param clientLabel the client label
 * @param configAppId the requested config's app id
 * @param configClusterName the requested config's cluster name
 * @param configNamespace the requested config's namespace name
 * @param clientMessages the messages received in client side
 * @return the release
 */
private Release findRelease(String clientAppId, String clientIp, String clientLabel, String configAppId, String configClusterName,
    String configNamespace, ApolloNotificationMessages clientMessages) {
  Long grayReleaseId = grayReleaseRulesHolder.findReleaseIdFromGrayReleaseRule(clientAppId, clientIp, clientLabel, configAppId,
      configClusterName, configNamespace); // 读取灰度发布编号

  Release release = null;

  if (grayReleaseId != null) {  //  读取灰度 Release 对象
    release = findActiveOne(grayReleaseId, clientMessages);
  }

  if (release == null) {  // 非灰度，获得最新的，并且有效的 Release 对象
    release = findLatestActiveRelease(configAppId, configClusterName, configNamespace, clientMessages);
  }

  return release;
}
```

- 第 17 行：调用 `GrayReleaseRulesHolder#findReleaseIdFromGrayReleaseRule(...)` 方法，读取灰度发布编号，即 `GrayReleaseRule.releaseId` 属性。详细解析，在 [《Apollo 源码解析 —— Portal 灰度发布》](http://www.iocoder.cn/Apollo/portal-publish-namespace-branch?self) 中。
- 第 18 至 22 行：调用 `#findActiveOne(grayReleaseId, clientMessages)` 方法，读取**灰度** Release 对象。
- 第 23 至 26 行：**若非灰度**，调用 `#findLatestActiveRelease(configAppId, configClusterName, configNamespace, clientMessages)` 方法，获得**最新的**，并且**有效的** Release 对象。

## 3.3 DefaultConfigService

`com.ctrip.framework.apollo.configservice.service.config.DefaultConfigService` ，实现 AbstractConfigService 抽象类，配置 Service 默认实现类，直接查询数据库，而不使用缓存。代码如下：

```java
public class DefaultConfigService extends AbstractConfigService {

  @Autowired
  private ReleaseService releaseService;

  @Override
  protected Release findActiveOne(long id, ApolloNotificationMessages clientMessages) {
    return releaseService.findActiveOne(id);
  }

  @Override
  protected Release findLatestActiveRelease(String configAppId, String configClusterName, String configNamespace,
                                            ApolloNotificationMessages clientMessages) {
    return releaseService.findLatestActiveRelease(configAppId, configClusterName,
        configNamespace);
  }

  @Override
  public void handleMessage(ReleaseMessage message, String channel) {
    // since there is no cache, so do nothing
  }
}
```

- ReleaseService ，在 [《Apollo 源码解析 —— Portal 发布配置》](http://www.iocoder.cn/Apollo/portal-publish/?self) 中，有详细解析。

## 3.4 ConfigServiceWithCache

`com.ctrip.framework.apollo.configservice.service.config.ConfigServiceWithCache` ，实现 AbstractConfigService 抽象类，基于 **Guava Cache** 的配置 Service 实现类。

### 3.4.1 构造方法

```java
public class ConfigServiceWithCache extends AbstractConfigService {
  private static final Logger logger = LoggerFactory.getLogger(ConfigServiceWithCache.class);
  private static final long DEFAULT_EXPIRED_AFTER_ACCESS_IN_MINUTES = 60;//1 hour 默认缓存过滤时间，单位：分钟
  private static final String TRACER_EVENT_CACHE_INVALIDATE = "ConfigCache.Invalidate"; // TRACER 日志内存的枚举
  private static final String TRACER_EVENT_CACHE_LOAD = "ConfigCache.LoadFromDB";
  private static final String TRACER_EVENT_CACHE_LOAD_ID = "ConfigCache.LoadFromDBById";
  private static final String TRACER_EVENT_CACHE_GET = "ConfigCache.Get";
  private static final String TRACER_EVENT_CACHE_GET_ID = "ConfigCache.GetById";
  private static final Splitter STRING_SPLITTER =
      Splitter.on(ConfigConsts.CLUSTER_NAMESPACE_SEPARATOR).omitEmptyStrings();

  @Autowired
  private ReleaseService releaseService;

  @Autowired
  private ReleaseMessageService releaseMessageService;
  //  ConfigCacheEntry 缓存。KEY：Watch Key {@link ReleaseMessage#message}
  private LoadingCache<String, ConfigCacheEntry> configCache;
  // Release 缓存。KEY ：Release 编号
  private LoadingCache<Long, Optional<Release>> configIdCache;
  // 无 ConfigCacheEntry 占位对象
  private ConfigCacheEntry nullConfigCacheEntry;

  public ConfigServiceWithCache() {
    nullConfigCacheEntry = new ConfigCacheEntry(ConfigConsts.NOTIFICATION_ID_PLACEHOLDER, null);
  }
  // ... 省略其他方法

}
```

### 3.4.2 ConfigCacheEntry

ConfigCacheEntry ，ConfigServiceWithCache 的内部私有静态类，配置缓存 Entry 。代码如下：

```java
private static class ConfigCacheEntry {

    /**
     * 通知编号
     */
    private final long notificationId;
    /**
     * Release 对象
     */
    private final Release release;

    public ConfigCacheEntry(long notificationId, Release release) {
        this.notificationId = notificationId;
        this.release = release;
    }

    public long getNotificationId() {
        return notificationId;
    }

    public Release getRelease() {
        return release;
    }

}
```

### 3.4.3 初始化

`#initialize()` 方法，通过 Spring 调用，**初始化缓存对象**。代码如下：

```java
@PostConstruct
void initialize() {
  configCache = CacheBuilder.newBuilder() // 初始化 configCache
      .expireAfterAccess(DEFAULT_EXPIRED_AFTER_ACCESS_IN_MINUTES, TimeUnit.MINUTES) // 访问过期
      .build(new CacheLoader<String, ConfigCacheEntry>() {
        @Override
        public ConfigCacheEntry load(String key) throws Exception {
          List<String> namespaceInfo = STRING_SPLITTER.splitToList(key);
          if (namespaceInfo.size() != 3) {  // 格式不正确，返回 nullConfigCacheEntry
            Tracer.logError(
                new IllegalArgumentException(String.format("Invalid cache load key %s", key)));
            return nullConfigCacheEntry;
          }

          Transaction transaction = Tracer.newTransaction(TRACER_EVENT_CACHE_LOAD, key);
          try {
            ReleaseMessage latestReleaseMessage = releaseMessageService.findLatestReleaseMessageForMessages(Lists
                .newArrayList(key)); // 获得最新的 ReleaseMessage 对象
            Release latestRelease = releaseService.findLatestActiveRelease(namespaceInfo.get(0), namespaceInfo.get(1),
                namespaceInfo.get(2)); // 获得最新的，并且有效的 Release 对象

            transaction.setStatus(Transaction.SUCCESS);
            // 获得通知编号
            long notificationId = latestReleaseMessage == null ? ConfigConsts.NOTIFICATION_ID_PLACEHOLDER : latestReleaseMessage
                .getId();
            // 若 latestReleaseMessage 和 latestRelease 都为空，返回 nullConfigCacheEntry
            if (notificationId == ConfigConsts.NOTIFICATION_ID_PLACEHOLDER && latestRelease == null) {
              return nullConfigCacheEntry;
            }
            // 创建 ConfigCacheEntry 对象
            return new ConfigCacheEntry(notificationId, latestRelease);
          } catch (Throwable ex) {
            transaction.setStatus(ex);
            throw ex;
          } finally {
            transaction.complete();
          }
        }
      });
  configIdCache = CacheBuilder.newBuilder() // 初始化 configIdCache
      .expireAfterAccess(DEFAULT_EXPIRED_AFTER_ACCESS_IN_MINUTES, TimeUnit.MINUTES) // 访问过期
      .build(new CacheLoader<Long, Optional<Release>>() {
        @Override
        public Optional<Release> load(Long key) throws Exception {
          Transaction transaction = Tracer.newTransaction(TRACER_EVENT_CACHE_LOAD_ID, String.valueOf(key));
          try {
            Release release = releaseService.findActiveOne(key); // 获得 Release 对象

            transaction.setStatus(Transaction.SUCCESS);

            return Optional.ofNullable(release); // 使用 Optional 包装 Release 对象返回
          } catch (Throwable ex) {
            transaction.setStatus(ex);
            throw ex;
          } finally {
            transaction.complete();
          }
        }
      });
}
```

- 第 4 至 41 行：初始化`configCache`。
  - 第 9 至 14 行： `key` 格式不正确，返回 `nullConfigCacheEntry` 。
  - 第 19 行：调用 `releaseMessageService.findLatestReleaseMessageForMessages(List<String>)` 方法，获得**最新的** ReleaseMessage 对象。这一步是 DefaultConfigService 没有的操作，用于读取缓存的时候，判断缓存是否过期，下文详细解析。
  - 第 21 行：调用 `ReleaseService.findLatestActiveRelease(appId, clusterName, namespaceName)` 方法，获得**最新的**，且**有效的** Release 对象。
  - 第 25 行：获得通知编号。
  - 第 26 至 29 行：若 `latestReleaseMessage` 和 `latestRelease` **都**为空，返回 `nullConfigCacheEntry` 。
  - 第 31 行：创建 ConfigCacheEntry 对象，并返回。
- 第 42 至 66 行：初始化`configIdCache`。
  - 第 52 行：调用 `ReleaseService#findActiveOne(key)` 方法，获得 Release 对象。
  - 第 56 行：调用 `Optional.ofNullable(Object)` 方法，使用 Optional 包装 Release 对象，并返回。

### 3.4.4 handleMessage

```java
@Override
public void handleMessage(ReleaseMessage message, String channel) {
  logger.info("message received - channel: {}, message: {}", channel, message);
  if (!Topics.APOLLO_RELEASE_TOPIC.equals(channel) || Strings.isNullOrEmpty(message.getMessage())) { // 仅处理 APOLLO_RELEASE_TOPIC
    return;
  }

  try {
    invalidate(message.getMessage());  // 清空对应的缓存
    // 预热缓存，读取 ConfigCacheEntry 对象，重新从 DB 中加载。
    //warm up the cache
    configCache.getUnchecked(message.getMessage());
  } catch (Throwable ex) {
    //ignore
  }
}
```

- 第 4 至 7 行：仅处理 **APOLLO_RELEASE_TOPIC** 。

- 第 10 行：调用 `#invalidate(message)` 方法，清空对应的缓存。代码如下：

  ```java
  private void invalidate(String key) {
    configCache.invalidate(key); // 清空对应的缓存
    Tracer.logEvent(TRACER_EVENT_CACHE_INVALIDATE, key);
  }
  ```

- 第 13 行：调用 `LoadingCache#getUnchecked(key)` 方法，预热缓存，读取 ConfigCacheEntry 对象，重新从 DB 中加载。

### 3.4.5 findLatestActiveRelease

```java
@Override
protected Release findLatestActiveRelease(String appId, String clusterName, String namespaceName,
                                          ApolloNotificationMessages clientMessages) {
  String key = ReleaseMessageKeyGenerator.generate(appId, clusterName, namespaceName); // 根据 appId + clusterName + namespaceName ，获得 ReleaseMessage 的 message

  Tracer.logEvent(TRACER_EVENT_CACHE_GET, key);
  // 从缓存 configCache 中，读取 ConfigCacheEntry 对象
  ConfigCacheEntry cacheEntry = configCache.getUnchecked(key);

  //cache is out-dated
  if (clientMessages != null && clientMessages.has(key) &&
      clientMessages.get(key) > cacheEntry.getNotificationId()) { // 若客户端的通知编号更大，说明缓存已经过期。
    //invalidate the cache and try to load from db again
    invalidate(key); // 清空对应的缓存
    cacheEntry = configCache.getUnchecked(key); // 读取 ConfigCacheEntry 对象，重新从 DB 中加载。
  }

  return cacheEntry.getRelease();  // 返回 Release 对象
}
```

- 第 4 行：调用 `ReleaseMessageKeyGenerator#generate(appId, clusterName, namespaceName)` 方法，根据 `appId` + `clusterName` + `namespaceName` ，获得 ReleaseMessage 的 `message` 。

- 第 8 行：调用 `LoadingCache#getUnchecked(key)` 方法，从缓存 `configCache` 中，读取 ConfigCacheEntry 对象。

- 第 9 至 17 行：若客户端的通知编号**更大**，说明缓存已经过期。因为`#handleMessage(ReleaseMessage message, String channel)`

  方法，是通过**定时**扫描 ReleaseMessage 的机制实现，那么延迟是不可避免会存在的。所以通过此处比较的方式，实现

  缓存的过期的检查。

  - 第 14 行：调用 `#invalidate(message)` 方法，清空对应的缓存。
  - 第 16 行：调用`LoadingCache#getUnchecked(key)`方法，读取 ConfigCacheEntry 对象，重新从 DB 中加载。
    - 第 19 行：返回 Release 对象。

### 3.4.6 findActiveOne

```java
@Override
protected Release findActiveOne(long id, ApolloNotificationMessages clientMessages) {
  Tracer.logEvent(TRACER_EVENT_CACHE_GET_ID, String.valueOf(id));
  return configIdCache.getUnchecked(id).orElse(null); // 从缓存 configIdCache 中，读取 Release 对象
}
```

# 4. ApolloConfig

`com.ctrip.framework.apollo.core.dto.ApolloConfig` ，Apollo 配置 DTO 。代码如下：

```java
public class ApolloConfig {

    /**
     * App 编号
     */
    private String appId;
    /**
     * Cluster 名字
     */
    private String cluster;
    /**
     * Namespace 名字
     */
    private String namespaceName;
    /**
     * 配置 Map
     */
    private Map<String, String> configurations;
    /**
     * Release Key
     *
     * 如果 {@link #configurations} 是多个 Release ，那 Release Key 是多个 `Release.releaseKey` 拼接，使用 '+' 拼接。
     */
    private String releaseKey;

}
```

- 该类在 `apollo-core` 项目中，被 `apollo-configservice` 和 `apollo-client` 共同引用。因此，Apollo 的客户端，也使用 ApolloConfig 。



# 参考

[Apollo 源码解析 —— Config Service 配置读取接口](https://www.iocoder.cn/Apollo/config-service-config-query-api/)

