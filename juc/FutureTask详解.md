## 1. 前言

FutureTask 为 Future 提供了基础实现，如获取任务执行结果(get)和取消任务(cancel)等。如果任务尚未完成，获取任务执行结果时将会阻塞。一旦执行结束，任务就不能被重启或取消(除非使用runAndReset执行计算)。FutureTask 常用来封装 Callable 和 Runnable，也可以作为一个任务提交到线程池中执行。除了作为一个独立的类之外，此类也提供了一些功能性函数供我们创建自定义 task 类使用。FutureTask 的线程安全由CAS来保证。

## 2. 类关系

<img src="http://blog-1259650185.cosbj.myqcloud.com/img/202201/09/1641739708.png" alt="img" style="zoom:50%;" />

```java
public interface RunnableFuture<V> extends Runnable, Future<V> {
    void run();
}
```

`FutureTask` 实现了 `RunnableFuture` 接口，而 `RunnableFuture` 接口又分别实现了 `Runnable` 和 `Future` 接口，所以可以推断出 `FutureTask` 具有这两种接口的特性：

- 有 `Runnable` 特性，所以可以用在 `ExecutorService` 中配合线程池使用。
- 有 `Future` 特性，所以可以从中获取到执行结果。

## 3. Callable接口

```java
@FunctionalInterface
public interface Callable<V> {
    
    V call() throws Exception;
}
```

Callable 是一个泛型接口，里面只有一个 `call()` 方法，**该方法可以返回泛型值 V** ，使用起来就像这样：

```java
Callable<String> callable = () -> {
    // Perform some computation
    Thread.sleep(2000);
    return "Return some result";
};
```

## 4. Future接口

**Java 1.5** 提供了 `java.util.concurrent.Future` 接口，处理异步调用和并发处理时非常有用，今天我们来研究一下这个接口。在 **JDK** 中对 `Future` 是这么描述的：

> A Future represents the result of an asynchronous computation. Methods are provided to check if the computation is complete, to wait for its completion, and to retrieve the result of the computation. The result can only be retrieved using method get when the computation has completed, blocking if necessary until it is ready. Cancellation is performed by the cancel method. Additional methods are provided to determine if the task completed normally or was cancelled. Once a computation has completed, the computation cannot be cancelled. If you would like to use a Future for the sake of cancellability but not provide a usable result, you can declare types of the form Future<?> and return null as a result of the underlying task.

大致意思就是：`Future` 是异步计算结果的容器接口，它提供了在等待异步计算完成时检查计算是否完成的状态，并在异步计算完成后获取计算结果而且只能通过 `get` 方法获取结果，如果异步计算没有完成则阻塞，当然你可以在异步计算完成前通过 `cancel` 方法取消，如果异步计算被取消则标记一个取消的状态。如果希望异步计算可以被取消而且不提供可用的计算结果，如果为了可取消性而使用 Future 但又不提供可用的结果，则可以声明 `Future<?>` 形式类型、并返回 `null` 作为底层任务的结果。

Future 又是一个接口，里面只有五个方法：

```java
// 取消任务
boolean cancel(boolean mayInterruptIfRunning);

// 获取任务执行结果
V get() throws InterruptedException, ExecutionException;

// 获取任务执行结果，带有超时时间限制
V get(long timeout, TimeUnit unit) throws InterruptedException, ExecutionException,  TimeoutException;

// 判断任务是否已经取消
boolean isCancelled();

// 判断任务是否已经结束
boolean isDone();
```

- cancel：**boolean cancel(boolean mayInterruptIfRunning)** 调用该方法将试图取消对任务的执行。如果任务已经完成了、已取消、无法取消这种尝试会失败。当该方法调用时任务还没有开始，方法调用成功而且任务将不会再执行。如果任务已经启动，则 `mayInterruptIfRunning` 参数确定是否执行此任务的线程应该以试图停止任务被中断，若`mayInterruptIfRunning`为`true`，则会立即中断执行任务的线程并返回`true`，若`mayInterruptIfRunning`为`false`，则会返回`true`且不会中断任务执行线程。此方法返回后调用`isDone` 方法将返回 `true` 。后续调用 `isCancelled` 总是返回第一次调用的返回值。

- isCancelled：**boolean isCancelled()** 如果任务在完成前被取消，将返回 `true`。

  > 请注意任务取消是一种主动的行为。

- isDone：**boolean isDone()** 任务已经结束，在任务完成、任务取消、任务异常的情况下都返回 `true` 。

- get：**V get() throws InterruptedException, ExecutionException** 调用此方法会在获取计算结果前等待。一但计算完毕将立刻返回结果。它还有一个重载方法 **V get(long timeout, TimeUnit unit)** 在单位时间内没有返回任务计算结果将超时，任务将立即结束。

## 5. 源码分析

实现 Runnable 接口形式创建的线程并不能获取到返回值，而实现 Callable 的才可以，所以 FutureTask 想要获取返回值，必定是和 Callable 有联系的，这个推断一点都没错，从构造方法中就可以看出来：

```java
public FutureTask(Callable<V> callable) {
    if (callable == null)
        throw new NullPointerException();
    this.callable = callable;
    this.state = NEW;       // ensure visibility of callable
}
```

即便在 FutureTask 构造方法中传入的是 Runnable 形式的线程，该构造方法也会通过 `Executors.callable` 工厂方法将其转换为 Callable 类型：

```java
public FutureTask(Runnable runnable, V result) {
    this.callable = Executors.callable(runnable, result);
    this.state = NEW;       // ensure visibility of callable
}
```

但是 FutureTask 实现的是 Runnable 接口，也就是只能重写 run() 方法，run() 方法又没有返回值，那问题来了：

> - FutureTask 是怎样在 run() 方法中获取返回值的？
> - 它将返回值放到哪里了？
> - get() 方法又是怎样拿到这个返回值的呢？

我们来看一下 run() 方法（关键代码都已标记注释）：

```java
public void run() {
  	// 如果状态不是 NEW，说明任务已经执行过或者已经被取消，直接返回
  	// 如果状态是 NEW，则尝试把执行线程保存在 runnerOffset（runner字段），如果赋值失败，则直接返回
    if (state != NEW ||
        !UNSAFE.compareAndSwapObject(this, runnerOffset,
                                     null, Thread.currentThread()))
        return;
    try {
      	// 获取构造函数传入的 Callable 值
        Callable<V> c = callable;
        if (c != null && state == NEW) {
            V result;
            boolean ran;
            try {
              	// 正常调用 Callable 的 call 方法就可以获取到返回值
                result = c.call();
                ran = true;
            } catch (Throwable ex) {
                result = null;
                ran = false;
              	// 保存 call 方法抛出的异常
                setException(ex);
            }
            if (ran)
              	// 保存 call 方法的执行结果
                set(result);
        }
    } finally {        
        runner = null;       
        int s = state;
      	// 如果任务被中断，则执行中断处理
        if (s >= INTERRUPTING)
            handlePossibleCancellationInterrupt(s);
    }
}
```

`run()` 方法没有返回值，至于 `run()` 方法是如何将 `call()` 方法的返回结果和异常都保存起来的呢？其实非常简单, 就是通过 set(result) 保存正常程序运行结果，或通过 setException(ex) 保存程序异常信息。

```java
/** The result to return or exception to throw from get() */
private Object outcome; // non-volatile, protected by state reads/writes

// 保存异常结果
protected void setException(Throwable t) {
    if (UNSAFE.compareAndSwapInt(this, stateOffset, NEW, COMPLETING)) {
        outcome = t;
        UNSAFE.putOrderedInt(this, stateOffset, EXCEPTIONAL); // final state
        finishCompletion();
    }
}

// 保存正常结果
protected void set(V v) {
  if (UNSAFE.compareAndSwapInt(this, stateOffset, NEW, COMPLETING)) {
    outcome = v;
    UNSAFE.putOrderedInt(this, stateOffset, NORMAL); // final state
    finishCompletion();
  }
}
```

`setException` 和 `set` 方法非常相似，都是将异常或者结果保存在 `Object` 类型的 `outcome` 变量中，`outcome` 是成员变量，就要考虑线程安全，所以他们要通过 CAS方式设置 outcome 变量的值，既然是在 CAS 成功后 更改 outcome 的值，这也就是 outcome 没有被 `volatile` 修饰的原因所在。

保存正常结果值（set方法）与保存异常结果值（setException方法）两个方法代码逻辑，唯一的不同就是 CAS 传入的 state 不同。我们上面提到，state 多数用于控制代码逻辑，FutureTask 也是这样，所以要搞清代码逻辑，我们需要先对 state 的状态变化有所了解。

```java
 /*
 *
 * Possible state transitions:
 * NEW -> COMPLETING -> NORMAL  //执行过程顺利完成
 * NEW -> COMPLETING -> EXCEPTIONAL //执行过程出现异常
 * NEW -> CANCELLED // 执行过程中被取消
 * NEW -> INTERRUPTING -> INTERRUPTED //执行过程中，线程被中断
 */
private volatile int state;
private static final int NEW          = 0;
private static final int COMPLETING   = 1;
private static final int NORMAL       = 2;
private static final int EXCEPTIONAL  = 3;
private static final int CANCELLED    = 4;
private static final int INTERRUPTING = 5;
private static final int INTERRUPTED  = 6;
```

7种状态，千万别慌，整个状态流转其实只有四种线路。

FutureTask 对象被创建出来，state 的状态就是 NEW 状态，从上面的构造函数中你应该已经发现了，四个最终状态 NORMAL ，EXCEPTIONAL ， CANCELLED ， INTERRUPTED 也都很好理解，两个中间状态稍稍有点让人困惑:

- COMPLETING：任务已经执行完成或者执行任务的时候发生异常，但是任务执行结果或者异常原因还没有保存到outcome字段的时候，状态会从NEW变更到COMPLETING。但是这个状态会时间会比较短，属于中间状态。
- INTERRUPTING：通过 cancel(true) 方法正在中断线程的时候，但是还没有中断任务执行线程之前，这也是一个中间状态。

总的来说，这两个中间状态都表示一种瞬时状态，我们将几种状态图形化展示一下：

<img src="http://blog-1259650185.cosbj.myqcloud.com/img/202201/09/1641742470.png" alt="img" style="zoom:50%;" />

我们知道了 run() 方法是如何保存结果的，以及知道了将正常结果/异常结果保存到了 outcome 变量里，那就需要看一下 FutureTask 是如何通过 get() 方法获取结果的：

```java
public V get() throws InterruptedException, ExecutionException {
    int s = state;
  	// 如果 state 还没到 set outcome 结果的时候，则调用 awaitDone() 方法阻塞自己
    if (s <= COMPLETING)
        s = awaitDone(false, 0L);
  	// 返回结果
    return report(s);
}

//返回执行结果或抛出异常
private V report(int s) throws ExecutionException {
    Object x = outcome;
    if (s == NORMAL)
        return (V)x;
    if (s >= CANCELLED)
        throw new CancellationException();
    throw new ExecutionException((Throwable)x);
}
```

awaitDone 方法是 FutureTask 最核心的一个方法。

```java
// get 方法支持超时限制，如果没有传入超时时间，则接受的参数是 false 和 0L
// 有等待就会有队列排队或者可响应中断，从方法签名上看有 InterruptedException，说明该方法这是可以被中断的
private int awaitDone(boolean timed, long nanos)
    throws InterruptedException {
  	// 计算等待截止时间
    final long deadline = timed ? System.nanoTime() + nanos : 0L;
    WaitNode q = null;
    boolean queued = false;
    for (;;) {
      	// 如果当前线程被中断，如果是，则在等待对立中删除该节点，并抛出 InterruptedException
        if (Thread.interrupted()) {
            removeWaiter(q);
            throw new InterruptedException();
        }

        int s = state;
      	// 状态大于 COMPLETING 说明已经达到某个最终状态（正常结束/异常结束/取消）
      	// 把 thread 只为空，并返回结果
        if (s > COMPLETING) {
            if (q != null)
                q.thread = null;
            return s;
        }
      	// 如果是COMPLETING 状态（中间状态），表示任务已结束，但 outcome 赋值还没结束，这时主动让出执行权，让其他线程优先执行（只是发出这个信号，至于是否别的线程执行一定会执行可是不一定的）
        else if (s == COMPLETING) // cannot time out yet
            Thread.yield();
      	// 等待节点为空
        else if (q == null)
          	// 将当前线程构造节点
            q = new WaitNode();
      	// 如果还没有入队列，则把当前节点加入waiters首节点并替换原来waiters
        else if (!queued)
            queued = UNSAFE.compareAndSwapObject(this, waitersOffset,
                                                 q.next = waiters, q);
      	// 如果设置超时时间
        else if (timed) {
            nanos = deadline - System.nanoTime();
          	// 时间到，则不再等待结果
            if (nanos <= 0L) {
                removeWaiter(q);
                return state;
            }
          	// 阻塞等待特定时间
            LockSupport.parkNanos(this, nanos);
        }
        else
          	// 挂起当前线程，知道被其他线程唤醒
            LockSupport.park(this);
    }
}

// 如果线程被中断，首先清除中断状态，调用removeWaiter移除等待节点，然后抛出InterruptedException
private void removeWaiter(WaitNode node) {
    if (node != null) {
        node.thread = null; // 首先置空线程
        retry:
        for (;;) {          // restart on removeWaiter race
            // 依次遍历查找
            for (WaitNode pred = null, q = waiters, s; q != null; q = s) {
                s = q.next;
                if (q.thread != null)
                    pred = q;
                else if (pred != null) {
                    pred.next = s;
                    if (pred.thread == null) // check for race
                        continue retry;
                }
                else if (!UNSAFE.compareAndSwapObject(this, waitersOffset,q, s)) // CAS 替换
                    continue retry;
            }
            break;
        }
    }
}
```

总的来说，进入这个方法，通常会经历三轮循环

1. 第一轮for循环，执行的逻辑是 `q == null`， 这时候会新建一个节点 q， 第一轮循环结束。
2. 第二轮for循环，执行的逻辑是 `!queue`，这个时候会把第一轮循环中生成的节点的 next 指针指向waiters，然后CAS的把节点q 替换waiters， 也就是把新生成的节点添加到waiters 中的首节点。如果替换成功，queued=true。第二轮循环结束。
3. 第三轮for循环，进行阻塞等待。要么阻塞特定时间，要么一直阻塞知道被其他线程唤醒。

对于第二轮循环，大家可能稍稍有点迷糊，我们前面说过，有阻塞，就会排队，有排队自然就有队列，FutureTask 内部同样维护了一个队列：

```java
/** Treiber stack of waiting threads */
private volatile WaitNode waiters;
```

说是等待队列，其实就是一个 Treiber 类型 stack，既然是 stack， 那就像手枪的弹夹一样（脑补一下子弹放入弹夹的情形），后进先出，所以刚刚说的第二轮循环，会把新生成的节点添加到 waiters stack 的首节点。

如果程序运行正常，通常调用 get() 方法，会将当前线程挂起，那谁来唤醒呢？自然是 run() 方法运行完会唤醒，设置返回结果（set方法）/异常的方法(setException方法) 两个方法中都会调用 finishCompletion 方法，该方法就会唤醒等待队列中的线程。

```java
private void finishCompletion() {
    // 已经 断言当前状态 肯定是已经开始执行任务了，即不是初始化 NEW 状态
    // assert state > COMPLETING;
    // 当前有线程挂起在等着拿结果
    for (WaitNode q; (q = waiters) != null;) {
        // 抢占线程 这里跟 for 结合的很巧妙 直接设置null 简单实用
        if (UNSAFE.compareAndSwapObject(this, waitersOffset, q, null)) {
          	// 不停的自旋 ，当然 LockSupport和Thread. interrupted搭配必须要自旋
            for (;;) {
                Thread t = q.thread;
                if (t != null) {
                    q.thread = null;
                  	// 唤醒等待队列中的线程
                    LockSupport.unpark(t);
                }
                WaitNode next = q.next;
                if (next == null)
                    break;
                q.next = null; // unlink to help gc
                // 赋值以快速获取线程快速拿到结果  这里也很巧妙
                q = next;
            }
            break;
        }
    }

    done();

    callable = null;        // to reduce footprint
}
```

将一个任务的状态设置成终止态只有三种方法：

- set
- setException
- cancel

前两种方法已经分析完，接下来我们就看一下 `cancel` 方法。

查看 Future cancel()，该方法注释上明确说明三种 cancel 操作一定失败的情形：

1. 任务已经执行完成了。
2. 任务已经被取消过了。
3. 任务因为某种原因不能被取消。

其它情况下，cancel操作将返回true。值得注意的是，cancel操作返回 true 并不代表任务真的就是被取消, **这取决于发动cancel状态时，任务所处的状态**

- 如果发起cancel时任务还没有开始运行，则随后任务就不会被执行；
- 如果发起cancel时任务已经在运行了，则这时就需要看`mayInterruptIfRunning`参数了：
  - 如果mayInterruptIfRunning 为true, 则当前在执行的任务会被中断。
  - 如果mayInterruptIfRunning 为false, 则可以允许正在执行的任务继续运行，直到它执行完。

有了这些铺垫，看一下 cancel 代码的逻辑就秒懂了

```java
public boolean cancel(boolean mayInterruptIfRunning) {
   //如果正处于NEW状态，希望请求正在运行也希望中断就设置为INTERRUTPTING，否则直接设置CANCELLED
    if (!(state == NEW &&
          UNSAFE.compareAndSwapInt(this, stateOffset, NEW,
              mayInterruptIfRunning ? INTERRUPTING : CANCELLED)))
        return false;
    try {    // in case call to interrupt throws exception
      	// 需要中断任务执行线程
        if (mayInterruptIfRunning) {
            try {
                Thread t = runner;
              	// 中断线程
                if (t != null)
                    t.interrupt();
            } finally { // final state
              	// 修改为最终状态 INTERRUPTED
                UNSAFE.putOrderedInt(this, stateOffset, INTERRUPTED);
            }
        }
    } finally {
      	// 唤醒等待中的线程
        finishCompletion();
    }
    return true;
}
```

这里用了 **CAS** 原子操作来尝试进行取消。当前如果是 **NEW** 状态然后结合另一个策略参数 `mayInterruptIfRunning` 来看看是不是正在中断或者已经取消，决定是否进行取消操作。如果允许运行时中断首先将状态更新为 **INTERRUPTING** 状态，然后线程中断的会把状态更新为 **INTERRUPTED** 。

们再回头看 ExecutorService 的三个 submit 方法：

```java
<T> Future<T> submit(Runnable task, T result);
Future<?> submit(Runnable task);
<T> Future<T> submit(Callable<T> task);
```

第一个方法，逐层代码查看到这里：

```java
// Executors.java
static final class RunnableAdapter<T> implements Callable<T> {
    final Runnable task;
    final T result;
    RunnableAdapter(Runnable task, T result) {
        this.task = task;
        this.result = result;
    }
    public T call() {
        task.run();
        return result;
    }
}
```

可以看到，我们可以传进去一个 result，result 相当于主线程和子线程之间的桥梁，通过它主子线程可以共享数据。

第二个方法参数是 Runnable 类型参数，即便调用 get() 方法也是返回 null，所以仅是可以用来断言任务已经结束了，类似 Thread.join()

第三个方法参数是 Callable 类型参数，通过get() 方法可以明确获取 call() 方法的返回值。

## 参考

[ JUC线程池: FutureTask详解](https://www.pdai.tech/md/java/thread/java-thread-x-juc-executor-FutureTask.html)

[Java Future详解与使用](https://dayarch.top/p/java-future-and-callable.html)
