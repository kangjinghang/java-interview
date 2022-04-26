# 1. 概述

> 老艿艿：本系列假定胖友已经阅读过 [《Apollo 官方 wiki 文档》](https://github.com/ctripcorp/apollo/wiki/) 。

本文分享 **Portal 创建 App** 的流程，整个过程涉及 Portal、Admin Service ，如下图所示：

![流程](http://blog-1259650185.cosbj.myqcloud.com/img/202204/02/1648888594.png)

下面，我们先来看看 App 的实体结构

> 老艿艿：因为 Portal 是管理后台，所以从代码实现上，和业务系统非常相像。也因此，本文会略显啰嗦。

# 2. App

在 `apollo-common` 项目中， `com.ctrip.framework.apollo.common.entity.App` ，继承 BaseEntity 抽象类，应用信息**实体**。代码如下：

```java
@Entity
@Table(name = "App")
@SQLDelete(sql = "Update App set isDeleted = 1 where id = ?")
@Where(clause = "isDeleted = 0")
public class App extends BaseEntity {

    /**
     * App 名
     */
    @Column(name = "Name", nullable = false)
    private String name;
    /**
     * App 编号
     */
    @Column(name = "AppId", nullable = false)
    private String appId;
    /**
     * 部门编号
     */
    @Column(name = "OrgId", nullable = false)
    private String orgId;
    /**
     * 部门名
     *
     * 冗余字段
     */
    @Column(name = "OrgName", nullable = false)
    private String orgName;
    /**
     * 拥有人名
     *
     * 例如在 Portal 系统中，使用系统的管理员账号，即 UserPO.username 字段
     */
    @Column(name = "OwnerName", nullable = false)
    private String ownerName;
    /**
     * 拥有人邮箱
     *
     * 冗余字段
     */
    @Column(name = "OwnerEmail", nullable = false)
    private String ownerEmail;
}
```

- ORM 选用 **Hibernate** 框架。
- `@SQLDelete(...)` + `@Where(...)` 注解，配合 `BaseEntity.extends` 字段，实现 App 的**逻辑删除**。
- 字段比较简单，胖友看下注释。

## 2.1 BaseEntity

`com.ctrip.framework.apollo.common.entity.BaseEntity` ，**基础**实体**抽象类**。代码如下：

```java
@MappedSuperclass
@Inheritance(strategy = InheritanceType.TABLE_PER_CLASS)
public abstract class BaseEntity {

    /**
     * 编号
     */
    @Id
    @GeneratedValue
    @Column(name = "Id")
    private long id;
    /**
     * 是否删除
     */
    @Column(name = "IsDeleted", columnDefinition = "Bit default '0'")
    protected boolean isDeleted = false;
  
    /**
    * 数据删除时间
    */
    @Column(name = "DeletedAt", columnDefinition = "Bigint default '0'")
    protected long deletedAt;
  
    /**
     * 数据创建人
     *
     * 例如在 Portal 系统中，使用系统的管理员账号，即 UserPO.username 字段
     */
    @Column(name = "DataChange_CreatedBy", nullable = false)
    private String dataChangeCreatedBy;
    /**
     * 数据创建时间
     */
    @Column(name = "DataChange_CreatedTime", nullable = false)
    private Date dataChangeCreatedTime;
    /**
     * 数据最后更新人
     *
     * 例如在 Portal 系统中，使用系统的管理员账号，即 UserPO.username 字段
     */
    @Column(name = "DataChange_LastModifiedBy")
    private String dataChangeLastModifiedBy;
    /**
     * 数据最后更新时间
     */
    @Column(name = "DataChange_LastTime")
    private Date dataChangeLastModifiedTime;

    /**
     * 保存前置方法
     */
    @PrePersist
    protected void prePersist() {
        if (this.dataChangeCreatedTime == null) dataChangeCreatedTime = new Date();
        if (this.dataChangeLastModifiedTime == null) dataChangeLastModifiedTime = new Date();
    }

    /**
     * 更新前置方法
     */
    @PreUpdate
    protected void preUpdate() {
        this.dataChangeLastModifiedTime = new Date();
    }

    /**
     * 删除前置方法
     */
    @PreRemove
    protected void preRemove() {
        this.dataChangeLastModifiedTime = new Date();
    }
    
    // ... 省略 setting / getting 方法
}
```

- `@MappedSuperclass` 注解，见 [《Hibernate 中 @MappedSuperclass 注解的使用说明》](https://blog.csdn.net/u012402177/article/details/78666532) 文章。
- `@Inheritance(...)` 注解，见 [《Hibernate（11）映射继承关系二之每个类对应一张表（@Inheritance(strategy=InheritanceType.TABLE_PER_CLASS）》](https://blog.csdn.net/jiangshangchunjiezi/article/details/78522924) 文章。
- `id` 字段，编号，Long 型，全局自增。
- `isDeleted` 字段，是否删除，用于**逻辑删除**的功能。
- `dataChangeCreatedBy` 和 `dataChangeCreatedTime` 字段，实现数据的创建人和时间的记录，方便追踪。
- `dataChangeLastModifiedBy` 和 `dataChangeLastModifiedTime` 字段，实现数据的更新人和时间的记录，方便追踪。
- `@PrePersist`、`@PreUpdate`、`@PreRemove` 注解，CRD 操作前，设置对应的**时间字段**。
- 在 Apollo 中，**所有**实体都会继承 BaseEntity ，实现**公用字段**的**统一**定义。这种设计值得**借鉴**，特别是**创建时间**和**更新时间**这两个字段，特别适合线上追踪问题和数据同步。

## 2.2 为什么需要同步

在文初的流程图中，我们看到 App 创建时，在 Portal Service 存储完成后，会**异步**同步到 Admin Service 中，这是为什么呢？

在 Apollo 的架构中，**一个**环境( Env ) 对应一套 Admin Service 和 Config Service 。
而 Portal Service 会管理**所有**环境( Env ) 。因此，每次创建 App 后，需要进行同步。

或者说，App 在 Portal Service 中，表示需要**管理**的 App 。而在 Admin Service 和 Config Service 中，表示**存在**的 App 。

# 3. Portal 侧

## 3.1 AppController

在 `apollo-portal` 项目中，`com.ctrip.framework.apollo.portal.controller.AppController` ，提供 App 的 **API** 。

在**创建项目**的界面中，点击【提交】按钮，调用**创建 App 的 API** 。

![创建项目](http://blog-1259650185.cosbj.myqcloud.com/img/202204/02/1648889671.png)

代码如下：

```java
@RestController
@RequestMapping("/apps")
public class AppController {

  private final UserInfoHolder userInfoHolder;
  private final AppService appService;
  private final PortalSettings portalSettings;
  private final ApplicationEventPublisher publisher; // Spring 事件发布者
  private final RolePermissionService rolePermissionService;
  private final RoleInitializationService roleInitializationService;
  private final AdditionalUserInfoEnrichService additionalUserInfoEnrichService;

  @PreAuthorize(value = "@permissionValidator.hasCreateApplicationPermission()")
  @PostMapping
  public App create(@Valid @RequestBody AppModel appModel) {
    // 将 AppModel 转换成 App 对象
    App app = transformToApp(appModel);
    // 保存 App 对象到数据库
    App createdApp = appService.createAppInLocal(app);
    // 发布 AppCreationEvent 创建事件
    publisher.publishEvent(new AppCreationEvent(createdApp));
    // 授予 App 管理员的角色
    Set<String> admins = appModel.getAdmins();
    if (!CollectionUtils.isEmpty(admins)) {
      rolePermissionService
          .assignRoleToUsers(RoleUtils.buildAppMasterRoleName(createdApp.getAppId()),
              admins, userInfoHolder.getUser().getUserId());
    }

    return createdApp;
  }

	// ... 省略其他接口和属性
}
```

- **POST `apps` 接口**，Request Body 传递 **JSON** 对象。
- [`com.ctrip.framework.apollo.portal.entity.model.AppModel`](https://github.com/YunaiV/apollo/blob/master/apollo-portal/src/main/java/com/ctrip/framework/apollo/portal/entity/model/AppModel.java) ，App Model 。在 `com.ctrip.framework.apollo.portal.entity.model` 包下，负责接收来自 Portal 界面的**复杂**请求对象。例如，AppModel 一方面带有创建 App 对象需要的属性，另外也带有需要授权管理员的编号集合 `admins` ，即存在**跨模块**的情况。
- 第 26 行：调用 [`#transformToApp(AppModel)`](https://github.com/YunaiV/apollo/blob/e7984de5d6ed8124184f8107e079f9d84462f037/apollo-portal/src/main/java/com/ctrip/framework/apollo/portal/controller/AppController.java#L171-L188) 方法，将 AppModel 转换成 App 对象。🙂 转换方法很简单，点击方法，直接查看。
- 第 28 行：调用 `AppService#createAppInLocal(App)` 方法，保存 App 对象到 **Portal DB** 数据库。在 [「3.2 AppService」](https://www.iocoder.cn/Apollo/portal-create-app/#) 中，详细解析。
- 第 30 行：调用 `ApplicationEventPublisher#publishEvent(AppCreationEvent)` 方法，发布 `com.ctrip.framework.apollo.portal.listener.AppCreationEvent` 事件。
- 第 31 至 36 行：授予 App 管理员的角色。详细解析，见 [《Apollo 源码解析 —— Portal 认证与授权（二）之授权》](http://www.iocoder.cn/Apollo/portal-auth-2?self) 。
- 第 38 行：返回创建的 App 对象。

## 3.2 AppService

在 `apollo-portal` 项目中，`com.ctrip.framework.apollo.portal.service.AppService` ，提供 App 的 **Service** 逻辑。

`#createAppInLocal(App)` 方法，保存 App 对象到 **Portal DB** 数据库。代码如下：

```java
@Transactional
public App createAppInLocal(App app) {
  String appId = app.getAppId();
  App managedApp = appRepository.findByAppId(appId);
  // 判断 appId 是否已经存在对应的 App 对象。若已经存在，抛出 BadRequestException 异常。
  if (managedApp != null) {
    throw new BadRequestException(String.format("App already exists. AppId = %s", appId));
  }
  // 获得 UserInfo 对象。若不存在，抛出 BadRequestException 异常
  UserInfo owner = userService.findByUserId(app.getOwnerName());
  if (owner == null) {
    throw new BadRequestException("Application's owner not exist.");
  }
  app.setOwnerEmail(owner.getEmail());
  // 设置 App 的创建和修改人
  String operator = userInfoHolder.getUser().getUserId();
  app.setDataChangeCreatedBy(operator);
  app.setDataChangeLastModifiedBy(operator);
  // 保存 App 对象到数据库
  App createdApp = appRepository.save(app);
  // 创建 App 的默认命名空间 "application"
  appNamespaceService.createDefaultAppNamespace(appId);
  roleInitializationService.initAppRoles(createdApp);  // 初始化 App 角色
  // Tracer 日志
  Tracer.logEvent(TracerEventType.CREATE_APP, appId);

  return createdApp;
}
```

- 第 15 至 19 行：调用 `AppRepository#findByAppId(appId)` 方法，判断 `appId` 是否已经存在对应的 App 对象。若已经存在，抛出 BadRequestException 异常。
- 第 20 至 25 行：调用 `UserService#findByUserId(userId)` 方法，获得 [`com.ctrip.framework.apollo.portal.entity.bo.UserInfo`](https://github.com/YunaiV/apollo/blob/master/apollo-portal/src/main/java/com/ctrip/framework/apollo/portal/entity/bo/UserInfo.java) 对象。`com.ctrip.framework.apollo.portal.entity.bo` 包下，负责返回 Service 的**业务**对象。例如，UserInfo 只包含 `com.ctrip.framework.apollo.portal.entity.po.UserPO` 的部分属性：`userId`、`username`、`email` 。
- 第 27 至 29 行：调用 `UserInfoHolder#getUser()#getUserId()` 方法，获得当前登录用户，并设置为 App 的创建和修改人。关于 UserInfoHolder ，后续文章，详细分享。
- 第 31 行：调用 `AppRepository#save(App)` 方法，保存 App 对象到数据库中。
- 第 33 行：调用 `AppNameSpaceService#createDefaultAppNamespace(appId)` 方法，创建 App 的**默认** Namespace (命名空间) `"application"` 。对于每个 App ，都会有一个默认 Namespace 。具体的代码实现，我们在 [《Apollo 源码解析 —— Portal 创建 Namespace》](http://www.iocoder.cn/Apollo/portal-create-namespace/?self)
- 第 35 行：初始化 App 角色。详解解析，见 [《Apollo 源码解析 —— Portal 认证与授权（二）之授权》](http://www.iocoder.cn/Apollo/portal-auth-2?self) 。
- 第 37 行：【TODO 6001】Tracer 日志

## 3.3 AppRepository

在 `apollo-portal` 项目中，`com.ctrip.framework.apollo.common.entity.App.AppRepository` ，继承 `org.springframework.data.repository.PagingAndSortingRepository` 接口，提供 App 的**数据访问**，即 **DAO** 。

代码如下：

```java
public interface AppRepository extends PagingAndSortingRepository<App, Long> {

  App findByAppId(String appId);

  List<App> findByOwnerName(String ownerName, Pageable page);

  List<App> findByAppIdIn(Set<String> appIds);

  List<App> findByAppIdIn(Set<String> appIds, Pageable pageable);

  Page<App> findByAppIdContainingOrNameContaining(String appId, String name, Pageable pageable);

  @Modifying
  @Query("UPDATE App SET IsDeleted = 1, DeletedAt = ROUND(UNIX_TIMESTAMP(NOW(4))*1000), DataChange_LastModifiedBy = ?2 WHERE AppId=?1")
  int deleteApp(String appId, String operator);
}
```

基于 Spring Data JPA 框架，使用 Hibernate 实现。详细参见 [《Spring Data JPA、Hibernate、JPA 三者之间的关系》](https://www.cnblogs.com/xiaoheike/p/5150553.html) 文章。

🙂 不熟悉 Spring Data JPA 的胖友，可以看下 [《Spring Data JPA 介绍和使用》](https://www.jianshu.com/p/633922bb189f) 文章。

## 3.4 AppCreationEvent

`com.ctrip.framework.apollo.portal.listener.AppCreationEvent` ，实现 `org.springframework.context.ApplicationEvent` 抽象类，App **创建**事件。

代码如下：

```java
public class AppCreationEvent extends ApplicationEvent {

  public AppCreationEvent(Object source) {
    super(source);
  }

  public App getApp() {
    Preconditions.checkState(source != null);
    return (App) this.source;
  }

}
```

- **构造方法**，将 App 对象作为*方法参数*传入。
- `#getApp()` 方法，获得事件对应的 App 对象。

### 3.4.1 CreationListener

`com.ctrip.framework.apollo.portal.listener.CreationListener` ，**对象创建**监听器，目前监听 AppCreationEvent 和 AppNamespaceCreationEvent 事件。

我们以 AppCreationEvent 举例子，代码如下：

```java
private final AdminServiceAPI.AppAPI appAPI;
private final AdminServiceAPI.NamespaceAPI namespaceAPI;

@EventListener
public void onAppCreationEvent(AppCreationEvent event) {
  AppDTO appDTO = BeanUtils.transform(AppDTO.class, event.getApp()); // 将 App 转成 AppDTO 对象
  List<Env> envs = portalSettings.getActiveEnvs(); // 获得有效的 Env 数组
  for (Env env : envs) { // 循环 Env 数组，调用对应的 Admin Service 的 API ，创建 App 对象。
    try {
      appAPI.createApp(env, appDTO);
    } catch (Throwable e) {
      LOGGER.error("Create app failed. appId = {}, env = {})", appDTO.getAppId(), env, e);
      Tracer.logError(String.format("Create app failed. appId = %s, env = %s", appDTO.getAppId(), env), e);
    }
  }
}
```

- `@EventListener` 注解 + 方法参数，表示 `#onAppCreationEvent(...)` 方法，监听 AppCreationEvent 事件。不了解的胖友，可以看下 [《Spring 4.2框架中注释驱动的事件监听器详解》](https://blog.csdn.net/chszs/article/details/49097919) 文章。

- 第 9 行：调用`BeanUtils#transfrom(Class<T> clazz, Object src)`

  方法，将 App 转换成`com.ctrip.framework.apollo.common.dto.AppDTO`对象。`com.ctrip.framework.apollo.common.dto`

  包下，提供 Controller 和 Service 层的数据传输。😈 笔者思考了下，Apollo 中，Model 和 DTO 对象很类似，差异点在 Model 更侧重 UI 界面提交“复杂”业务请求。另外 Apollo 中，还有 VO 对象，侧重 UI 界面返回复杂业务响应。整理如下图：

  ​	<img src="http://blog-1259650185.cosbj.myqcloud.com/img/202204/02/1648891796.png" alt="各种 Entity 整理" style="zoom:67%;" />

  - 老艿艿认为，PO 对象，可以考虑不暴露给 Controller 层，只在 Service 和 Repository 之间传递和返回。
  - 和彩笔老徐交流了下，实际项目可以简化，使用 VO + DTO + PO 。

- 第 11 行：调用 `PortalSettings#getActiveEnvs()` 方法，获得**有效**的 Env 数组，例如 `PROD` `UAT` 等。后续文章，详细分享该方法。

- 第 12 至 20 行：循环 Env 数组，调用 `AppAPI#createApp(Env, AppDTO)` 方法，调用对应的 Admin Service 的 **API** ，创建 App 对象，从而同步 App 到 **Config DB**。

## 3.5 AdminServiceAPI

`com.ctrip.framework.apollo.portal.api.AdminServiceAPI` ，Admin Service API **集合**，包含 Admin Service **所有模块** API 的调用封装。简化代码如下：

<img src="http://blog-1259650185.cosbj.myqcloud.com/img/202204/02/1648891983.png" alt="代码" style="zoom:50%;" />

### 3.5.1 API

`com.ctrip.framework.apollo.portal.api.API` ，API 抽象类。代码如下：

```java
public abstract class API {

  @Autowired
  protected RetryableRestTemplate restTemplate;

}
```

- 提供统一的 `restTemplate` 的属性注入。对于 RetryableRestTemplate 的源码实现，我们放到后续文章分享。

### 3.5.2 AppAPI

`com.ctrip.framework.apollo.portal.api.AdminServiceAPI.AppAPI` ，实现 API 抽象类，封装对 Admin Service 的 App 模块的 API 调用。代码如下：

```java
@Service
public static class AppAPI extends API {

  public AppDTO loadApp(Env env, String appId) {
    return restTemplate.get(env, "apps/{appId}", AppDTO.class, appId);
  }

  public AppDTO createApp(Env env, AppDTO app) {
    return restTemplate.post(env, "apps", app, AppDTO.class);
  }

  public void updateApp(Env env, AppDTO app) {
    restTemplate.put(env, "apps/{appId}", app, app.getAppId());
  }

  public void deleteApp(Env env, String appId, String operator) {
    restTemplate.delete(env, "/apps/{appId}?operator={operator}", appId, operator);
  }
}
```

- 使用 `restTemplate` ，调用对应的 API 接口。

# 4. Admin Service 侧

## 4.1 AppController

在 `apollo-adminservice` 项目中， `com.ctrip.framework.apollo.adminservice.controller.AppController` ，提供 App 的 **API** 。

`#create(AppDTO)` 方法，创建 App 。代码如下：

```java
@RestController
public class AppController {

  private final AppService appService;
  private final AdminService adminService;

  @PostMapping("/apps")
  public AppDTO create(@Valid @RequestBody AppDTO dto) {
    App entity = BeanUtils.transform(App.class, dto);  // 将 AppDTO 转换成 App 对象
    App managedEntity = appService.findOne(entity.getAppId());
    if (managedEntity != null) { // // 判断 appId 是否已经存在对应的 App 对象。若已经存在，抛出 BadRequestException 异常
      throw new BadRequestException("app already exist.");
    }
    // 保存 App 对象到数据库
    entity = adminService.createNewApp(entity);
    // 将保存的 App 对象，转换成 AppDTO 返回
    return BeanUtils.transform(AppDTO.class, entity);
  }

	// ... 省略其他接口和属性
}
```

- **POST `apps` 接口**，Request Body 传递 **JSON** 对象。
- 第 22 行：调用 `BeanUtils#transfrom(Class<T> clazz, Object src)` 方法，将 AppDTO 转换成 App对象。
- 第 24 至 27 行：调用 `AppService#findOne(appId)` 方法，判断 `appId` 是否已经存在对应的 App 对象。若已经存在，抛出 BadRequestException 异常。
- 第 29 行：调用 `AdminService#createNewApp(App)` 方法，保存 App 对象到数据库。
- 第 30 至 32 行：调用 `BeanUtils#transfrom(Class<T> clazz, Object src)` 方法，将保存的 App 对象，转换成 AppDTO 返回。

## 4.2 AdminService

`com.ctrip.framework.apollo.biz.service.AdminService` ，😈 无法定义是什么模块的 Service ，目前仅有 `#createNewApp(App)` 方法，代码如下：

```java
@Service
public class AdminService {
  private final static Logger logger = LoggerFactory.getLogger(AdminService.class);

  private final AppService appService;
  private final AppNamespaceService appNamespaceService;
  private final ClusterService clusterService;
  private final NamespaceService namespaceService;

  @Transactional
  public App createNewApp(App app) {
    String createBy = app.getDataChangeCreatedBy();
    App createdApp = appService.save(app); // 保存 App 对象到数据库

    String appId = createdApp.getAppId();
    // 创建 App 的默认命名空间 "application"
    appNamespaceService.createDefaultAppNamespace(appId, createBy);
    // 创建 App 的默认集群 "default"
    clusterService.createDefaultCluster(appId, createBy);
    // 创建 Cluster 的默认命名空间
    namespaceService.instanceOfAppNamespaces(appId, ConfigConsts.CLUSTER_NAME_DEFAULT, createBy);

    return app;
  }
  
  // ... 省略其他接口和属性
}
```

- 第 15 至 18 行：调用 `AppService#save(App)` 方法，保存 App 对象到数据库中。
- 第 20 行：调用 `AppNamespaceService#createDefaultAppNamespace(appId, createBy)` 方法，创建 App 的**默认** Namespace (命名空间) `"application"` 。具体的代码实现，我们在 [《Apollo 源码解析 —— Portal 创建 Namespace》](http://www.iocoder.cn/Apollo/portal-create-namespace/?self) 详细解析。
- ========== 如下部分，是 Admin Service 独有 ==========
- App 下有哪些 Cluster ，在 Portal 中是**不进行保存**，通过 Admin Service API 读取获得。
- 【AppNamespace】第 22 行：调用 `ClusterService#createDefaultCluster(appId, createBy)` 方法，创建 App 的**默认** Cluster `"default"` 。后续文章，详细分享。
- 【Namespace】第 24 行：调用 `NamespaceService#instanceOfAppNamespaces(appId, createBy)` 方法，创建 Cluster 的**默认**命名空间。

## 4.3 AppService

在 `apollo-biz` 项目中，`com.ctrip.framework.apollo.biz.service.AppService` ，提供 App 的 **Service** 逻辑给 Admin Service 和 Config Service 。

`#save(App)` 方法，保存 App 对象到数据库中。代码如下：

```java
@Transactional
public App save(App entity) {
  if (!isAppIdUnique(entity.getAppId())) { // 判断是否已经存在。若是，抛出 ServiceException 异常。
    throw new ServiceException("appId not unique");
  }
  entity.setId(0);//protection 保护代码，避免 App 对象中，已经有 id 属性。
  App app = appRepository.save(entity);
  // 记录 Audit 到数据库中
  auditService.audit(App.class.getSimpleName(), app.getId(), Audit.OP.INSERT,
      app.getDataChangeCreatedBy());

  return app;
}
```

- 第 8 至 11 行：调用 `#isAppIdUnique(appId)` 方法，判断是否已经存在。若是，抛出 ServiceException 异常。代码如下：

  ```java
  public boolean isAppIdUnique(String appId) {
      Objects.requireNonNull(appId, "AppId must not be null");
      return Objects.isNull(appRepository.findByAppId(appId));
  }
  ```

- 第 13 行：置“**空**” App 对象，防御性编程，避免 App 对象中，已经有 `id` 属性。

- 第 14 行：调用 `AppRepository#save(App)` 方法，保存 App 对象到数据库中。

- 第 16 行：记录 Audit 到数据库中。

## 4.4 AppRepository

`com.ctrip.framework.apollo.biz.repository.AppRepository` ，继承 `org.springframework.data.repository.PagingAndSortingRepository` 接口，提供 App 的**数据访问** 给 Admin Service 和 Config Service 。代码如下：

```java
public interface AppRepository extends PagingAndSortingRepository<App, Long> {

  @Query("SELECT a from App a WHERE a.name LIKE %:name%")
  List<App> findByName(@Param("name") String name);

  App findByAppId(String appId);

}
```

# 666. 彩蛋

我们知道，但凡涉及**跨系统**的同步，无可避免会有**事务**的问题，对于 App 创建也会碰到这样的问题，例如：

1. Portal 在同步 App 到 Admin Service 时，发生网络异常，**同步失败**。那么此时会出现该 App 存在于 Portal ，却不存在于 Admin Service 中。
2. 新增了一套环境( Env ) ，也会导致 Portal 和 Admin Service 不一致的情况。

那么 Apollo 是怎么解决这个问题的呢？😈 感兴趣的胖友，可以先自己翻翻源码。嘿嘿。



# 参考

[Apollo 源码解析 —— Portal 创建 App](https://www.iocoder.cn/Apollo/portal-create-app/)
