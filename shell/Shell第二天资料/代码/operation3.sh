#!/bin/bash

file1="/root/operation1.sh"
file2="/root/operation2.sh"

# 测试文件是否可写
if [[ -w $file1 ]]
then 
	echo "file1文件可写"
else 
	echo "file1文件不可写"
fi

# 测试文件是否读
if [[ -r $file1 ]]
then 
	echo "file1文件可读"
else 
	echo "file1文件不可读"
fi


# 测试文件是否可执行
if [[ -x $file1 ]]
then 
	echo "file1文件可执行"
else 
	echo "file1文件不可执行"
fi


# 测试文件是否是普通文件
if [[ -f $file1 ]]
then 
	echo "file1文件是普通文件"
else 
	echo "file1文件不是普通文件"
fi

# 测试文件是否为空
if [[ -s $file1 ]]
then 
	echo "file1文件不为空"
else 
	echo "file1文件为空"
fi

# 测试文件是否存在
if [[ -e $file1 ]]
then 
	echo "file1文件存在"
else 
	echo "file1文件不存在"
fi


# 测试文件是否是目录
if [[ -d $file1 ]]
then 
	echo "file1是目录"
else 
	echo "file1不是目录"
fi


# 测试文件1是否比文件2新
if [[ $file1 -nt $file2 ]]
then 
	echo "file1比file2新"
else 
	echo "file1比file2旧"
fi
