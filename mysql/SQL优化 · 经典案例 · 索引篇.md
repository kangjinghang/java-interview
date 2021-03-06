## Introduction

在这些年的工作之中，由于SQL问题导致的数据库故障层出不穷，下面将过去六年工作中遇到的SQL问题总结归类，还原问题原貌，给出分析问题思路和解决问题的方法，帮助用户在使用数据库的过程中能够少走一些弯路。总共包括四部分：索引篇，SQL改写篇，参数优化篇，优化器篇四部分，今天将介绍第一部分：索引篇。

索引问题是SQL问题中出现频率最高的，常见的索引问题包括：无索引，隐式转换。当数据库中出现访问表的SQL无索引导致全表扫描，如果表的数据量很大，扫描大量的数据，应用请求变慢占用数据库连接，连接堆积很快达到数据库的最大连接数设置，新的应用请求将会被拒绝导致故障发生。隐式转换是指SQL查询条件中的传入值与对应字段的数据定义不一致导致索引无法使用。常见隐式转换如字段的表结构定义为字符类型，但SQL传入值为数字；或者是字段定义collation为区分大小写，在多表关联的场景下，其表的关联字段大小写敏感定义各不相同。隐式转换会导致索引无法使用，进而出现上述慢SQL堆积数据库连接数跑满的情况。

## 无索引案例：

**表结构**

```SQL
CREATE TABLE `user` (
……
mo bigint NOT NULL DEFAULT '' ,
KEY ind_mo (mo) 
……
) ENGINE=InnoDB;

SELECT uid FROM `user` WHERE mo=13772556391 LIMIT 0,1
```

**执行计划**

```SQL
mysql> explain  SELECT uid FROM `user` WHERE mo=13772556391 LIMIT 0,1;
           id: 1
  select_type: SIMPLE
        table: user
         type: ALL
possible_keys: NULL
          key: NULL
         rows: 707250
         Extra: Using where
```

从上面的SQL看到执行计划中ALL，代表了这条SQL执行计划是全表扫描，每次执行需要扫描707250行数据，这是非常消耗性能的，该如何进行优化？添加索引。
**验证mo字段的过滤性**

```SQL
mysql> select count(*) from user where mo=13772556391;
|   0    |
```

可以看到mo字段的过滤性是非常高的，进一步验证可以通过select count(*) as all_count,count(distinct mo) as distinct_cnt from user，通对比 all_count和distinct_cnt这两个值进行对比，如果all_cnt和distinct_cnt相差甚多，则在mo字段上添加索引是非常有效的。

**添加索引**

```SQL
mysql> alter table user add index ind_mo(mo);
mysql>SELECT uid FROM `user` WHERE mo=13772556391 LIMIT 0,1;
Empty set (0.05 sec)
```

**执行计划**

```SQL
mysql> explain  SELECT uid FROM `user` WHERE mo=13772556391 LIMIT 0,1\G;
*************************** 1. row ***************************
               id: 1
      select_type: SIMPLE
            table: user
             type: index
    possible_keys: ind_mo
              key: ind_mo
             rows: 1
            Extra: Using where; Using index
```

## 隐式转换案例一

**表结构**

```SQL
  CREATE TABLE `user` (
  ……
  mo char(11) NOT NULL DEFAULT '' ,
  KEY ind_mo (mo)
  ……
  ) ENGINE=InnoDB;
```

**执行计划**

```SQL
mysql> explain extended select uid from`user` where mo=13772556391 limit 0,1;
mysql> show warnings;
Warning1：Cannot use  index 'ind_mo' due to type or collation conversion on field 'mo'                                                                        
Note：select `user`.`uid` AS `uid` from `user` where (`user`.`mo` = 13772556391) limit 0,1
```

**如何解决**

```SQL
mysql> explain   SELECT uid FROM `user` WHERE mo='13772556391' LIMIT 0,1\G;
*************************** 1. row ***************************
              id: 1
     select_type: SIMPLE
           table: user
            type: ref
   possible_keys: ind_mo
             key: ind_mo
            rows: 1
           Extra: Using where; Using index
```

上述案例中由于表结构定义mo字段后字符串数据类型，而应用传入的则是数字，进而导致了隐式转换，索引无法使用，所以有两种方案：
第一，将表结构mo修改为数字数据类型。
第二，修改应用将应用中传入的字符类型改为数据类型。

## 隐式转换案例二

**表结构**

```SQL
CREATE TABLE `test_date` (
     `id` int(11) DEFAULT NULL,
     `gmt_create` varchar(100) DEFAULT NULL,
     KEY `ind_gmt_create` (`gmt_create`)
) ENGINE=InnoDB AUTO_INCREMENT=524272;
```

**5.5版本执行计划**

```SQL
mysql> explain  select * from test_date where gmt_create BETWEEN DATE_ADD(NOW(), INTERVAL - 1 MINUTE) AND   DATE_ADD(NOW(), INTERVAL 15 MINUTE) ;
+----+-------------+-----------+-------+----------------+----------------+---------+------+------+-------------+
| id | select_type | table | type | possible_keys  | key | key_len | ref  | rows | Extra       |
+----+-------------+-----------+-------+----------------+----------------+---------+------+------+-------------+
|1|SIMPLE| test_date |range| ind_gmt_create|ind_gmt_create|303| NULL | 1 | Using where |
```

**5.6版本执行计划**

```SQL
mysql> explain select * from test_date where gmt_create BETWEEN DATE_ADD(NOW(), INTERVAL - 1 MINUTE) AND   DATE_ADD(NOW(), INTERVAL 15 MINUTE) ; 
+----+-------------+-----------+------+----------------+------+---------+------+---------+-------------+
| id | select_type | table | type | possible_keys  | key  | key_len | ref | rows | Extra|
+----+-------------+-----------+------+----------------+------+---------+------+---------+-------------+
| 1 | SIMPLE| test_date | ALL | ind_gmt_create | NULL | NULL | NULL | 2849555 | Using where |
+----+-------------+-----------+------+----------------+------+---------+------+---------+-------------+

|Warning|Cannot use range access on index 'ind_gmt_create' due to type on field 'gmt_create' 
  
```

上述案例是用户在5.5版本升级到5.6版本后出现的隐式转换，导致数据库cpu压力100%，所以我们在定义时间字段的时候一定要采用时间类型的数据类型。

## 隐式转换案例三

**表结构**

```SQL
  CREATE TABLE `t1` (
  `c1` varchar(100) CHARACTER SET latin1 COLLATE latin1_bin DEFAULT NULL,
  `c2` varchar(100) DEFAULT NULL,
  KEY `ind_c1` (`c1`)
) ENGINE=InnoDB DEFAULT CHARSET=utf8 

CREATE TABLE `t2` (
  `c1` varchar(100) CHARACTER SET utf8 COLLATE utf8_bin DEFAULT NULL,
  `c2` varchar(100) DEFAULT NULL,
  KEY `ind_c2` (`c2`)
) ENGINE=InnoDB DEFAULT CHARSET=utf8 
```

**执行计划**

```SQL
mysql> explain     select t1.* from  t2 left  join  t1 on t1.c1=t2.c1 where t2.c2='b';
+----+-------------+-------+------+---------------+--------+---------+-------+--------+-------------+
| id | select_type | table | type | possible_keys |key| key_len | ref   | rows   | Extra    |
+----+-------------+-------+------+---------------+--------+---------+-------+--------+-------------+
| 1 | SIMPLE | t2 | ref  | ind_c2 | ind_c2 | 303     | const |    258 | Using where |
|1  |SIMPLE |t1  |ALL   | NULL   | NULL   | NULL    | NULL  | 402250 |    |
```

**修改COLLATE**

```SQL
mysql> alter table t1 modify column c1 varchar(100) COLLATE utf8_bin ;                
Query OK, 401920 rows affected (2.79 sec)
Records: 401920  Duplicates: 0  Warnings: 0
```

**执行计划**

```SQL
mysql> explain   select t1.* from  t2 left  join  t1 on t1.c1=t2.c1 where t2.c2='b';
+----+-------------+-------+------+---------------+--------+---------+------------+-------+-------------+
| id | select_type | table | type | possible_keys | key  | key_len | ref | rows  | Extra       |
+----+-------------+-------+------+---------------+--------+---------+------------+-------+-------------+
|  1 | SIMPLE| t2| ref | ind_c2| ind_c2 | 303     | const      |   258 | Using where |
|  1 |SIMPLE| t1|ref| ind_c1  | ind_c1 | 303     | test.t2.c1 | 33527 |             |
+----+-------------+-------+------+---------------+--------+---------+------------+-------+-------------+
```

可以看到修改了字段的COLLATE后执行计划使用到了索引，所以一定要注意表字段的collate属性的定义保持一致。

## 两个索引的常见误区

- 误区一：对查询条件的每个字段建立单列索引，例如查询条件为：A=？and B=？and C=？。
  在表上创建了3个单列查询条件的索引ind_A(A)，ind_B(B)，ind_C(C)，应该根据条件的过滤性，创建适当的单列索引或者组合索引。
- 误区二：对查询的所有字段建立组合索引，例如查询条件为select A,B,C,D,E,F from T where G=？。
  在表上创建了ind_A_B_C_D_E_F_G(A,B,C,D,E,F,G)。

## 索引最佳实践

- 在使用索引时，我们可以通过explain+extended查看SQL的执行计划，判断是否使用了索引以及发生了隐式转换。
- 由于常见的隐式转换是由字段数据类型以及collation定义不当导致，因此我们在设计开发阶段，要避免数据库字段定义，避免出现隐式转换。
- 由于MySQL不支持函数索引，在开发时要避免在查询条件加入函数，例如date(gmt_create)。
- 所有上线的SQL都要经过严格的审核，创建合适的索引。



## 参考

[SQL优化 · 经典案例 · 索引篇](http://mysql.taobao.org/monthly/2017/02/05/)
