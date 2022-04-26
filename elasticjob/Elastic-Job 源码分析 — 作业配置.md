## 1. 概述

本文主要分享 **Elastic-Job-Lite 作业配置**。

涉及到主要类的类图如下

![img](http://blog-1259650185.cosbj.myqcloud.com/img/202204/26/1650976701.png)

- **黄色**的类在 `elastic-job-common-core` 项目里，为 Elastic-Job-Lite、Elastic-Job-Cloud **公用**作业配置类。

## 2. 作业配置

**一个作业( ElasticJob )的调度，需要配置独有的一个作业调度器( JobScheduler )**，两者是 1 : 1 的关系。这点大家要注意下，当然下文看代码也会看到。

作业调度器的创建可以配置四个参数：

1. 注册中心( CoordinatorRegistryCenter )：用于协调分布式服务。**必填**。
2. Lite作业配置( LiteJobConfiguration )：**必填**。
3. 作业事件总线( JobEventBus )：对作业事件**异步**监听。**选填**。
4. 作业监听器( ElasticJobListener )：对作业执行前，执行后进行**同步**监听。**选填**。

### 2.1 注册中心配置

Elastic-Job 抽象了**注册中心接口( RegistryCenter )**，并提供了默认**基于 Zookeeper 的注册中心实现( ZookeeperRegistryCenter )**。

ZookeeperRegistryCenter 对应配置类为 ZookeeperConfiguration。该类注释很完整，可以点击[链接](https://github.com/dangdangdotcom/elastic-job/blob/7dc099541a16de49f024fc59e46377a726be7f6b/elastic-job-common/elastic-job-common-core/src/main/java/com/dangdang/ddframe/job/reg/zookeeper/ZookeeperConfiguration.java)直接查看源码，这里我们重点说下 `namespace` 属性。如果你有多个**不同** Elastic-Job集群时，使用相同 Zookeeper，可以配置不同的 `namespace` 进行隔离。

注册中心的**初始化**，我们会在[《Elastic-Job-Lite 源码解析 —— 注册中心》](http://www.iocoder.cn/Elastic-Job/reg-center-zookeeper/?self)详细分享。

### 2.2 Lite作业配置

[LiteJobConfiguration](https://github.com/dangdangdotcom/elastic-job/blob/6617853bf059df373e2cb6ce959038c583ae5064/elastic-job-lite/elastic-job-lite-core/src/main/java/com/dangdang/ddframe/job/lite/config/LiteJobConfiguration.java) 继承自接口 [JobRootConfiguration](https://github.com/dangdangdotcom/elastic-job/blob/6617853bf059df373e2cb6ce959038c583ae5064/elastic-job-common/elastic-job-common-core/src/main/java/com/dangdang/ddframe/job/config/JobRootConfiguration.java)，作为 Elastic-Job-Lite 里的作业( LiteJob )配置。*Elastic-Job-Cloud 的作业( CloudJob )对应另外的配置类，也实现了该接口。*

````java
public final class LiteJobConfiguration implements JobRootConfiguration {
    
    private final JobTypeConfiguration typeConfig;
    private final boolean monitorExecution;
    private final int maxTimeDiffSeconds;
    private final int monitorPort;
    private final String jobShardingStrategyClass;
    private final int reconcileIntervalMinutes;
    private final boolean disabled;
    private final boolean overwrite;
    
    // .... 省略部分get方法
    
    public static class Builder {
    
        // .... 省略部分属性
    
        public final LiteJobConfiguration build() {
            return new LiteJobConfiguration(jobConfig, monitorExecution, maxTimeDiffSeconds, monitorPort, jobShardingStrategyClass, reconcileIntervalMinutes, disabled, overwrite);
        }
    }
}
````

- `typeConfig`：作业类型配置。**必填**。

- `monitorExecution`：监控作业运行时状态。默认为 `false`。选填。在[《Elastic-Job-Lite 源码解析 —— 作业执行》](http://www.iocoder.cn/Elastic-Job/job-execute/?self)详细分享。

  > 每次作业执行时间和间隔时间均**非常短**的情况，建议不监控作业运行时状态以提升效率。因为是瞬时状态，所以无必要监控。请用户自行增加数据堆积监控。并且不能保证数据重复选取，应在作业中实现幂等性。
  > 每次作业执行时间和间隔时间均**较长的**情况，建议监控作业运行时状态，可保证数据不会重复选取。

- `monitorPort`：作业监控端口。默认为 `-1`，不开启作业监控端口。选填。在[《Elastic-Job-Lite 源码解析 —— 作业监控服务》](http://www.iocoder.cn/Elastic-Job/job-monitor/?self)详细分享。

  > 建议配置作业监控端口, 方便开发者dump作业信息。
  > 使用方法: echo “dump” | nc 127.0.0.1 9888

- `maxTimeDiffSeconds`：设置最大容忍的本机与注册中心的时间误差秒数。默认为 `-1`，不检查时间误差。选填。

- `jobShardingStrategyClass`：作业分片策略实现类全路径。默认为使用分配侧路。选填。在[《Elastic-Job-Lite 源码解析 —— 作业分片策略》](http://www.iocoder.cn/Elastic-Job/job-sharding-strategy/?self)详细分享。

- `reconcileIntervalMinutes`：修复作业服务器不一致状态服务调度间隔时间，配置为小于1的任意值表示不执行修复。默认为 `10`。在[《Elastic-Job-Lite 源码解析 —— 自诊断修复 》](http://www.iocoder.cn/Elastic-Job/reconcile/?self)详细分享。

- `disabled`：作业是否禁用执行。默认为 `false`。选填。

- `overwrite`：设置使用本地作业配置覆盖注册中心的作业配置。默认为 `false`。选填。建议使用**运维平台( console )**配置作业配置，统一管理。

- Builder 类：使用该类配置 LiteJobConfiguration 属性，调用 `#build()` 方法最终生成作业配置。参见：[《JAVA设计模式 — 生成器模式(Builder)》](http://blog.csdn.net/top_code/article/details/8469297)。

#### 2.2.1 作业类型配置

作业类型配置**接口**( [JobTypeConfiguration](https://github.com/dangdangdotcom/elastic-job/blob/6617853bf059df373e2cb6ce959038c583ae5064/elastic-job-common/elastic-job-common-core/src/main/java/com/dangdang/ddframe/job/config/JobTypeConfiguration.java) ) 有三种配置实现，针对三种作业类型：

| 配置实现                                                     | 作业        | 说明                                                     |
| :----------------------------------------------------------- | :---------- | :------------------------------------------------------- |
| [SimpleJobConfiguration](https://github.com/dangdangdotcom/elastic-job/blob/6617853bf059df373e2cb6ce959038c583ae5064/elastic-job-common/elastic-job-common-core/src/main/java/com/dangdang/ddframe/job/config/simple/SimpleJobConfiguration.java) | SimpleJob   | 简单作业。例如：订单过期作业                             |
| [DataflowJobConfiguration](https://github.com/dangdangdotcom/elastic-job/blob/6617853bf059df373e2cb6ce959038c583ae5064/elastic-job-common/elastic-job-common-core/src/main/java/com/dangdang/ddframe/job/config/dataflow/DataflowJobConfiguration.java) | DataflowJob | 数据流作业。TODO：笔者暂时未了解流式处理数据，不误人子弟 |
| [ScriptJobConfiguration](https://github.com/dangdangdotcom/elastic-job/blob/6617853bf059df373e2cb6ce959038c583ae5064/elastic-job-common/elastic-job-common-core/src/main/java/com/dangdang/ddframe/job/config/script/ScriptJobConfiguration.java) | ScriptJob   | 脚本作业。例如：调用 shell 脚本备份数据库作业            |

种**配置类**属性对比如：

| 属性                | SimpleJob      | DataflowJob      | ScriptJob                 | 说明                 |
| :------------------ | :------------- | :--------------- | :------------------------ | :------------------- |
| `coreConfig`        | √              | √                | √                         | 作业核心配置         |
| `jobType`           | JobType.SIMPLE | JobType.DATAFLOW | JobType.SCRIPT            | 作业类型             |
| `jobClass`          | √              | √                | √ (默认：ScriptJob.class) | 作业实现类全路径     |
| `streamingProcess`  |                | √                |                           | 是否流式处理数据     |
| `scriptCommandLine` |                |                  | √                         | 脚本型作业执行命令行 |

**作业类型配置不仅仅适用于 Elastic-Job-Lite，也适用于 Elastic-Job-Cloud。**

#### 2.2.2 作业核心配置

作业核心配置( JobCoreConfiguration )，我们可以看到在每种作业类型配置（[JobTypeConfiguration](https://github.com/dangdangdotcom/elastic-job/blob/6617853bf059df373e2cb6ce959038c583ae5064/elastic-job-common/elastic-job-common-core/src/main/java/com/dangdang/ddframe/job/config/JobTypeConfiguration.java) ）都有该属性( `coreConfig` )。

```java
public final class JobCoreConfiguration {
    
    private final String jobName;
    private final String cron;
    private final int shardingTotalCount;
    private final String shardingItemParameters;
    private final String jobParameter;
    private final boolean failover;
    private final boolean misfire;
    private final String description;
    private final JobProperties jobProperties;
    
    public static class Builder {
    
        // .... 省略部分属性
    
        public final JobCoreConfiguration build() {
            Preconditions.checkArgument(!Strings.isNullOrEmpty(jobName), "jobName can not be empty.");
            Preconditions.checkArgument(!Strings.isNullOrEmpty(cron), "cron can not be empty.");
            Preconditions.checkArgument(shardingTotalCount > 0, "shardingTotalCount should larger than zero.");
            return new JobCoreConfiguration(jobName, cron, shardingTotalCount, shardingItemParameters, jobParameter, failover, misfire, description, jobProperties);
        }
    }
}
```

- `jobName`：作业名称。**必填。**

- `cron`：cron表达式，用于控制作业触发时间。**必填。**

- `shardingTotalCount`：作业分片总数。如果一个作业启动超过作业分片总数的节点，只有 `shardingTotalCount` 会执行作业。**必填。**在[《Elastic-Job-Lite 源码解析 —— 作业分片策略 》](http://www.iocoder.cn/Elastic-Job/job-sharding-strategy/?self)详细分享。

- `shardingItemParameters`：分片序列号和参数。选填。

  > 分片序列号和参数用等号分隔，多个键值对用逗号分隔
  > 分片序列号从0开始，**不可大于或等于**作业分片总数
  > 如：
  > 0=a,1=b,2=c

- `jobParameter`：作业自定义参数。选填。

  > 作业自定义参数，可通过传递该参数为作业调度的业务方法传参，用于实现带参数的作业
  > 例：每次获取的数据量、作业实例从数据库读取的主键等

- `failover`：是否开启作业执行失效转移。**开启表示如果作业在一次作业执行中途宕机，允许将该次未完成的作业在另一作业节点上补偿执行**。默认为 `false`。选填。在[《Elastic-Job-Lite 源码解析 —— 作业失效转移 》](http://www.iocoder.cn/Elastic-Job/job-failover/?self)详细分享。

- `misfire`：是否开启错过作业重新执行。默认为 `true`。选填。在[《Elastic-Job-Lite 源码解析 —— 作业执行 》](http://www.iocoder.cn/Elastic-Job/job-execute/?self)详细分享。

- `description`：作业描述。选填。

- `jobProperties`：作业属性配置。选填。在[《Elastic-Job-Lite 源码解析 —— 作业执行 》](http://www.iocoder.cn/Elastic-Job/job-execute/?self)详细分享。

  ```java
  public final class JobProperties {
      
      private EnumMap<JobPropertiesEnum, String> map = new EnumMap<>(JobPropertiesEnum.class);
      
     public enum JobPropertiesEnum {
          
          /**
           * 作业异常处理器.
           */
          JOB_EXCEPTION_HANDLER("job_exception_handler", JobExceptionHandler.class, DefaultJobExceptionHandler.class.getCanonicalName()),
          
          /**
           * 线程池服务处理器.
           */
          EXECUTOR_SERVICE_HANDLER("executor_service_handler", ExecutorServiceHandler.class, DefaultExecutorServiceHandler.class.getCanonicalName());
          
          private final String key;
      
          private final Class<?> classType;
          
          private final String defaultValue;
     }
  }
  ```

  - `JOB_EXCEPTION_HANDLER`：用于扩展**异常处理**类。
  - `EXECUTOR_SERVICE_HANDLER`：用于扩展**作业处理线程池**类。
  - 通过这个属性，我们可以自定义**每个作业**的异常处理和线程池服务。

### 2.3 作业事件配置

通过作业事件配置( JobEventConfiguration )，实现对作业事件的**异步**监听、处理。在[《Elastic-Job-Lite 源码解析 —— 作业事件追踪》](http://www.iocoder.cn/Elastic-Job/job-event-trace/?self)详细分享。

### 2.4 作业监听器

通过配置作业监听器( ElasticJobListener )，实现对作业执行的**同步**监听、处理。在[《Elastic-Job-Lite 源码解析 —— 作业监听器》](http://www.iocoder.cn/Elastic-Job/job-listener/?self)详细分享。

## 3. 作业配置服务

多个 Elastic-Job-Lite 使用相同**注册中心**和相同 **`namespace`** 组成集群，实现高可用。集群中，使用作业配置服务( ConfigurationService ) 共享作业配置。

```java
public final class ConfigurationService {

    /**
     * 时间服务
     */
    private final TimeService timeService;
    /**
     * 作业节点数据访问类
     */
    private final JobNodeStorage jobNodeStorage;
    
    public ConfigurationService(final CoordinatorRegistryCenter regCenter, final String jobName) {
        jobNodeStorage = new JobNodeStorage(regCenter, jobName);
        timeService = new TimeService();
    }
}
```

- JobNodeStorage，封装注册中心，提供存储服务。在[《Elastic-Job-Lite 源码解析 —— 作业数据存储》](http://www.iocoder.cn/Elastic-Job/job-storage/?self)详细分享。

- TimeService，时间服务，提供当前时间查询。

  ```java
  public final class TimeService {
      
      /**
       * 获取当前时间的毫秒数.
       * 
       * @return 当前时间的毫秒数
       */
      public long getCurrentMillis() {
          return System.currentTimeMillis();
      }
  }
  ```

#### 3.1 读取作业配置

```java
/**
* 读取作业配置.
* 
* @param fromCache 是否从缓存中读取
* @return 作业配置
*/
public LiteJobConfiguration load(final boolean fromCache) {
   String result;
   if (fromCache) { // 缓存
       result = jobNodeStorage.getJobNodeData(ConfigurationNode.ROOT);
       if (null == result) {
           result = jobNodeStorage.getJobNodeDataDirectly(ConfigurationNode.ROOT);
       }
   } else {
       result = jobNodeStorage.getJobNodeDataDirectly(ConfigurationNode.ROOT);
   }
   return LiteJobConfigurationGsonFactory.fromJson(result);
}
```

### 3.2 持久化作业配置

```java
/**
* 持久化分布式作业配置信息.
* 
* @param liteJobConfig 作业配置
*/
public void persist(final LiteJobConfiguration liteJobConfig) {
   checkConflictJob(liteJobConfig);
   if (!jobNodeStorage.isJobNodeExisted(ConfigurationNode.ROOT) || liteJobConfig.isOverwrite()) {
       jobNodeStorage.replaceJobNode(ConfigurationNode.ROOT, LiteJobConfigurationGsonFactory.toJson(liteJobConfig));
   }
}
```

- 调用 `#checkConflictJob(...)` 方法**校验**注册中心存储的作业配置的作业实现类全路径( `jobClass` )和当前的是否相同，如果不同，则认为是**冲突**，不允许存储：

  ```java
  private void checkConflictJob(final LiteJobConfiguration liteJobConfig) {
     Optional<LiteJobConfiguration> liteJobConfigFromZk = find();
     if (liteJobConfigFromZk.isPresent()
             && !liteJobConfigFromZk.get().getTypeConfig().getJobClass().equals(liteJobConfig.getTypeConfig().getJobClass())) { // jobClass 是否相同
         throw new JobConfigurationException("Job conflict with register center. The job '%s' in register center's class is '%s', your job class is '%s'", 
                 liteJobConfig.getJobName(), liteJobConfigFromZk.get().getTypeConfig().getJobClass(), liteJobConfig.getTypeConfig().getJobClass());
     }
  }
  ```

- 当注册中心**未存储**该作业配置 或者 当前作业配置允许替换注册中心作业配置( `overwrite = true` )时，持久化作业配置。

## 3.3 校验本机时间是否合法

```java
/**
* 检查本机与注册中心的时间误差秒数是否在允许范围.
* 
* @throws JobExecutionEnvironmentException 本机与注册中心的时间误差秒数不在允许范围所抛出的异常
*/
public void checkMaxTimeDiffSecondsTolerable() throws JobExecutionEnvironmentException {
   int maxTimeDiffSeconds =  load(true).getMaxTimeDiffSeconds();
   if (-1  == maxTimeDiffSeconds) {
       return;
   }
   long timeDiff = Math.abs(timeService.getCurrentMillis() - jobNodeStorage.getRegistryCenterTime());
   if (timeDiff > maxTimeDiffSeconds * 1000L) {
       throw new JobExecutionEnvironmentException(
               "Time different between job server and register center exceed '%s' seconds, max time different is '%s' seconds.", timeDiff / 1000, maxTimeDiffSeconds);
   }
}
```

- Elastic-Job-Lite 作业触发是**依赖本机时间**，相同集群使用注册中心时间为基准，校验本机与注册中心的时间误差是否在允许范围内( `LiteJobConfiguration.maxTimeDiffSeconds` )。



## 参考

[Elastic-Job-Lite 源码分析 —— 作业配置](https://www.iocoder.cn/Elastic-Job/job-config/)
