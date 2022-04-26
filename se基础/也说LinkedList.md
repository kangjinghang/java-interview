# 1. 概述

LinkedList 是 Java 集合框架中一个重要的实现，是一个实现了List接口和Deque接口的双端链表。和 ArrayList 一样，LinkedList 也支持空值和重复值。由于 LinkedList 基于链表实现，存储元素过程中，无需像 ArrayList 那样进行扩容。但有得必有失，LinkedList 存储元素的节点需要额外的空间存储前驱和后继的引用。另一方面，LinkedList 在链表头部和尾部插入效率比较高，但在指定位置进行插入时，效率一般。原因是，在指定位置插入需要定位到该位置处的节点，此操作的时间复杂度为`O(N)`。最后，LinkedList 是非线程安全的集合类，并发环境下，多个线程同时操作 LinkedList，会引发不可预知的错误。如果想使LinkedList变成线程安全的，可以调用静态类Collections类中的synchronizedList方法：

```java
List list=Collections.synchronizedList(new LinkedList(...));
```

# 2. 核心源码分析

## 2.1 继承体系

LinkedList 的继承体系较为复杂，继承自 AbstractSequentialList，同时又实现了 List 和 Deque 接口。继承体系图如下（删除了部分实现的接口）：

<img src="http://blog-1259650185.cosbj.myqcloud.com/img/202109/08/1631116129.png" alt="image-20210908234849007" style="zoom:50%;" />

LinkedList 继承自 AbstractSequentialList，AbstractSequentialList 又是什么呢？从实现上，AbstractSequentialList 提供了一套基于顺序访问的接口。通过继承此类，子类仅需实现部分代码即可拥有完整的一套访问某种序列表（比如链表）的接口。深入源码，AbstractSequentialList 提供的方法基本上都是通过 ListIterator 实现的，比如：

```java
public E get(int index) {
    try {
        return listIterator(index).next();
    } catch (NoSuchElementException exc) {
        throw new IndexOutOfBoundsException("Index: "+index);
    }
}

public void add(int index, E element) {
    try {
        listIterator(index).add(element);
    } catch (NoSuchElementException exc) {
        throw new IndexOutOfBoundsException("Index: "+index);
    }
}

// 留给子类实现
public abstract ListIterator<E> listIterator(int index);
```

所以只要继承类实现了 listIterator 方法，它不需要再额外实现什么即可使用。对于随机访问集合类一般建议继承 AbstractList 而不是 AbstractSequentialList。LinkedList 和其父类一样，也是基于顺序访问。所以 LinkedList 继承了 AbstractSequentialList，但 LinkedList 并没有直接使用父类的方法，而是重新实现了一套的方法。

另外，LinkedList 还实现了 Deque (double ended queue)，Deque 又继承自 Queue 接口。这样 LinkedList 就具备了队列的功能。比如，我们可以这样使用：

```java
Queue<T> queue = new LinkedList<>();
```

除此之外，我们基于 LinkedList 还可以实现一些其他的数据结构，比如栈，以此来替换 Java 集合框架中的 Stack 类（该类实现的不好，《Java 编程思想》一书的作者也对此类进行了吐槽）。

## 2.2 get()

LinkedList 底层基于链表结构，无法向 ArrayList 那样随机访问指定位置的元素。LinkedList 查找过程要稍麻烦一些，需要从链表头结点（或尾节点）向后查找，时间复杂度为 `O(N)`。相关源码如下：

```java
public E get(int index) {
    // 检查index范围是否在size之内
    checkElementIndex(index);
    // 调用Node(index)去找到index对应的node然后返回它的值
    return node(index).item;
}

Node<E> node(int index) {
    /*
     * 则从头节点开始查找，否则从尾节点查找
     * 查找位置 index 如果小于节点数量的一半，
     */    
    if (index < (size >> 1)) {
        Node<E> x = first;
        // 循环向后查找，直至 i == index
        for (int i = 0; i < index; i++)
            x = x.next;
        return x;
    } else {
        Node<E> x = last;
        for (int i = size - 1; i > index; i--)
            x = x.prev;
        return x;
    }
}
```

获取头节点（index=0）数据方法：

```java
public E getFirst() {
   final Node<E> f = first;
   if (f == null)
     throw new NoSuchElementException();
   return f.item;
}
public E element() {
   return getFirst();
}
public E peek() {
   final Node<E> f = first;
   return (f == null) ? null : f.item;
}

public E peekFirst() {
   final Node<E> f = first;
   return (f == null) ? null : f.item;
}
```

**区别：** getFirst(),element(),peek(),peekFirst() 这四个获取头结点方法的区别在于对链表为空时的处理，是抛出异常还是返回null，其中**getFirst()** 和**element()** 方法将会在链表为空时，抛出异常。element()方法的内部就是使用getFirst()实现的。它们会在链表为空时，抛出NoSuchElementException。

获取尾节点（index=-1）数据方法：

```java
 public E getLast() {
    final Node<E> l = last;
    if (l == null)
      throw new NoSuchElementException();
    return l.item;
 }
 public E peekLast() {
    final Node<E> l = last;
    return (l == null) ? null : l.item;
 }
```

**两者区别：** **getLast()** 方法在链表为空时，会抛出**NoSuchElementException**，而**peekLast()** 则不会，只是会返回 **null**。

## 2.3 indexOf()

```java
// 从头遍历找
public int indexOf(Object o) {
    int index = 0;
    if (o == null) {
        // 从头遍历
        for (Node<E> x = first; x != null; x = x.next) {
            if (x.item == null)
                return index;
            index++;
        }
    } else {
        // 从头遍历
        for (Node<E> x = first; x != null; x = x.next) {
            if (o.equals(x.item))
                return index;
            index++;
        }
    }
    return -1;
}
```

```java
// 从尾遍历找
public int lastIndexOf(Object o) {
    int index = size;
    if (o == null) {
        for (Node<E> x = last; x != null; x = x.prev) {
            index--;
            if (x.item == null)
                return index;
        }
    } else {
        for (Node<E> x = last; x != null; x = x.prev) {
            index--;
            if (o.equals(x.item))
                return index;
        }
    }
    return -1;
}
```

## 2.4 contains()

```java
// 检查对象o是否存在于链表中
public boolean contains(Object o) {
    return indexOf(o) != -1;
}
```

## 2.5 遍历

链表的遍历过程也很简单，和上面查找过程类似，我们从头节点往后遍历就行了。但对于 LinkedList 的遍历还是需要注意一些，不然可能会导致代码效率低下。通常情况下，我们会使用 foreach 遍历 LinkedList，而 foreach 最终转换成迭代器形式。所以分析 LinkedList 的遍历的核心就是它的迭代器实现，相关代码如下：

```java
public ListIterator<E> listIterator(int index) {
    checkPositionIndex(index);
    return new ListItr(index);
}

private class ListItr implements ListIterator<E> {
    private Node<E> lastReturned;
    private Node<E> next;
    private int nextIndex;
    private int expectedModCount = modCount;

    /*
     * 构造方法将 next 引用指向指定位置的节点
     */    
    ListItr(int index) {
        // assert isPositionIndex(index);
        next = (index == size) ? null : node(index);
        nextIndex = index;
    }

    public boolean hasNext() {
        return nextIndex < size;
    }

    public E next() {
        checkForComodification();
        if (!hasNext())
            throw new NoSuchElementException();

        lastReturned = next;
        next = next.next;    // 调用 next 方法后，next 引用都会指向他的后继节点
        nextIndex++;
        return lastReturned.item;
    }
    
    // 省略部分方法
}
```

我们都知道 LinkedList 不擅长随机位置访问，如果大家用随机访问的方式遍历 LinkedList，效率会很差。比如下面的代码：

```java
List<Integet> list = new LinkedList<>();
list.add(1)
list.add(2)
......
for (int i = 0; i < list.size(); i++) {
    Integet item = list.get(i);
    // do something
}
```

当链表中存储的元素很多时，上面的遍历方式对于效率来说就是灾难。原因在于，通过上面的方式每获取一个元素，LinkedList 都需要从头节点（或尾节点）进行遍历，效率不可谓不低。在我的电脑（MacBook Pro Early 2015, 2.7 GHz Intel Core i5）实测10万级的数据量，耗时约7秒钟。20万级的数据量耗时达到了约34秒的时间。50万级的数据量耗时约250秒。从测试结果上来看，上面的遍历方式在大数据量情况下，效率很差。大家在日常开发中应该尽量避免这种用法。

## 2.6 add()

```java
/*
 * 在链表尾部插入元素
 */  
public boolean add(E e) {
    linkLast(e);
    return true;
}

/*
 * 在链表指定位置插入元素
 */ 
public void add(int index, E element) {
    checkPositionIndex(index);

    // 判断 index 是不是链表尾部位置，如果是，直接将元素节点插入链表尾部即可
    if (index == size)
        linkLast(element);
    else
        linkBefore(element, node(index));
}

public void addLast(E e) {
    linkLast(e);
}

/*
 * 将元素节点插入到链表尾部
 */ 
void linkLast(E e) {
    final Node<E> l = last;
    // 创建节点，并指定节点前驱为链表尾节点 last，后继引用为空
    final Node<E> newNode = new Node<>(l, e, null);
    // 将 last 引用指向新节点
    last = newNode;
    // 判断尾节点是否为空，为空表示当前链表还没有节点
    if (l == null)
        first = newNode;
    else
        l.next = newNode;    // 让原尾节点后继引用 next 指向新的尾节点
    size++;
    modCount++;
}

public void addFirst(E e) {
    linkFirst(e);
}

private void linkFirst(E e) {
    final Node<E> f = first;
    // 新建节点，以头节点为后继节点
    final Node<E> newNode = new Node<>(null, e, f);
    first = newNode;
    // 如果链表为空，last节点也指向该节点
    if (f == null)
        last = newNode;
    else
      	// 否则，将头节点的前驱指针指向新节点，也就是指向前一个元素
        f.prev = newNode;
    size++;
    modCount++;
}

public void add(int index, E element) {
    // 检查索引是否处于[0-size]之间
    checkPositionIndex(index);
    // 添加在链表尾部
    if (index == size)
        linkLast(element);
    else 
        // 添加在链表中间
        linkBefore(element, node(index));
}

/*
 * 将元素节点插入到 succ 之前的位置
 */ 
void linkBefore(E e, Node<E> succ) {
    // assert succ != null;
    final Node<E> pred = succ.prev;
    // 1. 初始化节点，并指明前驱和后继节点
    final Node<E> newNode = new Node<>(pred, e, succ);
    // 2. 将 succ 节点前驱引用 prev 指向新节点
    succ.prev = newNode;
    // 判断尾节点是否为空，为空表示当前链表还没有节点    
    if (pred == null)
        first = newNode;
    else
        pred.next = newNode;   // 3. succ 节点前驱的后继引用指向新节点
    size++;
    modCount++;
}

/*
 * 将集合插入到链表尾部
 */ 
public boolean addAll(Collection<? extends E> c) {
    return addAll(size, c);
}

/*
 * 将集合从指定位置开始插入
 */ 
public boolean addAll(int index, Collection<? extends E> c) {
  	// 1:检查index范围是否在size之内
    checkPositionIndex(index);
		// 2:toArray()方法把集合的数据存到对象数组中
    Object[] a = c.toArray();
    int numNew = a.length;
    if (numNew == 0)
        return false;
	  // 3：得到插入位置的前驱节点和后继节点
    Node<E> pred, succ;
  	// 如果插入位置为尾部，前驱节点为last，后继节点为null
    if (index == size) {
        succ = null;
        pred = last;
    } else {
      	// 否则，调用node()方法得到后继节点，再得到前驱节点
        succ = node(index);
        pred = succ.prev;
    }

    // 4：遍历数据将数据插入
    for (Object o : a) {
        @SuppressWarnings("unchecked") E e = (E) o;
      	// 创建新节点
        Node<E> newNode = new Node<>(pred, e, null);
       // 如果插入位置在链表头部
        if (pred == null)
            first = newNode;
        else
            pred.next = newNode;
        pred = newNode;
    }

    // 如果插入位置在尾部，重置last节点
    if (succ == null) {
        last = pred;
    } else {
        // 否则，将插入的链表与先前链表连接起来，pred 现在是新插入的集合 c 的最后一个元素，插入前位置的前驱节点关系								      // 已经在前面维护好了，下面就维护插入后位置与 pred 的关系
        pred.next = succ;
        succ.prev = pred;
    }

    size += numNew;
    modCount++;
    return true;
}
```

## 2.7 remove()

```java
public boolean remove(Object o) {
    if (o == null) {
        for (Node<E> x = first; x != null; x = x.next) {
            if (x.item == null) {
                unlink(x);
                return true;
            }
        }
    } else {
        // 遍历链表，找到要删除的节点
        for (Node<E> x = first; x != null; x = x.next) {
            if (o.equals(x.item)) {
                unlink(x);    // 将节点从链表中移除
                return true;
            }
        }
    }
    return false;
}

public E remove(int index) {
    checkElementIndex(index);
    // 通过 node 方法定位节点，并调用 unlink 将节点从链表中移除
    return unlink(node(index));
}

// 删除头节点
public E pop() {
    return removeFirst();
}

// 删除头节点
public E remove() {
    return removeFirst();
}

// 删除头节点
public E removeFirst() {
    final Node<E> f = first;
    if (f == null)
        throw new NoSuchElementException();
    return unlinkFirst(f);
}

// 删除尾节点
// 区别： removeLast()在链表为空时将抛出NoSuchElementException，而pollLast()方法返回null。
public E removeLast() {
    final Node<E> l = last;
    if (l == null)
        throw new NoSuchElementException();
    return unlinkLast(l);
}

// 删除尾节点
public E pollLast() {
    final Node<E> l = last;
    return (l == null) ? null : unlinkLast(l);
}

private E unlinkFirst(Node<E> f) {
    // assert f == first && f != null;
    final E element = f.item;
    final Node<E> next = f.next;
    f.item = null;
    f.next = null; // help GC
    first = next;
    if (next == null)
        last = null;
    else
        next.prev = null;
    size--;
    modCount++;
    return element;
}

/**
 * Unlinks non-null last node l.
 */
private E unlinkLast(Node<E> l) {
    // assert l == last && l != null;
    final E element = l.item;
    final Node<E> prev = l.prev;
    l.item = null;
    l.prev = null; // help GC
    last = prev;
    if (prev == null)
        first = null;
    else
        prev.next = null;
    size--;
    modCount++;
    return element;
}

/*
 * 将某个节点从链表中移除
 */ 
E unlink(Node<E> x) {
    // assert x != null;
    final E element = x.item;
    final Node<E> next = x.next;
    final Node<E> prev = x.prev;
    
    // 删除前驱指针
    // prev 为空，表明删除的是头节点
    if (prev == null) {
        first = next;
    } else {
        // 将 x 的前驱的后继指向 x 的后继
        prev.next = next;
        // 将 x 的前驱引用置空，断开与前驱的链接
        x.prev = null;
    }

    // 删除后继指针
    // next 为空，表明删除的是尾节点
    if (next == null) {
        last = prev;
    } else {
        // 将 x 的后继的前驱指向 x 的前驱
        next.prev = prev;
        // 将 x 的后继引用置空，断开与后继的链接
        x.next = null;
    }

    // 将 item 置空，方便 GC 回收
    x.item = null;
    size--;
    modCount++;
    return element;
}
```

nlink 方法的逻辑如下（假设删除的节点既不是头节点，也不是尾节点）：

1. 将待删除节点 x 的**前驱**的后继指向 x 的后继
2. 将待删除节点 x 的**前驱**引用置空，断开与前驱的链接
3. 将待删除节点 x 的**后继**的前驱指向 x 的前驱
4. 将待删除节点 x 的**后继**引用置空，断开与后继的链接

<img src="http://blog-1259650185.cosbj.myqcloud.com/img/202109/09/1631120080.png" alt="image-20210909005440373" style="zoom:50%;" />

# 参考

[田小波的技术博客-LinkedList-源码分析](https://www.tianxiaobo.com/2018/01/31/LinkedList-%E6%BA%90%E7%A0%81%E5%88%86%E6%9E%90-JDK-1-8/)

[JavaGuide-LinkedList源码分析](https://snailclimb.gitee.io/javaguide/#/docs/java/collection/LinkedList%E6%BA%90%E7%A0%81%E5%88%86%E6%9E%90)

