前面几篇博文中，都是使用 OkHttpSender 来上报 Trace 信息给 Zipkin，这在生产环境中，当业务量比较大的时候，可能会成为一个性能瓶颈，这一篇博文我们来使用 KafkaSender 将 Trace 信息先写入到 Kafka 中，然后 Zipkin 使用 KafkaCollector 从 Kafka 中收集 Span信息。 在 Brave 配置中需要将 Sender 设置为 KafkaSender，而 Zipkin 的 collector 组件配置为 KafkaCollector。

相关代码在 Chapter8/zipkin-kafka 中。

pom.xml中添加依赖

```xml
<dependency>
    <groupId>io.zipkin.reporter2</groupId>
    <artifactId>zipkin-sender-kafka11</artifactId>
    <version>${zipkin-reporter2.version}</version>
</dependency>
```

TracingConfiguration 中，我们修改 Sender 为 KafkaSender，指定 Kafka 的地址，以及 topic。

```java
@Bean
Sender sender() {
	return KafkaSender.newBuilder().bootstrapServers("localhost:9091,localhost:9092,localhost:9093").topic("zipkin").encoding(Encoding.JSON).build();
}
```

我们先启动 zookeeper（默认端口号为2181），再依次启动一个本地的3个 broker 的 kafka 集群（端口号分别为9091、9092、9093），最后启动一个 KafkaManager（默认端口号9000），KafkaManager 是 Kafka 的UI管理工具 关于如何搭建本地 Kafka 伪集群，请自行上网搜索教程，本文使用的 Kafka 版本为0.10.0.0。

kafka 启动完毕后，我们创建名为 Zipkin 的 topic，因为我们有3个 broker，我这里设置 replication-factor=3。

```bash
bin/windows/kafka-topics.bat --create --zookeeper localhost:2181 --replication-factor 3 --partitions 1 --topic zipkin
```

打开KafkaManager界面 http://localhost:9000/clusters/localhost/topics/zipkin[![KafkaManager](https://static.blog.mozhu.org/images/zipkin/7_1.png)](https://static.blog.mozhu.org/images/zipkin/7_1.png)KafkaManager。可以看到 topic zipkin 中暂时没有消息。

我们使用如下命令启动 Zipkin，带上 Kafka 的 Zookeeper 地址参数，这样 Zipkin 就会从 kafka 中消费我们上报的 trace 信息。

```bash
java -jar zipkin-server-2.2.1-exec.jar --KAFKA_ZOOKEEPER=localhost:2181
```

然后分别运行，主意我们这里将 backend 的端口改为 9001，目的是为了避免和 KafkaManager 端口号冲突。

```bash
mvn spring-boot:run -Drun.jvmArguments="-Dserver.port=9001 -Dzipkin.service=backend"
```

```bash
mvn spring-boot:run -Drun.jvmArguments="-Dserver.port=8081 -Dzipkin.service=frontend"
```

浏览器访问 http://localhost:8081/ 会显示当前时间。

我们再次刷新KafkaManager界面 http://localhost:9000/clusters/localhost/topics/zipkin[![KafkaManager](https://static.blog.mozhu.org/images/zipkin/7_2.png)](https://static.blog.mozhu.org/images/zipkin/7_2.png)KafkaManager 可以看到topic zipkin中有两条消息。

为了看到这两条消息的具体内容，我们可以在kafka安装目录使用如下命令

```bash
bin/windows/kafka-console-consumer.bat --zookeeper localhost:2181 --topic zipkin --from-beginning
```

在控制台会打印出最近的两条消息

```json
[{"traceId":"802bd09f480b5faa","parentId":"802bd09f480b5faa","id":"bb3c70909ea3ee3c","kind":"SERVER","name":"get","timestamp":1510891296426607,"duration":10681,"localEndpoint":{"serviceName":"backend","ipv4":"10.200.170.137"},"remoteEndpoint":{"ipv4":"127.0.0.1","port":64421},"tags":{"http.path":"/api"},"shared":true}]
[{"traceId":"802bd09f480b5faa","parentId":"802bd09f480b5faa","id":"bb3c70909ea3ee3c","kind":"CLIENT","name":"get","timestamp":1510891296399882,"duration":27542,"localEndpoint":{"serviceName":"frontend","ipv4":"10.200.170.137"},"tags":{"http.path":"/api"}},{"traceId":"802bd09f480b5faa","id":"802bd09f480b5faa","kind":"SERVER","name":"get","timestamp":1510891296393252,"duration":39514,"localEndpoint":{"serviceName":"frontend","ipv4":"10.200.170.137"},"remoteEndpoint":{"ipv6":"::1","port":64420},"tags":{"http.path":"/"}}]
```

这说明我们的应用 frontend 和 backend 已经将 trace 信息写入kafka成功了！

在 Zipkin 的 Web 界面中，也能查询到这次跟踪信息。在 Zipkin 的控制台，我们也看到跟 Kafka 相关的类 ConsumerFetcherThread 启动，我们在后续专门分析 Zipkin的源代码再来看看这个类。

```java
2017-11-17 11:25:00.477  INFO 9292 --- [49-8e18eab0-0-1] kafka.consumer.ConsumerFetcherThread     : [ConsumerFetcherThread-zipkin_LT290-1510889099649-8e18eab0-0-1], Starting
2017-11-17 11:25:00.482  INFO 9292 --- [r-finder-thread] kafka.consumer.ConsumerFetcherManager    : [ConsumerFetcherManager-1510889099800] Added fetcher for partitions ArrayBuffer([[zipkin,0], initOffset 0 to broker id:1,host:10.200.170.137,port:9091] )
```

## 1. KafkaSender

```java
public abstract class KafkaSender extends Sender {
  public static Builder newBuilder() {
    // Settings below correspond to "Producer Configs"
    // http://kafka.apache.org/0102/documentation.html#producerconfigs
    Properties properties = new Properties();
    properties.put(ProducerConfig.KEY_SERIALIZER_CLASS_CONFIG, ByteArraySerializer.class.getName());
    properties.put(ProducerConfig.VALUE_SERIALIZER_CLASS_CONFIG,
        ByteArraySerializer.class.getName());
    properties.put(ProducerConfig.ACKS_CONFIG, "0");
    return new zipkin2.reporter.kafka11.AutoValue_KafkaSender.Builder()
        .encoding(Encoding.JSON)
        .properties(properties)
        .topic("zipkin")
        .overrides(Collections.EMPTY_MAP)
        .messageMaxBytes(1000000);
  }

  @Override public zipkin2.Call<Void> sendSpans(List<byte[]> encodedSpans) {
    if (closeCalled) throw new IllegalStateException("closed");
    byte[] message = encoder().encode(encodedSpans);
    return new KafkaCall(message);
  }

}
```

KafkaSender 中通过 KafkaProducer 客户端来发送消息给 Kafka，在 newBuilder 方法中，设置了一些默认值，比如 topic 默认为zipkin，编码默认用 JSON，消息最大字节数1000000，还可以通过 overrides 来覆盖默认的配置来定制 KafkaProducer。

在 sendSpans 方法中返回 KafkaCall，这个对象的 execute 方法，在 AsyncReporter 中的 flush 方法中会被调用：

```java
void flush(BufferNextMessage bundler) {
	// ...
	sender.sendSpans(nextMessage).execute();
	// ...
}
```

KafkaCall 的 父类 BaseCall 方法 execute 会调用 doExecute，而在 doExecute 方法中使用了一个 AwaitableCallback 将 KafkaProducer的异步发送消息的方法，强制转为了同步发送，这里也确实处理的比较优雅。

```java
class KafkaCall extends BaseCall<Void> { // KafkaFuture is not cancelable
  private final byte[] message;

  KafkaCall(byte[] message) {
    this.message = message;
  }

  @Override protected Void doExecute() throws IOException {
    final AwaitableCallback callback = new AwaitableCallback();
    get().send(new ProducerRecord<>(topic(), message), (metadata, exception) -> {
      if (exception == null) {
        callback.onSuccess(null);
      } else {
        callback.onError(exception);
      }
    });
    callback.await();
    return null;
  }

  @Override protected void doEnqueue(Callback<Void> callback) {
    get().send(new ProducerRecord<>(topic(), message), (metadata, exception) -> {
      if (exception == null) {
        callback.onSuccess(null);
      } else {
        callback.onError(exception);
      }
    });
  }

  @Override public Call<Void> clone() {
    return new KafkaCall(message);
  }
}
```

这里还有一个知识点，get 方法每次都会返回一个新的 KafkaProducer，我在第一眼看到这段代码时也曾怀疑，难道这里没有性能问题？ 原来这里用到了google的插件 autovalue 里的标签 @Memoized，结合 @AutoValue 标签，它会在自动生成的类里，给我们添加一些代码，可以看到 get 方法里作了一层缓存，所以我们的担心是没有必要的

```java
@Memoized KafkaProducer<byte[], byte[]> get() {
  KafkaProducer<byte[], byte[]> result = new KafkaProducer<>(properties());
  provisioned = true;
  return result;
}
```

AutoValue_KafkaSender

```java
final class AutoValue_KafkaSender extends $AutoValue_KafkaSender {
  private volatile KafkaProducer<byte[], byte[]> get;

  AutoValue_KafkaSender(Encoding encoding$, int messageMaxBytes$, BytesMessageEncoder encoder$,
      String topic$, Properties properties$) {
    super(encoding$, messageMaxBytes$, encoder$, topic$, properties$);
  }

  @Override
  KafkaProducer<byte[], byte[]> get() {
    if (get == null) {
      synchronized (this) {
        if (get == null) {
          get = super.get();
          if (get == null) {
            throw new NullPointerException("get() cannot return null");
          }
        }
      }
    }
    return get;
  }
}
```

## 2. KafkaCollector

我们再来看下 Zipkin 中的 KafkaCollector，我们打开 zipkin-server 的源代码，在目录 resources/zipkin-server-shared.yml 文件中，发现关于 kafka 的配置片段。而我们在本文前面使用 –KAFKA_ZOOKEEPER 启动了 Zipkin，将 kafka 的 zookeeper 参数传递给了KafkaServer 的 main 方法，也就是说，我们制定了 zipkin.collector.kafka.zookeeper 的值为 localhost:2181。

```bash
java -jar zipkin-server-2.2.1-exec.jar --KAFKA_ZOOKEEPER=localhost:2181
```

zipkin-server-shared.yml

```java
zipkin:
  collector:
    kafka:
      # ZooKeeper host string, comma-separated host:port value.
      zookeeper: ${KAFKA_ZOOKEEPER:}
      # Name of topic to poll for spans
      topic: ${KAFKA_TOPIC:zipkin}
      # Consumer group this process is consuming on behalf of.
      group-id: ${KAFKA_GROUP_ID:zipkin}
      # Count of consumer threads consuming the topic
      streams: ${KAFKA_STREAMS:1}
      # Maximum size of a message containing spans in bytes
      max-message-size: ${KAFKA_MAX_MESSAGE_SIZE:1048576}
```

在 pom.xml 中，有如下依赖

```xml
<!-- Kafka Collector -->
<dependency>
  <groupId>${project.groupId}</groupId>
  <artifactId>zipkin-autoconfigure-collector-kafka</artifactId>
  <optional>true</optional>
</dependency>
```

## 3. ZipkinKafkaCollectorAutoConfiguration

我们找到 zipkin-autoconfigure/collector-kafka 的 ZipkinKafkaCollectorAutoConfiguration 类，使用了 @Conditional 注解，当KafkaZooKeeperSetCondition 条件满足时，ZipkinKafkaCollectorAutoConfiguration 类会被 SpringBoot 加载。当加载时，会配置 KafkaCollector 到 spring 容器中。

```java
@Configuration
@EnableConfigurationProperties(ZipkinKafkaCollectorProperties.class)
@Conditional(KafkaZooKeeperSetCondition.class)
public class ZipkinKafkaCollectorAutoConfiguration {

  /**
   * This launches a thread to run start. This prevents a several second hang, or worse crash if
   * zookeeper isn't running, yet.
   */
  @Bean KafkaCollector kafka(ZipkinKafkaCollectorProperties kafka, CollectorSampler sampler,
      CollectorMetrics metrics, StorageComponent storage) {
    final KafkaCollector result =
        kafka.toBuilder().sampler(sampler).metrics(metrics).storage(storage).build();

    // don't use @Bean(initMethod = "start") as it can crash the process if zookeeper is down
    Thread start = new Thread("start " + result.getClass().getSimpleName()) {
      @Override public void run() {
        result.start();
      }
    };
    start.setDaemon(true);
    start.start();

    return result;
  }
}
```

## 4. KafkaZooKeeperSetCondition

KafkaZooKeeperSetCondition 继承了 SpringBootCondition，实现了 getMatchOutcome 方法，当上下文的环境变量中有配置zipkin.collector.kafka.zookeeper 的时候，则条件满足，即 ZipkinKafkaCollectorAutoConfiguration 会被加载。

```java
final class KafkaZooKeeperSetCondition extends SpringBootCondition {
  static final String PROPERTY_NAME = "zipkin.collector.kafka.zookeeper";

  @Override
  public ConditionOutcome getMatchOutcome(ConditionContext context, AnnotatedTypeMetadata a) {
    String kafkaZookeeper = context.getEnvironment().getProperty(PROPERTY_NAME);
    return kafkaZookeeper == null || kafkaZookeeper.isEmpty() ?
        ConditionOutcome.noMatch(PROPERTY_NAME + " isn't set") :
        ConditionOutcome.match();
  }
}
```

在 ZipkinKafkaCollectorAutoConfiguration 中，启动了一个守护线程来运行 KafkaCollector 的 start 方法，避免 zookeeper 连不上，阻塞 Zipkin 的启动过程。

```java
public final class KafkaCollector implements CollectorComponent {
  final LazyConnector connector;
  final LazyStreams streams;

  KafkaCollector(Builder builder) {
    connector = new LazyConnector(builder);
    streams = new LazyStreams(builder, connector);
  }

  @Override public KafkaCollector start() {
    connector.get();
    streams.get();
    return this;
  }
}
```

KafkaCollector 中初始化了两个对象，LazyConnector 和 LazyStreams，在 start 方法中调用了2个对象的 get 方法。

## 5. LazyConnector

LazyConnector 继承了 Lazy，当 get 方法被调用的时候，compute 方法会被调用。

```
static final class LazyConnector extends LazyCloseable<ZookeeperConsumerConnector> {

  final ConsumerConfig config;

  LazyConnector(Builder builder) {
    this.config = new ConsumerConfig(builder.properties);
  }

  @Override protected ZookeeperConsumerConnector compute() {
    return (ZookeeperConsumerConnector) createJavaConsumerConnector(config);
  }

  @Override
  public void close() {
    ZookeeperConsumerConnector maybeNull = maybeNull();
    if (maybeNull != null) maybeNull.shutdown();
  }
}
```

Lazy 的 get 方法中，使用了典型的懒汉式单例模式，并使用了 double-check，方式多线程构造多个实例，而真正构造对象是委派给compute 方法。

```java
public abstract class Lazy<T> {

  volatile T instance = null;

  /** Remembers the result, if the operation completed unexceptionally. */
  protected abstract T compute();

  /** Returns the same value, computing as necessary */
  public final T get() {
    T result = instance;
    if (result == null) {
      synchronized (this) {
        result = instance;
        if (result == null) {
          instance = result = tryCompute();
        }
      }
    }
    return result;
  }

  /**
   * This is called in a synchronized block when the value to memorize hasn't yet been computed.
   *
   * <p>Extracted only for LazyCloseable, hence package protection.
   */
  T tryCompute() {
    return compute();
  }
}
```

在 LazyConnector 的 compute 方法中根据 ConsumerConfig 构造出了 ZookeeperConsumerConnector，这个是kafka 0.8版本一种重要的对象，基于 zookeeper 的 ConsumerConnector。

## 6. LazyStreams

在 LazyStreams 的 compute 中，新建了一个线程池，线程池大小可以由参数 streams（即zipkin.collector.kafka.streams）来指定，默认为一个线程的线程池。 然后通过 topicCountMap 设置 Zipkin 的 kafka 消费使用的线程数，再使用 ZookeeperConsumerConnector的 createMessageStreams 方法来创建 KafkaStream，然后使用线程池执行 KafkaStreamProcessor。

```java
static final class LazyStreams extends LazyCloseable<ExecutorService> {
  final int streams;
  final String topic;
  final Collector collector;
  final CollectorMetrics metrics;
  final LazyCloseable<ZookeeperConsumerConnector> connector;
  final AtomicReference<CheckResult> failure = new AtomicReference<>();

  LazyStreams(Builder builder, LazyCloseable<ZookeeperConsumerConnector> connector) {
    this.streams = builder.streams;
    this.topic = builder.topic;
    this.collector = builder.delegate.build();
    this.metrics = builder.metrics;
    this.connector = connector;
  }

  @Override protected ExecutorService compute() {
    ExecutorService pool = streams == 1
        ? Executors.newSingleThreadExecutor()
        : Executors.newFixedThreadPool(streams);

    Map<String, Integer> topicCountMap = new LinkedHashMap<>(1);
    topicCountMap.put(topic, streams);

    for (KafkaStream<byte[], byte[]> stream : connector.get().createMessageStreams(topicCountMap)
        .get(topic)) {
      pool.execute(guardFailures(new KafkaStreamProcessor(stream, collector, metrics)));
    }
    return pool;
  }

  Runnable guardFailures(final Runnable delegate) {
    return () -> {
      try {
        delegate.run();
      } catch (RuntimeException e) {
        failure.set(CheckResult.failed(e));
      }
    };
  }

  @Override
  public void close() {
    ExecutorService maybeNull = maybeNull();
    if (maybeNull != null) maybeNull.shutdown();
  }
}
```

## 7. KafkaStreamProcessor

在 KafkaStreamProcessor 的 run 方法中，迭代 stream 对象，取出获得的流数据，然后调用 Collector 的 acceptSpans 方法，即使用storage 组件来接收并存储 span 数据。

```java
final class KafkaStreamProcessor implements Runnable {
  final KafkaStream<byte[], byte[]> stream;
  final Collector collector;
  final CollectorMetrics metrics;

  KafkaStreamProcessor(
      KafkaStream<byte[], byte[]> stream, Collector collector, CollectorMetrics metrics) {
    this.stream = stream;
    this.collector = collector;
    this.metrics = metrics;
  }

  @Override
  public void run() {
    ConsumerIterator<byte[], byte[]> messages = stream.iterator();
    while (messages.hasNext()) {
      byte[] bytes = messages.next().message();
      metrics.incrementMessages();

      if (bytes.length == 0) {
        metrics.incrementMessagesDropped();
        continue;
      }

      // If we received legacy single-span encoding, decode it into a singleton list
      if (bytes[0] <= 16 && bytes[0] != 12 /* thrift, but not a list */) {
        try {
          metrics.incrementBytes(bytes.length);
          Span span = SpanDecoder.THRIFT_DECODER.readSpan(bytes);
          collector.accept(Collections.singletonList(span), NOOP);
        } catch (RuntimeException e) {
          metrics.incrementMessagesDropped();
        }
      } else {
        collector.acceptSpans(bytes, DETECTING_DECODER, NOOP);
      }
    }
  }
}
```

这里的 kafka 消费方式还是 kafka 0.8版本的，如果你想用 kafka 0.10+的版本，可以更改 zipkin-server 的 pom，将 collector-kafka10 加入到依赖中，其原理跟 kafka0.8 的差不多，此处不再展开分析了。

```xml
<!-- Kafka10 Collector -->
<dependency>
  <groupId>io.zipkin.java</groupId>
  <artifactId>zipkin-autoconfigure-collector-kafka10</artifactId>
  <optional>true</optional>
</dependency>

<dependency>
  <groupId>io.zipkin.java</groupId>
  <artifactId>zipkin-collector-kafka10</artifactId>
</dependency>
```

在生产环境中，我们可以将 Zipkin 的日志收集器改为 kafka 来提高系统的吞吐量，而且也可以让客户端和 zipkin 服务端解耦，客户端将不依赖 Zipkin 服务端，只依赖 kafka 集群。

当然我们也可以将 Zipkin 的 collector 替换为 RabbitMQ 来提高日志收集的效率，Zipkin 对 scribe 也作了支持，这里就不展开篇幅细说了。



## 参考

[Java分布式跟踪系统Zipkin（八）：Zipkin源码分析-KafkaCollector](http://blog.mozhu.org/2017/11/16/zipkin/zipkin-8.html)
