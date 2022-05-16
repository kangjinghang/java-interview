## 1. 基本用法

引入依赖

```xml
<dependency>
    <groupId>org.springframework.cloud</groupId>
    <artifactId>spring-cloud-starter-openfeign</artifactId>
</dependency>
```

开启feign

```java
@EnableFeignClients
```

定义接口

```java
@FeignClient("nacos-discovery-provider-sample") // 指向服务提供者应用
public interface EchoService {

    @GetMapping("/echo/{message}")
    String echo(@PathVariable("message") String message);
}
```

## 2. 源码分析

### 2.1 配置解析阶段

#### 2.1.1 @EnableFeignClients

```java
@Retention(RetentionPolicy.RUNTIME)
@Target(ElementType.TYPE)
@Documented
@Import(FeignClientsRegistrar.class)
public @interface EnableFeignClients {
}
```

通过 import 注解导入了 `FeignClientsRegistrar  `配置类，那么进入这个类中，一看详情。

#### 2.1.2 FeignClientsRegistrar

这个类实现了 `ImportBeanDefinitionRegistrar` 接口，那么就需要重写 `registerBeanDefinitions` 方法。如下：

```java
@Override
public void registerBeanDefinitions(AnnotationMetadata metadata, BeanDefinitionRegistry registry) {
 registerDefaultConfiguration(metadata, registry);
 registerFeignClients(metadata, registry);
}
```

这个方法做了两件事情：

1. 注册全局配置，如果 EnableFeignClients 注解上配置了 defaultConfiguration 属性。

```java
private void registerDefaultConfiguration(AnnotationMetadata metadata,
   BeanDefinitionRegistry registry) {
  Map<String, Object> defaultAttrs = metadata
    .getAnnotationAttributes(EnableFeignClients.class.getName(), true);

  if (defaultAttrs != null && defaultAttrs.containsKey("defaultConfiguration")) {
   String name;
   if (metadata.hasEnclosingClass()) {
    name = "default." + metadata.getEnclosingClassName();
   }
   else {
    name = "default." + metadata.getClassName();
   }
   registerClientConfiguration(registry, name,
     defaultAttrs.get("defaultConfiguration"));
  }
 }
```

2. 注册 FeignClients

```java
public void registerFeignClients(AnnotationMetadata metadata,
   BeanDefinitionRegistry registry) {
  ClassPathScanningCandidateComponentProvider scanner = getScanner();
  scanner.setResourceLoader(this.resourceLoader);

  Set<String> basePackages;

  Map<String, Object> attrs = metadata
    .getAnnotationAttributes(EnableFeignClients.class.getName());
  AnnotationTypeFilter annotationTypeFilter = new AnnotationTypeFilter(
    FeignClient.class);
  //省略部分代码
  ......
  for (String basePackage : basePackages) {
   Set<BeanDefinition> candidateComponents = scanner
     .findCandidateComponents(basePackage);
   for (BeanDefinition candidateComponent : candidateComponents) {
    if (candidateComponent instanceof AnnotatedBeanDefinition) {
     // verify annotated class is an interface
     AnnotatedBeanDefinition beanDefinition = (AnnotatedBeanDefinition) candidateComponent;
     AnnotationMetadata annotationMetadata = beanDefinition.getMetadata();
     Assert.isTrue(annotationMetadata.isInterface(),
       "@FeignClient can only be specified on an interface");

     Map<String, Object> attributes = annotationMetadata
       .getAnnotationAttributes(
         FeignClient.class.getCanonicalName());

     String name = getClientName(attributes);
     registerClientConfiguration(registry, name,
       attributes.get("configuration"));

     registerFeignClient(registry, annotationMetadata, attributes);
    }
   }
  }
 }
```

这个方法会扫描类路径上标记`@FeignClient`注解的接口，根据`@EnableFeignClients`注解上的配置，并循环注册 FeignClient。 进入`registerFeignClient`方法

```java
private void registerFeignClient(BeanDefinitionRegistry registry,
   AnnotationMetadata annotationMetadata, Map<String, Object> attributes) {
  String className = annotationMetadata.getClassName();
  BeanDefinitionBuilder definition = BeanDefinitionBuilder
    .genericBeanDefinition(FeignClientFactoryBean.class);
  validate(attributes);
  definition.addPropertyValue("url", getUrl(attributes));
  definition.addPropertyValue("path", getPath(attributes));
  String name = getName(attributes);
  definition.addPropertyValue("name", name);
  String contextId = getContextId(attributes);
  definition.addPropertyValue("contextId", contextId);
  definition.addPropertyValue("type", className);
  definition.addPropertyValue("decode404", attributes.get("decode404"));
  definition.addPropertyValue("fallback", attributes.get("fallback"));
  definition.addPropertyValue("fallbackFactory", attributes.get("fallbackFactory"));
  definition.setAutowireMode(AbstractBeanDefinition.AUTOWIRE_BY_TYPE);

  String alias = contextId + "FeignClient";
  AbstractBeanDefinition beanDefinition = definition.getBeanDefinition();
  beanDefinition.setAttribute(FactoryBean.OBJECT_TYPE_ATTRIBUTE, className);

  // has a default, won't be null
  boolean primary = (Boolean) attributes.get("primary");

  beanDefinition.setPrimary(primary);

  String qualifier = getQualifier(attributes);
  if (StringUtils.hasText(qualifier)) {
   alias = qualifier;
  }

  BeanDefinitionHolder holder = new BeanDefinitionHolder(beanDefinition, className,
    new String[] { alias });
  BeanDefinitionReaderUtils.registerBeanDefinition(holder, registry);
 }
```

可以看到，这个方法就是将 FeignClient 注解上的属性信息，封装到 BeanDefinition 中，并注册到 Spring 容器中。但是在这个方法中，有一个关键信息，就是真实注册的是 `FeignClientFactoryBean`，它实现了 `FactoryBean`接口，表明这是一个工厂 bean，用于创建代理Bean，真正执行的逻辑是 `FactoryBean`的 `getObject`方法。至此，FeignClient 的配置解析阶段就完成了。下面进入 `FeignClientFactoryBean`，看看在这个类中都做了什么。

### 2.2 运行阶段

#### 2.2.1 FeignClientFactoryBean

1. 核心方法 getObject

```java
@Override
public Object getObject() throws Exception {
 return getTarget();
}
```

当我们在业务代码中通过 `@Autowire  ` 依赖注入或者通过 `getBean` 依赖查找时，此方法会被调用。内部会调用 `getTarget` 方法，那么进入这个方法一探究竟。 

2. getTarget

```java
<T> T getTarget() {
  FeignContext context = applicationContext.getBean(FeignContext.class);
  Feign.Builder builder = feign(context);

  if (!StringUtils.hasText(url)) {
   if (!name.startsWith("http")) {
    url = "http://" + name;
   }
   else {
    url = name;
   }
   url += cleanPath();
   return (T) loadBalance(builder, context,
     new HardCodedTarget<>(type, name, url));
  }
  if (StringUtils.hasText(url) && !url.startsWith("http")) {
   url = "http://" + url;
  }
  String url = this.url + cleanPath();
  Client client = getOptional(context, Client.class);
  if (client != null) {
   if (client instanceof LoadBalancerFeignClient) {
    // not load balancing because we have a url,
    // but ribbon is on the classpath, so unwrap
    client = ((LoadBalancerFeignClient) client).getDelegate();
   }
   if (client instanceof FeignBlockingLoadBalancerClient) {
    // not load balancing because we have a url,
    // but Spring Cloud LoadBalancer is on the classpath, so unwrap
    client = ((FeignBlockingLoadBalancerClient) client).getDelegate();
   }
   builder.client(client);
  }
  Targeter targeter = get(context, Targeter.class);
  return (T) targeter.target(this, builder, context,
    new HardCodedTarget<>(type, name, url));
 }
```

首先从 Spring 上下文中，获取 FeignContext 这个Bean，这个 bean 是在哪里注册的呢？是在 `FeignAutoConfiguration `中注册的。 然后判断 url 属性是否为空，如果不为空，则生成默认的代理类；如果为空，则走负载均衡，生成带有负载均衡的代理类。那么重点关注`loadBalance` 方法。

3. loadBalance

```java
protected <T> T loadBalance(Feign.Builder builder, FeignContext context,
   HardCodedTarget<T> target) {
  Client client = getOptional(context, Client.class);
  if (client != null) {
   builder.client(client);
   Targeter targeter = get(context, Targeter.class);
   return targeter.target(this, builder, context, target);
  }

  throw new IllegalStateException(
    "No Feign Client for loadBalancing defined. Did you forget to include spring-cloud-starter-netflix-ribbon?");
 }
```

首先调用  `getOptional  `方法，这个方法就是根据  `contextId`  获取一个子上下文，然后从这个子上下文中查找 Client bean，SpringCloud 会为每一个 feignClient 创建一个子上下文，然后存入以 contextId 为 key 的 map 中，详见 `NamedContextFactory `的`getContext `方法。此处会返回 `LoadBalancerFeignClient` 这个 Client。详见：`FeignRibbonClientAutoConfiguration `会导入相关配置类。 然后会从子上下文中，查找 `Targeter` bean，默认返回的是 `DefaultTargeter` , 最后调用 `target `方法。

4. DefaultTargeter

```java
class DefaultTargeter implements Targeter {

 @Override
 public <T> T target(FeignClientFactoryBean factory, Feign.Builder feign,
   FeignContext context, Target.HardCodedTarget<T> target) {
  return feign.target(target);
 }

}
```

最终底层调用 `Feign.Builder  ` 的 `target` 方法。进入 `Feign` class中，看看到底做了什么事情

5. Feign

```java
public <T> T target(Target<T> target) {
    return this.build().newInstance(target);
}

public Feign build() {
    //省略部分代码
    ......
    return new ReflectiveFeign(handlersByName, this.invocationHandlerFactory, this.queryMapEncoder);
}
```

可以看到最终是通过创建 `ReflectiveFeign `对象，然后调用 `newInstance` 方法返回了一个代理对象，通过名字可以发现，底层使用的Java 反射创建的。 那么看看 `ReflectiveFeign `的 `newInstance `方法到底做了什么。

6. ReflectiveFeign

```java
public <T> T newInstance(Target<T> target) {
				//根据接口类和Contract协议解析方式，解析接口类上的方法和注解，转换成内部的MethodHandler处理方式
        Map<String, MethodHandler> nameToHandler = this.targetToHandlersByName.apply(target);
        Map<Method, MethodHandler> methodToHandler = new LinkedHashMap();
        List<DefaultMethodHandler> defaultMethodHandlers = new LinkedList();
        Method[] var5 = target.type().getMethods();
        int var6 = var5.length;

        for(int var7 = 0; var7 < var6; ++var7) {
            Method method = var5[var7];
            if (method.getDeclaringClass() != Object.class) {
                if (Util.isDefault(method)) {
                    DefaultMethodHandler handler = new DefaultMethodHandler(method);
                    defaultMethodHandlers.add(handler);
                    methodToHandler.put(method, handler);
                } else {
                    methodToHandler.put(method, nameToHandler.get(Feign.configKey(target.type(), method)));
                }
            }
        }
  //基于Proxy.newProxyInstance 为接口类创建动态实现，将所有的请求转换给InvocationHandler 处理。
        InvocationHandler handler = this.factory.create(target, methodToHandler);
        T proxy = Proxy.newProxyInstance(target.type().getClassLoader(), new Class[]{target.type()}, handler);
        Iterator var12 = defaultMethodHandlers.iterator();

        while(var12.hasNext()) {
            DefaultMethodHandler defaultMethodHandler = (DefaultMethodHandler)var12.next();
            defaultMethodHandler.bindTo(proxy);
        }

        return proxy;
    }
```

见注释。此处`invocationHandler handler = this.factory.create(target, methodToHandler);`真实返回的是 `FeignInvocationHandler`，当在自己的业务类中调用feign接口方法时，会调用`FeignInvocationHandler`的`invoke`方法。

如何解析方法的注解信息呢。 `Feign`中提供一个`Contract` 解析协议，有如下实现。

![img](http://blog-1259650185.cosbj.myqcloud.com/img/202205/06/1651767127.awebp)

**默认支持解析逻辑**

```java
class Default extends Contract.BaseContract {
	protected void processAnnotationOnMethod() {
		Class<? extends Annotation> annotationType = methodAnnotation.annotationType();
		if (annotationType == RequestLine.class) {
			//@RequestLine	注解处理逻辑
		} else if (annotationType == Body.class) {
			//@Body	注解处理逻辑
		} else if (annotationType == Headers.class) {
			//@Headers	注解处理逻辑
		}
	}
	protected boolean processAnnotationsOnParameter() {
		boolean isHttpAnnotation = false;
		for (Annotation annotation : annotations) {
			Class<? extends Annotation> annotationType = annotation.annotationType();
			if (annotationType == Param.class) {
				Param paramAnnotation = (Param) annotation;
				//@Param	注解处理逻辑
			} else if (annotationType == QueryMap.class) {
				//@QueryMap	注解处理逻辑
			} else if (annotationType == HeaderMap.class) {
				//@HeaderMap	注解处理逻辑
			}
		}
		return isHttpAnnotation;
	}
}
```

**原生的常用注解**

| Annotation     | Interface Target |
| -------------- | ---------------- |
| `@RequestLine` | Method           |
| `@Param`       | Parameter        |
| `@Headers`     | Method, Type     |
| `@QueryMap`    | Parameter        |
| `@HeaderMap`   | Parameter        |
| `@Body`        | Method           |

**Spring MVC 扩展注解**

- SpringMvcContract 为 `spring-cloud-open-feign` 的扩展支持`SpringMVC`注解，现 `feign` 版本也已支持

```java
public class SpringMvcContract  {
	
	// 处理类上的 @RequestMapping
	@Override
	protected void processAnnotationOnClass(MethodMetadata data, Class<?> clz) {
		if (clz.getInterfaces().length == 0) {
			RequestMapping classAnnotation = findMergedAnnotation(clz,
					RequestMapping.class);
		}
	}
	
	// 处理 @RequestMapping 注解，当然也支持衍生注解 @GetMapping @PostMapping 等处理
	@Override
	protected void processAnnotationOnMethod() {
		if (!RequestMapping.class.isInstance(methodAnnotation) && !methodAnnotation
				.annotationType().isAnnotationPresent(RequestMapping.class)) {
			return;
		}
		RequestMapping methodMapping = findMergedAnnotation(method, RequestMapping.class);
		// 获取请求方法
		RequestMethod[] methods = methodMapping.method();
		// produce处理
		parseProduces(data, method, methodMapping);
		// consumes处理
		parseConsumes(data, method, methodMapping);
		// headers头处理
		parseHeaders(data, method, methodMapping);

		data.indexToExpander(new LinkedHashMap<Integer, Param.Expander>());
	}

	// 处理 请求参数 SpringMVC 原生注解
	@Override
	protected boolean processAnnotationsOnParameter() {
		Param.Expander expander = this.convertingExpanderFactory
				.getExpander(typeDescriptor);
		if (expander != null) {
			data.indexToExpander().put(paramIndex, expander);
		}
		return isHttpAnnotation;
	}
}
```

7. ReflectiveFeign.FeignInvocationHandler

```java
@Override
    public Object invoke(Object proxy, Method method, Object[] args) throws Throwable {
      if ("equals".equals(method.getName())) {
        try {
          Object otherHandler =
              args.length > 0 && args[0] != null ? Proxy.getInvocationHandler(args[0]) : null;
          return equals(otherHandler);
        } catch (IllegalArgumentException e) {
          return false;
        }
      } else if ("hashCode".equals(method.getName())) {
        return hashCode();
      } else if ("toString".equals(method.getName())) {
        return toString();
      }

      return dispatch.get(method).invoke(args);
    }
```

在 `invoke` 方法中，会调用  `this.dispatch.get(method)).invoke(args)` 。`this.dispatch.get(method)` 会返回一个`SynchronousMethodHandler` 进行拦截处理。这个方法会根据参数生成完成的 `RequestTemplate` 对象，这个对象是 Http 请求的模版，代码如下。 看 `SynchronousMethodHandler `中的 `invoke`  方法。

8. SynchronousMethodHandler

```java
@Override
  public Object invoke(Object[] argv) throws Throwable {
    RequestTemplate template = buildTemplateFromArgs.create(argv);
    Options options = findOptions(argv);
    Retryer retryer = this.retryer.clone();
    while (true) {
      try {
        return executeAndDecode(template, options);
      } catch (RetryableException e) {
        try {
          retryer.continueOrPropagate(e);
        } catch (RetryableException th) {
          Throwable cause = th.getCause();
          if (propagationPolicy == UNWRAP && cause != null) {
            throw cause;
          } else {
            throw th;
          }
        }
        if (logLevel != Logger.Level.NONE) {
          logger.logRetry(metadata.configKey(), logLevel);
        }
        continue;
      }
    }
  }
```

上面的代码中有一个  `executeAndDecode()` 方法，该方法通过 `RequestTemplate` 生成 `Request` 请求对象，然后利用`Http Client(默认)`获取`response`，来获取响应信息

```java
Object executeAndDecode(RequestTemplate template, Options options) throws Throwable {
    Request request = targetRequest(template);

    if (logLevel != Logger.Level.NONE) {
      logger.logRequest(metadata.configKey(), logLevel, request);
    }

    Response response;
    long start = System.nanoTime();
    try {
      //发起远程通信
      response = client.execute(request, options);
      // ensure the request is set. TODO: remove in Feign 12
      response = response.toBuilder()
          .request(request)
          .requestTemplate(template)
          .build();
    } catch (IOException e) {
      if (logLevel != Logger.Level.NONE) {
        logger.logIOException(metadata.configKey(), logLevel, e, elapsedTime(start));
      }
      throw errorExecuting(request, e);
    }
    //省略部分代码
    ......
  }
```

`client.execute(request, options);`默认使用 `HttpURLConnection `发起远程调用，这里的 client 为 `LoadBalancerFeignClient`。那么看看他的 `execute `方法。

9. LoadBalancerFeignClient

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

最终通过 Ribbon 负载均衡器发起远程调用，具体分析见另一篇关于 Ribbon 的源码分析。

## 3. 总结

![image](http://blog-1259650185.cosbj.myqcloud.com/img/202205/06/1651766926.awebp)

通过源码我们了解了 `Spring Cloud OpenFeign` 的加载配置创建流程。通过注解 `@FeignClient` 和 `@EnableFeignClients` 注解实现了client 的配置声明注册，再通过 `FeignRibbonClientAutoConfiguration` 和 `FeignAutoConfiguration` 类进行自动装配。本文仅对feign 源码的主线进行分析，还有很多细节并未介绍，如果读者感兴趣，可以参考本文，自行阅读源码。

## 4. 补充

### 4.1 Feign的组成

| 接口               | 作用                                                         | 默认值                                                       |
| ------------------ | ------------------------------------------------------------ | ------------------------------------------------------------ |
| Feign.Builder      | Feign的入口                                                  | Feign.Builder                                                |
| Client             | Feign底层用什么去请求                                        | 和Ribbon配合时：LoadBalancerFeignClient不和Ribbon配合时：Fgien.Client.Default |
| Contract           | 契约，注解支持                                               | SpringMVCContract                                            |
| Encoder            | 编码器                                                       | SpringEncoder                                                |
| Decoder            | 解码器                                                       | ResponseEntityDecoder                                        |
| Logger             | 日志管理器                                                   | Slf4jLogger                                                  |
| RequestInterceptor | 用于为每个请求添加通用逻辑（拦截器，例子：比如想给每个请求都带上token） | 无                                                           |

### 4.2 Feign的日志级别

| 日志级别     | 打印内容                                                     |
| ------------ | ------------------------------------------------------------ |
| NONE（默认） | 不记录任何日志                                               |
| BASIC        | 仅记录请求方法，URL，响应状态代码以及执行时间（适合生产环境） |
| HEADERS      | 记录BASIC级别的基础上，记录请求和响应的header                |
| FULL         | 记录请求和响应header，body和元数据                           |

### 4.3 如何给 Feign 添加日志级别

#### 4.3.1 局部配置

**方式一：代码实现**

1. 编写配置类

```java
public class FeignConfig {
  @Bean
  public Logger.Level Logger() {
      return Logger.Level.FULL;
   }
}
```

> 添加 Feign 配置类，可以添加在主类下，但是不用添加 @Configuration。如果添加了 @Configuration 而且又放在了主类之下，那么就会所有 Feign 客户端实例共享，同 Ribbon 配置类一样父子上下文加载冲突；如果一定添加 @Configuration，就放在主类加载之外的包。（建议还是不用加 @Configuration）

2. 配置 @FeignClient

```java
@FeignClient(name = "alibaba-nacos-discovery-server"，configuration = FeignConfig.class)
public interface NacosDiscoveryClientFeign {

    @GetMapping("/hello")
    String hello(@RequestParam(name = "name") String name);
}
```

**方式二：配置文件实现**

```yaml
feign:
  client:
    config:
      #要调用的微服务名称
      clientName:
        loggerLevel: FULL
```

#### 4.3.2 全局配置

**方式一：代码实现**

```java
@EnableFeignClients(defaultConfiguration = FeignConfig.class)
```

**方式二：配置文件实现**

```java
feign:
  client:
    config:
      #将调用的微服务名称改成default就配置成全局的了
      default:
        loggerLevel: FULL
```

### 4.4 Feign 支持的配置项

#### 4.4.1 代码方式支持配置项

| 配置项                           | 作用                                              |
| -------------------------------- | ------------------------------------------------- |
| Logger.Level                     | 指定日志级别                                      |
| Retryer                          | 指定重试策略                                      |
| ErrorDecoder                     | 指定错误解码器                                    |
| Request.Options                  | 超时时间                                          |
| Collection\<RequestInterceptor\> | 拦截器                                            |
| SetterFactory                    | 用于设置Hystrix的配置属性，Fgien整合Hystrix才会用 |

详见 `FeignClientsConfiguration` 中配置

#### 4.4.2 配置文件属性支持配置项

```yaml
feign:
  client:
    config:
      feignName:
        connectTimeout: 5000  # 相当于Request.Optionsn 连接超时时间
        readTimeout: 5000     # 相当于Request.Options 读取超时时间
        loggerLevel: full     # 配置Feign的日志级别，相当于代码配置方式中的Logger
        errorDecoder: com.example.SimpleErrorDecoder  # Feign的错误解码器，相当于代码配置方式中的ErrorDecoder
        retryer: com.example.SimpleRetryer  # 配置重试，相当于代码配置方式中的Retryer
        requestInterceptors: # 配置拦截器，相当于代码配置方式中的RequestInterceptor
          - com.example.FooRequestInterceptor
          - com.example.BarRequestInterceptor
        # 是否对404错误解码
        decode404: false
        encode: com.example.SimpleEncoder
        decoder: com.example.SimpleDecoder
        contract: com.example.SimpleContract
```

Feign 还支持对请求和响应进行 GZIP 压缩，以提高通信效率， 仅支持 Apache HttpClient，详见`FeignContentGzipEncodingAutoConfiguration`  配置方式如下：

```properties
# 配置请求GZIP压缩
feign.compression.request.enabled=true
# 配置响应GZIP压缩
feign.compression.response.enabled=true
# 配置压缩支持的MIME TYPE
feign.compression.request.mime-types=text/xml,application/xml,application/json
# 配置压缩数据大小的下限
feign.compression.request.min-request-size=2048
```

Feign 默认使用 HttpUrlConnection 进行远程调用，可以通过配置开启 HttpClient 或 OkHttp3，具体详见`FeignRibbonClientAutoConfiguration`，配置如下：

```properties
feign.httpclient.enabled=true
# 或
feign.okhttp.enabled=true
```

并添加相应的依赖即可

```xml
<dependency>
    <groupId>io.github.openfeign</groupId>
    <artifactId>feign-okhttp</artifactId>
</dependency>
<-- 或 --/>
<dependency>
    <groupId>io.github.openfeign</groupId>
    <artifactId>feign-httpclient</artifactId>
</dependency>
```

### 4.5 Spring Cloud NamedContextFactory

Spring Cloud  中它为了实现不同的微服务具有不同的配置，例如不同的 `FeignClient` 会使用不同的 `ApplicationContext`，从各自的上下文中获取不同配置进行实例化。在什么场景下我们会需要这种机制呢？ 例如，认证服务是会高频访问的服务，它的客户端超时时间应该要设置的比较小；而报表服务因为涉及到大量的数据查询和统计，它的超时时间就应该设置的比较大。

在 Spring Cloud 中 `NamedContextFactory` 就是为了实现该机制而设计的。我们可以自己手动实现下这个机制。

首先，创建 `AnyinContext` 类和 `AnyinSpecification `类。`AnyinContext` 就是我们的上下文类，或者容器类，它是一个子容器。`AnyinSpecification` 类是对应的配置类保存类，根据不通过的上下文名称(`name`字段）来获取配置类。

```java
public static class AnyinSpecification implements NamedContextFactory.Specification {
        private String name;
        private Class<?>[] configurations;
        public AnyinSpecification(String name, Class<?>[] configurations) {
            this.name = name;
            this.configurations = configurations;
        }
        @Override
        public String getName() {
            return name;
        }
        @Override
        public Class<?>[] getConfiguration() {
            return configurations;
        }
    }
    public static class AnyinContext extends NamedContextFactory<AnyinSpecification>{
        private static final String PROPERTY_SOURCE_NAME = "anyin";
        private static final String PROPERTY_NAME = PROPERTY_SOURCE_NAME + ".context.name";
        public AnyinContext(Class<?> defaultConfigType) {
            super(defaultConfigType, PROPERTY_SOURCE_NAME, PROPERTY_NAME);
        }
    }
}
```

接着，我们创建三个 bean 类，它们会分别置于父容器配置、子容器公共配置、子容器配置类中。如下：

```java
public static class Parent {}
public static class AnyinCommon{}

@Getter
public static class Anyin {
    private String context;
    public Anyin(String context) {
        this.context = context;
    }
}
```

然后，再创建三个配置类，如下：

```java
// 父容器配置类
@Configuration(proxyBeanMethods = false)
public static class ParentConfig {
    @Bean
    public Parent parent(){
        return new Parent();
    }
    @Bean
    public Anyin anyin(){
        return new Anyin("anyin parent=============");
    }
}
// 子容器公共配置类
@Configuration(proxyBeanMethods = false)
public static class AnyinCommonCnofig{
    @Bean
    public AnyinCommon anyinCommon(){
        return new AnyinCommon();
    }
}
// 子容器1配置类
@Configuration(proxyBeanMethods = false)
public static class Anyin1Config{
    @Bean
    public Anyin anyin(){
        return new Anyin("anyin1=============");
    }
}
// 子容器2配置类
@Configuration(proxyBeanMethods = false)
public static class Anyin2Config{
    @Bean
    public Anyin anyin(){
        return new Anyin("anyin2=============");
    }
}
```

最后，我们来做下代码测试。

```java
@Test
public void test(){
    // 创建父容器
    AnnotationConfigApplicationContext parent = new AnnotationConfigApplicationContext();
    // 注册父容器配置类
    parent.register(ParentConfig.class);
    parent.refresh();
    // 创建子容器，并且注入默认的功能配置类
    AnyinContext context = new AnyinContext(AnyinCommonCnofig.class);
    // 子容器1配置类
    AnyinSpecification spec1 = new AnyinSpecification("anyin1", new Class[]{Anyin1Config.class});
    // 子容器2配置类
    AnyinSpecification spec2 = new AnyinSpecification("anyin2", new Class[]{Anyin2Config.class});
    // 子容器和父容器绑定关系
    context.setApplicationContext(parent);
    // 子容器注入子容器1/2配置类
    context.setConfigurations(Lists.newArrayList(spec1, spec2));
    // 获取子容器1的Parent实例
    Parent parentBean1 = context.getInstance("anyin1", Parent.class);
    // 获取子容器2的Parent实例
    Parent parentBean2 = context.getInstance("anyin2", Parent.class);
    // 获取父容器的Parent实例
    Parent parentBean3 = parent.getBean(Parent.class);
    // true
    log.info("parentBean1 == parentBean2: {}", parentBean1.equals(parentBean2));
    // true
    log.info("parentBean1 == parentBean3: {}", parentBean1.equals(parentBean3));
    // true
    log.info("parentBean2 == parentBean3: {}", parentBean2.equals(parentBean3));
    // 获取子容器1的AnyinCommon实例
    AnyinCommon anyinCommon1 = context.getInstance("anyin1", AnyinCommon.class);
    // 获取子容器2的AnyinCommon实例
    AnyinCommon anyinCommon2 = context.getInstance("anyin1", AnyinCommon.class);
    // true
    log.info("anyinCommon1 == anyinCommon2: {}", anyinCommon1.equals(anyinCommon2));
    // 报错，没有找到对应的bean
    // AnyinCommon anyinCommon3 = parent.getBean(AnyinCommon.class);
    // 获取子容器1的Anyin对象
    Anyin anyin1 = context.getInstance("anyin1", Anyin.class);
    // anyin1 context: anyin1=============
    log.info("anyin1 context: {}", anyin1.getContext());
    // anyin2 context: anyin2=============
    Anyin anyin2 = context.getInstance("anyin2", Anyin.class);
    log.info("anyin2 context: {}", anyin2.getContext());
    // false
    log.info("anyin1 == anyin2: {}", anyin1.equals(anyin2));
    // anyinParent: anyin parent=============
    Anyin anyinParent = parent.getBean(Anyin.class);
    log.info("anyinParent: {}", anyinParent.getContext());
}
```

以上代码可能会比较长，请详细查阅。通过以上测试，我们可以总结以下几点：

- 子容器可以拿到父容器的实例
- 父容器无法拿到子容器的实例
- 实例优先从公共配置类中获取（这点需要在`AnyinCommonCnofig`配置类添加`Anyin`实例配置）



## 参考

[Spring Cloud OpenFeign源码解析](https://zhuanlan.zhihu.com/p/429668670)

[关于OpenFeign那点事儿 - 源码篇](https://juejin.cn/post/7069281398967762952)

[【图文】Spring Cloud OpenFeign 源码解析](https://juejin.cn/post/6844904066229927950#heading-5)
