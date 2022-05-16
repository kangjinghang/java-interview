上一篇博文中，我们分析了Tracing的相关源代码，这一篇我们来看看Brave是如何在Web项目中使用的

我们先来看看普通的servlet项目中，如何使用Brave，这对我们后面分析和理解Brave和SpringMVC等框架整合有帮助

首先Chapter1/servlet25项目中配置了FrontServlet和BackendServlet以及TracingFilter

web.xml

```xml
<web-app xmlns="http://java.sun.com/xml/ns/javaee"
    xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance"
    xsi:schemaLocation="http://java.sun.com/xml/ns/javaee
	http://java.sun.com/xml/ns/javaee/web-app_2_5.xsd"
    version="2.5">

  <display-name>Servlet2.5 Application</display-name>

  <filter>
    <filter-name>TracingFilter</filter-name>
    <filter-class>org.mozhu.zipkin.filter.BraveTracingFilter</filter-class>
  </filter>
  <filter-mapping>
    <filter-name>TracingFilter</filter-name>
    <url-pattern>/*</url-pattern>
  </filter-mapping>

  <servlet>
    <servlet-name>BackendServlet</servlet-name>
    <servlet-class>org.mozhu.zipkin.servlet.BackendServlet</servlet-class>
    <load-on-startup>1</load-on-startup>
  </servlet>
  <servlet-mapping>
    <servlet-name>BackendServlet</servlet-name>
    <url-pattern>/api</url-pattern>
  </servlet-mapping>

  <servlet>
    <servlet-name>FrontendServlet</servlet-name>
    <servlet-class>org.mozhu.zipkin.servlet.FrontendServlet</servlet-class>
    <load-on-startup>1</load-on-startup>
  </servlet>
  <servlet-mapping>
    <servlet-name>FrontendServlet</servlet-name>
    <url-pattern>/</url-pattern>
  </servlet-mapping>
</web-app>
```

## 1. TracingFilter

我们使用自定义的 BraveTracingFilter 作为入口，其 init 方法中，我们初始化了 Tracing，然后创建 HttpTracing 对象，最后调用TracingFilter.create(httpTracing) 创建了 tracingFilter。 doFilter 方法中，所有请求将被 tracingFilter 来处理。

BraveTracingFilter

```java
package org.mozhu.zipkin.filter;

import brave.Tracing;
import brave.context.log4j2.ThreadContextCurrentTraceContext;
import brave.http.HttpTracing;
import brave.propagation.B3Propagation;
import brave.propagation.ExtraFieldPropagation;
import brave.servlet.TracingFilter;
import zipkin2.codec.SpanBytesEncoder;
import zipkin2.reporter.AsyncReporter;
import zipkin2.reporter.Sender;
import zipkin2.reporter.okhttp3.OkHttpSender;

import javax.servlet.*;
import java.io.IOException;
import java.util.concurrent.TimeUnit;

public class BraveTracingFilter implements Filter {
    Filter tracingFilter;

    @Override
    public void init(FilterConfig filterConfig) throws ServletException {
        Sender sender = OkHttpSender.create("http://localhost:9411/api/v2/spans");
        AsyncReporter asyncReporter = AsyncReporter.builder(sender)
                .closeTimeout(500, TimeUnit.MILLISECONDS)
                .build(SpanBytesEncoder.JSON_V2);

        Tracing tracing = Tracing.newBuilder()
                .localServiceName(System.getProperty("zipkin.service", "servlet25-demo"))
                .spanReporter(asyncReporter)
                .propagationFactory(ExtraFieldPropagation.newFactory(B3Propagation.FACTORY, "user-name"))
                .currentTraceContext(ThreadContextCurrentTraceContext.create())
                .build();

        HttpTracing httpTracing = HttpTracing.create(tracing);
        filterConfig.getServletContext().setAttribute("TRACING", httpTracing);
        tracingFilter = TracingFilter.create(httpTracing);
        tracingFilter.init(filterConfig);
    }

    @Override
    public void doFilter(ServletRequest servletRequest, ServletResponse servletResponse, FilterChain filterChain) throws IOException, ServletException {
        tracingFilter.doFilter(servletRequest, servletResponse, filterChain);
    }

    @Override
    public void destroy() {
        tracingFilter.destroy();
    }

}
```

## 2. TracingFilter

TracingFilter 在 brave-instrumentation-servlet 包中。

```java
public final class TracingFilter implements Filter {
  public static Filter create(Tracing tracing) {
    return new TracingFilter(HttpTracing.create(tracing));
  }

  public static Filter create(HttpTracing httpTracing) {
    return new TracingFilter(httpTracing);
  }

  final ServletRuntime servlet = ServletRuntime.get();
  final Tracer tracer;
  final HttpServerHandler<HttpServletRequest, HttpServletResponse> handler;
  final TraceContext.Extractor<HttpServletRequest> extractor;

  TracingFilter(HttpTracing httpTracing) {
    tracer = httpTracing.tracing().tracer();
    handler = HttpServerHandler.create(httpTracing, new HttpServletAdapter());
    extractor = httpTracing.tracing().propagation().extractor(HttpServletRequest::getHeader);
  }
}
```

TracingFilter 中几个重要的类

- HttpTracing - 包含 Http 处理相关的组件，clientParser，serverParser，clientSampler，serverSampler
- ServletRuntime - Servlet 运行时类，包含根据环境来判断是否支持 Servlet3 异步调用等方法
- HttpServerHandler - Http 处理的核心组件，基本上所有和 trace 相关的操作均在此类中完成
- HttpServletAdapter - HttpServlet 的适配器接口，此类的引入可以让 httpServerHandler 类变得更为通用，因为它是一个泛型接口，跟具体的 request 和 response 无关，能和更多框架进行整合
- TraceContext.Extractor - TraceContext 的数据提取器

doFilter 方法

```
@Override
  public void doFilter(ServletRequest request, ServletResponse response, FilterChain chain)
      throws IOException, ServletException {
    HttpServletRequest httpRequest = (HttpServletRequest) request;
    HttpServletResponse httpResponse = servlet.httpResponse(response);

    Span span = handler.handleReceive(extractor, httpRequest);
    Throwable error = null;
    try (Tracer.SpanInScope ws = tracer.withSpanInScope(span)) {
      chain.doFilter(httpRequest, httpResponse); // any downstream filters see Tracer.currentSpan
    } catch (IOException | ServletException | RuntimeException | Error e) {
      error = e;
      throw e;
    } finally {
      if (servlet.isAsync(httpRequest)) { // we don't have the actual response, handle later
        servlet.handleAsync(handler, httpRequest, span);
      } else { // we have a synchronous response, so we can finish the span
        handler.handleSend(httpResponse, error, span);
      }
    }
  }
```

- 首先调用 handler.handleReceive(extractor, httpRequest) 从 request 中提取 Span 信息。
- 然后调用 tracer.withSpanInScope(span) 将 Span 包装成 Tracer.SpanInScope，而 Tracer.SpanInScope 和前面博文中分析的CurrentTraceContext.Scope 比较像，都实现了 Closeable 接口，这里的目的也一样，都是为了利用 JDK7 的 try-with-resources 的特性，JVM 会自动调用 close 方法，做一些线程对象的清理工作。其区别是后者是 SPI（Service Provider Interface），不适合暴露给真正的使用者。 这样使得 chain.doFilter(httpRequest, httpResponse) 里的代码能用 Tracer.currentSpan 拿到从请求中提取（extract）的 Span 信息。
- 最后调用 handler.handleSend(httpResponse, error, span)。

下面来仔细分析下 handler 中 handleReceive 和 handleSend 两个方法。

handleReceive 方法 

```java
public Span handleReceive(TraceContext.Extractor<Req> extractor, Req request) {
  return handleReceive(extractor, request, request);
}

public <C> Span handleReceive(TraceContext.Extractor<C> extractor, C carrier, Req request) {
  Span span = nextSpan(extractor.extract(carrier), request);
  if (span.isNoop()) return span;

  // all of the parsing here occur before a timestamp is recorded on the span
  span.kind(Span.Kind.SERVER);

  // Ensure user-code can read the current trace context
  Tracer.SpanInScope ws = tracer.withSpanInScope(span);
  try {
    parser.request(adapter, request, span);
  } finally {
    ws.close();
  }

  boolean parsedEndpoint = false;
  if (Platform.get().zipkinV1Present()) {
    zipkin.Endpoint.Builder deprecatedEndpoint = zipkin.Endpoint.builder().serviceName("");
    if ((parsedEndpoint = adapter.parseClientAddress(request, deprecatedEndpoint))) {
      span.remoteEndpoint(deprecatedEndpoint.build());
    }
  }
  if (!parsedEndpoint) {
    Endpoint.Builder remoteEndpoint = Endpoint.newBuilder();
    if (adapter.parseClientAddress(request, remoteEndpoint)) {
      span.remoteEndpoint(remoteEndpoint.build());
    }
  }
  return span.start();
}
```

- 首先调用 nextSpan(extractor.extract(carrier), request) 从 request 中提取 TraceContextOrSamplingFlags，并创建 Span，并将Span 的 kind 类型设置为 SERVER。
- 然后调用 parser.request(adapter, request, span)，将 request 的内容，将 span 的 name 改为 request 的 method 即 GET 或者POST，而且会将当前请求的路径以 Tag(http.path) 写入 Span 中，这样我们就能在 Zipkin 的 UI 界面中能清晰的看出某个 Span 是发起了什么请求。
- 最后为 Span 设置 Endpoint 信息，并调用 start 设置开始时间。

handleSend 方法

```java
public void handleSend(@Nullable Resp response, @Nullable Throwable error, Span span) {
  if (span.isNoop()) return;

  // Ensure user-code can read the current trace context
  Tracer.SpanInScope ws = tracer.withSpanInScope(span);
  try {
    parser.response(adapter, response, error, span);
  } finally {
    ws.close();
    span.finish();
  }
}
```

handleSend比较简单，调用 parser.response(adapter, response, error, span)，会将 HTTP 状态码写入 Span 的 Tag(http.status_code)中，如果有出错，则会将错误信息写入 Tag(error)中。最后会调用 Span 的 finish 方法，而 finish 方法中，会调用 Reporter 的 report 方法将 Span 信息上报到 Zipkin。

接着看下 nextSpan 方法

```java
Span nextSpan(TraceContextOrSamplingFlags extracted, Req request) {
  if (extracted.sampled() == null) { // Otherwise, try to make a new decision
    extracted = extracted.sampled(sampler.trySample(adapter, request));
  }
  return extracted.context() != null
      ? tracer.joinSpan(extracted.context())
      : tracer.nextSpan(extracted);
}
```

从请求里提取的对象 extracted（TraceContextOrSamplingFlags），如果没有 sampled 信息，则由 HttpSampler 的 trySample 方法来决定是否采样。如果 extracted 中含有 TraceContext 信息，则由 tracer 调用 joinSpan，加入已存在的 trace，这种情况一般是客户端代码使用将 trace 信息放入 header，而服务端收到请求后，则自动加入客户端发起的 trace 中，所以当 backend 的请求运行到这段代码，会 joinSpan。如果 extracted 中不含 TraceContext 信息，则由 tracer 调用 nextSpan，这种情况一般是我们用户发起的请求，比如浏览器发起，则请求 header 中肯定是没有 trace 信息的，所以当 frontend 的请求运行到这段代码，会新建一个 span。

joinSpan 方法

```java
public final Span joinSpan(TraceContext context) {
  if (context == null) throw new NullPointerException("context == null");
  if (!supportsJoin) return newChild(context);
  // If we are joining a trace, we are sharing IDs with the caller
  // If the sampled flag was left unset, we need to make the decision here
  TraceContext.Builder builder = context.toBuilder();
  if (context.sampled() == null) {
    builder.sampled(sampler.isSampled(context.traceId()));
  } else {
    builder.shared(true);
  }
  return toSpan(builder.build());
}

public Span newChild(TraceContext parent) {
  if (parent == null) throw new NullPointerException("parent == null");
  return nextSpan(TraceContextOrSamplingFlags.create(parent));
}
```

在 joinSpan 方法中，会共享调用方的 traceId，如果调用者没有传入 sampled 信息，则由服务端自己决定是否采样，即sampler.isSampled(context.traceId())。

nextSpan 方法

```java
public Span nextSpan(TraceContextOrSamplingFlags extracted) {
  TraceContext parent = extracted.context();
  if (extracted.samplingFlags() != null) {
    TraceContext implicitParent = currentTraceContext.get();
    if (implicitParent == null) {
      return toSpan(newRootContext(extracted.samplingFlags(), extracted.extra()));
    }
    // fall through, with an implicit parent, not an extracted one
    parent = appendExtra(implicitParent, extracted.extra());
  }
  long nextId = Platform.get().randomLong();
  if (parent != null) {
    return toSpan(parent.toBuilder() // copies "extra" from the parent
        .spanId(nextId)
        .parentId(parent.spanId())
        .shared(false)
        .build());
  }
  TraceIdContext traceIdContext = extracted.traceIdContext();
  if (extracted.traceIdContext() != null) {
    Boolean sampled = traceIdContext.sampled();
    if (sampled == null) sampled = sampler.isSampled(traceIdContext.traceId());
    return toSpan(TraceContext.newBuilder()
        .sampled(sampled)
        .debug(traceIdContext.debug())
        .traceIdHigh(traceIdContext.traceIdHigh()).traceId(traceIdContext.traceId())
        .spanId(nextId)
        .extra(extracted.extra()).build());
  }
  // TraceContextOrSamplingFlags is a union of 3 types, we've checked all three
  throw new AssertionError("should not reach here");
}
```

在 nextSpan 方法中，首先找出合适的 parent，当 parent 存在时，则新建一个 child Span，否则返回 new Span。

到这里服务端接受到请求后，是如何记录 Span 信息的代码已经分析完毕，接下来我们看看作为客户端，我们是如何上报 Span 信息。

### 2.1 FrontServlet

首先我们看到 FrontServet 中 init 方法里，我们初始化了 OkHttpClient，并将 TracingInterceptor 拦截器添加到 OkHttpClient 的NetworkInterceptor 拦截器栈中，然后还用 CurrentTraceContext 中的 ExecutorService 的包装方法，将 Dispatcher 中的ExecutorService 包装后设置到 OkHttpClient 中。

```java
package org.mozhu.zipkin.servlet;

import brave.http.HttpTracing;
import brave.okhttp3.TracingInterceptor;
import okhttp3.Dispatcher;
import okhttp3.OkHttpClient;
import okhttp3.Request;
import okhttp3.Response;
import org.slf4j.Logger;
import org.slf4j.LoggerFactory;

import javax.servlet.ServletConfig;
import javax.servlet.ServletException;
import javax.servlet.http.HttpServlet;
import javax.servlet.http.HttpServletRequest;
import javax.servlet.http.HttpServletResponse;
import java.io.IOException;
import java.io.PrintWriter;

public class FrontendServlet extends HttpServlet {

    private final static Logger LOGGER = LoggerFactory.getLogger(FrontendServlet.class);

    private OkHttpClient client;

    @Override
    public void init(ServletConfig config) throws ServletException {
        super.init(config);
        HttpTracing httpTracing = (HttpTracing) config.getServletContext().getAttribute("TRACING");
        client = new OkHttpClient.Builder()
                .dispatcher(new Dispatcher(
                        httpTracing.tracing().currentTraceContext()
                                .executorService(new Dispatcher().executorService())
                ))
                .addNetworkInterceptor(TracingInterceptor.create(httpTracing))
                .build();
    }

    @Override
    protected void service(HttpServletRequest req, HttpServletResponse resp) throws ServletException, IOException {
        LOGGER.info("frontend receive request");
        Request request = new Request.Builder()
                .url("http://localhost:9000/api")
                .build();

        Response response = client.newCall(request).execute();
        if (!response.isSuccessful()) throw new IOException("Unexpected code " + response);

        PrintWriter writer = resp.getWriter();
        writer.write(response.body().string());
        writer.flush();
        writer.close();
    }

}
```

```java
public final class TracingInterceptor implements Interceptor {
  // ...

  final Tracer tracer;
  final String remoteServiceName;
  final HttpClientHandler<Request, Response> handler;
  final TraceContext.Injector<Request.Builder> injector;

  TracingInterceptor(HttpTracing httpTracing) {
    if (httpTracing == null) throw new NullPointerException("HttpTracing == null");
    tracer = httpTracing.tracing().tracer();
    remoteServiceName = httpTracing.serverName();
    handler = HttpClientHandler.create(httpTracing, new HttpAdapter());
    injector = httpTracing.tracing().propagation().injector(SETTER);
  }
}
```

TracingInterceptor 中依赖 Tracer，TraceContext.Injector，HttpClientHandler，HttpAdapter。

- TraceContext.Injector - 将 Trace 信息注入到 HTTP Request 中，即放到 Http headers 中
- HttpClientHandler - 和 HttpServerHandler 对应，也是 Http 处理的核心组件，基本上所有和 trace 相关的操作均在此类中完成
- HttpAdapter - 能从 Http request 中获得各种数据，比如 method，请求 Path，header 值等

```java
@Override public Response intercept(Chain chain) throws IOException {
  Request request = chain.request();
  Request.Builder requestBuilder = request.newBuilder();

  Span span = handler.handleSend(injector, requestBuilder, request);
  parseServerAddress(chain.connection(), span);
  Response response = null;
  Throwable error = null;
  try (Tracer.SpanInScope ws = tracer.withSpanInScope(span)) {
    return response = chain.proceed(requestBuilder.build());
  } catch (IOException | RuntimeException | Error e) {
    error = e;
    throw e;
  } finally {
    handler.handleReceive(response, error, span);
  }
}
```

这里代码和 TracingFilter 中 doFilter 比较相似，是一个相反的过程：

- 首先将 trace 信息注入到 request 中，并创建 Span 对象。
- 然后调用 chain.proceed(requestBuilder.build()) 来执行发送 http 请求
- 最后 handler.handleReceive(response, error, span)

接下来看看 HttpClientHandler 的 handleSend 方法和 handleReceive 方法。

handleSend方法

```
public Span handleSend(TraceContext.Injector<Req> injector, Req request, Span span) {
  return handleSend(injector, request, request, span);
}

public <C> Span handleSend(TraceContext.Injector<C> injector, C carrier, Req request, Span span) {
  injector.inject(span.context(), carrier);
  if (span.isNoop()) return span;

  // all of the parsing here occur before a timestamp is recorded on the span
  span.kind(Span.Kind.CLIENT);

  // Ensure user-code can read the current trace context
  Tracer.SpanInScope ws = tracer.withSpanInScope(span);
  try {
    parser.request(adapter, request, span);
  } finally {
    ws.close();
  }

  boolean parsedEndpoint = false;
  if (Platform.get().zipkinV1Present()) {
    zipkin.Endpoint.Builder deprecatedEndpoint = zipkin.Endpoint.builder()
        .serviceName(serverNameSet ? serverName : "");
    if ((parsedEndpoint = adapter.parseServerAddress(request, deprecatedEndpoint))) {
      span.remoteEndpoint(deprecatedEndpoint.serviceName(serverName).build());
    }
  }
  if (!parsedEndpoint) {
    Endpoint.Builder remoteEndpoint = Endpoint.newBuilder().serviceName(serverName);
    if (adapter.parseServerAddress(request, remoteEndpoint) || serverNameSet) {
      span.remoteEndpoint(remoteEndpoint.build());
    }
  }
  return span.start();
}
```

- 首先调用 injector.inject(span.context(), carrier) 将 Trace 信息注入 request 中，并将 Span 的 kind 类型设置为 CLIENT。
- 然后调用 parser.request(adapter, request, span)，将 request 的内容，将 span 的 name 改为 request 的 method，即 GET 或者POST，而且会将当前请求的路径以 Tag(http.path) 写入 Span 中，这样我们就能在 Zipkin 的 UI 界面中能清晰的看出某个 Span 是发起了什么请求。
- 最后为 Span 设置 Endpoint 信息，并调用 start 设置开始时间。

handleReceive 方法

```
public void handleReceive(@Nullable Resp response, @Nullable Throwable error, Span span) {
  if (span.isNoop()) return;
  Tracer.SpanInScope ws = tracer.withSpanInScope(span);
  try {
    parser.response(adapter, response, error, span);
  } finally {
    ws.close();
    span.finish();
  }
}
```

handleReceive 比较简单，当客户端收到服务端的响应后 handleReceive 方法会被调用，即调用 parser.response(adapter, response, error, span)，会将 HTTP 状态码写入 Span 的 Tag(http.status_code) 中，如果有出错，则会将错误信息写入 Tag(error)中。最后会调用Span的 finish 方法，而 finish 方法中，会调用 Reporter 的 report 方法将 Span 信息上报到 Zipkin。

### 2.2 BackendServlet

最后看看 BackendServlet，在收到请求后，将请求的 header 中参数 user-name 取出，添加到时间戳字符串尾部，并返回。 在上一篇博文中，我们看到如果我们向 Frontend 发送的请求中带有 header user-name 参数，Frontend 会将这个值传递给 Backend，然后backend 会将它放到响应字符串中返回，以表明接收到该 header。

```java
package org.mozhu.zipkin.servlet;

import org.slf4j.Logger;
import org.slf4j.LoggerFactory;

import javax.servlet.ServletException;
import javax.servlet.http.HttpServlet;
import javax.servlet.http.HttpServletRequest;
import javax.servlet.http.HttpServletResponse;
import java.io.IOException;
import java.io.PrintWriter;
import java.util.Date;

public class BackendServlet extends HttpServlet {

    private final static Logger LOGGER = LoggerFactory.getLogger(BackendServlet.class);

    @Override
    protected void service(HttpServletRequest req, HttpServletResponse resp) throws ServletException, IOException {
        LOGGER.info("backend receive request");
        String username = req.getHeader("user-name");
        String result;
        if (username != null) {
            result = new Date().toString() + " " + username;
        } else {
            result = new Date().toString();
        }
        PrintWriter writer = resp.getWriter();
        writer.write(result);
        writer.flush();
        writer.close();
    }

}
```

至此，我们已经分析完 Brave 是如何在普通的 web 项目中使用的，分析了 TracingFilter 拦截请求处理请求的逻辑，也分析了OkHttpClient 是如何将 Trace 信息放入 request 中的。 后面博文中，我们还会继续分析 Brave 和 Spring Web 项目的整合方法。



## 参考

[Java分布式跟踪系统Zipkin（四）：Brave源码分析-HttpTracing](http://blog.mozhu.org/2017/11/13/zipkin/zipkin-4.html)
