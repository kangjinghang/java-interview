应用：新美大push服务-长连通道sailfish
日推送消息：180亿
QPS峰值: 35W
最大实时在线用户：2200W

push服务简单结构为

> 客户端sdk<=>长连通道sailfish<=>pushServer

1.客户端sdk: 负责提供客户客户端收发push的api

2.长连通道sailfish：负责维持海量客户端连接

3.pushServer：负责给业务方提供收发push的rpc服务，与长连通道sailfish通过tcp连接，自定义协议。

## 一

2016年9月2号6:00 左右陆续收到两台机器的报警，上去看一下[cat](https://github.com/dianping/cat)监控。

<img src="http://blog-1259650185.cosbj.myqcloud.com/img/202112/04/1638591328.jpg" alt="改造之前gc情况" style="zoom:50%;" />

发现 在凌晨4:11分左右，这台机器cms old区域到达old gc阀值1525M（old区域设置为2048M, -XX:CMSInitiatingOccupancyFraction=70，所以阀值为1433M，前一分钟为1428.7M），于是进行old gc，结果进行一次old gc之后，啥也没回收掉，接下来**一次次old gc，old区不减反增，甚是诡异！**

<img src="http://blog-1259650185.cosbj.myqcloud.com/img/202112/04/1638591420.jpg" alt="gc日志" style="zoom:67%;" />

在4:10:29开始频繁old gc(其实这是第二次old gc了，之前已经有过一次，不过可以忽略，我就拿这次来分析)，发现old gc过后，old区域大小基本没变，所以这个时候可以断定old区里面肯定有一直被引用的对象，猜测为缓存之类的对象。

## 二

使用 jmap -dump:live,format=b,file=xxx [pid] 先触发一次gc再dump。

重点关注这台10.32.145.237。

dump 的时候，花了long long的时间,为了不影响线上引用，遂放弃。。。

## 三

9月3号早上又发现old gc，于是连忙起床去dump内存，总内存为1.8G，MAT载入分析。

<img src="http://blog-1259650185.cosbj.myqcloud.com/img/202112/04/1638591626.jpg" alt="堆内存" style="zoom:50%;" />



光这两个家伙就占据了71.24%，其他的可以忽略不计。

然后看到NioSocketChannel这个家伙，对应着某条TCP连接，于是追根溯源，找到这条连接对应的机器。

<img src="http://blog-1259650185.cosbj.myqcloud.com/img/202112/04/1638591684.jpg" alt="NioSocketChannel 堆内存" style="zoom:50%;" />



然后去cmdb里面一查。

<img src="http://blog-1259650185.cosbj.myqcloud.com/img/202112/04/1638591734.jpg" alt="cmdb" style="zoom:50%;" />

发现是pushServer的机器。长连通道服务器sailfish是用netty实现，自带缓冲区，对外连接着海量的客户端，将海量用户的请求转发给pushServer，而pushServer是BIO实现，无IO缓冲区，当pushServer的TCP缓冲区满了之后，TCP滑动窗口为0，那么长连服务器发送给这台机器的消息netty就一直会保存在自带的缓冲区ChannelOutBoundBuffer里，撑大old区。接下来需要进一步验证：

## 四

9月5号早上，来公司验证，跑到10.12.22.253这台机器看一下tcp底层缓冲区的情况。

<img src="http://blog-1259650185.cosbj.myqcloud.com/img/202112/04/1638592054.jpg" alt="tcp -antp" style="zoom:50%;" />

发现tcp发送队列积压了这么多数据没发出去，这种情况发生的原因是接收方来不及处理，接收方的接收队列里面数据积压，于是导致发送方发送不出去，接下来就跑到接收方机器上看下tcp的接收队列。

<img src="http://blog-1259650185.cosbj.myqcloud.com/img/202112/04/1638592115.jpg" alt="10.32.177.127" style="zoom:67%;" />

<img src="http://blog-1259650185.cosbj.myqcloud.com/img/202112/04/1638592143.jpg" alt="10.4.210.192" style="zoom:67%;" />

<img src="http://blog-1259650185.cosbj.myqcloud.com/img/202112/04/1638592187.jpg" alt="10.4.210.193" style="zoom:67%;" />

果不其然，三台机器接受队列都撑得很大，到这里，问题基本排查出来了，结论是接收方处理速度过慢导致发送方积压消息过多，netty会把要发送的消息保存在ChannelOutboundBuffer里面，随着积压的消息越来越多，导致old区域逐渐扩大，最终old gc，然而这些消息对象都是live的，因此回收不掉，所以频繁old gc。

## 五

9月5号下午
 考虑到pushServer改造nio需要一段时间，长连通道这边又无法忍受频繁old gc而不得不重启应用，于是在通道端做了一点更改，在选择pushServer写的时候，只选择可写的Channel。

```java
 public ChannelGroupFuture writeAndFlushRandom(Object message) {
        final int size = super.size();
        if (size <= 0) {
            return super.writeAndFlush(message);
        }

        return super.writeAndFlush(message, new ChannelMatcher() {
            private int index = 0;
            private int matchedIndex = random.nextInt(size());

            @Override
            public boolean matches(Channel channel) {
                return matchedIndex == index++ && channel.isWritable();
            }
        });
    }
```

以上`&& channel.isWritable()`为新添加代码，追踪一下isWritable方法的实现，最终是调用到AbstractChannel的isWritable方法。

```java
// AbstractChannel.java
@Override
public boolean isWritable() {
  ChannelOutboundBuffer buf = unsafe.outboundBuffer();
  return buf != null && buf.isWritable();
}

// ChannelOutboundBuffer.java
public boolean isWritable() {
  return unwritable == 0;
}
```

而unwritable这个field是在这里被确定。

```java
// ChannelOutboundBuffer.java
private void incrementPendingOutboundBytes(long size, boolean invokeLater) {
  if (size == 0) {
    return;
  }

  long newWriteBufferSize = TOTAL_PENDING_SIZE_UPDATER.addAndGet(this, size);
  if (newWriteBufferSize >= channel.config().getWriteBufferHighWaterMark()) {
    setUnwritable(invokeLater);
  }
}
```

其中`channel.config().getWriteBufferHighWaterMark()`返回的field是ChannelConfig里面对应的`writeBufferHighWaterMark`，可以看到，默认值为64K, 表示如果你在写之前调用调用isWriteable方法，netty最多给你缓存64K的数据, 否则，缓存就一直膨胀。

```java
// DefaultChannelConfig.java
private volatile int writeBufferHighWaterMark = 64 * 1024;
```

由此可见，Channel可写至少是TCP缓冲区+netty缓冲区(默认64K)都没有写满, 我这边的做法就是当某个Channel写满之后，就放弃这条Channel，随机选择其他的Channel。

## 六

改造完之后，观察了一个多礼拜，old区域已缓慢稳定增长，达到预期效果。

<img src="http://blog-1259650185.cosbj.myqcloud.com/img/202112/04/1638592471.jpg" alt="改造之后gc情况" style="zoom:50%;" />

可以发现，每次old区域都是1M左右的增长。

## 另外一个问题：每次olg gc的时候重启机器，瞬间异常井喷

<img src="http://blog-1259650185.cosbj.myqcloud.com/img/202112/04/1638594931.jpg" alt="TransferToPushServerException" style="zoom: 67%;" />

重启三次，三次异常，结合前面的ChannelOutboundBuffer，不难分析，这些写失败的都是之前被堵塞的buffer，重启之后，关闭与pushServer的连接，进入到如下方法。

```java
// AbstractChannel.java
public final void close(final ChannelPromise promise) {
        if (!promise.setUncancellable()) {
            return;
        }

        if (outboundBuffer == null) {
            // Only needed if no VoidChannelPromise.
            if (!(promise instanceof VoidChannelPromise)) {
                // This means close() was called before so we just register a listener and return
                closeFuture.addListener(new ChannelFutureListener() {
                    @Override
                    public void operationComplete(ChannelFuture future) throws Exception {
                        promise.setSuccess();
                    }
                });
            }
            return;
        }

        if (closeFuture.isDone()) {
            // Closed already.
            safeSetSuccess(promise);
            return;
        }

        final boolean wasActive = isActive();
        final ChannelOutboundBuffer buffer = outboundBuffer;
        outboundBuffer = null; // Disallow adding any messages and flushes to outboundBuffer.
        Executor closeExecutor = closeExecutor();
        if (closeExecutor != null) {
            closeExecutor.execute(new OneTimeTask() {
                @Override
                public void run() {
                    try {
                        // Execute the close.
                        doClose0(promise);
                    } finally {
                        // Call invokeLater so closeAndDeregister is executed in the EventLoop again!
                        invokeLater(new OneTimeTask() {
                            @Override
                            public void run() {
                                // Fail all the queued messages
                                buffer.failFlushed(CLOSED_CHANNEL_EXCEPTION, false);
                                buffer.close(CLOSED_CHANNEL_EXCEPTION);
                                fireChannelInactiveAndDeregister(wasActive);
                            }
                        });
                    }
                }
            });
        } else {
            try {
                // Close the channel and fail the queued messages in all cases.
                doClose0(promise);
            } finally {
                // Fail all the queued messages.
                buffer.failFlushed(CLOSED_CHANNEL_EXCEPTION, false);
                buffer.close(CLOSED_CHANNEL_EXCEPTION);
            }
            if (inFlush0) {
                invokeLater(new OneTimeTask() {
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
```

程序进入到`outboundBuffer.failFlushed(CLOSED_CHANNEL_EXCEPTION, false);`然后进入到`ChannelOutboundBuffer`的`failFlushed`方法

```java
// ChannelOutboundBuffer.java
void failFlushed(Throwable cause, boolean notify) {
        // Make sure that this method does not reenter.  A listener added to the current promise can be notified by the
        // current thread in the tryFailure() call of the loop below, and the listener can trigger another fail() call
        // indirectly (usually by closing the channel.)
        //
        // See https://github.com/netty/netty/issues/1501
        if (inFail) {
            return;
        }

        try {
            inFail = true;
            for (;;) {
                if (!remove0(cause, notify)) {
                    break;
                }
            }
        } finally {
            inFail = false;
        }
    }
```

这里的for循环导致remove0 会遍历Entry缓存对象链表。

```java
// ChannelOutboundBuffer.java
private boolean remove0(Throwable cause, boolean notifyWritability) {
        Entry e = flushedEntry;
        if (e == null) {
            clearNioBuffers();
            return false;
        }
        Object msg = e.msg;

        ChannelPromise promise = e.promise;
        int size = e.pendingSize;

        removeEntry(e);

        if (!e.cancelled) {
            // only release message, fail and decrement if it was not canceled before.
            ReferenceCountUtil.safeRelease(msg);

            safeFail(promise, cause);
            decrementPendingOutboundBytes(size, false, notifyWritability);
        }

        // recycle the entry
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
            // 指针指向下一个待删除的缓存
            flushedEntry = e.next;
        }
    }

```

直到所有的缓存对象都被remove掉,remove0 每调用一次都会调用一次safeFail(promise, cause)方法。

```java
// ChannelOutboundBuffer.java 
private static void safeFail(ChannelPromise promise, Throwable cause) {
        if (!(promise instanceof VoidChannelPromise) && !promise.tryFailure(cause)) {
            logger.warn("Failed to mark a promise as failure because it's done already: {}", promise, cause);
        }
    }
```

然后进入到：

```java
// DefaultPromise.java
@Override
public boolean tryFailure(Throwable cause) {
    if (setFailure0(cause)) {
        notifyListeners();
        return true;
    }
    return false;
}   

static void notifyListener0(Future future, GenericFutureListener l) {
    try {
        l.operationComplete(future);
    } catch (Throwable t) {
        if (logger.isWarnEnabled()) {
            logger.warn("An exception was thrown by " + l.getClass().getName() + ".operationComplete()", t);
        }
    }
}
```

最终一个future回调，调回到用户方法。

```java
@Override
protected void channelRead0(ChannelHandlerContext ctx, TransferFromSdkDataPacket msg) throws Exception {
    TransferToPushServerDataPacket dataPacket = new TransferToPushServerDataPacket();

    dataPacket.setVersion(Constants.PUSH_SERVER_VERSION);
    dataPacket.setData(msg.getData());
    dataPacket.setConnectionId(ctx.channel().attr(AttributeKeys.CONNECTION_ID).get());

    final long startTime = System.nanoTime();

    try {
        ChannelGroupFuture channelFutures = pushServerChannels.writeAndFlushRandom(dataPacket);
        channelFutures.addListener(new GenericFutureListener<Future<? super Void>>() {
            @Override
            public void operationComplete(Future<? super Void> future) throws Exception {
                if (future.isSuccess()) {
                    CatUtil.logTransaction(startTime, null, CatTransactions.TransferToPushServer, CatTransactions.TransferToPushServer);
                } else {
                    Channel channel = (Channel) ((ChannelGroupFuture) future).group().toArray()[0];
                    final String pushServer = channel.remoteAddress().toString();
                    TransferToPushServerException e = new TransferToPushServerException(String.format("pushServer: %s", pushServer), future.cause());

                    CatUtil.logTransaction(new CatUtil.CatTransactionCallBack() {
                        @Override
                        protected void beforeComplete() {
                            Cat.logEvent(CatEvents.WriteToPushServerError, pushServer);
                        }
                    }, startTime, e, CatTransactions.TransferToPushServer, CatTransactions.TransferToPushServer);
                }
            }

        });
    } catch (Exception e) {
        CatUtil.logTransaction(startTime, e, CatTransactions.TransferToPushServer, CatTransactions.TransferToPushServer);
    }
}
```

而在用户方法里面，我们包装了一下自定义异常，喷到[cat](https://github.com/dianping/cat)，导致瞬间TransferToPushServerException飙高。



## 参考

[一次netty"引发的"诡异old gc问题排查过程](https://www.jianshu.com/p/702ef10102e4)
