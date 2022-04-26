# 1. 概述

本篇文章我们来聊聊大家日常开发中常用的一个集合类 - `HashMap`。HashMap 最早出现在 JDK 1.2中，底层基于散列算法实现。HashMap 允许 null 键和 null 值，在计算哈键的哈希值时，**null 键哈希值为 0**。HashMap 并不保证键值对的顺序，这意味着在进行某些操作后，键值对的顺序可能会发生变化。另外，需要注意的是，HashMap 是非线程安全类，在多线程环境下可能会存在问题。

在本篇文章中，我将会对 HashMap 中常用方法、重要属性及相关方法进行分析。需要说明的是，HashMap 源码中可分析的点很多，本文很难一一覆盖，请见谅。

# 2. 原理

上一节说到 HashMap 底层是基于散列算法实现，散列算法分为**散列再探测（开放寻址法）和拉链式**。HashMap 则使用了拉链式的散列算法，并在 JDK 1.8 中引入了红黑树优化过长的链表。数据结构示意图如下：

<img src="http://blog-1259650185.cosbj.myqcloud.com/img/202108/27/1630031610.png" alt="image-20210827103330692" style="zoom:50%;" />

对于拉链式的散列算法，其数据结构是由数组和链表（或树形结构）组成。在进行增删查等操作时，首先要定位到元素的所在桶的位置，之后再从链表中定位该元素。比如我们要查询上图结构中是否包含元素`35`，步骤如下：

1. 定位元素`35`所处桶的位置，`index = 35 % 16 = 3`
2. 在`3`号桶所指向的链表中继续查找，发现35在链表中。

上面就是 HashMap 底层数据结构的原理，HashMap 基本操作就是对拉链式散列算法基本操作的一层包装。不同的地方在于 JDK 1.8 中引入了红黑树，底层数据结构由`数组+链表`变为了`数组+链表+红黑树`，不过本质并未变。在理想情况下，hashCode 分布良好，链表长度符合泊松分布，各个长度的命中率依次递减，当长度为 8 时，概率小于千万分之一，通常 Map 里不会存这么多数据，也就不会发生链表到红黑树的转换。

# 3. 源码分析

本篇文章所分析的源码版本为 JDK 1.8。与 JDK 1.7 相比，JDK 1.8 对 HashMap 进行了一些优化。比如引入红黑树解决过长链表效率低的问题。重写 resize 方法，移除了 alternative hashing 相关方法，避免重新计算键的 hash 等。

**Node 节点类源码:**

```java
// 继承自 Map.Entry<K,V>
static class Node<K,V> implements Map.Entry<K,V> {
       final int hash;// 哈希值，存放元素到hashmap中时用来与其他元素hash值比较
       final K key;//键
       V value;//值
       // 指向下一个节点
       Node<K,V> next;
       Node(int hash, K key, V value, Node<K,V> next) {
            this.hash = hash;
            this.key = key;
            this.value = value;
            this.next = next;
        }
        public final K getKey()        { return key; }
        public final V getValue()      { return value; }
        public final String toString() { return key + "=" + value; }
        // 重写hashCode()方法
        public final int hashCode() {
            return Objects.hashCode(key) ^ Objects.hashCode(value);
        }

        public final V setValue(V newValue) {
            V oldValue = value;
            value = newValue;
            return oldValue;
        }
        // 重写 equals() 方法
        public final boolean equals(Object o) {
            if (o == this)
                return true;
            if (o instanceof Map.Entry) {
                Map.Entry<?,?> e = (Map.Entry<?,?>)o;
                if (Objects.equals(key, e.getKey()) &&
                    Objects.equals(value, e.getValue()))
                    return true;
            }
            return false;
        }
}
```

**树节点类源码:**

```java
static final class TreeNode<K,V> extends LinkedHashMap.Entry<K,V> {
        TreeNode<K,V> parent;  // 父
        TreeNode<K,V> left;    // 左
        TreeNode<K,V> right;   // 右
        TreeNode<K,V> prev;    // needed to unlink next upon deletion
        boolean red;           // 判断颜色
        TreeNode(int hash, K key, V val, Node<K,V> next) {
            super(hash, key, val, next);
        }
        // 返回根节点
        final TreeNode<K,V> root() {
            for (TreeNode<K,V> r = this, p;;) {
                if ((p = r.parent) == null)
                    return r;
                r = p;
}
```

## 3.1 常量和成员变量

```java
// 默认初始化table数组容量
static final int DEFAULT_INITIAL_CAPACITY = 1 << 4; // aka 16

// table数组允许的最大容量
static final int MAXIMUM_CAPACITY = 1 << 30;

// 默认负载因子
static final float DEFAULT_LOAD_FACTOR = 0.75f;

// 树化阈值
static final int TREEIFY_THRESHOLD = 8;

// 红黑树退化为链表阈值
static final int UNTREEIFY_THRESHOLD = 6;

// 树化时table数组的最小容量，数组容量大于64并且链表长度大于8时才树化
static final int MIN_TREEIFY_CAPACITY = 64;

/* ---------------- Fields -------------- */

// 散列表数组
transient Node<K,V>[] table;

// entrySet
transient Set<Map.Entry<K,V>> entrySet;

// table数组真实容量
transient int size;

// HashMap被结构化改变的次数（put、remove等，当元素value只是被替换时，不算），用来fail-fast
transient int modCount;

// 容量阈值，当前 HashMap 所能容纳键值对数量的最大值，超过这个值，则需扩容，threshold = capacity * load factor
int threshold;

// 负载因子
final float loadFactor;
```

## 3.2 构造方法

HashMap 的构造方法不多，只有四个。HashMap 构造方法做的事情比较简单，一般都是初始化一些重要变量，比如 loadFactor 和 threshold。而底层的数据结构则是延迟到插入键值对时再进行初始化。HashMap 相关构造方法如下

```java
/** 构造方法 1 ，无参方法只是给成员变量赋值，不会初始化*/
public HashMap() {
    this.loadFactor = DEFAULT_LOAD_FACTOR; // all other fields defaulted
}

/** 构造方法 2 */
public HashMap(int initialCapacity) {
    // 给了初始化容量，和构造方法3是相关的
    // 构造方法2和构造方法3都是同时给负载因子 loadFactor 和 容量阈值 threshold 赋值的，而构造方法1只是给 loadFactor 赋值
    this(initialCapacity, DEFAULT_LOAD_FACTOR);
}

/** 构造方法 3 */
public HashMap(int initialCapacity, float loadFactor) {
    // 校验
    if (initialCapacity < 0)
        throw new IllegalArgumentException("Illegal initial capacity: " +
                                           initialCapacity);
    if (initialCapacity > MAXIMUM_CAPACITY)
        initialCapacity = MAXIMUM_CAPACITY;
    if (loadFactor <= 0 || Float.isNaN(loadFactor))
        throw new IllegalArgumentException("Illegal load factor: " +
                                           loadFactor);
    this.loadFactor = loadFactor;
    // 容量阈值赋值，不是从公式 threshold = capacity * loadFactor 计算的，而是tableSizeFor()的返回值
    this.threshold = tableSizeFor(initialCapacity);
}

/**
 * 返回最近的大于或等于当前值的二次方数，n = cap - 1, n最后是都是11111的二进制数字，然后+1，正好是二次方数
 * 主要是用来计算容量阈值的
 */
static final int tableSizeFor(int cap) {
    int n = cap - 1;
    n |= n >>> 1;
    n |= n >>> 2;
    n |= n >>> 4;
    n |= n >>> 8;
    n |= n >>> 16;
    return (n < 0) ? 1 : (n >= MAXIMUM_CAPACITY) ? MAXIMUM_CAPACITY : n + 1;
}

/** 构造方法 4 */
public HashMap(Map<? extends K, ? extends V> m) {
    this.loadFactor = DEFAULT_LOAD_FACTOR;
    putMapEntries(m, false);
}

final void putMapEntries(Map<? extends K, ? extends V> m, boolean evict) {
    int s = m.size();
    if (s > 0) {
        // 判断table是否已经初始化
        if (table == null) { // pre-size
            // 未初始化，s为m的实际元素个数，ft为table数组长度
            float ft = ((float)s / loadFactor) + 1.0F;
            int t = ((ft < (float)MAXIMUM_CAPACITY) ?
                    (int)ft : MAXIMUM_CAPACITY);
            // 计算得到的t大于阈值，则初始化阈值
            if (t > threshold)
                threshold = tableSizeFor(t);
        }
        // 已初始化，并且m元素个数大于阈值，进行扩容处理
        else if (s > threshold)
            resize();
        // 将m中的所有元素添加至HashMap中
        for (Map.Entry<? extends K, ? extends V> e : m.entrySet()) {
            K key = e.getKey();
            V value = e.getValue();
            putVal(hash(key), key, value, false, evict);
        }
    }
}

```

上面4个构造方法中，大家平时用的最多的应该是第一个了。第一个构造方法很简单，仅将 loadFactor 变量设为默认值。构造方法2调用了构造方法3，而构造方法3仍然只是设置了一些变量。构造方法4则是将另一个 Map 中的映射拷贝一份到自己的存储结构中来，这个方法不是很常用

对于 HashMap 来说，负载因子是一个很重要的参数，该参数反应了 HashMap 桶数组的使用情况（假设键值对节点均匀分布在桶数组中）。通过调节负载因子，可使 HashMap 时间和空间复杂度上有不同的表现。当我们调低负载因子时，HashMap 所能容纳的键值对数量变少。扩容时，重新将键值对存储新的桶数组里，键与键之间产生的碰撞会下降，链表长度变短。此时，HashMap 的增删改查等操作的效率将会变高，这里是典型的拿空间换时间。相反，如果增加负载因子（负载因子可以大于1），HashMap 所能容纳的键值对数量变多，空间利用率高，但碰撞率也高。这意味着链表长度变长，效率也随之降低，这种情况是拿时间换空间。至于负载因子怎么调节，这个看使用场景了。一般情况下，我们用默认值就可以了。

## 3.3 put()

```java
public V put(K key, V value) {
    return putVal(hash(key), key, value, false, true);
}

// 	让 key 的 hash 值的高16位也参与路由计算，减小哈希冲突的概率
static final int hash(Object key) {
    int h;
    return (key == null) ? 0 : (h = key.hashCode()) ^ (h >>> 16);
}

/**
 * Implements Map.put and related methods
 *
 * @param hash hash for key key的hash值
 * @param key the key key
 * @param value the value to put value
 * @param onlyIfAbsent if true, don't change existing 如果是 true，那么只有在不存在该 key 时才会进行 put 操作，空值才put
 * @param evict if false, the table is in creation mode. 如果是false，table正在处于创建模式
 * @return previous value, or null if none 原来的value，如果没有的话，返回null
 */
final V putVal(int hash, K key, V value, boolean onlyIfAbsent, boolean evict) {
  	// p 是辅助节点，e 是可能会被找到的要被替换的节点
    Node<K,V>[] tab; Node<K,V> p; int n, i;
    // 初始化桶数组 table，table 被延迟到插入新数据时再进行初始化
    // 第一次 put 值的时候，会触发下面的 resize()
    // 第一次 resize 和后续的扩容有些不一样，因为这次是数组从 null 初始化到默认的 16 或自定义的初始容量
    if ((tab = table) == null || (n = tab.length) == 0)
        n = (tab = resize()).length;
    // (n - 1) & hash 确定元素存放在哪个桶中，如果此位置没有值，那么直接初始化一下 Node 并放置在这个位置就可以了
    // p是数组下标位置上节点的键值对
    if ((p = tab[i = (n - 1) & hash]) == null)
        tab[i] = newNode(hash, key, value, null);
    else { // 数组该位置有值
        Node<K,V> e; K k;
        // 如果键的值以及节点 hash 等于该位置节点的键值对时，则将 e 指向该键值对，取出这个节点，对 e 赋值为该位置的首个节点
        if (p.hash == hash &&
            ((k = p.key) == key || (key != null && key.equals(k))))
            // e 就赋值为该位置的首个节点
            e = p;
            
        // 如果该节点的引用类型为 TreeNode，则调用红黑树的插入方法
        else if (p instanceof TreeNode)  
            // e 赋值为？？？
            e = ((TreeNode<K,V>)p).putTreeVal(this, tab, hash, key, value);
        else {
          	// 到这里，说明数组该位置上是一个链表
            // 对链表进行遍历，并统计链表长度
            for (int binCount = 0; ; ++binCount) {
                // 链表中不包含要插入的键值对节点时，则将该节点接在链表的最后
                // e 是遍历指针，是p节点的next节点，刚进来的时候 p 是首个节点（前面已经判断过），e 是第二个节点
                // 最终是末尾节点的next节点，也就是null
                if ((e = p.next) == null) {
                    p.next = newNode(hash, key, value, null);
                  	// TREEIFY_THRESHOLD 为 8，所以，如果新插入的值是链表中的第 9 个（binCount = 7,0-7 循环了8次）
                    // 会触发下面的 treeifyBin，也就是将链表转换为红黑树（树化）
                    if (binCount >= TREEIFY_THRESHOLD - 1) // -1 for 1st
                        treeifyBin(tab, hash);
                    // 跳出循环
                    break;
                }
                
                // 条件为 true，在该链表中找到了"相等"的 key(== 或 equals)，跳出循环
                if (e.hash == hash &&
                    ((k = e.key) == key || (key != null && key.equals(k))))
                    // 此时 break，那么 e 为链表中[与要插入的新值的 key "相等"]的 node
                    break;
                // p = pre ???
                p = e;
            }
        }
        
        // e!=null 说明存在旧值的key与要插入的key"相等"
        // 对于我们分析的put操作，下面这个 if 其实就是进行 "值覆盖"，然后返回旧值
        if (e != null) { // existing mapping for key
            V oldValue = e.value;
            // onlyIfAbsent 表示是否仅在 oldValue 为 null 的情况下更新键值对的值
            if (!onlyIfAbsent || oldValue == null)
                e.value = value;
            // 访问后回调
            afterNodeAccess(e);
          	// 返回旧值
            return oldValue;
        }
    }
 		// 结构性修改
    ++modCount;
    // 键值对数量超过阈值时，则进行扩容
    if (++size > threshold)
        resize();
  	// 插入后回调
    afterNodeInsertion(evict);
    return null;
}
```

插入操作的入口方法是 `put(K,V)`，但核心逻辑在`V putVal(int, K, V, boolean, boolean)` 方法中。putVal 方法主要做了这么几件事情：

1. 当桶数组 table 为空或长度为 0时，通过扩容的方式初始化 table。
2. 通过 `hash & (table.length - 1)` 计算出目标槽位。
3. 如果目标槽位为空，创建结点并设置到槽位上。
4. 槽位非空，执行如下查找与 key 相同的节点：
   - 4.1 如果槽上第一个节点的 key 相同，找到。
   - 4.2 如果槽上第一个节点是红黑树，在红黑树上插入，返回原来的与 key 系统相同的节点。
   - 4.3 槽上第一个节点是链表，遍历：如果 key 相同，中断循环，找不到则插入到链表末尾，插入后如果达到转为红黑树的阈值 TREEIFY_THRESHOLD，则尝试转换为红黑树。
5. 如果找到目标节点，根据参数决定是否替换为新值，并返回旧值。
6. 元素计数加 1，判断键值对数量是否大于阈值，大于的话则进行扩容操作

## 3.4 resize()

在 Java 中，数组的长度是固定的，这意味着数组只能存储固定量的数据。但在开发的过程中，很多时候我们无法知道该建多大的数组合适。建小了不够用，建大了用不完，造成浪费。如果我们能实现一种变长的数组，并按需分配空间就好了。好在，我们不用自己实现变长数组，Java 集合框架已经实现了变长的数据结构。比如 ArrayList 和 HashMap。对于这类基于数组的变长数据结构，扩容是一个非常重要的操作。下面就来聊聊 HashMap 的扩容机制。

在 HashMap 中，桶数组的长度均是2的幂，阈值大小为桶数组长度与负载因子的乘积。当 HashMap 中的键值对数量超过阈值时，进行扩容。

HashMap 的扩容机制与其他变长集合的套路不太一样，HashMap 按当前桶数组长度的2倍进行扩容，阈值也变为原来的2倍（如果计算过程中，阈值溢出归零，则按阈值公式重新计算）。扩容之后，要重新计算键值对的位置，并把它们移动到合适的位置上去。

resize() 方法用于**初始化数组**或**数组扩容**，每次扩容后，容量为原来的 2 倍，并进行数据迁移。

```java
final Node<K,V>[] resize() {
    Node<K,V>[] oldTab = table;
  	// oldTab 和 oldCap 分别赋值为扩容前的 table 数组和 table 数组的长度
    int oldCap = (oldTab == null) ? 0 : oldTab.length;
  	// oldThr 赋值为扩容前 table 数组的容量阈值
    int oldThr = threshold;
    // 初始化扩容后的容量和容量阈值都为0
    int newCap, newThr = 0;
    // 如果 table 不为空，表明已经初始化过了，是正常扩容
    if (oldCap > 0) {
        // 当 table 容量超过容量最大值，则不再扩容
        if (oldCap >= MAXIMUM_CAPACITY) {
            threshold = Integer.MAX_VALUE;
            return oldTab;
        } 
        // 将数组大小扩大一倍，新容量为旧容量的两倍
        else if ((newCap = oldCap << 1) < MAXIMUM_CAPACITY &&
                 // 并且原来的容量大于等于16时，当扩容前的oldCap容量<16时不满足，后面需要重新计算扩容后容量阈值
                 oldCap >= DEFAULT_INITIAL_CAPACITY)
          	// 将阈值扩大一倍
            newThr = oldThr << 1; // double threshold
    } else if (oldThr > 0) // initial capacity was placed in threshold
      	// 对应使用 new HashMap(int initialCapacity) 构造方法2/3/4 初始化后，第一次 put 的时候
      	// 新的容量就是原来的容量阈值（tableSizeFor()计算得到的，一定是2的次方数）
      	// 构造方法2/3/4 这种 new hashmap的时候就给定了初始化容量的情况，真实容量就用原来计算好的容量阈值（二次方数）
        newCap = oldThr;
    else {               // zero initial threshold signifies using defaults
        // 对应使用 new HashMap() 构造方法1 初始化后，第一次 put 的时候
        // 桶数组容量为默认容量，
        newCap = DEFAULT_INITIAL_CAPACITY;
        // 阈值为默认容量与默认负载因子乘积， 16 * 0.75 = 12
        newThr = (int)(DEFAULT_LOAD_FACTOR * DEFAULT_INITIAL_CAPACITY);
    }
    
    // newThr 为 0 时（构造方法2/3/4的情况 || 普通数组扩容但是扩容前容量 < 16），新的容量阈值按阈值计算公式进行计算
    // 构造方法2和构造方法3的容量阈值也是为了当时下来，因为给的构造方法里的初始化容量就用一次，没有保存
    // 用容量阈值暂时计算出大于等于初始化容量的二次方数，然后暂存，最后还是赋值给容量，然后重新计算容量阈值
  	// 就是为了在构造方法的时候不初始化数组，统一在put()触发resize()的时候初始化
    if (newThr == 0) {
        float ft = (float)newCap * loadFactor;
        newThr = (newCap < MAXIMUM_CAPACITY && ft < (float)MAXIMUM_CAPACITY ?
                  (int)ft : Integer.MAX_VALUE);
    }
    // 容量阈值更新为新的容量阈值
    threshold = newThr;
    // 创建新的桶数组，桶数组的初始化也是在这里完成的
    Node<K,V>[] newTab = (Node<K,V>[])new Node[newCap];
    table = newTab;
    // 如果是初始化数组，到这里就结束了，返回 newTab 即可
    if (oldTab != null) {
        // 如果扩容前 tab 数组不为空，则遍历扩容前 tab 数组，并将键值对映射到扩容后的 tab 数组中
        for (int j = 0; j < oldCap; ++j) {
          	//  当前 node 节点
            Node<K,V> e;
          	// 说明当前桶位中有数据，但是数据具体是单个数据，还是链表，还是红黑树，并不知道
            if ((e = oldTab[j]) != null) {
              	// 置空，方便JVM GC时回收内存
                oldTab[j] = null;
              	// 第一种情况，当前桶位只有一个元素，从未发生过碰撞，这种情况直接计算当前元素在新的 tab 数组中的位置，
              	// 然后扔进去就可以了
                if (e.next == null)
                    newTab[e.hash & (newCap - 1)] = e;
              	// 第二种情况，当前节点已经树化
                else if (e instanceof TreeNode)
                    // 重新映射时，需要对红黑树进行拆分
                    ((TreeNode<K,V>)e).split(this, newTab, j, oldCap);
                else { // preserve order
                  	//  第三种情况，桶位已经形成链表
                  	// 低位链表，存放在扩容之后的数组的下标位置，与当前数组的下标位置一致
                    Node<K,V> loHead = null, loTail = null;
                    // 高位链表，存放在扩容之后的数组的下标位置为当前数组的下标位置 + 扩容之前的数组长度（31 = 15 + 16）
                    Node<K,V> hiHead = null, hiTail = null;
                  	// 当前节点的下一个元素
                    Node<K,V> next;
                    // 遍历链表，并将链表节点按原来的顺序进行分组，之前的版本以逆序（头插法）的方式重新插入，容易出现死循环
                    do {
                        next = e.next;
                      	// hash -> ...1 1111 31
                      	// or hash -> ...0 1111 15
                      	// oldCap -> 	0b 10000 16
                      	// 低位链表
                        if ((e.hash & oldCap) == 0) {
                            if (loTail == null)
                                loHead = e;
                            else
                                loTail.next = e;
                            loTail = e;
                        }
                        else { // 高位链表
                            if (hiTail == null)
                                hiHead = e;
                            else
                                hiTail.next = e;
                            hiTail = e;
                        }
                    } while ((e = next) != null);
                    // 将分组后的链表映射到新桶中，重新映射后，两条链表中的节点顺序并未发生变化，还是保持了扩容前的顺序。
                    if (loTail != null) {
                        loTail.next = null;
                        newTab[j] = loHead;
                    }
                    if (hiTail != null) {
                        hiTail.next = null;
                        newTab[j + oldCap] = hiHead;
                    }
                }
            }
        }
    }
    return newTab;
}
```

上面的源码有点长，希望大家耐心看懂它的逻辑。上面的源码总共做了3件事，分别是：

1. 计算新桶数组的容量 newCap 和新阈值 newThr，默认扩容为原来的两倍。
2. 根据计算出的 newCap 创建新的桶数组，桶数组 table 也是在这里进行初始化的。
3. 把旧数组上的元素转移到新数据上：遍历槽数组，对非空的数组元素 e 进行如下处理：
   - 3.1 如果 e.next 为空，表示只有一个节点，直接转移到新的槽位上。
   - 3.2 如果 e 是红黑树，把红黑树逆转、拆分到高低两棵树，分别追加到 table[index], table[index+oldCap] 槽上。
   - 3.3 如果节点是链表，则按原顺序把链表拆分为高低两个链表，分别追加到 table[index], table[index+oldCap] 槽上。

## 3.5 get()

```java
public V get(Object key) {
    Node<K,V> e;
    return (e = getNode(hash(key), key)) == null ? null : e.value;
}

final Node<K,V> getNode(int hash, Object key) {
  	// tab：引用当前hashMap的散列表
    // first：桶位的头元素
		// e：临时node元素
		// n：table数组长度
    Node<K,V>[] tab; Node<K,V> first, e; int n; K k;
    // 定位键值对所在桶的位置
    if ((tab = table) != null && (n = tab.length) > 0 &&
        (first = tab[(n - 1) & hash]) != null) {
      	// 第一种情况：定位出来的桶位元素，即为要 get 的元素
        if (first.hash == hash && // always check first node
            ((k = first.key) == key || (key != null && key.equals(k))))
            return first;
      	// 说明当前桶位不止一个元素，可能是链表，也可能是红黑树
        if ((e = first.next) != null) {
            // 第二种情况：如果 first 是 TreeNode 类型，则调用黑红树查找方法
            if (first instanceof TreeNode)
                return ((TreeNode<K,V>)first).getTreeNode(hash, key);
                
            // 第三种情况：桶位形成链表，对链表进行查找
            do {
                if (e.hash == hash &&
                    ((k = e.key) == key || (key != null && key.equals(k))))
                    return e;
            } while ((e = e.next) != null);
        }
    }
    return null;
}
```

HashMap 的查找操作比较简单，查找步骤与原理篇介绍一致，即先定位键值对所在的桶的位置，然后再对链表或红黑树进行查找。

## 3.6 remove()

```java
public V remove(Object key) {
    Node<K,V> e;
    return (e = removeNode(hash(key), key, null, false, true)) == null ?
        null : e.value;
}

// 查找到的 node 的 value 要和给定的参数的 value 要匹配的上
public boolean remove(Object key, Object value) {
    return removeNode(hash(key), key, value, true, true) != null;
}

/**
 * @param hash hash for key
 * @param key the key
 * @param value the value to match if matchValue, else ignored 是否要匹配给定的value
 * @param matchValue if true only remove if value is equal 如果是true，只有 value equals的时候才会移除value 
 * @param movable if false do not move other nodes while removing 如果是false，不会移除
 * @return the node, or null if none
 */
final Node<K,V> removeNode(int hash, Object key, Object value,
                           boolean matchValue, boolean movable) {
    // tab：引用当前hashMap的散列表
    // p：当前 node 元素
		// n：table数组长度
  	// index：寻址结果
    Node<K,V>[] tab; Node<K,V> p; int n, index;
    if ((tab = table) != null && (n = tab.length) > 0 &&
        // 定位桶位置
        (p = tab[index = (n - 1) & hash]) != null) {
        // 说明路由的桶位是有数据的，需要进行查找操作，并且删除 value
      	// node：查找到的结果
      	// e：当前 node 的下一个元素
        Node<K,V> node = null, e; K k; V v;
        // 第一种情况：如果键的值与链表第一个节点相等，就是要找的元素,则将 node 指向该节点
        if (p.hash == hash &&
            ((k = p.key) == key || (key != null && key.equals(k))))
            node = p;
        else if ((e = p.next) != null) { 
          	// 说明，当前桶位要么是链表，要么是红黑树
            if (p instanceof TreeNode)
                // 第二种情况： 是TreeNode 类型，调用红黑树的查找逻辑定位待删除节点
                node = ((TreeNode<K,V>)p).getTreeNode(hash, key);
            else {
                // 第三种情况：是链表，遍历链表，找到待删除节点
                do {
                    if (e.hash == hash &&
                        ((k = e.key) == key ||
                         (key != null && key.equals(k)))) {
                        node = e;
                        break;
                    }
                    p = e;
                } while ((e = e.next) != null);
            }
        }
        
        // 判断 node 不为空的话，说明按照 key 找到要删除的节点了，要删除节点，并修复链表或红黑树
        if (node != null && (!matchValue || (v = node.value) == value ||
                             (value != null && value.equals(v)))) {
            if (node instanceof TreeNode)
                // 第一种情况：node 是树节点，说明需要进行树节点移除操作
                ((TreeNode<K,V>)node).removeTreeNode(this, tab, movable);
            else if (node == p)
              	// 第二种情况：桶位元素即为查找结果，则将该元素的下一个元素放至桶位中
                tab[index] = node.next;
            else
                // 第三种情况：连接新的链表
                p.next = node.next;
            ++modCount;
            --size;
            afterNodeRemoval(node);
            return node;
        }
    }
    return null;
}
```

HashMap 的删除操作并不复杂，仅需三个步骤即可完成。第一步是定位桶位置，第二步遍历链表并找到键值相等的节点，第三步删除节点。

## 3.7 iterator()

和查找查找一样，遍历操作也是大家使用频率比较高的一个操作。对于 遍历 HashMap，我们一般都会用下面的方式

```java
for(Object key : map.keySet()) {
    // do something
}
```

或

```java
for(HashMap.Entry entry : map.entrySet()) {
    // do something
}
```

从上面代码片段中可以看出，大家一般都是对 HashMap 的 key 集合或 Entry 集合进行遍历。上面代码片段中用 foreach 遍历 keySet 方法产生的集合，在编译时会转换成用迭代器遍历，等价于：

```java
Set keys = map.keySet();
Iterator ite = keys.iterator();
while (ite.hasNext()) {
    Object key = ite.next();
    // do something
}
```

大家在遍历 HashMap 的过程中会发现，多次对 HashMap 进行遍历时，遍历结果顺序都是一致的。但这个顺序和插入的顺序一般都是不一致的。产生上述行为的原因是怎样的呢？大家想一下原因。我先把遍历相关的代码贴出来，如下：

```java
public Set<K> keySet() {
    Set<K> ks = keySet;
    if (ks == null) {
        ks = new KeySet();
        keySet = ks;
    }
    return ks;
}

/**
 * 键集合
 */
final class KeySet extends AbstractSet<K> {
    public final int size()                 { return size; }
    public final void clear()               { HashMap.this.clear(); }
    public final Iterator<K> iterator()     { return new KeyIterator(); }
    public final boolean contains(Object o) { return containsKey(o); }
    public final boolean remove(Object key) {
        return removeNode(hash(key), key, null, false, true) != null;
    }
    // 省略部分代码
}

/**
 * 键迭代器
 */
final class KeyIterator extends HashIterator implements Iterator<K> {
    public final K next() { return nextNode().key; }
}

abstract class HashIterator {
    Node<K,V> next;        // next entry to return，当前节点的下一个节点
    Node<K,V> current;     // current entry 当前节点
    int expectedModCount;  // for fast-fail
    int index;             // current slot

    HashIterator() {
        expectedModCount = modCount;
        Node<K,V>[] t = table;
        current = next = null;
        index = 0;
        if (t != null && size > 0) { // advance to first entry 
            // 寻找第一个包含链表节点引用的桶
            do {} while (index < t.length && (next = t[index++]) == null);
        }
    }

    public final boolean hasNext() {
        return next != null;
    }

    final Node<K,V> nextNode() {
        Node<K,V>[] t;
        Node<K,V> e = next;
        if (modCount != expectedModCount)
            throw new ConcurrentModificationException();
        if (e == null)
            throw new NoSuchElementException();
      	// next 每次赋值，为当前节点的下一个节点
      	// 当达到链表末尾时，进入 if 代码块
        if ((next = (current = e).next) == null && (t = table) != null) {
            // 寻找下一个包含链表节点引用的桶
            do {} while (index < t.length && (next = t[index++]) == null);
        }
        return e;
    }
    //省略部分代码
}
```

如上面的源码，遍历所有的键时，首先要获取键集合`KeySet`对象，然后再通过 KeySet 的迭代器`KeyIterator`进行遍历。KeyIterator 类继承自`HashIterator`类，核心逻辑也封装在 HashIterator 类中。HashIterator 的逻辑并不复杂，在初始化时，HashIterator 先从桶数组中找到包含链表节点引用的桶。然后对这个桶指向的链表进行遍历。遍历完成后，再继续寻找下一个包含链表节点引用的桶，找到继续遍历。找不到，则结束遍历。举个例子，假设我们遍历下图的结构：

<img src="http://blog-1259650185.cosbj.myqcloud.com/img/202108/31/1630342133.png" alt="image-20210831004847370" style="zoom:50%;" />

HashIterator 在初始化时，会先遍历桶数组，找到包含链表节点引用的桶，对应图中就是3号桶。随后由 nextNode 方法遍历该桶所指向的链表。遍历完3号桶后，nextNode 方法继续寻找下一个不为空的桶，对应图中的7号桶。之后流程和上面类似，直至遍历完最后一个桶。以上就是 HashIterator 的核心逻辑的流程，对应下图：

<img src="http://blog-1259650185.cosbj.myqcloud.com/img/202108/31/1630342168.png" alt="image-20210831004928264" style="zoom:50%;" />

遍历上图的最终结果是 `19 -> 3 -> 35 -> 7 -> 11 -> 43 -> 59`，为了验证正确性，简单写点测试代码跑一下看看。测试代码如下

```java
/**
 * 应在 JDK 1.8 下测试，其他环境下不保证结果和上面一致
 */
public class HashMapTest {

    @Test
    public void testTraversal() {
        HashMap<Integer, String> map = new HashMap(16);
        map.put(7, "");
        map.put(11, "");
        map.put(43, "");
        map.put(59, "");
        map.put(19, "");
        map.put(3, "");
        map.put(35, "");

        System.out.println("遍历结果：");
        for (Integer key : map.keySet()) {
            System.out.print(key + " -> ");
        }
    }
}
```

## 3.8 为什么 table 数组用 transient 修饰？

HashMap 并没有使用默认的序列化机制，而是通过实现`readObject/writeObject`两个方法自定义了序列化的内容。主要是基于以下两点考虑：

1. table 多数情况下是未填满的，序列化未使用部分，浪费空间。
2. 同一个键在不同的 JVM 下算出来的哈希值可能不同，所处的槽位也就不同，在不同的 JVM 下反序列化 table 可能出错。不同的 JVM 下，可能会有不同的实现，产生的 hash 可能也是不一样的。也就是说同一个键在不同平台下可能会产生不同的 hash，此时再对在同一个 table 继续操作，就会出现问题。

# 参考

[田小波的技术博客-HashMap-源码详细分析-JDK1-8](https://www.tianxiaobo.com/2018/01/18/HashMap-%E6%BA%90%E7%A0%81%E8%AF%A6%E7%BB%86%E5%88%86%E6%9E%90-JDK1-8/)

[javadoop-Java7/8 中的 HashMap 和 ConcurrentHashMap 全解析](https://javadoop.com/post/hashmap)

[coderbee笔记-HashMap](https://coderbee.net/index.php/java/20210607/2159)

[JavaGuide-HashMap(JDK1.8)源码+底层数据结构分析](https://snailclimb.gitee.io/javaguide/#/docs/java/collection/HashMap(JDK1.8)%E6%BA%90%E7%A0%81+%E5%BA%95%E5%B1%82%E6%95%B0%E6%8D%AE%E7%BB%93%E6%9E%84%E5%88%86%E6%9E%90)

