　　BiMap提供了一种新的集合类型，它提供了key和value的双向关联的数据结构。
　　通常情况下，我们在使用Java的Map时，往往是通过key来查找value的，但是如果出现下面一种场景的情况，我们就需要额外编写一些代码了。首先来看下面一种表示标识序号和文件名的map结构。

```java
@Test
public void logMapTest() {
    Map<Integer, String> logfileMap = Maps.newHashMap();
    logfileMap.put(1, "a.log");
    logfileMap.put(2, "b.log");
    logfileMap.put(3, "c.log");
    System.out.println("logfileMap:" + logfileMap);
}
```

　　当我们需要通过序号查找文件名，很简单。但是如果我们需要通过文件名查找其序号时，我们就不得不遍历map了。当然我们还可以编写一段Map倒转的方法来帮助实现倒置的映射关系。

```java
/**
 * 逆转Map的key和value
 *
 * @param <S>
 * @param <T>
 * @param map
 * @return
 */
public static <S, T> Map<T, S> getInverseMap(Map<S, T> map) {
    Map<T, S> inverseMap = new HashMap<T, S>();
    for (Map.Entry<S, T> entry : map.entrySet()) {
        inverseMap.put(entry.getValue(), entry.getKey());
    }
    return inverseMap;
}

@Test
public void logMapTest2() {
    Map<Integer, String> logfileMap = Maps.newHashMap();
    logfileMap.put(1, "a.log");
    logfileMap.put(2, "b.log");
    logfileMap.put(3, "c.log");

    System.out.println("logfileMap:" + logfileMap);

    Map<String, Integer> logfileInverseMap = getInverseMap(logfileMap);

    System.out.println("logfileInverseMap:" + logfileInverseMap);
}
```

　　上面的代码可以帮助我们实现map倒转的要求，但是还有一些我们需要考虑的问题:
   　1. 如何处理重复的value的情况。不考虑的话，反转的时候就会出现覆盖的情况。
            　2. 如果在反转的map中增加一个新的key，倒转前的map是否需要更新一个值呢？

      　　　在这种情况下需要考虑的业务以外的内容就增加了，编写的代码也变得不那么易读了。这时我们就可以考虑使用Guava中的BiMap了。

　　**Bimap**

　　Bimap使用非常的简单，对于上面的这种使用场景，我们可以用很简单的代码就实现了：

```java
@Test
public void bimapTest() {
    BiMap<Integer, String> logfileMap = HashBiMap.create();
    logfileMap.put(1, "a.log");
    logfileMap.put(2, "b.log");
    logfileMap.put(3, "c.log");
    System.out.println("logfileMap:" + logfileMap);
    BiMap<String, Integer> filelogMap = logfileMap.inverse();
    System.out.println("filelogMap:" + filelogMap);
}
```

　　**Bimap数据的强制唯一性**

　　在使用BiMap时，会要求Value的唯一性。如果value重复了则会抛出错误：java.lang.IllegalArgumentException，例如：

```java
@Test
public void bimapTest2() {
    BiMap<Integer, String> logfileMap = HashBiMap.create();
    logfileMap.put(1, "a.log");
    logfileMap.put(2, "b.log");
    logfileMap.put(3, "c.log");
    logfileMap.put(4, "d.log");
    logfileMap.put(5, "d.log");
}
```

　　logfileMap.put(5,"d.log") 会抛出java.lang.IllegalArgumentException: value already present: d.log的错误。如果我们确实需要插入重复的value值，那可以选择forcePut方法。但是我们需要注意的是前面的key也会被覆盖了。

```java
@Test
public void bimapTestForcePut() {
    BiMap<Integer, String> logfileMap = HashBiMap.create();
    logfileMap.put(1, "a.log");
    logfileMap.put(2, "b.log");
    logfileMap.put(3, "c.log");

    logfileMap.put(4, "d.log");
    logfileMap.forcePut(5, "d.log");
    System.out.println("logfileMap:" + logfileMap);
}
```

​		输出：

```java
logfileMap:{1=a.log, 2=b.log, 3=c.log, 5=d.log}
```

​		**理解inverse方法**
　　inverse方法会返回一个反转的BiMap，但是注意这个反转的map不是新的map对象，它实现了一种视图关联，这样你对于反转后的map的所有操作都会影响原先的map对象。例如：

```java
@Test
public void bimapTestInverse() {
    BiMap<Integer, String> logfileMap = HashBiMap.create();
    logfileMap.put(1, "a.log");
    logfileMap.put(2, "b.log");
    logfileMap.put(3, "c.log");
    System.out.println("logfileMap:" + logfileMap);
    BiMap<String, Integer> filelogMap = logfileMap.inverse();
    System.out.println("filelogMap:" + filelogMap);

    logfileMap.put(4, "d.log");

    System.out.println("logfileMap:" + logfileMap);
    System.out.println("filelogMap:" + filelogMap);
}
```

　　输出：

```java
logfileMap:{1=a.log, 2=b.log, 3=c.log}
filelogMap:{a.log=1, b.log=2, c.log=3}
logfileMap:{1=a.log, 2=b.log, 3=c.log, 4=d.log}
filelogMap:{a.log=1, b.log=2, c.log=3, d.log=4}
```

　　**BiMap的实现类**

| **Key-Value Map Impl** | **Value-Key Map Impl** | **Corresponding BiMap** |
| ---------------------- | ---------------------- | ----------------------- |
| HashMap                | HashMap                | HashBiMap               |
| ImmutableMap           | ImmutableMap           | ImmutableBiMap          |
| EnumMap                | EnumMap                | EnumBiMap               |
| EnumMap                | HashMap                | EnumHashBiMap           |




## 参考

[Guava学习笔记：Guava新增集合类型-Bimap](https://www.cnblogs.com/peida/p/Guava_Bimap.html)
