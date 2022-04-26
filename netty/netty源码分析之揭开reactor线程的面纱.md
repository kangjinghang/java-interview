## 前言

netty最核心的就是reactor线程，对应项目中使用广泛的NioEventLoop，那么NioEventLoop里面到底在干些什么事？netty是如何保证事件循环的高效轮询和任务的及时执行？又是如何来优雅地fix掉jdk的nio bug？带着这些疑问，本篇文章将庖丁解牛，带你逐步了解netty reactor线程的真相[源码基于4.1.68.Final]。

## I/O的四种模型

在学习Reactor模式之前，我们需要对“I/O的四种模型”以及“什么是I/O多路复用”进行简单的介绍，因为Reactor是一个使用了同步非阻塞的I/O多路复用机制的模式。

I/O 操作 主要分成两部分:

1. 数据准备，将数据加载到内核缓存
2. 将内核缓存中的数据加载到用户缓存

- **Synchronous blocking I/O**

  ![Synchronous_blocking](http://blog-1259650185.cosbj.myqcloud.com/img/202112/23/1640270574.png)

- **Synchronous non-blocking I/O**

  ![Synchronous-non-blocking](http://blog-1259650185.cosbj.myqcloud.com/img/202112/23/1640270630.png)

- **Asynchronous blocking I/O**

  ![Asynchronous-blocking](http://blog-1259650185.cosbj.myqcloud.com/img/202112/23/1640270660.png)

- **Asynchronous non-blocking I/O**

  ![Asynchronous-non-blocking](http://blog-1259650185.cosbj.myqcloud.com/img/202112/23/1640270716.png)

堵塞、非堵塞的区别是在于第一阶段，即数据准备阶段。无论是堵塞还是非堵塞，都是用应用主动找内核要数据，而read数据的过程是"堵塞"的，直到数据读取完。

同步、异步的区别在于第二阶段，若由请求者主动的去获取数据，则为同步操作，需要说明的是：read/write操作也是"堵塞"的，直到数据读取完。

若数据的read都由kernel内核完成了(在内核read数据的过程中，应用进程依旧可以执行其他的任务)，这就是异步操作。

换句话说，BIO里用户最关心"我要读"，NIO里用户最关心"我可以读了"，在AIO模型里用户更需要关注的是"读完了"。

NIO一个重要的特点是：socket主要的读、写、注册和接收函数，在等待就绪阶段都是非阻塞的，真正的I/O操作是同步阻塞的（消耗CPU但性能非常高）。
NIO是一种同步非阻塞的I/O模型，也是I/O多路复用的基础。

### I/O多路复用

I/O多路复用是指使用一个线程来检查多个文件描述符(Socket)的就绪状态，比如调用select和poll函数，传入多个文件描述符，如果有一个文件描述符就绪，则返回，否则阻塞直到超时。得到就绪状态后进行真正的操作可以在同一个线程里执行，也可以启动线程执行(比如使用线程池)。

一般情况下，I/O 复用机制需要事件分发器。 事件分发器的作用，将那些读写事件源分发给各读写事件的处理者。
涉及到事件分发器的两种模式称为：Reactor和Proactor。 Reactor模式是基于同步I/O的，而Proactor模式是和异步I/O相关的。本文主要介绍的就是 Reactor模式相关的知识。

## reactor 线程的启动

NioEventLoop的run方法是reactor线程的主体，在第一次添加任务的时候被启动。

> NioEventLoop 父类 SingleThreadEventExecutor 的execute方法

```java
// SingleThreadEventExecutor.java
@Override
public void execute(Runnable task) {
    ObjectUtil.checkNotNull(task, "task");
    execute(task, !(task instanceof LazyRunnable) && wakesUpForTask(task));
}

private void execute(Runnable task, boolean immediate) {
    boolean inEventLoop = inEventLoop();
    addTask(task);
    if (!inEventLoop) {
        startThread(); // 启动线程
        if (isShutdown()) {
            boolean reject = false;
            try {
                if (removeTask(task)) {
                    reject = true;
                }
            } catch (UnsupportedOperationException e) {
                // The task queue does not support removal so the best thing we can do is to just move on and
                // hope we will be able to pick-up the task before its completely terminated.
                // In worst case we will log on termination.
            }
            if (reject) {
                reject();
            }
        }
    }

    if (!addTaskWakesUp && immediate) {
        wakeup(inEventLoop);
    }
}
```

外部线程在往任务队列里面添加任务的时候执行 `startThread()` ，netty会判断reactor线程有没有被启动，如果没有被启动，那就启动线程再往任务队列里面添加任务。

> 启动 NioEventLoop 中的线程的方法在这里。

```java
// SingleThreadEventExecutor.java
private void startThread() {
    if (state == ST_NOT_STARTED) {  // 判断状态，没有启动时会启动
        if (STATE_UPDATER.compareAndSet(this, ST_NOT_STARTED, ST_STARTED)) { // 更新状态，未启动 -> 启动
            boolean success = false;
            try {
                doStartThread(); // 启动线程的动作
                success = true;
            } finally {
                if (!success) {
                    STATE_UPDATER.compareAndSet(this, ST_STARTED, ST_NOT_STARTED);
                }
            }
        }
    }
}
```

SingleThreadEventExecutor 在执行`doStartThread`的时候，会调用内部执行器`executor`的execute方法，将调用NioEventLoop的run（父类的模板方法）方法的过程封装成一个runnable塞到一个新建的线程中去执行。

```java
// SingleThreadEventExecutor.java
private void doStartThread() {
    ...
    // 这里的 executor 大家是不是有点熟悉的感觉，它就是一开始我们实例化 NioEventLoop 的时候传进来的 ThreadPerTaskExecutor 的实例。它是每次来一个任务，创建一个线程的那种 executor。
    // 一旦我们调用它的 execute 方法，它就会创建一个新的线程，所以这里终于会创建 Thread 实例
    executor.execute(new Runnable() {
        @Override
        public void run() {
            thread = Thread.currentThread(); // 看这里，将 “executor” 中创建的这个线程设置为 NioEventLoop 的线程！！
            ...
                SingleThreadEventExecutor.this.run(); //  具体的子类（NioEventLoop）去执行抽象的run()
            ...
        }
    }
}
```

该线程就是`executor`创建的，对应的就是netty的reactor线程实体。

默认情况下，`executor` 是`ThreadPerTaskExecutor`，`ThreadPerTaskExecutor` 在每次执行`execute` 方法的时候都会通过`DefaultThreadFactory`创建一个`FastThreadLocalThread`线程，而这个线程就是netty中的reactor线程实体，由这个线程去执行`run()`，不停的死循环就处理任务和事件。

````java
// ThreadPerTaskExecutor.java
public void execute(Runnable command) {
    threadFactory.newThread(command).start();
}
````

到此基本就分析清楚了。

至于为啥是 `ThreadPerTaskExecutor` 和 `DefaultThreadFactory`的组合来new一个`FastThreadLocalThread`呢，这里就不再详细描述，通过下面几段代码来简单说明。

> 标准的netty程序会调用到`NioEventLoopGroup`的父类`MultithreadEventExecutorGroup`的如下代码

```java
// MultithreadEventExecutorGroup.java
protected MultithreadEventExecutorGroup(int nThreads, Executor executor,
                                        EventExecutorChooserFactory chooserFactory, Object... args) {
    if (executor == null) {
        executor = new ThreadPerTaskExecutor(newDefaultThreadFactory());
    }
}
```

然后通过newChild的方式传递给`NioEventLoop`。

```java
// NioEventLoopGroup.java
@Override
protected EventLoop newChild(Executor executor, Object... args) throws Exception {
    SelectorProvider selectorProvider = (SelectorProvider) args[0];
    SelectStrategyFactory selectStrategyFactory = (SelectStrategyFactory) args[1];
    RejectedExecutionHandler rejectedExecutionHandler = (RejectedExecutionHandler) args[2];
    EventLoopTaskQueueFactory taskQueueFactory = null;
    EventLoopTaskQueueFactory tailTaskQueueFactory = null;

    int argsLength = args.length;
    if (argsLength > 3) {
        taskQueueFactory = (EventLoopTaskQueueFactory) args[3];
    }
    if (argsLength > 4) {
        tailTaskQueueFactory = (EventLoopTaskQueueFactory) args[4];
    }
    return new NioEventLoop(this, executor, selectorProvider,
            selectStrategyFactory.newSelectStrategy(),
            rejectedExecutionHandler, taskQueueFactory, tailTaskQueueFactory);
}
```

关于reactor线程的创建和启动就先讲这么多，我们总结一下：netty的reactor线程在添加一个任务的时候被创建，该线程实体为 `FastThreadLocalThread`(这玩意以后会开篇文章重点讲讲)，最后线程执行主体为`NioEventLoop`的`run`方法（因为在MultithreadEventExecutorGroup 中 newChild 返回的是EventLoop 就是 成员变量EventExecutor[] children的中的每一个元素）。

## reactor 线程的执行

那么下面我们就重点剖析一下 `NioEventLoop` 的run方法。

```java
// NioEventLoop.java
@Override
protected void run() {
    int selectCnt = 0;
    for (;;) {
        try {
            int strategy;
            try {
                strategy = selectStrategy.calculateStrategy(selectNowSupplier, hasTasks());
                switch (strategy) {
                // 如果 taskQueue 不为空，也就是 hasTasks() 返回 true，那么执行一次 selectNow()，该方法不会阻塞
                case SelectStrategy.CONTINUE: 
                    continue;

                case SelectStrategy.BUSY_WAIT:
                    // fall-through to SELECT since the busy-wait is not supported with NIO
								// 这个很好理解，就是按照是否有任务在排队来决定是否可以进行阻塞
                case SelectStrategy.SELECT:
                    long curDeadlineNanos = nextScheduledTaskDeadlineNanos();
                    if (curDeadlineNanos == -1L) {
                        curDeadlineNanos = NONE; // nothing on the calendar
                    }
                    nextWakeupNanos.set(curDeadlineNanos);
                    try {
                        if (!hasTasks()) {
                            strategy = select(curDeadlineNanos);
                        }
                    } finally {
                        // This update is just to help block unnecessary selector wakeups
                        // so use of lazySet is ok (no race condition)
                        nextWakeupNanos.lazySet(AWAKE);
                    }
                    // fall through
                default:
                }
            } catch (IOException e) {
                // If we receive an IOException here its because the Selector is messed up. Let's rebuild
                // the selector and retry. https://github.com/netty/netty/issues/8566
                rebuildSelector0();
                selectCnt = 0;
                handleLoopException(e);
                continue;
            }

            selectCnt++;
            cancelledKeys = 0;
            needsToSelectAgain = false;
            final int ioRatio = this.ioRatio; // 默认地，ioRatio 的值是 50
            boolean ranTasks;
            if (ioRatio == 100) { 
              	// 如果 ioRatio 设置为 100，那么先执行 IO 操作，然后在 finally 块中执行 taskQueue 中的任务
                try {
                    if (strategy > 0) {
                      	// 1. 执行 IO 操作。因为前面 select 以后，可能有些 channel 是需要处理的。
                        processSelectedKeys(); 
                    }
                } finally {
                    // Ensure we always run tasks.
                  	// 2. 执行非 IO 任务，也就是 taskQueue 中的任务
                    ranTasks = runAllTasks();
                }
            } else if (strategy > 0) {
              	// 如果 ioRatio 不是 100，那么根据 IO 操作耗时，限制非 IO 操作耗时
                final long ioStartTime = System.nanoTime();
                try {
                  	// 执行 IO 操作
                    processSelectedKeys();
                } finally {
                 	  // 根据 IO 操作消耗的时间，计算执行非 IO 操作（runAllTasks）可以用多少时间.
                    // Ensure we always run tasks.
                    final long ioTime = System.nanoTime() - ioStartTime;
                    // 按ioRatio和ioTime折算非IO的task执行时间
                    ranTasks = runAllTasks(ioTime * (100 - ioRatio) / ioRatio);
                }
            } else {
                ranTasks = runAllTasks(0); // This will run the minimum number of tasks
            }

            if (ranTasks || strategy > 0) {
                if (selectCnt > MIN_PREMATURE_SELECTOR_RETURNS && logger.isDebugEnabled()) {
                    logger.debug("Selector.select() returned prematurely {} times in a row for Selector {}.",
                            selectCnt - 1, selector);
                }
                selectCnt = 0;
            } else if (unexpectedSelectorWakeup(selectCnt)) { // Unexpected wakeup (unusual case)
                selectCnt = 0;
            }
        } catch (CancelledKeyException e) {
						...
        } finally {
						...
        }
    }
}
```

我们抽取出主干，reactor线程做的事情其实很简单，用下面一幅图就可以说明。

<img src="http://blog-1259650185.cosbj.myqcloud.com/img/202111/15/1636906514" alt="img" style="zoom: 33%;" />

reactor线程大概做的事情分为对三个步骤不断循环。

> 1..首先轮询注册到reactor线程对用的selector上的所有的channel的IO事件。

```java
// NioEventLoop.java
select(curDeadlineNanos);
```

> 2.处理产生网络IO事件的channel。

```java
// NioEventLoop.java
processSelectedKeys();
```

> 3.处理任务队列

```java
// NioEventLoop.java
runAllTasks(...);
```

下面对每个步骤详细说明。

### select操作

```java
// SelectStrategy.java
/**
 * Select strategy interface.
 *
 * 提供控制选择循环行为的能力。例如，如果有立刻要被处理的事件，一个阻塞的select操作可能被延迟或者跳过
 */
public interface SelectStrategy {

    /**
     * 表示下一步应该是阻塞的select操作
     */
    int SELECT = -1;
    /**
     * 表示应该重试IO循环，下一步是非阻塞的select操作
     */
    int CONTINUE = -2;
    /**
     * 表示IO循环应该用非阻塞的方式去拉取新的事件
     */
    int BUSY_WAIT = -3;

    /**
     * {@link SelectStrategy}可以被用来指示一个潜在的select调用结果
     * @param selectSupplier The supplier with the result of a select result.
     * @param hasTasks true if tasks are waiting to be processed.如果有任务等待去被执行
     * @return 如果返回{@link #SELECT}，说明下一步操作应该是阻塞的select；如果返回{@link #CONTINUE}，说明
     *         下一步操作应该不应该是select，而应该是继续跳回IO循环并且重试；并且，如果value >= 0，说明有selectKey需要被处理
     */
    int calculateStrategy(IntSupplier selectSupplier, boolean hasTasks) throws Exception;
}
```

```java
// NioEventLoop.java
int strategy;
try {
    strategy = selectStrategy.calculateStrategy(selectNowSupplier, hasTasks());
    switch (strategy) {
    // 如果 taskQueue 不为空，也就是 hasTasks() 返回 true，那么执行一次 selectNow()，该方法不会阻塞
    case SelectStrategy.CONTINUE:
        continue;

    case SelectStrategy.BUSY_WAIT:
        // fall-through to SELECT since the busy-wait is not supported with NIO
	  // 这个很好理解，就是按照是否有任务在排队来决定是否可以进行阻塞
    case SelectStrategy.SELECT:
        // 第一个任务的到期时间
        long curDeadlineNanos = nextScheduledTaskDeadlineNanos();
        if (curDeadlineNanos == -1L) {
            curDeadlineNanos = NONE; // nothing on the calendar
        }
        nextWakeupNanos.set(curDeadlineNanos);
        try {
            if (!hasTasks()) {
                strategy = select(curDeadlineNanos);
            }
        } finally {
            nextWakeupNanos.lazySet(AWAKE);
        }
    default:
    }
} 

private int select(long deadlineNanos) throws IOException {
    if (deadlineNanos == NONE) {
        return selector.select();
    }
    // Timeout will only be 0 if deadline is within 5 microsecs
    long timeoutMillis = deadlineToDelayNanos(deadlineNanos + 995000L) / 1000000L;
    return timeoutMillis <= 0 ? selector.selectNow() : selector.select(timeoutMillis);
}
```

```java
// DefaultSelectStrategy.java
final class DefaultSelectStrategy implements SelectStrategy {
    static final SelectStrategy INSTANCE = new DefaultSelectStrategy();

    private DefaultSelectStrategy() { }

    @Override
    public int calculateStrategy(IntSupplier selectSupplier, boolean hasTasks) throws Exception {
        // 如果有正在或等待执行的任务，则执行一次非阻塞的selectNow()，否则返回-1
        return hasTasks ? selectSupplier.get() : SelectStrategy.SELECT;
    }
}
```

上面这段代码是 NioEventLoop 的核心，这里介绍两点：

1. 首先，会根据 hasTasks() 的结果来决定是执行 selectNow() 还是 select(oldWakenUp)，这个应该好理解。如果有任务正在等待，那么应该使用无阻塞的 selectNow()，如果没有任务在等待，那么就可以使用带阻塞的 select 操作。
2. ioRatio 控制 IO 操作所占的时间比重：
   - 如果设置为 100%，那么先执行 IO 操作，然后再执行任务队列中的任务。
   - 如果不是 100%，那么先执行 IO 操作，然后执行 taskQueue 中的任务，但是需要控制执行任务的总时间。也就是说，非 IO 操作可以占用的时间，通过 ioRatio 以及这次 IO 操作耗时计算得出。

根据`selectStrategy.calculateStrategy(selectNowSupplier, hasTasks())`的返回值来进行下一步的操作。`selectNowSupplier`就是非阻塞的`selectNow()`操作的返回值，`hasTasks()`为是否有正在或等待执行的任务，返回-1代表下一步应该是阻塞的`select()`操作，-2则代表应该重新进行IO循环和非阻塞的`select()`操作，-3与-2的逻辑相同，如果是其他值说明，说明有selectedKey需要被处理，继续进行后续的操作了。

额外说明，netty里面定时任务队列是按照到期时间从小到大进行排序， `nextScheduledTaskDeadlineNanos`方法即取出第一个定时任务的到期时间，否则的话返回-1。


```java
// AbstractScheduledEventExecutor.java
protected final long nextScheduledTaskDeadlineNanos() {
    ScheduledFutureTask<?> scheduledTask = peekScheduledTask();
    return scheduledTask != null ? scheduledTask.deadlineNanos() : -1;
}
```

下面就各种情况，详细的说明一下：

> 如果strategy是-1

得到第一个定时任务的到期时间后设置为epoll边缘触发的唤醒时间，然后也用这个时间作为参数去执行`select(long deadlineNanos)`方法。

```java
// NioEventLoop.java
private int select(long deadlineNanos) throws IOException {
    if (deadlineNanos == NONE) {
        return selector.select();
    }
    long timeoutMillis = deadlineToDelayNanos(deadlineNanos + 995000L) / 1000000L;
    return timeoutMillis <= 0 ? selector.selectNow() : selector.select(timeoutMillis);
}
```

如果定时任务的截止时间为-1，就执行阻塞`select()`操作（直到有需要被处理的事件才返回），如果发现当前的定时任务队列中第一个定时任务的截止事件快到了(<=5微秒)，就直接执行非阻塞的`selectNow()`操作，会立即返回，否则的话执行超时时间为`timeoutMillis`的阻塞`select()`操作，直到到达第一个定时任务的截止时间。

这里，我们可以问自己一个问题，如果第一个定时任务的延迟非常长，比如一个小时，那么有没有可能线程一直阻塞在select操作，当然有可能！但是，注意一下`select(curDeadlineNanos);`的执行条件，只有任务队列中为空时才会执行。

> 如果strategy是-2，会再次进行IO循环。
>
> 如果strategy是-3，因为NIO不支持忙等待，所以会和-1的操作完全相同。
>
> 如果strategy是其他值，则什么都不做，进行后续的处理。



> 额外说明，外部线程调用execute方法添加任务。

```java
// NioEventLoop.java
@Override
public void execute(Runnable task) { 
    ...
    wakeup(inEventLoop); // inEventLoop为false
    ...
}
```

> 调用wakeup方法唤醒selector阻塞，被阻塞的select() 或 select(long) 会立即返回。

```java
// NioEventLoop.java
protected void wakeup(boolean inEventLoop) {
    if (!inEventLoop && wakenUp.compareAndSet(false, true)) {
        selector.wakeup();
    }
}
```

可以看到，在外部线程添加任务的时候，会调用wakeup方法来唤醒 `selector.select(timeoutMillis)`。



> 解决jdk的nio bug

关于该bug的描述见 [http://bugs.java.com/bugdatabase/view_bug.do?bug_id=6595055)](https://links.jianshu.com/go?to=http%3A%2F%2Fbugs.java.com%2Fbugdatabase%2Fview_bug.do%3Fbug_id%3D6595055)

该bug会导致Selector一直空轮询，最终导致cpu 100%，nio server不可用，严格意义上来说，netty没有解决jdk的bug，而是通过一种方式来巧妙地避开了这个bug，具体做法如下：

```java
// NioEventLoop.java
if (ranTasks || strategy > 0) {
	...
} else if (unexpectedSelectorWakeup(selectCnt)) { // Unexpected wakeup (unusual case)
    selectCnt = 0;
}

private boolean unexpectedSelectorWakeup(int selectCnt) {
    if (Thread.interrupted()) {
        if (logger.isDebugEnabled()) {
            logger.debug("Selector.select() returned prematurely because " +
                    "Thread.currentThread().interrupt() was called. Use " +
                    "NioEventLoop.shutdownGracefully() to shutdown the NioEventLoop.");
        }
        return true;
    }
    if (SELECTOR_AUTO_REBUILD_THRESHOLD > 0 &&
            selectCnt >= SELECTOR_AUTO_REBUILD_THRESHOLD) {
        logger.warn("Selector.select() returned prematurely {} times in a row; rebuilding Selector {}.",
                selectCnt, selector);
        rebuildSelector();
        return true;
    }
    return false;
}
```

当select的次数超过一个阀值的时候，默认是512，可能触发了jdk的空轮询bug，就开始重建selector。

下面我们简单描述一下netty 通过`rebuildSelector`来fix空轮询bug的过程，`rebuildSelector`的操作其实很简单：new一个新的selector，将之前注册到老的selector上的的channel重新转移到新的selector上。我们抽取完主要代码之后的骨架如下：

```java
// NioEventLoop.java
public void rebuildSelector() {
    final Selector oldSelector = selector;
    final Selector newSelector;
    newSelector = openSelector();

    int nChannels = 0;
     try {
        for (;;) {
                for (SelectionKey key: oldSelector.keys()) {
                    Object a = key.attachment();
                     if (!key.isValid() || key.channel().keyFor(newSelector) != null) {
                         continue;
                     }
                     int interestOps = key.interestOps();
                     key.cancel();
                     SelectionKey newKey = key.channel().register(newSelector, interestOps, a);
                     if (a instanceof AbstractNioChannel) {
                         ((AbstractNioChannel) a).selectionKey = newKey;
                      }
                     nChannels ++;
                }
                break;
        }
    } catch (ConcurrentModificationException e) {
        // Probably due to concurrent modification of the key set.
        continue;
    }
    selector = newSelector;
    oldSelector.close();
}
```

首先，通过`openSelector()`方法创建一个新的selector，然后执行一个死循环，只要执行过程中出现过一次并发修改selectionKeys异常，就重新开始转移。

具体的转移步骤为：

1. 拿到有效的key
2. 取消该key在旧的selector上的事件注册
3. 将该key对应的channel注册到新的selector上
4. 重新绑定channel和新的key的关系

转移完成之后，就可以将原有的selector废弃，后面所有的轮询都是在新的selector进行。

最后，我们总结reactor线程select步骤做的事情：不断地轮询是否有IO事件发生，保证了netty的任务队列中的任务得到有效执行，轮询过程顺带用一个计数器避开了了JDK空轮询的bug，过程清晰明了。

### process selected keys操作

我们进入到reactor线程的 `run` 方法，找到处理IO事件的代码，如下：

```java
// NioEventLoop.java
processSelectedKeys();

private void processSelectedKeys() {
    if (selectedKeys != null) {
        // 不用 JDK 的 selector.selectKeys() ，性能更好（1%-2%），垃圾回收更少
        processSelectedKeysOptimized();
    } else {
        processSelectedKeysPlain(selector.selectedKeys());
    }
}
```

我们发现处理IO事件，netty有两种选择，从名字上看，一种是处理优化过的selectedKeys，一种是正常的处理。processSelectedKeys方法，会根据有没有开启优化来选择不同的遍历方式，优化过的`Selector`由于使用的是数组，效率更高。

我们对优化过的selectedKeys的处理稍微展开一下，看看netty是如何优化的，我们查看 `selectedKeys` 被引用过的地方，有如下代码：

```java
// NioEventLoop.java
private SelectedSelectionKeySet selectedKeys;

// 构造器初始化的时候被调用
private SelectorTuple openSelector() {
    final Selector unwrappedSelector;
    try {
        unwrappedSelector = provider.openSelector();
    } catch (IOException e) {
        throw new ChannelException("failed to open a new selector", e);
    }  
    //...
    final SelectedSelectionKeySet selectedKeySet = new SelectedSelectionKeySet();
    // selectorImplClass -> sun.nio.ch.SelectorImpl
    Field selectedKeysField = selectorImplClass.getDeclaredField("selectedKeys");
    Field publicSelectedKeysField = selectorImplClass.getDeclaredField("publicSelectedKeys");
    selectedKeysField.setAccessible(true);
    publicSelectedKeysField.setAccessible(true);
    selectedKeysField.set(selector, selectedKeySet);
    publicSelectedKeysField.set(selector, selectedKeySet);
    //...
    selectedKeys = selectedKeySet;
}
```

首先，selectedKeys是一个 `SelectedSelectionKeySet` 类对象，在`NioEventLoop` 的 `openSelector` 方法中创建，之后就通过反射将selectedKeys与 `sun.nio.ch.SelectorImpl` 中的两个field（selectedKeys、publicSelectedKeys）绑定，就是说把netty优化过的`SelectedSelectionKeySet`设置给了`unwrappedSelector`的 selectedKeys、publicSelectedKeys 两个成员变量。	

`sun.nio.ch.SelectorImpl` 中我们可以看到，这两个field其实是两个HashSet。

```java
// sun.nio.ch.SelectorImpl.java
// Public views of the key sets
private Set<SelectionKey> publicKeys;             // Immutable
private Set<SelectionKey> publicSelectedKeys;     // Removal allowed, but not addition
protected SelectorImpl(SelectorProvider sp) {
    super(sp);
    keys = new HashSet<SelectionKey>();
    selectedKeys = new HashSet<SelectionKey>();
    if (Util.atBugLevel("1.4")) {
        publicKeys = keys;
        publicSelectedKeys = selectedKeys;
    } else {
        publicKeys = Collections.unmodifiableSet(keys);
        publicSelectedKeys = Util.ungrowableSet(selectedKeys);
    }
}
```

selector在调用`select()`族方法的时候，如果有IO事件发生，就会往里面的两个field中塞相应的`selectionKey`(具体怎么塞有待研究)，即相当于往一个hashSet中add元素，既然netty通过反射将jdk中的两个field替换掉，那我们就应该意识到是不是netty自定义的`SelectedSelectionKeySet`在`add`方法做了某些优化呢？

带着这个疑问，我们进入到 `SelectedSelectionKeySet` 类中探个究竟。

```java
// SelectedSelectionKeySet.java
final class SelectedSelectionKeySet extends AbstractSet<SelectionKey> {

    SelectionKey[] keys;
    int size;

    SelectedSelectionKeySet() {
        keys = new SelectionKey[1024];
    }

    @Override
    public boolean add(SelectionKey o) {
        if (o == null) {
            return false;
        }

        keys[size++] = o;
        if (size == keys.length) {
            increaseCapacity();
        }

        return true;
    }

    @Override
    public boolean remove(Object o) {
        return false;
    }

    @Override
    public boolean contains(Object o) {
        return false;
    }

    @Override
    public int size() {
        return size;
    }

    @Override
    public Iterator<SelectionKey> iterator() {
        return new Iterator<SelectionKey>() {
            private int idx;

            @Override
            public boolean hasNext() {
                return idx < size;
            }

            @Override
            public SelectionKey next() {
                if (!hasNext()) {
                    throw new NoSuchElementException();
                }
                return keys[idx++];
            }

            @Override
            public void remove() {
                throw new UnsupportedOperationException();
            }
        };
    }

    void reset() {
        reset(0);
    }

    void reset(int start) {
        Arrays.fill(keys, start, size, null);
        size = 0;
    }

    private void increaseCapacity() {
        SelectionKey[] newKeys = new SelectionKey[keys.length << 1];
        System.arraycopy(keys, 0, newKeys, 0, size);
        keys = newKeys;
    }
}
```

该类继承了 `AbstractSet`，内部很简单，使用数组代替原`Selector`的中的HashSet，提高性能。数组默认大小为1024，不够用时容量*2。

我们可以看到，待程序跑过一段时间，等数组的长度足够长，每次在轮询到nio事件的时候，netty只需要O(1)的时间复杂度就能将 `SelectionKey` 塞到 set中去，而JDK底层使用的hashSet需要O(lgn)的时间复杂度。

关于netty对`SelectionKeySet`的优化我们暂时就跟这么多，下面继续跟netty对IO事件的处理，到`processSelectedKeysOptimized`。

```java
// NioEventLoop.java
private void processSelectedKeysOptimized() {
    for (int i = 0; i < selectedKeys.size; ++i) {
        final SelectionKey k = selectedKeys.keys[i];
        // null out entry in the array to allow to have it GC'ed once the Channel close
        // See https://github.com/netty/netty/issues/2363
        selectedKeys.keys[i] = null;
        // 呼应与 channel 的 register 中的 this ：
        // 例如：selectKey = javaChannel().register(eventLoop().unwrappedSelector(), 0, this);
        final Object a = k.attachment(); // attachment 就是 serverSocketChannel

        if (a instanceof AbstractNioChannel) {
            processSelectedKey(k, (AbstractNioChannel) a);
        } else {
            @SuppressWarnings("unchecked")
            NioTask<SelectableChannel> task = (NioTask<SelectableChannel>) a;
            processSelectedKey(k, task);
        }

        if (needsToSelectAgain) {
            // null out entries in the array to allow to have it GC'ed once the Channel close
            // See https://github.com/netty/netty/issues/2363
            selectedKeys.reset(i + 1);

            selectAgain();
            i = -1;
        }
    }
}
```

我们可以将该过程分为以下三个步骤：

> 1.取出IO事件以及对应的netty channel类

这里其实也能体会到优化过的 `SelectedSelectionKeySet` 的好处，遍历的时候遍历的是数组，相对JDK原生的`HashSet`效率有所提高。

拿到当前SelectionKey之后，将`selectedKeys[i]`置为null，这里简单解释一下这么做的理由：想象一下这种场景，假设一个NioEventLoop平均每次轮询出N个IO事件，高峰期轮询出3\*N个事件，那么`selectedKeys`的物理长度要大于等于3*N，如果每次处理这些key，不置`selectedKeys[i]`为空，那么高峰期一过，这些保存在数组尾部的`selectedKeys[i]`对应的`SelectionKey`将一直无法被回收，`SelectionKey`对应的对象可能不大，但是要知道，它可是有attachment的，这里的attachment具体是什么下面会讲到，但是有一点我们必须清楚，attachment可能很大，这样一来，这些元素是GC root可达的，很容易造成gc不掉，内存泄漏就发生了。



> 2.处理该channel

拿到对应的attachment之后，netty做了如下判断：

```java
// NioEventLoop.java
if (a instanceof AbstractNioChannel) {
    processSelectedKey(k, (AbstractNioChannel) a);
} 
```

源码读到这，我们需要思考为啥会有这么一条判断，凭什么说attachment可能会是 `AbstractNioChannel`对象？

我们的思路应该是找到底层selector, 然后在selector调用register方法的时候，看一下注册到selector上的对象到底是什么鬼，我们使用intellij的全局搜索引用功能，最终在 `AbstractNioChannel`中搜索到如下方法

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
						...
        }
    }
}
```

`javaChannel()` 返回netty类`AbstractChannel`对应的JDK底层channel对象。

```java
// AbstractNioChannel.java
protected SelectableChannel javaChannel() {
    return ch;
}
```

我们查看到SelectableChannel方法，结合netty的 `doRegister()` 方法，我们不难推论出，netty的轮询注册机制其实是将`AbstractNioChannel`内部的JDK类`SelectableChannel`对象注册到JDK类`Selctor`对象上去，并且将netty的`AbstractNioChannel`作为`SelectableChannel`对象的一个attachment附属上去，这样再JDK轮询出某条`SelectableChannel`有IO事件发生时，就可以直接取出`AbstractNioChannel`进行后续操作，完成了netty的`AbstractNioChannel`与JDK的`SelectableChannel`和`Selctor`的关联。

下面是JDK中的register方法：

```java
     //*
     //* @param  sel
     //*         The selector with which this channel is to be registered
     //*
     //* @param  ops
     //*         The interest set for the resulting key
     //*
     //* @param  att
     //*         The attachment for the resulting key; may be <tt>null</tt>
public abstract SelectionKey register(Selector sel, int ops, Object att)
        throws ClosedChannelException;
```



由于篇幅原因，详细的 `processSelectedKey(SelectionKey k, AbstractNioChannel ch)` 过程我们单独写一篇文章来详细展开，这里就简单说一下

1. 对于boss NioEventLoop来说，轮询到的是基本上就是连接事件，后续的事情就通过他的pipeline将连接扔给一个worker NioEventLoop处理。
2. 对于worker NioEventLoop来说，轮询到的基本上都是io读写事件，后续的事情就是通过他的pipeline将读取到的字节流传递给每个channelHandler来处理。

上面处理attachment的时候，还有个else分支，我们也来分析一下。

else部分的代码如下：

```java
NioTask<SelectableChannel> task = (NioTask<SelectableChannel>) a;
processSelectedKey(k, task);
```

说明注册到selctor上的attachment还有另外一中类型，就是 `NioTask`，NioTask主要是用于当一个 `SelectableChannel` 注册到selector的时候，执行一些任务。

NioTask的定义：

```java
// NioTask.java
public interface NioTask<C extends SelectableChannel> {
    void channelReady(C ch, SelectionKey key) throws Exception;
    void channelUnregistered(C ch, Throwable cause) throws Exception;
}
```

由于`NioTask` 在netty内部没有使用的地方，这里不过多展开。



> 3.判断是否该再来次轮询

```java
// NioEventLoop.java
if (needsToSelectAgain) {
    selectedKeys.reset(i + 1);

    selectAgain();
    i = -1;
}
```

我们回忆一下netty的reactor线程经历前两个步骤，分别是抓取产生过的IO事件以及处理IO事件，每次在抓到IO事件之后，都会将 needsToSelectAgain 重置为false，那么什么时候needsToSelectAgain会重新被设置成true呢？

还是和前面一样的思路，我们使用intellij来帮助我们查看needsToSelectAgain被使用的地方，在NioEventLoop类中，只有下面一处将needsToSelectAgain设置为true

```java
// NioEventLoop.java
void cancel(SelectionKey key) {
    // 没有特殊情况（配置so linger），下面这个cancel：其实没有"执行"，因为在关闭channel的时候执行过了
    key.cancel();
    cancelledKeys ++;
    // 下面是优化：当处理一批事件时，发现很多连接都断了（默认256）
    // 这个时候后面的事件可能就失效了，所以不妨select again下。
    if (cancelledKeys >= CLEANUP_INTERVAL) {
        cancelledKeys = 0;
        needsToSelectAgain = true;
    }
}
```

继续查看 `cancel` 函数被调用的地方

```java
// AbstractChannel.java
@Override
protected void doDeregister() throws Exception {
    eventLoop().cancel(selectionKey());
}
```

不难看出，在channel从selector上移除的时候，调用cancel方法将key取消，并且当被去掉的key到达 `CLEANUP_INTERVAL` 的时候，设置needsToSelectAgain为true，`CLEANUP_INTERVAL`默认值为256。

```java
// NioEventLoop.java
private static final int CLEANUP_INTERVAL = 256;
```

也就是说，对于每个NioEventLoop而言，每隔256个channel从selector上移除的时候，就标记 needsToSelectAgain 为true，我们还是跳回到上面这段代码。

```java
// NioEventLoop.java
if (needsToSelectAgain) {
  	 // 通过 selectedKeys.keys[i] = null; 和 下面这条语句，将selectedKeys清空
    selectedKeys.reset(i + 1);
		// 重新select，这样selectedKeys就会被重新设置上值
    selectAgain();
    i = -1;
}

private void selectAgain() {
    needsToSelectAgain = false;
    try {
        selector.selectNow();
    } catch (Throwable t) {
        logger.warn("Failed to update SelectionKeys.", t);
    }
}
```

每满256次，就会进入到if的代码块，首先，将selectedKeys的内部数组全部清空，方便被jvm垃圾回收，然后重新调用`selectAgain`重新填装一下 `selectionKey`。netty这么做的目的我想应该是每隔256次channel断线，重新清理一下selectionKey，保证现存的SelectionKey及时有效。

到这里，我们初次阅读源码的时候对reactor的第二个步骤的了解已经足够了。总结一下：netty的reactor线程第二步做的事情为处理IO事件，netty使用数组替换掉JDK原生的HashSet来保证IO事件的高效处理，每个SelectionKey上绑定了netty类`AbstractChannel`对象作为attachment，在处理每个SelectionKey的时候，就可以找到`AbstractChannel`，然后通过pipeline的方式将处理串行到ChannelHandler，回调到我们定义的handler。

### run tasks操作

#### netty中的task的常见使用场景

我们取三种典型的task使用场景来分析。

##### 一. 用户自定义普通任务

```java
ctx.channel().eventLoop().execute(new Runnable() {
    @Override
    public void run() {
        //...
    }
});
```

我们跟进`execute`方法，看重点：

```java
// SingleThreadEventExecutor.java
@Override
public void execute(Runnable task) {
    //...
    addTask(task);
    //...
}

protected void addTask(Runnable task) {
    // ...
    if (!offerTask(task)) {
        reject(task);
    }
}

final boolean offerTask(Runnable task) {
    // ...
    return taskQueue.offer(task);
}
```

`execute`方法调用 `addTask`方法，然后调用`offerTask`方法，如果offer失败，那就调用`reject`方法，通过默认的 `RejectedExecutionHandler` 直接抛出异常。

跟到`offerTask`方法，基本上task就落地了，netty内部使用一个`taskQueue`将task保存起来，那么这个`taskQueue`又是何方神圣？

我们查看 `taskQueue` 定义的地方和被初始化的地方。

```java
// SingleThreadEventExecutor.java
private final Queue<Runnable> taskQueue;

taskQueue = newTaskQueue(this.maxPendingTasks);

protected Queue<Runnable> newTaskQueue(int maxPendingTasks) {
    return new LinkedBlockingQueue<Runnable>(maxPendingTasks);
}

// NioEventLoop.java
@Override
protected Queue<Runnable> newTaskQueue(int maxPendingTasks) {
    return newTaskQueue0(maxPendingTasks);
}

private static Queue<Runnable> newTaskQueue0(int maxPendingTasks) {
    // This event loop never calls takeTask()
    return maxPendingTasks == Integer.MAX_VALUE ? PlatformDependent.<Runnable>newMpscQueue()
            : PlatformDependent.<Runnable>newMpscQueue(maxPendingTasks);
}
```

我们发现 `taskQueue`在NioEventLoop中默认是mpsc队列，mpsc队列，即多生产者单消费者队列，netty使用mpsc，方便的将外部线程的task聚集，在reactor线程内部用单线程来串行执行，我们可以借鉴netty的任务执行模式来处理类似多线程数据上报，定时聚合的应用。

在本节讨论的任务场景中，所有代码的执行都是在reactor线程中的，所以，所有调用 `inEventLoop()` 的地方都返回true，既然都是在reactor线程中执行，那么其实这里的mpsc队列其实没有发挥真正的作用，mpsc大显身手的地方其实在第二种场景。

##### 二. 非当前reactor线程调用channel的各种方法

```java
// non reactor thread
channel.write(...)
```

上面一种情况在push系统中比较常见，一般在业务线程里面，**根据用户的标识，找到对应的channel引用，然后调用write类方法向该用户推送消息，就会进入到这种场景**。

关于channel.write()类方法的调用链，后面会单独拉出一篇文章来深入剖析，这里，我们只需要知道，最终write方法串至以下方法。

```java
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
        final WriteTask task = WriteTask.newInstance(next, m, promise, flush);
        if (!safeExecute(executor, task, promise, m, !flush)) {
            task.cancel();
        }
    }
}
```

外部线程在调用`write`的时候，`executor.inEventLoop()`会返回false，直接进入到else分支，将write封装成一个`WriteTask`， 然后调用 `safeExecute`方法。

```java
private static boolean safeExecute(EventExecutor executor, Runnable runnable,
        ChannelPromise promise, Object msg, boolean lazy) {
    try {
        if (lazy && executor instanceof AbstractEventExecutor) {
            ((AbstractEventExecutor) executor).lazyExecute(runnable);
        } else {
            executor.execute(runnable);
        }
        return true;
    } catch (Throwable cause) {
        ...
        return false;
    }
}
```

接下来的调用链就进入到第一种场景了，但是和第一种场景有个明显的区别就是，**第一种场景的调用链的发起线程是reactor线程**，**第二种场景的调用链的发起线程是用户线程**，用户线程可能会有很多个，显然多个线程并发写`taskQueue`可能出现线程同步问题，于是，这种场景下，netty的mpsc queue就有了用武之地。

##### 三. 用户自定义定时任务

```java
ctx.channel().eventLoop().schedule(new Runnable() {
    @Override
    public void run() {

    }
}, 60, TimeUnit.SECONDS);
```

第三种场景就是定时任务逻辑了，用的最多的便是如上方法：在一定时间之后执行任务。

我们跟进`schedule`方法：

```java
// AbstractScheduledEventExecutor.java
@Override
public ScheduledFuture<?> schedule(Runnable command, long delay, TimeUnit unit) {
    ...

    return schedule(new ScheduledFutureTask<Void>(
            this,
            command,
            deadlineNanos(unit.toNanos(delay))));
}
```

通过 `ScheduledFutureTask`, 将用户自定义任务再次包装成一个netty内部的任务。

```java
// AbstractScheduledEventExecutor.java
private <V> ScheduledFuture<V> schedule(final ScheduledFutureTask<V> task) {
    if (inEventLoop()) {
      	// 场景一
        scheduleFromEventLoop(task);
    } else {
        ...
    }

    return task;
}
```

到了这里，我们有点似曾相识，在非定时任务的处理中，netty通过一个mpsc队列将任务落地，这里，是否也有一个类似的队列来承载这类定时任务呢？带着这个疑问，我们继续向前。

```java
// AbstractScheduledEventExecutor.java
PriorityQueue<ScheduledFutureTask<?>> scheduledTaskQueue() {
    if (scheduledTaskQueue == null) {
        scheduledTaskQueue = new DefaultPriorityQueue<ScheduledFutureTask<?>>(
                SCHEDULED_FUTURE_TASK_COMPARATOR,
                // Use same initial capacity as java.util.PriorityQueue
                11);
    }
    return scheduledTaskQueue;
}
```

果不其然，`scheduledTaskQueue()` 方法，会返回一个优先级队列，然后调用 `add` 方法将定时任务加入到队列中去，但是，这里为什么要使用优先级队列，而不需要考虑多线程的并发？

因为我们现在讨论的场景，调用链的发起方是reactor线程，不会存在多线程并发这些问题。

但是，万一有的用户在reactor之外执行定时任务呢？虽然这类场景很少见，但是netty作为一个无比健壮的高性能io框架，必须要考虑到这种情况。

对此，netty的处理是，如果是在外部线程调用schedule，netty将添加定时任务的逻辑封装成一个普通的task，这个task的任务是添加[添加定时任务]的任务，而不是添加定时任务，其实也就是第二种场景，这样，将任务加到mpsc队列中去。相当于，`AbstractScheduledEventExecutor`中有一个定时任务队列scheduledTaskQueue，子类`SingleThreadEventExecutor`中有个mpsc队列`taskQueue`。

```java
// AbstractScheduledEventExecutor.java
private <V> ScheduledFuture<V> schedule(final ScheduledFutureTask<V> task) {
    if (inEventLoop()) { 
      	// 场景一：调用链的发起方是reactor线程，将定时任务加入到优先级队列中去
        scheduleFromEventLoop(task);
    } else { 
      	// 场景二：进一步封装任务
        final long deadlineNanos = task.deadlineNanos();
        // task will add itself to scheduled task queue when run if not expire
        if (beforeScheduledTaskSubmitted(deadlineNanos)) {
          	// 场景2.1：任务还没有到期，将任务添加到mpsc队列中去
            execute(task);
        } else {
            lazyExecute(task);
            // Second hook after scheduling to facilitate race-avoidance
            if (afterScheduledTaskSubmitted(deadlineNanos)) {
                execute(WAKEUP_TASK);
            }
        }
    }

    return task;
}

// SingleThreadEventExecutor.java
@Override
public void execute(Runnable task) {
    ObjectUtil.checkNotNull(task, "task");
    execute(task, !(task instanceof LazyRunnable) && wakesUpForTask(task));
}
// 又回到了上面的方法里
private void execute(Runnable task, boolean immediate) {
    boolean inEventLoop = inEventLoop();
  	// 将任务加到mpsc队列
    addTask(task);
    if (!inEventLoop) {
        startThread(); // 启动线程
        if (isShutdown()) {
					...
        }
    }

    if (!addTaskWakesUp && immediate) {
        wakeup(inEventLoop);
    }
}
```

在阅读源码细节的过程中，我们应该多问几个为什么？这样会有利于看源码的时候不至于犯困！比如这里，为什么定时任务要保存在优先级队列中，我们可以先不看源码，来思考一下优先级对列的特性。

优先级队列按一定的顺序来排列内部元素，内部元素必须是可以比较的，联系到这里每个元素都是定时任务，那就说明定时任务是可以比较的，那么到底有哪些地方可以比较？

每个任务都有一个下一次执行的截止时间，截止时间是可以比较的，截止时间相同的情况下，任务添加的顺序也是可以比较的，就像这样，阅读源码的过程中，一定要多和自己对话，多问几个为什么。

带着猜想，我们研究与一下`ScheduledFutureTask`，抽取出关键部分

```java
// ScheduledFutureTask.java
final class ScheduledFutureTask<V> extends PromiseTask<V> implements ScheduledFuture<V> {
    private static final AtomicLong nextTaskId = new AtomicLong();
    private static final long START_TIME = System.nanoTime();

    static long nanoTime() {
        return System.nanoTime() - START_TIME;
    }

    private final long id = nextTaskId.getAndIncrement();
    /* 0 - no repeat, >0 - repeat at fixed rate, <0 - repeat with fixed delay */
    private final long periodNanos;

    @Override
    public int compareTo(Delayed o) {
        //...
    }

    // 精简过的代码
    @Override
    public void run() {
    }
````
这里，我们一眼就找到了`compareTo` 方法，跳转到实现的接口，发现就是`Comparable`接口。

```java
// ScheduledFutureTask.java
public int compareTo(Delayed o) {
    if (this == o) {
        return 0;
    }

    ScheduledFutureTask<?> that = (ScheduledFutureTask<?>) o;
    long d = deadlineNanos() - that.deadlineNanos();
    if (d < 0) {
        return -1;
    } else if (d > 0) {
        return 1;
    } else if (id < that.id) {
        return -1;
    } else if (id == that.id) {
        throw new Error();
    } else {
        return 1;
    }
}
```

进入到方法体内部，我们发现，两个定时任务的比较，确实是先比较任务的截止时间，截止时间相同的情况下，再比较id，即任务添加的顺序，如果id再相同的话，就抛Error。

这样，在执行定时任务的时候，就能保证最近截止时间的任务先执行。

下面，我们再来看下netty是如何来保证各种定时任务的执行的，netty里面的定时任务分以下三种：

1. 若干时间后执行一次
2. 每隔一段时间执行一次
3. 每次执行结束，隔一定时间再执行一次

netty使用一个 `periodNanos` 来区分这三种情况，正如netty的注释那样。

```java
// ScheduledFutureTask.java
/* 0 - no repeat, >0 - repeat at fixed rate, <0 - repeat with fixed delay */
private final long periodNanos;
```

了解这些背景之后，我们来看下netty是如何来处理这三种不同类型的定时任务的。

```java
// ScheduledFutureTask.java
@Override
public void run() {
    assert executor().inEventLoop();
    try {
        if (delayNanos() > 0L) {
            // Not yet expired, need to add or remove from queue
            if (isCancelled()) {
                scheduledExecutor().scheduledTaskQueue().removeTyped(this);
            } else {
                scheduledExecutor().scheduleFromEventLoop(this);
            }
            return;
        }
        if (periodNanos == 0) {
            if (setUncancellableInternal()) {
                V result = runTask();
                setSuccessInternal(result);
            }
        } else {
            // check if is done as it may was cancelled
            if (!isCancelled()) {
                runTask();
                if (!executor().isShutdown()) {
                    if (periodNanos > 0) {
                        deadlineNanos += periodNanos;
                    } else {
                        deadlineNanos = nanoTime() - periodNanos;
                    }
                    if (!isCancelled()) {
                        scheduledExecutor().scheduledTaskQueue().add(this);
                    }
                }
            }
        }
    } catch (Throwable cause) {
        setFailureInternal(cause);
    }
}
```

`delayNanos()`大于0，还没到截止时间，添加到定时任务队列或者从队列中移除。

`if (periodNanos == 0)` 对应 `若干时间后执行一次` 的定时任务类型，执行完了该任务就结束了。

否则，进入到else代码块，如果任务还没有取消，先执行任务，然后再区分是哪种类型的任务。`periodNanos`大于0，表示是以固定频率执行某个任务，和任务的持续时间无关，然后，设置该任务的下一次截止时间为本次的截止时间加上间隔时间`periodNanos`，否则，就是每次任务执行完毕之后，间隔多长时间之后再次执行，截止时间为当前时间加上间隔时间，`-p`（p此时为负数）就表示加上一个正的间隔时间，最后，将当前任务对象再次加入到队列，实现任务的定时执行。

netty内部的任务添加机制了解地差不多之后，我们就可以查看reactor第三部曲是如何来调度这些任务的。

#### reactor线程task的调度

首先，我们将目光转向最外层的外观代码。

```java
// SingleThreadEventExecutor.java
runAllTasks(long timeoutNanos);
```

顾名思义，这行代码表示了尽量在一定的时间内，将所有的任务都取出来run一遍。`timeoutNanos` 表示该方法最多执行这么长时间，netty为什么要这么做？我们可以想一想，reactor线程如果在此停留的时间过长，那么将积攒许多的IO事件无法处理(见reactor线程的前面两个步骤)，最终导致大量客户端请求阻塞，因此，默认情况下，netty将控制内部队列的执行时间。

好，我们继续跟进。

```java
// SingleThreadEventExecutor.java
protected boolean runAllTasks(long timeoutNanos) {
    fetchFromScheduledTaskQueue();
    Runnable task = pollTask();
    if (task == null) {
        afterRunningAllTasks();
        return false;
    }

    final long deadline = timeoutNanos > 0 ? ScheduledFutureTask.nanoTime() + timeoutNanos : 0;
    long runTasks = 0;
    long lastExecutionTime;
    for (;;) {
        safeExecute(task);

        runTasks ++;
      
        if ((runTasks & 0x3F) == 0) {
            lastExecutionTime = ScheduledFutureTask.nanoTime();
            if (lastExecutionTime >= deadline) {
                break;
            }
        }

        task = pollTask();
        if (task == null) {
            lastExecutionTime = ScheduledFutureTask.nanoTime();
            break;
        }
    }

    afterRunningAllTasks();
    this.lastExecutionTime = lastExecutionTime;
    return true;
}
```

这段代码便是reactor执行task的所有逻辑，可以拆解成下面几个步骤：

1. 从scheduledTaskQueue转移定时任务到taskQueue(mpsc queue)
2. 计算本次任务循环的截止时间
3. 执行任务
4. 收尾

按照这个步骤，我们一步步来分析下。

##### 从scheduledTaskQueue转移定时任务到taskQueue(mpsc queue)

```java
// SingleThreadEventExecutor.java
private boolean fetchFromScheduledTaskQueue() {
    if (scheduledTaskQueue == null || scheduledTaskQueue.isEmpty()) {
        return true;
    }
    long nanoTime = AbstractScheduledEventExecutor.nanoTime();
    for (;;) {
        Runnable scheduledTask = pollScheduledTask(nanoTime);
        if (scheduledTask == null) {
            return true;
        }
        if (!taskQueue.offer(scheduledTask)) {
            // No space left in the task queue add it back to the scheduledTaskQueue so we pick it up again.
            scheduledTaskQueue.add((ScheduledFutureTask<?>) scheduledTask);
            return false;
        }
    }
}
```

可以看到，netty在把任务从scheduledTaskQueue转移到taskQueue的时候还是非常小心的，当taskQueue无法offer的时候，需要把从scheduledTaskQueue里面取出来的任务重新添加回去。

从scheduledTaskQueue从拉取一个定时任务的逻辑如下，传入的参数`nanoTime`为当前时间(其实是当前纳秒减去`ScheduledFutureTask`类被加载的纳秒个数)。

```java
// AbstractScheduledEventExecutor.java
protected final Runnable pollScheduledTask(long nanoTime) {
    assert inEventLoop();

    ScheduledFutureTask<?> scheduledTask = peekScheduledTask();
    if (scheduledTask == null || scheduledTask.deadlineNanos() - nanoTime > 0) {
        return null;
    }
    scheduledTaskQueue.remove();
    scheduledTask.setConsumed();
    return scheduledTask;
}
```

可以看到，每次 `pollScheduledTask` 的时候，只有在当前任务的截止时间已经到了，才会取出来。

##### 计算本次任务循环的截止时间

```java
 // SingleThreadEventExecutor.java
 Runnable task = pollTask();
 //...
final long deadline = timeoutNanos > 0 ? ScheduledFutureTask.nanoTime() + timeoutNanos : 0;
long runTasks = 0;
long lastExecutionTime;
```

这一步将取出第一个任务，用reactor线程传入的超时时间 `timeoutNanos` 来计算出当前任务循环的deadline，并且使用了`runTasks`，`lastExecutionTime`来时刻记录任务的状态。

##### 循环执行任务

```java
 // SingleThreadEventExecutor.java
for (;;) {
    safeExecute(task);

    runTasks ++;

    if ((runTasks & 0x3F) == 0) {
        lastExecutionTime = ScheduledFutureTask.nanoTime();
        if (lastExecutionTime >= deadline) {
            break;
        }
    }

    task = pollTask();
    if (task == null) {
        lastExecutionTime = ScheduledFutureTask.nanoTime();
        break;
    }
}
```

这一步便是netty里面执行所有任务的核心代码了。

首先调用`safeExecute`来确保任务安全执行，忽略任何异常。

```java
// AbstractEventExecutor.java
protected static void safeExecute(Runnable task) {
    try {
        task.run();
    } catch (Throwable t) {
        logger.warn("A task raised an exception. Task: {}", task, t);
    }
}
```

然后将已运行任务 `runTasks` 加一，每隔`0x3F`任务，即每执行完64个任务之后，判断当前时间是否超过本次reactor任务循环的截止时间了，如果超过，那就break掉，如果没有超过，那就继续执行。可以看到，netty对性能的优化考虑地相当的周到，假设netty任务队列里面如果有海量小任务，如果每次都要执行完任务都要判断一下是否到截止时间，那么效率是比较低下的。

##### 收尾

```java
 // SingleThreadEventExecutor.java
afterRunningAllTasks();
this.lastExecutionTime = lastExecutionTime;
```

收尾工作很简单，调用一下 `afterRunningAllTasks` 方法。

```java
// SingleThreadEventLoop.java
@Override
protected void afterRunningAllTasks() {
    runAllTasksFrom(tailTasks);
}
```

`NioEventLoop`可以通过父类`SingleTheadEventLoop`的`executeAfterEventLoopIteration`方法向`tailTasks`中添加收尾任务，比如，你想统计一下一次执行一次任务循环花了多长时间就可以调用此方法。

```java
// SingleThreadEventLoop.java
public final void executeAfterEventLoopIteration(Runnable task) {
        // ...
        if (!tailTasks.offer(task)) {
            reject(task);
        }
        //...
}
```

`this.lastExecutionTime = lastExecutionTime;`简单记录一下任务执行的时间。

## 小结

reactor线程第三曲到了这里基本上就给你讲完了，如果你读到这觉得很轻松，那么恭喜你，你对netty的task机制已经非常比较熟悉了，也恭喜一下我，把这些机制给你将清楚了。我们最后再来一次总结，以tips的方式。

- 当前reactor线程调用当前eventLoop执行任务，直接执行，否则，添加到任务队列稍后执行。
- netty内部的任务分为普通任务和定时任务，分别落地到MpscQueue和PriorityQueue。
- netty每次执行任务循环之前，会将已经到期的定时任务从PriorityQueue转移到MpscQueue。
- netty每隔64个任务检查一下是否该退出任务循环。



## 参考

[netty源码分析之揭开reactor线程的面纱（一）](https://www.jianshu.com/p/0d0eece6d467)

[netty源码分析之揭开reactor线程的面纱（一）](https://www.jianshu.com/p/0d0eece6d467)

[netty源码分析之揭开reactor线程的面纱（一）](https://www.jianshu.com/p/0d0eece6d467)

[Netty源码分析（五）：EventLoop](https://www.cnblogs.com/YJTZ/p/10742949.html)

[Netty源码分析（六）：SelectedSelectionKeySetSelector](https://www.cnblogs.com/YJTZ/p/10853466.html)

[Netty 那些事儿 ——— Reactor模式详解](https://www.jianshu.com/p/1ccbc6a348db)

[http://www.dre.vanderbilt.edu/~schmidt/PDF/reactor-siemens.pdf](https://link.jianshu.com/?t=http://www.dre.vanderbilt.edu/~schmidt/PDF/reactor-siemens.pdf)

[Netty 源码解析 ——— NioEventLoop 详解](https://www.jianshu.com/p/3f6e997efd27)
