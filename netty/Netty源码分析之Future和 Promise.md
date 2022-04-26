## Netty 中的异步编程: Future

关于 `Future` 接口，我想大家应该都很熟悉，用得最多的就是在使用 Java 的线程池 `ThreadPoolExecutor` 的时候了。在 **submit** 一个任务到线程池中的时候，返回的就是一个 `Future` 实例，通过它来获取提交的任务的执行状态和最终的执行结果，我们最常用它的 `isDone()` 和 `get()` 方法。

下面是 JDK  中的 `Future` 接口：

```java
// java.util.concurrent.Future.java
public interface Future<V> {
    // 取消该任务
    boolean cancel(boolean mayInterruptIfRunning);
    // 任务是否已取消
    boolean isCancelled();
    // 任务是否已完成
    boolean isDone();
    // 阻塞获取任务执行结果
    V get() throws InterruptedException, ExecutionException;
    // 带超时参数的获取任务执行结果
    V get(long timeout, TimeUnit unit)
        throws InterruptedException, ExecutionException, TimeoutException;
}
```

我们的第一印象会觉得这样的设计并不坏，但仔细思考，便会发现问题：

1. 接口中只有isDone()方法判断一个异步操作是否完成，但是对于完成的定义过于模糊，JDK文档指出正常终止、抛出异常、用户取消都会使isDone()方法返回真。在我们的使用中，我们极有可能是对这三种情况分别处理，而JDK这样的设计不能满足我们的需求。
2. 对于一个异步操作，我们更关心的是这个异步操作触发或者结束后能否再执行一系列动作。可见在这样的情况下，JDK中的Future便不能处理。

所以，Netty针对上面两个问题进行了扩展，Netty 中的`Future` 接口（同名）继承了 JDK 中的 `Future` 接口，然后添加了一些方法：

```java
// io.netty.util.concurrent.Future
public interface Future<V> extends java.util.concurrent.Future<V> {

    // 是否成功
    boolean isSuccess();

    // 是否可取消
    boolean isCancellable();

    // 如果任务执行失败，这个方法返回异常信息
    Throwable cause();

    // 添加 Listener 来进行回调
    Future<V> addListener(GenericFutureListener<? extends Future<? super V>> listener);
    Future<V> addListeners(GenericFutureListener<? extends Future<? super V>>... listeners);

    Future<V> removeListener(GenericFutureListener<? extends Future<? super V>> listener);
    Future<V> removeListeners(GenericFutureListener<? extends Future<? super V>>... listeners);

    // 阻塞等待任务结束，如果任务失败，将“导致失败的异常”重新抛出来
    Future<V> sync() throws InterruptedException;
    // 不响应中断的 sync()，这个大家应该都很熟了
    Future<V> syncUninterruptibly();

    // 阻塞等待任务结束，和 sync() 功能是一样的，不过如果任务失败，它不会抛出执行过程中的异常
    Future<V> await() throws InterruptedException;
    Future<V> awaitUninterruptibly();
    boolean await(long timeout, TimeUnit unit) throws InterruptedException;
    boolean await(long timeoutMillis) throws InterruptedException;
    boolean awaitUninterruptibly(long timeout, TimeUnit unit);
    boolean awaitUninterruptibly(long timeoutMillis);

    // 获取执行结果，不阻塞。我们都知道 java.util.concurrent.Future 中的 get() 是阻塞的
    V getNow();

    // 取消任务执行，如果取消成功，任务会因为 CancellationException 异常而导致失败
    //      也就是 isSuccess()==false，同时上面的 cause() 方法返回 CancellationException 的实例。
    // mayInterruptIfRunning 说的是：是否对正在执行该任务的线程进行中断(这样才能停止该任务的执行)，
    //       似乎 Netty 中 Future 接口的各个实现类，都没有使用这个参数
    @Override
    boolean cancel(boolean mayInterruptIfRunning);
}
```

如果你对Future的状态还有疑问，放上代码注释中的ascii图打消你的疑虑：

```ruby
 *                                      +---------------------------+
 *                                      | Completed successfully    |
 *                                      +---------------------------+
 *                                 +---->      isDone() = true      |
 * +--------------------------+    |    |   isSuccess() = true      |
 * |        Uncompleted       |    |    +===========================+
 * +--------------------------+    |    | Completed with failure    |
 * |      isDone() = false    |    |    +---------------------------+
 * |   isSuccess() = false    |----+---->      isDone() = true      |
 * | isCancelled() = false    |    |    |       cause() = non-null  |
 * |       cause() = null     |    |    +===========================+
 * +--------------------------+    |    | Completed by cancellation |
 *                                 |    +---------------------------+
 *                                 +---->      isDone() = true      |
 *                                      | isCancelled() = true      |
 *                                      +---------------------------+
```

可知，Future对象有两种状态尚未完成和已完成，其中已完成又有三种状态：成功、失败、用户取消。

看完上面的 Netty 的 `Future` 接口，我们可以发现，它加了 `sync()` 和 `await()` 用于阻塞等待，还加了 Listeners，只要任务结束去回调 Listener 们就可以了，那么我们就不一定要主动调用 isDone() 来获取状态，或通过 get() 阻塞方法来获取值。

所以它其实有两种使用范式。

顺便说下 `sync()` 和 `await()` 的区别：`sync()` 内部会先调用 `await()` 方法，等 `await()` 方法返回后，会检查下**这个任务是否失败**，如果失败，重新将导致失败的异常抛出来。也就是说，如果使用 `await()`，任务抛出异常后，`await()` 方法会返回，但是不会抛出异常，而 `sync()` 方法返回的同时会抛出异常。

我们也可以看到，`Future` 接口没有和 IO 操作关联在一起，还是比较*纯净*的接口。

### AbstractFuture

AbstractFuture主要实现Future的get()方法，取得Future关联的异步操作结果：

```java
// AbstractFuture.java
public abstract class AbstractFuture<V> implements Future<V> {

    @Override
    public V get() throws InterruptedException, ExecutionException {
        await(); // 阻塞直到异步操作完成

        Throwable cause = cause();
        if (cause == null) {
            return getNow(); // 成功则返回关联结果
        }
        if (cause instanceof CancellationException) {
            throw (CancellationException) cause; // 由用户取消
        }
        throw new ExecutionException(cause); // 失败抛出异常
    }

    @Override
    public V get(long timeout, TimeUnit unit) throws InterruptedException, ExecutionException, TimeoutException {
        if (await(timeout, unit)) {
            Throwable cause = cause();
            if (cause == null) {
                return getNow();
            }
            if (cause instanceof CancellationException) {
                throw (CancellationException) cause;
            }
            throw new ExecutionException(cause);
        }
        throw new TimeoutException();
    }
}
```

其中的实现简单明了，但关键调用方法的具体实现并没有，我们将在子类实现中分析。对应的加入超时时间的get(long timeout, TimeUnit unit)实现也类似。

### CompleteFuture

Complete表示操作已完成，所以CompleteFuture表示一个异步操作已完成的结果，由此可推知：该类的实例在异步操作完成时创建，返回给用户，用户则使用addListener()方法定义一个异步操作。如果你熟悉javascript，将Listener类比于回调函数callback()可方便理解。

```java
// CompleteFuture.java
// 执行器，执行Listener中定义的操作
private final EventExecutor executor;

// 这有一个构造方法，可知executor是必须的
protected CompleteFuture(EventExecutor executor) {
    this.executor = executor;
}
```

CompleteFuture类定义了一个EventExecutor，可视为一个线程，用于执行Listener中的操作。我们再看addListener()和removeListener()方法：

```java
// CompleteFuture.java
@Override
public Future<V> addListener(GenericFutureListener<? extends Future<? super V>> listener) {
    // 由于这是一个已完成的Future，所以立即通知Listener执行
    DefaultPromise.notifyListener(executor(), this, ObjectUtil.checkNotNull(listener, "listener"));
    return this; 
}

@Override
public Future<V> removeListener(GenericFutureListener<? extends Future<? super V>> listener) {
    // NOOP 由于已完成，Listener中的操作已完成，没有需要删除的Listener
    return this;
}
```

其中的实现也很简单，我们看一下GenericFutureListener接口，其中只定义了一个方法：

```java
// GenericFutureListener.java
void operationComplete(F future) throws Exception; // 异步操作完成是调用
```

关于Listener我们再关注一下ChannelFutureListener，它并没有扩展GenericFutureListener接口，所以类似于一个标记接口。我们看其中实现的三个通用ChannelFutureListener：

```java
// ChannelFutureListener.java
public interface ChannelFutureListener extends GenericFutureListener<ChannelFuture> {

    ChannelFutureListener CLOSE = new ChannelFutureListener() {
        @Override
        public void operationComplete(ChannelFuture future) {
            future.channel().close(); // 操作完成时关闭Channel
        }
    };

    ChannelFutureListener CLOSE_ON_FAILURE = new ChannelFutureListener() {
        @Override
        public void operationComplete(ChannelFuture future) {
            if (!future.isSuccess()) {
                future.channel().close(); // 操作失败时关闭Channel
            }
        }
    };
  
    ChannelFutureListener FIRE_EXCEPTION_ON_FAILURE = new ChannelFutureListener() {
        @Override
        public void operationComplete(ChannelFuture future) {
            if (!future.isSuccess()) {
              	// 操作失败时触发一个ExceptionCaught事件
                future.channel().pipeline().fireExceptionCaught(future.cause());
            }
        }
    };

}
```

这三个Listener对象定义了对Channel处理时常用的操作，如果符合需求，可以直接使用。

由于CompleteFuture表示一个已完成的异步操作，所以可推知sync()和await()方法都将立即返回。此外，可推知线程的状态如下，不再列出代码：

```bash
isDone() = true; isCancelled() = false; 
```

### ChannelFuture

接下来，我们来看 `Future` 接口的子接口 `ChannelFuture`，这个接口用得最多，它将和 IO 操作中的 Channel 关联在一起了，用于异步处理 Channel 中的事件。

```java
// ChannelFuture.java
public interface ChannelFuture extends Future<Void> {

    // ChannelFuture 关联的 Channel
    Channel channel();

    // 覆写以下几个方法，使得它们返回值为 ChannelFuture 类型 
    @Override
    ChannelFuture addListener(GenericFutureListener<? extends Future<? super Void>> listener);
    @Override
    ChannelFuture addListeners(GenericFutureListener<? extends Future<? super Void>>... listeners);
    @Override
    ChannelFuture removeListener(GenericFutureListener<? extends Future<? super Void>> listener);
    @Override
    ChannelFuture removeListeners(GenericFutureListener<? extends Future<? super Void>>... listeners);

    @Override
    ChannelFuture sync() throws InterruptedException;
    @Override
    ChannelFuture syncUninterruptibly();

    @Override
    ChannelFuture await() throws InterruptedException;
    @Override
    ChannelFuture awaitUninterruptibly();

    // 用来标记该 future 是 void 的，
    // 这样就不允许使用 addListener(...), sync(), await() 以及它们的几个重载方法
    boolean isVoid();
}
```

我们看到，`ChannelFuture` 接口相对于 `Future` 接口，除了将 channel 关联进来，没有增加什么东西。还有个 `isVoid() `方法算是不那么重要的存在吧。其他几个都是方法覆写，为了让返回值类型变为 `ChannelFuture`，而不是原来的 `Future`。

### CompleteChannelFuture

CompleteChannelFuture的类签名如下：

```java
abstract class CompleteChannelFuture extends CompleteFuture<Void> implements ChannelFuture
```

CompleteChannelFuture还继承了CompleteFuture\<Void\>，尖括号中的泛型表示Future关联的结果，此结果为Void，意味着CompleteChannelFuture不关心这个特定结果即get()相关方法返回null。也就是说，我们可以将CompleteChannelFuture纯粹的视为一种回调函数机制。

CompleteChannelFuture的字段只有一个：

```java
private final Channel channel; // 关联的Channel对象
```

CompleteChannelFuture的大部分方法实现中，只是将方法返回的Future覆盖为ChannelFuture对象（ChannelFuture接口的要求），代码不在列出。我们看一下executor()方法：

```java
// CompleteChannelFuture.java
@Override
protected EventExecutor executor() {
    EventExecutor e = super.executor(); // 构造方法指定
    if (e == null) {
        return channel().eventLoop(); // 构造方法未指定使用channel注册到的eventLoop
    } else {
        return e;
    }
}
```

### Succeeded/FailedChannelFuture

Succeeded/FailedChannelFuture为特定的两个异步操作结果，回忆总述中关于Future状态的讲解，成功意味着

```bash
Succeeded: isSuccess() == true, cause() == null;
Failed:    isSuccess() == false, cause() == non-null        
```

代码中的实现也很简单，不再列出。需要注意的是，其中的构造方法不建议用户调用，一般使用Channel对象的方法newSucceededFuture()和newFailedFuture(Throwable)代替。

## Netty 中的异步编程: Promise

仔细看完上一节并联系Future接口中的方法，你是不是也会和我有相同的疑问：Future接口中的方法都是getter方法而没有setter方法，也就是说这样实现的Future子类的状态是不可变的，如果我们想要变化，那该怎么办呢？Netty提供的解决方法是：使用可写的Future即Promise。

我们来介绍下 `Promise` 接口，它和 `ChannelFuture` 接口无关，而是和前面的 `Future` 接口相关，`Promise` 这个接口非常重要。

`Promise` 接口和 `ChannelFuture` 一样，也继承了 Netty 的 `Future` 接口，然后加了一些 `Promise` 的内容：

```java
// Promise.java
public interface Promise<V> extends Future<V> {

    // 标记该 future 成功及设置其执行结果，并且会通知所有的 listeners。
    // 如果该操作失败，将抛出异常(失败指的是该 future 已经有了结果了，成功的结果，或者失败的结果)
    Promise<V> setSuccess(V result);

    // 和 setSuccess 方法一样，只不过如果失败，它不抛异常，返回 false
    boolean trySuccess(V result);

    // 标记该 future 失败，及其失败原因。
    // 如果失败，将抛出异常(失败指的是已经有了结果了)
    Promise<V> setFailure(Throwable cause);

    // 标记该 future 失败，及其失败原因。
    // 如果已经有结果，返回 false，不抛出异常
    boolean tryFailure(Throwable cause);

    // 标记该 future 不可以被取消
    boolean setUncancellable();

    // 这里和 ChannelFuture 一样，对这几个方法进行覆写，目的是为了返回 Promise 类型的实例
    @Override
    Promise<V> addListener(GenericFutureListener<? extends Future<? super V>> listener);
    @Override
    Promise<V> addListeners(GenericFutureListener<? extends Future<? super V>>... listeners);

    @Override
    Promise<V> removeListener(GenericFutureListener<? extends Future<? super V>> listener);
    @Override
    Promise<V> removeListeners(GenericFutureListener<? extends Future<? super V>>... listeners);

    @Override
    Promise<V> await() throws InterruptedException;
    @Override
    Promise<V> awaitUninterruptibly();

    @Override
    Promise<V> sync() throws InterruptedException;
    @Override
    Promise<V> syncUninterruptibly();
}
```

可能有些读者对 `Promise` 的概念不是很熟悉，这里简单说两句。

我觉得只要明白一点，`Promise` 实例内部是一个任务，任务的执行往往是异步的，通常是一个线程池来处理任务。`Promise` 提供的 `setSuccess(V result)` 或 `setFailure(Throwable t)` 将来会被某个执行任务的线程在执行完成以后调用，同时那个线程在调用 `setSuccess(result)` 或 `setFailure(t)` 后会回调 listeners 的回调函数（当然，回调的具体内容不一定要由执行任务的线程自己来执行，它可以创建新的线程来执行，也可以将回调任务提交到某个线程池来执行）。而且，一旦 setSuccess(...) 或 setFailure(...) 后，那些 `await()` 或 `sync()` 的线程就会从等待中返回。

**所以这里就有两种编程方式，一种是用 await()，等 await() 方法返回后，得到 promise 的执行结果，然后处理它；另一种就是提供 Listener 实例，我们不太关心任务什么时候会执行完，只要它执行完了以后会去执行 listener 中的处理方法就行。**

Promise从Uncompleted --> Completed的状态转变**有且只能有一次**，也就是说setSuccess和setFailure方法最多只会成功一个，此外，在setSuccess和setFailure方法中会通知注册到其上的监听者。为了加深对Future和Promise的理解，我们可以将Future类比于定额发票，Promise类比于机打发票。当商户拿到税务局的发票时，如果是定额发票，则已经确定好金额是100还是50或其他，商户再也不能更改；如果是机打发票，商户相当于拿到了一个发票模板，需要多少金额按实际情况填到模板指定处。显然，不能两次使用同一张机打发票打印，这会使发票失效，而Promise做的更好，它使第二次调用setter方法失败。

## Netty 中的异步编程: ChannelPromise

接下来，我们再来看下 **ChannelPromise**，它继承了前面介绍的 ChannelFuture 和 Promise 接口。

<img src="http://blog-1259650185.cosbj.myqcloud.com/img/202112/06/1638721076.png" alt="4" style="zoom:50%;" />

ChannelPromise 接口在 Netty 中使用得比较多，因为它综合了 ChannelFuture 和 Promise 两个接口：

```java
// ChannelPromise.java
public interface ChannelPromise extends ChannelFuture, Promise<Void> {

    // 覆写 ChannelFuture 中的 channel() 方法，其实这个方法一点没变
    @Override
    Channel channel();

    // 下面几个方法是覆写 Promise 中的接口，为了返回值类型是 ChannelPromise
    @Override
    ChannelPromise setSuccess(Void result);
    ChannelPromise setSuccess();
    boolean trySuccess();
    @Override
    ChannelPromise setFailure(Throwable cause);

    // 到这里大家应该都熟悉了，下面几个方法的覆写也是为了得到 ChannelPromise 类型的实例
    @Override
    ChannelPromise addListener(GenericFutureListener<? extends Future<? super Void>> listener);
    @Override
    ChannelPromise addListeners(GenericFutureListener<? extends Future<? super Void>>... listeners);
    @Override
    ChannelPromise removeListener(GenericFutureListener<? extends Future<? super Void>> listener);
    @Override
    ChannelPromise removeListeners(GenericFutureListener<? extends Future<? super Void>>... listeners);

    @Override
    ChannelPromise sync() throws InterruptedException;
    @Override
    ChannelPromise syncUninterruptibly();
    @Override
    ChannelPromise await() throws InterruptedException;
    @Override
    ChannelPromise awaitUninterruptibly();

    /**
     * Returns a new {@link ChannelPromise} if {@link #isVoid()} returns {@code true} otherwise itself.
     */
    // 我们忽略这个方法吧。
    ChannelPromise unvoid();
}
```

我们可以看到，它综合了 ChannelFuture 和 Promise 中的方法，只不过通过覆写将返回值都变为 ChannelPromise 了而已，**没有增加什么新的功能**。

小结一下，我们上面介绍了几个接口，Future 以及它的子接口 ChannelFuture 和 Promise，然后是 ChannelPromise 接口同时继承了 ChannelFuture 和 Promise。

我把这几个接口的主要方法列在一起，这样大家看得清晰些：

<img src="http://blog-1259650185.cosbj.myqcloud.com/img/202112/06/1638721247.png" alt="7" style="zoom: 50%;" />

接下来，我们需要来一个实现类，这样才能比较直观地看出它们是怎么使用的，因为上面的这些都是接口定义，具体还得看实现类是怎么工作的。

## Netty 中的异步编程: DefaultPromise

下面，我们来介绍下 **DefaultPromise** 这个实现类，这个类很常用，它的源码也不短，我们先介绍几个关键的内容，然后介绍一个示例使用。

首先，我们看下它有哪些属性：

```java
// DefaultPromise.java
public class DefaultPromise<V> extends AbstractFuture<V> implements Promise<V> {
  	// 可以嵌套的Listener的最大层数，可见最大值为8
  	private static final int MAX_LISTENER_STACK_DEPTH = Math.min(8,
        SystemPropertyUtil.getInt("io.netty.defaultPromise.maxListenerStackDepth", 8));
  
		// result字段由使用RESULT_UPDATER更新
		private static final AtomicReferenceFieldUpdater<DefaultPromise, Object> RESULT_UPDATER =
        AtomicReferenceFieldUpdater.newUpdater(DefaultPromise.class, Object.class, "result");  
  	// 异步操作成功且结果为null时设置为改值
		private static final Object SUCCESS = new Object();
  	// 异步操作不可取消
		private static final Object UNCANCELLABLE = new Object();
  	// 异步操作失败时保存异常原因
		private static final CauseHolder CANCELLATION_CAUSE_HOLDER = new CauseHolder(
        StacklessCancellationException.newInstance(DefaultPromise.class, "cancel(...)"));  
    // 异步操作结果
    private volatile Object result;
    // 执行任务和listener操作的线程池，promise 持有 executor 的引用
    private final EventExecutor executor;
    // 监听者，回调函数，任务结束后（正常或异常结束）执行
    private Object listeners;

    // 阻塞等待这个 promise 的线程数(调用sync()/await()进行等待的线程数量)
    private short waiters;

    // 是否正在唤醒等待线程，用于防止重复执行唤醒，不然会重复执行 listeners 的回调方法
    private boolean notifyingListeners;
    ......
}
```

可以看出，此类实现了 Promise，但是没有实现 ChannelFuture，所以它和 Channel 联系不起来。

别急，我们后面会碰到另一个类 DefaultChannelPromise 的使用，这个类是综合了 ChannelFuture 和 Promise 的，但是它的实现其实大部分都是继承自这里的 DefaultPromise 类的。

嵌套的Listener，是指在listener的operationComplete方法中，可以再次使用future.addListener()继续添加listener，Netty限制的最大层数是8，用户可使用系统变量io.netty.defaultPromise.maxListenerStackDepth设置。

也许你已经注意到，listeners是一个Object类型。这似乎不合常理，一般情况下我们会使用一个集合或者一个数组。Netty之所以这样设计，是因为大多数情况下listener只有一个，用集合和数组都会造成浪费。当只有一个listener时，该字段为一个GenericFutureListener对象；当多余一个listener时，该字段为DefaultFutureListeners，可以储存多个listener。明白了这些，我们分析关键方法addListener()：

```java
// DefaultPromise.java
@Override
public Promise<V> addListener(GenericFutureListener<? extends Future<? super V>> listener) {
    synchronized (this) {
        addListener0(listener); // 保证多线程情况下只有一个线程执行添加操作
    }

    if (isDone()) {
        notifyListeners();  // 异步操作已经完成通知监听者
    }
    return this;
}

private void addListener0(GenericFutureListener<? extends Future<? super V>> listener) {
    if (listeners == null) {
        listeners = listener;   // 只有一个
    } else if (listeners instanceof DefaultFutureListeners) {
        ((DefaultFutureListeners) listeners).add(listener); // 大于两个
    } else {
        // 从一个扩展为两个
        listeners = new DefaultFutureListeners((GenericFutureListener<? extends Future<V>>) listeners, listener);   
    }
}
```

从代码中可以看出，在添加Listener时，如果异步操作已经完成，则会notifyListeners()：

```java
// DefaultPromise.java
private void notifyListeners() {
    EventExecutor executor = executor();
    if (executor.inEventLoop()) {  // 执行线程为reactor线程
        final InternalThreadLocalMap threadLocals = InternalThreadLocalMap.get();
        final int stackDepth = threadLocals.futureListenerStackDepth(); // 嵌套层数
        if (stackDepth < MAX_LISTENER_STACK_DEPTH) {
            threadLocals.setFutureListenerStackDepth(stackDepth + 1); // 执行前增加嵌套层数
            try {
                notifyListenersNow();
            } finally { // 执行完毕，无论如何都要回滚嵌套层数
                threadLocals.setFutureListenerStackDepth(stackDepth);
            }
            return;
        }
    }
    // 外部线程则提交任务给执行线程
    safeExecute(executor, new Runnable() {
        @Override
        public void run() {
            notifyListenersNow();
        }
    });
}

private static void safeExecute(EventExecutor executor, Runnable task) {
    try {
        executor.execute(task);
    } catch (Throwable t) {
        rejectedExecutionLogger.error("Failed to submit a listener notification task. Event loop shut down?", t);
    }
}
```

所以，外部线程不能执行监听者Listener中定义的操作，只能提交任务到指定Executor，其中的操作最终由指定Executor执行。我们再看notifyListenersNow()方法：

```java
// DefaultPromise.java
private void notifyListenersNow() {
    Object listeners;
    synchronized (this) { // 此时外部线程可能会执行添加Listener操作，所以需要同步
        // Only proceed if there are listeners to notify and we are not already notifying listeners.
        if (notifyingListeners || this.listeners == null) { // 正在通知或已没有监听者（外部线程删除）直接返回
            return;
        }
        notifyingListeners = true;
        listeners = this.listeners;
        this.listeners = null;
    }
    for (;;) {
        if (listeners instanceof DefaultFutureListeners) { // 通知单个
            notifyListeners0((DefaultFutureListeners) listeners);
        } else { // 通知多个（遍历集合调用单个）
            notifyListener0(this, (GenericFutureListener<?>) listeners);
        }
        synchronized (this) {
            if (this.listeners == null) {  // 执行完毕且外部线程没有再添加监听者
                // Nothing can throw from within this method, so setting notifyingListeners back to false does not
                // need to be in a finally block.
                notifyingListeners = false;
                return;
            }
            listeners = this.listeners; // 外部线程添加了监听者继续执行
            this.listeners = null;
        }
    }
}


private static void notifyListener0(Future future, GenericFutureListener l) {
    try {
        l.operationComplete(future);
    } catch (Throwable t) {
        if (logger.isWarnEnabled()) {
            logger.warn("An exception was thrown by " + l.getClass().getName() + ".operationComplete()", t);
        }
    }
}
```

到此为止，我们分析完了Promise最重要的addListener()和notifyListener()方法。在源码中还有static的notifyListener()方法，这些方法是CompleteFuture使用的，对于CompleteFuture，添加监听者的操作不需要缓存，直接执行Listener中的方法即可，执行线程为调用线程，相关代码可回顾CompleteFuture。addListener()相对的removeListener()方法实现简单，我们不再分析。

回忆result字段，修饰符有volatile，所以使用RESULT_UPDATER更新，保证更新操作为原子操作。Promise不携带特定的结果（即携带Void）时，成功时设置为静态字段的Object对象SUCCESS；如果携带泛型参数结果，则设置为泛型一致的结果。对于Promise，设置成功、设置失败、取消操作，**三个操作至多只能调用一个且同一个方法至多生效一次**，再次调用会抛出异常（set）或返回失败（try）。这些设置方法原理相同，我们以setSuccess()为例分析:

```java
// DefaultPromise.java
@Override
public Promise<V> setSuccess(V result) {
    if (setSuccess0(result)) {
        return this;
    }
    throw new IllegalStateException("complete already: " + this);
}

private boolean setSuccess0(V result) {
    return setValue0(result == null ? SUCCESS : result); // 为空时设置为SUCCESS对象
}

private boolean setValue0(Object objResult) {
    if (RESULT_UPDATER.compareAndSet(this, null, objResult) ||
        RESULT_UPDATER.compareAndSet(this, UNCANCELLABLE, objResult)) { // 只有结果为null或者UNCANCELLABLE时才可设置且只可以设置一次
        if (checkNotifyWaiters()) { // 唤醒调用await()和sync()方法等待该异步操作结果的线程
            notifyListeners(); // 通知等待的线程
        }
        return true;
    }
    return false;
}
```

checkNotifyWaiters()方法唤醒调用await()和sync()方法等待该异步操作结果的线程，代码如下：

```java
private synchronized boolean checkNotifyWaiters() {
    if (waiters > 0) { // 确实有等待的线程才notifyAll
        notifyAll(); // JDK方法
    }
    return listeners != null;
}
```

说完上面的属性以后，大家可以看下 `setSuccess(V result)` 、`trySuccess(V result)` 和 `setFailure(Throwable cause)` 、 `tryFailure(Throwable cause)` 这几个方法：

```java
// DefaultPromise.java
@Override
public Promise<V> setSuccess(V result) {
    if (setSuccess0(result)) {
        return this;
    }
    throw new IllegalStateException("complete already: " + this);
}

@Override
public boolean trySuccess(V result) {
    return setSuccess0(result);
}

@Override
public Promise<V> setFailure(Throwable cause) {
    if (setFailure0(cause)) {
        return this;
    }
    throw new IllegalStateException("complete already: " + this, cause);
}

@Override
public boolean tryFailure(Throwable cause) {
    return setFailure0(cause);
}

private boolean setSuccess0(V result) {
    return setValue0(result == null ? SUCCESS : result);
}

private boolean setFailure0(Throwable cause) {
    return setValue0(new CauseHolder(checkNotNull(cause, "cause")));
}

private boolean setValue0(Object objResult) {
    if (RESULT_UPDATER.compareAndSet(this, null, objResult) ||
        RESULT_UPDATER.compareAndSet(this, UNCANCELLABLE, objResult)) {
        if (checkNotifyWaiters()) {
            notifyListeners();
        }
        return true;
    }
    return false;
}
```

看出 `setSuccess(result)` 和 `trySuccess(result)` 的区别了吗？

上面几个方法都非常简单，先设置好值，然后执行监听者们的回调方法。notifyListeners() 方法感兴趣的读者也可以看一看，不过它还涉及到 Netty 线程池的一些内容，我们还没有介绍到线程池，这里就不展开了。上面的代码，在 `setSuccess0` 或 `setFailure0` 方法中都会唤醒阻塞在 `sync()` 或 `await()` 的线程。有了唤醒操作，那么sync()和await()的实现是怎么样的呢？

```java
// DefaultPromise.java
@Override
public Promise<V> sync() throws InterruptedException {
    await();
    rethrowIfFailed(); // 如果任务是失败的，重新抛出相应的异常
    return this;
}
```

可见，sync()和await()很类似，区别只是sync()调用，如果异步操作失败，则会抛出异常。我们接着看await()的实现：

```java
// DefaultPromise.java
@Override
public Promise<V> await() throws InterruptedException {
    if (isDone()) { // 异步操作已经完成，直接返回
        return this;
    }

    if (Thread.interrupted()) {
        throw new InterruptedException(toString());
    }

    checkDeadLock(); // 死锁检测

    synchronized (this) { // 同步使修改waiters的线程只有一个
        while (!isDone()) {  // 等待直到异步操作完成
            incWaiters();  // ++waiters;
            try {
                wait(); // JDK方法
            } finally {
                decWaiters(); // --waiters
            }
        }
    }
    return this;
}
```

其中的实现简单明了，其他await()方法也类似，不再分析。我们注意其中的checkDeadLock()方法用来进行死锁检测：

```java
// DefaultPromise.java
protected void checkDeadLock() {
    EventExecutor e = executor();
    if (e != null && e.inEventLoop()) {
        throw new BlockingOperationException(toString());
    }
}
```

也就是说，**不能在同一个线程中调用await()相关的方法**。为了更好的理解这句话，我们使用代码注释中的例子来解释。Handler中的channelRead()方法是由Channel注册到的eventLoop执行的，其中的Future的Executor也是这个eventLoop，所以不能在channelRead()方法中调用await这一类（包括sync）方法。

```java
// 错误的例子
public void channelRead(ChannelHandlerContext ctx, Object msg) {
    ChannelFuture future = ctx.channel().close();
    future.awaitUninterruptibly();
    // ...
}

// 正确的做法
public void channelRead(ChannelHandlerContext ctx, Object msg) {
    ChannelFuture future = ctx.channel().close();
    future.addListener(new ChannelFutureListener() {
        public void operationComplete(ChannelFuture future) {
            // ... 使用异步操作
        }
    });
}
```

到了这里，我们已经分析完Future和Promise的主要实现。剩下的DefaultChannelPromise、VoidChannelPromise实现都很简单，我们不再分析。ProgressivePromise表示异步的进度结果，也不再进行分析。

## 代码实践

接下来，我们来写个实例代码吧：

```java
// 用户代码
public static void main(String[] args) {

    // 构造线程池
    EventExecutor executor = new DefaultEventExecutor();

    // 创建 DefaultPromise 实例
    Promise promise = new DefaultPromise(executor);

    // 下面给这个 promise 添加两个 listener
    promise
            .addListener((GenericFutureListener<Future<Integer>>) future -> {
                if (future.isSuccess()) {
                    System.out.println("任务结束，结果：" + future.get());
                } else {
                    System.out.println("任务失败，异常：" + future.cause());
                }
            })
            .addListener((GenericFutureListener<Future<Integer>>) future ->
                    System.out.println("任务结束，balabala...")
            );

    // 提交任务到线程池，五秒后执行结束，设置执行 promise 的结果
    executor.submit(() -> {
        try {
            Thread.sleep(5000);
        } catch (InterruptedException e) {
            // do nothing
        }
        // 设置 promise 的结果
        // promise.setFailure(new RuntimeException());
        promise.setSuccess(123456);
    });

    // main 线程阻塞等待执行结果
    try {
        promise.sync();
    } catch (InterruptedException e) {
        // do nothing
    }
}
```

运行代码，两个 listener 将在 5 秒后将输出：

```
任务结束，结果：123456
任务结束，balabala...
```

读者这里可以试一下 `sync()` 和 `await()` 的区别，在任务中调用 `promise.setFailure(new RuntimeException())` 试试看。

`sync()`的输出结果如下：

```java
Exception in thread "main" java.lang.RuntimeException
	at top.lijingyuan.netty.learning.test.PromiseTest.lambda$main$2(PromiseTest.java:43)
	at io.netty.util.concurrent.PromiseTask.runTask(PromiseTask.java:98)
	at io.netty.util.concurrent.PromiseTask.run(PromiseTask.java:106)
	at io.netty.util.concurrent.DefaultEventExecutor.run(DefaultEventExecutor.java:66)
	at io.netty.util.concurrent.SingleThreadEventExecutor$4.run(SingleThreadEventExecutor.java:986)
	at io.netty.util.internal.ThreadExecutorMap$2.run(ThreadExecutorMap.java:74)
	at io.netty.util.concurrent.FastThreadLocalRunnable.run(FastThreadLocalRunnable.java:30)
	at java.base/java.lang.Thread.run(Thread.java:829)
```

`await()`的输出结果如下：

```
任务失败，异常：java.lang.RuntimeException
任务结束，balabala...
```

可以看到， `sync()`会将异常抛出来，而`await()`则会返回，然后通知listener。

上面的代码中，大家可能会对线程池 executor 和 `promise` 之间的关系感到有点迷惑。读者应该也要清楚，**具体的任务不一定就要在这个 executor 中被执行**。任务结束以后，需要调用 `promise.setSuccess(result)` 作为通知。

通常来说，`promise` 代表的 `future` 是**不需要和线程池搅在一起的**，`future` 只关心任务是否结束以及任务的执行结果，至于是哪个线程或哪个线程池执行的任务，`future` 其实是不关心的。

不过 Netty 毕竟不是要创建一个通用的线程池实现，而是和它要处理的 IO 息息相关的，所以我们只不过要理解它就好了。

我们看一下这张图，看看大家是不是看懂了这节内容：

<img src="http://blog-1259650185.cosbj.myqcloud.com/img/202112/06/1638722506.png" alt="6" style="zoom:50%;" />

我们就说说上图左边的部分吧，main 线程调用 `b.bind(port)` 这个方法会返回一个 `ChannelFuture`，`bind()` 是一个异步方法，当某个执行线程执行了真正的绑定操作后，那个执行线程一定会标记这个 `future` 为成功（我们假定 bind 会成功），然后这里的 `sync()` 方法（main 线程）就会返回了。

> 如果 bind(port) 失败，我们知道，sync() 方法会将异常抛出来，然后就会执行到 finally 块了。 

一旦绑定端口 bind 成功，进入下面一行，`f.channel()` 方法会返回该 future 关联的 channel。

`channel.closeFuture()` 也会返回一个 `ChannelFuture`，然后调用了 `sync()` 方法，这个 `sync() `方法返回的条件是：**有其他的线程关闭了 NioServerSocketChannel**，往往是因为需要停掉服务了，然后那个线程会设置 future 的状态（ `setSuccess(result)` 或 `setFailure(cause)` ），这个 `sync()` 方法才会返回。

## 参考

[Netty 源码解析（三）: Netty 的 Future 和 Promise](https://javadoop.com/post/netty-part-3)

[自顶向下深入分析Netty（五）--Future](https://www.jianshu.com/p/a06da3256f0c)
