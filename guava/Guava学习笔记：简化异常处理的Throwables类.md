​	有时候, 当我们我们捕获异常, 并且像把这个异常传递到下一个try/catch块中。Guava提供了一个异常处理工具类, 可以简单地捕获和重新抛出多个异常。例如：

```java
import java.io.IOException;
import org.junit.Test;
import com.google.common.base.Throwables;

public class ThrowablesTest {
    
    @Test
    public void testThrowables(){
        try {
            throw new Exception();
        } catch (Throwable t) {
            String ss = Throwables.getStackTraceAsString(t);
            System.out.println("ss:"+ss);
            Throwables.propagate(t);
        }
    }
    
    @Test
    public void call() throws IOException {
        try {
            throw new IOException();
        } catch (Throwable t) {
            Throwables.propagateIfInstanceOf(t, IOException.class);
            throw Throwables.propagate(t);
        }
    }    
}
```

 　将检查异常转换成未检查异常,例如：

```java
import java.io.InputStream;
import java.net.URL;
import org.junit.Test;
import com.google.common.base.Throwables;

public class ThrowablesTest {
    
    @Test
    public void testCheckException(){
        try {  
            URL url = new URL("http://ociweb.com");  
            final InputStream in = url.openStream();  
            // read from the input stream  
            in.close();  
        } catch (Throwable t) {  
            throw Throwables.propagate(t);  
        }  
    }
}
```

​		传递异常的常用方法：

　　1.RuntimeException propagate(Throwable)：把throwable包装成RuntimeException，用该方法保证异常传递，抛出一个RuntimeException异常
　　2.void propagateIfInstanceOf(Throwable, Class\<X extends Exception\>) throws X：当且仅当它是一个X的实例时，传递throwable
　　3.void propagateIfPossible(Throwable)：当且仅当它是一个RuntimeException和Error时，传递throwable
　　4.void propagateIfPossible(Throwable, Class\<X extends Throwable\>) throws X：当且仅当它是一个RuntimeException和Error时，或者是一个X的实例时，传递throwable。

　　使用实例：

```java
import java.io.IOException;
import org.junit.Test;
import com.google.common.base.Throwables;

public class ThrowablesTest {    
    @Test
    public void testThrowables(){
        try {
            throw new Exception();
        } catch (Throwable t) {
            String ss = Throwables.getStackTraceAsString(t);
            System.out.println("ss:"+ss);
            Throwables.propagate(t);
        }
    }
    
    @Test
    public void call() throws IOException {
        try {
            throw new IOException();
        } catch (Throwable t) {
            Throwables.propagateIfInstanceOf(t, IOException.class);
            throw Throwables.propagate(t);
        }
    }
    
 	  @Test
    public void testPropagateIfPossible() throws Exception {
          try {
              throw new Exception();
          } catch (Throwable t) {
            Throwables.propagateIfPossible(t, Exception.class);
            Throwables.propagate(t);
          }
    }
}
```

　Guava的异常链处理方法：

　　1.Throwable getRootCause(Throwable)
　　2.List\<Throwable\> getCausalChain(Throwable)
　　3.String getStackTraceAsString(Throwable)



## 参考

[Guava学习笔记：简化异常处理的Throwables类](https://www.cnblogs.com/peida/p/Guava_Throwables.html)
