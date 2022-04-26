## 总述

<img src="http://blog-1259650185.cosbj.myqcloud.com/img/202109/01/1630463042.png" alt="image-20210901102402222" style="zoom: 33%;" />

在这一章中，我们将分析图中的箭头部分，将各部件连接起来。进行连接的关键部件正是本章的主角Channel，Channel是网络Socket进行联系的纽带，可以完成诸如读、写、连接、绑定等I/O操作。

### Channel概述

JDK中的Channel是通讯的载体，而Netty中的Channel在此基础上进行封装从而赋予了Channel更多的能力，用户可以使用Channel进行以下操作：

- 查询Channel的状态。
- 配置Channel的参数。
- 进行Channel支持的I/O操作（read，write，connect，bind）。
- 获取对应的ChannelPipeline，从而可以自定义处理I/O事件或者其他请求。

为了保证在使用Channel或者处理I/O操作时不出现错误，以下几点需要特别注意：

1. **所有的I/O操作都是异步的**
    由于采用事件驱动的机制，所以Netty中的所有IO操作都是异步的。这意味着当我们调用一个IO操作时，方法会立即返回并不保证操作已经完成。我们知道，这些IO操作会返回一个ChannelFuture对象，这就意味着我们需要通过添加监听者的方式执行操作完成后需执行的代码。
2. **Channel是有等级的**
    如果一个Channel由另一个Channel创建，那么他们之间形成父子关系。比如说，当ServerSocketChannel通过accept()方法接受一个SocketChannel时，那么SocketChannel的父亲是ServerSocketChannel，调用SocketChannel的parent()方法返回该ServerSocketChannel对象。
3. **可以使用向下转型获取子类的特定操作**
    某些子类Channel会提供一些所需的特定操作，可以向下转型到这样的子类，从而获得特定操作。比如说，对于UDP的数据报的传输，有特定的join()和leave()操作，我们可以向下转型到DatagramChannel从而使用这些操作。
4. **释放资源**
    当一个Channel不再使用时，须调用close()或者close(ChannelPromise)方法释放资源。

### Channel配置参数

#### 通用参数

**CONNECT_TIMEOUT_MILLIS**
 Netty参数，连接超时毫秒数，默认值30000毫秒即30秒。

**MAX_MESSAGES_PER_READ**
Netty参数，一次Loop读取的最大消息数，对于ServerChannel或者NioByteChannel，默认值为16，其他Channel默认值为1。默认值这样设置，是因为：ServerChannel需要接受足够多的连接，保证大吞吐量，NioByteChannel可以减少不必要的系统调用select。

**WRITE_SPIN_COUNT**
Netty参数，一个Loop写操作执行的最大次数，默认值为16。也就是说，对于大数据量的写操作至多进行16次，如果16次仍没有全部写完数据，此时会提交一个新的写任务给EventLoop，任务将在下次调度继续执行。这样，其他的写请求才能被响应不会因为单个大数据量写请求而耽误。

**ALLOCATOR**
Netty参数，ByteBuf的分配器，默认值为ByteBufAllocator.DEFAULT，4.0版本为UnpooledByteBufAllocator，4.1版本为PooledByteBufAllocator。该值也可以使用系统参数io.netty.allocator.type配置，使用字符串值："unpooled"，"pooled"。

**RCVBUF_ALLOCATOR**
Netty参数，用于Channel分配接受Buffer的分配器，默认值为AdaptiveRecvByteBufAllocator.DEFAULT，是一个自适应的接受缓冲区分配器，能根据接受到的数据自动调节大小。可选值为FixedRecvByteBufAllocator，固定大小的接受缓冲区分配器。

**AUTO_READ**
Netty参数，自动读取，默认值为True。Netty只在必要的时候才设置关心相应的I/O事件。对于读操作，需要调用channel.read()设置关心的I/O事件为OP_READ，这样若有数据到达才能读取以供用户处理。该值为True时，每次读操作完毕后会自动调用channel.read()，从而有数据到达便能读取；否则，需要用户手动调用channel.read()。需要注意的是：当调用config.setAutoRead(boolean)方法时，如果状态由false变为true，将会调用channel.read()方法读取数据；由true变为false，将调用config.autoReadCleared()方法终止数据读取。

**WRITE_BUFFER_HIGH_WATER_MARK**
Netty参数，写高水位标记，默认值64KB。如果Netty的写缓冲区中的字节超过该值，Channel的isWritable()返回False。

**WRITE_BUFFER_LOW_WATER_MARK**
Netty参数，写低水位标记，默认值32KB。当Netty的写缓冲区中的字节超过高水位之后若下降到低水位，则Channel的isWritable()返回True。写高低水位标记使用户可以控制写入数据速度，从而实现流量控制。推荐做法是：每次调用channl.write(msg)方法首先调用channel.isWritable()判断是否可写。

**MESSAGE_SIZE_ESTIMATOR**
Netty参数，消息大小估算器，默认为DefaultMessageSizeEstimator.DEFAULT。估算ByteBuf、ByteBufHolder和FileRegion的大小，其中ByteBuf和ByteBufHolder为实际大小，FileRegion估算值为0。该值估算的字节数在计算水位时使用，FileRegion为0可知FileRegion不影响高低水位。

**SINGLE_EVENTEXECUTOR_PER_GROUP**
Netty参数，单线程执行ChannelPipeline中的事件，默认值为True。该值控制执行ChannelPipeline中执行ChannelHandler的线程。如果为Trye，整个pipeline由一个线程执行，这样不需要进行线程切换以及线程同步，是Netty4的推荐做法；如果为False，ChannelHandler中的处理过程会由Group中的不同线程执行。

#### SocketChannel参数

**SO_RCVBUF**

Socket参数，TCP数据接收缓冲区大小。该缓冲区即TCP接收滑动窗口，linux操作系统可使用命令：`cat /proc/sys/net/ipv4/tcp_rmem`查询其大小。一般情况下，该值可由用户在任意时刻设置，但当设置值超过64KB时，需要在连接到远端之前设置。

**SO_SNDBUF**
Socket参数，TCP数据发送缓冲区大小。该缓冲区即TCP发送滑动窗口，linux操作系统可使用命令：`cat /proc/sys/net/ipv4/tcp_smem`查询其大小。

**TCP_NODELAY**
TCP参数，立即发送数据，默认值为True（Netty默认为True而操作系统默认为False）。该值设置Nagle算法的启用，该算法将小的碎片数据连接成更大的报文来最小化所发送的报文的数量，如果需要发送一些较小的报文，则需要禁用该算法。Netty默认禁用该算法，从而降低最小化报文传输延时。

**SO_KEEPALIVE**
Socket参数，连接保活，默认值为False。启用该功能时，TCP会主动探测空闲连接的有效性。可以将此功能视为TCP的心跳机制，需要注意的是：默认的心跳间隔是7200s即2小时。Netty默认关闭该功能。

**SO_REUSEADDR**
Socket参数，地址复用，默认值False。有四种情况可以使用：(1).当有一个有相同本地地址和端口的socket1处于TIME_WAIT状态时，而你希望启动的程序的socket2要占用该地址和端口，比如重启服务且保持先前端口。(2).有多块网卡或用IP Alias技术的机器在同一端口启动多个进程，但每个进程绑定的本地IP地址不能相同。(3).单个进程绑定相同的端口到多个socket上，但每个socket绑定的ip地址不同。(4).完全相同的地址和端口的重复绑定。但这只用于UDP的多播，不用于TCP。

**SO_LINGER**
 Netty对底层Socket参数的简单封装，关闭Socket的延迟时间，默认值为-1，表示禁用该功能。-1以及所有<0的数表示socket.close()方法立即返回，但OS底层会将发送缓冲区全部发送到对端。0表示socket.close()方法立即返回，OS放弃发送缓冲区的数据直接向对端发送RST包，对端收到复位错误。非0整数值表示调用socket.close()方法的线程被阻塞直到延迟时间到或发送缓冲区中的数据发送完毕，若超时，则对端会收到复位错误。

**IP_TOS**
IP参数，设置IP头部的Type-of-Service字段，用于描述IP包的优先级和QoS选项。

**ALLOW_HALF_CLOSURE**
Netty参数，一个连接的远端关闭时本地端是否关闭，默认值为False。值为False时，连接自动关闭；为True时，触发ChannelInboundHandler的userEventTriggered()方法，事件为ChannelInputShutdownEvent。

#### ServerSocketChannel参数

**SO_RCVBUF**
已说明，需要注意的是：当设置值超过64KB时，需要在绑定到本地端口前设置。该值设置的是由ServerSocketChannel使用accept接受的SocketChannel的接收缓冲区。

**SO_REUSEADDR**
已说明。

**SO_BACKLOG**
Socket参数，服务端接受连接的队列长度，如果队列已满，客户端连接将被拒绝。默认值，Windows为200，其他为128。

#### DatagramChannel参数

**SO_BROADCAST**
Socket参数，设置广播模式。

**SO_RCVBUF**
已说明。

**SO_SNDBUF**
已说明。

**SO_REUSEADDR**
已说明。

**IP_MULTICAST_LOOP_DISABLED**
对应IP参数IP_MULTICAST_LOOP，设置本地回环接口的多播功能。由于IP_MULTICAST_LOOP返回True表示关闭，所以Netty加上后缀_DISABLED防止歧义。

**IP_MULTICAST_ADDR**
对应IP参数IP_MULTICAST_IF，设置对应地址的网卡为多播模式。

**IP_MULTICAST_IF**
对应IP参数IP_MULTICAST_IF2，同上但支持IPV6。

**IP_MULTICAST_TTL**
IP参数，多播数据报的time-to-live即存活跳数。

**IP_TOS**
已说明。

**DATAGRAM_CHANNEL_ACTIVE_ON_REGISTRATION**
Netty参数，DatagramChannel注册的EventLoop即表示已激活。

### Channel接口

Channel接口中含有大量的方法，我们先对这些方法分类：

#### 状态查询方法

 ```java
 // Channel.java
 boolean isOpen(); // 是否开放
 boolean isRegistered(); // 是否注册到一个EventLoop
 boolean isActive(); // 是否激活
 boolean isWritable();   // 是否可写
 ```

open表示Channel的开放状态，True表示Channel可用，False表示Channel已关闭不再可用。

registered表示Channel的注册状态，True表示已注册到一个EventLoop，False表示没有注册到EventLoop。

active表示Channel的激活状态，对于ServerSocketChannel，True表示Channel已绑定到端口；对于SocketChannel，表示Channel可用（open）且已连接到对端。

Writable表示Channel的可写状态，当Channel的写缓冲区outboundBuffer非null且可写时返回True。

一个正常结束的Channel状态转移有以下两种情况：

```bash
REGISTERED->CONNECT/BIND->ACTIVE->CLOSE->INACTIVE->UNREGISTERED 
REGISTERED->ACTIVE->CLOSE->INACTIVE->UNREGISTERED
```

其中第一种是服务端用于绑定的Channel或者客户端用于发起连接的Channel，第二种是服务端接受的SocketChannel。一个异常关闭的Channel则不会服从这样的状态转移。

####  getter方法

```java
// Channel.java
EventLoop eventLoop();  // 注册的EventLoop
Channel parent();   // 父类Channel
ChannelConfig config(); // 配置参数
ChannelMetadata metadata(); // 元数据
SocketAddress localAddress();   // 本地地址
SocketAddress remoteAddress();  // 远端地址
Unsafe unsafe();    // Unsafe对象
ChannelPipeline pipeline(); // 事件管道，用于处理IO事件
ByteBufAllocator alloc();   // 字节缓存分配器
ChannelFuture closeFuture();    // Channel关闭时的异步结果
ChannelPromise voidPromise();   
```

#### 异步结果生成方法

```java
// Channel.java
ChannelPromise newPromise();
ChannelFuture newSucceededFuture();
ChannelFuture newFailedFuture(Throwable cause);
```

#### I/O事件处理方法

```java
// Channel.java
ChannelFuture bind(SocketAddress localAddress);
ChannelFuture connect(SocketAddress remoteAddress);
ChannelFuture disconnect();
ChannelFuture close();
ChannelFuture deregister();
Channel read();
ChannelFuture write(Object msg);
Channel flush();
ChannelFuture writeAndFlush(Object msg);
```

这里的I/O事件都是outbound出站事件，表示由用户发起，即用户可以调用这些方法产生响应的事件。对应地，有inbound入站事件，将在ChnanelPipeline一节中详述。

### Unsafe

Unsafe？直译中文为不安全，这曾给我带来极大的困扰。如果你是第一次遇到这种接口，一定会和我感同身受。一个Unsafe对象是不安全的？这里说的不安全，是相对于用户程序员而言的，也就是说，用户程序员使用Netty进行编程时不会接触到这个接口和相关类。为什么不会接触到呢？因为类似的接口和类是Netty的大量内部实现细节，不会暴露给用户程序员。然而我们的目标是自顶向下深入分析Netty，所以有必要深入Unsafe雷区。我们先看Unsafe接口中的方法：

```java
SocketAddress localAddress();   // 本地地址
SocketAddress remoteAddress();  // 远端地址
ChannelPromise voidPromise();   // 不关心结果的异步Promise？
ChannelOutboundBuffer outboundBuffer(); // 写缓冲区
void register(EventLoop eventLoop, ChannelPromise promise);
void bind(SocketAddress localAddress, ChannelPromise promise);
void connect(SocketAddress remoteAddress, SocketAddress localAddress, 
                          ChannelPromise promise);
void disconnect(ChannelPromise promise);
void close(ChannelPromise promise);
void closeForcibly();
void deregister(ChannelPromise promise);
void beginRead();
void write(Object msg, ChannelPromise promise);
void flush();
```

也许你已经发现Unsafe接口和Channel接口中都有register、bind等I/O事件相关的方法，它们有什么区别呢？回忆一下NioEventLoop线程实现，当一个selectedKey就绪时，对I/O事件的处理委托给unsafe对象实现，代码类似如下：

```java
// NioEventLoop.java
if ((readyOps & SelectionKey.OP_CONNECT) != 0) {
    k.interestOps(k.interestOps() & ~SelectionKey.OP_CONNECT); 
    unsafe.finishConnect(); 
}
if ((readyOps & (SelectionKey.OP_READ | SelectionKey.OP_ACCEPT)) != 0
              || readyOps == 0) {
    unsafe.read(); 
}
if ((readyOps & SelectionKey.OP_WRITE) != 0) {
    ch.unsafe().forceFlush();
}
```

也就是说，**Unsafe的子类作为Channel的内部类，实际负责处理底层NIO相关的I/O事件**。

## 源码实现

<img src="https://img-blog.csdn.net/20160928165809260" alt="img" style="zoom:67%;" />

Channel的类图比较清晰。我们主要分析`NioSocketChannel`和`NioServerSocketChannel`这两个 `Channel`子类的实现。

### AbstractChannel

首先看其中的字段：

```java
// AbstractChannel.java
private final Channel parent;   // 父Channel
private final Unsafe unsafe;    
private final DefaultChannelPipeline pipeline;  // 处理通道
private final ChannelFuture succeededFuture = new SucceededChannelFuture(this, null);
private final VoidChannelPromise voidPromise = new VoidChannelPromise(this, true);
private final VoidChannelPromise unsafeVoidPromise = new VoidChannelPromise(this, false);
private final CloseFuture closeFuture = new CloseFuture(this);

private volatile SocketAddress localAddress;    // 本地地址
private volatile SocketAddress remoteAddress;   // 远端地址
private volatile EventLoop eventLoop;   // EventLoop线程
private volatile boolean registered;    // 是否注册到EventLoop
```

然后，我们看其中的构造方法：

```java
// AbstractChannel.java
protected AbstractChannel(Channel parent) {
    this.parent = parent;
    // new出来三大组件（id，unsafe，pipeline），赋值到成员变量
    id = newId(); // 每条channel的唯一标识
    unsafe = newUnsafe();
    pipeline = newChannelPipeline();
}
```

`newUnsafe()`和 `newChannelPipeline()`可由子类覆盖实现。在Netty的实现中每一个`Channel`都有一个对应的`Unsafe`内部类：AbstractChannel--AbstractUnsafe，AbstractNioChannel--AbstractNioUnsafe等等，`newUnsafe()`方法正好用来生成这样的对应关系。`ChannelPipeline`作为用户处理器Handler的容器为用户提供自定义处理I/O事件的能力即为用户提供业务逻辑处理。`AbstractChannel`中对I/O事件的处理，都委托给`ChannelPipeline`处理，代码都如出一辙：

```java
// AbstractChannel.java
public ChannelFuture bind(SocketAddress localAddress) {
    return pipeline.bind(localAddress);
}
```

AbstractChannel其他方法都比较简单，主要关注状态判定的方法：

```java
// AbstractChannel.java
public boolean isRegistered() {
    return registered;
}

public boolean isWritable() {
    ChannelOutboundBuffer buf = unsafe.outboundBuffer();
    return buf != null && buf.isWritable(); // 写缓冲区不为null且可写
}
```

对于`Channel`的实现来说，其中的内部类`Unsafe`才是关键，因为其中含有I/O事件处理的细节。`AbstractUnsafe`作为`AbstractChannel`的内部类，定义了I/O事件处理的基本框架，其中的细节留给子类实现。我们将依次对各个事件框架进行分析。

#### register事件框架

```java
// AbstractUnsafe.java
@Override
public final void register(EventLoop eventLoop, final ChannelPromise promise) {
    ObjectUtil.checkNotNull(eventLoop, "eventLoop");
    if (isRegistered()) { // 已经注册则失败
        promise.setFailure(new IllegalStateException("registered to an event loop already"));
        return;
    }
    if (!isCompatible(eventLoop)) { // EventLoop不兼容当前Channel
        promise.setFailure(
                new IllegalStateException("incompatible event loop type: " + eventLoop.getClass().getName()));
        return;
    }
    // 将这个 eventLoop 实例设置给这个 channel，从此这个 channel 就是有 eventLoop 的了，这一步其实挺关键的，因为后续该 channel 中的所有异步操作，都要提交给这个 eventLoop 来执行
    AbstractChannel.this.eventLoop = eventLoop;
    // 判断自己的线程（currentThread）是不是 nioEventLoop 里的线程，比如注册的时候，currentThread 是 main thead
    if (eventLoop.inEventLoop()) { // 对于我们来说，它不会进入到这个分支，之所以有这个分支，是因为我们是可以 unregister，然后再 register 的，后面再仔细看
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
            logger.warn(
                    "Force-closing a channel whose registration task was not accepted by an event loop: {}",
                    AbstractChannel.this, t);
            closeForcibly();
            closeFuture.setClosed();
            safeSetFailure(promise, t);
        }
    }
}
```

`eventLoop.execute(...)` 这种类似的代码结构，Netty使用了很多次，这是为了保证I/O事件以及用户定义的I/O事件处理逻辑（业务逻辑）在一个线程中处理。我们看提交的任务`register0()`：

```java
// AbstractUnsafe.java
private void register0(ChannelPromise promise) {
    try {
        // check if the channel is still open as it could be closed in the mean time when the register
        // call was outside of the eventLoop
        if (!promise.setUncancellable() || !ensureOpen(promise)) { // 确保Channel没有关闭
            return;
        }
        boolean firstRegistration = neverRegistered;
        doRegister(); //进行 JDK 底层的操作：Channel 注册到 Selector 上。模板方法，细节由子类完成
        neverRegistered = false;
        registered = true; // 到这里，就算是 registered 了

        // Ensure we call handlerAdded(...) before we actually notify the promise. This is needed as the
        // user may already fire events through the pipeline in the ChannelFutureListener.
        pipeline.invokeHandlerAddedIfNeeded(); // 将用户Handler添加到ChannelPipeline

        safeSetSuccess(promise); // 设置当前 promise 的状态为 success，因为当前 register 方法是在 eventLoop 中的线程中执行的，需要通知提交 register 操作的线程
        pipeline.fireChannelRegistered(); // 当前的 register 操作已经成功，该事件应该被 pipeline 上所有关心 register 事件的 handler 感知到，往 pipeline 中扔一个事件
        // Only fire a channelActive if the channel has never been registered. This prevents firing
        // multiple channel actives if the channel is deregistered and re-registered.
        // server socket 的注册不会走进下面的 if，server socket 接受连接创建的 socket 可以走进去，因为 accept 后就 active 了
        if (isActive()) {
            if (firstRegistration) { // 如果该 channel 是第一次执行 register，那么 fire ChannelActive 事件
                pipeline.fireChannelActive();
            } else if (config().isAutoRead()) {
                // This channel was registered before and autoRead() is set. This means we need to begin read
                // again so that we process inbound data.
                // 对于socketChannel来说就是，注册读事件，可以开始新连接的读操作（建立好连接，下面就可以读了）
                // See https://github.com/netty/netty/issues/4805
                beginRead(); // 该 channel 之前已经 register 过了，这里让该 channel 立马去监听通道中的 OP_READ 事件。可视为模板方法
            }
        }
    } catch (Throwable t) {
        // Close the channel directly to avoid FD leak.
        closeForcibly(); // 可视为模板方法
        closeFuture.setClosed();
        safeSetFailure(promise, t);
    }
}
```

`register0()`方法定义了注册到`EventLoop`的整体框架，整个流程如下：

1. 注册的具体细节由`doRegister()`方法完成，子类中实现。

2. 注册后将处理业务逻辑的用户Handler添加到`ChannelPipeline`。

3. 异步结果设置为成功，触发`Channel`的Registered事件。

4. 对于服务端接受的客户端连接，如果首次注册，触发`Channel`的Active事件，如果已设置autoRead，则调用`beginRead()`开始读取数据。

第4点是因为`fireChannelActive()`中也根据autoRead配置，调用了`beginRead()`方法。`beginRead()`方法其实也是一个框架，细节由`doBeginRead()`方法在子类中实现：

```java
// AbstractUnsafe.java
@Override
public final void beginRead() {
    assertEventLoop();

    try {
        doBeginRead();
    } catch (final Exception e) {
        invokeLater(new Runnable() {
            @Override
            public void run() {
                pipeline.fireExceptionCaught(e);
            }
        });
        close(voidPromise());
    }
}
```

异常处理的closeForcibly()方法也是一个框架，细节由doClose()方法在子类中实现：

```java
// AbstractUnsafe.java
@Override
public final void closeForcibly() {
    assertEventLoop();

    try {
        doClose();
    } catch (Exception e) {
        logger.warn("Failed to close a channel.", e);
    }
}
```

register框架中有一对`safeSetXXX()`方法，将未完成的`Promise`标记为完成且成功或失败，其实现如下：

```java
// AbstractUnsafe.java
protected final void safeSetSuccess(ChannelPromise promise) {
    if (!(promise instanceof VoidChannelPromise) && !promise.trySuccess()) {
        logger.warn("Failed to mark a promise as success because it is done already: {}", promise);
    }
}
```

至此，register事件框架分析完毕。

#### bind事件框架

```java
// AbstractUnsafe.java
@Override
public final void bind(final SocketAddress localAddress, final ChannelPromise promise) {
    assertEventLoop();

    if (!promise.setUncancellable() || !ensureOpen(promise)) { // 确保Channel没有关闭
        return;
    }
		...
    
    boolean wasActive = isActive();
    try {
        doBind(localAddress); // 模板方法，细节由子类完成
    } catch (Throwable t) {
        safeSetFailure(promise, t);
        closeIfClosed();
        return;
    }
    // 绑定后，才是开始激活
    if (!wasActive && isActive()) {
        invokeLater(new Runnable() {
            @Override
            public void run() {
                pipeline.fireChannelActive(); // 触发Active事件
            }
        });
    }

    safeSetSuccess(promise);
}
```

bind事件框架较为简单，主要完成在`Channel`绑定完成后触发`Channel`的Active事件。其中的`invokeLater()`方法向`Channel`注册到的`EventLoop`提交一个任务：

```java
// AbstractUnsafe.java
private void invokeLater(Runnable task) {
    try {
        eventLoop().execute(task);
    } catch (RejectedExecutionException e) {
        logger.warn("Can't invoke task later as EventLoop rejected it", e);
    }
}
```

`closeIfClosed()`方法当`Channel`不再打开时关闭`Channel`，代码如下：

```java
// AbstractUnsafe.java
protected final void closeIfClosed() {
    if (isOpen()) {
        return;
    }
    close(voidPromise());
}
```

close()也是一个框架，之后会进行分析。

#### disconnect事件框架

```java
// AbstractUnsafe.java
@Override
public final void disconnect(final ChannelPromise promise) {
    assertEventLoop();

    if (!promise.setUncancellable()) {
        return;
    }

    boolean wasActive = isActive();
    try {
        doDisconnect(); // 模板方法，细节由子类实现
        // Reset remoteAddress and localAddress
        remoteAddress = null;
        localAddress = null;
    } catch (Throwable t) {
        safeSetFailure(promise, t);
        closeIfClosed();
        return;
    }

    if (wasActive && !isActive()) {
        invokeLater(new Runnable() {
            @Override
            public void run() {
                pipeline.fireChannelInactive();
            }
        });
    }

    safeSetSuccess(promise);
    closeIfClosed(); // doDisconnect() might have closed the channel，disconnect框架可能会调用close框架
}
```

#### close事件框架

```java
// AbstractUnsafe.java
private void close(final ChannelPromise promise, final Throwable cause,
                   final ClosedChannelException closeCause, final boolean notify) {
    if (!promise.setUncancellable()) {
        return;
    }

    if (closeInitiated) {
        if (closeFuture.isDone()) { // 已经关闭，保证底层close只执行一次
            // Closed already.
            safeSetSuccess(promise);
        } else if (!(promise instanceof VoidChannelPromise)) { // Only needed if no VoidChannelPromise.
            // This means close() was called before so we just register a listener and return
            closeFuture.addListener(new ChannelFutureListener() {
                @Override
                public void operationComplete(ChannelFuture future) throws Exception {
                    promise.setSuccess(); // 当Channel关闭时，将此次close异步请求结果也设置为成功
                }
            });
        }
        return;
    }

    closeInitiated = true;

    final boolean wasActive = isActive();
    final ChannelOutboundBuffer outboundBuffer = this.outboundBuffer;
    // 不接受消息。outboundBuffer作为一个标记，为空表示Channel正在关闭
        this.outboundBuffer = null; // Disallow adding any messages and flushes to outboundBuffer.
    Executor closeExecutor = prepareToClose();
    if (closeExecutor != null) {
        closeExecutor.execute(new Runnable() {
            @Override
            public void run() {
                try {
                    // Execute the close. prepareToClose返回的executor执行
                    // 走到这，说明solinger（单位：秒）设置了，Close会阻塞一定时间/或数据处理完毕再关闭
                    doClose0(promise);
                } finally {
                    // Call invokeLater so closeAndDeregister is executed in the EventLoop again!
                    invokeLater(new Runnable() {
                        @Override
                        public void run() { // Channel注册的EventLoop执行
                            if (outboundBuffer != null) {
                                // Fail all the queued messages. 写缓冲队列中的数据全部设置失败
                                outboundBuffer.failFlushed(cause, notify); // 移除flushedEntry指针之后的所有Entry
                                outboundBuffer.close(closeCause);
                            }
                            fireChannelInactiveAndDeregister(wasActive);
                        }
                    });
                }
            }
        });
    } else { // 当前调用线程执行
        try {
            // Close the channel and fail the queued messages in all cases.
            doClose0(promise);
        } finally {
            if (outboundBuffer != null) {
                // Fail all the queued messages.
                outboundBuffer.failFlushed(cause, notify);
                outboundBuffer.close(closeCause);
            }
        }
        if (inFlush0) {
            invokeLater(new Runnable() {
                @Override
                public void run() {
                    fireChannelInactiveAndDeregister(wasActive);
                }
            });
        } else {
            fireChannelInactiveAndDeregister(wasActive);
        }
    }
}

private void doClose0(ChannelPromise promise) {
    try {
        doClose(); // 模板方法，细节由子类实现
        closeFuture.setClosed();
        safeSetSuccess(promise);
    } catch (Throwable t) {
        closeFuture.setClosed();
        safeSetFailure(promise, t);
    }
}
```

close事件框架保证只有一个线程执行了真正关闭的`doClose()`方法，`prepareToClose()`做一些关闭前的清除工作并返回一个`Executor`，如果不为空，需要在该`Executor`里执行`doClose0()`方法；如果为空，则在当前线程执行（为什么这样设计？）。

写缓冲区`outboundBuffer`同时也作为一个标记字段，为空表示`Channel`正在关闭，此时禁止写操作。`fireChannelInactiveAndDeregister()`方法需要`invokeLater()`使用`EventLoop`执行，是因为其中会调用`deRegister()`方法触发Inactive事件，而事件执行需要在`EventLoop`中执行。

```java
// AbstractUnsafe.java
private void fireChannelInactiveAndDeregister(final boolean wasActive) {
    deregister(voidPromise(), wasActive && !isActive());
}
```

#### deregister事件框架

```java
// AbstractUnsafe.java
@Override
public final void deregister(final ChannelPromise promise) {
    assertEventLoop();

    deregister(promise, false);
}

private void deregister(final ChannelPromise promise, final boolean fireChannelInactive) {
    if (!promise.setUncancellable()) {
        return;
    }

    if (!registered) { // 已经deregister
        safeSetSuccess(promise);
        return;
    }

    invokeLater(new Runnable() {
        @Override
        public void run() {
            try {
                doDeregister();  // 模板方法，子类实现具体细节
            } catch (Throwable t) {
                logger.warn("Unexpected exception occurred while deregistering a channel.", t);
            } finally {
                if (fireChannelInactive) {
                    pipeline.fireChannelInactive(); // channelInactive，根据参数触发Inactive事件
                }
                if (registered) {
                    registered = false;
                    pipeline.fireChannelUnregistered(); // channelUnregistered，首次调用触发Unregistered事件
                }
                safeSetSuccess(promise);
            }
        }
    });
}
```

deregister事件框架的处理流程很清晰，其中，使用`invokeLater()`方法是因为：用户可能会在`ChannlePipeline`中将当前`Channel`注册到新的`EventLoop`，确保`ChannelPipiline`事件和`doDeregister()`在同一个`EventLoop完成`。

需要注意的是：事件之间可能相互调用，比如：disconnect->close->deregister。

#### write事件框架

```java
// AbstractUnsafe.java
@Override
public final void write(Object msg, ChannelPromise promise) {
    assertEventLoop(); //  1.确保该方法的调用是在reactor线程中

    ChannelOutboundBuffer outboundBuffer = this.outboundBuffer;
    // 下面的判断，是判断是否 channel 已经关闭了
    if (outboundBuffer == null) { // 联系close操作，outboundBuffer为空表示Channel正在关闭，禁止写数据
        try {
            // release message now to prevent resource-leak
            ReferenceCountUtil.release(msg);
        } finally {
            // If the outboundBuffer is null we know the channel was closed and so
            // need to fail the future right away. If it is not null the handling of the rest
            // will be done in flush0()
            // See https://github.com/netty/netty/issues/2362
            safeSetFailure(promise,
                    newClosedChannelException(initialCloseCause, "write(Object, ChannelPromise)"));
        }
        return;
    }

    int size;
    try { // 2.过滤待写入的对象，把非ByteBuf对象和FileRegion过滤掉，把所有的非直接内存转换成直接内存DirectBuffer
        msg = filterOutboundMessage(msg); // 委托给AbstractChannel（通常是AbstractNioByteChannel）调用
        size = pipeline.estimatorHandle().size(msg); // 3.估算出需要写入的ByteBuf的size
        if (size < 0) {
            size = 0;
        }
    } catch (Throwable t) {
        try {
            ReferenceCountUtil.release(msg);
        } finally {
            safeSetFailure(promise, t);
        }
        return;
    }
    // 4.消息放到 buf 里面
    outboundBuffer.addMessage(msg, size, promise);
}
```

事实上，这是Netty定义的write操作的全部代码，完成的功能是将要写的消息Msg加入到写缓冲区。其中的`filterOutboundMessage()`可对消息进行过滤整理，例如把`HeapBuffer`转为`DirectBuffer`，具体实现由子类负责：

```java
// AbstractChannel.java
protected Object filterOutboundMessage(Object msg) throws Exception {
    return msg; // 默认实现
}
```

#### flush事件框架

```java
// AbstractUnsafe.java
@Override
public final void flush() {
    assertEventLoop();

    ChannelOutboundBuffer outboundBuffer = this.outboundBuffer;
    if (outboundBuffer == null) { // outboundBuffer == null 表明 channel 关闭了
        return; // Channel正在关闭直接返回
    }

    outboundBuffer.addFlush(); // 添加一个标记
    flush0();
}

@SuppressWarnings("deprecation")
protected void flush0() {
    if (inFlush0) { // 正在flush返回防止多次调用
        // Avoid re-entrance
        return;
    }

    final ChannelOutboundBuffer outboundBuffer = this.outboundBuffer;
    if (outboundBuffer == null || outboundBuffer.isEmpty()) {
        return; // Channel正在关闭或者已没有需要写的数据
    }

    inFlush0 = true;

    // Mark all pending write requests as failure if the channel is inactive.
    if (!isActive()) { // Channel已经非激活，将所有进行中的写请求标记为失败
        try {
            // Check if we need to generate the exception at all.
            if (!outboundBuffer.isEmpty()) {
                if (isOpen()) {
                    outboundBuffer.failFlushed(new NotYetConnectedException(), true);
                } else {
                    // Do not trigger channelWritabilityChanged because the channel is closed already.
                    outboundBuffer.failFlushed(newClosedChannelException(initialCloseCause, "flush0()"), false);
                }
            }
        } finally {
            inFlush0 = false;
        }
        return;
    }

    try {
        doWrite(outboundBuffer); // 核心方法，委托给AbstractNioByteChannel执行。模板方法，细节由子类实现
    } catch (Throwable t) {
        handleWriteError(t);
    } finally {
        inFlush0 = false;
    }
}
```

flush事件中执行真正的底层写操作，Netty对于写的处理引入了一个写缓冲区`ChannelOutboundBuffer`，由该缓冲区控制`Channel`的可写状态，其具体实现，将会在缓冲区一章中分析。

至此，`Unsafe`中的事件方法已经分析完7个，但还有connect和read没有引入，下一节将进行分析。

### AbstractNioChannel

Netty的实现中，`Unsafe`的I/O事件框架中的细节实现方法doXXX()放到了`Channel`子类中而不是`Unsafe`子类中，所以我们先分析`Unsafe`，然后分析`Channel`。

`AbstractNioChanne`l从名字可以看出是对NIO的抽象，我们自顶向下一步一步深入细节，该类中定义了一个`NioUnsafe`接口：

```java
// NioUnsafe.java
public interface NioUnsafe extends Unsafe {
    SelectableChannel ch(); // 对应NIO中的JDK实现的Channel
    void finishConnect();   // 连接完成
    void read();    // 从JDK的Channel中读取数据
    void forceFlush(); 
}
```

回忆NIO的三大概念：`Channel`、`Buffer`、`Selector`，Netty的`Channel`包装了JDK的`Channel`从而实现更为复杂的功能。`Unsafe`中可以使用ch()方法，`NioChannel`中可以使用`javaChannel()`方法获得JDK的`Channel`。

接口中定义了`finishConnect()`方法是因为：`SelectableChannel`设置为非阻塞模式时，`connect()`方法会立即返回，此时连接操作可能没有完成，如果没有完成，则需要调用JDK的`finishConnect()`方法完成连接操作。也许你已经注意到，`AbstractUnsafe`中并没有connect事件框架，这是因为并不是所有连接都有标准的connect过程，比如Netty的`LocalChannel`和`EmbeddedChannel`。但是NIO中的连接操作则有较为标准的流程，在介绍Connect事件框架前，先介绍一下其中使用到的相关字段，这些字段定义在`AbstractNioChannel`中：

```java
// AbstractNioChannel.java
private ChannelPromise connectPromise;  // 连接异步结果
private ScheduledFuture<?> connectTimeoutFuture;    // 连接超时检测任务异步结果
private SocketAddress requestedRemoteAddress;   // 连接的远端地址
```

#### connect事件框架

```java
// AbstractNioUnsafe.java
@Override
public final void connect(
        final SocketAddress remoteAddress, final SocketAddress localAddress, final ChannelPromise promise) {
    if (!promise.setUncancellable() || !ensureOpen(promise)) { // Channel已被关闭
        return;
    }

    try {
        if (connectPromise != null) { // 已有连接操作正在进行
            // Already a connect in process.
            throw new ConnectionPendingException();
        }

        boolean wasActive = isActive();
        if (doConnect(remoteAddress, localAddress)) { // 做 JDK 底层的 SocketChannel connect，返回值代表是否已经连接成功。模板方法，细节子类完成
            fulfillConnectPromise(promise, wasActive); // 处理连接成功的情况
        } else { // 连接操作尚未完成
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
                        if (connectTimeoutFuture != null) { // 连接操作取消则连接超时检测任务取消
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

Connect事件框架中包含了Netty的连接超时检测机制：向`EventLoop`提交一个调度任务，设定的超时时间已到则向连接操作的异步结果设置失败然后关闭连接。`fulfillConnectPromise()`设置异步结果为成功并触发`Channel`的Active事件。

```java
// AbstractNioUnsafe.java
private void fulfillConnectPromise(ChannelPromise promise, boolean wasActive) {
    if (promise == null) { // 操作已取消或Promise已被通知？
        // Closed via cancellation and the promise has been notified already.
        return;
    }

    boolean active = isActive();

    boolean promiseSet = promise.trySuccess();  // False表示用户取消操作

    if (!wasActive && active) { // 此时用户没有取消Connect操作
        pipeline().fireChannelActive(); // 触发Active事件
    }

    if (!promiseSet) {
        close(voidPromise()); // 操作已被用户取消，关闭Channel
    }
}
```

#### finishConnect事件框架

```java
// AbstractNioUnsafe.java
@Override
public final void finishConnect() {
    // Note this method is invoked by the event loop only if the connection attempt was
    // neither cancelled nor timed out.

    assert eventLoop().inEventLoop();

    try {
        boolean wasActive = isActive();
        doFinishConnect(); // 模板方法
        fulfillConnectPromise(connectPromise, wasActive); // 首次Active触发Active事件
    } catch (Throwable t) {
        fulfillConnectPromise(connectPromise, annotateConnectException(t, requestedRemoteAddress));
    } finally {
        // Check for null as the connectTimeoutFuture is only created if a connectTimeoutMillis > 0 is used
        // See https://github.com/netty/netty/issues/1770
        if (connectTimeoutFuture != null) {
            connectTimeoutFuture.cancel(false); // 连接完成，取消超时检测任务
        }
        connectPromise = null;
    }
}
```

finishConnect()只由`EventLoop`处理就绪selectionKey为OP_CONNECT事件时调用，从而完成连接操作。注意：连接操作被取消或者超时不会使该方法被调用。

#### flush事件框架

`AbstractNioUnsafe`重写了父类的`flush0()`。

```java
// AbstractNioUnsafe.java
@Override
protected final void flush0() {
    if (!isFlushPending()) {
        super.flush0(); // 调用父类方法
    }
}

@Override
public final void forceFlush() {
    // directly call super.flush0() to force a flush now
    super.flush0(); // 调用父类方法
}

private boolean isFlushPending() {
    SelectionKey selectionKey = selectionKey();
    return selectionKey.isValid() && (selectionKey.interestOps() & SelectionKey.OP_WRITE) != 0;
}
```

`forceFlush()`方法由`EventLoop`处理就绪 selectionKey 的 OP_WRITE 事件时调用，将缓冲区中的数据入`Channel`。`isFlushPending()`方法容易导致困惑：为什么 selectionKey 关心 OP_WRITE 事件表示正在 Flush 呢？ OP_WRITE 表示通道可写，而一般情况下通道都可写，如果 selectionKey 一直关心 OP_WRITE 事件，那么将不断从`select()`方法返回从而导致死循环。Netty 使用一个写缓冲区，write 操作将数据放入缓冲区中，flush 时设置 selectionKey 关心 OP_WRITE 事件，完成后取消关心 OP_WRITE 事件。所以，如果selectionKey 关心 OP_WRITE 事件表示此时正在Flush数据。

`AbstractNioUnsafe`还有最后一个方法`removeReadOp()`：

```java
// AbstractNioUnsafe.java
protected final void removeReadOp() {
    SelectionKey key = selectionKey();
    if (!key.isValid()) { // selectionKey已被取消
        return;
    }
    int interestOps = key.interestOps();
    if ((interestOps & readInterestOp) != 0) {
        // only remove readInterestOp if needed
        key.interestOps(interestOps & ~readInterestOp); // 设置为不再感兴趣
    }
}
```

Netty中将服务端的 OP_ACCEPT 和客户端的 Read 统一抽象为Read 事件，在NIO底层I/O事件使用 bitmap 表示，一个二进制位对应一个I/O事件。当一个二进制位为1时表示关心该事件，`readInterestOp`的二进制表示只有1位为1，所以体会`interestOps & ~readInterestOp`的含义，可知`removeReadOp()`的功能是设置 SelectionKey 不再关心 Read 事件。类似的，还有`setReadOp()`、`removeWriteOp()`、`setWriteOp()`等等。

分析完`AbstractNioUnsafe`，我们再分析`AbstractNioChannel`，首先看其中还没讲解的字段：

```java
// AbstractNioChannel.java
private final SelectableChannel ch; // 包装的JDK Channel
protected final int readInterestOp; // Read事件，服务端OP_ACCEPT，其他OP_READ
volatile SelectionKey selectionKey; // JDK Channel对应的选择键
private volatile boolean readPending;   // 底层读事件进行标记
```

再看一下构造方法：

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

其中的`ch.configureBlocking(false)`方法设置`Channel`为非阻塞模式，从而为Netty提供非阻塞处理I/O事件的能力。

#### doXXX()方法

对于`AbstractNioChanne`l的方法，我们主要分析它实现I/O事件框架细节部分的`doXXX()`方法。

```java
// AbstractNioChannel.java
@Override
protected void doRegister() throws Exception {
    boolean selected = false;
    for (;;) {
        try { // 调用 JDK 的 API，将 channel 注册到 nioEventLoop 里绑定的 selector ，ops = 0 ，
            selectionKey = javaChannel().register(eventLoop().unwrappedSelector(), 0, this);
            return;
        } catch (CancelledKeyException e) {
            if (!selected) {.
                eventLoop().selectNow(); // 选择键取消重新selectNow()，清除因取消操作而缓存的选择键
                selected = true;
            } else {
                throw e;
            }
        }
    }
}

@Override
protected void doDeregister() throws Exception {
    eventLoop().cancel(selectionKey()); // 设置取消选择键
}
```

对于 Register 事件，当`Channel`属于NIO时，已经可以确定注册操作的全部细节：将`Channel`注册到给定`NioEventLoop`的`selector`上即可。注意，其中第二个参数0表示**注册时不关心任何事件**，第三个参数为 Netty 的`NioChannel`对象本身。

对于 Deregister 事件，选择键执行`cancle()`操作，选择键表示JDK `Channel`和`selctor`的关系，调用`cancle()`终结这种关系，从而实现从`NioEventLoop`中 Deregister 。需要注意的是：`cancle`操作调用后，注册关系不会立即生效，而会将 cancle 的 key 移入selector的一个取消键集合，当下次调用`select`相关方法或一个正在进行的`select`调用结束时，会从取消键集合中移除该选择键，此时注销才真正完成。一个Cancle的选择键为无效键，调用它相关的方法会抛出`CancelledKeyException`。

```java
// AbstractNioChannel.java
@Override
protected void doBeginRead() throws Exception {
    // Channel.read() or ChannelHandlerContext.read() was called
    // 前面register步骤返回的对象，前面我们在register的时候，注册的ops是0
    final SelectionKey selectionKey = this.selectionKey;
    if (!selectionKey.isValid()) { // 选择键被取消而不再有效
        return;
    }

    readPending = true; // 设置底层读事件正在进行
    // 获取前面监听的 ops = 0，
    final int interestOps = selectionKey.interestOps();
    // 假设之前没有监听readInterestOp，则监听readInterestOp
    // 就是之前new NioServerSocketChannel 时 super(null, channel, SelectionKey.OP_ACCEPT); 传进来保存到则监听readInterestOp的
    if ((interestOps & readInterestOp) == 0) { // interestOps 不包括 readInterestOp，https://cloud.tencent.com/developer/article/1603990
        logger.info("interest ops：{}", readInterestOp);
        selectionKey.interestOps(interestOps | readInterestOp); // 真正的注册 interestOps，做好连接的准备
    }
}
```

对于`NioChannel`的 beginRead 事件，只需将 Read 事件设置为选择键所关心的事件，则之后的`select()`调用如果`Channel`对应的 Read 事件就绪，便会触发 Netty 的 `read()`操作。

```java
// AbstractNioChannel.java
protected void doClose() throws Exception {
    ChannelPromise promise = connectPromise;
    if (promise != null) { // 连接操作还在进行，但用户调用close操作
        // Use tryFailure() instead of setFailure() to avoid the race against cancel().
        promise.tryFailure(new ClosedChannelException());
        connectPromise = null;
    }

    Future<?> future = connectTimeoutFuture;
    if (future != null) { // 如果有连接超时检测任务，则取消
        future.cancel(false);
        connectTimeoutFuture = null;
    }
}
```

此处的`doClose`操作主要处理了连接操作相关的后续处理。并没有实际关闭`Channel`，所以需要子类继续增加细节实现。`AbstractNioChannel`中还有关于创建`DirectBuffer`的方法，将在以后必要时进行分析。其他的方法则较为简单，不在列出。最后提一下`isCompatible()`方法，说明`NioChannel`只在`NioEventLoop`中可用。

```java
// AbstractNioChannel.java
@Override
protected boolean isCompatible(EventLoop loop) {
    return loop instanceof NioEventLoop;
}
```

`AbstractNioChannel`的子类实现分为服务端`AbstractNioMessageChannel`和客户端`AbstractNioByteChannel`，我们将首先分析服务端`AbstractNioMessageChannel`。

### AbstractNioMessageChannel

`AbstractNioMessageChannel`是底层数据为消息的`NioChannel`。在 Netty 中，**服务端 Accept 的一个`Channel`被认为是一条消息**，UDP数据报也是一条消息。该类主要完善 flush 事件框架的`doWrite`细节和实现 read 事件框架（在内部类`NioMessageUnsafe`完成）。首先看 read 事件框架：

```java
// NioMessageUnsafe.java
@Override
public void read() {
    assert eventLoop().inEventLoop();
    final ChannelConfig config = config();
    final ChannelPipeline pipeline = pipeline();
    final RecvByteBufAllocator.Handle allocHandle = unsafe().recvBufAllocHandle(); // 获取之前在创建channel配置器的时候传入的AdaptiveRecvByteBufAllocator
    allocHandle.reset(config); // 重置一些变量

    boolean closed = false;
    Throwable exception = null;
    try {
        try {
            do { // 委托到所在的外部类NioSocketChannel，doReadMessages方法不断地读取消息，用 readBuf 作为容器，读取的是一个个连接
                int localRead = doReadMessages(readBuf); // Message的含义我们可以当作是一个SelectableChannel，读的意思就是accept一个SelectableChannel
                if (localRead == 0) { // 没有数据可读
                    break;
                }
                if (localRead < 0) { // 读取出错
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
            readPending = false; // 已没有底层读事件
            // 创建的结果（socketChannel）通过 fireChannelRead 传播出去了，就是各种 handler 的串行执行
            pipeline.fireChannelRead(readBuf.get(i));
        }
        readBuf.clear();
        allocHandle.readComplete();
        pipeline.fireChannelReadComplete();  // 触发ChannelReadComplete事件，用户处理

        if (exception != null) {
            closed = closeOnReadError(exception); // ServerChannel异常也不能关闭，应该恢复读取下一个客户端

            pipeline.fireExceptionCaught(exception);
        }

        if (closed) {
            inputShutdown = true;
            if (isOpen()) { // 非serverChannel且打开则关闭
                close(voidPromise());
            }
        }
    } finally {
        if (!readPending && !config.isAutoRead()) { // 既没有配置autoRead也没有底层读事件进行
            removeReadOp();
        }
    }
}
```

read 事件框架的流程已在代码中注明，需要注意的是读取消息的细节`doReadMessages(readBuf)`方法由子类实现。

我们主要分析`NioServerSocketChanne`l，它不支持`doWrite()`操作，所以我们不再分析本类的 flush 事件框架的`doWrite`细节方法，直接转向下一个目标：`NioServerSocketChannel`。

### NioServerSocketChannel

你肯定已经使用过`NioServerSocketChannel`，作为处于`Channel`最底层的子类，`NioServerSocketChannel`会实现I/O事件框架的底层细节。首先需要注意的是：`NioServerSocketChannel`**只支持bind、read和close操作**。

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

@Override
protected void doClose() throws Exception {
    javaChannel().close();
}

@Override
protected int doReadMessages(List<Object> buf) throws Exception {
    // 接受新连接查创建SocketChannel
    SocketChannel ch = SocketUtils.accept(javaChannel()); // 调用jdk的 accept()方法，新建立一条连接。

    try {
        if (ch != null) { // 一个NioSocketChannel为一条消息
            buf.add(new NioSocketChannel(this, ch)); // 封装成自定义的 NioSocketChannel，加入到buf里面
            return 1;
        }
    } catch (Throwable t) {
        logger.warn("Failed to create a new channel from an accepted socket.", t);

        try {
            ch.close();
        } catch (Throwable t2) {
            logger.warn("Failed to close a socket.", t2);
        }
    }

    return 0;
}
```

其中的实现，都是调用JDK的`Channel`的方法，从而实现了最底层的细节。需要注意的是：此处的`doReadMessages()`方法每次最多返回一个消息（客户端连接），由此可知`NioServerSocketChannel`的 read 操作一次至多处理的连接数为`config.getMaxMessagesPerRead()`，也就是参数值`MAX_MESSAGES_PER_READ`。此外`doClose()`覆盖了`AbstractNioChannel`的实现，因为`NioServerSocketChannel`不支持 connect 操作，所以不需要连接超时处理。

```java
// NioServerSocketChannel.java
public NioServerSocketChannel(ServerSocketChannel channel) {
    super(null, channel, SelectionKey.OP_ACCEPT); // 对于服务端来说，关心的是 SelectionKey.OP_ACCEPT 事件，等待客户端连接
    config = new NioServerSocketChannelConfig(this, javaChannel().socket());
}
```

其中的`SelectionKey.OP_ACCEPT`最为关键， Netty 正是在此处将`NioServerSocketChannel`的 read 事件定义为 NIO 底层的 OP_ACCEPT ，统一完成 read 事件的抽象。

至此，我们已分析完两条线索中的服务端部分，下面分析客户端部分。首先是`AbstractNioChannel`的另一个子类`AbstractNioByteChannel`。

### AbstractNioByteChannel

从字面可推知，`AbstractNioByteChannel`的底层数据为 Byte 字节。首先看构造方法：

```java
// AbstractNioByteChannel.java
protected AbstractNioByteChannel(Channel parent, SelectableChannel ch) {
    super(parent, ch, SelectionKey.OP_READ); //注册OP_READ事件，表示对channel的读感兴趣
}
```

其中的`SelectionKey.OP_READ`，说明`AbstractNioByteChannel`的 read 事件为 NIO 底层的 OP_READ 事件。

#### read事件框架

然后我们看read事件框架：

```java
// NioByteUnsafe.java
@Override
public final void read() {
    final ChannelConfig config = config();
    if (shouldBreakReadReady(config)) {
        clearReadPending();
        return;
    }
    final ChannelPipeline pipeline = pipeline();
    final ByteBufAllocator allocator = config.getAllocator(); // 获取缓冲区分配器
    // io.netty.channel.DefaultChannelConfig 中设置 RecvByteBufAllocator ，默认 AdaptiveRecvByteBufAllocator
    final RecvByteBufAllocator.Handle allocHandle = recvBufAllocHandle();
    allocHandle.reset(config); // 重置一些变量

    ByteBuf byteBuf = null;
    boolean close = false;
    try {
        do {
            // 分配一个ByteBuf，尽可能分配合适的大小：guess，第一次就是 1024 byte
            byteBuf = allocHandle.allocate(allocator);
            // 读并且记录读了多少，如果读满了，下次continue的话就直接扩容。
            allocHandle.lastBytesRead(doReadBytes(byteBuf)); // doReadBytes(byteBuf)，委托到所在的外部类NioSocketChannel
            if (allocHandle.lastBytesRead() <= 0) { // 没有读取到数据，则释放缓冲区
                // nothing was read. release the buffer. 数据清理
                byteBuf.release();
                byteBuf = null;
                close = allocHandle.lastBytesRead() < 0; // 读取数据量为负数表示对端已经关闭
                if (close) {
                    // There is nothing left to read as we received an EOF.
                    readPending = false;
                }
                break;
            }
            // 记录一下读了几次，仅仅一次
            allocHandle.incMessagesRead(1); // 读取的总信息++
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
        if (!readPending && !config.isAutoRead()) { // 此时读操作不被允许，既没有配置autoRead也没有底层读事件进行
            removeReadOp();
        }
    }
}
```

`AbstractNioByteChannel`的 read 事件框架处理流程与`AbstractNioMessageChannel`的稍有不同：`AbstractNioMessageChannel`依次读取 Message ，最后统一触发 ChannelRead 事件；而`AbstractNioByteChannel`每读取到一定字节就触发 ChannelRead 事件。这是因为，`AbstractNioMessageChannel`需要高吞吐量，特别是`ServerSocketChannel`需要尽可能多地接受连接；而`AbstractNioByteChannel`需求快响应，要尽可能快地响应远端请求。

read 事件的具体流程请参考代码和代码注释进行理解，不再分析。注意到代码中有关于接收缓冲区的代码，这一部分我们单独使用一节讲述，之后会分析。当读取到的数据小于零时，表示远端连接已关闭，这时会调用`closeOnRead(pipeline)`方法：

```java
// NioByteUnsafe.java
private void closeOnRead(ChannelPipeline pipeline) {
    // input 关闭了么？没有
    if (!isInputShutdown0()) {
        // 是否支持半关？如果是，关闭读，触发事件
        if (isAllowHalfClosure(config())) {
            shutdownInput(); // 远端关闭此时设置Channel的输入源关闭
            pipeline.fireUserEventTriggered(ChannelInputShutdownEvent.INSTANCE);
        } else {
            close(voidPromise());
        }
    } else {
        inputClosedSeenErrorOnRead = true;
        pipeline.fireUserEventTriggered(ChannelInputShutdownReadComplete.INSTANCE);
    }
}
```

这段代码正是`Channel`参数`ALLOW_HALF_CLOSURE`的意义描述，该参数为 True 时，会触发用户事件`ChannelInputShutdownEvent`，否则，触发用户事件`ChannelInputShutdownReadComplete`。

抛出异常时，会调用`handleReadException(pipeline, byteBuf, t, close)`方法：

```java
// NioByteUnsafe.java
private void handleReadException(ChannelPipeline pipeline, ByteBuf byteBuf, Throwable cause, boolean close,
        RecvByteBufAllocator.Handle allocHandle) {
    if (byteBuf != null) { // 已读取到数据
        if (byteBuf.isReadable()) { // 数据可读
            readPending = false;
            pipeline.fireChannelRead(byteBuf);
        } else { // 数据不可读
            byteBuf.release();
        }
    }
    allocHandle.readComplete();
    pipeline.fireChannelReadComplete();
    pipeline.fireExceptionCaught(cause);

    if (close || cause instanceof OutOfMemoryError || cause instanceof IOException) {
        closeOnRead(pipeline);
    }
}
```

可见，抛出异常时，如果读取到可用数据和正常读取一样触发 ChannelRead 事件，只是最后会统一触发 ExceptionCaught 事件由用户进行处理。

至此， read 事件框架分析完毕，下面我们分析 write 事件的细节实现方法`doWrite()`。在此之前，先看`filterOutboundMessage()`方法对需要写的数据进行过滤。

#### write事件框架

```java
// AbstractNioByteChannel.java
// 过滤非ByteBuf和FileRegion的对象
@Override
protected final Object filterOutboundMessage(Object msg) {
    if (msg instanceof ByteBuf) {
        ByteBuf buf = (ByteBuf) msg;
        if (buf.isDirect()) {
            return msg;
        }

        return newDirectBuffer(buf); // 所有的非直接内存转换成直接内存DirectBuffer
    }

    if (msg instanceof FileRegion) {
        return msg;
    }

    throw new UnsupportedOperationException(
            "unsupported message type: " + StringUtil.simpleClassName(msg) + EXPECTED_TYPES);
}
```

可知， Netty 支持的写数据类型只有两种：**`DirectBuffer`**和**`FileRegion`**。我们再看这些数据怎么写到`Channel`上，也就是`doWrite()`方法：

```java
// AbstractNioByteChannel.java
@Override
protected void doWrite(ChannelOutboundBuffer in) throws Exception {
    int writeSpinCount = config().getWriteSpinCount(); // 1.拿到自旋锁迭代次数
    do {
        Object msg = in.current(); // 2.拿到第一个需要flush的节点的数据
        if (msg == null) { // 数据已全部写完
            // Wrote all messages.
            clearOpWrite(); // 清除OP_WRITE事件
            // Directly return here so incompleteWrite(...) is not called.
            return;
        }
        writeSpinCount -= doWriteInternal(in, msg); // 3.不断的自旋调用doWriteInternal方法，直到自旋次数小于或等于0为止
    } while (writeSpinCount > 0);

    incompleteWrite(writeSpinCount < 0);
}

private int doWriteInternal(ChannelOutboundBuffer in, Object msg) throws Exception {
    if (msg instanceof ByteBuf) {
        ByteBuf buf = (ByteBuf) msg;
        if (!buf.isReadable()) {
            in.remove();
            return 0;
        }

        final int localFlushedAmount = doWriteBytes(buf); // 将当前节点写出，模板方法，子类实现细节
        if (localFlushedAmount > 0) { // NIO在非阻塞模式下写操作可能返回0表示未写入数据
            in.progress(localFlushedAmount); // 记录进度
            if (!buf.isReadable()) {
                in.remove(); // 写完之后，将当前节点删除
            }
            return 1;
        }
    } else if (msg instanceof FileRegion) {
        FileRegion region = (FileRegion) msg;
        if (region.transferred() >= region.count()) {
            in.remove();
            return 0;
        }

        long localFlushedAmount = doWriteFileRegion(region);
        if (localFlushedAmount > 0) {
            in.progress(localFlushedAmount);
            if (region.transferred() >= region.count()) {
                in.remove();
            }
            return 1;
        }
    } else {
        // Should not reach here.
        throw new Error();  // 其他类型不支持
    }
    return WRITE_STATUS_SNDBUF_FULL;
}
```

`FileRegion`是 Netty 对 NIO 底层的`FileChannel`的封装，负责将 File 中的数据写入到`WritableChannel`中。`FileRegion`的默认实现是`DefaultFileRegion`，如果你很感兴趣它的实现，可以自行查阅。

我们主要分析对 ByteBuf 的处理。`doWrite`的流程简洁明了，核心操作是模板方法`doWriteBytes(buf)`，将 ByteBuf 中的数据写入到`Channel`，由于 NIO 底层的写操作返回已写入的数据量，在非阻塞模式下该值可能为0，此时会调用`incompleteWrite()`方法：

```java
// AbstractNioByteChannel.java
protected final void incompleteWrite(boolean setOpWrite) {
    // Did not write completely.
    if (setOpWrite) {
        setOpWrite(); // 设置继续关心OP_WRITE事件
    } else {  // 此时已进行写操作次数writeSpinCount，但并没有写完
        clearOpWrite();

        eventLoop().execute(flushTask); // 再次提交一个flush()任务
    }
}
```

该方法分两种情况处理，在上文提到的第一种情况（实际写0数据）下，设置`SelectionKey`继续关心 OP_WRITE 事件从而继续进行写操作；第二种情况下，也就是写操作进行次数达到配置中的`writeSpinCount`值但尚未写完，此时向`EventLoop`提交一个新的 flush 任务，此时可以响应其他请求，从而提交响应速度。这样的处理，不会使大数据的写操作占用全部资源而使其他请求得不到响应，可见这是一个较为公平的处理。这里引出一个问题：使用 Netty 如何搭建高性能文件服务器？

至此，已分析完对于 Byte 数据的 read 事件和`doWrite`细节的处理，接下里，继续分析`NioSocketChannel`，从而完善各事件框架的细节部分。

### NioSocketChannel

`NioSocketChannel`作为`Channel`的最末端子类，实现了`NioSocket`相关的最底层细节实现，首先看`doBind()`：

```java
// NioSocketChannel.java
@Override
protected void doBind(SocketAddress localAddress) throws Exception {
    doBind0(localAddress);
}

private void doBind0(SocketAddress localAddress) throws Exception {
    if (PlatformDependent.javaVersion() >= 7) { // JDK版本1.7以上
        SocketUtils.bind(javaChannel(), localAddress);
    } else {
        SocketUtils.bind(javaChannel().socket(), localAddress);
    }
}
```

这部分代码与`NioServerSocketChannel`中相同，委托给JDK的`Channel`进行绑定操作。

接着再看`doConnect()`和`doFinishConnect()`方法：

```java
// NioSocketChannel.java
@Override
protected boolean doConnect(SocketAddress remoteAddress, SocketAddress localAddress) throws Exception {
    if (localAddress != null) {
        doBind0(localAddress);
    }

    boolean success = false;
    try {
        boolean connected = SocketUtils.connect(javaChannel(), remoteAddress);
        if (!connected) {
            selectionKey().interestOps(SelectionKey.OP_CONNECT); // 设置关心OP_CONNECT事件，事件就绪时调用finishConnect()
        }
        success = true;
        return connected;
    } finally {
        if (!success) {
            doClose();
        }
    }
}

@Override
protected void doFinishConnect() throws Exception {
    if (!javaChannel().finishConnect()) {
        throw new Error();
    }
}
```

JDK中的`Channel`在非阻塞模式下调用`connect()`方法时，会立即返回结果：成功建立连接返回 True ，操作还在进行时返回 False 。返回 False 时，需要在底层 OP_CONNECT 事件就绪时，调用`finishConnect()`方法完成连接操作。

再看`doDisconnect()`和`doClose()`方法：

```java
// NioSocketChannel.java
@Override
protected void doDisconnect() throws Exception {
    doClose();
}

@Override
protected void doClose() throws Exception {
    super.doClose(); // AbstractNioChannel中关于连接超时的处理
    javaChannel().close();
}
```

然后看核心的`doReadBytes()`和`doWriteXXX()`方法：

```java
// NioSocketChannel.java
@Override
protected int doReadBytes(ByteBuf byteBuf) throws Exception {
    final RecvByteBufAllocator.Handle allocHandle = unsafe().recvBufAllocHandle();
    allocHandle.attemptedBytesRead(byteBuf.writableBytes());
    return byteBuf.writeBytes(javaChannel(), allocHandle.attemptedBytesRead()); // 将jdk的 SelectableChannel的字节数据读取到netty的ByteBuf中
}

@Override
protected int doWriteBytes(ByteBuf buf) throws Exception {
    final int expectedWrittenBytes = buf.readableBytes();
    return buf.readBytes(javaChannel(), expectedWrittenBytes);
}

@Override
protected long doWriteFileRegion(FileRegion region) throws Exception {
    final long position = region.transferred();
    return region.transferTo(javaChannel(), position);
}
```

对于 read 和 write 操作，委托给`ByteBuf`处理，我们将使用专门的一章，对这一部分细节进行完善，将在后面介绍。

`NioSocketChannel`最重要的部分是覆盖了父类的`doWrite()`方法，使用更高效的方式进行写操作，其代码如下：

```java
// NioSocketChannel.java
@Override
protected void doWrite(ChannelOutboundBuffer in) throws Exception {
    SocketChannel ch = javaChannel();
    // 有数据要写，且能写入，这最多尝试16次
    int writeSpinCount = config().getWriteSpinCount();
    do {
        if (in.isEmpty()) {
            // All written so clear OP_WRITE
            // 数据都写完了，不用也不需要写16次
            clearOpWrite();
            // Directly return here so incompleteWrite(...) is not called.
            return;
        }

        // Ensure the pending writes are made of ByteBufs only. 尽量想多写点数据
        int maxBytesPerGatheringWrite = ((NioSocketChannelConfig) config).getMaxBytesPerGatheringWrite();
        // 最多返回1024个数据，总的 size 尽量不超过 maxBytesPerGatheringWrite，数据组装成 nioBuffers
        ByteBuffer[] nioBuffers = in.nioBuffers(1024, maxBytesPerGatheringWrite);
        int nioBufferCnt = in.nioBufferCount();

        switch (nioBufferCnt) {
            case 0: // 没有ByteBuffer，也就是只有FileRegion
                // We have something else beside ByteBuffers to write so fallback to normal writes.
                writeSpinCount -= doWrite0(in);
                break;
            case 1: { // 只有一个ByteBuffer
                ByteBuffer buffer = nioBuffers[0];
                int attemptedBytes = buffer.remaining();
                final int localWrittenBytes = ch.write(buffer);
                if (localWrittenBytes <= 0) { // <=0 说明我们写不进去数据了，会注册一个 opWrite 事件，让能写进去的时候再通知我们来写
                    incompleteWrite(true);
                    return;
                }
                adjustMaxBytesPerGatheringWrite(attemptedBytes, localWrittenBytes, maxBytesPerGatheringWrite);
                // 从 ChannelOutboundBuffer 中移除已经写出的数据
                in.removeBytes(localWrittenBytes);
                --writeSpinCount; // 减少写的次数
                break;
            }
            default: { // 多个ByteBuffer，采用gathering方法处理
                long attemptedBytes = in.nioBufferSize();
                final long localWrittenBytes = ch.write(nioBuffers, 0, nioBufferCnt);
                if (localWrittenBytes <= 0) {
                    // 缓存区满了，写不进去了，注册写事件
                    incompleteWrite(true);
                    return;
                }
              
                adjustMaxBytesPerGatheringWrite((int) attemptedBytes, (int) localWrittenBytes,
                        maxBytesPerGatheringWrite);
                in.removeBytes(localWrittenBytes);  // 清理缓冲区
                --writeSpinCount;
                break;
            }
        }
    } while (writeSpinCount > 0);
    // 写了16次数据，还是没有写完，直接 schedule 一个新的 flush task 出来，而不是注册写事件
    incompleteWrite(writeSpinCount < 0);
}
```

在明白了父类的`doWrite`方法后，这段代码便容易理解，本段代码做的优化是：当输出缓冲区中有多个 buffer 时，采用`Gathering Writes`将数据从这些 buffer 写入到同一个 channel。

在`AbstractUnsafe`对 close 事件框架的分析中，有一个`prepareToClose()`方法，进行关闭的必要处理并在必要时返回一个`Executor`执行`doClose()`操作，默认方法返回null，`NioSocketChannelUnsafe`覆盖了父类的实现，代码如下：

```java
// NioSocketChannelUnsafe.java
@Override
protected Executor prepareToClose() {
    try {
        if (javaChannel().isOpen() && config().getSoLinger() > 0) {
            // 需要逗留到数据收发完成或者设置的时间，所以提交到另外的 Executor 中执行
            // 提前 deregister 掉，逗留期不接受新的数据了
            // deregister 包含 selection key 的 cancel 的原因之一。
            doDeregister();
            return GlobalEventExecutor.INSTANCE;
        }
    } catch (Throwable ignore) {
    }
    return null;
}
```

`SO_LINGER`表示 Socket 关闭的延时时间，在此时间内，内核将继续把 TCP 缓冲区的数据发送给对端且执行 close 操作的线程将阻塞直到数据发送完成。Netty 的原则是I/O线程不能被阻塞，所以此时返回一个`Executor`用于执行阻塞的`doClose()`操作。

`doDeregister()`取消选择键`selectionKey`是因为：延迟关闭期间， 如果`selectionKey`仍然关心 OP_WRITE 事件，而输出缓冲区又为null，这样 write 操作直接返回，不会再执行`clearOpWrite()`操作取消关心 OP_WRITE 事件，而`Channel`一般是可写的，这样OP_WRITE 事件会不断就绪从而耗尽 CPU，所以需要取消选择键删除注册的事件。

## 参考

[自顶向下深入分析Netty（六）--Channel总述](https://www.jianshu.com/p/fffc18d33159)

[自顶向下深入分析Netty（六）--Channel源码实现](https://www.jianshu.com/p/9258af254e1d)

