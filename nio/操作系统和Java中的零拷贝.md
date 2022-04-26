# 前言

零拷贝机制（Zero-Copy）是在操作数据时不需要将数据从一块内存区域复制到另一块内存区域的技术，这样就避免了内存的拷贝，使得可以提高CPU的。它的作用是在数据报从网络设备到用户程序空间传递的过程中，减少数据拷贝次数，减少系统调用，实现 CPU 的零参与，彻底消除 CPU 在这方面的负载。实现零拷贝用到的最主要技术是 DMA 数据传输技术和内存区域映射技术。

- 零拷贝机制可以减少数据在内核缓冲区和用户进程缓冲区之间反复的 I/O 拷贝操作。
- 零拷贝机制可以减少用户进程地址空间和内核地址空间之间因为上下文切换而带来的 CPU 开销。

# 操作系统的零拷贝

## 传统IO

在开始谈零拷贝之前，首先要对传统的IO方式有一个概念。

操作系统的存储空间包含硬盘和内存，而内存又分成用户空间和内核空间。

基于传统的IO方式，底层实际上通过调用操作系统的`read()`和`write()`函数来实现。

以从文件服务器下载文件为例，服务器需要将硬盘中的数据通过网络通信发送给客户端：

```java
File.read(file, buf, len);

Socket.send(socket, buf, len);
```

整个过程发生了**4次用户态和内核态的上下文切换**和**4次拷贝**，具体流程如下：

1. 用户进程通过`read()`方法向操作系统发起调用，此时上下文从**用户态转向内核态**
2. DMA控制器把数据从硬盘中**拷贝到读缓冲区**
3. 由于应用程序无法访问内核地址空间的数据，如果应用程序要操作这些数据，CPU要把读缓冲区数据**拷贝到用户缓冲区**，`read()` 调用的返回引发上下文从**内核态转为用户态**
4. 用户进程通过`write()`方法发起调用，上下文从**用户态转为内核态**
5. CPU将用户缓冲区中数据**拷贝到socket缓冲区**
6. DMA控制器把数据从socket缓冲区**拷贝到网卡**，上下文从**内核态切换回用户态**，`write()`返回 

**整个过程中，用户空间和内核空间切换4次，DMA拷贝2次、CPU拷贝2次，过程2和6是由DMA负责，并不会消耗CPU，只有过程3和5的拷贝需要CPU参与。**内核空间和硬件之间数据拷贝是DMA复制传输，内核空间和用户空间之间数据拷贝是通过CPU复制。另外，CPU除了需要参与拷贝任务，还需要多次从内核空间和用户空间之间来回切换，无疑都额外增加了很多的CPU工作负担。

流程如下图示：

<img src="http://blog-1259650185.cosbj.myqcloud.com/img/202109/21/1632228129.png" alt="image-20210921204209856" style="zoom:50%;" />



读缓冲区是 Linux 系统的 Page Cahe。为了加快磁盘的 IO，Linux 系统会把磁盘上的数据以 Page 为单位缓存在操作系统的内存里，这里的 Page 是 Linux 系统定义的一个逻辑概念，一个 Page 一般为 4K。

那么，这里指的**用户态**、**内核态**指的是什么？上下文切换又是什么？

简单来说，用户空间指的就是用户进程的运行空间，内核空间就是内核的运行空间。

如果进程运行在内核空间就是内核态，运行在用户空间就是用户态。

如果我们的操作系统的全部权限，包括内存都可以让用户随意操作那是一个很危险的事情，例如某些病毒可以随意篡改内存中的数据，以达到某些不轨的目的，那就很难受了。所以，我们的操作系统就必须对这些底层的API进行一些限制和保护。为了安全起见，他们之间是互相隔离的，而在用户态和内核态之间的上下文切换也是比较耗时的。

我们还是以写出文件为例，当我们调用了一个write api的时候，他会将write的方法名以及参数加载到CPU的寄存器中，同时执行一个指令叫做  **int 0x80**的指令，int 0x80是 **interrupt 128（0x80的10进制）的缩写，我们一般叫80中断**，当调用了这个指令之后，CPU会停止当前的调度，保存当前的执行中的线程的状态，然后在中断向量表中寻找 128代表的回调函数，将之前写到寄存器中的数据（write /参数）当作参数，传递到这个回调函数中，由这个回调函数去寻找对应的系统函数write进行写出操作。

从上面我们可以看到，一次简单的IO过程产生了4次上下文切换，这个无疑在高并发场景下会对性能产生较大的影响。

那么什么又是**DMA**拷贝呢？

因为对于一个IO操作而言，都是通过CPU发出对应的指令来完成，但是相比CPU来说，IO的速度太慢了，CPU有大量的时间处于等待IO的状态。

因此就产生了DMA（Direct Memory Access）直接内存访问技术，本质上来说他就是一块主板上独立的芯片，通过它来进行内存和IO设备的数据传输，从而减少CPU的等待时间。

但是无论谁来拷贝，频繁的拷贝耗时也是对性能的影响。

所以操作系统为了减少CPU拷贝数据带来的性能消耗,提供了几种解决方案来减少CPU拷贝次数

## mmap

`mmap`主要实现方式是将读缓冲区的地址和用户缓冲区的地址进行映射，将内核空间的内存区域与用户空间进行共享，进程可以像访问普通内存一样对文件进行访问，不必再调用read()，write()等操作。无论是用户空间还是内核空间操作自己的缓冲区，本质上都是**操作这一块共享内存**中的缓冲区数据，从而减少了从读缓冲区到用户缓冲区的一次CPU拷贝。

```c
void *mmap(void *addr, size_t length, int prot, int flags,
       int fd, off_t offset);
int munmap(void *addr, size_t length);
```

> mmap()在调用进程的虚拟地址空间中创建一个新的映射。新映射的起始地址在addr中指定。length参数指定映射的长度,如果addr为空，则内核选择创建映射的地址;这是创建新映射的最可移植的方法。如果addr不为空，则内核将其作为提示!关于在哪里放置映射;在Linux上，映射将在附近的页面边界创建。新映射的地址作为调用的结果返回。

<img src="http://blog-1259650185.cosbj.myqcloud.com/img/202109/21/1632229731.png" alt="image-20210921210851522" style="zoom:50%;" />

整个过程发生了**4次用户态和内核态的上下文切换**和**3次拷贝**，具体流程如下：

1. 用户进程通过`mmap`方法向操作系统发起调用，上下文从**用户态转向内核态**
2. DMA控制器把数据从硬盘中**拷贝到读缓冲区**
3. **上下文从内核态转为用户态，mmap调用返回**
4. 用户进程通过`write()`方法发起调用，上下文从**用户态转为内核态**
5. **CPU将读缓冲区中数据拷贝到socket缓冲区**
6. DMA控制器把数据从socket缓冲区**拷贝到网卡**，上下文从**内核态切换回用户态**，`write()`返回

**整个流程中：DMA拷贝2次、CPU拷贝1次、用户空间和内核空间切换4次**。

`mmap`的方式节省了一次CPU拷贝，同时由于用户进程中的内存是虚拟的，只是映射到内核的读缓冲区，所以可以节省一半的内存空间，比较适合大文件的传输。对于小文件，内存映射文件反而会导致碎片空间的浪费，因为内存映射总是要对齐页边界，最小单位是 4 KB，一个 5 KB 的文件将会映射占用 8 KB 内存，也就会浪费 3 KB 内存。

## sendfile

相比`mmap`来说，`sendfile`同样减少了一次CPU拷贝，而且还减少了2次上下文切换。

`sendfile`是Linux2.1内核版本后引入的一个系统调用函数，作用是将一个文件描述符的内容发送给另一个文件描述符，通过使用`sendfile`数据可以直接在内核空间进行传输，而用户空间是不需要关心文件描述符的，所以整个的拷贝过程只会在内核空间操作，因此避免了用户空间和内核空间的拷贝，同时由于使用`sendfile`替代了`read+write`从而节省了一次系统调用，也就是2次上下文切换。

零拷贝过程使用的 Linux 系统 API 为：

```c
ssize_t sendfile(int out_fd, int in_fd, off_t *offset, size_t count);
```

> sendfile()在一个文件描述符和另一个文件描述符之间复制数据。因为这种复制是在内核中完成的，所以sendfile()比read()和write()的组合更高效，后者需要在用户空间之间来回传输数据。
>
> in_fd是打开用于读取的文件描述符，而out_fd是打开用于写入的文件描述符。
>
> 如果offset不为NULL，则它指向一个保存文件偏移量的变量，sendfile()将从这个变量开始从in_fd读取数据。当sendfile()返回时，这个变量将被设置为最后一个被读取字节后面的字节的偏移量。如果offset不为NULL，则sendfile()不会修改当前值
>
> 租用文件偏移in_fd;否则，将调整当前文件偏移量以反映从in_fd读取的字节数。
>
> 如果offset为NULL，则从当前文件偏移量开始从in_fd读取数据，并通过调用更新文件偏移量。
>
> count是要在文件描述符之间复制的字节数。
>
> in_fd参数必须对应于支持类似mmap(2)的操作的文件(也就是说，它不能是套接字)。
>
> 在2.6.33之前的Linux内核中，out_fd必须引用一个套接字。从Linux 2.6.33开始，它可以是任何文件。如果是一个常规文件，则sendfile()适当地更改文件偏移量。

<img src="http://blog-1259650185.cosbj.myqcloud.com/img/202109/21/1632230539.png" alt="image-20210921212219315" style="zoom:50%;" />

整个过程发生了**2次用户态和内核态的上下文切换**和**3次拷贝**，具体流程如下：

1. 用户进程通过`sendfile()`方法向操作系统发起调用，上下文从**用户态转向内核态**
2. DMA控制器把数据从硬盘中**拷贝到读缓冲区**
3. CPU将读缓冲区中数据**拷贝到socket缓冲区**
4. DMA控制器把数据从socket缓冲区**拷贝到网卡**，上下文从**内核态切换回用户态**，`sendfile`调用返回

`sendfile`方法IO数据对用户空间完全不可见，全程都是在内核空间实现的，所以只能适用于完全不需要用户空间处理的情况，比如静态文件服务器。

## sendfile+DMA Scatter/Gather

Linux2.4内核版本之后对`sendfile`做了进一步优化，通过引入新的硬件支持，这个方式叫做DMA Scatter/Gather 分散/收集功能。

它将读缓冲区中的数据描述信息--内存地址和偏移量记录到socket缓冲区，由 DMA 根据这些将数据从读缓冲区拷贝到网卡，相比之前版本减少了一次CPU拷贝的过程。

<img src="http://blog-1259650185.cosbj.myqcloud.com/img/202109/21/1632231255.png" alt="image-20210921213415675" style="zoom:50%;" />

整个过程发生了**2次用户态和内核态的上下文切换**和**2次拷贝**，其中更重要的是完全没有CPU拷贝，具体流程如下：

1. 用户进程通过`sendfile()`方法向操作系统发起调用，上下文从**用户态转向内核态**
2. DMA控制器利用scatter把数据从硬盘中**拷贝到读缓冲区离散存储**
3. CPU把读缓冲区中的文件描述符和数据长度发送到socket缓冲区
4. DMA控制器根据文件描述符和数据长度，使用scatter/gather把数据从内核缓冲区**拷贝到网卡**
5. `sendfile()`调用返回，上下文从**内核态切换回用户态**

**整个过程中：DMA拷贝2次、CPU拷贝0次、内核空间和用户空间切换2次。**

`DMA gather`和`sendfile`一样数据对用户空间不可见，而且需要硬件支持，同时输入文件描述符只能是文件，但是过程中**完全没有CPU拷贝**过程，实现了真正的CPU零拷贝机制，极大提升了性能。

## splice

sendfile 只适用于将数据从文件拷贝到 socket 套接字上，同时需要硬件的支持，这也限定了它的使用范围。Linux 在 2.6.17 版本引入 splice 系统调用，不仅不需要硬件支持，还实现了两个文件描述符之间的数据零拷贝。splice 的伪代码如下：

```c
splice(fd_in, off_in, fd_out, off_out, len, flags);
```

splice函数的作用是将两个文件描述符之间建立一个管道，然后将文件描述符的引用传递过去，这样在使用到数据的时候就可以直接通过引用指针访问到具体数据。过程如下:

1. 用户进程通过 splice() 函数向内核（kernel）发起系统调用，上下文从用户态（user space）切换为内核态（kernel space）。
2. CPU 利用 DMA 控制器将数据从主存或硬盘拷贝到内核空间（kernel space）的读缓冲区（read buffer）。
3. CPU 在内核空间的读缓冲区（read buffer）和网络缓冲区（socket buffer）之间建立管道（pipeline）。
4. CPU 利用 DMA 控制器将数据从网络缓冲区（socket buffer）拷贝到网卡进行数据传输。
5. 上下文从内核态（kernel space）切换回用户态（user space），splice 系统调用执行返回。

<img src="http://blog-1259650185.cosbj.myqcloud.com/img/202109/21/1632236412.png" alt="image-20210921230012294" style="zoom:50%;" />

**整个过程中：DMA拷贝2次、CPU拷贝0次、内核空间和用户空间切换2次**

可以看出通过slice函数传输数据时同样可以实现CPU的零拷贝，且不需要CPU在内核空间和用户空间之间来回切换。

## 小结

由于CPU和IO速度的差异问题，产生了DMA技术，通过DMA搬运来减少CPU的等待时间。

传统的IO `read+write` 方式会产生2次DMA拷贝+2次CPU拷贝，同时有4次上下文切换。

而通过 `mmap+write` 方式则产生2次DMA拷贝+1次CPU拷贝，4次上下文切换，通过内存映射减少了一次CPU拷贝，可以减少内存使用，适合大文件的传输。

`sendfile` 方式是新增的一个系统调用函数，产生2次DMA拷贝+1次CPU拷贝，但是只有2次上下文切换。因为只有一次调用，减少了上下文的切换，但是用户空间对IO数据不可见，适用于静态文件服务器。

`sendfile+DMA gather` 方式产生2次DMA拷贝，没有CPU拷贝，而且也只有2次上下文切换。虽然极大地提升了性能，但是需要依赖新的硬件设备支持。

无论是传统 I/O 拷贝方式还是引入零拷贝的方式，2 次 DMA Copy 是都少不了的，因为两次 DMA 都是依赖硬件完成的。下面从 CPU 拷贝次数、DMA 拷贝次数以及系统调用几个方面总结一下上述几种 I/O 拷贝方式的差别。

| 拷贝方式                   | CPU拷贝 | DMA拷贝 | 系统调用     | 上下文切换 |
| -------------------------- | ------- | ------- | ------------ | ---------- |
| 传统方式（read + write）   | 2       | 2       | read / write | 4          |
| 内存映射（mmap + write）   | 1       | 2       | mmap / write | 4          |
| sendfile                   | 1       | 2       | sendfile     | 2          |
| sendfile + DMA gather copy | 0       | 2       | sendfile     | 2          |
| splice                     | 0       | 2       | splice       | 2          |

# Java的零拷贝

## transderTo

Java的应用程序经常会遇到数据传输的场景，在Java NIO包中就提供了零拷贝机制的实现，主要是通过NIO包中的FileChannel实现FileChannel提供了transferTo和transferFrom方法，都是采用了调用底层操作系统的sendfile函数来实现的CPU零拷贝机制。

```java
FileChannel.transderTo(long position, long count, WritableByteChannel target);
```

几个参数也比较好理解，分别是开始传输的位置，传输的字节数，以及目标通道。transferTo()允许将一个通道交叉连接到另一个通道，而不需要一个中间缓冲区来传递数据；注：这里不需要中间缓冲区有两层意思：第一层不需要用户空间缓冲区来拷贝内核缓冲区，另外一层两个通道都有自己的内核缓冲区，两个内核缓冲区也可以做到无需拷贝数据；

经常需要从一个位置将文件传输到另外一个位置，FileChannel提供了transferTo()方法用来提高传输的效率，首先看一个简单的实例：

```java
public class ChannelTransfer {
    public static void main(String[] argv) throws Exception {
        String files[]=new String[1];
        files[0]="D://db.txt";
        catFiles(Channels.newChannel(System.out), files);
    }

    private static void catFiles(WritableByteChannel target, String[] files)
            throws Exception {
        for (int i = 0; i < files.length; i++) {
            FileInputStream fis = new FileInputStream(files[i]);
            FileChannel channel = fis.getChannel();
            channel.transferTo(0, channel.size(), target);
            channel.close();
            fis.close();
        }
    }
}
```

## MappedByteBuffer

java nio提供的FileChannel提供了map()方法，该方法可以在一个打开的文件和MappedByteBuffer之间建立一个虚拟内存映射，MappedByteBuffer继承于ByteBuffer，类似于一个基于内存的缓冲区，只不过该对象的数据元素存储在磁盘的一个文件中；调用get()方法会从磁盘中获取数据，此数据反映该文件当前的内容，调用put()方法会更新磁盘上的文件，并且对文件做的修改对其他阅读者也是可见的；下面看一个简单的读取实例，然后在对MappedByteBuffer进行分析：

```java
public class MappedByteBufferTest {

    public static void main(String[] args) throws Exception {
        File file = new File("D://db.txt");
        long len = file.length();
        byte[] ds = new byte[(int) len];
        MappedByteBuffer mappedByteBuffer = new FileInputStream(file).getChannel().map(FileChannel.MapMode.READ_ONLY, 0,
                len);
        for (int offset = 0; offset < len; offset++) {
            byte b = mappedByteBuffer.get();
            ds[offset] = b;
        }
        Scanner scan = new Scanner(new ByteArrayInputStream(ds)).useDelimiter(" ");
        while (scan.hasNext()) {
            System.out.print(scan.next() + " ");
        }
    }
}

```

主要通过FileChannel提供的map()来实现映射，map()方法如下：

```java
public abstract MappedByteBuffer map(MapMode mode, long position, long size) throws IOException;
```

分别提供了三个参数，MapMode，Position和size；分别表示：MapMode：映射的模式，可选项包括：READ_ONLY，READ_WRITE，PRIVATE；Position：从哪个位置开始映射，字节数的位置；Size：从position开始向后多少个字节；

重点看一下MapMode，请两个分别表示只读和可读可写，当然请求的映射模式受到Filechannel对象的访问权限限制，如果在一个没有读权限的文件上启用READ_ONLY，将抛出NonReadableChannelException；PRIVATE模式表示写时拷贝的映射，意味着通过put()方法所做的任何修改都会导致产生一个私有的数据拷贝并且该拷贝中的数据只有MappedByteBuffer实例可以看到；该过程不会对底层文件做任何修改，而且一旦缓冲区被施以垃圾收集动作（garbage collected），那些修改都会丢失；大致浏览一下map()方法的源码：

```java
public MappedByteBuffer map(MapMode mode, long position, long size) throws IOException {
    // ...省略...
    int pagePosition = (int)(position % allocationGranularity);
    long mapPosition = position - pagePosition;
    long mapSize = size + pagePosition;
    try {
        // If no exception was thrown from map0, the address is valid
        addr = map0(imode, mapPosition, mapSize);
    } catch (OutOfMemoryError x) {
        // An OutOfMemoryError may indicate that we've exhausted memory
        // so force gc and re-attempt map
        System.gc();
        try {
            Thread.sleep(100);
        } catch (InterruptedException y) {
            Thread.currentThread().interrupt();
        }
        try {
            addr = map0(imode, mapPosition, mapSize);
        } catch (OutOfMemoryError y) {
            // After a second OOME, fail
            throw new IOException("Map failed", y);
        }
    }

    // On Windows, and potentially other platforms, we need an open
    // file descriptor for some mapping operations.
    FileDescriptor mfd;
    try {
        mfd = nd.duplicateForMapping(fd);
    } catch (IOException ioe) {
        unmap0(addr, mapSize);
        throw ioe;
    }

    assert (IOStatus.checkAll(addr));
    assert (addr % allocationGranularity == 0);
    int isize = (int)size;
    Unmapper um = new Unmapper(addr, mapSize, isize, mfd);
    if ((!writable) || (imode == MAP_RO)) {
        return Util.newMappedByteBufferR(isize, addr + pagePosition, mfd, um);
    } else {
        return Util.newMappedByteBuffer(isize, addr + pagePosition, mfd, um);
    }
 }
```

大致意思就是通过native方法获取内存映射的地址，如果失败，手动gc再次映射；最后通过内存映射的地址实例化 MappedByteBuffer，MappedByteBuffer本身是一个抽象类，其实这里真正实例话出来的是DirectByteBuffer；

## DirectByteBuffer

DirectByteBuffer继承于MappedByteBuffer，从名字就可以猜测出开辟了一段直接的内存，并不会占用jvm的内存空间；上一节中通过Filechannel映射出的MappedByteBuffer其实际也是DirectByteBuffer，当然除了这种方式，也可以手动开辟一段空间：

```
ByteBuffer directByteBuffer = ByteBuffer.allocateDirect(100);
```

如上开辟了100字节的直接内存空间。

为什么`DirectByteBuffer`就能够直接操作JVM外的内存呢？我们看下他的源码实现：

```java
DirectByteBuffer(int cap) { 
  // .....忽略....
   try {
     // 分配内存
     base = unsafe.allocateMemory(size);
   } catch (OutOfMemoryError x) {
     // ....忽略....
  }
  // ....忽略....
    if (pa && (base % ps != 0)) {
      //对齐page 计算地址并保存
      address = base + ps - (base & (ps - 1));
    } else {
      //计算地址并保存
      address = base;
    }
  //释放内存的回调
  cleaner = Cleaner.create(this, new Deallocator(base, size, cap));
  // ....忽略..
}
```

我们主要关注：`unsafe.allocateMemory(size);`

```java
public native long allocateMemory(long var1);
```

我们可以看到他调用的是 native方法，这种方法通常由C++实现，是直接操作内存空间的，这个是被jdk进行安全保护的操作，也就是说你通过`Unsafe.getUnsafe()`是获取不到的，必须通过反射。

但是大家有没有考虑过一个问题，这部分空间不经过垃JVM管理了，他该什么时候释放呢？JVM都管理不了了，那么堆外内存势必会导致OOM的出现，所以，我们必须要去手动的释放这个内存，但是手动释放对于编程复杂度难度太大，所以，JVM对堆外内存的管理也做了一部分优化，首先我们先看一下上述**DirectByteBuffer**中的`cleaner = Cleaner.create(this, new Deallocator(base, size, cap));`,这个对象，他主要用于堆外内存空间的释放；

```java
public class Cleaner extends PhantomReference<Object> {....}
```

Cleaner继承了一个PhantomReference，这代表着Cleaner是一个虚引用。

```java
public class PhantomReference<T> extends Reference<T> {
    public T get() {
        return null;
    }
    public PhantomReference(T referent, ReferenceQueue<? super T> q) {
        super(referent, q);
    }
}
```

虚引用的构造函数中要求必须传递的两个参数，被引用对象、引用队列。

JVM通过可待性分析算法，发现除了 ref引用之外，其余的没有人引用他，因为ref是虚引用，所以本次垃圾回收一定会回收它，回收的时候，做了一件什么事呢？

我们在创建这个虚引用的时候传入了一个队列，在这个对象被回收的时候，被引用的对象会进入到这个回调。

```java
public class MyPhantomReference {
    static ReferenceQueue<Object> queue = new ReferenceQueue<>();
    public static void main(String[] args) throws InterruptedException {
        byte[] bytes = new byte[10 * 1024];
        // 将该对象被虚引用引用
        PhantomReference<Object> objectPhantomReference = new PhantomReference<Object>(bytes,queue);
        // 这个一定返回null，因为实在接口定义中写死的
        System.out.println(objectPhantomReference.get());
        // 此时jvm并没有进行对象的回收，该队列返回为空
        System.out.println(queue.poll());
        // 手动释放该引用，将该引用置为无效引用
        bytes = null;
        // 触发gc
        System.gc();
        // 这里返回的还是null，接口定义中写死的
        System.out.println(objectPhantomReference.get());
        // 垃圾回收后，被回收对象进入到引用队列
        System.out.println(queue.poll());
    }
}
```

基本了解了虚引用之后，我们再来看`DirectByteBuffer`对象，他在构造函数创建的时候引用看一个虚引用`Cleaner`。当这个DirectByteBuffer使用完毕后，DirectByteBuffer被JVM回收，触发Cleaner虚引用。JVM垃圾线程会将这个对象绑定到`Reference`对象中的`pending`属性中，程序启动后引用类`Reference`类会创建一条守护线程：

```java
static {
        ThreadGroup tg = Thread.currentThread().getThreadGroup();
        for (ThreadGroup tgn = tg;
             tgn != null;
             tg = tgn, tgn = tg.getParent());
        Thread handler = new ReferenceHandler(tg, "Reference Handler");
        //设置优先级为系统最高优先级
        handler.setPriority(Thread.MAX_PRIORITY);
        handler.setDaemon(true);
        handler.start();
  //.......................
    }
```

我们看一下该线程的定义：

```java
static boolean tryHandlePending(boolean waitForNotify) {
        Reference<Object> r;
        Cleaner c;
        try {
            synchronized (lock) {
                if (pending != null) {
                   //......忽略
                    c = r instanceof Cleaner ? (Cleaner) r : null;
                    pending = r.discovered;
                    r.discovered = null;
                } else {
                    //队列中没有数据结阻塞  RefQueue入队逻辑中有NF操作，感兴趣可以自己去看下
                    if (waitForNotify) {
                        lock.wait();
                    }
                    // retry if waited
                    return waitForNotify;
                }
            }
        } catch (OutOfMemoryError x) {
            //发生OOM之后就让出线程的使用权，看能不能内部消化这个OOM
            Thread.yield();
            return true;
        } catch (InterruptedException x) {
            // 线程中断的话就直接返回
            return true;
        }

        // 这里是关键，如果虚引用是一个 cleaner对象，就直接进行清空操作，不在入队
        if (c != null) {
            //TODO 重点关注
            c.clean();
            return true;
        }
  //如果不是 cleaner对象，就将该引用入队
        ReferenceQueue<? super Object> q = r.queue;
        if (q != ReferenceQueue.NULL) q.enqueue(r);
        return true;
    }
```

那我们此时就应该重点关注**c.clean();**方法了！

```java
this.thunk.run();
```

重点关注这个，thunk是一个什么对象？我们需要重新回到 DirectByteBuffer创建的时候，看看他传递的是什么。

```java
 cleaner = Cleaner.create(this, new Deallocator(base, size, cap));
```

我们可以看到，传入的是一个 `Deallocator`对象，那么他所调用的run方法，我们看下逻辑:

```java
public void run() {
    if (address == 0) {
        // Paranoia
        return;
    }
    //释放内存
    unsafe.freeMemory(address);
    address = 0;
    Bits.unreserveMemory(size, capacity);
}
```

重点关注**unsafe.freeMemory(address);**这个就是释放内存的！

至此，我们知道了JVM是如何管理堆外内存的了。

<img src="http://blog-1259650185.cosbj.myqcloud.com/img/202109/21/1632235717.png" alt="image-20210921224837194" style="zoom:50%;" />

# Netty的零拷贝

Netty作为NIO的高性能网络通信框架，同样也实现了零拷贝机制，不过和操作系统的零拷贝机制则不是一个概念。

Netty中的零拷贝机制体现在多个场景:

1. 使用直接内存,在进行IO数据传输时避免了ByteBuf从堆外内存拷贝到堆内内存的步骤,而如果使用堆内内存分配ByteBuf的化,那么发送数据时需要将IO数据从堆内内存拷贝到堆外内存才能通过Socket发送。
2. Netty的文件传输使用了FileChannel的transferTo方法,底层使用到sendfile函数来实现了CPU零拷贝。
3. Netty中提供CompositeByteBuf类,用于将多个ByteBuf合并成逻辑上的ByteBuf,避免了将多个ByteBuf拷贝成一个ByteBuf的过程。
4. ByteBuf支持slice方法可以将ByteBuf分解成多个共享内存区域的ByteBuf,避免了内存拷贝。

下面对第3点和第4点做一下更详细的说明。

netty提供了零拷贝的buffer，在传输数据时，最终处理的数据会需要对单个传输的报文，进行组合和拆分，NIO原生的ByteBuffer无法做到，netty通过提供的Composite（组合）和Slice（拆分）两种buffer来实现零拷贝；看下面一张图会比较清晰：

<img src="http://blog-1259650185.cosbj.myqcloud.com/img/202109/21/1632233324.png" alt="image-20210921220843918" style="zoom:50%;" />

TCP层HTTP报文被分成了两个ChannelBuffer，这两个Buffer对我们上层的逻辑(HTTP处理)是没有意义的。但是两个ChannelBuffer被组合起来，就成为了一个有意义的HTTP报文，这个报文对应的ChannelBuffer，才是能称之为”Message”的东西，这里用到了一个词”Virtual Buffer”。可以看一下netty提供的CompositeChannelBuffer源码：

```java
public class CompositeChannelBuffer extends AbstractChannelBuffer {

    private final ByteOrder order;
    private ChannelBuffer[] components;
    private int[] indices;
    private int lastAccessedComponentId;
    private final boolean gathering;
    
    public byte getByte(int index) {
        int componentId = componentId(index);
        return components[componentId].getByte(index - indices[componentId]);
    }
    ...省略...
```

components用来保存的就是所有接收到的buffer，indices记录每个buffer的起始位置，lastAccessedComponentId记录上一次访问的ComponentId；CompositeChannelBuffer并不会开辟新的内存并直接复制所有ChannelBuffer内容，而是直接保存了所有ChannelBuffer的引用，并在子ChannelBuffer里进行读写，实现了零拷贝。



# MQ的零拷贝

RocketMQ和Kafka都使用到了零拷贝的技术。

RocketMQ 选择了 mmap + write 这种零拷贝方式，适用于业务级消息这种小块文件的数据持久化和传输；而 Kafka 采用的是 sendfile 这种零拷贝方式，适用于系统日志消息这种高吞吐量的大块文件的数据持久化和传输。但是值得注意的一点是，Kafka 的索引文件使用的是 mmap + write 方式，数据文件使用的是 sendfile 方式。

| 消息队列 | 零拷贝方式   | 优点                                                         | 缺点                                                         |
| -------- | ------------ | ------------------------------------------------------------ | ------------------------------------------------------------ |
| RocketMQ | mmap + write | 适用于小块文件传输，频繁调用时，效率很高                     | 不能很好的利用 DMA 方式，会比 sendfile 多消耗 CPU，内存安全性控制复杂，需要避免 JVM Crash 问题 |
| Kafka    | sendfile     | 可以利用 DMA 方式，消耗 CPU 较少，大块文件传输效率高，无内存安全性问题 | 小块文件效率低于 mmap 方式，只能是 BIO 方式传输，不能使用 NIO 方式 |



# 参考

[浅析操作系统和Netty中的零拷贝机制](https://mp.weixin.qq.com/s/yelN_YLyjuYwRtfbZ6V-lA)

[逛到底层看NIO的零拷贝](https://mp.weixin.qq.com/s?__biz=MzU1NTc4NTE4NQ==&mid=2247485110&idx=1&sn=38222f4f38b509c50d2fc1e8666a7401&chksm=fbce4838ccb9c12e4d2190590d18e2c01d12d5794f63263e5b4f04a4f6c800ad21d2174171ce&scene=178&cur_album_id=1775872781121798150#rd)

[蚂蚁金服二面：面试官问我零拷贝的实现原理，当场跪。。。](https://mp.weixin.qq.com/s?__biz=MzU0OTk3ODQ3Ng==&mid=2247486661&idx=1&sn=baba4510bf8892f56ae16b8cfdfb6974&chksm=fba6e4c6ccd16dd004f548444dbd1f48f5d0e780877ebe893cf7313de882f461257987037f03&mpshare=1&scene=1&srcid=&sharer_sharetime=1575024923643&sharer_shareid=e4b458a8ccb808fbd3001b9266388a76#rd)

[阿里二面：什么是mmap？](https://mp.weixin.qq.com/s/sG0rviJlhVtHzGfd5NoqDQ)

[Netty、Kafka 中的零拷贝技术这次我彻底懂了](https://mp.weixin.qq.com/s?__biz=Mzg2MDYzODI5Nw==&mid=2247494073&idx=1&sn=3d4da3740fc71e96a37a2564d30c9a82&source=41#wechat_redirect)

[深入剖析Linux IO原理和几种零拷贝机制的实现](https://juejin.cn/post/6844903949359644680#heading-0)

