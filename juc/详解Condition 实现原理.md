## 1. 简介

`Condition`是一个接口，AbstractQueuedSynchronizer 中的`ConditionObject`内部类实现了这个接口。`Condition`声明了一组`等待/通知`的方法，这些方法的功能与`Object`中的`wait/notify/notifyAll`等方法相似。这两者相同的地方在于，它们所提供的`等待/通知`方法均是为了协同线程的运行秩序。只不过，Object 中的方法需要配合 synchronized 关键字使用，而 Condition 中的方法则要配合锁对象使用，并通过`newCondition`方法获取实现类对象。除此之外，Condition 接口中声明的方法功能上更为丰富一些。比如，Condition 声明了具有不响应中断和超时功能的等待接口，这些都是 Object wait 方法所不具备的。

关于`Condition`的简介这里先说到这，接下来分析一下`Condition`实现类`ConditionObject`的原理。

## 2. 实现原理

`ConditionObject`是通过基于**单链表的条件队列**来管理等待线程的。线程在调用`await`方法进行等待时，会**释放同步状态，即会释放锁**。同时线程将会被封装到一个等待节点中，并将节点置入条件队列（condition queue）尾部进行等待。当有线程在获取独占锁的情况下调用`signal`或`singalAll`方法时，队列中的等待线程将会被唤醒，**重新竞争锁**。另外，需要说明的是，一个锁对象可同时创建多个 ConditionObject 对象，这意味着**多个竞争同一独占锁的线程可在不同的条件队列中进行等待**。在唤醒时，可唤醒指定条件队列中的线程。其大致示意图如下：

![img](http://blog-1259650185.cosbj.myqcloud.com/img/202112/29/1640780761.jpg)

条件队列=condition queue，同步队列=sync queue/CLH queue。

以上就是 ConditionObject 所实现的等待/通知机制的大致原理，并不是很难理解。当然，在具体的实现中，则考虑的更为细致一些。相关细节将会在接下来一章中进行说明，继续往下看吧。

## 3. 源码解析

### 3.1 等待

ConditionObject 中实现了几种不同的等待方法，每种方法均有它自己的特点。比如`await()`会响应中断，而`awaitUninterruptibly()`则不响应中断。`await(long, TimeUnit)`则会在响应中断的基础上，新增了超时功能。除此之外，还有一些等待方法，这里就不一一列举了。

在本节中，我将主要分析`await()`的方法实现。其他的等待方法大同小异，就不一一分析了。

```java
/**
 * await 是一个响应中断的等待方法，主要逻辑流程如下：
 * 1. 如果线程中断了，抛出 InterruptedException 异常
 * 2. 将线程封装到节点对象里，并将节点添加到条件队列尾部
 * 3. 保存并完全释放同步状态，保存下来的同步状态在重新竞争锁时会用到
 * 4. 线程进入等待状态，直到被通知或中断才会恢复运行
 * 5. 使用第3步保存的同步状态去竞争独占锁
 */
public final void await() throws InterruptedException {
    // 线程中断，则抛出中断异常，对应步骤1
    if (Thread.interrupted())
        throw new InterruptedException();
    
    // 添加等待节点到条件队列尾部，对应步骤2
    Node node = addConditionWaiter();
    
    // 保存并完全释放同步状态，对应步骤3。此方法的意义会在后面详细说明。
    int savedState = fullyRelease(node);
    int interruptMode = 0;
    
    /*
     * 判断节点是否在同步队列上，如果不在则阻塞线程。
     * 循环结束的条件：
     * 1. 其他线程调用 singal/singalAll，node 将会被转移到同步队列上。node 对应线程将
     *    会在获取同步状态的过程中被唤醒，并走出 while 循环。
     * 2. 线程在阻塞过程中产生中断
     */ 
    while (!isOnSyncQueue(node)) {
        // 调用 LockSupport.park 阻塞当前线程，对应步骤4
        LockSupport.park(this);
        
        /*
         * 检测中断模式，这里有两种中断模式，如下：
         * THROW_IE：
         *     中断在 node 转移到同步队列“前”发生，需要当前线程自行将 node 转移到同步队
         *     列中，并在随后抛出 InterruptedException 异常。
         *     
         * REINTERRUPT：
         *     中断在 node 转移到同步队列“期间”或“之后”发生，此时表明有线程正在调用 
         *     singal/singalAll 转移节点。在该种中断模式下，再次设置线程的中断状态。
         *     向后传递中断标志，由后续代码去处理中断。
         */
        if ((interruptMode = checkInterruptWhileWaiting(node)) != 0)
            break;
    }
    
    /*
     * 被转移到同步队列的节点 node 将在 acquireQueued 方法中重新获取同步状态，注意这里
     * 的这里的 savedState 是上面调用 fullyRelease 所返回的值，与此对应，可以把这里的 
     * acquireQueued 作用理解为 fullyAcquire（并不存在这个方法）。
     * 
     * 如果上面的 while 循环没有产生中断，则 interruptMode = 0。但 acquireQueued 方法
     * 可能会产生中断，产生中断时返回 true。这里仍将 interruptMode 设为 REINTERRUPT，
     * 目的是继续向后传递中断，acquireQueued 不会处理中断。
     */
    if (acquireQueued(node, savedState) && interruptMode != THROW_IE)
        interruptMode = REINTERRUPT;
    
    /*
     * 正常通过 singal/singalAll 转移节点到同步队列时，nextWaiter 引用会被置空。
     * 若发生线程产生中断（THROW_IE）或 fullyRelease 方法出现错误等异常情况，
     * 该引用则不会被置空
     */ 
    if (node.nextWaiter != null) // clean up if cancelled
        // 清理等待状态非 CONDITION 的节点
        unlinkCancelledWaiters();
        
    if (interruptMode != 0)
        /*
         * 根据 interruptMode 觉得中断的处理方式：
         *   THROW_IE：抛出 InterruptedException 异常
         *   REINTERRUPT：重新设置线程中断标志
         */ 
        reportInterruptAfterWait(interruptMode);
}

/** 将当先线程封装成节点，并将节点添加到条件队列尾部 */
private Node addConditionWaiter() {
    Node t = lastWaiter;
    /*
     * 清理等待状态为 CANCELLED 的节点。fullyRelease 内部调用 release 发生异常或释放同步状
     * 态失败时，节点的等待状态会被设置为 CANCELLED。所以这里要清理一下已取消的节点
     */
    if (t != null && t.waitStatus != Node.CONDITION) {
        unlinkCancelledWaiters();
      	// 重新指向尾部节点
        t = lastWaiter;
    }
    
    // 创建节点，并将节点置于队列尾部
    Node node = new Node(Thread.currentThread(), Node.CONDITION);
    if (t == null)
      	// 作为头节点
        firstWaiter = node;
    else
      	// 作为下一节点
        t.nextWaiter = node;
  	// 更新尾部节点
    lastWaiter = node;
    return node;
}

/** 清理等待状态为 CANCELLED 的节点 */ 
private void unlinkCancelledWaiters() {
    Node t = firstWaiter;
    // 指向上一个等待状态为非 CANCELLED 的节点
    Node trail = null;
    while (t != null) {
        Node next = t.nextWaiter;
        if (t.waitStatus != Node.CONDITION) {
            t.nextWaiter = null;
            /*
             * trail 为 null，表明 next 之前的节点等待状态均为 CANCELLED，此时更新 
             * firstWaiter 引用的指向。
             * trail 不为 null，表明 next 之前有节点的等待状态为 CONDITION，这时将 
             * trail.nextWaiter 指向 next 节点。
             */
            if (trail == null)
                firstWaiter = next;
            else
                trail.nextWaiter = next;
            // next 为 null，表明遍历到条件队列尾部了，此时将 lastWaiter 指向 trail
            if (next == null)
                lastWaiter = trail;
        }
        else
            // t.waitStatus = Node.CONDITION，则将 trail 指向 t
            trail = t;
        t = next;
    }
}
   
/**
 * 这个方法用于完全释放同步状态。这里解释一下完全释放的原因：为了避免死锁的产生，锁的实现上
 * 一般应该支持重入功能。对应的场景就是一个线程在不释放锁的情况下可以多次调用同一把锁的 
 * lock 方法进行加锁，且不会加锁失败，如失败必然导致导致死锁。锁的实现类可通过 AQS 中的整型成员
 * 变量 state 记录加锁次数，每次加锁，将 state++。每次 unlock 方法释放锁时，则将 state--，
 * 直至 state = 0，线程完全释放锁。用这种方式即可实现了锁的重入功能。
 */
final int fullyRelease(Node node) {
    boolean failed = true;
    try {
        // 获取同步状态数值
        int savedState = getState();
        // 调用 release 释放指定数量的同步状态
        if (release(savedState)) { // 注意，这里是全部释放了，而不是像lock一样只释放了1
            failed = false;
            return savedState;
        } else {
            throw new IllegalMonitorStateException();
        }
    } finally {
        // 如果 relase 出现异常或释放同步状态失败，此处将 node 的等待状态设为 CANCELLED
        if (failed)
            node.waitStatus = Node.CANCELLED;
    }
}

/** 该方法用于判断节点 node 是否在同步队列上 */
final boolean isOnSyncQueue(Node node) {
    /*
     * 节点在同步队列上时，其状态可能为 0、SIGNAL、PROPAGATE 和 CANCELLED 其中之一，
     * 但不会为 CONDITION，所以可已通过节点的等待状态来判断节点所处的队列。
     * 
     * node.prev 仅会在节点获取同步状态后，调用 setHead 方法将自己设为头结点时被置为 
     * null，就是说同步队列的节点中只有头节点的 prev 是 null，所以只要节点在同步队列上，node.prev 一定不会为 null
     */
    if (node.waitStatus == Node.CONDITION || node.prev == null)
        return false;
        
    /*
     * 如果节点后继被为 null，则表明节点在同步队列上。因为条件队列使用的是 nextWaiter 指
     * 向后继节点的，条件队列上节点的 next 指针均为 null。但仅以 node.next != null 条
     * 件断定节点在同步队列是不充分的。节点在入队过程中，是先设置 node.prev，后设置 
     * node.next。如果设置完 node.prev 后，线程被切换了，此时 node.next 仍然为 
     * null，但此时 node 确实已经在同步队列上了，所以这里还需要进行后续的判断。
     */
    if (node.next != null)
        return true;
        
    // 在同步队列上，从后向前查找 node 节点
    return findNodeFromTail(node);
}

/** 由于同步队列上的的节点 prev 引用不会为空，所以这里从后向前查找 node 节点 */
private boolean findNodeFromTail(Node node) {
    Node t = tail;
    for (;;) {
        if (t == node)
            return true;
        if (t == null)
            return false;
        t = t.prev;
    }
}

/** 检测线程在等待期间是否发生了中断 */
private int checkInterruptWhileWaiting(Node node) {
    return Thread.interrupted() ?
        (transferAfterCancelledWait(node) ? THROW_IE : REINTERRUPT) :
        0;
}

/** 
 * 判断中断发生的时机，分为两种：
 * 1. 中断在节点被转移到同步队列前发生，此时返回 true
 * 2. 中断在节点被转移到同步队列期间或之后发生，此时返回 false
 */
final boolean transferAfterCancelledWait(Node node) {

    // 中断在节点被转移到同步队列前发生，此时自行将节点转移到同步队列上，并返回 true
    if (compareAndSetWaitStatus(node, Node.CONDITION, 0)) {
        // 调用 enq 将节点转移到同步队列中
        enq(node);
        return true;
    }
    
    /*
     * 如果上面的条件分支失败了，则表明已经有线程在调用 signal/signalAll 方法了，这两个
     * 方法会先将节点等待状态由 CONDITION 设置为 0 后，再调用 enq 方法转移节点。下面判断节
     * 点是否已经在同步队列上的原因是，signal/signalAll 方法可能仅设置了等待状态，还没
     * 来得及转移节点就被切换走了。所以这里用自旋的方式判断 signal/signalAll 是否已经完
     * 成了转移操作。这种情况表明了中断发生在节点被转移到同步队列期间。
     */
    while (!isOnSyncQueue(node))
        Thread.yield();
    }
    
    // 中断在节点被转移到同步队列期间或之后发生，返回 false
    return false;
}

/**
 * 根据中断类型做出相应的处理：
 * THROW_IE：抛出 InterruptedException 异常
 * REINTERRUPT：重新设置中断标志，向后传递中断
 */
private void reportInterruptAfterWait(int interruptMode)
    throws InterruptedException {
    if (interruptMode == THROW_IE)
        throw new InterruptedException();
    else if (interruptMode == REINTERRUPT)
        selfInterrupt();
}

/** 中断线程 */   
static void selfInterrupt() {
    Thread.currentThread().interrupt();
}
```

这里有朋友可能会有疑问：

> 为什么这里是单向队列，也没有使用CAS 来保证加入队列的安全性呢？

因为 await 是 Lock 范式 try 中使用的，说明已经获取到锁了，所以就没必要使用 CAS 了，至于是单向，因为这里还不涉及到竞争锁，只是做一个条件队列。

在 Lock 中可以定义多个条件，每个条件都会对应一个 条件等待队列，所以将上图丰富说明一下就变成了这个样子：

<img src="http://blog-1259650185.cosbj.myqcloud.com/img/202112/30/1640795457.png" alt="同步队列" style="zoom:67%;" />



### 3.2 通知

线程已经按相应的条件加入到了条件队列中，那如何再尝试获取锁呢？signal / signalAll 方法就已经排上用场了

```java
/** 将条件队列中的头结点转移到同步队列中 */
public final void signal() {
    // 检查线程是否获取了独占锁，未获取独占锁调用 signal 方法是不允许的
    if (!isHeldExclusively())
        throw new IllegalMonitorStateException();
    
    Node first = firstWaiter;
    if (first != null)
        // 将头结点转移到同步队列中
        doSignal(first);
}
    
private void doSignal(Node first) {
    do {
        /*
         * 将 firstWaiter 指向 first 节点的 nextWaiter 节点，while 循环将会用到更新后的 
         * firstWaiter 作为判断条件。
         */ 
        if ( (firstWaiter = first.nextWaiter) == null)
            lastWaiter = null;
        // 将头结点从条件队列中移除
        first.nextWaiter = null;
    
    /*
     * 调用 transferForSignal 将节点转移到同步队列中，如果失败，且 firstWaiter
     * 不为 null，则再次进行尝试。transferForSignal 成功了，while 循环就结束了。
     */
    } while (!transferForSignal(first) &&
             (first = firstWaiter) != null);
}

/** 这个方法用于将条件队列中的节点转移到同步队列中 */
final boolean transferForSignal(Node node) {
    /*
     * 如果将节点的等待状态由 CONDITION 设为 0 失败，则表明节点被取消。
     * 因为 transferForSignal 中不存在线程竞争的问题，所以下面的 CAS 
     * 失败的唯一原因是节点的等待状态为 CANCELLED。
     */ 
    if (!compareAndSetWaitStatus(node, Node.CONDITION, 0))
        return false;

    // 调用 enq 方法将 node 转移到同步队列中，并返回 node 的前驱节点 p
    Node p = enq(node);
    int ws = p.waitStatus;
    
    /*
     * 如果前驱节点的等待状态 ws > 0，则表明前驱节点处于取消状态，此时应唤醒 node 对应的
     * 线程去获取同步状态。如果 ws <= 0，这里通过 CAS 将节点 p 的等待设为 SIGNAL。
     * 这样，节点 p 在释放同步状态后，才会唤醒后继节点 node。如果 CAS 设置失败，则应立即
     * 唤醒 node 节点对应的线程。以免因 node 没有被唤醒导致同步队列挂掉。
     */
    if (ws > 0 || !compareAndSetWaitStatus(p, ws, Node.SIGNAL))
        LockSupport.unpark(node.thread);
    return true;
}
```

所以我们再用图解一下唤醒的整个过程：

<img src="http://blog-1259650185.cosbj.myqcloud.com/img/202112/30/1640795594.png" alt="条件队列唤醒" style="zoom:67%;" />

看完了 signal 方法的分析，下面再来看看 signalAll 的源码分析，只不过循环判断是否还有 nextWaiter，如果有就像 signal 操作一样，将其从条件等待队列中移到同步队列中，如下：

```java
public final void signalAll() {
    // 检查线程是否获取了独占锁
    if (!isHeldExclusively())
        throw new IllegalMonitorStateException();
    Node first = firstWaiter;
    if (first != null)
        doSignalAll(first);
}

private void doSignalAll(Node first) {
    lastWaiter = firstWaiter = null;
    /*
     * 将条件队列中所有的节点转移到同步队列中。与 doSignal 方法略有不同，主要区别在 
     * while 循环的循环条件上，下面的循环只有在条件队列中没节点后才终止。
     */ 
    do {
        Node next = first.nextWaiter;
        // 将 first 节点从条件队列中移除
        first.nextWaiter = null;
        // 转移节点到同步队列上
        transferForSignal(first);
        first = next;    
    } while (first != null);
}
```

## 4. 其他

这里还要多说一个细节，从条件队列移到同步队列是有时间差的，所以使用 await() 方法也是范式的， 同样在Java doc中做了解释

<img src="http://blog-1259650185.cosbj.myqcloud.com/img/202112/30/1640795704.png" alt="标准范式" style="zoom:50%;" />

在我阅读 ConditionObject 源码时发现了一个问题 - await 方法竟然没有做同步控制。而在 signal 和 signalAll 方法开头都会调用 isHeldExclusively 检测线程是否已经获取了独占锁，未获取独占锁调用这两个方法会抛出异常。但在 await 方法中，却没有进行相关的检测。如果在正确的使用方式下调用 await 方法是不会出现问题的，所谓正确的使用方式指的是在获取锁的情况下调用 await 方法。但如果没获取锁就调用该方法，就会产生线程竞争的情况，这将会对条件队列的结构造成破坏。这里再来看一下新增节点的方法源码，如下：

```java
private Node addConditionWaiter() {
    Node t = lastWaiter;
    if (t != null && t.waitStatus != Node.CONDITION) {
        unlinkCancelledWaiters();
        t = lastWaiter;
    }
    Node node = new Node(Thread.currentThread(), Node.CONDITION);

    // 存在竞争时将会导致节点入队出错
    if (t == null)
        firstWaiter = node;
    else
        t.nextWaiter = node;
    lastWaiter = node;
    return node;
}
```

假如现在有线程 t1 和 t2，对应节点 node1 和 node2。线程 t1 获取了锁，而 t2 未获取锁，此时条件队列为空，即 firstWaiter = lastWaiter = null。演绎一下会导致条件队列被破坏的场景，如下：

1. 时刻1：线程 t1 和 t2 同时执行到 `if (t == null)`，两个线程都认为 if 条件满足
2. 时刻2：线程 t1 初始化 firstWaiter，即将 firstWaiter 指向 node1
3. 时刻3：线程 t2 再次修改 firstWaiter 的指向，此时 firstWaiter 指向 node2

如上，如果线程是按照上面的顺序执行，这会导致队列被破坏。firstWaiter 本应该指向 node1，但结果却指向了 node2，node1 被排挤出了队列。这样会导致什么问题呢？这样可能会导致线程 t1 一直阻塞下去。因为 signal/signalAll 是从条件队列头部转移节点的，但 node1 不在队列中，所以 node1 无法被转移到同步队列上。在不出现中断的情况下，node1 对应的线程 t1 会被永久阻塞住。

这里未对 await 方法进行同步控制，导致条件队列出现问题，应该算 ConditionObject 实现上的一个缺陷了。关于这个缺陷，博客园博主 [活在夢裡](https://home.cnblogs.com/u/micrari/) 在他的文章 [AbstractQueuedSynchronizer源码解读–续篇之Condition](http://www.cnblogs.com/micrari/p/7219751.html) 中也提到了。并向 JDK 开发者提了一个 BUG，BUG 链接为 [JDK-8187408](https://bugs.java.com/bugdatabase/view_bug.do?bug_id=JDK-8187408)，有兴趣的同学可以去看看。

## 5. 总结

到这里，Condition 的原理就分析完了。分析完 Condition 原理，关于 AbstractQueuedSynchronizer 的分析也就结束了。AQS 是 JDK 中锁和其他并发组件实现的基础，弄懂 AQS 原理对后续在分析各种锁和其他同步组件大有裨益。

AQS 本身实现比较复杂，要处理各种各样的情况。作为类库，AQS 要考虑和处理各种可能的情况，实现起来可谓非常复杂。不仅如此，AQS 还很好的封装了同步队列的管理，线程的阻塞与唤醒等基础操作，大大降低了继承类实现同步控制功能的复杂度。

## 参考

[AbstractQueuedSynchronizer 原理分析 - Condition 实现原理](https://www.tianxiaobo.com/2018/05/04/AbstractQueuedSynchronizer-%E5%8E%9F%E7%90%86%E5%88%86%E6%9E%90-Condition-%E5%AE%9E%E7%8E%B0%E5%8E%9F%E7%90%86/)

[万字超强图文讲解AQS以及ReentrantLock应用（建议收藏）](https://mp.weixin.qq.com/s?__biz=MzkwNzI0MzQ2NQ==&mid=2247489006&idx=1&sn=6ae3d61ba627cbfc9829b7b12d760e25&chksm=c0dd6f48f7aae65ee9b2cc4935a6703bb0e828507859c69ed54f9655cdbb5d8560681d0ba4e6&scene=178&cur_album_id=2197885342135959557#rd)
