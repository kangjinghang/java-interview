## 1. EventBus是什么

EventBus 是Google的一个开源库，它利用发布/订阅者者模式来对项目进行解耦。它可以利用很少的代码，来实现多组件间通信。

------

## 2. EventBus代码结构

EventBus代码结构如下：

![img](http://blog-1259650185.cosbj.myqcloud.com/img/202204/18/1650213065.awebp)

类说明：

### 2.1 EventBus

EventBus 是核心入口类，如果全都采用默认实现，只需要实现 Listener，并通过调用 EventBus 类的方法则可完成所有功能。

### 2.2 SubscriberExceptionHandler

SubscriberExceptionHandler 是异常处理接口，可替换自己的实现。

### 2.3 Executor

Executor用于异步执行 Listener 的监听方法，可替换自己的实现。

### 2.4 Dispatcher

Dispatcher 是 event 派发接口，可替换自己的实现，默认提供了3个实现类。

### 2.5 SubscriberRegistry

SubscriberRegistry 是事件注册类，也用于获取订阅者。

### 2.6 Subscriber

Subscriber 是订阅者，对 Listener 做了封装，屏蔽了复杂的调用逻辑，使得使用者不必关心这些复杂逻辑，只要提供 Listener 的具体实现则可。

### 2.7 SynchronizedSubscriber

SynchronizedSubscriber 是支持并发调用的订阅者，可以通过在 Listener 的事件监听方法上添加 AllowConcurrentEvents 注解来达到使用 SynchronizedSubscriber 的目的。

### 2.8 Subscribe

Subscribe 是一个注解类，可以在任何类的方法上添加该注解来表达该方法是一个事件监听方法。

### 2.9 DeadEvent

DeadEvent 用于记录那些已经没有订阅者的事件。

### 2.10 SubscriberExceptionContext

SubscriberExceptionContext 是异常上下文，用于当订阅者处理异常时记录相关的上下文信息，方便异常处理实现类获得这些信息来处理异常。

------

## 3. EventBus的优秀之处

1. 面向接口编程：Executor，Dispatcher，SubscriberExceptionHandler 都是接口，使用者可以替换具体的实现类。
2. 使用依赖注入，使得可测性增强。从图中可以看到 EventBus 持有 Executor，Dispatcher，SubscriberExceptionHandler 三个对象，它们可通过 EventBus 的构造器注入，这样使用者就有机会方便的替换具体的实现，或者 mock 一个对象来用于测试。如果它们不是可注入的，而是直接在某个方法内调用，就失去了替换的机会。当然，接口注入的方式还有很多，例如通过 set 方法，通过反射动态生成等等，但构造器注入是最简单，最省心的方法。
3. 异步处理，提高性能。Subscriber 最终处理 event 是通过 Executor 以异步线程方式执行，不会因为同步而阻塞，大大提高了性能。
4. 利用 Subscribe 注解+反射，使得任何类的任何方法都可以成为事件监听类，而不需要实现特定的监听者接口。
5. 考虑了异常处理机制，一方面提供了 SubscriberExceptionHandler 接口让使用者来实现具体的处理逻辑，另外一方面提供了DeadEvent 类，将那些失去订阅者的事件统一归类到 DeadEvent ，由使用者自行实现一个 Listener 去处理它们。
6. 通过模板方法固化了整个调用流程，使用者只需要按照要求简单实现则可使用。

------

## 4. EventBus具体使用过程

### 4.1 实现一个Listener

#### 4.1.1. 使用说明

Listener 是一个事件监听类，一个 Listener 类可以通过不同的方法同时监听多个事件，任何类都可以作为 Listener，但需要遵循以下要求：

1. 必须在监听方法上添加 Subscribe 注解，用以表达该方法是一个监听方法。
2. 此监听方法只能有一个参数，这个参数就是要监听的事件，参数类的 Class 可以理解为就是要监听的 EventType。

#### 4.1.2 相关代码

1.Listener例子

```java
public class MyListener {

  // 添加Subscribe注解则表示要监听某个事件
  @Subscribe
  public void onEvent(MyEvent1 event1) {
    // do something
  }
  
  // 一个Listener可以监听多个事件
  @Subscribe
  public void onEvent(MyEvent2 event2) {
    // do something
  }
}
```

2.SubscriberRegistry.java：

```java
private final ConcurrentMap<Class<?>, CopyOnWriteArraySet<Subscriber>> subscribers = Maps.newConcurrentMap();

// 传入的 clazz 类就是 Listener 的 Class
private static ImmutableList<Method> getAnnotatedMethodsNotCached(Class<?> clazz) {
  Set<? extends Class<?>> supertypes = TypeToken.of(clazz).getTypes().rawTypes();
  Map<MethodIdentifier, Method> identifiers = Maps.newHashMap();
  for (Class<?> supertype : supertypes) {
    for (Method method : supertype.getDeclaredMethods()) {
      if (method.isAnnotationPresent(Subscribe.class) && !method.isSynthetic()) {  // 这里查找方法上是否有 Subscribe 注解
        // TODO(cgdecker): Should check for a generic parameter type and error out
        Class<?>[] parameterTypes = method.getParameterTypes();
        checkArgument( // 这里检查方法的参数只有1个
            parameterTypes.length == 1,
            "Method %s has @Subscribe annotation but has %s parameters."
                + "Subscriber methods must have exactly 1 parameter.",
            method,
            parameterTypes.length);

        MethodIdentifier ident = new MethodIdentifier(method);
        if (!identifiers.containsKey(ident)) {
          identifiers.put(ident, method);
        }
      }
    }
  }
  return ImmutableList.copyOf(identifiers.values());
}
```

从上面的定义形式中我们可以看出，这里使用的是事件的 Class 类型映射到 Subscriber 列表的。这里的 Subscriber 列表使用的是 Java 中的 CopyOnWriteArraySet 集合，它底层使用了 CopyOnWriteArrayList，并对其进行了封装，也就是在基本的集合上面增加了去重的操作。这是一种适用于读多写少场景的集合，在读取数据的时候不会加锁，写入数据的时候进行加锁，并且会进行一次数组拷贝。

### 4.2 构造EventBus

#### 4.2.1 使用说明

1. 在一个系统中，根据用途不同，可以同时存在多个 EventBus，不同的 EventBus 通过 identifier 来识别。
2. 为方便使用，EventBus 提供了多个构造器，使用者可以根据需要注入不同的实现类，最简单的构造器是一个无参构造器，全部使用默认实现。
3. 在实际使用过程中，可以使用一个单例类来持有 EventBus 实例，如有需要，可以持有不同的 EventBus 实例用于不同的用途。

#### 4.2.2 相关代码

1.EventBus.java

```java
  // 无参构造器
  public EventBus() {
    this("default");
  }
  
  // 指定标识符构造器
  public EventBus(String identifier) {
    this(
        identifier,
        MoreExecutors.directExecutor(),
        Dispatcher.perThreadDispatchQueue(),
        LoggingHandler.INSTANCE);
  }
  
  // 注入自定义异常类构造器
  public EventBus(SubscriberExceptionHandler exceptionHandler) {
    this(
        "default",
        MoreExecutors.directExecutor(),
        Dispatcher.perThreadDispatchQueue(),
        exceptionHandler);
  }
  
  // 注入所有参数构造器，需注意的是，此方法不是public的，只能在包内访问。
  EventBus(
      String identifier,
      Executor executor,
      Dispatcher dispatcher,
      SubscriberExceptionHandler exceptionHandler) {
    this.identifier = checkNotNull(identifier);
    this.executor = checkNotNull(executor);
    this.dispatcher = checkNotNull(dispatcher);
    this.exceptionHandler = checkNotNull(exceptionHandler);
  }
```

这里的 identifier 是一个字符串类型，类似于 EventBus 的 id；subscribers 是 SubscriberRegistry 类型的，实际上 EventBus 在添加、移除和遍历观察者的时候都会使用该实例的方法，所有的观察者信息也都维护在该实例中；executor 是事件分发过程中使用到的线程池，可以自己实现；dispatcher 是 Dispatcher 类型的子类，用来在发布事件的时候分发消息给监听者，它有几个默认的实现，分别针对不同的分发方式；exceptionHandler 是 SubscriberExceptionHandler 类型的，它用来处理异常信息，在默认的 EventBus 实现中，会在出现异常的时候打印出 log，当然我们也可以定义自己的异常处理策咯。

### 4.3 注册Listener

#### 4.3.1 使用说明

以上两步完成后，即可通过 EventBus 来注册 Listener。

#### 4.3.2、相关代码

1.EventBus.java

```java
private final SubscriberRegistry subscribers = new SubscriberRegistry(this);

public void register(Object object) {
  subscribers.register(object);
}
```

2.SubscriberRegistry.java

```java
void register(Object listener) {
  // 查找有Subscribe注解的方法，并封装为Subscriber，Multimap的key记录的Class就是要监听的对象的Class
  Multimap<Class<?>, Subscriber> listenerMethods = findAllSubscribers(listener);
	// 遍历上述映射表并将新注册的观察者映射表添加到全局的subscribers中
  for (Entry<Class<?>, Collection<Subscriber>> entry : listenerMethods.asMap().entrySet()) {
    Class<?> eventType = entry.getKey();
    Collection<Subscriber> eventMethodsInListener = entry.getValue();

    CopyOnWriteArraySet<Subscriber> eventSubscribers = subscribers.get(eventType);

    if (eventSubscribers == null) {
      CopyOnWriteArraySet<Subscriber> newSet = new CopyOnWriteArraySet<>();
      eventSubscribers =
        MoreObjects.firstNonNull(subscribers.putIfAbsent(eventType, newSet), newSet);
    }

    eventSubscribers.addAll(eventMethodsInListener);
  }
}

private Multimap<Class<?>, Subscriber> findAllSubscribers(Object listener) {
    // 创建一个哈希表
    Multimap<Class<?>, Subscriber> methodsInListener = HashMultimap.create();
    // 获取监听者的类型
    Class<?> clazz = listener.getClass();
    // 获取上述监听者的全部监听方法
    UnmodifiableIterator var4 = getAnnotatedMethods(clazz).iterator(); // 1
    // 遍历上述方法，并且根据方法和类型参数创建观察者并将其插入到映射表中
    while(var4.hasNext()) {
        Method method = (Method)var4.next();
        Class<?>[] parameterTypes = method.getParameterTypes();
        // 事件类型
        Class<?> eventType = parameterTypes[0];
        methodsInListener.put(eventType, Subscriber.create(this.bus, listener, method));
    }
    return methodsInListener;
}
```

### 4.4 发布Event

#### 4.4.1 使用说明

发布事件比较简单，只要在需要发布事件的地方得到 EventBus 实例，然后调用 post 方法则可。

#### 4.4.2 相关代码

1.EventBus.java

```java
public void post(Object event) {
  // 根据event找到订阅者，这里实际是根据event.Class来查找，也即和Listener的监听方法的参数的Class一致。
  Iterator<Subscriber> eventSubscribers = subscribers.getSubscribers(event);
  if (eventSubscribers.hasNext()) {
    //通过dispatcher来派发事件，最终调用的是Subscriber的dispatchEvent方法
    dispatcher.dispatch(event, eventSubscribers);
  } else if (!(event instanceof DeadEvent)) {
    // the event had no subscribers and was not itself a DeadEvent
    post(new DeadEvent(this, event));
  }
}
```

2.SubscriberRegistry.java

```java
Iterator<Subscriber> getSubscribers(Object event) {
  ImmutableSet<Class<?>> eventTypes = flattenHierarchy(event.getClass());  // 获取事件类型的所有父类型和自身构成的集合

  List<Iterator<Subscriber>> subscriberIterators =
      Lists.newArrayListWithCapacity(eventTypes.size());

  for (Class<?> eventType : eventTypes) {  // 遍历上述事件类型，并从 subscribers 中获取所有的观察者列表
    CopyOnWriteArraySet<Subscriber> eventSubscribers = subscribers.get(eventType);
    if (eventSubscribers != null) {
      // eager no-copy snapshot
      subscriberIterators.add(eventSubscribers.iterator());
    }
  }

  return Iterators.concat(subscriberIterators.iterator());
}
```

它用来获取当前事件的所有的父类包含自身的类型构成的集合，也就是说，加入我们触发了一个 Interger 类型的事件，那么 Number 和Object 等类型的监听方法都能接收到这个事件并触发。这里的逻辑很简单，就是根据事件的类型，找到它及其所有的父类的类型对应的观察者并返回。

3.Subscriber.java

从 EventBus.post() 方法可以看出，当我们使用 Dispatcher 进行事件分发的时候，需要将当前的事件和所有的观察者作为参数传入到方法中。然后，在方法的内部进行分发操作。最终某个监听者的监听方法是使用反射进行触发的，这部分逻辑在 Subscriber 内部，而Dispatcher 是事件分发的方式的策略接口。EventBus 中提供了3个默认的 Dispatcher 实现，分别用于不同场景的事件分发:

1. ImmediateDispatcher：直接在当前线程中遍历所有的观察者并进行事件分发；
2. LegacyAsyncDispatcher：异步方法，存在两个循环，一先一后，前者用于不断往全局的队列中塞入封装的观察者对象，后者用于不断从队列中取出观察者对象进行事件分发；实际上，EventBus 有个子类 AsyncEventBus 就是用该分发器进行事件分发的。
3. PerThreadQueuedDispatcher：这种分发器使用了两个线程局部变量进行控制，当 dispatch() 方法被调用的时候，会先获取当前线程的观察者队列，并将传入的观察者列表传入到该队列中；然后通过一个布尔类型的线程局部变量，判断当前线程是否正在进行分发操作，如果没有在进行分发操作，就通过遍历上述队列进行事件分发。

上述三个分发器内部最终都会调用 Subscriber 的 dispatchEvent() 方法进行事件分发：

```javascript
  final void dispatchEvent(final Object event) {
    // 通过executor来实现异步调用，这个executor在EventBus是可注入的，可以注入修改后的实现类
    executor.execute(
        new Runnable() {
          @Override
          public void run() {
            try {
              invokeSubscriberMethod(event); // 使用反射触发监听方法
            } catch (InvocationTargetException e) {
              // 这里最终调用的是在EventBus中注入的SubscriberExceptionHandler，可以注入修改后的实现类
              bus.handleSubscriberException(e.getCause(), context(event));
            }
          }
        });
  }
  
  void invokeSubscriberMethod(Object event) throws InvocationTargetException {
    try {
      //这里的method就是Listener的监听方法，target就是Listener对象，event就是这个监听方法的入参
      method.invoke(target, checkNotNull(event));
    } catch (IllegalArgumentException e) {
      throw new Error("Method rejected target/argument: " + event, e);
    } catch (IllegalAccessException e) {
      throw new Error("Method became inaccessible: " + event, e);
    } catch (InvocationTargetException e) {
      if (e.getCause() instanceof Error) {
        throw (Error) e.getCause();
      }
      throw e;
    }
  }
```

另外还要注意下 Subscriber 还有一个子类 SynchronizedSubscriber，它与一般的 Subscriber 的不同就在于它的反射触发调用的方法被sychronized 关键字修饰，也就是它的触发方法是加锁的、线程安全的。

------

## 5. 小结

至此，我们已经完成了EventBus的源码分析。简单总结一下：

EventBus中维护了三个缓存和四个映射：

1. 事件类型到观察者列表的映射（缓存）；
2. 事件类型到监听者方法列表的映射（缓存）；
3. 事件类型到事件类型及其所有父类的类型的列表的映射（缓存）；
4. 观察者到监听者的映射，观察者到监听方法的映射；

观察者 Subscriber 内部封装了监听者和监听方法，可以直接反射触发。而如果是映射到监听者的话，还要判断监听者的方法的类型来进行触发。个人觉得这个设计是非常棒的，因为我们无需再在EventBus中维护一个映射的缓存了，因为 Subscriber 中已经完成了这个一对一的映射。

每次使用 EventBus 注册和取消注册监听者的时候，都会先从缓存中进行获取，不是每一次都会用到反射的，这可以提升获取的效率，也解答了我们一开始提出的效率的问题。当使用反射触发方法的调用貌似是不可避免的了。

最后，EventBus 中使用了非常多的数据结构，比如 MultiMap、CopyOnWriteArraySet 等，还有一些缓存和映射的工具库，这些大部分都来自于 Guava。

看了 EventBus 的实现，由衷地感觉 Google 的工程师真牛！而 Guava 中还有许多更加丰富的内容值得我们去挖掘！



## 参考

[Google guava源码之EventBus](https://juejin.cn/post/6844904099591225358)

[Guava 消息框架 EventBus 的实现原理](https://juejin.cn/post/6844903650125414407)
