#!/bin/bash
read -p "请输入一个循环的数字:" number
i=0
until [[ ! $i < $number ]]
do
   let i++
   echo "hello${i}"
done
