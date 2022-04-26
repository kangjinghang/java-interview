# 1. 概述

`ArrayList` 是一种变长的集合类，基于定长数组实现，它的容量能动态增。ArrayList 允许空值和重复元素，当往 ArrayList 中添加的元素数量大于其底层数组容量时，其会通过扩容机制重新生成一个更大的数组。在添加大量元素前，应用程序可以使用`ensureCapacity`操作来增加 `ArrayList` 实例的容量，这可以减少递增式再分配的数量。另外，由于 ArrayList 底层基于数组实现，所以其可以保证在 `O(1)` 复杂度下完成随机查找操作。其他方面，ArrayList 是非线程安全类，并发环境下，多个线程同时操作 ArrayList，会引发不可预知的错误。

`ArrayList`继承于 `AbstractList` ，实现了 `List`, `RandomAccess`, `Cloneable`, `java.io.Serializable` 这些接口。

```java
public class ArrayList<E> extends AbstractList<E>
        implements List<E>, RandomAccess, Cloneable, java.io.Serializable{

 }
```

- `RandomAccess` 是一个标志接口，表明实现这个这个接口的 List 集合是支持**快速随机访问**的。在 `ArrayList` 中，我们即可以通过元素的序号快速获取元素对象，这就是快速随机访问。
- `ArrayList` 实现了 `Cloneable` 接口 ，即覆盖了函数`clone()`，能被克隆。
- `ArrayList` 实现了 `java.io.Serializable`接口，这意味着`ArrayList`支持序列化，能通过序列化去传输。

# 2. 核心源码分析

## 2.1 构造方法

```java
/**
 * 默认初始容量大小
 */
private static final int DEFAULT_CAPACITY = 10;

/**
 * 空数组（用于空实例）
 */
private static final Object[] EMPTY_ELEMENTDATA = {};

/**
 * 用于默认大小空实例的共享空数组实例。
 * 我们把它从EMPTY_ELEMENTDATA数组中区分出来，以知道在添加第一个元素时容量需要增加多少。
 */
private static final Object[] DEFAULTCAPACITY_EMPTY_ELEMENTDATA = {};

/**
 * 保存ArrayList数据的数组
 */
transient Object[] elementData; // non-private to simplify nested class access

/**
 * ArrayList 所包含的元素个数
 */
private int size;

/**
 * 默认构造函数，使用初始容量10构造一个空列表(无参数构造)
 * DEFAULTCAPACITY_EMPTY_ELEMENTDATA 为0，初始化为10，也就是说初始其实是空数组 当添加第一个元素的时候数组容量才变成10
 */
public ArrayList() {
    this.elementData = DEFAULTCAPACITY_EMPTY_ELEMENTDATA;
}

/**
 * 带初始容量参数的构造函数（用户可以在创建ArrayList对象时自己指定集合的初始大小）
 */
public ArrayList(int initialCapacity) {
    if (initialCapacity > 0) {// 初始容量大于0
        // 如果传入的参数大于0，创建initialCapacity大小的数组
        this.elementData = new Object[initialCapacity];
    } else if (initialCapacity == 0) {// 初始容量等于0
        // 如果传入的参数等于0，创建空数组
        this.elementData = EMPTY_ELEMENTDATA;
    } else {// 初始容量小于0，抛出异常
        throw new IllegalArgumentException("Illegal Capacity: "+ initialCapacity);
    }
}

/**
 * 构造一个包含指定集合的元素的列表，按照它们由集合的迭代器返回的顺序。
 */
 public ArrayList(Collection<? extends E> c) {
    elementData = c.toArray();
    if ((size = elementData.length) != 0) {
        // c.toArray might (incorrectly) not return Object[] (see 6260652)
        if (elementData.getClass() != Object[].class)
            elementData = Arrays.copyOf(elementData, size, Object[].class);
    } else {
        // replace with empty array.
        this.elementData = EMPTY_ELEMENTDATA;
    }
}
```

两个构造方法做的事情并不复杂，目的都是初始化底层数组 elementData。区别在于无参构造方法会将 elementData 初始化一个空数组，当真正对数组进行添加元素操作时，才真正分配容量。即向数组中添加第一个元素时，数组容量扩为 10。而有参的构造方法则会将 elementData 初始化为参数值大小（>= 0）的数组。

## 2.2 add()

```java
/**
 * 将指定的元素插入到列表的末尾
 */
public boolean add(E e) {
    // 添加元素之前，先调用ensureCapacityInternal方法检测是否需要扩容
    ensureCapacityInternal(size + 1);  // Increments modCount!!
    // 将新元素插入到数组尾部
    elementData[size++] = e;
    return true;
}

/**
 * 在元素序列 index 位置处插入
 */
public void add(int index, E element) {
    rangeCheckForAdd(index)
    // 添加元素之前，先调用ensureCapacityInternal方法检测是否需要扩容
    ensureCapacityInternal(size + 1);  // Increments modCount!!
    // 将 index 及其之后的所有元素都向后移一位
    System.arraycopy(elementData, index, elementData, index + 1,
                     size - index);
    // 将新元素插入至 index 处
    elementData[index] = element;
    size++;
}
```

将新元素插入至序列指定位置，需要先将该位置及其之后的元素都向后移动一位，为新元素腾出位置。这个操作的时间复杂度为`O(N)`，频繁移动元素可能会导致效率问题，特别是集合中元素数量较多时。在日常开发中，若非所需，我们应当尽量避免在大集合中调用第二个插入方法。

## 2.3 ensureCapacityInternal()

```java
// 扩容方法入口
private void ensureCapacityInternal(int minCapacity) {
  	// 调用 ensureExplicitCapacity()
    ensureExplicitCapacity(calculateCapacity(elementData, minCapacity));
}

// 计算最小容量
private static int calculateCapacity(Object[] elementData, int minCapacity) {
    if (elementData == DEFAULTCAPACITY_EMPTY_ELEMENTDATA) {
        // 获取默认的容量和传入参数的较大值
      	// 当要 add 进第1个元素时，minCapacity 为1，在 Math.max() 方法比较后，minCapacity 为10。
        return Math.max(DEFAULT_CAPACITY, minCapacity);
    }
    return minCapacity;
}

// 判断是否需要扩容
private void ensureExplicitCapacity(int minCapacity) {
    modCount++;
    // overflow-conscious code
    if (minCapacity - elementData.length > 0)
        // 调用 grow 方法进行扩容，调用此方法代表已经开始扩容了
        grow(minCapacity);
}
```

我们来仔细分析一下：

- 当我们要 add 进第 1 个元素到 ArrayList 时，elementData.length 为 0 （因为还是一个空的 list），因为执行了 `ensureCapacityInternal()` 方法 ，所以 minCapacity 此时为 10。此时，`minCapacity - elementData.length > 0`成立，所以会进入 `grow(minCapacity)` 方法。
- 当 add 第 2 个元素时，minCapacity 为 2，此时 elementData.length(容量)在添加第一个元素后扩容成 10 了。此时，`minCapacity - elementData.length > 0` 不成立，所以不会进入 （执行）`grow(minCapacity)` 方法。
- 添加第 3、4···到第 10 个元素时，依然不会执行 grow 方法，数组容量都为 10。

直到添加第 11 个元素，minCapacity(为 11)比 elementData.length（为 10）要大。进入 grow 方法进行扩容。

## 2.4 grow()

```java
/**
 * 要分配的最大数组大小
 */
private static final int MAX_ARRAY_SIZE = Integer.MAX_VALUE - 8;

/**
 * 扩容的核心方法
 */
private void grow(int minCapacity) {
    // oldCapacity 为旧容量， newCapacity 为新容量
    int oldCapacity = elementData.length;
    // 将oldCapacity 右移一位，其效果相当于oldCapacity /2，
    // 我们知道位运算的速度远远快于整除运算，整句运算式的结果就是将新容量更新为旧容量的1.5倍
    int newCapacity = oldCapacity + (oldCapacity >> 1);
    // 然后检查新容量是否大于最小需要容量，若还是小于最小需要容量，那么就直接把最小需要容量当作数组的新容量
    // 比如用户手动调用 public void ensureCapacity(int minCapacity) 时可能会出现
    if (newCapacity - minCapacity < 0)
        newCapacity = minCapacity;
   // 如果新容量大于 MAX_ARRAY_SIZE,进入(执行) hugeCapacity() 方法来比较 minCapacity 和 MAX_ARRAY_SIZE，
    if (newCapacity - MAX_ARRAY_SIZE > 0)
        newCapacity = hugeCapacity(minCapacity);
    // minCapacity is usually close to size, so this is a win:
  	// 旧数组拷贝到新数组
    elementData = Arrays.copyOf(elementData, newCapacity);
}

private static int hugeCapacity(int minCapacity) {
    if (minCapacity < 0) // overflow
        throw new OutOfMemoryError();
    // 如果 minCapacity 大于 MAX_ARRAY_SIZE，则新容量则为 Integer.MAX_VALUE，
   	// 否则，新容量大小则为 MAX_ARRAY_SIZE 即为 Integer.MAX_VALUE - 8。
    return (minCapacity > MAX_ARRAY_SIZE) ?
        Integer.MAX_VALUE :
        MAX_ARRAY_SIZE;
}
```

我们来仔细分析一下：

- 当 add 第 1 个元素时，oldCapacity 为 0，经比较后第一个 if 判断成立，newCapacity = minCapacity(为 10)。但是第二个 if 判断不会成立，即 newCapacity 不比 MAX_ARRAY_SIZE 大，则不会进入 `hugeCapacity` 方法。数组容量为 10，add 方法中 return true,size 增为 1。
- 当 add 第 11 个元素进入 grow 方法时，newCapacity 为 15，比 minCapacity（为 11）大，第一个 if 判断不成立。新容量没有大于数组最大 size，不会进入 hugeCapacity 方法。数组容量扩为 15，add 方法中 return true,size 增为 11。
- 以此类推······

## 2.5 remove()

```java
/**
 * 删除指定位置的元素
 */
public E remove(int index) {
    rangeCheck(index);

    modCount++;
    // 返回被删除的元素值
    E oldValue = elementData(index);

    int numMoved = size - index - 1;
    if (numMoved > 0)
        // 将 index+1 及之后的元素向前移动一位，覆盖被删除值
        System.arraycopy(elementData, index+1, elementData, index,
                         numMoved);
    // 将最后一个元素置空，并将 size 值减1                
    elementData[--size] = null; // clear to let GC do its work

    return oldValue;
}

@SuppressWarnings("unchecked")
E elementData(int index) {
    return (E) elementData[index];
}

/**
 * 删除指定元素，若元素重复，则只删除下标最小的元素。如果列表不包含该元素，则它不会更改。
 */
public boolean remove(Object o) {
    if (o == null) {
        for (int index = 0; index < size; index++)
            if (elementData[index] == null) {
                fastRemove(index);
                return true;
            }
    } else {
        // 遍历数组，查找要删除元素的位置
        for (int index = 0; index < size; index++)
            if (o.equals(elementData[index])) {
                fastRemove(index);
                return true;
            }
    }
    return false;
}

/**
 * 快速删除，不做边界检查，也不返回删除的元素值
 */
private void fastRemove(int index) {
    modCount++;
    int numMoved = size - index - 1;
    if (numMoved > 0)
        System.arraycopy(elementData, index+1, elementData, index,
                         numMoved);
    elementData[--size] = null; // clear to let GC do its work
}
```

## 2.6 trimToSize()

现在，考虑这样一种情况。我们往 ArrayList 插入大量元素后，又删除很多元素，此时底层数组（有效元素的后面的空间）会空闲处大量的空间。因为 ArrayList 没有自动缩容机制，导致底层数组大量的空闲空间不能被释放，造成浪费。对于这种情况，ArrayList 也提供了相应的处理方法，如下：

```java
/**
 * 将数组容量缩小至元素数量
 */
public void trimToSize() {
    modCount++;
    if (size < elementData.length) {
        elementData = (size == 0)
          ? EMPTY_ELEMENTDATA
          : Arrays.copyOf(elementData, size);
    }
}
```

## 2.7 contains()

```java
/**
 * 如果此列表包含指定的元素，则返回true
 */
public boolean contains(Object o) {
    // 调用 indexOf() ：返回此列表中指定元素的首次出现的索引，如果此列表不包含此元素，则为-1
    return indexOf(o) >= 0;
}

/**
 * 返回此列表中指定元素的首次出现的索引，如果此列表不包含此元素，则为-1
 */
public int indexOf(Object o) {
    if (o == null) {
        for (int i = 0; i < size; i++)
            if (elementData[i]==null)
                return i;
    } else {
        for (int i = 0; i < size; i++)
            // equals()方法比较
            if (o.equals(elementData[i]))
                return i;
    }
    return -1;
}

/**
 * 返回此列表中指定元素的最后一次出现的索引，如果此列表不包含元素，则返回-1。.
 */
public int lastIndexOf(Object o) {
    if (o == null) {
        for (int i = size-1; i >= 0; i--)
            if (elementData[i]==null)
                return i;
    } else {
        for (int i = size-1; i >= 0; i--)
            if (o.equals(elementData[i]))
                return i;
    }
    return -1;
}
```

## 2.8 addAll()

```java
/**
 * 按指定集合的 Iterator 返回的顺序将指定集合中的所有元素追加到此列表的末尾
 */
public boolean addAll(Collection<? extends E> c) {
    Object[] a = c.toArray();
    int numNew = a.length;
    ensureCapacityInternal(size + numNew);  // Increments modCount
    System.arraycopy(a, 0, elementData, size, numNew);
    size += numNew;
    return numNew != 0;
}

/**
 * 将指定集合中的所有元素插入到此列表中，从指定的位置开始
 */
public boolean addAll(int index, Collection<? extends E> c) {
    rangeCheckForAdd(index);

    Object[] a = c.toArray();
    int numNew = a.length;
    ensureCapacityInternal(size + numNew);  // Increments modCount

    int numMoved = size - index;
    if (numMoved > 0)
        System.arraycopy(elementData, index, elementData, index + numNew,
                         numMoved);

    System.arraycopy(a, 0, elementData, index, numNew);
    size += numNew;
    return numNew != 0;
}
```

## 2.9 removeRange()

```java
/**
 * 从此列表中删除所有索引为 fromIndex（含）和 toIndex 之间的元素。
 * 将任何后续元素移动到左侧（减少其索引）。
 */
protected void removeRange(int fromIndex, int toIndex) {
    modCount++;
    int numMoved = size - toIndex;
    System.arraycopy(elementData, toIndex, elementData, fromIndex,
                     numMoved);

    // clear to let GC do its work
    int newSize = size - (toIndex-fromIndex);
    for (int i = newSize; i < size; i++) {
        elementData[i] = null;
    }
    size = newSize;
}
```

## 2.10 iterator()

```java
/**
 * 从列表中的指定位置开始，返回列表中的元素（按正确顺序）的列表迭代器。
 * 指定的索引表示初始调用将返回的第一个元素为 next。 初始调用previous将返回指定索引减1的元素。
 * 返回的列表迭代器是fail-fast 。
 */
public ListIterator<E> listIterator(int index) {
    if (index < 0 || index > size)
        throw new IndexOutOfBoundsException("Index: "+index);
    return new ListItr(index);
}

/**
 * 返回列表中的列表迭代器（按适当的顺序）。
 * 返回的列表迭代器是fail-fast 。
 */
public ListIterator<E> listIterator() {
    return new ListItr(0);
}

/**
 * 以正确的顺序返回该列表中的元素的迭代器。
 * 返回的迭代器是fail-fast 。
 */
public Iterator<E> iterator() {
    return new Itr();
}

```

## 2.11 toArray()

```java
/**
 * 以正确的顺序（从第一个到最后一个元素）返回一个包含此列表中所有元素的数组。
 * 返回的数组将是“安全的”，因为该列表不保留对它的引用。（换句话说，这个方法必须分配一个新的数组）。
 * 因此，调用者可以自由地修改返回的数组。 此方法充当基于阵列和基于集合的API之间的桥梁。
 */
public Object[] toArray() {
    return Arrays.copyOf(elementData, size);
}

/**
 * 以正确的顺序返回一个包含此列表中所有元素的数组（从第一个到最后一个元素）;
 * 返回的数组的运行时类型是指定数组的运行时类型。 如果列表适合指定的数组，则返回其中。
 * 否则，将为指定数组的运行时类型和此列表的大小分配一个新数组。
 * 如果列表适用于指定的数组，其余空间（即数组的列表数量多于此元素），则紧跟在集合结束后的数组中的元素设置为null 。
 * （这仅在调用者知道列表不包含任何空元素的情况下才能确定列表的长度。）
 */
public <T> T[] toArray(T[] a) {
    if (a.length < size)
        // Make a new array of a's runtime type, but my contents:
        // 新建一个运行时类型的数组，但是仍然是ArrayList数组的内容 
        return (T[]) Arrays.copyOf(elementData, size, a.getClass());
    // 调用System提供的arraycopy()方法实现数组之间的复制    
    System.arraycopy(elementData, 0, a, 0, size);
    if (a.length > size)
        a[size] = null;
    return a;
}
```

## 2.12 其他

```java
/**
 * 返回此列表中的元素数。
 */
public int size() {
    return size;
}

/**
 * 如果此列表不包含元素，则返回 true 。
 */
public boolean isEmpty() {
    //注意 =和 == 的区别
    return size == 0;
}

/**
 * 返回此ArrayList实例的浅拷贝。（元素本身不被复制。）
 */
public Object clone() {
    try {
        ArrayList<?> v = (ArrayList<?>) super.clone();
        // Arrays.copyOf功能是实现数组的复制，返回复制后的数组。参数是被复制的数组和复制的长度
        v.elementData = Arrays.copyOf(elementData, size);
        v.modCount = 0;
        return v;
    } catch (CloneNotSupportedException e) {
        // 这不应该发生，因为我们是可以克隆的
        throw new InternalError(e);
    }
}

/**
 * 用指定的元素替换此列表中指定位置的元素。
 */
public E set(int index, E element) {
    // 对index进行界限检查
    rangeCheck(index);

    E oldValue = elementData(index);
    elementData[index] = element;
    // 返回原来在这个位置的元素
    return oldValue;
}

/**
 * 从列表中删除所有元素。
 */
public void clear() {
    modCount++;

    // 把数组中所有的元素的值设为null
    for (int i = 0; i < size; i++)
        elementData[i] = null;

    size = 0;
}

/**
 * 检查给定的索引是否在范围内。
 */
private void rangeCheck(int index) {
    if (index >= size)
        throw new IndexOutOfBoundsException(outOfBoundsMsg(index));
}

/**
 * add和addAll使用的rangeCheck的一个版本
 */
private void rangeCheckForAdd(int index) {
    if (index > size || index < 0)
        throw new IndexOutOfBoundsException(outOfBoundsMsg(index));
}

/**
 * 返回IndexOutOfBoundsException细节信息
 */
private String outOfBoundsMsg(int index) {
    return "Index: "+index+", Size: "+size;
}

/**
 * 从此列表中删除指定集合中包含的所有元素。
 */
public boolean removeAll(Collection<?> c) {
    Objects.requireNonNull(c);
    //如果此列表被修改则返回true
    return batchRemove(c, false);
}

/**
 * 仅保留此列表中包含在指定集合中的元素。
 *换句话说，从此列表中删除其中不包含在指定集合中的所有元素。
 */
public boolean retainAll(Collection<?> c) {
    Objects.requireNonNull(c);
    return batchRemove(c, true);
}
```

# 3. 其他细节

## 3.1 快速失败机制

在 Java 集合框架中，很多类都实现了快速失败机制。该机制被触发时，会抛出并发修改异常`ConcurrentModificationException`，这个异常大家在平时开发中多多少少应该都碰到过。关于快速失败机制，ArrayList 的注释里对此做了解释，这里引用一下：

> The iterators returned by this class’s iterator() and listIterator(int) methods are fail-fast if the list is structurally modified at any time after the iterator is created, in any way except through the iterator’s own ListIterator remove() or ListIterator add(Object) methods, the iterator will throw a ConcurrentModificationException. Thus, in the face of concurrent modification, the iterator fails quickly and cleanly, rather than risking arbitrary, non-deterministic behavior at an undetermined time in the future.

上面注释大致意思是，ArrayList 迭代器中的方法都是均具有快速失败的特性，当遇到并发修改的情况时，迭代器会快速失败，以避免程序在将来不确定的时间里出现不确定的行为。

以上就是 Java 集合框架中引入快速失败机制的原因，并不难理解，这里不多说了。

## 3.2 关于遍历时删除

遍历时删除是一个不正确的操作，即使有时候代码不出现异常，但执行逻辑也会出现问题。关于这个问题，阿里巴巴 Java 开发手册里也有所提及。这里引用一下：

> 【强制】不要在 foreach 循环里进行元素的 remove/add 操作。remove 元素请使用 Iterator 方式，如果并发操作，需要对 Iterator 对象加锁。

相关代码（稍作修改）如下：

```java
List<String> a = new ArrayList<String>();
    a.add("1");
    a.add("2");
    for (String temp : a) {
        System.out.println(temp);
        if("1".equals(temp)){
            a.remove(temp);
        }
    }
}
```

相信有些朋友应该看过这个，并且也执行过上面的程序。上面的程序执行起来不会虽不会出现异常，但代码执行逻辑上却有问题，只不过这个问题隐藏的比较深。我们把 temp 变量打印出来，会发现只打印了数字`1`，`2`没打印出来。初看这个执行结果确实很让人诧异，不明原因。如果死抠上面的代码，我们很难找出原因，此时需要稍微转换一下思路。我们都知道 Java 中的 foreach 是个语法糖，编译成字节码后会被转成用迭代器遍历的方式。所以我们可以把上面的代码转换一下，等价于下面形式：

```java
List<String> a = new ArrayList<>();
a.add("1");
a.add("2");
Iterator<String> it = a.iterator();
while (it.hasNext()) {
    String temp = it.next();
    System.out.println("temp: " + temp);
    if("1".equals(temp)){
        a.remove(temp);
    }
}
```

这个时候，我们再去分析一下 ArrayList 的迭代器源码就能找出原因。

```java
private class Itr implements Iterator<E> {
    int cursor;       // index of next element to return
    int lastRet = -1; // index of last element returned; -1 if no such
    int expectedModCount = modCount;

    public boolean hasNext() {
        return cursor != size;
    }

    
    public E next() {
        // 并发修改检测，检测不通过则抛出异常
        checkForComodification();
        int i = cursor;
        if (i >= size)
            throw new NoSuchElementException();
        Object[] elementData = ArrayList.this.elementData;
        if (i >= elementData.length)
            throw new ConcurrentModificationException();
        cursor = i + 1;
        return (E) elementData[lastRet = i];
    }
    
    final void checkForComodification() {
        if (modCount != expectedModCount)
            throw new ConcurrentModificationException();
    }
    
    // 省略不相关的代码
}
```

我们一步一步执行一下上面的代码，第一次进入 while 循环时，一切正常，元素 1 也被删除了。但删除元素 1 后，就无法再进入 while 循环，此时 it.hasNext() 为 false。原因是删除元素 1 后，元素计数器 size = 1，而迭代器中的 cursor 也等于 1，从而导致 it.hasNext() 返回false。归根结底，上面的代码段没抛异常的原因是，循环提前结束，导致 next 方法没有机会抛异常。不信的话，大家可以把代码稍微修改一下，即可发现问题：

```java
List<String> a = new ArrayList<>();
a.add("1");
a.add("2");
a.add("3");
Iterator<String> it = a.iterator();
while (it.hasNext()) {
    String temp = it.next();
    System.out.println("temp: " + temp);
    if("1".equals(temp)){
        a.remove(temp);
    }
}
```

以上是关于遍历时删除的分析，在日常开发中，我们要避免上面的做法。正确的做法使用迭代器提供的删除方法，而不是直接删除。

## 3.3 System.arraycopy() 和 Arrays.copyOf()

阅读源码的话，我们就会发现 ArrayList 中大量调用了这两个方法。比如：我们上面讲的扩容操作以及`add(int index, E element)`、`toArray()` 等方法中都用到了该方法！

### 3.3.1 System.arraycopy()

```java
// 我们发现 arraycopy 是一个 native 方法,接下来我们解释一下各个参数的具体意义
/**
* 复制数组
* @param src 源数组
* @param srcPos 源数组中的起始位置
* @param dest 目标数组
* @param destPos 目标数组中的起始位置
* @param length 要复制的数组元素的数量
*/
public static native void arraycopy(Object src,  int srcPos,
                                    Object dest, int destPos,
                                    int length);
```

场景：

```java
/**
 * 在此列表中的指定位置插入指定的元素。
 * 先调用 rangeCheckForAdd 对index进行界限检查；然后调用 ensureCapacityInternal 方法保证capacity足够大；
 * 再将从index开始之后的所有成员后移一个位置；将element插入index位置；最后size加1。
 */
public void add(int index, E element) {
    rangeCheckForAdd(index);

    ensureCapacityInternal(size + 1);  // Increments modCount!!
    // arraycopy()方法实现数组自己复制自己
    // elementData:源数组; 
  	// index:源数组中的起始位置;
  	// elementData：目标数组；
  	// index + 1：目标数组中的起始位置； 
  	// size - index：要复制的数组元素的数量；
    System.arraycopy(elementData, index, elementData, index + 1, size - index);
    elementData[index] = element;
    size++;
}
```

### 3.3.2 Arrays.copyOf()

```java
public static int[] copyOf(int[] original, int newLength) {
    // 申请一个新的数组
    int[] copy = new int[newLength];
		// 调用System.arraycopy,将源数组中的数据进行拷贝,并返回新的数组
    System.arraycopy(original, 0, copy, 0,
                     Math.min(original.length, newLength));
    return copy;
}
```

场景：

```java
/**
 * 以正确的顺序返回一个包含此列表中所有元素的数组（从第一个到最后一个元素）; 返回的数组的运行时类型是指定数组的运行时类型。
 */
public Object[] toArray() {
	  //elementData：要复制的数组；size：要复制的长度
    return Arrays.copyOf(elementData, size);
}
```

### 3.3.3 两者联系和区别

**联系：**

看两者源代码可以发现 `copyOf()`内部实际调用了 `System.arraycopy()` 方法

**区别：**

`arraycopy()` 需要目标数组，将原数组拷贝到你自己定义的数组里或者原数组，而且可以选择拷贝的起点和长度以及放入新数组中的位置 ，而`copyOf()` 是系统自动在内部新建一个数组，并返回该数组。

## 4. 总结

看到这里，大家对 ArrayList 应该又有了些新的认识。ArrayList 是一个比较基础的集合类，用的很多。它的结构简单（本质上就是一个变长的数组），实现上也不复杂。尽管如此，本文还是啰里啰嗦讲了很多，大家见谅。好了，本文到这里就结束了，感谢阅读。

# 参考

[田小波的技术博客-ArrayList源码分析](https://www.tianxiaobo.com/2018/01/28/ArrayList%E6%BA%90%E7%A0%81%E5%88%86%E6%9E%90/)

[JavaGuide-ArrayList源码+扩容机制分析](https://snailclimb.gitee.io/javaguide/#/docs/java/collection/ArrayList%E6%BA%90%E7%A0%81+%E6%89%A9%E5%AE%B9%E6%9C%BA%E5%88%B6%E5%88%86%E6%9E%90)

