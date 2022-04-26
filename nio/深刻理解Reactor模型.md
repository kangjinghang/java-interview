# 1. 前言

在web服务中，处理web请求通常有两种体系结构，分别为：**thread-based architecture（基于线程的架构）、event-driven architecture（事件驱动模型）**



# 2. thread-based architecture（基于线程的架构）

也就是我们常说的传统I/O模型架构。对于传统的I/O通信方式来说，客户端连接到服务端，服务端接收客户端请求并响应的流程为：读取 -> 解码 -> 应用处理 -> 编码 -> 发送结果。服务端为每一个客户端连接新建一个线程，建立通道，从而处理后续的请求，也就是BIO的方式。

<img src="http://blog-1259650185.cosbj.myqcloud.com/img/202109/23/1632372433" alt="图片" style="zoom:75%;" />

这种模式一定程度上极大地提高了服务器的吞吐量，由于在不同线程中，之前的请求在read阻塞以后，不会影响到后续的请求。但是，仅适用于于并发量不大的场景，因为：

- 线程需要占用一定的内存资源
- 创建和销毁线程也需一定的代价
- 操作系统在切换线程也需要一定的开销
- 线程处理I/O，在等待输入或输出的这段时间处于空闲的状态，同样也会造成cpu资源的浪费

在客户端数量不断增加的情况下，对于连接和请求的响应会急剧下降，并且占用太多线程浪费资源，线程数量也不是没有上限的，会遇到各种瓶颈。虽然可以使用线程池进行优化，但是依然有诸多问题，比如在线程池中所有线程都在处理请求时，无法响应其他的客户端连接；每个客户端依旧需要专门的服务端线程来服务，线程在处理某个连接的 `read` 操作时，如果遇到没有数据可读，就会发生阻塞，那么线程就没办法继续处理其他连接的业务。

要解决这一个问题，最简单的方式就是将 socket 改成非阻塞，然后线程不断地轮询调用 `read` 操作来判断是否有数据，这种方式虽然该能够解决阻塞的问题，但是解决的方式比较粗暴，因为轮询是要消耗 CPU 的，而且随着一个 线程处理的连接越多，轮询的效率就会越低。

上面的问题在于，线程并不知道当前连接是否有数据可读，从而需要每次通过 `read` 去试探。

那有没有办法在只有当连接上有数据的时候，线程才去发起读请求呢？答案是有的，实现这一技术的就是 I/O 多路复用。

I/O 多路复用技术会用一个系统调用函数来监听我们所有关心的连接，也就说可以在一个监控线程里面监控很多的连接。

我们熟悉的 select/poll/epoll 就是内核提供给用户态的多路复用系统调用，线程可以通过一个系统调用函数从内核中获取多个事件。

**select/poll/epoll 是如何获取网络事件的呢**？

在获取事件时，先把我们要关心的连接传给内核，再由内核检测：

- 如果没有事件发生，线程只需阻塞在这个系统调用，而无需像前面的线程池方案那样轮训调用 read 操作来判断是否有数据。
- 如果有事件发生，内核会返回产生了事件的连接，线程就会从阻塞状态返回，然后在用户态中再处理这些连接对应的业务即可。

# 3. event-driven architecture（事件驱动模型）

事件驱动体系结构是目前比较广泛使用的一种。这种方式会定义一系列的事件处理器来响应事件的发生，并且将**服务端接受连接**与**对事件的处理**分离。其中，**事件是一种状态的改变**。比如，tcp中socket的new incoming connection、ready for read、ready for write。

Reactor模式和Proactor模式都是是event-driven architecture（事件驱动模型）的实现方式，下面聊一聊这两种模式。

## 3.1 Reactor模式

当下开源软件能做到网络高性能的原因就是 I/O 多路复用吗？

是的，基本是基于 I/O 多路复用，用过 I/O 多路复用接口写网络程序的同学，肯定知道是面向过程的方式写代码的，这样的开发的效率不高。于是，大佬们基于面向对象的思想，对 I/O 多路复用作了一层封装，让使用者不用考虑底层网络 API 的细节，只需要关注应用代码的编写。

大佬们还为这种模式取了个让人第一时间难以理解的名字：**Reactor 模式**。

Reactor模式也叫Dispatcher模式，即I/O多路复用统一监听事件，收到事件后分发（Dispatch给某进程/线程），这是编写高性能网络服务器的必备技术之一。维基百科对`Reactor pattern`的解释：

> The reactor design pattern is an event handling pattern for handling service requests delivered concurrently to a service handler by one or more inputs. The service handler then demultiplexes the incoming requests and dispatches them synchronously to the associated request handlers.

从这个描述中，我们知道Reactor模式**首先是事件驱动的，有一个或多个并发输入源，有一个Service Handler，有多个Request Handlers**；Service Handler会对输入的请求（Event）进行多路复用，并同步地将它们分发给相应的Request Handler。

下面的图将直观地展示上述文字描述：

<img src="http://blog-1259650185.cosbj.myqcloud.com/img/202109/23/1632372748.jpg" alt="img" />

Reactor模式以NIO为底层支持，核心组成部分包括Reactor和Handler：

- Reactor：Reactor在一个单独的线程中运行，负责监听和分发事件，分发给适当的处理程序来对I/O事件做出反应。它就像公司的电话接线员，它接听来自客户的电话并将线路转移到适当的联系人。
- Handlers：处理程序执行I/O事件要完成的实际事件，Reactor通过调度适当的处理程序来响应 I/O 事件，处理程序执行非阻塞操作。类似于客户想要与之交谈的公司中的实际员工。

根据Reactor的数量和Handler线程数量，可以将Reactor分为三种模型，Reactor模式可以分为三种不同的方式，下面一一介绍。

- 单线程模型 (单Reactor单线程)
- 多线程模型 (单Reactor多线程)
- 主从多线程模型 (多Reactor多线程) 

### 3.1.1 单线程模式

Java中的NIO模式的Selector网络通讯，其实就是一个简单的Reactor模型。可以说是单线程的Reactor模式。

<img src="http://blog-1259650185.cosbj.myqcloud.com/img/202109/23/1632377297" alt="图片" style="zoom: 67%;" />

<img src="http://blog-1259650185.cosbj.myqcloud.com/img/202109/23/1632382492.jpg" alt="img" style="zoom: 50%;" />

<img src="http://blog-1259650185.cosbj.myqcloud.com/img/202109/23/1632401836.jpg" alt="preview" style="zoom:40%;" />

可以看到进程里有 **Reactor、Acceptor、Handler** 这三个对象：

- Reactor 对象的作用是监听和分发事件；
- Acceptor 对象的作用是获取连接；
- Handler 对象的作用是处理业务；

对象里的 select、accept、read、send 是系统调用函数，dispatch 和 「业务处理」是需要完成的操作，其中 dispatch 是分发事件操作。

接下来，介绍下「单线程模型」这个方案：

1. Reactor对象通过 select （IO 多路复用接口） 监听事件，收到事件后通过dispatch进行分发，具体分发给 Acceptor 对象还是 Handler 对象，还要看收到的事件类型。
2. 如果是连接建立的事件，则由Acceptor处理，Acceptor通过accept 方法接受连接，并创建一个Handler来处理连接后续的各种事件。
3. 如果是读写事件，直接调用连接对应的Handler来处理。
4. Handler完成read -> (decode -> compute -> encode) ->send的业务流程。

这种模型好处是简单，坏处却很明显，第一个是，因为只有一个线程，**无法充分利用 多核 CPU 的性能**。第二个是，当某个Handler阻塞时，会导致其他客户端的handler和accpetor都得不到执行，无法做到高性能，只适用于业务处理非常快速的场景，如redis读写操作。

所以，单 Reactor 单进程的方案**不适用计算机密集型的场景，只适用于业务处理非常快速的场景**。

Redis 是由 C 语言实现的，它采用的正是「单 Reactor 单进程」的方案，因为 Redis 业务处理主要是在内存中完成，操作的速度是很快的，性能瓶颈不在 CPU 上，所以 Redis 对于命令的处理是单进程的方案。

Reactor的单线程模式的单线程主要是针对于I/O操作而言，也就是所以的I/O的accept()、read()、write()以及connect()操作都在一个线程上完成的。

但在目前的单线程Reactor模式中，不仅I/O操作在该Reactor线程上，连非I/O的业务操作也在该线程上进行处理了，这可能会大大延迟I/O请求的响应。所以我们应该将非I/O的业务逻辑操作从Reactor线程上卸载，以此来加速Reactor线程对I/O请求的响应。

### 3.1.2 多线程模型

<img src="http://blog-1259650185.cosbj.myqcloud.com/img/202109/23/1632379227" alt="图片" style="zoom:67%;" />

<img src="http://blog-1259650185.cosbj.myqcloud.com/img/202109/23/1632382520.jpg" alt="img" style="zoom:50%;" />

<img src="http://blog-1259650185.cosbj.myqcloud.com/img/202109/23/1632402314.jpg" alt="img" style="zoom:40%;" />

与单线程模式不同的是，添加了一个**业务线程池**，并将非I/O操作从Reactor线程中移出转交给业务线程池（Thread Pool）来执行。这样能够提高Reactor线程的I/O响应，不至于因为一些耗时的业务逻辑而延迟对后面I/O请求的处理。

具体实现方案是：

1. Reactor对象通过 select （IO 多路复用接口） 监听事件，收到事件后通过dispatch进行分发，具体分发给 Acceptor 对象还是 Handler 对象，还要看收到的事件类型。
2. 如果是连接建立的事件，则由Acceptor处理，Acceptor通过accept 方法接受连接，并创建一个Handler来处理连接后续的各种事件。
3. 如果是读写事件，直接调用连接对应的Handler来处理。

上面的三个步骤和单 Reactor 单线程方案是一样的，接下来的步骤就开始不一样了。

Handler 对象不再负责业务处理，只负责数据的接收和发送。也就是只进行read读取数据和write写出数据，业务处理交给业务线程池进行处理。

业务线程池分配一个线程完成真正的业务处理，然后将响应结果交给主线程的Handler处理，Handler将结果send给client。

多线程的方案优势在于**能够充分利用多核 CPU 的能**，那既然引入多线程，那么自然就带来了多线程竞争资源的问题。

例如，子线程完成业务处理后，要把结果传递给主线程的 Reactor 进行发送，这里涉及共享数据的竞争。

要避免多线程由于竞争共享资源而导致数据错乱的问题，就需要在操作共享资源前加上互斥锁，以保证任意时间里只有一个线程在操作共享资源，待该线程操作完释放互斥锁后，其他线程才有机会操作共享数据。

聊完单 Reactor 多线程的方案，接着来看看单 Reactor 多进程的方案。

事实上，单 Reactor 多进程相比单 Reactor 多线程实现起来很麻烦，主要因为要考虑子进程 <-> 父进程的双向通信，并且父进程还得知道子进程要将数据发送给哪个客户端。

而多线程间可以共享数据，虽然要额外考虑并发问题，但是这远比进程间通信的复杂度低得多，因此实际应用中也看不到单 Reactor 多进程的模式。

另外，虽然非I/O操作交给了线程池来处理，但是**单Reactor既要处理IO操作请求，又要响应连接请求**，而当我们的服务端遇到大量的客户端同时进行连接，或者在请求连接时执行一些耗时操作，比如身份认证，权限检查等，这种瞬时的高并发就容易成为性能瓶颈。所以，对于Reactor的优化，又产生出下面的多线程模式。

### 3.1.3 主从多线程模型

<img src="http://blog-1259650185.cosbj.myqcloud.com/img/202109/23/1632379289" alt="图片" style="zoom:67%;" />

<img src="http://blog-1259650185.cosbj.myqcloud.com/img/202109/23/1632382582.jpg" alt="img" style="zoom:50%;" />

<img src="http://blog-1259650185.cosbj.myqcloud.com/img/202109/23/1632402672.jpg" alt="img" style="zoom:40%;" />

对于多个CPU的机器，为充分利用系统资源，将Reactor拆分为两部分：mainReactor和subReactor。

存在多个Reactor，**每个Reactor都有自己的Selector选择器，线程和dispatch**。

方案详细说明如下：

- 主线程中的 MainReactor 对象通过 select 监控连接建立事件，用来处理网络新连接的建立，收到事件后通过 Acceptor 对象中的 accept 获取连接，将新的连接分配给某个子线程，通常mainReactor一个线程就可以处理。
- 子线程中的 SubReactor 对象将 MainReactor 对象分配的连接加入 select 继续进行监听，并创建一个 Handler 用于处理后续网络数据读写事件，通常使用**多线程**。
- 如果有新的事件发生时，SubReactor 对象会调用当前连接对应的 Handler 对象来进行响应。
- Handler 对象通过 read -> 业务处理 -> send 的流程来完成完整的业务流程。
- 对非I/O的操作，依然转交给业务线程池（Thread Pool）执行。

此种模型中，每个模块的工作更加专一，耦合度更低，性能和稳定性也大量的提升，支持的可并发客户端数量可达到上百万级别。关于此种模型的应用，目前有很多优秀的框架已经在应用了，比如mina和netty 等。

多 Reactor 多线程的方案虽然看起来复杂的，但是实际实现时比单 Reactor 多线程的方案要简单的多，原因如下：

- 主线程和子线程分工明确，主线程只负责接收新连接，子线程负责完成后续的业务处理。
- 主线程和子线程的交互很简单，主线程只需要把新连接传给子线程，子线程无须返回数据，直接就可以在子线程将处理结果发送给客户端。

大名鼎鼎的两个开源软件 Netty 和 Memcache 都采用了「多 Reactor 多线程」的方案。

采用了「多 Reactor 多进程」方案的开源软件是 Nginx，不过方案与标准的多 Reactor 多进程有些差异。

具体差异表现在主进程中仅仅用来初始化 socket，并没有创建 mainReactor 来 accept 连接，而是由子进程的 Reactor 来 accept 连接，通过锁来控制一次只有一个子进程进行 accept（防止出现惊群现象），子进程 accept 新连接后就放到自己的 Reactor 进行处理，不会再分配给其他子进程。

## 3.2 Proactor模式

异步 I/O 比同步 I/O 性能更好，因为异步 I/O 在「内核数据准备好」和「数据从内核空间拷贝到用户空间」这两个过程都不用等待。

Proactor 正是采用了异步 I/O 技术，所以被称为异步网络模型。

现在我们再来理解 Reactor 和 Proactor 的区别，就比较清晰了。

- **Reactor 是非阻塞同步网络模式，感知的是就绪可读写事件**。在每次感知到有事件发生（比如可读就绪事件）后，就需要应用进程主动调用 read 方法来完成数据的读取，也就是要应用进程主动将 socket 接收缓存中的数据读到应用进程内存中，这个过程是同步的，读取完数据后应用进程才能处理数据。
- **Proactor 是异步网络模式， 感知的是已完成的读写事件**。在发起异步读写请求时，需要传入数据缓冲区的地址（用来存放结果数据）等信息，这样系统内核才可以自动帮我们把数据的读写工作完成，这里的读写工作全程由操作系统来做，并不需要像 Reactor 那样还需要应用进程主动发起 read/write 来读写数据，操作系统完成读写工作后，就会通知应用进程直接处理数据。

因此，**Reactor 可以理解为「来了事件操作系统通知应用进程，让应用进程来处理」**，而 **Proactor 可以理解为「来了事件操作系统来处理，处理完再通知应用进程」**。这里的「事件」就是有新连接、有数据可读、有数据可写的这些 I/O 事件这里的「处理」包含从驱动读取到内核以及从内核读取到用户空间。

举个实际生活中的例子，Reactor 模式就是快递员在楼下，给你打电话告诉你快递到你家小区了，你需要自己下楼来拿快递。而在 Proactor 模式下，快递员直接将快递送到你家门口，然后通知你。

无论是 Reactor，还是 Proactor，都是一种基于「事件分发」的网络编程模式，区别在于 **Reactor 模式是基于「待完成」的 I/O 事件，而 Proactor 模式则是基于「已完成」的 I/O 事件**。

接下来，一起看看 Proactor 模式的示意图：

<img src="http://blog-1259650185.cosbj.myqcloud.com/img/202109/23/1632410287.jpg" alt="img" style="zoom:50%;" />

介绍一下 Proactor 模式的工作流程：

- Proactor Initiator 负责创建 Proactor 和 Handler 对象，并将 Proactor 和 Handler 都通过 Asynchronous Operation Processor 注册到内核；
- Asynchronous Operation Processor 负责处理注册请求，并处理 I/O 操作；
- Asynchronous Operation Processor 完成 I/O 操作后通知 Proactor；
- Proactor 根据不同的事件类型回调不同的 Handler 进行业务处理；
- Handler 完成业务处理；

可惜的是，在 Linux 下的异步 I/O 是不完善的， `aio` 系列函数是由 POSIX 定义的异步操作接口，不是真正的操作系统级别支持的，而是在用户空间模拟出来的异步，并且仅仅支持基于本地文件的 aio 异步操作，网络编程中的 socket 是不支持的，这也使得基于 Linux 的高性能网络程序都是使用 Reactor 方案。

而 Windows 里实现了一套完整的支持 socket 的异步编程接口，这套接口就是 `IOCP`，是由操作系统级别实现的异步 I/O，真正意义上异步 I/O，因此在 Windows 里实现高性能网络程序可以使用效率更高的 Proactor 方案。

## 3.3 Reactor模式和Proactor模式的总结对比

### 3.3.1 主动和被动

以主动写为例：

- Reactor将handler放到select()，等待可写就绪，然后调用write()写入数据；写完数据后再处理后续逻辑；
- Proactor调用aoi_write后立刻返回，由内核负责写操作，写完后调用相应的回调函数处理后续逻辑

**Reactor模式是一种被动的处理**，即有事件发生时被动处理。而**Proator模式则是主动发起异步调用**，然后循环检测完成事件。

### 3.3.2 实现

Reactor实现了一个被动的事件分离和分发模型，服务等待请求事件的到来，再通过不受间断的同步处理事件，从而做出反应；

Proactor实现了一个主动的事件分离和分发模型；这种设计允许多个任务并发的执行，从而提高吞吐量。

所以涉及到文件I/O或耗时I/O可以使用Proactor模式，或使用多线程模拟实现异步I/O的方式。

### 3.3.3 优点

Reactor实现相对简单，对于链接多，但耗时短的处理场景高效；

- 操作系统可以在多个事件源上等待，并且避免了线程切换的性能开销和编程复杂性；
- 事件的串行化对应用是透明的，可以顺序的同步执行而不需要加锁；
- 事务分离：将与应用无关的多路复用、分配机制和与应用相关的回调函数分离开来。

Proactor在**理论上**性能更高，能够处理耗时长的并发场景。为什么说在**理论上**？请自行搜索Netty 5.X版本废弃的原因。

### 3.3.4 缺点

Reactor处理耗时长的操作会造成事件分发的阻塞，影响到后续事件的处理；

Proactor实现逻辑复杂；依赖操作系统对异步的支持，目前实现了纯异步操作的操作系统少，实现优秀的如windows IOCP，但由于其windows系统用于服务器的局限性，目前应用范围较小；而Unix/Linux系统对纯异步的支持有限，应用事件驱动的主流还是通过select/epoll来实现。

### 3.3.5 适用场景

Reactor：同时接收多个服务请求，并且依次同步的处理它们的事件驱动程序；

Proactor：异步接收和同时处理多个服务请求的事件驱动程序。



# 4. netty线程模型

Netty线程模型就是Reactor模式的一个实现，如下图所示：

<img src="http://blog-1259650185.cosbj.myqcloud.com/img/202109/23/1632380852" alt="图片" style="zoom:67%;" />



- EventLoopGroup就相当于是Reactor，bossGroup对应主Reactor，workerGroup对应从Reactor
- xxxServerHandler就是Handler
- child开头的方法配置的是客户端channel，非child开头的方法配置的是服务端channel

## 4.1 线程组

Netty抽象了两组线程池 BossGroup 和 WorkerGroup ，其类型都是 NioEventLoopGroup，BossGroup 用来接受客户端发来的连接，WorkerGroup 则负责对完成TCP三次握手的连接进行处理。

NioEventLoopGroup 里面包含了多个 NioEventLoop，管理 NioEventLoop 的生命周期。每个 NioEventLoop 中包含了一个NIO Selector、一个队列、一个线程；其中线程用来做轮询注册到 Selector 上的 Channel 的读写事件和对投递到队列里面的事件进行处理。

**Boss Group NioEventLoop线程的执行步骤**：

- 处理accept事件, 与client建立连接, 生成NioSocketChannel。

- 将NioSocketChannel注册到某个worker NIOEventLoop上的selector。

- 处理任务队列的任务， 即runAllTasks。

**Worker Group NioEventLoop线程的执行步骤**：

- 轮询注册到自己Selector上的所有NioSocketChannel的read和write事件。

- 处理read和write事件，在对应NioSocketChannel处理业务。

- runAllTasks处理任务队列TaskQueue的任务，一些耗时的业务处理可以放入TaskQueue中慢慢处理，这样不影响数据在pipeline中的流动处理。

Worker NIOEventLoop处理NioSocketChannel业务时，使用了pipeline (管道)，管道中维护了handler处理器链表，用来处理 channel 中的数据。

## 4.2 ChannelPipeline

Netty 将 Channel 的数据管道抽象为 ChannelPipeline ，消息在 ChannelPipline 中流动和传递。 ChannelPipeline 持有I/O事件拦截器ChannelHandler 的双向链表，由 ChannelHandler 对I/O事件进行拦截和处理，可以方便的新增和删除 ChannelHandler 来实现不同的业务逻辑定制，不需要对已有的 ChannelHandler 进行修改，能够实现对修改封闭和对扩展的支持。

ChannelPipeline 是一系列的 ChannelHandler 实例，流经一个 Channel 的入站和出站事件可以被 ChannelPipeline 拦截。每当一个新的 Channel 被创建了，都会建立一个新的 ChannelPipeline 并绑定到该 Channel 上，这个关联是永久性的；Channel 既不能附上另一个ChannelPipeline 也不能分离当前这个。这些都由Netty负责完成，而无需开发人员的特别处理。

根据起源,一个事件将由 ChannelInboundHandler 或 ChannelOutboundHandler 处理，ChannelHandlerContext 实现转发或传播到下一个 ChannelHandler。一个 ChannelHandler 处理程序可以通知 ChannelPipeline 中的下一个 ChannelHandler 执行。Read事件（入站事件）和write事件（出站事件）使用相同的 pipeline，入站事件会从链表 head 往后传递到最后一个入站的 handler，出站事件会从链表 tail 往前传递到最前一个出站的 handler，两种类型的 handler 互不干扰。

<img src="http://blog-1259650185.cosbj.myqcloud.com/img/202109/23/1632381369" alt="图片" style="zoom:67%;" />

ChannelInboundHandler回调方法：

| 回调方法            | 触发时机                                                     | client | server |
| ------------------- | ------------------------------------------------------------ | ------ | ------ |
| channelRegistered   | 当前channel注册到EventLoop                                   | true   | true   |
| channelUnregistered | 当前channel从EventLoop取消注册                               | true   | true   |
| channelActive       | 当前channel激活的时候                                        | true   | true   |
| channellnactive     | 当前channel不活跃的时候，也就是true当前channel到了它生命周期末 | true   | true   |
| channelRead         | 当前channel从远端读取到数据                                  | true   | true   |
| channelReadComplete | channel read消费完读取的数据的时候被触发                     | true   | true   |

ChannelOutboundHandler回调方法：

| 回调方法   | 触发时机                 | client | server |
| ---------- | ------------------------ | ------ | ------ |
| bind       | bind操作执行前触发       | false  | true   |
| connect    | connect操作执行前触发    | true   | false  |
| disconnect | disconnect操作执行前触发 | true   | false  |
| close      | close操作执行前触发      | false  | true   |
| read       | read操作执行前触发       | true   | true   |
| write      | write操作执行前触发      | true   | true   |
| flush      | flush操作执行前触发      | true   | true   |

## 4.3 异步非阻塞

**写操作**：通过 NioSocketChannel 的 write 方法向连接里面写入数据时候是非阻塞的，马上会返回，即使调用写入的线程是我们的业务线程。Netty 通过在 ChannelPipeline 中判断调用 NioSocketChannel 的 write 的调用线程是不是其对应的 NioEventLoop 中的线程，**如果发现不是，则会把写入请求封装为 WriteTask 投递到其对应的 NioEventLoop 中的队列里面**，然后等其对应的 NioEventLoop 中的线程轮询读写事件时候，将其从队列里面取出来执行。

**读操作**：当从 NioSocketChannel 中读取数据时候，并不是需要业务线程阻塞等待，而是等 NioEventLoop 中的 IO 轮询线程发现Selector 上有数据就绪时，通过事件通知方式来通知业务数据已就绪，可以来读取并处理了。

每个 NioSocketChannel 对应的读写事件都是在其对应的 NioEventLoop 管理的单线程内执行，对同一个 NioSocketChannel 不存在并发读写，所以无需加锁处理。

使用 Netty 框架进行网络通信时，当我们发起 I/O 请求后会马上返回，而不会阻塞我们的业务调用线程；如果想要获取请求的响应结果，也不需要业务调用线程使用阻塞的方式来等待，而是当响应结果出来的时候，使用 I/O 线程异步通知业务的方式，所以在整个请求 -> 响应过程中业务线程不会由于阻塞等待而不能干其他事情。 



# 参考

[Java 开发必备！ I/O与Netty原理精讲](https://mp.weixin.qq.com/s/K9Oyn0cbwqVCh1j3N5bd_w)

[高性能IO模型分析-Reactor模式和Proactor模式（二）](https://zhuanlan.zhihu.com/p/95662364)

[网络 IO 演变过程](https://zhuanlan.zhihu.com/p/353692786)

[高性能Server - Reactor模型](http://www.linkedkeeper.com/132.html)

[如何深刻理解Reactor和Proactor？ - 小林coding的回答 - 知乎](https://www.zhihu.com/question/26943938/answer/1856426252)