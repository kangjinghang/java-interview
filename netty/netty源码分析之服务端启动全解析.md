## background

netty 是一个异步事件驱动的网络通信层框架，其官方文档的解释为

> Netty is a NIO client server framework which enables quick and easy development of network applications such as protocol servers and clients. It greatly simplifies and streamlines network programming such as TCP and UDP socket server.

## why netty

netty底层基于jdk的NIO，我们为什么不直接基于jdk的nio或者其他nio框架？下面是我总结出来的原因：

1. 使用jdk自带的nio需要了解太多的概念，编程复杂
2. netty底层IO模型随意切换，而这一切只需要做微小的改动
3. netty自带的拆包解包，异常检测等机制让你从nio的繁重细节中脱离出来，让你只需要关心业务逻辑
4. netty解决了jdk的很多包括空轮训在内的bug
5. netty底层对线程，selector做了很多细小的优化，精心设计的reactor线程做到非常高效的并发处理
6. 自带各种协议栈让你处理任何一种通用协议都几乎不用亲自动手
7. netty社区活跃，遇到问题随时邮件列表或者issue
8. netty已经历各大rpc框架，消息中间件，分布式通信中间件线上的广泛验证，健壮性无比强大

## dive into netty

了解了这么多，今天我们就从一个例子出来，开始我们的netty源码之旅。

本篇主要讲述的是netty是如何绑定端口，启动服务。启动服务的过程中，你将会了解到netty各大核心组件，我先不会细讲这些组件，而是会告诉你各大组件是怎么串起来组成netty的核心。

### example

下面是一个非常简单的服务端启动代码

```java
public final class SimpleServer {

    public static void main(String[] args) throws Exception {
        EventLoopGroup bossGroup = new NioEventLoopGroup(1);
        EventLoopGroup workerGroup = new NioEventLoopGroup();

        try {
            ServerBootstrap b = new ServerBootstrap();
            b.group(bossGroup, workerGroup)
                    .channel(NioServerSocketChannel.class)
                    .handler(new SimpleServerHandler())
                    .childHandler(new ChannelInitializer<SocketChannel>() {
                        @Override
                        public void initChannel(SocketChannel ch) throws Exception {
                        }
                    });

            ChannelFuture f = b.bind(8888).sync();

            f.channel().closeFuture().sync();
        } finally {
            bossGroup.shutdownGracefully();
            workerGroup.shutdownGracefully();
        }
    }

    private static class SimpleServerHandler extends ChannelInboundHandlerAdapter {
        @Override
        public void channelActive(ChannelHandlerContext ctx) throws Exception {
            System.out.println("channelActive");
        }

        @Override
        public void channelRegistered(ChannelHandlerContext ctx) throws Exception {
            System.out.println("channelRegistered");
        }

        @Override
        public void handlerAdded(ChannelHandlerContext ctx) throws Exception {
            System.out.println("handlerAdded");
        }
    }
}
```

简单的几行代码就能开启一个服务端，端口绑定在8888，使用nio模式，下面讲下每一个步骤的处理细节：

- `EventLoopGroup` 说白了，就是一个死循环，不停地检测IO事件，处理IO事件，执行任务
- `ServerBootstrap` 是服务端的一个启动辅助类，通过给他设置一系列参数来绑定端口启动服务
- `group(bossGroup, workerGroup)` 我们需要两种类型的人干活，一个是老板，一个是工人，老板负责从外面接活，接到的活分配给工人干，放到这里，`bossGroup`的作用就是不断地accept到新的连接，将新的连接丢给`workerGroup`来处理
- `.channel(NioServerSocketChannel.class)` 表示服务端启动的是nio相关的channel，channel在netty里面是一大核心概念，可以理解为一条channel就是一个连接或者一个服务端bind动作，后面会细说
- `.handler(new SimpleServerHandler()` 表示服务器启动过程中，需要经过哪些流程，这里`SimpleServerHandler`最终的顶层接口为`ChannelHander`，是netty的一大核心概念，表示数据流经过的处理器，可以理解为流水线上的每一道关卡
- `childHandler(new ChannelInitializer<SocketChannel>)...`表示一条新的连接进来之后，该怎么处理，也就是上面所说的，老板如何给工人配活
- `ChannelFuture f = b.bind(8888).sync();` 这里就是真正的启动过程了，绑定8888端口，等待服务器启动完毕，才会进入下行代码
- `f.channel().closeFuture().sync();` 等待服务端关闭socket
- `bossGroup.shutdownGracefully(); workerGroup.shutdownGracefully();` 关闭两组死循环

上述代码可以很轻松地再本地跑起来，最终控制台的输出为：

```
handlerAdded
channelRegistered
channelActive
```

### 深入细节

`ServerBootstrap` 一系列的参数配置其实没啥好讲的，无非就是使用[method chaining](https://links.jianshu.com/go?to=https%3A%2F%2Fen.wikipedia.org%2Fwiki%2FMethod_chaining%23Java)的方式将启动服务器需要的参数保存到filed。我们的重点落入到下面这段代码：

```java
b.bind(8888).sync();
```

我们跟进去，分析

```java
// AbstractBootstrap.java
public ChannelFuture bind(int inetPort) {
    return bind(new InetSocketAddress(inetPort));
} 

public ChannelFuture bind(SocketAddress localAddress) {
    validate();
    return doBind(ObjectUtil.checkNotNull(localAddress, "localAddress"));
}
```

`validate()` 验证服务启动需要的必要参数，然后调用`doBind()`

```java
// AbstractBootstrap.java
// 3步，第一步创建，第二步 init ，第三步 register 到selector
private ChannelFuture doBind(final SocketAddress localAddress) {
    final ChannelFuture regFuture = initAndRegister();
    final Channel channel = regFuture.channel();
    if (regFuture.cause() != null) {
        return regFuture;
    }
    // 不能肯定register完成，因为register是丢到 nio event loop 里面执行去了
    if (regFuture.isDone()) {
        // At this point we know that the registration was complete and successful.
        ChannelPromise promise = channel.newPromise();
        doBind0(regFuture, channel, localAddress, promise);
        return promise;
    } else {
        // Registration future is almost always fulfilled already, but just in case it's not.
        final PendingRegistrationPromise promise = new PendingRegistrationPromise(channel);
        // 不能完成的话，则封装成一个 task，等着 register 完成来通知再执行 bind
        regFuture.addListener(new ChannelFutureListener() {
            @Override
            public void operationComplete(ChannelFuture future) throws Exception {
                Throwable cause = future.cause();
                if (cause != null) {
                    promise.setFailure(cause);
                } else {
                    promise.registered();

                    doBind0(regFuture, channel, localAddress, promise);
                }
            }
        });
        return promise;
    }
}
```

其实，从方法名上面我们已经可以略窥一二，init->初始化，register->注册，那么到底要注册到什么呢？联系到nio里面轮询器的注册，可能是把某个东西初始化好了之后注册到selector上面去，最后bind，像是在本地绑定端口号，带着这些猜测，我们深入下去

#### initAndRegister()

```java
// AbstractBootstrap.java
final ChannelFuture initAndRegister() {
    Channel channel = null;
    try {
        // 反射加工厂创建channel，比如 nioServerSocketChannel
        channel = channelFactory.newChannel();
        init(channel); // 初始化
    } catch (Throwable t) {
        if (channel != null) {
            channel.unsafe().closeForcibly();
            return new DefaultChannelPromise(channel, GlobalEventExecutor.INSTANCE).setFailure(t);
        }
        return new DefaultChannelPromise(new FailedChannel(), GlobalEventExecutor.INSTANCE).setFailure(t);
    }
    // 开始 register
    ChannelFuture regFuture = config().group().register(channel);
    if (regFuture.cause() != null) {
        if (channel.isRegistered()) {
            channel.close();
        } else {
            channel.unsafe().closeForcibly();
        }
    }

    return regFuture;
}
```

我们还是专注于核心代码，抛开边角料，我们看到 `initAndRegister()` 做了几件事情：

1. new一个channel
2. init这个channel
3. 将这个channel register到某个对象

我们逐步分析这三件事情。

##### 1.new一个channel

我们首先要搞懂channel的定义，netty官方对channel的描述如下

> A nexus to a network socket or a component which is capable of I/O operations such as read, write, connect, and bind

这里的channel，由于是在服务启动的时候创建，我们可以和普通Socket编程中的ServerSocket对应上，表示服务端绑定的时候经过的一条流水线。

我们发现这条channel是通过一个 `channelFactory` new出来的，`channelFactory` 的接口很简单。

```java
public interface ChannelFactory<T extends Channel> {
    /**
     * Creates a new channel.
     */
    T newChannel();
}
```

就一个方法，我们查看channelFactory被赋值的地方

```java
// AbstractBootstrap.java
public B channelFactory(ChannelFactory<? extends C> channelFactory) {
    ObjectUtil.checkNotNull(channelFactory, "channelFactory");
    if (this.channelFactory != null) {
        throw new IllegalStateException("channelFactory set already");
    }

    this.channelFactory = channelFactory;
    return self();
}
```

在这里被赋值，我们层层回溯，查看该函数被调用的地方，发现最终是在这个函数中，ChannelFactory被new出。

```java
// AbstractBootstrap.java
public B channel(Class<? extends C> channelClass) {
    return channelFactory(new ReflectiveChannelFactory<C>(
            ObjectUtil.checkNotNull(channelClass, "channelClass")
    ));
}
```

这里，我们的demo程序调用`channel(channelClass)`方法的时候，将`channelClass`作为`ReflectiveChannelFactory`的构造函数创建出一个`ReflectiveChannelFactory`。

demo端的代码如下：

```java
.channel(NioServerSocketChannel.class);
```

然后回到本节最开始

```java
channelFactory.newChannel();
```

我们就可以推断出，最终是调用到 `ReflectiveChannelFactory.newChannel()` 方法，跟进。

```java
// ReflectiveChannelFactory.java
public class ReflectiveChannelFactory<T extends Channel> implements ChannelFactory<T> {

    private final Class<? extends T> clazz;

    public ReflectiveChannelFactory(Class<? extends T> clazz) {
        if (clazz == null) {
            throw new NullPointerException("clazz");
        }
        this.clazz = clazz;
    }

    @Override
    public T newChannel() {
        try {
            return clazz.newInstance();
        } catch (Throwable t) {
            throw new ChannelException("Unable to create Channel from class " + clazz, t);
        }
    }
}
```

看到`clazz.newInstance();`，我们明白了，原来是通过反射的方式来创建一个对象，而这个class就是我们在`ServerBootstrap`中传入的`NioServerSocketChannel.class`。

结果，绕了一圈，最终创建channel相当于调用默认构造函数new出一个 `NioServerSocketChannel`对象。

接下来我们就可以将重心放到 `NioServerSocketChannel`的默认构造函数。

```java
// NioServerSocketChannel.java
private static final SelectorProvider DEFAULT_SELECTOR_PROVIDER = SelectorProvider.provider();

public NioServerSocketChannel() {
    this(newSocket(DEFAULT_SELECTOR_PROVIDER));
}

private static ServerSocketChannel newSocket(SelectorProvider provider) {
    //...
    return provider.openServerSocketChannel();
}
```

通过`SelectorProvider.openServerSocketChannel()`创建一条server端channel，然后进入到以下方法。

```java
// NioServerSocketChannel.java
public NioServerSocketChannel(ServerSocketChannel channel) {
    super(null, channel, SelectionKey.OP_ACCEPT);
    config = new NioServerSocketChannelConfig(this, javaChannel().socket());
}
```

这里第一行代码就跑到父类里面去了，第二行，new出来一个 `NioServerSocketChannelConfig`，其顶层接口为 `ChannelConfig`，netty官方的描述如下：

> A set of configuration properties of a Channel.

基本可以判定，`ChannelConfig` 也是netty里面的一大核心模块，初次看源码，看到这里，我们大可不必深挖这个对象，而是在用到的时候再回来深究，只要记住，这个对象在创建`NioServerSocketChannel`对象的时候被创建即可。

我们继续追踪到 `NioServerSocketChannel` 的父类。

```java
// AbstractNioMessageChannel.java
protected AbstractNioMessageChannel(Channel parent, SelectableChannel ch, int readInterestOp) {
    super(parent, ch, readInterestOp);
}
```

继续往上追。

```java
// AbstractNioChannel.java
protected AbstractNioChannel(Channel parent, SelectableChannel ch, int readInterestOp) {
    super(parent);
    this.ch = ch;
    this.readInterestOp = readInterestOp;
    try {
        ch.configureBlocking(false);
    } catch (IOException e) {
				...
    }
}
```

这里，简单地将前面 `provider.openServerSocketChannel();` 创建出来的 `ServerSocketChannel` 保存到成员变量，然后调用`ch.configureBlocking(false);`设置该channel为非阻塞模式，标准的jdk nio编程的玩法。

这里的 `readInterestOp` 即前面层层传入的 `SelectionKey.OP_ACCEPT`，接下来重点分析 `super(parent);`(这里的parent其实是null，由前面写死传入)。

```java
// AbstractChannel.java
protected AbstractChannel(Channel parent) {
    this.parent = parent;
    id = newId();
    unsafe = newUnsafe();
    pipeline = newChannelPipeline();
}
```

到了这里，又new出来三大组件，赋值到成员变量，分别为：

```java
// AbstractChannel.java
id = newId();
protected ChannelId newId() {
    return DefaultChannelId.newInstance();
}
```

id是netty中每条channel的唯一标识，这里不细展开，接着：

```java
// AbstractChannel.java
unsafe = newUnsafe();
protected abstract AbstractUnsafe newUnsafe();
```

查看Unsafe的定义：

> Unsafe operations that should never be called from user-code. These methods  are only provided to implement the actual transport, and must be invoked from an I/O thread

成功捕捉netty的又一大组件，我们可以先不用管TA是干嘛的，只需要知道这里的 `newUnsafe`方法最终属于类`NioServerSocketChannel`中。

最后：

```java
pipeline = newChannelPipeline();

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

初次看这段代码，可能并不知道 `DefaultChannelPipeline` 是干嘛用的，我们仍然使用上面的方式，查看顶层接口`ChannelPipeline`的定义：

> A list of ChannelHandlers which handles or intercepts inbound events and outbound operations of a Channel

从该类的文档中可以看出，该接口基本上又是netty的一大核心模块。

到了这里，我们总算把一个服务端channel创建完毕了，将这些细节串起来的时候，我们顺带提取出netty的几大基本组件，先总结如下：

- Channel
- ChannelConfig
- ChannelId
- Unsafe
- Pipeline
- ChannelHander

初次看代码的时候，我们的目标是跟到服务器启动的那一行代码，我们先把以上这几个组件记下来，等代码跟完，我们就可以自顶向下，逐层分析，我会放到后面源码系列中去深入到每个组件。

总结一下，用户调用方法 `Bootstrap.bind(port)` 第一步就是通过反射的方式new一个`NioServerSocketChannel`对象，并且在new的过程中创建了一系列的核心组件，仅此而已，并无他，真正的启动我们还需要继续跟。

##### 2.init这个channel

第一步newChannel完毕，这里就对这个channel做init，init方法具体干啥，我们深入。

```java
// ServerBootstrap.java
void init(Channel channel) {
    setChannelOptions(channel, newOptionsArray(), logger); // 初始化 option
    setAttributes(channel, newAttributesArray()); // 初始化 channel 的属性

    ChannelPipeline p = channel.pipeline(); // 构建一个 pipeline
    // 以上属性都是为了初始化 socketChannel 来使用的
    final EventLoopGroup currentChildGroup = childGroup;
    final ChannelHandler currentChildHandler = childHandler;
    final Entry<ChannelOption<?>, Object>[] currentChildOptions = newOptionsArray(childOptions);
    final Entry<AttributeKey<?>, Object>[] currentChildAttrs = newAttributesArray(childAttrs);
    // ChannelInitializer一次性，初始化handler
    // 负责添加一个ServerBootstrapAcceptor handler，添加完后，自己就移除了
    // ServerBootstrapAcceptor handler（Reactor模式的Acceptor）：负责接收客户端连接创建连接后，对连接的初始化工作。
    p.addLast(new ChannelInitializer<Channel>() {
        @Override
        public void initChannel(final Channel ch) {
            final ChannelPipeline pipeline = ch.pipeline();
            ChannelHandler handler = config.handler();
            if (handler != null) {
                pipeline.addLast(handler);
            }

            ch.eventLoop().execute(new Runnable() {
                @Override
                public void run() {
                    pipeline.addLast(new ServerBootstrapAcceptor( // Reactor模式的Acceptor
                            ch, currentChildGroup, currentChildHandler, currentChildOptions, currentChildAttrs));
                }
            });
        }
    });
}
```

###### 1.设置option

````java
// ServerBootstrap.java
void init(Channel channel) {
  ...
	setChannelOptions(channel, newOptionsArray(), logger); // 初始化 option
}
// AbstractBootstrap.java
private final Map<ChannelOption<?>, Object> options = new LinkedHashMap<ChannelOption<?>, Object>();

final Map.Entry<ChannelOption<?>, Object>[] newOptionsArray() {
    return newOptionsArray(options);
}

static Map.Entry<ChannelOption<?>, Object>[] newOptionsArray(Map<ChannelOption<?>, Object> options) {
    synchronized (options) {
        return new LinkedHashMap<ChannelOption<?>, Object>(options).entrySet().toArray(EMPTY_OPTION_ARRAY);
    }
}

static void setChannelOptions(
        Channel channel, Map.Entry<ChannelOption<?>, Object>[] options, InternalLogger logger) {
    for (Map.Entry<ChannelOption<?>, Object> e: options) {
        setChannelOption(channel, e.getKey(), e.getValue(), logger);
    }
}

private static void setChannelOption(
        Channel channel, ChannelOption<?> option, Object value, InternalLogger logger) {
    try {
        if (!channel.config().setOption((ChannelOption<Object>) option, value)) {
            logger.warn("Unknown channel option '{}' for channel '{}'", option, channel);
        }
    } catch (Throwable t) {
				...
    }
}
````

###### 2.设置attr

```java
// ServerBootstrap.java
void init(Channel channel) {
  ...
	setAttributes(channel, newAttributesArray()); // 初始化 channel 的属性
}
// AbstractBootstrap.java
private final Map<AttributeKey<?>, Object> attrs = new ConcurrentHashMap<AttributeKey<?>, Object>();

final Map<AttributeKey<?>, Object> attrs0() {
    return attrs;
}

static Map.Entry<AttributeKey<?>, Object>[] newAttributesArray(Map<AttributeKey<?>, Object> attributes) {
    return attributes.entrySet().toArray(EMPTY_ATTRIBUTE_ARRAY);
}

static void setAttributes(Channel channel, Map.Entry<AttributeKey<?>, Object>[] attrs) {
    for (Map.Entry<AttributeKey<?>, Object> e: attrs) {
        @SuppressWarnings("unchecked")
        AttributeKey<Object> key = (AttributeKey<Object>) e.getKey();
        channel.attr(key).set(e.getValue());
    }
}
```

首先通过`newOptionsArray()`和` newAttributesArray()`初始化option和attr，然后将得到的options和attrs注入到channelConfig或者channel中，关于option和attr是干嘛用的，其实你现在不用了解得那么深入，只需要查看最顶层接口`ChannelOption`以及查看一下channel的具体继承关系，就可以了。

###### 3.设置新接入channel的option和attr

```java
// ServerBootstrap.java
private final Map<ChannelOption<?>, Object> childOptions = new LinkedHashMap<ChannelOption<?>, Object>();
private final Map<AttributeKey<?>, Object> childAttrs = new ConcurrentHashMap<AttributeKey<?>, Object>();
private volatile EventLoopGroup childGroup;
private volatile ChannelHandler childHandler;

void init(Channel channel) {
  ...
  final EventLoopGroup currentChildGroup = childGroup;
	final ChannelHandler currentChildHandler = childHandler;
	final Entry<ChannelOption<?>, Object>[] currentChildOptions = newOptionsArray(childOptions);
	final Entry<AttributeKey<?>, Object>[] currentChildAttrs = newAttributesArray(childAttrs);
  ...
}

// AbstractBootstrap.java
static Map.Entry<ChannelOption<?>, Object>[] newOptionsArray(Map<ChannelOption<?>, Object> options) {
    synchronized (options) {
        return new LinkedHashMap<ChannelOption<?>, Object>(options).entrySet().toArray(EMPTY_OPTION_ARRAY);
    }
}

static Map.Entry<AttributeKey<?>, Object>[] newAttributesArray(Map<AttributeKey<?>, Object> attributes) {
    return attributes.entrySet().toArray(EMPTY_ATTRIBUTE_ARRAY);
}
```

和上面类似，只不过不是设置当前server socket channel的这两个属性，而是对应到新进来连接对应的socket channel。

###### 4.加入新连接处理器

```java
// ChannelInitializer一次性，初始化handler
// 负责添加一个ServerBootstrapAcceptor handler，添加完后，自己就移除了
// ServerBootstrapAcceptor handler（Reactor模式的Acceptor）：负责接收客户端连接创建连接后，对连接的初始化工作。
p.addLast(new ChannelInitializer<Channel>() {
    @Override
    public void initChannel(final Channel ch) {
        final ChannelPipeline pipeline = ch.pipeline();
        ChannelHandler handler = config.handler();
        if (handler != null) {
            pipeline.addLast(handler);
        }

        ch.eventLoop().execute(new Runnable() {
            @Override
            public void run() {
                pipeline.addLast(new ServerBootstrapAcceptor( // Reactor模式的Acceptor
                        ch, currentChildGroup, currentChildHandler, currentChildOptions, currentChildAttrs));
            }
        });
    }
});	
```

到了最后一步，`p.addLast()`向serverChannel的流水线处理器中加入了一个 `ServerBootstrapAcceptor`，从名字上就可以看出来，这是一个接入器，专门接受新请求，把新的请求扔给某个事件循环器，我们先不做过多分析。

##### 3.将这个channel register到某个对象

这一步，我们是分析如下方法。

```java
// AbstractBootstrap.java
final ChannelFuture initAndRegister() {
		...
    // 开始 register
    ChannelFuture regFuture = config().group().register(channel);
    if (regFuture.cause() != null) {
        if (channel.isRegistered()) {
            channel.close();
        } else {
            channel.unsafe().closeForcibly();
        }
    }

    return regFuture;
}
```

调用到 `SingleThreadEventLoop` 中的`register`。

```java
// SingleThreadEventLoop.java
@Override
public ChannelFuture register(Channel channel) {
    return register(new DefaultChannelPromise(channel, this));
}

@Override
public ChannelFuture register(final ChannelPromise promise) {
    ObjectUtil.checkNotNull(promise, "promise");
  	// promise 关联了 channel，channel 持有 Unsafe 实例，register 操作就封装在 Unsafe 中
    promise.channel().unsafe().register(this, promise);
    return promise;
}
```

好了，到了这一步，还记得这里的`unsafe()`返回的应该是什么对象吗？不记得的话可以看下前面关于unsafe的描述，或者最快的方式就是debug到这边，跟到register方法里面，看看是哪种类型的unsafe。

我们跟进去之后发现是`AbstractUnsafe`

```java
// AbstractUnsafe.java
@Override
public final void register(EventLoop eventLoop, final ChannelPromise promise) {
		...
		// 将这个 eventLoop 实例设置给这个 channel，从此这个 channel 就是有 eventLoop 的了，这一步其实挺关键的，因为后续该 channel 中的所有异步操作，都要提交给这个 eventLoop 来执行
    AbstractChannel.this.eventLoop = eventLoop;
    // 判断自己的线程（currentThread）是不是 nioEventLoop 里的线程，比如注册的时候，currentThread 是 main thead
    if (eventLoop.inEventLoop()) {
      	// 对于我们来说，它不会进入到这个分支，之所以有这个分支，是因为我们是可以 unregister，然后再 register 的，后面再仔细看
        register0(promise);
    } else {
        try {
            eventLoop.execute(new Runnable() { // 封装成一个 task 放到 eventLoop 中，eventLoop 中的线程会负责调用 register0(promise)
                @Override
                public void run() {
                    register0(promise);
                }
            });
        } catch (Throwable t) {
						...
        }
    }
}
```

> 到这里，我们要明白，NioEventLoop 中是还没有实例化 Thread 实例的。	
>
> 对于我们前面过来的 register 操作，其实提交到 eventLoop 以后，就直接返回 promise 实例了，剩下的**register0 是异步操作，它由 NioEventLoop 实例来完成**。
>
> Channel 实例一旦 register 到了 NioEventLoopGroup 实例中的某个 NioEventLoop 实例，那么后续该 Channel 的所有操作，都是由该 NioEventLoop 实例来完成的。
>
> 这个也非常简单，因为 Selector 实例是在 NioEventLoop 实例中的，Channel 实例一旦注册到某个 Selector 实例中，当然也只能在这个实例中处理 NIO 事件。

这里我们依然只需要focus重点，先将EventLoop事件循环器绑定到该NioServerSocketChannel上，然后调用 `register0()`。

```java
// AbstractChannel.java
private void register0(ChannelPromise promise) {
    try {
        if (!promise.setUncancellable() || !ensureOpen(promise)) {
            return;
        }
        boolean firstRegistration = neverRegistered;
        doRegister(); //进行 JDK 底层的操作：Channel 注册到 Selector 上
        neverRegistered = false;
        registered = true; // 到这里，就算是 registered 了

        pipeline.invokeHandlerAddedIfNeeded();
			  // 设置当前 promise 的状态为 success，因为当前 register 方法是在 eventLoop 中的线程中执行的，需要通知提交 register 操作的线程
        safeSetSuccess(promise);
     		 // 当前的 register 操作已经成功，该事件应该被 pipeline 上所有关心 register 事件的 handler 感知到，往 pipeline 中扔一个事件
        pipeline.fireChannelRegistered();
        // server socket 的注册不会走进下面的 if，server socket接受连接创建的socket可以走进去，因为 accept 后就 active 了
        if (isActive()) {
            if (firstRegistration) {
              	// 如果该 channel 是第一次执行 register，那么 fire ChannelActive 事件
                pipeline.fireChannelActive();
            } else if (config().isAutoRead()) {
              	// 该 channel 之前已经 register 过了，这里让该 channel 立马去监听通道中的 OP_READ 事件
                beginRead();
            }
        }
    } catch (Throwable t) {
				...
    }
}

// AbstractNioChannel.java
@Override
protected void doRegister() throws Exception {
    boolean selected = false;
    for (;;) {
        try { // 调用 JDK 的 API，将 channel 注册到 nioEventLoop 里绑定的 selector ，ops = 0 ，
            selectionKey = javaChannel().register(eventLoop().unwrappedSelector(), 0, this);
            return;
        } catch (CancelledKeyException e) {
					...
        }
    }
}
```

这一段其实也很清晰，先调用 `doRegister();`，具体干啥待会再讲，然后调用`invokeHandlerAddedIfNeeded()`, 于是乎，控制台第一行打印出来的就是。

```java
handlerAdded
```

关于最终是如何调用到的，我们后面详细剖析pipeline的时候再讲。

然后调用 `pipeline.fireChannelRegistered();` 我们来看看这句代码会发生什么：

```java
// DefaultChannelPipeline
@Override
public final ChannelPipeline fireChannelRegistered() {
    // 注意这里的传参是 head
    AbstractChannelHandlerContext.invokeChannelRegistered(head);
    return this;
}
```

也就是说，我们往 pipeline 中扔了一个 **channelRegistered** 事件，这里的 register 属于 Inbound 事件，pipeline 接下来要做的就是执行 pipeline 中的 Inbound 类型的 handlers 中的 channelRegistered() 方法。

从上面的代码，我们可以看出，往 pipeline 中扔出 channelRegistered 事件以后，第一个处理的 handler 是 **head**。

接下来，我们还是跟着代码走，此时我们来到了 pipeline 的第一个节点 **head** 的处理中：

```java
// AbstractChannelHandlerContext
// next 此时是 head
static void invokeChannelRegistered(final AbstractChannelHandlerContext next) {

    EventExecutor executor = next.executor();
    // 执行 head 的 invokeChannelRegistered()
    if (executor.inEventLoop()) {
        next.invokeChannelRegistered();
    } else {
        executor.execute(new Runnable() {
            @Override
            public void run() {
                next.invokeChannelRegistered();
            }
        });
    }
}
```

也就是说，这里会先执行 head.invokeChannelRegistered() 方法，而且是放到 NioEventLoop 中的 taskQueue 中执行的：

```java
// AbstractChannelHandlerContext
private void invokeChannelRegistered() {
    if (invokeHandler()) {
        try {
            // handler() 方法此时会返回 head
            ((ChannelInboundHandler) handler()).channelRegistered(this);
        } catch (Throwable t) {
            notifyHandlerException(t);
        }
    } else {
        fireChannelRegistered();
    }
}
```

我们去看 head 的 channelRegistered 方法：

```java
// HeadContext
@Override
public void channelRegistered(ChannelHandlerContext ctx) throws Exception {
    // 1. 这一步是 head 对于 channelRegistered 事件的处理。没有我们要关心的
    invokeHandlerAddedIfNeeded();
    // 2. 向后传播 Inbound 事件
    ctx.fireChannelRegistered();
}
```

然后 head 会执行 fireChannelRegister() 方法：

```java
// AbstractChannelHandlerContext
@Override
public ChannelHandlerContext fireChannelRegistered() {
  	// 沿着 pipeline 找到下一个 支持 REGISTERED 回调类型的 handler
    invokeChannelRegistered(findContextInbound(MASK_CHANNEL_REGISTERED)); 
    return this;
}
```

> 注意：pipeline.fireChannelRegistered() 是将 channelRegistered 事件抛到 pipeline 中，pipeline 中的 handlers 准备处理该事件。而 context.fireChannelRegistered() 是一个 handler 处理完了以后，向后传播给下一个 handler。
>
> 它们两个的方法名字是一样的，但是来自于不同的类。

最终，调用之后，控制台的显示为：

```java
handlerAdded
channelRegistered
```

继续往下跟。

```java
// AbstractChannel.java
if (isActive()) {
    if (firstRegistration) {
        pipeline.fireChannelActive();
    } else if (config().isAutoRead()) {
        // This channel was registered before and autoRead() is set. This means we need to begin read
        // again so that we process inbound data.
        beginRead();
    }
}
```

读到这，你可能会想当然地以为，控制台最后一行由这行代码输出：

```java
pipeline.fireChannelActive();
```

我们不妨先看一下 `isActive()` 方法。

```java
// AbstractChannel.java
@Override
public boolean isActive() {
    // As java.nio.ServerSocketChannel.isBound() will continue to return true even after the channel was closed
    // we will also need to check if it is open.
    return isOpen() && javaChannel().socket().isBound();
}
```

最终调用到jdk中。

```java
/**
 * Returns the binding state of the ServerSocket.
 *
 * @return true if the ServerSocket successfully bound to an address
 * @since 1.4
 */
public boolean isBound() {
    // Before 1.3 ServerSockets were always bound during creation
    return bound || oldImpl;
}
```

这里`isBound()`返回false，但是从目前我们跟下来的流程看，我们并没有将一个ServerSocket绑定到一个address，所以 `isActive()` 返回false，我们没有成功进入到`pipeline.fireChannelActive();`方法，那么最后一行到底是谁输出的呢，我们有点抓狂，其实，只要熟练运用IDE，要定位函数调用栈，无比简单。

<img src="http://blog-1259650185.cosbj.myqcloud.com/img/202111/21/1637427996.gif" alt="img" style="zoom:50%;" />

我们先在最终输出文字的这一行代码处打一个断点，然后debug，运行到这一行，intellij自动给我们拉起了调用栈，我们唯一要做的事，就是移动方向键，就能看到函数的完整的调用链。

如果你看到方法的最近的发起端是一个线程Runnable的run方法，那么就在提交Runnable对象方法的地方打一个断点，去掉其他断点，重新debug，比如我们首次debug发现调用栈中的最近的一个Runnable如下：

```java
if (!wasActive && isActive()) {
    invokeLater(new Runnable() {
        @Override
        public void run() {
            pipeline.fireChannelActive();
        }
    });
}
```

我们停在了这一行`pipeline.fireChannelActive();`, 我们想看最初始的调用，就得跳出来，断点打到 `if (!wasActive && isActive())`，因为netty里面很多任务执行都是异步线程即reactor线程调用的(具体可以看reactor线程三部曲中的[最后一曲](https://www.jianshu.com/p/0d0eece6d467))，如果我们要查看最先发起的方法调用，我们必须得查看Runnable被提交的地方，逐次递归下去，就能找到那行"消失的代码"

最终，通过这种方式，终于找到了 `pipeline.fireChannelActive();` 的发起调用的代码，不巧，刚好就是下面的`doBind0()`方法

#### doBind0

```java
// AbstractBootstrap.java
private static void doBind0(
            final ChannelFuture regFuture, final Channel channel,
            final SocketAddress localAddress, final ChannelPromise promise) {
        channel.eventLoop().execute(new Runnable() {
            @Override
            public void run() {
                if (regFuture.isSuccess()) {
                    channel.bind(localAddress, promise).addListener(ChannelFutureListener.CLOSE_ON_FAILURE);
                } else {
                    promise.setFailure(regFuture.cause());
                }
            }
        });
    }
```

我们发现，在调用`doBind0(...)`方法的时候，是通过包装一个Runnable进行异步化的，关于异步化task，可以看下我前面的文章。

好，接下来我们进入到`channel.bind()`方法。

```java
// AbstractChannel.java
@Override
public ChannelFuture bind(SocketAddress localAddress, ChannelPromise promise) {
    return pipeline.bind(localAddress, promise);
}
```

发现是调用pipeline的bind方法。

```java
// DefaultChannelPipeline.java
@Override
public final ChannelFuture bind(SocketAddress localAddress) {
    return tail.bind(localAddress);
}
```

相信你对tail是什么不是很了解，可以翻到最开始，tail在创建pipeline的时候出现过，关于pipeline和tail对应的类，我后面源码系列会详细解说，这里，你要想知道接下来代码的走向，唯一一个比较好的方式就是debug 单步进入，篇幅原因，我就不详细展开。

最后，我们来到了如下区域

```java
// HeadContext.java
@Override
public void bind(
        ChannelHandlerContext ctx, SocketAddress localAddress, ChannelPromise promise)
        throws Exception {
    unsafe.bind(localAddress, promise);
}
```

这里的unsafe就是前面提到的 `AbstractUnsafe`, 准确点，应该是 `NioMessageUnsafe`。

我们进入到它的bind方法。

```java
// AbstractUnsafe.java
@Override
public final void bind(final SocketAddress localAddress, final ChannelPromise promise) {
		...
    boolean wasActive = isActive();
    try {
        doBind(localAddress);
    } catch (Throwable t) {
				...
    }
    // 绑定后，才是开始激活
    if (!wasActive && isActive()) {
        invokeLater(new Runnable() {
            @Override
            public void run() {
                pipeline.fireChannelActive();
            }
        });
    }

    safeSetSuccess(promise);
}
```

显然按照正常流程，我们前面已经分析到 `isActive();` 方法返回false，进入到 `doBind()`之后，如果channel被激活了，就发起`pipeline.fireChannelActive();`调用，最终调用到用户方法，在控制台打印出了最后一行，所以到了这里，你应该清楚为什么最终会在控制台按顺序打印出那三行字了吧。

`doBind()`方法也很简单。

```java
// NioServerSocketChannel.java
@Override
protected void doBind(SocketAddress localAddress) throws Exception {
    if (PlatformDependent.javaVersion() >= 7) { // 使用 JDK 的 API ，bind
        javaChannel().bind(localAddress, config.getBacklog());
    } else {
        javaChannel().socket().bind(localAddress, config.getBacklog());
    }
}
```

最终调到了jdk里面的bind方法，这行代码过后，正常情况下，就真正进行了端口的绑定。

另外，通过自顶向下的方式分析，在调用`pipeline.fireChannelActive();`方法的时候，会调用到如下方法：

```java
// HeadContext.java
public void channelActive(ChannelHandlerContext ctx) throws Exception {
    ctx.fireChannelActive();
		// 注册读事件：读包括：创建连接/读数据
    readIfIsAutoRead();
}

private void readIfIsAutoRead() {
    if (channel.config().isAutoRead()) {
        channel.read();
    }
}
```

分析`isAutoRead`方法。

```java
// DefaultChannelConfig.java
private volatile int autoRead = 1;
public boolean isAutoRead() {
    return autoRead == 1;
}
```

由此可见，`isAutoRead`方法默认返回true，于是进入到以下方法：

```java
// AbstractChannel.java
public Channel read() {
    pipeline.read();
    return this;
}
```

最终调用到：

```java
// HeadContext.java
@Override
public void read(ChannelHandlerContext ctx) {
    // 实际上就是注册OP_ACCEPT/OP_READ事件：创建连接或者读事件
    unsafe.beginRead();
}

// AbstractNioUnsafe.java
@Override
public final void beginRead() {
    assertEventLoop();

    try {
        doBeginRead();
    } catch (final Exception e) {
			...
    }
}

// AbstractNioChannel.java
@Override
protected void doBeginRead() throws Exception {
    // Channel.read() or ChannelHandlerContext.read() was called
    final SelectionKey selectionKey = this.selectionKey;
    if (!selectionKey.isValid()) {
        return;
    }

    readPending = true;
    // 获取前面监听的 ops = 0，
    final int interestOps = selectionKey.interestOps();
    // 假设之前没有监听readInterestOp，则监听readInterestOp
    if ((interestOps & readInterestOp) == 0) {
        logger.info("interest ops：{}", readInterestOp);
        selectionKey.interestOps(interestOps | readInterestOp); // 真正的注册 interestOps，做好连接的准备
    }
}
```

这里的`this.selectionKey`就是我们在前面register步骤返回的对象，前面我们在register的时候，注册的ops是0，也就是什么都不监听。

> 当然，也就意味着，后续一定有某个地方会需要修改这个 selectionKey 的监听集合，不然啥都干不了。

回忆一下注册

```java
// AbstractNioChannel.java
selectionKey = javaChannel().register(eventLoop().selector, 0, this)
```

这里相当于把注册过的ops取出来，通过了if条件，然后调用

```java
// AbstractNioChannel.java
selectionKey.interestOps(interestOps | readInterestOp);
```

而这里的 `readInterestOp` 就是前面newChannel的时候传入的`SelectionKey.OP_ACCEPT`，又是标准的jdk nio的玩法，到此，你需要了解的细节基本已经差不多了，就这样结束吧！

### summary

最后，我们来做下总结，netty启动一个服务所经过的流程
 1.设置启动类参数，最重要的就是设置channel。
 2.创建server对应的channel，创建各大组件，包括ChannelConfig,ChannelId、ChannelPipeline、ChannelHandler、Unsafe等。
 3.初始化server对应的channel，设置一些attr，option，以及设置子channel的attr，option，给server的channel添加新channel接入器，并触发addHandler、register等事件
 4.调用到jdk底层做端口绑定，并触发active事件，**active触发的时候，真正做服务端口绑定**。

## 参考

[netty源码分析之服务端启动全解析](https://www.jianshu.com/p/c5068caab217)

[Netty 源码解析（八）: 回到 Channel 的 register 操作](https://javadoop.com/post/netty-part-8)
