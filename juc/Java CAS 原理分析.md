## 1. 简介

CAS 全称是 compare and swap，是一种用于在多线程环境下实现同步功能的机制。CAS 操作包含三个操作数 – 内存位置、预期数值和新值。CAS 的实现逻辑是将内存位置处的数值与预期数值想比较，若相等，则将内存位置处的值替换为新值。若不相等，则不做任何操作。

在 Java 中，Java 并没有直接实现 CAS，CAS 相关的实现是通过 C++ 内联汇编的形式实现的。Java 代码需通过 JNI 才能调用。关于实现上的细节，我将会在第3章进行分析。

前面说了 CAS 操作的流程，并不是很难。但仅有上面的说明还不够，接下来我将会再介绍一点其他的背景知识。有这些背景知识，才能更好的理解后续的内容。

## 2.背景介绍

我们都知道，CPU 是通过总线和内存进行数据传输的。在多核心时代下，多个核心通过同一条总线和内存以及其他硬件进行通信。如下图：

![img](http://blog-1259650185.cosbj.myqcloud.com/img/202201/07/1641539007.jpg)

上图是一个较为简单的计算机结构图，虽然简单，但足以说明问题。在上图中，CPU 通过两个蓝色箭头标注的总线与内存进行通信。大家考虑一个问题，CPU 的多个核心同时对同一片内存进行操作，若不加以控制，会导致什么样的错误？这里简单说明一下，假设核心1经32位带宽的总线向内存写入64位的数据，核心1要进行两次写入才能完成整个操作。若在核心1第一次写入32位的数据后，核心2从核心1写入的内存位置读取了64位数据。由于核心1还未完全将64位的数据全部写入内存中，核心2就开始从该内存位置读取数据，那么读取出来的数据必定是混乱的。

不过对于这个问题，实际上不用担心。通过 Intel 开发人员手册，我们可以了解到自奔腾处理器开始，Intel 处理器会保证以原子的方式读写按64位边界对齐的四字（quadword）。

根据上面的说明，我们可总结出，Intel 处理器可以保证单次访问内存对齐的指令以原子的方式执行。但如果是两次访存的指令呢？答案是无法保证。比如递增指令`inc dword ptr [...]`，等价于`DEST = DEST + 1`。该指令包含三个操作`读->改->写`，涉及两次访存。考虑这样一种情况，在内存指定位置处，存放了一个为1的数值。现在 CPU 两个核心同时执行该条指令。两个核心交替执行的流程如下：

1. 核心1 从内存指定位置出读取数值1，并加载到寄存器中。
2. 核心2 从内存指定位置出读取数值1，并加载到寄存器中。
3. 核心1 将寄存器中值递加1。
4. 核心2 将寄存器中值递加1。
5. 核心1 将修改后的值写回内存
6. 核心2 将修改后的值写回内存。

经过执行上述流程，内存中的最终值时2，而我们期待的是3，这就出问题了。要处理这个问题，就要避免两个或多个核心同时操作同一片内存区域。那么怎样避免呢？这就要引入本文的主角 - lock 前缀。关于该指令的详细描述，可以参考 Intel 开发人员手册 Volume 2 Instruction Set Reference，Chapter 3 Instruction Set Reference A-L。我这里引用其中的一段，如下：

> LOCK—Assert LOCK# Signal Prefix
> Causes the processor’s LOCK# signal to be asserted during execution of the accompanying instruction (**turns the instruction into an atomic instruction**). In a multiprocessor environment, the LOCK# signal **ensures that the processor has exclusive use of any shared memory** while the signal is asserted.

上面描述的重点已经用黑体标出了，在多处理器环境下，LOCK# 信号可以确保处理器独占使用某些共享内存。lock 可以被添加在下面的指令前：

ADD, ADC, AND, BTC, BTR, BTS, CMPXCHG, CMPXCH8B, CMPXCHG16B, DEC, INC, NEG, NOT, OR, SBB, SUB, XOR, XADD, and XCHG.

通过在 inc 指令前添加 lock 前缀，即可让该指令具备原子性。多个核心同时执行同一条 inc 指令时，会以串行的方式进行，也就避免了上面所说的那种情况。那么这里还有一个问题，lock 前缀是怎样保证核心独占某片内存区域的呢？答案如下：

在 Intel 处理器中，有两种方式保证处理器的某个核心独占某片内存区域。第一种方式是通过锁定总线，让某个核心独占使用总线，但这样代价太大。总线被锁定后，其他核心就不能访问内存了，可能会导致其他核心短时内停止工作。第二种方式是锁定缓存，若某处内存数据被缓存在处理器缓存中。处理器发出的 LOCK# 信号不会锁定总线，而是锁定缓存行对应的内存区域。其他处理器在这片内存区域锁定期间，无法对这片内存区域进行相关操作。相对于锁定总线，锁定缓存的代价明显比较小。关于总线锁和缓存锁，更详细的描述请参考 Intel 开发人员手册 Volume 3 Software Developer’s Manual，Chapter 8 Multiple-Processor Management。

## 3. 源码分析

有了上面的背景知识，现在我们就可以从容不迫的阅读 CAS 的源码了。本章的内容将对 java.util.concurrent.atomic 包下的原子类 AtomicInteger 中的 compareAndSet 方法进行分析，相关分析如下：

```java
public class AtomicInteger extends Number implements java.io.Serializable {

    // setup to use Unsafe.compareAndSwapInt for updates
    private static final Unsafe unsafe = Unsafe.getUnsafe();
    private static final long valueOffset;

    static {
        try {
            // 计算变量 value 在类对象中的偏移
            valueOffset = unsafe.objectFieldOffset
                (AtomicInteger.class.getDeclaredField("value"));
        } catch (Exception ex) { throw new Error(ex); }
    }

    private volatile int value;
    
    public final boolean compareAndSet(int expect, int update) {
        /*
         * compareAndSet 实际上只是一个壳子，主要的逻辑封装在 Unsafe 的 
         * compareAndSwapInt 方法中
         */
        return unsafe.compareAndSwapInt(this, valueOffset, expect, update);
    }
    
    // ......
}

public final class Unsafe {
    // compareAndSwapInt 是 native 类型的方法，继续往下看
    public final native boolean compareAndSwapInt(Object o, long offset,
                                                  int expected,
                                                  int x);
    // ......
}
```

```cpp
// unsafe.cpp
/*
 * 这个看起来好像不像一个函数，不过不用担心，不是重点。UNSAFE_ENTRY 和 UNSAFE_END 都是宏，
 * 在预编译期间会被替换成真正的代码。下面的 jboolean、jlong 和 jint 等是一些类型定义（typedef）：
 * 
 * jni.h
 *     typedef unsigned char   jboolean;
 *     typedef unsigned short  jchar;
 *     typedef short           jshort;
 *     typedef float           jfloat;
 *     typedef double          jdouble;
 * 
 * jni_md.h
 *     typedef int jint;
 *     #ifdef _LP64 // 64-bit
 *     typedef long jlong;
 *     #else
 *     typedef long long jlong;
 *     #endif
 *     typedef signed char jbyte;
 */
UNSAFE_ENTRY(jboolean, Unsafe_CompareAndSwapInt(JNIEnv *env, jobject unsafe, jobject obj, jlong offset, jint e, jint x))
  UnsafeWrapper("Unsafe_CompareAndSwapInt");
  oop p = JNIHandles::resolve(obj);
  // 根据偏移量，计算 value 的地址。这里的 offset 就是 AtomaicInteger 中的 valueOffset
  jint* addr = (jint *) index_oop_from_field_offset_long(p, offset);
  // 调用 Atomic 中的函数 cmpxchg，该函数声明于 Atomic.hpp 中
  return (jint)(Atomic::cmpxchg(x, addr, e)) == e;
UNSAFE_END

// atomic.cpp
unsigned Atomic::cmpxchg(unsigned int exchange_value,
                         volatile unsigned int* dest, unsigned int compare_value) {
  assert(sizeof(unsigned int) == sizeof(jint), "more work to do");
  /*
   * 根据操作系统类型调用不同平台下的重载函数，这个在预编译期间编译器会决定调用哪个平台下的重载
   * 函数。相关的预编译逻辑如下：
   * 
   * atomic.inline.hpp：
   *    #include "runtime/atomic.hpp"
   *    
   *    // Linux
   *    #ifdef TARGET_OS_ARCH_linux_x86
   *    # include "atomic_linux_x86.inline.hpp"
   *    #endif
   *   
   *    // 省略部分代码
   *    
   *    // Windows
   *    #ifdef TARGET_OS_ARCH_windows_x86
   *    # include "atomic_windows_x86.inline.hpp"
   *    #endif
   *    
   *    // BSD
   *    #ifdef TARGET_OS_ARCH_bsd_x86
   *    # include "atomic_bsd_x86.inline.hpp"
   *    #endif
   * 
   * 接下来分析 atomic_windows_x86.inline.hpp 中的 cmpxchg 函数实现
   */
  return (unsigned int)Atomic::cmpxchg((jint)exchange_value, (volatile jint*)dest,
                                       (jint)compare_value);
}
```

上面的分析看起来比较多，不过主流程并不复杂。如果不纠结于代码细节，还是比较容易看懂的。接下来，我会分析 Windows 平台下的 Atomic::cmpxchg 函数。继续往下看吧。

```cpp
// atomic_windows_x86.inline.hpp             
inline jint Atomic::cmpxchg (jint exchange_value, volatile jint* dest, jint compare_value) {
  // alternative for InterlockedCompareExchange
  int mp = os::is_MP();
  __asm {
    mov edx, dest
    mov ecx, exchange_value
    mov eax, compare_value
    LOCK_IF_MP(mp)
    cmpxchg dword ptr [edx], ecx
  }
}
```

上面的代码由 LOCK_IF_MP 预编译标识符和 cmpxchg 函数组成。为了看到更清楚一些，我们将 cmpxchg 函数中的 LOCK_IF_MP 替换为实际内容。如下：

```cpp
inline jint Atomic::cmpxchg (jint exchange_value, volatile jint* dest, jint compare_value) {
  // 判断是否是多核 CPU
  int mp = os::is_MP();
  __asm {
    // 将参数值放入寄存器中
    mov edx, dest    // 注意: dest 是指针类型，这里是把内存地址存入 edx 寄存器中
    mov ecx, exchange_value
    mov eax, compare_value
    
    // LOCK_IF_MP
    cmp mp, 0
    /*
     * 如果 mp = 0，表明是线程运行在单核 CPU 环境下。此时 je 会跳转到 L0 标记处，
     * 也就是越过 _emit 0xF0 指令，直接执行 cmpxchg 指令。也就是不在下面的 cmpxchg 指令
     * 前加 lock 前缀。
     */
    je L0
    /*
     * 0xF0 是 lock 前缀的机器码，这里没有使用 lock，而是直接使用了机器码的形式。至于这样做的
     * 原因可以参考知乎的一个回答：
     *     https://www.zhihu.com/question/50878124/answer/123099923
     */ 
    _emit 0xF0
L0:
    /*
     * 比较并交换。简单解释一下下面这条指令，熟悉汇编的朋友可以略过下面的解释:
     *   cmpxchg: 即“比较并交换”指令
     *   dword: 全称是 double word，在 x86/x64 体系中，一个 
     *          word = 2 byte，dword = 4 byte = 32 bit
     *   ptr: 全称是 pointer，与前面的 dword 连起来使用，表明访问的内存单元是一个双字单元
     *   [edx]: [...] 表示一个内存单元，edx 是寄存器，dest 指针值存放在 edx 中。
     *          那么 [edx] 表示内存地址为 dest 的内存单元
     *          
     * 这一条指令的意思就是，将 eax 寄存器中的值（compare_value）与 [edx] 双字内存单元中的值
     * 进行对比，如果相同，则将 ecx 寄存器中的值（exchange_value）存入 [edx] 内存单元中。
     */
    cmpxchg dword ptr [edx], ecx
  }
}
```

到这里 CAS 的实现过程就讲完了，CAS 的实现离不开处理器的支持。以上这么多代码，其实核心代码就是一条带lock 前缀的 cmpxchg 指令，即`lock cmpxchg dword ptr [edx], ecx`。

## 4. ABA 问题

谈到 CAS，基本上都要谈一下 CAS 的 ABA 问题。CAS 由三个步骤组成，分别是“读取->比较->写回”。考虑这样一种情况，线程1和线程2同时执行 CAS 逻辑，两个线程的执行顺序如下：

1. 时刻1：线程1执行读取操作，获取原值 A，然后线程被切换走
2. 时刻2：线程2执行完成 CAS 操作将原值由 A 修改为 B
3. 时刻3：线程2再次执行 CAS 操作，并将原值由 B 修改为 A
4. 时刻4：线程1恢复运行，将比较值（compareValue）与原值（oldValue）进行比较，发现两个值相等。
   然后用新值（newValue）写入内存中，完成 CAS 操作

如上流程，线程1并不知道原值已经被修改过了，在它看来并没什么变化，所以它会继续往下执行流程。对于 ABA 问题，通常的处理措施是对每一次 CAS 操作设置版本号。java.util.concurrent.atomic 包下提供了一个可处理 ABA 问题的原子类 AtomicStampedReference，具体的实现这里就不分析了，有兴趣的朋友可以自己去看看。

## 5. 总结

写到这里，这篇文章总算接近尾声了。虽然 CAS 本身的原理，包括实现都不是很难，但是写起来真的不太好写。这里面涉及到了一些底层的知识，虽然能看懂，但想说明白，还是有点难度的。由于我底层的知识比较欠缺，上面的一些分析难免会出错。所以如有错误，请轻喷，当然最好能说明怎么错的，感谢。

好了，本篇文章就到这里。感谢阅读，再见。

## 参考

[Java CAS 原理分析](https://www.tianxiaobo.com/2018/05/15/Java-%E4%B8%AD%E7%9A%84-CAS-%E5%8E%9F%E7%90%86%E5%88%86%E6%9E%90/)
