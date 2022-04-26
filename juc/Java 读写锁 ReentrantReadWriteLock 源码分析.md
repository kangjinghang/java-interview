## 1. 简介

如果对 ReentrantLock 比较熟的话，那么当别人问你， ReentrantLock 是独占锁还是共享锁，你的第一反应就是: 独占锁。

ReentrantReadWriteLock 是在 ReentrantLock 的基础上做的优化，什么优化呢？ReentrantLock 就是不管操作是读操作还是写操作都会对资源进行加锁，但是聪明的你想想嘛，如果好几个操作都只是读的话，并没有让数据的状态发生改变，这样的话是不是可以允许多个读操作同时运行？这样去处理的话，相对来说是不是就提高了并发呢？

啥也不多说，咱们直接上个案例好吧。

## 2. 使用示例

下面这个例子非常实用，我是 Java doc 的搬运工：

```java
// 这是一个关于缓存操作的故事
class CachedData {
    Object data;
    volatile boolean cacheValid;
    // 读写锁实例
    final ReentrantReadWriteLock rwl = new ReentrantReadWriteLock();

    void processCachedData() {
        // 获取读锁
        rwl.readLock().lock();
        if (!cacheValid) { // 如果缓存过期了，或者为 null
            // 释放掉读锁，然后获取写锁 (后面会看到，没释放掉读锁就获取写锁，会发生死锁情况)
            rwl.readLock().unlock();
            rwl.writeLock().lock();

            try {
                if (!cacheValid) { // 重新判断，因为在等待写锁的过程中，可能前面有其他写线程执行过了
                    data = ...
                    cacheValid = true;
                }
                // 获取读锁 (持有写锁的情况下，是允许获取读锁的，称为 “锁降级”，反之不行。)
                rwl.readLock().lock();
            } finally {
                // 释放写锁，此时还剩一个读锁
                rwl.writeLock().unlock(); // Unlock write, still hold read
            }
        }

        try {
            use(data);
        } finally {
            // 释放读锁
            rwl.readLock().unlock();
        }
    }
}
```

ReentrantReadWriteLock 分为读锁和写锁两个实例，读锁是共享锁，可被多个线程同时使用，写锁是独占锁。持有写锁的线程可以继续获取读锁，反之不行。

下面再给出了一个使用ReentrantReadWriteLock的示例，源代码如下：

```java
import java.util.concurrent.locks.ReentrantReadWriteLock;

class ReadThread extends Thread {
    private ReentrantReadWriteLock rrwLock;
    
    public ReadThread(String name, ReentrantReadWriteLock rrwLock) {
        super(name);
        this.rrwLock = rrwLock;
    }
    
    public void run() {
        System.out.println(Thread.currentThread().getName() + " trying to lock");
        try {
            rrwLock.readLock().lock();
            System.out.println(Thread.currentThread().getName() + " lock successfully");
            Thread.sleep(5000);        
        } catch (InterruptedException e) {
            e.printStackTrace();
        } finally {
            rrwLock.readLock().unlock();
            System.out.println(Thread.currentThread().getName() + " unlock successfully");
        }
    }
}

class WriteThread extends Thread {
    private ReentrantReadWriteLock rrwLock;
    
    public WriteThread(String name, ReentrantReadWriteLock rrwLock) {
        super(name);
        this.rrwLock = rrwLock;
    }
    
    public void run() {
        System.out.println(Thread.currentThread().getName() + " trying to lock");
        try {
            rrwLock.writeLock().lock();
            System.out.println(Thread.currentThread().getName() + " lock successfully");    
        } finally {
            rrwLock.writeLock().unlock();
            System.out.println(Thread.currentThread().getName() + " unlock successfully");
        }
    }
}

public class ReentrantReadWriteLockDemo {
    public static void main(String[] args) {
        ReentrantReadWriteLock rrwLock = new ReentrantReadWriteLock();
        ReadThread rt1 = new ReadThread("rt1", rrwLock);
        ReadThread rt2 = new ReadThread("rt2", rrwLock);
        WriteThread wt1 = new WriteThread("wt1", rrwLock);
        rt1.start();
        rt2.start();
        wt1.start();
    } 
}
```

运行结果(某一次)：

```jade
rt1 trying to lock
rt2 trying to lock
wt1 trying to lock
rt1 lock successfully
rt2 lock successfully
rt1 unlock successfully
rt2 unlock successfully
wt1 lock successfully
wt1 unlock successfully
```

说明：程序中生成了一个ReentrantReadWriteLock对象，并且设置了两个读线程，一个写线程。根据结果，可能存在如下的时序图。

![img](http://blog-1259650185.cosbj.myqcloud.com/img/202201/09/1641662391.png)

- rt1线程执行rrwLock.readLock().lock操作，主要的方法调用如下：

​	

![img](http://blog-1259650185.cosbj.myqcloud.com/img/202201/09/1641662476.png)

​		说明：此时，AQS的状态state为2^16 次方，即表示此时读线程数量为1。

- rt2线程执行rrwLock.readLock().lock操作，主要的方法调用如下：

  ![img](http://blog-1259650185.cosbj.myqcloud.com/img/202201/09/1641662502.png)

  说明：此时，AQS的状态state为2 * 2^16次方，即表示此时读线程数量为2。

- wt1线程执行rrwLock.writeLock().lock操作，主要的方法调用如下：

  ![img](http://blog-1259650185.cosbj.myqcloud.com/img/202201/09/1641662563.png)

  说明：此时，在同步队列Sync queue中存在两个结点，并且wt1线程会被禁止运行。

- rt1线程执行rrwLock.readLock().unlock操作，主要的方法调用如下：

  ![img](http://blog-1259650185.cosbj.myqcloud.com/img/202201/09/1641662665.png)

  说明：此时，AQS的state为2^16次方，表示还有一个读线程。

- rt2线程执行rrwLock.readLock().unlock操作，主要的方法调用如下：

  ![img](http://blog-1259650185.cosbj.myqcloud.com/img/202201/09/1641662691.png)

  说明：当rt2线程执行unlock操作后，AQS的state为0，并且wt1线程将会被unpark，其获得CPU资源就可以运行。

- wt1线程获得CPU资源，继续运行，需要恢复。由于之前acquireQueued方法中的parkAndCheckInterrupt方法中被禁止的，所以，恢复到parkAndCheckInterrupt方法中，主要的方法调用如下：

  ![img](http://blog-1259650185.cosbj.myqcloud.com/img/202201/09/1641662718.png)

  说明：最后，sync queue队列中只有一个结点，并且头节点尾节点均指向它，AQS的state值为1，表示此时有一个写线程。

- wt1执行rrwLock.writeLock().unlock操作，主要的方法调用如下：

  ![](http://blog-1259650185.cosbj.myqcloud.com/img/202201/09/1641662749.png)

  说明：此时，AQS的state为0，表示没有任何读线程或者写线程了。并且Sync queue结构与上一个状态的结构相同，没有变化。

## 3. 总览

我们要先看清楚 ReentrantReadWriteLock 的大框架，然后再到源码细节。

ReentrantReadWriteLock有五个内部类，五个内部类之间也是相互关联的。内部类的关系如下图所示：

![img](http://blog-1259650185.cosbj.myqcloud.com/img/202201/09/1641661900.png)

如上图所示，Sync继承自AQS、NonfairSync继承自Sync类、FairSync继承自Sync类，ReadLock实现了Lock接口、WriteLock也实现了Lock接口。

首先，我们来看下 ReentrantReadWriteLock 的结构，它有好些嵌套类：

<img src="http://blog-1259650185.cosbj.myqcloud.com/img/202201/08/1641612073.png" alt="11" style="zoom: 50%;" />

大家先仔细看看这张图中的信息。然后我们把 ReadLock 和 WriteLock 的代码提出来一起看，清晰一些：

![12](http://blog-1259650185.cosbj.myqcloud.com/img/202201/08/1641614251.png)

很清楚了，ReadLock 和 WriteLock 中的方法都是通过 Sync 这个类来实现的。Sync 是 AQS 的子类，然后再派生了公平模式和不公平模式。

从它们调用的 Sync 方法，我们可以看到： **ReadLock 使用了共享模式，WriteLock 使用了独占模式**。

等等，**同一个 AQS 实例怎么可以同时使用共享模式和独占模式**？？？

这里给大家回顾下 AQS，我们横向对比下 AQS 的共享模式和独占模式：

![13](http://blog-1259650185.cosbj.myqcloud.com/img/202201/08/1641614358.png)

AQS 的精髓在于内部的属性 **state**：

1. 对于独占模式来说，通常就是 0 代表可获取锁，1 代表锁被别人获取了，重入例外。
2. 而共享模式下，每个线程都可以对 state 进行加减操作

也就是说，独占模式和共享模式对于 state 的操作完全不一样，那读写锁 ReentrantReadWriteLock 中是怎么使用 state 的呢？答案是**将 state 这个 32 位的 int 值分为高 16 位和低 16位，分别用于共享模式和独占模式**。

## 4. 源码分析

ReentrantReadWriteLock 的前面几行很简单，我们往下滑到 Sync 类，先来看下它的所有的属性：

```java
abstract static class Sync extends AbstractQueuedSynchronizer {
    // 下面这块说的就是将 state 一分为二，高 16 位用于共享模式，低16位用于独占模式
    static final int SHARED_SHIFT   = 16;
    static final int SHARED_UNIT    = (1 << SHARED_SHIFT);
    static final int MAX_COUNT      = (1 << SHARED_SHIFT) - 1;
  	// 值就是 65535 ，化成二进制就是 16 个 1
    static final int EXCLUSIVE_MASK = (1 << SHARED_SHIFT) - 1;
    // 取 c 的高 16 位值，代表读锁的获取次数(包括重入)，它的计算方式就是无符号右移 16 位，空位都以 0 来补齐
  	// 对于 sharedCount 来说，只要传进来的值不大于 65535 ，那么经过计算之后，值都是 0
    static int sharedCount(int c)    { return c >>> SHARED_SHIFT; }
    // 取 c 的低 16 位值，代表写锁的重入次数，因为写锁是独占模式
  	// 传进来 c 的值，和 16 位全为 1 做 “&” 运算的话，只有 1 & 1 才为 1 ，也就是说，传进来的 c 值经过这样转换之后，还是原来的值
    // 对于 exclusiveCount 来说，传进来的值是多少，经过计算之后还是多少
  	static int exclusiveCount(int c) { return c & EXCLUSIVE_MASK; }

    // 这个嵌套类的实例用来记录每个线程持有的读锁数量(读锁重入)
    static final class HoldCounter {
        // 持有的读锁数
        int count = 0;
        // 线程 id
        final long tid = getThreadId(Thread.currentThread());
    }

    // 本地线程计数器
    static final class ThreadLocalHoldCounter extends ThreadLocal<HoldCounter> {
        public HoldCounter initialValue() {
          	// 重写初始化方法，在没有进行set的情况下，获取的都是该HoldCounter值
            return new HoldCounter();
        }
    }
    /**
      * 组合使用上面两个类，用一个 ThreadLocal 来记录当前线程持有的读锁数量
      */ 
    private transient ThreadLocalHoldCounter readHolds;

    // 用于缓存，记录"最后一个获取读锁的线程"的读锁重入次数，
    // 所以不管哪个线程获取到读锁后，就把这个值占为已用，这样就不用到 ThreadLocal 中查询 map 了
    // 算不上理论的依据：通常读锁的获取很快就会伴随着释放，
    //   显然，在 获取->释放 读锁这段时间，如果没有其他线程获取读锁的话，此缓存就能帮助提高性能
    private transient HoldCounter cachedHoldCounter;

    // 第一个获取读锁的线程(并且其未释放读锁)，以及它持有的读锁数量
    private transient Thread firstReader = null;
    private transient int firstReaderHoldCount;

    Sync() {
        // 初始化 readHolds 这个 ThreadLocal 属性
        readHolds = new ThreadLocalHoldCounter();
        // 为了保证 readHolds 的内存可见性
        setState(getState()); // ensures visibility of readHolds
    }
    ...
}
```

1. state 的高 16 位代表读锁的获取次数，包括重入次数，获取到读锁一次加 1，释放掉读锁一次减 1。
2. state 的低 16 位代表写锁的获取次数，因为写锁是独占锁，同时只能被一个线程获得，所以它代表重入次数。
3. 每个线程都需要维护自己的 HoldCounter，记录该线程获取的读锁次数，这样才能知道到底是不是读锁重入，用 ThreadLocal 属性 **readHolds** 维护。
4. **cachedHoldCounter** 有什么用？其实没什么用，但能提升性能。将最后一次获取读锁的线程的 HoldCounter 缓存到这里，这样比使用 ThreadLocal 性能要好一些，因为 ThreadLocal 内部是基于 map 来查询的。但是 cachedHoldCounter 这一个属性毕竟只能缓存一个线程，所以它要起提升性能作用的依据就是：通常读锁的获取紧随着就是该读锁的释放。
5. **firstReader** 和 **firstReaderHoldCount** 有什么用？其实也没什么用，但是它也能提升性能。将"第一个"获取读锁的线程记录在 firstReader 属性中，这里的**第一个**不是全局的概念，等这个 firstReader 当前代表的线程释放掉读锁以后，会有后来的线程占用这个属性的。**firstReader 和 firstReaderHoldCount 使得在读锁不产生竞争的情况下，记录读锁重入次数非常方便快速**。
6. 如果一个线程使用了 firstReader，那么它就不需要占用 cachedHoldCounter。
7. 个人认为，读写锁源码中最让初学者头疼的就是这几个用于提升性能的属性了，使得大家看得云里雾里的。主要是因为 ThreadLocal 内部是通过一个 ThreadLocalMap 来操作的，会增加检索时间。而很多场景下，执行 unlock 的线程往往就是刚刚最后一次执行 lock 的线程，中间可能没有其他线程进行 lock。还有就是很多不怎么会发生读锁竞争的场景。

上面说了这么多，是希望能帮大家降低后面阅读源码的压力，大家也可以先看看后面的，然后再慢慢体会。

前面我们好像都只说读锁，完全没提到写锁，主要是因为写锁真的是简单很多，我也特地将写锁的源码放到了后面，我们先啃下最难的读锁先。

### 4.1 读锁获取

我们来看下读锁 ReadLock 的 lock 流程：

```java
// ReadLock
public void lock() {
    sync.acquireShared(1);
}
// AQS
public final void acquireShared(int arg) {
    if (tryAcquireShared(arg) < 0)
        doAcquireShared(arg);
}
```

然后我们就会进到 Sync 类的 tryAcquireShared 方法：

> 在 AQS 中，如果 tryAcquireShared(arg) 方法返回值小于 0 代表没有获取到共享锁(读锁)，大于 0 代表获取到
>
> 回顾 AQS 共享模式：tryAcquireShared 方法不仅仅在 acquireShared 的最开始被使用，这里是 try，也就可能会失败，如果失败的话，执行后面的 doAcquireShared，进入到阻塞队列，然后等待前驱节点唤醒。唤醒以后，还是会调用 tryAcquireShared 进行获取共享锁的。当然，唤醒以后再 try 是很容易获得锁的，因为这个节点已经排了很久的队了，组织是会照顾它的。
>
> 所以，你在看下面这段代码的时候，要想象到两种获取读锁的场景，一种是新来的，一种是排队排到它的。

```java
protected final int tryAcquireShared(int unused) {

    Thread current = Thread.currentThread();
    int c = getState();

    // exclusiveCount(c) 不等于 0，说明有线程持有写锁，
    //    而且不是当前线程持有写锁，那么当前线程获取读锁失败
    //         （另，如果持有写锁的是当前线程，是可以继续获取读锁的）
    if (exclusiveCount(c) != 0 &&
        getExclusiveOwnerThread() != current)
        return -1;

    // 读锁的获取次数
    int r = sharedCount(c);

    // 读锁获取是否需要被阻塞，稍后细说。为了进去下面的分支，假设这里不阻塞就好了
    if (!readerShouldBlock() &&
        // 判断是否会溢出 (2^16-1，没那么容易溢出的)
        r < MAX_COUNT &&
        // 下面这行 CAS 是将 state 属性的高 16 位加 1，低 16 位不变，如果成功就代表获取到了读锁
        compareAndSetState(c, c + SHARED_UNIT)) {

        // =======================
        //   进到这里就是获取到了读锁
        // =======================

        if (r == 0) {
            // r == 0 说明此线程是第一个获取读锁的，或者说在它前面获取读锁的都走光光了，它也算是第一个吧
            //  记录 firstReader 为当前线程，及其持有的读锁数量：1
            firstReader = current;
            firstReaderHoldCount = 1;
        } else if (firstReader == current) {
            // 进来这里，说明是 firstReader 重入获取读锁（这非常简单，count 加 1 结束）
            firstReaderHoldCount++;
        } else {
            // 前面我们说了 cachedHoldCounter 用于缓存最后一个获取读锁的线程
            // 如果 cachedHoldCounter 缓存的不是当前线程，设置为缓存当前线程的 HoldCounter
            HoldCounter rh = cachedHoldCounter;
            if (rh == null || rh.tid != getThreadId(current))
                cachedHoldCounter = rh = readHolds.get();
            else if (rh.count == 0) 
                // 到这里，那么就是 cachedHoldCounter 缓存的是当前线程，但是 count 为 0，
                // 大家可以思考一下：这里为什么要 set ThreadLocal 呢？(当然，答案肯定不在这块代码中)
                //   既然 cachedHoldCounter 缓存的是当前线程，
                //   当前线程肯定调用过 readHolds.get() 进行初始化 ThreadLocal
                readHolds.set(rh);

            // count 加 1
            rh.count++;
        }
        // return 大于 0 的数，代表获取到了共享锁
        return 1;
    }
    // 往下看
    return fullTryAcquireShared(current);
}
```

上面的代码中，要进入 if 分支，需要满足：readerShouldBlock() 返回 false，并且 CAS 要成功（我们先不要纠结 MAX_COUNT 溢出）。

那我们反向推，怎么样进入到最后的 fullTryAcquireShared：

- readerShouldBlock() 返回 true，2 种情况：

  - 在 FairSync 中说的是 hasQueuedPredecessors()，即阻塞队列中有其他元素在等待锁。

    > 也就是说，公平模式下，有人在排队呢，你新来的不能直接获取锁。

  - 在 NonFairSync 中说的是 apparentlyFirstQueuedIsExclusive()，即判断阻塞队列中 head 的第一个后继节点是否是来获取写锁的，如果是的话，让这个写锁先来，避免写锁饥饿。

    > 作者给写锁定义了更高的优先级，所以如果碰上获取写锁的线程**马上**就要获取到锁了，获取读锁的线程不应该和它抢。
    >
    > 如果 head.next 不是来获取写锁的，那么可以随便抢，因为是非公平模式，大家比比 CAS 速度。

- compareAndSetState(c, c + SHARED_UNIT) 这里 CAS 失败，存在竞争。可能是和另一个读锁获取竞争，当然也可能是和另一个写锁获取操作竞争。

然后就会来到 fullTryAcquireShared 中再次尝试：

```java
/**
 * 1. 刚刚我们说了可能是因为 CAS 失败，如果就此返回，那么就要进入到阻塞队列了，
 *    想想有点不甘心，因为都已经满足了 !readerShouldBlock()，也就是说本来可以不用到阻塞队列的，
 *    所以进到这个方法其实是增加 CAS 成功的机会
 * 2. 在 NonFairSync 情况下，虽然 head.next 是获取写锁的，我知道它等待很久了，我没想和它抢，
 *    可是如果我是来重入读锁的，那么只能表示对不起了
 */
final int fullTryAcquireShared(Thread current) {
    HoldCounter rh = null;
    // 别忘了这外层有个 for 循环
    for (;;) {
        int c = getState();
        // 如果其他线程持有了写锁，自然这次是获取不到读锁了，乖乖到阻塞队列排队吧
        if (exclusiveCount(c) != 0) {
            if (getExclusiveOwnerThread() != current)
                return -1;
            // else we hold the exclusive lock; blocking here
            // would cause deadlock.
        } else if (readerShouldBlock()) {
            /**
              * 进来这里，说明：
              *  1. exclusiveCount(c) == 0：写锁没有被占用
              *  2. readerShouldBlock() 为 true，说明阻塞队列中有其他线程在等待
              *
              * 既然 should block，那进来这里是干什么的呢？
              * 答案：是进来处理读锁重入的！
              * 
              */

            // firstReader 线程重入读锁，直接到下面的 CAS
            if (firstReader == current) {
                // assert firstReaderHoldCount > 0;
            } else {
                if (rh == null) {
                    rh = cachedHoldCounter;
                    if (rh == null || rh.tid != getThreadId(current)) {
                        // cachedHoldCounter 缓存的不是当前线程
                        // 那么到 ThreadLocal 中获取当前线程的 HoldCounter
                        // 如果当前线程从来没有初始化过 ThreadLocal 中的值，get() 会执行初始化
                        rh = readHolds.get();
                        // 如果发现 count == 0，也就是说，纯属上一行代码初始化的，那么执行 remove
                        // 然后往下两三行，乖乖排队去
                        if (rh.count == 0)
                            readHolds.remove();
                    }
                }
                if (rh.count == 0)
                    // 排队去。
                    return -1;
            }
            /**
              * 这块代码我看了蛮久才把握好它是干嘛的，原来只需要知道，它是处理重入的就可以了。
              * 就是为了确保读锁重入操作能成功，而不是被塞到阻塞队列中等待
              *
              * 另一个信息就是，这里对于 ThreadLocal 变量 readHolds 的处理：
              *    如果 get() 后发现 count == 0，居然会做 remove() 操作，
              *    这行代码对于理解其他代码是有帮助的
              */
        }

        if (sharedCount(c) == MAX_COUNT)
            throw new Error("Maximum lock count exceeded");

        if (compareAndSetState(c, c + SHARED_UNIT)) {
            // 这里 CAS 成功，那么就意味着成功获取读锁了
            // 下面需要做的是设置 firstReader 或 cachedHoldCounter

            if (sharedCount(c) == 0) {
                // 如果发现 sharedCount(c) 等于 0，就将当前线程设置为 firstReader
                firstReader = current;
                firstReaderHoldCount = 1;
            } else if (firstReader == current) {
                firstReaderHoldCount++;
            } else {
                // 下面这几行，就是将 cachedHoldCounter 设置为当前线程
                if (rh == null)
                    rh = cachedHoldCounter;
                if (rh == null || rh.tid != getThreadId(current))
                    rh = readHolds.get();
                else if (rh.count == 0)
                    readHolds.set(rh);
                rh.count++;
                cachedHoldCounter = rh;
            }
            // 返回大于 0 的数，代表获取到了读锁
            return 1;
        }
    }
}
```

> firstReader 是每次将**读锁获取次数**从 0 变为 1 的那个线程。
>
> 能缓存到 firstReader 中就不要缓存到 cachedHoldCounter 中。

上面的源码分析应该说得非常详细了，如果到这里你不太能看懂上面的有些地方的注释，那么可以先往后看，然后再多看几遍。

### 4.2 读锁释放

下面我们看看读锁释放的流程：

```java
// ReadLock
public void unlock() {
    sync.releaseShared(1);
}
```

```java
// Sync
public final boolean releaseShared(int arg) {
    if (tryReleaseShared(arg)) {
        doReleaseShared(); // 这句代码其实唤醒 获取写锁的线程，往下看就知道了
        return true;
    }
    return false;
}

// Sync
protected final boolean tryReleaseShared(int unused) {
    Thread current = Thread.currentThread();
    if (firstReader == current) {
        if (firstReaderHoldCount == 1)
            // 如果等于 1，那么这次解锁后就不再持有锁了，把 firstReader 置为 null，给后来的线程用
            // 为什么不顺便设置 firstReaderHoldCount = 0？因为没必要，其他线程使用的时候自己会设值
            firstReader = null;
        else
            firstReaderHoldCount--;
    } else {
        // 判断 cachedHoldCounter 是否缓存的是当前线程，不是的话要到 ThreadLocal 中取
        HoldCounter rh = cachedHoldCounter;
        if (rh == null || rh.tid != getThreadId(current))
            rh = readHolds.get();

        int count = rh.count;
        if (count <= 1) {

            // 这一步将 ThreadLocal remove 掉，防止内存泄漏。因为已经不再持有读锁了
            readHolds.remove();

            if (count <= 0)
                // 就是那种，lock() 一次，unlock() 好几次的逗比
                throw unmatchedUnlockException();
        }
        // count 减 1
        --rh.count;
    }

    for (;;) {
        int c = getState();
        // nextc 是 state 高 16 位减 1 后的值
        int nextc = c - SHARED_UNIT;
        if (compareAndSetState(c, nextc))
            // 如果 nextc == 0，那就是 state 全部 32 位都为 0，也就是读锁和写锁都空了
            // 此时这里返回 true 的话，其实是帮助唤醒后继节点中的获取写锁的线程
            return nextc == 0;
    }
}
```

读锁释放的过程还是比较简单的，主要就是将 hold count 减 1，如果减到 0 的话，还要将 ThreadLocal 中的 remove 掉。

然后是在 for 循环中将 state 的高 16 位减 1，如果发现读锁和写锁都释放光了，那么唤醒后继的获取写锁的线程。

### 4.3 写锁获取

- 写锁是独占锁。
- 如果有读锁被占用，写锁获取是要进入到阻塞队列中等待的。

```java
// WriteLock
public void lock() {
    sync.acquire(1);
}
// AQS
public final void acquire(int arg) {
    if (!tryAcquire(arg) &&
        // 如果 tryAcquire 失败，那么进入到阻塞队列等待
        acquireQueued(addWaiter(Node.EXCLUSIVE), arg))
        selfInterrupt();
}

// Sync
protected final boolean tryAcquire(int acquires) {

    Thread current = Thread.currentThread();
    int c = getState();
    int w = exclusiveCount(c);
  	// c != 0 说明有读锁/写锁
    if (c != 0) {

        // 看下这里返回 false 的情况：
        //   c != 0 && w == 0: 写锁可用，但是有线程持有读锁(也可能是自己持有)
        //   c != 0 && w !=0 && current != getExclusiveOwnerThread(): 其他线程持有写锁
        //   也就是说，只要有读锁或写锁被占用，这次就不能获取到写锁
        if (w == 0 || current != getExclusiveOwnerThread())
            return false;

        if (w + exclusiveCount(acquires) > MAX_COUNT)
            throw new Error("Maximum lock count exceeded");

        // 这里不需要 CAS，仔细看就知道了，能到这里的，只可能是写锁重入，不然在上面的 if 就拦截了
        setState(c + acquires);
        return true;
    }

    // 如果写锁获取不需要 block，那么进行 CAS，成功就代表获取到了写锁
    if (writerShouldBlock() ||
        !compareAndSetState(c, c + acquires))
        return false;
    setExclusiveOwnerThread(current);
    return true;
}
```

下面看一眼 **writerShouldBlock()** 的判定，然后你再回去看一遍写锁获取过程。

```java
static final class NonfairSync extends Sync {
    // 如果是非公平模式，那么 lock 的时候就可以直接用 CAS 去抢锁，抢不到再排队
    final boolean writerShouldBlock() {
        return false; // writers can always barge
    }
    ...
}
static final class FairSync extends Sync {
    final boolean writerShouldBlock() {
        // 如果是公平模式，那么如果阻塞队列有线程等待的话，就乖乖去排队
        return hasQueuedPredecessors();
    }
    ...
}
```

### 4.4 写锁释放

```java
// WriteLock
public void unlock() {
    sync.release(1);
}

// AQS
public final boolean release(int arg) {
    // 1. 释放锁
    if (tryRelease(arg)) {
        // 2. 如果独占锁释放"完全"，唤醒后继节点
        Node h = head;
        if (h != null && h.waitStatus != 0)
            unparkSuccessor(h);
        return true;
    }
    return false;
}

// Sync 
// 释放锁，是线程安全的，因为写锁是独占锁，具有排他性
// 实现很简单，state 减 1 就是了
protected final boolean tryRelease(int releases) {
    if (!isHeldExclusively())
        throw new IllegalMonitorStateException();
    int nextc = getState() - releases;
    boolean free = exclusiveCount(nextc) == 0;
    if (free)
        setExclusiveOwnerThread(null);
    setState(nextc);
    // 如果 exclusiveCount(nextc) == 0，也就是说包括重入的，所有的写锁都释放了，
    // 那么返回 true，这样会进行唤醒后继节点的操作。
    return free;
}
```

看到这里，是不是发现写锁相对于读锁来说要简单很多。

## 5. 锁降级

Doug Lea 没有说写锁更**高级**，如果有线程持有读锁，那么写锁获取也需要等待。

不过从源码中也可以看出，确实会给写锁一些特殊照顾，如非公平模式下，为了提高吞吐量，lock 的时候会先 CAS 竞争一下，能成功就代表读锁获取成功了，但是如果发现 head.next 是获取写锁的线程，就不会去做 CAS 操作。

Doug Lea 将持有写锁的线程，去获取读锁的过程称为**锁降级（Lock downgrading）**。这样，此线程就既持有写锁又持有读锁。

但是，**锁升级**是不可以的。线程持有读锁的话，在没释放的情况下不能去获取写锁，因为会发生**死锁**。

回去看下写锁获取的源码：

```java
protected final boolean tryAcquire(int acquires) {

    Thread current = Thread.currentThread();
    int c = getState();
    int w = exclusiveCount(c);
    if (c != 0) {
        // 看下这里返回 false 的情况：
        //   c != 0 && w == 0: 写锁可用，但是有线程持有读锁(也可能是自己持有)
        //   c != 0 && w !=0 && current != getExclusiveOwnerThread(): 其他线程持有写锁
        //   也就是说，只要有读锁或写锁被占用，这次就不能获取到写锁
        if (w == 0 || current != getExclusiveOwnerThread())
            return false;
        ...
    }
    ...
}
```

仔细想想，如果线程 a 先获取了读锁，然后获取写锁，那么线程 a 就到阻塞队列休眠了，自己把自己弄休眠了，而且可能之后就没人去唤醒它了。

锁降级中读锁的获取是否必要呢? 答案是必要的。主要是为了保证数据的可见性，如果当前线程不获取读锁而是直接释放写锁，假设此刻另一个线程(记作线程T)获取了写锁并修改了数据，那么当前线程无法感知线程T的数据更新。如果当前线程获取读锁，即遵循锁降级的步骤，则线程T将会被阻塞，直到当前线程使用数据并释放读锁之后，线程T才能获取写锁进行数据更新。

RentrantReadWriteLock不支持锁升级（把持读锁、获取写锁，最后释放读锁的过程）。目的也是保证数据可见性，如果读锁已被多个线程获取，其中任意线程成功获取了写锁并更新了数据，则其更新对其他获取到读锁的线程是不可见的。

## 6. 手写一个读写锁

首先来个 state 变量，然后高 16 位设置为读锁数量，低 16 位设置为写锁数量低，然后在进行读锁时，先判断下是不是有写锁，如果没有，直接读取即可，如果有的话那就需要等待；在写锁想要拿到锁的时候，就要判断写锁和读锁是不是都存在了，如果存在那就等着，如果不存在才进行接下来的操作。

```java
 public static class ReadWrite{
    // 定义一个读写锁共享变量 state
    private int state = 0;

    // state 高 16 位为读锁数量
    private int getReadCount(){
        return state >>> 16;
    }

    // state 低 16 位为写锁数量
    private int getWriteCount(){
        return state & (( 1 << 16 ) - 1 );
    }

    // 获取读锁时,先判断是否有写锁
    // 如果有写锁,就等待
    // 如果没有,进行加 1 操作
    public synchronized void lockRead() throws InterruptedException{
        while ( getWriteCount() > 0){
            wait();
        }

        System.out.println("lockRead --- " + Thread.currentThread().getName());
        state = state + ( 1 << 16);
    }

    // 释放读锁数量减 1 ,通知其他线程
    public synchronized void unLockRead(){
        state = state - ( 1 << 16 );
        notifyAll();
    }

    // 获取写锁时需要判断读锁和写锁是否都存在,有则等待,没有则将写锁数量加 1
    public synchronized void lockWrite() throws InterruptedException{

        while (getReadCount() > 0 || getWriteCount() > 0) {
            wait();
        }
        System.out.println("lockWrite --- " + Thread.currentThread().getName());
        state ++;
    }

    // 释放写锁数量减 1 ,通知所有等待线程
    public synchronized void unlockWriters(){
        state --;
        notifyAll();
    }
}
```

自己测试了下，没啥大问题。

但是如果细究的话，还是有问题的，就比如，如果现在我有好多个读锁，如果一直不释放的话，那么写锁是一直没办法获取到的，这样就造成了饥饿现象的产生嘛。

解决的话也蛮好解决的，就是在上面添加一个记录写锁数量的变量，然后在读锁之前，去判断一下是否有线程要获取写锁，如果有的话，优先处理，没有的话再进行读锁操作。

## 7. 总结

![14](http://blog-1259650185.cosbj.myqcloud.com/img/202201/09/1641660779.png)

## 参考

[Java 读写锁 ReentrantReadWriteLock 源码分析](https://javadoop.com/post/reentrant-read-write-lock)
