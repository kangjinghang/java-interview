#!/bin/bash
read -p "请输入一个循环的数字:" number
i=0
while ((i<number))
do
   let i++
   if ((i==3))
   then 
       echo "进入下一次循环"
       continue;
   fi
   echo "hello${i}"
done
