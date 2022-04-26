# 1. 概述

> 老艿艿：本系列假定胖友已经阅读过 [《Apollo 官方 wiki 文档》](https://github.com/ctripcorp/apollo/wiki/) ，特别是 [《Apollo 官方 wiki 文档 —— 灰度发布使用指南》](https://github.com/ctripcorp/apollo/wiki/Apollo使用指南#五灰度发布使用指南)。

**灰度发布**，实际上是**子** Namespace ( **分支** Namespace )发布 Release 。所以，调用的接口和 [《Apollo 源码解析 —— Portal 发布配置》](http://www.iocoder.cn/Apollo/portal-publish/?self) 是**一样的**。

**差异点**，在于 `apollo-biz` 项目中，`ReleaseService#publish(...)` 方法中，多了一个处理**灰度发布**的分支逻辑。

# 2. ReleaseService

## 2.1 publishBranchNamespace

`#publishBranchNamespace(...)` 方法，**子** Namespace 发布 Release 。**子** Namespace 会**自动继承** 父 Namespace **已经发布**的配置。若有相同的配置项，使用 **子** Namespace 的。配置处理的逻辑上，和**关联** Namespace 是一致的。代码如下：

```java
// 进行灰度发布
private Release publishBranchNamespace(Namespace parentNamespace, Namespace childNamespace,
                                       Map<String, String> childNamespaceItems,
                                       String releaseName, String releaseComment,
                                       String operator, boolean isEmergencyPublish) {
  return publishBranchNamespace(parentNamespace, childNamespace, childNamespaceItems, releaseName, releaseComment,
          operator, isEmergencyPublish, null);

}

private Release publishBranchNamespace(Namespace parentNamespace, Namespace childNamespace,
                                       Map<String, String> childNamespaceItems,
                                       String releaseName, String releaseComment,
                                       String operator, boolean isEmergencyPublish, Set<String> grayDelKeys) {
  Release parentLatestRelease = findLatestActiveRelease(parentNamespace);  // 获得父 Namespace 的最后有效 Release 对象
  Map<String, String> parentConfigurations = parentLatestRelease != null ?
          GSON.fromJson(parentLatestRelease.getConfigurations(),
                        GsonType.CONFIG) : new LinkedHashMap<>(); // 获得父 Namespace 的配置项
  long baseReleaseId = parentLatestRelease == null ? 0 : parentLatestRelease.getId(); // 获得父 Namespace 的 releaseId 属性
  // 合并配置项
  Map<String, String> configsToPublish = mergeConfiguration(parentConfigurations, childNamespaceItems);

  if(!(grayDelKeys == null || grayDelKeys.size()==0)){
    for (String key : grayDelKeys){
      configsToPublish.remove(key);
    }
  }
  // 发布子 Namespace 的 Release
  return branchRelease(parentNamespace, childNamespace, releaseName, releaseComment,
      configsToPublish, baseReleaseId, operator, ReleaseOperation.GRAY_RELEASE, isEmergencyPublish,
      childNamespaceItems.keySet());

}
```

- 第 5 至 12 行：获得最终的配置 Map 。

  - 第 6 行：调用 `#findLatestActiveRelease(parentNamespace)` 方法，获得**父** Namespace 的**最后有效** Release 对象。

  - 第 8 行：获得**父** Namespace 的配置 Map 。

  - 第 10 行：获得**父** Namespace 的 `releaseId` 属性。

  - 第 12 行：调用 `#mergeConfiguration(parentConfigurations, childNamespaceItems)` 方法，合并**父子** Namespace 的配置 Map 。代码如下：

    ```java
    private Map<String, String> mergeConfiguration(Map<String, String> baseConfigurations, Map<String, String> coverConfigurations) {
        Map<String, String> result = new HashMap<>();
        // copy base configuration
        // 父 Namespace 的配置项
        for (Map.Entry<String, String> entry : baseConfigurations.entrySet()) {
            result.put(entry.getKey(), entry.getValue());
        }
        // update and publish
        // 子 Namespace 的配置项
        for (Map.Entry<String, String> entry : coverConfigurations.entrySet()) {
            result.put(entry.getKey(), entry.getValue());
        }
        // 返回合并后的配置项
        return result;
    }
    ```

- 第 14 行：调用 `#branchRelease(...)` 方法，发布**子** Namespace 的 Release 。代码如下：

  ```java
  private Release branchRelease(Namespace parentNamespace, Namespace childNamespace,
                                String releaseName, String releaseComment,
                                Map<String, String> configurations, long baseReleaseId,
                                String operator, int releaseOperation, boolean isEmergencyPublish, Collection<String> branchReleaseKeys) {
    Release previousRelease = findLatestActiveRelease(childNamespace.getAppId(),
                                                      childNamespace.getClusterName(),
                                                      childNamespace.getNamespaceName()); // 获得子 Namespace 最后有效的 Release 对象
    long previousReleaseId = previousRelease == null ? 0 : previousRelease.getId(); // // 获得子 Namespace 最后有效的 Release 对象的编号
    // 创建 Map ，用于 ReleaseHistory 对象的 operationContext 属性。
    Map<String, Object> releaseOperationContext = Maps.newLinkedHashMap();
    releaseOperationContext.put(ReleaseOperationContext.BASE_RELEASE_ID, baseReleaseId);
    releaseOperationContext.put(ReleaseOperationContext.IS_EMERGENCY_PUBLISH, isEmergencyPublish);
    releaseOperationContext.put(ReleaseOperationContext.BRANCH_RELEASE_KEYS, branchReleaseKeys);
    // 创建子 Namespace 的 Release 对象，并保存
    Release release =
        createRelease(childNamespace, releaseName, releaseComment, configurations, operator);
    // 更新 GrayReleaseRule 的 releaseId 属性
    //update gray release rules
    GrayReleaseRule grayReleaseRule = namespaceBranchService.updateRulesReleaseId(childNamespace.getAppId(),
                                                                                  parentNamespace.getClusterName(),
                                                                                  childNamespace.getNamespaceName(),
                                                                                  childNamespace.getClusterName(),
                                                                                  release.getId(), operator);
    // 创建 ReleaseHistory 对象，并保存
    if (grayReleaseRule != null) {
      releaseOperationContext.put(ReleaseOperationContext.RULES, GrayReleaseRuleItemTransformer
          .batchTransformFromJSON(grayReleaseRule.getRules()));
    }
  
    releaseHistoryService.createReleaseHistory(parentNamespace.getAppId(), parentNamespace.getClusterName(),
                                               parentNamespace.getNamespaceName(), childNamespace.getClusterName(),
                                               release.getId(),
                                               previousReleaseId, releaseOperation, releaseOperationContext, operator);
  
    return release;
  }
  ```

  - 第 6 行：获得**子** Namespace **最后有效**的 Release 对象。

  - 第 8 行：获得**子** Namespace 的 `releaseId` 属性。

  - 第 10 至 13 行：创建 Map ，用于 ReleaseHistory 对象的 `operationContext` 属性。

  - 第 16 行：调用 `#createRelease(...)` 方法，创建**子** Namespace 的 Release 对象，并**保存**到数据库中。

  - 第 18 至 24 行：**更新** GrayReleaseRule 的 `releaseId` 属性到数据库中。代码如下：

    ```java
    @Transactional
    public GrayReleaseRule updateRulesReleaseId(String appId, String clusterName, String namespaceName, String branchName, long latestReleaseId, String operator) {
        // 获得老的 GrayReleaseRule 对象
        GrayReleaseRule oldRules = grayReleaseRuleRepository.findTopByAppIdAndClusterNameAndNamespaceNameAndBranchNameOrderByIdDesc(appId, clusterName, namespaceName, branchName);
        if (oldRules == null) {
            return null;
        }
    
        // 创建新的 GrayReleaseRule 对象
        GrayReleaseRule newRules = new GrayReleaseRule();
        newRules.setBranchStatus(NamespaceBranchStatus.ACTIVE);
        newRules.setReleaseId(latestReleaseId); // update
        newRules.setRules(oldRules.getRules());
        newRules.setAppId(oldRules.getAppId());
        newRules.setClusterName(oldRules.getClusterName());
        newRules.setNamespaceName(oldRules.getNamespaceName());
        newRules.setBranchName(oldRules.getBranchName());
        newRules.setDataChangeCreatedBy(operator); // update
        newRules.setDataChangeLastModifiedBy(operator); // update
    
        // 保存新的 GrayReleaseRule 对象
        grayReleaseRuleRepository.save(newRules);
        // 删除老的 GrayReleaseRule 对象
        grayReleaseRuleRepository.delete(oldRules);
        return newRules;
    }
    ```

    - 删除**老的** GrayReleaseRule 对象。
    - 保存**新的** GrayReleaseRule 对象。

  - 第 26 至 33 行：调用 `ReleaseHistoryService#createReleaseHistory(...)` 方法，创建 ReleaseHistory 对象，并**保存**到数据库中。

## 2.2 mergeFromMasterAndPublishBranch

> 本小节不属于本文，考虑到和灰度发布相关，所以放在此处。

在**父** Namespace 发布 Release 后，会调用 `#mergeFromMasterAndPublishBranch(...)` 方法，自动将 **父** Namespace (主干) 合并到**子** Namespace (分支)，并进行一次子 Namespace 的发布。代码如下：

```java
private void mergeFromMasterAndPublishBranch(Namespace parentNamespace, Namespace childNamespace,
                                             Map<String, String> parentNamespaceItems,
                                             String releaseName, String releaseComment,
                                             String operator, Release masterPreviousRelease,
                                             Release parentRelease, boolean isEmergencyPublish) {
  //create release for child namespace
  Release childNamespaceLatestActiveRelease = findLatestActiveRelease(childNamespace);

  Map<String, String> childReleaseConfiguration; // 获得子 Namespace 的配置 Map
  Collection<String> branchReleaseKeys;
  if (childNamespaceLatestActiveRelease != null) {
    childReleaseConfiguration = GSON.fromJson(childNamespaceLatestActiveRelease.getConfigurations(), GsonType.CONFIG);
    branchReleaseKeys = getBranchReleaseKeys(childNamespaceLatestActiveRelease.getId());
  } else {
    childReleaseConfiguration = Collections.emptyMap();
    branchReleaseKeys = null;
  }
  // 获得父 Namespace 的配置 Map
  Map<String, String> parentNamespaceOldConfiguration = masterPreviousRelease == null ?
                                                        null : GSON.fromJson(masterPreviousRelease.getConfigurations(),
                                                                             GsonType.CONFIG);
  // 计算合并最新父 Namespace 的配置 Map 后的子 Namespace 的配置 Map
  Map<String, String> childNamespaceToPublishConfigs =
      calculateChildNamespaceToPublishConfiguration(parentNamespaceOldConfiguration, parentNamespaceItems,
          childReleaseConfiguration, branchReleaseKeys);

  //compare  // 若发生了变化，则进行一次子 Namespace 的发布
  if (!childNamespaceToPublishConfigs.equals(childReleaseConfiguration)) {
    branchRelease(parentNamespace, childNamespace, releaseName, releaseComment,
                  childNamespaceToPublishConfigs, parentRelease.getId(), operator,
                  ReleaseOperation.MASTER_NORMAL_RELEASE_MERGE_TO_GRAY, isEmergencyPublish, branchReleaseKeys);
  }

}
```

- 第 8 行：调用 `#findLatestActiveRelease(childNamespace)` 方法，获得**子** Namespace 的**最新且有效的** Release 。代码如下：

  ```java
  public Release findLatestActiveRelease(Namespace namespace) {
    return findLatestActiveRelease(namespace.getAppId(),
                                   namespace.getClusterName(), namespace.getNamespaceName());
  
  }
  
  public Release findLatestActiveRelease(String appId, String clusterName, String namespaceName) {
    return releaseRepository.findFirstByAppIdAndClusterNameAndNamespaceNameAndIsAbandonedFalseOrderByIdDesc(appId,
                                                                                                            clusterName,
                                                                                                            namespaceName);
  }
  ```

- 第 10 行：获得**父** Namespace 的配置 Map 。

- 第 12 至 14 行：计算**合并**最新父 Namespace 的配置 Map 后，子 Namespace 的配置 Map 。代码如下：

  ```java
  // 计算合并最新父 Namespace 的配置 Map 后，子 Namespace 的配置 Map
  private Map<String, String> calculateChildNamespaceToPublishConfiguration(
      Map<String, String> parentNamespaceOldConfiguration, Map<String, String> parentNamespaceNewConfiguration,
      Map<String, String> childNamespaceLatestActiveConfiguration, Collection<String> branchReleaseKeys) {
    //first. calculate child namespace modified configs
    // 以子 Namespace 的配置 Map 为基础，计算出差异的 Map
    Map<String, String> childNamespaceModifiedConfiguration = calculateBranchModifiedItemsAccordingToRelease(
        parentNamespaceOldConfiguration, childNamespaceLatestActiveConfiguration, branchReleaseKeys);
  
    //second. append child namespace modified configs to parent namespace new latest configuration
    return mergeConfiguration(parentNamespaceNewConfiguration, childNamespaceModifiedConfiguration);
  }
  
  // 以子 Namespace 的配置 Map 为基础，计算出差异的 Map
  private Map<String, String> calculateBranchModifiedItemsAccordingToRelease(
      Map<String, String> masterReleaseConfigs, Map<String, String> branchReleaseConfigs,
      Collection<String> branchReleaseKeys) {
    // 差异 Map
    Map<String, String> modifiedConfigs = new LinkedHashMap<>();
    // 若子 Namespace 的配置 Map 为空，直接返回空 Map
    if (CollectionUtils.isEmpty(branchReleaseConfigs)) {
      return modifiedConfigs;
    }
  
    // new logic, retrieve modified configurations based on branch release keys
    if (branchReleaseKeys != null) {
      for (String branchReleaseKey : branchReleaseKeys) {
        if (branchReleaseConfigs.containsKey(branchReleaseKey)) {
          modifiedConfigs.put(branchReleaseKey, branchReleaseConfigs.get(branchReleaseKey));
        }
      }
  
      return modifiedConfigs;
    }
  
    // old logic, retrieve modified configurations by comparing branchReleaseConfigs with masterReleaseConfigs
    if (CollectionUtils.isEmpty(masterReleaseConfigs)) { // 若父 Namespace 的配置 Map 为空，直接返回子 Namespace 的配置 Map
      return branchReleaseConfigs;
    }
    // 以子 Namespace 的配置 Map 为基础，计算出差异的 Map
    for (Map.Entry<String, String> entry : branchReleaseConfigs.entrySet()) {
  
      if (!Objects.equals(entry.getValue(), masterReleaseConfigs.get(entry.getKey()))) {
        modifiedConfigs.put(entry.getKey(), entry.getValue());
      }
    }
  
    return modifiedConfigs;
  
  }
  ```

  - 【第一步】逻辑看起来比较冗长和“绕”。简单的说，**子** Namespace 的配置 Map 是包含**老**的**父** Namespace 的配置 Map ，所以需要**剔除**。但是呢，剔除的过程中，又需要保留**子** Namespace 的**自定义**的配置项。这就是第二个方法，`#calculateBranchModifiedItemsAccordingToRelease(...)` 的逻辑。
  - 【第二步】做完上面的步骤后，就可以调用 `#mergeConfiguration(...)` 方法，合并**新**的**父** Namespace 的配置 Map 。
  - 胖友好好理解下。

- 第 17 至 22 行：若发生了变化，则调用 `#branchRelease(...)` 方法，进行一次**子** Namespace 的发布。这块就和 [「2.1 publishBranchNamespace」](https://www.iocoder.cn/Apollo/portal-publish-namespace-branch/#) 一致了。

  - 什么情况下会未发生变化呢？例如，**父** Namespace 修改配置项 `timeout: 2000 => 3000` ，而恰好**子** Namespace 修改配置项 `timeout: 2000=> 3000` 并且已经灰度发布。

# 3. 加载灰度配置

在 [《Apollo 源码解析 —— Config Service 配置读取接口》](http://www.iocoder.cn/Apollo/config-service-config-query-api/?self) 中，我们看到 `AbstractConfigService#findRelease(...)` 方法中，会读取根据客户端的情况，匹配是否有**灰度 Release** ，代码如下：

```java
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

- 第 17 行：调用 `GrayReleaseRulesHolder#findReleaseIdFromGrayReleaseRule(...)` 方法，读取灰度发布编号，即 `GrayReleaseRule.releaseId` 属性。详细解析，在 [「3.1 GrayReleaseRulesHolder」](https://www.iocoder.cn/Apollo/portal-publish-namespace-branch/#) 中。
- 第 18 至 22 行：调用 `#findActiveOne(grayReleaseId, clientMessages)` 方法，读取**灰度** Release 对象。

## 3.1 GrayReleaseRulesHolder

`com.ctrip.framework.apollo.biz.grayReleaseRule.GrayReleaseRulesHolder` ，实现 InitializingBean 和 ReleaseMessageListener 接口，GrayReleaseRule **缓存** Holder ，用于提高对 GrayReleaseRule 的读取速度。

### 3.1.1 构造方法

```java
public class GrayReleaseRulesHolder implements ReleaseMessageListener, InitializingBean { // 缓存Holder ，用于提高对 GrayReleaseRule 的读取速度
  private static final Logger logger = LoggerFactory.getLogger(GrayReleaseRulesHolder.class);
  private static final Joiner STRING_JOINER = Joiner.on(ConfigConsts.CLUSTER_NAMESPACE_SEPARATOR);
  private static final Splitter STRING_SPLITTER =
      Splitter.on(ConfigConsts.CLUSTER_NAMESPACE_SEPARATOR).omitEmptyStrings();

  @Autowired
  private GrayReleaseRuleRepository grayReleaseRuleRepository;
  @Autowired
  private BizConfig bizConfig;

  private int databaseScanInterval; // 数据库扫描频率，单位：秒
  private ScheduledExecutorService executorService; // ExecutorService 对象
  //store configAppId+configCluster+configNamespace -> GrayReleaseRuleCache map
  private Multimap<String, GrayReleaseRuleCache> grayReleaseRuleCache; // GrayReleaseRuleCache 缓存。 KEY：configAppId+configCluster+configNamespace ，通过 {@link #assembleGrayReleaseRuleKey(String, String, String)} 生成。注意，KEY 中不包含 BranchName
  //store clientAppId+clientNamespace+ip -> ruleId map
  private Multimap<String, Long> reversedGrayReleaseRuleCache; // GrayReleaseRuleCache 缓存2。KEY：clientAppId+clientNamespace+ip ，通过 {@link #assembleReversedGrayReleaseRuleKey(String, String, String)} 生成。注意，KEY 中不包含 ClusterName
  //an auto increment version to indicate the age of rules
  private AtomicLong loadVersion; // 加载版本号

  public GrayReleaseRulesHolder() {
    loadVersion = new AtomicLong();
    grayReleaseRuleCache = Multimaps.synchronizedSetMultimap(
        TreeMultimap.create(String.CASE_INSENSITIVE_ORDER, Ordering.natural()));
    reversedGrayReleaseRuleCache = Multimaps.synchronizedSetMultimap(
        TreeMultimap.create(String.CASE_INSENSITIVE_ORDER, Ordering.natural()));
    executorService = Executors.newScheduledThreadPool(1, ApolloThreadFactory
        .create("GrayReleaseRulesHolder", true));
  }
  // ... 省略其他接口和属性
}
```

- 缓存相关
  - GrayReleaseRuleCache ，胖友先去 [「3.2 GrayReleaseRuleCache」](https://www.iocoder.cn/Apollo/portal-publish-namespace-branch/#) ，在回过来。
  - `grayReleaseRuleCache`属性， GrayReleaseRuleCache 缓存。
    - KEY： `configAppId` + `configCluster` + `configNamespace` 拼接成，不包含 `branchName` 。因为我们在**匹配**灰度规则时，不关注 `branchName` 属性。
    - VALUE：GrayReleaseRuleCache 数组。因为 `branchName` 不包含在 KEY 中，而同一个 Namespace 可以创建多次灰度( 创建下一个需要将前一个灰度放弃 )版本，所以就会形成数组。
  - `reversedGrayReleaseRuleCache`属性，**反转**的 GrayReleaseRuleCache 缓存。
    - KEY：`clientAppId` + `clientNamespace` + `ip` 。**注意**，不包含 `clusterName` 属性。具体原因，我们下面的 `#hasGrayReleaseRule(clientAppId, clientIp, namespaceName)` 方法中，详细分享。
    - VALUE：GrayReleaseRule 的编号数组。
    - 为什么叫做**反转**呢？因为使用 GrayReleaseRule 的具体属性作为键，而使用 GrayReleaseRule 的编号作为值。
  - 通过**定时**扫描 + ReleaseMessage **近实时**通知，更新缓存。
- 定时任务相关
  - `executorService` 属性，ExecutorService 对象。
  - `databaseScanInterval` 属性，数据库扫描频率，单位：秒。
  - `loadVersion` 属性，加载版本。

### 3.1.2 初始化

`#afterPropertiesSet()` 方法，通过 Spring 调用，初始化 Scan 任务。代码如下：

```java
@Override
public void afterPropertiesSet() throws Exception {
  populateDataBaseInterval();  // 从 ServerConfig 中，读取任务的周期配置
  //force sync load for the first time
  periodicScanRules(); // 初始拉取 GrayReleaseRuleCache 到缓存
  executorService.scheduleWithFixedDelay(this::periodicScanRules, // 定时拉取 GrayReleaseRuleCache 到缓存
      getDatabaseScanIntervalSecond(), getDatabaseScanIntervalSecond(), getDatabaseScanTimeUnit()
  );
}
```

- 第 3 行：调用 `#populateDataBaseInterval()` 方法，从 ServerConfig 中，读取定时任务的周期配置。代码如下：

  ```java
  private void populateDataBaseInterval() {
      databaseScanInterval = bizConfig.grayReleaseRuleScanInterval(); // "apollo.gray-release-rule-scan.interval" ，默认为 60 。
  }
  ```

- 第 6 行：调用 `#periodicScanRules()` 方法，**初始**拉取 GrayReleaseRuleCache 到缓存。代码如下：

  ```java
  private void periodicScanRules() {
    Transaction transaction = Tracer.newTransaction("Apollo.GrayReleaseRulesScanner",
        "scanGrayReleaseRules");
    try {
      loadVersion.incrementAndGet(); // 递增加载版本号
      scanGrayReleaseRules(); // 从数据卷库中，扫描所有 GrayReleaseRules ，并合并到缓存中
      transaction.setStatus(Transaction.SUCCESS);
    } catch (Throwable ex) {
      transaction.setStatus(ex);
      logger.error("Scan gray release rule failed", ex);
    } finally {
      transaction.complete();
    }
  }
  
  private void scanGrayReleaseRules() {
    long maxIdScanned = 0;
    boolean hasMore = true;
  
    while (hasMore && !Thread.currentThread().isInterrupted()) { // 循环顺序分批加载 GrayReleaseRule ，直到结束或者线程打断
      List<GrayReleaseRule> grayReleaseRules = grayReleaseRuleRepository
          .findFirst500ByIdGreaterThanOrderByIdAsc(maxIdScanned);  // 顺序分批加载 GrayReleaseRule 500 条
      if (CollectionUtils.isEmpty(grayReleaseRules)) {
        break;
      }
      mergeGrayReleaseRules(grayReleaseRules); // 合并到 GrayReleaseRule 缓存
      int rulesScanned = grayReleaseRules.size();  // 获得新的 maxIdScanned ，取最后一条记录
      maxIdScanned = grayReleaseRules.get(rulesScanned - 1).getId();
      //batch is 500
      hasMore = rulesScanned == 500; // 若拉取不足 500 条，说明无 GrayReleaseRule 了
    }
  }
  ```

  - 循环**顺序**、**分批**加载 GrayReleaseRule ，直到**全部加载完**或者线程打断。
  - `loadVersion` 属性，**递增**加载版本号。
  - 调用 `#mergeGrayReleaseRules(List<GrayReleaseRule>)` 方法，**合并** GrayReleaseRule 数组，到缓存中。详细解析，见 [「3.1.4 mergeGrayReleaseRules」](https://www.iocoder.cn/Apollo/portal-publish-namespace-branch/#) 。
  - 🙂 其他代码比较简单，胖友自己看代码注释。

- 第 7 至 10 行：创建定时任务，定时调用 `#scanGrayReleaseRules()` 方法，**重新全量**拉取 GrayReleaseRuleCache 到缓存。

### 3.1.3 handleMessage

`#handleMessage(ReleaseMessage, channel)` **实现**方法，基于 ReleaseMessage **近实时**通知，更新缓存。代码如下：

```java
@Override
public void handleMessage(ReleaseMessage message, String channel) {
  logger.info("message received - channel: {}, message: {}", channel, message);
  String releaseMessage = message.getMessage();
  if (!Topics.APOLLO_RELEASE_TOPIC.equals(channel) || Strings.isNullOrEmpty(releaseMessage)) { // 只处理 APOLLO_RELEASE_TOPIC 的消息
    return;
  }
  List<String> keys = STRING_SPLITTER.splitToList(releaseMessage); // 获得 appId cluster namespace 参数
  //message should be appId+cluster+namespace
  if (keys.size() != 3) {
    logger.error("message format invalid - {}", releaseMessage);
    return;
  }
  String appId = keys.get(0);
  String cluster = keys.get(1);
  String namespace = keys.get(2);
  // 获得对应的 GrayReleaseRule 数组
  List<GrayReleaseRule> rules = grayReleaseRuleRepository
      .findByAppIdAndClusterNameAndNamespaceName(appId, cluster, namespace);
  // 合并到 GrayReleaseRule 缓存中
  mergeGrayReleaseRules(rules);
}
```

- 第 5 至 8 行：只处理 **APOLLO_RELEASE_TOPIC** 的消息。
- 第 9 至 18 行：获得 `appId` `cluster` `namespace` 参数。
- 第 21 行：调用 `grayReleaseRuleRepository#findByAppIdAndClusterNameAndNamespaceName(appId, cluster, namespace)` 方法，获得对应的 GrayReleaseRule 数组。
- 第 23 行：调用 `#mergeGrayReleaseRules(List<GrayReleaseRule>)` 方法，合并到 GrayReleaseRule 缓存中。详细解析，见 [「3.1.4 mergeGrayReleaseRules」](https://www.iocoder.cn/Apollo/portal-publish-namespace-branch/#) 。

### 3.1.4 mergeGrayReleaseRules

`#mergeGrayReleaseRules(List<GrayReleaseRule>)` 方法，合并 GrayReleaseRule 到缓存中。代码如下：

```java
private void mergeGrayReleaseRules(List<GrayReleaseRule> grayReleaseRules) {
  if (CollectionUtils.isEmpty(grayReleaseRules)) {
    return;
  }
  for (GrayReleaseRule grayReleaseRule : grayReleaseRules) { // !!! 注意，下面我们说的“老”，指的是已经在缓存中，但是实际不一定“老”。
    if (grayReleaseRule.getReleaseId() == null || grayReleaseRule.getReleaseId() == 0) { // 无对应的 Release 编号，记未灰度发布，则无视
      //filter rules with no release id, i.e. never released
      continue;
    }
    String key = assembleGrayReleaseRuleKey(grayReleaseRule.getAppId(), grayReleaseRule
        .getClusterName(), grayReleaseRule.getNamespaceName()); // 创建 grayReleaseRuleCache 的 KEY
    //create a new list to avoid ConcurrentModificationException // 从缓存 grayReleaseRuleCache 读取，并创建数组，避免并发
    List<GrayReleaseRuleCache> rules = Lists.newArrayList(grayReleaseRuleCache.get(key));
    GrayReleaseRuleCache oldRule = null; // 获得子 Namespace 对应的老的 GrayReleaseRuleCache 对象
    for (GrayReleaseRuleCache ruleCache : rules) {
      if (ruleCache.getBranchName().equals(grayReleaseRule.getBranchName())) {
        oldRule = ruleCache;
        break;
      }
    }
    // 忽略，若不存在老的 GrayReleaseRuleCache ，并且当前 GrayReleaseRule 对应的分支不处于激活( 有效 )状态
    //if old rule is null and new rule's branch status is not active, ignore
    if (oldRule == null && grayReleaseRule.getBranchStatus() != NamespaceBranchStatus.ACTIVE) {
      continue;
    }
    // 若新的 GrayReleaseRule 为新增或更新，进行缓存更新
    //use id comparison to avoid synchronization
    if (oldRule == null || grayReleaseRule.getId() > oldRule.getRuleId()) {
      addCache(key, transformRuleToRuleCache(grayReleaseRule));  // 添加新的 GrayReleaseRuleCache 到缓存中
      if (oldRule != null) {
        removeCache(key, oldRule); // 移除老的 GrayReleaseRuleCache 出缓存中
      }
    } else {  // 老的 GrayReleaseRuleCache 对应的分支处于激活( 有效 )状态，更新加载版本号。
      // 例如，定时轮询，有可能，早于 #handleMessage(...) 拿到对应的新的 GrayReleaseRule 记录，那么此时规则编号是相等的，不符合上面的条件，但是符合这个条件。
      // 再例如，两次定时轮询，第二次和第一次的规则编号是相等的，不符合上面的条件，但是符合这个条件。
      if (oldRule.getBranchStatus() == NamespaceBranchStatus.ACTIVE) {
        //update load version
        oldRule.setLoadVersion(loadVersion.get());
      } else if ((loadVersion.get() - oldRule.getLoadVersion()) > 1) { // 保留两轮，适用于 GrayReleaseRule.branchStatus 为 DELETED 或 MERGED 的情况
        //remove outdated inactive branch rule after 2 update cycles
        removeCache(key, oldRule);
      }
    }
  }
}
```

- 第 5 行：**!!! 注意**，下面我们说的“老”，指的是已经在缓存中，但是实际不一定“老”。

- 第 6 行：**循环** GrayReleaseRule 数组，合并到缓存中。被缓存到的 GrayReleaseRule 对象，我们称为“**新**”的。

- 第 7 至 11 行：**无视**，若 GrayReleaseRule 无对应的 Release 编号，说明该**子** Namespace 还未灰度发布。

- 第 12 至 24 行：获得子 Namespace 对应的**老**的 GrayReleaseRuleCache 对象。此处的“老”，指的是**缓存中**的。

- 第 26 至 30 行：**无视**，若不存在老的 GrayReleaseRuleCache ，并且当前 GrayReleaseRule 对应的分支不处于激活( **ACTIVE** 有效 )状态。

- 第 32 至 40 行：若**新**的 GrayReleaseRule 为新增或更新( 编号**更大**)，进行缓存更新，并移除**老**的 GrayReleaseRule 出缓存。

  - 第 36 行：调用 `transformRuleToRuleCache(GrayReleaseRule)` 方法，将 GrayReleaseRule 转换成 GrayReleaseRuleCache 对象。详细解析，见 [「3.1.4.1 transformRuleToRuleCache」](https://www.iocoder.cn/Apollo/portal-publish-namespace-branch/#) 。
  - 第 36 行：调用 `#addCache(key, GrayReleaseRuleCache)` 方法，添加**新**的 GrayReleaseRuleCache 到缓存中。详细解析，见 [「3.1.4.2 addCache」](https://www.iocoder.cn/Apollo/portal-publish-namespace-branch/#) 。
  - 第 37 至 40 行：调用 `#remove(key, oldRule)` 方法，移除**老** 的 GrayReleaseRuleCache 出缓存。详细解析，见 [「3.1.4.3 removeCache」](https://www.iocoder.cn/Apollo/portal-publish-namespace-branch/#) 。

- 第 42 至 47 行：**老**的 GrayReleaseRuleCache 对应的分支处于激活( 有效 )状态，更新加载版本号。

  - 例如，定时轮询，有可能，早于 `#handleMessage(...)` 拿到对应的新的 GrayReleaseRule 记录，那么此时规则编号是相等的，不符合上面的条件，但是符合这个条件。
  - 再例如，两次定时轮询，第二次和第一次的规则编号是相等的，不符合上面的条件，但是符合这个条件。
  - **总结**，刷新有效的 GrayReleaseRuleCache 对象的 `loadVersion` 。

- 第 50 至 53 行：若 `GrayReleaseRule.branchStatus` 为 DELETED 或 MERGED 的情况，保留两轮定时扫描，后调用 `#remove(key, oldRule)` 方法，移除出缓存。

  - 例如，灰度全量发布时，会添加 `GrayReleaseRule.branchStatus` 为 **MERGED** 到缓存中。保留两轮，进行移除出缓存。

  - 为什么是**两轮**？笔者请教了宋老师( Apollo 的作者之一 )，解答如下：

    > 这个是把已经inactive的rule删除，至于为啥保留两轮，这个可能只是个选择问题
    >
    > - T T 笔者表示还是不太明白，继续思考ing 。如果有知道的胖友，烦请告知。

#### 3.1.4.1 transformRuleToRuleCache

`#transformRuleToRuleCache(GrayReleaseRule)` 方法，将 GrayReleaseRule 转换成 GrayReleaseRuleCache 对象。代码如下：

```java
private GrayReleaseRuleCache transformRuleToRuleCache(GrayReleaseRule grayReleaseRule) {
    // 转换出 GrayReleaseRuleItemDTO 数组
    Set<GrayReleaseRuleItemDTO> ruleItems;
    try {
        ruleItems = GrayReleaseRuleItemTransformer.batchTransformFromJSON(grayReleaseRule.getRules());
    } catch (Throwable ex) {
        ruleItems = Sets.newHashSet();
        Tracer.logError(ex);
        logger.error("parse rule for gray release rule {} failed", grayReleaseRule.getId(), ex);
    }
    // 创建 GrayReleaseRuleCache 对象，并返回
    return new GrayReleaseRuleCache(grayReleaseRule.getId(),
            grayReleaseRule.getBranchName(), grayReleaseRule.getNamespaceName(), grayReleaseRule
            .getReleaseId(), grayReleaseRule.getBranchStatus(), loadVersion.get(), ruleItems);
}
```

#### 3.1.4.2 addCache

`#addCache(key, GrayReleaseRuleCache)` 方法，添加**新**的 GrayReleaseRuleCache 到缓存中。代码如下：

```java
 1: private void addCache(String key, GrayReleaseRuleCache ruleCache) {
 2:     // 添加到 reversedGrayReleaseRuleCache 中
 3:     // 为什么这里判断状态？因为删除灰度，或者灰度全量发布的情况下，是无效的，所以不添加到 reversedGrayReleaseRuleCache 中
 4:     if (ruleCache.getBranchStatus() == NamespaceBranchStatus.ACTIVE) {
 5:         for (GrayReleaseRuleItemDTO ruleItemDTO : ruleCache.getRuleItems()) {
 6:             for (String clientIp : ruleItemDTO.getClientIpList()) {
 7:                 reversedGrayReleaseRuleCache.put(assembleReversedGrayReleaseRuleKey(ruleItemDTO.getClientAppId(), ruleCache.getNamespaceName(), clientIp),
 8:                         ruleCache.getRuleId());
 9:             }
10:         }
11:     }
12:     // 添加到 grayReleaseRuleCache
13:     // 这里为什么可以添加？因为添加到 grayReleaseRuleCache 中是个对象，可以判断状态
14:     grayReleaseRuleCache.put(key, ruleCache);
15: }
```

- 第 2 至 11 行：添加到`reversedGrayReleaseRuleCache`中。
  - 为什么这里**判断状态**？因为删除灰度，或者灰度全量发布的情况下，是无效的，所以不添加到 `reversedGrayReleaseRuleCache` 中。
- 第 14 行：添加到`grayReleaseRuleCache`中。
  - 为什么这里**可以添加**？因为添加到 `grayReleaseRuleCache` 中是个对象，可以判断状态。

#### 3.1.4.3 removeCache

`#remove(key, oldRule)` 方法，移除**老** 的 GrayReleaseRuleCache 出缓存。代码如下：

```java
private void removeCache(String key, GrayReleaseRuleCache ruleCache) {
    // 移除出 grayReleaseRuleCache
    grayReleaseRuleCache.remove(key, ruleCache);
    // 移除出 reversedGrayReleaseRuleCache
    for (GrayReleaseRuleItemDTO ruleItemDTO : ruleCache.getRuleItems()) {
        for (String clientIp : ruleItemDTO.getClientIpList()) {
            reversedGrayReleaseRuleCache.remove(assembleReversedGrayReleaseRuleKey(ruleItemDTO.getClientAppId(), ruleCache.getNamespaceName(), clientIp),
                    ruleCache.getRuleId());
        }
    }
}
```

### 3.1.5 findReleaseIdFromGrayReleaseRule

`#findReleaseIdFromGrayReleaseRule(clientAppId, clientIp, configAppId, configCluster, configNamespaceName)` 方法，若匹配上灰度规则，返回对应的 Release 编号。代码如下：

```java
public Long findReleaseIdFromGrayReleaseRule(String clientAppId, String clientIp, String
        configAppId, String configCluster, String configNamespaceName) {
    // 判断 grayReleaseRuleCache 中是否存在
    String key = assembleGrayReleaseRuleKey(configAppId, configCluster, configNamespaceName);
    if (!grayReleaseRuleCache.containsKey(key)) {
        return null;
    }
    // 循环 GrayReleaseRuleCache 数组，获得匹配的 Release 编号
    // create a new list to avoid ConcurrentModificationException
    List<GrayReleaseRuleCache> rules = Lists.newArrayList(grayReleaseRuleCache.get(key));
    for (GrayReleaseRuleCache rule : rules) {
        // 校验 GrayReleaseRuleCache 对应的子 Namespace 的状态是否为有效
        //check branch status
        if (rule.getBranchStatus() != NamespaceBranchStatus.ACTIVE) {
            continue;
        }
        // 是否匹配灰度规则。若是，则返回。
        if (rule.matches(clientAppId, clientIp)) {
            return rule.getReleaseId();
        }
    }
    return null;
}
```

- 🙂 代码比较易懂，胖友自己看代码注释哈。

### 3.1.6 hasGrayReleaseRule

```java
/**
 * Check whether there are gray release rules for the clientAppId, clientIp, namespace
 * combination. Please note that even there are gray release rules, it doesn't mean it will always
 * load gray releases. Because gray release rules actually apply to one more dimension - cluster.
 */
public boolean hasGrayReleaseRule(String clientAppId, String clientIp, String namespaceName) {
    return reversedGrayReleaseRuleCache.containsKey(assembleReversedGrayReleaseRuleKey(clientAppId, namespaceName, clientIp))
            || reversedGrayReleaseRuleCache.containsKey(assembleReversedGrayReleaseRuleKey(clientAppId, namespaceName, GrayReleaseRuleItemDTO.ALL_IP));
}
```

- 我们来翻一下英文注释哈，非**直译**哈。

- 【一】Check whether there are gray release rules for the clientAppId, clientIp, namespace combination. 针对 `clientAppId` + `clientIp` + `namespaceName` ，校验是否有灰度规则。

- 【二】Please note that even there are gray release rules, it doesn’t mean it will always load gray releases. 请注意，即使返回 `true` ，也不意味着调用方能加载到灰度发布的配置。

- 【三】 Because gray release rules actually apply to one more dimension - cluster. 因为，`reversedGrayReleaseRuleCache` 的 KEY 不包含 `branchName` ，所以 `reversedGrayReleaseRuleCache` 的 VALUE 为**多个** `branchName` 的 Release 编号的**集合**。

- 那么为什么不包含 `branchName` 呢？在 [《Apollo 源码解析 —— Config Service 配置读取接口》](http://www.iocoder.cn/Apollo/config-service-config-query-api/?self) 一文中，我们看到 AbstractConfigService 中，`#loadConfig(...)` 方法中，是按照**集群**的**优先级**加载，代码如下：

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

  - 但是，笔者又想了想，应该也不是这个方法的原因，因为这个方法里，每个调用的方法，`clusterName` 是明确的，那么把 `clusterName` 融入到缓存 KEY 也是可以的。**所以应该不是这个原因**。

- 目前 `#hasGrayReleaseRule(clientAppId, clientIp, namespaceName)` 方法，仅仅被 ConfigFileController 调用。而 ConfigFileController 在调用时，确实是不知道自己使用哪个 `clusterName` 。恩恩，应该是这个原因。

## 3.2 GrayReleaseRuleCache

`com.ctrip.framework.apollo.biz.grayReleaseRule.GrayReleaseRuleCache` ，GrayReleaseRule 的缓存类。代码如下：

```java
public class GrayReleaseRuleCache implements Comparable<GrayReleaseRuleCache> {

  private long ruleId;
  
  // 缺少 appId
	// 缺少 clusterName

  private String branchName;
  private String namespaceName;
  private long releaseId;
  private long loadVersion; // 加载版本
  private int branchStatus;
  private Set<GrayReleaseRuleItemDTO> ruleItems;

  // 匹配 clientAppId + clientIp + clientLabel
  public boolean matches(String clientAppId, String clientIp, String clientLabel) {
    for (GrayReleaseRuleItemDTO ruleItem : ruleItems) {
      if (ruleItem.matches(clientAppId, clientIp, clientLabel)) {
        return true;
      }
    }
    return false;
  }

  // ... 省略其他接口和属性
}
```

相比 GrayReleaseRule 来说：

- **少**了 `appId` + `clusterName` 字段，因为在 GrayReleaseRulesHolder 中，缓存 KEY 会根据需要包含这两个字段。
- **多**了 `loadVersion` 字段，用于记录 GrayReleaseRuleCache 的加载版本，用于自动过期逻辑。



# 参考

[Apollo 源码解析 —— Portal 灰度发布](https://www.iocoder.cn/Apollo/portal-publish-namespace-branch/)

