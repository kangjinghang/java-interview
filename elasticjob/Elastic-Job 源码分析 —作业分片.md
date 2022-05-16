## 1. 概述

本文主要分享 **Elastic-Job-Lite 作业分片**。

涉及到主要类的类图如下

![img](http://blog-1259650185.cosbj.myqcloud.com/img/202204/28/1651161113.png)



- 粉色的类在 `com.dangdang.ddframe.job.lite.internal.sharding` 包下，实现了 Elastic-Job-Lite 作业分片。
- ShardingService，作业分片服务。
- ShardingNode，作业分片数据存储路径。
- ShardingListenerManager，作业分片监听管理器。

## 2. 作业分片条件

当作业满足分片条件时，不会**立即**进行作业分片分配，而是设置需要重新进行分片的**标记**，等到作业分片获取时，判断有该标记后**执行**作业分配。

设置需要重新进行分片的**标记**的代码如下：

```java
// ShardingService.java
/**
* 设置需要重新分片的标记.
*/
public void setReshardingFlag() {
   jobNodeStorage.createJobNodeIfNeeded(ShardingNode.NECESSARY);
}

// JobNodeStorage.java
/**
* 如果存在则创建作业节点.
* 如果作业根节点不存在表示作业已经停止, 不再继续创建节点.
* 
* @param node 作业节点名称
*/
public void createJobNodeIfNeeded(final String node) {
   if (isJobRootNodeExisted() && !isJobNodeExisted(node)) {
       regCenter.persist(jobNodePath.getFullPath(node), "");
   }
}
```

- 调用 `#setReshardingFlag()` 方法设置**需要重新分片的标记** `/${JOB_NAME}/leader/sharding/necessary`。该 Zookeeper 数据节点是**永久**节点，存储空串( `""` )，使用 zkClient 查看如下：

  ```java
  [zk: localhost:2181(CONNECTED) 2] ls /elastic-job-example-lite-java/javaSimpleJob/leader/sharding
  [necessary]
  [zk: localhost:2181(CONNECTED) 3] get /elastic-job-example-lite-java/javaSimpleJob/leader/sharding/necessary
  ```

- 设置标记之后，通过调用 `#isNeedSharding()` 方法即可判断是否需要重新分片。

  ```java
  // ShardingService.java
  /**
  * 判断是否需要重分片.
  * 
  * @return 是否需要重分片
  */
  public boolean isNeedSharding() {
     return jobNodeStorage.isJobNodeExisted(ShardingNode.NECESSARY);
  }
  
  // JobNodeStorage.java
  /**
  * 判断作业节点是否存在.
  * 
  * @param node 作业节点名称
  * @return 作业节点是否存在
  */
  public boolean isJobNodeExisted(final String node) {
     return regCenter.isExisted(jobNodePath.getFullPath(node));
  }
  ```

**设置需要重新进行分片有 4 种情况**

**第一种**，注册作业启动信息时。

```java
// SchedulerFacade.java
public void registerStartUpInfo(final boolean enabled) {
   // ... 省略无关代码
   // 设置 需要重新分片的标记
   shardingService.setReshardingFlag();
  // ... 省略无关代码
}s
```

**第二种**，作业分片总数( `JobCoreConfiguration.shardingTotalCount` )变化时。

```java
// ShardingTotalCountChangedJobListener.java
class ShardingTotalCountChangedJobListener extends AbstractJobListener {
   
   @Override
   protected void dataChanged(final String path, final Type eventType, final String data) {
       if (configNode.isConfigPath(path)
               && 0 != JobRegistry.getInstance().getCurrentShardingTotalCount(jobName)) {
           int newShardingTotalCount = LiteJobConfigurationGsonFactory.fromJson(data).getTypeConfig().getCoreConfig().getShardingTotalCount();
           if (newShardingTotalCount != JobRegistry.getInstance().getCurrentShardingTotalCount(jobName)) { // 作业分片总数变化
               // 设置需要重新分片的标记
               shardingService.setReshardingFlag();
               // 设置当前分片总数
               JobRegistry.getInstance().setCurrentShardingTotalCount(jobName, newShardingTotalCount);
           }
       }
   }
}
```

**第三种**，服务器变化时。

```java
// ShardingListenerManager.java
class ListenServersChangedJobListener extends AbstractJobListener {

   @Override
   protected void dataChanged(final String path, final Type eventType, final String data) {
       if (!JobRegistry.getInstance().isShutdown(jobName)
               && (isInstanceChange(eventType, path)
                   || isServerChange(path))) {
           shardingService.setReshardingFlag();
       }
   }
   
   private boolean isInstanceChange(final Type eventType, final String path) {
       return instanceNode.isInstancePath(path) && Type.NODE_UPDATED != eventType;
   }
   
   private boolean isServerChange(final String path) {
       return serverNode.isServerPath(path);
   }
}
```

- 服务器变化有**两种**情况。
- 第一种，`#isServerChange(...)` 服务器被开启或禁用。
- 第二种，`#isInstanceChange(...)` 作业节点新增或者移除。

**第四种**，在[《Elastic-Job-Lite 源码解析 —— 自诊断修复》](http://www.iocoder.cn/Elastic-Job/reconcile/?self)详细分享。

## 3. 分配作业分片项

调用 `ShardingService#shardingIfNecessary()` 方法，如果需要分片且当前节点为主节点, 则作业分片。

总体流程如下**顺序图**：

![img](http://blog-1259650185.cosbj.myqcloud.com/img/202204/28/1651161346.png)

实现代码如下：

```java
// ShardingService.java
/**
* 如果需要分片且当前节点为主节点, 则作业分片.
* 
* 如果当前无可用节点则不分片.
*/
public void shardingIfNecessary() {
   List<JobInstance> availableJobInstances = instanceService.getAvailableJobInstances();
   if (!isNeedSharding() // 判断是否需要重新分片
           || availableJobInstances.isEmpty()) {
       return;
   }
   // 【非主节点】等待 作业分片项分配完成
   if (!leaderService.isLeaderUntilBlock()) { // 判断是否为【主节点】
       blockUntilShardingCompleted();
       return;
   }
   // 【主节点】作业分片项分配
   // 等待 作业未在运行中状态
   waitingOtherJobCompleted();
   //
   LiteJobConfiguration liteJobConfig = configService.load(false);
   int shardingTotalCount = liteJobConfig.getTypeConfig().getCoreConfig().getShardingTotalCount();
   // 设置 作业正在重分片的标记
   log.debug("Job '{}' sharding begin.", jobName);
   jobNodeStorage.fillEphemeralJobNode(ShardingNode.PROCESSING, "");
   // 重置 作业分片项信息
   resetShardingInfo(shardingTotalCount);
   // 【事务中】设置 作业分片项信息
   JobShardingStrategy jobShardingStrategy = JobShardingStrategyFactory.getStrategy(liteJobConfig.getJobShardingStrategyClass());
   jobNodeStorage.executeInTransaction(new PersistShardingInfoTransactionExecutionCallback(jobShardingStrategy.sharding(availableJobInstances, jobName, shardingTotalCount)));
   log.debug("Job '{}' sharding complete.", jobName);
}
```

- 调用 `#isNeedSharding()` 方法判断是否需要重新分片。

- 调用 `LeaderService#isLeaderUntilBlock()` 方法判断是否为**主节点**。作业分片项的分配过程：

  - 【主节点】**执行**作业分片项分配。
  - 【非主节点】**等待**作业分片项分配完成。
  - `LeaderService#isLeaderUntilBlock()` 方法在[《Elastic-Job-Lite 源码分析 —— 主节点选举》「3. 选举主节点」](http://www.iocoder.cn/Elastic-Job/election/?self)有详细分享。

- 调用 `#blockUntilShardingCompleted()` 方法【非主节点】**等待**作业分片项分配完成。

  ```java
  private void blockUntilShardingCompleted() {
     while (!leaderService.isLeaderUntilBlock() // 当前作业节点不为【主节点】
             && (jobNodeStorage.isJobNodeExisted(ShardingNode.NECESSARY) // 存在作业需要重分片的标记
                 || jobNodeStorage.isJobNodeExisted(ShardingNode.PROCESSING))) { // 存在作业正在重分片的标记
         log.debug("Job '{}' sleep short time until sharding completed.", jobName);
         BlockUtils.waitingShortTime();
     }
  }
  ```

  - 调用 `#LeaderService#isLeaderUntilBlock()` 方法判断是否为**主节点**。为什么上面判断了一次，这里又判断一次？主节点作业分片项分配过程中，不排除自己挂掉了，此时【非主节点】若选举成主节点，无需继续等待，当然也不能等待，因为已经没节点在执行作业分片项分配，所有节点都会卡在这里。
  - 当 **作业需要重分片的标记**、**作业正在重分片的标记** 都不存在时，意味着作业分片项分配已经完成，下文 PersistShardingInfoTransactionExecutionCallback 类里我们会看到。

- 调用 `#waitingOtherJobCompleted()` 方法等待作业未在运行中状态。作业是否在运行中需要 `LiteJobConfiguration.monitorExecution = true`，[《Elastic-Job-Lite 源码分析 —— 作业执行》「4.6 执行普通触发的作业」](http://www.iocoder.cn/Elastic-Job/election/?self)有详细分享。

- 调用 `ConfigurationService#load(...)` 方法从注册中心获取作业配置( **非缓存** )，避免主节点本地作业配置可能非最新的，主要目的是获得作业分片总数( `shardingTotalCount` )。

- 调用 `jobNodeStorage.fillEphemeralJobNode(ShardingNode.PROCESSING, "")` 设置**作业正在重分片的标记** `/${JOB_NAME}/leader/sharding/processing`。该 Zookeeper 数据节点是**临时**节点，存储空串( `""` )，仅用于标记作业正在重分片，无特别业务逻辑。

- 调用 `#resetShardingInfo(...)` 方法**重置**作业分片信息。

  ```java
  private void resetShardingInfo(final int shardingTotalCount) {
    // 重置 有效的作业分片项
    for (int i = 0; i < shardingTotalCount; i++) {
        jobNodeStorage.removeJobNodeIfExisted(ShardingNode.getInstanceNode(i)); // 移除 `/${JOB_NAME}/sharding/${ITEM_ID}/instance`
        jobNodeStorage.createJobNodeIfNeeded(ShardingNode.ROOT + "/" + i); // 创建 `/${JOB_NAME}/sharding/${ITEM_ID}`
    }
    // 移除 多余的作业分片项
    int actualShardingTotalCount = jobNodeStorage.getJobNodeChildrenKeys(ShardingNode.ROOT).size();
    if (actualShardingTotalCount > shardingTotalCount) {
        for (int i = shardingTotalCount; i < actualShardingTotalCount; i++) {
            jobNodeStorage.removeJobNodeIfExisted(ShardingNode.ROOT + "/" + i); // 移除 `/${JOB_NAME}/sharding/${ITEM_ID}`
        }
    }
  }
  ```

- 调用 `JobShardingStrategy#sharding(...)` 方法**计算**每个节点分配的作业分片项。[《Elastic-Job-Lite 源码分析 —— 作业分片策略》](http://www.iocoder.cn/Elastic-Job/job-sharding-strategy/?self)有详细分享。

- 调用 `JobNodeStorage#executeInTransaction(...)` + `PersistShardingInfoTransactionExecutionCallback#execute()` 方法实现在**事务**中**设置**每个节点分配的作业分片项。

  ```java
  // PersistShardingInfoTransactionExecutionCallback.java
  class PersistShardingInfoTransactionExecutionCallback implements TransactionExecutionCallback {
     
     /**
      * 作业分片项分配结果
      * key：作业节点
      * value：作业分片项
      */
     private final Map<JobInstance, List<Integer>> shardingResults;
     
     @Override
     public void execute(final CuratorTransactionFinal curatorTransactionFinal) throws Exception {
         // 设置 每个节点分配的作业分片项
         for (Map.Entry<JobInstance, List<Integer>> entry : shardingResults.entrySet()) {
             for (int shardingItem : entry.getValue()) {
                 curatorTransactionFinal.create().forPath(jobNodePath.getFullPath(ShardingNode.getInstanceNode(shardingItem))
                         , entry.getKey().getJobInstanceId().getBytes()).and();
             }
         }
         // 移除 作业需要重分片的标记、作业正在重分片的标记
         curatorTransactionFinal.delete().forPath(jobNodePath.getFullPath(ShardingNode.NECESSARY)).and();
         curatorTransactionFinal.delete().forPath(jobNodePath.getFullPath(ShardingNode.PROCESSING)).and();
     }
  }
  
  // JobNodeStorage.java
  /**
  * 在事务中执行操作.
  * 
  * @param callback 执行操作的回调
  */
  public void executeInTransaction(final TransactionExecutionCallback callback) {
     try {
         CuratorTransactionFinal curatorTransactionFinal = getClient().inTransaction().check().forPath("/").and();
         callback.execute(curatorTransactionFinal);
         curatorTransactionFinal.commit();
     } catch (final Exception ex) {
         RegExceptionHandler.handleException(ex);
     }
  }
  ```

  - 设置**临时**数据节点 `/${JOB_NAME}/sharding/${ITEM_ID}/instance` 为分配的作业节点的作业实例主键( `jobInstanceId` )。使用 zkClient 查看如下：

  ```java
  [zk: localhost:2181(CONNECTED) 0] get /elastic-job-example-lite-java/javaSimpleJob/sharding/0/instance
  192.168.3.2@-@31492
  ```

## 4. 获取作业分片上下文集合

在[《Elastic-Job-Lite 源码分析 —— 作业执行的》「4.2 获取当前作业服务器的分片上下文」](http://www.iocoder.cn/Elastic-Job/job-execute/?self)中，我们可以看到作业执行器( AbstractElasticJobExecutor ) 执行作业时，会获取当前作业服务器的分片上下文进行执行。获取过程总体如下顺序图：

![img](http://blog-1259650185.cosbj.myqcloud.com/img/202204/28/1651161382.png)

- 橘色叉叉在[《Elastic-Job-Lite 源码解析 —— 作业失效转移》](http://www.iocoder.cn/Elastic-Job/job-failover/?self)有详细分享。

实现代码如下：

```java
// LiteJobFacade.java
@Override
public ShardingContexts getShardingContexts() {
   // 【忽略，作业失效转移详解】获得 失效转移的作业分片项
   boolean isFailover = configService.load(true).isFailover();
   if (isFailover) {
       List<Integer> failoverShardingItems = failoverService.getLocalFailoverItems();
       if (!failoverShardingItems.isEmpty()) {
           return executionContextService.getJobShardingContext(failoverShardingItems);
       }
   }
   // 作业分片，如果需要分片且当前节点为主节点
   shardingService.shardingIfNecessary();
   // 获得 分配在本机的作业分片项
   List<Integer> shardingItems = shardingService.getLocalShardingItems();
   // 【忽略，作业失效转移详解】移除 分配在本机的失效转移的作业分片项目
   if (isFailover) {
       shardingItems.removeAll(failoverService.getLocalTakeOffItems());
   }
   // 移除 被禁用的作业分片项
   shardingItems.removeAll(executionService.getDisabledItems(shardingItems));
   // 获取当前作业服务器分片上下文
   return executionContextService.getJobShardingContext(shardingItems);
}
```

- 调用 `ShardingService#shardingIfNecessary()` 方法，如果需要分片且当前节点为主节点，作业分片项**分配**。**不是每次都需要作业分片，必须满足「2. 作业分片条件」才执行作业分片**。

- 调用 `ShardingService#getLocalShardingItems()`方法，获得分配在**本机**的作业分片项，即 `/${JOB_NAME}/sharding/${ITEM_ID}/instance` 为本机的作业分片项。

  ```
  // ShardingService.java
  /**
  * 获取运行在本作业实例的分片项集合.
  * 
  * @return 运行在本作业实例的分片项集合
  */
  public List<Integer> getLocalShardingItems() {
     if (JobRegistry.getInstance().isShutdown(jobName) || !serverService.isAvailableServer(JobRegistry.getInstance().getJobInstance(jobName).getIp())) {
         return Collections.emptyList();
     }
     return getShardingItems(JobRegistry.getInstance().getJobInstance(jobName).getJobInstanceId());
  }
  
  /**
  * 获取作业运行实例的分片项集合.
  *
  * @param jobInstanceId 作业运行实例主键
  * @return 作业运行实例的分片项集合
  */
  public List<Integer> getShardingItems(final String jobInstanceId) {
     JobInstance jobInstance = new JobInstance(jobInstanceId);
     if (!serverService.isAvailableServer(jobInstance.getIp())) {
         return Collections.emptyList();
     }
     List<Integer> result = new LinkedList<>();
     int shardingTotalCount = configService.load(true).getTypeConfig().getCoreConfig().getShardingTotalCount();
     for (int i = 0; i < shardingTotalCount; i++) {
         // `/${JOB_NAME}/sharding/${ITEM_ID}/instance`
         if (jobInstance.getJobInstanceId().equals(jobNodeStorage.getJobNodeData(ShardingNode.getInstanceNode(i)))) {
             result.add(i);
         }
     }
     return result;
  }
  ```

- 调用 `shardingItems.removeAll(executionService.getDisabledItems(shardingItems))`，移除**被禁用**的作业分片项，即 `/${JOB_NAME}/sharding/${ITEM_ID}/disabled` **存在**的作业分片项。

  ```java
  // ExecutionService.java
  /**
  * 获取禁用的任务分片项.
  *
  * @param items 需要获取禁用的任务分片项
  * @return 禁用的任务分片项
  */
  public List<Integer> getDisabledItems(final List<Integer> items) {
     List<Integer> result = new ArrayList<>(items.size());
     for (int each : items) {
         // /${JOB_NAME}/sharding/${ITEM_ID}/disabled
         if (jobNodeStorage.isJobNodeExisted(ShardingNode.getDisabledNode(each))) {
             result.add(each);
         }
     }
     return result;
  }
  ```

- 调用 `ExecutionContextService#getJobShardingContext(...)` 方法，获取**当前**作业服务器分片上下文。

**获取当前作业服务器分片上下文**

调用 `ExecutionContextService#getJobShardingContext(...)` 方法，获取**当前**作业服务器分片上下文：

```java
// ExecutionContextService.java
public ShardingContexts getJobShardingContext(final List<Integer> shardingItems) {
   LiteJobConfiguration liteJobConfig = configService.load(false);
   // 移除 正在运行中的作业分片项
   removeRunningIfMonitorExecution(liteJobConfig.isMonitorExecution(), shardingItems);
   //
   if (shardingItems.isEmpty()) {
       return new ShardingContexts(buildTaskId(liteJobConfig, shardingItems), liteJobConfig.getJobName(), liteJobConfig.getTypeConfig().getCoreConfig().getShardingTotalCount(), 
               liteJobConfig.getTypeConfig().getCoreConfig().getJobParameter(), Collections.<Integer, String>emptyMap());
   }
   // 解析分片参数
   Map<Integer, String> shardingItemParameterMap = new ShardingItemParameters(liteJobConfig.getTypeConfig().getCoreConfig().getShardingItemParameters()).getMap();
   // 创建 分片上下文集合
   return new ShardingContexts(buildTaskId(liteJobConfig, shardingItems), //
           liteJobConfig.getJobName(), liteJobConfig.getTypeConfig().getCoreConfig().getShardingTotalCount(),
           liteJobConfig.getTypeConfig().getCoreConfig().getJobParameter(),
           getAssignedShardingItemParameterMap(shardingItems, shardingItemParameterMap)); // 获得当前作业节点的分片参数
}
```

- 调用 `#removeRunningIfMonitorExecution()` 方法，移除正在运行中的作业分片项。

  ```java
  private void removeRunningIfMonitorExecution(final boolean monitorExecution, final List<Integer> shardingItems) {
     if (!monitorExecution) {
         return;
     }
     List<Integer> runningShardingItems = new ArrayList<>(shardingItems.size());
     for (int each : shardingItems) {
         if (isRunning(each)) {
             runningShardingItems.add(each); // /${JOB_NAME}/sharding/${ITEM_ID}/running
         }
     }
     shardingItems.removeAll(runningShardingItems);
  }
      
  private boolean isRunning(final int shardingItem) {
     return jobNodeStorage.isJobNodeExisted(ShardingNode.getRunningNode(shardingItem));
  }
  ```

- 使用 ShardingItemParameters 解析作业分片参数。例如作业分片参数( `JobCoreConfiguration.shardingItemParameters="0=Beijing,1=Shanghai,2=Guangzhou"` ) 解析结果：![img](http://blog-1259650185.cosbj.myqcloud.com/img/202204/28/1651161395.png)

  - ShardingItemParameters 代码清晰易懂，点击[链接](https://github.com/dangdangdotcom/elastic-job/blob/fd45d3799565f69c6b604db83f78629d8c9a70cd/elastic-job-common/elastic-job-common-core/src/main/java/com/dangdang/ddframe/job/util/config/ShardingItemParameters.java)直接查看。

- 调用 `#buildTaskId(...)` 方法，创建作业任务ID( `ShardingContexts.taskId` )：

  ```java
  private String buildTaskId(final LiteJobConfiguration liteJobConfig, final List<Integer> shardingItems) {
     JobInstance jobInstance = JobRegistry.getInstance().getJobInstance(jobName);
     return Joiner.on("@-@").join(liteJobConfig.getJobName(), Joiner.on(",").join(shardingItems), "READY", 
             null == jobInstance.getJobInstanceId() ? "127.0.0.1@-@1" : jobInstance.getJobInstanceId()); 
  }
  ```

  - `taskId` = `${JOB_NAME}` + `@-@` + `${SHARDING_ITEMS}` + `@-@` + `READY` + `@-@` + `${IP}` + `@-@` + `${PID}`。例如：`javaSimpleJob@-@0,1,2@-@READY@-@192.168.3.2@-@38330`。

- 调用 `#getAssignedShardingItemParameterMap(...)` 方法，获得当前作业节点的分片参数。

  ```java
  private Map<Integer, String> getAssignedShardingItemParameterMap(final List<Integer> shardingItems, final Map<Integer, String> shardingItemParameterMap) {
      Map<Integer, String> result = new HashMap<>(shardingItems.size(), 1);
      for (int each : shardingItems) {
          result.put(each, shardingItemParameterMap.get(each));
      }
      return result;
  }
  ```
  
- ShardingContexts，分片上下文集合。

  ```java
  public final class ShardingContexts implements Serializable {
      
      private static final long serialVersionUID = -4585977349142082152L;
      
      /**
       * 作业任务ID.
       */
      private final String taskId;
      /**
       * 作业名称.
       */
      private final String jobName;
      /**
       * 分片总数.
       */
      private final int shardingTotalCount;
      /**
       * 作业自定义参数.
       * 可以配置多个相同的作业, 但是用不同的参数作为不同的调度实例.
       */
      private final String jobParameter;
      /**
       * 分配于本作业实例的分片项和参数的Map.
       */
      private final Map<Integer, String> shardingItemParameters;
      /**
       * 作业事件采样统计数.
       */
      private int jobEventSamplingCount;
      /**
       * 当前作业事件采样统计数.
       */
      @Setter
      private int currentJobEventSamplingCount;
      /**
       * 是否允许可以发送作业事件.
       */
      @Setter
      private boolean allowSendJobEvent = true;
  }
  ```

  - `jobEventSamplingCount`，`currentJobEventSamplingCount` 在 Elastic-Job-Lite 暂未还使用，在 Elastic-Job-Cloud 使用。



## 参考

[Elastic-Job-Lite 源码分析 —— 作业分片](https://www.iocoder.cn/Elastic-Job/job-sharding/)
