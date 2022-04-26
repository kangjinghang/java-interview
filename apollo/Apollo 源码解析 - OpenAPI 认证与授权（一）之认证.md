# 1. 概述

> 老艿艿：本系列假定胖友已经阅读过 [《Apollo 官方 wiki 文档》](https://github.com/ctripcorp/apollo/wiki/) ，特别是 [《Apollo 开放平台》](https://github.com/ctripcorp/apollo/wiki/Apollo开放平台) 。

考虑到 [Portal 的认证与授权](https://www.iocoder.cn/Apollo/openapi-auth-1/#) 分成了两篇，所以本文分享 OpenAPI 的认证与授权， **侧重在认证部分**。

在 [《Apollo 开放平台》](https://github.com/ctripcorp/apollo/wiki/Apollo开放平台) 文档的开头：

> Apollo 提供了一套的 Http REST 接口，使第三方应用能够自己管理配置。虽然 Apollo 系统本身提供了 Portal 来管理配置，但是在有些情景下，应用需要通过程序去管理配置。

- OpenAPI 和 Portal 都在 `apollo-portal` 项目中，但是他们是**两套** API ，包括 `package` 都是两个不同的，如下图所示：<img src="http://blog-1259650185.cosbj.myqcloud.com/img/202204/07/1649314893.png" alt="项目结构" style="zoom: 67%;" />

# 3. 实体

## 3.1 Consumer

**Consumer** 表，对应实体 `com.ctrip.framework.apollo.openapi.entity.Consumer` ，代码如下：

```java
@Entity
@Table(name = "Consumer")
@SQLDelete(sql = "Update Consumer set IsDeleted = 1, DeletedAt = ROUND(UNIX_TIMESTAMP(NOW(4))*1000) where Id = ?")
@Where(clause = "isDeleted = 0")
public class Consumer extends BaseEntity {

  @Column(name = "Name", nullable = false)
  private String name; // 应用名称

  @Column(name = "AppId", nullable = false)
  private String appId; // 应用编号。注意，和 {@link com.ctrip.framework.apollo.common.entity.App} 不是一个东西

  @Column(name = "OrgId", nullable = false)
  private String orgId; // 部门编号

  @Column(name = "OrgName", nullable = false)
  private String orgName; // 部门名

  @Column(name = "OwnerName", nullable = false)
  private String ownerName; // 项目负责人名，使用 {@link com.ctrip.framework.apollo.portal.entity.po.UserPO#username}

  @Column(name = "OwnerEmail", nullable = false)
  private String ownerEmail; //  项目负责人邮箱，使用 {@link com.ctrip.framework.apollo.portal.entity.po.UserPO#email}

  // ... 省略其他接口和属性
}
```

- 字段比较简单，胖友自己看注释。
- 例子如下图：![例子](http://blog-1259650185.cosbj.myqcloud.com/img/202204/07/1649315021.png)

## 3.2 ConsumerToken

**ConsumerToken** 表，对应实体 `com.ctrip.framework.apollo.openapi.entity.ConsumerToken` ，代码如下：

```java
@Entity
@Table(name = "ConsumerToken")
@SQLDelete(sql = "Update ConsumerToken set IsDeleted = 1, DeletedAt = ROUND(UNIX_TIMESTAMP(NOW(4))*1000) where Id = ?")
@Where(clause = "isDeleted = 0")
public class ConsumerToken extends BaseEntity {
  @Column(name = "ConsumerId", nullable = false)
  private long consumerId; // 第三方应用编号，使用 {@link Consumer#id}

  @Column(name = "token", nullable = false)
  private String token; // Token

  @Column(name = "Expires", nullable = false)
  private Date expires; // 过期时间

  // ... 省略其他接口和属性
}
```

- `consumerId` 字段，第三方应用编号，指向对应的 Consumer 记录。ConsumerToken 和 Consumer 是**多对一**的关系。

- `token` 字段，Token 。

  - 调用 OpenAPI 时，放在请求 Header `"Authorization"` 中，作为身份标识。

  - 通过 `ConsumerService#generateToken(consumerAppId, generationTime, consumerTokenSalt)` 方法生成，代码如下：

    ```java
    String generateToken(String consumerAppId, Date generationTime, String consumerTokenSalt) {
        return Hashing.sha1().hashString(KEY_JOINER.join(consumerAppId, TIMESTAMP_FORMAT.format(generationTime), consumerTokenSalt), Charsets.UTF_8).toString();
    }
    ```

- `expires` 字段，过期时间。

- 例子如下图：![例子](http://blog-1259650185.cosbj.myqcloud.com/img/202204/07/1649315101.png)

## 3.3 ConsumerAudit

**ConsumerAudit** 表，对应实体 `com.ctrip.framework.apollo.openapi.entity.ConsumerAudit` ，代码如下：

> ConsumerAudit 和 Audit 功能类似，我们在 [《Apollo 源码解析 —— Config Service 操作审计日志 Audit》](http://www.iocoder.cn/Apollo/config-service-audit/?self) 中已经分享。

````java
@Entity
@Table(name = "ConsumerAudit")
public class ConsumerAudit {
  @Id
  @GeneratedValue(strategy = GenerationType.IDENTITY)
  @Column(name = "Id")
  private long id; // 日志编号，自增

  @Column(name = "ConsumerId", nullable = false)
  private long consumerId; // 第三方应用编号，使用 {@link Consumer#id}

  @Column(name = "Uri", nullable = false)
  private String uri; // 请求 URI

  @Column(name = "Method", nullable = false)
  private String method; // 请求 Method

  @Column(name = "DataChange_CreatedTime")
  private Date dataChangeCreatedTime; // 数据创建时间

  @Column(name = "DataChange_LastTime")
  private Date dataChangeLastModifiedTime; // 数据最后更新时间

  @PrePersist
  protected void prePersist() {
    if (this.dataChangeCreatedTime == null) {
      this.dataChangeCreatedTime = new Date();
    }
    if (this.dataChangeLastModifiedTime == null) {
      dataChangeLastModifiedTime = this.dataChangeCreatedTime;
    }
  }

  // ... 省略其他接口和属性
}
````

- 字段比较简单，胖友自己看注释。
- 如果胖友希望更加详细，可以添加如下字段：
  - `token` 字段，请求时的 Token 。
  - `params` 字段，请求参数。
  - `responseStatus` 字段， 响应状态码。
  - `ip` 字段，请求 IP 。
  - `ua` 字段，请求 User-Agent 。

# 4. ConsumerAuthenticationFilter

`com.ctrip.framework.apollo.openapi.filter.ConsumerAuthenticationFilter` ，实现 Filter 接口，OpenAPI **认证**( Authentication )过滤器。代码如下：

```java
public class ConsumerAuthenticationFilter implements Filter {
  private final ConsumerAuthUtil consumerAuthUtil;
  private final ConsumerAuditUtil consumerAuditUtil;

  public ConsumerAuthenticationFilter(ConsumerAuthUtil consumerAuthUtil, ConsumerAuditUtil consumerAuditUtil) {
    this.consumerAuthUtil = consumerAuthUtil;
    this.consumerAuditUtil = consumerAuditUtil;
  }

  @Override
  public void init(FilterConfig filterConfig) throws ServletException {
    //nothing
  }

  @Override
  public void doFilter(ServletRequest req, ServletResponse resp, FilterChain chain) throws
      IOException, ServletException {
    HttpServletRequest request = (HttpServletRequest) req;
    HttpServletResponse response = (HttpServletResponse) resp;
    // 从请求 Header 中，获得 token
    String token = request.getHeader(HttpHeaders.AUTHORIZATION);
    // 获得 Consumer 编号
    Long consumerId = consumerAuthUtil.getConsumerId(token);
    // 若不存在，返回错误状态码 401
    if (consumerId == null) {
      response.sendError(HttpServletResponse.SC_UNAUTHORIZED, "Unauthorized");
      return;
    }
    // 存储 Consumer 编号到请求中
    consumerAuthUtil.storeConsumerId(request, consumerId);
    consumerAuditUtil.audit(request, consumerId); // 记录 ConsumerAudit 记录
    // 继续过滤器
    chain.doFilter(req, resp);
  }

  @Override
  public void destroy() {
    //nothing
  }
}
```

- ConsumerToken 相关
  - 第 22 行：从**请求 Header** `"Authorization"` 中，获得作为身份标识的 Token 。
  - 第 24 行：调用 `ConsumerAuthUtil#getConsumerId(token)` 方法，获得 Token 对应的 **Consumer 编号**。详细解析，在 [「5.1 ConsumerAuthUtil」](https://www.iocoder.cn/Apollo/openapi-auth-1/#) 中。
  - 第 25 至 29 行：若 Consumer 不存在时，返回错误状态码 **401** 。
  - 第 31 行：调用 `ConsumerAuthUtil#storeConsumerId(request, consumerId)` 方法，存储 **Consumer 编号**到 Request 中。
- ConsumerAudit 相关
  - 第 33 行：调用 `ConsumerAuditUtil#audit(request, consumerId)` 方法，记录 ConsumerAudit 记录。详细解析，在 [「5.2 ConsumerAuditUtil」](https://www.iocoder.cn/Apollo/openapi-auth-1/#) 中。

## 4.1 AuthFilterConfiguration

`com.ctrip.framework.apollo.portal.spi.configuration.AuthFilterConfiguration` ，**AuthFilterConfigurationFilter** Spring Java 配置。代码如下：

```java
@Configuration
public class AuthFilterConfiguration {

    @Bean
    public FilterRegistrationBean openApiAuthenticationFilter(ConsumerAuthUtil consumerAuthUtil, ConsumerAuditUtil consumerAuditUtil) {
        FilterRegistrationBean openApiFilter = new FilterRegistrationBean();

        openApiFilter.setFilter(new ConsumerAuthenticationFilter(consumerAuthUtil, consumerAuditUtil));
        openApiFilter.addUrlPatterns("/openapi/*"); // 匹配 `"/openapi/*"` 路径

        return openApiFilter;
    }

}
```

- 匹配 `"/openapi/*"` 路径。

# 5. Util

## 5.1 ConsumerAuthUtil

```java
@Service
public class ConsumerAuthUtil {
  static final String CONSUMER_ID = "ApolloConsumerId"; // Request Attribute —— Consumer 编号
  private final ConsumerService consumerService;

  public ConsumerAuthUtil(final ConsumerService consumerService) {
    this.consumerService = consumerService;
  }
  // 获得 Token 获得对应的 Consumer 编号
  public Long getConsumerId(String token) {
    return consumerService.getConsumerIdByToken(token);
  }
  // 设置 Consumer 编号到 Request
  public void storeConsumerId(HttpServletRequest request, Long consumerId) {
    request.setAttribute(CONSUMER_ID, consumerId);
  }
  // 获得 Consumer 编号从 Request
  public long retrieveConsumerId(HttpServletRequest request) {
    Object value = request.getAttribute(CONSUMER_ID);

    try {
      return Long.parseLong(value.toString());
    } catch (Throwable ex) {
      throw new IllegalStateException("No consumer id!", ex);
    }
  }
}
```

- 代码比较简单，胖友自己阅读理解。

## 5.2 ConsumerAuditUtil

`com.ctrip.framework.apollo.openapi.util.ConsumerAuditUtill` ，实现 InitializingBean 接口，ConsumerAudit 工具类。代码如下：

```java
@Service
public class ConsumerAuditUtil implements InitializingBean {
  private static final int CONSUMER_AUDIT_MAX_SIZE = 10000;
  private final BlockingQueue<ConsumerAudit> audits = Queues.newLinkedBlockingQueue(CONSUMER_AUDIT_MAX_SIZE); // 队列
  private final ExecutorService auditExecutorService; // ExecutorService 对象
  private final AtomicBoolean auditStopped; // 是否停止
  private static final int BATCH_SIZE = 100; // 批任务 ConsumerAudit 数量

  // ConsumerAuditUtilTest used reflection to set BATCH_TIMEOUT and BATCH_TIMEUNIT, so without `final` now
  private static long BATCH_TIMEOUT = 5;  // 批任务 ConsumerAudit 等待超时时间
  private static TimeUnit BATCH_TIMEUNIT = TimeUnit.SECONDS; // {@link #BATCH_TIMEOUT} 单位

  private final ConsumerService consumerService;

  public ConsumerAuditUtil(final ConsumerService consumerService) {
    this.consumerService = consumerService;
    auditExecutorService = Executors.newSingleThreadExecutor(
        ApolloThreadFactory.create("ConsumerAuditUtil", true));
    auditStopped = new AtomicBoolean(false);
  }

  public boolean audit(HttpServletRequest request, long consumerId) {
    //ignore GET request
    if ("GET".equalsIgnoreCase(request.getMethod())) { // 忽略 GET 请求
      return true;
    }
    String uri = request.getRequestURI(); // 组装 URI
    if (!Strings.isNullOrEmpty(request.getQueryString())) {
      uri += "?" + request.getQueryString();
    }
    // 创建 ConsumerAudit 对象
    ConsumerAudit consumerAudit = new ConsumerAudit();
    Date now = new Date();
    consumerAudit.setConsumerId(consumerId);
    consumerAudit.setUri(uri);
    consumerAudit.setMethod(request.getMethod());
    consumerAudit.setDataChangeCreatedTime(now);
    consumerAudit.setDataChangeLastModifiedTime(now);

    //throw away audits if exceeds the max size // 添加到队列
    return this.audits.offer(consumerAudit);
  }

  @Override
  public void afterPropertiesSet() throws Exception {
    auditExecutorService.submit(() -> {
      while (!auditStopped.get() && !Thread.currentThread().isInterrupted()) { // 循环【批任务】，直到停止
        List<ConsumerAudit> toAudit = Lists.newArrayList();
        try {
          Queues.drain(audits, toAudit, BATCH_SIZE, BATCH_TIMEOUT, BATCH_TIMEUNIT);  // 获得 ConsumerAudit 批任务，直到到达上限，或者超时
          if (!toAudit.isEmpty()) {
            consumerService.createConsumerAudits(toAudit);
          }
        } catch (Throwable ex) {
          Tracer.logError(ex);
        }
      }
    });
  }

  public void stopAudit() {
    auditStopped.set(true);
  }
}
```

- `#audit(request, consumerId)` 方法，创建 ConsumerAudit 对象，添加到**队列** `audits` 中。
- `#afterPropertiesSet()`方法，初始化**后台**任务。该任务，调用`Queues#drain(BlockingQueue, buffer, numElements, timeout, TimeUnit)`方法，获得 ConsumerAudit 批任务，直到**到达上限(**`BATCH_SIZE`)，或者**超时**(`BATCH_TIMEOUT`) 。若获得到任务，调用`ConsumerService@createConsumerAudit(Iterable<ConsumerAudit>)`方法，**批量**保存到数据库中。
  - Google Guava **Queues** ，感兴趣的胖友，可以自己去研究下。
  - Eureka Server 集群同步实例，也有相同处理。

# 6. ConsumerService

`com.ctrip.framework.apollo.openapi.service.ConsumerService` ，提供 Consumer、ConsumerToken、ConsumerAudit、ConsumerRole 相关的 **Service** 逻辑。

```java
@Service
public class ConsumerService {

  private static final FastDateFormat TIMESTAMP_FORMAT = FastDateFormat.getInstance("yyyyMMddHHmmss");
  private static final Joiner KEY_JOINER = Joiner.on("|");

  private final UserInfoHolder userInfoHolder;
  private final ConsumerTokenRepository consumerTokenRepository;
  private final ConsumerRepository consumerRepository;
  private final ConsumerAuditRepository consumerAuditRepository;
  private final ConsumerRoleRepository consumerRoleRepository;
  private final PortalConfig portalConfig;
  private final RolePermissionService rolePermissionService;
  private final UserService userService;
  private final RoleRepository roleRepository;

  public ConsumerService(
      final UserInfoHolder userInfoHolder,
      final ConsumerTokenRepository consumerTokenRepository,
      final ConsumerRepository consumerRepository,
      final ConsumerAuditRepository consumerAuditRepository,
      final ConsumerRoleRepository consumerRoleRepository,
      final PortalConfig portalConfig,
      final RolePermissionService rolePermissionService,
      final UserService userService,
      final RoleRepository roleRepository) {
    this.userInfoHolder = userInfoHolder;
    this.consumerTokenRepository = consumerTokenRepository;
    this.consumerRepository = consumerRepository;
    this.consumerAuditRepository = consumerAuditRepository;
    this.consumerRoleRepository = consumerRoleRepository;
    this.portalConfig = portalConfig;
    this.rolePermissionService = rolePermissionService;
    this.userService = userService;
    this.roleRepository = roleRepository;
  }
  // ... 省略其他接口和属性
}
```

## 6.2 createConsumer

`#createConsumer(Consumer)` 方法，保存 Consumer 到数据库中。代码如下：

```java
public Consumer createConsumer(Consumer consumer) {
  String appId = consumer.getAppId();
  // 校验 appId 对应的 Consumer 不存在
  Consumer managedConsumer = consumerRepository.findByAppId(appId);
  if (managedConsumer != null) {
    throw new BadRequestException("Consumer already exist");
  }
  // 校验 ownerName 对应的 UserInfo 存在
  String ownerName = consumer.getOwnerName();
  UserInfo owner = userService.findByUserId(ownerName);
  if (owner == null) {
    throw new BadRequestException(String.format("User does not exist. UserId = %s", ownerName));
  }
  consumer.setOwnerEmail(owner.getEmail());
  // 设置 Consumer 的创建和最后修改人为当前管理员
  String operator = userInfoHolder.getUser().getUserId();
  consumer.setDataChangeCreatedBy(operator);
  consumer.setDataChangeLastModifiedBy(operator);
  // 保存 Consumer 到数据库中
  return consumerRepository.save(consumer);
}
```

## 6.3 generateAndSaveConsumerToken

`#generateAndSaveConsumerToken(Consumer, expires)` 方法，基于 Consumer 对象，创建其对应的 ConsumerToken 对象，并保存到数据库中。代码如下：

```java
public ConsumerToken generateAndSaveConsumerToken(Consumer consumer, Date expires) {
  Preconditions.checkArgument(consumer != null, "Consumer can not be null");
  // 生成 ConsumerToken 对象
  ConsumerToken consumerToken = generateConsumerToken(consumer, expires);
  consumerToken.setId(0);
  // 保存 ConsumerToken 到数据库中
  return consumerTokenRepository.save(consumerToken);
}
```

- 调用 `#generateConsumerToken(Consumer, expires)` 方法，基于 Consumer 对象，创建其对应的 ConsumerToken 对象。代码如下：

  ```java
  private ConsumerToken generateConsumerToken(Consumer consumer, Date expires) {
    long consumerId = consumer.getId();
    String createdBy = userInfoHolder.getUser().getUserId();
    Date createdTime = new Date();
    // 创建 ConsumerToken
    ConsumerToken consumerToken = new ConsumerToken();
    consumerToken.setConsumerId(consumerId);
    consumerToken.setExpires(expires);
    consumerToken.setDataChangeCreatedBy(createdBy);
    consumerToken.setDataChangeCreatedTime(createdTime);
    consumerToken.setDataChangeLastModifiedBy(createdBy);
    consumerToken.setDataChangeLastModifiedTime(createdTime);
    // 生成 ConsumerToken 的 token
    generateAndEnrichToken(consumer, consumerToken);
  
    return consumerToken;
  }
  ```

- 调用 `#generateAndEnrichToken(Consumer, ConsumerToken)` 方法，生成 ConsumerToken 的 `token` 。代码如下：

  ```java
  void generateAndEnrichToken(Consumer consumer, ConsumerToken consumerToken) {
  
    Preconditions.checkArgument(consumer != null);
    // 设置创建时间
    if (consumerToken.getDataChangeCreatedTime() == null) {
      consumerToken.setDataChangeCreatedTime(new Date());
    }
    consumerToken.setToken(generateToken(consumer.getAppId(), consumerToken
        .getDataChangeCreatedTime(), portalConfig.consumerTokenSalt())); // 生成 ConsumerToken 的 token
  }
  ```

## 6.4 其他方法

在 ConsumerService 中，还有授权相关的方法，在下一篇文章分享。

- `#assignNamespaceRoleToConsumer(token, appId, namespaceName)` 方法
- `#assignAppRoleToConsumer(token, appId)` 方法

# 7. ConsumerController

在 `apollo-portal` 项目中，`com.ctrip.framework.apollo.portal.controller.ConsumerController` ，提供 Consumer、ConsumerToken、ConsumerAudit 相关的 **API** 。

在**创建第三方应用**的界面中，点击【创建】按钮，调用**创建 Consumer 的 API** 。

![创建第三方应用](http://blog-1259650185.cosbj.myqcloud.com/img/202204/07/1649316729.png)

代码如下：

```java
@Transactional
@PreAuthorize(value = "@permissionValidator.isSuperAdmin()")
@PostMapping(value = "/consumers")
public ConsumerToken createConsumer(@RequestBody Consumer consumer,
                                    @RequestParam(value = "expires", required = false)
                                    @DateTimeFormat(pattern = "yyyyMMddHHmmss") Date
                                        expires) {
  // 校验非空
  if (StringUtils.isContainEmpty(consumer.getAppId(), consumer.getName(),
                                 consumer.getOwnerName(), consumer.getOrgId())) {
    throw new BadRequestException("Params(appId、name、ownerName、orgId) can not be empty.");
  }
  // 创建 Consumer 对象，并保存到数据库中
  Consumer createdConsumer = consumerService.createConsumer(consumer);
  // 创建 ConsumerToken 对象，并保存到数据库中
  if (Objects.isNull(expires)) {
    expires = DEFAULT_EXPIRES;
  }

  return consumerService.generateAndSaveConsumerToken(createdConsumer, expires);
}
```

- **POST `/consumers` 接口**，Request Body 传递 **JSON** 对象。
- `@PreAuthorize(...)` 注解，调用 `PermissionValidator#isSuperAdmin(a)` 方法，校验是否超级管理员。
- 调用 ConsumerService ，创建 **Consumer** 和 **ConsumerToken** 对象，并保存到数据库中。



# 参考

[Apollo 源码解析 —— OpenAPI 认证与授权（一）之认证](https://www.iocoder.cn/Apollo/openapi-auth-1/)
