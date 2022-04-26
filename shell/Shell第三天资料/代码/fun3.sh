#!/bin/bash
funParam()
{
	echo "第一个参数为: $1 !"
	echo "第二个参数为: $2 !"
	echo "第十个参数为: ${10} !"
	echo "参数总数有 $# 个!"
	echo "获取所有参数作为一个字符串返回: $* !"
}

# 调用函数
funParam 1 2 3 4 5 6 7 8 9 10 22
