## 1. 前言

对于CountDownLatch，其他线程为游戏玩家，比如英雄联盟，主线程为控制游戏开始的线程。在所有的玩家都准备好之前，主线程是处于等待状态的，也就是游戏不能开始。当所有的玩家准备好之后，下一步的动作实施者为主线程，即开始游戏。

对于CyclicBarrier，假设有一家公司要全体员工进行团建活动，活动内容为翻越三个障碍物，每一个人翻越障碍物所用的时间是不一样的。但是公司要求所有人在翻越当前障碍物之后再开始翻越下一个障碍物，也就是所有人翻越第一个障碍物之后，才开始翻越第二个，以此类推。类比地，每一个员工都是一个“其他线程”。当所有人都翻越的所有的障碍物之后，程序才结束。而主线程可能早就结束了，这里我们不用管主线程。

它们之间主要的区别在于唤醒等待线程的时机。CountDownLatch 是在计数器减为0后，唤醒等待线程。CyclicBarrier 是在计数器（等待线程数）增长到指定数量后，再唤醒等待线程。

CyclicBarrier 的字面意思是“可重复使用的栅栏”或“周期性的栅栏”，总之不是用了一次就没用了的，CyclicBarrier 相比 CountDownLatch 来说，要简单很多，其源码没有什么高深的地方，它是 ReentrantLock 和 Condition 的组合使用。看如下示意图，CyclicBarrier 和 CountDownLatch 是不是很像，只是 CyclicBarrier 可以有不止一个栅栏，因为它的栅栏（Barrier）可以重复使用（Cyclic）。

<img src="http://blog-1259650185.cosbj.myqcloud.com/img/202201/05/1641312929.png" alt="cyclicbarrier-2" style="zoom:50%;" />

## 2. 实现原理

与 CountDownLatch 的实现方式不同，CyclicBarrier 并没有直接通过 AQS 实现同步功能，而是在重入锁 ReentrantLock 的基础上基于Condition 实现的。在 CyclicBarrier 中，线程访问 await 方法需先获取锁才能访问。在最后一个线程访问 await 方法前，其他线程进入 await 方法中后，会调用 Condition 的 await 方法进入等待状态。在最后一个线程进入 CyclicBarrier await 方法后，该线程将会调用 Condition 的 signalAll 方法唤醒所有处于等待状态中的线程。同时，最后一个进入 await 的线程还会重置 CyclicBarrier 的状态，使其可以重复使用。

下面用一张图来描绘下 CyclicBarrier 里面的一些概念，和它的基本使用流程：

<img src="http://blog-1259650185.cosbj.myqcloud.com/img/202201/05/1641313019.png" alt="cyclicbarrier-3" style="zoom:50%;" />

> 看图我们也知道了，CyclicBarrier 的源码最重要的就是 await() 方法了。

## 3. 源码分析

大家先把图看完，然后我们开始源码分析。

CyclicBarrier没有显示继承哪个父类或者实现哪个父接口, 所有AQS和重入锁不是通过继承实现的，而是通过组合实现的。

```java
public class CyclicBarrier {
    // 我们说了，CyclicBarrier 是可以重复使用的，我们把每次从开始使用到穿过栅栏当做"一代"，或者"一个周期"
  	// 当所有线程到达屏障后，generation 将会被更新，表示 CyclicBarrier 进入新的一个周期
    private static class Generation {
        boolean broken = false;
    }

    /** The lock for guarding barrier entry */
    private final ReentrantLock lock = new ReentrantLock();

    // CyclicBarrier 是基于 Condition 的
    // Condition 是“条件”的意思，CyclicBarrier 的等待线程通过 barrier 的“条件”是大家都到了栅栏上
    private final Condition trip = lock.newCondition();

    // 参与的线程数量
    private final int parties;

    // 如果设置了这个，代表越过栅栏之前，要执行相应的操作
    private final Runnable barrierCommand;

    // 当前所处的“代”
    private Generation generation = new Generation();

    // 还没有到栅栏的线程数，这个值初始为 parties，然后递减
    // 还没有到栅栏的线程数 = parties - 已经到栅栏的数量
    private int count;
		// 该构造方法可以指定关联该CyclicBarrier的线程数量，并且可以指定在所有线程都进入屏障后的执行动作，该执行动作由最后一个进行屏障的线程执行。
    public CyclicBarrier(int parties, Runnable barrierAction) {
        if (parties <= 0) throw new IllegalArgumentException();
        this.parties = parties;
        this.count = parties;
        this.barrierCommand = barrierAction;
    }
		// 该构造方法仅仅执行了关联该CyclicBarrier的线程数量，没有设置执行动作。
    public CyclicBarrier(int parties) {
        this(parties, null);
    }

```

首先，先看怎么开启新的一代：

```java
// 开启新的一代，当最后一个线程到达栅栏上的时候，调用这个方法来唤醒其他线程，同时初始化“下一代”
private void nextGeneration() {
    // 首先，需要唤醒所有的在栅栏上等待的线程
    trip.signalAll();
    // 更新 count 的值
    count = parties;
    // 重新生成“新一代”
    generation = new Generation();
}

// AbstractQueuedSynchronizer.java
public final void signalAll() {
    if (!isHeldExclusively()) // 不被当前线程独占，抛出异常
        throw new IllegalMonitorStateException();
    // 保存condition队列头节点
    Node first = firstWaiter;
    if (first != null) // 头节点不为空
        // 唤醒所有等待线程
        doSignalAll(first);
}
```

> 开启新的一代，类似于重新实例化一个 CyclicBarrier 实例

综合上面的分析可知，newGeneration函数的主要方法的调用如下：

![img](http://blog-1259650185.cosbj.myqcloud.com/img/202201/06/1641436637.png)

看看怎么打破一个栅栏：

```java
private void breakBarrier() {
    // 设置状态 broken 为 true
    generation.broken = true;
    // 重置 count 为初始值 parties
    count = parties;
    // 唤醒所有已经在等待的线程
    trip.signalAll();
}
```

可以看到，此函数也调用了AQS的signalAll方法，由signalAll方法提供支持。

这两个方法之后用得到，现在开始分析最重要的等待通过栅栏方法 await 方法：

```java
// 不带超时机制
public int await() throws InterruptedException, BrokenBarrierException {
    try {
        return dowait(false, 0L);
    } catch (TimeoutException toe) {
        throw new Error(toe); // cannot happen
    }
}
// 带超时机制，如果超时抛出 TimeoutException 异常
public int await(long timeout, TimeUnit unit)
    throws InterruptedException,
           BrokenBarrierException,
           TimeoutException {
    return dowait(true, unit.toNanos(timeout));
}
```

继续往里看：

```java
private int dowait(boolean timed, long nanos)
        throws InterruptedException, BrokenBarrierException,
               TimeoutException {
    final ReentrantLock lock = this.lock;
    // 先要获取到锁，然后在 finally 中要记得释放锁
    // 我们知道 condition 的 await() 会释放锁，被 signal() 唤醒的时候需要重新获取锁
    lock.lock();
    try {
        final Generation g = generation;
        // 检查栅栏是否被打破，如果被打破，抛出 BrokenBarrierException 异常
        if (g.broken)
            throw new BrokenBarrierException();
        // 检查中断状态，如果中断了，抛出 InterruptedException 异常
        if (Thread.interrupted()) {
            breakBarrier();
            throw new InterruptedException();
        }
        // index 表示线程到达屏障的顺序，index = parties - 1 表明当前线程是第一个，
        // 到达屏障的。index = 0，表明当前线程是最有一个到达屏障的。
        // 注意到这里，这个是从 count 递减后得到的值
        int index = --count;

        // 如果等于 0，说明所有的线程都到栅栏上了，准备通过
        if (index == 0) {  // tripped
            boolean ranAction = false;
            try {
                // 如果在初始化的时候，指定了通过栅栏前需要执行的操作，在这里会得到执行
                final Runnable command = barrierCommand;
                if (command != null)
                    command.run();
                // 如果 ranAction 为 true，说明执行 command.run() 的时候，没有发生异常退出的情况
                ranAction = true;
                // 唤醒等待的线程，然后开启新的一代
                nextGeneration();
                return 0;
            } finally {
                if (!ranAction)
                    // 进到这里，说明执行指定操作的时候，发生了异常，那么需要打破栅栏
                    // 之前我们说了，打破栅栏意味着唤醒所有等待的线程，设置 broken 为 true，重置 count 为 parties
                    breakBarrier();
            }
        }

        // loop until tripped, broken, interrupted, or timed out
        // 如果是最后一个线程调用 await，那么上面就返回了
        // 下面的操作是给那些不是最后一个到达栅栏的线程执行的
      	// 线程运行到此处的线程都会被屏障挡住，并进入等待状态。
        for (;;) {
            try {
                // 如果带有超时机制，调用带超时的 Condition 的 await 方法等待，直到最后一个线程调用 await
                if (!timed)
                    trip.await();
                else if (nanos > 0L)
                    nanos = trip.awaitNanos(nanos);
            } catch (InterruptedException ie) {
                // 如果到这里，则表明本轮运行还未结束，说明等待的线程在 await（是 Condition 的 await）的时候被中断
                if (g == generation && ! g.broken) {
                    // 打破栅栏，唤醒其他线程
                    breakBarrier();
                    // 打破栅栏后，重新抛出这个 InterruptedException 异常给外层调用的方法
                    throw ie;
                } else {
                    // 到这里有两种可能。第一种： g != generation, 说明新的一代已经产生，即最后一个线程 await 执行完成，
                    // 那么此时没有必要再抛出 InterruptedException 异常，记录下来这个中断信息即可
                    // 第二种：是栅栏已经被打破了，表明已经有线程执行过 breakBarrier 方法了。
                    // 那么也不应该抛出 InterruptedException 异常，而是在稍后才抛出 BrokenBarrierException 异常
                    Thread.currentThread().interrupt();
                }
            }

            // 唤醒后，检查栅栏是否是“破的”
            if (g.broken)
                // 栅栏是“破的”，抛出异常
                throw new BrokenBarrierException();

            // 这个 for 循环除了异常，就是要从这里退出了
            // 我们要清楚，最后一个线程在执行完指定任务(如果有的话)，会调用 nextGeneration 来开启一个新的代
            // 然后释放掉锁，其他线程从 Condition 的 await 方法中得到锁并返回，然后到这里的时候，其实就会满足 g != generation 的
            // 那什么时候不满足呢？barrierCommand 执行过程中抛出了异常，那么会执行打破栅栏操作，
            // 设置 broken 为true，然后唤醒这些线程。这些线程会从上面的 if (g.broken) 这个分支抛 BrokenBarrierException 异常返回
            // 当然，还有最后一种可能，那就是 await 超时，此种情况不会从上面的 if (g.broken) 分支异常返回，也不会从这里 if (g != generation) 返回，会执行后面的代码
            if (g != generation)
                return index;

            // 如果醒来发现超时了，打破栅栏，抛出异常
            if (timed && nanos <= 0L) {
                breakBarrier();
                throw new TimeoutException();
            }
        }
    } finally {
        lock.unlock();
    }
}
```

好了，我想我应该讲清楚了吧，我好像几乎没有漏掉任何一行代码吧？

下面开始收尾工作。

首先，我们看看怎么得到有多少个线程到了栅栏上，处于等待状态：

```java
public int getNumberWaiting() {
    final ReentrantLock lock = this.lock;
    lock.lock();
    try {
        return parties - count;
    } finally {
        lock.unlock();
    }
}
```

判断一个栅栏是否被打破了，这个很简单，直接看 broken 的值即可：

```java
public boolean isBroken() {
    final ReentrantLock lock = this.lock;
    lock.lock();
    try {
        return generation.broken;
    } finally {
        lock.unlock();
    }
}
```

前面我们在说 await 的时候也几乎说清楚了，什么时候栅栏会被打破，总结如下：

- 中断，我们说了，如果某个等待的线程发生了中断，那么会打破栅栏，同时抛出 InterruptedException 异常；
- 超时，打破栅栏，同时抛出 TimeoutException 异常；
- 指定执行的操作抛出了异常，这个我们前面也说过。

最后，我们来看看怎么重置一个栅栏：

```java
public void reset() {
    final ReentrantLock lock = this.lock;
    lock.lock();
    try {
        breakBarrier();   // break the current generation
        nextGeneration(); // start a new generation
    } finally {
        lock.unlock();
    }
}
```

我们设想一下，如果初始化时，指定了线程 parties = 4，前面有 3 个线程调用了 await 等待，在第 4 个线程调用 await 之前，我们调用 reset 方法，那么会发生什么？

首先，打破栅栏，那意味着所有等待的线程（3个等待的线程）会唤醒，await 方法会通过抛出 BrokenBarrierException 异常返回。然后开启新的一代，重置了 count 和 generation，相当于一切归零了。

## 4. 和CountDonwLatch再对比

- CountDownLatch减计数，CyclicBarrier加计数。
- CountDownLatch是一次性的，CyclicBarrier可以重用。
- CountDownLatch和CyclicBarrier都有让多个线程等待同步然后再开始下一步动作的意思，但是CountDownLatch的下一步的动作实施者是主线程，具有不可重复性；而CyclicBarrier的下一步动作实施者还是“其他线程”本身，具有往复多次实施动作的特点。

## 参考

[一行一行源码分析清楚 AbstractQueuedSynchronizer (三)](https://javadoop.com/post/AbstractQueuedSynchronizer-3)

[JUC工具类: CyclicBarrier详解](https://www.pdai.tech/md/java/thread/java-thread-x-juc-tool-cyclicbarrier.html)

[Java 线程同步组件 CountDownLatch 与 CyclicBarrier 原理分析](https://www.tianxiaobo.com/2018/05/10/Java-%E7%BA%BF%E7%A8%8B%E5%90%8C%E6%AD%A5%E7%BB%84%E4%BB%B6-CountDownLatch-%E4%B8%8E-CyclicBarrier-%E5%8E%9F%E7%90%86%E5%88%86%E6%9E%90/)
