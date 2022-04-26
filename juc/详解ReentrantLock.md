## 1. 前言

### 1.1 Java SDK 为什么要设计 Lock

曾几何时幻想过，如果 Java 并发控制只有 synchronized 多好，只有下面三种使用方式，简单方便

```java
public class ThreeSync {

 private static final Object object = new Object();

 public synchronized void normalSyncMethod(){
  //临界区
 }

 public static synchronized void staticSyncMethod(){
  //临界区
 }

 public void syncBlockMethod(){
  synchronized (object){
   //临界区
  }
 }
}
```

如果在 Java 1.5之前，确实是这样，自从 1.5 版本 Doug Lea 大师就重新造了一个轮子 Lock。

我们常说：“避免重复造轮子”，如果有了轮子还是要坚持再造个轮子，那么肯定传统的轮子在某些应用场景中不能很好的解决问题。

不知你是否还记得 Coffman 总结的四个可以发生死锁的情形 ，其中【不可剥夺条件】是指：

> 线程已经获得资源，在未使用完之前，不能被剥夺，只能在使用完时自己释放

要想破坏这个条件，**就需要具有申请不到进一步资源就释放已有资源的能力**。

很显然，这个能力是 synchronized 不具备的，使用 synchronized ，如果线程申请不到资源就会进入阻塞状态，我们做什么也改变不了它的状态，这是 synchronized 轮子的致命弱点，这就强有力的给了重造轮子 Lock 的理由。

### 1.2 显式锁 Lock

旧轮子有弱点，新轮子就要解决这些问题，所以要具备不会阻塞的功能，下面的三个方案都是解决这个问题的好办法。

| 特性             | 描述                                                         | API                          |
| :--------------- | :----------------------------------------------------------- | :--------------------------- |
| 能响应中断       | 如果不能自己释放，那可以响应中断也是很好的。Java多线程中断机制 专门描述了中断过程，目的是通过中断信号来跳出某种状态，比如阻塞 | lockInterruptbly()           |
| 非阻塞式的获取锁 | 尝试获取，获取不到不会阻塞，直接返回                         | tryLock()                    |
| 支持超时         | 给定一个时间限制，如果一段时间内没获取到，不是进入阻塞状态，同样直接返回 | tryLock(long time, timeUnit) |

好的方案有了，但鱼和熊掌不可兼得，Lock 多了 synchronized 不具备的特性，自然不会像 synchronized 那样一个关键字三个玩法走遍全天下，在使用上也相对复杂了一丢丢。

#### 1.2.1 Lock 使用范式

synchronized 有标准用法，这样的优良传统咱 Lock 也得有，相信很多人都知道使用 Lock 的一个**范式**。

```java
Lock lock = new ReentrantLock();
lock.lock();
try{
 ...
}finally{
 lock.unlock();
}
```

既然是范式（没事不要挑战更改写法的那种），肯定有其理由，我们来看一下。

**标准1—finally 中释放锁**

这个大家应该都会明白，在 finally 中释放锁，目的是保证在获取到锁之后，**最终**能被释放。

**标准2—在 try{} 外面获取锁**

不知道你有没有想过，为什么会有标准 2 的存在，我们通常是“喜欢” try 住所有内容，生怕发生异常不能捕获的。

在 `try{}` 外获取锁主要考虑两个方面：

1. 如果没有获取到锁就抛出异常，最终释放锁肯定是有问题的，因为还未曾拥有锁谈何释放锁呢
2. 如果在获取锁时抛出了异常，也就是当前线程并未获取到锁，但执行到 finally 代码时，如果恰巧别的线程获取到了锁，则会被释放掉（无故释放）

> 不同锁的实现方式略有不同，范式的存在就是要避免一切问题的出现，所以大家尽量遵守范式。

#### 1.2.2 Lock 是怎样起到锁的作用呢？

如果你熟悉 synchronized，你知道程序编译成 CPU 指令后，在临界区会有 `moniterenter` 和 `moniterexit` 指令的出现，可以理解成进出临界区的标识。

从范式上来看：

- `lock.lock()` 获取锁，“等同于” synchronized 的 moniterenter指令。
- `lock.unlock()` 释放锁，“等同于” synchronized 的 moniterexit 指令 。

## 2. 源码分析

### 2.1 类的继承关系

ReentrantLock实现了Lock接口，Lock接口中定义了lock与unlock相关操作，并且还存在newCondition方法，表示生成一个条件。

```java
public class ReentrantLock implements Lock, java.io.Serializable
```

### 2.2 类的内部类

ReentrantLock总共有三个内部类，并且三个内部类是紧密相关的，下面先看三个类的关系。

![image](http://blog-1259650185.cosbj.myqcloud.com/img/202112/30/1640877605.png)

说明: ReentrantLock类内部总共存在Sync、NonfairSync、FairSync三个类，NonfairSync与FairSync类继承自Sync类，Sync类继承自AbstractQueuedSynchronizer抽象类。下面逐个进行分析。

#### 2.2.1 Sync类

Sync类的源码如下:

```java
abstract static class Sync extends AbstractQueuedSynchronizer {
    // 序列号
    private static final long serialVersionUID = -5179523762034025860L;
    
    // 获取锁
    abstract void lock();
    
    // 非公平方式获取
    final boolean nonfairTryAcquire(int acquires) {
        // 当前线程
        final Thread current = Thread.currentThread();
        // 获取状态
        int c = getState();
        if (c == 0) { // 表示没有线程正在竞争该锁
          	// 与公平锁不同的是，这里没有对阻塞队列进行判断
            if (compareAndSetState(0, acquires)) { // 比较并设置状态成功，状态0表示锁没有被占用
                // 设置当前线程独占
                setExclusiveOwnerThread(current); 
                return true; // 成功
            }
        }
        else if (current == getExclusiveOwnerThread()) { // 当前线程拥有该锁
            int nextc = c + acquires; // 增加重入次数
            if (nextc < 0) // overflow
                throw new Error("Maximum lock count exceeded");
            // 设置状态
            setState(nextc); 
            // 成功
            return true; 
        }
        // 失败
        return false;
    }
    
    // 试图在共享模式下获取对象状态，此方法应该查询是否允许它在共享模式下获取对象状态，如果允许，则获取它
    protected final boolean tryRelease(int releases) {
        int c = getState() - releases;
        if (Thread.currentThread() != getExclusiveOwnerThread()) // 当前线程不为独占线程
            throw new IllegalMonitorStateException(); // 抛出异常
        // 释放标识
        boolean free = false; 
        if (c == 0) {
            free = true;
            // 已经释放，清空独占
            setExclusiveOwnerThread(null); 
        }
        // 设置标识
        setState(c); 
        return free; 
    }
    
    // 判断资源是否被当前线程占有
    protected final boolean isHeldExclusively() {
        // While we must in general read state before owner,
        // we don't need to do so to check if current thread is owner
        return getExclusiveOwnerThread() == Thread.currentThread();
    }

    // 新生一个条件
    final ConditionObject newCondition() {
        return new ConditionObject();
    }

    // Methods relayed from outer class
    // 返回资源的占用线程
    final Thread getOwner() {        
        return getState() == 0 ? null : getExclusiveOwnerThread();
    }
    // 返回状态
    final int getHoldCount() {            
        return isHeldExclusively() ? getState() : 0;
    }

    // 资源是否被占用
    final boolean isLocked() {        
        return getState() != 0;
    }

    /**
        * Reconstitutes the instance from a stream (that is, deserializes it).
        */
    // 自定义反序列化逻辑
    private void readObject(java.io.ObjectInputStream s)
        throws java.io.IOException, ClassNotFoundException {
        s.defaultReadObject();
        setState(0); // reset to unlocked state
    }
}　　
```

Sync类存在如下方法和作用如下：

![image](http://blog-1259650185.cosbj.myqcloud.com/img/202112/31/1640880087.png)



#### 2.2.2 NonfairSync类

NonfairSync类继承了Sync类，表示采用非公平策略获取锁，其实现了Sync类中抽象的lock方法，源码如下:

```java
// 非公平锁
static final class NonfairSync extends Sync {
    // 版本号
    private static final long serialVersionUID = 7316153563782823691L;

    // 获得锁
    final void lock() {
        if (compareAndSetState(0, 1)) // 比较并设置状态成功，状态0表示锁没有被占用
            // 把当前线程设置独占了锁
            setExclusiveOwnerThread(Thread.currentThread());
        else // 锁已经被占用，或者set失败
            // 以独占模式获取对象，忽略中断
            acquire(1); 
    }

    protected final boolean tryAcquire(int acquires) {
        return nonfairTryAcquire(acquires);
    }
}
```

说明: 从lock方法的源码可知，每一次都尝试获取锁，而并不会按照公平等待的原则进行等待，让等待时间最久的线程获得锁。

####  2.2.3 FairSync类

FairSync类也继承了Sync类，表示采用公平策略获取锁，其实现了Sync类中的抽象lock方法，源码如下：

```java
// 公平锁
static final class FairSync extends Sync {
    // 版本序列化
    private static final long serialVersionUID = -3000897897090466540L;

    final void lock() {
        // 以独占模式获取对象，忽略中断
        acquire(1);
    }

    // 尝试公平获取锁
    protected final boolean tryAcquire(int acquires) {
        // 获取当前线程
        final Thread current = Thread.currentThread();
        // 获取状态
        int c = getState();
        if (c == 0) { // 状态为0
            if (!hasQueuedPredecessors() &&
                compareAndSetState(0, acquires)) { // 不存在已经等待更久的线程并且比较并且设置状态成功
                // 设置当前线程独占
                setExclusiveOwnerThread(current);
                return true;
            }
        }
        else if (current == getExclusiveOwnerThread()) { // 状态不为0，即资源已经被线程占据
            // 下一个状态
            int nextc = c + acquires;
            if (nextc < 0) // 超过了int的表示范围
                throw new Error("Maximum lock count exceeded");
            // 设置状态
            setState(nextc);
            return true;
        }
        return false;
    }
}
```

说明: 跟踪lock方法的源码可知，当资源空闲时，它总是会先判断sync队列(AbstractQueuedSynchronizer中的数据结构)是否有等待时间更长的线程，如果存在，则将该线程加入到等待队列的尾部，实现了公平获取原则。其中，FairSync类的lock的方法调用如下，只给出了主要的方法。

![image](http://blog-1259650185.cosbj.myqcloud.com/img/202112/31/1640880431.png)

说明: 可以看出只要资源被其他线程占用，该线程就会添加到sync queue中的尾部，而不会先尝试获取资源，这也是和Nonfair最大的区别。公平锁的上锁是必须判断自己是不是需要排队，而非公平锁是直接进行CAS修改计数器看能不能加锁成功，如果加锁不成功则乖乖排队(调用acquire)。所以不管公平还是不公平，只要进到了AQS队列当中那么他就会排队，一朝排队，永远排队，记住这点。

总结：公平锁和非公平锁只有两处不同：

1. 非公平锁在调用 lock 后，首先就会调用 CAS 进行一次抢锁，如果这个时候恰巧锁没有被占用，那么直接就获取到锁返回了。
2. 非公平锁在 CAS 失败后，和公平锁一样都会进入到 tryAcquire 方法，在 tryAcquire 方法中，如果发现锁这个时候被释放了（state == 0），非公平锁会直接 CAS 抢锁，但是公平锁会判断等待队列是否有线程处于等待状态，如果有则不去抢锁，乖乖排到后面。

公平锁和非公平锁就这两点区别，如果这两次 CAS 都不成功，那么后面非公平锁和公平锁是一样的，都要进入到阻塞队列等待唤醒。

相对来说，非公平锁会有更好的性能，因为它的吞吐量比较大。当然，非公平锁让获取锁的时间变得更加不确定，可能会导致在阻塞队列中的线程长期处于饥饿状态。

下面给出他们的代码执行逻辑的区别图：

<img src="http://blog-1259650185.cosbj.myqcloud.com/img/202112/31/1640882156.png" alt="公平和非公平" style="zoom: 33%;" />

### 2.3 类的属性

ReentrantLock类的sync非常重要，对ReentrantLock类的操作大部分都直接转化为对Sync和AbstractQueuedSynchronizer类的操作。

```java
public class ReentrantLock implements Lock, java.io.Serializable {
    // 序列号
    private static final long serialVersionUID = 7373984872572414699L;    
    // 同步队列
    private final Sync sync;
}
```

### 2.4 类的构造函数

####  2.4.1 ReentrantLock()型构造函数

默认是采用的非公平策略获取锁。

```java
public ReentrantLock() {
    // 默认非公平策略
    sync = new NonfairSync();
}
```

#### 2.4.2 ReentrantLock(boolean)型构造函数

可以传递参数确定采用公平策略或者是非公平策略，参数为true表示公平策略，否则，采用非公平策略。

```java
public ReentrantLock(boolean fair) {
    sync = fair ? new FairSync() : new NonfairSync();
}
```

#### 2.4.3 核心函数分析

通过分析ReentrantLock的源码，可知对其操作都转化为对Sync对象的操作，由于Sync继承了AQS，所以基本上都可以转化为对AQS的操作。如将ReentrantLock的lock函数转化为对Sync的lock函数的调用，而具体会根据采用的策略(如公平策略或者非公平策略)的不同而调用到Sync的不同子类。

使用多线程很重要的考量点是线程切换的开销，想象一下，如果采用非公平锁，当一个线程请求锁获取同步状态，然后释放同步状态，因为不需要考虑是否还有前驱节点，所以刚释放锁的线程在此刻再次获取同步状态的几率就变得非常大，所以就减少了线程的开销。

**测试**：假设10个线程，每个线程获取100000次锁。

**结果**：公平锁耗时=94\*非公平锁耗时，公平锁线程切换次数=133\*非公平锁切换次数。

> 使用公平锁会有什么问题？

公平锁保证了排队的公平性，非公平锁霸气的忽视这个规则，所以就有可能导致排队的长时间在排队，也没有机会获取到锁，这就是传说中的 **“饥饿”**。

> 如何选择公平锁/非公平锁？

相信到这里，答案已经在你心中了，如果为了更高的吞吐量，很显然非公平锁是比较合适的，因为节省很多线程切换时间，吞吐量自然就上去了，否则那就用公平锁还大家一个公平。

下面通过例子来更进一步分析源码。

### 2.5 示例分析

#### 2.5.1 公平锁 

```java
import java.util.concurrent.locks.Lock;
import java.util.concurrent.locks.ReentrantLock;

class MyThread extends Thread {
    private Lock lock;
    public MyThread(String name, Lock lock) {
        super(name);
        this.lock = lock;
    }
    
    public void run () {
        lock.lock();
        try {
            System.out.println(Thread.currentThread() + " running");
            try {
                Thread.sleep(500);
            } catch (InterruptedException e) {
                e.printStackTrace();
            }
        } finally {
            lock.unlock();
        }
    }
}

public class AbstractQueuedSynchonizerDemo {
    public static void main(String[] args) throws InterruptedException {
        Lock lock = new ReentrantLock(true);
        
        MyThread t1 = new MyThread("t1", lock);        
        MyThread t2 = new MyThread("t2", lock);
        MyThread t3 = new MyThread("t3", lock);
        t1.start();
        t2.start();    
        t3.start();
    }
}
```

运行结果(某一次)：

```java
Thread[t1,5,main] running
Thread[t2,5,main] running
Thread[t3,5,main] running
```

说明: 该示例使用的是公平策略，由结果可知，可能会存在如下一种时序。

![image](http://blog-1259650185.cosbj.myqcloud.com/img/202112/31/1640881295.png)

说明: 首先，t1线程的lock操作 -> t2线程的lock操作 -> t3线程的lock操作 -> t1线程的unlock操作 -> t2线程的unlock操作 -> t3线程的unlock操作。根据这个时序图来进一步分析源码的工作流程。

- t1线程执行lock.lock，下图给出了方法调用中的主要方法。

​	![image](http://blog-1259650185.cosbj.myqcloud.com/img/202112/31/1640881340.png)

​		说明: 由调用流程可知，t1线程成功获取了资源，可以继续执行。

- t2线程执行lock.lock，下图给出了方法调用中的主要方法。

​	![image](http://blog-1259650185.cosbj.myqcloud.com/img/202112/31/1640881381.png)

​	说明: 由上图可知，最后的结果是t2线程会被禁止，因为调用了LockSupport.park。		

- t3线程执行lock.lock，下图给出了方法调用中的主要方法。

  ![image](http://blog-1259650185.cosbj.myqcloud.com/img/202112/31/1640881476.png)

  说明: 由上图可知，最后的结果是t3线程会被禁止，因为调用了LockSupport.park。

- t1线程调用了lock.unlock，下图给出了方法调用中的主要方法。

  ![image](http://blog-1259650185.cosbj.myqcloud.com/img/202112/31/1640881607.png)

  说明: 如上图所示，最后，head的状态会变为0，t2线程会被unpark，即t2线程可以继续运行。此时t3线程还是被禁止。

- t2获得cpu资源，继续运行，由于t2之前被park了，现在需要恢复之前的状态，下图给出了方法调用中的主要方法。

  ![image](http://blog-1259650185.cosbj.myqcloud.com/img/202112/31/1640881633.png)

  说明: 在setHead函数中会将head设置为之前head的下一个结点，并且将pre域与thread域都设置为null，在acquireQueued返回之前，sync queue就只有两个结点了。

- t2执行lock.unlock，下图给出了方法调用中的主要方法。

  ![image](http://blog-1259650185.cosbj.myqcloud.com/img/202112/31/1640881730.png)

  说明: 由上图可知，最终unpark t3线程，让t3线程可以继续运行。

- t3线程获取cpu资源，恢复之前的状态，继续运行。

  ![image](http://blog-1259650185.cosbj.myqcloud.com/img/202112/31/1640881744.png)

  说明: 最终达到的状态是sync queue中只剩下了一个结点，并且该节点除了状态为0外，其余均为null。

- t3执行lock.unlock，下图给出了方法调用中的主要方法。

​		![image](http://blog-1259650185.cosbj.myqcloud.com/img/202112/31/1640881789.png)

说明: 最后的状态和之前的状态是一样的，队列中有一个空节点，头节点为尾节点均指向它。















## 参考

[AbstractQueuedSynchronizer 原理分析 - Condition 实现原理](https://www.tianxiaobo.com/2018/05/04/AbstractQueuedSynchronizer-%E5%8E%9F%E7%90%86%E5%88%86%E6%9E%90-Condition-%E5%AE%9E%E7%8E%B0%E5%8E%9F%E7%90%86/)

[万字超强图文讲解AQS以及ReentrantLock应用（建议收藏）](https://mp.weixin.qq.com/s?__biz=MzkwNzI0MzQ2NQ==&mid=2247489006&idx=1&sn=6ae3d61ba627cbfc9829b7b12d760e25&chksm=c0dd6f48f7aae65ee9b2cc4935a6703bb0e828507859c69ed54f9655cdbb5d8560681d0ba4e6&scene=178&cur_album_id=2197885342135959557#rd)
