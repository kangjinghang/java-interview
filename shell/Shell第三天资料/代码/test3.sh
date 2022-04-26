#!/bin/bash
read -p "请输入文件全名:" filename
read -p "请输入数据:" data
if [ -w $filename -a -n $data ]
then
	# 将输入数据输出到文件中
	echo $data > $filename
	echo "文件写入成功"
else
	echo "文件写入失败"
fi
