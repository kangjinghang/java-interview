# 总述

netty在服务端端口绑定和新连接建立的过程中会建立相应的channel，而与channel的动作密切相关的是pipeline这个概念，pipeline像是可以看作是一条流水线，原始的原料(字节流)进来，经过加工，最后输出。

Netty定义了两种事件类型：入站（inbound）事件和出站（outbound）事件。ChannelPipeline使用拦截过滤器模式使用户可以掌控ChannelHandler处理事件的流程。注意：**事件在ChannelPipeline中不自动流动**而需要调用ChannelHandlerContext中诸如fireXXX()或者read()类似的方法将事件从一个ChannelHandler传播到下一个ChannelHandler。
事实上，ChannelHandler不处理具体的事件，处理具体的事件由相应的子类完成：ChannelInboundHandler处理和拦截入站事件，ChannelOutboundHandler处理和拦截出站事件。

入站事件一般由**I/O线程**触发，以下事件为入站事件：

```java
ChannelRegistered() // Channel注册到EventLoop
ChannelActive()     // Channel激活
ChannelRead(Object) // Channel读取到数据
ChannelReadComplete()   // Channel读取数据完毕
ExceptionCaught(Throwable)  // 捕获到异常
UserEventTriggered(Object)  // 用户自定义事件
ChannelWritabilityChanged() // Channnel可写性改变，由写高低水位控制
ChannelInactive()   // Channel不再激活
ChannelUnregistered()   // Channel从EventLoop中注销
```

出站事件一般由**用户**触发，以下事件为出站事件：

```java
bind(SocketAddress, ChannelPromise) // 绑定到本地地址
connect(SocketAddress, SocketAddress, ChannelPromise)   // 连接一个远端机器
write(Object, ChannelPromise)   // 写数据，实际只加到Netty出站缓冲区
flush() // flush数据，实际执行底层写
read()  // 读数据，实际设置关心OP_READ事件，当数据到来时触发ChannelRead入站事件
disconnect(ChannelPromise)  // 断开连接，NIO Server和Client不支持，实际调用close
close(ChannelPromise)   // 关闭Channel
deregister(ChannelPromise)  // 从EventLoop注销Channel
```

入站事件一般由I/O线程触发，用户程序员也可根据实际情况触发。考虑这样一种情况：一个协议由头部和数据部分组成，其中头部含有数据长度，由于数据量较大，客户端分多次发送该协议的数据，服务端接收到数据后需要收集足够的数据，组装为更有意义的数据传给下一个ChannelInboudHandler。也许你已经知道，这个收集数据的ChannelInboundHandler正是Netty中基本的Encoder，Encoder中会处理多次ChannelRead()事件，只触发一次对下一个ChannelInboundHandler更有意义的ChannelRead()事件。

出站事件一般由用户触发，而I/O线程也可能会触发。比如，**当用户已配置ChannelOption.AutoRead选项，则I/O在执行完ChannelReadComplete()事件，会调用read()方法继续关心OP_READ事件，保证数据到达时自动触发ChannelRead()事件**。

如果你初次接触Netty，会对下面的方法感到疑惑，所以列出区别：

```java
channelHandlerContext.close()   // close事件传播到下一个Handler
channel.close()                 // ==channelPipeline.close()
channelPipeline.close()         // 事件沿整个ChannelPipeline传播，注意in/outboud的传播起点
```

本文，我将以新连接的建立为例，分为以下几个部分介绍netty中的pipeline是怎么玩转起来的

- pipeline 初始化
- pipeline 添加节点
- pipeline 删除节点

# pipeline主流程

## pipeline 初始化

在新连接的建立这篇文章中，我们已经知道了创建`NioSocketChannel`的时候会将netty的核心组件创建出来。

<img src="http://blog-1259650185.cosbj.myqcloud.com/img/202111/30/1638266029.jpg" alt="1357217-7c30f04e2e77bc71" style="zoom:67%;" />

pipeline是其中的一员，在下面这段代码中被创建：

```java
// AbstractChannel.java
protected AbstractChannel(Channel parent) {
    this.parent = parent;
    // new出来三大组件（id，unsafe，pipeline），赋值到成员变量
    id = newId(); // 每条channel的唯一标识
    unsafe = newUnsafe();
    pipeline = newChannelPipeline();
}

protected DefaultChannelPipeline newChannelPipeline() {
    return new DefaultChannelPipeline(this);
}

// DefaultChannelPipeline.java
protected DefaultChannelPipeline(Channel channel) {
    this.channel = ObjectUtil.checkNotNull(channel, "channel");
    succeededFuture = new SucceededChannelFuture(channel, null);
    voidPromise =  new VoidChannelPromise(channel, true);

    tail = new TailContext(this);
    head = new HeadContext(this);

    head.next = tail;
    tail.prev = head;
}
```

可见，新建一个Channel时会自动新建一个ChannelPipeline，也就是说他们之间是一对一的关系。另外需要注意的是：ChannelPipeline是**线程安全**的，也就是说，我们可以动态的添加、删除其中的ChannelHandler。考虑这样的场景：服务器需要对用户登录信息进行加密，而其他信息不加密，则可以首先将加密Handler添加到ChannelPipeline，验证完用户信息后，主动从ChnanelPipeline中删除，从而实现该需求。

pipeline中保存了channel的引用，创建完pipeline之后，整个pipeline是这个样子的：

<img src="http://blog-1259650185.cosbj.myqcloud.com/img/202111/30/1638276080.jpg" alt="pipeline默认结构"  />

pipeline中的每个节点是一个`ChannelHandlerContext`对象，每个context节点保存了它包裹的执行器 `ChannelHandler` 执行操作所需要的上下文，其实就是pipeline，因为pipeline包含了channel的引用，可以拿到所有的context信息。

每个 Channel 内部都有这样一个 pipeline，handler 之间的顺序是很重要的，因为 IO 事件将按照顺序顺次经过 pipeline 上的 handler，这样每个 handler 可以专注于做一点点小事，由多个 handler 组合来完成一些复杂的逻辑。

默认情况下，一条pipeline会有两个节点，head和tail，后面的文章我们具体分析这两个特殊的节点，今天我们重点放在pipeline。

#### ChannelHandler

ChannelHandler并没有方法处理事件，而需要由子类处理：ChannelInboundHandler拦截和处理入站事件，ChannelOutboundHandler拦截和处理出站事件。我们已经明白，ChannelPipeline中的事件不会自动流动，而我们一般需求事件自动流动，Netty提供了两个Adapter：ChannelInboundHandlerAdapter和ChannelOutboundHandlerAdapter来满足这种需求。其中的实现类似如下：

```java
// inboud事件默认处理过程
public void channelRegistered(ChannelHandlerContext ctx) throws Exception {
    ctx.fireChannelRegistered();    // 事件传播到下一个Handler
}

// outboud事件默认处理过程
public void bind(ChannelHandlerContext ctx, SocketAddress localAddress,
        ChannelPromise promise) throws Exception {
    ctx.bind(localAddress, promise);  // 事件传播到下一个Handler
}
```

在Adapter中，事件默认自动传播到下一个Handler，这样带来的另一个好处是：用户的Handler类可以继承Adapter且覆盖自己感兴趣的事件实现，其他事件使用默认实现，不用再实现ChannelIn/outboudHandler接口中所有方法，提高效率。

我们常常遇到这样的需求：在一个业务逻辑处理器中，需要写数据库、进行网络连接等耗时业务。Netty的原则是不阻塞I/O线程，所以需指定Handler执行的线程池，可使用如下代码：

```java
static final EventExecutorGroup group = new DefaultEventExecutorGroup(16);
...
ChannelPipeline pipeline = ch.pipeline();
// 简单非阻塞业务，可以使用I/O线程执行
pipeline.addLast("decoder", new MyProtocolDecoder());
pipeline.addLast("encoder", new MyProtocolEncoder());
// 复杂耗时业务，使用新的线程池
pipeline.addLast(group, "handler", new MyBusinessLogicHandler());
```

ChannelHandler中有一个Sharable注解，使用该注解后多个ChannelPipeline中的Handler对象实例只有一个，从而减少Handler对象实例的创建。代码示例如下：

```java
public class DataServerInitializer extends ChannelInitializer<Channel> {
   private static final DataServerHandler SHARED = new DataServerHandler();

   @Override
   public void initChannel(Channel channel) {
       channel.pipeline().addLast("handler", SHARED);
   }
}
```

Sharable注解的使用是有限制的，多个ChannelPipeline只有一个实例，所以该Handler要求**无状态**。上述示例中，DataServerHandler的事件处理方法中，不能使用或改变本身的私有变量，因为ChannelHandler是**非线程安全**的，使用私有变量会造成线程竞争而产生错误结果。

#### ChannelHandlerContext

Context指上下文关系，ChannelHandler的Context指的是ChannleHandler之间的关系以及ChannelHandler与ChannelPipeline之间的关系。ChannelPipeline中的事件传播主要依赖于ChannelHandlerContext实现，由于ChannelHandlerContext中有ChannelHandler之间的关系，所以能得到ChannelHandler的后继节点，从而将事件传播到下一个ChannelHandler。

ChannelHandlerContext继承自AttributeMap，所以提供了attr()方法设置和删除一些状态属性值，用户可将业务逻辑中所需使用的状态属性值存入到Context中。此外，Channel也继承自AttributeMap，也有attr()方法，在Netty4.0中，这两个attr()方法并不等效，这会给用户程序员带来困惑并且增加内存开销，所以Netty4.1中将channel.attr()==ctx.attr()。在使用Netty4.0时，建议只使用channel.attr()防止引起不必要的困惑。

#### ChannelPipeline源码实现

首先看ChannelPipeline接口的关键方法，相似方法只列出一个：

```java
ChannelPipeline addLast(String name, ChannelHandler handler);
ChannelPipeline remove(ChannelHandler handler);
ChannelHandler first();
ChannelHandlerContext firstContext();
ChannelHandler get(String name);
ChannelHandlerContext context(ChannelHandler handler);
Channel channel();
ChannelPipeline fireChannelRegistered();
ChannelFuture bind(SocketAddress localAddress);
```

DefaultChannelPipeline是ChannelPipeline的一个子类，回忆ChannelHandler的事件处理顺序，与双向链表的正向遍历和反向遍历顺序相同，可推知DefaultChannelPipeline使用了双向链表。事实上如此，所不同的是：链表中的节点并不是ChannelHandler而是ChannelHandlerContext。明白了这些，先看其中的字段：

```java
final AbstractChannelHandlerContext head;   // 双向链表头
final AbstractChannelHandlerContext tail;   // 双向链表尾
private final Channel channel;  // 对应Channel
// 线程池中的线程映射，记住这个映射是为了保证执行任务时使用同一个线程
private Map<EventExecutorGroup, EventExecutor> childExecutors;
private MessageSizeEstimator.Handle estimatorHandle;    // 消息大小估算器，内部没有使用
private boolean firstRegistration = true;   // 对应Channel首次注册到EventLoop
// ChannelHandler添加任务队列链表头部
private PendingHandlerCallback pendingHandlerCallbackHead;
// 注册到EventLoop标记，该值一旦设置为true后不再改变
private boolean registered; 
```

此外还需要注意一个static字段：

```java
private static final FastThreadLocal<Map<Class<?>, String>> nameCaches =
     initialValue() -> {  return new WeakHashMap<Class<?>, String>(); };
```

这是一个Netty内部定义的FastThreadLocal变量，以后会分析它的实现，现在先了解这样的事实：nameCaches是一个线程本地（局部）变量，也就是说每个线程都存有一份该变量，该变量是一个WeakHashMap，其中存放的是ChannelHandler的Class与字符串名称的映射关系。简单说就是每个线程都有一份Handler的Class与字符串名称的映射关系，之所以这样是为了避免使用复杂的CurrentHashMap也能实现并发安全。

## pipeline添加节点

下面是一段非常常见的客户端代码：

```java
// 用户代码
bootstrap.childHandler(new ChannelInitializer<SocketChannel>() {
     @Override
     public void initChannel(SocketChannel ch) throws Exception {
         ChannelPipeline p = ch.pipeline();
         p.addLast(new Spliter())
         p.addLast(new Decoder());
         p.addLast(new BusinessHandler())
         p.addLast(new Encoder());
     }
});
```

首先，用一个spliter将来源TCP数据包拆包，然后将拆出来的包进行decoder，传入业务处理器BusinessHandler，业务处理完encoder，输出。

整个pipeline结构如下：

<img src="http://blog-1259650185.cosbj.myqcloud.com/img/202111/30/1638277523.jpg" alt="pipeline结构" style="zoom:67%;" />

我用两种颜色区分了一下pipeline中两种不同类型的节点，一个是 `ChannelInboundHandler`，处理inBound事件，最典型的就是读取数据流，加工处理；还有一种类型的Handler是 `ChannelOutboundHandler`, 处理outBound事件，比如当调用`writeAndFlush()`类方法时，就会经过该种类型的handler。

不管是哪种类型的handler，其外层对象 `ChannelHandlerContext` 之间都是通过双向链表连接，而区分一个 `ChannelHandlerContext`到底是in还是out，在添加节点的时候我们就可以看到netty是怎么处理的。

```java
// DefaultChannelPipeline.java
public final ChannelPipeline addLast(ChannelHandler handler) {
    return addLast(null, handler);
}

@Override
public final ChannelPipeline addLast(String name, ChannelHandler handler) {
    return addLast(null, name, handler);
}

@Override
public final ChannelPipeline addLast(EventExecutorGroup group, String name, ChannelHandler handler) {
    final AbstractChannelHandlerContext newCtx;
    synchronized (this) {
      	// 1.检查是否有重复handler
        checkMultiplicity(handler);
				// 2.创建节点
        newCtx = newContext(group, filterName(name, handler), handler);
				// 3.添加节点
        addLast0(newCtx);

        if (!registered) {
          	// 此时Channel还没注册的EventLoop中，而Netty的原则是事件在同一个EventLoop执行，所以新增一个任务用于注册后添加
            newCtx.setAddPending();
            callHandlerCallbackLater(newCtx, true);
            return this;
        }

        EventExecutor executor = newCtx.executor();
        if (!executor.inEventLoop()) {
          	// 当前线程不是EventLoop线程
            callHandlerAddedInEventLoop(newCtx, executor);
            return this;
        }
    }
    callHandlerAdded0(newCtx);// 4.回调用户方法
    return this;
}
```

这里简单地用`synchronized`方法是为了防止多线程并发操作pipeline底层的双向链表。

我们还是逐步分析上面这段代码。

### 1. 检查是否有重复handler

在用户代码添加一条handler的时候，首先会查看该handler有没有添加过。

```java
// DefaultChannelPipeline.java
private static void checkMultiplicity(ChannelHandler handler) {
    if (handler instanceof ChannelHandlerAdapter) {
        ChannelHandlerAdapter h = (ChannelHandlerAdapter) handler;
        if (!h.isSharable() && h.added) {
            throw new ChannelPipelineException(
                    h.getClass().getName() +
                    " is not a @Sharable handler, so can't be added or removed multiple times.");
        }
        h.added = true;
    }
}
```

netty使用一个成员变量`added`标识一个channel是否已经添加，上面这段代码很简单，如果当前要添加的Handler是非共享的，并且已经添加过，那就抛出异常，否则，标识该handler已经添加。

由此可见，一个Handler如果是sharable的，就可以无限次被添加到pipeline中，我们客户端代码如果要让一个Handler被共用，只需要加一个@Sharable标注即可，如下：

```java
@Sharable
public class BusinessHandler {
    
}
```

而如果Handler是sharable的，一般就通过spring的注入的方式使用，不需要每次都new 一个。

`isSharable()` 方法正是通过该Handler对应的类是否标注@Sharable来实现的。

```java
// ChannelHandlerAdapter.java
public boolean isSharable() {
   Class<?> clazz = getClass();
    Map<Class<?>, Boolean> cache = InternalThreadLocalMap.get().handlerSharableCache();
    Boolean sharable = cache.get(clazz);
    if (sharable == null) {
        sharable = clazz.isAnnotationPresent(Sharable.class);
        cache.put(clazz, sharable);
    }
    return sharable;
}
```

这里也可以看到，netty为了性能优化到极致，还使用了ThreadLocal来缓存Handler的状态，高并发海量连接下，每次有新连接添加Handler都会创建调用此方法。

### 2. 创建节点

回到主流程，看创建上下文这段代码。

```java
// ChannelHandlerAdapter.java
newCtx = newContext(group, filterName(name, handler), handler);
```

这里我们需要先分析 `filterName(name, handler)` 这段代码，这个函数用于给handler创建一个唯一性的名字。

```java
// ChannelHandlerAdapter.java
private String filterName(String name, ChannelHandler handler) {
    if (name == null) {
        return generateName(handler);
    }
    checkDuplicateName(name);
    return name;
}
```

显然，我们传入的name为null，netty就给我们生成一个默认的name，否则，检查是否有重名，检查通过的话就返回。

netty创建默认name的规则为 `简单类名#0`，下面我们来看些具体是怎么实现的。

```java
// ChannelHandlerAdapter.java
private static final FastThreadLocal<Map<Class<?>, String>> nameCaches =
        new FastThreadLocal<Map<Class<?>, String>>() {
    @Override
    protected Map<Class<?>, String> initialValue() throws Exception {
        return new WeakHashMap<Class<?>, String>();
    }
};

private String generateName(ChannelHandler handler) {
    // 先查看缓存中是否有生成过默认name
    Map<Class<?>, String> cache = nameCaches.get();
    Class<?> handlerType = handler.getClass();
    String name = cache.get(handlerType);
    // 没有生成过，就生成一个默认name，加入缓存 
    if (name == null) {
        name = generateName0(handlerType);
        cache.put(handlerType, name);
    }

    // 生成完了，还要看默认name有没有冲突
    if (context0(name) != null) {
        String baseName = name.substring(0, name.length() - 1);
        for (int i = 1;; i ++) {
            String newName = baseName + i;
            if (context0(newName) == null) {
                name = newName;
                break;
            }
        }
    }
    return name;
}
```

netty使用一个 `FastThreadLocal`变量来缓存Handler的类和默认名称的映射关系，在生成name的时候，首先查看缓存中有没有生成过默认name(`简单类名#0`)，如果没有生成，就调用`generateName0()`生成默认name，然后加入缓存。

接下来还需要检查name是否和已有的name有冲突，调用`context0()`，查找pipeline里面有没有对应的context。

```java
// ChannelHandlerAdapter.java
private AbstractChannelHandlerContext context0(String name) {
    AbstractChannelHandlerContext context = head.next;
    while (context != tail) {
        if (context.name().equals(name)) {
            return context;
        }
        context = context.next;
    }
    return null;
}
```

`context0()`方法链表遍历每一个 `ChannelHandlerContext`，只要发现某个context的名字与待添加的name相同，就返回该context，最后抛出异常，可以看到，这个其实是一个线性搜索的过程。

如果`context0(name) != null` 成立，说明现有的context里面已经有了一个默认name，那么就从 `简单类名#1` 往上一直找，直到找到一个唯一的name，比如`简单类名#3`。

如果用户代码在添加Handler的时候指定了一个name，那么要做到事仅仅为检查一下是否有重复。

```java
// ChannelHandlerAdapter.java
private void checkDuplicateName(String name) {
    if (context0(name) != null) {
        throw new IllegalArgumentException("Duplicate handler name: " + name);
    }
}
```

处理完name之后，就进入到创建context的过程，由前面的调用链得知，`group`为null，因此`childExecutor(group)`也返回null。

```java
// ChannelHandlerAdapter.java
private AbstractChannelHandlerContext newContext(EventExecutorGroup group, String name, ChannelHandler handler) {
    return new DefaultChannelHandlerContext(this, childExecutor(group), name, handler);
}

private EventExecutor childExecutor(EventExecutorGroup group) {
    if (group == null) {
        return null;
    }
    ...
}

// DefaultChannelHandlerContext.java
DefaultChannelHandlerContext(
        DefaultChannelPipeline pipeline, EventExecutor executor, String name, ChannelHandler handler) {
    super(pipeline, executor, name, handler.getClass());
    this.handler = handler;
}
```

构造函数中，`DefaultChannelHandlerContext`将参数回传到父类，保存Handler的引用，进入到其父类。

```java
// AbstractChannelHandlerContext.java
AbstractChannelHandlerContext(DefaultChannelPipeline pipeline, EventExecutor executor,
                              String name, Class<? extends ChannelHandler> handlerClass) {
    this.name = ObjectUtil.checkNotNull(name, "name");
    this.pipeline = pipeline;
    this.executor = executor;
    this.executionMask = mask(handlerClass);  // 调用ChannelHandlerMask#mask()，得到context关联的handler对象支持回调的事件类型
    // Its ordered if its driven by the EventLoop or the given Executor is an instanceof OrderedEventExecutor.
    ordered = executor == null || executor instanceof OrderedEventExecutor;
}
// ChannelHandlerMask
static int mask(Class<? extends ChannelHandler> clazz) {
    Map<Class<? extends ChannelHandler>, Integer> cache = MASKS.get();
    Integer mask = cache.get(clazz);
    if (mask == null) {
        mask = mask0(clazz);
        cache.put(clazz, mask);
    }
    return mask;
}
```

netty中用`executionMask`字段来表示支持的回调事件，详细代码如下：

```java
// ChannelHandlerMask.java
final class ChannelHandlerMask {
    private static final InternalLogger logger = InternalLoggerFactory.getInstance(ChannelHandlerMask.class);

    // 定义了很多常量，每个常量表示支持一种回调的事件类型（比如handlerAdded、handlerRemoved等）
    static final int MASK_EXCEPTION_CAUGHT = 1; // 1    0001
    static final int MASK_CHANNEL_REGISTERED = 1 << 1; // 2    0010(左移1位)
    static final int MASK_CHANNEL_UNREGISTERED = 1 << 2; // 4    0100(左移2位)
    static final int MASK_CHANNEL_ACTIVE = 1 << 3; // 8    1000(左移3位)
    static final int MASK_CHANNEL_INACTIVE = 1 << 4; // 16
    static final int MASK_CHANNEL_READ = 1 << 5; // 32
    static final int MASK_CHANNEL_READ_COMPLETE = 1 << 6; // 64
    static final int MASK_USER_EVENT_TRIGGERED = 1 << 7; // 128
    static final int MASK_CHANNEL_WRITABILITY_CHANGED = 1 << 8; // 256
    static final int MASK_BIND = 1 << 9; // 512
    static final int MASK_CONNECT = 1 << 10; // 1024
    static final int MASK_DISCONNECT = 1 << 11; // 2048
    static final int MASK_CLOSE = 1 << 12; // 4096
    static final int MASK_DEREGISTER = 1 << 13; // 8192
    static final int MASK_READ = 1 << 14; // 16384
    static final int MASK_WRITE = 1 << 15; // 32768   1000 0000 0000 0000  (左移15位)
    static final int MASK_FLUSH = 1 << 16; //65536   1 0000 0000 0000 0000 (左移16位)

    static final int MASK_ONLY_INBOUND =  MASK_CHANNEL_REGISTERED |
            MASK_CHANNEL_UNREGISTERED | MASK_CHANNEL_ACTIVE | MASK_CHANNEL_INACTIVE | MASK_CHANNEL_READ |
            MASK_CHANNEL_READ_COMPLETE | MASK_USER_EVENT_TRIGGERED | MASK_CHANNEL_WRITABILITY_CHANGED; // 入站inBound事件
    private static final int MASK_ALL_INBOUND = MASK_EXCEPTION_CAUGHT | MASK_ONLY_INBOUND; // 支持的所有入站inBound回调的mask
    static final int MASK_ONLY_OUTBOUND =  MASK_BIND | MASK_CONNECT | MASK_DISCONNECT |
            MASK_CLOSE | MASK_DEREGISTER | MASK_READ | MASK_WRITE | MASK_FLUSH; // 出站outBound事件
    private static final int MASK_ALL_OUTBOUND = MASK_EXCEPTION_CAUGHT | MASK_ONLY_OUTBOUND; // 支持的所有出站outBound回调的mask

    // 维护着每个handler的Class对象对应的executeMask值，根据一个handler获取其mask值，从而知道其支持的事件类型，并间接的知道这个handler属于inbound handler还是属于outbound handler
    private static final FastThreadLocal<Map<Class<? extends ChannelHandler>, Integer>> MASKS =
            new FastThreadLocal<Map<Class<? extends ChannelHandler>, Integer>>() {
                @Override
                protected Map<Class<? extends ChannelHandler>, Integer> initialValue() {
                    return new WeakHashMap<Class<? extends ChannelHandler>, Integer>(32);
                }
            };

    static int mask(Class<? extends ChannelHandler> clazz) {
        // Try to obtain the mask from the cache first. If this fails calculate it and put it in the cache for fast
        // lookup in the future.
        Map<Class<? extends ChannelHandler>, Integer> cache = MASKS.get();
        Integer mask = cache.get(clazz);
        if (mask == null) {
            mask = mask0(clazz);
            cache.put(clazz, mask);
        }
        return mask;
    }

    /**
     * Calculate the {@code executionMask}. 计算支持的回调事件
     */
    private static int mask0(Class<? extends ChannelHandler> handlerType) {
        int mask = MASK_EXCEPTION_CAUGHT;
        try {
            if (ChannelInboundHandler.class.isAssignableFrom(handlerType)) {
                mask |= MASK_ALL_INBOUND; // 所有的in事件
                // 如果该 Handler 的 xx 方法标注了 @Skip 注解，则将他剔除
                if (isSkippable(handlerType, "channelRegistered", ChannelHandlerContext.class)) {
                    mask &= ~MASK_CHANNEL_REGISTERED; // 排除REGISTERED ，非:把1变成0  0变成1，先把自己的值取反（把1变成0 0变成1），然后和mask取并（11得1），这样原本的位置由1变成了0
                } // mask &= ~MASK_CHANNEL_REGISTERED，反向推，怎么把mask中对应MASK_CHANNEL_REGISTERED中1的位置变成0，就先取反，把1的位置变0，然后取并，这样mask中原来是1的位置就被处理成0了，达成目的
                if (isSkippable(handlerType, "channelUnregistered", ChannelHandlerContext.class)) {
                    mask &= ~MASK_CHANNEL_UNREGISTERED; // 排除UNREGISTERED
                }
                if (isSkippable(handlerType, "channelActive", ChannelHandlerContext.class)) {
                    mask &= ~MASK_CHANNEL_ACTIVE;
                }
                if (isSkippable(handlerType, "channelInactive", ChannelHandlerContext.class)) {
                    mask &= ~MASK_CHANNEL_INACTIVE;
                }
                if (isSkippable(handlerType, "channelRead", ChannelHandlerContext.class, Object.class)) {
                    mask &= ~MASK_CHANNEL_READ;
                }
                if (isSkippable(handlerType, "channelReadComplete", ChannelHandlerContext.class)) {
                    mask &= ~MASK_CHANNEL_READ_COMPLETE;
                }
                if (isSkippable(handlerType, "channelWritabilityChanged", ChannelHandlerContext.class)) {
                    mask &= ~MASK_CHANNEL_WRITABILITY_CHANGED;
                }
                if (isSkippable(handlerType, "userEventTriggered", ChannelHandlerContext.class, Object.class)) {
                    mask &= ~MASK_USER_EVENT_TRIGGERED;
                }
            }

            if (ChannelOutboundHandler.class.isAssignableFrom(handlerType)) {
                mask |= MASK_ALL_OUTBOUND; // 所有的out事件

                if (isSkippable(handlerType, "bind", ChannelHandlerContext.class,
                        SocketAddress.class, ChannelPromise.class)) {
                    mask &= ~MASK_BIND; // 排除bind
                }
                if (isSkippable(handlerType, "connect", ChannelHandlerContext.class, SocketAddress.class,
                        SocketAddress.class, ChannelPromise.class)) {
                    mask &= ~MASK_CONNECT;
                }
                if (isSkippable(handlerType, "disconnect", ChannelHandlerContext.class, ChannelPromise.class)) {
                    mask &= ~MASK_DISCONNECT;
                }
                if (isSkippable(handlerType, "close", ChannelHandlerContext.class, ChannelPromise.class)) {
                    mask &= ~MASK_CLOSE;
                }
                if (isSkippable(handlerType, "deregister", ChannelHandlerContext.class, ChannelPromise.class)) {
                    mask &= ~MASK_DEREGISTER;
                }
                if (isSkippable(handlerType, "read", ChannelHandlerContext.class)) {
                    mask &= ~MASK_READ;
                }
                if (isSkippable(handlerType, "write", ChannelHandlerContext.class,
                        Object.class, ChannelPromise.class)) {
                    mask &= ~MASK_WRITE;
                }
                if (isSkippable(handlerType, "flush", ChannelHandlerContext.class)) {
                    mask &= ~MASK_FLUSH;
                }
            }

            if (isSkippable(handlerType, "exceptionCaught", ChannelHandlerContext.class, Throwable.class)) {
                mask &= ~MASK_EXCEPTION_CAUGHT;
            }
        } catch (Exception e) {
            // Should never reach here.
            PlatformDependent.throwException(e);
        }

        return mask;
    }

    @SuppressWarnings("rawtypes")
    private static boolean isSkippable(
            final Class<?> handlerType, final String methodName, final Class<?>... paramTypes) throws Exception {
        return AccessController.doPrivileged(new PrivilegedExceptionAction<Boolean>() {
            @Override
            public Boolean run() throws Exception {
                Method m;
                try {
                    m = handlerType.getMethod(methodName, paramTypes);
                } catch (NoSuchMethodException e) {
                    if (logger.isDebugEnabled()) {
                        logger.debug(
                            "Class {} missing method {}, assume we can not skip execution", handlerType, methodName, e);
                    }
                    return false;
                }
                return m.isAnnotationPresent(Skip.class);
            }
        });
    }

    private ChannelHandlerMask() { }

    @Target(ElementType.METHOD)
    @Retention(RetentionPolicy.RUNTIME)
    @interface Skip {
        // no value
    }
}
```

将核心的`mask0`方法的主干代码剥离出后，其实核心逻辑很简单：

```java
// 添加了所有
mask |= MASK_ALL_INBOUND;
// 如果该 Handler 的 xx 方法标注了 @Skip 注解，则将他剔除
if (isSkippable(handlerType, "xx", ChannelHandlerContext.class)) {
    mask &= ~xx;
}
```

这样计算出某个ChannelHandler的`executionMask`值并缓存起来。

在使用的时候，比如查询pipeline责任链中下一个可以被执行的入站或出站的handler的时候是这样判断的：

```java
// AbstractChannelHandlerContext.java

// 因为pipeline是个职责链，它需要判断当前的method是否被允许执行。使用 (ctx.executionMask & mask) == 0 来表示当前是否被禁止调用。如果是的话，则忽略，继续迭代，直到找到允许被调用的 handler
private AbstractChannelHandlerContext findContextInbound(int mask) {
    AbstractChannelHandlerContext ctx = this;
    EventExecutor currentExecutor = executor();
    do {
        ctx = ctx.next;
    } while (skipContext(ctx, currentExecutor, mask, MASK_ONLY_INBOUND)); // 如果下一个Handler的某个事件，标注@Skip的会被跳过 继续寻找下一个
    return ctx;
}

private AbstractChannelHandlerContext findContextOutbound(int mask) {
    AbstractChannelHandlerContext ctx = this;
    EventExecutor currentExecutor = executor();
    do {
        ctx = ctx.prev;
    } while (skipContext(ctx, currentExecutor, mask, MASK_ONLY_OUTBOUND)); // 如果上一个Handler的某个事件，标注@Skip的会被跳过 继续寻找下一个
    return ctx;
}
// 表示会跳过执行
private static boolean skipContext(
        AbstractChannelHandlerContext ctx, EventExecutor currentExecutor, int mask, int onlyMask) {
    // Ensure we correctly handle MASK_EXCEPTION_CAUGHT which is not included in the MASK_EXCEPTION_CAUGHT
    return (ctx.executionMask & (onlyMask | mask)) == 0 ||
            // We can only skip if the EventExecutor is the same as otherwise we need to ensure we offload
            // everything to preserve ordering.
            //
            // See https://github.com/netty/netty/issues/10067
            (ctx.executor() == currentExecutor && (ctx.executionMask & mask) == 0); // (ctx.executionMask & mask) == 0表示当前是否被禁止调用
}
```

如果一个Handler同时实现了`ChannelInboundHandler`和`ChannelOutboundHandler`接口，那么他既是一个inBound类型的Handler，又是一个outBound类型的Handler，比如下面这个类`ChannelDuplexHandler`。

<img src="http://blog-1259650185.cosbj.myqcloud.com/img/202112/01/1638289952.jpg" alt="ChannelDuplexHandler" style="zoom:50%;" />



常用的，将decode操作和encode操作合并到一起的codec，一般会继承 `MessageToMessageCodec`，而`MessageToMessageCodec`就是继承`ChannelDuplexHandler`。

```java
// MessageToMessageCodec.java
public abstract class MessageToMessageCodec<INBOUND_IN, OUTBOUND_IN> extends ChannelDuplexHandler {

    protected abstract void encode(ChannelHandlerContext ctx, OUTBOUND_IN msg, List<Object> out)
            throws Exception;

    protected abstract void decode(ChannelHandlerContext ctx, INBOUND_IN msg, List<Object> out)
            throws Exception;
 }
```

context 创建完了之后，接下来终于要将创建完毕的context加入到pipeline中去了。

### 3. 添加节点

```java
private void addLast0(AbstractChannelHandlerContext newCtx) {
    AbstractChannelHandlerContext prev = tail.prev;
    newCtx.prev = prev; // 1
    newCtx.next = tail; // 2
    prev.next = newCtx; // 3
    tail.prev = newCtx; // 4
}
```

用下面这幅图可见简单的表示这段过程，说白了，其实就是一个双向链表的插入操作。

<img src="http://blog-1259650185.cosbj.myqcloud.com/img/202112/01/1638290159.jpg" alt="添加节点过程" style="zoom: 67%;" />

操作完毕，该context就加入到pipeline中。

<img src="http://blog-1259650185.cosbj.myqcloud.com/img/202112/01/1638290203.jpg" alt="添加节点之后" style="zoom:67%;" />

到这里，pipeline添加节点的操作就完成了，你可以根据此思路掌握所有的addxxx()系列方法。

### 4. 回调用户方法

```java
// DefaultChannelPipeline.java
private void callHandlerAdded0(final AbstractChannelHandlerContext ctx) {
    try {
        ctx.handler().handlerAdded(ctx);    // 调用事件处理
        ctx.setAddComplete();  
    } catch (Throwable t) {
        boolean removed = false;    // 异常时删除Context，尽量恢复现场
        try {
            remove0(ctx);   // 实际双向链表删除操作
            try {
                ctx.handler().handlerRemoved(ctx);  // 调用事件处理
            } finally {
                ctx.setRemoved();
            }
            removed = true;
        } catch (Throwable t2) {
            logger.warn("Failed to remove a handler: " + ctx.name(), t2);
        }

        if (removed) {
            fireExceptionCaught(new ChannelPipelineException("handlerAdded() has thrown an exception; removed."));
        } else {
            fireExceptionCaught(new ChannelPipelineException("handlerAdded() has thrown an exception; also failed to remove."));
        }
    }
}
```

到了第四步，pipeline中的新节点添加完成，调用AbstractChannelHandlerContext的`callHandlerAdded()`方法。

````java
// AbstractChannelHandlerContext.java
final void callHandlerAdded() throws Exception {
    if (setAddComplete()) {
        handler().handlerAdded(this);  // 回调用户自定义的handler里的handlerAdded方法
    }
}
````

首先，设置该节点的状态。

````java
// AbstractChannelHandlerContext.java
// 设置并返回该节点的状态
final boolean setAddComplete() {
    for (;;) {
        int oldState = handlerState;
        if (oldState == REMOVE_COMPLETE) { // 如果原来状态是REMOVE_COMPLETE，说明该节点已经被移除，返回false
            return false;
        }
        // Ensure we never update when the handlerState is REMOVE_COMPLETE already.
        // oldState is usually ADD_PENDING but can also be REMOVE_COMPLETE when an EventExecutor is used that is not
        // exposing ordering guarantees.
        if (HANDLER_STATE_UPDATER.compareAndSet(this, oldState, ADD_COMPLETE)) { // 用cas修改节点的状态至ADD_COMPLETE
            return true;
        }
    }
}
````

完成了节点的状态设置后，便开始回调用户代码 `handler().handlerAdded(this);`，常见的用户代码如下：

```java
// 用户代码
public class DemoHandler extends SimpleChannelInboundHandler<...> {
    @Override
    public void handlerAdded(ChannelHandlerContext ctx) throws Exception {
        // 节点被添加完毕之后回调到此
        // do something
    }
}
```

接着看callHandlerCallbackLater()方法，当我们在Channel注册到之前添加或删除Handler时，此时没有EventExecutor可执行HandlerAdd或HandlerRemove事件，所以Netty为此事件生成一个相应任务等注册完成后在调用执行任务。添加或删除任务可能有很多个，DefaultChannelPipeline使用一个链表存储，链表头部为先前的字段`pendingHandlerCallbackHead`，代码如下：

```java
// DefaultChannelPipeline.java
// 参数added为True表示HandlerAdd任务，False表示HandlerRemove任务
private void callHandlerCallbackLater(AbstractChannelHandlerContext ctx, boolean added) {
    assert !registered; // 必须非注册
    PendingHandlerCallback task = added ? new PendingHandlerAddedTask(ctx) : new PendingHandlerRemovedTask(ctx);
    PendingHandlerCallback pending = pendingHandlerCallbackHead;
    if (pending == null) {
        pendingHandlerCallbackHead = task;  // 链表头部
    } else {    // 插入到链表尾部
        while (pending.next != null) {
            pending = pending.next;
        }
        pending.next = task;
    }
}
```

以HandlerAdd任务为例分析任务部分的代码（HandlerRemove可类比）：

```java
// PendingHandlerCallback.java
private abstract static class PendingHandlerCallback implements Runnable {
    final AbstractChannelHandlerContext ctx;
    PendingHandlerCallback next;

    PendingHandlerCallback(AbstractChannelHandlerContext ctx) { this.ctx = ctx;}

    abstract void execute();
}

private final class PendingHandlerAddedTask extends PendingHandlerCallback {
    PendingHandlerAddedTask(AbstractChannelHandlerContext ctx) { super(ctx);}

    @Override
    public void run() {
        callHandlerAdded0(ctx);
    }

    @Override
    void execute() {
        EventExecutor executor = ctx.executor();
        if (executor.inEventLoop()) {
            // 当前线程为EventLoop线程，调用HandlerAdd事件
            callHandlerAdded0(ctx);
        } else {
            try {
                executor.execute(this); // 否则提交一个任务，任务执行run()方法
            } catch (RejectedExecutionException e) {
                logger.warn("...");
                remove0(ctx);   // 异常时，将已添加的Handler删除
                ctx.setRemoved();
            }
        }
    }
}
```

## pipeline删除节点

netty 有个最大的特性之一就是Handler可插拔，做到动态编织pipeline，比如在首次建立连接的时候，需要通过进行权限认证，在认证通过之后，就可以将此context移除，下次pipeline在传播事件的时候就就不会调用到权限认证处理器。

下面是权限认证Handler最简单的实现，第一个数据包传来的是认证信息，如果校验通过，就删除此Handler，否则，直接关闭连接。

```java
// 用户代码
public class AuthHandler extends SimpleChannelInboundHandler<ByteBuf> {
    @Override
    protected void channelRead0(ChannelHandlerContext ctx, ByteBuf authDataPacket) throws Exception {
        if (verify(authDataPacket)) {
            ctx.pipeline().remove(this);
        } else {
            ctx.close();
        }
    }

    private boolean verify(ByteBuf byteBuf) {
        //...
    }
}
```

重点就在 `ctx.pipeline().remove(this)` 这段代码。

```java
// DefaultChannelPipeline.java
@Override
public final ChannelPipeline remove(ChannelHandler handler) {
    remove(getContextOrDie(handler));
    return this;
}
```

remove操作相比add简单不少，分为三个步骤：

1. 找到待删除的节点
2. 调整双向链表指针删除
3. 回调用户函数

### 1. 找到待删除的节点

```java
// DefaultChannelPipeline.java
private AbstractChannelHandlerContext getContextOrDie(ChannelHandler handler) {
    AbstractChannelHandlerContext ctx = (AbstractChannelHandlerContext) context(handler);
    if (ctx == null) {
        throw new NoSuchElementException(handler.getClass().getName());
    } else {
        return ctx;
    }
}

@Override
public final ChannelHandlerContext context(ChannelHandler handler) {
    ObjectUtil.checkNotNull(handler, "handler");

    AbstractChannelHandlerContext ctx = head.next;
    for (;;) {

        if (ctx == null) {
            return null;
        }

        if (ctx.handler() == handler) {
            return ctx;
        }

        ctx = ctx.next;
    }
}
```

这里为了找到Handler对应的context，照样是通过依次遍历双向链表的方式，直到某一个context的Handler和当前Handler相同，便找到了该节点。

### 2. 调整双向链表指针删除

```java
// DefaultChannelPipeline.java
private AbstractChannelHandlerContext remove(final AbstractChannelHandlerContext ctx) {
    assert ctx != head && ctx != tail;

    synchronized (this) {
        atomicRemoveFromHandlerList(ctx); // 2.调整双向链表指针删除

        if (!registered) {
            callHandlerCallbackLater(ctx, false);
            return ctx;
        }

        EventExecutor executor = ctx.executor();
        if (!executor.inEventLoop()) {
            executor.execute(new Runnable() {
                @Override
                public void run() {
                    callHandlerRemoved0(ctx);
                }
            });
            return ctx;
        }
    }
    callHandlerRemoved0(ctx); // 3.回调用户函数
    return ctx; 
}

private synchronized void atomicRemoveFromHandlerList(AbstractChannelHandlerContext ctx) {
    AbstractChannelHandlerContext prev = ctx.prev;
    AbstractChannelHandlerContext next = ctx.next;
    prev.next = next; // 1
    next.prev = prev; // 2
}
```

经历的过程要比添加节点要简单，可以用下面一幅图来表示：

<img src="http://blog-1259650185.cosbj.myqcloud.com/img/202112/01/1638291366.jpg" alt="删除节点过程" style="zoom:67%;" />

最后的结果为：

<img src="http://blog-1259650185.cosbj.myqcloud.com/img/202112/01/1638291396.jpg" alt="删除节点之后" style="zoom:80%;" />

结合这两幅图，可以很清晰地了解权限验证Handler的工作原理，另外，被删除的节点因为没有对象引用到，果过段时间就会被gc自动回收。

### 3. 回调用户函数

```java
// DefaultChannelPipeline.java
private void callHandlerRemoved0(final AbstractChannelHandlerContext ctx) {
    // Notify the complete removal.
    try {
        ctx.callHandlerRemoved();
    } catch (Throwable t) {
        fireExceptionCaught(new ChannelPipelineException(
                ctx.handler().getClass().getName() + ".handlerRemoved() has thrown an exception.", t));
    }
}

// AbstractChannelHandlerContext.java
final void callHandlerRemoved() throws Exception {
    try {
        if (handlerState == ADD_COMPLETE) { // 只有状态是ADD_COMPLETE才会被调用
            handler().handlerRemoved(this);
        }
    } finally {
        setRemoved(); // 将该节点的状态设置为REMOVE_COMPLETE
    }
}


```

到了第三步，pipeline中的节点删除完成，于是便开始回调用户代码 `handler().handlerRemoved(this);`，常见的代码如下：

```java
// 用户代码
public class DemoHandler extends SimpleChannelInboundHandler<...> {
    @Override
    public void handlerRemoved(ChannelHandlerContext ctx) throws Exception {
        // 节点被删除完毕之后回调到此，可做一些资源清理
        // do something
    }
}
```

最后，在finally代码块中将该节点的状态设置为REMOVE_COMPLETE。

## 其他方法

再看一下fireXXX方法和bind等事件触发方法的代码：

```java
@Override
public final ChannelPipeline fireChannelRegistered() {
    // 入站事件从双向链表头部处理
    AbstractChannelHandlerContext.invokeChannelRegistered(head);
    return this;
}

@Override
public final ChannelFuture bind(SocketAddress localAddress, ChannelPromise promise) {
    // 出站事件从双向链表尾部处理
    return tail.bind(localAddress, promise);
}
```

由于头部和尾部节点都是ChannelHandlerContext，具体的事件触发处理都委托给head和tail处理，将在之后一节进行分析。至此，接口中的方法已分析完毕，是不是还差点什么？仔细回想一下，在addXXX()方法中有待执行的HandlerAdd和HandlerRemove任务，它们怎么执行的呢？DefaultChannelPipeline提供了invokeHandlerAddedIfNeeded()方法：

```java
// DefaultChannelPipeline.java
final void invokeHandlerAddedIfNeeded() {
    assert channel.eventLoop().inEventLoop();
    if (firstRegistration) {
        firstRegistration = false;
        // 至此，channel已注册到EventLoop，可以执行任务
        callHandlerAddedForAllHandlers();
    }
}

private void callHandlerAddedForAllHandlers() {
    final PendingHandlerCallback pendingHandlerCallbackHead;
    synchronized (this) {
        assert !registered; // 必须为非注册
        registered = true;  // 至此则说明已注册

        pendingHandlerCallbackHead = this.pendingHandlerCallbackHead;
        this.pendingHandlerCallbackHead = null;  // 帮助垃圾回收
    }

    // 用一个局部变量保存任务链表头部是因为以下代码如果在synchronized块内，则当用户在
    // 非EventLoop中执行HandlerAdd()方法而该方法中又新增一个handler时不会发生死锁
    PendingHandlerCallback task = pendingHandlerCallbackHead;
    while (task != null) {
        task.execute(); // 遍历链表依次执行
        task = task.next;
    }
}
```

invokeHandlerAddedIfNeeded()方法在以下两种情况被调用：

1. AbstractUnsafe的register事件框架，当Channel注册到EventLoop之前会被调用，确保异步注册操作一旦完成就触发HandlerAdd事件。
2. 双向链表头部节点的channelRegistered()方法（为什么此时调用，双重保护？）。

DefaultChannelPipeline还有最后一个方法destroy()，将pipeline中的所有节点销毁，顺序**由尾部向头部**并触发HandlerRemove事件，代码如下：

```java
// DefaultChannelPipeline.java
private synchronized void destroy() {
    destroyUp(head.next, false);
}

// 参数inEventLoop应理解为是否直接执行本段代码的for循环部分，也就是说为true时不需要提交
// 一个destroyUp任务，为False时则需要判断Handler的执行线程是否为EventLoop线程
private void destroyUp(AbstractChannelHandlerContext ctx, boolean inEventLoop) {
    final Thread currentThread = Thread.currentThread();
    final AbstractChannelHandlerContext tail = this.tail;
    for (;;) {
        if (ctx == tail) {
            destroyDown(currentThread, tail.prev, inEventLoop);
            break;
        }

        final EventExecutor executor = ctx.executor();
        if (!inEventLoop && !executor.inEventLoop(currentThread)) {
            final AbstractChannelHandlerContext finalCtx = ctx;
            // destroyUp()的for循环部分需在executor内执行，所以置True
            executor.execute( () -> { destroyUp(finalCtx, true); } );
            break;
        }

        ctx = ctx.next;
        inEventLoop = false; // 每次都悲观的认为下一个Handler的处理线程会是另外一个线程
    }
}


private void destroyDown(Thread currentThread, AbstractChannelHandlerContext ctx, boolean inEventLoop) {
    // 至此，已经到达双向链表尾部，可确定入站事件已在删除操作进行之前传播完毕
    final AbstractChannelHandlerContext head = this.head;
    for (;;) {
        if (ctx == head) {
            break;
        }

        // 这部分代码实质与up部分一致，采用两种表现形式容易引起困惑
        // 本质上 （！a  && ！b） == （a || b）
        final EventExecutor executor = ctx.executor();
        if (inEventLoop || executor.inEventLoop(currentThread)) {
            synchronized (this) {
                remove0(ctx);
            }
            callHandlerRemoved0(ctx);
        } else {
            final AbstractChannelHandlerContext finalCtx = ctx;
            executor.execute(() -> { destroyDown(Thread.currentThread(), finalCtx, true); });
            break;
        }

        ctx = ctx.prev;
        inEventLoop = false;
    }
}
```

这部分代码晦涩难懂，考虑这样一种情况，当我们由尾部向头部删除节点时，有一个入站事件正从头部向尾部传播，由于从尾部开始删除了某些节点，入站事件的处理流程被破坏。这部分代码正是为了处理这种情况，所以首先从头部向尾部遍历，确保没有入站事件，此时才从尾部向头部进行删除销毁操作。

这部分代码还为了保证事件在正确的线程中执行，假设有如下pipeline：

```rust
    HEAD --> [E1] H1 --> [E2] H2 --> TAIL
```

其中E1和E2为两个线程，则必须保证Handler1中的事件在E1执行，Handler2中的事件在E2执行，而Head和Tail的事件在Channel注册到的EventLoop中执行。

## 总结

1. 以新连接创建为例，新连接创建的过程中创建channel，而在创建channel的过程中创建了该channel对应的pipeline，创建完pipeline之后，自动给该pipeline添加了head和tail两个节点。ChannelHandlerContext中有用pipeline和channel所有的上下文信息。

2. pipeline是双向个链表结构，添加和删除节点均只需要调整链表结构

3. pipeline中的每个节点包裹着具体的处理器`ChannelHandler`，节点根据`ChannelHandler`的类型是`ChannelInboundHandler`还是`ChannelOutboundHandler`可以通过executionMask来判断。

4. 下图展示了传播的方法，但我其实是更想让大家看一下，哪些事件是 Inbound 类型的，哪些是 Outbound 类型的：

   <img src="http://blog-1259650185.cosbj.myqcloud.com/img/202112/06/1638757902.png" alt="19" style="zoom:50%;" />



# pipeline细节

在上一节中，我们已经了解了pipeline在netty中所处的角色，像是一条流水线，控制着字节流的读写，本文，我们在这个基础上继续深挖pipeline在事件传播，异常传播等方面的细节。

接下来，分以下几个部分进行

1. ChannelHandlerContext源码实现
1. netty中的Unsafe到底是干什么的
2. pipeline中的head
3. pipeline中的inBound事件传播
4. pipeline中的tail
5. pipeline中的outBound事件传播
6. pipeline 中异常的传播
6. ChannelHandlerContext源码实现

## ChannelHandlerContext源码实现

### AbstractChannelHandlerContext

AbstractChannelHandlerContext的类签名如下：

```java
abstract class AbstractChannelHandlerContext extends DefaultAttributeMap implements ChannelHandlerContext
```

该类作为其他ChannelHandlerContext的基类，Netty4.0中继承自DefaultAttributeMap实现属性键值对的存储和获取，由于此种用法与`channel.attr()`存在混淆，故不建议使用。确有需要时，请直接使用`channel.attr()`。

下面介绍其中的关键字段：

```java
// AbstractChannelHandlerContext.java
// Context形成双向链表，next和prev分别是后继节点和前驱节点
volatile AbstractChannelHandlerContext next;
volatile AbstractChannelHandlerContext prev;

private final int executionMask; // context关联的handler对象支持回调的事件类型

private final DefaultChannelPipeline pipeline;  
private final String name;  // Context的名称
private final boolean ordered;  // 事件顺序标记

final EventExecutor executor; // 事件执行线程

private volatile int handlerState = INIT;   // 状态
```

其中`handlerState`的字面意思容易使人误解，为此列出四种状态并加以解释：

```java
// AbstractChannelHandlerContext.java
// 初始状态
private static final int INIT = 0; 
// 对应Handler的handlerAdded方法将要被调用但还未调用
private static final int ADD_PENDING = 1;
// 对应Handler的handlerAdded方法被调用
private static final int ADD_COMPLETE = 2;
// 对应Handler的handlerRemoved方法被调用
private static final int REMOVE_COMPLETE = 3;
```

AbstractChannelHandlerContext只有一个构造方法：

```java
// AbstractChannelHandlerContext.java
AbstractChannelHandlerContext(DefaultChannelPipeline pipeline, 
          EventExecutor executor, String name, 
          boolean inbound, boolean outbound) {
    this.name = ObjectUtil.checkNotNull(name, "name");
    this.pipeline = pipeline;
    this.executor = executor;
    this.inbound = inbound;
    this.outbound = outbound;
    
    // 只有执行线程为EventLoop或者标记为OrderedEventExecutor才是顺序的
    ordered = executor == null || executor instanceof OrderedEventExecutor;
}
```

由于Netty将事件抽象为入站事件和出站事件，AbstractChannelHandlerContext对事件的处理也分为两类，分别为ChannelRead和read事件。

### DefaultChannelHandlerContext

DefaultChannelHandlerContext是使用Netty时经常使用的事实Context类，其中的大部分功能已在AbstractChannelHandlerContext中完成，所以该类十分简单，其构造方法如下：

```java
// DefaultChannelHandlerContext.java
DefaultChannelHandlerContext(
        DefaultChannelPipeline pipeline, EventExecutor executor, String name, ChannelHandler handler) {
    super(pipeline, executor, name, handler.getClass());
    this.handler = handler;
}
```

实现中引入了一个新的字段：

```java
private final ChannelHandler handler;
```

回忆ChannelPipeline，pipeline其中形成Context的双向链表，而处理逻辑则在Handler中。设计模式中指出，关联Handler与Context的方法有两种：**组合**和**继承**。本例中，使用的是组合。

## Unsafe到底是干什么的

之所以Unsafe放到pipeline中讲，是因为unsafe和pipeline密切相关，pipeline中的有关io的操作最终都是落地到unsafe，所以，有必要先讲讲unsafe。

### 初识Unsafe

顾名思义，unsafe是不安全的意思，就是告诉你不要在应用程序里面直接使用Unsafe以及他的衍生类对象。

在 JDK 的源码中，sun.misc.Unsafe 类提供了一些底层操作的能力，它设计出来是给 JDK 中的源码使用的，比如 AQS、ConcurrentHashMap 等，在并发包中也看到了很多它们使用 Unsafe 的场景，这个 Unsafe 类不是给我们的代码使用的，是给 JDK 源码使用的（需要的话，我们也是可以获取它的实例的）。

> Unsafe 类的构造方法是 private 的，但是它提供了 getUnsafe() 这个静态方法：
>
> ```java
> Unsafe unsafe = Unsafe.getUnsafe();
> ```
>
> 大家可以试一下，上面这行代码编译没有问题，但是执行的时候会抛 `java.lang.SecurityException` 异常，因为它就不是给我们的代码用的。
>
> 但是如果你就是想获取 Unsafe 的实例，可以通过下面这个代码获取到：
>
> ```java
> Field f = Unsafe.class.getDeclaredField("theUnsafe");
> f.setAccessible(true);
> Unsafe unsafe = (Unsafe) f.get(null);
> ```

Netty 中的 Unsafe 也是同样的意思，它封装了 Netty 中会使用到的 JDK 提供的 NIO 接口，比如将 channel 注册到 selector 上，比如 bind 操作，比如 connect 操作等，**这些操作都是稍微偏底层一些**。Netty 同样也是不希望我们的业务代码使用 Unsafe 的实例，它是提供给 Netty 中的源码使用的。

netty官方的解释如下：

> Unsafe operations that should never be called from user-code. These methods are only provided to implement the actual transport, and must be invoked from an I/O thread

Unsafe 在Channel定义，属于Channel的内部类，表明Unsafe和Channel密切相关。

下面是unsafe接口的所有方法：

```java
// Unsafe.java
interface Unsafe {

    RecvByteBufAllocator.Handle recvBufAllocHandle();

    SocketAddress localAddress();

    SocketAddress remoteAddress();

    void register(EventLoop eventLoop, ChannelPromise promise);

    void bind(SocketAddress localAddress, ChannelPromise promise);

    void connect(SocketAddress remoteAddress, SocketAddress localAddress, ChannelPromise promise);

    void disconnect(ChannelPromise promise);

    void close(ChannelPromise promise);

    void closeForcibly();

    void deregister(ChannelPromise promise);

    void beginRead();

    void write(Object msg, ChannelPromise promise);

    void flush();

    ChannelPromise voidPromise();

    ChannelOutboundBuffer outboundBuffer();
}
```

按功能可以分为分配内存，Socket四元组信息，注册事件循环，绑定网卡端口，Socket的连接和关闭，Socket的读写，看的出来，这些操作都是和jdk底层相关。

<img src="http://blog-1259650185.cosbj.myqcloud.com/img/202112/01/1638325044.jpg" alt="Unsafe 继承结构" style="zoom:50%;" />

`NioUnsafe` 在 `Unsafe`基础上增加了以下几个接口。

```java
// NioUnsafe.java
public interface NioUnsafe extends Unsafe {
    SelectableChannel ch();
    void finishConnect();
    void read();
    void forceFlush();
}
```

从增加的接口以及类名上来看，`NioUnsafe` 增加了可以访问底层JDK的`SelectableChannel`的功能，定义了从`SelectableChannel`读取数据的`read`方法。

`AbstractUnsafe` 实现了大部分`Unsafe`的功能。

`AbstractNioUnsafe` 主要是通过代理到其外部类`AbstractNioChannel`拿到了与jdk nio相关的一些信息，比如`SelectableChannel`，`SelectionKey`等等。

`NioSocketChannelUnsafe`和`NioByteUnsafe`放到一起讲，其实现了IO的基本操作，读，和写，这些操作都与jdk底层相关。

`NioMessageUnsafe`和 `NioByteUnsafe` 是处在同一层次的抽象，netty将**一个新连接的建立也当作一个IO操作来处理**，这里的**Message的含义我们可以当作是一个`SelectableChannel`**，**读的意思就是accept一个`SelectableChannel`**，写的意思是针对一些无连接的协议，比如UDP来操作的，我们先不用关注。

### Unsafe的分类

从以上继承结构来看，我们可以总结出两种类型的Unsafe分类，一个是与连接的字节数据读写相关的`NioByteUnsafe`，一个是与新连接建立操作相关的`NioMessageUnsafe`。

**`NioByteUnsafe`中的读**：

委托到所在的外部类NioSocketChannel。

```java
// NioSocketChannel.java
protected int doReadBytes(ByteBuf byteBuf) throws Exception {
    final RecvByteBufAllocator.Handle allocHandle = unsafe().recvBufAllocHandle();
    allocHandle.attemptedBytesRead(byteBuf.writableBytes());
    return byteBuf.writeBytes(javaChannel(), allocHandle.attemptedBytesRead());
}
```

最后一行已经与jdk底层以及netty中的ByteBuf相关，将jdk的 `SelectableChannel`的字节数据读取到netty的`ByteBuf`中。

**`NioByteUnsafe`中的写**：

直接使用父类`AbstractUnsafe`的write方法。

**`NioMessageUnsafe`中的读**：

委托到所在的外部类NioServerSocketChannel。

```java
// NioServerSocketChannel.java
@Override
protected int doReadMessages(List<Object> buf) throws Exception {
    // 接受新连接查创建SocketChannel
    SocketChannel ch = SocketUtils.accept(javaChannel());
    try {
        if (ch != null) {
            buf.add(new NioSocketChannel(this, ch)); // 封装成自定义的 NioSocketChannel，加入到buf里面
            return 1;
        }
    } catch (Throwable t) {
				...
    }
    return 0;
}
```

`NioMessageUnsafe` 的读操作很简单，就是调用jdk的`accept()`方法，新建立一条连接。

**`NioMessageUnsafe`中的读**：

在tcp协议层面我们基本不会涉及，暂时忽略。

## pipeline中的head

在第一节中，我们了解到head节点在pipeline中第一个处理IO事件，新连接的接入和读事件在`NioEventLoop`的第二个步骤processSelectedKey被检测到。

```java
// NioEventLoop.javas
private void processSelectedKey(SelectionKey k, AbstractNioChannel ch) {
     final AbstractNioChannel.NioUnsafe unsafe = ch.unsafe();
  	 ...
     //新连接的已准备接入或者已存在的连接有数据可读
     if ((readyOps & (SelectionKey.OP_READ | SelectionKey.OP_ACCEPT)) != 0 || readyOps == 0) {
         unsafe.read();
     }
  	 ...
}
```

读操作直接依赖到unsafe来进行，新连接的接入（unsafe为NioMessageUnsafe时）在netty源码分析之新连接接入全解析中已详细阐述，这里不再描述，下面将重点放到连接字节数据流（unsafe为NioByteUnsafe时）的读写。

```java
@Override
public final void read() {
    final ChannelConfig config = config();
    if (shouldBreakReadReady(config)) {
        clearReadPending();
        return;
    }
    final ChannelPipeline pipeline = pipeline();
    final ByteBufAllocator allocator = config.getAllocator(); // 创建ByteBuf分配器
    // io.netty.channel.DefaultChannelConfig 中设置 RecvByteBufAllocator ，默认 AdaptiveRecvByteBufAllocator
    final RecvByteBufAllocator.Handle allocHandle = recvBufAllocHandle();
    allocHandle.reset(config);

    ByteBuf byteBuf = null;
    boolean close = false;
    try {
        do {
            // 分配一个ByteBuf，尽可能分配合适的大小：guess，第一次就是 1024 byte
            byteBuf = allocHandle.allocate(allocator);
            // 读并且记录读了多少，如果读满了，下次continue的话就直接扩容。
            allocHandle.lastBytesRead(doReadBytes(byteBuf)); // doReadBytes(byteBuf)，委托到所在的外部类NioSocketChannel
            if (allocHandle.lastBytesRead() <= 0) {
                // nothing was read. release the buffer. 数据清理
                byteBuf.release();
                byteBuf = null;
                close = allocHandle.lastBytesRead() < 0;
                if (close) {
                    // There is nothing left to read as we received an EOF.
                    readPending = false;
                }
                break;
            }
            // 记录一下读了几次，仅仅一次
            allocHandle.incMessagesRead(1);
            readPending = false;
            // 触发事件，将会引发pipeline的读事件传播，pipeline上执行，业务逻辑的处理就是在这个地方，将得到的数据 byteBuf 传递出去
            pipeline.fireChannelRead(byteBuf);
            byteBuf = null;
        } while (allocHandle.continueReading());
        // 记录这次读事件总共读了多少数据，计算下次分配大小
        allocHandle.readComplete();
        // 相当于完成本地读事件的处理，数据多的话，可能会读（read）很多次（16次），都会通过 fireChannelRead 传播出去，这里是读取完成，仅仅一次
        pipeline.fireChannelReadComplete();

        if (close) {
            closeOnRead(pipeline);
        }
    } catch (Throwable t) {
        handleReadException(pipeline, byteBuf, t, close, allocHandle);
    } finally {
				...
    }
}
```

`NioByteUnsafe` 要做的事情可以简单地分为以下几个步骤：

1. 拿到Channel的config之后拿到ByteBuf分配器，用分配器来分配一个ByteBuf，ByteBuf是netty里面的字节数据载体，后面读取的数据都读到这个对象里面。
2. 将Channel中的数据读取到ByteBuf。
3. 数据读完之后，调用 `pipeline.fireChannelRead(byteBuf);` 从head节点开始传播至整个pipeline。

这里，我们的重点其实就是 `pipeline.fireChannelRead(byteBuf);`

```java
// DefaultChannelPipeline.java

final AbstractChannelHandlerContext head;
//...
head = new HeadContext(this);

@Override
public final ChannelPipeline fireChannelReadComplete() {
    AbstractChannelHandlerContext.invokeChannelReadComplete(head);
    return this;
}
```

结合这幅图：

<img src="http://blog-1259650185.cosbj.myqcloud.com/img/202111/30/1638277523.jpg" alt="pipeline结构" style="zoom:67%;" />

可以看到，数据从head节点开始流入，在进行下一步之前，我们先把head节点的功能过一遍。

```java
// HeadContext.java
// 调用Unsafe做具体的操作 注意：HeadContext 既是ChannelOutboundHandler，也是ChannelInboundHandler
final class HeadContext extends AbstractChannelHandlerContext
        implements ChannelOutboundHandler, ChannelInboundHandler {

    private final Unsafe unsafe;

    HeadContext(DefaultChannelPipeline pipeline) {
        super(pipeline, null, HEAD_NAME, HeadContext.class);
        unsafe = pipeline.channel().unsafe();
        setAddComplete();
    }

    @Override
    public ChannelHandler handler() {
        return this;
    }

    @Override
    public void handlerAdded(ChannelHandlerContext ctx) {
        // NOOP
    }

    @Override
    public void handlerRemoved(ChannelHandlerContext ctx) {
        // NOOP
    }

    @Override
    public void bind(
            ChannelHandlerContext ctx, SocketAddress localAddress, ChannelPromise promise) {
        unsafe.bind(localAddress, promise);
    }

    @Override
    public void connect(
            ChannelHandlerContext ctx,
            SocketAddress remoteAddress, SocketAddress localAddress,
            ChannelPromise promise) {
        unsafe.connect(remoteAddress, localAddress, promise);
    }

    @Override
    public void disconnect(ChannelHandlerContext ctx, ChannelPromise promise) {
        unsafe.disconnect(promise);
    }

    @Override
    public void close(ChannelHandlerContext ctx, ChannelPromise promise) {
        unsafe.close(promise);
    }

    @Override
    public void deregister(ChannelHandlerContext ctx, ChannelPromise promise) {
        unsafe.deregister(promise);
    }

    @Override
    public void read(ChannelHandlerContext ctx) {
        // 实际上就是注册OP_ACCEPT/OP_READ事件：创建连接或者读事件
        unsafe.beginRead();
    }
    // headContext write msg
    @Override
    public void write(ChannelHandlerContext ctx, Object msg, ChannelPromise promise) {
        unsafe.write(msg, promise);
    }

    @Override
    public void flush(ChannelHandlerContext ctx) {
        unsafe.flush();
    }

    @Override
    public void exceptionCaught(ChannelHandlerContext ctx, Throwable cause) {
        ctx.fireExceptionCaught(cause);
    }

    @Override
    public void channelRegistered(ChannelHandlerContext ctx) {
        invokeHandlerAddedIfNeeded();
        ctx.fireChannelRegistered();
    }

    @Override
    public void channelUnregistered(ChannelHandlerContext ctx) {
        ctx.fireChannelUnregistered();

        // Remove all handlers sequentially if channel is closed and unregistered.
        if (!channel.isOpen()) {
            destroy();
        }
    }

    @Override
    public void channelActive(ChannelHandlerContext ctx) {
        ctx.fireChannelActive();
        // 注册读事件：读包括：创建连接/读数据
        readIfIsAutoRead();
    }

    @Override
    public void channelInactive(ChannelHandlerContext ctx) {
        ctx.fireChannelInactive();
    }

    @Override
    public void channelRead(ChannelHandlerContext ctx, Object msg) {
        ctx.fireChannelRead(msg); // 在 pipeline 上传播
    }

    @Override
    public void channelReadComplete(ChannelHandlerContext ctx) {
        ctx.fireChannelReadComplete();

        readIfIsAutoRead();
    }

    private void readIfIsAutoRead() {
        if (channel.config().isAutoRead()) {
            channel.read();
        }
    }

    @Override
    public void userEventTriggered(ChannelHandlerContext ctx, Object evt) {
        ctx.fireUserEventTriggered(evt);
    }

    @Override
    public void channelWritabilityChanged(ChannelHandlerContext ctx) {
        ctx.fireChannelWritabilityChanged();
    }
}
```

从head节点继承和实现的两个接口看，它既是一个ChannelHandlerContext，同时又属于inBound和outBound Handler，可知HeadContext需要同时处理出站事件和入站事件。

> 注意，在不同的版本中，源码也略有差异，head 不一定是 in + out，大家知道这点就好了。

**以read和ChannelRead事件为例，当用户调用read出站事件时，是在告诉IO线程:我需要向网络读数据做处理；当IO线程读到数据后，则使用ChannelRead事件通知用户:已读取到数据**。

`read()`方法代码如下：

```java
public void read(ChannelHandlerContext ctx) {
    unsafe.beginRead();
}
```

在传播读写事件的时候，head的功能只是简单地将事件传播下去，如`ctx.fireChannelRead(msg);`

在真正执行读写操作的时候，例如在调用`writeAndFlush()`等方法的时候，最终都会委托到unsafe执行，而当一次数据读完，`channelReadComplete`方法首先被调用，它要做的事情除了将事件继续传播下去之外，还得继续向reactor线程注册读事件，即调用`readIfIsAutoRead()`, 我们简单跟一下。

```java
// HeadContext.java
private void readIfIsAutoRead() {
    if (channel.config().isAutoRead()) {
        channel.read();
    }
}

// AbstractChannel.java
@Override
public Channel read() {
    pipeline.read();
    return this;
}
```

默认情况下，Channel都是默认开启自动读取模式的，即只要Channel是active的，读完一波数据之后就继续向selector注册读事件，这样就可以连续不断得读取数据，最终，通过pipeline，还是传递到head节点。

```java
// HeadContext.java
@Override
public void read(ChannelHandlerContext ctx) {
 	 // 实际上就是注册OP_ACCEPT/OP_READ事件：创建连接或者读事件
    unsafe.beginRead();
}

// AbstractUnsafe.java
public final void beginRead() {
    assertEventLoop();
    try {
        doBeginRead();
    } catch (final Exception e) {
				...
    }
}
```

看一下`doBeginRead();`在`AbstractNioChannel`中的实现。

```java
// AbstractNioChannel.java
@Override
protected void doBeginRead() throws Exception {
    // Channel.read() or ChannelHandlerContext.read() was called
    // 前面register步骤返回的对象，前面我们在register的时候，注册的ops是0
    final SelectionKey selectionKey = this.selectionKey;
    if (!selectionKey.isValid()) {
        return;
    }

    readPending = true;
    // 获取前面监听的 ops = 0，
    final int interestOps = selectionKey.interestOps();
    // 假设之前没有监听readInterestOp，则监听readInterestOp
    // 就是之前new NioServerSocketChannel 时 super(null, channel, SelectionKey.OP_ACCEPT); 传进来保存到则监听readInterestOp的
    if ((interestOps & readInterestOp) == 0) {
        logger.info("interest ops：{}", readInterestOp);
        selectionKey.interestOps(interestOps | readInterestOp); // 真正的注册 interestOps，做好连接的准备
    }
}
```

`doBeginRead()` 做的事情很简单，拿到处理过的`selectionKey`，然后如果发现该selectionKey若在某个地方被移除了`readInterestOp`操作，这里给他加上，事实上，标准的netty程序是不会走到这一行的，只有在三次握手成功之后，如下方法被调用：

```java
// DefaultChannelPipeline.java
public void channelActive(ChannelHandlerContext ctx) throws Exception {
    ctx.fireChannelActive();
    readIfIsAutoRead();  // 自动读取
}
```

才会将`readInterestOp`注册到SelectionKey上，可结合 《netty源码分析之新连接接入全解析》来看。

HeadContext的`ChannelRead()`方法代码如下：

```java
public void channelRead(ChannelHandlerContext ctx, Object msg) throws Exception {
    ctx.fireChannelRead(msg);
}
```

可知HeadContext只是简单的将事件传播到下一个入站处理器。

也许你会有疑问：自己根本没使用过read出站事件，为什么数据自动读取了呢？这是因为默认设置自动读取`autoRead`。

总结一下，head节点的作用就是作为pipeline的头节点开始传递读写事件，调用unsafe进行实际的读写操作，下面，进入pipeline中非常重要的一环，inbound/outbound事件的传播。

## 如何理解inBound和outBound

### 错误的理解

`ChannelInboundHandler`、`ChannelOutboundHandler`，这里的inbound和outbound是什么意思呢？inbound对应IO输入，outbound对应IO输出？这是我看到这两个名字时的第一反应，但当我看到`ChannelOutboundHandler`接口中有read方法时，就开始疑惑了，应该是理解错了，如果outbound对应IO输出，为什么这个接口里会有明显表示IO输入的read方法呢？

### 正确的理解

直到看到了[Stack Overflow上Netty作者Trustin Lee对inbound和outbound的解释](https://stackoverflow.com/questions/22354135/in-netty4-why-read-and-write-both-in-outboundhandler)，疑团终于解开：

众所周知，Netty是事件驱动的，而事件分为两大类：inboud和outbound，分别由`ChannelInboundHandler`和`ChannelOutboundHandler`负责处理。所以，inbound和outbound并非指IO的输入和输出，而是指事件类型。

那么什么样的事件属于inbound，什么样的事件属于outbound呢？也就是说，事件类型的划分依据是什么？

答案是：**触发事件的源头**。

### inbound

**由外部触发的事件是inbound事件**。外部是指应用程序之外，因此inbound事件就是并非因为应用程序主动请求做了什么而触发的事件，比如某个socket上有数据读取进来了（注意是“读完了”这个事件，而不是“读取”这个操作），再比如某个socket连接了上来并被注册到了某个EventLoop。

Inbound事件的详细列表：

- [channelActive](https://netty.io/4.1/api/io/netty/channel/ChannelInboundHandler.html#channelActive-io.netty.channel.ChannelHandlerContext-) / [channelInactive](https://netty.io/4.1/api/io/netty/channel/ChannelInboundHandler.html#channelInactive-io.netty.channel.ChannelHandlerContext-)
- [channelRead](https://netty.io/4.1/api/io/netty/channel/ChannelInboundHandler.html#channelRead-io.netty.channel.ChannelHandlerContext-java.lang.Object-)
- [channelReadComplete](https://netty.io/4.1/api/io/netty/channel/ChannelInboundHandler.html#channelReadComplete-io.netty.channel.ChannelHandlerContext-)
- [channelRegistered](https://netty.io/4.1/api/io/netty/channel/ChannelInboundHandler.html#channelRegistered-io.netty.channel.ChannelHandlerContext-) / [channelUnregistered](https://netty.io/4.1/api/io/netty/channel/ChannelInboundHandler.html#channelUnregistered-io.netty.channel.ChannelHandlerContext-)
- [channelWritabilityChanged](https://netty.io/4.1/api/io/netty/channel/ChannelInboundHandler.html#channelWritabilityChanged-io.netty.channel.ChannelHandlerContext-)
- [exceptionCaught](https://netty.io/4.1/api/io/netty/channel/ChannelInboundHandler.html#exceptionCaught-io.netty.channel.ChannelHandlerContext-java.lang.Throwable-)
- [userEventTriggered](https://netty.io/4.1/api/io/netty/channel/ChannelInboundHandler.html#userEventTriggered-io.netty.channel.ChannelHandlerContext-java.lang.Object-)

### outbound

而outbound事件是由应用程序主动请求而触发的事件，可以认为，outbound是指应用程序发起了某个操作。比如向socket写入数据，再比如从socket读取数据（注意是“读取”这个操作请求，而非“读完了”这个事件），这也解释了为什么ChannelOutboundHandler中会有read方法。

Outbound事件列表：

- [bind](https://netty.io/4.1/api/io/netty/channel/ChannelOutboundHandler.html#bind-io.netty.channel.ChannelHandlerContext-java.net.SocketAddress-io.netty.channel.ChannelPromise-)
- [close](https://netty.io/4.1/api/io/netty/channel/ChannelOutboundHandler.html#close-io.netty.channel.ChannelHandlerContext-io.netty.channel.ChannelPromise-)
- [connect](https://netty.io/4.1/api/io/netty/channel/ChannelOutboundHandler.html#connect-io.netty.channel.ChannelHandlerContext-java.net.SocketAddress-java.net.SocketAddress-io.netty.channel.ChannelPromise-)
- [deregister](https://netty.io/4.1/api/io/netty/channel/ChannelOutboundHandler.html#deregister-io.netty.channel.ChannelHandlerContext-io.netty.channel.ChannelPromise-)
- [disconnect](https://netty.io/4.1/api/io/netty/channel/ChannelOutboundHandler.html#disconnect-io.netty.channel.ChannelHandlerContext-io.netty.channel.ChannelPromise-)
- [flush](https://netty.io/4.1/api/io/netty/channel/ChannelOutboundHandler.html#flush-io.netty.channel.ChannelHandlerContext-)
- [read](https://netty.io/4.1/api/io/netty/channel/ChannelOutboundHandler.html#read-io.netty.channel.ChannelHandlerContext-)
- [write](https://netty.io/4.1/api/io/netty/channel/ChannelOutboundHandler.html#write-io.netty.channel.ChannelHandlerContext-java.lang.Object-io.netty.channel.ChannelPromise-)

大都是在socket上可以执行的一系列常见操作：绑定地址、建立和关闭连接、IO操作，另外还有Netty定义的一种操作deregister：解除channel与eventloop的绑定关系。

值得注意的是，一旦应用程序发出以上操作请求，ChannelOutboundHandler中对应的方法就会被调用，而不是等到操作完毕之后才被调用，一个handler在处理时甚至可以将请求拦截而不再传递给后续的handler，使得真正的操作并不会被执行。

### inbound events & outbound operations

以上对inbound和outbound的理解从[`ChannelPipeline`的Javadoc](https://netty.io/4.1/api/io/netty/channel/ChannelPipeline.html)中也可以得到佐证：

> A list of [`ChannelHandler`](https://netty.io/4.1/api/io/netty/channel/ChannelHandler.html)s which handles or intercepts ***inbound events*** and ***outbound operations*** of a [`Channel`](https://netty.io/4.1/api/io/netty/channel/Channel.html). [`ChannelPipeline`](https://netty.io/4.1/api/io/netty/channel/ChannelPipeline.html) implements an advanced form of the [Intercepting Filter](http://www.oracle.com/technetwork/java/interceptingfilter-142169.html) pattern to give a user full control over how an event is handled and how the [`ChannelHandler`](https://netty.io/4.1/api/io/netty/channel/ChannelHandler.html)s in a pipeline interact with each other.

重点在于inbound events和outbound operations，即**inbound是事件，outbound是操作（直接导致的事件）**。

## pipeline中的inBound事件传播

在《netty源码分析之新连接接入全解析》一文中，我们没有详细描述为啥`pipeline.fireChannelActive();`最终会调用到`AbstractNioChannel.doBeginRead()`，了解pipeline中的事件传播机制，你会发现相当简单。

```java
// DefaultChannelPipeline.java
public final ChannelPipeline fireChannelActive() {
    AbstractChannelHandlerContext.invokeChannelActive(head);
    return this;
}
```

三次握手成功之后，`pipeline.fireChannelActive();`被调用，然后以head节点为参数，直接一个静态调用。

```java
// AbstractChannelHandlerContext.java
static void invokeChannelActive(final AbstractChannelHandlerContext next) {
    EventExecutor executor = next.executor();
    if (executor.inEventLoop()) {
        next.invokeChannelActive();
    } else {
        executor.execute(new Runnable() {
            @Override
            public void run() {
                next.invokeChannelActive();
            }
        });
    }
}

private void invokeChannelActive() {
    if (invokeHandler()) {
        try {
            ((ChannelInboundHandler) handler()).channelActive(this);
        } catch (Throwable t) {
            invokeExceptionCaught(t);
        }
    } else {
        fireChannelActive();
    }
}

private boolean invokeHandler() {
    int handlerState = this.handlerState; // handlerState为volatile变量，存储为本地变量，以便减少volatile读
    return handlerState == ADD_COMPLETE || (!ordered && handlerState == ADD_PENDING);
}
```

首先，netty为了确保线程的安全性，将确保该操作在reactor线程中被执行，head的handlerState是`INIT`，`invokeHandler()`返回接false，这里的head直接调用 `AbstractChannelHandlerContext.channelActive()`方法。

这就是说`invokeHandler()`保证了，当一个处理器还没有调用HandlerAdded方法时，只有处理器的执行线程是非顺序线程池的实例才能执行业务处理逻辑；否则必须等待已调用handlerAdded方法，才能处理业务逻辑。这个方法保证了ChannelPipeline的线程安全性，由此用户可以随意增加删除Handler。

```java
// AbstractChannelHandlerContext.java
@Override
public ChannelHandlerContext fireChannelActive() {
    invokeChannelActive(findContextInbound(MASK_CHANNEL_ACTIVE));
    return this;
}
```

首先，调用 `findContextInbound()` 找到下一个inbound节点，由于当前pipeline的双向链表结构中既有inbound节点，又有outbound节点，让我们看看netty是怎么找到下一个inBound节点的。

```java
// AbstractChannelHandlerContext.java
// 因为pipeline是个职责链，它需要判断当前的method是否被允许执行。使用 (ctx.executionMask & mask) == 0 来表示当前是否被禁止调用。如果是的话，则忽略，继续迭代，直到找到允许被调用的 handler
private AbstractChannelHandlerContext findContextInbound(int mask) {
    AbstractChannelHandlerContext ctx = this;
    EventExecutor currentExecutor = executor();
    do {
        ctx = ctx.next;
    } while (skipContext(ctx, currentExecutor, mask, MASK_ONLY_INBOUND)); // 如果下一个Handler的某个事件，标注@Skip的会被跳过 继续寻找下一个
    return ctx;
}

// 表示会跳过执行
private static boolean skipContext(
        AbstractChannelHandlerContext ctx, EventExecutor currentExecutor, int mask, int onlyMask) {
    return (ctx.executionMask & (onlyMask | mask)) == 0 ||
            (ctx.executor() == currentExecutor && (ctx.executionMask & mask) == 0); // (ctx.executionMask & mask) == 0表示当前是否被禁止调用
}

```

这段代码很清楚地表明，netty寻找下一个inBound节点的过程是一个线性搜索的过程，它遍历双向链表的下一个节点，通过`skipContext`判断是否需要跳过，直到找到下一个inBound类型的节点。

找到下一个节点之后，执行 `invokeChannelActive(next);`，一个递归调用，直到最后一个inBound节点——tail节点。

```java
// TailContext.java
@Override
public void channelActive(ChannelHandlerContext ctx) {
    onUnhandledInboundChannelActive();
}

protected void onUnhandledInboundChannelActive() {
}
```

Tail节点的该方法为空，结束调用，同理，可以分析所有的inBound事件的传播，正常情况下，即用户如果不覆盖每个节点的事件传播操作，几乎所有的事件最后都落到tail节点，所以，我们有必要研究一下tail节点所具有的功能。

## pipeline中的tail

```java
// 注意：TailContext 是 ChannelInboundHandler
// A special catch-all handler that handles both bytes and messages. 用于向用户抛出pipeline中未处理异常以及对未处理消息的警告
final class TailContext extends AbstractChannelHandlerContext implements ChannelInboundHandler {

    TailContext(DefaultChannelPipeline pipeline) {
        super(pipeline, null, TAIL_NAME, TailContext.class); // executor传入null
        setAddComplete();
    }

    @Override
    public ChannelHandler handler() {
        return this;
    }

    @Override
    public void channelRegistered(ChannelHandlerContext ctx) { }

    @Override
    public void channelUnregistered(ChannelHandlerContext ctx) { }

    @Override
    public void channelActive(ChannelHandlerContext ctx) {
        onUnhandledInboundChannelActive();
    }

    @Override
    public void channelInactive(ChannelHandlerContext ctx) {
        onUnhandledInboundChannelInactive();
    }

    @Override
    public void channelWritabilityChanged(ChannelHandlerContext ctx) {
        onUnhandledChannelWritabilityChanged();
    }

    @Override
    public void handlerAdded(ChannelHandlerContext ctx) { }

    @Override
    public void handlerRemoved(ChannelHandlerContext ctx) { }

    @Override
    public void userEventTriggered(ChannelHandlerContext ctx, Object evt) {
        onUnhandledInboundUserEventTriggered(evt);
    }

    @Override
    public void exceptionCaught(ChannelHandlerContext ctx, Throwable cause) {
        onUnhandledInboundException(cause);
    }

    @Override
    public void channelRead(ChannelHandlerContext ctx, Object msg) {
        onUnhandledInboundMessage(ctx, msg);
    }

    @Override
    public void channelReadComplete(ChannelHandlerContext ctx) {
        onUnhandledInboundChannelReadComplete();
    }
}
```

正如我们前面所提到的，tail节点的大部分作用即终止事件的传播(方法体为空)，除此之外，有两个重要的方法我们必须提一下，`exceptionCaught()`和`channelRead()`。

```java
// TailContext.java
protected void onUnhandledInboundException(Throwable cause) {
    try {
        logger.warn(
                "An exceptionCaught() event was fired, and it reached at the tail of the pipeline. " +
                        "It usually means the last handler in the pipeline did not handle the exception.",
                cause);
    } finally {
        ReferenceCountUtil.release(cause);
    }
}
```

异常传播的机制和inBound事件传播的机制一样，最终如果用户自定义节点没有处理的话，会落到tail节点，tail节点可不会简单地吞下这个异常，而是向你发出警告，相信使用netty的同学对这段警告不陌生吧？

```java
// TailContext.java
protected void onUnhandledInboundMessage(ChannelHandlerContext ctx, Object msg) {
    onUnhandledInboundMessage(msg);
    if (logger.isDebugEnabled()) {
        logger.debug("Discarded message pipeline : {}. Channel : {}.",
                     ctx.pipeline().names(), ctx.channel());
    }
}

protected void onUnhandledInboundMessage(Object msg) {
    try {
        logger.debug(
                "Discarded inbound message {} that reached at the tail of the pipeline. " +
                        "Please check your pipeline configuration.", msg);
    } finally {
        ReferenceCountUtil.release(msg);
    }
}
```

另外，tail节点在发现字节数据(ByteBuf)或者decoder之后的业务对象在pipeline流转过程中没有被消费，落到tail节点，tail节点就会给你发出一个警告，告诉你，我已经将你未处理的数据给丢掉了。

总结一下，tail节点的作用就是结束事件传播，并且对一些重要的事件做一些善意提醒。

## pipeline中的outBound事件传播

上一节中，我们在阐述tail节点的功能时，忽略了其父类`AbstractChannelHandlerContext`所具有的功能，这一节中，我们以最常见的writeAndFlush操作来看下pipeline中的outBound事件是如何向外传播的。

典型的消息推送系统中，会有类似下面的一段代码：

```java
// 用户代码
Channel channel = getChannel(userInfo);
channel.writeAndFlush(pushInfo);
```

这段代码的含义就是根据用户信息拿到对应的Channel，然后给用户推送消息。跟进 `AbstractChannel.writeAndFlush`。

```java
// AbstractChannel.java
@Override
public ChannelFuture writeAndFlush(Object msg) {
    return pipeline.writeAndFlush(msg);
}
```

从pipeline开始往外传播。

```java
// DefaultChannelPipeline.java
public final ChannelFuture writeAndFlush(Object msg) {
    return tail.writeAndFlush(msg);
}
```

Channel 中大部分outBound事件都是从tail开始往外传播, `writeAndFlush()`方法是tail继承而来的方法，我们跟进去。

```java
// AbstractChannelHandlerContext.java
@Override
public ChannelFuture writeAndFlush(Object msg) {
    return writeAndFlush(msg, newPromise());
}

@Override
public ChannelPromise newPromise() {
    return new DefaultChannelPromise(channel(), executor());
}

@Override
public ChannelFuture writeAndFlush(Object msg, ChannelPromise promise) {
    write(msg, true, promise);
    return promise;
}
```

这里提前说一点，netty中很多io操作都是异步操作，返回一个`ChannelFuture`给调用方，调用方拿到这个future可以在适当的时机拿到操作的结果，或者注册回调，这里就带过了，我们继续。

```java
// AbstractChannelHandlerContext.java
private void write(Object msg, boolean flush, ChannelPromise promise) {
		...
    // 找到下一个 handlerContext
    final AbstractChannelHandlerContext next = findContextOutbound(flush ?
            (MASK_WRITE | MASK_FLUSH) : MASK_WRITE);
    // 引用计数用的，用来监测内存泄露
    final Object m = pipeline.touch(msg, next);
    EventExecutor executor = next.executor();
    if (executor.inEventLoop()) {
        if (flush) {
            next.invokeWriteAndFlush(m, promise);
        } else {
            next.invokeWrite(m, promise);
        }
    } else {
        final WriteTask task = WriteTask.newInstance(next, m, promise, flush); // 用户线程调用
        if (!safeExecute(executor, task, promise, m, !flush)) {
            task.cancel();
        }
    }
}
```

netty为了保证程序的高效执行，所有的核心的操作都在reactor线程中处理。如果业务线程调用Channel的读写方法，netty会将该操作封装成一个task，随后在reactor线程中执行，参考 《netty源码分析之揭开reactor线程的面纱》，异步task的执行。

这里我们为了不跑偏，假设是在reactor线程中(上面的这段例子其实是在业务线程中)，先调用`findContextOutbound()`方法找到下一个`outBound()`节点（同inBound事件传播中的`findContextInbound()`类似）。

```java
// AbstractChannelHandlerContext.java
private AbstractChannelHandlerContext findContextOutbound(int mask) {
    AbstractChannelHandlerContext ctx = this;
    EventExecutor currentExecutor = executor();
    do {
        ctx = ctx.prev;
    } while (skipContext(ctx, currentExecutor, mask, MASK_ONLY_OUTBOUND)); // 如果上一个Handler的某个事件，标注@Skip的会被跳过 继续寻找下一个
    return ctx;
}
// 表示会跳过执行
private static boolean skipContext(
        AbstractChannelHandlerContext ctx, EventExecutor currentExecutor, int mask, int onlyMask) {
    // Ensure we correctly handle MASK_EXCEPTION_CAUGHT which is not included in the MASK_EXCEPTION_CAUGHT
    return (ctx.executionMask & (onlyMask | mask)) == 0 ||
            // We can only skip if the EventExecutor is the same as otherwise we need to ensure we offload
            // everything to preserve ordering.
            //
            // See https://github.com/netty/netty/issues/10067
            (ctx.executor() == currentExecutor && (ctx.executionMask & mask) == 0); // (ctx.executionMask & mask) == 0表示当前是否被禁止调用
```

回到主线，找到下一个`outBound()`节点后，然后调用`next.invokeWriteAndFlush(m, promise)`。

```java
// AbstractChannelHandlerContext.java
void invokeWriteAndFlush(Object msg, ChannelPromise promise) {
    if (invokeHandler()) {
        invokeWrite0(msg, promise);
        invokeFlush0();
    } else {
        writeAndFlush(msg, promise);
    }
}

private void invokeWrite0(Object msg, ChannelPromise promise) {
    try {
        ((ChannelOutboundHandler) handler()).write(this, msg, promise);
    } catch (Throwable t) {
        notifyOutboundHandlerException(t, promise);
    }
}
```

调用该节点的ChannelHandler的write方法，flush方法我们暂且忽略，后面会专门讲writeAndFlush的完整流程。

我们在使用outBound类型的ChannelHandler中，一般会继承 `ChannelOutboundHandlerAdapter`，所以，我们需要看看他的 `write`方法是怎么处理outBound事件传播的。

```java
// ChannelOutboundHandlerAdapter.java
@Skip
@Override
public void write(ChannelHandlerContext ctx, Object msg, ChannelPromise promise) throws Exception {
    ctx.write(msg, promise);
}
```

很简单，他除了递归调用 `ctx.write(msg, promise);`之外，啥事也没干，在《netty源码分析之pipeline》我们已经知道，pipeline的双向链表结构中，最后一个outBound节点是head节点，因此数据最终会落地到head的write方法。

```java
// HeadContext.java
public void write(ChannelHandlerContext ctx, Object msg, ChannelPromise promise) throws Exception {
    unsafe.write(msg, promise);
}
```

这里，加深了我们对head节点的理解，即所有的数据写出都会经过head节点。

实际情况下，outBound类的节点中会有一种特殊类型的节点叫encoder，它的作用是根据自定义编码规则将业务对象转换成ByteBuf，而这类encoder 一般继承自 `MessageToByteEncoder`。

下面是一段：

```java
// 用户代码
public abstract class DataPacketEncoder extends MessageToByteEncoder<DatePacket> {

    @Override
    protected void encode(ChannelHandlerContext ctx, DatePacket msg, ByteBuf out) throws Exception {
        // 这里拿到业务对象msg的数据，然后调用 out.writeXXX()系列方法编码
    }
}
```

为什么业务代码只需要覆盖这里的encod方法，就可以将业务对象转换成字节流写出去呢？通过前面的调用链条，我们需要查看一下其父类`MessageToByteEncoder`的write方法是怎么处理业务对象的

```java
// MessageToByteEncoder.java
@Override
public void write(ChannelHandlerContext ctx, Object msg, ChannelPromise promise) throws Exception {
    ByteBuf buf = null;
    try {
        if (acceptOutboundMessage(msg)) { // 需要判断当前编码器能否处理这类对象
            @SuppressWarnings("unchecked")
            I cast = (I) msg;
            buf = allocateBuffer(ctx, cast, preferDirect); // 分配内存
            try {
                encode(ctx, cast, buf);
            } finally {
                ReferenceCountUtil.release(cast); // 既然自定义java对象转换成ByteBuf了，那么这个对象就已经无用了，释放掉。(当传入的msg类型是ByteBuf的时候，就不需要自己手动释放了)
            }

            if (buf.isReadable()) { // buf到这里已经装载着数据，于是把该buf往前丢，直到head节点
                ctx.write(buf, promise);
            } else {
                buf.release();
                ctx.write(Unpooled.EMPTY_BUFFER, promise);
            }
            buf = null;
        } else {
            ctx.write(msg, promise); // 如果不能处理，就将outBound事件继续往前面传播
        }
    } catch (EncoderException e) {
        throw e;
    } catch (Throwable e) {
        throw new EncoderException(e);
    } finally {
        if (buf != null) {
            buf.release();
        }
    }
}
```

1. 调用 `acceptOutboundMessage` 方法判断，该encoder是否可以处理msg对应的类的对象。
2. 通过之后，就强制转换，这里的泛型I对应的是`DataPacket。`
3. 转换之后，先开辟一段内存，调用`encode()`，即回到`DataPacketEncoder`中，将buf装满数据。
4. 最后，如果buf中被写了数据(`buf.isReadable()`)，就将该buf往前丢，一直传递到head节点，被head节点的unsafe消费掉。

当然，如果当前encoder不能处理当前业务对象，就简单地将该业务对象向前传播，直到head节点，最后，都处理完之后，释放buf，避免堆外内存泄漏。

## pipeline 中异常的传播

我们通常在业务代码中，会加入一个异常处理器，统一处理pipeline过程中的所有的异常，并且，一般该异常处理器需要加载自定义节点的最末尾，即

<img src="http://blog-1259650185.cosbj.myqcloud.com/img/202112/01/1638360493.jpg" alt="pipeline中异常的传播"  />

此类ExceptionHandler一般继承自 `ChannelDuplexHandler`，标识该节点既是一个inBound节点又是一个outBound节点，我们分别分析一下inBound事件和outBound事件过程中，ExceptionHandler是如何才处理这些异常的。

### inBound异常的处理

我们以数据的读取为例，看下netty是如何传播在这个过程中发生的异常。

我们前面已经知道，对于每一个节点的数据读取都会调用`AbstractChannelHandlerContext.invokeChannelRead()`方法

```java
// AbstractChannelHandlerContext.java
private void invokeChannelRead(Object msg) {
    if (invokeHandler()) {
        try { // 执行 ChannelInboundHandler.channelRead()
            ((ChannelInboundHandler) handler()).channelRead(this, msg);
        } catch (Throwable t) {
            invokeExceptionCaught(t);
        }
    } else {
        fireChannelRead(msg);
    }
```

可以看到该节点最终委托到其内部的ChannelHandler处理channelRead，而在最外层catch整个Throwable，因此，我们在如下用户代码中的异常会被捕获：

```java
// 用户代码
public class BusinessHandler extends ChannelInboundHandlerAdapter {
    @Override
    protected void channelRead(ChannelHandlerContext ctx, Object data) throws Exception {
       //...
          throw new BusinessException(...); 
       //...
    }

}
```

上面这段业务代码中的 `BusinessException` 会被 `BusinessHandler`所在的节点捕获，进入到 `invokeExceptionCaught(t);`往下传播，我们看下它是如何传播的。

```java
// AbstractChannelHandlerContext.java
private void invokeExceptionCaught(final Throwable cause) {
    if (invokeHandler()) {
        try {
            handler().exceptionCaught(this, cause);
        } catch (Throwable error) {
						...
        }
    } else {
        fireExceptionCaught(cause);
    }
}
```

可以看到，此Hander中异常优先由此Handelr中的`exceptionCaught`方法来处理，默认情况下，如果不覆写此Handler中的`exceptionCaught`方法，调用`ChannelInboundHandlerAdapter.exceptionCaught()`。

```java
// ChannelInboundHandlerAdapter.java
@Skip
@Override
@Deprecated
public void exceptionCaught(ChannelHandlerContext ctx, Throwable cause) throws Exception {
    ctx.fireExceptionCaught(cause);
}

// AbstractChannelHandlerContext.java
@Override
public ChannelHandlerContext fireExceptionCaught(final Throwable cause) {
    invokeExceptionCaught(findContextInbound(MASK_EXCEPTION_CAUGHT), cause);
    return this;
}
```

到了这里，已经很清楚了，如果我们在自定义Handler中没有处理异常，那么默认情况下该异常将一直传递下去，遍历每一个节点，直到最后一个自定义异常处理器ExceptionHandler来终结，收编异常。

```java
// 用户代码
public Exceptionhandler extends ChannelDuplexHandler {
    @Override
    public void exceptionCaught(ChannelHandlerContext ctx, Throwable cause)
            throws Exception {
        // 处理该异常，并终止异常的传播
    }
}
```

到了这里，你应该知道为什么异常处理器要加在pipeline的最后了吧？

### outBound异常的处理

然而对于outBound事件传播过程中所发生的异常，该`Exceptionhandler`照样能完美处理，为什么？

我们以前面提到的`writeAndFlush`方法为例，来看看outBound事件传播过程中的异常最后是如何落到`Exceptionhandler`中去的。

前面我们知道，`channel.writeAndFlush()`方法最终也会调用到节点的 `invokeFlush0()`方法。

```java
// AbstractChannelHandlerContext.java
void invokeWriteAndFlush(Object msg, ChannelPromise promise) {
    if (invokeHandler()) {
        invokeWrite0(msg, promise);
        invokeFlush0();
    } else {
        writeAndFlush(msg, promise);
    }
}

private void invokeFlush0() {
    try {
        ((ChannelOutboundHandler) handler()).flush(this);
    } catch (Throwable t) {
        invokeExceptionCaught(t);
    }
}
```

而`invokeFlush0()`会委托其内部的ChannelHandler的flush方法，我们一般实现的即是ChannelHandler的flush方法。

好，假设在当前节点在flush的过程中发生了异常，都会被 `invokeExceptionCaught(t);`捕获，该方法会和inBound事件传播过程中的异常传播方法一样，也是轮流找下一个异常处理器，而如果异常处理器在pipeline最后面的话，一定会被执行到，这就是为什么该异常处理器也能处理outBound异常的原因。

关于为啥 `ExceptionHandler` 既能处理inBound，又能处理outBound类型的异常的原因，总结一点就是，在任何节点中发生的异常都会往下一个节点传递，最后终究会传递到异常处理器。

## 总结

最后，老样子，我们做下总结

1. 一个Channel对应一个Unsafe，Unsafe处理底层操作，NioServerSocketChannel对应NioMessageUnsafe, NioSocketChannel对应NioByteUnsafe。
2. inBound事件从head节点传播到tail节点，outBound事件从tail节点传播到head节点。
3. 异常传播只会往后传播，而且不分inbound还是outbound节点，不像outBound事件一样会往前传。

# 参考

[netty源码分析之pipeline(一)](https://www.jianshu.com/p/6efa9c5fa702)

[netty源码分析之pipeline(二)](https://www.jianshu.com/p/087b7e9a27a2)

[Netty 源码解析（四）: Netty 的 ChannelPipeline](https://javadoop.com/post/netty-part-4)

[自顶向下深入分析Netty（七）--ChannelPipeline和ChannelHandler总述](https://www.jianshu.com/p/7dc5da98694c)

[自顶向下深入分析Netty（七）--ChannelPipeline源码实现](https://www.jianshu.com/p/0e15165714fc)

[自顶向下深入分析Netty（七）--ChannelHandlerContext源码实现](https://www.jianshu.com/p/d1228b009aac)
