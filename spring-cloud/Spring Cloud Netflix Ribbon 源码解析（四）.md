## 1. 前言

今天我们接着来探索 ribbon 是怎么做到服务发现的，看一看背后是怎么实现的，如果没有看过前几篇的同学，请先阅读前几篇。好了废话不多说，直接进入正题。今天我们从 `RibbonLoadBalancerClient `的 `execute` 方法入手。

## 2. 源码分析

### 2.1 RibbonLoadBalancerClient

```java
public <T> T execute(String serviceId, LoadBalancerRequest<T> request, Object hint)
 throws IOException {
 //获取负载均衡器
 ILoadBalancer loadBalancer = getLoadBalancer(serviceId);
 //根据负载均衡器选择一个server
 Server server = getServer(loadBalancer, hint);
 if (server == null) {
  throw new IllegalStateException("No instances available for " + serviceId);
 }
 RibbonServer ribbonServer = new RibbonServer(serviceId, server,
   isSecure(server, serviceId),
   serverIntrospector(serviceId).getMetadata(server));

 return execute(serviceId, ribbonServer, request);
}
```

相信看过前几篇的同学，对于上面的代码，肯定不会感到陌生。我们今天要讲的内容，就从 `getServer(loadBalancer, hint);`开始。 简单回顾下：`getServer `方法内部会委托给传入的负载均衡器（`ZoneAwareLoadBalancer`），通过它的 `chooseServer `方法，最终内部会调用父类（`BaseLoadBalancer`）的 `chooseServer `方法，然后通过调用默认的负载均衡算法（`RoundRobinRule`）的 `choose`方法，选择一个 server 并返回。那么，今天就重点研究下，这些 server 是怎么被发现的。先看一下 `RoundRobinRule.choose `方法：

### 2.2 RoundRobinRule

```java
public Server choose(ILoadBalancer lb, Object key) {
    if (lb == null) {
        log.warn("no load balancer");
        return null;
    }

    Server server = null;
    int count = 0;
    while (server == null && count++ < 10) {
     //获取可用的服务列表
        List<Server> reachableServers = lb.getReachableServers();
        //获取所有的服务列表
        List<Server> allServers = lb.getAllServers();
        int upCount = reachableServers.size();
        int serverCount = allServers.size();

        if ((upCount == 0) || (serverCount == 0)) {
            log.warn("No up servers available from load balancer: " + lb);
            return null;
        }

        int nextServerIndex = incrementAndGetModulo(serverCount);
        server = allServers.get(nextServerIndex);

        ......
    }
 ......
    return server;
}
```

通过调用负载均衡器的 `getReachableServers() `和 `getAllServers() `方法，分别获取可用的服务列表以及所有服务列表。这两个方法都是在 `BaseLoadBalancer` 中定义的：

### 2.3 BaseLoadBalancer

```java
@Override
public List<Server> getReachableServers() {
    return Collections.unmodifiableList(upServerList);
}

@Override
public List<Server> getAllServers() {
    return Collections.unmodifiableList(allServerList);
}
```

以上方法都是通过内部的成员变量创建的列表，代码如下：

```java
@Monitor(name = PREFIX + "AllServerList", type = DataSourceType.INFORMATIONAL)
protected volatile List<Server> allServerList = Collections
        .synchronizedList(new ArrayList<Server>());
@Monitor(name = PREFIX + "UpServerList", type = DataSourceType.INFORMATIONAL)
protected volatile List<Server> upServerList = Collections
        .synchronizedList(new ArrayList<Server>());
```

那么我们就看看 `allServerList `和 `upServerList`，这两个列表是在哪里初始化赋值的。如果在读源码的时候不清楚怎么查找的话，这里介绍一种查找方式：在 IDEA 中通过 Find Usages，找到它的写方法，如下图：

![img](https://pic3.zhimg.com/80/v2-ee57a1278542b47c50cdcdd930471552_1440w.jpg)

然后一层层的查找，最终一定会找到在哪里被调用到。这里就不带着大家一步步寻找了，直接说结论：在`RibbonClientConfiguration`配置类中通过构造函数创建 `ZoneAwareLoadBalancer` 实例对象时：

### 2.4 RibbonClientConfiguration

```java
@Bean
@ConditionalOnMissingBean
public ILoadBalancer ribbonLoadBalancer(IClientConfig config,
  ServerList<Server> serverList, ServerListFilter<Server> serverListFilter,
  IRule rule, IPing ping, ServerListUpdater serverListUpdater) {
 if (this.propertiesFactory.isSet(ILoadBalancer.class, name)) {
  return this.propertiesFactory.get(ILoadBalancer.class, config, name);
 }
 return new ZoneAwareLoadBalancer<>(config, rule, ping, serverList,
   serverListFilter, serverListUpdater);
}
```

### 2.5 ZoneAwareLoadBalancer

```java
public ZoneAwareLoadBalancer(IClientConfig clientConfig, IRule rule,
                            IPing ping, ServerList<T> serverList, ServerListFilter<T> filter,
                            ServerListUpdater serverListUpdater) {
   //调用父类DynamicServerListLoadBalancer的构造器
   super(clientConfig, rule, ping, serverList, filter, serverListUpdater);
}
```

会调用父类 DynamicServerListLoadBalancer 的构造器：

### 2.6 DynamicServerListLoadBalancer

```java
public DynamicServerListLoadBalancer(IClientConfig clientConfig, IRule rule, IPing ping,
                                     ServerList<T> serverList, ServerListFilter<T> filter,
                                     ServerListUpdater serverListUpdater) {
    //调用父类BaseLoadBalancer的构造器，暂且放下
    super(clientConfig, rule, ping);
    this.serverListImpl = serverList;
    this.filter = filter;
    this.serverListUpdater = serverListUpdater;
    if (filter instanceof AbstractServerListFilter) {
        ((AbstractServerListFilter) filter).setLoadBalancerStats(getLoadBalancerStats());
    }
    //关键方法
    restOfInit(clientConfig);
}
```

重点看下 `restOfInit `方法：

```java
void restOfInit(IClientConfig clientConfig) {
    boolean primeConnection = this.isEnablePrimingConnections();
    // turn this off to avoid duplicated asynchronous priming done in BaseLoadBalancer.setServerList()
    this.setEnablePrimingConnections(false);
    //1.开启定时器
    enableAndInitLearnNewServersFeature();

 		//2.更新服务列表
    updateListOfServers();
    if (primeConnection && this.getPrimeConnections() != null) {
        this.getPrimeConnections()
                .primeConnections(getReachableServers());
    }
    this.setEnablePrimingConnections(primeConnection);
    LOGGER.info("DynamicServerListLoadBalancer for client {} initialized: {}", clientConfig.getClientName(), this.toString());
}
```

1. 进入`enableAndInitLearnNewServersFeature`方法：

```java
public void enableAndInitLearnNewServersFeature() {
   LOGGER.info("Using serverListUpdater {}", serverListUpdater.getClass().getSimpleName());
   serverListUpdater.start(updateAction);
}

protected final ServerListUpdater.UpdateAction updateAction = new ServerListUpdater.UpdateAction() {
   @Override
   public void doUpdate() {
    	//更新服务列表
       updateListOfServers();
   }
};
```

`serverListUpdater` 是通过 `RibbonClientConfiguration` 配置类创建的，返回的是 `PollingServerListUpdater `实例，然后通过`ZoneAwareLoadBalancer `的构造函数一步步传入父类 `DynamicServerListLoadBalancer` 中。方法内部调用 `(PollingServerListUpdater)serverListUpdater `的`start `方法，方法的入参为 `updateAction `实例对象。

2. PollingServerListUpdater

```java
@Override
public synchronized void start(final UpdateAction updateAction) {
    if (isActive.compareAndSet(false, true)) {
        final Runnable wrapperRunnable = new Runnable() {
            @Override
            public void run() {
                if (!isActive.get()) {
                    if (scheduledFuture != null) {
                        scheduledFuture.cancel(true);
                    }
                    return;
                }
                try {
                 //最终也会调用updateListOfServers();方法
                    updateAction.doUpdate();
                    lastUpdated = System.currentTimeMillis();
                } catch (Exception e) {
                    logger.warn("Failed one update cycle", e);
                }
            }
        };

  			//启动一个定时器
        scheduledFuture = getRefreshExecutor().scheduleWithFixedDelay(
          			//任务
                wrapperRunnable,
                //初始延迟时间：默认1秒
                initialDelayMs,
                //周期执行时间间隔，默认30秒
                refreshIntervalMs,
                //时间单位
                TimeUnit.MILLISECONDS
        );
    } else {
        logger.info("Already active, no-op");
    }
}
```

启动一个定时任务，每隔`30`秒执行一次 `updateListOfServers()` 方法。

3. 进入`updateListOfServers`方法：

```java
@VisibleForTesting
public void updateListOfServers() {
    List<T> servers = new ArrayList<T>();
    if (serverListImpl != null) {
     //1.获取服务列表
        servers = serverListImpl.getUpdatedListOfServers();
        LOGGER.debug("List of Servers for {} obtained from Discovery client: {}",
                getIdentifier(), servers);

        if (filter != null) {
            servers = filter.getFilteredListOfServers(servers);
            LOGGER.debug("Filtered List of Servers for {} obtained from Discovery client: {}",
                    getIdentifier(), servers);
        }
    }
    //2.更新服务列表
    updateAllServerList(servers);
}
```

`serverListImpl`也是通过 `RibbonClientConfiguration `创建并注入到 spring 容器中的，默认在没有使用 `eureka` 等服务注册中心时，默认注册的是 `ConfigurationBasedServerList` 实例，即通过配置文件获取服务列表。对于 ribbon 从服务注册中的拉取服务列表的相关代码分析，放在以后再说，今天先说从配置文件中获取服务列表。

```java
@Bean
@ConditionalOnMissingBean
@SuppressWarnings("unchecked")
public ServerList<Server> ribbonServerList(IClientConfig config) {
 if (this.propertiesFactory.isSet(ServerList.class, name)) {
  return this.propertiesFactory.get(ServerList.class, config, name);
 }
 ConfigurationBasedServerList serverList = new ConfigurationBasedServerList();
 serverList.initWithNiwsConfig(config);
 return serverList;
}
```

3.1 进入 `ConfigurationBasedServerList `的 `getUpdatedListOfServers` 方法：

```java
@Override
public List<Server> getUpdatedListOfServers() {
       String listOfServers = clientConfig.get(CommonClientConfigKey.ListOfServers);
       return derive(listOfServers);
}

protected List<Server> derive(String value) {
    List<Server> list = Lists.newArrayList();
 if (!Strings.isNullOrEmpty(value)) {
  for (String s: value.split(",")) {
   list.add(new Server(s.trim()));
  }
 }
    return list;
}
```

最终从配置文件中获取服务列表，即通过 `*.ribbon.listOfServers`配置的静态服务列表。

3.2 然后将获取到的服务列表传入 `updateAllServerList` 方法，进行更新成员变量。 进入 `updateAllServerList` 方法：

```java
protected void updateAllServerList(List<T> ls) {
    // other threads might be doing this - in which case, we pass
    if (serverListUpdateInProgress.compareAndSet(false, true)) {
        try {
            for (T s : ls) {
             //设置服务状态为活跃状态
                s.setAlive(true); // set so that clients can start using these
                                  // servers right away instead
                                  // of having to wait out the ping cycle.
            }
            //更新服务列表
            setServersList(ls);
            super.forceQuickPing();
        } finally {
            serverListUpdateInProgress.set(false);
        }
    }
}
```

进入 `setServersList `方法：

```java
@Override
public void setServersList(List lsrv) {
 //调用父类BaseLoadBalancer的方法
    super.setServersList(lsrv);
    ......
}
```

进入 `BaseLoadBalancer `的 `setServersList` 方法：

```java
public void setServersList(List lsrv) {
  ......
        allServerList = allServers;
        ......
        upServerList = allServerList;
}
```

> **小知识点：**方法内部还会调用 `ServerListChangeListener `接口的 `serverListChanged(oldList, newList) `方法，因此如果我们想获取服务上下线的通知，可以实现 `ServerListChangeListener` 接口，剩下的就自己随心所欲的处理吧

最终在这个方法内部更新服务列表。好了，到这里，**我们已经知道 ribbon 每 30 秒会更新一次服务列表**。

现在看来从服务的解析到服务列表的找寻及缓存都解决了，看拟问题都解决了，但是还有一个问题，那就是服务的存活问题，因为在生产环境中有服务挂机的情况，所以这里面的设计应该还有一个定时去 ping 下服务是否运转正常，如果 ping 的结果发现服务有异常那一定会去改变我们的 ILoadBalancer 的服务列表，把它下线，还记得我们在 **DynamicServerListLoadBalancer** 的构造方法中会继续调用父类的构造方法吗？在父类 **BaseLoadBalancer** 的构造函数中，最终会调用 **setupPingTask()** 方法：

### 2.7 BaseLoadBalancer

```java
void setupPingTask() {
    if (canSkipPing()) {
        return;
    }
    if (lbTimer != null) {
        lbTimer.cancel();
    }
    lbTimer = new ShutdownEnabledTimer("NFLoadBalancer-PingTimer-" + name,
            true);
    lbTimer.schedule(new PingTask(), 0, pingIntervalSeconds * 1000);
    forceQuickPing();
}
```

方法内部会启动一个定时任务，**默认每隔 10 秒执行一次**。那么，我们看看`new PingTask()`，这个任务做了什么。

```java
class PingTask extends TimerTask {
    public void run() {
        try {
         //策略模式，通过传入的值决定是用哪个ping去完成
         new Pinger(pingStrategy).runPinger();
        } catch (Exception e) {
            logger.error("LoadBalancer [{}]: Error pinging", name, e);
        }
    }
}
```

进入内部类 Pinger(pingStrategy).runPinger() 方法:

```java
public void runPinger() throws Exception {
        if (!pingInProgress.compareAndSet(false, true)) {
            return; // Ping in progress - nothing to do
        }

        // we are "in" - we get to Ping

        Server[] allServers = null;
        boolean[] results = null;

        Lock allLock = null;
        Lock upLock = null;

        try {
            /*
             * The readLock should be free unless an addServer operation is
             * going on...
             */
            allLock = allServerLock.readLock();
            allLock.lock();
            allServers = allServerList.toArray(new Server[allServerList.size()]);
            allLock.unlock();

            int numCandidates = allServers.length;
            //唯一的实现SerialPingStrategy,重点是这一行代码
            results = pingerStrategy.pingServers(ping, allServers);

            final List<Server> newUpList = new ArrayList<Server>();
            final List<Server> changedServers = new ArrayList<Server>();

            for (int i = 0; i < numCandidates; i++) {
                boolean isAlive = results[i];
                Server svr = allServers[i];
                boolean oldIsAlive = svr.isAlive();

                svr.setAlive(isAlive);

                if (oldIsAlive != isAlive) {
                    changedServers.add(svr);
                    logger.debug("LoadBalancer [{}]:  Server [{}] status changed to {}",
                  name, svr.getId(), (isAlive ? "ALIVE" : "DEAD"));
                }

                if (isAlive) {
                    newUpList.add(svr);
                }
            }
            upLock = upServerLock.writeLock();
            upLock.lock();
            upServerList = newUpList;
            upLock.unlock();

            notifyServerStatusChangeListener(changedServers);
        } finally {
            pingInProgress.set(false);
        }
    }
}
```

进入`(SerialPingStrategy)pingerStrategy.pingServers(ping, allServers) `方法：

```java
@Override
public boolean[] pingServers(IPing ping, Server[] servers) {
    int numCandidates = servers.length;
    boolean[] results = new boolean[numCandidates];

    logger.debug("LoadBalancer:  PingTask executing [{}] servers configured", numCandidates);

    for (int i = 0; i < numCandidates; i++) {
        results[i] = false; /* Default answer is DEAD. */
        try {
            // NOTE: IFF we were doing a real ping
            // assuming we had a large set of servers (say 15)
            // the logic below will run them serially
            // hence taking 15 times the amount of time it takes
            // to ping each server
            // A better method would be to put this in an executor
            // pool
            // But, at the time of this writing, we dont REALLY
            // use a Real Ping (its mostly in memory eureka call)
            // hence we can afford to simplify this design and run
            // this
            // serially
            if (ping != null) {
             		//循环调用
                results[i] = ping.isAlive(servers[i]);
            }
        } catch (Exception e) {
            logger.error("Exception while pinging Server: '{}'", servers[i], e);
        }
    }
    return results;
}
```

在配置文件中没有配置的情况下，默认注入到 spring 应用上下文的是 **DummyPing**，这个实现什么也不会做（见：**RibbonClientConfiguration**）,这里我们进入 **PingUrl** 类来分析

进入 `PingUrl.isAlive(servers[i])` 方法：

```java
public boolean isAlive(Server server) {
    String urlStr = "";
    if (this.isSecure) {
        urlStr = "https://";
    } else {
        urlStr = "http://";
    }

    urlStr = urlStr + server.getId();
    urlStr = urlStr + this.getPingAppendString();
    boolean isAlive = false;
    HttpClient httpClient = new DefaultHttpClient();
    HttpUriRequest getRequest = new HttpGet(urlStr);
    String content = null;

    try {
        HttpResponse response = httpClient.execute(getRequest);
        content = EntityUtils.toString(response.getEntity());
        isAlive = response.getStatusLine().getStatusCode() == 200;
        if (this.getExpectedContent() != null) {
            LOGGER.debug("content:" + content);
            if (content == null) {
                isAlive = false;
            } else if (content.equals(this.getExpectedContent())) {
                isAlive = true;
            } else {
                isAlive = false;
            }
        }
    } catch (IOException var11) {
        var11.printStackTrace();
    } finally {
        getRequest.abort();
    }

    return isAlive;
}
```

发起的是 HTTP 请求，然后根据返回的状态码进行判断。最终贴一张从网上找的时序图：

![img](https://pic1.zhimg.com/80/v2-20ee0a3178c2acd88871b43639d587a4_1440w.jpg)

## 3. 总结

1. ribbon 客户端，默认情况下每隔 30 秒从注册中心拉取一次配置，然后更新本地缓存。
2. ribbon 客户端，默认情况下每隔 10 秒发送一次心跳请求，检查服务是否存活，然后更新本地缓存。



## 参考

[Spring Cloud Netflix Ribbon 源码解析（四）](https://zhuanlan.zhihu.com/p/497096942)
