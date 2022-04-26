# 1. 概述

> 老艿艿：本系列假定胖友已经阅读过 [《Apollo 官方 wiki 文档》](https://github.com/ctripcorp/apollo/wiki/) ，特别是 [《Apollo 官方 wiki 文档 —— 灰度发布使用指南》](https://github.com/ctripcorp/apollo/wiki/Apollo使用指南#五灰度发布使用指南)。

本文分享 **Portal 配置灰度规则** 的流程，整个过程涉及 Portal、Admin Service ，如下图所示：![流程](http://blog-1259650185.cosbj.myqcloud.com/img/202204/06/1649215472.png)

- 对于一个**子** Namespace 仅对应一条**有效**灰度规则 GrayReleaseRule 记录。每次变更灰度规则时，**标记删除**老的灰度规则，**新增保存**新的灰度规则。
- 变更灰度配置完成后，会发布一条 ReleaseMessage 消息，以通知配置变更。

# 2. GrayReleaseRule

在 `apollo-common` 项目中，`com.ctrip.framework.apollo.common.entity.GrayReleaseRule` ，继承 BaseEntity 抽象类，GrayReleaseRule **实体**。代码如下：

```java
@Entity
@Table(name = "GrayReleaseRule")
@SQLDelete(sql = "Update GrayReleaseRule set isDeleted = 1 where id = ?")
@Where(clause = "isDeleted = 0")
public class GrayReleaseRule extends BaseEntity {

    /**
     * App 编号
     */
    @Column(name = "appId", nullable = false)
    private String appId;
    /**
     * Cluster 名字
     */
    @Column(name = "ClusterName", nullable = false)
    private String clusterName;
    /**
     * Namespace 名字
     */
    @Column(name = "NamespaceName", nullable = false)
    private String namespaceName;
    /**
     * Branch 名，使用子 Cluster 名字
     */
    @Column(name = "BranchName", nullable = false)
    private String branchName;
    /**
     * 规则，目前将 {@link com.ctrip.framework.apollo.common.dto.GrayReleaseRuleItemDTO} 的数组，JSON 格式化
     */
    @Column(name = "Rules")
    private String rules;
    /**
     * Release 编号。
     *
     * 有两种情况：
     * 1、当灰度已经发布，则指向对应的最新的 Release 对象的编号
     * 2、当灰度还未发布，等于 0 。等到灰度发布后，更新为对应的 Release 对象的编号
     */
    @Column(name = "releaseId", nullable = false)
    private Long releaseId;
    /**
     * 分支状态，在 {@link com.ctrip.framework.apollo.common.constants.NamespaceBranchStatus} 枚举
     */
    @Column(name = "BranchStatus", nullable = false)
    private int branchStatus;
}
```

- `appId` + `clusterName` + `namespaceName` + `branchName` 四个字段，指向对应的**子** Namespace 对象。

- `rules` 字段，规则**数组**，目前将 GrayReleaseRuleItemDTO 数组，**JSON** 格式化进行存储。详细解析，见 [「2.1 GrayReleaseRuleItemDTO」](https://www.iocoder.cn/Apollo/portal-modify-namespace-branch-gray-rules/#) 。字段存储例子如下：

  ```
  [{"clientAppId":"233","clientIpList":["10.12.13.14","20.23.12.15"]}]
  ```

- `release` 字段，Release 编号。目前有**两种**情况：

  - 1、当灰度**已经发布**，则指向对应的最新的 Release 对象的编号。
  - 2、当灰度**还未发布**，等于 0 。等到灰度发布后，更新为对应的 Release 对象的编号。

- `branchStatus` 字段，Namespace 分支状态。在 `com.ctrip.framework.apollo.common.constants.NamespaceBranchStatus` 中，枚举如下：

  ```java
  public interface NamespaceBranchStatus {
  
      /**
       * 删除
       */
      int DELETED = 0;
      /**
       * 激活（有效）
       */
      int ACTIVE = 1;
      /**
       * 合并
       */
      int MERGED = 2;
  
  }
  ```

## 2.1 GrayReleaseRuleItemDTO

`com.ctrip.framework.apollo.common.dto.GrayReleaseRuleItemDTO` ，GrayRelease 规则**项** DTO 。代码如下：

```java
public class GrayReleaseRuleItemDTO {
  public static final String ALL_IP = "*";
  public static final String ALL_Label = "*";

  private String clientAppId; // 客户端 App 编号
  private Set<String> clientIpList; // 客户端 IP 集合
  private Set<String> clientLabelList; // 客户端 标签 集合
	
  // 匹配方法 BEGIN
  public boolean matches(String clientAppId, String clientIp,String clientLabel) {
    return (appIdMatches(clientAppId) && ipMatches(clientIp))||(appIdMatches(clientAppId) && labelMatches(clientLabel));
  }

  private boolean appIdMatches(String clientAppId) {
    return this.clientAppId.equalsIgnoreCase(clientAppId);
  }

  private boolean ipMatches(String clientIp) {
    return this.clientIpList.contains(ALL_IP) || clientIpList.contains(clientIp);
  }

  private boolean labelMatches(String clientLabel) {
    return this.clientLabelList.contains(ALL_Label) || clientLabelList.contains(clientLabel);
  }
  // 匹配方法 END

  // ... 省略其他接口和属性
}
```

- 为什么会有 `clientAppId` 字段呢？对于**公共** Namespace 的灰度规则，需要先指定要灰度的 appId ，然后再选择 IP 。如下图：![编辑灰度规则5](http://blog-1259650185.cosbj.myqcloud.com/img/202204/06/1649215668.png)

  - 这样设计的初衷是什么？笔者请教了宋老师( Apollo 的作者 ) ：

    > 默认公共 namespace 就允许被所有应用使用的，可以认为是一个隐性的关联。
    >
    > 在应用界面上的关联是为了覆盖公共配置使用的。
    >
    > 客户端的 appId 是获取自己的配置，公共配置的获取不需要 appid 。

    - 从而实现**公用类型**的 Namespace ，可以设置对任意 App 灰度发布。双击 666 。

# 3. Portal 侧

## 3.1 NamespaceBranchController

在 `apollo-portal` 项目中，`com.ctrip.framework.apollo.portal.controller.NamespaceBranchController` ，提供 Namespace **分支**的 **API** 。

> 切换到灰度规则 Tab ，点击【新增规则】按钮。
>
> ![新增规则](https://static.iocoder.cn/images/Apollo/2018_05_05/02.png)
>
> 在弹出框中【灰度的 IP】下拉框会默认展示当前使用配置的机器列表，选择我们要灰度的 IP，点击完成。
>
> ![编辑灰度规则1](https://static.iocoder.cn/images/Apollo/2018_05_05/03.png)
> ![编辑灰度规则2](https://static.iocoder.cn/images/Apollo/2018_05_05/04.png)
> ![规则列表](https://static.iocoder.cn/images/Apollo/2018_05_05/05.png)
>
> 如果下拉框中没找到需要的IP，说明机器还没从Apollo取过配置，可以点击手动输入IP来输入，输入完后点击添加按钮
> ![编辑灰度规则3](https://static.iocoder.cn/images/Apollo/2018_05_05/06.png)
> ![编辑灰度规则4](https://static.iocoder.cn/images/Apollo/2018_05_05/07.png)

`#updateBranchRules(...)` 方法， 更新 Namespace **分支**的灰度规则。代码如下：

```java
@PreAuthorize(value = "@permissionValidator.hasOperateNamespacePermission(#appId, #namespaceName, #env)")
@PutMapping(value = "/apps/{appId}/envs/{env}/clusters/{clusterName}/namespaces/{namespaceName}/branches/{branchName}/rules")
public void updateBranchRules(@PathVariable String appId, @PathVariable String env,
                              @PathVariable String clusterName, @PathVariable String namespaceName,
                              @PathVariable String branchName, @RequestBody GrayReleaseRuleDTO rules) {

  namespaceBranchService
      .updateBranchGrayRules(appId, Env.valueOf(env), clusterName, namespaceName, branchName, rules);

}
```

- **PUT `"apps/{appId}/envs/{env}/clusters/{clusterName}/namespaces/{namespaceName}/branches/{branchName}/rules` 接口** 。

- `@PreAuthorize(...)` 注解，调用 `PermissionValidator#hasOperateNamespacePermission(appId, namespaceName)` 方法，校验是否有**操作** Namespace 的权限。后续文章，详细分享。

- `com.ctrip.framework.apollo.common.dto.GrayReleaseRuleDTO` ，灰度发布规则 DTO ，代码如下：

  ```java
  public class GrayReleaseRuleDTO extends BaseDTO {
  
    private String appId; // App 编号
  
    private String clusterName; // Cluster 名字
  
    private String namespaceName; // Namespace 名字
  
    private String branchName; // Branch 名字
  
    private Set<GrayReleaseRuleItemDTO> ruleItems; // GrayReleaseRuleItemDTO 数组
  
    private Long releaseId; // Release 编号。更新灰度发布规则时，该参数不会传递
    // ... 省略其他接口和属性
  }
  ```

- 调用 `NamespaceBranchService#updateBranchGrayRules(...)` 方法，更新 Namespace **分支**的灰度规则。

## 3.2 NamespaceBranchService

在 `apollo-portal` 项目中，`com.ctrip.framework.apollo.portal.service.NamespaceBranchService` ，提供 Namespace **分支**的 **Service** 逻辑。

`#createItem(appId, env, clusterName, namespaceName, ItemDTO)` 方法，创建并保存 Item 到 Admin Service 。代码如下：

```java
// 更新 Namespace 分支的灰度规则
public void updateBranchGrayRules(String appId, Env env, String clusterName, String namespaceName,
                                  String branchName, GrayReleaseRuleDTO rules) {

  String operator = userInfoHolder.getUser().getUserId(); // 设置 GrayReleaseRuleDTO 的创建和修改人为当前管理员
  updateBranchGrayRules(appId, env, clusterName, namespaceName, branchName, rules, operator);
}
// 更新 Namespace 分支的灰度规则
public void updateBranchGrayRules(String appId, Env env, String clusterName, String namespaceName,
                                  String branchName, GrayReleaseRuleDTO rules, String operator) {
  rules.setDataChangeCreatedBy(operator);
  rules.setDataChangeLastModifiedBy(operator);
  // 更新 Namespace 分支的灰度规则
  namespaceBranchAPI.updateBranchGrayRules(appId, env, clusterName, namespaceName, branchName, rules);

  Tracer.logEvent(TracerEventType.UPDATE_GRAY_RELEASE_RULE,
          String.format("%s+%s+%s+%s", appId, env, clusterName, namespaceName));
}
```

- 第 8 至 11 行：设置 GrayReleaseRuleDTO 的创建和修改人为当前管理员。
- 第 13 行：调用 `NamespaceBranchAPI#updateBranchGrayRules(...)` 方法，更新 Namespace 分支的灰度规则。
- 第 15 行：Tracer 日志

## 3.3 NamespaceBranchAPI

`com.ctrip.framework.apollo.portal.api.NamespaceBranchAPI` ，实现 API 抽象类，封装对 Admin Service 的 Namespace **分支**模块的 API 调用。代码如下：

![NamespaceBranchAPI](http://blog-1259650185.cosbj.myqcloud.com/img/202204/06/1649220029.png)

# 4. Admin Service 侧

## 4.1 NamespaceBranchController

在 `apollo-adminservice` 项目中， `com.ctrip.framework.apollo.adminservice.controller.NamespaceBranchController` ，提供 Namespace **分支**的 **API** 。

`#updateBranchGrayRules(...)` 方法，更新 Namespace **分支**的灰度规则。代码如下

```java
@Transactional
@PutMapping("/apps/{appId}/clusters/{clusterName}/namespaces/{namespaceName}/branches/{branchName}/rules")
public void updateBranchGrayRules(@PathVariable String appId, @PathVariable String clusterName,
                                  @PathVariable String namespaceName, @PathVariable String branchName,
                                  @RequestBody GrayReleaseRuleDTO newRuleDto) {
  // 校验子 Namespace
  checkBranch(appId, clusterName, namespaceName, branchName);
  // 将 GrayReleaseRuleDTO 转成 GrayReleaseRule 对象
  GrayReleaseRule newRules = BeanUtils.transform(GrayReleaseRule.class, newRuleDto);
  newRules.setRules(GrayReleaseRuleItemTransformer.batchTransformToJSON(newRuleDto.getRuleItems()));  // JSON 化规则为字符串，并设置到 GrayReleaseRule 对象中
  newRules.setBranchStatus(NamespaceBranchStatus.ACTIVE); // 设置 GrayReleaseRule 对象的 branchStatus 为 ACTIVE
  // 更新子 Namespace 的灰度发布规则
  namespaceBranchService.updateBranchGrayRules(appId, clusterName, namespaceName, branchName, newRules);
  // 发送 Release 消息
  messageSender.sendMessage(ReleaseMessageKeyGenerator.generate(appId, clusterName, namespaceName),
                            Topics.APOLLO_RELEASE_TOPIC);
}
```

- 第 14 行：调用 `#checkBranch(appId, clusterName, namespaceName, branchName)` ，**校验**子 Namespace 是否存在。代码如下：

  ```java
  private void checkBranch(String appId, String clusterName, String namespaceName, String branchName) {
      // 校验 Namespace 是否存在
      // 1. check parent namespace
      checkNamespace(appId, clusterName, namespaceName);
  
      // 校验子 Namespace 是否存在。若不存在，抛出 BadRequestException 异常
      // 2. check child namespace
      Namespace childNamespace = namespaceService.findOne(appId, branchName, namespaceName);
      if (childNamespace == null) {
          throw new BadRequestException(String.format("Namespace's branch not exist. AppId = %s, ClusterName = %s, "
                          + "NamespaceName = %s, BranchName = %s", appId, clusterName, namespaceName, branchName));
      }
  }
  ```

- 第 17 行：调用 `BeanUtils#transfrom(Class<T> clazz, Object src)` 方法，将 GrayReleaseRuleDTO **转换**成 GrayReleaseRule 对象。

- 第 19 行：调用 `GrayReleaseRuleItemTransformer#batchTransformToJSON(et<GrayReleaseRuleItemDTO> ruleItems)` 方法，**JSON** 化规则为字符串，并设置到 GrayReleaseRule 对象中。代码如下：

  ```java
  private static final Gson gson = new Gson();
  
  public static String batchTransformToJSON(Set<GrayReleaseRuleItemDTO> ruleItems) {
      return gson.toJson(ruleItems);
  }
  ```

- 第 21 行：设置 GrayReleaseRule 对象的 `branchStatus` 为 **ACTIVE** 。
- 第 23 行：调用 `NamespaceBranchService#updateBranchGrayRules(appId, clusterName, namespaceName, branchName, newRules)` 方法，更新**子** Namespace 的灰度发布规则。详细解析，见 [「3.2 NamespaceBranchService」](https://www.iocoder.cn/Apollo/portal-modify-namespace-branch-gray-rules/#) 。
- 第 25 行：调用 `MessageSender#sendMessage(message, channel)` 方法，发送 Release 消息，**从而通知客户端更新配置**。

## 4.2 NamespaceBranchService

在 `apollo-biz` 项目中，`com.ctrip.framework.apollo.biz.service.NamespaceBranchService` ，提供 Namespace **分支**的 **Service** 逻辑给 Admin Service 和 Config Service 。

`#updateBranchGrayRules(appId, clusterName, namespaceName, branchName, newRules)` 方法，更新**子** Namespace 的灰度发布规则。代码如下：

```java
@Transactional
public void updateBranchGrayRules(String appId, String clusterName, String namespaceName,
                                  String branchName, GrayReleaseRule newRules) {
  doUpdateBranchGrayRules(appId, clusterName, namespaceName, branchName, newRules, true, ReleaseOperation.APPLY_GRAY_RULES);
}

private void doUpdateBranchGrayRules(String appId, String clusterName, String namespaceName,
                                            String branchName, GrayReleaseRule newRules, boolean recordReleaseHistory, int releaseOperation) {
  GrayReleaseRule oldRules = grayReleaseRuleRepository // 获得子 Namespace 的灰度发布规则
      .findTopByAppIdAndClusterNameAndNamespaceNameAndBranchNameOrderByIdDesc(appId, clusterName, namespaceName, branchName);
  // 获得最新的子 Namespace 的 Release 对象
  Release latestBranchRelease = releaseService.findLatestActiveRelease(appId, branchName, namespaceName);
  // 获得最新的子 Namespace 的 Release 对象的编号
  long latestBranchReleaseId = latestBranchRelease != null ? latestBranchRelease.getId() : 0;
  // 设置 GrayReleaseRule 的 `releaseId`
  newRules.setReleaseId(latestBranchReleaseId);
  // 保存新的 GrayReleaseRule 对象
  grayReleaseRuleRepository.save(newRules);
  // 删除老的 GrayReleaseRule 对象
  //delete old rules
  if (oldRules != null) {
    grayReleaseRuleRepository.delete(oldRules);
  }

  if (recordReleaseHistory) { // 若需要，创建 ReleaseHistory 对象，并保存
    Map<String, Object> releaseOperationContext = Maps.newHashMap();
    releaseOperationContext.put(ReleaseOperationContext.RULES, GrayReleaseRuleItemTransformer
        .batchTransformFromJSON(newRules.getRules()));
    if (oldRules != null) {
      releaseOperationContext.put(ReleaseOperationContext.OLD_RULES,
          GrayReleaseRuleItemTransformer.batchTransformFromJSON(oldRules.getRules()));
    }
    releaseHistoryService.createReleaseHistory(appId, clusterName, namespaceName, branchName, latestBranchReleaseId,
        latestBranchReleaseId, releaseOperation, releaseOperationContext, newRules.getDataChangeLastModifiedBy());
  }
}
```

- 第 15 行：调用 `GrayReleaseRuleRepository#findTopByAppIdAndClusterNameAndNamespaceNameAndBranchNameOrderByIdDesc(appId, clusterName, namespaceName, branchName)` 方法，获得**子** Namespace 的灰度发布规则。
- Release Id 相关：
  - 第 16 行：调用 `ReleaseService#findLatestActiveRelease(appId, branchName, namespaceName)` 方法，获得**最新的**，并且**有效的**，**子** Namespace 的 Release 对象。
  - 第 19 行：获得最新的**子** Namespace 的 Release 对象的编号。若不存在，则设置为 **0** 。
  - 第 21 行：设置 GrayReleaseRule 的 `releaseId` 属性。
- 第 23 行：调用 `GrayReleaseRuleRepository#save(GrayReleaseRule)` 方法，保存**新的** GrayReleaseRule 对象。
- 第 25 至 29 行：删除**老的** GrayReleaseRule 对象。
- 第 31 至 40 行：若需要，调用 `ReleaseHistoryService#createReleaseHistory(...)` 方法，创建 ReleaseHistory 对象，并保存。其中，`ReleaseHistory.operation` 属性，为 **APPLY_GRAY_RULES** 。

## 4.3 GrayReleaseRuleRepository

`com.ctrip.framework.apollo.biz.repository.GrayReleaseRuleRepository` ，继承 `org.springframework.data.repository.PagingAndSortingRepository` 接口，提供 GrayReleaseRule 的**数据访问** 给 Admin Service 和 Config Service 。代码如下：

```java
public interface GrayReleaseRuleRepository extends PagingAndSortingRepository<GrayReleaseRule, Long> {

  GrayReleaseRule findTopByAppIdAndClusterNameAndNamespaceNameAndBranchNameOrderByIdDesc(String appId, String clusterName,
                                                                                         String namespaceName, String branchName);

  List<GrayReleaseRule> findByAppIdAndClusterNameAndNamespaceName(String appId,
                                                               String clusterName, String namespaceName);

  List<GrayReleaseRule> findFirst500ByIdGreaterThanOrderByIdAsc(Long id);

}
```



# 参考

[Apollo 源码解析 —— Portal 配置灰度规则](https://www.iocoder.cn/Apollo/portal-modify-namespace-branch-gray-rules/)
