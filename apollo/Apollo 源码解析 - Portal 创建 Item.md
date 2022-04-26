# 1. 概述

> 老艿艿：本系列假定胖友已经阅读过 [《Apollo 官方 wiki 文档》](https://github.com/ctripcorp/apollo/wiki/) 。

Item ，配置项，是 Namespace 下**最小颗粒度**的单位。在 Namespace 分成**五种**类型：`properties` `yml` `yaml` `json` `xml` 。其中：

- **`properties`** ：**每一行**配置对应**一条** Item 记录。
- **后四者**：无法进行拆分，所以**一个** Namespace **仅仅**对应**一条** Item 记录。

本文先分享 **Portal 创建类型为 properties 的 Namespace 的 Item** 的流程，整个过程涉及 Portal、Admin Service ，如下图所示：

![流程](http://blog-1259650185.cosbj.myqcloud.com/img/202204/03/1648950540.png)

> 老艿艿：因为 Portal 是管理后台，所以从代码实现上，和业务系统非常相像。也因此，本文会略显啰嗦。

# 2. 实体

## 2.1 Item

`com.ctrip.framework.apollo.biz.entity.Item` ，继承 BaseEntity 抽象类，Item **实体**。代码如下：

```java
@Entity
@Table(name = "Item")
@SQLDelete(sql = "Update Item set IsDeleted = 1, DeletedAt = ROUND(UNIX_TIMESTAMP(NOW(4))*1000) where Id = ?")
@Where(clause = "isDeleted = 0")
public class Item extends BaseEntity {

  @Column(name = "NamespaceId", nullable = false)
  private long namespaceId; // Namespace 编号

  @Column(name = "key", nullable = false)
  private String key; // 键

  @Column(name = "value")
  @Lob
  private String value; // 值

  @Column(name = "comment")
  private String comment; // 注释

  @Column(name = "LineNum")
  private Integer lineNum; // 行号，从一开始。例如 Properties 中，多个配置项。每个配置项对应一行。

}
```

- `namespaceId` 字段，Namespace 编号，指向对应的 Namespace 记录。
- `key`字段，键。
  - 对于 `properties` ，使用 Item 的 `key` ，对应**每条**配置项的键。
  - 对于 `yaml` 等等，使用 Item 的 `key = content` ，对应**整个**配置文件。
- `lineNum` 字段，行号，从**一**开始。主要用于 `properties` 类型的配置文件。

## 2.2 Commit

`com.ctrip.framework.apollo.biz.entity.Commit` ，继承 BaseEntity 抽象类，Commit **实体**，记录 Item 的 **KV** 变更历史。代码如下：

```java
@Entity
@Table(name = "Commit")
@SQLDelete(sql = "Update Commit set IsDeleted = 1, DeletedAt = ROUND(UNIX_TIMESTAMP(NOW(4))*1000) where Id = ?")
@Where(clause = "isDeleted = 0")
public class Commit extends BaseEntity {

  @Lob
  @Column(name = "ChangeSets", nullable = false)
  private String changeSets; // 变更集合。JSON 格式化，使用 {@link com.ctrip.framework.apollo.biz.utils.ConfigChangeContentBuilder} 生成

  @Column(name = "AppId", nullable = false)
  private String appId; // App 编号

  @Column(name = "ClusterName", nullable = false)
  private String clusterName; // Cluster 名字

  @Column(name = "NamespaceName", nullable = false)
  private String namespaceName; // Namespace 名字

  @Column(name = "Comment")
  private String comment; // 备注

}
```

- `appId` + `clusterName` + `namespaceName` 字段，可以确认唯一 Namespace 记录。
- `changeSets` 字段，Item 变更集合。JSON 格式化字符串，使用 ConfigChangeContentBuilder 构建。

### 2.2.1 ConfigChangeContentBuilder

`com.ctrip.framework.apollo.biz.utils.ConfigChangeContentBuilder` ，配置变更内容构建器。

**构造方法**

```java
public class ConfigChangeContentBuilder {

  private static final Gson GSON = new GsonBuilder().setDateFormat("yyyy-MM-dd HH:mm:ss").create();

  private List<Item> createItems = new LinkedList<>(); // 创建 Item 集合
  private List<ItemPair> updateItems = new LinkedList<>(); // 更新 Item 集合
  private List<Item> deleteItems = new LinkedList<>(); // 删除 Item 集合
  // ... 省略其他接口和属性
}
```

- `createItems` 字段，添加代码如下：

  ```java
  public ConfigChangeContentBuilder createItem(Item item) {
      if (!StringUtils.isEmpty(item.getKey())) {
          createItems.add(cloneItem(item));
      }
      return this;
  }
  ```

  - 调用 `#cloneItem(Item)` 方法，克隆 Item 对象。因为在 `#build()` 方法中，会修改 Item 对象的属性。代码如下：

    ```java
    Item cloneItem(Item source) {
        Item target = new Item();
        BeanUtils.copyProperties(source, target);
        return target;
    }
    ```

- `updateItems` 字段，更新代码如下：

  ```java
  public ConfigChangeContentBuilder updateItem(Item oldItem, Item newItem) {
      if (!oldItem.getValue().equals(newItem.getValue())) {
          ItemPair itemPair = new ItemPair(cloneItem(oldItem), cloneItem(newItem));
          updateItems.add(itemPair);
      }
      return this;
  }
  ```

  - ItemPair ，Item **组**，代码如下：

    ```java
    static class ItemPair {
    
        Item oldItem; // 老
        Item newItem; // 新
    
        public ItemPair(Item oldItem, Item newItem) {
            this.oldItem = oldItem;
            this.newItem = newItem;
        }
    
    }
    ```

- `deleteItems` 字段，删除代码如下：

  ```java
  public ConfigChangeContentBuilder deleteItem(Item item) {
      if (!StringUtils.isEmpty(item.getKey())) {
          deleteItems.add(cloneItem(item));
      }
      return this;
  }
  ```

**hasContent**

`#hasContent()` 方法，判断是否有变化。**当且仅当有变化才记录 Commit**。代码如下：

```java
public boolean hasContent() {
    return !createItems.isEmpty() || !updateItems.isEmpty() || !deleteItems.isEmpty();
}
```

**build**

`#build()` 方法，构建 Item 变化的 JSON 字符串。代码如下：

```java
public String build() {
    // 因为事务第一段提交并没有更新时间,所以build时统一更新
    Date now = new Date();
    for (Item item : createItems) {
        item.setDataChangeLastModifiedTime(now);
    }
    for (ItemPair item : updateItems) {
        item.newItem.setDataChangeLastModifiedTime(now);
    }
    for (Item item : deleteItems) {
        item.setDataChangeLastModifiedTime(now);
    }
    // JSON 格式化成字符串
    return gson.toJson(this);
}
```

- 例子如下：

  ```json
  // 已经使用 http://tool.oschina.net/codeformat/json/ 进行格式化，实际是**紧凑型**
  {
      "createItems": [ ], 
      "updateItems": [
          {
              "oldItem": {
                  "namespaceId": 32, 
                  "key": "key4", 
                  "value": "value4123", 
                  "comment": "123", 
                  "lineNum": 4, 
                  "id": 15, 
                  "isDeleted": false, 
                  "dataChangeCreatedBy": "apollo", 
                  "dataChangeCreatedTime": "2018-04-27 16:49:59", 
                  "dataChangeLastModifiedBy": "apollo", 
                  "dataChangeLastModifiedTime": "2018-04-27 22:37:52"
              }, 
              "newItem": {
                  "namespaceId": 32, 
                  "key": "key4", 
                  "value": "value41234", 
                  "comment": "123", 
                  "lineNum": 4, 
                  "id": 15, 
                  "isDeleted": false, 
                  "dataChangeCreatedBy": "apollo", 
                  "dataChangeCreatedTime": "2018-04-27 16:49:59", 
                  "dataChangeLastModifiedBy": "apollo", 
                  "dataChangeLastModifiedTime": "2018-04-27 22:38:58"
              }
          }
      ], 
      "deleteItems": [ ]
  }
  ```

# 3. Portal 侧

## 3.1 ItemController

在 `apollo-portal` 项目中，`com.ctrip.framework.apollo.portal.controller.ItemController` ，提供 Item 的 **API** 。

在【**添加配置项**】的界面中，点击【提交】按钮，调用**创建 Item 的 API** 。

<img src="http://blog-1259650185.cosbj.myqcloud.com/img/202204/03/1648952150.png" alt="添加配置项" style="zoom: 33%;" />

`#createItem(appId, env, clusterName, namespaceName, ItemDTO)` 方法，创建 Item 对象。代码如下：

```java
@RestController
public class ItemController {

  private final ItemService configService;
  private final NamespaceService namespaceService;
  private final UserInfoHolder userInfoHolder;
  private final PermissionValidator permissionValidator;

  @PreAuthorize(value = "@permissionValidator.hasModifyNamespacePermission(#appId, #namespaceName, #env)")
  @PostMapping("/apps/{appId}/envs/{env}/clusters/{clusterName}/namespaces/{namespaceName}/item")
  public ItemDTO createItem(@PathVariable String appId, @PathVariable String env,
                            @PathVariable String clusterName, @PathVariable String namespaceName,
                            @RequestBody ItemDTO item) {
    checkModel(isValidItem(item)); // 校验 Item 格式正确

    //protect
    item.setLineNum(0);
    item.setId(0);
    String userId = userInfoHolder.getUser().getUserId(); // 设置 ItemDTO 的创建和修改人为当前管理员
    item.setDataChangeCreatedBy(userId);
    item.setDataChangeLastModifiedBy(userId);
    item.setDataChangeCreatedTime(null);
    item.setDataChangeLastModifiedTime(null);
    // 保存 Item 到 Admin Service
    return configService.createItem(appId, Env.valueOf(env), clusterName, namespaceName, item);
  }
  // ... 省略其他接口和属性
}
```

- **POST `/apps/{appId}/envs/{env}/clusters/{clusterName}/namespaces/{namespaceName}/item` 接口**，Request Body 传递 **JSON** 对象。

- `@PreAuthorize(...)` 注解，调用 `PermissionValidator#hasModifyNamespacePermission(appId, namespaceName)` 方法，校验是否有**修改** Namespace 的权限。后续文章，详细分享。

- `com.ctrip.framework.apollo.common.dto.ItemDTO` ，Item DTO 。代码如下：

  ```java
  public class ItemDTO extends BaseDTO {
  
      /**
       * Item 编号
       */
      private long id;
      /**
       * Namespace 编号
       */
      private long namespaceId;
      /**
       * 键
       */
      private String key;
      /**
       * 值
       */
      private String value;
      /**
       * 备注
       */
      private String comment;
      /**
       * 行数
       */
      private int lineNum;
  }
  ```

- 第 14 行：调用 `#isValidItem(ItemDTO)` 方法，校验 Item 格式正确。代码如下：

  ```java
  private boolean isValidItem(ItemDTO item) {
      return Objects.nonNull(item) // 非空
              && !StringUtils.isContainEmpty(item.getKey()); // 键非空
  }
  ```

- 第 16 至 18 行 && 第 23 至 25 行：防御性编程，这几个参数不需要从 Portal 传递。

- 第 19 至 22 行：设置 ItemDTO 的创建和修改人为当前管理员。

- 第 27 行：调用 `ConfigService#createItem(appId, Env, clusterName, namespaceName, ItemDTO)` 方法，保存 Item 到 Admin Service 中。

## 3.2 ItemService

在 `apollo-portal` 项目中，`com.ctrip.framework.apollo.portal.service.ItemService` ，提供 Item 的 **Service** 逻辑。

`#createItem(appId, env, clusterName, namespaceName, ItemDTO)` 方法，创建并保存 Item 到 Admin Service 。代码如下：

```java
@Service
public class ItemService {
  private static final Gson GSON = new Gson();

  private final UserInfoHolder userInfoHolder;
  private final AdminServiceAPI.NamespaceAPI namespaceAPI;
  private final AdminServiceAPI.ItemAPI itemAPI;
  private final AdminServiceAPI.ReleaseAPI releaseAPI;
  private final ConfigTextResolver fileTextResolver;
  private final ConfigTextResolver propertyResolver;

  public ItemDTO createItem(String appId, Env env, String clusterName, String namespaceName, ItemDTO item) {
    NamespaceDTO namespace = namespaceAPI.loadNamespace(appId, env, clusterName, namespaceName); // 校验 NamespaceDTO 是否存在。若不存在，抛出 BadRequestException 异常
    if (namespace == null) {
      throw new BadRequestException(
          "namespace:" + namespaceName + " not exist in env:" + env + ", cluster:" + clusterName);
    }
    item.setNamespaceId(namespace.getId()); // 设置 ItemDTO 的 namespaceId
    // 保存 Item 到 Admin Service
    ItemDTO itemDTO = itemAPI.createItem(appId, env, clusterName, namespaceName, item);
    Tracer.logEvent(TracerEventType.MODIFY_NAMESPACE, String.format("%s+%s+%s+%s", appId, env, clusterName, namespaceName));
    return itemDTO;
  }
  // ... 省略其他接口和属性
}
```

- 第 7 至11 行：调用 `NamespaceAPI#loadNamespace(appId, Env, clusterName, namespaceName)` 方法，**校验** Namespace 是否存在。若不存在，抛出 BadRequestException 异常。**注意**，此处是远程调用 Admin Service 的 API 。
- 第 12 行：设置 ItemDTO 的 `namespaceId` 。
- 第 15 行：调用 `NamespaceAPI#createItem(appId, Env, clusterName, namespaceName, ItemDTO)` 方法，保存 Item 到 Admin Service 。
- 第 17 行：【TODO 6001】Tracer 日志

## 3.3 ItemAPI

`com.ctrip.framework.apollo.portal.api.ItemAPI` ，实现 API 抽象类，封装对 Admin Service 的 Item 模块的 API 调用。代码如下：

![ItemAPI](http://blog-1259650185.cosbj.myqcloud.com/img/202204/03/1648953462.png)

# 4. Admin Service 侧

## 4.1 ItemController

在 `apollo-adminservice` 项目中， `com.ctrip.framework.apollo.adminservice.controller.ItemController` ，提供 Item 的 **API** 。

`#create(appId, clusterName, namespaceName, ItemDTO)` 方法，创建 Item ，并记录 Commit 。代码如下：

```java
@RestController
public class ItemController {

  private final ItemService itemService;
  private final NamespaceService namespaceService;
  private final CommitService commitService;
  private final ReleaseService releaseService;


  public ItemController(final ItemService itemService, final NamespaceService namespaceService, final CommitService commitService, final ReleaseService releaseService) {
    this.itemService = itemService;
    this.namespaceService = namespaceService;
    this.commitService = commitService;
    this.releaseService = releaseService;
  }

  @PreAcquireNamespaceLock
  @PostMapping("/apps/{appId}/clusters/{clusterName}/namespaces/{namespaceName}/items")
  public ItemDTO create(@PathVariable("appId") String appId,
                        @PathVariable("clusterName") String clusterName,
                        @PathVariable("namespaceName") String namespaceName, @RequestBody ItemDTO dto) {
    Item entity = BeanUtils.transform(Item.class, dto); // 将 ItemDTO 转换成 Item 对象

    ConfigChangeContentBuilder builder = new ConfigChangeContentBuilder(); // 创建 ConfigChangeContentBuilder 对象
    Item managedEntity = itemService.findOne(appId, clusterName, namespaceName, entity.getKey());
    if (managedEntity != null) { // 校验对应的 Item 是否已经存在。若是，抛出 BadRequestException 异常
      throw new BadRequestException("item already exists");
    }
    entity = itemService.save(entity); // 保存 Item 对象
    builder.createItem(entity); // 添加到 ConfigChangeContentBuilder 中
    dto = BeanUtils.transform(ItemDTO.class, entity); // 将 Item 转换成 ItemDTO 对象
    // 创建 Commit 对象
    Commit commit = new Commit();
    commit.setAppId(appId);
    commit.setClusterName(clusterName);
    commit.setNamespaceName(namespaceName);
    commit.setChangeSets(builder.build());
    commit.setDataChangeCreatedBy(dto.getDataChangeLastModifiedBy());
    commit.setDataChangeLastModifiedBy(dto.getDataChangeLastModifiedBy());
    commitService.save(commit); // 保存 Commit 对象

    return dto;
  }
  // ... 省略其他接口和属性
}
```

- **POST `/apps/{appId}/clusters/{clusterName}/namespaces/{namespaceName}/items` 接口**，Request Body 传递 **JSON** 对象。
- 第 16 行：调用 `BeanUtils#transfrom(Class<T> clazz, Object src)` 方法，将 ItemDTO **转换**成 Item 对象。
- 第 18 行：创建 ConfigChangeContentBuilder 对象。
- 第 19 至 22 行：调用 `ItemService#findOne(appId, clusterName, namespaceName, key)` 方法，**校验**对应的 Item 是否已经存在。若是，抛出 BadRequestException 异常。
- 第 25 行：调用 `ItemService#save(Item)` 方法，保存 Item 对象。
- 第 27 行：调用 `ConfigChangeContentBuilder#createItem(Item)` 方法，添加到 ConfigChangeContentBuilder 中。
- 第 30 行：调用 `BeanUtils#transfrom(Class<T> clazz, Object src)` 方法，将 Item **转换**成 ItemDTO 对象。
- 第 31 至 38 行：创建 Commit 对象。
- 第 40 行：调用 `CommitService#save(Commit)` 方法，保存 Commit 对象。

## 4.2 ItemService

在 `apollo-biz` 项目中，`com.ctrip.framework.apollo.biz.service.ItemService` ，提供 Item 的 **Service** 逻辑给 Admin Service 和 Config Service 。

`#save(Item)` 方法，保存 Item 对象 。代码如下：

```java
@Service
public class ItemService {

  private final ItemRepository itemRepository;
  private final NamespaceService namespaceService;
  private final AuditService auditService;
  private final BizConfig bizConfig;

  @Transactional
  public Item save(Item entity) {
    checkItemKeyLength(entity.getKey()); // 校验 Key 长度
    checkItemValueLength(entity.getNamespaceId(), entity.getValue()); // 校验 Value 长度

    entity.setId(0);//protection
    // 设置 Item 的行号，以 Namespace 下的 Item 最大行号 + 1 。
    if (entity.getLineNum() == 0) {
      Item lastItem = findLastOne(entity.getNamespaceId());
      int lineNum = lastItem == null ? 1 : lastItem.getLineNum() + 1;
      entity.setLineNum(lineNum);
    }
    // 保存 Item
    Item item = itemRepository.save(entity);
    // 记录 Audit 到数据库中
    auditService.audit(Item.class.getSimpleName(), item.getId(), Audit.OP.INSERT,
                       item.getDataChangeCreatedBy());

    return item;
  }
  // ... 省略其他接口和属性
}
```

- 第 9 行：调用 `#checkItemKeyLength(key)`方法，校验 Key 长度。

  - 可配置 `"item.value.length.limit"` 在 ServerConfig 配置最大长度。
  - 默认最大长度为 128 。

- 第 11 行：调用`#checkItemValueLength(namespaceId, value)`方法，校验 Value 长度。

  - 全局可配置 `"item.value.length.limit"` 在 ServerConfig 配置最大长度。
  - **自定义**配置 `"namespace.value.length.limit.override"` 在 ServerConfig 配置最大长度。
  - 默认最大长度为 20000 。

- 第 14 至 19 行：设置 Item 的行号，以 Namespace 下的 Item **最大**行号 + 1 。`#findLastOne(namespaceId)` 方法，获得最大行号的 Item 对象，代码如下：

  ```java
  public Item findLastOne(long namespaceId) {
      return itemRepository.findFirst1ByNamespaceIdOrderByLineNumDesc(namespaceId);
  }
  ```

- 第 21 行：调用 `ItemRepository#save(Item)` 方法，保存 Item 。

- 第 23 行：记录 Audit 到数据库中

## 4.3 ItemRepository

`com.ctrip.framework.apollo.biz.repository.ItemRepository` ，继承 `org.springframework.data.repository.PagingAndSortingRepository` 接口，提供 Item 的**数据访问** 给 Admin Service 和 Config Service 。代码如下：

````java
public interface ItemRepository extends PagingAndSortingRepository<Item, Long> {

  Item findByNamespaceIdAndKey(Long namespaceId, String key);

  List<Item> findByNamespaceIdOrderByLineNumAsc(Long namespaceId);

  List<Item> findByNamespaceId(Long namespaceId);

  List<Item> findByNamespaceIdAndDataChangeLastModifiedTimeGreaterThan(Long namespaceId, Date date);

  Page<Item> findByKey(String key, Pageable pageable);
  
  Item findFirst1ByNamespaceIdOrderByLineNumDesc(Long namespaceId);

  @Modifying
  @Query("update Item set IsDeleted = 1, DeletedAt = ROUND(UNIX_TIMESTAMP(NOW(4))*1000), DataChange_LastModifiedBy = ?2 where namespaceId = ?1")
  int deleteByNamespaceId(long namespaceId, String operator);

}
````

## 4.4 CommitService

在 `apollo-biz` 项目中，`com.ctrip.framework.apollo.biz.service.CommitService` ，提供 Commit 的 **Service** 逻辑给 Admin Service 和 Config Service 。

`#save(Commit)` 方法，保存 Item 对象 。代码如下：

```java
@Service
public class CommitService {

  private final CommitRepository commitRepository;
  
  @Transactional
  public Commit save(Commit commit){
    commit.setId(0);//protection
    return commitRepository.save(commit); // 保存 Commit
  }
  // ... 省略其他接口和属性
}
```

## 4.5 CommitRepository

`com.ctrip.framework.apollo.biz.repository.CommitRepository` ，继承 `org.springframework.data.repository.PagingAndSortingRepository` 接口，提供 Commit 的**数据访问** 给 Admin Service 和 Config Service 。代码如下：

```java
public interface CommitRepository extends PagingAndSortingRepository<Commit, Long> {

  List<Commit> findByAppIdAndClusterNameAndNamespaceNameOrderByIdDesc(String appId, String clusterName,
                                                                      String namespaceName, Pageable pageable);

  List<Commit> findByAppIdAndClusterNameAndNamespaceNameAndDataChangeLastModifiedTimeGreaterThanEqualOrderByIdDesc(
      String appId, String clusterName, String namespaceName, Date dataChangeLastModifiedTime, Pageable pageable);

  @Modifying
  @Query("update Commit set IsDeleted = 1, DeletedAt = ROUND(UNIX_TIMESTAMP(NOW(4))*1000), DataChange_LastModifiedBy = ?4 where appId=?1 and clusterName=?2 and namespaceName = ?3")
  int batchDelete(String appId, String clusterName, String namespaceName, String operator);

  List<Commit> findByAppIdAndClusterNameAndNamespaceNameAndChangeSetsLikeOrderByIdDesc(String appId, String clusterName, String namespaceName,String changeSets, Pageable page);
}
```



# 参考

[Apollo 源码解析 —— Portal 创建 Item](https://www.iocoder.cn/Apollo/portal-create-item/)
