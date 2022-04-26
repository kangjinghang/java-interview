## 1. JAVA Sever

讲到 Netty 不得不提它的历史，而他产生的历史又与 Java IO 有着密切的联系。 

### 1.1 BIO与NIO

什么是 BIO 和 NIO ？ 

> Block IO，顾名思义，这是一种阻塞的 IO 方式，IO的过程无非 read 和 write，而这两个操作在执行过程中，执行线程需要被阻塞，这就是 BIO。
> 对应的，NIO(NonBlock IO) 就是非阻塞式 read 和 write，数据的 read 和 write 都是从计算机中的一个区域到另一个区域，这个过程内核可以处理，不需要执行线程的参与。

什么是BIO网络模型？ 

> 同步且阻塞：服务器端，一个线程专属一个连接，即客户端有连接请求时服务器端就需要启动一个线程进行处理。 

Java 中的 BIO 实现位于核心包的 Java.io，这里的实现已经属于元老级。

### 1.2 BIO实现

<img src="http://blog-1259650185.cosbj.myqcloud.com/img/202204/21/1650545279.png" alt="图片" style="zoom: 67%;" />

- 第一步，新建ServerSocket，绑定到8080端口
- 第二步，主线程死循环等待新连接到来
- 第三步，accept 方法阻塞监听端口是否连接，这里的阻塞即前文解释的执行线程被阻塞。
- 第四步，对 socket 的数据进行 read，write并执行业务逻辑，这里使用了线程池，因为 read 和 write 也是阻塞的，如果不使用额外的线程，主线程将被阻塞。

问题:

这里我们关系的几个阻塞点，accept，read，write，由于 read 和 write 已经由线程池处理，所以阻塞主线程的问题主要在 accept。 

> 注意，这里提到的accept，read和write指的都是系统调用

### 1.3 NIO实现

既然 accept 是阻塞的，那么我们使用 NIO 非阻塞的实现：

<img src="http://blog-1259650185.cosbj.myqcloud.com/img/202204/21/1650553412.png" alt="图片" style="zoom:67%;" />

<img src="http://blog-1259650185.cosbj.myqcloud.com/img/202204/21/1650545412.png" alt="图片" style="zoom:67%;" />

- 第一步，开启一个ServerSockt并绑定端口，同时设置Blocking为false开启非阻塞。
- 第二步，死循环，此处accept已经是非阻塞了（同时server对象的read/write也是非阻塞），所以可能拿到空，需要判断有连接时才存起来。
- 第三步，将保存起来的连接使用线程池进行分别处理，一对一进行读写及业务逻辑。

问题：NIO的问题仍然在 accept()，如果同一段时间有大量客户端连接，那么程序需要每次轮询都对所有的连接进行判断是否有数据请求了。
如果此时10万个连接中只有1个连接在进行数据请求，系统资源将极大的浪费。

### 1.4 IO多路复用

多路复用解决了上述问题，它在 accept/read/write 方法之前，先使用（select()/poll()/epoll()）方法进行 Socket 中是否有对应的数据请求的检测。有了系统调用，程序就只需要等待回调即可，回调告诉我们是 accept 就进行 accpet，是 read/write 就进行相关数据处理。

> 上述 select()/poll()/epoll() 三个系统调用的作用在于： 允许程序同时在多个底层文件描述符（理解成连接即可）上，等待输入的到达或输出的完成。
> 三个调用的区别见下图：
>
> ![图片](http://blog-1259650185.cosbj.myqcloud.com/img/202204/21/1650553540.png)

代码 Demo：

<img src="http://blog-1259650185.cosbj.myqcloud.com/img/202204/21/1650553583.png" alt="图片" style="zoom:67%;" />

<img src="http://blog-1259650185.cosbj.myqcloud.com/img/202204/21/1650553590.png" alt="图片" style="zoom:67%;" />

- 第一步，ServerSocket 绑定端口，设置非阻塞
- 第二步，开启 Selector，即使用上述三个系统调用。
- 第三步，SelectionKey 即为 action类型（accept动作还是其他），这里进行获取类型的判断，分别进行不同的处理
- 第四步，如果是 accept类型，注册一个新的 socketChannel（连接）并且监听他的 read 动作，write 动作，准备接收客户端的新数据。
- 第五步，如果是读，把需要返还给客户端的数据给到 socketChannel。
- 第六步，如果是写，从 socketChannel 中取出数据进行处理。

## 2. 执行器源码实现——Netty

多路复用也被称为 Reactor，而 Netty 的设计正是基于 Reactor。
我们接着【xxl-job源码阅读——（七）执行器启动与动态代码加载解读】继续往下看 EmbedServer 的start。 

EmbedServer.start()

```java
// EmbedServer.java
public void start(final String address, final int port, final String appname, final String accessToken) {
    executorBiz = new ExecutorBizImpl(); // 实例化ExecutorBizImpl
    thread = new Thread(new Runnable() {

        @Override
        public void run() {

            // param  声明了bossGroup和workGroup，这是两个Reactor（多路复用模型），前者负责监听连接，后者负责处理读写和业务逻辑处理
            EventLoopGroup bossGroup = new NioEventLoopGroup();
            EventLoopGroup workerGroup = new NioEventLoopGroup();
            ThreadPoolExecutor bizThreadPool = new ThreadPoolExecutor( // 声明了一个业务连接池
                    0,
                    200,
                    60L,
                    TimeUnit.SECONDS,
                    new LinkedBlockingQueue<Runnable>(2000),
                    new ThreadFactory() {
                        @Override
                        public Thread newThread(Runnable r) {
                            return new Thread(r, "xxl-job, EmbedServer bizThreadPool-" + r.hashCode());
                        }
                    },
                    new RejectedExecutionHandler() {
                        @Override
                        public void rejectedExecution(Runnable r, ThreadPoolExecutor executor) {
                            throw new RuntimeException("xxl-job, EmbedServer bizThreadPool is EXHAUSTED!");
                        }
                    });


            try {
                // start server
                ServerBootstrap bootstrap = new ServerBootstrap(); // 声明一个ServerBootstrap，这是一个服务启动的引导器
                bootstrap.group(bossGroup, workerGroup)
                        .channel(NioServerSocketChannel.class)
                        .childHandler(new ChannelInitializer<SocketChannel>() {
                            @Override
                            public void initChannel(SocketChannel channel) throws Exception {
                                channel.pipeline() // 对引导器绑定group，SocketChannel以及各种handler，这其中 EmbedHttpServerHandler 是 xxl-job 业务自定义的处理器
                                        .addLast(new IdleStateHandler(0, 0, 30 * 3, TimeUnit.SECONDS))  // beat 3N, close if 。idle IdleStateHandler主要是用来检测远端是否存活
                                        .addLast(new HttpServerCodec()) // HttpServerCodec 和 HttpObjectAggregator是 netty 对 http 请求数据的处理类
                                        .addLast(new HttpObjectAggregator(5 * 1024 * 1024))  // merge request & reponse to FULL
                                        .addLast(new EmbedHttpServerHandler(executorBiz, accessToken, bizThreadPool));
                            }
                        })
                        .childOption(ChannelOption.SO_KEEPALIVE, true);

                // bind
                ChannelFuture future = bootstrap.bind(port).sync(); // 绑定端口，并以同步方式启动服务

                logger.info(">>>>>>>>>>> xxl-job remoting server start success, nettype = {}, port = {}", EmbedServer.class, port);

                // start registry
                startRegistry(appname, address); // 启动 xxl-job 执行器的注册线程

                // wait util stop
                future.channel().closeFuture().sync(); // 让 netty 服务器线程不会关闭

            } catch (InterruptedException e) {
                if (e instanceof InterruptedException) {
                    logger.info(">>>>>>>>>>> xxl-job remoting server stop.");
                } else {
                    logger.error(">>>>>>>>>>> xxl-job remoting server error.", e);
                }
            } finally {
                // stop
                try {
                    workerGroup.shutdownGracefully();
                    bossGroup.shutdownGracefully();
                } catch (Exception e) {
                    logger.error(e.getMessage(), e);
                }
            }

        }

    });
    thread.setDaemon(true);	// daemon, service jvm, user thread leave >>> daemon leave >>> jvm leave
    thread.start();
}
```

EmbedHttpServerHandler.channelRead0() 

channelRead0 是 SimpleChannelInboundHandler 方法，netty 调用 Handler 时将会调用该方法。

```java
// EmbedHttpServerHandler.java
public static class EmbedHttpServerHandler extends SimpleChannelInboundHandler<FullHttpRequest> {
    private static final Logger logger = LoggerFactory.getLogger(EmbedHttpServerHandler.class);

    private ExecutorBiz executorBiz;
    private String accessToken;
    private ThreadPoolExecutor bizThreadPool;
    public EmbedHttpServerHandler(ExecutorBiz executorBiz, String accessToken, ThreadPoolExecutor bizThreadPool) {
        this.executorBiz = executorBiz;
        this.accessToken = accessToken;
        this.bizThreadPool = bizThreadPool;
    }

    @Override
    protected void channelRead0(final ChannelHandlerContext ctx, FullHttpRequest msg) throws Exception {

        // request parse
        //final byte[] requestBytes = ByteBufUtil.getBytes(msg.content());    // byteBuf.toString(io.netty.util.CharsetUtil.UTF_8);
        String requestData = msg.content().toString(CharsetUtil.UTF_8); // 转换编码，拿到请求数据
        String uri = msg.uri();
        HttpMethod httpMethod = msg.method();
        boolean keepAlive = HttpUtil.isKeepAlive(msg);
        String accessTokenReq = msg.headers().get(XxlJobRemotingUtil.XXL_JOB_ACCESS_TOKEN); // 从数据中解析出 xxl-job 的token

        // invoke
        bizThreadPool.execute(new Runnable() { // 使用之前定义的业务线程池执行任务
            @Override
            public void run() {
                // do invoke
                Object responseObj = process(httpMethod, uri, requestData, accessTokenReq);

                // to json
                String responseJson = GsonTool.toJson(responseObj);

                // write response
                writeResponse(ctx, keepAlive, responseJson);
            }
        });
    }

    private Object process(HttpMethod httpMethod, String uri, String requestData, String accessTokenReq) {

        // valid  方法类型校验与token校验
        if (HttpMethod.POST != httpMethod) {
            return new ReturnT<String>(ReturnT.FAIL_CODE, "invalid request, HttpMethod not support.");
        }
        if (uri==null || uri.trim().length()==0) {
            return new ReturnT<String>(ReturnT.FAIL_CODE, "invalid request, uri-mapping empty.");
        }
        if (accessToken!=null
                && accessToken.trim().length()>0
                && !accessToken.equals(accessTokenReq)) {
            return new ReturnT<String>(ReturnT.FAIL_CODE, "The access token is wrong.");
        }

        // services mapping 对访问路径判断，进行不同的方法调用，执行业务逻辑
        try {
            if ("/beat".equals(uri)) {
                return executorBiz.beat();
            } else if ("/idleBeat".equals(uri)) {
                IdleBeatParam idleBeatParam = GsonTool.fromJson(requestData, IdleBeatParam.class);
                return executorBiz.idleBeat(idleBeatParam);
            } else if ("/run".equals(uri)) {
                TriggerParam triggerParam = GsonTool.fromJson(requestData, TriggerParam.class);
                return executorBiz.run(triggerParam);
            } else if ("/kill".equals(uri)) {
                KillParam killParam = GsonTool.fromJson(requestData, KillParam.class);
                return executorBiz.kill(killParam);
            } else if ("/log".equals(uri)) {
                LogParam logParam = GsonTool.fromJson(requestData, LogParam.class);
                return executorBiz.log(logParam);
            } else {
                return new ReturnT<String>(ReturnT.FAIL_CODE, "invalid request, uri-mapping("+ uri +") not found.");
            }
        } catch (Exception e) {
            logger.error(e.getMessage(), e);
            return new ReturnT<String>(ReturnT.FAIL_CODE, "request error:" + ThrowableUtil.toString(e));
        }
    }

    /**
     * write response
     */
    private void writeResponse(ChannelHandlerContext ctx, boolean keepAlive, String responseJson) {
        // write response
        FullHttpResponse response = new DefaultFullHttpResponse(HttpVersion.HTTP_1_1, HttpResponseStatus.OK, Unpooled.copiedBuffer(responseJson, CharsetUtil.UTF_8));   //  Unpooled.wrappedBuffer(responseJson)
        response.headers().set(HttpHeaderNames.CONTENT_TYPE, "text/html;charset=UTF-8");       // HttpHeaderValues.TEXT_PLAIN.toString()
        response.headers().set(HttpHeaderNames.CONTENT_LENGTH, response.content().readableBytes());
        if (keepAlive) {
            response.headers().set(HttpHeaderNames.CONNECTION, HttpHeaderValues.KEEP_ALIVE);
        }
        ctx.writeAndFlush(response);
    }

    @Override
    public void channelReadComplete(ChannelHandlerContext ctx) throws Exception {
        ctx.flush();
    }

    @Override
    public void exceptionCaught(ChannelHandlerContext ctx, Throwable cause) {
        logger.error(">>>>>>>>>>> xxl-job provider netty_http server caught exception", cause);
        ctx.close();
    }

    @Override
    public void userEventTriggered(ChannelHandlerContext ctx, Object evt) throws Exception {
        if (evt instanceof IdleStateEvent) {
            ctx.channel().close();      // beat 3N, close if idle
            logger.debug(">>>>>>>>>>> xxl-job provider netty_http server close an idle channel.");
        } else {
            super.userEventTriggered(ctx, evt);
        }
    }
}
```

这里我们只看稍微复杂的run方法。

ExecutorBizImpl.run()

```java
// ExecutorBizImpl.java
@Override
public ReturnT<String> run(TriggerParam triggerParam) {
    // load old：jobHandler + jobThread
    JobThread jobThread = XxlJobExecutor.loadJobThread(triggerParam.getJobId()); // 获取任务所对应线程，这里能够看出，一个类型的任务对应一个执行线程
    IJobHandler jobHandler = jobThread!=null?jobThread.getHandler():null;
    String removeOldReason = null;

    // valid：jobHandler + jobThread
    GlueTypeEnum glueTypeEnum = GlueTypeEnum.match(triggerParam.getGlueType());
    if (GlueTypeEnum.BEAN == glueTypeEnum) { // Bean 模式的处理，找到业务系统自定义的 jobHandler Bean

        // new jobhandler
        IJobHandler newJobHandler = XxlJobExecutor.loadJobHandler(triggerParam.getExecutorHandler());

        // valid old jobThread
        if (jobThread!=null && jobHandler != newJobHandler) {
            // change handler, need kill old thread
            removeOldReason = "change jobhandler or glue type, and terminate the old job thread.";

            jobThread = null;
            jobHandler = null;
        }

        // valid handler
        if (jobHandler == null) {
            jobHandler = newJobHandler;
            if (jobHandler == null) {
                return new ReturnT<String>(ReturnT.FAIL_CODE, "job handler [" + triggerParam.getExecutorHandler() + "] not found.");
            }
        }

    } else if (GlueTypeEnum.GLUE_GROOVY == glueTypeEnum) { // Java 动态加载模式

        // valid old jobThread
        if (jobThread != null &&
                !(jobThread.getHandler() instanceof GlueJobHandler
                    && ((GlueJobHandler) jobThread.getHandler()).getGlueUpdatetime()==triggerParam.getGlueUpdatetime() )) {
            // change handler or gluesource updated, need kill old thread
            removeOldReason = "change job source or glue type, and terminate the old job thread.";

            jobThread = null;
            jobHandler = null;
        }

        // valid handler
        if (jobHandler == null) {
            try {
                IJobHandler originJobHandler = GlueFactory.getInstance().loadNewInstance(triggerParam.getGlueSource());
                jobHandler = new GlueJobHandler(originJobHandler, triggerParam.getGlueUpdatetime());
            } catch (Exception e) {
                logger.error(e.getMessage(), e);
                return new ReturnT<String>(ReturnT.FAIL_CODE, e.getMessage());
            }
        }
    } else if (glueTypeEnum!=null && glueTypeEnum.isScript()) { // 脚本语言的执行，判断是否是脚本代码

        // valid old jobThread
        if (jobThread != null &&
                !(jobThread.getHandler() instanceof ScriptJobHandler
                        && ((ScriptJobHandler) jobThread.getHandler()).getGlueUpdatetime()==triggerParam.getGlueUpdatetime() )) {
            // change script or gluesource updated, need kill old thread
            removeOldReason = "change job source or glue type, and terminate the old job thread.";

            jobThread = null;
            jobHandler = null;
        }

        // valid handler
        if (jobHandler == null) { // 生成了一个ScriptJobHandler对象
            jobHandler = new ScriptJobHandler(triggerParam.getJobId(), triggerParam.getGlueUpdatetime(), triggerParam.getGlueSource(), GlueTypeEnum.match(triggerParam.getGlueType()));
        }
    } else {
        return new ReturnT<String>(ReturnT.FAIL_CODE, "glueType[" + triggerParam.getGlueType() + "] is not valid.");
    }

    // executor block strategy   对于已在执行的同一类型任务，选择丢弃最后的还是覆盖前一个，还是并行处理
    if (jobThread != null) {
        ExecutorBlockStrategyEnum blockStrategy = ExecutorBlockStrategyEnum.match(triggerParam.getExecutorBlockStrategy(), null);
        if (ExecutorBlockStrategyEnum.DISCARD_LATER == blockStrategy) { // 丢弃最后的
            // discard when running
            if (jobThread.isRunningOrHasQueue()) {
                return new ReturnT<String>(ReturnT.FAIL_CODE, "block strategy effect："+ExecutorBlockStrategyEnum.DISCARD_LATER.getTitle());
            }
        } else if (ExecutorBlockStrategyEnum.COVER_EARLY == blockStrategy) { // 覆盖前一个
            // kill running jobThread
            if (jobThread.isRunningOrHasQueue()) {
                removeOldReason = "block strategy effect：" + ExecutorBlockStrategyEnum.COVER_EARLY.getTitle();

                jobThread = null;
            }
        } else {
            // just queue trigger
        }
    }

    // replace thread (new or exists invalid)
    if (jobThread == null) { // 注册并启动执行线程进行任务执行
        jobThread = XxlJobExecutor.registJobThread(triggerParam.getJobId(), jobHandler, removeOldReason);
    }

    // push data to queue  将结果放入全局变量triggerQueue中，表示正在被运行
    ReturnT<String> pushResult = jobThread.pushTriggerQueue(triggerParam);
    return pushResult;
}
```

```java
public class JobThread extends Thread{
	private static Logger logger = LoggerFactory.getLogger(JobThread.class);

	private int jobId;
	private IJobHandler handler;
	private LinkedBlockingQueue<TriggerParam> triggerQueue;
	private Set<Long> triggerLogIdSet;		// avoid repeat trigger for the same TRIGGER_LOG_ID

	private volatile boolean toStop = false;
	private String stopReason;

    private boolean running = false;    // if running job
	private int idleTimes = 0;			// idel times


	public JobThread(int jobId, IJobHandler handler) {
		this.jobId = jobId;
		this.handler = handler;
		this.triggerQueue = new LinkedBlockingQueue<TriggerParam>();
		this.triggerLogIdSet = Collections.synchronizedSet(new HashSet<Long>());

		// assign job thread name
		this.setName("xxl-job, JobThread-"+jobId+"-"+System.currentTimeMillis());
	}
	public IJobHandler getHandler() {
		return handler;
	}

    /**
     * new trigger to queue
     *
     * @param triggerParam
     * @return
     */
	public ReturnT<String> pushTriggerQueue(TriggerParam triggerParam) {
		// avoid repeat
		if (triggerLogIdSet.contains(triggerParam.getLogId())) {
			logger.info(">>>>>>>>>>> repeate trigger job, logId:{}", triggerParam.getLogId());
			return new ReturnT<String>(ReturnT.FAIL_CODE, "repeate trigger job, logId:" + triggerParam.getLogId());
		}

		triggerLogIdSet.add(triggerParam.getLogId());
		triggerQueue.add(triggerParam);
        return ReturnT.SUCCESS;
	}

    /**
     * kill job thread
     *
     * @param stopReason
     */
	public void toStop(String stopReason) {
		/**
		 * Thread.interrupt只支持终止线程的阻塞状态(wait、join、sleep)，
		 * 在阻塞出抛出InterruptedException异常,但是并不会终止运行的线程本身；
		 * 所以需要注意，此处彻底销毁本线程，需要通过共享变量方式；
		 */
		this.toStop = true;
		this.stopReason = stopReason;
	}

    /**
     * is running job
     * @return
     */
    public boolean isRunningOrHasQueue() {
        return running || triggerQueue.size()>0;
    }

    @Override
	public void run() {

    	// init
    	try {
			handler.init(); // 先调用handler.init()
		} catch (Throwable e) {
    		logger.error(e.getMessage(), e);
		}

		// execute
		while(!toStop){ // 用一个标记为进行判断
			running = false;
			idleTimes++; // 首先将空闲次数 idleTimes 自增， 标记当前又一次没有获取到任务进行空转

            TriggerParam triggerParam = null;
            try {
				// to check toStop signal, we need cycle, so wo cannot use queue.take(), instand of poll(timeout)
				triggerParam = triggerQueue.poll(3L, TimeUnit.SECONDS); // 从triggerQueue 阻塞队列获取任务， 并且一次周期最长等待时间是3s
				if (triggerParam!=null) {
					running = true;
					idleTimes = 0; // 如果获取到任务， 将idleTimes 清零
					triggerLogIdSet.remove(triggerParam.getLogId());

					// log filename, like "logPath/yyyy-MM-dd/9999.log"
					String logFileName = XxlJobFileAppender.makeLogFileName(new Date(triggerParam.getLogDateTime()), triggerParam.getLogId());
					XxlJobContext xxlJobContext = new XxlJobContext(
							triggerParam.getJobId(),
							triggerParam.getExecutorParams(),
							logFileName,
							triggerParam.getBroadcastIndex(),
							triggerParam.getBroadcastTotal());

					// init job context 构造一些参数信息，然后缓存到ThreadLocal 中
					XxlJobContext.setXxlJobContext(xxlJobContext);

					// execute
					XxlJobHelper.log("<br>----------- xxl-job job execute start -----------<br>----------- Param:" + xxlJobContext.getJobParam());

					if (triggerParam.getExecutorTimeout() > 0) {
						// limit timeout
						Thread futureThread = null;
						try {
							FutureTask<Boolean> futureTask = new FutureTask<Boolean>(new Callable<Boolean>() {
								@Override
								public Boolean call() throws Exception {

									// init job context
									XxlJobContext.setXxlJobContext(xxlJobContext);

									handler.execute();
									return true;
								}
							});
							futureThread = new Thread(futureTask);
							futureThread.start();

							Boolean tempResult = futureTask.get(triggerParam.getExecutorTimeout(), TimeUnit.SECONDS);
						} catch (TimeoutException e) {

							XxlJobHelper.log("<br>----------- xxl-job job execute timeout");
							XxlJobHelper.log(e);

							// handle result
							XxlJobHelper.handleTimeout("job execute timeout ");
						} finally {
							futureThread.interrupt();
						}
					} else {
						// just execute   调用 handler.execute(); 进行任务的执行
						handler.execute();
					}

					// valid execute handle data
					if (XxlJobContext.getXxlJobContext().getHandleCode() <= 0) {
						XxlJobHelper.handleFail("job handle result lost.");
					} else {
						String tempHandleMsg = XxlJobContext.getXxlJobContext().getHandleMsg();
						tempHandleMsg = (tempHandleMsg!=null&&tempHandleMsg.length()>50000)
								?tempHandleMsg.substring(0, 50000).concat("...")
								:tempHandleMsg;
						XxlJobContext.getXxlJobContext().setHandleMsg(tempHandleMsg);
					}
					XxlJobHelper.log("<br>----------- xxl-job job execute end(finish) -----------<br>----------- Result: handleCode="
							+ XxlJobContext.getXxlJobContext().getHandleCode()
							+ ", handleMsg = "
							+ XxlJobContext.getXxlJobContext().getHandleMsg()
					);

				} else {
					if (idleTimes > 30) { // 如果获取不到，则判断空闲次数是否到达30 次，如果到达 30 次。则调用 com.xxl.job.core.executor.XxlJobExecutor#removeJobThread 移除该线程。 会将 toStop 标记为置为true，然后线程正常结束后销毁。
						if(triggerQueue.size() == 0) {	// avoid concurrent trigger causes jobId-lost
							XxlJobExecutor.removeJobThread(jobId, "excutor idel times over limit.");
						}
					}
				}
			} catch (Throwable e) {
				if (toStop) {
					XxlJobHelper.log("<br>----------- JobThread toStop, stopReason:" + stopReason);
				}

				// handle result
				StringWriter stringWriter = new StringWriter();
				e.printStackTrace(new PrintWriter(stringWriter));
				String errorMsg = stringWriter.toString();

				XxlJobHelper.handleFail(errorMsg);

				XxlJobHelper.log("<br>----------- JobThread Exception:" + errorMsg + "<br>----------- xxl-job job execute end(error) -----------");
			} finally {
                if(triggerParam != null) {
                    // callback handler info
                    if (!toStop) {
                        // commonm
                        TriggerCallbackThread.pushCallBack(new HandleCallbackParam(
                        		triggerParam.getLogId(),
								triggerParam.getLogDateTime(),
								XxlJobContext.getXxlJobContext().getHandleCode(),
								XxlJobContext.getXxlJobContext().getHandleMsg() )
						);
                    } else {
                        // is killed
                        TriggerCallbackThread.pushCallBack(new HandleCallbackParam(
                        		triggerParam.getLogId(),
								triggerParam.getLogDateTime(),
								XxlJobContext.HANDLE_CODE_FAIL,
								stopReason + " [job running, killed]" )
						);
                    }
                }
            }
        }

		// callback trigger request in queue
		while(triggerQueue !=null && triggerQueue.size()>0){
			TriggerParam triggerParam = triggerQueue.poll();
			if (triggerParam!=null) {
				// is killed
				TriggerCallbackThread.pushCallBack(new HandleCallbackParam(
						triggerParam.getLogId(),
						triggerParam.getLogDateTime(),
						XxlJobContext.HANDLE_CODE_FAIL,
						stopReason + " [job not executed, in the job queue, killed.]")
				);
			}
		}

		// destroy
		try {
			handler.destroy();
		} catch (Throwable e) {
			logger.error(e.getMessage(), e);
		}

		logger.info(">>>>>>>>>>> xxl-job JobThread stoped, hashCode:{}", Thread.currentThread());
	}
}
```

1. run 方法会先调用 handler.init()。

2. while 循环内部然后用一个标记为进行判断。
   1. 首先将空闲次数idleTimes 自增， 标记当前又一次没有获取到任务进行空转。
   2. 然后从triggerQueue 阻塞队列获取任务， 并且一次周期最长等待时间是3s
      1. 如果获取到任务， 将idleTimes 清零。然后构造一些参数信息，然后缓存到ThreadLocal 中。 然后调用handler.execute(); 进行任务的执行。 (如果是继承IJobHandler则直接调用execute 方法)； 如果是@XxlJob 注解的方式， 实则是生成了一个com.xxl.job.core.handler.impl.MethodJobHandler 反射进行调用。
      2. 如果获取不到， 则判断空闲次数是否到达30 次， 如果到达30 次。则调用 com.xxl.job.core.executor.XxlJobExecutor#removeJobThread 移除该线程。 会将toStop 标记为置为true，然后线程正常结束后销毁。

这里有几个注意点：

(1) init 方法是每次创建一个JobThread 都会调用

(2) 每个jobid 对应的任务都会开启一个线程。此线程允许 90s 内不执行任务， 如果超过 90s 线程会自动销毁。并且是每个 jobId对应 一个线程。

一个xxl-job 后台开启的异步定时线程如下：

![img](http://blog-1259650185.cosbj.myqcloud.com/img/202204/24/1650730825.png)



## 参考

[xxl-job源码阅读——（八）BIO，NIO与xxl-job的Reactor实现](https://mp.weixin.qq.com/s?__biz=MzU0MzQ1NTM4MQ==&mid=2247483867&idx=1&sn=cc47c70cacf285e66ab3024e6d628da9&chksm=fb0a6021cc7de937e6ef6f71cc5bdad3e644628e6c7ecddb687d93a0b0430c616dec3422b0de&scene=178&cur_album_id=2226684892866740226#rd)
