## 1. 前言

今天我们接着把 ribbon 剩下的知识点介绍一下。我们先看看 RestTemplate 在 Ribbon 的加持下，经过 ribbon 的负载均衡返回一个server 后，发起远程 http 调用的相关细节。然后再看看 openfeign 是怎么利用 ribbon 的负载均衡选择一个 server 并发起远程调用的。好了，废话不多说，直接上干货。

## 2. 源码解析

### RestTemplate与Ribbon

![img](http://blog-1259650185.cosbj.myqcloud.com/img/202205/07/1651933083.png)

### 2.1 RibbonLoadBalancerClient

经过了前几篇的介绍，在 `RibbonLoadBalancerClient` 中的 `execute` 方法里，我们分别分析了通过 `getLoadBalancer` 方法获取负载均衡器，通过  `getServer  ` 方法从服务列表中返回一个可用的服务实例。现在来看看 `execute` 方法做了哪些事情，在 http 远程调用时，框架又为我们提供哪些 http 客户端供选择呢？

```java
public <T> T execute(String serviceId, LoadBalancerRequest<T> request, Object hint)
 throws IOException {
 //从子上下文中获取负载均衡器
 ILoadBalancer loadBalancer = getLoadBalancer(serviceId);
 //从服务列表中返回一个可用的服务实例
 Server server = getServer(loadBalancer, hint);
 if (server == null) {
  throw new IllegalStateException("No instances available for " + serviceId);
 }
 RibbonServer ribbonServer = new RibbonServer(serviceId, server,
   isSecure(server, serviceId),
   serverIntrospector(serviceId).getMetadata(server));
 //执行execute方法，调用远程服务
 return execute(serviceId, ribbonServer, request);
}
```

进入 `execute` 方法：

```java
@Override
public <T> T execute(String serviceId, ServiceInstance serviceInstance,
  LoadBalancerRequest<T> request) throws IOException {
 Server server = null;
 if (serviceInstance instanceof RibbonServer) {
  server = ((RibbonServer) serviceInstance).getServer();
 }
 if (server == null) {
  throw new IllegalStateException("No instances available for " + serviceId);
 }

 RibbonLoadBalancerContext context = this.clientFactory
   .getLoadBalancerContext(serviceId);
 RibbonStatsRecorder statsRecorder = new RibbonStatsRecorder(context, server);

 try {
  //调用LoadBalancerRequest的apply方法
  T returnVal = request.apply(serviceInstance);
  statsRecorder.recordStats(returnVal);
  return returnVal;
 }
 // catch IOException and rethrow so RestTemplate behaves correctly
 catch (IOException ex) {
  statsRecorder.recordStats(ex);
  throw ex;
 }
 catch (Exception ex) {
  statsRecorder.recordStats(ex);
  ReflectionUtils.rethrowRuntimeException(ex);
 }
 return null;
}
```

核心代码就是调用 `LoadBalancerRequest ` 的 `apply` 方法，而这个 `LoadBalancerRequest` 对象又是通过上一个方法传入的，那么我们就往回找，看看对象的被传入的源头在哪里。

### 2.2 LoadBalancerInterceptor

```java
@Override
public ClientHttpResponse intercept(final HttpRequest request, final byte[] body,
  final ClientHttpRequestExecution execution) throws IOException {
 final URI originalUri = request.getURI();
 String serviceName = originalUri.getHost();
 Assert.state(serviceName != null,
   "Request URI does not contain a valid hostname: " + originalUri);
 return this.loadBalancer.execute(serviceName,
   // 在这里创建并返回的
   this.requestFactory.createRequest(request, body, execution));
}
```

最终我们会找到  `LoadBalancerInterceptor`  类的 `intercept` 方法，会看到通过调用`this.requestFactory.createRequest(request, body, execution)`创建并返回的。进入`LoadBalancerRequestFactory`的`createRequest`方法：

### 2.3 LoadBalancerRequestFactory

```java
public LoadBalancerRequest<ClientHttpResponse> createRequest(
   final HttpRequest request, final byte[] body,
   final ClientHttpRequestExecution execution) {
 return instance -> {
  HttpRequest serviceRequest = new ServiceRequestWrapper(request, instance,
    this.loadBalancer);
  if (this.transformers != null) {
   for (LoadBalancerRequestTransformer transformer : this.transformers) {
    serviceRequest = transformer.transformRequest(serviceRequest,
      instance);
   }
  }
  return execution.execute(serviceRequest, body);
 };
}
```

代码通过 lamdba 表达式创建了一个 `LoadBalancerRequest` 对象并实现了 `apply` 方法，`LoadBalancerRequest  `中只有一个  `apply `方法，如下：

### 2.4 LoadBalancerRequest

```java
public interface LoadBalancerRequest<T> {

 T apply(ServiceInstance instance) throws Exception;

}
```

搞清楚了这个，就会知道 `request.apply(serviceInstance)` 方法会进入 `LoadBalancerRequestFactory` 的 `createRequest` 中的lamdba 表达式中，摘取部分代码：

### 2.5 再次回到 LoadBalancerRequestFactory

```java
HttpRequest serviceRequest = new ServiceRequestWrapper(request, instance,
    this.loadBalancer);
if (this.transformers != null) {
 for (LoadBalancerRequestTransformer transformer : this.transformers) {
  serviceRequest = transformer.transformRequest(serviceRequest,
    instance);
 }
}
return execution.execute(serviceRequest, body);
```

一起来分析下这块代码，首先通过创建 `ServiceRequestWrapper` 对象，将 `HttpRequest`、`ServiceInstance` 还有` RibbonLoadBalancerClient `对象进行了包装；然后判断 `transformers` 列表是否等于 null，不等于 null 的话，会迭代 `transformers`列表并调用 `LoadBalancerRequestTransformer` 的 `transformRequest` 方法。这个 `transformers` 是在 `LoadBalancerAutoConfiguration` 中注入并通过构造函数传入 `LoadBalancerRequestFactory` 中的，默认情况下框架并未提供任何实现，所以也就不会走这个分支。

> **通过读源码，我们也会得到一些讯息，那就是，如果想在获取可用服务实例之后，发起远程调用之前，比如想改变目标服务，那么就可以自己实现LoadBalancerRequestTransformer接口，重写transformRequest方法**

最后调用 `ClientHttpRequestExecution `的` execute `方法，`ClientHttpRequestExecution `接口只有一个实现，就是 `InterceptingRequestExecution`：

### 2.6 InterceptingClientHttpRequest#InterceptingRequestExecution

```text
@Override
public ClientHttpResponse execute(HttpRequest request, byte[] body) throws IOException {
 if (this.iterator.hasNext()) {
  ClientHttpRequestInterceptor nextInterceptor = this.iterator.next();
  //调用拦截器方法
  return nextInterceptor.intercept(request, body, this);
 }
 else {
  HttpMethod method = request.getMethod();
  Assert.state(method != null, "No standard HTTP method");
  //ClientHttpRequestFactory的createRequest方法
  ClientHttpRequest delegate = requestFactory.createRequest(request.getURI(), method);
  request.getHeaders().forEach((key, value) -> delegate.getHeaders().addAll(key, value));
  if (body.length > 0) {
   if (delegate instanceof StreamingHttpOutputMessage) {
    StreamingHttpOutputMessage streamingOutputMessage = (StreamingHttpOutputMessage) delegate;
    streamingOutputMessage.setBody(outputStream -> StreamUtils.copy(body, outputStream));
   }
   else {
    StreamUtils.copy(body, delegate.getBody());
   }
  }
  return delegate.execute();
 }
}
```

又看到了我们熟悉的方法，但是这一次会走 else 分支。重点分析一下 `requestFactory.createRequest(request.getURI(), method)`方法的调用：

1. 首先调用 `ServiceRequestWrapper` 的` getURI()`方法（为什么是这个对象，见上一步），根据` ServiceInstance `重构请求的 url：将服务名转换成真正的 ip 和 port。 **ServiceRequestWrapper**

```java
public URI getURI() {
 URI uri = this.loadBalancer.reconstructURI(this.instance, getRequest().getURI());
 return uri;
}
```

方法内部会调用 `RibbonLoadBalancerClient` 的 `reconstructURI` 方法：

```java
@Override
public URI reconstructURI(ServiceInstance instance, URI original) {
 Assert.notNull(instance, "instance can not be null");
 String serviceId = instance.getServiceId();
 //通过SpringClientFactory，从子上下文中取出RibbonLoadBalancerContext实例对象
 RibbonLoadBalancerContext context = this.clientFactory
   .getLoadBalancerContext(serviceId);

 URI uri;
 Server server;
 if (instance instanceof RibbonServer) {
  RibbonServer ribbonServer = (RibbonServer) instance;
  server = ribbonServer.getServer();
  uri = updateToSecureConnectionIfNeeded(original, ribbonServer);
 }
 else {
  server = new Server(instance.getScheme(), instance.getHost(),
    instance.getPort());
  IClientConfig clientConfig = clientFactory.getClientConfig(serviceId);
  ServerIntrospector serverIntrospector = serverIntrospector(serviceId);
  uri = updateToSecureConnectionIfNeeded(original, clientConfig,
    serverIntrospector, server);
 }
 return context.reconstructURIWithServer(server, uri);
}
```

首先通过 `SpringClientFactory`，从子上下文中取出 `RibbonLoadBalancerContext` 实例对象，然后调用它的`reconstructURIWithServer `方法：

```java
public URI reconstructURIWithServer(Server server, URI original) {
    String host = server.getHost();
    int port = server.getPort();
    String scheme = server.getScheme();
    
    if (host.equals(original.getHost()) 
            && port == original.getPort()
            && scheme == original.getScheme()) {
        return original;
    }
    if (scheme == null) {
        scheme = original.getScheme();
    }
    if (scheme == null) {
        scheme = deriveSchemeAndPortFromPartialUri(original).first();
    }

    try {
        StringBuilder sb = new StringBuilder();
        sb.append(scheme).append("://");
        if (!Strings.isNullOrEmpty(original.getRawUserInfo())) {
            sb.append(original.getRawUserInfo()).append("@");
        }
        sb.append(host);
        if (port >= 0) {
            sb.append(":").append(port);
        }
        sb.append(original.getRawPath());
        if (!Strings.isNullOrEmpty(original.getRawQuery())) {
            sb.append("?").append(original.getRawQuery());
        }
        if (!Strings.isNullOrEmpty(original.getRawFragment())) {
            sb.append("#").append(original.getRawFragment());
        }
        URI newURI = new URI(sb.toString());
        return newURI;            
    } catch (URISyntaxException e) {
        throw new RuntimeException(e);
    }
}
```

最终返回一个由ip和port组成的URI。 

2. 然后通过调用 `requestFactory` 的 `createRequest(request.getURI(), method)` 方法创建 `ClientHttpRequest` 对象。

> 需要解释说明下：requestFactory 是 SimpleClientHttpRequestFactory 对象的实例，是在 RestTemplate 的父类 HttpAccessor 的createRequest 方法中，调用它的子类 InterceptingHttpAccessor 的 getRequestFactory 方法，然后通过构造器传入InterceptingClientHttpRequest 对象中的。忘记了的同学，可以回顾下之前的文章。

进入 `SimpleClientHttpRequestFactory `的 `createRequest` 方法：

```java
@Override
public ClientHttpRequest createRequest(URI uri, HttpMethod httpMethod) throws IOException {
 HttpURLConnection connection = openConnection(uri.toURL(), this.proxy);
 prepareConnection(connection, httpMethod.name());
 
 if (this.bufferRequestBody) {
  //this.bufferRequestBody默认为true
  return new SimpleBufferingClientHttpRequest(connection, this.outputStreaming);
 }
 else {
  return new SimpleStreamingClientHttpRequest(connection, this.chunkSize, this.outputStreaming);
 }
}
```

此处返回的就是 `SimpleBufferingClientHttpRequest` 对象。最终会调用它的 `executeInternal` 方法：

```java
@Override
protected ClientHttpResponse executeInternal(HttpHeaders headers, byte[] bufferedOutput) throws IOException {
 addHeaders(this.connection, headers);
 // JDK <1.8 doesn't support getOutputStream with HTTP DELETE
 if (getMethod() == HttpMethod.DELETE && bufferedOutput.length == 0) {
  this.connection.setDoOutput(false);
 }
 if (this.connection.getDoOutput() && this.outputStreaming) {
  this.connection.setFixedLengthStreamingMode(bufferedOutput.length);
 }
 this.connection.connect();
 if (this.connection.getDoOutput()) {
  FileCopyUtils.copy(bufferedOutput, this.connection.getOutputStream());
 }
 else {
  // Immediately trigger the request in a no-output scenario as well
  this.connection.getResponseCode();
 }
 return new SimpleClientHttpResponse(this.connection);
}
```

我们可以清楚的看到底层是通过 `HttpURLConnection` 发起的远程调用。

### 2.7 小结

1. 默认情况下 RestTemplate 底层通过 SimpleClientHttpRequestFactory 对象创建 HttpURLConnection 发起远程调用。
2. spring 提供了多种对 HTTP 客户端库的支持：

- HttpComponentsClientHttpRequestFactory 使用 Apache HttpClient
- OkHttp3ClientHttpRequestFactory 使用 okhttp3 OkHttpClient

1. 切换底层使用的类库：

- 引入依赖
- 配置如下

```java
@Bean
public RestTemplate restTemplate() {
    return new RestTemplate(new HttpComponentsClientHttpRequestFactory());
}
```

## 3. OpenFeign与Ribbon

在 OpenFeign 源码分析篇中，我们知道了 OpenFeign 的工作原理以及一些注意事项。今天看看 OpenFeign 和 Ribbon 是怎么配合工作的。

### 3.1 LoadBalancerFeignClient

```java
@Override
public Response execute(Request request, Request.Options options) throws IOException {
 try {
  URI asUri = URI.create(request.url());
  String clientName = asUri.getHost();
  URI uriWithoutHost = cleanUrl(request.url(), clientName);
  FeignLoadBalancer.RibbonRequest ribbonRequest = new FeignLoadBalancer.RibbonRequest(
    this.delegate, request, uriWithoutHost);

  IClientConfig requestConfig = getClientConfig(options, clientName);
  //通过负载均衡客户端，执行负载均衡处理
  return lbClient(clientName)
    .executeWithLoadBalancer(ribbonRequest, requestConfig).toResponse();
 }
 catch (ClientException e) {
  IOException io = findIOException(e);
  if (io != null) {
   throw io;
  }
  throw new RuntimeException(e);
 }
}
```

上一次我们分析到 `lbClient(clientName).executeWithLoadBalancer(ribbonRequest, requestConfig)` 就终止了，现在接着往下分析。 进入  `lbClient(clientName)`  方法：

```java
private FeignLoadBalancer lbClient(String clientName) {
 return this.lbClientFactory.create(clientName);
}
```

`lbClientFactory `是 `CachingSpringLoadBalancerFactory` 实例对象，而 `CachingSpringLoadBalancerFactory` 是在` FeignRibbonClientAutoConfiguration  `中注册到容器中，并传入 `LoadBalancerFeignClient` 中的。

### 3.2 CachingSpringLoadBalancerFactory

```java
public FeignLoadBalancer create(String clientName) {
 //根据clientName从缓存中取，如果有，就直接返回；如果没有就根据相关配置创建一个，并放入缓存中
 FeignLoadBalancer client = this.cache.get(clientName);
 if (client != null) {
  return client;
 }
 IClientConfig config = this.factory.getClientConfig(clientName);
 //这里实际返回的是ZoneAwareLoadBalancer，相信读者对这个类不会感到陌生
 ILoadBalancer lb = this.factory.getLoadBalancer(clientName);
 ServerIntrospector serverIntrospector = this.factory.getInstance(clientName,
   ServerIntrospector.class);
 client = this.loadBalancedRetryFactory != null
   ? new RetryableFeignLoadBalancer(lb, config, serverIntrospector,
     this.loadBalancedRetryFactory)
   : new FeignLoadBalancer(lb, config, serverIntrospector);
 //以clientName为key，FeignLoadBalancer为value，存入缓存中。
 this.cache.put(clientName, client);
 return client;
}
```

这个类中只有一个 create 方法，主要就是用来创建 `FeignLoadBalancer `并以 clientName 为 key 存入缓存中： `private volatile Map<String, FeignLoadBalancer> cache = new ConcurrentReferenceHashMap<>();` 接下来看看 `FeignLoadBalancer.executeWithLoadBalancer` 方法，由于 `FeignLoadBalancer` 继承 `AbstractLoadBalancerAwareClient`，所以实际是调用父类的方法：

### 3.3 AbstractLoadBalancerAwareClient

```java
public T executeWithLoadBalancer(final S request, final IClientConfig requestConfig) throws ClientException {
 //首先构建LoadBalancerCommand对象
    LoadBalancerCommand<T> command = buildLoadBalancerCommand(request, requestConfig);

    try {
     //然后调用LoadBalancerCommand的submit方法
        return command.submit(
         //创建ServerOperation对象，并实现了它的call方法。
            new ServerOperation<T>() {
                @Override
                public Observable<T> call(Server server) {
                 //根据服务实例重新构建一个由ip+port组成的URI对象，是不是似曾相识
                    URI finalUri = reconstructURIWithServer(server, request.getUri());
                    S requestForServer = (S) request.replaceUri(finalUri);
                    try {
                     //最后执行execute方法发起远程调用
                        return Observable.just(AbstractLoadBalancerAwareClient.this.execute(requestForServer, requestConfig));
                    } 
                    catch (Exception e) {
                        return Observable.error(e);
                    }
                }
            })
            .toBlocking()
            .single();
    } catch (Exception e) {
        Throwable t = e.getCause();
        if (t instanceof ClientException) {
            throw (ClientException) t;
        } else {
            throw new ClientException(e);
        }
    }
    
}
```

具体见代码中的注释。`LoadBalancerCommand.submit `方法内部会调用 `selectServer() `方法，通过负载均衡器返回一个 `server`，内部流程就是我们之前分析的，这里就不再赘述了。最后通过 `rxjava` 的相关api会回调 `ServerOperation` 的 `call` 方法。（由于`rxjava`不是我们分析的重点，所以这里就不深入研究了）`call `内部首先进行 URI 重构，将服务名替换成真实的地址，最后调用 `AbstractLoadBalancerAwareClient.this.execute(requestForServer, requestConfig)` 方法发起远程调用。

**重要：以下分析有误，真正调用的是子类FeignLoadBalancer的execute方法，见<<Spring Cloud OpenFeign源码解析(纠错篇)>>，下面的这些分析仅限ribbon单独使用时**

![img](http://blog-1259650185.cosbj.myqcloud.com/img/202205/07/1651889280.jpg)

通过上面的截图可以看到 `AbstractLoadBalancerAwareClient `的子类有很多，到底是哪一个子类呢？所以首先我们要搞清楚这点。

```java
@Configuration(proxyBeanMethods = false)
@EnableConfigurationProperties
// Order is important here, last should be the default, first should be optional
// see
// https://github.com/spring-cloud/spring-cloud-netflix/issues/2086#issuecomment-316281653
@Import({ HttpClientConfiguration.class, OkHttpRibbonConfiguration.class,
  RestClientRibbonConfiguration.class, HttpClientRibbonConfiguration.class })
public class RibbonClientConfiguration {
 ......
}
```

在 `RibbonClientConfiguration` 中会找到线索：通过`@Import`注解导入了四个配置类，其中在 `OkHttpRibbonConfiguration.class `、`RestClientRibbonConfiguration.class  `以及 `HttpClientRibbonConfiguration.class` 中分别向 sprin g容器中注册了 `AbstractLoadBalancerAwareClient` 的三个子类。重点看一下 `OkHttpRibbonConfiguration.class`和`HttpClientRibbonConfiguration.class`

### 3.4 OkHttpRibbonConfiguration

```java
@Configuration(proxyBeanMethods = false)
@ConditionalOnProperty("ribbon.okhttp.enabled")
@ConditionalOnClass(name = "okhttp3.OkHttpClient")
public class OkHttpRibbonConfiguration {

 @RibbonClientName
 private String name = "client";

 @Bean
 @ConditionalOnMissingBean(AbstractLoadBalancerAwareClient.class)
 @ConditionalOnClass(name = "org.springframework.retry.support.RetryTemplate")
 public RetryableOkHttpLoadBalancingClient retryableOkHttpLoadBalancingClient(
   IClientConfig config, ServerIntrospector serverIntrospector,
   ILoadBalancer loadBalancer, RetryHandler retryHandler,
   LoadBalancedRetryFactory loadBalancedRetryFactory, OkHttpClient delegate,
   RibbonLoadBalancerContext ribbonLoadBalancerContext) {
  RetryableOkHttpLoadBalancingClient client = new RetryableOkHttpLoadBalancingClient(
    delegate, config, serverIntrospector, loadBalancedRetryFactory);
  client.setLoadBalancer(loadBalancer);
  client.setRetryHandler(retryHandler);
  client.setRibbonLoadBalancerContext(ribbonLoadBalancerContext);
  Monitors.registerObject("Client_" + this.name, client);
  return client;
 }

 @Bean
 @ConditionalOnMissingBean(AbstractLoadBalancerAwareClient.class)
 @ConditionalOnMissingClass("org.springframework.retry.support.RetryTemplate")
 public OkHttpLoadBalancingClient okHttpLoadBalancingClient(IClientConfig config,
   ServerIntrospector serverIntrospector, ILoadBalancer loadBalancer,
   RetryHandler retryHandler, OkHttpClient delegate) {
  OkHttpLoadBalancingClient client = new OkHttpLoadBalancingClient(delegate, config,
    serverIntrospector);
  client.setLoadBalancer(loadBalancer);
  client.setRetryHandler(retryHandler);
  Monitors.registerObject("Client_" + this.name, client);
  return client;
 }

 ......

}
```

配置的是 `OkHttpLoadBalancingClient`，如果有 retry，则是 `RetryableOkHttpLoadBalancingClient`

### 3.5 HttpClientRibbonConfiguration

```java
@Configuration(proxyBeanMethods = false)
@ConditionalOnClass(name = "org.apache.http.client.HttpClient")
@ConditionalOnProperty(name = "ribbon.httpclient.enabled", matchIfMissing = true)
public class HttpClientRibbonConfiguration {

 @RibbonClientName
 private String name = "client";

 @Bean
 @ConditionalOnMissingBean(AbstractLoadBalancerAwareClient.class)
 @ConditionalOnMissingClass("org.springframework.retry.support.RetryTemplate")
 public RibbonLoadBalancingHttpClient ribbonLoadBalancingHttpClient(
   IClientConfig config, ServerIntrospector serverIntrospector,
   ILoadBalancer loadBalancer, RetryHandler retryHandler,
   CloseableHttpClient httpClient) {
  RibbonLoadBalancingHttpClient client = new RibbonLoadBalancingHttpClient(
    httpClient, config, serverIntrospector);
  client.setLoadBalancer(loadBalancer);
  client.setRetryHandler(retryHandler);
  Monitors.registerObject("Client_" + this.name, client);
  return client;
 }

 @Bean
 @ConditionalOnMissingBean(AbstractLoadBalancerAwareClient.class)
 @ConditionalOnClass(name = "org.springframework.retry.support.RetryTemplate")
 public RetryableRibbonLoadBalancingHttpClient retryableRibbonLoadBalancingHttpClient(
   IClientConfig config, ServerIntrospector serverIntrospector,
   ILoadBalancer loadBalancer, RetryHandler retryHandler,
   LoadBalancedRetryFactory loadBalancedRetryFactory,
   CloseableHttpClient httpClient,
   RibbonLoadBalancerContext ribbonLoadBalancerContext) {
  RetryableRibbonLoadBalancingHttpClient client = new RetryableRibbonLoadBalancingHttpClient(
    httpClient, config, serverIntrospector, loadBalancedRetryFactory);
  client.setLoadBalancer(loadBalancer);
  client.setRetryHandler(retryHandler);
  client.setRibbonLoadBalancerContext(ribbonLoadBalancerContext);
  Monitors.registerObject("Client_" + this.name, client);
  return client;
 }

 ......

}
```

配置的是 `RibbonLoadBalancingHttpClient`，如果有 retry，则是 `RetryableRibbonLoadBalancingHttpClient`

### 3.6 小结

`AbstractLoadBalancingClient  `有 appche httpclient 以及 okhttp 两类实现，分别是 `RibbonLoadBalancingHttpClient`（默认开启）及 `OkHttpLoadBalancingClient`；每种实现都有 retry 相关的实现，分别是 `RetryableRibbonLoadBalancingHttpClient `、`RetryableOkHttpLoadBalancingClient`。

有了上面的结论，那么就进入`RibbonLoadBalancingHttpClient.execute`方法：

```java
@Override
public RibbonApacheHttpResponse execute(RibbonApacheHttpRequest request,
  final IClientConfig configOverride) throws Exception {
 IClientConfig config = configOverride != null ? configOverride : this.config;
 RibbonProperties ribbon = RibbonProperties.from(config);
 RequestConfig requestConfig = RequestConfig.custom()
   .setConnectTimeout(ribbon.connectTimeout(this.connectTimeout))
   .setSocketTimeout(ribbon.readTimeout(this.readTimeout))
   .setRedirectsEnabled(ribbon.isFollowRedirects(this.followRedirects))
   .setContentCompressionEnabled(ribbon.isGZipPayload(this.gzipPayload))
   .build();

 request = getSecureRequest(request, configOverride);
 final HttpUriRequest httpUriRequest = request.toRequest(requestConfig);
 //通过apache httpclient的CloseableHttpClient api发起远程调用
 final HttpResponse httpResponse = this.delegate.execute(httpUriRequest);
 return new RibbonApacheHttpResponse(httpResponse, httpUriRequest.getURI());
}
```

最终通过 apache httpclient 的CloseableHttpClient api 发起远程调用，然后 apache 的 `HttpResponse` 对象包装成 `RibbonApacheHttpResponse` 返回。



## 参考

[Spring Cloud Netflix Ribbon源码解析（五）](https://zhuanlan.zhihu.com/p/498939068)
