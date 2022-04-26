# 1. 概述

> 老艿艿：本系列假定胖友已经阅读过 [《Apollo 官方 wiki 文档》](https://github.com/ctripcorp/apollo/wiki/) 。

在 Portal 的应用详情页，我们可以看到每个 Namespace 下的**实例**列表。如下图所示：![实例列表](http://blog-1259650185.cosbj.myqcloud.com/img/202204/06/1649176146.png)

- 实例( Instance )，实际就是 Apollo 的**客户端**。

**本文分享实例相关的实体和如何存储的**。

# 2. 实体

## 2.1 Instance

`com.ctrip.framework.apollo.biz.entity.Instance` ，Instance **实体**。代码如下：

```java
@Entity
@Table(name = "Instance")
public class Instance {

    /**
     * 编号
     */
    @Id
    @GeneratedValue
    @Column(name = "Id")
    private long id;
    /**
     * App 编号
     */
    @Column(name = "AppId", nullable = false)
    private String appId;
    /**
     * Cluster 名字
     */
    @Column(name = "ClusterName", nullable = false)
    private String clusterName;
    /**
     * 数据中心的 Cluster 名字
     */
    @Column(name = "DataCenter", nullable = false)
    private String dataCenter;
    /**
     * 客户端 IP
     */
    @Column(name = "Ip", nullable = false)
    private String ip;
    /**
     * 数据创建时间
     */
    @Column(name = "DataChange_CreatedTime", nullable = false)
    private Date dataChangeCreatedTime;
    /**
     * 数据最后更新时间
     */
    @Column(name = "DataChange_LastTime")
    private Date dataChangeLastModifiedTime;

    @PrePersist
    protected void prePersist() {
        if (this.dataChangeCreatedTime == null) {
            dataChangeCreatedTime = new Date();
        }
        if (this.dataChangeLastModifiedTime == null) {
            dataChangeLastModifiedTime = dataChangeCreatedTime;
        }
    }
}
```

- `id` 字段，编号，自增。
- `appId` + `clusterName` + `dataCenter` + `ip` 组成**唯一索引**，通过这四个字段**唯一一个实例( 客户端 )**。

## 2.2 InstanceConfig

`com.ctrip.framework.apollo.biz.entity.InstanceConfig` ，Instance Config **实体**，记录 Instance 对 Namespace 的配置的**获取**情况。如果一个 Instance 使用了**多个** Namespace ，则会记录**多条** InstanceConfig 。

代码如下：

```java
@Entity
@Table(name = "InstanceConfig")
public class InstanceConfig {

    /**
     * 编号
     */
    @Id
    @GeneratedValue
    @Column(name = "Id")
    private long id;
    /**
     * Instance 编号，指向 {@link Instance#id}
     */
    @Column(name = "InstanceId")
    private long instanceId;
    /**
     * App 编号
     */
    @Column(name = "ConfigAppId", nullable = false)
    private String configAppId;
    /**
     * Cluster 名字
     */
    @Column(name = "ConfigClusterName", nullable = false)
    private String configClusterName;
    /**
     * Namespace 名字
     */
    @Column(name = "ConfigNamespaceName", nullable = false)
    private String configNamespaceName;
    /**
     * Release Key ，对应 {@link Release#releaseKey}
     */
    @Column(name = "ReleaseKey", nullable = false)
    private String releaseKey;
    /**
     * 配置下发时间
     */
    @Column(name = "ReleaseDeliveryTime", nullable = false)
    private Date releaseDeliveryTime;
    /**
     * 数据创建时间
     */
    @Column(name = "DataChange_CreatedTime", nullable = false)
    private Date dataChangeCreatedTime;
    /**
     * 数据最后更新时间
     */
    @Column(name = "DataChange_LastTime")
    private Date dataChangeLastModifiedTime;

    @PrePersist
    protected void prePersist() {
        if (this.dataChangeCreatedTime == null) {
            dataChangeCreatedTime = new Date();
        }
        if (this.dataChangeLastModifiedTime == null) {
            dataChangeLastModifiedTime = dataChangeCreatedTime;
        }
    }
}
```

- `id` 字段，编号，自增。
- `instanceId` + `configAppId` + `ConfigNamespaceName` 组成**唯一索引**，因为一个 Instance 可以使用**多个** Namespace 。
- `releaseKey` 字段，Release Key ，对应 `Release.releaseKey` 字段。
- `releaseDeliveryTime` 字段，配置下发时间。
- 通过 `releaseKey` + `releaseDeliveryTime` 字段，可以很容易判断 Instance 在当前 Namespace 获取**配置的情况**。
- `configClusterName` 字段，Cluster 名字。

# 3. InstanceConfigAuditUtil

在 [《Apollo 源码解析 —— Config Service 配置读取接口》](http://www.iocoder.cn/Apollo/config-service-config-query-api/?self) 中，我们看到，客户端读取配置时，会调用 Config Service 的 **GET `/configs/{appId}/{clusterName}/{namespace:.+}` 接口**。在接口中，会调用 `InstanceConfigAuditUtil#audit(...)` 的方法，代码如下：

```java
private void auditReleases(String appId, String cluster, String dataCenter, String clientIp,
                           List<Release> releases) {
    if (Strings.isNullOrEmpty(clientIp)) {
        //no need to audit instance config when there is no ip
        return;
    }
    // 循环 Release 数组
    for (Release release : releases) {
        // 记录 InstanceConfig
        instanceConfigAuditUtil.audit(appId, cluster, dataCenter, clientIp, release.getAppId(),
                release.getClusterName(),
                release.getNamespaceName(), release.getReleaseKey());
    }
}
```

下面我们来看看 InstanceConfigAuditUtil 的具体实现。

`com.ctrip.framework.apollo.configservice.util.InstanceConfigAuditUtil` ，实现 InitializingBean 接口，InstanceConfig 审计工具类。

## 3.1 构造方法

```java
@Service
public class InstanceConfigAuditUtil implements InitializingBean {
  private static final int INSTANCE_CONFIG_AUDIT_MAX_SIZE = 10000; // {@link #audits} 大小
  private static final int INSTANCE_CACHE_MAX_SIZE = 50000; // {@link #instanceCache} 大小
  private static final int INSTANCE_CONFIG_CACHE_MAX_SIZE = 50000; //  {@link #instanceConfigReleaseKeyCache} 大小
  private static final long OFFER_TIME_LAST_MODIFIED_TIME_THRESHOLD_IN_MILLI = TimeUnit.MINUTES.toMillis(10);//10 minutes
  private static final Joiner STRING_JOINER = Joiner.on(ConfigConsts.CLUSTER_NAMESPACE_SEPARATOR);
  private final ExecutorService auditExecutorService; // ExecutorService 对象。队列大小为 1
  private final AtomicBoolean auditStopped; // 是否停止
  private BlockingQueue<InstanceConfigAuditModel> audits = Queues.newLinkedBlockingQueue
      (INSTANCE_CONFIG_AUDIT_MAX_SIZE); // 队列
  private Cache<String, Long> instanceCache; // Instance 的编号的缓存。KEY：{@link #assembleInstanceKey(String, String, String, String)}，VALUE：{@link Instance#id}
  private Cache<String, String> instanceConfigReleaseKeyCache; // InstanceConfig 的 ReleaseKey 的缓存。KEY：{@link #assembleInstanceConfigKey(long, String, String)}。VALUE：{@link InstanceConfig#id}

  private final InstanceService instanceService;

  public InstanceConfigAuditUtil(final InstanceService instanceService) {
    this.instanceService = instanceService;
    auditExecutorService = Executors.newSingleThreadExecutor(
        ApolloThreadFactory.create("InstanceConfigAuditUtil", true));
    auditStopped = new AtomicBoolean(false);
    instanceCache = CacheBuilder.newBuilder().expireAfterAccess(1, TimeUnit.HOURS)
        .maximumSize(INSTANCE_CACHE_MAX_SIZE).build();
    instanceConfigReleaseKeyCache = CacheBuilder.newBuilder().expireAfterWrite(1, TimeUnit.DAYS)
        .maximumSize(INSTANCE_CONFIG_CACHE_MAX_SIZE).build();
  }
  // ... 省略其他方法

}
```

- 基础属性
  - `instanceCache`属性，Instance 的**编号**的**缓存**。其中：
    - KEY ，使用 `appId` + `clusterName` + `dataCenter` + `ip` ，恰好是 Instance 的唯一索引的字段。
    - VALUE ，使用 `id` 。
  - `instanceConfigReleaseKeyCache`属性，InstanceConfig 的 **ReleaseKey的缓存**。其中：
    - KEY ，使用 `instanceId` + `configAppId` + `ConfigNamespaceName` ，恰好是 InstanceConfig 的唯一索引的字段。
    - VALUE ，使用 `releaseKey` 。
- 线程相关
  - InstanceConfigAuditUtil 记录 Instance 和 InstanceConfig 是提交到队列，使用线程池异步处理。
  - `auditExecutorService` 属性，ExecutorService 对象。队列大小为 **1** 。
  - `auditStopped` 属性，是否停止。
  - `audits` 属性，队列。

## 3.2 初始化任务

`#afterPropertiesSet()` 方法，通过 Spring 调用，**初始化任务**。代码如下：

```java
@Override
public void afterPropertiesSet() throws Exception {
  auditExecutorService.submit(() -> { // 提交任务
    while (!auditStopped.get() && !Thread.currentThread().isInterrupted()) { // 循环，直到停止或线程打断
      try {
        InstanceConfigAuditModel model = audits.take(); // 获得队首 InstanceConfigAuditModel 元素，非阻塞
        doAudit(model); // 若获取到，记录 Instance 和 InstanceConfig
      } catch (Throwable ex) {
        Tracer.logError(ex);
      }
    }
  });
}
```

- 第 4 至 21 行：提交任务到`auditExecutorService`中。
  - 第 6 至 20 行：循环，直到停止或线程打断。
  - 第 9 行：调用 `BlockingQueue#take()` 方法，获得**队首** InstanceConfigAuditModel 元素，**阻塞**。
  - 第 16 行：若获取到，调用 `#doAudit(InstanceConfigAuditModel)` 方法，记录 Instance 和 InstanceConfig 。详细解析，见 [「3.4 doAudit」](https://www.iocoder.cn/Apollo/config-service-audit-instance/#) 。

## 3.3 audit

`#audit(...)` 方法，添加到队列中。代码如下：

```java
public boolean audit(String appId, String clusterName, String dataCenter, String
    ip, String configAppId, String configClusterName, String configNamespace, String releaseKey) {
  return this.audits.offer(new InstanceConfigAuditModel(appId, clusterName, dataCenter, ip,
      configAppId, configClusterName, configNamespace, releaseKey));
}
```

- 创建 InstanceConfigAuditModel 对象，代码如下：

  ```java
  public static class InstanceConfigAuditModel {
  
      private String appId;
      private String clusterName;
      private String dataCenter;
      private String ip;
      private String configAppId;
      private String configClusterName;
      private String configNamespace;
      private String releaseKey;
      /**
       * 入队时间
       */
      private Date offerTime;
  
      public InstanceConfigAuditModel(String appId, String clusterName, String dataCenter, String
              clientIp, String configAppId, String configClusterName, String configNamespace, String
                                              releaseKey) {
          this.offerTime = new Date(); // 当前时间
          this.appId = appId;
          this.clusterName = clusterName;
          this.dataCenter = Strings.isNullOrEmpty(dataCenter) ? "" : dataCenter;
          this.ip = clientIp;
          this.configAppId = configAppId;
          this.configClusterName = configClusterName;
          this.configNamespace = configNamespace;
          this.releaseKey = releaseKey;
      }
  }
  ```

  - `offerTime` 属性，入队时间，取得当前时间，**避免异步处理的时间差**。

- 调用 `BlockingQueue#offset(InstanceConfigAuditModel)` 方法，添加到队列 `audits` 中。

## 3.4 doAudit

`#doAudit(InstanceConfigAuditModel)` 方法，记录 Instance 和 InstanceConfig 。代码如下：

```java
void doAudit(InstanceConfigAuditModel auditModel) {
  String instanceCacheKey = assembleInstanceKey(auditModel.getAppId(), auditModel
      .getClusterName(), auditModel.getIp(), auditModel.getDataCenter()); // 拼接 instanceCache 的 KEY
  Long instanceId = instanceCache.getIfPresent(instanceCacheKey); // 获得 Instance 编号
  if (instanceId == null) { // 查询不到，从 DB 加载或者创建，并添加到缓存中
    instanceId = prepareInstanceId(auditModel);
    instanceCache.put(instanceCacheKey, instanceId);
  }

  //load instance config release key from cache, and check if release key is the same
  String instanceConfigCacheKey = assembleInstanceConfigKey(instanceId, auditModel
      .getConfigAppId(), auditModel.getConfigNamespace()); // 获得 instanceConfigReleaseKeyCache 的 KEY
  String cacheReleaseKey = instanceConfigReleaseKeyCache.getIfPresent(instanceConfigCacheKey); // 获得缓存的 cacheReleaseKey

  //if release key is the same, then skip audit // 若相等，跳过
  if (cacheReleaseKey != null && Objects.equals(cacheReleaseKey, auditModel.getReleaseKey())) {
    return;
  }
  // 更新对应的 instanceConfigReleaseKeyCache 缓存
  instanceConfigReleaseKeyCache.put(instanceConfigCacheKey, auditModel.getReleaseKey());

  //if release key is not the same or cannot find in cache, then do audit
  InstanceConfig instanceConfig = instanceService.findInstanceConfig(instanceId, auditModel
      .getConfigAppId(), auditModel.getConfigNamespace()); // 获得 InstanceConfig 对象

  if (instanceConfig != null) { // 若 InstanceConfig 已经存在，进行更新
    if (!Objects.equals(instanceConfig.getReleaseKey(), auditModel.getReleaseKey())) { // ReleaseKey 发生变化
      instanceConfig.setConfigClusterName(auditModel.getConfigClusterName());
      instanceConfig.setReleaseKey(auditModel.getReleaseKey());
      instanceConfig.setReleaseDeliveryTime(auditModel.getOfferTime());  // 配置下发时间，使用入队时间
    } else if (offerTimeAndLastModifiedTimeCloseEnough(auditModel.getOfferTime(),
        instanceConfig.getDataChangeLastModifiedTime())) { // 时间过近，例如 Client 先请求的 Config Service A 节点，再请求 Config Service B 节点的情况。
      //when releaseKey is the same, optimize to reduce writes if the record was updated not long ago
      return;
    }
    //we need to update no matter the release key is the same or not, to ensure the
    //last modified time is updated each day
    instanceConfig.setDataChangeLastModifiedTime(auditModel.getOfferTime()); // 更新
    instanceService.updateInstanceConfig(instanceConfig);
    return;
  }
  // 若 InstanceConfig 不存在，创建 InstanceConfig 对象
  instanceConfig = new InstanceConfig();
  instanceConfig.setInstanceId(instanceId);
  instanceConfig.setConfigAppId(auditModel.getConfigAppId());
  instanceConfig.setConfigClusterName(auditModel.getConfigClusterName());
  instanceConfig.setConfigNamespaceName(auditModel.getConfigNamespace());
  instanceConfig.setReleaseKey(auditModel.getReleaseKey());
  instanceConfig.setReleaseDeliveryTime(auditModel.getOfferTime());
  instanceConfig.setDataChangeCreatedTime(auditModel.getOfferTime());

  try {
    instanceService.createInstanceConfig(instanceConfig); // 保存 InstanceConfig 对象到数据库中
  } catch (DataIntegrityViolationException ex) {
    //concurrent insertion, safe to ignore
  }
}
```

- ============ Instance 相关 ============

- 第 2 至 4 行：拼接 `instanceCache` 的 KEY 。

- 第 6 行：调用 `Cache#getIfPresent(key)` 从缓存 `instanceCache` 中获得 Instance 编号。

- 第 7 至 11 行：查询不到，从 DB 加载或者创建，并添加到缓存中。`#prepareInstanceId(InstanceConfigAuditModel)` 方法，代码如下：

  ```java
   private long prepareInstanceId(InstanceConfigAuditModel auditModel) {
      // 查询 Instance 对象
      Instance instance = instanceService.findInstance(auditModel.getAppId(), auditModel
              .getClusterName(), auditModel.getDataCenter(), auditModel.getIp());
      // 已存在，返回 Instance 编号
      if (instance != null) {
          return instance.getId();
      }
      // 若 Instance 不存在，创建 Instance 对象
      instance = new Instance();
      instance.setAppId(auditModel.getAppId());
      instance.setClusterName(auditModel.getClusterName());
      instance.setDataCenter(auditModel.getDataCenter());
      instance.setIp(auditModel.getIp());
      // 保存 Instance 对象到数据库中
      try {
          return instanceService.createInstance(instance).getId();
      } catch (DataIntegrityViolationException ex) {
          // 发生唯一索引冲突，意味着已经存在，进行查询 Instance 对象，并返回
          // return the one exists
          return instanceService.findInstance(instance.getAppId(), instance.getClusterName(),
                  instance.getDataCenter(), instance.getIp()).getId();
      }
  }
  ```

  - 🙂 代码比较简单，胖友看下注释。

- ============ InstanceConfig 相关 ============

- 第 15 行：拼接 `instanceConfigReleaseKeyCache` 的 KEY 。

- 第 18 行：调用 `Cache#getIfPresent(key)` 从缓存 `instanceConfigReleaseKeyCache` 中获得 `cacheReleaseKey` 。

- 第 19 至 23 行：若 `releaseKey` 相当，说明**无更新**，跳过。

- 第 25 行：更新对应的 `instanceConfigReleaseKeyCache` 缓存。

- 第 26 至 29 行：调用 `InstanceService#findInstanceConfig(...)` 方法，获得 InstanceConfig 对象。相比 Instance 来说，InstanceConfig 存在**更新**逻辑。

- 第 31 至 49 行：若 InstanceConfig 已经存在，进行更新。

  - 第 34 至 37 行：若 `releaseKey` 发生变化，设置需要更新的字段 `configClusterName` `releaseKey` `releaseDeliveryTime` 。**注意**，`releaseDeliveryTime` 配置下发时间，使用入队时间。

  - 第 38 至 42 行：调用 `#offerTimeAndLastModifiedTimeCloseEnough(Date offerTime, Date lastModifiedTime)` 方法，时间过近，仅相差 **10** 分钟。例如，Client 先请求的 Config Service A 节点，再请求 Config Service B 节点的情况。此时，InstanceConfig 在 DB 中是已经更新了，但是在 Config Service B 节点的缓存是未更新的。`#offerTimeAndLastModifiedTimeCloseEnough(...)` 方法，代码如下：

    ```java
    private boolean offerTimeAndLastModifiedTimeCloseEnough(Date offerTime, Date lastModifiedTime) {
        return (offerTime.getTime() - lastModifiedTime.getTime()) < OFFER_TIME_LAST_MODIFIED_TIME_THRESHOLD_IN_MILLI;
    }
    ```

  - 第 43 至 48 行：调用`InstanceService#updateInstanceConfig(InstanceConfig)`方法，更新 InstanceConfig。**结束处理**。

    - 第 51 至 65 行：若 InstanceConfig 不存在，创建 InstanceConfig 对象。

  - 第 52 至 59 行：创建 InstanceConfig 对象。

  - 第 60 至 62 行：调用 `InstanceService#createInstanceConfig(InstanceConfig)` 方法，保存 InstanceConfig 对象到数据库中。



# 参考

[Apollo 源码解析 —— Config Service 记录 Instance](https://www.iocoder.cn/Apollo/config-service-audit-instance/)
