依稀记得我第一次设计一个系统的时候，画了一堆UML（Unified Modeling Language，统一建模语言）图，面对Class Diagram（其实就是领域模型），纠结了好久，不知道如何落地。因为，如果按照这个类图去落数据库的话，看起来很奇怪，有点繁琐。可是不按照这个类图落库的话，又不知道这个类图画了有什么用。

现在回想起来，我当时的纠结源自于我对领域模型和数据模型这两个重要概念的不清楚。最近，我发现对这两个概念的混淆不是个例，而是非常普遍的现象。其结果就是，小到会影响一些模块设计的不合理性，大到会影响像业务中台这样重大技术决策，因为如果底层的逻辑、概念、理论基础没搞清楚的话，其构建在其上的系统也会出现问题，非常严重的问题。

鉴于很少看到有人对这个话题进行比较深入的研究和探讨，我觉得有必要花时间认真明晰这两个概念，帮助大家在工作中，更好的做设计决策。

## 1. 领域模型和数据模型的概念定义

领域模型关注的是领域知识，是业务领域的核心实体，体现了问题域里面的关键概念，以及概念之间的联系。领域模型建模的关键是看模型能否显性化、清晰的表达业务语义，扩展性是其次。

数据模型关注的是数据存储，所有的业务都离不开数据，都离不开对数据的CRUD，数据模型建模的决策因素主要是扩展性、性能等非功能属性，无需过分考虑业务语义的表征能力。

按照Robert在《整洁架构》里面的观点，领域模型是核心，数据模型是技术细节。然而现实情况是，二者都很重要。

这两个模型之所以容易被混淆，是因为两者都强调实体（Entity），都强调关系（Relationship），这可不，我们传统的数据库的数据模型建模就是用的ER图啊。

是的，二者的确有一些共同点，有时候领域模型和数据模型会长的很像，甚至会趋同，这很正常。但更多的时候，二者是有区别的。正确的做法应该是有意识地把这两个模型区别开来，分别设计，因为他们建模的目标会有所不同。如下图所示，数据模型负责的是数据存储，其要义是扩展性、灵活性、性能。而领域模型负责业务逻辑的实现，其要义是业务语义显性化的表达，以及充分利用OO的特性增加代码的业务表征能力。

<img src="http://blog-1259650185.cosbj.myqcloud.com/img/202203/15/1647330223.jpeg" alt="9"  />

然而，现实情况是，我们很多的业务系统设计，并没有很好的区分二者的关系。经常会犯两个错误，一个是把领域模型当数据模型，另一个是把数据模型当领域模型。

## 2. 错把领域模型当数据模型

这几天我在做一个报价优化的项目，里面涉及到报价规则的问题，这块的业务逻辑大意是说，对于不同的商品（通过类目、品牌、供应商类型等维度区分），我们会给出不同的价格区间，然后来判断商家的报价是否应该被自动审核（autoApprove）通过，还是应该被自动拦截（autoBlock）。

对于这个规则，领域模型很简单，就是提供了价格管控需要的配置数据，如下图所示：

![2](http://blog-1259650185.cosbj.myqcloud.com/img/202203/15/1647330475.png)

如果按照这个领域模型去设计我们的存储的话，自然是需要两张表：price_rule和price_range，一张用来存价格规则，一张是用来存价格区间。

![3](http://blog-1259650185.cosbj.myqcloud.com/img/202203/15/1647331551.png)

如果这样去设计数据模型，我们就犯了把领域模型当数据模型的错误。这里，更合适的做法是一张表就够了，把price_range作为一个字段在price_rule中用一个字段存储，如下图所示，里面的多个价格区间信息用一个JSON字段去存取就好了。

![4](http://blog-1259650185.cosbj.myqcloud.com/img/202203/15/1647335560.png)

这样做的好处很明显：

- 首先，维护一张数据库表肯定比两张的成本要小。

- 其次，其数据的扩展性更好。比如，新需求来了，需要增加一个建议价格（suggest price）区间，如果是两张表的话，我需要在price_range中加两个新字段，而如果是JSON存储的话，数据模型可以保持不变。

可是，在业务代码里面，如果是基于JSON在做事情可不那么美好。我们需要把JSON的数据对象，转换成有业务语义的领域对象，这样，我们既可以享受数据模型扩展性带来的便捷性，又不失领域模型对业务语义显性化带来的代码可读性。

<img src="http://blog-1259650185.cosbj.myqcloud.com/img/202203/15/1647335637.png" alt="5" style="zoom:67%;" />

## 3. 错把数据模型当领域模型

的确，数据模型最好尽量可扩展，毕竟，改动数据库可是个大工程，不管是加字段、减字段，还是加表、删表，都涉及到不少的工作量。

说到数据模型的扩展设计经典之作，非阿里的业务中台莫属，核心的商品、订单、支付、物流4张表，得益于良好的扩展性设计，就支撑了阿里几十个业务的成千上万的业务场景。

拿商品中台来说，它用一张auction_extend垂直表，就解决了所有业务商品数据存储扩展性的需求。理论上来说，这种数据模型可以满足无限的业务扩展。

JSON字段也好，垂直表也好，虽然可以很好的解决数据存储扩展的问题，但是，我们最好不要把这些扩展（features）当成领域对象来处理，否则，你的代码根本就不是在面向对象编程，而是在面向扩展字段（features）编程，从而犯了把数据模型当领域模型的错误。更好的做法，应该是把数据对象（Data Object）转换成领域对象来处理。

如下所示，这种代码里面到处是getFeature、addFeature的写法，是一种典型的把数据模型当领域模型的错误示范。

![6](http://blog-1259650185.cosbj.myqcloud.com/img/202203/15/1647335869.png)

## 4. 领域模型和数据模型各司其职

上面展示了因为混淆领域模型和数据模型，带来的问题。正确的做法应该是把领域模型、数据模型区别开来，让他们各司其职，从而更合理的架构我们的应用系统。

其中，领域模型是面向领域对象的，要尽量具体，尽量语义明确，显性化的表达业务语义是其首要任务，扩展性是其次。而数据模型是面向数据存储的，要尽量可扩展。

在具体落地的时候，我们可以采用COLA[1]的架构思想，使用gateway作为数据对象（Data Object）和领域对象（Entity）之间的转义网关，其中，gateway除了转义的作用，还起到了防腐解耦的作用，解除了业务代码对底层数据（DO、DTO等）的直接依赖，从而提升系统的可维护性。

<img src="http://blog-1259650185.cosbj.myqcloud.com/img/202203/15/1647335977.jpeg" alt="7" style="zoom:50%;" />

此外，教科书上教导我们在做关系数据库设计的时候，要满足3NF（三范式），然而，在实际工作中，我们经常会因为性能、扩展性的原因故意打破这个原则，比如我们会通过数据冗余提升访问性能，我们会通过元数据、垂直表、扩展字段提升表的扩展性。

业务场景不一样，对数据扩展的诉求也不一样，像price_rule这种简单的配置数据扩展，JSON就能胜任。复杂一点的，像auction_extend这种垂直表也是不错的选择。

wait，有同学说，你这样做，数据是可扩展了，可数据查询怎么解决呢？总不能用join表，或者用like吧。实际上，对一些配置类的数据，或者数据量不大的数据，完全可以like。然而，对于像阿里商品、交易这样的海量数据，当然不能like，不过这个问题，很容易通过读写分离，构建search的办法解决。

<img src="http://blog-1259650185.cosbj.myqcloud.com/img/202203/15/1647336158.jpeg" alt="8" style="zoom: 67%;" />

## 5. 关于扩展的更多思考

最后，再给一个思考题吧。

前面提到的数据扩展，还都是领域内的有限扩展。如果我连业务领域是什么还不知道，能不能做数据扩展呢？可以的，Salesforce的force.com就是这么做的，其底层数据存储完全是元数据驱动的（metadata-driven[2]），他用一张有500个匿名字段的表，去支撑所有的SaaS业务，每个字段的实际表意是通过元数据去描述的。如下图所示，value0到value500都是预留的业务字段，具体代表什么意思，由metadata去定义。

<img src="http://blog-1259650185.cosbj.myqcloud.com/img/202203/15/1647337260.png" alt="9" style="zoom:67%;" />

说实话，这种实现方式的确是一个很有想法，很大胆的设计，也的确支撑了上面数以千计的SaaS应用和Salesforce千亿美金的市值。

只是，我不清楚从元数据到领域对象的映射，Salesforce具体是怎么做的，是通过他们的语法糖Apex？如果没有领域对象，他们的业务代码要怎么写呢？反正据在Salesforce里面做vendor的同学说，他们所谓的Low-Code，里面还是有很多用Apex写的代码，而且可维护性一般。

anyway，我们绝大部分的应用都是面向确定问题域的，不需要像Salesforce那样提供“无边际”的扩展能力。在这种情况下，我认为，领域对象是最好的连接数据模型和业务逻辑的桥梁。

## 参考

[领域模型vs数据模型，应该怎么用？](https://mp.weixin.qq.com/s?__biz=MzIzOTU0NTQ0MA==&mid=2247501842&idx=1&sn=e6fec2dbd74011c2f420c6c0da998978&chksm=e92af51dde5d7c0b1bc5dc98199b5181dd103df32f6de80c9a9fa2efafa8263b80b36b2d5232&scene=178&cur_album_id=1530994292440301570#rd)

[Alibaba-COLA](https://github.com/alibaba/COLA)

[metadata-driven](https://developer.salesforce.com/wiki/multi_tenant_architecture)
