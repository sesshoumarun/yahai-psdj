# yahai-psdj
中转加直连
1. install.sh（GitHub 远程主脚本）
角色：整个系统的“大脑”和控制面板入口。

逻辑关系：存放在你的 GitHub 仓库中。用户通过 curl 执行它时，它会拉取最新代码并呈现交互菜单。它本身不包含任何敏感密钥，只负责调度逻辑、安装依赖、调用 Xray/Docker 以及和云端 API 交互。

2. /root/yahaidajian.sh（本地独立配置文件）
角色：服务器的“通行证”。

逻辑关系：由 install.sh 在首次运行时自动引导创建（或手动放置）。它保存在服务器本地 /root/ 目录下，绝对不能上传到 GitHub。里面仅存放两行关键参数：

Bash
API_URL="你的云端API地址"
API_TOKEN="你的安全校验密钥"
主脚本在最顶部通过 source 加载它，用来打通远程防撞池和云端大盘。

🌐 二、 模块一：直连节点（VLESS + REALITY）相关文件
直连节点采用宿主机原生运行 Xray 进程的方式。

核心配置文件路径：/usr/local/etc/xray/config_${port}.json

逻辑：每个直连节点对应一个独立端口的配置文件，由脚本动态生成。

进程日志路径：/root/xray_${port}.log

逻辑：记录对应端口 Xray 进程的运行状态和报错信息。

客户端产物路径：

/root/node_${remark}.txt：保存给客户端连接的完整 vless:// 链接。

/root/node_${remark}.png：自动生成的手机端扫码二维码图片。

🔄 三、 模块二：中转节点（Docker Xray + Gost）相关文件
中转节点采用 Docker 容器化隔离管理，每个节点拥有独立的独立工作目录。

独立工作目录：/opt/relay-${NODE_KEY}/

逻辑：根据节点别名的 MD5 哈希缩写创建的专属文件夹，每个节点隔离。

目录内部核心文件：

server.env：记录该中转节点的完整环境变量（别名、内外网端口、上游 IP/账号密码、Xray 公私钥等）。

config.json：挂载给 Docker 内 Xray 容器使用的配置文件。

Docker 容器实例：

gost-${NODE_KEY}：负责向下游/上游转发流量的 Gost 容器。

xray-${NODE_KEY}：负责对外提供 VLESS-REALITY 接入的 Xray 容器。

客户端产物路径：

/root/${NODE_ALIAS}-link.txt：中转节点的客户端导入链接。

/root/${NODE_ALIAS}-QR.png：中转节点的客户端二维码。

🛡️ 四、 远程云端联动层（API & 防撞池）
这部分不占用本地固定文件，通过 HTTP 请求与你的远程后端（API_URL）实时同步：

全局防撞端口池：

每次用户输入或随机分配端口时，脚本会向远程 API 发送请求，检查该端口是否在全网段的其他服务器或本机的历史记录中被占用，防止端口冲突。

节点大盘联动：

每次新建、修改或销毁节点时，脚本会自动把当前服务器 IP、端口、别名以及客户端链接（node_add / node_remove）同步到云端数据库，方便你在后台大盘统一查看。
