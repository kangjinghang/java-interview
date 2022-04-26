#!/bin/bash
read -t 30 -p "请输入创建文件的数目:" n
test=$(echo $n | sed 's/[0-9]//g')
if [ -n "$n" -a -z "$test" ]
then 
	for ((i=0;i<$n;i++))
	do
		name=$(date +%N)
		[ ! -d ./temp ] && mkdir -p ./temp
		touch "./temp/$name"
		echo "创建 $name 成功!"
	done	
else
	echo "创建失败"
	exit 1
fi
