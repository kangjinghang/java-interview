## 1. 丢失任务源码

在前面【执行器注册机制】中我们已经提及AdminBiz与ExecutorBiz的作用，任务的分发运行，取消，上报等也是通过这两个接口来实现。任务“丢失”的判定如下：

<img src="http://blog-1259650185.cosbj.myqcloud.com/img/202204/19/1650371510.png" alt="图片" style="zoom:67%;" />

JobCompleteHelper.getInstance().start()

```java
// JobCompleteHelper.java
public void start(){

	// for callback
  ...

	// for monitor
	monitorThread = new Thread(new Runnable() {

		@Override
		public void run() {

			// wait for JobTriggerPoolHelper-init
			try {
				TimeUnit.MILLISECONDS.sleep(50);
			} catch (InterruptedException e) {
				if (!toStop) {
					logger.error(e.getMessage(), e);
				}
			}

			// monitor
			while (!toStop) {
				try {
					// 任务结果丢失处理：调度记录停留在 "运行中" 状态超过10min，且对应执行器心跳注册失败不在线，则将本地调度主动标记失败；
					Date losedTime = DateUtil.addMinutes(new Date(), -10);
					List<Long> losedJobIds  = XxlJobAdminConfig.getAdminConfig().getXxlJobLogDao().findLostJobIds(losedTime);

					if (losedJobIds!=null && losedJobIds.size()>0) {
						for (Long logId: losedJobIds) {

							XxlJobLog jobLog = new XxlJobLog();
							jobLog.setId(logId);

							jobLog.setHandleTime(new Date());
							jobLog.setHandleCode(ReturnT.FAIL_CODE);
							jobLog.setHandleMsg( I18nUtil.getString("joblog_lost_fail") );

							XxlJobCompleter.updateHandleInfoAndFinish(jobLog);
						}

					}
				} catch (Exception e) {
					if (!toStop) {
						logger.error(">>>>>>>>>>> xxl-job, job fail monitor thread error:{}", e);
					}
				}

				try {
					TimeUnit.SECONDS.sleep(60);
				} catch (Exception e) {
					if (!toStop) {
						logger.error(e.getMessage(), e);
					}
				}

			}

			logger.info(">>>>>>>>>>> xxl-job, JobLosedMonitorHelper stop");

		}
	});
	monitorThread.setDaemon(true);
	monitorThread.setName("xxl-job, admin JobLosedMonitorHelper");
	monitorThread.start();
}
```

## 2. 失败任务源码

失败任务线程主要负责两件事：

1. 重试任务
2. 任务报警

JobFailMonitorHelper.getInstance().start()

一进来老套路，while循环，对了，这里的toStop时一个volatile的boolean，默认为false，当spring容器停止，触发DisposableBean时会被变更为true。

```java
// JobFailMonitorHelper.java
public void start(){
	monitorThread = new Thread(new Runnable() {

		@Override
		public void run() {

			// monitor
			while (!toStop) {
				try {
					// 1. 在xxl_job_log表拿1000条为处理的失败日志
					List<Long> failLogIds = XxlJobAdminConfig.getAdminConfig().getXxlJobLogDao().findFailJobLogIds(1000);
					if (failLogIds!=null && !failLogIds.isEmpty()) {
						for (long failLogId: failLogIds) {

							// lock log  2. 通过CAS锁住一条日志进行操作
							int lockRet = XxlJobAdminConfig.getAdminConfig().getXxlJobLogDao().updateAlarmStatus(failLogId, 0, -1);
							if (lockRet < 1) {
								continue;
							}
							XxlJobLog log = XxlJobAdminConfig.getAdminConfig().getXxlJobLogDao().load(failLogId);
							XxlJobInfo info = XxlJobAdminConfig.getAdminConfig().getXxlJobInfoDao().loadById(log.getJobId());

							// 1、fail retry monitor  3. 判断是否还有剩余失败重试次数，有则重试，并将次数 -1
							if (log.getExecutorFailRetryCount() > 0) {
								JobTriggerPoolHelper.trigger(log.getJobId(), TriggerTypeEnum.RETRY, (log.getExecutorFailRetryCount()-1), log.getExecutorShardingParam(), log.getExecutorParam(), null);
								String retryMsg = "<br><br><span style=\"color:#F39C12;\" > >>>>>>>>>>>"+ I18nUtil.getString("jobconf_trigger_type_retry") +"<<<<<<<<<<< </span><br>";
								log.setTriggerMsg(log.getTriggerMsg() + retryMsg);
								XxlJobAdminConfig.getAdminConfig().getXxlJobLogDao().updateTriggerInfo(log);
							}

							// 2、fail alarm monitor  4. 触发邮件报警，这里我们稍加改造就可以实现短信/企微等其他报警
							int newAlarmStatus = 0;		// 告警状态：0-默认、-1=锁定状态、1-无需告警、2-告警成功、3-告警失败
							if (info != null) {
								boolean alarmResult = XxlJobAdminConfig.getAdminConfig().getJobAlarmer().alarm(info, log);
								newAlarmStatus = alarmResult?2:3;
							} else {
								newAlarmStatus = 1;
							}
							// 5. CAS再次更新当前log的告警状态
							XxlJobAdminConfig.getAdminConfig().getXxlJobLogDao().updateAlarmStatus(failLogId, -1, newAlarmStatus);
						}
					}

				} catch (Exception e) {
					if (!toStop) {
						logger.error(">>>>>>>>>>> xxl-job, job fail monitor thread error:{}", e);
					}
				}

				try {
					TimeUnit.SECONDS.sleep(10);
				} catch (Exception e) {
					if (!toStop) {
						logger.error(e.getMessage(), e);
					}
				}

			}

			logger.info(">>>>>>>>>>> xxl-job, job fail monitor thread stop");

		}
	});
	monitorThread.setDaemon(true);
	monitorThread.setName("xxl-job, admin JobFailMonitorHelper");
	monitorThread.start();
}
```

## 3. 扩展报警方式

在失败处理线程中，我们看到了JobAlarmer，我们看一下他的结构。

![image-20220419210557792](http://blog-1259650185.cosbj.myqcloud.com/img/202204/19/1650373557.png)

这里的解耦味道不错。 

- JobAlarmer 是警报触发器，负责触发的动作。
- JobAlarm 的实现类是实际警报处理器，比如此处的 EmailJobAlarm 实现了邮件的发送。

同理我们也可以增加一些其他方式的报警处理器:

1. 需要实现 JobAlarm 的 doAlarm 方法即可。

```java
public interface JobAlarm {

    /**
     * job alarm
     *
     * @param info
     * @param jobLog
     * @return
     */
    public boolean doAlarm(XxlJobInfo info, XxlJobLog jobLog);

}
```

2. 如果需要发送地址，比如短信报警，可以复用页面的“报警邮件”这一项，或者自定义，再增加一个字段，然后在新增的doAlarm里面解析使用即可。



## 参考

[xxl-job源码阅读——（四）丢失，失败处理机制及扩展报警方式](https://mp.weixin.qq.com/s?__biz=MzU0MzQ1NTM4MQ==&mid=2247483773&idx=1&sn=daa9747badc730cb503e77ccb7de269f&chksm=fb0a6087cc7de9918d7ae608d8c45a6eb9b32c2c5c6d90ee646a11596fa8b7d6fa0edd9ea15d&cur_album_id=2226684892866740226&scene=190#rd)
