## 1. 基本用法

```java
@LoadBalanced
@Bean
public RestTemplate restTemplate() {
    return new RestTemplate();
}

@GetMapping("/call/echo/{message}")
public String callEcho(@PathVariable String message) {
    // 访问应用 nacos-discovery-provider-sample 的 REST "/echo/{message}"
    return restTemplate.getForObject("http://nacos-discovery-provider-sample/echo/" + message, String.class);
}
```

其中关键代码就是 `@LoadBalanced` 注解的使用，那么我们就从这个注解开始，看看它到底做了什么，为什么只是 `RestTemplate` 上标注了它，就能起到负载均衡的作用。

在正式源码分析之前，根据以往的知识，我们先大胆的猜测一下，框架是怎么实现的。

- 收集被 `@LoadBalanced` 注解标记的 bean
- 循环 restTemplate bean 集合，然后依次添加拦截器
- 在真正方法调用的时候，先执行拦截器方法，根据服务名，获取服务列表
- 根据某个负载均衡算法，从服务列表中选择一个服务实例，从而将服务名替换为真实的ip地址
- 最后将 restTemplate.getForObject() 中的服务名，替换为真实ip地址，发起远程调用

然而真实的情况，是不是像我们猜测的这样呢？通过阅读源码来一步步验证我们的猜测。

## 2. 源码分析

![img](http://blog-1259650185.cosbj.myqcloud.com/img/202205/07/1651933031.png)

### 2.1 配置阶段

#### 2.1.1 @LoadBalanced注解

```java
@Target({ ElementType.FIELD, ElementType.PARAMETER, ElementType.METHOD })
@Retention(RetentionPolicy.RUNTIME)
@Documented
@Inherited
@Qualifier
public @interface LoadBalanced {

}
```

通过查看这个注解，我们发现这个注解被 `@Qualifier` 修饰，那么这个注解就是 `@Qualifier` 的派生注解。这里顺便提一下 `@Qualifier` 注解的作用：用来修饰或者限定某个 bean，当依赖注入时，可以像下面的代码一样，收集 spring容 器中所有被 `@Qualifier` 注解修饰的bean，起到一个标记的作用。

```java
@LoadBalanced
@Autowired(required = false)
private List<RestTemplate> restTemplates = Collections.emptyList();
```

那么我们看一下被 @LoadBalanced 标记的 `RestTemplate` 在哪里被用到，这里直接说结果：在 `LoadBalancerAutoConfiguration` 类中被使用。下面进入这个类中看一看。

#### 2.1.2 LoadBalancerAutoConfiguration

```java
@Configuration(proxyBeanMethods = false)
@ConditionalOnClass(RestTemplate.class)
@ConditionalOnBean(LoadBalancerClient.class)
@EnableConfigurationProperties(LoadBalancerRetryProperties.class)
public class LoadBalancerAutoConfiguration {

 @LoadBalanced
 @Autowired(required = false)
 private List<RestTemplate> restTemplates = Collections.emptyList();

 @Autowired(required = false)
 private List<LoadBalancerRequestTransformer> transformers = Collections.emptyList();

 @Bean
 public SmartInitializingSingleton loadBalancedRestTemplateInitializerDeprecated(
   final ObjectProvider<List<RestTemplateCustomizer>> restTemplateCustomizers) {
  return () -> restTemplateCustomizers.ifAvailable(customizers -> {
   for (RestTemplate restTemplate : LoadBalancerAutoConfiguration.this.restTemplates) {
    for (RestTemplateCustomizer customizer : customizers) {
     customizer.customize(restTemplate);
    }
   }
  });
 }

 @Bean
 @ConditionalOnMissingBean
 public LoadBalancerRequestFactory loadBalancerRequestFactory(
   LoadBalancerClient loadBalancerClient) {
  return new LoadBalancerRequestFactory(loadBalancerClient, this.transformers);
 }

 @Configuration(proxyBeanMethods = false)
 @ConditionalOnMissingClass("org.springframework.retry.support.RetryTemplate")
 static class LoadBalancerInterceptorConfig {

  @Bean
  public LoadBalancerInterceptor ribbonInterceptor(
    LoadBalancerClient loadBalancerClient,
    LoadBalancerRequestFactory requestFactory) {
   return new LoadBalancerInterceptor(loadBalancerClient, requestFactory);
  }

  @Bean
  @ConditionalOnMissingBean
  public RestTemplateCustomizer restTemplateCustomizer(
    final LoadBalancerInterceptor loadBalancerInterceptor) {
   return restTemplate -> {
    List<ClientHttpRequestInterceptor> list = new ArrayList<>(
      restTemplate.getInterceptors());
    list.add(loadBalancerInterceptor);
    restTemplate.setInterceptors(list);
   };
  }

 }
 //省略部分代码
 ......
}
```

我们看到这个类的最上面就是通过收集 spring 容器中被 `@LoadBalanced` 标记的 `RestTemplate`。这个类中配置了三个核心的 bean，分别是 `SmartInitializingSingleton、LoadBalancerInterceptor、RestTemplateCustomizer`，那么接下来我们重点分析下这三个配置。

#### 2.1.3 LoadBalancerInterceptor

```java
@Bean
public LoadBalancerInterceptor ribbonInterceptor(
  LoadBalancerClient loadBalancerClient,
  LoadBalancerRequestFactory requestFactory) {
 return new LoadBalancerInterceptor(loadBalancerClient, requestFactory);
}
```

我们看到这个 bean，spring 帮我们注入了 `LoadBalancerClient` 和 `LoadBalancerRequestFactory` 两个bean，（那么这两个 bean 是在哪里注册的呢？答案是：` LoadBalancerClient `在 `RibbonAutoConfiguration` 配置类中注册的，具体实现是 `RibbonLoadBalancerClient`，这里我们先有一个印象，后面会用到这个对象。`LoadBalancerRequestFactory `是在 `LoadBalancerAutoConfiguration` 配置类中注册的，是一个工厂类，用于创建 `LoadBalancerRequest` 对象，这里也留一个印象。）然后将这两个 bean 传入构造函数中。`LoadBalancerInterceptor `的作用，正如我们最开始猜测的那样，就是在执行 `RestTemplate` 的时候，拦截请求，之后做一系列的处理。那么我们接着看一下，他是怎么被设置到 `RestTemplate` 上的。

#### 2.1.4 RestTemplateCustomizer

```java
@Bean
@ConditionalOnMissingBean
public RestTemplateCustomizer restTemplateCustomizer(
  final LoadBalancerInterceptor loadBalancerInterceptor) {
 return restTemplate -> {
  List<ClientHttpRequestInterceptor> list = new ArrayList<>(
    restTemplate.getInterceptors());
  list.add(loadBalancerInterceptor);
  restTemplate.setInterceptors(list);
 };
}
```

就是在这里将 `LoadBalancerInterceptor` 设置到 `restTemplate` 中去的。到这里还没有结束，那么他们两个是怎么关联起来的呢，那么就引入了第三个关键 bean：`SmartInitializingSingleton`。

### 2.1.5 SmartInitializingSingleton

```java
@Bean
public SmartInitializingSingleton loadBalancedRestTemplateInitializerDeprecated(
  final ObjectProvider<List<RestTemplateCustomizer>> restTemplateCustomizers) {
 return () -> restTemplateCustomizers.ifAvailable(customizers -> {
  for (RestTemplate restTemplate : LoadBalancerAutoConfiguration.this.restTemplates) {
   for (RestTemplateCustomizer customizer : customizers) {
    customizer.customize(restTemplate);
   }
  }
 });
}
```

我们可以看到，这里注册了` SmartInitializingSingleton `bean，然后将 `LoadBalancerInterceptor `和 `RestTemplateCustomizer`，通过循环调用 `customizer.customize(restTemplate);` 方法将两者做了关联。我们都知道：`SmartInitializingSingleton `的实现类，会在 spring 应用上下文启动的时候，调用其内部的 `afterSingletonsInstantiated` 方法，而以上代码，即通过 lambda 表达式重写了 `afterSingletonsInstantiated` 方法。到此就分析完了配置阶段的代码，也验证了我们一开始的猜想：即框架内部收集了所有被`@LoadBalanced `注解标记的 `RestTemplate`，然后将 `LoadBalancerInterceptor `绑定到 `RestTemplate` 中。 最后补充一张时序图，如下图所示：

![img](https://pic1.zhimg.com/80/v2-4c22ed7aa9d075aee73df85a1eb175b8_1440w.jpg)

### 2.2 运行阶段

#### 2.2.1 重点关注 LoadBalancerInterceptor

```java
@Override
public ClientHttpResponse intercept(final HttpRequest request, final byte[] body,
  final ClientHttpRequestExecution execution) throws IOException {
 final URI originalUri = request.getURI();
 String serviceName = originalUri.getHost();
 Assert.state(serviceName != null,
   "Request URI does not contain a valid hostname: " + originalUri);
 return this.loadBalancer.execute(serviceName,
   this.requestFactory.createRequest(request, body, execution));
}
```

此处将真正的执行委托给 `loadBalancer` 去执行，还记得这个 `loadBalancer` 具体是哪个吗？是 `RibbonLoadBalancerClient` 这个对象，不记得的话，请回忆下。 那么看看 `RibbonLoadBalancerClient `的 execute 方法。

### 2.2.2 RibbonLoadBalancerClient

```java
public <T> T execute(String serviceId, LoadBalancerRequest<T> request, Object hint)
   throws IOException {
 ILoadBalancer loadBalancer = getLoadBalancer(serviceId);
 Server server = getServer(loadBalancer, hint);
 if (server == null) {
  throw new IllegalStateException("No instances available for " + serviceId);
 }
 RibbonServer ribbonServer = new RibbonServer(serviceId, server,
   isSecure(server, serviceId),
   serverIntrospector(serviceId).getMetadata(server));

 return execute(serviceId, ribbonServer, request);
}
```

进入到这个方法，首先通过 `getLoadBalancer` 方法获取负载均衡器，然后调用 `getServer` 方法，传入上一步得到的负载均衡器，获取一个 server，这里返回的 server 对象中，内部持有的就是真实的 ip 地址，此处是不是也验证了，我们一开始的猜测呢。最后调用execute 方法。开始之前先贴一张时序图，方便大家理解：

![img](https://pic3.zhimg.com/80/v2-c71b57bc00c66442a21baf76a20dd446_1440w.jpg)

1. 接着看下 `getLoadBalancer `方法做了哪些事：

```java
protected ILoadBalancer getLoadBalancer(String serviceId) {
 return this.clientFactory.getLoadBalancer(serviceId);
}
```

通过 serviceId 获取负载均衡器，这里的 `clientFactory `是通过 `RibbonAutoConfiguration` 注册的 `SpringClientFactory`。最终通过 `SpringClientFactory` 的 `getLoadBalancer` 方法，根据 serviceId 从 spring 子上下文中查找 `ILoadBalancer` 类型的 bean，其实最终得到是 `ZoneAwareLoadBalancer` 实例（详见：`RibbonClientConfiguration`配置类），具体细节这里就不进行深入了，请读者自行查阅源码。下面贴一张类图：

![img](https://pic2.zhimg.com/80/v2-05c7d9eb974dd2705763bddc1e06fb8d_1440w.jpg)

**解释说明：**

> ILoadBalancer 接口：定义添加服务，选择服务，获取可用服务，获取所有服务方法
> AbstractLoadBalancer 抽象类：定义了一个关于服务实例的分组枚举，包含了三种类型的服务：ALL 表示所有服务，STATUS_UP 表示正常运行的服务，STATUS_NOT_UP 表示下线的服务。
> BaseLoadBalancer：
> 1）：类中有两个 List 集合，一个 List 集合用来保存所有的服务实例，还有一个 List 集合用来保存当前有效的服务实例
> 2）：定义了一个 IPingStrategy，用来描述服务检查策略，IPingStrategy 默认实现采用了 SerialPingStrategy 实现
> 3）：chooseServer 方法中(负载均衡的核心方法)，调用 IRule 中的 choose 方法来找到一个具体的服务实例,默认实现是RoundRobinRule
> 4）：PingTask 用来检查 Server 是否有效，默认执行时间间隔为10秒
> 5）：markServerDown 方法用来标记一个服务是否有效，标记方式为调用 Server 对象的 setAlive 方法设置 isAliveFlag 属性为 false
> 6）：getReachableServers 方法用来获取所有有效的服务实例列表
> 7）：getAllServers 方法用来获取所有服务的实例列表
> 8）：addServers 方法表示向负载均衡器中添加一个新的服务实例列表
> DynamicServerListLoadBalancer：主要是实现了服务实例清单在运行期间的动态更新能力，同时提供了对服务实例清单的过滤功能。
> ZoneAwareLoadBalancer：主要是重写 DynamicServerListLoadBalancer 中的 chooseServer 方法，由于DynamicServerListLoadBalancer 中负责均衡的策略依然是 BaseLoadBalancer 中的线性轮询策略，这种策略不具备区域感知功能

2. 然后看一下getServer方法，做了哪些事情：

```java
protected Server getServer(ILoadBalancer loadBalancer, Object hint) {
 if (loadBalancer == null) {
  return null;
 }
 // Use 'default' on a null hint, or just pass it on?
 return loadBalancer.chooseServer(hint != null ? hint : "default");
}
```

内部通过上一步传入的负载均衡器，即 `ZoneAwareLoadBalancer`，然后调用其  `chooseServer`  方法，选择一个 server。接下来看一下 `loadBalancer.chooseServer("default")`方法：

```java
public Server chooseServer(Object key) {
    if (counter == null) {
        counter = createCounter();
    }
    counter.increment();
    if (rule == null) {
        return null;
    } else {
        try {
            return rule.choose(key);
        } catch (Exception e) {
            logger.warn("LoadBalancer [{}]:  Error choosing server for key {}", name, key, e);
            return null;
        }
    }
}
```

最终会调用父类 `BaseLoadBalancer` 的 `chooseServer `方法，内部最终调用 `rule.choose(key)`，这里的rule默认为 `RoundRobinRule`，老规矩，开始之前先奉上IRule的类图，如下图：

![img](https://pic2.zhimg.com/80/v2-ca12fc5bc80dd1c6ffbb7252e2ead50d_1440w.jpg)

然后我们进入`RoundRobinRule`的`choose`方法：

```java
public Server choose(ILoadBalancer lb, Object key) {
    if (lb == null) {
        log.warn("no load balancer");
        return null;
    }

    Server server = null;
    int count = 0;
    while (server == null && count++ < 10) {
        List<Server> reachableServers = lb.getReachableServers();
        List<Server> allServers = lb.getAllServers();
        int upCount = reachableServers.size();
        int serverCount = allServers.size();

        if ((upCount == 0) || (serverCount == 0)) {
            log.warn("No up servers available from load balancer: " + lb);
            return null;
        }

        int nextServerIndex = incrementAndGetModulo(serverCount);
        server = allServers.get(nextServerIndex);

        if (server == null) {
            /* Transient. */
            Thread.yield();
            continue;
        }

        if (server.isAlive() && (server.isReadyToServe())) {
            return (server);
        }

        // Next.
        server = null;
    }

    if (count >= 10) {
        log.warn("No available alive servers after 10 tries from load balancer: "
                + lb);
    }
    return server;
}
```

最终通过 `incrementAndGetModulo` 方法，对服务列表总数进行取模运算，得到服务下标索引

```java
private int incrementAndGetModulo(int modulo) {
    for (;;) {
        int current = nextServerCyclicCounter.get();
        int next = (current + 1) % modulo;
        if (nextServerCyclicCounter.compareAndSet(current, next))
            return next;
    }
}
```

好了，到这里已经将 ribbon 从配置到运行的主干代码已经分析完毕，并且也一步步验证了文章开头的猜想。当然在分析源代码的过程中，还有很多分支没有介绍，这里就留给读者自己去探索了，后续有时间我也会补充一些关于 ribbon 的其他源码分析，敬请期待。

## **总结**

spring cloud netflix ribbon通过 `LoadBalancerAutoConfiguration` 配置类，分别注册了 `SmartInitializingSingleton、LoadBalancerInterceptor、RestTemplateCustomizer`三个bean，通过 `SmartInitializingSingleton` 将其它2个 bean 串联了起来，使得 `RestTemplate` 具备了 ribbon 的负载均衡能力。并通过 `RibbonClientConfiguration `配置类对ribbon客户端做了相关配置。

## **补充**

通过阅读源码我们可以得知，如果想在 `RestTemplate.getForObject()` 方法执行前，做一些个性化的处理，那么就可以参照 `LoadBalancerInterceptor` 类，实现 `ClientHttpRequestInterceptor` 接口，重写 `intercept `方法，从而达到自定义拦截器处理。更多知识点，希望大家自己去挖掘，这里只是起到一个抛针引线的作用。



## 参考

[Spring Cloud Netflix Ribbon源码解析（一）](https://zhuanlan.zhihu.com/p/484498895)
