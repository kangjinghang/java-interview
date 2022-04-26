# 1. 概述

> 老艿艿：本系列假定胖友已经阅读过 [《Apollo 官方 wiki 文档》](https://github.com/ctripcorp/apollo/wiki/) 。

本文接 [《Apollo 源码解析 —— Portal 创建 Item》](http://www.iocoder.cn/Apollo/portal-create-item/?self) 文章，分享 Item 的**批量变更**。

- 对于 `yaml` `yml` `json` `xml` 数据类型的 Namespace ，仅有一条 Item 记录，所以批量修改实际是修改**该条** Item 。
- 对于 `properties` 数据类型的 Namespace ，有多条 Item 记录，所以批量变更是**多条** Item 。

整体流程如下图：

<img src="http://blog-1259650185.cosbj.myqcloud.com/img/202204/04/1649001758.png" alt="流程" style="zoom: 33%;" />

> 老艿艿：因为 Portal 是管理后台，所以从代码实现上，和业务系统非常相像。也因此，本文会略显啰嗦。

# 2. ItemChangeSets

`com.ctrip.framework.apollo.common.dto.ItemChangeSets` ，Item 变更**集合**。代码如下：

```java
public class ItemChangeSets extends BaseDTO{

  private List<ItemDTO> createItems = new LinkedList<>(); // 新增 Item 集合
  private List<ItemDTO> updateItems = new LinkedList<>(); // 修改 Item 集合
  private List<ItemDTO> deleteItems = new LinkedList<>(); // 删除 Item 集合

  public void addCreateItem(ItemDTO item) {
    createItems.add(item);
  }

  public void addUpdateItem(ItemDTO item) {
    updateItems.add(item);
  }

  public void addDeleteItem(ItemDTO item) {
    deleteItems.add(item);
  }

  public boolean isEmpty(){
    return createItems.isEmpty() && updateItems.isEmpty() && deleteItems.isEmpty();
  }
  
  // ... 省略 setting / getting 方法

}
```

# 3. ConfigTextResolver

在 `apollo-portal` 项目中， `com.ctrip.framework.apollo.portal.component.txtresolver.ConfigTextResolver` ，配置文本解析器**接口**。代码如下：

```java
public interface ConfigTextResolver {
  
  /**
   * 解析文本，创建 ItemChangeSets 对象
   *
   * @param namespaceId Namespace 编号
   * @param configText 配置文本
   * @param baseItems 已存在的 ItemDTO 们
   * @return ItemChangeSets 对象
   */
  ItemChangeSets resolve(long namespaceId, String configText, List<ItemDTO> baseItems);

}
```

## 3.1 FileTextResolver

`com.ctrip.framework.apollo.portal.component.txtresolver.FileTextResolver` ，实现 ConfigTextResolver 接口，**文件**配置文本解析器，适用于 `yaml`、`yml`、`json`、`xml` 格式。代码如下：

```java
@Override
public ItemChangeSets resolve(long namespaceId, String configText, List<ItemDTO> baseItems) {
  ItemChangeSets changeSets = new ItemChangeSets();
  if (CollectionUtils.isEmpty(baseItems) && StringUtils.isEmpty(configText)) { // 配置文本为空，不进行修改
    return changeSets;
  }
  if (CollectionUtils.isEmpty(baseItems)) {  // 不存在已有配置，创建 ItemDTO 到 ItemChangeSets 新增项
    changeSets.addCreateItem(createItem(namespaceId, 0, configText));
  } else { // 已存在配置，创建 ItemDTO 到 ItemChangeSets 修改项
    ItemDTO beforeItem = baseItems.get(0);
    if (!configText.equals(beforeItem.getValue())) {//update
      changeSets.addUpdateItem(createItem(namespaceId, beforeItem.getId(), configText));
    }
  }

  return changeSets;
}
```

- 第 3 行：创建 ItemChangeSets 对象。

- 第 4 至 7 行：若配置文件为**空**，不进行修改。

- 第 8 至 10 行：不存在已有配置( `baseItems` ) ，创建 ItemDTO 到 ItemChangeSets 新增项。

- 第 11 至 17 行：已存在配置，并且配置值**不相等**，创建 ItemDTO 到 ItemChangeSets 修改项。**注意**，选择了第一条 ItemDTO 进行对比，因为 `yaml` 等，有且仅有一条。

- `#createItem(long namespaceId, long itemId, String value)` 方法，创建 ItemDTO 对象。代码如下：

  ```java
  private ItemDTO createItem(long namespaceId, long itemId, String value) {
      ItemDTO item = new ItemDTO();
      item.setId(itemId);
      item.setNamespaceId(namespaceId);
      item.setValue(value);
      item.setLineNum(1);
      item.setKey(ConfigConsts.CONFIG_FILE_CONTENT_KEY);
      return item;
  }
  ```

## 3.2 PropertyResolver

`com.ctrip.framework.apollo.portal.component.txtresolver.PropertyResolver` ，实现 ConfigTextResolver 接口，`properties` 配置解析器。代码如下：

```java
private static final String KV_SEPARATOR = "=";
private static final String ITEM_SEPARATOR = "\n";

@Override
public ItemChangeSets resolve(long namespaceId, String configText, List<ItemDTO> baseItems) {
  // 创建 Item Map ，以 lineNum 为 键
  Map<Integer, ItemDTO> oldLineNumMapItem = BeanUtils.mapByKey("lineNum", baseItems);
  Map<String, ItemDTO> oldKeyMapItem = BeanUtils.mapByKey("key", baseItems);

  //remove comment and blank item map.
  oldKeyMapItem.remove("");
  // 按照拆分 Property 配置
  String[] newItems = configText.split(ITEM_SEPARATOR);
  Set<String> repeatKeys = new HashSet<>();
  if (isHasRepeatKey(newItems, repeatKeys)) { // 校验是否存在重复配置 Key 。若是，抛出 BadRequestException 异常
    throw new BadRequestException(String.format("Config text has repeated keys: %s, please check your input.", repeatKeys.toString()));
  }
  // 创建 ItemChangeSets 对象，并解析配置文件到 ItemChangeSets 中
  ItemChangeSets changeSets = new ItemChangeSets();
  Map<Integer, String> newLineNumMapItem = new HashMap<>();//use for delete blank and comment item
  int lineCounter = 1;
  for (String newItem : newItems) {
    newItem = newItem.trim();
    newLineNumMapItem.put(lineCounter, newItem);
    ItemDTO oldItemByLine = oldLineNumMapItem.get(lineCounter); // 使用行号，获得已存在的 ItemDTO

    //comment item
    if (isCommentItem(newItem)) {

      handleCommentLine(namespaceId, oldItemByLine, newItem, lineCounter, changeSets);

      //blank item
    } else if (isBlankItem(newItem)) { // 空白 Item

      handleBlankLine(namespaceId, oldItemByLine, lineCounter, changeSets);

      //normal item
    } else { // 普通 Item
      handleNormalLine(namespaceId, oldKeyMapItem, newItem, lineCounter, changeSets);
    }

    lineCounter++; // 行号计数 + 1
  }

  deleteCommentAndBlankItem(oldLineNumMapItem, newLineNumMapItem, changeSets);  // 删除注释和空行配置项
  deleteNormalKVItem(oldKeyMapItem, changeSets);  // 删除普通配置项

  return changeSets;
}
```

- 第 7 行：调用 `BeanUtils#mapByKey(String key, List<? extends Object> list)` 方法，创建 ItemDTO Map `oldLineNumMapItem` ，以 `lineNum` 属性为键。

- 第 9 至 10 行：调用`BeanUtils#mapByKey(String key, List<? extends Object> list)` 方法，创建 ItemDTO Map`oldKeyMapItem`，以`key`属性为键。

  - 移除 `key =""` 的原因是，移除**注释**和**空行**的配置项。

- 第 13 行：按照 `"\n"` 拆分 `properties` 配置。

- 第 15 至 17 行：调用 `#isHasRepeatKey(newItems)` 方法，**校验**是否存在重复配置 Key 。若是，抛出 BadRequestException 异常。代码如下：

  ```java
  private boolean isHasRepeatKey(String[] newItems, @NotNull Set<String> repeatKeys) {
    Set<String> keys = new HashSet<>();
    int lineCounter = 1; // 记录行数，用于报错提示，无业务逻辑需要。
    for (String item : newItems) {
      if (!isCommentItem(item) && !isBlankItem(item)) { // 排除注释和空行的配置项
        String[] kv = parseKeyValueFromItem(item);
        if (kv != null) {
          String key = kv[0].toLowerCase();
          if(!keys.add(key)){
            repeatKeys.add(key);
          }
        } else {
          throw new BadRequestException("line:" + lineCounter + " key value must separate by '='");
        }
      }
      lineCounter++;
    }
    return !repeatKeys.isEmpty();
  }
  ```

  - **基于 Set 做排重判断**。

- 第 19 至 44 行：创建 ItemChangeSets 对象，并解析配置文本到 ItemChangeSets 中。

  - 第 23 行：**循环** `newItems` 。

  - 第 27 行：使用**行号**，获得对应的**老的** ItemDTO 配置项。

  - ========== **注释**配置项 【基于**行数**】 ==========

  - 第 29 行：调用 `#isCommentItem(newItem)` 方法，判断是否为**注释**配置文本。代码如下：

    ```java
    private boolean isCommentItem(String line) {
        return line != null && (line.startsWith("#") || line.startsWith("!"));
    }
    ```

  - 第 30 行：调用 `#handleCommentLine(namespaceId, oldItemByLine, newItem, lineCounter, changeSets)` 方法，处理**注释**配置项。代码如下：

    ```java
    1: private void handleCommentLine(Long namespaceId, ItemDTO oldItemByLine, String newItem, int lineCounter, ItemChangeSets changeSets) {
    2:     String oldComment = oldItemByLine == null ? "" : oldItemByLine.getComment();
    3:     // create comment. implement update comment by delete old comment and create new comment
    4:     // 创建注释 ItemDTO 到 ItemChangeSets 的新增项，若老的配置项不是注释或者不相等。另外，更新注释配置，通过删除 + 添加的方式。
    5:     if (!(isCommentItem(oldItemByLine) && newItem.equals(oldComment))) {
    6:         changeSets.addCreateItem(buildCommentItem(0L, namespaceId, newItem, lineCounter));
    7:     }
    8: }
    ```

    - 创建注释 ItemDTO 到 ItemChangeSets 的**新增项**，若老的配置项*不是注释*或者*不相等*。另外，更新注释配置，通过**删除 + 添加**的方式。

    - `#buildCommentItem(id, namespaceId, comment, lineNum)` 方法，创建**注释** ItemDTO 对象。代码如下：

      ```java
      private ItemDTO buildCommentItem(Long id, Long namespaceId, String comment, int lineNum) {
        return buildNormalItem(id, namespaceId, "", "", comment, lineNum);
      }
      ```

      - `key` 和 `value` 的属性，使用 `""` 空串。

  - ========== **空行**配置项 【基于**行数**】 ==========

  - 第 32 行：调用 调用 `#isBlankItem(newItem)` 方法，判断是否为**空行**配置文本。代码如下：

    ```java
    private boolean isBlankItem(String line) {
      return  Strings.nullToEmpty(line).trim().isEmpty();
    }
    ```

  - 第 33 行：调用 `#handleBlankLine(namespaceId, oldItemByLine, lineCounter, changeSets)` 方法，处理**空行**配置项。代码如下：

    ```java
    1: private void handleBlankLine(Long namespaceId, ItemDTO oldItem, int lineCounter, ItemChangeSets changeSets) {
    2:     // 创建空行 ItemDTO 到 ItemChangeSets 的新增项，若老的不是空行。另外，更新空行配置，通过删除 + 添加的方式
    3:     if (!isBlankItem(oldItem)) {
    4:         changeSets.addCreateItem(buildBlankItem(0L, namespaceId, lineCounter));
    5:     }
    6: }
    ```

    - 创建**空行** ItemDTO 到 ItemChangeSets 的**新增项**，若老的*不是空行*。另外，更新空行配置，通过**删除 + 添加**的方式。

    - `#buildBlankItem(id, namespaceId, lineNum)` 方法，处理**空行**配置项。代码如下：

      ```java
      private ItemDTO buildBlankItem(Long id, Long namespaceId, int lineNum) {
        return buildNormalItem(id, namespaceId, "", "", "", lineNum);
      }
      ```

      - 和 `#buildCommentItem(...)` 的差异点是，`comment` 是 `""` 空串。

  - ========== **普通**配置项 【基于 **Key** 】 ==========

  - 第 36 行：调用 `#handleNormalLine(namespaceId, oldKeyMapItem, newItem, lineCounter, changeSets)` 方法，处理**普通**配置项。代码如下：

    ```java
     1: private void handleNormalLine(Long namespaceId, Map<String, ItemDTO> keyMapOldItem, String newItem,
     2:                               int lineCounter, ItemChangeSets changeSets) {
     3:     // 解析一行，生成 [key, value]
     4:     String[] kv = parseKeyValueFromItem(newItem);
     5:     if (kv == null) {
     6:         throw new BadRequestException("line:" + lineCounter + " key value must separate by '='");
     7:     }
     8:     String newKey = kv[0];
     9:     String newValue = kv[1].replace("\\n", "\n"); //handle user input \n
    10:     // 获得老的 ItemDTO 对象
    11:     ItemDTO oldItem = keyMapOldItem.get(newKey);
    12:     // 不存在，则创建 ItemDTO 到 ItemChangeSets 的添加项
    13:     if (oldItem == null) {//new item
    14:         changeSets.addCreateItem(buildNormalItem(0L, namespaceId, newKey, newValue, "", lineCounter));
    15:     // 如果值或者行号不相等，则创建 ItemDTO 到 ItemChangeSets 的修改项
    16:     } else if (!newValue.equals(oldItem.getValue()) || lineCounter != oldItem.getLineNum()) {//update item
    17:         changeSets.addUpdateItem(buildNormalItem(oldItem.getId(), namespaceId, newKey, newValue, oldItem.getComment(), lineCounter));
    18:     }
    19:     // 移除老的 ItemDTO 对象
    20:     keyMapOldItem.remove(newKey);
    21: }
    ```

    - 第 3 至 9 行：调用 `#parseKeyValueFromItem(newItem)` 方法，解析一行，生成 `[key, value]` 。代码如下：

      ```java
      private String[] parseKeyValueFromItem(String item) {
          int kvSeparator = item.indexOf(KV_SEPARATOR);
          if (kvSeparator == -1) {
              return null;
          }
          String[] kv = new String[2];
          kv[0] = item.substring(0, kvSeparator).trim();
          kv[1] = item.substring(kvSeparator + 1, item.length()).trim();
          return kv;
      }
      ```

    - 第 11 行：获得老的 ItemDTO 对象。

    - 第 12 至 14 行：若老的 Item DTO 对象**不存在**，则创建 ItemDTO 到 ItemChangeSets 的**新增**项。

    - 第 15 至 18 行：若老的 Item DTO 对象**存在**，且*值*或者*行数*不相等，则创建 ItemDTO 到 ItemChangeSets 的**修改**项。

    - 第 20 行：移除老的 ItemDTO 对象。这样，最终 `keyMapOldItem` 保留的是，需要**删除**的普通配置项，详细见 `#deleteNormalKVItem(oldKeyMapItem, changeSets)` 方法。

- 第 42 行：调用 `#deleteCommentAndBlankItem(oldLineNumMapItem, newLineNumMapItem, changeSets)` 方法，删除**注释**和**空行**配置项。代码如下：

  ```java
  private void deleteCommentAndBlankItem(Map<Integer, ItemDTO> oldLineNumMapItem,
                                         Map<Integer, String> newLineNumMapItem,
                                         ItemChangeSets changeSets) {
      for (Map.Entry<Integer, ItemDTO> entry : oldLineNumMapItem.entrySet()) {
          int lineNum = entry.getKey();
          ItemDTO oldItem = entry.getValue();
          String newItem = newLineNumMapItem.get(lineNum);
          // 添加到 ItemChangeSets 的删除项
          // 1. old is blank by now is not
          // 2. old is comment by now is not exist or modified
          if ((isBlankItem(oldItem) && !isBlankItem(newItem)) // 老的是空行配置项，新的不是空行配置项
                  || isCommentItem(oldItem) && (newItem == null || !newItem.equals(oldItem.getComment()))) { // 老的是注释配置项，新的不相等
              changeSets.addDeleteItem(oldItem);
          }
      }
  }
  ```

  - 将需要删除( *具体条件看注释* ) 的注释和空白配置项，添加到 ItemChangeSets 的**删除项**中。

- 第 44 行：调用 #deleteNormalKVItem(oldKeyMapItem, changeSets) 方法，删除普通配置项。代码如下：

  ```java
  private void deleteNormalKVItem(Map<String, ItemDTO> baseKeyMapItem, ItemChangeSets changeSets) {
      // 将剩余的配置项，添加到 ItemChangeSets 的删除项
      // surplus item is to be deleted
      for (Map.Entry<String, ItemDTO> entry : baseKeyMapItem.entrySet()) {
          changeSets.addDeleteItem(entry.getValue());
      }
  }
  ```

  - 将剩余的配置项( `oldLineNumMapItem` )，添加到 ItemChangeSets 的**删除项**。

🙂 整个方法比较冗长，建议胖友多多调试，有几个点特别需要注意：

- 对于**注释**和**空行**配置项，基于**行数**做比较。当发生变化时，使用**删除 + 创建**的方式。笔者的理解是，注释和空行配置项，是没有 Key ，每次变化都认为是**新的**。另外，这样也可以和**注释**和**空行**配置项被改成**普通**配置项，保持一致。例如，第一行原先是**注释**配置项，改成了**普通**配置项，从数据上也是**删除 + 创建**的方式。
- 对于**普通**配置项，基于 **Key** 做比较。例如，第一行原先是**普通**配置项，结果我们在敲了回车，在第一行添加了**注释**，那么认为是**普通**配置项修改了**行数**。

# 4. Portal 侧

## 4.1 ItemController

在 `apollo-portal` 项目中，`com.ctrip.framework.apollo.portal.controller.ItemController` ，提供 Item 的 **API** 。

在【**批量变更 Namespace 配置项**】的界面中，点击【 √ 】按钮，调用**批量变更 Namespace 的 Item 们的 API** 。

![批量变更 Namespace 配置项](https://static.iocoder.cn/images/Apollo/2018_03_20/02.png)

`#modifyItemsByText(appId, env, clusterName, namespaceName, NamespaceTextModel)` 方法，批量变更 Namespace 的 Item 们。代码如下：

```java
private final ItemService configService;

@PreAuthorize(value = "@permissionValidator.hasModifyNamespacePermission(#appId, #namespaceName, #env)")
@PutMapping(value = "/apps/{appId}/envs/{env}/clusters/{clusterName}/namespaces/{namespaceName}/items", consumes = {
    "application/json"})
public void modifyItemsByText(@PathVariable String appId, @PathVariable String env,
                              @PathVariable String clusterName, @PathVariable String namespaceName,
                              @RequestBody NamespaceTextModel model) {
  model.setAppId(appId); // 设置 PathVariable 到 model 中
  model.setClusterName(clusterName);
  model.setEnv(env);
  model.setNamespaceName(namespaceName);
  // 批量更新一个 Namespace 下的 Item 们
  configService.updateConfigItemByText(model);
}
```

- **POST `/apps/{appId}/envs/{env}/clusters/{clusterName}/namespaces/{namespaceName}/items` 接口**，Request Body 传递 **JSON** 对象。

- `@PreAuthorize(...)` 注解，调用 `PermissionValidator#hasModifyNamespacePermission(appId, namespaceName)` 方法，校验是否有**修改** Namespace 的权限。后续文章，详细分享。

- `com.ctrip.framework.apollo.portal.entity.model.NamespaceTextModel` ，Namespace 下的配置文本 Model 。代码如下：

  ```java
  public class NamespaceTextModel implements Verifiable {
  
    private String appId; // App 编号
    private String env; // Env 名
    private String clusterName; // Cluster 名
    private String namespaceName; // Namespace 名
    private long namespaceId; // Namespace 编号
    private String format; // 格式
    private String configText; // 配置文本
    private String operator;
  
    @Override
    public boolean isInvalid() {
      return StringUtils.isContainEmpty(appId, env, clusterName, namespaceName) || namespaceId <= 0;
    }
    
  }
  ```

  - 重点是 `configText` 属性，配置文本。

- 第 11 至 15 行：设置 PathVariable 变量，到 NamespaceTextModel 中 。

- 第 17 行：调用 `ItemService#updateConfigItemByText(NamespaceTextModel)` 方法，批量更新一个 Namespace 下的 Item **们** 。

## 4.2 ItemService

在 `apollo-portal` 项目中，`com.ctrip.framework.apollo.portal.service.ItemService` ，提供 Item 的 **Service** 逻辑。

`#updateConfigItemByText(NamespaceTextModel)` 方法，解析配置文本，并批量更新 Namespace 的 Item 们。代码如下：

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

  public ItemService(
      final UserInfoHolder userInfoHolder,
      final NamespaceAPI namespaceAPI,
      final ItemAPI itemAPI,
      final ReleaseAPI releaseAPI,
      final @Qualifier("fileTextResolver") ConfigTextResolver fileTextResolver,
      final @Qualifier("propertyResolver") ConfigTextResolver propertyResolver) {
    this.userInfoHolder = userInfoHolder;
    this.namespaceAPI = namespaceAPI;
    this.itemAPI = itemAPI;
    this.releaseAPI = releaseAPI;
    this.fileTextResolver = fileTextResolver;
    this.propertyResolver = propertyResolver;
  }


  /**
   * parse config text and update config items
   *
   * @return parse result
   */
  public void updateConfigItemByText(NamespaceTextModel model) {
    String appId = model.getAppId();
    Env env = model.getEnv();
    String clusterName = model.getClusterName();
    String namespaceName = model.getNamespaceName();

    NamespaceDTO namespace = namespaceAPI.loadNamespace(appId, env, clusterName, namespaceName);
    if (namespace == null) {
      throw new BadRequestException(
          "namespace:" + namespaceName + " not exist in env:" + env + ", cluster:" + clusterName);
    }
    long namespaceId = namespace.getId();

    // In case someone constructs an attack scenario
    if (model.getNamespaceId() != namespaceId) {
      throw new BadRequestException("Invalid request, item and namespace do not match!");
    }

    String configText = model.getConfigText();
    // 获得对应格式的 ConfigTextResolver 对象
    ConfigTextResolver resolver =
        model.getFormat() == ConfigFileFormat.Properties ? propertyResolver : fileTextResolver;
    // 解析成 ItemChangeSets
    ItemChangeSets changeSets = resolver.resolve(namespaceId, configText,
        itemAPI.findItems(appId, env, clusterName, namespaceName));
    if (changeSets.isEmpty()) {
      return;
    }
    // 设置修改人为当前管理员
    String operator = model.getOperator();
    if (StringUtils.isBlank(operator)) {
      operator = userInfoHolder.getUser().getUserId();
    }
    changeSets.setDataChangeLastModifiedBy(operator);
    // 调用 Admin Service API ，批量更新 Item 们
    updateItems(appId, env, clusterName, namespaceName, changeSets);
    // Tracer 日志
    Tracer.logEvent(TracerEventType.MODIFY_NAMESPACE_BY_TEXT,
        String.format("%s+%s+%s+%s", appId, env, clusterName, namespaceName));
    Tracer.logEvent(TracerEventType.MODIFY_NAMESPACE, String.format("%s+%s+%s+%s", appId, env, clusterName, namespaceName));
  }
```

- 第 21 行：获得对应**格式**( `format` )的 ConfigTextResolver 对象。

- 第 23 行：调用 `ItemAPI#findItems(appId, env, clusterName, namespaceName)` 方法，获得 Namespace 下所有的 ItemDTO 配置项们。

- 第 23 行：调用 `ConfigTextResolver#resolve(...)` 方法，解析配置文本，生成 ItemChangeSets 对象。

- 第 24 至 26 行：调用 `ItemChangeSets#isEmpty()` 方法，若无变更项，直接返回。

- 第 30 行：调用 `#updateItems(appId, env, clusterName, namespaceName, changeSets)` 方法，调用 Admin Service API ，批量更新 Namespace 下的 Item 们。代码如下：

  ```java
  public void updateItems(String appId, Env env, String clusterName, String namespaceName, ItemChangeSets changeSets) {
      itemAPI.updateItemsByChangeSet(appId, env, clusterName, namespaceName, changeSets);
  }
  ```

- 第 31 至 33 行：Tracer 日志

## 4.3 ItemAPI

`com.ctrip.framework.apollo.portal.api.ItemAPI` ，实现 API 抽象类，封装对 Admin Service 的 Item 模块的 API 调用。代码如下：

![ItemAPI](https://static.iocoder.cn/images/Apollo/2018_03_25/03.png)

# 5. Admin Service 侧

## 5.1 ItemSetController

在 `apollo-adminservice` 项目中， `com.ctrip.framework.apollo.adminservice.controller.ItemSetController` ，提供 Item **批量**的 **API** 。

`#create(appId, clusterName, namespaceName, ItemChangeSets)` 方法，批量更新 Namespace 下的 Item 们。代码如下：

```java
@RestController
public class ItemSetController {

  private final ItemSetService itemSetService;

  public ItemSetController(final ItemSetService itemSetService) {
    this.itemSetService = itemSetService;
  }

  @PreAcquireNamespaceLock
  @PostMapping("/apps/{appId}/clusters/{clusterName}/namespaces/{namespaceName}/itemset")
  public ResponseEntity<Void> create(@PathVariable String appId, @PathVariable String clusterName,
                                     @PathVariable String namespaceName, @RequestBody ItemChangeSets changeSet) {
    // 批量更新 Namespace 下的 Item 们
    itemSetService.updateSet(appId, clusterName, namespaceName, changeSet);

    return ResponseEntity.status(HttpStatus.OK).build();
  }

}
```

- **POST `/apps/{appId}/clusters/{clusterName}/namespaces/{namespaceName}/itemset` 接口**，Request Body 传递 **JSON** 对象。

## 5.2 ItemSetService

在 `apollo-biz` 项目中，`com.ctrip.framework.apollo.biz.service.ItemSetService` ，提供 Item **批量** 的 **Service** 逻辑给 Admin Service 和 Config Service 。

`#updateSet(Namespace, ItemChangeSets)` 方法，批量更新 Namespace 下的 Item 们。代码如下：

```java
@Service
public class ItemSetService {

  private final AuditService auditService;
  private final CommitService commitService;
  private final ItemService itemService;
  private final NamespaceService namespaceService;

  public ItemSetService(
      final AuditService auditService,
      final CommitService commitService,
      final ItemService itemService,
      final NamespaceService namespaceService) {
    this.auditService = auditService;
    this.commitService = commitService;
    this.itemService = itemService;
    this.namespaceService = namespaceService;
  }

  @Transactional
  public ItemChangeSets updateSet(Namespace namespace, ItemChangeSets changeSets){
    return updateSet(namespace.getAppId(), namespace.getClusterName(), namespace.getNamespaceName(), changeSets);
  }

  @Transactional
  public ItemChangeSets updateSet(String appId, String clusterName,
                                  String namespaceName, ItemChangeSets changeSet) {
    Namespace namespace = namespaceService.findOne(appId, clusterName, namespaceName);

    if (namespace == null) {
      throw new NotFoundException(String.format("Namespace %s not found", namespaceName));
    }

    String operator = changeSet.getDataChangeLastModifiedBy();
    ConfigChangeContentBuilder configChangeContentBuilder = new ConfigChangeContentBuilder();
    // 保存 Item 们
    if (!CollectionUtils.isEmpty(changeSet.getCreateItems())) {
      for (ItemDTO item : changeSet.getCreateItems()) {
        if (item.getNamespaceId() != namespace.getId()) {
          throw new BadRequestException("Invalid request, item and namespace do not match!");
        }

        Item entity = BeanUtils.transform(Item.class, item);
        entity.setDataChangeCreatedBy(operator);
        entity.setDataChangeLastModifiedBy(operator);
        Item createdItem = itemService.save(entity); // 保存 Item
        configChangeContentBuilder.createItem(createdItem); // 添加到 ConfigChangeContentBuilder 中
      }
      auditService.audit("ItemSet", null, Audit.OP.INSERT, operator); // 记录 Audit 到数据库中
    }
    // 更新 Item 们
    if (!CollectionUtils.isEmpty(changeSet.getUpdateItems())) {
      for (ItemDTO item : changeSet.getUpdateItems()) {
        Item entity = BeanUtils.transform(Item.class, item);

        Item managedItem = itemService.findOne(entity.getId());
        if (managedItem == null) {
          throw new NotFoundException(String.format("item not found.(key=%s)", entity.getKey()));
        }
        if (managedItem.getNamespaceId() != namespace.getId()) {
          throw new BadRequestException("Invalid request, item and namespace do not match!");
        }
        Item beforeUpdateItem = BeanUtils.transform(Item.class, managedItem);

        //protect. only value,comment,lastModifiedBy,lineNum can be modified
        managedItem.setValue(entity.getValue());
        managedItem.setComment(entity.getComment());
        managedItem.setLineNum(entity.getLineNum());
        managedItem.setDataChangeLastModifiedBy(operator);

        Item updatedItem = itemService.update(managedItem); // 更新 Item
        configChangeContentBuilder.updateItem(beforeUpdateItem, updatedItem); // 添加到 ConfigChangeContentBuilder 中

      }
      auditService.audit("ItemSet", null, Audit.OP.UPDATE, operator);  // 记录 Audit 到数据库中
    }
    // 删除 Item 们
    if (!CollectionUtils.isEmpty(changeSet.getDeleteItems())) {
      for (ItemDTO item : changeSet.getDeleteItems()) {
        Item deletedItem = itemService.delete(item.getId(), operator); // 删除 Item
        if (deletedItem.getNamespaceId() != namespace.getId()) {
          throw new BadRequestException("Invalid request, item and namespace do not match!");
        }
        configChangeContentBuilder.deleteItem(deletedItem); // 添加到 ConfigChangeContentBuilder 中
      }
      auditService.audit("ItemSet", null, Audit.OP.DELETE, operator); // 记录 Audit 到数据库中
    }

    if (configChangeContentBuilder.hasContent()){ // 创建 Commit 对象，并保存
      createCommit(appId, clusterName, namespaceName, configChangeContentBuilder.build(),
                   changeSet.getDataChangeLastModifiedBy());
    }

    return changeSet;

  }

  private void createCommit(String appId, String clusterName, String namespaceName, String configChangeContent,
                            String operator) {
    // 创建 Commit 对象
    Commit commit = new Commit();
    commit.setAppId(appId);
    commit.setClusterName(clusterName);
    commit.setNamespaceName(namespaceName);
    commit.setChangeSets(configChangeContent);
    commit.setDataChangeCreatedBy(operator);
    commit.setDataChangeLastModifiedBy(operator);
    commitService.save(commit); // 保存 Commit 对象
  }

}
```

- 第 21 至 34 行：**保存** Item 们。
- 第 35 至 56 行：**更新** Item 们。
  - 第 40 至 42 行：若更新的 Item 不存在，抛出 NotFoundException 异常，**事务回滚**。
- 第 57 至 67 行：**删除** Item 们。
  - 第 61 行：在 `ItemService#delete(long id, String operator)` 方法中，会**校验**删除的 Item 是否存在。若不存在，会抛出 IllegalArgumentException 异常，**事务回滚**。
- 第 69 至 71 行：调用 `ConfigChangeContentBuilder#hasContent()` 方法，判断若有变更，则调用 `#createCommit(appId, clusterName, namespaceName, configChangeContent, operator)` 方法，创建并保存 Commit 。



# 参考

[Apollo 源码解析 —— Portal 批量变更 Item](https://www.iocoder.cn/Apollo/portal-update-item-set/)
