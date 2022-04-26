#!/bin/bash
filenames=$(ls /root/temp)
number=1
for name in $filenames
do
	printf "重命名前:%s " ${name}
	newname=${name}"-"${number}
	rename ${name} ${newname} /root/temp/*
	let number++
	printf "重命名后:%s \n" ${newname}
done
