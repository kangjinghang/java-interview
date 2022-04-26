## 总述

`ChannelHandler`并不处理事件，而由其子类代为处理：`ChannelInboundHandler`拦截和处理入站事件，`ChannelOutboundHandler`拦截和处理出站事件。`ChannelHandler`和`ChannelHandlerContext`通过**组合或继承**的方式关联到一起成对使用。事件通过`ChannelHandlerContext`主动调用如`fireXXX()`和`write(msg)`等方法，将事件传播到下一个处理器。注意：入站事件在`ChannelPipeline`双向链表中由头到尾正向传播，出站事件则方向相反。

当客户端连接到服务器时，Netty新建一个`ChannelPipeline`处理其中的事件，而一个`ChannelPipeline`中含有若干`ChannelHandler`。如果每个客户端连接都新建一个`ChannelHandler`实例，当有大量客户端时，服务器将保存大量的`ChannelHandler`实例。为此，Netty提供了`Sharable`注解，如果一个`ChannelHandler`**状态无关**，那么可将其标注为`Sharable`，如此，服务器只需保存一个实例就能处理所有客户端的事件。

## handler源码分析

### 核心类

<img src="http://blog-1259650185.cosbj.myqcloud.com/img/202112/13/1639365212.png" alt="11" style="zoom:67%;" />

上图是`ChannelHandler`的核心类类图，其继承层次清晰，我们逐一分析。

**ChannelHandler**

`ChannaleHandler` 作为最顶层的接口，并不处理入站和出站事件，所以接口中只包含最基本的方法：

```java
// ChannaleHandler.java
// Handler本身被添加到ChannelPipeline时调用
void handlerAdded(ChannelHandlerContext ctx) throws Exception;
// Handler本身被从ChannelPipeline中删除时调用
void handlerRemoved(ChannelHandlerContext ctx) throws Exception;
// 发生异常时调用
void exceptionCaught(ChannelHandlerContext ctx, Throwable cause) throws Exception;
```

其中也定义了`Sharable`标记注解：

```java
@Inherited
@Documented
@Target(ElementType.TYPE)
@Retention(RetentionPolicy.RUNTIME)
@interface Sharable {
    // no value
}
```

作为`ChannelHandler`的默认实现，`ChannelHandlerAdapter`有个重要的方法`isSharable()`，代码如下：

```java
// ChannelHandlerAdapter.java
public boolean isSharable() {
    Class<?> clazz = getClass();
    Map<Class<?>, Boolean> cache = InternalThreadLocalMap.get().handlerSharableCache(); // ThreadLocal来缓存Handler的状态
    Boolean sharable = cache.get(clazz);
    if (sharable == null) {
        sharable = clazz.isAnnotationPresent(Sharable.class); // Handler是否存在Sharable注解
        cache.put(clazz, sharable);
    }
    return sharable;
}
```

每个线程都有一份`ChannelHandler`是否`Sharable`的缓存。这样可以减少线程间的竞争，提升性能。

**ChannelInboundHandler**

ChannelInboundHandler处理入站事件，以及用户自定义事件：

```java
// ChannelInboundHandler.java
// 类似的入站事件
void channeXXX(ChannelHandlerContext ctx) throws Exception;
// 用户自定义事件
void userEventTriggered(ChannelHandlerContext ctx, Object evt) throws Exception;
```

ChannelInboundHandlerAdapter作为ChannelInboundHandler的实现，默认将入站事件自动传播到下一个入站处理器。其中的代码高度一致，如下：

```java
// ChannelInboundHandlerAdapter.java
public void channelRead(ChannelHandlerContext ctx, Object msg) throws Exception {
   ctx.fireChannelRead(msg);
}
```

**ChannelOutboundHandler**

ChannelOutboundHandler处理出站事件：

```java
// ChannelOutboundHandler.java
// 类似的出站事件
void read(ChannelHandlerContext ctx) throws Exception;
```

同理，`ChannelOutboundHandlerAdapter`作为`ChannelOutboundHandler`的事件，默认将出站事件传播到下一个出站处理器：

```java
// ChannelOutboundHandlerAdapter.java
@Override
public void read(ChannelHandlerContext ctx) throws Exception {
  	ctx.read();
}
```

**ChannelDuplexHandler**

ChannelDuplexHandler则同时实现了`ChannelInboundHandler`和`ChannelOutboundHandler`接口。如果一个所需的`ChannelHandler`既要处理入站事件又要处理出站事件，推荐继承此类。

至此，ChannelHandler的核心类已分析完毕，接下来将分析一些Netty自带的Handler。

### LoggingHandler

日志处理器`LoggingHandler`是使用Netty进行开发时的好帮手，它可以对入站\出站事件进行日志记录，从而方便我们进行问题排查。首先看类签名：

```java
@Sharable
public class LoggingHandler extends ChannelDuplexHandler
```

注解`Sharable`说明`LoggingHandler`没有状态相关变量，所有Channel可以使用一个实例。继承自`ChannelDuplexHandler`表示对入站出站事件都进行日志记录。**最佳实践**：使用`static`修饰`LoggingHandler`实例，并在生产环境删除`LoggingHandler`。

该类的成员变量如下：

```java
// LoggingHandler.java
// 实际使用的日志处理，slf4j、log4j等
protected final InternalLogger logger;
// 日志框架使用的日志级别
protected final InternalLogLevel internalLevel;
// Netty使用的日志级别
private final LogLevel level;

// 默认级别为Debug
private static final LogLevel DEFAULT_LEVEL = LogLevel.DEBUG;
```

看完成员变量，然后移目到构造方法，`LoggingHandler`的构造方法较多，一个典型的如下：

```java
// LoggingHandler.java
public LoggingHandler(LogLevel level) {
    if (level == null) {
        throw new NullPointerException("level");
    }
    // 获得实际的日志框架
    logger = InternalLoggerFactory.getInstance(getClass());
    // 设置日志级别
    this.level = level;
    internalLevel = level.toInternalLevel();
}
```

在构造方法中获取用户实际使用的日志框架，如slf4j、log4j等，并日志设置记录级别。其他的构造方法也类似，不在赘述。

记录出站、入站事件的过程类似，我们以`ChannelRead()`为例分析，代码如下：

```java
// LoggingHandler.java
public void channelRead(ChannelHandlerContext ctx, Object msg) throws Exception {
    logMessage(ctx, "RECEIVED", msg);   // 记录日志
    ctx.fireChannelRead(msg);   // 传播事件
}

private void logMessage(ChannelHandlerContext ctx, String eventName, Object msg) {
    if (logger.isEnabled(internalLevel)) {
        logger.log(internalLevel, format(ctx, formatMessage(eventName, msg)));
    }
}

protected String formatMessage(String eventName, Object msg) {
    if (msg instanceof ByteBuf) {
        return formatByteBuf(eventName, (ByteBuf) msg);
    } else if (msg instanceof ByteBufHolder) {
        return formatByteBufHolder(eventName, (ByteBufHolder) msg);
    } else {
        return formatNonByteBuf(eventName, msg);
    }
}
```

其中的代码都简单明了，主要分析`formatByteBuf()`方法：

```java
// LoggingHandler.java
protected String formatByteBuf(String eventName, ByteBuf msg) {
    int length = msg.readableBytes();
    if (length == 0) {
        StringBuilder buf = new StringBuilder(eventName.length() + 4);
        buf.append(eventName).append(": 0B");
        return buf.toString();
    } else {
        int rows = length / 16 + (length % 15 == 0? 0 : 1) + 4;
        StringBuilder buf = new StringBuilder(eventName.length() + 
                    2 + 10 + 1 + 2 + rows * 80);

        buf.append(eventName)
                  .append(": ").append(length).append('B').append(NEWLINE);
        appendPrettyHexDump(buf, msg);

        return buf.toString();
    }
}
```

其中的数字计算，容易让人失去耐心，使用逆向思维，放上结果反推：

![日志打印效果](http://blog-1259650185.cosbj.myqcloud.com/img/202112/13/1639365598.png)



有了这样的结果，请反推实现。需要注意的是其中的`appendPrettyHexDump()`方法，这是在`ByteBufUtil`里的`static`方法，当我们也需要查看多字节数据时，这是一个特别有用的展现方法，记得可在以后的Debug中可加以使用。

### IdleStateHandler

在开发TCP服务时，一个常见的需求便是使用心跳保活客户端。而Netty自带的三个超时处理器`IdleStateHandler`，`ReadTimeoutHandler`和`WriteTimeoutHandler`可完美满足此需求。其中`IdleStateHandler`可处理读超时（客户端长时间没有发送数据给服务端）、写超时（服务端长时间没有发送数据到客户端）和读写超时（客户端与服务端长时间无数据交互）三种情况。这三种情况的枚举为：

```swift
public enum IdleState {
    READER_IDLE,    // 读超时
    WRITER_IDLE,    // 写超时
    ALL_IDLE    // 数据交互超时
}
```

以`IdleStateHandler`的读超时事件为例进行分析，首先看类签名：

```java
public class IdleStateHandler extends ChannelDuplexHandler
```

注意到此Handler没有`Sharable`注解，这是因为每个连接的超时时间是特有的即每个连接有独立的状态，所以不能标注`Sharable`注解。继承自`ChannelDuplexHandler`是因为既要处理读超时又要处理写超时。

该类的一个典型构造方法如下：

```java
// IdleStateHandler.java
public IdleStateHandler(int readerIdleTimeSeconds, int writerIdleTimeSeconds, 
            int allIdleTimeSeconds) {
    this(readerIdleTimeSeconds, writerIdleTimeSeconds,  
            allIdleTimeSeconds, TimeUnit.SECONDS);
}
```

分别设定各个超时事件的时间阈值。以读超时事件为例，有以下相关的字段：

```java
// 用户配置的读超时时间
private final long readerIdleTimeNanos;
// 判定超时的调度任务Future
private ScheduledFuture<?> readerIdleTimeout;
// 最近一次读取数据的时间
private long lastReadTime;
// 是否第一次读超时事件
private boolean firstReaderIdleEvent = true;
// 状态，0 - 无关， 1 - 初始化完成 2 - 已被销毁
private byte state; 
// 是否正在读取
private boolean reading;
```

首先看初始化方法`initialize()`：

```java
// IdleStateHandler.java
private void initialize(ChannelHandlerContext ctx) {
    // Avoid the case where destroy() is called before scheduling timeouts.
    // See: https://github.com/netty/netty/issues/143
    switch (state) {
    case 1: // 初始化进行中或者已完成
    case 2: // 销毁进行中或者已完成
        return;
    default:
         break;
    }

    state = 1;
    initOutputChanged(ctx);

    lastReadTime = lastWriteTime = ticksInNanos();
    if (readerIdleTimeNanos > 0) {
        readerIdleTimeout = schedule(ctx, new ReaderIdleTimeoutTask(ctx),
                readerIdleTimeNanos, TimeUnit.NANOSECONDS);
    }
    if (writerIdleTimeNanos > 0) {
        writerIdleTimeout = schedule(ctx, new WriterIdleTimeoutTask(ctx),
                writerIdleTimeNanos, TimeUnit.NANOSECONDS);
    }
    if (allIdleTimeNanos > 0) {
        allIdleTimeout = schedule(ctx, new AllIdleTimeoutTask(ctx),
                allIdleTimeNanos, TimeUnit.NANOSECONDS);
    }
}
```

初始化的工作较为简单，设定最近一次读取时间`lastReadTime`为当前系统时间，然后在用户设置的读超时时间`readerIdleTimeNanos`截止时，执行一个`ReaderIdleTimeoutTask`进行检测。其中使用的方法很简洁，如下：

```java
// IdleStateHandler.java
long ticksInNanos() {
    return System.nanoTime();
}

ScheduledFuture<?> schedule(ChannelHandlerContext ctx, Runnable task, 
          long delay, TimeUnit unit) {
    return ctx.executor().schedule(task, delay, unit);
}
```

然后，分析销毁方法`destroy()`：

```java
// IdleStateHandler.java
private void destroy() {
    state = 2; // 这里结合initialize对比理解

    if (readerIdleTimeout != null) {
        readerIdleTimeout.cancel(false);  // 取消调度任务，并置null
        readerIdleTimeout = null;
    }
    if (writerIdleTimeout != null) {
        writerIdleTimeout.cancel(false);
        writerIdleTimeout = null;
    }
    if (allIdleTimeout != null) {
        allIdleTimeout.cancel(false);
        allIdleTimeout = null;
    }
}
```

可知销毁的处理也很简单，分析完初始化和销毁，再看这两个方法被调用的地方，`initialize()`在三个方法中被调用：

```java
// IdleStateHandler.java
@Override
public void handlerAdded(ChannelHandlerContext ctx) throws Exception {
    if (ctx.channel().isActive() && ctx.channel().isRegistered()) {
        initialize(ctx);
    } else {
    }
}

@Override
public void channelRegistered(ChannelHandlerContext ctx) throws Exception {
    // Initialize early if channel is active already.
    if (ctx.channel().isActive()) {
        initialize(ctx);
    }
    super.channelRegistered(ctx);
}

@Override
public void channelActive(ChannelHandlerContext ctx) throws Exception {
    initialize(ctx);
    super.channelActive(ctx);
}
```

当客户端与服务端成功建立连接后，Channel被激活，此时`channelActive`的初始化被调用；如果Channel被激活后，动态添加此Handler，则`handlerAdded`的初始化被调用；如果Channel被激活，用户主动切换Channel的执行线程Executor，则`channelRegistered`的初始化被调用。这一部分较难理解，请仔细体会。

`destroy()`则有两处调用：

```java
// IdleStateHandler.java
@Override
public void channelInactive(ChannelHandlerContext ctx) throws Exception {
    destroy();
    super.channelInactive(ctx);
}

@Override
public void handlerRemoved(ChannelHandlerContext ctx) throws Exception {
    destroy();
}
```

即该Handler被动态删除时，`handlerRemoved`的销毁被执行；Channel失效时，`channelInactive`的销毁被执行。

分析完这些，在分析核心的调度任务`ReaderIdleTimeoutTask`：

```java
// ReaderIdleTimeoutTask.java
private final class ReaderIdleTimeoutTask extends AbstractIdleTask {

    ReaderIdleTimeoutTask(ChannelHandlerContext ctx) {
        super(ctx);
    }

    @Override
    protected void run(ChannelHandlerContext ctx) {
        long nextDelay = readerIdleTimeNanos;
        if (!reading) {
            // 计算是否idle的关键，nextDelay<=0 说明在设置的超时时间内没有读取数据
            nextDelay -= ticksInNanos() - lastReadTime;
        }
        // 隐含正在读取时，nextDelay = readerIdleTimeNanos > 0
        if (nextDelay <= 0) {
            // 空闲了，超时时间已到，则再次调度该任务本身
            // Reader is idle - set a new timeout and notify the callback.
            readerIdleTimeout = schedule(ctx, this, readerIdleTimeNanos, TimeUnit.NANOSECONDS);

            boolean first = firstReaderIdleEvent;
            // firstReaderIdleEvent在下个读来之前，第一次idle之后，可能触发多次
            firstReaderIdleEvent = false;

            try {
                IdleStateEvent event = newIdleStateEvent(IdleState.READER_IDLE, first);
                channelIdle(ctx, event); // 模板方法处理
            } catch (Throwable t) {
                ctx.fireExceptionCaught(t);
            }
        } else {
            // 重新起一个监测task，用nextDelay时间，注意此处的nextDelay值，会跟随lastReadTime刷新
            // Read occurred before the timeout - set a new timeout with shorter delay.
            readerIdleTimeout = schedule(ctx, this, nextDelay, TimeUnit.NANOSECONDS);
        }
    }
}
```

这个读超时检测任务执行的过程中又递归调用了它本身进行下一次调度，请仔细品味该种使用方法。再列出`channelIdle()`的代码：

```java
// ReaderIdleTimeoutTask.java
protected void channelIdle(ChannelHandlerContext ctx, IdleStateEvent evt) throws Exception {
    ctx.fireUserEventTriggered(evt);
}
```

本例中，该方法将写超时事件作为用户事件传播到下一个Handler，用户需要在某个Handler中拦截该事件进行处理。该方法标记为`protect`说明子类通常可覆盖，`ReadTimeoutHandler`子类即定义了自己的处理：

```java
// ReadTimeoutHandler.java
@Override
protected final void channelIdle(ChannelHandlerContext ctx, IdleStateEvent evt) throws Exception {
    assert evt.state() == IdleState.READER_IDLE;
    readTimedOut(ctx);
}

protected void readTimedOut(ChannelHandlerContext ctx) throws Exception {
    if (!closed) {
        // 发生 timeout 的时候，直接抛一个异常
        ctx.fireExceptionCaught(ReadTimeoutException.INSTANCE);
        ctx.close();
        closed = true;
    }
}
```

可知在`ReadTimeoutHandler`中，如果发生读超时事件，将会关闭该Channel。当进行心跳处理时，使用`IdleStateHandler`较为麻烦，一个简便的方法是：直接继承`ReadTimeoutHandler`然后覆盖`readTimedOut()`进行用户所需的超时处理。

## 为什么要粘包拆包

### 为什么要粘包

首先你得了解一下TCP/IP协议，在用户数据量非常小的情况下，极端情况下，一个字节，该TCP数据包的有效载荷非常低，传递100字节的数据，需要100次TCP传送，100次ACK，在应用及时性要求不高的情况下，将这100个有效数据拼接成一个数据包，那会缩短到一个TCP数据包，以及一个ack，有效载荷提高了，带宽也节省了。

非极端情况，有可能两个数据包拼接成一个数据包，也有可能一个半的数据包拼接成一个数据包，也有可能两个半的数据包拼接成一个数据包。

### 为什么要拆包

拆包和粘包是相对的，一端粘了包，另外一端就需要将粘过的包拆开，举个栗子，发送端将三个数据包粘成两个TCP数据包发送到接收端，接收端就需要根据应用协议将两个TCP数据包重新组装成三个数据包。

还有一种情况就是用户数据包超过了mss(最大报文长度)，那么这个数据包在发送的时候必须拆分成几个数据包，接收端收到之后需要将这些数据包粘合起来之后，再拆开。

## 拆包的原理

在没有netty的情况下，用户如果自己需要拆包，基本原理就是不断从TCP缓冲区中读取数据，每次读取完都需要判断是否是一个完整的数据包。

1. 如果当前读取的数据不足以拼接成一个完整的业务数据包，那就保留该数据，继续从TCP缓冲区中读取，直到得到一个完整的数据包。
2. 如果当前读到的数据加上已经读取的数据足够拼接成一个数据包，那就将已经读取的数据拼接上本次读取的数据，够成一个完整的业务数据包传递到业务逻辑，多余的数据仍然保留，以便和下次读到的数据尝试拼接。

## netty中拆包的基类

netty 中的拆包也是如上这个原理，内部会有一个累加器，每次读取到数据都会不断累加，然后尝试对累加到的数据进行拆包，拆成一个完整的业务数据包，这个基类叫做 `ByteToMessageDecoder`。需要说明一点：`ByteToMessage`容易引起误解，解码结果Message会被认为是JAVA对象POJO，但实际解码结果是**消息帧**。也就是说该解码器处理TCP的粘包现象，将网络发送的字节流解码为具有确定含义的消息帧，之后的解码器再将消息帧解码为实际的POJO对象。下面我们先详细分析下这个类。

### 累加器

`ByteToMessageDecoder` 中定义了两个累加器，可自动扩容累积字节数据。

先来看一下接口定义：

```java
public interface Cumulator {
 	 ByteBuf cumulate(ByteBufAllocator alloc, ByteBuf cumulation, ByteBuf in);
}
```

其中，两个ByteBuf参数`cumulation`指已经累积的字节数据，`in`表示该次`channelRead()`读取到的新数据。返回ByteBuf为累积数据后的新累积区（必要时候自动扩容）。

下面看一下是如何使用的。

```java
// ByteToMessageDecoder.java
public static final Cumulator MERGE_CUMULATOR = ...;
public static final Cumulator COMPOSITE_CUMULATOR = ...;
```

默认情况下，会使用 `MERGE_CUMULATOR`。

```java
// ByteToMessageDecoder.java
private Cumulator cumulator = MERGE_CUMULATOR;
```

`MERGE_CUMULATOR`的原理是每次都将读取到的数据通过内存拷贝的方式，拼接到一个大的字节容器中，这个字节容器在 	`ByteToMessageDecoder`中叫做 `cumulation`。

```java
ByteBuf cumulation;
```

下面我们看一下 `MERGE_CUMULATOR` 是如何将新读取到的数据累加到字节容器里的。

```java
// ByteToMessageDecoder.java
public static final Cumulator MERGE_CUMULATOR = new Cumulator() {
    @Override
    public ByteBuf cumulate(ByteBufAllocator alloc, ByteBuf cumulation, ByteBuf in) {
        if (!cumulation.isReadable() && in.isContiguous()) {
            cumulation.release();
            return in;
        }
        try {
            final int required = in.readableBytes();
            if (required > cumulation.maxWritableBytes() ||
                    (required > cumulation.maxFastWritableBytes() && cumulation.refCnt() > 1) ||
                    cumulation.isReadOnly()) {
                // 如果不够空间，就去扩容。先把空间搞够
                return expandCumulation(alloc, cumulation, in);
            }
            // 然后把空间追加进去就行了
            cumulation.writeBytes(in, in.readerIndex(), required);
            in.readerIndex(in.writerIndex());
            return cumulation;
        } finally {
            in.release();
        }
    }
};
```

netty 中ByteBuf的抽象，使得累加非常简单，通过一个简单的api调用 `buffer.writeBytes(in);` 便将新数据累加到字节容器中，为了防止字节容器大小不够，在累加之前还进行了扩容处理。

可知，三种情况下会扩容：

1. 累积区容量不够容纳新读入的数据
2. 用户使用了`slice().retain()`或`duplicate().retain()`使refCnt增加并且大于1，此时扩容返回一个新的累积区ByteBuf，方便用户对老的累积区ByteBuf进行后续处理。
3. 累积区是可写不是可读的。

```java
// ByteToMessageDecoder.java
static ByteBuf expandCumulation(ByteBufAllocator alloc, ByteBuf oldCumulation, ByteBuf in) {
    int oldBytes = oldCumulation.readableBytes();
    int newBytes = in.readableBytes();
    int totalBytes = oldBytes + newBytes;
    ByteBuf newCumulation = alloc.buffer(alloc.calculateNewCapacity(totalBytes, MAX_VALUE));
    ByteBuf toRelease = newCumulation;
    try {
        // This avoids redundant checks and stack depth compared to calling writeBytes(...)
        newCumulation.setBytes(0, oldCumulation, oldCumulation.readerIndex(), oldBytes)
            .setBytes(oldBytes, in, in.readerIndex(), newBytes)
            .writerIndex(totalBytes);
        in.readerIndex(in.writerIndex());
        toRelease = oldCumulation;
        return newCumulation;
    } finally {
        toRelease.release();
    }
}
```

扩容也是一个内存拷贝操作，新增的大小即是新读取数据的大小。

另一个累积器为`COMPOSITE_CUMULATOR`：

```java
// ByteToMessageDecoder.java
/**
 * 把 ByteBuf 组合起来，避免了内存复制。组合模式，提供逻辑视图
 */
public static final Cumulator COMPOSITE_CUMULATOR = new Cumulator() {
    @Override
    public ByteBuf cumulate(ByteBufAllocator alloc, ByteBuf cumulation, ByteBuf in) {
        if (!cumulation.isReadable()) {
            cumulation.release();
            return in;
        }
        CompositeByteBuf composite = null;
        try {
            if (cumulation instanceof CompositeByteBuf && cumulation.refCnt() == 1) {
                composite = (CompositeByteBuf) cumulation;

                if (composite.writerIndex() != composite.capacity()) {
                    composite.capacity(composite.writerIndex());
                }
            } else {
                composite = alloc.compositeBuffer(Integer.MAX_VALUE).addFlattenedComponents(true, cumulation);
            }
            // 避免内存复制
            composite.addFlattenedComponents(true, in);
            in = null;
            return composite;
        } finally {
            if (in != null) {
                // We must release if the ownership was not transferred as otherwise it may produce a leak
                in.release();
                // Also release any new buffer allocated if we're not returning it
                if (composite != null && composite != cumulation) {
                    composite.release();
                }
            }
        }
    }
};
```

这个累积器只在第二种情况refCnt>1时扩容，除此之外处理和`MERGE_CUMULATOR`一致，不同的是当cumulation不是`CompositeByteBuf`时会创建新的同类`CompositeByteBuf`，这样最后返回的ByteBuf必定是`CompositeByteBuf`。使用这个累积器后，当容量不够时并不会进行内存复制，只会讲新读入的`in`加到`CompositeByteBuf`中。需要注意的是：此种情况下虽然不需内存复制，却要求用户维护复杂的索引，在某些使用中可能慢于`MERGE_CUMULATOR`。故Netty默认使用`MERGE_CUMULATOR`累积器。

累积器分析完毕，步入正题`ByteToMessageDecoder`，首先看类签名：

```java
public abstract class ByteToMessageDecoder extends ChannelInboundHandlerAdapter
```

该类是一个抽象类，其中的抽象方法只有一个`decode()`：

```csharp
protected abstract void decode(ChannelHandlerContext ctx, ByteBuf in, List<Object> out) throws Exception;
```

用户使用了该解码框架后，只需实现该方法就可定义自己的解码器。参数`in`表示累积器已累积的数据，`out`表示本次可从累积数据解码出的结果列表，结果可为POJO对象或者ByteBuf等等Object。

关注一下成员变量，以便更好的分析：

```java
// ByteToMessageDecoder.java
ByteBuf cumulation; // 累积区
private Cumulator cumulator = MERGE_CUMULATOR; // 累积器
// 设置为true后每个channelRead事件只解码出一个结果
private boolean singleDecode;   // 某些特殊协议使用
private boolean first;  // 是否首个消息
// 累积区不丢弃字节的最大次数，16次后开始丢弃
private int discardAfterReads = 16;
private int numReads;   // 累积区不丢弃字节的channelRead次数
```

## 拆包抽象

下面我们回到主流程，目光集中在`ByteToMessageDecoder`的 `channelRead` 方法，`channelRead`方法是每次从TCP缓冲区读到数据都会调用的方法，触发点在`AbstractNioByteChannel`的`read`方法中，里面有个`while`循环不断读取，读取到一次就触发一次`channelRead`。

```java
// ByteToMessageDecoder.java
@Override
public void channelRead(ChannelHandlerContext ctx, Object msg) throws Exception {
    if (msg instanceof ByteBuf) { // 只对ByteBuf处理即只对字节数据进行处理
        CodecOutputList out = CodecOutputList.newInstance();  // 解码结果列表
        try {
          	// 1.累加数据
            first = cumulation == null; // 累积区为空表示首次解码
            cumulation = cumulator.cumulate(ctx.alloc(),
                    // 是第一次读时，返回空的buffer，否则放到积累器中
                    first ? Unpooled.EMPTY_BUFFER : cumulation, (ByteBuf) msg);
            // 2.尝试将字节容器cumulation的数据拆分成业务数据包，塞到业务数据容器out中
            callDecode(ctx, cumulation, out);
        } catch (DecoderException e) {
            throw e;
        } catch (Exception e) {
            throw new DecoderException(e);
        } finally {
            try {
              	// 3.清理字节容器
                if (cumulation != null && !cumulation.isReadable()) {
                    numReads = 0; // 标注一下当前字节容器一次数据也没读取
                    cumulation.release(); // 如果字节容器当前已无数据可读取，直接销毁字节容器
                    cumulation = null;
                } else if (++numReads >= discardAfterReads) { // 如果连续16次（discardAfterReads的默认值），字节容器中仍然有未被业务拆包器读取的数据
                    numReads = 0;
                  	 // 做一次压缩，有效数据段整体移到容器首部
                    discardSomeReadBytes();
                }
								// 4.传递业务数据包给业务解码器处理
                int size = out.size();
                firedChannelRead |= out.insertSinceRecycled(); // firedChannelRead标识本次读取数据是否拆到一个业务数据包
                fireChannelRead(ctx, out, size); // 将拆到的业务数据包都传递到后续的业务handler
            } finally {
                out.recycle();
            }
        }
    } else {
        ctx.fireChannelRead(msg);
    }
}
```

解码结果列表`CodecOutputList`是Netty定制的一个特殊列表，该列表在线程中被缓存，可循环使用来存储解码结果，减少不必要的列表实例创建，从而提升性能。由于解码结果需要频繁存储，普通的ArrayList难以满足该需求，故定制化了一个特殊列表，由此可见Netty对优化的极致追求。

方法体不长不短，可以分为以下几个逻辑步骤：

1. 累加数据。
2. 将累加到的数据传递给业务进行业务拆包。
3. 清理字节容器。
4. 传递业务数据包给业务解码器处理。

### 1. 累加数据

如果当前累加器没有数据，就直接跳过内存拷贝，直接将字节容器的指针指向新读取的数据，否则，调用累加器累加数据至字节容器。

```java
// ByteToMessageDecoder.java
first = cumulation == null;
cumulation = cumulator.cumulate(ctx.alloc(),
        // 是第一次读时，返回空的buffer，否则放到积累器中
        first ? Unpooled.EMPTY_BUFFER : cumulation, (ByteBuf) msg);
```

### 2. 将累加到的数据传递给业务进行拆包

到这一步，字节容器里的数据已是目前未拆包部分的所有的数据了。

```java
// ByteToMessageDecoder.java
CodecOutputList out = CodecOutputList.newInstance();
...
callDecode(ctx, cumulation, out);
```

`callDecode` 将尝试将字节容器的数据拆分成业务数据包塞到业务数据容器`out`中。

```java
// ByteToMessageDecoder.java
protected void callDecode(ChannelHandlerContext ctx, ByteBuf in, List<Object> out) {
    try {
        while (in.isReadable()) {
            final int outSize = out.size();

            if (outSize > 0) {
                fireChannelRead(ctx, out, outSize);
                out.clear();

                if (ctx.isRemoved()) { // 用户主动删除该Handler，继续操作in是不安全的
                    break;
                }
            }
            // 记录一下字节容器中有多少字节待拆
            int oldInputLength = in.readableBytes();
            // decode 中时，不能执行完handler remove 清理操作。
            // 那 decode 完之后，需要清理数据
            decodeRemovalReentryProtection(ctx, in, out);

            if (ctx.isRemoved()) {
                break;
            }

            if (out.isEmpty()) {
                if (oldInputLength == in.readableBytes()) { // 拆包器未读取任何数据，可能数据还不够业务拆包器处理，直接break等待新的数据
                    break;
                } else {
                    continue; // 拆包器已读取部分数据，说明解码器仍然在工作，还需要继续解码
                }
            }
            // 什么数据都没读取，却解析出一个业务数据包（前文的out.isEmpty() == false），这是有问题的
            if (oldInputLength == in.readableBytes()) {
                throw new DecoderException(
                        StringUtil.simpleClassName(getClass()) +
                                ".decode() did not read anything but decoded a message.");
            }

            if (isSingleDecode()) {
                break;
            }
        }
    } catch (DecoderException e) {
        throw e;
    } catch (Exception cause) {
        throw new DecoderException(cause);
    }
}

final void decodeRemovalReentryProtection(ChannelHandlerContext ctx, ByteBuf in, List<Object> out)
        throws Exception {
    decodeState = STATE_CALLING_CHILD_DECODE;
    try {
        decode(ctx, in, out); // 模版方法模式
    } finally {
        boolean removePending = decodeState == STATE_HANDLER_REMOVED_PENDING;
        decodeState = STATE_INIT;
        if (removePending) {
            fireChannelRead(ctx, out, out.size());
            out.clear();
            handlerRemoved(ctx);
        }
    }
}
```

在解码之前，先记录一下字节容器中有多少字节待拆，然后通过调用`decodeRemovalReentryProtection`方法，调用模版抽象方法 `decode` 进行拆包。

```java
// ByteToMessageDecoder.java
protected abstract void decode(ChannelHandlerContext ctx, ByteBuf in, List<Object> out) throws Exception;
```

netty中对各种用户协议的支持就体现在这个抽象函数中，传进去的是当前读取到的未被消费的所有的数据，以及业务协议包容器，所有的拆包器最终都实现了该抽象方法。

业务拆包完成之后，如果发现并没有拆到一个完整的数据包，这个时候又分两种情况：

1. 一个是拆包器什么数据也没读取，可能数据还不够业务拆包器处理，直接break等待新的数据。
2. 拆包器已读取部分数据，说明解码器仍然在工作，继续解码。

业务拆包完成之后，如果发现已经解到了数据包，但是，发现并没有读取任何数据，这个时候就会抛出一个Runtime异常 `DecoderException`，告诉你，你什么数据都没读取，却解析出一个业务数据包，这是有问题的。

### 3. 清理字节容器

业务拆包完成之后，只是从字节容器中取走了数据，但是这部分空间对于字节容器来说依然保留着，而字节容器每次累加字节数据的时候都是将字节数据追加到尾部，如果不对字节容器做清理，那么时间一长就会OOM。

正常情况下，其实每次读取完数据，netty都会在下面这个方法中将字节容器清理，只不过，当发送端发送数据过快，`channelReadComplete`可能会很久才被调用一次。

```java
// ByteToMessageDecoder.java
@Override
public void channelReadComplete(ChannelHandlerContext ctx) throws Exception {
    numReads = 0;
    discardSomeReadBytes(); // 清理容器，但是如果发送端发送数据过快，当前方法可能会很久才被调用一次
    if (!firedChannelRead && !ctx.channel().config().isAutoRead()) {
        ctx.read();
    }
    firedChannelRead = false;
    ctx.fireChannelReadComplete();
}
```

这里顺带插一句，如果一次数据读取完毕之后(可能接收端一边收，发送端一边发，这里的读取完毕指的是接收端在某个时间不再接受到数据为止），发现仍然没有拆到一个完整的用户数据包，即使该channel的设置为非自动读取，也会触发一次读取操作 `ctx.read()`，该操作会重新向selector注册op_read事件，以便于下一次能读到数据之后拼接成一个完整的数据包。

所以为了防止发送端发送数据过快，netty会在每次读取到一次数据，业务拆包之后对字节字节容器做清理，清理部分的代码如下：

```java
// ByteToMessageDecoder.java
if (cumulation != null && !cumulation.isReadable()) {
    numReads = 0;
    cumulation.release();
    cumulation = null;
} else if (++ numReads >= discardAfterReads) {
    numReads = 0;
    discardSomeReadBytes();
}
```

第一种情况，如果字节容器当前已无数据可读取，直接销毁字节容器，并且标注一下当前字节容器一次数据也没读取。想象这样的情况，当一条消息被解码完毕后，如果客户端长时间不发送消息，那么，服务端保存该条消息的累积区将一直占据服务端内存浪费资源，所以必须释放该累积区。

第二种情况，如果连续16次（`discardAfterReads`的默认值），字节容器中仍然有未被业务拆包器读取的数据，那就做一次压缩，有效数据段整体移到容器首部。

```java
// ByteToMessageDecoder.java
// 做一次压缩，有效数据段整体移到容器首部，就是把ByteBuf里首部的readed移除，后面的unreaded和writable部分移动到首部
protected final void discardSomeReadBytes() {
    if (cumulation != null && !first && cumulation.refCnt() == 1) {
        cumulation.discardSomeReadBytes();
    }
}
```

需要注意的是，累积区的`refCnt() == 1`时才丢弃数据是因为：如果用户使用了`slice().retain()`和`duplicate().retain()`使`refCnt>1`，表明该累积区还在被用户使用，丢弃数据可能导致用户的困惑，所以须确定用户不再使用该累积区的已读数据，此时才丢弃。

discardSomeReadBytes之前，字节累加器中的数据分布：

```java
+--------------+----------+----------+
|   readed     | unreaded | writable | 
+--------------+----------+----------+
```

discardSomeReadBytes之后，字节容器中的数据分布：

```java
+----------+-------------------------+
| unreaded |      writable           | 
+----------+-------------------------+
```

这样字节容器又可以承载更多的数据了。

### 4. 传递业务数据包给业务解码器处理

以上三个步骤完成之后，就可以将拆成的包丢到业务解码器处理了，代码如下：

```java
// ByteToMessageDecoder.java
int size = out.size();
decodeWasNull = !out.insertSinceRecycled();
fireChannelRead(ctx, out, size);
out.recycle();
```

期间用一个成员变量 `firedChannelRead` 来标识本次读取数据是否拆到一个业务数据包，然后调用 `fireChannelRead` 将拆到的业务数据包都传递到后续的handler。

```java
// ByteToMessageDecoder.java
static void fireChannelRead(ChannelHandlerContext ctx, CodecOutputList msgs, int numElements) {
    for (int i = 0; i < numElements; i ++) { // 遍历列表，逐个将msg传递到后续的业务解码器
        ctx.fireChannelRead(msgs.getUnsafe(i));
    }
}
```

这样，就可以把一个个完整的业务数据包传递到后续的业务解码器进行解码，随后处理业务逻辑。

## 行拆包器

下面，以一个具体的例子来看一下netty自带的拆包器是如何来拆包的。

这个类叫做 `LineBasedFrameDecoder`，基于行分隔符的拆包器，它可以同时处理 `\n`以及`\r\n`两种类型的行分隔符，核心方法都在继承的 `decode` 方法中。

首先看该类定义的成员变量：

```java
// 最大帧长度，超过此长度将抛出异常TooLongFrameException
private final int maxLength;
// 是否快速失败，true-检测到帧长度过长立即抛出异常不在读取整个帧
// false-检测到帧长度过长依然读完整个帧再抛出异常
private final boolean failFast;
// 是否略过分隔符，true-解码结果不含分隔符
private final boolean stripDelimiter;

// 超过最大帧长度是否丢弃字节
private boolean discarding;
private int discardedBytes; // 丢弃的字节数
```

下面看一下核心的 `decode` 方法。

```java
// LineBasedFrameDecoder.java
protected final void decode(ChannelHandlerContext ctx, ByteBuf in, List<Object> out) throws Exception {
    Object decoded = decode(ctx, in);
    if (decoded != null) {
        out.add(decoded);
    }
}

protected Object decode(ChannelHandlerContext ctx, ByteBuf buffer) throws Exception {
    final int eol = findEndOfLine(buffer);
    if (!discarding) {
        if (eol >= 0) {
            final ByteBuf frame;
            final int length = eol - buffer.readerIndex();
            final int delimLength = buffer.getByte(eol) == '\r'? 2 : 1;

            if (length > maxLength) {
                buffer.readerIndex(eol + delimLength);
                fail(ctx, length);
                return null;
            }

            if (stripDelimiter) {
                frame = buffer.readRetainedSlice(length);
                buffer.skipBytes(delimLength);
            } else {
                frame = buffer.readRetainedSlice(length + delimLength);
            }

            return frame;
        } else {
            final int length = buffer.readableBytes();
            if (length > maxLength) {
                discardedBytes = length;
                buffer.readerIndex(buffer.writerIndex());
                discarding = true;
                offset = 0;
                if (failFast) {
                    fail(ctx, "over " + discardedBytes);
                }
            }
            return null;
        }
    } else {
        if (eol >= 0) {
            final int length = discardedBytes + eol - buffer.readerIndex();
            final int delimLength = buffer.getByte(eol) == '\r'? 2 : 1;
            buffer.readerIndex(eol + delimLength);
            discardedBytes = 0;
            discarding = false;
            if (!failFast) {
                fail(ctx, length);
            }
        } else {
            discardedBytes += buffer.readableBytes();
            buffer.readerIndex(buffer.writerIndex());
            // We skip everything in the buffer, we need to set the offset to 0 again.
            offset = 0;
        }
        return null;
    }
}
```

netty 中自带的拆包器都是如上这种模板，我们接着跟进去，代码比较长，我们还是分模块来剖析。

### 1. 找到换行符位置

```java
// LineBasedFrameDecoder.java
ByteProcessor FIND_LF = new IndexOfProcessor((byte) '\n');

final int eol = findEndOfLine(buffer);

// for循环遍历，找到第一个\n的位置,如果\n前面的字符为\r，那就返回\r的位置
private int findEndOfLine(final ByteBuf buffer) {
    int totalLength = buffer.readableBytes();
    int i = buffer.forEachByte(buffer.readerIndex() + offset, totalLength - offset, ByteProcessor.FIND_LF);
    if (i >= 0) {
        offset = 0;
        if (i > 0 && buffer.getByte(i - 1) == '\r') {
            i--;
        }
    } else {
        offset = totalLength;
    }
    return i;
}
```

for循环遍历，找到第一个 `\n` 的位置,如果`\n`前面的字符为`\r`，那就返回`\r`的位置。

### 2. 非discarding模式的处理

接下来，netty会判断，当前拆包是否属于丢弃模式，用一个成员变量来标识。

第一次拆包不在discarding模式（ 后面的分支会讲何为非discarding模式），于是进入以下环节：

#### 2.1 非discarding模式下找到行分隔符的处理

```java
// LineBasedFrameDecoder.java
// 1.计算分隔符和包长度
final ByteBuf frame;
final int length = eol - buffer.readerIndex(); // 当前包的长度
final int delimLength = buffer.getByte(eol) == '\r'? 2 : 1; // 分隔符是 \r\n 的话，delimLength=2，否则=1

// 2.丢弃异常数据
if (length > maxLength) {
    buffer.readerIndex(eol + delimLength);
    fail(ctx, length);
    return null;
}

// 3.取包的时候是否包括分隔符
if (stripDelimiter) {
    frame = buffer.readRetainedSlice(length);
    buffer.skipBytes(delimLength);
} else {
    frame = buffer.readRetainedSlice(length + delimLength);
}
return frame;
```

1. 首先，新建一个帧，计算一下当前包的长度和分隔符的长度（因为有两种分隔符）。
2. 然后判断一下需要拆包的长度是否大于该拆包器允许的最大长度(`maxLength`)，这个参数在构造函数中被传递进来，如超出允许的最大长度，就将这段数据抛弃，返回null。
3. 最后，将一个完整的数据包取出，如果构造本解包器的时候指定 `stripDelimiter`为false，即解析出来的包包含分隔符，默认为不包含分隔符。

#### 2.2 非discarding模式下未找到分隔符的处理

没有找到对应的行分隔符，说明字节容器没有足够的数据拼接成一个完整的业务数据包，进入如下流程处理：

```java
// LineBasedFrameDecoder.java
final int length = buffer.readableBytes();
if (length > maxLength) {
    discardedBytes = length;
    buffer.readerIndex(buffer.writerIndex());
    discarding = true;
    if (failFast) {
        fail(ctx, "over " + discardedBytes);
    }
}
return null;
```

首先取得当前字节容器的可读字节个数，接着，判断一下是否已经超过可允许的最大长度，如果没有超过，直接返回null，字节容器中的数据没有任何改变，否则，就需要进入丢弃模式。

使用一个成员变量 `discardedBytes` 来表示已经丢弃了多少数据，然后将字节容器的读指针移到写指针，意味着丢弃这一部分数据，设置成员变量`discarding`为true表示当前处于丢弃模式。如果设置了`failFast`，那么直接抛出异常，默认情况下`failFast`为false，即安静得丢弃数据。

### 3. discarding模式

如果解包的时候处在discarding模式，也会有两种情况发生。

#### 3.1 discarding模式下找到行分隔符

在discarding模式下，如果找到分隔符，那可以将分隔符之前的都丢弃掉。

```java
// LineBasedFrameDecoder.java
final int length = discardedBytes + eol - buffer.readerIndex();
final int delimLength = buffer.getByte(eol) == '\r'? 2 : 1;
buffer.readerIndex(eol + delimLength);
discardedBytes = 0;
discarding = false;
if (!failFast) {
    fail(ctx, length);
}
```

计算出分隔符的长度之后，直接把分隔符之前的数据全部丢弃，当然丢弃的字符也包括分隔符，经过这么一次丢弃，后面就有可能是正常的数据包，下一次解包的时候就会进入正常的解包流程。

#### 3.2 discarding模式下未找到行分隔符

```java
// LineBasedFrameDecoder.java
discardedBytes += buffer.readableBytes();
buffer.readerIndex(buffer.writerIndex());
offset = 0;
```

这种情况比较简单，因为当前还在丢弃模式，没有找到行分隔符意味着当前一个完整的数据包还没丢弃完，当前读取的数据是要被丢弃的一部分，所以直接丢弃。

## 特定分隔符拆包器

这个类叫做 `DelimiterBasedFrameDecoder`，可支持多个分隔符，每个分隔符可为一个或多个字符。如果定义了多个分隔符，并且可解码出多个消息帧，则选择产生最小帧长的结果。例如，使用行分隔符`\r\n`和`\n`分隔：

```shell
+--------------+
| ABC\nDEF\r\n |
+--------------+
```

可有两种结果：

```shell
+-----+-----+              +----------+   
| ABC | DEF |  (√)   和    | ABC\nDEF |  (×)
+-----+-----+              +----------+
```

该编码器可配置的变量与`LineBasedFrameDecoder`类似，只是多了一个`ByteBuf[] delimiters`用于配置具体的分隔符。

Netty在`Delimiters`类中定义了两种默认的分隔符，分别是NULL分隔符和行分隔符：

```java
// DelimiterBasedFrameDecoder.java
public static ByteBuf[] nulDelimiter() {
    return new ByteBuf[] {
            Unpooled.wrappedBuffer(new byte[] { 0 }) };
}

public static ByteBuf[] lineDelimiter() {
    return new ByteBuf[] {
            Unpooled.wrappedBuffer(new byte[] { '\r', '\n' }),
            Unpooled.wrappedBuffer(new byte[] { '\n' }),
    };
}
```

## 固定长度拆包器

该解码器十分简单，按照固定长度`frameLength`解码出消息帧。如下的数据帧解码为固定长度3的消息帧示例如下：

```ruby
+---+----+------+----+      +-----+-----+-----+
| A | BC | DEFG | HI |  ->  | ABC | DEF | GHI |
+---+----+------+----+      +-----+-----+-----+
```

其中的解码方法也十分简单：

```java
protected Object decode(ChannelHandlerContext ctx, ByteBuf in) throws Exception {
    if (in.readableBytes() < frameLength) {
        return null;
    } else {
        return in.readSlice(frameLength).retain();
    }
}
```

## 通用拆包器

下面讲一下通用拆包器`LengthFieldBasedFrameDecoder`，如果你还在自己实现人肉拆包，不妨了解一下这个强大的拆包器，因为几乎所有和长度相关的二进制协议都可以通过TA来实现，下面我们先看看他有哪些用法。

### LengthFieldBasedFrameDecoder 的用法

首先，看一下成员变量。

```java
private final ByteOrder byteOrder;
private final int maxFrameLength;
private final boolean failFast;
private final int lengthFieldOffset;
private final int lengthFieldLength;
private final int lengthAdjustment;
private final int initialBytesToStrip;
```

变量`byteOrder`表示长度字段的字节序：大端或小端，默认为大端。如果对字节序有疑问，请查阅其他资料，不再赘述。`maxFrameLength`和`failFast`与其他解码器相同，控制最大帧长度和快速失败抛异常，注意：该解码器`failFast`默认为true。

接下来将重点介绍其它四个变量：

1. `lengthFieldOffset`表示长度字段偏移量即在一个数据包中长度字段的具体下标位置。标准情况，该长度字段为数据部分长度。
2. `lengthFieldLength`表示长度字段的具体字节数，如一个int占4字节。该解码器支持的字节数有：1，2，3，4和8，其他则会抛出异常。另外，还需要注意的是：长度字段的结果为**无符号数**。
3. `lengthAdjustment`是一个长度调节量，当数据包的长度字段不是数据部分长度而是总长度时，可将此值设定为头部长度，便能正确解码出包含整个数据包的结果消息帧。注意：某些情况下，该值可设定为负数。
4. `initialBytesToStrip`表示需要略过的字节数，如果我们只关心数据部分而不关心头部，可将此值设定为头部长度从而丢弃头部。

下面我们使用具体的例子来说明：

#### 1. 基于长度的拆包

<img src="http://blog-1259650185.cosbj.myqcloud.com/img/202112/03/1638545919.jpg" alt="长度的拆包" style="zoom:67%;" />

上面这类数据包协议比较常见的，前面几个字节表示数据包的长度（不包括长度域），后面是具体的数据。拆完之后数据包是一个完整的**带有长度域的数据包**（之后即可传递到应用层解码器进行解码），创建一个如下方式的`LengthFieldBasedFrameDecoder`即可实现这类协议。

```java
new LengthFieldBasedFrameDecoder(Integer.MAX, 0, 4);
```

其中：

1. 第一个参数是 `maxFrameLength` 表示的是发送的数据包的最大长度，超出包的最大长度netty将会做一些特殊处理。
2. 第二个参数是`lengthFieldOffset`，表示的是长度域的偏移量，也就是长度域位于发送的字节数组中的下标。换句话说：发送的字节数组中下标为${lengthFieldOffset}的地方是长度域的开始地方，在这里是0，表示无偏移。
3. 第三个参数是`lengthFieldLength`，表示的是长度域长度，换句话说：发送字节数组bytes时, 字节数组bytes[lengthFieldOffset, lengthFieldOffset+lengthFieldLength]域对应于的定义长度域部分，这里是4，表示长度域的长度为4。

#### 2. 基于长度的截断拆包

如果我们的应用层解码器不需要使用到长度字段，那么我们希望netty拆完包之后，是这个样子：

<img src="http://blog-1259650185.cosbj.myqcloud.com/img/202112/03/1638546245.jpg" alt="长度的截断拆包" style="zoom:67%;" />

长度域被截掉，我们只需要指定另外一个参数就可以实现，这个参数叫做 `initialBytesToStrip`，表示netty拿到一个完整的数据包之后向业务解码器传递之前，应该跳过多少字节。

```java
new LengthFieldBasedFrameDecoder(Integer.MAX, 0, 4, 0, 4);
```

前面三个参数的含义和上文相同，第四个参数我们后面再讲，而这里的第五个参数就是`initialBytesToStrip`，这里为4，表示获取完一个完整的数据包之后，忽略前面的四个字节，应用解码器拿到的就是不带长度域的数据包。

#### 3. 基于偏移长度的拆包

下面这种方式二进制协议是更为普遍的，前面几个固定字节表示协议头，通常包含一些magicNumber，protocol version 之类的meta信息，紧跟着后面的是一个长度域，表示包体有多少字节的数据。

<img src="http://blog-1259650185.cosbj.myqcloud.com/img/202112/03/1638546420.jpg" alt="偏移长度的拆包" style="zoom:67%;" />

只需要基于第一种情况，调整第二个参数既可以实现。

```java
new LengthFieldBasedFrameDecoder(Integer.MAX, 4, 4);
```

`lengthFieldOffset` 是4，表示跳过4个字节之后的才是长度域。

#### 4. 基于可调整长度的拆包

有些时候，二进制协议可能会设计成如下方式：

<img src="http://blog-1259650185.cosbj.myqcloud.com/img/202112/03/1638546557.jpg" alt="可调整长度的拆包" style="zoom: 67%;" />



即长度域在前，header在后，这种情况又是如何来调整参数达到我们想要的拆包效果呢？

1. 长度域在数据包最前面表示无偏移，`lengthFieldOffset` 为 0。
2. 长度域的长度为3，即`lengthFieldLength`为3。
3. 长度域表示的包体的长度略过了header，这里有另外一个参数，叫做 `lengthAdjustment`，包体长度调整的大小，长度域的数值表示的长度加上这个修正值表示的就是带header的包，这里是 12+2，header和包体一共占14个字节。

最后，代码实现为：

```java
new LengthFieldBasedFrameDecoder(Integer.MAX, 0, 3, 2, 0);
```

#### 5. 基于偏移可调整长度的截断拆包

更变态一点的二进制协议带有两个header，比如下面这种：

<img src="http://blog-1259650185.cosbj.myqcloud.com/img/202112/03/1638547019.jpg" alt="可调整长度的截断拆包" style="zoom: 67%;" />

拆完之后，`HDR1` 丢弃，长度域丢弃，只剩下第二个header和有效包体，这种协议中，一般`HDR1`可以表示magicNumber，表示应用只接受以该magicNumber开头的二进制数据，rpc里面用的比较多。

我们仍然可以通过设置netty的参数实现：

1. 长度域偏移为1，那么 `lengthFieldOffset`为1。
2. 长度域长度为2，那么`lengthFieldLength`为2。
3. 长度域表示的包体的长度略过了HDR2，但是拆包的时候HDR2也被netty当作是包体的的一部分来拆，HDR2的长度为1，那么 `lengthAdjustment` 为1。
4. 拆完之后，截掉了前面三个字节，那么 `initialBytesToStrip` 为 3。

最后，代码实现为：

```java
new LengthFieldBasedFrameDecoder(Integer.MAX, 1, 2, 1, 3);
```

#### 6. 基于偏移可调整变异长度的截断拆包

前面的所有的长度域表示的都是不带header的包体的长度，如果让长度域表示的含义包含整个数据包的长度，比如如下这种情况：

<img src="http://blog-1259650185.cosbj.myqcloud.com/img/202112/03/1638547150.jpg" alt="于偏移可调整变异长度的截断拆包" style="zoom:67%;" />

其中长度域字段的值为16， 其字段长度为2，HDR1的长度为1，HDR2的长度为1，包体的长度为12，1+1+2+12=16，又该如何设置参数呢？

这里除了长度域表示的含义和上一种情况不一样之外，其他都相同，因为netty并不了解业务情况，你需要告诉netty的是，长度域后面，再跟多少字节就可以形成一个完整的数据包，这里显然是13个字节，而长度域的值为16，因此减掉3才是真是的拆包所需要的长度，`lengthAdjustment`为-3。

这里的六种情况是netty源码里自带的六中典型的二进制协议，相信已经囊括了90%以上的场景，如果你的协议是基于长度的，那么可以考虑不用字节来实现，而是直接拿来用，或者继承他，做些简单的修改即可。

如此强大的拆包器其实现也是非常优雅，下面我们来一起看下netty是如何来实现。

### LengthFieldBasedFrameDecoder 源码剖析

#### 构造函数

```java
// LengthFieldBasedFrameDecoder.java
public LengthFieldBasedFrameDecoder(
        ByteOrder byteOrder, int maxFrameLength, int lengthFieldOffset, int lengthFieldLength,
        int lengthAdjustment, int initialBytesToStrip, boolean failFast) {
    // 省略参数校验部分
    this.byteOrder = byteOrder;
    this.maxFrameLength = maxFrameLength;
    this.lengthFieldOffset = lengthFieldOffset;
    this.lengthFieldLength = lengthFieldLength;
    this.lengthAdjustment = lengthAdjustment;
    lengthFieldEndOffset = lengthFieldOffset + lengthFieldLength;
    this.initialBytesToStrip = initialBytesToStrip;
    this.failFast = failFast;
}
```

构造函数做的事很简单，只是把传入的参数简单地保存在field，这里的大多数field在前面已经阐述过，剩下的几个补充说明下：

1. `byteOrder` 表示字节流表示的数据是大端还是小端，用于长度域的读取。
2. `lengthFieldEndOffset`表示紧跟长度域字段后面的第一个字节的在整个数据包中的偏移量。
3. `failFast`，如果为true，则表示读取到长度域，它的值的超过`maxFrameLength`，就抛出一个 `TooLongFrameException`，而为false表示只有当真正读取完长度域的值表示的字节之后，才会抛出 `TooLongFrameException`，默认情况下设置为true，建议不要修改，否则可能会造成内存溢出。

#### 实现拆包抽象

在上一节，我们已经知道，具体的拆包协议只需要实现：

```java
// ByteToMessageDecoder.java
void decode(ChannelHandlerContext ctx, ByteBuf in, List<Object> out) 
```

其中 `in` 表示目前为止还未拆的数据，拆完之后的包添加到 `out`这个list中即可实现包向下传递。

`LengthFieldBasedFrameDecoder`的第一层实现比较简单，重载的protected函数`decode`做真正的拆包动作，下面分三个部分来分析一下这个重量级函数。

```java
// LengthFieldBasedFrameDecoder.java
@Override
protected final void decode(ChannelHandlerContext ctx, ByteBuf in, List<Object> out) throws Exception {
    Object decoded = decode(ctx, in);
    if (decoded != null) {
        out.add(decoded);
    }
}
```

#### 获取frame长度

##### 1. 获取需要待拆包的包大小

```java
// LengthFieldBasedFrameDecoder.java
// 如果当前可读字节还未达到长度长度域的偏移，那说明肯定是读不到长度域的，直接不读
if (in.readableBytes() < lengthFieldEndOffset) {
    return null;
}

// 拿到长度域的实际字节偏移 
int actualLengthFieldOffset = in.readerIndex() + lengthFieldOffset;
// 拿到实际的未调整过的包长度
long frameLength = getUnadjustedFrameLength(in, actualLengthFieldOffset, lengthFieldLength, byteOrder);


// 如果拿到的长度为负数，直接跳过长度域并抛出异常
if (frameLength < 0) {
    in.skipBytes(lengthFieldEndOffset);
    throw new CorruptedFrameException(
            "negative pre-adjustment length field: " + frameLength);
}

// 调整包的长度，后面统一做拆分
frameLength += lengthAdjustment + lengthFieldEndOffset;
```

上面这一段内容有个扩展点 `getUnadjustedFrameLength`，如果你的长度域代表的值表达的含义不是正常的int,short等基本类型，你可以重写这个函数。

```java
// LengthFieldBasedFrameDecoder.java
protected long getUnadjustedFrameLength(ByteBuf buf, int offset, int length, ByteOrder order) {
        buf = buf.order(order);
        long frameLength;
        switch (length) {
        case 1:
            frameLength = buf.getUnsignedByte(offset);
            break;
        case 2:
            frameLength = buf.getUnsignedShort(offset);
            break;
        case 3:
            frameLength = buf.getUnsignedMedium(offset);
            break;
        case 4:
            frameLength = buf.getUnsignedInt(offset);
            break;
        case 8:
            frameLength = buf.getLong(offset);
            break;
        default:
            throw new DecoderException(
                    "unsupported lengthFieldLength: " + lengthFieldLength + " (expected: 1, 2, 3, 4, or 8)");
        }
        return frameLength;
    }
```

比如，有的奇葩的长度域里面虽然是4个字节，比如 0x1234，但是它的含义是10进制，即长度就是十进制的1234，那么覆盖这个函数即可实现奇葩长度域拆包。

##### 2. 长度校验

```java
// LengthFieldBasedFrameDecoder.java
// 整个数据包的长度还没有长度域长，直接抛出异常
if (frameLength < lengthFieldEndOffset) {
    in.skipBytes(lengthFieldEndOffset);
    throw new CorruptedFrameException(
            "Adjusted frame length (" + frameLength + ") is less " +
            "than lengthFieldEndOffset: " + lengthFieldEndOffset);
}

// 数据包长度超出最大包长度，进入丢弃模式
if (frameLength > maxFrameLength) {
    long discard = frameLength - in.readableBytes();
    tooLongFrameLength = frameLength;

    if (discard < 0) {
        // 当前可读字节已达到frameLength，直接跳过frameLength个字节，丢弃之后，后面有可能就是一个合法的数据包
        in.skipBytes((int) frameLength);
    } else {
        // 当前可读字节未达到frameLength，说明后面未读到的字节也需要丢弃，进入丢弃模式，先把当前累积的字节全部丢弃
        discardingTooLongFrame = true;
        // bytesToDiscard表示还需要丢弃多少字节
        bytesToDiscard = discard;
        in.skipBytes(in.readableBytes());
    }
    failIfNecessary(true);
    return null;
}
```

最后，调用`failIfNecessary`判断是否需要抛出异常。

```java
// LengthFieldBasedFrameDecoder.java
private void failIfNecessary(boolean firstDetectionOfTooLongFrame) {
    // 不需要再丢弃后面的未读字节，就开始重置丢弃状态
    if (bytesToDiscard == 0) {
        long tooLongFrameLength = this.tooLongFrameLength;
        this.tooLongFrameLength = 0;
        discardingTooLongFrame = false;
        // 如果没有设置快速失败，或者设置了快速失败并且是第一次检测到大包错误，抛出异常，让handler去处理
        if (!failFast ||
            failFast && firstDetectionOfTooLongFrame) {
            fail(tooLongFrameLength);
        }
    } else {
        // 如果设置了快速失败，并且是第一次检测到打包错误，抛出异常，让handler去处理
        if (failFast && firstDetectionOfTooLongFrame) {
            fail(tooLongFrameLength);
        }
    }
}
```

前面我们可以知道`failFast`默认为true，而这里`firstDetectionOfTooLongFrame`为true，所以，第一次检测到大包肯定会抛出异常。

下面是抛出异常的代码：

```java
// LengthFieldBasedFrameDecoder.java
private void fail(long frameLength) {
    if (frameLength > 0) {
        throw new TooLongFrameException(
                        "Adjusted frame length exceeds " + maxFrameLength +
                        ": " + frameLength + " - discarded");
    } else {
        throw new TooLongFrameException(
                        "Adjusted frame length exceeds " + maxFrameLength +
                        " - discarding");
    }
}
```

#### 丢弃模式的处理

如果读者是一边对着源码，一边阅读本篇文章，就会发现 `LengthFieldBasedFrameDecoder.decoder` 函数的入口处还有一段代码在我们的前面的分析中被我省略掉了，放到这一小节中的目的是为了承接上一小节，更加容易读懂丢弃模式的处理。

```java
// LengthFieldBasedFrameDecoder.java
if (discardingTooLongFrame) {
    discardingTooLongFrame(in);
}

private void discardingTooLongFrame(ByteBuf in) {
    long bytesToDiscard = this.bytesToDiscard;
    int localBytesToDiscard = (int) Math.min(bytesToDiscard, in.readableBytes());
    in.skipBytes(localBytesToDiscard);
    bytesToDiscard -= localBytesToDiscard;
    this.bytesToDiscard = bytesToDiscard;

    failIfNecessary(false);
}
```

如上，如果当前处在丢弃模式，先计算需要丢弃多少字节，取当前还需可丢弃字节和可读字节的最小值，丢弃掉之后，进入 `failIfNecessary`，对照着这个函数看，默认情况下是不会继续抛出异常，而如果设置了 `failFast`为false，那么等丢弃完之后，才会抛出异常，读者可自行分析。

#### 跳过指定字节长度

```java
// LengthFieldBasedFrameDecoder.java
int frameLengthInt = (int) frameLength;
if (in.readableBytes() < frameLengthInt) {
    return null;
}

if (initialBytesToStrip > frameLengthInt) {
    in.skipBytes(frameLengthInt);
    throw new CorruptedFrameException(
            "Adjusted frame length (" + frameLength + ") is less " +
            "than initialBytesToStrip: " + initialBytesToStrip);
}
in.skipBytes(initialBytesToStrip);
```

先验证当前是否已经读到足够的字节，如果读到了，在下一步抽取一个完整的数据包之前，需要根据`initialBytesToStrip`的设置来跳过某些字节，当然，跳过的字节不能大于数据包的长度，否则就抛出 `CorruptedFrameException` 的异常。

#### 抽取frame

```java
// LengthFieldBasedFrameDecoder.java
int readerIndex = in.readerIndex();
int actualFrameLength = frameLengthInt - initialBytesToStrip;
ByteBuf frame = extractFrame(ctx, in, readerIndex, actualFrameLength);
in.readerIndex(readerIndex + actualFrameLength);

return frame;

protected ByteBuf extractFrame(ChannelHandlerContext ctx, ByteBuf buffer, int index, int length) {
    return buffer.retainedSlice(index, length);
}
```

到了最后抽取数据包其实就很简单了，拿到当前累积数据的读指针，然后拿到待抽取数据包的实际长度进行抽取，抽取之后，移动读指针。

抽取的过程是简单的调用了一下 `ByteBuf` 的`retainedSlice`api，该api无内存copy开销。

从真正抽取数据包来看看，传入的参数为 `int` 类型，所以，可以判断，自定义协议中，如果你的长度域是8个字节的，那么前面四个字节基本是没有用的。

## MessageToByteEncoder

MessageToByteEncoder框架可见用户使用POJO对象编码为字节数据存储到ByteBuf。用户只需定义自己的编码方法`encode()`即可。

首先看类签名：

```java
public abstract class MessageToByteEncoder<I> extends ChannelOutboundHandlerAdapter
```

可知该类只处理出站事件，切确的说是write事件。

该类有两个成员变量，`preferDirect`表示是否使用内核的DirectedByteBuf，默认为true。`TypeParameterMatcher`用于检测泛型参数是否是期待的类型，比如说，如果需要编码`String`类的POJO对象，Matcher会确保`write()`传入的参数`Object`的实际切确类型为`String`。

直接分析`write()`的处理：

```java
// MessageToByteEncoder.java
@Override
public void write(ChannelHandlerContext ctx, Object msg, ChannelPromise promise) throws Exception {
    ByteBuf buf = null;
    try {
        if (acceptOutboundMessage(msg)) { //1. 需要判断当前编码器能否处理这类对象
            @SuppressWarnings("unchecked")
            I cast = (I) msg; // 2.强制类型转换
            buf = allocateBuffer(ctx, cast, preferDirect); // 3.分配内存
            try {
                encode(ctx, cast, buf); // 4.回到子类的实现方法中，将buf装满数据（用户将数据写入ByteBuf）
            } finally {
                ReferenceCountUtil.release(cast); // 既然自定义java对象转换成ByteBuf了，那么这个对象就已经无用了，释放掉。(当传入的msg类型是ByteBuf的时候，就不需要自己手动释放了)
            }

            if (buf.isReadable()) { // 5.buf到这里已经装载着数据，于是把该buf往前丢，直到head节点
                ctx.write(buf, promise);
            } else { // 没有需要写的数据，也有可能是用户编码错误
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
            buf.release(); // 释放buf，避免堆外内存泄漏
        }
    }
}
```

编码框架简单明了，再列出`allocateBuffer()`方法的代码：

```java
// MessageToByteEncoder.java
protected ByteBuf allocateBuffer(ChannelHandlerContext ctx, @SuppressWarnings("unused") I msg,
                           boolean preferDirect) throws Exception {
    if (preferDirect) {
        return ctx.alloc().ioBuffer(); // 内核直接缓存
    } else {
        return ctx.alloc().heapBuffer(); // JAVA队缓存
    }
}
```

总的来说，编码的复杂度大大小于解码的复杂度，这是因为编码不需考虑TCP粘包。编解码的处理还有一个常用的类`MessageToMessageCodec`用于POJO对象之间的转换。如果有兴趣，可下载源码查看。至此，编解码框架已分析完毕。

## 总结

netty的拆包过程和自己写手工拆包并没有什么不同，都是将字节累加到一个容器里面，判断当前累加的字节数据是否达到了一个包的大小，达到一个包大小就拆开，进而传递到上层业务解码handler。

之所以netty的拆包能做到如此强大，就是因为netty将具体如何拆包抽象出一个`decode`方法，不同的拆包器实现不同的`decode`方法，就能实现不同协议的拆包。

如果你使用了netty，并且二进制协议是基于长度，考虑使用`LengthFieldBasedFrameDecoder`吧，通过调整各种参数，一定会满足你的需求。`LengthFieldBasedFrameDecoder`的拆包包括合法参数校验，异常包处理，以及最后调用 `ByteBuf` 的`retainedSlice`来实现无内存copy的拆包。

## 参考

[netty源码分析之拆包器的奥秘](https://www.jianshu.com/p/dc26e944da95)

[netty源码分析之LengthFieldBasedFrameDecoder](https://www.jianshu.com/p/a0a51fd79f62)

[LengthFieldBasedFrameDecoder - 参数说明](https://blog.csdn.net/liyantianmin/article/details/85603347)

[自顶向下深入分析Netty（八）--CodecHandler](https://www.jianshu.com/p/c3fbd6113dd6)
