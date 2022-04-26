## 内存对齐类SizeClasses

在学习Netty内存池之前，我们先了解一下Netty的内存对齐类SizeClasse，表示对于内存池中分配的内存大小需要对齐的size，它为Netty内存池中的内存块提供大小对齐，索引计算等服务方法。在jemalloc论文中将其分为了三块,分别为Small、Large和Huge。其中Small和Large是在Arena中分配的，而Huge则是直接在Arena之外进行分配的。下面则是其对应的各个size的图。

![img](http://blog-1259650185.cosbj.myqcloud.com/img/202112/19/1639923189.png)

不过对于Netty来说其对应的sizeClasses是有所不同的。下面的表格展示了netty的默认配置下对应的sizeClasses中缓存的数据内容，其中后面size、hSize和Dsize不是其缓存的数据，size表示的是netty所支持的所有Huge之外的对齐的size(即从netty内存池中获取的除了Huge之外的内存的大小一定是size中的一个)。size是利用log2Group、nDelta和log2Delta计算出来的，其计算公式为：

```java
size = 1 << log2Group + nDelta * (1 << log2Delta)
```

其中，log2Group是内存块分组，nDelta是增量乘数，log2Delta是增量大小的log2值。

| index | log2Group | log2Delta | nDelta | isMultiPageSize | isSubPage | log2DeltaLookup | size     | hSize  | Dsize |
| ----- | --------- | --------- | ------ | --------------- | --------- | --------------- | -------- | ------ | ----- |
| 0     | 4         | 4         | 0      | 0               | 1         | 4               | 16       | 16B    | 0B    |
| 1     | 4         | 4         | 1      | 0               | 1         | 4               | 32       | 32B    | 16B   |
| 2     | 4         | 4         | 2      | 0               | 1         | 4               | 48       | 48B    | 16B   |
| 3     | 4         | 4         | 3      | 0               | 1         | 4               | 64       | 64B    | 16B   |
| 4     | 6         | 4         | 1      | 0               | 1         | 4               | 80       | 80B    | 16B   |
| 5     | 6         | 4         | 2      | 0               | 1         | 4               | 96       | 96B    | 16B   |
| 6     | 6         | 4         | 3      | 0               | 1         | 4               | 112      | 112B   | 16B   |
| 7     | 6         | 4         | 4      | 0               | 1         | 4               | 128      | 128B   | 16B   |
| 8     | 7         | 5         | 1      | 0               | 1         | 5               | 160      | 160B   | 32B   |
| 9     | 7         | 5         | 2      | 0               | 1         | 5               | 192      | 192B   | 32B   |
| 10    | 7         | 5         | 3      | 0               | 1         | 5               | 224      | 224B   | 32B   |
| 11    | 7         | 5         | 4      | 0               | 1         | 5               | 256      | 256B   | 32B   |
| 12    | 8         | 6         | 1      | 0               | 1         | 6               | 320      | 320B   | 64B   |
| 13    | 8         | 6         | 2      | 0               | 1         | 6               | 384      | 384B   | 64B   |
| 14    | 8         | 6         | 3      | 0               | 1         | 6               | 448      | 448B   | 64B   |
| 15    | 8         | 6         | 4      | 0               | 1         | 6               | 512      | 512B   | 64B   |
| 16    | 9         | 7         | 1      | 0               | 1         | 7               | 640      | 640B   | 128B  |
| 17    | 9         | 7         | 2      | 0               | 1         | 7               | 768      | 768B   | 128B  |
| 18    | 9         | 7         | 3      | 0               | 1         | 7               | 896      | 896B   | 128B  |
| 19    | 9         | 7         | 4      | 0               | 1         | 7               | 1024     | 1KB    | 128B  |
| 20    | 10        | 8         | 1      | 0               | 1         | 8               | 1280     | 1.25KB | 256B  |
| 21    | 10        | 8         | 2      | 0               | 1         | 8               | 1536     | 1.5KB  | 256B  |
| 22    | 10        | 8         | 3      | 0               | 1         | 8               | 1792     | 1.75KB | 256B  |
| 23    | 10        | 8         | 4      | 0               | 1         | 8               | 2048     | 2KB    | 256B  |
| 24    | 11        | 9         | 1      | 0               | 1         | 9               | 2560     | 2.5KB  | 512B  |
| 25    | 11        | 9         | 2      | 0               | 1         | 9               | 3072     | 3KB    | 512B  |
| 26    | 11        | 9         | 3      | 0               | 1         | 9               | 3584     | 3.5KB  | 512B  |
| 27    | 11        | 9         | 4      | 0               | 1         | 9               | 4096     | 4KB    | 512B  |
| 28    | 12        | 10        | 1      | 0               | 1         | 0               | 5120     | 5KB    | 1KB   |
| 29    | 12        | 10        | 2      | 0               | 1         | 0               | 6144     | 6KB    | 1KB   |
| 30    | 12        | 10        | 3      | 0               | 1         | 0               | 7168     | 7KB    | 1KB   |
| 31    | 12        | 10        | 4      | 1               | 1         | 0               | 8192     | 8KB    | 1KB   |
| 32    | 13        | 11        | 1      | 0               | 1         | 0               | 10240    | 10KB   | 2KB   |
| 33    | 13        | 11        | 2      | 0               | 1         | 0               | 12288    | 12KB   | 2KB   |
| 34    | 13        | 11        | 3      | 0               | 1         | 0               | 14336    | 14KB   | 2KB   |
| 35    | 13        | 11        | 4      | 1               | 1         | 0               | 16384    | 16KB   | 2KB   |
| 36    | 14        | 12        | 1      | 0               | 1         | 0               | 20480    | 20KB   | 4KB   |
| 37    | 14        | 12        | 2      | 1               | 1         | 0               | 24576    | 24KB   | 4KB   |
| 38    | 14        | 12        | 3      | 0               | 1         | 0               | 28672    | 28KB   | 4KB   |
| 39    | 14        | 12        | 4      | 1               | 0         | 0               | 32768    | 32KB   | 4KB   |
| 40    | 15        | 13        | 1      | 1               | 0         | 0               | 40960    | 40KB   | 8KB   |
| 41    | 15        | 13        | 2      | 1               | 0         | 0               | 49152    | 48KB   | 8KB   |
| 42    | 15        | 13        | 3      | 1               | 0         | 0               | 57344    | 56KB   | 8KB   |
| 43    | 15        | 13        | 4      | 1               | 0         | 0               | 65536    | 64KB   | 8KB   |
| 44    | 16        | 14        | 1      | 1               | 0         | 0               | 81920    | 80KB   | 16KB  |
| 45    | 16        | 14        | 2      | 1               | 0         | 0               | 98304    | 96KB   | 16KB  |
| 46    | 16        | 14        | 3      | 1               | 0         | 0               | 114688   | 112KB  | 16KB  |
| 47    | 16        | 14        | 4      | 1               | 0         | 0               | 131072   | 128KB  | 16KB  |
| 48    | 17        | 15        | 1      | 1               | 0         | 0               | 163840   | 160KB  | 32KB  |
| 49    | 17        | 15        | 2      | 1               | 0         | 0               | 196608   | 192KB  | 32KB  |
| 50    | 17        | 15        | 3      | 1               | 0         | 0               | 229376   | 224KB  | 32KB  |
| 51    | 17        | 15        | 4      | 1               | 0         | 0               | 262144   | 256KB  | 32KB  |
| 52    | 18        | 16        | 1      | 1               | 0         | 0               | 327680   | 320KB  | 64KB  |
| 53    | 18        | 16        | 2      | 1               | 0         | 0               | 393216   | 384KB  | 64KB  |
| 54    | 18        | 16        | 3      | 1               | 0         | 0               | 458752   | 448KB  | 64KB  |
| 55    | 18        | 16        | 4      | 1               | 0         | 0               | 524288   | 512KB  | 64KB  |
| 56    | 19        | 17        | 1      | 1               | 0         | 0               | 655360   | 640KB  | 128KB |
| 57    | 19        | 17        | 2      | 1               | 0         | 0               | 786432   | 768KB  | 128KB |
| 58    | 19        | 17        | 3      | 1               | 0         | 0               | 917504   | 896KB  | 128KB |
| 59    | 19        | 17        | 4      | 1               | 0         | 0               | 1048576  | 1MB    | 128KB |
| 60    | 20        | 18        | 1      | 1               | 0         | 0               | 1310720  | 1.25MB | 256KB |
| 61    | 20        | 18        | 2      | 1               | 0         | 0               | 1572864  | 1.5MB  | 256KB |
| 62    | 20        | 18        | 3      | 1               | 0         | 0               | 1835008  | 1.75MB | 256KB |
| 63    | 20        | 18        | 4      | 1               | 0         | 0               | 2097152  | 2MB    | 256KB |
| 64    | 21        | 19        | 1      | 1               | 0         | 0               | 2621440  | 2.5MB  | 512KB |
| 65    | 21        | 19        | 2      | 1               | 0         | 0               | 3145728  | 3MB    | 512KB |
| 66    | 21        | 19        | 3      | 1               | 0         | 0               | 3670016  | 3.5MB  | 512KB |
| 67    | 21        | 19        | 4      | 1               | 0         | 0               | 4194304  | 4MB    | 512KB |
| 68    | 22        | 20        | 1      | 1               | 0         | 0               | 5242880  | 5MB    | 1MB   |
| 69    | 22        | 20        | 2      | 1               | 0         | 0               | 6291456  | 6MB    | 1MB   |
| 70    | 22        | 20        | 3      | 1               | 0         | 0               | 7340032  | 7MB    | 1MB   |
| 71    | 22        | 20        | 4      | 1               | 0         | 0               | 8388608  | 8MB    | 1MB   |
| 72    | 23        | 21        | 1      | 1               | 0         | 0               | 10485760 | 10MB   | 2MB   |
| 73    | 23        | 21        | 2      | 1               | 0         | 0               | 12582912 | 12MB   | 2MB   |
| 74    | 23        | 21        | 3      | 1               | 0         | 0               | 14680064 | 14MB   | 2MB   |
| 75    | 23        | 21        | 4      | 1               | 0         | 0               | 16777216 | 16MB   | 2MB   |

hSize则是为了方便查看而将其转换为B这种形式，Dsize则是size与上一个size的差值。

SizeClasses初始化后，将计算chunkSize（内存池每次向操作系统申请内存块大小）范围内每个size的值，保存到sizeClasses字段中。

sizeClasses是一个表格（二维数组），共有7列，各列的含义（从0开始）如下：

0. index：内存块size的索引。
1. log2Group：表示的对应size的内存块分组，用于计算对应的size。
2. log2Delata：增量大小的log2值，用于计算对应的size，就是和上一个sizeClass的差值的log2值，其实就是Dsize的log2值。
3. nDelta：增量乘数，用于计算对应的size。
4. isMultipageSize：表示size是否为page的倍数（这个表格的一个page的大小是8kB，故是8kB的倍数的size标记为1）。
5. isSubPage：表示是否为一个subPage类型（即这种类型的size需要利用subPage进行分配）。
6. log2DeltaLookup：表示的是lookup的size的值即为log2Delata值，其它时间则为0（代码中没看到具体用处）。

从表格中可以看到其最小的分配单位是16B,最大的是16MB(这里的16MB不是netty的最大的分配大小，比16MB大的归为Huge类，netty直接从堆或者堆外内存中分配，不进行池化操作)。从16B到16MB，其中间的size的大小的生成规则其实就是以4个为一组，每组中其对应的与上一个size的差值是一样的(即log2Delta一样)，而每组之间的差值数据则是以2的幂次进行增长(即log2Delta每隔一组会加一)，当然第一组特殊除外。

netty中SizeClasses是PoolArena的父类，其主要是根据pageSize，chunkSize等信息根据上面的规则生成对应的size的表格，并提供索引到size，size到索引的映射等功能，以便其他组件如PoolChunk，PoolArena，PoolSubPage等判断其是否为subPage，以及利用size和索引的映射关系来建立索引相关的池表示每种size的对应的池。

下面是SizeClasses这个的构造器主要的初始化是生成了sizeClasses，sizeIdx2sizeTab，pageIdx2SizeTab以及size2IdxTab这几个缓存表。

- sizeClasses:这个表即为上面的存储了log2Group等7个数据的表格。
- sizeIdx2sizeTab:这个表格存的则是索引和对应的size的对应表格（其实就是上面表格中size那一列的数据）。
- pageIdx2SizeTab:这个表格存储的是上面的表格中isMultiPages是1的对应的size的数据（主要用于监控的数据）。
- sizeIdxTab:这个表格主要存储的是lookup下的size以每2B为单位存储一个size到其对应的size的缓存值(主要是对小数据类型的对应的idx的查找进行缓存)。

```java
protected SizeClasses(int pageSize, int pageShifts, int chunkSize, int directMemoryCacheAlignment) {
    this.pageSize = pageSize; // 这个是8192，8KB
    this.pageShifts = pageShifts; // 用于辅助计算的（pageSize的最高位需要左移的次数） 13  ===> 2 ^ 13 = 8192
    this.chunkSize = chunkSize; // 16M  chunk 大小
    this.directMemoryCacheAlignment = directMemoryCacheAlignment; // 对齐基准，主要是对于Huge这种直接分配的类型的数据将其对其为directMemoryCacheAlignment的倍数
    // 计算出group的数量，24 + 1 - 4 = 19个group
    int group = log2(chunkSize) + 1 - LOG2_QUANTUM;

    //generate size classes，生成sizeClasses,对于这个数组的7个位置的每一位表示的含义为
    //[index, log2Group, log2Delta, nDelta, isMultiPageSize, isSubPage, log2DeltaLookup]
    sizeClasses = new short[group << LOG2_SIZE_CLASS_GROUP][7];
    nSizes = sizeClasses();
    // 生成idx对size的表格,这里的sizeIdx2sizeTab存储的就是利用(1 << log2Group) + (nDelta << log2Delta)计算的size
    //generate lookup table
    sizeIdx2sizeTab = new int[nSizes];
    pageIdx2sizeTab = new int[nPSizes]; //pageIdx2sizeTab则存储的是isMultiPageSize是1的对应的size
    idx2SizeTab(sizeIdx2sizeTab, pageIdx2sizeTab);
    // 生成size对idx的表格，这里存储的是lookupMaxSize以下的，并且其size的单位是1<<LOG2_QUANTUM
    size2idxTab = new int[lookupMaxSize >> LOG2_QUANTUM];
    size2idxTab(size2idxTab);
}
```

SizeClasses类中负责计算sizeClasses表格的代码如下：

```java
// SizeClasses.java
private int sizeClasses() {
    int normalMaxSize = -1;

    int index = 0;
    int size = 0;

    int log2Group = LOG2_QUANTUM; // log2Group = LOG2_QUANTUM = 4
    int log2Delta = LOG2_QUANTUM; // log2Delta = LOG2_QUANTUM = 4
    int ndeltaLimit = 1 << LOG2_SIZE_CLASS_GROUP; // ndeltaLimit = 1 << 2 = 4，表示的是每一组的数量，内存块size以4个为一组进行分组

    //First small group, nDelta start at 0.
    //first size class is 1 << LOG2_QUANTUM
    int nDelta = 0; // 初始化第0组
    while (nDelta < ndeltaLimit) { // nDelta从0开始
        size = sizeClass(index++, log2Group, log2Delta, nDelta++); // sizeClass方法计算sizeClasses每一行内容
    }
    log2Group += LOG2_SIZE_CLASS_GROUP; // 从第1组开始，log2Group增加LOG2_SIZE_CLASS_GROUP，即log2Group = 6，而log2Delta = 4 不变
    // 所以 log2Group += LOG2_SIZE_CLASS_GROUP，等价于 log2Group = log2Delta + LOG2_SIZE_CLASS_GROUP
    //All remaining groups, nDelta start at 1.
    while (size < chunkSize) { // 初始化后面的size
        nDelta = 1; // nDelta从1开始
        // 生成一组内存块，nDeleta从1到1 << LOG2_SIZE_CLASS_GROUP，即1到4的内存块
        while (nDelta <= ndeltaLimit && size < chunkSize) {
            size = sizeClass(index++, log2Group, log2Delta, nDelta++);
            normalMaxSize = size;
        }
        // 每组log2Group+1，log2Delta+1
        log2Group++;
        log2Delta++;
    }

    //chunkSize must be normalMaxSize
    assert chunkSize == normalMaxSize; // 进行了断言,表示chunkSize必须是sizeClass的最后一个

    //return number of size index
    return index;
}

//calculate size class
private int sizeClass(int index, int log2Group, int log2Delta, int nDelta) {
    short isMultiPageSize;
    if (log2Delta >= pageShifts) {
        isMultiPageSize = yes;
    } else {
        int pageSize = 1 << pageShifts;
        int size = (1 << log2Group) + (1 << log2Delta) * nDelta; // 计算公式
        // 因为上文中可以得到，log2Group = log2Delta + LOG2_SIZE_CLASS_GROUP
        // 所以，int size = (1 << (log2Delta + LOG2_SIZE_CLASS_GROUP)) + (1 << log2Delta) * nDelta =  (2 ^ LOG2_SIZE_CLASS_GROUP + nDelta) * (1 << log2Delta)
        isMultiPageSize = size == size / pageSize * pageSize? yes : no;
    }

    int log2Ndelta = nDelta == 0? 0 : log2(nDelta);

    byte remove = 1 << log2Ndelta < nDelta? yes : no;

    int log2Size = log2Delta + log2Ndelta == log2Group? log2Group + 1 : log2Group;
    if (log2Size == log2Group) {
        remove = yes;
    }

    short isSubpage = log2Size < pageShifts + LOG2_SIZE_CLASS_GROUP? yes : no;

    int log2DeltaLookup = log2Size < LOG2_MAX_LOOKUP_SIZE ||
                          log2Size == LOG2_MAX_LOOKUP_SIZE && remove == no
            ? log2Delta : no;

    short[] sz = {
            (short) index, (short) log2Group, (short) log2Delta,
            (short) nDelta, isMultiPageSize, isSubpage, (short) log2DeltaLookup
    };

    sizeClasses[index] = sz;
    int size = (1 << log2Group) + (nDelta << log2Delta);

    if (sz[PAGESIZE_IDX] == yes) {
        nPSizes++;
    }
    if (sz[SUBPAGE_IDX] == yes) {
        nSubpages++;
        smallMaxSizeIdx = index;
    }
    if (sz[LOG2_DELTA_LOOKUP_IDX] != no) {
        lookupMaxSize = size;
    }
    return size;
}
```

从转化后的size计算公式`size = (2 ^ LOG2_SIZE_CLASS_GROUP + nDelta) * (1 << log2Delta)`可以看到，每个内存块size都是(1 << log2Delta)的倍数。从第二组开始，每组内这个倍数依次是5，6，7，8...

每组内相邻行大小增量为(1 << log2Delta)，相邻组之间(1 << log2Delta)（注：因为log2Delta++，相当于每组增量翻倍）翻倍。 Netty默认的配置一个page的大小是2^13，即为8KB,默认的一个chunk的大小为16777216，即16MB。sizeClasses表格内存如下：

<img src="http://blog-1259650185.cosbj.myqcloud.com/img/202112/14/1639497307.jpg" alt="img" style="zoom: 50%;" />

Netty内存池中管理了大小不同的内存块，对于这些不同大小的内存块，Netty划分为不同的等级Small，Normal，Huge。Huge是大于chunkSize的内存块，不在表格中，这里也不讨论。

sizeClasses表格可以分为两部分：

1. isSubPage为1、size为Small内存块，其他为Normal内存块。
   分配Small内存块，需要找到对应的index。通过size2SizeIdx方法计算index。
   比如需要分配一个90字节的内存块，需要从sizeClasses表格找到第一个大于90的内存块size，即96，其index为5。
2. Normal内存块必须是page的倍数。
   将isMultipageSize为1的行取出组成另一个表格。

​		<img src="http://blog-1259650185.cosbj.myqcloud.com/img/202112/15/1639497602.jpg" alt="img" style="zoom:67%;" />

PoolChunk中分配Normal内存块需求查询对应的pageIdx。比如要分配一个50000字节的内存块，需要从这个新表格找到第一个大于50000的内存块size，即57344，其pageIdx为6。

通过pages2pageIdxCompute方法计算pageIdx，就是根据给定的页数来计算出其对应的页的序号。下面看一下具体的计算方法：

```java
// SizeClasses.java
@Override
public int size2SizeIdx(int size) {
    if (size == 0) {
        return 0;
    }
    if (size > chunkSize) { // 大于chunkSize，则返回nSizes，代表申请的是Huge内存块。
        return nSizes;
    }

    if (directMemoryCacheAlignment > 0) { // directMemoryCacheAlignment默认为0， >0 表示不使用sizeClasses表格，直接将申请内存大小转换为directMemoryCacheAlignment的倍数。
        size = alignSize(size);
    }
    // SizeClasses将一部分较小的size与对应index记录在size2idxTab作为位图，这里直接查询size2idxTab，避免重复计算
    if (size <= lookupMaxSize) { // size2idxTab中保存了(size-1)/(2^LOG2_QUANTUM) --> idx的对应关系。
        //size-1 / MIN_TINY。  从sizeClasses方法可以看到，sizeClasses表格中每个size都是(2^LOG2_QUANTUM) 的倍数。
        return size2idxTab[size - 1 >> LOG2_QUANTUM];
    }
    // 对申请内存大小进行log2的向上取整，就是每组最后一个内存块size。-1是为了避免申请内存大小刚好等于2的指数次幂时被翻倍。
    int x = log2((size << 1) - 1); // 将log2Group = log2Delta + LOG2_SIZE_CLASS_GROUP，nDelta=2^LOG2_SIZE_CLASS_GROUP代入计算公式，可得lastSize = 1 << (log2Group + 1)，即x = log2Group + 1
    int shift = x < LOG2_SIZE_CLASS_GROUP + LOG2_QUANTUM + 1 //  shift，当前在第几组，从0开始（sizeClasses表格中0~3行为第0组，4~7行为第1组，以此类推，不是log2Group）
            ? 0 : x - (LOG2_SIZE_CLASS_GROUP + LOG2_QUANTUM); // x < LOG2_SIZE_CLASS_GROUP + LOG2_QUANTUM + 1，即log2Group < LOG2_SIZE_CLASS_GROUP + LOG2_QUANTUM，满足该条件的是第0组的size，这时shift固定是0。
    //从sizeClasses方法可以看到，除了第0组，都满足shift = log2Group - LOG2_QUANTUM - (LOG2_SIZE_CLASS_GROUP - 1)。
    int group = shift << LOG2_SIZE_CLASS_GROUP; // group = shift << LOG2_SIZE_CLASS_GROUP，就是该组第一个内存块size的索引
    // 计算log2Delta。第0组固定是LOG2_QUANTUM。除了第0组，将nDelta = 2^LOG2_SIZE_CLASS_GROUP代入计算公式，lastSize = ( 2^LOG2_SIZE_CLASS_GROUP + 2^LOG2_SIZE_CLASS_GROUP ) * (1 << log2Delta)
    // lastSize = (1 << log2Delta) << LOG2_SIZE_CLASS_GROUP << 1
    int log2Delta = x < LOG2_SIZE_CLASS_GROUP + LOG2_QUANTUM + 1
            ? LOG2_QUANTUM : x - LOG2_SIZE_CLASS_GROUP - 1;
    // 前面已经定位到第几组了，下面要找到申请内存大小应分配在该组第几位，这里要找到比申请内存大的最小size。申请内存大小可以理解为上一个size加上一个不大于(1 << log2Delta)的值，即
    //(nDelta - 1 + 2^LOG2_SIZE_CLASS_GROUP) * (1 << log2Delta) + n， 备注：0 < n <= (1 << log2Delta)。注意，nDelta - 1就是mod
    int deltaInverseMask = -1 << log2Delta;
    int mod = (size - 1 & deltaInverseMask) >> log2Delta & // & deltaInverseMask，将申请内存大小最后log2Delta个bit位设置为0，可以理解为减去n。>> log2Delta，右移log2Delta个bit位，就是除以(1 << log2Delta)，结果就是(nDelta - 1 + 2 ^ LOG2_SIZE_CLASS_GROUP)
              (1 << LOG2_SIZE_CLASS_GROUP) - 1; // & (1 << LOG2_SIZE_CLASS_GROUP) - 1， 取最后的LOG2_SIZE_CLASS_GROUP个bit位的值，结果就是mod
    // size - 1，是为了申请内存等于内存块size时避免分配到下一个内存块size中，即n == (1 << log2Delta)的场景。
    return group + mod; // 第0组由于log2Group等于log2Delta，代入计算公式如下：1 << log2Delta + (nDelta - 1) * (1 << log2Delta) + n， 备注：0 < n <= (1 << log2Delta)
    // nDelta * (1 << log2Delta) + n，所以第0组nDelta从0开始，mod = nDelta
}
```

pages2pageIdxCompute方法计算pageIdx逻辑与size2SizeIdx方法类似，只是将LOG2_QUANTUM变量换成了pageShifts，这里不再重复。

size2idxTab方法比较简单，其主要是1在lookupMaxSize一下的小的size，以每隔2B为单位生成个(size-1)/2B-->idx的对应关系，从而在size小于lookupMaxSize时可以直接从size2idxTab数组中获取对应的idx。

```java
private void size2idxTab(int[] size2idxTab) {
    int idx = 0;
    int size = 0;

    for (int i = 0; size <= lookupMaxSize; i++) {
        int log2Delta = sizeClasses[i][LOG2DELTA_IDX];
        int times = 1 << log2Delta - LOG2_QUANTUM;
        // 以2B为单位,每隔2B生成一个size->idx的对应关系
        while (size <= lookupMaxSize && times-- > 0) {
            size2idxTab[idx++] = i;
            size = idx + 1 << LOG2_QUANTUM;
        }
    }
}
```

SizeClasses是给PoolArena（内存池），PoolChunk(内存块)提供服务的，建议大家结合后面分析PoolArena，PoolChunk的文章一起理解。

如果大家对SizeClasses具体算法不感兴趣，只有理解SizeClasses类中利用sizeClasses表格，为PoolArena，PoolChunk提供计算index，pageIdx索引的方法，也可以帮助大家理解后面解析PoolArena，PoolChunk的文章。

------

## 内存池与PoolArena

我们知道，Netty使用直接内存实现Netty零拷贝以提升性能，但直接内存的创建和释放可能需要涉及系统调用，是比较昂贵的操作，如果每个请求都创建和释放一个直接内存，那性能肯定是不能满足要求的。这时就需要使用内存池，即从系统中申请一大块内存，再在上面分配每个请求所需的内存。

Netty中的内存池主要涉及PoolArena，PoolChunk与PoolSubpage。本节主要分析PoolArena的作用与实现。

PoolArena是外部申请内存的主要入口，在多线程处理器中，每个线程都会对应一个DirectPoolArena和HeapArena，而其选取的策略则是轮询找出最少的thread的arena，这种轮询的方式能让每个PoolArena中的Thread更加的平均，下面图则是线程和PoolArena的对应图。

![img](http://blog-1259650185.cosbj.myqcloud.com/img/202112/22/1640140316.png)

这种线程模型保证的是同一个线程对应下分配的PooledByteBuf是在同一块的PoolArena中，但是同一个线程进行free的PooledByteBuf则不一定是同一个PoolArena。

PoolThreadCache则是实现上面的线程和PoolArena的对应的主要方式，它是维护在ThreadLocal，即每个线程都会有一个PoolThreadCache，而PoolThreadCache则会指向一个PoolArena，表示每个线程的分配都会在同一个PoolArena中进行的。

### 接口关系

ByteBufAllocator，内存分配器，负责为ByteBuf分配内存，线程安全。

PooledByteBufAllocator，池化内存分配器，默认的ByteBufAllocator，预先从操作系统中申请一大块内存，在该内存上分配内存给ByteBuf，可以提高性能和减小内存碎片。

UnPooledByteBufAllocator，非池化内存分配器，每次都从操作系统中申请内存。

RecvByteBufAllocator，接收内存分配器，为Channel读入的IO数据分配一块大小合理的buffer空间。具体功能交由内部接口Handle定义。它主要是针对Channel读入场景添加一些操作，如 guess，incMessagesRead，lastBytesRead等等。

ByteBuf，分配好的内存块，可以直接使用。

下面只关注PooledByteBufAllocator，它是Netty中默认的内存分配器，也是理解Netty内存机制的难点。

### 流程概览

回忆一下NioSocketChannel的数据读取流程。

```java
// NioByteUnsafe.java
public final void read() {
    ...
    final RecvByteBufAllocator.Handle allocHandle = recvBufAllocHandle();
    allocHandle.reset(config);

    ByteBuf byteBuf = null;

    ...
    byteBuf = allocHandle.allocate(allocator);
    allocHandle.lastBytesRead(doReadBytes(byteBuf));
    ...
}
```

recvBufAllocHandle方法返回AdaptiveRecvByteBufAllocator.HandleImpl。(AdaptiveRecvByteBufAllocator，PooledByteBufAllocator都在DefaultChannelConfig中初始化)

AdaptiveRecvByteBufAllocator.HandleImpl#allocate -> AbstractByteBufAllocator#ioBuffer -> PooledByteBufAllocator#directBuffer -> PooledByteBufAllocator#newDirectBuffer

```java
// PooledByteBufAllocator.java
@Override
protected ByteBuf newDirectBuffer(int initialCapacity, int maxCapacity) {
  	//  从当前线程中获取缓存，这里的get方法会调用初始化方法 initialValue() ，会实例化 PoolThreadCache
    PoolThreadCache cache = threadCache.get(); 
    // 获取直接内存竞技场
    PoolArena<ByteBuffer> directArena = cache.directArena;

    final ByteBuf buf;
    if (directArena != null) {
        buf = directArena.allocate(cache, initialCapacity, maxCapacity); // 在当前线程内存池上分配内存
    } else { // 如果缓存中没有，就只能用UnpooledDirectByteBuf创建了
        buf = PlatformDependent.hasUnsafe() ?
                UnsafeByteBufUtil.newUnsafeDirectByteBuf(this, initialCapacity, maxCapacity) :
                new UnpooledDirectByteBuf(this, initialCapacity, maxCapacity);
    }

    return toLeakAwareBuffer(buf);
}
```

AbstractByteBufAllocator#ioBuffer方法会判断当前系统是否支持unsafe。支持时使用直接内存，不支持则使用堆内存。这里只关注默认的直接内存的实现。

### PoolThreadCache

PooledByteBufAllocator#threadCache是一个PoolThreadLocalCache实例，是PooledByteBufAllocator为线程分配的一个缓存器，主要是维护这个线程对的PoolArena，并对这个线程中的释放了的ByteBuf在PoolArena中对应的内存进行缓存，以便PooledByteBuf在申请内存可以直接从对应内存中获取。PoolThreadCache类就好比为同城仓库，可以就近提取中小型货物。

<img src="http://blog-1259650185.cosbj.myqcloud.com/img/202112/23/1640230115.png" alt="PoolThreadCache" style="zoom: 67%;" />

这里，新引入一个数据类型MemoryRegionCache，其内部是一个ByteBuf队列。每个节点是一个ByteBuf的说法并不准确，切确的说，是不再使用的ByteBuf待释放的内存空间，可以再次使用这部分空间构建ByteBuf对象。根据分配请求大小的不同，

MemoryRegionCache可以分为Small和Normal两种。为了更方便的根据请求分配时的大小找到满足需求的缓存空间，每一种MemoryRegionCache又根据规范化后的大小依次组成数组，Small、Normal的数组大小依次为4、12。

其中ByteBuf队列的长度是有限制的，Tiny、Small、Normal依次为512、256、64。为了更好的理解，举例子如下：

```css
16B  -- TinyCache[1]  -- (Buf512-...-Buf3-Buf2-Buf1)
32B  -- TinyCache[2]  -- ()
496B -- TinyCache[31] -- (Buf2-Buf1)
512B -- SmallCache[0] -- (Buf256-...-Buf3-Buf2-Buf1)
8KB  -- NormalCache[0] - (Buf64 -...-Buf3-Buf2-Buf1)
```

在线程缓存中，待回收的空间根据大小排列，比如，最大空间为16B的ByteBuf被缓存时，将被置于数组索引为1的MemoryRegionCache中，其中又由其中的队列存放该ByteBuf的空间信息，队列的最大长度为512。也就是说，16B的ByteBuf空间可以缓存512个，512B可以缓存256个，8KB可以缓存64个。

PoolThreadLocalCache继承于FastThreadLocal，FastThreadLocal这里简单理解为对ThreadLocal的优化，为每个线程维护了一个PoolThreadCache，PoolThreadCache上关联了内存池。当PoolThreadLocalCache上某个线程的PoolThreadCache不存在时，通过initialValue方法构造。

```java
// PooledByteBufAllocator.java
@Override
// 在执行get方法的时候会执行initialValue（）方法，来初始化数据。
protected synchronized PoolThreadCache initialValue() { 
  	// 堆内存Arena；这里是比较所有PoolArena看下哪个被使用最少，找到使用率最少的那个，使得线程均等使用Arena。
    final PoolArena<byte[]> heapArena = leastUsedArena(heapArenas); 
  	// 直接内存Arena，也是找到使用率最少的那个，构造PooledByteBufAllocator时默认初始化了8个PoolArena。
    final PoolArena<ByteBuffer> directArena = leastUsedArena(directArenas); 
    // 构造PoolThreadCache
    final Thread current = Thread.currentThread();
    if (useCacheForAllThreads || current instanceof FastThreadLocalThread) { // 线程是FastTreadLocalTread 这里在NioEventLoop初始化的时候线程就被封装过了
        final PoolThreadCache cache = new PoolThreadCache( // 创建一个PoolTreadCache实例
                heapArena, directArena, smallCacheSize, normalCacheSize,
                DEFAULT_MAX_CACHED_BUFFER_CAPACITY, DEFAULT_CACHE_TRIM_INTERVAL);

        if (DEFAULT_CACHE_TRIM_INTERVAL_MILLIS > 0) {
            final EventExecutor executor = ThreadExecutorMap.currentExecutor();
            if (executor != null) {
                executor.scheduleAtFixedRate(trimTask, DEFAULT_CACHE_TRIM_INTERVAL_MILLIS,
                        DEFAULT_CACHE_TRIM_INTERVAL_MILLIS, TimeUnit.MILLISECONDS);
            }
        }
        return cache;
    }
    // No caching so just use 0 as sizes.
    return new PoolThreadCache(heapArena, directArena, 0, 0, 0, 0);
}
```

当设置全局变量useCacheForAllThreads为true（默认情况true）时或者线程是FastThreadLocalThread的子类（IO线程）时，才会启用缓存。

其中的leastUsedArena()方法，使得线程均等使用Arena，代码如下：

```java
// PooledByteBufAllocator.java
private <T> PoolArena<T> leastUsedArena(PoolArena<T>[] arenas) {
    if (arenas == null || arenas.length == 0) {
        return null;
    }
    // 寻找使用缓存最少的arena
    PoolArena<T> minArena = arenas[0];
    for (int i = 1; i < arenas.length; i++) {
        PoolArena<T> arena = arenas[i];
        if (arena.numThreadCaches.get() < minArena.numThreadCaches.get()) {
            minArena = arena;
        }
    }

    return minArena;
}
```

每次都寻找被最少线程使用的Arena分配新的线程，这样每个Arena都能均等分到线程数，从而平均Arena的负载。

当线程生命周期结束时，调用onRemoval()方法进行一些清理操作，代码如下：

```java
// PooledByteBufAllocator.java
@Override
protected void onRemoval(PoolThreadCache threadCache) {
    threadCache.free(false); // 释放线程缓存中未分配的空间
} // 释放的时候，为子类提供的空方法
```

PoolArena，可以理解为一个内存池，负责管理从操作系统中申请到的内存块。PoolThreadCache为每一个线程关联一个PoolArena（PoolThreadCache#directArena），该线程的内存都在该PoolArena上分配。

下面图展示了其内的MemoryRegionCache的数据结构，其内为每一个sizeClasses维护了一个队列，这个队列里面的存储的是对象是Entry，这个Entry主要维护了PoolChunk，handle和normalCapacity这三个数据指向PoolArena中的一块内存。

在外部申请内存时会找其对应的一个Entry中缓存的PoolArena中的内存分配给这个新分配的PooledByteBuf，并将Entry还给Entry池。在PooledByteBuf释放一块内存时，其会从Entry池中获取一个Entry，并存上PoolChunk，handle等信息并放入其对应的队列中，以便给后面的PooledByteBuf用。

![img](http://blog-1259650185.cosbj.myqcloud.com/img/202112/22/1640178602.png)

PoolThreadCache主要是维护了两种类型的PoolArena表示这个线程所对应的PoolArena，以及4种类型的MemoryReginCache主要是维护对应的Entry队列，以及allocation主要是用来维护分配次数，它的主要作用是和freeSweepAllocationThreshold一起来确定trim的时机。

#### 数据结构

```java
// PoolThreadCache.java
final class PoolThreadCache {
    final PoolArena<byte[]> heapArena;//其对应的heap类型的PoolArena
    final PoolArena<ByteBuffer> directArena;//其对应的堆外内存的PoolArena
    //对不同类型的pageCachees
    private final MemoryRegionCache<byte[]>[] smallSubPageHeapCaches;
    private final MemoryRegionCache<ByteBuffer>[] smallSubPageDirectCaches;
    private final MemoryRegionCache<byte[]>[] normalHeapCaches;
    private final MemoryRegionCache<ByteBuffer>[] normalDirectCaches;
    // Used for bitshifting when calculate the index of normal caches later
    private final int numShiftsNormalDirect;
    private final int numShiftsNormalHeap;
    private final int freeSweepAllocationThreshold;//缓存命中多少次后进行trim操作
    private final AtomicBoolean freed = new AtomicBoolean();//缓存是否被释放标识
    private int allocations;//缓存命中次数
  
 }
```

再看一下构造方法：

```java
// PoolThreadCache.java
PoolThreadCache(PoolArena<byte[]> heapArena, PoolArena<ByteBuffer> directArena,
                int smallCacheSize, int normalCacheSize, int maxCachedBufferCapacity,
                int freeSweepAllocationThreshold) {
    checkPositiveOrZero(maxCachedBufferCapacity, "maxCachedBufferCapacity");
    this.freeSweepAllocationThreshold = freeSweepAllocationThreshold; // 分配次数的阈值
    this.heapArena = heapArena;
    this.directArena = directArena;
    if (directArena != null) {
        smallSubPageDirectCaches = createSubPageCaches( // 创建subPage缓存数组 ，smallCacheSize = 256， PoolArena.numSmallSubpagePools = 4
                smallCacheSize, directArena.numSmallSubpagePools);

        normalDirectCaches = createNormalCaches( // 创建Normal缓存数组 ， normalCacheSize = 64 ， maxCachedBufferCapacity = 32K
                normalCacheSize, maxCachedBufferCapacity, directArena);

        directArena.numThreadCaches.getAndIncrement();
    } else {
        // No directArea is configured so just null out all caches
        smallSubPageDirectCaches = null;
        normalDirectCaches = null;
    }
    if (heapArena != null) {
        // Create the caches for the heap allocations
        smallSubPageHeapCaches = createSubPageCaches(
                smallCacheSize, heapArena.numSmallSubpagePools);

        normalHeapCaches = createNormalCaches(
                normalCacheSize, maxCachedBufferCapacity, heapArena);

        heapArena.numThreadCaches.getAndIncrement();
    } else {
        // No heapArea is configured so just null out all caches
        smallSubPageHeapCaches = null;
        normalHeapCaches = null;
    }

    // Only check if there are caches in use.
    if ((smallSubPageDirectCaches != null || normalDirectCaches != null
            || smallSubPageHeapCaches != null || normalHeapCaches != null)
            && freeSweepAllocationThreshold < 1) {
        throw new IllegalArgumentException("freeSweepAllocationThreshold: "
                + freeSweepAllocationThreshold + " (expected: > 0)");
    }
}
```

缓存数组的构建方法如下：

```java
// PoolThreadCache.java
private static <T> MemoryRegionCache<T>[] createNormalCaches(
        int cacheSize, int maxCachedBufferCapacity, PoolArena<T> area) {
    if (cacheSize > 0 && maxCachedBufferCapacity > 0) {
        int max = Math.min(area.chunkSize, maxCachedBufferCapacity); // 32K 和 16m 取小的 那就是 32K
        List<MemoryRegionCache<T>> cache = new ArrayList<MemoryRegionCache<T>>() ;
        for (int idx = area.numSmallSubpagePools; idx < area.nSizes && area.sizeIdx2size(idx) <= max ; idx++) {
            cache.add(new NormalMemoryRegionCache<T>(cacheSize));
        }
        return cache.toArray(new MemoryRegionCache[0]);
    } else {
        return null;
    }
}
```

其中的参数maxCachedBufferCapacity为缓存Buf的最大容量，因为Normal的ByteBuf最大容量为16MB，且默认缓存64个，这是巨大的内存开销，所以设置该参数调节缓存Buf的最大容量。比如设置为16KB，那么只有16KB和8KB的ByteBuf缓存，其他容量的Normal请求就不缓存，这样大大减小了内存占用。在Netty中，该参数的默认值为32KB。

为了更好的理解回收内存进而再分配的过程，先介绍PoolThreadCache中的数据结构，首先看MemoryRegionCache，它的成员变量如下：

```java
// MemoryRegionCache.java
private final int size; // 队列长度
private final Queue<Entry<T>> queue; // 队列
private final SizeClass sizeClass; // Small/Normal
private int allocations; // 分配次数
```

其中Entry的成员变量如下：

```java
// MemoryRegionCache.Entry.java
final Handle<Entry<?>> recyclerHandle; // 回收该对象
PoolChunk<T> chunk; // ByteBuf之前分配所属的Chunk，chunk、handle和normCapacity这三个数据指向PoolArena中的一块内存
ByteBuffer nioBuffer;
long handle = -1; // ByteBuf在Chunk中的分配信息
int normCapacity;
```

此处重点分析MemoryRegionCache的构造方法：

```java
// MemoryRegionCache.java
MemoryRegionCache(int size, SizeClass sizeClass) {
    this.size = MathUtil.safeFindNextPositivePowerOfTwo(size);  // 对Size进行对齐,  Small = 256
    queue = PlatformDependent.newFixedMpscQueue(this.size); // 创建队列，长度是Size
    this.sizeClass = sizeClass;  // 记录类型
}
```

这里使用了一个MPSC（Multiple Producer Single Consumer）队列即多个生产者单一消费者队列，之所以使用这种类型的队列是因为：ByteBuf的分配和释放可能在不同的线程中，这里的多生产者即多个不同的释放线程，这样才能保证多个释放线程同时释放ByteBuf时所占空间正确添加到队列中。

#### 内存分配

allocate主要是进行内存分配操作，可以看到其最终调用MemoryRegionCache中的allocate方法来分配内存给PooledByteBuf，分配的方式也很见到，就是将队列中Entry缓存的对应的PoolChunk，handle等对应的位置分配给PooledByteBuf。实质的分配依然在MemoryRegionCache中。

不过需要注意的是其在allocations大于freeSweepAllocationThreshold操作时会进行一个trim操作，这个操作主要是在分配次数比较多的情况下进行内存清理的操作。

```java
// PoolThreadCache.java
private boolean allocate(MemoryRegionCache<?> cache, PooledByteBuf buf, int reqCapacity) {
    if (cache == null) {
        // no cache found so just return false here
        return false;
    }
    boolean allocated = cache.allocate(buf, reqCapacity, this);
    if (++ allocations >= freeSweepAllocationThreshold) {
        allocations = 0;
        trim();
    }
    return allocated;
}

// MemoryRegionCache.java
public final boolean allocate(PooledByteBuf<T> buf, int reqCapacity, PoolThreadCache threadCache) {
    Entry<T> entry = queue.poll(); // 从队列头部取出
    if (entry == null) {
        return false;
    }
  	// 在之前ByteBuf同样的内存位置分配一个新的 ByteBuf 对象
    initBuf(entry.chunk, entry.nioBuffer, entry.handle, buf, reqCapacity, threadCache);
    entry.recycle();

    // allocations is not thread-safe which is fine as this is only called from the same thread all time.
    ++ allocations; // 该值是内部量，和上一方法不同
    return true;
}
```

在分配过程还有一个trim()方法，当分配操作达到一定阈值（Netty默认8192）时，没有被分配出去的缓存空间都要被释放，以防止内存泄漏，核心代码如下：

```java
// MemoryRegionCache.java
public final void trim() {
    int free = size - allocations;
    allocations = 0; // allocations 表示已经重新分配出去的ByteBuf个数

    // We not even allocated all the number that are
    if (free > 0) { // 在一定阈值内还没被分配出去的空间将被释放
        free(free, false); // 释放队列中的节点
    }
}
```

也就是说，期望一个MemoryRegionCache频繁进行回收-分配，这样allocations > size，将不会释放队列中的任何一个节点表示的内存空间；但如果长时间没有分配，则应该释放这一部分空间，防止内存占据过多。Small请求缓存256个节点，由此可知当使用率超过 256 / 8192 = 3.125% 时就不会释放节点。

#### 内存回收

明白了这些，开始分析ByteBuf的回收过程，当一个ByteBuf被释放不再使用后，arena首先调用下面两个add方法尝试将内存放入到PoolThreadCache。主要的步骤就是先将其构建成一个Entry，然后放入到对应的MemoryReginCache的队列中。

```java
// PoolThreadCache.java
boolean add(PoolArena<?> area, PoolChunk chunk, ByteBuffer nioBuffer,
            long handle, int normCapacity, SizeClass sizeClass) {
    int sizeIdx = area.size2SizeIdx(normCapacity);
    MemoryRegionCache<?> cache = cache(area, sizeIdx, sizeClass); // 获取缓存对应的数组
    if (cache == null) {
        return false;
    }
    return cache.add(chunk, nioBuffer, handle, normCapacity); // 添加到队列中
}

// MemoryRegionCache.java
public final boolean add(PoolChunk<T> chunk, ByteBuffer nioBuffer, long handle, int normCapacity) {
    Entry<T> entry = newEntry(chunk, nioBuffer, handle, normCapacity); // 新建ENTRY
    boolean queued = queue.offer(entry); //  添加到队列中
    if (!queued) { // 如果队列满了，直接回收entry对象进行下一次分配，不缓存
        // If it was not possible to cache the chunk, immediately recycle the entry
        entry.recycle();
    }

    return queued;
}
```

以上便是PoolThreadCache的回收过程。

#### 内存释放

接下来再分析释放过程，代码如下：

```java
// PoolThreadCache.javas
void free(boolean finalizer) { // 对所有的数组进行释放
    // As free() may be called either by the finalizer or by FastThreadLocal.onRemoval(...) we need to ensure
    // we only call this one time.
    if (freed.compareAndSet(false, true)) {
        int numFreed = free(smallSubPageDirectCaches, finalizer) +
                free(normalDirectCaches, finalizer) +
                free(smallSubPageHeapCaches, finalizer) +
                free(normalHeapCaches, finalizer);

        if (numFreed > 0 && logger.isDebugEnabled()) {
            logger.debug("Freed {} thread-local buffer(s) from thread: {}", numFreed,
                    Thread.currentThread().getName());
        }

        if (directArena != null) {
            directArena.numThreadCaches.getAndDecrement();
        }

        if (heapArena != null) {
            heapArena.numThreadCaches.getAndDecrement();
        }
    }
}

private static int free(MemoryRegionCache<?>[] caches, boolean finalizer) {
    if (caches == null) {
        return 0;
    }

    int numFreed = 0;
    for (MemoryRegionCache<?> c: caches) {
        numFreed += free(c, finalizer);
    }
    return numFreed;
}

private static int free(MemoryRegionCache<?> cache, boolean finalizer) {
    if (cache == null) {
        return 0;
    }
    return cache.free(finalizer);
}
```

与分配和回收稍有不同的是：释放需要遍历Cache数组，对每一个MemoryRegionCache执行free()，代码如下：

```java
// MemoryRegionCache.java
public final int free(boolean finalizer) {
    return free(Integer.MAX_VALUE, finalizer);
}

private int free(int max, boolean finalizer) {
    int numFreed = 0;
    for (; numFreed < max; numFreed++) {
        Entry<T> entry = queue.poll();
        if (entry != null) {
            freeEntry(entry, finalizer);
        } else {
            // all cleared
            return numFreed; // 队列中所有节点都被释放
        }
    }
    return numFreed;
}

private  void freeEntry(Entry entry, boolean finalizer) {
    PoolChunk chunk = entry.chunk;
    long handle = entry.handle;
    ByteBuffer nioBuffer = entry.nioBuffer;

    if (!finalizer) {
        entry.recycle();  // 回收entry对象
    }

    chunk.arena.freeChunk(chunk, handle, entry.normCapacity, sizeClass, nioBuffer, finalizer); // 释放实际的内存空间
}
```

虽然PoolThreadCache名称中含有Thread，但到目前为止的分析，与线程没有一点关系。的确如此，使他们产生联系的正是我们这一节的主题：PoolThreadLocalCache。下面我们回到正题。

------

Netty支持高并发系统，可能有很多线程进行同时内存分配。为了缓解线程竞争，通过创建多个PoolArena细化锁的粒度，从而提高并发执行的效率。

注意，一个PoolArena可以会分给多个的线程，可以看到PoolArena上会有一些同步操作。

### 数据结构

下面的代码展示PoolArena的数据结构，其主要维护的是一个PoolChunkList链表，另一个则是PoolSubpgae池。下面两张图展示的是这两个数据结构，一个由6种按照使用率确定的PoolChunkList组成的链表结构，他的QInit的pre是自己，而Q000的pre为空，以此来实现QInit中的PoolChunk不会被销毁，而Q000中的PoolChunk才能被销毁（详情见下文PoolChunkList实现原理一节）。

![img](http://blog-1259650185.cosbj.myqcloud.com/img/202112/22/1640141180.png)

另一种则是PoolSubPage池，这个PoolSubPage池则是为sizeClasses中所有的是subpage的size维护一个对应的双端循环链表，这些双端循环链表的head是一个特殊的PoolSubPage节点，不会进行内存分配，并且存在smallSubpagePools这个数组中，其数组的索引是每个size在sizeClasses中对应的idx。

<img src="http://blog-1259650185.cosbj.myqcloud.com/img/202112/21/1640091280.png" alt="img" style="zoom:67%;" />

```java
// PoolArena.java
abstract class PoolArena<T> extends SizeClasses implements PoolArenaMetric {
    static final boolean HAS_UNSAFE = PlatformDependent.hasUnsafe();

    enum SizeClass {
        Small,
        Normal
    }

    final PooledByteBufAllocator parent; // 分配这个poolArena对应的allocator

    final int numSmallSubpagePools; // small级别的的双向链表头个数
    final int directMemoryCacheAlignment;
    private final PoolSubpage<T>[] smallSubpagePools; // 数组中每个元素都是一个PoolSubpage链表，PoolSubpage之间可以通过next，prev组成链表。维护的是PoolArena内的所有的PoolChunk内下的所有的PoolSubpage
    // 存储了所有类型的PoolChunkList
    private final PoolChunkList<T> q050;
    private final PoolChunkList<T> q025;
    private final PoolChunkList<T> q000;
    private final PoolChunkList<T> qInit;
    private final PoolChunkList<T> q075;
    private final PoolChunkList<T> q100;
	
  	...

    // Number of thread caches backed by this arena.
    final AtomicInteger numThreadCaches = new AtomicInteger(); // 存储分配给这个PoolArena的对应得到线程的数量
 		... 
}  
```

### 内存分配

第一节分析SizeClasses时说过，Netty将内存池中的内存块按大小划分为3个级别。不同级别的内存块管理算法不同。默认划分规则如下：

- small <= 28672(28K)
- normal <= 16777216(16M)
- huge > 16777216(16M)

smallSubpagePools是一个PoolSubpage数组，负责维护small级别的内存块信息。

PoolChunk负责维护normal级别的内存，PoolChunkList管理一组PoolChunk。

PoolArena按内存使用率将PoolChunk分别维护到6个PoolChunkList中，

- qInit -> 内存使用率为0~25。
- q000 -> 内存使用率为1~50。
- q025 -> 内存使用率为25~75。
- q050 -> 内存使用率为50~75。
- q075 -> 内存使用率为75~100。
- q100 -> 内存使用率为100。

注意：PoolChunk是Netty每次向操作系统申请的内存块。

PoolSubpage需要从PoolChunk中分配，而Tiny，Small级別的内存则是从PoolSubpage中分配。

下面来看一下分配过程，allocate主要根据申请内存的大小分为三种情况，分别为small，normal和huge。需要注意对于huge的分配进行类型对齐，这个directMemoryCacheAlignment>0表示需要进行内存对齐。而对于small和normal的内存对齐则是在size2SizeIdx这个方法中完成。

```java
// PoolArena.java
PooledByteBuf<T> allocate(PoolThreadCache cache, int reqCapacity, int maxCapacity) {
    PooledByteBuf<T> buf = newByteBuf(maxCapacity); // 初始化一块容量为 2^31 - 1的ByteBuf
    allocate(cache, buf, reqCapacity); // reqCapacity = 1024  进入分配逻辑
    return buf;
}

private void allocate(PoolThreadCache cache, PooledByteBuf<T> buf, final int reqCapacity) {
  	// 父类SizeClasses提供的方法，使用特定算法，将申请的内存大小调整为规范大小，划分到对应位置，返回对应索引
    final int sizeIdx = size2SizeIdx(reqCapacity);  // 在PoolSubpage进行分配

    if (sizeIdx <= smallMaxSizeIdx) { // capacity < pageSize 判断校准之后的请求大小 是否小于 28k，分配small级别的内存块
        tcacheAllocateSmall(cache, buf, reqCapacity, sizeIdx);
    } else if (sizeIdx < nSizes) { // 分配normal级别的内存块
        tcacheAllocateNormal(cache, buf, reqCapacity, sizeIdx);  // 在PoolChunk中进行分配
    } else {
      	// 分配huge级别的内存块。如果大于sizeClasses中最大的能分配的大小，则不在池中分配，直接堆或者直接内存中分配
       // directMemoryCacheAlignment表示的是是否需要内存对齐，对于small和normal类型的内存对齐则是在父类的size2SizeIdx方法完成的
        int normCapacity = directMemoryCacheAlignment > 0
                ? normalizeSize(reqCapacity) : reqCapacity;
        // Huge allocations are never served via the cache so just call allocateHuge
        allocateHuge(buf, normCapacity);
    }
}
```

下面跟进一下分配small级别的内存块的流程，tcacheAllocateSmall这个方法主要是对subpage这些小内存的分配工作，主要是先从PoolSubpage池中找到对应的size的PoolSubpage来进行所需内存的分配，如果没有的话会从PoolChunk分配出对应的PoolSubpage，以进行内存分配。 

```java
// PoolArena.java
private void tcacheAllocateSmall(PoolThreadCache cache, PooledByteBuf<T> buf, final int reqCapacity,
                                 final int sizeIdx) {
    // 1.首先尝试在线程缓存上分配。除了PoolArena，PoolThreadCache#smallSubPageHeapCaches还为每个线程维护了Small级别的内存缓存
    if (cache.allocateSmall(this, buf, reqCapacity, sizeIdx)) {
        // was able to allocate out of the cache so move on
        return;
    }

    final PoolSubpage<T> head = smallSubpagePools[sizeIdx]; // 2.使用前面SizeClasses#size2SizeIdx方法计算的索引，获取对应PoolSubpage
    final boolean needsNormalAllocation;
    synchronized (head) { // 注意，head是一个占位节点，并不存储数据。这里必要运行在同步机制中，即会锁定整个链表。
      	// 这里没有进行遍历，因为对应的链表下的所有的PoolSubpage必然没有满并且分配的单块内存都是这个sizeIdx对应的size
        final PoolSubpage<T> s = head.next;
        needsNormalAllocation = s == head; // s==head表示当前不存在可以用的PoolSubpage，因为已经耗尽的PoolSubpage是会从链表中移除。
        if (!needsNormalAllocation) { // 直接从PoolSubpage中分配内存
            assert s.doNotDestroy && s.elemSize == sizeIdx2size(sizeIdx);
            long handle = s.allocate();
            assert handle >= 0;
            s.chunk.initBufWithSubpage(buf, null, handle, reqCapacity, cache);
        }
    }

    if (needsNormalAllocation) { // 没有可用的PoolSubpage，需要申请一个Normal级别的内存块，再在上面分配所需内存
        synchronized (this) {
            allocateNormal(buf, reqCapacity, sizeIdx, cache);
        }
    }

    incSmallAllocation();
}
```

而normal级别的内存也是先尝试在线程缓存中分配，分配失败后再调用allocateNormal方法申请。PoolArena#allocate -> allocateNormal，这种主要是对sizeClass中不是subpage中的内存的分配，默认最小是32KB。其主要是利用5种不同类型的PoolChunkList来进行分配，它按照使用率从大到小进行分配，不过其将Q075移动到最后一个，认为q075几乎已经满了，作为最后的机会分配。jemalloc对这段分配顺序的描述是。

> Fullness categories also provide a mechanism for choosing a new current run from among non-full runs. The order of preference is: Q50, Q25, Q0, then Q75. Q75 is the last choice because such runs may be almost completely full; routinely choosing such runs can result in rapid turnover for the current run.

下面跟进一下详细流程：

```java
// PoolArena.java
private void tcacheAllocateNormal(PoolThreadCache cache, PooledByteBuf<T> buf, final int reqCapacity,
                                  final int sizeIdx) {
    if (cache.allocateNormal(this, buf, reqCapacity, sizeIdx)) { // 从PoolThreadCache中进行分配
        // was able to allocate out of the cache so move on
        return;
    }
    synchronized (this) { // 对于allocateNormal的调用一定需要对PoolArena对象加锁
        allocateNormal(buf, reqCapacity, sizeIdx, cache);
        ++allocationsNormal;
    }
}

private void allocateNormal(PooledByteBuf<T> buf, int reqCapacity, int sizeIdx, PoolThreadCache threadCache) {
 	  // 依次从q050，q025，q000，qInit，q075上申请内存
    if (q050.allocate(buf, reqCapacity, sizeIdx, threadCache) || 
        q025.allocate(buf, reqCapacity, sizeIdx, threadCache) ||
        q000.allocate(buf, reqCapacity, sizeIdx, threadCache) ||
        qInit.allocate(buf, reqCapacity, sizeIdx, threadCache) || // 在qInit中不能分配的内存在q075中是有可能进行分配，因为qInit中的内存使用率虽然是0%~25%，而q075的使用率是75%~100%
        q075.allocate(buf, reqCapacity, sizeIdx, threadCache)) { // 但是qInit中可能没有一块连续的很大的内存，而q075中可能有
        return;
    }

    // Add a new chunk.
    PoolChunk<T> c = newChunk(pageSize, nPSizes, pageShifts, chunkSize);
    boolean success = c.allocate(buf, reqCapacity, sizeIdx, threadCache);
    assert success;
    qInit.add(c); // 首先加入到qInit中
}
```

为什么要依次按照q050，q025，q000，qInit，q075这个顺序申请内存呢？

PoolArena中的PoolChunkList之间也组成一个“双向”链表

```text
qInit ---> q000 <---> q025 <---> q050 <---> q075 <---> q100
```

PoolChunkList中还维护了minUsage，maxUsage，即当一个PoolChunk使用率大于maxUsage，它将被移动到下一个PoolChunkList，使用率小于minUsage，则被移动到前一个PoolChunkList。

注意：q000没有前置节点，它的minUsage为1，即上面的PoolChunk内存完全释放后，将被销毁。

qInit的前置节点是它自己，但它的minUsage为Integer.MIN_VALUE，即使上面的PoolChunk内存完全释放后，也不会被销毁，而是继续保留在内存。

不优先从q000分配，正是因为q000上的PoolChunk内存完全释放后要被销毁，如果在上面分配，则会延迟内存的回收进度。而q075上由于内存利用率太高，导致内存分配的成功率大大降低，因此放到最后。所以从q050是一个不错的选择，这样大部分情况下，Chunk的利用率都会保持在一个较高水平，提高整个应用的内存利用率。

在PoolChunkList上申请内存，PoolChunkList会遍历链表上PoolChunk节点，直到分配成功或到达链表末尾。

PoolChunk分配后，如果内存使用率高于maxUsage，它将被移动到下一个PoolChunkList。

newChunk方法负责构造一个PoolChunk，这里是内存池向操作系统申请内存。

```java
// PoolArena.java
@Override
protected PoolChunk<ByteBuffer> newChunk(int pageSize, int maxPageIdx,
    int pageShifts, int chunkSize) {
    if (directMemoryCacheAlignment == 0) {
        ByteBuffer memory = allocateDirect(chunkSize);
        return new PoolChunk<ByteBuffer>(this, memory, memory, pageSize, pageShifts,
                chunkSize, maxPageIdx);
    }

    final ByteBuffer base = allocateDirect(chunkSize + directMemoryCacheAlignment);
    final ByteBuffer memory = PlatformDependent.alignDirectBuffer(base, directMemoryCacheAlignment);
    return new PoolChunk<ByteBuffer>(this, base, memory, pageSize,
            pageShifts, chunkSize, maxPageIdx);
}
```

allocateDirect方法向操作系统申请内存，获得一个(jvm)ByteBuffer，PoolChunk#memory维护了该ByteBuffer，PoolChunk的内存实际上都是在该ByteBuffer上分配。

最后跟进一下huge级别的内存申请：

```java
// PoolArena.java
private void allocateHuge(PooledByteBuf<T> buf, int reqCapacity) {
    PoolChunk<T> chunk = newUnpooledChunk(reqCapacity);
    activeBytesHuge.add(chunk.chunkSize());
    buf.initUnpooled(chunk, reqCapacity);
    allocationsHuge.increment();
}
```

比较简单，没有使用内存池，直接向操作系统申请内存。

总结一下内存分配过程：

1. 对于Small、Normal大小的请求，优先从线程缓存中分配。
2. 没有从缓存中得到分配的Tiny/Small请求，会从**以第一次请求大小为基准进行分组的Subpage双向链表中进行分配**；如果双向链表还没初始化，则会使用Normal请求分配Chunk块中的一个Page，Page以请求大小为基准进行切分并分配第一块内存，然后加入到双向链表中。
3. 没有从缓存中得到分配的Normal请求，则会使用伙伴算法分配满足要求的连续Page块。
4. 对于Huge请求，则直接使用Unpooled直接分配。

### 内存释放

free方法主要是对内存进行释放，对于huge这些没有池化的内存的释放直接就是destroy（这些内存虽然以PoolChunk的形式维护，但是没有挂在PoolChunkList链表中），而对于其他的则是需要根据其内存使用度调整其在PoolChunkList的所在位置。

```java
// PoolArena.java
void free(PoolChunk<T> chunk, ByteBuffer nioBuffer, long handle, int normCapacity, PoolThreadCache cache) {
    if (chunk.unpooled) { // 如果是非池化的huge类型的内存，直接销毁内存
        int size = chunk.chunkSize();
        destroyChunk(chunk);
        activeBytesHuge.add(-size);
        deallocationsHuge.increment();
    } else { // 如果是池化内存，首先尝试加到线程缓存中，成功则不需要其他操作。失败则调用freeChunk
        SizeClass sizeClass = sizeClass(handle);
      	// PoolThreadCache内存进行分配
        if (cache != null && cache.add(this, chunk, nioBuffer, handle, normCapacity, sizeClass)) {
            // cached so not free it.
            return;
        }

        freeChunk(chunk, handle, normCapacity, sizeClass, nioBuffer, false);
    }
}

void freeChunk(PoolChunk<T> chunk, long handle, int normCapacity, SizeClass sizeClass, ByteBuffer nioBuffer,
               boolean finalizer) {
    final boolean destroyChunk;
    synchronized (this) {
        ...
         // 在PoolChunkList中进行释放,并调整其对应的数据结构
        destroyChunk = !chunk.parent.free(chunk, handle, normCapacity, nioBuffer);
    }
    if (destroyChunk) {
        // destroyChunk not need to be called while holding the synchronized lock.
        destroyChunk(chunk);
    }
}
```

chunk.parent即PoolChunkList，PoolChunkList#free会调用PoolChunk释放内存，释放内存后，如果内存使用率低于minUsage，则移动前一个PoolChunkList，如果前一个PoolChunkList不存在(q000)，则返回false，由后面的步骤销毁该PoolChunk。

### reallocate

reallocate方法是由PooledByteBuf的capacity方法进行调用的，主要是当PooledByteBuf容量扩增时，内存需要重新分配，切换当前ByteBuf的大小，其对应的实现逻辑即为这个PooledByteBuf分配一块新的内存，并将原内存的所有数据copy到新的内存中去（注意这种操作不会切换当前PooledByteBuf的writeIdx和readIdx，不过如果新的内存比当前内存的内存小则会将writeIdx截断到最后一位）。并且将原来的内存进行释放。

```java
// PoolArena.java
void reallocate(PooledByteBuf<T> buf, int newCapacity, boolean freeOldMemory) {
    assert newCapacity >= 0 && newCapacity <= buf.maxCapacity();

    int oldCapacity = buf.length;
    if (oldCapacity == newCapacity) {
        return;
    }

    PoolChunk<T> oldChunk = buf.chunk;
    ByteBuffer oldNioBuffer = buf.tmpNioBuf;
    long oldHandle = buf.handle;
    T oldMemory = buf.memory;
    int oldOffset = buf.offset;
    int oldMaxLength = buf.maxLength;

    // This does not touch buf's reader/writer indices
    allocate(parent.threadCache(), buf, newCapacity); // 重新分配一个newCapacity大小的内存，这里会重新分配一个ByteBuffer
    int bytesToCopy;
    if (newCapacity > oldCapacity) {
        bytesToCopy = oldCapacity;
    } else {
        buf.trimIndicesToCapacity(newCapacity); // 如果新的分配的内存比原来的小,则将对应的ByteBuf的readIdx和writeIdx截断到最后一个位置
        bytesToCopy = newCapacity;
    }
    memoryCopy(oldMemory, oldOffset, buf, bytesToCopy); // 将原先内存的数据copy到新分配的内存中
    if (freeOldMemory) {
        free(oldChunk, oldNioBuffer, oldHandle, oldMaxLength, buf.cache);
    }
}
```

------

## PoolChunk实现原理

这一节主要分享Netty中PoolChunk如何管理内存。PoolChunk表示的内存池中一整块的内存，也是内存池向Java虚拟机申请和释放的最小单位，即内存池每次会向虚拟机申请一个PoolChunk内存来进行分配，并在PoolChunk空闲时将PoolChunk中的内存释放。

内存池对于内存的分配其最终分配的是内存所处的PoolChunk以及PoolChunk下的句柄handle。

### 主要概念

在介绍PoolChunk代码之前先介绍几个比较主要的概念。

- page：page是PoolChunk的分配的最小单位，默认的1个page的大小为8kB。
- run：表示的是一个page的集合。
- chunk：表示的是一个run的集合。
- handle:句柄，用于表示PoolChunk中一块内存的位置、大小、使用情况等信息，下面的图展示了一个handle的对应的位数的含义。可以看到一个handle其实是一个64位的long型数字，其前15位表示的是这个句柄所处的位置，即第几页，后面15位表示的是这个句柄表示的是多少页，isUsed表示这一段内存是否被使用，isSubpage表示的这一段内存是否用于subPage的分配，bitmapIdx表示的是这块内存在subPage中bitMap的第几个。

![img](http://blog-1259650185.cosbj.myqcloud.com/img/202112/20/1639965054.png)

### 内存管理算法

首先说明一下PoolChunk内存组织方式。PoolChunk的**内存大小默认是16M**，Netty将它划分为2048个page，每个page为8K。PoolChunk上可以分配Normal内存块。Normal内存块大小必须是page的倍数。

PoolChunk通过runsAvail字段管理内存块。PoolChunk#runsAvail是PriorityQueue数组，其中PriorityQueue存放的是handle。handle可以理解为一个句柄，维护一个内存块的信息，由以下部分组成：

- o: runOffset ，在chunk中page偏移索引，从0开始，15bit。
- s: size，当前位置可分配的page数量，15bit。
- u: isUsed，是否使用， 1bit。
- e: isSubpage，是否在subpage中， 1bit。
- b: bitmapIdx，内存块在subpage中的索引，不在subpage则为0， 32bit。

在第一节里说过SizeClasses将sizeClasses表格中isMultipageSize为1的行取出可以组成一个新表格，这里称为Page表格。

![img](http://blog-1259650185.cosbj.myqcloud.com/img/202112/16/1639668991.jpg)

runsAvail数组默认长度为40，每个位置index上放的handle代表了存在一个可用内存块，并且可分配pageSize大于等于(pageIdx=index)上的pageSize，小于(pageIdex=index+1)的pageSize。

例如，runsAvail[11]上的handle的size可分配pageSize可能为16 ~ 19，假如runsAvail[11]上handle的size为18，如果该handle分配了7个page，剩下的11个page，这时要将handle移动runsAvail[8]（当然，handle的信息要调整）。

这时如果要找分配6个page，就可以从runsAvail[5]开始查找runsAvail数组，如果前面runsAvail[5]~runsAvail[7]都没有handle，就找到了runsAvail[8]。

分配6个page之后，剩下的5个page，handle移动runsAvail[4]。

先看一下PoolChunk的主要成员变量和构造函数：

```java
// PoolChunk.java

final PoolArena<T> arena; // 所处的PoolArena
final Object base;
final T memory; // 维护的内存块，用泛型区分是堆内存还是直接内存
final boolean unpooled; // 表示这个PoolChunk是没进行池化操作的，主要为Huge的size的内存分配

private final LongLongHashMap runsAvailMap; // 存储的是有用的run中的第一个和最后一个Page的句柄（handle）

private final LongPriorityQueue[] runsAvail; // 管理所有有用的run,这个数组的索引是SizeClasses中page2PageIdx计算出来的idx，即sizeClass中每个size一个优先队列进行存储

private final PoolSubpage<T>[] subpages; // 管理这个poolchunk中所有的poolSubPag

private final int pageSize;  // 一个page的大小
private final int pageShifts; // pageSize需要左移多少位
private final int chunkSize; // 这个chunk的大小

private final Deque<ByteBuffer> cachedNioBuffers; // 主要是对PooledByteBuf中频繁创建的ByteBuffer进行缓存，以避免由于频繁创建的对象导致频繁的GC

int freeBytes; // 空闲的byte值

PoolChunkList<T> parent; // 所处的PoolChunkLis
PoolChunk<T> prev; // 所处双向链表前一个PoolChunk
PoolChunk<T> next;  // 所处双向两边的后一个PoolChunk


@SuppressWarnings("unchecked")
PoolChunk(PoolArena<T> arena, Object base, T memory, int pageSize, int pageShifts, int chunkSize, int maxPageIdx) {
    unpooled = false; // 不使用内存池
    this.arena = arena; // 该PoolChunk所属的PoolArena
    this.base = base; // 底层内存对齐偏移量
    this.memory = memory; // 底层的内存块，对于堆内存，它是一个byte数组，对于直接内存，它是(jvm)ByteBuffer，但无论是哪种形式，其内存大小默认都是16M。
    this.pageSize = pageSize; // page大小，默认为8K。
    this.pageShifts = pageShifts;
    this.chunkSize = chunkSize; // 整个PoolChunk的内存大小，默认为16777216，即16M。
    freeBytes = chunkSize;

    runsAvail = newRunsAvailqueueArray(maxPageIdx); // 初始化runsAvail
    runsAvailMap = new LongLongHashMap(-1); // 记录了每个内存块开始位置和结束位置的runOffset和handle映射。
    subpages = new PoolSubpage[chunkSize >> pageShifts];

    //insert initial run, offset = 0, pages = chunkSize / pageSize
    int pages = chunkSize >> pageShifts;
    long initHandle = (long) pages << SIZE_SHIFT;
    insertAvailRun(0, pages, initHandle); // 在runsAvail数组最后位置插入一个handle，该handle代表page偏移位置为0的地方可以分配16M的内存块

    cachedNioBuffers = new ArrayDeque<ByteBuffer>(8);
}
```

上面的数据结构中主要是runsAvailMap，runsAvail，subPages和memory这4块数据，下面图描述了这几块数据具体存储的内容。

其中memory部分绿色表示已经分配了的页,空白的表示还没被分配的页，青色部分表示的被分配为subPage的页。

可以看到runsAvailMap存储的是runOffset -> handle之间的键值对，并且其存储的是空闲块的第一页和最后一页的句柄（1、2，6、7，9、10，12、16都是成对放到runsAvailMap里）。runsAvail则是维护的一个优先队列数组，其数组的索引其实是size对应的sizeIdx，可以看到空闲页为2页的内存的三块内存的句柄都存在了runsAvail数组中相同索引位置的优先队列中，而空闲页为5页的内存则存到了runsAvail数组中另一个索引位置对应的优先队列中。subPages则数一个PoolSubPage数组，其数组的索引为page的runOffset，存储的是以这个offset开始的PoolSubPage对象。

<img src="http://blog-1259650185.cosbj.myqcloud.com/img/202112/20/1640015057.png" alt="img"  />

注意：runAvail中的1KB、2KB...等size是错误的，应该都乘上8。

PoolChunk主要的是allocate和free这两个方法，处理分配和释放两个操作,下面来介绍一下这两个方法。

### 内存分配

```java
// PoolChunk.java
boolean allocate(PooledByteBuf<T> buf, int reqCapacity, int sizeIdx, PoolThreadCache cache) {
    final long handle;
  	// sizeIdx表示的是sizeClass的size2sizeIdx计算的对应的sizeIdx，smallMaxSizeIdx表示的是最大的subPage的对应的索引，处理Small内存块申请
    if (sizeIdx <= arena.smallMaxSizeIdx) { 
        // small
        handle = allocateSubpage(sizeIdx);
        if (handle < 0) {
            return false;
        }
        assert isSubpage(handle);
    } else { // 利用allocateRun分配多个整的page，处理Normal内存块申请，sizeIdx2size方法根据内存块索引查找对应内存块size
        // normal
        // runSize must be multiple of pageSize
        int runSize = arena.sizeIdx2size(sizeIdx);
        handle = allocateRun(runSize); // allocateRun方法负责分配Normal内存块，返回handle存储了分配的内存块大小和偏移量。
        if (handle < 0) {
            return false;
        }
    }
		// 从cachedNioBuffers获取缓存的ByteBuffer，一个PoolChunk下的所有的这些ByteBuffer
    ByteBuffer nioBuffer = cachedNioBuffers != null? cachedNioBuffers.pollLast() : null;
    initBuf(buf, nioBuffer, handle, reqCapacity, cache); // 使用handle和底层内存类(ByteBuffer)初始化ByteBuf
    return true;
}

// 分配多个page操作，其主要操作是从runAvail中找到最接近当前需要分配的size的内存块，然后将其进行切分出需要分配的内存块，并将剩下的空闲块再存到runAvail和runsAvailMap中。
private long allocateRun(int runSize) {
    int pages = runSize >> pageShifts; // 1.计算所需的page数量
    int pageIdx = arena.pages2pageIdx(pages); // 2.计算对应的pageIdx，因为runAvail这个数组用的则是这个idx为索引的。注意，pages2pageIdx方法会将申请内存大小对齐为上述Page表格中的一个size。例如申请172032字节(21个page)的内存块，pages2pageIdx方法计算结果为13，实际分配196608(24个page)的内存块。

    synchronized (runsAvail) {
        //find first queue which has at least one big enough run
        int queueIdx = runFirstBestFit(pageIdx); // 3.从当前的pageIdx开始遍历runsAvail，找到第一个handle。该handle上可以分配所需内存块。
        if (queueIdx == -1) {
            return -1;
        }

        //get run with min offset in this queue
        LongPriorityQueue queue = runsAvail[queueIdx];
        long handle = queue.poll();

        assert handle != LongPriorityQueue.NO_VALUE && !isUsed(handle) : "invalid handle: " + handle;

        removeAvailRun(queue, handle); // 4.从runsAvail，runsAvailMap移除该handle信息
        //  5.在第3步找到的handle上划分出所要的内存块。
        if (handle != -1) {
          	// 将这一块内存进行切分，剩余空闲的内存继续存储到ranAvail和runsAvailMap中
            handle = splitLargeRun(handle, pages); 
        }
        // 6.减少可用内存字节数
        freeBytes -= runSize(pageShifts, handle);
        return handle;
    }
}

private long splitLargeRun(long handle, int needPages) {
    assert needPages > 0;
    // totalPages，从handle中获取的当前位置可用page数。
    int totalPages = runPages(handle);
    assert needPages <= totalPages;
    // remPages，分配后剩余的page数
    int remPages = totalPages - needPages;
    // 剩余page数大于0
    if (remPages > 0) {
        int runOffset = runOffset(handle);

        // keep track of trailing unused pages for later use
        int availOffset = runOffset + needPages; // availOffset，计算剩余page开始偏移量
        long availRun = toRunHandle(availOffset, remPages, 0); // 生成一个新的handle
        insertAvailRun(availOffset, remPages, availRun); // 将availRun插入到runsAvail，runsAvailMap中

        // not avail
        return toRunHandle(runOffset, needPages, 1);
    }

    //mark it as used
    handle |= 1L << IS_USED_SHIFT;
    return handle;
}
```

下面图描述了对上面那幅图进行了一次3个page的分配操作后对应的内存的数据结构，可以和上面的图对比一下，其中红色表示的是这次分配的内存，可以看到原来在5kB的内存数据到2kB中，并且存储在runsAvaliMap中的对应的key也由原来的12移到了现在的15。

![img](http://blog-1259650185.cosbj.myqcloud.com/img/202112/21/1640016997.png)

下面看一下allocateSubpage的实现。这个方法是分配一个subPage，其主要的逻辑是先对sizeIdx这个索引在sizeClasses中所对应的size为基础的elemSize获取一个这个elemSize和pageSize的最小公倍数大小的内存，将这块内存分为大小相等的以elmSize的subPage利用PoolSubPage来进行维护。

```java
// PoolChunk.java
private long allocateSubpage(int sizeIdx) {
    // Obtain the head of the PoolSubPage pool that is owned by the PoolArena and synchronize on it.
    // This is need as we may add it back and so alter the linked-list structure.
    // 根据sizeIdx计算出其对应的PoolSubpage，arena以sizeIdx为key存储了一个散列表来存储PoolSubpage，其每个链表的头都是一个特殊的不做内存分配的PoolSubpage的head，对于其对应链表的操作都需要对这个链表的head加锁
    PoolSubpage<T> head = arena.findSubpagePoolHead(sizeIdx); 
    synchronized (head) {
        //allocate a new run
        int runSize = calculateRunSize(sizeIdx); // 计算第一个对这个sizeIdx对应的size与pageSize的最小公倍数
        //runSize must be multiples of pageSize
      	// 分配一个Normal内存块，作为PoolSubpage的底层内存块，大小为Small内存块size和pageSize最小公倍数
        long runHandle = allocateRun(runSize);
        if (runHandle < 0) {
            return -1;
        }
			  // 构建PoolSubpage runOffset，即Normal内存块偏移量，也是该PoolSubpage在整个Chunk中的偏移量elemSize，Small内存块size
        int runOffset = runOffset(runHandle);
        assert subpages[runOffset] == null;
        int elemSize = arena.sizeIdx2size(sizeIdx);
        // 把这个分配的runSize切分为runSize/elemSize个相同的elemSize大小的subPage。利用PoolSubpage进行分配
        PoolSubpage<T> subpage = new PoolSubpage<T>(head, this, pageShifts, runOffset,
                           runSize(pageShifts, runHandle), elemSize);

        subpages[runOffset] = subpage; // 将这个subPage存在subpages中
        return subpage.allocate(); // 在subpage上分配内存块
    }
}
```

### 内存释放

free的进行释放操作，主要操作如果是subpage，利用PoolSubpage进行释放。对于多页的释放则会利用runsAvailMap合并其前后的空闲的内存块，因为runsAvailMap中存储了空闲内存块的头和尾，所以对内存块的合并很简单，即为以当前的头和尾的前一个或者后一个为key能否找到对应的空闲内存合并即可。

```java
// PoolChunk.java
void free(long handle, int normCapacity, ByteBuffer nioBuffer) {
    if (isSubpage(handle)) { // 释放的是subPage
        int sizeIdx = arena.size2SizeIdx(normCapacity);
        PoolSubpage<T> head = arena.findSubpagePoolHead(sizeIdx);

        int sIdx = runOffset(handle);
        PoolSubpage<T> subpage = subpages[sIdx];
        assert subpage != null && subpage.doNotDestroy;

        // Obtain the head of the PoolSubPage pool that is owned by the PoolArena and synchronize on it.
        // This is need as we may add it back and so alter the linked-list structure.
        synchronized (head) {
            if (subpage.free(head, bitmapIdx(handle))) { // 调用subpage#free释放Small内存，返回true则表示这块PoolSubPage还在用，不释放PoolSubpage内存块。返回false，将继续向下执行，这时会释放PoolSubpage整个内存块
                //the subpage is still used, do not free it
                return;
            }
            assert !subpage.doNotDestroy;
            // Null out slot in the array as it was freed and we should not use it anymore.
            subpages[sIdx] = null;
        }
    }

    //start free run
    int pages = runPages(handle); // 计算释放的page数

    synchronized (runsAvail) {
        // collapse continuous runs, successfully collapsed runs
        // will be removed from runsAvail and runsAvailMap
        long finalRun = collapseRuns(handle); // 如果可以，将前后相邻的可用内存块进行合并
        // 插入新的handle
        //set run as not used
        finalRun &= ~(1L << IS_USED_SHIFT); // 将IS_USED和IS_SUBPAGE标志位设置为0
        //if it is a subpage, set it to run
        finalRun &= ~(1L << IS_SUBPAGE_SHIFT); // 将IS_USED和IS_SUBPAGE标志位设置为0

        insertAvailRun(runOffset(finalRun), runPages(finalRun), finalRun); //将合并后的句柄存储到runAvail和runsAvailMap中
        freeBytes += pages << pageShifts;
    }
    // 将这个ByteBuf创建的ByteBuffer存到cachedNioBuffers缓存中
    if (nioBuffer != null && cachedNioBuffers != null &&
        cachedNioBuffers.size() < PooledByteBufAllocator.DEFAULT_MAX_CACHED_BYTEBUFFERS_PER_CHUNK) {
        cachedNioBuffers.offer(nioBuffer);
    }
}

private long collapseRuns(long handle) {
  	// collapsePast方法合并前面的可用内存块，collapseNext方法合并后面的可用内存块
    return collapseNext(collapsePast(handle)); 
}

private long collapsePast(long handle) {
    for (;;) {
        int runOffset = runOffset(handle);
        int runPages = runPages(handle);

        long pastRun = getAvailRunByOffset(runOffset - 1); // 从runsAvailMap中找到下一个内存块的handle。
        if (pastRun == -1) {
            return handle;
        }

        int pastOffset = runOffset(pastRun);
        int pastPages = runPages(pastRun);
        // 如果是连续的内存块，则移除下一个内存块handle，并将其page合并生成一个新的handle。
        //is continuous
        if (pastRun != handle && pastOffset + pastPages == runOffset) {
            //remove past run
            removeAvailRun(pastRun);
            handle = toRunHandle(pastOffset, pastPages + runPages, 0);
        } else {
            return handle;
        }
    }
}
```

下面图则是对开始的内存数据将offset为8的内存块释放后其内存数据结构的情况，可以看到其将前面和后面空闲的内存块合并了，成为了5页的内存块，其对应的runsAvailMap和runsAvail中的数据也进行了相应的改变。 

![img](http://blog-1259650185.cosbj.myqcloud.com/img/202112/21/1640018059.png)

下面再来看一个例子：

![img](http://blog-1259650185.cosbj.myqcloud.com/img/202112/17/1639671659.jpg)

大家可以结合例子中runsAvail和内存使用情况的变化，理解上面的代码。实际上，2个Page的内存块是通过Subpage分配，回收时会放回线程缓存中而不是直接释放存块，但为了展示PoolChunk中内存管理过程，图中不考虑这些场景。

PoolChunk在Netty 4.1.52版本修改了算法，引入了jemalloc 4的算法 -- [Review PooledByteBufAllocator in respect of jemalloc 4.x changes and … · netty/netty@0d701d7](https://link.zhihu.com/?target=https%3A//github.com/netty/netty/commit/0d701d7c3c51263a1eef56d5a549ef2075b9aa9e)

Netty 4.1.52之前的版本，PoolChunk引入的是jemalloc 3的算法，使用二叉树管理内存块。

------

## PoolChunkList实现原理

PoolChunkList主要维护了一个双链表存储PoolArena中的PoolChunk。jemalloc按照内存的使用度将其划分为QInit、Q0、Q25、Q50、Q75和Q100这几个类型，下面入是jemalloc论文中的一张图，展示了每种类型的PoolChunkList内存的使用情况。其中的虚线表示一个PoolChunk从一个类别移动到另一个类别其对应的内存度。

<img src="http://blog-1259650185.cosbj.myqcloud.com/img/202112/08/1638976983.png" alt="img" style="zoom:67%;" />

可以看到对于内存的内存的回收是在Q0的使用度为0%时，而在QINIT在使用率为0%时是不会进行删除的，这样可以保证PoolChunk不会因为一个对象的频繁分配和释放而频繁的创建和销毁，因为要对一个PoolChunk销毁必然是先要将其使用度用到25%升到Q25类型，然后再将内存的数据都释放降到0%才能完成内存的释放。

下面的图则展示了PoolChunkList在netty中的内存的数据结构，可以看到除了Qinit外，其他的类型的PoolChunkList则为一个双向链表，PoolChunkList中的Chunk块也形成双向链表，而QInit的前一个指向的是自己，Q000则没有前置节点，这种设计主要则是为了实现上面**只在Q000中才会对PoolChunk进行释放**，而不会在QInit进行释放，因为netty在进行内存释放时会将当前内存往前移动，如果其前面没有节点则会将这个PoolChunk释放。

![img](http://blog-1259650185.cosbj.myqcloud.com/img/202112/22/1640103700.png)

它们之间的关系如下图所示：

<img src="http://blog-1259650185.cosbj.myqcloud.com/img/202112/23/1640190002.png" alt="Chunk与PoolChunkList" style="zoom:50%;" />

以Q25依次加入Chunk1，Chunk2，Chunk3为例，形成的链表如图，其中Head节点是最后加入的Chunk3节点。Chunk随着内存使用率的变化，会在PoolChunkList中移动，初始时都在QINI，随着使用率增大，移动到Q0，Q25等；随着使用率降低，又移回Q0，当Q0中的Chunk块不再使用时，从Q0中移除。

### 初始化化方法

下面代码块是PoolArena中对PoolChunkList的初始化操作，构建上面的数据结构。

```java
// PoolArena.java
q100 = new PoolChunkList<T>(this, null, 100, Integer.MAX_VALUE, chunkSize);
//传入的即为其下一个节点
q075 = new PoolChunkList<T>(this, q100, 75, 100, chunkSize);
q050 = new PoolChunkList<T>(this, q075, 50, 100, chunkSize);
q025 = new PoolChunkList<T>(this, q050, 25, 75, chunkSize);
q000 = new PoolChunkList<T>(this, q025, 1, 50, chunkSize);
qInit = new PoolChunkList<T>(this, q000, Integer.MIN_VALUE, 25, chunkSize);
 
q100.prevList(q075);
q075.prevList(q050);
q050.prevList(q025);
q025.prevList(q000);
q000.prevList(null);
qInit.prevList(qInit);


// PoolChunkList.java
final class PoolChunkList<T> implements PoolChunkListMetric {
    private static final Iterator<PoolChunkMetric> EMPTY_METRICS = Collections.<PoolChunkMetric>emptyList().iterator();
    private final PoolArena<T> arena; // 所属的Arena
    private final PoolChunkList<T> nextList; // 下一个PoolChunkList
    private final int minUsage; // PoolChunkList的最小内存使用率
    private final int maxUsage; // PoolChunkList的最大内存使用率
    private final int maxCapacity;  // 该PoolChunkList下的一个Chunk可分配的最大字节数
    private PoolChunk<T> head; // head节点
    private final int freeMinThreshold;
    private final int freeMaxThreshold;

    private PoolChunkList<T> prevList; // 上一个PoolChunkList
  
  
  PoolChunkList(PoolArena<T> arena, PoolChunkList<T> nextList, int minUsage, int maxUsage, int chunkSize) {
    assert minUsage <= maxUsage;
    this.arena = arena;
    this.nextList = nextList;
    this.minUsage = minUsage;
    this.maxUsage = maxUsage;
    maxCapacity = calculateMaxCapacity(minUsage, chunkSize); // 计算该PoolChunkList下，一个Chunk块可以分配的最大内存

    freeMinThreshold = (maxUsage == 100) ? 0 : (int) (chunkSize * (100.0 - maxUsage + 0.99999999) / 100L);
    freeMaxThreshold = (minUsage == 100) ? 0 : (int) (chunkSize * (100.0 - minUsage + 0.99999999) / 100L);
}

private static int calculateMaxCapacity(int minUsage, int chunkSize) {
    minUsage = minUsage0(minUsage);

    if (minUsage == 100) {
        // If the minUsage is 100 we can not allocate anything out of this list.
        return 0; // Q100 不能再分配
    }

    return  (int) (chunkSize * (100L - minUsage) / 100L); // Q25中一个Chunk可以分配的最大内存为0.75 * ChunkSize
}
  ...
}  
```

其中的prevList()方法如下：

```java
// PoolChunkList.java
void prevList(PoolChunkList<T> prevList) {
    assert this.prevList == null; // 这个方法只应该在创建时调用一次
    this.prevList = prevList;
}
```

接着分析，在PoolChunkList中的PoolChunk形成的双向链表的操作，代码如下：

```java
// PoolChunkList.java
void add(PoolChunk<T> chunk) {
    if (chunk.freeBytes <= freeMinThreshold) { // 在空闲的bytes小于当前下限时则直接移动到后面一个节点
        nextList.add(chunk);
        return;
    }
    add0(chunk);
}

void add0(PoolChunk<T> chunk) {
    chunk.parent = this;
    if (head == null) { // 可以看到每次add都是加在下一个链表的头部，头插法
        head = chunk;
        chunk.prev = null;
        chunk.next = null;
    } else {
        chunk.prev = null;
        chunk.next = head;
        head.prev = chunk;
        head = chunk;
    }
}
// 从双链表中移除这个节点
private void remove(PoolChunk<T> cur) {
    if (cur == head) {
        head = cur.next;
        if (head != null) {
            head.prev = null;
        }
    } else {
        PoolChunk<T> next = cur.next;
        cur.prev.next = next;
        if (next != null) {
            next.prev = cur.prev;
        }
    }
}
```

对于add方法则会在空闲byte小于下限时继续用其后的list进行add操作。

具体的add0和remove操作则只是对双链表的节点指针进行简单的修改工作，需要注意的是这里都是加到链表的头部。

将一个PoolChunk加入到PoolChunkList中的代码如下：

```java
// PoolChunkList.java
void add(PoolChunk<T> chunk) {
    if (chunk.freeBytes <= freeMinThreshold) { // 在空闲的bytes小于当前下限时则直接移动到后面一个节点
        nextList.add(chunk);
        return;
    }
    add0(chunk);
}
```

注意该方法实质是一个递归调用，在if语句中会找到真正符合状态的PoolChunkList，然后才执行add0()加入PoolChunk节点。随着内存使用率的增加，需要调用add()方法将**PoolChunk向右移动到正确状态的PoolChunkList**；同理，随着内存使用率的减小，也需要一个方法将PoolChunk向左移动到正确状态。在实现中，这个方法为move()，名字带有歧义，忽略名字，代码如下：

```java
// PoolChunkList.java
private boolean move(PoolChunk<T> chunk) {
    assert chunk.usage() < maxUsage;

    if (chunk.freeBytes > freeMaxThreshold) {
        // Move the PoolChunk down the PoolChunkList linked-list.
        return move0(chunk); // 当前节点的空闲byte大于上限，则向前移动，递归调用
    }

    // PoolChunk fits into this PoolChunkList, adding it here.
    add0(chunk);
    return true;
}

private boolean move0(PoolChunk<T> chunk) {
    if (prevList == null) { // 这里没有上一个节点，即为Q0对应的list，并且返回的是false表示的是当前。PoolChunk会被回收
        // There is no previous PoolChunkList so return false which result in having the PoolChunk destroyed and
        // all memory associated with the PoolChunk will be released.
        assert chunk.usage() == 0;
        return false;
    }
    return prevList.move(chunk); // 向左移动
}
```

### 内存分配

对于PoolChunkList主要的也是allocate方法， 这里的allocate方法主要是遍历其内的所有的PoolChunk，并根据其分配后的情况来决定其会不会移动到下一个类型的PoolChunkList中。

```java
// PoolChunkList.java
boolean allocate(PooledByteBuf<T> buf, int reqCapacity, int sizeIdx, PoolThreadCache threadCache) {
    int normCapacity = arena.sizeIdx2size(sizeIdx);
    if (normCapacity > maxCapacity) { // 这里的请求的内存比当前的PoolChunkList的最大的容量，即100%减去当前类型的最小容量
        // Either this PoolChunkList is empty or the requested capacity is larger then the capacity which can
        // be handled by the PoolChunks that are contained in this PoolChunkList.
        return false;
    }
    // 遍历这个链表的所有PoolChunk进行分配
    for (PoolChunk<T> cur = head; cur != null; cur = cur.next) {
        if (cur.allocate(buf, reqCapacity, sizeIdx, threadCache)) { // 单个PoolChunk成功
            if (cur.freeBytes <= freeMinThreshold) { // 这里直接获取freeBytes数据,而不是调用useage方法那样对arena进行synchonized操作，因为此处的操作必然有了arena锁对象
                remove(cur); // 这里如果当前剩下的空闲的byte小于这个类型的最小的下限，则需要将其向上移动到下一个PoolChunkList中
                nextList.add(cur);
            }
            return true;
        }
    }
    return false;
}
```

### 内存释放

free方法主要是对对应的PoolChunk进行释放，不过可以看到这里的PoolChunk是外部传递过来的，PoolByteBuf会持有PoolChunk对象，但是其对其对应内存的释放还是从PooledArena到PoolChunkList，再到PoolChunk进行释放的。

可以看到下面的释放操作当前的空闲内存大于上限时不是调用的add方法，而是调用的move0方法，主要是对于前面链表往前走时可能会有一个Q0类型的PoolChunkList，而其在Q0内存中的内存使用率为0%是会进行PoolChunk的内存回收操作。

```java
// PoolChunkList.java
boolean free(PoolChunk<T> chunk, long handle, int normCapacity, ByteBuffer nioBuffer) {
    chunk.free(handle, normCapacity, nioBuffer);
    if (chunk.freeBytes > freeMaxThreshold) {
        remove(chunk);
        // Move the PoolChunk down the PoolChunkList linked-list.
        return move0(chunk); // 这里调用的不是preList的add操作,而是move0的操作
    }
    return true;
}

private boolean move(PoolChunk<T> chunk) {
    assert chunk.usage() < maxUsage;

    if (chunk.freeBytes > freeMaxThreshold) {
        // Move the PoolChunk down the PoolChunkList linked-list.
        return move0(chunk); // 当前节点的空闲byte大于上限，则向前移动，递归调用
    }

    // PoolChunk fits into this PoolChunkList, adding it here.
    add0(chunk);
    return true;
}

private boolean move0(PoolChunk<T> chunk) {
    if (prevList == null) { // 这里没有上一个节点，即为Q0对应的list，并且返回的是false表示的是当前。PoolChunk会被回收
        // There is no previous PoolChunkList so return false which result in having the PoolChunk destroyed and
        // all memory associated with the PoolChunk will be released.
        assert chunk.usage() == 0;
        return false;
    }
    return prevList.move(chunk); // 向左移动
}
```

### 内存销毁

最后，销毁PoolChunkList的方法如下：

```java
// PoolChunkList.java
void destroy(PoolArena<T> arena) {
    PoolChunk<T> chunk = head;
    while (chunk != null) {
        arena.destroyChunk(chunk); // 释放Chunk
        chunk = chunk.next;
    }
    head = null; // GC回收节点
}
```

------

## PoolSubpage实现原理

前面一节说了PoolChunk如何管理Normal内存块，本节分享一下PoolSubpage如何管理Small内存块。

PoolSubPage主要是对sizeClasses中isSubPage是1的内存的分配（即大小小于1<<(pageshift+LOG22_SIZE_CLASS_GROUP)，就是小于28K的对应的内存）的分配。其主要是在PoolChunk将一页或者多页内存的数据分配为多个第一次请求的内存块，用PoolSubPage来维护。结构如下图：

<img src="http://blog-1259650185.cosbj.myqcloud.com/img/202112/21/1640091280.png" alt="img" style="zoom:67%;" />

![img](http://blog-1259650185.cosbj.myqcloud.com/img/202112/23/1640224509.png)

PoolSubPage用一个bitmap来表示其内的每一块内存的使用情况，对于在PoolChunk中介绍的句柄，在是subPage对应的句柄的后32位 则是这个bitMap中对应的位坐标。

而Subpage又是**由PoolChunk中的一个Page依照第一次分配请求的大小均等切分而成**。可推知，小于PageSize的分配请求执行过程如下：

1. 首次请求Arena分配，Arena中的双向链表为空，不能分配；传递给Chunk分配，Chunk找到一个空闲的Page，然后均等切分并加入到Arena链表中，最后分配满足要求的大小。
2. 之后请求分配同样大小的内存，则直接在Arena中的PoolSubpage双向链表进行分配；如果链表中的节点都没有空间分配，则重复1步骤。

### 数据结构

```java
// PoolSubpage.java
final class PoolSubpage<T> implements PoolSubpageMetric { // PoolSubpage实际上就是PoolChunk中的一个Normal内存块，大小为其管理的内存块size与pageSize最小公倍数。

    final PoolChunk<T> chunk; // 所属的chunk
    private final int pageShifts; // page需要移动的位数，即在整个Chunk的偏移字节数
    private final int runOffset; // 在poolChunk所处的位置
    private final int runSize;
    private final long[] bitmap; // 每个long元素上每个bit位都可以代表一个内存块是否使用。

    PoolSubpage<T> prev; // 链表的前一个节点
    PoolSubpage<T> next; // 链表的后一个节点

    boolean doNotDestroy; // 标识这个PoolSubpage从pool移除，已经被释放了
    int elemSize; // 均等切分的一块内存的大小
    private int maxNumElems; // 最多可以切分的小块数
    private int bitmapLength; // 位图bitmap的长度,long元素的个数（每个long元素上每个bit位都可以代表一个内存块是否使用）
    private int nextAvail; // 下一个可用的内存块坐标缓存
    private int numAvail; // 可用的内存块的数量
  
  PoolSubpage(PoolSubpage<T> head, PoolChunk<T> chunk, int pageShifts, int runOffset, int runSize, int elemSize) {
    this.chunk = chunk;
    this.pageShifts = pageShifts;
    this.runOffset = runOffset;
    this.runSize = runSize;
    this.elemSize = elemSize;
    bitmap = new long[runSize >>> 6 + LOG2_QUANTUM]; //  bitmap长度为runSize / 64 / QUANTUM，此处使用最大值，最小分配16B所需的long个数，从《内存对齐类SizeClasses》可以看到，runSize都是2^LOG2_QUANTUM的倍数。

    doNotDestroy = true;
    if (elemSize != 0) {
        maxNumElems = numAvail = runSize / elemSize; // elemSize：每个subPage的大小，maxNumElems：subPage数量
        nextAvail = 0;
        bitmapLength = maxNumElems >>> 6; // bitmapLength：bitmap使用的long元素个数，使用bitmap中一部分元素足以管理全部内存块。
        if ((maxNumElems & 63) != 0) { // (maxNumElems & 63) != 0，代表maxNumElems不能整除64，所以bitmapLength要加1，用于管理余下的内存块。
            bitmapLength ++; // subpage的总数不是64倍，多需要一个long
        }

        for (int i = 0; i < bitmapLength; i ++) {
            bitmap[i] = 0;
        }
    }
    addToPool(head); //  添加到PoolSubpage链表中
}
  
 ... 
}

private void addToPool(PoolSubpage<T> head) {
    assert prev == null && next == null;
    prev = head;
    next = head.next;
    next.prev = this;
    head.next = this;
}
```

需要注意的是：Netty使用了多个long整数的位数表示位图信息，这部分代码主要是在初始化位图结构。bitmap的最大长度为runSize(约等于 pageSize)>>> 10表示最小分配16(1>>>4)B所需的long(1>>>6)个数(1个long型整数是64位)，此处不使用pageSize/elemSize/64是因为考虑到复用。当一个PoolSubpage以32B均等切分，然后释放返回给Chunk，当Chunk再次被分配时，比如16B，此时只需调用init()方法即可而不再需要初始其他数据。

最后的addToPool()方法将该PoolSubpage加入到Arena的双向链表中，这是经典的双向链表操作，只需注意每次新加入的节点都在Head节点之后。从链表中删除的操作是该操作的逆操作。

### 内存管理算法

PoolSubpage负责管理Small内存块。一个PoolSubpage中的内存块size都相同，该size对应SizeClasses#sizeClasses表格的一个索引index。

新创建的PoolSubpage都必须加入到PoolArena#smallSubpagePools[index]链表中。PoolArena#smallSubpagePools是一个PoolSubpage数组，数组中每个元素都是一个PoolSubpage链表，PoolSubpage之间可以通过next，prev组成链表。

注意，Small内存size并不一定小于pageSize(默认为8K)。默认Small内存size <= 28672(28KB)

**PoolSubpage实际上就是PoolChunk中的一个Normal内存块，大小为其管理的内存块size与pageSize最小公倍数**。

PoolSubpage使用位图的方式管理内存块。PoolSubpage#bitmap是一个long数组，其中每个long元素上每个bit位都可以代表一个内存块是否使用。

### 内存分配

分配Small内存块有两个步骤：

1. 从PoolArena#smallSubpagePools中查找对应的PoolSubpage。如果找到了，直接从该PoolSubpage上分配内存。否则，分配一个Normal内存块，创建PoolSubpage。
2. PoolSubpage上PoolSubpage#allocate分配内存块。allocate方法主要从开始找出第一个空闲的内存块(即其在bitmap中对应的位置的bit位为0)，并且在内存都被分配完时将其从poolSubpage池中移除。

```java
// PoolSubpage.java
long allocate() {
    if (numAvail == 0 || !doNotDestroy) { // numAvail==0表示已经分配完了，而!doNotDestroy则是表示poolSubpage已经从池子里面移除了
        return -1; // 通常PoolSubpage分配完成后会从PoolArena#smallSubpagePools中移除，不再在该PoolSubpage上分配内存，所以一般不会出现这种场景。
    }
    // 在bitmap中从前开始搜索第一个bit为0的可用内存块的坐标
    final int bitmapIdx = getNextAvail();
    int q = bitmapIdx >>> 6; // 获取该内存块在bitmap数组中第q元素。由于bitMap是long[]数组，所以这个bitmapIdx的后6位的2^6=64个数则表示的是这个long的每一位的坐标
    int r = bitmapIdx & 63; // 获取该内存块是bitmap数组中第q个元素的第r个bit位
    assert (bitmap[q] >>> r & 1) == 0;
    bitmap[q] |= 1L << r; // 将bitmap中对应位置的bit标识设置为1，表示已经被分配
    // 如果所用的内存块都被分配完，则从PoolArena的池中移除当前的PoolSubpage
    if (-- numAvail == 0) {
        removeFromPool();
    }
    // 计算出对应的handle来标识这个被分配块的内存位置
    return toHandle(bitmapIdx);
}
```

下面是getNextAvail方法，可以看到其显示看当前是否有一个空闲位置的缓存，如果有则直接用这个缓存，没有的话则是直接遍历bitmap中找出第一个bit位是0的坐标。

```java
// PoolSubpage.java
private int getNextAvail() {
    int nextAvail = this.nextAvail; // 这里是内存缓存，这个主要是free后的一个位置将其设置为nextAvail则可以提升效率
    if (nextAvail >= 0) {
        this.nextAvail = -1;
        return nextAvail;
    }
    return findNextAvail();
}

private int findNextAvail() {
    final long[] bitmap = this.bitmap;
    final int bitmapLength = this.bitmapLength;
    for (int i = 0; i < bitmapLength; i ++) { // 遍历bitmap
        long bits = bitmap[i];
        if (~bits != 0) { // ~bits != 0，表示存在一个bit位不为1，即存在可用内存块。
            return findNextAvail0(i, bits); // 找到long中第一个bit位置
        }
    }
    return -1;
}

private int findNextAvail0(int i, long bits) {
    final int maxNumElems = this.maxNumElems;
    final int baseVal = i << 6;

    for (int j = 0; j < 64; j ++) { // 遍历64个bit位，
        if ((bits & 1) == 0) { // 检查最低bit位是否为0（可用），为0则返回val
            int val = baseVal | j; // val等于 (i << 6) | j，即i * 64 + j，该bit位在bitmap中是第几个bit位。
            if (val < maxNumElems) {
                return val;
            } else {
                break;
            }
        }
        bits >>>= 1; // 右移一位，处理下一个bit位
    }
    return -1;
}
```

### 内存释放

释放Small内存块可能有两个步骤：

1. 释放PoolSubpage的上内存块。
2. 如果PoolSubpage中的内存块已全部释放，则从Chunk中释放该PoolSubpage，同时从PoolArena#smallSubpagePools移除它。

```java
// PoolSubpage.java
boolean free(PoolSubpage<T> head, int bitmapIdx) {
    if (elemSize == 0) {
        return true;
    }
    int q = bitmapIdx >>> 6;
    int r = bitmapIdx & 63;
    assert (bitmap[q] >>> r & 1) != 0;
    bitmap[q] ^= 1L << r;

    setNextAvail(bitmapIdx);  // 将对应bit位设置为可以使用，释放后将当前释放的内存直接缓存

    if (numAvail ++ == 0) { // 在PoolSubpage的内存块全部被使用时，释放了某个内存块，这时重新加入到PoolArena内存池中。
        addToPool(head);
        /* When maxNumElems == 1, the maximum numAvail is also 1.
         * Each of these PoolSubpages will go in here when they do free operation.
         * If they return true directly from here, then the rest of the code will be unreachable
         * and they will not actually be recycled. So return true only on maxNumElems > 1. */
        if (maxNumElems > 1) {
            return true;
        }
    }

    if (numAvail != maxNumElems) { // 未完全释放，即还存在已分配内存块，返回true
        return true;
    } else { // 处理所有内存块已经完全释放的场景。
        // Subpage not in use (numAvail == maxNumElems)
        if (prev == next) { // PoolArena#smallSubpagePools链表组成双向链表，链表中只有head和当前PoolSubpage时，当前PoolSubpage的prev，next都指向head。
            // Do not remove if this subpage is the only one left in the pool.
            return true; // 这时当前PoolSubpage是PoolArena中该链表最后一个PoolSubpage，不释放该PoolSubpage，以便下次申请内存时直接从该PoolSubpage上分配。
        }

        // Remove this subpage from the pool if there are other subpages left in the pool.
        doNotDestroy = false; // 内存空了的话，从PoolArena中移除，并返回false，这时PoolChunk会将释放对应Page节点。
        removeFromPool();
        return false;
    }
}
```

------

## jemalloc3算法

前面文章已经分享了Netty如何引用jemalloc 4算法管理内存。本文主要分享Netty 4.1.52之前版本中，PoolChunk如何使用jemalloc 3算法管理内存。感兴趣的同学可以对比两种算法。
**源码分析基于Netty 4.1.29。**

Netty的`PooledByteBuf`采用与jemalloc一致的内存分配算法。可用这样的情景类比，想像一下当前电商的配送流程。当顾客采购小件商品（比如书籍）时，直接从同城仓库送出；当顾客采购大件商品（比如电视）时，从区域仓库送出；当顾客采购超大件商品（比如汽车）时，则从全国仓库送出。Netty的分配算法与此相似，可参见下图：

<img src="http://blog-1259650185.cosbj.myqcloud.com/img/202112/14/1639456944.png" alt="jemalloc内存分配示意图" style="zoom:67%;" />

稍有不同的是：在Netty中，小件商品和大件商品都首先从同城仓库（ThreadCache-tcache）送出；如果同城仓库没有，则会从区域仓库（Arena）送出。

对于商品分类，Netty根据每次请求分配内存的大小，将请求分为如下几类：

<img src="http://blog-1259650185.cosbj.myqcloud.com/img/202112/14/1639457022.png" alt="分配请求分类" style="zoom:67%;" />

注意以下几点：

1. 内存分配的最小单位为16B。
2. < 512B的请求为Tiny，< 8KB(PageSize)的请求为Small，<= 16MB(ChunkSize)的请求为Normal，> 16MB(ChunkSize)的请求为Huge。
3. < 512B的请求以16B为起点每次增加16B；>= 512B的请求则每次加倍。
4. 不在表格中的请求大小，将向上规范化到表格中的数据，比如：请求分配511B、512B、513B，将依次规范化为512B、512B、1KB。

### Arena

为了提高内存分配效率并减少内部碎片，jemalloc算法将Arena切分为小块Chunk，根据每块的内存使用率又将小块组合为以下几种状态：QINIT，Q0，Q25，Q50，Q75，Q100。Chunk块可以在这几种状态间随着内存使用率的变化进行转移，内存使用率和状态转移可参见下图：

<img src="http://blog-1259650185.cosbj.myqcloud.com/img/202112/08/1638976983.png" alt="img" style="zoom:67%;" />

其中横轴表示内存使用率（百分比），纵轴表示状态，可知：

1. QINIT的内存使用率为[0,25)、Q0为(0,50)、Q100为[100,100]。
2. Chunk块的初始状态为QINIT，当使用率达到25时转移到Q0状态，再次达到50时转移到Q25，依次类推直到Q100；当内存释放时又从Q100转移到Q75，直到Q0状态且内存使用率为0时，该Chunk从Arena中删除。注意极端情况下，Chunk可能从QINIT转移到Q0再释放全部内存，然后从Arena中删除。

### Chunk和Page

虽然已将Arena切分为小块Chunk，但实际上Chunk是相当大的内存块，在jemalloc中建议为4MB，Netty默认使用16MB。为了进一步提高内存利用率并减少内部碎片，需要继续将Chunk切分为小的块Page。一个典型的切分将Chunk切分为2048块，Netty正是如此，可知Page的大小为：16MB/2048=8KB。一个好的内存分配算法，应使得已分配内存块尽可能保持连续，这将大大减少内部碎片，由此jemalloc使用伙伴分配算法尽可能提高连续性。伙伴分配算法的示意图如下：

![img](http://blog-1259650185.cosbj.myqcloud.com/img/202112/22/1640187508.png)

图中最底层表示一个被切分为2048个Page的Chunk块。自底向上，每一层节点作为上一层的子节点构造出一棵满二叉树，然后按层分配满足要求的内存块。以待分配序列8KB、16KB、8KB为例分析分配过程（每个Page大小8KB）：

1. 8KB--需要一个Page，第11层满足要求，故分配2048节点即Page0；
2. 16KB--需要两个Page，故需要在第10层进行分配，而1024的子节点2048已分配，从左到右找到满足要求的1025节点，故分配节点1025即Page2和Page3；
3. 8KB--需要一个Page，第11层满足要求，2048已分配，从左到右找到2049节点即Page1进行分配。

分配结束后，已分配连续的Page0-Page3，这样的连续内存块，大大减少内部碎片并提高内存使用率。

### SubPage

Netty中每个Page的默认大小为8KB，在实际使用中，很多业务需要分配更小的内存块比如16B、32B、64B等。为了应对这种需求，需要进一步切分Page成更小的SubPage。SubPage是jemalloc中内存分配的最小单位，不能再进行切分。SubPage切分的单位并不固定，**以第一次请求分配的大小为单位**（最小切分单位为16B）。比如，第一次请求分配32B，则Page按照32B均等切分为256块；第一次请求16B，则Page按照16B均等切分为512块。为了便于内存分配和管理，根据SubPage的切分单位进行分组，每组使用双向链表组合，示意图如下：

![Subpage双向链表](http://blog-1259650185.cosbj.myqcloud.com/img/202112/22/1640187640.png)



其中每组的头结点head只用来标记该组的大小，之后的节点才是实际分配的SubPage节点。需要注意的是，这些节点正是上一节中满二叉树的叶子节点即一个Page。

至此，已介绍完jemalloc的基本思想。

### 数据结构

首先说明PoolChunk内存组织方式。PoolChunk的内存大小默认是16M，它将内存组织成为一颗完美二叉树。二叉树的每一层每个节点所代表的内存大小都是均等的，并且每一层节点所代表的内存大小总和加起来都是16M。每一层节点可分配内存是父节点的1/2。整颗二叉树的总层数为12，层数从0开始。

示意图如下：

![img](http://blog-1259650185.cosbj.myqcloud.com/img/202112/18/1639760235.jpg)

先看一下PoolChunk的构造函数：

```java
// PoolChunk.java
PoolChunk(PoolArena<T> arena, T memory, int pageSize, int maxOrder, int pageShifts, int chunkSize, int offset) {
    unpooled = false; // 是否使用内存池
    this.arena = arena; // 该PoolChunk所属的PoolArena
    this.memory = memory; // 底层的内存块，对于堆内存，它是一个byte数组，对于直接内存，它是(jvm)ByteBuffer，但无论是哪种形式，其内存大小默认都是16M。
    this.pageSize = pageSize; // 叶子节点大小，默认为8192，即8K。
    this.pageShifts = pageShifts; // 用于计算分配内存所在二叉树层数，默认为13。
    this.maxOrder = maxOrder;  // 表示二叉树最大的层数，总共12层，从0开始。默认为11。
    this.chunkSize = chunkSize; // 整个PoolChunk的内存大小，默认为16777216，即16M。
    this.offset = offset; // 底层内存对齐偏移量，默认为0。
    unusable = (byte) (maxOrder + 1); // 表示节点已被分配，不用了，默认为12。
    log2ChunkSize = log2(chunkSize); // 用于计算偏移量，默认为24。
    subpageOverflowMask = ~(pageSize - 1); // 用于判断申请内存是否为PoolSubpage，默认为-8192。
    freeBytes = chunkSize; // 空闲内存字节数。每个PoolChunk都要按内存使用率关联到一个PoolChunkList上，内存使用率正是通过freeBytes计算。

    assert maxOrder < 30 : "maxOrder should be < 30, but is: " + maxOrder;
    maxSubpageAllocs = 1 << maxOrder; // 叶子节点数量，默认为2048，即2^11。

    // Generate the memory map.
    memoryMap = new byte[maxSubpageAllocs << 1]; // 第d层的开始下标为 1<<d。(数组第0个元素不使用)。
    depthMap = new byte[memoryMap.length];
    int memoryMapIndex = 1;
    for (int d = 0; d <= maxOrder; ++ d) { // move down the tree one level at a time 初始化内存管理二叉树，使用数组维护二叉树
        int depth = 1 << d;
        for (int p = 0; p < depth; ++ p) {
            // in each level traverse left to right and set value to the depth of subtree
            memoryMap[memoryMapIndex] = (byte) d; // 将每一层节点值设置为层数d
            depthMap[memoryMapIndex] = (byte) d;  // 保存二叉树的层数，用于通过位置下标找到其在整棵树中对应的层数
            memoryMapIndex ++;
        }
    }
```

### 分配伙伴算法

注意：depthMap的值代表二叉树的层数，初始化后不再变化。memoryMap的值代表当前节点最大可申请内存块，在分配内存过程中不断变化。节点最大可申请内存块可以通过层数d计算，为`2 ^ (pageShifts + maxOrder - d)`。

Netty使用两个字节数组memoryMap和depthMap来表示两棵二叉树，其中MemoryMap存放分配信息，depthMap存放节点的高度信息。为了更好的理解这两棵二叉树，参考下图：

![伙伴分配算法二叉树](http://blog-1259650185.cosbj.myqcloud.com/img/202112/23/1640189627.png)

左图表示每个节点的编号，注意从1开始，省略0是因为这样更容易计算父子关系：子节点加倍，父节点减半，比如512的子节点为1024=512 * 2。右图表示每个节点的深度，注意从0开始。在代表二叉树的数组中，左图中节点上的数字作为数组索引即id，右图节点上的数字作为值。初始状态时，`memoryMap`和`depthMap`相等，可知一个id为512节点的初始值为9，即：

```java
memoryMap[512] = depthMap[512] = 9;
```

depthMap的值初始化后不再改变，memoryMap的值则随着节点分配而改变。当一个节点被分配以后，该节点的值设置为12（最大高度+1）表示不可用，并且会更新祖先节点的值。下图表示随着4号节点分配而更新祖先节点的过程，其中每个节点的第一个数字表示节点编号，第二个数字表示节点高度值。

![伙伴分配算法分配过程](http://blog-1259650185.cosbj.myqcloud.com/img/202112/23/1640189687.png)

分配过程如下：

1. 4号节点被完全分配，将高度值设置为12表示不可用。
2. 4号节点的父亲节点即2号节点，将高度值更新为两个子节点的较小值；其他祖先节点亦然，直到高度值更新至根节点。

可推知，memoryMap数组的值有如下三种情况：

1. memoryMap[id] = depthMap[id] -- 该节点没有被分配
2. memoryMap[id] > depthMap[id] -- 至少有一个子节点被分配，不能再分配该高度满足的内存，但可以根据实际分配较小一些的内存。比如，上图中分配了4号子节点的2号节点，值从1更新为2，表示该节点不能再分配8MB的只能最大分配4MB内存，因为分配了4号节点后只剩下5号节点可用。
3. mempryMap[id] = 最大高度 + 1（本例中12） -- 该节点及其子节点已被完全分配， 没有剩余空间。

明白了这些，再深入源码分析Netty的实现细节。

### 内存分配

```java
// PoolChunk.java
long allocate(int normCapacity) {
    if ((normCapacity & subpageOverflowMask) != 0) { // >= pageSize
        return allocateRun(normCapacity);
    } else {
        return allocateSubpage(normCapacity);
    }
}
```

若申请内存大于pageSize，调用allocateRun方法分配Chunk级别的内存。否则调用allocateSubpage方法分配PoolSubpage，再在PoolSubpage上分配所需内存。

```java
// PoolChunk.java
private long allocateRun(int normCapacity) {
    int d = maxOrder - (log2(normCapacity) - pageShifts); // 计算应该在哪层分配分配内存。如16K， 即2^14，计算结果为10，即在10层分配。
    int id = allocateNode(d); // 在d层分配一个节点
    if (id < 0) {
        return id;
    }
    freeBytes -= runLength(id); // 减少空闲内存字节数。
    return id;
}

private int allocateNode(int d) {
    int id = 1;
    int initial = - (1 << d); // has last d bits = 0 and rest all = 1
    byte val = value(id);
    if (val > d) { // unusable memoryMap[1] > d，第0层的可分配内存不足，表明该PoolChunk内存不能满足分配，分配失败。
        return -1;
    } // 遍历二叉树，找到满足内存分配的节点。val < d，即该节点内存满足分配。 id & initial = 0，即 id < 1<<d， d层之前循环继续执行。这里并不会出现val > d的场景，但会出现val == d的场景，如
    // PoolChunk当前可分配内存为2M，即memoryMap[1] = 3，这时申请2M内存，在0-2层，都是val == d
    while (val < d || (id & initial) == 0) { // id & initial == 1 << d for all ids at depth d, for < d it is 0
        id <<= 1; // 向下找到下一层下标，注意，子树左节点的下标是父节点下标的2倍。
        val = value(id);
        if (val > d) { // 表示当前节点不能满足分配
            id ^= 1; // 查找同一父节点下的兄弟节点，在兄弟节点上分配内存。id ^= 1，当id为偶数，即为id+=1， 当id为奇数，即为id-=1。由于前面通过id <<= 1找到下一层下标都是偶数，这里等于id+=1。
            val = value(id);
        }
    }
    byte value = value(id);
    assert value == d && (id & initial) == 1 << d : String.format("val = %d, id & initial = %d, d = %d",
            value, id & initial, d);
    setValue(id, unusable); // mark as unusable 因为一开始判断了PoolChunk内存是否足以分配，所以这里一定可以找到一个可分配节点。这里标注找到的节点已分配。
    updateParentsAlloc(id); // 更新找到节点的父节点最大可分配内存块大小
    return id;
}

private void updateParentsAlloc(int id) {
    while (id > 1) { // 向父节点遍历，直到根节点
        int parentId = id >>> 1; //  id >>> 1，找到父节点
        byte val1 = value(id);
        byte val2 = value(id ^ 1);
        byte val = val1 < val2 ? val1 : val2; // 取当前节点和兄弟节点中较小值，作为父节点的值，表示父节点最大可分配内存块大小。
        // 如memoryMap[1] = 0，表示最大可分配内存块为16M。分配8M后，memoryMap[1] = 1，表示当前最大可分配内存块为8M。
        setValue(parentId, val);
        id = parentId;
    }
}
```

下面看一则实例，大家可以结合实例理解上面的代码：

![img](http://blog-1259650185.cosbj.myqcloud.com/img/202112/18/1639762741.jpg)

### 内存释放

下面看一下内存释放。	

```java
// PoolChunk.java
void free(long handle) {
    // #1
    int memoryMapIdx = memoryMapIdx(handle);
    int bitmapIdx = bitmapIdx(handle);
    // #2
    if (bitmapIdx != 0) { // free a subpage
        ...
    }
    freeBytes += runLength(memoryMapIdx);
    setValue(memoryMapIdx, depth(memoryMapIdx));
    updateParentsFree(memoryMapIdx);
}
```

`#1` 获取memoryMapIdx和bitmapIdx
`#2` 内存块在PoolSubpage中分配，通过PoolSubpage释放内存。
`#3` 处理到这里，就是释放Chunk级别的内存块了。
增加空闲内存字节数。
设置二叉树中对应的节点为未分配
对应修改该节点的父节点。

这里再简单说一下Netty 4.1.52前的内存级别划分算法。
PoolArena中将维护的内存块按大小划分为以下级别：
Tiny < 512 Small < 8192(8K) Chunk < 16777216(16M) Huge >= 16777216

PoolArena#tinySubpagePools，smallSubpagePools两个数组用于维护Tiny，Small级别的内存块。tinySubpagePools，32个元素，每个数组之间差16个字节，大小分别为0,16,32,48,64, … ,496。smallSubpagePools，4个元素，每个数组之间大小翻倍，大小分别为512,1025,2048,4096。这两个数组都是PoolSubpage数组，PoolSubpage大小默认都是8192，Tiny，Small级别的内存都是在PoolSubpage上分配的。

Chunk内存块则都是8192的倍数。

在Netty 4.1.52，已经删除了Small级别内存块，并引入了SizeClasses计算对齐内存块或计算对应的索引。SizeClasses默认将16M划分为75个内存块size，内存划分更细，也可以减少内存对齐的空间浪费，更充分利用内存。

------

## 对象池Recycler实现原理

由于在Java中创建一个实例的消耗不小，很多框架为了提高性能都使用对象池，Netty也不例外。本文主要分析Netty对象池Recycler的实现原理。

### 缓存对象管理

Recycler的内部类Stack负责管理缓存对象。

```java
// Recycler.Stack.java
// Stack所属主线程，注意这里使用了WeakReference
WeakReference<Thread> threadRef;    
// 主线程回收的对象
DefaultHandle<?>[] elements;
// elements最大长度
int maxCapacity;
// elements索引
int size;
// 非主线程回收的对象
volatile WeakOrderQueue head;   
```

Recycler将一个Stack划分给某个主线程，主线程直接从Stack#elements中存取对象，而非主线程回收对象则存入WeakOrderQueue中。

threadRef字段使用了WeakReference，当主线程消亡后，该字段指向对象就可以被垃圾回收。

DefaultHandle，对象的包装类，在Recycler中缓存的对象都会包装成DefaultHandle类。

head指向的WeakOrderQueue，用于存放其他线程的对象。

WeakOrderQueue主要属性：

```java
// Head#link指向Link链表首对象
Head head;  
// 指向Link链表尾对象
Link tail;
// 指向WeakOrderQueue链表下一对象
WeakOrderQueue next;
// 所属线程
WeakReference<Thread> owner;
```

Link中也有一个`DefaultHandle<?>[] elements`字段，负责存储数据。注意，Link继承了AtomicInteger，AtomicInteger的值存储elements的最新索引。

WeakOrderQueue也是属于某个线程，并且WeakOrderQueue继承了`WeakReference<Thread>`，当所属线程消亡时，对应WeakOrderQueue也可以被垃圾回收。注意：每个WeakOrderQueue都只属于一个Stack，并且只属于一个非主线程。

![img](http://blog-1259650185.cosbj.myqcloud.com/img/202112/19/1639844046.jpg)

thread2如果要存放对象到Stack1中，只能存放在WeakOrderQueue1。thread1如果要存放对象到Stack2中，只能存放在WeakOrderQueue3。

### 回收对象

DefaultHandle#recycle -> Stack#push

```java
// Recycler.Stack.java
void push(DefaultHandle<?> item) {
    Thread currentThread = Thread.currentThread();
    if (threadRef.get() == currentThread) {
        pushNow(item); //  当前线程是主线程，直接将对象加入到Stack#elements中。
    } else {
        pushLater(item, currentThread); // 当前线程非主线程，需要将对象放到对应的WeakOrderQueue中
    }
}
```

```java
private void pushLater(DefaultHandle<?> item, Thread thread) {
    ...
    // #1
    Map<Stack<?>, WeakOrderQueue> delayedRecycled = DELAYED_RECYCLED.get();
    WeakOrderQueue queue = delayedRecycled.get(this);
    if (queue == null) {
        // #2
        if (delayedRecycled.size() >= maxDelayedQueues) {
            delayedRecycled.put(this, WeakOrderQueue.DUMMY);
            return;
        }
        // #3
        if ((queue = newWeakOrderQueue(thread)) == null) {
            return;
        }
        delayedRecycled.put(this, queue);
    } else if (queue == WeakOrderQueue.DUMMY) {
        // #4
        return;
    }
    // #5
    queue.add(item);
}
```

`#1` DELAYED_RECYCLED是一个FastThreadLocal，可以理解为Netty中的ThreadLocal优化类。它为每个线程维护了一个Map，存储每个Stack和对应WeakOrderQueue。
所有这里获取的delayedRecycled变量是仅用于当前线程的。
而delayedRecycled.get获取的WeakOrderQueue，是以Thread + Stack作为维度区分的，只能是一个线程操作。
`#2` 当前WeakOrderQueue数量超出限制，添加WeakOrderQueue.DUMMY作为标记
`#3` 构造一个WeakOrderQueue，加入到Stack#head指向的WeakOrderQueue链表中，并放入DELAYED_RECYCLED。这时是需要一下同步操作的。
`#4` 遇到WeakOrderQueue.DUMMY标记对象，直接抛弃对象
`#5` 将缓存对象添加到WeakOrderQueue中。

WeakOrderQueue#add：

```java
void add(DefaultHandle<?> handle) {
    handle.lastRecycledId = id;

    // #1
    if (handleRecycleCount < interval) {
        handleRecycleCount++;
        return;
    }
    handleRecycleCount = 0;


    Link tail = this.tail;
    int writeIndex;
    // #2
    if ((writeIndex = tail.get()) == LINK_CAPACITY) {
        Link link = head.newLink();
        if (link == null) {
            return;
        }
        this.tail = tail = tail.next = link;
        writeIndex = tail.get();
    }
    // #3
    tail.elements[writeIndex] = handle;
    handle.stack = null;
    // #4
    tail.lazySet(writeIndex + 1);

```

`#1` 控制回收频率，避免WeakOrderQueue增长过快。
每8个对象都会抛弃7个，回收一个
`#2` 当前Link#elements已全部使用，创建一个新的Link
`#3` 存入缓存对象
`#4` 延迟设置Link#elements的最新索引（Link继承了AtomicInteger），这样在该stack主线程通过该索引获取elements缓存对象时，保证elements中元素已经可见。

### 获取对象

Recycler#threadLocal中存放了每个线程对应的Stack。Recycler#get中首先获取属于当前线程的Stack，再从该Stack中获取对象，也就是，每个线程只能从自己的Stack中获取对象。

Recycler#get -> Stack#pop

```java
DefaultHandle<T> pop() {
    int size = this.size;
    if (size == 0) {
        // #1
        if (!scavenge()) {
            return null;
        }
        size = this.size;
        if (size <= 0) {
            return null;
        }
    }
    // #2
    size --;
    DefaultHandle ret = elements[size];
    elements[size] = null;
    this.size = size;

    ...
    return ret;
}
```

scavenge -> scavengeSome -> WeakOrderQueue#transfer

```java
// WeakOrderQueue.java
boolean transfer(Stack<?> dst) {
    Link head = this.head.link;
    if (head == null) {
        return false;
    }
    // #1
    if (head.readIndex == LINK_CAPACITY) {
        if (head.next == null) {
            return false;
        }
        this.head.link = head = head.next;
    }
		// #2
    final int srcStart = head.readIndex;
    int srcEnd = head.get();
    final int srcSize = srcEnd - srcStart;
    if (srcSize == 0) {
        return false;
    }
		// #3
    final int dstSize = dst.size;
    final int expectedCapacity = dstSize + srcSize;

    if (expectedCapacity > dst.elements.length) {
        final int actualCapacity = dst.increaseCapacity(expectedCapacity);
        srcEnd = min(srcStart + actualCapacity - dstSize, srcEnd);
    }

    if (srcStart != srcEnd) {
        final DefaultHandle[] srcElems = head.elements;
        final DefaultHandle[] dstElems = dst.elements;
        int newDstSize = dstSize;
      	// #4
        for (int i = srcStart; i < srcEnd; i++) {
            DefaultHandle element = srcElems[i];
            if (element.recycleId == 0) {
                element.recycleId = element.lastRecycledId;
            } else if (element.recycleId != element.lastRecycledId) {
                throw new IllegalStateException("recycled already");
            }
            srcElems[i] = null;
						// #5
            if (dst.dropHandle(element)) {
                // Drop the object.
                continue;
            }
            element.stack = dst;
            dstElems[newDstSize ++] = element;
        }
				// #6
        if (srcEnd == LINK_CAPACITY && head.next != null) {
            // Add capacity back as the Link is GCed.
            this.head.reclaimSpace(LINK_CAPACITY);
            this.head.link = head.next;
        }

        head.readIndex = srcEnd;
      	// #7
        if (dst.size == newDstSize) {
            return false;
        }
        dst.size = newDstSize;
        return true;
    } else {
        // The destination stack is full already.
        return false;
    }
}
```

就是把WeakOrderQueue中的对象迁移到Stack中。

`#1` head.readIndex 标志现在已迁移对象下标
`head.readIndex == LINK_CAPACITY`，表示当前Link已全部移动，查找下一个Link
`#2` 计算待迁移对象数量
注意，Link继承了AtomicInteger
`#3` 计算Stack#elements数组长度，不够则扩容
`#4` 遍历待迁移的对象
`#5` 控制回收频率
`#6` 当前Link对象已全部移动，修改WeakOrderQueue#head的link属性，指向下一Link，这样前面的Link就可以被垃圾回收了。
`#7` `dst.size == newDstSize` 表示并没有对象移动，返回false
否则更新dst.size。

其实对象池的实现难点在于线程安全。Recycler中将主线程和非主线程回收对象划分到不同的存储空间中（stack#elements和WeakOrderQueue.Link#elements），并且对于WeakOrderQueue.Link#elements，存取操作划分到两端进行（非主线程从尾端存入，主线程从首部开始读取），从而减少同步操作，并保证线程安全。

另外，Netty还提供了更高级别的对象池类ObjectPool，使用方法可以参考PooledDirectByteBuf#RECYCLER，这里不再赘述。

## AdaptiveRecvByteBufAllocator

RecvByteBufAllocator：

分配一个新的接受缓存，该缓存的容量会尽可能的足够大以读入所有的入站数据并且该缓存的容量也尽可能的小以不会浪费它的空间。

AdaptiveRecvByteBufAllocator：

RecvByteBufAllocator会根据反馈自动的增加和减少可预测的buffer的大小。

它会逐渐地增加期望的可读到的字节数如果之前的读取已经完全填充满了分配好的buffer( 也就是，上一次的读取操作，已经完全填满了已经分配好的buffer，那么它就会很优雅的自动的去增加可读的字节数量，也就是自动的增加缓冲区的大小 )。它也会逐渐的减少期望的可读的字节数如果连续两次读操作都没有填充满分配的buffer。否则，它会保持相同的预测。

```java
// AdaptiveRecvByteBufAllocator.java
static {
    List<Integer> sizeTable = new ArrayList<Integer>();
    for (int i = 16; i < 512; i += 16) { // 依次往sizeTable添加元素：[16 , (512-16)]之间16的倍数。即，16、32、48...496
        sizeTable.add(i);
    }
    // 再往sizeTable中添加元素：[512 , 512 * (2^N))，N > 1; 直到数值超过Integer的限制(2^31 - 1)
    // Suppress a warning since i becomes negative when an integer overflow happens
    for (int i = 512; i > 0; i <<= 1) { // lgtm[java/constant-comparison]
        sizeTable.add(i);
    }
    // 根据sizeTable长度构建一个静态成员常量数组SIZE_TABLE，并将sizeTable中的元素赋值给SIZE_TABLE数组
    SIZE_TABLE = new int[sizeTable.size()];
    for (int i = 0; i < SIZE_TABLE.length; i ++) {
        SIZE_TABLE[i] = sizeTable.get(i);
    }
}
```

具体流程为：

1. 依次往sizeTable添加元素：[16 , (512-16)]之间16的倍数。即，16、32、48...496；
2. 然后再往sizeTable中添加元素：[512 , 512 * (2^N))，N > 1; 直到数值超过Integer的限制(2^31 - 1)；
3. 根据sizeTable长度构建一个静态成员常量数组SIZE_TABLE，并将sizeTable中的元素赋值给SIZE_TABLE数组。注意List是有序的，所以是根据插入元素的顺序依次的赋值给SIZE_TABLE，SIZE_TABLE从下标0开始。

SIZE_TABLE为预定义好的以从小到大的顺序设定的可分配缓冲区的大小值的数组。因为AdaptiveRecvByteBufAllocator作用是可自动适配每次读事件使用的buffer的大小。这样当需要对buffer大小做调整时，只要根据一定逻辑从SIZE_TABLE中取出值，然后根据该值创建新buffer即可。

HandleImpl是AdaptiveRecvByteBufAllocator一个内部类，该处理器类用于提供真实的操作并保留预测最佳缓冲区容量所需的内部信息。
guess()方法用于返回预测的应该创建的buffer容量大小。

每次读取完信息后可调用readComplete()方法来根据本次的读取数据大小以对下一次读操作是应该创建多大容量的buffer做调整。

allocate()方法会返回一个新的buffer用于接受读数据，该buffer的容量会尽可能足够大去读取所有的入站数据并且也会尽可能足够小以至于不会浪费容量。同时还会根据操作系统、平台以及系统参数的设置进行内存的分配(即，可能是堆外内存也可能是堆内内存)

总的来说，AdaptiveRecvByteBufAllocator目前我们只需要知道：

1. 它可以自动调节每次读操作所需buffer的容量大小。这需要我们在读操作的时候调用AdaptiveRecvByteBufAllocator类的相关方法来收集相关的信息。
2. 容量调整逻辑是：a) 如果最后一次读操作读取到的数据大等于分配的buffer的容量大小，则扩大buffer容量的值。再下一次读操作时，就会根据这个扩大的容量值来创建新的buffer来接收数据；b) 如果连续两次读操作读取到的数据都比创建的buffer的容量小的话，则对buffer的容量进行缩减。那么在下一次读操作时就根据这个新的容量大小值进行新的buffer的创建来获取数据；c) 否则，则保持buffer的容量大小不变。
3. 可以通过allocate()方法获取由AdaptiveRecvByteBufAllocator衡量后得到的最理想容量大小的buffer。并且会根据操作系统、平台以及系统参数的设置进行内存的分配(即，可能是堆外内存也可能是对内内存)。









## 参考

[自顶向下深入分析Netty（十）--JEMalloc分配算法](https://www.jianshu.com/p/15304cd63175)

[Netty源码解析 -- 内存对齐类SizeClasses](https://zhuanlan.zhihu.com/p/269999684)

[Netty源码解析 -- 内存池与PoolArena](https://zhuanlan.zhihu.com/p/270974280)

[Netty源码解析 -- PoolChunk实现原理](https://zhuanlan.zhihu.com/p/278116929)

[Netty源码解析 -- PoolSubpage实现原理](https://zhuanlan.zhihu.com/p/279753082)

[netty源码阅读一(内存池之SizeClasses)](https://blog.csdn.net/cq_pf/article/details/107767775?ops_request_misc=%257B%2522request%255Fid%2522%253A%2522163984723316780366588092%2522%252C%2522scm%2522%253A%252220140713.130102334.pc%255Fblog.%2522%257D&request_id=163984723316780366588092&biz_id=0&utm_medium=distribute.pc_search_result.none-task-blog-2~blog~first_rank_v2~rank_v29-2-107767775.pc_v2_rank_blog_default&utm_term=netty&spm=1018.2226.3001.4450)

[netty源码阅读二(内存池之PoolChunk)](https://blog.csdn.net/cq_pf/article/details/107794567?spm=1001.2014.3001.5502)
