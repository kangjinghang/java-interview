## 1. ConcurrentBag 的定义

HikariCP contains a custom lock-free collection called a ConcurrentBag. The idea was borrowed from the C# .NET ConcurrentBag class, but the internal implementation quite different. The ConcurrentBag provides…

- A lock-free design
- ThreadLocal caching
- Queue-stealing
- Direct hand-off optimizations

…resulting in a high degree of concurrency, extremely low latency, and minimized occurrences of false-sharing.

https://en.wikipedia.org/wiki/False_sharing

- CopyOnWriteArrayList：负责存放ConcurrentBag中全部用于出借的资源
- ThreadLocal：用于加速线程本地化资源访问
- SynchronousQueue：用于存在资源等待线程时的第一手资源交接

ConcurrentBag取名来源于C# .NET的同名类，但是实现却不一样。它是一个lock-free集合，在连接池（多线程数据交互）的实现上具

有比LinkedBlockingQueue和LinkedTransferQueue更优越的并发读写性能。

## 2. ConcurrentBag 源码解析

ConcurrentBag 内部同时使用了 ThreadLocal 和 CopyOnWriteArrayList 来存储元素，其中 CopyOnWriteArrayList 是线程共享的。

ConcurrentBag 采用了 queue-stealing 的机制获取元素：首先尝试从 ThreadLocal 中获取属于当前线程的元素来避免锁竞争，如果如果没有可用元素则扫描公共集合，再次从共享的CopyOnWriteArrayList中获取。（ThreadLocal 列表中没有被使用的 items 在借用线程没有属于自己的时候，是可以被“窃取”的）

ThreadLocal 和 CopyOnWriteArrayList 在 ConcurrentBag 中都是成员变量，线程间不共享，避免了伪共享(false sharing)的发生。其使用专门的 AbstractQueuedLongSynchronizer 来管理跨线程信号，这是一个"lock-less“的实现。

这里要特别注意的是，ConcurrentBag 中通过 borrow 方法进行数据资源借用，通过 requite 方法进行资源回收，注意其中 borrow 方法只提供对象引用，不移除对象。所以从 bag 中“借用”的 items 实际上并没有从任何集合中删除，因此即使引用废弃了，垃圾收集也不会发生。因此使用时**通过 borrow 取出的对象必须通过 requite 方法进行放回，否则会导致内存泄露**，只有"remove"方法才能完全从 bag 中删除一个对象。

上节提过，CopyOnWriteArrayList 负责存放 ConcurrentBag 中全部用于出借的资源，就是 private final CopyOnWriteArrayList sharedList; 如下图所示，sharedList 中的资源通过 add 方法添加，remove 方法出借。

add 方法向 bag 中添加 bagEntry 对象，让别人可以借用

```java
/**
 * Add a new object to the bag for others to borrow.
 *
 * @param bagEntry an object to add to the bag
 */
public void add(final T bagEntry)
{
   if (closed) {
      LOGGER.info("ConcurrentBag has been closed, ignoring add()");
      throw new IllegalStateException("ConcurrentBag has been closed, ignoring add()");
   }
   sharedList.add(bagEntry);//新添加的资源优先放入CopyOnWriteArrayList
   // spin until a thread takes it or none are waiting
   // 当有等待资源的线程时，将资源交到某个等待线程后才返回（SynchronousQueue）
   while (waiters.get() > 0 && !handoffQueue.offer(bagEntry)) {
      yield();
   }
}
```

remove 方法用来从 bag 中删除一个 bageEntry，该方法只能在 borrow(long, TimeUnit) 和 reserve(T) 时被使用

```java
/**
 * Remove a value from the bag.  This method should only be called
 * with objects obtained by <code>borrow(long, TimeUnit)</code> or <code>reserve(T)</code>
 *
 * @param bagEntry the value to remove
 * @return true if the entry was removed, false otherwise
 * @throws IllegalStateException if an attempt is made to remove an object
 *         from the bag that was not borrowed or reserved first
 */
public boolean remove(final T bagEntry)
{
   // 如果资源正在使用且无法进行状态切换，则返回失败
   if (!bagEntry.compareAndSet(STATE_IN_USE, STATE_REMOVED) && !bagEntry.compareAndSet(STATE_RESERVED, STATE_REMOVED) && !closed) {
      LOGGER.warn("Attempt to remove an object from the bag that was not borrowed or reserved: {}", bagEntry);
      return false;
   }
   final boolean removed = sharedList.remove(bagEntry);// 从CopyOnWriteArrayList中移出
   if (!removed && !closed) {
      LOGGER.warn("Attempt to remove an object from the bag that does not exist: {}", bagEntry);
   }
   return removed;
}
```

ConcurrentBag 中通过 borrow 方法进行数据资源借用

```java
/**
  * The method will borrow a BagEntry from the bag, blocking for the
  * specified timeout if none are available.
  *
  * @param timeout how long to wait before giving up, in units of unit
  * @param timeUnit a <code>TimeUnit</code> determining how to interpret the timeout parameter
  * @return a borrowed instance from the bag or null if a timeout occurs
  * @throws InterruptedException if interrupted while waiting
  */
 public T borrow(long timeout, final TimeUnit timeUnit) throws InterruptedException
 {
    // Try the thread-local list first
    // 优先查看有没有可用的本地化的资源
    final List<Object> list = threadList.get();
    for (int i = list.size() - 1; i >= 0; i--) {
       final Object entry = list.remove(i);
       @SuppressWarnings("unchecked")
       final T bagEntry = weakThreadLocals ? ((WeakReference<T>) entry).get() : (T) entry;
       if (bagEntry != null && bagEntry.compareAndSet(STATE_NOT_IN_USE, STATE_IN_USE)) {
          return bagEntry;
       }
    }
    // Otherwise, scan the shared list ... then poll the handoff queue
    final int waiting = waiters.incrementAndGet();
    try {
    // 当无可用本地化资源时，遍历全部资源，查看是否存在可用资源
    // 因此被一个线程本地化的资源也可能被另一个线程“抢走”
       for (T bagEntry : sharedList) {
          if (bagEntry.compareAndSet(STATE_NOT_IN_USE, STATE_IN_USE)) {
             // If we may have stolen another waiter's connection, request another bag add.
             if (waiting > 1) {
             // 因为可能“抢走”了其他线程的资源，因此提醒包裹进行资源添加
                listener.addBagItem(waiting - 1);
             }
             return bagEntry;
          }
       }
       listener.addBagItem(waiting);
       timeout = timeUnit.toNanos(timeout);
       do {
          final long start = currentTime();
          // 当现有全部资源全部在使用中，等待一个被释放的资源或者一个新资源
          final T bagEntry = handoffQueue.poll(timeout, NANOSECONDS);
          if (bagEntry == null || bagEntry.compareAndSet(STATE_NOT_IN_USE, STATE_IN_USE)) {
             return bagEntry;
          }
          timeout -= elapsedNanos(start);
       } while (timeout > 10_000);
       return null;
    }
    finally {
       waiters.decrementAndGet();
    }
 }
/**
  * This method will return a borrowed object to the bag.  Objects
  * that are borrowed from the bag but never "requited" will result
  * in a memory leak.
  *
  * @param bagEntry the value to return to the bag
  * @throws NullPointerException if value is null
  * @throws IllegalStateException if the bagEntry was not borrowed from the bag
  */
 public void requite(final T bagEntry)
 {
    // 将状态转为未在使用
    bagEntry.setState(STATE_NOT_IN_USE);
    // 判断是否存在等待线程，若存在，则直接转手资源
    for (int i = 0; waiters.get() > 0; i++) {
       if (bagEntry.getState() != STATE_NOT_IN_USE || handoffQueue.offer(bagEntry)) {
          return;
       }
       else if ((i & 0xff) == 0xff) {
          parkNanos(MICROSECONDS.toNanos(10));
       }
       else {
          yield();
       }
    }
    // 否则，进行资源本地化
    final List<Object> threadLocalList = threadList.get();
    threadLocalList.add(weakThreadLocals ? new WeakReference<>(bagEntry) : bagEntry);
 }
```

上述代码中的 weakThreadLocals 是用来判断是否使用弱引用，通过下述方法初始化：

```java
/**
  * Determine whether to use WeakReferences based on whether there is a
  * custom ClassLoader implementation sitting between this class and the
  * System ClassLoader.
  *
  * @return true if we should use WeakReferences in our ThreadLocals, false otherwise
  */
 private boolean useWeakThreadLocals()
 {
    try {
    // 人工指定是否使用弱引用，但是官方不推荐进行自主设置。
       if (System.getProperty("com.zaxxer.hikari.useWeakReferences") != null) {   // undocumented manual override of WeakReference behavior
          return Boolean.getBoolean("com.zaxxer.hikari.useWeakReferences");
       }
// 默认通过判断初始化的ClassLoader是否是系统的ClassLoader来确定
       return getClass().getClassLoader() != ClassLoader.getSystemClassLoader();
    }
    catch (SecurityException se) {
       return true;
    }
 }
```

## 3. SynchronousQueue

SynchronousQueue 主要用于存在资源等待线程时的第一手资源交接，如下图所示：

<img src="http://blog-1259650185.cosbj.myqcloud.com/img/202205/15/1652626833.jpeg" alt="4" style="zoom:67%;" />

在hikariCP中，选择的是公平模式 this.handoffQueue = new SynchronousQueue<>(true);

公平模式总结下来就是：队尾匹配队头出队，先进先出，体现公平原则。

SynchronousQueue是一个无存储空间的阻塞队列(是实现newFixedThreadPool的核心)，非常适合做交换工作，生产者的线程和消费者的线程同步以传递某些信息、事件或者任务。
因为是无存储空间的，所以与其他阻塞队列实现不同的是，这个阻塞peek方法直接返回null，无任何其他操作，其他的方法与阻塞队列的其他方法一致。这个队列的特点是，必须先调用take或者poll方法，才能使用off，add方法。

作为 BlockingQueue 中的一员，SynchronousQueue 与其他 BlockingQueue 有着不同特性：

- SynchronousQueue 没有容量。与其他 BlockingQueue 不同，SynchronousQueue 是一个不存储元素的 BlockingQueue。每一个put 操作必须要等待一个 take 操作，否则不能继续添加元素，反之亦然。
- 因为没有容量，所以对应 peek, contains, clear, isEmpty … 等方法其实是无效的。例如 clear 是不执行任何操作的，contains 始终返回false,peek始终返回null。
- SynchronousQueue 分为公平和非公平，默认情况下采用非公平性访问策略，当然也可以通过构造函数来设置为公平性访问策略（为true即可）。
- 若使用 TransferQueue，则队列中永远会存在一个 dummy node。

SynchronousQueue 提供了两个构造函数：

```java
public SynchronousQueue() {
    this(false);
}
public SynchronousQueue(boolean fair) {
    // 通过 fair 值来决定公平性和非公平性
    // 公平性使用TransferQueue，非公平性采用TransferStack
    transferer = fair ? new TransferQueue<E>() : new TransferStack<E>();
}
```

TransferQueue、TransferStack继承 Transferer，Transferer 为 SynchronousQueue的内部类，它提供了一个方法 transfer()，该方法定义了转移数据的规范

```java
abstract static class Transferer<E> {
    abstract E transfer(E e, boolean timed, long nanos);
} 
```

transfer() 方法主要用来完成转移数据的，如果 e != null，相当于将一个数据交给消费者，如果 e == null，则相当于从一个生产者接收一个消费者交出的数据。

SynchronousQueue 采用队列 TransferQueue 来实现公平性策略，采用堆栈 TransferStack 来实现非公平性策略，他们两种都是通过链表实现的，其节点分别为 QNode，SNode。TransferQueue 和TransferStack在 SynchronousQueue 中扮演着非常重要的作用，SynchronousQueue 的 put、take 操作都是委托这两个类来实现的。

### 3.1 公平模式

公平模式底层使用的 TransferQueue 内部队列，一个 head 和 tail 指针，用于指向当前正在等待匹配的线程节点。 初始化时，TransferQueue 的状态如下：

<img src="http://blog-1259650185.cosbj.myqcloud.com/img/202205/15/1652627354.png" alt="image-20220515230914510" style="zoom:67%;" />

接着我们进行一些操作：

1、线程 put1 执行 put(1) 操作，由于当前没有配对的消费线程，所以 put1 线程入队列，自旋一小会后睡眠等待，这时队列状态如下：

<img src="http://blog-1259650185.cosbj.myqcloud.com/img/202205/15/1652627406.png" alt="image-20220515231006699" style="zoom:67%;" />

2、接着，线程 put2 执行了 put(2) 操作，跟前面一样，put2 线程入队列，自旋一小会后睡眠等待，这时队列状态如下：

<img src="http://blog-1259650185.cosbj.myqcloud.com/img/202205/15/1652627445.png" alt="image-20220515231045130" style="zoom:67%;" />

3、这时候，来了一个线程 take1，执行了 take 操作，由于 tail 指向 put2 线程，put2 线程跟 take1 线程配对了(一put一take)，这时take1 线程不需要入队，但是请注意了，这时候，要唤醒的线程并不是 put2，而是 put1。为何？ 大家应该知道我们现在讲的是公平策略，所谓公平就是谁先入队了，谁就优先被唤醒，我们的例子明显是 put1 应该优先被唤醒。至于读者可能会有一个疑问，明明是 take1 线程跟 put2 线程匹配上了，结果是 put1 线程被唤醒消费，怎么确保 take1 线程一定可以和次首节点(head.next)也是匹配的呢？其实大家可以拿个纸画一画，就会发现真的就是这样的。 
公平策略总结下来就是：队尾匹配队头出队。 
执行后 put1 线程被唤醒，take1 线程的  take() 方法返回了1(put1 线程的数据)，这样就实现了线程间的一对一通信，这时候内部状态如下：

<img src="http://blog-1259650185.cosbj.myqcloud.com/img/202205/15/1652627535.png" alt="image-20220515231215243" style="zoom:67%;" />

4、最后，再来一个线程 take2，执行 take 操作，这时候只有 put2 线程在等候，而且两个线程匹配上了，线程 put2 被唤醒， 

take2 线程 take 操作返回了2(线程 put2 的数据)，这时候队列又回到了起点，如下所示：

<img src="http://blog-1259650185.cosbj.myqcloud.com/img/202205/15/1652627582.png" alt="image-20220515231301999" style="zoom:67%;" />

以上便是公平模式下，SynchronousQueue 的实现模型。总结下来就是：队尾匹配队头出队，先进先出，体现公平原则。

### 3.2 非公平模式

还是使用跟公平模式下一样的操作流程，对比两种策略下有何不同。非公平模式底层的实现使用的是 TransferStack， 
一个栈，实现中用 head 指针指向栈顶，接着我们看看它的实现模型:

1、线程 put1 执行  put(1)操作，由于当前没有配对的消费线程，所以 put1 线程入栈，自旋一小会后睡眠等待，这时栈状态如下：

<img src="http://blog-1259650185.cosbj.myqcloud.com/img/202205/15/1652627664.png" alt="image-20220515231424258" style="zoom:67%;" />

2、接着，线程 put2 再次执行了 put(2) 操作，跟前面一样，put2 线程入栈，自旋一小会后睡眠等待，这时栈状态如下：

<img src="http://blog-1259650185.cosbj.myqcloud.com/img/202205/15/1652627696.png" alt="image-20220515231456374" style="zoom:67%;" />

3、这时候，来了一个线程 take1，执行了 take 操作，这时候发现栈顶为 put2 线程，匹配成功，但是实现会先把 take1 线程入栈，然后take1 线程循环执行匹配 put2 线程逻辑，一旦发现没有并发冲突，就会把栈顶指针直接指向 put1 线程

<img src="http://blog-1259650185.cosbj.myqcloud.com/img/202205/15/1652627859.png" alt="image-20220515231739112" style="zoom:67%;" />

4、最后，再来一个线程 take2，执行 take 操作，这跟步骤3的逻辑基本是一致的，take2 线程入栈，然后在循环中匹配 put1 线程，最终全部匹配完毕，栈变为空，恢复初始状态，如下图所示：

<img src="http://blog-1259650185.cosbj.myqcloud.com/img/202205/15/1652627914.png" alt="image-20220515231834428" style="zoom:67%;" />

从上面流程看出，虽然 put1 线程先入栈了，但是却是后匹配，这就是非公平的由来。

## 4. CopyOnWriteArrayList

CopyOnWriteArrayList 负责存放 ConcurrentBag 中全部用于出借的资源。

CopyOnWriteArrayList，顾名思义，Write 的时候总是要 Copy，也就是说对于任何可变的操作（add、set、remove）都是伴随复制这个动作的，是 ArrayList  的一个线程安全的变体。

> A thread-safe variant of ArrayList in which all mutative operations (add, set, and so on) are implemented by making a fresh copy of the underlying array.This is ordinarily too costly, but may be more efficient than alternatives when traversal operations vastly outnumber mutations, and is useful when you cannot or don't want to synchronize traversals, yet need to preclude interference among concurrent threads. The "snapshot" style iterator method uses a reference to the state of the array at the point that the iterator was created. This array never changes during the lifetime of the iterator, so interference is impossible and the iterator is guaranteed not to throw ConcurrentModificationException. The iterator will not reflect additions, removals, or changes to the list since the iterator was created. Element-changing operations on iterators themselves (remove, set, and add) are not supported. These methods throw UnsupportedOperationException. All elements are permitted, including null.

CopyOnWriteArrayList的add操作的源代码如下：

```java
 public boolean add(E e) {
    //1、先加锁
    final ReentrantLock lock = this.lock;
    lock.lock();
    try {
        Object[] elements = getArray();
        int len = elements.length;
        //2、拷贝数组
        Object[] newElements = Arrays.copyOf(elements, len + 1);
        //3、将元素加入到新数组中
        newElements[len] = e;
        //4、将array引用指向到新数组
        setArray(newElements);
        return true;
    } finally {
       //5、解锁
        lock.unlock();
    }
}
```

一次add大致经历了几个步骤：

1、加锁
2、拿到原数组，得到新数组的大小（原数组大小+1），实例化出一个新的数组来
3、把原数组的元素复制到新数组中去
4、新数组最后一个位置设置为待添加的元素（因为新数组的大小是按照原数组大小+1来的）
5、把Object array引用指向新数组
6、解锁

插入、删除、修改操作也都是一样，每一次的操作都是以对Object[] array进行一次复制为基础的

由于所有的写操作都是在新数组进行的，这个时候如果有线程并发的写，则通过锁来控制，如果有线程并发的读，则分几种情况： 
1、如果写操作未完成，那么直接读取原数组的数据； 
2、如果写操作完成，但是引用还未指向新数组，那么也是读取原数组数据； 
3、如果写操作完成，并且引用已经指向了新的数组，那么直接从新数组中读取数据。

可见，CopyOnWriteArrayList 的读操作是可以不用加锁的。

**常用的List有ArrayList、LinkedList、Vector，其中前两个是线程非安全的，最后一个是线程安全的。Vector虽然是线程安全的，但是只是一种相对的线程安全而不是绝对的线程安全，它只能够保证增、删、改、查的单个操作一定是原子的，不会被打断，但是如果组合起来用，并不能保证线程安全性。比如就像上面的线程1在遍历一个Vector中的元素、线程2在删除一个Vector中的元素一样，势必产生并发修改异常，也就是fail-fast。**

所以这就是选择 CopyOnWriteArrayList 这个并发组件的原因，CopyOnWriteArrayList 如何做到线程安全的呢？

CopyOnWriteArrayList 使用了一种叫**写时复制**的方法，当有新元素添加到 CopyOnWriteArrayList 时，先从原有的数组中拷贝一份出来，然后在新的数组做写操作，写完之后，再将原来的数组引用指向到新数组。

当有新元素加入的时候，如下图，创建新数组，并往新数组中加入一个新元素,这个时候，array 这个引用仍然是指向原数组的。

<img src="http://blog-1259650185.cosbj.myqcloud.com/img/202205/15/1652628082.png" alt="image-20220515232122149" style="zoom:50%;" />

当元素在新数组添加成功后，将 array 这个引用指向新数组。

<img src="http://blog-1259650185.cosbj.myqcloud.com/img/202205/15/1652628114.png" alt="image-20220515232154019" style="zoom:50%;" />

CopyOnWriteArrayList 的整个 add 操作都是在锁的保护下进行的。 
这样做是为了避免在多线程并发 add 的时候，复制出多个副本出来，把数据搞乱了，导致最终的数组数据不是我们期望的。

CopyOnWriteArrayList 反映的是三个十分重要的分布式理念：

1. 读写分离
   我们读取 CopyOnWriteArrayList 的时候读取的是 CopyOnWriteArrayList 中的 Object[] array，但是修改的时候，操作的是一个新的 Object[] array，读和写操作的不是同一个对象，这就是读写分离。这种技术数据库用的非常多，在高并发下为了缓解数据库的压力，即使做了缓存也要对数据库做读写分离，读的时候使用读库，写的时候使用写库，然后读库、写库之间进行一定的同步，这样就避免同一个库上读、写的 IO 操作太多。
2. 最终一致
   对 CopyOnWriteArrayList 来说，线程1读取集合里面的数据，未必是最新的数据。因为线程2、线程3、线程4四个线程都修改了CopyOnWriteArrayList 里面的数据，但是线程1拿到的还是最老的那个 Object[] array，新添加进去的数据并没有，所以线程1读取的内容未必准确。不过这些数据虽然对于线程1是不一致的，但是对于之后的线程一定是一致的，它们拿到的 Object[] array一定是三个线程都操作完毕之后的 Object array[]，这就是最终一致。最终一致对于分布式系统也非常重要，它通过容忍一定时间的数据不一致，提升整个分布式系统的可用性与分区容错性。当然，最终一致并不是任何场景都适用的，像火车站售票这种系统用户对于数据的实时性要求非常非常高，就必须做成强一致性的。
3. 使用另外开辟空间的思路，来解决并发冲突。

缺点：
1、因为 CopyOnWrite 的写时复制机制，所以在进行写操作的时候，内存里会同时驻扎两个对象的内存，旧的对象和新写入的对象（注意:在复制的时候只是复制容器里的引用，只是在写的时候会创建新对象添加到新容器里，而旧容器的对象还在使用，所以有两份对象内存）。如果这些对象占用的内存比较大，比如说200M左右，那么再写入100M数据进去，内存就会占用300M，那么这个时候很有可能造成频繁的Yong GC和Full GC。之前某系统中使用了一个服务由于每晚使用 CopyOnWrite 机制更新大对象，造成了每晚15秒的 Full GC，应用响应时间也随之变长。针对内存占用问题，可以通过压缩容器中的元素的方法来减少大对象的内存消耗，比如，如果元素全是10进制的数字，可以考虑把它压缩成36进制或64进制。或者不使用 CopyOnWrite 容器，而使用其他的并发容器，如 ConcurrentHashMap。
2、不能用于实时读的场景，像拷贝数组、新增元素都需要时间，所以调用一个 set 操作后，读取到数据可能还是旧的,虽CopyOnWriteArrayList 能做到最终一致性,但是还是没法满足实时性要求；
3.数据一致性问题。CopyOnWrite 容器只能保证数据的最终一致性，不能保证数据的实时一致性。所以如果你希望写入的的数据，马上能读到，请不要使用 CopyOnWrite 容器。

随着 CopyOnWriteArrayList 中元素的增加，CopyOnWriteArrayList 的修改代价将越来越昂贵，因此，CopyOnWriteArrayList 合适读多写少的场景，不过这类慎用 。
因为谁也没法保证CopyOnWriteArrayList 到底要放置多少数据，万一数据稍微有点多，每次 add/set 都要重新复制数组，这个代价实在太高昂了。在高性能的互联网应用中，这种操作分分钟引起故障。**CopyOnWriteArrayList 适用于读操作远多于修改操作的并发场景中。**而 HikariCP 就是这种场景。

还有比如白名单，黑名单，商品类目的访问和更新场景，假如我们有一个搜索网站，用户在这个网站的搜索框中，输入关键字搜索内容，但是某些关键字不允许被搜索。这些不能被搜索的关键字会被放在一个黑名单当中，黑名单每天晚上更新一次。当用户搜索时，会检查当前关键字在不在黑名单当中，如果在，则提示不能搜索。

但是使用 CopyOnWriteMap 需要注意两件事情：

1. 减少扩容开销。根据实际需要，初始化 CopyOnWriteMap 的大小，避免写时 CopyOnWriteMap 扩容的开销。
2. 使用批量添加。因为每次添加，容器每次都会进行复制，所以减少添加次数，可以减少容器的复制次数。



## 参考

[【追光者系列】HikariCP源码分析之ConcurrentBag](https://mp.weixin.qq.com/s/UuJg5YFqSrPpKrxrfJk2Wg)
