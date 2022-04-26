## 1. 表结构

先来看一下调度器需要init的表结构。

| table              | 说明                                                         |
| ------------------ | ------------------------------------------------------------ |
| xxl_job_lock       | 任务调度锁表                                                 |
| xxl_job_info       | 调度扩展信息表：用于保存XXL-JOB调度任务的扩展信息            |
| xxl_job_group      | 执行器信息表，维护任务执行器信息                             |
| xxl_job_log        | 用于保存XXL-JOB任务调度的历史信息，如调度结果                |
| xxl_job_log_report | 调度日志报表：用户存储XXL-JOB任务调度日志的报表              |
| xxl_job_logglue    | 任务GLUE日志：用于保存GLUE更新历史，用于支持GLUE的版本回溯功能 |
| xxl_job_registry   | 执行器注册表，维护在线的执行器和调度中心机器地址信息         |
| xxl_job_user       | 系统用户表                                                   |

from 官方文档（5.2 “调度数据库”配置）

## 2. 启动流程

1.xxl-job基于springboot，所以我们可以从XxlJobAdminConfig入手。

```java
// XxlJobAdminConfig.java
private XxlJobScheduler xxlJobScheduler;

@Override
public void afterPropertiesSet() throws Exception {
    adminConfig = this;

    xxlJobScheduler = new XxlJobScheduler();
    xxlJobScheduler.init();
}
```

可以看到这里，通过实现了InitializingBean.afterPropertiesSet，在spring初始化阶段，实例化了一个XxlJobScheduler，并调用init方法，打开init。

2.XxlJobScheduler.init()

```java
// XxlJobScheduler.java
public void init() throws Exception {
    // init i18n
    initI18n();

    // admin trigger pool start
    JobTriggerPoolHelper.toStart();

    // admin registry monitor run
    JobRegistryHelper.getInstance().start();

    // admin fail-monitor run
    JobFailMonitorHelper.getInstance().start();

    // admin lose-monitor run ( depend on JobTriggerPoolHelper )
    JobCompleteHelper.getInstance().start();

    // admin log report start
    JobLogReportHelper.getInstance().start();

    // start-schedule  ( depend on JobTriggerPoolHelper )
    JobScheduleHelper.getInstance().start();

    logger.info(">>>>>>>>> init xxl-job admin success.");
}
```

这里的代码易读性很好:

- 加载国际化配置
- 启动两个线程池，用于触发任务
- 启动管理注册执行器的线程

- 启动处理失败任务，触发报警的线程
- 启动处理“丢失”任务的线程
- 启动生成调度报表数据的线程
- 启动两个调度器线程，一个处理粗粒任务，另一个使用时间轮处理秒级粒度任务。

> 值得一提，这里启动的诸多背负功能线程都被设置成了守护线程。

## 3. 国际化

国际化，又称为i18n（因为这个单词从i到n有18个英文字母，因此命名）。

*xxl-job的国际化切换英文版展示*

<img src="http://blog-1259650185.cosbj.myqcloud.com/img/202204/19/1650335411.png" alt="image-20220419103011415" style="zoom:25%;" />

*xxl-job的国际化切换繁体中文版展示*

<img src="http://blog-1259650185.cosbj.myqcloud.com/img/202204/19/1650335452.png" alt="image-20220419103052249" style="zoom: 25%;" />

### 3.1 配置

#### 3.1.1 资源文件

resources下有一个i18n资源文件夹，下属三个properties文件分别对应英文字典，中文字典，繁体中文字典。

<img src="http://blog-1259650185.cosbj.myqcloud.com/img/202204/19/1650335307.png" alt="image-20220419102827838" style="zoom:67%;" />

#### 3.1.2 配置项

application.properties中，xxl,job.i18n配置项可配置文件，通过指定上述资源文件名中下划线后半部分 来指定要加载的语言字典。

```properties
### application.properties
### xxl-job, i18n (default is zh_CN, and you can choose "zh_CN", "zh_TC" and "en")
xxl.job.i18n=zh_CN
```

当前版本xxl官方提供了三种语言字典，我们也可以按照自己的需求配置更多的语言文件副本。
资源字典里面的key并不多，两百六十多行。

> 注:使用自定义语言字典还需要简单修改源码的XxlJobAdminConfig.getI18n()。

### 3.2 源码分析

从前文[启动流程]中可知，调度器启动时，第一项便是加载国际化资源。

XxlJobScheduler.initI18n()方法：

```java
// XxlJobScheduler.java
// ---------------------- I18n ----------------------

private void initI18n(){
    for (ExecutorBlockStrategyEnum item:ExecutorBlockStrategyEnum.values()) {
        item.setTitle(I18nUtil.getString("jobconf_block_".concat(item.name())));
    }
}
```

ExecutorBlockStrategyEnum
这里通过加载`阻塞处理策略`的枚举类时，进行了语言字典的加载。

```java
// ExecutorBlockStrategyEnum.java
public enum ExecutorBlockStrategyEnum {

    SERIAL_EXECUTION("Serial execution"),
    /*CONCURRENT_EXECUTION("并行"),*/
    DISCARD_LATER("Discard Later"),
    COVER_EARLY("Cover Early");
   // ... 省略其他方法和属性
}  
```

I18nUtil.getString()

```java
// I18nUtil.java
/**
 * get val of i18n key
 *
 * @param key
 * @return
 */
public static String getString(String key) {
    return loadI18nProp().getProperty(key);
}

public static Properties loadI18nProp(){
    if (prop != null) { // 资源文件的加载，此处，如果prop不为null则会直接加载语言字典。不需要关心线程冲突，Properties继承Hashtable
        return prop;
    }
    try {
        // build i18n prop 这里的i18n变量便是取自 xxl.job.i18n 配置，值得一提，getI18n()里面做了一个判断，必须属于"zh_CN", "zh_TC", "en"其中一种才可以使用，所以如果需要使用自定义语言字典，此方法也需要修改一下。
        String i18n = XxlJobAdminConfig.getAdminConfig().getI18n();
        String i18nFile = MessageFormat.format("i18n/message_{0}.properties", i18n);

        // load prop 使用i18n拼接文件地址，获取字典资源文件并加载到内存中
        Resource resource = new ClassPathResource(i18nFile);
        EncodedResource encodedResource = new EncodedResource(resource,"UTF-8");
        prop = PropertiesLoaderUtils.loadProperties(encodedResource);
    } catch (IOException e) {
        logger.error(e.getMessage(), e);
    }
    return prop;
}
```

### 3.3 使用

上述我们已经了解了语言字典的加载过程，那么我们知道此时的语言字典已经作为一个字典本身存在于内存中，那么此时就可以在任意一个位置加载字典中的key。

同理，我们需要增加额外的国际化关键字，也可以配置在这几个字典中。

## 4. 一次任务执行流程

1. com.xxl.job.admin.core.thread.JobTriggerPoolHelper#trigger 添加到任务队列。

2. com.xxl.job.admin.core.thread.JobTriggerPoolHelper#addTrigger 线程池中跑任务

3. com.xxl.job.admin.core.trigger.XxlJobTrigger#trigger 触发任务，继续调用 com.xxl.job.admin.core.trigger.XxlJobTrigger#processTrigger 获取到参数之后构造TriggerParam 发送http 请求调用(调用到com.xxl.job.core.biz.client.ExecutorBizClient#run 发送http 请求)， 同时构造 XxlJobLog 保存相关日志信息。 

4. 客戶端收到请求，会调用到 com.xxl.job.core.server.EmbedServer.EmbedHttpServerHandler#process 执行请求。 最后交给异步线程池 com.xxl.job.core.thread.JobThread。 最后会 com.xxl.job.core.thread.TriggerCallbackThread#pushCallBack 生成回调信息。 然后调用 com.xxl.job.core.biz.client.AdminBizClient#callback 向admin 调度中心发送 /callback 信息 (走http 发送信息到admin 调度信息)。

5. admin 调度中心收到 callback 回调后， 调用到： com.xxl.job.admin.controller.JobApiController#api ，然后调用到： com.xxl.job.admin.core.thread.JobCompleteHelper#callback(java.util.List<com.xxl.job.core.biz.model.HandleCallbackParam>) -》 com.xxl.job.admin.core.thread.JobCompleteHelper#callback(com.xxl.job.core.biz.model.HandleCallbackParam)

​		-》 com.xxl.job.admin.core.complete.XxlJobCompleter#finishJob 结束任务， 如果有子任务， 继续执行子任务



## 参考

[xxl-job源码阅读——（二）调度器表结构及启动流程](https://mp.weixin.qq.com/s?__biz=MzU0MzQ1NTM4MQ==&mid=2247483735&idx=1&sn=4871cdb81831fe1944d93d7bddbf1f8d&chksm=fb0a60adcc7de9bb03fb9da71679c241069141dec8ff8c9d673cb56d071c4d1fd3179b3de21a&scene=21#wechat_redirect)

[xxl-job源码(三)服务端源码 ](https://www.cnblogs.com/qlqwjy/p/15510945.html)
