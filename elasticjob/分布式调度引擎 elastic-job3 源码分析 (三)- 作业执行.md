elastic-job 作业执行是分片执行，支持错过重调度，重叠执行转错过重调度，作业运行节点下线的失效转移，服务节点/运行实例变更的重分片。

## 1. 作业执行逻辑

<img src="http://blog-1259650185.cosbj.myqcloud.com/img/202204/25/1650898863.png" alt="img" style="zoom: 67%;" />

作业触发两个来源，quartz 调度触发和失效转移触发，分片分为失效转移和常规调度两部分

作业和分片应该按两种来源分支，逻辑比较清晰

## 2. 作业执行类图

<img src="http://blog-1259650185.cosbj.myqcloud.com/img/202204/25/1650898949.png" alt="img"  />

**LiteJob/JobItemExecutor/ElasticJob** 

elastic-job 可以看作分布式 quartz，分片作业由 quartz 调度器调起。

LiteJob 实现了 quartz 的 job 接口，作为 quartz 与 elastic-job 作业的桥接，用 quartz 的参数机制注入 **ElasticJobExecutor**

```java
@Setter
public final class LiteJob implements Job {
    // 用 quartz 的参数机制注入
    private ElasticJobExecutor jobExecutor;
    
    @Override
    public void execute(final JobExecutionContext context) {
        jobExecutor.execute();
    }
    
}
```

这样静悄悄地桥接到 elastic-job 的领地。

**ElasticJobExecutor** 

elastic-job 作业执行代码

```java
/**
 * Execute job.
 */
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

分 5 步：

作业分片，重叠执行检查，执行作业分片，执行错过(missfired)分片，失效转移

其中，作业分片参看分片服务，失效转移参看失效转移

### 2.1 重叠执行检查

quartz 可使用 @DisallowConcurrentExecution 配置不允许作业重叠执行，即当前作业未执行完，下一个作业不触发，elastic-job 的 quartz 作业实现 LiteJob 并没有该注解，但 elastic-job 设置执行线程池为 1，org.quartz.jobStore.misfireThreshold = 1(毫秒)，实际不重叠执行，因此， elastic-job 是自己管理重叠执行逻辑，是否重叠执行依据是作业分片执行前检查是否有分片执行(running)，如果有就设置 missfired，通过重调错过执行补偿执行。

![img](http://blog-1259650185.cosbj.myqcloud.com/img/202204/25/1650901608.png)

写入 missfired，后面通过错过重调度处理。

- 依赖 **monitorExecution** 配置，**missfired **是调度的业务功能，怎么会依赖是否监控

- **不支持 2 次及以上的错过重调度**

- **建议：增加一个/leader/overlap 设置是否需要重叠执行**

### 2.2 常规执行作业

```java
private void execute(final JobConfiguration jobConfig, final ShardingContexts shardingContexts, final ExecutionSource executionSource) {
    if (shardingContexts.getShardingItemParameters().isEmpty()) {
        jobFacade.postJobStatusTraceEvent(shardingContexts.getTaskId(), State.TASK_FINISHED, String.format("Sharding item for job '%s' is empty.", jobConfig.getJobName()));
        return;
    }
    jobFacade.registerJobBegin(shardingContexts);
    String taskId = shardingContexts.getTaskId();
    jobFacade.postJobStatusTraceEvent(taskId, State.TASK_RUNNING, "");
    try {
        process(jobConfig, shardingContexts, executionSource);
    } finally {
        // TODO Consider increasing the status of job failure, and how to handle the overall loop of job failure
        jobFacade.registerJobCompleted(shardingContexts);
        if (itemErrorMessages.isEmpty()) {
            jobFacade.postJobStatusTraceEvent(taskId, State.TASK_FINISHED, "");
        } else {
            jobFacade.postJobStatusTraceEvent(taskId, State.TASK_ERROR, itemErrorMessages.toString());
            itemErrorMessages.clear();
        }
    }
}
```

JobFacade.registerJobBegin 作业分片执行前，写入 zk 分片项 running 状态，znode**/{itemNum}/running**

![img](http://blog-1259650185.cosbj.myqcloud.com/img/202204/25/1650901934.png)

JobFacade.registerJobCompleted 作业执行结束，删除 zk 分片项 znode running，删除失效转移 znode

```java
@Override
public void registerJobCompleted(final ShardingContexts shardingContexts) {
    executionService.registerJobCompleted(shardingContexts);
    if (configService.load(true).isFailover()) {
        failoverService.updateFailoverComplete(shardingContexts.getShardingItemParameters().keySet());
    }
}
```

updateFailoverComplete 移除失效转移分片，这里要跳到分片的处理逻辑回顾一下

```java
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

失效转移是触发(trigger)执行，处理失效转移分片, 名字 update，实际上操作是移除 /failover 和 /failovering

![img](http://blog-1259650185.cosbj.myqcloud.com/img/202204/25/1650902151)

接着分析分片执行代码

```java
private void process(final JobConfiguration jobConfig, final ShardingContexts shardingContexts, final ExecutionSource executionSource) {
    Collection<Integer> items = shardingContexts.getShardingItemParameters().keySet();
    if (1 == items.size()) {
        int item = shardingContexts.getShardingItemParameters().keySet().iterator().next();
        JobExecutionEvent jobExecutionEvent = new JobExecutionEvent(IpUtils.getHostName(), IpUtils.getIp(), shardingContexts.getTaskId(), jobConfig.getJobName(), executionSource, item);
        process(jobConfig, shardingContexts, item, jobExecutionEvent);
        return;
    }
    CountDownLatch latch = new CountDownLatch(items.size());
    for (int each : items) {
        JobExecutionEvent jobExecutionEvent = new JobExecutionEvent(IpUtils.getHostName(), IpUtils.getIp(), shardingContexts.getTaskId(), jobConfig.getJobName(), executionSource, each);
        ExecutorService executorService = executorContext.get(ExecutorService.class);
        if (executorService.isShutdown()) {
            return;
        }
        executorService.submit(() -> {
            try {
                process(jobConfig, shardingContexts, each, jobExecutionEvent);
            } finally {
                latch.countDown();
            }
        });
    }
    try {
        latch.await();
    } catch (final InterruptedException ex) {
        Thread.currentThread().interrupt();
    }
}
```

作业执行是分片执行，每个运行实例(instance)可能分到多个分片，需要线程池并行执行作业分片，线程池实现 Reloadable 接口，支持 spi 载入和热配置

![img](http://blog-1259650185.cosbj.myqcloud.com/img/202204/25/1650902249.png)

分片执行代码，使用 JobItemExecutor，elasic-job 不同的执行器逻辑，如 script，dataflow，http。


```java
private void process(final JobConfiguration jobConfig, final ShardingContexts shardingContexts, final int item, final JobExecutionEvent startEvent) {
    jobFacade.postJobExecutionEvent(startEvent);
    log.trace("Job '{}' executing, item is: '{}'.", jobConfig.getJobName(), item);
    JobExecutionEvent completeEvent;
    try {
        jobItemExecutor.process(elasticJob, jobConfig, jobFacade, shardingContexts.createShardingContext(item));
        completeEvent = startEvent.executionSuccess();
        log.trace("Job '{}' executed, item is: '{}'.", jobConfig.getJobName(), item);
        jobFacade.postJobExecutionEvent(completeEvent);
        // CHECKSTYLE:OFF
    } catch (final Throwable cause) {
        // CHECKSTYLE:ON
        completeEvent = startEvent.executionFailure(ExceptionUtils.transform(cause));
        jobFacade.postJobExecutionEvent(completeEvent);
        itemErrorMessages.put(item, ExceptionUtils.transform(cause));
        JobErrorHandler jobErrorHandler = executorContext.get(JobErrorHandler.class);
        jobErrorHandler.handleException(jobConfig.getJobName(), cause);
    }
}
```

### 2.3 错过重调度

错过作业重调度(missfired)，elastic-job 来说，missfired 来源于常规执行和失效转移分片执行并行中发生

```java
// JobTriggerListener.java
@Override
public void triggerMisfired(final Trigger trigger) {
    if (null != trigger.getPreviousFireTime()) {
        executionService.setMisfire(shardingService.getLocalShardingItems());
    }
}
```

elastic-job 使用 quartz 机制，TriggerListener 的 triggerMisfired 处理触发错失，设置 znode /misfired 节点，使用 elastic-job 的错过重调度机制补偿执行

正常作业执行后，重执行错过的作业，与正常执行逻辑一致

```java
// ElasticJobExecutor.java
// 错过重执行有两个来源，1.重叠执行转missfired，但分片逻辑没有考虑该来源missfired分片；2.失效转移转missfired
while (jobFacade.isExecuteMisfired(shardingContexts.getShardingItemParameters().keySet())) { 
    // while 应该是考虑for循环抓失效转移分片，意义不大
    jobFacade.clearMisfire(shardingContexts.getShardingItemParameters().keySet());
    execute(jobConfig, shardingContexts, ExecutionSource.MISFIRE); // 执行missfired分片
}
```

![img](http://blog-1259650185.cosbj.myqcloud.com/img/202204/26/1650902692.png)

Misfired 分片与当前分片的交集

看一下分片逻辑

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

两个场景，失效转移触发的作业，常规触发的作业

分片应加上错过重调度的考虑，目前分片只考虑正常分片和 failover

依赖核心服务：

- 分片服务 作业分配，获取分片信息
- 调度服务
- 失效转移



## 参考

[分布式调度引擎 elastic-job3 源码分析 (三)- 作业执行](https://xie.infoq.cn/article/f362359ba3d35a9c66de2edc6)
