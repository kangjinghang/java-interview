# 1. 概述

> 老艿艿：本系列假定胖友已经阅读过 [《Apollo 官方 wiki 文档》](https://github.com/ctripcorp/apollo/wiki/) ，特别是 [《Spring 整合方式》](https://github.com/ctripcorp/apollo/wiki/Java客户端使用指南#32-spring整合方式) 。
>
> 😁 因为 Spring 仅仅处于入门水平，所以可能一些地方，表述的灰常业余。

**本文分享 Spring 注解 + Java Config 配置的集成**，包括两方面：

- Apollo Config 集成到 Spring PropertySource 体系中。
- **自动更新** Spring Placeholder Values ，参见 [PR #972](https://github.com/ctripcorp/apollo/pull/972) 。

# 2. @EnableApolloConfig

`com.ctrip.framework.apollo.spring.annotation.@EnableApolloConfig` **注解**，可以使用它声明使用的 Apollo Namespace ，和 Apollo XML 配置的 `<apollo:config />` 等价。

**1. 代码如下**：

```java
@Retention(RetentionPolicy.RUNTIME)
@Target(ElementType.TYPE)
@Documented
@Import(ApolloConfigRegistrar.class)
public @interface EnableApolloConfig {
  /**
   * Apollo namespaces to inject configuration into Spring Property Sources.
   */
  String[] value() default {ConfigConsts.NAMESPACE_APPLICATION};

  /**
   * The order of the apollo config, default is {@link Ordered#LOWEST_PRECEDENCE}, which is Integer.MAX_VALUE.
   * If there are properties with the same name in different apollo configs, the apollo config with smaller order wins.
   * @return
   */
  int order() default Ordered.LOWEST_PRECEDENCE;
}
```

- `value` 属性，Namespace 名字的集合，默认为 `"application"` 。
- `order` 属性，优先级，值越小，优先级越高。
- `@Import(Class<?>[])` 注解，引用 ApolloConfigRegistrar 类。详细解析，见 [「3. ApolloConfigRegistrar」](https://www.iocoder.cn/Apollo/client-config-spring-2/#) 。

**2. 例子如下**：

```java
@Configuration
@EnableApolloConfig({"someNamespace","anotherNamespace"})
public class AppConfig {
}
```

- 可声明**多个**。

# 3. ApolloConfigRegistrar

```java
public class ApolloConfigRegistrar implements ImportBeanDefinitionRegistrar, EnvironmentAware {

  private final ApolloConfigRegistrarHelper helper = ServiceBootstrap.loadPrimary(ApolloConfigRegistrarHelper.class);

  @Override
  public void registerBeanDefinitions(AnnotationMetadata importingClassMetadata, BeanDefinitionRegistry registry) {
    helper.registerBeanDefinitions(importingClassMetadata, registry);
  }

  @Override
  public void setEnvironment(Environment environment) {
    this.helper.setEnvironment(environment);
  }

}

// DefaultApolloConfigRegistrarHelper.java
@Override
public void registerBeanDefinitions(AnnotationMetadata importingClassMetadata, BeanDefinitionRegistry registry) {
  AnnotationAttributes attributes = AnnotationAttributes
      .fromMap(importingClassMetadata.getAnnotationAttributes(EnableApolloConfig.class.getName())); // 解析 @EnableApolloConfig 注解
  final String[] namespaces = attributes.getStringArray("value");
  final int order = attributes.getNumber("order");
  final String[] resolvedNamespaces = this.resolveNamespaces(namespaces);
  PropertySourcesProcessor.addNamespaces(Lists.newArrayList(resolvedNamespaces), order); // 添加到 PropertySourcesProcessor 中

  Map<String, Object> propertySourcesPlaceholderPropertyValues = new HashMap<>();
  // to make sure the default PropertySourcesPlaceholderConfigurer's priority is higher than PropertyPlaceholderConfigurer
  propertySourcesPlaceholderPropertyValues.put("order", 0);
  // 注册 PropertySourcesPlaceholderConfigurer 到 BeanDefinitionRegistry 中，替换 PlaceHolder 为对应的属性值，参考文章 https://leokongwq.github.io/2016/12/28/spring-PropertyPlaceholderConfigurer.html
  BeanRegistrationUtil.registerBeanDefinitionIfNotExists(registry, PropertySourcesPlaceholderConfigurer.class.getName(),
      PropertySourcesPlaceholderConfigurer.class, propertySourcesPlaceholderPropertyValues);
  BeanRegistrationUtil.registerBeanDefinitionIfNotExists(registry, PropertySourcesProcessor.class.getName(),
      PropertySourcesProcessor.class); //【差异】注册 PropertySourcesProcessor 到 BeanDefinitionRegistry 中，因为可能存在 XML 配置的 Bean ，用于 PlaceHolder 自动更新机制
  BeanRegistrationUtil.registerBeanDefinitionIfNotExists(registry, ApolloAnnotationProcessor.class.getName(),
      ApolloAnnotationProcessor.class); // 注册 ApolloAnnotationProcessor 到 BeanDefinitionRegistry 中，解析 @ApolloConfig 和 @ApolloConfigChangeListener 注解
  BeanRegistrationUtil.registerBeanDefinitionIfNotExists(registry, SpringValueProcessor.class.getName(),
      SpringValueProcessor.class);  // 注册 SpringValueProcessor 到 BeanDefinitionRegistry 中，用于 PlaceHolder 自动更新机制
  BeanRegistrationUtil.registerBeanDefinitionIfNotExists(registry, SpringValueDefinitionProcessor.class.getName(),
      SpringValueDefinitionProcessor.class); //【差异】注册 SpringValueDefinitionProcessor 到 BeanDefinitionRegistry 中，因为可能存在 XML 配置的 Bean ，用于 PlaceHolder 自动更新机制
}
```

- 第 5 至 10 行：解析 `@EnableApolloConfig` 注解，并调用 `PropertySourcesProcessor#addNamespaces(namespace, order)` 方法，添加到 PropertySourcesProcessor 中。通过这样的方式，`@EnableApolloConfig` 声明的 Namespace 们，就已经**集成**到 Spring ConfigurableEnvironment 中。
- 第 12 至 23 行：注册各种 **Processor** 到 BeanDefinitionRegistry 中。和 ConfigPropertySourcesProcessor **类似**，**差异**在于**多**注册了 PropertySourcesProcessor 和 SpringValueDefinitionProcessor 两个，因为可能存在 **XML 配置的 Bean** 。
- 总的来说，这个类起到的作用，和 NamespaceHandler **基本一致**。

# 4. 注解

## 4.1 @ApolloJsonValue

`com.ctrip.framework.apollo.spring.annotation.@ApolloJsonValue` 注解，将 Apollo 的**一个 JSON 格式的属性**进行注入，例如：

```java
// Inject the json property value for type SomeObject.
// Suppose SomeObject has 2 properties, someString and someInt, then the possible config
// in Apollo is someJsonPropertyKey={"someString":"someValue", "someInt":10}.
@ApolloJsonValue("${someJsonPropertyKey:someDefaultValue}")
private SomeObject someObject;
```

- **错误**的理解：笔者一开理解错了，认为是从 Apollo 中，格式为 **JSON** Namespace 取其中一个 **KEY** 。
- **正确**的理解：将 Apollo **任意格式**的 Namespace 的**一个 Item** 配置项，解析成对应类型的对象，注入到 `@ApolloJsonValue` 的对象中。

------

代码如下：

```java
@Retention(RetentionPolicy.RUNTIME)
@Target({ElementType.FIELD, ElementType.METHOD})
@Documented
public @interface ApolloJsonValue {

    /**
     * The actual value expression: e.g. "${someJsonPropertyKey:someDefaultValue}".
     */
    String value();

}
```

- 对应的处理器，见 [「5.1 ApolloJsonValueProcessor」](https://www.iocoder.cn/Apollo/client-config-spring-2/#) 。

## 4.2 @ApolloConfig

`com.ctrip.framework.apollo.spring.annotation.@ApolloConfig` 注解，将 Apollo Config 对象注入，例如：

```java
// Inject the config for "someNamespace"
@ApolloConfig("someNamespace")
private Config config;
```

------

代码如下：

```java
@Retention(RetentionPolicy.RUNTIME)
@Target(ElementType.FIELD)
@Documented
public @interface ApolloConfig {

    /**
     * Apollo namespace for the config, if not specified then default to application
     */
    String value() default ConfigConsts.NAMESPACE_APPLICATION;

}
```

- 对应的处理器，见 [「5.2 ApolloAnnotationProcessor」](https://www.iocoder.cn/Apollo/client-config-spring-2/#) 。

## 4.3 @ApolloConfigChangeListener

`com.ctrip.framework.apollo.spring.annotation.@ApolloConfigChangeListener` 注解，将被注解的方法，向指定的 Apollo Config 发起配置变更**监听**，例如：

```java
// Listener on namespaces of "someNamespace" and "anotherNamespace"
@ApolloConfigChangeListener({"someNamespace","anotherNamespace"})
private void onChange(ConfigChangeEvent changeEvent) {
   // handle change event
}
```

- 虽然已经有**自动更新**机制，但是不可避免会有需要更新和初始化关联的属性。例如：
  - 例子一：[《Apollo应用之动态调整线上数据源(DataSource)》](http://www.kailing.pub/article/index/arcid/198.html)
  - 例子二：[ApolloRefreshConfig.java](https://github.com/ctripcorp/apollo/blob/v0.9.1/apollo-demo/src/main/java/com/ctrip/framework/apollo/demo/spring/common/refresh/ApolloRefreshConfig.java)
  - 例子三：[SpringBootApolloRefreshConfig.java](https://github.com/ctripcorp/apollo/blob/master/apollo-demo/src/main/java/com/ctrip/framework/apollo/demo/spring/springBootDemo/refresh/SpringBootApolloRefreshConfig.java)

------

代码如下：

```java
@Retention(RetentionPolicy.RUNTIME)
@Target(ElementType.METHOD)
@Documented
public @interface ApolloConfigChangeListener {
  /**
   * Apollo namespace for the config, if not specified then default to application
   */
  String[] value() default {ConfigConsts.NAMESPACE_APPLICATION};

  /**
   * The keys interested by the listener, will only be notified if any of the interested keys is changed.
   * <br />
   * If neither of {@code interestedKeys} and {@code interestedKeyPrefixes} is specified then the {@code listener} will be notified when any key is changed.
   */
  String[] interestedKeys() default {};

  /**
   * The key prefixes that the listener is interested in, will be notified if and only if the changed keys start with anyone of the prefixes.
   * The prefixes will simply be used to determine whether the {@code listener} should be notified or not using {@code changedKey.startsWith(prefix)}.
   * e.g. "spring." means that {@code listener} is interested in keys that starts with "spring.", such as "spring.banner", "spring.jpa", etc.
   * and "application" means that {@code listener} is interested in keys that starts with "application", such as "applicationName", "application.port", etc.
   * <br />
   * If neither of {@code interestedKeys} and {@code interestedKeyPrefixes} is specified then the {@code listener} will be notified when whatever key is changed.
   */
  String[] interestedKeyPrefixes() default {};
}
```

- 对应的处理器，见 [「5.2 ApolloAnnotationProcessor」](https://www.iocoder.cn/Apollo/client-config-spring-2/#) 。

# 5. 处理器

## 5.1 ~~ApolloJsonValueProcessor~~

## 5.2 ApolloAnnotationProcessor

`com.ctrip.framework.apollo.spring.annotation.ApolloAnnotationProcessor` ，实现 BeanFactoryAware 接口，继承 ApolloProcessor 抽象类，处理 `@ApolloConfig` 和 `@ApolloConfigChangeListener` 注解处理器的初始化。

### 5.2.1 processField

```java
@Override
protected void processField(Object bean, String beanName, Field field) {
  this.processApolloConfig(bean, field);
  this.processApolloJsonValue(bean, beanName, field);
}

private void processApolloConfig(Object bean, Field field) {
  ApolloConfig annotation = AnnotationUtils.getAnnotation(field, ApolloConfig.class);
  if (annotation == null) {
    return;
  }

  Preconditions.checkArgument(Config.class.isAssignableFrom(field.getType()),
      "Invalid type: %s for field: %s, should be Config", field.getType(), field);

  final String namespace = annotation.value();
  final String resolvedNamespace = this.environment.resolveRequiredPlaceholders(namespace);
  Config config = ConfigService.getConfig(resolvedNamespace);  // 创建 Config 对象
  // 设置 Config 对象，到对应的 Field
  ReflectionUtils.makeAccessible(field);
  ReflectionUtils.setField(field, bean, config);
}

private void processApolloJsonValue(Object bean, String beanName, Field field) {
  ApolloJsonValue apolloJsonValue = AnnotationUtils.getAnnotation(field, ApolloJsonValue.class);
  if (apolloJsonValue == null) {
    return;
  }
  String placeholder = apolloJsonValue.value(); // 获得 Placeholder 表达式
  Object propertyValue = placeholderHelper // 解析对应的值
      .resolvePropertyValue(this.configurableBeanFactory, beanName, placeholder);

  // propertyValue will never be null, as @ApolloJsonValue will not allow that
  if (!(propertyValue instanceof String)) {  // 忽略，非 String 值
    return;
  }
  // 设置到 Field 中
  boolean accessible = field.isAccessible();
  field.setAccessible(true);
  ReflectionUtils
      .setField(field, bean, parseJsonValue((String) propertyValue, field.getGenericType()));
  field.setAccessible(accessible);
  // 是否开启自动更新机制
  if (configUtil.isAutoUpdateInjectedSpringPropertiesEnabled()) {
    Set<String> keys = placeholderHelper.extractPlaceholderKeys(placeholder); // 提取 keys 属性们
    for (String key : keys) { // 循环 keys ，创建对应的 SpringValue 对象，并添加到 springValueRegistry 中
      SpringValue springValue = new SpringValue(key, placeholder, bean, beanName, field, true);
      springValueRegistry.register(this.configurableBeanFactory, key, springValue);
      logger.debug("Monitoring {}", springValue);
    }
  }
}
```

- 处理 `@ApolloConfig`和`@ApolloJsonValue` 注解，创建( *获得* )对应的 Config 对象，设置到**注解**的 Field 中。

- `#processApolloJsonValue(Object bean, String beanName, Field field)`方法中。

  - 第 8 行：获得 Placeholder 表达式。

  - 第 10 行：调用 `PlaceholderHelper#resolvePropertyValue(beanFactory, beanName, placeholder` 方法，**解析**属性值。

  - 第 17 至 21 行：**设置值**，到注解的 Field 中。`#parseJsonValue(value, targetType)` 方法，解析成对应值的类型( Type ) 。代码如下：

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

- 第 23 至 33 行：用于**自动更新** Spring Placeholder Values 机制。

  - 第 26 行：调用 `PlaceholderHelper#extractPlaceholderKeys(placeholder)` 方法，提取 `keys` 属性们。
  - 第 27 至 32 行：**循环** `keys` ，创建对应的 SpringValue 对象，并添加到 `springValueRegistry` 中。

### 5.2.2 processMethod

```java
@Override
protected void processMethod(final Object bean, String beanName, final Method method) {
  this.processApolloConfigChangeListener(bean, method);
  this.processApolloJsonValue(bean, beanName, method);
}

private void processApolloConfigChangeListener(final Object bean, final Method method) {
  ApolloConfigChangeListener annotation = AnnotationUtils
      .findAnnotation(method, ApolloConfigChangeListener.class);
  if (annotation == null) {
    return;
  }
  Class<?>[] parameterTypes = method.getParameterTypes();
  Preconditions.checkArgument(parameterTypes.length == 1,
      "Invalid number of parameters: %s for method: %s, should be 1", parameterTypes.length,
      method);
  Preconditions.checkArgument(ConfigChangeEvent.class.isAssignableFrom(parameterTypes[0]),
      "Invalid parameter type: %s for method: %s, should be ConfigChangeEvent", parameterTypes[0],
      method);
  // 创建 ConfigChangeListener 监听器。该监听器会调用被注解的方法
  ReflectionUtils.makeAccessible(method);
  String[] namespaces = annotation.value();
  String[] annotatedInterestedKeys = annotation.interestedKeys();
  String[] annotatedInterestedKeyPrefixes = annotation.interestedKeyPrefixes();
  ConfigChangeListener configChangeListener = new ConfigChangeListener() {
    @Override
    public void onChange(ConfigChangeEvent changeEvent) {
      ReflectionUtils.invokeMethod(method, bean, changeEvent);  // 匿名内部类使用外部的final参数
    }
  };

  Set<String> interestedKeys =
      annotatedInterestedKeys.length > 0 ? Sets.newHashSet(annotatedInterestedKeys) : null;
  Set<String> interestedKeyPrefixes =
      annotatedInterestedKeyPrefixes.length > 0 ? Sets.newHashSet(annotatedInterestedKeyPrefixes)
          : null;
  // 向指定 Namespace 的 Config 对象们，注册该监听器
  for (String namespace : namespaces) {
    final String resolvedNamespace = this.environment.resolveRequiredPlaceholders(namespace);
    Config config = ConfigService.getConfig(resolvedNamespace);

    if (interestedKeys == null && interestedKeyPrefixes == null) {
      config.addChangeListener(configChangeListener);
    } else {
      config.addChangeListener(configChangeListener, interestedKeys, interestedKeyPrefixes);
    }
  }
}

private void processApolloJsonValue(Object bean, String beanName, Method method) {
  ApolloJsonValue apolloJsonValue = AnnotationUtils.getAnnotation(method, ApolloJsonValue.class);
  if (apolloJsonValue == null) {
    return;
  }
  String placeHolder = apolloJsonValue.value(); // 获得 Placeholder 表达式
  // 解析对应的值
  Object propertyValue = placeholderHelper
      .resolvePropertyValue(this.configurableBeanFactory, beanName, placeHolder);

  // propertyValue will never be null, as @ApolloJsonValue will not allow that
  if (!(propertyValue instanceof String)) { // 忽略，非 String 值
    return;
  }

  Type[] types = method.getGenericParameterTypes();
  Preconditions.checkArgument(types.length == 1,
      "Ignore @Value setter {}.{}, expecting 1 parameter, actual {} parameters",
      bean.getClass().getName(), method.getName(), method.getParameterTypes().length);
  // 调用 Method ，设置值
  boolean accessible = method.isAccessible();
  method.setAccessible(true);
  ReflectionUtils.invokeMethod(method, bean, parseJsonValue((String) propertyValue, types[0]));
  method.setAccessible(accessible);
  // 是否开启自动更新机制
  if (configUtil.isAutoUpdateInjectedSpringPropertiesEnabled()) {
    Set<String> keys = placeholderHelper.extractPlaceholderKeys(placeHolder); // 提取 keys 属性们
    for (String key : keys) { // 循环 keys ，创建对应的 SpringValue 对象，并添加到 springValueRegistry 中
      SpringValue springValue = new SpringValue(key, apolloJsonValue.value(), bean, beanName,
          method, true);
      springValueRegistry.register(this.configurableBeanFactory, key, springValue);
      logger.debug("Monitoring {}", springValue);
    }
  }
}
```

- 处理 `@ApolloConfigChangeListener` 注解，创建**回调注解方法的** ConfigChangeListener 对象，并向指定 Namespace **们**的 Config 对象**们**，注册该监听器。



# 参考

[Apollo 源码解析 —— 客户端配置 Spring 集成（二）之注解配置](https://www.iocoder.cn/Apollo/client-config-spring-2/)

