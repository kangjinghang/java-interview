# 1. 概述

> 老艿艿：本系列假定胖友已经阅读过 [《Apollo 官方 wiki 文档》](https://github.com/ctripcorp/apollo/wiki/) 。

本文分享 **Portal 创建 Cluster** 的流程，整个过程涉及 Portal、Admin Service ，如下图所示：

<img src="http://blog-1259650185.cosbj.myqcloud.com/img/202204/02/1648913557.png" alt="流程" style="zoom: 50%;" />

下面，我们先来看看 Cluster 的实体结构

> 老艿艿：因为 Portal 是管理后台，所以从代码实现上，和业务系统非常相像。也因此，本文会略显啰嗦。

# 2. Cluster

`com.ctrip.framework.apollo.biz.entity.Cluster` ，继承 BaseEntity 抽象类，Cluster **实体**。代码如下：

```java
@Entity
@Table(name = "Cluster")
@SQLDelete(sql = "Update Cluster set isDeleted = 1 where id = ?")
@Where(clause = "isDeleted = 0")
public class Cluster extends BaseEntity implements Comparable<Cluster> {

    /**
     * 名字
     */
    @Column(name = "Name", nullable = false)
    private String name;
    /**
     * App 编号 {@link }
     */
    @Column(name = "AppId", nullable = false)
    private String appId;
    /**
     * 父 App 编号
     */
    @Column(name = "ParentClusterId", nullable = false)
    private long parentClusterId;
}
```

- `appId` 字段，App 编号，指向对应的 App 。App : Cluster = 1 : N 。
- `parentClusterId` 字段，父 App 编号。用于灰度发布，在 [《Apollo 源码解析 —— Portal 创建灰度》](http://www.iocoder.cn/Apollo/portal-create-namespace-branch/?self) 有详细解析。

# 3. Portal 侧

## 3.1 ClusterController

在 `apollo-portal` 项目中，`com.ctrip.framework.apollo.portal.controller.ClusterController` ，提供 Cluster 的 **API** 。

在**创建 Cluster**的界面中，点击【提交】按钮，调用**创建 Cluster 的 API** 。

<img src="http://blog-1259650185.cosbj.myqcloud.com/img/202204/02/1648913837.png" alt="创建 Cluster" style="zoom: 67%;" />

```java
@PreAuthorize(value = "@permissionValidator.hasCreateClusterPermission(#appId)")
@PostMapping(value = "apps/{appId}/envs/{env}/clusters")
public ClusterDTO createCluster(@PathVariable String appId, @PathVariable String env,
                                @Valid @RequestBody ClusterDTO cluster) { // 校验 ClusterDTO 非空
  String operator = userInfoHolder.getUser().getUserId();
  cluster.setDataChangeLastModifiedBy(operator); // 设置 ClusterDTO 的创建和修改人为当前管理员
  cluster.setDataChangeCreatedBy(operator);
  // 创建 Cluster 到 Admin Service
  return clusterService.createCluster(Env.valueOf(env), cluster);
}
```

- **POST `apps/{appId}/envs/{env}/cluster` 接口**，Request Body 传递 **JSON** 对象。
- `@PreAuthorize(...)` 注解，调用 `PermissionValidator#hasCreateClusterPermission(appId,)` 方法，校验是否有创建 Cluster 的权限。后续文章，详细分享。
- `@Valid`校验 ClusterDTO 非空。**注意**，此处使用的接收请求参数是 Cluster**DTO** ，校验 ClusterDTO 的 `appId` 和 `name` 非空，校验 ClusterDTO 的 `name` 格式正确，符合 `[0-9a-zA-Z_.-]+"` 格式。
- 第 21 至 24 行：设置 ClusterDTO 的创建和修改人为当前管理员。
- 第 26 行：调用 `ClusterService#createCluster(Env, ClusterDTO)` 方法，创建并保存 Cluster 到 Admin Service 。在 [「3.2 ClusterService」](https://www.iocoder.cn/Apollo/portal-create-cluster/#) 中，详细解析。

## 3.2 ClusterService

在 `apollo-portal` 项目中，`com.ctrip.framework.apollo.portal.service.ClusterService` ，提供 Cluster 的 **Service** 逻辑。

`#createCluster(Env, ClusterDTO)` 方法，创建并保存 Cluster 到 Admin Service 。代码如下：

```java
@Service
public class ClusterService {

  private final UserInfoHolder userInfoHolder;
  private final AdminServiceAPI.ClusterAPI clusterAPI;

  public ClusterDTO createCluster(Env env, ClusterDTO cluster) {
    if (!clusterAPI.isClusterUnique(cluster.getAppId(), env, cluster.getName())) { // 根据 appId 和 name 校验 Cluster 的唯一性
      throw new BadRequestException(String.format("cluster %s already exists.", cluster.getName()));
    }
    ClusterDTO clusterDTO = clusterAPI.create(env, cluster); // 创建 Cluster 到 Admin Service
    // Tracer 日志
    Tracer.logEvent(TracerEventType.CREATE_CLUSTER, cluster.getAppId(), "0", cluster.getName());

    return clusterDTO;
  }
  
  // ... 省略其他接口和属性
}  
```

- 第 5 至 8 行：调用 `ClusterAPI#isClusterUnique(appId, Env, clusterName)` 方法，根据 `appId` 和 `name` **校验** Cluster 的唯一性。**注意**，此处是远程调用 Admin Service 的 API 。
- 第 10 行：调用 `ClusterAPI#create(Env, ClusterDTO)` 方法，创建 Cluster 到 Admin Service 。
- 第 12 行：Tracer 日志。

## 3.3 ClusterAPI

`com.ctrip.framework.apollo.portal.api.ClusterAPI` ，实现 API 抽象类，封装对 Admin Service 的 Cluster 模块的 API 调用。代码如下：

![ClusterAPI](http://blog-1259650185.cosbj.myqcloud.com/img/202204/02/1648914850.png)

# 4. Admin Service 侧

## 4.1 ClusterController

在 `apollo-adminservice` 项目中， `com.ctrip.framework.apollo.adminservice.controller.ClusterController` ，提供 Cluster 的 **API** 。

`#create(appId, autoCreatePrivateNamespace, ClusterDTO)` 方法，创建 Cluster 。代码如下：

```java
@RestController
public class ClusterController {

  private final ClusterService clusterService;

  public ClusterController(final ClusterService clusterService) {
    this.clusterService = clusterService;
  }

  @PostMapping("/apps/{appId}/clusters")
  public ClusterDTO create(@PathVariable("appId") String appId,
                           @RequestParam(value = "autoCreatePrivateNamespace", defaultValue = "true") boolean autoCreatePrivateNamespace,
                           @Valid @RequestBody ClusterDTO dto) { // 校验 ClusterDTO 的 name 格式正确。
    Cluster entity = BeanUtils.transform(Cluster.class, dto); // 将 ClusterDTO 转换成 Cluster 对象
    Cluster managedEntity = clusterService.findOne(appId, entity.getName());
    if (managedEntity != null) { // 判断 name 在 App 下是否已经存在对应的 Cluster 对象。若已经存在，抛出 BadRequestException 异常。
      throw new BadRequestException("cluster already exist.");
    }

    if (autoCreatePrivateNamespace) { // 保存 Cluster 对象，并创建其 Namespace
      entity = clusterService.saveWithInstanceOfAppNamespaces(entity);
    } else { // 保存 Cluster 对象，不创建其 Namespace
      entity = clusterService.saveWithoutInstanceOfAppNamespaces(entity);
    }

    return BeanUtils.transform(ClusterDTO.class, entity);  // 将保存的 Cluster 对象转换成 ClusterDTO
  }
  
  // ... 省略其他接口和属性
}
```

- **POST `/apps/{appId}/clusters` 接口**，Request Body 传递 **JSON** 对象。
- `@Valid`调用，**校验** ClusterDTO 的 `name` 格式正确，符合 `[0-9a-zA-Z_.-]+"` 格式。
- 第 15 行：调用 `BeanUtils#transfrom(Class<T> clazz, Object src)` 方法，将 ClusterDTO **转换**成 Cluster 对象。
- 第 16 至 20 行：调用 `ClusterService#findOne(appId, name)` 方法，**校验** `name` 在 App 下，是否已经存在对应的 Cluster 对象。若已经存在，抛出 BadRequestException 异常。
- 第 21 至 23 行：若 `autoCreatePrivateNamespace = true` 时，调用 `ClusterService#saveWithInstanceOfAppNamespaces(Cluster)` 方法，保存 Cluster 对象，**并**创建其 Namespace 。
- 第 24 至 27 行：若 `autoCreatePrivateNamespace = false` 时，调用 `ClusterService#saveWithoutInstanceOfAppNamespaces(Cluster)` 方法，保存 Cluster 对象，**不**创建其 Namespace 。
- 第 29 行：调用 `BeanUtils#transfrom(Class<T> clazz, Object src)` 方法，将 Cluster **转换**成 ClusterDTO 对象。

## 4.2 ClusterService

在 `apollo-biz` 项目中，`com.ctrip.framework.apollo.biz.service.ClusterService` ，提供 Cluster 的 **Service** 逻辑给 Admin Service 和 Config Service 。

`#saveWithInstanceOfAppNamespaces(Cluster)` 方法，保存 Cluster 对象，并创建其 Namespace 。代码如下：

```java
@Service
public class ClusterService {

  private final ClusterRepository clusterRepository;
  private final AuditService auditService;
  private final NamespaceService namespaceService;

  @Transactional
  public Cluster saveWithInstanceOfAppNamespaces(Cluster entity) {
    // 保存 Cluster 对象
    Cluster savedCluster = saveWithoutInstanceOfAppNamespaces(entity);
    // 创建 Cluster 的 Namespace 们
    namespaceService.instanceOfAppNamespaces(savedCluster.getAppId(), savedCluster.getName(),
                                             savedCluster.getDataChangeCreatedBy());

    return savedCluster;
  }
  
  // ... 省略其他接口和属性
}
```

- 第 11 行：调用 `#saveWithoutInstanceOfAppNamespaces(Cluster)` 方法，保存 Cluster 对象。
- 第 13 行：调用 `NamespaceService#instanceOfAppNamespaces(appId, clusterName, createBy)` 方法，创建 Cluster 的 Namespace 们。在 [《Apollo 源码解析 —— Portal 创建 Namespace》](http://www.iocoder.cn/Apollo/portal-create-namespace/?self) 中，有详细解析。

`#saveWithoutInstanceOfAppNamespaces(Cluster)` 方法，保存 Cluster 对象。代码如下：

```java
@Transactional
public Cluster saveWithoutInstanceOfAppNamespaces(Cluster entity) {
  if (!isClusterNameUnique(entity.getAppId(), entity.getName())) { // 判断 name 在 App 下是否已经存在对应的 Cluster 对象。若已经存在，抛出 BadRequestException 异常。
    throw new BadRequestException("cluster not unique");
  }
  entity.setId(0);//protection
  Cluster cluster = clusterRepository.save(entity); // 保存 Cluster 对象到数据库
  // Tracer 日志
  auditService.audit(Cluster.class.getSimpleName(), cluster.getId(), Audit.OP.INSERT,
                     cluster.getDataChangeCreatedBy());

  return cluster;
}
```

## 4.3 ClusterRepository

`com.ctrip.framework.apollo.biz.repository.ClusterRepository` ，继承 `org.springframework.data.repository.PagingAndSortingRepository` 接口，提供 Cluster 的**数据访问** 给 Admin Service 和 Config Service 。代码如下：

```java
public interface ClusterRepository extends PagingAndSortingRepository<Cluster, Long> {

  List<Cluster> findByAppIdAndParentClusterId(String appId, Long parentClusterId);

  List<Cluster> findByAppId(String appId);

  Cluster findByAppIdAndName(String appId, String name);

  List<Cluster> findByParentClusterId(Long parentClusterId);
}
```



# 参考

[Apollo 源码解析 —— Portal 创建 Cluster](https://www.iocoder.cn/Apollo/portal-create-cluster/)
