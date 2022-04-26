## 1. 简介

AbstractQueuedSynchronizer （抽象队列同步器，以下简称 AQS）出现在 JDK 1.5 中，由大师 Doug Lea 所创作。它提供了“把锁分配给谁"这一问题的一种解决方案，使得锁的开发人员可以将精力放在“如何加解锁上”，避免陷于把锁进行分配而带来的种种细节陷阱之中。它设计了一套比较通用的线程阻塞等待唤醒的机制，无锁状态加锁，有锁状态将线程放在等待队列排队获取锁。这种有效等待，相比于其他死等待或休眠机制、一方面减少了CPU空耗，另一方面机制能力很强，可以满足非常多并发控制的场景。

AQS 是很多同步器的基础框架，比如 ReentrantLock、CountDownLatch 和 Semaphore 等都是基于 AQS 实现的。除此之外，我们还可以基于 AQS，定制出我们所需要的同步器。

AQS 的使用方式通常都是通过内部类继承 AQS 实现同步功能，通过继承 AQS，可以简化同步器的实现。如前面所说，AQS 是很多同步器实现的基础框架。弄懂 AQS 对理解 Java 并发包里的组件大有裨益。好了，其他的就不多说了，开始进入正题吧。

## 2. 原理概述

### 2.1 基于CAS的状态更新

AQS要把锁正确地分配给请求者，就需要其他的属性来维护信息，那么自身也要面对并发问题，因为信息将会被更改，而且可能来源于任意线程。

AQS使用了CAS（compare and set）协助完成自身要维护的信息的更新（后续的源码处处可见）。CAS的意义为：期望对象为某个值并设置为新的值。那么，如果不为期望的值或更新值失败，返回false；如果为期望的值并且设置成功，那么返回true。用例子表达就是“我认为我的家门是开着的，我将把它关上”。那么只有在家门是开着的，并且我把他关上了，这句断言为ture。

CAS是硬件层面上提供的原子操作保证，意味着任意时刻只有一个线程能访问CAS操作的对象。那么，AQS使用CAS的原因在于：

1. CAS足够快。
2. 如果并发时CAS失败时，可能通过自旋再次尝试，因为AQS知道维护信息的并发操作需要等待的时间非常短。
3. AQS对信息的维护不能导致其它线程的阻塞。

因此，AQS对于自身所需要的各种信息更新，均使用CAS协助并发正确。

### 2.2 CLH队列

CLH队列得名于Craig、Landin 和 Hagersten的名字缩写，他们提出实现了以自旋锁方式在并发中构建一个`FIFO`（先入先出）队列，是一个单向链表。在AQS中，也维护着这样一个CLH变体的同步队列，	来记录各个线程对锁的申请状态。在公平竞争的情况下，无法获取同步状态的线程将会被封装成一个节点，置于队列尾部。入队的线程将会通过自旋的方式获取同步状态，若在有限次的尝试后，仍未获取成功，线程则会被阻塞住。大致示意图如下：

![img](http://blog-1259650185.cosbj.myqcloud.com/img/202112/27/1640620458.jpg)

当头结点释放同步状态后，且后继节点对应的线程被阻塞，此时头结点线程将会去唤醒后继节点线程。后继节点线程恢复运行并获取同步状态后，会将旧的头结点从队列中移除，并将自己设为头结点。大致示意图如下：

![img](http://blog-1259650185.cosbj.myqcloud.com/img/202112/27/1640620525.jpg)

同步队列中的节点除了要保存线程，还要保存等待状态。不管是独占式还是共享式，在获取状态失败时都会用到节点类。所以这里我们要先看一下节点类的实现，为后面的源码分析进行简单铺垫。源码如下：

```java
static final class Node {

    /** 共享类型节点，标记节点在共享模式下等待 */
    static final Node SHARED = new Node();
    
    /** 独占类型节点，标记节点在独占模式下等待 */
    static final Node EXCLUSIVE = null;

    /** 等待状态 - 此线程取消了争抢这个锁 */
    static final int CANCELLED =  1;
    
    /** 
     * 等待状态 - 当前节点的后继节点对应的线程需要被唤醒。
     * 如果某个节点处于该状态，那么当该节点释放同步状态或取消后，
     * 该节点就会通知后继节点的线程，使后继节点可以恢复运行 
     */
    static final int SIGNAL    = -1;
    
    /** 等待状态 - 条件等待。表明节点等待在 Condition 上 */
   /** 
     * 等待状态 - 条件等待。表明节点等待在 Condition 上。
     * 当其他线程对Condition调用了signal()后，该节点将会从
     * 条件等待队列中转移到同步队列中，加入到同步状态的获取中。
     */
    static final int CONDITION = -2;
    
    /**
     * 等待状态 - 传播。表示无条件向后传播唤醒动作，详细分析请看第五章
     */
    static final int PROPAGATE = -3;

    /**
     * 等待状态，取值如下：
     *   SIGNAL,
     *   CANCELLED,
     *   CONDITION,
     *   PROPAGATE,
     *   0
     * 
     * 初始情况下，waitStatus = 0
     */
    volatile int waitStatus;

    /**
     * 前驱节点
     */
    volatile Node prev;

    /**
     * 后继节点
     */
    volatile Node next;

    /**
     * 对应的线程
     */
    volatile Thread thread;

    /**
     * 下一个等待节点，用在 ConditionObject 中
     */
    Node nextWaiter;

    /**
     * 判断节点是否是共享节点
     */
    final boolean isShared() {
        return nextWaiter == SHARED;
    }

    /**
     * 获取前驱节点
     */
    final Node predecessor() throws NullPointerException {
        Node p = prev;
        if (p == null)
            throw new NullPointerException();
        else
            return p;
    }

    Node() {    // Used to establish initial head or SHARED marker
    }

    /** addWaiter 方法会调用该构造方法 */
    Node(Thread thread, Node mode) {
        this.nextWaiter = mode;
        this.thread = thread;
    }

    /** Condition 中会用到此构造方法 */
    Node(Thread thread, int waitStatus) { // Used by Condition
        this.waitStatus = waitStatus;
        this.thread = thread;
    }
}
```

以Node的结构来看，prev 和 next 属性将可以支持AQS可以将请求锁的线程构成双向队列，而入队列出队列，以及先入先出的特性，需要方法来支持。

```java
private transient volatile Node head;
private transient volatile Node tail;

private Node enq(final Node node) {
    for (;;) {
        Node t = tail;
        if (t == null) { 
            // 进入到这里，说明没有head节点，CAS操作创建一个head节点
            // 失败也不要紧，失败说明发生了并发，会走到下面的else
            if (compareAndSetHead(new Node()))
                tail = head;
        } else {
            node.prev = t;
            // 把Node加入到尾部，保证加入到为止
            if (compareAndSetTail(t, node)) {
                t.next = node;
                return t;
            }
        }
    }
}
```

AQS中，以head为CLH队列头部，以tail为CLH队列尾部，当加入节点时，通过CAS和自旋保证节点正确入队。

AQS支持独占锁和共享锁，那么CLH队列也就需要能区分节点类型。无论那种节点，都能通过`addWaiter()` 将节点插入到队列而不是直接调用`enq()`。

````java
static final class Node {
    // 表明是共享锁节点
    static final Node SHARED = new Node();
    // 表明是独占锁节点
    static final Node EXCLUSIVE = null;
}

private Node addWaiter(Node mode) {
    Node node = new Node(Thread.currentThread(), mode);

    Node pred = tail;
  	// 快速尝试添加尾节点
    if (pred != null) {
        node.prev = pred;
        if (compareAndSetTail(pred, node)) {
            // 如果插入尾部成功，就直接返回
            pred.next = node;
            return node;
        }
    }
    // 通过CAS自旋确保入队
    enq(node);
    return node;
}
````

根据前面的内容，Node.waitStatus表示Node处于什么样的状态，意味着状态是可以改变的，那么CLH队列中的节点也是可以取消等待的：

```java
private void cancelAcquire(Node node) {
    if (node == null)
        return;

    node.thread = null;

    Node pred = node.prev;
    // 首先，找到当前节点最前面的取消等待的节点
    while (pred.waitStatus > 0)
        node.prev = pred = pred.prev;

    // 方便操作
    Node predNext = pred.next;
    // 记录当前节点状态为取消，这样，如果发生并发，也能正确地处理掉
    node.waitStatus = Node.CANCELLED;

    // 如果当前节点为tail，通过CAS将tail设置为找到的没被取消的pred节点
    if (node == tail && compareAndSetTail(node, pred)) {
        compareAndSetNext(pred, predNext, null);
    } else {
        int ws;
        if (pred != head &&
            ((ws = pred.waitStatus) == Node.SIGNAL ||
            (ws <= 0 && compareAndSetWaitStatus(pred, ws, Node.SIGNAL))) &&
            pred.thread != null) {
            // ① 
            Node next = node.next;
            if (next != null && next.waitStatus <= 0)
                // 移除掉找到的CANCELLED节点，整理CLH队列
                compareAndSetNext(pred, predNext, next);
        } else {
            // ② 表示pred为头节点，或者上述其他条件不满足，唤醒下一节点
            unparkSuccessor(node);
        }
        node.next = node; // help GC
    }
}
```

对于代码中①处进入的情况为：

1. pred不为头节点并且pred的状态为SIGNAL（即等待分配到锁）。
2. 【或者】pred关联的线程不为空并且pred的状态小于0并且能通过CAS设置为SIGNAL。

![cancelAcquire](http://blog-1259650185.cosbj.myqcloud.com/img/202112/28/1640678099.png)

对于代码中②处，当前节点取消后，则唤醒当前节点的后继节点。

<img src="http://blog-1259650185.cosbj.myqcloud.com/img/202112/29/1640710166.png" alt="image-20211229004926842" style="zoom:50%;" />

cancelAcquire()将CLH队列整理成了新的状态，完成了并发状态下将已取消等待的节点的移除操作。

## 3. 重要方法介绍

本节将介绍三组重要的方法，通过使用这三组方法即可实现一个同步组件。

第一组方法是用于访问/设置同步状态的，如下：

| 方法                                               | 说明                  |
| -------------------------------------------------- | --------------------- |
| int getState()                                     | 获取同步状态          |
| void setState()                                    | 设置同步状态          |
| boolean compareAndSetState(int expect, int update) | 通过 CAS 设置同步状态 |

第二组方需要由同步组件重写。如下：

| 方法                              | 说明                       |
| --------------------------------- | -------------------------- |
| boolean tryAcquire(int arg)       | 独占式获取同步状态         |
| boolean tryRelease(int arg)       | 独占式释放同步状态         |
| int tryAcquireShared(int arg)     | 共享式获取同步状态         |
| boolean tryReleaseShared(int arg) | 共享式释放同步状态         |
| boolean isHeldExclusively()       | 检测当前线程是否获取独占锁 |

第三组方法是一组模板方法，同步组件可直接调用。如下：

| 方法                                              | 说明                                                         |
| ------------------------------------------------- | ------------------------------------------------------------ |
| void acquire(int arg)                             | 独占式获取同步状态，该方法将会调用 tryAcquire 尝试获取同步状态。获取成功则返回，获取失败，线程进入同步队列等待。 |
| void acquireInterruptibly(int arg)                | 响应中断版的 acquire                                         |
| boolean tryAcquireNanos(int arg,long nanos)       | 超时+响应中断版的 acquire                                    |
| void acquireShared(int arg)                       | 共享式获取同步状态，同一时刻可能会有多个线程获得同步状态。比如读写锁的读锁就是就是调用这个方法获取同步状态的。 |
| void acquireSharedInterruptibly(int arg)          | 响应中断版的 acquireShared                                   |
| boolean tryAcquireSharedNanos(int arg,long nanos) | 超时+响应中断版的 acquireShared                              |
| boolean release(int arg)                          | 独占式释放同步状态                                           |
| boolean releaseShared(int arg)                    | 共享式释放同步状态                                           |

上面列举了一堆方法，看似繁杂。但稍微理一下，就会发现上面诸多方法无非就两大类：一类是独占式获取和释放共享状态，另一类是共享式获取和释放同步状态。至于这两类方法的实现细节，我会在接下来的章节中讲到，继续往下看吧。

## 4. 源码分析

### 4.1 数据结构

首先看一下AQS 有哪些成员变量。

```java
// 头结点，你直接把它当做 当前持有锁的线程 可能是最好理解的
private transient volatile Node head;

// 阻塞的尾节点，每个新的节点进来，都插入到最后，也就形成了一个链表
private transient volatile Node tail;

// 这个是最重要的，代表当前锁的状态，0代表没有被占用，大于 0 代表有线程持有当前锁
// 这个值可以大于 1，是因为锁可以重入，每次重入都加上 1
private volatile int state;

// 代表当前持有独占锁的线程，举个最重要的使用例子，因为锁可以重入
// reentrantLock.lock()可以嵌套调用多次，所以每次用这个来判断当前线程是否已经拥有了锁
// if (currentThread == getExclusiveOwnerThread()) {state++}
private transient Thread exclusiveOwnerThread; //继承自AbstractOwnableSynchronizer
```

<img src="http://blog-1259650185.cosbj.myqcloud.com/img/202112/30/1640846582.png" alt="image" style="zoom:67%;" />

其中Sync queue，即同步队列，是双向链表，包括head结点和tail结点，head结点主要用作后续的调度。而Condition queue不是必须的，其是一个单向链表，只有当使用Condition时，才会存在此单向链表。并且可能会有多个Condition queue。

AQS定义两种资源共享方式

- Exclusive(独占)：只有一个线程能执行，如ReentrantLock。又可分为公平锁和非公平锁：
  - 公平锁：按照线程在队列中的排队顺序，先到者先拿到锁
  - 非公平锁：当线程要获取锁时，无视队列顺序直接去抢锁，谁抢到就是谁的
- Share(共享)：多个线程可同时执行，如Semaphore/CountDownLatch。Semaphore、CountDownLatCh、 CyclicBarrier、ReadWriteLock 我们都会在后面讲到。

ReentrantReadWriteLock 可以看成是组合式，因为ReentrantReadWriteLock也就是读写锁允许多个线程同时对某一资源进行读。

不同的自定义同步器争用共享资源的方式也不同。自定义同步器在实现时只需要实现共享资源 state 的获取与释放方式即可，至于具体线程等待队列的维护(如获取资源失败入队/唤醒出队等)，AQS已经在上层已经帮我们实现好了。

### 4.2 独占模式分析

#### 4.2.1 获取同步状态

独占式获取同步状态时通过 acquire 进行的，下面来分析一下该方法的源码。如下：

```java
/**
 * 该方法将会调用子类复写的 tryAcquire 方法获取同步状态，
 * - 获取成功：直接返回
 * - 获取失败：将线程封装在节点中，并将节点置于同步队列尾部，
 *     通过自旋尝试获取同步状态。如果在有限次内仍无法获取同步状态，
 *     该线程将会被 LockSupport.park 方法阻塞住，直到被前驱节点唤醒
 */
public final void acquire(int arg) {
    if (!tryAcquire(arg) &&
        acquireQueued(addWaiter(Node.EXCLUSIVE), arg))
        selfInterrupt();
}

/** 向同步队列尾部添加一个节点 */
private Node addWaiter(Node mode) {
  	// 构造Node节点，包含当前线程信息以及节点模式【独占/共享】
    Node node = new Node(Thread.currentThread(), mode);
    // 新建变量 pred 将指针指向tail指向的节点
    Node pred = tail;
    if (pred != null) { // 说明，同步队列已经完成了初始化
      	// 新加入的节点前驱节点指向尾节点
        node.prev = pred;
      	// 因为如果多个线程同时获取同步状态失败都会执行这段代码
      	// 所以，通过 CAS 方式确保安全的设置当前节点为最新的尾节点
        if (compareAndSetTail(pred, node)) {
          	// 曾经的尾节点的后继节点指向当前节点
            pred.next = node;
          	// 返回新构建的节点
            return node;
        }
    }
    
    // 快速插入节点失败，说明当前节点是第一个被加入到同步队列中的节点，调用 enq 方法，不停的尝试插入节点
    enq(node);
    return node;
}

/**
 * 通过 CAS + 自旋的方式插入节点到队尾
 */
private Node enq(final Node node) {
    for (;;) {
        Node t = tail;
        if (t == null) { // Must initialize
            // 设置头结点，初始情况下，头结点是一个空节点
            if (compareAndSetHead(new Node()))
                // 注意：这里只是设置了tail=head，这里可没return哦，没有return，没有return
                // 所以，设置完了以后，继续for循环，下次就到下面的else分支了
                tail = head;
        } else {
            /*
             * 将节点插入队列尾部。这里是先将新节点的前驱设为尾节点，之后在尝试将新节点设为尾节
             * 点，最后再将原尾节点的后继节点指向新的尾节点。除了这种方式，我们还先设置尾节点，
             * 之后再设置前驱和后继，即：
             * 
             *    if (compareAndSetTail(t, node)) {
             *        node.prev = t;
             *        t.next = node;
             *    }
             *    
             * 但如果是这样做，会导致一个问题，即短时内，队列结构会遭到破坏。考虑这种情况，
             * 某个线程在调用 compareAndSetTail(t, node)成功后，该线程被 CPU 切换了。此时
             * 设置前驱和后继的代码还没来得及执行，但尾节点指针却设置成功，导致队列结构短时内会
             * 出现如下情况：
             *
             *      +------+  prev +-----+       +-----+
             * head |      | <---- |     |       |     |  tail
             *      |      | ----> |     |       |     |
             *      +------+ next  +-----+       +-----+
             *
             * tail 节点完全脱离了队列，这样导致一些队列遍历代码出错。如果先设置
             * 前驱，再设置尾节点，即使线程被切换，队列结构短时可能如下：
             *
             *      +------+  prev +-----+ prev  +-----+
             * head |      | <---- |     | <---- |     |  tail
             *      |      | ----> |     |       |     |
             *      +------+ next  +-----+       +-----+
             *      
             * 这样并不会影响从后向前遍历，不会导致遍历逻辑出错。
             * 
             * 参考：
             *    https://www.cnblogs.com/micrari/p/6937995.html
             */
            node.prev = t;
            if (compareAndSetTail(t, node)) {
                t.next = node;
                return t;
            }
        }
    }
}

/**
 * 同步队列中的线程在此方法中以循环尝试获取同步状态，在有限次的尝试后，
 * 若仍未获取锁，线程将会被阻塞，直至被前驱节点的线程唤醒。
 */
final boolean acquireQueued(final Node node, int arg) {
    boolean failed = true;
    try {
        boolean interrupted = false;
        // 循环获取同步状态
        for (;;) {
            final Node p = node.predecessor();
            /*
             * 前驱节点如果是头结点，表明前驱节点已经获取了同步状态。前驱节点释放同步状态后，
             * 在不出异常的情况下， tryAcquire(arg) 应返回 true。此时节点就成功获取了同
             * 步状态，并将自己设为头节点，原头节点出队。
             * 这里我们说一下，为什么可以去试试：
             * 首先，它是队头，这个是第一个条件，其次，当前的head有可能是刚刚初始化的node，
             * enq(node) 方法里面有提到，head是延时初始化的，而且new Node()的时候没有设置任何线程
             * 也就是说，当前的head不属于任何一个线程，所以作为队头，可以去试一试
             */ 
            if (p == head && tryAcquire(arg)) {
                // 成功获取同步状态，设置自己为头节点
                setHead(node);
                p.next = null; // help GC
                failed = false;
                return interrupted; // 返回是否发生过中断
            }
            
            /*
             * 当前节点的前驱节点不是头节点【或者】当前节点的前驱节点是头节点但获取同步状态失败
             * 则根据条件判断是否应该阻塞自己。
             * 如果不阻塞，CPU 就会处于忙等状态，这样会浪费 CPU 资源
             */
            if (shouldParkAfterFailedAcquire(p, node) &&
                parkAndCheckInterrupt())
                interrupted = true;
        }
    } finally {
        /*
         * 如果在获取同步状态中出现异常，failed = true，cancelAcquire 方法会被执行。
         * tryAcquire 需同步组件开发者重写，难免不了会出现异常。
         */
        if (failed)
            cancelAcquire(node);
    }
}

/** 设置头节点 */
private void setHead(Node node) {
    // 仅有一个线程可以成功获取同步状态，所以这里不需要进行同步控制
    head = node;
    node.thread = null;
    node.prev = null;
}

/**
 * 该方法主要用途是，当线程在获取同步状态失败时，根据前驱节点的等待状态，决定后续的动作。比如前驱
 * 节点等待状态为 SIGNAL，表明当前节点线程应该被阻塞住了。不能老是尝试，避免 CPU 忙等。
 *    —————————————————————————————————————————————————————————————————
 *    | 前驱节点等待状态 |                   相应动作                     |
 *    —————————————————————————————————————————————————————————————————
 *    | SIGNAL         | 阻塞                                          |
 *    | CANCELLED      | 向前遍历, 移除前面所有为该状态的节点               |
 *    | waitStatus < 0 | 将前驱节点状态设为 SIGNAL, 并再次尝试获取同步状态   |
 *    —————————————————————————————————————————————————————————————————
 */
private static boolean shouldParkAfterFailedAcquire(Node pred, Node node) {
    int ws = pred.waitStatus;
    /* 
     * 前驱节点等待状态为 SIGNAL，表示当前线程应该被阻塞。
     * 线程阻塞后，会在前驱节点释放同步状态后被前驱节点线程唤醒。
     * 返回true是指当前节点的线程可以安心的阻塞，因为前驱节点会唤醒你。
     */
    if (ws == Node.SIGNAL)
        return true;
        
    /*
     * 前驱节点等待状态为 CANCELLED，则以前驱节点为起点向前遍历，
     * 移除其他等待状态为 CANCELLED 的节点，重新连接队列。
     * 和 cancelAcquire()类似，整合移除node之前被取消的节点
     */ 
    if (ws > 0) {
        do {
            node.prev = pred = pred.prev;
        } while (pred.waitStatus > 0);
        pred.next = node;
    } else {
        /*
         * 前驱节点的waitStatus不等于-1和1，那也就是只可能是0，-2，-3，
         * 每个新的node入队时，waitStatu都是0，正常情况下，
         * 前驱节点是之前的 tail，那么它的 waitStatus 应该是 0
         * 表示我们需要通过CAS 设置前驱节点等待状态为 SIGNAL，
         * false 返回for循环还能尝试获取一下锁
         */
        compareAndSetWaitStatus(pred, ws, Node.SIGNAL);
    }
  	// 会再走一次 for 循环， 然后再次进来此方法，此时会从第一个分支返回 true
    return false;
}

/** 将线程挂起，恢复后返回线程是否被中断过 */
private final boolean parkAndCheckInterrupt() {
    // 调用 LockSupport.park 阻塞自己
  	// 线程挂起，程序不会继续向下执行
    LockSupport.park(this);
    // 根据 park 方法 API描述，程序在下述三种情况会继续向下执行
    //  1. 被 unpark 
    //  2. 被中断(interrupt)
    //  3. 其他不合逻辑的返回才会继续向下执行
    // 因上述三种情况程序执行至此，返回当前线程的中断状态，并清空中断状态
    // 如果由于被中断，该方法会返回 true
    return Thread.interrupted();
}

/**
 * 取消获取同步状态
 */
private void cancelAcquire(Node node) {
  	// 忽略无效节点
    if (node == null)
        return;
		// 将关联的线程信息清空
    node.thread = null;

    // 前驱节点等待状态为 CANCELLED，则向前遍历并移除其他为取消状态的前驱节点
    Node pred = node.prev;
    while (pred.waitStatus > 0)
        node.prev = pred = pred.prev;

    // 跳出上面循环后找到前驱【有效】节点，记录 pred 的后继节点，后面会用到
    Node predNext = pred.next;

    // 将当前节点等待状态设为 CANCELLED，这样，如果发生并发，也能正确地处理掉
    node.waitStatus = Node.CANCELLED;

    /*
     * 如果当前节点是尾节点，则通过 CAS 设置前驱节点 prev 为尾节点。设置成功后，再利用 CAS 将 
     * prev 的 next 引用置空，断开与后继节点的联系，完成清理工作。
     */ 
    if (node == tail && compareAndSetTail(node, pred)) {
        /* 
         * 执行到这里，表明 pred 节点被成功设为了尾节点，这里通过 CAS 将 pred 节点的后继节点
         * 设为 null。注意这里的 CAS 即使失败了，也没关系。失败了，表明 pred 的后继节点更新
         * 了。pred 此时已经是尾节点了，若后继节点被更新，则是有新节点入队了。这种情况下，这次的
         *  CAS 虽然失败，但失败不会影响同步队列的结构。
         */
        compareAndSetNext(pred, predNext, null);
    } else {
        int ws;
        // 根据条件判断是唤醒后继节点，还是将前驱节点和后继节点连接到一起
        if (pred != head &&
            ((ws = pred.waitStatus) == Node.SIGNAL ||
             (ws <= 0 && compareAndSetWaitStatus(pred, ws, Node.SIGNAL))) &&
            pred.thread != null) {
            // 将节点的前驱节点和后继节点重新连接到一起
            Node next = node.next;
            if (next != null && next.waitStatus <= 0)
                /*
                 * 这里使用 CAS 设置 pred 的 next，表明多个线程同时在取消，这里存在竞争。
                 * 不过此处没针对 compareAndSetNext 方法失败后做一些处理，表明即使失败了也
                 * 没关系。实际上，多个线程同时设置 pred 的 next 引用时，只要有一个能设置成
                 * 功即可。
                 */
                compareAndSetNext(pred, predNext, next);
        } else {
            /*
             * 唤醒后继节点对应的线程。这里简单讲一下为什么要唤醒后继线程，考虑下面一种情况：
             *        head          node1         node2         tail
             *        ws=0          ws=1          ws=-1         ws=0
             *      +------+  prev +-----+  prev +-----+  prev +-----+
             *      |      | <---- |     | <---- |     | <---- |     |  
             *      |      | ----> |     | ----> |     | ----> |     |
             *      +------+  next +-----+  next +-----+  next +-----+
             *      
             * 头结点初始状态为 0，node1、node2 和 tail 节点依次入队。node1 自旋过程中调用 
             * tryAcquire 出现异常，进入 cancelAcquire。head 节点此时等待状态仍然是 0，它
             * 会认为后继节点还在运行中，所以它在释放同步状态后，不会去唤醒后继等待状态为非取消的
             * 节点 node2。如果 node1 再不唤醒 node2 的线程，该线程面临无法被唤醒的情况。此
             * 时，整个同步队列就回全部阻塞住。
             */
            unparkSuccessor(node);
        }

        node.next = node; // help GC
    }
}

/**
 * 唤醒节点的后继节点
 */
private void unparkSuccessor(Node node) {
    int ws = node.waitStatus;
    /*
     * 通过 CAS 将等待状态设为 0，让后继节点线程多一次
     * 尝试获取同步状态的机会
     */
    if (ws < 0)
        compareAndSetWaitStatus(node, ws, 0);

    Node s = node.next;
  	// 判断当前节点的后继节点是否是取消状态，如果是，需要移除，重新连接队列	
    if (s == null || s.waitStatus > 0) {
        s = null;
       /*
        * 这里如果 s == null 处理，是不是表明 node 是尾节点？答案是不一定。原因之前在分析 
        * enq 方法时说过。这里再啰嗦一遍，新节点入队时，队列瞬时结构可能如下：
        *                      node1         node2
        *      +------+  prev +-----+ prev  +-----+
        * head |      | <---- |     | <---- |     |  tail
        *      |      | ----> |     |       |     |
        *      +------+ next  +-----+       +-----+
        * 
        * node2 节点为新入队节点，此时 tail 已经指向了它，但 node1 后继引用还未设置。
        * 这里 node1 就是 node 参数，s = node1.next = null，但此时 node1 并不是尾
        * 节点。所以这里不能从前向后遍历同步队列，应该从后向前。
        */
        for (Node t = tail; t != null && t != node; t = t.prev)
          	// 从tail开始，找到最靠近head的状态不为0的节点
          	// 如果是独占式，这里小于0，其实就是 SIGNAL
            if (t.waitStatus <= 0)
                s = t;
    }
    if (s != null)
        // 唤醒 node 的后继节点线程
        LockSupport.unpark(s.thread);
}

/**
 * 程序已经成功获取到同步状态并返回后，自我中断
 * 注意：中断只是给个信号，至于是否响应是你自己的事，程序执行到这里只是知道程序被中断了，至于是因为什么中断是完全不知道的。
 * 中断标识还会被Thread.interrupted()方法去无情清空了，所以需要自己重新设立一下中断标识。
 */
static void selfInterrupt() {
    Thread.currentThread().interrupt();
}
```

到这里，独占式获取同步状态的分析就讲完了。如果仅分析获取同步状态的大致流程，那么这个流程并不难。但若深入到细节之中，还是需要思考思考。这里对独占式获取同步状态的大致流程做个总结，如下：

1. 调用 tryAcquire 方法尝试获取同步状态。
2. 如果获取成功，则直接返回。
3. 如果获取失败，将线程封装到节点中，并将节点入队。
4. 入队节点在 acquireQueued 方法中自旋获取同步状态。
5. 若节点的前驱节点是头节点，则再次调用 tryAcquire 尝试获取同步状态。
6. 获取成功，当前节点将自己设为头节点并返回。
7. 获取失败，可能再次尝试，也可能会被阻塞。这里简单认为会被阻塞。

上面的步骤对应下面的流程图：

![img](http://blog-1259650185.cosbj.myqcloud.com/img/202112/28/1640660006.jpg)



上面流程图参考自《Java并发编程》第128页图 5-5，这里进行了重新绘制，并做了一定的修改。

**以acquireQueued()看，请求锁是的过程是公平的**，按照队列排列顺序申请锁。**以acquire()看，请求锁的过程是不公平的**，因为acquire()会先尝试获取锁再入队，意味着将在某一时刻，有线程完成插队。

对于cancelAcquire与unparkSuccessor方法，如下示意图可以清晰的表示:

![image](http://blog-1259650185.cosbj.myqcloud.com/img/202112/30/1640847658.png)

其中node为参数，在执行完cancelAcquire方法后的效果就是unpark了s结点所包含的t4线程。

**其他特性**：

可中断向AQS请求锁的线程是可以中断的，从parkAndCheckInterrupt()会检查恢复的线程的中断状态，以让更上层的调用决定如何处理。以acquire()来看，它会让已中断过的线程回到中断状态。

可重入性控制可以通过isHeldExclusively()设置可重入性控制，在AQS中是为了共享锁服务的。当然，也可以在子类tryAcquire()等加锁的方法中，借助setExclusiveOwnerThread()和getExclusiveOwnerThread()一起实现是否可重入。

可控获取锁时间申请锁的时间，也可以控制，实现只需要通过在申请不到锁入队时，设置线程唤醒时间即可。AQS提供了其他版本的申请锁方法，流程大体一致。

并发量控制AQS通过属性 state 来提供控制并发量的方式，state只能通过原子性的操作修改。子类控制加解锁操作时，可以通过控制state来做出判断。

#### 4.2.2 释放同步状态

相对于获取同步状态，释放同步状态的过程则要简单的多，这里简单罗列一下步骤：

1. 调用 tryRelease(arg) 尝试释放同步状态。
2. 根据条件判断是否应该唤醒后继线程。

就两个步骤，下面看一下源码分析。

```java
public final boolean release(int arg) {
    if (tryRelease(arg)) {
        Node h = head;
        /*
         * 这里简单列举条件分支的可能性，如下：
         * 1. head = null
         *     head 还未初始化。初始情况下，head = null，当第一个节点入队后，head 会被初始
         *     为一个虚拟（dummy）节点。这里，如果还没节点入队就调用 release 释放同步状态，
         *     就会出现 h = null 的情况。
         *     
         * 2. head != null && waitStatus = 0
         *     表明后继节点对应的线程仍在运行中，不需要唤醒
         * 
         * 3. head != null && waitStatus < 0
         *     后继节点对应的线程可能被阻塞了，需要唤醒 
         */
        if (h != null && h.waitStatus != 0)
            // 唤醒后继节点，上面分析过了，这里不再赘述
            unparkSuccessor(h);
        return true;
    }
    return false;
}
```

### 4.3 共享模式分析

共享式与独占式的最主要区别在于同一时刻独占式只能有一个线程获取同步状态，而共享式在同一时刻可以有多个线程获取同步状态。例如读操作可以有多个线程同时进行，而写操作同一时刻只能有一个线程进行写操作，其他操作都会被阻塞。

共享模式是实现读写锁中的读锁、CountDownLatch 和 Semaphore 等同步组件的基础，搞懂了，再去理解一些共享同步组件就不难了。

#### 4.3.1 获取共享同步状态

共享类型的节点获取共享同步状态后，如果后继节点也是共享类型节点，当前节点则会唤醒后继节点。这样，多个节点线程即可同时获取共享同步状态。

```java
public final void acquireShared(int arg) {
    // 尝试获取共享同步状态，tryAcquireShared 返回的是整型
    if (tryAcquireShared(arg) < 0)
        doAcquireShared(arg);
}

/** 返回 >= 0 的值表示获取成功 */
private void doAcquireShared(int arg) {
    final Node node = addWaiter(Node.SHARED);
    boolean failed = true;
    try {
        boolean interrupted = false;
        // 这里和前面一样，也是通过有限次自旋的方式获取同步状态
        for (;;) {
            final Node p = node.predecessor();
            /*
             * 前驱是头结点，其类型可能是 EXCLUSIVE，也可能是 SHARED.
             * 如果是 EXCLUSIVE，线程无法获取共享同步状态。
             * 如果是 SHARED，线程则可获取共享同步状态。
             * 能不能获取共享同步状态要看 tryAcquireShared 具体的实现。比如多个线程竞争读写
             * 锁的中的读锁时，均能成功获取读锁。但多个线程同时竞争信号量时，可能就会有一部分线
             * 程因无法竞争到信号量资源而阻塞。
             */ 
            if (p == head) {
                // 尝试获取共享同步状态，r表示资源情况
                int r = tryAcquireShared(arg);
                if (r >= 0) {
                    // 获取到了锁，重新设置头结点，如果后继节点是共享类型，向后传播，唤醒后继节点
                    setHeadAndPropagate(node, r);
                    p.next = null; // help GC
                    if (interrupted)
                        selfInterrupt();
                    failed = false;
                    return;
                }
            }
            if (shouldParkAfterFailedAcquire(p, node) &&
                parkAndCheckInterrupt())
                interrupted = true;
        }
    } finally {
        if (failed)
            cancelAcquire(node);
    }
}
   
/**
 * 这个方法做了两件事情：
 * 1. 设置自身为头结点
 * 2. 根据条件判断是否要唤醒后继节点
 */ 
private void setHeadAndPropagate(Node node, int propagate) {
    Node h = head;
    // 设置头结点
    setHead(node);
    
    /*
     * 这个条件分支可能有3种情况：
     * 1. propagate > 0 （代表有更多的资源），但是仅仅靠这个条件判断是否唤醒后继节点是不充分的，至于原因请参考第五章
     * 2. 原来的head为空或未被取消（waitStatus = SIGNAL 或 PROPAGATE）
     * 3. 新的head为空或未被取消（waitStatus = SIGNAL 或 PROPAGATE）
     */
    if (propagate > 0 || h == null || h.waitStatus < 0 ||
        (h = head) == null || h.waitStatus < 0) {
        Node s = node.next;
        /*
         * 节点 s 如果是共享类型节点，则应该唤醒该节点
         * 至于 s == null 的情况前面分析过，这里不在赘述。
         */ 
        if (s == null || s.isShared())
            doReleaseShared();
    }
}

/**
 * 该方法用于在 acquires/releases 存在竞争的情况下，确保唤醒动作向后传播。
 */ 
private void doReleaseShared() {
    /*
     * 下面的循环在 head 节点存在后继节点的情况下，做了两件事情：
     * 1. 如果 head 节点等待状态为 SIGNAL，则将 head 节点状态设为 0，并唤醒后继节点
     * 2. 如果 head 节点等待状态为 0，则将 head 节点状态设为 PROPAGATE，保证唤醒能够正
     *    常传播下去。关于 PROPAGATE 状态的细节分析，后面会讲到。
     */
    for (;;) {
        Node h = head;
        if (h != null && h != tail) {
            int ws = h.waitStatus;
            if (ws == Node.SIGNAL) {
                if (!compareAndSetWaitStatus(h, Node.SIGNAL, 0))
                    continue;            // loop to recheck cases
                unparkSuccessor(h);
            }
            /* 
             * ws = 0 的情况下，这里要尝试将状态从 0 设为 PROPAGATE，保证唤醒向后
             * 传播。setHeadAndPropagate 在读到 h.waitStatus < 0 时，可以继续唤醒
             * 后面的节点。
             */
            else if (ws == 0 &&
                     // 这个 CAS 失败的场景是：执行到这里的时候，刚好有一个节点入队，入队会将这个 ws 设置为 -1
                     !compareAndSetWaitStatus(h, 0, Node.PROPAGATE))
                continue;                // loop on failed CAS
        }
        if (h == head)                   // loop if head changed
            break;
    }
}
```

到这里，共享模式下获取同步状态的逻辑就分析完了，不过我这里只做了简单分析。相对于独占式获取同步状态，共享式的情况更为复杂。独占模式下，只有一个节点线程可以成功获取同步状态，也只有获取已同步状态节点线程才可以释放同步状态。但在共享模式下，多个共享节点线程可以同时获得同步状态，在一些线程获取同步状态的同时，可能还会有另外一些线程正在释放同步状态。所以，共享模式更为复杂。

最后说一下共享模式下获取同步状态的大致流程，如下：

1. 获取共享同步状态。
2. 若获取失败，则生成节点，并入队。
3. 如果前驱为头结点，再次尝试获取共享同步状态。
4. 获取成功则将自己设为头结点，如果后继节点是共享类型的，则唤醒。
5. 若失败，将节点状态设为 SIGNAL，再次尝试。若再次失败，线程进入等待状态。

#### 4.3.2 释放共享同步状态

释放共享同步状态主要逻辑在 doReleaseShared 中，doReleaseShared 上节已经分析过，这里就不赘述了。共享节点线程在获取共享同步状态和释放共享同步状态时都会调用 doReleaseShared，所以 doReleaseShared 是多线程竞争集中的地方。

```java
public final boolean releaseShared(int arg) {
    if (tryReleaseShared(arg)) {
        doReleaseShared();
        return true;
    }
    return false;
}
```

## 4.3 响应中断版和超时版的获取和释放同步状态

到这里，关于独占式获取/释放锁的流程已经闭环了，但是关于 AQS 的另外两个模版方法还没有介绍

- `响应中断`
- `超时限制`

### 4.3.1 响应中断版的独占模式获取同步状态

有了前面的理解，理解响应中断版的独占模式的获取同步状态方式，真是一眼就能明白了：

```java
public final void acquireInterruptibly(int arg)
        throws InterruptedException {
    if (Thread.interrupted())
        throw new InterruptedException();
  	// 尝试非阻塞式获取同步状态失败，如果没有获取到同步状态，doAcquireInterruptibly
    if (!tryAcquire(arg))
        doAcquireInterruptibly(arg);
}

private void doAcquireInterruptibly(int arg)
    throws InterruptedException {
    final Node node = addWaiter(Node.EXCLUSIVE);
    boolean failed = true;
    try {
        for (;;) {
            final Node p = node.predecessor();
            if (p == head && tryAcquire(arg)) {
                setHead(node);
                p.next = null; // help GC
                failed = false;
                return;
            }
            if (shouldParkAfterFailedAcquire(p, node) &&
                parkAndCheckInterrupt())
              	// 获取中断信号后，不再返回 interrupted = true 的值，而是直接抛出 InterruptedException 
                throw new InterruptedException();
        }
    } finally {
        if (failed)
            cancelAcquire(node);
    }
}
```

doAcquireInterruptibly(int arg)方法与acquire(int arg)方法仅有两个差别。

1. 方法声明抛出InterruptedException异常。
2. 在中断方法处不再是使用interrupted标志，而是直接抛出InterruptedException异常，这样就逐层返回上层调用栈捕获该异常进行下一步操作了。

趁热打铁，来看看另外一个模版方法：

### 4.3.2 响应中断+超时版的独占模式获取同步状态

这个很好理解，就是给定一个时限，在该时间段内获取到同步状态，就返回 true， 否则，返回 false。好比线程给自己定了一个闹钟，闹铃一响，线程就自己返回了，这就不会使自己是阻塞状态了。

既然涉及到超时限制，其核心逻辑肯定是计算时间间隔，因为在超时时间内，肯定是多次尝试获取锁的，每次获取锁肯定有时间消耗，所以计算时间间隔的逻辑就像我们在程序打印程序耗时 log 那么简单。

> nanosTimeout = deadline - System.nanoTime()

```java
public final boolean tryAcquireNanos(int arg, long nanosTimeout)
        throws InterruptedException {
    if (Thread.interrupted())
        throw new InterruptedException();
    return tryAcquire(arg) ||
        doAcquireNanos(arg, nanosTimeout);
}
```

是不是和上面 `acquireInterruptibly` 方法长相很详细了，继续查看来 doAcquireNanos 方法，看程序, 该方法也是 throws InterruptedException，方法标记上有 `throws InterruptedException` 说明该方法也是可以响应中断的，所以你可以理解超时限制是 `acquireInterruptibly` 方法的加强版，具有超时和非阻塞控制的双保险。

```java
private boolean doAcquireNanos(int arg, long nanosTimeout)
        throws InterruptedException {
  	// 超时时间内，为获取到同步状态，直接返回false
    if (nanosTimeout <= 0L)
        return false;
  	// 计算超时截止时间
    final long deadline = System.nanoTime() + nanosTimeout;
  	// 以独占模式加入到同步队列中
    final Node node = addWaiter(Node.EXCLUSIVE);
    boolean failed = true;
    try {
        for (;;) {
            final Node p = node.predecessor();
            if (p == head && tryAcquire(arg)) {
                setHead(node);
                p.next = null; // help GC
                failed = false;
                return true;
            }
          	// 计算新的超时时间
            nanosTimeout = deadline - System.nanoTime();
            if (nanosTimeout <= 0L)
              	// 如果超时，直接返回 false
                return false;
            if (shouldParkAfterFailedAcquire(p, node) &&
                // 判断是最新超时时间是否大于阈值 1000    
                nanosTimeout > spinForTimeoutThreshold)
              	// 挂起线程 nanosTimeout 长时间，时间到，自动返回
                LockSupport.parkNanos(this, nanosTimeout);
            if (Thread.interrupted())
                throw new InterruptedException();
        }
    } finally {
        if (failed)
            cancelAcquire(node);
    }
}

```

上面的方法应该不是很难懂，但是又同学可能还有下面的困惑

> 为什么 nanosTimeout 和 自旋超时阈值1000进行比较？

```java
/**
 * The number of nanoseconds for which it is faster to spin
 * rather than to use timed park. A rough estimate suffices
 * to improve responsiveness with very short timeouts.
 */
static final long spinForTimeoutThreshold = 1000L;
```

其实 java doc 说的很清楚，说白了，1000 nanoseconds 时间已经非常非常短暂了，非常短的时间等待无法做到十分精确，如果这时再次进行超时等待，相反会让nanosTimeout 的超时从整体上面表现得不是那么精确。所以在超时非常短的场景中，AQS没必要再执行挂起和唤醒操作了，会进行无条件的快速自旋，直接进入下一次循环。

## 5. PROPAGATE 状态存在的意义

AQS 的节点有几种不同的状态，这个在 4.1 节介绍过。在这几个状态中，PROPAGATE 的用途可能是最不好理解的。网上包括一些书籍关于该状态的叙述基本都是一句带过，也就是 PROPAGATE 字面意义，即向后传播唤醒动作。至于怎么传播，鲜有资料说明过。不过，好在最终我还是找到了一篇详细叙述了 PROPAGATE 状态的文章。在博客园上，博友 [活在夢裡](https://home.cnblogs.com/u/micrari/) 在他的文章 [AbstractQueuedSynchronizer源码解读](https://www.cnblogs.com/micrari/p/6937995.html) 对 PROPAGATE，以及其他的一些细节进行了说明，很有深度。好了，其他的不多说了，继续往下分析。

在本节中，将会说明两个个问题，如下：

1. PROPAGATE 状态用在哪里，以及怎样向后传播唤醒动作的？
2. 引入 PROPAGATE 状态是为了解决什么问题？

这两个问题将会在下面两节中分别进行说明。

### 5.1 利用 PROPAGATE 传播唤醒动作

PROPAGATE 状态是用来传播唤醒动作的，那么它是在哪里进行传播的呢？答案是在`setHeadAndPropagate`方法中，这里再来看看 setHeadAndPropagate 方法的实现：

```java
private void setHeadAndPropagate(Node node, int propagate) {
    Node h = head;
    setHead(node);
    
    if (propagate > 0 || h == null || h.waitStatus < 0 ||
        (h = head) == null || h.waitStatus < 0) {
        Node s = node.next;
        if (s == null || s.isShared())
            doReleaseShared();
    }
}
```

大家注意看 setHeadAndPropagate 方法中那个长长的判断语句，其中有一个条件是`h.waitStatus < 0`，当 h.waitStatus = SIGNAL(-1) 或 PROPAGATE(-3) 是，这个条件就会成立。那么 PROPAGATE 状态是在何时被设置的呢？答案是在`doReleaseShared`方法中，如下：

```java
private void doReleaseShared() {
    for (;;) {
        Node h = head;
        if (h != null && h != tail) {
            int ws = h.waitStatus;
            if (ws == Node.SIGNAL) {...}
            
            // 如果 ws = 0，则将 h 状态设为 PROPAGATE
            else if (ws == 0 &&
                     !compareAndSetWaitStatus(h, 0, Node.PROPAGATE))
                continue;                // loop on failed CAS
        }
        ...
    }
}
```

再回到 setHeadAndPropagate 的实现，该方法既然引入了`h.waitStatus < 0`这个条件，就意味着仅靠条件`propagate > 0`判断是否唤醒后继节点线程的机制是不充分的。至于为啥不充分，请继续往看下看。

### 5.2 引入 PROPAGATE 所解决的问题

PROPAGATE 的引入是为了解决一个 BUG – [JDK-6801020](https://bugs.java.com/bugdatabase/view_bug.do?bug_id=6801020)，复现这个 BUG 的代码如下：

```java
import java.util.concurrent.Semaphore;

public class TestSemaphore {

   private static Semaphore sem = new Semaphore(0);

   private static class Thread1 extends Thread {
       
       public void run() {
           sem.acquireUninterruptibly();
       }
   }

   private static class Thread2 extends Thread {
       
       public void run() {
           sem.release();
       }
   }

   public static void main(String[] args) throws InterruptedException {
       for (int i = 0; i < 10000000; i++) {
           Thread t1 = new Thread1();
           Thread t2 = new Thread1();
           Thread t3 = new Thread2();
           Thread t4 = new Thread2();
           t1.start();
           t2.start();
           t3.start();
           t4.start();
           t1.join();
           t2.join();
           t3.join();
           t4.join();
           System.out.println(i);
       }
   }
}
```

根据 BUG 的描述消息可知 JDK 6u11、6u17 两个版本受到影响。那么，接下来再来看看引起这个 BUG 的代码 – [JDK 6u17](http://www.oracle.com/technetwork/java/javase/downloads/java-archive-downloads-javase6-419409.html) 中 setHeadAndPropagate 和 releaseShared 两个方法源码，如下：

```java
private void setHeadAndPropagate(Node node, int propagate) {
    setHead(node);
    if (propagate > 0 && node.waitStatus != 0) {
        /*
         * Don't bother fully figuring out successor.  If it
         * looks null, call unparkSuccessor anyway to be safe.
         */
        Node s = node.next;
        if (s == null || s.isShared())
            unparkSuccessor(node);
    }
}

// 和 release 方法的源码基本一样
public final boolean releaseShared(int arg) {
    if (tryReleaseShared(arg)) {
        Node h = head;
        if (h != null && h.waitStatus != 0)
            unparkSuccessor(h);
        return true;
    }
    return false;
}
```

下面来简单说明 TestSemaphore 这个类的逻辑。这个类持有一个数值为 0 的信号量对象，并创建了4个线程，线程 t1 和 t2 用于获取信号量，t3 和 t4 则是调用 release() 方法释放信号量。在一般情况下，TestSemaphore 这个类的代码都可以正常执行。但当有极端情况出现时，可能会导致同步队列挂掉。这里演绎一下这个极端情况，考虑某次循环时，队列结构如下：

![img](http://blog-1259650185.cosbj.myqcloud.com/img/202112/28/1640667250.jpg)

1. 时刻1：线程 t3 调用 unparkSuccessor 方法，head 节点状态由 SIGNAL(-1) 变为`0`，并唤醒线程 t1。此时信号量数值为1。
2. 时刻2：线程 t1 恢复运行，t1 调用 Semaphore.NonfairSync 的 tryAcquireShared，返回`0`。然后线程 t1 被切换，暂停运行。
3. 时刻3：线程 t4 调用 releaseShared 方法，因 head 的状态为`0`，所以 t4 不会调用 unparkSuccessor 方法。
4. 时刻4：线程 t1 恢复运行，t1 成功获取信号量，调用 setHeadAndPropagate。但因为 propagate = 0，线程 t1 无法调用 unparkSuccessor 唤醒线程 t2，t2 面临无线程唤醒的情况。因为 t2 无法退出等待状态，所以 t2.join 会阻塞主线程，导致程序挂住。

下面再来看一下修复 BUG 后的代码，根据 BUG 详情页显示，该 BUG 在 JDK 1.7 中被修复。这里找一个 JDK 7 较早版本（JDK 7u10）的代码看一下，如下：

```java
private void setHeadAndPropagate(Node node, int propagate) {
    Node h = head; // Record old head for check below
    setHead(node);
    
    if (propagate > 0 || h == null || h.waitStatus < 0) {
        Node s = node.next;
        if (s == null || s.isShared())
            doReleaseShared();
    }
}

public final boolean releaseShared(int arg) {
    if (tryReleaseShared(arg)) {
        doReleaseShared();
        return true;
    }
    return false;
}

private void doReleaseShared() {
    for (;;) {
        Node h = head;
        if (h != null && h != tail) {
            int ws = h.waitStatus;
            if (ws == Node.SIGNAL) {
                if (!compareAndSetWaitStatus(h, Node.SIGNAL, 0))
                    continue;            // loop to recheck cases
                unparkSuccessor(h);
            }
            else if (ws == 0 &&
                     !compareAndSetWaitStatus(h, 0, Node.PROPAGATE))
                continue;                // loop on failed CAS
        }
        if (h == head)                   // loop if head changed
            break;
    }
}
```

在按照上面的代码演绎一下逻辑，如下：

1. 时刻1：线程 t3 调用 unparkSuccessor 方法，head 节点状态由 SIGNAL(-1) 变为`0`，并唤醒线程t1。此时信号量数值为1。
2. 时刻2：线程 t1 恢复运行，t1 调用 Semaphore.NonfairSync 的 tryAcquireShared，返回`0`。然后线程 t1 被切换，暂停运行。
3. 时刻3：线程 t4 调用 releaseShared 方法，检测到`h.waitStatus = 0`，t4 将头节点等待状态由`0`设为`PROPAGATE(-3)`。
4. 时刻4：线程 t1 恢复运行，t1 成功获取信号量，调用 setHeadAndPropagate。因 propagate = 0，`propagate > 0` 条件不满足。而 `h.waitStatus = PROPAGATE(-3)`，所以条件`h.waitStatus < 0`成立。进而，线程 t1 可以唤醒线程 t2，完成唤醒动作的传播。

到这里关于状态 PROPAGATE 的内容就讲完了。最后，简单总结一下本章开头提的两个问题。

**问题一：PROPAGATE 状态用在哪里，以及怎样向后传播唤醒动作的？**
答：PROPAGATE 状态用在 setHeadAndPropagate。当头节点状态被设为 PROPAGATE 后，后继节点成为新的头结点后。若 `propagate > 0` 条件不成立，则根据条件`h.waitStatus < 0`成立与否，来决定是否唤醒后继节点，即向后传播唤醒动作。

**问题二：引入 PROPAGATE 状态是为了解决什么问题？**
答：引入 PROPAGATE 状态是为了解决**并发释放信号量**所导致部分请求信号量的线程无法被唤醒的问题。

## 6. 示例图解析

下面属于回顾环节，用简单的示例来说一遍，如果上面的有些东西没看懂，这里还有一次帮助你理解的机会。

首先，第一个线程调用 reentrantLock.lock()，翻到最前面可以发现，tryAcquire(1) 直接就返回 true 了，结束。只是设置了 state=1，连 head 都没有初始化，更谈不上什么阻塞队列了。要是线程 1 调用 unlock() 了，才有线程 2 来，那世界就太太太平了，完全没有交集嘛，那我还要 AQS 干嘛。

如果线程 1 没有调用 unlock() 之前，线程 2 调用了 lock(), 想想会发生什么？

线程 2 会初始化 head【new Node()】，同时线程 2 也会插入到阻塞队列并挂起 (注意看这里是一个 for 循环，而且设置 head 和 tail 的部分是不 return 的，只有入队成功才会跳出循环)

```java
private Node enq(final Node node) {
    for (;;) {
        Node t = tail;
        if (t == null) { // Must initialize
            if (compareAndSetHead(new Node()))
                tail = head;
        } else {
            node.prev = t;
            if (compareAndSetTail(t, node)) {
                t.next = node;
                return t;
            }
        }
    }
}
```

首先，是线程 2 初始化 head 节点，此时 head==tail, waitStatus==0。

<img src="http://blog-1259650185.cosbj.myqcloud.com/img/202112/31/1640965832.png" alt="aqs-1" style="zoom:50%;" />

然后线程 2 入队：

<img src="http://blog-1259650185.cosbj.myqcloud.com/img/202112/31/1640965845.png" alt="aqs-2" style="zoom:50%;" />

同时我们也要看此时节点的 waitStatus，我们知道 head 节点是线程 2 初始化的，此时的 waitStatus 没有设置， java 默认会设置为 0，但是到 shouldParkAfterFailedAcquire 这个方法的时候，线程 2 会把前驱节点，也就是 head 的waitStatus设置为 -1。

那线程 2 节点此时的 waitStatus 是多少呢，由于没有设置，所以是 0；

如果线程 3 此时再进来，直接插到线程 2 的后面就可以了，此时线程 3 的 waitStatus 是 0，到 shouldParkAfterFailedAcquire 方法的时候把前驱节点线程 2 的 waitStatus 设置为 -1。

<img src="http://blog-1259650185.cosbj.myqcloud.com/img/202112/31/1640965867.png" alt="aqs-3" style="zoom:50%;" />

这里可以简单说下 waitStatus 中 SIGNAL(-1) 状态的意思，Doug Lea 注释的是：代表后继节点需要被唤醒。也就是说这个 waitStatus 其实代表的不是自己的状态，而是后继节点的状态，我们知道，每个 node 在入队的时候，都会把前驱节点的状态改为 SIGNAL，然后阻塞，等待被前驱唤醒。

## 7. 总结

到这里，本文就差不多结束了。本文的最后，来说一下如何学习 AQS 原理。AQS 的大致原理不是很难理解，所以一开始不建议纠结细节，应该先弄懂它的大致原理。在此基础上，再去分析一些细节，分析细节时，要从多线程的角度去考虑。比如，有点地方 CAS 失败后要重试，有的不用重试。总体来说 AQS 的大致原理容易理解，细节部分比较复杂。很多细节要在脑子里演绎一遍，好好思考才能想通。

## 参考

[AbstractQueuedSynchronizer 原理分析 - 独占/共享模式](https://www.tianxiaobo.com/2018/05/01/AbstractQueuedSynchronizer-%E5%8E%9F%E7%90%86%E5%88%86%E6%9E%90-%E7%8B%AC%E5%8D%A0-%E5%85%B1%E4%BA%AB%E6%A8%A1%E5%BC%8F/)

[AbstractQueuedSynchronizer源码解读](https://www.cnblogs.com/micrari/p/6937995.html)

[一文了解AQS(AbstractQueuedSynchronizer)](https://juejin.cn/post/6948030364321333262#heading-11)

[安琪拉AQS回答让面试官唱征服](https://mp.weixin.qq.com/s/6Usstie2eUo8Pq3MDLD8kA)

[万字超强图文讲解AQS以及ReentrantLock应用（建议收藏）](https://mp.weixin.qq.com/s?__biz=MzkwNzI0MzQ2NQ==&mid=2247489006&idx=1&sn=6ae3d61ba627cbfc9829b7b12d760e25&chksm=c0dd6f48f7aae65ee9b2cc4935a6703bb0e828507859c69ed54f9655cdbb5d8560681d0ba4e6&scene=178&cur_album_id=2197885342135959557#rd)

[J.U.C之AQS](http://www.jiangxinlingdu.com/concurrent/2018/11/21/aqs.html)

[JUC锁: 锁核心类AQS详解](https://www.pdai.tech/md/java/thread/java-thread-x-lock-AbstractQueuedSynchronizer.html)
