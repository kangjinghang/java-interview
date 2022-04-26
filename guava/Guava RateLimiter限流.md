缓存，降级和限流是大型分布式系统中的三把利剑。目前限流主要有漏桶和令牌桶两种算法。

1. 缓存：缓存的目的是减少外部调用，提高系统响速度。俗话说："缓存是网站优化第一定律"。缓存又分为本机缓存和分布式缓存，本机缓存是针对当前JVM实例的缓存，可以直接使用JDK Collection框架里面的集合类或者诸如Google Guava Cache来做本地缓存；分布式缓存目前主要有Memcached,Redis等。
2. 降级：所谓降级是指在系统调用高峰时，优先保证我们的核心服务，对于非核心服务可以选择将其关闭以保证核心服务的可用。例如在淘宝双11时，支付功能是核心，其他诸如用户中心等非核心功能可以选择降级，优先保证交易。
3. 限流：任何系统的性能都有一个上限，当并发量超过这个上限之后，可能会对系统造成毁灭性地打击。因此在任何时刻我们都必须保证系统的并发请求数量不能超过某个阈值，限流就是为了完成这一目的。

------

## 1. 常用限流算法

### 1.1 限流之漏桶算法

![漏桶算法](http://blog-1259650185.cosbj.myqcloud.com/img/202204/18/1650247156.png)

我们想象有一个固定容量的桶，桶底有个洞。请求就是从上往下倒进来的水，可能水流湍急，也可能是涓涓细流。因为桶的容量是固定的，所以灌进来太多的水，溢出去了我们就用不了了。所以无论怎样，桶底漏出来的水，都是匀速流出的。而我们要做的，就是处理这些匀速流出的水就好了。

**漏桶算法可以将系统处理请求限定到恒定的速率，当请求过载时，漏桶将直接溢出。漏桶算法假定了系统处理请求的速率是恒定的，但是在现实环境中，往往我们的系统处理请求的速率不是恒定的。漏桶算法无法解决系统突发流量的情况。**

------

### 1.2 限流之令牌桶算法

令牌桶算法相对漏桶算法的优势在于可以处理系统的突发流量，其算法示意图如下所示：

![令牌桶算法](http://blog-1259650185.cosbj.myqcloud.com/img/202204/18/1650247357.png)



相比于漏桶而言，令牌桶的处理方式完全相反。我们想象依旧有一个固定容量的桶，不过这次是以稳定的速率生成令牌放在桶中。当有请求时，需要获取令牌才能通过。因为桶的容量固定，令牌满了就不生产了。桶中有充足的令牌时，突发的流量可以直接获取令牌通过。当令牌取光后，桶空了，后面的请求就得等生成令牌后才能通过，这种情况下请求通过的速率就变得稳定了。

**令牌桶有一定的容量（capacity），后台服务向令牌桶中以恒定的速率放入令牌（token），当令牌桶中的令牌数量超过 capacity 之后，多余的令牌直接丢弃。当一个请求进来时，需要从桶中拿到 N 个令牌，如果能够拿到则继续后面的处理流程，如果拿不到，则当前线程可以选择阻塞等待桶中的令牌数量够本次请求的数量或者不等待直接返回失败。**

### 1.3 计数器法

设置一个时间窗口内允许的最大请求量，如果当前窗口请求数超过这个设定数量，则拒绝该窗口内之后的请求。

关键词：时间窗口，计数器。

举个例子，我们设置1秒钟的最大请求数量为100，使用一个计数器来记录这一秒中的请求数。每一秒开始时，计数器都从0开始记录请求量，如果在这一秒内计数器达到了100，则在这一秒未结束时，之后的请求全部拒绝。

计数器法是一个简单粗暴的方法。也就是因为简单粗暴，会有一定的问题。比如0.9秒时有100个请求，1.1秒时也有100个请求。按照计数器法的计算，第一秒和第二秒确实都在各自的时间范围内限制了100个请求，但是从0.5秒1.5秒这一秒之间有200个请求，这是计数器法的临界问题。如果请求量集中在两个时间窗口的临界点，会产生请求的尖峰。

<img src="http://blog-1259650185.cosbj.myqcloud.com/img/202204/18/1650266563.jpg" alt="img" style="zoom:50%;" />

我们可以引用滑动窗口的方式更加精细的划分时间窗口解决这个问题。将1秒钟细分为10个格子，每个格子用单独的计数器计算当前100毫秒的请求。随着时间的流逝，我们的窗口也跟着时间滑动，每次都是计算最近10个格子的请求量。如果最近10个格子的请求总量超过了100，则下一个格子里就拒绝全部的请求。格子数量越多，我们对流量控制的也就越精细，这部分逻辑可以借助LinkedList来实现。

而滑动窗口的缺点是，需要一直占用内存空间保存最近一个时间窗口内每个格子的请求。

### 1.4 信号量

操作系统的信号量是个很重要的概念，Java 并发库 的Semaphore 可以很轻松完成信号量控制，Semaphore可以控制某个资源可被同时访问的个数，通过 acquire() 获取一个许可，如果没有就等待，而 release() 释放一个许可。

信号量的本质是控制某个资源可被同时访问的个数，在一定程度上可以控制某资源的访问频率，但不能精确控制。

```java
@Test
fun semaphoreTest() {
    val semaphore = Semaphore(2)

    (1..10).map {
        thread(true) {
            semaphore.acquire()

            println("$it\t${Date()}")
            Thread.sleep(1000)

            semaphore.release()
        }
    }.forEach { it.join() }
}
```

以上示例，创建信号量，指定并发数为2，其输出如下

```basic
1   Wed Jan 17 10:31:49 CST 2018
2   Wed Jan 17 10:31:49 CST 2018
3   Wed Jan 17 10:31:50 CST 2018
4   Wed Jan 17 10:31:50 CST 2018
5   Wed Jan 17 10:31:51 CST 2018
6   Wed Jan 17 10:31:51 CST 2018
7   Wed Jan 17 10:31:52 CST 2018
8   Wed Jan 17 10:31:52 CST 2018
9   Wed Jan 17 10:31:53 CST 2018
10  Wed Jan 17 10:31:53 CST 2018
```

可以很清楚的看到，同一时刻最多只能有2个线程进行输出。
虽然信号量可以在一定程度上控制资源的访问频率，却不能精确控制。

------

## 2. Guava RateLimiter限流

Guava RateLimiter 是一个谷歌提供的限流工具，RateLimiter 基于令牌桶算法，可以有效限定单个 JVM 实例上某个接口的流量。

1. 令牌桶**有最大令牌数限制**，再多就装不下了。
2. 令牌的生成也是匀速的，每个小时生成60个令牌，如果时刻都有人来取令牌，那这些人会保持均匀的速率领取。（SmoothBursty模式和SmoothWarmingUp模式稳定期）
3. 如果之前累积了大量的令牌，一旦有大量的请求来获取令牌，这些请求都会被通过。
4. RateLimiter是**预获取令牌模式**，即：如果一次性被消耗掉大于已有数量的令牌，RateLimiter 的策略是**先满足你，不够的令牌数我先欠着，等后续生成了足够的令牌后，再给下一个请求发放令牌**。
5. 令牌桶通过**记录下一次请求可发放令牌的时间点**来确定是否接受下一个请求，以及下一个请求需要等待的时间。

### 2.1 RateLimiter使用的一个例子

```java
import com.google.common.util.concurrent.RateLimiter;

import java.util.concurrent.CountDownLatch;
import java.util.concurrent.ExecutorService;
import java.util.concurrent.Executors;

public class RateLimiterTest {

    public static void main(String[] args) throws InterruptedException {
        // qps设置为5，代表一秒钟只允许处理五个并发请求
        RateLimiter rateLimiter = RateLimiter.create(5);
        ExecutorService executorService = Executors.newFixedThreadPool(5);
        int nTasks = 10;
        CountDownLatch countDownLatch = new CountDownLatch(nTasks);
        long start = System.currentTimeMillis();
        for (int i = 0; i < nTasks; i++) {
            final int j = i;
            executorService.submit(() -> {
                rateLimiter.acquire(1);
                System.out.println(Thread.currentThread().getName() + " gets job " + j + " doing");
                try {
                    Thread.sleep(1000);
                } catch (InterruptedException e) {
                }
                System.out.println(Thread.currentThread().getName() + " gets job " + j + " done");
                countDownLatch.countDown();
            });
        }
        executorService.shutdown();
        countDownLatch.await();
        long end = System.currentTimeMillis();
        System.out.println("10 jobs gets done by 5 threads concurrently in " + (end - start) + " milliseconds");
    }

}
```

**输出结果**:

```java
pool-1-thread-1 gets job 0 doing
pool-1-thread-5 gets job 4 doing
pool-1-thread-4 gets job 3 doing
pool-1-thread-3 gets job 2 doing
pool-1-thread-2 gets job 1 doing
pool-1-thread-1 gets job 0 done
pool-1-thread-1 gets job 5 doing
pool-1-thread-5 gets job 4 done
pool-1-thread-5 gets job 6 doing
pool-1-thread-4 gets job 3 done
pool-1-thread-4 gets job 7 doing
pool-1-thread-3 gets job 2 done
pool-1-thread-3 gets job 8 doing
pool-1-thread-2 gets job 1 done
pool-1-thread-2 gets job 9 doing
pool-1-thread-1 gets job 5 done
pool-1-thread-5 gets job 6 done
pool-1-thread-4 gets job 7 done
pool-1-thread-3 gets job 8 done
pool-1-thread-2 gets job 9 done
10 jobs gets done by 5 threads concurrently in 2805 milliseconds
```

上面例子中我们提交10个工作任务，每个任务大概耗时5000微秒，开启10个线程，并且使用RateLimiter设置了qps为5，一秒内只允许五个并发请求被处理，虽然有10个线程，但是我们设置了qps为5，一秒之内只能有五个并发请求。我们预期的总耗时大概是2000微秒左右，结果为2805和预期的差不多。

再来一个例子。

```java
@Test
fun rateLimiterTest() {
    val rateLimiter = RateLimiter.create(0.5)

    arrayOf(1,6,2).forEach {
        println("${System.currentTimeMillis()} acq $it:\twait ${rateLimiter.acquire(it)}s")
    }
}
```

以上示例，创建一个RateLimiter，指定每秒放0.5个令牌（2秒放1个令牌），其输出见下

```basic
1516166482561 acq 1: wait 0.0s
1516166482563 acq 6: wait 1.997664s
1516166484569 acq 2: wait 11.991958s
```

从输出结果可以看出，RateLimiter具有预消费的能力：
`acq 1`时并没有任何等待直接预消费了1个令牌
`acq 6`时，**由于之前预消费了1个令牌，故而等待了2秒，之后又预消费了6个令牌**
`acq 2`时同理，**由于之前预消费了6个令牌，故而等待了12秒**

从另一方面讲，RateLimiter通过限制【后面】请求的等待时间，来支持一定程度的突发请求（预消费）。
但是某些情况下并**`不需要`**这种突发请求处理能力，如某IM厂商提供消息推送接口，但推送接口有严格的频率限制(600次/30秒)，在调用该IM厂商推送接口时便不能**预消费**，否则，则可能出现推送频率超出限制而失败。该情况的处理会在其他博文中介绍。

------

## 3. RateLimiter

RateLimiter基于令牌桶算法，它的核心思想主要有：

1. 响应本次请求之后，动态计算下一次可以服务的时间，如果下一次请求在这个时间之前则需要进行等待。SmoothRateLimiter 类中的 nextFreeTicketMicros 属性表示下一次可以响应的时间。例如，如果我们设置QPS为1，本次请求处理完之后，那么下一次最早的能够响应请求的时间一秒钟之后。
2. RateLimiter 的子类 SmoothBursty 支持处理突发流量请求，例如，我们设置QPS为1，在十秒钟之内没有请求，那么令牌桶中会有10个（假设设置的最大令牌数大于10）空闲令牌，如果下一次请求是 `acquire(20)` ，则不需要等待20秒钟，因为令牌桶中已经有10个空闲的令牌。SmoothRateLimiter 类中的 storedPermits 就是用来表示当前令牌桶中的空闲令牌数。
3. RateLimiter 子类 SmoothWarmingUp 不同于 SmoothBursty ，它存在一个“热身”的概念。它将 storedPermits 分成两个区间值：[0, thresholdPermits) 和 [thresholdPermits, maxPermits]。当请求进来时，如果当前系统处于"cold"的状态，从 [thresholdPermits, maxPermits] 区间去拿令牌，所需要等待的时间会长于从区间 [0, thresholdPermits) 拿相同令牌所需要等待的时间。当请求增多，storedPermits 减少到 thresholdPermits 以下时，此时拿令牌所需要等待的时间趋于稳定。这也就是所谓“热身”的过程。这个过程后面会详细分析。

RateLimiter主要的类的类图如下所示：

![RateLimiter类图](http://blog-1259650185.cosbj.myqcloud.com/img/202204/18/1650248690.png)



RateLimiter 是一个抽象类，SmoothRateLimiter 继承自 RateLimiter，不过 SmoothRateLimiter 仍然是一个抽象类，SmoothBursty 和 SmoothWarmingUp 才是具体的实现类。

Guava有两种限流模式，一种为稳定模式(SmoothBursty：令牌生成速度恒定)，一种为渐进模式(SmoothWarmingUp：令牌生成速度缓慢提升直到维持在一个稳定值) 两种模式实现思路类似，主要区别在等待时间的计算上。

其中，稳定模式支持处理突发请求。比如令牌桶现有令牌数为5，这时连续进行10个请求，则前5个请求会全部直接通过，没有等待时间，之后5个请求则每隔200毫秒通过一次。
而渐进模式则只会让第一个请求直接通过，之后的请求都会有等待时间，等待时间不断缩短，直到稳定在每隔200毫秒通过一次。这样，就会有一个预热的过程。

先上一个简单的demo，直观的感受一下这两种模式的差别。

代码执行结果对比如下：

<img src="http://blog-1259650185.cosbj.myqcloud.com/img/202204/18/1650268680.jpg" alt="img" style="zoom:67%;" />

------

## 4. SmoothRateLimiter主要属性

SmoothRateLimiter 是抽象类，其定义了一些关键的参数，我们先来看一下这些参数：

```java
/**
* The currently stored permits.
*/
double storedPermits;

/**
* The maximum number of stored permits.
*/
double maxPermits;

/**
* The interval between two unit requests, at our stable rate. E.g., a stable rate of 5 permits
* per second has a stable interval of 200ms.
*/
double stableIntervalMicros;

/**
* The time when the next request (no matter its size) will be granted. After granting a request,
* this is pushed further in the future. Large requests push this further than small requests.
*/
private long nextFreeTicketMicros = 0L; // could be either in the past or future
```

storedPermits 表明当前令牌桶中有多少令牌。maxPermits 表示令牌桶最大令牌数目，storedPermits 的取值范围为：[0, maxPermits]。stableIntervalMicros 等于 `1/qps`，它代表系统在稳定期间，两次请求之间间隔的微秒数。例如：如果我们设置的 qps 为5，则 stableIntervalMicros 为200ms。nextFreeTicketMicros 表示系统处理完当前请求后，下一次请求被许可的最短微秒数，如果在这之前有请求进来，则必须等待。

**当我们设置了 qps 之后，需要计算某一段时间系统能够生成的令牌数目，那么怎么计算呢？一种方式是开启一个后台任务去做，但是这样代价未免有点大。RateLimiter 中采取的是惰性计算方式：在每次请求进来的时候先去计算上次请求和本次请求之间应该生成多少个令牌。**

> Q：为什么是nextFreeTicketMicros?
>
> A：最简单的维持QPS速率的方式就是记住最后一次请求的时间，然后确保再次有请求过来的时候，已经经过了 1/QPS 秒。比如QPS是5 次/秒，只需要确保两次请求时间经过了200ms即可，如果刚好在100ms到达，就会再等待100ms,也就是说，如果一次性需要15个令牌，需要的时间为为3s。但是对于一个长时间没有请求的系统，这样的的设计方式有一定的不合理之处。考虑一个场景：如果一个RateLimiter,每秒产生1个令牌,它一直没有使用过，突然来了一个需要100个令牌的请求，选择等待100s再执行这个请求，显得不太明智，更好的处理方式为立即执行它，然后把接下来的请求推迟100s。
>
> 因而RateLimiter本身并不记下最后一次请求的时间，而是记下下一次期望运行的时间（nextFreeTicketMicros）。
>
> 这种方式带来的一个好处是，可以去判断等待的超时时间是否大于下次运行的时间，以使得能够执行，如果等待的超时时间太短，就能立即返回。
>
> Q：为什么会有一个标记代表存储了多少令牌？
>
> A：同样的考虑长时间没有使用的场景。如果长时间没有请求，突然间来了，这个时候是否应该立马放行这些请求？长时间没有使用可能意味着两件事：
>
> 1. 很多资源是存在空闲的情况，比如说网络请求长时间没有，它的缓冲区很有可能是空的，此时是可以加速传输，提高它的利用率
> 2. 一些时候，瞬间的爆发会导致溢出，比如说服务上的缓存过期了，需要去查询库，这个花销是非常“昂贵”的，过多的请求会导致数据库撑不住
>
> RateLimiter 就使用 storedPermits 来给过去请求的不充分程度建模。它的存储规则如下： 假设 RateLimiter 每秒产生一个令牌,每过去一秒如果没有请求，RateLimter 也就没有消费，就使 storedPermits 增长1。假设10s之内都没有请求过来，storedPermits 就变成了10（假设 maxPermits>10），此时如果要获取3个令牌，会使用 storedPermits 来中的令牌来处理，然后它的值变为了7，片刻之后，如果调用了acquire(10),部分的会从 storedPermits 拿到7个权限，剩余的3个则需要重新产生。
>
> 总的来说 RateLimiter 提供了一个 storedPermits 变量，当资源利用充分的时候，它就是0，最大可以增长到 maxStoredPermits。请求所需的令牌来自于两个地方：stored permits (空闲时存储的令牌)和 fresh permits（现有的令牌）
>
> Q：怎么衡量从 storedPermits 中获取令牌这个过程？
>
> A：同样假设每秒 RateLimiter 只生产一个令牌，正常情况下，如果一次来了3个请求，整个过程会持续3秒钟。考虑到长时间没有请求的场景：
>
> 1. 资源空闲。这种时候系统是能承受住一定量的请求的，当然希望在承受范围之内能够更快的提供请求，也就是说，如果有存储令牌，相比新产生令牌，此时希望能够更快的获取令牌，也就是此时从存储令牌中获取令牌的时间消耗要比产生新令牌要少，从而更快相应请求
> 2. 瞬时流量过大。这时候就不希望过快的消耗存储的令牌，希望它能够相比产生新的令牌的时间消耗大些，从而能够使请求相对平缓。
>
> 分析可知，针对不同的场景，需要对获取 storedPermits 做不同的处理，Ratelimiter的实现方式就是 storedPermitsToWaitTime 函数，它建立了从 storedPermits 中获取令牌和时间花销的模型函数，而衡量时间的花销就是通过对模型函数进行积分计算，比如原来存储了10个令牌，现在需要拿3个令牌，还剩余7个，那么所需要的时间花销就是该函数从7-10区间中的积分。
>
> 这种方式保证了任何获取令牌方式所需要的时间都是一样的，好比 每次拿一个和先拿两个再拿一个，从时间上来讲并没有分别。

------

## 5. SmoothBursty

### 5.1 创建

RateLimiter 中提供了创建 SmoothBursty 的方法：

```java
public static RateLimiter create(double permitsPerSecond) {
    return create(permitsPerSecond, SleepingStopwatch.createFromSystemTimer());
}

@VisibleForTesting
static RateLimiter create(double permitsPerSecond, SleepingStopwatch stopwatch) {
    RateLimiter rateLimiter = new SmoothBursty(stopwatch, 1.0 /* maxBurstSeconds */);  // maxBurstSeconds 用于计算 maxPermits
    rateLimiter.setRate(permitsPerSecond); // 设置生成令牌的速率
    return rateLimiter;
}
```

SmoothBursty 的 maxBurstSeconds 构造函数参数主要用于计算 maxPermits，是指在 RateLimiter 未使用时，最多存储几秒的令牌 ：`maxPermits = maxBurstSeconds * permitsPerSecond;`，SleepingStopwatch：guava中的一个时钟类实例，会通过这个来计算时间及令牌。

我们再看一下 setRate 的方法，RateLimiter 中 setRate 方法最终后调用 doSetRate 方法，doSetRate 是一个抽象方法， 内部通过私有锁来保证速率的修改是线程安全的，SmoothRateLimiter 抽象类中覆写了 RateLimiter 的 doSetRate 方法：

```java
// SmoothRateLimiter类中的doSetRate方法，覆写了 RateLimiter 类中的 doSetRate 方法，此方法再委托下面的 doSetRate 方法做处理。
@Override
final void doSetRate(double permitsPerSecond, long nowMicros) {
    resync(nowMicros);
    double stableIntervalMicros = SECONDS.toMicros(1L) / permitsPerSecond;
    this.stableIntervalMicros = stableIntervalMicros;
    doSetRate(permitsPerSecond, stableIntervalMicros);
}

// SmoothBursty 和 SmoothWarmingUp 类中覆写此方法
abstract void doSetRate(double permitsPerSecond, double stableIntervalMicros);

// SmoothBursty 中对 doSetRate的实现
@Override
void doSetRate(double permitsPerSecond, double stableIntervalMicros) {
    double oldMaxPermits = this.maxPermits;
    maxPermits = maxBurstSeconds * permitsPerSecond;
    if (oldMaxPermits == Double.POSITIVE_INFINITY) {
        // if we don't special-case this, we would get storedPermits == NaN, below
        storedPermits = maxPermits;
    } else {  // 如果oldMaxPermits为0，则说明是初始化限流器，当前令牌桶已存在令牌置为0。否则按照新的最大令牌数等比例的扩大已存在的令牌数
        storedPermits =
                (oldMaxPermits == 0.0)
                        ? 0.0 // initial state
                        : storedPermits * maxPermits / oldMaxPermits;
    }
}
```

桶中可存放的最大令牌数由maxBurstSeconds计算而来，其含义为最大存储maxBurstSeconds秒生成的令牌。
该参数的作用在于，可以更为灵活地控制流量。如，某些接口限制为300次/20秒，某些接口限制为50次/45秒等。也就是流量不局限于qps。

### 5.2 resync方法

SmoothRateLimiter 类的 doSetRate方法中我们着重看一下 **resync** 这个方法：

```java
// 基于当前时间，更新下一次请求令牌的时间，以及当前存储的令牌(可以理解为生成令牌)
void resync(long nowMicros) {
    // if nextFreeTicket is in the past, resync to now
    if (nowMicros > nextFreeTicketMicros) {
        double newPermits = (nowMicros - nextFreeTicketMicros) / coolDownIntervalMicros();
        storedPermits = min(maxPermits, storedPermits + newPermits);
        nextFreeTicketMicros = nowMicros;
    }
}
```

根据令牌桶算法，桶中的令牌是持续生成存放的，有请求时需要先从桶中拿到令牌才能开始执行，谁来持续生成令牌存放呢？

一种解法是，开启一个定时任务，由定时任务持续生成令牌。这样的问题在于会极大的消耗系统资源，如，某接口需要分别对每个用户做访问频率限制，假设系统中存在6W用户，则至多需要开启6W个定时任务来维持每个桶中的令牌数，这样的开销是巨大的。

另一种解法则是延迟计算，如上`resync`函数。该函数会在每次获取令牌之前调用，其实现思路为，若当前时间晚于nextFreeTicketMicros，则计算该段时间内可以生成多少令牌，将生成的令牌加入令牌桶中并更新数据。这样一来，只需要在获取令牌时计算一次即可。

resync 方法就是 RateLimiter 中**惰性计算** 的实现。每一次请求来的时候，都会调用到这个方法。这个方法的过程大致如下：

1. 首先判断当前时间是不是大于 nextFreeTicketMicros ，如果是则代表系统已经"cool down"， 这两次请求之间应该有新的 permit 生成。
2. 计算本次应该新添加的 permit 数量，这里分式的分母是 coolDownIntervalMicros 方法，它是一个抽象方法。在 SmoothBursty 和 SmoothWarmingUp 中分别有不同的实现。SmoothBursty 中返回的是 stableIntervalMicros 也即是 `1 / QPS`。coolDownIntervalMicros 方法在 SmoothWarmingUp 中的计算方式为`warmupPeriodMicros / maxPermits`，warmupPeriodMicros 是 SmoothWarmingUp 的“预热”时间。
3. 计算 storedPermits，这个逻辑比较简单。
4. 设置 nextFreeTicketMicros 为 nowMicros。

### 5.3 tryAcquire方法

tryAcquire 方法用于尝试获取若干个 permit，此方法不会等待，如果获取失败则直接返回失败。canAcquire 方法用于判断当前的请求能否通过：

```java
public boolean tryAcquire(int permits, long timeout, TimeUnit unit) {
    long timeoutMicros = max(unit.toMicros(timeout), 0);
    checkPermits(permits);
    long microsToWait;
    synchronized (mutex()) {
        long nowMicros = stopwatch.readMicros();
        if (!canAcquire(nowMicros, timeoutMicros)) { // 首先判断当前超时时间之内请求能否被满足，不能满足的话直接返回失败
            return false;
        } else {
            microsToWait = reserveAndGetWaitLength(permits, nowMicros); // 计算本次请求需要等待的时间，核心方法
        }
    }
    stopwatch.sleepMicrosUninterruptibly(microsToWait);
    return true;
}

final long reserveAndGetWaitLength(int permits, long nowMicros) {
    long momentAvailable = reserveEarliestAvailable(permits, nowMicros);
    return max(momentAvailable - nowMicros, 0);
}

private boolean canAcquire(long nowMicros, long timeoutMicros) {
    return queryEarliestAvailable(nowMicros) - timeoutMicros <= nowMicros;
}

final long queryEarliestAvailable(long nowMicros) {
    return nextFreeTicketMicros;
}
```

canAcquire 方法逻辑比较简单，就是看 nextFreeTicketMicros 减去 timeoutMicros 是否小于等于 nowMicros。如果当前需求能被满足，则继续往下走。第一次运行的时候，nextFreeTicketMicros 是创建时候的时间，必定小于当前时间，所以第一次肯定会放过，允许执行，只是需要计算要等待的时间。

接着会调用 SmoothRateLimiter 类的 reserveEarliestAvailable 方法，该方法返回当前请求需要等待的时间。该方法在 acquire 方法中也会用到，我们来着重分析这个方法。

```java
// 计算本次请求需要等待的时间
final long reserveEarliestAvailable(int requiredPermits, long nowMicros) {

    resync(nowMicros); // 本次请求和上次请求之间间隔的时间是否应该有新的令牌生成，如果有则更新 storedPermits
    long returnValue = nextFreeTicketMicros;
    
    // 本次请求的令牌数 requiredPermits 由两个部分组成：storedPermits 和 freshPermits，storedPermits 是令牌桶中已有的令牌
    // freshPermits 是需要新生成的令牌数
    double storedPermitsToSpend = min(requiredPermits, this.storedPermits);
    double freshPermits = requiredPermits - storedPermitsToSpend;
    
    // 分别计算从两个部分拿走的令牌各自需要等待的时间，然后总和作为本次请求需要等待的时间，SmoothBursty 中从 storedPermits 拿走的部分不需要等待时间
    long waitMicros =
        storedPermitsToWaitTime(this.storedPermits, storedPermitsToSpend)
            + (long) (freshPermits * stableIntervalMicros);
            
    // 更新 nextFreeTicketMicros，这里更新的其实是下一次请求的时间，是一种“预消费”
    // 下次能够获取令牌的时间，需要延迟当前已经等待的时间，也就是说，如果立马有请求过来会放行，但是这个等待时间将会影响后续的请求访问，也就是说，这次的请求如果当前的特别的多，下一次能够请求的能够允许的时间必定会有很长的延迟
    this.nextFreeTicketMicros = LongMath.saturatedAdd(nextFreeTicketMicros, waitMicros);
    
    // 更新 storedPermits
    this.storedPermits -= storedPermitsToSpend;
    return returnValue;
}

/**
* Translates a specified portion of our currently stored permits which we want to spend/acquire,
* into a throttling time. Conceptually, this evaluates the integral of the underlying function we
* use, for the range of [(storedPermits - permitsToTake), storedPermits].
*
* <p>This always holds: {@code 0 <= permitsToTake <= storedPermits}
*/
abstract long storedPermitsToWaitTime(double storedPermits, double permitsToTake);
```

上面的代码是 SmoothRateLimiter 中的具体实现。其主要有以下步骤：

1. resync，这个方法之前已经分析过，这里不再赘述。其主要用来计算当前请求和上次请求之间这段时间需要生成新的 permit 数量。

2. 对于 requiredPermits ，RateLimiter 将其分为两个部分：storedPermits 和 freshPermits。storedPermits 代表令牌桶中已经存在的令牌，可以直接拿出来用，freshPermits 代表本次请求需要新生成的 permit 数量。

3. 分别计算 storedPermits 和 freshPermits 拿出来的部分的令牌数所需要的时间，对于 freshPermits 部分的时间比较好计算：直接拿 freshPermits 乘以 stableIntervalMicros 就可以得到。而对于需要从 storedPermits 中拿出来的部分则计算比较复杂，这个计算逻辑在 storedPermitsToWaitTime 方法中实现。storedPermitsToWaitTime 方法在 SmoothBursty 和 SmoothWarmingUp 中有不同的实现。storedPermitsToWaitTime 意思就是表示当前请求从 storedPermits 中拿出来的令牌数需要等待的时间，因为 SmoothBursty 中没有“热身”的概念， storedPermits 中有多少个就可以用多少个，不需要等待，因此 storedPermitsToWaitTime 方法在 SmoothBursty 中返回的是0。而它在 SmoothWarmingUp 中的实现后面会着重分析。

   storedPermits 本身是用来衡量没有使用的时间的。在没有使用令牌的时候存储，存储的速率（单位时间内存储的令牌的个数）是 每没用1次就存储1次: rate=permites/time 。也就是说 1 / rate = time / permits，那么可得到 (1/rate)*permits 就可以来衡量时间花销。

   选取(1/rate)作为基准线

   - 如果选取一条在它之上的线，就做到了比从 fresh permits 中获取要慢；
   - 如果在基准线之下，则是比从 fresh permits 中获取要快；
   - 刚好是基准线，那么从 storedPermits 中获取和新产生的速率一模一样；

   Bursty 的 storedPermitsToWaitTime 方法实现直接返回了0，也就是在基准线之下，获取storedPermits的速率比新产生要快，立即能够拿到存储的量。

4. 计算到了本次请求需要等待的时间之后，会将这个时间加到 nextFreeTicketMicros 中去。最后从 storedPermits 减去本次请求从这部分拿走的令牌数量。

5. reserveEarliestAvailable 方法返回的是本次请求需要等待的时间，该方法中算出来的 waitMicros 按理来说是应该作为返回值的，但是这个方法返回的却是开始时的 nextFreeTicketMicros ，而算出来的 waitMicros 累加到 nextFreeTicketMicros 中去了。这里其实就是“预消费”，让下一次消费来为本次消费来“买单”。

### 5.4 acquire方法

```java
public double acquire(int permits) {
    long microsToWait = reserve(permits);
    stopwatch.sleepMicrosUninterruptibly(microsToWait);
    return 1.0 * microsToWait / SECONDS.toMicros(1L);
}
  
final long reserve(int permits) {
    checkPermits(permits);
    synchronized (mutex()) {
      return reserveAndGetWaitLength(permits, stopwatch.readMicros());
    }
}
  
final long reserveAndGetWaitLength(int permits, long nowMicros) {
    long momentAvailable = reserveEarliestAvailable(permits, nowMicros);
    return max(momentAvailable - nowMicros, 0);
}  
  
abstract long reserveEarliestAvailable(int permits, long nowMicros);  
```

acquire 函数主要用于获取 permits 个令牌，并计算需要等待多长时间，进而挂起等待，并将该值返回，主要通过 reserve 返回需要等待的时间，reserve 中通过调用 reserveAndGetWaitLength 获取等待时间。最终还是通过 reserveEarliestAvailable 方法来计算本次请求需要等待的时间。这个方法上面已经分析过了，这里就不再过多阐述。

```java
public static void sleepUninterruptibly(long sleepFor, TimeUnit unit) {
    //sleep 阻塞线程 内部通过Thread.sleep()
  boolean interrupted = false;
  try {
    long remainingNanos = unit.toNanos(sleepFor);
    long end = System.nanoTime() + remainingNanos;
    while (true) {
      try {
        // TimeUnit.sleep() treats negative timeouts just like zero.
        NANOSECONDS.sleep(remainingNanos);
        return;
      } catch (InterruptedException e) {
        interrupted = true;
        remainingNanos = end - System.nanoTime();
        //如果被interrupt可以继续，更新sleep时间，循环继续sleep
      }
    }
  } finally {
    if (interrupted) {
      Thread.currentThread().interrupt();
      //如果被打断过，sleep过后再真正中断线程
    }
  }
}
```

sleep之后，acquire 返回 sleep 的时间，阻塞结束，获取到令牌。

------

## 6. SmoothWarmingUp

SmoothWarmingUp 相对 SmoothBursty 来说主要区别在于 storedPermitsToWaitTime 方法。其他部分原理和 SmoothBursty 类似。

### 6.1 创建

SmoothWarmingUp 是 SmoothRateLimiter 的子类，它相对于 SmoothRateLimiter 多了几个属性：

```java
static final class SmoothWarmingUp extends SmoothRateLimiter {
    /**
     * 预热时间，单位毫秒
     */
    private final long warmupPeriodMicros;
    /**
     * The slope of the line from the stable interval (when permits == 0), to the cold interval
     * (when permits == maxPermits)
     * 斜率，用于计算坐标系中梯形面积
     */
    private double slope;

    /**
     * 预热期与稳定期令牌数临界值
     */
    private double thresholdPermits;

    /**
     * 冷却期因子，用于计算冷却期产生令牌时间间隔
     */
    private double coldFactor;

    SmoothWarmingUp(
            SleepingStopwatch stopwatch, long warmupPeriod, TimeUnit timeUnit, double coldFactor) {
        super(stopwatch);
        this.warmupPeriodMicros = timeUnit.toMicros(warmupPeriod);
        this.coldFactor = coldFactor;
    }

    /**
     * @param permitsPerSecond     每秒生成令牌数，SmoothWarmingUp用不上
     * @param stableIntervalMicros 稳定期令牌生成间隔时间
     */
    @Override
    void doSetRate(double permitsPerSecond, double stableIntervalMicros) {
        double oldMaxPermits = maxPermits;
        // 冷却期产生令牌时间间隔 = 稳定期令牌生成间隔时间 * 冷却期因子
        double coldIntervalMicros = stableIntervalMicros * coldFactor;
        // 临界值 = 0.5 * 预热时间 / 稳定期令牌生成间隔时间
        // 源码的注释中说，从maxPermits到thresholdPermits，需要用warmupPeriod的时间，而从thresholdPermits到0需要warmupPeriod一半的时间
        // 因为前面coldFactor被硬编码为3.好吧~
        thresholdPermits = 0.5 * warmupPeriodMicros / stableIntervalMicros;
        // 最大令牌数 = 临界值 + 2 * 预热时间 / (稳定期令牌生成间隔时间 + 冷却期产生令牌时间间隔)
        // 为什么是这么算出来的呢？源码的注释已经给出了推导过程。因为坐标系中右边的梯形面积就是预热的时间，即：
        // warmupPeriodMicros = 0.5 * (stableInterval + coldInterval) * (maxPermits - thresholdPermits)
        // 因此可以推导求出maxPermits：
        maxPermits = thresholdPermits + 2.0 * warmupPeriodMicros / (stableIntervalMicros + coldIntervalMicros);

        // 咳咳，这里其实仔细算算，一顿操作猛如虎，因为coldFactor默认为3，所以其实：
        // maxPermits = warmupPeriodMicros / stableIntervalMicros
        // thresholdPermits = 0.5 * warmupPeriodMicros / stableIntervalMicros = maxPermits / 2

        // 斜率 = (冷却期产生令牌时间间隔 - 稳定期令牌生成间隔时间) / (最大令牌数 - 临界值)
        // 看图，是小学数学题的求斜率哦
        slope = (coldIntervalMicros - stableIntervalMicros) / (maxPermits - thresholdPermits);

        // 这部分和稳定限流器的逻辑不一样，初始化时默认storedPermits就为maxPermits
        if (oldMaxPermits == Double.POSITIVE_INFINITY) {
            // if we don't special-case this, we would get storedPermits == NaN, below
            storedPermits = 0.0;
        } else {
            storedPermits = (oldMaxPermits == 0.0) ? maxPermits : storedPermits * maxPermits / oldMaxPermits;
        }
    }

    /**
     * 计算令牌桶的等待时间
     * 怎么计算时间呢？我们用给的这个坐标系来计算。
     * 其中纵坐标是生成令牌的间隔时间，横坐标是桶中的令牌数。
     * 我们要计算消耗掉permitsToTake个令牌数需要的时间，实际上就是求坐标系中的面积
     * 所以storedPermitsToWaitTime方法实际上就是求三种情况下的面积
     *
     * @param storedPermits 令牌桶中存在的令牌数
     * @param permitsToTake 本次消耗掉的令牌数
     * @return
     */
    @Override
    long storedPermitsToWaitTime(double storedPermits, double permitsToTake) {
        // 当前令牌桶内的令牌数和临界值的差值
        double availablePermitsAboveThreshold = storedPermits - thresholdPermits;
        long micros = 0;
        // measuring the integral on the right part of the function (the climbing line)
        // 高于临界值，则需要根据预热算法计算时间
        if (availablePermitsAboveThreshold > 0.0) {
            // WARM UP PERIOD 可能就足够使用了，也可能不够。所以，梯形的高是 permitsAboveThresholdToTake
            double permitsAboveThresholdToTake = min(availablePermitsAboveThreshold, permitsToTake);
            double length = permitsToTime(availablePermitsAboveThreshold) + permitsToTime(availablePermitsAboveThreshold - permitsAboveThresholdToTake);
            micros = (long) (permitsAboveThresholdToTake * length / 2.0);
            permitsToTake -= permitsAboveThresholdToTake;
        }
        // measuring the integral on the left part of the function (the horizontal line)
        // 如果不走上面的分支，则说明当前限流器不处于预热阶段，那么，等待时间 = 消耗掉的令牌数 * 稳定令牌生成间隔时间

        micros += (long) (stableIntervalMicros * permitsToTake);
        return micros;
    }

    private double permitsToTime(double permits) {
        return stableIntervalMicros + permits * slope;
    }

    @Override
    double coolDownIntervalMicros() {
        return warmupPeriodMicros / maxPermits;
    }
}
```

这四个参数都是和 SmoothWarmingUp 的“热身”（warmup）机制相关。warmup 可以用如下的图来表示：

```java
*          ^ throttling
*          |
*    cold  +                  /
* interval |                 /.
*          |                / .
*          |               /  .   ← "warmup period" is the area of the trapezoid between
*          |              /   .     thresholdPermits and maxPermits
*          |             /    .
*          |            /     .
*          |           /      .
*   stable +----------/  WARM .
* interval |          .   UP  .
*          |          . PERIOD.
*          |          .       .
*        0 +----------+-------+--------------→ storedPermits
*          0 thresholdPermits maxPermits
  
* 等价于

*          ^ throttling
*          |
* 3*stable +                  /
* interval |                 /.
*  (cold)  |                / .
*          |               /  .   <-- "warmup period" is the area of the trapezoid between
* 2*stable +              /   .       halfPermits and maxPermits
* interval |             /    .
*          |            /     .
*          |           /      .
*   stable +----------/  WARM . }
* interval |          .   UP  . } <-- this rectangle (from 0 to maxPermits, and
*          |          . PERIOD. }     height == stableInterval) defines the cooldown period,
*          |          .       . }     and we want cooldownPeriod == warmupPeriod
*          |---------------------------------> storedPermits
*              (halfPermits) (maxPermits)
```

> 1. RateLimiter (storedPermits) 的状态是该图中的一条垂直线。
>
> 2. 当不使用 RateLimiter 时，我们在最右端（最多 maxPermits）。
> 3. 当使用 RateLimiter 时，它会向左移动（直到下降到零），因为如果我们有 storagePermits，我们会从第一个服务。
> 4. 当__unused__时，我们以恒定的速度向右移动，速率是 maxPermits / warmup period。这确保了从 0 到 maxPermits 所需的时间等于 warmup period。
> 5. 当__used__时，假设我们要 K 个已保存的 permit，它所花费的时间等于我们的函数在 X 个 permit 和 X-K 个 permit 之间的积分。
>
> 综上所述，向左移动所需的时间（花费 K个 permit），等于宽度 == K 的函数的面积。
>
> warmup period = 2 * cooldown period（梯形面积 = 2 * 矩形面积）
>
> 假设我们有饱和需求，从 maxPermits 到 thresholdPermits 的时间等于 warmupPeriod。而从 thresholdPermits 到 0 的时间是 warmupPeriod / 2。 （这是 warmupPeriod / 2 的原因是为了保持原始实现的行为，其中 coldFactor 被硬编码为 3）
>
> 剩下的就是计算 thresholdsPermits 和 maxPermits。
>
> - 从 thresholdPermits 到 0 的时间等于函数在 0 和 thresholdPermits 之间的积分。这是 thresholdPermits * stableIntervals。通过 上面的第5条法则， 它也等于 warmupPeriod / 2。所以 thresholdPermits = 0.5 * warmupPeriod / stableInterval
>
> - 从 maxPermits 到 thresholdPermits 的时间等于 thresholdPermits 和 maxPermits 之间函数的积分。这是图中梯形的面积，它等于 0.5 (stableInterval + coldInterval) * (maxPermits - thresholdPermits)。它也等于 warmupPeriod，所以 maxPermits = thresholdPermits + 2 * warmupPeriod / (stableInterval + coldInterval)
>
> 横轴表示存储的令牌个数，纵轴表示消费每个 permit 需要的时间，这样函数的积分就可以表示获取 n 个 permit 所要消耗的时间。
> 在程序刚开始运行的时候，warmingup方式会存满所有的令牌，而根据从存储令牌中的获取方式，可以实现从存储最大令牌中到降到一半令牌所需要的时间为存储同量令牌时间的2倍，从而使得刚开始的时候发放令牌的速度比较慢，等消耗一半之后，获取的速率和生产的速率一致，从而也就实现了一个‘热身’的概念
>
> 从storedPermits中获取令牌所需要的时间，它分为两部分，以maxPetmits 的一半为分割点
>
> - storedPermits <= halfPermits 的时候，存储和消费 storedPermits 的速率与产生的速率一模一样
> - storedPermits > halfPermits, 存储 storePermites 所需要的时间和产生的速率保持一致，但是消费 storePermites 从maxPermits 到 halfPermits 所需要的时间为从 halfPermits 增长到 maxPermits  所需要时间的2倍，也就是比新令牌产生要慢 。为什么在分隔点计算还有斜率方面选了3倍和一半的位置？对函数做积分计算(图形面积)，刚好可以保证，超过一半的部分，如果要拿掉一半的存储令牌所需要的时间恰好是存储同样量（或者说是新令牌产生）时间花销的两倍，对应场景如果过了很长一段时间没有使用(存储的令牌会达到maxPermits)，刚开始能接收请求的速率相对比较慢，然后再增长到稳定的消费速率。
>
> 关键在于存储的速率是和新令牌产生的速率一样，但是消费的速率，当存储的超过一半时，会慢于新令牌产生的速率，小于一半则速率是一样的。

上图中横坐标是当前令牌桶中的令牌 storedPermits，前面说过 SmoothWarmingUp 将 storedPermits 分为两个区间：[0, thresholdPermits) 和 [thresholdPermits, maxPermits]。纵坐标是生成令牌的间隔时间，stableInterval 就是 `1 / QPS`，例如设置的 QPS 为5，则 stableInterval 就是200ms，`coldInterval = stableInterval * coldFactor`，这里的 coldFactor "hard-code"写死的是3。

注释中说的三种情况，就是在以下三种情况下，求函数图像和x轴之间围成的面积，如下： 第一种，限流器在预热期，获取permitsToTake个令牌后，桶中的令牌数多于thresholdPermits，如图：

<img src="http://blog-1259650185.cosbj.myqcloud.com/img/202204/18/1650270705.jpg" alt="img" style="zoom:50%;" />

第二种，限流器在预热期，获取permitsToTake个令牌后，桶中的令牌数少于thresholdPermits，如图：

<img src="http://blog-1259650185.cosbj.myqcloud.com/img/202204/18/1650270724.jpg" alt="img" style="zoom:50%;" />

第三种，限流器处于稳定期，如图：

<img src="http://blog-1259650185.cosbj.myqcloud.com/img/202204/18/1650270741.jpg" alt="img" style="zoom:50%;" />

对于注释中所说的简化计算 maxPermits = warmupPeriodMicros / stableIntervalMicros 的过程，推导如下：

<img src="http://blog-1259650185.cosbj.myqcloud.com/img/202204/18/1650270511.jpg" alt="img" style="zoom:50%;" />



### 6.2 storedPermitsToWaitTime方法

上面"矩形+梯形"图像的面积就是 waitMicros 也即是本次请求需要等待的时间。计算过程在 SmoothWarmingUp 类的 storedPermitsToWaitTime 方法中覆写:

```java
@Override
long storedPermitsToWaitTime(double storedPermits, double permitsToTake) {
    double availablePermitsAboveThreshold = storedPermits - thresholdPermits;
    long micros = 0;
    // measuring the integral on the right part of the function (the climbing line)
    if (availablePermitsAboveThreshold > 0.0) { // 如果当前 storedPermits 超过 availablePermitsAboveThreshold 则计算从 超过部分拿令牌所需要的时间（图中的 WARM UP PERIOD）
        // WARM UP PERIOD 部分计算的方法，这部分是一个梯形，梯形的面积计算公式是 “（上底 + 下底） * 高 / 2”
        double permitsAboveThresholdToTake = min(availablePermitsAboveThreshold, permitsToTake);
        // TODO(cpovirk): Figure out a good name for this variable.
        double length = permitsToTime(availablePermitsAboveThreshold)
                + permitsToTime(availablePermitsAboveThreshold - permitsAboveThresholdToTake);
        micros = (long) (permitsAboveThresholdToTake * length / 2.0); // 计算出从 WARM UP PERIOD 拿走令牌的时间
        permitsToTake -= permitsAboveThresholdToTake; // 剩余的令牌从 stable 部分拿
    }
    // measuring the integral on the left part of the function (the horizontal line)
    micros += (stableIntervalMicros * permitsToTake); // stable 部分令牌获取花费的时间
    return micros;
}

// WARM UP PERIOD 部分 获取相应令牌所对应的的时间
private double permitsToTime(double permits) {
    return stableIntervalMicros + permits * slope;
}
```

SmoothWarmingUp 类中 storedPermitsToWaitTime 方法将 permitsToTake 分为两部分，一部分从 WARM UP PERIOD 部分拿，这部分是一个梯形，面积计算就是（上底 + 下底）* 高 / 2。另一部分从 stable 部分拿，它是一个长方形，面积就是 长 * 宽。最后返回两个部分的时间总和。

------

## 9. 计时器

最后要说一下RateLimiter类中的计时器。

计时器随限流器初始化时创建，贯穿始终，伴随限流器漫长的一生。令牌桶中数量的计算、是否到达可以接收请求的时间点都需要计时器参与。我认为计时器是限流器成立的基础。

限流器使用的是 SleepingStopwatch 这个内部类作为计时器。而 SleepingStopwatch 的则是通过持有一个 Stopwatch 对象来实现计时和休眠。

```java
/**
 * The underlying timer; used both to measure elapsed time and sleep as necessary. A separate
 * object to facilitate testing.
 * 一个底层的限流器，用于测量运行时间和睡眠时间
 */
private final SleepingStopwatch stopwatch;

abstract static class SleepingStopwatch {
    /**
     * Constructor for use by subclasses.
     */
    protected SleepingStopwatch() {
    }

    /**
     * 获取当前时间点
     *
     * @return
     */
    protected abstract long readMicros();

    /**
     * 按照计算的睡眠时间等待休眠
     *
     * @param micros
     */
    protected abstract void sleepMicrosUninterruptibly(long micros);

    public static SleepingStopwatch createFromSystemTimer() {
        return new SleepingStopwatch() {
            final Stopwatch stopwatch = Stopwatch.createStarted();

            @Override
            protected long readMicros() {
                return stopwatch.elapsed(MICROSECONDS);
            }

            @Override
            protected void sleepMicrosUninterruptibly(long micros) {
                if (micros > 0) {
                    Uninterruptibles.sleepUninterruptibly(micros, MICROSECONDS);
                }
            }
        };
    }
}
```

------

## 8. 总结

1. RateLimiter中采用惰性方式来计算两次请求之间生成多少新的 permit，这样省去了后台计算任务带来的开销。
2. 最终的 requiredPermits 由两个部分组成：storedPermits 和 freshPermits 。SmoothBursty 中 storedPermits 都是一样的，不做区分。而 SmoothWarmingUp 类中将其分成两个区间：[0, thresholdPermits) 和 [thresholdPermits, maxPermits]，存在一个"热身"的阶段，thresholdPermits 是系统 stable 阶段和 cold 阶段的临界点。从 thresholdPermits 右边的部分拿走 permit 需要等待的时间更长。左半部分是一个矩形，由半部分是一个梯形。
3. RateLimiter 能够处理突发流量的请求，采取一种"预消费"的策略。
4. RateLimiter 只能用作单个JVM实例上接口或者方法的限流，不能用作全局流量控制。

> Q：maxBurstSeconds 在代码里如何设置哈？
> SmoothBursty 允许突发请求，如果说初始时 permitsPerSecond 为10，maxPermits 为10的话，第一次 acquire 了100，此时是能获取到令牌的，一次响应了100个请求。但下一次 acquire 的话需要等待10秒。这样保证了平均的速率，感觉瞬时的速率没有被限制住吧？ 这样理解对吗？
>
> A：是这样的，guava 的 ratelimiter 基本也没办法处理这种突发请求
> 但是，比如需要限制每分钟60次，可以将 permitsPerSecond 设为1，maxPermits 也设为1，这样可以保证每秒最多调用一次，也就是每分钟最多调用60次。
>
> 在acquire之前，你应该知道一次最大允许 acquire 多少个 permit，这个值就是 permitsPerSecond。
> 对于突发请求，有两种理解：
>
> 1. 大量的请求同时 acquire
>
> 比如RateLimiter.create(10)，一段时间没有 acquire，然后1000个线程同时去 acquire，有且只有10(也可以说11)个线程可以无需等待拿到 permit。
> 这就是相对漏桶算法优势的地方，一段时间没有去 acquire，却允许一定数量的线程可以拿到 permit。
>
> 2. 某个请求 acquire 的数量很大，比如 rateLimiter.acquire(1000)，这个1000远远超过了 permitsPerSecond。
>
> 对于这种情况，就是设计不合理的地方了，既然你设置的 permitsPerSecond 是10，那么就不应该有 acquire(1000)的情况出现，所以 guava 里有这行源码
> double storedPermitsToSpend = min(requiredPermits, this.storedPermits);
> 参见源码：com.google.common.util.concurrent.SmoothRateLimiter#reserveEarliestAvailable




## 参考

[Guava RateLimiter限流](https://juejin.cn/post/6844903783432978439)

[逐行拆解Guava限流器RateLimiter](https://zhuanlan.zhihu.com/p/439682111)

[限流原理解读之guava中的RateLimiter](https://juejin.cn/post/6844903687026901000)
