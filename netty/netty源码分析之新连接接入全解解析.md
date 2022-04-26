## 前序背景

读这篇文章之前，最好掌握一些前序知识，包括netty中的reactor线程，以及服务端启动过程。

下面我带你简单地回顾一下：

### 1.netty中的reactor线程

netty中最核心的东西莫过于两种类型的reactor线程，可以看作netty中两种类型的发动机，驱动着netty整个框架的运转。

一种类型的reactor线程是boos线程组，专门用来接受新的连接，然后封装成channel对象扔给worker线程组；还有一种类型的reactor线程是worker线程组，专门用来处理连接的读写。

不管是boos线程还是worker线程，所做的事情均分为以下三个步骤：

1. 轮询注册在selector上的IO事件
2. 处理IO事件
3. 执行异步task

对于boos线程来说，第一步轮询出来的基本都是 accept  事件，表示有新的连接，而worker线程轮询出来的基本都是read/write事件，表示网络的读写事件。

### 2.服务端启动

服务端启动过程是在用户线程中开启，第一次添加异步任务的时候启动boos线程被启动，netty将处理新连接的过程封装成一个channel，对应的pipeline会按顺序处理新建立的连接(关于pipeline我后面会开篇详细分析)。

了解完两个背景，我们开始进入正题。

## 新连接的建立

简单来说，新连接的建立可以分为三个步骤：

1. 检测到有新的连接
2. 将新的连接注册到worker线程组
3. 注册新连接的读事件

下面带你庖丁解牛，一步步分析整个过程。

### 检测到有新连接进入

我们已经知道，当服务端绑启动之后，服务端的channel已经注册到boos reactor线程中，reactor不断检测有新的事件，直到检测出有accept事件发生。

```java
// NioEventLoop.java
private void processSelectedKey(SelectionKey k, AbstractNioChannel ch) {
    final AbstractNioChannel.NioUnsafe unsafe = ch.unsafe();

    try {
        int readyOps = k.readyOps();
        if ((readyOps & SelectionKey.OP_CONNECT) != 0) {
            // remove OP_CONNECT as otherwise Selector.select(..) will always return without blocking
            int ops = k.interestOps();
            ops &= ~SelectionKey.OP_CONNECT;
            k.interestOps(ops);

            unsafe.finishConnect();
        }

        if ((readyOps & SelectionKey.OP_WRITE) != 0) {
            ch.unsafe().forceFlush(); // 写事件的话就直接 flush
        }

        // 处理读请求（断开连接）或者接入连接
        if ((readyOps & (SelectionKey.OP_READ | SelectionKey.OP_ACCEPT)) != 0 || readyOps == 0) {
            unsafe.read();
        }
    } catch (CancelledKeyException ignored) {
        unsafe.close(unsafe.voidPromise());
    }
}
```

上面这段代码是reactor线程三部曲中的第二部曲，表示boos reactor线程已经轮询到 `SelectionKey.OP_ACCEPT` 事件，说明有新的连接进入，此时将调用channel的 `unsafe`来进行实际的操作。

关于 `unsafe`，这篇文章我不打算细讲，下面是netty作者对于unsafe的解释。

> Unsafe operations that should never be called from user-code. These methods are only provided to implement the actual transport.

你只需要了解一个大概的概念，就是所有的channel底层都会有一个与unsafe绑定，每种类型的channel实际的操作都由unsafe来实现。

而从上一篇文章，服务端的启动过程中，我们已经知道，服务端对应的channel的unsafe是 `NioMessageUnsafe`，那么，我们进入到它的`read`方法，进入新连接处理的第二步。

### 注册到reactor线程

```java
// NioMessageUnsafe.java
private final List<Object> readBuf = new ArrayList<Object>();

public void read() {
    assert eventLoop().inEventLoop();
    final ChannelConfig config = config();
    final ChannelPipeline pipeline = pipeline();
    final RecvByteBufAllocator.Handle allocHandle = unsafe().recvBufAllocHandle();
    allocHandle.reset(config);

    boolean closed = false;
    Throwable exception = null;
    try {
        try {
            do {
                int localRead = doReadMessages(readBuf); // do
                if (localRead == 0) {
                    break;
                }
                if (localRead < 0) {
                    closed = true;
                    break;
                }

                allocHandle.incMessagesRead(localRead); // 记录下创建的次数
            } while (continueReading(allocHandle));
        } catch (Throwable t) {
            exception = t;
        }

        int size = readBuf.size();
        for (int i = 0; i < size; i ++) {
            readPending = false;
            // 创建的结果（socketChannel）通过 fireChannelRead 传播出去了，就是各种 handler 的串行执行
            pipeline.fireChannelRead(readBuf.get(i));
        }
        readBuf.clear();
        allocHandle.readComplete();
        pipeline.fireChannelReadComplete();

        if (exception != null) {
            closed = closeOnReadError(exception);

            pipeline.fireExceptionCaught(exception);
        }

        if (closed) {
            inputShutdown = true;
            if (isOpen()) {
                close(voidPromise());
            }
        }
    } finally {
				...
    }
}
```

一上来，就用一条断言确定该read方法必须是reactor线程调用，然后拿到channel对应的pipeline和 `RecvByteBufAllocator.Handle`(先不解释)。

接下来，调用 `doReadMessages` 方法不断地读取消息，用 `readBuf` 作为容器，这里，其实可以猜到读取的是一个个连接，然后调用 `pipeline.fireChannelRead()`，将每条新连接经过一层服务端channel的洗礼。

之后清理容器，触发 `pipeline.fireChannelReadComplete()`，整个过程清晰明了，不含一丝杂质，下面我们具体看下这两个方法：

1.doReadMessages(List)
2.pipeline.fireChannelRead(NioSocketChannel)

#### 1.doReadMessages()

```java
// NioServerSocketChannel.java
@Override
protected int doReadMessages(List<Object> buf) throws Exception {
    // 接受新连接查创建SocketChannel
    SocketChannel ch = SocketUtils.accept(javaChannel());

    try {
        if (ch != null) {
            buf.add(new NioSocketChannel(this, ch));
            return 1;
        }
    } catch (Throwable t) {
				...
    }

    return 0;
}

// SocketUtils.java
public static SocketChannel accept(final ServerSocketChannel serverSocketChannel) throws IOException {
    try {
        return AccessController.doPrivileged(new PrivilegedExceptionAction<SocketChannel>() {
            @Override
            public SocketChannel run() throws IOException {
                // 非阻塞模式下，没有连接请求时，返回null，有连接请求时，创建 socketChannel 后返回
                return serverSocketChannel.accept();
            }
        });
    } catch (PrivilegedActionException e) {
        throw (IOException) e.getCause();
    }
}
```

我们终于窥探到netty调用jdk底层nio的边界 `serverSocketChannel.accept();`，由于netty中reactor线程第一步就扫描到有accept事件发生，因此，这里的`accept`方法是设置了非阻塞会立即返回的，返回jdk底层nio创建的一条channel。

netty将jdk的 `SocketChannel` 封装成自定义的 `NioSocketChannel`，加入到list里面，这样外层就可以遍历该list，做后续处理。

从上篇文章中，我们已经知道服务端的创建过程中会创建netty中一系列的核心组件，包括pipeline,unsafe等等，那么，接受一条新连接的时候是否也会创建这一系列的组件呢？

带着这个疑问，我们跟进去。

```java
// NioSocketChannel.java
public NioSocketChannel(Channel parent, SocketChannel socket) {
    super(parent, socket);
    config = new NioSocketChannelConfig(this, socket.socket());
}
```

我们重点分析 `super(parent, socket)`，config相关的分析我们放到后面的文章中。

```java
// AbstractNioByteChannel.java
protected AbstractNioByteChannel(Channel parent, SelectableChannel ch) {
    super(parent, ch, SelectionKey.OP_READ);
}
```

这里，我们看到jdk nio里面熟悉的影子—— `SelectionKey.OP_READ`，一般在原生的jdk nio编程中，也会注册这样一个事件，表示对channel的读感兴趣。

我们继续往上，追踪到`AbstractNioByteChannel`的父类 `AbstractNioChannel`, 这里，我相信读了上篇文章的你对于这部分代码肯定是有印象的。

```java
// AbstractNioChannel.java
protected AbstractNioChannel(Channel parent, SelectableChannel ch, int readInterestOp) {
    super(parent);
    this.ch = ch; // 保存到成员变量
    this.readInterestOp = readInterestOp;
    try { // 设置该channel为非阻塞模式，标准的JDK NIO编程的玩法
        ch.configureBlocking(false);
    } catch (IOException e) {
        try {
            ch.close();
        } catch (IOException e2) {
            logger.warn(
                        "Failed to close a partially initialized socket.", e2);
        }

        throw new ChannelException("Failed to enter non-blocking mode.", e);
    }
}
```

在创建服务端channel的时候，最终也会进入到这个方法，`super(parent)`, 便是在`AbstractChannel`中创建一系列和该channel绑定的组件，如下：

```java
// AbstractChannel.java
protected AbstractChannel(Channel parent) {
    this.parent = parent;
    // new出来三大组件，赋值到成员变量
    id = newId(); // 每条channel的唯一标识
    unsafe = newUnsafe();
    pipeline = newChannelPipeline();
}
```

而这里的 `readInterestOp` 表示该channel关心的事件是 `SelectionKey.OP_READ`，后续会将该事件注册到selector，之后设置该通道为非阻塞模式。

到了这里，我终于可以将netty里面最常用的channel的结构图放给你看。

<img src="http://blog-1259650185.cosbj.myqcloud.com/img/202111/21/1637509900" alt="img" style="zoom:50%;" />

这里的继承关系有所简化，当前，我们只需要了解这么多。

1. channel 继承 Comparable 表示channel是一个可以比较的对象
2. channel 继承AttributeMap表示channel是可以绑定属性的对象，在用户代码中，我们经常使用channel.attr(...)方法就是来源于此
3. ChannelOutboundInvoker是4.1.x版本新加的抽象，表示一条channel可以进行的操作
4. DefaultAttributeMap用于AttributeMap抽象的默认方法,后面channel继承了直接使用
5. AbstractChannel用于实现channel的大部分方法，其中我们最熟悉的就是其构造函数中，创建出一条channel的基本组件
6. AbstractNioChannel基于AbstractChannel做了nio相关的一些操作，保存jdk底层的 `SelectableChannel`，并且在构造函数中设置channel为非阻塞
7. 最后，就是两大channel，NioServerSocketChannel，NioSocketChannel对应着服务端接受新连接过程和新连接读写过程

读到这，关于channel的整体框架你基本已经了解了一大半了。

好了，让我们退栈，继续之前的源码分析，在创建出一条 `NioSocketChannel`之后，放置在List容器里面之后，就开始进行下一步操作。

#### 2.pipeline.fireChannelRead(NioSocketChannel)

```java
// AbstractNioMessageChannel.java
pipeline.fireChannelRead(NioSocketChannel);
```

在没有正式介绍pipeline之前，请让我简单介绍一下pipeline这个组件。

在netty的各种类型的channel中，都会包含一个pipeline，字面意思是管道，我们可以理解为一条流水线工艺，流水线工艺有起点，有结束，中间还有各种各样的流水线关卡，一件物品，在流水线起点开始处理，经过各个流水线关卡的加工，最终到流水线结束

对应到netty里面，流水线的开始就是`HeadContxt`，流水线的结束就是`TailConext`，`HeadContxt`中调用`Unsafe`做具体的操作，`TailConext`中用于向用户抛出pipeline中未处理异常以及对未处理消息的警告，关于pipeline的具体分析我们后面再详细探讨。

通过前面一篇文章，我们已经知道在服务端处理新连接的pipeline中，已经自动添加了一个pipeline处理器 `ServerBootstrapAcceptor`, 并已经将用户代码中设置的一系列的参数传入了构造函数，接下来，我们就来看下`ServerBootstrapAcceptor`。

```java
private static class ServerBootstrapAcceptor extends ChannelInboundHandlerAdapter {

    private final EventLoopGroup childGroup;
    private final ChannelHandler childHandler;
    private final Entry<ChannelOption<?>, Object>[] childOptions;
    private final Entry<AttributeKey<?>, Object>[] childAttrs;
    private final Runnable enableAutoReadTask;

    ServerBootstrapAcceptor( // 接收连接后的后续处理
            final Channel channel, EventLoopGroup childGroup, ChannelHandler childHandler,
            Entry<ChannelOption<?>, Object>[] childOptions, Entry<AttributeKey<?>, Object>[] childAttrs) {
        this.childGroup = childGroup;
        this.childHandler = childHandler;
        this.childOptions = childOptions;
        this.childAttrs = childAttrs;

        enableAutoReadTask = new Runnable() {
            @Override
            public void run() {
                channel.config().setAutoRead(true);
            }
        };
    }

    @Override
    @SuppressWarnings("unchecked") // AbstractNioMessageChannel.NioMessageUnsafe#read() 89行 ChannelPipeline#fireChannelRead() 传播过来触发的
    public void channelRead(ChannelHandlerContext ctx, Object msg) {
        final Channel child = (Channel) msg;

        child.pipeline().addLast(childHandler);

        setChannelOptions(child, childOptions, logger); // 设置 childOptions
        setAttributes(child, childAttrs); // 设置 child 属性

        try {
            childGroup.register(child).addListener(new ChannelFutureListener() {
                @Override
                public void operationComplete(ChannelFuture future) throws Exception {
                    if (!future.isSuccess()) {
                        forceClose(child, future.cause());
                    }
                }
            });
        } catch (Throwable t) {
            forceClose(child, t);
        }
    }

    private static void forceClose(Channel child, Throwable t) {
        child.unsafe().closeForcibly();
        logger.warn("Failed to register an accepted channel: {}", child, t);
    }

    @Override
    public void exceptionCaught(ChannelHandlerContext ctx, Throwable cause) throws Exception {
        final ChannelConfig config = ctx.channel().config();
        if (config.isAutoRead()) {
            config.setAutoRead(false);
            ctx.channel().eventLoop().schedule(enableAutoReadTask, 1, TimeUnit.SECONDS);
        }
        ctx.fireExceptionCaught(cause);
    }
}
```

前面的 `pipeline.fireChannelRead(NioSocketChannel);` 最终通过head->unsafe->ServerBootstrapAcceptor的调用链，调用到这里的 `ServerBootstrapAcceptor`  的`channelRead`方法

而 `channelRead` 一上来就把这里的msg强制转换为 `Channel`, 为什么这里可以强制转换？读者可以思考一下。

然后，拿到该channel，也就是我们之前new出来的 `NioSocketChannel`对应的pipeline，将用户代码中的 `childHandler`，添加到pipeline，这里的 `childHandler` 在用户代码中的体现为

```java
ServerBootstrap b = new ServerBootstrap();
b.group(bossGroup, workerGroup)
 .channel(NioServerSocketChannel.class)
 .childHandler(new ChannelInitializer<SocketChannel>() {
     @Override
     public void initChannel(SocketChannel ch) throws Exception {
         ChannelPipeline p = ch.pipeline();
         p.addLast(new EchoServerHandler());
     }
 });
```

其实对应的是 `ChannelInitializer`，到了这里，`NioSocketChannel`中pipeline对应的处理器为 head->ChannelInitializer->tail，牢记，后面会再次提到！

接着，设置 `NioSocketChannel` 对应的 attr和option，然后进入到 `childGroup.register(child)`，这里的childGroup就是我们在启动代码中new出来的`NioEventLoopGroup`。

我们进入到`NioEventLoopGroup`的`register`方法，代理到其父类`MultithreadEventLoopGroup`。

```java
// MultithreadEventLoopGroup.java
@Override
public ChannelFuture register(Channel channel) {
    return next().register(channel); // 找到 group 里的下一个 eventLoop，注册 channel
}
```

这里又扯出来一个 next()方法，我们跟进去。

```java
// MultithreadEventLoopGroup.java
@Override
public EventLoop next() {
    return (EventLoop) super.next();
}

// MultithreadEventExecutorGroup.java
@Override
public EventExecutor next() {
    return chooser.next();
}
```

这里的chooser对应的类为 `EventExecutorChooser`，字面意思为事件执行器选择器，放到我们这里的上下文中的作用就是从worker reactor线程组中选择一个reactor线程

```java
// EventExecutorChooserFactory.java
public interface EventExecutorChooserFactory {

    /**
     * Returns a new {@link EventExecutorChooser}.
     */
    EventExecutorChooser newChooser(EventExecutor[] executors);

    /**
     * Chooses the next {@link EventExecutor} to use.
     */
    @UnstableApi
    interface EventExecutorChooser {

        /**
         * Returns the new {@link EventExecutor} to use.
         */
        EventExecutor next();
    }
}
```

关于chooser的具体创建我不打算展开，相信前面几篇文章中的源码阅读技巧可以帮助你找出choose的始末，这里，我直接告诉你（但是劝你还是自行分析一下，简单得很），chooser的实现有两种。

```java
public final class DefaultEventExecutorChooserFactory implements EventExecutorChooserFactory {

    public static final DefaultEventExecutorChooserFactory INSTANCE = new DefaultEventExecutorChooserFactory();

    private DefaultEventExecutorChooserFactory() { }

    @SuppressWarnings("unchecked")
    @Override
    public EventExecutorChooser newChooser(EventExecutor[] executors) {
        if (isPowerOfTwo(executors.length)) {
            return new PowerOfTowEventExecutorChooser(executors);
        } else {
            return new GenericEventExecutorChooser(executors);
        }
    }

    private static boolean isPowerOfTwo(int val) {
        return (val & -val) == val;
    }

    private static final class PowerOfTowEventExecutorChooser implements EventExecutorChooser {
        private final AtomicInteger idx = new AtomicInteger();
        private final EventExecutor[] executors;

        PowerOfTowEventExecutorChooser(EventExecutor[] executors) {
            this.executors = executors;
        }

        @Override
        public EventExecutor next() {
            return executors[idx.getAndIncrement() & executors.length - 1];
        }
    }

    private static final class GenericEventExecutorChooser implements EventExecutorChooser {
        private final AtomicInteger idx = new AtomicInteger();
        private final EventExecutor[] executors;

        GenericEventExecutorChooser(EventExecutor[] executors) {
            this.executors = executors;
        }

        @Override
        public EventExecutor next() {
            return executors[Math.abs(idx.getAndIncrement() % executors.length)];
        }
    }
}
```

默认情况下，chooser通过 `DefaultEventExecutorChooserFactory`被创建，在创建reactor线程选择器的时候，会判断reactor线程的个数，如果是2的幂，就创建`PowerOfTowEventExecutorChooser`，否则，创建`GenericEventExecutorChooser`。

两种类型的选择器在选择reactor线程的时候，都是通过Round-Robin的方式选择reactor线程，唯一不同的是，`PowerOfTowEventExecutorChooser`是通过与运算，而`GenericEventExecutorChooser`是通过取余运算，与运算的效率要高于求余运算，可见，netty为了效率优化简直丧心病狂！

选择完一个reactor线程，即 `NioEventLoop` 之后，我们回到注册的地方。

```java
// SingleThreadEventLoop.java
@Override
public ChannelFuture register(Channel channel) {
    return register(new DefaultChannelPromise(channel, this));
}
```

其实，这里已经和服务端启动的过程一样了，详细步骤可以参考服务端启动详解这篇文章，我们直接跳到关键环节。

```java
// AbstractChannel.java
private void register0(ChannelPromise promise) {
    try {
        // check if the channel is still open as it could be closed in the mean time when the register
        // call was outside of the eventLoop
        if (!promise.setUncancellable() || !ensureOpen(promise)) {
            return;
        }
        boolean firstRegistration = neverRegistered;
        doRegister();
        neverRegistered = false;
        registered = true;

        pipeline.invokeHandlerAddedIfNeeded();

        safeSetSuccess(promise);
        pipeline.fireChannelRegistered();
        // server socket 的注册不会走进下面的 if，server socket接受连接创建的socket可以走进去，因为 accept 后就 active 了
        if (isActive()) {
            if (firstRegistration) {
                pipeline.fireChannelActive();
            } else if (config().isAutoRead()) {
                beginRead();
            }
        }
    } catch (Throwable t) {
				...
    }
}
```

和服务端启动过程一样，先是调用 `doRegister();`做真正的注册过程，如下：

```java
// AbstractNioChannel.java
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

将该条channel绑定到一个`selector`上去，一个selector被一个reactor线程使用，后续该channel的事件轮询，以及事件处理，异步task执行都是由此reactor线程来负责。

绑定完reactor线程之后，调用 `pipeline.invokeHandlerAddedIfNeeded()`。

前面我们说到，到目前为止`NioSocketChannel` 的pipeline中有三个处理器，head->ChannelInitializer->tail，最终会调用到 `ChannelInitializer` 的 `handlerAdded` 方法

```java
// ChannelInitializer.java
@Override
public void handlerAdded(ChannelHandlerContext ctx) throws Exception {
    if (ctx.channel().isRegistered()) {
        if (initChannel(ctx)) {
            removeState(ctx);
        }
    }
}
```

`handlerAdded`方法调用 `initChannel` 方法之后，调用`remove(ctx);`将自身删除。

```java
// ChannelInitializer.java
private boolean initChannel(ChannelHandlerContext ctx) throws Exception {
    if (initMap.add(ctx)) { // Guard against re-entrance.
        try {
            initChannel((C) ctx.channel());
        } catch (Throwable cause) {
            exceptionCaught(ctx, cause);
        } finally {
            ChannelPipeline pipeline = ctx.pipeline();
            if (pipeline.context(this) != null) {
                pipeline.remove(this);
            }
        }
        return true;
    }
    return false;
}
```

而这里的 `initChannel` 方法又是神马玩意？让我们回到用户方法，比如下面这段用户代码：

```java
// 用户代码
ServerBootstrap b = new ServerBootstrap();
b.group(bossGroup, workerGroup)
 .channel(NioServerSocketChannel.class)
 .option(ChannelOption.SO_BACKLOG, 100)
 .handler(new LoggingHandler(LogLevel.INFO))
 .childHandler(new ChannelInitializer<SocketChannel>() {
     @Override
     public void initChannel(SocketChannel ch) throws Exception {
         ChannelPipeline p = ch.pipeline();
         p.addLast(new LoggingHandler(LogLevel.INFO));
         p.addLast(new EchoServerHandler());
     }
 });
```

哦，原来最终跑到我们自己的代码里去了啊！我就不解释这段代码是干嘛的了，你懂的～。

完了之后，`NioSocketChannel`绑定的pipeline的处理器就包括 head->LoggingHandler->EchoServerHandler->tail。

### 注册读事件

```java
// AbstractChannel.java
private void register0(ChannelPromise promise) {
    try {
        ...
        pipeline.fireChannelRegistered();
        // server socket 的注册不会走进下面的 if，server socket接受连接创建的socket可以走进去，因为 accept 后就 active 了
        if (isActive()) {
            if (firstRegistration) {
                pipeline.fireChannelActive();
            } else if (config().isAutoRead()) {
                beginRead();
            }
        }
    } catch (Throwable t) {
				...
    }
}
```

`pipeline.fireChannelRegistered();`，其实没有干啥有意义的事情，最终无非是再调用一下业务pipeline中每个处理器的 `ChannelHandlerRegistered`方法处理下回调。

`isActive()`在连接已经建立的情况下返回true，所以进入方法块，进入到 `pipeline.fireChannelActive();`，这里的分析和netty源码分析之服务端启动全解析分析中的一样，在这里我详细步骤先省略，直接进入到关键环节。

```java
// AbstractChannel.java
@Override
public final void beginRead() {
    assertEventLoop();

    try {
        doBeginRead();
    } catch (final Exception e) {
				...
    }
}

// AbstractNioChannel.jav
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

你应该还记得前面 `register0()` 方法的时候，向selector注册的事件代码是0，而 `readInterestOp`对应的事件代码是 `SelectionKey.OP_READ`，参考前文中创建 `NioSocketChannel` 的过程，稍加推理，聪明的你就会知道，这里其实就是将 `SelectionKey.OP_READ`事件注册到selector中去，表示这条通道已经可以开始处理read事件了。

## connect过程分析

对于客户端 NioSocketChannel 来说，前面 register 完成以后，就要开始 connect 了，这一步将连接到服务端。

```java
// Bootstrap.java
private ChannelFuture doResolveAndConnect(final SocketAddress remoteAddress, final SocketAddress localAddress) {
    // 这里完成了 register 操作
    final ChannelFuture regFuture = initAndRegister();
    final Channel channel = regFuture.channel();

    // 这里我们不去纠结 register 操作是否 isDone()
    if (regFuture.isDone()) {
        if (!regFuture.isSuccess()) {
            return regFuture;
        }
        // 看这里
        return doResolveAndConnect0(channel, remoteAddress, localAddress, channel.newPromise());
    } else {
        ....
    }
}
```

最后，我们会来到 AbstractChannel 的 connect 方法：

```java
// AbstractChannel.java
@Override
public ChannelFuture connect(SocketAddress remoteAddress, ChannelPromise promise) {
    return pipeline.connect(remoteAddress, promise);
}
```

我们看到，connect 操作是交给 pipeline 来执行的。进入 pipeline 中，我们会发现，connect 这种 Outbound 类型的操作，是从 pipeline 的 tail 开始的：

> 前面我们介绍的 register 操作是 Inbound 的，是从 head 开始的

```java
// DefaultChannelPipeline.java
@Override
public final ChannelFuture connect(SocketAddress remoteAddress, ChannelPromise promise) {
    return tail.connect(remoteAddress, promise);
}
```

接下来就是 pipeline 的操作了，从 tail 开始，执行 pipeline 上的 Outbound 类型的 handlers 的 connect(...) 方法，那么真正的底层的 connect 的操作发生在哪里呢？还记得我们的 pipeline 的图吗？

<img src="http://blog-1259650185.cosbj.myqcloud.com/img/202111/30/1638277523.jpg" alt="pipeline结构" style="zoom:67%;" />

从 tail 开始往前找 out 类型的 handlers，每经过一个 handler，都执行里面的 connect() 方法，最后会到 head 中，因为 head 也是 Outbound 类型的，我们需要的 connect 操作就在 head 中，它会负责调用 unsafe 中提供的 connect 方法：

```java
// HeadContext
public void connect(
        ChannelHandlerContext ctx,
        SocketAddress remoteAddress, SocketAddress localAddress,
        ChannelPromise promise) throws Exception {
    unsafe.connect(remoteAddress, localAddress, promise);
}
```

接下来，我们来看一看 connect 在 unsafe 类中所谓的底层操作：

```java
// AbstractNioChannel.java
@Override
public final void connect(
        final SocketAddress remoteAddress, final SocketAddress localAddress, final ChannelPromise promise) {
    if (!promise.setUncancellable() || !ensureOpen(promise)) {
        return;
    }

    try {
        if (connectPromise != null) {
            // Already a connect in process.
            throw new ConnectionPendingException();
        }

        boolean wasActive = isActive();
        if (doConnect(remoteAddress, localAddress)) { // 做 JDK 底层的 SocketChannel connect，返回值代表是否已经连接成功
            fulfillConnectPromise(promise, wasActive); // 处理连接成功的情况
        } else {
            connectPromise = promise;
            requestedRemoteAddress = remoteAddress;

            // Schedule connect timeout. 处理连接超时的情况
            int connectTimeoutMillis = config().getConnectTimeoutMillis();
            if (connectTimeoutMillis > 0) {
                connectTimeoutFuture = eventLoop().schedule(new Runnable() { // 用到了 NioEventLoop 的定时任务的功能
                    @Override
                    public void run() {
                        ChannelPromise connectPromise = AbstractNioChannel.this.connectPromise;
                        if (connectPromise != null && !connectPromise.isDone()
                                && connectPromise.tryFailure(new ConnectTimeoutException(
                                        "connection timed out: " + remoteAddress))) {
                            close(voidPromise());
                        }
                    }
                }, connectTimeoutMillis, TimeUnit.MILLISECONDS);
            }

            promise.addListener(new ChannelFutureListener() {
                @Override
                public void operationComplete(ChannelFuture future) throws Exception {
                    if (future.isCancelled()) {
                        if (connectTimeoutFuture != null) {
                            connectTimeoutFuture.cancel(false);
                        }
                        connectPromise = null;
                        close(voidPromise());
                    }
                }
            });
        }
    } catch (Throwable t) {
        promise.tryFailure(annotateConnectException(t, remoteAddress));
        closeIfClosed();
    }
}
```

如果上面的 doConnect 方法返回 false，那么后续是怎么处理的呢？

在上一节介绍的 register 操作中，channel 已经 register 到了 selector 上，只不过将 interestOps 设置为了 0，也就是什么都不监听。

而在上面的 doConnect 方法中，我们看到它在调用底层的 connect 方法后，会设置 interestOps 为 `SelectionKey.OP_CONNECT`。

剩下的就是 NioEventLoop 的事情了，还记得 NioEventLoop 的 run() 方法吗？也就是说这里的 connect 成功以后，这个 TCP 连接就建立起来了，后续的操作会在 `NioEventLoop.run()` 方法中被 `processSelectedKeys()` 方法处理掉。

## 总结

至此，netty中关于新连接的处理已经向你展示完了，我们做下总结：

1. boos reactor线程轮询到有新的连接进入
2. 通过封装jdk底层的channel创建 `NioSocketChannel`以及一系列的netty核心组件
3. 将该条连接通过chooser，选择一条worker reactor线程绑定上去
4. 注册读事件，开始新连接的读写

## 参考

[netty源码分析之新连接接入全解析](https://www.jianshu.com/p/0242b1d4dd21)

[Netty 源码解析（九）: connect 过程和 bind 过程分析](https://javadoop.com/post/netty-part-9)