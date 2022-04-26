#!/bin/bash
read -p "请输入你的考试成绩: " score
if ((score<60 && score>=0))
then 
	echo "不及格"
elif ((score>=60 && score<70))
then 
	echo "及格"
elif ((score>=70 && score<80))
then 
	echo "中等"
elif ((score>=80 && score<90))
then 
	echo "良好"
elif ((score>=90 && score<=100))
then 
	echo "优秀"
else
	echo "成绩不合法"
fi



