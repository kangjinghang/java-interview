# 1. 概述

> 老艿艿：本系列假定胖友已经阅读过 [《Apollo 官方 wiki 文档》](https://github.com/ctripcorp/apollo/wiki/) ，特别是 [《Spring 整合方式》](https://github.com/ctripcorp/apollo/wiki/Java客户端使用指南#32-spring整合方式) 。
>
> 😁 因为 Spring 仅仅处于入门水平，所以可能一些地方，表述的灰常业余。

**本文分享 Spring 外部化配置的集成**。我们先看看官方文档的说明：

> 使用上述两种方式的配置形式( *基于 XML 的配置和基于Java的配置* )后，Apollo 会在 Spring 的 **postProcessBeanFactory** 阶段注入配置到 Spring 的 Environment中，早于 bean 的初始化阶段，所以对于普通的 bean 注入配置场景已经能很好的满足。
>
> 不过 Spring Boot 有一些场景需要配置在更早的阶段注入，比如使用 `@ConditionalOnProperty` 的场景或者是有一些 `spring-boot-starter` 在启动阶段就需要读取配置做一些事情（ 如 [`spring-boot-starter-dubbo`](https://github.com/teaey/spring-boot-starter-dubbo) )，所以对于 Spring Boot 环境建议通过以下方式来接入 Apollo ( 需要0.10.0及以上版本 ）。
> 使用方式很简单，只需要在 `application.properties/bootstrap.properties` 中按照如下样例配置即可。
>
> 1、在 bootstrap 阶段注入默认 `application` namespace 的配置示例：
>
> ```properties
> # will inject 'application' namespace in bootstrap phase
> apollo.bootstrap.enabled = true
> ```
>
> 2、在 bootstrap 阶段注入**非默认** `application` namespace 或多个 namespace 的配置示例
>
> ```properties
> apollo.bootstrap.enabled = true
> # will inject 'application', 'FX.apollo' and 'application.yml' namespaces in bootstrap phase
> apollo.bootstrap.namespaces = application,FX.apollo,application.yml
> ```

下面，让我们来看看具体的代码实现。

# 2. spring.factories

Apollo 在 `apollo-client` 的 [`META-INF/spring.factories`](https://github.com/YunaiV/apollo/blob/2907eebd618825f32b8e27586cb521bcd0221a7e/apollo-client/src/main/resources/META-INF/spring.factories) 定义如下：

```properties
org.springframework.boot.autoconfigure.EnableAutoConfiguration=\
com.ctrip.framework.apollo.spring.boot.ApolloAutoConfiguration
org.springframework.context.ApplicationContextInitializer=\
com.ctrip.framework.apollo.spring.boot.ApolloApplicationContextInitializer
org.springframework.boot.env.EnvironmentPostProcessor=\
com.ctrip.framework.apollo.spring.boot.ApolloApplicationContextInitializer
```

* 这个 `spring.factories` 里面配置的那些类，主要作用是告诉 Spring Boot 这个 **starter** 所需要加载的那些 xxxAutoConfiguration 和 xxxContextInitializer 类，也就是你真正的要自动注册的那些 bean 或功能。然后，我们实现一个 `spring.factories` 指定的类即可。
* 此处配置了 **ApolloAutoConfiguration** 、 **ApolloApplicationContextInitializer**  和 **ApolloApplicationContextInitializer** 类。

# 3. ApolloAutoConfiguration

`com.ctrip.framework.apollo.spring.boot.ApolloAutoConfiguration` ，自动注入 **ConfigPropertySourcesProcessor** bean 对象，当**不存在** **PropertySourcesProcessor** 时，以实现 Apollo 配置的自动加载。代码如下：

```Java
@Configuration
@ConditionalOnProperty(PropertySourcesConstants.APOLLO_BOOTSTRAP_ENABLED)
@ConditionalOnMissingBean(PropertySourcesProcessor.class) // 缺失 PropertySourcesProcessor 时
public class ApolloAutoConfiguration {

    @Bean
    public ConfigPropertySourcesProcessor configPropertySourcesProcessor() {
        return new ConfigPropertySourcesProcessor(); // 注入 ConfigPropertySourcesProcessor bean 对象
    }

}
```

# 4. ApolloApplicationContextInitializer

`com.ctrip.framework.apollo.spring.boot.ApolloApplicationContextInitializer` ，实现 ApplicationContextInitializer 接口，在 Spring Boot 启动阶段( **bootstrap phase** )，注入**配置**的 Apollo Config 对象们。

> 实现代码上，和 PropertySourcesProcessor 一样实现了注入**配置**的 Apollo Config 对象们，差别在于处于 Spring 的不同阶段。

代码如下：

```java
public class ApolloApplicationContextInitializer implements
    ApplicationContextInitializer<ConfigurableApplicationContext> , EnvironmentPostProcessor, Ordered {
  public static final int DEFAULT_ORDER = 0;

  private static final Logger logger = LoggerFactory.getLogger(ApolloApplicationContextInitializer.class);
  private static final Splitter NAMESPACE_SPLITTER = Splitter.on(",").omitEmptyStrings()
      .trimResults();
  public static final String[] APOLLO_SYSTEM_PROPERTIES = {ApolloClientSystemConsts.APP_ID,
      ApolloClientSystemConsts.APOLLO_LABEL,
      ApolloClientSystemConsts.APOLLO_CLUSTER,
      ApolloClientSystemConsts.APOLLO_CACHE_DIR,
      ApolloClientSystemConsts.APOLLO_ACCESS_KEY_SECRET,
      ApolloClientSystemConsts.APOLLO_META,
      ApolloClientSystemConsts.APOLLO_CONFIG_SERVICE,
      ApolloClientSystemConsts.APOLLO_PROPERTY_ORDER_ENABLE,
      ApolloClientSystemConsts.APOLLO_PROPERTY_NAMES_CACHE_ENABLE};

  private final ConfigPropertySourceFactory configPropertySourceFactory = SpringInjector
      .getInstance(ConfigPropertySourceFactory.class);

  private int order = DEFAULT_ORDER;

  @Override
  public void initialize(ConfigurableApplicationContext context) {
    ConfigurableEnvironment environment = context.getEnvironment();
    // 获得 "apollo.bootstrap.enabled" 配置项，若未开启，忽略
    if (!environment.getProperty(PropertySourcesConstants.APOLLO_BOOTSTRAP_ENABLED, Boolean.class, false)) {
      logger.debug("Apollo bootstrap config is not enabled for context {}, see property: ${{}}", context, PropertySourcesConstants.APOLLO_BOOTSTRAP_ENABLED);
      return;
    }
    logger.debug("Apollo bootstrap config is enabled for context {}", context);

    initialize(environment);
  }


  /**
   * Initialize Apollo Configurations Just after environment is ready.
   *
   * @param environment
   */
  protected void initialize(ConfigurableEnvironment environment) {
    // 忽略，若已经有 APOLLO_BOOTSTRAP_PROPERTY_SOURCE_NAME 的 PropertySource
    if (environment.getPropertySources().contains(PropertySourcesConstants.APOLLO_BOOTSTRAP_PROPERTY_SOURCE_NAME)) {
      //already initialized, replay the logs that were printed before the logging system was initialized
      DeferredLogger.replayTo();
      return;
    }
    // 获得 "apollo.bootstrap.namespaces" 配置项
    String namespaces = environment.getProperty(PropertySourcesConstants.APOLLO_BOOTSTRAP_NAMESPACES, ConfigConsts.NAMESPACE_APPLICATION);
    logger.debug("Apollo bootstrap namespaces: {}", namespaces);
    List<String> namespaceList = NAMESPACE_SPLITTER.splitToList(namespaces);
    // 按照优先级，顺序遍历 Namespace
    CompositePropertySource composite;
    final ConfigUtil configUtil = ApolloInjector.getInstance(ConfigUtil.class);
    if (configUtil.isPropertyNamesCacheEnabled()) {
      composite = new CachedCompositePropertySource(PropertySourcesConstants.APOLLO_BOOTSTRAP_PROPERTY_SOURCE_NAME);
    } else {
      composite = new CompositePropertySource(PropertySourcesConstants.APOLLO_BOOTSTRAP_PROPERTY_SOURCE_NAME);
    }
    for (String namespace : namespaceList) {
      Config config = ConfigService.getConfig(namespace); // 创建 Apollo Config 对象
      // 创建 Namespace 对应的 ConfigPropertySource 对象，添加到 composite 中。
      composite.addPropertySource(configPropertySourceFactory.getConfigPropertySource(namespace, config));
    }
    // 添加到 environment 中，且优先级最高
    environment.getPropertySources().addFirst(composite);
  }

  /**
   * To fill system properties from environment config
   */
  void initializeSystemProperty(ConfigurableEnvironment environment) {
    for (String propertyName : APOLLO_SYSTEM_PROPERTIES) {
      fillSystemPropertyFromEnvironment(environment, propertyName);
    }
  }

  private void fillSystemPropertyFromEnvironment(ConfigurableEnvironment environment, String propertyName) {
    if (System.getProperty(propertyName) != null) {
      return;
    }

    String propertyValue = environment.getProperty(propertyName);

    if (Strings.isNullOrEmpty(propertyValue)) {
      return;
    }

    System.setProperty(propertyName, propertyValue);
  }

  /**
   *
   * In order to load Apollo configurations as early as even before Spring loading logging system phase,
   * this EnvironmentPostProcessor can be called Just After ConfigFileApplicationListener has succeeded.
   *
   * <br />
   * The processing sequence would be like this: <br />
   * Load Bootstrap properties and application properties -----> load Apollo configuration properties ----> Initialize Logging systems
   *
   * @param configurableEnvironment
   * @param springApplication
   */
  @Override
  public void postProcessEnvironment(ConfigurableEnvironment configurableEnvironment, SpringApplication springApplication) {

    // should always initialize system properties like app.id in the first place
    initializeSystemProperty(configurableEnvironment);

    Boolean eagerLoadEnabled = configurableEnvironment.getProperty(PropertySourcesConstants.APOLLO_BOOTSTRAP_EAGER_LOAD_ENABLED, Boolean.class, false);

    //EnvironmentPostProcessor should not be triggered if you don't want Apollo Loading before Logging System Initialization
    if (!eagerLoadEnabled) {
      return;
    }

    Boolean bootstrapEnabled = configurableEnvironment.getProperty(PropertySourcesConstants.APOLLO_BOOTSTRAP_ENABLED, Boolean.class, false);

    if (bootstrapEnabled) {
      DeferredLogger.enable();
      initialize(configurableEnvironment);
    }

  }

  /**
   * @since 1.3.0
   */
  @Override
  public int getOrder() {
    return order;
  }

  /**
   * @since 1.3.0
   */
  public void setOrder(int order) {
    this.order = order;
  }
}
```

- `#initialize(ConfigurableApplicationContext context)`方法。
  - 第 12 行：获得 `"apollo.bootstrap.enabled"` 配置项。
  - 第 13 至 18 行：**忽略**，若未配置开启。
  - 第 20 至 24 行：**忽略**，若已经有 *APOLLO_BOOTSTRAP_PROPERTY_SOURCE_NAME* 的 PropertySource 对象。
  - 第 26 至 29 行：获得 `"apollo.bootstrap.namespaces"` 配置项。
  - 第 31 至 33 行：按照顺序遍历 Namespace 。
    - 第 35 行：调用 `ConfigService#getConfig(namespace)` 方法，获得( *创建* ) Apollo Config 对象。这个地方，非常关键。
    - 第 38 行：调用 `ConfigPropertySourceFactory#getConfigPropertySource(namespace, config)` 方法，创建 Namespace **对应的** ConfigPropertySource 对象。
    - 第 38 行：调用 `CompositePropertySource#addPropertySource(PropertySource)` 方法，添加到 `composite` 中。通过这样的方式，形成**顺序的优先级**。
    - 第 42 行：添加 `composite` 到 `environment` 中。这样，我们从 `environment` 里，**且优先级最高**。




# 参考

[Apollo 源码解析 —— 客户端配置 Spring 集成（三）之外部化配置](https://www.iocoder.cn/Apollo/client-config-spring-3/)
