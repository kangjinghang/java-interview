失效转移是运行节点下线后，其他在线运行节点抓取该节点分配的分片执行，保证整个作业的完整性，是分布式调度引擎必备的特性。

## 1. 失效触发

![img](http://blog-1259650185.cosbj.myqcloud.com/img/202204/26/1650939616.png)

**JobCrashedJobListener** 

监听运行实例znode /instances/{instanceId} 删除事件，即运行实例下线事件，本节点下线不处理

```java
class JobCrashedJobListener implements DataChangedEventListener {
    
    @Override
    public void onChange(final DataChangedEvent event) {
        if (!JobRegistry.getInstance().isShutdown(jobName) && isFailoverEnabled() && Type.DELETED == event.getType() && instanceNode.isInstancePath(event.getKey())) {
            String jobInstanceId = event.getKey().substring(instanceNode.getInstanceFullPath().length() + 1);
            if (jobInstanceId.equals(JobRegistry.getInstance().getJobInstance(jobName).getJobInstanceId())) {
                return;
            }
            List<Integer> failoverItems = failoverService.getFailoveringItems(jobInstanceId);
            if (!failoverItems.isEmpty()) {
                for (int each : failoverItems) {
                    failoverService.setCrashedFailoverFlagDirectly(each);
                    failoverService.failoverIfNecessary();
                }
            } else {
                for (int each : shardingService.getCrashedShardingItems(jobInstanceId)) {
                    failoverService.setCrashedFailoverFlag(each);
                    failoverService.failoverIfNecessary();
                }
            }
        }
    }
}
```

## 2. 失效转移

![img](http://blog-1259650185.cosbj.myqcloud.com/img/202204/26/1650939780.png)

犹如员工请假，需要其他员工接替工作，运行实例下线需要接替两类工作，将(未)触发的作业，通过重新分片处理；失效转移针对正在进行的作业分片

运行实例正在进行的工作(分片)有哪些

设为missfired的分片，包括quartz missfired和重叠执行转missfired

抢到的失效转移分片，抢到后运行实例下线了

正常分片分配到的作业分片

missfired没有处理，之前分片服务分析了，重分片会剪掉多出的/sharding/item，！！！丢失待处理missfired分片，处理及时性也是问题

继续分析监听器

在线实例都进入 if，没有实例进入 else，抓取 crashed 节点的分片，可以合起来再循环抓取

首先 getFailoveringItem 获取下线实例抢到的失效转移分片，这是在弦上的箭，该znode是failoverIfNecessary写入的，下面会分析到

![img](http://blog-1259650185.cosbj.myqcloud.com/img/202204/26/1650940363.png)

setCrashedFailoverFlagDirectly/setCrashedFailoverFlag方法，写入/leader/failover/items/{itemNum}，需要失效转移的分片, 待failoverIfNecessary抓取

![img](http://blog-1259650185.cosbj.myqcloud.com/img/202204/26/1650940423.png)



shardingService.getCrashedShardingItems 抓取正常作业分片

**获取失效转移分片后**，FailoverService.failoverIfNecessary主节点回调处理，该方法有两处调用，JobCrashedJobListener和作业执行的最后

```java
// FailoverService.java
/**
 * Failover if necessary.
 */
public void failoverIfNecessary() {
    if (needFailover()) {
        jobNodeStorage.executeInLeader(FailoverNode.LATCH, new FailoverLeaderExecutionCallback());
    }
}
```

/leader/failover/latch，这是znode存储分析时说到的两个选主znode之一，用于失效转移处理同步

主节点后的回调，与多线程同步一样，保证只有一个实例处理

```java
class FailoverLeaderExecutionCallback implements LeaderExecutionCallback {
    
    @Override
    public void execute() {
        if (JobRegistry.getInstance().isShutdown(jobName) || !needFailover()) {
            return;
        }
        int crashedItem = Integer.parseInt(jobNodeStorage.getJobNodeChildrenKeys(FailoverNode.ITEMS_ROOT).get(0));
        log.debug("Failover job '{}' begin, crashed item '{}'", jobName, crashedItem);
        jobNodeStorage.fillEphemeralJobNode(FailoverNode.getExecutionFailoverNode(crashedItem), JobRegistry.getInstance().getJobInstance(jobName).getJobInstanceId());
        jobNodeStorage.fillJobNode(FailoverNode.getExecutingFailoverNode(crashedItem), JobRegistry.getInstance().getJobInstance(jobName).getJobInstanceId());
        jobNodeStorage.removeJobNodeIfExisted(FailoverNode.getItemsNode(crashedItem));
        // TODO Instead of using triggerJob, use executor for unified scheduling
        JobScheduleController jobScheduleController = JobRegistry.getInstance().getJobScheduleController(jobName);
        if (null != jobScheduleController) {
            jobScheduleController.triggerJob();
        }
    }
}
```

![img](http://blog-1259650185.cosbj.myqcloud.com/img/202204/26/1650941594.png)

- 获取一个失效转移分配，每次只抢一个，增加并行度

​		jobNodeStorage.getJobNodeChildrenKeys(FailoverNode.ITEMS_ROOT).get(0)

- 写入当前运行实例Id到，抢占转移分片

​		/sharding/{itemNum}/failover和/sharding/{itemNum}/failovering

- 为什么需要两个znode

​		/failover现在分配给谁了，临时的状态，用于执行时决策

​		/failovering 已经给谁了，持久节点，用于回收

- 从/leader/failover去掉抢到的分片
- 触发作业执行

​	还有问题，失效转移与正常执行存在并发可能，并且作业触发即时执行，quartz 的线程数只有 1，触发失效，转入错过重调度

​	建议：绕过 quartz，用另外线程资源执行，避免转到错过重调度

最后 ，跑一下失效转移

ElasticJobExecutor.execute

```java
jobFacade.failoverIfNecessary(); // 失效转移，获取一个失效转移分片，能怎么样？
try {
    jobFacade.afterJobExecuted(shardingContexts);
    //CHECKSTYLE:OFF
} catch (final Throwable cause) {
    //CHECKSTYLE:ON
    jobErrorHandler.handleException(jobConfig.getJobName(), cause);
}
```

什么意思，failoverIfNecessary 只获取一个失效转移分片，能起什么作用

**FailoverSettingsChangedJobListener **

**失效转移热配置，**监听配置节点，检查是否关闭失效转移



## 参考

[分布式调度引擎elastic-job源码分析(六)-失效转移base v3](https://www.jianshu.com/p/e9ebf7a9df18)
