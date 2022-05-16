> 基于Spring Cloud Hoxton.SR9版本

------

## 1. 前言

接着上篇《[Spring Cloud Netflix Ribbon源码解析（一）](https://zhuanlan.zhihu.com/p/484498895)》，在上一篇中，在运行阶段，我们是直接进入 `LoadBalancerInterceptor` 的`intercept `方法，然后一步步沿着主线脉络去分析的。那么这个方法又是怎么被调用的呢？今天我们就来看看，这个方法是怎么被调用到的。那么开始之前呢，我们需要找到入口位置，这个入口就是 `restTemplate.getForObject() `方法，好了，我们进入这个方法，一探究竟吧。

## 2. 源码分析

### 2.1 RestTemplate

```java
@Override
@Nullable
public <T> T getForObject(String url, Class<T> responseType, Object... uriVariables) throws RestClientException {
 RequestCallback requestCallback = acceptHeaderRequestCallback(responseType);
 HttpMessageConverterExtractor<T> responseExtractor =
   new HttpMessageConverterExtractor<>(responseType, getMessageConverters(), logger);
 return execute(url, HttpMethod.GET, requestCallback, responseExtractor, uriVariables);
}
```

通过查看源码可以发现调用自己的 `execute` 方法。

```java
@Override
@Nullable
public <T> T execute(String url, HttpMethod method, @Nullable RequestCallback requestCallback,
  @Nullable ResponseExtractor<T> responseExtractor, Object... uriVariables) throws RestClientException {

 URI expanded = getUriTemplateHandler().expand(url, uriVariables);
 return doExecute(expanded, method, requestCallback, responseExtractor);
}
```

接着调用内部的 `doExecute` 方法。

```java
@Nullable
protected <T> T doExecute(URI url, @Nullable HttpMethod method, @Nullable RequestCallback requestCallback,
  @Nullable ResponseExtractor<T> responseExtractor) throws RestClientException {

 Assert.notNull(url, "URI is required");
 Assert.notNull(method, "HttpMethod is required");
 ClientHttpResponse response = null;
 try {
  // 创建ClientHttpRequest对象
  ClientHttpRequest request = createRequest(url, method);
  if (requestCallback != null) {
   requestCallback.doWithRequest(request);
  }
  // 发起请求
  response = request.execute();
  handleResponse(url, method, response);
  return (responseExtractor != null ? responseExtractor.extractData(response) : null);
 }
 catch (IOException ex) {
  String resource = url.toString();
  String query = url.getRawQuery();
  resource = (query != null ? resource.substring(0, resource.indexOf('?')) : resource);
  throw new ResourceAccessException("I/O error on " + method.name() +
    " request for \"" + resource + "\": " + ex.getMessage(), ex);
 }
 finally {
  if (response != null) {
   response.close();
  }
 }
}
```

这里有2行关键的代码，分别是：`createRequest(url, method) `和 `request.execute()`，那么首先我们需要看看 `createRequest` 方法返回的 `ClientHttpRequest` 对象的具体实现是哪个。进入 createRequest 方法内部：

### 2.2 HttpAccessor

```java
protected ClientHttpRequest createRequest(URI url, HttpMethod method) throws IOException {
 ClientHttpRequest request = getRequestFactory().createRequest(url, method);
 initialize(request);
 if (logger.isDebugEnabled()) {
  logger.debug("HTTP " + method.name() + " " + url);
 }
 return request;
}
```

点击会进入父类`（HttpAccessor）的 createRequest` 方法，这里先插入一下类图，方便理解：

![img](https://pic1.zhimg.com/80/v2-3ad344dde26ed99674ecec905a2de5d4_1440w.jpg)

通过代码可以看到这一行代码 `getRequestFactory().createRequest(url, method);`,首先通过  `getRequestFactory()`  方法得到 `requestFactory`，然后调用目标的  `createRequest`  方法，所以我们需要先知道这个  `requestFactory`，具体是哪一个。

![img](https://pic2.zhimg.com/80/v2-963345f6a6db3a46e33e55d75d02965d_1440w.jpg)

通过上图可以发现，一个是调用它本身的 `getRequestFactory` 方法，一个是调用子类的方法，很明显，这里调用的是子类的方法，那么点击进入子类中。

### 2.3 InterceptingHttpAccessor

```java
@Override
public ClientHttpRequestFactory getRequestFactory() {
 List<ClientHttpRequestInterceptor> interceptors = getInterceptors();
 if (!CollectionUtils.isEmpty(interceptors)) {
  ClientHttpRequestFactory factory = this.interceptingRequestFactory;
  if (factory == null) {
   factory = new InterceptingClientHttpRequestFactory(super.getRequestFactory(), interceptors);
   this.interceptingRequestFactory = factory;
  }
  return factory;
 }
 else {
  return super.getRequestFactory();
 }
}
```

首先调用 `getInterceptors()` 方法获取拦截器集合，那么我们先看看这些拦截器是怎么来的，点进去看一下：

```java
public List<ClientHttpRequestInterceptor> getInterceptors() {
 return this.interceptors;
}
```

返回当前类中 `interceptors` 对象，那么这个 interceptors 是在哪里赋值的呢，在当前类的顶部我们会发现这么一行代码：

```java
private final List<ClientHttpRequestInterceptor> interceptors = new ArrayList<>();
```

创建了一个空集合，那么看看到底是在哪里被初始化赋值的，往下看，可以看到这个类有一个 setInterceptors 方法：

```java
public void setInterceptors(List<ClientHttpRequestInterceptor> interceptors) {
 Assert.noNullElements(interceptors, "'interceptors' must not contain null elements");
 // Take getInterceptors() List as-is when passed in here
 if (this.interceptors != interceptors) {
  this.interceptors.clear();
  this.interceptors.addAll(interceptors);
  AnnotationAwareOrderComparator.sort(this.interceptors);
 }
}
```

上面的 `interceptors` 集合就是在这里被赋值的，那么这个 `setInterceptors` 方法在哪里被调用的呢？还记得上一篇中在 `LoadBalancerAutoConfiguration` 配置类中的代码吗？

```java
@Bean
@ConditionalOnMissingBean
public RestTemplateCustomizer restTemplateCustomizer(
  final LoadBalancerInterceptor loadBalancerInterceptor) {
 return restTemplate -> {
  List<ClientHttpRequestInterceptor> list = new ArrayList<>(
    restTemplate.getInterceptors());
  list.add(loadBalancerInterceptor);
  // 答案就在这里
  restTemplate.setInterceptors(list);
 };
}
```

所以前面说的 `List<ClientHttpRequestInterceptor> interceptors = getInterceptors(); `结果肯定不会为空，好的，回到上一步，由于 `interceptors` 肯定不为空，所以 `getRequestFactory` 方法返回的是 `InterceptingClientHttpRequestFactory`。再退到 `ClientHttpRequest request=getRequestFactory().createRequest(url, method);`方法。最终调用的就是 `InterceptingClientHttpRequestFactory` 类的 `createRequest` 方法：

### 2.4 InterceptingClientHttpRequestFactory

```java
@Override
protected ClientHttpRequest createRequest(URI uri, HttpMethod httpMethod, ClientHttpRequestFactory requestFactory) {
 return new InterceptingClientHttpRequest(requestFactory, this.interceptors, uri, httpMethod);
}
```

返回的` ClientHttpRequest `的具体实现就是 `InterceptingClientHttpRequest` 对象。ok，那么我们再回到 `RestTemplate` 的`doExecute `方法，看一下内部的 `request.execute()` 方法调用情况。为了方便阅读，先插入一张类图，如下：

![img](http://blog-1259650185.cosbj.myqcloud.com/img/202205/06/1651802726.jpg)

通过类图可以发现，调用的其实是父类中的 `execute` 方法。那么进入 `AbstractClientHttpRequest` 的 `execute` 方法：

```java
@Override
public final ClientHttpResponse execute() throws IOException {
 assertNotExecuted();
 ClientHttpResponse result = executeInternal(this.headers);
 this.executed = true;
 return result;
}
```

内部会调用模板方法 `executeInternal`，一路向下，最终会调用 `InterceptingClientHttpRequest `的 `executeInternal` 方法：

```java
@Override
protected final ClientHttpResponse executeInternal(HttpHeaders headers, byte[] bufferedOutput) throws IOException {
 InterceptingRequestExecution requestExecution = new InterceptingRequestExecution();
 return requestExecution.execute(this, bufferedOutput);
}
```

然后调用 `InterceptingRequestExecution` 的 `execute` 方法：

### 2.5 InterceptingRequestExecution

```java
@Override
public ClientHttpResponse execute(HttpRequest request, byte[] body) throws IOException {
 if (this.iterator.hasNext()) {
  ClientHttpRequestInterceptor nextInterceptor = this.iterator.next();
  return nextInterceptor.intercept(request, body, this);
 }
 else {
  HttpMethod method = request.getMethod();
  Assert.state(method != null, "No standard HTTP method");
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

上面的代码中有个 `this.iterator`，我们先不管 `iterator` 是啥，但从字面上我们可以看出 `ClientHttpRequestInterceptor`这玩意给我们存的应该是一个客户端请求拦截器，而且通 过debugger 可以发现这个拦截器一定会包含我上一篇中分析说到的`LoadBalancerInterceptor`，这样一步步的看就跟上一篇幅说的连上了。

好了，说到这里，我们今天的源码之旅就要结束了，感谢您的阅读。下一篇我们会继续介绍关于 Ribbon 的其他内容，敬请期待！



## 参考

[Spring Cloud Netflix Ribbon源码解析之RestTemplate（二）](https://zhuanlan.zhihu.com/p/490728242)
