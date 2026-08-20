#!/bin/bash
set -e

# ================= 引入本地独立配置（防 Git 泄露 + 自动引导） =================
CONFIG_FILE="/root/yahaidajian.sh"
if [ -f "$CONFIG_FILE" ]; then
    source "$CONFIG_FILE"
else
    echo "=========================================="
    echo "  ⚠️ 检测到本地未配置云端 API 参数"
    echo "=========================================="
    read -p "请输入云端 API 地址 (例如 https://yourdomain.com/api.php): " input_url
    read -p "请输入云端 API 密钥 (Token): " input_token
    if [ -z "$input_url" ] || [ -z "$input_token" ]; then
            echo "❌ 错误: API_URL 或 API_TOKEN 不能为空！"
            exit 1
        fi
    cat <<EOT > "$CONFIG_FILE"
API_URL="$input_url"
API_TOKEN="$input_token"
EOT
    chmod 600 "$CONFIG_FILE"
    echo "✅ 配置文件已自动创建并写入至 $CONFIG_FILE"
    source "$CONFIG_FILE"
fi

# 检查变量是否加载成功
[ -z "$API_URL" ] || [ -z "$API_TOKEN" ] && { echo "❌ 配置文件中 API_URL 或 API_TOKEN 为空！"; exit 1; }
# =================================================================

EXPORT_DIR="/root"
CONFIG_DIR="/usr/local/etc/xray"

enable_bbr() {
    if ! sysctl net.ipv4.tcp_congestion_control | grep -q "bbr"; then
        cat <<EOT >> /etc/sysctl.conf
net.core.default_qdisc=fq
net.ipv4.tcp_congestion_control=bbr
net.ipv4.tcp_rmem=4096 87380 67108864
net.ipv4.tcp_wmem=4096 65536 67108864
net.core.rmem_max=67108864
net.core.wmem_max=67108864
EOT
        sysctl -p >/dev/null 2>&1 || true
    fi
}

install_dependencies() {
    echo "=========================================="
    echo "        🔍 正在检查本地运行环境..."
    echo "=========================================="
    
    for tool in python3 qrencode curl jq; do
        if ! command -v "$tool" >/dev/null 2>&1; then
            echo "📦 检测到缺失工具 [$tool]，正在自动安装..."
            apt-get update -y && apt-get install -y "$tool" || yum install -y "$tool"
        else
            echo "✅ 本地环境 [ $tool ] 已就绪"
        fi
    done

    if ! command -v docker >/dev/null 2>&1; then
        echo "🐳 检测到 Docker 未安装，正在自动部署..."
        curl -fsSL https://get.docker.com | bash
        systemctl start docker
        systemctl enable docker
    else
        echo "✅ 本地环境 [ Docker ] 已就绪"
    fi

    mkdir -p "$CONFIG_DIR"
    enable_bbr
    echo "=========================================="
}

pause() {
    echo ""
    read -p "📌 按回车键继续..."
}

# =========================================================
# 云端 API 核心交互函数 (统一适配 GET 方式与 URL 传参)
# =========================================================
call_api() {
    local action="$1"
    local extra_params="$2" # 传入的附加参数，例如 "port=10000&node_type=direct"
    
    local target_url="${API_URL}?token=${API_TOKEN}&action=${action}"
    if [ -n "$extra_params" ]; then
        target_url="${target_url}&${extra_params}"
    fi
    
    curl -sS --max-time 3 "$target_url"
}

get_server_ip() {
    curl -sS --max-time 5 https://api.ipify.org || echo "127.0.0.1"
}

check_port_used() {
    local p="$1"
    if ss -lntp 2>/dev/null | grep -qE ":${p}[[:space:]]"; then
        return 0
    fi
    local res
    res=$(call_api "list" || echo "")
    if echo "$res" | tr '[:space:]' '\n' | grep -q "^${p}$"; then
        return 0
    fi
    return 1
}

add_port_log() {
    local p="$1"
    [ -z "$p" ] && return
    call_api "add" "port=${p}" >/dev/null 2>&1 || true
}

remove_port_log() {
    local p="$1"
    [ -z "$p" ] && return
    call_api "remove" "port=${p}" >/dev/null 2>&1 || true
}

sync_node_to_cloud() {
    local port="$1"
    local name="$2"
    local link="$3"
    local server_ip
    server_ip=$(get_server_ip)
    [ -z "$port" ] && return
    
    local encoded_params
    encoded_params=$(python3 - <<PY
import urllib.parse
s = urllib.parse.quote("""${server_ip}""")
p = urllib.parse.quote("""${port}""")
n = urllib.parse.quote("""${name}""")
l = urllib.parse.quote("""${link}""")
print(f"server={s}&port={p}&name={n}&link={l}")
PY
)
    call_api "node_add" "$encoded_params" >/dev/null 2>&1 || true
}

remove_node_from_cloud() {
    local port="$1"
    local server_ip
    server_ip=$(get_server_ip)
    [ -z "$port" ] && return
    call_api "node_remove" "server=${server_ip}&port=${port}" >/dev/null 2>&1 || true
}

manual_add_port() {
    echo -e "\n--- 批量添加已占用端口 ---"
    echo "👉 支持一次性粘贴多个端口，用空格、逗号分隔 (例: 80 443, 10000-10005)"
    read -p "请输入要绑定的端口号: " input_ports
    [ -z "$input_ports" ] && { echo "❌ 未输入任何端口。"; return; }

    formatted_input=$(echo "$input_ports" | tr ',' ' ')
    count=0
    for item in $formatted_input; do
        if [[ "$item" =~ ^([0-9]+)-([0-9]+)$ ]]; then
            for ((p=${BASH_REMATCH[1]}; p<=${BASH_REMATCH[2]}; p++)); do
                add_port_log "$p"; count=$((count+1))
            done
        elif [[ "$item" =~ ^[0-9]+$ ]]; then
            add_port_log "$item"; count=$((count+1))
        fi
    done
    echo "✅ 成功将 ${count} 个端口同步至远程全局防撞池！"
}

view_port_pool() {
    echo -e "\n=========================================="
    echo "        🛡️ 远程全局防撞端口池记录"
    echo "=========================================="
    local list
    list=$(call_api "list" || echo "")
    if [ -z "$list" ]; then
        echo "⚠️ 当前远程防撞池为空或连接 API 失败。"
    else
        local clean_list
        clean_list=$(echo "$list" | tr '[:space:]' '\n' | grep -E '^[0-9]+$' | sort -n | uniq)
        local count
        count=$(echo "$clean_list" | grep -c '^' || echo "0")
        
        echo "📊 当前远程防撞池共占用：${count} 个端口"
        echo "------------------------------------------"
        if [ "$count" -gt 0 ]; then
            echo "$clean_list" | awk '{print "    [端口] " $0}'
        else
            echo "    (暂无有效端口记录)"
        fi
    fi
    echo "=========================================="
}

get_node_key() {
    echo "$1" | md5sum | head -c 8
}

# =========================================================
# 模块一：直连节点管理
# =========================================================
direct_list_nodes() {
    echo -e "\n=========================================================================="
    echo "                          📊 已搭建的直连节点列表                          "
    echo "=========================================================================="
    shopt -s nullglob; files=("${EXPORT_DIR}"/node_*.txt); shopt -u nullglob

    if [ ${#files[@]} -eq 0 ]; then
        echo "当前未找到任何已搭建的直连节点。"
        DIRECT_TOTAL=0
        return
    fi

    i=1
    for file in "${files[@]}"; do
        create_time=$(stat -c "%y" "$file" 2>/dev/null | cut -d'.' -f1 || echo "未知时间")
        link=$(cat "$file" 2>/dev/null)
        port=$(echo "$link" | sed -n 's/.*:\([0-9]*\)?.*/\1/p')
        alias_name=$(echo "$link" | awk -F'#' '{print $2}')
        [ -z "$port" ] && port="未知"
        [ -z "$alias_name" ] && alias_name=$(basename "$file" .txt | sed 's/^node_//')

        if [ "$port" != "未知" ] && ss -lntp 2>/dev/null | grep -q ":${port}[[:space:]]"; then
            status_text="🟢 运行正常"
        else
            status_text="🔴 未运行"
        fi

        echo " [$i] 别名: ${alias_name} | 端口: ${port} | 状态: ${status_text} | 时间: ${create_time}"
        echo "--------------------------------------------------------------------------"
        eval "DNODE_${i}_FILE=\"$file\""; eval "DNODE_${i}_ALIAS=\"$alias_name\""; eval "DNODE_${i}_PORT=\"$port\""
        i=$((i+1))
    done
    DIRECT_TOTAL=$((i-1))
}

direct_select_node() {
    direct_list_nodes
    [ "$DIRECT_TOTAL" -eq 0 ] && return 1
    read -p "请输入要操作的节点序号 (1-$DIRECT_TOTAL): " num
    if ! [[ "$num" =~ ^[0-9]+$ ]] || [ "$num" -lt 1 ] || [ "$num" -gt "$DIRECT_TOTAL" ]; then
        echo "❌ 无效的选择。"; return 1
    fi
    eval "SELECTED_D_FILE=\$DNODE_${num}_FILE"; eval "SELECTED_D_ALIAS=\$DNODE_${num}_ALIAS"; eval "SELECTED_D_PORT=\$DNODE_${num}_PORT"
    return 0
}

direct_create_node() {
    echo -e "\n--- 新建 VLESS-REALITY 直连节点 ---"
    read -p "1. 请输入节点别名前缀 (例如 美国807-): " user_remark
    [ -z "$user_remark" ] && user_remark="节点-"
    read -p "2. 请输入对应的伪装域名或 IP (例如 us1.5898519.xyz): " server_address
    [ -z "$server_address" ] && server_address="us.5898519.xyz"

    while true; do
        read -p "3. 请输入监听端口 (留空自动生成 20000-39999 随机可用端口): " port
        if [ -z "$port" ]; then
            for i in {1..20}; do
                candidate=$((RANDOM % 20000 + 20000))
                if ! check_port_used "$candidate"; then port=$candidate; break; fi
            done
            [ -z "$port" ] && port=$((RANDOM % 20000 + 20000))
            echo "-> 自动分配可用端口: ${port}"
            break
        else
            if check_port_used "$port"; then
                echo "❌ 警告：端口 ${port} 在远程防撞池或系统中已被占用！"
            else
                break
            fi
        fi
    done

    remark="${user_remark}${port}"
    if [ ! -f "/usr/local/bin/xray" ]; then
        echo "正在下载 Xray 核心..."
        mkdir -p /tmp/xray && cd /tmp/xray
        curl -L -o xray.zip https://github.com/XTLS/Xray-core/releases/latest/download/Xray-linux-64.zip
        unzip -o xray.zip && mv xray /usr/local/bin/xray && chmod +x /usr/local/bin/xray && cd /root
    fi

    UUID=$(/usr/local/bin/xray uuid 2>/dev/null || python3 -c 'import uuid; print(uuid.uuid4())')
    RAW_KEYS=$(/usr/local/bin/xray x25519)
    PRI_KEY=$(echo "$RAW_KEYS" | grep -i "Private" | awk -F': ' '{print $2}' | tr -d ' \r\n\t')
    PUB_KEY=$(echo "$RAW_KEYS" | grep -i "Public" | awk -F': ' '{print $2}' | tr -d ' \r\n\t')
    [ -z "$PRI_KEY" ] && { PRI_KEY=$(echo "$RAW_KEYS" | head -n 1 | awk '{print $NF}' | tr -d ' \r\n\t'); PUB_KEY=$(echo "$RAW_KEYS" | tail -n 1 | awk '{print $NF}' | tr -d ' \r\n\t'); }

    SHORT_ID=$(openssl rand -hex 8 | tr -d ' \r\n')
    DEST_DOMAIN="www.apple.com"
    SPECIFIC_CONFIG="${CONFIG_DIR}/config_${port}.json"

    python3 -c '
import json
config = {
  "log": {"loglevel": "warning"},
  "inbounds": [{
    "port": int("'"$port"'"),
    "protocol": "vless",
    "settings": {"clients": [{"id": "'"$UUID"'"}], "decryption": "none"},
    "streamSettings": {"network": "tcp", "security": "reality", "realitySettings": {"show": False, "dest": "'"$DEST_DOMAIN"':443", "xver": 0, "serverNames": ["'"$DEST_DOMAIN"'"], "privateKey": "'"$PRI_KEY"'", "shortIds": ["'"$SHORT_ID"'"]}}
  }],
  "outbounds": [{"protocol": "freedom"}]
}
with open("'"$SPECIFIC_CONFIG"'", "w") as f: json.dump(config, f, indent=2)
' 2>/dev/null || true

    nohup /usr/local/bin/xray run -config "$SPECIFIC_CONFIG" > /root/xray_${port}.log 2>&1 &
    sleep 2

    VLESS_LINK="vless://${UUID}@${server_address}:${port}?encryption=none&security=reality&sni=${DEST_DOMAIN}&fp=chrome&pbk=${PUB_KEY}&sid=${SHORT_ID}&type=tcp#${remark}"
    TXT_FILE="${EXPORT_DIR}/node_${remark}.txt"
    QR_FILE="${EXPORT_DIR}/node_${remark}.png"
    echo "$VLESS_LINK" > "$TXT_FILE"
    qrencode -o "$QR_FILE" "$VLESS_LINK" 2>/dev/null || true

    add_port_log "$port"
    sync_node_to_cloud "$port" "$remark" "$VLESS_LINK"
    echo "✅ 直连节点部署成功！端口 ${port} 已同步至远程防撞池与云端大盘。链接: $VLESS_LINK"
}

direct_stop_node() {
    if direct_select_node; then
        pkill -f "xray.*config_${SELECTED_D_PORT}.json" 2>/dev/null || true
        echo "⏸️ 直连节点 [${SELECTED_D_ALIAS}] 已暂停！"
    fi
}

direct_start_node() {
    if direct_select_node; then
        config_path="${CONFIG_DIR}/config_${SELECTED_D_PORT}.json"
        pkill -f "xray.*config_${SELECTED_D_PORT}.json" 2>/dev/null || true
        nohup /usr/local/bin/xray run -config "$config_path" > /root/xray_${SELECTED_D_PORT}.log 2>&1 &
        echo "🟢 直连节点 [${SELECTED_D_ALIAS}] 已恢复运行！"
    fi
}

direct_delete_node() {
    if direct_select_node; then
        read -p "⚠️ 确认销毁直连节点 [${SELECTED_D_ALIAS}] 吗？(y/N): " confirm
        if [[ "$confirm" =~ ^[Yy]$ ]]; then
            pkill -f "xray.*config_${SELECTED_D_PORT}.json" 2>/dev/null || true
            rm -f "$SELECTED_D_FILE" "${SELECTED_D_FILE%.txt}.png" "${CONFIG_DIR}/config_${SELECTED_D_PORT}.json"
            [ -n "$SELECTED_D_PORT" ] && remove_port_log "$SELECTED_D_PORT"
            [ -n "$SELECTED_D_PORT" ] && remove_node_from_cloud "$SELECTED_D_PORT"
            echo "🗑️ 直连节点已销毁，远程防撞池端口与云端大盘记录已同步清理！"
        fi
    fi
}

# =========================================================
# 模块二：中转节点管理
# =========================================================
relay_list_nodes() {
    echo -e "\n=========================================================================================="
    echo "                                       📊 已搭建的中转节点列表                                    "
    echo "=========================================================================================="
    DIRS=$(ls -d /opt/relay-* 2>/dev/null || true)
    if [ -z "$DIRS" ]; then
        echo "当前未找到任何中转节点。"
        RELAY_TOTAL=0
        return
    fi

    printf "%-6s %-25s %-10s %-12s %-12s %-20s\n" "序号" "节点别名" "对外端口" "GOST状态" "Xray状态" "配置目录"
    echo "------------------------------------------------------------------------------------------"
    i=1
    for dir in $DIRS; do
        if [ -f "$dir/server.env" ]; then
            alias_name=$(grep "^NODE_ALIAS=" "$dir/server.env" | cut -d'=' -f2 | tr -d '"')
            xray_port=$(grep "^XRAY_PORT=" "$dir/server.env" | cut -d'=' -f2 | tr -d '"')
            key=$(basename "$dir" | sed 's/relay-//')
            gost_status=$(docker inspect -f '{{.State.Status}}' "gost-${key}" 2>/dev/null || echo "未运行")
            xray_status=$(docker inspect -f '{{.State.Status}}' "xray-${key}" 2>/dev/null || echo "未运行")
            [ -n "$xray_port" ] && add_port_log "$xray_port"

            printf "%-6s %-25s %-10s %-12s %-12s %-20s\n" "[$i]" "${alias_name:-未知}" "${xray_port:-未知}" "$gost_status" "$xray_status" "$dir"
            eval "RNODE_${i}_DIR=\"$dir\""; eval "RNODE_${i}_ALIAS=\"${alias_name}\""
            eval "RNODE_${i}_KEY=\"$key\""; eval "RNODE_${i}_PORT=\"$xray_port\""
            i=$((i+1))
        fi
    done
    RELAY_TOTAL=$((i-1))
}

relay_select_node() {
    relay_list_nodes
    [ "$RELAY_TOTAL" -eq 0 ] && return 1
    read -p "请输入要操作的节点序号 (1-$RELAY_TOTAL): " num
    if ! [[ "$num" =~ ^[0-9]+$ ]] || [ "$num" -lt 1 ] || [ "$num" -gt "$RELAY_TOTAL" ]; then
        echo "❌ 无效的选择。"; return 1
    fi
    eval "SELECTED_R_DIR=\$RNODE_${num}_DIR"; eval "SELECTED_R_ALIAS=\$RNODE_${num}_ALIAS"
    eval "SELECTED_R_KEY=\$RNODE_${num}_KEY"; eval "SELECTED_R_PORT=\$RNODE_${num}_PORT"
    return 0
}

relay_create_node() {
    echo -e "\n--- 新建中转节点 ---"
    read -p "1. 请输入节点别名前缀 (例如 马来西亚住宅 / 日本 01): " user_alias_prefix
    [ -z "$user_alias_prefix" ] && user_alias_prefix="中转"
    read -p "2. 请输入你的伪装域名/服务器IP (例如 us1.5898519.xyz): " NODE_DOMAIN
    [ -z "$NODE_DOMAIN" ] && NODE_DOMAIN="$(curl -sS --max-time 5 https://api.ipify.org || echo "127.0.0.1")"

    echo -e "\n3. 请输入出口中转(上游)信息"
    echo "👉 支持一键粘贴格式: IP:端口:账号:密码 (例如 103.116.47.189:9270:user:pass)"
    read -p "    请输入: " RAW_UP_INFO

    if [[ "$RAW_UP_INFO" =~ ^([^:]+):([0-9]+):([^:]+):(.+)$ ]]; then
        MY_UP_HOST="${BASH_REMATCH[1]}"; MY_UP_PORT="${BASH_REMATCH[2]}"
        MY_UP_USER="${BASH_REMATCH[3]}"; MY_UP_PASS="${BASH_REMATCH[4]}"
        echo "-> 已识别一键格式: IP: ${MY_UP_HOST} | 端口: ${MY_UP_PORT} | 账号: ${MY_UP_USER} | 密码: ${MY_UP_PASS}"
    else
        MY_UP_HOST="$RAW_UP_INFO"
        read -p "    端口: " MY_UP_PORT
        read -p "    账号: " MY_UP_USER
        read -p "    密码: " MY_UP_PASS
    fi

    while true; do
        read -p "4. 请输入对外监听端口 (留空自动生成 20000-60000 随机可用端口): " XRAY_PORT
        if [ -z "$XRAY_PORT" ]; then
            for j in {1..20}; do
                candidate=$((RANDOM % 40001 + 20000))
                if ! check_port_used "$candidate"; then XRAY_PORT=$candidate; break; fi
            done
            [ -z "$XRAY_PORT" ] && XRAY_PORT=$((RANDOM % 40001 + 20000))
            echo "-> 自动分配可用端口: ${XRAY_PORT}"
            break
        else
            if check_port_used "$XRAY_PORT"; then
                echo "❌ 警告：端口 ${XRAY_PORT} 在远程防撞池或系统中已被占用！"
            else
                break
            fi
        fi
    done

    NODE_ALIAS="${user_alias_prefix}-${XRAY_PORT}"
    LOCAL_SOCKS_PORT=$((XRAY_PORT + 1000))
    while check_port_used "$LOCAL_SOCKS_PORT"; do
        LOCAL_SOCKS_PORT=$((RANDOM % 40001 + 20000))
    done

    NODE_KEY=$(get_node_key "$NODE_ALIAS")
    WORK_DIR="/opt/relay-${NODE_KEY}"
    mkdir -p "${WORK_DIR}"

    echo -e "\n正在开始部署，请稍候..."
    
    echo "正在测试网络连通性..."
    egress_ip=""
    country_code=""
    test_res=$(docker run --rm --network host -e ALL_PROXY="socks5://${MY_UP_USER}:${MY_UP_PASS}@${MY_UP_HOST}:${MY_UP_PORT}" curlimages/curl:latest curl -s --max-time 6 https://ipapi.co/json 2>/dev/null || echo "")
    if [ -n "$test_res" ]; then
        egress_ip=$(echo "$test_res" | grep -o '"ip":[^,]*' | awk -F'"' '{print $4}')
        country_code=$(echo "$test_res" | grep -o '"country_code":[^,]*' | awk -F'"' '{print $4}')
    fi

    XRAY_IMAGE="ghcr.io/xtls/xray-core:26.3.23"
    docker pull "$XRAY_IMAGE" >/dev/null 2>&1
    XRAY_UUID="$(python3 -c 'import uuid; print(uuid.uuid4())')"
    KEYS="$(docker run --rm "$XRAY_IMAGE" x25519)"
    XRAY_PRIVATE="$(echo "$KEYS" | grep -i "Private" | awk '{print $NF}')"
    XRAY_PUBLIC="$(echo "$KEYS" | grep -i "Public" | awk '{print $NF}')"
    XRAY_SHORT_ID="$(openssl rand -hex 8)"
    DEST_DOMAIN="www.apple.com"

    cat <<EOT > "${WORK_DIR}/server.env"
NODE_ALIAS="${NODE_ALIAS}"
NODE_DOMAIN="${NODE_DOMAIN}"
XRAY_PORT=${XRAY_PORT}
LOCAL_SOCKS_PORT=${LOCAL_SOCKS_PORT}
MY_UP_HOST=${MY_UP_HOST}
MY_UP_PORT=${MY_UP_PORT}
MY_UP_USER=${MY_UP_USER}
MY_UP_PASS=${MY_UP_PASS}
XRAY_IMAGE=${XRAY_IMAGE}
XRAY_UUID=${XRAY_UUID}
XRAY_PRIVATE=${XRAY_PRIVATE}
XRAY_PUBLIC=${XRAY_PUBLIC}
XRAY_SHORT_ID=${XRAY_SHORT_ID}
DEST_DOMAIN=${DEST_DOMAIN}
EOT
    chmod 600 "${WORK_DIR}/server.env"

    docker rm -f "gost-${NODE_KEY}" 2>/dev/null || true
    docker run -d --name "gost-${NODE_KEY}" --restart unless-stopped --network host gogost/gost:latest -L "socks5://127.0.0.1:${LOCAL_SOCKS_PORT}?udp=true" -F "socks5://${MY_UP_USER}:${MY_UP_PASS}@${MY_UP_HOST}:${MY_UP_PORT}?notls=true&udp=true" >/dev/null

    cat <<EOT > "${WORK_DIR}/config.json"
{
  "log": { "loglevel": "warning" },
  "inbounds": [{
    "port": ${XRAY_PORT}, "protocol": "vless",
    "settings": { "clients": [{ "id": "${XRAY_UUID}" }], "decryption": "none" },
    "streamSettings": { "network": "tcp", "security": "reality", "realitySettings": { "show": false, "dest": "${DEST_DOMAIN}:443", "xver": 0, "serverNames": ["${DEST_DOMAIN}"], "privateKey": "${XRAY_PRIVATE}", "shortIds": ["${XRAY_SHORT_ID}"] } }
  }],
  "outbounds": [{ "protocol": "socks", "settings": { "servers": [{ "address": "127.0.0.1", "port": ${LOCAL_SOCKS_PORT} }] } }]
}
EOT
    chmod 644 "${WORK_DIR}/config.json"

    docker rm -f "xray-${NODE_KEY}" 2>/dev/null || true
    docker run -d --name "xray-${NODE_KEY}" --restart unless-stopped --network host -v "${WORK_DIR}/config.json:/etc/xray/config.json:ro" "$XRAY_IMAGE" run -c /etc/xray/config.json >/dev/null

    LINK_FILE="/root/${NODE_ALIAS}-link.txt"
    QR_FILE="/root/${NODE_ALIAS}-QR.png"
    python3 - <<PY
import urllib.parse
params = "encryption=none&security=reality&sni=${DEST_DOMAIN}&fp=chrome&pbk=${XRAY_PUBLIC}&sid=${XRAY_SHORT_ID}&type=tcp&headerType=none"
alias = urllib.parse.quote("${NODE_ALIAS}", safe='')
link = f"vless://${XRAY_UUID}@${NODE_DOMAIN}:${XRAY_PORT}?{params}#{alias}"
with open("${LINK_FILE}", "w", encoding="utf-8") as f: f.write(link + "\n")
PY
    qrencode -o "${QR_FILE}" -s 10 "$(cat "${LINK_FILE}")" 2>/dev/null || true
    
    add_port_log "$XRAY_PORT"
    sync_node_to_cloud "$XRAY_PORT" "$NODE_ALIAS" "$(cat "${LINK_FILE}")"

    echo -e "\n=========================================="
    echo "🎉 中转节点 [${NODE_ALIAS}] 部署成功！"
    echo "=========================================="
    echo "对外监听端口: ${XRAY_PORT}"
    echo "出口实际 IP: ${egress_ip:-检测超时/直连}"
    echo "出口国家代码: ${country_code:-未知}"
    echo "=========================================="
    echo "【客户端一键 VLESS 链接】"
    cat "${LINK_FILE}"
    echo ""
    echo "二维码已保存至: ${QR_FILE}"
    echo "=========================================="
}

relay_modify_node_config() {
    if relay_select_node; then
        ENV_FILE="${SELECTED_R_DIR}/server.env"
        CONF_FILE="${SELECTED_R_DIR}/config.json"
        [ ! -f "$ENV_FILE" ] && return
        source "$ENV_FILE"

        echo -e "\n------------------------------------------"
        echo "🔧 当前选择的中转节点: [${NODE_ALIAS}]"
        echo " 1. 仅修改 UUID"
        echo " 2. 仅修改 对外监听端口"
        echo " 3. 同时修改 UUID 和 对外监听端口"
        echo " 0. 返回"
        read -p "请选择 (0-3): " mod_choice

        NEW_UUID="$XRAY_UUID"
        NEW_PORT="$XRAY_PORT"
        NEED_UPDATE=0

        case "$mod_choice" in
            1) NEW_UUID="$(python3 -c 'import uuid; print(uuid.uuid4())')"; NEED_UPDATE=1 ;;
            2|3)
                [ "$mod_choice" -eq 3 ] && NEW_UUID="$(python3 -c 'import uuid; print(uuid.uuid4())')"
                while true; do
                    read -p "请输入新的对外监听端口: " input_p
                    if [[ "$input_p" =~ ^[0-9]+$ ]] && [ "$input_p" -ge 1 ] && [ "$input_p" -le 65535 ]; then
                        if [ "$input_p" -ne "$XRAY_PORT" ] && check_port_used "$input_p"; then
                            echo "❌ 端口已被占用！"
                        else
                            NEW_PORT="$input_p"; NEED_UPDATE=1; break
                        fi
                    fi
                done
                ;;
            *) return ;;
        esac

        if [ "$NEED_UPDATE" -eq 1 ]; then
            if [ "$NEW_PORT" -ne "$XRAY_PORT" ]; then
                remove_port_log "$XRAY_PORT"
                remove_node_from_cloud "$XRAY_PORT"
                add_port_log "$NEW_PORT"
            fi
            [ -z "$DEST_DOMAIN" ] && DEST_DOMAIN="www.apple.com"

            sed -i "s/^XRAY_UUID=.*/XRAY_UUID=\"${NEW_UUID}\"/" "$ENV_FILE"
            sed -i "s/^XRAY_PORT=.*/XRAY_PORT=${NEW_PORT}/" "$ENV_FILE"
            
            cat <<EOT > "${CONF_FILE}"
{
  "log": { "loglevel": "warning" },
  "inbounds": [{
    "port": ${NEW_PORT}, "protocol": "vless",
    "settings": { "clients": [{ "id": "${NEW_UUID}" }], "decryption": "none" },
    "streamSettings": { "network": "tcp", "security": "reality", "realitySettings": { "show": false, "dest": "${DEST_DOMAIN}:443", "xver": 0, "serverNames": ["${DEST_DOMAIN}"], "privateKey": "${XRAY_PRIVATE}", "shortIds": ["${XRAY_SHORT_ID}"] } }
  }],
  "outbounds": [{ "protocol": "socks", "settings": { "servers": [{ "address": "127.0.0.1", "port": ${LOCAL_SOCKS_PORT} }] } }]
}
EOT
            docker restart "xray-${SELECTED_R_KEY}" >/dev/null

            LINK_FILE="/root/${NODE_ALIAS}-link.txt"
            python3 - <<PY
import urllib.parse
params = "encryption=none&security=reality&sni=${DEST_DOMAIN}&fp=chrome&pbk=${XRAY_PUBLIC}&sid=${XRAY_SHORT_ID}&type=tcp&headerType=none"
alias = urllib.parse.quote("${NODE_ALIAS}", safe='')
link = f"vless://${NEW_UUID}@${NODE_DOMAIN}:${NEW_PORT}?{params}#{alias}"
with open("${LINK_FILE}", "w", encoding="utf-8") as f: f.write(link + "\n")
PY
            sync_node_to_cloud "$NEW_PORT" "$NODE_ALIAS" "$(cat "${LINK_FILE}")"

            echo "✅ 中转节点配置修改成功，云端大盘已自动更新！"
        fi
    fi
}

relay_stop_node() { relay_select_node && docker stop "gost-${SELECTED_R_KEY}" "xray-${SELECTED_R_KEY}" 2>/dev/null && echo "✅ 中转已暂停"; }
relay_start_node() { relay_select_node && docker start "gost-${SELECTED_R_KEY}" "xray-${SELECTED_R_KEY}" 2>/dev/null && echo "✅ 中转已恢复"; }

relay_destroy_node() {
    if relay_select_node; then
        read -p "⚠️ 确认彻底销毁中转节点 [${SELECTED_R_ALIAS}] 吗？(y/N): " confirm
        if [[ "$confirm" =~ ^[Yy]$ ]]; then
            docker rm -f "gost-${SELECTED_R_KEY}" "xray-${SELECTED_R_KEY}" 2>/dev/null || true
            rm -rf "${SELECTED_R_DIR}" "/root/${SELECTED_R_ALIAS}-link.txt" "/root/${SELECTED_R_ALIAS}-QR.png"
            [ -n "$SELECTED_R_PORT" ] && remove_port_log "$SELECTED_R_PORT"
            [ -n "$SELECTED_R_PORT" ] && remove_node_from_cloud "$SELECTED_R_PORT"
            echo "🗑️ 中转节点已彻底销毁，远程防撞池与云端节点大盘记录已同步清理！"
        fi
    fi
}

relay_view_link() {
    if relay_select_node; then
        [ -f "/root/${SELECTED_R_ALIAS}-link.txt" ] && cat "/root/${SELECTED_R_ALIAS}-link.txt"
    fi
}

# =========================================================
# 菜单导航层
# =========================================================
direct_menu() {
    while true; do
        clear
        echo "=========================================="
        echo "    🌐 直连节点管理 (VLESS + REALITY)"
        echo "=========================================="
        echo "1. 查看直连节点列表"
        echo "2. 新建直连节点"
        echo "3. 暂停直连节点"
        echo "4. 恢复直连节点"
        echo "5. 销毁直连节点"
        echo "0. 返回主菜单"
        echo "=========================================="
        read -p "选择操作: " c
        case "$c" in
            1) direct_list_nodes; pause ;;
            2) direct_create_node; pause ;;
            3) direct_stop_node; pause ;;
            4) direct_start_node; pause ;;
            5) direct_delete_node; pause ;;
            0) break ;;
        esac
    done
}

relay_menu() {
    while true; do
        clear
        echo "=========================================="
        echo "    🔄 中转节点管理 (Docker Xray + Gost)"
        echo "=========================================="
        echo "1. 查看中转节点列表"
        echo "2. 新建中转节点"
        echo "3. 修改中转节点配置 (UUID / 端口)"
        echo "4. 暂停中转节点"
        echo "5. 恢复中转节点"
        echo "6. 销毁中转节点"
        echo "7. 查看中转节点链接"
        echo "0. 返回主菜单"
        echo "=========================================="
        read -p "选择操作: " c
        case "$c" in
            1) relay_list_nodes; pause ;;
            2) relay_create_node; pause ;;
            3) relay_modify_node_config; pause ;;
            4) relay_stop_node; pause ;;
            5) relay_start_node; pause ;;
            6) relay_destroy_node; pause ;;
            7) relay_view_link; pause ;;
            0) break ;;
        esac
    done
}

main_menu() {
    install_dependencies
    while true; do
        clear
        echo "=========================================="
        echo "        🚀 涯海跨境 综合节点管理面板        "
        echo "=========================================="
        echo " 1. 🌐 直连节点管理 (VLESS + REALITY)"
        echo " 2. 🔄 中转节点管理 (Docker Xray + Gost)"
        echo " 3. 🛡️ 批量添加已占用端口到远程防撞池"
        echo " 4. 🛡️ 查看远程全局防撞端口池记录"
        echo " 0. 退出脚本"
        echo "=========================================="
        read -p "请输入选项数字 (0-4): " choice
        case "$choice" in
            1) direct_menu ;;
            2) relay_menu ;;
            3) manual_add_port; pause ;;
            4) view_port_pool; pause ;;
            0) echo "已退出管理面板。"; exit 0 ;;
        esac
    done
}

main_menu
