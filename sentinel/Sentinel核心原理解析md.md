Sentinel是分布式系统的防御系统。以流量为切入点，通过动态设置的流量控制、服务熔断等手段达到保护系统的目的，通过服务降级增强服务被拒后用户的体验。

# 1.Sentinel工作原理

## 1.1 架构图解析

若要读懂Sentinel源码，则必须要搞明白官方给出的Sentinel的架构图。

<img src="http://blog-1259650185.cosbj.myqcloud.com/img/202111/24/1637720298.png" alt="sentinel-slot-chain" style="zoom: 25%;" />

Sentinel的核心骨架是ProcessorSlotChain。其将不同的 Slot 按照顺序串在一起（责任链模式），从而将不同的功能组合在一起（限流、降级、系统保护）。系统**会为每个资源创建一套SlotChain**。

## 1.2 SPI机制 

Sentinel槽链中各Slot的执行顺序是固定好的。但并不是绝对不能改变的。Sentinel将`ProcessorSlot` 作为 SPI 接口进行扩展，使得 SlotChain 具备了扩展能力。用户可以自定义Slot并编排Slot 间的顺序，从而可以给 Sentinel 添加自定义的功能。

<img src="http://blog-1259650185.cosbj.myqcloud.com/img/202111/24/1637720406.png" alt="Slot SPI" style="zoom:50%;" />

## 1.3 Resouce简介

资源是 Sentinel 的关键概念。它可以是 Java 应用程序中的任何内容，例如，由应用程序提供的服务，或由应用程序调用的其它服务，甚至可以是一段代码。

只要通过 Sentinel API 定义的代码，就是资源，能够被 Sentinel 保护起来。大部分情况下，可以使用方法签名，URL，甚至服务名称作为资源名来标示资源。简单来说，资源就是 Sentinel 用来保护系统的一个媒介。

定义完资源后，就可以通过在程序中埋点来保护你自己的服务了，埋点的方式有两种：

- try-catch 方式（通过 `SphU.entry(...)`），当 catch 到BlockException时执行异常处理(或fallback)
- if-else 方式（通过 `SphO.entry(...)`），当返回 false 时执行异常处理(或fallback)

源码中用来包装资源的类是： `ResourceWrapper`，它是一个抽象的包装类，包装了资源的 **Name** 、**EntryType**和**resourceType**。它有两个实现子类： `StringResourceWrapper` 和 `MethodResourceWrapper`。顾名思义， `StringResourceWrapper` 是通过对一串字符串进行包装，是一个通用的资源包装类， `MethodResourceWrapper` 是对方法调用的包装。

## 1.4 Slot简介 

在 Sentinel 里面，所有的资源都对应一个资源名称（`resourceName`），**每次资源调用都会创建一个 `Entry` 对象**。Entry 可以通过对主流框架的适配自动创建，也可以通过注解的方式或调用 `SphU` API 显式创建。Entry 创建的时候，同时也会创建一系列功能插槽（slot chain），Sentinel的工作流程就是围绕着一个个插槽所组成的插槽链来展开的。这些插槽有不同的职责，例如：

**NodeSelectorSlot**

负责收集资源的路径，并将这些资源的调用路径，以**树状结构存储**起来，用于根据调用路径来限流降级。

**ClusterBuilderSlot**

用于存储资源的统计信息以及调用者信息，例如该资源的 RT, QPS, thread count，Block count，Exception count 等等，这些信息将用作为多维度限流，降级的依据。简单来说，就是用于构建ClusterNode。 

**StatisticSlot**

用于记录、统计不同纬度的 runtime 指标监控信息。

**ParamFlowSlot**

对应`热点流控`。 

**FlowSlot**

用于根据预设的限流规则以及前面 slot 统计的状态，来进行流量控制。对应`流控规则`。 

**AuthoritySlot**

根据配置的黑白名单和调用来源信息，来做黑白名单控制。对应`授权规则`。 

**DegradeSlot**

通过统计信息以及预设的规则，来做熔断降级。对应`降级规则`。 

**SystemSlot**

通过系统的状态，例如 load1 等，来控制总的入口流量。对应`系统规则`。 

总体的框架如下:

<img src="http://blog-1259650185.cosbj.myqcloud.com/img/202111/24/1637721453.gif" alt="img" style="zoom: 50%;" />

Sentinel 通过 `SlotChainBuilder` 作为 SPI 接口，使得 Slot Chain 具备了扩展的能力。我们可以通过实现 `SlotsChainBuilder` 接口加入自定义的 slot 并自定义编排各个 slot 之间的顺序，从而可以给 Sentinel 添加自定义的功能。

那SlotChain是在哪创建的呢？是在 `CtSph.lookProcessChain()` 方法中创建的，并且该方法会根据当前请求的资源先去一个静态的HashMap中获取，如果获取不到才会创建，创建后会保存到HashMap中。这就意味着，同一个资源会全局共享一个SlotChain。

<img src="https://mmbiz.qpic.cn/mmbiz_png/GtXvavW2UlzWfcHpD5K9yOqibfMZmFttias1RibnXN0bs1fVWO5sia5DlrkgmQa2sBknYFHaZ1c92tB3dTYl8F6p7A/640?wx_fmt=png&tp=webp&wxfrom=5&wx_lazy=1&wx_co=1" alt="图片" style="zoom:50%;" />

## 1.5 Metric简介

 `Metric`是Sentinel中用来进行实时数据统计的度量接口，`Node`就是通过`Metric`来进行数据统计的。而`Metric`本身也并没有统计的能力，他也是通过`MetricBucket`来进行统计的。

`Metric`有一个实现类：`ArrayMetric`，在`ArrayMetric`中主要是通过一个叫`WindowLeapArray`的对象进行窗口统计的。

<img src="https://mmbiz.qpic.cn/mmbiz_png/GtXvavW2UlzWfcHpD5K9yOqibfMZmFttiaQBSyQAAiaRAniabB9ibpvMQdvwnXG14jeMkRoIaduGTC4zxPEUyWLFFiaA/640?wx_fmt=png&tp=webp&wxfrom=5&wx_lazy=1&wx_co=1" alt="图片" style="zoom:50%;" />

# 2. Sentinel核心源码解析

<img src="http://blog-1259650185.cosbj.myqcloud.com/img/202111/24/1637720629.png" alt="Sentinel核心源码解析流程图" style="zoom: 33%;" />

## 2.1 Slot

每个Slot执行完业务逻辑处理后，会调用fireEntry()方法，该方法将会触发下一个节点的entry方法，下一个节点又会调用他的fireEntry，以此类推直到最后一个Slot，由此就形成了sentinel的责任链。

下面我们就来详细研究下这些Slot的原理。

### 2.1.1 NodeSelectorSlot

这个 slot 主要负责收集资源的路径，并将这些资源的调用路径以树状结构存储起来，构造成调用链，用于根据调用路径进行流量控制。具体的是将资源的调用路径，封装成一个一个的节点，再组成一个树状的结构来形成一个完整的调用链， `NodeSelectorSlot`是所有Slot中最关键也是最复杂的一个Slot。

```java
 ContextUtil.enter("entrance1", "appA");
 Entry nodeA = SphU.entry("nodeA");
 if (nodeA != null) {
    nodeA.exit();
 }
 ContextUtil.exit();
```

上述代码通过 `ContextUtil.enter()` 创建了一个名为 `entrance1` 的上下文，同时指定调用发起者为 `appA`；接着通过 `SphU.entry()`请求一个 token，如果该方法顺利执行没有抛 `BlockException`，表明 token 请求成功。

以上代码将在内存中生成以下结构：

````java
 	     machine-root
                 /     
                /
         EntranceNode1
              /
             /   
      DefaultNode(nodeA)
````
注意：每个 `DefaultNode` 由**资源 ID 和输入名称来标识。换句话说，一个资源 ID 可以有多个不同入口的 DefaultNode**。

```java
  ContextUtil.enter("entrance1", "appA");
  Entry nodeA = SphU.entry("nodeA");
  if (nodeA != null) {
    nodeA.exit();
  }
  ContextUtil.exit();

  ContextUtil.enter("entrance2", "appA");
  nodeA = SphU.entry("nodeA");
  if (nodeA != null) {
    nodeA.exit();
  }
  ContextUtil.exit();
```

以上代码将在内存中生成以下结构：

```
                   machine-root
                   /         \
                  /           \
          EntranceNode1   EntranceNode2
                /               \
               /                 \
       DefaultNode(nodeA)   DefaultNode(nodeA)
```

上面的结构可以通过调用 `curl http://localhost:8719/tree?type=root` 来显示：

```
EntranceNode: machine-root(t:0 pq:1 bq:0 tq:1 rt:0 prq:1 1mp:0 1mb:0 1mt:0)
-EntranceNode1: Entrance1(t:0 pq:1 bq:0 tq:1 rt:0 prq:1 1mp:0 1mb:0 1mt:0)
--nodeA(t:0 pq:1 bq:0 tq:1 rt:0 prq:1 1mp:0 1mb:0 1mt:0)
-EntranceNode2: Entrance1(t:0 pq:1 bq:0 tq:1 rt:0 prq:1 1mp:0 1mb:0 1mt:0)
--nodeA(t:0 pq:1 bq:0 tq:1 rt:0 prq:1 1mp:0 1mb:0 1mt:0)

t:threadNum  pq:passQps  bq:blockedQps  tq:totalQps  rt:averageRt  prq: passRequestQps 1mp:1m-passed 1mb:1m-blocked 1mt:1m-total
```

#### 调用链树

当在一个上下文中多次调用了` SphU#entry()` 方法时，就会创建一棵调用链树。具体的代码在entry方法中创建CtEntry对象时：

```java
// CtEntry.java
CtEntry(ResourceWrapper resourceWrapper, ProcessorSlot<Object> chain, Context context) {
    super(resourceWrapper);
    this.chain = chain;
    this.context = context;

    setUpEntryFor(context);
}
// 调用链的变换，即将当前 Entry 接到传入 Context 的调用链路上
private void setUpEntryFor(Context context) {
    // The entry should not be associated to NullContext.
    if (context instanceof NullContext) {
        return;
    }
    this.parent = context.getCurEntry(); // 获取「上下文」中上一次的入口
    if (parent != null) {
        ((CtEntry) parent).child = this; // 然后将当前入口设置为上一次入口的子节点（建立链表的前驱、后继节点）
    }
    context.setCurEntry(this); // 设置「上下文」的当前入口为该类本身
}
```

这里可能看代码没有那么直观，可以用一些图形来描述一下这个过程。

#### 构造树干

##### 创建context

context的创建在上面已经分析过了，初始化的时候，context中的curEntry属性是没有值的，如下图所示：

<img src="http://blog-1259650185.cosbj.myqcloud.com/img/202111/26/1637911172" alt="图片" style="zoom:50%;" />

##### 创建Entry

每创建一个新的Entry对象时，都会重新设置context的curEntry，并将context原来的curEntry设置为该新Entry对象的父节点，如下图所示：

<img src="http://blog-1259650185.cosbj.myqcloud.com/img/202111/26/1637911312" alt="图片" style="zoom:50%;" />

##### 退出Entry

某个Entry退出时，将会重新设置context的curEntry，当该Entry是最顶层的一个入口时，将会把ThreadLocal中保存的context也清除掉，如下图所示：

<img src="http://blog-1259650185.cosbj.myqcloud.com/img/202111/26/1637912210" alt="图片" style="zoom:50%;" />

#### 构造叶子节点

上面的过程是构造了一棵调用链的树（Entry），但是这棵树只有树干，没有叶子（Node），那叶子节点是在什么时候创建的呢？DefaultNode就是叶子节点，在叶子节点中保存着目标资源在当前状态下的统计信息。通过分析，我们知道了叶子节点是在NodeSelectorSlot的entry方法中创建的。具体的代码如下：

```java
// NodeSelectorSlot.java
@Override
public void entry(Context context, ResourceWrapper resourceWrapper, Object obj, int count, boolean prioritized, Object... args)
    throws Throwable {
    DefaultNode node = map.get(context.getName()); // 根据「上下文」的名称获取DefaultNode，多线程环境下，每个线程都会创建一个context，只要资源名相同，则context的名称也相同，那么获取到的节点就相同
    if (node == null) {
        synchronized (this) {
            node = map.get(context.getName());
            if (node == null) {
                // 如果当前「上下文」中没有该节点，则创建一个DefaultNode节点
                node = new DefaultNode(resourceWrapper, null);
                HashMap<String, DefaultNode> cacheMap = new HashMap<String, DefaultNode>(map.size());
                cacheMap.putAll(map);
                cacheMap.put(context.getName(), node);
                map = cacheMap;
                // Build invocation tree ，将当前node作为「上下文」的最后一个节点的子节点添加进去
                // 如果context的curEntry.parent.curNode为null，则添加到entranceNode中去，否则添加到context的curEntry.parent.curNode中去
                ((DefaultNode) context.getLastNode()).addChild(node);
            }

        }
    }
    // 将该节点设置为「上下文」中的当前节点，实际是将当前节点赋值给context中curEntry的curNode，在Context的getLastNode中会用到在此处设置的curNode
    context.setCurNode(node);
    fireEntry(context, resourceWrapper, node, count, prioritized, args); // 由此触发下一个节点的entry方法
}
```

上面的代码可以分解成下面这些步骤：

1. 获取当前上下文对应的DefaultNode，如果没有的话会为当前的调用新生成一个DefaultNode节点，它的作用是对资源进行各种统计度量以便进行流控；
2. 将新创建的DefaultNode节点，添加到context中，作为「entranceNode」或者「curEntry.parent.curNode」的子节点；
3. 将DefaultNode节点，添加到context中，作为「curEntry」的curNode。

上面的第2步，不是每次都会执行。我们先看第3步，把当前DefaultNode设置为context的curNode，**实际上是把当前节点赋值给context中curEntry的curNode**，用图形表示就是这样：

<img src="http://blog-1259650185.cosbj.myqcloud.com/img/202111/26/1637941160" alt="图片" style="zoom:50%;" />

多次创建不同的Entry，并且执行NodeSelectorSlot的entry方法后，就会变成这样一棵调用链树：

<img src="http://blog-1259650185.cosbj.myqcloud.com/img/202111/26/1637941335" alt="图片" style="zoom:50%;" />

**PS：这里图中的node0，node1，node2可能是相同的node，因为在同一个context中从map中获取的node是同一个，这里只是为了表述的更清楚所以用了不同的节点名。**

##### 保存子节点

上面已经分析了叶子节点的构造过程，叶子节点是保存在各个Entry的curNode属性中的。

我们知道context中只保存了入口节点和当前Entry，那子节点是什么时候保存的呢，其实子节点就是上面代码中的第2步中保存的。

下面我们来分析上面的第2步的情况：

```java
// Context.java
public Node getLastNode() {
    if (curEntry != null && curEntry.getLastNode() != null) {
        return curEntry.getLastNode();
    } else {
        return entranceNode;
    }
}
````
代码中我们可以知道，lastNode的值可能是context中的entranceNode也可能是curEntry.parent.curNode，但是他们都是「DefaultNode」类型的节点，DefaultNode的所有子节点是保存在一个HashSet中的。

第一次调用getLastNode方法时，context中curEntry是null，因为curEntry是在第3步中才赋值的。所以，lastNode最初的值就是context的entranceNode。那么将node添加到entranceNode的子节点中去之后就变成了下面这样：

<img src="http://blog-1259650185.cosbj.myqcloud.com/img/202111/26/1637941811" alt="图片" style="zoom:50%;" />

紧接着再进入一次，资源名不同，会再次生成一个新的Entry，上面的图形就变成下图这样：

<img src="http://blog-1259650185.cosbj.myqcloud.com/img/202111/26/1637941876" alt="图片" style="zoom:50%;" />

此时再次调用context的getLastNode方法，因为此时curEntry的parent不再是null了，所以获取到的lastNode是curEntry.parent.curNode，在上图中可以很方便的看出，这个节点就是**node0**。那么把当前节点node1添加到lastNode的子节点中去，上面的图形就变成下图这样：

<img src="http://blog-1259650185.cosbj.myqcloud.com/img/202111/26/1637942313" alt="图片" style="zoom:50%;" />

然后将当前node设置给context的curNode，上面的图形就变成下图这样：

<img src="http://blog-1259650185.cosbj.myqcloud.com/img/202111/27/1637942439" alt="图片" style="zoom:50%;" />

假如再创建一个Entry，然后再进入一次不同的资源名，上面的图就变成下面这样：

<img src="http://blog-1259650185.cosbj.myqcloud.com/img/202111/27/1637942526" alt="图片" style="zoom:50%;" />

至此NodeSelectorSlot的基本功能已经大致分析清楚了。

**PS：以上的分析是基于每次执行SphU.entry(name)时，资源名都是不一样的前提下。如果资源名都一样的话，那么生成的node都相同，则只会再第一次把node加入到entranceNode的子节点中去，其他的时候，只会创建一个新的Entry，然后替换context中的curEntry的值。**

再举一个例子：

```java
ContextUtil.enter("context-test", "");
Entry ea = SphU.entry("resouceA");
Entry eb = SphU.entry("resouceB");
eb.exit();
ea.exit();
```

当执行到

> Entry ea = SphU.entry("resouceA");

时， 这里执行的结果为：

![获取完resouceA权限之后](http://blog-1259650185.cosbj.myqcloud.com/img/202111/29/1638194188)

当执行到

> Entry eb = SphU.entry("resouceB");

时， 这里执行的结果为：

![img](http://blog-1259650185.cosbj.myqcloud.com/img/202111/29/1638194210)

根据两张图我们可以知道，通过这个slot，我们构建了一个完整的调用树。

再举个例子：创建一个Context和5个resourceEntry，看一下整个树的结构会是什么样子。

```java
 public static void main(String[] args) {
    try {
        Context context=ContextUtil.enter("context1");
        Entry entry=SphU.entry("A");
        Entry entry2=SphU.entry("B");
        Entry entry3=SphU.entry("C");
        Entry entry4=SphU.entry("D");
        Entry entry5=SphU.entry("E");
        entry.exit();
        entry2.exit();
        entry3.exit();
        entry4.exit();
        entry5.exit();
        ContextUtil.exit();
    } catch (BlockException ex) {
        // 处理被流控的逻辑
        System.out.println("blocked!");
    }catch (Exception e){
        e.printStackTrace();
    }
}
```

运行结果如下:

<img src="https://upload-images.jianshu.io/upload_images/3397380-3794a8a985204b12.png?imageMogr2/auto-orient/strip|imageView2/2/w/1200/format/webp" alt="img" style="zoom:50%;" />

### 2.1.2 ClusterBuilderSlot

此插槽用于构建资源的 `ClusterNode` 以及调用来源节点。`ClusterNode` 保持某个资源运行统计信息（响应时间、QPS、block 数目、线程数、异常数等）以及调用来源统计信息列表。调用来源的名称由 `ContextUtil.enter(contextName，origin)` 中的 `origin` 标记。可通过如下命令查看某个资源不同调用者的访问情况：`curl http://localhost:8719/origin?id=caller`：

```
id: nodeA
idx origin  threadNum passedQps blockedQps totalQps aRt   1m-passed 1m-blocked 1m-total 
1   caller1 0         0         0          0        0     0         0          0        
2   caller2 0         0         0          0        0     0         0          0        
```

NodeSelectorSlot的entry方法执行完之后，会调用fireEntry方法，此时会触发ClusterBuilderSlot的entry方法。

ClusterBuilderSlot的entry方法比较简单，具体代码如下：

```java
// ClusterBuilderSlot.java
@Override
public void entry(Context context, ResourceWrapper resourceWrapper, DefaultNode node, int count,
                  boolean prioritized, Object... args)
    throws Throwable {
    if (clusterNode == null) {
        synchronized (lock) {
            if (clusterNode == null) {
                // Create the cluster node.
                clusterNode = new ClusterNode(resourceWrapper.getName(), resourceWrapper.getResourceType());
                HashMap<ResourceWrapper, ClusterNode> newMap = new HashMap<>(Math.max(clusterNodeMap.size(), 16));
                newMap.putAll(clusterNodeMap);
                newMap.put(node.getId(), clusterNode);

                clusterNodeMap = newMap;
            }
        }
    }
    node.setClusterNode(clusterNode);

    if (!"".equals(context.getOrigin())) {
        Node originNode = node.getClusterNode().getOrCreateOriginNode(context.getOrigin());
        context.getCurEntry().setOriginNode(originNode);
    }

    fireEntry(context, resourceWrapper, node, count, prioritized, args);
}
```

NodeSelectorSlot的职责比较简单，主要做了两件事：

一、为每个资源创建一个clusterNode，然后把clusterNode塞到DefaultNode中去

二、将clusterNode保持到全局的map中去，用资源作为map的key

**PS：一个资源只有一个ClusterNode，但是可以有多个DefaultNode**

**在NodeSelectorSlot类中有一个Map保存了DefaultNode，但是key是用的contextName，而不是resourceName，这是为什么呢？**

试想一下，如果用resourceName来做map的key，那对于同一个资源resourceA来说，在context1中获取到的defaultNodeA和在context2中获取到的defaultNodeA是同一个，那么怎么在这两个context中对defaultNodeA进行更改呢，修改了一个必定会对另一个产生影响。

<img src="https://mmbiz.qpic.cn/mmbiz_png/GtXvavW2UlzWfcHpD5K9yOqibfMZmFttia6HDYqlWaOgtHdoxlSeCLDiaicV9KMr9iaNPg8xKcb9aUeryAxpvIoickbA/640?wx_fmt=png&tp=webp&wxfrom=5&wx_lazy=1&wx_co=1" alt="图片" style="zoom:50%;" />

而如果用contextName来作为key，那对于同一个资源resourceA来说，在context1中获取到的是defaultNodeA1，在context2中获取到是defaultNodeA2，那在不同的context中对同一个资源可以使用不同的DefaultNode进行分别统计和计算，最后再通过ClusterNode进行合并就可以了。

<img src="https://mmbiz.qpic.cn/mmbiz_png/GtXvavW2UlzWfcHpD5K9yOqibfMZmFttiatmAfloBDNHPoqkiaC0Mae1WLb5adnUNBnAEvIgmcPraUIwoOsalu5mQ/640?wx_fmt=png&tp=webp&wxfrom=5&wx_lazy=1&wx_co=1" alt="图片" style="zoom:50%;" />

所以在NodeSelectorSlot这个类里面，map里面保存的是contextName和DefaultNode的映射关系，目的是为了可以在不同的context对相同的资源进行分开统计。

同一个context中对同一个resource进行多次entry()调用时，会形式一颗调用树，这个树是通过CtEntry之间的parent/child关系维护的。

### 2.1.3 StatisticSlot

`StatisticSlot` 是 Sentinel 的核心功能插槽之一，用于根据规则判断结果统计实时的调用数据。

- `clusterNode`：资源唯一标识的 ClusterNode 的实时统计
- `origin`：根据来自不同调用者的统计信息
- `defaultnode`: 根据入口上下文区分的资源 ID 的 runtime 统计
- 入口流量的统计

```java
// StatisticSlot.java
@Override
public void entry(Context context, ResourceWrapper resourceWrapper, DefaultNode node, int count,
                  boolean prioritized, Object... args) throws Throwable {
    try {
        // Do some checking. 调用SlotChain中后续的所有slot，完成所有规则检测。其在执行过程中可能会抛异常，例如：规则检测未通过，抛出BlockException
        fireEntry(context, resourceWrapper, node, count, prioritized, args);

        // Request passed, add thread count and pass count. 代码能走到这里，说明前面的检测全部通过，此时就可以将该请求统计到相应数据中了
        node.increaseThreadNum(); // 增加线程数
        node.addPassRequest(count); // 增加通过的请求数量

        if (context.getCurEntry().getOriginNode() != null) {
            // Add count for origin node.
            context.getCurEntry().getOriginNode().increaseThreadNum();
            context.getCurEntry().getOriginNode().addPassRequest(count);
        }

        if (resourceWrapper.getEntryType() == EntryType.IN) {
            // Add count for global inbound entry node for global statistics.
            Constants.ENTRY_NODE.increaseThreadNum();
            Constants.ENTRY_NODE.addPassRequest(count);
        }

        // Handle pass event with registered entry callback handlers.
        for (ProcessorSlotEntryCallback<DefaultNode> handler : StatisticSlotCallbackRegistry.getEntryCallbacks()) {
            handler.onPass(context, resourceWrapper, node, count, args);
        }
    } catch (PriorityWaitException ex) {
				...
    } catch (BlockException e) {
				...
        throw e;
    } catch (Throwable e) {
				...
        throw e;
    }
}

@Override
public void exit(Context context, ResourceWrapper resourceWrapper, int count, Object... args) {
    Node node = context.getCurNode();

    if (context.getCurEntry().getBlockError() == null) {
        // Calculate response time (use completeStatTime as the time of completion).
        long completeStatTime = TimeUtil.currentTimeMillis();
        context.getCurEntry().setCompleteTimestamp(completeStatTime);
        long rt = completeStatTime - context.getCurEntry().getCreateTimestamp();

        Throwable error = context.getCurEntry().getError();

        // Record response time and success count.
        recordCompleteFor(node, count, rt, error);
        recordCompleteFor(context.getCurEntry().getOriginNode(), count, rt, error);
        if (resourceWrapper.getEntryType() == EntryType.IN) {
            recordCompleteFor(Constants.ENTRY_NODE, count, rt, error);
        }
    }

    // Handle exit event with registered exit callback handlers.
    Collection<ProcessorSlotExitCallback> exitCallbacks = StatisticSlotCallbackRegistry.getExitCallbacks();
    for (ProcessorSlotExitCallback handler : exitCallbacks) {
        handler.onExit(context, resourceWrapper, count, args);
    }

    fireExit(context, resourceWrapper, count);
}
```

entry 的时候：依次执行后续slot的entry方法，即SystemSlot、FlowSlot、DegradeSlot等的规则。每个 slot 触发流控的话会抛出异常（`BlockException` 的子类）。若有 `BlockException` 抛出，则记录 block 数据；若无异常抛出则算作可通过（pass），记录 pass 数据。

exit 的时候：若无 error（无论是业务异常还是流控异常），记录 complete（success）以及 RT，线程数-1。

记录数据的维度：线程数+1、记录当前 DefaultNode 数据、记录对应的 originNode 数据（若存在 origin）、累计 IN 统计数据（若流量类型为 IN）。

Sentinel 底层采用高性能的滑动窗口数据结构 `LeapArray` 来统计实时的秒级指标数据，可以很好地支撑写多于读的高并发场景。

<img src="http://blog-1259650185.cosbj.myqcloud.com/img/202111/25/1637845403.png" alt="sliding-window-leap-array" style="zoom:50%;" />

### 2.1.4 SystemSlot

这个 slot 会根据对于当前系统的整体情况，对入口资源的调用进行动态调配。其原理是让入口的流量和当前系统的预计容量达到一个动态平衡。

注意系统规则只对入口流量起作用（调用类型为 `EntryType.IN`），对出口流量无效。可通过 `SphU.entry(res, entryType)` 指定调用类型，如果不指定，默认是`EntryType.OUT`。

### 2.1.5 AuthoritySlot

AuthoritySlot做的事也比较简单，主要是根据黑白名单进行过滤，只要有一条规则校验不通过，就抛出异常。

```java
// AuthoritySlot.java
@Override
public void entry(Context context, ResourceWrapper resourceWrapper, DefaultNode node, int count, boolean prioritized, Object... args)
    throws Throwable {
    checkBlackWhiteAuthority(resourceWrapper, context);
    fireEntry(context, resourceWrapper, node, count, prioritized, args);
}

@Override
public void exit(Context context, ResourceWrapper resourceWrapper, int count, Object... args) {
    fireExit(context, resourceWrapper, count, args);
}

void checkBlackWhiteAuthority(ResourceWrapper resource, Context context) throws AuthorityException {
    Map<String, Set<AuthorityRule>> authorityRules = AuthorityRuleManager.getAuthorityRules();

    if (authorityRules == null) {
        return;
    }

    Set<AuthorityRule> rules = authorityRules.get(resource.getName());
    if (rules == null) {
        return;
    }

    for (AuthorityRule rule : rules) {
        if (!AuthorityRuleChecker.passCheck(rule, context)) {
            throw new AuthorityException(context.getOrigin(), rule);
        }
    }
}
```

### 2.1.6 FlowSlot

这个 slot 主要根据预设的资源的统计信息，按照固定的次序，依次生效。如果一个资源对应两条或者多条流控规则，则会根据如下次序依次检验，直到全部通过或者有一个规则生效为止:

- 指定应用生效的规则，即针对调用方限流的；
- 调用方为 other 的规则；
- 调用方为 default 的规则。

```java
// FlowSlot.java
@Override
public void entry(Context context, ResourceWrapper resourceWrapper, DefaultNode node, int count,
                  boolean prioritized, Object... args) throws Throwable {
    checkFlow(resourceWrapper, context, node, count, prioritized); // 检测并应用流控规则
    // 触发下一个slot
    fireEntry(context, resourceWrapper, node, count, prioritized, args);
}

void checkFlow(ResourceWrapper resource, Context context, DefaultNode node, int count, boolean prioritized)
    throws BlockException {
    checker.checkFlow(ruleProvider, resource, context, node, count, prioritized);
}
```

### 2.1.7 DegradeSlot

这个 slot 主要针对资源的平均响应时间（RT）以及异常比率，来决定资源是否在接下来的时间被自动熔断掉。

```java
@Override
public void entry(Context context, ResourceWrapper resourceWrapper, DefaultNode node, int count,
                  boolean prioritized, Object... args) throws Throwable {
    performChecking(context, resourceWrapper); // 完成熔断降级检测
    // 触发下一个节点
    fireEntry(context, resourceWrapper, node, count, prioritized, args);
}

void performChecking(Context context, ResourceWrapper r) throws BlockException {
    List<CircuitBreaker> circuitBreakers = DegradeRuleManager.getCircuitBreakers(r.getName()); // 获取到当前资源的所有熔断器
    if (circuitBreakers == null || circuitBreakers.isEmpty()) { // 若熔断器为空，则直接结束
        return;
    }
    for (CircuitBreaker cb : circuitBreakers) { // 逐个尝试所有熔断器
        if (!cb.tryPass(context)) { // 如果没有通过，则直接抛出DegradeException
            throw new DegradeException(cb.getRule().getLimitApp(), cb.getRule());
        }
    }
}
```

### 2.1.8 总结

sentinel的限流降级等功能，主要是通过一个SlotChain实现的。在链式插槽中，有7个核心的Slot，这些Slot各司其职，可以分为以下几种类型：

一、进行资源调用路径构造的NodeSelectorSlot和ClusterBuilderSlot。

二、进行资源的实时状态统计的StatisticsSlot。

三、进行系统保护，限流，降级等规则校验的SystemSlot、AuthoritySlot、FlowSlot、DegradeSlot。

后面几个Slot依赖于前面几个Slot统计的结果。至此，每种Slot的功能已经基本分析清楚了。

## 2.2 ProcessorSlotChain

Sentinel 的核心骨架，将不同的 Slot 按照顺序串在一起（责任链模式），从而将不同的功能（限流、降级、系统保护）组合在一起。slot chain 其实可以分为两部分：统计数据构建部分（statistic）和判断部分（rule checking）。核心结构：

<img src="http://blog-1259650185.cosbj.myqcloud.com/img/202111/24/1637720298.png" alt="sentinel-slot-chain" style="zoom: 25%;" />

目前的设计是 **one slot chain per resource**，因为某些 slot 是 per resource 的（比如 NodeSelectorSlot）。

```java
/** 这是一个单向链表，默认包含一个节点，且有两个指针first和end同时指向这个节点
 * @author qinan.qn
 * @author jialiang.linjl
 */
public class DefaultProcessorSlotChain extends ProcessorSlotChain {

    AbstractLinkedProcessorSlot<?> first = new AbstractLinkedProcessorSlot<Object>() {

        @Override
        public void entry(Context context, ResourceWrapper resourceWrapper, Object t, int count, boolean prioritized, Object... args)
            throws Throwable {
            super.fireEntry(context, resourceWrapper, t, count, prioritized, args);
        }

        @Override
        public void exit(Context context, ResourceWrapper resourceWrapper, int count, Object... args) {
            super.fireExit(context, resourceWrapper, count, args);
        }

    };
    AbstractLinkedProcessorSlot<?> end = first;

    @Override
    public void addFirst(AbstractLinkedProcessorSlot<?> protocolProcessor) {
        protocolProcessor.setNext(first.getNext());
        first.setNext(protocolProcessor);
        if (end == first) {
            end = protocolProcessor;
        }
    }

    @Override
    public void addLast(AbstractLinkedProcessorSlot<?> protocolProcessor) {
        end.setNext(protocolProcessor); // 当前end的下一个节点指向新节点
        end = protocolProcessor; // end指向新节点
    }

    /**
     * Same as {@link #addLast(AbstractLinkedProcessorSlot)}.
     *
     * @param next processor to be added.
     */
    @Override
    public void setNext(AbstractLinkedProcessorSlot<?> next) {
        addLast(next);
    }

    @Override
    public AbstractLinkedProcessorSlot<?> getNext() {
        return first.getNext();
    }

    @Override
    public void entry(Context context, ResourceWrapper resourceWrapper, Object t, int count, boolean prioritized, Object... args)
        throws Throwable {
        first.transformEntry(context, resourceWrapper, t, count, prioritized, args);
    }

    @Override
    public void exit(Context context, ResourceWrapper resourceWrapper, int count, Object... args) {
        first.exit(context, resourceWrapper, count, args);
    }

}
```

DefaultProcessorSlotChain中有两个AbstractLinkedProcessorSlot类型的变量：first和end，这就是链表的头结点和尾节点。

创建DefaultProcessorSlotChain对象时，首先创建了首节点，然后把首节点赋值给了尾节点，可以用下图表示：

<img src="http://blog-1259650185.cosbj.myqcloud.com/img/202111/26/1637857569" alt="图片" style="zoom:67%;" />

将第一个节点添加到链表中后，整个链表的结构变成了如下图这样：

<img src="http://blog-1259650185.cosbj.myqcloud.com/img/202111/26/1637857596" alt="图片" style="zoom:67%;" />

将所有的节点都加入到链表中后，整个链表的结构变成了如下图所示：

<img src="http://blog-1259650185.cosbj.myqcloud.com/img/202111/26/1637857612" alt="图片" style="zoom: 50%;" />



这样就将所有的Slot对象添加到了链表中去了，每一个Slot都是继承自AbstractLinkedProcessorSlot。而AbstractLinkedProcessorSlot是一种责任链的设计，每个对象中都有一个next属性，指向的是另一个AbstractLinkedProcessorSlot对象。其实责任链模式在很多框架中都有，比如Netty中是通过pipeline来实现的。

**执行SlotChain的entry方法**

lookProcessChain方法获得的ProcessorSlotChain的实例是DefaultProcessorSlotChain，那么执行chain.entry方法，就会执行DefaultProcessorSlotChain的entry方法，而DefaultProcessorSlotChain的entry方法是这样的：

```java
// DefaultProcessorSlotChain.java
@Override
public void entry(Context context, ResourceWrapper resourceWrapper, Object t, int count, boolean prioritized, Object... args)
    throws Throwable {
    first.transformEntry(context, resourceWrapper, t, count, prioritized, args);
}
```

也就是说，DefaultProcessorSlotChain的entry实际是执行的first属性的transformEntry方法。

而transformEntry方法会执行当前节点的entry方法，在DefaultProcessorSlotChain中first节点重写了entry方法，具体如下：

```java
// DefaultProcessorSlotChain.
@Override
public void entry(Context context, ResourceWrapper resourceWrapper, Object t, int count, boolean prioritized, Object... args)
    throws Throwable {
    super.fireEntry(context, resourceWrapper, t, count, prioritized, args);
}
```

first节点的entry方法，实际又是执行的super的fireEntry方法，那继续把目光转移到fireEntry方法，具体如下：

```java
// AbstractLinkedProcessorSlot.java
@Override
public void fireEntry(Context context, ResourceWrapper resourceWrapper, Object obj, int count, boolean prioritized, Object... args)
    throws Throwable {
    if (next != null) { // 切换到下一个节点
        next.transformEntry(context, resourceWrapper, obj, count, prioritized, args);
    }
}
```

从这里可以看到，从fireEntry方法中就开始传递执行entry了，这里会执行当前节点的下一个节点transformEntry方法，上面已经分析过了，transformEntry方法会触发当前节点的entry，也就是说**fireEntry方法实际是触发了下一个节点的entry方法**。具体的流程如下图所示：

<img src="http://blog-1259650185.cosbj.myqcloud.com/img/202111/26/1637858105" alt="图片" style="zoom:50%;" />

从图中可以看出，从最初的调用Chain的entry()方法，转变成了调用SlotChain中Slot的entry()方法。从上面的分析可以知道，SlotChain中的第一个Slot节点是NodeSelectorSlot。

**执行Slot的entry方法**

现在可以把目光转移到SlotChain中的第一个节点NodeSelectorSlot的entry方法中去了，具体的代码如下：

```java
// NodeSelectorSlot.java
@Override
public void entry(Context context, ResourceWrapper resourceWrapper, Object obj, int count, boolean prioritized, Object... args)
    throws Throwable {
    DefaultNode node = map.get(context.getName());
    if (node == null) {
        synchronized (this) {
            node = map.get(context.getName());
            if (node == null) {
                node = new DefaultNode(resourceWrapper, null);
                HashMap<String, DefaultNode> cacheMap = new HashMap<String, DefaultNode>(map.size());
                cacheMap.putAll(map);
                cacheMap.put(context.getName(), node);
                map = cacheMap;
                // Build invocation tree
                ((DefaultNode) context.getLastNode()).addChild(node);
            }

        }
    }

    context.setCurNode(node);
    fireEntry(context, resourceWrapper, node, count, prioritized, args);
}
```

从代码中可以看到，NodeSelectorSlot节点做了一些自己的业务逻辑处理。执行完业务逻辑处理后，调用了fireEntry()方法，由此触发了下一个节点的entry方法。此时我们就知道了sentinel的责任链就是这样传递的：每个Slot节点执行完自己的业务后，会调用fireEntry来触发下一个节点的entry方法。

所以可以将上面的图完整了，具体如下：

<img src="http://blog-1259650185.cosbj.myqcloud.com/img/202111/26/1637858543" alt="图片" style="zoom:50%;" />

至此就通过SlotChain完成了对每个节点的entry()方法的调用，**每个节点会根据创建的规则，进行自己的逻辑处理，当统计的结果达到设置的阈值时，就会触发限流、降级等事件，具体是抛出BlockException异常**。

**总结**
sentinel主要是基于7种不同的Slot形成了一个链表，每个Slot都各司其职，自己做完分内的事之后，会把请求传递给下一个Slot，直到在某一个Slot中命中规则后抛出BlockException而终止。

前三个Slot负责做统计，后面的Slot负责根据统计的结果结合配置的规则进行具体的控制，是Block该请求还是放行。

控制的类型也有很多可选项：根据qps、线程数、冷启动等等。

然后基于这个核心的方法，衍生出了很多其他的功能：

1. dashboard控制台，可以可视化的对每个连接过来的sentinel客户端 (通过发送heartbeat消息)进行控制，dashboard和客户端之间通过http协议进行通讯。
2. 规则的持久化，通过实现DataSource接口，可以通过不同的方式对配置的规则进行持久化，默认规则是在内存中的。
3. 对主流的框架进行适配，包括servlet，dubbo，gRpc等。

## 2.3 Context

源码中是这样描述context类的：`This class holds metadata of current invocation` 。就是说在context中维护着当前调用链的元数据，那元数据有哪些呢，从context类的源码中可以看到有：

- entranceNode：当前调用链的入口节点
- curEntry：当前调用链的当前entry
- origin：当前调用链的调用源

<img src="https://mmbiz.qpic.cn/mmbiz_png/GtXvavW2UlzWfcHpD5K9yOqibfMZmFttialZhdCtZXmrBvjNe7ltibKia9TQ6OLmJiby4QkNmQ5cLJ43VYa5VWF9prQ/640?wx_fmt=png&tp=webp&wxfrom=5&wx_lazy=1&wx_co=1" alt="图片" style="zoom:50%;" />

Context 代表调用链路上下文，贯穿一次调用链路中的所有 `Entry`，每个资源操作必须属于一个Context。Context 维持着入口节点（`entranceNode`）、本次调用链路的`curEntry`、调用来源（`origin`）等信息，**并且相同的资源名(注意，是资源名)只会创建一个上下文**。**Context 名称即为调用链路入口名称**。如果代码中没有指定Context，则会创建一个name为`sentinel_default_context`的默认Context。**一个Context生命周期中可以包含多个资源操作**。Context生命周期中的最后一个资源在exit()时会清理该Conetxt，这也就意味着这个Context生命周期结束了。

```java
public class Context {
  
  	// 上下文名称
    private final String name;

  	// 当前调用树的入口节点
    private DefaultNode entranceNode;

  	// 当前入口
    private Entry curEntry;

  	// 来源，比如服务名称、ip等
    private String origin = "";

    private final boolean async;
  	
  	...
}
```

Context 维持的方式：通过 ThreadLocal 传递，只有在入口 `enter` 的时候生效。由于 Context 是通过 ThreadLocal 传递的，因此对于异步调用链路，线程切换的时候会丢掉 Context，因此需要手动通过 `ContextUtil.runOnContext(context, f)` 来变换 context。

Context代码举例：

```java
// Context 就是一次调用链，可能包含对多个资源的操作
public class Demo {
    public void m() {
        // 创建一个来自于appA访问的Context，
        // entranceOne为Context的name
        ContextUtil.enter("entranceOne", "appA");
        // Entry就是一个资源操作对象
        Entry resource1 = null;
        Entry resource2 = null;
        try {
            // 获取资源resource1的entry
            resource1 = SphU.entry("resource1");
            // 代码能走到这里，说明当前对资源resource1的请求通过了流控
            // 对资源resource1的相关业务处理。。。

            // 获取资源resource2的entry
            resource2 = SphU.entry("resource2");
            // 代码能走到这里，说明当前对资源resource2的请求通过了流控
            // 对资源resource2的相关业务处理。。。
        } catch (BlockException e) {
            // 代码能走到这里，说明请求被限流，
            // 这里执行降级处理
        } finally {
            if (resource1 != null) {
                resource1.exit();
            }
            if (resource2 != null) {
                resource2.exit();
            }
        }
        // 释放Context
        ContextUtil.exit();

        // --------------------------------------------------------

        // 创建另一个来自于appA访问的Context，
        // entranceTwo为Context的name
        ContextUtil.enter("entranceTwo", "appA");
        // Entry就是一个资源操作对象
        Entry resource3 = null;
        try {
            // 获取资源resource2的entry
            resource2 = SphU.entry("resource2");
            // 代码能走到这里，说明当前对资源resource2的请求通过了流控
            // 对资源resource2的相关业务处理。。。


            // 获取资源resource3的entry
            resource3 = SphU.entry("resource3");
            // 代码能走到这里，说明当前对资源resource3的请求通过了流控
            // 对资源resource3的相关业务处理。。。

        } catch (BlockException e) {
            // 代码能走到这里，说明请求被限流，
            // 这里执行降级处理
        } finally {
            if (resource2 != null) {
                resource2.exit();
            }
            if (resource3 != null) {
                resource3.exit();
            }
        }
        // 释放Context
        ContextUtil.exit();
    }
}
```

再举一个例子：

```java
ContextUtil.enter("context-test", "");
Entry ea = SphU.entry("resouceA");
Entry eb = SphU.entry("resouceB");
eb.exit();
ea.exit();
```

当执行到

> ContextUtil.enter("context-test", "");

时，context的内容为：

![img](http://blog-1259650185.cosbj.myqcloud.com/img/202111/29/1638193756)

当执行到

> Entry ea = SphU.entry("resouceA");

时，context内容为：

![img](http://blog-1259650185.cosbj.myqcloud.com/img/202111/29/1638193785)

当执行到

> Entry eb = SphU.entry("resouceB");

时，context内容为：

![img](http://blog-1259650185.cosbj.myqcloud.com/img/202111/29/1638193810)

这就构建了一个调用关系，即我们在上下文context-test中，先获取了resourceA的权限，再获取了resourceB的权限，这两个资源在调用关系上存在一个先后关系。当我们在后面调用exit的时候，也是先退curEntry指向的entry，并且把curEntry指向parent，后面再退他的parent。

**Context是通过ContextUtil创建的，具体的方法是trueEntry**，代码如下：

```java
// ContextUtil.java
protected static Context trueEnter(String name, String origin) {
    Context context = contextHolder.get(); // 尝试从ThreadLocal中获取Context
    if (context == null) { // 若ThreadLocal中没有context，则尝试从缓存map中获取
        Map<String, DefaultNode> localCacheNameMap = contextNameNodeMap; // 缓存map的key为context名称，value为EntranceNode
        DefaultNode node = localCacheNameMap.get(name); // 获取EntranceNode -- 双重检测锁DCL -- 为了防止并发创建
        if (node == null) { // 若缓存map的size大于context数量的最大阈值，则直接返回NULL_CONTEXT
            if (localCacheNameMap.size() > Constants.MAX_CONTEXT_NAME_SIZE) {
                setNullContext();
                return NULL_CONTEXT;
            } else {
                LOCK.lock();
                try {
                    node = contextNameNodeMap.get(name);
                    if (node == null) {
                        if (contextNameNodeMap.size() > Constants.MAX_CONTEXT_NAME_SIZE) {
                            setNullContext();
                            return NULL_CONTEXT;
                        } else { // 创建一个EntranceNode
                            node = new EntranceNode(new StringResourceWrapper(name, EntryType.IN), null);
                            // Add entrance node. 将新建的node添加到ROOT
                            Constants.ROOT.addChild(node);
                            // 写时复制，空间换并发性能，将新建node写入到缓存map，为了防止"迭代稳定性问题"（iterate stable），对于共享集合的写操作要采用这种形式，避免并发问题
                            Map<String, DefaultNode> newMap = new HashMap<>(contextNameNodeMap.size() + 1);
                            newMap.putAll(contextNameNodeMap);
                            newMap.put(name, node);
                            contextNameNodeMap = newMap;
                        }
                    }
                } finally {
                    LOCK.unlock();
                }
            }
        }
        context = new Context(node, name); // 将node和name封装成context
        context.setOrigin(origin); // 初始化context的来源
        contextHolder.set(context); // 将context写入ThreadLocal
    }

    return context;
}
```

生成Context的过程：

1. 先从ThreadLocal中获取，如果能获取到直接返回，如果获取不到则继续第2步。
2. 从一个static的map中根据上下文的名称获取，如果能获取到则直接返回，否则继续第3步。
3. 加锁后进行一次double check，如果还是没能从map中获取到，则创建一个EntranceNode，并把该EntranceNode添加到一个全局的ROOT节点中去，然后将该节点添加到map中去(这部分代码在上述代码中省略了)。
4. 根据EntranceNode创建一个上下文，并将该上下文保存到ThreadLocal中去，下一个请求可以直接获取。

所以，**一个线程对应一个Context，一个ContextName对应多个Context，一个ContextName共享一个EntranceNode。**

<img src="https://upload-images.jianshu.io/upload_images/3397380-a53df77b1587fad1.png?imageMogr2/auto-orient/strip|imageView2/2/w/663/format/webp" alt="img" style="zoom:50%;" />

当有三个线程访问 `helloWorld`的`Context`,会初始化3个Context，但是这三个Context共同指向同一个`EntranceNode`。

那保存在ThreadLocal中的上下文什么时候会清除呢？从代码中可以看到具体的清除工作在ContextUtil的exit方法中，当执行该方法时，会将保存在ThreadLocal中的context对象清除。

```java
// ContextUtil.java
public static void exit() {
    Context context = contextHolder.get();
    if (context != null && context.getCurEntry() == null) {
        contextHolder.set(null);
    }
}
```

那ContextUtil.exit方法什么时候会被调用呢？有两种情况：一是主动调用ContextUtil.exit的时候，二是当一个入口Entry要退出，执行该Entry的trueExit方法的时候，此时会触发ContextUtil.exit的方法。但是有一个前提，**就是当前Entry的父Entry为null时，此时说明该Entry已经是最顶层的根节点了，可以清除context**。



<img src="https://mmbiz.qpic.cn/mmbiz_png/GtXvavW2UlzWfcHpD5K9yOqibfMZmFttiahKxbMSnSCvhdW85DVeQ9GRM58ueqDGBUwfgEwsErs8jHebXeSXIp6w/640?wx_fmt=png&tp=webp&wxfrom=5&wx_lazy=1&wx_co=1" alt="图片" style="zoom:50%;" />



## 2.4 Entry

每一次资源调用都会创建一个 `Entry`。`Entry` 包含了资源名、curNode（当前统计节点）、originNode（来源统计节点）等信息。entry是Sentinel中用来表示是否通过限流的一个凭证，就像一个token一样。每次执行 `SphU.entry()` 或 `SphO.entry()` 都会返回一个 `Entry` 给调用者，意思就是告诉调用者，如果正确返回了 `Entry` 给你，那表示你可以正常访问被Sentinel保护的后方服务了，否则Sentinel会抛出一个BlockException(如果是 `SphO.entry()` 会返回false)，这就表示调用者想要访问的服务被保护了，也就是说调用者本身被限流了。

`Entry`是一个抽象类，他只有一个实现类`CtEntry` ，在调用 `SphU.entry(xxx)` 的时候创建。它的特性是：Linked entry within current context（内部维护着 `parent` 和 `child`）。

`Entry`中保存了本次执行 entry() 方法的一些基本信息，包括：

- createTimestamp：当前Entry的创建时间，主要用来后期计算rt
- curNode：当前Entry所关联的node，该node主要是记录了当前context下该资源的统计信息
- originNode：当前Entry的调用来源，通常是调用方的应用名称，在 `ClusterBuilderSlot.entry()` 方法中设置的
- resourceWrapper：当前Entry所关联的资源

当在一个上下文中多次调用了 `SphU.entry()` 方法时，就会创建一个调用树，这个树的节点之间是通过parent和child关系维持的。

**需要注意的是：parent和child是在 `CtSph` 类的一个私有内部类 `CtEntry` 中定义的， `CtEntry`是 `Entry` 的一个子类。**由于context中总是保存着调用链树中的当前入口，所以当当前entry执行exit退出时，需要将parent设置为当前入口。

**需要注意的一点**：CtEntry 构造函数中会做**调用链的变换**，即将当前 Entry 接到传入 Context 的调用链路上（`setUpEntryFor`）。

资源调用结束时需要 `entry.exit()`。exit 操作会过一遍 slot chain exit，恢复调用栈，exit context 然后清空 entry 中的 context 防止重复调用。

**一个resource对应一个SlotChain，一个请求创建一个Entry**。

<img src="https://upload-images.jianshu.io/upload_images/3397380-ac90d15b225dec58.png?imageMogr2/auto-orient/strip|imageView2/2/w/1090/format/webp" alt="img" style="zoom:50%;" />

## 2.5 Node

节点是用来保存某个资源的各种实时统计信息的，他是一个接口，通过访问节点，就可以获取到对应资源的实时状态，以此为依据进行限流和降级操作。如下图所示：

<img src="http://blog-1259650185.cosbj.myqcloud.com/img/202111/26/1637895308" alt="图片" style="zoom:50%;" />

<img src="http://blog-1259650185.cosbj.myqcloud.com/img/202111/24/1637720564.png" alt="Sentinel中Node间的关系示意图" style="zoom:67%;" />





Sentinel 里面的各种种类的统计节点：

- `StatisticNode`：最为基础的统计节点，用于完成数据统计，包含秒级和分钟级两个滑动窗口结构。
- `DefaultNode`：链路节点，用于**统计调用链路上某个资源当前Context中的数据**，维持树状结构。当在同一个上下文中多次调用entry方法时，该节点可能下会创建有一系列的子节点。另外每个`DefaultNode`中会关联一个`ClusterNode`。
- `ClusterNode`：簇点（集群节点），用于统计**每个资源全局的数据（不区分调用链路，在所有Context中的总体统计数据）**，以及存放该资源的按来源区分的调用数据（类型为 `StatisticNode`，包括rt，线程数，qps等等）。相同的资源会全局共享同一个`ClusterNode`，不管他属于哪个上下文。特别地，`Constants.ENTRY_NODE` 节点用于统计全局的入口资源数据。
- `EntranceNode`：每个上下文的入口节点，特殊的链路节点，该节点是直接挂在root下的，对应某个 **Context 入口的所有调用数据**。一个Context会有一个入口节点，通过可以获取调用链树中所有的子节点，用于统计当前Context的总体流量数据。`Constants.ROOT` 节点也是入口节点。

构建的时机：

- `EntranceNode` 在 `ContextUtil.enter(xxx)` 的时候就创建了，然后塞到 Context 里面。
- `NodeSelectorSlot`：根据 context 创建 `DefaultNode`，然后 set curNode to context。
- `ClusterBuilderSlot`：首先根据 resourceName 创建 `ClusterNode`，并且 set clusterNode to defaultNode；然后再根据 origin 创建来源节点（类型为 `StatisticNode`），并且 set originNode to curEntry。

几种 Node 的维度（数目）：

- `ClusterNode` 的维度是 **resource**，存在ClusterBuilderSlot类的 `map` 里面
- `DefaultNode` 的维度是 **resource * context**，存在每个 NodeSelectorSlot 的 `clusterNodeMap` 里面
- `EntranceNode` 的维度是 **context**，存在 ContextUtil 类的 `contextNameNodeMap` 里面
- 来源节点（类型为 `StatisticNode`）的维度是 **resource * origin**，存在每个 ClusterNode 的 `originCountMap` 里面

 

# 3. 滑动时间窗算法

对于滑动时间窗算法的源码解析分为两部分：对数据的统计，与对统计数据的使用。不过，在分析源码之前，需要先理解该算法原理。

## 3.1 时间窗限流算法 

**算法原理**

<img src="http://blog-1259650185.cosbj.myqcloud.com/img/202111/24/1637720796.png" alt="image-20211124102636468" style="zoom:50%;" />

该算法原理是，系统会自动选定一个时间窗口的起始零点，然后按照固定长度将时间轴划分为若干定长的时间窗口。所以该算法也称为“固定时间窗算法”。

当请求到达时，系统会查看该请求到达的时间点所在的时间窗口当前统计的数据是否超出了预先设定好的阈值。未超出，则请求通过，否则被限流。

**存在的问题**

![image-20211124102710406](http://blog-1259650185.cosbj.myqcloud.com/img/202111/24/1637720830.png)

该算法存在这样的问题：连续两个时间窗口中的统计数据都没有超出阈值，但在跨窗口的时间窗长度范围内的统计数据却超出了阈值。

## 3.2 滑动时间窗限流算法 

**算法原理**

<img src="http://blog-1259650185.cosbj.myqcloud.com/img/202111/24/1637720862.png" alt="image-20211124102742066" style="zoom:50%;" />

滑动时间窗限流算法解决了固定时间窗限流算法的问题。其没有划分固定的时间窗起点与终点，而是将每一次请求的到来时间点作为统计时间窗的终点，起点则是终点向前推时间窗长度的时间点。这种时间窗称为“滑动时间窗”。

**存在的问题** 

<img src="http://blog-1259650185.cosbj.myqcloud.com/img/202111/24/1637720954.png" alt="image-20211124102914588" style="zoom:50%;" />

**算法改进**

<img src="http://blog-1259650185.cosbj.myqcloud.com/img/202111/24/1637720975.png" alt="image-20211124102935236" style="zoom:50%;" />

针对以上问题，系统采用了一种“折中”的改进措施：将整个时间轴拆分为若干“样本窗口”，样本窗口的长度是小于滑动时间窗口长度的。当等于滑动时间窗口长度时，就变为了“固定时间窗口算法”。 一般时间窗口长度会是样本窗口长度的整数倍。

那么是如何判断一个请求是否能够通过呢？当到达样本窗口终点时间时，每个样本窗口会统计一次本样本窗口中的流量数据并记录下来。当一个请求到达时，会统计出当前请求时间点所在样本窗口中的流量数据，然后再获取到当前请求时间点所在时间窗中其它样本窗口的统计数据，求和后，如果没有超出阈值，则通过，否则被限流。

## 3.3 数据统计源码解析 

<img src="http://blog-1259650185.cosbj.myqcloud.com/img/202111/24/1637721030.png" alt="Sentinel滑动时间窗算法源码解析—数据统计" style="zoom:50%;" />

<img src="https://upload-images.jianshu.io/upload_images/13670604-f5d244c9080260ec.jpg?imageMogr2/auto-orient/strip|imageView2/2/w/521/format/webp" alt="img" style="zoom:50%;" />

### 化整为零

我们已经知道了Slot是从第一个往后一直传递到最后一个的，且当信息传递到StatisticSlot时，这里就开始进行统计了，统计的结果又会被后续的Slot所采用，作为规则校验的依据。我们先来看一段非常熟悉的代码，就是StatisticSlot中的entry方法：

```java
// StatisticSlot.java
@Override
public void entry(Context context, ResourceWrapper resourceWrapper, DefaultNode node, int count,
                  boolean prioritized, Object... args) throws Throwable {
    try {
        // Do some checking. 调用SlotChain中后续的所有slot，完成所有规则检测。其在执行过程中可能会抛异常，例如：规则检测未通过，抛出BlockException
        fireEntry(context, resourceWrapper, node, count, prioritized, args);

        // Request passed, add thread count and pass count. 代码能走到这里，说明前面的检测全部通过，此时就可以将该请求统计到相应数据中了
        node.increaseThreadNum(); // 增加线程数
        node.addPassRequest(count); // 增加通过的请求数量

        if (context.getCurEntry().getOriginNode() != null) {
            // Add count for origin node.
            context.getCurEntry().getOriginNode().increaseThreadNum();
            context.getCurEntry().getOriginNode().addPassRequest(count);
        }

        if (resourceWrapper.getEntryType() == EntryType.IN) {
            // Add count for global inbound entry node for global statistics.
            Constants.ENTRY_NODE.increaseThreadNum();
            Constants.ENTRY_NODE.addPassRequest(count);
        }

        for (ProcessorSlotEntryCallback<DefaultNode> handler : StatisticSlotCallbackRegistry.getEntryCallbacks()) {
            handler.onPass(context, resourceWrapper, node, count, args);
        }
    } catch (PriorityWaitException ex) {
				...
    } catch (BlockException e) {
				...
        throw e;
    } catch (Throwable e) {
				...
        throw e;
    }
}
```

#### DefaultNode和ClusterNode

我们可以看到 `node.addPassRequest()` 这段代码是在fireEntry执行之后执行的，这意味着，当前请求通过了sentinel的流控等规则，此时需要将当次请求记录下来，也就是执行 `node.addPassRequest()` 这行代码，现在我们进入这个代码看看。具体的代码如下所示：

```java
// DefaultNode.java
@Override
public void addPassRequest(int count) {
    super.addPassRequest(count); // 增加当前入口的DefaultNode中的统计数据
    this.clusterNode.addPassRequest(count); // 增加当前资源的ClusterNode中的全局统计数据
}
```

首先我们知道这里的node是一个 `DefaultNode` 实例，这里特别补充一个 `DefaultNode` 和 `ClusterNode` 的区别：

- DefaultNode：保存着某个resource在某个context中的实时指标，每个DefaultNode都指向一个ClusterNode。
- ClusterNode：保存着某个resource在所有的context中实时指标的总和，同样的resource会共享同一个ClusterNode，不管他在哪个context中。

#### StatisticNode

好了，知道了他们的区别后，我们再来看上面的代码，其实都是执行的 `StatisticNode` 对象的 `addPassRequest` 方法。进入这个方法中看下具体的代码：

```java
// StatisticNode.java
/**
 * 定义了一个使用数组保存数据的计量器。SAMPLE_COUNT，样本窗口数量，默认值为2。INTERVAL时间窗口长度，默认值为1000ms
 */
private transient volatile Metric rollingCounterInSecond = new ArrayMetric(SampleCountProperty.SAMPLE_COUNT,
    IntervalProperty.INTERVAL);

private transient Metric rollingCounterInMinute = new ArrayMetric(60, 60 * 1000, false);

@Override
public void addPassRequest(int count) {
    rollingCounterInSecond.addPass(count); // 为滑动计数器增加本次访问的数据
    rollingCounterInMinute.addPass(count);
}
```

#### Metric

从代码中我们可以看到，具体的增加pass指标是通过一个叫 `Metric` 的接口进行操作的，并且是通过 `ArrayMetric` 这种实现类，现在我们在进入 `ArrayMetric` 中看一下。具体的代码如下所示：

```java
// ArrayMetric.java
public class ArrayMetric implements Metric {
    // 数据就保存在这个数据结构中
    private final LeapArray<MetricBucket> data;
}
```

#### LeapArray和MetricBucket

本以为在`ArrayMetric`中应该可以看到具体的统计操作了，谁知道又出现了一个叫 `MetricBucket` 的类。继续跟代码，发现 `wrap.value().addPass()` 是执行的 `wrap` 对象所包装的 `MetricBucket` 对象的 `addPass` 方法，这里就是最终的增加qps中q的值的地方了。进入 `MetricBucket` 类中看一下，具体的代码如下：

```java
// MetricBucket.java
public class MetricBucket {
    // 统计的数据存放在这里，是多维度的，这些维度类型在MetricEvent枚举中
    private final LongAdder[] counters;

    private volatile long minRt;

    public MetricBucket() {
        MetricEvent[] events = MetricEvent.values();
        this.counters = new LongAdder[events.length];
        for (MetricEvent event : events) {
            counters[event.ordinal()] = new LongAdder();
        }
        initMinRt();
    }

    public MetricBucket reset(MetricBucket bucket) {
        for (MetricEvent event : MetricEvent.values()) {
            counters[event.ordinal()].reset();
            counters[event.ordinal()].add(bucket.get(event));
        }
        initMinRt();
        return this;
    }

    private void initMinRt() {
        this.minRt = SentinelConfig.statisticMaxRt();
    }

    /**
     * Reset the adders.
     *
     * @return new metric bucket in initial state
     */
    public MetricBucket reset() {
        for (MetricEvent event : MetricEvent.values()) { // 将每个维度的统计数据清零
            counters[event.ordinal()].reset();
        }
        initMinRt();
        return this;
    }

    public long get(MetricEvent event) {
        return counters[event.ordinal()].sum();
    }

    public MetricBucket add(MetricEvent event, long n) {
        counters[event.ordinal()].add(n);
        return this;
    }

    public long pass() {
        return get(MetricEvent.PASS);
    }

    public long occupiedPass() {
        return get(MetricEvent.OCCUPIED_PASS);
    }

    public long block() {
        return get(MetricEvent.BLOCK);
    }

    public long exception() {
        return get(MetricEvent.EXCEPTION);
    }

    public long rt() {
        return get(MetricEvent.RT);
    }

    public long minRt() {
        return minRt;
    }

    public long success() {
        return get(MetricEvent.SUCCESS);
    }

    public void addPass(int n) {
        add(MetricEvent.PASS, n); // 向PASS维度中增加统计数据
    }

    public void addOccupiedPass(int n) {
        add(MetricEvent.OCCUPIED_PASS, n);
    }

    public void addException(int n) {
        add(MetricEvent.EXCEPTION, n);
    }

    public void addBlock(int n) {
        add(MetricEvent.BLOCK, n);
    }

    public void addSuccess(int n) {
        add(MetricEvent.SUCCESS, n);
    }

    public void addRT(long rt) {
        add(MetricEvent.RT, rt);

        // Not thread-safe, but it's okay.
        if (rt < minRt) {
            minRt = rt;
        }
    }

    @Override
    public String toString() {
        return "p: " + pass() + ", b: " + block() + ", w: " + occupiedPass();
    }
}
```

看到这里是不是就放心了，原来 `MetricBucket` 是通过 `LongAdder` 来保存各种指标的值的，看到 `LongAdder` 是不是立刻就想到 `AtomicLong` 了？但是这里为什么不用 `AtomicLong` ，而是用 `LongAdder` 呢？主要是 `LongAdder` 在高并发下有更好的吞吐量，代价是花费了更多的空间，典型的以空间换时间。

### 完整的流程

分析到这里我们已经把指标统计的完整链路理清楚了，可以用下面这张图来表示整个过程：

<img src="http://blog-1259650185.cosbj.myqcloud.com/img/202111/28/1638030249" alt="图片" style="zoom:50%;" />

这里的 `timeId` 是用来表示一个 `WindowWrap`对象的时间id。为什么要用 `timeId` 来表示呢？我们可以看到每一个 `WindowWrap` 对象由三个部分组成：

- **windowStart:** 时间窗口的开始时间，单位是毫秒
- **windowLength:** 时间窗口的长度，单位是毫秒
- **value:** 时间窗口的内容，在 `WindowWrap` 中是用泛型表示这个值的，但实际上就是 `MetricBucket` 类

我们先大致的了解下时间窗口的构成，后面会再来分析 **timeId** 的作用。首先一个时间窗口是用来在某个固定时间长度内保存一些统计值的虚拟概念。有了这个概念后，我们就可以通过时间窗口来计算统计一段时间内的诸如：qps，rt，threadNum等指标了。

### 继续深入

我们再回到 `ArrayMetric` 中看一下：

```java
// ArrayMetric.java
public class ArrayMetric implements Metric {
    // 数据就保存在这个数据结构中
    private final LeapArray<MetricBucket> data;

    public ArrayMetric(int sampleCount, int intervalInMs) {
        this.data = new OccupiableBucketLeapArray(sampleCount, intervalInMs);
    }
  
  	public ArrayMetric(int sampleCount, int intervalInMs, boolean enableOccupy) {
        if (enableOccupy) {
            this.data = new OccupiableBucketLeapArray(sampleCount, intervalInMs);
        } else {
            this.data = new BucketLeapArray(sampleCount, intervalInMs);
        }
    }
}
```

首先创建了一个 `BucketLeapArray` 对象，看一下 `BucketLeapArray` 类的代码：

```java
// BucketLeapArray.java
public class BucketLeapArray extends LeapArray<MetricBucket> {

    public BucketLeapArray(int sampleCount, int intervalInMs) {
        super(sampleCount, intervalInMs);
    }
}
```

该对象的构造方法有两个参数：

- `intervalInMs` ：一个用毫秒做单位的时间窗口的长度
- `sampleCount` ，样本窗口数量，默认为2个

然后 `BucketLeapArray` 继承自 `LeapArray` ，在初始化 `BucketLeapArray` 的时候，直接调用了父类的构造方法，再来看一下父类 `LeapArray` 的代码：

```java
// LeapArray.java
public abstract class LeapArray<T> {
    // 样本窗口长度
    protected int windowLengthInMs;
    protected int sampleCount; // 一个时间窗中包含的样本窗口数量
    protected int intervalInMs; // 时间窗口长度
    private double intervalInSecond; // 时间窗口长度
    // 这是一个数组，元素为WindowWrap样本窗口，泛型T为MetricBucket等类型
    protected final AtomicReferenceArray<WindowWrap<T>> array;

    private final ReentrantLock updateLock = new ReentrantLock();

    public LeapArray(int sampleCount, int intervalInMs) {
        AssertUtil.isTrue(sampleCount > 0, "bucket count is invalid: " + sampleCount);
        AssertUtil.isTrue(intervalInMs > 0, "total time interval of the sliding window should be positive");
        AssertUtil.isTrue(intervalInMs % sampleCount == 0, "time span needs to be evenly divided");

        this.windowLengthInMs = intervalInMs / sampleCount;
        this.intervalInMs = intervalInMs;
        this.intervalInSecond = intervalInMs / 1000.0;
        this.sampleCount = sampleCount;

        this.array = new AtomicReferenceArray<>(sampleCount);
    }
}
```

可以很清晰的看出来在 `LeapArray` 中创建了一个 `AtomicReferenceArray` 数组，用来对时间窗口中的统计值进行采样。通过采样的统计值再计算出平均值，就是我们需要的最终的实时指标的值了。

可以看到我在上面的代码中通过注释，标明了默认采样的时间窗口的个数是2个，这个值是怎么得到的呢？我们回忆一下 `LeapArray` 对象创建，是通过在 `StatisticNode` 中，new了一个 `ArrayMetric` ，然后将参数一路往上传递后创建的：

```java
private transient volatile Metric rollingCounterInSecond = new ArrayMetric(SampleCountProperty.SAMPLE_COUNT,
    IntervalProperty.INTERVAL);
```

`SampleCountProperty.SAMPLE_COUNT` 的默认值是2，所以第一个参数 `IntervalProperty.INTERVAL` 的值是1000ms，每个时间窗口的长度是500ms，也就是说总共分了两个采样的时间窗口。

现在继续回到 `ArrayMetric.addPass()` 方法：

```java
// ArrayMetric.java
@Override
public void addPass(int count) {
    WindowWrap<MetricBucket> wrap = data.currentWindow(); // 获取当前时间点所在的样本窗口
    wrap.value().addPass(count); // 将当前请求的计数量添加到当前样本窗口的统计数据中
}
```

#### 获取当前Window

我们已经分析了 `wrap.value().addPass()` ，现在只需要分析清楚 `data.currentWindow()`具体做了什么，拿到了当前时间窗口就可以 了。继续深入代码，最终定位到下面的代码：

```java
// LeapArray.java
public WindowWrap<T> currentWindow() {
    return currentWindow(TimeUtil.currentTimeMillis()); // 获取当前时间点所在的样本窗口
}

public WindowWrap<T> currentWindow(long timeMillis) {
    if (timeMillis < 0) {
        return null;
    }
    // 计算当前时间点所在的样本窗口id，即计算在数组LeapArray中的索引
    int idx = calculateTimeIdx(timeMillis);
    // Calculate current bucket start time. 计算当前样本窗口的开始时间点
    long windowStart = calculateWindowStart(timeMillis);

    /*
     * Get bucket item at given time from the array.
     *
     * (1) Bucket is absent, then just create a new bucket and CAS update to circular array.
     * (2) Bucket is up-to-date, then just return the bucket.
     * (3) Bucket is deprecated, then reset current bucket and clean all deprecated buckets.
     */
    while (true) {
        WindowWrap<T> old = array.get(idx); // 获取当前时间点所在的样本窗口
        if (old == null) { // 若当前时间点所在样本窗口为null，说明该样本窗口还不存在，则创建一个样本时间窗
   				// 创建一个样本时间窗
            WindowWrap<T> window = new WindowWrap<T>(windowLengthInMs, windowStart, newEmptyBucket(timeMillis));
            if (array.compareAndSet(idx, null, window)) { // 通过CAS的方式将新建窗口放入到array
                // Successfully updated, return the created bucket.
                return window;
            } else {
                // Contention failed, the thread will yield its time slice to wait for bucket available.
                Thread.yield();
            }
        } else if (windowStart == old.windowStart()) { // 当前样本窗口的其实时间点与计算出的样本窗口时间点相同，则说明这两个是同一个样本窗口
            return old;
        } else if (windowStart > old.windowStart()) { // 若当前样本窗口的其实时间点 大于 计算出的样本窗口时间点，说明原来的样本窗口已经过时了，需要将原来的样本窗口替换
            if (updateLock.tryLock()) {
                try {
                    // Successfully get the update lock, now we reset the bucket. 替换老的样本时间窗口
                    return resetWindowTo(old, windowStart);
                } finally {
                    updateLock.unlock();
                }
            } else {
                Thread.yield();
            }
        } else if (windowStart < old.windowStart()) { // 当前样本窗口的其实时间点 小于 计算出的样本窗口时间点，这种情况一般不会出现，除非人为修改了系统时钟
            return new WindowWrap<T>(windowLengthInMs, windowStart, newEmptyBucket(timeMillis));
        }
    }
}

private int calculateTimeIdx(/*@Valid*/ long timeMillis) {
    long timeId = timeMillis / windowLengthInMs; // 计算出当前时间点在哪个样本窗口
    return (int)(timeId % array.length());
}

protected long calculateWindowStart(/*@Valid*/ long timeMillis) {
    return timeMillis - timeMillis % windowLengthInMs;
}
```

初次看到这段代码时，可能会觉得有点懵，但是细细的分析一下，实际可以把他分成以下几步：

1. 根据当前时间，算出该时间的timeId，并根据timeId算出当前窗口在采样窗口数组中的索引idx
2. 根据当前时间算出当前窗口的应该对应的开始时间time，以毫秒为单位
3. 根据索引idx，在采样窗口数组中取得一个时间窗口old
4. 循环判断直到获取到一个当前时间窗口
   - 4.1 如果old为空，则创建一个时间窗口，并将它插入到array的第idx个位置，array上面已经分析过了，是一个 `AtomicReferenceArray`
   - 4.2 如果当前窗口的开始时间time与old的开始时间相等，那么说明old就是当前时间窗口，直接返回old
   - 4.3 如果当前窗口的开始时间time大于old的开始时间，则说明old窗口已经过时了，将old的开始时间更新为最新值：time，下个循环中会在步骤4.2中返回
   - 4.4 如果当前窗口的开始时间time小于old的开始时间，实际上这种情况是不可能存在的，因为time是当前时间，old是过去的一个时间

timeId是会随着时间的增长而增加，当前时间每增长一个windowLength的长度，timeId就加1。但是idx不会增长，只会在0和1之间变换，因为array数组的长度是2，只有两个采样时间窗口。至于为什么默认只有两个采样窗口，个人觉得因为sentinel是比较轻量的框架。时间窗口中保存着很多统计数据，如果时间窗口过多的话，一方面会占用过多内存，另一方面时间窗口过多就意味着时间窗口的长度会变小，如果时间窗口长度变小，就会导致时间窗口过于频繁的滑动。

### 看图理解

为了更好的理解，下面我用几幅图来描述下这个过程。

<img src="http://blog-1259650185.cosbj.myqcloud.com/img/202111/28/1638032907" alt="图片" style="zoom:50%;" />

初始的时候arrays数组中只有一个窗口(可能是第一个，也可能是第二个)，每个时间窗口的长度是500ms，这就意味着只要当前时间与时间窗口的差值在500ms之内，时间窗口就不会向前滑动。例如，假如当前时间走到300或者500时，当前时间窗口仍然是相同的那个：

<img src="http://blog-1259650185.cosbj.myqcloud.com/img/202111/28/1638032933" alt="图片" style="zoom:50%;" />

时间继续往前走，当超过500ms时，时间窗口就会向前滑动到下一个，这时就会更新当前窗口的开始时间：

<img src="http://blog-1259650185.cosbj.myqcloud.com/img/202111/28/1638032950" alt="图片" style="zoom:50%;" />

时间继续往前走，只要不超过1000ms，则当前窗口不会发生变化：

<img src="http://blog-1259650185.cosbj.myqcloud.com/img/202111/28/1638032984" alt="图片" style="zoom:50%;" />

当时间继续往前走，当前时间超过1000ms时，就会再次进入下一个时间窗口，此时arrays数组中的窗口将会有一个失效，会有另一个新的窗口进行替换：

<img src="http://blog-1259650185.cosbj.myqcloud.com/img/202111/28/1638033002" alt="图片" style="zoom:50%;" />

以此类推随着时间的流逝，时间窗口也在发生变化，在当前时间点中进入的请求，会被统计到当前时间对应的时间窗口中。计算qps时，会用当前采样的时间窗口中对应的指标统计值除以时间间隔，就是具体的qps。具体的代码在StatisticNode中：

```java
// StatisticNode.java
@Override
public double totalQps() {
    return passQps() + blockQps();
}

@Override
public double passQps() { // rollingCounterInSecond.pass() 当前时间窗口中统计的通过的请求数量；rollingCounterInSecond.getWindowIntervalInSec() 时间窗口长度
    return rollingCounterInSecond.pass() / rollingCounterInSecond.getWindowIntervalInSec(); // 计算出的就是QPS
}

@Override
public double blockQps() {
    return rollingCounterInSecond.block() / rollingCounterInSecond.getWindowIntervalInSec();
}

// ArrayMetric.java
@Override
public long pass() {
    data.currentWindow(); // 更新当前样本窗口为最新的数据
    long pass = 0;
    List<MetricBucket> list = data.values(); // 当前时间窗口中所有的样本窗口统计的value记录到pass中
    // 将list中所有的pass维度的统计数据取出并求和
    for (MetricBucket window : list) {
        pass += window.pass();
    }
    return pass;
}

@Override
public double getWindowIntervalInSec() {
    return data.getIntervalInSecond();
}
```

到这里就基本上把滑动窗口的原理分析清楚了，还有不清楚的地方，最好能够借助代码继续分析下，最好的做法就是debug，这里贴一下笔者在分析 `currentWindow` 方法时采取的测试代码：

```java
public static void main(String[] args) throws InterruptedException {

    int windowLength = 500;
    int arrayLength = 2;

    calculate(windowLength, arrayLength);
    
    Thread.sleep(100);

    calculate(windowLength, arrayLength);

    Thread.sleep(200);

    calculate(windowLength, arrayLength);

    Thread.sleep(200);

    calculate(windowLength, arrayLength);

    Thread.sleep(500);

    calculate(windowLength, arrayLength);
    
    Thread.sleep(500);

    calculate(windowLength, arrayLength);

    Thread.sleep(500);

    calculate(windowLength, arrayLength);
    
    Thread.sleep(500);

    calculate(windowLength, arrayLength);

    Thread.sleep(500);

    calculate(windowLength, arrayLength);

}

private static void calculate(int windowLength, int arrayLength) {

    long time = System.currentTimeMillis();

    long timeId = time / windowLength;

    long currentWindowStart = time - time % windowLength;

    int idx = (int) (timeId % arrayLength);

    System.out.println("time=" + time + ",currentWindowStart=" + currentWindowStart + ",timeId=" + timeId + ",idx=" + idx);

}
```

这里假设时间窗口的长度为500ms，数组的大小为2，当前时间作为输入参数，计算出当前时间窗口的timeId、windowStart、idx等值。执行上面的代码后，将打印出如下的结果：

```java
time=1638033645542,currentWindowStart=1638033645500,timeId=3276067291,idx=1
time=1638033645644,currentWindowStart=1638033645500,timeId=3276067291,idx=1
time=1638033645845,currentWindowStart=1638033645500,timeId=3276067291,idx=1
time=1638033646048,currentWindowStart=1638033646000,timeId=3276067292,idx=0
time=1638033646550,currentWindowStart=1638033646500,timeId=3276067293,idx=1
time=1638033647055,currentWindowStart=1638033647000,timeId=3276067294,idx=0
time=1638033647556,currentWindowStart=1638033647500,timeId=3276067295,idx=1
time=1638033648061,currentWindowStart=1638033648000,timeId=3276067296,idx=0
time=1638033648564,currentWindowStart=1638033648500,timeId=3276067297,idx=1
```

可以看出来，windowStart每增加500ms，timeId就加1，这时就是时间窗口发生滑动的时候。

## 3.4 使用统计数据

<img src="http://blog-1259650185.cosbj.myqcloud.com/img/202111/24/1637721058.png" alt="Sentinel滑动时间窗算法源码解析—使用统计数据" style="zoom:50%;" />



# 4. 如何为系统设置扩展点

一个好的框架有一个很重要的特性就是扩展性要好，不能把系统写死，后期想要新增功能时，可以通过预留的扩展点进行扩展，而不是去修改原来的代码。

本篇文章我就来跟大家分享下 Sentinel 在扩展性这块是怎么做的，都有哪些扩展点。

## 4.1 模块设计

第一点从模块设计上，Sentinel 就充分考虑了扩展性，Sentinel 核心的功能其实就在 sentinel-core 模块中，要想在自己的系统中使用 Sentinel 最少只需要引入这一个依赖就够了。其他的都是为了框架的易用性和高可用性等做的扩展。

我们来看下 Sentinel 中都有哪些扩展的模块：

- sentinel-dashboard：一个通过 spring boot 实现的 web 应用，相当于是 Sentinel 的 OPS 工具，通过 dashboard 我们可以更方便的对规则进行调整、查询实时统计信息等，但是这并不是必须的，没有 dashboard 我们也能使用 Sentinel，甚至我们可以通过 Sentinel 提供的 api 来实现自己的 dashboard。
- sentinel-transport：一个 sentinel-core 和 sentinel-dashboard 通讯的桥梁，如果我们的应用接入了 Sentinel，并且也想通过 dashboard 来管理的话，那就需要引入 sentinel-transport 模块。
- sentinel-extension：一个 Sentinel 的扩展模块，主要是实现了规则的动态更新和持久化。另外热点参数限流也在这里实现的，除此之外注解的相关实现也是在这个模块中。
- sentinel-adapter：一个适配器的扩展，通过适配器可以很方便的为其他框架进行 Sentinel 的集成。
- sentinel-cluster：集群限流的扩展，通过引入这个模块可以在集群环境中使用 Sentinel。

除了 sentinel-core 之外，其他的模块基本上都是围绕着 sentinel-core 做了一些扩展，而且各个模块之间没有强耦合，是可插拔的，以下这张图可以简单的描述这个关系：

<img src="https://mmbiz.qpic.cn/mmbiz_png/GtXvavW2UlxaWVysqktQM9M6jwEF6IEFKlrmhhpHw6JUuNb391ic3CwhpzaFCfJElhRQ7P0psuw0ASI9CMhDpOg/640?wx_fmt=png&tp=webp&wxfrom=5&wx_lazy=1&wx_co=1" alt="图片" style="zoom:50%;" />

## 4.2 系统初始化

Sentinel 为我们提供了一个 InitFunc 接口来做系统的初始化工作，如果我们想要实现在系统初始化时就执行的逻辑，可以实现 InitFunc 接口。

目前 Sentinel 中有一些实现了 InitFunc 的类：

<img src="http://blog-1259650185.cosbj.myqcloud.com/img/202111/29/1638162523.png" alt="image-20211129130843483" style="zoom: 33%;" />



主要实现了以下这些系统初始化的工作：

- CommandCenter 的初始化
- HeartBeat 的初始化与心跳发送
- 集群服务端和客户端的初始化
- 热点限流中 StatisticSlot 回调的初始化

并且我们我们可以通过 @InitOrder 注解来指定 InitFunc 执行的顺序，order 的值越小越先执行。

InitFunc 是在首次调用 SphU.entry(KEY) 方法时触发的，注册的初始化函数会依次执行。

如果你不想把初始化的工作延后到第一次调用时触发，可以手动调用 InitExecutor.doInit() 函数，重复调用只会执行一次。

## 4.3 规则持久化

限流降级的规则，是通过调用 loadRules 方法加载进内存中的，而实际使用中，我们必须要对规则进行持久化，因为不进行持久化的话规则将会在系统重启时丢失。

那么 Sentinel 是如何做到，在扩展了动态规则加载的方法时，又不影响原先正常的规则加载的呢？我们看一下 FlowRuleManager 的 loadRules 方式就知道了：

```java
private static SentinelProperty<List<FlowRule>> currentProperty = new DynamicSentinelProperty<>();

public static void loadRules(List<FlowRule> rules) {
    currentProperty.updateValue(rules);
}
```

实际上是通过 DynamicSentinelProperty 的 updateValue 方法来动态更新规则的。

那么我们只需要在持久化的规则发生变更时，通过触发 SentinelProperty 的 updateValue 方法把更新后的规则注入进去就可以了。目前 SentinelProperty 有默认的实现，这一块我们不需要进行扩展，我们只需要实现监听每种持久化的数据源在发生数据变更时的事件，当接收到最新的数据时将它 update 进 FlowRuleManager 中即可。

所以我们需要抽象出读数据源和写数据源的两个接口：

- ReadableDataSource：读数据源负责监听持久化的数据源的变更，在接收到变更事件时将最新的数据更新
- WritableDataSource：写数据源负责将变更后的规则写入到持久化的数据源中

目前系统中只有一种文件数据源实现了 WritableDataSource 接口，其他的数据源只实现了 ReadableDataSource 接口。

<img src="https://mmbiz.qpic.cn/mmbiz_png/GtXvavW2UlxaWVysqktQM9M6jwEF6IEFC1munDX7CcibL9GXdu6WxhwRibc6zYficamCB5mYGx38v1XL5LYhQFlFA/640?wx_fmt=png&tp=webp&wxfrom=5&wx_lazy=1&wx_co=1" alt="图片" style="zoom:50%;" />

## 4.4 网络通讯

sentinel-transport 模块中的功能基本上都是网络通讯相关的，而我们有很多的网络协议：http、tcp等，所以网络通讯这块肯定也要有可扩展的能力。目前 sentinel-transport-common 模块中抽象了3个接口作为扩展点：

- CommandCenter：该接口主要用来在 sentinel-core 中启动一个可以对外提供 api 接口的服务端，Sentinel 中默认有两个实现，分别是 http 和 netty。但是官方默认推荐的是使用 http 的实现。
- CommandHandler：该接口主要是用来处理接收到的请求的，不同的请求有不同的 handler 类来进行处理，我们可以实现我们自己的 CommandHandler 并注册到 SPI 配置文件中来为 CommandCenter 添加自定义的命令。
- HeartbeatSender：该接口主要是为 sentinel-core 用来向 sentinel-dashboard 发送心跳的，默认也有两个实现，分别是 http 和 netty。

<img src="https://mmbiz.qpic.cn/mmbiz_png/GtXvavW2UlxaWVysqktQM9M6jwEF6IEFkZAvBWT8vqInBhKug3bHyaemWuOrL7ekvJicXjBZVlafFRSZOXe6VjA/640?wx_fmt=png&tp=webp&wxfrom=5&wx_lazy=1&wx_co=1" alt="图片" style="zoom:50%;" />

## 4.5 Slot链

Sentinel 内部是通过一系列的 slot 组成的 slot chain 来完成各种功能的，包括构建调用链、调用数据统计、规则检查等，各个 slot 之间的顺序非常重要。

Sentinel 将 SlotChainBuilder 作为 SPI 接口进行扩展，使得 Slot Chain 具备了扩展的能力。我们可以自行加入自定义的 slot 并编排 slot 间的顺序，从而可以给 Sentinel 添加自定义的功能。

## 4.6 StatisticSlot回调

之前 StatisticSlot 里面包含了太多的逻辑，像普通 qps 和 热点参数 qps 的 addPass/addBlock 等逻辑统计都在 StatisticSlot 里面，各个逻辑都杂糅在一起，不利于扩展。

因此有必要为 StatisticSlot 抽象出一系列的 callback，从而使 StatisticSlot 具备基本的扩展能力，并将一系列的逻辑从 StatisticSlot 解耦出来，目前 Sentinel 提供了两种 callback：

- ProcessorSlotEntryCallback：包含 onPass 和 onBlocked 两个回调函数，分别对应着请求在 pass 和 blocked 的时候执行。
- ProcessorSlotExitCallback：包含 onExit 回调函数，对应着请求在 exit 的时候执行。

只需将实现的 callback 注册到 StatisticSlotCallbackRegistry 即可生效。



# 5. 控制台是如何获取到实时数据的

Sentinel 能够被大家所认可，除了他自身的轻量级，高性能，可扩展之外，跟控制台的好用和易用也有着莫大的关系，因为通过控制台极大的方便了我们日常的运维工作。

我们可以在控制台上操作各种限流、降级、系统保护的规则，也可以查看每个资源的实时数据，还能管理集群环境下的服务端与客户端机器。

但是控制台只是一个独立的 spring boot 应用，他本身是没有任何数据的，他的数据都是从其他的 sentinel 实例中获取的，那他是如何获取到这些数据的呢？带着这个疑问我们从源码中寻找答案。

我们就以一个简单的查看【流控规则】为例来描述，点击【流控规则】进入页面后，按F11打开network就可以看到请求的url了。

可以看到，请求的 url 是 /v1/flow/rules 我们直接在源码中全局搜索 /rules ，为什么不搜索 /v1/flow/rules 呢，因为有可能 url 被拆分成两部分，我们直接搜完整的 url 可能搜不到结果。

我们要找的应该就是 FlowControllerV1 这个类了，打开这个类看下类上修饰的值是不是 /v1/flow 。

dashboard 是通过一个叫 SentinelApiClient 的类去指定的 ip 和 port 处获取数据的。这个 ip 和 port 是前端页面直接提交给后端的，而前端页面又是通过 /app/{app}/machines.json 接口获取机器列表的。

## 5.1 连接 dashboard

这里的机器列表中展示的就是所有连接到 dashboard 上的 sentinel 的实例，包括普通限流的 sentinel-core 和集群模式下的 token-server 和 token-client。我们可以回想一下，一个 sentinel-core 的实例要接入 dashboard 的几个步骤：

1. 引入 dashboard 的依赖
2. 配置 dashboard 的 ip 和 port
3. 初始化 sentinel-core，连接 dashboard

sentinel-core 在初始化的时候，通过 JVM 参数中指定的 dashboard 的 ip 和 port，会主动向 dashboard 发起连接的请求，该请求是通过 HeartbeatSender 接口以心跳的方式发送的，并将自己的 ip 和 port 告知 dashboard。这里 sentinel-core 上报给 dashboard 的端口是 sentinel 对外暴露的自己的 CommandCenter 的端口。

HeartbeatSender 有两个实现类，一个是通过 http，另一个是通过 netty，我们看 http 的实现类：

```java
public class SimpleHttpHeartbeatSender implements HeartbeatSender {

    private static final int OK_STATUS = 200;

    private static final long DEFAULT_INTERVAL = 1000 * 10;

    private final HeartbeatMessage heartBeat = new HeartbeatMessage();
    private final SimpleHttpClient httpClient = new SimpleHttpClient();

    private final List<Endpoint> addressList;

    private int currentAddressIdx = 0;

    public SimpleHttpHeartbeatSender() {
        // Retrieve the list of default addresses.
        List<Endpoint> newAddrs = TransportConfig.getConsoleServerList();
				...
        this.addressList = newAddrs;
    }

    @Override
    public boolean sendHeartbeat() throws Exception {
        if (TransportConfig.getRuntimePort() <= 0) {
            RecordLog.info("[SimpleHttpHeartbeatSender] Command server port not initialized, won't send heartbeat");
            return false;
        }
        Endpoint addrInfo = getAvailableAddress();
        if (addrInfo == null) {
            return false;
        }

        SimpleHttpRequest request = new SimpleHttpRequest(addrInfo, TransportConfig.getHeartbeatApiPath());
        request.setParams(heartBeat.generateCurrentMessage());
        try {
            SimpleHttpResponse response = httpClient.post(request);
            if (response.getStatusCode() == OK_STATUS) {
                return true;
            } else if (clientErrorCode(response.getStatusCode()) || serverErrorCode(response.getStatusCode())) {
                RecordLog.warn("[SimpleHttpHeartbeatSender] Failed to send heartbeat to " + addrInfo
                    + ", http status code: " + response.getStatusCode());
            }
        } catch (Exception e) {
            RecordLog.warn("[SimpleHttpHeartbeatSender] Failed to send heartbeat to " + addrInfo, e);
        }
        return false;
    }

    @Override
    public long intervalMs() {
        return DEFAULT_INTERVAL;
    }

    private Endpoint getAvailableAddress() {
        if (addressList == null || addressList.isEmpty()) {
            return null;
        }
        if (currentAddressIdx < 0) {
            currentAddressIdx = 0;
        }
        int index = currentAddressIdx % addressList.size();
        return addressList.get(index);
    }

    private boolean clientErrorCode(int code) {
        return code > 399 && code < 500;
    }

    private boolean serverErrorCode(int code) {
        return code > 499 && code < 600;
    }
}
```

通过一个 HttpClient 向 dashboard 发送了自己的信息，包括 ip port 和版本号等信息。

其中 consoleHost 和 consolePort 的值就是从 JVM 参数 csp.sentinel.dashboard.server 中获取的。

dashboard 在接收到 sentinel-core 的连接之后，就会与 sentinel-core 建立连接，并将 sentinel-core 上报的 ip 和 port 的信息包装成一个 MachineInfo 对象，然后通过 SimpleMachineDiscovery 将该对象保存在一个 map 中，如下图所示：

<img src="https://mmbiz.qpic.cn/mmbiz_png/GtXvavW2Ulz5leWOh63PWH2OxiblT3XpmbyYSPqEIBqdWaOl29RViaZJFbXVCh5usiaKLQO1YxsUxXDNqGMibkB6qQ/640?wx_fmt=png&tp=webp&wxfrom=5&wx_lazy=1&wx_co=1" alt="图片" style="zoom:50%;" />

## 5.2 定时发送心跳

sentinel-core 连接上 dashboard 之后，并不是就结束了，事实上 sentinel-core 是通过一个 ScheduledExecutorService 的定时任务，每隔 10 秒钟向 dashboard 发送一次心跳信息。发送心跳的目的主要是告诉 dashboard 我这台 sentinel 的实例还活着，你可以继续向我请求数据。

这也就是为什么 dashboard 中每个 app 对应的机器列表要用 Set 来保存的原因，如果用 List 来保存的话就可能存在同一台机器保存了多次的情况。

心跳可以维持双方之间的连接是正常的，但是也有可能因为各种原因，某一方或者双方都离线了，那他们之间的连接就丢失了。

### 5.2.1 sentinel-core 宕机

如果是 sentinel-core 宕机了，那么这时 dashboard 中保存在内存里面的机器列表还是存在的。目前 dashboard 只是在接收到 sentinel-core 发送过来的心跳包的时候更新一次机器列表，当 sentinel-core 宕机了，不再发送心跳数据的时候，dashboard 是没有将 “失联” 的 sentinel-core 实例给去除的。而是页面上每次查询的时候，会去用当前时间减去机器上次心跳包的时间，如果时间差大于 5 分钟了，才会将该机器标记为 “失联”。

所以我们在页面上的机器列表中，需要至少等到 5 分钟之后，才会将具体失联的 sentinel-core 的机器标记为 “失联”。如下图所示：

<img src="https://mmbiz.qpic.cn/mmbiz_png/GtXvavW2Ulz5leWOh63PWH2OxiblT3XpmP7icd4JzvParCu7F2RkOlyvcflINJJmWQOoBbsAkicZhwibT2mqSAR2dA/640?wx_fmt=png&tp=webp&wxfrom=5&wx_lazy=1&wx_co=1" alt="图片" style="zoom:50%;" />



### 5.2.2 dashboard 宕机

如果 dashboard 宕机了，sentinel-core 的定时任务实际上是会一直请求下去的，只要 dashboard 恢复后就会自动重新连接上 dashboard，双方之间的连接又会恢复正常了，如果 dashboard 一直不恢复，那么 sentinel-core 就会一直报错，在 sentinel-record.log 中我们会看到如下的报错信息：

<img src="https://mmbiz.qpic.cn/mmbiz_png/GtXvavW2Ulz5leWOh63PWH2OxiblT3XpmTzWZwgvYz2luLZ81cAS9q2uWuEJkg2cqicBUNOHOBvHYcZDicdsa9O5g/640?wx_fmt=png&tp=webp&wxfrom=5&wx_lazy=1&wx_co=1" alt="图片" style="zoom:50%;" />

不过实际生产中，不可能出现 dashboard 宕机了一直没人去恢复的情况的，如果真出现这种情况的话，那就要吃故障了。

## 5.3 请求数据

当 dashboard 有了具体的 sentinel-core 实例的 ip 和 port 之后，就可以去请求所需要的数据了。

让我们再回到最开始的地方，我在页面上查询某一台机器的限流的规则时，是将该机器的 ip 和 port 以及 appName 都传给了服务端，服务端通过这些信息去具体的远程实例中请求所需的数据，拿到数据后再封装成 dashboard 所需的格式返回给前端页面进行展示。

具体请求限流规则列表的代码在 SentinelApiClient 中，如下所示：

```java
// SentinelApiClient.java
public List<FlowRuleEntity> fetchFlowRuleOfMachine(String app, String ip, int port) {
    List<FlowRule> rules = fetchRules(ip, port, FLOW_RULE_TYPE, FlowRule.class);
    if (rules != null) {
        return rules.stream().map(rule -> FlowRuleEntity.fromFlowRule(app, ip, port, rule))
            .collect(Collectors.toList());
    } else {
        return null;
    }
}

private <T extends Rule> List<T> fetchRules(String ip, int port, String type, Class<T> ruleType) {
    return fetchItems(ip, port, GET_RULES_PATH, type, ruleType);
}

@Nullable
private <T> List<T> fetchItems(String ip, int port, String api, String type, Class<T> ruleType) {
    try {
        AssertUtil.notEmpty(ip, "Bad machine IP");
        AssertUtil.isTrue(port > 0, "Bad machine port");
        Map<String, String> params = null;
        if (StringUtil.isNotEmpty(type)) {
            params = new HashMap<>(1);
            params.put("type", type);
        }
        return fetchItemsAsync(ip, port, api, type, ruleType).get();
    } catch (InterruptedException | ExecutionException e) {
        logger.error("Error when fetching items from api: {} -> {}", api, type, e);
        return null;
    } catch (Exception e) {
        logger.error("Error when fetching items: {} -> {}", api, type, e);
        return null;
    }
}

@Nullable
private <T> CompletableFuture<List<T>> fetchItemsAsync(String ip, int port, String api, String type, Class<T> ruleType) {
    AssertUtil.notEmpty(ip, "Bad machine IP");
    AssertUtil.isTrue(port > 0, "Bad machine port");
    Map<String, String> params = null;
    if (StringUtil.isNotEmpty(type)) {
        params = new HashMap<>(1);
        params.put("type", type);
    }
    return executeCommand(ip, port, api, params, false)
            .thenApply(json -> JSON.parseArray(json, ruleType));
}

private CompletableFuture<String> executeCommand(String ip, int port, String api, Map<String, String> params, boolean useHttpPost) {
    return executeCommand(null, ip, port, api, params, useHttpPost);
}

private CompletableFuture<String> executeCommand(String app, String ip, int port, String api, Map<String, String> params, boolean useHttpPost) {
    CompletableFuture<String> future = new CompletableFuture<>();
    if (StringUtil.isBlank(ip) || StringUtil.isBlank(api)) {
        future.completeExceptionally(new IllegalArgumentException("Bad URL or command name"));
        return future;
    }
    StringBuilder urlBuilder = new StringBuilder();
    urlBuilder.append("http://");
    urlBuilder.append(ip).append(':').append(port).append('/').append(api);
    if (params == null) {
        params = Collections.emptyMap();
    }
    if (!useHttpPost || !isSupportPost(app, ip, port)) {
        // Using GET in older versions, append parameters after url
        if (!params.isEmpty()) {
            if (urlBuilder.indexOf("?") == -1) {
                urlBuilder.append('?');
            } else {
                urlBuilder.append('&');
            }
            urlBuilder.append(queryString(params));
        }
        return executeCommand(new HttpGet(urlBuilder.toString()));
    } else {
        // Using POST
        return executeCommand(
                postRequest(urlBuilder.toString(), params, isSupportEnhancedContentType(app, ip, port)));
    }
}

private CompletableFuture<String> executeCommand(HttpUriRequest request) {
    CompletableFuture<String> future = new CompletableFuture<>();
    httpClient.execute(request, new FutureCallback<HttpResponse>() {
        @Override
        public void completed(final HttpResponse response) {
            int statusCode = response.getStatusLine().getStatusCode();
            try {
                String value = getBody(response);
                if (isSuccess(statusCode)) {
                    future.complete(value);
                } else {
                    if (isCommandNotFound(statusCode, value)) {
                        future.completeExceptionally(new CommandNotFoundException(request.getURI().getPath()));
                    } else {
                        future.completeExceptionally(new CommandFailedException(value));
                    }
                }

            } catch (Exception ex) {
                future.completeExceptionally(ex);
                logger.error("HTTP request failed: {}", request.getURI().toString(), ex);
            }
        }

        @Override
        public void failed(final Exception ex) {
            future.completeExceptionally(ex);
            logger.error("HTTP request failed: {}", request.getURI().toString(), ex);
        }

        @Override
        public void cancelled() {
            future.complete(null);
        }
    });
    return future;
}
```

可以看到也是通过一个 httpClient 请求的数据，然后再对结果进行转换。

获取数据的请求从 dashboard 中发出去了，那 sentinel-core 中是怎么进行相应处理的呢？看过我其他文章的同学肯定还记得， sentinel-core 在启动的时候，执行了一个 InitExecutor.init 的方法，该方法会触发所有 InitFunc 实现类的 init 方法，其中就包括两个最重要的实现类：

- HeartbeatSenderInitFunc
- CommandCenterInitFunc

HeartbeatSenderInitFunc 会启动一个 HeartbeatSender 来定时的向 dashboard 发送自己的心跳包。

而 **CommandCenterInitFunc 则会启动一个 CommandCenter 对外提供 sentinel-core 的数据服务**，而这些数据服务是通过一个一个的 CommandHandler 来提供的。

```java
public class CommandCenterInitFunc implements InitFunc {

    @Override
    public void init() throws Exception {
        CommandCenter commandCenter = CommandCenterProvider.getCommandCenter();

        if (commandCenter == null) {
            RecordLog.warn("[CommandCenterInitFunc] Cannot resolve CommandCenter");
            return;
        }

        commandCenter.beforeStart();
        commandCenter.start();
        RecordLog.info("[CommandCenterInit] Starting command center: "
                + commandCenter.getClass().getCanonicalName());
    }
}
```

如下图所示：

<img src="https://mmbiz.qpic.cn/mmbiz_png/GtXvavW2Ulz5leWOh63PWH2OxiblT3XpmGkPNQGjp7HjrxxRNy1M9lxPLd9QyUBwfxQa9Uxc662OnRasfzbLl5w/640?wx_fmt=png&tp=webp&wxfrom=5&wx_lazy=1&wx_co=1" alt="图片" style="zoom:50%;" />

## 5.4 总结

现在我们已经知道了 dashboard 是如何获取到实时数据的了，具体的流程如下所示：

1. 首先 sentinel-core 向 dashboard 发送心跳包
2. dashboard 将 sentinel-core 的机器信息保存在内存中
3. dashboard 根据 sentinel-core 的机器信息通过 httpClient 获取实时的数据
4. sentinel-core 接收到请求之后，会找到具体的 CommandHandler 来处理
5. sentinel-core 将处理好的结果返回给 dashboard

## 5.5 思考

### 5.5.1 数据安全性

sentinel-dashboard 和 sentinel-core 之间的通讯是基于 http 的，没有进行加密或鉴权，可能会存在数据安全性的问题，不过这些数据并非是很机密的数据，对安全性要求并不是很高，另外增加了鉴权或加密之后，对于性能和实效性有一定的影响。

### 5.5.2 SentinelApiClient

目前所有的数据请求都是通过 SentinelApiClient 类去完成的，该类中充斥着大量的方法，都是发送 http 请求的。代码的可读性和可维护性不高，所以需要对该类进行重构，目前我能够想到的有两种方法：

1）通过将 sentinel-core 注册为 rpc 服务，dashboard 就像调用本地方法一样去调用 sentinel-core 中的方法，不过这样的话需要引入服务注册和发现的依赖了。

2）通过 netty 实现私有的协议，sentinel-core 通过 netty 启动一个 CommandCenter 来对外提供服务。dashboard 通过发送 Packet 来进行数据请求，sentinel-core 来处理 Packet。不过这种方法跟目前的做法没有太大的区别，唯一比较好的可能就是不需要为每种请求都写一个方法，只需要定义好具体的 Packet 就好了。

# 参考

[【尚硅谷】Sentinel视频教程丨Alibaba流量控制组件sentinel](https://www.bilibili.com/video/BV12o4y127GC)

[Sentinel 源码解析系列 ](https://mp.weixin.qq.com/s/7_pCkamNv0269e5l9_Wz7w)

[Sentinel 原理-如何为系统设置扩展点](https://mp.weixin.qq.com/s/gPymTM4rW3G91EZ397bfVQ)

[Sentinel原理：控制台是如何获取到实时数据的](https://mp.weixin.qq.com/s/hr_7wnA6IHpXyksTscQyZQ)

[【sentinel】深入浅出之原理篇SlotChain](https://www.jianshu.com/p/a7a405de3a12)

[javadoop-阿里 Sentinel 源码解析](https://www.javadoop.com/post/sentinel)
