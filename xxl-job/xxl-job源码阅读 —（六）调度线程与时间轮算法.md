本章介绍 init() 最后一个步骤，初始化调度线程。

另外 第六步的 JobLogReportHelper.getInstance().start() 只是做了一个日志整理收集，最终在页面图表展示的工作，这里不再深入。

JobScheduleHelper.getInstance().start() 开启了两个线程，基础调度 scheduleThread，与时间轮调度 ringThread。

```java
public class JobScheduleHelper {

    private Thread scheduleThread; // 基础调度
    private Thread ringThread; // 时间轮调度
   // ... 省略其他方法和属性
}
```

## 1. 时间对齐

scheduleThread 作为时间调度线程，自身的时间是如何对齐到整秒上的呢？

如下代码可见，在线程启动的同时，sleep 了 `5000-System.currentTimeMillis()%1000` 个毫秒，等到整5秒的倍数。

```java
try {
    TimeUnit.MILLISECONDS.sleep(5000 - System.currentTimeMillis()%1000 );
} catch (InterruptedException e) {
    if (!scheduleThreadToStop) {
        logger.error(e.getMessage(), e);
    }
}
```

举例: 现在是 17:37:05 的100ms，那么上述公式 = 4900ms，从现在开始睡眠 4900ms，唤醒的时刻，便是整5秒倍数的17:37:10。

那么为什么是 5s 呢？再看预读时间变量，一致。预读时间变量的作用是每次读取现在开始的未来 5s 内的任务，用于处理执行。

```java
public static final long PRE_READ_MS = 5000;    // pre read
```

shceduled 线程在 while 循环的最后还有一次时间对齐：如果预读处理了一些数据，那么就等待到下一个整 5s，如果没有预读到数据，说明当前无任务，直接等待下一个 5s。

```java
// Wait seconds, align second
if (cost < 1000) {  // scan-overtime, not wait
    try { // 如果预读处理了一些数据，那么就等待到下一个整 5s，如果没有预读到数据，说明当前无任务，直接等待下一个 5s
        // pre-read period: success > scan each second; fail > skip this period;
        TimeUnit.MILLISECONDS.sleep((preReadSuc?1000:PRE_READ_MS) - System.currentTimeMillis()%1000);
    } catch (InterruptedException e) {
        if (!scheduleThreadToStop) {
            logger.error(e.getMessage(), e);
        }
    }
}
```

时间轮线程也有同样的时间对齐，只不过不是 5s，而是 1s，不再展开。

## 2. scheduleThread 调度线程

跳过时间对齐，往后看。

```java
// JobScheduleHelper.java
// schedule thread
scheduleThread = new Thread(new Runnable() {
    @Override
    public void run() {

        try {
            TimeUnit.MILLISECONDS.sleep(5000 - System.currentTimeMillis()%1000 );
        } catch (InterruptedException e) {
            if (!scheduleThreadToStop) {
                logger.error(e.getMessage(), e);
            }
        }
        logger.info(">>>>>>>>> init xxl-job admin scheduler success.");
        // 计算预读数据，这里的数据是作者根据qps平均计算得到的，正常case下5s内能够处理的数量。这里的时间计算只涉及调度过程，实际trigger业务已经被快慢线程池接手，所以这里的数量预估理论上是没问题的
        // pre-read count: treadpool-size * trigger-qps (each trigger cost 50ms, qps = 1000/50 = 20)
        int preReadCount = (XxlJobAdminConfig.getAdminConfig().getTriggerPoolFastMax() + XxlJobAdminConfig.getAdminConfig().getTriggerPoolSlowMax()) * 20; // 300 * 20 = 6000

        while (!scheduleThreadToStop) {

            // Scan Job
            long start = System.currentTimeMillis();

            Connection conn = null;
            Boolean connAutoCommit = null;
            PreparedStatement preparedStatement = null;

            boolean preReadSuc = true;
            try {

                conn = XxlJobAdminConfig.getAdminConfig().getDataSource().getConnection();
                connAutoCommit = conn.getAutoCommit();
                conn.setAutoCommit(false);
                // 悲观锁，支持多节点部署
                preparedStatement = conn.prepareStatement(  "select * from xxl_job_lock where lock_name = 'schedule_lock' for update" );
                preparedStatement.execute();

                // tx start

                // 1、pre read
                long nowTime = System.currentTimeMillis();
                List<XxlJobInfo> scheduleList = XxlJobAdminConfig.getAdminConfig().getXxlJobInfoDao().scheduleJobQuery(nowTime + PRE_READ_MS, preReadCount); // 根据预读数量和预读时间，取出即将要处理的任务
                if (scheduleList!=null && scheduleList.size()>0) {
                    // 2、push time-ring
                    for (XxlJobInfo jobInfo: scheduleList) {

                        // time-ring jump
                        if (nowTime > jobInfo.getTriggerNextTime() + PRE_READ_MS) { // 如果当前时间已经超过了任务原定计划时间 +5s 的范围，则跳过，本次不再执行
                            // 2.1、trigger-expire > 5s：pass && make next-trigger-time
                            logger.warn(">>>>>>>>>>> xxl-job, schedule misfire, jobId = " + jobInfo.getId());

                            // 1、misfire match
                            MisfireStrategyEnum misfireStrategyEnum = MisfireStrategyEnum.match(jobInfo.getMisfireStrategy(), MisfireStrategyEnum.DO_NOTHING);
                            if (MisfireStrategyEnum.FIRE_ONCE_NOW == misfireStrategyEnum) { // 如果调度过期策略是立即执行一次，那么立即执行
                                // FIRE_ONCE_NOW 》 trigger
                                JobTriggerPoolHelper.trigger(jobInfo.getId(), TriggerTypeEnum.MISFIRE, -1, null, null, null);
                                logger.debug(">>>>>>>>>>> xxl-job, schedule push trigger : jobId = " + jobInfo.getId() );
                            }

                            // 2、fresh next 刷新下一次任务调度时间
                            refreshNextValidTime(jobInfo, new Date());

                        } else if (nowTime > jobInfo.getTriggerNextTime()) { // 如果当前时间已经超过原定计划时间但是未超过5s，还能抢救一下，执行任务
                            // 2.2、trigger-expire < 5s：direct-trigger && make next-trigger-time

                            // 1、trigger 抢救一下，立即执行
                            JobTriggerPoolHelper.trigger(jobInfo.getId(), TriggerTypeEnum.CRON, -1, null, null, null);
                            logger.debug(">>>>>>>>>>> xxl-job, schedule push trigger : jobId = " + jobInfo.getId() );

                            // 2、fresh next 刷新下一次任务调度时间
                            refreshNextValidTime(jobInfo, new Date());

                            // next-trigger-time in 5s, pre-read again  调度成功并且如果下一次执行时间在未来5s内，那么直接将任务塞给时间轮线程，让时间轮线程负责下一次执行
                            if (jobInfo.getTriggerStatus()==1 && nowTime + PRE_READ_MS > jobInfo.getTriggerNextTime()) {

                                // 1、make ring second
                                int ringSecond = (int)((jobInfo.getTriggerNextTime()/1000)%60);

                                // 2、push time ring  塞给时间轮线程
                                pushTimeRing(ringSecond, jobInfo.getId());

                                // 3、fresh next 刷新下一次任务调度时间
                                refreshNextValidTime(jobInfo, new Date(jobInfo.getTriggerNextTime()));

                            }

                        } else { // 还未到执行时间，直接扔给时间轮线程
                            // 2.3、trigger-pre-read：time-ring trigger && make next-trigger-time

                            // 1、make ring second
                            int ringSecond = (int)((jobInfo.getTriggerNextTime()/1000)%60);

                            // 2、push time ring 塞给时间轮线程
                            pushTimeRing(ringSecond, jobInfo.getId());

                            // 3、fresh next 刷新下一次任务调度时间
                            refreshNextValidTime(jobInfo, new Date(jobInfo.getTriggerNextTime()));

                        }

                    }

                    // 3、update trigger info
                    for (XxlJobInfo jobInfo: scheduleList) { // 更新任务信息，（下一次执行时间，任务状态等）
                        XxlJobAdminConfig.getAdminConfig().getXxlJobInfoDao().scheduleUpdate(jobInfo);
                    }

                } else {
                    preReadSuc = false;
                }

                // tx stop


            } catch (Exception e) {
                if (!scheduleThreadToStop) {
                    logger.error(">>>>>>>>>>> xxl-job, JobScheduleHelper#scheduleThread error:{}", e);
                }
            } finally {

                // commit
                if (conn != null) {
                    try {
                        conn.commit();
                    } catch (SQLException e) {
                        if (!scheduleThreadToStop) {
                            logger.error(e.getMessage(), e);
                        }
                    }
                    try {
                        conn.setAutoCommit(connAutoCommit);
                    } catch (SQLException e) {
                        if (!scheduleThreadToStop) {
                            logger.error(e.getMessage(), e);
                        }
                    }
                    try {
                        conn.close();
                    } catch (SQLException e) {
                        if (!scheduleThreadToStop) {
                            logger.error(e.getMessage(), e);
                        }
                    }
                }

                // close PreparedStatement
                if (null != preparedStatement) {
                    try {
                        preparedStatement.close();
                    } catch (SQLException e) {
                        if (!scheduleThreadToStop) {
                            logger.error(e.getMessage(), e);
                        }
                    }
                }
            }
            long cost = System.currentTimeMillis()-start; // 调度耗时


            // Wait seconds, align second
            if (cost < 1000) {  // scan-overtime, not wait 调度耗时超过 1s，不需要 sleep，否则，需要
                try { // 如果预读处理了一些数据，那么就等待到下一个整 1s，如果没有预读到数据，说明当前无任务调度，直接等待下一个 5s
                    // pre-read period: success > scan each second; fail > skip this period;
                    TimeUnit.MILLISECONDS.sleep((preReadSuc?1000:PRE_READ_MS) - System.currentTimeMillis()%1000);
                } catch (InterruptedException e) {
                    if (!scheduleThreadToStop) {
                        logger.error(e.getMessage(), e);
                    }
                }
            }

        }

        logger.info(">>>>>>>>>>> xxl-job, JobScheduleHelper#scheduleThread stop");
    }
});
scheduleThread.setDaemon(true);
scheduleThread.setName("xxl-job, admin JobScheduleHelper#scheduleThread");
scheduleThread.start();
```

由上可见，未过期的任务，在 5s 的时间范围内，精确的调度都被交给了时间轮线程，下面我们就继续深入，了解一下时间轮算法的实现。

## 3. ringThread 时间轮（算法）线程

思考一下，我们实现一个遵循 cron 表达式的调度功能会怎么做？

- 方案1：启动一个线程，计算将要执行时间到当前时间的秒数，直接 sleep 这个秒数。当执行完一次任务后，再计算下次执行时间到当前时间的秒数，继续sleep。 

> 这个方法想想也不是不行，但是缺点是，当我们需要多个cron任务时，需要开启多个线程，造成资源的浪费。

- 方案2：只用一个守护线程，任务死循环扫任务数据，拿执行时间距离当前最近的任务，如果该任务时间等同于当前时间（或者在当前之间很小的一个范围内），则执行，否则不执行，等待下一个循环。 

> 此方案似乎解决了线程数量爆炸的问题，但是又会引入一个新的问题，如果某一个任务执行时间太长，显然会阻塞其他任务，导致其他任务不能及时执行。

- 方案3：在方案2的基础上，责任拆分，一个线程为调度线程，另外有一个线程池为执行线程池，这样便可以一定程度避免长任务阻塞的问题。

​	<img src="http://blog-1259650185.cosbj.myqcloud.com/img/202204/20/1650430167.png" alt="image-20220420124927252" style="zoom: 33%;" />

> 但是，毫无限制的死循环查询数据，无论这个任务数据存在数据库还是其他地方，似乎都不是一个优雅的方案。那么有没有一种方式，能如同时钟一般，指针到了才执行对应时间的任务。

时间轮算法，顾名思义，时间轮其实很简单，就是用实际的时钟刻度槽位来存储任务，如下图，我们以小时为单位，9:00执行A任务，10:00执行B，C任务。

<img src="http://blog-1259650185.cosbj.myqcloud.com/img/202204/20/1650430250.png" alt="image-20220420125050016" style="zoom: 33%;" />

<img src="http://blog-1259650185.cosbj.myqcloud.com/img/202204/20/1650430285.png" alt="image-20220420125125600" style="zoom:33%;" />

这里的刻度当然也可以更细致，比如把一天切分成 24\*60\*60 个秒的刻度，秒的刻度上挂任务。
我们只需要在`方案3`的基础上改造：

- 声明一个变量Map<时间刻度，所属任务集合>。
- 任务增加时，只需要增加到对应的时间轮上。
- 仍然有一个线程在死循环，按照秒的刻度1秒执行一次（如何对齐时间请看第一部分），到达这一秒时从Map中取出对应任务，使用线程池进行执行。

> 时间轮算法也不是完美的，如果某一个刻度上的任务太多，即便任务的执行使用线程池处理，仍然可能会导致执行到下一秒还没完成。毕竟我们对任务的调度，总要对任务的状态等细节进行处理，尤其是这些状态的更新依赖数据库等外部数据源时。

### 3.1 源码实现

xxl-job 的时间轮算法实现与上述有所区别，通过之前的描述我们已经知道 scheduleThread 已经做了调度的一部分工作，包括取出任务，对过期/到期任务进行执行。
而对将来5秒内将要执行的任务，scheduleThread则是通过如下代码的 pushTimRing 方法扔给了时间轮Map： 

```java
// JobScheduleHelper.java
private volatile static Map<Integer, List<Integer>> ringData = new ConcurrentHashMap<>();

private void pushTimeRing(int ringSecond, int jobId){
    // push async ring
    List<Integer> ringItemData = ringData.get(ringSecond);
    if (ringItemData == null) {
        ringItemData = new ArrayList<Integer>();
        ringData.put(ringSecond, ringItemData);
    }
    ringItemData.add(jobId);

    logger.debug(">>>>>>>>>>> xxl-job, schedule push time-ring : " + ringSecond + " = " + Arrays.asList(ringItemData) );
}
```

ringData 是一个秒级的时间轮，时间轮的范围是 0~59。

```java
// JobScheduleHelper.java
// ring thread
ringThread = new Thread(new Runnable() {
    @Override
    public void run() {

        while (!ringThreadToStop) {

            // align second 线程启动时，对齐这一秒
            try {
                TimeUnit.MILLISECONDS.sleep(1000 - System.currentTimeMillis() % 1000);
            } catch (InterruptedException e) {
                if (!ringThreadToStop) {
                    logger.error(e.getMessage(), e);
                }
            }

            try {
                // second data
                List<Integer> ringItemData = new ArrayList<>();
                int nowSecond = Calendar.getInstance().get(Calendar.SECOND);   // 避免处理耗时太长，跨过刻度，向前校验一个刻度；
                for (int i = 0; i < 2; i++) { // 通过当前秒获取ringData中的任务，同时为了防止之前有延时产生，也检查一下前一秒的刻度中是否还存在未处理的任务
                    List<Integer> tmpData = ringData.remove( (nowSecond+60-i)%60 );
                    if (tmpData != null) {
                        ringItemData.addAll(tmpData);
                    }
                }

                // ring trigger
                logger.debug(">>>>>>>>>>> xxl-job, time-ring beat : " + nowSecond + " = " + Arrays.asList(ringItemData) );
                if (ringItemData.size() > 0) {
                    // do trigger
                    for (int jobId: ringItemData) {
                        // do trigger  触发任务，扔到快慢线程池去处理
                        JobTriggerPoolHelper.trigger(jobId, TriggerTypeEnum.CRON, -1, null, null, null);
                    }
                    // clear
                    ringItemData.clear(); // 清理临时变量
                }
            } catch (Exception e) {
                if (!ringThreadToStop) {
                    logger.error(">>>>>>>>>>> xxl-job, JobScheduleHelper#ringThread error:{}", e);
                }
            }
        }
        logger.info(">>>>>>>>>>> xxl-job, JobScheduleHelper#ringThread stop");
    }
});
ringThread.setDaemon(true);
ringThread.setName("xxl-job, admin JobScheduleHelper#ringThread");
ringThread.start();
```

总结：xxl-job实现的是一个 5s 一次的定时任务调度，同时对未来 5s 将被执行的任务，使用一个范围为一分钟，刻度为秒的时间轮算法来执行。



## 参考

[xxl-job源码阅读——（六）调度线程与时间轮算法](https://mp.weixin.qq.com/s?__biz=MzU0MzQ1NTM4MQ==&mid=2247483818&idx=1&sn=d42e1e3db6e8bf471747c1b3c6585a24&chksm=fb0a6050cc7de946af261706fe59d4fdec044900813346b4599882c50873292d1a1f0998dd3d&cur_album_id=2226684892866740226&scene=190#rd)
