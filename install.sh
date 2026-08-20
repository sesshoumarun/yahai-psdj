
#!/bin/bash

set -e

INSTALL_DIR="/usr/local/tk-node-manager"

echo "================================="
echo " TK NODE MANAGER V3 INSTALL"
echo "================================="


if [ "$EUID" -ne 0 ]; then
    echo "请使用 root 执行"
    exit 1
fi


echo "[1/5] 更新系统"

apt update -y >/dev/null 2>&1 || true


echo "[2/5] 安装依赖"


apt install -y \
curl \
wget \
jq \
qrencode \
python3 \
git \
openssl \
net-tools \
unzip >/dev/null 2>&1 || true



echo "[3/5] 安装目录"

mkdir -p $INSTALL_DIR


echo "[4/5] 下载程序"


REPO="https://raw.githubusercontent.com/你的用户名/tk-node-manager/main"


curl -fsSL $REPO/main.sh \
-o $INSTALL_DIR/main.sh


curl -fsSL $REPO/config.conf \
-o $INSTALL_DIR/config.conf


chmod +x $INSTALL_DIR/main.sh



echo "[5/5] 创建快捷命令"


cat >/usr/bin/node-manager <<EOF
#!/bin/bash
bash $INSTALL_DIR/main.sh
EOF


chmod +x /usr/bin/node-manager



echo ""
echo "================================="
echo "安装完成"
echo ""
echo "运行:"
echo ""
echo "node-manager"
echo "================================="
