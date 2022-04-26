# 1. 概述

> 老艿艿：本系列假定胖友已经阅读过 [《Apollo 官方 wiki 文档》](https://github.com/ctripcorp/apollo/wiki/) ，特别是 [《Apollo 官方 wiki 文档 —— 灰度发布使用指南》](https://github.com/ctripcorp/apollo/wiki/Apollo使用指南#五灰度发布使用指南)。

本文接 [《Apollo 源码解析 —— Portal 灰度发布》](http://www.iocoder.cn/Apollo/portal-publish-namespace-branch?self) ，分享灰度**全量**发布。

我们先来看看官方文档对**灰度全量发布**的使用指南，来理解下它的定义和流程。

> 如果灰度的配置测试下来比较理想，符合预期，那么就可以操作【全量发布】。
>
> 全量发布的效果是：
>
> 1. 灰度版本的配置会合并回主版本，在这个例子中，就是主版本的 timeout 会被更新成 3000
> 2. 主版本的配置会自动进行一次发布
> 3. 在全量发布页面，可以选择是否保留当前灰度版本，默认为不保留。
>
> ![灰度发布1](https://static.iocoder.cn/images/Apollo/2018_05_15/01.png)
> ![全量发布1](https://static.iocoder.cn/images/Apollo/2018_05_15/02.png)
> <img src="https://static.iocoder.cn/images/Apollo/2018_05_15/03.png" alt="全量发布2" style="zoom:67%;" />
>
> 我选择了不保留灰度版本，所以发布完的效果就是主版本的配置更新、灰度版本删除。点击主版本的实例列表，可以看到10.32.21.22和10.32.21.19都使用了主版本最新的配置。
>
> ![灰度发布2](https://static.iocoder.cn/images/Apollo/2018_05_15/04.png)

灰度**全量**发布，和 [《Apollo 源码解析 —— Portal 发布配置》](http://www.iocoder.cn/Apollo/portal-publish/?self) ，差异点在于，**多了一步配置合并**，所以代码实现上，有很多相似度。整体系统流程如下：

<img src="https://static.iocoder.cn/images/Apollo/2018_05_15/06.png" alt="流程" style="zoom:67%;" />

# 2. Portal 侧

## 2.1 NamespaceBranchController

在 `apollo-portal` 项目中，`com.ctrip.framework.apollo.portal.controller.NamespaceBranchController` ，提供 Namespace **分支**的 **API** 。

`#merge(...)` 方法，灰度**全量**发布，**合并**子 Namespace 变更的配置 Map 到父 Namespace ，并进行一次 **Release** 。代码如下：

```java
@PreAuthorize(value = "@permissionValidator.hasReleaseNamespacePermission(#appId, #namespaceName, #env)")
@PostMapping(value = "/apps/{appId}/envs/{env}/clusters/{clusterName}/namespaces/{namespaceName}/branches/{branchName}/merge")
public ReleaseDTO merge(@PathVariable String appId, @PathVariable String env,
                        @PathVariable String clusterName, @PathVariable String namespaceName,
                        @PathVariable String branchName, @RequestParam(value = "deleteBranch", defaultValue = "true") boolean deleteBranch,
                        @RequestBody NamespaceReleaseModel model) {
  // 若是紧急发布，但是当前环境未允许该操作，抛出 BadRequestException 异常
  if (model.isEmergencyPublish() && !portalConfig.isEmergencyPublishAllowed(Env.valueOf(env))) {
    throw new BadRequestException(String.format("Env: %s is not supported emergency publish now", env));
  }
  // 合并子 Namespace 变更的配置 Map 到父 Namespace ，并进行一次 Release
  ReleaseDTO createdRelease = namespaceBranchService.merge(appId, Env.valueOf(env), clusterName, namespaceName, branchName,
                                                           model.getReleaseTitle(), model.getReleaseComment(),
                                                           model.isEmergencyPublish(), deleteBranch);
  // 创建 ConfigPublishEvent 对象
  ConfigPublishEvent event = ConfigPublishEvent.instance();
  event.withAppId(appId)
      .withCluster(clusterName)
      .withNamespace(namespaceName)
      .withReleaseId(createdRelease.getId())
      .setMergeEvent(true)
      .setEnv(Env.valueOf(env));
  // 发布 ConfigPublishEvent 事件
  publisher.publishEvent(event);

  return createdRelease;
}
```

- **POST `/apps/{appId}/envs/{env}/clusters/{clusterName}/namespaces/{namespaceName}/branches/{branchName}/merge` 接口**，Request Body 传递 **JSON** 对象。
- `@PreAuthorize(...)` 注解，调用 `PermissionValidator#hasReleaseNamespacePermissio(appId, namespaceName)` 方法，**校验**是否有发布配置的权限。后续文章，详细分享。
- 第 7 至 10 行：**校验**若是紧急发布，但是当前环境未允许该操作，抛出 BadRequestException 异常。
- 第 11 至 14 行：调用 `NamespaceBranchService#merge(...)` 方法，合并子 Namespace 变更的配置 Map 到父 Namespace ，并进行一次 Release 。
- 第 16 至 25 行：创建 ConfigPublishEvent 对象，并调用 `ApplicationEventPublisher#publishEvent(event)` 方法，发布 ConfigPublishEvent 事件。这部分，我们在后续文章分享。
- 第 26 行：返回 **ReleaseDTO** 对象。

## 2.2 NamespaceBranchService

在 `apollo-portal` 项目中，`com.ctrip.framework.apollo.portal.service.NamespaceBranchService` ，提供 Namespace **分支**的 **Service** 逻辑。

`#merge(...)` 方法，调用 Admin Service API ，**合并**子 Namespace 变更的配置 Map 到父 Namespace ，并进行一次 **Release** 。代码如下：

```java
public ReleaseDTO merge(String appId, Env env, String clusterName, String namespaceName,
                        String branchName, String title, String comment,
                        boolean isEmergencyPublish, boolean deleteBranch) {
  String operator = userInfoHolder.getUser().getUserId();
  return merge(appId, env, clusterName, namespaceName, branchName, title, comment, isEmergencyPublish, deleteBranch, operator);
}
// 合并子 Namespace 变更的配置 Map 到父 Namespace ，并进行一次 Release
public ReleaseDTO merge(String appId, Env env, String clusterName, String namespaceName,
                        String branchName, String title, String comment,
                        boolean isEmergencyPublish, boolean deleteBranch, String operator) {
  // 计算变化的 Item 集合
  ItemChangeSets changeSets = calculateBranchChangeSet(appId, env, clusterName, namespaceName, branchName, operator);
  // 合并子 Namespace 变更的配置 Map 到父 Namespace ，并进行一次 Release
  ReleaseDTO mergedResult =
          releaseService.updateAndPublish(appId, env, clusterName, namespaceName, title, comment,
                  branchName, isEmergencyPublish, deleteBranch, changeSets);

  Tracer.logEvent(TracerEventType.MERGE_GRAY_RELEASE,
          String.format("%s+%s+%s+%s", appId, env, clusterName, namespaceName));

  return mergedResult;
}
```

- 第 10 行：调用 `#calculateBranchChangeSet(appId, env, clusterName, namespaceName, branchName)` 方法，计算变化的 Item 集合。详细解析，见 [「2.2.1 calculateBranchChangeSet」](https://www.iocoder.cn/Apollo/portal-publish-namespace-branch-to-master/#) 。

- 第12 至 13 行：调用 `ReleaseService#updateAndPublish(...)` 方法，调用 Admin Service API ，**合并**子 Namespace 变更的配置 Map 到父 Namespace ，并进行一次 **Release** 。代码如下：

  ```java
  @Autowired
  private AdminServiceAPI.ReleaseAPI releaseAPI;
  
  public ReleaseDTO updateAndPublish(String appId, Env env, String clusterName, String namespaceName,
                                     String releaseTitle, String releaseComment, String branchName,
                                     boolean isEmergencyPublish, boolean deleteBranch, ItemChangeSets changeSets) {
      return releaseAPI.updateAndPublish(appId, env, clusterName, namespaceName, releaseTitle, releaseComment, branchName,
              isEmergencyPublish, deleteBranch, changeSets);
  }
  ```

  - 方法内部，调用 `ReleaseAPI#updateAndPublish(...)` 方法，调用 Admin Service API ，合并子 Namespace 变更的配置 Map 到父 Namespace ，并进行一次 Release 。🙂 可能会有胖友会问，为什么不 NamespaceBranchService 直接调用 ReleaseAPI 呢？ReleaseAPI 属于 ReleaseService 模块，对外**透明**、**屏蔽**该细节。这样，未来 ReleaseService 想要改实现，可能不是调用 ReleaseAPI 的方法，而是别的方法，也是非常方便的。

### 2.2.1 calculateBranchChangeSet

```java
private ItemChangeSets calculateBranchChangeSet(String appId, Env env, String clusterName, String namespaceName,
                                                String branchName, String operator) {
  NamespaceBO parentNamespace = namespaceService.loadNamespaceBO(appId, env, clusterName, namespaceName); // 获得父 NamespaceBO 对象

  if (parentNamespace == null) {  // 若父 Namespace 不存在，抛出 BadRequestException 异常
    throw new BadRequestException("base namespace not existed");
  }

  if (parentNamespace.getItemModifiedCnt() > 0) { // 若父 Namespace 有配置项的变更，不允许合并。因为，可能存在冲突
    throw new BadRequestException("Merge operation failed. Because master has modified items");
  }
  // 获得父 Namespace 的 Item 数组
  List<ItemDTO> masterItems = itemService.findItems(appId, env, clusterName, namespaceName);
  // 获得子 Namespace 的 Item 数组
  List<ItemDTO> branchItems = itemService.findItems(appId, env, branchName, namespaceName);
  // 计算变化的 Item 集合
  ItemChangeSets changeSets = itemsComparator.compareIgnoreBlankAndCommentItem(parentNamespace.getBaseInfo().getId(),
                                                                               masterItems, branchItems);
  changeSets.setDeleteItems(Collections.emptyList()); // 设置 ItemChangeSets.deleteItem 为空。因为子 Namespace 从父 Namespace 继承配置，但是实际自己没有那些配置项，所以如果不清空，会导致这些配置项被删除
  changeSets.setDataChangeLastModifiedBy(operator); // 设置 ItemChangeSets.dataChangeLastModifiedBy 为当前管理员
  return changeSets;
}
```

- 第 11 至 20 行，父 Namespace 相关
  - 第 12 行：调用 [`namespaceService#loadNamespaceBO(appId, env, clusterName, namespaceName)`](https://github.com/YunaiV/apollo/blob/80166648912b03667cd92e234e93927e1bb096ff/apollo-portal/src/main/java/com/ctrip/framework/apollo/portal/service/NamespaceService.java#L147-L310) 方法，获得父 [**NamespaceBO**](https://github.com/YunaiV/apollo/blob/80166648912b03667cd92e234e93927e1bb096ff/apollo-portal/src/main/java/com/ctrip/framework/apollo/portal/entity/bo/NamespaceBO.java) 对象。该对象，包含了 Namespace 的**详细**数据，包括 Namespace 的基本信息、配置集合。详细解析，点击方法链接查看，笔者已经添加详细注释。方法比较**冗长**，胖友耐心阅读，其目的是为了【第 17 至 20 行】的判断，是否有**未发布**的配置变更。
  - 第 13 至 16 行：若**父** Namespace 不存在，抛出 BadRequestException 异常。
  - 第 17 至 20 行：若**父** Namespace 有**未发布**的配置变更，不允许合并。因为，可能存在冲突，无法自动解决。此时，需要在 Portal 上将**父** Namespace 的配置进行一次发布，或者回退回历史版本。
- 第 21 至 30 行：获得配置变更集合 ItemChangeSets 对象。该对象，我们在 [《Apollo 源码解析 —— Portal 批量变更 Item》](http://www.iocoder.cn/Apollo/portal-update-item-set/?self) 中已介绍过。
  - 第 22 行：调用 `ItemService#findItems(appId, env, clusterName, namespaceName)` 方法，获得**父** Namespace 的 ItemDTO 数组。
  - 第 24 行：调用 `ItemService#findItems(appId, env, branchName, namespaceName)` 方法，获得**子** Namespace 的 ItemDTO 数组。
  - 第 26 行：调用 [`ItemsComparator#compareIgnoreBlankAndCommentItem(baseNamespaceId, baseItems, targetItems)`](https://github.com/YunaiV/apollo/blob/80166648912b03667cd92e234e93927e1bb096ff/apollo-portal/src/main/java/com/ctrip/framework/apollo/portal/component/ItemsComparator.java) 方法，计算**变化**的 Item 集合。详细解析，点击方法链接查看，笔者已经添加详细注释。
  - 第 28 行：设置 `ItemChangeSets.deleteItem` 为**空**。因为**子** Namespace 从**父** Namespace 继承配置，但是实际自己没有那些配置项，所以如果不设置为空，会导致合并时，这些配置项被删除。

## 2.3 ReleaseAPI

`com.ctrip.framework.apollo.portal.api.ReleaseAPI` ，实现 API 抽象类，封装对 Admin Service 的 Release 模块的 API 调用。代码如下：

![ReleaseAPI](http://blog-1259650185.cosbj.myqcloud.com/img/202204/06/1649231771.png)

# 3. Admin Service 侧

## 3.1 ReleaseController

在 `apollo-adminservice` 项目中， `com.ctrip.framework.apollo.adminservice.controller.ReleaseController` ，提供 Release 的 **API** 。

`#updateAndPublish(...)` 方法，**合并**子 Namespace 变更的配置 Map 到父 Namespace ，并进行一次 **Release** 。代码如下：

```java
@Transactional
@PostMapping("/apps/{appId}/clusters/{clusterName}/namespaces/{namespaceName}/updateAndPublish")
public ReleaseDTO updateAndPublish(@PathVariable("appId") String appId,
                                   @PathVariable("clusterName") String clusterName,
                                   @PathVariable("namespaceName") String namespaceName,
                                   @RequestParam("releaseName") String releaseName,
                                   @RequestParam("branchName") String branchName,
                                   @RequestParam(value = "deleteBranch", defaultValue = "true") boolean deleteBranch,
                                   @RequestParam(name = "releaseComment", required = false) String releaseComment,
                                   @RequestParam(name = "isEmergencyPublish", defaultValue = "false") boolean isEmergencyPublish,
                                   @RequestBody ItemChangeSets changeSets) {
  Namespace namespace = namespaceService.findOne(appId, clusterName, namespaceName); // 获得 Namespace
  if (namespace == null) {
    throw new NotFoundException("Could not find namespace for %s %s %s", appId, clusterName,
        namespaceName);
  }
  // 合并子 Namespace 变更的配置 Map 到父 Namespace ，并进行一次 Release
  Release release = releaseService.mergeBranchChangeSetsAndRelease(namespace, branchName, releaseName,
                                                                   releaseComment, isEmergencyPublish, changeSets);

  if (deleteBranch) { // 若需要删除子 Namespace ，则进行删除
    namespaceBranchService.deleteBranch(appId, clusterName, namespaceName, branchName,
                                        NamespaceBranchStatus.MERGED, changeSets.getDataChangeLastModifiedBy());
  }
  // 发送 Release 消息
  messageSender.sendMessage(ReleaseMessageKeyGenerator.generate(appId, clusterName, namespaceName),
                            Topics.APOLLO_RELEASE_TOPIC);
  // 将 Release 转换成 ReleaseDTO 对象
  return BeanUtils.transform(ReleaseDTO.class, release);

}
```

- 第 17 至 21 行：调用`NamespaceService#findOne(ppId, clusterName, namespaceName)`方法，获得**父**Namespace 对象。
  - 若校验到不存在，抛出 NotFoundException 异常。
- 第 23 行：调用 `ReleaseService#mergeBranchChangeSetsAndRelease(...)` 方法，合并**子** Namespace 变更的配置 Map 到**父** Namespace ，并进行一次 **Release** 。详细解析，见 [「3.2 ReleaseService」](https://www.iocoder.cn/Apollo/portal-publish-namespace-branch-to-master/#) 。
- 第 25 至 27 行：若需要**删除**子 Namespace ，即 Portal 中选择【删除灰度版本】，调用 `NamespaceBranchService#deleteBranch(...)` 方法，删除**子** Namespace 相关的记录。详细解析，见 [「3.3 NamespaceBranchService」](https://www.iocoder.cn/Apollo/portal-publish-namespace-branch-to-master/#) 。
- 第 29 行：调用 `MessageSender#sendMessage(String message, String channel)` 方法，发送发布消息。
- 第 31 行：调用 `BeanUtils#transfrom(Class<T> clazz, Object src)` 方法，将 Release **转换**成 ReleaseDTO 对象。

## 3.2 ReleaseService

在 `apollo-biz` 项目中，`com.ctrip.framework.apollo.biz.service.ReleaseService` ，提供 Release 的 **Service** 逻辑给 Admin Service 和 Config Service 。

### 3.2.1 mergeBranchChangeSetsAndRelease

`ReleaseService#mergeBranchChangeSetsAndRelease(...)` 方法，合并**子** Namespace 变更的配置 Map 到**父** Namespace ，并进行一次 **Release** 。代码如下：

```java
@Transactional
public Release mergeBranchChangeSetsAndRelease(Namespace namespace, String branchName, String releaseName,
                                               String releaseComment, boolean isEmergencyPublish,
                                               ItemChangeSets changeSets) {
  // 校验锁定
  checkLock(namespace, isEmergencyPublish, changeSets.getDataChangeLastModifiedBy());
  // 变更的配置集 合 ItemChangeSets 对象，更新到父 Namespace 中
  itemSetService.updateSet(namespace, changeSets);
  // 获得子 Namespace 的最新且有效的 Release 对象
  Release branchRelease = findLatestActiveRelease(namespace.getAppId(), branchName, namespace
      .getNamespaceName());
  long branchReleaseId = branchRelease == null ? 0 : branchRelease.getId(); // 获得子 Namespace 的最新且有效的 Release 编号
  // 获得父 Namespace 的配置 Map
  Map<String, String> operateNamespaceItems = getNamespaceItems(namespace);
  // 创建 Map ，用于 ReleaseHistory 对象的 operationContext 属性。
  Map<String, Object> operationContext = Maps.newLinkedHashMap();
  operationContext.put(ReleaseOperationContext.SOURCE_BRANCH, branchName);
  operationContext.put(ReleaseOperationContext.BASE_RELEASE_ID, branchReleaseId);
  operationContext.put(ReleaseOperationContext.IS_EMERGENCY_PUBLISH, isEmergencyPublish);
  // 父 Namespace 进行发布
  return masterRelease(namespace, releaseName, releaseComment, operateNamespaceItems,
                       changeSets.getDataChangeLastModifiedBy(),
                       ReleaseOperation.GRAY_RELEASE_MERGE_TO_MASTER, operationContext);

}

```

- 第 7 行：调用 `#checkLock(...)` 方法，**校验**锁定。
- 第 9 行：调用`ItemService#updateSet(namespace, changeSets)`方法，将变更的配置集 合 ItemChangeSets 对象，更新到**父**Namespace 中。详细解析，在 [《Apollo 源码解析 —— Portal 批量变更 Item》](http://www.iocoder.cn/Apollo/portal-update-item-set/?self) 中。
  - 第 17 行：调用 `#getNamespaceItems(namespace)` 方法，获得**父** Namespace 的配置 Map 。因为上面已经更新过，所以获得到的是**合并后**的结果。
- 第 11 至 23 行：创建 Map ，并设置需要的 KV ，用于 ReleaseHistory 对象的`operationContext`属性。
  - 第 12 行：调用 `#findLatestActiveRelease(...)` 方法，获得**子** Namespace 的**最新**且**有效**的 Release 对象。
  - 第 14 行：获得**子** Namespace 的**最新**且**有效**的 Release 编号。
  - 第 21 至 23 行：设置 KV 到 Map 中。
- 第 26 至 28 行：调用 `#masterRelease(...)` 方法，**父** Namespace 进行发布。这块，和 [《Apollo 源码解析 —— Portal 发布配置》](http://www.iocoder.cn/Apollo/portal-publish/?self) 的逻辑就统一了，所以详细解析，见该文。

## 3.3 NamespaceBranchService

在 `apollo-biz` 项目中，`com.ctrip.framework.apollo.biz.service.NamespaceBranchService` ，提供 Namespace **分支**的 **Service** 逻辑给 Admin Service 和 Config Service 。

### 3.3.1 deleteBranch

`#deleteBranch(...)` 方法，删除**子** Namespace 相关的记录。代码如下：

```java
@Transactional
public void deleteBranch(String appId, String clusterName, String namespaceName,
                         String branchName, int branchStatus, String operator) {
  Cluster toDeleteCluster = clusterService.findOne(appId, branchName); // 获得子 Cluster 对象
  if (toDeleteCluster == null) {
    return;
  }
  // 获得子 Namespace 的最后有效的 Release 对象
  Release latestBranchRelease = releaseService.findLatestActiveRelease(appId, branchName, namespaceName);
  // 获得子 Namespace 的最后有效的 Release 对象的编号
  long latestBranchReleaseId = latestBranchRelease != null ? latestBranchRelease.getId() : 0;

  //update branch rules // 创建新的，用于表示删除的 GrayReleaseRule 的对象
  GrayReleaseRule deleteRule = new GrayReleaseRule();
  deleteRule.setRules("[]");
  deleteRule.setAppId(appId);
  deleteRule.setClusterName(clusterName);
  deleteRule.setNamespaceName(namespaceName);
  deleteRule.setBranchName(branchName);
  deleteRule.setBranchStatus(branchStatus);
  deleteRule.setDataChangeLastModifiedBy(operator);
  deleteRule.setDataChangeCreatedBy(operator);
  // 更新 GrayReleaseRule
  doUpdateBranchGrayRules(appId, clusterName, namespaceName, branchName, deleteRule, false, -1);

  //delete branch cluster  // 删除子 Cluster
  clusterService.delete(toDeleteCluster.getId(), operator);

  int releaseOperation = branchStatus == NamespaceBranchStatus.MERGED ? ReleaseOperation
      .GRAY_RELEASE_DELETED_AFTER_MERGE : ReleaseOperation.ABANDON_GRAY_RELEASE;
  // 创建 ReleaseHistory 对象，并保存
  releaseHistoryService.createReleaseHistory(appId, clusterName, namespaceName, branchName, latestBranchReleaseId,
      latestBranchReleaseId, releaseOperation, null, operator);
  // 记录 Audit 到数据库中
  auditService.audit("Branch", toDeleteCluster.getId(), Audit.OP.DELETE, operator);
}
```

- 第 4 至 8 行：调用 `ClusterService#findOne(appId, branchName)` 方法，获得**子** Cluster 对象。

- 第 10 行：调用`ReleaseService#findLatestActiveRelease(namespace)`方法，获得**最后、有效的** Release 对象。

  - 第 12 行：获得**最后**、**有效**的 Release 对象的编号。

- 第 14 至 24 行：创建**新的**，用于表示删除的 GrayReleaseRule 的对象。并且，当前场景，该 GrayReleaseRule 的

  `branchStatus`为**MERGED**。

  - 第 26 行：调用 `#doUpdateBranchGrayRules(...)` 方法，更新 GrayReleaseRule 。详细解析，见 [《Apollo 源码解析 —— Portal 配置灰度规则》](http://www.iocoder.cn/Apollo/portal-modify-namespace-branch-gray-rules/?self) 中。

- 第 30 行：调用 `ClusterService#delte(id, operator)` 方法，删除子 Cluster 相关。详细解析，见 [「3.4 ClusterService」](https://www.iocoder.cn/Apollo/portal-publish-namespace-branch-to-master/#) 。

- 第 32 至 35 行：调用 `ReleaseHistoryService#createReleaseHistory(...)` 方法，创建 **ReleaseHistory** 对象，并保存。

- 第 37 行：记录 Audit 到数据库中。

## 3.4 ClusterService

在 `apollo-biz` 项目中，`com.ctrip.framework.apollo.biz.service.ClusterService` ，提供 Cluster 的 **Service** 逻辑给 Admin Service 和 Config Service 。

### 3.4.1 delete

`#delete(...)` 方法，删除 Cluster 相关。代码如下：

```java
@Transactional
public void delete(long id, String operator) {
    // 获得 Cluster 对象
    Cluster cluster = clusterRepository.findOne(id);
    if (cluster == null) {
        throw new BadRequestException("cluster not exist");
    }
    // 删除 Namespace
    // delete linked namespaces
    namespaceService.deleteByAppIdAndClusterName(cluster.getAppId(), cluster.getName(), operator);

    // 标记删除 Cluster
    cluster.setDeleted(true);
    cluster.setDataChangeLastModifiedBy(operator);
    clusterRepository.save(cluster);

    // 记录 Audit 到数据库中
    auditService.audit(Cluster.class.getSimpleName(), id, Audit.OP.DELETE, operator);
}
```

- 会**标记**删除 Cluster 和其相关的 Namespace 。代码比较简单，胖友自己看看哈。



# 参考

[Apollo 源码解析 —— Portal 灰度全量发布](https://www.iocoder.cn/Apollo/portal-publish-namespace-branch-to-master/)
