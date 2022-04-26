# 1. 概述

> 老艿艿：本系列假定胖友已经阅读过 [《Apollo 官方 wiki 文档》](https://github.com/ctripcorp/apollo/wiki/) ，特别是 [《Apollo 官方 wiki 文档 —— 核心概念之“Namespace”》](https://github.com/ctripcorp/apollo/wiki/Apollo核心概念之“Namespace”) 。

本文分享 **Portal 创建 Namespace** 的流程，整个过程涉及 Portal、Admin Service ，如下图所示：

<img src="http://blog-1259650185.cosbj.myqcloud.com/img/202204/03/1648915604.png" alt="流程" style="zoom:50%;" />

下面，我们先来看看 AppNamespace 和 Namespace 的实体结构

> 老艿艿：因为 Portal 是管理后台，所以从代码实现上，和业务系统非常相像。也因此，本文会略显啰嗦。

# 2. 实体

## 2.1 AppNamespace

在 `apollo-common` 项目中，`com.ctrip.framework.apollo.common.entity.AppNamespace` ，继承 BaseEntity 抽象类，App Namespace **实体**。代码如下：

```java
@Entity
@Table(name = "AppNamespace")
@SQLDelete(sql = "Update AppNamespace set IsDeleted = 1, DeletedAt = ROUND(UNIX_TIMESTAMP(NOW(4))*1000) where Id = ?")
@Where(clause = "isDeleted = 0")
public class AppNamespace extends BaseEntity {

  @NotBlank(message = "AppNamespace Name cannot be blank")
  @Pattern(
      regexp = InputValidator.CLUSTER_NAMESPACE_VALIDATOR,
      message = "Invalid Namespace format: " + InputValidator.INVALID_CLUSTER_NAMESPACE_MESSAGE + " & " + InputValidator.INVALID_NAMESPACE_NAMESPACE_MESSAGE
  )
  @Column(name = "Name", nullable = false)
  private String name; // AppNamespace 名

  @NotBlank(message = "AppId cannot be blank")
  @Column(name = "AppId", nullable = false)
  private String appId; // App 编号

  @Column(name = "Format", nullable = false)
  private String format; // 格式，参见 {@link ConfigFileFormat}

  @Column(name = "IsPublic", columnDefinition = "Bit default '0'")
  private boolean isPublic = false; // 是否公用的

  @Column(name = "Comment")
  private String comment; // 备注

}
```

- `appId` 字段，App 编号，指向对应的 App 。App : AppNamespace = 1 : N 。

- `format` 字段，格式。在 `com.ctrip.framework.apollo.core.enums.ConfigFileFormat` **枚举类**中，定义了五种类型。代码如下：

  ```java
  public enum ConfigFileFormat {
  
      Properties("properties"), XML("xml"), JSON("json"), YML("yml"), YAML("yaml");
  
      private String value;
  
      // ... 省略了无关的代码
  }
  ```

- `isPublic` 字段，是否公用的。

  > Namespace的获取权限分为两种：
  >
  > - **private** （私有的）：private 权限的 Namespace ，只能被所属的应用获取到。一个应用尝试获取其它应用 private 的 Namespace ，Apollo 会报 “404” 异常。
  > - **public** （公共的）：public 权限的 Namespace ，能被任何应用获取。
  >
  > *这里的获取权限是相对于 Apollo 客户端来说的。*

## 2.2 Namespace

## 2.2 Namespace

在 `apollo-biz` 项目中， `com.ctrip.framework.apollo.biz.entity.Namespace` ，继承 BaseEntity 抽象类，Cluster Namespace **实体**，是配置项的**集合**，类似于一个配置文件的概念。代码如下：

```java
@Entity
@Table(name = "Namespace")
@SQLDelete(sql = "Update Namespace set IsDeleted = 1, DeletedAt = ROUND(UNIX_TIMESTAMP(NOW(4))*1000) where Id = ?")
@Where(clause = "isDeleted = 0")
public class Namespace extends BaseEntity {

  @Column(name = "appId", nullable = false)
  private String appId; // App 编号 {@link com.ctrip.framework.apollo.common.entity.App#appId}

  @Column(name = "ClusterName", nullable = false)
  private String clusterName; // Cluster 名 {@link Cluster#name}

  @Column(name = "NamespaceName", nullable = false)
  private String namespaceName; // AppNamespace 名 {@link com.ctrip.framework.apollo.common.entity.AppNamespace#name}

}
```

## 2.3 AppNamespace vs. Namespace

**关系图**如下：

<img src="http://blog-1259650185.cosbj.myqcloud.com/img/202204/03/1648916666.png" alt="ER 图" style="zoom:50%;" />

**数据流**向如下：

1. 在 App 下创建 **App**Namespace 后，自动给 App 下每个 Cluster 创建 Namespace 。
2. 在 App 下创建 Cluster 后，根据 App 下 每个 **App**Namespace 创建 Namespace 。
3. 可删除 Cluster 下的 Namespace 。

**总结**来说：

1. **App**Namespace 是 App 下的每个 Cluster **默认**创建的 Namespace 。
2. Namespace 是 每个 Cluster **实际**拥有的 Namespace 。

## 2.4 类型

> Namespace 类型有三种：
>
> - 私有类型：私有类型的 Namespace 具有 **private** 权限。
> - 公共类型：公共类型的 Namespace 具有 **public** 权限。公共类型的 Namespace 相当于游离于应用之外的配置，且通过 Namespace 的名称去标识公共 Namespace ，所以公共的 Namespace 的名称必须**全局唯一**。
> - 关联类型：关联类型又可称为继承类型，关联类型具有 **private** 权限。关联类型的Namespace 继承于公共类型的Namespace，用于覆盖公共 Namespace 的某些配置。

在 Namespace 实体中，**找不到** 类型的字段呀？！通过如下逻辑判断：

```java
Namespace => AppNamespace
if (AppNamespace.isPublic) {
    return "公共类型";
}
if (Namespace.appId == AppNamespace.appId) {
    return "私有类型";
}
return "关联类型";
```

# 3. Portal 侧

## 3.1 NamespaceController

在 `apollo-portal` 项目中，`com.ctrip.framework.apollo.portal.controller.NamespaceController` ，提供 AppNamespace 和 Namespace 的 **API** 。

在**创建 Namespace**的界面中，点击【提交】按钮，调用**创建 AppNamespace 的 API** 。

<img src="http://blog-1259650185.cosbj.myqcloud.com/img/202204/03/1648917006.png" alt="创建 Namespace" style="zoom:50%;" />

代码如下：

```java
@RestController
public class NamespaceController {

  private static final Logger logger = LoggerFactory.getLogger(NamespaceController.class);

  private final ApplicationEventPublisher publisher;
  private final UserInfoHolder userInfoHolder;
  private final NamespaceService namespaceService;
  private final AppNamespaceService appNamespaceService;
  private final RoleInitializationService roleInitializationService;
  private final PortalConfig portalConfig;
  private final PermissionValidator permissionValidator;
  private final AdminServiceAPI.NamespaceAPI namespaceAPI;

  @PreAuthorize(value = "@permissionValidator.hasCreateAppNamespacePermission(#appId, #appNamespace)")
  @PostMapping("/apps/{appId}/appnamespaces")
  public AppNamespace createAppNamespace(@PathVariable String appId,
      @RequestParam(defaultValue = "true") boolean appendNamespacePrefix,
      @Valid @RequestBody AppNamespace appNamespace) { // 校验 AppNamespace 的 appId 和 name 非空。
    if (!InputValidator.isValidAppNamespace(appNamespace.getName())) {
      throw new BadRequestException(String.format("Invalid Namespace format: %s",
          InputValidator.INVALID_CLUSTER_NAMESPACE_MESSAGE + " & " + InputValidator.INVALID_NAMESPACE_NAMESPACE_MESSAGE));
    }
    // 保存 AppNamespace 对象到数据库
    AppNamespace createdAppNamespace = appNamespaceService.createAppNamespaceInLocal(appNamespace, appendNamespacePrefix);
    // 赋予权限，若满足如下任一条件：1. 公开类型的 AppNamespace 2. 私有类型的 AppNamespace ，并且允许 App 管理员创建私有类型的 AppNamespace
    if (portalConfig.canAppAdminCreatePrivateNamespace() || createdAppNamespace.isPublic()) {
      namespaceService.assignNamespaceRoleToOperator(appId, appNamespace.getName(),
          userInfoHolder.getUser().getUserId());
    }
    // 发布 AppNamespaceCreationEvent 创建事件
    publisher.publishEvent(new AppNamespaceCreationEvent(createdAppNamespace));
    // 返回创建的 AppNamespace 对象
    return createdAppNamespace;
  }
  // ... 省略其他接口和属性
}
```

- **POST `apps/{appId}/appnamespaces` 接口**，Request Body 传递 **JSON** 对象。

- `@PreAuthorize(...)` 注解，调用 `PermissionValidator#hasCreateAppNamespacePermission(appId, appNamespace)` 方法，校验是否有创建 AppNamespace 的权限。后续文章，详细分享。

- `@Valid`调用，校验 AppNamespace 的 `appId` 和 `name` 非空，校验 AppNamespace 的 `name` 格式正确，符合 `[0-9a-zA-Z_.-]+"` 和 `[a-zA-Z0-9._-]+(?<!\.(json|yml|yaml|xml|properties))$` 格式。

- 第 23 行：调用 `AppNamespaceService#createAppNamespaceInLocal(AppNamespace)` 方法，保存 AppNamespace 对象到 **Portal DB** 数据库。在 [「3.2 AppNamespaceService」](https://www.iocoder.cn/Apollo/portal-create-namespace/#) 中，详细解析。

- 第 27 至 30 行：调用 `#assignNamespaceRoleToOperator(String appId, String namespaceName)` 方法，授予 Namespace Role ，需要满足如下**任一**条件。

  - 1、 **公开**类型的 AppNamespace 。

  - 2、**私有**类型的 AppNamespace ，并且允许 App 管理员创建私有类型的 AppNamespace 。

    > **admin.createPrivateNamespace.switch** 【在 ServerConfig 表】
    >
    > 是否允许项目管理员创建 **private namespace** 。设置为 `true` 允许创建，设置为 `false` 则项目管理员在页面上看不到创建 **private namespace** 的选项。并且，项目管理员不允许创建 **private namespace** 。

- 第 32 行：调用 `ApplicationEventPublisher#publishEvent(AppNamespaceCreationEvent)` 方法，发布 `com.ctrip.framework.apollo.portal.listener.AppNamespaceCreationEvent` 事件。

- 第 38 行：返回创建的 AppNamespace 对象。

## 3.2 AppNamespaceService

在 `apollo-portal` 项目中，`com.ctrip.framework.apollo.portal.service.AppNamespaceService` ，提供 AppNamespace 的 **Service** 逻辑。

`#createAppNamespaceInLocal(AppNamespace)` 方法，保存 AppNamespace 对象到 **Portal DB** 数据库。代码如下：

```java
@Service
public class AppNamespaceService {

  private static final int PRIVATE_APP_NAMESPACE_NOTIFICATION_COUNT = 5;
  private static final Joiner APP_NAMESPACE_JOINER = Joiner.on(",").skipNulls();

  private final UserInfoHolder userInfoHolder;
  private final AppNamespaceRepository appNamespaceRepository;
  private final RoleInitializationService roleInitializationService;
  private final AppService appService;
  private final RolePermissionService rolePermissionService;

  @Transactional
  public AppNamespace createAppNamespaceInLocal(AppNamespace appNamespace, boolean appendNamespacePrefix) {
    String appId = appNamespace.getAppId();
    // 校验对应的 App 是否存在。若不存在，抛出 BadRequestException 异常
    //add app org id as prefix
    App app = appService.load(appId);
    if (app == null) {
      throw new BadRequestException("App not exist. AppId = " + appId);
    }
    // 拼接 AppNamespace 的 name 属性。
    StringBuilder appNamespaceName = new StringBuilder();
    //add prefix postfix
    appNamespaceName
        .append(appNamespace.isPublic() && appendNamespacePrefix ? app.getOrgId() + "." : "") // 公用类型，拼接组织编号
        .append(appNamespace.getName())
        .append(appNamespace.formatAsEnum() == ConfigFileFormat.Properties ? "" : "." + appNamespace.getFormat());
    appNamespace.setName(appNamespaceName.toString());

    if (appNamespace.getComment() == null) { // 设置 AppNamespace 的 comment 属性为空串，若为 null
      appNamespace.setComment("");
    }

    if (!ConfigFileFormat.isValidFormat(appNamespace.getFormat())) { // 校验 AppNamespace 的 format 是否合法
     throw new BadRequestException("Invalid namespace format. format must be properties、json、yaml、yml、xml");
    }
    // 设置 AppNamespace 的创建和修改人
    String operator = appNamespace.getDataChangeCreatedBy();
    if (StringUtils.isEmpty(operator)) {
      operator = userInfoHolder.getUser().getUserId(); // 当前登录管理员
      appNamespace.setDataChangeCreatedBy(operator);
    }

    appNamespace.setDataChangeLastModifiedBy(operator);

    // globally uniqueness check for public app namespace
    if (appNamespace.isPublic()) { // 公用类型，校验 name 在全局唯一
      checkAppNamespaceGlobalUniqueness(appNamespace);
    } else { // 私有类型，校验 name 在 App 下唯一
      // check private app namespace
      if (appNamespaceRepository.findByAppIdAndName(appNamespace.getAppId(), appNamespace.getName()) != null) {
        throw new BadRequestException("Private AppNamespace " + appNamespace.getName() + " already exists!");
      }
      // should not have the same with public app namespace
      checkPublicAppNamespaceGlobalUniqueness(appNamespace);
    }
    // 保存 AppNamespace 到数据库
    AppNamespace createdAppNamespace = appNamespaceRepository.save(appNamespace);
    // 初始化 Namespace 的 Role 们
    roleInitializationService.initNamespaceRoles(appNamespace.getAppId(), appNamespace.getName(), operator);
    roleInitializationService.initNamespaceEnvRoles(appNamespace.getAppId(), appNamespace.getName(), operator);

    return createdAppNamespace;
  }
  // ... 省略其他接口和属性
}
```

- 第 15 至 18 行：调用 `AppService.load(appId)` 方法，获得对应的 App 对象。当**校验** App 不存在时，抛出 BadRequestException 异常。

- 第 19 至 26 行：拼接并设置 AppNamespace 的 `name` 属性。

- 第 27 至 30 行：**设置** AppNamespace 的 `comment` 属性为空串，若为 null 。

- 第 31 至 34 行：**校验** AppNamespace 的 `format` 是否合法。

- 第 35 至 41 行：**设置** AppNamespace 的创建和修改人。

- 第 42 至 46 行：若 AppNamespace 为公用类型，**校验** `name` 在**全局**唯一，否则抛出 BadRequestException 异常。`#findPublicAppNamespace(name)` 方法，代码如下：

  ```java
  public AppNamespace findPublicAppNamespace(String namespaceName) {
      return appNamespaceRepository.findByNameAndIsPublic(namespaceName, true);
  }
  ```

- 第 47 至 50 行：若 AppNamespace 为私有类型，**校验** `name` 在 **App** 唯一否则抛出 BadRequestException 异常。

- 第 52 行：调用 `AppNamespaceRepository#save(AppNamespace)` 方法，保存 AppNamespace 到数据库。

- 第 54 行：初始化 Namespace 的 Role 们。详解解析，见 [《Apollo 源码解析 —— Portal 认证与授权（二）之授权》](http://www.iocoder.cn/Apollo/portal-auth-2?self) 。

------

`#createDefaultAppNamespace(appId)` 方法，创建并保存 App 下默认的 `"application"` 的 AppNamespace 到数据库。代码如下：

```java
@Transactional
public void createDefaultAppNamespace(String appId) {
  if (!isAppNamespaceNameUnique(appId, ConfigConsts.NAMESPACE_APPLICATION)) { // 校验 name 在 App 下唯一
    throw new BadRequestException(String.format("App already has application namespace. AppId = %s", appId));
  }
  // 创建 AppNamespace 对象
  AppNamespace appNs = new AppNamespace();
  appNs.setAppId(appId);
  appNs.setName(ConfigConsts.NAMESPACE_APPLICATION); // application
  appNs.setComment("default app namespace");
  appNs.setFormat(ConfigFileFormat.Properties.getValue());
  String userId = userInfoHolder.getUser().getUserId(); // 设置 AppNamespace 的创建和修改人为当前管理员
  appNs.setDataChangeCreatedBy(userId);
  appNs.setDataChangeLastModifiedBy(userId);
  // 保存 AppNamespace 到数据库
  appNamespaceRepository.save(appNs);
}
```

- 在 App **创建**时，会调用该方法。

## 3.3 AppNamespaceRepository

在 `apollo-portal` 项目中，`com.ctrip.framework.apollo.portal.repository.AppNamespaceRepository` ，继承 `org.springframework.data.repository.PagingAndSortingRepository` 接口，提供 AppNamespace 的**数据访问**，即 **DAO** 。

代码如下：

```java
public interface AppNamespaceRepository extends PagingAndSortingRepository<AppNamespace, Long> {

  AppNamespace findByAppIdAndName(String appId, String namespaceName);

  AppNamespace findByName(String namespaceName);

  List<AppNamespace> findByNameAndIsPublic(String namespaceName, boolean isPublic);

  List<AppNamespace> findByIsPublicTrue();

  List<AppNamespace> findByAppId(String appId);

  @Modifying
  @Query("UPDATE AppNamespace SET IsDeleted = 1, DeletedAt = ROUND(UNIX_TIMESTAMP(NOW(4))*1000), DataChange_LastModifiedBy=?2 WHERE AppId=?1")
  int batchDeleteByAppId(String appId, String operator);

  @Modifying
  @Query("UPDATE AppNamespace SET IsDeleted = 1, DeletedAt = ROUND(UNIX_TIMESTAMP(NOW(4))*1000), DataChange_LastModifiedBy = ?3 WHERE AppId=?1 and Name = ?2")
  int delete(String appId, String namespaceName, String operator);
}
```

## 3.4 AppNamespaceCreationEvent

`com.ctrip.framework.apollo.portal.listener.AppNamespaceCreationEvent` ，实现 `org.springframework.context.ApplicationEvent` 抽象类，AppNamespace **创建**事件。

代码如下：

```java
public class AppNamespaceCreationEvent extends ApplicationEvent {

  public AppNamespaceCreationEvent(Object source) {
    super(source);
  }

  public AppNamespace getAppNamespace() {
    Preconditions.checkState(source != null);
    return (AppNamespace) this.source;
  }

}
```

- **构造方法**，将 AppNamespace 对象作为*方法参数*传入。
- `#getAppNamespace()` 方法，获得事件对应的 AppNamespace 对象。

### 3.4.1 CreationListener

`com.ctrip.framework.apollo.portal.listener.CreationListener` ，**对象创建**监听器，目前监听 AppCreationEvent 和 AppNamespaceCreationEvent 事件。

我们以 AppNamespaceCreationEvent 举例子，代码如下：

```java
@EventListener
public void onAppNamespaceCreationEvent(AppNamespaceCreationEvent event) {
  AppNamespaceDTO appNamespace = BeanUtils.transform(AppNamespaceDTO.class, event.getAppNamespace());  // 将 AppNamespace 转成 AppNamespaceDTO 对象
  List<Env> envs = portalSettings.getActiveEnvs(); // 获得有效的 Env 数组
  for (Env env : envs) { // 循环 Env 数组，调用对应的 Admin Service 的 API ，创建 AppNamespace 对象。
    try {
      namespaceAPI.createAppNamespace(env, appNamespace);
    } catch (Throwable e) {
      LOGGER.error("Create appNamespace failed. appId = {}, env = {}", appNamespace.getAppId(), env, e);
      Tracer.logError(String.format("Create appNamespace failed. appId = %s, env = %s", appNamespace.getAppId(), env), e);
    }
  }
}
```

## 3.5 NamespaceAPI

`com.ctrip.framework.apollo.portal.api.NamespaceAPI` ，实现 API 抽象类，封装对 Admin Service 的 AppNamespace 和 Namespace **两个**模块的 API 调用。代码如下：

<img src="http://blog-1259650185.cosbj.myqcloud.com/img/202204/03/1648918781.png" alt="NamespaceAPI" style="zoom:67%;" />

- 使用 `restTemplate` ，调用对应的 API 接口。

# 4. Admin Service 侧

## 4.1 AppNamespaceController

在 `apollo-adminservice` 项目中， `com.ctrip.framework.apollo.adminservice.controller.AppNamespaceController` ，提供 AppNamespace 的 **API** 。

`#create(AppNamespaceDTO)` 方法，创建 AppNamespace 。代码如下：

```java
@RestController
public class AppNamespaceController {

  private final AppNamespaceService appNamespaceService;
  private final NamespaceService namespaceService;

  // 创建 AppNamespace
  @PostMapping("/apps/{appId}/appnamespaces")
  public AppNamespaceDTO create(@RequestBody AppNamespaceDTO appNamespace,
                                @RequestParam(defaultValue = "false") boolean silentCreation) {
    // 将 AppNamespaceDTO 转换成 AppNamespace 对象
    AppNamespace entity = BeanUtils.transform(AppNamespace.class, appNamespace);
    AppNamespace managedEntity = appNamespaceService.findOne(entity.getAppId(), entity.getName());

    if (managedEntity == null) {
      if (StringUtils.isEmpty(entity.getFormat())){
        entity.setFormat(ConfigFileFormat.Properties.getValue()); // 设置 AppNamespace 的 format 属性为 "properties"，若为 null
      }

      entity = appNamespaceService.createAppNamespace(entity); // 保存 AppNamespace 对象到数据库
    } else if (silentCreation) {
      appNamespaceService.createNamespaceForAppNamespaceInAllCluster(appNamespace.getAppId(), appNamespace.getName(),
          appNamespace.getDataChangeCreatedBy());

      entity = managedEntity;
    } else { // 判断 name 在 App 下是否已经存在对应的 AppNamespace 对象。若已经存在，抛出 BadRequestException 异常
      throw new BadRequestException("app namespaces already exist.");
    }

    return BeanUtils.transform(AppNamespaceDTO.class, entity);
  }
  // ... 省略其他接口和属性
}
```

- **POST `/apps/{appId}/appnamespaces` 接口**，Request Body 传递 **JSON** 对象。
- 第 22 行：调用 `BeanUtils#transfrom(Class<T> clazz, Object src)` 方法，将 AppNamespaceDTO **转换**成 AppNamespace对象。
- 第 20 至 23 行：调用 `AppNamespaceService#findOne(appId, name)` 方法，**校验** `name` 在 App 下，是否已经存在对应的 AppNamespace 对象。若已经存在，抛出 BadRequestException 异常。
- 第 24 至 27 行：**设置** AppNamespace 的 `format` 属性为 `"properties"`，若为 null 。
- 第 29 行：调用 `AppNamespaceService#createAppNamespace(AppNamespace)` 方法，保存 AppNamespace 对象到数据库。
- 第 30 至 32 行：调用 `BeanUtils#transfrom(Class<T> clazz, Object src)` 方法，将保存的 AppNamespace 对象，转换成 AppNamespaceDTO 返回。

## 4.2 AppNamespaceService

在 `apollo-biz` 项目中，`com.ctrip.framework.apollo.biz.service.AppNamespaceService` ，提供 AppNamespace 的 **Service** 逻辑给 Admin Service 和 Config Service 。

`#save(AppNamespace)` 方法，保存 AppNamespace 对象到数据库中。代码如下：

```java
@Service
public class AppNamespaceService {

  private static final Logger logger = LoggerFactory.getLogger(AppNamespaceService.class);

  private final AppNamespaceRepository appNamespaceRepository;
  private final NamespaceService namespaceService;
  private final ClusterService clusterService;
  private final AuditService auditService;

  @Transactional
  public AppNamespace createAppNamespace(AppNamespace appNamespace) {
    String createBy = appNamespace.getDataChangeCreatedBy();
    if (!isAppNamespaceNameUnique(appNamespace.getAppId(), appNamespace.getName())) { // 判断 name 在 App 下是否已经存在对应的 AppNamespace 对象。若已经存在，抛出 ServiceException 异常。
      throw new ServiceException("appnamespace not unique");
    }
    appNamespace.setId(0);//protection 保护代码，避免 App 对象中，已经有 id 属性
    appNamespace.setDataChangeCreatedBy(createBy);
    appNamespace.setDataChangeLastModifiedBy(createBy);
    // 保存 AppNamespace 到数据库
    appNamespace = appNamespaceRepository.save(appNamespace);
    // 创建 AppNamespace 在 App 下，每个 Cluster 的 Namespace 对象。
    createNamespaceForAppNamespaceInAllCluster(appNamespace.getAppId(), appNamespace.getName(), createBy);
    // 记录 Audit 到数据库中
    auditService.audit(AppNamespace.class.getSimpleName(), appNamespace.getId(), Audit.OP.INSERT, createBy);
    return appNamespace;
  }
  // ... 省略其他接口和属性
}
```

- 第 12 至 16 行：调用 `#isAppNamespaceNameUnique(appId, name)` 方法，判断 `name` 在 App 下是否已经存在对应的 AppNamespace 对象。若已经存在，抛出 ServiceException 异常。代码如下：

  ```java
  public boolean isAppNamespaceNameUnique(String appId, String namespaceName) {
      Objects.requireNonNull(appId, "AppId must not be null");
      Objects.requireNonNull(namespaceName, "Namespace must not be null");
      return Objects.isNull(appNamespaceRepository.findByAppIdAndName(appId, namespaceName));
  }
  ```

- 第 18 行：置“**空**” AppNamespace 的编号，防御性编程，避免 AppNamespace 对象中，已经有 `id` 属性。

- 第 22 行：调用 `AppNamespaceRepository#save(AppNamespace)` 方法，保存 AppNamespace 对象到数据库中。

- 第 24 行：调用 `#instanceOfAppNamespaceInAllCluster(appId, namespaceName, createBy)` 方法，创建 AppNamespace 在 App 下，**每个** Cluster 的 Namespace 对象。代码如下：

  ```java
  private void instanceOfAppNamespaceInAllCluster(String appId, String namespaceName, String createBy) {
      // 获得 App 下所有的 Cluster 数组
      List<Cluster> clusters = clusterService.findParentClusters(appId);
      // 循环 Cluster 数组，创建并保存 Namespace 到数据库
      for (Cluster cluster : clusters) {
          Namespace namespace = new Namespace();
          namespace.setClusterName(cluster.getName());
          namespace.setAppId(appId);
          namespace.setNamespaceName(namespaceName);
          namespace.setDataChangeCreatedBy(createBy);
          namespace.setDataChangeLastModifiedBy(createBy);
          namespaceService.save(namespace);
      }
  }
  ```

- 第 26 行：记录 Audit 到数据库中。

## 4.3 AppNamespaceRepository

`com.ctrip.framework.apollo.biz.repository.AppNamespaceRepository` ，继承 `org.springframework.data.repository.PagingAndSortingRepository` 接口，提供 AppNamespace 的**数据访问** 给 Admin Service 和 Config Service 。代码如下：

```java
public interface AppNamespaceRepository extends PagingAndSortingRepository<AppNamespace, Long>{

  AppNamespace findByAppIdAndName(String appId, String namespaceName);

  List<AppNamespace> findByAppIdAndNameIn(String appId, Set<String> namespaceNames);

  AppNamespace findByNameAndIsPublicTrue(String namespaceName);

  List<AppNamespace> findByNameInAndIsPublicTrue(Set<String> namespaceNames);

  List<AppNamespace> findByAppIdAndIsPublic(String appId, boolean isPublic);

  List<AppNamespace> findByAppId(String appId);

  List<AppNamespace> findFirst500ByIdGreaterThanOrderByIdAsc(long id);

  @Modifying
  @Query("UPDATE AppNamespace SET IsDeleted = 1, DeletedAt = ROUND(UNIX_TIMESTAMP(NOW(4))*1000), DataChange_LastModifiedBy = ?2 WHERE AppId=?1")
  int batchDeleteByAppId(String appId, String operator);

  @Modifying
  @Query("UPDATE AppNamespace SET IsDeleted = 1, DeletedAt = ROUND(UNIX_TIMESTAMP(NOW(4))*1000), DataChange_LastModifiedBy = ?3 WHERE AppId=?1 and Name = ?2")
  int delete(String appId, String namespaceName, String operator);
}
```

## 4.4 NamespaceService

在 `apollo-biz` 项目中，`com.ctrip.framework.apollo.biz.service.NamespaceService` ，提供 Namespace 的 **Service** 逻辑给 Admin Service 和 Config Service 。

`#save(Namespace)` 方法，保存 Namespace 对象到数据库中。代码如下：

```java
@Service
public class NamespaceService {

  private static final Gson GSON = new Gson();

  private final NamespaceRepository namespaceRepository;
  private final AuditService auditService;
  private final AppNamespaceService appNamespaceService;
  private final ItemService itemService;
  private final CommitService commitService;
  private final ReleaseService releaseService;
  private final ClusterService clusterService;
  private final NamespaceBranchService namespaceBranchService;
  private final ReleaseHistoryService releaseHistoryService;
  private final NamespaceLockService namespaceLockService;
  private final InstanceService instanceService;
  private final MessageSender messageSender;

  @Transactional
  public Namespace save(Namespace entity) {
    if (!isNamespaceUnique(entity.getAppId(), entity.getClusterName(), entity.getNamespaceName())) { // 判断是否已经存在。若是，抛出 ServiceException 异常。
      throw new ServiceException("namespace not unique");
    }
    entity.setId(0);//protection 保护代码，避免 Namespace 对象中，已经有 id 属性
    Namespace namespace = namespaceRepository.save(entity); // 保存 Namespace 到数据库
    // 保存 Namespace 到数据库
    auditService.audit(Namespace.class.getSimpleName(), namespace.getId(), Audit.OP.INSERT,
                       namespace.getDataChangeCreatedBy());

    return namespace;
  }
  // ... 省略其他接口和属性
}
```

- 第 8 至 11 行：调用 `#isNamespaceUnique(appId, cluster, namespace)` 方法，**校验**是否已经存在。若是，抛出 ServiceException 异常。代码如下：

  ```java
  public boolean isNamespaceUnique(String appId, String cluster, String namespace) {
      Objects.requireNonNull(appId, "AppId must not be null");
      Objects.requireNonNull(cluster, "Cluster must not be null");
      Objects.requireNonNull(namespace, "Namespace must not be null");
      return Objects.isNull(namespaceRepository.findByAppIdAndClusterNameAndNamespaceName(appId, cluster, namespace));
  }
  ```

- 第 12 行：置“**空**” Namespace 的编号，防御性编程，避免 Namespace 对象中，已经有 `id` 属性。

- 第 15 行：调用 `NamespaceRepository#save(AppNamespace)` 方法，保存 Namespace 对象到数据库中。

- 第 17 行：记录 Audit 到数据库中。

------

`#instanceOfAppNamespaces(appId, clusterName, createBy)` 方法，创建并保存 App 下**指定** Cluster 的 Namespace 到数据库。代码如下：

```java
@Transactional
public void instanceOfAppNamespaces(String appId, String clusterName, String createBy) {

  List<AppNamespace> appNamespaces = appNamespaceService.findByAppId(appId); // 获得所有的 AppNamespace 对象
  // 循环 AppNamespace 数组，创建并保存 Namespace 到数据库
  for (AppNamespace appNamespace : appNamespaces) {
    Namespace ns = new Namespace();
    ns.setAppId(appId);
    ns.setClusterName(clusterName);
    ns.setNamespaceName(appNamespace.getName());
    ns.setDataChangeCreatedBy(createBy);
    ns.setDataChangeLastModifiedBy(createBy);
    namespaceRepository.save(ns);
    auditService.audit(Namespace.class.getSimpleName(), ns.getId(), Audit.OP.INSERT, createBy);  // 记录 Audit 到数据库中
  }

}
```

- 在 App **创建**时，传入 Cluster 为 `default` ，此时只有 **1** 个 AppNamespace 对象。
- 在 Cluster **创建**时，传入**自己**，此处可以有**多**个 AppNamespace 对象。

## 4.5 NamespaceRepository

`com.ctrip.framework.apollo.biz.repository.NamespaceRepository` ，继承 `org.springframework.data.repository.PagingAndSortingRepository` 接口，提供 Namespace 的**数据访问** 给 Admin Service 和 Config Service 。代码如下：

```java
public interface NamespaceRepository extends PagingAndSortingRepository<Namespace, Long> {

  List<Namespace> findByAppIdAndClusterNameOrderByIdAsc(String appId, String clusterName);

  Namespace findByAppIdAndClusterNameAndNamespaceName(String appId, String clusterName, String namespaceName);

  @Modifying
  @Query("update Namespace set IsDeleted = 1, DeletedAt = ROUND(UNIX_TIMESTAMP(NOW(4))*1000), DataChange_LastModifiedBy = ?3 where appId=?1 and clusterName=?2")
  int batchDelete(String appId, String clusterName, String operator);

  List<Namespace> findByAppIdAndNamespaceNameOrderByIdAsc(String appId, String namespaceName);

  List<Namespace> findByNamespaceName(String namespaceName, Pageable page);

  List<Namespace> findByIdIn(Set<Long> namespaceIds);

  int countByNamespaceNameAndAppIdNot(String namespaceName, String appId);

}
```



# 参考

[Apollo 源码解析 —— Portal 创建 Namespace](https://www.iocoder.cn/Apollo/portal-create-namespace/)
