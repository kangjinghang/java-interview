# 1. 概述

在[《Apollo 极简入门》](http://www.iocoder.cn/Apollo/install/?self)中，我们已经学习了如何搭建一个 Apollo 服务。如果还没有的胖友，赶紧先去简单学习下，重点是跟着该文[「2. 单机部署」](https://www.iocoder.cn/Spring-Boot/config-apollo/?self#)小节，自己搭建一个 Apollo 服务。

本文，我们来学习下如何在 Spring Boot 中，将 Apollo 作为一个**配置中心**，实现分布式环境下的配置管理。

# 2. 快速入门

> 示例代码对应仓库：[lab-45-apollo-demo](https://github.com/YunaiV/SpringBoot-Labs/tree/master/lab-45/lab-45-apollo-demo)。

本小节，我们会在 Apollo 服务中定义配置，并使用 并使用 [`@ConfigurationProperties`](https://github.com/spring-projects/spring-boot/blob/master/spring-boot-project/spring-boot/src/main/java/org/springframework/boot/context/properties/ConfigurationProperties.java) 和 [`@Value`](https://github.com/spring-projects/spring-framework/blob/master/spring-beans/src/main/java/org/springframework/beans/factory/annotation/Value.java) 注解，读取该配置。

## 2.1 引入依赖

在 [`pom.xml`](https://github.com/YunaiV/SpringBoot-Labs/blob/master/lab-45/lab-45-apollo-demo/pom.xml) 文件中，引入相关依赖。

```xml
<?xml version="1.0" encoding="UTF-8"?>
<project xmlns="http://maven.apache.org/POM/4.0.0"
         xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance"
         xsi:schemaLocation="http://maven.apache.org/POM/4.0.0 http://maven.apache.org/xsd/maven-4.0.0.xsd">
    <parent>
        <groupId>org.springframework.boot</groupId>
        <artifactId>spring-boot-starter-parent</artifactId>
        <version>2.2.2.RELEASE</version>
        <relativePath/> <!-- lookup parent from repository -->
    </parent>
    <modelVersion>4.0.0</modelVersion>

    <artifactId>lab-45-apollo-demo</artifactId>


    <dependencies>
        <!-- Spring Boot Starter 基础依赖 -->
        <dependency>
            <groupId>org.springframework.boot</groupId>
            <artifactId>spring-boot-starter</artifactId>
        </dependency>

        <!--  引入 Apollo 客户端，内置对 Apollo 的自动化配置 -->
        <dependency>
            <groupId>com.ctrip.framework.apollo</groupId>
            <artifactId>apollo-client</artifactId>
            <version>1.5.1</version>
        </dependency>
    </dependencies>

</project>
```

- 引入 `apollo-client` 依赖，Apollo 客户端，内置对 Apollo 的自动化配置。

## 2.2 配置文件

在 [`application.yml`](https://github.com/YunaiV/SpringBoot-Labs/blob/master/lab-45/lab-45-apollo-demo/src/main/resources/application.yaml) 中，添加 Apollo 配置，如下：

```yaml
server:
  port: 7070 # 避免和本地的 Apollo Portal 端口冲突

app:
  id: apollo-learning # 使用的 Apollo 的项目（应用）编号
apollo:
  meta: http://127.0.0.1:8080 # Apollo Meta Server 地址
  bootstrap:
    enabled: true # 是否开启 Apollo 配置预加载功能。默认为 false。
    eagerLoad:
      enabled: true # 是否开启 Apollo 支持日志级别的加载时机。默认为 false。
    namespaces: application # 使用的 Apollo 的命名空间，默认为 application。
```

- `app.id` 配置项，使用的 Apollo 的项目（应用）编号。稍后，我们在[「2.3 创建 Apollo 配置」](https://www.iocoder.cn/Spring-Boot/config-apollo/?self#)小节中进行创建。
- `apollo.meta` 配置项，使用的 Apollo Meta Server 地址。
- `apollo.bootstrap.enabled` 配置项，是否开启 Apollo 配置预加载功能。默认为 `false`。😈 这里，我们设置为 `true`，保证使用 `@Value` 和 `@ConfigurationProperties` 注解，可以读取到来自 Apollo 的配置项。
- `apollo.bootstrap.eagerLoad.enabled` 配置项，是否开启 Apollo 支持日志级别的加载时机。默认为 `false`。😈 这里，我们设置为 `true`，保证 Spring Boot 应用的 Logger 能够使用来自 Apollo 的配置项。
- `apollo.bootstrap.namespaces` 配置项，使用的 Apollo 的命名空间，默认为 `application`。关于 Apollo 的概念，可见[《Apollo 核心概念之“Namespace”》](https://github.com/ctripcorp/apollo/wiki/Apollo核心概念之“Namespace”)文章。

## 2.3 创建 Apollo 配置

在 Apollo 中创建 Apollo 配置，内容如下图所示：

![创建 Apollo 配置](http://blog-1259650185.cosbj.myqcloud.com/img/202204/02/1648868353.png)

## 2.4 OrderProperties

创建 [OrderProperties](https://github.com/YunaiV/SpringBoot-Labs/blob/master/lab-45/lab-45-apollo-demo/src/main/java/cn/iocoder/springboot/lab45/apollodemo/OrderProperties.java) 配置类，读取 `order` 配置项。代码如下：

```java
@Component
@ConfigurationProperties(prefix = "order")
public class OrderProperties {

    /**
     * 订单支付超时时长，单位：秒。
     */
    private Integer payTimeoutSeconds;

    /**
     * 订单创建频率，单位：秒
     */
    private Integer createFrequencySeconds;

    // ... 省略 set/get 方法

}
```

- 在类上，添加 `@Component` 注解，保证该配置类可以作为一个 Bean 被扫描到。
- 在类上，添加 `@ConfigurationProperties` 注解，并设置 `prefix = "order"` 属性，这样它就可以读取**前缀**为 `order` 配置项，设置到配置类对应的属性上。

## 2.5 Application

创建 [`Application.java`](https://github.com/YunaiV/SpringBoot-Labs/blob/master/lab-45/lab-45-apollo-demo/src/main/java/cn/iocoder/springboot/lab45/apollodemo/Application.java) 类，配置 `@SpringBootApplication` 注解即可。代码如下：

```java
@SpringBootApplication
public class Application {

    public static void main(String[] args) {
        SpringApplication.run(Application.class, args);
    }

    @Component
    public class OrderPropertiesCommandLineRunner implements CommandLineRunner {

        private final Logger logger = LoggerFactory.getLogger(getClass());

        @Autowired
        private OrderProperties orderProperties;

        @Override
        public void run(String... args) {
            logger.info("payTimeoutSeconds:" + orderProperties.getPayTimeoutSeconds());
            logger.info("createFrequencySeconds:" + orderProperties.getCreateFrequencySeconds());
        }

    }

    @Component
    public class ValueCommandLineRunner implements CommandLineRunner {

        private final Logger logger = LoggerFactory.getLogger(getClass());

        @Value(value = "${order.pay-timeout-seconds}")
        private Integer payTimeoutSeconds;

        @Value(value = "${order.create-frequency-seconds}")
        private Integer createFrequencySeconds;

        @Override
        public void run(String... args) {
            logger.info("payTimeoutSeconds:" + payTimeoutSeconds);
            logger.info("createFrequencySeconds:" + createFrequencySeconds);
        }
    }

}
```

① 在 OrderPropertiesCommandLineRunner 类中，我们测试了使用 `@ConfigurationProperties` 注解的 OrderProperties 配置类，读取 `order` 配置项的效果。

② 在 ValueCommandLineRunner 类中，我们测试了使用 `@Value` 注解，读取 `order` 配置项的效果

下面，我们来执行 Application 的 `#main(String[] args)` 方法，启动 Spring Boot 应用。输出日志如下：

```java
# 从 Apollo 中，读取配置。
2020-01-26 12:10:04.574  INFO 12179 --- [           main] c.c.f.a.i.DefaultMetaServerProvider      : Located meta services from apollo.meta configuration: http://127.0.0.1:8080!
2020-01-26 12:10:04.581  INFO 12179 --- [           main] c.c.f.apollo.core.MetaDomainConsts       : Located meta server address http://127.0.0.1:8080 for env UNKNOWN from com.ctrip.framework.apollo.internals.DefaultMetaServerProvider
2020-01-26 12:10:04.945  INFO 12179 --- [           main] o.s.c.a.ConfigurationClassPostProcessor  : Cannot enhance @Configuration bean definition 'com.ctrip.framework.apollo.spring.boot.ApolloAutoConfiguration' since its singleton instance has been created too early. The typical cause is a non-static @Bean method with a BeanDefinitionRegistryPostProcessor return type: Consider declaring such methods as 'static'.

# ValueCommandLineRunner 输出
2020-01-26 12:10:05.085  INFO 12179 --- [           main] s.l.a.Application$ValueCommandLineRunner : payTimeoutSeconds:120
2020-01-26 12:10:05.086  INFO 12179 --- [           main] s.l.a.Application$ValueCommandLineRunner : createFrequencySeconds:120

# OrderPropertiesCommandLineRunner 输出
2020-01-26 12:10:05.086  INFO 12179 --- [           main] ication$OrderPropertiesCommandLineRunner : payTimeoutSeconds:120
2020-01-26 12:10:05.086  INFO 12179 --- [           main] ication$OrderPropertiesCommandLineRunner : createFrequencySeconds:120
```

- 两个 CommandLineRunner 都读取 `order` 配置项成功，美滋滋。

# 3. 多环境配置

> 示例代码对应仓库：[lab-45-apollo-demo-profiles](https://github.com/YunaiV/SpringBoot-Labs/tree/master/lab-45/lab-45-apollo-demo-profiles)。

在[《芋道 Spring Boot 配置文件入门》](http://www.iocoder.cn/Spring-Boot/config-file/?self)的[「6. 多环境配置」](https://www.iocoder.cn/Spring-Boot/config-apollo/?self#)中，我们介绍如何基于 `spring.profiles.active` 配置项，在 Spring Boot 实现多环境的配置功能。在本小节中，我们会在该基础之上，实现结合 Apollo 的多环境配置。

在 Apollo 中，我们可以通过搭建不同环境的 Config Service + Admin Service 服务。然后，在每个 `application-${profile}.yaml` 配置文件中，配置对应的 Config Service + Admin Service 服务即可。

下面，我们来搭建一个结合 Apollo 的多环境的示例。

## 3.1 创建 Apollo 配置

在 Apollo 中创建 Apollo 配置，创建一个 AppId 为 `demo-application-profiles` 的项目，并配置 DEV（开发环境）和 PRO（生产环境）两套配置。如下图所示：

![创建 Apollo 配置（开发）](http://blog-1259650185.cosbj.myqcloud.com/img/202204/02/1648868993.png) 

![创建 Apollo 配置（生产）](http://blog-1259650185.cosbj.myqcloud.com/img/202204/02/1648869002.png)

这里，我们通过不同环境，使用不同 `server.port` 配置项。这样， Spring Boot 项目启动后，从日志中就可以看到生效的服务器端口，嘿嘿~从而模拟不同环境，不同配置。

## 3.2 引入依赖

在 [`pom.xml`](https://github.com/YunaiV/SpringBoot-Labs/blob/master/lab-45/lab-45-apollo-demo-profiles/pom.xml) 文件中，引入相关依赖。

```xml
<?xml version="1.0" encoding="UTF-8"?>
<project xmlns="http://maven.apache.org/POM/4.0.0"
         xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance"
         xsi:schemaLocation="http://maven.apache.org/POM/4.0.0 http://maven.apache.org/xsd/maven-4.0.0.xsd">
    <parent>
        <groupId>org.springframework.boot</groupId>
        <artifactId>spring-boot-starter-parent</artifactId>
        <version>2.2.2.RELEASE</version>
        <relativePath/> <!-- lookup parent from repository -->
    </parent>
    <modelVersion>4.0.0</modelVersion>

    <artifactId>lab-45-apollo-demo-profiles</artifactId>


    <dependencies>
        <!-- 实现对 SpringMVC 的自动化配置 -->
        <dependency>
            <groupId>org.springframework.boot</groupId>
            <artifactId>spring-boot-starter-web</artifactId>
        </dependency>

        <!--  引入 Apollo 客户端，内置对 Apollo 的自动化配置 -->
        <dependency>
            <groupId>com.ctrip.framework.apollo</groupId>
            <artifactId>apollo-client</artifactId>
            <version>1.5.1</version>
        </dependency>
    </dependencies>

</project>
```

- 引入 `spring-boot-starter-web` 原来的原因是，我们会使用 `server.port` 配置项，配置 Tomcat 的端口。

## 3.3 配置文件

在 [`resources`](https://github.com/YunaiV/SpringBoot-Labs/tree/master/lab-45/lab-45-apollo-demo-profiles/src/main/resources) 目录下，创建 2 个配置文件，对应不同的环境。如下：

- [`application-dev.yaml`](https://github.com/YunaiV/SpringBoot-Labs/blob/master/lab-45/lab-45-apollo-demo-profiles/src/main/resources/application-dev.yaml)，开发环境。

  ```yaml
  app:
    id: demo-application-profiles # 使用的 Apollo 的项目（应用）编号
  apollo:
    meta: http://127.0.0.1:8080 # Apollo Meta Server 地址
    bootstrap:
      enabled: true # 是否开启 Apollo 配置预加载功能。默认为 false。
      eagerLoad:
        enable: true # 是否开启 Apollo 支持日志级别的加载时机。默认为 false。
      namespaces: application # 使用的 Apollo 的命名空间，默认为 application。
  ```

  - 和[「2.2 配置文件」](https://www.iocoder.cn/Spring-Boot/config-apollo/?self#)不同的点，重点是 `apollo.meta` 配置项，设置为 DEV 环境的 Apollo Meta Server 地址。

- [`application-prod.yaml`](https://github.com/YunaiV/SpringBoot-Labs/blob/master/lab-45/lab-45-apollo-demo-profiles/src/main/resources/application-prod.yaml)，生产环境。

  ```yaml
  app:
    id: demo-application-profiles # 使用的 Apollo 的项目（应用）编号
  apollo:
    meta: http://127.0.0.1:18080 # Apollo Meta Server 地址
    bootstrap:
      enabled: true # 是否开启 Apollo 配置预加载功能。默认为 false。
      eagerLoad:
        enable: true # 是否开启 Apollo 支持日志级别的加载时机。默认为 false。
      namespaces: application # 使用的 Apollo 的命名空间，默认为 application。
  ```

  - 和[「2.2 配置文件」](https://www.iocoder.cn/Spring-Boot/config-apollo/?self#)不同的点，重点是 `apollo.meta` 配置项，设置为 PROD 环境的 Apollo Meta Server 地址。

另外，我们会创建 [`application.yaml`](https://github.com/YunaiV/SpringBoot-Labs/blob/master/lab-45/lab-45-apollo-demo-profiles/src/main/resources/application.yaml) 配置文件，放不同环境的**相同配置**。例如说，`spring.application.name` 配置项，肯定是相同的啦。配置如下：

```yaml
#server:
spring:
  application:
    name: demo-application
```

## 3.4 ProfilesApplication

创建 [`ProfilesApplication.java`](https://github.com/YunaiV/SpringBoot-Labs/blob/master/lab-45/lab-45-apollo-demo-profiles/src/main/java/cn/iocoder/springboot/lab45/apollodemo/ProfilesApplication.java) 类，配置 `@SpringBootApplication` 注解即可。代码如下：

```java
@SpringBootApplication
public class ProfilesApplication {

    public static void main(String[] args) {
        SpringApplication.run(ProfilesApplication.class, args);
    }

}
```

## 3.5 简单测试

下面，我们使用命令行参数进行 `--spring.profiles.active` 配置项，实现不同环境，读取不同配置文件。

① **开发环境**示例：直接在 IDEA 中，增加 `--spring.profiles.active=dev` 到 Program arguments 中。如下图所示：![IDEA 配置 - dev](http://www.iocoder.cn/images/Spring-Boot/2020-07-04/13.png)

启动 Spring Boot 应用，输出日志如下：

```
# 省略其它日志...
2020-01-27 12:08:57.051  INFO 27951 --- [           main] o.s.b.w.embedded.tomcat.TomcatWebServer  : Tomcat initialized with port(s): 8081 (http)
```

- Tomcat 启动在 8081 端口，符合读取 DEV 环境的配置。

② **生产环境**示例：直接在 IDEA 中，增加 `--spring.profiles.active=prod` 到 Program arguments 中。如下图所示：![IDEA 配置 - prod](http://www.iocoder.cn/images/Spring-Boot/2020-07-04/14.png)

启动 Spring Boot 应用，输出日志如下：

```
# 省略其它日志...
2020-01-27 12:11:31.159  INFO 28150 --- [           main] o.s.b.w.embedded.tomcat.TomcatWebServer  : Tomcat initialized with port(s): 8084 (http)
```

- Tomcat 启动在 8084 端口，符合读取 PROD 环境的配置。

另外，关于 Spring Boot 应用的多环境部署，胖友也可以看看[《芋道 Spring Boot 持续交付 Jenkins 入门》](http://www.iocoder.cn/Spring-Boot/Jenkins/?self)文章。

# 4. 自动刷新配置

> 示例代码对应仓库：[lab-45-apollo-demo-auto-refresh](https://github.com/YunaiV/SpringBoot-Labs/blob/master/lab-45/lab-45-apollo-demo-auto-refresh/)。

在上面的示例中，我们已经实现从 Apollo 读取配置。那么，在应用已经启动的情况下，如果我们将读取的 Apollo 的配置进行修改时，应用是否会自动刷新本地的配置呢？答案是，针对 `@Value` 注解的属性**是的**，针对 `@ConfigurationProperties` 注解的配置类需要**做特殊处理**。

下面，我们来搭建一个自动刷新配置的示例。

## 4.1 引入依赖

在 [`pom.xml`](https://github.com/YunaiV/SpringBoot-Labs/blob/master/lab-45/lab-45-apollo-demo-auto-refresh/pom.xml) 文件中，引入相关依赖。

```xml
<?xml version="1.0" encoding="UTF-8"?>
<project xmlns="http://maven.apache.org/POM/4.0.0"
         xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance"
         xsi:schemaLocation="http://maven.apache.org/POM/4.0.0 http://maven.apache.org/xsd/maven-4.0.0.xsd">
    <parent>
        <groupId>org.springframework.boot</groupId>
        <artifactId>spring-boot-starter-parent</artifactId>
        <version>2.2.2.RELEASE</version>
        <relativePath/> <!-- lookup parent from repository -->
    </parent>
    <modelVersion>4.0.0</modelVersion>

    <artifactId>lab-45-apollo-demo-auto-refresh</artifactId>

    <dependencies>
        <!-- 实现对 SpringMVC 的自动化配置 -->
        <dependency>
            <groupId>org.springframework.boot</groupId>
            <artifactId>spring-boot-starter-web</artifactId>
        </dependency>

        <!--  引入 Apollo 客户端，内置对 Apollo 的自动化配置 -->
        <dependency>
            <groupId>com.ctrip.framework.apollo</groupId>
            <artifactId>apollo-client</artifactId>
            <version>1.5.1</version>
        </dependency>
    </dependencies>

</project>
```

- 引入 `spring-boot-starter-web` 依赖的原因，稍后我们会编写 API 接口，查看来自 Apollo 配置的最新值。

## 4.2 创建 Apollo 配置

在 Apollo 中创建 Apollo 配置，内容如下图所示：![创建 Apollo 配置](http://www.iocoder.cn/images/Spring-Boot/2020-07-04/21.png)

## 4.3 配置文件

在 [`application.yml`](https://github.com/YunaiV/SpringBoot-Labs/blob/master/lab-45/lab-45-apollo-demo-auto-refresh/src/main/resources/application.yaml) 中，添加 Apollo 配置，如下：

```yaml
server:
  port: 7070 # 避免和本地的 Apollo Portal 端口冲突

app:
  id: demo-application # 使用的 Apollo 的项目（应用）编号
apollo:
  meta: http://127.0.0.1:8080 # Apollo Meta Server 地址
  bootstrap:
    enabled: true # 是否开启 Apollo 配置预加载功能。默认为 false。
    eagerLoad:
      enable: true # 是否开启 Apollo 支持日志级别的加载时机。默认为 false。
    namespaces: application # 使用的 Apollo 的命名空间，默认为 application。
```

- 和[「2.2 配置文件」](https://www.iocoder.cn/Spring-Boot/config-apollo/?self#)的差异点，只是添加了 `server.port` 配置项。

## 4.4 TestProperties

在 [`cn.iocoder.springboot.lab45.apollodemo.properties`](https://github.com/YunaiV/SpringBoot-Labs/blob/master/lab-45/lab-45-apollo-demo-auto-refresh/src/main/java/cn/iocoder/springboot/lab45/apollodemo/properties/) 包下，创建 [TestProperties](https://github.com/YunaiV/SpringBoot-Labs/blob/master/lab-45/lab-45-apollo-demo-auto-refresh/src/main/java/cn/iocoder/springboot/lab45/apollodemo/properties/TestProperties.java) 配置类，读取 `test` 配置项。代码如下：

```java
@Component
@ConfigurationProperties(prefix = "test")
public class TestProperties {

    /**
     * 测试属性
     */
    private String test;

    public String getTest() {
        return test;
    }

    public TestProperties setTest(String test) {
        this.test = test;
        return this;
    }

}
```

## 4.5 DemoController

在 [`cn.iocoder.springboot.lab45.apollodemo.controller`](https://github.com/YunaiV/SpringBoot-Labs/blob/master/lab-45/lab-45-apollo-demo-auto-refresh/src/main/java/cn/iocoder/springboot/lab45/apollodemo/controller/) 包下，创建 [DemoController](https://github.com/YunaiV/SpringBoot-Labs/blob/master/lab-45/lab-45-apollo-demo-auto-refresh/src/main/java/cn/iocoder/springboot/lab45/apollodemo/controller/DemoController.java) 类，提供返回配置的 API 接口。代码如下：

```java
@RestController
@RequestMapping("/demo")
public class DemoController {

    @Value("${test.test}")
    private String test;

    @GetMapping("/test")
    public String test() {
        return test;
    }

    @Autowired
    private TestProperties testProperties;

    @GetMapping("/test_properties")
    public TestProperties testProperties() {
        return testProperties;
    }
    
}
```

- `/demo/test` 接口，测试 `@Value` 注解的属性的动刷新配置的功能。
- `/demo/test_properties` 接口，测试 `@ConfigurationProperties` 注解的 TestProperties 配置类的动刷新配置的功能。

## 4.6 Application

创建 [`Application.java`](https://github.com/YunaiV/SpringBoot-Labs/blob/master/lab-45/lab-45-apollo-demo-auto-refresh/src/main/java/cn/iocoder/springboot/lab45/apollodemo/Application.java) 类，配置 `@SpringBootApplication` 注解即可。代码如下：

```
@SpringBootApplication
public class Application {

    public static void main(String[] args) {
        SpringApplication.run(Application.class, args);
    }

}
```

## 4.7 简单测试

启动 Spring Boot 应用，开始我们本轮的测试。

① 分别请求 `/demo/test`、`/demo/test_properties` 接口，响应结果如下：

```
# /demo/test 接口
哈哈哈哈

# /demo/test_properties 接口
{
    "test": "哈哈哈哈"
}
```

② 修改 Apollo 中的 `test.test` 配置项设置为 `呵呵呵呵`。如下图所示：![修改 Apollo 配置项](http://www.iocoder.cn/images/Spring-Boot/2020-07-01/22.png)

并且，我们可以看到控制台会输出 Apollo 的自动刷新配置相关的日志。日志如下：

```
2020-01-27 15:42:52.537  INFO 31590 --- [Apollo-Config-1] c.f.a.s.p.AutoUpdateConfigChangeListener : Auto update apollo changed value successfully, new value: 呵呵呵呵, key: test.test, beanName: demoController, field: cn.iocoder.springboot.lab45.apollodemo.controller.DemoController.test
```

③ 分别请求 `/demo/test`、`/demo/test_properties` 接口，响应结果如下：

```
# /demo/test 接口
呵呵呵呵

# /demo/test_properties 接口
{
    "test": "哈哈哈哈"
}
```

- `@Value` 注解的属性，自动刷新配置**成功**。
- `@ConfigurationProperties`注解的配置类，自动刷新配置失败。
  - 目前 Apollo 暂时未提供 `@ConfigurationProperties` 注解的配置类的自动刷新配置的功能，并且在**纯** Spring Boot 项目中，没有太好的实现自动刷新配置的方式，具体可见 [issues#1657](https://github.com/ctripcorp/apollo/issues/1657) 讨论。
  - 针对 Spring Cloud 项目，可以参考 [issue#2846](https://github.com/ctripcorp/apollo/issues/2846) 讨论，基于 [EnvironmentChangeEvent](https://cloud.spring.io/spring-cloud-static/spring-cloud.html#_environment_changes) 或 [RefreshScope](https://cloud.spring.io/spring-cloud-static/spring-cloud.html#_refresh_scope)。相关代码实现，可以参考 `apollo-use-cases` 项目中的 [ZuulPropertiesRefresher.java](https://github.com/ctripcorp/apollo-use-cases/blob/master/spring-cloud-zuul/src/main/java/com/ctrip/framework/apollo/use/cases/spring/cloud/zuul/ZuulPropertiesRefresher.java#L48) 和 `apollo-demo` 项目中的 [SampleRedisConfig.java](https://github.com/ctripcorp/apollo/blob/master/apollo-demo/src/main/java/com/ctrip/framework/apollo/demo/spring/springBootDemo/config/SampleRedisConfig.java) 以及 [SpringBootApolloRefreshConfig.java](https://github.com/ctripcorp/apollo/blob/master/apollo-demo/src/main/java/com/ctrip/framework/apollo/demo/spring/springBootDemo/refresh/SpringBootApolloRefreshConfig.java)。

## 4.8 Apollo 配置监听器

默认情况下，Apollo 已经能够满足我们绝大多数场景下的自动刷新配置的功能。但是，在一些场景下，我们仍然需要**自定义 Apollo 配置监听器**，实现对 Apollo 配置的监听，执行自定义的逻辑。

例如说，当数据库连接的配置发生变更时，我们需要通过监听该配置的变更，重新初始化应用中的数据库连接，从而访问到新的数据库地址。

又例如说，当日志级别发生变更时，我们需要通过监听该配置的变更，设置应用中的 Logger 的日志级别，从而后续的日志打印可以根据新的日志级别。

可能这么说，胖友会觉得有点抽象，我们来搭建一个日志级别的示例。

在 [`cn.iocoder.springboot.lab45.apollodemo.listener`](https://github.com/YunaiV/SpringBoot-Labs/blob/master/lab-45/lab-45-apollo-demo-auto-refresh/src/main/java/cn/iocoder/springboot/lab45/apollodemo/listener/) 包下，创建 [LoggingSystemConfigListener](https://github.com/YunaiV/SpringBoot-Labs/blob/master/lab-45/lab-45-apollo-demo-auto-refresh/src/main/java/cn/iocoder/springboot/lab45/apollodemo/listener/LoggingSystemConfigListener.java) 类，监听 `logging.level` 配置项的变更，修改 Logger 的日志级别。代码如下：

```java
@Component
public class LoggingSystemConfigListener {

    /**
     * 日志配置项的前缀
     */
    private static final String LOGGER_TAG = "logging.level.";

    @Resource
    private LoggingSystem loggingSystem;

    @ApolloConfig
    private Config config;

    @ApolloConfigChangeListener
    public void onChange(ConfigChangeEvent changeEvent) throws Exception {
        // <X> 获得 Apollo 所有配置项
        Set<String> keys = config.getPropertyNames();
        // <Y> 遍历配置集的每个配置项，判断是否是 logging.level 配置项
        for (String key : keys) {
            // 如果是 logging.level 配置项，则设置其对应的日志级别
            if (key.startsWith(LOGGER_TAG)) {
                // 获得日志级别
                String strLevel = config.getProperty(key, "info");
                LogLevel level = LogLevel.valueOf(strLevel.toUpperCase());
                // 设置日志级别到 LoggingSystem 中
                loggingSystem.setLogLevel(key.replace(LOGGER_TAG, ""), level);
            }
        }
    }

}
```

- `loggingSystem` 属性，是 Spring Boot Logger 日志系统，通过 [LoggingSystem](https://github.com/spring-projects/spring-boot/blob/master/spring-boot-project/spring-boot/src/main/java/org/springframework/boot/logging/LoggingSystem.java) 可以进行日志级别的修改。
- `config` 属性，是 Apollo [Config](https://github.com/ctripcorp/apollo/blob/master/apollo-client/src/main/java/com/ctrip/framework/apollo/Config.java) 对象，通过它获取本地缓存的 Apollo 配置。
- 在 `#onChange(ConfigChangeEvent changeEvent)` 方法上，我们添加了 [`@ApolloConfigChangeListener`](https://github.com/ctripcorp/apollo/blob/4fa65a1d4a8eb7591c0a71d8a01a898ebf654ae8/apollo-client/src/main/java/com/ctrip/framework/apollo/spring/annotation/ApolloConfigChangeListener.java) 注解，声明该方法处理 Apollo 的配置变化。
- `<X>` 处，通过 Apollo Config 对象，获得所有配置项的 KEY。
- `<Y>` 处，遍历每个配置项的 KEY，判断如果是 `logging.level` 配置项，则设置到 LoggingSystem 中，从而修改日志级别。详细的整个过程，胖友看看艿艿的详细的注释，嘿嘿~

## 4.9 再次测试

① 在 DemoController 类中，增加如下 API 接口。代码如下：

```java
private Logger logger = LoggerFactory.getLogger(getClass());

@GetMapping("/logger")
public void logger() {
    logger.debug("[logger][测试一下]");
}
```

- 如果 DemoController 对应的 Logger 日志级别是 DEBUG 以上，则无法打印出日志。

② 在 Apollo 中，增加 `logging.level.cn.iocoder.springboot.lab45.apollodemo.controller` 配置项为 INFO，具体内容如下图：![修改 Apollo 配置项](http://blog-1259650185.cosbj.myqcloud.com/img/202204/02/1648869398.png)

③ 启动 Spring Boot 应用，开始我们本轮的测试。

④ 请求 `/demo/logger` 接口，控制台并未打印日志，因为当前日志级别是 INFO。

⑤ 在 Apollo 中，增加 `logging.level.cn.iocoder.springboot.lab45.apollodemo.controller` 配置项为 DEBUG，具体内容如下图：![修改 Apollo 配置项 02](http://blog-1259650185.cosbj.myqcloud.com/img/202204/02/1648869400.png)

⑥ 请求 `/demo/logger` 接口，控制台打印日志，因为当前日志级别是 DEBUG。日志内容如下：

```
2020-01-27 16:36:24.231 DEBUG 33860 --- [nio-7070-exec-3] c.i.s.l.a.controller.DemoController      : [logger][测试一下]
```

- 符合预期。

更多 Apollo 自定义配置监听器，实现各种组件刷新的文章，也可以阅读如下两篇文章：

- [《spring boot 动态调整线上日志级别》](http://www.iocoder.cn/Fight/Spring-boot-dynamically-adjusts-the-online-log-level/?self)
- [《Apollo 应用之动态调整线上数据源(DataSource)》](http://www.iocoder.cn/Fight/Dynamic-adjustment-of-the-online-DataSource-by-Apollo-application/?self)

# 5. 配置加密

> 示例代码对应仓库：[lab-45-apollo-demo-jasypt](https://github.com/YunaiV/SpringBoot-Labs/tree/master/lab-45/lab-45-apollo-demo-jasypt)。

考虑到安全性，我们可能最好将配置文件中的敏感信息进行加密。例如说，MySQL 的用户名密码、第三方平台的 Token 令牌等等。不过，Apollo 暂时未内置配置加密的功能。官方文档说明如下：

> FROM https://github.com/ctripcorp/apollo/wiki/FAQ
>
> **7. Apollo 是否支持查看权限控制或者配置加密？**
>
> 从 1.1.0 版本开始，apollo-portal 增加了查看权限的支持，可以支持配置某个环境只允许项目成员查看私有 Namespace 的配置。
>
> 这里的项目成员是指：
>
> 1. 项目的管理员
> 2. 具备该私有Namespace在该环境下的修改或发布权限
>
> 配置方式很简单，用超级管理员账号登录后，进入 `管理员工具 - 系统参数` 页面新增或修改 `configView.memberOnly.envs` 配置项即可。
>
> ![configView.memberOnly.envs](http://blog-1259650185.cosbj.myqcloud.com/img/202204/02/1648869400.png)
>
> 配置加密可以参考 [spring-boot-encrypt demo项目](https://github.com/ctripcorp/apollo-use-cases/tree/master/spring-boot-encrypt)

因此，我们暂时只能在客户端进行配置的加解密。这里，我们继续采用在[《芋道 Spring Boot 配置文件入门》](http://www.iocoder.cn/Spring-Boot/config-file/?self)的[「8. 配置加密」](https://www.iocoder.cn/Spring-Boot/config-apollo/?self#)小节中使用的 [Jasypt](https://github.com/jasypt/jasypt)。

下面，我们来使用 Apollo + Jasypt 搭建一个配置加密的示例。

## 5.1 引入依赖

在 [`pom.xml`](https://github.com/YunaiV/SpringBoot-Labs/blob/master/lab-45/lab-45-apollo-demo-jasypt/pom.xml) 文件中，引入相关依赖。

```xml
<?xml version="1.0" encoding="UTF-8"?>
<project xmlns="http://maven.apache.org/POM/4.0.0"
         xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance"
         xsi:schemaLocation="http://maven.apache.org/POM/4.0.0 http://maven.apache.org/xsd/maven-4.0.0.xsd">
    <parent>
        <groupId>org.springframework.boot</groupId>
        <artifactId>spring-boot-starter-parent</artifactId>
        <version>2.2.2.RELEASE</version>
        <relativePath/> <!-- lookup parent from repository -->
    </parent>
    <modelVersion>4.0.0</modelVersion>

    <artifactId>lab-45-apollo-demo-jasypt</artifactId>

    <dependencies>
        <!-- 实现对 SpringMVC 的自动化配置 -->
        <dependency>
            <groupId>org.springframework.boot</groupId>
            <artifactId>spring-boot-starter-web</artifactId>
        </dependency>

        <!--  引入 Apollo 客户端，内置对 Apollo 的自动化配置 -->
        <dependency>
            <groupId>com.ctrip.framework.apollo</groupId>
            <artifactId>apollo-client</artifactId>
            <version>1.5.1</version>
        </dependency>

        <!-- 实现对 Jasypt 实现自动化配置 -->
        <dependency>
            <groupId>com.github.ulisesbocchio</groupId>
            <artifactId>jasypt-spring-boot-starter</artifactId>
            <version>3.0.2</version>
        </dependency>

        <!-- 方便等会写单元测试 -->
        <dependency>
            <groupId>org.springframework.boot</groupId>
            <artifactId>spring-boot-starter-test</artifactId>
            <scope>test</scope>
        </dependency>
    </dependencies>

</project>
```

- 引入 [`jasypt-spring-boot-starter`](https://mvnrepository.com/artifact/com.github.ulisesbocchio/jasypt-spring-boot-starter) 依赖，实现对 Jasypt 的自动化配置。

## 5.2 创建 Apollo 配置

在 Apollo 中创建 Apollo 配置，内容如下图所示：![创建 Apollo 配置](http://blog-1259650185.cosbj.myqcloud.com/img/202204/02/1648869402.png)

这里为了测试简便，我们直接添加加密秘钥 `jasypt.encryptor.password` 配置项在该 Apollo 配置中。如果为了安全性更高，实际建议把加密秘钥和配置隔离。不然，如果配置泄露，岂不是可以拿着加密秘钥，直接进行解密。

## 5.3 配置文件

在 [`application.yml`](https://github.com/YunaiV/SpringBoot-Labs/blob/master/lab-45/lab-45-apollo-demo-jasypt/src/main/resources/application.yaml) 中，添加 Apollo 配置，如下：

```yaml
server:
  port: 7070 # 避免和本地的 Apollo Portal 端口冲突

app:
  id: demo-application-jasypt # 使用的 Apollo 的项目（应用）编号
apollo:
  meta: http://127.0.0.1:8080 # Apollo Meta Server 地址
  bootstrap:
    enabled: true # 是否开启 Apollo 配置预加载功能。默认为 false。
    eagerLoad:
      enable: true # 是否开启 Apollo 支持日志级别的加载时机。默认为 false。
    namespaces: application # 使用的 Apollo 的命名空间，默认为 application。
```

- 和[「2.2 配置文件」](https://www.iocoder.cn/Spring-Boot/config-apollo/?self#)一样，就是换了一个 Apollo 项目为 `demo-application-jasypt`。

## 5.4 Application

创建 [`Application.java`](https://github.com/YunaiV/SpringBoot-Labs/blob/master/lab-45/lab-45-apollo-demo-jasypt/src/main/java/cn/iocoder/springboot/lab45/apollodemo/Application.java) 类，配置 `@SpringBootApplication` 注解即可。代码如下：

```java
@SpringBootApplication
public class Application {

    public static void main(String[] args) {
        SpringApplication.run(Application.class, args);
    }

}
```

## 5.5 简单测试

下面，我们进行下简单测试。

- 首先，我们会使用 Jasypt 将 `demo-application` 进行加密，获得加密结果。
- 然后，将加密结果，赋值到 Apollo 的 `spring.application.name` 配置项中。
- 最后，我们会使用 Jasypt 将 `spring.application.name` 配置项解密。

创建 [JasyptTest](https://github.com/YunaiV/SpringBoot-Labs/blob/master/lab-45/lab-45-apollo-demo-jasypt/src/test/java/cn/iocoder/springboot/lab45/apollodemo/JasyptTest.java) 测试类，编写测试代码如下：

```java
@SpringBootTest
public class JasyptTest {

    @Autowired
    private StringEncryptor encryptor;

    @Test
    public void encode() {
        String applicationName = "apollo-learning";
        System.out.println(encryptor.encrypt(applicationName));
    }

    @Value("${spring.application.name}")
    private String applicationName;

    @Test
    public void print() {
        System.out.println(applicationName);
    }

}
```

- 首先，执行 `#encode()`方法，手动使用 Jasypt 将`apollo-learning`进行加密，获得加密结果。加密结果如下：

  ```
  npwrQdCnv0L3zMplHg83iNV8tGWkcynu8vSOn3dNzJE=
  ```

- 然后，将加密结果，赋值到 Apollo 的 `spring.application.name` 配置项中。如下图所示：![修改 Apollo 配置](http://blog-1259650185.cosbj.myqcloud.com/img/202204/02/1648869403.png)

- 最后，执行 `#print()` 方法，**自动**使用 Jasypt 将 `spring.application.name` 配置项解密。解密结果如下：

  ```
  apollo-learning
  ```

  - 成功正确解密，符合预期。

## 5.6 补充说明

目前测试下来，在将 Jasypt 集成进来时，Apollo 的[「4. 自动配置刷新」](https://www.iocoder.cn/Spring-Boot/config-apollo/?self#)功能，竟然失效了。

- 具体的验证，胖友可以将 `jasypt-spring-boot-starter` 依赖设置成 `<scope>test</scope>`，并是使用 [DemoController](https://github.com/YunaiV/SpringBoot-Labs/blob/master/lab-45/lab-45-apollo-demo-jasypt/src/main/java/cn/iocoder/springboot/lab45/apollodemo/controller/DemoController.java) 进行测试。
- 具体的原因，艿艿暂时没去调试与研究，有了解的胖友，麻烦告知下哟。在 [issues#2162](https://github.com/ctripcorp/apollo/issues/2162) 中，也有其它胖友提到该问题。

如果说，胖友暂时不需要自动配置刷新功能的话，可以考虑选择使用 Jasypt 集成。如果需要的话，那么就等待官方支持吧，暂时不要考虑使用 Jasypt 咧。

# 6. 配置加载顺序

> 示例代码对应仓库：[lab-45-apollo-demo-multi](https://github.com/YunaiV/SpringBoot-Labs/tree/master/lab-45/lab-45-apollo-demo-multi)。

在[《芋道 Spring Boot 配置文件入门》](http://www.iocoder.cn/Spring-Boot/config-file/?self)的[「9. 配置加载顺序」](https://www.iocoder.cn/Spring-Boot/config-apollo/?self#)小节，我们了解了 Spring Boot 自带的配置加载顺序。本小节，我们来看看来自 Apollo 的配置，在其中的顺序。同时，我们将配置多个 Apollo Namespace 命名空间，看看它们互相之间的加载顺序。

下面，我们来搭建一个用于测试配置加载顺序的示例。

## 6.1 创建 Apollo 配置

在 Apollo 中创建 Apollo 配置，内容如下图所示：![创建 Apollo 配置](http://www.iocoder.cn/images/Spring-Boot/2020-07-04/41.png)

## 6.2 引入依赖

在 [`pom.xml`](https://github.com/YunaiV/SpringBoot-Labs/blob/master/lab-45/lab-45-apollo-demo-multi/pom.xml) 文件中，引入相关依赖。

```xml
<?xml version="1.0" encoding="UTF-8"?>
<project xmlns="http://maven.apache.org/POM/4.0.0"
         xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance"
         xsi:schemaLocation="http://maven.apache.org/POM/4.0.0 http://maven.apache.org/xsd/maven-4.0.0.xsd">
    <parent>
        <groupId>org.springframework.boot</groupId>
        <artifactId>spring-boot-starter-parent</artifactId>
        <version>2.2.2.RELEASE</version>
        <relativePath/> <!-- lookup parent from repository -->
    </parent>
    <modelVersion>4.0.0</modelVersion>

    <artifactId>lab-45-apollo-demo-multi</artifactId>

    <dependencies>
        <!-- 实现对 SpringMVC 的自动化配置 -->
        <dependency>
            <groupId>org.springframework.boot</groupId>
            <artifactId>spring-boot-starter-web</artifactId>
        </dependency>

        <!--  引入 Apollo 客户端，内置对 Apollo 的自动化配置 -->
        <dependency>
            <groupId>com.ctrip.framework.apollo</groupId>
            <artifactId>apollo-client</artifactId>
            <version>1.5.1</version>
        </dependency>
    </dependencies>

</project>
```

- 和[「2.1 引入依赖」](https://www.iocoder.cn/Spring-Boot/config-apollo/?self#)是一致的。

## 6.3 配置文件

在 [`application.yml`](https://github.com/YunaiV/SpringBoot-Labs/blob/master/lab-45/lab-45-apollo-demo-multi/src/main/resources/application.yaml) 中，添加 Apollo 配置，如下：

```yaml
server:
  port: 7070 # 避免和本地的 Apollo Portal 端口冲突

app:
  id: demo-application-multi # 使用的 Apollo 的项目（应用）编号
apollo:
  meta: http://127.0.0.1:8080 # Apollo Meta Server 地址
  bootstrap:
    enabled: true # 是否开启 Apollo 配置预加载功能。默认为 false。
    eagerLoad:
      enable: true # 是否开启 Apollo 支持日志级别的加载时机。默认为 false。
    namespaces: application, db # 使用的 Apollo 的命名空间，默认为 application。
```

- 注意，我们在 `apollo.bootstrap.namespaces` 配置项中，设置了[「6.1 创建 Apollo 配置」](https://www.iocoder.cn/Spring-Boot/config-apollo/?self#)的两个 Namespace 命名空间。

## 6.4 Application

创建 [`Application.java`](https://github.com/YunaiV/SpringBoot-Labs/blob/master/lab-45/lab-45-apollo-demo-multi/src/main/java/cn/iocoder/springboot/lab45/apollodemo/Application.java) 类，配置 `@SpringBootApplication` 注解即可。代码如下：

```java
@SpringBootApplication
public class Application {

    public static void main(String[] args) {
        // 启动 Spring Boot 应用
        ConfigurableApplicationContext context = SpringApplication.run(Application.class, args);

        // 查看 Environment
        Environment environment = context.getEnvironment();
        System.out.println(environment);
    }

}
```

在代码中，我们去获取了 Spring [Environment](https://github.com/spring-projects/spring-framework/blob/master/spring-core/src/main/java/org/springframework/core/env/Environment.java) 对象，因为我们要从其中获取到 [PropertySource](https://github.com/spring-projects/spring-framework/blob/master/spring-core/src/main/java/org/springframework/core/env/PropertySource.java) 配置来源。**DEBUG** 运行 Application，并记得在 `System.out.println(environment);` 代码块打一个断点，可以看到如下图的调试信息：![调试信息](http://www.iocoder.cn/images/Spring-Boot/2020-07-04/42.png)

- 对于 `apollo.bootstrap` 对应一个 [CompositePropertySource](https://github.com/spring-projects/spring-framework/blob/master/spring-core/src/main/java/org/springframework/core/env/CompositePropertySource.java) 对象，即使有对应多个 Apollo Namespace。并且，多个 Namespace 是按照在 `apollo.bootstrap.namespaces` 配置顺序。
- 所有 Apollo 对应的 PropertySource 对象，优先级非常高，目前看下来仅仅低于 `server.ports` 对应的 MapPropertySource。基本上，我们可以认为是**最高优先级**了。

## 6.5 补充说明

搞懂配置加载顺序的作用，很多时候是解决多个配置来源，里面配置了相同的配置项。艿艿建议的话，尽量避免出现相同配置项，排查起来还挺麻烦的。

不过所幸，在日常开发中，我们也很少会设置相同的配置项 😜。



# 参考

[芋道 Spring Boot 配置中心 Apollo 入门](https://www.iocoder.cn/Spring-Boot/config-apollo/)



