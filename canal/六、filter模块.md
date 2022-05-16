## 1. Filter 模块简介

filter 模块用于对 binlog 进行过滤。在实际开发中，一个 mysql 实例中可能会有多个库，每个库里面又会有多个表，可能我们只是想订阅某个库中的部分表，这个时候就需要进行过滤。也就是说，parser 模块解析出来 binlog 之后，会进行一次过滤之后，才会存储到 store模块中。

过滤规则的配置既可以在 canal 服务端进行，也可以在客户端进行。

### 1.1 服务端配置

我们在配置一个 canal instance 时，在 instance.properties 中有以下两个配置项：

![78DD8A64-DEC1-4472-92AC-79F3E81431A2.png](http://static.tianshouzhi.com/ueditor/upload/image/20181103/1541178347274053823.png)

其中：

canal.instance.filter.regex 用于配置白名单，也就是我们希望订阅哪些库，哪些表，默认值为.*\\..*，也就是订阅所有库，所有表。

canal.instance.filter.black.regex 用于配置黑名单，也就是我们不希望订阅哪些库，哪些表。没有默认值，也就是默认黑名单为空。

 需要注意的是，在过滤的时候，会先根据白名单进行过滤，再根据黑名单过滤。意味着，如果一张表在白名单和黑名单中都出现了，那么这张表最终不会被订阅到，因为白名单通过后，黑名单又将这张表给过滤掉了。

另外一点值得注意的是，过滤规则使用的是 perl 正则表达式，而不是 jdk 自带的正则表达式。意味着 filter 模块引入了其他依赖，来进行匹配。具体来说，filter模块的 pom.xml 中包含以下两个依赖： 

```xml
<dependency>
   <groupId>com.googlecode.aviator</groupId>
   <artifactId>aviator</artifactId>
</dependency>
<dependency>
   <groupId>oro</groupId>
   <artifactId>oro</artifactId>
</dependency>
```

其中： 

**aviator**：是一个开源的、高性能、轻量级的 Java 语言实现的表达式求值引擎。

**oro：**全称为 Jakarta ORO，最全面以及优化得最好的正则表达式 API 之一，Jakarta-ORO 库以前叫做 OROMatcher，是由 DanielF. Savarese 编写，后来捐赠给了 apache Jakarta Project。canal 的过滤规则就是通过 oro 中的 Perl5Matcher 来进行完成的。

显然，对于 filter 模块的源码解析，实际上主要变成了对 aviator、oro 的分析。

这一点，我们可以从 filter 模块核心接口 `CanalEventFilter `的实现类中得到验证。CanalEventFilter 接口定义了一个 filter 方法： 

```java
public interface CanalEventFilter<T> {
    boolean filter(T event) throws CanalFilterException;
}
```

目前针对 CanalEventFilter 提供了 3 个实现类，都是基于开源的 Java 表达式求值引擎 Aviator，如下：

![05A55898-BFE1-4FAD-9D59-6EA6D10FBC85.png](http://static.tianshouzhi.com/ueditor/upload/image/20181103/1541178427861095029.png)

提示：这个 3 个实现都是以 Aviater 开头，应该是拼写错误，正确的应该是 Aviator。

其中：

- AviaterELFilter：基于 Aviator el 表达式的匹配过滤
- AviaterSimpleFilter：基于 Aviator 进行 tableName简单过滤计算，不支持正则匹配
- AviaterRegexFilter：基于 Aviator 进行 tableName 正则匹配的过滤算法。内部使用到了一个 RegexFunction 类，这是对 Aviator 自定义的函数的扩展，内部使用到了 oro 中的 Perl5Matcher 来进行正则匹配。 

需要注意的是，尽管 filter 模块提供了 3 个基于 Aviator 的过滤器实现，但是实际上使用到的只有 AviaterRegexFilter。这一点可以在canal-deploy 模块提供的 xxx-instance.xml 配置文件中得要验证。以 default-instance.xml 为例，eventParser 这个 bean 包含以下两个属性：

```xml
<bean id="eventParser" class="com.alibaba.otter.canal.parse.inbound.mysql.MysqlEventParser">
   <!-- ... -->
   <!-- 解析过滤处理 -->
   <property name="eventFilter">
      <bean class="com.alibaba.otter.canal.filter.aviater.AviaterRegexFilter" >
         <constructor-arg index="0" value="${canal.instance.filter.regex:.*\..*}" />
      </bean>
   </property>
  
   <property name="eventBlackFilter">
      <bean class="com.alibaba.otter.canal.filter.aviater.AviaterRegexFilter" >
         <constructor-arg index="0" value="${canal.instance.filter.black.regex:}" />
         <constructor-arg index="1" value="false" />
      </bean>
   </property>
  <!-- ... -->
</bean>
```

 其中：

- eventFilter属性：使用配置项 canal.instance.filter.regex 的值进行白名单过滤。
-  eventBlackFilter属性：使用配置项 canal.instance.filter.black.regex 进行黑名单过滤。

这两个属性的值都是通过一个内部 bean 的方式进行配置，类型都是 AviaterRegexFilter。由于其他两个类型的 CanalEventFilter 实现在parser 模块中并没有使用到，因此后文中，我们也只会对 AviaterRegexFilter 进行分析。

前面提到，parser 模块在过滤的时候，会先根据 canal.instance.filter.regex 进行白名单过滤，再根据 canal.instance.filter.black.regex进行黑名单过滤。到这里，实际上就是先通过 eventFilter 进行白名单过滤，通过 eventBlackFilter 进行黑名单过滤。

parser 模块实际上会将 eventFilter、eventBlackFilter 设置到一个 LogEventConvert 对象中，这个对象有2个方法：parseQueryEvent 和 parseRowsEvent 都进行了过滤。以 parseRowsEvent 方法为例：

com.alibaba.otter.canal.parse.inbound.mysql.dbsync.LogEventConvert#parseRowsEvent(省略部分代码片段)

```java
private Entry parseRowsEvent(RowsLogEvent event) {
				...
        TableMapLogEvent table = event.getTable();
        String fullname = table.getDbName() + "." + table.getTableName();
        // check name filter
        if (nameFilter != null && !nameFilter.filter(fullname)) {
            return null;
        }
        if (nameBlackFilter != null && nameBlackFilter.filter(fullname)) {
            return null;
        }
				...
```

这里的 nameFilter、nameBlackFilter 实际上就是我们设置到 parser 中的 eventFilter、eventBlackFilter，只不过 parser 将其设置到LogEventConvert 对象中换了一个名字。

可以看到，的确是先使用 nameFilter 进行白名单过滤，再使用 nameBlackFilter 进行黑名单过滤。在过滤时，使用`dbName+"."+tableName`作为参数，进行过滤。如果被过滤掉了，就返回 null。

再次提醒，由于黑名单后过滤，因此如果希望订阅一个表，一定不要在黑名单中出现。

### 1.2 客户端配置

上面提到的都是服务端配置。canal 也支持客户端配置过滤规则。举例来说，假设一个库有 10 张表，一个 client 希望订阅其中 5 张表，另一个 client 希望订阅另5张表。此时，服务端可以订阅 10 张表，当 client 来消费的时候，根据 client 的过滤规则只返回给对应的 binlog event。

客户端指定过滤规则通过 client 模块中的 CanalConnector 的 subscribe 方法来进行，subscribe 有两种重载形式，如下： 

```java
//对于第一个subscribe方法，不指定filter，以服务端的filter为准
void subscribe() throws CanalClientException;
 
// 指定了filter：
// 如果本次订阅中filter信息为空，则直接使用canal server服务端配置的filter信息
// 如果本次订阅中filter信息不为空，目前会直接替换canal server服务端配置的filter信息，以本次提交的为准
void subscribe(String filter) throws CanalClientException;
```

通过不同 client 指定不同的过滤规则，可以达到服务端一份数据供多个 client 进行订阅消费的效果。     

然而，想法是好的，现实确是残酷的，由于目前一个 canal instance 只允许一个 client 订阅，因此目前还达不到这种效果。读者明白这种设计的初衷即可。

最后列出 filter 模块的目录结构，这个模块的类相当的少，如下： 

![DDB7E291-F912-4628-9729-CEFFDB448C76.png](http://static.tianshouzhi.com/ueditor/upload/image/20181103/1541178589738009999.png)

到此，filter 模块的主要作用已经讲解完成。接着应该针对 AviaterRegexFilter 进行源码分析，由于其基于 Aviator 和 oro 基础之上编写，因此先对 Aviator 和 oro 进行介绍。

## 2. Aviator 快速入门

说明，这里关于 Aviator 的相关内容直接摘录自官网：https://github.com/killme2008/aviatorscript，并没有包含 Aviator 所有内容，仅仅是就 canal 内部使用到的一些特性进行讲解。

Aviator 是一个高性能、轻量级的 Java 语言实现的表达式求值引擎，主要用于各种表达式的动态求值。现在已经有很多开源可用的 Java 表达式求值引擎，为什么还需要 Avaitor 呢?

Aviator的设计目标是轻量级和高性能,相比于 Groovy、JRuby 的笨重， Aviator 非常小， 加上依赖包也才 537K,不算依赖包的话只有 70K。 当然，Aviator 的语法是受限的，它不是一门完整的语言，而只是语言的一小部分集合。

其次, Aviator 的实现思路与其他轻量级的求值器很不相同，其他求值器一般都是通过解释的方式运行，而 Aviator 则是直接将表达式编译成 JVM 字节码, 交给 JVM 去执行。简单来说，Aviator 的定位是介于 Groovy 这样的重量级脚本语言和 IKExpression 这样的轻量级表达式引擎之间。

Aviator 的特性：

- 支持绝大多数运算操作符，包括算术操作符、关系运算符、逻辑操作符、位运算符、正则匹配操作符(=~)、三元表达式(?:)
- 支持操作符优先级和括号强制设定优先级
- 逻辑运算符支持短路运算。
- 支持丰富类型，例如nil、整数和浮点数、字符串、正则表达式、日期、变量等，支持自动类型转换。
- 内置一套强大的常用函数库
- 可自定义函数，易于扩展
- 可重载操作符
- 支持大数运算(BigInteger)和高精度运算(BigDecimal)
- 性能优秀

引入Aviator, 从 3.2.0 版本开始， Aviator 仅支持 JDK 7 及其以上版本。 JDK 6 请使用 3.1.1 这个稳定版本。 

```xml
<dependency>
    <groupId>com.googlecode.aviator</groupId>
    <artifactId>aviator</artifactId>
    <version>{version}</version>
</dependency>
```

注意：canal 1.0.24 中使用的是 Aviator 2.2.1版本。

Aviator 的使用都是集中通过 com.googlecode.aviator.AviatorEvaluator 这个入口类来处理。在 canal 提供的 AviaterRegexFilter 中，仅仅使用到了Aviator部分功能，我们这里也仅仅就这些功能进行讲解。 

### 2.1 编译表达式

参考：[https://github.com/killme2008/aviator/wiki#%E7%BC%96%E8%AF%91%E8%A1%A8%E8%BE%BE%E5%BC%8F](https://github.com/killme2008/aviator/wiki#编译表达式)

案例： 

```java
public class TestAviator {
    public static void main(String[] args) {
        //1、定义一个字符串表达式
        String expression = "a-(b-c)>100";
        //2、对表达式进行编译，得到Expression对象实例
        Expression compiledExp = AviatorEvaluator.compile(expression);
        //3、准备计算表达式需要的参数
        Map<String, Object> env = new HashMap<String, Object>();
        env.put("a", 100.3);
        env.put("b", 45);
        env.put("c", -199.100);
        //4、执行表达式，通过调用Expression的execute方法
        Boolean result = (Boolean) compiledExp.execute(env);
        System.out.println(result);  // false
    }
}
```

通过`compile`方法可以将表达式编译成`Expression`的中间对象, 当要执行表达式的时候传入 env 并调用 Expression 的 execute 方法即可。 表达式中使用了括号来强制优先级, 这个例子还使用了 > 用于比较数值大小, 比较运算符 !=、==、>、>=、<、<= 不仅可以用于数值，也可以用于 String、Pattern、Boolean 等等, 甚至是任何用户传入的两个都实现了 java.lang.Comparable 接口的对象之间。

编译后的结果你可以自己缓存，也可以交给 Aviator 帮你缓存， AviatorEvaluator 内部有一个全局的缓存池，如果你决定缓存编译结果, 可以通过:

```java
public static Expression compile(String expression, boolean cached)
```

将 cached 设置为 true 即可, 那么下次编译同一个表达式的时候将直接返回上一次编译的结果。

使缓存失效通过以下方法：

```java
public static void invalidateCache(String expression)
```

### 2.2 自定义函数 

参考：[https://github.com/killme2008/aviator/wiki#%E8%87%AA%E5%AE%9A%E4%B9%89%E5%87%BD%E6%95%B0](https://github.com/killme2008/aviator/wiki#自定义函数)

Aviator 除了内置的函数之外，还允许用户自定义函数，只要实现 com.googlecode.aviator.runtime.type.AviatorFunction 接口，并注册到 AviatorEvaluator 即可使用。AviatorFunction 接口十分庞大，通常来说你并不需要实现所有的方法，只要根据你的方法的参 数个数， 继承 AbstractFunction 类并 override 相应方法即可。

可以看一个例子，我们实现一个 add 函数来做数值的相加：

```java
//1、自定义函数AddFunction，继承AbstractFunction，覆盖其getName方法和call方法
class AddFunction extends AbstractFunction {
     // 1.1 getName用于返回函数的名字，之后需要使用这个函数时，达表示需要以add开头
    public String getName() {
        return "add";
    }
    // 1.2 在执行计算时，call方法将会被回调。call方法有多种重载形式，参数可以分为2类：
    // 第一类：所有的call方法的第一个参数都是Map类型的env参数。
    // 第二类：不同数量的AviatorObject参数。由于在这里我们的add方法只接受2个参数，
    // 所以覆盖接受2个AviatorObject参数call方法重载形式
    // 用户在执行时，通过"函数名(参数1,参数2,...)"方式执行函数，如："add(1, 2)"
    @Override
    public AviatorObject call(Map<String, Object> env, AviatorObject arg1, AviatorObject arg2) {
        Number left = FunctionUtils.getNumberValue(arg1, env);
        Number right = FunctionUtils.getNumberValue(arg2, env);
        return new AviatorDouble(left.doubleValue() + right.doubleValue());
    }
}

public class TestAviator {
    public static void main(String[] args) {
        //注册函数
        AviatorEvaluator.addFunction(new AddFunction());
        System.out.println(AviatorEvaluator.execute("add(1, 2)"));           // 3.0
        System.out.println(AviatorEvaluator.execute("add(add(1, 2), 100)")); // 103.0
    }
}
```

注册函数通过 AviatorEvaluator.addFunction 方法, 移除可以通过 removeFunction。另外， FunctionUtils 提供了一些方便参数类型转换的方法。

## 3. AviaterRegexFilter 源码解析

AviaterRegexFilter 实现了 CanalEventFilter 接口，主要是实现其 filter 方法对 binlog 进行过滤。

首先对 AviaterRegexFilter 中定义的字段和构造方法进行介绍：

com.alibaba.otter.canal.filter.aviater.AviaterRegexFilter 

```java
public class AviaterRegexFilter implements CanalEventFilter<String> {
    //我们的配置的binlog过滤规则可以由多个正则表达式组成，使用逗号”,"进行分割
    private static final String SPLIT = ",";
    //将经过逗号",”分割后的过滤规则重新使用|串联起来
    private static final String PATTERN_SPLIT = "|";
    //canal定义的Aviator过滤表达式，使用了regex自定义函数，接受pattern和target两个参数
    private static final String FILTER_EXPRESSION = "regex(pattern,target)";
    //regex自定义函数实现，RegexFunction的getName方法返回regex，call方法接受两个参数
    private static final RegexFunction regexFunction = new RegexFunction();
    //对自定义表达式进行编译，得到Expression对象
    private final Expression exp = AviatorEvaluator.compile(FILTER_EXPRESSION, true);
    static {
        //将自定义函数添加到AviatorEvaluator中 
        AviatorEvaluator.addFunction(regexFunction);
    }
    //用于比较两个字符串的大小  
    private static final Comparator<String> COMPARATOR = new StringComparator();
    
    //用户设置的过滤规则，需要使用SPLIT进行分割
    final private String pattern;
    //在没有指定过滤规则pattern情况下的默认值，例如默认为true，表示用户不指定过滤规则情况下，总是返回所有的binlog event
    final private boolean defaultEmptyValue;
    public AviaterRegexFilter(String pattern) {
        this(pattern, true);
    }
    //构造方法
    public AviaterRegexFilter(String pattern, boolean defaultEmptyValue) {
        //1 给defaultEmptyValue字段赋值
        this.defaultEmptyValue = defaultEmptyValue;
 
        //2、给pattern字段赋值
        //2.1 将传入pattern以逗号",”进行分割，放到list中；如果没有指定pattern，则list为空，意味着不需要过滤
        List<String> list = null;
        if (StringUtils.isEmpty(pattern)) {
            list = new ArrayList<String>();
        } else {
            String[] ss = StringUtils.split(pattern, SPLIT);
            list = Arrays.asList(ss);
        }
        //2.2 对list中的pattern元素，按照从长到短的排序
        Collections.sort(list, COMPARATOR);
        
       //2.3 对pattern进行头尾完全匹配
        list = completionPattern(list);
        //2.4 将过滤规则重新使用|串联起来赋值给pattern
        this.pattern = StringUtils.join(list, PATTERN_SPLIT);
    }
...
}
```

上述代码中，2.2 步骤使用了 COMPARATOR 对 list 中分割后的 pattern 进行比较，COMPARATOR 的类型是 StringComparator，这是定义在 AviaterRegexFilter 中的一个静态内部类。

```java
/**
* 修复正则表达式匹配的问题，因为使用了 oro 的 matches，会出现：
* foo|foot 匹配 foot 出错，原因是 foot 匹配了 foo 之后，会返回 foo，但是 foo 的长度和 foot 的长度不一样
* 因此此类对正则表达式进行了从长到短的排序
*/
private static class StringComparator implements Comparator<String> {
    @Override
    public int compare(String str1, String str2) {
        if (str1.length() > str2.length()) {
            return -1;
        } else if (str1.length() < str2.length()) {
            return 1;
        } else {
            return 0;
        }
    }
}
```

上述代码 2.3节调用 completionPattern(list) 方法对 list 中分割后的 pattern 进行头尾完全匹配。

```java
/**
 * 修复正则表达式匹配的问题，即使按照长度递减排序，还是会出现以下问题：
 *  foooo|f.*t 匹配 fooooot 出错，原因是 fooooot 匹配了 foooo 之后，会将 fooo 和数据进行匹配，
 * 但是 foooo 的长度和 fooooot 的长度不一样，因此此类对正则表达式进行头尾完全匹配
 */
private List<String> completionPattern(List<String> patterns) {
    List<String> result = new ArrayList<String>();
    for (String pattern : patterns) {
        StringBuffer stringBuffer = new StringBuffer();
        stringBuffer.append("^");
        stringBuffer.append(pattern);
        stringBuffer.append("$");
        result.add(stringBuffer.toString());
    }
    return result;
}
```

**filter方法**

AviaterRegexFilter 类中最重要的就是 filter 方法，由这个方法执行过滤，如下： 

```java
//1 参数：前面已经分析过parser模块的LogEventConvert中，会将binlog event的 dbName+”."+tableName当做参数过滤
public boolean filter(String filtered) throws CanalFilterException {
    //2 如果没有指定匹配规则，返回默认值
    if (StringUtils.isEmpty(pattern)) {
        return defaultEmptyValue;
    }
    //3 如果需要过滤的dbName+”.”+tableName是一个空串，返回默认值
    //提示：一些类型的binlog event，如heartbeat，并不是真正修改数据，这种类型的event是没有库名和表名的
    if (StringUtils.isEmpty(filtered)) {
        return defaultEmptyValue;
    }
    //4 将传入的dbName+”."+tableName通过canal自定义的Aviator扩展函数RegexFunction进行计算
    Map<String, Object> env = new HashMap<String, Object>();
    env.put("pattern", pattern);
    env.put("target", filtered.toLowerCase());
    return (Boolean) exp.execute(env);
}
```

第4步通过 exp.execute 方法进行过滤判断，前面已经看到，exp 这个 Expression 实例是通过 "regex(pattern,target)" 编译得到。根据前面对 AviatorEvaluator 的介绍，其应该调用一个名字为 regex 的 Aviator 自定义函数，这个函数接受2个参数。

RegexFunction 的实现如下所示：

com.alibaba.otter.canal.filter.aviater.RegexFunction 

```java
public class RegexFunction extends AbstractFunction {
    public AviatorObject call(Map<String, Object> env, AviatorObject arg1, AviatorObject arg2) {
        String pattern = FunctionUtils.getStringValue(arg1, env);
        String text = FunctionUtils.getStringValue(arg2, env);
        Perl5Matcher matcher = new Perl5Matcher();
        boolean isMatch = matcher.matches(text, PatternUtils.getPattern(pattern));
        return AviatorBoolean.valueOf(isMatch);
    }
    public String getName() {
        return "regex";
    }
}
```

可以看到，在这个函数里面，实际上是根据配置的过滤规则 pattern，以及需要过滤的内容 text(即dbName+”.”+tableName)，通过jarkata-oro 中 Perl5Matcher 类进行正则表达式匹配。 



## 参考

[6.0 filter模块](http://www.tianshouzhi.com/api/tutorials/canal/402)
