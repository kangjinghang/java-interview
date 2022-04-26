## 前言

在前面的《Netty源码分析之pipeline》文章中，我们已经详细阐述了事件和异常传播在netty中的实现，其中有一类事件我们在实际编码中用得最多，那就是 `write`或者`writeAndFlush`，也就是我们今天的主要内容。

## 主要内容

本文分以下几个部分阐述一个java对象最后是如何转变成字节流，写到socket缓冲区中去的

1. pipeline中的标准链表结构
2. Java对象编码过程
3. write：写队列
4. flush：刷新写队列
5. writeAndFlush: 写队列并刷新

### pipeline中的标准链表结构

一个标准的pipeline链式结构如下(我们省去了异常处理Handler)：

<img src="http://blog-1259650185.cosbj.myqcloud.com/img/202111/30/1638277523.jpg" alt="pipeline结构" style="zoom:67%;" />

数据从head节点流入，先拆包，然后解码成业务对象，最后经过业务Handler处理，调用write，将结果对象写出去。而写的过程先通过tail节点，然后通过encoder节点将对象编码成ByteBuf，最后将该ByteBuf对象传递到head节点，调用底层的Unsafe写到jdk底层管道。

### Java对象编码过程

为什么我们在pipeline中添加了encoder节点，Java对象就转换成netty可以处理的ByteBuf，写到管道里？

我们先看下调用`write`的code。

```java
// 用户代码，BusinessHandler
protected void channelRead0(ChannelHandlerContext ctx, Request request) throws Exception {
    Response response = doBusiness(request);
    
    if (response != null) {
        ctx.channel().write(response);
    }
 }
```

业务处理器接受到请求之后，做一些业务处理，返回一个`Response`，然后，response在pipeline中传递，落到 `Encoder`节点，下面是 `Encoder` 的处理流程。

```java
// 用户代码，Encoder
public class Encoder extends MessageToByteEncoder<Response> {
    @Override
    protected void encode(ChannelHandlerContext ctx, Response response, ByteBuf out) throws Exception {
        out.writeByte(response.getVersion());
        out.writeInt(4 + response.getData().length);
        out.writeBytes(response.getData());
    }
}
```

Encoder的处理流程很简单，按照简单自定义协议，将java对象 `Response` 写到传入的参数 `out`中，这个`out`到底是什么？

为了回答这个问题，我们需要了解到 `Response` 对象，从 `BusinessHandler` 传入到 `MessageToByteEncoder`的时候，首先是传入到 `write` 方法。

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

我们详细阐述一下Encoder是如何处理传入的Java对象的

1. 判断当前Handler是否能处理写入的消息，如果能处理，进入下面的流程，否则，直接扔给下一个节点处理。
2. 将对象强制转换成`Encoder`可以处理的 `Response`对象。
3. 分配一个ByteBuf。
4. 调用encoder，即进入到 `Encoder` 的 `encode`方法，该方法是用户代码，用户将数据写入ByteBuf。
5. 既然自定义java对象转换成ByteBuf了，那么这个对象就已经无用了，释放掉，(当传入的msg类型是ByteBuf的时候，就不需要自己手动释放了)。
6. 如果buf中写入了数据，就把buf传到下一个节点，否则，释放buf，将空数据传到下一个节点。
7. 最后，当buf在pipeline中处理完之后，释放节点。

总结一点就是，`Encoder`节点分配一个ByteBuf，调用`encode`方法，将java对象根据自定义协议写入到ByteBuf，然后再把ByteBuf传入到下一个节点，在我们的例子中，最终会传入到head节点。

```java
// HeadContext.java
public void write(ChannelHandlerContext ctx, Object msg, ChannelPromise promise) throws Exception {
    unsafe.write(msg, promise);
}
```

这里的msg就是前面在`Encoder`节点中，载有Java对象数据的自定义ByteBuf对象，进入下一节。

### write：写队列

实际的write操作最终是由Unsafe完成的，详情如下代码：

```java
// AbstractUnsafe.java
@Override
public final void write(Object msg, ChannelPromise promise) {
    assertEventLoop(); //  确保该方法的调用是在reactor线程中

    ChannelOutboundBuffer outboundBuffer = this.outboundBuffer;
    // 下面的判断，是判断是否 channel 已经关闭了
    if (outboundBuffer == null) {
        try {
            ReferenceCountUtil.release(msg);
        } finally {
            safeSetFailure(promise,
                    newClosedChannelException(initialCloseCause, "write(Object, ChannelPromise)"));
        }
        return;
    }

    int size;
    try {
      	// 过滤待写入的对象，把非ByteBuf对象和FileRegion过滤掉，把所有的非直接内存转换成直接内存DirectBuffer
        msg = filterOutboundMessage(msg); // 委托给AbstractChannel（通常是AbstractNioByteChannel）调用
        size = pipeline.estimatorHandle().size(msg); // 估算出需要写入的ByteBuf的size
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
    // 消息放到 buf 里面
    outboundBuffer.addMessage(msg, size, promise);
}

// AbstractNioByteChannel.java
@Override
protected final Object filterOutboundMessage(Object msg) { // 过滤非ByteBuf和FileRegion的对象
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

1. 调用 `assertEventLoop` 确保该方法的调用是在reactor线程中。
2. 委托给`AbstractChannel`（通常是`AbstractNioByteChannel`）调用 `filterOutboundMessage()` 方法，将待写入的对象过滤，把非`ByteBuf`对象和`FileRegion`过滤，把所有的非直接内存转换成直接内存`DirectBuffer`。
3. 估算出需要写入的ByteBuf的size。
4. 调用 `ChannelOutboundBuffer` 的`addMessage(msg, size, promise)` 方法。所以，接下来，我们需要重点看一下这个方法干了什么事情。

```java
// ChannelOutboundBuffer.java
public void addMessage(Object msg, int size, ChannelPromise promise) {
    Entry entry = Entry.newInstance(msg, size, total(msg), promise);   // 创建一个待写出的消息节点
    if (tailEntry == null) {
        flushedEntry = null;
    } else {
        Entry tail = tailEntry;
        tail.next = entry;
    }
    tailEntry = entry; // 追加到队尾
    if (unflushedEntry == null) {
        unflushedEntry = entry;
    }

    incrementPendingOutboundBytes(entry.pendingSize, false);
}

```

想要理解上面这段代码，必须得掌握写缓存中的几个消息指针，如下图：

<img src="http://blog-1259650185.cosbj.myqcloud.com/img/202112/01/1638374259.jpg" alt="指针1"  />

ChannelOutboundBuffer 里面的数据结构是一个单链表结构，每个节点是一个 `Entry`，`Entry` 里面包含了待写出`ByteBuf` 以及消息回调 `promise`，下面分别是三个指针的作用：

1. flushedEntry 指针表示第一个要被写到操作系统Socket缓冲区中的节点。
2. unFlushedEntry 指针表示第一个未被写入到操作系统Socket缓冲区中的节点。
3. tailEntry指针表示ChannelOutboundBuffer缓冲区的最后一个节点。

初次调用 `addMessage` 之后，各个指针的情况为：

<img src="http://blog-1259650185.cosbj.myqcloud.com/img/202112/02/1638374668.jpg" alt="指针2"  />

`fushedEntry`指向空，`unFushedEntry`和 `tailEntry` 都指向新加入的节点。

第二次调用 `addMessage`之后，各个指针的情况为：

<img src="http://blog-1259650185.cosbj.myqcloud.com/img/202112/02/1638374890.jpg" alt="指针3"  />

第n次调用 `addMessage`之后，各个指针的情况为：

<img src="http://blog-1259650185.cosbj.myqcloud.com/img/202112/02/1638374928.jpg" alt="指针4"  />

可以看到，调用n次`addMessage`，flushedEntry指针一直指向NULL，表示现在还没有节点需要写出到Socket缓冲区，而`unFushedEntry`之后有n个节点，表示当前还有n个节点尚未写出到Socket缓冲区中去。

### flush：刷新写队列

不管调用`channel.flush()`，还是`ctx.flush()`，最终都会落地到pipeline中的head节点。

```java
// HeadContext.java
@Override
public void flush(ChannelHandlerContext ctx) {
    unsafe.flush();
}

// AbstractUnsafe.java
@Override
public final void flush() {
    assertEventLoop();

    ChannelOutboundBuffer outboundBuffer = this.outboundBuffer;
    if (outboundBuffer == null) { // outboundBuffer == null 表明 channel 关闭了
        return;
    }

    outboundBuffer.addFlush();
    flush0();
}

// ChannelOutboundBuffer.java
public void addFlush() {
    Entry entry = unflushedEntry;
    if (entry != null) {
        if (flushedEntry == null) {
            // there is no flushedEntry yet, so start with the entry，unflushedEntry 数据转换为 flushedEntry
            flushedEntry = entry;
        }
        do {
            flushed ++;
            if (!entry.promise.setUncancellable()) {
                // Was cancelled so make sure we free up memory and notify about the freed bytes
                int pending = entry.cancel();
                decrementPendingOutboundBytes(pending, false, true);
            }
            entry = entry.next;
        } while (entry != null);

        unflushedEntry = null;
    }
}
```

可以结合前面的图来看，首先拿到 `unflushedEntry` 指针，然后将 `flushedEntry` 指向`unflushedEntry`所指向的节点，调用完毕之后，三个指针的情况如下所示：

![指针5](http://blog-1259650185.cosbj.myqcloud.com/img/202112/02/1638375262.jpg)

接下来，调用 `flush0();`

```java
protected void flush0() {
		...
    try {
        doWrite(outboundBuffer); // 核心方法，委托给AbstractNioByteChannel执行
    } catch (Throwable t) {
        handleWriteError(t);
    } finally {
        inFlush0 = false;
    }
}
```

发现这里的核心代码就一个 doWrite，继续跟。

```java
// AbstractNioByteChannel.java
@Override
protected void doWrite(ChannelOutboundBuffer in) throws Exception {
    int writeSpinCount = config().getWriteSpinCount(); // 1.拿到自旋锁迭代次数
    do {
        Object msg = in.current(); // 2.拿到第一个需要flush的节点的数据
        if (msg == null) {
            // Wrote all messages.
            clearOpWrite();
            // Directly return here so incompleteWrite(...) is not called.
            return;
        }
        writeSpinCount -= doWriteInternal(in, msg); // 3.不断的自旋调用doWriteInternal方法，直到自旋次数小于或等于0为止
    } while (writeSpinCount > 0);

    incompleteWrite(writeSpinCount < 0);
}
```

首先，拿到自旋锁的迭代次数，默认值为16。

```java
// DefaultChannelConfig
private volatile int writeSpinCount = 16;

@Override
public int getWriteSpinCount() {
    return writeSpinCount;
}
```

关于为什么要用自旋锁，netty的文档已经解释得很清楚。

> ChannelConfig.java
>
> Returns the maximum loop count for a write operation until WritableByteChannel.write(ByteBuffer) returns a non-zero value. It is similar to what a spin lock is used for in concurrency programming. It improves memory utilization and write throughput depending on the platform that JVM runs on. The default value is 16.

然后，调用`current()`先拿到第一个需要flush的节点的数据。

```java
// ChannelOutBoundBuffer.java
public Object current() {
    Entry entry = flushedEntry;
    if (entry == null) {
        return null;
    }

    return entry.msg;
}
```

最后，不断的自旋调用`doWriteInternal`方法，直到自旋次数小于或等于0为止。下面跟进一下`doWriteInternal`方法。

```java
// AbstractNioByteChannel.java
// 同filterOutboundMessage(msg)呼应，只能写ByteBuf或FileRegion类型的数据
private int doWriteInternal(ChannelOutboundBuffer in, Object msg) throws Exception {
    if (msg instanceof ByteBuf) {
        ByteBuf buf = (ByteBuf) msg;
        if (!buf.isReadable()) {
            in.remove();
            return 0;
        }

        final int localFlushedAmount = doWriteBytes(buf); // 将当前节点写出
        if (localFlushedAmount > 0) {
            in.progress(localFlushedAmount);
            if (!buf.isReadable()) {
                in.remove(); // 写完之后，将当前节点删除
            }
            return 1;
        }
    } else if (msg instanceof FileRegion) {
			...
    } else {
        // Should not reach here.
        throw new Error();
    }
    return WRITE_STATUS_SNDBUF_FULL;
}

@Override
protected int doWriteBytes(ByteBuf buf) throws Exception {
    final int expectedWrittenBytes = buf.readableBytes();
    return buf.readBytes(javaChannel(), expectedWrittenBytes);
}
```

在这一步中，以msg为`ByteBuf`类型为例，首先进行类型转换，然后调用`doWriteBytes`方法，将ByteBuf中的数据写到JDK的nio chanel中去，最后，在写完之后，调用`ChannelOutboundBuffer.remove()`删除该节点。

```java
// ChannelOutboundBuffer.java
public boolean remove() {
    Entry e = flushedEntry; // 拿到当前被flush掉的节点(flushedEntry所指)
    if (e == null) {
        clearNioBuffers();
        return false;
    }
    Object msg = e.msg;

    ChannelPromise promise = e.promise; // 到该节点的回调对象 ChannelPromise
    int size = e.pendingSize;

    removeEntry(e); // 移除该节点，并将的flushedEntry（下一个要被写到socket缓冲区的指针）指针指向下一个节点

    if (!e.cancelled) {
        // only release message, notify and decrement if it was not canceled before.
        ReferenceCountUtil.safeRelease(msg); 
        safeSuccess(promise); // 回调用户的listener
        decrementPendingOutboundBytes(size, false, true);
    }

    // 回收当前节点
    e.recycle();

    return true;
}

private void removeEntry(Entry e) {
    if (-- flushed == 0) {
        // processed everything
        flushedEntry = null;
        if (e == tailEntry) {
            tailEntry = null;
            unflushedEntry = null;
        }
    } else {
        flushedEntry = e.next; // flushedEntry（下一个要被写到socket缓冲区的指针）指向下一个节点
    }
}
```

具体的删除操作流程就是，首先拿到当前被flush掉的节点(flushedEntry所指)，然后拿到该节点的回调对象 `ChannelPromise`， 调用 `removeEntry()`方法移除该节点（逻辑移除），并将flushedEntry指针指向下一个节点。调用完毕之后，节点图示如下。

![指针6](http://blog-1259650185.cosbj.myqcloud.com/img/202112/02/1638411415.jpg)





随后，释放该节点数据的内存，调用 `safeSuccess` 进行回调，用户代码可以在回调里面做一些记录，下面是一段Example。

```java
// ChannelOutboundBuffer.java
private static void safeSuccess(ChannelPromise promise) {
    // 回调用户的listener
    PromiseNotificationUtil.trySuccess(promise, null, promise instanceof VoidChannelPromise ? null : logger);
}

// PromiseNotificationUtil.java
public static <V> void trySuccess(Promise<? super V> p, V result, InternalLogger logger) {
    if (!p.trySuccess(result) && logger != null) { // 回调用户的listener
        Throwable err = p.cause();
        if (err == null) {
            logger.warn("Failed to mark a promise as success because it has succeeded already: {}", p);
        } else {
            logger.warn(
                    "Failed to mark a promise as success because it has failed already: {}, unnotified cause:",
                    p, err);
        }
    }
}

// DefaultPromise.java
@Override
public boolean trySuccess(V result) {
    return setSuccess0(result);
}

private boolean setSuccess0(V result) {
    return setValue0(result == null ? SUCCESS : result);
}

private boolean setValue0(Object objResult) {
    if (RESULT_UPDATER.compareAndSet(this, null, objResult) ||
        RESULT_UPDATER.compareAndSet(this, UNCANCELLABLE, objResult)) {
        if (checkNotifyWaiters()) {
            notifyListeners(); // 回调用户的listener
        }
        return true;
    }
    return false;
}

// 用户代码
ctx.write(xx).addListener(new GenericFutureListener<Future<? super Void>>() {
    @Override
    public void operationComplete(Future<? super Void> future) throws Exception {
       // 回调 
    }
})
```

最后，调用 `recycle`方法，将当前节点回收。

### writeAndFlush: 写队列并刷新

理解了write和flush这两个过程，`writeAndFlush` 也就不难了。

writeAndFlush在某个Handler中被调用之后，最终会落到 `TailContext` 节点，见 《netty源码分析之pipeline》。

```java
// DefaultChannelPipeline.java
@Override
public final ChannelFuture writeAndFlush(Object msg) {
    return tail.writeAndFlush(msg);
}

// AbstractChannelHandlerContext.java
@Override
public ChannelFuture writeAndFlush(Object msg) {
    return writeAndFlush(msg, newPromise());
}

@Override
public ChannelFuture writeAndFlush(Object msg, ChannelPromise promise) {
    write(msg, true, promise);
    return promise;
}

private void write(Object msg, boolean flush, ChannelPromise promise) {
    ObjectUtil.checkNotNull(msg, "msg");
		...
    // 找到下一个 handlerContext
    final AbstractChannelHandlerContext next = findContextOutbound(flush ?
            (MASK_WRITE | MASK_FLUSH) : MASK_WRITE);
    // 引用计数用的，用来监测内存泄露
    final Object m = pipeline.touch(msg, next);
    EventExecutor executor = next.executor();
    if (executor.inEventLoop()) { // reactor线程（IO线程）调用
        if (flush) {
            next.invokeWriteAndFlush(m, promise);
        } else {
            next.invokeWrite(m, promise);
        }
    } else {  // 用户线程调用，比如在消息推送系统中，Channel channel = getChannel(userInfo); channel.writeAndFlush(pushInfo);
        final WriteTask task = WriteTask.newInstance(next, m, promise, flush);
        if (!safeExecute(executor, task, promise, m, !flush)) {
            task.cancel();
        }
    }
}
```

可以看到，最终，通过一个boolean类型的`flush`变量，表示是调用 `invokeWriteAndFlush`，还是 `invokeWrite`，`invokeWrite`便是我们上文中的`write`过程。

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
```

可以看到，最终调用的底层方法和单独调用 `write` 和 `flush` 是一样的。

由此看来，`invokeWriteAndFlush`基本等价于`write`方法之后再来一次`flush`。

## 总结

1. pipeline中的编码器原理是创建一个ByteBuf,将Java对象转换为ByteBuf，然后再把ByteBuf继续向前传递。
2. 调用write方法并没有将数据写到Socket缓冲区中，而是写到了一个单向链表的数据结构中，flush才是真正的写出。
3. writeAndFlush等价于先将数据写到netty的缓冲区，再将netty缓冲区中的数据写到Socket缓冲区中，写的过程与并发编程类似，用自旋锁保证写成功。
4. netty中的缓冲区中的ByteBuf为DirectByteBuf。

## 参考

[netty源码分析之writeAndFlush全解析](https://www.jianshu.com/p/feaeaab2ce56)
