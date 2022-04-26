# 1. 概述

> 老艿艿：本系列假定胖友已经阅读过 [《Apollo 官方 wiki 文档》](https://github.com/ctripcorp/apollo/wiki/) 。

从本文开始，我们进入 Apollo **最最最**核心的流程 [配置发布后的实时推送设计](https://github.com/ctripcorp/apollo/wiki/Apollo配置中心设计#21-配置发布后的实时推送设计) 。

> 在配置中心中，一个重要的功能就是配置发布后实时推送到客户端。下面我们简要看一下这块是怎么设计实现的。
>
> ![配置发布](http://blog-1259650185.cosbj.myqcloud.com/img/202204/04/1649080506.png)
>
> 上图简要描述了配置发布的大致过程：
>
> 1. 用户在 Portal 操作配置发布
> 2. Portal 调用 Admin Service 的接口操作发布
> 3. Admin Service 发布配置后，发送 ReleaseMessage 给各个Config Service
> 4. Config Service 收到 ReleaseMessage 后，通知对应的客户端

本文分享 **Portal 发布配置**，对应上述第一、二步，大体流程如下：

![流程](http://blog-1259650185.cosbj.myqcloud.com/img/202204/04/1649080556.png)

- 😈 这个流程过程中，我们先不考虑**灰度**发布，会涉及**配置合并**的过程。

> 老艿艿：因为 Portal 是管理后台，所以从代码实现上，和业务系统非常相像。也因此，本文会略显啰嗦。

# 2. 实体

## 2.1 Release

`com.ctrip.framework.apollo.biz.entity.Release` ，继承 BaseEntity 抽象类，Release **实体**。代码如下：

```java
@Entity
@Table(name = "Release")
@SQLDelete(sql = "Update Release set IsDeleted = 1, DeletedAt = ROUND(UNIX_TIMESTAMP(NOW(4))*1000) where Id = ?")
@Where(clause = "isDeleted = 0")
public class Release extends BaseEntity {
  @Column(name = "ReleaseKey", nullable = false)
  private String releaseKey; // Release Key

  @Column(name = "Name", nullable = false)
  private String name; // 标题

  @Column(name = "AppId", nullable = false)
  private String appId; // App 编号

  @Column(name = "ClusterName", nullable = false)
  private String clusterName; // Cluster 名字

  @Column(name = "NamespaceName", nullable = false)
  private String namespaceName; // Namespace 名字

  @Column(name = "Configurations", nullable = false)
  @Lob
  private String configurations; // 配置 Map 字符串，使用 JSON 格式化成字符串

  @Column(name = "Comment", nullable = false)
  private String comment; // 备注

  @Column(name = "IsAbandoned", columnDefinition = "Bit default '0'")
  private boolean isAbandoned; // 是否被回滚（放弃）

}
```

- `releaseKey` 字段，用途？

- `name` 字段，发布标题。

- `comment` 字段，发布备注。

- `appId` + `clusterName` + `namespaceName` 字段，指向对应的 Namespace 记录。

- `configurations` 字段，发布时的**完整**配置 Map **字符串**，使用 JSON 格式化成字符串。

  - 和 `Commit.changeSets` 字段，格式**一致**，只是它是**变化**配置 Map **字符串**。

  - 例子如下：

    ```json
    {"huidu01":"huidu01"}
    ```

- `isAbandoned` 字段，是否被回滚（放弃）。

## 2.2 ReleaseHistory

`com.ctrip.framework.apollo.biz.entity.ReleaseHistory` ，继承 BaseEntity 抽象类，ReleaseHistory **实体**，记录每次 Release **相关**的操作日志。代码如下：

```java
@Entity
@Table(name = "ReleaseHistory")
@SQLDelete(sql = "Update ReleaseHistory set IsDeleted = 1, DeletedAt = ROUND(UNIX_TIMESTAMP(NOW(4))*1000) where Id = ?")
@Where(clause = "isDeleted = 0")
public class ReleaseHistory extends BaseEntity {
  @Column(name = "AppId", nullable = false)
  private String appId; // App 编号

  @Column(name = "ClusterName", nullable = false)
  private String clusterName; // Cluster 名字

  @Column(name = "NamespaceName", nullable = false)
  private String namespaceName; // Namespace 名字

  @Column(name = "BranchName", nullable = false)
  private String branchName; // Branch 名。主干，使用 Cluster 名字。分支，使用子 Cluster 名字

  @Column(name = "ReleaseId")
  private long releaseId; // Release 编号

  @Column(name = "PreviousReleaseId")
  private long previousReleaseId; // 上一次 Release 编号

  @Column(name = "Operation")
  private int operation; // 操作类型 {@link com.ctrip.framework.apollo.common.constants.ReleaseOperation}

  @Column(name = "OperationContext", nullable = false)
  private String operationContext; // 操作 Context

}
```

- `appId` + `clusterName` + `namespaceName` 字段，指向对应的 Namespace 记录。

- `branchName`字段，Branch 名字。

  - **主干**，使用 Cluster 名字。
  - **分支**，使用**子** Cluster 名字。

- `releaseId` 字段，Release 编号。

- `previousReleaseId` 字段，**上一次** Release 编号。

- `operation` 类型，操作类型。在 `com.ctrip.framework.apollo.common.constants.ReleaseOperation` 类中，枚举了所有发布相关的操作类型。代码如下：

  ```java
  public interface ReleaseOperation {
  
      int NORMAL_RELEASE = 0; // 主干发布
      int ROLLBACK = 1; // 回滚
      int GRAY_RELEASE = 2; // 灰度发布
      int APPLY_GRAY_RULES = 3; //
      int GRAY_RELEASE_MERGE_TO_MASTER = 4;
      int MASTER_NORMAL_RELEASE_MERGE_TO_GRAY = 5;
      int MATER_ROLLBACK_MERGE_TO_GRAY = 6;
      int ABANDON_GRAY_RELEASE = 7;
      int GRAY_RELEASE_DELETED_AFTER_MERGE = 8;
  
  }
  ```

- `operationContext` 字段，操作 Context 。

## 2.3 ReleaseMessage

## 2.3 ReleaseMessage

下一篇文章，详细分享。

# 3. Portal 侧

## 3.1 ReleaseController

在 `apollo-portal` 项目中，`com.ctrip.framework.apollo.portal.controller.ReleaseController` ，提供 Release 的 **API** 。

在【发布】的界面中，点击【 发布 】按钮，调用**发布配置的 API** 。

![发布配置](http://blog-1259650185.cosbj.myqcloud.com/img/202204/04/1649081092.png)

`#createRelease(appId, env, clusterName, namespaceName, NamespaceReleaseModel)` 方法，发布配置。代码如下：

```java
@Validated
@RestController
public class ReleaseController {

  private final ReleaseService releaseService;
  private final ApplicationEventPublisher publisher;
  private final PortalConfig portalConfig;
  private final PermissionValidator permissionValidator;
  private final UserInfoHolder userInfoHolder;

  public ReleaseController(
      final ReleaseService releaseService,
      final ApplicationEventPublisher publisher,
      final PortalConfig portalConfig,
      final PermissionValidator permissionValidator,
      final UserInfoHolder userInfoHolder) {
    this.releaseService = releaseService;
    this.publisher = publisher;
    this.portalConfig = portalConfig;
    this.permissionValidator = permissionValidator;
    this.userInfoHolder = userInfoHolder;
  }

  @PreAuthorize(value = "@permissionValidator.hasReleaseNamespacePermission(#appId, #namespaceName, #env)")
  @PostMapping(value = "/apps/{appId}/envs/{env}/clusters/{clusterName}/namespaces/{namespaceName}/releases")
  public ReleaseDTO createRelease(@PathVariable String appId,
                                  @PathVariable String env, @PathVariable String clusterName,
                                  @PathVariable String namespaceName, @RequestBody NamespaceReleaseModel model) {
    model.setAppId(appId); // 设置 PathVariable 变量到 NamespaceReleaseModel 中
    model.setEnv(env);
    model.setClusterName(clusterName);
    model.setNamespaceName(namespaceName);
    // 若是紧急发布，但是当前环境未允许该操作，抛出 BadRequestException 异常
    if (model.isEmergencyPublish() && !portalConfig.isEmergencyPublishAllowed(Env.valueOf(env))) {
      throw new BadRequestException(String.format("Env: %s is not supported emergency publish now", env));
    }
    // 发布配置
    ReleaseDTO createdRelease = releaseService.publish(model);
    // 创建 ConfigPublishEvent 对象
    ConfigPublishEvent event = ConfigPublishEvent.instance();
    event.withAppId(appId)
        .withCluster(clusterName)
        .withNamespace(namespaceName)
        .withReleaseId(createdRelease.getId())
        .setNormalPublishEvent(true)
        .setEnv(Env.valueOf(env));
    // 发布 ConfigPublishEvent 事件
    publisher.publishEvent(event);

    return createdRelease;
  }
  // ... 省略其他方法

}
```

- **POST `/apps/{appId}/envs/{env}/clusters/{clusterName}/namespaces/{namespaceName}/releases` 接口**，Request Body 传递 **JSON** 对象。

- `@PreAuthorize(...)` 注解，调用 `PermissionValidator#hasReleaseNamespacePermissio(appId, namespaceName)` 方法，**校验**是否有发布配置的权限。后续文章，详细分享。

- `com.ctrip.framework.apollo.portal.entity.model.NamespaceReleaseModel` ，Namespace 配置发布 Model 。代码如下：

  ```java
  public class NamespaceReleaseModel implements Verifiable {
  
    private String appId; // App 编号
    private String env; // Env 名字
    private String clusterName; // Cluster 名字
    private String namespaceName; // Namespace 名字
    private String releaseTitle; // 发布标题
    private String releaseComment; // 发布描述
    private String releasedBy; // 发布人
    private boolean isEmergencyPublish; // 是否紧急发布
  
  }
  ```

- 第 14 行：**校验** NamespaceReleaseModel 非空。

- 第 15 至 19 行：**设置** PathVariable 变量到 NamespaceReleaseModel 中。

- 第 20 至 23 行：**校验**若是紧急发布，但是当前环境未允许该操作，抛出 BadRequestException 异常。

  - **紧急发布**功能，可通过设置 **PortalDB** 的 ServerConfig 的`"emergencyPublish.supported.envs"` 配置开启对应的 **Env 们**。例如，`emergencyPublish.supported.envs = dev` 。

- 第 25 行：调用 `ReleaseService#publish(NamespaceReleaseModel)` 方法，调用 Admin Service API ，发布配置。

- 第 27 至 36 行：创建 ConfigPublishEvent 对象，并调用 `ApplicationEventPublisher#publishEvent(event)` 方法，发布 ConfigPublishEvent 事件。这部分，我们在后续文章分享。

- 第 38 行：返回 **ReleaseDTO** 对象。

## 3.2 ReleaseService

在 `apollo-portal` 项目中，`com.ctrip.framework.apollo.portal.service.ReleaseService` ，提供 Release 的 **Service** 逻辑。

`#publish(NamespaceReleaseModel)` 方法，调用 Admin Service API ，发布配置。代码如下：

```java
@Service
public class ReleaseService {

  private static final Gson GSON = new Gson();

  private final UserInfoHolder userInfoHolder;
  private final AdminServiceAPI.ReleaseAPI releaseAPI;
s
  public ReleaseDTO publish(NamespaceReleaseModel model) {
    Env env = model.getEnv();
    boolean isEmergencyPublish = model.isEmergencyPublish();
    String appId = model.getAppId();
    String clusterName = model.getClusterName();
    String namespaceName = model.getNamespaceName();
    String releaseBy = StringUtils.isEmpty(model.getReleasedBy()) ?
                       userInfoHolder.getUser().getUserId() : model.getReleasedBy();
    // 调用 Admin Service API ，发布 Namespace 的配置
    ReleaseDTO releaseDTO = releaseAPI.createRelease(appId, env, clusterName, namespaceName,
                                                     model.getReleaseTitle(), model.getReleaseComment(),
                                                     releaseBy, isEmergencyPublish);
    // Tracer 日志
    Tracer.logEvent(TracerEventType.RELEASE_NAMESPACE,
                    String.format("%s+%s+%s+%s", appId, env, clusterName, namespaceName));

    return releaseDTO;
  }
  // ... 省略其他方法

}
```

- 第14 至 17 行：调用 `ReleaseAPI#createRelease(appId, env, clusterName, namespaceName, releaseTitle, releaseComment, releaseBy, isEmergencyPublish)` 方法，调用 Admin Service API ，发布配置。
- 第 19 行：Tracer 日志

## 3.3 ReleaseAPI

`com.ctrip.framework.apollo.portal.api.ReleaseAPI` ，实现 API 抽象类，封装对 Admin Service 的 Release 模块的 API 调用。代码如下：

![ReleaseAPI](http://blog-1259650185.cosbj.myqcloud.com/img/202204/04/1649082504.png)

# 4. Admin Service 侧

## 4.1 ReleaseController

在 `apollo-adminservice` 项目中， `com.ctrip.framework.apollo.adminservice.controller.ReleaseController` ，提供 Release 的 **API** 。

`#publish(appId, env, clusterName, namespaceName, releaseTitle, releaseComment, releaseBy, isEmergencyPublish)` 方法，发布 Namespace 的配置。代码如下：

```java
@RestController
public class ReleaseController {

  private static final Splitter RELEASES_SPLITTER = Splitter.on(",").omitEmptyStrings()
      .trimResults();

  private final ReleaseService releaseService;
  private final NamespaceService namespaceService;
  private final MessageSender messageSender;
  private final NamespaceBranchService namespaceBranchService;

  @Transactional
  @PostMapping("/apps/{appId}/clusters/{clusterName}/namespaces/{namespaceName}/releases")
  public ReleaseDTO publish(@PathVariable("appId") String appId,
                            @PathVariable("clusterName") String clusterName,
                            @PathVariable("namespaceName") String namespaceName,
                            @RequestParam("name") String releaseName,
                            @RequestParam(name = "comment", required = false) String releaseComment,
                            @RequestParam("operator") String operator,
                            @RequestParam(name = "isEmergencyPublish", defaultValue = "false") boolean isEmergencyPublish) {
    Namespace namespace = namespaceService.findOne(appId, clusterName, namespaceName);
    if (namespace == null) { // 校验对应的 Namespace 对象是否存在。若不存在，抛出 NotFoundException 异常
      throw new NotFoundException("Could not find namespace for %s %s %s", appId, clusterName,
          namespaceName);
    }
    Release release = releaseService.publish(namespace, releaseName, releaseComment, operator, isEmergencyPublish); // 发布 Namespace 的配置

    //send release message 获得 Cluster 名
    Namespace parentNamespace = namespaceService.findParentNamespace(namespace);
    String messageCluster;
    if (parentNamespace != null) { // 灰度发布
      messageCluster = parentNamespace.getClusterName();
    } else {
      messageCluster = clusterName; // 使用请求的 ClusterName
    }
    messageSender.sendMessage(ReleaseMessageKeyGenerator.generate(appId, messageCluster, namespaceName),
                              Topics.APOLLO_RELEASE_TOPIC); // 发送 Release 消息
    return BeanUtils.transform(ReleaseDTO.class, release); // 将 Release 转换成 ReleaseDTO 对象
  }
  // ... 省略其他方法

}
```

- **POST `/apps/{appId}/clusters/{clusterName}/namespaces/{namespaceName}/releases` 接口**，Request Body 传递 **JSON** 对象。

- 第 17 至 21 行：**校验**对应的 Namespace 对象是否存在。若不存在，抛出 NotFoundException 异常。

- 第 23 行：调用 `ReleaseService#publish(namespace, releaseName, releaseComment, operator, isEmergencyPublish)` 方法，发布 Namespace 的配置，返回 **Release** 对象。

- 第 26 至 33 行：获得发布消息的 **Cluster** 名字。

  - 第 27 行：调用 `NamespaceService#findParentNamespace(namespace)` 方法，获得**父** Namespace 对象。代码如下：

    ```java
    @Autowired
    private ClusterService clusterService;
    @Autowired
    private ClusterService clusterService;
        
    public Namespace findParentNamespace(Namespace namespace) {
        String appId = namespace.getAppId();
        String namespaceName = namespace.getNamespaceName();
        // 获得 Cluster
        Cluster cluster = clusterService.findOne(appId, namespace.getClusterName());
        // 若为子 Cluster
        if (cluster != null && cluster.getParentClusterId() > 0) {
            // 获得父 Cluster
            Cluster parentCluster = clusterService.findOne(cluster.getParentClusterId());
            // 获得父 Namespace
            return findOne(appId, parentCluster.getName(), namespaceName);
        }
        return null;
    }
    
    public Namespace findOne(String appId, String clusterName, String namespaceName) {
        return namespaceRepository.findByAppIdAndClusterNameAndNamespaceName(appId, clusterName, namespaceName);
    }
    ```

    - 这块胖友可以先跳过，等看完后面**灰度发布**相关的内容，在回过头理解。

  - 第 29 至 30 行：若有**父** Namespace 对象，说明是**子** Namespace ( 灰度发布 )，则使用**父** Namespace 的 Cluster 名字。因为，客户端即使在灰度发布的情况下，也是使用 **父** Namespace 的 Cluster 名字。也就说，灰度发布，对客户端是透明无感知的。

  - 第 32 行：使用**请求**的 Cluster 名字。

- 第 35 行：调用 `MessageSender#sendMessage(String message, String channel)` 方法，发送发布消息。详细实现，下一篇文章详细解析。

- 第 38 行：调用 `BeanUtils#transfrom(Class<T> clazz, Object src)` 方法，将 Release **转换**成 ReleaseDTO 对象。

## 4.2 ReleaseService

在 `apollo-biz` 项目中，`com.ctrip.framework.apollo.biz.service.ReleaseService` ，提供 Release 的 **Service** 逻辑给 Admin Service 和 Config Service 。

### 4.2.1 publish

`#publish(namespace, releaseName, releaseComment, operator, isEmergencyPublish)` 方法，发布 Namespace 的配置。代码如下：

```java
@Service
public class ReleaseService {

  private static final FastDateFormat TIMESTAMP_FORMAT = FastDateFormat.getInstance("yyyyMMddHHmmss");
  private static final Gson GSON = new Gson();
  private static final Set<Integer> BRANCH_RELEASE_OPERATIONS = Sets
      .newHashSet(ReleaseOperation.GRAY_RELEASE, ReleaseOperation.MASTER_NORMAL_RELEASE_MERGE_TO_GRAY,
          ReleaseOperation.MATER_ROLLBACK_MERGE_TO_GRAY);
  private static final Pageable FIRST_ITEM = PageRequest.of(0, 1);
  private static final Type OPERATION_CONTEXT_TYPE_REFERENCE = new TypeToken<Map<String, Object>>() { }.getType();

  private final ReleaseRepository releaseRepository;
  private final ItemService itemService;
  private final AuditService auditService;
  private final NamespaceLockService namespaceLockService;
  private final NamespaceService namespaceService;
  private final NamespaceBranchService namespaceBranchService;
  private final ReleaseHistoryService releaseHistoryService;
  private final ItemSetService itemSetService;

  @Transactional
  public Release mergeBranchChangeSetsAndRelease(Namespace namespace, String branchName, String releaseName,
                                                 String releaseComment, boolean isEmergencyPublish,
                                                 ItemChangeSets changeSets) {

    checkLock(namespace, isEmergencyPublish, changeSets.getDataChangeLastModifiedBy());

    itemSetService.updateSet(namespace, changeSets);

    Release branchRelease = findLatestActiveRelease(namespace.getAppId(), branchName, namespace
        .getNamespaceName());
    long branchReleaseId = branchRelease == null ? 0 : branchRelease.getId();

    Map<String, String> operateNamespaceItems = getNamespaceItems(namespace);

    Map<String, Object> operationContext = Maps.newLinkedHashMap();
    operationContext.put(ReleaseOperationContext.SOURCE_BRANCH, branchName);
    operationContext.put(ReleaseOperationContext.BASE_RELEASE_ID, branchReleaseId);
    operationContext.put(ReleaseOperationContext.IS_EMERGENCY_PUBLISH, isEmergencyPublish);

    return masterRelease(namespace, releaseName, releaseComment, operateNamespaceItems,
                         changeSets.getDataChangeLastModifiedBy(),
                         ReleaseOperation.GRAY_RELEASE_MERGE_TO_MASTER, operationContext);

  }

  @Transactional
  public Release publish(Namespace namespace, String releaseName, String releaseComment,
                         String operator, boolean isEmergencyPublish) {
    // 校验锁定
    checkLock(namespace, isEmergencyPublish, operator);
    // 获得 Namespace 的普通配置 Map
    Map<String, String> operateNamespaceItems = getNamespaceItems(namespace);
    // 获得父 Namespace
    Namespace parentNamespace = namespaceService.findParentNamespace(namespace);
    // 若有父 Namespace ，则是子 Namespace ，进行灰度发布
    //branch release
    if (parentNamespace != null) {
      return publishBranchNamespace(parentNamespace, namespace, operateNamespaceItems,
                                    releaseName, releaseComment, operator, isEmergencyPublish);
    }
    // 获得子 Namespace 对象
    Namespace childNamespace = namespaceService.findChildNamespace(namespace);
    // 获得上一次，并且有效的 Release 对象
    Release previousRelease = null;
    if (childNamespace != null) {
      previousRelease = findLatestActiveRelease(namespace);
    }
    // 创建操作 Context
    //master release
    Map<String, Object> operationContext = Maps.newLinkedHashMap();
    operationContext.put(ReleaseOperationContext.IS_EMERGENCY_PUBLISH, isEmergencyPublish);
    // 主干发布
    Release release = masterRelease(namespace, releaseName, releaseComment, operateNamespaceItems,
                                    operator, ReleaseOperation.NORMAL_RELEASE, operationContext);  // 是否紧急发布。
    // 若有子 Namespace 时，自动将主干合并到子 Namespace ，并进行一次子 Namespace 的发布
    //merge to branch and auto release
    if (childNamespace != null) {
      mergeFromMasterAndPublishBranch(namespace, childNamespace, operateNamespaceItems,
                                      releaseName, releaseComment, operator, previousRelease,
                                      release, isEmergencyPublish);
    }

    return release;
  }
  // ... 省略其他方法

}
```

- 第 19 行：调用 `#checkLock(namespace, isEmergencyPublish, operator)` 方法，**校验** NamespaceLock 锁定。代码如下：

  ```java
  private void checkLock(Namespace namespace, boolean isEmergencyPublish, String operator) {
      if (!isEmergencyPublish) { // 非紧急发布
          // 获得 NamespaceLock 对象
          NamespaceLock lock = namespaceLockService.findLock(namespace.getId());
          // 校验锁定人是否是当前管理员。若是，抛出 BadRequestException 异常
          if (lock != null && lock.getDataChangeCreatedBy().equals(operator)) {
              throw new BadRequestException("Config can not be published by yourself.");
          }
      }
  }
  ```

- 第 21 行：调用 `#getNamespaceItems(namespace)` 方法，获得 Namespace 的**普通**配置 Map 。代码如下：

  ```java
  private Map<String, String> getNamespaceItems(Namespace namespace) {
      // 读取 Namespace 的 Item 集合
      List<Item> items = itemService.findItemsWithoutOrdered(namespace.getId());
      // 生成普通配置 Map 。过滤掉注释和空行的配置项
      Map<String, String> configurations = new HashMap<String, String>();
      for (Item item : items) {
          if (StringUtils.isEmpty(item.getKey())) {
              continue;
          }
          configurations.put(item.getKey(), item.getValue());
      }
      return configurations;
  }
  ```

- 第 23 行：调用 `#findParentNamespace(namespace)` 方法，获得**父** Namespace 对象。

- 第 26 至 28 行：若有**父** Namespace 对象，**灰度发布**。详细解析，见 [《Apollo 源码解析 —— Portal 灰度发布》](http://www.iocoder.cn/Apollo/portal-publish-namespace-branch?self) 。

- 第 30 行：调用 `NamespaceService#findChildNamespace(namespace)` 方法，获得子 Namespace 对象。详细解析，见 [《Apollo 源码解析 —— Portal 创建灰度》](http://www.iocoder.cn/Apollo/portal-create-namespace-branch/?slef) 。

- 第 31 至 35 行：调用 `#findLatestActiveRelease(Namespace)` 方法，获得**上一次**，并且有效的 Release 对象。代码如下：

  ```java
  public Release findLatestActiveRelease(Namespace namespace) {
      return findLatestActiveRelease(namespace.getAppId(), namespace.getClusterName(), namespace.getNamespaceName());
  }
  
  public Release findLatestActiveRelease(String appId, String clusterName, String namespaceName) {
      return releaseRepository.findFirstByAppIdAndClusterNameAndNamespaceNameAndIsAbandonedFalseOrderByIdDesc(appId,
              clusterName, namespaceName); // IsAbandoned = False && Id DESC
  }
  ```

- 第 36 至 39 行：创建操作 **Context** 。

- 第 41 行：调用 `#masterRelease(namespace, releaseName, releaseComment, operateNamespaceItems, operator, releaseOperation, operationContext)` 方法，**主干**发布配置。🙂 创建的 Namespace ，默认就是**主干**，而**灰度**发布使用的是**分支**。

- 第 42 至 48 行：调用 `#mergeFromMasterAndPublishBranch(...)` 方法，若有子 Namespace 时，自动将主干合并到子 Namespace ，并进行一次子 Namespace 的发布。

- 第 49 行：返回 **Release** 对象。详细解析，见 [《Apollo 源码解析 —— Portal 灰度发布》](http://www.iocoder.cn/Apollo/portal-publish-namespace-branch?self) 。

### 4.2.2 masterRelease

`#masterRelease(namespace, releaseName, releaseComment, operateNamespaceItems, operator, releaseOperation, operationContext)` 方法，主干发布配置。代码如下：

```java
private Release masterRelease(Namespace namespace, String releaseName, String releaseComment,
                              Map<String, String> configurations, String operator,
                              int releaseOperation, Map<String, Object> operationContext) {
  Release lastActiveRelease = findLatestActiveRelease(namespace); // 获得最后有效的 Release 对象
  long previousReleaseId = lastActiveRelease == null ? 0 : lastActiveRelease.getId();
  Release release = createRelease(namespace, releaseName, releaseComment,
                                  configurations, operator);  // 创建 Release 对象，并保存
  // 创建 ReleaseHistory 对象，并保存
  releaseHistoryService.createReleaseHistory(namespace.getAppId(), namespace.getClusterName(),
                                             namespace.getNamespaceName(), namespace.getClusterName(),
                                             release.getId(), previousReleaseId, releaseOperation,
                                             operationContext, operator);

  return release;
}
```

- 第 5 行：调用 `#findLatestActiveRelease(namespace)` 方法，获得**最后**、**有效**的 Release 对象。代码如下：

  ```java
  public Release findLatestActiveRelease(Namespace namespace) {
      return findLatestActiveRelease(namespace.getAppId(), namespace.getClusterName(), namespace.getNamespaceName());
  }
  
  public Release findLatestActiveRelease(String appId, String clusterName, String namespaceName) {
      return releaseRepository.findFirstByAppIdAndClusterNameAndNamespaceNameAndIsAbandonedFalseOrderByIdDesc(appId,
              clusterName, namespaceName); // IsAbandoned = False && Id DESC
  }
  ```

- 第 8 行：调用 `#createRelease(namespace, releaseName, releaseComment, configurations, operator)` 方法，创建 **Release** 对象，并保存。

- 第10 至 14 行：调用 `ReleaseHistoryService#createReleaseHistory(appId, clusterName, namespaceName, branchName, releaseId, previousReleaseId, operation, operationContext, operator)` 方法，创建 **ReleaseHistory** 对象，并保存。

### 4.2.3 createRelease

`#createRelease(namespace, releaseName, releaseComment, configurations, operator)` 方法，创建 **Release** 对象，并保存。代码如下：

```java
private Release createRelease(Namespace namespace, String name, String comment,
                              Map<String, String> configurations, String operator) {
  Release release = new Release(); // 创建 Release 对象
  release.setReleaseKey(ReleaseKeyGenerator.generateReleaseKey(namespace));
  release.setDataChangeCreatedTime(new Date());
  release.setDataChangeCreatedBy(operator);
  release.setDataChangeLastModifiedBy(operator);
  release.setName(name);
  release.setComment(comment);
  release.setAppId(namespace.getAppId());
  release.setClusterName(namespace.getClusterName());
  release.setNamespaceName(namespace.getNamespaceName());
  release.setConfigurations(GSON.toJson(configurations)); // 使用 Gson ，将配置 Map 格式化成字符串。
  release = releaseRepository.save(release); // 保存 Release 对象

  namespaceLockService.unlock(namespace.getId()); // 释放 NamespaceLock
  auditService.audit(Release.class.getSimpleName(), release.getId(), Audit.OP.INSERT,
                     release.getDataChangeCreatedBy()); // 记录 Audit 到数据库中

  return release;
}
```

- 第 4 至 14 行：创建 Release 对象，并设置对应的属性。
  - 第 5 行：Release Key 用途？
  - 第 14 行：调用 `Gson#toJson(src)` 方法，将**配置 Map** 格式化成字符串。
- 第 16 行：调用 `ReleaseRepository#save(Release)` 方法，保存 Release 对象。
- 第 18 行：调用 `NamespaceLockService#unlock(namespaceId)` 方法，释放 NamespaceLock 。
- 第 20 行：记录 Audit 到数据库中。

## 4.3 ReleaseRepository

`com.ctrip.framework.apollo.biz.repository.ReleaseRepository` ，继承 `org.springframework.data.repository.PagingAndSortingRepository` 接口，提供 Release 的**数据访问** 给 Admin Service 和 Config Service 。代码如下：

```java
public interface ReleaseRepository extends PagingAndSortingRepository<Release, Long> {

  Release findFirstByAppIdAndClusterNameAndNamespaceNameAndIsAbandonedFalseOrderByIdDesc(@Param("appId") String appId, @Param("clusterName") String clusterName,
                                                                                         @Param("namespaceName") String namespaceName);

  Release findByIdAndIsAbandonedFalse(long id);

  List<Release> findByAppIdAndClusterNameAndNamespaceNameOrderByIdDesc(String appId, String clusterName, String namespaceName, Pageable page);

  List<Release> findByAppIdAndClusterNameAndNamespaceNameAndIsAbandonedFalseOrderByIdDesc(String appId, String clusterName, String namespaceName, Pageable page);

  List<Release> findByAppIdAndClusterNameAndNamespaceNameAndIsAbandonedFalseAndIdBetweenOrderByIdDesc(String appId, String clusterName, String namespaceName, long fromId, long toId);

  List<Release> findByReleaseKeyIn(Set<String> releaseKey);

  List<Release> findByIdIn(Set<Long> releaseIds);

  @Modifying
  @Query("update Release set IsDeleted = 1, DeletedAt = ROUND(UNIX_TIMESTAMP(NOW(4))*1000), DataChange_LastModifiedBy = ?4 where appId=?1 and clusterName=?2 and namespaceName = ?3")
  int batchDelete(String appId, String clusterName, String namespaceName, String operator);

  // For release history conversion program, need to delete after conversion it done
  List<Release> findByAppIdAndClusterNameAndNamespaceNameOrderByIdAsc(String appId, String clusterName, String namespaceName);
}
```

## 4.4 ReleaseHistoryService

在 `apollo-biz` 项目中，`com.ctrip.framework.apollo.biz.service.ReleaseHistoryService` ，提供 ReleaseHistory 的 **Service** 逻辑给 Admin Service 和 Config Service 。

`#createReleaseHistory(appId, clusterName, namespaceName, branchName, releaseId, previousReleaseId, operation, operationContext, operator)` 方法，创建 **ReleaseHistory** 对象，并保存。代码如下：

```java
@Transactional
public ReleaseHistory createReleaseHistory(String appId, String clusterName, String
    namespaceName, String branchName, long releaseId, long previousReleaseId, int operation,
                                           Map<String, Object> operationContext, String operator) {
  ReleaseHistory releaseHistory = new ReleaseHistory(); // 创建 ReleaseHistory 对象
  releaseHistory.setAppId(appId);
  releaseHistory.setClusterName(clusterName);
  releaseHistory.setNamespaceName(namespaceName);
  releaseHistory.setBranchName(branchName);
  releaseHistory.setReleaseId(releaseId); // Release 编号
  releaseHistory.setPreviousReleaseId(previousReleaseId);  // 上一个 Release 编
  releaseHistory.setOperation(operation);
  if (operationContext == null) {
    releaseHistory.setOperationContext("{}"); //default empty object
  } else {
    releaseHistory.setOperationContext(GSON.toJson(operationContext));
  }
  releaseHistory.setDataChangeCreatedTime(new Date());
  releaseHistory.setDataChangeCreatedBy(operator);
  releaseHistory.setDataChangeLastModifiedBy(operator);
  // 保存 ReleaseHistory 对象
  releaseHistoryRepository.save(releaseHistory);
  // 记录 Audit 到数据库中
  auditService.audit(ReleaseHistory.class.getSimpleName(), releaseHistory.getId(),
                     Audit.OP.INSERT, releaseHistory.getDataChangeCreatedBy());

  return releaseHistory;
}
```

- 第 12 至 28 行：创建 ReleaseHistory 对象，并设置对应的属性。
- 第 30 行：调用 `ReleaseHistoryRepository#save(ReleaseHistory)` 方法，保存 ReleaseHistory 对象。
- 第 32 行：记录 Audit 到数据库中。

## 4.5 ReleaseHistoryRepository

`com.ctrip.framework.apollo.biz.repository.ReleaseHistoryRepository` ，继承 `org.springframework.data.repository.PagingAndSortingRepository` 接口，提供 ReleaseHistory 的**数据访问** 给 Admin Service 和 Config Service 。代码如下：

```java
public interface ReleaseHistoryRepository extends PagingAndSortingRepository<ReleaseHistory, Long> {
  Page<ReleaseHistory> findByAppIdAndClusterNameAndNamespaceNameOrderByIdDesc(String appId, String
      clusterName, String namespaceName, Pageable pageable);

  Page<ReleaseHistory> findByReleaseIdAndOperationOrderByIdDesc(long releaseId, int operation, Pageable pageable);

  Page<ReleaseHistory> findByPreviousReleaseIdAndOperationOrderByIdDesc(long previousReleaseId, int operation, Pageable pageable);

  Page<ReleaseHistory> findByReleaseIdAndOperationInOrderByIdDesc(long releaseId, Set<Integer> operations, Pageable pageable);

  @Modifying
  @Query("update ReleaseHistory set IsDeleted = 1, DeletedAt = ROUND(UNIX_TIMESTAMP(NOW(4))*1000), DataChange_LastModifiedBy = ?4 where appId=?1 and clusterName=?2 and namespaceName = ?3")
  int batchDelete(String appId, String clusterName, String namespaceName, String operator);

}
```



# 参考

[Apollo 源码解析 —— Portal 发布配置](https://www.iocoder.cn/Apollo/portal-publish/)
