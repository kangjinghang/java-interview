一般情况下，开源框架都会提供插件或其他形式的拓展点，供开发者自行拓展。这样的好处是显而易见的，一是增加了框架的灵活性。二是开发者可以结合实际需求，对框架进行拓展，使其能够更好的工作。以 MyBatis 为例，我们可基于 MyBatis 插件机制实现分页、分表，监控等功能。由于插件和业务无关，业务也无法感知插件的存在。因此可以无感植入插件，在无形中增强功能。

开发 MyBatis 插件需要对 MyBatis 比较深了解才行，一般来说最好能够掌握 MyBatis 的源码，门槛相对较高。本篇文章在分析完 MyBatis 插件机制后，会手写一个简单的分页插件，以帮助大家更好的掌握 MyBatis 插件的编写。

## 1. 插件机制原理

我们在编写插件时，除了需要让插件类实现 Interceptor 接口外，还需要通过注解标注该插件的拦截点。所谓拦截点指的是插件所能拦截的方法，MyBatis 所允许拦截的方法如下：

1. Executor: update, query, flushStatements, commit, rollback, getTransaction, close, isClosed

2. ParameterHandler: getParameterObject, setParameters

3. ResultSetHandler: handleResultSets, handleOutputParameters

4. StatementHandler: prepare, parameterize, batch, update, query

如果我们想要拦截 Executor 的 query 方法，那么可以这样定义插件。

```java
@Intercepts({
  @Signature(
    type = Executor.class,
    method = "query",
    args ={MappedStatement.class, Object.class, RowBounds.class, 
  ResultHandler.class} )
})
public class ExamplePlugin implements Interceptor {
// 省略逻辑
}
```

除此之外，我们还需将插件配置到相关文件中。这样 MyBatis 在启动时可以加载插件，并保存插件实例到相关对象（InterceptorChain，拦截器链）中。待准备工作做完后，MyBatis 处于就绪状态。我们在执行 SQL 时，需要先通过 DefaultSqlSessionFactory 创 建SqlSession 。Executor 实例会在创建 SqlSession 的过程中被创建，Executor 实例创建完毕后，MyBatis 会通过 JDK 动态代理为实例生成代理类。这样，插件逻辑即可在 Executor 相关方法被调用前执行。以上就是 MyBatis 插件机制的基本原理。接下来，我们来看一下原理背后对应的源码是怎样的。

### 1.1 植⼊插件逻辑

本节，我将以 Executor 为例，分析 MyBatis 是如何为 Executor 实例植入插件逻辑的。Executor 实例是在开启 SqlSession 时被创建的，因此，下面我们从源头进行分析。先来看一下 SqlSession 开启的过程。

```java
// DefaultSqlSessionFactory.java
public SqlSession openSession() {
    return openSessionFromDataSource(configuration.getDefaultExecutorType(), null, false);
}

private SqlSession openSessionFromDataSource(ExecutorType execType, TransactionIsolationLevel level, boolean autoCommit) {
    Transaction tx = null;
    try {
        // 省略部分逻辑
        
        // 创建 Executor
        final Executor executor = configuration.newExecutor(tx, execType);
        return new DefaultSqlSession(configuration, executor, autoCommit);
    } 
    catch (Exception e) {...} 
    finally {...}
}
```

Executor 的创建过程封装在 Configuration 中，我们跟进去看看看。

```java
// Configuration.java
public Executor newExecutor(Transaction transaction, ExecutorType executorType) {
    executorType = executorType == null ? defaultExecutorType : executorType;
    executorType = executorType == null ? ExecutorType.SIMPLE : executorType;
    Executor executor;
    
    // 根据 executorType 创建相应的 Executor 实例
    if (ExecutorType.BATCH == executorType) {...} 
    else if (ExecutorType.REUSE == executorType) {...} 
    else {
        executor = new SimpleExecutor(this, transaction);
    }
    if (cacheEnabled) {
        executor = new CachingExecutor(executor);
    }
    
    // 植入插件
    executor = (Executor) interceptorChain.pluginAll(executor);
    return executor;
}
```

如上，newExecutor 方法在创建好 Executor 实例后，紧接着通过拦截器链 interceptorChain 为 Executor 实例植入代理逻辑。那下面我们看一下 InterceptorChain 的代码是怎样的。

```java
public class InterceptorChain {

  private final List<Interceptor> interceptors = new ArrayList<>();

  public Object pluginAll(Object target) {
    for (Interceptor interceptor : interceptors) { // 遍历拦截器集合
      target = interceptor.plugin(target); // 调用拦截器的 plugin 方法植入相应的插件逻辑
    }
    return target; // 返回的是创建好的代理对象
  }

  public void addInterceptor(Interceptor interceptor) { // 添加插件实例到 interceptors 集合中
    interceptors.add(interceptor);
  }

  public List<Interceptor> getInterceptors() { // 获取插件列表
    return Collections.unmodifiableList(interceptors);
  }

}
```

以上是 InterceptorChain 的全部代码，比较简单。它的 pluginAll 方法会调用具体插件的 plugin 方法植入相应的插件逻辑。如果有多个插件，则会多次调用 plugin 方法，最终生成一个层层嵌套的代理类。形如下面：

<img src="http://blog-1259650185.cosbj.myqcloud.com/img/202203/04/1646359342.jpeg" alt="9" style="zoom:50%;" />

当 Executor 的某个方法被调用的时候，插件逻辑会先行执行。执行顺序由外而内，比如上图的执行顺序为 plugin3 → plugin2 → Plugin1 → Executor。plugin 方法是由具体的插件类实现，不过该方法代码一般比较固定，所以下面找个示例分析一下。

```java
// ExamplePlugin.java
public Object plugin(Object target) {
    return Plugin.wrap(target, this);
}

// Plugin.java
public static Object wrap(Object target, Interceptor interceptor) {
    /*
     * 获取插件类 @Signature 注解内容，并生成相应的映射结构。形如下面：
     * {
     *     Executor.class : [query, update, commit],
     *     ParameterHandler.class : [getParameterObject, setParameters]
     * }
     */
    Map<Class<?>, Set<Method>> signatureMap = getSignatureMap(interceptor);
    Class<?> type = target.getClass();
    // 获取目标类实现的接口
    Class<?>[] interfaces = getAllInterfaces(type, signatureMap);
    if (interfaces.length > 0) {
        // 通过 JDK 动态代理为目标类生成代理类，然后返回
        return Proxy.newProxyInstance(
            type.getClassLoader(),
            interfaces,
            new Plugin(target, interceptor, signatureMap));
    }
    return target;
}
```

如上，plugin 方法在内部调用了 Plugin 类的 wrap 方法，用于为目标对象生成代理。Plugin类实现了 InvocationHandler 接口，因此它可以作为参数传给 Proxy 的 newProxyInstance方法。

到这里，关于插件植入的逻辑就分析完了。接下来，我们来看看插件逻辑是怎样执行的。

### 1.2 执⾏插件逻辑

Plugin 实现了 InvocationHandler 接口，因此它的 invoke 方法会拦截所有的方法调用。invoke 方法会对所拦截的方法进行检测，以决定是否执行插件逻辑。该方法的逻辑如下：

```java
// Plugin.java
// 被代理类执行每个方法的时候
@Override
public Object invoke(Object proxy, Method method, Object[] args) throws Throwable {
  try { // 我这个 plugin 拦截哪些类的哪些方法呢？
    Set<Method> methods = signatureMap.get(method.getDeclaringClass()); // 获取被拦截方法列表，比如：signatureMap.get(Executor.class)，可能返回 [query, update, commit]
    // 就是说，我自己这个 plugin 设置的要拦截的类和方法命中了
    if (methods != null && methods.contains(method)) { // 检测方法列表是否包含被拦截的方法
      return interceptor.intercept(new Invocation(target, method, args)); // 把被代理的对象，当前方法，参数 组装成 Invocation 执行插件逻辑
    }
    return method.invoke(target, args); // 执行被拦截的方法
  } catch (Exception e) {
    throw ExceptionUtil.unwrapThrowable(e);
  }
}
```

invoke 方法的代码比较少，逻辑不难理解。首先，invoke 方法会检测被拦截方法是否配置在插件的 @Signature 注解中，若是，则执行插件逻辑，否则执行被拦截方法。插件逻辑封装在 intercept 中，该方法的参数类型为 Invocation。Invocation 主要用于存储目标类，方法以及方法参数列表。下面简单看一下该类的定义。

```java
public class Invocation {

    private final Object target;
    private final Method method;
    private final Object[] args;

    public Invocation(Object target, Method method, Object[] args) {
        this.target = target;
        this.method = method;
        this.args = args;
    }

    // 省略部分代码

    public Object proceed() throws InvocationTargetException, IllegalAccessException {
        // 调用被拦截的方法
        return method.invoke(target, args);
    }
}
```

关于插件的执行逻辑就分析到这，整个过程不难理解，大家简单看看即可。

## 2. 实现⼀个分页插件

为了更好的向大家介绍 MyBatis 的插件机制，本节将实现一个 MySQL 数据库分页插件。相关代码如下：

```java
@Intercepts({
    @Signature(
        type = Executor.class, // 目标类
        method = "query", // 目标方法
        args ={MappedStatement.class, Object.class, RowBounds.class, ResultHandler.class}
    )
})
public class MySqlPagingPlugin implements Interceptor {

    private static final Integer MAPPED_STATEMENT_INDEX = 0;
    private static final Integer PARAMETER_INDEX = 1;
    private static final Integer ROW_BOUNDS_INDEX = 2;

    @Override
    public Object intercept(Invocation invocation) throws Throwable {
        Object[] args = invocation.getArgs();
        RowBounds rb = (RowBounds) args[ROW_BOUNDS_INDEX];
        if (rb == RowBounds.DEFAULT) { // 无需分页
            return invocation.proceed();
        }
        args[ROW_BOUNDS_INDEX] = RowBounds.DEFAULT; // 将原 RowBounds 参数设为 RowBounds.DEFAULT，关闭 MyBatis 内置的分页机制

        MappedStatement ms = (MappedStatement) args[MAPPED_STATEMENT_INDEX];
        BoundSql boundSql = ms.getBoundSql(args[PARAMETER_INDEX]);

        System.out.println();
        String sql = boundSql.getSql();  // 获取 SQL 语句，拼接 limit 语句
        String limit = String.format("LIMIT %d,%d", rb.getOffset(), rb.getLimit());
        sql = sql + " " + limit;
        // 创建一个 StaticSqlSource，并将拼接好的 sql 传入
        SqlSource sqlSource = new StaticSqlSource(ms.getConfiguration(), sql, boundSql.getParameterMappings());
        // 通过反射获取并设置 MappedStatement 的 sqlSource 字段
        Field field = MappedStatement.class.getDeclaredField("sqlSource");
        field.setAccessible(true);
        field.set(ms, sqlSource);

        return invocation.proceed(); // 执行被拦截方法
    }

    @Override
    public Object plugin(Object target) {
        return Plugin.wrap(target, this);
    }

    @Override
    public void setProperties(Properties properties) {
    }
}
```

上面的分页插件通过 RowBounds 参数获取分页信息，并生成相应的 limit 语句。之后拼接 sql，并使用该 sql 作为参数创建 StaticSqlSource。最后通过反射替换 MappedStatement 对象中的 sqlSource 字段。下面，写点测试代码验证一下插件是否可以正常运行。先来看一下 Dao 接口与映射文件的定义：

```java
public interface StudentDao {
    List<Student> findByPaging(@Param("id") Integer id, RowBounds rb);
}
```

```xml
<mapper namespace="xyz.coolblog.dao6.StudentDao">
    <select id="findByPaging" resultType="xyz.coolblog.model5.Student">
        SELECT
            `id`, `name`, `age`
        FROM
            student
        WHERE
            id > #{id}
    </select>
</mapper>
```

测试代码如下：

```java
public class PluginTest {

    private SqlSessionFactory sqlSessionFactory;

    
    public void prepare() throws IOException {
        String resource = "mybatis-plugin-config.xml";
        InputStream inputStream = Resources.getResourceAsStream(resource);
        sqlSessionFactory = new SqlSessionFactoryBuilder().build(inputStream);
        inputStream.close();
    }

    
    public void testPlugin() {
        SqlSession session = sqlSessionFactory.openSession();
        try {
            StudentDao studentDao = session.getMapper(StudentDao.class);
            studentDao.findByPaging(1, new RowBounds(20, 10));
        } finally {
            session.close();
        }
    }
}
```

上面代码运行之后，会打印如下日志。

```java
DEBUG [main] - ==>  Preparing: SELECT `id`, `name`, `age` FROM student WHERE id > ? LIMIT 20,10 
DEBUG [main] - ==> Parameters: 1(Integer)
DEBUG [main] - <==      Total: 0
```

在上面的输出中，SQL 语句中包含了 LIMIT 字样，这说明插件生效了。

## 3. 本章⼩结

到此，关于 MyBatis 插件机制就分析完了。总体来说，MyBatis 插件机制比较简单。但实现一个插件却较为复杂，需要对 MyBatis 比较了解才行。因此，若想写出高效的插件，还需深入学习源码才行。

## 参考

[MyBatis 源码分析 - 插件机制](https://www.tianxiaobo.com/2018/08/26/MyBatis-%E6%BA%90%E7%A0%81%E5%88%86%E6%9E%90-%E6%8F%92%E4%BB%B6%E6%9C%BA%E5%88%B6/)
