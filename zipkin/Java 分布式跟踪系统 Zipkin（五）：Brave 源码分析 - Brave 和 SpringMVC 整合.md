上一篇博文中，我们分析了 Brave 是如何在普通 Web 项目中使用的，这一篇博文我们继续分析 Brave 和 SpringMVC 项目的整合方法及原理。 我们分两个部分来介绍和 SpringMVC 的整合，及 XML 配置方式和 Annotation 注解方式。

pom.xml

添加相关依赖 spring-web 和 spring-webmvc。

```xml
<dependency>
  <groupId>io.zipkin.brave</groupId>
  <artifactId>brave-instrumentation-spring-web</artifactId>
  <version>${brave.version}</version>
</dependency>
<dependency>
  <groupId>org.springframework</groupId>
  <artifactId>spring-web</artifactId>
  <version>${spring.version}</version>
</dependency>

<dependency>
  <groupId>io.zipkin.brave</groupId>
  <artifactId>brave-instrumentation-spring-webmvc</artifactId>
  <version>${brave.version}</version>
</dependency>
<dependency>
  <groupId>org.springframework</groupId>
  <artifactId>spring-webmvc</artifactId>
  <version>${spring.version}</version>
</dependency>
```

## 1. XML 配置方式

在 Servlet2.5 规范中，必须配置 web.xml，我们只需要配置 DispatcherServlet，SpringMVC 的核心控制器就可以了。

相关代码在 Chapter5/springmvc-servlet25 中 web.xml：

```xml
<web-app xmlns="http://java.sun.com/xml/ns/javaee"
    xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance"
    xsi:schemaLocation="http://java.sun.com/xml/ns/javaee
	http://java.sun.com/xml/ns/javaee/web-app_2_5.xsd"
    version="2.5">

  <display-name>SpringMVC Servlet2.5 Application</display-name>

  <servlet>
    <servlet-name>spring-webmvc</servlet-name>
    <servlet-class>org.springframework.web.servlet.DispatcherServlet</servlet-class>
    <load-on-startup>1</load-on-startup>
  </servlet>

  <servlet-mapping>
    <servlet-name>spring-webmvc</servlet-name>
    <url-pattern>/</url-pattern>
  </servlet-mapping>
</web-app>
```

然后在 WEB-INF 下配置 spring-webmvc-servlet.xml。

```xml
<beans xmlns="http://www.springframework.org/schema/beans"
    xmlns:context="http://www.springframework.org/schema/context"
    xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance"
    xmlns:mvc="http://www.springframework.org/schema/mvc"
    xmlns:util="http://www.springframework.org/schema/util"
    xsi:schemaLocation="
        http://www.springframework.org/schema/beans
        http://www.springframework.org/schema/beans/spring-beans-3.2.xsd
        http://www.springframework.org/schema/mvc
        http://www.springframework.org/schema/mvc/spring-mvc-3.2.xsd
        http://www.springframework.org/schema/context
        http://www.springframework.org/schema/context/spring-context-3.2.xsd
        http://www.springframework.org/schema/util
        http://www.springframework.org/schema/util/spring-util-3.2.xsd">

  <context:property-placeholder/>

  <bean id="sender" class="zipkin2.reporter.okhttp3.OkHttpSender" factory-method="create">
    <constructor-arg type="String" value="http://localhost:9411/api/v2/spans"/>
  </bean>

  <bean id="tracing" class="brave.spring.beans.TracingFactoryBean">
    <property name="localServiceName" value="${zipkin.service:springmvc-servlet25-example}"/>
    <property name="spanReporter">
      <bean class="brave.spring.beans.AsyncReporterFactoryBean">
        <property name="encoder" value="JSON_V2"/>
        <property name="sender" ref="sender"/>
        <!-- wait up to half a second for any in-flight spans on close -->
        <property name="closeTimeout" value="500"/>
      </bean>
    </property>
    <property name="propagationFactory">
      <bean id="propagationFactory" class="brave.propagation.ExtraFieldPropagation" factory-method="newFactory">
        <constructor-arg index="0">
          <util:constant static-field="brave.propagation.B3Propagation.FACTORY"/>
        </constructor-arg>
        <constructor-arg index="1">
          <list>
            <value>user-name</value>
          </list>
        </constructor-arg>
      </bean>
    </property>
    <property name="currentTraceContext">
      <bean class="brave.context.log4j2.ThreadContextCurrentTraceContext" factory-method="create"/>
    </property>
  </bean>

  <bean id="httpTracing" class="brave.spring.beans.HttpTracingFactoryBean">
    <property name="tracing" ref="tracing"/>
  </bean>

  <bean id="restTemplate" class="org.springframework.web.client.RestTemplate">
    <property name="interceptors">
      <list>
        <bean class="brave.spring.web.TracingClientHttpRequestInterceptor" factory-method="create">
          <constructor-arg type="brave.http.HttpTracing" ref="httpTracing"/>
        </bean>
      </list>
    </property>
  </bean>

  <mvc:interceptors>
    <bean class="brave.spring.webmvc.TracingHandlerInterceptor" factory-method="create">
      <constructor-arg type="brave.http.HttpTracing" ref="httpTracing"/>
    </bean>
  </mvc:interceptors>

  <!-- Loads the controller -->
  <context:component-scan base-package="org.mozhu.zipkin.springmvc"/>
  <mvc:annotation-driven/>
</beans>
```

使用 brave.spring.beans.TracingFactoryBean 创建 tracing，使用 brave.spring.beans.HttpTracingFactoryBean 创建 httpTracing ， 配置 springmvc 的拦截器 brave.spring.webmvc.TracingHandlerInterceptor 并配置 org.springframework.web.client.RestTemplate 作为客户端发送 http 请求。

再来看看两个 Controller：Frontend 和 Backend，和前面 FrontendServlet，BackendServlet 功能一样。

### 1.1 Frontend

```java
@RestController
public class Frontend {
    private final static Logger LOGGER = LoggerFactory.getLogger(Frontend.class);
    @Autowired
    RestTemplate restTemplate;

    @RequestMapping("/")
    public String callBackend() {
        LOGGER.info("frontend receive request");
        return restTemplate.getForObject("http://localhost:9000/api", String.class);
    }
}
```

Frontend 中使用 Spring 提供的 restTemplate 向 Backend 发送请求。

### 1.2 Backend

```java
@RestController
public class Backend {

  private final static Logger LOGGER = LoggerFactory.getLogger(Backend.class);

  @RequestMapping("/api")
  public String printDate(@RequestHeader(name = "user-name", required = false) String username) {
    LOGGER.info("backend receive request");
    if (username != null) {
      return new Date().toString() + " " + username;
    }
    return new Date().toString();
  }
}
```

Backend 中收到来自 Frontend 的请求，并给出响应，打出当前的时间戳，如果 headers 中存在 user-name，也会添加到响应字符串尾部。

跟前面博文一样，启动Zipkin，然后分别运行

```bash
mvn jetty:run -Pbackend
```

```bash
mvn jetty:run -Pfrontend
```

浏览器访问 http://localhost:8081/ 会显示当前时间。在 Zipkin 的 Web 界面中，也能查询到这次跟踪信息。

现在来分析下两个 Spring 相关的类。

brave.spring.webmvc.TracingHandlerInterceptor - 服务端请求的拦截器，在这个类里会处理服务端的 trace 信息。brave.spring.web.TracingClientHttpRequestInterceptor - 客户端请求的拦截器，在这个类里会处理客户端的 trace 信息。

TracingHandlerInterceptor

```java
public final class TracingHandlerInterceptor extends HandlerInterceptorAdapter {

  public static AsyncHandlerInterceptor create(Tracing tracing) {
    return new TracingHandlerInterceptor(HttpTracing.create(tracing));
  }

  public static AsyncHandlerInterceptor create(HttpTracing httpTracing) {
    return new TracingHandlerInterceptor(httpTracing);
  }

  final Tracer tracer;
  final HttpServerHandler<HttpServletRequest, HttpServletResponse> handler;
  final TraceContext.Extractor<HttpServletRequest> extractor;

  @Autowired TracingHandlerInterceptor(HttpTracing httpTracing) { // internal
    tracer = httpTracing.tracing().tracer();
    handler = HttpServerHandler.create(httpTracing, new HttpServletAdapter());
    extractor = httpTracing.tracing().propagation().extractor(HttpServletRequest::getHeader);
  }

  @Override
  public boolean preHandle(HttpServletRequest request, HttpServletResponse response, Object o) {
    if (request.getAttribute(SpanInScope.class.getName()) != null) {
      return true; // already handled (possibly due to async request)
    }

    Span span = handler.handleReceive(extractor, request);
    request.setAttribute(SpanInScope.class.getName(), tracer.withSpanInScope(span));
    return true;
  }

  @Override
  public void afterCompletion(HttpServletRequest request, HttpServletResponse response,
      Object o, Exception ex) {
    Span span = tracer.currentSpan();
    if (span == null) return;
    ((SpanInScope) request.getAttribute(SpanInScope.class.getName())).close();
    handler.handleSend(response, ex, span);
  }
}
```

TracingHandlerInterceptor 继承了 HandlerInterceptorAdapter，覆盖了其中 preHandle 和 afterCompletion 方法，分别在请求执行前，和请求完成后执行。 这里没办法向前面几篇博文的一样，使用 try-with-resources 来自动关闭 SpanInScope，所以只能在preHandle 中将 SpanInScope 放在 request 的 attribute 中，然后在 afterCompletion 中将其取出来手动 close，其他代码逻辑和前面TracingFilter 里一样。

TracingClientHttpRequestInterceptor

```java
public final class TracingClientHttpRequestInterceptor implements ClientHttpRequestInterceptor {
  static final Propagation.Setter<HttpHeaders, String> SETTER = HttpHeaders::set;

  public static ClientHttpRequestInterceptor create(Tracing tracing) {
    return create(HttpTracing.create(tracing));
  }

  public static ClientHttpRequestInterceptor create(HttpTracing httpTracing) {
    return new TracingClientHttpRequestInterceptor(httpTracing);
  }

  final Tracer tracer;
  final HttpClientHandler<HttpRequest, ClientHttpResponse> handler;
  final TraceContext.Injector<HttpHeaders> injector;

  @Autowired TracingClientHttpRequestInterceptor(HttpTracing httpTracing) {
    tracer = httpTracing.tracing().tracer();
    handler = HttpClientHandler.create(httpTracing, new HttpAdapter());
    injector = httpTracing.tracing().propagation().injector(SETTER);
  }

  @Override public ClientHttpResponse intercept(HttpRequest request, byte[] body,
      ClientHttpRequestExecution execution) throws IOException {
    Span span = handler.handleSend(injector, request.getHeaders(), request);
    ClientHttpResponse response = null;
    Throwable error = null;
    try (Tracer.SpanInScope ws = tracer.withSpanInScope(span)) {
      return response = execution.execute(request, body);
    } catch (IOException | RuntimeException | Error e) {
      error = e;
      throw e;
    } finally {
      handler.handleReceive(response, error, span);
    }
  }

  static final class HttpAdapter
      extends brave.http.HttpClientAdapter<HttpRequest, ClientHttpResponse> {

    @Override public String method(HttpRequest request) {
      return request.getMethod().name();
    }

    @Override public String url(HttpRequest request) {
      return request.getURI().toString();
    }

    @Override public String requestHeader(HttpRequest request, String name) {
      Object result = request.getHeaders().getFirst(name);
      return result != null ? result.toString() : null;
    }

    @Override public Integer statusCode(ClientHttpResponse response) {
      try {
        return response.getRawStatusCode();
      } catch (IOException e) {
        return null;
      }
    }
  }
}
```

TracingClientHttpRequestInterceptor 里的逻辑和前面博文分析的 brave.okhttp3.TracingInterceptor 类似，此处不再展开分析。

下面再来介绍用Annotation注解方式来配置SpringMVC和Brave

## 2. Annotation 注解方式

相关代码在 Chapter5/springmvc-servlet3 中。在 Servlet3 以后，web.xml 不是必须的了，org.mozhu.zipkin.springmvc.Initializer 是我们整个应用的启动器。

```java
public class Initializer extends AbstractAnnotationConfigDispatcherServletInitializer {

  @Override protected String[] getServletMappings() {
    return new String[] {"/"};
  }

  @Override protected Class<?>[] getRootConfigClasses() {
    return null;
  }

  @Override protected Class<?>[] getServletConfigClasses() {
    return new Class[] {TracingConfiguration.class};
  }
}
```

org.mozhu.zipkin.springmvc.Initializer，继承自 AbstractDispatcherServletInitializer，实现了 WebApplicationInitializer WebApplicationInitializer

```java
public interface WebApplicationInitializer {

	void onStartup(ServletContext servletContext) throws ServletException;

}
```

关于 Servlet3 的容器是如何启动的，我们再来看一个类 SpringServletContainerInitializer，该类实现了javax.servlet.ServletContainerInitializer 接口，并且该类上有一个 javax.servlet.annotation.HandlesTypes 注解。Servlet3 规范规定实现 Servlet3 的容器，必须加载 classpath 里所有实现了 ServletContainerInitializer 接口的类，并调用其 onStartup 方法，传入的第一个参数是类上 HandlesTypes 中所指定的类，这里是 WebApplicationInitializer 的集合。在 SpringServletContainerInitializer 的onStartup 方法中，会将传入的 WebApplicationInitializer 类，全部实例化，并且排序，然后依次调用它们的initializer.onStartup(servletContext)。

```java
@HandlesTypes(WebApplicationInitializer.class)
public class SpringServletContainerInitializer implements ServletContainerInitializer {

	@Override
	public void onStartup(Set<Class<?>> webAppInitializerClasses, ServletContext servletContext)
			throws ServletException {

		List<WebApplicationInitializer> initializers = new LinkedList<WebApplicationInitializer>();

		if (webAppInitializerClasses != null) {
			for (Class<?> waiClass : webAppInitializerClasses) {
				// Be defensive: Some servlet containers provide us with invalid classes,
				// no matter what @HandlesTypes says...
				if (!waiClass.isInterface() && !Modifier.isAbstract(waiClass.getModifiers()) &&
						WebApplicationInitializer.class.isAssignableFrom(waiClass)) {
					try {
						initializers.add((WebApplicationInitializer) waiClass.newInstance());
					}
					catch (Throwable ex) {
						throw new ServletException("Failed to instantiate WebApplicationInitializer class", ex);
					}
				}
			}
		}

		if (initializers.isEmpty()) {
			servletContext.log("No Spring WebApplicationInitializer types detected on classpath");
			return;
		}

		servletContext.log(initializers.size() + " Spring WebApplicationInitializers detected on classpath");
		AnnotationAwareOrderComparator.sort(initializers);
		for (WebApplicationInitializer initializer : initializers) {
			initializer.onStartup(servletContext);
		}
	}

}
```

另外 Servlet3 在 ServletContext 中提供了 addServlet 方法，允许以编码方式向容器中添加 Servlet

```java
jpublic ServletRegistration.Dynamic addServlet(String servletName, Servlet servlet);
```

而在 AbstractDispatcherServletInitializer 中 registerDispatcherServlet 方法会将 SpringMVC 的核心控制器 DispatcherServlet 添加到Web 容器中。

```java
protected void registerDispatcherServlet(ServletContext servletContext) {
	String servletName = getServletName();
	Assert.hasLength(servletName, "getServletName() must not return empty or null");

	WebApplicationContext servletAppContext = createServletApplicationContext();
	Assert.notNull(servletAppContext,
			"createServletApplicationContext() did not return an application " +
			"context for servlet [" + servletName + "]");

	FrameworkServlet dispatcherServlet = createDispatcherServlet(servletAppContext);
	dispatcherServlet.setContextInitializers(getServletApplicationContextInitializers());

	ServletRegistration.Dynamic registration = servletContext.addServlet(servletName, dispatcherServlet);
	Assert.notNull(registration,
			"Failed to register servlet with name '" + servletName + "'." +
			"Check if there is another servlet registered under the same name.");

	registration.setLoadOnStartup(1);
	registration.addMapping(getServletMappings());
	registration.setAsyncSupported(isAsyncSupported());

	Filter[] filters = getServletFilters();
	if (!ObjectUtils.isEmpty(filters)) {
		for (Filter filter : filters) {
			registerServletFilter(servletContext, filter);
		}
	}

	customizeRegistration(registration);
}
protected FrameworkServlet createDispatcherServlet(WebApplicationContext servletAppContext) {
	return new DispatcherServlet(servletAppContext);
}
```

以前用 xml 配置 bean 的方式，全改为在 TracingConfiguration 类里用 @Bean 注解来配置，并且使用 @ComponentScan 注解指定controller的package，让 Spring 容器可以扫描到这些 Controller。

```java
@Configuration
@EnableWebMvc
@ComponentScan(basePackages = "org.mozhu.zipkin.springmvc")
@Import({TracingClientHttpRequestInterceptor.class, TracingHandlerInterceptor.class})
public class TracingConfiguration extends WebMvcConfigurerAdapter {

  @Bean Sender sender() {
    return OkHttpSender.create("http://127.0.0.1:9411/api/v2/spans");
  }

  @Bean AsyncReporter<Span> spanReporter() {
    return AsyncReporter.create(sender());
  }

  @Bean Tracing tracing(@Value("${zipkin.service:springmvc-servlet3-example}") String serviceName) {
    return Tracing.newBuilder()
        .localServiceName(serviceName)
        .propagationFactory(ExtraFieldPropagation.newFactory(B3Propagation.FACTORY, "user-name"))
        .currentTraceContext(ThreadContextCurrentTraceContext.create()) // puts trace IDs into logs
        .spanReporter(spanReporter()).build();
  }

  @Bean HttpTracing httpTracing(Tracing tracing) {
    return HttpTracing.create(tracing);
  }

  @Autowired
  private TracingHandlerInterceptor serverInterceptor;

  @Autowired
  private TracingClientHttpRequestInterceptor clientInterceptor;

  @Bean RestTemplate restTemplate() {
    RestTemplate restTemplate = new RestTemplate();
    List<ClientHttpRequestInterceptor> interceptors =
      new ArrayList<>(restTemplate.getInterceptors());
    interceptors.add(clientInterceptor);
    restTemplate.setInterceptors(interceptors);
    return restTemplate;
  }

  @Override
  public void addInterceptors(InterceptorRegistry registry) {
    registry.addInterceptor(serverInterceptor);
  }
}
```

然后在 getServletConfigClasses 方法中指定 TracingConfiguration，让 Spring 容器可以加载所有的配置。

```java
@Override protected Class<?>[] getServletConfigClasses() {
  return new Class[] {TracingConfiguration.class};
}
```

Annotation 和 XML 配置的方式相比，简化了不少，而其中使用的 Tracing 相关的类都一样，这里就不用再分析了



## 参考

[Java分布式跟踪系统Zipkin（五）：Brave源码分析-Brave和SpringMVC整合](http://blog.mozhu.org/2017/11/14/zipkin/zipkin-5.html)
