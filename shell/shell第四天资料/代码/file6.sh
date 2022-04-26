#!/bin/bash
ULIST=$(cat /root/users.txt)
for UNAME in $ULIST
do
	useradd $UNAME
	echo "123456" | passwd --stdin $UNAME &>/dev/null
	[ $? -eq 0 ] && echo "${UNAME}用户名与密码添加初始化成功!"
done
