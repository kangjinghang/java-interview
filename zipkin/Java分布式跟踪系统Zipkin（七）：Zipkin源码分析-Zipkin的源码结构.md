前面花了大量篇幅来介绍Brave的使用，一直把Zipkin当黑盒在使用，现在来逐渐拨开Zipkin的神秘面纱。 Zipkin的源代码地址为：https://github.com/openzipkin/zipkin

Zipkin的源码结构[![Zipkin的源码结构](https://static.blog.mozhu.org/images/zipkin/8_1.png)](https://static.blog.mozhu.org/images/zipkin/8_1.png)Zipkin的源码结构

- zipkin - 对应的是zipkin v1
- zipkin2 - 对应的是zipkin v2
- zipkin-server - 是zipkin的web工程目录，zipkin.server.ZipkinServer是启动类
- zipkin-ui - zipkin ui工程目录，zipkin的设计师前后端分离的，zipkin-server提供数据查询接口，zipkin-ui做数据展现。
- zipkin-autoconfigure - 是为springboot提供的自动配置相关的类 collector-kafka collector-kafka10 collector-rabbitmq collector-scribe metrics-prometheus storage-cassandra storage-cassandra3 storage-elasticsearch-aws storage-elasticsearch-http storage-mysql ui

- zipkin-collector - 是zipkin比较重要的模块，收集trace信息，支持从kafka和rabbitmq，以及scribe中收集，这个模块是可选的，因为zipkin默认使用http协议提供给客户端来收集 kafka kafka10 rabbitmq scribe

- zipkin-storage - 也是zipkin比较重要的模块，用于存储收集的trace信息，默认是使用内置的InMemoryStorage，即存储在内存中，重启就会丢失。我们可以根据我们实际的需要更换存储方式，将trace存储在mysql，elasticsearch，cassandra中。 cassandra elasticsearch elasticsearch-http mysql zipkin2_cassandra

## 1. ZipkinServer

ZipkinServer 是 SpringBoot 启动类，该类上使用了 @EnableZipkinServer 注解，加载了相关的 Bean，而且在启动方法中添加了监听器RegisterZipkinHealthIndicators 类，来初始化健康检查的相关 bean。

```java
@SpringBootApplication
@EnableZipkinServer
public class ZipkinServer {

  public static void main(String[] args) {
    new SpringApplicationBuilder(ZipkinServer.class)
        .listeners(new RegisterZipkinHealthIndicators())
        .properties("spring.config.name=zipkin-server").run(args);
  }
}
```

```java
@Target(ElementType.TYPE)
@Retention(RetentionPolicy.RUNTIME)
@Documented
@Import({
  ZipkinServerConfiguration.class,
  BraveConfiguration.class,
  ZipkinQueryApiV1.class,
  ZipkinHttpCollector.class
})
public @interface EnableZipkinServer {

}
```

EnableZipkinServer 注解导入了 ZipkinServerConfiguration，BraveConfiguration，ZipkinQueryApiV1，ZipkinHttpCollector。注意，这里并没有导入 ZipkinQueryApiV2，但是由于 SpringBoot 项目会默认加载和启动类在一个包，或者在其子包的所有使用 Component，Controller，Service 等注解的类，所以在启动后，也会发现 ZipkinQueryApiV2 也被加载了。

- ZipkinServerConfiguration - Zipkin Server端所有核心配置
- BraveConfiguration - Zipkin存储 trace 信息时，还可以将自身的 trace 信息一起记录，这时就依赖 Brave 相关的类，都在这个类里配置
- ZipkinQueryApiV1 - Zipkin V1 版本的查询API都在这个 Controller 中
- ZipkinQueryApiV2 - Zipkin V2 版本的查询API都在这个 Controller 中
- ZipkinHttpCollector - Zipkin 默认的 Collector 使用 http 协议里收集 Trace 信息，客户端调用 /api/v1/spans 或/ api/v2/spans 来上报 trace 信息

## 2. ZipkinServerConfiguration

所有 Zipkin 服务需要的 Bean 都在这个类里进行配置

- ZipkinHealthIndicator - Zipkin 健康自检的类
- CollectorSampler - Collector 的采样率，默认100%采样，可以通过 zipkin.collector.sample-rate 来设置采样率
- CollectorMetrics - Collector 的统计信息，默认实现为 ActuateCollectorMetrics
- BraveTracedStorageComponentEnhancer - Zipkin 存储 trace 时的 self-trace 类，启用后会将 Zipkin的Storage 存储模块执行的trace 信息也采集进系统中
- InMemoryConfiguration - 默认的内存Storage存储配置，当zipkin.storage.type属性未指定，或者容器中没有配置StorageComponent时，该配置被激活

## 3. ZipkinHealthIndicator

Zipkin 健康自检的类，实现了 springboot-actuate 的 CompositeHealthIndicator，提供系统组件的健康信息

```java
final class ZipkinHealthIndicator extends CompositeHealthIndicator {

  ZipkinHealthIndicator(HealthAggregator healthAggregator) {
    super(healthAggregator);
  }

  void addComponent(Component component) {
    String healthName = component instanceof V2StorageComponent
      ? ((V2StorageComponent) component).delegate().getClass().getSimpleName()
      : component.getClass().getSimpleName();
    healthName = healthName.replace("AutoValue_", "");
    addHealthIndicator(healthName, new ComponentHealthIndicator(component));
  }

  static final class ComponentHealthIndicator implements HealthIndicator {
    final Component component;

    ComponentHealthIndicator(Component component) {
      this.component = component;
    }

    @Override public Health health() {
      Component.CheckResult result = component.check();
      return result.ok ? Health.up().build() : Health.down(result.exception).build();
    }
  }
}
```

## 4. RegisterZipkinHealthIndicators

启动时加载的 RegisterZipkinHealthIndicators 类，当启动启动后，收到 ApplicationReadyEvent 事件，即系统已经启动完毕，会将Spring 容器中的 zipkin.Component 添加到 ZipkinHealthIndicator 中：

```java
public final class RegisterZipkinHealthIndicators implements ApplicationListener {

  @Override public void onApplicationEvent(ApplicationEvent event) {
    if (!(event instanceof ApplicationReadyEvent)) return;
    ConfigurableListableBeanFactory beanFactory =
        ((ApplicationReadyEvent) event).getApplicationContext().getBeanFactory();
    ZipkinHealthIndicator healthIndicator = beanFactory.getBean(ZipkinHealthIndicator.class);
    for (Component component : beanFactory.getBeansOfType(Component.class).values()) {
      healthIndicator.addComponent(component);
    }
  }
}
```

启动zipkin，访问下面地址，可以看到输出zipkin的健康检查信息 http://localhost:9411/health.json

```java
{"status":"UP","zipkin":{"status":"UP","InMemoryStorage":{"status":"UP"}},"diskSpace":{"status":"UP","total":429495595008,"free":392936411136,"threshold":10485760}}
```

## 5. ZipkinHttpCollector

Zipkin 默认的 Collector 使用 http 协议里收集 Trace 信息，客户端均调用 /api/v1/span s或 /api/v2/spans 来上报 trac e信息。

```java
@Autowired ZipkinHttpCollector(StorageComponent storage, CollectorSampler sampler,
    CollectorMetrics metrics) {
  this.metrics = metrics.forTransport("http");
  this.collector = Collector.builder(getClass())
      .storage(storage).sampler(sampler).metrics(this.metrics).build();
}

@RequestMapping(value = "/api/v2/spans", method = POST)
public ListenableFuture<ResponseEntity<?>> uploadSpansJson2(
  @RequestHeader(value = "Content-Encoding", required = false) String encoding,
  @RequestBody byte[] body
) {
  return validateAndStoreSpans(encoding, JSON2_DECODER, body);
}

ListenableFuture<ResponseEntity<?>> validateAndStoreSpans(String encoding, SpanDecoder decoder,
    byte[] body) {
  SettableListenableFuture<ResponseEntity<?>> result = new SettableListenableFuture<>();
  metrics.incrementMessages();
  if (encoding != null && encoding.contains("gzip")) {
    try {
      body = gunzip(body);
    } catch (IOException e) {
      metrics.incrementMessagesDropped();
      result.set(ResponseEntity.badRequest().body("Cannot gunzip spans: " + e.getMessage() + "\n"));
    }
  }
  collector.acceptSpans(body, decoder, new Callback<Void>() {
    @Override public void onSuccess(@Nullable Void value) {
      result.set(SUCCESS);
    }

    @Override public void onError(Throwable t) {
      String message = t.getMessage() == null ? t.getClass().getSimpleName() : t.getMessage();
      result.set(t.getMessage() == null || message.startsWith("Cannot store")
          ? ResponseEntity.status(500).body(message + "\n")
          : ResponseEntity.status(400).body(message + "\n"));
    }
  });
  return result;
}
```

ZipkinHttpCollector 中 uploadSpansJson2 方法接受所有 /api/v2/spans 请求，然后调用 validateAndStoreSpans 方法校验并存储Span 。在 validateAndStoreSpans 方法中，当请求数据为 gzip 格式，会先解压缩，然后调用 collector 的 acceptSpans 方法。

## 6. Collector

zipkin.collector.Collector 的 acceptSpans 方法中，对各种格式的 Span 数据做了兼容处理，我们这里只看下 V2 版的 JSON 格式的 Span是如何处理的，即会调用 storage2(V2Collector) 的 acceptSpans 方法。

```java
public class Collector
  extends zipkin.internal.Collector<SpanDecoder, zipkin.Span> {
  @Override
  public void acceptSpans(byte[] serializedSpans, SpanDecoder decoder, Callback<Void> callback) {
    try {
      if (decoder instanceof DetectingSpanDecoder) decoder = detectFormat(serializedSpans);
    } catch (RuntimeException e) {
      metrics.incrementBytes(serializedSpans.length);
      callback.onError(errorReading(e));
      return;
    }
    if (storage2 != null && decoder instanceof V2JsonSpanDecoder) {
      storage2.acceptSpans(serializedSpans, SpanBytesDecoder.JSON_V2, callback);
    } else {
      super.acceptSpans(serializedSpans, decoder, callback);
    }
  }
}
```

## 7. V2Collector

zipkin.internal.V2Collector 继承了 zipkin.internal.Collector，而在 Collector 的 acceptSpans 方法中会调用 decodeLists 先将传入的二进制数据转换成 Span对象，然后调用 accept 方法，accept 方法中会调用 sampled 方法，将需要采样的 Span 过滤出来，最后调用record 方法将 Span 信息存入 Storage 中。

```java
public abstract class Collector<D, S> {
  protected void acceptSpans(byte[] serializedSpans, D decoder, Callback<Void> callback) {
    metrics.incrementBytes(serializedSpans.length);
    List<S> spans;
    try {
      spans = decodeList(decoder, serializedSpans);
    } catch (RuntimeException e) {
      callback.onError(errorReading(e));
      return;
    }
    accept(spans, callback);
  }

  public void accept(List<S> spans, Callback<Void> callback) {
    if (spans.isEmpty()) {
      callback.onSuccess(null);
      return;
    }
    metrics.incrementSpans(spans.size());

    List<S> sampled = sample(spans);
    if (sampled.isEmpty()) {
      callback.onSuccess(null);
      return;
    }

    try {
      record(sampled, acceptSpansCallback(sampled));
      callback.onSuccess(null);
    } catch (RuntimeException e) {
      callback.onError(errorStoringSpans(sampled, e));
      return;
    }
  }

  List<S> sample(List<S> input) {
    List<S> sampled = new ArrayList<>(input.size());
    for (S s : input) {
      if (isSampled(s)) sampled.add(s);
    }
    int dropped = input.size() - sampled.size();
    if (dropped > 0) metrics.incrementSpansDropped(dropped);
    return sampled;
  }
}
```

V2Collector中的 record 方法会调用 storage 的 accept 方法，Zipkin 默认会使用 InMemoryStorage 来存储。

```java
public final class V2Collector extends Collector<BytesDecoder<Span>, Span> {
  @Override protected List<Span> decodeList(BytesDecoder<Span> decoder, byte[] serialized) {
    List<Span> out = new ArrayList<>();
    if (!decoder.decodeList(serialized, out)) return Collections.emptyList();
    return out;
  }

  @Override protected boolean isSampled(Span span) {
    return sampler.isSampled(Util.lowerHexToUnsignedLong(span.traceId()), span.debug());
  }

  @Override protected void record(List<Span> sampled, Callback<Void> callback) {
    storage.spanConsumer().accept(sampled).enqueue(new V2CallbackAdapter<>(callback));
  }
}
```

## 8. ZipkinQueryApiV1 & ZipkinQueryApiV2

暴露了 Zipkin 对外的查询 API，V1 和 V2 的区别，主要是 Span 里的字段叫法不一样了，这里主要看下 ZipkinQueryApiV2，ZipkinQueryApiV2 方法都比较简单，主要是调用 storage 组件来实现查询功能。

- /dependencies - 查看所有 trace 的依赖关系 
- /services - 查看所有的 services 
- /spans - 根据 serviceName 查询 spans 信息 
- /traces - 根据 serviceName，spanName，annotationQuery，minDuration，maxDuration 等来搜索 traces 信息
- /trace/{traceIdHex} - 根据 traceId 查询某条 trace 信息

至此 ZipkinServer 的代码分析的差不多了，在后面博文中我们再具体分析各种 Storage 和 Collector 的源代码。



## 参考

[Java分布式跟踪系统Zipkin（八）：Zipkin源码分析-KafkaCollector](http://blog.mozhu.org/2017/11/16/zipkin/zipkin-8.html)
