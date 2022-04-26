　　Guava引进了JDK里没有的，但是非常有用的一些新的集合类型。所有这些新集合类型都能和JDK里的集合平滑集成。Guava集合非常精准地实现了JDK定义的接口。Guava中定义的新集合有：
　　Multiset
　　SortedMultiset
　　Multimap
　　ListMultimap
　　SetMultimap
　　BiMap
　　ClassToInstanceMap
　　Table

　　**Multiset集合**

　　Multiset是什么？顾名思义，Multiset和Set的区别就是可以保存多个相同的对象。在JDK中，List和Set有一个基本的区别，就是List可以包含多个相同对象，且是有顺序的，而Set不能有重复，且不保证顺序（有些实现有顺序，例如LinkedHashSet和SortedSet等）所以Multiset占据了List和Set之间的一个灰色地带：允许重复，但是不保证顺序。
　　常见使用场景：Multiset有一个有用的功能，就是跟踪每种对象的数量，所以你可以用来进行数字统计。 常见的普通实现方式如下：

```java
@Test
public void testWordCount() {
    String strWorld = "wer|dffd|ddsa|dfd|dreg|de|dr|ce|ghrt|cf|gt|ser|tg|ghrt|cf|gt|" +
            "ser|tg|gt|kldf|dfg|vcd|fg|gt|ls|lser|dfr|wer|dffd|ddsa|dfd|dreg|de|dr|" +
            "ce|ghrt|cf|gt|ser|tg|gt|kldf|dfg|vcd|fg|gt|ls|lser|dfr";
    String[] words = strWorld.split("\\|");
    Map<String, Integer> countMap = new HashMap<>();
    for (String word : words) {
        countMap.merge(word, 1, Integer::sum);
    }
    System.out.println("countMap：");
    for (String key : countMap.keySet()) {
        System.out.println(key + " count：" + countMap.get(key));
    }
}
```

　　上面的代码实现的功能非常简单，用于记录字符串在数组中出现的次数。这种场景在实际的开发过程还是容易经常出现的，如果使用实现Multiset接口的具体类就可以很容易实现以上的功能需求：

```java
@Test
public void testMultsetWordCount() {
    String strWorld = "wer|dfd|dd|dfd|dda|de|dr";
    String[] words = strWorld.split("\\|");
    Multiset<String> wordsMultiset = HashMultiset.create();
    wordsMultiset.addAll(Arrays.asList(words));
    for (String key : wordsMultiset.elementSet()) {
        System.out.println(key + " count：" + wordsMultiset.count(key));
    }
}
```

　　**Multiset主要方法**

　　Multiset接口定义的接口主要有：
　　　　add(E element) :向其中添加单个元素
　　　　add(E element,int occurrences) : 向其中添加指定个数的元素
　　　　count(Object element) : 返回给定参数元素的个数
　　　　remove(E element) : 移除一个元素，其count值 会响应减少
　　　　remove(E element,int occurrences): 移除相应个数的元素
　　　　elementSet() : 将不同的元素放入一个Set中
　　　　entrySet(): 类似与Map.entrySet 返回Set<Multiset.Entry>。包含的Entry支持使用getElement()和getCount()
　　　　setCount(E element ,int count): 设定某一个元素的重复次数
　　　　setCount(E element,int oldCount,int newCount): 将符合原有重复个数的元素修改为新的重复次数
　　　　retainAll(Collection c) : 保留出现在给定集合参数的所有的元素
　　　　removeAll(Collectionc) : 去除出现给给定集合参数的所有的元素

　　常用方法实例：

```java
@Test
public void testMultsetWordCase() {
    String strWorld = "wer|dfd|dd|dfd|dda|de|dr";
    String[] words = strWorld.split("\\|");
    Multiset<String> wordsMultiset = HashMultiset.create();
    wordsMultiset.addAll(Arrays.asList(words));

    //System.out.println("wordsMultiset："+wordsMultiset);

    for (String key : wordsMultiset.elementSet()) {
        System.out.println(key + " count：" + wordsMultiset.count(key));
    }

    if (!wordsMultiset.contains("peida")) {
        wordsMultiset.add("peida", 2);
    }
    System.out.println("============================================");
    for (String key : wordsMultiset.elementSet()) {
        System.out.println(key + " count：" + wordsMultiset.count(key));
    }


    if (wordsMultiset.contains("peida")) {
        wordsMultiset.setCount("peida", 23);
    }

    System.out.println("============================================");
    for (String key : wordsMultiset.elementSet()) {
        System.out.println(key + " count：" + wordsMultiset.count(key));
    }

    if (wordsMultiset.contains("peida")) {
        wordsMultiset.setCount("peida", 23, 45);
    }

    System.out.println("============================================");
    for (String key : wordsMultiset.elementSet()) {
        System.out.println(key + " count：" + wordsMultiset.count(key));
    }

    if (wordsMultiset.contains("peida")) {
        wordsMultiset.setCount("peida", 44, 67);
    }

    System.out.println("============================================");
    for (String key : wordsMultiset.elementSet()) {
        System.out.println(key + " count：" + wordsMultiset.count(key));
    }
}
```

　　输出：

```java
dd count：1
dda count：1
de count：1
dfd count：2
wer count：1
dr count：1
============================================
dd count：1
dda count：1
de count：1
dfd count：2
wer count：1
peida count：2
dr count：1
============================================
dd count：1
dda count：1
de count：1
dfd count：2
wer count：1
peida count：23
dr count：1
============================================
dd count：1
dda count：1
de count：1
dfd count：2
wer count：1
peida count：45
dr count：1
============================================
dd count：1
dda count：1
de count：1
dfd count：2
wer count：1
peida count：45
dr count：1
```

　　说明：setCount(E element,int oldCount,int newCount): 方法，如果传入的oldCount和element的不一致的时候，是不能将element的count设置成newCount的。需要注意。

　　**Multiset不是Map**

　　需要注意的是Multiset不是一个Map<E,Integer>，尽管Multiset提供一部分类似的功能实现。其它值得关注的差别有:
　　Multiset中的元素的重复个数只会是正数，且最大不会超过Integer.MAX_VALUE。设定计数为0的元素将不会出现multiset中，也不会出现 elementSet() 和 entrySet() 的返回结果中。
　　multiset.size() 方法返回的是所有的元素的总和，相当于是将所有重复的个数相加。如果需要知道每个元素的个数可以使用elementSet().size()得到。(因而调用add(E)方法会是multiset.size()增加1)。
　　multiset.iterator() 会循环迭代每一个出现的元素，迭代的次数与multiset.size()相同。 iterates over each occurrence of each element, so the length of the iteration is equal to multiset.size().
　　Multiset 支持添加、移除多个元素以及重新设定元素的个数。执行setCount(element,0)相当于移除multiset中所有的相同元素。
　　调用multiset.count(elem)方法时，如果该元素不在该集中，那么返回的结果只会是0。

　　**Multiset的实现**　

　　Guava提供了Multiset的多种实现，这些实现基本对应了JDK中Map的实现：

| **Map**           | **Corresponding Multiset** | **Supports null elements**   |
| ----------------- | -------------------------- | ---------------------------- |
| HashMap           | HashMultiset               | Yes                          |
| TreeMap           | TreeMultiset               | Yes (if the comparator does) |
| LinkedHashMap     | LinkedHashMultiset         | Yes                          |
| ConcurrentHashMap | ConcurrentHashMultiset     | No                           |
| ImmutableMap      | ImmutableMultiset          | No                           |



## 参考

[Guava学习笔记：Guava新增集合类型-Multiset](https://www.cnblogs.com/peida/p/Guava_ImmutableCollections.html)
