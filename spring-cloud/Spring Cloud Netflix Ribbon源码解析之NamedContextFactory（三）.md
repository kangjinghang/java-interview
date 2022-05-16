## 1. 前言

经过了前两篇对 Ribbon 的介绍，我们基本把整个脉络梳理清楚了。相信读者已经对 ribbon 的实现原理有个一个整体的了解，如果你还没有看懂，希望你参考前面两篇文章，自己动手亲自跟踪一遍代码，相信你会有不一样的体会。好了，今天我们来重点说一下 `NamedContextFactory `这个类。为什么要介绍这个类呢？因为这个抽象类在 spring cloud 中是一个十分重要的类，不仅在 ribbon 中被使用，而且在 feign 中也有被用到。所以有必要单独写一篇文章来介绍它，以便于后面的学习。那么我们一起来看看吧！

## 2. 源码分析

### 2.1 NamedContextFactory

```java
public abstract class NamedContextFactory<C extends NamedContextFactory.Specification>
  implements DisposableBean, ApplicationContextAware {
}
```

这个抽象类实现了 `ApplicationContextAware `接口，那么必然要重写 `setApplicationContext` 方法：

```java
@Override
public void setApplicationContext(ApplicationContext parent) throws BeansException {
 this.parent = parent;
}
```

那么在 spring 应用上下文启动的时候，必然会为我们注入 `ApplicationContext` 对象，有了它，我们就可以做很多事情，比如通过依赖查找获取容器中的某个 bean。

我们先看一下这个抽象类中提供了哪些方法，这个抽象类为我们提供了：

- createContext方法：用于创建应用上下文
- getContext方法：用于获取应用上下文
- getInstance方法：用于查找某个 bean 实例

其他方法就不一一介绍了。

那么这个抽象类到底有什么作用呢？好吧，直接上答案： 不管是在 ribbon 中还是在 feign 中，都是根据服务名，创建一个 spring 的子应用上下文，比如我们通过 `restTemplate.getForObject("http://nacos-discovery-provider-sample/echo/" + message, String.class);`调用远程服务的时候，这里的 `nacos-discovery-provider-sample `就是对应的服务名，然后存在内存中的 map 中，以服务名作为 key，值为 ApplicationContext 对象：

```java
private Map<String, AnnotationConfigApplicationContext> contexts = new ConcurrentHashMap<>();
```

到目前为止，我们知道这么多就够了。那么接下来我们具体看看它的子类，在 Ribbon 环境下，`SpringClientFactory` 实现了它。

### 2.2 SpringClientFactory

创建客户端、负载均衡器和客户端配置实例的工厂，为每一个客户端创建一个 Spring ApplicationContext。可以理解成相当于BeanFactory。在其中持有关于 Ribbon 的相关配置等信息。

```java
public class SpringClientFactory extends NamedContextFactory<RibbonClientSpecification> {
   // 获取客户端
   public <C extends IClient<?, ?>> C getClient(String name, Class<C> clientClass) {
       ......
   }
   // 获取负载均衡器
   public ILoadBalancer getLoadBalancer(String name) {
       ......
   }
   // 获取客户端配置
   public IClientConfig getClientConfig(String name) {
       ......
   }
   // 获取上下文
   public RibbonLoadBalancerContext getLoadBalancerContext(String serviceId) {
       ......
   }
   
}
```

`SpringClientFacotry `的构造函数：

```java
public SpringClientFactory() {
 super(RibbonClientConfiguration.class, NAMESPACE, "ribbon.client.name");
}
```

super 调用父类 `NamedContextFactory` 的构造器，将 `RibbonClientConfiguration.class` 赋值给`defaultConfigType`。`NamedContextFactory  `会为  `Spring ApplicationContext` 创建一个 `子ApplicationContext`。

```java
public NamedContextFactory(Class<?> defaultConfigType, String propertySourceName,
  String propertyName) {
 //defaultConfigType=RibbonClientConfiguration.class先记住这个
 this.defaultConfigType = defaultConfigType;
 this.propertySourceName = propertySourceName;
 this.propertyName = propertyName;
}
```

在调用 `createContext` 中有注入 `defaultConfigType` 类型的bean，即注入 `RibbonClientConfiguration`。

```java
protected AnnotationConfigApplicationContext createContext(String name) {
    ......
    context.register(PropertyPlaceholderAutoConfiguration.class,
      this.defaultConfigType);
    ......  
}
```

### 2.3 RibbonClientConfiguration

Ribbon 客户端配置，提供默认的负载均衡算法等配置。第一次调用接口的时候，才会触发该配置类。这里先有个印象，重点今天的重点不是它，**但是要记住，如果你在什么都不配置的情况下，框架会为你提供以下这些默认配置。**

```java
@Configuration(proxyBeanMethods = false)
@EnableConfigurationProperties
@Import({ HttpClientConfiguration.class, OkHttpRibbonConfiguration.class,
      RestClientRibbonConfiguration.class, HttpClientRibbonConfiguration.class })
public class RibbonClientConfiguration {
    // 默认的IRule，默认为ZoneAvoidanceRule
    // 使用了ConditionalOnMissingBean，当自定义实现bean的时候，默认的配置就不会被加载了。
    @Bean
    @ConditionalOnMissingBean
    public IRule ribbonRule(IClientConfig config) {
        // propertiesFactory是通过配置设置IRule实现的，
        // 比如在application.yml文件中设置。
        if (this.propertiesFactory.isSet(IRule.class, name)) {
          return this.propertiesFactory.get(IRule.class, config, name);
       }
       ZoneAvoidanceRule rule = new ZoneAvoidanceRule();
       rule.initWithNiwsConfig(config);
       return rule;
    }
     
    // 默认的IPing实现，默认为： DummyPing
    @Bean
    @ConditionalOnMissingBean
    public IPing ribbonPing(IClientConfig config) {
        if (this.propertiesFactory.isSet(IPing.class, name)) {
            return this.propertiesFactory.get(IPing.class, config, name);
        }
        return new DummyPing();
    }
    
    // 默认的ILoadBalancer实现，默认为：ZoneAwareLoadBalancer
    @Bean
    @ConditionalOnMissingBean
    public ILoadBalancer ribbonLoadBalancer(IClientConfig config,
        ServerList<Server> serverList, ServerListFilter<Server> serverListFilter,
          IRule rule, IPing ping, ServerListUpdater serverListUpdater) {
       if (this.propertiesFactory.isSet(ILoadBalancer.class, name)) {
           return this.propertiesFactory.get(ILoadBalancer.class, config, name);
       }
       // 将IRule和IPing作为参数
       return new ZoneAwareLoadBalancer<>(config, rule, ping, serverList,
         serverListFilter, serverListUpdater);
    }
    
    // Ribbon负载均衡上下文
    @Bean
    @ConditionalOnMissingBean
    public RibbonLoadBalancerContext ribbonLoadBalancerContext(ILoadBalancer loadBalancer,
        IClientConfig config, RetryHandler retryHandler) {
        return new RibbonLoadBalancerContext(loadBalancer, config, retryHandler);
    }
}
```

我们继续回到 `SpringClientFactory`，看看它的构造函数是在哪里被调用的，如果看过我写的 ribbon 系列第一篇的读者，就会知道它是在` RibbonAutoConfiguration `配置类中被创建并注册到spring上下文中：

### 2.4 RibbonAutoConfiguration

```java
@Configuration
@Conditional(RibbonAutoConfiguration.RibbonClassesConditions.class)
@RibbonClients
@AutoConfigureAfter(
  name = "org.springframework.cloud.netflix.eureka.EurekaClientAutoConfiguration")
@AutoConfigureBefore({ LoadBalancerAutoConfiguration.class,
  AsyncLoadBalancerAutoConfiguration.class })
@EnableConfigurationProperties({ RibbonEagerLoadProperties.class,
  ServerIntrospectorProperties.class })
public class RibbonAutoConfiguration {

 // 这里很关键，后面我们会说到，留个印象
 @Autowired(required = false)
 private List<RibbonClientSpecification> configurations = new ArrayList<>();

 @Autowired
 private RibbonEagerLoadProperties ribbonEagerLoadProperties;

 @Bean
 public HasFeatures ribbonFeature() {
  return HasFeatures.namedFeature("Ribbon", Ribbon.class);
 }

 //传入configurations基金和，创建实例对象，并将其添加到spring应用上下文中
 @Bean
 @ConditionalOnMissingBean
 public SpringClientFactory springClientFactory() {
  SpringClientFactory factory = new SpringClientFactory();
  factory.setConfigurations(this.configurations);
  return factory;
 }
 //将SpringClientFactory作为构造器参数传入到RibbonLoadBalancerClient中，很重要。
 @Bean
 @ConditionalOnMissingBean(LoadBalancerClient.class)
 public LoadBalancerClient loadBalancerClient() {
  return new RibbonLoadBalancerClient(springClientFactory());
 }
 ......
}
```

好了，到这里，我们基本上把 SpringClientFactory 的来龙去脉已经分析清楚了。接下来，我们一起来看看，这个 `SpringClientFactory` 在哪里被使用到。在ribbon系列的第一篇中，我们在 `RibbonLoadBalancerClient` 中，看到在执行execute方法中：

### 2.5 RibbonLoadBalancerClient

```java
public <T> T execute(String serviceId, LoadBalancerRequest<T> request, Object hint)
   throws IOException {
 //获取负载均衡器
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

忘记了同学，请自行回顾。我们在分析到`ILoadBalancer loadBalancer = getLoadBalancer(serviceId);`这行代码的时候，我们就没有继续深入了。那么今天我们重点 分析下，`getLoadBalancer(serviceId)`方法到底是怎么获取负载均衡器的以及相关的配置信息。调用 getLoadBalancer 方法会进入下面的代码：

```java
protected ILoadBalancer getLoadBalancer(String serviceId) {
 return this.clientFactory.getLoadBalancer(serviceId);
}
```

其中 `clientFactory `就是之前通过构造器传入的 `SpringClientFactory`，然后调用它的 `getLoadBalancer` 方法：

### 2.6 再次回到 SpringClientFactory

```java
public ILoadBalancer getLoadBalancer(String name) {
 return getInstance(name, ILoadBalancer.class);
}
```

前面我们已经分析了 `SpringClientFactory` 类的作用，那么重点看一下 `getInstance `方法：

```java
@Override
public <C> C getInstance(String name, Class<C> type) {
 //调用NamedContextFactory的getInstance方法
 C instance = super.getInstance(name, type);
 if (instance != null) {
  return instance;
 }
 IClientConfig config = getInstance(name, IClientConfig.class);
 return instantiateWithConfig(getContext(name), type, config);
}
```

在方法内部首先会调用父类的 getInstance(name, type) 方法：

### 2.7 再次回到 NamedContextFactory

```java
public <T> T getInstance(String name, Class<T> type) {
 AnnotationConfigApplicationContext context = getContext(name);
 if (BeanFactoryUtils.beanNamesForTypeIncludingAncestors(context,
   type).length > 0) {
  return context.getBean(type);
 }
 return null;
}
```

从上下文中获取 ILoadBalancer 类型的 bean。接着看一下 getContext 方法：

```java
private Map<String, AnnotationConfigApplicationContext> contexts = new ConcurrentHashMap<>();
......
protected AnnotationConfigApplicationContext getContext(String name) {
 if (!this.contexts.containsKey(name)) {
  synchronized (this.contexts) {
   if (!this.contexts.containsKey(name)) {
    this.contexts.put(name, createContext(name));
   }
  }
 }
 return this.contexts.get(name);
}
```

获取服务名的上下文。首先判断 map 中是否包含 key 为服务名，如果不包含则以服务名作为 key，并调用 `createContext` 方法创建AnnotationConfigApplicationContext 作为值存入 `contexts` 中；如果包含，则根据服务名取出对应的上下文对象。重点看一下 `createContext`，重点来喽，重点来喽，重点来喽，重要的事情说三遍：

```java
protected AnnotationConfigApplicationContext createContext(String name) {
 AnnotationConfigApplicationContext context = new AnnotationConfigApplicationContext();
 // @RibbonClient的value或name属性，指定了服务名的配置
 if (this.configurations.containsKey(name)) {
  for (Class<?> configuration : this.configurations.get(name)
    .getConfiguration()) {
   context.register(configuration);
  }
 }
 //通过@RibbonClients的defaultConfiguration指定了配置
 for (Map.Entry<String, C> entry : this.configurations.entrySet()) {
  if (entry.getKey().startsWith("default.")) {
   for (Class<?> configuration : entry.getValue().getConfiguration()) {
    context.register(configuration);
   }
  }
 }
 // 使用默认的配置，即RibbonClientConfiguration
 context.register(PropertyPlaceholderAutoConfiguration.class,
   this.defaultConfigType);
 context.getEnvironment().getPropertySources().addFirst(new MapPropertySource(
   this.propertySourceName,
   Collections.<String, Object>singletonMap(this.propertyName, name)));
 if (this.parent != null) {
  // Uses Environment from parent as well as beans
  // 将Spring ApplicationContext设置成该服务名的上下文的父级
  context.setParent(this.parent);
  // jdk11 issue
  // https://github.com/spring-cloud/spring-cloud-netflix/issues/3101
  context.setClassLoader(this.parent.getClassLoader());
 }
 context.setDisplayName(generateDisplayName(name));
 context.refresh();
 return context;
}
```

见代码中的注释，看到这里，很多同学肯定会有疑问，你是怎么知道这些代码跟 `@RibbonClient`、`@RibbonClients `有关系的呢？好的，那么我们先看看 `this.configurations` 是什么，以及在哪里初始化的，请认真观看哦：

```java
public abstract class NamedContextFactory<C extends NamedContextFactory.Specification>
  implements DisposableBean, ApplicationContextAware {

 ......

 private Map<String, C> configurations = new ConcurrentHashMap<>();

 ......
 public void setConfigurations(List<C> configurations) {
  for (C client : configurations) {
   this.configurations.put(client.getName(), client);
  }
 }
 ......
}
```

关键就在上面的 `setConfigurations` 方法，那么看一下 `setConfigurations` 方法在哪里调用的。忘记了的同学请往上翻，这里为了方便大家理解，还是再放一下代码吧：

```java
@Configuration
@Conditional(RibbonAutoConfiguration.RibbonClassesConditions.class)
@RibbonClients
@AutoConfigureAfter(
  name = "org.springframework.cloud.netflix.eureka.EurekaClientAutoConfiguration")
@AutoConfigureBefore({ LoadBalancerAutoConfiguration.class,
  AsyncLoadBalancerAutoConfiguration.class })
@EnableConfigurationProperties({ RibbonEagerLoadProperties.class,
  ServerIntrospectorProperties.class })
public class RibbonAutoConfiguration {

 //关键就在这个RibbonClientSpecification类型的bean是在哪里被添加到spring的容器中的
 @Autowired(required = false)
 private List<RibbonClientSpecification> configurations = new ArrayList<>();
 ......
 //传入configurations基金和，创建实例对象，并将其添加到spring应用上下文中
 @Bean
 @ConditionalOnMissingBean
 public SpringClientFactory springClientFactory() {
  SpringClientFactory factory = new SpringClientFactory();
  factory.setConfigurations(this.configurations);
  return factory;
 }
 
 ......
}
```

见代码中的注释。这里我们直接说方法：在 IDEA 中，在 MAC 环境下可以通过 cmd+shift+f 全局搜索 RibbonClientSpecification 在哪里被用到，可以很容易的被找到，自己动手试试吧。结果就在 `RibbonClientConfigurationRegistrar` 类中被注册到 spring 容器中。另外如果熟悉 ribbon 的同学，应该都知道，ribbon 为我们提供了 `@RibbonClient、@RibbonClients` 注解，用于针对服务自定义或提供全局自定义配置。

```java
@Configuration(proxyBeanMethods = false)
@Import(RibbonClientConfigurationRegistrar.class)
@Target(ElementType.TYPE)
@Retention(RetentionPolicy.RUNTIME)
@Documented
public @interface RibbonClient {
}

@Configuration(proxyBeanMethods = false)
@Retention(RetentionPolicy.RUNTIME)
@Target({ ElementType.TYPE })
@Documented
@Import(RibbonClientConfigurationRegistrar.class)
public @interface RibbonClients {

 RibbonClient[] value() default {};

 Class<?>[] defaultConfiguration() default {};

}
```

在以上两个注解中，都为我们导入了 `RibbonClientConfigurationRegistrar  `配置类。

### 2.8 RibbonClientConfigurationRegistrar

```java
public class RibbonClientConfigurationRegistrar implements ImportBeanDefinitionRegistrar {

 @Override
 public void registerBeanDefinitions(AnnotationMetadata metadata,
   BeanDefinitionRegistry registry) {
  Map<String, Object> attrs = metadata
    .getAnnotationAttributes(RibbonClients.class.getName(), true);
  if (attrs != null && attrs.containsKey("value")) {
   AnnotationAttributes[] clients = (AnnotationAttributes[]) attrs.get("value");
   for (AnnotationAttributes client : clients) {
    //获取@RibbonClient注解属性configuration上的配置并注册为bean
    registerClientConfiguration(registry, getClientName(client),
      client.get("configuration"));
   }
  }
  if (attrs != null && attrs.containsKey("defaultConfiguration")) {
   String name;
   if (metadata.hasEnclosingClass()) {
    name = "default." + metadata.getEnclosingClassName();
   }
   else {
    name = "default." + metadata.getClassName();
   }
   //获取@RibbonClients注解属性defaultConfiguration上的配置并注册为bean, bean名称以default.开头
   registerClientConfiguration(registry, name,
     attrs.get("defaultConfiguration"));
  }
  Map<String, Object> client = metadata
    .getAnnotationAttributes(RibbonClient.class.getName(), true);
  String name = getClientName(client);
  if (name != null) {
   //获取@RibbonClient注解属性configuration上的配置并注册为bean
   registerClientConfiguration(registry, name, client.get("configuration"));
  }
 }

 ......

 private void registerClientConfiguration(BeanDefinitionRegistry registry, Object name,
   Object configuration) {
  BeanDefinitionBuilder builder = BeanDefinitionBuilder
    .genericBeanDefinition(RibbonClientSpecification.class);
  builder.addConstructorArgValue(name);
  builder.addConstructorArgValue(configuration);
  registry.registerBeanDefinition(name + ".RibbonClientSpecification",
    builder.getBeanDefinition());
 }

}
```

见上面的代码注释，如果看不懂的同学，请自行补充基础知识。最终注册的就是 `RibbonClientSpecification `类型的bean。好了，弄清楚了这些，我们继续回到 `NamedContextFactory中` 的 `createContext` 方法。

### 2.9 三次回到 NamedContextFactory

```java
protected AnnotationConfigApplicationContext createContext(String name) {
 AnnotationConfigApplicationContext context = new AnnotationConfigApplicationContext();
 // @RibbonClient的value或name属性，指定了服务名的配置
 if (this.configurations.containsKey(name)) {
  for (Class<?> configuration : this.configurations.get(name)
    .getConfiguration()) {
   context.register(configuration);
  }
 }
 //通过@RibbonClients的defaultConfiguration指定了配置
 for (Map.Entry<String, C> entry : this.configurations.entrySet()) {
  if (entry.getKey().startsWith("default.")) {
   for (Class<?> configuration : entry.getValue().getConfiguration()) {
    context.register(configuration);
   }
  }
 }
 // 使用默认的配置，即RibbonClientConfiguration
 context.register(PropertyPlaceholderAutoConfiguration.class,
   this.defaultConfigType);
 context.getEnvironment().getPropertySources().addFirst(new MapPropertySource(
   this.propertySourceName,
   Collections.<String, Object>singletonMap(this.propertyName, name)));
 if (this.parent != null) {
  // Uses Environment from parent as well as beans
  // 将Spring ApplicationContext设置成该服务名的上下文的父级
  context.setParent(this.parent);
  // jdk11 issue
  // https://github.com/spring-cloud/spring-cloud-netflix/issues/3101
  context.setClassLoader(this.parent.getClassLoader());
 }
 context.setDisplayName(generateDisplayName(name));
 context.refresh();
 return context;
}
```

解释下：根据服务名创建一个 ApplicationContext，在 ApplicationContext 中会注册通过 @RibbonClient 或 @RibbonClients 配置的配置类，以及默认的配置类 RibbonClientConfiguration。在各个 Configuration 中通过 @Bean 的方式注册 IRule 或 ILoadBalancer 等组件的时候，要使用 @ConditionalOnMissingBean，如果不使用此注册，会存在多个 Bean，后注册的会覆盖先注册的。

**多说一句：createContext 方法是在父类 NamedContextFactory 中提供的，而子类并未覆盖，所以不管是 ribbon 还是 feign 最终都是通过这个方法根据服务名创建属于自己的上下文配置。**

至此我们已经清楚了，是怎么从 spring 容器中获取负载均衡器的，以及这些配置的来源有哪些。同样，其他关于 ribbon 的配置，比如IRule、IPing 等都是通过这种方式查找和提供配置的。有了以上知识作为储备，那么接下来，看看怎么自定义 Ribbon 相关配置以及注意事项。

## 3. 自定义配置

不使用默认实现的 IRule，自定义实现 IRule。（ILoadBalancer 或 IPing 使用方式一样）

### 3.1 通过注解 @RibbonClient 或 @RibbonClients 指定配置类

1. 创建 IRule 的实现类，一般通过继承 AbstractLoadBalancerRule：

```java
import com.netflix.client.config.IClientConfig;
import com.netflix.loadbalancer.AbstractLoadBalancerRule;
import com.netflix.loadbalancer.Server;
 
import java.util.List;
 
/**
 * 自定义负载均衡规则
 * 永远返回服务列表中的第一个服务
 */
public class MyLoadBalancerRule extends AbstractLoadBalancerRule {
 
    @Override
    public void initWithNiwsConfig(IClientConfig clientConfig) {
 
    }
 
    @Override
    public Server choose(Object key) {
        System.out.println("=====================进入MyLoadBalancerRule=================");
 
        // 获取所有的服务
        List<Server> serverList = getLoadBalancer().getAllServers();
 
        if (serverList==null || serverList.size()==0) {
            return null;
        }
        // 返回服务列表中的第一个服务
        return serverList.get(0);
    }
}
```

2. 创建 configuration

```java
import com.netflix.loadbalancer.IRule;
import org.springframework.boot.autoconfigure.condition.ConditionalOnMissingBean;
import org.springframework.context.annotation.Bean;
import org.springframework.context.annotation.Configuration;
 
/**
 * 自定义
 */
@Configuration
public class MyRibbonClientConfiguration {
 
    @Bean
    @ConditionalOnMissingBean
    public IRule myIRule() {
        return new MyLoadBalancerRule();
    }
 
 
}
```

3. 在启动类上加上 @RibbonClient 注解

```java
@SpringBootApplication
@RibbonClient(name = "服务名",configuration = MyRibbonClientConfiguration.class)
public class MyClientApplication {
 
    public static void main(String[] args) {
        SpringApplication.run(MyClientApplication.class, args);
    }
 
}
```

4. 启动客户端项目，并访问接口。

可以发现进入了自定义的 MyLoadBalancerRule 的 choose 来实现负载均衡。

### 3.2 通过配置实现自定义组件

使用 PropertiesFactory 提供的功能，通过配置完成自定义组件。

```java
NFLoadBalancerClassName：自定义ILoadBalancer
NFLoadBalancerPingClassName：自定义IPing
NFLoadBalancerRuleClassName：自定义IRule
NIWSServerListClassName：自定义ServerList
NIWSServerListFilterClassName：自定义ServerListFilter
```

修改 application.yml 配置：

```java
服务名:
  ribbon:
    NFLoadBalancerRuleClassName:
      client.config.MyLoadBalancerRule
```

两个方式都可以实现自定义组件，并且第二种通过配置的方式优先级比通过代码实现要高。

### 3.3 注意事项

这里需要注意一点：假设同一个客户端需要调用多个服务端的接口，比如一个接口需要调用服务A的接口：http://serverA/server/info，一个接口需要调用服务B的接口：http://serverB/server/info。如果此时你想调用服务A的接口使用自定义的负载均衡逻辑，调用服务B的接口还是使用默认的负载均衡逻辑。**对于自定义的配置类，你把它放在了 @ComponentScan 的扫描范围内，则这个自定义的配置类将全局生效，这样会造成服务A和服务B都会使用自定义的配置**。为了避免这样的情况，需要将服务A的自定义配置放在 @ComponentScan无法扫描的类，或通过  @ComponentScan过滤掉。

比如在启动类上通过 @ComponentScan(excludeFilters=“”）过滤掉配置类，并且 @RibbonClient 中的 name 属性值一定要和 url 中的服务名相同：

```java
// myServer一定要是调用接口http://myServer/server/info中的服务名
@RibbonClient(name = "myServer",configuration = MyRibbonClientConfiguration.class)
@ComponentScan(excludeFilters = "配置类所在的包")
```

**这里我给的建议是，如果只是对某个服务应用自定义配置，那么就不要在配置类上添加`@Configuration`注解，这样就不会被扫描到。**

### 3.4 原因分析

在第一次调用客户端接口的时候，通过 SpringClientFactory 的 getInstance 获取负载均衡器，最终会调用其父类 NamedContextFactory的 createContext，来初始化服务名对应的上下文。

1. 首先查看是否有服务名对应的配置，即通过 `@RibbonClient(name="服务名", configuration="")` 来配置，如果有注册到当前上下文中；
2. 然后再查看是否有 `default` 开头的配置，即通 过`@RibbonClients(defaultConfiguration="")`来配置，如果有注册到当前上下文中。
3. 最后注册默认的配置。最后将当前服务名的上下文设置成 Spring 上下文的子级。

当自定义的配置在 @ComponentScan 扫描范围内的时候（如果配置类上标注了 @Configuration 注解）即会被注册到父级 Spring 上下文中。这样当加载默认的配置类 RibbonClientConfiguration，因为使用了 @ConditionalOnMissingBean，此时父级的上下文中已经存在了，条件不满足，就不会注册这里的 bean。

当自定义的配置不在 @ComponentScan 扫描范围内的时候，就不会加进 Spring 上下文，此时要想配置生效，就需要 **@RibbonClient 配置的 name 值与服务名一致，这样配置会加入当前服务名所对应的上下文中，只会对当前服务名生效**。

### 3.5 总结

**当自定义的配置只需要应用到某个服务名上时，只需要将自定义配置注册到服务名的上下文中， 不要将配置类放在启动类能扫描到的包下或者不标注 @Configuration 注解**。

**当自定义的配置需要应用到所有的服务名上时，则可以将自定义配置注册到 Spring 上下文中**。

主要分成 2 种配置：

1. 超时时间等静态配置，使用 ribbon.* 配置所有 Client，使用 .ribbon.* 配置某个Client
2. 使用哪种核心接口实现类配置，使用 @RibbonClients 注解做默认配置，使用 @RibbonClient 做针对 Client 的配置（注意@Configuration 不要被 SpringBoot 主启动类扫描到的问题）



## 参考

[Spring Cloud Netflix Ribbon源码解析之NamedContextFactory（三）](https://zhuanlan.zhihu.com/p/493877201)
