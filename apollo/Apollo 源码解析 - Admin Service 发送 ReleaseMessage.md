# 1. 概述

> 老艿艿：本系列假定胖友已经阅读过 [《Apollo 官方 wiki 文档》](https://github.com/ctripcorp/apollo/wiki/) 。

本文接 [《Apollo 源码解析 —— Portal 发布配置》](http://www.iocoder.cn/Apollo/portal-publish/?self) 一文，分享配置发布的第三步，**Admin Service 发布配置后，发送 ReleaseMessage 给各个Config Service** 。

> FROM [《Apollo配置中心设计》](https://github.com/ctripcorp/apollo/wiki/Apollo配置中心设计#211-发送releasemessage的实现方式) 的 [2.1.1 发送ReleaseMessage的实现方式](https://www.iocoder.cn/Apollo/admin-server-send-release-message/#)
>
> Admin Service 在配置发布后，需要通知所有的 Config Service 有配置发布，从而 Config Service 可以通知对应的客户端来拉取最新的配置。
>
> 从概念上来看，这是一个典型的**消息使用场景**，Admin Service 作为 **producer** 发出消息，各个Config Service 作为 **consumer** 消费消息。通过一个**消息组件**（Message Queue）就能很好的实现 Admin Service 和 Config Service 的解耦。
>
> 在实现上，考虑到 Apollo 的实际使用场景，以及为了**尽可能减少外部依赖**，我们没有采用外部的消息中间件，而是通过**数据库实现了一个简单的消息队列**。

实现方式如下：

> 1. Admin Service 在配置发布后会往 ReleaseMessage 表插入一条消息记录，消息内容就是配置发布的 AppId+Cluster+Namespace ，参见 DatabaseMessageSender 。
> 2. Config Service 有一个线程会每秒扫描一次 ReleaseMessage 表，看看是否有新的消息记录，参见 ReleaseMessageScanner 。
> 3. Config Service 如果发现有新的消息记录，那么就会通知到所有的消息监听器（ReleaseMessageListener），如 NotificationControllerV2 ，消息监听器的注册过程参见 ConfigServiceAutoConfiguration 。
> 4. NotificationControllerV2 得到配置发布的 **AppId+Cluster+Namespace** 后，会通知对应的客户端。

示意图如下：

> ![流程](http://blog-1259650185.cosbj.myqcloud.com/img/202204/04/1649086237.png)

本文分享第 **1 + 2 + 3** 步骤，在 `apollo-biz` 项目的 `message` 模块实现。😏 第 4 步，我们在下一篇文章分享。

# 2. ReleaseMessage

`com.ctrip.framework.apollo.biz.entity.ReleaseMessage` ，**不继承** BaseEntity 抽象类，ReleaseMessage **实体**。代码如下：

```java
@Entity
@Table(name = "ReleaseMessage")
public class ReleaseMessage {
  @Id
  @GeneratedValue(strategy = GenerationType.IDENTITY)
  @Column(name = "Id")
  private long id; // 编号

  @Column(name = "Message", nullable = false)
  private String message; // 消息内容，通过 {@link com.ctrip.framework.apollo.biz.utils.ReleaseMessageKeyGenerator#generate(String, String, String)} 方法生成

  @Column(name = "DataChange_LastTime")
  private Date dataChangeLastModifiedTime; // 最后更新时间

  @PrePersist
  protected void prePersist() {
    if (this.dataChangeLastModifiedTime == null) {
      dataChangeLastModifiedTime = new Date();
    }
  }

}
```

- `id` 字段，编号，**自增**。
- `message` 字段，消息内容。通过 **ReleaseMessageKeyGenerator** 生成。胖友先跳到 [「2.1 ReleaseMessageKeyGenerator」](https://www.iocoder.cn/Apollo/admin-server-send-release-message/#) 看看具体实现。
- `#dataChangeLastModifiedTime`字段，最后更新时间。
  - `#prePersist()` 方法，若保存时，未设置该字段，进行补全。

## 2.1 ReleaseMessageKeyGenerator

`com.ctrip.framework.apollo.biz.utils.ReleaseMessageKeyGenerator` ，ReleaseMessage **消息内容**( `ReleaseMessage.message` )生成器。代码如下：

```java
public class ReleaseMessageKeyGenerator {

  private static final Joiner STRING_JOINER = Joiner.on(ConfigConsts.CLUSTER_NAMESPACE_SEPARATOR);

  public static String generate(String appId, String cluster, String namespace) {
    return STRING_JOINER.join(appId, cluster, namespace);
  }
}
```

`#generate(...)` 方法，将 `appId` + `cluster` + `namespace` 拼接，使用 `ConfigConsts.CLUSTER_NAMESPACE_SEPARATOR = "+"` 作为**间隔**，例如：`"test+default+application"` 。

因此，对于同一个 Namespace ，生成的**消息内容**是**相同**的。通过这样的方式，我们可以使用最新的 `ReleaseMessage` 的 **`id`** 属性，作为 Namespace 是否发生变更的标识。而 Apollo 确实是通过这样的方式实现，Client 通过不断使用**获得到 `ReleaseMessage` 的 `id` 属性**作为**版本号**，请求 Config Service 判断是否**配置**发生了变化。🙂 这里胖友先留有一个印象，后面我们会再详细介绍这个流程。

正因为，ReleaseMessage 设计的意图是作为配置发生变化的通知，所以对于同一个 Namespace ，仅需要保留**其最新的** ReleaseMessage 记录即可。所以，在 [「3.3 DatabaseMessageSender」](https://www.iocoder.cn/Apollo/admin-server-send-release-message/#) 中，我们会看到，有后台任务不断清理**旧的** ReleaseMessage 记录。

## 2.2 ReleaseMessageRepository

`com.ctrip.framework.apollo.biz.repository.ReleaseMessageRepository` ，继承 `org.springframework.data.repository.PagingAndSortingRepository` 接口，提供 ReleaseMessage 的**数据访问** 给 Admin Service 和 Config Service 。代码如下：

```java
public interface ReleaseMessageRepository extends PagingAndSortingRepository<ReleaseMessage, Long> {
  List<ReleaseMessage> findFirst500ByIdGreaterThanOrderByIdAsc(Long id);

  ReleaseMessage findTopByOrderByIdDesc();

  ReleaseMessage findTopByMessageInOrderByIdDesc(Collection<String> messages);

  List<ReleaseMessage> findFirst100ByMessageAndIdLessThanOrderByIdAsc(String message, Long id);

  @Query("select message, max(id) as id from ReleaseMessage where message in :messages group by message")
  List<Object[]> findLatestReleaseMessagesGroupByMessages(@Param("messages") Collection<String> messages);
}
```

# 3. MessageSender

`com.ctrip.framework.apollo.biz.message.MessageSender` ，Message **发送者**接口。代码如下：

```java
public interface MessageSender {

    /**
     * 发送 Message
     *
     * @param message 消息
     * @param channel 通道（主题）
     */
    void sendMessage(String message, String channel);

}
```

## 3.1 发布配置

在 ReleaseController 的 `#publish(...)` 方法中，会调用 `MessageSender#sendMessage(message, channel)` 方法，发送 Message 。**调用**简化代码如下：

```java
// send release message
// 获得 Cluster 名
Namespace parentNamespace = namespaceService.findParentNamespace(namespace);
String messageCluster;
if (parentNamespace != null) { //  有父 Namespace ，说明是灰度发布，使用父 Namespace 的集群名
    messageCluster = parentNamespace.getClusterName();
} else {
    messageCluster = clusterName; // 使用请求的 ClusterName
}
// 发送 Release 消息
messageSender.sendMessage(ReleaseMessageKeyGenerator.generate(appId, messageCluster, namespaceName), Topics.APOLLO_RELEASE_TOPIC);
```

- 关于**父** Namespace 部分的代码，胖友看完**灰度发布**的内容，再回过头理解。
- `ReleaseMessageKeyGenerator#generate(appId, clusterName, namespaceName)` 方法，生成 ReleaseMessage 的**消息内容**。
- 使用 **Topic** 为 `Topics.APOLLO_RELEASE_TOPIC` 。

## 3.2 Topics

`com.ctrip.framework.apollo.biz.message.Topics` ，Topic **枚举**。代码如下：

```java
public class Topics {

    /**
     * Apollo 配置发布 Topic
     */
    public static final String APOLLO_RELEASE_TOPIC = "apollo-release";

}
```

## 3.3 DatabaseMessageSender

`com.ctrip.framework.apollo.biz.message.DatabaseMessageSender` ，实现 MessageSender 接口，Message 发送者**实现类**，基于**数据库**实现。

### 3.3.1 构造方法

```java
@Component
public class DatabaseMessageSender implements MessageSender {
  private static final Logger logger = LoggerFactory.getLogger(DatabaseMessageSender.class);
  private static final int CLEAN_QUEUE_MAX_SIZE = 100; // 清理 Message 队列 最大容量
  private BlockingQueue<Long> toClean = Queues.newLinkedBlockingQueue(CLEAN_QUEUE_MAX_SIZE); // 清理 Message 队列
  private final ExecutorService cleanExecutorService; // 清理 Message ExecutorService
  private final AtomicBoolean cleanStopped; // 是否停止清理 Message 标识

  private final ReleaseMessageRepository releaseMessageRepository;

  public DatabaseMessageSender(final ReleaseMessageRepository releaseMessageRepository) {
    cleanExecutorService = Executors.newSingleThreadExecutor(ApolloThreadFactory.create("DatabaseMessageSender", true));  // 创建 ExecutorService 对象
    cleanStopped = new AtomicBoolean(false); // 设置 cleanStopped 为 false 
    this.releaseMessageRepository = releaseMessageRepository;
  }
  // ... 省略其他方法

}
```

- 主要和**清理** ReleaseMessage 相关的属性。

### 3.3.2 sendMessage

```java
@Override
@Transactional
public void sendMessage(String message, String channel) {
  logger.info("Sending message {} to channel {}", message, channel);
  if (!Objects.equals(channel, Topics.APOLLO_RELEASE_TOPIC)) {  // 仅允许发送 APOLLO_RELEASE_TOPI
    logger.warn("Channel {} not supported by DatabaseMessageSender!", channel);
    return;
  }

  Tracer.logEvent("Apollo.AdminService.ReleaseMessage", message); // Tracer 日志
  Transaction transaction = Tracer.newTransaction("Apollo.AdminService", "sendMessage");
  try {
    ReleaseMessage newMessage = releaseMessageRepository.save(new ReleaseMessage(message)); // 保存 ReleaseMessage 对象
    toClean.offer(newMessage.getId()); // 添加到清理 Message 队列。若队列已满，添加失败，不阻塞等待。
    transaction.setStatus(Transaction.SUCCESS);
  } catch (Throwable ex) {
    logger.error("Sending message to database failed", ex);
    transaction.setStatus(ex);
    throw ex;
  } finally {
    transaction.complete();
  }
}
```

- 第 5 至 9 行：第 5 至 9 行：仅**允许**发送 APOLLO_RELEASE_TOPIC 。

- 第 16 行：调用 `ReleaseMessageRepository#save(ReleaseMessage)` 方法，保存 ReleaseMessage 对象。

- 第 18 行：调用`toClean#offer(Long id)`方法，添加到清理 Message 队列。**若队列已满，添加失败，不阻塞等待**。

### 3.3.3 清理 ReleaseMessage 任务

`#initialize()` 方法，通知 Spring 调用，初始化**清理 ReleaseMessage 任务**。代码如下：

 ```java
 @PostConstruct
 private void initialize() {
   cleanExecutorService.submit(() -> {
     while (!cleanStopped.get() && !Thread.currentThread().isInterrupted()) { // 若未停止，持续运行。
       try {
         Long rm = toClean.poll(1, TimeUnit.SECONDS); // 拉取
         if (rm != null) { // 队列非空，处理拉取到的消息
           cleanMessage(rm);
         } else {
           TimeUnit.SECONDS.sleep(5); // 队列为空，sleep ，避免空跑，占用 CPU
         }
       } catch (Throwable ex) {
         Tracer.logError(ex);  // Tracer 日志
       }
     }
   });
 }
 ```

- 第 3 至 21 行：调用`ExecutorService#submit(Runnable)`方法，提交**清理 ReleaseMessage 任务**
  - 第 5 行：**循环**，直到停止。
  - 第 8 行：调用`BlockingQueue#poll(long timeout, TimeUnit unit)`方法，拉取**队头**的**消息编号**
    - 第 10 至 11 行：若拉取到消息编号，调用 `#cleanMessage(Long id)` 方法，处理拉取到的消息，即**清理老消息们**。
    - 第 13 至 15 行：若**未**拉取到消息编号，说明队列为**空**，**sleep** ，避免空跑，占用 CPU 。

------

`#cleanMessage(Long id)` 方法，清理老消息们。代码如下：

```java
private void cleanMessage(Long id) {
  // 查询对应的 ReleaseMessage 对象，避免已经删除。因为，DatabaseMessageSender 会在多进程中执行。例如：1）Config Service + Admin Service ；2）N * Config Service ；3）N * Admin Service
  //double check in case the release message is rolled back
  ReleaseMessage releaseMessage = releaseMessageRepository.findById(id).orElse(null);
  if (releaseMessage == null) {
    return;
  }
  boolean hasMore = true;
  while (hasMore && !Thread.currentThread().isInterrupted()) { // 循环删除相同消息内容( "message" )的老消息
    List<ReleaseMessage> messages = releaseMessageRepository.findFirst100ByMessageAndIdLessThanOrderByIdAsc(
        releaseMessage.getMessage(), releaseMessage.getId()); // 拉取相同消息内容的 100 条的老消息。按照 id 升序
    // 老消息的定义：比当前消息编号小，即先发送的
    releaseMessageRepository.deleteAll(messages); // 删除老消息
    hasMore = messages.size() == 100; // 若拉取不足 100 条，说明无老消息了

    messages.forEach(toRemove -> Tracer.logEvent(
        String.format("ReleaseMessage.Clean.%s", toRemove.getMessage()), String.valueOf(toRemove.getId())));
  }
}
```

- 第 5 至 8 行：调用`ReleaseMessageRepository#findOne(id)`方法，查询对应的 ReleaseMessage 对象，避免已经删除。

  - 因为，**DatabaseMessageSender 会在多进程中执行**。例如：1）Config Service + Admin Service ；2）N \*Config Service ；3）N\* Admin Service 。
  - 为什么 Config Service 和 Admin Service 都会启动清理任务呢？😈 因为 DatabaseMessageSender 添加了 `@Component` 注解， 被 `apollo-adminservice` 和 `apoll-configservice` 项目都引用了，所以都会启动该任务。

- 第 10 至 23 行：**循环删除，相同消息内容**(`ReleaseMessage.message`)的**老**消息，即 Namespace 的**老**消息。

  - 第 14 至 15 行：调用`ReleaseMessageRepository#findFirst100ByMessageAndIdLessThanOrderByIdAsc(message, id)`

    方法，拉取相同消息内容的 **100**条的老消息，按照 id **升序**。

    - 老消息的**定义**：比当前消息编号小，即先发送的。

  - 第 17 行：调用 `ReleaseMessageRepository#delete(messages)` 方法，**删除**老消息。

  - 第 19 行：若拉取**不足** 100 条，说明无老消息了。

  - 第 21 至 22 行：Tracer 日志

# 4. ReleaseMessageListener

`com.ctrip.framework.apollo.biz.message.ReleaseMessageListener` ，ReleaseMessage **监听器**接口。代码如下：

```java
public interface ReleaseMessageListener {
  /**
   * 处理 ReleaseMessage
   *
   * @param message
   * @param channel 通道（主题）
   */
  void handleMessage(ReleaseMessage message, String channel);
}
```

ReleaseMessageListener 实现子类如下图：

![子类](http://blog-1259650185.cosbj.myqcloud.com/img/202204/05/1649088829.png)

例如，NotificationControllerV2 得到配置发布的 **AppId+Cluster+Namespace** 后，会通知对应的客户端。🙂 具体的代码实现，我们下一篇文章分享。

## 4.1 ReleaseMessageScanner

`com.ctrip.framework.apollo.biz.message.ReleaseMessageScanner` ，实现 `org.springframework.beans.factory.InitializingBean` 接口，ReleaseMessage 扫描器，**被 Config Service 使用**。

```java
public class ReleaseMessageScanner implements InitializingBean {
  private static final Logger logger = LoggerFactory.getLogger(ReleaseMessageScanner.class);
  private static final int missingReleaseMessageMaxAge = 10; // hardcoded to 10, could be configured via BizConfig if necessary
  @Autowired
  private BizConfig bizConfig;
  @Autowired
  private ReleaseMessageRepository releaseMessageRepository;
  private int databaseScanInterval; // 从 DB 中扫描 ReleaseMessage 表的频率，单位：毫秒
  private final List<ReleaseMessageListener> listeners; // 监听器数组
  private final ScheduledExecutorService executorService; // 定时任务服务
  private final Map<Long, Integer> missingReleaseMessages; // missing release message id => age counter
  private long maxIdScanned; // 最后扫描到的 ReleaseMessage 的编号

  public ReleaseMessageScanner() {
    listeners = Lists.newCopyOnWriteArrayList(); // 创建监听器数组
    executorService = Executors.newScheduledThreadPool(1, ApolloThreadFactory
        .create("ReleaseMessageScanner", true)); //  创建 ScheduledExecutorService 对象
    missingReleaseMessages = Maps.newHashMap();
  }
  
  // ... 省略其他方法

}
```

- `listeners` 属性，监听器数组。通过 `#addMessageListener(ReleaseMessageListener)` 方法，注册 ReleaseMessageListener 。在 **MessageScannerConfiguration** 中，调用该方法，初始化 ReleaseMessageScanner 的监听器们。代码如下：

  ```java
    @Configuration
    static class MessageScannerConfiguration {
      private final NotificationController notificationController;
      private final ConfigFileController configFileController;
      private final NotificationControllerV2 notificationControllerV2;
      private final GrayReleaseRulesHolder grayReleaseRulesHolder;
      private final ReleaseMessageServiceWithCache releaseMessageServiceWithCache;
      private final ConfigService configService;
  
      public MessageScannerConfiguration(
          final NotificationController notificationController,
          final ConfigFileController configFileController,
          final NotificationControllerV2 notificationControllerV2,
          final GrayReleaseRulesHolder grayReleaseRulesHolder,
          final ReleaseMessageServiceWithCache releaseMessageServiceWithCache,
          final ConfigService configService) {
        this.notificationController = notificationController;
        this.configFileController = configFileController;
        this.notificationControllerV2 = notificationControllerV2;
        this.grayReleaseRulesHolder = grayReleaseRulesHolder;
        this.releaseMessageServiceWithCache = releaseMessageServiceWithCache;
        this.configService = configService;
      }
  
      @Bean
      public ReleaseMessageScanner releaseMessageScanner() {
        ReleaseMessageScanner releaseMessageScanner = new ReleaseMessageScanner();
        //0. handle release message cache
        releaseMessageScanner.addMessageListener(releaseMessageServiceWithCache);
        //1. handle gray release rule
        releaseMessageScanner.addMessageListener(grayReleaseRulesHolder);
        //2. handle server cache
        releaseMessageScanner.addMessageListener(configService);
        releaseMessageScanner.addMessageListener(configFileController);
        //3. notify clients
        releaseMessageScanner.addMessageListener(notificationControllerV2);
        releaseMessageScanner.addMessageListener(notificationController);
        return releaseMessageScanner;
      }
    }
  ```

### 4.1.2 初始化 Scan 任务

`#afterPropertiesSet()` 方法，通过 Spring 调用，初始化 Scan 任务。代码如下：

```java
@Override
public void afterPropertiesSet() throws Exception {
  databaseScanInterval = bizConfig.releaseMessageScanIntervalInMilli(); //  从 ServerConfig 中获得频率
  maxIdScanned = loadLargestMessageId(); // 获得最大的 ReleaseMessage 的编号
  executorService.scheduleWithFixedDelay(() -> { // 创建从 DB 中扫描 ReleaseMessage 表的定时任务
    Transaction transaction = Tracer.newTransaction("Apollo.ReleaseMessageScanner", "scanMessage");
    try {
      scanMissingMessages();
      scanMessages();  // 从 DB 中，扫描 ReleaseMessage 们
      transaction.setStatus(Transaction.SUCCESS);
    } catch (Throwable ex) {
      transaction.setStatus(ex);
      logger.error("Scan and send message failed", ex);
    } finally {
      transaction.complete();
    }
  }, databaseScanInterval, databaseScanInterval, TimeUnit.MILLISECONDS);

}
```

- 第 4 行：调用 `BizConfig#releaseMessageScanIntervalInMilli()` 方法，从 ServerConfig 中获得频率，单位：毫秒。可通过 `"apollo.message-scan.interval"` 配置，默认：**1000** ms 。

- 第 6 行：调用 `#loadLargestMessageId()` 方法，获得**最大的** ReleaseMessage 的编号。代码如下：

  ```java
  /**
   * find largest message id as the current start point
   *
   * @return current largest message id
   */
  private long loadLargestMessageId() {
      ReleaseMessage releaseMessage = releaseMessageRepository.findTopByOrderByIdDesc();
      return releaseMessage == null ? 0 : releaseMessage.getId();
  }
  ```

- 第 8 至 24 行：调用`ExecutorService#scheduleWithFixedDelay(Runnable)` 方法，创建从 DB 中扫描 ReleaseMessage 表的定时任务。
  - 第 13 行：调用 `#scanMessages()` 方法，从 DB 中，扫描**新的** ReleaseMessage 们。

------

`#scanMessages()` 方法，**循环**扫描消息，直到没有**新的** ReleaseMessage 为止。代码如下：

```java
private void scanMessages() {
    boolean hasMoreMessages = true;
    while (hasMoreMessages && !Thread.currentThread().isInterrupted()) {
        hasMoreMessages = scanAndSendMessages();
    }
}
```

------

`#scanAndSendMessages()` 方法，扫描消息，并返回是否继续有**新的** ReleaseMessage 可以继续扫描。代码如下：

```java
private boolean scanAndSendMessages() {
  //current batch is 500 获得大于 maxIdScanned 的 500 条 ReleaseMessage 记录，按照 id 升序
  List<ReleaseMessage> releaseMessages =
      releaseMessageRepository.findFirst500ByIdGreaterThanOrderByIdAsc(maxIdScanned);
  if (CollectionUtils.isEmpty(releaseMessages)) {
    return false;
  }
  fireMessageScanned(releaseMessages); // 触发监听器
  int messageScanned = releaseMessages.size();
  long newMaxIdScanned = releaseMessages.get(messageScanned - 1).getId(); // 获得新的 maxIdScanned ，取最后一条记录
  // check id gaps, possible reasons are release message not committed yet or already rolled back
  if (newMaxIdScanned - maxIdScanned > messageScanned) {
    recordMissingReleaseMessageIds(releaseMessages, maxIdScanned);
  }
  maxIdScanned = newMaxIdScanned;
  return messageScanned == 500;  // 若拉取不足 500 条，说明无新消息了
}
```

- 第 4 至 7 行：调用 `ReleaseMessageRepository#findFirst500ByIdGreaterThanOrderByIdAsc(maxIdScanned)` 方法，获得**大于 maxIdScanned** 的 **500** 条 ReleaseMessage 记录，**按照 id 升序**。
- 第 9 行：调用 `#fireMessageScanned(List<ReleaseMessage> messages)` 方法，触发监听器们。
- 第 10 至 12 行：获得**新的** `maxIdScanned` ，取**最后一条**记录。
- 第 14 行：若拉取**不足 500** 条，说明无新消息了。

### 4.1.3 fireMessageScanned

`#fireMessageScanned(List<ReleaseMessage> messages)` 方法，触发监听器，处理 ReleaseMessage 们。代码如下：

```java
private void fireMessageScanned(List<ReleaseMessage> messages) {
    for (ReleaseMessage message : messages) { // 循环 ReleaseMessage
        for (ReleaseMessageListener listener : listeners) { // 循环 ReleaseMessageListener
            try {
                // 触发监听器
                listener.handleMessage(message, Topics.APOLLO_RELEASE_TOPIC);
            } catch (Throwable ex) {
                Tracer.logError(ex);
                logger.error("Failed to invoke message listener {}", listener.getClass(), ex);
            }
        }
    }
}
```



# 参考

[Admin Service 发送 ReleaseMessage](https://www.iocoder.cn/Apollo/admin-server-send-release-message/)
