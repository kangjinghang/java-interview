#!/bin/bash
# 使用read命令读取数据,要有提示信息"请输入姓名,年龄,爱好:" 将数据赋值给多个变量
read -p "请输入姓名,年龄,爱好:" name age hobby
# 打印每一个变量的值
echo "姓名:${name}"
echo "年龄:${age}"
echo "爱好:${hobby}"
