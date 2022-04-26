# . 概述

> 老艿艿：本系列假定胖友已经阅读过 [《Apollo 官方 wiki 文档》](https://github.com/ctripcorp/apollo/wiki/) ，特别是 [《Spring 整合方式》](https://github.com/ctripcorp/apollo/wiki/Java客户端使用指南#32-spring整合方式) 。
>
> 😁 因为 Spring 仅仅处于入门水平，所以可能一些地方，表述的灰常业余。

从本文开始，我们来看看 Apollo 客户端的配置，是如何和 Spring 集成的。笔者会分成三篇文章，分别是：

- XML 配置 【本文】
- 注解配置
- 外部化配置

其中，注解配置会包含 *Java Config* ，实在不好拆分 😓 。推荐一篇有趣的文章，[《用小说的形式讲解Spring（3） —— xml、注解和Java Config到底选哪个》](https://zhuanlan.zhihu.com/p/29938139) 。

------

**本文分享 Spring XML 配置的集成**，包括两方面：

- Apollo Config 集成到 Spring PropertySource 体系中。
- **自动更新** Spring Placeholder Values ，参见 [PR #972](https://github.com/ctripcorp/apollo/pull/972) 。

Apollo XML 配置，自定义 `<apollo: />` 标签，基于 Spring XML 进行解析。如果不了解的胖友，可以查看如下文档：

- [《Spring 源码阅读 —— XML 文件默认标签的解析》](https://gavinzhang1.gitbooks.io/spring/content/xmlwen_jian_mo_ren_biao_qian_de_jie_xi.html)
- [《Spring 源码阅读 —— XML 自定义标签的解析》](https://gavinzhang1.gitbooks.io/spring/content/xmlzi_ding_yi_biao_qian_de_jie_xi.html)

# 2. 定义

## 2.1 spring.schemas

Apollo 在 `apollo-client` 的 [`META-INF/spring.schemas`](https://github.com/YunaiV/apollo/blob/2907eebd618825f32b8e27586cb521bcd0221a7e/apollo-client/src/main/resources/META-INF/spring.schemas) 定义如下：

```properties
http\://www.ctrip.com/schema/apollo-1.0.0.xsd=/META-INF/apollo-1.0.0.xsd
http\://www.ctrip.com/schema/apollo.xsd=/META-INF/apollo-1.0.0.xsd
```

- `xmlns` 为 `http://code.alibabatech.com/schema/dubbo/dubbo.xsd` 或 `http://code.alibabatech.com/schema/dubbo/dubbo-1.0.0.xsd` 。
- `xsd` 为 `META-INF/apollo-1.0.0.xsd` 。

## 2.2 apollo-1.0.0.xsd

[`apollo-1.0.0.xsd`](https://github.com/YunaiV/apollo/blob/2907eebd618825f32b8e27586cb521bcd0221a7e/apollo-client/src/main/resources/META-INF/apollo-1.0.0.xsd) 定义如下：

```java
<?xml version="1.0" encoding="UTF-8" standalone="no"?>
<!--
  ~ Copyright 2022 Apollo Authors
  ~
  ~ Licensed under the Apache License, Version 2.0 (the "License");
  ~ you may not use this file except in compliance with the License.
  ~ You may obtain a copy of the License at
  ~
  ~ http://www.apache.org/licenses/LICENSE-2.0
  ~
  ~ Unless required by applicable law or agreed to in writing, software
  ~ distributed under the License is distributed on an "AS IS" BASIS,
  ~ WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
  ~ See the License for the specific language governing permissions and
  ~ limitations under the License.
  ~
-->
<xsd:schema xmlns="http://www.ctrip.com/schema/apollo"
            xmlns:xsd="http://www.w3.org/2001/XMLSchema"
            targetNamespace="http://www.ctrip.com/schema/apollo"
            elementFormDefault="qualified"
            attributeFormDefault="unqualified">

    <xsd:annotation>
        <xsd:documentation><![CDATA[ Namespace support for Ctrip Apollo Configuration Center. ]]></xsd:documentation>
    </xsd:annotation>

    <xsd:element name="config">
        <xsd:annotation>
            <xsd:documentation>
                <![CDATA[ Apollo configuration section to integrate with Spring.]]>
            </xsd:documentation>
        </xsd:annotation>
        <xsd:complexType>
            <xsd:attribute name="namespaces" type="xsd:string" use="optional">
                <xsd:annotation>
                    <xsd:documentation>
                        <![CDATA[
                            The comma-separated list of namespace names to integrate with Spring property sources.
                            If not specified, then default to application namespace.
                        ]]>
                    </xsd:documentation>
                </xsd:annotation>
            </xsd:attribute>
            <xsd:attribute name="order" type="xsd:int" use="optional">
                <xsd:annotation>
                    <xsd:documentation>
                        <![CDATA[
                            The order of the config, default to Ordered.LOWEST_PRECEDENCE, which is Integer.MAX_VALUE.
                            If there are properties with the same name in different apollo configs, the config with smaller order wins.
                        ]]>
                    </xsd:documentation>
                </xsd:annotation>
            </xsd:attribute>
        </xsd:complexType>
    </xsd:element>
</xsd:schema>
```

定义了 `<apollo:config />` 标签，可对应**多个** Config 对象。

- `namespaces` 属性，Namespace 名字的**数组**，这就是为什么说“多个”的原因。
- `order` 属性，多个 Namespace 可能存在多个**相同属性名**的属性，应用程序在使用属性时，是**不知道** Namespace 的存在的，所以需要通过 `order` 来判断优先级。`order` 越小，优先级越高。

## 2.3 spring.handlers

[`spring.handlers`](https://github.com/YunaiV/apollo/blob/2907eebd618825f32b8e27586cb521bcd0221a7e/apollo-client/src/main/resources/META-INF/spring.handlers) 定义如下：

```properties
http\://www.ctrip.com/schema/apollo=com.ctrip.framework.apollo.spring.config.NamespaceHandler
```

- 定义了 Apollo 的 XML Namespace 的处理器 NamespaceHandler 。

## 2.4 NamespaceHandler

`com.ctrip.framework.apollo.spring.config.NamespaceHandler` ，实现 `org.springframework.beans.factory.xml.NamespaceHandlerSupport` **抽象类**，Apollo 的 XML Namespace 的处理器。代码如下

```java
public class NamespaceHandler extends NamespaceHandlerSupport {

  private static final Splitter NAMESPACE_SPLITTER = Splitter.on(",").omitEmptyStrings()
      .trimResults();

  @Override
  public void init() {
    registerBeanDefinitionParser("config", new BeanParser());
  }

  static class BeanParser extends AbstractSingleBeanDefinitionParser {

    @Override
    protected Class<?> getBeanClass(Element element) {
      return ConfigPropertySourcesProcessor.class;
    }

    @Override
    protected boolean shouldGenerateId() {
      return true;
    }

    private String resolveNamespaces(Element element) {
      String namespaces = element.getAttribute("namespaces");
      if (Strings.isNullOrEmpty(namespaces)) {
        //default to application
        return ConfigConsts.NAMESPACE_APPLICATION;
      }
      return SystemPropertyUtils.resolvePlaceholders(namespaces);
    }

    @Override
    protected void doParse(Element element, BeanDefinitionBuilder builder) {
      String namespaces = this.resolveNamespaces(element); // 解析 namespaces 属性，默认为 "application"

      int order = Ordered.LOWEST_PRECEDENCE;
      String orderAttribute = element.getAttribute("order"); // 解析 order 属性，默认为 Ordered.LOWEST_PRECEDENCE

      if (!Strings.isNullOrEmpty(orderAttribute)) {
        try {
          order = Integer.parseInt(orderAttribute);
        } catch (Throwable ex) {
          throw new IllegalArgumentException(
              String.format("Invalid order: %s for namespaces: %s", orderAttribute, namespaces));
        }
      }
      PropertySourcesProcessor.addNamespaces(NAMESPACE_SPLITTER.splitToList(namespaces), order); // 添加到 PropertySourcesProcessor
    }
  }
}
```

- `#getBeanClass(Element)` 方法，返回 **Bean** 对应的类为 ConfigPropertySourcesProcessor。详细解析，见 [「4. ConfigPropertySourcesProcessor」](https://www.iocoder.cn/Apollo/client-config-spring-1/#) 。
- `#doParse(Element, BeanDefinitionBuilder)`方法，解析 XML 配置。
  - 解析 `namespaces` 和 `order` 属性。
  - 调用 `PropertySourcesProcessor#addNamespaces(namespaces, order)` 方法，添加到 PropertySourcesProcessor 中。什么用？我们接着往下看。

# 3. PropertySourcesProcessor

`com.ctrip.framework.apollo.spring.config.PropertySourcesProcessor` ，实现 BeanFactoryPostProcessor、EnvironmentAware、PriorityOrdered 接口，PropertySource 处理器。

> The reason why PropertySourcesProcessor implements **BeanFactoryPostProcessor** instead of `org.springframework.beans.factory.support.BeanDefinitionRegistryPostProcessor` is that lower versions of Spring (e.g. 3.1.1) doesn’t support registering BeanDefinitionRegistryPostProcessor in ImportBeanDefinitionRegistrar - `com.ctrip.framework.apollo.spring.annotation.ApolloConfigRegistrar` 。

## 3.1 构造方法

```java
public class PropertySourcesProcessor implements BeanFactoryPostProcessor, EnvironmentAware, PriorityOrdered {
  private static final Multimap<Integer, String> NAMESPACE_NAMES = LinkedHashMultimap.create(); // Namespace 名字集合。KEY：优先级。VALUE：Namespace 名字集合
  private static final Set<BeanFactory> AUTO_UPDATE_INITIALIZED_BEAN_FACTORIES = Sets.newConcurrentHashSet();

  private final ConfigPropertySourceFactory configPropertySourceFactory = SpringInjector
      .getInstance(ConfigPropertySourceFactory.class);
  private ConfigUtil configUtil;
  private ConfigurableEnvironment environment; // Spring ConfigurableEnvironment 对象
  
  // ... 省略其他接口和属性
}
```

- `NAMESPACE_NAMES` **静态**属性，Namespace 名字集合。Apollo 在解析到的 **XML 或注解**配置的 Apollo Namespace 时，会调用 `#addNamespaces(namespaces, order)` 方法，添加到其中。代码如下：

  ```java
  public static boolean addNamespaces(Collection<String> namespaces, int order) {
      return NAMESPACE_NAMES.putAll(order, namespaces);
  }
  ```

- `environment` 属性，Spring ConfigurableEnvironment 对象，通过它，可以获取到应用实例中，**所有的配置属性信息**。通过 `#setEnvironment(Environment)` 方法，注入。代码如下：

  ```java
  @Override
  public void setEnvironment(Environment environment) {
      //it is safe enough to cast as all known environment is derived from ConfigurableEnvironment
      this.environment = (ConfigurableEnvironment) environment;
  }
  ```

- `configPropertySourceFactory` 属性，ConfigPropertySource **工厂**。在 `NAMESPACE_NAMES` 中的每一个 Namespace ，都会创建成**对应**的 ConfigPropertySource 对象( *基于 Apollo Config 的 PropertySource 实现类* )，并添加到 `environment` 中。**重点**：通过这样的方式，Spring 的 `<property name="" value="" />` 和 `@Value` 注解，就可以从 `environment` 中，**直接**读取到对应的**属性值**。

胖友，先跳到 [「5. ConfigPropertySource」](https://www.iocoder.cn/Apollo/client-config-spring-1/#) ，理解了 ConfigPropertySource 属性源，在回过头继续往下看。

## 3.2 postProcessBeanFactory

> 实现 BeanFactoryPostProcessor 接口，可以在 spring 的 **bean 创建之前**，修改 bean 的定义属性。也就是说，Spring 允许 BeanFactoryPostProcessor 在容器实例化任何其它bean 之前读取配置元数据，并可以根据需要进行修改，例如可以把 bean 的 `scope` 从 singleton 改为 prototype ，也可以把 `property` 的值给修改掉。可以同时配置多个BeanFactoryPostProcessor ，并通过设置 `order` 属性来控制各个BeanFactoryPostProcessor 的**执行次序**。
>
> **注意：BeanFactoryPostProcessor 是在 spring 容器加载了 bean 的定义文件之后，在 bean 实例化之前执行的**。

`#postProcessBeanFactory(ConfigurableListableBeanFactory)` 方法，代码如下：

```java
@Override
public void postProcessBeanFactory(ConfigurableListableBeanFactory beanFactory) throws BeansException {
  this.configUtil = ApolloInjector.getInstance(ConfigUtil.class);
  initializePropertySources(); // 初始化 PropertySource 们
  initializeAutoUpdatePropertiesFeature(beanFactory); // 初始化 AutoUpdateConfigChangeListener 对象，实现属性的自动更新
}
```

- 调用 `#initializePropertySources()` 方法，初始化 PropertySource 们。代码如下：

  ```java
  private void initializePropertySources() {
    if (environment.getPropertySources().contains(PropertySourcesConstants.APOLLO_PROPERTY_SOURCE_NAME)) {
      //already initialized  // 若 environment 已经有 APOLLO_PROPERTY_SOURCE_NAME 属性源，说明已经初始化，直接返回。
      return;
    }
    CompositePropertySource composite; // 创建 CompositePropertySource 对象，组合多个 Namespace 的 ConfigPropertySource
    if (configUtil.isPropertyNamesCacheEnabled()) {
      composite = new CachedCompositePropertySource(PropertySourcesConstants.APOLLO_PROPERTY_SOURCE_NAME);
    } else {
      composite = new CompositePropertySource(PropertySourcesConstants.APOLLO_PROPERTY_SOURCE_NAME);
    }
  
    //sort by order asc // 按照优先级，顺序遍历 Namespace
    ImmutableSortedSet<Integer> orders = ImmutableSortedSet.copyOf(NAMESPACE_NAMES.keySet());
    Iterator<Integer> iterator = orders.iterator();
  
    while (iterator.hasNext()) {
      int order = iterator.next();
      for (String namespace : NAMESPACE_NAMES.get(order)) {
        Config config = ConfigService.getConfig(namespace);  // 创建 Apollo Config 对象
        // 创建 Namespace 对应的 ConfigPropertySource 对象添加到 composite 中
        composite.addPropertySource(configPropertySourceFactory.getConfigPropertySource(namespace, config));
      }
    }
  
    // clean up
    NAMESPACE_NAMES.clear();
    // 若有 APOLLO_BOOTSTRAP_PROPERTY_SOURCE_NAME 属性源，添加到其后
    // add after the bootstrap property source or to the first
    if (environment.getPropertySources()
        .contains(PropertySourcesConstants.APOLLO_BOOTSTRAP_PROPERTY_SOURCE_NAME)) {
  
      // ensure ApolloBootstrapPropertySources is still the first
      ensureBootstrapPropertyPrecedence(environment);
  
      environment.getPropertySources()
          .addAfter(PropertySourcesConstants.APOLLO_BOOTSTRAP_PROPERTY_SOURCE_NAME, composite);
    } else { // 若没 APOLLO_BOOTSTRAP_PROPERTY_SOURCE_NAME 属性源，添加到首个
      environment.getPropertySources().addFirst(composite);
    }
  }
  ```

  - 第 2 至 6 行：`environment` 已经有 APOLLO_PROPERTY_SOURCE_NAME 属性源，说明**已经初始化**，直接返回。**本方法初始化的就是 APOLLO_PROPERTY_SOURCE_NAME 属性源**。

  - 第 8 行：创建 CompositePropertySource 对象，**组合**多个 Namespace 的 ConfigPropertySource 。

  - 第 9 至 13 行：按照**优先级**，顺序遍历 Namespace 。

    - 第 15 行：调用 `ConfigService#getConfig(namespace)` 方法，获得( *创建* ) Apollo Config 对象。这个地方，非常关键。
    - 第 18 行：调用 `ConfigPropertySourceFactory#getConfigPropertySource(namespace, config)` 方法，创建 Namespace **对应的** ConfigPropertySource 对象。
    - 第 18 行：调用 `CompositePropertySource#addPropertySource(PropertySource)` 方法，添加到 `composite` 中。通过这样的方式，形成**顺序的优先级**。

  - 第 22 至 29 行：添加`composite`到`environment`中。这样，我们从`environment`里，可以读取到 Apollo Config 的配置。🙂

    属性源的优先级为：**APOLLO_BOOTSTRAP_PROPERTY_SOURCE_NAME** > **APOLLO_PROPERTY_SOURCE_NAME** > 其他。APOLLO_BOOTSTRAP_PROPERTY_SOURCE_NAME 是外部化配置产生的 PropertySource 对象，优先级最高。

    - 😏 *至此，Apollo Config 集成到 Spring XML 的 Bean 的属性，可以说已经完成了。如果不考虑，我们下面继续分享的**自动更新**功能*。

- 调用 `#initializeAutoUpdatePropertiesFeature(ConfigurableListableBeanFactory)` 方法，初始化 AutoUpdateConfigChangeListener 对象，实现 Spring Placeholder 的**自动更新**功能。代码如下：

  ```java
  private void initializeAutoUpdatePropertiesFeature(ConfigurableListableBeanFactory beanFactory) {
    if (!configUtil.isAutoUpdateInjectedSpringPropertiesEnabled() ||
        !AUTO_UPDATE_INITIALIZED_BEAN_FACTORIES.add(beanFactory)) { // 若未开启属性的自动更新功能，直接返回
      return;
    }
    // 创建 AutoUpdateConfigChangeListener 对象
    AutoUpdateConfigChangeListener autoUpdateConfigChangeListener = new AutoUpdateConfigChangeListener(
        environment, beanFactory);
    // 循环，向 ConfigPropertySource 注册配置变更器
    List<ConfigPropertySource> configPropertySources = configPropertySourceFactory.getAllConfigPropertySources();
    for (ConfigPropertySource configPropertySource : configPropertySources) {
      configPropertySource.addChangeListener(autoUpdateConfigChangeListener);
    }
  }
  ```

  - 调用 `ConfigUtil#isAutoUpdateInjectedSpringPropertiesEnabled()` 方法，判断Spring Placeholder 的**自动更新**的功能是否开启。代码如下：

    ```java
    private boolean autoUpdateInjectedSpringProperties = true;
    
    private void initAutoUpdateInjectedSpringProperties() {
        // 1. Get from System Property
        String enableAutoUpdate = System.getProperty("apollo.autoUpdateInjectedSpringProperties");
        if (Strings.isNullOrEmpty(enableAutoUpdate)) {
            // 2. Get from app.properties
            enableAutoUpdate = Foundation.app().getProperty("apollo.autoUpdateInjectedSpringProperties", null);
        }
        if (!Strings.isNullOrEmpty(enableAutoUpdate)) {
            autoUpdateInjectedSpringProperties = Boolean.parseBoolean(enableAutoUpdate.trim());
        }
    }
    ```

    - 默认**开启**，可通过 `-Dapollo.autoUpdateInjectedSpringProperties=false` 或者在 `app.properties` 中设置 `apollo.autoUpdateInjectedSpringProperties=false` 进行**关闭**。

  - 创建 AutoUpdateConfigChangeListener 对象，并**循环**，向 ConfigPropertySource **注册**为配置变更监听器，从而实现 Apollo Config 配置变更的监听。详细解析，见 [「9. AutoUpdateConfigChangeListener」](https://www.iocoder.cn/Apollo/client-config-spring-1/#) 。

## 3.3 getOrder

```java
@Override
public int getOrder() {
    // make it as early as possible
    return Ordered.HIGHEST_PRECEDENCE; // 最高优先级
}
```

# 4. ConfigPropertySourcesProcessor

`com.ctrip.framework.apollo.spring.config.ConfigPropertySourcesProcessor` ，实现 BeanDefinitionRegistryPostProcessor 接口，继承 [「3. PropertySourcesProcessor」](https://www.iocoder.cn/Apollo/client-config-spring-1/#) 类，Apollo PropertySource 处理器。

```java
public class ConfigPropertySourcesProcessor extends PropertySourcesProcessor
    implements BeanDefinitionRegistryPostProcessor {

  private ConfigPropertySourcesProcessorHelper helper = ServiceBootstrap.loadPrimary(ConfigPropertySourcesProcessorHelper.class);

  @Override
  public void postProcessBeanDefinitionRegistry(BeanDefinitionRegistry registry) throws BeansException {
    helper.postProcessBeanDefinitionRegistry(registry);
  }
}
```

> Apollo Property Sources processor for Spring XML Based Application

- 用于处理 Spring **XML** 的配置。

## 4.1 postProcessBeanDefinitionRegistry

```java
public interface ConfigPropertySourcesProcessorHelper extends Ordered {

  void postProcessBeanDefinitionRegistry(BeanDefinitionRegistry registry) throws BeansException;
}

@Override
public void postProcessBeanDefinitionRegistry(BeanDefinitionRegistry registry) throws BeansException {
    // 注册 PropertySourcesPlaceholderConfigurer 到 BeanDefinitionRegistry 中，替换 PlaceHolder 为对应的属性值，参考文章 https://leokongwq.github.io/2016/12/28/spring-PropertyPlaceholderConfigurer.html
    BeanRegistrationUtil.registerBeanDefinitionIfNotExists(registry, PropertySourcesPlaceholderConfigurer.class.getName(), PropertySourcesPlaceholderConfigurer.class);
    // 注册 ApolloAnnotationProcessor 到 BeanDefinitionRegistry 中，因为 XML 配置的 Bean 对象，也可能存在 @ApolloConfig 和 @ApolloConfigChangeListener 注解。
    BeanRegistrationUtil.registerBeanDefinitionIfNotExists(registry, ApolloAnnotationProcessor.class.getName(), ApolloAnnotationProcessor.class);
    // 注册 SpringValueProcessor 到 BeanDefinitionRegistry 中，用于 PlaceHolder 自动更新机制
    BeanRegistrationUtil.registerBeanDefinitionIfNotExists(registry, SpringValueProcessor.class.getName(), SpringValueProcessor.class);
    // 注册 ApolloJsonValueProcessor 到 BeanDefinitionRegistry 中，因为 XML 配置的 Bean 对象，也可能存在 @ApolloJsonValue 注解。
    BeanRegistrationUtil.registerBeanDefinitionIfNotExists(registry, ApolloJsonValueProcessor.class.getName(), ApolloJsonValueProcessor.class);

    // 处理 XML 配置的 Spring PlaceHolder
    processSpringValueDefinition(registry);
}
```

- 调用 `BeanRegistrationUtil#registerBeanDefinitionIfNotExists(registry, beanName, beanClass)` 方法，**注册** `beanClass` 到 BeanDefinitionRegistry 中，**当且仅当** `beanName` 和 `beanClass` **都不存在**对应的 BeanDefinition 时。代码如下：

  ```java
  public static boolean registerBeanDefinitionIfNotExists(BeanDefinitionRegistry registry, String beanName,
                                                          Class<?> beanClass, Map<String, Object> extraPropertyValues) {
    if (registry.containsBeanDefinition(beanName)) {  // 不存在 beanName 对应的 BeanDefinition
      return false;
    }
    // 不存在 beanClass 对应的 BeanDefinition
    String[] candidates = registry.getBeanDefinitionNames();
  
    String reservedBeanDefinition = RESERVED_BEAN_DEFINITIONS.get(beanClass.getName());
    for (String candidate : candidates) {
      BeanDefinition beanDefinition = registry.getBeanDefinition(candidate);
      if (Objects.equals(beanDefinition.getBeanClassName(), beanClass.getName())) {
        return false;
      }
  
      if (reservedBeanDefinition != null && beanDefinition.getSource() != null && beanDefinition.getSource() instanceof MethodMetadata) {
        MethodMetadata metadata = (MethodMetadata) beanDefinition.getSource();
        if (Objects.equals(reservedBeanDefinition, String.format("%s#%s", metadata.getDeclaringClassName(), metadata.getMethodName()))) {
          return false;
        }
      }
    }
    // 注册 beanClass 到 BeanDefinitionRegistry 中
    BeanDefinition beanDefinition = BeanDefinitionBuilder.genericBeanDefinition(beanClass).getBeanDefinition();
  
    if (extraPropertyValues != null) {
      for (Map.Entry<String, Object> entry : extraPropertyValues.entrySet()) {
        beanDefinition.getPropertyValues().add(entry.getKey(), entry.getValue());
      }
    }
  
    registry.registerBeanDefinition(beanName, beanDefinition);
  
    return true;
  }
  ```

- 注册 **PropertySourcesPlaceholderConfigurer** 到 BeanDefinitionRegistry 中，替换 PlaceHolder 为对应的属性值，参考文章 [《Spring 扩展点之 PropertyPlaceholderConfigurer》](https://leokongwq.github.io/2016/12/28/spring-PropertyPlaceholderConfigurer.html) 。

- 注册 **ApolloAnnotationProcessor** 到 BeanDefinitionRegistry 中，因为 XML 配置的 Bean 对象，也可能存在 `@ApolloConfig` 和 `@ApolloConfigChangeListener` 注解。详细解析，见 [《Apollo 源码解析 —— 客户端配置 Spring 集成（一）之注解配置》](http://www.iocoder.cn/Apollo/client-config-spring-2?slef) 。

- 注册 **SpringValueProcessor** 到 BeanDefinitionRegistry 中，用于 PlaceHolder **自动更新**机制。详细解析，见 [「7.1 SpringValueProcessor」](https://www.iocoder.cn/Apollo/client-config-spring-1/#) 。

- ========== 分割线 ==========

- 调用 `#processSpringValueDefinition(BeanDefinitionRegistry)` 方法，处理 XML 配置的 Spring PlaceHolder 。这块的目的，也是用于 PlaceHolder **自动更新**机制。

------

！！！划重点！！！

🙂 Apollo 为了实现**自动更新**机制，做了很多处理，**重点在于找到 XML 和注解配置的 PlaceHolder**，全部以 *StringValue* 的形式，注册到 *SpringValueRegistry* 中，从而让 AutoUpdateConfigChangeListener **监听**到 Apollo 配置变更后，能够从 *SpringValueRegistry* 中找到发生属性值变更的属性对应的 *StringValue* ，**进行修改**。😈 相对复杂，其实也非常好理解，胖友看完所有的代码之后，可以在回味思考下。

## 4.2 processSpringValueDefinition

```java
private void processSpringValueDefinition(BeanDefinitionRegistry registry) {
    // 创建 SpringValueDefinitionProcessor 对象
    SpringValueDefinitionProcessor springValueDefinitionProcessor = new SpringValueDefinitionProcessor();
    // 处理 XML 配置的 Spring PlaceHolder
    springValueDefinitionProcessor.postProcessBeanDefinitionRegistry(registry);
}
```

- SpringValueDefinitionProcessor 的详细解析，见 [「6. SpringValueDefinitionProcessor」](https://www.iocoder.cn/Apollo/client-config-spring-1/#) 中。

- 该方法上有注释如下：

  ```
  /**
   * For Spring 3.x versions, the BeanDefinitionRegistryPostProcessor would not be
   * instantiated if it is added in postProcessBeanDefinitionRegistry phase, so we have to manually
   * call the postProcessBeanDefinitionRegistry method of SpringValueDefinitionProcessor here...
   */
  ```

  - 在 Spring 3.x 版本中，BeanDefinitionRegistryPostProcessor ( *SpringValueDefinitionProcessor 实现了该接口* )无法被实例化，在 **postProcessBeanDefinitionRegistry** 阶段，因此，我们不得不手动创建 SpringValueDefinitionProcessor 对象，并调用其 `#postProcessBeanDefinitionRegistry(BeanDefinitionRegistry)` 方法。
  - 🙂 哈哈哈，不是很理解 Spring 的 Bean 的初始化的生命周期，所以胖友需要自己在查查。

# 5. ConfigPropertySource

`com.ctrip.framework.apollo.spring.config.ConfigPropertySource` ，实现 `org.springframework.core.env.ConfigPropertySource` 抽象类，基于 **Apollo Config** 的 PropertySource 实现类。代码如下：

```java
public class ConfigPropertySource extends EnumerablePropertySource<Config> {
  private static final String[] EMPTY_ARRAY = new String[0];

  ConfigPropertySource(String name, Config source) {  // 此处的 Apollo Config 作为 source
    super(name, source);
  }

  @Override
  public boolean containsProperty(String name) {
    return this.source.getProperty(name, null) != null;
  }

  @Override
  public String[] getPropertyNames() {
    Set<String> propertyNames = this.source.getPropertyNames(); // 从 Config 中，获得属性名集合
    if (propertyNames.isEmpty()) {
      return EMPTY_ARRAY;
    }
    return propertyNames.toArray(new String[propertyNames.size()]); // 转换成 String 数组，返回
  }

  @Override
  public Object getProperty(String name) {
    return this.source.getProperty(name, null);
  }
  // 添加 ConfigChangeListener 到 Config 中
  public void addChangeListener(ConfigChangeListener listener) {
    this.source.addChangeListener(listener);
  }
}
```

- 简单的将 Apollo Config 的方法，进行封装。

## 5.1 ConfigPropertySourceFactory

`com.ctrip.framework.apollo.spring.config.ConfigPropertySourceFactory` ，ConfigPropertySource **工厂**。代码如下：

```java
public class ConfigPropertySourceFactory {
  // ConfigPropertySource 数组
  private final List<ConfigPropertySource> configPropertySources = Lists.newLinkedList();
  // 创建 ConfigPropertySource 对象
  public ConfigPropertySource getConfigPropertySource(String name, Config source) {
    ConfigPropertySource configPropertySource = new ConfigPropertySource(name, source); // 创建 ConfigPropertySource 对象
    // 添加到数组中
    configPropertySources.add(configPropertySource);

    return configPropertySource;
  }

  public List<ConfigPropertySource> getAllConfigPropertySources() {
    return Lists.newLinkedList(configPropertySources);
  }
}
```

# 6. SpringValueDefinitionProcessor

`com.ctrip.framework.apollo.spring.property.SpringValueDefinitionProcessor` ，实现 BeanDefinitionRegistryPostProcessor 接口，处理 Spring XML **PlaceHolder** ，解析成 StringValueDefinition **集合**。例如：

```xml
<bean class="com.ctrip.framework.apollo.demo.spring.xmlConfigDemo.bean.XmlBean">
    <property name="timeout" value="${timeout:200}"/>
    <property name="batch" value="${batch:100}"/>
</bean>
```

- **每个** `<property />` 都会被解析成**一个** StringValueDefinition 对象。关于 StringValueDefinition ，胖友先跳到 [「8.1 StringValueDefinition」](https://www.iocoder.cn/Apollo/client-config-spring-1/#) 。
- 对应关系如下图：![对应关系](http://blog-1259650185.cosbj.myqcloud.com/img/202204/09/1649504504.png)

## 6.1 构造方法

```java
public class SpringValueDefinitionProcessor implements BeanDefinitionRegistryPostProcessor {
  private static final Map<BeanDefinitionRegistry, Multimap<String, SpringValueDefinition>> beanName2SpringValueDefinitions =
      Maps.newConcurrentMap(); // SpringValueDefinition 集合。KEY1：BeanDefinitionRegistry。KEY2：beanName。VALUE：SpringValueDefinition 集合
  private static final Set<BeanDefinitionRegistry> PROPERTY_VALUES_PROCESSED_BEAN_FACTORIES = Sets.newConcurrentHashSet();

  private final ConfigUtil configUtil;
  private final PlaceholderHelper placeholderHelper;

  public SpringValueDefinitionProcessor() {
    configUtil = ApolloInjector.getInstance(ConfigUtil.class);
    placeholderHelper = SpringInjector.getInstance(PlaceholderHelper.class);
  }
  
  // ... 省略其他接口和属性
}
```

- `beanName2SpringValueDefinitions` **静态**字段，SpringValueDefinition 集合。其中，KEY 为 `beanName` ，VALUE 为 SpringValueDefinition 集合。

## 6.2 postProcessBeanDefinitionRegistry

```java
@Override
public void postProcessBeanDefinitionRegistry(BeanDefinitionRegistry registry) throws BeansException {
    // 是否开启自动更新功能，因为 SpringValueDefinitionProcessor 就是为了这个功能编写的。
    if (configUtil.isAutoUpdateInjectedSpringPropertiesEnabled()) {
        processPropertyValues(registry);
    }
}

private void processPropertyValues(BeanDefinitionRegistry beanRegistry) {
  if (!PROPERTY_VALUES_PROCESSED_BEAN_FACTORIES.add(beanRegistry)) { // 若已经初始化，直接返回
    // already initialized
    return;
  }

  if (!beanName2SpringValueDefinitions.containsKey(beanRegistry)) {
    beanName2SpringValueDefinitions.put(beanRegistry, LinkedListMultimap.<String, SpringValueDefinition>create());
  }
  // 循环 BeanDefinition 集合
  Multimap<String, SpringValueDefinition> springValueDefinitions = beanName2SpringValueDefinitions.get(beanRegistry);

  String[] beanNames = beanRegistry.getBeanDefinitionNames();
  for (String beanName : beanNames) {
    BeanDefinition beanDefinition = beanRegistry.getBeanDefinition(beanName);
    MutablePropertyValues mutablePropertyValues = beanDefinition.getPropertyValues();
    List<PropertyValue> propertyValues = mutablePropertyValues.getPropertyValueList();
    for (PropertyValue propertyValue : propertyValues) { // 循环 BeanDefinition 的 PropertyValue 数组
      Object value = propertyValue.getValue(); // 获得 value 属性
      if (!(value instanceof TypedStringValue)) {  // 忽略非 Spring PlaceHolder 的 value 属性
        continue;
      }
      String placeholder = ((TypedStringValue) value).getValue(); // 获得 placeholder 属性
      Set<String> keys = placeholderHelper.extractPlaceholderKeys(placeholder); // 提取 keys 属性们

      if (keys.isEmpty()) {
        continue;
      }
      // 循环 keys ，创建对应的 SpringValueDefinition 对象，并添加到 beanName2SpringValueDefinitions 中。
      for (String key : keys) {
        springValueDefinitions.put(beanName, new SpringValueDefinition(key, placeholder, propertyValue.getName()));
      }
    }
  }
}
```

- 代码比较简单，胖友看下注释。

- `PlaceholderHelper#extractPlaceholderKeys(placeholder)` 方法，**为什么**会提取到多个 `key` 属性呢？

  > Extract keys from placeholder, e.g.
  >
  > - `${some.key}` => “some.key”
  > - `${some.key:${some.other.key:100}}` => “some.key”, “some.other.key”
  > - `${${some.key}}` => “some.key”
  > - `${${some.key:other.key}}` => “some.key”
  > - `${${some.key}:${another.key}}` => “some.key”, “another.key”
  > - `#{new java.text.SimpleDateFormat('${some.key}').parse('${another.key}')}` => “some.key”, “another.key”

  - 具体的代码实现，感兴趣的胖友，自己研究下。

# 7. ApolloProcessor

`com.ctrip.framework.apollo.spring.annotation.ApolloProcessor` ，实现 BeanPostProcessor、PriorityOrdered 接口，Apollo 处理器**抽象类**，封装了在 **Spring Bean 初始化**之前，处理属性和方法。但是具体的处理，是两个**抽象方法**：

```java
/**
 * subclass should implement this method to process field
 */
protected abstract void processField(Object bean, String beanName, Field field);

/**
 * subclass should implement this method to process method
 */
protected abstract void processMethod(Object bean, String beanName, Method method);
```

**1. postProcessBeforeInitialization**

```java
@Override
public Object postProcessBeforeInitialization(Object bean, String beanName) throws BeansException {
    Class clazz = bean.getClass();
    // 处理所有 Field
    for (Field field : findAllField(clazz)) {
        processField(bean, beanName, field);
    }
    // 处理所有的 Method
    for (Method method : findAllMethod(clazz)) {
        processMethod(bean, beanName, method);
    }
    return bean;
}
```

- 调用 `#findAllField(Class)` 方法，获得所有 Field 。代码如下：

  ```java
  private List<Field> findAllField(Class clazz) {
      final List<Field> res = new LinkedList<>();
      ReflectionUtils.doWithFields(clazz, new ReflectionUtils.FieldCallback() {
          @Override
          public void doWith(Field field) throws IllegalArgumentException, IllegalAccessException {
              res.add(field);
          }
      });
      return res;
  }
  ```

- 调用 `#findAllMethod(Class)` 方法，获得所有 Method 。代码如下：

  ```java
  private List<Method> findAllMethod(Class clazz) {
      final List<Method> res = new LinkedList<>();
      ReflectionUtils.doWithMethods(clazz, new ReflectionUtils.MethodCallback() {
          @Override
          public void doWith(Method method) throws IllegalArgumentException, IllegalAccessException {
              res.add(method);
          }
      });
      return res;
  }
  ```

------

**2. postProcessAfterInitialization**

```java
@Override
public Object postProcessAfterInitialization(Object bean, String beanName) throws BeansException {
    return bean;
}
```

------

**3. getOrder**

```java
@Override
public int getOrder() {
    // make it as late as possible
    return Ordered.LOWEST_PRECEDENCE; // 最高优先级
}
```

------

**4. 子类**

ApolloProcessor 有两个子类实现：

- SpringValueProcessor
- ApolloAnnotationProcessor

分文仅分享第一个，SpringValueProcessor ，和本文**相关**。

## 7.1 SpringValueProcessor

`com.ctrip.framework.apollo.spring.annotation.SpringValueProcessor` ，实现 BeanFactoryPostProcessor 接口，继承 ApolloProcessor 抽象类，Spring Value 处理器，处理：

1. 带有 `@Value` **注解**的 Field 和 Method
2. **XML** 配置的 Bean 的 PlaceHolder 们

每个 Field、Method、XML PlaceHolder 被处理成一个 SpringValue 对象，添加到 SpringValueRegistry 中。
**目的**还是，为了 PlaceHolder 的**自动更新**机制。

### 7.1.1 构造方法

```java
public class SpringValueProcessor extends ApolloProcessor implements BeanFactoryPostProcessor, BeanFactoryAware {

  private static final Logger logger = LoggerFactory.getLogger(SpringValueProcessor.class);

  private final ConfigUtil configUtil;
  private final PlaceholderHelper placeholderHelper;
  private final SpringValueRegistry springValueRegistry; // SpringValueRegistry 对象

  private BeanFactory beanFactory;
  private Multimap<String, SpringValueDefinition> beanName2SpringValueDefinitions; // SpringValueDefinition 集合。KEY：beanName。VALUE：SpringValueDefinition 集合

  public SpringValueProcessor() {
    configUtil = ApolloInjector.getInstance(ConfigUtil.class);
    placeholderHelper = SpringInjector.getInstance(PlaceholderHelper.class);
    springValueRegistry = SpringInjector.getInstance(SpringValueRegistry.class);
    beanName2SpringValueDefinitions = LinkedListMultimap.create();
  }
  // ... 省略其他接口和属性
}
```

- `beanName2SpringValueDefinitions` 字段，SpringValueDefinition **集合**。通过 `#postProcessBeanFactory()` 方法，进行初始化。代码如下：

  ```java
  @Override
  public void postProcessBeanFactory(ConfigurableListableBeanFactory beanFactory)
      throws BeansException {
    if (configUtil.isAutoUpdateInjectedSpringPropertiesEnabled() && beanFactory instanceof BeanDefinitionRegistry) {  // 是否开启自动更新机制
      beanName2SpringValueDefinitions = SpringValueDefinitionProcessor
          .getBeanName2SpringValueDefinitions((BeanDefinitionRegistry) beanFactory);
    }
  }
  ```

  - 因为需要在 [「6. SpringValueDefinitionProcessor」](https://www.iocoder.cn/Apollo/client-config-spring-1/#) 的 `#postProcessBeanFactory(beanFactory)` 方法之后。

- `springValueRegistry` 字段，SpringValue 注册表。胖友先跳到 [「8. SpringValueRegistry」](https://www.iocoder.cn/Apollo/client-config-spring-1/#) ，看完在回来。

### 7.1.2 postProcessBeforeInitialization

```java
@Override
public Object postProcessBeforeInitialization(Object bean, String beanName) throws BeansException {
    // 是否开启自动更新机制
    if (configUtil.isAutoUpdateInjectedSpringPropertiesEnabled()) {
        // 处理 Field 和 Method
        super.postProcessBeforeInitialization(bean, beanName);
        // 处理 XML 配置的 Bean 的 PlaceHolder 们
        processBeanPropertyValues(bean, beanName);
    }
    return bean;
}
```

- 调用**父** `#postProcessBeforeInitialization(bean, beanName)` 方法，处理 Field 和 Method 。
- 调用 `#processBeanPropertyValues(bean, beanName)` 方法，处理 **XML** 配置的 Bean 的 PlaceHolder 们。

### 7.1.3 processField

```java
@Override
protected void processField(Object bean, String beanName, Field field) {
  // register @Value on field
  Value value = field.getAnnotation(Value.class);
  if (value == null) {
    return;
  }

  doRegister(bean, beanName, field, value);
}

private void doRegister(Object bean, String beanName, Member member, Value value) {
  Set<String> keys = placeholderHelper.extractPlaceholderKeys(value.value()); // 提取 keys 属性们。
  if (keys.isEmpty()) {
    return;
  }
  // 循环 keys ，创建对应的 SpringValue 对象，并添加到 springValueRegistry 中
  for (String key : keys) {
    SpringValue springValue;
    if (member instanceof Field) {
      Field field = (Field) member;
      springValue = new SpringValue(key, value.value(), bean, beanName, field, false);
    } else if (member instanceof Method) {
      Method method = (Method) member;
      springValue = new SpringValue(key, value.value(), bean, beanName, method, false);
    } else {
      logger.error("Apollo @Value annotation currently only support to be used on methods and fields, "
          + "but is used on {}", member.getClass());
      return;
    }
    springValueRegistry.register(beanFactory, key, springValue);
    logger.info("Monitoring {}", springValue);
  }
}
```

- 从代码上，和 SpringValueDefinitionProcessor 的 `#processPropertyValues(beanRegistry)` 类似。

### 7.1.4 processMethod

```java
@Override
protected void processMethod(Object bean, String beanName, Method method) {
  //register @Value on method
  Value value = method.getAnnotation(Value.class);
  if (value == null) {
    return;
  }
  //skip Configuration bean methods // 忽略 @Bean 注解的方法
  if (method.getAnnotation(Bean.class) != null) {
    return;
  }
  if (method.getParameterTypes().length != 1) {
    logger.error("Ignore @Value setter {}.{}, expecting 1 parameter, actual {} parameters",
        bean.getClass().getName(), method.getName(), method.getParameterTypes().length);
    return;
  }

  doRegister(bean, beanName, method, value);
}
```

- 从代码上，和 SpringValueDefinitionProcessor 的 `#processPropertyValues(beanRegistry)` 类似。

### 7.1.5 processBeanPropertyValues

```java
private void processBeanPropertyValues(Object bean, String beanName) {
  Collection<SpringValueDefinition> propertySpringValues = beanName2SpringValueDefinitions
      .get(beanName); // 获得 SpringValueDefinition 数组
  if (propertySpringValues == null || propertySpringValues.isEmpty()) {
    return;
  }
  // 循环 SpringValueDefinition 数组，创建对应的 SpringValue 对象，并添加到 SpringValueRegistry 中
  for (SpringValueDefinition definition : propertySpringValues) {
    try {
      PropertyDescriptor pd = BeanUtils
          .getPropertyDescriptor(bean.getClass(), definition.getPropertyName());
      Method method = pd.getWriteMethod();
      if (method == null) {
        continue;
      }
      SpringValue springValue = new SpringValue(definition.getKey(), definition.getPlaceholder(),
          bean, beanName, method, false);
      springValueRegistry.register(beanFactory, definition.getKey(), springValue);
      logger.debug("Monitoring {}", springValue);
    } catch (Throwable ex) {
      logger.error("Failed to enable auto update feature for {}.{}", bean.getClass(),
          definition.getPropertyName());
    }
  }

  // clear
  beanName2SpringValueDefinitions.removeAll(beanName); // 移除 Bean 对应的 SpringValueDefinition 数组
}
```

# 8. SpringValueRegistry

`com.ctrip.framework.apollo.spring.property.SpringValueRegistry` ，SpringValue **注册表**。代码如下：

```java
public class SpringValueRegistry {
  private static final Logger logger = LoggerFactory.getLogger(SpringValueRegistry.class);

  private static final long CLEAN_INTERVAL_IN_SECONDS = 5;
  private final Map<BeanFactory, Multimap<String, SpringValue>> registry = Maps.newConcurrentMap(); // SpringValue 集合。KEY：属性 KEY ，即 Config 配置 KEY。VALUE：SpringValue 数组
  private final AtomicBoolean initialized = new AtomicBoolean(false);
  private final Object LOCK = new Object();
  // 注册
  public void register(BeanFactory beanFactory, String key, SpringValue springValue) {
    if (!registry.containsKey(beanFactory)) {
      synchronized (LOCK) {
        if (!registry.containsKey(beanFactory)) {
          registry.put(beanFactory, Multimaps.synchronizedListMultimap(LinkedListMultimap.<String, SpringValue>create()));
        }
      }
    }

    registry.get(beanFactory).put(key, springValue);

    // lazy initialize
    if (initialized.compareAndSet(false, true)) {
      initialize();
    }
  }
  // 获得
  public Collection<SpringValue> get(BeanFactory beanFactory, String key) {
    Multimap<String, SpringValue> beanFactorySpringValues = registry.get(beanFactory);
    if (beanFactorySpringValues == null) {
      return null;
    }
    return beanFactorySpringValues.get(key);
  }

  private void initialize() {
    Executors.newSingleThreadScheduledExecutor(ApolloThreadFactory.create("SpringValueRegistry", true)).scheduleAtFixedRate(
        new Runnable() {
          @Override
          public void run() {
            try {
              scanAndClean();
            } catch (Throwable ex) {
              logger.error(ex.getMessage(), ex);
            }
          }
        }, CLEAN_INTERVAL_IN_SECONDS, CLEAN_INTERVAL_IN_SECONDS, TimeUnit.SECONDS);
  }

  private void scanAndClean() {
    Iterator<Multimap<String, SpringValue>> iterator = registry.values().iterator();
    while (!Thread.currentThread().isInterrupted() && iterator.hasNext()) {
      Multimap<String, SpringValue> springValues = iterator.next();
      Iterator<Entry<String, SpringValue>> springValueIterator = springValues.entries().iterator();
      while (springValueIterator.hasNext()) {
        Entry<String, SpringValue> springValue = springValueIterator.next();
        if (!springValue.getValue().isTargetBeanValid()) {
          // clear unused spring values
          springValueIterator.remove();
        }
      }
    }
  }
}

```

## 8.1 SpringValue

`com.ctrip.framework.apollo.spring.property.SpringValue` ，代码如下：

```java
public class SpringValue {

  private MethodParameter methodParameter; // Spring 方法参数封装
  private Field field;
  private WeakReference<Object> beanRef;
  private String beanName; // Bean 名字
  private String key; // KEY。即在 Config 中的属性 KEY
  private String placeholder; // 占位符
  private Class<?> targetType; // 值类型
  private Type genericType; // 泛型。当是 JSON 类型时，使用
  private boolean isJson; // 是否 JSON
  // ... 省略其他接口和属性
}
```

- 分成两种类型：Field 和 Method 类型。

### 8.1.1 构造方法

Field 和 Method 分别对应不同的构造方法：

```java
public SpringValue(String key, String placeholder, Object bean, String beanName, Field field, boolean isJson) {
  this.beanRef = new WeakReference<>(bean);
  this.beanName = beanName;
  this.field = field;
  this.key = key;
  this.placeholder = placeholder;
  this.targetType = field.getType(); // Field 差异
  this.isJson = isJson;
  if(isJson){
    this.genericType = field.getGenericType();
  }
}

public SpringValue(String key, String placeholder, Object bean, String beanName, Method method, boolean isJson) {
  this.beanRef = new WeakReference<>(bean);
  this.beanName = beanName;
  this.methodParameter = new MethodParameter(method, 0);
  this.key = key;
  this.placeholder = placeholder;
  Class<?>[] paramTps = method.getParameterTypes();
  this.targetType = paramTps[0]; // Method 差异
  this.isJson = isJson;
  if(isJson){
    this.genericType = method.getGenericParameterTypes()[0];
  }
}
```

### 8.1.2 更新

Field 和 Method 分别对应不同的更新方法：

```java
private void injectField(Object newVal) throws IllegalAccessException {
  Object bean = beanRef.get();
  if (bean == null) {
    return;
  }
  boolean accessible = field.isAccessible();
  field.setAccessible(true);
  field.set(bean, newVal);
  field.setAccessible(accessible);
}

private void injectMethod(Object newVal)
    throws InvocationTargetException, IllegalAccessException {
  Object bean = beanRef.get();
  if (bean == null) {
    return;
  }
  methodParameter.getMethod().invoke(bean, newVal);
}
```

## 8.2 SpringValueDefinition

`com.ctrip.framework.apollo.spring.property.SpringValueDefinition` ，SpringValue **定义**。代码如下：

```java
/**
 * KEY
 *
 * 即在 Config 中的属性 KEY 。
 */
private final String key;
/**
 * 占位符
 */
private final String placeholder;
/**
 * 属性名
 */
private final String propertyName;
```

# 9. AutoUpdateConfigChangeListener

`com.ctrip.framework.apollo.spring.property.AutoUpdateConfigChangeListener` ，实现 ConfigChangeListener 接口，自动更新配置**监听器**。

## 9.1 构造方法

```java
/**
 * {@link TypeConverter#convertIfNecessary(Object, Class, Field)} 是否带上 Field 参数，因为 Spring 3.2.0+ 才有该方法
 */
private final boolean typeConverterHasConvertIfNecessaryWithFieldParameter;
private final Environment environment;
private final ConfigurableBeanFactory beanFactory;
/**
 * TypeConverter 对象，参见 https://blog.csdn.net/rulerp2014/article/details/51100857
 */
private final TypeConverter typeConverter;
private final PlaceholderHelper placeholderHelper;
private final SpringValueRegistry springValueRegistry;
private final Gson gson;

public AutoUpdateConfigChangeListener(Environment environment, ConfigurableListableBeanFactory beanFactory) {
    this.typeConverterHasConvertIfNecessaryWithFieldParameter = testTypeConverterHasConvertIfNecessaryWithFieldParameter();
    this.beanFactory = beanFactory;
    this.typeConverter = this.beanFactory.getTypeConverter();
    this.environment = environment;
    this.placeholderHelper = SpringInjector.getInstance(PlaceholderHelper.class);
    this.springValueRegistry = SpringInjector.getInstance(SpringValueRegistry.class);
    this.gson = new Gson();
}
```

- `typeConverter` 字段，TypeConverter 对象，详细参见 [《Spring 容器中 TypeConverter 对象的使用》](https://blog.csdn.net/rulerp2014/article/details/51100857) 。

- `typeConverterHasConvertIfNecessaryWithFieldParameter` 字段，是否使用带 Field 方法参数的 `TypeConverter#convertIfNecessary(Object, Class, Field)` 方法，因为 Spring **3.2.0+** 才有该方法。通过 `#testTypeConverterHasConvertIfNecessaryWithFieldParameter()` 方法，初始化：

  ```java
  private boolean testTypeConverterHasConvertIfNecessaryWithFieldParameter() {
      try {
          TypeConverter.class.getMethod("convertIfNecessary", Object.class, Class.class, Field.class);
      } catch (Throwable ex) {
          return false;
      }
      return true;
  }
  ```

  - 通过反射是否存在该方法。

## 9.2 onChange

```java
@Override
public void onChange(ConfigChangeEvent changeEvent) {
  Set<String> keys = changeEvent.changedKeys();  // 获得更新的 KEY 集合
  if (CollectionUtils.isEmpty(keys)) {
    return;
  }
  for (String key : keys) {  // 循环 KEY 集合，更新 StringValue
    // 1. check whether the changed key is relevant // 忽略，若不在 SpringValueRegistry 中
    Collection<SpringValue> targetValues = springValueRegistry.get(beanFactory, key);
    if (targetValues == null || targetValues.isEmpty()) {
      continue;
    }

    // 2. update the value // 循环，更新 SpringValue
    for (SpringValue val : targetValues) {
      updateSpringValue(val);
    }
  }
}
```

- 第 3 至 7 行：获得更新的 **KEY** 集合。
- 第 8 至 26 行：**循环** KEY 集合，更新对应的 StringValue 们。
  - 第 10 至 15 行：**忽略**，若不在 SpringValueRegistry 中。因为，不是所有的 Apollo 的配置项，应用程序中都在使用。
  - 第 21 至 25 行：循环，调用 `#updateSpringValue(SpringValue)` 更新 SpringValue 。

## 9.3 updateSpringValue

```java
private void updateSpringValue(SpringValue springValue) {
    try {
        // 解析值
        Object value = resolvePropertyValue(springValue);
        // 更新 StringValue
        springValue.update(value);
        logger.info("Auto update apollo changed value successfully, new value: {}, {}", value, springValue);
    } catch (Throwable ex) {
        logger.error("Auto update apollo changed value failed, {}", springValue.toString(), ex);
    }
}
```

## 9.4 resolvePropertyValue

```java
private Object resolvePropertyValue(SpringValue springValue) {
  // value will never be null, as @Value and @ApolloJsonValue will not allow that
  Object value = placeholderHelper
      .resolvePropertyValue(beanFactory, springValue.getBeanName(), springValue.getPlaceholder());

  if (springValue.isJson()) {  // 如果值数据结构是 JSON 类型，则使用 Gson 解析成对应值的类型
    value = parseJsonValue((String)value, springValue.getGenericType());
  } else {
    if (springValue.isField()) { // 如果类型为 Field
      // org.springframework.beans.TypeConverter#convertIfNecessary(java.lang.Object, java.lang.Class, java.lang.reflect.Field) is available from Spring 3.2.0+
      if (typeConverterHasConvertIfNecessaryWithFieldParameter) {
        value = this.typeConverter
            .convertIfNecessary(value, springValue.getTargetType(), springValue.getField());
      } else {
        value = this.typeConverter.convertIfNecessary(value, springValue.getTargetType());
      }
    } else { // 如果类型为 Method
      value = this.typeConverter.convertIfNecessary(value, springValue.getTargetType(),
          springValue.getMethodParameter());
    }
  }

  return value;
}
```

- 第 8 行：调用 `PlaceholderHelper#resolvePropertyValue(beanFactory, beanName, placeholder` 方法，**解析**属性值。代码如下：

  ```java
  public Object resolvePropertyValue(ConfigurableBeanFactory beanFactory, String beanName, String placeholder) {
    // resolve string value
    String strVal = beanFactory.resolveEmbeddedValue(placeholder);
    // 获得 BeanDefinition 对象
    BeanDefinition bd = (beanFactory.containsBean(beanName) ? beanFactory
        .getMergedBeanDefinition(beanName) : null);
  
    // resolve expressions like "#{systemProperties.myProp}"
    return evaluateBeanDefinitionString(beanFactory, strVal, bd);
  }
  
  private Object evaluateBeanDefinitionString(ConfigurableBeanFactory beanFactory, String value,
      BeanDefinition beanDefinition) {
    if (beanFactory.getBeanExpressionResolver() == null) {
      return value;
    }
    Scope scope = (beanDefinition != null ? beanFactory
        .getRegisteredScope(beanDefinition.getScope()) : null);
    return beanFactory.getBeanExpressionResolver()
        .evaluate(value, new BeanExpressionContext(beanFactory, scope));
  }
  ```

- **注意**，`value` 是 Object 类型，不一定符合更新 StringValue 的值类型，因此，需要经过转换。

  - 第 9 至 11 行：如果**值**的数据类型是 JSON 类型，则调用 `#parseJsonValue(value, targetType)` 方法，解析成对应值的类型( Type ) 。代码如下：

    ```java
    private Object parseJsonValue(String json, Type targetType) {
        try {
            return gson.fromJson(json, targetType);
        } catch (Throwable ex) {
            logger.error("Parsing json '{}' to type {} failed!", json, targetType, ex);
            throw ex;
        }
    }
    ```

    - 这块需要结合 `@ApolloJsonValue` 注解一起理解，所以见 [《Apollo 源码解析 —— 客户端配置 Spring 集成（一）之注解配置》](http://www.iocoder.cn/Apollo/client-config-spring-2?self)

  - 第 12 至 25 行：如果**值**的数据类型是**非** JSON 类型，调用 TypeConverter 的 `#convertIfNecessary(...)` 方法，转换成对应类型的值。

# 10. SpringInjector

`com.ctrip.framework.apollo.spring.util.SpringInjector` ，Spring 注入器，实现依赖注入( **DI**，全称“**Dependency Injection**” ) 。

类似 DefaultInjector 。但是不要被类名“欺骗”啦，只是注入**集成 Spring 需要**做的 DI ，例如 **SpringValueRegistry** 的单例。

## 10.1 构造方法

```java
/**
 * 注入器
 */
private static volatile Injector s_injector;
/**
 * 锁
 */
private static final Object lock = new Object();

private static Injector getInjector() {
    // 若 Injector 不存在，则进行获得
    if (s_injector == null) {
        synchronized (lock) {
            // 若 Injector 不存在，则进行获得
            if (s_injector == null) {
                try {
                    s_injector = Guice.createInjector(new SpringModule());
                } catch (Throwable ex) {
                    ApolloConfigException exception = new ApolloConfigException("Unable to initialize Apollo Spring Injector!", ex);
                    Tracer.logError(exception);
                    throw exception;
                }
            }
        }
    }
    return s_injector;
}
```

- 使用 SpringModule 类，告诉 Guice 需要 **DI** 的配置。代码如下：

  ```java
      private static class SpringModule extends AbstractModule {
  
      @Override
      protected void configure() {
          bind(PlaceholderHelper.class).in(Singleton.class);
          bind(ConfigPropertySourceFactory.class).in(Singleton.class);
          bind(SpringValueRegistry.class).in(Singleton.class);
      }
  
  }
  ```

  - 配置了 PlaceholderHelper、ConfigPropertySourceFactory、SpringValueRegistry 三个单例。

## 10.2 获得实例

```java
public static <T> T getInstance(Class<T> clazz) {
    try {
        return getInjector().getInstance(clazz);
    } catch (Throwable ex) {
        Tracer.logError(ex);
        throw new ApolloConfigException(String.format("Unable to load instance for %s!", clazz.getName()), ex);
    }
}
```



# 参考

[Apollo 源码解析 —— 客户端配置 Spring 集成（一）之 XML 配置](https://www.iocoder.cn/Apollo/client-config-spring-1/)
