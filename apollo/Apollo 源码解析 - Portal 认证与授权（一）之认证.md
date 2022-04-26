# 1. 概述

> 老艿艿：本系列假定胖友已经阅读过 [《Apollo 官方 wiki 文档》](https://github.com/ctripcorp/apollo/wiki/) ，特别是 [《Portal 实现用户登录功能》](https://github.com/ctripcorp/apollo/wiki/Portal-实现用户登录功能) 。

本文分享 Portal 的认证与授权，**侧重在认证部分**。

在 [《Portal 实现用户登录功能》](https://github.com/ctripcorp/apollo/wiki/Portal-实现用户登录功能) 文档的开头：

> Apollo 是配置管理系统，会提供权限管理（Authorization），理论上是不负责用户登录认证功能的实现（Authentication）。
>
> 所以 Apollo 定义了一些SPI用来解耦，Apollo 接入登录的关键就是实现这些 SPI 。

和我们理解的 JDK SPI 不同，Apollo 是基于 Spring [Profile](https://docs.spring.io/autorepo/docs/spring-boot/current/reference/html/boot-features-profiles.html) 的特性，配合上 Spring Java Configuration 实现了**类似** SPI 的功能。对于大多数人，我们可能比较熟悉的是，基于不同的 Profile 加载不同**环境**的 `yaml` 或 `properties` 配置文件。所以，当笔者看到这样的玩法，也是眼前一亮。

在 `apollo-portal` 项目中，`spi` 包下，我们可以看到**认证**相关的**配置**与**实现**，如下图所示：

<img src="http://blog-1259650185.cosbj.myqcloud.com/img/202204/06/1649260457.png" alt="代码结构" style="zoom: 67%;" />

- 绿框：接口。
- 紫框：实现。
- 红框：配置接口对应的实现。

# 2. AuthConfiguration

`com.ctrip.framework.apollo.portal.spi.configuration.AuthConfiguration` ，**认证** Spring Java 配置。如下图：

<img src="http://blog-1259650185.cosbj.myqcloud.com/img/202204/06/1649260549.png" alt="AuthConfiguration" style="zoom:50%;" />



目前有三种实现：

- 第一种， `profile=ctrip` ，携程**内部**实现，接入了SSO并实现用户搜索、查询接口。
- 第二种，`profile=auth` ，使用 Apollo 提供的 **Spring Security** 简单认证。
- 第三种，`profile` 为空，使用**默认**实现，全局只有 apollo 一个账号。

一般情况下，我们使用**第二种**，基于 **Spring Security** 的实现。所以本文仅分享这种方式。对其他方式感兴趣的胖友，可以自己读下代码哈。

整体类图如下：

<img src="http://blog-1259650185.cosbj.myqcloud.com/img/202204/06/1649260651.png" alt="类图" style="zoom: 67%;" />

## 2.1 SpringSecurityAuthAutoConfiguration

**UserService** ，配置如下：

```java
@Bean
@ConditionalOnMissingBean(UserService.class)
public UserService springSecurityUserService(PasswordEncoder passwordEncoder,
    UserRepository userRepository, AuthorityRepository authorityRepository) {
  return new SpringSecurityUserService(passwordEncoder, userRepository, authorityRepository);
}
```

- 使用 SpringSecurityUserService 实现类，在 [「5. UserService」](https://www.iocoder.cn/Apollo/portal-auth-1/#) 中，详细解析。

------

**UserInfoHolder** ，配置如下：

```java
@Bean
@ConditionalOnMissingBean(UserInfoHolder.class)
public UserInfoHolder springSecurityUserInfoHolder(UserService userService) {
  return new SpringSecurityUserInfoHolder(userService);
}
```

- 使用 SpringSecurityUserInfoHolder 实现类，在 [「6. UserInfoHolder」](https://www.iocoder.cn/Apollo/portal-auth-1/#) 中，详细解析。

------

**JdbcUserDetailsManager** ，配置如下：

```java
@Bean
public static JdbcUserDetailsManager jdbcUserDetailsManager(PasswordEncoder passwordEncoder,
    AuthenticationManagerBuilder auth, DataSource datasource) throws Exception {
  JdbcUserDetailsManager jdbcUserDetailsManager = auth.jdbcAuthentication()
      .passwordEncoder(passwordEncoder).dataSource(datasource)
      .usersByUsernameQuery("select Username,Password,Enabled from `Users` where Username = ?")
      .authoritiesByUsernameQuery(
          "select Username,Authority from `Authorities` where Username = ?")
      .getUserDetailsService();

  jdbcUserDetailsManager.setUserExistsSql("select Username from `Users` where Username = ?");
  jdbcUserDetailsManager
      .setCreateUserSql("insert into `Users` (Username, Password, Enabled) values (?,?,?)");
  jdbcUserDetailsManager
      .setUpdateUserSql("update `Users` set Password = ?, Enabled = ? where id = (select u.id from (select id from `Users` where Username = ?) as u)");
  jdbcUserDetailsManager.setDeleteUserSql("delete from `Users` where id = (select u.id from (select id from `Users` where Username = ?) as u)");
  jdbcUserDetailsManager
      .setCreateAuthoritySql("insert into `Authorities` (Username, Authority) values (?,?)");
  jdbcUserDetailsManager
      .setDeleteUserAuthoritiesSql("delete from `Authorities` where id in (select a.id from (select id from `Authorities` where Username = ?) as a)");
  jdbcUserDetailsManager
      .setChangePasswordSql("update `Users` set Password = ? where id = (select u.id from (select id from `Users` where Username = ?) as u)");

  return jdbcUserDetailsManager;
}
```

- `org.springframework.security.provisioning.JdbcUserDetailsManager` ，继承 JdbcDaoImpl 的功能，提供了一些很有用的与 **Users 和 Authorities 表**相关的方法。
- 胖友先看下 [「3. Users」](https://www.iocoder.cn/Apollo/portal-auth-1/#) 和 [「4. Authorities」](https://www.iocoder.cn/Apollo/portal-auth-1/#) 小节，然后回过头继续往下看。

------

**SsoHeartbeatHandler** ，配置如下：

```java
@Bean
@ConditionalOnMissingBean(SsoHeartbeatHandler.class)
public SsoHeartbeatHandler defaultSsoHeartbeatHandler() {
  return new DefaultSsoHeartbeatHandler();
}
```

- 使用 DefaultSsoHeartbeatHandler 实现类，在 [「7. SsoHeartbeatHandler」](https://www.iocoder.cn/Apollo/portal-auth-1/#) 中，详细解析。

------

**LogoutHandler** ，配置如下：

```java
@Bean
@ConditionalOnMissingBean(LogoutHandler.class)
public LogoutHandler logoutHandler() {
  return new DefaultLogoutHandler();
}
```

- 使用 DefaultLogoutHandler 实现类，在 [「8. LogoutHandler」](https://www.iocoder.cn/Apollo/portal-auth-1/#) 中，详细解析。

## 2.2 SpringSecurityConfigureration

```java
@Order(99)
@Profile("auth")
@Configuration
@EnableWebSecurity
@EnableGlobalMethodSecurity(prePostEnabled = true)
static class SpringSecurityConfigurer extends WebSecurityConfigurerAdapter {

  public static final String USER_ROLE = "user";

  @Override
  protected void configure(HttpSecurity http) throws Exception {
    http.csrf().disable(); // 关闭打开的 csrf 保护
    http.headers().frameOptions().sameOrigin();  // 仅允许相同 origin 访问
    http.authorizeRequests()
        .antMatchers(BY_PASS_URLS).permitAll()
        .antMatchers("/**").hasAnyRole(USER_ROLE);
    http.formLogin().loginPage("/signin").defaultSuccessUrl("/", true).permitAll().failureUrl("/signin?#/error").and()
        .httpBasic(); // 其他，需要登录 User
    http.logout().logoutUrl("/user/logout").invalidateHttpSession(true).clearAuthentication(true)
        .logoutSuccessUrl("/signin?#/logout");
    http.exceptionHandling().authenticationEntryPoint(new LoginUrlAuthenticationEntryPoint("/signin"));
  }

}
```

- `@EnableWebSecurity` 注解，禁用 Boot 的默认 Security 配置，配合 `@Configuration` 启用自定义配置（需要继承 WebSecurityConfigurerAdapter ）。

- `@EnableGlobalMethodSecurity(prePostEnabled = true)` 注解，启用 Security 注解，例如最常用的 `@PreAuthorize` 。

- **注意**，`.antMatchers("/**").hasAnyRole(USER_ROLE);` 代码块，设置**统一**的 URL 的权限校验，**只判断是否为登录用户**。另外，`#hasAnyRole(...)` 方法，会自动添加 `"ROLE_"` 前缀，所以此处的传参是 `"user"` 。代码如下：

  ```java
  // ExpressionUrlAuthorizationConfigurer.java
  
  private static String hasAnyRole(String... authorities) {
  	String anyAuthorities = StringUtils.arrayToDelimitedString(authorities,
  			"','ROLE_");
  	return "hasAnyRole('ROLE_" + anyAuthorities + "')";
  }
  ```

# 3. Users

**Users** 表，对应实体 `com.ctrip.framework.apollo.portal.entity.po.UserPO` ，代码如下：

```java
@Entity
@Table(name = "Users")
public class UserPO {

  @Id
  @GeneratedValue(strategy = GenerationType.IDENTITY)
  @Column(name = "Id")
  private long id; // 编号
  @Column(name = "Username", nullable = false)
  private String username; // 账号
  @Column(name = "UserDisplayName", nullable = false)
  private String userDisplayName;
  @Column(name = "Password", nullable = false)
  private String password; // 密码
  @Column(name = "Email", nullable = false)
  private String email; // 邮箱
  @Column(name = "Enabled", nullable = false)
  private int enabled; // 是否开启

  // ... 省略其他接口和属性
}
```

- 字段比较简单，胖友自己看注释。

## 3.1 UserInfo

`com.ctrip.framework.apollo.portal.entity.bo.UserInfo` ，User **BO** 。代码如下：

```java
public class UserInfo {

  private String userId; // 账号 {@link com.ctrip.framework.apollo.portal.entity.po.UserPO#username}
  private String name; // 账号 {@link com.ctrip.framework.apollo.portal.entity.po.UserPO#username}
  private String email; // 邮箱 {@link com.ctrip.framework.apollo.portal.entity.po.UserPO#email}

  // ... 省略其他接口和属性
}
```

- 在 UserPO 的 `#toUserInfo()` 方法中，将 UserPO 转换成 UserBO ，代码如下：

  ```java
  public UserInfo toUserInfo() {
      UserInfo userInfo = new UserInfo();
      userInfo.setName(this.getUsername());
      userInfo.setUserId(this.getUsername());
      userInfo.setEmail(this.getEmail());
      return userInfo;
  }
  ```

  - **注意**，`userId` 和 `name` 属性，都是指向 `User.username` 。

# 4. Authorities

**Authorities** 表，Spring Security 中的 Authority ，实际和 Role 角色**等价**。表结构如下：

```sql
`Id` int(11) UNSIGNED NOT NULL AUTO_INCREMENT COMMENT '自增Id',
`Username` varchar(50) NOT NULL,
`Authority` varchar(50) NOT NULL,
```

- 目前 Portal 只有**一种**角色 `"ROLE_user"` 。如下图所示：![Authorities](https://static.iocoder.cn/images/Apollo/2018_06_01/03.png)
- 为什么是这样的呢？在 Apollo 中，
  - **统一**的 URL 的权限校验，**只判断是否为登录用户**，在 SpringSecurityConfigureration 中，我们可以看到。
  - 具体**每个** URL 的权限校验，通过在对应的方法上，添加 `@PreAuthorize` 方法注解，配合具体的方法参数，一起校验**功能 + 数据级**的权限校验。

# 5. UserService

`com.ctrip.framework.apollo.portal.spi.UserService` ，User 服务**接口**，用来给 Portal 提供用户搜索相关功能。代码如下：

```java
public interface UserService {
  List<UserInfo> searchUsers(String keyword, int offset, int limit);

  UserInfo findByUserId(String userId);

  List<UserInfo> findByUserIds(List<String> userIds);

}
```

## 5.1 SpringSecurityUserService

`com.ctrip.framework.apollo.portal.spi.springsecurity.SpringSecurityUserService` ，基于 **Spring Security** 的 UserService 实现类。

### 5.5.1 构造方法

```java
public class SpringSecurityUserService implements UserService {

  private final PasswordEncoder passwordEncoder;

  private final UserRepository userRepository;

  private final AuthorityRepository authorityRepository;

  public SpringSecurityUserService(
      PasswordEncoder passwordEncoder,
      UserRepository userRepository,
      AuthorityRepository authorityRepository) {
    this.passwordEncoder = passwordEncoder;
    this.userRepository = userRepository;
    this.authorityRepository = authorityRepository;
  }
  // ... 省略其他接口和属性
}
```

- `authorities` 属性，只有一个元素，为 `"ROLE_user"` 。

### 5.5.2 createOrUpdate

`#createOrUpdate(UserPO)` 方法，创建或更新 User 。代码如下：

```java
@Transactional
public void createOrUpdate(UserPO user) {
  String username = user.getUsername();
  String newPassword = passwordEncoder.encode(user.getPassword());

  UserPO managedUser = userRepository.findByUsername(username);
  if (managedUser == null) { // 若不存在，则进行新增
    user.setPassword(newPassword);
    user.setEnabled(1);
    userRepository.save(user);

    //save authorities
    Authority authority = new Authority();
    authority.setUsername(username);
    authority.setAuthority("ROLE_user");
    authorityRepository.save(authority);
  } else { // 若存在，则进行更新
    managedUser.setPassword(newPassword);
    managedUser.setEmail(user.getEmail());
    managedUser.setUserDisplayName(user.getUserDisplayName());
    userRepository.save(managedUser);
  }
}
```

- 第 5 行：创建`com.ctrip.framework.apollo.portal.spi.springsecurity.User`对象。
  - 使用 PasswordEncoder 对 `password` 加密。
  - 传入对应的角色 `authorities` 参数。
- 第 6 至 12 行：新增或更新 User 。
- 第 13 至 16 行：更新 `email` 。不直接在【第 6 至 12 行】处理的原因是，`com.ctrip.framework.apollo.portal.spi.springsecurity.User` 中没有 `email` 属性。

### 5.5.3 其他实现方法

🙂 胖友自己查看代码。嘿嘿。

## 5.2 UserInfoController

在 `apollo-portal` 项目中，`com.ctrip.framework.apollo.portal.controller.UserInfoController` ，提供 User 的 **API** 。

### 5.2.1 createOrUpdateUser

在**用户管理**的界面中，点击【提交】按钮，调用**创建或更新 User 的 API** 。

![创建或更新 User 界面](http://blog-1259650185.cosbj.myqcloud.com/img/202204/07/1649261765.png)

`#createOrUpdateUser(UserPO)` 方法，创建或更新 User 。代码如下：

```java
@PreAuthorize(value = "@permissionValidator.isSuperAdmin()")
@PostMapping("/users")
public void createOrUpdateUser(@RequestBody UserPO user) {
  if (StringUtils.isContainEmpty(user.getUsername(), user.getPassword())) { // // 校验 username 、password 非空
    throw new BadRequestException("Username and password can not be empty.");
  }

  CheckResult pwdCheckRes = passwordChecker.checkWeakPassword(user.getPassword());
  if (!pwdCheckRes.isSuccess()) {
    throw new BadRequestException(pwdCheckRes.getMessage());
  }

  if (userService instanceof SpringSecurityUserService) {
    ((SpringSecurityUserService) userService).createOrUpdate(user); // 新增或更新 User
  } else {
    throw new UnsupportedOperationException("Create or update user operation is unsupported");
  }
}
```

- **POST `/users` 接口**，Request Body 传递 **JSON** 对象。
- `@PreAuthorize(...)` 注解，调用 `PermissionValidator#isSuperAdmin()` 方法，校验是否为**超级管理员**。后续文章，详细分享。
- 调用 `SpringSecurityUserService#createOrUpdate(UserPO)` 方法，新增或更新 User 。

### 5.2.2 logout

`#logout(request, response)` 方法，User 登出。代码如下：

```java
@GetMapping("/user/logout")
public void logout(HttpServletRequest request, HttpServletResponse response) throws IOException {
  logoutHandler.logout(request, response);
}
```

- **GET `/user/logout` 接口**。
- 调用 `LogoutHandler#logout(request, response)` 方法，登出 User 。在 [「8. LogoutHandler」](https://www.iocoder.cn/Apollo/portal-auth-1/#) 中，详细解析。

# 6. UserInfoHolder

`com.ctrip.framework.apollo.portal.spi.UserInfoHolder` ，获取当前登录用户信息，**SSO** 一般都是把当前登录用户信息放在线程 ThreadLocal 上。代码如下：

```java
public interface UserInfoHolder {

    UserInfo getUser();

}
```

## 6.1 SpringSecurityUserInfoHolder

`com.ctrip.framework.apollo.portal.spi.springsecurity.SpringSecurityUserInfoHolder` ，实现 UserInfoHolder 接口，基于 **Spring Security** 的 UserInfoHolder 实现类。代码如下：

```java
public class SpringSecurityUserInfoHolder implements UserInfoHolder {

  private final UserService userService;

  public SpringSecurityUserInfoHolder(UserService userService) {
    this.userService = userService;
  }

  @Override
  public UserInfo getUser() {
    String userId = this.getCurrentUsername();
    UserInfo userInfoFound = this.userService.findByUserId(userId);
    if (userInfoFound != null) {
      return userInfoFound;
    }
    UserInfo userInfo = new UserInfo(); // 创建 UserInfo 对象，设置 username 到 UserInfo.userId 中
    userInfo.setUserId(userId);
    return userInfo;
  }

  private String getCurrentUsername() {
    Object principal = SecurityContextHolder.getContext().getAuthentication().getPrincipal();
    if (principal instanceof UserDetails) {
      return ((UserDetails) principal).getUsername();
    }
    if (principal instanceof Principal) {
      return ((Principal) principal).getName();
    }
    return String.valueOf(principal);
  }

}
```

# 7. SsoHeartbeatHandler

`com.ctrip.framework.apollo.portal.spi.SsoHeartbeatHandler` ，Portal 页面如果长时间不刷新，登录信息会过期。通过此接口来刷新登录信息。代码如下：

```java
public interface SsoHeartbeatHandler {

    void doHeartbeat(HttpServletRequest request, HttpServletResponse response);

}
```

## 7.1 DefaultSsoHeartbeatHandler

`com.ctrip.framework.apollo.portal.spi.defaultimpl.DefaultSsoHeartbeatHandler` ，实现 SsoHeartbeatHandler 接口，代码如下：

```java
public class DefaultSsoHeartbeatHandler implements SsoHeartbeatHandler {

    @Override
    public void doHeartbeat(HttpServletRequest request, HttpServletResponse response) {
        try {
            response.sendRedirect("default_sso_heartbeat.html");
        } catch (IOException e) {
        }
    }

}
```

- 跳转到 `default_sso_heartbeat.html` 中。页面如下：

  ```html
  <!DOCTYPE html>
  <html lang="en">
  <head>
      <meta charset="UTF-8">
      <title>SSO Heartbeat</title>
      <script type="text/javascript">
          var reloading = false;
          setInterval(function () {
              if (reloading) {
                  return;
              }
              reloading = true;
              location.reload(true);
          }, 60000);
      </script>
  </head>
  <body>
  </body>
  </html>
  ```

  - 每 60 秒刷新一次页面。🙂 一脸懵逼，这是干啥的？继续往下看。

## 7.2 SsoHeartbeatController

`com.ctrip.framework.apollo.portal.controller.SsoHeartbeatController` ，代码如下：

```java
@Controller
@RequestMapping("/sso_heartbeat")
public class SsoHeartbeatController {
  private final SsoHeartbeatHandler handler;

  public SsoHeartbeatController(final SsoHeartbeatHandler handler) {
    this.handler = handler;
  }

  @GetMapping
  public void heartbeat(HttpServletRequest request, HttpServletResponse response) {
    handler.doHeartbeat(request, response);
  }
}
```

- 通过打开一个**新的窗口**，访问 `http://ip:prot/sso_hearbeat` 地址，每 60 秒刷新一次页面，从而避免 SSO 登录过期。因此，相关类的类名都包含 Heartbeat ，代表**心跳**的意思。

# 8. LogoutHandler

`com.ctrip.framework.apollo.portal.spi.LogoutHandler` ，用来实现登出功能。代码如下：

```java
public interface LogoutHandler {

    void logout(HttpServletRequest request, HttpServletResponse response);

}
```

## 8.1 DefaultLogoutHandler

`com.ctrip.framework.apollo.portal.spi.defaultimpl.DefaultLogoutHandler` ，实现 LogoutHandler 接口，代码如下：

```java
public class DefaultLogoutHandler implements LogoutHandler {

  @Override
  public void logout(HttpServletRequest request, HttpServletResponse response) {
    try {
      response.sendRedirect("/");
    } catch (IOException e) {
      throw new RuntimeException(e);
    }
  }
}
```

- 登出后，跳转到 `/` 地址。
- 😈 在使用 Spring Security 的请款下，不会调用到。**注意**，因为，我们配置了登出页。



# 参考

[Apollo 源码解析 —— Portal 认证与授权（一）之认证](https://www.iocoder.cn/Apollo/portal-auth-1/)
