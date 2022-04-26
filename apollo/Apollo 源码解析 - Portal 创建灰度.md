# 1. 概述

> 老艿艿：本系列假定胖友已经阅读过 [《Apollo 官方 wiki 文档》](https://github.com/ctripcorp/apollo/wiki/) ，特别是 [《Apollo 官方 wiki 文档 —— 灰度发布使用指南》](https://github.com/ctripcorp/apollo/wiki/Apollo使用指南#五灰度发布使用指南)。

本文分享 **Portal 创建灰度** 的流程，整个过程涉及 Portal、Admin Service ，如下图所示：<img src="https://static.iocoder.cn/images/Apollo/2018_05_01/01.png" alt="流程" style="zoom:67%;" />

创建灰度，调用的是创建 Namespace **分支** 的 API 。通过创建的子 Namespace ，可以关联其自己定义的 Cluster、Item、Release 等等。关系如下所图所示：![关系图](https://static.iocoder.cn/images/Apollo/2018_05_01/02.png)

- 创建 Namespace**分支**时：
  - 会创建**子** Cluster ，指向**父** Cluster 。
  - 会创建**子** Namespace ，关联**子** Namespace 。实际上，**子** Namespace 和 **父** Namespace 无**任何**数据字段上的关联。
- 向**子** Namespace 添加 Item 时，该 Item 指向**子** Namespace 。虽然，代码实现和**父** Namespace 是**一模一样**的。
- **子** Namespace 发布( *灰度发布* ) 和 **父** Namespace 发布( *普通发布* ) 在代码实现，有一些差距，后续文章分享。

> 老艿艿：在目前 Apollo 的实现上，胖友可以把**分支**和**灰度**等价。
>
> - 所以下文在用词时，选择使用**分支**。
> - 所以下文在用词时，选择使用**分支**。
> - 所以下文在用词时，选择使用**分支**。

🙂 这样的设计，巧妙。

# 2. Portal 侧

## 2.1 NamespaceBranchController

在 `apollo-portal` 项目中，`com.ctrip.framework.apollo.portal.controller.NamespaceBranchController` ，提供 Namespace **分支**的 **API** 。

> 首先点击 application namespace 右上角的【创建灰度】按钮。
>
> ![创建灰度](https://static.iocoder.cn/images/Apollo/2018_05_01/03.png)
>
> 点击确定后，灰度版本就创建成功了，页面会自动切换到【灰度版本】 Tab 。
>
> ![灰度版本](https://static.iocoder.cn/images/Apollo/2018_05_01/04.png)

`#createBranch(...)` 方法，创建 Namespace **分支**。代码如下：

```java
@RestController
public class NamespaceBranchController {

  private final PermissionValidator permissionValidator;
  private final ReleaseService releaseService;
  private final NamespaceBranchService namespaceBranchService;
  private final ApplicationEventPublisher publisher;
  private final PortalConfig portalConfig;

  @PreAuthorize(value = "@permissionValidator.hasModifyNamespacePermission(#appId, #namespaceName, #env)")
  @PostMapping(value = "/apps/{appId}/envs/{env}/clusters/{clusterName}/namespaces/{namespaceName}/branches")
  public NamespaceDTO createBranch(@PathVariable String appId,
                                   @PathVariable String env,
                                   @PathVariable String clusterName,
                                   @PathVariable String namespaceName) {

    return namespaceBranchService.createBranch(appId, Env.valueOf(env), clusterName, namespaceName);
  }
  // ... 省略其他接口和属性
}
```

- **POST `"/apps/{appId}/envs/{env}/clusters/{clusterName}/namespaces/{namespaceName}/branches` 接口** 。
- `@PreAuthorize(...)` 注解，调用 `PermissionValidator#hasModifyNamespacePermission(appId, namespaceName)` 方法，校验是否有**修改** Namespace 的权限。后续文章，详细分享。
- 调用 `NamespaceBranchService#createBranch(...)` 方法，创建 Namespace **分支**。

## 2.2 NamespaceBranchService

在 `apollo-portal` 项目中，`com.ctrip.framework.apollo.portal.service.NamespaceBranchService` ，提供 Namespace **分支**的 **Service** 逻辑。

```java
@Service
public class NamespaceBranchService {

  private final ItemsComparator itemsComparator;
  private final UserInfoHolder userInfoHolder;
  private final NamespaceService namespaceService;
  private final ItemService itemService;
  private final AdminServiceAPI.NamespaceBranchAPI namespaceBranchAPI;
  private final ReleaseService releaseService;

  @Transactional
  public NamespaceDTO createBranch(String appId, Env env, String parentClusterName, String namespaceName) {
    String operator = userInfoHolder.getUser().getUserId();
    return createBranch(appId, env, parentClusterName, namespaceName, operator);
  }

  @Transactional
  public NamespaceDTO createBranch(String appId, Env env, String parentClusterName, String namespaceName, String operator) {
    NamespaceDTO createdBranch = namespaceBranchAPI.createBranch(appId, env, parentClusterName, namespaceName,
            operator); // 创建 Namespace 分支

    Tracer.logEvent(TracerEventType.CREATE_GRAY_RELEASE, String.format("%s+%s+%s+%s", appId, env, parentClusterName,
            namespaceName));
    return createdBranch;

  }
  // ... 省略其他接口和属性
}
```

- 第 9 行：调用 `NamespaceBranchAPI#createBranch(...)` 方法，创建 Namespace **分支**。
- 第 11 行：【TODO 6001】Tracer 日志

## 2.3 NamespaceBranchAPI

`com.ctrip.framework.apollo.portal.api.NamespaceBranchAPI` ，实现 API 抽象类，封装对 Admin Service 的 Namespace **分支**模块的 API 调用。代码如下：

![NamespaceBranchAPI](http://blog-1259650185.cosbj.myqcloud.com/img/202204/06/1649214160.png)

# 3. Admin Service 侧

## 3.1 NamespaceBranchController

在 `apollo-adminservice` 项目中， `com.ctrip.framework.apollo.adminservice.controller.NamespaceBranchController` ，提供 Namespace **分支**的 **API** 。

`#createBranch(...)` 方法，创建 Namespace **分支**。代码如下：

```java
@RestController
public class NamespaceBranchController {

  private final MessageSender messageSender;
  private final NamespaceBranchService namespaceBranchService;
  private final NamespaceService namespaceService;

  @PostMapping("/apps/{appId}/clusters/{clusterName}/namespaces/{namespaceName}/branches")
  public NamespaceDTO createBranch(@PathVariable String appId,
                                   @PathVariable String clusterName,
                                   @PathVariable String namespaceName,
                                   @RequestParam("operator") String operator) {
    // 校验 Namespace 是否存在
    checkNamespace(appId, clusterName, namespaceName);
    // 创建子 Namespace
    Namespace createdBranch = namespaceBranchService.createBranch(appId, clusterName, namespaceName, operator);
    // 将 Namespace 转换成 NamespaceDTO 对象
    return BeanUtils.transform(NamespaceDTO.class, createdBranch);
  }
  // ... 省略其他接口和属性
}
```

- 第 17 行：调用 `#checkNamespace(appId, clusterName, namespaceName)` ，**校验**父 Namespace 是否存在。代码如下：

  ```java
  private void checkNamespace(String appId, String clusterName, String namespaceName) {
      // 查询父 Namespace 对象
      Namespace parentNamespace = namespaceService.findOne(appId, clusterName, namespaceName);
      // 若父 Namespace 不存在，抛出 BadRequestException 异常
      if (parentNamespace == null) {
          throw new BadRequestException(String.format("Namespace not exist. AppId = %s, ClusterName = %s, NamespaceName = %s",
                  appId, clusterName, namespaceName));
      }
  }
  ```

- 第 19 行：调用 `NamespaceBranchService#createBranch(appId, clusterName, namespaceName, operator)` 方法，创建 Namespace **分支**。

- 第 21 行：调用 `BeanUtils#transfrom(Class<T> clazz, Object src)` 方法，将 Namespace **转换**成 NamespaceDTO 对象。

## 3.2 NamespaceBranchService

在 `apollo-biz` 项目中，`com.ctrip.framework.apollo.biz.service.NamespaceBranchService` ，提供 Namespace **分支**的 **Service** 逻辑给 Admin Service 和 Config Service 。

`#createBranch(appId, clusterName, namespaceName, operator)` 方法，创建 Namespace **分支**。即，新增**子** Cluster 和**子** Namespace 。代码如下：

```java
@Service
public class NamespaceBranchService {

  private final AuditService auditService;
  private final GrayReleaseRuleRepository grayReleaseRuleRepository;
  private final ClusterService clusterService;
  private final ReleaseService releaseService;
  private final NamespaceService namespaceService;
  private final ReleaseHistoryService releaseHistoryService;

  @Transactional
  public Namespace createBranch(String appId, String parentClusterName, String namespaceName, String operator){
    Namespace childNamespace = findBranch(appId, parentClusterName, namespaceName);  // 获得子 Namespace 对象
    if (childNamespace != null){ // 若存在子 Namespace 对象，则抛出 BadRequestException 异常。一个 Namespace 有且仅允许有一个子 Namespace
      throw new BadRequestException("namespace already has branch");
    }

    Cluster parentCluster = clusterService.findOne(appId, parentClusterName);  // 获得父 Cluster 对象
    if (parentCluster == null || parentCluster.getParentClusterId() != 0) {  // 若父 Cluster 对象不存在，抛出 BadRequestException 异常
      throw new BadRequestException("cluster not exist or illegal cluster");
    }

    //create child cluster // 创建子 Cluster 对象
    Cluster childCluster = createChildCluster(appId, parentCluster, namespaceName, operator);
    // 保存子 Cluster 对象
    Cluster createdChildCluster = clusterService.saveWithoutInstanceOfAppNamespaces(childCluster);

    //create child namespace // 创建子 Namespace 对象
    childNamespace = createNamespaceBranch(appId, createdChildCluster.getName(),
                                                        namespaceName, operator);
    return namespaceService.save(childNamespace); // 保存子 Namespace 对象
  }
  
  // ... 省略其他接口和属性
}
```

- 第 9 行：调用 `#findBranch(appId, parentClusterName, namespaceName)` 方法，获得**子** Namespace 对象。详细解析，见 [「3.2.1 findBranch」](https://www.iocoder.cn/Apollo/portal-create-namespace-branch/#) 。
- 第 10 至 13 行：**校验**若存在**子** Namespace 对象，则抛出 BadRequestException 异常。**一个 Namespace 有且仅允许有一个子 Namespace** 。
- 第 15 行：调用 `ClusterService#findOne(appId, parentClusterName)` 方法，获得**父** Cluster 对象。
- 第 16 至 19 行：**校验**若父 Cluster 对象不存在，则抛出 BadRequestException 异常。
- ========== 子 Cluster ==========
- 第 23 行：调用 `#createChildCluster(appId, parentCluster, namespaceName, operator)` 方法，创建**子** Cluster 对象。详细解析，见 [「3.2.2 createChildCluster」](https://www.iocoder.cn/Apollo/portal-create-namespace-branch/#) 。
- 第 25 行：调用 `ClusterService#saveWithoutInstanceOfAppNamespaces(Cluster)` 方法，保存**子** Cluster 对象。
- ========== 子 Namespace ==========
- 第 29 行：调用 `#createNamespaceBranch(appId, createdChildClusterName, namespaceName, operator)` 方法，创建**子** Namespace 对象。详细解析，见 [「3.2.3 createNamespaceBranch」](https://www.iocoder.cn/Apollo/portal-create-namespace-branch/#) 。
- 第 31 行：调用 `NamespaceService#save(childNamespace)` 方法，保存**子** Namespace 对象。

### 3.2.1 findBranch

`#findBranch(appId, parentClusterName, namespaceName)` 方法，获得**子** Namespace 对象。代码如下：

```java
public Namespace findBranch(String appId, String parentClusterName, String namespaceName) {
    return namespaceService.findChildNamespace(appId, parentClusterName, namespaceName);
}
```

------

`NamespaceService#findChildNamespace(appId, parentClusterName, namespaceName)` 方法，获得**子** Namespace 对象。代码如下：

```java
public Namespace findChildNamespace(String appId, String parentClusterName, String namespaceName) {
  List<Namespace> namespaces = findByAppIdAndNamespaceName(appId, namespaceName); // 获得 Namespace 数组
  if (CollectionUtils.isEmpty(namespaces) || namespaces.size() == 1) { // 若只有一个 Namespace ，说明没有子 Namespace
    return null;
  }
  // 获得 Cluster 数组
  List<Cluster> childClusters = clusterService.findChildClusters(appId, parentClusterName);
  if (CollectionUtils.isEmpty(childClusters)) { // 若无子 Cluster ，说明没有子 Namespace
    return null;
  }
  // 创建子 Cluster 的名字的集合
  Set<String> childClusterNames = childClusters.stream().map(Cluster::getName).collect(Collectors.toSet());
  //the child namespace is the intersection of the child clusters and child namespaces
  for (Namespace namespace : namespaces) { // 遍历 Namespace 数组，比较 Cluster 的名字。若符合，则返回该子 Namespace 对象
    if (childClusterNames.contains(namespace.getClusterName())) {
      return namespace;
    }
  }

  return null; // 无子 Namespace ，返回空
}
```

- 第 11 行：调用 `#findByAppIdAndNamespaceName(appId, namespaceName)` 方法，获得 **App 下所有的** Namespace 数组。代码如下：

  ```java
  public List<Namespace> findByAppIdAndNamespaceName(String appId, String namespaceName) {
      return namespaceRepository.findByAppIdAndNamespaceName(appId, namespaceName);
  }
  ```

- 第12 至 15 行：若只有**一个** Namespace ，说明没有**子** Namespace 。

- 第 17 行：调用 `ClusterService#findChildClusters(appId, parentClusterName)` 方法，获得 Cluster 数组。代码如下：

  ```java
  /**
   * 获得子 Cluster 数组
   *
   * @param appId App 编号
   * @param parentClusterName Cluster 名字
   * @return 子 Cluster 数组
   */
  public List<Cluster> findChildClusters(String appId, String parentClusterName) {
      // 获得父 Cluster 对象
      Cluster parentCluster = findOne(appId, parentClusterName);
      // 若不存在，抛出 BadRequestException 异常
      if (parentCluster == null) {
          throw new BadRequestException("parent cluster not exist");
      }
      // 获得子 Cluster 数组
      return clusterRepository.findByParentClusterId(parentCluster.getId());
  }
  ```

- 第 18 至 21 行：若无**子** Cluster ，说明没有**子** Namespace 。

- 第 23 行：创建**子** Cluster 的名字的集合。

- 第 24 至 30 行：遍历 Namespace 数组，若 Namespace 的 **Cluster 名字** 在 `childClusterNames` 中，返回该 Namespace 。因为【第 11 行】，获得 **App 下所有的** Namespace 数组。

### 3.2.2 createChildCluster

```java
private Cluster createChildCluster(String appId, Cluster parentCluster,
                                   String namespaceName, String operator) {

  Cluster childCluster = new Cluster();
  childCluster.setAppId(appId);
  childCluster.setParentClusterId(parentCluster.getId());
  childCluster.setName(UniqueKeyGenerator.generate(appId, parentCluster.getName(), namespaceName));
  childCluster.setDataChangeCreatedBy(operator);
  childCluster.setDataChangeLastModifiedBy(operator);

  return childCluster;
}
```

- `appId` 字段，指向和**父** Cluster 相同。
- `parentClusterId` 字段，指向**父** Cluster 编号。
- `name` 字段，调用 `UniqueKeyGenerator#generate(appId, parentClusterName, namespaceName)` 方法，创建唯一 KEY 。例如，`"20180422134118-dee27ba3456ff928"` 。

### 3.2.3 createNamespaceBranch

`#createNamespaceBranch(...)` 方法，创建**子** Namespace 对象。代码如下：

```java
private Namespace createNamespaceBranch(String appId, String clusterName, String namespaceName, String operator) {
  Namespace childNamespace = new Namespace();
  childNamespace.setAppId(appId);
  childNamespace.setClusterName(clusterName);
  childNamespace.setNamespaceName(namespaceName);
  childNamespace.setDataChangeLastModifiedBy(operator);
  childNamespace.setDataChangeCreatedBy(operator);
  return childNamespace;
}
```

- `appId` 字段，指向和**父** Namespace 相同。
- `clusterName` 字段，指向和**子** Cluster 编号。
- `namespaceName` 字段，和 **父** Namespace 的名字相同。



# 参考

[Apollo 源码解析 —— Portal 创建灰度](https://www.iocoder.cn/Apollo/portal-create-namespace-branch/)
