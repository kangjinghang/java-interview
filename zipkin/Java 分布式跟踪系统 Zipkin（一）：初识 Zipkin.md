## 1. 概述

Zipkin 是一款开源的分布式实时数据追踪系统（Distributed Tracking System），基于 Google Dapper 的论文设计而来，由 Twitter 公司开发贡献。其主要功能是聚集来自各个异构系统的实时监控数据。

Zipkin 整体架构如下图所示，分成三个部分：

![img](http://blog-1259650185.cosbj.myqcloud.com/img/202205/09/1652060576.png)

- 【红框】**Zipkin Tracer** ：负责从应用中，收集分布式场景下的调用链路数据，发送给 Zipkin Server 服务。
- 【蓝框】**Transport** ：链路数据的传输方式，目前有 HTTP、MQ 等等多种方式。
- 【绿框】**Zipkin Server** ：负责接收 Tracer 发送的 Tracing 数据信息，将其聚合处理并进行存储，后提供查询功能。之后，用户可通过 Web UI 方便获得服务延迟、调用链路、系统依赖等等。

### 1.1 Zipkin Tracer

Zipkin Tracer（追踪器）驻留在你的应用程序里，并且记录发生操作的时间和元数据。他们经常[装配在库](https://zipkin.io/pages/tracers_instrumentation.html)上，所以对用户来说是透明的。举个例子，一个装配过的 Web 服务器，会在接收请求和发送响应进行记录。收集的追踪数据叫做 **Span（跨度）**。

> 一般来说，在 Java 应用程序中，我们使用 [Brave](https://github.com/openzipkin/brave) 库，作为 Zipkin Server 的 Java Tracer 客户端。同时它的 [instrumentation](https://github.com/openzipkin/brave/tree/master/instrumentation) 子项目，已经提供了 SpringMVC、MySQL、Dubbo 等等的链路追踪的功能。

生产环境中的装配器应该是安全并且低负载的。为此，带内（in-band）只**传输 ID**，并且告诉接收器仍有一个追踪在处理。完成的跨度在带外（out-of-band）汇报给 Zipkin，类似于应用程序异步汇报指标一样。

- 举个例子，当追踪一个操作的时候，该操作对外发送了一个 HTTP 请求，那么，为了传输 ID 就会添加一些额外的头部信息。头部信息并不是用于发送像是操作明这样的详细信息的。

在上面的 Zipkin 架构图，胖友对可能对 Instrumented Client 和 Instrumented Server 有点懵逼？

- Instrumented Client 和 Instrumented Server，它们是指分布式架构中使用了 Tracer 工具的两个应用，Client 会调用 Server 提供的服务，**两者**都会向 Zipkin 上报链路数据。
- Non-Instrumented Server，指的是未使用 Trace 工具的 Server，显然它**不会**上报链路数据，但是调用其的 Instrumented Client **还是会**上报链路数据。

### 1.2 Transport

在装配应用中，用于向 Zipkin 发送数据的组件叫做 **Reporter**。Reporter 通过 **Transport** 发送追踪数据到 Zipkin 的 Collector，Collector 持久化数据到 Storage 中。之后，API 从 Storage 中查询数据提供给 UI。

> 一般来说，在 Java 应用程序中，我们使用 [zipkin-reporter-java](https://github.com/openzipkin/zipkin-reporter-java) 库，作为 Zipkin Reporter 客户端。包括如下的 Transport 方式：
>
> - HTTP ，通过 [okhttp3](https://github.com/openzipkin/zipkin-reporter-java/blob/master/okhttp3/) 或 [urlconnection](https://github.com/openzipkin/zipkin-reporter-java/tree/master/urlconnection) 实现。
> - ActiveMQ，通过 [activemq-client](https://github.com/openzipkin/zipkin-reporter-java/tree/master/activemq-client) 实现。
> - RabbitMQ，通过 [amqp-client](https://github.com/openzipkin/zipkin-reporter-java/blob/master/amqp-client/) 实现。
> - Kafka，通过 [kafka](https://github.com/openzipkin/zipkin-reporter-java/blob/master/kafka) 或 [kafka08](https://github.com/openzipkin/zipkin-reporter-java/blob/master/kafka08) 实现。
> - Thrift，通过 [libthrift](https://github.com/openzipkin/zipkin-reporter-java/blob/master/libthrift/) 实现。
>
> 请求量级小的时候，采用 HTTP 传输即可。量较大的时候，推荐使用 Kafka 消息队列。

### 1.3 Zipkin Server

Zipkin Server 包括 Collector、Storage、API、UI 四个组件。

**① Collector**

Collector 负责接收 Tracer 发送的链路数据，并为了后续的查询，对链路数据进行校验、存储、索引。

**② Storage**

Storage 负责存储链路数据，目前支持 Memory、MySQL、Cassandra、ElasticSearch 等数据库。

- Memory ：默认存储器，用于简单演示为主，生产环境下不推荐。
- MySQL ：小规模使用时，可以考虑 MySQL 进行存储。
- ElasticSearch ：主流的选择，问了一圈朋友，基本采用 ElasticSearch 存储链路数据。
- Cassandra ：在 Twitter 内部被大规模使用，，因为 Cassandra 易跨站，支持灵活的 schema。

**③ API**

API 负责提供了一个简单的 JSON API 查询和获取追踪数据。API 的主要消费者就是 Web UI。

**④ UI**

Web UI 负责提供了基于服务、时间和标记（annotation）查看服务延迟、调用链路、系统依赖等等的界面。

## 2. 流程图

```ba
┌─────────────┐ ┌───────────────────────┐  ┌─────────────┐  ┌──────────────────┐
│ User Code   │ │ Trace Instrumentation │  │ Http Client │  │ Zipkin Collector │
└─────────────┘ └───────────────────────┘  └─────────────┘  └──────────────────┘
       │                 │                         │                 │
           ┌─────────┐
       │ ──┤GET /foo ├─▶ │ ────┐                   │                 │
           └─────────┘         │ record tags
       │                 │ ◀───┘                   │                 │
                           ────┐
       │                 │     │ add trace headers │                 │
                           ◀───┘
       │                 │ ────┐                   │                 │
                               │ record timestamp
       │                 │ ◀───┘                   │                 │
                             ┌─────────────────┐
       │                 │ ──┤GET /foo         ├─▶ │                 │
                             │X-B3-TraceId: aa │     ────┐
       │                 │   │X-B3-SpanId: 6b  │   │     │           │
                             └─────────────────┘         │ invoke
       │                 │                         │     │ request   │
                                                         │
       │                 │                         │     │           │
                                 ┌────────┐          ◀───┘
       │                 │ ◀─────┤200 OK  ├─────── │                 │
                           ────┐ └────────┘
       │                 │     │ record duration   │                 │
            ┌────────┐     ◀───┘
       │ ◀──┤200 OK  ├── │                         │                 │
            └────────┘       ┌────────────────────────────────┐
       │                 │ ──┤ asynchronously report span     ├────▶ │
                             │                                │
                             │{                               │
                             │  "traceId": "aa",              │
                             │  "id": "6b",                   │
                             │  "name": "get",                │
                             │  "timestamp": 1483945573944000,│
                             │  "duration": 386000,           │
                             │  "annotations": [              │
                             │--snip--                        │
                             └────────────────────────────────┘
```

由上图可以看出，应用的代码（User Code）发起 Http Get 请求（请求路径 /foo），经过 Trace 框架（Trace Instrumentation）拦截，并依次经过如下步骤，记录 Trace 信息到 Zipkin 中：

1. record tags ：记录 tags 信息到 Span 中。
2. add trace headers ：将当前调用链的链路信息记录到 Http Headers 中。
3. record timestamp ：记录当前调用的时间戳（timestamp）。
4. 发送 HTTP 请求，并携带 Trace 相关的 Header。例如说， `X-B3-TraceId:aa`，`X-B3-SpandId:6b`。
5. 调用结束后，记录当次调用所花的时间（duration）。
6. 将步骤1-5，汇总成一个Span（最小的Trace单元），异步上报该 Span 信息给 Zipkin Collector。

## 3. Zipkin 的几个基本概念

**Span**：基本工作单元，一次链路调用（可以是 RPC，DB 等没有特定的限制）创建一个 span，通过一个64位 ID 标识它。Span 还有其它的数据，例如描述信息，时间戳，key-value 对的（Annotation）Tag 信息，parent-id 等等。其中，parent-id 可以表示 Span 调用链路来源。通俗的理解 ，Span 就是一次请求信息。

**Trace**：类似于树结构的 Span 集合，表示一条完整的调用链路，存在唯一标识，即 TraceId 链路编号。

**Annotation**：注解，用来记录请求特定事件相关信息（例如时间），通常包含四个注解信息：

- **cs** - Client Start，表示客户端发起请求。
- **sr** - Server Receive，表示服务端收到请求。
- **ss** - Server Send，表示服务端完成处理，并将结果发送给客户端。
- **cr** - Client Received，表示客户端获取到服务端返回信息。

**BinaryAnnotation**：提供一些额外信息，一般以key-value对出现。

## 4. 安装

本系列博文使用的 Zipkin 版本为2.2.1，所需 JDK 为1.8

下载最新的 Zipkin 的 jar包，并运行

```bash
wget -O zipkin.jar 'https://search.maven.org/remote_content?g=io.zipkin.java&a=zipkin-server&v=LATEST&c=exec'
java -jar zipkin.jar
```

还可以使用docker，具体操作请参考：

https://github.com/openzipkin/docker-zipkin

启动成功后浏览器访问

http://localhost:9411/

打开Zipkin的Web UI界面

下面用一个简单的Web应用来演示如何向Zipkin上报追踪数据

代码地址：https://gitee.com/mozhu/zipkin-learning

在Chapter1/servlet25中，演示了如何在传统的Servlet项目中使用Brave框架，向Zipkin上传Trace数据

分别运行`mvn jetty:run -Pbackend`  和 `mvn jetty:run -Pfrontend`。

则会启动两个端口为8081和9000的服务，Frontend会发送请求到Backend，Backend返回当前时间

Frontend: http://localhost:8081/

Backend: http://localhost:9000/api

浏览器访问 http://localhost:8081/ 会显示当前时间

Fri Nov 03 18:43:00 GMT+08:00 2017

打开Zipkin Web UI界面，点击 Find Traces，显示如下界面：
![image-20220511114438867](http://blog-1259650185.cosbj.myqcloud.com/img/202205/11/1652240678.png)

继续点击，查看详情，界面如下：
![image-20220511114626463](http://blog-1259650185.cosbj.myqcloud.com/img/202205/11/1652240786.png)

可以看到Frontend调用Backend的跟踪链信息，Frontend整个过程耗时113.839ms，其中调用Backend服务耗时67.805ms

点击左侧跟踪栈的frontend和backend，分别打开每条跟踪栈的详细信息
[![frontend跟踪栈信息](http://static.blog.mozhu.org/images/zipkin/1_4.png)](http://static.blog.mozhu.org/images/zipkin/1_4.png)frontend跟踪栈信息
[![backend跟踪栈信息](http://static.blog.mozhu.org/images/zipkin/1_5.png)](http://static.blog.mozhu.org/images/zipkin/1_5.png)backend跟踪栈信息

点击页面右上角的JSON，可以看到该Trace的所有数据

```json
[
  {
    "traceId": "f3e648a459e6c685",
    "id": "f3e648a459e6c685",
    "name": "get",
    "timestamp": 1509771706395235,
    "duration": 113839,
    "annotations": [
      {
        "timestamp": 1509771706395235,
        "value": "sr",
        "endpoint": {
          "serviceName": "frontend",
          "ipv4": "192.168.1.8"
        }
      },
      {
        "timestamp": 1509771706509074,
        "value": "ss",
        "endpoint": {
          "serviceName": "frontend",
          "ipv4": "192.168.1.8"
        }
      }
    ],
    "binaryAnnotations": [
      {
        "key": "ca",
        "value": true,
        "endpoint": {
          "serviceName": "",
          "ipv6": "::1",
          "port": 55037
        }
      },
      {
        "key": "http.path",
        "value": "/",
        "endpoint": {
          "serviceName": "frontend",
          "ipv4": "192.168.1.8"
        }
      }
    ]
  },
  {
    "traceId": "f3e648a459e6c685",
    "id": "2ce51fa654dd0c2f",
    "name": "get",
    "parentId": "f3e648a459e6c685",
    "timestamp": 1509771706434207,
    "duration": 67805,
    "annotations": [
      {
        "timestamp": 1509771706434207,
        "value": "cs",
        "endpoint": {
          "serviceName": "frontend",
          "ipv4": "192.168.1.8"
        }
      },
      {
        "timestamp": 1509771706479391,
        "value": "sr",
        "endpoint": {
          "serviceName": "backend",
          "ipv4": "192.168.1.8"
        }
      },
      {
        "timestamp": 1509771706495481,
        "value": "ss",
        "endpoint": {
          "serviceName": "backend",
          "ipv4": "192.168.1.8"
        }
      },
      {
        "timestamp": 1509771706502012,
        "value": "cr",
        "endpoint": {
          "serviceName": "frontend",
          "ipv4": "192.168.1.8"
        }
      }
    ],
    "binaryAnnotations": [
      {
        "key": "ca",
        "value": true,
        "endpoint": {
          "serviceName": "",
          "ipv4": "127.0.0.1",
          "port": 55038
        }
      },
      {
        "key": "http.path",
        "value": "/api",
        "endpoint": {
          "serviceName": "frontend",
          "ipv4": "192.168.1.8"
        }
      },
      {
        "key": "http.path",
        "value": "/api",
        "endpoint": {
          "serviceName": "backend",
          "ipv4": "192.168.1.8"
        }
      },
      {
        "key": "sa",
        "value": true,
        "endpoint": {
          "serviceName": "",
          "ipv4": "127.0.0.1",
          "port": 9000
        }
      }
    ]
  }
]
```

点击Dependencies页面，可以看到下图，frontend和backend的依赖关系图

[![frontend和backend的依赖关系图](http://static.blog.mozhu.org/images/zipkin/1_5.png)](http://static.blog.mozhu.org/images/zipkin/1_5.png)frontend和backend的依赖关系图

在复杂的调用链路中假设存在一条调用链路响应缓慢，如何定位其中延迟高的服务呢？
在使用分布式跟踪系统之前，我们一般只能依次分析调用链路上各个系统中的日志文件，
而在使用了Zipkin提供的WebUI界面后，我们很容易搜索出一个调用链路中延迟高的服务

后面博文中会详细介绍Zipkin的用法原理，以及和我们现有的系统框架整合。



## 参考

[芋道 Zipkin 极简入门](https://www.iocoder.cn/Zipkin/install/)

[Java分布式跟踪系统Zipkin（一）：初识Zipkin](http://blog.mozhu.org/2017/11/10/zipkin/zipkin-1.html)
