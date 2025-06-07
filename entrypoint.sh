#!/bin/bash

# 设置工作目录
INSTALL_DIR="/opt/.agsb"
cd ${INSTALL_DIR}

# 定义文件路径
CONFIG_FILE="${INSTALL_DIR}/config.json"
SB_CONFIG_FILE="${INSTALL_DIR}/sb.json"
SB_LOG="${INSTALL_DIR}/sb.log"
ARGO_LOG="${INSTALL_DIR}/argo.log"
LIST_FILE="${INSTALL_DIR}/list.txt"
JH_FILE="${INSTALL_DIR}/jh.txt"
ALLNODES_FILE="${INSTALL_DIR}/allnodes.txt"
SBPID_FILE="${INSTALL_DIR}/sbpid.log"
SBARGOPID_FILE="${INSTALL_DIR}/sbargopid.log"

# --- 1. 生成或加载配置 ---
# 优先从环境变量读取 VMESS_PORT
if [ -n "${VMESS_PORT}" ]; then
    echo "VMESS_PORT environment variable detected: ${VMESS_PORT}"
    # 如果 config.json 存在，读取 UUID 但不覆盖端口
    if [ -f "${CONFIG_FILE}" ]; then
        UUID=$(jq -r '.uuid' "${CONFIG_FILE}")
        echo "Loaded existing UUID from config.json: ${UUID}"
    else
        # 如果 config.json 不存在，生成新的 UUID
        UUID=$(cat /proc/sys/kernel/random/uuid)
        echo "Config file not found. Generating new UUID: ${UUID}"
    fi
    # 强制将 UUID 和环境中的 VMESS_PORT 保存到 config.json (覆盖或新建)
    jq -n \
        --arg uuid "$UUID" \
        --argjson vmess_port "$VMESS_PORT" \
        '{uuid: $uuid, vmess_port: $vmess_port}' > "${CONFIG_FILE}"
    echo "Using VMESS_PORT from environment: ${VMESS_PORT}"
else
    # 如果环境变量没有指定，检查 config.json
    if [ ! -f "${CONFIG_FILE}" ]; then
        echo "Config file not found. Generating new UUID and random port..."
        # 生成随机 UUID
        UUID=$(cat /proc/sys/kernel/random/uuid)
        # 生成 10000 到 60000 之间的随机端口
        VMESS_PORT=$(shuf -i 10000-60000 -n 1)

        # 将 UUID 和端口保存到 config.json
        jq -n \
            --arg uuid "$UUID" \
            --argjson vmess_port "$VMESS_PORT" \
            '{uuid: $uuid, vmess_port: $vmess_port}' > "${CONFIG_FILE}"
        echo "Generated config: UUID=${UUID}, VMESS_PORT=${VMESS_PORT}"
    else
        echo "Config file found. Loading existing UUID and port from config.json..."
        UUID=$(jq -r '.uuid' "${CONFIG_FILE}")
        VMESS_PORT=$(jq -r '.vmess_port' "${CONFIG_FILE}")
        echo "Loaded config: UUID=${UUID}, VMESS_PORT=${VMESS_PORT}"
    fi
fi


# --- 2. 生成 sing-box 配置文件 (sb.json) ---
echo "Generating sing-box config (sb.json)..."
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
                "type": "vmess",
                "listen": "127.0.0.1",
                "listen_port": $vmess_port,
                "users": [
                    {
                        "uuid": $uuid,
                        "alterId": 0
                    }
                ],
                "transport": {
                    "type": "ws",
                    "path": "/" + $uuid + "-vm?ed=2048",
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
./cloudflared tunnel --url "http://localhost:${VMESS_PORT}/${UUID}-vm?ed=2048" > "${ARGO_LOG}" 2>&1 &
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

# --- 6. 生成节点链接 ---
echo "Generating node links..."

# Cloudflare 的常见边缘 IP (这些可以根据需要更新或扩展)
CF_IPS=(
    "104.16.1.0"   # Example: Toronto
    "104.16.2.0"   # Example: Frankfurt
    "104.16.3.0"   # Example: Singapore
    "104.16.4.0"   # Example: Sydney
    "104.16.5.0"   # Example: Tokyo
    "104.16.6.0"   # Example: London
    "104.16.7.0"   # Example: New York
    "104.16.8.0"   # Example: San Francisco
    "104.16.9.0"   # Example: Paris
    "104.16.10.0"  # Example: Mumbai
    "104.16.11.0"  # Example: Rio de Janeiro
    "104.16.12.0"  # Example: Johannesburg
    "104.16.13.0"  # Example: Dubai
    "104.16.14.0"  # Example: Warsaw
)

# 清空之前的节点文件
> "${LIST_FILE}"
> "${JH_FILE}"
> "${ALLNODES_FILE}"

VMESS_WS_PATH="/${UUID}-vm"
TLS_SNI="${TUNNEL_DOMAIN}" # SNI 设置为隧道域名

# TLS 端口
TLS_PORTS=(443 8443 2053 2083 2087)
# 非 TLS 端口
NON_TLS_PORTS=(80 8080 8880)

# 生成带 TLS 的节点链接
for port in "${TLS_PORTS[@]}"; do
    for ip in "${CF_IPS[@]}"; do
        JSON_CONFIG=$(jq -n \
            --arg v "2" \
            --arg ps "CF-TLS-${port}-${ip}" \
            --arg add "${ip}" \
            --argjson port "$port" \
            --arg id "${UUID}" \
            --argjson aid 0 \
            --arg net "ws" \
            --arg type "none" \
            --arg host "${TLS_SNI}" \
            --arg path "${VMESS_WS_PATH}?ed=2048" \
            --arg tls "tls" \
            '{v: $v, ps: $ps, add: $add, port: $port, id: $id, aid: $aid, net: $net, type: $type, host: $host, path: $path, tls: $tls}')
        
        ENCODED_LINK="vmess://$(echo -n "${JSON_CONFIG}" | base64 -w 0)"
        echo "${ENCODED_LINK}" >> "${JH_FILE}"
        echo "${ENCODED_LINK}" >> "${ALLNODES_FILE}"
        echo "Generated: ${ENCODED_LINK}" >> "${LIST_FILE}"
    done
done

# 生成不带 TLS 的节点链接 (如果需要)
for port in "${NON_TLS_PORTS[@]}"; do
    for ip in "${CF_IPS[@]}"; do
        JSON_CONFIG=$(jq -n \
            --arg v "2" \
            --arg ps "CF-NON-TLS-${port}-${ip}" \
            --arg add "${ip}" \
            --argjson port "$port" \
            --arg id "${UUID}" \
            --argjson aid 0 \
            --arg net "ws" \
            --arg type "none" \
            --arg host "${TLS_SNI}" \
            --arg path "${VMESS_WS_PATH}?ed=2048" \
            '{v: $v, ps: $ps, add: $add, port: $port, id: $id, aid: $aid, net: $net, type: $type, host: $host, path: $path}')
        
        ENCODED_LINK="vmess://$(echo -n "${JSON_CONFIG}" | base64 -w 0)"
        echo "${ENCODED_LINK}" >> "${JH_FILE}"
        echo "${ENCODED_LINK}" >> "${ALLNODES_FILE}"
        echo "Generated: ${ENCODED_LINK}" >> "${LIST_FILE}"
    done
done

echo ""
echo "-------------------------------------"
echo "VMess Service Started Successfully!"
echo "Cloudflare Tunnel Domain: ${TUNNEL_DOMAIN}"
echo "Your UUID: ${UUID}"
echo "VMess Listen Port (internal): ${VMESS_PORT}"
echo "-------------------------------------"
echo "Generated Node Links (jh.txt):"
cat "${JH_FILE}"
echo "-------------------------------------"
echo "Detailed Node Info (list.txt):"
cat "${LIST_FILE}"
echo "-------------------------------------"

# 保持容器运行
wait $(cat "${SBPID_FILE}") $(cat "${SBARGOPID_FILE}")
echo "One of the services (sing-box or cloudflared) exited. Container stopping."
