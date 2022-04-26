服务可分为功能服务和核心服务，其中核心服务支撑功能服务的服务，功能任务有任务注册，任务执行，失效转移等，是调度平台的”业务”功能。

## 1. 核心服务

### 1.1 znode 结构

znode 设计是 zookeeper 分布式协调的灵魂，zk 的临时 znode，持久 znode，watch 机制

![img](http://blog-1259650185.cosbj.myqcloud.com/img/202204/26/1650903054.png)

本文分析的核心，服务如何使用 znode，znode 间组合使用

### 1.2 注册中心和 znode 存储服务

注册中心属于生态一部分，但注册中心主要用在 znode 存储服务，合起来一起看

![img](http://blog-1259650185.cosbj.myqcloud.com/img/202204/26/1650903122.png)

JobNodeStorage/CoordinatorRegistryCenter 两个类名字有点名不副实，CoordinatorRegistryCenter 才是 znode 节点存取；JobNodeStorage 更多是 znode”应用”:

executeInLeader 主节点选举

addDataListener 注册 znode 监听

executeInTransaction znode 操作事务 TransactionExecutionCallback

AbstracJobListener znode 事件监听器基类

LeaderExecutionCallback 主节点选举后回调

TransactionExecutionCallback znode 事务操作

### 1.3 监听服务

总体来说，监听服务分两大类，quartz 和分布式(zk)

本文只关注 zk 部分，elastic-job 自身也只实现 zk 部分，quartz 部分留接口给用户，其他的核心服务都依赖监听服务，捕获 znode 事件，执行相应服务逻辑，因此监听服务非常关键服务，是其他服务分析的入口

![img](http://blog-1259650185.cosbj.myqcloud.com/img/202204/26/1650903406.png)

**ListenerManager** 

监听管理器的集中管理

**AbstractListenerManager/ AbstractJobListener **

其他服务继承，实现服务的监听管理接入的监听器实现

**RegistryCenterConnectionStateListener** 

连接状态的监听器，连接断开暂停作业，重连后，重新初始化作业，清除分片，重启作业

谁使用：几乎所有核心服务

依赖服务：

- znode 存储服务/注册中心 znode 节点存取，监听器注册

### 1.4 分片服务(sharding)

分片是分布式任务不可或缺的特性，任务分片并行执行，极大提高处理能力，分片伴随弹性计算，节点发现，容错等能力，是分布式调度的体现

elastic-job 实现了静态分片和分片容错，当作业满足分片条件时，设置需要分片**标记**，等到作业执行时，判断有该标记后**执行**作业分配

#### 1.4.1 分片监听

elastic-job 的分片是先设置需要分片标记，等到需要的时候再实际分片，哪里设置分片？

![img](http://blog-1259650185.cosbj.myqcloud.com/img/202204/26/1650903581.png)

**ListenServersChangedJobListener**

监听 server znode 和 instance znode，对于一个作业，server 可有对应多个 instance，因此 server 的上下线，同时接收到 server 和 instance 事件

server 节点是持久 znode，所以服务事件只有上线和 server enabled/disabled 变更

**ShardingTotalCountChangedJobListener**

监听作业配置分片数变更

另外，诊断服务也定时设置分片标记

#### 1.4.2 分片

下面分析分片，分片就是分配任务到各个在线运行实例节点

![img](http://blog-1259650185.cosbj.myqcloud.com/img/202204/26/1650903686.png)

分片入口方法 ShardingService.shardingIfNecessary，回顾一下作业执行。

```java
// ElasticJobExecutor.java
public void execute() {
    JobConfiguration jobConfig = jobFacade.loadJobConfiguration(true);
    executorContext.reloadIfNecessary(jobConfig);
    JobErrorHandler jobErrorHandler = executorContext.get(JobErrorHandler.class);
    try {
        jobFacade.checkJobExecutionEnvironment();
    } catch (final JobExecutionEnvironmentException cause) {
        jobErrorHandler.handleException(jobConfig.getJobName(), cause);
    }
    ShardingContexts shardingContexts = jobFacade.getShardingContexts(); // 作业分片
    jobFacade.postJobStatusTraceEvent(shardingContexts.getTaskId(), State.TASK_STAGING, String.format("Job '%s' execute begin.", jobConfig.getJobName()));
    if (jobFacade.misfireIfRunning(shardingContexts.getShardingItemParameters().keySet())) { // 重叠作业检查，设置 misfired，通过错过重调度机制执行
        jobFacade.postJobStatusTraceEvent(shardingContexts.getTaskId(), State.TASK_FINISHED, String.format(
                "Previous job '%s' - shardingItems '%s' is still running, misfired job will start after previous job completed.", jobConfig.getJobName(),
                shardingContexts.getShardingItemParameters().keySet()));
        return;
    }
    try {
        jobFacade.beforeJobExecuted(shardingContexts);
        //CHECKSTYLE:OFF
    } catch (final Throwable cause) {
        //CHECKSTYLE:ON
        jobErrorHandler.handleException(jobConfig.getJobName(), cause);
    }
    execute(jobConfig, shardingContexts, ExecutionSource.NORMAL_TRIGGER); // 执行作业，分两个执行场景：quatz调起，执行常规分片作业；失效转移触发，执行失效转移分片
    while (jobFacade.isExecuteMisfired(shardingContexts.getShardingItemParameters().keySet())) { // 错过重执行有两个来源，1.重叠执行转missfired，但分片逻辑没有考虑该来源missfired分片；2.失效转移转missfired
        jobFacade.clearMisfire(shardingContexts.getShardingItemParameters().keySet()); // while 应该是考虑for循环抓失效转移分片，意义不大
        execute(jobConfig, shardingContexts, ExecutionSource.MISFIRE); // 执行missfired分片
    }
    jobFacade.failoverIfNecessary(); // 失效转移，获取一个失效转移分片，能怎么样？
    try {
        jobFacade.afterJobExecuted(shardingContexts);
        //CHECKSTYLE:OFF
    } catch (final Throwable cause) {
        //CHECKSTYLE:ON
        jobErrorHandler.handleException(jobConfig.getJobName(), cause);
    }
}
```

分片在 getShardingContexgts 完成

```java
// LiteJobFacade.java
@Override
public ShardingContexts getShardingContexts() {
    boolean isFailover = configService.load(true).isFailover();
    if (isFailover) { // 如果有失效转移分片，先处理
        List<Integer> failoverShardingItems = failoverService.getLocalFailoverItems();
        if (!failoverShardingItems.isEmpty()) {
            return executionContextService.getJobShardingContext(failoverShardingItems);
        }
    }
    shardingService.shardingIfNecessary(); // 分片
    List<Integer> shardingItems = shardingService.getLocalShardingItems();
    if (isFailover) { // 重新分片了
        shardingItems.removeAll(failoverService.getLocalTakeOffItems());
    }
    shardingItems.removeAll(executionService.getDisabledItems(shardingItems));
    return executionContextService.getJobShardingContext(shardingItems);
}
```

优先处理失效分片，记得失效转移分析，失效分片是通过调度器 triggerJob 触发即时执行，如果没有，调用 ShardingService.shardingIfNecessary 正常作业分片，最终分片封装到 ShardingContexts。

接下来分片代码。

```java
// LiteJobFacade.java
public void shardingIfNecessary() {
    List<JobInstance> availableJobInstances = instanceService.getAvailableJobInstances(); // 获取在线的运行示例
    if (!isNeedSharding() || availableJobInstances.isEmpty()) {
        return;
    }
    if (!leaderService.isLeaderUntilBlock()) { // 分片主节点负责
        blockUntilShardingCompleted();
        return;
    }
    waitingOtherShardingItemCompleted();
    JobConfiguration jobConfig = configService.load(false);
    int shardingTotalCount = jobConfig.getShardingTotalCount();
    log.debug("Job '{}' sharding begin.", jobName);
    jobNodeStorage.fillEphemeralJobNode(ShardingNode.PROCESSING, "");
    resetShardingInfo(shardingTotalCount);
    JobShardingStrategy jobShardingStrategy = JobShardingStrategyFactory.getStrategy(jobConfig.getJobShardingStrategyType());
    jobNodeStorage.executeInTransaction(getShardingResultTransactionOperations(jobShardingStrategy.sharding(availableJobInstances, jobName, shardingTotalCount)));
    log.debug("Job '{}' sharding complete.", jobName);
}
```

getLocalTakeOffItems，获取分配了的失效转移的分片

![img](http://blog-1259650185.cosbj.myqcloud.com/img/202204/26/1650904497.png)

防止运行实例在主节点分片后下线，然后又上线，该节点的分片很可能已转移给别的运行实例，因此需要进行移除，避免多节点运行相同的作业分片项。

**这里是不是应该直接丢弃所有分片，再看失效转移处理**

```java
private void removeRunningIfMonitorExecution(final boolean monitorExecution, final List<Integer> shardingItems) {
    if (!monitorExecution) {
        return;
    }
    List<Integer> runningShardingItems = new ArrayList<>(shardingItems.size());
    for (int each : shardingItems) {
        if (isRunning(each)) {
            runningShardingItems.add(each);
        }
    }
    shardingItems.removeAll(runningShardingItems);
}
```

循环分掉 crashed 实例所有的分片 

------

分片在主节点完成

LeaderService#isLeaderUntilBlock/blockUntilShardingCompleted 若非主节点等待分片完成

waitingOtherShardingItemCompleted 等待当前执行中的分片完成，依赖 monitor execution 配置

**分片运行依赖 monitorExecution 配置，也就是等不等待完成主要是看监控不监控，感觉主次没搞好；这里也反应了分片要严格按照配置要求，像失效转移分片改变需要另行处理**

jobNodeStorage.fillEphemeralJobNode(ShardingNode.PROCESSING, "") 标记分片处理中，写入/leading/sharding/processing

![img](http://blog-1259650185.cosbj.myqcloud.com/img/202204/26/1650904013.png)

**processing znode**

只有在非主节点等待分片完成是用到，由于 necessary 必定存在，只为监控使用

resetShardingInfo

```java
private void resetShardingInfo(final int shardingTotalCount) {
    for (int i = 0; i < shardingTotalCount; i++) {
        jobNodeStorage.removeJobNodeIfExisted(ShardingNode.getInstanceNode(i));
        jobNodeStorage.createJobNodeIfNeeded(ShardingNode.ROOT + "/" + i);
    }
    int actualShardingTotalCount = jobNodeStorage.getJobNodeChildrenKeys(ShardingNode.ROOT).size();
    if (actualShardingTotalCount > shardingTotalCount) { // 删除之前多出的分片
        for (int i = shardingTotalCount; i < actualShardingTotalCount; i++) {
            jobNodeStorage.removeJobNodeIfExisted(ShardingNode.ROOT + "/" + i);
        }
    }
}
```

**JobShardingStrategy**

spi 载入，有多种策略，属于基础(infra)包，细节就不分析

最后事务写入分片分配使用 PersistShardingInfoTransactionExecutionCallback

![img](http://blog-1259650185.cosbj.myqcloud.com/img/202204/26/1650904227.png)

分片分配给那个作业运行实例

![img](http://blog-1259650185.cosbj.myqcloud.com/img/202204/26/1650904242.png)

清理 znode，需要分片标记和分片处理中标记

谁使用：

- 作业执行 作业分片，获取分片信息
- 诊断服务 设置分片标记，处理分布式环境下，离线作业运行实例未处理分片

依赖服务：

- znode 存储服务/注册中心 znode 节点存取，监听器注册
- 选主服务 分片需主节点执行



## 参考

[分布式调度引擎elastic-job源码分析(四)核心服务I based v3](https://www.jianshu.com/p/67efd4d3f464)
