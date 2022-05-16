**本文基于 Elastic-Job V2.1.5 版本分享**

## 1. 概述

本文主要分享 **Elastic-Job-Lite 作业初始化**。

涉及到主要类的类图如下

![img](http://blog-1259650185.cosbj.myqcloud.com/img/202204/26/1650983765.png)

## 2. 作业注册表

作业注册表( JobRegistry )，维护了单个 Elastic-Job-Lite **进程内**作业相关信息，可以理解成其专属的 Spring IOC 容器。因此，其本身是一个**单例**。

```java
public final class JobRegistry {

    /**
     * 单例
     */
    private static volatile JobRegistry instance;
    /**
     * 作业调度控制器集合
     * key：作业名称
     */
    private Map<String, JobScheduleController> schedulerMap = new ConcurrentHashMap<>();
    /**
     * 注册中心集合
     * key：作业名称
     */
    private Map<String, CoordinatorRegistryCenter> regCenterMap = new ConcurrentHashMap<>();
    /**
     * 作业运行实例集合
     * key：作业名称
     */
    private Map<String, JobInstance> jobInstanceMap = new ConcurrentHashMap<>();
    /**
     * 运行中作业集合
     * key：作业名字
     */
    private Map<String, Boolean> jobRunningMap = new ConcurrentHashMap<>();
    /**
     * 作业总分片数量集合
     * key：作业名字
     */
    private Map<String, Integer> currentShardingTotalCountMap = new ConcurrentHashMap<>();
    
    /**
     * 获取作业注册表实例.
     * 
     * @return 作业注册表实例
     */
    public static JobRegistry getInstance() {
        if (null == instance) {
            synchronized (JobRegistry.class) {
                if (null == instance) {
                    instance = new JobRegistry();
                }
            }
        }
        return instance;
    }
    
    // .... 省略方法
}
```

- `instance` 是一个单例，通过 `#getInstance()` 方法获取该单例。该单例的创建方式为**[双重检验锁模式](http://wuchong.me/blog/2014/08/28/how-to-correctly-write-singleton-pattern/#双重检验锁)**。
- Map集合属性**全部**以**作业名称**作为 KEY，通过作业名称，可以获得作业相关信息。
- 省略的方法，下文在实际调用时，进行解析。

# 3. 作业调度器

作业调度器( JobScheduler )，创建并初始化后，进行作业调度。

**Elastic-Job-Lite 使用 Quartz 作为调度内核。**

## 3.1 创建

```java
public class JobScheduler {
    /**
     * Lite作业配置
     */
    private final LiteJobConfiguration liteJobConfig;
    /**
     * 注册中心
     */
    private final CoordinatorRegistryCenter regCenter;
    /**
     * 调度器门面对象
     */
    @Getter
    private final SchedulerFacade schedulerFacade;
    /**
     * 作业门面对象
     */
    private final JobFacade jobFacade;
    
    public JobScheduler(final CoordinatorRegistryCenter regCenter, final LiteJobConfiguration liteJobConfig, final ElasticJobListener... elasticJobListeners) {
        this(regCenter, liteJobConfig, new JobEventBus(), elasticJobListeners);
    }
    
    public JobScheduler(final CoordinatorRegistryCenter regCenter, final LiteJobConfiguration liteJobConfig, final JobEventConfiguration jobEventConfig, 
                        final ElasticJobListener... elasticJobListeners) {
        this(regCenter, liteJobConfig, new JobEventBus(jobEventConfig), elasticJobListeners);
    }
    
    private JobScheduler(final CoordinatorRegistryCenter regCenter, final LiteJobConfiguration liteJobConfig, final JobEventBus jobEventBus, final ElasticJobListener... elasticJobListeners) {
        // 添加 作业运行实例
        JobRegistry.getInstance().addJobInstance(liteJobConfig.getJobName(), new JobInstance());
        // 设置 Lite作业配置
        this.liteJobConfig = liteJobConfig;
        this.regCenter = regCenter;
        // 设置 作业监听器
        List<ElasticJobListener> elasticJobListenerList = Arrays.asList(elasticJobListeners);
        setGuaranteeServiceForElasticJobListeners(regCenter, elasticJobListenerList);
        // 设置 调度器门面对象
        schedulerFacade = new SchedulerFacade(regCenter, liteJobConfig.getJobName(), elasticJobListenerList);
        // 设置 作业门面对象
        jobFacade = new LiteJobFacade(regCenter, liteJobConfig.getJobName(), Arrays.asList(elasticJobListeners), jobEventBus);
    }
}
```

- 调用 `#JobRegistry#addJobInstance()` 方法添**加作业运行实例( JobInstance )**。

  ```java
  // JobRegistry.java
  /**
  * 作业运行实例集合
  * key：作业名称
  */
  private Map<String, JobInstance> jobInstanceMap = new ConcurrentHashMap<>();
  /**
  * 添加作业实例.
  *
  * @param jobName 作业名称
  * @param jobInstance 作业实例
  */
  public void addJobInstance(final String jobName, final JobInstance jobInstance) {
     jobInstanceMap.put(jobName, jobInstance);
  }
  
  // JobInstance.java
  public final class JobInstance {
  
      private static final String DELIMITER = "@-@";
      
      /**
       * 作业实例主键.
       */
      private final String jobInstanceId;
      
      public JobInstance() {
          jobInstanceId = IpUtils.getIp()
                  + DELIMITER
                  + ManagementFactory.getRuntimeMXBean().getName().split("@")[0]; // PID
      }
  
  }
  ```

  - `jobInstanceId` 格式：`${IP}@-@${PID}`。其中 `PID` 为进程编号。同一个 Elastic-Job-Lite 实例，**不同**的作业使用**相同**的作业实例主键。

- 设置作业监听器，在[《Elastic-Job-Lite 源码解析 —— 作业监听器》](http://www.iocoder.cn/Elastic-Job/job-listener/?self)详细分享。

- SchedulerFacade，为**调度器**提供内部服务的门面类。

  ```java
  public final class SchedulerFacade {
  
      /**
       * 作业名称
       */
      private final String jobName;
      /**
       * 作业配置服务
       */
      private final ConfigurationService configService;
      /**
       * 作业分片服务
       */
      private final ShardingService shardingService;
      /**
       * 主节点服务
       */
      private final LeaderService leaderService;
      /**
       * 作业服务器服务
       */
      private final ServerService serverService;
      /**
       * 作业运行实例服务
       */
      private final InstanceService instanceService;
      /**
       * 执行作业服务
       */
      private final ExecutionService executionService;
      /**
       * 作业监控服务
       */
      private final MonitorService monitorService;
      /**
       * 调解作业不一致状态服务
       */
      private final ReconcileService reconcileService;
      /**
       * 作业注册中心的监听器管理者
       */
      private ListenerManager listenerManager;
      
      public SchedulerFacade(final CoordinatorRegistryCenter regCenter, final String jobName, final List<ElasticJobListener> elasticJobListeners) {
          this.jobName = jobName;
          // .... 省略 new XXXXX() 对象
      }
  ```

  

- LiteJobFacade，为**作业**提供内部服务的门面类。

  ```java
  public final class LiteJobFacade implements JobFacade {
      /**
       * 作业配置服务
       */
      private final ConfigurationService configService;
      /**
       * 作业分片服务
       */
      private final ShardingService shardingService;
      /**
       * 执行作业服务
       */
      private final ExecutionService executionService;
      /**
       * 作业运行时上下文服务
       */
      private final ExecutionContextService executionContextService;
      /**
       * 作业失效转移服务
       */
      private final FailoverService failoverService;
      /**
       * 作业监听器数组
       */
      private final List<ElasticJobListener> elasticJobListeners;
      /**
       * 作业事件总线
       */
      private final JobEventBus jobEventBus;
      
      public LiteJobFacade(final CoordinatorRegistryCenter regCenter, final String jobName, final List<ElasticJobListener> elasticJobListeners, final JobEventBus jobEventBus) {
          // .... 省略 new XXXXX() 对象
          failoverService = new FailoverService(regCenter, jobName);
          this.elasticJobListeners = elasticJobListeners;
          this.jobEventBus = jobEventBus;
      }
  }
  ```

SchedulerFacade 和 LiteJobFacade，看起来很相近，实际差别很大。它们分别为调度器、作业提供需要的方法。下文也会体现这一特点。

## 3.2 初始化

作业调度器创建后，调用 `#init()` 方法初始化，作业方**开始**调度。

```java
/**
* 初始化作业.
*/
public void init() {
   // 更新 作业配置
   LiteJobConfiguration liteJobConfigFromRegCenter = schedulerFacade.updateJobConfiguration(liteJobConfig);
   // 设置 当前作业分片总数
   JobRegistry.getInstance().setCurrentShardingTotalCount(liteJobConfigFromRegCenter.getJobName(), liteJobConfigFromRegCenter.getTypeConfig().getCoreConfig().getShardingTotalCount());
   // 创建 作业调度控制器
   JobScheduleController jobScheduleController = new JobScheduleController(
           createScheduler(), createJobDetail(liteJobConfigFromRegCenter.getTypeConfig().getJobClass()), liteJobConfigFromRegCenter.getJobName());
   // 添加 作业调度控制器
   JobRegistry.getInstance().registerJob(liteJobConfigFromRegCenter.getJobName(), jobScheduleController, regCenter);
   // 注册 作业启动信息
   schedulerFacade.registerStartUpInfo(!liteJobConfigFromRegCenter.isDisabled());
   // 调度作业
   jobScheduleController.scheduleJob(liteJobConfigFromRegCenter.getTypeConfig().getCoreConfig().getCron());
}
```

### 3.2.1 更新作业配置

```java
// SchedulerFacade.java
/**
* 更新作业配置.
*
* @param liteJobConfig 作业配置
* @return 更新后的作业配置
*/
public LiteJobConfiguration updateJobConfiguration(final LiteJobConfiguration liteJobConfig) {
   // 更新 作业配置
   configService.persist(liteJobConfig);
   // 读取 作业配置
   return configService.load(false);
}
```

- 从[《Elastic-Job 源码分析 —— 作业配置》](http://www.iocoder.cn/Elastic-Job/job-config/?self)的「3.2 持久化作业配置」，调用 `ConfigService#persist(...)` 方法也不一定会更新作业配置，因此调用 `ConfigService#load(...)` 方法返回的可能是本地的作业配置，也可能是**注册中心**存储的作业配置。

### 3.2.2 设置当前作业分片总数

```java
// JobRegistry.java
private Map<String, Integer> currentShardingTotalCountMap = new ConcurrentHashMap<>();
/**
* 设置当前分片总数.
*
* @param jobName 作业名称
* @param currentShardingTotalCount 当前分片总数
*/
public void setCurrentShardingTotalCount(final String jobName, final int currentShardingTotalCount) {
   currentShardingTotalCountMap.put(jobName, currentShardingTotalCount);
}
```

### 3.2.3 创建作业调度控制器

```java
public void init() {
   // .... 省略
   // 创建 作业调度控制器
   JobScheduleController jobScheduleController = new JobScheduleController(
           createScheduler(), createJobDetail(liteJobConfigFromRegCenter.getTypeConfig().getJobClass()), liteJobConfigFromRegCenter.getJobName());
   // .... 省略
}
```

- JobScheduleController，作业调度控制器，提供对 Quartz 方法的封装：

  ```java
  public final class JobScheduleController {
  
      /**
       * Quartz 调度器
       */
      private final Scheduler scheduler;
      /**
       * 作业信息
       */
      private final JobDetail jobDetail;
      /**
       * 触发器编号
       * 目前使用工作名字( jobName )
       */
      private final String triggerIdentity;
      
      public void scheduleJob(final String cron) {} // 调度作业
      public synchronized void rescheduleJob(final String cron) {} // 重新调度作业
      private CronTrigger createTrigger(final String cron) {} // 创建触发器
      public synchronized boolean isPaused() {} // 判断作业是否暂停
      public synchronized void pauseJob() {} // 暂停作业
      public synchronized void resumeJob() {} // 恢复作业
      public synchronized void triggerJob() {} // 立刻启动作业
      public synchronized void shutdown() {} // 关闭调度器
  }
  ```

- 调用 `#createScheduler()` 方法创建 Quartz 调度器：

  ```java
  // JobScheduler.java
  private Scheduler createScheduler() {
     Scheduler result;
     try {
         StdSchedulerFactory factory = new StdSchedulerFactory();
         factory.initialize(getBaseQuartzProperties());
         result = factory.getScheduler();
         result.getListenerManager().addTriggerListener(schedulerFacade.newJobTriggerListener());
     } catch (final SchedulerException ex) {
         throw new JobSystemException(ex);
     }
     return result;
  }
      
  private Properties getBaseQuartzProperties() {
     Properties result = new Properties();
     result.put("org.quartz.threadPool.class", org.quartz.simpl.SimpleThreadPool.class.getName());
     result.put("org.quartz.threadPool.threadCount", "1"); // Quartz 线程数：1
     result.put("org.quartz.scheduler.instanceName", liteJobConfig.getJobName());
     result.put("org.quartz.jobStore.misfireThreshold", "1");
     result.put("org.quartz.plugin.shutdownhook.class", JobShutdownHookPlugin.class.getName()); // 作业关闭钩子
     result.put("org.quartz.plugin.shutdownhook.cleanShutdown", Boolean.TRUE.toString()); // 关闭时，清理所有资源
     return result;
  }
  ```

  - `org.quartz.threadPool.threadCount = 1`，即 Quartz 执行作业线程数量为 1。原因：**一个作业( ElasticJob )的调度，需要配置独有的一个作业调度器( JobScheduler )**，两者是 `1 : 1` 的关系。
  - `org.quartz.plugin.shutdownhook.class` 设置作业**优雅关闭**钩子：[JobShutdownHookPlugin](https://github.com/dangdangdotcom/elastic-job/blob/7dc099541a16de49f024fc59e46377a726be7f6b/elastic-job-lite/elastic-job-lite-core/src/main/java/com/dangdang/ddframe/job/lite/internal/schedule/JobShutdownHookPlugin.java)。
  - 触发器监听器( TriggerListener )，在[《Elastic-Job-Lite 源码解析 —— 作业执行》](http://www.iocoder.cn/Elastic-Job/job-execute/?self)详细分享。

- 调用 `#createJobDetail()` 方法创建 Quartz 作业：

  ```java
  // JobScheduler.java
  private JobDetail createJobDetail(final String jobClass) {
     // 创建 Quartz 作业
     JobDetail result = JobBuilder.newJob(LiteJob.class).withIdentity(liteJobConfig.getJobName()).build();
     //
     result.getJobDataMap().put(JOB_FACADE_DATA_MAP_KEY, jobFacade);
     // 创建 Elastic-Job 对象
     Optional<ElasticJob> elasticJobInstance = createElasticJobInstance();
     if (elasticJobInstance.isPresent()) {
         result.getJobDataMap().put(ELASTIC_JOB_DATA_MAP_KEY, elasticJobInstance.get());
     } else if (!jobClass.equals(ScriptJob.class.getCanonicalName())) {
         try {
             result.getJobDataMap().put(ELASTIC_JOB_DATA_MAP_KEY, Class.forName(jobClass).newInstance());
         } catch (final ReflectiveOperationException ex) {
             throw new JobConfigurationException("Elastic-Job: Job class '%s' can not initialize.", jobClass);
         }
     }
     return result;
  }
      
  protected Optional<ElasticJob> createElasticJobInstance() {
     return Optional.absent();
  }
      
  // SpringJobScheduler.java
  @Override
  protected Optional<ElasticJob> createElasticJobInstance() {
     return Optional.fromNullable(elasticJob);
  }
  ```

  - 创建 Quartz 作业设置了 LiteJob 类，这样 Quartz 触发作业执行时，LiteJob 会去调用 Elastic-Job 作业对象。在[《Elastic-Job-Lite 源码解析 —— 作业执行》](http://www.iocoder.cn/Elastic-Job/job-execute/?self)详细分享。
  - 在 Spring 里，Elastic-Job 如果已经创建好**注入**到 SpringJobScheduler，无需进行创建。
  - `Jodetail.jobDataMap` 属性里添加了作业门面对象( LiteJobFacade )、Elastic-Job 对象，Quartz 触发作业时，会设置到 LiteJob 对象里。

### 3.2.4 注册作业启动信息

```java
/**
* 注册作业启动信息.
* 
* @param enabled 作业是否启用
*/
public void registerStartUpInfo(final boolean enabled) {
   // 开启 所有监听器
   listenerManager.startAllListeners();
   // 选举 主节点
   leaderService.electLeader();
   // 持久化 作业服务器上线信息
   serverService.persistOnline(enabled);
   // 持久化 作业运行实例上线相关信息
   instanceService.persistOnline();
   // 设置 需要重新分片的标记
   shardingService.setReshardingFlag();
   // 初始化 作业监听服务
   monitorService.listen();
   // 初始化 调解作业不一致状态服务
   if (!reconcileService.isRunning()) {
       reconcileService.startAsync();
   }
}
```

- 开启所有监听器。每个功能模块都有其相应的监听器，在[模块对应「文章」](https://static.iocoder.cn/images/common/wechat_mp_2017_07_31_bak.jpg)详细分享。

- 选举主节点，在[《Elastic-Job-Lite 源码解析 —— 主节点选举》](http://www.iocoder.cn/Elastic-Job/election/?self)详细分享。

- 调用 `ServerService#persistOnline()` 方法，持久化作业服务器上线信息。

  ```java
  public final class ServerService {
      /**
       * 持久化作业服务器上线信息.
       * 
       * @param enabled 作业是否启用
       */
      public void persistOnline(final boolean enabled) {
          if (!JobRegistry.getInstance().isShutdown(jobName)) {
              jobNodeStorage.fillJobNode(serverNode.getServerNode(JobRegistry.getInstance().getJobInstance(jobName).getIp()), enabled ? "" : ServerStatus.DISABLED.name());
          }
      }
  }
  ```

  - 当作业配置设置作业**禁用**时( `LiteJobConfiguration.disabled = true` )，作业调度但**调度作业分片为空**。不太好理解？[《Elastic-Job-Lite 源码解析 —— 作业分片》](http://www.iocoder.cn/Elastic-Job/job-sharding/?self)详细分享。

- 调用 `InstanceService#persistOnline()` 方法，持久化作业运行实例上线相关信息：

  ```java
  public final class InstanceService {
      /**
       * 持久化作业运行实例上线相关信息.
       */
      public void persistOnline() {
          jobNodeStorage.fillEphemeralJobNode(instanceNode.getLocalInstanceNode(), "");
      }
  }
  ```

- 设置需要重新分片的标记，在[《Elastic-Job-Lite 源码解析 —— 作业分片》](http://www.iocoder.cn/Elastic-Job/job-sharding/?self)详细分享。

- 初始化作业监听服务，在[《Elastic-Job-Lite 源码解析 —— 作业监控服务》](http://www.iocoder.cn/Elastic-Job/job-monitor/?self)详细分享。

- 初始化调解作业不一致状态服务，在[《Elastic-Job-Lite 源码解析 —— 自诊断修复》](http://www.iocoder.cn/Elastic-Job/reconcile/?self)详细分享。

### 3.2.5 调度作业

```java
// JobScheduler.java
public void init() {
   // .... 省略部分代码
   // 调度作业
   jobScheduleController.scheduleJob(liteJobConfigFromRegCenter.getTypeConfig().getCoreConfig().getCron());
}

// JobScheduleController.java
/**
* 调度作业.
*
* @param cron CRON表达式
*/
public void scheduleJob(final String cron) {
   try {
       if (!scheduler.checkExists(jobDetail.getKey())) {
           scheduler.scheduleJob(jobDetail, createTrigger(cron));
       }
       scheduler.start();
   } catch (final SchedulerException ex) {
       throw new JobSystemException(ex);
   }
}
```

- 调用 `#scheduleJob()` 方法后，该 Elastic-Job 作业**开始**被调度。



## 参考

[Elastic-Job-Lite 源码分析 —— 作业初始化](https://www.iocoder.cn/Elastic-Job/job-init/)
