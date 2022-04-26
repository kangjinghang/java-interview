# 1. 概述

> 老艿艿：本系列假定胖友已经阅读过 [《Apollo 官方 wiki 文档》](https://github.com/ctripcorp/apollo/wiki/) ，特别是 [《架构模块》](https://github.com/ctripcorp/apollo/wiki/Apollo配置中心设计#12-架构模块) 。

本文分享 Apollo **服务的注册与发现**。如下图所示：

![服务的注册与发现](http://blog-1259650185.cosbj.myqcloud.com/img/202204/07/1649345138.png)

- 各服务的介绍，见 [《各模块概要介绍》](https://github.com/ctripcorp/apollo/wiki/Apollo配置中心设计#13-各模块概要介绍) 。
- 默认情况下，Config Service、Meta Service、Eureka Server **统一**部署在 **Config Service** 中。如果想要使用**单独的 Eureka Server**，参见 [《将 Config Service 和 Admin Service 注册到单独的 Eureka Server 上》](https://github.com/ctripcorp/apollo/wiki/部署&开发遇到的常见问题#8-将config-service和admin-service注册到单独的eureka-server上) 。

# 2. Eureka Server

## 2.1 启动 Eureka Server

在 `apollo-configservice` 项目中，`com.ctrip.framework.apollo.configservice.ConfigServerEurekaServerConfigure` 中，通过 `@EnableEurekaServer` 注解启动 Eureka Server 。代码如下：

```java
@Configuration
@EnableEurekaServer
@ConditionalOnProperty(name = "apollo.eureka.server.enabled", havingValue = "true", matchIfMissing = true)
public class ConfigServerEurekaServerConfigure {
}
```

- 第一行的 `@EnableEurekaServer` 注解，启动 Eureka Server 。基于 Spring Cloud Eureka ，需要在 Maven 的 `pom.xml` 中申明如下依赖：

  ```xml
  <!-- eureka -->
  <dependency>
  	<groupId>org.springframework.cloud</groupId>
  	<artifactId>spring-cloud-starter-netflix-eureka-server</artifactId>
  	<exclusions>
  		<exclusion>
  			<artifactId>spring-cloud-starter-netflix-archaius</artifactId>
  			<groupId>org.springframework.cloud</groupId>
  		</exclusion>
  		<exclusion>
  			<artifactId>spring-cloud-starter-netflix-ribbon</artifactId>
  			<groupId>org.springframework.cloud</groupId>
  		</exclusion>
  		<exclusion>
  			<artifactId>ribbon-eureka</artifactId>
  			<groupId>com.netflix.ribbon</groupId>
  		</exclusion>
  		<exclusion>
  			<artifactId>aws-java-sdk-core</artifactId>
  			<groupId>com.amazonaws</groupId>
  		</exclusion>
  		<exclusion>
  			<artifactId>aws-java-sdk-ec2</artifactId>
  			<groupId>com.amazonaws</groupId>
  		</exclusion>
  		<exclusion>
  			<artifactId>aws-java-sdk-autoscaling</artifactId>
  			<groupId>com.amazonaws</groupId>
  		</exclusion>
  		<exclusion>
  			<artifactId>aws-java-sdk-sts</artifactId>
  			<groupId>com.amazonaws</groupId>
  		</exclusion>
  		<exclusion>
  			<artifactId>aws-java-sdk-route53</artifactId>
  			<groupId>com.amazonaws</groupId>
  		</exclusion>
  		<!-- duplicated with spring-security-core -->
  		<exclusion>
  			<groupId>org.springframework.security</groupId>
  			<artifactId>spring-security-crypto</artifactId>
  		</exclusion>
  	</exclusions>
  </dependency>
  <dependency>
  	<groupId>com.sun.jersey.contribs</groupId>
  	<artifactId>jersey-apache-client4</artifactId>
  </dependency>
  <!-- end of eureka -->
  ```

那么 Eureka Server 怎么构建成**集群**呢？答案在 [「2.2 注册到 Eureka Client」](https://www.iocoder.cn/Apollo/service-register-discovery/#) 中。

## 2.2 注册到 Eureka Client

在 `apollo-biz` 项目中，`com.ctrip.framework.apollo.biz.eureka.ApolloEurekaClientConfig` 中，**声明** Eureka 的**配置**。代码如下：

```java
@Component
@Primary
@ConditionalOnProperty(value = {"eureka.client.enabled"}, havingValue = "true", matchIfMissing = true)
public class ApolloEurekaClientConfig extends EurekaClientConfigBean {

  private final BizConfig bizConfig;
  private final RefreshScope refreshScope;
  private static final String EUREKA_CLIENT_BEAN_NAME = "eurekaClient";

  public ApolloEurekaClientConfig(final BizConfig bizConfig, final RefreshScope refreshScope) {
    this.bizConfig = bizConfig;
    this.refreshScope = refreshScope;
  }

  /**
   * Assert only one zone: defaultZone, but multiple environments.
   */
  public List<String> getEurekaServerServiceUrls(String myZone) {
    List<String> urls = bizConfig.eurekaServiceUrls();
    return CollectionUtils.isEmpty(urls) ? super.getEurekaServerServiceUrls(myZone) : urls;
  }

  @EventListener
  public void listenApplicationReadyEvent(ApplicationReadyEvent event) {
    this.refreshEurekaClient();
  }

  private void refreshEurekaClient() {
    if (!super.isFetchRegistry()) {
        super.setFetchRegistry(true);
        super.setRegisterWithEureka(true);
        refreshScope.refresh(EUREKA_CLIENT_BEAN_NAME);
    }
  }

  @Override
  public boolean equals(Object o) {
    return super.equals(o);
  }
}
```

- `@Primary` 注解，保证**优先级**。

- `#getEurekaServerServiceUrls(myZone)` 方法，调用 `BizConfig#eurekaServiceUrls()` 方法，从 ServerConfig 的 `"eureka.service.url"` 配置项，获得 Eureka Server 地址。代码如下：

  ```java
  // 获得 Eureka 服务器地址的数组
  public List<String> eurekaServiceUrls() {
      // 获得配置值
      String configuration = getValue("eureka.service.url", "");
      // 分隔成 List
      if (Strings.isNullOrEmpty(configuration)) {
          return Collections.emptyList();
      }
      return splitter.splitToList(configuration);
  }
  ```

  - Eureka Server **共享**该配置，从而形成 Eureka Server **集群**。

- 基于 Spring Cloud Eureka ，需要在 Maven 的 `pom.xml` 中申明如下依赖：

  ```xml
  <!-- eureka -->
  <dependency>
  	<groupId>org.springframework.cloud</groupId>
  	<artifactId>spring-cloud-starter-eureka</artifactId>
  </dependency>
  <!-- end of eureka -->
  ```

`apollo-adminservice` 和 `apollo-configservice` 项目，引入 `apollo-biz` 项目，启动 Eureka Client ，向 Eureka Server **注册**自己为实例。通过 `.properties` 配置**实例名**：

```properties
// FROM adminservice.properties
spring.application.name= apollo-adminservice

// FROM configservice.properties
spring.application.name= apollo-configservice
```

# 3. Meta Service

在 `apollo-configservice` 项目中，`metaservice` **包**下，看到所有 Meta Service 的类，如下图：

<img src="http://blog-1259650185.cosbj.myqcloud.com/img/202204/07/1649346466.png" alt="Meta Service" style="zoom:50%;" />

## 3.1 ApolloMetaServiceConfig

```java
@EnableAutoConfiguration
@Configuration
@ComponentScan(basePackageClasses = ApolloMetaServiceConfig.class)
public class ApolloMetaServiceConfig {
    @Bean
    public HttpFirewall allowUrlEncodedSlashHttpFirewall() {
        return new DefaultHttpFirewall();
    }
}
```

## 3.2 ServiceController

```java
@RestController
@RequestMapping("/services")
public class ServiceController {

  private final DiscoveryService discoveryService;

  public ServiceController(final DiscoveryService discoveryService) {
    this.discoveryService = discoveryService;
  }

  /**
   * This method always return an empty list as meta service is not used at all
   */
  @Deprecated
  @RequestMapping("/meta")
  public List<ServiceDTO> getMetaService() {
    return Collections.emptyList();
  }

  @RequestMapping("/config")
  public List<ServiceDTO> getConfigService(
      @RequestParam(value = "appId", defaultValue = "") String appId,
      @RequestParam(value = "ip", required = false) String clientIp) {
    return discoveryService.getServiceInstances(ServiceNameConsts.APOLLO_CONFIGSERVICE);
  }

  @RequestMapping("/admin")
  public List<ServiceDTO> getAdminService() {
    return discoveryService.getServiceInstances(ServiceNameConsts.APOLLO_ADMINSERVICE);
  }
}
```

- 提供了**三个** API ，`services/meta`、`services/config`、`services/admin` 获得 Meta Service、Config Service、Admin Service **集群**地址。😈 实际上，`services/meta` 暂时是不可用的，获取不到实例，因为 Meta Service 目前**内嵌**在 Config Service 中。

- 在**每个** API 中，调用 DiscoveryService 调用对应的方法，获取服务集群。

- `com.ctrip.framework.apollo.core.dto.ServiceDTO` ，服务 DTO 。代码如下：

  ```java
  public class ServiceDTO {
  
      /**
       * 应用名
       */
      private String appName;
      /**
       * 实例编号
       */
      private String instanceId;
      /**
       * Home URL
       */
      private String homepageUrl;
  }
  ```

## 3.3 DiscoveryService

```java
public interface DiscoveryService {

  /**
   * @param serviceId the service id
   * @return the service instance list for the specified service id, or an empty list if no service
   * instance available
   */
  List<ServiceDTO> getServiceInstances(String serviceId);
}
```

```java
/**
 * Default discovery service for Eureka
 */
@Service
@ConditionalOnMissingProfile({"kubernetes", "nacos-discovery", "consul-discovery", "zookeeper-discovery", "custom-defined-discovery"})
public class DefaultDiscoveryService implements DiscoveryService {

  private final EurekaClient eurekaClient;

  public DefaultDiscoveryService(final EurekaClient eurekaClient) {
    this.eurekaClient = eurekaClient;
  }

  @Override
  public List<ServiceDTO> getServiceInstances(String serviceId) {
    Application application = eurekaClient.getApplication(serviceId);
    if (application == null || CollectionUtils.isEmpty(application.getInstances())) {
      Tracer.logEvent("Apollo.Discovery.NotFound", serviceId);
      return Collections.emptyList();
    }
    return application.getInstances().stream().map(instanceInfoToServiceDTOFunc)
        .collect(Collectors.toList());
  }

  private static final Function<InstanceInfo, ServiceDTO> instanceInfoToServiceDTOFunc = instance -> {
    ServiceDTO service = new ServiceDTO();
    service.setAppName(instance.getAppName());
    service.setInstanceId(instance.getInstanceId());
    service.setHomepageUrl(instance.getHomePageUrl());
    return service;
  };
}
```

- **每个**方法，调用 `EurekaClient#getApplication(appName)` 方法，获得**服务**集群。

- `com.ctrip.framework.apollo.core.ServiceNameConsts` ，枚举了所有服务的名字。代码如下：

  ```java
  public interface ServiceNameConsts {
  
      String APOLLO_METASERVICE = "apollo-metaservice";
  
      String APOLLO_CONFIGSERVICE = "apollo-configservice";
  
      String APOLLO_ADMINSERVICE = "apollo-adminservice";
  
      String APOLLO_PORTAL = "apollo-portal";
  
  }
  ```

## 3.4 集群

考虑到高可用，Meta Service 必须**集群**。因为 Meta Service 自身扮演了**目录服务**的角色，所以此时不得不引入 Proxy Server 。从选择上，笔者想到的是：

1. Nginx ，目前互联网上最常用的 Proxy Server 。
2. Zuul ，可以和 Eureka 打通，实现注册与发现。

因为 Meta Service 目前并未注册到 Zuul 上，所以相比来说，Nginx 会是更合适的选择。当然，😈 Nginx 自身也是要做高可用的，哈哈哈，这块胖友自己 Google 下解决方案。

**在高性能之前，一切服务节点必须高可用**。任何服务节点的松懈，势必在未来的某个时刻，给我们来一波暴击！！！

# 4. ConfigServiceLocator

在 `apollo-client` 项目中，`com.ctrip.framework.apollo.internals.ConfigServiceLocator` ，Config Service 定位器。

- 初始时，从 Meta Service 获取 Config Service 集群地址进行**缓存**。
- 定时任务，每 **5** 分钟，从 Meta Service 获取 Config Service 集群地址刷新**缓存**。

🙂 代码比较简单，胖友自己查看。代码如下：

```java
public class ConfigServiceLocator {
  private static final Logger logger = DeferredLoggerFactory.getLogger(ConfigServiceLocator.class);
  private HttpClient m_httpClient;
  private ConfigUtil m_configUtil;
  private AtomicReference<List<ServiceDTO>> m_configServices; // ServiceDTO 数组的缓存
  private Type m_responseType;
  private ScheduledExecutorService m_executorService; // 定时任务 ExecutorService
  private static final Joiner.MapJoiner MAP_JOINER = Joiner.on("&").withKeyValueSeparator("=");
  private static final Escaper queryParamEscaper = UrlEscapers.urlFormParameterEscaper();

  /**
   * Create a config service locator.
   */
  public ConfigServiceLocator() {
    List<ServiceDTO> initial = Lists.newArrayList();
    m_configServices = new AtomicReference<>(initial);
    m_responseType = new TypeToken<List<ServiceDTO>>() {
    }.getType();
    m_httpClient = ApolloInjector.getInstance(HttpClient.class);
    m_configUtil = ApolloInjector.getInstance(ConfigUtil.class);
    this.m_executorService = Executors.newScheduledThreadPool(1,
        ApolloThreadFactory.create("ConfigServiceLocator", true));
    initConfigServices();
  }

  private void initConfigServices() {
    // get from run time configurations
    List<ServiceDTO> customizedConfigServices = getCustomizedConfigService();

    if (customizedConfigServices != null) {
      setConfigServices(customizedConfigServices);
      return;
    }

    // update from meta service
    this.tryUpdateConfigServices(); // 初始拉取 Config Service 地址
    this.schedulePeriodicRefresh(); // 创建定时任务，定时拉取 Config Service 地址
  }

  private List<ServiceDTO> getCustomizedConfigService() {
    // 1. Get from System Property
    String configServices = System.getProperty(ApolloClientSystemConsts.APOLLO_CONFIG_SERVICE);
    if (Strings.isNullOrEmpty(configServices)) {
      // 2. Get from OS environment variable
      configServices = System.getenv(ApolloClientSystemConsts.APOLLO_CONFIG_SERVICE_ENVIRONMENT_VARIABLES);
    }
    if (Strings.isNullOrEmpty(configServices)) {
      // 3. Get from server.properties
      configServices = Foundation.server().getProperty(ApolloClientSystemConsts.APOLLO_CONFIG_SERVICE, null);
    }
    if (Strings.isNullOrEmpty(configServices)) {
      // 4. Get from deprecated config
      configServices = getDeprecatedCustomizedConfigService();
    }

    if (Strings.isNullOrEmpty(configServices)) {
      return null;
    }

    logger.info("Located config services from apollo.config-service configuration: {}, will not refresh config services from remote meta service!", configServices);

    // mock service dto list
    String[] configServiceUrls = configServices.split(",");
    List<ServiceDTO> serviceDTOS = Lists.newArrayList();

    for (String configServiceUrl : configServiceUrls) {
      configServiceUrl = configServiceUrl.trim();
      ServiceDTO serviceDTO = new ServiceDTO();
      serviceDTO.setHomepageUrl(configServiceUrl);
      serviceDTO.setAppName(ServiceNameConsts.APOLLO_CONFIGSERVICE);
      serviceDTO.setInstanceId(configServiceUrl);
      serviceDTOS.add(serviceDTO);
    }

    return serviceDTOS;
  }

  @SuppressWarnings("deprecation")
  private String getDeprecatedCustomizedConfigService() {
    // 1. Get from System Property
    String configServices = System.getProperty(ApolloClientSystemConsts.DEPRECATED_APOLLO_CONFIG_SERVICE);
    if (!Strings.isNullOrEmpty(configServices)) {
      DeprecatedPropertyNotifyUtil.warn(ApolloClientSystemConsts.DEPRECATED_APOLLO_CONFIG_SERVICE,
          ApolloClientSystemConsts.APOLLO_CONFIG_SERVICE);
    }
    if (Strings.isNullOrEmpty(configServices)) {
      // 2. Get from OS environment variable
      configServices = System.getenv(ApolloClientSystemConsts.DEPRECATED_APOLLO_CONFIG_SERVICE_ENVIRONMENT_VARIABLES);
      if (!Strings.isNullOrEmpty(configServices)) {
        DeprecatedPropertyNotifyUtil.warn(ApolloClientSystemConsts.DEPRECATED_APOLLO_CONFIG_SERVICE_ENVIRONMENT_VARIABLES,
            ApolloClientSystemConsts.APOLLO_CONFIG_SERVICE_ENVIRONMENT_VARIABLES);
      }
    }
    if (Strings.isNullOrEmpty(configServices)) {
      // 3. Get from server.properties
      configServices = Foundation.server().getProperty(ApolloClientSystemConsts.DEPRECATED_APOLLO_CONFIG_SERVICE, null);
      if (!Strings.isNullOrEmpty(configServices)) {
        DeprecatedPropertyNotifyUtil.warn(ApolloClientSystemConsts.DEPRECATED_APOLLO_CONFIG_SERVICE,
            ApolloClientSystemConsts.APOLLO_CONFIG_SERVICE);
      }
    }
    return configServices;
  }

  /**
   * Get the config service info from remote meta server.
   *
   * @return the services dto
   */
  public List<ServiceDTO> getConfigServices() {
    if (m_configServices.get().isEmpty()) { // 缓存为空，强制拉取
      updateConfigServices();
    }

    return m_configServices.get(); // 返回 ServiceDTO 数组
  }

  private boolean tryUpdateConfigServices() {
    try {
      updateConfigServices();
      return true;
    } catch (Throwable ex) {
      //ignore
    }
    return false;
  }

  private void schedulePeriodicRefresh() {
    this.m_executorService.scheduleAtFixedRate(
        new Runnable() {
          @Override
          public void run() {
            logger.debug("refresh config services");
            Tracer.logEvent("Apollo.MetaService", "periodicRefresh");
            tryUpdateConfigServices();  // 拉取 Config Service 地址
          }
        }, m_configUtil.getRefreshInterval(), m_configUtil.getRefreshInterval(),
        m_configUtil.getRefreshIntervalTimeUnit());
  }

  private synchronized void updateConfigServices() {
    String url = assembleMetaServiceUrl(); // 拼接请求 Meta Service URL

    HttpRequest request = new HttpRequest(url);
    int maxRetries = 2; // 重试两次
    Throwable exception = null;
    // 循环请求 Meta Service ，获取 Config Service 地址
    for (int i = 0; i < maxRetries; i++) {
      Transaction transaction = Tracer.newTransaction("Apollo.MetaService", "getConfigService");
      transaction.addData("Url", url);
      try {
        HttpResponse<List<ServiceDTO>> response = m_httpClient.doGet(request, m_responseType); // 请求
        transaction.setStatus(Transaction.SUCCESS);
        List<ServiceDTO> services = response.getBody(); // 获得结果 ServiceDTO 数组
        if (services == null || services.isEmpty()) { // 获得结果为空，重新请求
          logConfigService("Empty response!");
          continue;
        }
        setConfigServices(services); // 更新缓存
        return;
      } catch (Throwable ex) {
        Tracer.logEvent("ApolloConfigException", ExceptionUtil.getDetailMessage(ex));
        transaction.setStatus(ex);
        exception = ex; // 暂存一下异常
      } finally {
        transaction.complete();
      }
      // 请求失败，sleep 等待下次重试
      try {
        m_configUtil.getOnErrorRetryIntervalTimeUnit().sleep(m_configUtil.getOnErrorRetryInterval());
      } catch (InterruptedException ex) {
        //ignore
      }
    }
    // 请求全部失败，抛出 ApolloConfigException 异常
    throw new ApolloConfigException(
        String.format("Get config services failed from %s", url), exception);
  }

  private void setConfigServices(List<ServiceDTO> services) {
    m_configServices.set(services);
    logConfigServices(services); // 打印结果 ServiceDTO 数组
  }

  private String assembleMetaServiceUrl() {
    String domainName = m_configUtil.getMetaServerDomainName();
    String appId = m_configUtil.getAppId();
    String localIp = m_configUtil.getLocalIp();
    // 参数集合
    Map<String, String> queryParams = Maps.newHashMap();
    queryParams.put("appId", queryParamEscaper.escape(appId));
    if (!Strings.isNullOrEmpty(localIp)) {
      queryParams.put("ip", queryParamEscaper.escape(localIp));
    }

    return domainName + "/services/config?" + MAP_JOINER.join(queryParams);
  }

  private void logConfigServices(List<ServiceDTO> serviceDtos) {
    for (ServiceDTO serviceDto : serviceDtos) {
      logConfigService(serviceDto.getHomepageUrl());
    }
  }

  private void logConfigService(String serviceUrl) {
    Tracer.logEvent("Apollo.Config.Services", serviceUrl);
  }
}
```

# 5. AdminServiceAddressLocator

在 `apollo-portal` 项目中，`com.ctrip.framework.apollo.portal.component.AdminServiceAddressLocator` ，Admin Service 定位器。

- 初始时，创建延迟 **1 秒**的任务，从 Meta Service 获取 Config Service 集群地址进行**缓存**。
- 获取**成功**时，创建延迟 **5 分钟**的任务，从 Meta Service 获取 Config Service 集群地址刷新**缓存**。
- 获取**失败**时，创建延迟 **10 秒**的任务，从 Meta Service 获取 Config Service 集群地址刷新**缓存**。

🙂 代码比较简单，胖友自己查看。代码如下：

```java
@Component
public class AdminServiceAddressLocator {

  private static final long NORMAL_REFRESH_INTERVAL = 5 * 60 * 1000;
  private static final long OFFLINE_REFRESH_INTERVAL = 10 * 1000;
  private static final int RETRY_TIMES = 3;
  private static final String ADMIN_SERVICE_URL_PATH = "/services/admin";
  private static final Logger logger = LoggerFactory.getLogger(AdminServiceAddressLocator.class);

  private ScheduledExecutorService refreshServiceAddressService; // 定时任务 ExecutorService
  private RestTemplate restTemplate;
  private List<Env> allEnvs; // Env 数组
  private Map<Env, List<ServiceDTO>> cache = new ConcurrentHashMap<>(); // List<ServiceDTO 缓存 Map。KEY：ENV

  private final PortalSettings portalSettings;
  private final RestTemplateFactory restTemplateFactory;
  private final PortalMetaDomainService portalMetaDomainService;

  public AdminServiceAddressLocator(
      final HttpMessageConverters httpMessageConverters,
      final PortalSettings portalSettings,
      final RestTemplateFactory restTemplateFactory,
      final PortalMetaDomainService portalMetaDomainService
  ) {
    this.portalSettings = portalSettings;
    this.restTemplateFactory = restTemplateFactory;
    this.portalMetaDomainService = portalMetaDomainService;
  }

  @PostConstruct
  public void init() {
    allEnvs = portalSettings.getAllEnvs(); // 获得 Env 数组

    //init restTemplate
    restTemplate = restTemplateFactory.getObject();

    refreshServiceAddressService = // 创建 ScheduledExecutorService
        Executors.newScheduledThreadPool(1, ApolloThreadFactory.create("ServiceLocator", true));
    // 创建延迟任务，1 秒后拉取 Admin Service 地址
    refreshServiceAddressService.schedule(new RefreshAdminServerAddressTask(), 1, TimeUnit.MILLISECONDS);
  }

  public List<ServiceDTO> getServiceList(Env env) {
    List<ServiceDTO> services = cache.get(env); // 从缓存中获得 ServiceDTO 数组
    if (CollectionUtils.isEmpty(services)) { // 若不存在，直接返回空数组。这点和 ConfigServiceLocator 不同
      return Collections.emptyList();
    }
    List<ServiceDTO> randomConfigServices = Lists.newArrayList(services);
    Collections.shuffle(randomConfigServices); // 打乱 ServiceDTO 数组，返回。实现 Client 级的负载均衡
    return randomConfigServices;
  }

  //maintain admin server address
  private class RefreshAdminServerAddressTask implements Runnable {

    @Override
    public void run() {
      boolean refreshSuccess = true;
      //refresh fail if get any env address fail
      for (Env env : allEnvs) {  // 循环多个 Env ，请求对应的 Meta Service ，获得 Admin Service 集群地址
        boolean currentEnvRefreshResult = refreshServerAddressCache(env);
        refreshSuccess = refreshSuccess && currentEnvRefreshResult;
      }

      if (refreshSuccess) { // 若刷新成功，则创建定时任务，5 分钟后执行
        refreshServiceAddressService
            .schedule(new RefreshAdminServerAddressTask(), NORMAL_REFRESH_INTERVAL, TimeUnit.MILLISECONDS);
      } else { // 若刷新失败，则创建定时任务，10 秒后执行
        refreshServiceAddressService
            .schedule(new RefreshAdminServerAddressTask(), OFFLINE_REFRESH_INTERVAL, TimeUnit.MILLISECONDS);
      }
    }
  }

  private boolean refreshServerAddressCache(Env env) {

    for (int i = 0; i < RETRY_TIMES; i++) {

      try {
        ServiceDTO[] services = getAdminServerAddress(env); // 请求 Meta Service ，获得 Admin Service 集群地址
        if (services == null || services.length == 0) { // 获得结果为空，continue ，继续执行下一次请求
          continue;
        }
        cache.put(env, Arrays.asList(services)); // 更新缓存
        return true; // 返回获取成功
      } catch (Throwable e) {
        logger.error(String.format("Get admin server address from meta server failed. env: %s, meta server address:%s",
                                   env, portalMetaDomainService.getDomain(env)), e);
        Tracer
            .logError(String.format("Get admin server address from meta server failed. env: %s, meta server address:%s",
                                    env, portalMetaDomainService.getDomain(env)), e);
      }
    }
    return false; // 返回获取失败
  }

  private ServiceDTO[] getAdminServerAddress(Env env) {
    String domainName = portalMetaDomainService.getDomain(env);
    String url = domainName + ADMIN_SERVICE_URL_PATH;
    return restTemplate.getForObject(url, ServiceDTO[].class);
  }


}
```

## 5.1 MetaDomainConsts

`com.ctrip.framework.apollo.core.MetaDomainConsts` ，Meta Service 多**环境**的地址枚举类。代码如下：

```java
/**
 * The meta domain will load the meta server from System environment first, if not exist, will load
 * from apollo-env.properties. If neither exists, will load the default meta url.
 * <p>
 * Currently, apollo supports local/dev/fat/uat/lpt/pro environments.
 */
public class MetaDomainConsts {

    private static Map<Env, Object> domains = new HashMap<>();

    public static final String DEFAULT_META_URL = "http://config.local";

    static {
        // 读取配置文件到 Properties 中
        Properties prop = new Properties();
        prop = ResourceUtils.readConfigFile("apollo-env.properties", prop);
        // 获得系统 Properties
        Properties env = System.getProperties();
        // 添加到 domains 中
        // 优先级，env > prop
        domains.put(Env.LOCAL, env.getProperty("local_meta", prop.getProperty("local.meta", DEFAULT_META_URL)));
        domains.put(Env.DEV, env.getProperty("dev_meta", prop.getProperty("dev.meta", DEFAULT_META_URL)));
        domains.put(Env.FAT, env.getProperty("fat_meta", prop.getProperty("fat.meta", DEFAULT_META_URL)));
        domains.put(Env.UAT, env.getProperty("uat_meta", prop.getProperty("uat.meta", DEFAULT_META_URL)));
        domains.put(Env.LPT, env.getProperty("lpt_meta", prop.getProperty("lpt.meta", DEFAULT_META_URL)));
        domains.put(Env.PRO, env.getProperty("pro_meta", prop.getProperty("pro.meta", DEFAULT_META_URL)));
    }

    public static String getDomain(Env env) {
        return String.valueOf(domains.get(env));
    }

}
```

- 具体的读取**顺序**和说明，见**英文注释**说明。🙂 英语和我一样有非常大的进步空的同学，可以使用有道词典翻译。

## 5.2 Env

`com.ctrip.framework.apollo.core.enums.Env` ，环境**枚举**。代码如下：

```java
/**
 * Here is the brief description for all the predefined environments:
 * <ul>
 * <li>LOCAL: Local Development environment, assume you are working at the beach with no network access</li>
 * <li>DEV: Development environment</li>
 * <li>FWS: Feature Web Service Test environment</li>
 * <li>FAT: Feature Acceptance Test environment</li>
 * <li>UAT: User Acceptance Test environment</li>
 * <li>LPT: Load and Performance Test environment</li>
 * <li>PRO: Production environment</li>
 * <li>TOOLS: Tooling environment, a special area in production environment which allows
 * access to test environment, e.g. Apollo Portal should be deployed in tools environment</li>
 * </ul>
 *
 * @author Jason Song(song_s@ctrip.com)
 */
public enum Env {

    LOCAL, DEV, FWS, FAT, UAT, LPT, PRO, TOOLS;

    public static Env fromString(String env) {
        Env environment = EnvUtils.transformEnv(env);
        Preconditions.checkArgument(environment != null, String.format("Env %s is invalid", env));
        return environment;
    }

}
```

😎 前面一直忘记对 Env 介绍，所以有些奇怪的放在这个位置。主要目的是，我们可以参考携程对**服务环境**的命名和定义。



# 参考

[Apollo 源码解析 —— 服务的注册与发现](https://www.iocoder.cn/Apollo/service-register-discovery/)
