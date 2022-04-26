xxl-job是一个分布式任务调度平台，其核心设计目标是开发迅速、学习简单、轻量级、易扩展。现已开放源代码并接入多家公司线上产品线，开箱即用。

在同类框架中，quartz也是佼佼者。

两者相比，xxl-job的调度器服务是独立部署，quartz则是作为三方依赖包直接引入业务系统。类似分库分表框架中，MyCat与shardingJDBC的区别。

作为一个优秀的开源调度框架，xxl-job有许多值得学习的地方，尤其如时间轮算法的思想，负载均衡各种策略的实现等。

## 1. 架构设计

xxl-job主要包含两部分，一是调度器，调度器需要独立部署；二是执行器，执行器作为maven依赖继承到我们的业务系统中，使用业务系统的资源做任务执行。 
（未使用过的同学可以先看一下官方文档使用指南）
https://www.xuxueli.com/xxl-job/#5.3%20%E6%9E%B6%E6%9E%84%E8%AE%BE%E8%AE%A1
官方架构图如下：

<img src="http://blog-1259650185.cosbj.myqcloud.com/img/202204/19/1650297745.png" alt="输入图片说明" style="zoom: 50%;" />

## 2. 目录结构

<img src="http://blog-1259650185.cosbj.myqcloud.com/img/202204/19/1650297927.png" alt="image-20220419000527483" style="zoom:67%;" />

xxl-job目录下分了三个maven子项目：

| 子项目                   | 说明                                       |
| :----------------------- | :----------------------------------------- |
| xxl-job-admin            | 调度器服务，需要独立部署                   |
| xxj-job-core             | 执行器，同时含有一些调度器也需要的公共代码 |
| xxl-job-executor-samples | 执行器的示例代码，模拟一个业务系统         |

### 2.1 xxl-job-admin目录结构

<img src="http://blog-1259650185.cosbj.myqcloud.com/img/202204/19/1650298002.png" alt="image-20220419000642232" style="zoom:50%;" />



| 目录           | 说明                                     |
| :------------- | :--------------------------------------- |
| core.alarm     | 报警相关处理，默认实现了一个报警邮件发送 |
| core.conf      | 配置项                                   |
| core.cron      | 提供cron表达式的解析器                   |
| core.exception | 自定义异常类                             |
| core.model     | domain                                   |
| core.old       | 已被移除的一些历史实现                   |
| core.route     | 执行器的路由策略                         |
| core.scheduler | 调度器的核心启动流程                     |
| core.thread    | 调度器的各个守护线程                     |
| core.trigger   | 调度器分发任务到执行器的trigger          |
| dao            | 数据库操作                               |
| service        | service层                                |
| controller     | controller层及一些拦截器                 |

### 2.2 xxl-core目录结构

<img src="http://blog-1259650185.cosbj.myqcloud.com/img/202204/19/1650298099.png" alt="image-20220419000819647" style="zoom:50%;" />

| 目录         | 说明                                      |
| :----------- | :---------------------------------------- |
| biz.client   | 提供执行器与调度器互相调用的api相关的逻辑 |
| biz.enums    | 排队策略等枚举                            |
| biz.executor | 执行器启动主流程                          |
| biz.glue     | 胶水代码相关                              |
| biz.handler  | JobHandler相关                            |
| biz.log      | log配置                                   |
| biz.server   | 执行器命令接收服务                        |
| biz.thread   | 执行器端线程                              |

xxl-core 可以看到主要是作为核心组件， 在 admin 调度中心和客户端都存在该依赖。 且该服务包含了调度中心和客户端操作对应的api。 比如 com.xxl.job.core.biz.client.ExecutorBizClient 就是用于服务端调用客户端的时候走http 接口进行调用， 实现对应的相关方法。 com.xxl.job.core.biz.impl.ExecutorBizImpl 是用于客户端， 调用对应的handler 方法进行处理业务。(这也是一种设计思想。 客户端和服务端实现相同接口，类似于策略模式，服务端和客户端的机制分离。)

目录部分大致了解，接下来我们先从调度器启动流程入手，逐步讲解。



## 参考

[xxl-job源码阅读-架构设计及目录介绍](https://mp.weixin.qq.com/s?__biz=MzU0MzQ1NTM4MQ==&mid=2247483686&idx=1&sn=556d4eeb7c7c2d53232540aa3d10d6f8&chksm=fb0a60dccc7de9ca925edf6adfd443abb267ba4ac6f942d6c931695cd668dede90d2bf17d723&scene=21#wechat_redirect)

[xxl-job源码(一)服务端客户端简单理解 ](https://www.cnblogs.com/qlqwjy/p/15506173.html)
