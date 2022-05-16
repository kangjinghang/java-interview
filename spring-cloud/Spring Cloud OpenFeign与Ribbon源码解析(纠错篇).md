## 1. 前言

在[Spring Cloud Netflix Ribbon源码解析（五）](https://zhuanlan.zhihu.com/p/498939068)中，有关 OpenFeign 与 Ribbon 结合的源码分析中，关于`AbstractLoadBalancerAwareClient.this.execute(requestForServer, requestConfig) `这段代码的分析中，我错误的推断此处调用的是 `RibbonLoadBalancingHttpClient.execute` 方法，忘记了同学，请回看。由于是通过子类 `FeignLoadBalancer` 调用的`executeWithLoadBalancer `方法，所以这里其实是调用的 `FeignLoadBalancer` 的 `execute` 方法，那么今天纠正下这个错误，重新分析下这块相关的源码。

## 2. 源码分析

### 2.1 FeignLoadBalancer

```java
@Override
public RibbonResponse execute(RibbonRequest request, IClientConfig configOverride)
  throws IOException {
 Request.Options options;
 if (configOverride != null) {
  //如果客户端配置了openfeign相关超时时间，就是用openfeign的
  RibbonProperties override = RibbonProperties.from(configOverride);
  options = new Request.Options(override.connectTimeout(this.connectTimeout),
    override.readTimeout(this.readTimeout));
 }
 else {
  //如果没有提供，就是用ribbon的超时时间
  options = new Request.Options(this.connectTimeout, this.readTimeout);
 }
 Response response = request.client().execute(request.toRequest(), options);
 return new RibbonResponse(request.getUri(), response);
}
```

见代码注释。 调用 `request.client().execute(request.toRequest(), options)` 方法，首先通过 `request.client() `返回一个 `client`，然后调用它的 `execute` 方法。先来看看这个 `client` 是什么。

### 2.2 LoadBalancerFeignClient

```java
@Override
public Response execute(Request request, Request.Options options) throws IOException {
 try {
  URI asUri = URI.create(request.url());
  String clientName = asUri.getHost();
  URI uriWithoutHost = cleanUrl(request.url(), clientName);
  //在此处设置的client，即this.delegate
  FeignLoadBalancer.RibbonRequest ribbonRequest = new FeignLoadBalancer.RibbonRequest(
    this.delegate, request, uriWithoutHost);

  IClientConfig requestConfig = getClientConfig(options, clientName);
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

这个 `client` 是在调用 `LoadBalancerFeignClient `的 `execute` 方法时被设置到了 `RibbonRequest` 对象中的，而这个`client`是通过构造器传入的。

```java
public LoadBalancerFeignClient(Client delegate,
 CachingSpringLoadBalancerFactory lbClientFactory,
  SpringClientFactory clientFactory) {
 this.delegate = delegate;
 this.lbClientFactory = lbClientFactory;
 this.clientFactory = clientFactory;
}
```

之前介绍过 `LoadBalancerFeignClient `是在 `FeignRibbonClientAutoConfiguration` 中导入并配置的

```java
@ConditionalOnClass({ ILoadBalancer.class, Feign.class })
@ConditionalOnProperty(value = "spring.cloud.loadbalancer.ribbon.enabled",
  matchIfMissing = true)
@Configuration(proxyBeanMethods = false)
@AutoConfigureBefore(FeignAutoConfiguration.class)
@EnableConfigurationProperties({ FeignHttpClientProperties.class })
// Order is important here, last should be the default, first should be optional
// see
// https://github.com/spring-cloud/spring-cloud-netflix/issues/2086#issuecomment-316281653
@Import({ HttpClientFeignLoadBalancedConfiguration.class,
  OkHttpFeignLoadBalancedConfiguration.class,
  DefaultFeignLoadBalancedConfiguration.class })
public class FeignRibbonClientAutoConfiguration {
 ......
}
```

通过 `@Import` 注解导入了 `HttpClientFeignLoadBalancedConfiguration.class、OkHttpFeignLoadBalancedConfiguration.class、DefaultFeignLoadBalancedConfiguration.class` 三个配置类

#### 2.2.1 HttpClientFeignLoadBalancedConfiguration.class

```text
@Configuration(proxyBeanMethods = false)
@ConditionalOnClass(ApacheHttpClient.class)
@ConditionalOnProperty(value = "feign.httpclient.enabled", matchIfMissing = true)
@Import(HttpClientFeignConfiguration.class)
class HttpClientFeignLoadBalancedConfiguration {

 @Bean
 @ConditionalOnMissingBean(Client.class)
 public Client feignClient(CachingSpringLoadBalancerFactory cachingFactory,
   SpringClientFactory clientFactory, HttpClient httpClient) {
  ApacheHttpClient delegate = new ApacheHttpClient(httpClient);
  return new LoadBalancerFeignClient(delegate, cachingFactory, clientFactory);
 }

}
```

条件是classpath中存在`ApacheHttpClient.class`并且在上下文中没有Client.class类型的bean时，向spring容器中注册Client.class类型的bean，并通过构造器传入`ApacheHttpClient`对象。

**OkHttpFeignLoadBalancedConfiguration.class**

```java
@Configuration(proxyBeanMethods = false)
@ConditionalOnClass(OkHttpClient.class)
@ConditionalOnProperty("feign.okhttp.enabled")
@Import(OkHttpFeignConfiguration.class)
class OkHttpFeignLoadBalancedConfiguration {

 @Bean
 @ConditionalOnMissingBean(Client.class)
 public Client feignClient(CachingSpringLoadBalancerFactory cachingFactory,
   SpringClientFactory clientFactory, okhttp3.OkHttpClient okHttpClient) {
  OkHttpClient delegate = new OkHttpClient(okHttpClient);
  return new LoadBalancerFeignClient(delegate, cachingFactory, clientFactory);
 }

}
```

条件是 classpath 中存在 `OkHttpClient.class `并且 `feign.okhttp.enabled=true` 并且在上下文中没有 Client.class 类型的 bean 时，向 spring 容器中注册 Client.class 类型的 bean，并通过构造器传入 `OkHttpClient` 对象

#### 2.2.2 DefaultFeignLoadBalancedConfiguration.class

```java
@Configuration(proxyBeanMethods = false)
class DefaultFeignLoadBalancedConfiguration {

 @Bean
 @ConditionalOnMissingBean
 public Client feignClient(CachingSpringLoadBalancerFactory cachingFactory,
   SpringClientFactory clientFactory) {
  return new LoadBalancerFeignClient(new Client.Default(null, null), cachingFactory,
    clientFactory);
 }

}
```

在上面2个配置类中条件都不满足的情况下，会默认向 spring 上下文中注册 `Client.class` 类型的 bean，并通过构造器传入 `new Client.Default(null, null)` 对象。

有了上面的分析，在我当前的环境下，默认生效的就是 `DefaultFeignLoadBalancedConfiguration` 配置类，那么 `LoadBalancerFeignClient` 构造器中接收到的 client 就是 `new Client.Default(null, null)` 的实例。 回到 `FeignLoadBalancer`类的 `execute` 方法中，继续看看 `new Client.Default(null, null) `的 `execute` 方法调用情况

```java
public interface Client {
    Response execute(Request var1, Options var2) throws IOException;

    public static class Default implements Client {
        private final SSLSocketFactory sslContextFactory;
        private final HostnameVerifier hostnameVerifier;

        public Default(SSLSocketFactory sslContextFactory, HostnameVerifier hostnameVerifier) {
            this.sslContextFactory = sslContextFactory;
            this.hostnameVerifier = hostnameVerifier;
        }

        public Response execute(Request request, Options options) throws IOException {
            HttpURLConnection connection = this.convertAndSend(request, options);
            return this.convertResponse(connection).toBuilder().request(request).build();
        }
  ......
   }

......

}
```

可以清晰的看到，默认使用的 `HttpURLConnection `发起的远程调用。至于怎么切换底层的 http 客户端，在关于 `OpenFeign` 的源码分析中已经介绍过，经过今天的讲解，相信大家理解起来会更加深刻。

## **补充**

![img](http://blog-1259650185.cosbj.myqcloud.com/img/202205/07/1651904544.jpg)

上次我们提到 `AbstractLoadBalancerAwareClient `有很多子类，并且错误的引导大家：在 OpenFeign 与 Ribbon 的结合下，最终调用的是 `RibbonLoadBalancingHttpClient` 的 `execute` 方法。正确的解释是：在 OpenFeign 与 Ribbon 组合下，使用的是 `FeignLoadBalancer` 这个子类。那么上次提到的在`RibbonClientConfiguration`中导入并配置的`AbstractLoadBalancerAwareClient`的子类（见<<Spring Cloud Netflix Ribbon源码解析（五）>>）是在什么时候被用到呢？答案是在 Ribbon 单独使用时，并通过配置 `ribbon.httpclient.enabled=true` 或者 `ribbon.okhttp.enabled=true` 来启用的。

**关于openfeign再补充一个知识点：在发起远程调用前，可以通过实现 RequestInterceptor 接口，并重写 apply 方法，然后注册到spring 上下文中，就可以实现比如在请求中统一携带 token 值。最终这个拦截器类会在`SynchronousMethodHandler`的`targetRequest`中被调用：**

```java
Request targetRequest(RequestTemplate template) {
    for (RequestInterceptor interceptor : requestInterceptors) {
      interceptor.apply(template);
    }
    return target.apply(template);
  }
```



## 参考

[Spring Cloud OpenFeign与Ribbon源码解析(纠错篇)](https://zhuanlan.zhihu.com/p/500959570)
