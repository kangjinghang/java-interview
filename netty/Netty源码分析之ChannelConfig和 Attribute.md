本文与其说是ChannelConfig、Attribute源码解析，不如说是对ChannelConfig以及Attribute结构层次的分析。因为这才是它们在Netty中使用到的重要之处。

## ChannelConfig

当我们在构建NioServerSocketChannel的时候同时会构建一个NioServerSocketChannelConfig对象赋值给NioServerSocketChannel的成员变量config。

而这一个NioServerSocketChannelConfig是当前NioServerSocketChannel配置属性的集合。NioServerSocketChannelConfig主要用于对NioServerSocketChannel相关配置的设置(如，网络的相关参数配置)，比如，配置Channel是否为非阻塞、配置连接超时时间等等。

下面我们来对NioServerSocketChannelConfig的结构做个详细介绍：

<img src="http://blog-1259650185.cosbj.myqcloud.com/img/202112/25/1640364837.png" alt="NioServerSocketChannelConfig" style="zoom:50%;" />

NioServerSocketChannelConfig其实是一个ChannelConfig实例。ChannelConfig表示为一个Channel相关的配置属性的集合。所以NioServerSocketChannelConfig就是针对于NioServerSocketChannel的配置属性的集合。

ChannelConfig是Channel所需的公共配置属性的集合，如，setAllocator(设置用于channel分配buffer的分配器)。而不同类型的网络传输对应的Channel有它们自己特有的配置，因此可以通过扩展ChannelConfig来补充特有的配置，如，ServerSocketChannelConfig是针对基于TCP连接的服务端ServerSocketChannel相关配置属性的集合，它补充了针对TCP服务端所需的特有配置的设置setBacklog、setReuseAddress、setReceiveBufferSize。

DefaultChannelConfig作为ChannelConfig的默认实现，对ChannelConfig中的配置提供了默认值。

接下来，我们来看一个设置ChannelConfig的流程：

`serverBootstrap.option(ChannelOption.SO_REUSEADDR, true);`

我们可以在启动服务端前通过ServerBootstrap来进行相关配置的设置，该选项配置会在Channel初始化时被获取并设置到Channel中，最终会调用底层ServerSocket.setReuseAddress方法来完成配置的设置。

ServerBootstrap的init()方法：

```java
// AbstractBootstrap.java
@Override
void init(Channel channel) {
  setChannelOptions(channel, newOptionsArray(), logger); // 初始化 option
  ...
}  

static void setChannelOptions(
        Channel channel, Map.Entry<ChannelOption<?>, Object>[] options, InternalLogger logger) {
    for (Map.Entry<ChannelOption<?>, Object> e: options) {
        setChannelOption(channel, e.getKey(), e.getValue(), logger);
    }
}
```

取出我们程序设定的options(即，LinkedHashMap对象)，依次遍历options中的key-value对，将其设置到channel中。

```java
// DefaultChannelConfig.java
@Override
@SuppressWarnings("deprecation")
public <T> boolean setOption(ChannelOption<T> option, T value) {
    validate(option, value);

    if (option == CONNECT_TIMEOUT_MILLIS) {
        setConnectTimeoutMillis((Integer) value);
    } else if (option == MAX_MESSAGES_PER_READ) {
        setMaxMessagesPerRead((Integer) value);
    } else if (option == WRITE_SPIN_COUNT) {
        setWriteSpinCount((Integer) value);
    } else if (option == ALLOCATOR) {
        setAllocator((ByteBufAllocator) value);
    } else if (option == RCVBUF_ALLOCATOR) {
        setRecvByteBufAllocator((RecvByteBufAllocator) value);
    } else if (option == AUTO_READ) {
        setAutoRead((Boolean) value);
    } else if (option == AUTO_CLOSE) {
        setAutoClose((Boolean) value);
    } else if (option == WRITE_BUFFER_HIGH_WATER_MARK) {
        setWriteBufferHighWaterMark((Integer) value);
    } else if (option == WRITE_BUFFER_LOW_WATER_MARK) {
        setWriteBufferLowWaterMark((Integer) value);
    } else if (option == WRITE_BUFFER_WATER_MARK) {
        setWriteBufferWaterMark((WriteBufferWaterMark) value);
    } else if (option == MESSAGE_SIZE_ESTIMATOR) {
        setMessageSizeEstimator((MessageSizeEstimator) value);
    } else if (option == SINGLE_EVENTEXECUTOR_PER_GROUP) {
        setPinEventExecutorPerGroup((Boolean) value);
    } else if (option == MAX_MESSAGES_PER_WRITE) {
        setMaxMessagesPerWrite((Integer) value);
    } else {
        return false;
    }

    return true;
}

protected <T> void validate(ChannelOption<T> option, T value) {
    ObjectUtil.checkNotNull(option, "option").validate(value);
}
```

首先对option和value进行校验，其实就是进行非空校验。

然后判断对应的是哪个常量属性，并进行相应属性的设置。如果传进来的ChannelOption不是已经设定好的常量属性，则会打印一条警告级别的日志，告知这是未知的channel option。

Netty提供ChannelOption的一个主要的功能就是让特定的变量的值给类型化。因为从`ChannelOption<T> option`和`T value`可以看出，我们属性的值类型T，是取决于ChannelOption的泛型的，也就属性值类型是由属性来决定的。

## ChannelOption

这里，我们可以看到有个ChannelOption类，它允许以类型安全的方式去配置一个ChannelConfig。支持哪一种ChannelOption取决于ChannelConfig的实际的实现并且也可能取决于它所属的传输层的本质。

<img src="http://blog-1259650185.cosbj.myqcloud.com/img/202112/25/1640365711.png" alt="ChannelOption" style="zoom: 67%;" />

可见ChannelOption是一个Consant扩展类，Consant是Netty提供的一个单例类，它能安全去通过’==’来进行比较操作。通过ConstantPool进行管理和创建。

常量由一个id和name组成。id：表示分配给常量的唯一数字；name：表示常量的名字。

## ConstantPool

如上所说，Constant是由ConstantPool来进行管理和创建的，那么ConstantPool又是个什么样的类了？

ConstantPool是Netty提供的一个常量池类，它底层通过一个成员变量constants来维护所有的常量：

```java
// ConstantPool.java
public abstract class ConstantPool<T extends Constant<T>> {

    private final ConcurrentMap<String, T> constants = PlatformDependent.newConcurrentHashMap();
  	...
}  
```

constants：底层就是Java的ConcurrentHashMap对象。

并通过下面的代码来实现的线程安全。主要通过ConcurrentHashMap的putIfAbsent来实现线程安全。

```java
// ConstantPool.java
private T getOrCreate(String name) {
    T constant = constants.get(name);
    if (constant == null) {
        final T tempConstant = newConstant(nextId(), name);
        constant = constants.putIfAbsent(name, tempConstant);
        if (constant == null) {
            return tempConstant;
        }
    }

    return constant;
}
```

首先从constants中get这个name对应的常量，如果不存在则调用newConstant()来构建这个常量tempConstant，然后在调用constants.putIfAbsent方法来实现“如果该name没有存在对应的常量，则插入，否则返回该name所对应的常量。(这整个的过程都是原子性的)”，因此我们是根据putIfAbsent方法的返回来判断该name对应的常量是否已经存在于constants中的。如果返回为null，则说明当前创建的tempConstant就为name所对应的常量；否则，将putIfAbsent返回的name已经对应的常量值返回。(注意，因为ConcurrentHashMap不会允许value为null的情况，所以我们可以根据putIfAbsent返回为null则代表该name在此之前并未有对应的常量值)

## ChannelOption类中属性

好了，到目前为止，我们已经知道ChannelOption是一个Constant的扩展，因此它可以由ConstantPool来管理和创建。接下来，我们继续来看看ChannelOption类中的一些重要属性：

```java
// ChannelOption.java
public class ChannelOption<T> extends AbstractConstant<ChannelOption<T>> {

    private static final ConstantPool<ChannelOption<Object>> pool = new ConstantPool<ChannelOption<Object>>() {
        @Override
        protected ChannelOption<Object> newConstant(int id, String name) {
            return new ChannelOption<Object>(id, name);
        }
    };
  	...
}  
```

正如我们前面所说的，这个`ConstantPool<ChannelOption<Object>> pool`(即，ChannelOption常量池)是ChannelOption的一个私有静态成员属性，用于管理和创建ChannelOption。

同时，ChannelOption中将所有的与相关的配置项名称都已常量形式定义好了。如：

```java
// ChannelOption.java
public static final ChannelOption<Boolean> SO_BROADCAST = valueOf("SO_BROADCAST");
public static final ChannelOption<Boolean> SO_KEEPALIVE = valueOf("SO_KEEPALIVE");
public static final ChannelOption<Integer> SO_SNDBUF = valueOf("SO_SNDBUF");
public static final ChannelOption<Integer> SO_RCVBUF = valueOf("SO_RCVBUF");
public static final ChannelOption<Boolean> SO_REUSEADDR = valueOf("SO_REUSEADDR");
public static final ChannelOption<Integer> SO_LINGER = valueOf("SO_LINGER");
public static final ChannelOption<Integer> SO_BACKLOG = valueOf("SO_BACKLOG");
public static final ChannelOption<Integer> SO_TIMEOUT = valueOf("SO_TIMEOUT");
```

这些定义好的ChannelOption常量都已经存储数到ChannelOption的常量池(ConstantPool)中了。

**注意，ChannelOption本身并不维护选项值的信息，它只是维护选项名字本身。比如，`public static final ChannelOption<Integer> SO_RCVBUF = valueOf("SO_RCVBUF");`，这只是维护了“SO_RCVBUF”这个选项名字的信息，同时泛型表示选择值类型，即“SO_RCVBUF”选项值为Integer。**

好了，到目前为止，我们对Netty的ChannelOption的设置以及底层的实现已经分析完了，简单的来说：Netty在初始化Channel时会构建一个ChannelConfig对象，而ChannelConfig是Channel配置属性的集合。比如，Netty在初始化NioServerSocketChannel的时候同时会构建一个NioServerSocketChannelConfig对象，并将其赋值给NioServerSocketChannel的成员变量config，而这个config(NioServerSocketChannelConfig)维护了NioServerSocketChannel的所有配置属性。比如，NioServerSocketChannelConfig提供了setConnectTimeoutMillis方法来设置NioServerSocketChannel连接超时的时间。

同时，程序可以通过ServerBootstrap或Boostrap的option(`ChannelOption<T> option, T value`)方法来实现配置的设置。这里，我们通过ChannelOption来实现配置的设置，ChannelOption中已经将常用的配置项预定义为了常量供我们直接使用，同时ChannelOption的一个主要的功能就是让特定的变量的值给类型化。因为从`ChannelOption<T> option`和`T value`可以看出，我们属性的值类型T，是取决于ChannelOption的泛型的，也就属性值类型是由属性来决定的。

## Attribute

一个attribute允许存储一个值的引用。它可以被自动的更新并且是线程安全的。

其实Attribute就是一个属性对象，这个属性的名称为`AttributeKey<T> key`，而属性的值为T value。

我们可以通过程序ServerBootstrap或Boostrap的attr方法来设置一个Channel的属性，如：

`serverBootstrap.attr(AttributeKey.valueOf("userID"), UUID.randomUUID().toString());`

当Netty底层初始化Channel的时候，就会将我们设置的attribute给设置到Channel中：

```java
// AbstractBootstrap.java
static void setAttributes(Channel channel, Map.Entry<AttributeKey<?>, Object>[] attrs) {
    for (Map.Entry<AttributeKey<?>, Object> e: attrs) {
        @SuppressWarnings("unchecked")
        AttributeKey<Object> key = (AttributeKey<Object>) e.getKey();
        channel.attr(key).set(e.getValue());
    }
}
```

如上面所说，Attribute就是一个属性对象，这个属性的名称为`AttributeKey<T> key`，而属性的值为`T value`。

而AttributeKey也是Constant的一个扩展，因此也有一个ConstantPool来管理和创建，这和ChannelOption是类似的。

Channel类本身继承了AttributeMap类，而AttributeMap它持有多个Attribute，这些Attribute可以通过AttributeKey来访问的。所以，才可以通过channel.attr(key).set(value)的方式将属性设置到channel中了(即，这里的attr方法实际上是AttributeMap接口中的方法)。

**AttributeKey、Attribute、AttributeMap间的关系：**
AttributeMap相对于一个map，AttributeKey相当于map的key，Attribute是一个持有key(AttributeKey)和value的对象。因此在map中我们可以通过AttributeKey key获取Attribute，从而获取Attribute中的value(即，属性值)。

**关于ChannelHandlerContext.attr(..) 和 Channel.attr(..)**

Q：ChannelHandlerContext和Channel都提供了attr方法，那么它们设置的属性作用域有什么不同了？

A：在Netty 4.1版本之前，它们两设置的属性作用域确实存在着不同，但从Netty 4.1版本开始，它们两设置的属性的作用域已经完全相同了。

<img src="http://blog-1259650185.cosbj.myqcloud.com/img/202112/25/1640366964.png" alt="Netty4.1版本新特性及注意" style="zoom:50%;" />

从上面的描述上，我们可以知道从Netty 4.1 开始 “ChannelHandlerContext.attr(..) == Channel.attr(..)”。即放入它们的attribute的作用域是一样的了。每个Channel内部指保留一个AttributeMap。

而在Netty4.1之前，Channel内部保留有一个AttributeMap，而每个ChannelHandlerContext内部又保留有它们自己的AttributeMap，这样通过Channel.attr()放入的属性，是无法通过ChannelHandlerContext.attr()得到的，反之亦然。这种行为不仅令人困惑还会浪费内存。因此有了Netty 4.1将attr作用域统一的做法。

## 参考

[Netty 源码解析 ——— ChannelConfig 和 Attribute](https://www.jianshu.com/p/39ec11d38e32)
