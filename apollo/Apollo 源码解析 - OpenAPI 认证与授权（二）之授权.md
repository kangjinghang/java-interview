# 1. 概述

> 老艿艿：本系列假定胖友已经阅读过 [《Apollo 官方 wiki 文档》](https://github.com/ctripcorp/apollo/wiki/) ，特别是 [《Apollo 开放平台》](https://github.com/ctripcorp/apollo/wiki/Apollo开放平台) 。

本文接 [《Apollo 源码解析 —— OpenAPI 认证与授权（一）之认证》](http://www.iocoder.cn/Apollo/openapi-auth-1/?self) ，**侧重在授权部分**。和 Portal 的**授权**一样：

> 具体**每个** URL 的权限校验，通过在对应的方法上，添加 `@PreAuthorize` 方法注解，配合具体的方法参数，一起校验**功能 + 数据级**的权限校验。

# 2. 权限模型

和 Portal 使用**相同**的权限模型，**差别**在于 UserRole 换成了 ConsumerRole 。所以，关系如下图：

<img src="http://blog-1259650185.cosbj.myqcloud.com/img/202204/07/1649319788.png" alt="关系" style="zoom:50%;" />

## 2.1 ConsumerRole

**ConsumerRole** 表，Consumer 与角色的**关联**表，对应实体 `com.ctrip.framework.apollo.openapi.entity.ConsumerRole` ，代码如下：

```java
@Entity
@Table(name = "ConsumerRole")
@SQLDelete(sql = "Update ConsumerRole set IsDeleted = 1, DeletedAt = ROUND(UNIX_TIMESTAMP(NOW(4))*1000) where Id = ?")
@Where(clause = "isDeleted = 0")
public class ConsumerRole extends BaseEntity {
  @Column(name = "ConsumerId", nullable = false)
  private long consumerId; // Consumer 编号 {@link Consumer#id}

  @Column(name = "RoleId", nullable = false)
  private long roleId; // Role 编号 {@link com.ctrip.framework.apollo.portal.entity.po.Role#id}

}
```

- 字段比较简单，胖友自己看注释。

# 3. ConsumerService

`com.ctrip.framework.apollo.openapi.service.ConsumerService` ，提供 Consumer、ConsumerToken、ConsumerAudit、ConsumerRole 相关的 **Service** 逻辑。

## 3.1 createConsumerRole

`#createConsumerRole(consumerId, roleId, operator)` 方法，创建 Consumer 对象。代码如下：

```java
ConsumerRole createConsumerRole(Long consumerId, Long roleId, String operator) {
    ConsumerRole consumerRole = new ConsumerRole();
    consumerRole.setConsumerId(consumerId);
    consumerRole.setRoleId(roleId);
    consumerRole.setDataChangeCreatedBy(operator);
    consumerRole.setDataChangeLastModifiedBy(operator);
    return consumerRole;
}
```

## 3.2 assignAppRoleToConsumer

`#assignAppRoleToConsumer(token, appId)` 方法，授权 App 的 Role 给 Consumer 。代码如下：

```java
@Transactional
public ConsumerRole assignAppRoleToConsumer(String token, String appId) {
  Long consumerId = getConsumerIdByToken(token); // 校验 Token 是否有对应的 Consumer 。若不存在，抛出 BadRequestException 异常
  if (consumerId == null) {
    throw new BadRequestException("Token is Illegal");
  }
  // 获得 App 对应的 Role 对象
  Role masterRole = rolePermissionService.findRoleByRoleName(RoleUtils.buildAppMasterRoleName(appId));
  if (masterRole == null) {
    throw new BadRequestException("App's role does not exist. Please check whether app has created.");
  }
  // 获得 Consumer 对应的 ConsumerRole 对象。若已存在，返回 ConsumerRole 对象
  long roleId = masterRole.getId();
  ConsumerRole managedModifyRole = consumerRoleRepository.findByConsumerIdAndRoleId(consumerId, roleId);
  if (managedModifyRole != null) {
    return managedModifyRole;
  }
  // 创建 Consumer 对应的 ConsumerRole 对象
  String operator = userInfoHolder.getUser().getUserId();
  ConsumerRole consumerRole = createConsumerRole(consumerId, roleId, operator);
  return consumerRoleRepository.save(consumerRole); // 保存 Consumer 对应的 ConsumerRole 对象
}
```

## 3.3 assignNamespaceRoleToConsumer

`#assignNamespaceRoleToConsumer(token, appId, namespaceName)` 方法，授权 Namespace 的 Role 给 Consumer 。对吗如下：

```java
@Transactional
public List<ConsumerRole> assignNamespaceRoleToConsumer(String token, String appId, String namespaceName, String env) {
  Long consumerId = getConsumerIdByToken(token);  // 校验 Token 是否有对应的 Consumer 。若不存在，抛出 BadRequestException 异常
  if (consumerId == null) {
    throw new BadRequestException("Token is Illegal");
  }
  // 获得 Namespace 对应的 Role 们。若有任一不存在，抛出 BadRequestException 异常
  Role namespaceModifyRole =
      rolePermissionService.findRoleByRoleName(RoleUtils.buildModifyNamespaceRoleName(appId, namespaceName, env));
  Role namespaceReleaseRole =
      rolePermissionService.findRoleByRoleName(RoleUtils.buildReleaseNamespaceRoleName(appId, namespaceName, env));

  if (namespaceModifyRole == null || namespaceReleaseRole == null) {
    throw new BadRequestException("Namespace's role does not exist. Please check whether namespace has created.");
  }

  long namespaceModifyRoleId = namespaceModifyRole.getId();
  long namespaceReleaseRoleId = namespaceReleaseRole.getId();
  // 获得 Consumer 对应的 ConsumerRole 们。若都存在，返回 ConsumerRole 数组
  ConsumerRole managedModifyRole = consumerRoleRepository.findByConsumerIdAndRoleId(consumerId, namespaceModifyRoleId);
  ConsumerRole managedReleaseRole = consumerRoleRepository.findByConsumerIdAndRoleId(consumerId, namespaceReleaseRoleId);
  if (managedModifyRole != null && managedReleaseRole != null) {
    return Arrays.asList(managedModifyRole, managedReleaseRole);
  }
  // 创建 Consumer 对应的 ConsumerRole 们
  String operator = userInfoHolder.getUser().getUserId();

  ConsumerRole namespaceModifyConsumerRole = createConsumerRole(consumerId, namespaceModifyRoleId, operator);
  ConsumerRole namespaceReleaseConsumerRole = createConsumerRole(consumerId, namespaceReleaseRoleId, operator);
  // 保存 Consumer 对应的 ConsumerRole 们到数据库中
  ConsumerRole createdModifyConsumerRole = consumerRoleRepository.save(namespaceModifyConsumerRole);
  ConsumerRole createdReleaseConsumerRole = consumerRoleRepository.save(namespaceReleaseConsumerRole);
  // 返回 ConsumerRole 数组
  return Arrays.asList(createdModifyConsumerRole, createdReleaseConsumerRole);
}
```

# 4. ConsumerRolePermissionService

`com.ctrip.framework.apollo.openapi.service.ConsumerRolePermissionService` ，ConsumerRole 权限**校验** Service 。代码如下：

```java
@Service
public class ConsumerRolePermissionService {
  private final PermissionRepository permissionRepository;
  private final ConsumerRoleRepository consumerRoleRepository;
  private final RolePermissionRepository rolePermissionRepository;

  public ConsumerRolePermissionService(
      final PermissionRepository permissionRepository,
      final ConsumerRoleRepository consumerRoleRepository,
      final RolePermissionRepository rolePermissionRepository) {
    this.permissionRepository = permissionRepository;
    this.consumerRoleRepository = consumerRoleRepository;
    this.rolePermissionRepository = rolePermissionRepository;
  }

  /**
   * Check whether user has the permission
   */
  public boolean consumerHasPermission(long consumerId, String permissionType, String targetId) {
    Permission permission =  // 获得 Permission 对象
        permissionRepository.findTopByPermissionTypeAndTargetId(permissionType, targetId);
    if (permission == null) { // 若 Permission 不存在，返回 false
      return false;
    }
    // 获得 ConsumerRole 数组
    List<ConsumerRole> consumerRoles = consumerRoleRepository.findByConsumerId(consumerId);
    if (CollectionUtils.isEmpty(consumerRoles)) { // 若数组为空，返回 false
      return false;
    }
    // 获得 RolePermission 数组
    Set<Long> roleIds =
        consumerRoles.stream().map(ConsumerRole::getRoleId).collect(Collectors.toSet());
    List<RolePermission> rolePermissions = rolePermissionRepository.findByRoleIdIn(roleIds);
    if (CollectionUtils.isEmpty(rolePermissions)) { // 若数组为空，返回 false
      return false;
    }
    // 判断是否有对应的 RolePermission 。若有，则返回 true 【有权限】
    for (RolePermission rolePermission : rolePermissions) {
      if (rolePermission.getPermissionId() == permission.getId()) {
        return true;
      }
    }

    return false;
  }
}
```

- 和 `DefaultRolePermissionService#userHasPermission(userId, permissionType, targetId)` 方法，**基本类似**。

# 5. ConsumerPermissionValidator

> ConsumerPermissionValidator 和 PermissionValidator **基本类似**。

`com.ctrip.framework.apollo.openapi.auth.ConsumerPermissionValidator` ，Consumer 权限校验器。代码如下：

```java
@Component
public class ConsumerPermissionValidator {

  private final ConsumerRolePermissionService permissionService;
  private final ConsumerAuthUtil consumerAuthUtil;

  public ConsumerPermissionValidator(final ConsumerRolePermissionService permissionService,
      final ConsumerAuthUtil consumerAuthUtil) {
    this.permissionService = permissionService;
    this.consumerAuthUtil = consumerAuthUtil;
  }

  public boolean hasModifyNamespacePermission(HttpServletRequest request, String appId,
      String namespaceName, String env) {
    if (hasCreateNamespacePermission(request, appId)) {
      return true;
    }
    return permissionService.consumerHasPermission(consumerAuthUtil.retrieveConsumerId(request),
        PermissionType.MODIFY_NAMESPACE, RoleUtils.buildNamespaceTargetId(appId, namespaceName))
        || permissionService.consumerHasPermission(consumerAuthUtil.retrieveConsumerId(request),
            PermissionType.MODIFY_NAMESPACE,
            RoleUtils.buildNamespaceTargetId(appId, namespaceName, env));

  }

  public boolean hasReleaseNamespacePermission(HttpServletRequest request, String appId,
      String namespaceName, String env) {
    if (hasCreateNamespacePermission(request, appId)) {
      return true;
    }
    return permissionService.consumerHasPermission(consumerAuthUtil.retrieveConsumerId(request),
        PermissionType.RELEASE_NAMESPACE, RoleUtils.buildNamespaceTargetId(appId, namespaceName))
        || permissionService.consumerHasPermission(consumerAuthUtil.retrieveConsumerId(request),
            PermissionType.RELEASE_NAMESPACE,
            RoleUtils.buildNamespaceTargetId(appId, namespaceName, env));

  }

  public boolean hasCreateNamespacePermission(HttpServletRequest request, String appId) {
    return permissionService.consumerHasPermission(consumerAuthUtil.retrieveConsumerId(request),
        PermissionType.CREATE_NAMESPACE, appId);
  }

  public boolean hasCreateClusterPermission(HttpServletRequest request, String appId) {
    return permissionService.consumerHasPermission(consumerAuthUtil.retrieveConsumerId(request),
        PermissionType.CREATE_CLUSTER, appId);
  }
}
```

在每个需要校验权限的方法上，添加 `@PreAuthorize` 注解，并在 `value` 属性上写 EL 表达式，调用 PermissionValidator 的校验方法。例如：

- 创建 Namespace 的方法，添加了 `@PreAuthorize(value = "@consumerPermissionValidator.hasCreateNamespacePermission(#request, #appId)")` 。
- 发布 Namespace 的方法，添加了 `@PreAuthorize(value = "@consumerPermissionValidator.hasReleaseNamespacePermission(#request, #appId, #namespaceName)")` 。

通过这样的方式，达到**功能 + 数据级**的权限控制。

# 6. ConsumerController

在 `apollo-portal` 项目中，`com.ctrip.framework.apollo.portal.controller.ConsumerController` ，提供 Consumer、ConsumerToken、ConsumerAudit 相关的 **API** 。

在**创建第三方应用**的界面中，点击【提交】按钮，调用**授权 Consumer 的 API** 。

![创建第三方应用](http://blog-1259650185.cosbj.myqcloud.com/img/202204/07/1649323774.png)

代码如下：

```java
@RestController
public class ConsumerController {

  private static final Date DEFAULT_EXPIRES = new GregorianCalendar(2099, Calendar.JANUARY, 1).getTime();

  private final ConsumerService consumerService;

  public ConsumerController(final ConsumerService consumerService) {
    this.consumerService = consumerService;
  }


  @Transactional
  @PreAuthorize(value = "@permissionValidator.isSuperAdmin()")
  @PostMapping(value = "/consumers")
  public ConsumerToken createConsumer(@RequestBody Consumer consumer,
                                      @RequestParam(value = "expires", required = false)
                                      @DateTimeFormat(pattern = "yyyyMMddHHmmss") Date
                                          expires) {
    // 校验非空
    if (StringUtils.isContainEmpty(consumer.getAppId(), consumer.getName(),
                                   consumer.getOwnerName(), consumer.getOrgId())) {
      throw new BadRequestException("Params(appId、name、ownerName、orgId) can not be empty.");
    }
    // 创建 Consumer 对象，并保存到数据库中
    Consumer createdConsumer = consumerService.createConsumer(consumer);
    // 创建 ConsumerToken 对象，并保存到数据库中
    if (Objects.isNull(expires)) {
      expires = DEFAULT_EXPIRES;
    }

    return consumerService.generateAndSaveConsumerToken(createdConsumer, expires);
  }

  @GetMapping(value = "/consumers/by-appId")
  public ConsumerToken getConsumerTokenByAppId(@RequestParam String appId) {
    return consumerService.getConsumerTokenByAppId(appId);
  }

  @PreAuthorize(value = "@permissionValidator.isSuperAdmin()")
  @PostMapping(value = "/consumers/{token}/assign-role")
  public List<ConsumerRole> assignNamespaceRoleToConsumer(@PathVariable String token,
                                                          @RequestParam String type,
                                                          @RequestParam(required = false) String envs,
                                                          @RequestBody NamespaceDTO namespace) {

    String appId = namespace.getAppId();
    String namespaceName = namespace.getNamespaceName();
    // 校验 appId 非空。若为空，抛出 BadRequestException 异常
    if (StringUtils.isEmpty(appId)) {
      throw new BadRequestException("Params(AppId) can not be empty.");
    }
    if (Objects.equals("AppRole", type)) { // 授权 App 的 Role 给 Consumer
      return Collections.singletonList(consumerService.assignAppRoleToConsumer(token, appId));
    }
    if (StringUtils.isEmpty(namespaceName)) {
      throw new BadRequestException("Params(NamespaceName) can not be empty.");
    }
    if (null != envs){
      String[] envArray = envs.split(",");
      List<String> envList = Lists.newArrayList();
      // validate env parameter
      for (String env : envArray) {
        if (Strings.isNullOrEmpty(env)) {
          continue;
        }
        if (Env.UNKNOWN.equals(Env.transformEnv(env))) {
          throw new BadRequestException(String.format("env: %s is illegal", env));
        }
        envList.add(env);
      }
      // 授权 Namespace 的 Role 给 Consumer
      List<ConsumerRole> consumeRoles = new ArrayList<>();
      for (String env : envList) {
        consumeRoles.addAll(consumerService.assignNamespaceRoleToConsumer(token, appId, namespaceName, env));
      }
      return consumeRoles;
    }

    return consumerService.assignNamespaceRoleToConsumer(token, appId, namespaceName);
  }

}
```

OpenAPI 在 `v1/controller` 中，实现了自己的 API ，**共享**调用 Portal 中的 Service 。如下图所示：

<img src="http://blog-1259650185.cosbj.myqcloud.com/img/202204/07/1649323907.png" alt="OpenAPI Controller" style="zoom:50%;" />



# 参考

[Apollo 源码解析 —— OpenAPI 认证与授权（二）之授权](https://www.iocoder.cn/Apollo/openapi-auth-2/)
