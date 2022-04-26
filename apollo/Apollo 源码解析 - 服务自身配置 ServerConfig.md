# 1. 概述

> 老艿艿：本系列假定胖友已经阅读过 [《Apollo 官方 wiki 文档》](https://github.com/ctripcorp/apollo/wiki/)

Portal、Config Service、Admin Service 等等服务，**自身需要配置服务**。一种实现是，基于配置文件，简单方便。但是，不方便统一管理和共享。因此，Apollo 基于**数据库**实现类配置表 ServerConfig 。

> 老艿艿：如果胖友的系统暂时没有使用配置中心，
>
> - 可以基于**数据库**实现类配置表 ServerConfig ，实现业务系统里面的配置功能，短平快。
> - 配合 Redis 的 PUB/SUB 特性，实现配置更新的实时通知。

本文涉及的类如下图所示：

<img src="http://blog-1259650185.cosbj.myqcloud.com/img/202204/06/1649256613.png" alt="类图" style="zoom: 50%;" />

# 2. ServerConfig

## 2.1 Portal 侧

在 `apollo-portal` 项目中，`com.ctrip.framework.apollo.portal.entity.po.ServerConfig` ，继承 BaseEntity 抽象类，ServerConfig **实体**，服务器 KV 配置项。代码如下：

```java
@Entity
@Table(name = "ServerConfig")
@SQLDelete(sql = "Update ServerConfig set IsDeleted = 1, DeletedAt = ROUND(UNIX_TIMESTAMP(NOW(4))*1000) where Id = ?")
@Where(clause = "isDeleted = 0")
public class ServerConfig extends BaseEntity {
  @NotBlank(message = "ServerConfig.Key cannot be blank")
  @Column(name = "Key", nullable = false)
  private String key; // KEY

  @NotBlank(message = "ServerConfig.Value cannot be blank")
  @Column(name = "Value", nullable = false)
  private String value; // VALUE

  @Column(name = "Comment", nullable = false)
  private String comment; // 备注

}
```

- **KV** 结构，一个配置项，一条记录。例如：![例子](http://blog-1259650185.cosbj.myqcloud.com/img/202204/06/1649256785.png)

## 2.2 Config 侧

在 `apollo-biz` 项目中，`com.ctrip.framework.apollo.biz.entity.ServerConfig` ，继承 BaseEntity 抽象类，ServerConfig **实体**，服务器 KV 配置项。代码如下：

```java
@Entity
@Table(name = "ServerConfig")
@SQLDelete(sql = "Update ServerConfig set IsDeleted = 1, DeletedAt = ROUND(UNIX_TIMESTAMP(NOW(4))*1000) where Id = ?")
@Where(clause = "isDeleted = 0")
public class ServerConfig extends BaseEntity {
  @Column(name = "Key", nullable = false)
  private String key; // KEY

  @Column(name = "Cluster", nullable = false)
  private String cluster; // Cluster 名

  @Column(name = "Value", nullable = false)
  private String value; // VALUE

  @Column(name = "Comment", nullable = false)
  private String comment; // 备注

}
```

- 提供给 Config Service、Admin Service 服务使用。

- 相比多了 `cluster` 属性，用于**多机房**部署使用。官方说明如下：

  > 在多机房部署时，往往希望 config service 和 admin service 只向同机房的 eureka 注册，要实现这个效果，需要利用 ServerConfig 表中的 `cluster` 字段。
  >
  > config service 和 admin service 会读取所在机器的 `/opt/settings/server.properties`（Mac/Linux）或 `C:\opt\settings\server.properties`（Windows）中的 `idc` 属性，如果该 idc 有对应的`eureka.service.url` 配置，那么就会向该机房的 eureka 注册 。

  - 默认情况下，使用 `"default"` 集群。

- **KV** 结构，一个配置项，一条记录。例如：![例子](http://blog-1259650185.cosbj.myqcloud.com/img/202204/06/1649257110.png)

# 3. RefreshablePropertySource

`com.ctrip.framework.apollo.common.config.RefreshablePropertySource` ，实现 `org.springframework.core.env.MapPropertySource` 类，**可刷新**的 PropertySource 抽象类。代码如下：

```java
public abstract class RefreshablePropertySource extends MapPropertySource {

    public RefreshablePropertySource(String name, Map<String, Object> source) {
        super(name, source);
    }

    @Override
    public Object getProperty(String name) {
        return this.source.get(name);
    }

    /**
     * refresh property
     */
    protected abstract void refresh();

}
```

- Spring PropertySource 体系，在 [《【Spring4揭秘 基础2】PropertySource和Enviroment》](https://blog.csdn.net/u011179993/article/details/51511364) 中，有详细解析。
- `#refresh()` **抽象**方法，刷新配置。

## 3.1 PortalDBPropertySource

`com.ctrip.framework.apollo.portal.service.PortalDBPropertySource` ，实现 RefreshablePropertySource 抽象类，基于 **PortalDB** 的 ServerConfig 的 PropertySource 实现类。代码如下：

```java
@Component
public class PortalDBPropertySource extends RefreshablePropertySource {

    private static final Logger logger = LoggerFactory.getLogger(PortalDBPropertySource.class);

    @Autowired
    private ServerConfigRepository serverConfigRepository;

    public PortalDBPropertySource(String name, Map<String, Object> source) {
        super(name, source);
    }

    public PortalDBPropertySource() {
        super("DBConfig", Maps.newConcurrentMap());
    }

    @Override
    protected void refresh() {
        // 获得所有的 ServerConfig 记录
        Iterable<ServerConfig> dbConfigs = serverConfigRepository.findAll();
        // 缓存，更新到属性源
        for (ServerConfig config : dbConfigs) {
            String key = config.getKey();
            Object value = config.getValue();

            // 打印日志
            if (this.source.isEmpty()) {
                logger.info("Load config from DB : {} = {}", key, value);
            } else if (!Objects.equals(this.source.get(key), value)) {
                logger.info("Load config from DB : {} = {}. Old value = {}", key, value, this.source.get(key));
            }

            // 更新到属性源
            this.source.put(key, value);
        }
    }

}
```

- 在 PortalDBPropertySource **构造方法**中，我们可以看到，属性源的名字为 `"DBConfig"` ，属性源使用 **ConcurrentMap** 。
- `#refresh()` **实现**方法，从 PortalDB 中，读取所有的 ServerConfig 记录，更新到属性源 `source` 。

## 3.2 BizDBPropertySource

`com.ctrip.framework.apollo.biz.service.BizDBPropertySource` ，实现 RefreshablePropertySource 抽象类，基于 **ConfigDB** 的 ServerConfig 的 PropertySource 实现类。代码如下：

```java
@Component
public class BizDBPropertySource extends RefreshablePropertySource {

    private static final Logger logger = LoggerFactory.getLogger(BizDBPropertySource.class);

    @Autowired
    private ServerConfigRepository serverConfigRepository;

    public BizDBPropertySource(String name, Map<String, Object> source) {
        super(name, source);
    }

    public BizDBPropertySource() {
        super("DBConfig", Maps.newConcurrentMap());
    }

    String getCurrentDataCenter() {
        return Foundation.server().getDataCenter();
    }

    @Override
    protected void refresh() {
        // 获得所有的 ServerConfig 记录
        Iterable<ServerConfig> dbConfigs = serverConfigRepository.findAll();

        // 创建配置 Map ，将匹配的 Cluster 的 ServerConfig 添加到其中
        Map<String, Object> newConfigs = Maps.newHashMap();
        // 匹配默认的 Cluster
        // default cluster's configs
        for (ServerConfig config : dbConfigs) {
            if (Objects.equals(ConfigConsts.CLUSTER_NAME_DEFAULT, config.getCluster())) {
                newConfigs.put(config.getKey(), config.getValue());
            }
        }
        // 匹配数据中心的 Cluster
        // data center's configs
        String dataCenter = getCurrentDataCenter();
        for (ServerConfig config : dbConfigs) {
            if (Objects.equals(dataCenter, config.getCluster())) {
                newConfigs.put(config.getKey(), config.getValue());
            }
        }
        // 匹配 JVM 启动参数的 Cluster
        // cluster's config
        if (!Strings.isNullOrEmpty(System.getProperty(ConfigConsts.APOLLO_CLUSTER_KEY))) { // -Dapollo.cluster=xxxx
            String cluster = System.getProperty(ConfigConsts.APOLLO_CLUSTER_KEY);
            for (ServerConfig config : dbConfigs) {
                if (Objects.equals(cluster, config.getCluster())) {
                    newConfigs.put(config.getKey(), config.getValue());
                }
            }
        }

        // 缓存，更新到属性源
        // put to environment
        for (Map.Entry<String, Object> config : newConfigs.entrySet()) {
            String key = config.getKey();
            Object value = config.getValue();

            // 打印日志
            if (this.source.get(key) == null) {
                logger.info("Load config from DB : {} = {}", key, value);
            } else if (!Objects.equals(this.source.get(key), value)) {
                logger.info("Load config from DB : {} = {}. Old value = {}", key,
                        value, this.source.get(key));
            }

            // 更新到属性源
            this.source.put(key, value);
        }
    }

}
```

- 提供给 Config Service、Admin Service 服务使用。
- 相比 PortalDBPropertySource ，BizDBPropertySource 多了**多机房部署**的 Cluster 过滤。在 `#refresh()` **实现**方法中，按照**默认** 的 Cluster、数据中心的 Cluster、JVM 启动参数的 Cluster ，逐个匹配 ServerConfig 的 `cluster` 字段。若匹配，最终会更新到属性源。
- 另外，使用 Foundation 类，获取数据中心的代码实现，我们后续单独分享。

# 4. RefreshableConfig

`com.ctrip.framework.apollo.common.config.RefreshableConfig` ，**可刷新**的配置抽象类。

## 4.1 构造方法

```java
public abstract class RefreshableConfig { // 可刷新的配置抽象类

  private static final Logger logger = LoggerFactory.getLogger(RefreshableConfig.class);

  private static final String LIST_SEPARATOR = ",";
  //TimeUnit: second // RefreshablePropertySource 刷新频率，单位：秒
  private static final int CONFIG_REFRESH_INTERVAL = 60;

  protected Splitter splitter = Splitter.on(LIST_SEPARATOR).omitEmptyStrings().trimResults();

  @Autowired
  private ConfigurableEnvironment environment; // Spring ConfigurableEnvironment 对象
  // RefreshablePropertySource 数组，通过 {@link #getRefreshablePropertySources} 获得
  private List<RefreshablePropertySource> propertySources;

  // ... 省略其他接口和属性
}
```

- `propertySources` 属性，RefreshablePropertySource 数组。

  - 在 `#setup()` 初始化方法中，将自己添加到 `environment` 中。

  - 通过 `#getRefreshablePropertySources()` **抽象**方法，返回需要注册的 RefreshablePropertySource 数组。代码如下：

    ```java
    protected abstract List<RefreshablePropertySource> getRefreshablePropertySources();
    ```

    - BizConfig 和 PortalConfig 实现该方法，返回其对应的 RefreshablePropertySource **实现类**的对象的数组。

- `environment` 属性，Spring ConfigurableEnvironment 对象。其 PropertySource 不仅仅包括 `propertySources` ，还包括 `yaml` `properties` 等 PropertySource 。这就是为什么 ServerConfig 被**封装**成 PropertySource 的原因。

- `CONFIG_REFRESH_INTERVAL` **静态**属性，每 60 秒，刷新一次 `propertySources` 配置。

## 4.2 初始化

`#setup()` 方法，通过 Spring 调用，初始化定时刷新配置任务。代码如下：

```java
@PostConstruct
public void setup() {

  propertySources = getRefreshablePropertySources(); // 返回需要注册的 RefreshablePropertySource 数组
  if (CollectionUtils.isEmpty(propertySources)) {
    throw new IllegalStateException("Property sources can not be empty.");
  }

  //add property source to environment
  for (RefreshablePropertySource propertySource : propertySources) {
    propertySource.refresh();
    environment.getPropertySources().addLast(propertySource);
  }

  //task to update configs // 创建 ScheduledExecutorService 对象
  ScheduledExecutorService
      executorService =
      Executors.newScheduledThreadPool(1, ApolloThreadFactory.create("ConfigRefresher", true));

  executorService
      .scheduleWithFixedDelay(() -> { // 提交定时任务，每分钟刷新一次 RefreshablePropertySource 数组
        try {
          propertySources.forEach(RefreshablePropertySource::refresh);
        } catch (Throwable t) {
          logger.error("Refresh configs failed.", t);
          Tracer.logError("Refresh configs failed.", t);
        }
      }, CONFIG_REFRESH_INTERVAL, CONFIG_REFRESH_INTERVAL, TimeUnit.SECONDS);
}
```

- 第 3 至 7 行：调用 `#getRefreshablePropertySources()` 方法，获得 RefreshablePropertySource 数组。
- 第 9 至 13 行：**循环**调用 `ConfigurableEnvironment#getPropertySources()#addLast(propertySource)` 方法，将 `propertySources` **注册**到 `environment` 中。
- 第 17 行：创建 ScheduledExecutorService 对象。
- 第 18 至 26 行：提交定时任务，每 60 秒，**循环**调用 `RefreshablePropertySource#refresh()` 方法，刷新 `propertySources` 的配置。

## 4.3 获得值

```java
public int getIntProperty(String key, int defaultValue) {
    try {
        String value = getValue(key);
        return value == null ? defaultValue : Integer.parseInt(value);
    } catch (Throwable e) {
        Tracer.logError("Get int property failed.", e);
        return defaultValue;
    }
}

public boolean getBooleanProperty(String key, boolean defaultValue) {
    try {
        String value = getValue(key);
        return value == null ? defaultValue : "true".equals(value);
    } catch (Throwable e) {
        Tracer.logError("Get boolean property failed.", e);
        return defaultValue;
    }
}

public String[] getArrayProperty(String key, String[] defaultValue) {
    try {
        String value = getValue(key);
        return Strings.isNullOrEmpty(value) ? defaultValue : value.split(LIST_SEPARATOR);
    } catch (Throwable e) {
        Tracer.logError("Get array property failed.", e);
        return defaultValue;
    }
}

public String getValue(String key, String defaultValue) {
    try {
        return environment.getProperty(key, defaultValue);
    } catch (Throwable e) {
        Tracer.logError("Get value failed.", e);
        return defaultValue;
    }
}

public String getValue(String key) {
    return environment.getProperty(key);
}
```

- 每个方法中，调用 `ConfigurableEnvironment#getProperty(key, defaultValue)` 方法，进行转换后返回值。🙂

## 4.4 PortalConfig

`com.ctrip.framework.apollo.portal.component.config.PortalConfig` ，实现 RefreshableConfig 抽象类。

### 4.4.1 getRefreshablePropertySources

```java
@Autowired
private PortalDBPropertySource portalDBPropertySource;

@Override
public List<RefreshablePropertySource> getRefreshablePropertySources() {
    return Collections.singletonList(portalDBPropertySource);
}
```

- 返回 PortalDBPropertySource 对象的数组。

### 4.4.2 获得值

方法比较多，胖友自己查看。如下是一个例子：

```java
// 获得 Env 集合
public List<Env> portalSupportedEnvs() {
    // 获得配置项
    String[] configurations = getArrayProperty("apollo.portal.envs", new String[]{"FAT", "UAT", "PRO"});
    // 创建成 List
    List<Env> envs = Lists.newLinkedList();
    for (String env : configurations) {
        envs.add(Env.fromString(env));
    }
    return envs;
}
```

## 4.5 BizConfig

`com.ctrip.framework.apollo.biz.config.BizConfig` ，实现 RefreshableConfig 抽象类。

### 4.5.1 getRefreshablePropertySources

```java
@Autowired
private BizDBPropertySource propertySource;

@Override
protected List<RefreshablePropertySource> getRefreshablePropertySources() {
    return Collections.singletonList(propertySource);
}
```

- 返回 BizDBPropertySource 对象的数组。

### 4.5.2 获得值

方法比较多，胖友自己查看。如下是一个例子：

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

# 5. ServerConfigController

在 `apollo-portal` 项目中，`com.ctrip.framework.apollo.portal.controller.ServerConfigController` ，提供 ServerConfig 的 **API** 。代码如下：

```java
@RestController
public class ServerConfigController {

  private final ServerConfigRepository serverConfigRepository;
  private final UserInfoHolder userInfoHolder;

  public ServerConfigController(final ServerConfigRepository serverConfigRepository, final UserInfoHolder userInfoHolder) {
    this.serverConfigRepository = serverConfigRepository;
    this.userInfoHolder = userInfoHolder;
  }

  @PreAuthorize(value = "@permissionValidator.isSuperAdmin()")
  @PostMapping("/server/config")
  public ServerConfig createOrUpdate(@Valid @RequestBody ServerConfig serverConfig) { // 校验 ServerConfig 非空
    String modifiedBy = userInfoHolder.getUser().getUserId();  // 获得操作人为当前管理员
    // 查询当前 DB 里的对应的 ServerConfig 对象
    ServerConfig storedConfig = serverConfigRepository.findByKey(serverConfig.getKey());

    if (Objects.isNull(storedConfig)) {//create // 若不存在，则进行新增
      serverConfig.setDataChangeCreatedBy(modifiedBy);
      serverConfig.setDataChangeLastModifiedBy(modifiedBy);
      serverConfig.setId(0L);//为空，设置ID 为0，jpa执行新增操作
      return serverConfigRepository.save(serverConfig);
    }
    //update // 若存在，则进行更新
    BeanUtils.copyEntityProperties(serverConfig, storedConfig); // 复制属性，serverConfig => storedConfig
    storedConfig.setDataChangeLastModifiedBy(modifiedBy);
    return serverConfigRepository.save(storedConfig);
  }

  @PreAuthorize(value = "@permissionValidator.isSuperAdmin()")
  @GetMapping("/server/config/{key:.+}")
  public ServerConfig loadServerConfig(@PathVariable String key) {
    return serverConfigRepository.findByKey(key);
  }

  // ... 省略其他接口和属性
}
```



# 参考

[Apollo 源码解析 —— 服务自身配置 ServerConfig](https://www.iocoder.cn/Apollo/server-config/)
