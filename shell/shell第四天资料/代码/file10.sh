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
	printf '正在备份数据库:%s ' ${db_name}
	$dump ${db_name} 2>/dev/null |gzip > ${backfile}/${db_name}_$(date +%m%d).sql.gz
	printf " , 备份完成\n"
done
echo "全部备份完成!"
