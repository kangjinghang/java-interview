#!/bin/bash
# 创建索引数组
echo "创建索引数组"
declare -a array1=(100 abc "itheima")
# 获取索引数组数据
echo "获取array1数组第3个元素: ${array1[2]}"
echo "打印array1数组所有元素:${array1[*]}"

echo 

# 创建关联数组
echo "创建关联数组"
declare -A array2=(["one"]=100 ["two"]=abc ["itcast"]="itheima")
# 获取索引数组数据
echo "获取array2数组key="itcast"元素: ${array2["itcast"]}"
echo "打印array2数组所有元素:${array2[@]}"


