#!/bin/bash
user=root
pass=root
backfile=/root/msyql/backup
[ ! -d $backfile ] && mkdir -p $backfile
cmd="mysql -u${user} -p${pass}"
dump="mysqldump -u$user -p$pass "
dblist=`$cmd -e "show databases;" 2>/dev/null | sed 1d | egrep -v '_schema|mysql'`
echo "需要备份的数据库列表:"
echo $dblist
echo "开始备份"
for db_name in $dblist
do
    printf '正在备份数据库:%s\n' ${db_name}
    tables=`mysql -u$user -p$pass -e"use $db_name;show tables;" 2>/dev/null|sed 1d`
    for j in $tables
    do
	printf '正在备份数据库 %s 表 %s ' ${db_name} ${j}
	$dump -B --databases $db_name --tables $j 2>/dev/null > ${backfile}/${db_name}-${j}-`date +%m%d`.sql
	printf ',备份完成\n'
    done
    printf '数据库 %s 备份完成\n' ${db_name}
done
echo "全部备份完成!"
