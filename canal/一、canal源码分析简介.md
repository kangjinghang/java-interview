canal是阿里巴巴开源的mysql数据库binlog的增量订阅&消费组件。项目github地址为：https://github.com/alibaba/canal。

本教程是从源码的角度来分析canal，适用于对canal有一定基础的同学。本教程使用的版本是1.0.24，这也是笔者写这篇教程时的最新稳定版，关于canal的基础知识可以参考：https://github.com/alibaba/canal/wiki。

## 1. 下载项目源码

下载

```bash
git clone https://github.com/alibaba/canal.git
```

切换到canal-1.0.24这个tag

```bash
git checkout canal-1.0.24
```

## 2. 源码模块划分

![Image.png](http://blog-1259650185.cosbj.myqcloud.com/img/202205/02/1651468376.png)



模块虽多，但是每个模块的代码都很少。各个模块的作用如下所示：

- **common模块：**主要是提供了一些公共的工具类和接口。

- **client模块：**canal的客户端。核心接口为 CanalConnector

- **example模块：**提供client模块使用案例。

- **protocol模块：**client和server模块之间的通信协议

- **deployer：**部署模块。通过该模块提供的 CanalLauncher 来启动 canal server

- **server模块：**canal服务器端。核心接口为 CanalServer

- **instance模块：**一个 server 有多个 instance。每个 instance 都会模拟成一个 mysql 实例的 slave。instance 模块有四个核心组成部分：parser模块、sink 模块、store 模块，meta 模块。核心接口为 CanalInstance

- **parser模块：**数据源接入，模拟 slave 协议和 master 进行交互，协议解析。parser 模块依赖于 dbsync、driver 模块。

- **driver模块和dbsync模块：**从这两个模块的artifactId(canal.parse.driver、canal.parse.dbsync)，就可以看出来，这两个模块实际上是parser模块的组件。事实上 parser  是通过 driver 模块与 mysql 建立连接，从而获取到 binlog。由于原始的 binlog 都是二进制流，需要解析成对应的 binlog 事件，这些 binlog 事件对象都定义在 dbsync 模块中，dbsync 模块来自于淘宝的 tddl。

- **sink模块：**parser 和 store 链接器，进行数据过滤，加工，分发的工作。核心接口为 CanalEventSink

- **store模块：**数据存储。核心接口为 CanalEventStore

- **meta模块：**增量订阅&消费信息管理器，核心接口为 CanalMetaManager，主要用于记录 canal 消费到的 mysql binlog 的位置

下面再通过一张图来说明各个模块之间的依赖关系：

![Image.png](http://blog-1259650185.cosbj.myqcloud.com/img/202205/02/1651468725.png)通过deployer模块，启动一个canal-server，一个cannal-server内部包含多个instance，每个instance都会伪装成一个mysql实例的slave。client与server之间的通信协议由protocol模块定义。client在订阅binlog信息时，需要传递一个destination参数，server会根据这个destination确定由哪一个instance为其提供服务。

在分析源码的时候，本人也是按照模块来划分的，基本上一个模块对应一篇文章。



## 参考

[1.0 canal源码分析简介](http://www.tianshouzhi.com/api/tutorials/canal/380)
