## 1. 概述

本文主要分享 **Elastic-Job-Lite 作业监听器**。

涉及到主要类的类图如下( [打开大图](https://static.iocoder.cn/images/Elastic-Job/2017_11_21/01.png) )：

![img](http://blog-1259650185.cosbj.myqcloud.com/img/202204/29/1651219165.png)



- 绿色**监听器**接口 ElasticJobListener，每台作业节点均执行。
- 粉色**监听器**接口 AbstractDistributeOnceElasticJobListener，分布式场景中仅单一节点执行。
- 蓝色类在 `com.dangdang.ddframe.job.lite.internal.guarantee` 里，保证分布式任务全部开始和结束状态。 AbstractDistributeOnceElasticJobListener 通过 `guarantee` 功能，实现分布式场景中仅单一节点执行。

## 2. ElasticJobListener

ElasticJobListener，作业监听器接口，**每台作业节点均执行**。

> 若作业处理作业服务器的文件，处理完成后删除文件，可考虑使用每个节点均执行清理任务。此类型任务实现简单，且无需考虑全局分布式任务是否完成，请尽量使用此类型监听器。

接口代码如下：

```java
public interface ElasticJobListener {
    
    /**
     * 作业执行前的执行的方法.
     * 
     * @param shardingContexts 分片上下文
     */
    void beforeJobExecuted(final ShardingContexts shardingContexts);
    
    /**
     * 作业执行后的执行的方法.
     *
     * @param shardingContexts 分片上下文
     */
    void afterJobExecuted(final ShardingContexts shardingContexts);
}
```

调用执行如下：

```java
// AbstractElasticJobExecutor.java
public final void execute() {
   // ...省略无关代码
   
   // 执行 作业执行前的方法
   try {
       jobFacade.beforeJobExecuted(shardingContexts);
   } catch (final Throwable cause) {
       jobExceptionHandler.handleException(jobName, cause);
   }
   // ...省略无关代码（执行 普通触发的作业）
   // ...省略无关代码（执行 被跳过触发的作业）
   // ...省略无关代码（执行 作业失效转移）
   
   // ...执行 作业执行后的方法
   try {
       jobFacade.afterJobExecuted(shardingContexts);
   } catch (final Throwable cause) {
       jobExceptionHandler.handleException(jobName, cause);
   }
}
```

- JobFacade 对作业监听器简单封装进行调用。

  ```java
  // LiteJobFacade.java
  @Override
  public void beforeJobExecuted(final ShardingContexts shardingContexts) {
     for (ElasticJobListener each : elasticJobListeners) {
         each.beforeJobExecuted(shardingContexts);
     }
  }
      
  @Override
  public void afterJobExecuted(final ShardingContexts shardingContexts) {
     for (ElasticJobListener each : elasticJobListeners) {
         each.afterJobExecuted(shardingContexts);
     }
  }
  ```

- 下文提到的 AbstractDistributeOnceElasticJobListener，也是这么调用。

## 3. AbstractDistributeOnceElasticJobListener

AbstractDistributeOnceElasticJobListener，在分布式作业中只执行一次的监听器。

> 若作业处理数据库数据，处理完成后只需一个节点完成数据清理任务即可。此类型任务处理复杂，需同步分布式环境下作业的状态同步，提供了超时设置来避免作业不同步导致的死锁，请谨慎使用。

**创建** AbstractDistributeOnceElasticJobListener 代码如下：

```java
public abstract class AbstractDistributeOnceElasticJobListener implements ElasticJobListener {

    /**
     * 开始超时时间
     */
    private final long startedTimeoutMilliseconds;
    /**
     * 开始等待对象
     */
    private final Object startedWait = new Object();
    /**
     * 完成超时时间
     */
    private final long completedTimeoutMilliseconds;
    /**
     * 完成等待对象
     */
    private final Object completedWait = new Object();
    /**
     * 保证分布式任务全部开始和结束状态的服务
     */
    @Setter
    private GuaranteeService guaranteeService;
    
    private TimeService timeService = new TimeService();
    
    public AbstractDistributeOnceElasticJobListener(final long startedTimeoutMilliseconds, final long completedTimeoutMilliseconds) {
        if (startedTimeoutMilliseconds <= 0L) {
            this.startedTimeoutMilliseconds = Long.MAX_VALUE;
        } else {
            this.startedTimeoutMilliseconds = startedTimeoutMilliseconds;
        }
        if (completedTimeoutMilliseconds <= 0L) {
            this.completedTimeoutMilliseconds = Long.MAX_VALUE; 
        } else {
            this.completedTimeoutMilliseconds = completedTimeoutMilliseconds;
        }
    }
}
```

- 超时参数 `startedTimeoutMilliseconds`、`completedTimeoutMilliseconds` 务必传递，避免作业不同步导致的死锁。

👇下面，我们来看本文的**重点**：AbstractDistributeOnceElasticJobListener，在分布式作业中只执行一次：

```java
@Override
public final void beforeJobExecuted(final ShardingContexts shardingContexts) {
   // 注册作业分片项开始运行
   guaranteeService.registerStart(shardingContexts.getShardingItemParameters().keySet());
   // 判断是否所有的分片项开始运行
   if (guaranteeService.isAllStarted()) {
       // 执行
       doBeforeJobExecutedAtLastStarted(shardingContexts);
       // 清理启动信息
       guaranteeService.clearAllStartedInfo();
       return;
   }
   // 等待
   long before = timeService.getCurrentMillis();
   try {
       synchronized (startedWait) {
           startedWait.wait(startedTimeoutMilliseconds);
       }
   } catch (final InterruptedException ex) {
       Thread.interrupted();
   }
   // 等待超时
   if (timeService.getCurrentMillis() - before >= startedTimeoutMilliseconds) {
       // 清理启动信息
       guaranteeService.clearAllStartedInfo();
       handleTimeout(startedTimeoutMilliseconds);
   }
}
```

- 调用 `GuaranteeService#registerStart(...)` 方法，注册作业分片项开始运行。

  ```java
  // GuaranteeService.java
  public void registerStart(final Collection<Integer> shardingItems) {
     for (int each : shardingItems) {
         jobNodeStorage.createJobNodeIfNeeded(GuaranteeNode.getStartedNode(each));
     }
  }
  
  // GuaranteeNode.java
  public final class GuaranteeNode {
      static final String ROOT = "guarantee";
      static final String STARTED_ROOT = ROOT + "/started";
  }
  
  static String getStartedNode(final int shardingItem) {
     return Joiner.on("/").join(STARTED_ROOT, shardingItem);
  }
  ```

  - Zookeeper 数据节点 `/${JOB_NAME}/guarantee/started/${ITEM_INDEX}` 为**永久**节点，存储空串( `""` )。为什么是**永久**节点呢？在 `GuaranteeService#isAllStarted()` 见分晓。

- 调用 `GuaranteeService#isAllStarted()` 方法，判断是否所有的分片项开始运行。

  ```java
  /**
  * 判断是否所有的任务均启动完毕.
  *
  * @return 是否所有的任务均启动完毕
  */
  public boolean isAllStarted() {
     return jobNodeStorage.isJobNodeExisted(GuaranteeNode.STARTED_ROOT)
             && configService.load(false).getTypeConfig().getCoreConfig().getShardingTotalCount() == jobNodeStorage.getJobNodeChildrenKeys(GuaranteeNode.STARTED_ROOT).size();
  }
  ```

  - 当 `/${JOB_NAME}/guarantee/started/` 目录下，所有作业分片项都开始运行，即运行总数等于作业分片总数( `JobCoreConfiguration.ShardingTotalCount` )，**代表所有的任务均启动完毕**。
  - 等待所有任务启动过程中，不排除有作业节点会挂掉，如果 `/${JOB_NAME}/guarantee/started/${ITEM_INDEX}` 存储**临时**节点，会导致不能满足所有的分片项开始运行的条件。
  - 等待过程中，如果调整作业分片总数( `JobCoreConfiguration.ShardingTotalCount` )，会导致异常。

- 当不满足所有的分片项开始运行时，作业节点调用 `Object#wait(...)` 方法进行等待。该等待怎么结束等待？当满足所有的分片项开始运行的作业节点调用 `GuaranteeService#clearAllStartedInfo()` 时，StartedNodeRemovedJobListener 会监听到 `/${JOB_NAME}/guarantee/started/` 被删除，调用 `Object#notifyAll(...)` 方法进行唤醒全部。

  ```java
  // GuaranteeService.java
  /**
  * 清理所有任务启动信息.
  */
  public void clearAllStartedInfo() {
     jobNodeStorage.removeJobNodeIfExisted(GuaranteeNode.STARTED_ROOT);
  }
  
  // StartedNodeRemovedJobListener.java
  class StartedNodeRemovedJobListener extends AbstractJobListener {
     
     @Override
     protected void dataChanged(final String path, final Type eventType, final String data) {
         if (Type.NODE_REMOVED == eventType && guaranteeNode.isStartedRootNode(path)) {
             for (ElasticJobListener each : elasticJobListeners) {
                 if (each instanceof AbstractDistributeOnceElasticJobListener) {
                     ((AbstractDistributeOnceElasticJobListener) each).notifyWaitingTaskStart();
                 }
             }
         }
     }
  }
  ```

- 调用 `#doBeforeJobExecutedAtLastStarted(...)` 方法，执行最后一个作业执行前的执行的方法，实现该抽象方法，完成自定义逻辑。`#doAfterJobExecutedAtLastCompleted(...)` 实现的方式一样，就不重复解析了。

  ```
  // AbstractDistributeOnceElasticJobListener.java
  /**
  * 分布式环境中最后一个作业执行前的执行的方法.
  *
  * @param shardingContexts 分片上下文
  */
  public abstract void doBeforeJobExecutedAtLastStarted(ShardingContexts shardingContexts);
      
  /**
  * 分布式环境中最后一个作业执行后的执行的方法.
  *
  * @param shardingContexts 分片上下文
  */
  public abstract void doAfterJobExecutedAtLastCompleted(ShardingContexts shardingContexts);
  ```

  

- 整体流程如下图：![img](http://blog-1259650185.cosbj.myqcloud.com/img/202204/29/1651219298.png)



## 参考

[Elastic-Job-Lite 源码分析 —— 作业监听器](https://www.iocoder.cn/Elastic-Job/job-listener/)
