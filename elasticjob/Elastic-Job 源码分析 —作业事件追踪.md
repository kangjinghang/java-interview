# 1. 概述

本文主要分享 **Elastic-Job-Lite 作业事件追踪**。

另外，**Elastic-Job-Cloud 作业事件追踪** 和 Elastic-Job-Lite 基本类似，不单独开一篇文章，记录在该文章里。如果你对 Elastic-Job-Cloud 暂时不感兴趣，可以跳过相应部分。

Elastic-Job 提供了事件追踪功能，可通过事件订阅的方式处理调度过程的重要事件，用于查询、统计和监控。Elastic-Job 目前订阅两种事件，基于**关系型数据库**记录事件。

涉及到主要类的类图如下

![img](http://blog-1259650185.cosbj.myqcloud.com/img/202204/29/1651210982.png)

- 以上类在 `com.dangdang.ddframe.job.event` 包，不仅为 Elastic-Job-Lite，而且为 Elastic-Job-Cloud 实现了事件追踪功能。
- 作业**事件**：粉色的类。
- 作业**事件总线**：黄色的类。
- 作业**事件监听器**：蓝色的类。

![img](http://blog-1259650185.cosbj.myqcloud.com/img/202204/29/1651211201.png)

## 2. 作业事件总线

JobEventBus，作业事件总线，提供了注册监听器、发布事件两个方法。

**创建** JobEventBus 代码如下：

```java
public final class JobEventBus {

    /**
     * 作业事件配置
     */
    private final JobEventConfiguration jobEventConfig;
    /**
     * 线程池执行服务对象
     */
    private final ExecutorServiceObject executorServiceObject;
    /**
     * 事件总线
     */
    private final EventBus eventBus;
    /**
     * 是否注册作业监听器
     */
    private boolean isRegistered;
    
    public JobEventBus() {
        jobEventConfig = null;
        executorServiceObject = null;
        eventBus = null;
    }
    
    public JobEventBus(final JobEventConfiguration jobEventConfig) {
        this.jobEventConfig = jobEventConfig;
        executorServiceObject = new ExecutorServiceObject("job-event", Runtime.getRuntime().availableProcessors() * 2);
        // 创建 异步事件总线
        eventBus = new AsyncEventBus(executorServiceObject.createExecutorService());
        // 注册 事件监听器
        register();
    }
}
```

- JobEventBus 基于 [Google Guava EventBus](https://github.com/google/guava/wiki/EventBusExplained)，在[《Sharding-JDBC 源码分析 —— SQL 执行》「4.1 EventBus」](http://www.iocoder.cn/Sharding-JDBC/sql-execute)有详细分享。这里要注意的是 AsyncEventBus( **异步事件总线** )，注册在其上面的监听器是**异步**监听执行，事件发布无需阻塞等待监听器执行完逻辑，所以对性能不存在影响。

- 使用 JobEventConfiguration( 作业事件配置 ) 创建事件监听器，调用 `#register()` 方法进行注册监听。

  ```java
  private void register() {
     try {
         eventBus.register(jobEventConfig.createJobEventListener());
         isRegistered = true;
     } catch (final JobEventListenerConfigurationException ex) {
         log.error("Elastic job: create JobEventListener failure, error is: ", ex);
     }
  }
  ```

  - 该方法是私有( `private` )方法，只能使用 JobEventConfiguration 创建事件监听器注册。当不传递该配置时，意味着不开启**事件追踪**功能。

**发布作业事件**

发布作业事件( JobEvent ) 代码如下：

```java
// JobEventBus.java
public void post(final JobEvent event) {
   if (isRegistered && !executorServiceObject.isShutdown()) {
       eventBus.post(event);
   }
}
```

在 Elaistc-Job-Lite 里，LiteJobFacade 对 `JobEventBus#post(...)` 进行封装，提供给作业执行器( AbstractElasticJobExecutor )调用( Elastic-Job-Cloud 实际也进行了封装 )：

```java
// LiteJobFacade.java
@Override
public void postJobExecutionEvent(final JobExecutionEvent jobExecutionEvent) {
   jobEventBus.post(jobExecutionEvent);
}
    
@Override
public void postJobStatusTraceEvent(final String taskId, final State state, final String message) {
   TaskContext taskContext = TaskContext.from(taskId);
   jobEventBus.post(new JobStatusTraceEvent(taskContext.getMetaInfo().getJobName(), taskContext.getId(),
           taskContext.getSlaveId(), Source.LITE_EXECUTOR, taskContext.getType(), taskContext.getMetaInfo().getShardingItems().toString(), state, message));
   if (!Strings.isNullOrEmpty(message)) {
       log.trace(message);
   }
}
```

- TaskContext 通过 `#from(...)` 方法，对作业任务ID( `taskId` ) 解析，获取任务上下文。TaskContext 代码注释很完整，点击[链接](https://github.com/dangdangdotcom/elastic-job/blob/8926e94aa7c48dc635a36518da2c4b10194420a5/elastic-job-common/elastic-job-common-core/src/main/java/com/dangdang/ddframe/job/context/TaskContext.java)直接查看。

# 3. 作业事件

目前有两种作业事件( JobEvent )：

- JobStatusTraceEvent，作业状态追踪事件。
- JobExecutionEvent，作业执行追踪事件。

本小节分享两方面：

- 作业事件**发布时机**。
- Elastic-Job 基于**关系型数据库**记录事件的**表结构**。

## 3.1 作业状态追踪事件

JobStatusTraceEvent，作业状态追踪事件。

代码如下：

```java
public final class JobStatusTraceEvent implements JobEvent {

    /**
     * 主键
     */
    private String id = UUID.randomUUID().toString();
    /**
     * 作业名称
     */
    private final String jobName;
    /**
     * 原作业任务ID
     */
    @Setter
    private String originalTaskId = "";
    /**
     * 作业任务ID
     * 来自 {@link com.dangdang.ddframe.job.executor.ShardingContexts#taskId}
     */
    private final String taskId;
    /**
     * 执行作业服务器的名字
     * Elastic-Job-Lite，作业节点的 IP 地址
     * Elastic-Job-Cloud，Mesos 执行机主键
     */
    private final String slaveId;
    /**
     * 任务来源
     */
    private final Source source;
    /**
     * 任务执行类型
     */
    private final ExecutionType executionType;
    /**
     * 作业分片项
     * 多个分片项以逗号分隔
     */
    private final String shardingItems;
    /**
     * 任务执行状态
     */
    private final State state;
    /**
     * 相关信息
     */
    private final String message;
    /**
     * 记录创建时间
     */
    private Date creationTime = new Date();
}
```

- ExecutionType，执行类型。

  ```java
  public enum ExecutionType {
      
      /**
       * 准备执行的任务.
       */
      READY,
      
      /**
       * 失效转移的任务.
       */
      FAILOVER
  }
  ```

- Source，任务来源。

  ```java
  public enum Source {
     /**
      * Elastic-Job-Cloud 调度器
      */
     CLOUD_SCHEDULER,
     /**
      * Elastic-Job-Cloud 执行器
      */
     CLOUD_EXECUTOR,
     /**
      * Elastic-Job-Lite 执行器
      */
     LITE_EXECUTOR
  }
  ```

- State，任务执行状态。

  ```java
  public enum State {
     /**
      * 开始中
      */
     TASK_STAGING,
     /**
      * 运行中
      */
     TASK_RUNNING,
     /**
      * 完成（正常）
      */
     TASK_FINISHED,
     /**
      * 完成（异常）
      */
     TASK_ERROR,
         
     TASK_KILLED, TASK_LOST, TASK_FAILED,  TASK_DROPPED, TASK_GONE, TASK_GONE_BY_OPERATOR, TASK_UNREACHABLE, TASK_UNKNOWN
  }
  ```

  - Elastic-Job-Lite 使用 TASK_STAGING、TASK_RUNNING、TASK_FINISHED、TASK_ERROR 四种执行状态。
  - Elastic-Job-Cloud 使用所有执行状态。

关系数据库表 `JOB_STATUS_TRACE_LOG` 结构如下：

```sql
CREATE TABLE `JOB_STATUS_TRACE_LOG` (
  `id` varchar(40) COLLATE utf8_bin NOT NULL,
  `job_name` varchar(100) COLLATE utf8_bin NOT NULL,
  `original_task_id` varchar(255) COLLATE utf8_bin NOT NULL,
  `task_id` varchar(255) COLLATE utf8_bin NOT NULL,
  `slave_id` varchar(50) COLLATE utf8_bin NOT NULL,
  `source` varchar(50) COLLATE utf8_bin NOT NULL,
  `execution_type` varchar(20) COLLATE utf8_bin NOT NULL,
  `sharding_item` varchar(100) COLLATE utf8_bin NOT NULL,
  `state` varchar(20) COLLATE utf8_bin NOT NULL,
  `message` varchar(4000) COLLATE utf8_bin DEFAULT NULL,
  `creation_time` timestamp NULL DEFAULT NULL,
  PRIMARY KEY (`id`),
  KEY `TASK_ID_STATE_INDEX` (`task_id`,`state`)
) ENGINE=InnoDB DEFAULT CHARSET=utf8 COLLATE=utf8_bin
```

- Elastic-Job-Lite 一次作业执行记录如下( [打开大图](https://static.iocoder.cn/images/Elastic-Job/2017_11_14/02.png) )：

  ![img](http://blog-1259650185.cosbj.myqcloud.com/img/202204/29/1651211168.png)

**JobStatusTraceEvent 在 Elastic-Job-Lite 发布时机**：

- State.TASK_STAGING：

  ```java
  // AbstractElasticJobExecutor.java
  public final void execute() {
      // ... 省略无关代码
      // 发布作业状态追踪事件(State.TASK_STAGING)
      if (shardingContexts.isAllowSendJobEvent()) {
          jobFacade.postJobStatusTraceEvent(shardingContexts.getTaskId(), State.TASK_STAGING, String.format("Job '%s' execute begin.", jobName));
      }
      // ... 省略无关代码
  }
  ```

- State.TASK_RUNNING：

  ```java
  // AbstractElasticJobExecutor.java
  private void execute(final ShardingContexts shardingContexts, final JobExecutionEvent.ExecutionSource executionSource) {
     // ... 省略无关代码
     // 发布作业状态追踪事件(State.TASK_RUNNING)
     if (shardingContexts.isAllowSendJobEvent()) {
         jobFacade.postJobStatusTraceEvent(taskId, State.TASK_RUNNING, "");
     }
     // ... 省略无关代码
  }
  ```

- State.TASK_FINISHED、State.TASK_ERROR【第一种】：

  ```java
  // AbstractElasticJobExecutor.java
  public final void execute() {
      // ... 省略无关代码
      // 跳过 存在运行中的被错过作业
      if (jobFacade.misfireIfRunning(shardingContexts.getShardingItemParameters().keySet())) {
        // 发布作业状态追踪事件(State.TASK_FINISHED)
        if (shardingContexts.isAllowSendJobEvent()) {
            jobFacade.postJobStatusTraceEvent(shardingContexts.getTaskId(), State.TASK_FINISHED, String.format(
                    "Previous job '%s' - shardingItems '%s' is still running, misfired job will start after previous job completed.", jobName, 
                    shardingContexts.getShardingItemParameters().keySet()));
        }
        return;
      }
  }
  ```

- State.TASK_FINISHED、State.TASK_ERROR【第二种】：

  ```java
  // AbstractElasticJobExecutor.java
  private void execute(final ShardingContexts shardingContexts, final JobExecutionEvent.ExecutionSource executionSource) {
    // ... 省略无关代码
    try {
        process(shardingContexts, executionSource);
    } finally {
        // ... 省略无关代码
        // 根据是否有异常，发布作业状态追踪事件(State.TASK_FINISHED / State.TASK_ERROR)
        if (itemErrorMessages.isEmpty()) {
            if (shardingContexts.isAllowSendJobEvent()) {
                jobFacade.postJobStatusTraceEvent(taskId, State.TASK_FINISHED, "");
            }
        } else {
            if (shardingContexts.isAllowSendJobEvent()) {
                jobFacade.postJobStatusTraceEvent(taskId, State.TASK_ERROR, itemErrorMessages.toString());
            }
        }
    }
  }
  ```

**JobStatusTraceEvent 在 Elastic-Job-Cloud 发布时机**：

Elastic-Job-Cloud 除了上文 Elastic-Job-Lite 会多一个场景下记录作业状态追踪事件( **State.TASK_STAGING** )，实现代码如下：

```java
// TaskLaunchScheduledService.java
private JobStatusTraceEvent createJobStatusTraceEvent(final TaskContext taskContext) {
  TaskContext.MetaInfo metaInfo = taskContext.getMetaInfo();
  JobStatusTraceEvent result = new JobStatusTraceEvent(metaInfo.getJobName(), taskContext.getId(), taskContext.getSlaveId(),
          Source.CLOUD_SCHEDULER, taskContext.getType(), String.valueOf(metaInfo.getShardingItems()), JobStatusTraceEvent.State.TASK_STAGING, "");
  // 失效转移
  if (ExecutionType.FAILOVER == taskContext.getType()) {
      Optional<String> taskContextOptional = facadeService.getFailoverTaskId(metaInfo);
      if (taskContextOptional.isPresent()) {
          result.setOriginalTaskId(taskContextOptional.get());
      }
  }
  return result;
}
```

- 任务提交调度服务( TaskLaunchScheduledService )提交任务时，记录发布作业状态追踪事件(State.TASK_STAGING)。

Elastic-Job-Cloud 根据 Mesos Master 通知任务状态变更，记录**多种**作业状态追踪事件，实现代码如下：

```java
// SchedulerEngine.java
@Override
public void statusUpdate(final SchedulerDriver schedulerDriver, final Protos.TaskStatus taskStatus) {
   String taskId = taskStatus.getTaskId().getValue();
   TaskContext taskContext = TaskContext.from(taskId);
   String jobName = taskContext.getMetaInfo().getJobName();
   log.trace("call statusUpdate task state is: {}, task id is: {}", taskStatus.getState(), taskId);
   //
   jobEventBus.post(new JobStatusTraceEvent(jobName, taskContext.getId(), taskContext.getSlaveId(), Source.CLOUD_SCHEDULER,
           taskContext.getType(), String.valueOf(taskContext.getMetaInfo().getShardingItems()), State.valueOf(taskStatus.getState().name()), taskStatus.getMessage()));
   // ... 省略无关代码
}
```

## 3.2 作业执行追踪事件

JobExecutionEvent，作业执行追踪事件。

代码如下：

```java
public final class JobExecutionEvent implements JobEvent {

    /**
     * 主键
     */
    private String id = UUID.randomUUID().toString();
    /**
     * 主机名称
     */
    private String hostname = IpUtils.getHostName();
    /**
     * IP
     */
    private String ip = IpUtils.getIp();
    /**
     * 作业任务ID
     */
    private final String taskId;
    /**
     * 作业名字
     */
    private final String jobName;
    /**
     * 执行来源
     */
    private final ExecutionSource source;
    /**
     * 作业分片项
     */
    private final int shardingItem;
    /**
     * 开始时间
     */
    private Date startTime = new Date();
    /**
     * 结束时间
     */
    @Setter
    private Date completeTime;
    /**
     * 是否执行成功
     */
    @Setter
    private boolean success;
    /**
     * 执行失败原因
     */
    @Setter
    private JobExecutionEventThrowable failureCause;
}
```

- ExecutionSource，执行来源

  ```java
  public enum ExecutionSource {
     /**
      * 普通触发执行
      */
     NORMAL_TRIGGER,
     /**
      * 被错过执行
      */
     MISFIRE,
     /**
      * 失效转移执行
      */
     FAILOVER
  }
  ```

关系数据库表 `JOB_EXECUTION_LOG` 结构如下：

```sql
CREATE TABLE `JOB_EXECUTION_LOG` (
  `id` varchar(40) COLLATE utf8_bin NOT NULL,
  `job_name` varchar(100) COLLATE utf8_bin NOT NULL,
  `task_id` varchar(255) COLLATE utf8_bin NOT NULL,
  `hostname` varchar(255) COLLATE utf8_bin NOT NULL,
  `ip` varchar(50) COLLATE utf8_bin NOT NULL,
  `sharding_item` int(11) NOT NULL,
  `execution_source` varchar(20) COLLATE utf8_bin NOT NULL,
  `failure_cause` varchar(4000) COLLATE utf8_bin DEFAULT NULL,
  `is_success` int(11) NOT NULL,
  `start_time` timestamp NULL DEFAULT NULL,
  `complete_time` timestamp NULL DEFAULT NULL,
  PRIMARY KEY (`id`)
) ENGINE=InnoDB DEFAULT CHARSET=utf8 COLLATE=utf8_bin
```

- Elastic-Job-Lite 一次作业**多作业分片项**执行记录如下( [打开大图](https://static.iocoder.cn/images/Elastic-Job/2017_11_14/03.png) )：

  ![img](http://blog-1259650185.cosbj.myqcloud.com/img/202204/29/1651211168.png)

**JobExecutionEvent 在 Elastic-Job-Lite 发布时机**：

```java
private void process(final ShardingContexts shardingContexts, final int item, final JobExecutionEvent startEvent) {
   // 发布执行事件(开始)
   if (shardingContexts.isAllowSendJobEvent()) {
       jobFacade.postJobExecutionEvent(startEvent);
   }
   JobExecutionEvent completeEvent;
   try {
       // 执行单个作业
       process(new ShardingContext(shardingContexts, item));
       // 发布执行事件(成功)
       completeEvent = startEvent.executionSuccess();
       if (shardingContexts.isAllowSendJobEvent()) {
           jobFacade.postJobExecutionEvent(completeEvent);
       }
   } catch (final Throwable cause) {
       // 发布执行事件(失败)
       completeEvent = startEvent.executionFailure(cause);
       jobFacade.postJobExecutionEvent(completeEvent);
       // ... 省略无关代码
   }
}
```

**JobExecutionEvent 在 Elastic-Job-Cloud 发布时机**：

和 Elastic-Job-Lite 一致。

## 3.3 作业事件数据库存储

JobEventRdbStorage，作业事件数据库存储。

**创建** JobEventRdbStorage 代码如下：

```
JobEventRdbStorage(final DataSource dataSource) throws SQLException {
   this.dataSource = dataSource;
   initTablesAndIndexes();
}
    
private void initTablesAndIndexes() throws SQLException {
   try (Connection conn = dataSource.getConnection()) {
       createJobExecutionTableAndIndexIfNeeded(conn);
       createJobStatusTraceTableAndIndexIfNeeded(conn);
       databaseType = DatabaseType.valueFrom(conn.getMetaData().getDatabaseProductName());
   }
}
```

- 调用 `#createJobExecutionTableAndIndexIfNeeded(...)` 创建 `JOB_EXECUTION_LOG` 表和索引。
- 调用 `#createJobStatusTraceTableAndIndexIfNeeded(...)` 创建 `JOB_STATUS_TRACE_LOG` 表和索引。

**存储** JobStatusTraceEvent 代码如下：

```java
// JobEventRdbStorage.java
boolean addJobStatusTraceEvent(final JobStatusTraceEvent jobStatusTraceEvent) {
   String originalTaskId = jobStatusTraceEvent.getOriginalTaskId();
   if (State.TASK_STAGING != jobStatusTraceEvent.getState()) {
       originalTaskId = getOriginalTaskId(jobStatusTraceEvent.getTaskId());
   }
   boolean result = false;
   String sql = "INSERT INTO `" + TABLE_JOB_STATUS_TRACE_LOG + "` (`id`, `job_name`, `original_task_id`, `task_id`, `slave_id`, `source`, `execution_type`, `sharding_item`,  " 
           + "`state`, `message`, `creation_time`) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?);";
   // ... 省略你懂的代码
}
    
private String getOriginalTaskId(final String taskId) {
   String sql = String.format("SELECT original_task_id FROM %s WHERE task_id = '%s' and state='%s'", TABLE_JOB_STATUS_TRACE_LOG, taskId, State.TASK_STAGING);
   // ... 省略你懂的代码
   return original_task_id;
}
```

- `originalTaskId`，原任务作业ID。
  - Elastic-Job-Lite 暂未使用到该字段，存储空串( `""` )。
  - Elastic-Job-Cloud 在**作业失效转移**场景下使用该字段，存储失效转移的任务作业ID。

**存储** JobExecutionEvent 代码如下：

```java
// JobEventRdbStorage.java
boolean addJobExecutionEvent(final JobExecutionEvent jobExecutionEvent) {
   if (null == jobExecutionEvent.getCompleteTime()) { // 作业分片项执行开始
       return insertJobExecutionEvent(jobExecutionEvent);
   } else {
       if (jobExecutionEvent.isSuccess()) { // 作业分片项执行完成（正常）
           return updateJobExecutionEventWhenSuccess(jobExecutionEvent);
       } else { // 作业分片项执行完成（异常）
           return updateJobExecutionEventFailure(jobExecutionEvent);
       }
   }
}
```

- 作业分片项执行完成进行的是**更新**操作。

## 3.4 作业事件数据库查询

JobEventRdbSearch，作业事件数据库查询，提供给运维平台调用查询数据。感兴趣的同学点击[链接](https://github.com/dangdangdotcom/elastic-job/blob/8283acf01548222f39f7bfc202a8f89d27728e6c/elastic-job-common/elastic-job-common-core/src/main/java/com/dangdang/ddframe/job/event/rdb/JobEventRdbSearch.java)直接查看。

# 4. 作业监听器

在上文我们看到，作业监听器通过传递作业事件配置( JobEventConfiguration )给作业事件总线( JobEventBus ) **进行创建监听器，并注册监听器到事件总线**。

我们来看下 Elastic-Job 提供的基于**关系数据库**的事件配置实现。

```java
// JobEventConfiguration.java
public interface JobEventConfiguration extends JobEventIdentity {
    
    /**
     * 创建作业事件监听器.
     * 
     * @return 作业事件监听器.
     * @throws JobEventListenerConfigurationException 作业事件监听器配置异常
     */
    JobEventListener createJobEventListener() throws JobEventListenerConfigurationException;
}

// JobEventRdbConfiguration.java
public final class JobEventRdbConfiguration extends JobEventRdbIdentity implements JobEventConfiguration, Serializable {
    
    private final transient DataSource dataSource;
    
    @Override
    public JobEventListener createJobEventListener() throws JobEventListenerConfigurationException {
        try {
            return new JobEventRdbListener(dataSource);
        } catch (final SQLException ex) {
            throw new JobEventListenerConfigurationException(ex);
        }
    }

}
```

- JobEventRdbConfiguration，作业数据库事件配置。调用 `#createJobEventListener()` 创建作业事件数据库监听器( JobEventRdbListener )。

JobEventRdbListener，作业事件数据库监听器。实现代码如下：

```java
// JobEventListener.java
public interface JobEventListener extends JobEventIdentity {
    
    /**
     * 作业执行事件监听执行.
     *
     * @param jobExecutionEvent 作业执行事件
     */
    @Subscribe
    @AllowConcurrentEvents
    void listen(JobExecutionEvent jobExecutionEvent);
    
    /**
     * 作业状态痕迹事件监听执行.
     *
     * @param jobStatusTraceEvent 作业状态痕迹事件
     */
    @Subscribe
    @AllowConcurrentEvents
    void listen(JobStatusTraceEvent jobStatusTraceEvent);
}

// JobEventRdbListener.java
public final class JobEventRdbListener extends JobEventRdbIdentity implements JobEventListener {
    
    private final JobEventRdbStorage repository;
    
    public JobEventRdbListener(final DataSource dataSource) throws SQLException {
        repository = new JobEventRdbStorage(dataSource);
    }
    
    @Override
    public void listen(final JobExecutionEvent executionEvent) {
        repository.addJobExecutionEvent(executionEvent);
    }
    
    @Override
    public void listen(final JobStatusTraceEvent jobStatusTraceEvent) {
        repository.addJobStatusTraceEvent(jobStatusTraceEvent);
    }
}
```

- 通过 JobEventRdbStorage 存储作业事件到关系型数据库。

**如何自定义作业监听器？**

有些同学可能希望使用 ES 或者其他数据库存储作业事件，这个时候可以通过实现 JobEventConfiguration、JobEventListener 进行拓展。

**Elastic-Job-Cloud JobEventConfiguration 怎么配置？**

- Elastic-Job-Cloud-Scheduler：从 `conf/elastic-job-cloud-scheduler.properties` 配置文件读取如下属性，生成 JobEventConfiguration 配置对象。

  - `event_trace_rdb_driver`
  - `event_trace_rdb_url`
  - `event_trace_rdb_username`
  - `event_trace_rdb_password`

- Elastic-Job-Cloud-Executor：通过接收到任务执行信息里读取JobEventConfiguration，实现代码如下：

  ```java
  // TaskExecutor.java
  @Override
  public void registered(final ExecutorDriver executorDriver, final Protos.ExecutorInfo executorInfo, final Protos.FrameworkInfo frameworkInfo, final Protos.SlaveInfo slaveInfo) {
     if (!executorInfo.getData().isEmpty()) {
         Map<String, String> data = SerializationUtils.deserialize(executorInfo.getData().toByteArray());
         BasicDataSource dataSource = new BasicDataSource();
         dataSource.setDriverClassName(data.get("event_trace_rdb_driver"));
         dataSource.setUrl(data.get("event_trace_rdb_url"));
         dataSource.setPassword(data.get("event_trace_rdb_password"));
         dataSource.setUsername(data.get("event_trace_rdb_username"));
         jobEventBus = new JobEventBus(new JobEventRdbConfiguration(dataSource));
     }
  }
  ```

  

## 参考

[Elastic-Job-Lite 源码分析 —— 作业事件追踪](https://www.iocoder.cn/Elastic-Job/job-event-trace/)
