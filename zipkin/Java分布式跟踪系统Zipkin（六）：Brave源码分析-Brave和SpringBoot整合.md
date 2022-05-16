Zipkin 是用当下最流行的 SpringBoot 开发的，SpringBoot 将 Spring 项目的开发过程大大简化，一切主流的开发框架都可以通过添加 jar包和配置，自动激活，现在越来越受广大 Java开发人员的喜爱。 上一篇博文中，我们分析了 Brave 是如何在 SpringMVC 项目中使用的，这一篇博文我们继续分析 Brave 和 SpringBoot 项目的整合方法及原理。

相关代码在Chapter6/springboot 中。

pom.xml中添加依赖和插件

```xml
<dependency>
    <groupId>org.springframework.boot</groupId>
    <artifactId>spring-boot-starter</artifactId>
    <version>${springboot.version}</version>
</dependency>
<dependency>
    <groupId>org.springframework.boot</groupId>
    <artifactId>spring-boot-starter-web</artifactId>
    <version>${springboot.version}</version>
</dependency>

<plugin>
    <groupId>org.springframework.boot</groupId>
    <artifactId>spring-boot-maven-plugin</artifactId>
    <configuration>
        <fork>true</fork>
    </configuration>
</plugin>
```

```java
package org.mozhu.zipkin.springboot;

import org.springframework.boot.SpringApplication;
import org.springframework.boot.autoconfigure.EnableAutoConfiguration;
import org.springframework.boot.autoconfigure.SpringBootApplication;

@SpringBootApplication
@EnableAutoConfiguration
public class DefaultApplication {

    public static void main(String[] args) {
        SpringApplication.run(DefaultApplication.class, args);
    }

}
```

启动 Zipkin，然后分别运行：

```bash
mvn spring-boot:run -Drun.jvmArguments="-Dserver.port=9000 -Dzipkin.service=backend"
```

```bash
mvn spring-boot:run -Drun.jvmArguments="-Dserver.port=8081 -Dzipkin.service=frontend"
```

浏览器访问 http://localhost:8081/ 会显示当前时间。在 Zipkin 的 Web 界面中，也能查询到这次跟踪信息。

可见 Brave 和 SpringBoot 的整合更简单了，只添加了启动类 DefaultApplication，其他类都没变化。至于 SpringBoot 的原理，这里就不展开了，网上优秀教程一大把。

在 brave-instrumentation 目录中，还有对其他框架的支持，有兴趣的可以看看其源代码实现。 grpc、http、asyncclient、httpclient 、jaxrs2、kafka-clients、mysql、mysql6、p6spy、sparkjava...

至此，我们 Brave 的源码分析即将告一段落，后续我们会逐步 Zipkin 的高级用法及实现原理。



## 参考

[Java分布式跟踪系统Zipkin（六）：Brave源码分析-Brave和SpringBoot整合](http://blog.mozhu.org/2017/11/15/zipkin/zipkin-6.html)
