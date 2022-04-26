# 1. 操作系统是如何定义I/O的

**I/O**相关的操作，顾名思义也就是**Input/Output**，对应着**Read/Write** 读写两个动作，但是在上层系统应用中无论是读还是写，**操作系统都不会直接的操作物理机磁盘数据**，而是由系统内核加载磁盘数据。

我们以Read为例，当程序中发起了一个Read请求后，操作系统会将数据从内核缓冲区加载到用户缓冲区，如果内核缓冲区内没有数据，内核会将该次读请求追加到请求队列，当内核将磁盘数据读取到内核缓冲区后，再次执行读请求，将内核缓冲区的数据复制到用户缓冲区，继而返回给上层应用程序。

write请求也是类似于上面的情况，用户进程写入到用户缓冲区，复制到内核缓冲区，然后当数据到达一定量级之后由内核写入到网口或者磁盘文件。

# 2. 网络编程中的IO模型

## 2.1 同步阻塞I/O

### 2.1.1 传统的阻塞IO模型

<img src="http://blog-1259650185.cosbj.myqcloud.com/img/202109/22/1632279366.png" alt="image-20210922105606588" style="zoom:50%;" />

这种模型是单线程应用，服务端监听客户端连接，当监听到客户端的连接后立即去做业务逻辑的处理，**该次请求没有处理完成之前**，服务端接收到的其他连接**全部阻塞不可操作**。当然开发中，我们也不会这样写，这种写法只会存在于协议demo中。这种写法的缺陷在哪呢？

我们看图发现，当一个新连接被接入后，其他客户端的连接全部处于阻塞状态，那么当该客户端处理客户端时间过长的时候，会导致阻塞的客户端连接越来越多导致系统崩溃，我们是否能够找到一个办法，**使其能够将业务处理与Accept接收新连接分离开来**。这样业务处理不影响新连接接入就能够解决该问题。

### 2.1.2 伪异步阻塞IO模型

<img src="http://blog-1259650185.cosbj.myqcloud.com/img/202109/22/1632279466.png" alt="image-20210922105746155" style="zoom:50%;" />

这种业务模型是是对上一步单线程模型的一种优化，当一个新连接接入后，获取到这个链接的**Socket**,交给一条新的线程去处理，主程序继续接收下一个新连接，这样就能够解决同一时间只能处理一个新连接的问题，但是，明眼人都能看出来，这样有一个很致命的问题，这种模型处理小并发短时间可能不会出现问题，但是假设有10w连接接入，我需要开启10w个线程，这样会把系统直接压崩。我们需要**限制线程的数量**，那么肯定就会想到**线程池**，我们来优化一下这个模型吧。

### 2.1.3 优化伪异步阻塞IO模型

<img src="http://blog-1259650185.cosbj.myqcloud.com/img/202109/22/1632279565.png" alt="image-20210922105925844" style="zoom:50%;" />

这个模型是JDK1.4之前，没有NIO的时候的一个经典Socket模型，服务端接收到客户端新连接好后，将Socket连接以及业务逻辑包装为任务提交到线程池，由线程池开始执行，同时服务端继续接收新连接。这样能够解决上一步因为线程爆炸所引发的问题，但是我们回想下线程池的的提交步骤：**当核心线程池满了之后会将任务放置到队列，当队列满了之后，会占用最大线程数的数量继续开启线程，当达到最大线程数的时候开始拒绝策略。** 证明我最大的并发数只有1500个，其余的都在队列里面占1024个，假设现在的连接数是1w个，并且使用的是丢弃策略，那么会有近6000的连接任务被丢弃掉，而且1500个线程，线程之间的切换也是一个特别大的开销。这是一个致命的问题！



**上述的三种模型除了有上述的问题之外，还有一个特别致命的问题，他是阻塞的！**

在哪里阻塞的呢？

- 连接的时候，当没有客户端连接的时候是阻塞的。没有客户端连接的时候，线程只能傻傻的阻塞在哪里等待新连接接入。
- 等待数据写入的时候是阻塞的，当一个新连接接入后但是不写入数据，那么线程会一直等待数据写入，直到数据写入完成后才会停止阻塞。 假设我们使用 **优化后的伪异步线程模型** ，1000个连接可能只有 100个连接会频繁写入数据，剩余900个连接都很少写入，那么就会有900个线程在傻傻等待客户端写入数据，所以，这也是一个很严重的性能开销。

**现在我们总结一下上述模型的问题：**

1. 线程开销浪费严重
2. 线程间的切换频繁，效率低下
3. read/write执行的时候会进行阻塞
4. accept会阻塞等待新连接

**那么，我们是否有一种方案，用很少的线程去管理成千上万的连接，read/write会阻塞进程**，那么就会进入到下面的模型。

## 2.2 同步非阻塞I/O

同步非阻塞I/O模型就必须使用java NIO来实现了，看一段简单的代码：

```java
public static void main(String[] args) throws IOException {
    // 新接连池
    List<SocketChannel> socketChannelList = new ArrayList<>(8);
    // 开启服务端Socket
    ServerSocketChannel serverSocketChannel = ServerSocketChannel.open();
    serverSocketChannel.bind(new InetSocketAddress(8098));
    // 设置为非阻塞
    serverSocketChannel.configureBlocking(false);
    while (true) {
        // 探测新连接，由于设置了非阻塞，这里即使没有新连接也不会阻塞，而是直接返回null
        SocketChannel socketChannel = serverSocketChannel.accept();
        // 当返回值不为null的时候，证明存在新连接
        if(socketChannel!=null){
            System.out.println("新连接接入");
            // 将客户端设置为非阻塞  这样read/write不会阻塞
            socketChannel.configureBlocking(false);
            // 将新连接加入到线程池
            socketChannelList.add(socketChannel);
        }
        // 迭代器遍历连接池
        Iterator<SocketChannel> iterator = socketChannelList.iterator();
        while (iterator.hasNext()) {
            ByteBuffer byteBuffer = ByteBuffer.allocate(128);
            SocketChannel channel = iterator.next();
            // 读取客户端数据 当客户端数据没有写入完成的时候也不会阻塞，长度为0
            int read = channel.read(byteBuffer);

            if(read > 0) {
                // 当存在数据的时候打印数据
                System.out.println(new String(byteBuffer.array()));
            }else if(read == -1) {
                // 客户端退出的时候删除该连接
                iterator.remove();
                System.out.println("断开连接");
            }
        }
    }
}
```

上述代码我们可以看到一个关键的逻辑：`serverSocketChannel.configureBlocking(false);` 这里被设置为非阻塞的时候无论是 accept还是read/write都不会阻塞。我们看一下这种的实现逻辑有什么问题：

<img src="http://blog-1259650185.cosbj.myqcloud.com/img/202109/22/1632279898.png" alt="image-20210922110458547" style="zoom:50%;" />

看这里，我们似乎的确使用了一条线程处理了所有的连接以及读写操作，但是假设我们有10w连接，活跃连接（经常read/write）只有1000，但是我们这个线程需要每次要轮询10w条数据处理，极大的消耗了CPU。

**我们期待什么？期待的是，每次轮询值轮询有数据的Channel，没有数据的就不管他，比如刚刚的例子，只有1000个活跃连接，那么每次就只轮询这1000个，其他的有读写了有数据就轮询，没读写就不轮询。**

## 2.3 多路复用模型

多路复用模型是JAVA NIO 推荐使用的经典模型，内部通过 Selector进行事件选择，Selector事件选择通过系统实现，具体流程看一段代码:

```java

public static void main(String[] args) throws IOException {
    //开启服务端Socket
    ServerSocketChannel serverSocketChannel = ServerSocketChannel.open();
    serverSocketChannel.bind(new InetSocketAddress(8098));
    // 设置为非阻塞
    serverSocketChannel.configureBlocking(false);
    // 开启一个选择器
    Selector selector = Selector.open();
    serverSocketChannel.register(selector, SelectionKey.OP_ACCEPT);
    while (true) {
        // 阻塞等待需要处理的事件发生
        selector.select();
        // 获取selector中注册的全部事件的 SelectionKey 实例
        Set<SelectionKey> selectionKeys = selector.selectedKeys();
        // 获取已经准备完成的key
        Iterator<SelectionKey> iterator = selectionKeys.iterator();
        while (iterator.hasNext()) {
            SelectionKey next = iterator.next();
            // 当发现连接事件
            if(next.isAcceptable()) {
                // 获取客户端连接
                SocketChannel socketChannel = serverSocketChannel.accept();
                // 设置非阻塞
                socketChannel.configureBlocking(false);
                // 将该客户端连接注册进选择器 并关注读事件
                socketChannel.register(selector, SelectionKey.OP_READ);
                // 如果是读事件
            }else if(next.isReadable()){
                ByteBuffer allocate = ByteBuffer.allocate(128);
                // 获取与此key唯一绑定的channel
                SocketChannel channel = (SocketChannel) next.channel();
                // 开始读取数据
                int read = channel.read(allocate);
                if(read > 0){
                    System.out.println(new String(allocate.array()));
                }else if(read == -1){
                    System.out.println("断开连接");
                    channel.close();
                }
            }
            // 删除这个事件
            iterator.remove();
        }
    }
}
```

相比上面的同步非阻塞IO，这里多了一个selector选择器，能够对关注不同事件的Socket进行注册，后续如果关注的事件满足了条件的话，就将该socket放回到到里面，等待客户端轮询。

<img src="http://blog-1259650185.cosbj.myqcloud.com/img/202109/22/1632280028.png" alt="image-20210922110708264" style="zoom:50%;" />

NIO底层在JDK1.4版本是用linux的内核函数select()或poll()来实现，跟上面的NioServer代码类似，selector每次都会轮询所有的sockchannel看下哪个channel有读写事件，有的话就处理，没有就继续遍历，JDK1.5开始引入了epoll基于事件响应机制来优化NIO，首先我们会将我们的SocketChannel注册到对应的选择器上并选择关注的事件，后续操作系统会根据我们设置的感兴趣的事件将完成的事件SocketChannel放回到选择器中，等待用户的处理。那么它能够解决上述的问题吗？

肯定是可以的，因为**上面的一个同步非阻塞I/O痛点在于CPU总是在做很多无用的轮询**，在这个模型里被解决了。这个模型从selector中获取到的Channel全部是就绪的，后续只需要也就是说他**每次轮询都不会做无用功。**

# 3. 深入多路复用模型概念解析

select，poll，epoll都是IO多路复用的机制。I/O多路复用就是通过一种机制，一个进程可以监视多个描述符，一旦某个描述符就绪（一般是读就绪或者写就绪），能够通知程序进行相应的读写操作。但select，poll，epoll本质上都是同步I/O，因为他们都需要在读写事件就绪后自己负责进行读写，也就是说这个读写过程是阻塞的，而异步I/O则无需自己负责进行读写，异步I/O的实现会负责把数据从内核拷贝到用户空间。

从宏观上如果系统要对外提供一个进程可以监控多个连接的方法的话，那么实现这个方法需要考虑的问题主要是下面几条，而select、poll、epoll 他们的不同之处也都是围绕着这几点展开的：

1. 系统如何知道进程需要监控哪些连接和事件（也就是fd）。
2. 系统知道进程需要监控的连接和事件后，采用什么方式去对fd进行状态的监控。
3. 系统监控到活跃事件后如何通知进程。

## 3.1 select模型

```cpp
int select (int n, fd_set *readfds, fd_set *writefds, fd_set *exceptfds, struct timeval *timeout);
```

select 函数监视的文件描述符分3类，分别是writefds、readfds、和exceptfds。调用后select函数会阻塞，直到有描述符就绪（有数据 可读、可写、或者有except），或者超时（timeout指定等待时间，如果立即返回设为null即可），函数返回。当select函数返回后，可以 通过遍历fdset，来找到就绪的描述符。

应用进程想要通过select 去监控多个连接（也就是fd）的话需要经向大概如下的流程：

1. 在调用select之前告诉select 应用进程需要监控哪些fd可读、可写、异常事件，这些分别都存在一个fd_set数组中。

2. 然后应用进程调用select的时候把3个fd_set（writefds、readfds、和exceptfds）传给内核（这里也就产生了一次fd_set在用户空间到内核空间的复制），内核收到fd_set后对fd_set进行遍历，然后一个个去扫描对应fd是否满足可读写事件。

   <img src="http://blog-1259650185.cosbj.myqcloud.com/img/202109/22/1632289484.png" alt="image-20210922134444443" style="zoom:50%;" />

3. 如果发现了有对应的fd有读写事件后，内核会把fd_set里没有事件状态的fd句柄清除，然后把有事件的fd返回给应用进程（这里又会把fd_set从内核空间复制用户空间）。

4. 最后应用进程收到了select返回的活跃事件类型的fd句柄后，再向对应的fd发起数据读取或者写入数据操作。

   <img src="http://blog-1259650185.cosbj.myqcloud.com/img/202109/22/1632289560.png" alt="image-20210922134600377" style="zoom:50%;" />

通过上面的图我想你已经大概了解了select的工作模式，select 提供一种可以用一个进程监控多个网络连接的方式，但也还遗留了一些问题，这些问题也是后来select面对高并发环境的性能瓶颈。

1、每调用一次select 就需要3个事件类型的fd_set需从用户空间拷贝到内核空间去，返回时select也会把保留了活跃事件的fd_set返回(从内核拷贝到用户空间)。当fd_set数据大的时候，这个过程消耗是很大的。

2、select需要逐个遍历fd_set集合 ，然后去检查对应fd的可读写状态，如果fd_set 数据量多，那么遍历fd_set 就是一个比较耗时的过程。

3、fd_set是个集合类型的数据结构有长度限制，32位系统长度1024,62位系统长度2048，这个就限制了select最多能同时监控1024个连接。



首先我们需要了解操作系统有一个叫做**工作队列**的概念，由CPU轮流执行工作队列里面的进程，我们平时书写的Socket服务端客户端程序也是存在于工作队列的进程中，只要它存在于工作队列，它就会被CPU调用执行。我们下文将该网络程序称之为**进程A**。

<img src="http://blog-1259650185.cosbj.myqcloud.com/img/202109/22/1632285854.png" alt="image-20210922124414072" style="zoom:50%;" />



他的内部会维护一个 Socket列表，当调用系统函数`select(socket[])`的时候，操作系统会将**进程A**加入到Socket列表中的每一个Socket的等待队列中，同时将**进程A**从工作队列移除，此时，**进程A**处于阻塞状态。

<img src="http://blog-1259650185.cosbj.myqcloud.com/img/202109/22/1632285951.png" alt="image-20210922124551920" style="zoom:50%;" />

当网卡接收到数据之后，触发操作系统的中断程序，根据该程序的Socket端口取对应的Socket列表中寻找该**进程A**，并将**进程A**从所有的Socket列表中的等待队列移除，并加入到操作系统的工作队列。

<img src="http://blog-1259650185.cosbj.myqcloud.com/img/202109/22/1632286016.png" alt="image-20210922124656560" style="zoom:50%;" />



此时进程A被唤醒，此时知道至少有一个Socket存在数据，开始依次遍历所有的Socket，寻找存在数据的Socket并进行后续的业务操作。

<img src="http://blog-1259650185.cosbj.myqcloud.com/img/202109/22/1632286039.png" alt="image-20210922124719831" style="zoom:50%;" />

**该种结构的核心思想是，我先让所有的Socket都持有这个进程A的引用，当操作系统触发Socket中断之后，基于端口寻找到对应的Socket,就能够找到该Socket对应的进程，再基于进程，就能够找到所有被监控的Socket。要注意，当进程A被唤醒，就证明一件事，操作系统发生了Socket中断，就至少有一个Socket的数据准备就绪，只需要将所有的Socket遍历，就能够找到并处理本次客户端传入的数据！**

但是，你会发现，这种操作极为繁琐，中间存在了很多次遍历，先将进程A加入的所有的Socket等待队列需要遍历一次，发生中断之后需要遍历一次Socket列表，将所有对于进程A的引用移除，并将进程A的引用加入到工作队列。因为此时进程A并不知道哪一个Socket是有数据的，所以，由需要再次遍历一遍Socket列表，才能真正的处理数据，整个操作总共遍历了3次Socket，为了保证性能，所以1.4版本中，最多只能监控1024个Socket，去掉标准输出输出和错误输出只剩下1021个，因为如果Socket过多势必造成每次遍历消耗性能极大。

select目前几乎在所有的平台上支持，其良好跨平台支持也是它的一个优点。select的一 个缺点在于单个进程能够监视的文件描述符的数量存在最大限制，在Linux上一般为1024，可以通过修改宏定义甚至重新编译内核的方式提升这一限制，但是这样也会造成效率的降低。

## 3.2 poll模型

在早期计算机网络并不发达，所以并发网络请求并不会很高，select模型也足够使用了，但是随着网络的高速发展，高并发的网络请求程序越来越多，而select模式下 fd_set 长度限制就开始成为了致命的缺陷。

吸取了select的教训，poll模式就不再使用数组的方式来保存自己所监控的fd信息了，poll模型里面通过使用链表的形式来保存自己监控的fd信息，正是这样poll模型里面是没有了连接限制，可以支持高并发的请求。

和select还有一点不同的是保存在链表里的需要监控的fd信息采用的是pollfd的文件格式，select 调用返回的fd_set是只包含了上次返回的活跃事件的fd_set集合，下一次调用select又需要把这几个fd_set清空，重新添加上自己感兴趣的fd和事件类型，而poll采用的pollfd 保存着对应fd需要监控的事件集合，也保存了一个激活事件的fd集合。 所以重新发请求时不需要重置感兴趣的事件类型参数。

```cpp
int poll (struct pollfd *fds, unsigned int nfds, int timeout);
```

不同与select使用三个位图来表示三个fdset的方式，poll使用一个 pollfd的指针实现。

```cpp
struct pollfd {
    int fd; /* file descriptor，文件描述符*/
    short events; /* requested events to watch ，注册的事件*/
    short revents; /* returned events witnessed，实际发生的事件，由内核填充 */
};
```

pollfd结构包含了要监视的event和发生的event，不再使用select“参数-值”传递的方式。同时，pollfd并没有最大数量限制（但是数量过大后性能也是会下降）。 和select函数一样，poll返回后，需要轮询pollfd来获取就绪的描述符。

> 从上面看，select和poll都需要在返回后，`通过遍历文件描述符来获取已经就绪的socket`。事实上，同时连接的大量客户端在一时刻可能只有很少的处于就绪状态，因此随着监视的描述符数量的增长，其效率也会线性下降。

## 3.3 epoll模型

epoll是在2.6内核中提出的，是之前的select和poll的增强版本。相对于select和poll来说，epoll更加灵活，没有描述符限制。epoll使用一个文件描述符管理多个描述符，使用**红黑树**(RB-tree)**搜索**被监视的**文件描述符**(file descriptor)，将用户关系的文件描述符的事件存放到内核的一个事件表中，这样在用户空间和内核空间的copy只需一次。

在 epoll 实例上**注册事件**时，epoll 会将该**事件添加到** epoll 实例的**红黑树**上并**注册一个回调函数**，当**事件发生时**会将事件**添加到就绪链表**中。

epoll操作过程需要三个接口，分别如下：

```cpp
int epoll_create(int size)；// 创建一个epoll的句柄，size用来告诉内核这个监听的数目一共有多大
int epoll_ctl(int epfd, int op, int fd, struct epoll_event *event)；
int epoll_wait(int epfd, struct epoll_event * events, int maxevents, int timeout);
```

**epoll_create** 对应JDK NIO代码中的**Selector.open()**

**epoll_ctl** 对应JDK NIO代码中的**socketChannel.register(selector,xxxx);**

**epoll_wait** 对应JDK NIO代码中的 **selector.select();**

### 3.3.1 epoll_create：创建内核事件表

```cpp
int epoll_create(int size)；// 创建一个epoll的句柄，size用来告诉内核这个监听的数目一共有多大
```

这里主要是向内核申请**创建一个epoll的句柄**，作为**内核事件表**（红黑树结构的文件，没有数量限制），这个句柄用来保存应用进程需要监控哪些fd和对应类型的事件。

当创建好epoll句柄后，它就会占用一个fd值，在linux下如果查看/proc/进程id/fd/，是能够看到这个fd的，所以在使用完epoll后，必须调用close()关闭，否则可能导致fd被耗尽。

size用来告诉内核这个监听的数目一共有多大，这个参数不同于select()中的第一个参数，给出最大监听的fd+1的值，参数size并不是限制了epoll所能监听的描述符最大个数，只是对内核初始分配内部数据结构的一个建议。

<img src="http://blog-1259650185.cosbj.myqcloud.com/img/202109/22/1632292070.png" alt="image-20210922142750238" style="zoom:35%;" />

内核事件表是一个eventpoll结构体，这个结构体中有两个成员与epoll的使用方式密切相关。eventpoll结构体如下所示：

```cpp
struct eventpoll{
    ....
    /*红黑树的根节点，这颗树中存储着所有添加到epoll中的需要监控的事件*/
    struct rb_root  rbr;
    /*双链表中则存放着将要通过epoll_wait返回给用户的满足条件的事件*/
    struct list_head rdlist;
    ....
};
```

### 3.3.2 epoll_ctl：添加、修改或移除监控的fd和事件类型

```cpp
int epoll_ctl(int epfd, int op, int fd, struct epoll_event *event)；
```

函数是对指定描述符fd执行op操作。

- epfd：是epoll_create()的返回值。
- op：表示op操作，用三个宏来表示：添加EPOLL_CTL_ADD，删除EPOLL_CTL_DEL，修改EPOLL_CTL_MOD。分别添加、删除和修改对fd的监听事件。
- fd：是需要监听的fd（文件描述符）
- epoll_event：是告诉内核需要监听什么事件，struct epoll_event结构如下：

```cpp
struct epoll_event {
  __uint32_t events;  /* Epoll events */
  epoll_data_t data;  /* User data variable */
};

// events可以是以下几个宏的集合：
EPOLLIN ：表示对应的文件描述符可以读（包括对端SOCKET正常关闭）；
EPOLLOUT：表示对应的文件描述符可以写；
EPOLLPRI：表示对应的文件描述符有紧急的数据可读（这里应该表示有带外数据到来）；
EPOLLERR：表示对应的文件描述符发生错误；
EPOLLHUP：表示对应的文件描述符被挂断；
EPOLLET： 将EPOLL设为边缘触发(Edge Triggered)模式，这是相对于水平触发(Level Triggered)来说的。
EPOLLONESHOT：只监听一次事件，当监听完这次事件之后，如果还需要继续监听这个socket的话，需要再次把这个socket加入到EPOLL队列里
```

例如：

```cpp
struct epoll_event ev;
//设置与要处理的事件相关的文件描述符
ev.data.fd=listenfd;
//设置要处理的事件类型
ev.events=EPOLLIN|EPOLLET;
//注册epoll事件
epoll_ctl(epfd,EPOLL_CTL_ADD,listenfd,&ev);
```

调用此函数可以是向内核的**内核事件表**动态的添加、修改和移除fd 和对应事件类型。

<img src="http://blog-1259650185.cosbj.myqcloud.com/img/202109/22/1632292367.png" alt="image-20210922143246991" style="zoom:50%;" />



### 3.3.3 epoll_wait：绑定回调事件

```cpp
int epoll_wait(int epfd, struct epoll_event * events, int maxevents, int timeout);
```

等待epfd上的io事件，最多返回maxevents个事件。
参数events用来从内核得到事件的集合，maxevents告之内核这个events有多大，这个maxevents的值不能大于创建epoll_create()时的size，参数timeout是超时时间（毫秒，0会立即返回；-1将不确定，也有说法说是永久阻塞，直到任意已注册的事件变为就绪；当 timeout 为一正整数时，epoll 会阻塞直到计时结束或已注册的事件变为就绪。因为内核调度延迟，阻塞的时间可能会略微超过 timeout （毫秒级））。该函数返回需要处理的事件数目，如返回0表示已超时。

**接收发生在被监听的描述符上的，用户感兴趣的IO事件。简单点说：通过循环，不断地监听暴露的端口，看哪一个fd可读、可写。**

epoll文件描述符用完后，直接用**close**关闭，并且会**自动**从被监听的文件描述符集合中删除。

内核向事件表的fd绑定一个回调函数。

<img src="http://blog-1259650185.cosbj.myqcloud.com/img/202109/22/1632292438.png" alt="image-20210922143358315" style="zoom:50%;" />

当监控的fd活跃时，会调用callback函数把事件加到一个活跃事件队列里；

<img src="http://blog-1259650185.cosbj.myqcloud.com/img/202109/22/1632292936.png" alt="image-20210922144216617" style="zoom:50%;" />

最后在epoll_wait 返回的时候内核会把活跃事件队列里的fd和事件类型返回给应用进程。

<img src="http://blog-1259650185.cosbj.myqcloud.com/img/202109/22/1632292976.png" alt="image-20210922144256155" style="zoom:50%;" />

最后，从epoll整体思路上来看，采用事先就在内核创建一个事件监听表，后面只需要往里面添加移出对应事件，因为本身事件表就在内核空间，所以就避免了向select、poll一样每次都要把自己需要监听的事件列表传输过去，然后又传回来，这也就避免了事件信息需要在用户空间和内核空间相互拷贝的问题。

然后epoll并不是像select一样去遍历事件列表，然后逐个轮询的监控fd的事件状态，而是事先就建立了fd与之对应的回调函数，当事件激活后主动回调callback函数，这也就避免了遍历事件列表的这个操作，所以epoll并不会像select和poll一样随着监控的fd变多而效率降低，这种事件机制也是epoll要比select和poll高效的主要原因。

### 3.4 工作模式

epoll对文件描述符的操作有两种模式：**LT（level trigger）**和**ET（edge trigger）**。LT模式是默认模式，LT模式与ET模式的区别如下：
　　**LT模式**：当epoll_wait检测到描述符事件发生并将此事件通知应用程序，**应用程序可以不立即处理该事件**。下次调用epoll_wait时，会再次响应应用程序并通知此事件。
　　**ET模式**：当epoll_wait检测到描述符事件发生并将此事件通知应用程序，**应用程序必须立即处理该事件**。如果不处理，下次调用epoll_wait时，不会再次响应应用程序并通知此事件。

#### LT模式

LT(level triggered)是缺省的工作方式，并且同时支持block和no-block socket。在这种做法中，内核告诉你一个文件描述符是否就绪了，然后你可以对这个就绪的fd进行IO操作。如果你不作任何操作，下一次内核还是会继续通知你的。

#### ET模式

ET(edge-triggered)是高速工作方式，只支持no-block socket。在这种模式下，当描述符从未就绪变为就绪时，内核通过epoll告诉你。然后它会假设你知道文件描述符已经就绪，并且不会再为那个文件描述符发送更多的就绪通知，直到你做了某些操作导致那个文件描述符不再为就绪状态了(比如，你在发送，接收或者接收请求，或者发送接收的数据少于一定量时导致了一个EWOULDBLOCK 错误）。但是请注意，如果一直不对这个fd作IO操作(从而导致它再次变成未就绪)，内核不会发送更多的通知(only once)

**ET模式在很大程度上减少了epoll事件被重复触发的次数，因此效率要比LT模式高**。epoll工作在ET模式的时候，必须使用非阻塞套接字，以避免由于一个文件句柄的阻塞读/阻塞写操作把处理多个文件描述符的任务饿死。

#### 总结

**假如有这样一个例子：**

1. 我们已经把一个用来从管道中读取数据的文件句柄(RFD)添加到epoll描述符
2. 这个时候从管道的另一端被写入了2KB的数据
3. 调用epoll_wait(2)，并且它会返回RFD，说明它已经准备好读取操作
4. 然后我们读取了1KB的数据
5. 调用epoll_wait(2)......

**LT模式：**
如果是LT模式，那么在第5步调用epoll_wait(2)之后，仍然能受到通知。

**ET模式：**
如果我们在第1步将RFD添加到epoll描述符的时候使用了EPOLLET标志，那么在第5步调用epoll_wait(2)之后将**有可能会挂起**，因为剩余的数据还存在于文件的输入缓冲区内，而且数据发出端还在等待一个针对已经发出数据的反馈信息。只有在监视的文件句柄上发生了某个事件的时候 ET 工作模式才会汇报事件。因此在第5步的时候，调用者可能会放弃等待仍在存在于文件输入缓冲区内的剩余数据。

当使用epoll的ET模型来工作时，当产生了一个EPOLLIN事件后，
读数据的时候需要考虑的是当recv()返回的大小如果等于请求的大小，那么很有可能是缓冲区还有数据未读完，也意味着该次事件还没有处理完，所以还需要再次读取：

```cpp
while(rs){
  buflen = recv(activeevents[i].data.fd, buf, sizeof(buf), 0);
  if(buflen < 0){
    // 由于是非阻塞的模式,所以当errno为EAGAIN时,表示当前缓冲区已无数据可读
    // 在这里就当作是该次事件已处理处.
    if(errno == EAGAIN){
        break;
    }
    else{
        return;
    }
  }
  else if(buflen == 0){
     // 这里表示对端的socket已正常关闭.
  }

 if(buflen == sizeof(buf){
      rs = 1;   // 需要再次读取
 }
 else{
      rs = 0;
 }
}
```

**Linux中的EAGAIN含义**

Linux环境下开发经常会碰到很多错误(设置errno)，其中EAGAIN是其中比较常见的一个错误(比如用在非阻塞操作中)。
从字面上来看，是提示再试一次。这个错误经常出现在当应用程序进行一些非阻塞(non-blocking)操作(对文件或socket)的时候。

例如，以 O_NONBLOCK的标志打开文件/socket/FIFO，如果你连续做read操作而没有数据可读。此时程序不会阻塞起来等待数据准备就绪返回，read函数会返回一个错误EAGAIN，提示你的应用程序现在没有数据可读请稍后再试。
又例如，当一个系统调用(比如fork)因为没有足够的资源(比如虚拟内存)而执行失败，返回EAGAIN提示其再调用一次(也许下次就能成功)。

### 3.5 代码演示

下面是一段不完整的代码且格式不对，意在表述上面的过程，去掉了一些模板代码。

```cpp
#define IPADDRESS   "127.0.0.1"
#define PORT        8787
#define MAXSIZE     1024
#define LISTENQ     5
#define FDSIZE      1000
#define EPOLLEVENTS 100

// 绑定端口，返回绑定端口的fd
listenfd = socket_bind(IPADDRESS,PORT);

// 监听事件集合
struct epoll_event events[EPOLLEVENTS];

// 创建一个描述符，作为内核事件表
epollfd = epoll_create(FDSIZE);

// 向内核时间表添加监听描述符事件
// 监听绑定端口描述符的EPOLLIN事件     
add_event(epollfd,listenfd,EPOLLIN);

// 循环等待
for ( ; ; ){
    // 该函数返回已经准备好的描述符事件数目
    ret = epoll_wait(epollfd,events,EPOLLEVENTS,-1);
    // 处理接收到的连接
    handle_events(epollfd,events,ret,listenfd,buf);
}

// 事件处理函数，epollfd：内核事件表，events：需要监听的事件集合（我们监听了什么事件）
static void handle_events(int epollfd,struct epoll_event *events,int num,int listenfd,char *buf)
{
     int i;
     int fd;
     // 进行遍历;这里只要遍历已经准备好的io事件。num并不是当初epoll_create时的FDSIZE，而是准备好的FDSIZE
     for (i = 0;i < num;i++)
     {
         // 要监听的fd
         fd = events[i].data.fd;
         // 根据描述符的类型和事件类型进行处理
         if ((fd == listenfd) &&(events[i].events & EPOLLIN))
            // 有连接进来了
            handle_accpet(epollfd,listenfd);
         else if (events[i].events & EPOLLIN)
            // 客户端描述符收到了 EPOLLIN 可读事件
            do_read(epollfd,fd,buf);
         else if (events[i].events & EPOLLOUT)
            // 客户端描述符收到了 EPOLLOUT 可写事件
            do_write(epollfd,fd,buf);
     }
}

// 添加事件，epollfd：内核事件表，fd：需要监听的文件描述符，state：监听什么事件，EPOLLIN、EPOLLOUT...
static void add_event(int epollfd,int fd,int state){
    struct epoll_event ev;
    ev.events = state;
    // 需要监听的文件描述符保存到了 epoll_event
    ev.data.fd = fd;
    epoll_ctl(epollfd,EPOLL_CTL_ADD,fd,&ev);
}

// 处理接收到的连接
static void handle_accpet(int epollfd,int listenfd){
     int clifd;     
     struct sockaddr_in cliaddr;     
     socklen_t  cliaddrlen;  
  	 // 创建一个客户端描述符 
     clifd = accept(listenfd,(struct sockaddr*)&cliaddr,&cliaddrlen);     
     if (clifd == -1)         
     perror("accpet error:");     
     else {         
         printf("accept a new client: %s:%d\n",inet_ntoa(cliaddr.sin_addr),cliaddr.sin_port);                       				 // 监听客户端描述符的EPOLLIN事件         
         add_event(epollfd,clifd,EPOLLIN);     
     } 
}

// 读处理
static void do_read(int epollfd,int fd,char *buf){
    int nread;
    nread = read(fd,buf,MAXSIZE);
    if (nread == -1)     {         
        perror("read error:");         
        close(fd); // 记住close fd        
        delete_event(epollfd,fd,EPOLLIN); //删除监听 
    }
    else if (nread == 0)     {         
        fprintf(stderr,"client close.\n");
        close(fd); // 记住close fd       
        delete_event(epollfd,fd,EPOLLIN); //删除监听 
    }     
    else {         
        printf("read message is : %s",buf);        
        // 修改客户端描述符对应的事件，由可读改为可写         
        modify_event(epollfd,fd,EPOLLOUT);     
    } 
}

// 写处理
static void do_write(int epollfd,int fd,char *buf) {     
    int nwrite;     
    nwrite = write(fd,buf,strlen(buf));     
    if (nwrite == -1){         
        perror("write error:");        
        close(fd);   // 记住close fd       
        delete_event(epollfd,fd,EPOLLOUT);  //删除监听    
    }else{
        // 修改客户端描述符对应的事件，由可写改为可读        
        modify_event(epollfd,fd,EPOLLIN); 
    }    
    memset(buf,0,MAXSIZE); 
}

// 删除事件
static void delete_event(int epollfd,int fd,int state) {
    struct epoll_event ev;
    ev.events = state;
    ev.data.fd = fd;
    epoll_ctl(epollfd,EPOLL_CTL_DEL,fd,&ev);
}

// 修改事件
static void modify_event(int epollfd,int fd,int state){     
    struct epoll_event ev;
    ev.events = state;
    ev.data.fd = fd;
    epoll_ctl(epollfd,EPOLL_CTL_MOD,fd,&ev);
}

// 注：另外一端我就省了
```

相对比较正规的代码：

```cpp
int epfd = epoll_create(POLL_SIZE);
    struct epoll_event ev;
    struct epoll_event *events = NULL;
    nfds = epoll_wait(epfd, events, 20, 500);
    {
        for (n = 0; n < nfds; ++n) {
            if (events[n].data.fd == listener) {
                // 如果是主socket的事件的话，则表示
                // 有新连接进入了，进行新连接的处理。
                client = accept(listener, (structsockaddr *)&local, &addrlen);
                if (client < 0) {
                    perror("accept");
                    continue;
                }
                setnonblocking(client);        // 将新连接置于非阻塞模式
                ev.events = EPOLLIN | EPOLLET; // 并且将新连接也加入EPOLL的监听队列。
                // 注意，这里的参数EPOLLIN|EPOLLET并没有设置对写socket的监听，
                // 如果有写操作的话，这个时候epoll是不会返回事件的，如果要对写操作
                // 也监听的话，应该是EPOLLIN|EPOLLOUT|EPOLLET
                ev.data.fd = client;
                if (epoll_ctl(epfd, EPOLL_CTL_ADD, client, &ev) < 0) {
                    // 设置好event之后，将这个新的event通过epoll_ctl加入到epoll的监听队列里面，
                    // 这里用EPOLL_CTL_ADD来加一个新的epoll事件，通过EPOLL_CTL_DEL来减少一个
                    // epoll事件，通过EPOLL_CTL_MOD来改变一个事件的监听方式。
                    fprintf(stderr, "epollsetinsertionerror:fd=%d", client);
                    return -1;
                }
            }
            else if(event[n].events & EPOLLIN)
            {
                // 如果是已经连接的用户，并且收到数据，
                // 那么进行读入
                int sockfd_r;
                if ((sockfd_r = event[n].data.fd) < 0)
                    continue;
                read(sockfd_r, buffer, MAXSIZE);
                // 修改sockfd_r上要处理的事件为EPOLLOUT
                ev.data.fd = sockfd_r;
                ev.events = EPOLLOUT | EPOLLET;
                epoll_ctl(epfd, EPOLL_CTL_MOD, sockfd_r, &ev)
            }
            else if(event[n].events & EPOLLOUT)
            {
                // 如果有数据发送
                int sockfd_w = events[n].data.fd;
                write(sockfd_w, buffer, sizeof(buffer));
                // 修改sockfd_w上要处理的事件为EPOLLIN
                ev.data.fd = sockfd_w;
                ev.events = EPOLLIN | EPOLLET;
                epoll_ctl(epfd, EPOLL_CTL_MOD, sockfd_w, &ev)
            }
            do_use_fd(events[n].data.fd);
        }
    }
```

简单说下流程：

- 监听到有新连接进入了，进行新连接的处理；
- 如果是已经连接的用户，并且收到数据，读完之后修改sockfd_r上要处理的事件为EPOLLOUT（可写）；
- 如果有数据发送，写完之后，修改sockfd_w上要处理的事件为EPOLLIN（可读）

### 3.6 总结

在 select/poll中，进程只有在调用一定的方法后，内核才对所有监视的文件描述符进行扫描，而**epoll事先通过epoll_ctl()来注册一个文件描述符，一旦基于某个文件描述符就绪时，内核会采用类似callback的回调机制，迅速激活这个文件描述符，当进程调用epoll_wait() 时便得到通知**。(此处去掉了遍历文件描述符，而是通过监听回调的的机制。这正是epoll的魅力所在。)

**epoll的优点主要是一下几个方面：**

1. 监视的描述符数量不受限制，它所支持的FD上限是最大可以打开文件的数目，这个数字一般远大于2048,举个例子,在1GB内存的机器上大约是10万左 右，具体数目可以cat /proc/sys/fs/file-max察看,一般来说这个数目和系统内存关系很大。select的最大缺点就是进程打开的fd是有数量限制的。这对于连接数量比较大的服务器来说根本不能满足。虽然也可以选择多进程的解决方案( Apache就是这样实现的)，不过虽然linux上面创建进程的代价比较小，但仍旧是不可忽视的，加上进程间数据同步远比不上线程间同步的高效，所以也不是一种完美的方案。
2. IO的效率不会随着监视fd的数量的增长而下降。epoll不同于select和poll轮询的方式，而是通过每个fd定义的回调函数来实现的。只有就绪的fd才会执行回调函数。

> 如果没有大量的idle -connection或者dead-connection，epoll的效率并不会比select/poll高很多，但是当遇到大量的idle- connection，就会发现epoll的效率大大高于select/poll。这是因为在内核实现中epoll是根据**每个fd上面的callback**函数实现的。那么，**只有“活跃”的socket才会主动的去调用 callback函数**，其他idle（空闲）状态socket则不会，在这点上，epoll实现了一个“伪”AIO，因为这时候推动力在os内核。在一些 benchmark中，如果所有的socket基本上都是活跃的，比如一个高速LAN环境，epoll并不比select/poll有什么效率，相反，如果过多使用epoll_ctl,效率相比还有稍微的下降。但是一旦使用idle connections模拟WAN环境，epoll的效率就远在select/poll之上了。

<img src="http://blog-1259650185.cosbj.myqcloud.com/img/202109/23/1632329151.jpg" alt="img" style="zoom:50%;" />



# 4.NIO中的应用

Java NIO的世界中，**Selector是中央控制器**，**Buffer是承载数据的容器**，而**Channel**可以说是最基础的门面，它是**本地**I/O**设备、**网络I/O**的通信桥梁**。

- 网络I/O设备：

- - DatagramChannel:读写UDP通信的数据，对应DatagramSocket类
  - SocketChannel:读写TCP通信的数据，对应Socket类
  - ServerSocketChannel:监听新的TCP连接，并且会创建一个可读写的SocketChannel，对应ServerSocket类

- 本地I/O设备：

- - FileChannel:读写本地文件的数据,不支持Selector控制，对应File类

**①**先从最简单的ServerSocketChannel看起

`ServerSocketChannel`与`ServerSocket`一样是socket监听器，其主要区别前者可以运行在非阻塞模式下运行；

```java
// 创建一个ServerSocketChannel，将会关联一个未绑定的ServerSocket
public static ServerSocketChannel open() throws IOException {
    return SelectorProvider.provider().openServerSocketChannel();
}
```

`ServerSocketChannel`的创建也是依赖底层操作系统实现，其实现类主要是`ServerSocketChannelImpl`，我们来看看其构造方法

```java
ServerSocketChannelImpl(SelectorProvider var1) throws IOException {
   super(var1);
   // 创建一个文件操作符
   this.fd = Net.serverSocket(true);
   // 得到文件操作符是索引
   this.fdVal = IOUtil.fdVal(this.fd);
   this.state = 0;
}
```

新建一个`ServerSocketChannelImpl`其本质是在底层操作系统创建了一个fd（即文件描述符），相当于建立了一个用于网络通信的通道,调用socket的`bind()`方法绑定,通过accept()调用操作系统获取TCP连接。

```java
public SocketChannel accept() throws IOException {
    // 忽略一些校验及无关代码
    ....

    SocketChannelImpl var2 = null;
    // var3的作用主要是说明当前的IO状态，主要有
    /**
    * EOF = -1;
    * UNAVAILABLE = -2;
    * INTERRUPTED = -3;
    * UNSUPPORTED = -4;
    * THROWN = -5;
    * UNSUPPORTED_CASE = -6;
    */
    int var3 = 0;
    // 这里本质也是用fd来获取连接
    FileDescriptor var4 = new FileDescriptor();
    // 用来存储TCP连接的地址信息
    InetSocketAddress[] var5 = new InetSocketAddress[1];

    try {
        // 这里设置了一个中断器，中断时会将连接关闭
        this.begin();
        // 这里当IO被中断时，会重新获取连接
        do {
            var3 = this.accept(this.fd, var4, var5);
        } while(var3 == -3 && this.isOpen());
    }finally {
        // 当连接被关闭且accept失败时或抛出AsynchronousCloseException
        this.end(var3 > 0);
        // 验证连接是可用的
        assert IOStatus.check(var3);
    }

    if (var3 < 1) {
        return null;
    } {
        // 默认连接是阻塞的
        IOUtil.configureBlocking(var4, true);
        // 创建一个SocketChannel的引用
        var2 = new SocketChannelImpl(this.provider(), var4, var5[0]);
        // 下面是是否连接成功校验，这里忽略...

        return var2;
    }
}

// 依赖底层操作系统实现的accept0方法
private int accept(FileDescriptor var1, FileDescriptor var2, InetSocketAddress[] var3) throws IOException {
    return this.accept0(var1, var2, var3);
}
```

**②**SocketChannel

用于读写TCP通信的数据，相当于客户端

1. 通过**open**方法创建SocketChannel，
2. 然后利用**connect**方法来和服务端发起建立连接，还支持了一些判断连接建立情况的方法；
3. **read**和**write**支持最基本的读写操作

**open**

```java
public static SocketChannel open() throws IOException {    
    return SelectorProvider.provider().openSocketChannel();  
}
public SocketChannel openSocketChannel() throws IOException {
    return new SocketChannelImpl(this);
}
// State, increases monotonically
private static final int ST_UNINITIALIZED = -1;
private static final int ST_UNCONNECTED = 0;
private static final int ST_PENDING = 1;
private static final int ST_CONNECTED = 2;
private static final int ST_KILLPENDING = 3;
private static final int ST_KILLED = 4;
private int state = ST_UNINITIALIZED;    
SocketChannelImpl(SelectorProvider sp) throws IOException {
    super(sp);
    // 创建一个scoket通道，即fd(fd的作用可参考上面的描述)
    this.fd = Net.socket(true);
    // 得到该fd的索引
    this.fdVal = IOUtil.fdVal(fd);
    // 设置为未连接
    this.state = ST_UNCONNECTED;
}
```

**connect建立连接**

```java
// 代码均来自JDK1.8 部分代码
public boolean connect(SocketAddress var1) throws IOException {
    boolean var2 = false;
    // 读写都锁住
    synchronized(this.readLock) {
        synchronized(this.writeLock) {
             /****状态检查，channel和address****/
            // 判断channel是否open
            this.ensureOpenAndUnconnected();
            InetSocketAddress var5 = Net.checkAddress(var1);
            SecurityManager var6 = System.getSecurityManager();
            if (var6 != null) {
                var6.checkConnect(var5.getAddress().getHostAddress(), var5.getPort());
            }

            boolean var10000;
             /****连接建立****/
            // 阻塞状态变更的锁也锁住
            synchronized(this.blockingLock()) {
                int var8 = 0;

                try {
                    try {
                        this.begin(); 
                        // 如果当前socket未绑定本地端口，则尝试着判断和服务端是否能建立连接
                        synchronized(this.stateLock) {
                            if (!this.isOpen()) {
                                boolean var10 = false;
                                return var10;
                            }

                            if (this.localAddress == null) {
                              // 和远程建立连接后关闭连接
                               NetHooks.beforeTcpConnect(this.fd, var5.getAddress(), var5.getPort());
                            }

                            this.readerThread = NativeThread.current();
                        }

                        do {
                            InetAddress var9 = var5.getAddress();
                            if (var9.isAnyLocalAddress()) {
                                var9 = InetAddress.getLocalHost();
                            }
                            // 建立连接
                            var8 = Net.connect(this.fd, var9, var5.getPort());
                        } while(var8 == -3 && this.isOpen());
                synchronized(this.stateLock) {
                    this.remoteAddress = var5;
                    if (var8 <= 0) {
                        if (!this.isBlocking()) {
                            this.state = 1;
                        } else {
                            assert false;
                        }
                    } else {
                        this.state = 2;// 连接成功
                        if (this.isOpen()) {
                            this.localAddress = Net.localAddress(this.fd);
                        }

                        var10000 = true;
                        return var10000;
                    }
                }
            }

            var10000 = false;
            return var10000;
        }
    }
}
```

在建立在绑定地址之前，我们需要调用**NetHooks.beforeTcpBind**，这个方法是将fd转换为SDP(Sockets Direct Protocol，Java套接字直接协议) socket。SDP需要网卡支持InfiniBand高速网络通信技术，windows不支持该协议。

我们来看看在openjdk: src\solaris\classes\sun\net下的NetHooks.java

```java
private static final Provider provider = new sun.net.sdp.SdpProvider();

public static void beforeTcpBind(FileDescriptor fdObj, InetAddress address, int port) throws IOException
{
    provider.implBeforeTcpBind(fdObj, address, port);
}
public static void beforeTcpConnect(FileDescriptor fdObj, InetAddress address, int port) throws IOException
{
    provider.implBeforeTcpConnect(fdObj, address, port);
}   
```

可以看到实际是调用的SdpProvider里的implBeforeTcpBind。

```java
 @Override
    public void implBeforeTcpBind(FileDescriptor fdObj, InetAddress address, int port) throws IOException
    {
        if (enabled)
            convertTcpToSdpIfMatch(fdObj, Action.BIND, address, port);
    }
    // converts unbound TCP socket to a SDP socket if it matches the rules
    private void convertTcpToSdpIfMatch(FileDescriptor fdObj, Action action, InetAddress address,
                                        int port) throws IOException
    {
        boolean matched = false;
        // 主要是先通过规则校验器判断入参是否符合，一般有PortRangeRule校验器
        // 然后再执行将fd转换为socket
        for (Rule rule: rules) {
            if (rule.match(action, address, port)) {
                SdpSupport.convertSocket(fdObj);
                matched = true;
                break;
            }
        }

    }
    public static void convertSocket(FileDescriptor fd) throws IOException {
      ...
      // 获取fd索引
      int fdVal = fdAccess.get(fd);
      convert0(fdVal);
    }


    // convert0
   JNIEXPORT void JNICALL
   Java_sun_net_sdp_SdpSupport_convert0(JNIEnv *env, jclass cls, int fd)
  {
    // create方法实际是通过socket(AF_INET_SDP, SOCK_STREAM, 0);方法得到一个socket
    int s = create(env);

    if (s >= 0) {
        socklen_t len;
        int arg, res;
        struct linger linger;

        /* copy socket options that are relevant to SDP */
        len = sizeof(arg);
        // 重用TIME_WAIT的端口
        if (getsockopt(fd, SOL_SOCKET, SO_REUSEADDR, (char*)&arg, &len) == 0)
            setsockopt(s, SOL_SOCKET, SO_REUSEADDR, (char*)&arg, len);
        len = sizeof(arg);
        // 紧急数据放入普通数据流
        if (getsockopt(fd, SOL_SOCKET, SO_OOBINLINE, (char*)&arg, &len) == 0)
            setsockopt(s, SOL_SOCKET, SO_OOBINLINE, (char*)&arg, len);
        len = sizeof(linger);
        // 延迟关闭连接
        if (getsockopt(fd, SOL_SOCKET, SO_LINGER, (void*)&linger, &len) == 0)
            setsockopt(s, SOL_SOCKET, SO_LINGER, (char*)&linger, len);

        // 将fd也引用到s所持有的通道
        RESTARTABLE(dup2(s, fd), res);
        if (res < 0)
            JNU_ThrowIOExceptionWithLastError(env, "dup2");
        // 执行close方法，关闭s这个引用
        RESTARTABLE(close(s), res);
    }
  }
```

**read 读**

```java
public int read(ByteBuffer var1) throws IOException {
            // 省略一些判断
            synchronized(this.readLock) {
                  this.begin();
                  synchronized(this.stateLock) {
                                do {
                                // 通过IOUtil的读取fd的数据至buf
                                // 这里的nd是SocketDispatcher，用于调用底层的read和write操作
                                    var3 = IOUtil.read(this.fd, var1, -1L, nd);
                                } while(var3 == -3 && this.isOpen());
                                // 这个方法主要是将UNAVAILABLE(原为-2)这个状态返回0，否则返回n
                                var4 = IOStatus.normalize(var3);
                                var20 = false;
                                break label367;
                            }

                             this.readerCleanup();
                             assert IOStatus.check(var3);
                        }    
            }
        }
    }
static int read(FileDescriptor var0, ByteBuffer var1, long var2, NativeDispatcher var4) throws IOException {
        if (var1.isReadOnly()) {
            throw new IllegalArgumentException("Read-only buffer");
        } else if (var1 instanceof DirectBuffer) {
            return readIntoNativeBuffer(var0, var1, var2, var4);
        } else {
    // 临时缓冲区，大小为buf的remain(limit - position)，堆外内存，使用ByteBuffer.allocateDirect(size)分配
    // Notes：这里分配后后面有个try-finally块会释放该部分内存
            ByteBuffer var5 = Util.getTemporaryDirectBuffer(var1.remaining());

            int var7;
            try {
                // 将网络中的buf读进direct buffer
                int var6 = readIntoNativeBuffer(var0, var5, var2, var4);
                var5.flip();// 待读取
                if (var6 > 0) {
                    var1.put(var5);// 成功时写入
                }

                var7 = var6;
            } finally {
                Util.offerFirstTemporaryDirectBuffer(var5);
            }

            return var7;
        }
    }
private static int readIntoNativeBuffer(FileDescriptor var0, ByteBuffer var1, long var2, NativeDispatcher var4) throws IOException {
            // 忽略变量init
            if (var2 != -1L) {
                // pread方法只有在同步状态下才能使用
                var9 = var4.pread(var0, ((DirectBuffer)var1).address() + (long)var5, var7, var2);
            } else {
                // 其调用SocketDispatcher.read方法 -> FileDispatcherImpl.read0方法
                var9 = var4.read(var0, ((DirectBuffer)var1).address() + (long)var5, var7);
            }

            if (var9 > 0) {
                var1.position(var5 + var9);
            }

            return var9;
        }
    }
// 同样找到openjdk:src\solaris\native\sun\nio\ch 
//FileDispatcherImpl.c
JNIEXPORT jint JNICALL
Java_sun_nio_ch_FileDispatcherImpl_read0(JNIEnv *env, jclass clazz,
                             jobject fdo, jlong address, jint len)
{
    jint fd = fdval(env, fdo);// 获取fd索引
    void *buf = (void *)jlong_to_ptr(address);
    // 调用底层read方法
    return convertReturnVal(env, read(fd, buf, len), JNI_TRUE);
}
```

总结一下读取的过程

1. 初始化一个direct buffer，如果本身的buffer就是direct的则不用初始化
2. 调用底层read方法写入至direct buffer
3. 最终将direct buffer写到传入的buffer对象

**write 写**

看完了前面的read，write整个执行流程基本一样，具体的细节参考如下：

```java
public int write(ByteBuffer var1) throws IOException {
        if (var1 == null) {
            throw new NullPointerException();
        } else {
            synchronized(this.writeLock) {
                this.ensureWriteOpen();
                        this.begin();
                        synchronized(this.stateLock) {
                            if (!this.isOpen()) {
                                var5 = 0;
                                var20 = false;
                                break label310;
                            }
                            this.writerThread = NativeThread.current();
                        }
                        do {
                            // 通过IOUtil的读取fd的数据至buf
                            // 这里的nd是SocketDispatcher，用于调用底层的read和write操作
                            var3 = IOUtil.write(this.fd, var1, -1L, nd);
                        } while(var3 == -3 && this.isOpen());

                        var4 = IOStatus.normalize(var3);
                        var20 = false;
                    this.writerCleanup();
                    assert IOStatus.check(var3);
                    return var4;
                }
            }
        }
    }
static int write(FileDescriptor var0, ByteBuffer var1, long var2, NativeDispatcher var4) throws IOException {
        if (var1 instanceof DirectBuffer) {
            return writeFromNativeBuffer(var0, var1, var2, var4);
        } else {

            ByteBuffer var8 = Util.getTemporaryDirectBuffer(var7);

            int var10;
            try {
                // 这里的pos为buf初始的position，意思是将buf重置为最初的状态;因为目前还没有真实的写入到channel中
                var8.put(var1);
                var8.flip();
                var1.position(var5);
                // 调用
                int var9 = writeFromNativeBuffer(var0, var8, var2, var4);
                if (var9 > 0) {
                    var1.position(var5 + var9);
                }

                var10 = var9;
            } finally {
                Util.offerFirstTemporaryDirectBuffer(var8);
            }

            return var10;
        }
    }
IOUtil.writeFromNativeBuffer(fd , buf , position , nd)
{
    // ... 忽略一些获取buf变量的代码    
    int written = 0;
    if (position != -1) {
        // pread方法只有在同步状态下才能使用
        written = nd.pwrite(fd ,((DirectBuffer)bb).address() + pos,rem, position);
    } else {
        // 其调用SocketDispatcher.write方法 -> FileDispatcherImpl.write0方法
        written = nd.write(fd, ((DirectBuffer)bb).address() + pos, rem);
    }
    //....
}
FileDispatcherImpl.write0
{
    // 调用底层的write方法写入
    return convertReturnVal(env, write(fd, buf, len), JNI_FALSE);
}
}
```

总结一下write的过程：

1. 如果buf是direct buffer则直接开始写入，否则需要初始化一个direct buffer，大小是buf的remain
2. 将buf的内容写入到direct buffer中，并恢复buf的position
3. 调用底层的write方法写入至channel
4. 更新buf的position，即被direct buffer读取内容后的position

理解了前面的一些基础知识，接下来的部分就会涉及到Java是怎么样来使用epoll的。

Selector的创建过程如下：

```java
// 1.创建Selector
Selector selector = Selector.open();

// 2.将Channel注册到选择器中
// ....... new channel的过程 ....

//Notes：channel要注册到Selector上就必须是非阻塞的，所以FileChannel是不可以
//使用Selector的，因为FileChannel是阻塞的
channel.configureBlocking(false);

// 第二个参数指定了我们对 Channel 的什么类型的事件感兴趣
SelectionKey key = channel.register(selector , SelectionKey.OP_READ);

// 也可以使用或运算|来组合多个事件，例如
SelectionKey key = channel.register(selector , SelectionKey.OP_READ | SelectionKey.OP_WRITE);

// 不过值得注意的是，一个 Channel 仅仅可以被注册到一个 Selector 一次,
// 如果将 Channel 注册到 Selector 多次, 那么其实就是相当于更新 SelectionKey 
// 的 interest set.
```

**①**一个Channel在Selector注册其代表的是一个SelectionKey事件，SelectionKey的类型包括：

- **OP_READ**：可读事件；值为：1<<0
- **OP_WRITE**：可写事件；值为：1<<2
- **OP_CONNECT**：客户端连接服务端的事件(tcp连接)，一般为创建SocketChannel客户端channel；值为：1<<3
- **OP_ACCEPT**：服务端接收客户端连接的事件，一般为创建ServerSocketChannel服务端channel；值为：1<<4

**②**一个Selector内部维护了三组keys：

1. **key set**：当前channel注册在Selector上所有的key；可调用keys()获取
2. **selected-key set**：当前channel就绪的事件；可调用selectedKeys()获取
3. **cancelled-key**：主动触发SelectionKey#cancel()方法会放在该集合，前提条件是该channel没有被取消注册；不可通过外部方法调用

**③**Selector类中总共包含以下10个方法：

- **open**()：创建一个Selector对象
- **isOpen**()：是否是open状态，如果调用了close()方法则会返回false
- **provider**()：获取当前Selector的Provider
- **keys**()：如上文所述，获取当前channel注册在Selector上所有的key
- **selectedKeys**()：获取当前channel就绪的事件列表
- **selectNow**()：获取当前是否有事件就绪，该方法立即返回结果，不会阻塞；如果返回值>0，则代表存在一个或多个
- **select**(long timeout)：selectNow的阻塞超时方法，超时时间内，有事件就绪时才会返回；否则超过时间也会返回
- **select**()：selectNow的阻塞方法，直到有事件就绪时才会返回
- **wakeup**()：调用该方法会时，阻塞在select()处的线程会立马返回；**即使当前不存在线程阻塞在select()处，那么下一个执行select()方法的线程也会立即返回结果，相当于执行了一次selectNow()方法**
- **close**()：用完Selector后调用其close()方法会关闭该Selector，且使注册到该Selector上的所有SelectionKey实例无效。channel本身并不会关闭。

**关于SelectionKey**

谈到Selector就不得不提SelectionKey，两者是紧密关联，配合使用的；如上文所示，往Channel注册Selector会返回一个SelectionKey对象， 这个对象包含了如下内容：

- **interest set**，当前Channel感兴趣的事件集，即在调用register方法设置的interes set
- **ready set**
- **channel**
- **selector**
- **attached object**，可选的附加对象

interest set：可以通过SelectionKey类中的方法来获取和设置interes set

```java
// 返回当前感兴趣的事件列表
int interestSet = key.interestOps();

// 也可通过interestSet判断其中包含的事件
boolean isInterestedInAccept  = interestSet & SelectionKey.OP_ACCEPT;
boolean isInterestedInConnect = interestSet & SelectionKey.OP_CONNECT;
boolean isInterestedInRead    = interestSet & SelectionKey.OP_READ;
boolean isInterestedInWrite   = interestSet & SelectionKey.OP_WRITE;    

// 可以通过interestOps(int ops)方法修改事件列表
key.interestOps(interestSet | SelectionKey.OP_WRITE);
```

ready set：当前Channel就绪的事件列表

```java
int readySet = key.readyOps();

// 也可通过四个方法来分别判断不同事件是否就绪
key.isReadable();    //读事件是否就绪
key.isWritable();    //写事件是否就绪
key.isConnectable(); //客户端连接事件是否就绪
key.isAcceptable();  //服务端连接事件是否就绪
```

channel和selector：我们可以通过SelectionKey来获取当前的channel和selector

```java
// 返回当前事件关联的通道，可转换的选项包括:`ServerSocketChannel`和`SocketChannel`
Channel channel = key.channel();

// 返回当前事件所关联的Selector对象
Selector selector = key.selector();
```

attached object：我们可以在selectionKey中附加一个对象,或者在注册时直接附加：

```java
key.attach(theObject);
Object attachedObj = key.attachment();
// 在注册时直接附加
SelectionKey key = channel.register(selector, SelectionKey.OP_READ, theObject);
```

<img src="http://blog-1259650185.cosbj.myqcloud.com/img/202109/22/1632303904.png" alt="image-20210922174504237" style="zoom:50%;" />

可以看到Selector的实现是`SelectorImpl`, 然后SelectorImpl又将职责委托给了具体的平台，比如图中的linux2.6 **EpollSelectorImpl**,windows是**WindowsSelectorImpl**，MacOSX是**KQueueSelectorImpl**。

根据前面我们知道，Selector.open()可以得到一个Selector实例，怎么实现的呢？

```java
// Selector.java
public static Selector open() throws IOException {
    // 首先找到provider,然后再打开Selector
    return SelectorProvider.provider().openSelector();
}

// java.nio.channels.spi.SelectorProvider
    public static SelectorProvider provider() {
    synchronized (lock) {
        if (provider != null)
            return provider;
        return AccessController.doPrivileged(
            new PrivilegedAction<SelectorProvider>() {
                public SelectorProvider run() {
                        if (loadProviderFromProperty())
                            return provider;
                        if (loadProviderAsService())
                            return provider;
                            // 这里就是打开Selector的真正方法
                        provider = sun.nio.ch.DefaultSelectorProvider.create();
                        return provider;
                    }
                });
    }
}
```

在openjdk中，每个操作系统都有一个sun.nio.ch.DefaultSelectorProvider实现，以src solaris\classes\sun\nio\ch下的DefaultSelectorProvider为例:

```java
/**
 * Returns the default SelectorProvider.
 */
public static SelectorProvider create() {
    // 获取OS名称
    String osname = AccessController
        .doPrivileged(new GetPropertyAction("os.name"));
    // 根据名称来创建不同的Selctor
    if (osname.equals("SunOS"))
        return createProvider("sun.nio.ch.DevPollSelectorProvider");
    if (osname.equals("Linux"))
        return createProvider("sun.nio.ch.EPollSelectorProvider");
    return new sun.nio.ch.PollSelectorProvider();
}
```

打开src solaris\classes\sun\nio\ch下的EPollSelectorProvider.java

```java
public class EPollSelectorProvider extends SelectorProviderImpl
{
    public AbstractSelector openSelector() throws IOException {
        return new EPollSelectorImpl(this);
    }

    public Channel inheritedChannel() throws IOException {
        return InheritedChannel.getChannel();
    }
}
```

Linux平台就得到了最终的Selector实现:src solaris\classes\sun\nio\ch下的`EPollSelectorImpl.java`

来看看它实现的构造器：

```java
EPollSelectorImpl(SelectorProvider sp) throws IOException {
    super(sp);
    // makePipe返回管道的2个文件描述符，编码在一个long类型的变量中
    // 高32位代表读 低32位代表写
    // 使用pipe为了实现Selector的wakeup逻辑
    long pipeFds = IOUtil.makePipe(false);
    fd0 = (int) (pipeFds >>> 32);
    fd1 = (int) pipeFds;
    // 新建一个EPollArrayWrapper
    pollWrapper = new EPollArrayWrapper();
    pollWrapper.initInterrupt(fd0, fd1);
    fdToKey = new HashMap<>();
}
```

\src\solaris\native\sun\nio\ch下的EPollArrayWrapper.c

```c
JNIEXPORT jint JNICALL
Java_sun_nio_ch_EPollArrayWrapper_epollCreate(JNIEnv *env, jobject this)
{
    /*
     * epoll_create expects a size as a hint to the kernel about how to
     * dimension internal structures. We can't predict the size in advance.
     */
    int epfd = epoll_create(256);
    if (epfd < 0) {
       JNU_ThrowIOExceptionWithLastError(env, "epoll_create failed");
    }
    return epfd;
}
```

①epoll_create在前面已经讲过了，这里就不再赘述了。

②epoll wait 等待内核IO事件

调用Selector.select(返回键的数量，可能是零)最后会委托给各个实现的doSelect方法，限于篇幅不贴出太详细的，这里看下EpollSelectorImpl的**doSelect**方法：

```java
protected int doSelect(long timeout) throws IOException {
        if (closed)
            throw new ClosedSelectorException();
        processDeregisterQueue();
        try {
            begin();
            // EPollArrayWrapper pollWrapper
            pollWrapper.poll(timeout);//重点在这里
        } finally {
            end();
        }
        processDeregisterQueue();
        int numKeysUpdated = updateSelectedKeys();// 后面会讲到
        if (pollWrapper.interrupted()) {
            // Clear the wakeup pipe
            pollWrapper.putEventOps(pollWrapper.interruptedIndex(), 0);
            synchronized (interruptLock) {
                pollWrapper.clearInterrupted();
                IOUtil.drain(fd0);
                interruptTriggered = false;
            }
        }
        return numKeysUpdated;
    }

// EPollArrayWrapper
int poll(long timeout) throws IOException {
    updateRegistrations();// 这个代码在下面讲，涉及到epoo_ctl
    // 这个epollWait是不是有点熟悉呢？
    updated = epollWait(pollArrayAddress, NUM_EPOLLEVENTS, timeout, epfd);
    for (int i=0; i<updated; i++) {
        if (getDescriptor(i) == incomingInterruptFD) {
            interruptedIndex = i;
            interrupted = true;
            break;
        }
    }
    return updated
```

看下EPollArrayWrapper.c

```c
JNIEXPORT jint JNICALL
Java_sun_nio_ch_EPollArrayWrapper_epollWait(JNIEnv *env, jobject this,
                                            jlong address, jint numfds,
                                            jlong timeout, jint epfd)
{
    struct epoll_event *events = jlong_to_ptr(address);
    int res;

    if (timeout <= 0) {           /* Indefinite or no wait */
        // 系统调用等待内核事件
        RESTARTABLE(epoll_wait(epfd, events, numfds, timeout), res);
    } else {                      /* Bounded wait; bounded restarts */
        res = iepoll(epfd, events, numfds, timeout);
    }

    if (res < 0) {
        JNU_ThrowIOExceptionWithLastError(env, "epoll_wait failed");
    }
    return res;
}
```

可以看到在linux中Selector.select()其实是调用了epoll_wait。

③epoll control以及openjdk对事件管理的封装

JDK中对于注册到Selector上的IO事件关系是使用**SelectionKey**来表示，代表了Channel感兴趣的事件，如**Read,Write,Connect,Accept**。

调用**Selector.register()**时均会将事件存储到EpollArrayWrapper.java的成员变量eventsLow和eventsHigh中

```java
// events for file descriptors with registration changes pending, indexed
// by file descriptor and stored as bytes for efficiency reasons. For
// file descriptors higher than MAX_UPDATE_ARRAY_SIZE (unlimited case at
// least) then the update is stored in a map.
// 使用数组保存事件变更, 数组的最大长度是MAX_UPDATE_ARRAY_SIZE, 最大64*1024
private final byte[] eventsLow = new byte[MAX_UPDATE_ARRAY_SIZE];
// 超过数组长度的事件会缓存到这个map中，等待下次处理
private Map<Integer,Byte> eventsHigh;


/**
 * Sets the pending update events for the given file descriptor. This
 * method has no effect if the update events is already set to KILLED,
 * unless {@code force} is {@code true}.
 */
private void setUpdateEvents(int fd, byte events, boolean force) {
    // 判断fd和数组长度
    if (fd < MAX_UPDATE_ARRAY_SIZE) {
        if ((eventsLow[fd] != KILLED) || force) {
            eventsLow[fd] = events;
        }
    } else {
        Integer key = Integer.valueOf(fd);
        if (!isEventsHighKilled(key) || force) {
            eventsHigh.put(key, Byte.valueOf(events));
        }
    }
}
  /**
     * Returns the pending update events for the given file descriptor.
     */
    private byte getUpdateEvents(int fd) {
        if (fd < MAX_UPDATE_ARRAY_SIZE) {
            return eventsLow[fd];
        } else {
            Byte result = eventsHigh.get(Integer.valueOf(fd));
            // result should never be null
            return result.byteValue();
        }
```

在上面poll代码中涉及到：

```java
int poll(long timeout) throws IOException {
updateRegistrations();
  
/**
 * Update the pending registrations.
 */
private void updateRegistrations() {
    synchronized (updateLock) {
        int j = 0;
        while (j < updateCount) {
            int fd = updateDescriptors[j];
            // 从保存的eventsLow和eventsHigh里取出事件
            short events = getUpdateEvents(fd);
            boolean isRegistered = registered.get(fd);
            int opcode = 0;

            if (events != KILLED) {
                if (isRegistered) {
                    // 判断操作类型以传给epoll_ctl
                    // 没有指定EPOLLET事件类型
                    opcode = (events != 0) ? EPOLL_CTL_MOD : EPOLL_CTL_DEL;
                } else {
                    opcode = (events != 0) ? EPOLL_CTL_ADD : 0;
                }
                if (opcode != 0) {
                     // 熟悉的epoll_ctl
                    epollCtl(epfd, opcode, fd, events);
                    if (opcode == EPOLL_CTL_ADD) {
                        registered.set(fd);
                    } else if (opcode == EPOLL_CTL_DEL) {
                        registered.clear(fd);
                    }
                }
            }
            j++;
        }
        updateCount = 0;
    }
private native void epollCtl(int epfd, int opcode, int fd, int events);
```

可以看到epollCtl调用的native方法，我们进入EpollArrayWrapper.c。

```c
Java_sun_nio_ch_EPollArrayWrapper_epollCtl(JNIEnv *env, jobject this, jint epfd,
                                           jint opcode, jint fd, jint events)
{
    struct epoll_event event;
    int res;

    event.events = events;
    event.data.fd = fd;
    // epoll_ctl这里就不用多说了吧
    RESTARTABLE(epoll_ctl(epfd, (int)opcode, (int)fd, &event), res);

    /*
     * A channel may be registered with several Selectors. When each Selector
     * is polled a EPOLL_CTL_DEL op will be inserted into its pending update
     * list to remove the file descriptor from epoll. The "last" Selector will
     * close the file descriptor which automatically unregisters it from each
     * epoll descriptor. To avoid costly synchronization between Selectors we
     * allow pending updates to be processed, ignoring errors. The errors are
     * harmless as the last update for the file descriptor is guaranteed to
     * be EPOLL_CTL_DEL.
     */
    if (res < 0 && errno != EBADF && errno != ENOENT && errno != EPERM) {
        JNU_ThrowIOExceptionWithLastError(env, "epoll_ctl failed");
    }
}
```

在doSelect方法poll执行后，会更新EpollSelectorImpl.java里的 updateSelectedKeys，就是Selector里的三个set集合，具体可看前面。

```java
/**

*更新已被epoll选择fd的键。

*将就绪兴趣集添加到就绪队列。

*/
private int updateSelectedKeys() {
        int entries = pollWrapper.updated;
        int numKeysUpdated = 0;
        for (int i=0; i<entries; i++) {
            int nextFD = pollWrapper.getDescriptor(i);
            SelectionKeyImpl ski = fdToKey.get(Integer.valueOf(nextFD));
            // ski is null in the case of an interrupt
            if (ski != null) {
                int rOps = pollWrapper.getEventOps(i);
                if (selectedKeys.contains(ski)) {
                    if (ski.channel.translateAndSetReadyOps(rOps, ski)) {
                        numKeysUpdated++;
                    }
                } else {
                    ski.channel.translateAndSetReadyOps(rOps, ski);
                    if ((ski.nioReadyOps() & ski.nioInterestOps()) != 0) {
                        selectedKeys.add(ski);
                        numKeysUpdated++;
                    }
                }
            }
        }
        return numKeysUpdated;
    }
```



# 参考

[深入Hotspot源码与Linux内核理解NIO与Epoll](https://mp.weixin.qq.com/s?__biz=MzU1NTc4NTE4NQ==&mid=2247485110&idx=2&sn=22cc7062822e7a76d5d0a418e6607286&chksm=fbce4838ccb9c12e9c249358accdc761ded22c3e131162bf1bb3d93d204590a74e9b87d782c0&scene=178&cur_album_id=1775873174379741184#rd)

[【原创】万字长文浅析：Epoll与Java Nio的那些事儿](https://mp.weixin.qq.com/s/G6TfGbc4U8Zhv30wnN0HIg)

[网络 IO 演变过程](https://zhuanlan.zhihu.com/p/353692786)

[Linux IO模式及 select、poll、epoll详解](https://segmentfault.com/a/1190000003063859)

[IO复用之select、poll、epoll模型](https://zhuanlan.zhihu.com/p/126278747)

