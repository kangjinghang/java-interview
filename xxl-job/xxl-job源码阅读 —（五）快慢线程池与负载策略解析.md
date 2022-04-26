本章介绍 init() 第五个步骤，初始化调度器的 trigger 线程池，以及 trigger 一个任务的详细流程。

## 1. 快慢线程池

### 1.1 定义

JobTriggerPoolHelper.toStart()

```java
// JobTriggerPoolHelper.java
public void start(){
    fastTriggerPool = new ThreadPoolExecutor(
            10,
            XxlJobAdminConfig.getAdminConfig().getTriggerPoolFastMax(),
            60L,
            TimeUnit.SECONDS,
            new LinkedBlockingQueue<Runnable>(1000),
            new ThreadFactory() {
                @Override
                public Thread newThread(Runnable r) {
                    return new Thread(r, "xxl-job, admin JobTriggerPoolHelper-fastTriggerPool-" + r.hashCode());
                }
            });

    slowTriggerPool = new ThreadPoolExecutor(
            10,
            XxlJobAdminConfig.getAdminConfig().getTriggerPoolSlowMax(),
            60L,
            TimeUnit.SECONDS,
            new LinkedBlockingQueue<Runnable>(2000),
            new ThreadFactory() {
                @Override
                public Thread newThread(Runnable r) {
                    return new Thread(r, "xxl-job, admin JobTriggerPoolHelper-slowTriggerPool-" + r.hashCode());
                }
            });
}
```

调度器启动时，初始化了两个线程池，除了慢线程池的队列大一些以及最大线程数由用户自定义以外，其他配置都一致。

两者的区别在于：快线程池用于处理时间短的任务，慢线程池用于处理时间长的任务，这一点在 addTrigger 方法中可以得到验证。

### 1.2 任务处理

JobTriggerPoolHelper.addTrigger()

```java
// job timeout count
private volatile long minTim = System.currentTimeMillis()/60000;     // ms > min
private volatile ConcurrentMap<Integer, AtomicInteger> jobTimeoutCountMap = new ConcurrentHashMap<>();


/**
 * add trigger
 */
public void addTrigger(final int jobId,
                       final TriggerTypeEnum triggerType,
                       final int failRetryCount,
                       final String executorShardingParam,
                       final String executorParam,
                       final String addressList) {

    // choose thread pool
    ThreadPoolExecutor triggerPool_ = fastTriggerPool;
    AtomicInteger jobTimeoutCount = jobTimeoutCountMap.get(jobId); // 通过 jobTimeoutCountMap 判断当前任务在1分钟内是否有曾超过10次的慢任务，是的话则由慢线程池运行。jobTimeoutCountMap 存储了 jobId 曾经的执行耗时
    if (jobTimeoutCount!=null && jobTimeoutCount.get() > 10) {      // job-timeout 10 times in 1 min
        triggerPool_ = slowTriggerPool;
    }

    // trigger
    triggerPool_.execute(new Runnable() {
        @Override
        public void run() {

            long start = System.currentTimeMillis();

            try {
                // do trigger trigger 核心逻辑
                XxlJobTrigger.trigger(jobId, triggerType, failRetryCount, executorShardingParam, executorParam, addressList);
            } catch (Exception e) {
                logger.error(e.getMessage(), e);
            } finally {

                // check timeout-count-map
                long minTim_now = System.currentTimeMillis()/60000;
                if (minTim != minTim_now) { // 一小时一次，清空 jobTimeoutCountMap
                    minTim = minTim_now;
                    jobTimeoutCountMap.clear();
                }

                // incr timeout-count-map
                long cost = System.currentTimeMillis()-start; // 计算耗时，并将大于 500ms 的存储到 jobTimeoutCountMap 中。如果该 job 已存在，则 value+1，这里体现了 value 的含义，记录慢执行的次数
                if (cost > 500) {       // ob-timeout threshold 500ms
                    AtomicInteger timeoutCount = jobTimeoutCountMap.putIfAbsent(jobId, new AtomicInteger(1));
                    if (timeoutCount != null) {
                        timeoutCount.incrementAndGet();
                    }
                }

            }

        }
    });
}
```

到此方法结束，接下来我们继续深入trigger。

## 2. 负载算法

### 2.1 群起而攻之—分片广播

先介绍一下分片广播的算法实现：

如下图，对于一个具体的任务A来说，一般的负载算法都是在众多A任务所属执行器中，通过某种负载算法选择一个进行执行。但是这一类算法对于大数据量的任务不友好，一个任务只会触发一个执行器，如果我们我们的任务过大可能会导致这个执行器溢出/时间过长等问题，此时我们就需要分片广播了。

<img src="http://blog-1259650185.cosbj.myqcloud.com/img/202204/19/1650380973.png" alt="image-20220419230933832" style="zoom: 33%;" />

既然一个执行器不足以处理这个大任务，那我们是不是可以将这个任务拆分，分给其他执行器执行呢？只要任务满足拆分条件，当然是可以的。

<img src="http://blog-1259650185.cosbj.myqcloud.com/img/202204/19/1650381258.png" alt="image-20220419231418188" style="zoom: 33%;" />



这就是`分片广播`算法，接下来我们看一下源码实现。

```java
// XxlJobTrigger.java
/**
 * trigger job
 *
 * @param jobId
 * @param triggerType
 * @param failRetryCount
 * 			>=0: use this param
 * 			<0: use param from job info config
 * @param executorShardingParam  执行器分片参数，一般为 null，只有有失败任务，需要重试的时候才会把上次失败的分片参数再次传进来
 * @param executorParam  执行器参数
 *          null: use job param
 *          not null: cover job param
 * @param addressList
 *          null: use executor addressList
 *          not null: cover
 */
public static void trigger(int jobId,
                           TriggerTypeEnum triggerType,
                           int failRetryCount,
                           String executorShardingParam,
                           String executorParam,
                           String addressList) {

    // load data  1. 加载 job 详情，同时如果存在外部传入的执行参数和执行地址，则使用，这里的外部场景即在页面手动执行的情况
    XxlJobInfo jobInfo = XxlJobAdminConfig.getAdminConfig().getXxlJobInfoDao().loadById(jobId);
    if (jobInfo == null) {
        logger.warn(">>>>>>>>>>>> trigger fail, jobId invalid，jobId={}", jobId);
        return;
    }
    if (executorParam != null) {
        jobInfo.setExecutorParam(executorParam); // 赋值执行期参数
    }
    int finalFailRetryCount = failRetryCount>=0?failRetryCount:jobInfo.getExecutorFailRetryCount();
    XxlJobGroup group = XxlJobAdminConfig.getAdminConfig().getXxlJobGroupDao().load(jobInfo.getJobGroup());

    // cover addressList
    if (addressList!=null && addressList.trim().length()>0) {
        group.setAddressType(1);
        group.setAddressList(addressList.trim());
    }

    // sharding param  2. 这里开始时负载算法为分片广播才会用到的分片参数处理，举例：分片参数格式为 1/3，1 代表index，3 代表total
    int[] shardingParam = null;
    if (executorShardingParam!=null){ // 失败重试时传入了执行器分片参数
        String[] shardingArr = executorShardingParam.split("/");
        if (shardingArr.length==2 && isNumeric(shardingArr[0]) && isNumeric(shardingArr[1])) {
            shardingParam = new int[2];
            shardingParam[0] = Integer.valueOf(shardingArr[0]);
            shardingParam[1] = Integer.valueOf(shardingArr[1]);
        }
    }
    if (ExecutorRouteStrategyEnum.SHARDING_BROADCAST==ExecutorRouteStrategyEnum.match(jobInfo.getExecutorRouteStrategy(), null)
            && group.getRegistryList()!=null && !group.getRegistryList().isEmpty()
            && shardingParam==null) { // 3. 判断负载算法为分片广播，并且 shardingParam 不为 null，则进行分片广播任务处理
        for (int i = 0; i < group.getRegistryList().size(); i++) {
            processTrigger(group, jobInfo, finalFailRetryCount, triggerType, i, group.getRegistryList().size());
        }
    } else { // 4. 否则将 shardingParam 赋默认值，进行任务处理，这里的 processTrigger 不只分片广播，也包含了其他负载处理逻辑
        if (shardingParam == null) {
            shardingParam = new int[]{0, 1};
        }
        processTrigger(group, jobInfo, finalFailRetryCount, triggerType, shardingParam[0], shardingParam[1]);
    }

}
```

接下来，进入最终的处理逻辑，processTrigger() 。

### 2.2 其他负载算法

```java
// XxlJobTrigger.java
/**
 * @param group                     job group, registry list may be empty
 * @param jobInfo
 * @param finalFailRetryCount
 * @param triggerType
 * @param index                     sharding index
 * @param total                     sharding index
 */
private static void processTrigger(XxlJobGroup group, XxlJobInfo jobInfo, int finalFailRetryCount, TriggerTypeEnum triggerType, int index, int total){

    // param 获取任务阻塞处理枚举与负载策略枚举。
    ExecutorBlockStrategyEnum blockStrategy = ExecutorBlockStrategyEnum.match(jobInfo.getExecutorBlockStrategy(), ExecutorBlockStrategyEnum.SERIAL_EXECUTION);  // block strategy
    ExecutorRouteStrategyEnum executorRouteStrategyEnum = ExecutorRouteStrategyEnum.match(jobInfo.getExecutorRouteStrategy(), null);    // route strategy
    String shardingParam = (ExecutorRouteStrategyEnum.SHARDING_BROADCAST==executorRouteStrategyEnum)?String.valueOf(index).concat("/").concat(String.valueOf(total)):null; // 将入参被拆分的 shardingParam 再组合起来，这个格式就是执行器最后会拿到的参数

    // 1、save log-id  保存job日志
    XxlJobLog jobLog = new XxlJobLog();
    jobLog.setJobGroup(jobInfo.getJobGroup());
    jobLog.setJobId(jobInfo.getId());
    jobLog.setTriggerTime(new Date());
    XxlJobAdminConfig.getAdminConfig().getXxlJobLogDao().save(jobLog);
    logger.debug(">>>>>>>>>>> xxl-job trigger start, jobId:{}", jobLog.getId());

    // 2、init trigger-param  组装该任务的执行器触发参数
    TriggerParam triggerParam = new TriggerParam();
    triggerParam.setJobId(jobInfo.getId());
    triggerParam.setExecutorHandler(jobInfo.getExecutorHandler());
    triggerParam.setExecutorParams(jobInfo.getExecutorParam());
    triggerParam.setExecutorBlockStrategy(jobInfo.getExecutorBlockStrategy());
    triggerParam.setExecutorTimeout(jobInfo.getExecutorTimeout());
    triggerParam.setLogId(jobLog.getId());
    triggerParam.setLogDateTime(jobLog.getTriggerTime().getTime());
    triggerParam.setGlueType(jobInfo.getGlueType());
    triggerParam.setGlueSource(jobInfo.getGlueSource());
    triggerParam.setGlueUpdatetime(jobInfo.getGlueUpdatetime().getTime());
    triggerParam.setBroadcastIndex(index);
    triggerParam.setBroadcastTotal(total);

    // 3、init address  这里用了一个策略模式，通过负载策略获取到实际的负载策略处理类
    String address = null;
    ReturnT<String> routeAddressResult = null;
    if (group.getRegistryList()!=null && !group.getRegistryList().isEmpty()) {
        if (ExecutorRouteStrategyEnum.SHARDING_BROADCAST == executorRouteStrategyEnum) {
            if (index < group.getRegistryList().size()) {
                address = group.getRegistryList().get(index);
            } else {
                address = group.getRegistryList().get(0);
            }
        } else {
            routeAddressResult = executorRouteStrategyEnum.getRouter().route(triggerParam, group.getRegistryList());
            if (routeAddressResult.getCode() == ReturnT.SUCCESS_CODE) {
                address = routeAddressResult.getContent();
            }
        }
    } else {
        routeAddressResult = new ReturnT<String>(ReturnT.FAIL_CODE, I18nUtil.getString("jobconf_trigger_address_empty"));
    }

    // 4、trigger remote executor  进行任务处理，请求对应执行器，并等待拿到执行结果。这里使用的就是之前提到的 ExecutorBiz 接口的 run 方法
    ReturnT<String> triggerResult = null;
    if (address != null) {
        triggerResult = runExecutor(triggerParam, address);
    } else {
        triggerResult = new ReturnT<String>(ReturnT.FAIL_CODE, null);
    }

    // 5、collection trigger info  对结果进行格式化处理
    StringBuffer triggerMsgSb = new StringBuffer();
    triggerMsgSb.append(I18nUtil.getString("jobconf_trigger_type")).append("：").append(triggerType.getTitle());
    triggerMsgSb.append("<br>").append(I18nUtil.getString("jobconf_trigger_admin_adress")).append("：").append(IpUtil.getIp());
    triggerMsgSb.append("<br>").append(I18nUtil.getString("jobconf_trigger_exe_regtype")).append("：")
            .append( (group.getAddressType() == 0)?I18nUtil.getString("jobgroup_field_addressType_0"):I18nUtil.getString("jobgroup_field_addressType_1") );
    triggerMsgSb.append("<br>").append(I18nUtil.getString("jobconf_trigger_exe_regaddress")).append("：").append(group.getRegistryList());
    triggerMsgSb.append("<br>").append(I18nUtil.getString("jobinfo_field_executorRouteStrategy")).append("：").append(executorRouteStrategyEnum.getTitle());
    if (shardingParam != null) {
        triggerMsgSb.append("("+shardingParam+")");
    }
    triggerMsgSb.append("<br>").append(I18nUtil.getString("jobinfo_field_executorBlockStrategy")).append("：").append(blockStrategy.getTitle());
    triggerMsgSb.append("<br>").append(I18nUtil.getString("jobinfo_field_timeout")).append("：").append(jobInfo.getExecutorTimeout());
    triggerMsgSb.append("<br>").append(I18nUtil.getString("jobinfo_field_executorFailRetryCount")).append("：").append(finalFailRetryCount);

    triggerMsgSb.append("<br><br><span style=\"color:#00c0ef;\" > >>>>>>>>>>>"+ I18nUtil.getString("jobconf_trigger_run") +"<<<<<<<<<<< </span><br>")
            .append((routeAddressResult!=null&&routeAddressResult.getMsg()!=null)?routeAddressResult.getMsg()+"<br><br>":"").append(triggerResult.getMsg()!=null?triggerResult.getMsg():"");

    // 6、save log trigger-info 更新日志
    jobLog.setExecutorAddress(address);
    jobLog.setExecutorHandler(jobInfo.getExecutorHandler());
    jobLog.setExecutorParam(jobInfo.getExecutorParam());
    jobLog.setExecutorShardingParam(shardingParam);
    jobLog.setExecutorFailRetryCount(finalFailRetryCount);
    //jobLog.setTriggerTime();
    jobLog.setTriggerCode(triggerResult.getCode());
    jobLog.setTriggerMsg(triggerMsgSb.toString());
    XxlJobAdminConfig.getAdminConfig().getXxlJobLogDao().updateTriggerInfo(jobLog);

    logger.debug(">>>>>>>>>>> xxl-job trigger end, jobId:{}", jobLog.getId());
}
```

### 2.3 负载算法

回到上面的 ExecutorRouteStrategyEnum.getRouter 方法。
见下图，这个枚举类，实际上还保存了不同负载策略对应的处理类实例。

```java
public enum ExecutorRouteStrategyEnum {

    private ExecutorRouter router;

    public String getTitle() {
        return title;
    }
    public ExecutorRouter getRouter() {
        return router;
    }

	 // ... 省略其他方法和属性
}
```

这些实例，从上到下与页面一一对应

<img src="http://blog-1259650185.cosbj.myqcloud.com/img/202204/19/1650383749.png" alt="image-20220419235549699" style="zoom: 50%;" />

前四个没什么好说的，字面意思。 

### 2.4 一致性Hash算法

<img src="http://blog-1259650185.cosbj.myqcloud.com/img/202204/19/1650383950.png" alt="image-20220419235910140" style="zoom: 33%;" />



如图所示，一致性Hash算法的目的在于构建一个被节点均等分的圆环，当一个任务到来，落在区间的某一个点上时，向上取节点为执行节点，如图中，Node3将成为任务A的执行节点。 

- 优点：一致性Hash算法的优势在于节点的动态增减对任务的影响小，如图，如果将节点Node3断开，那么此时的任务A将被Node4执行。
- 缺点：负载的均衡性不好保障，100 任务到来，我们如何能够保证100 个任务能够均匀的散落这四个区间上？有同学可能会说给任务按照节点数量取模，那这样不就又回到类似轮询的负载策略了吗？ 

一致性Hash的负载均衡问题还是要靠概率方法解决，如下。

#### 2.4.1 带虚拟节点的一致性Hash算法

虚拟节点通过扩大节点数量来解决均衡问题。

<img src="http://blog-1259650185.cosbj.myqcloud.com/img/202204/20/1650384139.png" alt="image-20220420000219205" style="zoom: 33%;" />



如图所示，这是将3个节点数量扩大3倍，可以看出任务A落在某个节点的随机性将极大的增加，如果我们将节点数量无限制扩大，理论上就可以得到一个完全均衡的分布。 xxl-job正是使用这种方式来实现：

```java
/**
 * 分组下机器地址相同，不同JOB均匀散列在不同机器上，保证分组下机器分配JOB平均；且每个JOB固定调度其中一台机器；
 *      a、virtual node：解决不均衡问题
 *      b、hash method replace hashCode：String的hashCode可能重复，需要进一步扩大hashCode的取值范围
 * Created by xuxueli on 17/3/10.
 */
public class ExecutorRouteConsistentHash extends ExecutorRouter {

    private static int VIRTUAL_NODE_NUM = 100;

    /**
     * get hash code on 2^32 ring (md5散列的方式计算hash值) 。使用了md5hash，并且控制了结果值在0 - 2^32之间，也就是这个环的范围
     * @param key
     * @return
     */
    private static long hash(String key) {

        // md5 byte
        MessageDigest md5;
        try {
            md5 = MessageDigest.getInstance("MD5");
        } catch (NoSuchAlgorithmException e) {
            throw new RuntimeException("MD5 not supported", e);
        }
        md5.reset();
        byte[] keyBytes = null;
        try {
            keyBytes = key.getBytes("UTF-8");
        } catch (UnsupportedEncodingException e) {
            throw new RuntimeException("Unknown string :" + key, e);
        }

        md5.update(keyBytes);
        byte[] digest = md5.digest();

        // hash code, Truncate to 32-bits
        long hashCode = ((long) (digest[3] & 0xFF) << 24)
                | ((long) (digest[2] & 0xFF) << 16)
                | ((long) (digest[1] & 0xFF) << 8)
                | (digest[0] & 0xFF);

        long truncateHashCode = hashCode & 0xffffffffL;
        return truncateHashCode;
    }

    public String hashJob(int jobId, List<String> addressList) {

        // ------A1------A2-------A3------
        // -----------J1------------------
        TreeMap<Long, String> addressRing = new TreeMap<Long, String>();
        for (String address: addressList) {
            for (int i = 0; i < VIRTUAL_NODE_NUM; i++) { // 每个节点扩增100倍，放到环里面
                long addressHash = hash("SHARD-" + address + "-NODE-" + i);
                addressRing.put(addressHash, address);
            }
        }

        long jobHash = hash(String.valueOf(jobId)); // jobId 取 hash，得到 jobId 在环上的位置
        SortedMap<Long, String> lastRing = addressRing.tailMap(jobHash); // tailMap 方法获取的是大于等于这个 key 的键值对，也就是 jobId 后面的所有地址，取这些地址中的第一个，也就是 job 向上取到的节点
        if (!lastRing.isEmpty()) {
            return lastRing.get(lastRing.firstKey());
        }
        return addressRing.firstEntry().getValue(); // 如果 tailMap 方法没有取到值，说明当前任务在环上的位置已经接近最大范围，因为这里是一个圆，所以向上取就会继续从0开始找下一个节点，也就是整个环的第一个节点
    }

    @Override
    public ReturnT<String> route(TriggerParam triggerParam, List<String> addressList) {
        String address = hashJob(triggerParam.getJobId(), addressList);
        return new ReturnT<String>(address);
    }

}
```

### 2.5 LRU与LFU

LRU：最近最久未使用，这里使用了 LinkedHashMap 的 accessOrder（访问后排序）功能实现，比较简单，不再赘述。

```java
/**
 * 单个JOB对应的每个执行器，最久为使用的优先被选举
 *      a、LFU(Least Frequently Used)：最不经常使用，频率/次数
 *      b(*)、LRU(Least Recently Used)：最近最久未使用，时间
 *
 * Created by xuxueli on 17/3/10.
 */
public class ExecutorRouteLRU extends ExecutorRouter {

    private static ConcurrentMap<Integer, LinkedHashMap<String, String>> jobLRUMap = new ConcurrentHashMap<Integer, LinkedHashMap<String, String>>();
    private static long CACHE_VALID_TIME = 0;

    public String route(int jobId, List<String> addressList) {

        // cache clear
        if (System.currentTimeMillis() > CACHE_VALID_TIME) {
            jobLRUMap.clear();
            CACHE_VALID_TIME = System.currentTimeMillis() + 1000*60*60*24;
        }

        // init lru
        LinkedHashMap<String, String> lruItem = jobLRUMap.get(jobId);
        if (lruItem == null) {
            /**
             * LinkedHashMap
             *      a、accessOrder：true=访问顺序排序（get/put时排序）；false=插入顺序排期；
             *      b、removeEldestEntry：新增元素时将会调用，返回true时会删除最老元素；可封装LinkedHashMap并重写该方法，比如定义最大容量，超出是返回true即可实现固定长度的LRU算法；
             */
            lruItem = new LinkedHashMap<String, String>(16, 0.75f, true);
            jobLRUMap.putIfAbsent(jobId, lruItem);
        }

        // put new
        for (String address: addressList) {
            if (!lruItem.containsKey(address)) {
                lruItem.put(address, address);
            }
        }
        // remove old
        List<String> delKeys = new ArrayList<>();
        for (String existKey: lruItem.keySet()) {
            if (!addressList.contains(existKey)) {
                delKeys.add(existKey);
            }
        }
        if (delKeys.size() > 0) {
            for (String delKey: delKeys) {
                lruItem.remove(delKey);
            }
        }

        // load
        String eldestKey = lruItem.entrySet().iterator().next().getKey();
        String eldestValue = lruItem.get(eldestKey);
        return eldestValue;
    }

    @Override
    public ReturnT<String> route(TriggerParam triggerParam, List<String> addressList) {
        String address = route(triggerParam.getJobId(), addressList);
        return new ReturnT<String>(address);
    }

}
```

LFU：最近最不常使用 

```java
public class ExecutorRouteLFU extends ExecutorRouter {
    // 定义lfu缓存，<jobId,<地址，被访问次数>>
    private static ConcurrentMap<Integer, HashMap<String, Integer>> jobLfuMap = new ConcurrentHashMap<Integer, HashMap<String, Integer>>();
    private static long CACHE_VALID_TIME = 0;

    public String route(int jobId, List<String> addressList) {

        // cache clear
        if (System.currentTimeMillis() > CACHE_VALID_TIME) {
            jobLfuMap.clear();
            CACHE_VALID_TIME = System.currentTimeMillis() + 1000*60*60*24; // 每天一次，清理LFU缓存
        }

        // lfu item init  初始化当前job的LFU缓存
        HashMap<String, Integer> lfuItemMap = jobLfuMap.get(jobId);     // Key排序可以用TreeMap+构造入参Compare；Value排序暂时只能通过ArrayList；
        if (lfuItemMap == null) {
            lfuItemMap = new HashMap<String, Integer>();
            jobLfuMap.putIfAbsent(jobId, lfuItemMap);   // 避免重复覆盖
        }

        // put new  增加该job可以使用的地址，这里默认value不是0而是随机数的原因，是为了防止新加入的节点接收到的请求太多
        for (String address: addressList) {
            if (!lfuItemMap.containsKey(address) || lfuItemMap.get(address) >1000000 ) {
                lfuItemMap.put(address, new Random().nextInt(addressList.size()));  // 初始化时主动Random一次，缓解首次压力
            }
        }
        // remove old  清理掉已经不使用的地址
        List<String> delKeys = new ArrayList<>();
        for (String existKey: lfuItemMap.keySet()) {
            if (!addressList.contains(existKey)) {
                delKeys.add(existKey);
            }
        }
        if (delKeys.size() > 0) {
            for (String delKey: delKeys) {
                lfuItemMap.remove(delKey);
            }
        }

        // load least userd count address   借用 Arraylist 的排序，找到 value 最小的那个地址
        List<Map.Entry<String, Integer>> lfuItemList = new ArrayList<Map.Entry<String, Integer>>(lfuItemMap.entrySet());
        Collections.sort(lfuItemList, new Comparator<Map.Entry<String, Integer>>() {
            @Override
            public int compare(Map.Entry<String, Integer> o1, Map.Entry<String, Integer> o2) {
                return o1.getValue().compareTo(o2.getValue());
            }
        });

        Map.Entry<String, Integer> addressItem = lfuItemList.get(0);
        String minAddress = addressItem.getKey(); // 返回结果
        addressItem.setValue(addressItem.getValue() + 1);

        return addressItem.getKey();
    }

    @Override
    public ReturnT<String> route(TriggerParam triggerParam, List<String> addressList) {
        String address = route(triggerParam.getJobId(), addressList);
        return new ReturnT<String>(address);
    }

}
```

#### 2.6 故障转移与忙碌转移

故障转移：如果机器还活着，就用。

如代码所示，逻辑很直接，对地址进行 for 循环，每一个进行心跳检测，只要有一个心跳成功就使用，显然这个逻辑会一直使用活着的第一个节点。

```java
public class ExecutorRouteFailover extends ExecutorRouter {

    @Override
    public ReturnT<String> route(TriggerParam triggerParam, List<String> addressList) {

        StringBuffer beatResultSB = new StringBuffer();
        for (String address : addressList) { // 对地址进行for循环，每一个进行心跳检测
            // beat
            ReturnT<String> beatResult = null;
            try {
                ExecutorBiz executorBiz = XxlJobScheduler.getExecutorBiz(address);
                beatResult = executorBiz.beat(); // 只要有一个心跳成功就使用，显然这个逻辑会一直使用活着的第一个节点
            } catch (Exception e) {
                logger.error(e.getMessage(), e);
                beatResult = new ReturnT<String>(ReturnT.FAIL_CODE, ""+e );
            }
            beatResultSB.append( (beatResultSB.length()>0)?"<br><br>":"")
                    .append(I18nUtil.getString("jobconf_beat") + "：")
                    .append("<br>address：").append(address)
                    .append("<br>code：").append(beatResult.getCode())
                    .append("<br>msg：").append(beatResult.getMsg());

            // beat success
            if (beatResult.getCode() == ReturnT.SUCCESS_CODE) {

                beatResult.setMsg(beatResultSB.toString());
                beatResult.setContent(address);
                return beatResult;
            }
        }
        return new ReturnT<String>(ReturnT.FAIL_CODE, beatResultSB.toString());

    }
}
```

忙碌转移：与故障转移唯一的区别，是不调用心跳检测接口，而是`是否空闲idleBeat`接口。

```java
public class ExecutorRouteBusyover extends ExecutorRouter {

    @Override
    public ReturnT<String> route(TriggerParam triggerParam, List<String> addressList) {
        StringBuffer idleBeatResultSB = new StringBuffer();
        for (String address : addressList) { // // 对地址进行for循环，每一个进行 idle 心跳检测
            // beat
            ReturnT<String> idleBeatResult = null;
            try {
                ExecutorBiz executorBiz = XxlJobScheduler.getExecutorBiz(address);
                idleBeatResult = executorBiz.idleBeat(new IdleBeatParam(triggerParam.getJobId()));  // 只要有一个心跳成功就使用，显然这个逻辑会一直使用活着的第一个节点
            } catch (Exception e) {
                logger.error(e.getMessage(), e);
                idleBeatResult = new ReturnT<String>(ReturnT.FAIL_CODE, ""+e );
            }
            idleBeatResultSB.append( (idleBeatResultSB.length()>0)?"<br><br>":"")
                    .append(I18nUtil.getString("jobconf_idleBeat") + "：")
                    .append("<br>address：").append(address)
                    .append("<br>code：").append(idleBeatResult.getCode())
                    .append("<br>msg：").append(idleBeatResult.getMsg());

            // beat success
            if (idleBeatResult.getCode() == ReturnT.SUCCESS_CODE) {
                idleBeatResult.setMsg(idleBeatResultSB.toString());
                idleBeatResult.setContent(address);
                return idleBeatResult;
            }
        }

        return new ReturnT<String>(ReturnT.FAIL_CODE, idleBeatResultSB.toString());
    }

}
```

我们看一下执行器端 idleBeat 的实现：

```java
// ExecutorBizImpl.java
@Override
public ReturnT<String> idleBeat(IdleBeatParam idleBeatParam) {

    // isRunningOrHasQueue
    boolean isRunningOrHasQueue = false;
    JobThread jobThread = XxlJobExecutor.loadJobThread(idleBeatParam.getJobId());
    if (jobThread != null && jobThread.isRunningOrHasQueue()) {
        isRunningOrHasQueue = true;
    }

    if (isRunningOrHasQueue) {
        return new ReturnT<String>(ReturnT.FAIL_CODE, "job thread is running or has trigger queue.");
    }
    return ReturnT.SUCCESS;
}
```

执行器端缓存了jobId与线程实例的关系，这里直接判断了对应线程实例是否在执行任务，是否还有未执行的任务，都没有才认为是空闲的。



## 参考

[xxl-job源码阅读——（五）快慢线程池与负载策略解析](https://mp.weixin.qq.com/s?__biz=MzU0MzQ1NTM4MQ==&mid=2247483801&idx=1&sn=4d3e1fed58cd3fa7bace8ec6324cfa30&chksm=fb0a6063cc7de975bf262a60657de6c45170daed6a40ec63a9075898afa4ddd527cfe19286f2&cur_album_id=2226684892866740226&scene=190#rd)
