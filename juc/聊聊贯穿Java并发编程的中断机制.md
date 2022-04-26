## 1. 前言

在学习/编写并发程序时，总会听到/看到如下词汇：

- 线程被中断或抛出InterruptedException
- 设置了中断标识
- 清空了中断标识
- 判断线程是否被中断

在 Java Thread 类又提供了长相酷似，让人傻傻分不清的三个方法来处理并发中断问题：

- `interrupt()`
- `interrupted()`
- `isInterrupted()`

## 2. 什么是中断机制？

在多线程编程中，中断是一种【协同】机制，怎么理解这么高大上的词呢？就是女朋友叫你吃饭，你收到了中断游戏通知，**但是否马上放下手中的游戏去吃饭看你心情** 。在程序中怎样演绎这个心情就看具体的业务逻辑了，Java 的中断机制就是这么简单。

## 3. 为什么会有中断机制？

中断是一种协同机制，我觉得就是解决【当局者迷】的状况。

现实中，你努力忘我没有昼夜的工作，如果再没有人告知你中断，你身体是吃不消的。

在多线程的场景中，有的线程可能迷失在怪圈无法自拔（自旋浪费资源），这时就可以用其他线程在**恰当**的时机给它个中断通知，被“中断”的线程可以选择在**恰当**的时机选择跳出怪圈，最大化的利用资源。

那程序中如何中断？怎样识别是否中断？又如何处理中断呢？这就与上文提到的三个方法有关了。

## 4. interrupt() VS isInterrupted() VS interrupted()

Java 的每个线程对象里都有一个 boolean 类型的标识，代表是否有中断请求，可你寻遍 Thread 类你也不会找到这个标识，因为这是通过底层 native 方法实现的。

### 4.1 interrupt()

interrupt() 方法是 **唯一一个** 可以将上面提到中断标志设置为 true 的方法，从这里可以看出，这是一个 Thread 类 public 的对象方法，所以可以推断出任何线程对象都可以调用该方法，进一步说明就是可以**一个线程 interrupt 其他线程，也可以 interrupt 自己**。其中，中断标识的设置是通过 native 方法 `interrupt0` 完成的。

```java
public void interrupt() {
    if (this != Thread.currentThread())
        checkAccess();

    synchronized (blockerLock) {
        Interruptible b = blocker;
        if (b != null) {
            interrupt0();           // Just to set the interrupt flag
            b.interrupt(this);
            return;
        }
    }
    interrupt0();
}
```

在 Java 中，线程被中断的反应是不一样的，脾气不好的直接就抛出了 `InterruptedException()` 。

```java
/**
 * Interrupts this thread.
 *
 * ......
 *
 * <p> If this thread is blocked in an invocation of the {@link
 * Object#wait() wait()}, {@link Object#wait(long) wait(long)}, or {@link
 * Object#wait(long, int) wait(long, int)} methods of the {@link Object}
 * class, or of the {@link #join()}, {@link #join(long)}, {@link
 * #join(long, int)}, {@link #sleep(long)}, or {@link #sleep(long, int)},
 * methods of this class, then its interrupt status will be cleared and it
 * will receive an {@link InterruptedException}.
 *
 */
```

该方法注释上写的很清楚，当线程被阻塞在：

1. Object 类的 wait()、wait(long)、wait(long, int)
2. Thread 类的 join()、join(long)、join(long, int)
3. Thread 类的 sleep(long)、sleep(long, int)

这些方法时，如果被中断，就会抛出 InterruptedException 受检异常（也就是必须要求我们 catch 进行处理的）。即如果线程阻塞在这些方法上（我们知道，这些方法会让当前线程阻塞），这个时候如果其他线程对这个线程进行了中断，那么这个线程会从这些方法中立即返回，抛出 InterruptedException 异常，同时重置中断状态为 false。

还有就是，实现了 InterruptibleChannel 接口的类中的一些 I/O 阻塞操作，如 DatagramChannel 中的 connect 方法和 receive 方法等

> 如果线程阻塞在这里，中断线程会导致这些方法抛出 ClosedByInterruptException 并重置中断状态。

最后还有，Selector 中的 select 方法。

> 一旦中断，方法立即返回。

对于以上 3 种情况是最特殊的，因为他们能自动感知到中断（这里说自动，当然也是基于底层实现），**并且在做出相应的操作后都会重置中断状态为 false**。

那是不是只有以上 3 种方法能自动感知到中断呢？不是的，如果线程阻塞在 LockSupport.park(Object obj) 方法，也叫挂起，这个时候的中断也会导致线程唤醒，但是唤醒后不会重置中断状态，所以唤醒后去检测中断状态将是 true。

熟悉 JUC 的朋友可能知道，其实被中断抛出 InterruptedException 的远远不止这几个方法，比如：

```java
// BlockingQueue.java
boolean offer(E e, long timeout, TimeUnit unit) throws InterruptedException;
E take() throws InterruptedException;
```

反向推理，这些可能阻塞的方法如果声明有 `throws InterruptedException` ， 也就暗示我们它们是可中断的。

调用 interrput() 方法后，中断标识就被设置为 true 了，那我们怎么利用这个中断标识，来判断某个线程中断标识到底什么状态呢？

### 4.2 isInterrupted()

```java
public boolean isInterrupted() {
    return isInterrupted(false);
}

private native boolean isInterrupted(boolean ClearInterrupted);
```

这个方法名起的非常好，因为比较符合我们 bean boolean 类型字段的 get 方法规范，没错，该方法就是返回中断标识的结果：

- true：线程被中断，
- false：线程没被中断或被清空了中断标识（如何清空我们一会儿看）

拿到这个标识后，线程就可以判断这个标识来执行后续的逻辑了。有起名好的，也有起名不好的，就是下面这个方法。

### 4.3 interrupted()

按照常规翻译，过去时时态，这就是“被打断了/被打断的”，其实和上面的 isInterrupted() 方法差不多，两个方法都是调用 `private` 的 isInterrupted() 方法， 唯一差别就是会清空中断标识（这是从方法名中怎么也看不出来的）。

```java
public static boolean interrupted() {
    return currentThread().isInterrupted(true);
}
```

因为调用该方法，会返回当前中断标识，同时会清空中断标识，就有了那一段有点让人迷惑的方法注释：

<img src="http://blog-1259650185.cosbj.myqcloud.com/img/202112/31/1640939481.png" alt="interrupted" style="zoom:67%;" />

来段程序你就会明白上面注释的意思了：

```java
Thread.currentThread().isInterrupted(); // true
Thread.interrupted() // true，返回true后清空了中断标识将其置为 false
Thread.currentThread().isInterrupted(); // false
Thread.interrupted() // false
```

这个方法总觉得很奇怪，现实中有什么用呢？

> 当你可能要被大量中断并且你想确保只处理一次中断时，就可以使用这个方法了。

该方法在 JDK 源码中应用也非常多，比如：

```java
// CompletableFuture.java
public boolean isReleasable() {
    if (thread == null)
        return true;
    if (Thread.interrupted()) {
        int i = interruptControl;
        interruptControl = -1;
        if (i > 0)
            return true;
    }
    if (deadline != 0L &&
        (nanos <= 0L || (nanos = deadline - System.nanoTime()) <= 0L)) {
        thread = null;
        return true;
    }
    return false;
}
```

相信到这里你已经能明确分辨三胞胎都是谁，并发挥怎样的作用了，那么有哪些场景我们可以使用中断机制呢？

## 5. 中断机制的使用场景

通常，中断的使用场景有以下几个：

- 点击某个桌面应用中的关闭按钮时（比如你关闭 IDEA，不保存数据直接中断好吗？）；
- 某个操作超过了一定的执行时间限制需要中止时；
- 多个线程做相同的事情，只要一个线程成功其它线程都可以取消时；
- 一组线程中的一个或多个出现错误导致整组都无法继续时；

因为中断是一种协同机制，提供了更优雅中断方式，也提供了更多的灵活性，所以当遇到如上场景等，我们就可以考虑使用中断机制了。

## 6. 使用中断机制有哪些注意事项

其实使用中断机制无非就是注意上面说的两项内容：

1. 中断标识
2. InterruptedException

前浪已经将其总结为两个通用原则，我们后浪直接站在肩膀上用就可以了，来看一下这两个原则是什么：

### 原则-1

> 如果遇到的是可中断的阻塞方法, 并抛出 InterruptedException，可以继续向方法调用栈的上层抛出该异常；如果检测到中断，则可清除中断状态并抛出 InterruptedException，使当前方法也成为一个可中断的方法。

### 原则-2

> 若有时候不太方便在方法上抛出 InterruptedException，比如要实现的某个接口中的方法签名上没有 throws InterruptedException，这时就可以捕获可中断方法的 InterruptedException 并通过 Thread.currentThread.interrupt() 来重新设置中断状态。

再通过个例子来加深一下理解：

> 本意是当前线程被中断之后，退出while(true),  你觉得代码有问题吗？（先不要向下看）

```java
Thread th = Thread.currentThread();
while(true) {
  if(th.isInterrupted()) {
    break;
  }
  // 省略业务代码
  try {
    Thread.sleep(100);
  }catch (InterruptedException e){
    e.printStackTrace();
  }
}
```

打开 Thread.sleep 方法：

<img src="http://blog-1259650185.cosbj.myqcloud.com/img/202112/31/1640940908.png" alt="InterruptedException" style="zoom:50%;" />

sleep 方法抛出 InterruptedException后，中断标识也被清空置为 false，**我们在catch 没有通过调用 th.interrupt() 方法再次将中断标识置为 true，这就导致无限循环了**。

AQS 的做法很值得我们借鉴，我们知道 ReentrantLock 有两种 lock 方法：

```java
public void lock() {
    sync.lock();
}

public void lockInterruptibly() throws InterruptedException {
    sync.acquireInterruptibly(1);
}
```

前面我们提到过，lock() 方法不响应中断。如果 thread1 调用了 lock() 方法，过了很久还没抢到锁，这个时候 thread2 对其进行了中断，thread1 是不响应这个请求的，它会继续抢锁，当然它不会把“被中断”这个信息扔掉。我们可以看以下代码：

```java
public final void acquire(int arg) {
    if (!tryAcquire(arg) &&
        acquireQueued(addWaiter(Node.EXCLUSIVE), arg))
        // 我们看到，这里也没做任何特殊处理，就是记录下来中断状态。
        // 这样，如果外层方法需要去检测的时候，至少我们没有把这个信息丢了
        selfInterrupt();// Thread.currentThread().interrupt();
}
```

而对于 lockInterruptibly() 方法，因为其方法上面有 `throws InterruptedException` ，这个信号告诉我们，如果我们要取消线程抢锁，直接中断这个线程即可，它会立即返回，抛出 InterruptedException 异常。

这两个原则很好理解。总的来说，我们应该留意 InterruptedException，当我们捕获到该异常时，绝不可以默默的吞掉它，什么也不做，因为这会导致上层调用栈什么信息也获取不到。其实在编写程序时，捕获的任何受检异常我们都不应该吞掉。

## 7. InterruptedException 概述

它是一个特殊的异常，不是说 JVM 对其有特殊的处理，而是它的使用场景比较特殊。通常，我们可以看到，像 Object 中的 wait() 方法，ReentrantLock 中的 lockInterruptibly() 方法，Thread 中的 sleep() 方法等等，这些方法都带有 `throws InterruptedException`，我们通常称这些方法为阻塞方法（blocking method）。

阻塞方法一个很明显的特征是，它们需要花费比较长的时间（不是绝对的，只是说明时间不可控），还有它们的方法结束返回往往依赖于外部条件，如 wait 方法依赖于其他线程的 notify，lock 方法依赖于其他线程的 unlock等等。

当我们看到方法上带有 `throws InterruptedException` 时，我们就要知道，这个方法应该是阻塞方法，我们如果希望它能早点返回的话，我们往往可以通过中断来实现。 

除了几个特殊类（如 Object，Thread等）外，感知中断并提前返回是通过轮询中断状态来实现的。我们自己需要写可中断的方法的时候，就是通过在合适的时机（通常在循环的开始处）去判断线程的中断状态，然后做相应的操作（通常是方法直接返回或者抛出异常）。当然，我们也要看到，如果我们一次循环花的时间比较长的话，那么就需要比较长的时间才能**感知**到线程中断了。

## 8. JDK 中有哪些使用中断机制的地方呢？

中断机制贯穿整个并发编程中，这里只简单列觉大家经常会使用的，我们可以通过阅读JDK源码来进一步了解中断机制以及学习如何使用中断机制。

### 8.1 ThreadPoolExecutor

ThreadPoolExecutor 中的 shutdownNow 方法会遍历线程池中的工作线程并调用线程的 interrupt 方法来中断线程。

```java
public List<Runnable> shutdownNow() {
    List<Runnable> tasks;
    final ReentrantLock mainLock = this.mainLock;
    mainLock.lock();
    try {
        checkShutdownAccess();
        advanceRunState(STOP);
        interruptWorkers();
        tasks = drainQueue();
    } finally {
        mainLock.unlock();
    }
    tryTerminate();
    return tasks;
}


private void interruptWorkers() {
    final ReentrantLock mainLock = this.mainLock;
    mainLock.lock();
    try {
        for (Worker w : workers)
            w.interruptIfStarted();
    } finally {
        mainLock.unlock();
    }
}

void interruptIfStarted() {
    Thread t;
    if (getState() >= 0 && (t = thread) != null && !t.isInterrupted()) {
        try {
            t.interrupt();
        } catch (SecurityException ignore) {
        }
    }
}
```

### 8.2 FutureTask

FutureTask 中的 cancel 方法，如果传入的参数为 true，它将会在正在运行异步任务的线程上调用 interrupt 方法，如果正在执行的异步任务中的代码没有对中断做出响应，那么 cancel 方法中的参数将不会起到什么效果。

```java
public boolean cancel(boolean mayInterruptIfRunning) {
    if (!(state == NEW &&
          UNSAFE.compareAndSwapInt(this, stateOffset, NEW,
              mayInterruptIfRunning ? INTERRUPTING : CANCELLED)))
        return false;
    try {    // in case call to interrupt throws exception
        if (mayInterruptIfRunning) {
            try {
                Thread t = runner;
                if (t != null)
                    t.interrupt();
            } finally { // final state
                UNSAFE.putOrderedInt(this, stateOffset, INTERRUPTED);
            }
        }
    } finally {
        finishCompletion();
    }
    return true;
}
```

## 9. 总结

到这里你应该理解Java 并发编程中断机制的含义了，它是一种协同机制，和你先入为主的概念完全不一样。区分了三个相近方法，说明了使用场景以及使用原则，同时又给出JDK源码一些常见案例，相信你已经胸中有沟壑了。

## 参考

[聊聊贯穿Java并发编程的中断机制](https://mp.weixin.qq.com/s?__biz=MzkwNzI0MzQ2NQ==&mid=2247489004&idx=1&sn=9b8e2e4ec5bf44d7e8e0960dd09785b2&chksm=c0dd6f4af7aae65ca58ad68e0b44c87254326bc6cf3aaee3000a95e49ed46e4c7d792b7774f7&scene=178&cur_album_id=2197885342135959557#rd)
