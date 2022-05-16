## 1. 概述

本文主要分享 **Elastic-Job-Lite 作业监控服务**。内容对应[《官方文档 —— DUMP作业运行信息》](http://dangdangdotcom.github.io/elastic-job/elastic-job-lite/02-guide/dump/)。

> 使用Elastic-Job-Lite过程中可能会碰到一些分布式问题，导致作业运行不稳定。
> 由于无法在生产环境调试，通过dump命令可以把作业内部相关信息dump出来，方便开发者debug分析； 另外为了不泄露隐私，已将相关信息中的ip地址以ip1, ip2…的形式过滤，可以在互联网上公开传输环境信息，便于进一步完善Elastic-Job。

涉及到主要类的类图如下( [打开大图](https://static.iocoder.cn/images/Elastic-Job/2017_12_01/01.png) )：

![img](http://blog-1259650185.cosbj.myqcloud.com/img/202204/30/1651287756.png)

## 2. MonitorService

MonitorService，作业监控服务。

**初始化 MonitorService 方法实现如下**：

```java
// MonitorService.java
private final String jobName;

public void listen() {
   int port = configService.load(true).getMonitorPort();
   if (port < 0) {
       return;
   }
   try {
       log.info("Elastic job: Monitor service is running, the port is '{}'", port);
       openSocketForMonitor(port);
   } catch (final IOException ex) {
       log.error("Elastic job: Monitor service listen failure, error is: ", ex);
   }
}
    
private void openSocketForMonitor(final int port) throws IOException {
   serverSocket = new ServerSocket(port);
   new Thread() {
       
       @Override
       public void run() {
           while (!closed) {
               try {
                   process(serverSocket.accept());
               } catch (final IOException ex) {
                   log.error("Elastic job: Monitor service open socket for monitor failure, error is: ", ex);
               }
           }
       }
   }.start();
}
```

- 在作业配置的监控服务端口属性( `LiteJobConfiguration.monitorPort` )启动 **ServerSocket**。一个作业对应一个作业监控端口，所以配置时，请不要重复端口噢。

**处理 dump命令 方法如下**：

```java
// MonitorService.java
private void process(final Socket socket) throws IOException {
   try (
           BufferedReader reader = new BufferedReader(new InputStreamReader(socket.getInputStream()));
           BufferedWriter writer = new BufferedWriter(new OutputStreamWriter(socket.getOutputStream()));
           Socket autoCloseSocket = socket) {
       // 读取命令
       String cmdLine = reader.readLine();
       if (null != cmdLine && DUMP_COMMAND.equalsIgnoreCase(cmdLine)) { // DUMP
           List<String> result = new ArrayList<>();
           dumpDirectly("/" + jobName, result);
           outputMessage(writer, Joiner.on("\n").join(SensitiveInfoUtils.filterSensitiveIps(result)) + "\n");
       }
   }
}
```

- `#process()` 方法，目前只支持 `DUMP` 命令。如果你有自定义命令的需要，可以拓展该方法。

- 调用 `#dumpDirectly()` 方法，输出当前作业名对应的相关调试信息。

  ```java
private void dumpDirectly(final String path, final List<String> result) {
     for (String each : regCenter.getChildrenKeys(path)) {
         String zkPath = path + "/" + each;
         String zkValue = regCenter.get(zkPath);
         if (null == zkValue) {
             zkValue = "";
         }
         TreeCache treeCache = (TreeCache) regCenter.getRawCache("/" + jobName);
         ChildData treeCacheData = treeCache.getCurrentData(zkPath);
         String treeCachePath =  null == treeCacheData ? "" : treeCacheData.getPath();
         String treeCacheValue = null == treeCacheData ? "" : new String(treeCacheData.getData());
         // 判断 TreeCache缓存 和 注册中心 数据一致
         if (zkValue.equals(treeCacheValue) && zkPath.equals(treeCachePath)) {
             result.add(Joiner.on(" | ").join(zkPath, zkValue));
         } else {
             result.add(Joiner.on(" | ").join(zkPath, zkValue, treeCachePath, treeCacheValue));
         }
         // 递归
         dumpDirectly(zkPath, result);
     }
  }
  ```
  
  - 当作业本地 **TreeCache缓存** 和注册中心数据不一致时，DUMP 出 [zkPath, zkValue, treeCachePath, treeCacheValue]。当相同时，只需 DUMP 出 [zkPath, zkValue]，**方便看出本地和注册中心是否存在数据差异。**

- DUMP 信息例子如下：

  ```shell
  Yunai-MacdeMacBook-Pro-2:elastic-job yunai$ echo "dump" | nc 127.0.0.1 10024
  /javaSimpleJob/sharding | 
  /javaSimpleJob/sharding/2 | 
  /javaSimpleJob/sharding/2/instance | ip198@-@5100
  /javaSimpleJob/sharding/1 | 
  /javaSimpleJob/sharding/1/instance | ip198@-@5100
  /javaSimpleJob/sharding/0 | 
  /javaSimpleJob/sharding/0/instance | ip198@-@5100
  /javaSimpleJob/servers | 
  /javaSimpleJob/servers/ip2 | 
  /javaSimpleJob/servers/ip198 | 
  /javaSimpleJob/leader | 
  /javaSimpleJob/leader/sharding | 
  /javaSimpleJob/leader/failover | 
  /javaSimpleJob/leader/failover/latch | 
  /javaSimpleJob/leader/failover/items | 
  /javaSimpleJob/leader/election | 
  /javaSimpleJob/leader/election/latch | 
  /javaSimpleJob/leader/election/instance | ip198@-@5100
  /javaSimpleJob/instances | 
  /javaSimpleJob/instances/ip198@-@5100 | 
  /javaSimpleJob/config | {"jobName":"javaSimpleJob","jobClass":"com.dangdang.ddframe.job.example.job.simple.JavaSimpleJob","jobType":"SIMPLE","cron":"0 0/2 * * * ?","shardingTotalCount":3,"shardingItemParameters":"0\u003dBeijing,1\u003dShanghai,2\u003dGuangzhou","jobParameter":"","failover":true,"misfire":true,"description":"","jobProperties":{"job_exception_handler":"com.dangdang.ddframe.job.executor.handler.impl.DefaultJobExceptionHandler","executor_service_handler":"com.dangdang.ddframe.job.executor.handler.impl.DefaultExecutorServiceHandler"},"monitorExecution":false,"maxTimeDiffSeconds":-1,"monitorPort":10024,"jobShardingStrategyClass":"com.dangdang.ddframe.job.lite.api.strategy.impl.OdevitySortByNameJobShardingStrategy","reconcileIntervalMinutes":10,"disabled":false,"overwrite":true}
  ```
  
  

## 参考

[Elastic-Job-Lite 源码分析 —— 作业监控服务](https://www.iocoder.cn/Elastic-Job/job-monitor/)
