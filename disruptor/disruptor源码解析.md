## 增长序列 Sequence

disruptor中较为重要的一个类是Sequence。我们设想下，在disruptor运行过程中，事件发布者（生产者）和事件处理者（消费者）在ringbuffer上相互追逐，由什么来标记它们的相对位置呢？它们根据什么从ringbuffer上发布或者处理事件呢？就是这个Sequence 序列。事件发布者（生产者）和事件处理者（消费者）都有Sequence，记录生产和消费程序的序列。

我们看一下这个类的源代码，先看结构：

```java
class LhsPadding{  
    protected long p1, p2, p3, p4, p5, p6, p7;  
}  
class Value extends LhsPadding{  
    protected volatile long value;  
}  
class RhsPadding extends Value{  
    protected long p9, p10, p11, p12, p13, p14, p15;  
}  
  
public class Sequence extends RhsPadding{  
    static final long INITIAL_VALUE = -1L;  
    private static final Unsafe UNSAFE;  
    private static final long VALUE_OFFSET;  
    static{  
        UNSAFE = Util.getUnsafe();  
        try{  
            VALUE_OFFSET = UNSAFE.objectFieldOffset(Value.class.getDeclaredField("value"));  
        }catch (final Exception e){  
            throw new RuntimeException(e);  
        }  
    }  
    /** 
     * 默认初始值为-1 
     */  
    public Sequence(){  
        this(INITIAL_VALUE);  
    }  
  
    public Sequence(final long initialValue){  
        UNSAFE.putOrderedLong(this, VALUE_OFFSET, initialValue);  
    }
```

我们可以注意到两点：

​       1.通过Sequence的一系列的继承关系可以看到，它真正的用来计数的域是value，在value的前后各有7个long型的填充值，这些值在这里的作用是做cpu cache line填充，防止发生伪共享。

​       2.value域本身由volatile修饰，而且又看到了Unsafe类，大概猜到是要做原子操作了。

 继续看一下Sequence中的方法： 

```java
public long get(){  
    return value;  
}  
/** 
 * ordered write 
 * 在当前写操作和任意之前的读操作之间加入Store/Store屏障 
 */  
public void set(final long value){  
    UNSAFE.putOrderedLong(this, VALUE_OFFSET, value);  
}  
/** 
 * volatile write 
 * 在当前写操作和任意之前的读操作之间加入Store/Store屏障 
 * 在当前写操作和任意之后的读操作之间加入Store/Load屏障 
 */  
public void setVolatile(final long value){  
    UNSAFE.putLongVolatile(this, VALUE_OFFSET, value);  
}  
  
public boolean compareAndSet(final long expectedValue, final long newValue){  
    return UNSAFE.compareAndSwapLong(this, VALUE_OFFSET, expectedValue, newValue);  
}  
  
public long incrementAndGet(){  
    return addAndGet(1L);  
}  
  
public long addAndGet(final long increment){  
    long currentValue;  
    long newValue;  
    do{  
        currentValue = get();  
        newValue = currentValue + increment;  
    }while (!compareAndSet(currentValue, newValue));  
    return newValue;  
} 
```

可见Sequence是一个"原子"的序列。

总结一下：**Sequence是一个做了缓存行填充优化的原子序列**。

 下面再看下FixedSequenceGroup类： 

```java
public final class FixedSequenceGroup extends Sequence{  
     
    private final Sequence[] sequences;  
  
    public FixedSequenceGroup(Sequence[] sequences){  
        this.sequences = Arrays.copyOf(sequences, sequences.length);  
    }  
  
    @Override  
    public long get(){  
        return Util.getMinimumSequence(sequences);  
    }  
  
    @Override  
    public void set(long value){  
        throw new UnsupportedOperationException();  
    }  
      
    ...  
  
}  
```

FixedSequenceGroup相当于包含了若干序列的一个包装类，尽管本身继承了Sequence，但只是重写了get方法，获取内部序列组中最小的序列值，但其他的"写"方法都不支持。

上面看了序列的内容，distruptor中也针对序列的使用，提供了专门的功能接口Sequencer：

Sequencer接口扩展了Cursored和Sequenced。先看下这两个接口：

```java
public interface Cursored{  
    long getCursor();  
}
```

Cursored接口只提供了一个获取当前序列值（游标）的方法。

```java
public interface Sequenced{  
    /** 
     * 数据结构中事件槽的个数(就是RingBuffer的容量) 
     */  
    int getBufferSize();  
    /** 
     * 判断是否还有给定的可用容量
     */  
    boolean hasAvailableCapacity(final int requiredCapacity);  
    /** 
     * 获取剩余容量
     */  
    long remainingCapacity();  
    /** 
     * 申请下一个序列值，用来发布事件
     */  
    long next();  
    /** 
     * 申请下N个序列值，用来多个发布事件
     */  
    long next(int n);  
    /** 
     * 尝试申请下一个序列值用来发布事件，这个是无阻塞的方法
     */  
    long tryNext() throws InsufficientCapacityException;  
    /** 
     * 尝试申请下N个序列值用来发布多个事件，这个是无阻塞的方法
     */  
    long tryNext(int n) throws InsufficientCapacityException;  
    /** 
     * 在给定的序列值上发布事件，当填充好事件后会调用这个方法
     */  
    void publish(long sequence);  
    /** 
     * 在给定的序列返回上批量发布事件，当填充好事件后会调用这个方法
     */  
    void publish(long lo, long hi);  
}
```

最后看下Sequencer接口： 

```java
public interface Sequencer extends Cursored, Sequenced{  
    /** 序列初始值 */  
    long INITIAL_CURSOR_VALUE = -1L;  
  
    /** 
     * 声明一个序列，这个方法只在初始化RingBuffer的时候被调用
     */  
    void claim(long sequence);  
  
    /** 
     * 判断一个序列是否被发布，并且发布到序列上的事件是可处理的。非阻塞方法
     */  
    boolean isAvailable(long sequence);  
  
    /** 
     * 添加一些追踪序列到当前实例，添加过程是原子的。 
     * 这些控制序列一般是其他组件的序列，当前实例可以通过这些序列来查看其他组件的序列使用情况。 
     */  
    void addGatingSequences(Sequence... gatingSequences);  
  
    /** 
     * 移除控制序列
     */  
    boolean removeGatingSequence(Sequence sequence);  
  
    /** 
     * 基于给定的追踪序列创建一个序列栅栏，这个栅栏是提供给事件处理者 
     * 在判断Ringbuffer上某个事件是否能处理时使用的。
     */  
    SequenceBarrier newBarrier(Sequence... sequencesToTrack);  
  
    /** 
     * 获取控制序列里面当前最小的序列值
     */  
    long getMinimumSequence();  
    /** 
     * 获取RingBuffer上安全使用的最大的序列值。 
     * 具体实现里面，这个调用可能需要序列上从nextSequence到availableSequence之间的值。 
     * 如果没有比nextSequence大的可用序列，会返回nextSequence - 1。
     * 为了保证正确，事件处理者应该传递一个比最后的序列值大1个单位的序列来处理。
     * @param nextSequence  申请的序列值
     * @return 已经生产好的事件的最大序列值
     */  
    long getHighestPublishedSequence(long nextSequence, long availableSequence);  
  
    /* 
     * 通过给定的数据提供者和控制序列来创建一个EventPoller
     */  
    <T> EventPoller<T> newPoller(DataProvider<T> provider, Sequence...gatingSequences);  
}  
```

这里要注意一下：

​	Sequencer接口的很多功能是提供给事件发布者用的。

​	通过Sequencer可以得到一个SequenceBarrier，这是提供给事件处理者用的。

disruptor针对Sequencer接口提供了2种实现：SingleProducerSequencer和MultiProducerSequencer，可以理解成RingBuffer的"帮手"，RingBuffer委托Sequencer来处理一些非存储类的工作（比如申请sequence，维护sequence进度，发布事件等）。

看这两个类之前，先看下它们的父类AbstractSequencer：

```java
public abstract class AbstractSequencer implements Sequencer {
    private static final AtomicReferenceFieldUpdater<AbstractSequencer, Sequence[]> SEQUENCE_UPDATER =
        AtomicReferenceFieldUpdater.newUpdater(AbstractSequencer.class, Sequence[].class, "gatingSequences");

    protected final int bufferSize;
    protected final WaitStrategy waitStrategy;
    // 对于SingleProducerSequencer是，当前已经生产完成的最大序列值；对于MultiProducerSequencer是，RingBuffer上当前已申请的最大sequence
    protected final Sequence cursor = new Sequence(Sequencer.INITIAL_CURSOR_VALUE);
    protected volatile Sequence[] gatingSequences = new Sequence[0];

    public AbstractSequencer(int bufferSize, WaitStrategy waitStrategy)
    {
        if (bufferSize < 1)
        {
            throw new IllegalArgumentException("bufferSize must not be less than 1");
        }
        if (Integer.bitCount(bufferSize) != 1)
        {
            throw new IllegalArgumentException("bufferSize must be a power of 2");
        }

        this.bufferSize = bufferSize;
        this.waitStrategy = waitStrategy;
    }

    @Override
    public final long getCursor()
    {
        return cursor.get();
    }

    @Override
    public final int getBufferSize()
    {
        return bufferSize;
    }

    @Override
    public final void addGatingSequences(Sequence... gatingSequences)
    {
        SequenceGroups.addSequences(this, SEQUENCE_UPDATER, this, gatingSequences);
    }

    @Override
    public boolean removeGatingSequence(Sequence sequence)
    {
        return SequenceGroups.removeSequence(this, SEQUENCE_UPDATER, sequence);
    }

    @Override
    public long getMinimumSequence()
    {
        return Util.getMinimumSequence(gatingSequences, cursor.get());
    }

    @Override
    public SequenceBarrier newBarrier(Sequence... sequencesToTrack)
    {
        return new ProcessingSequenceBarrier(this, waitStrategy, cursor, sequencesToTrack);
    }

    @Override
    public <T> EventPoller<T> newPoller(DataProvider<T> dataProvider, Sequence... gatingSequences)
    {
        return EventPoller.newInstance(dataProvider, this, new Sequence(), cursor, gatingSequences);
    }

}
```

可见，父类基本上的作用就是管理追踪序列和关联当前序列。

先看下SingleProducerSequencer，还是先看结构：

```java
abstract class SingleProducerSequencerPad extends AbstractSequencer
{
    protected long p1, p2, p3, p4, p5, p6, p7;

    SingleProducerSequencerPad(int bufferSize, WaitStrategy waitStrategy)
    {
        super(bufferSize, waitStrategy);
    }
}

abstract class SingleProducerSequencerFields extends SingleProducerSequencerPad
{
    SingleProducerSequencerFields(int bufferSize, WaitStrategy waitStrategy)
    {
        super(bufferSize, waitStrategy);
    }

    long nextValue = Sequence.INITIAL_VALUE; // 事件发布者申请的要生产到的位置的序列值
    long cachedValue = Sequence.INITIAL_VALUE; // 事件处理者（可能是多个）都处理完成（消费完）的序列值
}


public final class SingleProducerSequencer extends SingleProducerSequencerFields
{
    protected long p1, p2, p3, p4, p5, p6, p7;

    public SingleProducerSequencer(int bufferSize, WaitStrategy waitStrategy)
    {
        super(bufferSize, waitStrategy);
    }
```

又是缓存行填充，真正使用的值是nextValue和cachedValue。

再看下里面的方法实现：

```java
@Override
public boolean hasAvailableCapacity(int requiredCapacity)
{
    return hasAvailableCapacity(requiredCapacity, false);
}

private boolean hasAvailableCapacity(int requiredCapacity, boolean doStore)
{
    long nextValue = this.nextValue;
		// wrapPoint是要申请序列值的上一圈的序列值，如果wrapPoint是负数，可以一直生产，
  	// 如果是一个大于0的数，wrapPoint要小于等于多个消费者线程中消费的最小的序列号，即cachedValue的值
    long wrapPoint = (nextValue + requiredCapacity) - bufferSize;
    long cachedGatingSequence = this.cachedValue;
		// wrapPoint > cachedGatingSequence == true 的话，就要被套圈了
  	// 如果wrapPoint比最慢消费者序号还大，代表生产者绕了一圈后又追赶上了消费者，这时候就不能继续生产了，否则把消费者还没消费的消息事件覆盖
    // 如果wrapPoint <= 上次最慢消费者序号，说明还是连上次最慢消费者序号都没使用完，不用进入下面的if代码块，直接返回nextSequence就行了
  	// 这样做目的：每次都去获取真实的最慢消费线程序号比较浪费资源，而是获取一批可用序号后，生产者只有使用完后，才继续获取当前最慢消费线程最小序号，重新获取最新资源
    if (wrapPoint > cachedGatingSequence || cachedGatingSequence > nextValue)
    {
        if (doStore) {
          	// cursor代表当前已经生产完成的序号，这里采用UNSAFE.putLongVolatile()插入一个StoreLoad内存屏障，
         	  // 主要保证cursor的真实值对所有的消费线程可见，避免不可见下消费线程无法消费问题
            cursor.setVolatile(nextValue);  // StoreLoad fence
        }
				// 所有跟踪序列的序列值和nextValue之中取的最小值
        long minSequence = Util.getMinimumSequence(gatingSequences, nextValue);
        this.cachedValue = minSequence; // 更新缓存，事件处理者（可能是多个）都处理完成的序列值 为 minSequence

        if (wrapPoint > minSequence) // true的话，就要被套圈了
        {
            return false;
        }
    }

    return true;
}
```

 hasAvailableCapacity方法可以这样理解：

​       当前序列的nextValue + requiredCapacity是事件发布者要申请的序列值。

​       当前序列的cachedValue记录的是之前事件处理者申请的序列值。

​       想一下一个环形队列，事件发布者在什么情况下才能申请一个序列呢？

​       事件发布者当前的位置在事件处理者前面，并且不能从事件处理者后面追上事件处理者（因为是环形），

​       即 **事件发布者要申请的序列值大于事件处理者之前的序列值** 且 **事件发布者要申请的序列值减去环的长度要小于事件处理者的序列值** 

​       如果满足这个条件，即使不知道当前事件处理者的序列值，也能确保事件发布者可以申请给定的序列。

​       如果不满足这个条件，就需要查看一下当前事件处理者的最小的序列值（因为可能有多个事件处理者），如果当前要申请的序列值比当前事件处理者的最小序列值大了一圈（从后面追上了），那就不能申请了（申请的话会覆盖没被消费的事件），也就是说没有可用的空间（用来发布事件）了，也就是hasAvailableCapacity方法要表达的意思。

```java
@Override
public long next()
{
    return next(1);
}

@Override
public long next(int n)
{
    if (n < 1)
    {
        throw new IllegalArgumentException("n must be > 0");
    }

    long nextValue = this.nextValue;

    long nextSequence = nextValue + n;
    long wrapPoint = nextSequence - bufferSize;
  	// cachedValue缓存之前获取的最慢消费者消费到的槽位序号，如果上次更新的cachedValue还没被使用完，那么就继续用上次的序号
    long cachedGatingSequence = this.cachedValue;
		// 如果wrapPoint比最慢消费者序号还大，代表生产者绕了一圈后又追赶上了消费者，这时候就不能继续生产了，否则把消费者还没消费的消息事件覆盖
    // 如果wrapPoint <= 上次最慢消费者序号，说明还是连上次最慢消费者序号都没使用完，不用进入下面的if代码块，直接返回nextSequence就行了
  	// 这样做目的：每次都去获取真实的最慢消费线程序号比较浪费资源，而是获取一批可用序号后，生产者只有使用完后，才继续获取当前最慢消费线程最小序号，重新获取最新资源
    if (wrapPoint > cachedGatingSequence || cachedGatingSequence > nextValue)
    {
        cursor.setVolatile(nextValue);  // StoreLoad fence

        long minSequence;
      	// 判断wrapPoint是否大于消费者线程最小的序列号，如果大于，不能写入，继续等待
        while (wrapPoint > (minSequence = Util.getMinimumSequence(gatingSequences, nextValue))) // 不能被套圈
        {
          	// 可以看到，next()方法是一个阻塞接口，如果一直获取不到可用资源，就会一直阻塞在这里
            LockSupport.parkNanos(1L); // 如果获取最新最慢消费线程最小序号后，依然没有可用资源，阻塞等待一下，然后重试
        }
        // 有可用资源时，将当前最慢消费序号缓存到cachedValue中，下次再申请时就可不必再进入if块中获取真实的最慢消费线程序号，只有这次获取到的被生产者使用完才会继续进入if块
        this.cachedValue = minSequence;
    }
    // 申请成功，将nextValue重新设置，缓存生产者最大生产序列号，下次再申请时继续在该值基础上申请
    this.nextValue = nextSequence;

    return nextSequence;
}
```

 next方法是真正申请序列的方法，里面的逻辑和hasAvailableCapacity一样，只是在不能申请序列的时候会阻塞等待一下，然后重试。 

cachedGatingSequence > nextValue判断的是最慢消费进度超过了我们即将要申请的sequence，乍一看这应该是不可能的吧，都还没申请到该sequence怎么可能消费到呢？找了些资料，发现确实是存在该场景的：RingBuffer提供了一个叫resetTo的方法，可以重置当前已申请sequence为一个指定值并publish出去：

```java
@Deprecated
public void resetTo(long sequence)
{
    sequencer.claim(sequence);
    sequencer.publish(sequence);
}
```

具体资料可参考：

- [https://github.com/LMAX-Exchange/disruptor/issues/280](https://links.jianshu.com/go?to=https%3A%2F%2Fgithub.com%2FLMAX-Exchange%2Fdisruptor%2Fissues%2F280)
- [https://github.com/LMAX-Exchange/disruptor/issues/76](https://links.jianshu.com/go?to=https%3A%2F%2Fgithub.com%2FLMAX-Exchange%2Fdisruptor%2Fissues%2F76)

不过该代码已经标注为@Deprecated，按照作者的意思，后续是要删掉的。那么在此处分析的时候，我们就将当它恒为false。

```java
@Override
public long tryNext() throws InsufficientCapacityException
{
    return tryNext(1);
}


@Override
public long tryNext(int n) throws InsufficientCapacityException
{
    if (n < 1)
    {
        throw new IllegalArgumentException("n must be > 0");
    }

    if (!hasAvailableCapacity(n, true))
    {
        throw InsufficientCapacityException.INSTANCE;
    }

    long nextSequence = this.nextValue += n;

    return nextSequence;
}
```

 tryNext方法是next方法的非阻塞版本，不能申请就抛异常。 

```java
public long remainingCapacity()
{
    long nextValue = this.nextValue;

    long consumed = Util.getMinimumSequence(gatingSequences, nextValue);
    long produced = nextValue;
    return getBufferSize() - (produced - consumed);
}
```

remainingCapacity方法就是环形队列的容量减去事件发布者与事件处理者的序列差。 

```java
@Override  
public void claim(long sequence){  
    this.nextValue = sequence;  
}
```

claim方法是声明一个序列，在初始化的时候用。 

````java
@Override  
public void publish(long sequence){  
    cursor.set(sequence);  
    waitStrategy.signalAllWhenBlocking();  
}  

@Override  
public void publish(long lo, long hi){  
    publish(hi);  
}
````

发布一个序列，会先设置内部游标值，然后唤醒等待的事件处理者。

最后，看下剩下的方法： 

```java
@Override  
public boolean isAvailable(long sequence){  
    return sequence <= cursor.get();  
}  

@Override  
public long getHighestPublishedSequence(long lowerBound, long availableSequence){  
    return availableSequence;  
}  
```

下面再看下MultiProducerSequencer，还是先看结构：

```java
public final class MultiProducerSequencer extends AbstractSequencer{  
    private static final Unsafe UNSAFE = Util.getUnsafe();  
    private static final long BASE  = UNSAFE.arrayBaseOffset(int[].class);  
    private static final long SCALE = UNSAFE.arrayIndexScale(int[].class);  
    private final Sequence gatingSequenceCache = new Sequence(Sequencer.INITIAL_CURSOR_VALUE);  
    // availableBuffer是用来记录每一个ringbuffer槽的状态。  
    private final int[] availableBuffer;  
    private final int indexMask;  
    private final int indexShift;  
  
    public MultiProducerSequencer(int bufferSize, final WaitStrategy waitStrategy){  
        super(bufferSize, waitStrategy);  
        availableBuffer = new int[bufferSize];  
        indexMask = bufferSize - 1;  
        indexShift = Util.log2(bufferSize);  
        initialiseAvailableBuffer();  
    }
```

MultiProducerSequencer内部多了一个availableBuffer，是一个int型的数组，size大小和RingBuffer的Size一样大，用来追踪Ringbuffer每个槽的状态，构造MultiProducerSequencer的时候会进行初始化，availableBuffer数组中的每个元素会被初始化成-1。

再看下里面的方法实现： 

```java
@Override
public boolean hasAvailableCapacity(final int requiredCapacity)
{
    return hasAvailableCapacity(gatingSequences, requiredCapacity, cursor.get());
}

private boolean hasAvailableCapacity(Sequence[] gatingSequences, final int requiredCapacity, long cursorValue)
{
    long wrapPoint = (cursorValue + requiredCapacity) - bufferSize;
    long cachedGatingSequence = gatingSequenceCache.get();

    if (wrapPoint > cachedGatingSequence || cachedGatingSequence > cursorValue)
    {
        long minSequence = Util.getMinimumSequence(gatingSequences, cursorValue);
        gatingSequenceCache.set(minSequence);

        if (wrapPoint > minSequence)
        {
            return false;
        }
    }

    return true;
}
```

逻辑和前面SingleProducerSequencer内部一样，区别是这里使用了cursor.get()，里面获取的是一个volatile的value值。 

```java
@Override
public long next(int n)
{
    if (n < 1)
    {
        throw new IllegalArgumentException("n must be > 0");
    }

    long current;
    long next;

    do
    {
        current = cursor.get();
        next = current + n;

        long wrapPoint = next - bufferSize;
        long cachedGatingSequence = gatingSequenceCache.get();

        if (wrapPoint > cachedGatingSequence || cachedGatingSequence > current)
        {
            long gatingSequence = Util.getMinimumSequence(gatingSequences, current);

            if (wrapPoint > gatingSequence)
            {
                LockSupport.parkNanos(1); // TODO, should we spin based on the wait strategy?
                continue;
            }

            gatingSequenceCache.set(gatingSequence);
        }
        else if (cursor.compareAndSet(current, next)) // 满足消费条件，有空余的空间让生产者写入，使用CAS算法，成功则跳出本次循环，不成功则重来  
        {
            break;
        }
    }
    while (true);

    return next;
}
```

逻辑还是一样，区别是里面的增加当前序列值是原子操作，多了一个CAS算法，获取消费者最小序列号的while循环和放到外面和CAS的while循环合并。

其他的方法都类似，都能保证多线程下的安全操作，唯一有点不同的是publish方法，看下：

```java
@Override
public void publish(long lo, long hi)
{
    for (long l = lo; l <= hi; l++)
    {
        setAvailable(l);
    }
    waitStrategy.signalAllWhenBlocking();
}

private void setAvailable(final long sequence)
{
    setAvailableBufferValue(calculateIndex(sequence), calculateAvailabilityFlag(sequence));
}

private void setAvailableBufferValue(int index, int flag)
{
    long bufferAddress = (index * SCALE) + BASE;
    UNSAFE.putOrderedInt(availableBuffer, bufferAddress, flag);
}

private int calculateAvailabilityFlag(final long sequence)
{
    return (int) (sequence >>> indexShift);
}

private int calculateIndex(final long sequence)
{
    return ((int) sequence) & indexMask;
}
```

方法中会将当前序列值的可用状态记录到availableBuffer里面，而记录的这个值其实就是sequence除以bufferSize，也就是当前sequence绕buffer的圈数。 

```java
@Override
public boolean isAvailable(long sequence)
{
    int index = calculateIndex(sequence);
    int flag = calculateAvailabilityFlag(sequence);
    long bufferAddress = (index * SCALE) + BASE;
    return UNSAFE.getIntVolatile(availableBuffer, bufferAddress) == flag;
}
// 对于多生产者模式，如果当前序列值可用，但是之前的还不可用，也是不可以的
@Override
public long getHighestPublishedSequence(long lowerBound, long availableSequence) {
  	// lowerBound：申请的序列值，availableSequence：可用的序列值
    for (long sequence = lowerBound; sequence <= availableSequence; sequence++) {
      	// 此时，sequence <= availableSequence，遍历 sequence --> availableSequence
        if (!isAvailable(sequence)) // 找到最前一个【准备就绪】，可以被消费的event对应的序列值
        {
            return sequence - 1; // 最小值为：sequence-1
        }
    }

    return availableSequence;
}
```

isAvailable方法也好理解了，getHighestPublishedSequence方法基于isAvailable实现。

大概了解了Sequencer的功能和实现以后，接下来看一下序列相关的一些类：

首先看下SequenceBarrier这个接口： 

```java
public interface SequenceBarrier{  
  
    /** 
     * 等待一个序列变为可用，然后消费这个序列。明显是给事件处理者使用的
     * @param sequence EventProcessor传入的需要进行消费的起始sequence
     * @return the sequence up to which is available 这里并不保证返回值availableSequence一定等于given sequence，他们的大小关系取决于采用的WaitStrategy
     *         a.YieldingWaitStrategy：在自旋100次尝试后，会直接返回dependentSequence的最小seq，这时并不保证返回值>=given sequence
     *         b.BlockingWaitStrategy：则会阻塞等待given sequence可用为止，可用并不是说availableSequence == given sequence，而应当是指 >=
     *         c.SleepingWaitStrategy：首选会自旋100次，然后执行100次Thread.yield()，还是不行则LockSupport.parkNanos(1L)直到availableSequence >= given sequence
     */  
    long waitFor(long sequence) throws AlertException, InterruptedException, TimeoutException;  
    /** 
     * 获取当前可以读取的序列值
     */  
    long getCursor();  
    /** 
     * 当前栅栏是否发过通知
     */  
    boolean isAlerted();  
    /** 
     * 通知事件处理者状态变化，然后停留在这个状态上，直到状态被清除
     */  
    void alert();  
    /** 
     * 清除通知状态
     */  
    void clearAlert();  
    /** 
     * 检测是否发生了通知，如果已经发生了抛出AlertException异常
     */  
    void checkAlert() throws AlertException;  
}
```

SequenceBarrier主要是设置消费依赖的。比如某个消费者必须等它依赖的消费者消费完某个消息之后才可以消费该消息。

接下来看一下SequenceBarrier的实现ProcessingSequenceBarrier：

```java
final class ProcessingSequenceBarrier implements SequenceBarrier
{
    private final WaitStrategy waitStrategy; // 等待策略
    private final Sequence dependentSequence;  // 这个域可能指向一个序列组
    private volatile boolean alerted = false;
    private final Sequence cursorSequence;
    private final Sequencer sequencer;

    ProcessingSequenceBarrier(
        final Sequencer sequencer,
        final WaitStrategy waitStrategy,
        final Sequence cursorSequence,
        final Sequence[] dependentSequences)
    {
        this.sequencer = sequencer;
        this.waitStrategy = waitStrategy;
        this.cursorSequence = cursorSequence;
        if (0 == dependentSequences.length)
        {
            dependentSequence = cursorSequence;
        }
        else
        {
            dependentSequence = new FixedSequenceGroup(dependentSequences);
        }
    }

    @Override
    public long waitFor(final long sequence)
        throws AlertException, InterruptedException, TimeoutException
    {
        checkAlert(); // 先检测报警状态
        // 然后根据等待策略来等待可用的序列值，无可消费消息是该接口可能会阻塞，具体逻辑由WaitStrategy实现
        long availableSequence = waitStrategy.waitFor(sequence, cursorSequence, dependentSequence, this);

        if (availableSequence < sequence)
        {
            return availableSequence;  // 如果可用的序列值小于给定的要消费的序列值，那么直接返回
        }
        // 否则，要返回能安全使用的最大的序列值
        return sequencer.getHighestPublishedSequence(sequence, availableSequence);
    }

    @Override
    public long getCursor()
    {
        return dependentSequence.get();
    }

    @Override
    public boolean isAlerted()
    {
        return alerted;
    }

    @Override
    public void alert()
    {
        alerted = true; // 设置通知标记
        waitStrategy.signalAllWhenBlocking(); // 如果有线程以阻塞的方式等待序列，将其唤醒
    }

    @Override
    public void clearAlert()
    {
        alerted = false;
    }

    @Override
    public void checkAlert() throws AlertException
    {
        if (alerted)
        {
            throw AlertException.INSTANCE;
        }
    }
}
```

ProcessingSequenceBarrier中核心方法只有一个：waitFor(long sequence)，传入希望消费得到起始序号，返回值代表可用于消费处理的序号，一般返回可用序号>=sequence，但也不一定，具体看WaitStrategy实现。

通过waitFor()返回的是一批可用消息的序号，比如申请消费7号槽位，waitFor()返回的可能是8，表示从6到8这一批数据都已生产完毕可以进行消费。

再看一个SequenceGroup类：

```java
public final class SequenceGroup extends Sequence {
    private static final AtomicReferenceFieldUpdater<SequenceGroup, Sequence[]> SEQUENCE_UPDATER =
        AtomicReferenceFieldUpdater.newUpdater(SequenceGroup.class, Sequence[].class, "sequences");
    private volatile Sequence[] sequences = new Sequence[0];

    public SequenceGroup()
    {
        super(-1);
    }

    /**
     * 获取序列组中最小的序列值
     */
    @Override
    public long get()
    {
        return Util.getMinimumSequence(sequences);
    }

    /**
     * 将序列组中所有的序列设置为给定值
     */
    @Override
    public void set(final long value)
    {
        final Sequence[] sequences = this.sequences;
        for (Sequence sequence : sequences)
        {
            sequence.set(value);
        }
    }

    /**
     * 添加一个序列到序列组，这个方法只能在初始化的时候调用。
     * 运行时添加的话，使用addWhileRunning(Cursored, Sequence)
     */
    public void add(final Sequence sequence)
    {
        Sequence[] oldSequences;
        Sequence[] newSequences;
        do
        {
            oldSequences = sequences;
            final int oldSize = oldSequences.length;
            newSequences = new Sequence[oldSize + 1];
            System.arraycopy(oldSequences, 0, newSequences, 0, oldSize);
            newSequences[oldSize] = sequence;
        }
        while (!SEQUENCE_UPDATER.compareAndSet(this, oldSequences, newSequences));
    }

    /**
     * 将序列组中出现的第一个给定的序列移除
     */
    public boolean remove(final Sequence sequence)
    {
        return SequenceGroups.removeSequence(this, SEQUENCE_UPDATER, sequence);
    }

    /**
     * 获取序列组的大小
     */
    public int size()
    {
        return sequences.length;
    }

    /**
     * 在线程已经开始往Disruptor上发布事件后，添加一个序列到序列组。
     * 调用这个方法后，会将新添加的序列的值设置为游标的值。 
     */
    public void addWhileRunning(Cursored cursored, Sequence sequence)
    {
        SequenceGroups.addSequences(this, SEQUENCE_UPDATER, cursored, sequence);
    }
}
```

还有一个SequenceGroups类，是针对SequenceGroup的帮助类，里面提供了addSequences和removeSequence方法，都是原子操作。

小结，上面看了这么多序列的相关类，其实只需要记住三点：

1. 真正的序列是Sequence。
2. 事件发布者通过Sequencer的大部分功能来使用序列。
3. 事件处理者通过SequenceBarrier来使用序列。

## 队列 RingBuffer

RingBuffer是disruptor最重要的核心组件，如果以生产者/消费者模式来看待disruptor框架的话，那RingBuffer就是生产者和消费者的工作队列了。RingBuffer可以理解为是一个环形队列，那内部是怎么实现的呢？看下源码。

首先，RingBuffer实现了一系列接口，Cursored、EventSequencer和EventSink，Cursored上一节提过了，这里看下后面两个：

```java
public interface EventSequencer<T> extends DataProvider<T>, Sequenced
{

}

public interface DataProvider<T>{  
    T get(long sequence);  
} 
```

EventSequencer扩展了Sequenced，提供了一些序列功能；同时扩展了DataProvider，提供了按序列值来获取数据的功能。 

```java
public interface EventSink<E>{  
    void publishEvent(EventTranslator<E> translator);  
  
    boolean tryPublishEvent(EventTranslator<E> translator);  
  
    <A> void publishEvent(EventTranslatorOneArg<E, A> translator, A arg0);  
  
    <A> boolean tryPublishEvent(EventTranslatorOneArg<E, A> translator, A arg0);  
  
    <A, B> void publishEvent(EventTranslatorTwoArg<E, A, B> translator, A arg0, B arg1);  
  
    <A, B> boolean tryPublishEvent(EventTranslatorTwoArg<E, A, B> translator, A arg0, B arg1);  
  
    <A, B, C> void publishEvent(EventTranslatorThreeArg<E, A, B, C> translator, A arg0, B arg1, C arg2);  
  
    <A, B, C> boolean tryPublishEvent(EventTranslatorThreeArg<E, A, B, C> translator, A arg0, B arg1, C arg2);  
  
    void publishEvent(EventTranslatorVararg<E> translator, Object... args);  
  
    boolean tryPublishEvent(EventTranslatorVararg<E> translator, Object... args);  
  
    void publishEvents(EventTranslator<E>[] translators);  
  
    void publishEvents(EventTranslator<E>[] translators, int batchStartsAt, int batchSize);  
  
    boolean tryPublishEvents(EventTranslator<E>[] translators);  
  
    boolean tryPublishEvents(EventTranslator<E>[] translators, int batchStartsAt, int batchSize);  
  
    <A> void publishEvents(EventTranslatorOneArg<E, A> translator, A[] arg0);  
  
    <A> void publishEvents(EventTranslatorOneArg<E, A> translator, int batchStartsAt, int batchSize, A[] arg0);  
  
    <A> boolean tryPublishEvents(EventTranslatorOneArg<E, A> translator, A[] arg0);  
  
    <A> boolean tryPublishEvents(EventTranslatorOneArg<E, A> translator, int batchStartsAt, int batchSize, A[] arg0);  
  
    <A, B> void publishEvents(EventTranslatorTwoArg<E, A, B> translator, A[] arg0, B[] arg1);  
  
    <A, B> void publishEvents(EventTranslatorTwoArg<E, A, B> translator, int batchStartsAt, int batchSize, A[] arg0, B[] arg1);  
  
    <A, B> boolean tryPublishEvents(EventTranslatorTwoArg<E, A, B> translator, A[] arg0, B[] arg1);  
  
    <A, B> boolean tryPublishEvents(EventTranslatorTwoArg<E, A, B> translator, int batchStartsAt, int batchSize, A[] arg0, B[] arg1);  
  
    <A, B, C> void publishEvents(EventTranslatorThreeArg<E, A, B, C> translator, A[] arg0, B[] arg1, C[] arg2);  
  
    <A, B, C> void publishEvents(EventTranslatorThreeArg<E, A, B, C> translator, int batchStartsAt, int batchSize, A[] arg0, B[] arg1, C[] arg2);  
  
    <A, B, C> boolean tryPublishEvents(EventTranslatorThreeArg<E, A, B, C> translator, A[] arg0, B[] arg1, C[] arg2);  
  
    <A, B, C> boolean tryPublishEvents(EventTranslatorThreeArg<E, A, B, C> translator, int batchStartsAt, int batchSize, A[] arg0, B[] arg1, C[] arg2);  
  
    void publishEvents(EventTranslatorVararg<E> translator, Object[]... args);  
  
    void publishEvents(EventTranslatorVararg<E> translator, int batchStartsAt, int batchSize, Object[]... args);  
  
    boolean tryPublishEvents(EventTranslatorVararg<E> translator, Object[]... args);  
  
    boolean tryPublishEvents(EventTranslatorVararg<E> translator, int batchStartsAt, int batchSize, Object[]... args);  
}  
```

可见，EventSink主要是提供发布事件(就是往队列上放数据)的功能，接口上定义了以各种姿势发布事件的方法。

了解了RingBuffer的接口功能，下面看下RingBuffer的结构：

```java
abstract class RingBufferPad
{
    protected long p1, p2, p3, p4, p5, p6, p7;
}

abstract class RingBufferFields<E> extends RingBufferPad
{
    private static final int BUFFER_PAD;
    private static final long REF_ARRAY_BASE;
    private static final int REF_ELEMENT_SHIFT;
    private static final Unsafe UNSAFE = Util.getUnsafe();

    static
    {
        final int scale = UNSAFE.arrayIndexScale(Object[].class);
        if (4 == scale) // 引用大小为4字节
        {
            REF_ELEMENT_SHIFT = 2;
        }
        else if (8 == scale)
        {
            REF_ELEMENT_SHIFT = 3;
        }
        else
        {
            throw new IllegalStateException("Unknown pointer size");
        }
        BUFFER_PAD = 128 / scale;
        // Including the buffer pad in the array base offset
        REF_ARRAY_BASE = UNSAFE.arrayBaseOffset(Object[].class) + (BUFFER_PAD << REF_ELEMENT_SHIFT);
    }

    private final long indexMask;
    private final Object[] entries;
    protected final int bufferSize;
    protected final Sequencer sequencer;

    RingBufferFields(
        EventFactory<E> eventFactory,
        Sequencer sequencer) {
      	// “帮手”，主要用来处理sequence申请、维护以及发布等工作
        this.sequencer = sequencer;
        this.bufferSize = sequencer.getBufferSize();

        if (bufferSize < 1)
        {
            throw new IllegalArgumentException("bufferSize must not be less than 1");
        }
        if (Integer.bitCount(bufferSize) != 1)
        {
            throw new IllegalArgumentException("bufferSize must be a power of 2");
        }
				// indexMask主要是为了使用位运算取模的，很多源码里都能看到这类优化
        this.indexMask = bufferSize - 1;
      	// 可以看到这个数组除了正常的size之外还有填充的元素，这个是为了解决false sharing的
        this.entries = new Object[sequencer.getBufferSize() + 2 * BUFFER_PAD];
        fill(eventFactory); // 预先填充数组元素，这对垃圾回收很优化，后续发布事件等操作都不需要创建对象，而只需要即可
    }

    private void fill(EventFactory<E> eventFactory)
    {
        for (int i = 0; i < bufferSize; i++)
        {
            entries[BUFFER_PAD + i] = eventFactory.newInstance();
        }
    }

    @SuppressWarnings("unchecked")
    protected final E elementAt(long sequence)
    {
        return (E) UNSAFE.getObject(entries, REF_ARRAY_BASE + ((sequence & indexMask) << REF_ELEMENT_SHIFT));
    }
}

public final class RingBuffer<E> extends RingBufferFields<E> implements Cursored, EventSequencer<E>, EventSink<E>
{
    public static final long INITIAL_CURSOR_VALUE = Sequence.INITIAL_VALUE;
    protected long p1, p2, p3, p4, p5, p6, p7;

    RingBuffer(
        EventFactory<E> eventFactory,
        Sequencer sequencer)
    {
        super(eventFactory, sequencer);
    }

```

RingBuffer的内部结构明确了：内部用数组来实现，同时有保存数组长度的域bufferSize和下标掩码indexMask，还有一个sequencer。

这里要注意几点：

1. 整个RingBuffer内部做了大量的缓存行填充，前后各填充了56（7\*8）个字节，entries本身也根据引用大小进行了填充，假设引用大小为4字节，那么entries数组两侧就要个填充32个空数组位。也就是说，实际的数组长度比bufferSize要大。所以可以看到根据序列从entries中取元素的方法elementAt内部做了一些调整，不是单纯的取模。

​       2.bufferSize必须是2的幂，indexMask就是bufferSize-1，这样取模更高效(sequence&indexMask)。

​       3.初始化时需要传入一个EventFactory，用来做队列内事件的预填充。

总结下RingBuffer的特点：内部做了细致的缓存行填充，避免伪共享；内部队列基于数组实现，能很好的利用程序的局部性；队列上的事件槽会不断重复利用，不受Java GC的影响。

从上面的代码看到，RingBuffer对本包外屏蔽了构造方法，那么怎创建RingBuffer实例呢？ 

```java
public static <E> RingBuffer<E> createMultiProducer(
    EventFactory<E> factory,
    int bufferSize,
    WaitStrategy waitStrategy)
{
    MultiProducerSequencer sequencer = new MultiProducerSequencer(bufferSize, waitStrategy);

    return new RingBuffer<E>(factory, sequencer);
}

public static <E> RingBuffer<E> createMultiProducer(EventFactory<E> factory, int bufferSize)
{
    return createMultiProducer(factory, bufferSize, new BlockingWaitStrategy());
}

public static <E> RingBuffer<E> createSingleProducer(
    EventFactory<E> factory,
    int bufferSize,
    WaitStrategy waitStrategy)
{
    SingleProducerSequencer sequencer = new SingleProducerSequencer(bufferSize, waitStrategy);

    return new RingBuffer<E>(factory, sequencer);
}

public static <E> RingBuffer<E> createSingleProducer(EventFactory<E> factory, int bufferSize)
{
    return createSingleProducer(factory, bufferSize, new BlockingWaitStrategy());
}

public static <E> RingBuffer<E> create(
    ProducerType producerType,
    EventFactory<E> factory,
    int bufferSize,
    WaitStrategy waitStrategy)
{
    switch (producerType)
    {
        case SINGLE:
            return createSingleProducer(factory, bufferSize, waitStrategy);
        case MULTI:
            return createMultiProducer(factory, bufferSize, waitStrategy);
        default:
            throw new IllegalStateException(producerType.toString());
    }
}
```

可见，RingBuffer提供了静态工厂方法分别针对单事件发布者和多事件发布者的情况进行RingBuffer实例创建。

RingBuffer方法实现也比较简单，看几个：

```java
@Override  
public E get(long sequence){  
    return elementAt(sequence);  
}
```

事件发布者和事件处理者申请到序列后，都会通过这个方法从序列上获取事件槽来发布或者消费事件。

```java
@Override  
public long next(int n){  
    return sequencer.next(n);  
}
```

next系列的方法是通过内部的sequencer来实现的。

```java
@Deprecated
public boolean isPublished(long sequence)
{
    return sequencer.isAvailable(sequence);
}
```

判断某个序列是否已经被事件发布者发布事件。 

```java
public void addGatingSequences(Sequence... gatingSequences){  
    sequencer.addGatingSequences(gatingSequences);  
}  
  
public long getMinimumGatingSequence(){  
    return sequencer.getMinimumSequence();  
}  
  
public boolean removeGatingSequence(Sequence sequence){  
    return sequencer.removeGatingSequence(sequence);  
}
```

追踪序列相关的方法。

```java
@Override
public void publishEvent(EventTranslator<E> translator)
{
    final long sequence = sequencer.next();
    translateAndPublish(translator, sequence);
}

private void translateAndPublish(EventTranslator<E> translator, long sequence)
{
    try
    {
        translator.translateTo(get(sequence), sequence);
    }
    finally
    {
        sequencer.publish(sequence);
    }
}
```

可见，发布事件分三步：

​       1.申请序列。

​       2.填充事件。

​       3.提交序列。

其他方法实现都很简单，这里不啰嗦了。

小结：
有关RingBuffer要记住以下几点：

1. RingBuffer是协调事件发布者和事件处理者的中间队列，事件发布者发布事件放到RingBuffer，事件处理者从RingBuffer上拿事件进行消费。
2. RingBuffer可以认为是一个环形队列，底层由数组实现。内部做了大量的缓存行填充，保存事件使用的数组的长度必须是2的幂，这样可以高效的取模（取模本身就包含绕回逻辑，按照序列不断的增长，形成一个环形轨迹）。由于RingBuffer这样的特性，也避免了GC带来的性能影响，因为RingBuffer本身永远不会被GC。
3. RingBuffer和普通的FIFO队列相比还有一个重要的区别就是，RingBuffer避免了头尾节点的竞争，多个事件发布者/事件处理者之间不必竞争同一个节点，只需要安全申请序列值各自存取事件就好了。

## 发布事件

前面两节看了disruptor中的序列和队列，这一节说一下怎么往RingBuffer中发布事件。这里也需要明确一下，和一般的生产者/消费者模式不同（如果以生产者/消费者的模式来看待disruptor的话），disruptor中队列里面的数据一般称为事件，RingBuffer中提供了发布事件的方法，另外也提供了专门的处理事件的类。

其实在disruptor中，RingBuffer也提供了一部分生产的功能，里面提供了大量的发布事件的方法。

上一节看到的RingBuffer的构造方法，需要传一个EventFactory做事件的预填充：

```java
// RingBuffer.java
RingBuffer(EventFactory<E> eventFactory,  
           Sequencer       sequencer){  
    super(eventFactory, sequencer);  
}

// RingBufferFields.java
RingBufferFields(EventFactory<E> eventFactory,  
                 Sequencer       sequencer){  
    ...  
    //最后要填充事件  
    fill(eventFactory);  
}  

private void fill(EventFactory<E> eventFactory){  
    for (int i = 0; i < bufferSize; i++){  
        entries[BUFFER_PAD + i] = eventFactory.newInstance();  
    }  
}  

// EventFactory.java
public interface EventFactory<T>
{
    T newInstance();
}
```

再看下RingBuffer的发布事件方法：

```java
@Override
public void publishEvent(EventTranslator<E> translator)
{
    final long sequence = sequencer.next();
    translateAndPublish(translator, sequence);
}

private void translateAndPublish(EventTranslator<E> translator, long sequence)
{
    try
    {
        translator.translateTo(get(sequence), sequence);
    }
    finally
    {
        sequencer.publish(sequence);
    }
}
```

在发布事件时需要传一个事件转换的接口，内部用这个接口做一下数据到事件的转换。看下这个接口：

```java
public interface EventTranslator<T>
{
    /**
     * Translate a data representation into fields set in given event
     *
     * @param event    into which the data should be translated.
     * @param sequence that is assigned to event.
     */
    void translateTo(T event, long sequence);
}
```

可见，具体的生产者可以实现这个接口，将需要发布的数据放到这个事件里面，一般是设置到事件的某个域上。

好，来看个例子理解一下。

首先我们定义好数据： 

```java
public class MyData {  
    private int id;  
    private String value;  
    public MyData(int id, String value) {  
        this.id = id;  
        this.value = value;  
    }  
  
    ...getter setter...  
  
    @Override  
    public String toString() {  
        return "MyData [id=" + id + ", value=" + value + "]";  
    }  
      
} 
```

然后针对我们的数据定义事件：

```java
public class MyDataEvent {  
    private MyData data;  
    public MyData getData() {  
        return data;  
    }  
    public void setData(MyData data) {  
        this.data = data;  
    }  
      
}
```

接下来需要给出一个EventFactory提供给RingBuffer做事件预填充：

```java
public class MyDataEventFactory implements EventFactory<MyDataEvent>{  
    @Override  
    public MyDataEvent newInstance() {  
        return new MyDataEvent();  
    }  
}
```

好了，可以初始化RingBuffer了：

```java
public static void main(String[] args) {  
    RingBuffer<MyDataEvent> ringBuffer = RingBuffer.createSingleProducer(new MyDataEventFactory(), 1024);  
    MyDataEvent dataEvent = ringBuffer.get(0);  
    System.out.println("Event = " + dataEvent);  
    System.out.println("Data = " + dataEvent.getData());  
}  
```

输出如下：

```java
Event = com.mjf.disruptor.product.MyDataEvent@5c647e05  
Data = null  
```

首先要注意，RingBuffer里面是MydataEvent，而不是MyData；其次我们构造好了RingBuffer，里面就已经填充了事件，我们可以取一个事件出来，发现里面的数据是空的。

下面就是怎么往RingBuffer里面放数据了，也就是事件发布者要干活了。我们上面看到了，要使用RingBuffer发布一个事件，需要一个事件转换器接口，针对我们的数据实现一个： 

```java
public class MyDataEventTranslator implements EventTranslator<MyDataEvent>{  
    @Override  
    public void translateTo(MyDataEvent event, long sequence) {  
        //新建一个数据  
        MyData data = new MyData(1, "holy shit!");  
        //将数据放入事件中。  
        event.setData(data);  
    }  
}  
```

有了转换器，我们就可以嗨皮的发布事件了：

```java
public static void main(String[] args) {  
    RingBuffer<MyDataEvent> ringBuffer = RingBuffer.createSingleProducer(new MyDataEventFactory(), 1024);  
    // 发布事件!!!  
    ringBuffer.publishEvent(new MyDataEventTranslator());  
      
    MyDataEvent dataEvent0 = ringBuffer.get(0);  
    System.out.println("Event = " + dataEvent0);  
    System.out.println("Data = " + dataEvent0.getData());  
    MyDataEvent dataEvent1 = ringBuffer.get(1);  
    System.out.println("Event = " + dataEvent1);  
    System.out.println("Data = " + dataEvent1.getData());  
} 
```

输出如下：

```java
Event = com.mjf.disruptor.product.MyDataEvent@5c647e05  
Data = MyData [id=1, value=holy shit!]  
Event = com.mjf.disruptor.product.MyDataEvent@33909752  
Data = null 
```

可见，我们已经成功了发布了一个事件到RingBuffer，由于是从序列0开始发布，所以我们从序列0可以读出这个数据。因为只发布了一个，所以序列1上还是没有数据。

当然也有其他姿势的转换器： 

```java
public class MyDataEventTranslatorWithIdAndValue implements EventTranslatorTwoArg<MyDataEvent, Integer, String>{  
    @Override  
    public void translateTo(MyDataEvent event, long sequence, Integer id,  
            String value) {  
        MyData data = new MyData(id, value);  
        event.setData(data);  
    }  
}
```

当然也可以直接利用RingBuffer来发布事件，不需要转换器：

```java
public static void main(String[] args) {  
    RingBuffer<MyDataEvent> ringBuffer =   
            RingBuffer.createSingleProducer(new MyDataEventFactory(), 1024);  
    long sequence = ringBuffer.next();  
    try{  
        MyDataEvent event = ringBuffer.get(sequence);  
        MyData data = new MyData(2, "R u kidding me?");  
        event.setData(data);  
    }finally{  
        ringBuffer.publish(sequence);  
    }  
}
```

下面分别说一下单线程发布事件和多线程发布事件的流程。

前面我们构造RingBuffer使用的是单线程发布事件的模式：

```java
RingBuffer<MyDataEvent> ringBuffer =   
        RingBuffer.createSingleProducer(new MyDataEventFactory(), 1024); 
```

RingBuffer也支持多线程发布事件模式，还记得上一节分析的RingBuffer代码吧： 

```java
public static <E> RingBuffer<E> createMultiProducer(EventFactory<E> factory, int bufferSize){  
    return createMultiProducer(factory, bufferSize, new BlockingWaitStrategy());  
}  
```

当然也提供了比较全面的构造方法：

```java
public static <E> RingBuffer<E> create(ProducerType    producerType,  
                                       EventFactory<E> factory,  
                                       int             bufferSize,  
                                       WaitStrategy    waitStrategy){  
    switch (producerType){  
    case SINGLE:  
        return createSingleProducer(factory, bufferSize, waitStrategy);  
    case MULTI:  
        return createMultiProducer(factory, bufferSize, waitStrategy);  
    default:  
        throw new IllegalStateException(producerType.toString());  
    }  
}
```

这个方法支持传入一个枚举来选择使用哪种模式： 

```java
public enum ProducerType{  
    SINGLE,  
    MULTI  
} 
```

上面看过了单线程发布事件的例子，接下来看个多线程发布事件的：

```java
public static void main(String[] args) {  
    final RingBuffer<MyDataEvent> ringBuffer = RingBuffer.createMultiProducer(new MyDataEventFactory(), 1024);  
    final CountDownLatch latch = new CountDownLatch(100);  
    for(int i=0;i<100;i++){  
        final int index = i;  
        // 开启多个线程发布事件。  
        new Thread(new Runnable() {  
            @Override  
            public void run() {  
                long sequence = ringBuffer.next();  
                try{  
                    MyDataEvent event = ringBuffer.get(sequence);  
                    MyData data = new MyData(index, index+"s");  
                    event.setData(data);  
                }finally{  
                    ringBuffer.publish(sequence);  
                    latch.countDown();  
                }  
            }  
        }).start();  
    }  
    try {  
        latch.await();  
        // 最后观察下发布的时间。  
        for(int i=0;i<100;i++){  
            MyDataEvent event = ringBuffer.get(i);  
            System.out.println(event.getData());  
        }  
    } catch (InterruptedException e) {  
        e.printStackTrace();  
    }  
} 
```

如果多线程环境下使用单线程发布模式会有上面问题呢？

```java
public static void main(String[] args) {  
  	// 这里是单线程模式!!!  
    final RingBuffer<MyDataEvent> ringBuffer = RingBuffer.createSingleProducer(new MyDataEventFactory(), 1024);  
    final CountDownLatch latch = new CountDownLatch(100);  
    for(int i=0;i<100;i++){  
        final int index = i;  
        // 开启多个线程发布事件。  
        new Thread(new Runnable() {  
            @Override  
            public void run() {  
                long sequence = ringBuffer.next();  
                try{  
                    MyDataEvent event = ringBuffer.get(sequence);  
                    MyData data = new MyData(index, index+"s");  
                    event.setData(data);  
                }finally{  
                    ringBuffer.publish(sequence);  
                    latch.countDown();  
                }  
            }  
        }).start();  
    }  
    try {  
        latch.await();  
        // 最后观察下发布的时间。  
        for(int i=0;i<100;i++){  
            MyDataEvent event = ringBuffer.get(i);  
            System.out.println(event.getData());  
        }  
    } catch (InterruptedException e) {  
        e.printStackTrace();  
    }  
}  
```

输出如下： 

```java
...  
MyData [id=92, value=92s]  
MyData [id=93, value=93s]  
MyData [id=94, value=94s]  
MyData [id=95, value=95s]  
MyData [id=96, value=96s]  
MyData [id=97, value=97s]  
MyData [id=99, value=99s]  
MyData [id=98, value=98s]  
null  
null  
```

会发现，如果多线程发布事件的环境下，使用单线程发布事件模式，会有数据被覆盖的情况。所以使用时应该按照具体情况选择合理发布模式。

小结，如何往RingBuffer中发布事件：

1. 定义好要生产的数据和相应的事件类(里面存放数据)。
2. 定于好事件转换器或者直接用RingBuffer进行事件发布。
3. 明确发布场景，合理的选择发布模式(单线程还是多线程)。 

## 处理事件

可以分为单消费者和多消费者两种情况，单消费者只需要`disruptor.handleEventsWith();`就可以。

多消费者的情况分为两类：

- 广播：对于多个消费者，每条信息会达到所有的消费者，被多次处理，一般每个消费者业务逻辑不通，用于同一个消息的不同业务逻辑处理。又可细分为两种情况：

  - 消费者之间无依赖关系：

    假设目前有handler1，handler2，handler3三个消费者处理一批消息，每个消息都要被三个消费者处理到，三个消费者无依赖关系，则如下所示即可`disruptor.handleEventsWith(handler1,handler2,handler3);`

  - 消费者之间有依赖关系：

    假设handler3必须在handler1，handler2处理完成后进行处理，则如下所示即可
    `disruptor.handleEventsWith(handler1,handler2).then(handler3);`

- 分组：对于同一组内的多个消费者，每条信息只会被组内一个消费者处理，每个消费者业务逻辑一般相同，用于多消费者并发处理一组消息。对于消费者，需要实现WorkHandler而不是EventHandler。假设handler1，handler2，handler3都实现了WorkHandler，则调用以下代码就可以实现分组`disruptor.handleEventsWithWorkerPool(handler1, handler2, handler3);`，广播和分组之间也是可以排列组合的。

**tips**

disruptor也提供了函数让你自定义消费者之间的关系，如
`public EventHandlerGroup<T> handleEventsWith(final EventProcessor… processors)`
当然，必须对disruptor有足够的了解才能正确的在EventProcessor中实现多消费者正确的逻辑。

举个例子，假设在电商场景中，每产生一个订单都要发邮件和短信通知买家，如果产生了十个订单，就有以下两种情况要考虑：
第一种：要发十封邮件和十条短信，此时，邮件系统和短信系统是各自独立的，他们各自消费这十个订单的事件，也就是说十个事件被消费二十次，所以邮件系统和短信系统各自独立消费，彼此没有关系，如下图，一个原点代表一个事件：

<img src="http://blog-1259650185.cosbj.myqcloud.com/img/202202/13/1644743518.png" alt="8" style="zoom: 50%;" />

第二种：假设邮件系统处理能力差，为了提升处理能力，部署了两台邮件服务器，因此是这两台邮件服务器共同处理十个订单事件，合起来一共发送了十封邮件，如下图，一号邮件服务器和二号邮件服务器是共同消费，某个订单事件只会在一个邮件服务器被消费：

<img src="http://blog-1259650185.cosbj.myqcloud.com/img/202202/13/1644743562.png" alt="9" style="zoom:50%;" />

独立消费的核心知识点：

1. 使用的API是handleEventsWith
2. 业务处理逻辑放入EventHandler的实现类中
3. 内部实现用BatchEventProcessor类，一个消费者对应一个BatchEventProcessor实例，任务是获取事件再调用EventHandler的onEvent方法处理
4. **一个消费者对应一个SequenceBarrier实例**，用于等待可消费事件
5. **一个消费者对应一个Sequence实例**（BatchEventProcessor的成员变量），用于记录消费进度
6. 每个BatchEventProcessor实例都会被放入集合（consumerRepository.consumerInfos）。
7. disruptor的start方法中，会将BatchEventProcessor放入线程池执行，也就是说每个消费者都在独立线程中执行

共同消费的核心知识点：

1. 使用的API是handleEventsWithWorkerPool
2. 业务处理逻辑放入WorkHandler的实现类中
3. 内部实现用WorkerPool和WorkProcessor类合作完成的，**WorkerPool实例只有一个，每个消费者对应一个WorkProcessor实例**
   **SequenceBarrier实例只有一个**，用于等待可消费事件
4. **每个消费者都有自己的Sequence实例，另外还有一个公共的Sequence实例（WorkerPool的成员变量），用于记录消费进度**
5. WorkerPool实例会包裹成WorkerPoolInfo实例再放入集合（consumerRepository.consumerInfos）
6. disruptor的start方法中，会调用WorkerPool.start方法，这里面会将每个WorkProcessor放入线程池执行，也就是说每个消费者都在独立线程中执行

**精简的小结**
上述核心知识点还是有点多，咱们用对比来精简一下，以下是精华中的精华，真不能再省了，请重点关注：

1. 独立消费的每个消费者都有属于自己独有的SequenceBarrier实例，共同消费者是所有消费者共用同一个SequenceBarrier实例
2. 独立消费的每个消费者都有属于自己独有的Sequence实例，对于共同消费者，虽然他们也有属于自己的Sequence实例，但这个Sequence实例的值是从一个公共Sequence实例（WorkerPool的成员变量workSequence）得来的
3. 独立消费和共同消费都有自己的取数据再消费的代码，放在一起对比看就一目了然了，如下图，共同消费时，每个消费者的Sequence值其实来自公共Sequence实例，多线程之间用CAS竞争来抢占事件用于消费：

<img src="http://blog-1259650185.cosbj.myqcloud.com/img/202202/13/1644743866.png" alt="10" style="zoom:50%;" />

最后放上自制图一张，希望有一图胜千言的效果吧：

<img src="http://blog-1259650185.cosbj.myqcloud.com/img/202202/13/1644743924.png" alt="11" style="zoom:50%;" />

### event 模式

disruptor中提供了专门的事件处理器接口，先看下接口定义：

```java
/** 
 * 事件处理器会等待RingBuffer中的事件变为可用(可处理)，然后处理可用的事件。 
 * 一个事件处理器通常会关联一个线程。 
 */  
public interface EventProcessor extends Runnable{  
    /** 
     * 获取一个事件处理器使用的序列引用。 
     */  
    Sequence getSequence();  
  
    void halt();  
    boolean isRunning();  
}
```

它实现了Runnable接口，disruptor在启动的时候会将所有注册上来的EventProcessor提交到线程池中执行，因此，一个EventProcessor可以看着一个独立的线程流用于处理RingBuffer上的数据。

disruptor中提供了两类事件处理器**BatchEventProcessor（批处理）**、**WorkProcessor**，它的职责是从RingBuffer中获取可消费的事件，然后调用EventHandler/WorkHandler的onEvent方法。

EventProcessor通过调用SequenceBarrier.waitFor()方法获取可用消息事件的序号，其实SequenceBarrier内部还是调用WaitStrategy.waitFor()方法，WaitStrategy等待策略主要封装如果获取消息时没有可用消息时如何处理的逻辑信息，是自旋、休眠、直接返回等，不同场景需要使用不同策略才能实现最佳的性能。

接下来看第一个实现，BatchEventProcessor。先看下内部结构：

```java
public final class BatchEventProcessor<T> implements EventProcessor {
    private static final int IDLE = 0;
    private static final int HALTED = IDLE + 1;
    private static final int RUNNING = HALTED + 1;
	  // 表示当前事件处理器的运行状态
    private final AtomicInteger running = new AtomicInteger(IDLE);
  	// 异常处理器
    private ExceptionHandler<? super T> exceptionHandler;
  	// 数据提供者。(RingBuffer)
    private final DataProvider<T> dataProvider;
  	// 序列栅栏
    private final SequenceBarrier sequenceBarrier;
  	// 真正处理事件的回调接口
    private final EventHandler<? super T> eventHandler;
    // 事件处理器使用的序列
    private final Sequence sequence = new Sequence(Sequencer.INITIAL_CURSOR_VALUE);
  	// 超时处理器
    private final TimeoutHandler timeoutHandler;
    private final BatchStartAware batchStartAware;

    public BatchEventProcessor(
        final DataProvider<T> dataProvider,
        final SequenceBarrier sequenceBarrier,
        final EventHandler<? super T> eventHandler)
    {
        this.dataProvider = dataProvider;
        this.sequenceBarrier = sequenceBarrier;
        this.eventHandler = eventHandler;

        if (eventHandler instanceof SequenceReportingEventHandler)
        {
            ((SequenceReportingEventHandler<?>) eventHandler).setSequenceCallback(sequence);
        }

        batchStartAware =
            (eventHandler instanceof BatchStartAware) ? (BatchStartAware) eventHandler : null;
        timeoutHandler =
            (eventHandler instanceof TimeoutHandler) ? (TimeoutHandler) eventHandler : null;
    }

```

大体对内部结构有个印象，然后看一下功能方法的实现：

```java
@Override
public Sequence getSequence()
{
    return sequence;
}

@Override
public void halt()
{
    running.set(HALTED);
    sequenceBarrier.alert();
}

@Override
public boolean isRunning()
{
    return running.get() != IDLE;
}
```

这几个方法都比较容易理解，重点看下run方法： 

```java
@Override
public void run()
{
    if (running.compareAndSet(IDLE, RUNNING)) // 状态设置与检测
    {
        sequenceBarrier.clearAlert(); // 先清除序列栅栏的通知状态
        // 如果eventHandler实现了LifecycleAware，这里会对其进行一个启动通知
        notifyStart();
        try
        {
            if (running.get() == RUNNING)
            {
                processEvents();
            }
        }
        finally
        {
            notifyShutdown(); // processEvents退出后，如果eventHandler实现了LifecycleAware，这里会对其进行一个停止通知。
            running.set(IDLE);  // 设置事件处理器运行状态为停止
        }
    }
    else
    {
        if (running.get() == RUNNING)
        {
            throw new IllegalStateException("Thread is already running");
        }
        else
        {
            earlyExit();
        }
    }
}

private void processEvents() {
    T event = null;
    long nextSequence = sequence.get() + 1L; // 获取要申请的序列值

    while (true) {
        try {
          	// 通过序列栅栏来等待可用的序列值，也就是已经被生产好的的sequence
            final long availableSequence = sequenceBarrier.waitFor(nextSequence); 
            if (batchStartAware != null) {
                batchStartAware.onBatchStart(availableSequence - nextSequence + 1);
            }
            // 得到可用的序列值后，【批量】处理nextSequence到availableSequence之间的事件（比如，sequence.get()=8，nextSequence=9，availableSequence=12）
          	 // 如果获取到的sequence大于等于nextSequence，说明有可以消费的event，从nextSequence(包含)到availableSequence(包含)这一段的事件就作为同一个批次
            while (nextSequence <= availableSequence) {
                event = dataProvider.get(nextSequence); // 获取事件
                eventHandler.onEvent(event, nextSequence, nextSequence == availableSequence); // 将事件交给eventHandler处理
                nextSequence++;
            }

            sequence.set(availableSequence); // 处理一批后，设置为【当前处理完成的最后序列值】，即一次性更新消费进度
        }
        catch (final TimeoutException e) {
            notifyTimeout(sequence.get()); // 如果发生超时，通知一下超时处理器(如果eventHandler同时实现了timeoutHandler，会将其设置为当前的超时处理器)
        }
        catch (final AlertException ex) {
            if (running.get() != RUNNING) // 如果捕获了序列栅栏变更通知，并且当前事件处理器停止了，那么退出主循环
            {
                break;
            }
        }
        catch (final Throwable ex) {
            handleEventException(ex, nextSequence, event); // 其他的异常都交给异常处理器进行处理
            sequence.set(nextSequence); // 处理异常后仍然会设置当前处理的最后的序列值，然后继续处理其他事件
            nextSequence++;
        }
    }
}
```

贴上其他方法：

```java
public void setExceptionHandler(final ExceptionHandler<? super T> exceptionHandler)
{
    if (null == exceptionHandler)
    {
        throw new NullPointerException();
    }

    this.exceptionHandler = exceptionHandler;
}


private void earlyExit()
{
    notifyStart();
    notifyShutdown();
}

private void notifyTimeout(final long availableSequence)
{
    try
    {
        if (timeoutHandler != null)
        {
            timeoutHandler.onTimeout(availableSequence);
        }
    }
    catch (Throwable e)
    {
        handleEventException(e, availableSequence, null);
    }
}

private void notifyStart()
{
    if (eventHandler instanceof LifecycleAware)
    {
        try
        {
            ((LifecycleAware) eventHandler).onStart();
        }
        catch (final Throwable ex)
        {
            handleOnStartException(ex);
        }
    }
}

private void notifyShutdown()
{
    if (eventHandler instanceof LifecycleAware)
    {
        try
        {
            ((LifecycleAware) eventHandler).onShutdown();
        }
        catch (final Throwable ex)
        {
            handleOnShutdownException(ex);
        }
    }
}
```

总结一下BatchEventProcessor：

1. BatchEventProcessor内部会记录自己的序列、运行状态。
2. BatchEventProcessor需要外部提供数据提供者(其实就是队列-RingBuffer)、序列栅栏、异常处理器。
3. BatchEventProcessor其实是将事件委托给内部的EventHandler来处理的。

知道了这些，再结合前几节的内容，来写个生产者/消费者模式的代码爽一下吧！

首先，要定义具体处理事件的EventHandler，先来看下这个接口：

```java
public interface EventHandler<T>{  
    /** 
     * Called when a publisher has published an event to the {@link RingBuffer} 
     * 
     * @param event published to the {@link RingBuffer} 
     * @param sequence of the event being processed 
     * @param endOfBatch 表示消费到的本次事件是否是这个批次中的最后一个
     * @throws Exception if the EventHandler would like the exception handled further up the chain. 
     */  
    void onEvent(T event, long sequence, boolean endOfBatch) throws Exception;  
}  
```

接口很明确，没什么要解释的，然后定义我们的具体处理方式： 

```java
public class MyDataEventHandler implements EventHandler<MyDataEvent>{  
    @Override  
    public void onEvent(MyDataEvent event, long sequence, boolean endOfBatch) throws Exception {  
        // 注意这里小睡眠了一下!!  
        TimeUnit.SECONDS.sleep(3);  
        System.out.println("handle event's data:" + event.getData() +"isEndOfBatch:"+endOfBatch);  
    }  
}
```

然后是主程序：

```java
public static void main(String[] args) {  
    // 创建一个RingBuffer，注意容量是4。  
    RingBuffer<MyDataEvent> ringBuffer = RingBuffer.createSingleProducer(new MyDataEventFactory(), 4);  
    // 创建一个事件处理器。  
    BatchEventProcessor<MyDataEvent> batchEventProcessor =  
            /* 
             * 注意参数：数据提供者就是RingBuffer、序列栅栏也来自RingBuffer 
             * EventHandler使用自定义的。 
             */  
            new BatchEventProcessor<MyDataEvent>(ringBuffer,   
                    ringBuffer.newBarrier(), new MyDataEventHandler());  
    // 将事件处理器本身的序列设置为ringBuffer的追踪序列。  
    ringBuffer.addGatingSequences(batchEventProcessor.getSequence());  
    // 启动事件处理器。  
    new Thread(batchEventProcessor).start();  
    // 往RingBuffer上发布事件  
    for(int i=0;i<10;i++){  
        ringBuffer.publishEvent(new MyDataEventTranslatorWithIdAndValue(), i, i+"s");  
        System.out.println("发布事件["+i+"]");  
    }  
      
    try {  
        System.in.read();  
    } catch (IOException e) {  
        e.printStackTrace();  
    }  
} 
```

注意到当前RingBuffer只有4个空间，然后发了10个事件，而且消费者内部会sleep一下，所以会不会出现事件覆盖的情况呢（生产者在RingBuffer上绕了一圈从后面追上了消费者）。

看下输出： 

```java
发布事件[0]  
发布事件[1]  
发布事件[2]  
发布事件[3]  
handle event's data:MyData [id=0, value=0s]isEndOfBatch:true  
发布事件[4]  
handle event's data:MyData [id=1, value=1s]isEndOfBatch:false  
handle event's data:MyData [id=2, value=2s]isEndOfBatch:false  
handle event's data:MyData [id=3, value=3s]isEndOfBatch:true  
发布事件[5]  
发布事件[6]  
发布事件[7]  
handle event's data:MyData [id=4, value=4s]isEndOfBatch:true  
发布事件[8]  
handle event's data:MyData [id=5, value=5s]isEndOfBatch:false  
handle event's data:MyData [id=6, value=6s]isEndOfBatch:false  
handle event's data:MyData [id=7, value=7s]isEndOfBatch:true  
发布事件[9]  
handle event's data:MyData [id=8, value=8s]isEndOfBatch:true  
handle event's data:MyData [id=9, value=9s]isEndOfBatch:true  
```

发现其实并没有覆盖事件的情况，而是发布程序会等待事件处理程序处理完毕，有可发布的空间，再进行发布。还记得前面文章分析的序列的next()方法，里面会通过观察追踪序列的情况来决定是否等待，也就是说，RingBuffer需要追踪事件处理器的序列，这个关系怎么确立的呢？就是上面代码中的这句话： 

```java
// 将事件处理器本身的序列设置为ringBuffer的追踪序列。  
ringBuffer.addGatingSequences(batchEventProcessor.getSequence());  
```

接下来再改一下程序，将MyDataEventHandler中的睡眠代码去掉，然后主程序中发布事件后加上睡眠代码：

```java
public class MyDataEventHandler implements EventHandler<MyDataEvent>{  
    @Override  
    public void onEvent(MyDataEvent event, long sequence, boolean endOfBatch)  
            throws Exception {  
        // TimeUnit.SECONDS.sleep(3);  
        System.out.println("handle event's data:" + event.getData() +"isEndOfBatch:"+endOfBatch);  
    }  
}  
    // 主程序  
    public static void main(String[] args) {  
        // 创建一个RingBuffer，注意容量是4。  
        RingBuffer<MyDataEvent> ringBuffer =   
                RingBuffer.createSingleProducer(new MyDataEventFactory(), 4);  
        // 创建一个事件处理器。  
        BatchEventProcessor<MyDataEvent> batchEventProcessor =  
                /* 
                 * 注意参数：数据提供者就是RingBuffer、序列栅栏也来自RingBuffer 
                 * EventHandler使用自定义的。 
                 */  
                new BatchEventProcessor<MyDataEvent>(ringBuffer,   
                        ringBuffer.newBarrier(), new MyDataEventHandler());  
        // 将事件处理器本身的序列设置为ringBuffer的追踪序列。  
        ringBuffer.addGatingSequences(batchEventProcessor.getSequence());  
        // 启动事件处理器。  
        new Thread(batchEventProcessor).start();  
        // 往RingBuffer上发布事件  
        for(int i=0;i<10;i++){  
            ringBuffer.publishEvent(new MyDataEventTranslatorWithIdAndValue(), i, i+"s");  
            System.out.println("发布事件["+i+"]");  
            try {  
                TimeUnit.SECONDS.sleep(3);//睡眠！！！  
            } catch (InterruptedException e) {  
                e.printStackTrace();  
            }  
        }  
          
        try {  
            System.in.read();  
        } catch (IOException e) {  
            e.printStackTrace();  
        }  
    }
```

这种情况下，事件处理很快，但是发布事件很慢，事件处理器会等待事件的发布么？

```java
发布事件[0]  
handle event's data:MyData [id=0, value=0s]isEndOfBatch:true  
发布事件[1]  
handle event's data:MyData [id=1, value=1s]isEndOfBatch:true  
发布事件[2]  
handle event's data:MyData [id=2, value=2s]isEndOfBatch:true  
发布事件[3]  
handle event's data:MyData [id=3, value=3s]isEndOfBatch:true  
发布事件[4]  
handle event's data:MyData [id=4, value=4s]isEndOfBatch:true  
发布事件[5]  
handle event's data:MyData [id=5, value=5s]isEndOfBatch:true  
发布事件[6]  
handle event's data:MyData [id=6, value=6s]isEndOfBatch:true  
发布事件[7]  
handle event's data:MyData [id=7, value=7s]isEndOfBatch:true  
发布事件[8]  
handle event's data:MyData [id=8, value=8s]isEndOfBatch:true  
发布事件[9]  
handle event's data:MyData [id=9, value=9s]isEndOfBatch:true
```

可见是会等待的，关键就是，事件处理器用的是RingBuffer的序列栅栏，会在栅栏上waitFor事件发布者： 

```java
new BatchEventProcessor<MyDataEvent>(ringBuffer,
                                     /*注意这里*/
                                     ringBuffer.newBarrier(), new MyDataEventHandler());  
```

接下来，我们在改变一下姿势，再加一个事件处理器，看看会发生什么：

```java
public class KickAssEventHandler implements EventHandler<MyDataEvent>{  
    @Override  
    public void onEvent(MyDataEvent event, long sequence, boolean endOfBatch) throws Exception {  
        System.out.println("kick your ass "+sequence+" times!!!!");  
    }  
}
```

主程序如下：

```java
public static void main(String[] args) {  
    // 创建一个RingBuffer，注意容量是4。  
    RingBuffer<MyDataEvent> ringBuffer =   
            RingBuffer.createSingleProducer(new MyDataEventFactory(), 4);  
    // 创建一个事件处理器。  
    BatchEventProcessor<MyDataEvent> batchEventProcessor =  
            /* 
             * 注意参数：数据提供者就是RingBuffer、序列栅栏也来自RingBuffer 
             * EventHandler使用自定义的。 
             */  
            new BatchEventProcessor<MyDataEvent>(ringBuffer,   
                    ringBuffer.newBarrier(), new MyDataEventHandler());  
    // 创建一个事件处理器。  
    BatchEventProcessor<MyDataEvent> batchEventProcessor2 =  
            /* 
             * 注意参数：数据提供者就是RingBuffer、序列栅栏也来自RingBuffer 
             * EventHandler使用自定义的。 
             */  
            new BatchEventProcessor<MyDataEvent>(ringBuffer,   
                    ringBuffer.newBarrier(), new KickAssEventHandler());  
    // 将事件处理器本身的序列设置为ringBuffer的追踪序列。  
    ringBuffer.addGatingSequences(batchEventProcessor.getSequence());  
    ringBuffer.addGatingSequences(batchEventProcessor2.getSequence());  
    // 启动事件处理器。  
    new Thread(batchEventProcessor).start();  
    new Thread(batchEventProcessor2).start();  
    // 往RingBuffer上发布事件  
    for(int i=0;i<10;i++){  
        ringBuffer.publishEvent(new MyDataEventTranslatorWithIdAndValue(), i, i+"s");  
        System.out.println("发布事件["+i+"]");  
        try {  
            TimeUnit.SECONDS.sleep(3);  
        } catch (InterruptedException e) {  
            e.printStackTrace();  
        }  
    }  
    try {  
        System.in.read();  
    } catch (IOException e) {  
        e.printStackTrace();  
    }  
}
```

看下输出：

```java
发布事件[0]  
kick your ass 0 times!!!!  
handle event's data:MyData [id=0, value=0s]isEndOfBatch:true  
发布事件[1]  
kick your ass 1 times!!!!  
handle event's data:MyData [id=1, value=1s]isEndOfBatch:true  
发布事件[2]  
handle event's data:MyData [id=2, value=2s]isEndOfBatch:true  
kick your ass 2 times!!!!  
发布事件[3]  
handle event's data:MyData [id=3, value=3s]isEndOfBatch:true  
kick your ass 3 times!!!!  
发布事件[4]  
kick your ass 4 times!!!!  
handle event's data:MyData [id=4, value=4s]isEndOfBatch:true  
发布事件[5]  
kick your ass 5 times!!!!  
handle event's data:MyData [id=5, value=5s]isEndOfBatch:true  
发布事件[6]  
handle event's data:MyData [id=6, value=6s]isEndOfBatch:true  
kick your ass 6 times!!!!  
发布事件[7]  
kick your ass 7 times!!!!  
handle event's data:MyData [id=7, value=7s]isEndOfBatch:true  
发布事件[8]  
kick your ass 8 times!!!!  
handle event's data:MyData [id=8, value=8s]isEndOfBatch:true  
发布事件[9]  
kick your ass 9 times!!!!  
handle event's data:MyData [id=9, value=9s]isEndOfBatch:true 
```

相当于有两个消费者，消费相同的数据，又有点像发布/订阅模式了，呵呵。

当然，按照上面源码的分析，我们还可以让我们的Eventhandler同时实现TimeoutHandler和LifecycleAware来做更多的事；还可以定制一个ExceptionHandler来处理异常情况（disruptor也提供了IgnoreExceptionHandler和FatalExceptionHandler两种ExceptionHandler实现，它们在异常处理时会记录不用级别的日志，后者还会抛出运行时异常）。

disruptor还提供了一个队列接口 —— EventPoller。通过这个接口也可以用RingBuffer中获取事件并处理，而且这个获取方式是无等待的，如果当前没有可处理的事件，会返回相应的状态——PollState。但注释说明这还是个实验性质的类，这里就不分析了。

### worker 模式

看完上面的内容，可能会有这样的疑惑：实际用的时候可能不会只用单线程来消费吧，能不能使用多个线程来消费同一批事件，每个线程消费这批事件中的一部分呢？

disruptor对这种情况也进行了支持，如果上面的叫Event模式，那么这个就叫Work模式吧。

首先要看下WorkProcessor，还是先看结构： 

```java
public final class WorkProcessor<T> implements EventProcessor {
    private final AtomicBoolean running = new AtomicBoolean(false);
    private final Sequence sequence = new Sequence(Sequencer.INITIAL_CURSOR_VALUE);
    private final RingBuffer<T> ringBuffer;
    private final SequenceBarrier sequenceBarrier;
    private final WorkHandler<? super T> workHandler;
    private final ExceptionHandler<? super T> exceptionHandler;
   // 多个处理者对同一个要处理事件的竞争，所以出现了一个workSequence，多个消费者共同使用，大家都从这个sequence里取得序列号，通过CAS保证线程安全
    private final Sequence workSequence;

    private final EventReleaser eventReleaser = new EventReleaser()
    {
        @Override
        public void release()
        {
            sequence.set(Long.MAX_VALUE);
        }
    };

    private final TimeoutHandler timeoutHandler;

    public WorkProcessor(
        final RingBuffer<T> ringBuffer,
        final SequenceBarrier sequenceBarrier,
        final WorkHandler<? super T> workHandler,
        final ExceptionHandler<? super T> exceptionHandler,
        final Sequence workSequence)
    {
        this.ringBuffer = ringBuffer;
        this.sequenceBarrier = sequenceBarrier;
        this.workHandler = workHandler;
        this.exceptionHandler = exceptionHandler;
        this.workSequence = workSequence;

        if (this.workHandler instanceof EventReleaseAware)
        {
            ((EventReleaseAware) this.workHandler).setEventReleaser(eventReleaser);
        }

        timeoutHandler = (workHandler instanceof TimeoutHandler) ? (TimeoutHandler) workHandler : null;
    }
```

看起来结构和BatchEventProcessor类似，区别是EventHandler变成了WorkHandler，还有了额外的workSequence和一个eventReleaser。

看下功能方法实现： 

```java
@Override  
public Sequence getSequence(){  
    return sequence;  
}  

@Override  
public void halt(){  
    running.set(false);  
    sequenceBarrier.alert();  
}  

@Override  
public boolean isRunning(){  
    return running.get();  
} 
```

这些方法和BatchEventProcessor的一样，不说了。看下主逻辑：

```java
@Override
public void run()
{
    if (!running.compareAndSet(false, true)) // 状态设置与检测
    {
        throw new IllegalStateException("Thread is already running");
    }
    sequenceBarrier.clearAlert(); // 先清除序列栅栏的通知状态

    notifyStart();  // 如果workHandler实现了LifecycleAware，这里会对其进行一个启动通知

    boolean processedSequence = true; // 标志位，用来标志一次消费过程
    long cachedAvailableSequence = Long.MIN_VALUE; // 用来缓存消费者可以使用的RingBuffer最大序列号
    long nextSequence = sequence.get(); // 记录下去RingBuffer取数据（要处理的事件）的序列号
    T event = null;
    while (true)
    {
        try
        {
          	// 判断上一个事件是否已经处理完毕。每次消费开始执行
            if (processedSequence) 
            {
                processedSequence = false; // 如果处理完毕，重置标识
                do
                { // 原子的获取下一要处理事件的序列值。
                    nextSequence = workSequence.get() + 1L;
                    sequence.set(nextSequence - 1L);
                }
                while (!workSequence.compareAndSet(nextSequence - 1L, nextSequence));
            }
            // 检查序列值是否需要申请。这一步是为了防止和事件生产者冲突。
          	// 如果可使用的最大序列号cachedAvaliableSequence大于等于我们要使用的序列号nextSequence，
          	// 直接从RingBuffer取数据；不然进入else
            if (cachedAvailableSequence >= nextSequence) {
                event = ringBuffer.get(nextSequence); // 从RingBuffer上获取事件
                workHandler.onEvent(event); // 委托给workHandler处理事件
                processedSequence = true; // 一次消费结束，设置事件处理完成标识
            } else {
                // 如果需要申请，通过序列栅栏来申请可用的序列，等待生产者生产，获取到最大的可以使用的序列号
                cachedAvailableSequence = sequenceBarrier.waitFor(nextSequence); 
            }
        }
        catch (final TimeoutException e)
        {
            notifyTimeout(sequence.get());
        }
        catch (final AlertException ex) // 处理通知
        {
            if (!running.get()) // 如果当前处理器被停止，那么退出主循环
            {
                break;
            }
        }
        catch (final Throwable ex)
        {   // 处理异常
            // handle, mark as processed, unless the exception handler threw an exception
            exceptionHandler.handleEventException(ex, nextSequence, event);
            processedSequence = true; // 如果异常处理器不抛出异常的话，就认为事件处理完毕，设置事件处理完成标识
        }
    }
    // 退出主循环后，如果workHandler实现了LifecycleAware，这里会对其进行一个关闭通知
    notifyShutdown();
    // 设置当前处理器状态为停止
    running.set(false);
}
```

说明一下WorkProcessor的主逻辑中几个重点：

1. 首先，由于是Work模式，必然是多个事件处理者（WorkProcessor）处理同一批事件，那么肯定会存在多个处理者对同一个要处理事件的竞争，所以出现了一个workSequence，所有的处理者都使用这一个workSequence，大家通过对workSequence的原子操作来保证不会处理相同的事件。
2. 其次，多个事件处理者和事件发布者之间也需要协调，需要等待事件发布者发布完事件之后才能对其进行处理，这里还是使用序列栅栏来协调(sequenceBarrier.waitFor)。每个消费者拿到序列号nextSequence后去和RingBuffer的cursor比较，即生产者生产到的最大序列号比较，如果自己要取的序号还没有被生产者生产出来，则等待生产者生成出来后再从RingBuffer中取数据，处理数据。

接下来再看一下Work模式下另一个重要的类——WorkerPool：

```java
public final class WorkerPool<T>
{
    private final AtomicBoolean started = new AtomicBoolean(false); // 运行状态标识
    private final Sequence workSequence = new Sequence(Sequencer.INITIAL_CURSOR_VALUE); // 工作序列
    private final RingBuffer<T> ringBuffer; // 事件队列
    // WorkProcessors are created to wrap each of the provided WorkHandlers
    private final WorkProcessor<?>[] workProcessors;  // 事件处理器数组

    @SafeVarargs
    public WorkerPool(
        final RingBuffer<T> ringBuffer,
        final SequenceBarrier sequenceBarrier,
        final ExceptionHandler<? super T> exceptionHandler,
        final WorkHandler<? super T>... workHandlers)
    {
        this.ringBuffer = ringBuffer;
        final int numWorkers = workHandlers.length;
        workProcessors = new WorkProcessor[numWorkers];

        for (int i = 0; i < numWorkers; i++)
        {
            workProcessors[i] = new WorkProcessor<>(
                ringBuffer,
                sequenceBarrier,
                workHandlers[i],
                exceptionHandler,
                workSequence);
        }
    }

    @SafeVarargs
    public WorkerPool(
        final EventFactory<T> eventFactory,
        final ExceptionHandler<? super T> exceptionHandler,
        final WorkHandler<? super T>... workHandlers)
    {
        ringBuffer = RingBuffer.createMultiProducer(eventFactory, 1024, new BlockingWaitStrategy());
        final SequenceBarrier barrier = ringBuffer.newBarrier();
        final int numWorkers = workHandlers.length;
        workProcessors = new WorkProcessor[numWorkers];

        for (int i = 0; i < numWorkers; i++)
        {
            workProcessors[i] = new WorkProcessor<>(
                ringBuffer,
                barrier,
                workHandlers[i],
                exceptionHandler,
                workSequence);
        }

        ringBuffer.addGatingSequences(getWorkerSequences());
    }
```

WorkerPool是Work模式下的事件处理器池，它起到了维护事件处理器生命周期、关联事件处理器与事件队列（RingBuffer）、提供工作序列（上面分析WorkProcessor时看到多个处理器需要使用统一的workSequence）的作用。

 看一下WorkerPool的方法：

```java
public Sequence[] getWorkerSequences()
{
    final Sequence[] sequences = new Sequence[workProcessors.length + 1];
    for (int i = 0, size = workProcessors.length; i < size; i++)
    {
        sequences[i] = workProcessors[i].getSequence();
    }
    sequences[sequences.length - 1] = workSequence;

    return sequences;
}
```

通过WorkerPool是可以获取内部事件处理器各自的序列和当前的WorkSequence，用于观察事件处理进度。

```java
public RingBuffer<T> start(final Executor executor)
{
    if (!started.compareAndSet(false, true))
    {
        throw new IllegalStateException("WorkerPool has already been started and cannot be restarted until halted.");
    }

    final long cursor = ringBuffer.getCursor();
    workSequence.set(cursor);

    for (WorkProcessor<?> processor : workProcessors)
    {
        processor.getSequence().set(cursor);
        executor.execute(processor);
    }

    return ringBuffer;
}
```

 start方法里面会初始化工作序列，然后使用一个给定的执行器（线程池）来执行内部的事件处理器。 

```java
public void drainAndHalt()
{
    Sequence[] workerSequences = getWorkerSequences();
    while (ringBuffer.getCursor() > Util.getMinimumSequence(workerSequences))
    {
        Thread.yield();
    }

    for (WorkProcessor<?> processor : workProcessors)
    {
        processor.halt();
    }

    started.set(false);
}
```

drainAndHalt方法会将RingBuffer中所有的事件取出，执行完毕后，然后停止当前WorkerPool。

```java
public void halt()
{
    for (WorkProcessor<?> processor : workProcessors)
    {
        processor.halt();
    }

    started.set(false);
}
```

马上停止当前WorkerPool。 

```java
public boolean isRunning()
{
    return started.get();
}
```

获取当前WorkerPool运行状态。

好了，有了WorkProcessor和WorkerPool，我们又可以嗨皮的写一下多线程消费的生产者/消费者模式了！

还记得WorkProcessor由内部的WorkHandler来具体处理事件吧，所以先写一个WorkHandler：

```java
public class MyDataWorkHandler implements WorkHandler<MyDataEvent>{  
      
    private String name;  
      
    public MyDataWorkHandler(String name) {  
        this.name = name;  
    }  
    @Override  
    public void onEvent(MyDataEvent event) throws Exception {  
        System.out.println("WorkHandler["+name+"]处理事件"+event.getData());  
    }  
}
```

然后是主程序：（其他的类源码见上一节）

```java
public static void main(String[] args) {  
    // 创建一个RingBuffer，注意容量是4。  
    RingBuffer<MyDataEvent> ringBuffer = RingBuffer.createSingleProducer(new MyDataEventFactory(), 4);  
    // 创建3个WorkHandler  
    MyDataWorkHandler handler1 = new MyDataWorkHandler("1");  
    MyDataWorkHandler handler2 = new MyDataWorkHandler("2");  
    MyDataWorkHandler handler3 = new MyDataWorkHandler("3");  
    WorkerPool<MyDataEvent> workerPool =  new WorkerPool<MyDataEvent>(ringBuffer, ringBuffer.newBarrier(),   
                    new IgnoreExceptionHandler(),   
                    handler1, handler2, handler3);  
    // 将WorkPool的工作序列集设置为ringBuffer的追踪序列。  
    ringBuffer.addGatingSequences(workerPool.getWorkerSequences());  
    // 创建一个线程池用于执行Workhandler。  
    Executor executor = Executors.newFixedThreadPool(4);  
    // 启动WorkPool。  
    workerPool.start(executor);  
    // 往RingBuffer上发布事件  
    for(int i=0;i<10;i++){  
        ringBuffer.publishEvent(new MyDataEventTranslatorWithIdAndValue(), i, i+"s");  
        System.out.println("发布事件["+i+"]");  
    }  
    try {  
        System.in.read();  
    } catch (IOException e) {  
        e.printStackTrace();  
    }  
} 
```

输出如下： 

```java
发布事件[0]  
WorkHandler[1]处理事件MyData [id=0, value=0s]  
发布事件[1]  
发布事件[2]  
WorkHandler[1]处理事件MyData [id=3, value=3s]  
发布事件[3]  
WorkHandler[2]处理事件MyData [id=2, value=2s]  
WorkHandler[3]处理事件MyData [id=1, value=1s]  
发布事件[4]  
WorkHandler[1]处理事件MyData [id=4, value=4s]  
发布事件[5]  
WorkHandler[2]处理事件MyData [id=5, value=5s]  
WorkHandler[3]处理事件MyData [id=6, value=6s]  
发布事件[6]  
发布事件[7]  
WorkHandler[1]处理事件MyData [id=7, value=7s]  
发布事件[8]  
发布事件[9]  
WorkHandler[2]处理事件MyData [id=8, value=8s]  
WorkHandler[3]处理事件MyData [id=9, value=9s]  
```

 正是我们想要的效果，多个处理器处理同一批事件！

### 等待策略 WaitStrategy

上面的分析中已经提到了事件发布者会使用序列栅栏来等待（waitFor）事件发布者发布事件，但具体是怎么等待呢？是阻塞还是自旋？接下来仔细看下这部分，disruptor框架对这部分提供了很多策略。

首先我们看下框架中提供的SequenceBarrier的实现——ProcessingSequenceBarrier类的waitFor细节：

```java
@Override
public long waitFor(final long sequence)
    throws AlertException, InterruptedException, TimeoutException
{
    checkAlert(); // 先检测报警状态
    // 然后根据等待策略来等待可用的序列值
    long availableSequence = waitStrategy.waitFor(sequence, cursorSequence, dependentSequence, this);

    if (availableSequence < sequence)
    {
        return availableSequence;  // 如果可用的序列值小于给定的序列，那么直接返回
    }
    // 否则，要返回能安全使用的最大的序列值
    return sequencer.getHighestPublishedSequence(sequence, availableSequence);
}
```

我们注意到waitFor方法中其实是调用了WaitStrategy的waitFor方法来实现等待，WaitStrategy接口是框架中定义的等待策略接口（其实在RingBuffer构造的可以传入一个等待策略，没显式传入的话，会使用默认的等待策略，可以查看下RingBuffer的构造方法），先看下这个接口： 

```java
public interface WaitStrategy{  
    /** 
     * 等待给定的sequence变为可用
     * 
     * @param sequence 等待(申请)的序列值
     * @param cursor ringBuffer中的主序列，也可以认为是事件发布者使用的序列
     * @param dependentSequence 事件处理者使用的序列
     * @param barrier 序列栅栏
     * @return 对事件处理者来说可用的序列值，可能会比申请的序列值大
     */  
    long waitFor(long sequence, Sequence cursor, Sequence dependentSequence, SequenceBarrier barrier)  
        throws AlertException, InterruptedException, TimeoutException;  
    /** 
     * 当发布事件成功后会调用这个方法来通知等待的事件处理者序列可用了。 
     */  
    void signalAllWhenBlocking();  
} 
```

disruptor框架中提供了如下几种等待策略：

- BlockingWaitStrategy：用了ReentrantLock的等待&&唤醒机制实现等待逻辑，是默认策略，比较节省CPU。
- BusySpinWaitStrategy：自旋，直到满足条件，**生产环境慎用**，JDK9之下慎用（最好别用）。
- DummyWaitStrategy：返回的Sequence值为0，正常环境是用不上的。
- LiteBlockingWaitStrategy：基于BlockingWaitStrategy，在没有锁竞争的时候会省去唤醒操作，但是作者说测试不充分，不建议使用。
- SleepingWaitStrategy：三段式，第一阶段自旋，第二阶段执行Thread.yield交出CPU，第三阶段睡眠执行时间，反复的的睡眠。
- TimeoutBlockingWaitStrategy：带超时时间的阻塞等待，与LiteTimeoutBlockingWaitStrategy的区别是TimeoutBlockingWaitStrategy等待时间必须严格低于设定的值。
- LiteTimeoutBlockingWaitStrategy：基于TimeoutBlockingWaitStrategy，在没有锁竞争的时候会省去唤醒操作。
- YieldingWaitStrategy：二段式，第一阶段自旋，第二阶段执行Thread.yield交出CPU。
- PhasedBackoffWaitStrategy：组合策略，可以指定上述策略，四段式，第一阶段自旋指定次数，第二阶段自旋指定时间，第三阶段执行Thread.yield交出CPU，第四阶段调用成员变量的waitFor方法，这个成员变量可以被设置为BlockingWaitStrategy、LiteBlockingWaitStrategy、SleepingWaitStrategy这三个中的一个。

首先看下BlockingWaitStrategy，也是默认的等待序列，如果您更倾向于节省CPU资源，对高吞吐量和低延时的要求相对低一些，那么BlockingWaitStrategy就适合您了：

```java
public final class BlockingWaitStrategy implements WaitStrategy
{
    private final Lock lock = new ReentrantLock();
    private final Condition processorNotifyCondition = lock.newCondition();

    @Override
    public long waitFor(long sequence, Sequence cursorSequence, Sequence dependentSequence, SequenceBarrier barrier)
        throws AlertException, InterruptedException
    {
        long availableSequence;
        if (cursorSequence.get() < sequence) // 如果RingBuffer上当前可用的序列值小于要申请的序列值
        {
            lock.lock();
            try
            {
                while (cursorSequence.get() < sequence) // 再次检测 double check
                {
                    barrier.checkAlert(); // 检查序列栅栏状态(事件处理器是否被关闭)
                    processorNotifyCondition.await(); // 当前线程在processorNotifyCondition条件上等待
                }
            }
            finally
            {
                lock.unlock();
            }
        }
        // 这里已经保证了availableSequence必然大于等于sequence，并且在存在依赖的场景中，
        // 被依赖消费者存在慢消费的话，会直接导致下游进入死循环况，（此时可能造成cpu升高）。
        while ((availableSequence = dependentSequence.get()) < sequence)
        {
            barrier.checkAlert();
            ThreadHints.onSpinWait();
        }

        return availableSequence;
    }

    @Override
    public void signalAllWhenBlocking()
    {
        lock.lock();
        try
        {
            processorNotifyCondition.signalAll();  // 唤醒在processorNotifyCondition条件上等待的处理事件线程
        }
        finally
        {
            lock.unlock();
        }
    }
  
}
```

可见BlockingWaitStrategy的实现方法是阻塞等待。当要求节省CPU资源，而不要求高吞吐量和低延迟的时候使用这个策略。

再看下BusySpinWaitStrategy： 

```java
public final class BusySpinWaitStrategy implements WaitStrategy
{
    @Override
    public long waitFor(
        final long sequence, Sequence cursor, final Sequence dependentSequence, final SequenceBarrier barrier)
        throws AlertException, InterruptedException
    {
        long availableSequence;

        while ((availableSequence = dependentSequence.get()) < sequence)
        {   // 自旋
            barrier.checkAlert();
          	// 关键就是ThreadHints.onSpinWait做了什么，如果ON_SPIN_WAIT_METHOD_HANDLE为空，意味着外面的while循环是个非常消耗CPU的自旋
            ThreadHints.onSpinWait();
        }

        return availableSequence;
    }

    @Override
    public void signalAllWhenBlocking()
    {
    }
}

// ThreadHints.java

static
    {
        final MethodHandles.Lookup lookup = MethodHandles.lookup();

        MethodHandle methodHandle = null;
        try
        {
          	// 就是Thread类的onSpinWait方法，如果Thread类没有onSpinWait方法，那么使用BusySpinWaitStrategy作为等待策略就有很高的代价了，环形队列里没有数据时消费线程会执行自旋，很耗费CPU
          	// 这方法是从JDK9才有的，所以对于JDK8使用者来说来说，选用BusySpinWaitStrategy就意味着要面对没做啥事儿的while循环了
            methodHandle = lookup.findStatic(Thread.class, "onSpinWait", methodType(void.class));
        }
        catch (final Exception ignore)
        {
        }

        ON_SPIN_WAIT_METHOD_HANDLE = methodHandle;
    }

public static void onSpinWait() {
    if (null != ON_SPIN_WAIT_METHOD_HANDLE)
    {
        try
        {
            ON_SPIN_WAIT_METHOD_HANDLE.invokeExact();
        }
        catch (final Throwable ignore)
        {
        }
    }
}
```

BusySpinWaitStrategy的实现方法是自旋等待。这种策略会利用CPU资源来避免系统调用带来的延迟抖动，当线程可以绑定到指定CPU（核）的时候可以使用这个策略。

再看下LiteBlockingWaitStrategy： 

```java
public final class LiteBlockingWaitStrategy implements WaitStrategy
{
    private final Lock lock = new ReentrantLock();
    private final Condition processorNotifyCondition = lock.newCondition();
    private final AtomicBoolean signalNeeded = new AtomicBoolean(false);

    @Override
    public long waitFor(long sequence, Sequence cursorSequence, Sequence dependentSequence, SequenceBarrier barrier)
        throws AlertException, InterruptedException
    {
        long availableSequence;
        if (cursorSequence.get() < sequence)
        {
            lock.lock();

            try
            {
                do
                {
                    signalNeeded.getAndSet(true);

                    if (cursorSequence.get() >= sequence)
                    {
                        break;
                    }

                    barrier.checkAlert();
                    processorNotifyCondition.await();
                }
                while (cursorSequence.get() < sequence);
            }
            finally
            {
                lock.unlock();
            }
        }

        while ((availableSequence = dependentSequence.get()) < sequence)
        {
            barrier.checkAlert();
            ThreadHints.onSpinWait();
        }

        return availableSequence;
    }

    @Override
    public void signalAllWhenBlocking()
    {
        if (signalNeeded.getAndSet(false))
        {
            lock.lock();
            try
            {
                processorNotifyCondition.signalAll();
            }
            finally
            {
                lock.unlock();
            }
        }
    }

}
```

相比BlockingWaitStrategy，LiteBlockingWaitStrategy的实现方法也是阻塞等待，但它会减少一些不必要的唤醒。从源码的注释上看，这个策略在基准性能测试上是会表现出一些性能提升，但是作者还不能完全证明程序的正确性。用于有时间限制的场景，每次等待超时后都会调用业务定制的超时处理逻辑，这个逻辑写到EventHandler实现类中，这个实现类要实现Timeouthandler接口。

再看下SleepingWaitStrategy：

```java
public final class SleepingWaitStrategy implements WaitStrategy
{
    private static final int DEFAULT_RETRIES = 200;
    private static final long DEFAULT_SLEEP = 100;

    private final int retries;
    private final long sleepTimeNs;

    public SleepingWaitStrategy()
    {
        this(DEFAULT_RETRIES, DEFAULT_SLEEP);
    }

    public SleepingWaitStrategy(int retries)
    {
        this(retries, DEFAULT_SLEEP);
    }

    public SleepingWaitStrategy(int retries, long sleepTimeNs)
    {
        this.retries = retries;
        this.sleepTimeNs = sleepTimeNs;
    }

    @Override
    public long waitFor(
        final long sequence, Sequence cursor, final Sequence dependentSequence, final SequenceBarrier barrier)
        throws AlertException
    {
        long availableSequence;
        int counter = retries;

        while ((availableSequence = dependentSequence.get()) < sequence)
        {
            counter = applyWaitMethod(barrier, counter);
        }

        return availableSequence;
    }

    @Override
    public void signalAllWhenBlocking()
    {
    }

    private int applyWaitMethod(final SequenceBarrier barrier, int counter)
        throws AlertException
    {
        barrier.checkAlert();
        // 从指定的重试次数（默认是200）重试到剩下100次，这个过程是自旋。
        if (counter > 100)
        {
            --counter;
        }
        else if (counter > 0) // 然后尝试100次让出处理器动作
        {
            --counter;
            Thread.yield();
        }
        else
        {
            LockSupport.parkNanos(sleepTimeNs); // 然后尝试阻塞1纳秒
        }

        return counter;
    }
}
```

SleepingWaitStrategy的实现方法是先自旋，不行再临时让出调度（yield），不行再短暂的阻塞等待。对于既想取得高性能，由不想太浪费CPU资源的场景，这个策略是一种比较好的折中方案。使用这个方案可能会出现延迟波动。

再看下TimeoutBlockingWaitStrategy： 

```java
public class TimeoutBlockingWaitStrategy implements WaitStrategy
{
    private final Lock lock = new ReentrantLock();
    private final Condition processorNotifyCondition = lock.newCondition();
    private final long timeoutInNanos;

    public TimeoutBlockingWaitStrategy(final long timeout, final TimeUnit units)
    {
        timeoutInNanos = units.toNanos(timeout);
    }

    @Override
    public long waitFor(
        final long sequence,
        final Sequence cursorSequence,
        final Sequence dependentSequence,
        final SequenceBarrier barrier)
        throws AlertException, InterruptedException, TimeoutException
    {
        long nanos = timeoutInNanos;

        long availableSequence;
        if (cursorSequence.get() < sequence)
        {
            lock.lock();
            try
            {
                while (cursorSequence.get() < sequence)
                {
                    barrier.checkAlert();
                    nanos = processorNotifyCondition.awaitNanos(nanos);
                    if (nanos <= 0)
                    {
                        throw TimeoutException.INSTANCE;
                    }
                }
            }
            finally
            {
                lock.unlock();
            }
        }

        while ((availableSequence = dependentSequence.get()) < sequence)
        {
            barrier.checkAlert();
        }

        return availableSequence;
    }

    @Override
    public void signalAllWhenBlocking()
    {
        lock.lock();
        try
        {
            processorNotifyCondition.signalAll();
        }
        finally
        {
            lock.unlock();
        }
    }

}
```

TimeoutBlockingWaitStrategy的实现方法是阻塞给定的时间，超过时间的话会抛出超时异常。

LiteTimeoutBlockingWaitStrategy与TimeoutBlockingWaitStrategy的关系，就像BlockingWaitStrategy与LiteBlockingWaitStrategy的关系：作为TimeoutBlockingWaitStrategy的变体，有TimeoutBlockingWaitStrategy的超时处理特性，而且没有锁竞争的时候，省略掉唤醒操作。作者说LiteBlockingWaitStrategy可用于体验，但正确性并未经过充分验证，但是在LiteTimeoutBlockingWaitStrategy的注释中没有看到这种说法，看样子这是个靠谱的等待策略，可以用，用在有超时处理的需求，而且没有锁竞争的场景（例如独立消费）

再看下YieldingWaitStrategy：

```java
public final class YieldingWaitStrategy implements WaitStrategy
{
    private static final int SPIN_TRIES = 100;

    @Override
    public long waitFor(
        final long sequence, Sequence cursor, final Sequence dependentSequence, final SequenceBarrier barrier)
        throws AlertException, InterruptedException
    {
        long availableSequence;
        int counter = SPIN_TRIES;

        while ((availableSequence = dependentSequence.get()) < sequence)
        {
            counter = applyWaitMethod(barrier, counter);
        }

        return availableSequence;
    }

    @Override
    public void signalAllWhenBlocking()
    {
    }

    private int applyWaitMethod(final SequenceBarrier barrier, int counter)
        throws AlertException
    {
        barrier.checkAlert();

        if (0 == counter)
        {
            Thread.yield();
        }
        else
        {
            --counter;
        }

        return counter;
    }
}
```

SleepingWaitStrategy的实现方法是先自旋（100次），不行再临时让出调度（yield）。和SleepingWaitStrategy一样也是一种高性能与CPU资源之间取舍的折中方案，但这个策略不会带来显著的延迟抖动。

```java
public final class SleepingWaitStrategy implements WaitStrategy
{
    private static final int DEFAULT_RETRIES = 200;
    private static final long DEFAULT_SLEEP = 100;

    private final int retries;
    private final long sleepTimeNs;

    public SleepingWaitStrategy()
    {
        this(DEFAULT_RETRIES, DEFAULT_SLEEP);
    }

    public SleepingWaitStrategy(int retries)
    {
        this(retries, DEFAULT_SLEEP);
    }

    public SleepingWaitStrategy(int retries, long sleepTimeNs)
    {
        this.retries = retries;
        this.sleepTimeNs = sleepTimeNs;
    }

    @Override
    public long waitFor(
        final long sequence, Sequence cursor, final Sequence dependentSequence, final SequenceBarrier barrier)
        throws AlertException
    {
        long availableSequence;
        int counter = retries;

        while ((availableSequence = dependentSequence.get()) < sequence)
        {
            counter = applyWaitMethod(barrier, counter);
        }

        return availableSequence;
    }

    @Override
    public void signalAllWhenBlocking()
    {
    }

    private int applyWaitMethod(final SequenceBarrier barrier, int counter)
        throws AlertException
    {
        barrier.checkAlert();
        // 从指定的重试次数（默认是200）重试到剩下100次，这个过程是自旋，相当于最快速的响应，即最高性能
        if (counter > 100)
        {
            --counter;
        }
        else if (counter > 0) // 然后尝试100次让出处理器动作，即最省CPU，但是响应最慢
        {
            --counter;
            Thread.yield();
        }
        else
        {
            LockSupport.parkNanos(sleepTimeNs); // 其他时候尝试阻塞1纳秒
        }

        return counter;
    }
}
```

最后看下PhasedBackoffWaitStrategy，该策略的特点是将整个等待过程分成下图的四段，四个方块代表一个时间线上的四个阶段：

<img src="http://blog-1259650185.cosbj.myqcloud.com/img/202202/13/1644749267.png" alt="11" style="zoom:50%;" />

这里说明一下上图的四个阶段：

1. 首先是自旋指定的次数，默认10000次；
2. 自旋过后，开始带计时的自旋，执行的时长是spinTimeoutNanos的值；
3. 执行时长达到spinTimeoutNanos的值后，开始执行Thread.yield()交出CPU资源，这个逻辑的执行时长是yieldTimeoutNanos-spinTimeoutNanos；
4. 执行时长达到yieldTimeoutNanos-spinTimeoutNanos的值后，开始调用fallbackStrategy.waitFor，这个调用没有时间或者次数限制；

现在问题来了fallbackStrategy是何方神圣？PhasedBackoffWaitStrategy类准备了三个静态方法，咱们可以按需选用，让fallbackStrategy是BlockingWaitStrategy、LiteBlockingWaitStrategy、SleepingWaitStrategy这三个中的一个：

```java
public final class PhasedBackoffWaitStrategy implements WaitStrategy
{
    private static final int SPIN_TRIES = 10000;
    private final long spinTimeoutNanos;
    private final long yieldTimeoutNanos;
    private final WaitStrategy fallbackStrategy;

    public PhasedBackoffWaitStrategy(
        long spinTimeout,
        long yieldTimeout,
        TimeUnit units,
        WaitStrategy fallbackStrategy)
    {
        this.spinTimeoutNanos = units.toNanos(spinTimeout);
        this.yieldTimeoutNanos = spinTimeoutNanos + units.toNanos(yieldTimeout);
        this.fallbackStrategy = fallbackStrategy;
    }

    public static PhasedBackoffWaitStrategy withLock(
        long spinTimeout,
        long yieldTimeout,
        TimeUnit units)
    {
        return new PhasedBackoffWaitStrategy(
            spinTimeout, yieldTimeout,
            units, new BlockingWaitStrategy());
    }

    public static PhasedBackoffWaitStrategy withLiteLock(
        long spinTimeout,
        long yieldTimeout,
        TimeUnit units)
    {
        return new PhasedBackoffWaitStrategy(
            spinTimeout, yieldTimeout,
            units, new LiteBlockingWaitStrategy());
    }

    public static PhasedBackoffWaitStrategy withSleep(
        long spinTimeout,
        long yieldTimeout,
        TimeUnit units)
    {
        return new PhasedBackoffWaitStrategy(
            spinTimeout, yieldTimeout,
            units, new SleepingWaitStrategy(0));
    }

    @Override
    public long waitFor(long sequence, Sequence cursor, Sequence dependentSequence, SequenceBarrier barrier)
        throws AlertException, InterruptedException, TimeoutException
    {
        long availableSequence;
        long startTime = 0;
        int counter = SPIN_TRIES;

        do
        {
            if ((availableSequence = dependentSequence.get()) >= sequence)
            {
                return availableSequence;
            }

            if (0 == --counter)
            {
                if (0 == startTime)
                {
                    startTime = System.nanoTime();
                }
                else
                {
                    long timeDelta = System.nanoTime() - startTime;
                    if (timeDelta > yieldTimeoutNanos)
                    {
                        return fallbackStrategy.waitFor(sequence, cursor, dependentSequence, barrier);
                    }
                    else if (timeDelta > spinTimeoutNanos)
                    {
                        Thread.yield();
                    }
                }
                counter = SPIN_TRIES;
            }
        }
        while (true);
    }

    @Override
    public void signalAllWhenBlocking()
    {
        fallbackStrategy.signalAllWhenBlocking();
    }
}
```

PhasedBackoffWaitStrategy的实现方法是先自旋（10000次），不行再临时让出调度（yield），不行再使用其他的策略进行等待。可以根据具体场景自行设置自旋时间、yield时间和备用等待策略。

小结：

1. 事件处理者可以通过Event模式或者Work模式来处理事件。
2. 事件处理者可以使用多种等待策略来等待事件发布者发布事件，可按照具体场景选择合适的等待策略。  

## 框架支持

前面几节看了disruptor中的一些重要组件和组件的运行方式，也通过手动组合这些组件的方式给出了一些基本的用例。框架也提供了一个 DSL-style API，来帮助我们更容易的使用框架，屏蔽掉一些细节（比如怎么构建RingBuffer、怎么关联追踪序列等），相当于Builder模式。

disruptor的常用类体系如下图所示：

![2](http://blog-1259650185.cosbj.myqcloud.com/img/202202/10/1644477763.png)

在看disruptor之前，先看一些辅助类，首先看下ConsumerRepository：

```java
class ConsumerRepository<T> implements Iterable<ConsumerInfo>
{
    private final Map<EventHandler<?>, EventProcessorInfo<T>> eventProcessorInfoByEventHandler =
        new IdentityHashMap<>();
    private final Map<Sequence, ConsumerInfo> eventProcessorInfoBySequence =
        new IdentityHashMap<>();
    private final Collection<ConsumerInfo> consumerInfos = new ArrayList<>();
```

可见ConsumerRepository内部存储着事件处理者（消费者）的信息，相当于事件处理者的仓库。

看一下里面的方法：

```java
public void add( final EventProcessor eventprocessor, final EventHandler<? super T> handler,
    final SequenceBarrier barrier) {
    final EventProcessorInfo<T> consumerInfo = new EventProcessorInfo<>(eventprocessor, handler, barrier);
    eventProcessorInfoByEventHandler.put(handler, consumerInfo);
    eventProcessorInfoBySequence.put(eventprocessor.getSequence(), consumerInfo);
    consumerInfos.add(consumerInfo);
}
```

添加事件处理者（Event模式）、事件处理器和序列栅栏到仓库中。 

```java
public void add(final EventProcessor processor) {
    final EventProcessorInfo<T> consumerInfo = new EventProcessorInfo<>(processor, null, null);
    eventProcessorInfoBySequence.put(processor.getSequence(), consumerInfo);
    consumerInfos.add(consumerInfo);
}
```

添加事件处理者（Event模式）到仓库中。 

```java
public void add(final WorkerPool<T> workerPool, final SequenceBarrier sequenceBarrier) {
    final WorkerPoolInfo<T> workerPoolInfo = new WorkerPoolInfo<>(workerPool, sequenceBarrier);
    consumerInfos.add(workerPoolInfo);
    for (Sequence sequence : workerPool.getWorkerSequences())
    {
        eventProcessorInfoBySequence.put(sequence, workerPoolInfo);
    }
}
```

添加事件处理者（Work模式）和序列栅栏到仓库中。 

```java
public Sequence[] getLastSequenceInChain(boolean includeStopped) {
    List<Sequence> lastSequence = new ArrayList<>();
    for (ConsumerInfo consumerInfo : consumerInfos)
    {
        if ((includeStopped || consumerInfo.isRunning()) && consumerInfo.isEndOfChain())
        {
            final Sequence[] sequences = consumerInfo.getSequences();
            Collections.addAll(lastSequence, sequences);
        }
    }

    return lastSequence.toArray(new Sequence[lastSequence.size()]);
}
```

获取当前已经消费到RingBuffer上事件队列末尾的事件处理者的序列，可通过参数指定是否要包含已经停止的事件处理者。 

```java
public void unMarkEventProcessorsAsEndOfChain(final Sequence... barrierEventProcessors){  
    for (Sequence barrierEventProcessor : barrierEventProcessors){  
        getEventProcessorInfo(barrierEventProcessor).markAsUsedInBarrier();  
    }  
}
```

重置已经处理到事件队列末尾的事件处理者的状态。

其他方法就不看了。

上面代码中出现的ConsumerInfo就相当于事件处理者信息和序列栅栏的包装类，ConsumerInfo本身是一个接口，针对Event模式和Work模式提供了两种实现：EventProcessorInfo和WorkerPoolInfo，代码都很容易理解，这里就不贴了。

现在来看下Disruptor类，先看结构： 

```java
public class Disruptor<T> {
    private final RingBuffer<T> ringBuffer; // 事件队列
    private final Executor executor; //用于执行事件处理的执行器
    private final ConsumerRepository<T> consumerRepository = new ConsumerRepository<>(); // 事件处理信息仓库
    private final AtomicBoolean started = new AtomicBoolean(false); // 运行状态
    private ExceptionHandler<? super T> exceptionHandler = new ExceptionHandlerWrapper<>(); // 异常处理器
```

可见，Disruptor内部包含了我们之前写用例使用到的所有组件。

再看下构造方法： 

```java
public Disruptor(final EventFactory<T> eventFactory, final int ringBufferSize, final ThreadFactory threadFactory) {
    this(RingBuffer.createMultiProducer(eventFactory, ringBufferSize), new BasicExecutor(threadFactory));
}

public Disruptor(
        final EventFactory<T> eventFactory,
        final int ringBufferSize,
        final ThreadFactory threadFactory,
        final ProducerType producerType,
        final WaitStrategy waitStrategy) {
    this(RingBuffer.create(producerType, eventFactory, ringBufferSize, waitStrategy),
        new BasicExecutor(threadFactory));
}

private Disruptor(final RingBuffer<T> ringBuffer, final Executor executor) {
    this.ringBuffer = ringBuffer;
    this.executor = executor;
}
```

可见，通过构造方法，可以对内部的RingBuffer和执行器进行初始化。

有了事件队列（RingBuffer），接下来看看怎么构建事件处理者： 

```java
@SafeVarargs
public final EventHandlerGroup<T> handleEventsWith(final EventHandler<? super T>... handlers) {
    return createEventProcessors(new Sequence[0], handlers); // 注意，第一个参数恒为一个空数组
}
// barrierSequences，是给存在依赖关系的消费者用的
EventHandlerGroup<T> createEventProcessors(final Sequence[] barrierSequences,
    final EventHandler<? super T>[] eventHandlers) {
    checkNotStarted();
		// 用来保存每个消费者的消费进度
    final Sequence[] processorSequences = new Sequence[eventHandlers.length];
  	// SequenceBarrier主要是用来设置消费依赖的
    final SequenceBarrier barrier = ringBuffer.newBarrier(barrierSequences);

    for (int i = 0, eventHandlersLength = eventHandlers.length; i < eventHandlersLength; i++)
    {
        final EventHandler<? super T> eventHandler = eventHandlers[i];
				// 可以看到每个eventHandler会被封装成BatchEventProcessor，看名字就知道是批量处理的了吧
        final BatchEventProcessor<T> batchEventProcessor =
            new BatchEventProcessor<>(ringBuffer, barrier, eventHandler);
			  // 设置异常处理器
        if (exceptionHandler != null)
        {
            batchEventProcessor.setExceptionHandler(exceptionHandler);
        }
				// 注册到consumerRepository
        consumerRepository.add(batchEventProcessor, eventHandler, barrier);
        // 每一个BatchEventProcessor事件处理者的消费进度
        processorSequences[i] = batchEventProcessor.getSequence();
    }

    updateGatingSequencesForNextInChain(barrierSequences, processorSequences);

    return new EventHandlerGroup<>(this, consumerRepository, processorSequences);
}

// barrierSequences：原先依赖的消费进度，processorSequences：新进来的消费者的进度
private void updateGatingSequencesForNextInChain(final Sequence[] barrierSequences, final Sequence[] processorSequences) {
    if (processorSequences.length > 0) {
      	// 1. 把新进消费者的消费进度加入到【所有消费者的消费进度数组】中
        ringBuffer.addGatingSequences(processorSequences); 
      	
        /*
         * 2. 如果说这个新进消费者是依赖了其他的消费者的，那么把其他的消费者从【所有消费者的消费进度数组】中移除。
         * 这里为什么要移除呢？因为【所有消费者的消费进度数组】主要是用来获取最慢的进度的。
         * 那么被依赖的可以不用考虑，因为它不可能比依赖它的慢。并且让这个数组足够小，可以提升计算最慢进度的性能。
         */
        for (final Sequence barrierSequence : barrierSequences) {
            ringBuffer.removeGatingSequence(barrierSequence);
        }
        // 3. 把被依赖的消费者的endOfChain属性设置成false。这个endOfChain是用来干嘛的呢？其实主要是Disruptor在shutdown的时候需要判定是否所有消费者都已经消费完了（如果依赖了别人的消费者都消费完了，那么整条链路上一定都消费完了）。
        consumerRepository.unMarkEventProcessorsAsEndOfChain(barrierSequences);
    }
}
```

可见，handleEventsWith方法内部会创建BatchEventProcessor，然后将事件处理者的序列设置为RingBuffer的追踪序列。

当然，对于Event模式，还有一些玩法，其实之前几节就看到过，我们可以设置两个EventHandler，然后事件会依次被这两个handler处理。Disruptor类中提供了更明确的定义（事实是结合了EventHandlerGroup的一些方法），比如我想让事件先被处理器a处理，然后在被处理器b处理，就可以这么写： 

```java
EventHandler<MyEvent> a = new EventHandler<MyEvent>() { ... };  
EventHandler<MyEvent> b = new EventHandler<MyEvent>() { ... };  
disruptor.handleEventsWith(a); //语句1  
disruptor.after(a).handleEventsWith(b); 
```

注意上面必须先写语句1，然后才能针对a调用after，否则after找不到处理器a，会报错。

上面的例子也可以这么写： 

```java
EventHandler<MyEvent> a = new EventHandler<MyEvent>() { ... };  
EventHandler<MyEvent> b = new EventHandler<MyEvent>() { ... };  
disruptor.handleEventsWith(a).then(b);  
```

效果是一样的。

Disruptor还允许我们定制事件处理者： 

```java
@SafeVarargs
public final EventHandlerGroup<T> handleEventsWith(final EventProcessorFactory<T>... eventProcessorFactories) {
    final Sequence[] barrierSequences = new Sequence[0];
    return createEventProcessors(barrierSequences, eventProcessorFactories);
}

public interface EventProcessorFactory<T> {
    EventProcessor createEventProcessor(RingBuffer<T> ringBuffer, Sequence[] barrierSequences);
}
```

handleEventsWith方法内部创建的Event模式的事件处理者，有没有Work模式的呢？

```java
@SafeVarargs
@SuppressWarnings("varargs")
public final EventHandlerGroup<T> handleEventsWithWorkerPool(final WorkHandler<T>... workHandlers) {
    return createWorkerPool(new Sequence[0], workHandlers);
}

EventHandlerGroup<T> createWorkerPool(
    final Sequence[] barrierSequences, final WorkHandler<? super T>[] workHandlers) {
  	// 创建SequenceBarrier，每次消费者要读取RingBuffer中的下一个值都要通过SequenceBarrier来获取SequenceBarrier用来协调多个消费者并发的问题
    final SequenceBarrier sequenceBarrier = ringBuffer.newBarrier(barrierSequences);
    final WorkerPool<T> workerPool = new WorkerPool<>(ringBuffer, sequenceBarrier, exceptionHandler, workHandlers);


    consumerRepository.add(workerPool, sequenceBarrier);

    final Sequence[] workerSequences = workerPool.getWorkerSequences();

    updateGatingSequencesForNextInChain(barrierSequences, workerSequences);

    return new EventHandlerGroup<>(this, consumerRepository, workerSequences);
}
```

handleEventsWithWorkerPool内部会创建WorkerPool。

事件处理者也构建好了，接下来看看怎么启动它们： 

```java
public RingBuffer<T> start() {
    checkOnlyStartedOnce();
    for (final ConsumerInfo consumerInfo : consumerRepository)
    {
        consumerInfo.start(executor);
    }

    return ringBuffer;
}
```

可见，启动过程中会启动事件处理者，并利用执行器来执行事件处理线程。

事件处理者构建好了，也启动了，看看怎么发布事件：

```java
public void publishEvent(final EventTranslator<T> eventTranslator) {
    ringBuffer.publishEvent(eventTranslator);
}
```

很简单，里面就是直接调用了RingBuffer来发布事件，之前几节都分析过了。

再看看其他的方法：

```java
public void halt() {
    for (final ConsumerInfo consumerInfo : consumerRepository)
    {
        consumerInfo.halt();
    }
}
```

停止事件处理者。 

```java
public void shutdown() {
    try {
        shutdown(-1, TimeUnit.MILLISECONDS);
    } catch (final TimeoutException e) {
        exceptionHandler.handleOnShutdownException(e);
    }
}

public void shutdown(final long timeout, final TimeUnit timeUnit) throws TimeoutException {
    final long timeOutAt = System.currentTimeMillis() + timeUnit.toMillis(timeout);
    while (hasBacklog()) {
        if (timeout >= 0 && System.currentTimeMillis() > timeOutAt) {
            throw TimeoutException.INSTANCE;
        }
        // Busy spin
    }
    halt();
}

private boolean hasBacklog() {
    final long cursor = ringBuffer.getCursor();
    for (final Sequence consumer : consumerRepository.getLastSequenceInChain(false)) {
      	// 通过判断生产数是否大于消费数，等于表示是否还有没有被消费的事件
        if (cursor > consumer.get()) {
            return true;
        }
    }
    return false;
}
```

等待所有能处理的事件都处理完了，再定制事件处理者，有超时选项。

好了，其他方法都比较简单，不看了。最后来使用Disruptor写一个生产者消费者模式吧： 

```java
public static void main(String[] args) {  
    // 创建一个执行器(线程池)。  
    Executor executor = Executors.newFixedThreadPool(4);  
    // 创建一个Disruptor。  
    Disruptor<MyDataEvent> disruptor =  new Disruptor<MyDataEvent>(new MyDataEventFactory(), 4, executor);  
    // 创建两个事件处理器。  
    MyDataEventHandler handler1 = new MyDataEventHandler();  
    KickAssEventHandler handler2 = new KickAssEventHandler();  
    // 同一个事件，先用handler1处理再用handler2处理。  
    disruptor.handleEventsWith(handler1).then(handler2);  
    // 启动Disruptor。  
    disruptor.start();  
    // 发布10个事件。  
    for(int i=0;i<10;i++){  
        disruptor.publishEvent(new MyDataEventTranslator());  
        System.out.println("发布事件["+i+"]");  
        try {  
            TimeUnit.SECONDS.sleep(3);  
        } catch (InterruptedException e) {  
            e.printStackTrace();  
        }  
    }  
    try {  
        System.in.read();  
    } catch (IOException e) {  
        e.printStackTrace();  
    }  
}  
```

看下输出： 

```java
发布事件[0]  
handle event's data:MyData [id=0, value=holy shit!]isEndOfBatch:true  
kick your ass 0 times!!!!  
发布事件[1]  
handle event's data:MyData [id=1, value=holy shit!]isEndOfBatch:true  
kick your ass 1 times!!!!  
发布事件[2]  
handle event's data:MyData [id=2, value=holy shit!]isEndOfBatch:true  
kick your ass 2 times!!!!  
发布事件[3]  
handle event's data:MyData [id=3, value=holy shit!]isEndOfBatch:true  
kick your ass 3 times!!!!  
发布事件[4]  
handle event's data:MyData [id=4, value=holy shit!]isEndOfBatch:true  
kick your ass 4 times!!!!  
发布事件[5]  
handle event's data:MyData [id=5, value=holy shit!]isEndOfBatch:true  
kick your ass 5 times!!!!  
发布事件[6]  
handle event's data:MyData [id=6, value=holy shit!]isEndOfBatch:true  
kick your ass 6 times!!!!  
发布事件[7]  
handle event's data:MyData [id=7, value=holy shit!]isEndOfBatch:true  
kick your ass 7 times!!!!  
发布事件[8]  
handle event's data:MyData [id=8, value=holy shit!]isEndOfBatch:true  
kick your ass 8 times!!!!  
发布事件[9]  
handle event's data:MyData [id=9, value=holy shit!]isEndOfBatch:true  
kick your ass 9 times!!!!  
```

最后总结：

1. 使用时可以直接使用Disruptor这个类来更方便的完成代码编写，注意灵活使用。
2. 最后别忘了单线程/多线程生产者、Event/Work处理模式等等。

## 参考

[disruptor-3.3.2源码解析汇总](https://www.iteye.com/blog/brokendreams-2255720)

[Disruptor之概览](https://juejin.cn/post/6844903556303028237)

[Disruptor核心源码分析](https://www.jianshu.com/p/b5aa623654ff?hmsr=toutiao.io&utm_medium=toutiao.io&utm_source=toutiao.io)

[disruptor笔记之四：事件消费知识点小结](https://xinchen.blog.csdn.net/article/details/117395009)

[disruptor笔记之七：等待策略](https://xinchen.blog.csdn.net/article/details/117608051)

[一起聊聊Disruptor](https://zhuanlan.zhihu.com/p/21355046)
