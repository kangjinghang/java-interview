## 1. 概述

本文主要分享 **Elastic-Job-Lite 运维平台**。内容对应[《官方文档 —— 运维平台》](http://dangdangdotcom.github.io/elastic-job/elastic-job-lite/02-guide/web-console/)。

运维平台实现上比较易懂，就不特别**啰嗦**的解析，简略说下每个类的用途和 UI 上的关联。

## 2. Maven模块 elastic-job-common-restful

1. Restful Server 内嵌服务器，基于 Jetty 实现
2. GSON Provider 后端接口 JSON 格式化
3. RestfulExceptionMapper 异常映射
4. WwwAuthFilter 授权认证 Filter

## 3. Maven模块 elastic-job-console

### 3.1 domain 包

- RegistryCenterConfigurations / RegistryCenterConfiguration ：注册中心配置实体相关。
- EventTraceDataSourceConfigurations / EventTraceDataSourceConfiguration / EventTraceDataSource / EventTraceDataSourceFactory ：事件事件追踪数据源配置实体相关。

### 3.2 filter 包

- GlobalConfigurationFilter ：全局配置过滤器，加载当前会话( HttpSession ) 选择的 RegistryCenterConfiguration / EventTraceDataSource 。

### 3.3 repository 包

使用 **XML文件** 存储 EventTraceDataSource / RegistryCenterConfiguration 配置实体。

### 3.4 restful 包

- `config` / RegistryCenterRestfulApi ：注册中心配置( RegistryCenterConfiguration )的RESTful API![img](https://static.iocoder.cn/images/Elastic-Job/2017_12_07/01.png)
- `config` / EventTraceDataSourceRestfulApi ：事件追踪数据源配置( EventTraceDataSource )的RESTful API![img](https://static.iocoder.cn/images/Elastic-Job/2017_12_07/02.png)
- `config` / LiteJobConfigRestfulApi ：作业配置( LiteJobConfiguration )的RESTful API![img](https://static.iocoder.cn/images/Elastic-Job/2017_12_07/03.png)
- EventTraceHistoryRestfulApi ：事件追踪历史记录( `JOB_EXECUTION_LOG` / `JOB_STATUS_TRACE_LOG` )的RESTful API![img](https://static.iocoder.cn/images/Elastic-Job/2017_12_07/06.png)![img](https://static.iocoder.cn/images/Elastic-Job/2017_12_07/07.png)
- ServerOperationRestfulApi ：服务器维度操作的RESTful API。![img](https://static.iocoder.cn/images/Elastic-Job/2017_12_07/05.png)
- JobOperationRestfulApi ：作业维度操作的RESTful API。![img](https://static.iocoder.cn/images/Elastic-Job/2017_12_07/04.png)

### 3.5 service 包

- RegistryCenterConfigurationService ：注册中心( RegistryCenterConfiguration )配置服务。
- EventTraceDataSourceConfigurationService ：事件追踪数据源配置( EventTraceDataSource )服务。
- JobAPIService ：和作业相关的 API 集合服务。这些 API 在 Maven模块`elastic-job-lite-lifecycle`实现。
  - JobSettingsAPI：作业配置的API。
  - JobOperateAPI ：操作作业的API。
  - ShardingOperateAPI ：操作分片的API。
  - JobStatisticsAPI ：JobStatisticsAPI。
  - ServerStatisticsAPI ：作业服务器状态展示的API。
  - ShardingStatisticsAPI ：作业分片状态展示的API。

## 4. Maven模块 elastic-job-lite-lifecycle

在 JobAPIService 已经基本提到，这里不重复叙述。

## 5. 其它

1. 前后端分离，后端使用 JSON 为前端提供数据接口。
2. 后端 API 使用 Restful 设计规范。
3. 国际化使用 `jquery.i18n.js` 实现。
4. 界面使用 Bootstrap AdminLTE 模板实现。



## 参考

[Elastic-Job-Lite 源码分析 —— 运维平台](https://www.iocoder.cn/Elastic-Job/job-console/)
