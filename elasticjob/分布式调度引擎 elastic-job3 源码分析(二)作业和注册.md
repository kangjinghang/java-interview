服务可分为功能服务和核心服务，其中核心服务是支撑功能服务的服务，功能任务有任务注册，任务执行，失效转移等，是调度平台的”业务”功能。

## 1.1 作业模型和执行器设计

![img](http://blog-1259650185.cosbj.myqcloud.com/img/202204/25/1650816730.png)

ElasticJob：标记类

ElasticJobExecutor：作业执行逻辑，使用 JobItemExecutor 执行作业，在 1.2 作业注册和调度 进一步分析

JobItemExecutor：两类作业，Typed/Classed，Typed 类型作业实现远程调用执行器， 如 http，feign，不用实现作业类，作业进程是通用的执行节点，不会依赖作业业务；Classed 实现执行器/作业

SimpleJobExecutor/SimpleJob：简单作业实现，平台提供其他常用作业实现，如 script，http，dataflow，这是一对配套实现

## 1.2 作业注册和调度

### 1.2.1 作业注册分为一次/定时两种类型

一次/定时调度两者区分是有否 cron 配置，没有 cron 配置视为一次调度，使用 触发服务 触发作业执行，定时调度作业使用本地 quartz

![img](http://blog-1259650185.cosbj.myqcloud.com/img/202204/25/1650817394.png)

### 1.2.2 作业初始化

spring boot starter

![img](http://blog-1259650185.cosbj.myqcloud.com/img/202204/25/1650817478.png)

**ElasticJobLiteAutoConfiguration** 

spring boot 自动配置主入口，import 其他的自动配置

**ElasticJobBootstrapConfiguration**

从名字看出功能是初始化 JobBootstrap，从 ElasticJobProperties 获取 ElasticJob 实例，构建 JobBootstrap，注册到 SingletonBeanRegistry，spring bean 工厂可获取

**ScheduleJobBootstrapStartupRunner**

CommandLineRunner 实现，spring bean 工厂获取 ScheduleJobBootstrap 实例，调度作业到本地 quartz

### 1.3 作业注册和调度

![img](http://blog-1259650185.cosbj.myqcloud.com/img/202204/25/1650818207.png)

**JobScheduler**

elastic-job 的调度器，作业执行环境初始化，构建和初始化 quartz scheduler

**JobRegistry**

单例，相当于作业执行上下文，管有作业的状态，调度器，注册中心

**JobScheduleController**

quartz 调度器的封装

**ScheduleJobBootstrap/OneOff JobBootstrap**

使用 JobScheduler 调度作业

**看上去构建和初始化 quartz scheduler 交给 JobScheduleController 比较合适**

依赖核心服务：

- 设置服务(setup)  置入作业配置，初始化其他核心服务
- 调度服务 作业调度为本地 quartz 作业
