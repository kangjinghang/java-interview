## 1. 概述

xxl-job的执行器注册过程如下，执行器自启动开始，每30s进行一次注册，注册同时兼具了心跳机制。而调度器则是在接收到注册请求之后，判断该执行器是否已经注册，如果已注册，则更新心跳时间。

<img src="http://blog-1259650185.cosbj.myqcloud.com/img/202204/19/1650337108.png" alt="图片" style="zoom:67%;" />

## 2. 源码分析

### 2.1 调度器与执行器的交互

首先看一下xxl-job-core子项目的两个接口，AdminBiz 与 ExecutorBiz：

先看AdminBiz，负责执行器向调度器的各类请求的聚合，比如执行器任务完成后的回调（callback），执行器注册请求（registry）等。

```java
public interface AdminBiz {


    // ---------------------- callback ----------------------

    /**
     * callback
     *
     * @param callbackParamList
     * @return
     */
    public ReturnT<String> callback(List<HandleCallbackParam> callbackParamList);


    // ---------------------- registry ----------------------

    /**
     * registry
     *
     * @param registryParam
     * @return
     */
    public ReturnT<String> registry(RegistryParam registryParam);

    /**
     * registry remove
     *
     * @param registryParam
     * @return
     */
    public ReturnT<String> registryRemove(RegistryParam registryParam);


    // ---------------------- biz (custome) ----------------------
    // group、job ... manage

}
```

继续看registry方法，会发现有两个实现类，一个是core子项目下的，一个是admin子项目下的。

<img src="http://blog-1259650185.cosbj.myqcloud.com/img/202204/19/1650337307.png" alt="图片" style="zoom: 67%;" />



由下图可知，这两个实现，一个是执行器端，一个是调度器端，执行器端只是进行http请求，调度端才是实际逻辑。

```java
// AdminBizClient.java
@Override
public ReturnT<String> registry(RegistryParam registryParam) {
    return XxlJobRemotingUtil.postBody(addressUrl + "api/registry", accessToken, timeout, registryParam, String.class);
}
```

同理，ExecutorBiz 则是调度器对执行器的请求，包含任务执行，取消等接口，调度器实现分别如下：

```java
@Override
public ReturnT<String> registry(RegistryParam registryParam) {
    return JobRegistryHelper.getInstance().registry(registryParam);
}
```

### 2.2 调度器端服务注册线程启动

> 简单了解了调度器与执行器交互的接口，我们便来解答另一个问题，执行器是如何注册到调度器上的。

回到调度器的 init，在国际化之后第二步即服务注册线程的启动。

```java
public void init() throws Exception {
		...
    // admin registry monitor run  启动管理注册执行器的线程
    JobRegistryHelper.getInstance().start();
		...
}
```

看下面这段代码之前，先回忆一下第一章提到的表结构，其中：

```basic
- xxl_job_group：执行器信息表，维护任务执行器信息；
- xxl_job_registry：执行器注册表，维护在线的执行器和调度中心机器地址信息；
```

JobRegistryHelper.getInstance().start()

```java
// JobRegistryHelper.java
public void start(){

	...
    
	// for monitor
	registryMonitorThread = new Thread(new Runnable() {
		@Override
		public void run() {
			while (!toStop) {
				try {
					// auto registry group 1.从xxl_job_group获取到所有执行器数据，addressType=0的即为自动注册的执行器
					List<XxlJobGroup> groupList = XxlJobAdminConfig.getAdminConfig().getXxlJobGroupDao().findByAddressType(0);
					if (groupList!=null && !groupList.isEmpty()) {

						// remove dead address (admin/executor) 2.清理xxl_job_registry中心跳机制大于3倍心跳时间的“死执行器”。
						List<Integer> ids = XxlJobAdminConfig.getAdminConfig().getXxlJobRegistryDao().findDead(RegistryConfig.DEAD_TIMEOUT, new Date());
						if (ids!=null && ids.size()>0) {
							XxlJobAdminConfig.getAdminConfig().getXxlJobRegistryDao().removeDead(ids);
						}

						// fresh online address (admin/executor) 3.从xxl_job_registry中获取“活执行器”，构造成 <app-name,List<address>> 的 map
						HashMap<String, List<String>> appAddressMap = new HashMap<String, List<String>>();
						List<XxlJobRegistry> list = XxlJobAdminConfig.getAdminConfig().getXxlJobRegistryDao().findAll(RegistryConfig.DEAD_TIMEOUT, new Date());
						if (list != null) {
							for (XxlJobRegistry item: list) {
								if (RegistryConfig.RegistType.EXECUTOR.name().equals(item.getRegistryGroup())) {
									String appname = item.getRegistryKey();
									List<String> registryList = appAddressMap.get(appname);
									if (registryList == null) {
										registryList = new ArrayList<String>();
									}

									if (!registryList.contains(item.getRegistryValue())) {
										registryList.add(item.getRegistryValue());
									}
									appAddressMap.put(appname, registryList);
								}
							}
						}

						// fresh group address 4.将地址拼接成 "ip1,ip2"的形式，更新到xxl_job_group
						for (XxlJobGroup group: groupList) {
							List<String> registryList = appAddressMap.get(group.getAppname());
							String addressListStr = null;
							if (registryList!=null && !registryList.isEmpty()) {
								Collections.sort(registryList);
								StringBuilder addressListSB = new StringBuilder();
								for (String item:registryList) {
									addressListSB.append(item).append(",");
								}
								addressListStr = addressListSB.toString();
								addressListStr = addressListStr.substring(0, addressListStr.length()-1);
							}
							group.setAddressList(addressListStr);
							group.setUpdateTime(new Date());

							XxlJobAdminConfig.getAdminConfig().getXxlJobGroupDao().update(group);
						}
					}
				} catch (Exception e) {
					if (!toStop) {
						logger.error(">>>>>>>>>>> xxl-job, job registry monitor thread error:{}", e);
					}
				}
				try { // 5.睡眠一个心跳时间，等待下次执行
					TimeUnit.SECONDS.sleep(RegistryConfig.BEAT_TIMEOUT);
				} catch (InterruptedException e) {
					if (!toStop) {
						logger.error(">>>>>>>>>>> xxl-job, job registry monitor thread error:{}", e);
					}
				}
			}
			logger.info(">>>>>>>>>>> xxl-job, job registry monitor thread stop");
		}
	});
	registryMonitorThread.setDaemon(true);
	registryMonitorThread.setName("xxl-job, admin JobRegistryMonitorHelper-registryMonitorThread");
	registryMonitorThread.start();
}
```

简单总结，此处线程做的操作很简单，即通过 xxl_job_registry 提供的心跳/注册数据，更新 xxl_job_group 表，也就是最终我们从页面看到的执行器列表。

![图片](http://blog-1259650185.cosbj.myqcloud.com/img/202204/19/1650342176.png)



## 参考

[xxl-job源码阅读——（三）执行器注册机制](https://mp.weixin.qq.com/s?__biz=MzU0MzQ1NTM4MQ==&mid=2247483761&idx=1&sn=804183a5e8919a5d5c40c2f8ed66c823&chksm=fb0a608bcc7de99d628ae1a9be7651e6a983904880defbbd898024797aed98885b78379659da&cur_album_id=2226684892866740226&scene=190#rd)
