## 基础知识

**lsn**: 可以理解为数据库从创建以来产生的redo日志量，这个值越大，说明数据库的更新越多，也可以理解为更新的时刻。此外，每个数据页上也有一个lsn，表示最后被修改时的lsn，值越大表示越晚被修改。比如，数据页A的lsn为100，数据页B的lsn为200，checkpoint lsn为150，系统lsn为300，表示当前系统已经更新到300，小于150的数据页已经被刷到磁盘上，因此数据页A的最新数据一定在磁盘上，而数据页B则不一定，有可能还在内存中。

**redo日志**: 现代数据库都需要写redo日志，例如修改一条数据，首先写redo日志，然后再写数据。在写完redo日志后，就直接给客户端返回成功。这样虽然看过去多写了一次盘，但是由于把对磁盘的随机写入(写数据)转换成了顺序的写入(写redo日志)，性能有很大幅度的提高。当数据库挂了之后，通过扫描redo日志，就能找出那些没有刷盘的数据页(在崩溃之前可能数据页仅仅在内存中修改了，但是还没来得及写盘)，保证数据不丢。

**undo日志**: 数据库还提供类似撤销的功能，当你发现修改错一些数据时，可以使用rollback指令回滚之前的操作。这个功能需要undo日志来支持。此外，现代的关系型数据库为了提高并发(同一条记录，不同线程的读取不冲突，读写和写读不冲突，只有同时写才冲突)，都实现了类似MVCC的机制，在InnoDB中，这个也依赖undo日志。为了实现统一的管理，与redo日志不同，undo日志在Buffer Pool中有对应的数据页，与普通的数据页一起管理，依据LRU规则也会被淘汰出内存，后续再从磁盘读取。与普通的数据页一样，对undo页的修改，也需要先写redo日志。

**检查点**: 英文名为checkpoint。数据库为了提高性能，数据页在内存修改后并不是每次都会刷到磁盘上。checkpoint之前的数据页保证一定落盘了，这样之前的日志就没有用了(由于InnoDB redolog日志循环使用，这时这部分日志就可以被覆盖)，checkpoint之后的数据页有可能落盘，也有可能没有落盘，所以checkpoint之后的日志在崩溃恢复的时候还是需要被使用的。InnoDB会依据脏页的刷新情况，定期推进checkpoint，从而减少数据库崩溃恢复的时间。检查点的信息在第一个日志文件的头部。

**崩溃恢复**: 用户修改了数据，并且收到了成功的消息，然而对数据库来说，可能这个时候修改后的数据还没有落盘，如果这时候数据库挂了，重启后，数据库需要从日志中把这些修改后的数据给捞出来，重新写入磁盘，保证用户的数据不丢。这个从日志中捞数据的过程就是崩溃恢复的主要任务，也可以成为数据库前滚。当然，在崩溃恢复中还需要回滚没有提交的事务，提交没有提交成功的事务。由于回滚操作需要undo日志的支持，undo日志的完整性和可靠性需要redo日志来保证，所以崩溃恢复先做redo前滚，然后做undo回滚。

## 1. binlog 位点刷新策略

### 1.1 背景

MySQL 非 GTID 协议主备同步原理： 主库在执行 SQL 语句时产生binlog，在事务 commit 时将产生的binlog event写入binlog文件，备库IO线程通过 `com_binlog_dump` 用文件位置协议从主库拉取 binlog，将拉取的binlog存储到relaylog， SQL线程读取 relaylog 然后进行 apply，实现主备同步，在这个过程中有以下几个问题：

1. 主库什么时间将产生的 binlog 真正刷到文件中？
2. 备库IO线程从哪个位置读取主库的 binlog event 的？
3. 备库SQL线程如何记录执行到的 relaylog 的位点？
4. 备库IO线程何时将cache中的event 刷到relay log 文件中的?

### 1.2 问题分析

下面对这几个问题挨个解答。

**问题 1: 主库什么时间将产生的binlog 真正刷到文件中**

事务`ordered_commit` 中，会将 `thd->cache_mngr` 中的 binlog cache 写入到 binlog 文件中，但并没有执行fsync()操作，即只将文件内容写入到 OS 缓存中，详细 bt 为：

```
#0  my_write
#1  0x0000000000a92f50 in inline_mysql_file_write
#2  0x0000000000a9612e in my_b_flush_io_cache
#3  0x0000000000a43466 in MYSQL_BIN_LOG::flush_cache_to_file
#4  0x0000000000a43a4d in MYSQL_BIN_LOG::ordered_commit
#5  0x0000000000a429f2 in MYSQL_BIN_LOG::commit
#6  0x000000000063d3e2 in ha_commit_trans
#7  0x00000000008adb7a in trans_commit_stmt
#8  0x00000000007e511f in mysql_execute_command
#9  0x00000000007e7e0e in mysql_parse
#10 0x00000000007dae0e in dispatch_command
#11 0x00000000007d9634 in do_command
#12 0x00000000007a046d in do_handle_one_connection
#13 0x000000000079ff75 in handle_one_connection
#14 0x0000003a00a07851 in start_thread ()
#15 0x0000003a006e767d in clone ()
```

commit 时，会判断是否将产生的 binlog flush 到文件中，即执行 fsync操作，详细bt 为：

```
#0  MYSQL_BIN_LOG::sync_binlog_file
#1  0x0000000000a43c62 in MYSQL_BIN_LOG::ordered_commit
#2  0x0000000000a429f2 in MYSQL_BIN_LOG::commit
#3  0x000000000063d3e2 in ha_commit_trans
#4  0x00000000008adb7a in trans_commit_stmt
#5  0x00000000007e511f in mysql_execute_command
#6  0x00000000007e7e0e in mysql_parse
#7  0x00000000007dae0e in dispatch_command
#8  0x00000000007d9634 in do_command (thd=0x37a40160)
#9  0x00000000007a046d in do_handle_one_connection
#10 0x000000000079ff75 in handle_one_connection
#11 0x0000003a00a07851 in start_thread ()
#12 0x0000003a006e767d in clone ()
```

由 `MYSQL_BIN_LOG::sync_binlog_file` 可以看出，每提交一个事务，会 fsync 一次binlog file。 当 sync_binlog != 1 的时候，每次事务提交的时候，不一定会执行 fsync 操作，binlog 的内容只是缓存在了 OS（是否会执行fsync操作，取决于OS缓存的大小），此时备库可以读到主库产生的 binlog， 在这种情况下，当主库机器挂掉时，有以下两种情况：

1. 主备同步无延迟，此时主库机器恢复后，备库接着之前的位点重新拉binlog, 但是主库由于没有fsync最后的binlog，所以会返回1236 的错误： `MySQL error code 1236 (ER_MASTER_FATAL_ERROR_READING_BINLOG): Got fatal error %d from master when reading data from binary log: '%-.256s'`
2. 备库没有读到主库失去的binlog，此时备库无法同步主库最后的更新，备库不可用。

**问题 2: 备库IO线程从哪个位置读取主库的binlog event 的**

更新位点信息的 bt 如下：

```
#0  Rpl_info_table::do_flush_info (this=0x379cbf90, force=false)
#1  0x0000000000a78270 in Rpl_info_handler::flush_info
#2  0x0000000000a773b9 in Master_info::flush_info
#3  0x0000000000a5da4b in flush_master_info
#4  0x0000000000a697eb in handle_slave_io
#5  0x0000003a00a07851 in start_thread () from /lib64/libpthread.so.0
#6  0x0000003a006e767d in clone () from /lib64/libc.so.6
```

备库通过 `master_log_info` 来记录主库的相关信息，通过参数 `sync_master_info` 来设置备库经过多少个 binlog event 来更新已经读取到的位点信息。当stop slave时，会把正常的位点更新到`master_log_info`中，此时，如果最后的位点不是commit，则在start slave后，会继续上一位点拉取 binlog，从而造成同一个事务的binlog event分布在不同的binlog file中，此时如果执行顺利则不会有问题；如果在拉这个事务的过程中，sql 线程出错中断，在并行复制下会引起分发线程停在事务中间，再次启动的时候，会从上一次分发的事务继续分发，会造成在并行复制中不可分发的情况，因此需要注意。

当 sync_master_info > 1000时，可能在第1000个binlog 拉取的时候机器出问题，此时重启后会从主库多拉999个 binlog event，造成事务在备库多次执行问题，对于没有 primary key, unique key 可能会有问题，造成主备数据不一致，最常遇到的是1062问题。

**问题3: 备库SQL线程如何记录执行到的relaylog 的位点**

同问题2一样，相关的 bt 也类似，`relay_log_info` 记录的是备库已经执行了的最后的位点，这个位点不会处于事务中间，即是每 `sync_relay_log_info` 个事务更新一下这个位点。

**问题 4: 备库IO线程何时将cache中的event 刷到relay log 文件中的**

这个问题的解答和问题1类似，也是以binlog event为单位的，当然也存在着和问题1中同样的问题，在此不在赘述。	

### 1.3 结语

MySQL 通过 `sync_binlog`，`sync_master_info`，`sync_relay_log_info`，`sync_relay_log` 来记录相关的位点信息，出于性能考虑以及程序本身的健壮性，引入了各式要样的bug，类似的bug在此不在列举，那么有没有更好的方法来记录这些信息呢，当然有，即GTID 协议，会在下期月报分析。



## 2. binlog拉取速度的控制

### 2.1 binlog拉取存在的问题

MySQL 主备之间数据同步是通过binlog进行的，当主库更新产生binlog时，备库需要同步主库的数据，通过binlog协议从主库拉取binlog进行数据同步，以达到主备数据一致性的目的。但当主库tps较高时会产生大量的binlog，以致备库拉取主库产生的binlog时占用较多的网络带宽，引起以下问题：

1. 在MySQL中，写入与读取binlog使用的是同一把锁(Lock_log)，频繁的读取binlog，会加剧Lock_log冲突，影响主库执行，进而造成TPS降低或抖动；
2. 当备库数量较多时，备库拉取binlog会占用过多的带宽，影响应用的响应时间。

为了解决上面提到的问题，需要对binlog的拉取速度进行限制。

### 2.2 问题存在的原因

备库或应用通过binlog协议向主库发送消息，告诉主库要拉取binlog，主库经过权限认证后，以binlog_event为单位读取在本地的binlog，然后将这些binlog_event发送给应用，其过程简单描述如下：

1. 从mysql-bin.index中找到用户消息中的指定文件，如果没有指定要拉取的binlog文件名称，则用第一个；
2. 上Lock_log锁，从1)或4) 中的binlog file中读取一个binlog_event，释放Lock_log锁，判断binlog_event的类型；
3. 如果是普通binlog_event，则将binlog_event发送到net 缓冲区；
4. 如果是Rotate_log_event，则取出要Rotate到的文件，执行2)；
5. 如果当前读的文件是最后一个文件且已经读到了文件的结尾，则会释放Lock_log锁，并等待新的Log_event信号。

从以上过程可以看出，binlog的发送速度和IO、网络有很大的关系，只要这三者不受限制，程序会就尽力发送binlog而没有限制。

### 2.3 解决问题的方法

由3、4可以看出，程序在读取和发送之间是没有其它工作的，如果IO很强，读取的速度很快，那么binlog的发送速度就会很快且不受限制，进而造成本文开始所描述的问题；针对binlog发送速度的问题，rds_mysql 通过设置binlog发送线程的发送频率、休眠时间来调整binlog的发送速度，因此 rds_mysql 引入了两个新的参数：

1. binlog_send_idle_period binlog发送线程的每次休眠时间，单位微秒，默认值100；
2. binlog_send_limit_users binlog发送线程的速度配置，默认值”“。

举例如下： set global binlog_send_limit_users=”rep1:3,rep2:10” 的作用是设置rep1拉取binlog的上限速度是3M/s, rep2拉取binlog的上限速度是10M/s，其中rep2、rep2指的是应用连接的用户名，对于binlog的拉取速度控制主要分为两个方面：

#### 2.3.1 binlog 发送速度监控线程

速度监控线程随着mysqld的启动而启动，用于定时扫描限速列表，计算列表中的每一个binlog dump线程的binlog发送速度，并根据计算的速度调整binlog的发送频率，其工作过程描述如下：

0. 速度监控线程随着mysqld的启动而启动，并初始化限速列表；

1. 对限速列表进行依次扫描，如果取到的线程不为空，转2);
2. 计算当前线程的发送速度，与用户设定的速度进行比较，大于设定的发送速度，转3)，如果小于用户设定的发送速度，则转4)
3. 通过调整当前线程的net_thread_frequency 成员，降低发送频率；
4. 通过调整当前线程的net_thread_frequency 成员，增加发送频率；
5. 遍历完限速列表后让出CPU 1毫秒，转1)

由以上描述可以看出，监控线程每毫秒执行一次，根据发送的字节数来计算binlog发送线程的发送速度是否超过设定的速度，并通过调整发送频率来调整binlog的发送速度，监控线程的限速列表是这样构造的：

1. binlog dump 线程在拉取binlog前会先根据连接的用户名判断是否应该对该用户限速，如果需要限速，则需要将当前dump线程加入限速列表；
2. 当binlog dump结束或断开连接时，从限速列表移除；
3. 当设置参数binlog_send_limit_users时，会对当前所有线程进行遍历，将被限制的用户加入限速列表，对不受限制的用户移出限制列表，所有受影响的线程不需要重新连接，可以实时生效。

#### 2.3.3 binlog dump 线程

dump 线程用于发送binlog，在发送过程中会根据监控线程设置的发送频率来调整binlog发送的速度，可以分为以下几步：

1. binlog dump 线程在拉取binlog前会先根据连接的用户名判断是否将本用户的线程加入限速列表；
2. 读取binlog，并查看是否需要休眠，需要休眠转3)，否则转4)；
3. 休眠binlog_send_idle_period；
4. 发送读取到的binlog event，转2。

因此可以通过设置binlog的发送频率及休眠时间精确调整binlog的发送速度。



## 3. MySQL权限存储与管理

### 3.1 权限相关的表

**系统表**

MySQL用户权限信息都存储在以下系统表中，用户权限的创建、修改和回收都会同步更新到系统表中。

```mysql
mysql.user            // 用户信息
mysql.db              // 库上的权限信息
mysql.tables_priv     // 表级别权限信息
mysql.columns_priv    // 列级别权限信息
mysql.procs_priv      // 存储过程和存储函数的权限信息
mysql.proxies_priv    // MySQL proxy权限信息，这里不讨论
```

> mysql.db存储是库的权限信息，不是存储实例有哪些库。MySQL查看实例有哪些数据库是通过在数据目录下查找有哪些目录文件得到的。

**information_schema表** 

information_schema下有以下权限相关的表可供查询:

```mysql
USER_PRIVILEGES
SCHEMA_PRIVILEGES
TABLE_PRIVILEGES
COLUMN_PRIVILEGES
```

### 3.2 权限缓存

用户在连接数据库的过程中，为了加快权限的验证过程，系统表中的权限会缓存到内存中。 例如： mysql.user缓存在数组acl_users中, mysql.db缓存在数组acl_dbs中， mysql.tables_priv和mysql.columns_priv缓存在hash表column_priv_hash中， mysql.procs_priv缓存在hash表proc_priv_hash和func_priv_hash中。

另外acl_cache缓存db级别的权限信息。例如执行use db时，会尝试从acl_cache中查找并更新当前数据库权限（thd->security_ctx->db_access）。

**权限更新过程**

以grant select on test.t1为例:

1. 更新系统表mysql.user，mysql.db，mysql.tables_priv；
2. 更新缓存acl_users，acl_dbs，column_priv_hash；
3. 清空acl_cache。

### 3.3 FLUSH PRIVILEGES

FLUSH PRIVILEGES会重新从系统表中加载权限信息来构建缓存。

当我们通过SQL语句直接修改权限系统表来修改权限时，权限缓存是没有更新的，这样会导致权限缓存和系统表不一致。因此通过这种方式修改权限后，应执行FLUSH PRIVILEGES来刷新缓存，从而使更新的权限生效。

通过GRANT/REVOKE/CREATE USER/DROP USER来更新权限是不需要FLUSH PRIVILEGES的。

> 当前连接修改了权限信息时，现存的其他客户连接是不受影响的，权限在客户的下一次请求时生效。



## 4. InnoDB ACID

本小节针对ACID这四种数据库特性分别进行简单描述。

### 4.1 Atomicity （原子性）

所谓原子性，就是一个事务要么全部完成变更，要么全部失败。如果在执行过程中失败，回滚操作需要保证“好像”数据库从没执行过这个事务一样。

从用户的角度来看，用户发起一个COMMIT语句，要保证事务肯定成功完成了；若发起ROLLBACK语句，则干净的回滚掉事务所有的变更。 从内部实现的角度看，InnoDB对事务过程中的数据变更总是维持了undo log，若用户想要回滚事务，能够通过Undo追溯最老版本的方式，将数据全部回滚回来。若用户需要提交事务，则将提交日志刷到磁盘。

### 4.2 Consistency （一致性）

一致性指的是数据库需要总是保持一致的状态，即使实例崩溃了，也要能保证数据的一致性，包括内部数据存储的准确性，数据结构（例如btree）不被破坏。InnoDB通过double write buffer 和crash recovery实现了这一点：前者保证数据页的准确性，后者保证恢复时能够将所有的变更apply到数据页上。如果崩溃恢复时存在还未提交的事务，那么根据XA规则提交或者回滚事务。最终实例总能处于一致的状态。

另外一种一致性指的是数据之间的约束不应该被事务所改变，例如外键约束。MySQL支持自动检查外键约束，或是做级联操作来保证数据完整性，但另外也提供了选项`foreign_key_checks`，如果您关闭了这个选项，数据间的约束和一致性就会失效。有些情况下，数据的一致性还需要用户的业务逻辑来保证。

### 4.3 Isolation （隔离性）

隔离性是指多个事务不可以对相同数据同时做修改，事务查看的数据要么就是修改之前的数据，要么就是修改之后的数据。InnoDB支持四种隔离级别，如上文所述，这里不再重复。

### 4.4 Durability（持久性）

当一个事务完成了，它所做的变更应该持久化到磁盘上，永不丢失。这个特性除了和数据库系统相关外，还和你的硬件条件相关。InnoDB给出了许多选项，你可以为了追求性能而弱化持久性，也可以为了完全的持久性而弱化性能。

和大多数DBMS一样，InnoDB 也遵循WAL（Write-Ahead Logging）的原则，在写数据文件前，总是保证日志已经写到了磁盘上。通过Redo日志可以恢复出所有的数据页变更。

为了保证数据的正确性，Redo log和数据页都做了checksum校验，防止使用损坏的数据。目前5.7版本默认支持使用CRC32的数据校验算法。

为了解决半写的问题，即写一半数据页时实例crash，这时候数据页是损坏的。InnoDB使用double write buffer来解决这个问题，在写数据页到用户表空间之前，总是先持久化到double write buffer，这样即使没有完整写页，我们也可以从double write buffer中将其恢复出来。你可以通过innodb_doublewrite选项来开启或者关闭该特性。

InnoDB通过这种机制保证了数据和日志的准确性的。你可以将实例配置成事务提交时将redo日志fsync到磁盘（`innodb_flush_log_at_trx_commit = 1`），数据文件的FLUSH策略（`innodb_flush_method`）修改为0_DIRECT，以此来保证强持久化。你也可以选择更弱化的配置来保证实例的性能。



## 5. InnoDB 事务锁系统简介

### 5.1 前言

本文的目的是对 InnoDB 的事务锁模块做个简单的介绍，使读者对这块有初步的认识。本文先介绍行级锁和表级锁的相关概念，再介绍其内部的一些实现；最后以两个有趣的案例结束本文。

本文所有的代码和示例都是基于当前最新的 MySQL5.7.10 版本。

### 5.2 行级锁

InnoDB 支持到行级别粒度的并发控制，本小节我们分析下几种常见的行级锁类型，以及在哪些情况下会使用到这些类型的锁。

**LOCK_REC_NOT_GAP**

锁带上这个 FLAG 时，表示这个锁对象只是单纯的锁在记录上，不会锁记录之前的 GAP。在 RC 隔离级别下一般加的都是该类型的记录锁（但唯一二级索引上的 duplicate key 检查除外，总是加 `LOCK_ORDINARY` 类型的锁）。

**LOCK_GAP**

表示只锁住一段范围，不锁记录本身，通常表示两个索引记录之间，或者索引上的第一条记录之前，或者最后一条记录之后的锁。可以理解为一种区间锁，一般在RR隔离级别下会使用到GAP锁。

你可以通过切换到RC隔离级别，或者开启选项`innodb_locks_unsafe_for_binlog`来避免GAP锁。这时候只有在检查外键约束或者duplicate key检查时才会使用到GAP LOCK。

**LOCK_ORDINARY(Next-Key Lock)**

也就是所谓的 NEXT-KEY 锁，包含记录本身及记录之前的GAP。当前 MySQL 默认情况下使用RR的隔离级别，而NEXT-KEY LOCK正是为了解决RR隔离级别下的幻读问题。所谓幻读就是一个事务内执行相同的查询，会看到不同的行记录。在RR隔离级别下这是不允许的。

假设索引上有记录1, 4, 5, 8，12 我们执行类似语句：SELECT… WHERE col > 10 FOR UPDATE。如果我们不在(8, 12)之间加上Gap锁，另外一个 Session 就可能向其中插入一条记录，例如9，再执行一次相同的SELECT FOR UPDATE，就会看到新插入的记录。

**LOCK_S（共享锁）**

共享锁的作用通常用于在事务中读取一条行记录后，不希望它被别的事务锁修改，但所有的读请求产生的LOCK_S锁是不冲突的。在InnoDB里有如下几种情况会请求S锁。

1. 普通查询在隔离级别为 SERIALIZABLE 会给记录加 LOCK_S 锁。但这也取决于场景：非事务读（auto-commit）在 SERIALIZABLE 隔离级别下，无需加锁(不过在当前最新的5.7.10版本中，SHOW ENGINE INNODB STATUS 的输出中不会打印只读事务的信息，只能从`informationschema.innodb_trx`表中获取到该只读事务持有的锁个数等信息)。

2. 类似 SQL SELECT … IN SHARE MODE，会给记录加S锁，其他线程可以并发查询，但不能修改。基于不同的隔离级别，行为有所不同:

   - RC隔离级别： `LOCK_REC_NOT_GAP | LOCK_S`；
   - RR隔离级别：如果查询条件为唯一索引且是唯一等值查询时，加的是 `LOCK_REC_NOT_GAP | LOCK_S`；对于非唯一条件查询，或者查询会扫描到多条记录时，加的是`LOCK_ORDINARY | LOCK_S`锁，也就是记录本身+记录之前的GAP；

3. 通常INSERT操作是不加锁的，但如果在插入或更新记录时，检查到 duplicate key（或者有一个被标记删除的duplicate key），对于普通的INSERT/UPDATE，会加LOCK_S锁，而对于类似REPLACE INTO或者INSERT … ON DUPLICATE这样的SQL加的是X锁。而针对不同的索引类型也有所不同：

   - 对于聚集索引（参阅函数`row_ins_duplicate_error_in_clust`），隔离级别小于等于RC时，加的是`LOCK_REC_NOT_GAP`类似的S或者X记录锁。否则加`LOCK_ORDINARY`类型的记录锁（NEXT-KEY LOCK）；
   - 对于二级唯一索引，若检查到重复键，当前版本总是加 LOCK_ORDINARY 类型的记录锁(函数 `row_ins_scan_sec_index_for_duplicate`)。实际上按照RC的设计理念，不应该加GAP锁（[bug#68021](http://bugs.mysql.com/bug.php?id=68021)），官方也事实上尝试修复过一次，即对于RC隔离级别加上`LOCK_REC_NOT_GAP`，但却引入了另外一个问题，导致二级索引的唯一约束失效([bug#73170](http://bugs.mysql.com/bug.php?id=73170))，感兴趣的可以参阅我写的[这篇博客](http://mysqllover.com/?p=1041)，由于这个严重bug，官方很快又把这个fix给revert掉了。

4. 外键检查

   当我们删除一条父表上的记录时，需要去检查是否有引用约束(`row_pd_check_references_constraints`)，这时候会扫描子表(`dict_table_t::referenced_list`)上对应的记录，并加上共享锁。按照实际情况又有所不同。我们举例说明

   使用RC隔离级别，两张测试表：

   ```sql
    create table t1 (a int, b int, primary key(a));
    create table t2 (a int, b int, primary key (a), key(b), foreign key(b) references t1(a));
    insert into t1 values (1,2), (2,3), (3,4), (4,5), (5,6), (7,8), (10,11);
    insert into t2 values (1,2), (2,2), (4,4);
   ```

   执行SQL：delete from t1 where a = 10;

   - 在t1表记录10上加 `LOCKREC_NOT_GAP|LOCK_X`
   - 在t2表的supremum记录（表示最大记录）上加 `LOCK_ORDINARY|LOCK_S`，即锁住(4, ~)区间

   执行SQL：delete from t1 where a = 2;

   - 在t1表记录(2,3)上加 `LOCK_REC_NOT_GAP|LOCK_X`
   - 在t2表记录(1,2)上加 `LOCK_REC_NOT_GAP|LOCK_S`锁，这里检查到有引用约束，因此无需继续扫描(2,2)就可以退出检查，判定报错。

   执行SQL：delete from t1 where a = 3;

   - 在t1表记录(3,4)上加 `LOCK_REC_NOT_GAP|LOCK_X`
   - 在t2表记录(4,4)上加 `LOCK_GAP|LOCK_S`锁

   另外从代码里还可以看到，如果扫描到的记录被标记删除时，也会加`LOCK_ORDINARY|LOCK_S` 锁。具体参阅函数`row_ins_check_foreign_constraint`

5. INSERT … SELECT插入数据时，会对SELECT的表上扫描到的数据加LOCK_S锁


**LOCK_X（排他锁）**

排他锁的目的主要是避免对同一条记录的并发修改。通常对于UPDATE或者DELETE操作，或者类似SELECT … FOR UPDATE操作，都会对记录加排他锁。

我们以如下表为例：

```sql
create table t1 (a int, b int, c int, primary key(a), key(b));
insert into t1 values (1,2,3), (2,3,4),(3,4,5), (4,5,6),(5,6,7);
```

执行SQL（通过二级索引查询）：update t1 set c = c +1 where b = 3;

- RC隔离级别：1. 锁住二级索引记录，为NOT GAP X锁；2.锁住对应的聚集索引记录，也是NOT GAP X锁。
- RR隔离级别下：1.锁住二级索引记录，为`LOCK_ORDINARY|LOCK_X`锁；2.锁住聚集索引记录，为NOT GAP X锁

执行SQL（通过聚集索引检索，更新二级索引数据）：update t1 set b = b +1 where a = 2;

- 对聚集索引记录加 `LOCK_REC_NOT_GAP | LOCK_X`锁;
- 在标记删除二级索引时，检查二级索引记录上的锁（`lock_sec_rec_modify_check_and_lock`），如果存在和`LOCK_X | LOCK_REC_NOT_GAP`冲突的锁对象，则创建锁对象并返回等待错误码；否则无需创建锁对象；
- 当到达这里时，我们已经持有了聚集索引上的排他锁，因此能保证别的线程不会来修改这条记录。（修改记录总是先聚集索引，再二级索引的顺序），即使不对二级索引加锁也没有关系。但如果已经有别的线程已经持有了二级索引上的记录锁，则需要等待。
- 在标记删除后，需要插入更新后的二级索引记录时，依然要遵循插入意向锁的加锁原则。

我们考虑上述两种 SQL 的混合场景，一个是先锁住二级索引记录，再锁聚集索引；另一个是先锁聚集索引，再检查二级索引冲突，因此在这类并发更新场景下，可能会发生死锁。

不同场景，不同隔离级别下的加锁行为都有所不同，例如在RC隔离级别下，不符合WHERE条件的扫描到的记录，会被立刻释放掉，但RR级别则会持续到事务结束。你可以通过GDB，断点函数`lock_rec_lock`来查看某条SQL如何执行加锁操作。

**LOCK_INSERT_INTENTION(插入意向锁)**

INSERT INTENTION锁是GAP锁的一种，如果有多个session插入同一个GAP时，他们无需互相等待，例如当前索引上有记录4和8，两个并发session同时插入记录6，7。他们会分别为(4,8)加上GAP锁，但相互之间并不冲突（因为插入的记录不冲突）。

当向某个数据页中插入一条记录时，总是会调用函数`lock_rec_insert_check_and_lock`进行锁检查（构建索引时的数据插入除外），会去检查当前插入位置的下一条记录上是否存在锁对象，这里的下一条记录不是指的物理连续，而是按照逻辑顺序的下一条记录。 如果下一条记录上不存在锁对象：若记录是二级索引上的，先更新二级索引页上的最大事务ID为当前事务的ID；直接返回成功。

如果下一条记录上存在锁对象，就需要判断该锁对象是否锁住了GAP。如果GAP被锁住了，并判定和插入意向GAP锁冲突，当前操作就需要等待，加的锁类型为`LOCK_X | LOCK_GAP | LOCK_INSERT_INTENTION`，并进入等待状态。但是插入意向锁之间并不互斥。这意味着在同一个GAP里可能有多个申请插入意向锁的会话。

**锁表更新**

我们知道GAP锁是在一个记录上描述的，表示记录及其之前的记录之间的GAP。但如果记录之前发生了插入或者删除操作，之前描述的GAP就会发生变化，InnoDB需要对锁表进行更新。

对于数据插入，假设我们当前在记录[3,9]之间有会话持有锁(不管是否和插入意向锁冲突)，现在插入一条新的记录5，需要调用函数`lock_update_insert`。这里会遍历所有在记录9上的记录锁，如果这些锁不是插入意向锁并且是LOCK_GAP或者NEXT-KEY LOCK（没有设置`LOCK_REC_NOT_GAP`标记)(`lock_rec_inherit_to_gap_if_gap_lock`)，就会为这些会话的事务增加一个新的锁对象，锁的类型为`LOCK_REC | LOCK_GAP`，锁住的GAP范围在本例中为(3,5)。所有符合条件的会话都继承了这个新的GAP，避免之前的GAP锁失效。

对于数据删除操作，调用函数`lock_update_delete`，这里会遍历在被删除记录上的记录锁，当符合如下条件时，需要为这些锁对应的事务增加一个新的GAP锁，锁的Heap No为被删除记录的下一条记录：

```cpp
lock_rec_inherit_to_gap
        for (lock = lock_rec_get_first(lock_sys->rec_hash, block, heap_no);
             lock != NULL;
             lock = lock_rec_get_next(heap_no, lock)) {

                if (!lock_rec_get_insert_intention(lock)
                    && !((srv_locks_unsafe_for_binlog
                          || lock->trx->isolation_level
                          <= TRX_ISO_READ_COMMITTED)
                         && lock_get_mode(lock) ==
                         (lock->trx->duplicates ? LOCK_S : LOCK_X))) {
                        lock_rec_add_to_queue(
                                LOCK_REC | LOCK_GAP | lock_get_mode(lock),
                                heir_block, heir_heap_no, lock->index,
                                lock->trx, FALSE);
                }
        }
```

从上述判断可以看出，即使在RC隔离级别下，也有可能继承LOCK GAP锁，这也是当前版本InnoDB唯一的意外：判断Duplicate key时目前容忍GAP锁。上面这段代码实际上在最近的版本中才做过更新，更早之前的版本可能存在二级索引损坏，感兴趣的可以阅读我的[这篇博客](http://mysqllover.com/?p=1477)

完成GAP锁继承后，会将所有等待该记录的锁对象全部唤醒(`lock_rec_reset_and_release_wait`)。

**LOCK_PREDICATE**

从 MySQL5.7 开始MySQL整合了`boost.geometry`库以更好的支持空间数据类型，并支持在在Spatial数据类型的列上构建索引，在InnoDB内，这个索引和普通的索引有所不同，基于R-TREE的结构，目前支持对2D数据的描述，暂不支持3D.

R-TREE和BTREE不同，它能够描述多维空间，而多维数据并没有明确的数据顺序，因此无法在RR隔离级别下构建NEXT-KEY锁以避免幻读，因此InnoDB使用称为Predicate Lock的锁模式来加锁，会锁住一块查询用到的被称为MBR(minimum boundingrectangle/box)的数据区域。 因此这个锁不是锁到某个具体的记录之上的，可以理解为一种Page级别的锁。

Predicate Lock和普通的记录锁或者表锁（如上所述）存储在不同的lock hash中，其相互之间不会产生冲突。

Predicate Lock相关代码见`lock/lock0prdt.cc`文件

关于Predicate Lock的设计参阅官方[WL#6609](http://dev.mysql.com/worklog/task/?id=6609)。

*由于这块的代码量比较庞大，目前小编对InnoDB的spatial实现了解有限，本文暂不对此展开，将在后面单独专门介绍spatial index时，再细细阐述这块内容。*

**隐式锁**

InnoDB 通常对插入操作无需加锁，而是通过一种“隐式锁”的方式来解决冲突。聚集索引记录中存储了事务id，如果另外有个session查询到了这条记录，会去判断该记录对应的事务id是否属于一个活跃的事务，并协助这个事务创建一个记录锁，然后将自己置于等待队列中。该设计的思路是基于大多数情况下新插入的记录不会立刻被别的线程并发修改，而创建锁的开销是比较昂贵的，涉及到全局资源的竞争。

关于隐式锁转换，上一期的月报[InnoDB 事务子系统介绍](http://mysql.taobao.org/monthly/2015/12/01/)我们已经介绍过了，这里不再赘述。

**锁的冲突判定**

锁模式的兼容性矩阵通过如下数组进行快速判定：

```cpp
static const byte lock_compatibility_matrix[5][5] = {
/** IS IX S X AI /
/ IS / { TRUE, TRUE, TRUE, FALSE, TRUE},
/ IX / { TRUE, TRUE, FALSE, FALSE, TRUE},
/ S / { TRUE, FALSE, TRUE, FALSE, FALSE},
/ X / { FALSE, FALSE, FALSE, FALSE, FALSE},
/ AI / { TRUE, TRUE, FALSE, FALSE, FALSE}
};
```

对于记录锁而言，锁模式只有LOCK_S 和LOCK_X，其他的 FLAG 用于锁的描述，如前述 LOCK_GAP、LOCK_REC_NOT_GAP 以及 LOCK_ORDINARY、LOCK_INSERT_INTENTION 四种描述。在比较两个锁是否冲突时，即使不满足兼容性矩阵，在如下几种情况下，依然认为是相容的，无需等待（参考函数`lock_rec_has_to_wait`）

- 对于GAP类型（锁对象建立在supremum上或者申请的锁类型为LOCK_GAP）且申请的不是插入意向锁时，无需等待任何锁，这是因为不同Session对于相同GAP可能申请不同类型的锁，而GAP锁本身设计为不互相冲突；
- LOCK_ORDINARY 或者LOCK_REC_NOT_GAP类型的锁对象，无需等待LOCK_GAP类型的锁；
- LOCK_GAP类型的锁无需等待LOCK_REC_NOT_GAP类型的锁对象；
- 任何锁请求都无需等待插入意向锁。

### 5.3 表级锁

InnoDB的表级别锁包含五种锁模式：LOCK_IS、LOCK_IX、LOCK_X、LOCK_S以及LOCK_AUTO_INC锁，锁之间的相容性遵循数组`lock_compatibility_matrix`中的定义。

InnoDB表级锁的目的是为了防止DDL和DML的并发问题。但从5.5版本开始引入MDL锁后，InnoDB层的表级锁的意义就没那么大了，MDL锁本身已经覆盖了其大部分功能。以下我们介绍下几种InnoDB表锁类型。

**LOCK_IS/LOCK_IX**

也就是所谓的意向锁，这实际上可以理解为一种“暗示”未来需要什么样行级锁，IS表示未来可能需要在这个表的某些记录上加共享锁，IX表示未来可能需要在这个表的某些记录上加排他锁。意向锁是表级别的，IS和IX锁之间相互并不冲突，但与表级S/X锁冲突。

在对记录加S锁或者X锁时，必须保证其在相同的表上有对应的意向锁或者锁强度更高的表级锁。

**LOCK_X**

当加了LOCK_X表级锁时，所有其他的表级锁请求都需要等待。通常有这么几种情况需要加X锁：

- DDL操作的最后一个阶段(`ha_innobase::commit_inlace_alter_table`)对表上加LOCK_X锁，以确保没有别的事务持有表级锁。通常情况下Server层MDL锁已经能保证这一点了，在DDL的commit 阶段是加了排他的MDL锁的。但诸如外键检查或者刚从崩溃恢复的事务正在进行某些操作，这些操作都是直接InnoDB自治的，不走server层，也就无法通过MDL所保护；
- 当设置会话的autocommit变量为OFF时，执行`LOCK TABLE tbname WRITE`这样的操作会加表级的LOCK_X锁(`ha_innobase::external_lock`)；
- 对某个表空间执行discard或者import操作时，需要加LOCK_X锁(`ha_innobase::discard_or_import_tablespace`)。

**LOCK_S**

- 在DDL的第一个阶段，如果当前DDL不能通过ONLINE的方式执行，则对表加LOCK_S锁(`prepare_inplace_alter_table_dict`)；
- 设置会话的autocommit为OFF，执行LOCK TABLE tbname READ时，会加LOCK_S锁(`ha_innobase::external_lock`)。

从上面的描述我们可以看到LOCK_X及LOCK_S锁在实际的大部分负载中都很少会遇到。主要还是互相不冲突的LOCK_IS及LOCK_IX锁。一个有趣的问题是，每次加表锁时，却总是要扫描表上所有的表级锁对象，检查是否有冲突的锁。很显然，如果我们在同一张表上的更新并发度很高，这个链表就会非常长。

基于大多数表锁不冲突的事实，我们在RDS MYSQL中对各种表锁对象进行计数，在检查是否有冲突时，例如当前申请的是意向锁，如果此时LOCK_S和LOCK_X的锁计数都是0，就可以认为没有冲突，直接忽略检查。由于检查是在持有全局大锁`lock_sys->mutex`下进行的。在单表大并发下，这个优化的效果还是非常明显的，可以减少持有全局大锁的时间。

**LOCK_AUTO_INC**

AUTO_INC锁加在表级别，和AUTO_INC、表级S锁以及X锁不相容。锁的范围为SQL级别，SQL结束后即释放。AUTO_INC的加锁逻辑和InnoDB的锁模式相关，这里在简单介绍一下。

通常对于自增列，我们既可以显式指定该值，也可以直接用NULL，系统将自动递增并填充该列。我们还可以在批量插入时混合使用者两种方式。不同的分配方式，其具体行为受到参数`innodb_autoinc_lock_mode`的影响。但在基于STATEMENT模式复制时，可能会影响到复制的数据一致性，[官方文档](http://dev.mysql.com/doc/refman/5.7/en/innodb-auto-increment-handling.html) 有详细描述，不再赘述，只说明下锁的影响。

自增锁模式通过参数`innodb_autoinc_lock_mode`来控制，加锁选择参阅函数`ha_innobase::innobase_lock_autoinc`

具体的，有以下几个值：

`AUTOINC_OLD_STYLE_LOCKING`（0）

也就是所谓的传统加锁模式（在5.1版本引入这个参数之前的策略），在该策略下，会在分配前加上AUTO_INC锁，并在SQL结束时释放掉。该模式保证了在STATEMENT复制模式下，备库执行类似INSERT … SELECT这样的语句时的一致性，因为这样的语句在执行时无法确定到底有多少条记录，只有在执行过程中不允许别的会话分配自增值，才能确保主备一致。

很显然这种锁模式非常影响并发插入的性能，但却保证了一条SQL内自增值分配的连续性。

`AUTOINC_NEW_STYLE_LOCKING`（1）

这是InnoDB的默认值。在该锁模式下

- 普通的 INSERT 或 REPLACE 操作会先加一个`dict_table_t::autoinc_mutex`，然后去判断表上是否有别的线程加了LOCK_AUTO_INC锁，如果有的话，释放autoinc_mutex，并使用OLD STYLE的锁模式。否则，在预留本次插入需要的自增值之后，就快速的将autoinc_mutex释放掉。很显然，对于普通的并发INSERT操作，都是无需加LOCK_AUTO_INC锁的。因此大大提升了吞吐量；
- 但是对于一些批量插入操作，例如LOAD DATA，INSERT …SELECT 等还是使用OLD STYLE的锁模式，SQL执行期间加LOCK_AUTO_INC锁。

和传统模式相比，这种锁模式也能保证STATEMENT模式下的复制安全性，但却无法保证一条插入语句内的自增值的连续性，并且在执行一条混合了显式指定自增值和使用系统分配两种方式的插入语句时，可能存在一定的自增值浪费。

例如执行SQL：

```sql
INSERT INTO t1 (c1,c2) VALUES (1,'a'), (NULL,'b'), (5,'c'), (NULL,’d’）
```

假设当前AUTO_INCREMENT值为101，在传统模式下执行完后，下一个自增值为103，而在新模式下，下一个可用的自增值为105，因为在开始执行SQL时，会先预取了[101, 104] 4个自增值，这和插入行的个数相匹配，然后将AUTO_INCREMENT设为105，导致自增值103和104被浪费掉。

`AUTOINC_NO_LOCKING`（2）

这种模式下只在分配时加个mutex即可，很快就释放，不会像NEW STYLE那样在某些场景下会退化到传统模式。因此设为2不能保证批量插入的复制安全性。

**关于自增锁的小BUG**

这是Mariadb的Jira上报的一个小bug，在row模式下，由于不走parse的逻辑，我们不知道行记录是通过什么批量导入还是普通INSERT产生的，因此command类型为SQLCOM_END，而在判断是否加自增锁时的逻辑时，是通过COMMAND类型是否为SQLCOM_INSERT或者SQLCOM_REPLACE来判断是否忽略加AUTO_INC锁。这个额外的锁开销，会导致在使用ROW模式时，InnoDB总是加AUTO_INC锁，加AUTO_INC锁又涉及到全局事务资源的开销，从而导致性能下降。

修复的方式也比较简单，将SQLCOM_END这个command类型也纳入考虑。

具体参阅[Jira链接](https://mariadb.atlassian.net/browse/MDEV-7578)。

### 5.4 两个有趣的案例

本小节我们来分析几个比较有趣的死锁案例。

**普通的并发插入导致的死锁**

create table t1 (a int primary key); 开启三个会话执行： insert into t1(a) values (2);

| session 1        | session 2                                   | session 3                     |
| :--------------- | :------------------------------------------ | :---------------------------- |
| BEGIN; INSERT..  |                                             |                               |
|                  | INSERT (block),为session1创建X锁，并等待S锁 |                               |
|                  |                                             | INSERT (block， 同上等待S锁)  |
| ROLLBACK，释放锁 |                                             |                               |
|                  | 获得S锁                                     | 获得S锁                       |
|                  | 申请插入意向X锁，等待session3               |                               |
|                  |                                             | 申请插入意向X锁，等待session2 |

上述描述了互相等待的场景，因为插入意向X锁和S锁是不相容的。这也是一种典型的锁升级导致的死锁。如果session1执行COMMIT的话，则另外两个线程都会因为duplicate key失败。

这里需要解释下为何要申请插入意向锁，因为ROLLBACK时原记录回滚时是被标记删除的。而我们尝试插入的记录和这个标记删除的记录是相邻的(键值相同)，根据插入意向锁的规则，插入位置的下一条记录上如果存在与插入意向X锁冲突的锁时，则需要获取插入意向X锁。

另外一种类似（但产生死锁的原因不同）的场景是在一张同时存在聚集索引和唯一索引的表上，通过replace into的方式插入冲突的唯一键，可能会产生死锁，在3月份的月报，我已经专门描述过这个问题，感兴趣的可以[延伸阅读下](http://mysql.taobao.org/index.php?title=MySQL内核月报_2015.03#MySQL_.C2.B7_.E7.AD.94.E7.96.91.E9.87.8A.E6.83.91.C2.B7_.E5.B9.B6.E5.8F.91Replace_into.E5.AF.BC.E8.87.B4.E7.9A.84.E6.AD.BB.E9.94.81.E5.88.86.E6.9E.90)。

**又一个并发插入的死锁现象**

两个会话参与。在RR隔离级别下

例表如下：

```sql
create table t1 (a int primary key ,b int);
insert into t1 values (1,2),(2,3),(3,4),(11,22);
```

| session 1                                                    | session 2                                                    |
| :----------------------------------------------------------- | :----------------------------------------------------------- |
| begin;select * from t1 where a = 5 for update;(获取记录(11,22)上的GAP X锁) |                                                              |
|                                                              | begin;select * from t1 where a = 5 for update; (同上,GAP锁之间不冲突 |
| insert into t1 values (4,5); (block，等待session1)           |                                                              |
|                                                              | insert into t1 values (4,5);（需要等待session2，死锁）       |

引起这个死锁的原因是非插入意向的GAP X锁和插入意向X锁之间是冲突的。



## 6. InnoDB 文件系统之文件物理结构

### 6.1 综述

从上层的角度来看，InnoDB层的文件，除了redo日志外，基本上具有相当统一的结构，都是固定block大小，普遍使用的btree结构来管理数据。只是针对不同的block的应用场景会分配不同的页类型。通常默认情况下，每个block的大小为 UNIV_PAGE_SIZE，在不做任何配置时值为16kb，你还可以选择在安装实例时指定一个块的block大小。对于压缩表，可以在建表时指定block size，但在内存中表现的解压页依旧为统一的页大小。

从物理文件的分类来看，有日志文件、主系统表空间文件ibdata、undo tablespace文件、临时表空间文件、用户表空间。

日志文件主要用于记录redo log，InnoDB采用循环使用的方式，你可以通过参数指定创建文件的个数和每个文件的大小。默认情况下，日志是以512字节的block单位写入。由于现代文件系统的block size通常设置到4k，InnoDB提供了一个选项，可以让用户将写入的redo日志填充到4KB，以避免read-modify-write的现象；而Percona Server则提供了另外一个选项，支持直接将redo日志的block size修改成指定的值。

ibdata是InnoDB最重要的系统表空间文件，它记录了InnoDB的核心信息，包括事务系统信息、元数据信息，记录InnoDB change buffer的btree，防止数据损坏的double write buffer等等关键信息。我们稍后会展开描述。

undo独立表空间是一个可选项，通常默认情况下，undo数据是存储在ibdata中的，但你也可以通过配置选项 `innodb_undo_tablespaces` 来将undo 回滚段分配到不同的文件中，目前开启undo tablespace 只能在install阶段进行。在主流版本进入5.7时代后，我们建议开启独立undo表空间，只有这样才能利用到5.7引入的新特效：online undo truncate。

MySQL 5.7 新开辟了一个临时表空间，默认的磁盘文件命名为ibtmp1，所有非压缩的临时表都存储在该表空间中。由于临时表的本身属性，该文件在重启时会重新创建。对于云服务提供商而言，通过ibtmp文件，可以更好的控制临时文件产生的磁盘存储。

用户表空间，顾名思义，就是用于自己创建的表空间，通常分为两类，一类是**一个表空间一个文件**，另外一种则是5.7版本引入的所谓General Tablespace，在满足一定约束条件下，可以将多个表创建到同一个文件中。除此之外，InnoDB还定义了一些特殊用途的ibd文件，例如全文索引相关的表文件。而针对空间数据类型，也构建了不同的数据索引格式R-tree。

### 6.2 文件管理页

InnoDB 的每个数据文件都归属于一个表空间，不同的表空间使用一个唯一标识的space id来标记。例如ibdata1, ibdata2… 归属系统表空间，拥有相同的space id。用户创建表产生的ibd文件，则认为是一个独立的tablespace，只包含一个文件。

每个文件按照固定的 page size 进行区分，默认情况下，非压缩表的page size为16Kb。而在文件内部又按照64个Page（总共1M）一个Extent的方式进行划分并管理。对于不同的page size，对应的Extent大小也不同，对应为：

| page size | file space extent size |
| :-------- | :--------------------- |
| 4 KiB     | 256 pages = 1 MiB      |
| 8 KiB     | 128 pages = 1 MiB      |
| 16 KiB    | 64 pages = 1 MiB       |
| 32 KiB    | 64 pages = 2 MiB       |
| 64 KiB    | 64 pages = 4 MiB       |

尽管支持更大的Page Size，但目前还不支持大页场景下的数据压缩，原因是这涉及到修改压缩页中slot的固定size（其实实现起来也不复杂）。在不做声明的情况下，下文我们默认使用16KB的Page Size来阐述文件的物理结构。

### 6.3 临时表空间ibtmp

MySQL5.7引入了临时表专用的表空间，默认命名为ibtmp1，创建的非压缩临时表都存储在该表空间中。系统重启后，ibtmp1会被重新初始化到默认12MB。你可以通过设置参数[innodb_temp_data_file_path](http://dev.mysql.com/doc/refman/5.7/en/innodb-parameters.html#sysvar_innodb_temp_data_file_path)来修改ibtmp1的默认初始大小，以及是否允许autoExtent。默认值为 “ibtmp1:12M:autoExtent”。

除了用户定义的非压缩临时表外，第1~32个临时表专用的回滚段也存放在该文件中（0号回滚段总是存放在ibdata中）(`trx_sys_create_noredo_rsegs`)，

### 6.4 日志文件ib_logfile

关于日志文件的格式，网上已经有很多的讨论，在之前的[系列文章](http://mysql.taobao.org/monthly/2015/05/01/)中我也有专门介绍过，本小节主要介绍下MySQL5.7新的修改。

首先是checksum算法的改变，当前版本的MySQL5.7可以通过参数`innodb_log_checksums`来开启或关闭redo checksum，但目前唯一支持的checksum算法是CRC32。而在之前老版本中只支持效率较低的InnoDB本身的checksum算法。

第二个改变是为Redo log引入了版本信息([WL#8845](http://dev.mysql.com/worklog/task/?id=8845))，存储在ib_logfile的头部，从文件头开始，描述如下

| Macro                | bytes | Desc                                                         |
| :------------------- | :---- | :----------------------------------------------------------- |
| LOG_HEADER_FORMAT    | 4     | 当前值为1(LOG_HEADER_FORMAT_CURRENT)，在老版本中这里的值总是为0 |
| LOG_HEADER_PAD1      | 4     | 新版本未使用                                                 |
| LOG_HEADER_START_LSN | 8     | 当前iblogfile的开始LSN                                       |
| LOG_HEADER_CREATOR   | 32    | 记录版本信息，和MySQL版本相关，例如在5.7.11中，这里存储的是”MySQL 5.7.11”(LOG_HEADER_CREATOR_CURRENT) |

每次切换到下一个iblogfile时，都会更新该文件头信息(`log_group_file_header_flush`)

新的版本支持兼容老版本（`recv_find_max_checkpoint_0`），但升级到新版本后，就无法在异常状态下in-place降级到旧版本了（除非做一次clean的shutdown，并清理掉iblogfile）。

### 参考

[MySQL · 引擎特性 · InnoDB 文件系统之文件物理结构](http://mysql.taobao.org/monthly/2016/02/01/)



## 7. InnoDB 文件系统之IO系统和内存管理

### 7.1 综述

在[前一篇](http://mysql.taobao.org/monthly/2016/02/01/)我们介绍了InnoDB文件系统的物理结构，本篇我们继续介绍InnoDB文件系统的IO接口和内存管理。

为了管理磁盘文件的读写操作，InnoDB设计了一套文件IO操作接口，提供了同步IO和异步IO两种文件读写方式。针对异步IO，支持两种方式：一种是Native AIO，这需要你在编译阶段加上LibAio的Dev包，另外一种是simulated aio模式，InnoDB早期实现了一套系统来模拟异步IO，但现在Native Aio已经很成熟了，并且Simulated Aio本身存在性能问题，建议生产环境开启Native Aio模式。

对于数据读操作，通常用户线程触发的数据块请求读是同步读，如果开启了数据预读机制的话，预读的数据块则为异步读，由后台IO线程进行。其他后台线程也会触发数据读操作，例如Purge线程在无效数据清理，会读undo页和数据页；Master线程定期做ibuf merge也会读入数据页。崩溃恢复阶段也可能触发异步读来加速recover的速度。

对于数据写操作，InnoDB和大部分数据库系统一样，都是WAL模式，即先写日志，延迟写数据页。事务日志的写入通常在事务提交时触发，后台master线程也会每秒做一次redo fsync。数据页则通常由后台Page cleaner线程触发。但当buffer pool空闲block不够时，或者没做checkpoint的lsn age太长时，也会驱动刷脏操作，这两种场景由用户线程来触发。Percona Server据此做了优化来避免用户线程参与。MySQL5.7也对应做了些不一样的优化。

除了数据块操作，还有物理文件级别的操作，例如truncate、drop table、rename table等DDL操作，InnoDB需要对这些操作进行协调，目前的解法是通过特殊的flag和计数器的方式来解决。

当文件读入内存后，我们需要一种统一的方式来对数据进行管理，在启动实例时，InnoDB会按照instance分区分配多个一大块内存（在5.7里则是按照可配置的chunk size进行内存块划分），每个chunk又以UNIV_PAGE_SIZE为单位进行划分。数据读入内存时，会从buffer pool的free list中分配一个空闲block。所有的数据页都存储在一个LRU链表上，修改过的block被加到`flush_list`上，解压的数据页被放到unzip_LRU链表上。我们可以配置buffer pool为多个instance，以降低对链表的竞争开销。

在关键的地方本文注明了代码函数，建议读者边参考代码边阅读本文，本文的代码部分基于MySQL 5.7.11版本，不同的版本函数名或逻辑可能会有所不同。请读者阅读本文时尽量选择该版本的代码。

### 7.2 IO子系统

本小节我们介绍下磁盘文件与内存数据的中枢，即IO子系统。InnoDB对page的磁盘操作分为读操作和写操作。

对于读操作，在将数据读入磁盘前，总是为其先预先分配好一个block，然后再去磁盘读取一个新的page，在使用这个page之前，还需要检查是否有change buffer项，并根据change buffer进行数据变更。读操作分为两种场景：普通的读page及预读操作，前者为同步读，后者为异步读。

数据写操作也分为两种，一种是batch write，一种是single page write。写page默认受double write buffer保护，因此对double write buffer的写磁盘为同步写，而对数据文件的写入为异步写。

同步读写操作通常由用户线程来完成，而异步读写操作则需要后台线程的协同。

举个简单的例子，假设我们向磁盘批量写数据，首先先写到double write buffer，当dblwr满了之后，一次性将dblwr中的数据同步刷到ibdata，在确保sync到dblwr后，再将这些page分别异步写到各自的文件中。注意这时候dblwr依旧未被清空，新的写Page请求会进入等待。当异步写page完成后，io helper线程会调用`buf_flush_write_complete`，将写入的Page从flush list上移除。当dblwr中的page完全写完后，在函数`buf_dblwr_update`里将dblwr清空。这时候才允许新的写请求进dblwr。

同样的，对于异步写操作，也需要IO Helper线程来检查page是否完好、merge change buffer等一系列操作。

除了数据页的写入，还包括日志异步写入线程、及ibuf后台线程。

### 7.2 IO后台线程

InnoDB的IO后台线程主要包括如下几类：

- IO READ 线程：后台读线程，线程数目通过参数`innodb_read_io_threads`配置，主要处理INNODB 数据文件异步读请求，任务队列为`AIO::s_reads`，任务队列包含slot数为线程数 * 256(linux 平台)，也就是说，每个read线程最多可以pend 256个任务；
- IO WRITE 线程：后台写线程数，线程数目通过参数`innodb_write_io_threads`配置。主要处理INNODB 数据文件异步写请求，任务队列为`AIO::s_writes`，任务队列包含slot数为线程数 * 256(linux 平台)，也就是说，每个read线程最多可以pend 256个任务；
- LOG 线程：写日志线程。只有在写checkpoint信息时才会发出一次异步写请求。任务队列为`AIO::s_log`，共1个segment，包含256个slot；
- IBUF 线程：负责读入change buffer页的后台线程，任务队列为`AIO::s_ibuf`，共1个segment，包含256个slot

所有的同步写操作都是由用户线程或其他后台线程执行。上述IO线程只负责异步操作。

### 7.3 日志填充写入

由于现代磁盘通常的block size都是大于512字节的，例如一般是4096字节，为了避免 “read-on-write” 问题，在5.7版本里添加了一个参数`innodb_log_write_ahead_size`，你可以通过配置该参数，在写入redo log时，将写入区域配置到block size对齐的字节数。

在代码里的实现，就是在写入redo log 文件之前，为尾部字节填充0（参考函数`log_write_up_to`）。

Tips：所谓READ-ON-WRITE问题，就是当修改的字节不足一个block时，需要将整个block读进内存，修改对应的位置，然后再写进去；如果我们以block为单位来写入的话，直接完整覆盖写入即可。

### 参考

[MySQL · 引擎特性 · InnoDB 文件系统之IO系统和内存管理](http://mysql.taobao.org/monthly/2016/02/02/)

## 8. 线程池

### 8.1 概述

MySQL 原有线程调度方式有每个连接一个线程(one-thread-per-connection)和所有连接一个线程（no-threads）。

no-threads一般用于调试，生产环境一般用one-thread-per-connection方式。one-thread-per-connection 适合于低并发长连接的环境，而在高并发或大量短连接环境下，大量创建和销毁线程，以及线程上下文切换，会严重影响性能。另外 one-thread-per-connection 对于大量连接数扩展也会影响性能。

为了解决上述问题，MariaDB、Percona、Oracle MySQL 都推出了线程池方案，它们的实现方式大体相似，这里以 Percona 为例来简略介绍实现原理，同时会介绍我们在其基础上的一些改进。

### 8.2 实现

线程池方案下，用户的每个连接不再对应一个线程。线程池由一系列 worker 线程组成，这些worker线程被分为`thread_pool_size`个group。用户的连接按 round-robin 的方式映射到相应的group 中，一个连接可以由一个group中的一个或多个worker线程来处理。

1. listener 线程 每个group中有一个listener线程，通过epoll的方式来监听本group中连接的事件。listener线程同时也是worker线程，listener线程不是固定的。 listener线程监听到连接事件后会将事件放入优先级队列中，listener线程作为worker线程也处理一些连接事件，以减少上下文切换。 listener线程会检查优先级队列是否为空，如果为空表示网络空闲，listener线程会作为worker线程处理第一个监听事件，其他事件仍然放入优先级队列中。 另外，当没有活跃线程时，listener会唤醒一个线程，如果没有线程可以唤醒，且当前group只有一个线程且为listener，则创建一个线程。
2. 优先级队列 分为高优先级队列和普通队列，已经开启的事务并且tickets不为0，放入高优先队列，否则放入普通队列。每个连接在`thread_pool_high_prio_tickets`次被放到优先队列中后，会移到普通队列中。worker线程先从高优先队列取event处理，只有当高优先队列为空时才从普通队列取event处理。 通过优先级队列，可以让已经开启的事务或短事务得到优先处理，及时提交释放锁等资源。
3. worker 线程 worker线程负责从优先队列取事件处理。如果没有取到event，会尝试从epoll中取一个，如果没有取到再进入等待，如果等待超过`thread_pool_idle_timeout` worker线程会退出。
4. timer 线程 每隔`thread_pool_stall_limit`时间检查一次。
   - listener没有接收新的事件，listener正在等待时需调用`wake_or_create_thread`，重新创建listener；
   - 从上一次检查起，worker线程没有收到新的事件，并且队列不为空，则认为发生了stall，需唤醒或创建worker线程；
   - 检查`net_wait_timeout`是否超时，如果超时退出连接，而不是退出worker线程。
5. 何时唤醒或创建worker线程
   - 从队列中取事件时发现没有活跃线程时；
   - worker线程发生等待且没有活跃线程时；
   - timer线程认为发生了stall；

**连接池和线程池的区别**

最后说一点连接池和线程池的区别。连接池和线程池是两个独立的概念，连接池是在客户端的优化，缓存客户的连接，避免重复创建和销毁连接。而线程池是服务器端的优化。两者的优化角度不同，不相关，因此两种优化可以同时使用。

### 参考

[MySQL · 特性分析 · 线程池](http://mysql.taobao.org/monthly/2016/02/09/)



## 9. checkpoint机制浅析

checkpoint又名检查点，一般checkpoint会将某个时间点之前的脏数据全部刷新到磁盘，以实现数据的一致性与完整性。目前各个流行的关系型数据库都具备checkpoint功能，其主要目的是为了缩短崩溃恢复时间，以Oracle为例，在进行数据恢复时，会以最近的checkpoint为参考点执行事务前滚。而在WAL机制的浅析中，也提过PostgreSQL在崩溃恢复时会以最近的checkpoint为基础，不断应用这之后的WAL日志。

以下几种情况会触发数据库操作系统做检查点操作：

1. 超级用户（其他用户不可）执行CHECKPOINT命令
2. 数据库shutdown
3. 数据库recovery完成
4. XLOG日志量达到了触发checkpoint阈值
5. 周期性地进行checkpoint
6. 需要刷新所有脏页

为了能够周期性的创建检查点，减少崩溃恢复时间，同时合并I/O，PostgreSQL提供了辅助进程checkpointer。它会对不断检测周期时间以及上面的XLOG日志量阈值是否达到，而周期时间以及XLOG日志量阈值可以通过参数来设置大小，接下来介绍下与checkpoints相关的参数。

## 参考

[PgSQL · 特性分析 · checkpoint机制浅析](http://mysql.taobao.org/monthly/2017/04/04/)



## 10. InnoDB Buffer Pool

### 10.1 前言

用户对数据库的最基本要求就是能高效的读取和存储数据，但是读写数据都涉及到与低速的设备交互，为了弥补两者之间的速度差异，所有数据库都有缓存池，用来管理相应的数据页，提高数据库的效率，当然也因为引入了这一中间层，数据库对内存的管理变得相对比较复杂。本文主要分析MySQL Buffer Pool的相关技术以及实现原理，源码基于阿里云RDS MySQL 5.6分支，其中部分特性已经开源到AliSQL。Buffer Pool相关的源代码在buf目录下，主要包括LRU List，Flu List，Double write buffer, 预读预写，Buffer Pool预热，压缩页内存管理等模块，包括头文件和IC文件，一共两万行代码。

### 10.2 基础知识

#### 10.2.1 Buffer Pool Instance:

大小等于innodb_buffer_pool_size/innodb_buffer_pool_instances，每个instance都有自己的锁，信号量，物理块(Buffer chunks)以及逻辑链表(下面的各种List)，即各个instance之间没有竞争关系，可以并发读取与写入。所有instance的物理块(Buffer chunks)在数据库启动的时候被分配，直到数据库关闭内存才予以释放。当innodb_buffer_pool_size小于1GB时候，innodb_buffer_pool_instances被重置为1，主要是防止有太多小的instance从而导致性能问题。每个Buffer Pool Instance有一个page hash链表，通过它，使用space_id和page_no就能快速找到已经被读入内存的数据页，而不用线性遍历LRU List去查找。注意这个hash表不是InnoDB的自适应哈希，自适应哈希是为了减少Btree的扫描，而page hash是为了避免扫描LRU List。

#### 10.2.2 数据页：

InnoDB中，数据管理的最小单位为页，默认是16KB，页中除了存储用户数据，还可以存储控制信息的数据。InnoDB IO子系统的读写最小单位也是页。如果对表进行了压缩，则对应的数据页称为压缩页，如果需要从压缩页中读取数据，则压缩页需要先解压，形成解压页，解压页为16KB。压缩页的大小是在建表的时候指定，目前支持16K，8K，4K，2K，1K。即使压缩页大小设为16K，在blob/varchar/text的类型中也有一定好处。假设指定的压缩页大小为4K，如果有个数据页无法被压缩到4K以下，则需要做B-tree分裂操作，这是一个比较耗时的操作。正常情况下，Buffer Pool中会把压缩和解压页都缓存起来，当Free List不够时，按照系统当前的实际负载来决定淘汰策略。如果系统瓶颈在IO上，则只驱逐解压页，压缩页依然在Buffer Pool中，否则解压页和压缩页都被驱逐。

#### 10.2.3 Buffer Chunks:

包括两部分：数据页和数据页对应的控制体，控制体中有指针指向数据页。Buffer Chunks是最低层的物理块，在启动阶段从操作系统申请，直到数据库关闭才释放。通过遍历chunks可以访问几乎所有的数据页，有两种状态的数据页除外：没有被解压的压缩页(BUF_BLOCK_ZIP_PAGE)以及被修改过且解压页已经被驱逐的压缩页(BUF_BLOCK_ZIP_DIRTY)。此外数据页里面不一定都存的是用户数据，开始是控制信息，比如行锁，自适应哈希等。

#### 10.2.4 逻辑链表:

链表节点是数据页的控制体(控制体中有指针指向真正的数据页)，链表中的所有节点都有同一的属性，引入其的目的是方便管理。下面其中链表都是逻辑链表。

#### 10.2.5 Free List:

其上的节点都是未被使用的节点，如果需要从数据库中分配新的数据页，直接从上获取即可。InnoDB需要保证Free List有足够的节点，提供给用户线程用，否则需要从FLU List或者LRU List淘汰一定的节点。InnoDB初始化后，Buffer Chunks中的所有数据页都被加入到Free List，表示所有节点都可用。

#### 10.2.6 LRU List:

这个是InnoDB中最重要的链表。所有新读取进来的数据页都被放在上面。链表按照最近最少使用算法排序，最近最少使用的节点被放在链表末尾，如果Free List里面没有节点了，就会从中淘汰末尾的节点。LRU List还包含没有被解压的压缩页，这些压缩页刚从磁盘读取出来，还没来的及被解压。LRU List被分为两部分，默认前5/8为young list，存储经常被使用的热点page，后3/8为old list。新读入的page默认被加在old list头，只有满足一定条件后，才被移到young list上，主要是为了预读的数据页和全表扫描污染buffer pool。

#### 10.2.7 FLU List:

这个链表中的所有节点都是脏页，也就是说这些数据页都被修改过，但是还没来得及被刷新到磁盘上。在FLU List上的页面一定在LRU List上，但是反之则不成立。一个数据页可能会在不同的时刻被修改多次，在数据页上记录了最老(也就是第一次)的一次修改的lsn，即oldest_modification。不同数据页有不同的oldest_modification，FLU List中的节点按照oldest_modification排序，链表尾是最小的，也就是最早被修改的数据页，当需要从FLU List中淘汰页面时候，从链表尾部开始淘汰。加入FLU List，需要使用flush_list_mutex保护，所以能保证FLU List中节点的顺序。

#### 10.2.8 Quick List:

这个链表是阿里云RDS MySQL 5.6加入的，使用带Hint的SQL查询语句，可以把所有这个查询的用到的数据页加入到Quick List中，一旦这个语句结束，就把这个数据页淘汰，主要作用是避免LRU List被全表扫描污染。

#### 10.2.9 Unzip LRU List:

这个链表中存储的数据页都是解压页，也就是说，这个数据页是从一个压缩页通过解压而来的。

#### 10.2.10 Zip Clean List:

这个链表只在Debug模式下有，主要是存储没有被解压的压缩页。这些压缩页刚刚从磁盘读取出来，还没来的及被解压，一旦被解压后，就从此链表中删除，然后加入到Unzip LRU List中。

#### 10.2.11 Zip Free:

压缩页有不同的大小，比如8K，4K，InnoDB使用了类似内存管理的伙伴系统来管理压缩页。Zip Free可以理解为由5个链表构成的一个二维数组，每个链表分别存储了对应大小的内存碎片，例如8K的链表里存储的都是8K的碎片，如果新读入一个8K的页面，首先从这个链表中查找，如果有则直接返回，如果没有则从16K的链表中分裂出两个8K的块，一个被使用，另外一个放入8K链表中。

### 10.3 Double Write Buffer(dblwr)

服务器突然断电，这个时候如果数据页被写坏了(例如数据页中的目录信息被损坏)，由于InnoDB的redolog日志不是完全的物理日志，有部分是逻辑日志，因此即使奔溃恢复也无法恢复到一致的状态，只能依靠Double Write Buffer先恢复完整的数据页。**Double Write Buffer主要是解决数据页半写**的问题，如果文件系统能保证写数据页是一个原子操作，那么可以把这个功能关闭，这个时候每个写请求直接写到对应的表空间中。 Double Write Buffer大小默认为2M，即128个数据页。其中分为两部分，一部分留给batch write，另一部分是single page write。前者主要提供给批量刷脏的操作，后者留给用户线程发起的单页刷脏操作。batch write的大小可以由参数`innodb_doublewrite_batch_size`控制，例如假设innodb_doublewrite_batch_size配置为120，则剩下8个数据页留给single page write。 假设我们要进行批量刷脏操作，我们会首先写到内存中的Double Write Buffer(也是2M，在系统初始化中分配，不使用Buffer Chunks空间)，如果dblwr写满了，一次将其中的数据刷盘到系统表空间指定位置，注意这里是同步IO操作，在确保写入成功后，然后使用异步IO把各个数据页写回自己的表空间，由于是异步操作，所有请求下发后，函数就返回，表示写成功了(`buf_dblwr_add_to_batch`)。不过这个时候后续的写请求依然会阻塞，知道这些异步操作都成功，才清空系统表空间上的内容，后续请求才能被继续执行。这样做的目的就是，如果在异步写回数据页的时候，系统断电，发生了数据页半写，这个时候由于系统表空间中的数据页是完整的，只要从中拷贝过来就行(`buf_dblwr_init_or_load_pages`)。 异步IO请求完成后，会检查数据页的完整性以及完成change buffer相关操作，接着IO helper线程会调用`buf_flush_write_complete`函数，把数据页从Flush List删除，如果发现batch write中所有的数据页都写成了，则释放dblwr的空间。



### 参考

[MySQL · 引擎特性 · InnoDB Buffer Pool](http://mysql.taobao.org/monthly/2017/05/01/)



## 11. 二级索引分析

### 11.1 前言

在MySQL中，创建一张表时会默认为主键创建聚簇索引，B+树将表中所有的数据组织起来，即数据就是索引主键所以在InnoDB里，主键索引也被称为聚簇索引，索引的叶子节点存的是整行数据。而除了聚簇索引以外的所有索引都称为二级索引，二级索引的叶子节点内容是主键的值。

### 11.2 二级索引

#### 11.2.1 创建二级索引

```sql
CREATE INDEX [index name] ON [table name]([column name]);
```

或者

```sql
ALTER TABLE [table name] ADD INDEX [index name]([column name]);
```

在MySQL中，`CREATE INDEX` 操作被映射为 `ALTER TABLE ADD_INDEX`。

#### 11.2.2 二级索引格式

例如创建如下一张表:

```sql
CREATE TABLE users(
    id INT NOT NULL,
    name VARCHAR(20) NOT NULL,
    age INT NOT NULL,
    PRIMARY KEY(id)
);
```

新建一个以`age`字段的二级索引:

```sql
ALTER TABLE users ADD INDEX index_age(age);
```

MySQL会分别创建主键`id`的聚簇索引和`age`的二级索引:

<img src="http://blog-1259650185.cosbj.myqcloud.com/img/202203/31/1648717694.jpg" alt="secondary_index" style="zoom: 50%;" />

**在MySQL中主键索引的叶子节点存的是整行数据，而二级索引叶子节点内容是主键的值。**

### 11.3 二级索引的检索过程

在MySQL的查询过程中，SQL优化器会选择合适的索引进行检索，在使用二级索引的过程中，因为二级索引没有存储全部的数据，假如二级索引满足查询需求，则直接返回，即为覆盖索引，反之则需要**回表**去主键索引(聚簇索引)查询。

例如执行`SELECT * FROM users WHERE age=35;`则需要进行回表:

<img src="http://blog-1259650185.cosbj.myqcloud.com/img/202203/31/1648717804.jpg" alt="search_secondary_index" style="zoom:50%;" />

使用 `EXPLAIN` 查看执行计划可以看到使用的索引是我们之前创建的 `index_age`:

```sql
MySQL [sbtest]> EXPLAIN SELECT * FROM users WHERE age=35;
+----+-------------+-------+------------+------+---------------+-----------+---------+-------+------+----------+-------+
| id | select_type | table | partitions | type | possible_keys | key       | key_len | ref   | rows | filtered | Extra |
+----+-------------+-------+------------+------+---------------+-----------+---------+-------+------+----------+-------+
|  1 | SIMPLE      | users | NULL       | ref  | index_age     | index_age | 4       | const |    1 |   100.00 | NULL  |
+----+-------------+-------+------------+------+---------------+-----------+---------+-------+------+----------+-------+
1 row in set, 1 warning (0.00 sec)
```

### 11.4 总结

二级索引是指定字段与主键的映射，主键长度越小，普通索引的叶子节点就越小，二级索引占用的空间也就越小，所以要避免使用过长的字段作为主键。



## 参考

[MySQL · 引擎特性 · 二级索引分析](http://mysql.taobao.org/monthly/2020/01/01/)























