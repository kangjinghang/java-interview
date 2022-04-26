# 1. 概述

> 老艿艿：本系列假定胖友已经阅读过 [《Apollo 官方 wiki 文档》](https://github.com/ctripcorp/apollo/wiki/) ，特别是 [《Apollo 官方 wiki 文档 —— 核心概念之“Namespace”》](https://github.com/ctripcorp/apollo/wiki/Apollo核心概念之“Namespace”) 。

本文分享 **Portal 关联 Namespace** 的流程，整个过程涉及 Portal、Admin Service ，如下图所示：

<img src="http://blog-1259650185.cosbj.myqcloud.com/img/202204/03/1648947667.png" alt="流程" style="zoom:50%;" />

> 老艿艿：因为 Portal 是管理后台，所以从代码实现上，和业务系统非常相像。也因此，本文会略显啰嗦。

# 2. Portal 侧

## 2.1 NamespaceController

在 `apollo-portal` 项目中，`com.ctrip.framework.apollo.portal.controller.NamespaceController` ，提供 AppNamespace 和 Namespace 的 **API** 。

在**关联 Namespace**的界面中，点击【提交】按钮，调用**创建 Namespace 的 API** 。

<img src="http://blog-1259650185.cosbj.myqcloud.com/img/202204/03/1648947717.png" alt="关联 Namespace" style="zoom: 50%;" />

- 公用类型的 Namespace 的**名字**是**全局**唯一，所以关联时，只需要查看名字即可。

`#createNamespace(appId, List<NamespaceCreationModel>)` 方法，创建 Namespace 对象，支持**多个** Namespace 。代码如下：

```java
@PreAuthorize(value = "@permissionValidator.hasCreateNamespacePermission(#appId)")
@PostMapping("/apps/{appId}/namespaces")
public ResponseEntity<Void> createNamespace(@PathVariable String appId,
                                            @RequestBody List<NamespaceCreationModel> models) {

  checkModel(!CollectionUtils.isEmpty(models)); // 校验 models 非空
  // 初始化 Namespace 的 Role 们
  String namespaceName = models.get(0).getNamespace().getNamespaceName();
  String operator = userInfoHolder.getUser().getUserId();

  roleInitializationService.initNamespaceRoles(appId, namespaceName, operator);
  roleInitializationService.initNamespaceEnvRoles(appId, namespaceName, operator);
  // 循环 models ，创建 Namespace 对象
  for (NamespaceCreationModel model : models) {
    NamespaceDTO namespace = model.getNamespace();
    RequestPrecondition.checkArgumentsNotEmpty(model.getEnv(), namespace.getAppId(), // 校验相关参数非空
                                               namespace.getClusterName(), namespace.getNamespaceName());

    try {
      namespaceService.createNamespace(Env.valueOf(model.getEnv()), namespace); // 创建 Namespace 对象
    } catch (Exception e) {
      logger.error("create namespace fail.", e);
      Tracer.logError(
              String.format("create namespace fail. (env=%s namespace=%s)", model.getEnv(),
                      namespace.getNamespaceName()), e);
    }
  }
  // 授予 Namespace Role 给当前管理员
  namespaceService.assignNamespaceRoleToOperator(appId, namespaceName,userInfoHolder.getUser().getUserId());

  return ResponseEntity.ok().build();
}
```

- **POST `/apps/{appId}/namespaces` 接口**，Request Body 传递 **JSON** 对象。

- `@PreAuthorize(...)` 注解，调用 `PermissionValidator#hasCreateNamespacePermission(appId)` 方法，校验是否有创建 Namespace 的权限。后续文章，详细分享。

- `com.ctrip.framework.apollo.portal.entity.model.NamespaceCreationModel` ，Namespace 创建 Model 。代码如下：

  ```java
  public class NamespaceCreationModel {
  
      /**
       * 环境
       */
      private String env;
      /**
       * Namespace 信息
       */
      private NamespaceDTO namespace;
  }
  ```

- `com.ctrip.framework.apollo.common.dto.NamespaceDTO` ，Namespace DTO 。代码如下：

  ```java
  public class NamespaceDTO extends BaseDTO {
  
      private long id;
      /**
       * App 编号
       */
      private String appId;
      /**
       * Cluster 名字
       */
      private String clusterName;
      /**
       * Namespace 名字
       */
      private String namespaceName;
  }
  ```

- 第 13 行：校验 `models` 非空。

- 第 14 至 17 行：初始化 Namespace 的 Role 们。详解解析，见 [《Apollo 源码解析 —— Portal 认证与授权（二）之授权》](http://www.iocoder.cn/Apollo/portal-auth-2?self) 。

- 第 18 至 30 行：循环`models`，创建 Namespace 对象们。

  - 第 22 行：调用 `RequestPrecondition#checkArgumentsNotEmpty(String... args)` 方法，校验 NamespaceDTO 的 `env` `appId` `clusterName` `namespaceName` 非空。
  - 第 25 行：调用 `NamespaceService#createNamespace(Env, NamespaceDTO)` 方法，创建并保存 Namespace 到 Admin Service 中。
  - 第 26 至 29 行：当发生异常时，即创建**失败**，仅打印异常日志。也就是说，在 【第 33 行】，依然提示创建 Namespace 成功。

- 第 32 行：授予 Namespace Role 给当前管理员。详解解析，见 [《Apollo 源码解析 —— Portal 认证与授权（二）之授权》](http://www.iocoder.cn/Apollo/portal-auth-2?self) 。

## 2.2 NamespaceService

在 `apollo-portal` 项目中，`com.ctrip.framework.apollo.portal.service.NamespaceService` ，提供 Namespace 的 **Service** 逻辑。

`#createNamespace(Env env, NamespaceDTO namespace)` 方法，保存 Namespace 对象到 Admin Service 中。代码如下：

```java
public NamespaceDTO createNamespace(Env env, NamespaceDTO namespace) {
  if (StringUtils.isEmpty(namespace.getDataChangeCreatedBy())) { // 设置 NamespaceDTO 的创建和修改人为当前管理员
    namespace.setDataChangeCreatedBy(userInfoHolder.getUser().getUserId());
  }

  if (StringUtils.isEmpty(namespace.getDataChangeLastModifiedBy())) {
    namespace.setDataChangeLastModifiedBy(userInfoHolder.getUser().getUserId());
  }
  NamespaceDTO createdNamespace = namespaceAPI.createNamespace(env, namespace); // 创建 Namespace 到 Admin Service
  // Tracer 日志
  Tracer.logEvent(TracerEventType.CREATE_NAMESPACE,
      String.format("%s+%s+%s+%s", namespace.getAppId(), env, namespace.getClusterName(),
          namespace.getNamespaceName()));
  return createdNamespace;
}
```

- 第 7 至 11 行：**设置** NamespaceDTO 的创建和修改人。
- 第 13 行：调用 `NamespaceAPI#createNamespace(Env, NamespaceDTO)` 方法，创建 Namespace 到 Admin Service 。
- 第 15 行：Tracer 日志。

## 2.3 NamespaceAPI

`com.ctrip.framework.apollo.portal.api.NamespaceAPI` ，实现 API 抽象类，封装对 Admin Service 的 AppNamespace 和 Namespace **两个**模块的 API 调用。代码如下：

![NamespaceAPI](http://blog-1259650185.cosbj.myqcloud.com/img/202204/03/1648949492.png)

- 使用 `restTemplate` ，调用对应的 API 接口。

# 3. Admin Service 侧

## 3.1 NamespaceController

在 `apollo-adminservice` 项目中， `com.ctrip.framework.apollo.adminservice.controller.NamespaceController` ，提供 Namespace 的 **API** 。

`#create(appId, clusterName, NamespaceDTO)` 方法，创建 Namespace 。代码如下：

```java
@RestController
public class NamespaceController {

  private final NamespaceService namespaceService;

  // 创建 Namespace
  @PostMapping("/apps/{appId}/clusters/{clusterName}/namespaces")
  public NamespaceDTO create(@PathVariable("appId") String appId,
                             @PathVariable("clusterName") String clusterName,
                             @Valid @RequestBody NamespaceDTO dto) { // 校验 NamespaceDTO 的 namespaceName 格式正确。
    Namespace entity = BeanUtils.transform(Namespace.class, dto); // 将 NamespaceDTO 转换成 Namespace 对象
    Namespace managedEntity = namespaceService.findOne(appId, clusterName, entity.getNamespaceName());
    if (managedEntity != null) { // 判断 name 在 Cluster 下是否已经存在对应的 Namespace 对象。若已经存在，抛出 BadRequestException 异常
      throw new BadRequestException("namespace already exist.");
    }
    // 保存 Namespace 对象
    entity = namespaceService.save(entity);
    // 将保存的 Namespace 对象转换成 NamespaceDTO
    return BeanUtils.transform(NamespaceDTO.class, entity);
  }
  // ... 省略其他接口和属性
}
```

- **POST `/apps/{appId}/clusters/{clusterName}/namespaces` 接口**，Request Body 传递 **JSON** 对象。
- `@Valid`调用，**校验** NamespaceDTO 的 `namespaceName` 格式正确，符合 `[0-9a-zA-Z_.-]+"` 格式。
- 第 23 行：调用 `BeanUtils#transfrom(Class<T> clazz, Object src)` 方法，将 NamespaceDTO **转换**成 Namespace 对象。
- 第 20 至 23 行：调用 `NamespaceService#findOne(appId, clusterName, namespaceName)` 方法，**校验** `name` 在 Cluster 下是否已经存在对应的 Namespace 对象。若已经存在，抛出 BadRequestException 异常。
- 第 30 行：调用 `NamespaceService#save(Namespace)` 方法，保存 Namespace 对象到数据库。
- 第 30 至 32 行：调用 `BeanUtils#transfrom(Class<T> clazz, Object src)` 方法，将保存的 Namespace 对象，转换成 NamespaceDTO 返回。

## 3.2 NamespaceService

在 [《Apollo 源码解析 —— Portal 创建 Namespace》](http://www.iocoder.cn/Apollo/portal-create-namespace/?self) 的 [「4.4 NamespaceService」](https://www.iocoder.cn/Apollo/portal-associate-namespace/#) ，已经详细解析。

## 3.3 NamespaceRepository

在 [《Apollo 源码解析 —— Portal 创建 Namespace》](http://www.iocoder.cn/Apollo/portal-create-namespace/?self) 的 [「4.5 NamespaceRepository」](https://www.iocoder.cn/Apollo/portal-associate-namespace/#) ，已经详细解析。



# 参考

[Apollo 源码解析 —— Portal 关联 Namespace](https://www.iocoder.cn/Apollo/portal-associate-namespace/)
