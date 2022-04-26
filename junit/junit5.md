## 1. JUnit5 Jupiter Overview

### Quality Engineering Process

Quality engineering (also known as quality management) is a process that evaluates, assesses, and improves the quality of software. There are three major groups of activities in the quality engineering process.

<img src="http://blog-1259650185.cosbj.myqcloud.com/img/202111/07/1636253785.png" alt="image-20211107105619324" style="zoom:50%;" />



This stage establishes the overall quality goal by managing customer's expectations under the project cost and budgetary
constraints. This quality plan also includes the strategy, that is, the selection of activities to perform and the appropriate quality
measurements to provide feedback and assessment.

This guarantees that software products and processes in the project life cycle meet their specified requirements by planning and performing a set of activities to provide adequate confidence that quality is being built into the software. The main QA activity is Verification & Validation, but there are others, such as software quality metrics, the use of quality standards, configuration management, documentation management, or an expert's opinion.

These stage includes activities for quality quantification and improvement measurement, analysis, feedback, and follow-up activities. The aim of these activities is to provide quantitative assessment of product quality and identification of improvement opportunities.

### Why Unit Testing

The sooner we detect a bug in the code, the faster and cheaper it is to fix. This is validated by the data shared by Google.

<img src="http://blog-1259650185.cosbj.myqcloud.com/img/202111/07/1636254188.png" alt="image-20211107110307968" style="zoom:50%;" />

### Unit Testing

Unit testing is a method by which individual pieces of source code are tested to verify that the design and implementation for that unit have been correctly implemented. There are four phases executed in sequence in a unit test case are the following:

- Setup: The test case initializes the test fixture, that is the before picture required for the SUT to exhibit the expected behavior
- Exercise: The test case interacts with the SUT, getting some outcome from it as a result. The SUT usually queries another component, named the Depended-On Component (DOC).
- Verify: The test case determines whether the expected outcome has been obtained using assertions (also known as predicates).
- Teardown: The test case tears down the test fixture to put the fUT back into the initial state.

<img src="http://blog-1259650185.cosbj.myqcloud.com/img/202111/07/1636254455.png" alt="image-20211107110735776" style="zoom:50%;" />

### Why JUnit Framework

JUnit is the most used library for Java projects.

<img src="http://blog-1259650185.cosbj.myqcloud.com/img/202111/07/1636254764.png" alt="Github Top 20 Java Libraries" style="zoom: 67%;" />

https://www.overops.com/blog/we-analyzed-60678-libraries-on-github-here-are-the-top-100/

## 2. JUnit 3 Framework Retrospect

JUnit is a testing framework which allows to create automated tests. The development of JUnit was started by Kent Beck and Erich Gamma in late 1995.

JUnit3 is open source software, released under Common Public License (CPL) Version 1.0 and hosted on SourceForge(https://sourceforge.net/projects/junit/). The latest version of JUnit 3 was JUnit 3.8.2, released on May 14, 2007

## 3. JUnit 4 Framework Retrospect

JUnit 4 is still an open source framework, though the license changed with respect to JUnit 3, from CPL to Eclipse Public License (EPL) Version 1.0. The source code of JUnit 4 is hosted on GitHub (https://github.com/junit-team/junit4/).

On February 18, 2006, JUnit 4.0 was released. It follows the same high-level guidelines than JUnit 3, that is, easily define test, the framework run tests independently, and the framework detects and report errors by the test.

One of the main differences of JUnit 4 with respect to JUnit 3 is the way that JUnit 4 allows to define tests. In JUnit 4 Java annotations are used to mark methods as tests. For this reason, JUnit 4 can only be used for Java 5 or later.

<img src="http://blog-1259650185.cosbj.myqcloud.com/img/202111/07/1636256014.png" alt="image-20211107113334424" style="zoom:50%;" />

In JUnit 4, a test runner is a Java class used to manage a test s life cycle: Instantiation calling setup and teardown methods,
running the test, handling exceptions, sending notifications, and so on. The default JUnit 4 test runner is called **BlockJUnit4ClassRunner**, and it implements the JUnit 4 standard test case class model.

One of the most significant innovations introduced in JUnit 4 was the use of rules. Rules allow flexible addition or redefinition of the behavior of each test method in a test class. A rule should be included in a test case by annotating a class attribute with the annotation **@Rule**.

```java
public class Junit4StandardTest {

    private static List<String> classLevelList;

    private List<String> testCaseLevelList;

    @BeforeClass
    public static void init() {
        classLevelList = new ArrayList<>();
    }

    @Before
    public void setUp() {
        this.testCaseLevelList = new ArrayList<>();
    }

    @Test
    public void addJavaInTwoList() {
        Assert.assertTrue(classLevelList.add("Java"));
        Assert.assertTrue(testCaseLevelList.add("Java"));
    }

    @Test
    public void addJUnitInTwoList() {
        Assert.assertTrue(classLevelList.add("JUnit"));
        Assert.assertTrue(testCaseLevelList.add("JUnit"));
    }

    @After
    public void tearDown() {
        Assert.assertEquals(1, testCaseLevelList.size());
        testCaseLevelList.clear();
    }

    @AfterClass
    public static void destroy() {
        Assert.assertEquals(2, classLevelList.size());
        classLevelList.clear();
    }

}
```

JUnit4 常见Runner：

```java
@RunWith(Suite.class)
@Suite.SuiteClasses({
        Junit4StandardTest.class
})
public class JUnit4SuiteTest {


}
```

```java
@RunWith(Parameterized.class)
public class JUnit4ParameterTest {

    @Parameterized.Parameter(0)
    public String literal;

    @Parameterized.Parameter(1)
    public int length;

    @Parameterized.Parameters(name = "{index} <==> literal={0} length = {1}")
    public static Collection<Object[]> data() {
        return Arrays.asList(new Object[]{"JUnit", 5}, new Object[]{"Java", 4}, new Object[]{"Programming", 11});
    }

    @Test
    public void theLiteralLengthShouldCorrect() {
        Assert.assertEquals(length, literal.length());
    }

}
```

```java
@RunWith(Theories.class)
public class JUnit4TheoriesTest {

    @DataPoints
    public static int[] data() {
        return new int[]{1, 10, 100};
    }

    @Theory
    public void sumTwoNumericAddShouldGreatThanTheOne(int a, int b) {
        Assert.assertTrue(a + b > a);
        System.out.printf("%d+%d>%d\n", a, b, a);
    }

}
```

```java
@RunWith(MockitoJUnitRunner.class)
public class MockitoRunnerTest {

    @Mock
    public List<String> list;

    @Test
    public void shouldAddElement2ListCorrect() {
        when(list.add("Java")).thenReturn(true);
        when(list.size()).thenReturn(10);
        assertEquals(10, list.size());
        assertTrue(list.add("Java"));
    }

}
```

JUnit Runner的不足：只能有一个Runner，不方便扩展，这时出现了@Rule。

```java
@RunWith(Theories.class)
public class JUnitRuleTest {

    @Rule
    public MockitoRule mockitoRule = MockitoJUnit.rule();

    @Mock
    public List<String> list;

    @Test
    public void shouldAddElement2ListCorrect() {
        when(list.add("Java")).thenReturn(true);
        when(list.size()).thenReturn(10);
        assertEquals(10, list.size());
        assertTrue(list.add("Java"));
    }

    @DataPoints
    public static int[] data() {
        return new int[]{1, 10, 100};
    }

    @Theory
    public void sumTwoNumericAddShouldGreatThanTheOne(int a, int b) {
        Assert.assertTrue(a + b > a);
        System.out.printf("%d+%d>%d\n", a, b, a);
    }

}
```

## 4. JUnit 4 Framwork Limitaions

- monolithic
- only use a single runner at a time.
- The main inconvenience when using JUnit 4 rules for complex tests is that we are not able to use a single rule entity for method-level and class-level.

<img src="http://blog-1259650185.cosbj.myqcloud.com/img/202111/07/1636297161.png" alt="image-20211107225921084" style="zoom:50%;" />

## 5. JUnit 5 Framework Design Principles

- **Modularization**: As introduced before, JUnit 4 was not modular, and this causes some problems. From its inception, JUnit 5 architecture is much completely modular, allowing developers to use the specific parts of the framework they require.
- Powerful **extension** model with focus on composability: Extensibility is a must for modern testing frameworks. Therefore, JUnit 5 should provide seamless integration with third-party frameworks, such as Spring or Mockito, to name a few. 
- **API segregation**: Decouple test discovery and execution from test definition.
- **Compatibility** with older releases: Supporting the execution of legacy Java 3 and Java 4 in the new JUnit 5 platform.
- **Modern programming model** for writing tests (Java 8): Nowadays, more and more developers write code with Java 8 new features, such as lambda expressions. JUnit 4 was built on Java 5, but JUnit 5 has been created from scratch using Java 8.

## 6. JUnit 5 Framework Architecture

JUnit 5 framework is composed of three major components, called Platform, Jupiter, and Vintage.

- Jupiter: The first high-level component is called Jupiter. It provides the brand-new programming and extension model of the JUnit 5 framework.
- JUnit Platform:  This component is aimed to become the foundation for any testing framework executed in the JVM. In other words, it provides mechanisms to run Jupiter tests, legacy JUnit 4, and also third-party tests (for example. Spock, FitNesse, and so on).
- Vintage: This component allows running legacy JUnit tests on the JUnit Platform out of the box.

<img src="http://blog-1259650185.cosbj.myqcloud.com/img/202111/07/1636297606.png" alt="image-20211107230646903" style="zoom:50%;" />

客户端：

- These are the modules facing users (that is, software engineer and testers). These modules provide the programming model for a particular Test Engine (for example, junit-jupiter-api for JUnit 5 tests and junit for JUnit 4 tests).
- Test Engines: These modules allow to execute a kind of test (Jupiter tests, legacy JUnit 4, or other Java tests) within the JUnit Platform. They are created by extending the general Platform Engine (junit-platform-engine).
- Test Launcher: These modules provide the ability of test discovery inside the JUnit platform for external build tools and IDEs. This API is consumed by tools such as Maven, Gradle, IntelliJ, and so on, using the junit-platform-launcher module.

<img src="http://blog-1259650185.cosbj.myqcloud.com/img/202111/07/1636298025.png" alt="image-20211107231345746" style="zoom:50%;" />

## 7. JUnit 5 Jupiter Fundamental

- Jupiter Assertion Statement
- Assert Exception
- Assert All
- DisplayName
- Disabled
- Assert Timeout
- Assumptions
- Repeat
- Order
- Nested Test Class
- Test case lifecycle
- Tagging & Filtering
- Custom Tagging
- Integration With Hamcrest
- Execution Condition
- TestinstancePostProcessor
- Callback API
- Handler API
- Conditional Execution

<img src="http://blog-1259650185.cosbj.myqcloud.com/img/202111/08/1636357267.png" alt="image-20211108154101140" style="zoom:50%;" />

<img src="http://blog-1259650185.cosbj.myqcloud.com/img/202111/08/1636360763.png" alt="image-20211108163922982" style="zoom:50%;" />

## 8. JUinit 5 Jupiter Advanced

In former JUnit versions, test constructors and methods were not allowed to have parameters. One of the major changes in JUnit 5 is that both test constructors and methods are now allowed to include parameters. This feature enables the dependency injection for constructors and methods

If a test constructor or a method annotated with @Test, @TestFactory, @BeforeEach, @AfterEach, @BeforeAll, or @AfterAll accepts a parameter, that parameter is resolved at runtime by a resolver (object with parent class ParameterResolver).

There are three built-in resolvers registered automatically in JUnit 5: TestinfoParameterResolver, and RepetitionInfoParameterResolver, TestReporterParameterResolver.

## 9. JUnit 5 Jupiter Advanced-Dynamic Tests

In JUnit 3, we identified tests by parsing method names and checking whether they started with the word test. Then, in JUnit 4, we identified tests by collecting methods annotated with @Test. Both of these techniques share the same approach: tests are defined at compile time. This concept is what we call static testing.

Static tests are considered a limited approach, especially for the common scenario in which the same test is supposed to be executed for a variety of input data.

JUnit 5 allows to generate test at runtime by a factory method that is annotated with @TestFactory. In contrast to @Test, a @TestFactory method is not a test but a factory. A @TestFactory method must return a Stream, Collection, Iterable, or Iterator of DynamicTest instances. These DynamicTest instances are executed lazily, enabling dynamic generation of test cases.

@TestFactory methods must not be private or static.

The DynamicTests are executed differently than the standard @Tests and do not support lifecycle callbacks. Meaning, the @BeforeEach and the @AfterEach methods will not be called for the DynamicTests.

## 10. JUnit 5 Jupiter Advanced-Test Template

A @TestTemplate method is not a regular test case but a template for test cases. Method annotated like this will be invoked multiple times, depending on the invocation context returned by the registered providers. Thus, test templates are used together with a registered TestTemplatelnvocationContextProviderextension!

RepeatedTest

Parametrized tests