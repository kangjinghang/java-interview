你也许已经习惯了使用下面的代码，使一个线程池退出：

```java
bossGroup.shutdownGracefully();
```

那么它是如何工作的呢？由于bossGroup是一个线程池，线程池的关闭要求其中的每一个线程关闭。而线程的实现是在`SingleThreadEventExecutor`类，所以我们将再次回到这个类，首先看其中的shutdownGracefully()方法，其中的参数quietPeriod为静默时间，timeout为超时时间，此外还有一个相关参数gracefulShutdownStartTime即优雅关闭开始时间，代码如下：

```java
// SingleThreadEventExecutor.java
/**
 * Signals this executor that the caller wants the executor to be shut down.  Once this method is called,
 * {@link #isShuttingDown()} starts to return {@code true}, and the executor prepares to shut itself down.
 * Unlike {@link #shutdown()}, graceful shutdown ensures that no tasks are submitted for <i>'the quiet period'</i>
 * (usually a couple seconds) before it shuts itself down.  If a task is submitted during the quiet period,
 * it is guaranteed to be accepted and the quiet period will start over.
 *
 * @param quietPeriod the quiet period as described in the documentation
 * @param timeout     the maximum amount of time to wait until the executor is {@linkplain #shutdown()}
 *                    regardless if a task was submitted during the quiet period
 * @param unit        the unit of {@code quietPeriod} and {@code timeout}
 *
 * @return the {@link #terminationFuture()}
 */
@Override
public Future<?> shutdownGracefully(long quietPeriod, long timeout, TimeUnit unit) {
    ObjectUtil.checkPositiveOrZero(quietPeriod, "quietPeriod"); // 静待时间需要>=0
    if (timeout < quietPeriod) { // 超时时间不能小于静待时间
        throw new IllegalArgumentException(
                "timeout: " + timeout + " (expected >= quietPeriod (" + quietPeriod + "))");
    }
    ObjectUtil.checkNotNull(unit, "unit");

    if (isShuttingDown()) { // 如果状态是关闭中或已关闭，直接返回终止Future
        return terminationFuture();
    }

    boolean inEventLoop = inEventLoop();
    boolean wakeup;
    int oldState;
    for (;;) {
        if (isShuttingDown()) { // 如果状态是关闭中或已关闭，直接返回终止Future
            return terminationFuture();
        }
        int newState;
        wakeup = true;
        oldState = state;
        if (inEventLoop) {
            newState = ST_SHUTTING_DOWN;
        } else {
            switch (oldState) {
                case ST_NOT_STARTED:
                case ST_STARTED:
                    newState = ST_SHUTTING_DOWN; // 改变状态
                    break;
                default:
                    newState = oldState;  // 已经有一个线程已修改好线程状态
                    wakeup = false; // 已经有线程唤醒，所以不用再唤醒
            }
        }
        if (STATE_UPDATER.compareAndSet(this, oldState, newState)) {
            break; // 保证只有一个线程将oldState修改为newState
        }
    }
    gracefulShutdownQuietPeriod = unit.toNanos(quietPeriod); // 在default情况下会更新这两个值
    gracefulShutdownTimeout = unit.toNanos(timeout);
	  // 如果线程之前的状态为ST_NOT_STARTED，则说明该线程还未被启动过，那么启动该线程。
    if (ensureThreadStarted(oldState)) {
        return terminationFuture;
    }

    if (wakeup) {
        taskQueue.offer(WAKEUP_TASK);
        if (!addTaskWakesUp) {
            wakeup(inEventLoop);
        }
    }

    return terminationFuture();
}
```

调用者希望执行器进行关闭的信号。一旦这个方法被调用了，`isShuttingDown()`方法将开始都会返回true，同时执行器准备关闭它自己。不像`shutdown()`方法，优雅关闭会确保在它关闭它自己之前没有任务在`the quiet period`(平静期，即，gracefulShutdownQuietPeriod属性)内提交。如果一个任务在平静期内提交了，它会保证任务被接受并且重新开始平静期。

这段代码真是为多线程同时调用关闭的情况操碎了心，我们抓住其中的关键点。

之前我们说过，NioEventLoop所关联的线程总共有5个状态，分别是：

```java
// NioEventLoop.java
private static final int ST_NOT_STARTED = 1;    // 线程还未启动
private static final int ST_STARTED = 2;        // 线程已经启动
private static final int ST_SHUTTING_DOWN = 3;  // 线程正在关闭
private static final int ST_SHUTDOWN = 4;       // 线程已经关闭
private static final int ST_TERMINATED = 5;     // 线程已经终止
```

其中，在正常的线程状态流为：ST_NOT_STARTED ——> ST_STARTED ——> ST_SHUTTING_DOWN ——> ST_TERMINATED。而ST_SHUTDOWN这个线程状态是已经弃用的『shutdown() or shutdownNow()』所会设置的线程状态，但是无论怎样在此步骤中，线程的状态至少为会置为ST_SHUTTING_DOWN，或者说正常情况下都是会设置为ST_SHUTTING_DOWN的。

该方法只是将线程状态修改为 ST_SHUTTING_DOWN ，并不执行具体的关闭操作（类似的shutdown方法将线程状态修改为ST_SHUTDOWN）。

for()循环是为了保证修改state的线程（原生线程或者外部线程）有且只有一个。因为子类的实现中run()方法是一个EventLoop即一个循环。`ensureThreadStarted`方法启动线程可以完整走一遍正常流程并且可以处理添加到队列中的任务以及IO事件。`wakeup(inEventLoop);`唤醒阻塞在阻塞点上的线程，使其从阻塞状态退出。

要从一个`EventLoop`循环中退出，有什么好方法吗？可能你会想到这样处理：设置一个标记，每次循环都检测这个标记，如果标记为真就退出。Netty正是使用这种方法，`NioEventLoop`的run()方法的循环部分有这样一段代码：

```java
// NioEventLoop.java
if (isShuttingDown()) { // 检测用户是否要终止线程，比如shutdownGracefully
    closeAll(); // 关闭注册的channel
    if (confirmShutdown()) {
        return;
    }
}
```

查询线程状态的方法有三个，实现简单，一并列出：

```java
// SingleThreadEventExecutor.java
public boolean isShuttingDown() {
    return STATE_UPDATER.get(this) >= ST_SHUTTING_DOWN;
}

public boolean isShutdown() {
    return STATE_UPDATER.get(this) >= ST_SHUTDOWN;
}

public boolean isTerminated() {
    return STATE_UPDATER.get(this) == ST_TERMINATED;
}
```

需要注意的是调用`shutdownGracefully()`方法后线程状态为 ST_SHUTTING_DOWN ，调用`shutdown()`方法后线程状态为ST_SHUTDOWN 。`isShuttingDown()`可以一并判断这两种调用方法。`closeAll()`方法关闭注册到`NioEventLoop`的所有Channel，代码不再列出。`confirmShutdown()`方法在`SingleThreadEventExecutor`类，确定是否可以关闭或者说是否可以从`EventLoop`循环中跳出。代码如下：

```java
// SingleThreadEventExecutor.java
protected boolean confirmShutdown() {
    if (!isShuttingDown()) {
        return false; // 没有调用shutdown相关的方法直接返回
    }

    if (!inEventLoop()) { // 必须是原生线程
        throw new IllegalStateException("must be invoked from an event loop");
    }
    // 取消所有 scheduledTasks
    cancelScheduledTasks();

    if (gracefulShutdownStartTime == 0) { // 优雅关闭开始时间，这也是一个标记
        gracefulShutdownStartTime = ScheduledFutureTask.nanoTime();
    }
    // 有task/hook在里面，执行他们，并且不让关闭，因为静默期又有任务做了。
    if (runAllTasks() || runShutdownHooks()) { // 执行完普通任务或者没有普通任务时执行完shutdownHook任务
        if (isShutdown()) {
            // Executor shut down - no new tasks anymore.
            return true; // 调用shutdown()方法直接退出
        }

        // There were tasks in the queue. Wait a little bit more until no tasks are queued for the quiet period or
        // terminate if the quiet period is 0.
        // See https://github.com/netty/netty/issues/4241
        if (gracefulShutdownQuietPeriod == 0) {
            return true; // 优雅关闭静默时间为0也直接退出
        }
        taskQueue.offer(WAKEUP_TASK); // 优雅关闭但有未执行任务，唤醒线程执行
        return false;
    }

    final long nanoTime = ScheduledFutureTask.nanoTime();
    // 是否超过了最大允许允许时间，如果是，需要关闭了，不再等待
    if (isShutdown() || nanoTime - gracefulShutdownStartTime > gracefulShutdownTimeout) {
        return true;
    }
    // 如果静默期做了任务，这不关闭，sleep 100ms，再检查下。
    if (nanoTime - lastExecutionTime <= gracefulShutdownQuietPeriod) {
        // Check if any tasks were added to the queue every 100ms.
        // TODO: Change the behavior of takeTask() so that it returns on timeout.
        taskQueue.offer(WAKEUP_TASK);
        try {
            Thread.sleep(100);
        } catch (InterruptedException e) {
            // Ignore
        }

        return false;
    }
    // 静默期没有做任务，返回需要关闭。此时若用户又提交任务则不会被执行
    // No tasks were added for last quiet period - hopefully safe to shut down.
    // (Hopefully because we really cannot make a guarantee that there will be no execute() calls by a user.)
    return true;
}
```

我们总结一下，调用shutdown()方法从循环跳出的条件有：

1. 执行完普通任务。
2. 没有普通任务，执行完shutdownHook任务。
3. 既没有普通任务也没有shutdownHook任务。

调用shutdownGracefully()方法从循环跳出的条件有：

1. 执行完普通任务且静默时间为0。
2. 没有普通任务，执行完shutdownHook任务且静默时间为0。
3. 静默期间没有任务提交。
4. 优雅关闭超时时间已到。

注意上面所列的条件之间是**或**的关系，也就是说满足任意一条就会从`EventLoop`循环中跳出。我们可以将静默时间看为一段观察期，在此期间如果没有任务执行，说明可以跳出循环；如果此期间有任务执行，执行完后立即进入下一个观察期继续观察；如果连续多个观察期一直有任务执行，那么截止时间到则跳出循环。我们看一下shutdownGracefully() 的默认参数：

```java
// AbstractEventExecutorGroup.java
public Future<?> shutdownGracefully() {
    return shutdownGracefully(2, 15, TimeUnit.SECONDS);
}
```

可知，Netty默认的shutdownGracefully()机制为：在2秒的静默时间内如果没有任务，则关闭；否则15秒截止时间到达时关闭。换句话说，在15秒时间段内，如果有超过2秒的时间段没有任务则关闭。至此，我们明白了从`EvnetLoop`循环中跳出的机制，最后，我们抵达终点站：线程结束机制。这一部分的代码实现在线程工厂的生成方法中：

```java
// SingleThreadEventExecutor.java
private void doStartThread() {
    assert thread == null;
    // 执行线程池里的 task
    executor.execute(new Runnable() {  // 这里的 executor 大家是不是有点熟悉的感觉，它就是一开始我们实例化 NioEventLoop 的时候传进来的 ThreadPerTaskExecutor 的实例。它是每次来一个任务，创建一个线程的那种 executor。
        @Override // 一旦我们调用它的 execute 方法，它就会创建一个新的线程，所以这里终于会创建 Thread 实例
        public void run() {
            thread = Thread.currentThread(); // 看这里，将 “executor” 中创建的这个线程设置为 NioEventLoop 的线程！！！
            if (interrupted) {
                thread.interrupt();
            }

            boolean success = false;
            updateLastExecutionTime();
            try {
                SingleThreadEventExecutor.this.run(); // 具体的子类（NioEventLoop）去执行抽象的run()
                success = true;
            } catch (Throwable t) {
                logger.warn("Unexpected exception from an event executor: ", t);
            } finally {
                for (;;) {
                    int oldState = state;
                    if (oldState >= ST_SHUTTING_DOWN || STATE_UPDATER.compareAndSet( // 用户调用了关闭的方法或者抛出异常
                            SingleThreadEventExecutor.this, oldState, ST_SHUTTING_DOWN)) {
                        break; // 抛出异常也将状态置为ST_SHUTTING_DOWN
                    }
                }

                // Check if confirmShutdown() was called at the end of the loop.
                if (success && gracefulShutdownStartTime == 0) { // time=0，说明confirmShutdown()方法没有调用，记录日志
                    if (logger.isErrorEnabled()) {
                        logger.error("Buggy " + EventExecutor.class.getSimpleName() + " implementation; " +
                                SingleThreadEventExecutor.class.getSimpleName() + ".confirmShutdown() must " +
                                "be called before run() implementation terminates.");
                    }
                }

                try {
                    // Run all remaining tasks and shutdown hooks. At this point the event loop
                    // is in ST_SHUTTING_DOWN state still accepting tasks which is needed for
                    // graceful shutdown with quietPeriod.
                    for (;;) {
                        if (confirmShutdown()) { // 抛出异常时，将普通任务和shutdownHook任务执行完毕
                            break; // 正常关闭时，结合前述的循环跳出条件
                        }
                    }

                    // Now we want to make sure no more tasks can be added from this point. This is
                    // achieved by switching the state. Any new tasks beyond this point will be rejected.
                    for (;;) {
                        int oldState = state;
                        if (oldState >= ST_SHUTDOWN || STATE_UPDATER.compareAndSet(
                                SingleThreadEventExecutor.this, oldState, ST_SHUTDOWN)) {
                            break;
                        }
                    }

                    // We have the final set of tasks in the queue now, no more can be added, run all remaining.
                    // No need to loop here, this is the final pass.
                    confirmShutdown();
                } finally {
                    try {
                        // 关闭selector
                        cleanup();
                    } finally {
                        // Lets remove all FastThreadLocals for the Thread as we are about to terminate and notify
                        // the future. The user may block on the future and once it unblocks the JVM may terminate
                        // and start unloading classes.
                        // See https://github.com/netty/netty/issues/6596.
                        FastThreadLocal.removeAll();

                        STATE_UPDATER.set(SingleThreadEventExecutor.this, ST_TERMINATED); // 线程状态设置为ST_TERMINATED，线程终止
                        threadLock.countDown();
                        int numUserTasks = drainTasks();
                        if (numUserTasks > 0 && logger.isWarnEnabled()) { //  关闭时，任务队列中添加了任务，记录日志
                            logger.warn("An event executor terminated with " +
                                    "non-empty task queue (" + numUserTasks + ')');
                        }
                        terminationFuture.setSuccess(null);  // 异步结果设置为成功
                    }
                }
            }
        }
    });
}
```

`success && gracefulShutdownStartTime == 0`说明子类在实现模板方法run()时，须调用confirmShutdown()方法，不调用的话会有错误日志。25-31行的for()循环主要是对异常情况的处理，但同时也兼顾了正常调用关闭方法的情况。可以将抛出异常的情况视为静默时间为0的shutdownGracefully()方法，这样便于理解循环跳出条件。cleanup()的默认实现什么也不做，`NioEventLoop`覆盖了基类，实现关闭`NioEventLoop`持有的selector：

```java
// NioEventLoop.java
@Override
protected void cleanup() {
    try {
        selector.close();
    } catch (IOException e) {
        logger.warn("Failed to close a selector.", e);
    }
}
```

关于Netty优雅关闭的机制，还有最后一点细节，那就是runShutdownHooks()方法：

```java
// SingleThreadEventExecutor.java
private boolean runShutdownHooks() {
    boolean ran = false;
    // Note shutdown hooks can add / remove shutdown hooks.
    while (!shutdownHooks.isEmpty()) {
        List<Runnable> copy = new ArrayList<Runnable>(shutdownHooks); // 使用copy是因为shutdwonHook任务中可以添加或删除shutdwonHook任务
        shutdownHooks.clear();
        for (Runnable task: copy) {
            try {
                task.run();
            } catch (Throwable t) {
                logger.warn("Shutdown hook raised an exception.", t);
            } finally {
                ran = true;
            }
        }
    }

    if (ran) {
        lastExecutionTime = ScheduledFutureTask.nanoTime();
    }

    return ran;
}
```

此外，还有threadLock.release()方法，如果你还记得字段定义，threadLock是一个初始值为1的信号量。一个初值为1的信号量，当线程请求锁时只会阻塞，这有什么用呢？awaitTermination()方法揭晓答案，用来使其他线程阻塞等待原生线程关闭 ：

```java
// NioEventLoop.java
@Override
public boolean awaitTermination(long timeout, TimeUnit unit) throws InterruptedException {
    ObjectUtil.checkNotNull(unit, "unit");
    if (inEventLoop()) {
        throw new IllegalStateException("cannot await termination of the current thread");
    }

    threadLock.await(timeout, unit);

    return isTerminated();
}
```

## 参考

[自顶向下深入分析Netty（四）--优雅退出机制](https://www.jianshu.com/p/088c5017acd6)

[Netty 源码解析 ——— Netty 优雅关闭流程](https://www.jianshu.com/p/e0ba9050aaef)
