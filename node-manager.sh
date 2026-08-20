#!/bin/bash


BASE="/root/yahai-psdj"

source $BASE/config.conf


mkdir -p $NODE_DIR

touch $PORT_FILE



check_port()
{

PORT=$1


if ss -lnt | grep -q ":$PORT"
then

return 0

fi


if grep -q "^$PORT$" $PORT_FILE
then

return 0

fi


return 1

}



api_check()
{

PORT=$1


RESULT=$(curl -s \
"$API_URL?action=check&password=$API_PASSWORD&port=$PORT")


echo $RESULT | grep -q "free"

}



get_port()
{


while true
do


P=$(shuf -i 20000-60000 -n1)


if ! check_port $P
then

if api_check $P
then

echo $P
return

fi

fi


done


}



register_port()
{

PORT=$1
TYPE=$2


curl -s \
"$API_URL?action=register&password=$API_PASSWORD&port=$PORT&type=$TYPE"


echo $PORT >> $PORT_FILE


}



show_ports()
{

curl -s \
"$API_URL?action=list&password=$API_PASSWORD"


}



create_direct()
{


echo "创建直连节点"


PORT=$(get_port)


echo "分配端口:$PORT"


register_port $PORT direct


echo "直连节点端口:$PORT 创建完成"


}



create_relay()
{


echo "创建中转节点"


PORT=$(get_port)


echo "分配端口:$PORT"


register_port $PORT relay


echo "中转节点端口:$PORT 创建完成"


}



menu()
{


while true

do


clear


echo "
========================

 YAHAI NODE MANAGER

========================

1. 创建直连节点

2. 创建中转节点

3. 查看共享端口

4. 检测API

0.退出


"


read -p "选择:" C



case $C in


1)
create_direct
read
;;


2)
create_relay
read
;;


3)
show_ports
read
;;


4)

curl $API_URL

read

;;


0)
exit
;;


esac


done


}


menu
