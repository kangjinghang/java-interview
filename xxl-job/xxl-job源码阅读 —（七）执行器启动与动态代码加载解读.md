## 1. 结构

前面六章基本上已经把调度器的部分覆盖了，接下来我们解读执行器部分，也就是 xxl-job-core 包。

<img src="http://blog-1259650185.cosbj.myqcloud.com/img/202204/20/1650467643.png" alt="image-20220420231358590" style="zoom:50%;" />

| 目录     | 说明                                       |
| -------- | ------------------------------------------ |
| biz      | 调度器与执行器交互的接口与实现             |
| enums    | 相关枚举                                   |
| executor | 执行器实例以及执行器与spring的嵌合         |
| glue     | Java动态加载的实现与其他胶水代码的枚举定义 |
| handler  | IJobHandler以及它的特定实现类。            |
| log      | 日志自定义实现，将日志写入本地文件保存     |
| server   | netty服务器实现，用于与调度器通信          |
| thread   | 任务线程，注册线程，日志文件清理线程等。   |
| util     | 工具类                                     |

## 2. 启动流程

XxlJobExecutor 是执行器的核心启动类。 

xxl-job默认支持spring集成，spring 体系下不需要额外的操作。同时也提供了一些其他的框架集成实现，放在了 xxl-job-executor-samples中。

我们这里只关注spring方式启动： 

- XxlJobSpringExecutor.afterSingletonsInstantiated()
- XxlJobSpringExecutor 使用了 SmartInitializingSingleton 而非 InitializingBean 来进行初始化。SmartInitializingSingleton 是在spring 容器中所有 bean 加载完成后，才会被调用，这里主要是为了保证 JobHandler 已经被 spring 容器加载。

```java
// XxlJobSpringExecutor.java
@Override
public void afterSingletonsInstantiated() {

    // init JobHandler Repository
    /*initJobHandlerRepository(applicationContext);*/

    // init JobHandler Repository (for method)
    initJobHandlerMethodRepository(applicationContext); // 将业务系统 @XxlJob 注解了的方法加载成 JobHandler 实例，保存到一个本地Map对象中

    // refresh GlueFactory
    GlueFactory.refreshInstance(1); // 加载 Glue 代码工厂实例，用于做运行中动态代码加载

    // super start
    try {
        super.start(); // 进入XxlJobExecutor启动主流程
    } catch (Exception e) {
        throw new RuntimeException(e);
    }
}
```

XxlJobExecutor.start()

```java
public class XxlJobExecutor  {
    private static final Logger logger = LoggerFactory.getLogger(XxlJobExecutor.class);

    // ---------------------- param ----------------------
    private String adminAddresses; // 调度中心部署跟地址 [选填]：如调度中心集群部署存在多个地址则用逗号分隔。执行器将会使用该地址进行"执行器心跳注册"和"任务结果回调"；为空则关闭自动注册
    private String accessToken; // 执行器通讯TOKEN [选填]：非空时启用
    private String appname; // 执行器AppName [选填]：执行器心跳注册分组依据；为空则关闭自动注册
    private String address; // 执行器注册 [选填]：优先使用该配置作为注册地址，为空时使用内嵌服务 ”IP:PORT“ 作为注册地址。从而更灵活的支持容器类型执行器动态IP和动态映射端口问题
    private String ip; // 执行器IP [选填]：默认为空表示自动获取IP，多网卡时可手动设置指定IP，该IP不会绑定Host仅作为通讯实用；地址信息用于 "执行器注册" 和 "调度中心请求并触发任务"
    private int port; // 执行器端口号 [选填]：小于等于0则自动获取；默认端口为9999，单机部署多个执行器时，注意要配置不同执行器端口
    private String logPath; // 执行器运行日志文件存储磁盘路径 [选填] ：需要对该路径拥有读写权限；为空则使用默认路径
    private int logRetentionDays; // 执行器日志文件保存天数 [选填] ： 过期日志自动清理, 限制值大于等于3时生效; 否则, 如-1, 关闭自动清理功能

    // ---------------------- start + stop ----------------------
    public void start() throws Exception {

        // init logpath  初始化任务处理日志的路径目录初始化，值得一提这里的默认 base 路径不适用于 windows 需要重新设定
        XxlJobFileAppender.initLogPath(logPath);

        // init invoker, admin-client  初始化调度器
        initAdminBizList(adminAddresses, accessToken);


        // init JobLogFileCleanThread  启动日志文件清理线程，文件清理周期由用户指定，logRetentionDays=1 代表清理一天前的日志文件
        JobLogFileCleanThread.getInstance().start(logRetentionDays);

        // init TriggerCallbackThread  启动回调线程，这里值得一提，我们知道 xxl-job 的任务是通过调度器下发给执行器的，而当执行器执行完任务之后，会将执行结果存放在一个 queue 中。然后由这个回调线程不断的将 queue 中的结果返还给调度器。
        TriggerCallbackThread.getInstance().start();

        // init executor-server  启动内嵌服务器 EmbedServer
        initEmbedServer(address, ip, port, appname, accessToken);
    }
  
		// ---------------------- executor-server (rpc provider) ----------------------
    private EmbedServer embedServer = null;

    private void initEmbedServer(String address, String ip, int port, String appname, String accessToken) throws Exception {

        // fill ip port 寻找一个可用的端口，默认先使用 9999，这里值得一提的是找可用端口的代码：从 9999 开始，往下递减，判断可用的方法则是直接使用 java.net.ServerSocket 实例化，抛异常说明已经被占用了
        port = port>0?port: NetUtil.findAvailablePort(9999);
        ip = (ip!=null&&ip.trim().length()>0)?ip: IpUtil.getIp();

        // generate address  拼接了一个http协议的请求地址
        if (address==null || address.trim().length()==0) {
            String ip_port_address = IpUtil.getIpPort(ip, port);   // registry-address：default use address to registry , otherwise use ip:port if address is null
            address = "http://{ip_port}/".replace("{ip_port}", ip_port_address);
        }

        // accessToken
        if (accessToken==null || accessToken.trim().length()==0) {
            logger.warn(">>>>>>>>>>> xxl-job accessToken is empty. To ensure system security, please set the accessToken.");
        }

        // start  启动netty服务器
        embedServer = new EmbedServer();
        embedServer.start(address, port, appname, accessToken);
    }
  
  // ... 省略其他方法和属性
  
}
```

netty 服务器的作用是与调度器进行通信，相关的具体配置，我们下一章节再结合 netty 进行讲解。

### 2.1 IJobHandler

IJobHandler 默认结构如下： (这里实际就是一种模板模式的应用)

![image-20220423233605403](http://blog-1259650185.cosbj.myqcloud.com/img/202204/23/1650728165.png)

还有另一种方式就是直接手动注册：(缓存是存在静态map 中， 所以我们也可以自己注册。我们只需要让其根据name 能找到对应的handler即可)

```java
static {
  // 手动通过如下方式注入到执行器容器。
  XxlJobExecutor.registJobHandler("XXLClassJob", new XXLClassJob());
}
```

## 3. 动态代码执行

Glue = 胶水，胶水代码这个词还是挺贴切的。xxl-job 支持的胶水代码主要是两部分，JVM类代码和脚本语言代码。

```java
public enum GlueTypeEnum {

    BEAN("BEAN", false, null, null),
    GLUE_GROOVY("GLUE(Java)", false, null, null),
    GLUE_SHELL("GLUE(Shell)", true, "bash", ".sh"),
    GLUE_PYTHON("GLUE(Python)", true, "python", ".py"),
    GLUE_PHP("GLUE(PHP)", true, "php", ".php"),
    GLUE_NODEJS("GLUE(Nodejs)", true, "node", ".js"),
    GLUE_POWERSHELL("GLUE(PowerShell)", true, "powershell", ".ps1");
  // ... 省略其他方法和属性
  
}
```

脚本代码的执行与glue包没什么关系，我们从任务执行的一段代码中找到相关部分的截出来。 

首先判断判断是否是脚本代码，最后使用脚本代码生成了一个 ScriptJobHandler 对象，重点就在这里。

<img src="http://blog-1259650185.cosbj.myqcloud.com/img/202204/21/1650470772.png" alt="截屏2022-04-21 00.03.26" style="zoom:33%;" />

ScriptJobHandler.execute()

```java
// ScriptJobHandler.java
@Override
public void execute() throws Exception {

    if (!glueType.isScript()) {
        XxlJobHelper.handleFail("glueType["+ glueType +"] invalid.");
        return;
    }

    // cmd  获取cmd，cmd即为各种脚本语言的执行器，也即执行器本地必须安装了相关的脚本执行器才可以执行相关脚本
    String cmd = glueType.getCmd();

    // make script file  将脚本保存成一个本地文件，准备之后直接用执行器执行
    String scriptFileName = XxlJobFileAppender.getGlueSrcPath()
            .concat(File.separator)
            .concat(String.valueOf(jobId))
            .concat("_")
            .concat(String.valueOf(glueUpdatetime))
            .concat(glueType.getSuffix());
    File scriptFile = new File(scriptFileName);
    if (!scriptFile.exists()) {
        ScriptUtil.markScriptFile(scriptFileName, gluesource);
    }

    // log file  获取到日志文件地址
    String logFileName = XxlJobContext.getXxlJobContext().getJobLogFileName();

    // script params：0=param、1=分片序号、2=分片总数  对广播分片模式的支持
    String[] scriptParams = new String[3];
    scriptParams[0] = XxlJobHelper.getJobParam();
    scriptParams[1] = String.valueOf(XxlJobContext.getXxlJobContext().getShardIndex());
    scriptParams[2] = String.valueOf(XxlJobContext.getXxlJobContext().getShardTotal());

    // invoke  使用Java.lang.Runtime执行命令
    XxlJobHelper.log("----------- script file:"+ scriptFileName +" -----------");
    int exitValue = ScriptUtil.execToFile(cmd, scriptFileName, logFileName, scriptParams);

    if (exitValue == 0) {
        XxlJobHelper.handleSuccess();
        return;
    } else {
        XxlJobHelper.handleFail("script exit value("+exitValue+") is failed");
        return ;
    }

}

// ScriptUtil.java
public static int execToFile(String command, String scriptFile, String logFile, String... params) throws IOException {

    FileOutputStream fileOutputStream = null;
    Thread inputThread = null;
    Thread errThread = null;
    try {
        // file
        fileOutputStream = new FileOutputStream(logFile, true);

        // command
        List<String> cmdarray = new ArrayList<>();
        cmdarray.add(command);
        cmdarray.add(scriptFile);
        if (params!=null && params.length>0) {
            for (String param:params) {
                cmdarray.add(param);
            }
        }
        String[] cmdarrayFinal = cmdarray.toArray(new String[cmdarray.size()]);

        // process-exec
        final Process process = Runtime.getRuntime().exec(cmdarrayFinal);

        // log-thread
        final FileOutputStream finalFileOutputStream = fileOutputStream;
        inputThread = new Thread(new Runnable() {
            @Override
            public void run() {
                try {
                    copy(process.getInputStream(), finalFileOutputStream, new byte[1024]);
                } catch (IOException e) {
                    XxlJobHelper.log(e);
                }
            }
        });
        errThread = new Thread(new Runnable() {
            @Override
            public void run() {
                try {
                    copy(process.getErrorStream(), finalFileOutputStream, new byte[1024]);
                } catch (IOException e) {
                    XxlJobHelper.log(e);
                }
            }
        });
        inputThread.start();
        errThread.start();

        // process-wait
        int exitValue = process.waitFor();      // exit code: 0=success, 1=error

        // log-thread join
        inputThread.join();
        errThread.join();

        return exitValue;
    } catch (Exception e) {
        XxlJobHelper.log(e);
        return -1;
    } finally {
        if (fileOutputStream != null) {
            try {
                fileOutputStream.close();
            } catch (IOException e) {
                XxlJobHelper.log(e);
            }

        }
        if (inputThread != null && inputThread.isAlive()) {
            inputThread.interrupt();
        }
        if (errThread != null && errThread.isAlive()) {
            errThread.interrupt();
        }
    }
}
```

## 4. JVM类的执行

Groovy 也是基于 JVM 的语言，类似的还有 Scala，虽然语法比 Java 精简，但是易读性可能会差一些。

xxl-job 支持的 JVM 类代码，其实也只是 Java 与 groovy ，因为这里直接使用了 GroovyClassLoader 作为类加载器。 

Glue工厂类的初始化：

SpringGlueFactory 是 GlueFactory 的子类，在前文的执行器启动过程中，Spring 框架下加载的，是 SpringGlueFactory。 

> SpringGlueFactory 相较于GlueFactory只是多了一个方法——injectService，看方法名字也能明白，作用是将一个object注入到spring容器中，作为一个bean存在。

```java
// SpringGlueFactory.java
@Override
public void injectService(Object instance){
    if (instance==null) {
        return;
    }

    if (XxlJobSpringExecutor.getApplicationContext() == null) {
        return;
    }

    Field[] fields = instance.getClass().getDeclaredFields();
    for (Field field : fields) {
        if (Modifier.isStatic(field.getModifiers())) {
            continue;
        }

        Object fieldBean = null;
        // with bean-id, bean could be found by both @Resource and @Autowired, or bean could only be found by @Autowired

        if (AnnotationUtils.getAnnotation(field, Resource.class) != null) {
            try {
                Resource resource = AnnotationUtils.getAnnotation(field, Resource.class);
                if (resource.name()!=null && resource.name().length()>0){
                    fieldBean = XxlJobSpringExecutor.getApplicationContext().getBean(resource.name());
                } else {
                    fieldBean = XxlJobSpringExecutor.getApplicationContext().getBean(field.getName());
                }
            } catch (Exception e) {
            }
            if (fieldBean==null ) {
                fieldBean = XxlJobSpringExecutor.getApplicationContext().getBean(field.getType());
            }
        } else if (AnnotationUtils.getAnnotation(field, Autowired.class) != null) {
            Qualifier qualifier = AnnotationUtils.getAnnotation(field, Qualifier.class);
            if (qualifier!=null && qualifier.value()!=null && qualifier.value().length()>0) {
                fieldBean = XxlJobSpringExecutor.getApplicationContext().getBean(qualifier.value());
            } else {
                fieldBean = XxlJobSpringExecutor.getApplicationContext().getBean(field.getType());
            }
        }

        if (fieldBean!=null) {
            field.setAccessible(true);
            try {
                field.set(instance, fieldBean);
            } catch (IllegalArgumentException e) {
                logger.error(e.getMessage(), e);
            } catch (IllegalAccessException e) {
                logger.error(e.getMessage(), e);
            }
        }
    }
}
```

GlueFactory：
核心的主要是 GroovyClassLoader 与一个代码加载方法，

```java
public class GlueFactory {


	private static GlueFactory glueFactory = new GlueFactory();
	public static GlueFactory getInstance(){
		return glueFactory;
	}
	public static void refreshInstance(int type){
		if (type == 0) {
			glueFactory = new GlueFactory();
		} else if (type == 1) {
			glueFactory = new SpringGlueFactory();
		}
	}


	/**
	 * groovy class loader
	 */
	private GroovyClassLoader groovyClassLoader = new GroovyClassLoader();
	private ConcurrentMap<String, Class<?>> CLASS_CACHE = new ConcurrentHashMap<>();

	/**
	 * load new instance, prototype
	 *
	 * @param codeSource
	 * @return
	 * @throws Exception
	 */
	public IJobHandler loadNewInstance(String codeSource) throws Exception{
		if (codeSource!=null && codeSource.trim().length()>0) {
			Class<?> clazz = getCodeSourceClass(codeSource); // 过 GroovyClassLoader 编译class
			if (clazz != null) {
				Object instance = clazz.newInstance(); // 通过class反射实例化一个object
				if (instance!=null) {
					if (instance instanceof IJobHandler) {
						this.injectService(instance); // 将object注入到spring容器中
						return (IJobHandler) instance;
					} else {
						throw new IllegalArgumentException(">>>>>>>>>>> xxl-glue, loadNewInstance error, "
								+ "cannot convert from instance["+ instance.getClass() +"] to IJobHandler");
					}
				}
			}
		}
		throw new IllegalArgumentException(">>>>>>>>>>> xxl-glue, loadNewInstance error, instance is null");
	}
	private Class<?> getCodeSourceClass(String codeSource){
		try {
			// md5
			byte[] md5 = MessageDigest.getInstance("MD5").digest(codeSource.getBytes());
			String md5Str = new BigInteger(1, md5).toString(16);

			Class<?> clazz = CLASS_CACHE.get(md5Str);
			if(clazz == null){
				clazz = groovyClassLoader.parseClass(codeSource);
				CLASS_CACHE.putIfAbsent(md5Str, clazz);
			}
			return clazz;
		} catch (Exception e) {
			return groovyClassLoader.parseClass(codeSource);
		}
	}

	/**
	 * inject service of bean field
	 *
	 * @param instance
	 */
	public void injectService(Object instance) {
		// do something
	}

}
```

到此结束，看过类加载器相关面试题的话这部分还是比较好理解的。

另外，动态代码加载也不只是GroovyClassLoader这一种方式，使用JDK中的tools.jar一样可以做到这个功能，当然就只支持Java语法了。



## 参考

[xxl-job源码阅读——（七）执行器启动与动态代码加载解读](https://mp.weixin.qq.com/s?__biz=MzU0MzQ1NTM4MQ==&mid=2247483846&idx=1&sn=3ebdd0f44cdadd1d5375c8843dab1423&chksm=fb0a603ccc7de92a4d4e56f37f19b350d7e75ab93fe0899281939d89d197a4b90e0aa619e806&cur_album_id=2226684892866740226&scene=190#rd)

[xxl-job源码(二)客户端源码 ](https://www.cnblogs.com/qlqwjy/p/15510940.html)
