#!/bin/bash
count=0
for i in 192.168.56.{1..254}
do
	receive=$(ping $i -c 2 | awk 'NR==6{print $4}')
	if [ $receive -gt 0 ]
	then
		echo "${i} 在线"
		let count++	
	else
		echo "${i} 不在线"
	fi
done
echo "在线服务器的个数:${count}"
