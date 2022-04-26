elastic-job3问题，整改方案及规划

## 1. 作业执行准确性

调度系统最主要是准确地执行作业(分片)，即，不漏一个分片，不重复一个分片，elastic-job分3类作业分片，正常分片，失效转移分片，错过执行分片

### 1.1 重复

失效转移， 失效转移与常规调度并行，elastic-job设置调度线程池为，因此，失效转移触发后可能进入等待，如果抓取多于一片失效分片后，进入作业执行，由于作业分片逻辑获取所有的抓取到的分片，多次的失效转移触发可能执行相同的分片

实例下线后，但实例可能仍在执行作业，另一边，其他实例瓜分了下线实例分片，并执行，分片可能重复执行，甚至并行执行

### 1.2 丢失

1. 重叠执行，elastic-job 重叠执行转 missfired 执行，但 missfired 只记录一次，重复就回丢失

​	解决方案：增加 overlap 配置，是否支持重叠执行，分布式分片，失效转移+错过重执行复杂性大大提高

2. 失效转移分两类，下线节点抓取的转移的分片；下线节点常规分配到的分片

```java
class JobCrashedJobListener implements DataChangedEventListener {

    @Override
    public void onChange(final DataChangedEvent event) {
        if (!JobRegistry.getInstance().isShutdown(jobName) && isFailoverEnabled() && Type.DELETED == event.getType() && instanceNode.isInstancePath(event.getKey())) {
            String jobInstanceId = event.getKey().substring(instanceNode.getInstanceFullPath().length() + 1);
            if (jobInstanceId.equals(JobRegistry.getInstance().getJobInstance(jobName).getJobInstanceId())) { // 本节点不处理
                return;
            }
            List<Integer> failoverItems = failoverService.getFailoveringItems(jobInstanceId); // 获取下线实例抢到的失效转移分片
            if (!failoverItems.isEmpty()) { // 获取下线实例的失效转移中的分片
                for (int each : failoverItems) {
                    failoverService.setCrashedFailoverFlagDirectly(each);
                    failoverService.failoverIfNecessary(); // 主节点回调处理
                }
            } else { // 获取下线实例分配的分片
                for (int each : shardingService.getCrashedShardingItems(jobInstanceId)) {
                    failoverService.setCrashedFailoverFlag(each);
                    failoverService.failoverIfNecessary();
                }
            }
        }
    }
}
```

上面是在线实例抓取下线作业分片的代码，该下线实例，抓取了另一个已下线的实例的分片，因此同时拥有失效分片和自身常规分配的分片，所有剩余的在线节点都在if，else没有被抓取

解决方案，两类合并，一个循环抓取

通过断点调试人为可重现， examples 的例子，设置4个分片，

![img](http://blog-1259650185.cosbj.myqcloud.com/img/202204/26/1650942563.png)

启动3个实例(A、B、C)，断点在 litejob，主节点运行到分片完成，这时候，每个实例分配到分片(其中一个有两个)，关掉其中一个实例，剩下两个实例(假设A和B)抢失效分片，关掉既有失效分片，又有常规分片的实例，此时还剩一个节点，假设是A，断点在 crashed 监听器抓取失效分片前，litejob 断点跑起，可能跑两次，看zk，看A有没有抓到C的失效分片，最后，crashed监听器断点跑起，抓取B的抓取的失效分片，A继续跑结束，B的常规分片没有抓取，丢失

## 2. 网格分片

elastic-job实现的是纵向分片，相当于数据hash分片，这样的粒度是不够的，需要增加横向的切分，即分页，这样每个分片规模可预期，同时增加并行度

## 3. 逻辑分片

分片藏在分片算法，不需预先配置分片，按需生成，减少分片配置项长度，支持动态分片

## 4. 动态分片

elastic-job是静态分片，存在2个问题

1. 数据倾斜，即，部分作业数据少，早完成；另一些任务还有大量数据未完成

2. 分片很多，配置相当长

动态分片实例节点按需领取，配合逻辑分片，最大化利用计算资源

## 5. 动态作业

动态增删作业，新增作业有两种情况，新增新类型的作业，新增已有类型作业的实例

elastic-job无中心分布式架构，没有提供动态增加作业(实例)的api，新增新类型的作业需新的作业实例，新增已有类型实例可以通过修改分片和参数间接实现

## 7. 监控快照

快照服务改造，接入Prometheus exporter，增加作业状态，数据处理量等



## 参考

[分布式调度引擎 elastic-job3 源码分析 (七)- 总结与规划](https://www.jianshu.com/p/b286ba459199)
