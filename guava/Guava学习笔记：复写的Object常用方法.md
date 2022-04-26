　　在Java中Object类是所有类的父类，其中有几个需要override的方法比如equals，hashCode和toString等方法。每次写这几个方法都要做很多重复性的判断, 很多类库提供了覆写这几个方法的工具类, Guava也提供了类似的方式。下面我们来看看Guava中这几个方法简单使用。

　　**equals方法：**

　　equals是一个经常需要覆写的方法， 可以查看Object的equals方法注释， 对equals有几个性质的要求：
　　　　**1. 自反性reflexive：**任何非空引用x，x.equals(x)返回为true；
　　　　**2. 对称性symmetric：**任何非空引用x和y，x.equals(y)返回true当且仅当y.equals(x)返回true；
　　　　**3. 传递性transitive：**任何非空引用x和y，如果x.equals(y)返回true，并且y.equals(z)返回true，那么x.equals(z)返回true；
　　　　**4. 一致性consistent：**两个非空引用x和y，x.equals(y)的多次调用应该保持一致的结果，（前提条件是在多次比较之间没有修改x和y用于比较的相关信息）；
　　　　**5. 对于所有非null的值x， x.equals(null)都要返回false**。 (如果你要用null.equals(x)也可以，会报NullPointerException)。

　　当我们要覆写的类中某些值可能为null的时候，就需要对null做很多判断和分支处理。 使用Guava的Objects.equal方法可以避免这个问题， 使得equals的方法的覆写变得更加容易， 而且可读性强，简洁优雅。

```java
import org.junit.Test;
import com.google.common.base.Objects;

public class ObjectTest {
    
    @Test
    public void equalTest() {
        System.out.println(Objects.equal("a", "a"));
        System.out.println(Objects.equal(null, "a")); 
        System.out.println(Objects.equal("a", null)); 
        System.out.println(Objects.equal(null, null));
    }
    
    @Test
    public void equalPersonTest() {
        System.out.println(Objects.equal(new Person("peida",23), new Person("peida",23)));
        Person person=new Person("peida",23);
        System.out.println(Objects.equal(person,person));
    }
}

class Person {
    public String name;
    public int age;

    Person(String name, int age) {
        this.name = name;
        this.age = age;
    }
}
```

​	运行输出：

```java
true
false
false
true
false
true
```

　　**hashCode方法：
**

　　当覆写（override）了equals()方法之后，必须也覆写hashCode()方法。这个方法返回一个整型值（hash code value），如果两个对象被equals()方法判断为相等，那么它们就应该拥有同样的hash code。Object类的hashCode()方法为不同的对象返回不同的值，Object类的hashCode值表示的是对象的地址。
　　hashCode的一般性契约（需要满足的条件）如下：
　　1.在Java应用的一次执行过程中，如果对象用于equals比较的信息没有被修改，那么同一个对象多次调用hashCode()方法应该返回同一个整型值。应用的多次执行中，这个值不需要保持一致，即每次执行都是保持着各自不同的值。
　　2.如果equals()判断两个对象相等，那么它们的hashCode()方法应该返回同样的值。
　　3.并没有强制要求如果equals()判断两个对象不相等，那么它们的hashCode()方法就应该返回不同的值。即，两个对象用equals()方法比较返回false，它们的hashCode可以相同也可以不同。但是，应该意识到，为两个不相等的对象产生两个不同的hashCode可以改善哈希表的性能。
　　写一个hashCode本来也不是很难，但是Guava提供给我们了一个更加简单的方法--Objects.hashCode(Object ...)， 这是个可变参数的方法，参数列表可以是任意数量，所以可以像这样使用Objects.hashCode(field1， field2， ...， fieldn)。非常方便和简洁。

```java
import org.junit.Test;
import com.google.common.base.Objects;

public class ObjectTest {    
    @Test
    public void hashcodeTest() {
        System.out.println(Objects.hashCode("a"));
        System.out.println(Objects.hashCode("a"));
        System.out.println(Objects.hashCode("a","b"));
        System.out.println(Objects.hashCode("b","a"));
        System.out.println(Objects.hashCode("a","b","c"));
        
        Person person=new Person("peida",23);
        System.out.println(Objects.hashCode(person));
        System.out.println(Objects.hashCode(person));
    }
}

class Person {
    public String name;
    public int age;

    Person(String name, int age) {
        this.name = name;
        this.age = age;
    }
}
```

​	运行输出：

```java
128
4066
4096
126145
19313256
19313256
```

​		toString()方法：

　　因为每个类都直接或间接地继承自Object，因此每个类都有toString()方法。这个方法是用得最多的, 覆写得最多, 一个好的toString方法对于调试来说是非常重要的, 但是写起来确实很不爽。Guava也提供了toString（）方法。

```java
import org.junit.Test;
import com.google.common.base.Objects;

public class ObjectTest {
    
    @Test
    public void toStringTest() {
        System.out.println(Objects.toStringHelper(this).add("x", 1).toString());
        System.out.println(Objects.toStringHelper(Person.class).add("x", 1).toString());
        
        Person person=new Person("peida",23);
        String result = Objects.toStringHelper(Person.class)
        .add("name", person.name)
        .add("age", person.age).toString();      
        System.out.print(result);
    }
}

class Person {
    public String name;
    public int age;

    Person(String name, int age) {
        this.name = name;
        this.age = age;
    }
}

//============输出===============
ObjectTest{x=1}
Person{x=1}
Person{name=peida, age=23}
```

​		compare/compareTo方法：

　　**CompareTo：**compareTo(Object o)方法是java.lang.Comparable\<T\>接口中的方法，当需要对某个类的对象进行排序时，该类需要实现 Comparable\<T\>接口的，必须重写public int compareTo(T o)方法。java规定，若a，b是两个对象，当a.compareTo(b)>0时，则a大于b，a.compareTo(b)<0时，a<b，即规定对象的比较大小的规则；
　　**compare：** compare(Object o1,Object o2)方法是java.util.Comparator\<T\>接口的方法，compare方法内主要靠定义的compareTo规定的对象大小关系规则来确定对象的大小。

　　compareTo方法的通用约定与equals类似：将本对象与指定的对象停止比拟，如果本对象小于、等于、或大于指定对象，则分离返回正数、零、或正数。如果指定的对象类型无法与本对象停止比拟，则跑出ClassCastException。
　　**对称性：**实现者必须保证对全部的x和y都有sgn(x.compareTo(y)) == -sgn(y.compareTo(x))。这也暗示当且仅当y.compareTo(x)抛出异常时，x.compareTo(y)才抛出异常。
　　**传递性：**实现者必须保证比拟关系是可传递的，如果x.compareTo(y) > 0且y.compareTo(z) > 0，则x.compareTo(z) > 0。实现者必须保证x.compareTo(y)==0暗示着全部的z都有(x.compareTo(z)) == (y.compareTo(z))。
　　**虽不强制要求，但强烈建议(x.compareTo(y) == 0) == (x.equals(y))。**一般来说，任何实现了Comparable的类如果违背了这个约定，都应该明白说明。推荐这么说：“注意：本类拥有自然顺序，但与equals不一致”。
　　第一条指出，如果颠倒两个比拟对象的比拟顺序，就会发生以下情况：如果第一个对象小于第二个对象，则第二个对象必须大于第一个对象；如果第一个对象等于第二个对象，则第二个对象也必须等于第一个对象；如果第一个对象大于第二个对象，则第二个对象小于第一个对象。
　　第二条指出，如果第一个对象大于第二个对象，第二个对象大于第三个对象，则第一个大于第三个。
　　第三条指出，对于两个相称的对象，他们与其他任何对象比拟结果应该雷同。
　　这三条约定的一个结果是，compareTo方法的等同性测试必须与equals方法满意雷同的约束条件：自反性、对称性、传递性。所以也存在类同的约束：不能在扩展一个可实例化的类并添加新的值组件时，同时保证compareTo的约定，除非你愿意放弃面向对象抽象的优势。可以用与equals雷同的规避措施：如果想在实现Comparable接口的类中增加一个值组件，就不要扩展它；应该写一个不相干的类，其中包括第一个类的实例。然后供给一个view方法返回该实例。这样你就可以再第二个类上实现任何compareTo方法，同时允许客户在须要的时候将第二个类看成是第一个类的一个实例。
　　compareTo约定的最后一段是一个强烈的建议而非真正的约定，即compareTo方法的等同性测试必须与equals方法的结果雷同。如果遵照了这一条，则称compareTo方法所施加的顺序与equals一致；反之则称为与equals不一致。当然与equals不一致的compareTo方法仍然是可以工作的，但是，如果一个有序集合包括了该类的元素，则这个集合可能就不能遵照响应集合接口（Collection、Set、Map）的通用约定。这是因为这些接口的通用约定是基于equals方法的，但是有序集合却使用了compareTo而非equals来执行。

　　下面我们简单自己实现一个类的compareTo方法：

```java
import org.junit.Test;

public class ObjectTest {
    
    
    @Test
    public void compareTest(){
        Person person=new Person("peida",23);
        Person person1=new Person("aida",25);
        Person person2=new Person("aida",25);
        Person person3=new Person("aida",26);
        Person person4=new Person("peida",26);
        
        System.out.println(person.compareTo(person1));
        System.out.println(person1.compareTo(person2));
        System.out.println(person1.compareTo(person3));
        System.out.println(person.compareTo(person4));
        System.out.println(person4.compareTo(person));    
    }
}

class Person implements Comparable<Person>{
    public String name;
    public int age;

    Person(String name, int age) {
        this.name = name;
        this.age = age;
    }
    
    @Override
    public int compareTo(Person other) {
        int cmpName = name.compareTo(other.name);
        if (cmpName != 0) {
            return cmpName;
        }
        if(age>other.age){
            return 1;
        }
        else if(age<other.age){
            return -1;
        }
        return 0;  
    }
}
```

```java
//========输出===========
15
0
-1
-1
1
```

　　上面的compareTo方法，代码看上去并不是十分优雅，如果实体属性很多，数据类型丰富，代码可读性将会很差。在guava里, 对所有原始类型都提供了比较的工具函数来避免这个麻烦. 比如对Integer, 可以用Ints.compare()。利用guava的原始类型的compare，我们对上面的方法做一个简化，实现compare方法：

```java
class PersonComparator implements Comparator<Person> {  
    @Override 
    public int compare(Person p1, Person p2) {  
      int result = p1.name.compareTo(p2.name);  
      if (result != 0) {  
        return result;  
      }  
      return Ints.compare(p1.age, p2.age);  
    }  
  }
```

　　上面的代码看上去简单了一点，但还是不那么优雅简单，对此, guava有一个相当聪明的解决办法, 提供了ComparisonChain:

```java
class Student implements Comparable<Student>{
    public String name;
    public int age;
    public int score;    
    
    Student(String name, int age,int score) {
        this.name = name;
        this.age = age;
        this.score=score;
    }
    
    @Override
    public int compareTo(Student other) {
        return ComparisonChain.start()
        .compare(name, other.name)
        .compare(age, other.age)
        .compare(score, other.score, Ordering.natural().nullsLast())
        .result();
    }
}

class StudentComparator implements Comparator<Student> {  
    @Override public int compare(Student s1, Student s2) {  
      return ComparisonChain.start()  
          .compare(s1.name, s2.name)  
          .compare(s1.age, s2.age)  
          .compare(s1.score, s2.score)  
          .result();  
    }  
  }  
}
```

　　ComparisonChain是一个lazy的比较过程， 当比较结果为0的时候， 即相等的时候， 会继续比较下去， 出现非0的情况， 就会忽略后面的比较。ComparisonChain实现的compare和compareTo在代码可读性和性能上都有很大的提高。

　　下面来一个综合应用实例：

```java
import java.util.Comparator;

import org.junit.Test;

import com.google.common.base.Objects;
import com.google.common.collect.ComparisonChain;
import com.google.common.collect.Ordering;

public class ObjectTest {

    
    @Test
    public void StudentTest(){
        
        Student student=new Student("peida",23,80);
        Student student1=new Student("aida",23,36);
        Student student2=new Student("jerry",24,90);
        Student student3=new Student("peida",23,80);
        
        System.out.println("==========equals===========");
        System.out.println(student.equals(student2));
        System.out.println(student.equals(student1));
        System.out.println(student.equals(student3));
        
        System.out.println("==========hashCode===========");
        System.out.println(student.hashCode());
        System.out.println(student1.hashCode());
        System.out.println(student3.hashCode());
        System.out.println(student2.hashCode());
        
        System.out.println("==========toString===========");
        System.out.println(student.toString());
        System.out.println(student1.toString());
        System.out.println(student2.toString());
        System.out.println(student3.toString());
        
        System.out.println("==========compareTo===========");
        System.out.println(student.compareTo(student1));
        System.out.println(student.compareTo(student2));
        System.out.println(student2.compareTo(student1));
        System.out.println(student2.compareTo(student));
        
    }

}

class Student implements Comparable<Student>{
    public String name;
    public int age;
    public int score;
    
    
    Student(String name, int age,int score) {
        this.name = name;
        this.age = age;
        this.score=score;
    }
    
    @Override
    public int hashCode() {
        return Objects.hashCode(name, age);
    }
    
    
    @Override
    public boolean equals(Object obj) {
        if (obj instanceof Student) {
            Student that = (Student) obj;
            return Objects.equal(name, that.name)
                    && Objects.equal(age, that.age)
                    && Objects.equal(score, that.score);
        }
        return false;
    }
    
    @Override
    public String toString() {
        return Objects.toStringHelper(this)
                .addValue(name)
                .addValue(age)
                .addValue(score)
                .toString();
    }
    
    
    @Override
    public int compareTo(Student other) {
        return ComparisonChain.start()
        .compare(name, other.name)
        .compare(age, other.age)
        .compare(score, other.score, Ordering.natural().nullsLast())
        .result();
    }
}



class StudentComparator implements Comparator<Student> {  
    @Override public int compare(Student s1, Student s2) {  
      return ComparisonChain.start()  
          .compare(s1.name, s2.name)  
          .compare(s1.age, s2.age)  
          .compare(s1.score, s2.score)  
          .result();  
    }  
  }  

//=============运行输出===========================
==========equals===========
false
false
true
==========hashCode===========
-991998617
92809683
-991998617
-1163491205
==========toString===========
Student{peida, 23, 80}
Student{aida, 23, 36}
Student{jerry, 24, 90}
Student{peida, 23, 80}
==========compareTo===========
1
1
1
-1
```



## 参考

[Guava学习笔记：复写的Object常用方法](https://www.cnblogs.com/peida/p/Guava_Objects.html)
