## 1. 引言

在我们微服务开发过程中不可避免的会涉及到微服务之间的调用，例如：认证 Auth 服务需要去用户 User 服务获取用户信息。在 `Spring Cloud`全家桶的背景下，我们一般都是使用 `Feign` 组件进行服务之间的调用。

关于一般的 `Feign` 组件使用相信大家都很熟悉，但是在搭建整个微服务架构的时候 `Feign` 组件遇到的问题也都熟悉吗 ？ 今天我们来聊一聊。

## 2. 基础使用

首先，我们先实现一个 `Feign` 组件的使用方法。

1. 导入包

```xml
<dependency>
  <groupId>org.springframework.cloud</groupId>
  <artifactId>spring-cloud-starter-loadbalancer</artifactId>
</dependency>

<dependency>
  <groupId>org.springframework.cloud</groupId>
  <artifactId>spring-cloud-starter-openfeign</artifactId>
</dependency>
```

这里也导入了一个 `Loadbalancer` 组件，因为在 `Feign` 底层还会使用到负载均衡器进行客户端负载。

2. 配置启用 FeignClient

```java
@EnableFeignClients(basePackages = {
        "org.anyin.gitee.cloud.center.upms.api"
})
```

在我们的 main 入口的类上添加上 `@EnableFeignClients` 注解，并指定了包扫描的位置

3. 编写 FeignClient 接口

```java
@FeignClient(name = "anyin-center-upms",
        contextId = "SysUserFeignApi",
        configuration = FeignConfig.class,
        path = "/api/sys-user")
public interface SysUserFeignApi {
    @GetMapping("/info/mobile")
    ApiResponse<SysUserResp> infoByMobile(@RequestParam("mobile") String mobile);
}
```

我们自定义了一个 `SysUserFeignApi `接口，并且添加上了 `@FeignClient` 注解。相关属性说明如下：

- `name`  应用名，其实就是 `spring.application.name` ，用于标识某个应用，并且能从注册中心拿到对应的运行实例信息
- `contextId`  当你多个接口都使用了一样的 `name`值，则需要通过 `contextId` 来进行区分
- `configuration`  指定了具体的配置类
- `path`  请求的前缀

4. 编写 FeignClient 接口实现

```java
@RestController
@RequestMapping("/api/sys-user")
public class SysUserFeignController implements SysUserFeignApi {
    @Autowired
    private SysUserRepository sysUserRepository;
    @Autowired
    private SysUserConvert sysUserConvert;
    @Override
    public ApiResponse<SysUserResp> infoByMobile(@RequestParam("mobile") String mobile) {
        SysUser user = sysUserRepository.infoByMobile(mobile);
        SysUserResp resp = sysUserConvert.getSysUserResp(user);
        return ApiResponse.success(resp);
    }
}
```

这个就是一个简单的 `Controller `类和对应的方法，用于根据手机号查询用户信息。

5. 客户端使用

```java
@Component
@Slf4j
public class MobileInfoHandler{
    @Autowired
    private SysUserFeignApi sysUserFeignApi;
    @Override
    public SysUserResp info(String mobile) {
        SysUserResp sysUser = sysUserFeignApi.infoByMobile(mobile).getData();
        if(sysUser == null){
            throw AuthExCodeEnum.USER_NOT_REGISTER.getException();
        }
        return sysUser;
    }
}
```

这个是我们在客户端服务使用 `Feign `组件的代码，它就像一个` Service` 方法一样，直接调用就行。无需处理请求和响应过程中关于参数的转换。

至此，我们的一个 `Feign组件` 基本使用的代码就完成了。这个时候我们信心满满的赶紧运行下我们代码，测试下接口是否正常。

以上的代码，是能够正常运行的。但是随着我们遇到`场景的增多`，我们会发现，理想很丰满，显示很骨感，以上的代码并不能100%适应我们遇到的场景。

接下来，我们来看看我们`遇到哪些场景以及这些场景需要怎么解决`。

## 3. 场景一：日志

在以上的代码中，因为我们未做任何配置，所以 `sysUserFeignApi.infoByMobile `方法对于我们来讲就像一个黑盒。

虽然我们传递了 `mobile` 值，但是不知道真实请求用户服务的值是什么，是否有其他信息一起传递？虽然方法返回的参数是 `SysUserResp` 实体，但是我们不知道用户服务返回的是什么，是否有其他信息一起返回？虽然我们知道 `Feign` 组件底层是 http 实现，那么请求的过程是否有传递 `header `信息？

这一切对我们来讲就是一个黑盒，极大阻碍我们拔刀（排查问题）的速度。所以，我们需要配置日志，用于显示请求过程中的所有信息传递。

在刚 `@FeignClient` 注解有个参数， `configuration`  指定了具体的配置类，我们可以在这里指定日志的级别。如下：

```java
public class FeignConfig {
    @Bean
    public Logger.Level loggerLevel(){
        return Logger.Level.FULL;
    }
}
```

接着还需要在配置文件指定具体 `FeignClient` 的日志级别 为`DEBUG`。

```yml
logging:
  level:
    root: info
    org.anyin.gitee.cloud.center.upms.api.SysUserFeignApi: debug
```

这个时候，你在请求接口的时候，会发现多了好多日志。

![image.png](https://p6-juejin.byteimg.com/tos-cn-i-k3u1fbpfcp/4a1f72ed636a42a9ab627a0b3e55de11~tplv-k3u1fbpfcp-zoom-in-crop-mark:1304:0:0:0.awebp?)

这里就可以详细看到，在请求开始的时候携带的所有 `header `信息以及请求参数信息，在响应回来的时候通用打印了所有的响应信息。

## 4. 场景二：透传header信息

在上一节中，我们在日志中看到了很多的请求头 `header `的信息，这些都是程序自己添加的吗 ？ 很明显不是。例如 `x-application-name `和 `x-request-id`，这两个参数就是我们自己添加的。

需要透传 `header `信息的场景，一般是出现在 `租户ID `或者 `请求ID` 的场景下。我们这里以 `请求ID` 为例，我们知道用户的一个请求，可能会涉及多个服务实例，当程序出现问题的时候为了方便排查，我们一般会使用`请求ID`来标识一次用户请求，并且这个 `请求ID `贯穿所有经过的服务实例，并且在日志中打印出来。这样子，当出现问题的时候，根据该`请求ID`就可以捞出本次用户请求的所有日志信息。

关于 `请求ID` 打印到日志可以参考：
 [不会吧，你还不会用RequestId看日志 ?](https://juejin.cn/post/7029880952666980388)

基于这种场景，我们需要手动设置透传信息，`Feign `组件也给我们提供了对应的方式。 只要实现了 `RequestInterceptor` 接口，即可透传 `header `信息。

```java
public class FeignRequestInterceptor implements RequestInterceptor {
    @Value("${spring.application.name}")
    private String app;
    @Override
    public void apply(RequestTemplate template) {
        HttpServletRequest request = WebContext.getRequest();
        // job 类型的任务，可能没有Request
        if(request != null && request.getHeaderNames() != null){
            Enumeration<String> headerNames = request.getHeaderNames();
            while (headerNames.hasMoreElements()) {
                String name = headerNames.nextElement();
                // Accept值不传递，避免出现需要响应xml的情况
                if ("Accept".equalsIgnoreCase(name)) {
                    continue;
                }
                String values = request.getHeader(name);
                template.header(name, values);
            }
        }
        template.header(CommonConstants.APPLICATION_NAME, app);
        template.header(CommonConstants.REQUEST_ID, RequestIdUtil.getRequestId().toString());
        template.header(HttpHeaders.CONTENT_TYPE, MediaType.APPLICATION_JSON_VALUE);
    }
}
```

## 5. 场景三：异常处理

在第一节我们客户调用的时候，我们是没有处理异常的，我们直接`. getData()` 直接返回了，这其实是一个非常危险的操作， `.getData()` 的返回结果可能是null，很容易造成NPE的情况。

```java
SysUserResp sysUser = sysUserFeignApi.infoByMobile(mobile).getData();
```

回想下，当我们调用其他当前服务的 `Service` 方法的时候，如果遇到异常，是不是就是直接抛出异常，交由统一异常处理器进行处理？所以，这里我们也是期望`调用Feign和Service一样`，遇到异常，交由统一异常进行处理。

如何处理这个需求呢？ 我们可以在`解码`的时候进行处理。

```java
@Slf4j
public class FeignDecoder implements Decoder {
    // 代理默认的解码器
    private Decoder decoder;
    public FeignDecoder(Decoder decoder) {
        this.decoder = decoder;
    }
    @Override
    public Object decode(Response response, Type type) throws IOException, DecodeException, FeignException {
        // 序列化为json
        String json = this.getResponseJson(response);
        this.processCommonException(json);
        return decoder.decode(response, type);
    }
    // 处理公共业务异常
    private void processCommonException(String json){
        if(!StringUtils.hasLength(json)){
            return;
        }
        ApiResponse resp = JSONUtil.toBean(json, ApiResponse.class);
        if(resp.getSuccess()){
            return;
        }
        log.info("feign response error: code={}, message={}", resp.getCode(), resp.getMessage());
        // 抛出我们期望的业务异常
        throw new CommonException(resp.getCode(), resp.getMessage());
    }
    // 响应值转json字符串
    private String getResponseJson(Response response) throws IOException {
        try (InputStream inputStream = response.body().asInputStream()) {
            return StreamUtils.copyToString(inputStream, StandardCharsets.UTF_8);
        }
    }
}
```

这里我们的处理方式是在解码的时候，先从响应结果中拿到是否有业务异常的判断，如果有，则构造业务异常实例，然后抛出信息。

运行下代码，我们会发现统一异常那边还是无法处理由下游服务返回的异常，原因是虽然我们抛出了一个 `CommonException`，但是其实最后还是会被 `Feign` 捕获，然后重新封装为 `DecodeException` 异常，再进行抛出

```java
Object decode(Response response, Type type) throws IOException {
    try {
      return decoder.decode(response, type);
    } catch (final FeignException e) {
      throw e;
    } catch (final RuntimeException e) {
      // 重新封装异常
      throw new DecodeException(response.status(), e.getMessage(), response.request(), e);
    }
  }
```

所以，我们还需要在统一异常那边再做下处理，代码如下：

```java
@ResponseStatus(HttpStatus.OK)
@ExceptionHandler(DecodeException.class)
public ApiResponse decodeException(DecodeException ex){
    log.error("解码失败: {}", ex.getMessage());
    String id = RequestIdUtil.getRequestId().toString();
    if(ex.getCause() instanceof CommonException){
        CommonException ce = (CommonException)ex.getCause();
        return ApiResponse.error(id, ce.getErrorCode(), ce.getErrorMessage());
    }
    return ApiResponse.error(id, CommonExCodeEnum.DATA_PARSE_ERROR.getCode(), ex.getMessage());
}
```

在运行下代码，我们就可以看到异常从`用户服务->认证服务->网关->前端`这么一个流程。

- 用户服务抛出的异常

![image.png](https://p3-juejin.byteimg.com/tos-cn-i-k3u1fbpfcp/5ed2e2c9b6b74b5ba8bc1bf759d6474e~tplv-k3u1fbpfcp-zoom-in-crop-mark:1304:0:0:0.awebp?)

- 认证服务抛出的异常

![image.png](http://blog-1259650185.cosbj.myqcloud.com/img/202205/05/1651765625.awebp)

- 前端显示的异常

![image.png](http://blog-1259650185.cosbj.myqcloud.com/img/202205/05/1651765625.awebp)

## 6. 场景四：时区问题

随着业务的变化，我们可能会在请求参数或者响应参数中增加关于 `Date` 类型的参数，这个时候你会发现，它的时区不对，少了8个小时。

这个问题其实是 `Jackson `组件带来的，该问题其实也有不同的解法。

1. 在每个 `Date `属性添加上 `@JsonFormat(pattern = "yyyy-MM-dd HH:mm:ss", timezone = "GMT+8")`
2. 传参统一转为 `yyyy-MM-dd HH:mm:ss` 格式的字符
3. 统一配置 `spring.jackson`

很明显，第三种解法最合适，我们在配置文件做如下的配置即可。

```yml
spring:
  jackson:
    date-format: yyyy-MM-dd HH:mm:ss
    time-zone: GMT+8
```

这里需要注意下，我们 `@FeignClient` 的配置是自定义配置的 `FeignConfig` 类，在自定义配置类中加载了解码器，而解码器依赖的是全局的 `HttpMessageConverters` 实例，和 `SpringMVC` 依赖的是同一个实例，所以该配置生效。有些场景下会自定义 `HttpMessageConverters`，那么该配置则不生效。

```java
public class FeignConfig {
    @Autowired
    private ObjectFactory<HttpMessageConverters> messageConverters;
    // 自定义解码器
    @Bean
    public Decoder decoder(ObjectProvider<HttpMessageConverterCustomizer> customizers){
        return new FeignDecoder(
                new OptionalDecoder(
                        new ResponseEntityDecoder(
                                new SpringDecoder(messageConverters, customizers))));
    }
}
```

## 7. 其他问题

不知道细心的朋友是否有看到在第一节定义 `SysUserFeignApi` 接口的时候，我在 `@FeignClient` 注解上使用了一个属性： `path`，并且接口上没有使用 `@RequestMapping` 注解。

回想下，之前我们在使用 `Feign `的时候，是不是这么使用的：

```java
@FeignClient(name = "anyin-center-upms",
        contextId = "SysUserFeignApi",
        configuration = FeignConfig.class)
@RequestMapping("/api/sys-user")        
public interface SysUserFeignApi {}
复制代码
```

这里不使用这个方式的原因是我当前版本的 `Spring Cloud OpenFeign` 已经不支持识别 `@RequestMapping`注解了，它不会在请求的时候加入到请求的前缀，所以即使解决了 `@RequestMapping` 注解被 `SpringMVC` 识别为`Controller`类也无法正常运行。

所以，这里使用了 `path` 属性。



## 参考

[关于OpenFeign那点事儿 - 使用篇](https://juejin.cn/post/7068179877047828517/)
