# 1. Sentinel 实战-控制台篇

## 1.1 部署控制台

### 1.1.1 下载可执行 jar 包

### 1.1.2 启动控制台

## 1.2 接入控制台

### 1.2.1 引入 transport 依赖

### 1.2.2 配置应用启动参数

### 1.2.3 触发客户端连接控制台

### 1.2.4 埋点

## 1.3 连接控制台

## 1.4 验证效果

## 1.5 原理

我们知道 sentinel 的核心就是围绕着几件事：资源的定义，规则的配置，代码中埋点。

而且这些事在 sentinel-core 中都有能力实现，另外通过接入 transport 模块就可以对外暴露相应的 http 接口方便我们查看 sentinel 中的相关数据。

#### CommandCenter

sentinel-core 在第一次规则被触发的时候，会通过spi扫描的方式启动一个并且仅启动一个 CommandCenter，也就是我们引入的 sentinel-transport-simple-http 依赖中被引入的实现类：SimpleHttpCommandCenter。

这个 SimpleHttpCommandCenter 类中启动了两个线程池：主线程池和业务线程池。

主线程池启动了一个 ServerSocket 来监听默认的 8719 端口，如果端口被占用，会自动尝试获取下一个端口，尝试3次。

业务线程池主要是用来处理 ServerSocket 接收到的数据。

```java
// SimpleHttpCommandCenter.java
public class SimpleHttpCommandCenter implements CommandCenter {

    private static final int PORT_UNINITIALIZED = -1;

    private static final int DEFAULT_SERVER_SO_TIMEOUT = 3000;
    private static final int DEFAULT_PORT = 8719;

    @SuppressWarnings("rawtypes")
    private static final Map<String, CommandHandler> handlerMap = new ConcurrentHashMap<String, CommandHandler>();

    @SuppressWarnings("PMD.ThreadPoolCreationRule")
    private ExecutorService executor = Executors.newSingleThreadExecutor(
        new NamedThreadFactory("sentinel-command-center-executor", true));
    private ExecutorService bizExecutor;

    private ServerSocket socketReference;

    @Override
    @SuppressWarnings("rawtypes")
    public void beforeStart() throws Exception {
        // Register handlers
        Map<String, CommandHandler> handlers = CommandHandlerProvider.getInstance().namedHandlers();
        registerCommands(handlers);
    }

    @Override
    public void start() throws Exception {
        int nThreads = Runtime.getRuntime().availableProcessors();
        this.bizExecutor = new ThreadPoolExecutor(nThreads, nThreads, 0L, TimeUnit.MILLISECONDS,
            new ArrayBlockingQueue<Runnable>(10),
            new NamedThreadFactory("sentinel-command-center-service-executor", true),
            new RejectedExecutionHandler() {
                @Override
                public void rejectedExecution(Runnable r, ThreadPoolExecutor executor) {
                    CommandCenterLog.info("EventTask rejected");
                    throw new RejectedExecutionException();
                }
            });

        Runnable serverInitTask = new Runnable() {
            int port;

            {
                try {
                    port = Integer.parseInt(TransportConfig.getPort());
                } catch (Exception e) {
                    port = DEFAULT_PORT;
                }
            }

            @Override
            public void run() {
                boolean success = false;
                ServerSocket serverSocket = getServerSocketFromBasePort(port);

                if (serverSocket != null) {
                    CommandCenterLog.info("[CommandCenter] Begin listening at port " + serverSocket.getLocalPort());
                    socketReference = serverSocket;
                    executor.submit(new ServerThread(serverSocket));
                    success = true;
                    port = serverSocket.getLocalPort();
                } else {
                    CommandCenterLog.info("[CommandCenter] chooses port fail, http command center will not work");
                }

                if (!success) {
                    port = PORT_UNINITIALIZED;
                }

                TransportConfig.setRuntimePort(port);
                executor.shutdown();
            }

        };

        new Thread(serverInitTask).start();
    }

    /**
     * Get a server socket from an available port from a base port.<br>
     * Increasing on port number will occur when the port has already been used.
     *
     * @param basePort base port to start
     * @return new socket with available port
     */
    private static ServerSocket getServerSocketFromBasePort(int basePort) {
        int tryCount = 0;
        while (true) {
            try {
                ServerSocket server = new ServerSocket(basePort + tryCount / 3, 100);
                server.setReuseAddress(true);
                return server;
            } catch (IOException e) {
                tryCount++;
                try {
                    TimeUnit.MILLISECONDS.sleep(30);
                } catch (InterruptedException e1) {
                    break;
                }
            }
        }
        return null;
    }

    @Override
    public void stop() throws Exception {
        if (socketReference != null) {
            try {
                socketReference.close();
            } catch (IOException e) {
                CommandCenterLog.warn("Error when releasing the server socket", e);
            }
        }
        bizExecutor.shutdownNow();
        executor.shutdownNow();
        TransportConfig.setRuntimePort(PORT_UNINITIALIZED);
        handlerMap.clear();
    }

    /**
     * Get the name set of all registered commands.
     */
    public static Set<String> getCommands() {
        return handlerMap.keySet();
    }

    class ServerThread extends Thread {

        private ServerSocket serverSocket;

        ServerThread(ServerSocket s) {
            this.serverSocket = s;
            setName("sentinel-courier-server-accept-thread");
        }

        @Override
        public void run() {
            while (true) {
                Socket socket = null;
                try {
                    socket = this.serverSocket.accept();
                    setSocketSoTimeout(socket);
                    HttpEventTask eventTask = new HttpEventTask(socket);
                    bizExecutor.submit(eventTask);
                } catch (Exception e) {
                    CommandCenterLog.info("Server error", e);
                    if (socket != null) {
                        try {
                            socket.close();
                        } catch (Exception e1) {
                            CommandCenterLog.info("Error when closing an opened socket", e1);
                        }
                    }
                    try {
                        // In case of infinite log.
                        Thread.sleep(10);
                    } catch (InterruptedException e1) {
                        // Indicates the task should stop.
                        break;
                    }
                }
            }
        }
    }

    @SuppressWarnings("rawtypes")
    public static CommandHandler getHandler(String commandName) {
        return handlerMap.get(commandName);
    }

    @SuppressWarnings("rawtypes")
    public static void registerCommands(Map<String, CommandHandler> handlerMap) {
        if (handlerMap != null) {
            for (Entry<String, CommandHandler> e : handlerMap.entrySet()) {
                registerCommand(e.getKey(), e.getValue());
            }
        }
    }

    @SuppressWarnings("rawtypes")
    public static void registerCommand(String commandName, CommandHandler handler) {
        if (StringUtil.isEmpty(commandName)) {
            return;
        }

        if (handlerMap.containsKey(commandName)) {
            CommandCenterLog.warn("Register failed (duplicate command): " + commandName);
            return;
        }

        handlerMap.put(commandName, handler);
    }

    private void setSocketSoTimeout(Socket socket) throws SocketException {
        if (socket != null) {
            socket.setSoTimeout(DEFAULT_SERVER_SO_TIMEOUT);
        }
    }
}
```

具体的情况如下图所示：

<img src="https://mmbiz.qpic.cn/mmbiz_png/GtXvavW2UlyKQ1uK8Oy4xZnqVAwsckHrZqpyNhjIW8nC5NPnQNEiaurSnGej70FajcaZUYawEjibhFicCg0Tibw7Sg/640?wx_fmt=png&tp=webp&wxfrom=5&wx_lazy=1&wx_co=1" alt="图片" style="zoom:50%;" />

#### HTTP接口

SimpleHttpCommandCenter 启动了一个 ServerSocket 来监听8719端口，也对外提供了一些 http 接口用以操作 sentinel-core 中的数据，包括查询/更改规则，查询节点状态等。

**PS：控制台也是通过这些接口与 sentinel-core 进行数据交互的！**

提供这些服务的是一些 CommandHandler 的实现类，每个类提供了一种能力，这些类是在 sentinel-transport-common 依赖中提供的，如下图所示：

<img src="http://blog-1259650185.cosbj.myqcloud.com/img/202111/29/1638118871.png" alt="image-20211129010111439" style="zoom: 33%;" />

### 1.6 查询规则

在控制台程序运行下面命令，则会返回现有生效的规则：

```shell
curl http://localhost:8719/getRules?type=<XXXX
```

其中，type有以下取值：

- `flow` 以 JSON 格式返回现有的限流规则；
- `degrade` 则返回现有生效的降级规则列表；
- `system` 则返回系统保护规则。

### 1.7 更改规则

同时也可以通过下面命令来修改已有规则：

```shell
curl http://localhost:8719/setRules?type=<XXXX>&data=<DATA>
```

其中，type 可以输入 `flow`、 `degrade` 等方式来制定更改的规则种类， `data` 则是对应的 JSON 格式的规则。

其他的接口不再一一详细举例了，有需要的大家可以自行查看源码了解。





# 2. Sentinel 实战-规则持久化

## 2.1 规则持久化的5种方式

### 2.1.1 规则丢失

无论是通过硬编码的方式来更新规则，还是通过接入 Sentinel Dashboard 后，在页面上操作来更新规则，都无法避免一个问题，那就是服务重新后，规则就丢失了，因为默认情况下规则是保存在内存中的。

Dashboard 是通过 transport 模块来获取每个 Sentinel 客户端中的规则的，获取到的规则通过 RuleRepository 接口保存在 Dashboard 的内存中，如果在 Dashboard 页面中更改了某个规则，也会调用 transport 模块提供的接口将规则更新到客户端中去。

试想这样一种情况，客户端连接上 Dashboard 之后，我们在 Dashboard 上为客户端配置好了规则，并推送给了客户端。这时由于一些因素客户端出现异常，服务不可用了，当客户端恢复正常再次连接上 Dashboard 后，这时所有的规则都丢失了，我们还需要重新配置一遍规则，这肯定不是我们想要的。

<img src="http://blog-1259650185.cosbj.myqcloud.com/img/202111/29/1638150351" alt="图片" style="zoom:67%;" />

如上图所示，当 Sentinel 的客户端挂掉之后，保存在各个 RuleManager 中的规则都会付之一炬，所以在生产中是绝对不能这么做的。

### 2.1.2 规则持久化原理

那我们有什么办法能解决这个问题呢，其实很简单，那就是把原本保存在 RuleManager 内存中的规则，持久化一份副本出去。这样下次客户端重启后，可以从持久化的副本中把数据 load 进内存中，这样就不会丢失规则了，如下图所示：

<img src="http://blog-1259650185.cosbj.myqcloud.com/img/202111/29/1638150433" alt="图片" style="zoom: 67%;" />

Sentinel 为我们提供了两个接口来实现规则的持久化，他们分别是：ReadableDataSource 和 WritableDataSource。

其中 WritableDataSource 不是我们本次关心的重点，或者说 WritableDataSource 并没有那么重要，因为通常各种持久化的数据源已经提供了具体的将数据持久化的方法了，我们只需要把数据从持久化的数据源中获取出来，转成我们需要的格式就可以了。

下面我们来看一下 ReadableDataSource 接口的具体的定义：

```java
// ReadableDataSource.java
public interface ReadableDataSource<S, T> {
		// 将原始数据转换成我们所需的格式
    T loadConfig() throws Exception;
		// 从数据源中读取原始的数据
    S readSource() throws Exception;
		// 获取该种数据源的SentinelProperty对象
    SentinelProperty<T> getProperty();

    void close() throws Exception;
}
```

接口很简单，最重要的就是这三个方法，另外 Sentinel 还为我们提供了一个抽象类：AbstractDataSource，该抽象类中实现了两个方法，具体的数据源实现类只需要实现一个 readSource 方法即可，具体的代码如下：

```java
public abstract class AbstractDataSource<S, T> implements ReadableDataSource<S, T> {
    // Converter接口负责转换数据
    protected final Converter<S, T> parser;
    protected final SentinelProperty<T> property; // SentinelProperty接口负责触发PropertyListener的configUpdate方法的回调

    public AbstractDataSource(Converter<S, T> parser) {
        if (parser == null) {
            throw new IllegalArgumentException("parser can't be null");
        }
        this.parser = parser;
        this.property = new DynamicSentinelProperty<T>();
    }

    @Override
    public T loadConfig() throws Exception {
        return loadConfig(readSource());
    }

    public T loadConfig(S conf) throws Exception {
        T value = parser.convert(conf);
        return value;
    }

    @Override
    public SentinelProperty<T> getProperty() {
        return property;
    }
}
```

实际上每个具体的 DataSource 实现类需要做三件事：

- 实现 readSource 方法将数据源中的原始数据转换成我们可以处理的数据S
- 提供一个 Converter 来将数据S转换成最终的数据T
- 将最终的数据T更新到具体的 RuleManager 中去

我把规则是如何从数据源加载进 RuleManager 中去的完整流程浓缩成了下面这张图：

<img src="https://mmbiz.qpic.cn/mmbiz_png/GtXvavW2UlyiaVOdMqQZ1QOG3ZGW6ts8Qibu8Ts0TWicTKH4DAwjG4dDFUC4FgfbUIJEEB9ichTIUl8slBB94LBHtQ/640?wx_fmt=png&tp=webp&wxfrom=5&wx_lazy=1&wx_co=1" alt="图片" style="zoom:50%;" />

大家可以就着这张图对照着源码来看，可以很容易的弄明白这个过程，这里我就不再展开具体的源码讲了，有几点需要注意的是：

- 规则的持久化配置中心可以是redis、nacos、zk、file等等任何可以持久化的数据源，只要能保证更新规则时，客户端能得到通知即可
- 规则的更新可以通过 Sentinel Dashboard 也可以通过各个配置中心自己的更新接口来操作
- AbstractDataSource 中的 SentinelProperty 持有了一个 PropertyListener 接口，最终更新 RuleManager 中的规则是 PropertyListener 去做的

## 2.2 规则持久化

好了，知道了具体的原理了，下面我们就来讲解下如何来接入规则的持久化。

目前 Sentinel 中默认实现了5种规则持久化的方式，分别是：file、redis、nacos、zk和apollo。

下面我们对这5种方式一一进行了解，以持久化限流的规则为例。

### 2.2.1 File

文件持久化有一个问题就是文件不像其他的配置中心，数据发生变更后会发出通知，使用文件来持久化的话就需要我们自己定时去扫描文件，来确定文件是否发现了变更。

文件数据源是通过 FileRefreshableDataSource 类来实现的，他是通过文件的最后更新时间来判断规则是否发生变更的。

首先需要引入依赖：

```xml
<dependency>
  <groupId>com.alibaba.csp</groupId>
  <artifactId>sentinel-datasource-extension</artifactId>
  <version>x.y.z</version>
</dependency>
```

接入的方法如下：

```java
// FileDataSourceInit.java
@Override
public void init() throws Exception {
    String flowRuleDir = System.getProperty("user.home") + File.separator + "sentinel" + File.separator + "rules";
    String flowRuleFile = "flowRule.json";
    String flowRulePath = flowRuleDir + File.separator + flowRuleFile; // 保存了限流规则的文件的地址
    // 创建文件规则数据源
    ReadableDataSource<String, List<FlowRule>> ds = new FileRefreshableDataSource<>(
        flowRulePath, source -> JSON.parseObject(source, new TypeReference<List<FlowRule>>() {})
    );
    // Register to flow rule manager. 将Property注册到 RuleManager 中去
    FlowRuleManager.register2Property(ds.getProperty());
		...
}
```

**PS：需要注意的是，我们需要在系统启动的时候调用该数据源注册的方法，否则不会生效的。具体的方式有很多，可以借助 Spring 来初始化该方法，也可以自定义一个类来实现 Sentinel 中的 InitFunc 接口来完成初始化。**

Sentinel 会在系统启动的时候通过 spi 来扫描 InitFunc 的实现类，并执行 InitFunc 的 init 方法，所以这也是一种可行的方法，如果我们的系统没有使用 Spring 的话，可以尝试这种方式。

### 2.2.2 Redis

Redis 数据源的实现类是 RedisDataSource。

首先引入依赖：

```xml
<dependency>
  <groupId>com.alibaba.csp</groupId>
  <artifactId>sentinel-datasource-redis</artifactId>
  <version>x.y.z</version>
</dependency>
```

接入方法如下：

```java
// StandaloneRedisDataSourceTest.java
@Before
public void buildResource() {
    try {
        // Bind to a random port.
        server = RedisServer.newRedisServer();
        server.start();
    } catch (IOException e) {
        e.printStackTrace();
    }
    Converter<String, List<FlowRule>> flowConfigParser = buildFlowConfigParser();
    client = RedisClient.create(RedisURI.create(server.getHost(), server.getBindPort()));
    RedisConnectionConfig config = RedisConnectionConfig.builder()
        .withHost(server.getHost())
        .withPort(server.getBindPort())
        .build();
    initRedisRuleData();
    ReadableDataSource<String, List<FlowRule>> redisDataSource = new RedisDataSource<List<FlowRule>>(config,
        ruleKey, channel, flowConfigParser);
    FlowRuleManager.register2Property(redisDataSource.getProperty());
}

private Converter<String, List<FlowRule>> buildFlowConfigParser() {
    return source -> JSON.parseObject(source, new TypeReference<List<FlowRule>>() {});
}
```

### 2.2.3 Nacos

Nacos 数据源的实现类是 NacosDataSource。

```xml
<dependency>
  <groupId>com.alibaba.csp</groupId>
  <artifactId>sentinel-datasource-nacos</artifactId>
  <version>x.y.z</version>
</dependency>
```

接入方法如下：

```java
// NacosDataSourceDemo.java

private static final String remoteAddress = "localhost:8848";
private static final String groupId = "Sentinel_Demo";
private static final String dataId = "com.alibaba.csp.sentinel.demo.flow.rule";

private static void loadRules() {
    ReadableDataSource<String, List<FlowRule>> flowRuleDataSource = new NacosDataSource<>(remoteAddress, groupId, dataId,
            source -> JSON.parseObject(source, new TypeReference<List<FlowRule>>() {
            }));
    FlowRuleManager.register2Property(flowRuleDataSource.getProperty());
}
```

### 2.2.4 Zookeeper

Zookeeper数据源的实现类是 ZookeeperDataSource。

首先引入依赖：

```xml
<dependency>
  <groupId>com.alibaba.csp</groupId>
  <artifactId>sentinel-datasource-zookeeper</artifactId>
  <version>x.y.z</version>
</dependency>
```

接入方法如下：

```java
// ZookeeperDataSourceDemo.java
private static void loadRules() {

    final String remoteAddress = "127.0.0.1:2181";
    final String path = "/Sentinel-Demo/SYSTEM-CODE-DEMO-FLOW";

    ReadableDataSource<String, List<FlowRule>> flowRuleDataSource = new ZookeeperDataSource<>(remoteAddress, path,
            source -> JSON.parseObject(source, new TypeReference<List<FlowRule>>() {}));
    FlowRuleManager.register2Property(flowRuleDataSource.getProperty());

}
```

### 2.2.5 Apollo

Apollo 数据源的实现类是 ApolloDataSource。

首先引入依赖：

```xml
<dependency>
  <groupId>com.alibaba.csp</groupId>
  <artifactId>sentinel-datasource-Apollo</artifactId>
  <version>x.y.z</version>
</dependency>
```

接入方法如下：

```java
// ApolloDataSourceDemo.java
private static void loadRules() {

    String appId = "sentinel-demo";
    String apolloMetaServerAddress = "http://localhost:8080";
    System.setProperty("app.id", appId);
    System.setProperty("apollo.meta", apolloMetaServerAddress);

    String namespaceName = "application";
    String flowRuleKey = "flowRules";
    // It's better to provide a meaningful default value.
    String defaultFlowRules = "[]";

    ReadableDataSource<String, List<FlowRule>> flowRuleDataSource = new ApolloDataSource<>(namespaceName,
        flowRuleKey, defaultFlowRules, source -> JSON.parseObject(source, new TypeReference<List<FlowRule>>() {
    }));
    FlowRuleManager.register2Property(flowRuleDataSource.getProperty());
}
```



# 3. Sentinel 实战-集群限流

## 3.1 集群限流

我们已经知道如何为应用接入限流了，但是到目前为止，这些还只是在单机应用中生效。也就是说，假如你的应用有多个实例，那么你设置了限流的规则之后，每一台应用的实例都会生效相同的流控规则，如下图所示：

<img src="https://mmbiz.qpic.cn/mmbiz_png/GtXvavW2Ulx4DpOK8SpxiaBoNvyXujtTmRuFiayG51LU3IyJzRjpzGTEx2ZwB1txqSVNKaGgxPRnUicLfXnQYI6VQ/640?wx_fmt=png&tp=webp&wxfrom=5&wx_lazy=1&wx_co=1" alt="图片" style="zoom:50%;" />

假设我们设置了一个流控规则，qps是10，那么就会出现如上图所示的情况，当qps大于10时，实例中的 sentinel 就开始生效了，就会将超过阈值的请求 block 掉。

上图好像没什么问题，但是细想一下，我们可以发现还是会有这样的问题：

- 假设集群中有 10 台机器，我们给每台机器设置单机限流阈值为 10 qps，理想情况下整个集群的限流阈值就为 100 qps。不过实际情况下路由到每台机器的流量可能会不均匀，会导致总量没有到的情况下某些机器就开始限流。
- 每台单机实例只关心自己的阈值，对于整个系统的全局阈值大家都漠不关心，当我们希望为某个 api 设置一个总的 qps 时(就跟为 api 设置总的调用次数一样)，那这种单机模式的限流就无法满足条件了。

基于种种这些问题，我们需要创建一种集群限流的模式，这时候我们很自然地就想到，可以找一个 server 来专门统计总的调用量，其它的实例都与这台 server 通信来判断是否可以调用。这就是最基础的集群流控的方式。

## 3.2 原理

集群限流的原理很简单，和单机限流一样，都需要对 qps 等数据进行统计，区别就在于单机版是在每个实例中进行统计，而集群版是有一个专门的实例进行统计。

这个专门的用来统计数据的称为 Sentinel 的 token server，其他的实例作为 Sentinel 的 token client 会向 token server 去请求 token，如果能获取到 token，则说明当前的 qps 还未达到总的阈值，否则就说明已经达到集群的总阈值，当前实例需要被 block，如下图所示：

<img src="http://blog-1259650185.cosbj.myqcloud.com/img/202111/29/1638154944" alt="图片" style="zoom:50%;" />

集群流控是在 Sentinel 1.4 的版本中提供的新功能，和单机流控相比，集群流控中共有两种身份：

- token client：集群流控客户端，用于向所属 token server 通信请求 token。集群限流服务端会返回给客户端结果，决定是否限流。
- token server：即集群流控服务端，处理来自 token client 的请求，根据配置的集群规则判断是否应该发放 token（是否允许通过）。

而单机流控中只有一种身份，每个 sentinel 都是一个 token server。

需要注意的是，集群限流中的 token server 是单点的，一旦 token server 挂掉，那么集群限流就会退化成单机限流的模式。在 ClusterFlowConfig 中有一个参数 fallbackToLocalWhenFail 就是用来确定当 client 连接失败或通信失败时，是否退化到本地的限流模式的。

Sentinel 集群流控支持限流规则和热点规则两种规则，并支持两种形式的阈值计算方式：

- **集群总体模式**：即限制整个集群内的某个资源的总体 qps 不超过此阈值。
- **单机均摊模式**：单机均摊模式下配置的阈值等同于单机能够承受的限额，token server 会根据连接数来计算总的阈值（比如独立模式下有 3 个 client 连接到了 token server，然后配的单机均摊阈值为 10，则计算出的集群总量就为 30），按照计算出的总的阈值来进行限制。这种方式根据当前的连接数实时计算总的阈值，对于机器经常进行变更的环境非常适合。

## 3.3 部署方式

token server 有两种部署方式：

- 一种是独立部署，就是单独启动一个 token server 服务来处理 token client 的请求，如下图所示：

  <img src="https://mmbiz.qpic.cn/mmbiz_png/GtXvavW2Ulx4DpOK8SpxiaBoNvyXujtTmF2WK5ia4P7WHibauiadLgHX7zK6Beib4d0B1DEicWb5xUu9v5TgTntos5tg/640?wx_fmt=png&tp=webp&wxfrom=5&wx_lazy=1&wx_co=1" alt="图片" style="zoom:50%;" />

​	如果独立部署的 token server 服务挂掉的话，那其他的 token client 就会退化成本地流控的模式，也就是单机版的流控，所以这种方式的集群限流需要保证 token server 的高可用性。

- 一种是嵌入部署，就是在多个 sentinel-core 中选择一个实例设置为 token server，随着应用一起启动，其他的 sentinel-core 都是集群中 token client，如下图所示：

  <img src="https://mmbiz.qpic.cn/mmbiz_png/GtXvavW2Ulx4DpOK8SpxiaBoNvyXujtTmgldszPsnGw5fiaIGl8nJ4uDSWnPWrEvkmPia4YbexbBibNw2MyKiauZkYQ/640?wx_fmt=png&tp=webp&wxfrom=5&wx_lazy=1&wx_co=1" alt="图片" style="zoom:50%;" />

  嵌入式部署的模式中，如果 token server 服务挂掉的话，我们可以将另外一个 token client 升级为token server来，当然啦如果我们不想使用当前的 token server 的话，也可以选择另外一个 token client 来承担这个责任，并且将当前 token server 切换为 token client。Sentinel 为我们提供了一个 api 来进行 token server 与 token client 的切换：

  ```
  http://<ip>:<port>/setClusterMode?mode=<xxx>
  ```

​		其中 mode 为 `0` 代表 client， `1` 代表 server， `-1` 代表关闭。

​		**PS：注意应用端需要引入集群限流客户端或服务端的相应依赖。**	

## 3.4 如何使用

下面我们来看一下如何快速使用集群流控功能。接入集群流控模块的步骤如下：

### 3.4.1 引入依赖

这里我们以嵌入模式来运行 token server，即在应用集群中指定某台机器作为 token server，其它的机器指定为 token client。

首先我们引入集群流控相关依赖：

```xml
<dependency>
    <groupId>com.alibaba.csp</groupId>
    <artifactId>sentinel-cluster-client-default</artifactId>
    <version>1.8.2</version>
</dependency>
<dependency>
    <groupId>com.alibaba.csp</groupId>
    <artifactId>sentinel-cluster-server-default</artifactId>
    <version>1.8.2</version>
</dependency>
```

### 3.4.2 监听规则源

要想使用集群流控功能，我们需要在应用端配置动态规则源，并通过 Sentinel 控制台实时进行推送。如下图所示：

<img src="https://mmbiz.qpic.cn/mmbiz_png/GtXvavW2Ulx4DpOK8SpxiaBoNvyXujtTm5GU96LAKcqRbFQdOI4uYGCic4fJZW4T6LVm4MC562m38TibxiaPjuE0Qw/640?wx_fmt=png&tp=webp&wxfrom=5&wx_lazy=1&wx_co=1" alt="图片" style="zoom:50%;" />

以流控规则为例，假设我们使用 ZooKeeper 作为配置中心，则可以向客户端 FlowRuleManager 注册 ZooKeeper 动态规则源：

```java
ReadableDataSource<String, List<FlowRule>> flowRuleDataSource = new ZookeeperDataSource<>(remoteAddress, path,
        source -> JSON.parseObject(source, new TypeReference<List<FlowRule>>() {}));
FlowRuleManager.register2Property(flowRuleDataSource.getProperty());
```

另外，我们还需要针对 token server 注册集群规则数据源。

由于嵌入模式下 token server 和 client 可以随时变换，因此我们只需在每个实例都向集群流控规则管理器ClusterFlowRuleManager 注册动态规则源即可。

token server 抽象出了命名空间（namespace）的概念，可以支持多个应用/服务，因此我们需要注册一个自动根据 namespace 创建动态规则源的生成器，即Supplier，如下所示:

```java
ClusterFlowRuleManager.setPropertySupplier(namespace -> {
    ReadableDataSource<String, List<FlowRule>> ds = new NacosDataSource<>(remoteAddress, groupId,
        namespace + DemoConstants.FLOW_POSTFIX, source -> JSON.parseObject(source, new TypeReference<List<FlowRule>>() {}));
    return ds.getProperty();
});
```

Supplier 会根据 namespace 生成动态规则源，类型为`SentinelProperty<List<FlowRule>>`，针对不同的 namespace 生成不同的规则源（监听不同 namespace 的 path）。默认 namespace 为应用名（project.name）

### 3.4.3 改造控制台推送动态规则

我们需要对 Sentinel 控制台进行简单的改造来将流控规则推送至配置中心。

从 Sentinel 1.4.0 开始，Sentinel 控制台提供了 DynamicRulePublisher 和 DynamicRuleProvider 接口用于实现应用维度的规则推送和拉取，并提供了 Nacos 推送的示例（位于 test 目录下）。

我们只需要实现自己的 DynamicRulePublisher 和 DynamicRuleProvider接口并在 FlowControllerV2类中相应位置通过 @Qualifier注解指定对应的 bean name 即可，类似于：

```java
@Autowired
@Qualifier("flowRuleNacosProvider")
private DynamicRuleProvider<List<FlowRuleEntity>> ruleProvider;

@Autowired
@Qualifier("flowRuleNacosPublisher")
private DynamicRulePublisher<List<FlowRuleEntity>> rulePublisher;
```

Sentinel 控制台提供应用维度推送的页面（/v2/flow）。

在上述配置完成后，我们可以在此页面向配置中心推送规则：

<img src="https://mmbiz.qpic.cn/mmbiz_png/GtXvavW2Ulx4DpOK8SpxiaBoNvyXujtTm46U69KXgy8v3HcE3nzOtibZSGshvvcShfvd2Wzibib1ECDQESKUHsUSgA/640?wx_fmt=png&tp=webp&wxfrom=5&wx_lazy=1&wx_co=1" alt="图片" style="zoom:50%;" />



### 3.4.4 在控制台中设置 token server

当上面的步骤都完成后，我们就可以在 Sentinel 控制台的“集群限流”页面中的 token server 列表页面管理分配 token server 了。假设我们启动了三个应用实例，我们选择一个实例为 token server，其它两个为 token client：

<img src="https://mmbiz.qpic.cn/mmbiz_png/GtXvavW2Ulx4DpOK8SpxiaBoNvyXujtTmGHV9DickBErov1AgBicG1mQjSESlRmscqSgRq2gPUZHRfcNztCGvnAxA/640?wx_fmt=png&tp=webp&wxfrom=5&wx_lazy=1&wx_co=1" alt="图片" style="zoom:50%;" />



页面上机器的显示方式为 ip@commandPort，其中 `commandPort` 为应用端暴露给 Sentinel 控制台的端口。选择好以后，点击【保存】按钮，刷新页面即可以看到 token server 分配成功：

<img src="https://mmbiz.qpic.cn/mmbiz_png/GtXvavW2Ulx4DpOK8SpxiaBoNvyXujtTmRSO5Zc0FMP38nYEK5wiaBckXN5xqz2QQ1icibkTVk87JYXZboXIZ3ibvIA/640?wx_fmt=png&tp=webp&wxfrom=5&wx_lazy=1&wx_co=1" alt="图片" style="zoom:50%;" />

并且我们可以在页面上查看 token server 的连接情况：

<img src="https://mmbiz.qpic.cn/mmbiz_png/GtXvavW2Ulx4DpOK8SpxiaBoNvyXujtTmswjjyu0QibUF4jnknUzVQELLIlyqWj1OZw5V6cIuafuyVvPAicLJbhqQ/640?wx_fmt=png&tp=webp&wxfrom=5&wx_lazy=1&wx_co=1" alt="图片" style="zoom:50%;" />

### 3.4.5 配置并推送规则

接下来我们配置一条集群限流规则，限制

`com.alibaba.csp.sentinel.demo.cluster.app.service.DemoService:sayHello(java.lang.String)`

资源的集群总 qps 为 10，选中“是否集群”选项，阈值模式选择总体阈值：

<img src="https://mmbiz.qpic.cn/mmbiz_png/GtXvavW2Ulx4DpOK8SpxiaBoNvyXujtTmNaUX8V7NLia3FjcXIzxiaMOYKltrFx7NSKTS3HRQPF2gI5oYl23QCA4Q/640?wx_fmt=png&tp=webp&wxfrom=5&wx_lazy=1&wx_co=1" alt="图片" style="zoom:50%;" />



### 3.4.6 查看效果

模拟流量同时请求这三台机器，过一段时间后观察效果。

可以在监控页面看到对应资源的集群维度的总 qps 稳定在 10，如下图所示：

<img src="https://mmbiz.qpic.cn/mmbiz_png/GtXvavW2Ulx4DpOK8SpxiaBoNvyXujtTmlbunSYficNpsuuaxcfHvZPfJiaCexCwXP1LVA2a2Zib2icNjNHV70NVhIA/640?wx_fmt=png&tp=webp&wxfrom=5&wx_lazy=1&wx_co=1" alt="图片" style="zoom:50%;" />

## 3.5 注意事项

集群流控能够精确地控制整个集群的 qps，结合单机限流兜底，可以更好地发挥流量控制的效果。

还有更多的场景等待大家发掘，比如：

- 在 API Gateway 处统计某个 api 的总访问量，并对某个 api 或服务的总 qps 进行限制
- Service Mesh 中对服务间的调用进行全局流控
- 集群内对热点商品的总访问频次进行限制

尽管集群流控比较好用，但它不是万能的，只有在确实有必要的场景下才推荐使用集群流控。

另外若在生产环境使用集群限流，管控端还需要关注以下的问题：

- Token Server 自动管理（分配/选举 Token Server）
- Token Server 高可用，在某个 server 不可用时自动 failover 到其它机器



# 4. Sentinel 实战-如何对热点参数限流

我们已经对单机限流和集群限流有过一定了解了，但是他们都是针对一些固定的资源进行流控的，在实际的应用场景中我们可能会遇到各种复杂的情况，不可能通过固定的资源来进行限流。

比如我们想要对一段时间内频繁访问的用户 ID 进行限制，又或者我们想统计一段时间内最常购买的商品 ID 并针对商品 ID 进行限制。那这里的用户 ID 和商品 ID 都是可变的资源，通过原先的固定资源已经无法满足我们的需求了，这时我们就可以通过 Sentinel 为我们提供的 **热点参数限流**来达到这样的效果。

## 4.1 什么是热点

首先我们需要知道什么是热点，热点就是访问非常频繁的参数。

例如我们大家都知道的爬虫，就是通过脚本去爬取其他网站的数据，一般防爬虫的常用方法之一就是限制爬虫的 IP，那对应到这里 IP 就是一种热点的参数。

那么 Sentinel 是怎么知道哪些参数是热点，哪些参数不是热点的呢？Sentinel 利用 LRU 策略，结合底层的滑动窗口机制来实现热点参数统计。**LRU 策略可以统计单位时间内，最近最常访问的热点参数**，而滑动窗口机制可以帮助统计每个参数的 qps。

**PS**：获取某种参数的 qps 最高的 topN 相关的代码在 ClusterParamMetric 类的 getTopValues 方法中，有兴趣的可以去了解下。

说简单点就是，Sentinel 会先检查出提交过来的参数，哪些是热点的参数，然后在应用热点参数的限流规则，将qps 超过设定阈值的请求给 block 掉，整个过程如下图所示：

<img src="https://mmbiz.qpic.cn/mmbiz_png/GtXvavW2UlwblexiaiaiaVWZnwY3vuyeKibHZeoa0wiasXYQ8uBuO5Oyfvq7Y0SBBO5XvM8c0crSrFmJyvoRjwLQnMA/640?wx_fmt=png&tp=webp&wxfrom=5&wx_lazy=1&wx_co=1" alt="图片" style="zoom:50%;" />

## 4.2 如何使用热点限流

现在我们知道了可以通过热点参数限流的方式，来动态的保护某些访问比较热的资源，或者是限制一些访问比较频繁的请求。现在让我们来看下怎样来使用热点参数限流吧。

### 4.2.1 引入依赖

第一步还是引入依赖，热点限流是在 sentinel-extension 模块中定义的，把热点限流当成一种扩展模块来使用，还不知道其中的用意。

引入下列的依赖：

```xml
<dependency>
    <groupId>com.alibaba.csp</groupId>
    <artifactId>sentinel-parameter-flow-control</artifactId>
    <version>1.8.2</version>
</dependency>
```

### 4.2.2 定义资源

使用热点限流时，定义资源和普通限流的操作方式是一致的。例如我们可以定义资源名为：

```java
/**
 * 热点限流的资源名
 */
private String resourceName = "freqParam";
```

### 4.2.3 定义规则

定义好资源之后，就可以来定义规则了，我们还是先用简单的硬编码的方式来演示，实际的使用过程中还是要通过控制台来定义规则的。

热点参数的规则是通过 ParamFlowRule 来定义的，跟流控的规则类 FlowRule 差不多，具体的属性如下表所示：

| 属性              | 说明                                                         | 默认值   |
| ----------------- | ------------------------------------------------------------ | -------- |
| resource          | 资源名，必填                                                 |          |
| count             | 限流阈值，必填                                               |          |
| grade             | 限流模式                                                     | QPS 模式 |
| durationInSec     | 统计窗口时间长度（单位为秒），1.6.0 版本开始支持             | 1s       |
| controlBehavior   | 流控效果（支持快速失败和匀速排队模式），1.6.0 版本开始支持   | 快速失败 |
| maxQueueingTimeMs | 最大排队等待时长（仅在匀速排队模式生效），1.6.0 版本开始支持 | 0ms      |
| paramIdx          | 热点参数的索引，必填，对应 `SphU.entry(xxx, args)` 中的参数索引位置 |          |
| paramFlowItemList | 参数例外项，可以针对指定的参数值单独设置限流阈值，不受前面 `count` 阈值的限制。**仅支持基本类型和字符串类型** |          |
| clusterMode       | 是否是集群参数流控规则                                       | `false`  |
| clusterConfig     | 集群流控相关配置                                             |          |

定义好规则之后，可以通过 ParamFlowRuleManager 的 loadRules 方法更新热点参数规则，如下所示：

```java
// 定义热点限流的规则，对第一个参数设置 qps 限流模式，阈值为5
ParamFlowRule rule = new ParamFlowRule(resourceName).setParamIdx(0)
        .setGrade(RuleConstant.FLOW_GRADE_QPS).setCount(5);

ParamFlowRuleManager.loadRules(Collections.singletonList(rule));
```

### 4.2.4 埋点

我们定义好资源，也定义好规则了，最后一步就是在代码中埋点来使应用热点限流的规则了。

那么如何传入对应的参数来让 Sentinel 进行统计呢？我们可以通过 `SphU` 类里面几个 `entry` 重载方法来传入：

```java
public static Entry entry(String name, EntryType trafficType, int batchCount, Object... args)
  
public static Entry entry(Method method, EntryType trafficType, int batchCount, Object... args)
```

其中最后的一串 args 就是要传入的参数，有多个就按照次序依次传入。

还是通过一个简单的 Controller 方法来进行埋点，如下所示：

```java
/**
 * 热点参数限流
 */
@GetMapping("/freqParamFlow")
@ResponseBody
public String freqParamFlow(@RequestParam("uid")Long uid, @RequestParam("ip") Long ip) {
    Entry entry = null;
    
    String retVal;

    try {
        // 只对参数uid进行限流，参数ip不进行限制
        entry = SphU.entry(resourceName, EntryType.IN, 1,uid);
        retVal = "passed";

    } catch (BlockException e){
        retVal = "blocked";

    } finally {
        if (entry!= null){
            entry.exit();

        }
    }
    return retVal;
}
```

### 4.2.5 查看效果

现在我们在浏览器中快速请求`http://127.0.0.1:8001/freqParamFlow?uid=123&ip=`的刷新页面来请求该方法，可以看到交替返回passed和blocked。

### 4.2.6 如果不传入参数

从上面的情况可以看出，我们已经对参数 uid 应用了热点限流的规则，并且也从模拟的结果中看到了效果。

如果我们把上述埋点的代码修改一下，将传入的 uid 参数移除，其他的地方都不变，改成如下所示：

```java
// 不传入任何参数
entry = SphU.entry(resourceName, EntryType.IN,1);
```

再次启动后，重新刷新页面，发现所有的请求都 pass 了。

因为此时应用的是热点限流的规则，但是我们没有指定任何的热点参数，所以所有的请求都会被 pass 掉。



# 参考

[Sentinel 实战-限流篇](https://mp.weixin.qq.com/s/rjyU37Dm-sxNln7GUD8tOw)

[Sentinel 实战-控制台篇](https://mp.weixin.qq.com/s/23EDFHMXLwsDqw-4O5dR5A)

[Sentinel 实战-规则持久化](https://mp.weixin.qq.com/s/twMFiBfRawKLR-1-N-f1yw)

[Sentinel 实战-集群限流](https://mp.weixin.qq.com/s/3V7m3ivgO-vxP4GXUktqdw)

[Sentinel实战：如何对热点参数限流](https://mp.weixin.qq.com/s/zl9CqcRE2jSeJXdxd2_7-Q)

[Sentinel 实战-集群限流环境搭建(详细图文描述)](https://mp.weixin.qq.com/s/sw3-XtZLAf5aUq027NOA8g)

