上一篇博文中，我们了解了Brave框架的基本使用，并且分析了跟Tracer相关的部分源代码。这篇博文我们接着看看Tracing的初始化及相关类的源代码

```java
public class TraceDemo {

    public static void main(String[] args) {
	Sender sender = OkHttpSender.create("http://localhost:9411/api/v2/spans");
	AsyncReporter asyncReporter = AsyncReporter.builder(sender)
		.closeTimeout(500, TimeUnit.MILLISECONDS)
		.build(SpanBytesEncoder.JSON_V2);

	Tracing tracing = Tracing.newBuilder()
		.localServiceName("tracer-demo")
		.spanReporter(asyncReporter)
		.propagationFactory(ExtraFieldPropagation.newFactory(B3Propagation.FACTORY, "user-name"))
		.currentTraceContext(ThreadContextCurrentTraceContext.create())
		.build();
	Tracer tracer = tracing.tracer();
	// ...
    }
}
```

Brave 中各个组件创建大量使用的 builder 设计模式，Tacing 也不例外，先来看下 Tracing.Builder。

## 1. Tracing.Builder

```java
public static final class Tracing.Builder {
    String localServiceName;
    Endpoint localEndpoint;
    Reporter<zipkin2.Span> reporter;
    Clock clock;
    Sampler sampler = Sampler.ALWAYS_SAMPLE;
    CurrentTraceContext currentTraceContext = CurrentTraceContext.Default.inheritable();
    boolean traceId128Bit = false;
    boolean supportsJoin = true;
    Propagation.Factory propagationFactory = Propagation.Factory.B3;

    public Tracing build() {
      if (clock == null) clock = Platform.get();
      if (localEndpoint == null) {
        localEndpoint = Platform.get().localEndpoint();
        if (localServiceName != null) {
          localEndpoint = localEndpoint.toBuilder().serviceName(localServiceName).build();
        }
      }
      if (reporter == null) reporter = Platform.get();
      return new Default(this);
    }

    Builder() {
    }
}
```

Tracing中依赖的几个重要类

- **Endpoint** - IP，端口和应用服务名等信息。
- **Sampler** - 采样器，根据 traceId 来判断是否一条 trace 需要被采样，即上报到 Zipkin。
- **TraceContext** - 包含 TraceId，SpanId，是否采样等数据。
- **CurrentTraceContext** - 是一个辅助类，可以用于获得当前线程的 TraceContext。
- **Propagation** - 是一个可以向数据携带的对象 carrier上 注入（inject）和提取（extract）数据的接口。
- **Propagation.Factory** - Propagation 的工厂类

前面 TraceDemo 例子中，我们初始化 Tracing 时设置了 localServiceName，spanReporter，propagationFactory，currentTraceContext。其中 spanReporter 为 AsyncReporter，我们上一篇已经分析过其源代码了，在 build 方法中可以看到，其默认实现是 Platform，默认会将 Span 信息用 logger 进行输出，而不是上报到 Zipkin 中：

```java
@Override public void report(zipkin2.Span span) {
  if (!logger.isLoggable(Level.INFO)) return;
  if (span == null) throw new NullPointerException("span == null");
  logger.info(span.toString());
}
```

## 2. Sampler

采样器，根据 traceId 来判断是否一条 trace 需要被采样，即上报到 Zipkin。

```java
public abstract class Sampler {

  public static final Sampler ALWAYS_SAMPLE = new Sampler() {
    @Override public boolean isSampled(long traceId) {
      return true;
    }

    @Override public String toString() {
      return "AlwaysSample";
    }
  };

  public static final Sampler NEVER_SAMPLE = new Sampler() {
    @Override public boolean isSampled(long traceId) {
      return false;
    }

    @Override public String toString() {
      return "NeverSample";
    }
  };

  /** Returns true if the trace ID should be measured. */
  public abstract boolean isSampled(long traceId);

  /**
   * Returns a sampler, given a rate expressed as a percentage.
   *
   * <p>The sampler returned is good for low volumes of traffic (<100K requests), as it is precise.
   * If you have high volumes of traffic, consider {@link BoundarySampler}.
   *
   * @param rate minimum sample rate is 0.01, or 1% of traces
   */
  public static Sampler create(float rate) {
    return CountingSampler.create(rate);
  }
}
```

Sampler.ALWAYS_SAMPLE 永远需要被采样，Sampler.NEVER_SAMPLE 永远不采样。

Sampler 还有一个实现类 CountingSampler 可以指定采样率，如 CountingSampler.create(0.5f) 则对50%的请求数据进行采样，里面用到了一个算法，这里不展开分析了。

## 3. TraceContext

包含 TraceId，SpanId，是否采样等数据。

在 Tracer 的 newRootContext 方法中有这样一段代码，通过 newBuilder 来构建 TraceContext 对象。

```java
TraceContext newRootContext(SamplingFlags samplingFlags, List<Object> extra) {
  long nextId = Platform.get().randomLong();
  Boolean sampled = samplingFlags.sampled();
  if (sampled == null) sampled = sampler.isSampled(nextId);
  return TraceContext.newBuilder()
      .sampled(sampled)
      .traceIdHigh(traceId128Bit ? Platform.get().nextTraceIdHigh() : 0L).traceId(nextId)
      .spanId(nextId)
      .debug(samplingFlags.debug())
      .extra(extra).build();
}
```

TraceContext 中有以下一些属性：

- **traceIdHigh** - 唯一标识 trace 的16字节 id，即 128-bit。
- **traceId** - 唯一标识 trace 的8字节id
- **parentId** - 父级 Span 的 spanId。
- **spanId** - 在某个 trace 中唯一标识 span 的8字节 id。
- **shared** - 如果为 true，则表明需要从其他 tracer 上共享 span 信息。
- **extra** - 在某个 trace 中相关的额外数据集。

还有继承自 SamplingFlags 的两个属性：

- **sampled** - 是否采样
- **debug** - 是否为调试，如果为 true 时，就算 sampled 为 false，也表明该 trace 需要采样（即可以覆盖 sampled 的值）。

TraceContext 中还定义了两个接口 Injector，Extractor

```java
public interface Injector<C> {
  void inject(TraceContext traceContext, C carrier);
}

public interface Extractor<C> {
  TraceContextOrSamplingFlags extract(C carrier);
}
```

- **Injector** - 用于将 TraceContext 中的各种数据注入到 carrier 中，这里的 carrier 一般在 RPC 中指的是类似于 Http Headers 的可以携带额外信息的对象。
- **Extractor** - 用于在 carrier 中提取 TraceContext 相关信息或者采样标记信息 TraceContextOrSamplingFlags。

## 4. TraceContextOrSamplingFlags

TraceContextOrSamplingFlags 是三种数据的联合类型，即 TraceContext，Trace Id Context，SamplingFlags，官方文档上说

- 当有 traceId 和 spanId 时，需用 create(TraceContext) 来创建。
- 当只有 spanId 时，需用 create(TraceIdContext) 来创建。
- 其他情况下，需用 create(SamplingFlags) 来创建。

TraceContextOrSamplingFlags里的代码比较简单，这里不展开分析了。

## 5. CurrentTraceContext

CurrentTraceContext 是一个辅助类，可以用于获得当前线程的 TraceContext，它的默认实现类是 CurrentTraceContext.Default。

```java
public static final class Default extends CurrentTraceContext {
    static final ThreadLocal<TraceContext> DEFAULT = new ThreadLocal<>();
    // Inheritable as Brave 3's ThreadLocalServerClientAndLocalSpanState was inheritable
    static final InheritableThreadLocal<TraceContext> INHERITABLE = new InheritableThreadLocal<>();

    final ThreadLocal<TraceContext> local;

    /** @deprecated prefer {@link #create()} as it isn't inheritable, so can't leak contexts. */
    @Deprecated
    public Default() {
      this(INHERITABLE);
    }

    /** Uses a non-inheritable static thread local */
    public static CurrentTraceContext create() {
      return new Default(DEFAULT);
    }

    /**
     * Uses an inheritable static thread local which allows arbitrary calls to {@link
     * Thread#start()} to automatically inherit this context. This feature is available as it is was
     * the default in Brave 3, because some users couldn't control threads in their applications.
     *
     * <p>This can be a problem in scenarios such as thread pool expansion, leading to data being
     * recorded in the wrong span, or spans with the wrong parent. If you are impacted by this,
     * switch to {@link #create()}.
     */
    public static CurrentTraceContext inheritable() {
      return new Default(INHERITABLE);
    }

    Default(ThreadLocal<TraceContext> local) {
      if (local == null) throw new NullPointerException("local == null");
      this.local = local;
    }

    @Override public TraceContext get() {
      return local.get();
    }
}
```

CurrentTraceContext.Default 提供了两个静态方法，即 create() 和 inheritable() 。当使用 create 方法创建时，local 对象为ThreadLocal 类型。当使用 inheritable 方法创建时，local对象为 InheritableThreadLocal 类型。 ThreadLocal可以理解为 JVM 为同一个线程开辟的一个共享内存空间，在同一个线程中不同方法调用，可以从该空间中取出放入的对象。而当使用 InheritableThreadLocal 获取线程绑定对象时，当前线程没有，则向当前线程的父线程的共享内存中获取。

官方文档指出，inheritable 方法在线程池的环境中需谨慎使用，可能会取出错误的 TraceContext，这样会导致 Span 等信息会记录并关联到错误的 traceId 上。

## 6. CurrentTraceContext.Scope

```java
public abstract Scope newScope(@Nullable TraceContext currentSpan);

/** A span remains in the scope it was bound to until close is called. */
public interface Scope extends Closeable {
  /** No exceptions are thrown when unbinding a span scope. */
  @Override void close();
}
```

CurrentTraceContext 中还定义了一个 Scope 接口，该接口继承自 Closeable 接口。自JDK7开始，凡是实现了 Closeable 接口的对象，只要在 try 语句中定义的，当 finally 执行的时候，JVM 都会主动调用其 close 方法来回收资源，所以 CurrentTraceContext 中就提供了一个 newScope 方法，我们在代码里可以这样来用：

```java
try (Scope scope = newScope(invocationContext)) {
  // do somthing
}
```

再来看看 CurrentTraceContext.Default 中是如何实现 newScope 的：

```
@Override public Scope newScope(@Nullable TraceContext currentSpan) {
      final TraceContext previous = local.get();
      local.set(currentSpan);
      class DefaultCurrentTraceContextScope implements Scope {
        @Override public void close() {
          local.set(previous);
        }
      }
      return new DefaultCurrentTraceContextScope();
    }
```

首先会将当前线程的 TraceContext 赋值给 previous 变量，然后设置新的 TraceContext 到当前线程，当 Scope 的 close方法调用时，会还原 previous 的值到当前线程中。

用两个嵌套的 try 代码块来演示下上面做法的意义：

```java
TraceContext traceContext1;
TraceContext traceContext2;
try (Scope scope = newScope(traceContext1)) {
  // 1.此处CurrentTraceContext.get()能获得traceContext1
  try (Scope scope = newScope(traceContext2)) {
  // 2.此处CurrentTraceContext.get()能获得traceContext2
  }
  // 3.此处CurrentTraceContext.get()能获得traceContext1
}
```

1. 在进入内层 try 代码块前，通过 CurrentTraceContext.get() 获取到的 traceContext1。
2. 在进入内层 try 代码块后，通过 CurrentTraceContext.get() 获取到的traceContext2。
3. 在运行完内层 try 代码块，通过CurrentTraceContext.get() 获取到的traceContext1。

这种处理方式确实比较灵活优雅，不过对使用的人来说，也有点过于隐晦，不知道 JDK7 新特性的同学刚开始看到这种用法可能会一脸茫然。

当然这种用法必须得让使用的人将 scope 对象 new 在 try 语句中，每个人都能按照这种约定的规则来写，容易出错，所以CurrentTraceContext 中提供了几个对 Callable，Runnable 的封装方法 wrap 方法：

```java
/** Wraps the input so that it executes with the same context as now. */
public <C> Callable<C> wrap(Callable<C> task) {
  final TraceContext invocationContext = get();
  class CurrentTraceContextCallable implements Callable<C> {
    @Override public C call() throws Exception {
      try (Scope scope = newScope(invocationContext)) {
        return task.call();
      }
    }
  }
  return new CurrentTraceContextCallable();
}

/** Wraps the input so that it executes with the same context as now. */
public Runnable wrap(Runnable task) {
  final TraceContext invocationContext = get();
  class CurrentTraceContextRunnable implements Runnable {
    @Override public void run() {
      try (Scope scope = newScope(invocationContext)) {
        task.run();
      }
    }
  }
  return new CurrentTraceContextRunnable();
}
```

CurrentTraceContext 还对 Executor，及 ExecuteService 提供了包装方法

```java
/**
 * Decorates the input such that the {@link #get() current trace context} at the time a task is
 * scheduled is made current when the task is executed.
 */
public Executor executor(Executor delegate) {
  class CurrentTraceContextExecutor implements Executor {
    @Override public void execute(Runnable task) {
      delegate.execute(CurrentTraceContext.this.wrap(task));
    }
  }
  return new CurrentTraceContextExecutor();
}

/**
 * Decorates the input such that the {@link #get() current trace context} at the time a task is
 * scheduled is made current when the task is executed.
 */
public ExecutorService executorService(ExecutorService delegate) {
  class CurrentTraceContextExecutorService extends brave.internal.WrappingExecutorService {

    @Override protected ExecutorService delegate() {
      return delegate;
    }

    @Override protected <C> Callable<C> wrap(Callable<C> task) {
      return CurrentTraceContext.this.wrap(task);
    }

    @Override protected Runnable wrap(Runnable task) {
      return CurrentTraceContext.this.wrap(task);
    }
  }
  return new CurrentTraceContextExecutorService();
}
```

这几个方法都用的是装饰器设计模式，属于比较常用的设计模式，此处就不再展开分析了。

## 7. ThreadContextCurrentTraceContext

可以看到 TraceDemo 中，我们设置的 CurrentTraceContext 是ThreadContextCurrentTraceContext.create()。

ThreadContextCurrentTraceContext 是为 log4j2 封装的，是 brave-context-log4j2 包中的一个类，在 ThreadContext 中放置 traceId 和 spanId 两个属性，我们可以在 log4j2 的配置文件中配置日志打印的 pattern，使用占位符%X{traceId}和%X{spanId}，让每行日志都能打印当前的 traceId 和 spanId 。

zipkin-learning\Chapter1\servlet25\src\main\resources\log4j2.properties

```properties
appender.console.layout.pattern = %d{ABSOLUTE} [%X{traceId}/%X{spanId}] %-5p [%t] %C{2} - %m%n
```

pom.xml中需要添加日志相关的jar

```xml
<brave.version>4.9.1</brave.version>
<log4j.version>2.8.2</log4j.version>

<dependency>
  <groupId>io.zipkin.brave</groupId>
  <artifactId>brave-context-log4j2</artifactId>
  <version>${brave.version}</version>
</dependency>

<dependency>
  <groupId>org.apache.logging.log4j</groupId>
  <artifactId>log4j-core</artifactId>
  <version>${log4j.version}</version>
</dependency>
<dependency>
  <groupId>org.apache.logging.log4j</groupId>
  <artifactId>log4j-jul</artifactId>
  <version>${log4j.version}</version>
</dependency>
<dependency>
  <groupId>org.apache.logging.log4j</groupId>
  <artifactId>log4j-jcl</artifactId>
  <version>${log4j.version}</version>
</dependency>
<dependency>
  <groupId>org.apache.logging.log4j</groupId>
  <artifactId>log4j-slf4j-impl</artifactId>
  <version>${log4j.version}</version>
</dependency>
```

在Chapter1的例子中，如果你观察 frontend 和 backend 的控制台，会有如下输出 0cabad9917e767ab 为 traceId，0cabad9917e767ab 和 e96a226ce75d30b4 为 spanId。

```java
10:11:05,731 [0cabad9917e767ab/0cabad9917e767ab] INFO  [qtp1441410416-17] servlet.FrontendServlet - frontend receive request
```

```java
10:11:05,820 [0cabad9917e767ab/e96a226ce75d30b4] INFO  [qtp1441410416-15] servlet.BackendServlet - backend receive request
```

```java
public final class ThreadContextCurrentTraceContext extends CurrentTraceContext {
  public static ThreadContextCurrentTraceContext create() {
    return create(CurrentTraceContext.Default.inheritable());
  }

  public static ThreadContextCurrentTraceContext create(CurrentTraceContext delegate) {
    return new ThreadContextCurrentTraceContext(delegate);
  }

  final CurrentTraceContext delegate;

  ThreadContextCurrentTraceContext(CurrentTraceContext delegate) {
    if (delegate == null) throw new NullPointerException("delegate == null");
    this.delegate = delegate;
  }

  @Override public TraceContext get() {
    return delegate.get();
  }

  @Override public Scope newScope(@Nullable TraceContext currentSpan) {
    final String previousTraceId = ThreadContext.get("traceId");
    final String previousSpanId = ThreadContext.get("spanId");

    if (currentSpan != null) {
      ThreadContext.put("traceId", currentSpan.traceIdString());
      ThreadContext.put("spanId", HexCodec.toLowerHex(currentSpan.spanId()));
    } else {
      ThreadContext.remove("traceId");
      ThreadContext.remove("spanId");
    }

    Scope scope = delegate.newScope(currentSpan);
    class ThreadContextCurrentTraceContextScope implements Scope {
      @Override public void close() {
        scope.close();
        ThreadContext.put("traceId", previousTraceId);
        ThreadContext.put("spanId", previousSpanId);
      }
    }
    return new ThreadContextCurrentTraceContextScope();
  }
}
```

ThreadContextCurrentTraceContext 继承了 CurrentTraceContext，覆盖了其 newScope 方法，提取了 currentSpan 中的 traceId 和spanId 放到 log4j2 的上下文对象 ThreadContext 中。

在https://github.com/openzipkin/brave/tree/master/context 中还能找到对 slf4j 和 log4j 的支持。brave-context-slf4j 中的brave.context.slf4j.MDCCurrentTraceContext brave-context-log4j12 中的 brave.context.log4j12.MDCCurrentTraceContext 代码都比较类似，这里不细说了。

## 8. Propagation

Propagation，英文翻译传播器，是一个可以向数据携带的对象 carrier 上注入（inject）和提取（extract）数据的接口。 对于 Http 协议来说，通常 carrier 就是指 http request 对象，它的 http headers 可以携带 trace 信息，一般来说 http 的客户端会在 headers 里注入（inject）trace 信息，而服务端则会在 headers 提取（extract）trace信息。Propagation.Setter 和 Propagation.Getter 可以在 carrier中设置和获取值。另外还有 injector 和 extractor 方法分别返回 TraceContext.Injector 和 TraceContext.Extractor。

```java
interface Setter<C, K> {
  void put(C carrier, K key, String value);
}
interface Getter<C, K> {
  @Nullable String get(C carrier, K key);
}

<C> TraceContext.Injector<C> injector(Setter<C, K> setter);
<C> TraceContext.Extractor<C> extractor(Getter<C, K> getter);
```

Propagation中 还有一个工厂类 Propagation.Factory，有一个工厂方法 create，通过 KeyFactory 来创建 Propagation 对象。

```java
abstract class Factory {
    public static final Factory B3 = B3Propagation.FACTORY;

    public boolean supportsJoin() {
      return false;
    }

    public boolean requires128BitTraceId() {
      return false;
    }

    public abstract <K> Propagation<K> create(KeyFactory<K> keyFactory);
}

interface KeyFactory<K> {
    KeyFactory<String> STRING = name -> name;

    K create(String name);
}
```

Propagation 的默认实现是 B3Propagation。B3Propagation 用下面这些 http headers 来传播 trace 信息。

- **X-B3-TraceId** - 128位或者64位的traceId，被编码成32位和16位的小写16进制形式
- **X-B3-SpanId** - 64位的spanId，被编码成16位的小写16进制形式
- **X-B3-ParentSpanId** - 64位的父级spanId，被编码成16位的小写16进制形式
- **X-B3-Sampled** - 1代表采样，0代表不采样，如果没有这个key，则留给header接受端，即服务端自行判断
- **X-B3-Flags** - debug，如果为1代表采样

```java
@Override public <C> TraceContext.Injector<C> injector(Setter<C, K> setter) {
  if (setter == null) throw new NullPointerException("setter == null");
  return new B3Injector<>(this, setter);
}

static final class B3Injector<C, K> implements TraceContext.Injector<C> {
  final B3Propagation<K> propagation;
  final Setter<C, K> setter;

  B3Injector(B3Propagation<K> propagation, Setter<C, K> setter) {
    this.propagation = propagation;
    this.setter = setter;
  }

  @Override public void inject(TraceContext traceContext, C carrier) {
    setter.put(carrier, propagation.traceIdKey, traceContext.traceIdString());
    setter.put(carrier, propagation.spanIdKey, toLowerHex(traceContext.spanId()));
    if (traceContext.parentId() != null) {
      setter.put(carrier, propagation.parentSpanIdKey, toLowerHex(traceContext.parentId()));
    }
    if (traceContext.debug()) {
      setter.put(carrier, propagation.debugKey, "1");
    } else if (traceContext.sampled() != null) {
      setter.put(carrier, propagation.sampledKey, traceContext.sampled() ? "1" : "0");
    }
  }
}
```

inject 方法中很简单，就是利用 Setter 将 trace 信息设置在 carrier 中。

```java
@Override public <C> TraceContext.Extractor<C> extractor(Getter<C, K> getter) {
  if (getter == null) throw new NullPointerException("getter == null");
  return new B3Extractor(this, getter);
}

static final class B3Extractor<C, K> implements TraceContext.Extractor<C> {
  final B3Propagation<K> propagation;
  final Getter<C, K> getter;

  B3Extractor(B3Propagation<K> propagation, Getter<C, K> getter) {
    this.propagation = propagation;
    this.getter = getter;
  }

  @Override public TraceContextOrSamplingFlags extract(C carrier) {
    if (carrier == null) throw new NullPointerException("carrier == null");

    String traceId = getter.get(carrier, propagation.traceIdKey);
    String sampled = getter.get(carrier, propagation.sampledKey);
    String debug = getter.get(carrier, propagation.debugKey);
    if (traceId == null && sampled == null && debug == null) {
      return TraceContextOrSamplingFlags.EMPTY;
    }

    // Official sampled value is 1, though some old instrumentation send true
    Boolean sampledV = sampled != null
        ? sampled.equals("1") || sampled.equalsIgnoreCase("true")
        : null;
    boolean debugV = "1".equals(debug);

    String spanId = getter.get(carrier, propagation.spanIdKey);
    if (spanId == null) { // return early if there's no span ID
      return TraceContextOrSamplingFlags.create(
          debugV ? SamplingFlags.DEBUG : SamplingFlags.Builder.build(sampledV)
      );
    }

    TraceContext.Builder result = TraceContext.newBuilder().sampled(sampledV).debug(debugV);
    result.traceIdHigh(
        traceId.length() == 32 ? lowerHexToUnsignedLong(traceId, 0) : 0
    );
    result.traceId(lowerHexToUnsignedLong(traceId));
    result.spanId(lowerHexToUnsignedLong(spanId));
    String parentSpanIdString = getter.get(carrier, propagation.parentSpanIdKey);
    if (parentSpanIdString != null) result.parentId(lowerHexToUnsignedLong(parentSpanIdString));
    return TraceContextOrSamplingFlags.create(result.build());
  }
}
```

extract 方法则利用 Getter 从 carrier 中获取 trace 信息。

在TraceDemo中我们设置的propagationFactory是ExtraFieldPropagation.newFactory(B3Propagation.FACTORY, “user-name”)

## 9. ExtraFieldPropagation

ExtraFieldPropagation 可以用来传输额外的信息。

运行 Chapter1 中的 Frontend 和 Backend 服务，在控制台输入

```bash
curl http://localhost:8081 --header "user-name: zhangsan"
```

可以看到控制台输出了 user-name 的值 zhangsan。

```
Wed Nov 15 11:42:02 GMT+08:00 2017 zhangsan
```

```java
static final class ExtraFieldInjector<C, K> implements Injector<C> {
  final Injector<C> delegate;
  final Propagation.Setter<C, K> setter;
  final Map<String, K> nameToKey;

  ExtraFieldInjector(Injector<C> delegate, Setter<C, K> setter, Map<String, K> nameToKey) {
    this.delegate = delegate;
    this.setter = setter;
    this.nameToKey = nameToKey;
  }

  @Override public void inject(TraceContext traceContext, C carrier) {
    for (Object extra : traceContext.extra()) {
      if (extra instanceof Extra) {
        ((Extra) extra).setAll(carrier, setter, nameToKey);
        break;
      }
    }
    delegate.inject(traceContext, carrier);
  }
}
```

ExtraFieldInjector 的 inject 方法中，将 traceContext 的 extra 数据，set 到 carrier 中，这里的 Extra 对象，其实就是 key-value，有One 和 Many 两种，Many 时就相当于 Map 结构。在 Extra 中 setAll 方法中，先用 extra 的 name 去 nameToKey 里找，如果没有就不设置，如果找到就调用 setter 的 put 方法将值设置到 carrier 中。

```java
static final class One extends Extra {
  String name, value;

  @Override void put(String name, String value) {
    this.name = name;
    this.value = value;
  }

  @Override String get(String name) {
    return name.equals(this.name) ? value : null;
  }

  @Override <C, K> void setAll(C carrier, Setter<C, K> setter, Map<String, K> nameToKey) {
    K key = nameToKey.get(name);
    if (key == null) return;
    setter.put(carrier, key, value);
  }

  @Override public String toString() {
    return "ExtraFieldPropagation{" + name + "=" + value + "}";
  }
}

static final class Many extends Extra {
  final LinkedHashMap<String, String> fields = new LinkedHashMap<>();

  @Override void put(String name, String value) {
    fields.put(name, value);
  }

  @Override String get(String name) {
    return fields.get(name);
  }

  @Override <C, K> void setAll(C carrier, Setter<C, K> setter, Map<String, K> nameToKey) {
    for (Map.Entry<String, String> field : fields.entrySet()) {
      K key = nameToKey.get(field.getKey());
      if (key == null) continue;
      setter.put(carrier, nameToKey.get(field.getKey()), field.getValue());
    }
  }

  @Override public String toString() {
    return "ExtraFieldPropagation" + fields;
  }
}
```

ExtraFieldExtractor 的 extract 方法中，循环 names 去 carrier 里找，然后构造 Extra 数据放入 delegate 执行 extract 方法后的结果中。

```java
static final class ExtraFieldExtractor<C, K> implements Extractor<C> {
  final Extractor<C> delegate;
  final Propagation.Getter<C, K> getter;
  final Map<String, K> names;

  ExtraFieldExtractor(Extractor<C> delegate, Getter<C, K> getter, Map<String, K> names) {
    this.delegate = delegate;
    this.getter = getter;
    this.names = names;
  }

  @Override public TraceContextOrSamplingFlags extract(C carrier) {
    TraceContextOrSamplingFlags result = delegate.extract(carrier);

    Extra extra = null;
    for (Map.Entry<String, K> field : names.entrySet()) {
      String maybeValue = getter.get(carrier, field.getValue());
      if (maybeValue == null) continue;
      if (extra == null) {
        extra = new One();
      } else if (extra instanceof One) {
        One one = (One) extra;
        extra = new Many();
        extra.put(one.name, one.value);
      }
      extra.put(field.getKey(), maybeValue);
    }
    if (extra == null) return result;
    return result.toBuilder().addExtra(extra).build();
  }
}
```

至此，Tracing 类相关的源代码已分析的差不多了，后续博文中，我们会继续分析 Brave 跟各大框架整合的源代码。



## 参考

[Java分布式跟踪系统Zipkin（三）：Brave源码分析-Tracing](http://blog.mozhu.org/2017/11/12/zipkin/zipkin-3.html)
