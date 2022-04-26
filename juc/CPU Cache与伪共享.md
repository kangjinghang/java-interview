## 认识CPU Cache

随着CPU的频率不断提升，而内存的访问速度却没有质的突破，为了弥补访问内存的速度慢，充分发挥CPU的计算资源，提高CPU整体吞吐量，在CPU与内存之间引入了一级Cache。随着热点数据体积越来越大，一级Cache L1已经不满足发展的要求，引入了二级Cache L2，三级Cache L3。（注：若无特别说明，本文的Cache指CPU Cache，高速缓存）CPU Cache在存储器层次结构中的示意如下图：

<img src="http://blog-1259650185.cosbj.myqcloud.com/img/202202/14/1644768910.png" alt="2" style="zoom: 67%;" />

> **寄存器**（Register）是中央处理器内用来暂存指令、数据和地址的电脑存储器。寄存器的存贮容量有限，读写速度非常快。在计算机体系结构里，寄存器存储在已知时间点所作计算的中间结果，通过快速地访问数据来加速计算机程序的运行。
>
> 寄存器位于存储器层次结构的最顶端，也是CPU可以读写的最快的存储器。寄存器通常都是以他们可以保存的比特数量来计量，举例来说，一个8位寄存器或32位寄存器。在中央处理器中，包含寄存器的部件有指令寄存器（IR）、程序计数器和累加器。寄存器现在都以寄存器数组的方式来实现，但是他们也可能使用单独的触发器、高速的核心存储器、薄膜存储器以及在数种机器上的其他方式来实现出来。
>
> **寄存器**也可以指代由一个指令之输出或输入可以直接索引到的寄存器组群，这些寄存器的更确切的名称为“架构寄存器”。例如，x86指令集定义八个32位寄存器的集合，但一个实现x86指令集的CPU内部可能会有八个以上的寄存器。
>
> L1缓分成两种，一种是指令缓存，一种是数据缓存。L2缓存和L3缓存不分指令和数据。
>
> L1和L2缓存在每一个CPU核中，L3则是所有CPU核心共享的内存。
>
> L1、L2、L3的越离CPU近就越小，速度也越快，越离CPU远，速度也越慢。
>
> CPU Cache 存在的目的：我 CPU 这么快，我每次去主存去取数据那代价也太大了，我就在我自己开辟一个内存池，来存我最想要的一些数据。那哪些数据可以被加载到 CPU 缓存道中来呢？复杂的计算和编程代码呗。
>
> 如果我在L1的内存池当中没有找到我想要的数据呢？就是**缓存未命中**
>
> 还能怎么办，去L2找呗，一些处理器使用**包含性缓存设计**（意味着存储在L1缓存中的数据也将在L2缓存中重复），而**其他处理器则是互斥**的（意味着两个缓存永不共享数据）。如果在L2高速缓存中找不到数据，则CPU会继续沿链条向下移动到L3（通常仍在裸片上），然后是L4（如果存在）和主内存（DRAM）。

计算机早已进入多核时代，软件也越来越多的支持多核运行。一个处理器对应一个物理插槽，多处理器间通过QPI总线相连。一个处理器包含多个核，一个处理器间的多核共享L3 Cache。一个核包含寄存器、L1 Cache、L2 Cache，下图是Intel Sandy Bridge CPU架构，一个典型的NUMA多处理器结构：

<img src="http://blog-1259650185.cosbj.myqcloud.com/img/202202/14/1644769057.png" alt="3" style="zoom:75%;" />

作为程序员，需要理解计算机存储器层次结构，它对应用程序的性能有巨大的影响。如果需要的程序是在CPU寄存器中的，指令执行时1个周期内就能访问到他们。如果在CPU Cache中，需要1~30个周期；如果在主存中，需要50~200个周期；在磁盘上，大概需要几千万个周期。充分利用它的结构和机制，可以有效的提高程序的性能。

以我们常见的X86芯片为例，Cache的结构下图所示：整个Cache被分为S个组，每个组是又由E行个最小的存储单元——Cache Line所组成，而一个Cache Line中有B（B=64）个字节用来存储数据，即每个Cache Line能存储64个字节的数据，每个Cache Line又额外包含一个有效位(valid bit)、t个标记位(tag bit)，其中valid bit用来表示该缓存行是否有效；tag bit用来协助寻址，唯一标识存储在CacheLine中的块；而Cache Line里的64个字节其实是对应内存地址中的数据拷贝。根据Cache的结构题，我们可以推算出每一级Cache的大小为B×E×S。

<img src="http://blog-1259650185.cosbj.myqcloud.com/img/202202/14/1644769171.png" alt="4" style="zoom:75%;" />

那么如何查看自己电脑CPU的Cache信息呢？

在windows下查看方式有多种方式，其中最直观的是，通过安装CPU-Z软件，直接显示Cache信息，如下图：

<img src="http://blog-1259650185.cosbj.myqcloud.com/img/202202/14/1644769342.png" alt="5" style="zoom:67%;" />

此外，Windows下还有两种方法：

1. Windows API调用GetLogicalProcessorInfo。
2. 通过命令行系统内部工具CoreInfo。

如果是Linux系统， 可以使用下面的命令查看Cache信息：

![6](http://blog-1259650185.cosbj.myqcloud.com/img/202202/14/1644769385.png)

还有lscpu等命令也可以查看相关信息。

如果是Mac系统，可以用sysctl machdep.cpu 命令查看cpu信息。

如果我们用Java编程，还可以通过CacheSize API方式来获取Cache信息， CacheSize是一个谷歌的小项目，Java 语言通过它可以进行访问本机Cache的信息。示例代码如下：

```java
public static void main(String[] args) throws CacheNotFoundException {
    CacheInfo info = CacheInfo.getInstance(); 
    CacheLevelInfo l1Datainf = info.getCacheInformation(CacheLevel.L1, CacheType.DATA_CACHE);
    System.out.println("第一级数据缓存信息："+l1Datainf.toString());

    CacheLevelInfo l1Instrinf = info.getCacheInformation(CacheLevel.L1, CacheType.INSTRUCTION_CACHE);
    System.out.println("第一级指令缓存信息："+l1Instrinf.toString());
}
```

打印输出结果如下：

```java
第一级数据缓存信息：CacheLevelInfo [cacheLevel=L1, cacheType=DATA_CACHE, cacheSets=64, cacheCoherencyLineSize=64, cachePhysicalLinePartitions=1, cacheWaysOfAssociativity=8, isFullyAssociative=false, isSelfInitializing=true, totalSizeInBytes=32768]

第一级指令缓存信息：CacheLevelInfo [cacheLevel=L1, cacheType=INSTRUCTION_CACHE, cacheSets=64, cacheCoherencyLineSize=64, cachePhysicalLinePartitions=1, cacheWaysOfAssociativity=8, isFullyAssociative=false, isSelfInitializing=true, totalSizeInBytes=32768]
```

还可以查询L2、L3级缓存的信息，这里不做示例。从打印的信息和CPU-Z显示的信息可以看出，本机的Cache信息是一致的，L1数据/指令缓存大小都为：C=B×E×S=64×8×64=32768字节=32KB。

**cacheline与内存之间的映射策略** :

- Hash:  (内存地址 % 缓存行) * 64 容易出现Hash冲突
- N-Way Set Associative ： 简单的说就是将N个cacheline分为一组，每个cacheline中，根据偏移进行寻址

从上图可以看出L1的数据缓存32KBytes分为了8-way，那么每一路就是4KBytes.

怎么寻址呢?

前面我们知道：大部分的Cache line一条为64Bytes

- Tag : 每条Cache line 前都会有一个独立分配的24bits=3Bytes来存的tag，也就是内存地址的前24bits。
- Index : 内存地址的后面的6bits=3/4Bytes存的是这一路（way）Cache line的索引，通过6bits我们可以索引2^6=64条Cache line。
- Offset : 在索引后面的6bits存的是Cache line的偏移量。

具体流程：

1. 用索引定位到相应的缓存块。
2. 用标签尝试匹配该缓存块的对应标签值。其结果为命中或未命中。
3. 如命中，用块内偏移定位此块内的目标字。然后直接改写这个字。
4. 如未命中，依系统设计不同可有两种处理策略，分别称为按写分配（Write allocate）和不按写分配（No-write allocate）。如果是按写分配，则先如处理读未命中一样，将未命中数据读入缓存，然后再将数据写到被读入的字单元。如果是不按写分配，则直接将数据写回内存。

如果某一路的缓存写满了怎么办呢？

替换一些最晚访问的字节呗，也就是常说的LRU(最久未使用）。

分析了L1的数据缓存，大家也可以照着分析其他L2、L3缓存，这里就不再分析了。

## MESI 协议及 RFO 请求

为了和下级存储（如内存）保持数据一致性，就必须把数据更新适时传播下去。这种传播通过回写来完成。一般有两种回写策略：**写回**（Write back）和**写通**（Write through）。

根据回写策略和上面提到的未命中的分配策略，请看下表：

![5](http://blog-1259650185.cosbj.myqcloud.com/img/202202/14/1644852544.png)

通过上图，我们知道：

**写回**时：如果缓存命中，不用更新内存，为的就是减少内存写操作，通常分配策略是分配

- 怎么标记缓存在被其他 CPU 加载时被更新过？每个Cache line提供了一个脏位（dirty bit）来标识被加载后是否发生过更新。（CPU在加载时是一块一块加载的，不是一个字节一个字节加载的，前面说过）

  ![4](http://blog-1259650185.cosbj.myqcloud.com/img/202202/14/1644852753.png)

**写通**时：

- 写通是指，每当缓存接收到写数据指令，都直接将数据写回到内存。如果此数据地址也在缓存中，则必须同时更新缓存。由于这种设计会引发造成大量写内存操作，有必要设置一个缓冲来减少硬件冲突。这个缓冲称作写缓冲器（Write buffer），通常不超过4个缓存块大小。不过，出于同样的目的，写缓冲器也可以用于写回型缓存。
- 写通较写回易于实现，并且能更简单地维持数据一致性。
- 通常分配策略是非分配

对于一个两级缓存系统，一级缓存可能会使用写通来简化实现，而二级缓存使用写回确保数据一致性。

从上一节中我们知道，每个核都有自己私有的 L1、L2 缓存。那么多线程编程时， 另外一个核的线程想要访问当前核内 L1、L2 缓存行的数据，该怎么办呢？

有人说可以通过第 2 个核直接访问第 1 个核的缓存行，这是当然是可行的，但这种方法不够快。跨核访问需要通过 Memory Controller（内存控制器，是计算机系统内部控制内存并且通过内存控制器使内存与 CPU 之间交换数据的重要组成部分），典型的情况是第 2 个核经常访问第 1 个核的这条数据，那么每次都有跨核的消耗.。更糟的情况是，有可能第 2 个核与第 1 个核不在一个插槽内，况且 Memory Controller 的总线带宽是有限的，扛不住这么多数据传输。所以，CPU 设计者们更偏向于另一种办法： 如果第 2 个核需要这份数据，由第 1 个核直接把数据内容发过去，数据只需要传一次。

那么什么时候会发生缓存行的传输呢？答案很简单：当一个核需要读取另外一个核的脏缓存行时发生。但是前者怎么判断后者的缓存行已经被弄脏(写)了呢？

下面将详细地解答以上问题. 首先我们需要谈到一个协议—— MESI 协议。现在主流的处理器都是用它来保证缓存的相干性和内存的相干性。M、E、S 和 I 代表使用 MESI 协议时缓存行所处的四个状态：

- M（修改，Modified）：本地处理器已经修改缓存行，即是脏行，它的内容与内存中的内容不一样，并且此 cache 只有本地一个拷贝(专有)；
- E（专有，Exclusive）：缓存行内容和内存中的一样，而且其它处理器都没有这行数据；
- S（共享，Shared）：缓存行内容和内存中的一样, 有可能其它处理器也存在此缓存行的拷贝；
- I（无效，Invalid）：缓存行失效, 不能使用。

下面说明这四个状态是如何转换的：

- 初始：一开始时，缓存行没有加载任何数据，所以它处于 I 状态。
- 本地写（Local Write）：如果本地处理器写数据至处于 I 状态的缓存行，则缓存行的状态变成 M。
- 本地读（Local Read）：如果本地处理器读取处于 I 状态的缓存行，很明显此缓存没有数据给它。此时分两种情况：(1)其它处理器的缓存里也没有此行数据，则从内存加载数据到此缓存行后，再将它设成 E 状态，表示只有我一家有这条数据，其它处理器都没有；(2)其它处理器的缓存有此行数据，则将此缓存行的状态设为 S 状态。（备注：如果处于M状态的缓存行，再由本地处理器写入/读出，状态是不会改变的）
- 远程读（Remote Read）：假设我们有两个处理器 c1 和 c2，如果 c2 需要读另外一个处理器 c1 的缓存行内容，c1 需要把它缓存行的内容通过内存控制器 (Memory Controller) 发送给 c2，c2 接到后将相应的缓存行状态设为 S。在设置之前，内存也得从总线上得到这份数据并保存。
- 远程写（Remote Write）：其实确切地说不是远程写，而是 c2 得到 c1 的数据后，不是为了读，而是为了写。也算是本地写，只是 c1 也拥有这份数据的拷贝，这该怎么办呢？c2 将发出一个 RFO (Request For Owner) 请求，它需要拥有这行数据的权限，其它处理器的相应缓存行设为 I，除了它自已，谁不能动这行数据。这保证了数据的安全，同时处理 RFO 请求以及设置I的过程将给写操作带来很大的性能消耗。

状态转换由下图做个补充：

![7](http://blog-1259650185.cosbj.myqcloud.com/img/202202/14/1644818564.png)

我们从上节知道，写操作的代价很高，特别当需要发送 RFO 消息时。我们编写程序时，什么时候会发生 RFO 请求呢？有以下两种：

1. 线程的工作从一个处理器移到另一个处理器, 它操作的所有缓存行都需要移到新的处理器上。此后如果再写缓存行，则此缓存行在不同核上有多个拷贝，需要发送 RFO 请求了。
2. 两个不同的处理器确实都需要操作相同的缓存行。

这里有一个网页（[MESI Interactive Animations](https://www.scss.tcd.ie/Jeremy.Jones/VivioJS/caches/MESIHelp.htm) ），建议先玩一玩上面网址的动图，可以了解下，各个cpu的缓存和主存的读、写数据。

这里简单阐述一下：我们主存有个x=0的值，处理器有两个cpu0,cpu1

- **cpu0读x的值**，cpu0先在cpu0缓存找，找不到，有一个**地址总线**，就是路由cpu的和主存，同时去**cpu和主存找**，比较版本，去主存拿x，拿到x的值通过**数据总线**将值赋值cpu0的缓存

  <img src="http://blog-1259650185.cosbj.myqcloud.com/img/202202/14/1644853083.png" alt="image-20220214233803498" style="zoom: 33%;" />

- **cpu0对x+1写**，直接获取cpu0的x=0，进行加1（这里不会更新主存，也不会更新cpu1的缓存，cpu1缓存还没有x的值）

  <img src="http://blog-1259650185.cosbj.myqcloud.com/img/202202/14/1644853161.png" alt="image-20220214233921263" style="zoom:33%;" />

- **cpu1读x的值**，首先在cpu1的缓存中找，找不到，根据**地址总线**，同时去cpu和主存找，比较版本（如果版本一样，会优先去主存的值），找到cpu0的x值，cpu0通过**数据总线**将数据优先更新cpu1的缓存x的值，在更新主存x的值

  <img src="http://blog-1259650185.cosbj.myqcloud.com/img/202202/14/1644853312.png" alt="image-20220214234152454" style="zoom:33%;" />

- **cpu1对x+1**，直接获取cpu1的x=1，进行加1（这里会更新主存，也不会更新cpu0的缓存，但是会通过RFO通知其他cpu）

  <img src="http://blog-1259650185.cosbj.myqcloud.com/img/202202/14/1644853421.png" alt="image-20220214234340954" style="zoom:33%;" />

其他情况可以自己去试一下。

通知协议：

**Snoopy 协议**。这种协议更像是一种数据通知的总线型的技术。CPU Cache通过这个协议可以识别其它Cache上的数据状态。如果有数据共享的话，可以通过广播机制将共享数据的状态通知给其它CPU Cache。这个协议要求每个CPU Cache 都可以“窥探”数据事件的通知并做出相应的反应。

扩展一下：

**MOESI**：MOESI是一个完整的缓存一致性协议，其中包含其他协议中常用的所有可能状态。除了四个常见的MESI协议状态外，还有第五个“拥有”状态，表示已修改和共享的数据。这样避免了在共享之前将修改后的数据写回主存储器的需要。尽管最终仍必须回写数据，但可以**推迟回写**。

**MOESF**：Forward状态下的数据是**clean**的，可以丢弃而**不用另行通知**。

**AMD用MOESI，Intel用MESIF**。

## Cache Line伪共享及解决方案

### Cache Line伪共享分析

说伪共享前，先看看Cache Line 在 Java 编程中使用的场景。如果CPU访问的内存数据不在Cache中（一级、二级、三级），这就产生了Cache Line miss问题，此时CPU不得不发出新的加载指令，从内存中获取数据。通过前面对Cache存储层次的理解，我们知道一旦CPU要从内存中访问数据就会产生一个较大的时延，程序性能显著降低，所谓远水救不了近火。为此我们不得不提高Cache命中率，也就是充分发挥局部性原理。

局部性包括时间局部性、空间局部性。时间局部性：对于同一数据可能被多次使用，自第一次加载到Cache Line后，后面的访问就可以多次从Cache Line中命中，从而提高读取速度（而不是从下层缓存读取）。空间局部性：一个Cache Line有64字节块，我们可以充分利用一次加载64字节的空间，把程序后续会访问的数据，一次性全部加载进来，从而提高Cache Line命中率（而不是重新去寻址读取）。

看个例子：内存地址是连续的数组（利用空间局部性），能一次被L1缓存加载完成。

如下代码，长度为16的row和column数组，在Cache Line 64字节数据块上内存地址是连续的，能被一次加载到Cache Line中，所以在访问数组时，Cache Line命中率高，性能发挥到极致。

```java
public int run(int[] row, int[] column) {
    int sum = 0;
    for(int i = 0; i < 16; i++ ) {
        sum += row[i] * column[i];
    }
    return sum;
}
```

而上面例子中变量i则体现了时间局部性，i作为计数器被频繁操作，一直存放在寄存器中，每次从寄存器访问，而不是从主存甚至磁盘访问。虽然连续紧凑的内存分配带来高性能，但并不代表它一直都能带来高性能。如果把它放在多线程中将会发生什么呢？如图：

<img src="http://blog-1259650185.cosbj.myqcloud.com/img/202202/14/1644818862.png" alt="8" style="zoom:75%;" />

上图中，一个运行在处理器 core1上的线程想要更新变量 X 的值，同时另外一个运行在处理器 core2 上的线程想要更新变量 Y 的值。但是，这两个频繁改动的变量都处于同一条缓存行。两个线程就会轮番发送 RFO 消息，占得此缓存行的拥有权。当 core1 取得了拥有权开始更新 X，则 core2 对应的缓存行需要设为 I 状态。当 core2 取得了拥有权开始更新 Y，则 core1 对应的缓存行需要设为 I 状态(失效态)。轮番夺取拥有权不但带来大量的 RFO 消息，而且如果某个线程需要读此行数据时，L1 和 L2 缓存上都是失效数据，只有 L3 缓存上是同步好的数据。读 L3 的数据非常影响性能。更坏的情况是跨槽读取，L3 都要 miss，只能从内存上加载。

表面上 X 和 Y 都是被独立线程操作的，而且两操作之间也没有任何关系。只不过它们共享了一个缓存行，但所有竞争冲突都是来源于共享。

### Cache Line伪共享处理方案

处理伪共享的两种方式：

增大数组元素的间隔使得不同线程存取的元素位于不同的cache line上。典型的空间换时间。（Linux cache机制与之相关）
在每个线程中创建全局数组各个元素的本地拷贝，然后结束后再写回全局数组。
在Java类中，最优化的设计是考虑清楚哪些变量是不变的，哪些是经常变化的，哪些变化是完全相互独立的，哪些属性一起变化。举个例子：

```java
public class Data{
    long modifyTime;
    boolean flag;
    long createTime;
    char key;
    int value;
}
```

假如业务场景中，上述的类满足以下几个特点：

1. 当value变量改变时，modifyTime肯定会改变
2. createTime变量和key变量在创建后，就不会再变化。
3. flag也经常会变化，不过与modifyTime和value变量毫无关联。

当上面的对象需要由多个线程同时的访问时，从Cache角度来说，就会有一些有趣的问题。当我们没有加任何措施时，Data对象所有的变量极有可能被加载在L1缓存的一行Cache Line中。在高并发访问下，会出现这种问题：

<img src="http://blog-1259650185.cosbj.myqcloud.com/img/202202/14/1644769867.png" alt="8" style="zoom:75%;" />

如上图所示，每次value变更时，根据MESI协议，对象其他CPU上相关的Cache Line全部被设置为失效。其他的处理器想要访问未变化的数据(key 和 createTime)时，必须从内存中重新拉取数据，增大了数据访问的开销。

### Padding 方式

正确的方式应该将该对象属性分组，将一起变化的放在一组，与其他属性无关的属性放到一组，将不变的属性放到一组。这样当每次对象变化时，不会带动所有的属性重新加载缓存，提升了读取效率。在JDK1.8以前，我们一般是在属性间增加长整型变量来分隔每一组属性。被操作的每一组属性占的字节数加上前后填充属性所占的字节数，不小于一个cache line的字节数就可以达到要求：

```java
public class DataPadding{
    long a1,a2,a3,a4,a5,a6,a7,a8;//防止与前一个对象产生伪共享
    int value;
    long modifyTime;
    long b1,b2,b3,b4,b5,b6,b7,b8;//防止不相关变量伪共享;
    boolean flag;
    long c1,c2,c3,c4,c5,c6,c7,c8;//
    long createTime;
    char key;
    long d1,d2,d3,d4,d5,d6,d7,d8;//防止与下一个对象产生伪共享
}
```

通过填充变量，使不相关的变量分开。

### Contended注解方式

在JDK1.8中，新增了一种注解@sun.misc.Contended，来使各个变量在Cache line中分隔开。注意，jvm需要添加参数-XX:-RestrictContended才能开启此功能
用时，可以在类前或属性前加上此注释：

```java
// 类前加上代表整个类的每个变量都会在单独的cache line中
@sun.misc.Contended
@SuppressWarnings("restriction")
public class ContendedData {
    int value;
    long modifyTime;
    boolean flag;
    long createTime;
    char key;
}
或者这种：
// 属性前加上时需要加上组标签
@SuppressWarnings("restriction")
public class ContendedGroupData {
    @sun.misc.Contended("group1")
    int value;
    @sun.misc.Contended("group1")
    long modifyTime;
    @sun.misc.Contended("group2")
    boolean flag;
    @sun.misc.Contended("group3")
    long createTime;
    @sun.misc.Contended("group3")
    char key;
}
```

采取上述措施图示：

<img src="http://blog-1259650185.cosbj.myqcloud.com/img/202202/14/1644770028.png" alt="9" style="zoom:75%;" />

### JDK1.8 ConcurrentHashMap的处理

java.util.concurrent.ConcurrentHashMap在这个如雷贯耳的Map中，有一个很基本的操作问题，在并发条件下进行++操作。因为++这个操作并不是原子的，而且在连续的Atomic中，很容易产生伪共享（false sharing）。所以在其内部有专门的数据结构来保存long型的数据:

```java

（openjdk\jdk\src\share\classes\java\util\concurrent\ConcurrentHashMap.java line:2506）：

    /* ---------------- Counter support -------------- */

    /**
     * A padded cell for distributing counts.  Adapted from LongAdder
     * and Striped64.  See their internal docs for explanation.
     */
    @sun.misc.Contended static final class CounterCell {
        volatile long value;
        CounterCell(long x) { value = x; }
    }
```

我们看到该类中，是通过@sun.misc.Contended达到防止false sharing的目的

### JDK1.8 Thread 的处理

java.lang.Thread在 Java 中，生成随机数是和线程有着关联。而且在很多情况下，多线程下产生随机数的操作是很常见的，JDK为了确保产生随机数的操作不会产生false sharing ，把产生随机数的三个相关值设为独占cache line。

```java
（openjdk\jdk\src\share\classes\java\lang\Thread.java line:2023）

    // The following three initially uninitialized fields are exclusively
    // managed by class java.util.concurrent.ThreadLocalRandom. These
    // fields are used to build the high-performance PRNGs in the
    // concurrent code, and we can not risk accidental false sharing.
    // Hence, the fields are isolated with @Contended.

    /** The current seed for a ThreadLocalRandom */
    @sun.misc.Contended("tlr")
    long threadLocalRandomSeed;

    /** Probe hash value; nonzero if threadLocalRandomSeed initialized */
    @sun.misc.Contended("tlr")
    int threadLocalRandomProbe;

    /** Secondary seed isolated from public ThreadLocalRandom sequence */
    @sun.misc.Contended("tlr")
    int threadLocalRandomSecondarySeed;

```

## Java中对Cache line经典设计

### Disruptor框架

#### 认识Disruptor

LMAX是在英国注册并受到FCA监管的外汇黄金交易所。也是欧洲第一家也是唯一一家采用多边交易设施Multilateral Trading Facility（MTF）拥有交易所牌照和经纪商牌照的欧洲顶级金融公司。LMAX的零售金融交易平台，是建立在JVM平台上，核心是一个业务逻辑处理器，它能够在一个线程里每秒处理6百万订单。业务逻辑处理器的核心就是Disruptor（注，本文Disruptor基于当前最新3.3.6版本），这是一个Java实现的并发组件，能够在无锁的情况下实现网络的Queue并发操作，它确保任何数据只由一个线程拥有以进行写访问，从而消除写争用的设计， 这种设计被称作“破坏者”，也是这样命名这个框架的。

Disruptor是一个线程内通信框架，用于线程里共享数据。与LinkedBlockingQueue类似，提供了一个高速的生产者消费者模型，广泛用于批量IO读写，在硬盘读写相关的程序中应用的十分广泛，Apache旗下的HBase、Hive、Storm等框架都有在使用Disruptor。LMAX 创建Disruptor作为可靠消息架构的一部分，并将它设计成一种在不同组件中共享数据非常快的方法。Disruptor运行大致流程入下图：

<img src="http://blog-1259650185.cosbj.myqcloud.com/img/202202/14/1644803435.png" alt="10" style="zoom:75%;" />

图中左侧（Input Disruptor部分）可以看作多生产者单消费者模式。外部多个线程作为多生产者并发请求业务逻辑处理器（Business Logic Processor），这些请求的信息经过Receiver存放在粉红色的圆环中，业务处理器则作为消费者从圆环中取得数据进行处理。右侧（Output Disruptor部分）则可看作单生产者多消费者模式。业务逻辑处理器作为单生产者，发布数据到粉红色圆环中，Publisher作为多个消费者接受业务逻辑处理器的结果。这里两处地方的数据共享都是通过那个粉红色的圆环，它就是Disruptor的核心设计RingBuffer。

**Disruptor特点**

1. 无锁机制。
2. 没有CAS操作，避免了内存屏障指令的耗时。
3. 避开了Cache line伪共享的问题，也是Disruptor部分主要关注的主题。

### Disruptor对伪共享的处理

**RingBuffer类**

RingBuffer类（即上节中粉红色的圆环）的类关系图如下：

![2](http://blog-1259650185.cosbj.myqcloud.com/img/202202/14/1644803610.png)

通过源码分析，RingBuffer的父类，RingBufferFields采用数组来实现存放线程间的共享数据。如下，entries数组。

```java
// RingBufferFields.java
private final long indexMask; // 下标掩码
private final Object[] entries; // 内部用数组来实现
protected final int bufferSize; // 数组长度
protected final Sequencer sequencer; // Single/Multi Sequencer
```

前面分析过数组比链表、树更具有缓存友好性，此处不做细表。不使用LinkedBlockingQueue队列，是基于无锁机制的考虑。详细分析可参考，并发编程网的翻译。这里我们主要分析RingBuffer的继承关系中的填充，解决缓存伪共享问题。如下：

```java
abstract class RingBufferPad
{
    protected long p1, p2, p3, p4, p5, p6, p7;
}


public final class RingBuffer<E> extends RingBufferFields<E> implements Cursored, EventSequencer<E>, EventSink<E>
{
    public static final long INITIAL_CURSOR_VALUE = Sequence.INITIAL_VALUE;
    protected long p1, p2, p3, p4, p5, p6, p7;

```

依据JVM对象继承关系中父类属性与子类属性，内存地址连续排列布局，RingBufferPad的`protected long p1, p2, p3, p4, p5, p6, p7;`作为缓存前置填充，RingBuffer中`protected long p1,p2,p3,p4,p5,p6,p7;`的作为缓存后置填充。这样任意线程访问RingBuffer时，RingBuffer放在父类RingBufferFields的属性，都是独占一行Cache line不会产生伪共享问题。如图，RingBuffer的操作字段在RingBufferFields中，使用rbf标识：

![3](http://blog-1259650185.cosbj.myqcloud.com/img/202202/14/1644803934.png)

按照一行缓存64字节计算，前后填充56字节（7个long），中间大于等于8字节的内容都能独占一行Cache line，此处rbf是大于8字节的。

#### Sequence类

Sequence类用来跟踪RingBuffer和事件处理器的增长步数，支持多个并发操作包括CAS指令和写指令。同时使用了Padding方式来实现，如下为其类结构图及Padding的类。

Sequence里在volatile long value前后放置了7个long padding，来解决伪共享的问题，源码如下，此处Value等于8字节：

```java
class LhsPadding
{
    protected long p1, p2, p3, p4, p5, p6, p7;
}

class Value extends LhsPadding
{
    protected volatile long value;
}

class RhsPadding extends Value
{
    protected long p9, p10, p11, p12, p13, p14, p15;
}
```

也许读者应该会认为这里的图示比上面RingBuffer的图示更好理解，这里的操作属性只有一个value。

#### Sequencer的实现

在RingBuffer构造函数里面存在一个Sequencer接口，用来遍历数据，在生产者和消费者之间传递数据。Sequencer有两个实现类，单生产者模式的实现SingleProducerSequencer与多生产者模式的实现MultiProducerSequencer。

单生产者是在Cache line中使用padding方式实现，源码如下：

```java
abstract class SingleProducerSequencerPad extends AbstractSequencer
{
    protected long p1, p2, p3, p4, p5, p6, p7;

    SingleProducerSequencerPad(int bufferSize, WaitStrategy waitStrategy)
    {
        super(bufferSize, waitStrategy);
    }
}

public final class SingleProducerSequencer extends SingleProducerSequencerFields
{
    protected long p1, p2, p3, p4, p5, p6, p7;

```

多生产者则是使用 sun.misc.Unsafe来实现的，源码如下：

```java
public final class MultiProducerSequencer extends AbstractSequencer
{
    private static final Unsafe UNSAFE = Util.getUnsafe();
    private static final long BASE = UNSAFE.arrayBaseOffset(int[].class);
    private static final long SCALE = UNSAFE.arrayIndexScale(int[].class);

    private final Sequence gatingSequenceCache = new Sequence(Sequencer.INITIAL_CURSOR_VALUE);
```

## 总结与使用示例

可见padding方式在Disruptor中是处理伪共享常见的方式，JDK1.8的@Contended很好的解决了这个问题，不知道Disruptor后面的版本是否会考虑使用它。

Disruptor使用示例代码[参考地址](https://github.com/EasonFeng5870/disruptor_demo)。

## 参考

[Java专家系列：CPU Cache与高性能编程](https://blog.csdn.net/karamos/article/details/80126704)

[进大厂，你必须掌握的CPU缓存基础，看这篇文章就够了！](https://mp.weixin.qq.com/s/RbTtQcBWDctc-J0T6Gz06g)
