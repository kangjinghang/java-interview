#!/bin/bash
echo "您的爱好是什么?"
select hobby in "编程" "游戏" "篮球" "游泳"
do
   echo $hobby
   break
done
echo "您的爱好是${hobby}"
