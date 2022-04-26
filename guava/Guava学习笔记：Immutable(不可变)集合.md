​		不可变集合，顾名思义就是说集合是不可被修改的。集合的数据项是在创建的时候提供，并且在整个生命周期中都不可改变。

　　为什么要用immutable对象？immutable对象有以下的优点：
　　　　1.对不可靠的客户代码库来说，它使用安全，可以在未受信任的类库中安全的使用这些对象
　　　　2.线程安全的：immutable对象在多线程下安全，没有竞态条件
　　　　3.不需要支持可变性, 可以尽量节省空间和时间的开销. 所有的不可变集合实现都比可变集合更加有效的利用内存 (analysis)
　　　　4.可以被使用为一个常量，并且期望在未来也是保持不变的

　　immutable对象可以很自然地用作常量，因为它们天生就是不可变的对于immutable对象的运用来说，它是一个很好的防御编程（defensive programming）的技术实践。

　　**JDK中实现immutable集合**

　　在JDK中提供了Collections.unmodifiableXXX系列方法来实现不可变集合, 但是存在一些问题，下面我们先看一个具体实例：

```java
import java.util.ArrayList;
import java.util.Arrays;
import java.util.Collections;
import java.util.List;
import org.junit.Test;

public class ImmutableTest {
    @Test
    public void testJDKImmutable(){                                                                                                                                                                                                                                    
        List<String> list=new ArrayList<>();                                                                               
        list.add("a");                                                                                                           
        list.add("b");                                                                                                           
        list.add("c");
        
        System.out.println(list);
        
        List<String> unmodifiableList=Collections.unmodifiableList(list); 
        
        System.out.println(unmodifiableList);
        
        List<String> unmodifiableList1=Collections.unmodifiableList(Arrays.asList("a","b","c")); 
        System.out.println(unmodifiableList1);
        
        String temp=unmodifiableList.get(1);
        System.out.println("unmodifiableList [0]："+temp);
                
        list.add("baby");
        System.out.println("list add a item after list:"+list);
        System.out.println("list add a item after unmodifiableList:"+unmodifiableList);
        
        unmodifiableList1.add("bb");
        System.out.println("unmodifiableList add a item after list:"+unmodifiableList1);
        
        unmodifiableList.add("cc");
        System.out.println("unmodifiableList add a item after list:"+unmodifiableList);        
    }
}
```

​		输出：

```java
[a, b, c]
[a, b, c]
[a, b, c]
unmodifiableList [0]：b
list add a item after list:[a, b, c, baby]
list add a item after unmodifiableList1:[a, b, c, baby]


java.lang.UnsupportedOperationException
	at java.util.Collections$UnmodifiableCollection.add(Collections.java:1057)
```

​		说明：Collections.unmodifiableList实现的不是真正的不可变集合，当原始集合修改后，不可变集合也发生变化。不可变集合不可以修改集合数据，当强制修改时会报错，实例中的最后两个add会直接抛出不可修改的错误。

　　总结一下JDK的Collections.unmodifiableXXX方法实现不可变集合的一些问题：

　　1.它用起来笨拙繁琐你不得不在每个防御性编程拷贝的地方用这个方法
　　2.它不安全：如果有对象reference原始的被封装的集合类，这些方法返回的集合也就不是正真的不可改变。
　　3.效率低：因为它返回的数据结构本质仍旧是原来的集合类，所以它的操作开销，包括并发下修改检查，hash table里的额外数据空间都和原来的集合是一样的。

　　**Guava的immutable集合**

　　Guava提供了对JDK里标准集合类里的immutable版本的简单方便的实现，以及Guava自己的一些专门集合类的immutable实现。当你不希望修改一个集合类，或者想做一个常量集合类的时候，使用immutable集合类就是一个最佳的编程实践。

注意：每个Guava immutable集合类的实现都拒绝null值。我们做过对Google内部代码的全面的调查，并且发现只有5%的情况下集合类允许null值，而95%的情况下都拒绝null值。万一你真的需要能接受null值的集合类，你可以考虑用Collections.unmodifiableXXX。

　　Immutable集合使用方法：
　　一个immutable集合可以有以下几种方式来创建：
　　1.用copyOf方法, 譬如, ImmutableSet.copyOf(set)
　　2.使用of方法，譬如，ImmutableSet.of("a", "b", "c")或者ImmutableMap.of("a", 1, "b", 2)
　　3.使用Builder类

　　实例：

```java
@Test
public void testGuavaImmutable() {

    List<String> list = new ArrayList<>();
    list.add("a");
    list.add("b");
    list.add("c");
    System.out.println("list：" + list);

    ImmutableList<String> imlist = ImmutableList.copyOf(list);
    System.out.println("imlist：" + imlist);

    ImmutableList<String> imOflist = ImmutableList.of("peida", "jerry", "harry");
    System.out.println("imOflist：" + imOflist);

    ImmutableSortedSet<String> imSortSet = ImmutableSortedSet.of("a", "b", "c", "a", "d", "b");
    System.out.println("imSortSet：" + imSortSet);

    list.add("baby");
    System.out.println("list add a item after list:" + list);
    System.out.println("list add a item after imlist:" + imlist);

    ImmutableSet<Color> imColorSet =
            ImmutableSet.<Color>builder()
                    .add(new Color(0, 255, 255))
                    .add(new Color(0, 191, 255))
                    .build();

    System.out.println("imColorSet:" + imColorSet);
}
```

　　输出：

```java
list：[a, b, c]
imlist：[a, b, c]
imOflist：[peida, jerry, harry]
imSortSet：[a, b, c, d]
list add a item after list:[a, b, c, baby]
list add a item after imlist:[a, b, c]
imColorSet:[ImmutableTest.Color(r=0, g=255, b=255), ImmutableTest.Color(r=0, g=191, b=255)]
```

​		对于排序的集合来说有例外，因为元素的顺序在构建集合的时候就被固定下来了。譬如，ImmutableSet.of("a", "b", "c", "a", "d", "b")，对于这个集合的遍历顺序来说就是"a", "b", "c", "d"。

　　**更智能的copyOf**

　　copyOf方法比你想象的要智能，ImmutableXXX.copyOf会在合适的情况下避免拷贝元素的操作－先忽略具体的细节，但是它的实现一般都是很“智能”的。譬如：

```java
@Test
public void testCotyOf() {
    ImmutableSet<String> imSet = ImmutableSet.of("peida", "jerry", "harry", "lisa");
    System.out.println("imSet：" + imSet);
    ImmutableList<String> imlist = ImmutableList.copyOf(imSet);
    System.out.println("imlist：" + imlist);
    ImmutableSortedSet<String> imSortSet = ImmutableSortedSet.copyOf(imSet);
    System.out.println("imSortSet：" + imSortSet);

    List<String> list = new ArrayList<>();
    for (int i = 0; i < 20; i++) {
        list.add(i + "x");
    }
    System.out.println("list：" + list);
    ImmutableList<String> imInfolist = ImmutableList.copyOf(list.subList(2, 18));
    System.out.println("imInfolist：" + imInfolist);
    int imInfolistSize = imInfolist.size();
    System.out.println("imInfolistSize：" + imInfolistSize);
    ImmutableSet<String> imInfoSet = ImmutableSet.copyOf(imInfolist.subList(2, imInfolistSize - 3));
    System.out.println("imInfoSet：" + imInfoSet);
}
```

　　输出：　

```java
imSet：[peida, jerry, harry, lisa]
imlist：[peida, jerry, harry, lisa]
imSortSet：[harry, jerry, lisa, peida]
list：[0x, 1x, 2x, 3x, 4x, 5x, 6x, 7x, 8x, 9x, 10x, 11x, 12x, 13x, 14x, 15x, 16x, 17x, 18x, 19x]
imInfolist：[2x, 3x, 4x, 5x, 6x, 7x, 8x, 9x, 10x, 11x, 12x, 13x, 14x, 15x, 16x, 17x]
imInfolistSize：16
imInfoSet：[4x, 5x, 6x, 7x, 8x, 9x, 10x, 11x, 12x, 13x, 14x]
```

　　在这段代码中，ImmutableList.copyOf(imSet)会智能地返回时间复杂度为常数的ImmutableSet的imSet.asList()。
　　一般来说，ImmutableXXX.copyOf(ImmutableCollection)会避免线性复杂度的拷贝操作。如在以下情况：
　　这个操作有可能就利用了被封装数据结构的常数复杂度的操作。但例如ImmutableSet.copyOf(list)不能在常数复杂度下实现。
　　这样不会导致内存泄漏－例如，你有个ImmutableList\<String\> imInfolist，然后你显式操作ImmutableList.copyOf(imInfolist.subList(0, 10))。这样的操作可以避免意外持有不再需要的在hugeList里元素的reference。
　　它不会改变集合的语意－像ImmutableSet.copyOf(myImmutableSortedSet)这样的显式拷贝操作，因为在ImmutableSet里的hashCode()和equals()的含义和基于comparator的ImmutableSortedSet是不同的。
　　这些特性有助于最优化防御性编程的性能开销。

　　**asList方法**

　　所有的immutable集合都以asList()的形式提供了ImmutableList视图（view）。譬如，你把数据放在ImmutableSortedSet，你就可以调用sortedSet.asList().get(k)来取得前k个元素的集合。
　　返回的ImmutableList常常是个常数复杂度的视图，而不是一个真的拷贝。也就是说，这个返回集合比一般的List更智能－譬如，它会更高效地实现contains这样的方法。

　　实例：

```java
@Test
public void testAsList() {
    ImmutableList<String> imList = ImmutableList.of("peida", "jerry", "harry", "lisa", "jerry");
    System.out.println("imList：" + imList);
    ImmutableSortedSet<String> imSortList = ImmutableSortedSet.copyOf(imList);
    System.out.println("imSortList：" + imSortList);
    System.out.println("imSortList as list：" + imSortList.asList());
}
```

　　输出：

```java
imList：[peida, jerry, harry, lisa, jerry]
imSortList：[harry, jerry, lisa, peida]
imSortList as list：[harry, jerry, lisa, peida]
```

　　**Guava集合和不可变对应关系**

| **可变集合类型**       | **可变集合源：JDK or Guava?** | **Guava不可变集合**         |
| ---------------------- | ----------------------------- | --------------------------- |
| Collection             | JDK                           | ImmutableCollection         |
| List                   | JDK                           | ImmutableList               |
| Set                    | JDK                           | ImmutableSet                |
| SortedSet/NavigableSet | JDK                           | ImmutableSortedSet          |
| Map                    | JDK                           | ImmutableMap                |
| SortedMap              | JDK                           | ImmutableSortedMap          |
| Multiset               | Guava                         | ImmutableMultiset           |
| SortedMultiset         | Guava                         | ImmutableSortedMultiset     |
| Multimap               | Guava                         | ImmutableMultimap           |
| ListMultimap           | Guava                         | ImmutableListMultimap       |
| SetMultimap            | Guava                         | ImmutableSetMultimap        |
| BiMap                  | Guava                         | ImmutableBiMap              |
| ClassToInstanceMap     | Guava                         | ImmutableClassToInstanceMap |
| Table                  | Guava                         | ImmutableTable              |



## 参考

[Guava学习笔记：Immutable(不可变)集合](https://www.cnblogs.com/peida/p/Guava_ImmutableCollections.html)
