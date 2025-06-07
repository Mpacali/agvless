#!/bin/bash

# 设置工作目录
INSTALL_DIR="/opt/.agsb"
cd ${INSTALL_DIR}

# 定义文件路径
CONFIG_FILE="${INSTALL_DIR}/config.json"
SB_CONFIG_FILE="${INSTALL_DIR}/sb.json"
SB_LOG="${INSTALL_DIR}/sb.log"
ARGO_LOG="${INSTALL_DIR}/argo.log"
NODE_LINK_FILE="${INSTALL_DIR}/vless_link.txt" # 新增，只保存 VLESS 链接
SBPID_FILE="${INSTALL_DIR}/sbpid.log"
SBARGOPID_FILE="${INSTALL_DIR}/sbargopid.log"

# 固定 VMESS/VLESS 监听端口
VMESS_PORT=3000 # 将端口固定为 3000

# --- 1. 生成或加载配置 ---
# 优先从 config.json 读取 UUID。如果不存在，则生成新的。
if [ ! -f "${CONFIG_FILE}" ]; then
    echo "Config file not found. Generating new UUID..."
    UUID=$(cat /proc/sys/kernel/random/uuid)
    # 将 UUID 和固定端口保存到 config.json
    jq -n \
        --arg uuid "$UUID" \
        --argjson vmess_port "$VMESS_PORT" \
        '{uuid: $uuid, vmess_port: $vmess_port}' > "${CONFIG_FILE}"
    echo "Generated config: UUID=${UUID}, VMESS_PORT=${VMESS_PORT}"
else
    echo "Config file found. Loading existing UUID..."
    UUID=$(jq -r '.uuid' "${CONFIG_FILE}")
    # 强制更新 config.json 中的端口为 3000，以防旧文件使用不同端口
    jq \
        --argjson vmess_port "$VMESS_PORT" \
        '.vmess_port = $vmess_port' "${CONFIG_FILE}" > "${CONFIG_FILE}.tmp" && \
    mv "${CONFIG_FILE}.tmp" "${CONFIG_FILE}"

    echo "Loaded config: UUID=${UUID}, VMESS_PORT=${VMESS_PORT}"
fi

# --- 2. 生成 sing-box 配置文件 (sb.json) ---
echo "Generating sing-box config (sb.json) for VLESS-WS-TLS..."
jq -n \
    --arg uuid "$UUID" \
    --argjson vmess_port "$VMESS_PORT" \
    '{
        "log": {
            "level": "info",
            "timestamp": true
        },
        "inbounds": [
            {
                "type": "vless",
                "listen": "127.0.0.1",
                "listen_port": $vmess_port,
                "users": [
                    {
                        "uuid": $uuid,
                        "flow": "xtls-rprx-vision" # VLESS 推荐流控
                    }
                ],
                "tls": null, # sing-box 本地不处理 TLS
                "transport": {
                    "type": "ws",
                    "path": "/" + $uuid + "-vless?ed=2048", # VLESS 路径
                    "headers": {
                        "Host": "bengbeng-cloudflared-sb.com"
                    }
                },
                "udp_fallback": null,
                "sniff": {
                    "enabled": true,
                    "routes": [
                        {
                            "port": 80,
                            "destination": "proxy"
                        },
                        {
                            "port": 443,
                            "destination": "proxy"
                        }
                    ]
                }
            }
        ],
        "outbounds": [
            {
                "type": "direct"
            },
            {
                "type": "block"
            }
        ]
    }' > "${SB_CONFIG_FILE}"

# --- 3. 启动 sing-box ---
echo "Starting sing-box..."
./sing-box -D run -c "${SB_CONFIG_FILE}" > "${SB_LOG}" 2>&1 &
echo $! > "${SBPID_FILE}" # 记录 sing-box 进程 ID
echo "sing-box started with PID $(cat ${SBPID_FILE})"

# --- 4. 启动 cloudflared Tunnel ---
echo "Starting cloudflared tunnel..."
# cloudflared 会在标准输出打印日志，我们可以重定向到 ARGO_LOG
./cloudflared tunnel --url "http://localhost:${VMESS_PORT}/${UUID}-vless?ed=2048" > "${ARGO_LOG}" 2>&1 &
echo $! > "${SBARGOPID_FILE}" # 记录 cloudflared 进程 ID
echo "cloudflared started with PID $(cat ${SBARGOPID_FILE})"

# --- 5. 获取 Tunnel 域名 ---
TUNNEL_DOMAIN=""
echo "Waiting for Cloudflare Tunnel domain..."
for i in $(seq 1 60); do # 尝试 60 次，每次等待 1 秒 (总共 60 秒)
    sleep 1
    TUNNEL_DOMAIN=$(grep -Eo 'https://[^ ]+\.trycloudflare\.com' "${ARGO_LOG}" | head -n 1 | sed 's|^https://||')
    if [ -n "${TUNNEL_DOMAIN}" ]; then
        echo "Cloudflare Tunnel domain: ${TUNNEL_DOMAIN}"
        break
    fi
    echo "Attempt ${i}: Still waiting for Tunnel domain..."
done

if [ -z "${TUNNEL_DOMAIN}" ]; then
    echo "ERROR: Failed to get Cloudflare Tunnel domain after multiple attempts. Check argo.log for errors."
    cat "${ARGO_LOG}" # 打印日志帮助调试
    exit 1
fi

# --- 6. 生成 VLESS 节点链接 ---
echo "Generating VLESS node links..."

# Cloudflare 的常见边缘 IP (这些可以根据需要更新或扩展)
# 对于 Argo 隧道，实际上客户端连接的是 Cloudflare 的任何边缘节点，这些 IP 列表主要是用于辅助客户端直连测试
CF_IPS=(
    "104.16.1.0"
    "104.16.2.0"
    "104.16.3.0"
    "104.16.4.0"
    "104.16.5.0"
    "104.16.6.0"
    "104.16.7.0"
    "104.16.8.0"
    "104.16.9.0"
    "104.16.10.0"
    "104.16.11.0"
    "104.16.12.0"
    "104.16.13.0"
    "104.16.14.0"
)

# 清空之前的节点文件
> "${NODE_LINK_FILE}"

VLESS_WS_PATH="/${UUID}-vless?ed=2048" # VLESS 的 WebSocket 路径
TLS_SNI="${TUNNEL_DOMAIN}" # SNI 设置为隧道域名
TLS_PORT=443 # 客户端连接 Cloudflare 边缘通常使用 443 端口

# 生成 VLESS-WS-TLS-Argo 节点链接
for ip in "${CF_IPS[@]}"; do
    # VLESS 链接格式：vless://UUID@Address:Port?params#Remark
    # params 示例: type=ws&host=TUNNEL_DOMAIN&path=/UUID-vless?ed=2048&security=tls&flow=xtls-rprx-vision
    ENCODED_PARAMS="type=ws&host=${TLS_SNI}&path=${VLESS_WS_PATH}&security=tls&flow=xtls-rprx-vision"
    VLESS_LINK="vless://${UUID}@${ip}:${TLS_PORT}?${ENCODED_PARAMS}#CF-VLESS-WS-TLS-${ip}"
    
    echo "${VLESS_LINK}" >> "${NODE_LINK_FILE}"
done

echo ""
echo "-------------------------------------"
echo "VLESS Service Started Successfully!"
echo "Cloudflare Tunnel Domain: ${TUNNEL_DOMAIN}"
echo "Your UUID: ${UUID}"
echo "VLESS Listen Port (internal): ${VMESS_PORT}"
echo "-------------------------------------"
echo "Generated VLESS Node Links (${NODE_LINK_FILE}):"
cat "${NODE_LINK_FILE}"
echo "-------------------------------------"

# 保持容器运行
wait $(cat "${SBPID_FILE}") $(cat "${SBARGOPID_FILE}")
echo "One of the services (sing-box or cloudflared) exited. Container stopping."
