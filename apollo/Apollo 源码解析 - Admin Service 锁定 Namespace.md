# 1. 概述

> 老艿艿：本系列假定胖友已经阅读过 [《Apollo 官方 wiki 文档》](https://github.com/ctripcorp/apollo/wiki/) 。

本文分享 **Admin Service 锁定 Namespace** 。可通过设置 **ConfigDB** 的 ServerConfig 的 `"namespace.lock.switch"` 为 `"true"` 开启。效果如下：

- 🙂 一次配置修改只能是**一个人**
- 😈 一次配置发布只能是**另一个人**

也就是说，开启后，一次配置修改并发布，需要**两个人**。

**默认**为 `"false"` ，即关闭。

# 2. NamespaceLock

`com.ctrip.framework.apollo.biz.entity.NamespaceLock` ，继承 BaseEntity 抽象类，Namespace Lock **实体**。代码如下：

```java
@Entity
@Table(name = "NamespaceLock")
@Where(clause = "isDeleted = 0")
public class NamespaceLock extends BaseEntity {

    /**
     * Namespace 编号 {@link Namespace}
     *
     * 唯一索引
     */
    @Column(name = "NamespaceId")
    private long namespaceId;

}
```

- **写操作** Item 时，创建 Namespace 对应的 NamespaceLock 记录到 **ConfigDB** 数据库中，从而记录配置修改**人**。
- `namespaceId`字段，Namespace 编号，指向对应的 Namespace 。
  - 该字段上有**唯一索引**。通过该锁定，保证并发**写操作**时，同一个 Namespace 有且仅有创建一条 NamespaceLock 记录。

## 2.1 NamespaceLockService

在 `apollo-biz` 项目中，`com.ctrip.framework.apollo.biz.service.NamespaceLockService` ，提供 NamespaceLock 的 **Service** 逻辑给 Admin Service 和 Config Service 。代码如下：

```java
@Service
public class NamespaceLockService {

  private final NamespaceLockRepository namespaceLockRepository;

  public NamespaceLockService(final NamespaceLockRepository namespaceLockRepository) {
    this.namespaceLockRepository = namespaceLockRepository;
  }

  public NamespaceLock findLock(Long namespaceId){
    return namespaceLockRepository.findByNamespaceId(namespaceId);
  }

  @Transactional
  public NamespaceLock tryLock(NamespaceLock lock){
    return namespaceLockRepository.save(lock);
  }

  @Transactional
  public void unlock(Long namespaceId){
    namespaceLockRepository.deleteByNamespaceId(namespaceId);
  }
}
```

## 2.2 NamespaceLockRepository

`com.ctrip.framework.apollo.biz.repository.NamespaceLockRepository` ，继承 `org.springframework.data.repository.PagingAndSortingRepository` 接口，提供 NamespaceLock 的**数据访问** 给 Admin Service 和 Config Service 。代码如下：

```java
public interface NamespaceLockRepository extends PagingAndSortingRepository<NamespaceLock, Long> {

  NamespaceLock findByNamespaceId(Long namespaceId);

  Long deleteByNamespaceId(Long namespaceId);

}
```

# 3. 限制修改人

在 `apollo-adminservice` 项目中，在 `aop` 模块中，通过 **Spring AOP** 记录 NamespaceLock ，从而实现锁定 Namespace ，限制修改人。

## 3.1 @PreAcquireNamespaceLock

`com.ctrip.framework.apollo.adminservice.aop.@PreAcquireNamespaceLock` ，**注解**，标识方法需要获取到 Namespace 的 Lock 才能执行。

```java
/**
 * 标识方法需要获取到namespace的lock才能执行
 */
@Target(ElementType.METHOD)
@Retention(RetentionPolicy.RUNTIME)
public @interface PreAcquireNamespaceLock {

}
```

目前添加了 `@PreAcquireNamespaceLock` 注解的方法如下图：

![标记 `@PreAcquireNamespaceLock` 注解的方法](http://blog-1259650185.cosbj.myqcloud.com/img/202204/04/1649038581.png)

## 3.2 NamespaceAcquireLockAspect

`com.ctrip.framework.apollo.adminservice.aop.NamespaceAcquireLockAspect` ，获得 NamespaceLock 切面。

**定义切面**

```java
@Aspect
@Component
public class NamespaceAcquireLockAspect {
  private static final Logger logger = LoggerFactory.getLogger(NamespaceAcquireLockAspect.class);

  private final NamespaceLockService namespaceLockService;
  private final NamespaceService namespaceService;
  private final ItemService itemService;
  private final BizConfig bizConfig;

  public NamespaceAcquireLockAspect(
      final NamespaceLockService namespaceLockService,
      final NamespaceService namespaceService,
      final ItemService itemService,
      final BizConfig bizConfig) {
    this.namespaceLockService = namespaceLockService;
    this.namespaceService = namespaceService;
    this.itemService = itemService;
    this.bizConfig = bizConfig;
  }


  //create item
  @Before("@annotation(PreAcquireNamespaceLock) && args(appId, clusterName, namespaceName, item, ..)")
  public void requireLockAdvice(String appId, String clusterName, String namespaceName,
                                ItemDTO item) {
    acquireLock(appId, clusterName, namespaceName, item.getDataChangeLastModifiedBy()); // 尝试锁定
  }

  //update item
  @Before("@annotation(PreAcquireNamespaceLock) && args(appId, clusterName, namespaceName, itemId, item, ..)")
  public void requireLockAdvice(String appId, String clusterName, String namespaceName, long itemId,
                                ItemDTO item) {
    acquireLock(appId, clusterName, namespaceName, item.getDataChangeLastModifiedBy()); // 尝试锁定
  }

  //update by change set
  @Before("@annotation(PreAcquireNamespaceLock) && args(appId, clusterName, namespaceName, changeSet, ..)")
  public void requireLockAdvice(String appId, String clusterName, String namespaceName,
                                ItemChangeSets changeSet) {
    acquireLock(appId, clusterName, namespaceName, changeSet.getDataChangeLastModifiedBy());  // 尝试锁定
  }

  //delete item
  @Before("@annotation(PreAcquireNamespaceLock) && args(itemId, operator, ..)")
  public void requireLockAdvice(long itemId, String operator) {
    Item item = itemService.findOne(itemId); // 获得 Item 对象。若不存在，抛出 BadRequestException 异常
    if (item == null){
      throw new BadRequestException("item not exist.");
    }
    acquireLock(item.getNamespaceId(), operator); // 尝试锁定
  } 
  // ... 省略其他方法

}
```

- `@Aspect` 注解，标记为表面类。
- `@Before` 注解，标记切入执行方法**前**。
- 调用 `#acquireLock(...)` 方法，尝试锁定。

**acquireLock**

```java
void acquireLock(String appId, String clusterName, String namespaceName,
                         String currentUser) {
  if (bizConfig.isNamespaceLockSwitchOff()) { // 当关闭锁定 Namespace 开关时，直接返回
    return;
  }
  // 获得 Namespace 对象
  Namespace namespace = namespaceService.findOne(appId, clusterName, namespaceName);
  // 尝试锁定
  acquireLock(namespace, currentUser);
}

void acquireLock(long namespaceId, String currentUser) {
  if (bizConfig.isNamespaceLockSwitchOff()) { // 当关闭锁定 Namespace 开关时，直接返回
    return;
  }
  // 获得 Namespace 对象
  Namespace namespace = namespaceService.findOne(namespaceId);
  // 尝试锁定
  acquireLock(namespace, currentUser);

}
```

- `BizConfig#isNamespaceLockSwitchOff()` 方法，判断是否关闭锁定 Namespace 的开关。代码如下：

  ```java
  public boolean isNamespaceLockSwitchOff() {
      return !getBooleanProperty("namespace.lock.switch", false);
  }
  ```

- `#acquireLock(namespace, currentUser)` 方法，尝试锁定。代码如下：

  ```java
  private void acquireLock(Namespace namespace, String currentUser) {
    if (namespace == null) { // 当 Namespace 为空时，抛出 BadRequestException 异常
      throw new BadRequestException("namespace not exist.");
    }
  
    long namespaceId = namespace.getId();
    // 获得 NamespaceLock 对象
    NamespaceLock namespaceLock = namespaceLockService.findLock(namespaceId);
    if (namespaceLock == null) {
      try {
        tryLock(namespaceId, currentUser);  // 锁定
        //lock success
      } catch (DataIntegrityViolationException e) {
        //lock fail
        namespaceLock = namespaceLockService.findLock(namespaceId);  // 锁定失败，获得 NamespaceLock 对象
        checkLock(namespace, namespaceLock, currentUser); // 校验锁定人是否是当前管理员
      } catch (Exception e) {
        logger.error("try lock error", e);
        throw e;
      }
    } else {
      //check lock owner is current user
      checkLock(namespace, namespaceLock, currentUser); // 校验锁定人是否是当前管理员
    }
  }
  ```

  - 第 8 行：调用 `NamespaceLockService#findLock(namespaceId)` 方法，获得 NamespaceLock 对象。

  - 第 10 至 14 行：当 NamespaceLock **不存在**时，调用 `#tryLock(namespaceId, currentUser)` 方法，尝试锁定。代码如下：

    ```java
    private void tryLock(long namespaceId, String user) {
        // 创建 NamespaceLock 对象
        NamespaceLock lock = new NamespaceLock();
        lock.setNamespaceId(namespaceId);
        lock.setDataChangeCreatedBy(user); // 管理员
        lock.setDataChangeLastModifiedBy(user); // 管理员
        // 保存 NamespaceLock 对象
        namespaceLockService.tryLock(lock);
    }
    ```

    - 创建 NamespaceLock 对象，并调用 `NamespaceLockService#tryLock(NamespaceLock)` 方法，进行保存。

  - 第 15 至 18 行：发生 DataIntegrityViolationException 异常，说明保存 NamespaceLock 对象失败，由于**唯一索引 `namespaceId` 冲突**，调用 `NamespaceLockService#tryLock(NamespaceLock)` 方法，获得**最新的** NamespaceLock 对象。

  - 第 20 行 || 第 28 行：调用 `#checkLock(namespace, namespaceLock, currentUser)` 方法，**校验**锁定人是否是当前管理员。代码如下：

    ```java
    private void checkLock(Namespace namespace, NamespaceLock namespaceLock, String currentUser) {
        // 当 NamespaceLock 不存在，抛出 ServiceException 异常
        if (namespaceLock == null) {
            throw new ServiceException(String.format("Check lock for %s failed, please retry.", namespace.getNamespaceName()));
        }
        // 校验锁定人是否是当前管理员。若不是，抛出 BadRequestException 异常
        String lockOwner = namespaceLock.getDataChangeCreatedBy();
        if (!lockOwner.equals(currentUser)) {
            throw new BadRequestException("namespace:" + namespace.getNamespaceName() + " is modified by " + lockOwner);
        }
    }
    ```

    - 当 `NamespaceLock.dataChangeCreatedBy` 不是当前管理员时，**抛出 BadRequestException 异常**，从而实现**限制修改人**。

## 3.3 NamespaceUnlockAspect

`com.ctrip.framework.apollo.adminservice.aop.NamespaceUnlockAspect` ，释放 NamespaceLock 切面。😈 在配置多次修改，**恢复**到原有状态( 即最后一次 **Release** 的配置) 。因此，NamespaceUnlockAspect 的类注释如下：

> unlock namespace if is redo operation.
>
> For example: If namespace has a item K1 = v1
>
> - First operate: change k1 = v2 (lock namespace)
> - Second operate: change k1 = v1 (unlock namespace)

**定义切面**

```java
@Aspect
@Component
public class NamespaceUnlockAspect {

  private static final Gson GSON = new Gson();

  private final NamespaceLockService namespaceLockService;
  private final NamespaceService namespaceService;
  private final ItemService itemService;
  private final ReleaseService releaseService;
  private final BizConfig bizConfig;

  public NamespaceUnlockAspect(
      final NamespaceLockService namespaceLockService,
      final NamespaceService namespaceService,
      final ItemService itemService,
      final ReleaseService releaseService,
      final BizConfig bizConfig) {
    this.namespaceLockService = namespaceLockService;
    this.namespaceService = namespaceService;
    this.itemService = itemService;
    this.releaseService = releaseService;
    this.bizConfig = bizConfig;
  }


  //create item
  @After("@annotation(PreAcquireNamespaceLock) && args(appId, clusterName, namespaceName, item, ..)")
  public void requireLockAdvice(String appId, String clusterName, String namespaceName,
                                ItemDTO item) {
    tryUnlock(namespaceService.findOne(appId, clusterName, namespaceName));  // 尝试解锁
  }

  //update item
  @After("@annotation(PreAcquireNamespaceLock) && args(appId, clusterName, namespaceName, itemId, item, ..)")
  public void requireLockAdvice(String appId, String clusterName, String namespaceName, long itemId,
                                ItemDTO item) {
    tryUnlock(namespaceService.findOne(appId, clusterName, namespaceName)); // 尝试解锁
  }

  //update by change set
  @After("@annotation(PreAcquireNamespaceLock) && args(appId, clusterName, namespaceName, changeSet, ..)")
  public void requireLockAdvice(String appId, String clusterName, String namespaceName,
                                ItemChangeSets changeSet) {
    tryUnlock(namespaceService.findOne(appId, clusterName, namespaceName)); // 尝试解锁
  }

  //delete item
  @After("@annotation(PreAcquireNamespaceLock) && args(itemId, operator, ..)")
  public void requireLockAdvice(long itemId, String operator) {
    Item item = itemService.findOne(itemId); // 获得 Item 对象。若不存在，抛出 BadRequestException 异常
    if (item == null) {
      throw new BadRequestException("item not exist.");
    }
    tryUnlock(namespaceService.findOne(item.getNamespaceId())); // 尝试解锁
  }
	// ... 省略其他方法

}
```

- `@Aspect` 注解，标记为表面类。
- `@After` 注解，标记切入执行方法**后**。
- 调用 `#tryUnlock(...)` 方法，尝试解锁。

**tryUnlock**

```java
private void tryUnlock(Namespace namespace) {
    // 当关闭锁定 Namespace 开关时，直接返回
    if (bizConfig.isNamespaceLockSwitchOff()) {
        return;
    }
    // 若当前 Namespace 的配置恢复原有状态，释放锁，即删除 NamespaceLock
    if (!isModified(namespace)) {
        namespaceLockService.unlock(namespace.getId());
    }
}
```

- `#isModified(Namespace)` 方法，若当前 Namespace 的配置**恢复原有状态**。
- `NamespaceLockService#unlock(namespaceId)` 方法，释放锁，即**删除** NamespaceLock 。

**isModified**

```java
 1: boolean isModified(Namespace namespace) {
 2:     // 获得当前 Namespace 的最后有效的 Release 对象
 3:     Release release = releaseService.findLatestActiveRelease(namespace);
 4:     // 获得当前 Namespace 的 Item 集合
 5:     List<Item> items = itemService.findItemsWithoutOrdered(namespace.getId());
 6: 
 7:     // 如果无 Release 对象，判断是否有普通的 Item 配置项。若有，则代表修改过。
 8:     if (release == null) {
 9:         return hasNormalItems(items);
10:     }
11: 
12:     // 获得 Release 的配置 Map
13:     Map<String, String> releasedConfiguration = gson.fromJson(release.getConfigurations(), GsonType.CONFIG);
14:     // 获得当前 Namespace 的配置 Map
15:     Map<String, String> configurationFromItems = generateConfigurationFromItems(namespace, items);
16:     // 对比两个 配置 Map ，判断是否相等。
17:     MapDifference<String, String> difference = Maps.difference(releasedConfiguration, configurationFromItems);
18:     return !difference.areEqual();
19: }
```

- 第 3 行：调用 `ReleaseService#findLatestActiveRelease(Namespace)` 方法，获得当前 Namespace 的**最后有效**的 Release 对象。Release 的 `configurations` 字段，记录每次发布的**完整配置 Map**，代码如下：

  ```java
  // Release.java
  @Column(name = "Configurations", nullable = false)
  @Lob
  private String configurations;
  ```

  - 例如：

    ```json
    {
        "key1": "value1", 
        "key2": "value2", 
        "key3": "value3", 
        "key4": "value4"
    }
    ```

- 第 5 行：调用 `ItemService#findItemsWithoutOrdered(namespaceId)` 方法，获得当前 Namespace 的 **Item 集合**。

- ========== 第一种情况 ==========

- 第 8 至 10 行：如果无 Release 对象，调用 `#hasNormalItems(List<Item>)` 方法，判断是否有普通的 Item 配置项。若有，则代表修改过。代码如下：

  ```java
  private boolean hasNormalItems(List<Item> items) {
      for (Item item : items) {
          if (!StringUtils.isEmpty(item.getKey())) { // 非空串的 Key ，因为注释和空行的 Item 的 Key 为空串。
              return true;
          }
      }
      return false;
  }
  ```

- ========== 第二种情况 ==========

- 第 13 行：获得 Release 的**配置 Map** 。

- 第 15 行：调用 `#generateConfigurationFromItems(namespace, items)` 方法，获得当前 Namespace 的**配置 Map** 。代码如下：

  ```java
  private Map<String, String> generateConfigurationFromItems(Namespace namespace, List<Item> namespaceItems) {
      Map<String, String> configurationFromItems = Maps.newHashMap();
      // 获得父 Namespace 对象
      Namespace parentNamespace = namespaceService.findParentNamespace(namespace);
      // 若无父 Namespace ，使用自己的配置
      // parent namespace
      if (parentNamespace == null) {
          generateMapFromItems(namespaceItems, configurationFromItems);
          // 若有父 Namespace ，说明是灰度发布，合并父 Namespace 的配置 + 自己的配置项
      } else { //child namespace
          Release parentRelease = releaseService.findLatestActiveRelease(parentNamespace);
          if (parentRelease != null) {
              configurationFromItems = gson.fromJson(parentRelease.getConfigurations(), GsonType.CONFIG);
          }
          generateMapFromItems(namespaceItems, configurationFromItems);
      }
      return configurationFromItems;
  }
  
  private Map<String, String> generateMapFromItems(List<Item> items, Map<String, String> configurationFromItems) {
      for (Item item : items) {
          String key = item.getKey();
          // 跳过注释和空行的配置项
          if (StringUtils.isBlank(key)) {
              continue;
          }
          configurationFromItems.put(key, item.getValue());
      }
      return configurationFromItems;
  }
  ```

  - 关于**父** Namespace 部分的代码，胖友看完**灰度发布**的内容，再回过头理解。

- 第 17 至 18 行：使用 Guava MapDifference 对比两个 配置 Map ，判断是否相等。

# 4. 限制发布人

发布配置时，调用 `ReleaseService#publish(...)` 方法时，在方法内部，会调用 `#checkLock(Namespace namespace, boolean isEmergencyPublish, String operator)` 方法，校验锁定人是否是当前管理员。代码如下：

```java
private void checkLock(Namespace namespace, boolean isEmergencyPublish, String operator) {
  if (!isEmergencyPublish) {  // 非紧急发布
    NamespaceLock lock = namespaceLockService.findLock(namespace.getId()); // 获得 NamespaceLock 对象
    if (lock != null && lock.getDataChangeCreatedBy().equals(operator)) { // 校验锁定人是否是当前管理员。若是，抛出 BadRequestException 异常
      throw new BadRequestException("Config can not be published by yourself.");
    }
  }
}
```

- 第 2 行：非**紧急发布**，可通过设置 **PortalDB** 的 ServerConfig 的`"emergencyPublish.supported.envs"` 配置开启对应的 **Env 们**。例如，`emergencyPublish.supported.envs = dev` 。
- 第 6 至 8 行：当 `NamespaceLock.dataChangeCreatedBy` **是**当前管理员时，**抛出 BadRequestException 异常**，从而实现**限制修改人**。

# 5. 解锁

发布配置时，调用 `ReleaseService#createRelease(...)` 方法时，在方法内部，会调用 `NamespaceLockService#unlock(namespaceId)` 方法，释放 NamespaceLock 。代码如下：

```java
private Release createRelease(Namespace namespace, String name, String comment,
                              Map<String, String> configurations, String operator) {
    // ... 省略无关代码
    // 释放 NamespaceLock
    namespaceLockService.unlock(namespace.getId());
    // ... 省略无关代码
}
```



# 参考

[Apollo 源码解析 —— Admin Service 锁定 Namespace](https://www.iocoder.cn/Apollo/admin-service-lock-namespace/)
