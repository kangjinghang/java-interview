# 初识 Netty：背景、现状与趋势

## 揭开Netty面纱

Netty由TrustinLee (韩国，Line公司）2004年开发 

- 本质：网络应用程序框架
- 实现：异步、 事件驱动
- 特性：高性能、 可维护、 快速开发
- 用途：开发服务器和客户端

<img src="https://blog-1259650185.cos.ap-beijing.myqcloud.com/img/202104/25/1619321099.png" alt="image-20210425112459822" style="zoom:50%;" />



## 为什么不用JDK NIO

### Netty做得更多

- 支持常用应用层协议；
- 解决传输问题：粘包、 半包现象；
- 支持流量整形；
- 完善的断连、Idle等异常处理等。

### Netty做得更好

- 规避JDK NIO bug
- API更友好更强大
- 隔离变化，屏蔽细节

#### 规避JDK NIO bug

<img src="https://blog-1259650185.cos.ap-beijing.myqcloud.com/img/202104/25/1619330352.png" alt="image-20210425135912592" style="zoom:50%;" />

<img src="https://blog-1259650185.cos.ap-beijing.myqcloud.com/img/202104/25/1619330382.png" alt="image-20210425135942743" style="zoom:50%;" />

<img src="https://blog-1259650185.cos.ap-beijing.myqcloud.com/img/202104/25/1619330420.png" alt="image-20210425140020515" style="zoom:50%;" />

<img src="https://blog-1259650185.cos.ap-beijing.myqcloud.com/img/202104/25/1619330441.png" alt="image-20210425140041627" style="zoom:50%;" />

#### API更友好更强大

- JDK 的 NIO 的一些API不够友好，功能薄弱，例如ByteBuffer  -> Netty's ByteBuf
- 出了 NIO 外，也提供了其他一些增强：ThreadLocal -> Netty's FastTreadLocal

#### 隔离变化，屏蔽细节

- 隔离 JDK NIO 的实现变化：nio -> nio2(aio) -> ...
- 屏蔽 JDK NIO 的实现细节



# Netty 源码：从“点”（领域知识）的角度剖析



## Netty 怎么切换三种 I/O 模式

### 什么是经典的三种 I/O 模式

生活场景：

​	当我们去饭店吃饭时：

- 食堂排队打饭模式：排队在窗口，打好才走；
- 点单、等待被叫模式：等待被叫，好了自己去端；
- 包厢模式：点单后菜直接被端上桌。

类比：

- 饭店 -> 服务器
- 饭菜-> 数据
- 饭菜好了-> 数据就绪
- 端菜 /送菜 -> 数据读取

| 模式               | IO模式             | 版本                           |
| ------------------ | ------------------ | ------------------------------ |
| 排队打饭模式       | BIO （阻塞 I/O）   | JDK1.4 之前                    |
| 点单、等待被叫模式 | NIO （非阻塞 I/O） | JDK1.4（2002 年，java.nio 包） |
| 包厢模式           | AIO（异步 I/O）    | JDK1.7 （2011 年）             |

### 阻塞与非阻塞

- 菜没好，要不要死等 -> 数据就绪前要不要等待？

- 阻塞：没有数据传过来时，读会阻塞直到有数据；缓冲区满时，写操作也会阻塞。

  非阻塞遇到这些情况，都是直接返回。

### 同步与异步

- 菜好了，谁端 -> 数据就绪后，数据操作谁完成？
- 数据就绪后需要自己去读是同步，数据就绪直接读好再回调给程序是异步。

### Netty 对三种 I/O 模式的支持

<img src="https://blog-1259650185.cos.ap-beijing.myqcloud.com/img/202104/25/1619341609.png" alt="image-20210425170649148" style="zoom: 50%;" />

### 为什么 Netty 仅支持 NIO 了？

为什么不建议（deprecate）阻塞 I/O（BIO/OIO）?

- 连接数高的情况下：阻塞 -> 耗资源、效率低

为什么删掉已经做好的 AIO 支持？

- Windows 实现成熟，但是很少用来做服务器。
- Linux 常用来做服务器，但是 AIO 实现不够成熟。
- Linux 下 AIO 相比较 NIO 的性能提升不明显 。

### 为什么 Netty 有多种 NIO 实现？

通用的 NIO 实现（Common）在 Linux 下也是使用 epoll，为什么自己单独实现？

实现得更好！

- Netty 暴露了更多的可控参数，例如：
  - JDK 的 NIO 默认实现是水平触发
  - Netty 是边缘触发（默认）和水平触发可切换
- Netty 实现的垃圾回收更少、性能更好

### NIO 一定优于 BIO 么？

- BIO 代码简单。

- 特定场景：连接数少，并发度低，BIO 性能不输 NIO。

### 源码解读 Netty 怎么切换 I/O 模式？

#### 怎么切换？

例如对于服务器开发：从 NIO 切换到 OIO

| NIO                    | OIO                    |
| ---------------------- | ---------------------- |
| NioEventLoopGroup      | OioEventLoopGroup      |
| NioServerSocketChannel | OioServerSocketChannel |

#### 原理是什么？

例如对于 ServerSocketChannel：工厂模式+泛型+反射实现

#### 为什么服务器开发并不需要切换客户端对应NioSocketChannel ？

ServerSocketChannel 负责创建对应的 SocketChannel 。所以我们只要切换 ServerSocketChannel 就够了，SocketChannel 由 ServerSocketChannel 来负责创建，我们不用手动修改。



## Netty 如何支持三种 Reactor

### 什么是 Reactor 及三种版本

生活场景：饭店规模变化

1. 一个人包揽所有：迎宾、点菜、做饭、上菜、送客等；
2. 多招几个伙计：大家一起做上面的事情；
3. 进一步分工：搞一个或者多个人专门做迎宾。

生活场景类比：

- 饭店伙计：线程
- 迎宾工作：接入连接
- 点菜：请求
- 做菜：业务处理
- 上菜：响应
- 送客：断连



1. 一个人包揽所有：迎宾、点菜、做饭、上菜、送客等 -> Reactor 单线程
2. 多招几个伙计：大家一起做上面的事情 -> Reactor 多线程模式
3. 进一步分工：搞一个或者多个人专门做迎宾 -> 主从 Reactor 多线程模式

|          BIO          |   NIO   |   AIO    |
| :-------------------: | :-----: | :------: |
| Thread-Per-Connection | Reactor | Proactor |

Reactor 是一种开发模式，模式的核心流程：

**注册感兴趣的事件** -> **扫描是否有感兴趣的事件发生** -> **事件发生后做出相应的处理**。

| Client/Server | SocketChannel/ServerSocketChannel | OP_ACCEPT | OP_CONNECT | OP_WRITE | OP_READ |
| :-----------: | :-------------------------------: | :-------: | :--------: | :------: | :-----: |
|    Client     |           SocketChannel           |           |     Y      |    Y     |    Y    |
|    Server     |        ServerSocketChannel        |     Y     |            |          |         |
|    Server     |           SocketChannel           |           |            |    Y     |    Y    |

#### Thread-Per-Connection 模式

所有的读、解码、处理、编码、写都是由一个单独的线程处理。

每个客户端的连接都要一个单出的线程。

<img src="https://blog-1259650185.cos.ap-beijing.myqcloud.com/img/202104/25/1619343946.png" alt="image-20210425174546903" style="zoom:50%;" />



#### Reactor 模式 V1：单线程

所有的连接、读、解码、处理、编码、写都是由一个线程处理（太累了）。

<img src="https://blog-1259650185.cos.ap-beijing.myqcloud.com/img/202104/25/1619344251.png" alt="image-20210425175051211" style="zoom:50%;" />

<img src="http://blog-1259650185.cosbj.myqcloud.com/img/202109/01/1630463139.png" alt="image-20210901102539912" style="zoom:50%;" />

#### Reactor 模式 V2：多线程

加一个线程池，所有的连接、读、写还是由一个线程处理，其他的3个比较耗时的操作（解码、处理、编码），交给线程池来处理，

<img src="https://blog-1259650185.cos.ap-beijing.myqcloud.com/img/202104/25/1619344446.png" alt="image-20210425175406867" style="zoom:50%;" />

#### Reactor 模式 V3：主从多线程

所有的连接（最重要的一个操作，比如迎宾）由一个线程（mainReactor）处理，读和写由另一个或几个线程（subReactor）处理。其他的3个比较耗时的操作（解码、处理、编码），还是交给线程池来处理，

<img src="http://blog-1259650185.cosbj.myqcloud.com/img/202109/01/1630463042.png" alt="image-20210901102402222" style="zoom:50%;" />



在解决了什么是Reactor模式后，我们来看看Reactor模式是由什么模块构成。图是一种比较简洁形象的表现方式，因而先上一张图来表达各个模块的名称和他们之间的关系：

![img](http://blog-1259650185.cosbj.myqcloud.com/img/202112/07/1638890967.png)

上面的图由五大角色构成，下面进行解释：

-  Handle（句柄或描述符，在Windows下称为句柄，在Linux下称为描述符）：本质上是一种资源，由操作系统提供的，该资源用于表示一个个的事件，比如说文件描述符，或是针对网络编程中的Socket描述符，事件既可以来自于外部，又可以来自于内部，外部事件比如客户端的连接请求，客户端数据的读写等等；内部事件比如操作系统产生的定时器事件，它本质上就是一个文件描述符。简单来说，Handle就是事件产生的发源地。
- Synchronous Event Demultiplexer（同步事件分离器）：它本身是一个系统调用，用于等待事件的发生（一个或多个）。调用方在调用它的时候会一直阻塞，一直阻塞到同步分离器上有事件产生，对于Linux来说，同步事件分离器指的就是常用的I/O多路复用器，比如说select、poll、epoll等，在Java NIO 领域中，同步事件分离器的组件就是Selector； 对应的阻塞方法就是select()。
- Event Hander （事件处理器）：本身由多个回调方法组成，这些回调方法构成了于应用相关的对于某个事件的反馈机制，Netty相比于Java的NIO来说，在事件处理器的这个角色上进行了一个升级，它为我们开发者指定了大量的回调方法，供我们在特定时间产生的时候实现相应的回调方法进行业务逻辑的处理。
- Concrete Event Handler（具体事件处理器）：是事件处理器的时间，本质上是我们所编写的一个个的处理器的实现
- Initiation Dispatcher （初始分发器）：实际上就是Reactor的角色，它本身定义了一些规范，这些规范用户控制事件的调度方式，同时又提供了应用事件处理器的注册、删除等设施，它本身是整个事件处理器的核心所在，会通过同步事件分离器来等待事件的发生，一旦事件发生，首先会分离出一个事件，然后调用事件处理器，最后调用相关的回调方法来处理这些事件。

### 如何在 Netty 中使用 Reactor 模式

<img src="https://blog-1259650185.cos.ap-beijing.myqcloud.com/img/202104/25/1619344916.png" alt="image-20210425180156320" style="zoom:50%;" />

### 解析 Netty 对 Reactor 模式支持的常见疑问

#### Netty 如何支持主从 Reactor 模式的？

主要看这个group中set的两个主从EventLoopGroup，其中主group主要是维护在AbstractBootstrap的成员变量中。

<img src="https://blog-1259650185.cos.ap-beijing.myqcloud.com/img/202104/25/1619347492.png" alt="image-20210425184452064" style="zoom: 33%;" />



使用，这个AbstractBootstrap在初始化点的时候将 new 出来的 channel 绑定到 parentGroup。

<img src="https://blog-1259650185.cos.ap-beijing.myqcloud.com/img/202104/25/1619347578.png" alt="image-20210425184618671" style="zoom: 33%;" />

ServerBootstrap 在 read 的时候将 channel 注册到childGroup。

<img src="https://blog-1259650185.cos.ap-beijing.myqcloud.com/img/202104/25/1619347722.png" alt="image-20210425184842413" style="zoom:33%;" />



#### 为什么说 Netty 的 main reactor 大多并不能用到一个线程组，只能线程组里面的一个？

#### Netty 给 Channel 分配 NIO event loop 的规则是什么？

就是把这么多 channel 分配给哪个 eventLoop （线程）。

主要看EventLoopGroup.register()。

````java
// NIO的实现类MultithreadEventLoopGroup
public ChannelFuture register(Channel channel) {
		return next().register(channel);
}

public EventLoop next() {
		return (EventLoop) super.next();
}
````

接下来看next()，主要是个策略模式（多种算法）

```java
@UnstableApi
interface EventExecutorChooser {

     /**
       * Returns the new {@link EventExecutor} to use.
       */
     EventExecutor next();
}
```

第一种，普通的取模。

```java
private static final class GenericEventExecutorChooser implements EventExecutorChooser {

    private final AtomicLong idx = new AtomicLong();
    private final EventExecutor[] executors;

    GenericEventExecutorChooser(EventExecutor[] executors) {
        this.executors = executors;
    }

    @Override
    public EventExecutor next() {
        // idx递增，然后对数组长度取模
        return executors[(int) Math.abs(idx.getAndIncrement() % executors.length)];
    }
}
```

第二种在2的幂次方时候，才能用，位运算。与hashMap定位 bucket 类似。

```java
private static final class PowerOfTwoEventExecutorChooser implements EventExecutorChooser {
  
    private final AtomicInteger idx = new AtomicInteger();
    private final EventExecutor[] executors;

    PowerOfTwoEventExecutorChooser(EventExecutor[] executors) {
        this.executors = executors;
    }

    @Override
    public EventExecutor next() {
        // idx 和 数组长度-1 进行与操作
        return executors[idx.getAndIncrement() & executors.length - 1];
    }
}
```



#### 通用模式的 NIO 实现多路复用器是怎么跨平台的

主要看NioEventLoopGroup。

```java
// NioEventLoopGroup
public NioEventLoopGroup(ThreadFactory threadFactory) {
    this(0, threadFactory, SelectorProvider.provider());
}

// SelectorProvider
public static SelectorProvider provider() {
    synchronized (lock) {
        if (provider != null)
            return provider;
        return AccessController.doPrivileged(
            new PrivilegedAction<SelectorProvider>() {
                public SelectorProvider run() {
                  			// 如果环境变量中进行了设置则从环境变量加载，默认为false
                        if (loadProviderFromProperty())
                            return provider;
                        // 走SPI机制，检查jar包的META-INF/services目录，默认为false
                        if (loadProviderAsService())
                            return provider;
                  		  // 走到JDK的源码，根据不同的JDK（Windows/Linux/Mac OS）创建 
                        provider = sun.nio.ch.DefaultSelectorProvider.create();
                        return provider;
                    }
                });
    }
}
```



## TCP 粘包/半包 Netty 全搞定

### 什么是粘包和半包？

发送：AB CD EF

接收：ABCDEF？  AB？CD？EF？

### 为什么 TCP 应用中会出现粘包和半包现象？

粘包的主要原因：

- 发送方每次写入数据 < 套接字缓冲区大小
- 接收方读取套接字缓冲区数据不够及时

半包的主要原因：

- 发送方写入数据 > 套接字缓冲区大小
- 发送的数据大于协议的 MTU（Maximum Transmission Unit，最大传输单元），必须拆包



换个角度看：

- 收发：一个发送可能被多次接收，多个发送可能被一次接收

- 传输：一个发送可能占用多个传输包，多个发送可能公用一个传输包



根本原因：

**TCP 是流式协议，消息无边界。**

提醒：UDP 像邮寄的包裹，虽然一次运输多个，但每个包裹都有“界限”，一个一个签收，所以无粘包、半包问题。

### 解决粘包和半包问题的几种常用方法

解决问题的根本手段：找出消息的边界：

<img src="https://blog-1259650185.cos.ap-beijing.myqcloud.com/img/202104/25/1619365362.png" alt="image-20210425234242859" style="zoom:50%;" />

### Netty 对三种常用封帧方式的支持

<img src="https://blog-1259650185.cos.ap-beijing.myqcloud.com/img/202104/25/1619365403.png" alt="image-20210425234323933" style="zoom:50%;" />

### 解读 Netty 处理粘包、半包的源码

源码解析：

主要看ByteToMessageDecoder.channelRead(ChannelHandlerContext ctx, Object msg)。

#### 解码核心工作流程？

```java
// ByteToMessageDecoder
public void channelRead(ChannelHandlerContext ctx, Object msg) throws Exception {
    if (msg instanceof ByteBuf) {
        CodecOutputList out = CodecOutputList.newInstance();
        try {
            first = cumulation == null;
            cumulation = cumulator.cumulate(ctx.alloc(),
                    // 是第一次读时，返回空的buffer，否则放到积累器中
                    first ? Unpooled.EMPTY_BUFFER : cumulation, (ByteBuf) msg);
           // 然后调用 callDecode()
            callDecode(ctx, cumulation, out);
        } catch (Exception e) {
            ...
        } finally {
					  ...
        }
    } else {
        ctx.fireChannelRead(msg);
    }
}

protected void callDecode(ChannelHandlerContext ctx, ByteBuf in, List<Object> out) {
    try {
        while (in.isReadable()) {
            int outSize = out.size();

            if (outSize > 0) {
                ...
            }

            int oldInputLength = in.readableBytes();
            // decode 中时，不能执行完handler remove 清理操作。
            // 那 decode 完之后，需要清理数据
            decodeRemovalReentryProtection(ctx, in, out);

						...
        }
    } catch (DecoderException e) {
        ...
    } 
}

final void decodeRemovalReentryProtection(ChannelHandlerContext ctx, ByteBuf in, List<Object> out)
        throws Exception {
    decodeState = STATE_CALLING_CHILD_DECODE;
    try {
        decode(ctx, in, out);
    } finally {
				...
    }
}

// 交由不同子类去实现
protected abstract void decode(ChannelHandlerContext ctx, ByteBuf in, List<Object> out) throws Exception;
```



```java
// FixedLengthFrameDecoder
protected final void decode(ChannelHandlerContext ctx, ByteBuf in, List<Object> out) throws Exception {
    Object decoded = decode(ctx, in);
    if (decoded != null) {
        out.add(decoded);
    }
}

protected Object decode(
        @SuppressWarnings("UnusedParameters") ChannelHandlerContext ctx, ByteBuf in) throws Exception {
    // 固定长度，不满足固定长度时，先不解析出数据。半包不处理，粘包只处理固定长度的
    if (in.readableBytes() < frameLength) {
        return null;
    } else {
        return in.readRetainedSlice(frameLength);
    }
}
```



#### 解码中两种数据积累器（Cumulator）的区别? 

```java
// 有两个实现
public interface Cumulator {
    ByteBuf cumulate(ByteBufAllocator alloc, ByteBuf cumulation, ByteBuf in);
}

// 通过内存复制，都放到一个ByteBuf
public static final Cumulator MERGE_CUMULATOR = new Cumulator() {
    @Override
    public ByteBuf cumulate(ByteBufAllocator alloc, ByteBuf cumulation, ByteBuf in) {
				...
        try {
            final int required = in.readableBytes();
            if (required > cumulation.maxWritableBytes() ||
                    (required > cumulation.maxFastWritableBytes() && cumulation.refCnt() > 1) ||
                    cumulation.isReadOnly()) {
                // 如果不够空间，就去扩容。先把空间搞够
                return expandCumulation(alloc, cumulation, in);
            }
            // 然后把空间追加进去就行了
            cumulation.writeBytes(in, in.readerIndex(), required);
            in.readerIndex(in.writerIndex());
            return cumulation;
        } finally {
            in.release();
        }
    }
};

// 把 ByteBuf 组合起来，避免了内存复制
public static final Cumulator COMPOSITE_CUMULATOR = new Cumulator() {
    @Override
    public ByteBuf cumulate(ByteBufAllocator alloc, ByteBuf cumulation, ByteBuf in) {
				...
        CompositeByteBuf composite = null;
        try {
            if (cumulation instanceof CompositeByteBuf && cumulation.refCnt() == 1) {
                composite = (CompositeByteBuf) cumulation;
                if (composite.writerIndex() != composite.capacity()) {
                    composite.capacity(composite.writerIndex());
                }
            } else {
                composite = alloc.compositeBuffer(Integer.MAX_VALUE).addFlattenedComponents(true, cumulation);
            }
            // 避免内存复制
            composite.addFlattenedComponents(true, in);
            in = null;
            return composite;
        } finally {
						...
        }
    }
};
```



#### 三种解码器的常用额外控制参数有哪些？

DelimiterBasedFrameDecoder：ByteBuf[] delimiters，多个分割器

FixedLengthFrameDecoder：int frameLength，桢长度

LengthFieldBasedFrameDecoder：lengthFieldOffset、lengthFieldLength、lengthAdjustment、initialBytesToStrip



## 常用的“二次”编解码方式

### 为什么需要“二次”解码？

假设我们把解决半包粘包问题的常用三种解码器叫一次解码器，那么我们在项目中，除了可选的的压缩解压缩之外，还需要一层解码，因为一次解码的结果是字节，需要和项目中所使用的对象做转化，方便使用，这层解码器可以称为“二次解码器”，相应的，对应的编码器是为了将 Java 对象转化成字节流方便存储或传输。

一次解码器：**ByteToMessageDecoder**：io.netty.buffer.ByteBuf （原始数据流）-> io.netty.buffer.ByteBuf （用户数据）

二次解码器：**MessageToMessageDecoder**：io.netty.buffer.ByteBuf （用户数据）-> Java Object

### 常用的“二次”编解码方式

- Java 序列化
- Marshaling
- XML
- JSON
- MessagePack
- Protobuf
- 其他

### 选择编解码方式的要点

- 空间：编码后占用空间，需要比较不同的数据大小情况
- 时间：编解码速度，需要比较不同的数据大小情况
- 是否追求可读性
- 多语言（Java、C、Python 等）的支持：例如 msgpack 的多语言支持

### Protobuf 简介与使用

- Protobuf 是一个灵活的、高效的用于序列化数据的协议。
- 相比较 XML 和 JSON 格式，Protobuf 更小、更快、更便捷。
- Protobuf 是跨语言的，并且自带了一个编译器（protoc），只需要用它进行编译，可以自动生成 Java、python、C++ 等代码，不需要再写其他代码。

### 源码解读：Netty 对二次编解码的支持

Protobuf 编解码怎么使用及原理？

```java
ch.pipeline().addLast(new ProtobufVarint32FrameDecoder());
ch.pipeline().addLast(new ProtobufDecoder(PersonOuterClass.Person.getDefaultInstance()));
ch.pipeline().addLast(new ProtobufVarint32LengthFieldPrepender());
ch.pipeline().addLast(new ProtobufEncoder());
```

自带哪些编解码？

## keepalive 与 Idle 监测

#### 为什么需要 keepalive ? 

生活场景:

假设你开了一个饭店，别人电话来订餐，电话通了后，订餐的说了一堆订餐要求，说着说着，对方就不讲话了（可能忘记挂机/出去办事/线路故障等）。

 这个时候你会一直握着电话等么？

不会

如果不会，那你一般怎么去做？

**会确认一句“你还在么？”，如果对方没有回复，挂机。这套机制即“keepalive”**

<img src="https://blog-1259650185.cos.ap-beijing.myqcloud.com/img/202104/27/1619453571.png" alt="image-20210427001251369" style="zoom:50%;" />

#### 怎么设计 keepalive ？以 TCP keepalive 为例

<img src="https://blog-1259650185.cos.ap-beijing.myqcloud.com/img/202104/27/1619453602.png" alt="image-20210427001322725" style="zoom:50%;" />

#### 为什么还需要应用层 keepalive ? 

- 协议分层，各层关注点不同：

  传输层关注是否“通”，应用层关注是否可服务？ 类比前面的电话订餐例子，电话能通，

  不代表有人接；服务器连接在，但是不定可以服务（例如服务不过来等）。

- TCP 层的 keepalive 默认关闭，且经过路由等中转设备 keepalive 包可能会被丢弃。

- TCP 层的 keepalive 时间太长：

  默认 > 2 小时，虽然可改，但属于系统参数，改动影响所有应用。

提示：HTTP 属于应用层协议，但是常常听到名词“ HTTP Keep-Alive ”指的是对长连接和短连接的选择：

- Connection : Keep-Alive 长连接（HTTP/1.1 默认长连接，不需要带这个 header） 
- Connection : Close 短连接

#### Idle 监测是什么？

重现生活场景:

假设你开了一个饭店，别人电话来订餐，电话通了后，订餐的说了一堆订餐要求，说着说着，对方就不讲话了。

你会**立马**发问：你还在么？

不会

一般你会稍微等待一定的时间，在这个时间内看看对方还会不会说话（**Idle 检测**），如果还不说，认定对方存在问题（**Idle**），于是开始发问“你还在么？”（**keepalive**），或者问都不问干脆直接挂机（关闭连接）。

Idle 监测，只是负责诊断，诊断后，做出不同的行为，决定 Idle 监测的最终用途：

- **发送 keepalive** :一般用来配合 keepalive ，减少 keepalive 消息。

  Keepalive 设计演进：V1 定时 keepalive 消息 -> V2 空闲监测 + 判定为 Idle 时才发keepalive。 

  - V1：keepalive 消息与服务器正常消息交换完全不关联，定时就发送；
  - V2：有其他数据传输的时候，不发送 keepalive ，无数据传输超过一定时间，判定为 Idle，再发 keepalive 。

- **直接关闭连接**：

  - 快速释放损坏的、恶意的、很久不用的连接，让系统时刻保持最好的状态。
  - 简单粗暴，客户端可能需要重连。

实际应用中：结合起来使用。**按需 keepalive ，保证不会空闲，如果空闲，关闭连接**。

#### 如何在Netty 中开启 TCP keepalive 和 Idle 检测

开启keepalive： 

Server 端开启 TCP keepalive

```java
bootstrap.childOption(ChannelOption.SO_KEEPALIVE,true) 
bootstrap.childOption(NioChannelOption.of(StandardSocketOptions.SO_KEEPALIVE), true)
```

提示：.option(ChannelOption.SO_KEEPALIVE,true) 存在但是无效

开启不同的 Idle Check:

ch.pipeline().addLast(“idleCheckHandler", new IdleStateHandler(0, 20, 0, TimeUnit.SECONDS));

```java
// io.netty.handler.timeout.IdleStateHandler
public IdleStateHandler(
        long readerIdleTime, long writerIdleTime, long allIdleTime,
        TimeUnit unit) {
    this(false, readerIdleTime, writerIdleTime, allIdleTime, unit);
}
```

## Netty 的那些“锁”事

### 分析同步问题的核心三要素

- 原子性：“并无一气呵成，岂能无懈可击”
- 可见性：“你做的改变，别人看不见”
- 有序性：“不按套路出牌”

### 锁的分类

- 对竞争的态度：乐观锁（java.util.concurrent 包中的原子类）与悲观锁（Synchronized)
- 等待锁的人是否公平而言：公平锁 new ReentrantLock (true)与非公平锁 new ReentrantLock ()
- 是否可以共享：共享锁与独享锁：ReadWriteLock ，其读锁是共享锁，其写锁是独享锁

### Netty 玩转锁的五个关键点

#### 在意锁的对象和范围 -> 减少粒度

例：初始化 channel （io.netty.bootstrap.ServerBootstrap#init）

Synchronized method -> Synchronized block

<img src="https://blog-1259650185.cos.ap-beijing.myqcloud.com/img/202104/27/1619502456.png" alt="image-20210427134736303" style="zoom:50%;" />

#### 注意锁的对象本身大小 -> 减少空间占用

例：统计待发送的字节数（io.netty.channel.ChannelOutboundBuffer

AtomicLong -> Volatile long + AtomicLongFieldUpdater

<img src="https://blog-1259650185.cos.ap-beijing.myqcloud.com/img/202104/27/1619502520.png" alt="image-20210427134840683" style="zoom:50%;" />

Atomic long VS long：

前者是一个对象，包含对象头（object header）以用来保存 hashcode、lock 等信息，32 位系统占用8字节；64 位系统占 16 字节，所以在 64 位系统情况下：

- volatile long = 8 bytes
- AtomicLong = 8 bytes （volatile long）+ 16bytes （对象头）+ 8 bytes (引用) = 32 bytes

至少节约 24 字节!

结论：Atomic* objects -> Volatile primary type + Static Atomic*FieldUpdater

#### 注意锁的速度 -> 提高并发性

例 1：记录内存分配字节数等功能用到的 LongCounter（io.netty.util.internal.PlatformDependent#newLongCounter() ）

高并发时：java.util.concurrent.atomic.AtomicLong -> java.util.concurrent.atomic.LongAdder (JDK1.8) 

结论： 及时衡量、使用 JDK 最新的功能

例 2：曾经根据不同情况，选择不同的并发包实现：JDK < 1.8 考虑

ConcurrentHashMapV8（ConcurrentHashMap 在 JDK8 中的版本），就是 把 JDK8 的实现复制到netty里，支持 JDK7 以下的使用。

#### 不同场景选择不同的并发类 -> 因需而变

例1：关闭和等待关闭事件执行器（Event Executor）：

Object.wait/notify -> CountDownLatch

wait 和 notify 要在持有锁的情况下使用，否则直接抛出异常，新手容易犯错。

io.netty.util.concurrent.SingleThreadEventExecutor#threadLock：

<img src="https://blog-1259650185.cos.ap-beijing.myqcloud.com/img/202104/27/1619502789.png" alt="image-20210427135309919" style="zoom:50%;" />

例2：Nio Event loop中负责存储task的Queue

Jdk’s LinkedBlockingQueue (MPMC) -> jctools’ MPSC

JDK 的 队列是多生产者多消费者的模式，比较通用，但是 netty 中是比较简单的多生产者单消费者模式，使用的 jctools 的实现。

io.netty.util.internal.PlatformDependent.Mpsc#newMpscQueue(int)：

<img src="https://blog-1259650185.cos.ap-beijing.myqcloud.com/img/202104/27/1619502990.png" alt="image-20210427135630291" style="zoom:50%;" />

#### 衡量好锁的价值 -> 能不用则不用

生活场景：

饭店提供了很多包厢，服务模式：

- 一个服务员固定服务某几个包厢模式；
- 所有的服务员服务所有包厢的模式。

表面上看，前者效率没有后者高，但实际上它避免了服务员之间的沟通（上下文切换）等开销，避免客人和服务员之间到处乱串，管理简单。

局部串行：Channel 的 I/O 请求处理 Pipeline 是串行的

<img src="https://blog-1259650185.cos.ap-beijing.myqcloud.com/img/202104/27/1619503124.png" alt="image-20210427135844129" style="zoom:50%;" />

整体并行：多个串行化的线程（NioEventLoop）

<img src="https://blog-1259650185.cos.ap-beijing.myqcloud.com/img/202104/27/1619503155.png" alt="image-20210427135915218" style="zoom:50%;" />

Netty 应用场景下：局部串行 + 整体并行 > 一个队列 + 多个线程模式: 

- 降低用户开发难度、逻辑简单、提升处理性能
- 避免锁带来的上下文切换和并发保护等额外开销



避免用锁：用 ThreadLocal 来避免资源争用，例如 Netty 轻量级的线程池实现

io.netty.util.Recycler#threadLocal

<img src="https://blog-1259650185.cos.ap-beijing.myqcloud.com/img/202104/27/1619503238.png" alt="image-20210427140038872" style="zoom:50%;" />



小结

- 分析同步问题的核心三要素：分析多线程问题的关键
- 浏览了锁的分类
- 结合代码分析了 Netty 玩转锁的五个关键点，具有普适性

## Netty 如何玩转内存使用

### 内存使用技巧的目标

目标：

- 内存占用少（空间）
- 应用速度快（时间）

对 Java 而言：减少 Full GC 的 STW（Stop the world）时间

### Netty 内存使用技巧 - 减少对像本身大小

例 1：用基本类型就不要用包装类：包装类会占据更大的空间

例 2: 应该定义成类变量的不要定义为实例变量

- 一个类 -> 一个类变量
- 一个实例 -> 一个实例变量
- 一个类 -> 多个实例
- 实例越多，浪费越多。

例 3: Netty 中结合前两者：

io.netty.channel.ChannelOutboundBuffer#incrementPendingOutboundBytes(long, boolean)

统计待写的请求的字节数

<img src="https://blog-1259650185.cos.ap-beijing.myqcloud.com/img/202104/27/1619518303.png" alt="image-20210427180603195" style="zoom:50%;" />

AtomicLong -> volatile long + static AtomicLongFieldUpdater

### Netty 内存使用技巧 - 对分配内存进行预估

例 1：对于已经可以预知固定 size 的 HashMap避免扩容

可以提前计算好初始size或者直接使用

com.google.common.collect.Maps#newHashMapWithExpectedSize

例 2：Netty 根据接受到的数据动态调整（guess）下个要分配的 Buffer 的大小。可参考io.netty.channel.AdaptiveRecvByteBufAllocator

<img src="https://blog-1259650185.cos.ap-beijing.myqcloud.com/img/202104/27/1619517882.png" alt="image-20210427180603195" style="zoom:50%;" />

### Netty 内存使用技巧 - Zero-Copy

例 1：使用逻辑组合，代替实际复制。

例如 CompositeByteBuf：

io.netty.handler.codec.ByteToMessageDecoder#COMPOSITE_CUMULATOR

<img src="https://blog-1259650185.cos.ap-beijing.myqcloud.com/img/202104/27/1619518708.png" alt="image-20210427181818186" style="zoom:50%;" />

例 2：使用包装，代替实际复制。

byte[] bytes = data.getBytes(); 

ByteBuf byteBuf = Unpooled.wrappedBuffer(bytes);

例 3：调用 JDK 的 Zero-Copy 接口

Netty 中也通过在 DefaultFileRegion 中包装了 NIO 的 FileChannel.transferTo() 方法实现了零拷贝：io.netty.channel.DefaultFileRegion#transferTo

<img src="https://blog-1259650185.cos.ap-beijing.myqcloud.com/img/202104/27/1619518911.png" alt="image-20210427182133693" style="zoom:50%;" />

### Netty 内存使用技巧 - 堆外内存

堆外内存生活场景：

夏日，小区周边的烧烤店铺，人满为患坐不下，店家常常怎么办？

解决思路：店铺门口摆很多桌子招待客人。

- 店内 -> JVM 内部 -> 堆（heap) + 非堆（non heap）
- 店外 -> JVM 外部 -> 堆外（off heap）



优点：

- 更广阔的“空间 ”，缓解店铺内压力 -> 破除堆空间限制，减轻 GC 压力
- 减少“冗余”细节（假设烧烤过程为了气氛在室外进行：烤好直接上桌：vs 烤好还要进店内）-> 避免复制

缺点：

- 需要搬桌子 -> 创建速度稍慢
- 受城管管、风险大 -> 堆外内存受操作系统管理

### Netty 内存使用技巧 - 内存池

内存池生活场景：

点菜单的演进：

- 一张纸：一桌客人一张纸
- 点菜平板：循环使用

为什么引入对象池：

- 创建对象开销大
- 对象高频率创建且可复用
- 支持并发又能保护系统
- 维护、共享有限的资源

如何实现对象池？

- 开源实现：Apache Commons Pool
- Netty 轻量级对象池实现 io.netty.util.Recycler

### 源码解读Netty 内存使用

源码解读：

- 怎么从堆外内存切换堆内使用？以UnpooledByteBufAllocator为例 public UnpooledByteBufAllocator(boolean preferDirect)

- 堆外内存的分配本质？

- 内存池/非内存池的默认选择及切换方式？

  io.netty.channel.DefaultChannelConfig#allocator

- 内存池实现（以 PooledDirectByteBuf 为例）

  io.netty.buffer.PooledDirectByteBuf

源码解读总结：

- 怎么从堆外内存切换堆内使用？

  - 方法 1：参数设置

    io.netty.noPreferDirect = true;

  - 方法 2：传入构造参数false

    ServerBootstrap serverBootStrap = new ServerBootstrap();

    UnpooledByteBufAllocator unpooledByteBufAllocator = new UnpooledByteBufAllocator(**false**);

    serverBootStrap.childOption(ChannelOption.ALLOCATOR, unpooledByteBufAllocator) 

- 堆外内存的分配？

  ByteBuffer.allocateDirect(initialCapacity)

- 内存池/非内存池的默认选择及切换方式？

  默认选择：安卓平台 -> 非 pooled 实现，其他 -> pooled 实现。

  - 参数设置：io.netty.allocator.type = unpooled; 
  - 显式指定：serverBootStrap.childOption(ChannelOption.ALLOCATOR, UnpooledByteBufAllocator.DEFAULT) 

- 内存池实现？

  核心要点：有借有还，避免遗忘。



# Netty 源码：从“线”（请求处理）的角度剖析



<img src="https://blog-1259650185.cos.ap-beijing.myqcloud.com/img/202104/27/1619522692.png" alt="image-20210427192441769" style="zoom:50%;" />

## 源码剖析：启动服务

**our thread**	（我们自己的线程，如 main 线程）

- 创建 selector
- 创建 server socket channel
- 初始化 server socket channel
- 给 server socket channel 从 **boss group** 中选择一个 NioEventLoop

**boss thread**

-  server socket channel 注册到选择的 NioEventLoop 的 selector
- 绑定地址启动
- 注册接受连接事件（OP_ACCEPT）到 selector 上

our thread  线程切换-->   boss thread

启动服务的本质：

```java
Selector selector = sun.nio.ch.SelectorProviderImpl.openSelector()
ServerSocketChannel serverSocketChannel = provider.openServerSocketChannel()
selectionKey = javaChannel().register(eventLoop().unwrappedSelector(), 0, this);
javaChannel().bind(localAddress, config.getBacklog());
selectionKey.interestOps(OP_ACCEPT);
```



- Selector 是在 new NioEventLoopGroup()（创建一批 NioEventLoop）时创建。

- 第一次 Register 并不是监听 OP_ACCEPT，而是 0:

  selectionKey = javaChannel().register(eventLoop().unwrappedSelector(), 0, **this**) 。 

- 最终监听 OP_ACCEPT 是通过 bind 完成后的 fireChannelActive() 来触发的。
- NioEventLoop 是通过 Register 操作的执行来完成启动的。
- 类似 ChannelInitializer，一些 Hander 可以设计成一次性的，用完就移除，例如授权。

## 源码剖析：构建连接

**boss thread**

- NioEventLoop 中的 selector 轮询创建连接事件（OP_ACCEPT）
- 创建 socket channel 
- 初始化 socket channel 并从 **worker group** 中选择一个 NioEventLoop

**boss thread**

- 将 socket channel 注册到选择的 NioEventLoop 的 selector
- 注册读事件（OP_READ）到 selector 上

接受连接本质：

selector.select()/selectNow()/select(timeoutMillis) 发现 **OP_ACCEPT** 事件，处理：

1. SocketChannel socketChannel = serverSocketChannel.accept()
2. selectionKey = javaChannel().register(eventLoop().unwrappedSelector(), 0, this);
3. selectionKey.interestOps(OP_READ);



- 创建连接的初始化和注册是通过 pipeline.fireChannelRead 在 ServerBootstrapAcceptor 中完成的。

- 第一次 Register 并不是监听 OP_READ ，而是 0 ：

  selectionKey = javaChannel().register(eventLoop().unwrappedSelector(), 0, **this**) 。 

- 最终监听 OP_READ 是通过“Register”完成后的fireChannelActive

  （io.netty.channel.AbstractChannel.AbstractUnsafe#register0中）来触发的

- Worker’s NioEventLoop 是通过 Register 操作执行来启动。

## 源码剖析：接受数据

### 读数据技巧

1. 自适应数据大小的分配器（AdaptiveRecvByteBufAllocator）：

   发放东西时，拿多大的桶去装？小了不够，大了浪费，所以会自己根据实际装的情况猜一猜下次情况，从而决定下次带多大的桶。

2. 连续读（defaultMaxMessagesPerRead）：

   发放东西时，假设拿的桶装满了，这个时候，你会觉得可能还有东西发放，所以直接拿个新桶等着装，而不是回家，直到后面出现没有装上的情况或者装了很多次需要给别人一点机会等原因才停止，回家。

### 主线（woke thread）

- 多路复用器（ Selector ）接收到 OP_READ 事件
- 处理 OP_READ 事件：NioSocketChannel.NioSocketChannelUnsafe.read() 
  - 分配一个初始 1024 字节的 byte buffer 来接受数据
  - 从 Channel 接受数据到 byte buffer
  - 记录实际接受数据大小，调整下次分配 byte buffer 大小
  - 触发 pipeline.fireChannelRead(byteBuf) 把读取到的数据传播出去
  - 判断接受 byte buffer 是否满载而归：是，尝试继续读取直到没有数据或满 16 次；否，结束本轮读取，等待下次 OP_READ 事件

### 知识点

- 读取数据本质：sun.nio.ch.SocketChannelImpl#read(java.nio.ByteBuffer) 

- NioSocketChannel read() 是读数据， NioServerSocketChannel read() 是创建连接

- pipeline.fireChannelReadComplete(); 一次读事件处理完成

  pipeline.fireChannelRead(byteBuf); 一次读数据完成，一次读事件处理可能会包含多次读数据操作。

- 为什么最多只尝试读取 16 次？“雨露均沾”，让注册到同一个 eventLoop 的其他 channel 也读一下

- AdaptiveRecvByteBufAllocator 对 bytebuf 的猜测：放大果断，缩小谨慎（需要连续 2 次判断）

## 源码剖析：业务处理

### 主线（worker thread）

- ~~多路复用器（ Selector ）接收到 OP_READ 事件~~
- ~~处理 OP_READ 事件：NioSocketChannel.NioSocketChannelUnsafe.read()~~ 
  - ~~分配一个初始 1024 字节的 byte buffer 来接受数据~~
  - ~~从 Channel 接受数据到 byte buffer~~
  - ~~记录实际接受数据大小，调整下次分配 byte buffer 大小~~
  - **触发 pipeline.fireChannelRead(byteBuf) 把读取到的数据传播出去**
  - ~~判断接受 byte buffer 是否满载而归：是，尝试继续读取直到没有数据或满 16 次；否，结束本轮读取，等待下次OP_READ事件~~

<img src="http://blog-1259650185.cosbj.myqcloud.com/img/202109/05/1630813432.png" alt="image-20210905114352490" style="zoom:50%;" />

Handler 执行资格：

- 实现了 ChannelInboundHandler
- 实现方法 channelRead 不能加注解 @Skip 

### 知识点

- 处理业务本质：数据在 pipeline 中所有的 handler 的 channelRead() 执行过程

  Handler 要实现 io.netty.channel.ChannelInboundHandler#channelRead (ChannelHandlerContext ctx, 

  Object msg)，且不能加注解 @Skip 才能被执行到。

  中途可退出，不保证执行到 Tail Handler。 

- 默认处理线程就是 Channel 绑定的 NioEventLoop 线程，也可以设置其他：

  pipeline.addLast(new UnorderedThreadPoolEventExecutor(10), serverHandler)

## 源码剖析：发送数据

### 写数据三种方式

| 快递场景（包裹）                | Netty 写数据（数据）                          |
| ------------------------------- | --------------------------------------------- |
| 揽收到仓库                      | **write**：写到一个 buffer                    |
| 从仓库发货                      | **flush**: 把 buffer 里的数据发送出去         |
| 揽收到仓库并立马发货 （加急件） | **writeAndFlush**：写到 buffer，立马发送      |
| 揽收与发货之间有个缓冲的仓库    | Write 和 Flush 之间有个 ChannelOutboundBuffer |

### 写数据要点

1. 对方仓库爆仓时，送不了的时候，会停止送，协商等电话通知什么时候好了，再送。

   Netty 写数据，写不进去时，会停止写，然后注册一个 **OP_WRITE** 事件，来通知什么时候可以写进去了再写。

2. 发送快递时，对方仓库都直接收下，这个时候再发送快递时，可以尝试发送更多的快递试试，这样效果更好。

   Netty 批量写数据时，如果想写的都写进去了，接下来的尝试写更多（调整 **maxBytesPerGatheringWrite**）。

3. 发送快递时，发到某个地方的快递特别多，我们会连续发，但是快递车毕竟有限，也会考虑下其他地方。

   Netty 只要有数据要写，且能写的出去，则一直尝试，直到写不出去或者满 16 次（**writeSpinCount**）。

4. 揽收太多，发送来不及时，爆仓，这个时候会出个告示牌：收不下了，最好过 2 天再来邮寄吧。

   Netty 待写数据太多，超过一定的水位线（**writeBufferWaterMark.high()**），会将可写的标志位改成 false ，让应用端自己做决定要不要发送数据了。

### 主线

<img src="http://blog-1259650185.cosbj.myqcloud.com/img/202109/05/1630831581.png" alt="image-20210905164621003" style="zoom:50%;" />

- Write - 写数据到 buffer ：

  ChannelOutboundBuffer#addMessage

- Flush - 发送 buffer 里面的数据：

  AbstractChannel.AbstractUnsafe#flush

  - 准备数据: ChannelOutboundBuffer#addFlush
  - 发送：NioSocketChannel#doWrite

### 知识点

- 写的本质：
  - Single write: sun.nio.ch.SocketChannelImpl#write(java.nio.ByteBuffer) 
  - gathering write：sun.nio.ch.SocketChannelImpl#write(java.nio.ByteBuffer[], int, int)
- 写数据写不进去时，会停止写，注册一个 **OP_WRITE** 事件，来通知什么时候可以写进去了。
- **OP_WRITE 不是说有数据可写，而是说可以写进去**，所以正常情况，不能注册，否则一直触发。

- 批量写数据时，如果尝试写的都写进去了，接下来会尝试写更多（**maxBytesPerGatheringWrite**）。
- 只要有数据要写，且能写，则一直尝试，直到 16 次（**writeSpinCount**），写 16 次还没有写完，就直接 schedule 一个 task 来继续写，而不是用注册写事件来触发，更简洁有力。
- 待写数据太多，超过一定的水位线（**writeBufferWaterMark**.high()），会将可写的标志位改成 false ，让应用端自己做决定要不要继续写。
- channelHandlerContext.channel().write() ：从 TailContext 开始执行；channelHandlerContext.write() : 从当前的 Context 开始。

## 源码剖析：断开连接

### 主线

- 多路复用器（Selector）接收到 OP_READ 事件 : 
- 处理 OP_READ 事件：NioSocketChannel.NioSocketChannelUnsafe.read()： 
  - 接受数据
  - 判断接受的数据大小是否 < 0 , 如果是，说明是关闭，开始执行关闭：
    - 关闭 channel（包含 cancel 多路复用器的 key）。
    - 清理消息：不接受新信息，fail 掉所有 queue 中消息。
    - 触发 fireChannelInactive 和 fireChannelUnregistered 。

### 知识点

- 关闭连接本质：
  - java.nio.channels.spi.AbstractInterruptibleChannel#close
    - java.nio.channels.SelectionKey#cancel
- 要点：
  - 关闭连接，会触发 OP_READ 方法。读取字节数是 -1 代表关闭。
  - 数据读取进行时，强行关闭，触发 IO Exception，进而执行关闭。
  - Channel 的关闭包含了 SelectionKey 的 cancel 。

## 源码剖析：关闭服务

<img src="http://blog-1259650185.cosbj.myqcloud.com/img/202109/06/1630857990.png" alt="image-20210906000630309" style="zoom:50%;" />

### 主线

- bossGroup.shutdownGracefully();

  workerGroup.shutdownGracefully();

  关闭所有 Group 中的 NioEventLoop: 

  - 修改 NioEventLoop 的 State 标志位
  - NioEventLoop 判断 State 执行退出

### 知识点

- 关闭服务本质：

  - 关闭所有连接及 Selector ：

    - java.nio.channels.Selector#keys
      - java.nio.channels.spi.AbstractInterruptibleChannel#close
      - java.nio.channels.SelectionKey#cancel

    - selector.close()

  - 关闭所有线程：退出循环体 for (;;)

    - 关闭服务要点：
      - 优雅（DEFAULT_SHUTDOWN_QUIET_PERIOD） 
      - 可控（DEFAULT_SHUTDOWN_TIMEOUT） 
      - 先不接活，后尽量干完手头的活（先关 boss 后关 worker：不是100%保证）



# Netty进阶

## Netty 编程中易错点解析

- LengthFieldBasedFrameDecoder 中 initialBytesToStrip 未考虑设置。解析出来的带了length字段，导致解析失败
- ChannelHandler 顺序不正确
- ChannelHandler 该共享不共享，不该共享却共享。多线程并发问题
- 分配 ByteBuf ：分配器直接用 ByteBufAllocator.DEFAULT 等，而不是采用 ChannelHandlerContext.alloc()。ChannelHandlerContext.alloc() 使用的是serverBootStrap参数里设置的allocator，保持一致。
- 未考虑 ByteBuf 的释放。SimpleChannelInboundHandler 帮我们释放资源。
- 错以为 ChannelHandlerContext.write(msg) 就写出数据了。write 仅仅是将信息写到队列里。
- 乱用 ChannelHandlerContext.channel().writeAndFlush(msg)。channel().writeAndFlush(msg) 调用的是整个 pipeline 全部走一遍，ChannelHandlerContext.writeAndFlush(msg) 是找到下一个handler，并不是全部 pipeline 重新走一遍。

## 调优参数

### 调整 System 参数夯实基础

- Linux 系统参数

  例如：*/proc/sys/net/ipv4/tcp_keepalive_time*

  - 进行 TCP 连接时，系统为每个 TCP 连接创建一个 socket 句柄，也就是一个文件句柄，但是 Linux 对每个进程打开的文件句柄数量做了限制，如果超出：报错 “Too many open file”。

    **ulimit -n [xxx]**

    注意：ulimit 命令修改的数值只对当前登录用户的目前使用环境有效，系统重启或者用户退出后就会失效，所以可以作为程序启动脚本一部分，让它程序启动前执行。

- Netty 支持的系统参数

  例如：*serverBootstrap.option(ChannelOption.SO_BACKLOG, 1024);*

  - SocketChannel -> .childOption
  - ServerSocketChannel -> .option

  

  SocketChannel（7个： childOption）:

  | Netty 系统相关参数 | 功能                                                         | 默认值                                                       |
  | ------------------ | ------------------------------------------------------------ | ------------------------------------------------------------ |
  | SO_SNDBUF          | TCP 数据发送缓冲区大小（快递的仓库）                         | /proc/sys/net/ipv4/tcp_wmem: 4K<br />[min, default, max] 动态调整 |
  | SO_RCVBUF          | TCP 数据接受缓冲区大小（快递的仓库）                         | /proc/sys/net/ipv4/tcp_rmem: 4K                              |
  | SO_KEEPALIVE       | TCP 层 keepalive（启用应用层 keepAlive ，TCP层保持关闭即可） | 默认关闭                                                     |
  | SO_REUSEADDR       | 地址重用，解决“Address already in use”<br />常用开启场景：多网卡（IP）绑定相同端口；让关闭连接释放的端口更早可使用 | 默认不开启<br />澄清：不是让 TCP 绑定完全相同 IP + Port 来重复启动 |
  | SO_LINGER          | 关闭 Socket 的延迟时间，默认禁用该功能，socket.close() 方法立即返回 | 默认不开启                                                   |
  | IP_TOS             | 设置 IP 头部的 Type-of-Service 字段，用于描述 IP 包的优先级和 QoS 选项。例如倾向于延时还是吞吐量？ | 1000 - minimize delay<br />0100 - maximize throughput<br />0010 - maximize reliability<br />0001 - minimize monetary cost<br />0000 - normal service （默认值）<br />*The value of the socket option is a hint. An* *implementation may ignore the value, or ignore specific values.* |
  | TCP_NODELAY        | 设置是否启用 Nagle 算法：用将小的碎片数据连接成更大的报文来提高发送效率。 | False<br />如果需要发送一些较小的报文，则需要禁用该算法      |

  

  ServerSocketChannel（3个： option ）:

  | Netty 系统相关参数 | 功能                                                         | 备注                                                         |
  | ------------------ | ------------------------------------------------------------ | ------------------------------------------------------------ |
  | SO_RCVBUF          | 为 Accept 创建的 socket channel 设置SO_RCVBUF：<br />“Sets a default proposed value for the SO_RCVBUF option <br />for sockets accepted from this ServerSocket” | 为什么有 SO_RCVBUF 而没有 SO_SNDBUF ？                       |
  | SO_REUSEADDR       | 是否可以重用端口                                             | 默认false                                                    |
  | **SO_BACKLOG**     | 最大的等待连接数量                                           | Netty 在 Linux下值的获取 （io.netty.util.NetUtil）：<br />先尝试：/proc/sys/net/core/somaxcon<br />然后尝试：sysctl<br />最终没有取到，用默认：**128**<br />使用方式：javaChannel().bind(localAddress, config.getBacklog()); |
  | ~~IP_TOS~~         |                                                              |                                                              |


### 权衡 Netty 核心参数

- 参数调整要点：
  - option/childOption 傻傻分不清：不会报错，但是会不生效；
  - 不懂不要动，避免过早优化。
  - 可配置（动态配置更好）
- 需要调整的参数：
  - 最大打开文件数
  - TCP_NODELAY SO_BACKLOG SO_REUSEADDR（酌情处理）
- ChannelOption
  - childOption(ChannelOption.[XXX], [YYY])
  - option(ChannelOption.[XXX], [YYY])
- System property
  - -Dio.netty.[XXX] = [YYY]



ChannelOption （非系统相关：共11个）

| Netty 参数                           | 功能                                                         | 默认值                                                       |
| ------------------------------------ | ------------------------------------------------------------ | ------------------------------------------------------------ |
| WRITE_BUFFER_WATER_MARK              | 高低水位线、间接防止写数据 OOM（write 设置成不可写，提醒我们不要再写数据，防止OOM） | 32k -> 64k，为什么不大？这是 channel 级别，如果是百万连接，就是个非常大的值了。 |
| CONNECT_TIMEOUT_MILLIS               | 客户端连接服务器最大允许时间                                 | 30秒                                                         |
| MAX_MESSAGES_PER_READ                | 最大允许“连续”读次数                                         | 16次                                                         |
| WRITE_SPIN_COUNT                     | 最大允许“连读”写次数                                         | 16次                                                         |
| ALLOCATOR                            | ByteBuf 分配器                                               | ByteBufAllocator.DEFAULT：大多池化、堆外                     |
| RCVBUF_ALLOCATOR                     | 数据接收 ByteBuf 分配大小计算器 + 读次数控制器               | AdaptiveRecvByteBufAllocator                                 |
| AUTO_READ                            | 是否监听“读事件”                                             | 默认：监听“读”事件：<br />设置此标记的方法也触发注册或移除读事件的监听 |
| AUTO_CLOSE                           | “写数据”失败，是否关闭连接                                   | 默认打开，会关闭连接，因为不关闭，下次还写，还是失败怎么办！ |
| MESSAGE_SIZE_ESTIMATOR               | 数据（ByteBuf、FileRegion等）大小计算器                      | DefaultMessageSizeEstimator.DEFAULT<br />例如计算 ByteBuf: byteBuf.readableBytes() |
| SINGLE_EVENTEXECUTOR_PER<br />_GROUP | 当增加一个 handler 且指定 EventExecutorGroup 时：决定这个 handler 是否只用EventExecutorGroup 中的一个固定的EventExecutor （取决于next()实现） | 默认：true:<br />这个 handler 不管是否共享，绑定上唯一一个 event executor.所以小名“**pinEventExecutor**”<br />没有指定 EventExecutorGroup，复用 channel 的 NioEventLoop |
| ALLOW_HALF_CLOSURE                   | 关闭连接时，允许半关。<br />https://issues.jboss.org/browse/NETTY-236 | 默认：不允许半关，如果允许，处理变成：<br />shutdownInput(); <br />pipeline.fireUserEventTriggered(ChannelInputShutd |

- ALLOCATOR 与 RCVBUF_ALLOCATOR

  - 功能关联：

    ALLOCATOR 负责 ByteBuf **怎么分配**（例如：从哪里分配），RCVBUF_ALLOCATOR 负责计算为**接收**数据接**分配多少** ByteBuf：

    例如，AdaptiveRecvByteBufAllocator 有两大功能：

    1. 动态计算下一次分配 bytebuf 的大小：guess()； 
    2. 判断**是否可以继续读**：continueReading()

    一对兄弟，共同完成一件事，一个是负责怎么分配，一个是负责分配多少。

  - 代码关联：

    io.netty.channel.AdaptiveRecvByteBufAllocator.HandleImpl handle = **AdaptiveRecvByteBufAllocator**.newHandle();

    ByteBuf byteBuf = handle.allocate(**ByteBufAllocator**)

    其中： allocate的实现：

    ​	ByteBuf allocate(ByteBufAllocator alloc) {

    ​		return alloc.ioBuffer(guess()); 

    ​	}

- System property (-Dio.netty.xxx，50+ ） 
  - 多种实现的切换：-Dio.netty.noJdkZlibDecoder 
  - 参数的调优： -Dio.netty.eventLoopThreads
  - 功能的开启关闭： -Dio.netty.noKeySetOptimization

| Netty 参数                                                   | 功能                     | 备注                                                         |
| ------------------------------------------------------------ | ------------------------ | ------------------------------------------------------------ |
| io.netty.eventLoopThreads                                    | IO Thread 数量           | 默认：availableProcessors * 2                                |
| io.netty.availableProcessors                                 | 指定 availableProcessors | 考虑 docker/VM 等情况                                        |
| io.netty.allocator.type                                      | unpooled/pooled          | 池化还是非池化？                                             |
| io.netty.noPreferDirect                                      | true/false               | 堆内还是堆外？                                               |
| io.netty.noUnsafe                                            | true/false               | 是否使用 sun.misc.Unsafe                                     |
| io.netty.leakDetection.level                                 | DISABLED/SIMPLE 等       | 内存泄漏检测级别，默认 SIMPLE                                |
| io.netty.native.workdir<br />io.netty.tmpdir                 | 临时目录                 | 从 jar 中解出 native 库存放的临时目录                        |
| io.netty.processId<br />io.netty.machineId                   | 进程号<br />机器硬件地址 | 计算 channel 的 ID :<br />MACHINE_ID + PROCESS_ID + SEQUENCE+ TIMESTAMP + RANDOM |
| io.netty.eventLoop.maxPendingTasks<br />io.netty.eventexecutor.maxPendingTasks | 存的 task 最大数目       | 默认 Integer.MAX_VALUE，显示设置为准，不低于16               |
| io.netty.handler.ssl.noOpenSsl                               | 关闭 open ssl 使用       | 优选 open ssl                                                |

- 补充说明

  - 一些其他重要的参数：

    - NioEventLoopGroup workerGroup = new NioEventLoopGroup();

      workerGroup.setIoRatio(50); 

  - 注意参数的关联

    - 临时存放 native 库的目录： -> io.netty.native.workdir > io.netty.tmpdir

  - 注意参数的变更

    - ~~io.netty.noResourceLeakDetection~~ -> io.netty.leakDetection.level

## 跟踪诊断

### 如何让应用易诊断

- 完善“线程名”

  - nioEventLoopGroup-2-1：boss group

    `new DefaultEventLoopGroup(1, new DefaultThreadFactory("boss")`

  - nioEventLoopGroup-3-1：worker group

    `new DefaultEventLoopGroup(0, new DefaultThreadFactory("worker"))`

- 完善 “Handler ”名称

  `pipeline.addLast("frameDecoder", new OrderFrameDecoder());`

- 使用好 Netty 的日志

  - Netty 日志框架原理
  - 修改 JDK logger 级别
  - 使用 slf4j + log4j 示例
  - 衡量好 logging handler 的位置和级别

### 应用能可视，心里才有底

Netty 可视化案例演示：

- 实现一个小目标：统计并展示当前系统连接数
  - Console 日志定时输出
  - JMX 实时展示
  - ELKK、TIG、etc

Netty 值得可视化的数据 –“外在”

| 可视化信息   | 来源                          | 备注                                |
| ------------ | ----------------------------- | ----------------------------------- |
| 连接信息统计 | channelActive/channelInactive |                                     |
| 收数据统计   | channelRead                   |                                     |
| 发数据统计   | write                         | ctx.write(msg).addListener() 更准确 |
| 异常统计     | exceptionCaught/ChannelFuture | ReadTimeoutException.INSTANCE       |

Netty 值得可视化的数据 –“内在”

| 可视化信息      | 来源                                             | 备注                                     |
| --------------- | ------------------------------------------------ | ---------------------------------------- |
| 线程数          | 根据不同实现计算                                 | 例如：nioEventLoopGroup.executorCount(); |
| 待处理任务      | executor.pendingTasks()                          | 例如：Nio Event Loop 的待处理任务        |
| 积累的数据      | channelOutboundBuffer.totalPendingSize           | Channel 级别                             |
| 可写状态切换    | channelWritabilityChanged                        |                                          |
| 触发事件统计    | userEventTriggered                               | IdleStateEvent                           |
| ByteBuf分配细节 | Pooled/UnpooledByteBufAllocator.DEFAULT.metric() |                                          |

<img src="http://blog-1259650185.cosbj.myqcloud.com/img/202109/07/1630982069.png" alt="image-20210907103429778" style="zoom:50%;" />

### 让应用内存不“泄露”？

- 本节的 Netty 内存泄漏是指什么？

  - 原因：“忘记”release

    ByteBuf buffer = ctx.alloc().buffer();

    buffer.release() / ReferenceCountUtil.release(buffer)

  - 后果：资源未释放 -> OOM
    - 堆外：未 free（PlatformDependent.freeDirectBuffer(buffer)）；
    - 池化：未归还 （recyclerHandle.recycle(this)）

- Netty 内存泄漏检测核心思路

  Netty 内存泄漏检测核心思路：引用计数（buffer.refCnt()）+ 弱引用（Weak reference） 

  - 引用计数

    - 判断历史人物到底功大于过，还是过大于功？

      功  +1， 过 -1， = 0 时：尘归尘，土归土，资源也该释放了

    - 那什么时候判断？“盖棺定论”时 -> 对象被 GC 后

  - 强引用与弱引用

    WeakReference<> 我是爱写作的弱保镖 = new WeakReference<>(new String(我是主人)，我的小本本ReferenceQueue);

    **referent（被 GC 掉）时候，我还是可以发挥写作特长：把我自己记到“小本本”（ReferenceQueue）上去**。

  ByteBuf buffer = ctx.alloc().buffer()  -> 引用计数 + 1 -> 定义弱引用对象 DefaultResourceLeak 加到 list （#**allLeaks** ）里

  buffer.release() ：                                -> 引用计数 – 1 -> 减到 0 时，自动执行释放资源操作，并将弱引用对象从 list 里面移除

  - 判断依据： 弱引用对象在不在 list 里面? 如果在，说明引用计数还没有到 0 没有到0，说明没有执行释放
  - 判断时机： 弱引用指向对象被回收时，可以把弱引用放进指定 **ReferenceQueue** 里面去，所以**遍历 queue** 拿出所有弱引用来判断

- Netty 内存泄漏检测的源码解析

  - 全样本？抽样？： PlatformDependent.threadLocalRandom().nextInt(samplingInterval)
  - 记录访问信息：new Record() : record extends Throwable
  - 级别/开关：io.netty.util.ResourceLeakDetector.Level
  - 信息呈现：logger.error
  - 触发汇报时机： AbstractByteBufAllocator#buffer() ：io.netty.util.ResourceLeakDetector#track0

- 示例：用 Netty 内存泄漏检测工具做检测

  - 方法：-Dio.netty.leakDetection.level=PARANOID 
  - 注意：
    - 默认级别 SIMPLE，不是每次都检测
    - GC 后，才有可能检测到
    - 注意日志级别
    - 上线前用最高级别，上线后用默认

## 优化使用

### 用好自带注解省点心

- @Sharable：标识 handler 提醒可共享，不标记共享的不能重复加入 pipeline
- @Skip：跳过 handler 的执行
- @UnstableApi：提醒不稳定，慎用
- @SuppressJava6Requirement：去除“Java6需求”的报警 https://github.com/mojohaus/animal-sniffer
- @SuppressForbidden：https://github.com/policeman-tools/forbidden-apis/去除 “禁用” 报警

### 整改线程模型让响应健步如飞

业务的常用两种场景：

- CPU 密集型：运算型

  - 保持当前线程模型：
    - Runtime.getRuntime().availableProcessors() * 2 
    - io.netty.availableProcessors * 2 
    - io.netty.eventLoopThreads

- IO 密集型：等待型

  - 整改线程模型：独立出 “线程池”来处理业务

    - 在 handler 内部使用 JDK Executors

    - 添加 handler 时，指定1个：

      EventExecutorGroup eventExecutorGroup = new UnorderedThreadPoolEventExecutor(10);

      pipeline.addLast(eventExecutorGroup, serverHandler)

      为什么案例中不用 new NioEventLoopGroup()？

### 增强写，延迟与吞吐量的抉择

写的“问题”

- 全部“加急式”快递 ，延迟低，但是吞吐量也很低`ctx.writeAndFlush(responseMessage);`

改进方式1：channelReadComplete

- 缺点：

  - 不适合异步业务线程 (不复用 NIO event loop) 处理：

    channelRead 中的业务处理结果的 write 很可能发生在 channelReadComplete 之后 

  - 不适合更精细的控制：例如连读 16 次时，第 16 次是 flush，但是如果保持连续的次数不变，如何做到 3 次就 flush?

改进方式2：flushConsolidationHandler

- 源码分析
- 使用

### 如何让应用丝般“平滑”

#### 流量整形的用途

- 网盘限速（有意）
- 景点限流（无奈）

#### Netty 内置的三种流量整形

- Channel级别：ChannelTrafficShapingHandler （2）
- Global级别：GlobalTrafficShapingHandler （2）
- GlobalChannelTrafficShapingHandler （4）

#### Netty 流量整形的源码分析与总结

- 读写流控判断：按一定时间段 checkInterval （1s） 来统计。writeLimit/readLimit 设置的值为 0时，表示关闭写整形/读整形

  是固定窗口（1s）的方式，而不是令牌桶或者滑动窗口的方式。

- 等待时间范围控制：10ms （MINIMAL_WAIT） -> 15s （maxTime） 

- 读流控：取消读事件监听，让读缓存区满，然后对端写缓存区满，然后对端写不进去，对端对数据进行丢弃或减缓发送。

- 写流控：待发数据入 Queue。等待超过 4s (maxWriteDelay) || 单个 channel 缓存的数据超过 4M(maxWriteSize) || 所有缓存数据超过400M (maxGlobalWriteSize)时修改写状态为不可写。

#### 示例：流量整形的使用

- ChannelTrafficShapingHandler
- GlobalTrafficShapingHandler：share
- GlobalChannelTrafficShapingHandler: share

### 为不同平台开启 Native

#### 如何开启 Native

- 修改代码
  - NioServerSocketChannel -> [Prefix]ServerSocketChannel
  - NioEventLoopGroup -> [Prefix]EventLoopGroup

- 准备好 native 库：自己build/Netty jar也自带了一些

#### 源码分析 Native 库的加载逻辑

- java.library.path: /usr/java/packages/lib/amd64:/usr/lib64:/lib64:/lib:/usr/lib
- META-INF/native/
- Native 相关的参数
  - io.netty.transport.noNative：是不是要启用native
  - io.netty.native.workdir：临时目录存放从 META-INF/native/ 拷贝出来的 native 库
  - io.netty.native.deleteLibAfterLoading：在 JVM 退出的时候删除掉临时文件

#### 常见问题

- 常见问题1： 平台
- 常见问题2： 执行权限

## 安全增强

### 设置“高低水位线”等保护好自己

#### Netty OOM 的根本原因

- 根源：进（读速度）大于出（写速度）
- 表象：
  - 上游发送太快：任务重
  - 自己：处理慢/不发或发的慢：处理能力有限，流量控制等原因
  - 网速：卡
  - 下游处理速度慢：导致不及时读取接受 Buffer 数据，然后反馈到这边，发送速度降速

#### Netty OOM – ChannelOutboundBuffer 

- 存的对象：Linked list 存 ChannelOutboundBuffer.Entry

- 解决方式：判断 totalPendingSize > writeBufferWaterMark.high() 设置unwritable

  - ChannelOutboundBuffer:

    <img src="http://blog-1259650185.cosbj.myqcloud.com/img/202109/08/1631032661.png" alt="image-20210908003740874" style="zoom:50%;" />

#### Netty OOM – TrafficShapingHandler

- 存的对象：messagesQueue 存 ChannelTrafficShapingHandler.ToSend

-  解决方式：判断 queueSize > maxWriteSize 或 delay > maxWriteDelay 设置 unwritable

  - AbstractTrafficShapingHandler:

    <img src="http://blog-1259650185.cosbj.myqcloud.com/img/202109/08/1631032705.png" alt="image-20210908003825813" style="zoom:50%;" />

#### Netty OOM 的对策

- unwritable

  是个 int 值，有好几位，GlobalTrafficShapingHandler 用1-3位，writeBufferWaterMark 用0位，针对不同情况可以做不同处理，需改写状态的时候会触发事件，区分不同状态。

  <img src="http://blog-1259650185.cosbj.myqcloud.com/img/202109/08/1631032830.png" alt="image-20210908004029976" style="zoom:50%;" />

- 设置好参数：
  - 高低水位线 （默认 32K-64K） 
  - 启用流量整形时才需要考虑：
    - maxwrite (默认4M) 
    - maxGlobalWriteSize (默认400M
    - maxWriteDelay (默认4s)

效果的关键：

判断 channel.isWritable()

### 启用空闲监测

示例：实现一个小目标

- 服务器加上 read idle check – 服务器 10s 接受不到 channel 的请求就断掉连接
  - 保护自己、瘦身（及时清理空闲的连接）

- 客户端加上 write idle check + keepalive – 客户端 5s 不发送数据就发一个 keepalive 
  - 避免连接被断
  - 启用不频繁的 keepalive

### 简单有效的黑白名单

#### Netty 中的 “cidrPrefix” 是什么？

<img src="http://blog-1259650185.cosbj.myqcloud.com/img/202109/08/1631067731.png" alt="image-20210908102211572" style="zoom:50%;" />

<img src="http://blog-1259650185.cosbj.myqcloud.com/img/202109/08/1631067794.png" alt="image-20210908102314838" style="zoom:50%;" />

#### Netty 地址过滤功能源码分析

- 同一个 IP 只能有一个连接
- IP 地址过滤：黑名单、白名单

#### 示例：使用黑名单增强安全

### 少不了的自定义授权

- 示例：
  - 使用自定义授权

### 拿来即用的 SSL

#### 什么是 SSL ?

- SSL/TLS 协议在传输层之上封装了应用层数据，不需要修改应用层协议的前提下提供安全保障
- TLS（传输层安全）是更为安全的升级版 SSL

#### 一段聊天记录揭示 SSL 的功能与设计

SSL剧本演员角色：

- 表白内容的加密：对称加密方式
- 对称加密密钥的传递：非对称加密方式，其中公钥：邮箱，私钥：邮箱密码
- 对称加密的密钥产生：三个随机数一起产生：1 男主打招呼（client hello）时携带随机数 2 女主打招呼（server hello）时携带随机数并返回邮箱地址（公钥） 3 男主产生并发送给女主的 pre master key：用发邮箱的方式（非对称加密方式）传递。女主在邮箱里收到公钥后，用3个随机数和公钥也产生一个对称加密的密钥，和客户端产生的是一样的，测试一下就可以用了。

画外音： 

- 为什么聊天内容用对称加密，而不是用非对称加密？效率高。 
- 公钥信息（邮箱地址）是放在证书（有效证件）上的，类似身份证、工牌卡等什么的。
- 证书的来源？自己做或者买授权过的。

Note: 本节示例基于“单向验证 + 交换秘钥方式为 RSA 方式”

#### 抓包案例：

- io.netty.example.securechat.SecureChatClient：

  final SslContext sslCtx = SslContextBuilder.forClient()

  // 客户端支持的加密套件，让服务端自己选

  .trustManager(InsecureTrustManagerFactory.INSTANCE).ciphers(Arrays.asList("TLS_RSA_WITH_AES_256_CBC_SHA")).build();

- io.netty.example.securechat.SecureChatServer：

  // 服务端返回公钥，相当于告诉客户端邮箱地址

  SelfSignedCertificate ssc = new SelfSignedCertificate(); System.out.println(ssc.privateKey());

#### SSL 流程总结

<img src="http://blog-1259650185.cosbj.myqcloud.com/img/202109/08/1631069683.png" alt="image-20210908105443762" style="zoom:50%;" />

#### 使用 SSL

在 Netty 中 使用 SSL： io.netty.handler.ssl.SslHandler



<img src="http://blog-1259650185.cosbj.myqcloud.com/img/202109/08/1631070254.png" alt="image-20210908110414534" style="zoom:50%;" />

# 总结

<img src="http://blog-1259650185.cosbj.myqcloud.com/img/202109/08/1631080289.png" alt="image-20210908135129312" style="zoom:50%;" />

# 参考

[极客时间-Netty 源码剖析与实战](https://time.geekbang.org/course/intro/237)

[Netty源码分析--Reactor模型（二）](https://www.cnblogs.com/huxipeng/p/10733563.html)