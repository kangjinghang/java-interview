## 5. 通用组件

### 5.1 Logger组件

日志模块作为一个通用的功能，在系统里通常会使用第三方的日志框架。Java 的日志框架有很多，比如：JUL（Java Util Logging）、Log4j、Logback、Log4j2、Tinylog 等。除此之外，还有 JCL（Apache Commons Logging）和 SLF4J 这样的“门面日志”。

今天我们就来看看 Tomcat 的日志模块是如何实现的。默认情况下，Tomcat 使用自身的 JULI 作为 Tomcat 内部的日志处理系统。JULI 的日志门面采用了 JCL；而 JULI 的具体实现是构建在 Java 原生的日志系统`java.util.logging`之上的，所以在看 JULI 的日志系统之前，我先简单介绍一下 Java 的日志系统。

#### 5.1.1 Java 日志系统

Java 的日志包在`java.util.logging`路径下，包含了几个比较重要的组件，我们通过一张图来理解一下：

<img src="http://blog-1259650185.cosbj.myqcloud.com/img/202201/17/1642423393.png" alt="22" style="zoom: 67%;" />

从图上我们看到这样几个重要的组件：

- Logger：用来记录日志的类。
- Handler：规定了日志的输出方式，如控制台输出、写入文件。
- Level：定义了日志的不同等级。
- Formatter：将日志信息格式化，比如纯文本、XML。

我们可以通过下面的代码来使用这些组件：

```java
public static void main(String[] args) {
  Logger logger = Logger.getLogger("com.mycompany.myapp");
  logger.setLevel(Level.FINE);
  logger.setUseParentHandlers(false);
  Handler hd = new ConsoleHandler();
  hd.setLevel(Level.FINE);
  logger.addHandler(hd);
  logger.info("start log"); 
}
```

#### 5.1.2 JULI

JULI 对日志的处理方式与 Java 自带的基本一致，但是 Tomcat 中可以包含多个应用，而每个应用的日志系统应该相互独立。Java 的原生日志系统是每个 JVM 有一份日志的配置文件，这不符合 Tomcat 多应用的场景，所以 JULI 重新实现了一些日志接口。

**DirectJDKLog**

Log 的基础实现类是 DirectJDKLog，这个类相对简单，就包装了一下 Java 的 Logger 类。但是它也在原来的基础上进行了一些修改，比如修改默认的格式化方式。

**LogFactory**

Log 使用了工厂模式来向外提供实例，LogFactory 是一个单例，可以通过 SeviceLoader 为 Log 提供自定义的实现版本，如果没有配置，就默认使用 DirectJDKLog。

```java
private LogFactory() {
    // 通过 ServiceLoader 尝试加载 Log 的实现类
    ServiceLoader<Log> logLoader = ServiceLoader.load(Log.class);
    Constructor<? extends Log> m=null;
    
    for (Log log: logLoader) {
        Class<? extends Log> c=log.getClass();
        try {
            m=c.getConstructor(String.class);
            break;
        }
        catch (NoSuchMethodException | SecurityException e) {
            throw new Error(e);
        }
    }
    
    // 如何没有定义 Log 的实现类，discoveredLogConstructor 为 null
    discoveredLogConstructor = m;
}
```

下面的代码是 LogFactory 的 getInstance 方法：

```java
public Log getInstance(String name) throws LogConfigurationException {
    // 如果 discoveredLogConstructor 为 null，也就没有定义 Log 类，默认用 DirectJDKLog
    if (discoveredLogConstructor == null) {
        return DirectJDKLog.getInstance(name);
    }
 
    try {
        return discoveredLogConstructor.newInstance(name);
    } catch (ReflectiveOperationException | IllegalArgumentException e) {
        throw new LogConfigurationException(e);
    }
}
```

**Handler**

在 JULI 中就自定义了两个 Handler：FileHandler 和 AsyncFileHandler。FileHandler 可以简单地理解为一个在特定位置写文件的工具类，有一些写操作常用的方法，如 open、write(publish)、close、flush 等，使用了读写锁。其中的日志信息通过 Formatter 来格式化。

AsyncFileHandler 继承自 FileHandler，实现了异步的写操作。其中缓存存储是通过阻塞双端队列 LinkedBlockingDeque 来实现的。当应用要通过这个 Handler 来记录一条消息时，消息会先被存储到队列中，而在后台会有一个专门的线程来处理队列中的消息，取出的消息会通过父类的 publish 方法写入相应文件内。这样就可以在大量日志需要写入的时候起到缓冲作用，防止都阻塞在写日志这个动作上。需要注意的是，我们可以为阻塞双端队列设置不同的模式，在不同模式下，对新进入的消息有不同的处理方式，有些模式下会直接丢弃一些日志：

```java
OVERFLOW_DROP_LAST：丢弃栈顶的元素 
OVERFLOW_DROP_FIRSH：丢弃栈底的元素 
OVERFLOW_DROP_FLUSH：等待一定时间并重试，不会丢失元素 
OVERFLOW_DROP_CURRENT：丢弃放入的元素
```

**Formatter**

Formatter 通过一个 format 方法将日志记录 LogRecord 转化成格式化的字符串，JULI 提供了三个新的 Formatter。

- OnelineFormatter：基本与 Java 自带的 SimpleFormatter 格式相同，不过把所有内容都写到了一行中。
- VerbatimFormatter：只记录了日志信息，没有任何额外的信息。
- JdkLoggerFormatter：格式化了一个轻量级的日志信息。

**日志配置**

Tomcat 的日志配置文件为 Tomcat 文件夹下`conf/logging.properties`。我来拆解一下这个配置文件，首先可以看到各种 Handler 的配置：

```properties
handlers = 1catalina.org.apache.juli.AsyncFileHandler, 2localhost.org.apache.juli.AsyncFileHandler, 3manager.org.apache.juli.AsyncFileHandler, 4host-manager.org.apache.juli.AsyncFileHandler, java.util.logging.ConsoleHandler
 
.handlers = 1catalina.org.apache.juli.AsyncFileHandler, java.util.logging.ConsoleHandler
```

以`1catalina.org.apache.juli.AsyncFileHandler`为例，数字是为了区分同一个类的不同实例；catalina、localhost、manager 和 host-manager 是 Tomcat 用来区分不同系统日志的标志；后面的字符串表示了 Handler 具体类型，如果要添加 Tomcat 服务器的自定义 Handler，需要在字符串里添加。

接下来是每个 Handler 设置日志等级、目录和文件前缀，自定义的 Handler 也要在这里配置详细信息:

```properties
1catalina.org.apache.juli.AsyncFileHandler.level = FINE
1catalina.org.apache.juli.AsyncFileHandler.directory = ${catalina.base}/logs
1catalina.org.apache.juli.AsyncFileHandler.prefix = catalina.
1catalina.org.apache.juli.AsyncFileHandler.maxDays = 90
1catalina.org.apache.juli.AsyncFileHandler.encoding = UTF-8
```

#### 5.1.3 Tomcat + SLF4J + Logback

SLF4J 和 JCL 都是日志门面，那它们有什么区别呢？它们的区别主要体现在日志服务类的绑定机制上。JCL 采用运行时动态绑定的机制，在运行时动态寻找和加载日志框架实现。

SLF4J 日志输出服务绑定则相对简单很多，在编译时就静态绑定日志框架，只需要提前引入需要的日志框架。另外 Logback 可以说 Log4j 的进化版，在性能和可用性方面都有所提升。你可以参考官网上这篇[文章](https://logback.qos.ch/reasonsToSwitch.html)来了解 Logback 的优势。

基于此我们来实战一下如何将 Tomcat 默认的日志框架切换成为“SLF4J + Logback”。具体的步骤是：

1. 根据你的 Tomcat 版本，从[这里](https://github.com/tomcat-slf4j-logback/tomcat-slf4j-logback/releases)下载所需要文件。解压后你会看到一个类似于 Tomcat 目录结构的文件夹。

2. 替换或拷贝下列这些文件到 Tomcat 的安装目录：

   <img src="http://blog-1259650185.cosbj.myqcloud.com/img/202201/17/1642424835.jpeg" alt="23" style="zoom:50%;" />

3. 删除`<Tomcat>/conf/logging.properties`

4. 启动 Tomcat

### 5.2 Manager组件

我们可以通过 Request 对象的 getSession 方法来获取 Session，并通过 Session 对象来读取和写入属性值。而 Session 的管理是由 Web 容器来完成的，主要是对 Session 的创建和销毁，除此之外 Web 容器还需要将 Session 状态的变化通知给监听者。

当然 Session 管理还可以交给 Spring 来做，好处是与特定的 Web 容器解耦，Spring Session 的核心原理是通过 Filter 拦截 Servlet 请求，将标准的 ServletRequest 包装一下，换成 Spring 的 Request 对象，这样当我们调用 Request 对象的 getSession 方法时，Spring 在背后为我们创建和管理 Session。

那么 Tomcat 的 Session 管理机制我们还需要了解吗？我觉得还是有必要，因为只有了解这些原理，我们才能更好的理解 Spring Session，以及 Spring Session 为什么设计成这样。今天我们就从 Session 的创建、Session 的清理以及 Session 的事件通知这几个方面来了解 Tomcat 的 Session 管理机制。

#### 5.2.1 Session 的创建

Tomcat 中主要由每个 Context 容器内的一个 Manager 对象来管理 Session。默认实现类为 StandardManager。下面我们通过它的接口来了解一下 StandardManager 的功能：

```java
public interface Manager {
    public Context getContext();
    public void setContext(Context context);
    public SessionIdGenerator getSessionIdGenerator();
    public void setSessionIdGenerator(SessionIdGenerator sessionIdGenerator);
    public long getSessionCounter();
    public void setSessionCounter(long sessionCounter);
    public int getMaxActive();
    public void setMaxActive(int maxActive);
    public int getActiveSessions();
    public long getExpiredSessions();
    public void setExpiredSessions(long expiredSessions);
    public int getRejectedSessions();
    public int getSessionMaxAliveTime();
    public void setSessionMaxAliveTime(int sessionMaxAliveTime);
    public int getSessionAverageAliveTime();
    public int getSessionCreateRate();
    public int getSessionExpireRate();
    public void add(Session session);
    public void changeSessionId(Session session);
    public void changeSessionId(Session session, String newId);
    public Session createEmptySession();
    public Session createSession(String sessionId);
    public Session findSession(String id) throws IOException;
    public Session[] findSessions();
    public void load() throws ClassNotFoundException, IOException;
    public void remove(Session session);
    public void remove(Session session, boolean update);
    public void addPropertyChangeListener(PropertyChangeListener listener)
    public void removePropertyChangeListener(PropertyChangeListener listener);
    public void unload() throws IOException;
    public void backgroundProcess();
    public boolean willAttributeDistribute(String name, Object value);
}
```

不出意外我们在接口中看到了添加和删除 Session 的方法；另外还有 load 和 unload 方法，它们的作用是分别是将 Session 持久化到存储介质和从存储介质加载 Session。

当我们调用`HttpServletRequest.getSession(true)`时，这个参数 true 的意思是“如果当前请求还没有 Session，就创建一个新的”。那 Tomcat 在背后为我们做了些什么呢？

HttpServletRequest 是一个接口，Tomcat 实现了这个接口，具体实现类是：`org.apache.catalina.connector.Request`。

但这并不是我们拿到的 Request，Tomcat 为了避免把一些实现细节暴露出来，还有基于安全上的考虑，定义了 Request 的包装类，叫作 RequestFacade，我们可以通过代码来理解一下：

```java
public class Request implements HttpServletRequest {}
```

````java
public class RequestFacade implements HttpServletRequest {
  protected Request request = null;
  
  public HttpSession getSession(boolean create) {
     return request.getSession(create);
  }
}
````

因此我们拿到的 Request 类其实是 RequestFacade，RequestFacade 的 getSession 方法调用的是 Request 类的 getSession 方法，我们继续来看 Session 具体是如何创建的：

```java
Context context = getContext();
if (context == null) {
    return null;
}
 
Manager manager = context.getManager();
if (manager == null) {
    return null;      
}
 
session = manager.createSession(sessionId);
session.access();
```

从上面的代码可以看出，Request 对象中持有 Context 容器对象，而 Context 容器持有 Session 管理器 Manager，这样通过 Context 组件就能拿到 Manager 组件，最后由 Manager 组件来创建 Session。

因此最后还是到了 StandardManager，StandardManager 的父类叫 ManagerBase，这个 createSession 方法定义在 ManagerBase 中，StandardManager 直接重用这个方法。

接着我们来看 ManagerBase 的 createSession 是如何实现的：

```java
@Override
public Session createSession(String sessionId) {
    // 首先判断 Session 数量是不是到了最大值，最大 Session 数可以通过参数设置
    if ((maxActiveSessions >= 0) &&
            (getActiveSessions() >= maxActiveSessions)) {
        rejectedSessions++;
        throw new TooManyActiveSessionsException(
                sm.getString("managerBase.createSession.ise"),
                maxActiveSessions);
    }
 
    // 重用或者创建一个新的 Session 对象，请注意在 Tomcat 中就是 StandardSession
    // 它是 HttpSession 的具体实现类，而 HttpSession 是 Servlet 规范中定义的接口
    Session session = createEmptySession();
 
 
    // 初始化新 Session 的值
    session.setNew(true);
    session.setValid(true);
    session.setCreationTime(System.currentTimeMillis());
    session.setMaxInactiveInterval(getContext().getSessionTimeout() * 60);
    String id = sessionId;
    if (id == null) {
        id = generateSessionId();
    }
    session.setId(id);// 这里会将 Session 添加到 ConcurrentHashMap 中
    sessionCounter++;
    
    // 将创建时间添加到 LinkedList 中，并且把最先添加的时间移除
    // 主要还是方便清理过期 Session
    SessionTiming timing = new SessionTiming(session.getCreationTime(), 0);
    synchronized (sessionCreationTiming) {
        sessionCreationTiming.add(timing);
        sessionCreationTiming.poll();
    }
    return session
}
```

到此我们明白了 Session 是如何创建出来的，创建出来后 Session 会被保存到一个 ConcurrentHashMap 中：

```java
// ManagerBase.java
protected Map<String, Session> sessions = new ConcurrentHashMap<>();
```

请注意 Session 的具体实现类是 StandardSession，StandardSession 同时实现了`javax.servlet.http.HttpSession`和`org.apache.catalina.Session`接口，并且对程序员暴露的是 StandardSessionFacade 外观类，保证了 StandardSession 的安全，避免了程序员调用其内部方法进行不当操作。StandardSession 的核心成员变量如下：

```java
public class StandardSession implements HttpSession, Session, Serializable {
    protected ConcurrentMap<String, Object> attributes = new ConcurrentHashMap<>();
    protected long creationTime = 0L;
    protected transient volatile boolean expiring = false;
    protected transient StandardSessionFacade facade = null;
    protected String id = null;
    protected volatile long lastAccessedTime = creationTime;
    protected transient ArrayList<SessionListener> listeners = new ArrayList<>();
    protected transient Manager manager = null;
    protected volatile int maxInactiveInterval = -1;
    protected volatile boolean isNew = false;
    protected volatile boolean isValid = false;
    protected transient Map<String, Object> notes = new Hashtable<>();
    protected transient Principal principal = null;
}
```

#### 5.2.2 Session 的清理

我们再来看看 Tomcat 是如何清理过期的 Session。在 Tomcat热加载和热部署的章节里，我讲到容器组件会开启一个 ContainerBackgroundProcessor 后台线程，调用自己以及子容器的 backgroundProcess 进行一些后台逻辑的处理，和 Lifecycle 一样，这个动作也是具有传递性的，也就是说子容器还会把这个动作传递给自己的子容器。你可以参考下图来理解这个过程。

<img src="http://blog-1259650185.cosbj.myqcloud.com/img/202201/17/1642430347.jpeg" alt="24" style="zoom:50%;" />

其中父容器会遍历所有的子容器并调用其 backgroundProcess 方法，而 StandardContext 重写了该方法，它会调用 StandardManager 的 backgroundProcess 进而完成 Session 的清理工作，下面是 StandardManager 的 backgroundProcess 方法的代码：

```java
public void backgroundProcess() {
    // processExpiresFrequency 默认值为 6，而 backgroundProcess 默认每隔 10s 调用一次，也就是说除了任务执行的耗时，每隔 60s 执行一次
    count = (count + 1) % processExpiresFrequency;
    if (count == 0) // 默认每隔 60s 执行一次 Session 清理
        processExpires();
}
 
/**
 * 单线程处理，不存在线程安全问题
 */
public void processExpires() {
 
    // 获取所有的 Session
    Session sessions[] = findSessions();   
    int expireHere = 0 ;
    for (int i = 0; i < sessions.length; i++) {
        // Session 的过期是在 isValid() 方法里处理的
        if (sessions[i]!=null && !sessions[i].isValid()) {
            expireHere++;
        }
    }
}
```

backgroundProcess 由 Tomcat 后台线程调用，默认是每隔 10 秒调用一次，但是 Session 的清理动作不能太频繁，因为需要遍历 Session 列表，会耗费 CPU 资源，所以在 backgroundProcess 方法中做了取模处理，backgroundProcess 调用 6 次，才执行一次 Session 清理，也就是说 Session 清理每 60 秒执行一次。

#### 5.2.3 Session 事件通知

按照 Servlet 规范，在 Session 的生命周期过程中，要将事件通知监听者，Servlet 规范定义了 Session 的监听器接口：

```java
public interface HttpSessionListener extends EventListener {
    //Session 创建时调用
    public default void sessionCreated(HttpSessionEvent se) {
    }
    
    //Session 销毁时调用
    public default void sessionDestroyed(HttpSessionEvent se) {
    }
}
```

注意到这两个方法的参数都是 HttpSessionEvent，所以 Tomcat 需要先创建 HttpSessionEvent 对象，然后遍历 Context 内部的 LifecycleListener，并且判断是否为 HttpSessionListener 实例，如果是的话则调用 HttpSessionListener 的 sessionCreated 方法进行事件通知。这些事情都是在 Session 的 setId 方法中完成的：

```java
session.setId(id);
 
@Override
public void setId(String id, boolean notify) {
    // 如果这个 id 已经存在，先从 Manager 中删除
    if ((this.id != null) && (manager != null))
        manager.remove(this);
 
    this.id = id;
 
    // 添加新的 Session
    if (manager != null)
        manager.add(this);
 
    // 这里面完成了 HttpSessionListener 事件通知
    if (notify) {
        tellNew();
    }
}
```

从代码我们看到 setId 方法调用了 tellNew 方法，那 tellNew 又是如何实现的呢？

```java
public void tellNew() {
 
    // 通知 org.apache.catalina.SessionListener
    fireSessionEvent(Session.SESSION_CREATED_EVENT, null);
 
    // 获取 Context 内部的 LifecycleListener 并判断是否为 HttpSessionListener
    Context context = manager.getContext();
    Object listeners[] = context.getApplicationLifecycleListeners();
    if (listeners != null && listeners.length > 0) {
    
        // 创建 HttpSessionEvent
        HttpSessionEvent event = new HttpSessionEvent(getSession());
        for (int i = 0; i < listeners.length; i++) {
            // 判断是否是 HttpSessionListener
            if (!(listeners[i] instanceof HttpSessionListener))
                continue;
                
            HttpSessionListener listener = (HttpSessionListener) listeners[i];
            // 注意这是容器内部事件
            context.fireContainerEvent("beforeSessionCreated", listener);   
            // 触发 Session Created 事件
            listener.sessionCreated(event);
            
            // 注意这也是容器内部事件
            context.fireContainerEvent("afterSessionCreated", listener);
            
        }
    }
}
```

上面代码的逻辑是，先通过 StandardContext 将 HttpSessionListener 类型的 Listener 取出，然后依次调用它们的 sessionCreated 方法。

#### 5.2.4 小结

本节涉及了  Session 的创建、销毁和事件通知，里面涉及不少相关的类，下面我画了一张图帮你理解和消化一下这些类的关系：

<img src="http://blog-1259650185.cosbj.myqcloud.com/img/202201/17/1642431253.jpeg" alt="25" style="zoom:67%;" />

Servlet 规范中定义了 HttpServletRequest 和 HttpSession 接口，Tomcat 实现了这些接口，但具体实现细节并没有暴露给开发者，因此定义了两个包装类，RequestFacade 和 StandardSessionFacade。

Tomcat 是通过 Manager 来管理 Session 的，默认实现是 StandardManager。StandardContext 持有 StandardManager 的实例，并存放了 HttpSessionListener 集合，Session 在创建和销毁时，会通知监听器。

### 5.3 Cluster组件

为了支持水平扩展和高可用，Tomcat 提供了集群部署的能力，但与此同时也带来了分布式系统的一个通用问题，那就是如何在集群中的多个节点之间保持数据的一致性，比如会话（Session）信息。

要实现这一点，基本上有两种方式，一种是把所有 Session 数据放到一台服务器或者一个数据库中，集群中的所有节点通过访问这台 Session 服务器来获取数据。另一种方式就是在集群中的节点间进行 Session 数据的同步拷贝，这里又分为两种策略：第一种是将一个节点的 Session 拷贝到集群中其他所有节点；第二种是只将一个节点上的 Session 数据拷贝到另一个备份节点。

对于 Tomcat 的 Session 管理来说，这两种方式都支持。今天我们就来看看第二种方式的实现原理，也就是 Tomcat 集群通信的原理和配置方法，最后通过官网上的一个例子来了解下 Tomcat 集群到底是如何工作的。

#### 5.3.1 集群通信原理

要实现集群通信，首先要知道集群中都有哪些成员。Tomcat 是通过**组播**（Multicast）来实现的。那什么是组播呢？为了理解组播，我先来说说什么是“单播”。网络节点之间的通信就好像是人们之间的对话一样，一个人对另外一个人说话，此时信息的接收和传递只在两个节点之间进行，比如你在收发电子邮件、浏览网页时，使用的就是单播，也就是我们熟悉的“点对点通信”。

如果一台主机需要将同一个消息发送多个主机逐个传输，效率就会比较低，于是就出现组播技术。组播是**一台主机向指定的一组主机发送数据报包**，组播通信的过程是这样的：每一个 Tomcat 节点在启动时和运行时都会周期性（默认 500 毫秒）发送组播心跳包，同一个集群内的节点都在相同的**组播地址**和**端口**监听这些信息；在一定的时间内（默认 3 秒）不发送**组播报文**的节点就会被认为已经崩溃了，会从集群中删去。因此通过组播，集群中每个成员都能维护一个集群成员列表。

#### 5.3.2 集群通信配置

有了集群成员的列表，集群中的节点就能通过 TCP 连接向其他节点传输 Session 数据。Tomcat 通过 SimpleTcpCluster 类来进行会话复制（In-Memory Replication）。要开启集群功能，只需要在`server.xml`里加上一行就行：

```xml
<Cluster className="org.apache.catalina.ha.tcp.SimpleTcpCluster"/>
```

虽然只是简单的一行配置，但这一行配置等同于下面这样的配置，也就是说 Tomcat 给我们设置了很多默认参数，这些参数都跟集群通信有关。

```xml
<!-- 
  SimpleTcpCluster 是用来复制 Session 的组件。复制 Session 有同步和异步两种方式：
  同步模式下，向浏览器的发送响应数据前，需要先将 Session 拷贝到其他节点完；
  异步模式下，无需等待 Session 拷贝完成就可响应。异步模式更高效，但是同步模式
  可靠性更高。
  同步异步模式由 channelSendOptions 参数控制，默认值是 8，为异步模式；4 是同步模式。
  在异步模式下，可以通过加上 " 拷贝确认 "（Acknowledge）来提高可靠性，此时
  channelSendOptions 设为 10
-->
<Cluster className="org.apache.catalina.ha.tcp.SimpleTcpCluster"
                 channelSendOptions="8">
   <!--
    Manager 决定如何管理集群的 Session 信息。
    Tomcat 提供了两种 Manager：BackupManager 和 DeltaManager。
    BackupManager－集群下的某一节点的 Session，将复制到一个备份节点。
    DeltaManager－ 集群下某一节点的 Session，将复制到所有其他节点。
    DeltaManager 是 Tomcat 默认的集群 Manager。
    
    expireSessionsOnShutdown－设置为 true 时，一个节点关闭时，
    将导致集群下的所有 Session 失效
    notifyListenersOnReplication－集群下节点间的 Session 复制、
    删除操作，是否通知 session listeners
    
    maxInactiveInterval－集群下 Session 的有效时间 (单位:s)。
    maxInactiveInterval 内未活动的 Session，将被 Tomcat 回收。
    默认值为 1800(30min)
  -->
  <Manager className="org.apache.catalina.ha.session.DeltaManager"
                   expireSessionsOnShutdown="false"
                   notifyListenersOnReplication="true"/>
 
   <!--
    Channel 是 Tomcat 节点之间进行通讯的工具。
    Channel 包括 5 个组件：Membership、Receiver、Sender、
    Transport、Interceptor
   -->
  <Channel className="org.apache.catalina.tribes.group.GroupChannel">
     <!--
      Membership 维护集群的可用节点列表。它可以检查到新增的节点，
      也可以检查没有心跳的节点
      className－指定 Membership 使用的类
      address－组播地址
      port－组播端口
      frequency－发送心跳 (向组播地址发送 UDP 数据包) 的时间间隔 (单位:ms)。
      dropTime－Membership 在 dropTime(单位:ms) 内未收到某一节点的心跳，
      则将该节点从可用节点列表删除。默认值为 3000。
     -->
     <Membership  className="org.apache.catalina.tribes.membership.
         McastService"
         address="228.0.0.4"
         port="45564"
         frequency="500"
         dropTime="3000"/>
     
     <!--
       Receiver 用于各个节点接收其他节点发送的数据。
       接收器分为两种：BioReceiver(阻塞式)、NioReceiver(非阻塞式)
 
       className－指定 Receiver 使用的类
       address－接收消息的地址
       port－接收消息的端口
       autoBind－端口的变化区间，如果 port 为 4000，autoBind 为 100，
                 接收器将在 4000-4099 间取一个端口进行监听。
       selectorTimeout－NioReceiver 内 Selector 轮询的超时时间
       maxThreads－线程池的最大线程数
     -->
     <Receiver className="org.apache.catalina.tribes.transport.nio.
         NioReceiver"
         address="auto"
         port="4000"
         autoBind="100"
         selectorTimeout="5000"
         maxThreads="6"/>
 
      <!--
         Sender 用于向其他节点发送数据，Sender 内嵌了 Transport 组件，
         Transport 真正负责发送消息。
      -->
      <Sender className="org.apache.catalina.tribes.transport.
          ReplicationTransmitter">
          <!--
            Transport 分为两种：bio.PooledMultiSender(阻塞式)
            和 nio.PooledParallelSender(非阻塞式)，PooledParallelSender
            是从 tcp 连接池中获取连接，可以实现并行发送，即集群中的节点可以
            同时向其他所有节点发送数据而互不影响。
           -->
          <Transport className="org.apache.catalina.tribes.
          transport.nio.PooledParallelSender"/>     
       </Sender>
       
       <!--
         Interceptor : Cluster 的拦截器
         TcpFailureDetector－TcpFailureDetector 可以拦截到某个节点关闭
         的信息，并尝试通过 TCP 连接到此节点，以确保此节点真正关闭，从而更新集
         群可用节点列表                 
        -->
       <Interceptor className="org.apache.catalina.tribes.group.
       interceptors.TcpFailureDetector"/>
       
       <!--
         MessageDispatchInterceptor－查看 Cluster 组件发送消息的
         方式是否设置为 Channel.SEND_OPTIONS_ASYNCHRONOUS，如果是，
         MessageDispatchInterceptor 先将等待发送的消息进行排队，
         然后将排好队的消息转给 Sender。
        -->
       <Interceptor className="org.apache.catalina.tribes.group.
       interceptors.MessageDispatchInterceptor"/>
  </Channel>
 
  <!--
    Valve : Tomcat 的拦截器，
    ReplicationValve－在处理请求前后打日志；过滤不涉及 Session 变化的请求。                 
    -->
  <Valve className="org.apache.catalina.ha.tcp.ReplicationValve"
    filter=""/>
  <Valve className="org.apache.catalina.ha.session.
  JvmRouteBinderValve"/>
 
  <!--
    Deployer 用于集群的 farm 功能，监控应用中文件的更新，以保证集群中所有节点
    应用的一致性，如某个用户上传文件到集群中某个节点的应用程序目录下，Deployer
    会监测到这一操作并把文件拷贝到集群中其他节点相同应用的对应目录下以保持
    所有应用的一致，这是一个相当强大的功能。
  -->
  <Deployer className="org.apache.catalina.ha.deploy.FarmWarDeployer"
     tempDir="/tmp/war-temp/"
     deployDir="/tmp/war-deploy/"
     watchDir="/tmp/war-listen/"
     watchEnabled="false"/>
 
  <!--
    ClusterListener : 监听器，监听 Cluster 组件接收的消息
    使用 DeltaManager 时，Cluster 接收的信息通过 ClusterSessionListener
    传递给 DeltaManager，从而更新自己的 Session 列表。
    -->
  <ClusterListener className="org.apache.catalina.ha.session.
  ClusterSessionListener"/>
  
</Cluster>
```

从上面的的参数列表可以看到，默认情况下 Session 管理组件 DeltaManager 会在节点之间拷贝 Session，DeltaManager 采用的一种 all-to-all 的工作方式，即集群中的节点会把 Session 数据向所有其他节点拷贝，而不管其他节点是否部署了当前应用。当集群节点数比较少时，比如少于 4 个，这种 all-to-all 的方式是不错的选择；但是当集群中的节点数量比较多时，数据拷贝的开销成指数级增长，这种情况下可以考虑 BackupManager，BackupManager 只向一个备份节点拷贝数据。

在大体了解了 Tomcat 集群实现模型后，就可以对集群作出更优化的配置了。Tomcat 推荐了一套配置，使用了比 DeltaManager 更高效的 BackupManager，并且通过 ReplicationValve 设置了请求过滤。

这里还请注意在一台服务器部署多个节点时需要修改 Receiver 的侦听端口，另外为了在节点间高效地拷贝数据，所有 Tomcat 节点最好采用相同的配置，具体配置如下：

```xml
<Cluster className="org.apache.catalina.ha.tcp.SimpleTcpCluster"
                 channelSendOptions="6">
 
    <Manager className="org.apache.catalina.ha.session.BackupManager"
                   expireSessionsOnShutdown="false"
                   notifyListenersOnReplication="true"
                   mapSendOptions="6"/>
         
     <Channel className="org.apache.catalina.tribes.group.
     GroupChannel">
     
     <Membership className="org.apache.catalina.tribes.membership.
     McastService"
       address="228.0.0.4"
       port="45564"
       frequency="500"
       dropTime="3000"/>
       
     <Receiver className="org.apache.catalina.tribes.transport.nio.
     NioReceiver"
       address="auto"
       port="5000"
       selectorTimeout="100"
       maxThreads="6"/>
 
     <Sender className="org.apache.catalina.tribes.transport.
     ReplicationTransmitter">
          <Transport className="org.apache.catalina.tribes.transport.
          nio.PooledParallelSender"/>
     </Sender>
     
     <Interceptor className="org.apache.catalina.tribes.group.
     interceptors.TcpFailureDetector"/>
     
     <Interceptor className="org.apache.catalina.tribes.group.
     interceptors.MessageDispatchInterceptor"/>
     
     <Interceptor className="org.apache.catalina.tribes.group.
     interceptors.ThroughputInterceptor"/>
   </Channel>
 
   <Valve className="org.apache.catalina.ha.tcp.ReplicationValve"
       filter=".*\.gif|.*\.js|.*\.jpeg|.*\.jpg|.*\.png|.*\
               .htm|.*\.html|.*\.css|.*\.txt"/>
 
   <Deployer className="org.apache.catalina.ha.deploy.FarmWarDeployer"
       tempDir="/tmp/war-temp/"
       deployDir="/tmp/war-deploy/"
       watchDir="/tmp/war-listen/"
       watchEnabled="false"/>
 
    <ClusterListener className="org.apache.catalina.ha.session.
    ClusterSessionListener"/>
</Cluster>
```

#### 5.3.3 集群工作过程

Tomcat 的官网给出了一个例子，来说明 Tomcat 集群模式下是如何工作的，以及 Tomcat 集群是如何实现高可用的。比如集群由 Tomcat A 和 Tomcat B 两个 Tomcat 实例组成，按照时间先后顺序发生了如下事件：

**1. Tomcat A 启动**

Tomcat A 启动过程中，当 Host 对象被创建时，一个 Cluster 组件（默认是 SimpleTcpCluster）被关联到这个 Host 对象。当某个应用在`web.xml`中设置了 Distributable 时，Tomcat 将为此应用的上下文环境创建一个 DeltaManager。SimpleTcpCluster 启动 Membership 服务和 Replication 服务。

**2. Tomcat B 启动（在 Tomcat A 之后启动）**

首先 Tomcat B 会执行和 Tomcat A 一样的操作，然后 SimpleTcpCluster 会建立一个由 Tomcat A 和 Tomcat B 组成的 Membership。接着 Tomcat B 向集群中的 Tomcat A 请求 Session 数据，如果 Tomcat A 没有响应 Tomcat B 的拷贝请求，Tomcat B 会在 60 秒后 time out。在 Session 数据拷贝完成之前 Tomcat B 不会接收浏览器的请求。

**3. Tomcat A 接收 HTTP 请求，创建 Session 1**

Tomcat A 响应客户请求，在把结果发送回客户端之前，ReplicationValve 会拦截当前请求（如果 Filter 中配置了不需拦截的请求类型，这一步就不会进行，默认配置下拦截所有请求），如果发现当前请求更新了 Session，就调用 Replication 服务建立 TCP 连接将 Session 拷贝到 Membership 列表中的其他节点即 Tomcat B。在拷贝时，所有保存在当前 Session 中的可序列化的对象都会被拷贝，而不仅仅是发生更新的部分。

**4. Tomcat A 崩溃**

当 Tomcat A 崩溃时，Tomcat B 会被告知 Tomcat A 已从集群中退出，然后 Tomcat B 就会把 Tomcat A 从自己的 Membership 列表中删除。并且 Tomcat B 的 Session 更新时不再往 Tomcat A 拷贝，同时负载均衡器会把后续的 HTTP 请求全部转发给 Tomcat B。在此过程中所有的 Session 数据不会丢失。

**5. Tomcat B 接收 Tomcat A 的请求**

Tomcat B 正常响应本应该发往 Tomcat A 的请求，因为 Tomcat B 保存了 Tomcat A 的所有 Session 数据。

**6. Tomcat A 重新启动**

Tomcat A 按步骤 1、2 操作启动，加入集群，并从 Tomcat B 拷贝所有 Session 数据，拷贝完成后开始接收请求。

**7. Tomcat A 接收请求，Session 1 被用户注销**

Tomcat 继续接收发往 Tomcat A 的请求，Session 1 设置为失效。请注意这里的失效并非因为 Tomcat A 处于非活动状态超过设置的时间，而是应用程序执行了注销的操作（比如用户登出）而引起的 Session 失效。这时 Tomcat A 向 Tomcat B 发送一个 Session 1 Expired 的消息，Tomcat B 收到消息后也会把 Session 1 设置为失效。

**8. Tomcat B 接收到一个新请求，创建 Session 2**

同理这个新的 Session 也会被拷贝到 Tomcat A。

**9. Tomcat A 上的 Session 2 过期**

因超时原因引起的 Session 失效 Tomcat A 无需通知 Tomcat B，Tomcat B 同样知道 Session 2 已经超时。因此对于 Tomcat 集群有一点非常重要，**所有节点的操作系统时间必须一致**。不然会出现某个节点 Session 已过期而在另一节点此 Session 仍处于活动状态的现象。

## 6. 性能优化

### 6.1 如何监控Tomcat的性能

今天我们接着来聊如何监控 Tomcat 的各种指标，因为只有我们掌握了这些指标和信息，才能对 Tomcat 内部发生的事情一目了然，让我们明白系统的瓶颈在哪里，进而做出调优的决策。

在今天的文章里，我们首先来看看到底都需要监控 Tomcat 哪些关键指标，接着来具体学习如何通过 JConsole 来监控它们。如果系统没有暴露 JMX 接口，我们还可以通过命令行来查看 Tomcat 的性能指标。

#### 6.1.1 Tomcat 的关键指标

Tomcat 的关键指标有**吞吐量、响应时间、错误数、线程池、CPU 以及 JVM 内存**。

我来简单介绍一下这些指标背后的意义。其中前三个指标是我们最关心的业务指标，Tomcat 作为服务器，就是要能够又快有好地处理请求，因此吞吐量要大、响应时间要短，并且错误数要少。

而后面三个指标是跟系统资源有关的，当某个资源出现瓶颈就会影响前面的业务指标，比如线程池中的线程数量不足会影响吞吐量和响应时间；但是线程数太多会耗费大量 CPU，也会影响吞吐量；当内存不足时会触发频繁地 GC，耗费 CPU，最后也会反映到业务指标上来。

那如何监控这些指标呢？Tomcat 可以通过 JMX 将上述指标暴露出来的。JMX（Java Management Extensions，即 Java 管理扩展）是一个为应用程序、设备、系统等植入监控管理功能的框架。JMX 使用管理 MBean 来监控业务资源，这些 MBean 在 JMX MBean 服务器上注册，代表 JVM 中运行的应用程序或服务。每个 MBean 都有一个属性列表。JMX 客户端可以连接到 MBean Server 来读写 MBean 的属性值。你可以通过下面这张图来理解一下 JMX 的工作原理：

<img src="http://blog-1259650185.cosbj.myqcloud.com/img/202201/17/1642434825.png" alt="26"  />

Tomcat 定义了一系列 MBean 来对外暴露系统状态，接下来我们来看看如何通过 JConsole 来监控这些指标。

#### 6.1.2 通过 JConsole 监控 Tomcat

首先我们需要开启 JMX 的远程监听端口，具体来说就是设置若干 JVM 参数。我们可以在 Tomcat 的 bin 目录下新建一个名为`setenv.sh`的文件（或者`setenv.bat`，根据你的操作系统类型），然后输入下面的内容：

```shell
export JAVA_OPTS="${JAVA_OPTS} -Dcom.sun.management.jmxremote"
export JAVA_OPTS="${JAVA_OPTS} -Dcom.sun.management.jmxremote.port=9001"
export JAVA_OPTS="${JAVA_OPTS} -Djava.rmi.server.hostname=x.x.x.x"
export JAVA_OPTS="${JAVA_OPTS} -Dcom.sun.management.jmxremote.ssl=false"
export JAVA_OPTS="${JAVA_OPTS} -Dcom.sun.management.jmxremote.authenticate=false"
```

重启 Tomcat，这样 JMX 的监听端口 9001 就开启了，接下来通过 JConsole 来连接这个端口。

```shell
jconsole x.x.x.x:9001
```

我们可以看到 JConsole 的主界面：

<img src="http://blog-1259650185.cosbj.myqcloud.com/img/202201/17/1642435010.png" alt="27" style="zoom:67%;" />

前面我提到的需要监控的关键指标有**吞吐量、响应时间、错误数、线程池、CPU 以及 JVM 内存**，接下来我们就来看看怎么在 JConsole 上找到这些指标。

**吞吐量、响应时间、错误数**

在 MBeans 标签页下选择 GlobalRequestProcessor，这里有 Tomcat 请求处理的统计信息。你会看到 Tomcat 中的各种连接器，展开“http-nio-8080”，你会看到这个连接器上的统计信息，其中 maxTime 表示最长的响应时间，processingTime 表示平均响应时间，requestCount 表示吞吐量，errorCount 就是错误数。

<img src="http://blog-1259650185.cosbj.myqcloud.com/img/202201/17/1642435114.png" alt="28" style="zoom:67%;" />

**线程池**

选择“线程”标签页，可以看到当前 Tomcat 进程中有多少线程，如下图所示：

<img src="http://blog-1259650185.cosbj.myqcloud.com/img/202201/17/1642435167.png" alt="29" style="zoom:67%;" />

图的左下方是线程列表，右边是线程的运行栈，这些都是非常有用的信息。如果大量线程阻塞，通过观察线程栈，能看到线程阻塞在哪个函数，有可能是 I/O 等待，或者是死锁。

**CPU**

在主界面可以找到 CPU 使用率指标，请注意这里的 CPU 使用率指的是 Tomcat 进程占用的 CPU，不是主机总的 CPU 使用率。

![30](http://blog-1259650185.cosbj.myqcloud.com/img/202201/18/1642435395.png)

**JVM 内存**

选择“内存”标签页，你能看到 Tomcat 进程的 JVM 内存使用情况。

<img src="http://blog-1259650185.cosbj.myqcloud.com/img/202201/18/1642435417.png" alt="31" style="zoom:67%;" />

你还可以查看 JVM 各内存区域的使用情况，大的层面分堆区和非堆区。堆区里有分为 Eden、Survivor 和 Old。选择“VM Summary”标签，可以看到虚拟机内的详细信息。

<img src="http://blog-1259650185.cosbj.myqcloud.com/img/202201/18/1642435487.png" alt="32" style="zoom:67%;" />

#### 6.1.3 命令行查看 Tomcat 指标

极端情况下如果 Web 应用占用过多 CPU 或者内存，又或者程序中发生了死锁，导致 Web 应用对外没有响应，监控系统上看不到数据，这个时候需要我们登陆到目标机器，通过命令行来查看各种指标。

1. 首先我们通过 ps 命令找到 Tomcat 进程，拿到进程 ID。

   ````shell
   ps -ef | grep tomcat
   ````

2. 接着查看进程状态的大致信息，通过`cat/proc/<pid>/status`命令：

   <img src="http://blog-1259650185.cosbj.myqcloud.com/img/202201/18/1642435699.png" alt="33" style="zoom:67%;" />

3. 监控进程的 CPU 和内存资源使用情况：

   <img src="http://blog-1259650185.cosbj.myqcloud.com/img/202201/18/1642435738.png" alt="34" style="zoom:67%;" />

4. 查看 Tomcat 的网络连接，比如 Tomcat 在 8080 端口上监听连接请求，通过下面的命令查看连接列表：

   <img src="http://blog-1259650185.cosbj.myqcloud.com/img/202201/18/1642435778.png" alt="35" style="zoom:67%;" />

   你还可以分别统计处在“已连接”状态和“TIME_WAIT”状态的连接数：

   ````shell
   netstat -na | grep ESTAB | grep 8080 | wc -l
   ````

   ```shell
   netstat -na | grep TIME_WAIT | grep 8080 | wc -l
   ```

5. 通过 ifstat 来查看网络流量，大致可以看出 Tomcat 当前的请求数和负载状况。

   ![36](http://blog-1259650185.cosbj.myqcloud.com/img/202201/18/1642435874.png)

### 6.2 Tomcat I/O和线程池的并发调优

上一节我们谈到了如何监控 Tomcat 的性能指标，在这个基础上，我们接着聊如何对 Tomcat 进行调优。

Tomcat 的调优涉及 I/O 模型和线程池调优、JVM 内存调优以及网络优化等，这一节我们来聊聊 I/O 模型和线程池调优，由于 Web 应用程序跑在 Tomcat 的工作线程中，因此 Web 应用对请求的处理时间也直接影响 Tomcat 整体的性能，而 Tomcat 和 Web 应用在运行过程中所用到的资源都来自于操作系统，因此调优需要将服务端看作是一个整体来考虑。

所谓的 I/O 调优指的是选择 NIO、NIO.2 还是 APR，而线程池调优指的是给 Tomcat 的线程池设置合适的参数，使得 Tomcat 能够又快又好地处理请求。

#### 6.2.1 I/O 模型的选择

I/O 调优实际上是连接器类型的选择，一般情况下默认都是 NIO，在绝大多数情况下都是够用的，除非你的 Web 应用用到了 TLS 加密传输，而且对性能要求极高，这个时候可以考虑 APR，因为 APR 通过 OpenSSL 来处理 TLS 握手和加 / 解密。OpenSSL 本身用 C 语言实现，它还对 TLS 通信做了优化，所以性能比 Java 要高。

那你可能会问那什么时候考虑选择 NIO.2？我的建议是如果你的 Tomcat 跑在 Windows 平台上，并且 HTTP 请求的数据量比较大，可以考虑 NIO.2，这是因为 Windows 从操作系统层面实现了真正意义上的异步 I/O，如果传输的数据量比较大，异步 I/O 的效果就能显现出来。

如果你的 Tomcat 跑在 Linux 平台上，建议使用 NIO，这是因为 Linux 内核没有很完善地支持异步 I/O 模型，因此 JVM 并没有采用原生的 Linux 异步 I/O，而是在应用层面通过 epoll 模拟了异步 I/O 模型，只是 Java NIO 的使用者感觉不到而已。因此可以这样理解，在 Linux 平台上，Java NIO 和 Java NIO.2 底层都是通过 epoll 来实现的，但是 Java NIO 更加简单高效。

#### 6.2.2 线程池调优

跟 I/O 模型紧密相关的是线程池，线程池的调优就是设置合理的线程池参数。我们先来看看 Tomcat 线程池中有哪些关键参数：

<img src="http://blog-1259650185.cosbj.myqcloud.com/img/202201/18/1642436594.jpeg" alt="37" style="zoom:50%;" />

这里面最核心的就是如何确定 maxThreads 的值，如果这个参数设置小了，Tomcat 会发生线程饥饿，并且请求的处理会在队列中排队等待，导致响应时间变长；如果 maxThreads 参数值过大，同样也会有问题，因为服务器的 CPU 的核数有限，线程数太多会导致线程在 CPU 上来回切换，耗费大量的切换开销。

那 maxThreads 设置成多少才算是合适呢？为了理解清楚这个问题，我们先来看看什么是利特尔法则（Little’s Law）。

**利特尔法则**

> 系统中的请求数 = 请求的到达速率 × 每个请求处理时间

其实这个公式很好理解，我举个我们身边的例子：我们去超市购物结账需要排队，但是你是如何估算一个队列有多长呢？队列中如果每个人都买很多东西，那么结账的时间就越长，队列也会越长；同理，短时间一下有很多人来收银台结账，队列也会变长。因此队列的长度等于新人加入队列的频率乘以平均每个人处理的时间。

**计算出了队列的长度，那么我们就创建相应数量的线程来处理请求，这样既能以最快的速度处理完所有请求，同时又没有额外的线程资源闲置和浪费。**

假设一个单核服务器在接收请求：

- 如果每秒 10 个请求到达，平均处理一个请求需要 1 秒，那么服务器任何时候都有 10 个请求在处理，即需要 10 个线程。
- 如果每秒 10 个请求到达，平均处理一个请求需要 2 秒，那么服务器在每个时刻都有 20 个请求在处理，因此需要 20 个线程。
- 如果每秒 10000 个请求到达，平均处理一个请求需要 1 秒，那么服务器在每个时刻都有 10000 个请求在处理，因此需要 10000 个线程。

因此可以总结出一个公式：

**线程池大小 = 每秒请求数 × 平均请求处理时间**

这是理想的情况，也就是说线程一直在忙着干活，没有被阻塞在 I/O 等待上。实际上任务在执行中，线程不可避免会发生阻塞，比如阻塞在 I/O 等待上，等待数据库或者下游服务的数据返回，虽然通过非阻塞 I/O 模型可以减少线程的等待，但是数据在用户空间和内核空间拷贝过程中，线程还是阻塞的。线程一阻塞就会让出 CPU，线程闲置下来，就好像工作人员不可能 24 小时不间断地处理客户的请求，解决办法就是增加工作人员的数量，一个人去休息另一个人再顶上。对应到线程池就是增加线程数量，因此 I/O 密集型应用需要设置更多的线程。

**线程 I/O 时间与 CPU 时间**

至此我们又得到一个线程池个数的计算公式，假设服务器是单核的：

**线程池大小 = （线程 I/O 阻塞时间 + 线程 CPU 时间 ）/ 线程 CPU 时间**

其中：线程 I/O 阻塞时间 + 线程 CPU 时间 = 平均请求处理时间

对比一下两个公式，你会发现，**平均请求处理时间**在两个公式里都出现了，这说明请求时间越长，需要更多的线程是毫无疑问的。

不同的是第一个公式是用**每秒请求数**来乘以请求处理时间；而第二个公式用**请求处理时间**来除以**线程 CPU 时间**，请注意 CPU 时间是小于请求处理时间的。

虽然这两个公式是从不同的角度来看待问题的，但都是理想情况，都有一定的前提条件。

1. 请求处理时间越长，需要的线程数越多，但前提是 CPU 核数要足够，如果一个 CPU 来支撑 10000 TPS 并发，创建 10000 个线程，显然不合理，会造成大量线程上下文切换。
2. 请求处理过程中，I/O 等待时间越长，需要的线程数越多，前提是 CUP 时间和 I/O 时间的比率要计算的足够准确。
3. 请求进来的速率越快，需要的线程数越多，前提是 CPU 核数也要跟上。

#### 6.2.3 实际场景下如何确定线程数

那么在实际情况下，线程池的个数如何确定呢？这是一个迭代的过程，先用上面两个公式大概算出理想的线程数，再反复压测调整，从而达到最优。

一般来说，如果系统的 TPS 要求足够大，用第一个公式算出来的线程数往往会比公式二算出来的要大。我建议选取这两个值中间更靠近公式二的值。也就是先设置一个较小的线程数，然后进行压测，当达到系统极限时（错误数增加，或者响应时间大幅增加），再逐步加大线程数，当增加到某个值，再增加线程数也无济于事，甚至 TPS 反而下降，那这个值可以认为是最佳线程数。

线程池中其他的参数，最好就用默认值，能不改就不改，除非在压测的过程发现了瓶颈。如果发现了问题就需要调整，比如 maxQueueSize，如果大量任务来不及处理都堆积在 maxQueueSize 中，会导致内存耗尽，这个时候就需要给 maxQueueSize 设一个限制。当然，这是一个比较极端的情况了。

再比如 minSpareThreads 参数，默认是 25 个线程，如果你发现系统在闲的时候用不到 25 个线程，就可以调小一点；如果系统在大部分时间都比较忙，线程池中的线程总是远远多于 25 个，这个时候你就可以把这个参数调大一点，因为这样线程池就不需要反复地创建和销毁线程了。

### 6.3 Tomcat内存溢出的原因分析及调优

作为 Java 程序员，我们几乎都会碰到 java.lang.OutOfMemoryError 异常，但是你知道有哪些原因可能导致 JVM 抛出 OutOfMemoryError 异常吗？

JVM 在抛出 java.lang.OutOfMemoryError 时，除了会打印出一行描述信息，还会打印堆栈跟踪，因此我们可以通过这些信息来找到导致异常的原因。在寻找原因前，我们先来看看有哪些因素会导致 OutOfMemoryError，其中内存泄漏是导致 OutOfMemoryError 的一个比较常见的原因。

#### 6.3.1 内存溢出场景及方案

**java.lang.OutOfMemoryError: Java heap space**

JVM 无法在堆中分配对象时，会抛出这个异常，导致这个异常的原因可能有三种：

1. 内存泄漏。Java 应用程序一直持有 Java 对象的引用，导致对象无法被 GC 回收，比如对象池和内存池中的对象无法被 GC 回收。
2. 配置问题。有可能是我们通过 JVM 参数指定的堆大小（或者未指定的默认大小），对于应用程序来说是不够的。解决办法是通过 JVM 参数加大堆的大小。
3. finalize 方法的过度使用。如果我们想在 Java 类实例被 GC 之前执行一些逻辑，比如清理对象持有的资源，可以在 Java 类中定义 finalize 方法，这样 JVM GC 不会立即回收这些对象实例，而是将对象实例添加到一个叫“java.lang.ref.Finalizer.ReferenceQueue”的队列中，执行对象的 finalize 方法，之后才会回收这些对象。Finalizer 线程会和主线程竞争 CPU 资源，但由于优先级低，所以处理速度跟不上主线程创建对象的速度，因此 ReferenceQueue 队列中的对象就越来越多，最终会抛出 OutOfMemoryError。解决办法是尽量不要给 Java 类定义 finalize 方法。

**java.lang.OutOfMemoryError: GC overhead limit exceeded**

出现这种 OutOfMemoryError 的原因是，垃圾收集器一直在运行，但是 GC 效率很低，比如 Java 进程花费超过 98％的 CPU 时间来进行一次 GC，但是回收的内存少于 2％的 JVM 堆，并且连续 5 次 GC 都是这种情况，就会抛出 OutOfMemoryError。

解决办法是查看 GC 日志或者生成 Heap Dump，确认一下是不是内存泄漏，如果不是内存泄漏可以考虑增加 Java 堆的大小。当然你还可以通过参数配置来告诉 JVM 无论如何也不要抛出这个异常，方法是配置`-XX:-UseGCOverheadLimit`，但是我并不推荐这么做，因为这只是延迟了 OutOfMemoryError 的出现。

**java.lang.OutOfMemoryError: Requested array size exceeds VM limit**

从错误消息我们也能猜到，抛出这种异常的原因是“请求的数组大小超过 JVM 限制”，应用程序尝试分配一个超大的数组。比如应用程序尝试分配 512MB 的数组，但最大堆大小为 256MB，则将抛出 OutOfMemoryError，并且请求的数组大小超过 VM 限制。

通常这也是一个配置问题（JVM 堆太小），或者是应用程序的一个 Bug，比如程序错误地计算了数组的大小，导致尝试创建一个大小为 1GB 的数组。

**java.lang.OutOfMemoryError: MetaSpace**

如果 JVM 的元空间用尽，则会抛出这个异常。我们知道 JVM 元空间的内存在本地内存中分配，但是它的大小受参数 MaxMetaSpaceSize 的限制。当元空间大小超过 MaxMetaSpaceSize 时，JVM 将抛出带有 MetaSpace 字样的 OutOfMemoryError。解决办法是加大 MaxMetaSpaceSize 参数的值。

**java.lang.OutOfMemoryError: Request size bytes for reason. Out of swap space**

当本地堆内存分配失败或者本地内存快要耗尽时，Java HotSpot VM 代码会抛出这个异常，VM 会触发“致命错误处理机制”，它会生成“致命错误”日志文件，其中包含崩溃时线程、进程和操作系统的有用信息。如果碰到此类型的 OutOfMemoryError，你需要根据 JVM 抛出的错误信息来进行诊断；或者使用操作系统提供的 DTrace 工具来跟踪系统调用，看看是什么样的程序代码在不断地分配本地内存。

**java.lang.OutOfMemoryError: Unable to create native threads**

抛出这个异常的过程大概是这样的：

1. Java 程序向 JVM 请求创建一个新的 Java 线程。
2. JVM 本地代码（Native Code）代理该请求，通过调用操作系统 API 去创建一个操作系统级别的线程 Native Thread。
3. 操作系统尝试创建一个新的 Native Thread，需要同时分配一些内存给该线程，每一个 Native Thread 都有一个线程栈，线程栈的大小由 JVM 参数`-Xss`决定。
4. 由于各种原因，操作系统创建新的线程可能会失败，下面会详细谈到。
5. JVM 抛出“java.lang.OutOfMemoryError: Unable to create new native thread”错误。

因此关键在于第四步线程创建失败，JVM 就会抛出 OutOfMemoryError，那具体有哪些因素会导致线程创建失败呢？

1. 内存大小限制：Java 创建一个线程需要消耗一定的栈空间，并通过`-Xss`参数指定。请你注意的是栈空间如果过小，可能会导致 StackOverflowError，尤其是在递归调用的情况下；但是栈空间过大会占用过多内存，而对于一个 32 位 Java 应用来说，用户进程空间是 4GB，内核占用 1GB，那么用户空间就剩下 3GB，因此它能创建的线程数大致可以通过这个公式算出来：

   ```shell
   Max memory（3GB） = [-Xmx] + [-XX:MaxMetaSpaceSize] + number_of_threads * [-Xss]
   ```

   不过对于 64 位的应用，由于虚拟进程空间近乎无限大，因此不会因为线程栈过大而耗尽虚拟地址空间。但是请你注意，64 位的 Java 进程能分配的最大内存数仍然受物理内存大小的限制。

2. **ulimit 限制**，在 Linux 下执行`ulimit -a`，你会看到 ulimit 对各种资源的限制。

   <img src="http://blog-1259650185.cosbj.myqcloud.com/img/202201/18/1642437164.png" alt="38" style="zoom:50%;" />

   其中的“max user processes”就是一个进程能创建的最大线程数，我们可以修改这个参数：

   ```shell
   ulimit -u 65535
   ```

3. **参数`sys.kernel.threads-max`限制**。这个参数限制操作系统全局的线程数，通过下面的命令可以查看它的值。

   ```shell
   cat /proc/sys/kernel/threads-max
   63752
   ```
   这表明当前系统能创建的总的线程是 63752。当然我们调整这个参数，具体办法是：
   
   在`/etc/sysctl.conf`配置文件中，加入`sys.kernel.threads-max = 999999`。

4. **参数`sys.kernel.pid_max`限制**，这个参数表示系统全局的 PID 号数值的限制，每一个线程都有 ID，ID 的值超过这个数，线程就会创建失败。跟`sys.kernel.threads-max`参数一样，我们也可以将`sys.kernel.pid_max`调大，方法是在`/etc/sysctl.conf`配置文件中，加入`sys.kernel.pid_max = 999999`。


对于线程创建失败的 OutOfMemoryError，除了调整各种参数，我们还需要从程序本身找找原因，看看是否真的需要这么多线程，有可能是程序的 Bug 导致创建过多的线程。

### 6.4 Tomcat拒绝连接原因分析及网络优化

下面我们来看看网络通信中可能会碰到的各种错误。网络通信方面的错误和异常也是我们在实际工作中经常碰到的，需要理解异常背后的原理，才能更快更精准地定位问题，从而找到解决办法。

下面我会先讲讲 Java Socket 网络编程常见的异常有哪些，然后通过一个实验来重现其中的 Connection reset 异常，并且通过配置 Tomcat 的参数来解决这个问题。

#### 6.4.1 常见异常

**java.net.SocketTimeoutException**

指超时错误。超时分为**连接超时**和**读取超时**，连接超时是指在调用 Socket.connect 方法的时候超时，而读取超时是调用 Socket.read 方法时超时。请你注意的是，连接超时往往是由于网络不稳定造成的，但是读取超时不一定是网络延迟造成的，很有可能是下游服务的响应时间过长。

**java.net.BindException: Address already in use: JVM_Bind**

指端口被占用。当服务器端调用 new ServerSocket(port) 或者 Socket.bind 函数时，如果端口已经被占用，就会抛出这个异常。我们可以用`netstat –an`命令来查看端口被谁占用了，换一个没有被占用的端口就能解决。

**java.net.ConnectException: Connection refused: connect**

指连接被拒绝。当客户端调用 new Socket(ip, port) 或者 Socket.connect 函数时，可能会抛出这个异常。原因是指定 IP 地址的机器没有找到；或者是机器存在，但这个机器上没有开启指定的监听端口。

解决办法是从客户端机器 ping 一下服务端 IP，假如 ping 不通，可以看看 IP 是不是写错了；假如能 ping 通，需要确认服务端的服务是不是崩溃了。

**java.net.SocketException: Socket is closed**

指连接已关闭。出现这个异常的原因是通信的一方主动关闭了 Socket 连接（调用了 Socket 的 close 方法），接着又对 Socket 连接进行了读写操作，这时操作系统会报“Socket 连接已关闭”的错误。

**java.net.SocketException: Connection reset/Connect reset by peer: Socket write error**

指连接被重置。这里有两种情况，分别对应两种错误：第一种情况是通信的一方已经将 Socket 关闭，可能是主动关闭或者是因为异常退出，这时如果通信的另一方还在写数据，就会触发这个异常（Connect reset by peer）；如果对方还在尝试从 TCP 连接中读数据，则会抛出 Connection reset 异常。

为了避免这些异常发生，在编写网络通信程序时要确保：

- 程序退出前要主动关闭所有的网络连接。
- 检测通信的另一方的关闭连接操作，当发现另一方关闭连接后自己也要关闭该连接。

**java.net.SocketException: Broken pipe**

指通信管道已坏。发生这个异常的场景是，通信的一方在收到“Connect reset by peer: Socket write error”后，如果再继续写数据则会抛出 Broken pipe 异常，解决方法同上。

**java.net.SocketException: Too many open files**

指进程打开文件句柄数超过限制。当并发用户数比较大时，服务器可能会报这个异常。这是因为每创建一个 Socket 连接就需要一个文件句柄，此外服务端程序在处理请求时可能也需要打开一些文件。

你可以通过`lsof -p pid`命令查看进程打开了哪些文件，是不是有资源泄露，也就是说进程打开的这些文件本应该被关闭，但由于程序的 Bug 而没有被关闭。

如果没有资源泄露，可以通过设置增加最大文件句柄数。具体方法是通过`ulimit -a`来查看系统目前资源限制，通过`ulimit -n 10240`修改最大文件数。

#### 6.4.2 Tomcat 网络参数

接下来我们看看 Tomcat 两个比较关键的参数：maxConnections 和 acceptCount。在解释这个参数之前，先简单回顾下 TCP 连接的建立过程：客户端向服务端发送 SYN 包，服务端回复 SYN＋ACK，同时将这个处于 SYN_RECV 状态的连接保存到**半连接队列**。客户端返回 ACK 包完成三次握手，服务端将 ESTABLISHED 状态的连接移入**accept 队列**，等待应用程序（Tomcat）调用 accept 方法将连接取走。这里涉及两个队列：

- **半连接队列**：保存 SYN_RECV 状态的连接。队列长度由`net.ipv4.tcp_max_syn_backlog`设置。
- **accept 队列**：保存 ESTABLISHED 状态的连接。队列长度为`min(net.core.somaxconn，backlog)`。其中 backlog 是我们创建 ServerSocket 时指定的参数，最终会传递给 listen 方法：

```
int listen(int sockfd, int backlog);
```

如果我们设置的 backlog 大于`net.core.somaxconn`，accept 队列的长度将被设置为`net.core.somaxconn`，而这个 backlog 参数就是 Tomcat 中的**acceptCount**参数，默认值是 100，但请注意`net.core.somaxconn`的默认值是 128。你可以想象在高并发情况下当 Tomcat 来不及处理新的连接时，这些连接都被堆积在 accept 队列中，而**acceptCount**参数可以控制 accept 队列的长度，超过这个长度时，内核会向客户端发送 RST，这样客户端会触发上文提到的“Connection reset”异常。

而 Tomcat 中的**maxConnections**是指 Tomcat 在任意时刻接收和处理的最大连接数。当 Tomcat 接收的连接数达到 maxConnections 时，Acceptor 线程不会再从 accept 队列中取走连接，这时 accept 队列中的连接会越积越多。

maxConnections 的默认值与连接器类型有关：NIO 的默认值是 10000，APR 默认是 8192。

所以你会发现 Tomcat 的最大并发连接数等于**maxConnections + acceptCount**。如果 acceptCount 设置得过大，请求等待时间会比较长；如果 acceptCount 设置过小，高并发情况下，客户端会立即触发 Connection reset 异常。

acceptCount 用来控制内核的 TCP 连接队列长度，maxConnections 用于控制 Tomcat 层面的最大连接数，就是说，在 Tomcat 达到 maxConnections 的最大连接数后，操作系统层面还可以接收 acceptCount 个连接。

### 6.5 Tomcat进程占用CPU过高怎么办？

接下来我们看一下 CPU 的问题。CPU 资源经常会成为系统性能的一个瓶颈，这其中的原因是多方面的，可能是内存泄露导致频繁 GC，进而引起 CPU 使用率过高；又可能是代码中的 Bug 创建了大量的线程，导致 CPU 上下文切换开销。

#### 6.5.1 “Java 进程 CPU 使用率高”的解决思路是什么？

通常我们所说的 CPU 使用率过高，这里面其实隐含着一个用来比较高与低的基准值，比如 JVM 在峰值负载下的平均 CPU 利用率为 40％，如果 CPU 使用率飙到 80% 就可以被认为是不正常的。

典型的 JVM 进程包含多个 Java 线程，其中一些在等待工作，另一些则正在执行任务。在单个 Java 程序的情况下，线程数可以非常低，而对于处理大量并发事务的互联网后台来说，线程数可能会比较高。

对于 CPU 的问题，最重要的是要找到是**哪些线程在消耗 CPU**，通过线程栈定位到问题代码；如果没有找到个别线程的 CPU 使用率特别高，我们要怀疑到是不是线程上下文切换导致了 CPU 使用率过高。下面我们通过一个实例来学习 CPU 问题定位的过程。

#### 6.5.2 定位高 CPU 使用率的线程和代码

1. 写一个模拟程序来模拟 CPU 使用率过高的问题，这个程序会在线程池中创建 4096 个线程。代码如下：

```java
@SpringBootApplication
@EnableScheduling
public class DemoApplication {
 
   // 创建线程池，其中有 4096 个线程。
   private ExecutorService executor = Executors.newFixedThreadPool(4096);
   // 全局变量，访问它需要加锁。
   private int count;
   
   // 以固定的速率向线程池中加入任务
   @Scheduled(fixedRate = 10)
   public void lockContention() {
      IntStream.range(0, 1000000)
            .forEach(i -> executor.submit(this::incrementSync));
   }
   
   // 具体任务，就是将 count 数加一
   private synchronized void incrementSync() {
      count = (count + 1) % 10000000;
   }
   
   public static void main(String[] args) {
      SpringApplication.run(DemoApplication.class, args);
   }
 
}
```

2. 在 Linux 环境下启动程序：

```shell
java -Xss256k -jar demo-0.0.1-SNAPSHOT.jar
```

请注意，这里我将线程栈大小指定为 256KB。对于测试程序来说，操作系统默认值 8192KB 过大，因为我们需要创建 4096 个线程。

3. 使用 top 命令，我们看到 Java 进程的 CPU 使用率达到了 262.3%，注意到进程 ID 是 4361。

<img src="http://blog-1259650185.cosbj.myqcloud.com/img/202201/18/1642492913.png" alt="39" style="zoom:50%;" />

4. 接着我们用更精细化的 top 命令查看这个 Java 进程中各线程使用 CPU 的情况：

```shell
top -H -p 4361
```

<img src="http://blog-1259650185.cosbj.myqcloud.com/img/202201/18/1642492969.png" alt="40" style="zoom:50%;" />

从图上我们可以看到，有个叫“scheduling-1”的线程占用了较多的 CPU，达到了 42.5%。因此下一步我们要找出这个线程在做什么事情。

5. 为了找出线程在做什么事情，我们需要用 jstack 命令生成线程快照，具体方法是：

```shell
jstack 4361
```

jstack 的输出比较大，你可以将输出写入文件：

```shell
jstack 4361 > 4361.log
```

然后我们打开 4361.log，定位到第 4 步中找到的名为“scheduling-1”的线程，发现它的线程栈如下：

<img src="http://blog-1259650185.cosbj.myqcloud.com/img/202201/18/1642493121.png" alt="41" style="zoom:50%;" />

从线程栈中我们看到了`AbstractExecutorService.submit`这个函数调用，说明它是 Spring Boot 启动的周期性任务线程，向线程池中提交任务，这个线程消耗了大量 CPU。

#### 6.5.3 进一步分析上下文切换开销

一般来说，通过上面的过程，我们就能定位到大量消耗 CPU 的线程以及有问题的代码，比如死循环。但是对于这个实例的问题，你是否发现这样一个情况：Java 进程占用的 CPU 是 262.3%， 而“scheduling-1”线程只占用了 42.5% 的 CPU，那还有将近 220% 的 CPU 被谁占用了呢？

不知道你注意到没有，我们在第 4 步用`top -H -p 4361`命令看到的线程列表中还有许多名为“pool-1-thread-x”的线程，它们单个的 CPU 使用率不高，但是似乎数量比较多。你可能已经猜到，这些就是线程池中干活的线程。那剩下的 220% 的 CPU 是不是被这些线程消耗了呢？

要弄清楚这个问题，我们还需要看 jstack 的输出结果，主要是看这些线程池中的线程是不是真的在干活，还是在“休息”呢？

<img src="http://blog-1259650185.cosbj.myqcloud.com/img/202201/18/1642493361.png" alt="42" style="zoom:50%;" />

通过上面的图我们发现这些“pool-1-thread-x”线程基本都处于 WAITING 的状态，那什么是 WAITING 状态呢？或者说 Java 线程都有哪些状态呢？你可以通过下面的图来理解一下：

<img src="http://blog-1259650185.cosbj.myqcloud.com/img/202201/18/1642493387.png" alt="43" style="zoom: 67%;" />

从图上我们看到“Blocking”和“Waiting”是两个不同的状态，我们要注意它们的区别：

- Blocking 指的是一个线程因为等待临界区的锁（Lock 或者 synchronized 关键字）而被阻塞的状态，请你注意的是处于这个状态的线程**还没有拿到锁。**
- Waiting 指的是一个线程拿到了锁，但是需要等待其他线程执行某些操作。比如调用了 Object.wait、Thread.join 或者 LockSupport.park 方法时，进入 Waiting 状态。**前提是这个线程已经拿到锁了**，并且在进入 Waiting 状态前，操作系统层面会自动释放锁，当等待条件满足，外部调用了 Object.notify 或者 LockSupport.unpark 方法，线程会重新竞争锁，成功获得锁后才能进入到 Runnable 状态继续执行。

回到我们的“pool-1-thread-x”线程，这些线程都处在“Waiting”状态，从线程栈我们看到，这些线程“等待”在 getTask 方法调用上，线程尝试从线程池的队列中取任务，但是队列为空，所以通过 LockSupport.park 调用进到了“Waiting”状态。那“pool-1-thread-x”线程有多少个呢？通过下面这个命令来统计一下，结果是 4096，正好跟线程池中的线程数相等。

```shell
grep -o 'pool-1-thread' 4361.log | wc -l
```

你可能好奇了，那剩下的 220% 的 CPU 到底被谁消耗了呢？分析到这里，我们应该怀疑 CPU 的上下文切换开销了，因为我们看到 Java 进程中的线程数比较多。下面我们通过 vmstat 命令来查看一下操作系统层面的线程上下文切换活动：

<img src="http://blog-1259650185.cosbj.myqcloud.com/img/202201/18/1642494254.png" alt="44" style="zoom:50%;" />

如果你还不太熟悉 vmstat，可以在[这里](https://linux.die.net/man/8/vmstat)学习如何使用 vmstat 和查看结果。其中 cs 那一栏表示线程上下文切换次数，in 表示 CPU 中断次数，我们发现这两个数字非常高，基本证实了我们的猜测，线程上下文切切换消耗了大量 CPU。那么问题来了，具体是哪个进程导致的呢？

我们停止 Spring Boot 测试程序，再次运行 vmstat 命令，会看到 in 和 cs 都大幅下降了，这样就证实了引起线程上下文切换开销的 Java 进程正是 4361。

<img src="http://blog-1259650185.cosbj.myqcloud.com/img/202201/18/1642494757.png" alt="45" style="zoom: 67%;" />

## 参考

[深入拆解 Tomcat & Jetty](https://time.geekbang.org/column/intro/100027701)

