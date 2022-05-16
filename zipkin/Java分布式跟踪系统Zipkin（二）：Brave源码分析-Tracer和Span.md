Brave 是 Java 版的 Zipkin 客户端，它将收集的跟踪信息，以 Span 的形式上报给 Zipkin 系统。

（Zipkin 是基于 Google 的一篇论文，名为 Dapper，Dapper 在荷兰语里是“勇敢的”的意思，这也是 Brave 的命名的原因）

Brave 目前版本为 4.9.1，兼容 zipkin1 和 2 的协议，github地址：https://github.com/openzipkin/brave

我们一般不会手动编写 Trace 相关的代码，Brave 提供了一些开箱即用的库，来帮助我们对某些特定的库类来进行追踪，比如 servlet，springmvc，mysql，okhttp3，httpclient 等，这些都可以在下面页面中找到：

https://github.com/openzipkin/brave/tree/master/instrumentation

我们先来看看一个简单的 Demo 来演示下 Brave 的基本使用，这对我们后续分析 Brave 的原理和其他类库的使用有很大帮助

TraceDemo

```java
package tracing;

import brave.Span;
import brave.Tracer;
import brave.Tracing;
import brave.context.log4j2.ThreadContextCurrentTraceContext;
import brave.propagation.B3Propagation;
import brave.propagation.ExtraFieldPropagation;
import zipkin2.codec.SpanBytesEncoder;
import zipkin2.reporter.AsyncReporter;
import zipkin2.reporter.Sender;
import zipkin2.reporter.okhttp3.OkHttpSender;

import java.util.concurrent.TimeUnit;

public class TraceDemo {

    public static void main(String[] args) {
        Sender sender = OkHttpSender.create("http://localhost:9411/api/v2/spans");
        AsyncReporter asyncReporter = AsyncReporter.builder(sender)
                .closeTimeout(500, TimeUnit.MILLISECONDS)
                .build(SpanBytesEncoder.JSON_V2);

        Tracing tracing = Tracing.newBuilder()
                .localServiceName("tracer-demo")
                .spanReporter(asyncReporter)
                .propagationFactory(ExtraFieldPropagation.newFactory(B3Propagation.FACTORY, "user-name"))
                .currentTraceContext(ThreadContextCurrentTraceContext.create())
                .build();

        Tracer tracer = tracing.tracer();
        Span span = tracer.newTrace().name("encode").start();
        try {
            doSomethingExpensive();
        } finally {
            span.finish();
        }


        Span twoPhase = tracer.newTrace().name("twoPhase").start();
        try {
            Span prepare = tracer.newChild(twoPhase.context()).name("prepare").start();
            try {
                prepare();
            } finally {
                prepare.finish();
            }
            Span commit = tracer.newChild(twoPhase.context()).name("commit").start();
            try {
                commit();
            } finally {
                commit.finish();
            }
        } finally {
            twoPhase.finish();
        }


        sleep(1000);

    }

    private static void doSomethingExpensive() {
        sleep(500);
    }

    private static void commit() {
        sleep(500);
    }

    private static void prepare() {
        sleep(500);
    }

    private static void sleep(long milliseconds) {
        try {
            TimeUnit.MILLISECONDS.sleep(milliseconds);
        } catch (InterruptedException e) {
            e.printStackTrace();
        }
    }
}
```

启动 Zipkin，然后运行 TraceDemo，在 Zipkin 的 UI 界面中能查到两条跟踪信息。

![image-20220511114658291](http://blog-1259650185.cosbj.myqcloud.com/img/202205/11/1652240818.png)

点击第一条跟踪信息，可以看到有一条Span(encode)，耗时500ms左右。

![image-20220511114854226](http://blog-1259650185.cosbj.myqcloud.com/img/202205/11/1652240934.png)

本条跟踪信息对应的代码片段为：

```java
Tracer tracer = tracing.tracer();
Span span = tracer.newTrace().name("encode").start();
try {
    doSomethingExpensive();
} finally {
    span.finish();
}
```

由 Tracer 创建一个新的 Span，名为 encode，然后调用 start 方法开始计时，之后运行一个比较耗时的方法 doSomethingExpensive，最后调用 finish 方法结束计时，完成并记录一条跟踪信息。

这段代码实际上向 Zipkin 上报的数据为：

```json
[
  {
    "traceId": "16661f6cb5d58903",
    "id": "16661f6cb5d58903",
    "name": "encode",
    "timestamp": 1510043590522358,
    "duration": 499867,
    "binaryAnnotations": [
      {
        "key": "lc",
        "value": "",
        "endpoint": {
          "serviceName": "tracer-demo",
          "ipv4": "192.168.99.1"
        }
      }
    ]
  }
]
```

然后我们再来看第二条稍微复杂的跟踪信息，可以看到一条名为 twoPhase 的 Span，总耗时为1000ms，它有2个子 Span，分别名为prepare 和 commit，两者分别耗时500ms。

![image-20220511115310732](http://blog-1259650185.cosbj.myqcloud.com/img/202205/11/1652241190.png)

这条跟踪信息对应的代码片段为：

```java
Span twoPhase = tracer.newTrace().name("twoPhase").start();
try {
    Span prepare = tracer.newChild(twoPhase.context()).name("prepare").start();
    try {
	prepare();
    } finally {
	prepare.finish();
    }
    Span commit = tracer.newChild(twoPhase.context()).name("commit").start();
    try {
	commit();
    } finally {
	commit.finish();
    }
} finally {
    twoPhase.finish();
}
```

这段代码实际上向 Zipkin 上报的数据为：

```json
[
  {
    "traceId": "89e051d5394b90b1",
    "id": "89e051d5394b90b1",
    "name": "twophase",
    "timestamp": 1510043591038983,
    "duration": 1000356,
    "binaryAnnotations": [
      {
        "key": "lc",
        "value": "",
        "endpoint": {
          "serviceName": "tracer-demo",
          "ipv4": "192.168.99.1"
        }
      }
    ]
  },
  {
    "traceId": "89e051d5394b90b1",
    "id": "60568c4903793b8d",
    "name": "prepare",
    "parentId": "89e051d5394b90b1",
    "timestamp": 1510043591039919,
    "duration": 499246,
    "binaryAnnotations": [
      {
        "key": "lc",
        "value": "",
        "endpoint": {
          "serviceName": "tracer-demo",
          "ipv4": "192.168.99.1"
        }
      }
    ]
  },
  {
    "traceId": "89e051d5394b90b1",
    "id": "ce14448169d01d2f",
    "name": "commit",
    "parentId": "89e051d5394b90b1",
    "timestamp": 1510043591539304,
    "duration": 499943,
    "binaryAnnotations": [
      {
        "key": "lc",
        "value": "",
        "endpoint": {
          "serviceName": "tracer-demo",
          "ipv4": "192.168.99.1"
        }
      }
    ]
  }
]
```

## 1. Span

首先看下 Span 的实现类 RealSpan

该类依赖几个核心类

**Recorder**，用于记录 Span

**Reporter**，用于上报 Span 给 Zipkin

**MutableSpan**，Span 的包装类，提供各种 API 操作 Span

**MutableSpanMap**，以TraceContext 为 Key，MutableSpan 为 Value 的 Map 结构，用于内存中存放所有的 Span

RealSpan 两个核心方法start, finish

```java
public Span start(long timestamp) {
  recorder().start(context(), timestamp);
  return this;
}

public void finish(long timestamp) {
  recorder().finish(context(), timestamp);
}
```

分别调用 Recorder 的 start 和 finish 方法，获取跟 TraceContext 绑定的 Span 信息，记录开始时间和结束时间，并在结束时，调用reporter 的 report 方法，上报给 Zipkin

```java
public void start(TraceContext context, long timestamp) {
  if (noop.get()) return;
  spanMap.getOrCreate(context).start(timestamp);
}

public void finish(TraceContext context, long finishTimestamp) {
  MutableSpan span = spanMap.remove(context);
  if (span == null || noop.get()) return;
  synchronized (span) {
    span.finish(finishTimestamp);
    reporter.report(span.toSpan());
  }
}
```

## 2. BoundedAsyncReporter

Reporter 的实现类 AsyncReporter，而 AsyncReporter 的实现类是 BoundedAsyncReporter

```java
static final class BoundedAsyncReporter<S> extends AsyncReporter<S> {
    static final Logger logger = Logger.getLogger(BoundedAsyncReporter.class.getName());
    final AtomicBoolean closed = new AtomicBoolean(false);
    final BytesEncoder<S> encoder;
    final ByteBoundedQueue pending;
    final Sender sender;
    final int messageMaxBytes;
    final long messageTimeoutNanos;
    final long closeTimeoutNanos;
    final CountDownLatch close;
    final ReporterMetrics metrics;

    BoundedAsyncReporter(Builder builder, BytesEncoder<S> encoder) {
      this.pending = new ByteBoundedQueue(builder.queuedMaxSpans, builder.queuedMaxBytes);
      this.sender = builder.sender;
      this.messageMaxBytes = builder.messageMaxBytes;
      this.messageTimeoutNanos = builder.messageTimeoutNanos;
      this.closeTimeoutNanos = builder.closeTimeoutNanos;
      this.close = new CountDownLatch(builder.messageTimeoutNanos > 0 ? 1 : 0);
      this.metrics = builder.metrics;
      this.encoder = encoder;
    }
}
```

BoundedAsyncReporter 中的几个重要的类：

- **BytesEncoder** - Span 的编码器，将 Span 编码成二进制，便于 sender 发送给 Zipkin。
- **ByteBoundedQueue** - 类似于BlockingQueue，是一个既有数量限制，又有字节数限制的阻塞队列。
- **Sender** - 将编码后的二进制数据，发送给 Zipkin。
- **ReporterMetrics** - Span 的 report 相关的统计信息。
- **BufferNextMessage** - Consumer，Span 信息的消费者，依靠 Sender 上报 Span 信息。

```java
public <S> AsyncReporter<S> build(BytesEncoder<S> encoder) {
  if (encoder == null) throw new NullPointerException("encoder == null");

  if (encoder.encoding() != sender.encoding()) {
    throw new IllegalArgumentException(String.format(
        "Encoder doesn't match Sender: %s %s", encoder.encoding(), sender.encoding()));
  }

  final BoundedAsyncReporter<S> result = new BoundedAsyncReporter<>(this, encoder);

  if (messageTimeoutNanos > 0) { // Start a thread that flushes the queue in a loop.
    final BufferNextMessage consumer =
        new BufferNextMessage(sender, messageMaxBytes, messageTimeoutNanos);
    final Thread flushThread = new Thread(() -> {
      try {
        while (!result.closed.get()) {
          result.flush(consumer);
        }
      } finally {
        for (byte[] next : consumer.drain()) result.pending.offer(next);
        result.close.countDown();
      }
    }, "AsyncReporter(" + sender + ")");
    flushThread.setDaemon(true);
    flushThread.start();
  }
  return result;
}
```

当 messageTimeoutNanos 大于0时，启动一个守护线程 flushThread，一直循环调用 BoundedAsyncReporter 的 flush 方法，将内存中的 Span 信息上报给 Zipkin， 而当 messageTimeoutNanos 等于0时，客户端需要手动调用 flush 方法来上报 Span 信息。

再来看下 BoundedAsyncReporter 中的 close 方法

```java
@Override public void close() {
  if (!closed.compareAndSet(false, true)) return; // already closed
  try {
    // wait for in-flight spans to send
    if (!close.await(closeTimeoutNanos, TimeUnit.NANOSECONDS)) {
      logger.warning("Timed out waiting for in-flight spans to send");
    }
  } catch (InterruptedException e) {
    logger.warning("Interrupted waiting for in-flight spans to send");
    Thread.currentThread().interrupt();
  }
  int count = pending.clear();
  if (count > 0) {
    metrics.incrementSpansDropped(count);
    logger.warning("Dropped " + count + " spans due to AsyncReporter.close()");
  }
}
```

这个 close 方法和 FlushThread 中 while 循环相呼应，在 close 方法中，首先将 closed 变量置为 true，然后调用 close.await()，等待close 信号量(CountDownLatch)的释放，此处代码会阻塞，一直到 FlushThread 中 finally 中调用 result.close.countDown();  而在 close方法中将 closed 变量置为 true 后，FlushThread 中的 while 循环将结束执行，然后执行 finally 代码块，系统会将内存中还未上报的Span，添加到 queue（result.pending）中，然后调用 result.close.countDown(); ，close 方法中阻塞的代码会继续执行，将调用metrics.incrementSpansDropped(count) 将这些 Span 的数量添加到 metrics 统计信息中

```java
@Override public void report(S span) {
  if (span == null) throw new NullPointerException("span == null");

  metrics.incrementSpans(1);
  byte[] next = encoder.encode(span);
  int messageSizeOfNextSpan = sender.messageSizeInBytes(Collections.singletonList(next));
  metrics.incrementSpanBytes(next.length);
  if (closed.get() ||
      // don't enqueue something larger than we can drain
      messageSizeOfNextSpan > messageMaxBytes ||
      !pending.offer(next)) {
    metrics.incrementSpansDropped(1);
  }
}
```

前面看到在 Recorder 的 finish 方法中，会调用 Reporter 的 report 方法，此处 report 方法，将 span 转化成字节数组，然后计算出messageSize，添加到 queue(pending)中，并记录相应的统计信息。

接下来看看两个 flush 方法，其中 flush() 方法，是 public 的，供外部手动调用，而 flush(BufferNextMessage bundler)是在FlushThread中 循环调用

```java
@Override public final void flush() {
  flush(new BufferNextMessage(sender, messageMaxBytes, 0));
}

void flush(BufferNextMessage bundler) {
  if (closed.get()) throw new IllegalStateException("closed");

  //将队列中的数据，全部提取到BufferNextMessage中，直到buffer(bundler)满为止
  pending.drainTo(bundler, bundler.remainingNanos());

  // record after flushing reduces the amount of gauge events vs on doing this on report
  metrics.updateQueuedSpans(pending.count);
  metrics.updateQueuedBytes(pending.sizeInBytes);

  // loop around if we are running, and the bundle isn't full
  // if we are closed, try to send what's pending
  if (!bundler.isReady() && !closed.get()) return;

  // Signal that we are about to send a message of a known size in bytes
  metrics.incrementMessages();
  metrics.incrementMessageBytes(bundler.sizeInBytes());
  List<byte[]> nextMessage = bundler.drain();

  try {
    sender.sendSpans(nextMessage).execute();
  } catch (IOException | RuntimeException | Error t) {
    // In failure case, we increment messages and spans dropped.
    int count = nextMessage.size();
    Call.propagateIfFatal(t);
    metrics.incrementMessagesDropped(t);
    metrics.incrementSpansDropped(count);
    if (logger.isLoggable(FINE)) {
      logger.log(FINE,
          format("Dropped %s spans due to %s(%s)", count, t.getClass().getSimpleName(),
              t.getMessage() == null ? "" : t.getMessage()), t);
    }
    // Raise in case the sender was closed out-of-band.
    if (t instanceof IllegalStateException) throw (IllegalStateException) t;
  }
}
```

flush中大致分下面几步：

1. 先将队列 pending 中的数据，全部提取到 BufferNextMessage（bundler）中，直到 bundler 满为止。
2. 当 bundler 准备好，即 isReady() 返回true，将 bundler 中的 message 全部取出来。
3. 将取出来的所有 message，调用 Sender 的 sendSpans 方法，发送到 Zipkin。

## 3. ByteBoundedQueue

类似于 BlockingQueue，是一个既有数量限制，又有字节数限制的阻塞队列，提供了offer，drainTo，clear三个方法，供调用者向queue里存放，提取和清空数据

```java
final class ByteBoundedQueue {

  final ReentrantLock lock = new ReentrantLock(false);
  final Condition available = lock.newCondition();

  final int maxSize;
  final int maxBytes;

  final byte[][] elements;
  int count;
  int sizeInBytes;
  int writePos;
  int readPos;

  ByteBoundedQueue(int maxSize, int maxBytes) {
    this.elements = new byte[maxSize][];
    this.maxSize = maxSize;
    this.maxBytes = maxBytes;
  }
}
```

ByteBoundedQueue 接受两个 int 参数，maxSize 是 queue 接受的最大数量，maxBytes 是 queue 接受的最大字节数。ByteBoundedQueue中 使用一个二维 byte 数组 elements 来存储 message，并使用 writePos 和 readPos 两个游标，分别记录写和读的位置。ByteBoundedQueue 中使用了最典型的可重入锁 ReentrantLock，使 offer，drainTo，clear 等方法是线程安全的。

```java
/**
 * Returns true if the element could be added or false if it could not due to its size.
 */
boolean offer(byte[] next) {
  lock.lock();
  try {
    if (count == elements.length) return false;
    if (sizeInBytes + next.length > maxBytes) return false;

    elements[writePos++] = next;

    if (writePos == elements.length) writePos = 0; // circle back to the front of the array

    count++;
    sizeInBytes += next.length;

    available.signal(); // alert any drainers
    return true;
  } finally {
    lock.unlock();
  }
}
```

offer 方法是添加 message 到queue 中，使用了标准的 try-lock 结构，即先获取锁，然后 finally 里释放锁。在获取锁以后，当 count 等于 elements.length 时，意味着 queue 是满的，则不能继续添加。 当 sizeInBytes + next.length > maxBytes 时，意味着该消息加进队列会超出队列字节大小限制，也不能添加新 message。 

如果上面两个条件都不满足，则表明可以继续添加 message，将 writePos+1，并将 message 放于 writePos+1处。当writePos 到达数组尾部，则将 writePos 置为0，让下一次添加从数组头部开始。然后将 count 计数器加1，并更新字节总数。最后调用 available.signal() 来通知其他在 lock 上等待的线程（在drainTo方法中阻塞的线程）继续竞争线程资源。

```java
/** Blocks for up to nanosTimeout for elements to appear. Then, consume as many as possible. */
int drainTo(Consumer consumer, long nanosTimeout) {
  try {
    // This may be called by multiple threads. If one is holding a lock, another is waiting. We
    // use lockInterruptibly to ensure the one waiting can be interrupted.
    lock.lockInterruptibly();
    try {
      long nanosLeft = nanosTimeout;
      while (count == 0) {
        if (nanosLeft <= 0) return 0;
        nanosLeft = available.awaitNanos(nanosLeft);
      }
      return doDrain(consumer);
    } finally {
      lock.unlock();
    }
  } catch (InterruptedException e) {
    return 0;
  }
}
```

drainTo 方法是提取 message 到 Consumer 中消费，如果当时 queue 里没有消息，则每次等待 nanosTimeout，直到 queue 里存入消息为止。当 while 循环退出，表明 queue 中已经有新的 message 添加进来，可以消费，则调用 doDrain 方法。

```java
int doDrain(Consumer consumer) {
  int drainedCount = 0;
  int drainedSizeInBytes = 0;
  while (drainedCount < count) {
    byte[] next = elements[readPos];

    if (next == null) break;
    if (consumer.accept(next)) {
      drainedCount++;
      drainedSizeInBytes += next.length;

      elements[readPos] = null;
      if (++readPos == elements.length) readPos = 0; // circle back to the front of the array
    } else {
      break;
    }
  }
  count -= drainedCount;
  sizeInBytes -= drainedSizeInBytes;
  return drainedCount;
}
```

doDrain 里依然是一个 while 循环，当 drainedCount 小于count，即提取的 message 数量总数小于 queue 里消息总数时，尝试调用consumer.accept 方法。如果 accept 方法返回 true，则将 drainedCount 加1，并且 drainedSizeInBytes 加上当前消息的字节数。如果accept 方法返回 false，则跳出循环，将 queue 的 count 减掉提取的总消息数 drainedCount，sizeInBytes 减去提取的总字节数drainedSizeInBytes。

```java
int clear() {
  lock.lock();
  try {
    int result = count;
    count = sizeInBytes = readPos = writePos = 0;
    Arrays.fill(elements, null);
    return result;
  } finally {
    lock.unlock();
  }
}
```

clear 方法，清空队列，这个方法比较简单，就是将所有东西清零，该方法在 Reporter 的 close 方法中会被使用。

## 4. BufferNextMessage

BufferNextMessage 是 ByteBoundedQueue.Consumer 的默认实现。

```java
final class BufferNextMessage implements ByteBoundedQueue.Consumer {
  private final Sender sender;
  private final int maxBytes;
  private final long timeoutNanos;
  private final List<byte[]> buffer = new LinkedList<>();

  long deadlineNanoTime;
  int sizeInBytes;
  boolean bufferFull;

  BufferNextMessage(Sender sender, int maxBytes, long timeoutNanos) {
    this.sender = sender;
    this.maxBytes = maxBytes;
    this.timeoutNanos = timeoutNanos;
  }
}
```

BufferNextMessage 中使用一个 LinkedList 来存储接收的 messages。

```java
@Override
public boolean accept(byte[] next) {
  buffer.add(next); // speculatively add to the buffer so we can size it
  int x = sender.messageSizeInBytes(buffer);
  int y = maxBytes;
  int includingNextVsMaxBytes = (x < y) ? -1 : ((x == y) ? 0 : 1);

  // If we can fit queued spans and the next into one message...
  if (includingNextVsMaxBytes <= 0) {
    sizeInBytes = x;

    if (includingNextVsMaxBytes == 0) {
      bufferFull = true;
    }
    return true;
  } else {
    buffer.remove(buffer.size() - 1);
    return false; // we couldn't fit the next message into this buffer
  }
}
```

accept方法，先将 message 放入buffer，然后调用 sender 的 messageSizeInBytes 方法统计下所有 buffer 消息的总字节数。includingNextVsMaxBytes 当 includingNextVsMaxBytes 大于该 buffer 的最大字节数 maxBytes，则将加入到 buffer 的 message 移除 。当includingNextVsMaxBytes 等于该 buffer 的最大字节数 maxBytes，则将该 buffer 标记为已满状态，即bufferFull = true。

```java
long remainingNanos() {
  if (buffer.isEmpty()) {
    deadlineNanoTime = System.nanoTime() + timeoutNanos;
  }
  return Math.max(deadlineNanoTime - System.nanoTime(), 0);
}

boolean isReady() {
  return bufferFull || remainingNanos() <= 0;
}
```

remainingNanos 方法中，当 buffer 为空，则重置一个 deadlineNanoTime，其值为当前系统时间加上 timeoutNanos。

isReady() 方法中，当系统时间超过这个时间或者 buffer 满了的时候， isReady 会返回 true，即 buffer 为准备就绪状态。

```java
List<byte[]> drain() {
  if (buffer.isEmpty()) return Collections.emptyList();
  ArrayList<byte[]> result = new ArrayList<>(buffer);
  buffer.clear();
  sizeInBytes = 0;
  bufferFull = false;
  deadlineNanoTime = 0;
  return result;
}
```

drain 方法返回 buffer 里的所有数据，并将 buffer 清空。

isReady 方法和 drain 方法，在 BoundedAsyncReporter 的 flush 方法中会被使用。

```java
void flush(BufferNextMessage bundler) {
	// ...
	if (!bundler.isReady() && !closed.get()) return;
	// ...
	List<byte[]> nextMessage = bundler.drain();
	// ...
	sender.sendSpans(nextMessage).execute();
}
```

因为 flush 是会一直不间断被调用，而这里先调用 bundler.isReady() 方法，当返回 true 后才取出所有堆积的消息，一起打包发送给Zipkin 提高效率。

再回过头来看看 BoundedAsyncReporter 里手动 flush 方法。

```java
@Override public final void flush() {
  flush(new BufferNextMessage(sender, messageMaxBytes, 0));
}
```

在我们分析完 BufferNextMessage 源代码后，我们很容易得出结论：这里构造 BufferNextMessage 传入的 timeoutNanos 为0，所以BufferNextMessage 的 isReady() 方法会永远返回 true。 这意味着每次我们手动调用 flush 方法，会立即将 queue 的数据用BufferNextMessage 填满，并打包发送给Zipkin，至于 queue 里剩下的数据，需要等到下次 FlushThread 循环执行 flush 方法的时候被发送。

至此，我们已经分析过 Tracer 和 Span 相关的源代码，这对我们后续看 Brave 和其他框架整合有很大帮助： Span/RealSpan Recorder Reporter/AsyncReporter/BoundedAsyncReporter BufferNextMessage ByteBoundedQueue。



## 参考

[Java分布式跟踪系统Zipkin（二）：Brave源码分析-Tracer和Span](http://blog.mozhu.org/2017/11/11/zipkin/zipkin-2.html)
