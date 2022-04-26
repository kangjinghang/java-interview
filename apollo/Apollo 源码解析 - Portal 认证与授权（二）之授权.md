# 1. 概述

> 老艿艿：本系列假定胖友已经阅读过 [《Apollo 官方 wiki 文档》](https://github.com/ctripcorp/apollo/wiki/) ，特别是 [《Portal 实现用户登录功能》](https://github.com/ctripcorp/apollo/wiki/Portal-实现用户登录功能) 。

本文接 [《Apollo 源码解析 —— Portal 认证与授权（一）之认证》](http://www.iocoder.cn/Apollo/portal-auth-1/?self) ，**侧重在授权部分**。在上一文中，我们提到：

> 具体**每个** URL 的权限校验，通过在对应的方法上，添加 `@PreAuthorize` 方法注解，配合具体的方法参数，一起校验**功能 + 数据级**的权限校验。

# 2. 权限模型

常见的权限模型，有两种：RBAC 和 ACL 。如果不了解的胖友，可以看下 [《基于AOP实现权限管理：访问控制模型 RBAC 和 ACL 》](https://blog.csdn.net/tch918/article/details/18449043) 。

笔者一开始看到 Role + UserRole + Permission + RolePermission 四张表，认为是 **RBAC** 权限模型。但是看了 Permission 的数据结构，以及 PermissionValidator 的权限判断方式，又感受到几分 **ACL** 权限模型的味道。

所以，很难完全说，Apollo 属于 RBAC 还是 ACL 权限模型。或者说，权限模型，本身会根据实际业务场景的业务需要，做一些变种和改造。权限模型，提供给我们的是指导和借鉴，不需要过于拘泥。

关系如下图：

![关系](http://blog-1259650185.cosbj.myqcloud.com/img/202204/07/1649262350.png)

## 2.1 Role

**Role** 表，角色表，对应实体 `com.ctrip.framework.apollo.portal.entity.po.Role` ，代码如下：

```java
@Entity
@Table(name = "Role")
@SQLDelete(sql = "Update Role set IsDeleted = 1, DeletedAt = ROUND(UNIX_TIMESTAMP(NOW(4))*1000) where Id = ?")
@Where(clause = "isDeleted = 0")
public class Role extends BaseEntity {
  @Column(name = "RoleName", nullable = false)
  private String roleName; // 角色名

  // ... 省略其他接口和属性
}
```

- `roleName`字段，**角色名**，通过系统**自动生成**。目前有**三种类型**( 不是三个 )角色：
  - App 管理员，格式为 `"Master + AppId"` ，例如：`"Master+100004458"` 。
  - Namespace **修改**管理员，格式为 `"ModifyNamespace + AppId + NamespaceName"` ，例如：`"ModifyNamespace+100004458+application"` 。
  - Namespace **发布**管理员，格式为 `"ReleaseNamespace + AppId + NamespaceName"` ，例如：`"ReleaseNamespace+100004458+application"` 。
- 例子如下图：![例子](http://blog-1259650185.cosbj.myqcloud.com/img/202204/07/1649262407.png)

## 2.2 UserRole

## 2.2 UserRole

**UserRole** 表，用户与角色的**关联**表，对应实体 `com.ctrip.framework.apollo.portal.entity.po.UserRole` ，代码如下：

```java
@Entity
@Table(name = "UserRole")
@SQLDelete(sql = "Update UserRole set IsDeleted = 1, DeletedAt = ROUND(UNIX_TIMESTAMP(NOW(4))*1000) where Id = ?")
@Where(clause = "isDeleted = 0")
public class UserRole extends BaseEntity {
  @Column(name = "UserId", nullable = false)
  private String userId; // 账号 {@link UserPO#username}

  @Column(name = "RoleId", nullable = false)
  private long roleId; // 角色编号 {@link Role#id}

  // ... 省略其他接口和属性
}
```

- `userId` 字段，用户编号，指向对应的 User 。目前使用 `UserPO.username` 。当然，我们自己的业务系统里，推荐使用 `UserPO.id` 。
- `roleId` 字段，角色编号，指向对应的 Role 。
- 例子如下图：![例子](http://blog-1259650185.cosbj.myqcloud.com/img/202204/07/1649262566.png)

## 2.3 Permission

**Permission** 表，权限表，对应实体 `com.ctrip.framework.apollo.portal.entity.po.Permission` ，代码如下：

```java
@Entity
@Table(name = "Permission")
@SQLDelete(sql = "Update Permission set IsDeleted = 1, DeletedAt = ROUND(UNIX_TIMESTAMP(NOW(4))*1000) where Id = ?")
@Where(clause = "isDeleted = 0")
public class Permission extends BaseEntity {
  @Column(name = "PermissionType", nullable = false)
  private String permissionType; // 权限类型

  @Column(name = "TargetId", nullable = false)
  private String targetId; // 目标编号

  // ... 省略其他接口和属性
}
```

- `permissionType` 字段，权限类型。在 `com.ctrip.framework.apollo.portal.constant.PermissionType` 中枚举，代码如下：

  ```java
  public interface PermissionType {
  
    /**
     * system level permission
     */
    String CREATE_APPLICATION = "CreateApplication"; // 创建 Application
    String MANAGE_APP_MASTER = "ManageAppMaster"; // 管理 Application
  
    /**
     * APP level permission
     */
    // 创建 Namespace
    String CREATE_NAMESPACE = "CreateNamespace";
    // 创建 Cluster
    String CREATE_CLUSTER = "CreateCluster";
  
    /**
     * 分配用户权限的权限
     */
    String ASSIGN_ROLE = "AssignRole";
  
    /**
     * namespace level permission
     */
    // 修改 Namespace
    String MODIFY_NAMESPACE = "ModifyNamespace";
    // 发布 Namespace
    String RELEASE_NAMESPACE = "ReleaseNamespace";
  
  
  }
  ```

  - 分成System、 App 和 Namespace **三种**级别的权限类型。

- `targetId` 字段，目标编号。

- 例子如下图：

  ![image-20220407003313690](http://blog-1259650185.cosbj.myqcloud.com/img/202204/07/1649262793.png)

  - **App** 级别时，`targetId` 指向 “**App 编号**“。
  - **Namespace** 级别时，`targetId`指向 “**App 编号+Namespace 名字**“。
    - **为什么**不是 Namespace 的编号？ **Namespace** 级别，是所有环境 + 所有集群都有权限，所以不能具体某个 Namespace 。

## 2.4 RolePermission

**RolePermission** 表，角色与权限的**关联**表，对应实体 `com.ctrip.framework.apollo.portal.entity.po.RolePermission` ，代码如下：

```java
@Entity
@Table(name = "RolePermission")
@SQLDelete(sql = "Update RolePermission set IsDeleted = 1, DeletedAt = ROUND(UNIX_TIMESTAMP(NOW(4))*1000) where Id = ?")
@Where(clause = "isDeleted = 0")
public class RolePermission extends BaseEntity {
  @Column(name = "RoleId", nullable = false)
  private long roleId; //  角色编号 {@link Role#id}

  @Column(name = "PermissionId", nullable = false)
  private long permissionId; // 权限编号 {@link Permission#id}
  
  // ... 省略其他接口和属性
}
```

- `roleId` 字段，角色编号，指向对应的 Role 。
- `permissionId` 字段，权限编号，指向对应的 Permission 。
- 例子如下图：![例子](http://blog-1259650185.cosbj.myqcloud.com/img/202204/07/1649262979.png)

# 3. RolePermissionService

`com.ctrip.framework.apollo.portal.service.RolePermissionService` ，提供 Role、UserRole、Permission、UserPermission 相关的操作。代码如下：

```java
public interface RolePermissionService {

  /**
   * Create role with permissions, note that role name should be unique
   */
  Role createRoleWithPermissions(Role role, Set<Long> permissionIds);

  /**
   * Assign role to users
   *
   * @return the users assigned roles
   */
  Set<String> assignRoleToUsers(String roleName, Set<String> userIds,
      String operatorUserId);

  /**
   * Remove role from users
   */
  void removeRoleFromUsers(String roleName, Set<String> userIds, String operatorUserId);

  /**
   * Query users with role
   */
  Set<UserInfo> queryUsersWithRole(String roleName);

  /**
   * Find role by role name, note that roleName should be unique
   */
  Role findRoleByRoleName(String roleName);

  /**
   * Check whether user has the permission
   */
  boolean userHasPermission(String userId, String permissionType, String targetId);

  /**
   * Find the user's roles
   */
  List<Role> findUserRoles(String userId);

  boolean isSuperAdmin(String userId);

  /**
   * Create permission, note that permissionType + targetId should be unique
   */
  Permission createPermission(Permission permission);

  /**
   * Create permissions, note that permissionType + targetId should be unique
   */
  Set<Permission> createPermissions(Set<Permission> permissions);

  /**
   * delete permissions when delete app.
   */
  void deleteRolePermissionsByAppId(String appId, String operator);

  /**
   * delete permissions when delete app namespace.
   */
  void deleteRolePermissionsByAppIdAndNamespace(String appId, String namespaceName, String operator);
}
```

## 3.1 DefaultRolePermissionService

`com.ctrip.framework.apollo.portal.spi.defaultimpl.DefaultRolePermissionService` ，实现 RolePermissionService 接口，默认 RolePermissionService 实现类。

> 老艿艿：下面的方法比较易懂，胖友看着代码注释理解。

### 3.1.1 createRoleWithPermissions

```java
@Transactional
public Role createRoleWithPermissions(Role role, Set<Long> permissionIds) {
    Role current = findRoleByRoleName(role.getRoleName()); // 获得 Role 对象，校验 Role 不存在
    Preconditions.checkState(current == null, "Role %s already exists!", role.getRoleName());
    // 新增 Role
    Role createdRole = roleRepository.save(role);
    // 授权给 Role
    if (!CollectionUtils.isEmpty(permissionIds)) {
        Iterable<RolePermission> rolePermissions = permissionIds.stream().map(permissionId -> {
            RolePermission rolePermission = new RolePermission();
            rolePermission.setRoleId(createdRole.getId()); // Role 编号
            rolePermission.setPermissionId(permissionId);
            rolePermission.setDataChangeCreatedBy(createdRole.getDataChangeCreatedBy());
            rolePermission.setDataChangeLastModifiedBy(createdRole.getDataChangeLastModifiedBy());
            return rolePermission;
        }).collect(Collectors.toList());  // 创建 RolePermission 数组
        rolePermissionRepository.saveAll(rolePermissions); // 保存 RolePermission 数组
    }

    return createdRole;
}
```

### 3.1.2 assignRoleToUsers

```java
@Transactional
public Set<String> assignRoleToUsers(String roleName, Set<String> userIds,
                                     String operatorUserId) {
    Role role = findRoleByRoleName(roleName); // 获得 Role 对象，校验 Role 存在
    Preconditions.checkState(role != null, "Role %s doesn't exist!", roleName);
    // 获得已存在的 UserRole 数组
    List<UserRole> existedUserRoles =
            userRoleRepository.findByUserIdInAndRoleId(userIds, role.getId());
    Set<String> existedUserIds =
        existedUserRoles.stream().map(UserRole::getUserId).collect(Collectors.toSet());
    // 创建需要新增的 UserRole 数组
    Set<String> toAssignUserIds = Sets.difference(userIds, existedUserIds);
    // 创建需要新增的 UserRole 数组
    Iterable<UserRole> toCreate = toAssignUserIds.stream().map(userId -> {
        UserRole userRole = new UserRole();
        userRole.setRoleId(role.getId());
        userRole.setUserId(userId);
        userRole.setDataChangeCreatedBy(operatorUserId);
        userRole.setDataChangeLastModifiedBy(operatorUserId);
        return userRole;
    }).collect(Collectors.toList());
    // 保存 RolePermission 数组
    userRoleRepository.saveAll(toCreate);
    return toAssignUserIds;
}
```

### 3.1.3 removeRoleFromUsers

```java
@Transactional
public void removeRoleFromUsers(String roleName, Set<String> userIds, String operatorUserId) {
    Role role = findRoleByRoleName(roleName); // 获得 Role 对象，校验 Role 存在
    Preconditions.checkState(role != null, "Role %s doesn't exist!", roleName);
    // 获得已存在的 UserRole 数组
    List<UserRole> existedUserRoles =
            userRoleRepository.findByUserIdInAndRoleId(userIds, role.getId());
    // 标记删除
    for (UserRole userRole : existedUserRoles) {
        userRole.setDeleted(true);
        userRole.setDataChangeLastModifiedTime(new Date());
        userRole.setDataChangeLastModifiedBy(operatorUserId);
    }
    // 保存 RolePermission 数组 【标记删除】
    userRoleRepository.saveAll(existedUserRoles);
}
```

### 3.1.4 queryUsersWithRole

```java
public Set<UserInfo> queryUsersWithRole(String roleName) {
    Role role = findRoleByRoleName(roleName); // 获得 Role 对象，校验 Role 存在

    if (role == null) {  // Role 不存在时，返回空数组
        return Collections.emptySet();
    }
    // 获得 UserRole 数组
    List<UserRole> userRoles = userRoleRepository.findByRoleId(role.getId());
    // 转换成 UserInfo 数组
    return userRoles.stream().map(userRole -> {
        UserInfo userInfo = new UserInfo();
        userInfo.setUserId(userRole.getUserId());
        return userInfo;
    }).collect(Collectors.toSet());
}
```

### 3.1.5 findRoleByRoleName

```java
public Role findRoleByRoleName(String roleName) {
    return roleRepository.findTopByRoleName(roleName);
}
```

### 3.1.6 userHasPermission 【重要】

```java
public boolean userHasPermission(String userId, String permissionType, String targetId) {
    Permission permission =  // 获得 Permission 对象
            permissionRepository.findTopByPermissionTypeAndTargetId(permissionType, targetId);
    if (permission == null) { // 若 Permission 不存在，返回 false
        return false;
    }
    // 若是超级管理员，返回 true 【有权限】
    if (isSuperAdmin(userId)) {
        return true;
    }
    // 获得 UserRole 数组
    List<UserRole> userRoles = userRoleRepository.findByUserId(userId);
    if (CollectionUtils.isEmpty(userRoles)) {  // 若数组为空，返回 false
        return false;
    }
    // 获得 RolePermission 数组
    Set<Long> roleIds =
        userRoles.stream().map(UserRole::getRoleId).collect(Collectors.toSet());
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
```

- 从目前的代码看下来，这个权限判断的过程，是 **ACL** 的方式。
- 如果是 **RBAC** 的方式，获得 Permission 后，再获得 Permission 对应的 RolePermission 数组，最后和 User 对应的 UserRole 数组，求 `roleId` 是否相交。

### 3.1.7 isSuperAdmin

```java
public boolean isSuperAdmin(String userId) {
    return portalConfig.superAdmins().contains(userId);
}
```

- 通过 ServerConfig 的 `"superAdmin"` 配置项，判断是否存在该账号。

### 3.1.8 createPermission

```java
@Transactional
public Permission createPermission(Permission permission) {
    String permissionType = permission.getPermissionType();
    String targetId = permission.getTargetId();
    Permission current = // 获得 Permission 对象，校验 Permission 为空
            permissionRepository.findTopByPermissionTypeAndTargetId(permissionType, targetId);
    Preconditions.checkState(current == null,
            "Permission with permissionType %s targetId %s already exists!", permissionType, targetId);
    // 保存 Permission
    return permissionRepository.save(permission);
}
```

### 3.1.9 createPermissions

```java
@Transactional
public Set<Permission> createPermissions(Set<Permission> permissions) {
    Multimap<String, String> targetIdPermissionTypes = HashMultimap.create();  // 创建 Multimap 对象，用于下面校验的分批的批量查询
    for (Permission permission : permissions) {
        targetIdPermissionTypes.put(permission.getTargetId(), permission.getPermissionType());
    }
    // 查询 Permission 集合，校验都不存在
    for (String targetId : targetIdPermissionTypes.keySet()) {
        Collection<String> permissionTypes = targetIdPermissionTypes.get(targetId);
        List<Permission> current =
                permissionRepository.findByPermissionTypeInAndTargetId(permissionTypes, targetId);
        Preconditions.checkState(CollectionUtils.isEmpty(current),
                "Permission with permissionType %s targetId %s already exists!", permissionTypes,
                targetId);
    }
    // 保存 Permission 集合
    Iterable<Permission> results = permissionRepository.saveAll(permissions);
    return StreamSupport.stream(results.spliterator(), false).collect(Collectors.toSet());  // 转成 Permission 集合，返回
}
```

# 4. RoleInitializationService

`com.ctrip.framework.apollo.portal.service.RoleInitializationService` ，提供角色初始化相关的操作。代码如下：

```java
public interface RoleInitializationService {
  // 初始化 App 级的 Role
  void initAppRoles(App app);
  // 初始化 Namespace 级的 Role
  void initNamespaceRoles(String appId, String namespaceName, String operator);

  void initNamespaceEnvRoles(String appId, String namespaceName, String operator);

  void initNamespaceSpecificEnvRoles(String appId, String namespaceName, String env,
      String operator);

  void initCreateAppRole();

  void initManageAppMasterRole(String appId, String operator);

}
```

## 4.1 DefaultRoleInitializationService

`com.ctrip.framework.apollo.portal.spi.defaultimpl.DefaultRoleInitializationService` ，实现 RoleInitializationService 接口，默认 RoleInitializationService 实现类。

### 4.1.1 initAppRoles

```java
@Transactional
public void initAppRoles(App app) {
  String appId = app.getAppId();
  // 创建 App 拥有者的角色名
  String appMasterRoleName = RoleUtils.buildAppMasterRoleName(appId);

  //has created before // 校验角色是否已经存在。若是，直接返回
  if (rolePermissionService.findRoleByRoleName(appMasterRoleName) != null) {
    return;
  }
  String operator = app.getDataChangeCreatedBy();
  //create app permissions // 创建 App 角色
  createAppMasterRole(appId, operator);
  //create manageAppMaster permission
  createManageAppMasterRole(appId, operator);

  //assign master role to user // 授权 Role 给 App 拥有者
  rolePermissionService
      .assignRoleToUsers(RoleUtils.buildAppMasterRoleName(appId), Sets.newHashSet(app.getOwnerName()),
          operator);
  // 初始化 Namespace 角色
  initNamespaceRoles(appId, ConfigConsts.NAMESPACE_APPLICATION, operator);
  initNamespaceEnvRoles(appId, ConfigConsts.NAMESPACE_APPLICATION, operator);
  // 授权 Role 给 App 创建者
  //assign modify、release namespace role to user
  rolePermissionService.assignRoleToUsers(
      RoleUtils.buildNamespaceRoleName(appId, ConfigConsts.NAMESPACE_APPLICATION, RoleType.MODIFY_NAMESPACE),
      Sets.newHashSet(operator), operator);
  rolePermissionService.assignRoleToUsers(
      RoleUtils.buildNamespaceRoleName(appId, ConfigConsts.NAMESPACE_APPLICATION, RoleType.RELEASE_NAMESPACE),
      Sets.newHashSet(operator), operator);

}
```

- 在 Portal 创建完**本地** App 后，自动初始化对应的 Role 们。调用如下图：![createLocalApp](https://static.iocoder.cn/images/Apollo/2018_06_05/06.png)

- =========== 初始化 App 级的 Role ===========

- 第 7 行：调用 `RoleUtils#buildAppMasterRoleName(appId)` 方法，创建 App **拥有者**的角色名。代码如下：

  ```java
  // RoleUtils.java
  private static final Joiner STRING_JOINER = Joiner.on(ConfigConsts.CLUSTER_NAMESPACE_SEPARATOR);
  
  public static String buildAppMasterRoleName(String appId) {
      return STRING_JOINER.join(RoleType.MASTER, appId);
  }
  
  // RoleType.java
  public static final String MASTER = "Master";
  ```

- 第 9 至 12 行：调用 `RolePermissionService#findRoleByRoleName(appMasterRoleName)` 方法，**校验**角色是否已经存在。若是，直接返回。

- 第 16 行：调用 `#createAppMasterRole(appId, operator)` 方法，创建 App **拥有者**角色。代码如下：

  ```java
  private void createAppMasterRole(String appId, String operator) {
      // 创建 App 对应的 Permission 集合，并保存到数据库
      Set<Permission> appPermissions = Lists.newArrayList(PermissionType.CREATE_CLUSTER, PermissionType.CREATE_NAMESPACE, PermissionType.ASSIGN_ROLE)
              .stream().map(permissionType -> createPermission(appId, permissionType, operator) /* 创建 Permission 对象 */ ).collect(Collectors.toSet());
      Set<Permission> createdAppPermissions = rolePermissionService.createPermissions(appPermissions);
      Set<Long> appPermissionIds = createdAppPermissions.stream().map(BaseEntity::getId).collect(Collectors.toSet());
  
      // 创建 App 对应的 Role 对象，并保存到数据库
      // create app master role
      Role appMasterRole = createRole(RoleUtils.buildAppMasterRoleName(appId), operator);
      rolePermissionService.createRoleWithPermissions(appMasterRole, appPermissionIds);
  }
  ```

  - 创建并保存 App 对应的 Permission 集合。`#createPermission(targetId, permissionType, operator)` 方法，创建 Permission 对象。代码如下：

    ```java
    private Permission createPermission(String targetId, String permissionType, String operator) {
        Permission permission = new Permission();
        permission.setPermissionType(permissionType);
        permission.setTargetId(targetId);
        permission.setDataChangeCreatedBy(operator);
        permission.setDataChangeLastModifiedBy(operator);
        return permission;
    }
    ```

  - 创建并保存 App 对应的 Role 对象，并授权对应的 Permission 集合。`#createRole(roleName, operator)` 方法，创建 Role 对象。代码如下：

    ```java
    private Role createRole(String roleName, String operator) {
        Role role = new Role();
        role.setRoleName(roleName);
        role.setDataChangeCreatedBy(operator);
        role.setDataChangeLastModifiedBy(operator);
        return role;
    }
    ```

- 第 19 行：调用 `rolePermissionService.assignRoleToUsers(roleName, userIds, operatorUserId)` 方法，授权 Role 给 App **拥有者**。

- =========== 初始化 Namespace 级的 Role ===========

- 第 22 行：调用 `#initNamespaceRoles(appId, namespaceName, operator)` 方法，初始化 Namespace 的角色。详细解析，见 [「4.2 initNamespaceRoles」](https://www.iocoder.cn/Apollo/portal-auth-2/#) 。

- 第 23 至 26 行：调用 `rolePermissionService.assignRoleToUsers(roleName, userIds, operatorUserId)` 方法，授权 Role 给 App **创建者**。**注意**，此处不是“拥有者”噢。为什么？因为，Namespace 是自动创建的，并且是通过**创建人**来操作的。

### 4.1.2 initNamespaceRoles

```java
@Override
@Transactional
public void initNamespaceRoles(String appId, String namespaceName, String operator) {
    // 创建 Namespace 修改的角色名
    String modifyNamespaceRoleName = RoleUtils.buildModifyNamespaceRoleName(appId, namespaceName);
    // 若不存在对应的 Role ，进行创建
    if (rolePermissionService.findRoleByRoleName(modifyNamespaceRoleName) == null) {
        createNamespaceRole(appId, namespaceName, PermissionType.MODIFY_NAMESPACE, RoleUtils.buildModifyNamespaceRoleName(appId, namespaceName), operator);
    }

    // 创建 Namespace 发布的角色名
    String releaseNamespaceRoleName = RoleUtils.buildReleaseNamespaceRoleName(appId, namespaceName);
    // 若不存在对应的 Role ，进行创建
    if (rolePermissionService.findRoleByRoleName(releaseNamespaceRoleName) == null) {
        createNamespaceRole(appId, namespaceName, PermissionType.RELEASE_NAMESPACE,
                RoleUtils.buildReleaseNamespaceRoleName(appId, namespaceName), operator);
    }
}
```

- 在 Portal 创建完 Namespace 后，自动初始化对应的 Role 们。调用如下图：![调用方](https://static.iocoder.cn/images/Apollo/2018_06_05/07.png)

- 创建并保存 Namespace **修改**和**发布**对应的 Role 。

- `RoleUtils#buildModifyNamespaceRoleName(appId, namespaceName)` 方法，创建 Namespace **修改**的角色名。代码如下：

  ```java
  // RoleUtils.java
  public static String buildModifyNamespaceRoleName(String appId, String namespaceName) {
      return STRING_JOINER.join(RoleType.MODIFY_NAMESPACE, appId, namespaceName);
  }
  
  // RoleType.java
  public static final String MODIFY_NAMESPACE = "ModifyNamespace";
  ```

- `RoleUtils#buildReleaseNamespaceRoleName(appId, namespaceName)` 方法，创建 Namespace **发布**的角色名。代码如下：

  ```java
  // RoleUtils.java
  public static String buildReleaseNamespaceRoleName(String appId, String namespaceName) {
      return STRING_JOINER.join(RoleType.RELEASE_NAMESPACE, appId, namespaceName);
  }
  
  // RoleType.java
  public static final String RELEASE_NAMESPACE = "ReleaseNamespace";
  ```

- `#createNamespaceRole(...)` 方法，创建 Namespace 的角色。代码如下：

  ```java
  private void createNamespaceRole(String appId, String namespaceName, String permissionType,
                                   String roleName, String operator) {
      // 创建 Namespace 对应的 Permission 对象，并保存到数据库
      Permission permission = createPermission(RoleUtils.buildNamespaceTargetId(appId, namespaceName), permissionType, operator);
      Permission createdPermission = rolePermissionService.createPermission(permission);
  
      // 创建 Namespace 对应的 Role 对象，并保存到数据库
      Role role = createRole(roleName, operator);
      rolePermissionService.createRoleWithPermissions(role, Sets.newHashSet(createdPermission.getId()));
  }
  ```

  - 创建并保存 Namespace 对应的 Permission 对象。

  - 创建并保存 Namespace 对应的 Role 对象，并授权对应的 Permission 。

  - `RoleUtils#buildNamespaceTargetId(appId, namespaceName)` 方法，创建 Namespace 的目标编号。代码如下：

    ```java
    public static String buildNamespaceTargetId(String appId, String namespaceName) {
        return STRING_JOINER.join(appId, namespaceName);
    }
    ```

# 5. PermissionValidator

`com.ctrip.framework.apollo.portal.component.PermissionValidator` ，权限校验器。代码如下：

```java
@Component("permissionValidator")
public class PermissionValidator {

  private final UserInfoHolder userInfoHolder;
  private final RolePermissionService rolePermissionService;
  private final PortalConfig portalConfig;
  private final AppNamespaceService appNamespaceService;
  private final SystemRoleManagerService systemRoleManagerService;

  @Autowired
  public PermissionValidator(
          final UserInfoHolder userInfoHolder,
          final RolePermissionService rolePermissionService,
          final PortalConfig portalConfig,
          final AppNamespaceService appNamespaceService,
          final SystemRoleManagerService systemRoleManagerService) {
    this.userInfoHolder = userInfoHolder;
    this.rolePermissionService = rolePermissionService;
    this.portalConfig = portalConfig;
    this.appNamespaceService = appNamespaceService;
    this.systemRoleManagerService = systemRoleManagerService;
  }
  // ========== Namespace 级别 ==========
  public boolean hasModifyNamespacePermission(String appId, String namespaceName) {
    return rolePermissionService.userHasPermission(userInfoHolder.getUser().getUserId(),
        PermissionType.MODIFY_NAMESPACE,
        RoleUtils.buildNamespaceTargetId(appId, namespaceName));
  }

  public boolean hasModifyNamespacePermission(String appId, String namespaceName, String env) {
    return hasModifyNamespacePermission(appId, namespaceName) ||
        rolePermissionService.userHasPermission(userInfoHolder.getUser().getUserId(),
            PermissionType.MODIFY_NAMESPACE, RoleUtils.buildNamespaceTargetId(appId, namespaceName, env));
  }

  public boolean hasReleaseNamespacePermission(String appId, String namespaceName) {
    return rolePermissionService.userHasPermission(userInfoHolder.getUser().getUserId(),
        PermissionType.RELEASE_NAMESPACE,
        RoleUtils.buildNamespaceTargetId(appId, namespaceName));
  }

  public boolean hasReleaseNamespacePermission(String appId, String namespaceName, String env) {
    return hasReleaseNamespacePermission(appId, namespaceName) ||
        rolePermissionService.userHasPermission(userInfoHolder.getUser().getUserId(),
        PermissionType.RELEASE_NAMESPACE, RoleUtils.buildNamespaceTargetId(appId, namespaceName, env));
  }

  public boolean hasDeleteNamespacePermission(String appId) {
    return hasAssignRolePermission(appId) || isSuperAdmin();
  }

  public boolean hasOperateNamespacePermission(String appId, String namespaceName) {
    return hasModifyNamespacePermission(appId, namespaceName) || hasReleaseNamespacePermission(appId, namespaceName);
  }

  public boolean hasOperateNamespacePermission(String appId, String namespaceName, String env) {
    return hasOperateNamespacePermission(appId, namespaceName) ||
        hasModifyNamespacePermission(appId, namespaceName, env) ||
        hasReleaseNamespacePermission(appId, namespaceName, env);
  }
  // ========== App 级别 ==========
  public boolean hasAssignRolePermission(String appId) {
    return rolePermissionService.userHasPermission(userInfoHolder.getUser().getUserId(),
        PermissionType.ASSIGN_ROLE,
        appId);
  }

  public boolean hasCreateNamespacePermission(String appId) {

    return rolePermissionService.userHasPermission(userInfoHolder.getUser().getUserId(),
        PermissionType.CREATE_NAMESPACE,
        appId);
  }

  public boolean hasCreateAppNamespacePermission(String appId, AppNamespace appNamespace) {

    boolean isPublicAppNamespace = appNamespace.isPublic();
    // 若满足如下任一条件： 1. 公开类型的 AppNamespace 。2. 私有类型的 AppNamespace ，并且允许 App 管理员创建私有类型的 AppNamespace 。
    if (portalConfig.canAppAdminCreatePrivateNamespace() || isPublicAppNamespace) {
      return hasCreateNamespacePermission(appId);
    }

    return isSuperAdmin();  // 超管
  }

  public boolean hasCreateClusterPermission(String appId) {
    return rolePermissionService.userHasPermission(userInfoHolder.getUser().getUserId(),
        PermissionType.CREATE_CLUSTER,
        appId);
  }

  public boolean isAppAdmin(String appId) {
    return isSuperAdmin() || hasAssignRolePermission(appId);
  }
  // ========== 超管 级别 ==========
  public boolean isSuperAdmin() {
    return rolePermissionService.isSuperAdmin(userInfoHolder.getUser().getUserId());
  }

  public boolean shouldHideConfigToCurrentUser(String appId, String env, String namespaceName) {
    // 1. check whether the current environment enables member only function
    if (!portalConfig.isConfigViewMemberOnly(env)) {
      return false;
    }

    // 2. public namespace is open to every one
    AppNamespace appNamespace = appNamespaceService.findByAppIdAndName(appId, namespaceName);
    if (appNamespace != null && appNamespace.isPublic()) {
      return false;
    }

    // 3. check app admin and operate permissions
    return !isAppAdmin(appId) && !hasOperateNamespacePermission(appId, namespaceName, env);
  }

  public boolean hasCreateApplicationPermission() {
    return hasCreateApplicationPermission(userInfoHolder.getUser().getUserId());
  }

  public boolean hasCreateApplicationPermission(String userId) {
    return systemRoleManagerService.hasCreateApplicationPermission(userId);
  }

  public boolean hasManageAppMasterPermission(String appId) {
    // the manage app master permission might not be initialized, so we need to check isSuperAdmin first
    return isSuperAdmin() ||
        (hasAssignRolePermission(appId) &&
         systemRoleManagerService.hasManageAppMasterPermission(userInfoHolder.getUser().getUserId(), appId)
        );
  }
}
```

在每个需要校验权限的方法上，添加 `@PreAuthorize` 注解，并在 `value` 属性上写 EL 表达式，调用 PermissionValidator 的校验方法。例如：

- 创建 Namespace 的方法，添加了 `@PreAuthorize(value = "@permissionValidator.hasCreateNamespacePermission(#appId)")` 。
- 删除 Namespace 的方法，添加了 `@PreAuthorize(value = "@permissionValidator.hasDeleteNamespacePermission(#appId)")` 。

通过这样的方式，达到**功能 + 数据级**的权限控制。

# 6. PermissionController

`com.ctrip.framework.apollo.portal.controller.PermissionController` ，提供**权限相关**的 **API** 。如下图所示：

```java
@RestController
public class PermissionController {

  private final UserInfoHolder userInfoHolder;
  private final RolePermissionService rolePermissionService;
  private final UserService userService;
  private final RoleInitializationService roleInitializationService;
  private final SystemRoleManagerService systemRoleManagerService;
  private final PermissionValidator permissionValidator;

  @Autowired
  public PermissionController(
          final UserInfoHolder userInfoHolder,
          final RolePermissionService rolePermissionService,
          final UserService userService,
          final RoleInitializationService roleInitializationService,
          final SystemRoleManagerService systemRoleManagerService,
          final PermissionValidator permissionValidator) {
    this.userInfoHolder = userInfoHolder;
    this.rolePermissionService = rolePermissionService;
    this.userService = userService;
    this.roleInitializationService = roleInitializationService;
    this.systemRoleManagerService = systemRoleManagerService;
    this.permissionValidator = permissionValidator;
  }

  @PostMapping("/apps/{appId}/initPermission")
  public ResponseEntity<Void> initAppPermission(@PathVariable String appId, @RequestBody String namespaceName) {
    roleInitializationService.initNamespaceEnvRoles(appId, namespaceName, userInfoHolder.getUser().getUserId());
    return ResponseEntity.ok().build();
  }

  @GetMapping("/apps/{appId}/permissions/{permissionType}")
  public ResponseEntity<PermissionCondition> hasPermission(@PathVariable String appId, @PathVariable String permissionType) {
    PermissionCondition permissionCondition = new PermissionCondition();

    permissionCondition.setHasPermission(
        rolePermissionService.userHasPermission(userInfoHolder.getUser().getUserId(), permissionType, appId));

    return ResponseEntity.ok().body(permissionCondition);
  }

  @GetMapping("/apps/{appId}/namespaces/{namespaceName}/permissions/{permissionType}")
  public ResponseEntity<PermissionCondition> hasPermission(@PathVariable String appId, @PathVariable String namespaceName,
                                                           @PathVariable String permissionType) {
    PermissionCondition permissionCondition = new PermissionCondition();

    permissionCondition.setHasPermission(
        rolePermissionService.userHasPermission(userInfoHolder.getUser().getUserId(), permissionType,
            RoleUtils.buildNamespaceTargetId(appId, namespaceName)));

    return ResponseEntity.ok().body(permissionCondition);
  }

  @GetMapping("/apps/{appId}/envs/{env}/namespaces/{namespaceName}/permissions/{permissionType}")
  public ResponseEntity<PermissionCondition> hasPermission(@PathVariable String appId, @PathVariable String env, @PathVariable String namespaceName,
                                                           @PathVariable String permissionType) {
    PermissionCondition permissionCondition = new PermissionCondition();

    permissionCondition.setHasPermission(
        rolePermissionService.userHasPermission(userInfoHolder.getUser().getUserId(), permissionType,
            RoleUtils.buildNamespaceTargetId(appId, namespaceName, env)));

    return ResponseEntity.ok().body(permissionCondition);
  }

  @GetMapping("/permissions/root")
  public ResponseEntity<PermissionCondition> hasRootPermission() {
    PermissionCondition permissionCondition = new PermissionCondition();

    permissionCondition.setHasPermission(rolePermissionService.isSuperAdmin(userInfoHolder.getUser().getUserId()));

    return ResponseEntity.ok().body(permissionCondition);
  }


  @GetMapping("/apps/{appId}/envs/{env}/namespaces/{namespaceName}/role_users")
  public NamespaceEnvRolesAssignedUsers getNamespaceEnvRoles(@PathVariable String appId, @PathVariable String env, @PathVariable String namespaceName) {

    // validate env parameter
    if (Env.UNKNOWN == Env.transformEnv(env)) {
      throw new BadRequestException("env is illegal");
    }

    NamespaceEnvRolesAssignedUsers assignedUsers = new NamespaceEnvRolesAssignedUsers();
    assignedUsers.setNamespaceName(namespaceName);
    assignedUsers.setAppId(appId);
    assignedUsers.setEnv(Env.valueOf(env));

    Set<UserInfo> releaseNamespaceUsers =
        rolePermissionService.queryUsersWithRole(RoleUtils.buildReleaseNamespaceRoleName(appId, namespaceName, env));
    assignedUsers.setReleaseRoleUsers(releaseNamespaceUsers);

    Set<UserInfo> modifyNamespaceUsers =
        rolePermissionService.queryUsersWithRole(RoleUtils.buildModifyNamespaceRoleName(appId, namespaceName, env));
    assignedUsers.setModifyRoleUsers(modifyNamespaceUsers);

    return assignedUsers;
  }

  @PreAuthorize(value = "@permissionValidator.hasAssignRolePermission(#appId)")
  @PostMapping("/apps/{appId}/envs/{env}/namespaces/{namespaceName}/roles/{roleType}")
  public ResponseEntity<Void> assignNamespaceEnvRoleToUser(@PathVariable String appId, @PathVariable String env, @PathVariable String namespaceName,
                                                           @PathVariable String roleType, @RequestBody String user) {
    checkUserExists(user);
    RequestPrecondition.checkArgumentsNotEmpty(user);

    if (!RoleType.isValidRoleType(roleType)) {
      throw new BadRequestException("role type is illegal");
    }

    // validate env parameter
    if (Env.UNKNOWN == Env.transformEnv(env)) {
      throw new BadRequestException("env is illegal");
    }
    Set<String> assignedUser = rolePermissionService.assignRoleToUsers(RoleUtils.buildNamespaceRoleName(appId, namespaceName, roleType, env),
        Sets.newHashSet(user), userInfoHolder.getUser().getUserId());
    if (CollectionUtils.isEmpty(assignedUser)) {
      throw new BadRequestException(user + " already authorized");
    }

    return ResponseEntity.ok().build();
  }

  @PreAuthorize(value = "@permissionValidator.hasAssignRolePermission(#appId)")
  @DeleteMapping("/apps/{appId}/envs/{env}/namespaces/{namespaceName}/roles/{roleType}")
  public ResponseEntity<Void> removeNamespaceEnvRoleFromUser(@PathVariable String appId, @PathVariable String env, @PathVariable String namespaceName,
                                                             @PathVariable String roleType, @RequestParam String user) {
    RequestPrecondition.checkArgumentsNotEmpty(user);

    if (!RoleType.isValidRoleType(roleType)) {
      throw new BadRequestException("role type is illegal");
    }
    // validate env parameter
    if (Env.UNKNOWN == Env.transformEnv(env)) {
      throw new BadRequestException("env is illegal");
    }
    rolePermissionService.removeRoleFromUsers(RoleUtils.buildNamespaceRoleName(appId, namespaceName, roleType, env),
        Sets.newHashSet(user), userInfoHolder.getUser().getUserId());
    return ResponseEntity.ok().build();
  }

  @GetMapping("/apps/{appId}/namespaces/{namespaceName}/role_users")
  public NamespaceRolesAssignedUsers getNamespaceRoles(@PathVariable String appId, @PathVariable String namespaceName) {

    NamespaceRolesAssignedUsers assignedUsers = new NamespaceRolesAssignedUsers();
    assignedUsers.setNamespaceName(namespaceName);
    assignedUsers.setAppId(appId);

    Set<UserInfo> releaseNamespaceUsers =
        rolePermissionService.queryUsersWithRole(RoleUtils.buildReleaseNamespaceRoleName(appId, namespaceName));
    assignedUsers.setReleaseRoleUsers(releaseNamespaceUsers);

    Set<UserInfo> modifyNamespaceUsers =
        rolePermissionService.queryUsersWithRole(RoleUtils.buildModifyNamespaceRoleName(appId, namespaceName));
    assignedUsers.setModifyRoleUsers(modifyNamespaceUsers);

    return assignedUsers;
  }

  @PreAuthorize(value = "@permissionValidator.hasAssignRolePermission(#appId)")
  @PostMapping("/apps/{appId}/namespaces/{namespaceName}/roles/{roleType}")
  public ResponseEntity<Void> assignNamespaceRoleToUser(@PathVariable String appId, @PathVariable String namespaceName,
                                                        @PathVariable String roleType, @RequestBody String user) {
    checkUserExists(user);
    RequestPrecondition.checkArgumentsNotEmpty(user);

    if (!RoleType.isValidRoleType(roleType)) {
      throw new BadRequestException("role type is illegal");
    }
    Set<String> assignedUser = rolePermissionService.assignRoleToUsers(RoleUtils.buildNamespaceRoleName(appId, namespaceName, roleType),
        Sets.newHashSet(user), userInfoHolder.getUser().getUserId());
    if (CollectionUtils.isEmpty(assignedUser)) {
      throw new BadRequestException(user + " already authorized");
    }

    return ResponseEntity.ok().build();
  }

  @PreAuthorize(value = "@permissionValidator.hasAssignRolePermission(#appId)")
  @DeleteMapping("/apps/{appId}/namespaces/{namespaceName}/roles/{roleType}")
  public ResponseEntity<Void> removeNamespaceRoleFromUser(@PathVariable String appId, @PathVariable String namespaceName,
                                                          @PathVariable String roleType, @RequestParam String user) {
    RequestPrecondition.checkArgumentsNotEmpty(user);

    if (!RoleType.isValidRoleType(roleType)) {
      throw new BadRequestException("role type is illegal");
    }
    rolePermissionService.removeRoleFromUsers(RoleUtils.buildNamespaceRoleName(appId, namespaceName, roleType),
        Sets.newHashSet(user), userInfoHolder.getUser().getUserId());
    return ResponseEntity.ok().build();
  }

  @GetMapping("/apps/{appId}/role_users")
  public AppRolesAssignedUsers getAppRoles(@PathVariable String appId) {
    AppRolesAssignedUsers users = new AppRolesAssignedUsers();
    users.setAppId(appId);

    Set<UserInfo> masterUsers = rolePermissionService.queryUsersWithRole(RoleUtils.buildAppMasterRoleName(appId));
    users.setMasterUsers(masterUsers);

    return users;
  }

  @PreAuthorize(value = "@permissionValidator.hasManageAppMasterPermission(#appId)")
  @PostMapping("/apps/{appId}/roles/{roleType}")
  public ResponseEntity<Void> assignAppRoleToUser(@PathVariable String appId, @PathVariable String roleType,
                                                  @RequestBody String user) {
    checkUserExists(user);
    RequestPrecondition.checkArgumentsNotEmpty(user);

    if (!RoleType.isValidRoleType(roleType)) {
      throw new BadRequestException("role type is illegal");
    }
    Set<String> assignedUsers = rolePermissionService.assignRoleToUsers(RoleUtils.buildAppRoleName(appId, roleType),
        Sets.newHashSet(user), userInfoHolder.getUser().getUserId());
    if (CollectionUtils.isEmpty(assignedUsers)) {
      throw new BadRequestException(user + " already authorized");
    }

    return ResponseEntity.ok().build();
  }

  @PreAuthorize(value = "@permissionValidator.hasManageAppMasterPermission(#appId)")
  @DeleteMapping("/apps/{appId}/roles/{roleType}")
  public ResponseEntity<Void> removeAppRoleFromUser(@PathVariable String appId, @PathVariable String roleType,
                                                    @RequestParam String user) {
    RequestPrecondition.checkArgumentsNotEmpty(user);

    if (!RoleType.isValidRoleType(roleType)) {
      throw new BadRequestException("role type is illegal");
    }
    rolePermissionService.removeRoleFromUsers(RoleUtils.buildAppRoleName(appId, roleType),
        Sets.newHashSet(user), userInfoHolder.getUser().getUserId());
    return ResponseEntity.ok().build();
  }

  private void checkUserExists(String userId) {
    if (userService.findByUserId(userId) == null) {
      throw new BadRequestException(String.format("User %s does not exist!", userId));
    }
  }

  @PreAuthorize(value = "@permissionValidator.isSuperAdmin()")
  @PostMapping("/system/role/createApplication")
  public ResponseEntity<Void> addCreateApplicationRoleToUser(@RequestBody List<String> userIds) {

    userIds.forEach(this::checkUserExists);
    rolePermissionService.assignRoleToUsers(SystemRoleManagerService.CREATE_APPLICATION_ROLE_NAME,
            new HashSet<>(userIds), userInfoHolder.getUser().getUserId());

    return ResponseEntity.ok().build();
  }

  @PreAuthorize(value = "@permissionValidator.isSuperAdmin()")
  @DeleteMapping("/system/role/createApplication/{userId}")
  public ResponseEntity<Void> deleteCreateApplicationRoleFromUser(@PathVariable("userId") String userId) {
    checkUserExists(userId);
    Set<String> userIds = new HashSet<>();
    userIds.add(userId);
    rolePermissionService.removeRoleFromUsers(SystemRoleManagerService.CREATE_APPLICATION_ROLE_NAME,
            userIds, userInfoHolder.getUser().getUserId());
    return ResponseEntity.ok().build();
  }

  @PreAuthorize(value = "@permissionValidator.isSuperAdmin()")
  @GetMapping("/system/role/createApplication")
  public List<String> getCreateApplicationRoleUsers() {
    return rolePermissionService.queryUsersWithRole(SystemRoleManagerService.CREATE_APPLICATION_ROLE_NAME)
            .stream().map(UserInfo::getUserId).collect(Collectors.toList());
  }

  @GetMapping("/system/role/createApplication/{userId}")
  public JsonObject hasCreateApplicationPermission(@PathVariable String userId) {
    JsonObject rs = new JsonObject();
    rs.addProperty("hasCreateApplicationPermission", permissionValidator.hasCreateApplicationPermission(userId));
    return rs;
  }

  @PreAuthorize(value = "@permissionValidator.isSuperAdmin()")
  @PostMapping("/apps/{appId}/system/master/{userId}")
  public ResponseEntity<Void> addManageAppMasterRoleToUser(@PathVariable String appId, @PathVariable String userId) {
    checkUserExists(userId);
    roleInitializationService.initManageAppMasterRole(appId, userInfoHolder.getUser().getUserId());
    Set<String> userIds = new HashSet<>();
    userIds.add(userId);
    rolePermissionService.assignRoleToUsers(RoleUtils.buildAppRoleName(appId, PermissionType.MANAGE_APP_MASTER),
            userIds, userInfoHolder.getUser().getUserId());
    return ResponseEntity.ok().build();
  }

  @PreAuthorize(value = "@permissionValidator.isSuperAdmin()")
  @DeleteMapping("/apps/{appId}/system/master/{userId}")
  public ResponseEntity<Void> forbidManageAppMaster(@PathVariable String appId, @PathVariable String  userId) {
    checkUserExists(userId);
    roleInitializationService.initManageAppMasterRole(appId, userInfoHolder.getUser().getUserId());
    Set<String> userIds = new HashSet<>();
    userIds.add(userId);
    rolePermissionService.removeRoleFromUsers(RoleUtils.buildAppRoleName(appId, PermissionType.MANAGE_APP_MASTER),
            userIds, userInfoHolder.getUser().getUserId());
    return ResponseEntity.ok().build();
  }

    @GetMapping("/system/role/manageAppMaster")
    public JsonObject isManageAppMasterPermissionEnabled() {
      JsonObject rs = new JsonObject();
      rs.addProperty("isManageAppMasterPermissionEnabled", systemRoleManagerService.isManageAppMasterPermissionEnabled());
      return rs;
    }
}
```

- 每个方法，调用 RolePermissionService 的方法，提供 API 服务。
- 🙂 代码比较简单，胖友自己查看。

对应界面为

- **App** 级权限管理：![项目管理](https://static.iocoder.cn/images/Apollo/2018_06_05/09.png)
- **Namespace** 级别权限管理：![权限管理](https://static.iocoder.cn/images/Apollo/2018_06_05/10.png)

# 666. 彩蛋

T T 老长一篇。哈哈哈，有种把所有代码 copy 过来的感觉。

突然发现没分享 `com.ctrip.framework.apollo.portal.spi.configurationRoleConfiguration` ，**Role** Spring Java 配置。代码如下：

```java
@Configuration
public class RoleConfiguration {

    @Bean
    public RoleInitializationService roleInitializationService() {
        return new DefaultRoleInitializationService();
    }

    @Bean
    public RolePermissionService rolePermissionService() {
        return new DefaultRolePermissionService();
    }

}
```



# 参考

[Apollo 源码解析 —— Portal 认证与授权（二）之授权](https://www.iocoder.cn/Apollo/portal-auth-2/)
