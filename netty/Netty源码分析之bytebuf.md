## ByteBuf总述

当一个客户端的接入请求接入进来的时候，Netty是如何处理，是怎么注册到多路复用器上的呢？这一节我们来一起看下客户端接入完成之后，是怎么实现读写操作的？我们自己想一下，应该就是为刚刚读取的数据分配一块缓冲区，然后把channel中的信息写入到缓冲区中，然后传入到各个handler链上，分别进行处理。那Netty是怎么去分配一块缓冲区的呢？这个就涉及到了Netty的内存模型。

引入缓冲区是为了解决速度不匹配的问题，在网络通讯中，CPU处理数据的速度大大快于网络传输数据的速度，所以引入缓冲区，将网络传输的数据放入缓冲区，累积足够的数据再送给CPU处理。

### 缓冲区的使用

`ByteBuf`是一个可存储字节的缓冲区，其中的数据可提供给`ChannelHandler`处理或者将用户需要写入网络的数据存入其中，待时机成熟再实际写到网络中。由此可知，`ByteBuf`有读操作和写操作，为了便于用户使用，该缓冲区维护了两个索引：读索引和写索引。一个`ByteBuf`缓冲区示例如下：

```ruby
+-------------------+------------------+------------------+
| discardable bytes |  readable bytes  |  writable bytes  |
|                   |     (CONTENT)    |                  |
+-------------------+------------------+------------------+
|                   |                  |                  |
0      <=      readerIndex   <=   writerIndex    <=    capacity
```

可知，`ByteBuf`由三个片段构成：废弃段、可读段和可写段。其中，可读段表示缓冲区实际存储的可用数据。当用户使用`readXXX()`或者`skip()`方法时，将会增加读索引。读索引之前的数据将进入废弃段，表示该数据已被使用。此外，用户可主动使用`discardReadBytes()`清空废弃段以便得到跟多的可写空间，示意图如下：

```ruby
清空前：
    +-------------------+------------------+------------------+
    | discardable bytes |  readable bytes  |  writable bytes  |
    +-------------------+------------------+------------------+
    |                   |                  |                  |
    0      <=      readerIndex   <=   writerIndex    <=    capacity
清空后：
    +------------------+--------------------------------------+
    |  readable bytes  |    writable bytes (got more space)   |
    +------------------+--------------------------------------+
    |                  |                                      |
readerIndex (0) <= writerIndex (decreased)       <=       capacity
```

对应可写段，用户可使用`writeXXX()`方法向缓冲区写入数据，也将增加写索引。

### 读写索引的非常规使用

用户在必要时可以使用`clear()`方法清空缓冲区，此时缓冲区的写索引和读索引都将置0，但是并不清除缓冲区中的实际数据。如果需要循环使用一个缓冲区，这个方法很有必要。

此外，用户可以使用`mark()`和`reset()`标记并重置读索引和写索引。想象这样的情形：一个数据需要写到写索引为4的位置，之后的另一个数据才写0-3索引，此时可以先mark标记0索引，然后`byteBuf.writeIndex(4)`，写入第一个数据，之后reset重置，写入第二个数据。用户可根据不同的业务，合理使用这两个方法。

需要说明的一点是：用户使用`toString(Charset)`将缓冲区的字节数据转为字符串时，并不会增加读索引。另外，`toString()`只是覆盖`Object`的常规方法，仅仅表示缓冲区的常规信息，并不会转化其中的字节数据。

### ByteBuf的底层及派生

容易想到`ByteBuf`缓冲区的底层数据结构是一个**字节数组**。从操作系统的角度理解，缓冲区的区别在于字节数组是在用户空间还是内核空间。如果位于用户空间，对于Java也就是位于堆，此时可使用Java的基本数据类型`byte[]`表示，用户可使用`array()`直接取得该字节数组，使用`hasArray()`判定该缓冲区是否是用户空间缓冲区。如果位于内核空间，Java程序将不能直接进行操作，此时可委托给JDK NIO中的直接缓冲区`DirectByteBuffer`由其操作内核字节数组，用户可使用`nioBuffer()`取得直接缓冲区，使用`nioBufferCount()`判定底层是否有直接缓冲区。

用户可在已有缓冲区上创建视图即派生缓冲区，这些视图维护各自独立的写索引、读索引以及标记索引，但他们和原生缓冲区共享想用的内部字节数据。创建视图即派生缓冲区的方法有：`duplicate()`，`slice()`以及`slice(int,int)`。如果想拷贝缓冲区，也就是说期望维护特有的字节数据而不是共享字节数据，此时可使用`copy()`方法。

## ByteBuf VS ByteBuffer

也许你已经发现了`ByteBuf`和`ByteBuffer`在命名上有极大的相似性，JDK的NIO包中既然已经有字节缓冲区`ByteBuffer` 的实现，为什么Netty还要重复造轮子呢？一个很大的原因是：`ByteBuffer`对程序员并不友好。

考虑这样的需求，向缓冲区写入两个字节0x01和0x02，然后读取出这两个字节。如果使用`ByteBuffer`，代码是这样的：

```java
ByteBuffer buf = ByteBuffer.allocate(4);
buf.put((byte) 1);
buf.put((byte) 2);

buf.flip(); // 从写模式切换为读模式
System.out.println(buf.get());  // 取出0x01
System.out.println(buf.get());  // 取出0x02
```

对于熟悉Netty的`ByteBuf`的你来说，或许只是多了一行`buf.flip()`用于将缓冲区从写模式却换为读模式。但事实并不如此，注意示例中申请了4个字节的空间，此时理应可以继续写入数据。不幸的是，如果再次调用`buf.put((byte)3)`，将抛出`java.nio.BufferOverflowException`。而要正确达到该目的，需要调用`buf.clear()`清空整个缓冲区或者`buf.compact()`清除已经读过的数据。

这个操作虽然有些繁琐，但并不是不能忍受，那么继续上个例子，考虑这样取数据的操作：

```java
buf.flip();
System.out.println(buf.get(0));
System.out.println(buf.get(1));

System.out.println(buf.get());
System.out.println(buf.get());
```

通过之前的分析，聪明的你也许已经发现`get()`操作会增加读索引，那么`get(index)`操作也会增加读索引吗？答案是：**并不会**，所以这个代码示例是正确的，将输出`0 1 0 1`的结果。什么？`get()`与`get(0)`居然是两个不一样的操作，前者会增加读索引而后者并不会。是的，可以掀桌子了。此外，`get()`的方法名本身就很有迷惑性，很自然的会认为与数组的`get()`一致，但是却有一个极大的副作用：增加索引，所以合理的名字应该是：`getAndIncreasePosition`。

又引入了一个新名词`position`，事实上`ByteBuffer`中并没有读索引和写索引的说法，这两个索引被统一称为`position`。在读写模式切换时，该值将会改变，正好与事实上的读索引与写索引对应。但愿这样的说法，并没有让你觉得头晕。

如果我们使用Netty的`ByteBuf`，感觉世界清静了很多：

```java
ByteBuf buf2 = Unpooled.buffer(4);
buf2.writeByte(1);
buf2.writeByte(2);

System.out.println(buf2.readByte());
System.out.println(buf2.readByte());
buf2.writeByte(3);
buf2.writeByte(4);
```

当然，如果不幸分配到了噩梦模式，必须使用`ByteBuffer`，那么谨记这四个步骤：

1. 写入数据到`ByteBuffer。`
2. 调用`flip()`方法。
3. 从`ByteBuffer`中读取数据。
4. 调用`clear()`方法或者`compact()`方法。

## 引用计数

服务端的网络通讯应用在处理一个客户端的请求时，基本都需要创建一个缓冲区`ByteBuf`，直到将字节数据解码为POJO对象，该缓冲区才不再有用。由此可知，当面对大量客户端的并发请求时，如果能有效利用这些缓冲区而不是每次都创建，将大大提高服务端应用的性能。

或许你会有疑问：既然已经有了Java的GC自动回收不再使用的对象，为什么还需要其他的回收技术？因为：1.GC回收或者引用队列回收效率不高，难以满足高性能的需求；2.缓冲区对象还需要尽可能的重用。有鉴于此，Netty4开始引入了引用计数的特性，缓冲区的生命周期可由引用计数管理，当缓冲区不再有用时，可快速返回给对象池或者分配器用于再次分配，从而大大提高性能，进而保证请求的实时处理。

需要注意的是：引用计数并不专门服务于缓冲区`ByteBuf`。用户可根据实际需求，在其他对象之上实现引用计数接口`ReferenceCounted`。下面将详细介绍引用计数特性。

### 基本概念

引用计数有如下两个基本规则：

- 对象的初始引用计数为1
- 引用计数为0的对象不能再被使用，只能被释放

在代码中，可以使用`retain()`使引用计数增加1，使用`release()`使引用计数减少1，这两个方法都可以指定参数表示引用计数的增加值和减少值。当我们使用引用计数为0的对象时，将抛出异常`IllegalReferenceCountException`。

### 谁负责释放对象

通用的原则是：谁最后使用含有引用计数的对象，谁负责释放或销毁该对象。一般来说，有以下两种情况：

1. 一个发送组件将引用计数对象传递给另一个接收组件时，发送组件无需负责释放对象，由接收组件决定是否释放。
2. 一个消费组件消费了引用计数对象并且明确知道不再有其他组件使用该对象，那么该消费组件应该释放引用计数对象。

一个示例如下：

```java
public ByteBuf a(ByteBuf input) {
    input.writeByte(42);
    return input;
}

public ByteBuf b(ByteBuf input) {
    try {
        output = input.alloc().buffer(input.readableBytes() + 1);
        output.writeBytes(input);
        output.writeByte(42);
        return output;
    } finally {
        input.release();
    }
}

public void c(ByteBuf input) {
    System.out.println(input);
    input.release();
}

public void main() {
    ByteBuf buf = Unpooled.buffer(1);
    c(b(a(buf)));
}
```

其中`main()`作为发送组件传递buf给`a()`，`a()`也仅仅写入数据然后发送给`b()`，`b()`同时作为消费者和发送者，消费input同时生成output发送给`c()`，`c()`仅仅作为消费者，不再产生新的引用计数对象。所以，`a()`不负责释放对象；`b()`完全消费了input，所以需要释放input，生成的output发送给`c()`，所以不负责释放output；`c()`完全消费了`b()`的output，故需要释放。

### 派生缓冲区

我们已经知道通过`duplicate()`，`slice()`等等生成的派生缓冲区`ByteBuf`会共享原生缓冲区的内部存储区域。此外，派生缓冲区并没有自己独立的引用计数而需要共享原生缓冲区的引用计数。也就是说，**当我们需要将派生缓冲区传入下一个组件时，一定要注意先调用`retain()`方法**。Netty的编解码处理器中，正是使用了这样的方法，可认为是下面代码的变形：

```java
ByteBuf parent = ctx.alloc().directBuffer(512);
parent.writeBytes(...);

try {
    while (parent.isReadable(16)) {
        ByteBuf derived = parent.readSlice(16);
        derived.retain();   // 一定要先增加引用计数
        process(derived);   // 传递给下一个组件
    }
} finally {
    parent.release();   // 原生缓冲区释放
}
...

public void process(ByteBuf buf) {
    ...
    buf.release();  // 派生缓冲区释放
} 
```

另外，实现`ByteBufHolder`接口的对象与派生缓冲区有类似的地方：共享所Hold缓冲区的引用计数，所以要注意对象的释放。在Netty，这样的对象包括`DatagramPacket`，`HttpContent`和`WebSocketframe`。

### 缓冲区泄露检测

没有什么东西是十全十美的，引用计数也不例外，虽然它大大提高了`ByteBuf`的使用效率，但也引入了一个新的问题：引用计数对象的内存泄露。由于JVM并没有意识到Netty实现的引用计数对象，它仍会将这些引用计数对象当做常规对象处理，也就意味着，当不为0的引用计数对象变得不可达时仍然会被GC自动回收。一旦被GC回收，引用计数对象将不再返回给创建它的对象池，这样便会造成内存泄露。

为了便于用户发现内存泄露，Netty提供了相应的检测机制并定义了四个检测级别：

为了便于用户发现内存泄露，Netty提供了相应的检测机制并定义了四个检测级别：

1. `DISABLED` 完全关闭内存泄露检测，并不建议
2. `SIMPLE` 以1%的抽样率检测是否泄露，默认级别
3. `ADVANCED` 抽样率同`SIMPLE`，但显示详细的泄露报告
4. `PARANOID` 抽样率为100%，显示报告信息同`ADVANCED`

有以下两种方法，可以更改泄露检测的级别：

1. 使用JVM参数`-Dio.netty.leakDetectionLevel`:	

   ```java
   java -Dio.netty.leakDetectionLevel=advanced ...
   ```

2. 直接使用代码

   ```java
   ResourceLeakDetector.setLevel(ResourceLeakDetector.Level.ADVANCED);
   ```

**最佳实践**

- 单元测试和集成测试使用`PARANOID`级别
- 使用`SIMPLE`级别运行足够长的时间以确定没有内存泄露，然后再将应用部署到集群
- 如果发现有内存泄露，调到`ADVANCED`级别以提供寻找泄露的线索信息
- 不要将有内存泄露的应用部署到整个集群

此外，如果在单元测试中创建一个缓冲区，很容易忘了释放。这会产生一个内存泄露的警告，但并不意味着应用中有内存泄露。为了减少在单元测试代码中充斥大量的`try-finally`代码块用于释放缓冲区，Netty提供了一个通用方法`ReferenceCountUtil.releaseLater()`，当测试线程结束时，将会自动释放缓冲区，使用示例如下：

```java
import static io.netty.util.ReferenceCountUtil.*;

@Test
public void testSomething() throws Exception {
    ByteBuf buf = releaseLater(Unpooled.directBuffer(512));
    ...
}
```

## ByteBuf源码分析

### 类图

ByteBuf的子类实现非常多，其中关键的实现类如下：

<img src="http://blog-1259650185.cosbj.myqcloud.com/img/202112/14/1639411555.png" alt="ByteBuf类图" style="zoom:67%;" />

可以使用两种方式对ByteBuf进行分类：按底层实现方式和按是否使用对象池。

- **按底层实现**
  - HeapByteBuf：
     HeapByteBuf的底层实现为Java堆内的字节数组。堆缓冲区与普通堆对象类似，位于JVM堆内存区，可由GC回收，其申请和释放效率较高。常规Java程序使用建议使用该缓冲区。
  - DirectByteBuf：
     DirectByteBuf的底层实现为操作系统内核空间的字节数组。直接缓冲区的字节数组位于JVM堆外的NATIVE堆，由操作系统管理申请和释放，而DirectByteBuf的引用由JVM管理。直接缓冲区由操作系统管理，一方面，申请和释放效率都低于堆缓冲区，另一方面，却可以大大提高IO效率。由于进行IO操作时，常规下用户空间的数据（Java即堆缓冲区）需要拷贝到内核空间（直接缓冲区），然后内核空间写到网络SOCKET或者文件中。如果在用户空间取得直接缓冲区，可直接向内核空间写数据，减少了一次拷贝，可大大提高IO效率，这也是常说的零拷贝。
  - CompositeByteBuf：
     CompositeByteBuf，顾名思义，有以上两种方式组合实现。这也是一种零拷贝技术，想象将两个缓冲区合并为一个的场景，一般情况下，需要将后一个缓冲区的数据拷贝到前一个缓冲区；而使用组合缓冲区则可以直接保存两个缓冲区，因为其内部实现组合两个缓冲区并保证用户如同操作一个普通缓冲区一样操作该组合缓冲区，从而减少拷贝操作。

- **按是否使用对象池**
  - UnpooledByteBuf：
    UnpooledByteBuf为不使用对象池的缓冲区，不需要创建大量缓冲区对象时建议使用该类缓冲区。
  - PooledByteBuf
     PooledByteBuf为对象池缓冲区，当对象释放后会归还给对象池，所以可循环使用。当需要大量且频繁创建缓冲区时，建议使用该类缓冲区。Netty4.1默认使用对象池缓冲区，4.0默认使用非对象池缓冲区。

### 关键类分析

#### ByteBuf

`ByteBuf`被定义为抽象类，但其中并未实现任何方法，故可看做一个接口，该接口扩展了`ReferenceCounted`实现引用计数。该类最重要的方法如下：

```java
// ByteBuf.java
int getInt(int index);
ByteBuf setInt(int index, int value);
int readInt();
ByteBuf writeInt(int value);
```

这些方法从缓冲区取得或设置一个4字节整数，区别在于`getInt()`和`setInt()`并**不会改变索引**，`readInt()`和`writeInt()`分别会**将读索引和写索引增加4**，因为int占4个字节。该类方法有大量同类，可操作布尔数`Boolean`，字节`Byte`，字符`Char`，2字节短整数`Short`，3字节整数`Medium`，4字节整数`Int`，8字节长整数`Long`，4字节单精度浮点数`Float`，8字节双精度浮点数`Double`以及字节数组`ByteArray`。

该类的一些方法遵循这样一个准则：空参数的方法类似常规getter方法，带参数的方法类似常规setter方法。比如`capacity()`表示缓冲区当前容量，`capacity(int newCapacity)`表示设置新的缓冲区容量。在此列出这些方法的带参数形式：

```java
// ByteBuf.java
ByteBuf capacity(int newCapacity); // 设置缓冲区容量
ByteBuf order(ByteOrder endianness); // 设置缓冲区字节序
ByteBuf readerIndex(int readerIndex); // 设置缓冲区读索引
ByteBuf writerIndex(int writerIndex); // 设置缓冲区写索引
```

上述后两个方法，可操作读写索引，除此之外，还有以下方法可以操作读写索引：

```java
// ByteBuf.java
ByteBuf setIndex(int readerIndex, int writerIndex); // 设置读写索引
ByteBuf markReaderIndex();  // 标记读索引，写索引可类比
ByteBuf resetReaderIndex(); // 重置为标记的读索引
ByteBuf skipBytes(int length); // 略过指定字节（增加读索引）
ByteBuf clear(); // 读写索引都置0
```

缓冲区可写可读性判断，以可读性为例：

```java
// ByteBuf.java
int readableBytes(); // 可读的字节数
boolean isReadable(); // 是否可读
boolean isReadable(int size); // 指定的字节数是否可读
```

堆缓冲区和直接缓冲区的判断，有以下方法：

```java
// ByteBuf.java
boolean hasArray(); // 判断底层实现是否为字节数组
byte[] array(); // 返回底层实现的字节数组
int arrayOffset();  // 底层字节数组的首字节位置

boolean isDirect(); // 判断底层实现是否为直接ByteBuffer
boolean hasMemoryAddress(); // 底层直接ByteBuffer是否有内存地址
long memoryAddress(); // 直接ByteBuffer的首字节内存地址
```

这一组方法主要用于区分缓冲区的底层实现，前3个方法用于对底层实现为字节数组的堆缓冲区进行操作，后三个方法用于底层为NIO Direct ByteBuffer的缓冲区进行操作。

使用缓冲区时，经常需要在缓冲区查找某个特定字节或对某个字节进行操作，为此ByteBuf提供了一系列方法：

```java
// ByteBuf.java
// 首个特定字节的绝对位置
int indexOf(int fromIndex, int toIndex, byte value);
// 首个特定字节的相对位置，相对读索引
int bytesBefore(byte value);
int bytesBefore(int length, byte value);
int bytesBefore(int index, int length, byte value);

// processor返回false时的首个位置
int forEachByte(ByteBufProcessor processor);
int forEachByte(int index, int length, ByteBufProcessor processor);
int forEachByteDesc(ByteBufProcessor processor);
int forEachByteDesc(int index, int length, ByteBufProcessor processor);
```

接口`ByteBufProcessor`的`process(byte)`方法定义的不符合常规，返回true时表示希望继续处理下一个字节，返回false时表示希望停止处理返回当前位置。由此，当我们希望查找到换行符时，代码如下：

```java
public boolean process(byte value) throws Exception {
    return value != '\r' && value != '\n';
}
```

这正是Netty默认实现的一个ByteBufProcessor FIND_CRLF，可见当我们期望查找换行符时，process的代码却要表达非换行符，此处设计不太合理，不人性化。作为折中，`ByteBufProcessor`中提供了大量默认的处理器，可满足大量场景的需求。如果确有必要实现自己的处理器，一定注意实现方法需要反义。

复制或截取缓冲区也是一个频繁操作，ByteBuf提供了以下方法：

```java
// ByteBuf.java   
ByteBuf copy();
ByteBuf copy(int index, int length);
ByteBuf slice();
ByteBuf slice(int index, int length);
ByteBuf duplicate();
```

其中**`copy()`方法生成的ByteBuf完全独立于原ByteBuf**，而**`slice()`和`duplicate()`方法生成的ByteBuf与原ByteBuf共享相同的底层实现**，只是各自维护独立的索引和标记，使用这两个方法时，特别需要注意结合使用场景确定是否调用`retain()`增加引用计数。

有关Java NIO中的ByteBuffer的方法：

```java
// ByteBuf.java
int nioBufferCount();
ByteBuffer nioBuffer();
ByteBuffer nioBuffer(int index, int length);
ByteBuffer internalNioBuffer(int index, int length);
ByteBuffer[] nioBuffers();
ByteBuffer[] nioBuffers(int index, int length);
```

这些方法在进行IO的写操作时会大量使用，一般情况下，用户很少调用这些方法。

最后需要注意的是`toString()`方法：

```java
// ByteBuf.java
String toString();
String toString(Charset charset);
String toString(int index, int length, Charset charset);
```

不带参数的`toString()`方法是Java中Object的标准重载方法，返回ByteBuf的Java描述；带参数的方法则返回使用指定编码集编码的缓冲区字节数据的字符形式。

不再列出`ByteBuf`继承自`ReferenceCounted`接口的方法，可见`ByteBuf`是一个含有过多的抽象方法的抽象类（接口）。此处，Netty使用了聚合的设计方法，将`ByteBuf`的子类可能使用的方法都集中到了基类。再加上使用工厂模式生成`ByteBuf`，给用户程序员带来了极大便利：完全不用接触具体的子类，只需要使用顶层接口进行操作。

了解了`ByteBuf`的所有方法，那么我们逐个击破，继续分析`AbstractByteBuf`。

#### AbstractByteBuf

抽象基类AbstractByteBuf中定义了ByteBuf的通用操作，比如读写索引以及标记索引的维护、容量扩增以及废弃字节丢弃等等。首先看其中的私有变量：

```java
// AbstractByteBuf.java
int readerIndex; // 读索引
int writerIndex; // 写索引
private int markedReaderIndex; // 标记读索引
private int markedWriterIndex; // 标记写索引

private int maxCapacity; // 最大容量
```

与变量相关的setter和getter方法不再分析，分析第一个关键方法：计算容量扩增的方法`calculateNewCapacity(minNewCapacity)`，其中参数表示扩增所需的最小容量：

```java
// AbstractByteBufAllocator.java
@Override
public int calculateNewCapacity(int minNewCapacity, int maxCapacity) {
    checkPositiveOrZero(minNewCapacity, "minNewCapacity");
    if (minNewCapacity > maxCapacity) {
        throw new IllegalArgumentException(String.format(
                "minNewCapacity: %d (expected: not greater than maxCapacity(%d)",
                minNewCapacity, maxCapacity));
    }
    final int threshold = CALCULATE_THRESHOLD; // 4 MiB page，4MB的阈值

    if (minNewCapacity == threshold) {
        return threshold;
    }

    // If over threshold, do not double but just increase by threshold.
    if (minNewCapacity > threshold) { // 所需的最小容量超过阈值4MB，每次增加4MB
        int newCapacity = minNewCapacity / threshold * threshold;
        if (newCapacity > maxCapacity - threshold) {
            newCapacity = maxCapacity; // 超过最大容量不再扩增
        } else {
            newCapacity += threshold; // 增加4MB
        }
        return newCapacity;
    }
    // 此时所需的最小容量小于阈值4MB，容量翻倍
    // 64 <= newCapacity is a power of 2 <= threshold
    final int newCapacity = MathUtil.findNextPositivePowerOfTwo(Math.max(minNewCapacity, 64));
    return Math.min(newCapacity, maxCapacity);
}
```

可见ByteBuf的最小容量为64B，当所需的扩容量在64B和4MB之间时，翻倍扩容；超过4MB之后，则每次扩容增加4MB，且最终容量（小于maxCapacity时）为4MB的最小整数倍。容量扩增的具体实现与ByteBuf的底层实现紧密相关，最终实现的容量扩增方法`capacity(newCapacity)`由底层实现。

接着分析丢弃已读字节方法`discardReadBytes()`：

```java
// AbstractByteBuf.java
@Override
public ByteBuf discardReadBytes() {
    if (readerIndex == 0) {
        ensureAccessible();
        return this;
    }

    if (readerIndex != writerIndex) {
        setBytes(0, this, readerIndex, writerIndex - readerIndex); // 将readerIndex之后的数据移动到从0开始
        writerIndex -= readerIndex; // 写索引减少readerIndex
        adjustMarkers(readerIndex); // 标记索引对应调整
        readerIndex = 0; // 读索引置0
    } else {
        ensureAccessible(); // 读写索引相同时等同于clear操作
        adjustMarkers(readerIndex);
        writerIndex = readerIndex = 0;
    }
    return this;
}
```

只需注意其中的`setBytes()`，从一个源数据ByteBuf中复制数据到ByteBuf中，在本例中数据源ByteBuf就是它本身，所以是将readerIndex之后的数据移动到索引0开始，也就是丢弃readerIndex之前的数据。`adjustMarkers()`重新调节标记索引，方法实现简单，不再进行细节分析。需要注意的是：读写索引不同时，频繁调用`discardReadBytes()`将导致数据的频繁前移，使性能损失。由此，提供了另一个方法`discardSomeReadBytes()`，当读索引超过容量的一半时，才会进行数据前移，核心实现如下：

```java
// AbstractByteBuf.java
if (readerIndex >= capacity() >>> 1) {
    setBytes(0, this, readerIndex, writerIndex - readerIndex);
    writerIndex -= readerIndex;
    adjustMarkers(readerIndex);
    readerIndex = 0;
}
```

当然，如果并不想丢弃字节，只期望读索引前移，可使用方法`skipBytes()`:

```java
// AbstractByteBuf.java
public ByteBuf skipBytes(int length) {
    checkReadableBytes(length);
    readerIndex += length;
    return this;
}
```

接下来以`getInt()`和`readInt()`为例，分析常用的数据获取方法。

```java
// AbstractByteBuf.java
public ByteBuf setInt(int index, int value) {
    checkIndex(index, 4);
    _setInt(index, value);
    return this;
}

protected abstract void _setInt(int index, int value);

public ByteBuf writeInt(int value) {
    ensureAccessible();
    ensureWritable0(4);
    _setInt(writerIndex, value);
    writerIndex += 4;
    return this;
}
```

此外，在`AbstractByteBuf`中实现了`ByteBuf`中很多和索引相关的无参方法，比如`copy()`:

```java
// AbstractByteBuf.java
public ByteBuf copy() {
    return copy(readerIndex, readableBytes());
}
```

具体实现只对无参方法设定默认索引，然后委托给有参方法由子类实现。

最后再分析一下检索字节的方法，比如`indexOf()`、`bytesBefore()`、`forEachByte()`等，其中的实现最后都委托给`forEachByte()`，核心代码如下：

```java
// AbstractByteBuf.java
private int forEachByteAsc0(int start, int end, ByteBufProcessor processor) throws Exception {
    for (; start < end; ++start) {
        if (!processor.process(_getByte(start))) {
            return start;
        }
    }

    return -1;
}
```

原理也很简单，从头开始使用`_getByte()`取出每个字节进行比较。if语句中的逻辑非!符号取反，这个设计并不好，容易让人产生误解。比如，`indexOf()`查找一个字节的`ByteBufProcessor`实现如下：

```java
private static class IndexOfProcessor implements ByteBufProcessor {
    private final byte byteToFind;

    public IndexOfProcessor(byte byteToFind) {
        this.byteToFind = byteToFind;
    }

    @Override
    public boolean process(byte value) {
        // 期望找到某个字节，但此处需要使用!=
        return value != byteToFind;
    }
}
```

此外的其他方法不再分析，接着分析与引用计数相关的`AbstractReferenceCountedByteBuf`。

#### AbstractReferenceCountedByteBuf

从名字可以推断，该抽象类实现引用计数相关的功能。引用计数的功能简单理解就是：当需要使用一个对象时，计数加1；不再使用时，计数减1。如何实现计数功能呢？考虑到引用计数的多线程使用情形，一般情况下，我们会选择简单的`AtomicInteger`作为计数，使用时加1，释放时减1。这样的实现是没有问题的，但Netty选择了另一种内存效率更高的实现方式：`volatile` + `FieldUpdater`。

首先看使用的成员变量：

```java
// AbstractReferenceCountedByteBuf.java
private static final long REFCNT_FIELD_OFFSET =
        ReferenceCountUpdater.getUnsafeOffset(AbstractReferenceCountedByteBuf.class, "refCnt");
private static final AtomicIntegerFieldUpdater<AbstractReferenceCountedByteBuf> AIF_UPDATER =
        AtomicIntegerFieldUpdater.newUpdater(AbstractReferenceCountedByteBuf.class, "refCnt");

private static final ReferenceCountUpdater<AbstractReferenceCountedByteBuf> updater =
        new ReferenceCountUpdater<AbstractReferenceCountedByteBuf>() {
    @Override
    protected AtomicIntegerFieldUpdater<AbstractReferenceCountedByteBuf> updater() {
        return AIF_UPDATER;
    }
    @Override
    protected long unsafeOffset() {
        return REFCNT_FIELD_OFFSET;
    }
};

private volatile int refCnt = updater.initialValue(); // 实际的引用计数值，默认为2
```

增加引用计数的方法：

```java
// AbstractReferenceCountedByteBuf.java
@Override
public ByteBuf retain() {
    return updater.retain(this);
}

@Override
public ByteBuf retain(int increment) {
    return updater.retain(this, increment);
}

// ReferenceCountUpdater.java
public final T retain(T instance) {
    return retain0(instance, 1, 2);
}

private T retain0(T instance, final int increment, final int rawIncrement) {
    int oldRef = updater().getAndAdd(instance, rawIncrement);
    if (oldRef != 2 && oldRef != 4 && (oldRef & 1) != 0) {
        throw new IllegalReferenceCountException(0, increment);
    }
    // don't pass 0!
    if ((oldRef <= 0 && oldRef + rawIncrement >= 0)
            || (oldRef >= 0 && oldRef + rawIncrement < oldRef)) {
        // overflow case
        updater().getAndAdd(instance, -rawIncrement);
        throw new IllegalReferenceCountException(realRefCnt(oldRef), increment);
    }
    return instance;
}
```

实现较为简单，只需注意`updater().getAndAdd(instance, -rawIncrement)`。这是一个原子操作。

减少引用计数的方法也类似：

```java
// AbstractReferenceCountedByteBuf.java
@Override
public boolean release() {
    return handleRelease(updater.release(this));
}

@Override
public boolean release(int decrement) {
    return handleRelease(updater.release(this, decrement));
}

// ReferenceCountUpdater.java
public final boolean release(T instance) {
    int rawCnt = nonVolatileRawCnt(instance);
    return rawCnt == 2 ? tryFinalRelease0(instance, 2) || retryRelease0(instance, 1)
            : nonFinalRelease0(instance, 1, rawCnt, toLiveRealRefCnt(rawCnt, 1));
}

public final boolean release(T instance, int decrement) {
    int rawCnt = nonVolatileRawCnt(instance);
    int realCnt = toLiveRealRefCnt(rawCnt, checkPositive(decrement, "decrement"));
    return decrement == realCnt ? tryFinalRelease0(instance, rawCnt) || retryRelease0(instance, decrement)
            : nonFinalRelease0(instance, decrement, rawCnt, realCnt);
}

private int nonVolatileRawCnt(T instance) {
    final long offset = unsafeOffset();
    return offset != -1 ? PlatformDependent.getInt(instance, offset) : updater().get(instance);
}
```

至此，`ByteBuf`的抽象层代码分析完毕。稍作休整，进入正题：ByteBuf的具体实现子类。

#### UnpooledHeapByteBuf

该Bytebuf的底层为不使用对象池技术的Java堆字节数组，首先看其中的成员变量：

```java
// UnpooledHeapByteBuf.java
private final ByteBufAllocator alloc;   // 分配器
byte[] array;   // 底层字节数组
private ByteBuffer tmpNioBuf; // NIO的ByteBuffer形式
```

只需要着重关注`array`变量，它是位于Java堆的字节数组。

再看一个构造方法（忽略其中的参数检查）：

```java
// UnpooledHeapByteBuf.java
public UnpooledHeapByteBuf(ByteBufAllocator alloc, int initialCapacity, int maxCapacity) {
    super(maxCapacity);

    if (initialCapacity > maxCapacity) {
        throw new IllegalArgumentException(String.format(
                "initialCapacity(%d) > maxCapacity(%d)", initialCapacity, maxCapacity));
    }

    this.alloc = checkNotNull(alloc, "alloc");
    setArray(allocateArray(initialCapacity));
    setIndex(0, 0);
}

protected byte[] allocateArray(int initialCapacity) {
    return new byte[initialCapacity];
}

private void setArray(byte[] initialArray) {
    array = initialArray;
    tmpNioBuf = null;
}

@Override
public ByteBuf setIndex(int readerIndex, int writerIndex) {
    if (checkBounds) {
        checkIndexBounds(readerIndex, writerIndex, capacity());
    }
    setIndex0(readerIndex, writerIndex);
    return this;
}
```

实现也很简单，只需关注`allocateArray()`方法，分配一个数组；对应地，有一个`freeArray()`方法，释放一个数组，代码如下：

```java
// UnpooledHeapByteBuf.java
protected void freeArray(byte[] array) {
    // NOOP
}
```

由于堆内的字节数组会被GC自动回收，所以不需要具体实现代码。此外，在引用计数的分析中，当引用计数释放的时候需要调用`deallocate()`方法释放该ByteBuf，实现如下：

```cpp
// UnpooledHeapByteBuf.java
protected void deallocate() {
    freeArray(array);
    array = null;
}
```

同理，使用GC自动回收，而设置`array=null`可以帮助GC回收。

ByteBuf中有关于判断底层实现的方法，具体实现也很简单：

```java
// 默认的字节序：大端模式
public ByteOrder order() { return ByteOrder.BIG_ENDIAN; }

// 底层是否有Java堆字节数组
public boolean hasArray() { return true; }

// 底层数组的偏移量
public int arrayOffset() { return 0; }

// 是否直接数组
public boolean isDirect() { return false; }

// 是否含有os底层的数组起始地址
public boolean hasMemoryAddress() { return false; }
```

接下来，看重要的设置容量方法`capacity(int newCapacity)`：

```java
// UnpooledHeapByteBuf.java
@Override
public ByteBuf capacity(int newCapacity) {
    checkNewCapacity(newCapacity);
    byte[] oldArray = array;
    int oldCapacity = oldArray.length;
    if (newCapacity == oldCapacity) { // 容量相等时不做处理
        return this;
    }

    int bytesToCopy;
    if (newCapacity > oldCapacity) {  // 容量扩增
        bytesToCopy = oldCapacity;
    } else {
        trimIndicesToCapacity(newCapacity); // 容量缩减
        bytesToCopy = newCapacity;
    }
    byte[] newArray = allocateArray(newCapacity); // 申请数组
    System.arraycopy(oldArray, 0, newArray, 0, bytesToCopy); // 将老数组的字节复制到新数组
    setArray(newArray);
    freeArray(oldArray);
    return this;
}

protected final void trimIndicesToCapacity(int newCapacity) {
    if (writerIndex() > newCapacity) {
        setIndex0(Math.min(readerIndex(), newCapacity), newCapacity);
    }
}
```

设置容量分为两种情况：容量扩增和容量缩减。实现都是将老数据复制到新的字节数组中，有必要的话，调整读写索引位置。

之前分析过`getXXX()`和`readXXX()`的核心实现是`_getXXX(index)`方法，以`_getInt(index)`为例进行分析，代码如下：

```java
// UnpooledHeapByteBuf.java
protected int _getInt(int index) {
    return HeapByteBufUtil.getInt(array, index);
}

// HeapByteBufUtil.java
static int getInt(byte[] memory, int index) {
    return  (memory[index]     & 0xff) << 24 |
            (memory[index + 1] & 0xff) << 16 |
            (memory[index + 2] & 0xff) <<  8 |
            memory[index + 3] & 0xff;
}
```

将字节数组中指定索引位置处的4个字节按照大端模式通过移位组装为一个整数。同理，可推断`_setInt(index)`方法将一个整数的4个字节通过移位填充到字节数组的指定位置，确实如此，核心实现如下：

```java
// HeapByteBufUtil.java
static void setInt(byte[] memory, int index, int value) {
    memory[index]     = (byte) (value >>> 24);
    memory[index + 1] = (byte) (value >>> 16);
    memory[index + 2] = (byte) (value >>> 8);
    memory[index + 3] = (byte) value;
}
```

可以派生新的ByteBuf的方法中，`slice()`和`duplicate()`共享底层实现，在本类中，就是共享`array`变量，但各自维护独立索引，而`copy()`方法有自己独立的底层字节数组，通过将数据复制到一个新的字节数组实现，代码如下：

```csharp
// UnpooledHeapByteBuf.java
@Override
public ByteBuf copy(int index, int length) {
    checkIndex(index, length);
    return alloc().heapBuffer(length, maxCapacity()).writeBytes(array, index, length);
}
```

虽然JDK自带的`ByteBuffer`有各种缺憾，但在进行IO时，不得不使用原生的`ByteBuffer`，所以Netty的`ByteBuf`也提供方法转化，实现如下：

```java
// UnpooledHeapByteBuf.java
@Override
public ByteBuffer internalNioBuffer(int index, int length) {
    checkIndex(index, length);
    return (ByteBuffer) internalNioBuffer().clear().position(index).limit(index + length);
}

private ByteBuffer internalNioBuffer() {
    ByteBuffer tmpNioBuf = this.tmpNioBuf;
    if (tmpNioBuf == null) {
        this.tmpNioBuf = tmpNioBuf = ByteBuffer.wrap(array);
    }
    return tmpNioBuf;
}
```

方法将该类转化为JDK的`HeapByteBuffer`，可见也是一个堆缓冲区。`clear().position(index).limit(index + length)`的使用是防止原生`ByteBuffer`的读写模式切换造成的错误。

至此，`UnpooledHeapByteBuf`的实现分析完毕，可见并没有想象中的困难，再接再厉，分析`UnpooledDirectByteBuf`。

#### UnpooledDirectByteBuf

Netty的`UnpooledDirectByteBuf`在NIO的`DirectByteBuf`上采用组合的方式进行了封装，屏蔽了对程序员不友好的地方，并使其符合Netty的`ByteBuf`体系。使用与`UnpooledHeapByteBuf`相同的顺序进行分析，首先看成员变量：

```java
private final ByteBufAllocator alloc;   // 分配器

private ByteBuffer buffer;  // 底层NIO直接ByteBuffer
private ByteBuffer tmpNioBuf; // 用于IO操作的ByteBuffer
private int capacity; // ByteBuf的容量
private boolean doNotFree; // 释放标记
```

做一个简介，`buffer`表示底层的直接ByteBuffer；`tmpNioBuf`常用来进行IO操作，实现实质是`buffer.duplicate()`即与`buffer`共享底层数据结构；`capacity`表示缓冲区容量，即字节数；`doNotFree`是一个标记，表示是否需要释放`buffer`的底层内存。

接着分析构造方法：

```java
// UnpooledDirectByteBuf.java
public UnpooledDirectByteBuf(ByteBufAllocator alloc, int initialCapacity, int maxCapacity) {
    super(maxCapacity);
    ObjectUtil.checkNotNull(alloc, "alloc");
    checkPositiveOrZero(initialCapacity, "initialCapacity");
    checkPositiveOrZero(maxCapacity, "maxCapacity");
    if (initialCapacity > maxCapacity) {
        throw new IllegalArgumentException(String.format(
                "initialCapacity(%d) > maxCapacity(%d)", initialCapacity, maxCapacity));
    }

    this.alloc = alloc;
    // allocateDirect分配堆外内存
    setByteBuffer(allocateDirect(initialCapacity), false);
}

protected ByteBuffer allocateDirect(int initialCapacity) {
    // 此处调用JDK的allocateDirect来分配堆外内存
    return ByteBuffer.allocateDirect(initialCapacity);
}

void setByteBuffer(ByteBuffer buffer, boolean tryFree) {
    if (tryFree) {
        ByteBuffer oldBuffer = this.buffer;
        if (oldBuffer != null) {
            if (doNotFree) {
                doNotFree = false;
            } else {
                freeDirect(oldBuffer);
            }
        }
    }

    this.buffer = buffer;
    tmpNioBuf = null;
    capacity = buffer.remaining();
}
```

由于`setByteBuffer(buffer)`中含有`doNotFree`变量使得理解稍微困难，仔细分析，当`doNotFree`为true时，调用后置为false，而为false时都需要`freeDirect(oldBuffer)`。由此可知，`doNotFree`表示不需要释放旧的Buffer。另外从代码可以看出：不需要释放旧的Buffer只有一种情况，这种情况便是Buffer作为构造方法的参数时，代码如下：

```java
// UnpooledDirectByteBuf.java
protected UnpooledDirectByteBuf(ByteBufAllocator alloc, ByteBuffer initialBuffer, int maxCapacity) {
    this(alloc, initialBuffer, maxCapacity, false, true);
}

UnpooledDirectByteBuf(ByteBufAllocator alloc, ByteBuffer initialBuffer,
        int maxCapacity, boolean doFree, boolean slice) {
    super(maxCapacity);
    ObjectUtil.checkNotNull(alloc, "alloc");
    ObjectUtil.checkNotNull(initialBuffer, "initialBuffer");
    if (!initialBuffer.isDirect()) {
        throw new IllegalArgumentException("initialBuffer is not a direct buffer.");
    }
    if (initialBuffer.isReadOnly()) {
        throw new IllegalArgumentException("initialBuffer is a read-only buffer.");
    }

    int initialCapacity = initialBuffer.remaining();
    if (initialCapacity > maxCapacity) {
        throw new IllegalArgumentException(String.format(
                "initialCapacity(%d) > maxCapacity(%d)", initialCapacity, maxCapacity));
    }

    this.alloc = alloc;
    doNotFree = !doFree; // doFree为false时，doNotFree置为true，表示不需要释放原有buffer
    setByteBuffer((slice ? initialBuffer.slice() : initialBuffer).order(ByteOrder.BIG_ENDIAN), false);
    writerIndex(initialCapacity); // 此时 doNotFree已经为false
}
```

分析完，发现`doNotFree`是一个不必要的变量，除非在执行构造方法的时候，oldBuffer不为null。（目前没想到有什么情况如此）

使用`allocateDirect(initialCapacity)`分配内存时实际委托给NIO的方法，释放内存`freeDirect(buffer)`也如此，委托给了NIO中DirectByteBuffer的cleaner，代码如下：

```java
// UnpooledDirectByteBuf.java
protected void freeDirect(ByteBuffer buffer) {
    PlatformDependent.freeDirectBuffer(buffer);
}

// PlatformDependent.java
public static void freeDirectBuffer(ByteBuffer buffer) {
    CLEANER.freeDirectBuffer(buffer);
}

// CleanerJava6.java
private static void freeDirectBufferPrivileged(final ByteBuffer buffer) {
    Throwable cause = AccessController.doPrivileged(new PrivilegedAction<Throwable>() {
        @Override
        public Throwable run() {
            try {
                freeDirectBuffer0(buffer);
                return null;
            } catch (Throwable cause) {
                return cause;
            }
        }
    });
    if (cause != null) {
        PlatformDependent0.throwException(cause);
    }
}

private static void freeDirectBuffer0(ByteBuffer buffer) throws Exception {
    final Object cleaner;
    // If CLEANER_FIELD_OFFSET == -1 we need to use reflection to access the cleaner, otherwise we can use
    // sun.misc.Unsafe.
    if (CLEANER_FIELD_OFFSET == -1) {
        cleaner = CLEANER_FIELD.get(buffer);
    } else {
        cleaner = PlatformDependent0.getObject(buffer, CLEANER_FIELD_OFFSET);
    }
    if (cleaner != null) {
        CLEAN_METHOD.invoke(cleaner);
    }
}
```

实际代码根据JDK版本不同调用不同方法，上述只是其中之一，但原理相同，不再列出。

与引用计数相关的`deallocate()`方法，代码实现如下：

```kotlin
// UnpooledDirectByteBuf.java
protected void deallocate() {
    ByteBuffer buffer = this.buffer;
    if (buffer == null) {
        return;
    }

    this.buffer = null;

    if (!doNotFree) { 
        freeDirect(buffer); // 前述分析可知，doNotFree构造方法之后一直为false
    }
}
```

判断底层实现的方法则如下：

```java
// 默认的字节序：大端模式
public ByteOrder order() { return ByteOrder.BIG_ENDIAN; }

// 是否直接数组
public boolean isDirect() { return true; }

// 底层是否有JAVA堆字节数组
public boolean hasArray() { throw new UnsupportedOperationException("..."); }

// 底层数组的偏移量
public int arrayOffset() { throw new UnsupportedOperationException("..."); }

// 是否含有os底层的数组起始地址
public boolean hasMemoryAddress() { return false; }
```

设置容量的方法：

```java
// UnpooledDirectByteBuf.java
@Override
public ByteBuf capacity(int newCapacity) {
    checkNewCapacity(newCapacity);
    int oldCapacity = capacity;
    if (newCapacity == oldCapacity) {
        return this;
    }
    int bytesToCopy;
    if (newCapacity > oldCapacity) { // 容量扩增
        bytesToCopy = oldCapacity;
    } else { // 容量缩减
        trimIndicesToCapacity(newCapacity);
        bytesToCopy = newCapacity;
    }
    ByteBuffer oldBuffer = buffer;
    ByteBuffer newBuffer = allocateDirect(newCapacity);
    oldBuffer.position(0).limit(bytesToCopy);
    newBuffer.position(0).limit(bytesToCopy);
    newBuffer.put(oldBuffer).clear();
    setByteBuffer(newBuffer, true);
    return this;
}
```

与HeapByteBuf类似，容量改变时，都将oldBuffer中的数据复制到新的newBuffer中，只是在容量缩减时，需要调整读写索引。

接着看关键的`_getInt(index)`和`_setInt(index,value)`方法：

```java
// UnpooledDirectByteBuf.java
protected int _getInt(int index) {
    return buffer.getInt(index);
}

protected void _setInt(int index, int value) {
    buffer.putInt(index, value);
}
```

可见具体实现委托给了NIO原生的ByteBuffer，追踪其中的具体实现，一种情况下的实现如下：

```java
// java.nio.Bits.java
static int getIntB(long a) {
    return makeInt(_get(a    ),
                   _get(a + 1),
                   _get(a + 2),
                   _get(a + 3));
}

static private int makeInt(byte b3, byte b2, byte b1, byte b0) {
    return (((b3       ) << 24) |
            ((b2 & 0xff) << 16) |
            ((b1 & 0xff) <<  8) |
            ((b0 & 0xff)      ));
}
```

可见与Netty的`HeapByteBuf`实现一致。另一种情况是native实现，没有找到具体实现代码，如果你有兴趣可以寻找相关实现，有相关发现请告诉我。

继续看`copy()`方法：

```java
// UnpooledDirectByteBuf.java
@Override
public ByteBuf copy(int index, int length) {
    ensureAccessible();
    ByteBuffer src;
    try {
        src = (ByteBuffer) buffer.duplicate().clear().position(index).limit(index + length);
    } catch (IllegalArgumentException ignored) {
        throw new IndexOutOfBoundsException("Too many bytes to read - Need " + (index + length));
    }

    return alloc().directBuffer(length, maxCapacity()).writeBytes(src);
}
```

对原buffer使用`duplicate()`方法，从而不干扰原来buffer的索引。然后从分配器中申请一个buffer并写入原buffer的数据。

最后看`internalNioBuffer()`：

```java
// UnpooledDirectByteBuf.java
@Override
public ByteBuffer internalNioBuffer(int index, int length) {
    checkIndex(index, length);
    return (ByteBuffer) internalNioBuffer().clear().position(index).limit(index + length);
}

private ByteBuffer internalNioBuffer() {
    ByteBuffer tmpNioBuf = this.tmpNioBuf;
    if (tmpNioBuf == null) {
        this.tmpNioBuf = tmpNioBuf = buffer.duplicate();
    }
    return tmpNioBuf;
}
```

可见，与`copy()`相同，使用`duplicate()`防止干扰原buffer的索引。

至此，`UnpooledDirectByteBuf`的源码分析完毕。

#### UnsafeByteBuf

Netty还使用Java的后门类`sun.misc.Unsafe`实现了两个缓冲区`UnpooledUnsafeHeapByteBuf`和`UnpooledUnsafeDirectByteBuf`。这个强大的后门类`Unsafe`可以暴露出对象的底层地址，一般不建议使用，而性能优化狂魔Netty则顾不得这些。简单介绍一下这两个类的原理，不再对代码进行分析。

`UnpooledUnsafeHeapByteBuf`在使用`Unsafe`后，暴露出字节数组在Java堆中的地址，所以不再使用字节数组的索引即array[index]访问，转而使用baseAddress + Index的得到字节的地址，然后从该地址取得字节。`UnpooledUnsafeDirectByteBuf`也一样，暴露底层DirectByteBuffer的地址后，使用相同的Address + Index方式取得对应字节。

## 参考

[自顶向下深入分析Netty（九）--ByteBuf](https://www.jianshu.com/p/dc862ab4813d)

[自顶向下深入分析Netty（九）--引用计数](https://www.jianshu.com/p/73fff8e09fed)

[自顶向下深入分析Netty（九）--ByteBuf源码分析](https://www.jianshu.com/p/0f93834f23de)

[自顶向下深入分析Netty（九）--UnpooledByteBuf源码分析](https://www.jianshu.com/p/ae8010b06ac2)
