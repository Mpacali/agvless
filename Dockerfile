#!/bin/bash
set -euo pipefail # 遇到错误立即退出，未设置变量也退出，管道符失败也退出

# --- 1. 定义环境变量和路径 ---
INSTALL_DIR="/opt/.agsb"
SINGBOX_BIN="${INSTALL_DIR}/sing-box"
CLOUDFLARED_BIN="${INSTALL_DIR}/cloudflared"
SBOX_CONFIG_FILE="${INSTALL_DIR}/config.json"

# Cloudflare Tunnel 相关的环境变量
# CLOUDFLARE_EMAIL: 你的 Cloudflare 邮箱 (首次登录时需要)
# CLOUDFLARE_API_KEY: 你的 Cloudflare Global API Key (首次登录时需要)
# CLOUDFLARE_TUNNEL_NAME: Cloudflare Tunnel 的名称，例如 "my-vless-tunnel"
# CLOUDFLARE_TUNNEL_DOMAIN: Cloudflare 托管的域名，例如 "example.com"
# CLOUDFLARE_TUNNEL_SUBDOMAIN: 用于 sing-box 的子域名，例如 "vless" (最终访问地址：vless.example.com)
# CLOUDFLARE_ZONE_ID: 你的 Cloudflare 区域 ID (如果 CLOUDFLARE_EMAIL/API_KEY 方式登录，可能需要)

# VLESS 配置
VLESS_PORT="${VLESS_PORT:-3000}" # VLESS 入站端口，默认 3000
VLESS_UUID="${VLESS_UUID:-$(cat /proc/sys/kernel/random/uuid)}" # VLESS UUID，如果未设置则随机生成
VLESS_PATH="${VLESS_PATH:-/vless}" # VLESS WebSocket Path

# 证书相关
CERT_DIR="${INSTALL_DIR}/certs"
CERT_KEY="${CERT_DIR}/private.key"
CERT_PEM="${CERT_DIR}/cert.pem"
mkdir -p "$CERT_DIR"

echo "========================================"
echo "         Starting AGSB Service          "
echo "========================================"
echo "VLESS UUID: ${VLESS_UUID}"
echo "VLESS Port: ${VLESS_PORT}"
echo "VLESS Path: ${VLESS_PATH}"
echo "Cloudflare Tunnel Name: ${CLOUDFLARE_TUNNEL_NAME}"
echo "Cloudflare Tunnel Subdomain: ${CLOUDFLARE_TUNNEL_SUBDOMAIN}.${CLOUDFLARE_TUNNEL_DOMAIN}"
echo "========================================"


# --- 2. 生成自签证书 ---
if [[ ! -f "$CERT_KEY" || ! -f "$CERT_PEM" ]]; then
    echo "Generating self-signed certificate..."
    openssl genrsa -out "$CERT_KEY" 2048
    openssl req -new -x509 -days 365 -key "$CERT_KEY" -out "$CERT_PEM" \
        -subj "/C=US/ST=Somewhere/L=City/O=MyOrg/CN=${CLOUDFLARE_TUNNEL_SUBDOMAIN}.${CLOUDFLARE_TUNNEL_DOMAIN}"
    echo "Self-signed certificate generated."
else
    echo "Self-signed certificate already exists. Skipping generation."
fi

# --- 3. 动态生成 sing-box 配置 ---
echo "Generating sing-box configuration..."
# 这里的配置仅包含 VLESS-WS-TLS 入站，你可以根据需要添加其他出站或路由规则
cat <<EOF > "$SBOX_CONFIG_FILE"
{
  "inbounds": [
    {
      "type": "vless",
      "tag": "vless-in",
      "listen": "0.0.0.0",
      "listen_port": ${VLESS_PORT},
      "users": [
        {
          "uuid": "${VLESS_UUID}",
          "flow": ""
        }
      ],
      "tls": {
        "enabled": true,
        "certificate_path": "${CERT_PEM}",
        "key_path": "${CERT_KEY}",
        "alpn": [ "http/1.1" ],
        "min_version": "1.2",
        "max_version": "1.3"
      },
      "websocket": {
        "enabled": true,
        "path": "${VLESS_PATH}",
        "headers": {
          "Host": "${CLOUDFLARE_TUNNEL_SUBDOMAIN}.${CLOUDFLARE_TUNNEL_DOMAIN}"
        }
      }
    }
  ],
  "outbounds": [
    {
      "type": "direct",
      "tag": "direct"
    },
    {
      "type": "block",
      "tag": "block"
    }
  ]
}
EOF
echo "Sing-box configuration generated at ${SBOX_CONFIG_FILE}"
# 验证 sing-box 配置
${SINGBOX_BIN} check -C "$SBOX_CONFIG_FILE"


# --- 4. 配置 Cloudflare Tunnel ---
# Cloudflare Tunnel 凭据目录 (重要：应挂载为 Docker Volume 以持久化)
TUNNEL_CRED_DIR="/etc/cloudflared" # 或者你挂载的卷路径
mkdir -p "$TUNNEL_CRED_DIR"

# 检查是否已登录 Cloudflare (如果 .cloudflared 目录中存在 config.yml 和 cert.pem)
# 注意：以下登录逻辑适用于首次运行，或当你希望每次启动都确保登录时
# 对于生产环境，更推荐在 Dockerfile build 阶段或通过 CI/CD 工具预先登录并挂载凭据。

if [[ -n "${CLOUDFLARE_EMAIL}" && -n "${CLOUDFLARE_API_KEY}" ]]; then
    echo "Logging into Cloudflare with API Key..."
    # 尝试登录并生成 ~/.cloudflared 目录下的凭据文件
    # 注意：此方式生成的凭据默认在 ~/.cloudflared，我们需要移动它
    HOME_TEMP="/tmp/cloudflared_home" # 临时 HOME 目录
    mkdir -p "$HOME_TEMP"
    # 使用 HOME 环境变量来控制 cloudflared 凭据的生成位置
    HOME="$HOME_TEMP" ${CLOUDFLARED_BIN} login --legacy
    
    # 查找生成的 config.yml 和 cert.pem，并移动到 TUNNEL_CRED_DIR
    FIND_CRED=$(find "$HOME_TEMP" -type f -name "config.yml" -print -quit)
    if [[ -n "$FIND_CRED" ]]; then
        cp -R "$(dirname "$FIND_CRED")"/* "$TUNNEL_CRED_DIR/"
        echo "Cloudflare credentials moved to ${TUNNEL_CRED_DIR}"
    else
        echo "Warning: Cloudflare login might have failed or credentials not found."
    fi
    rm -rf "$HOME_TEMP"
else
    echo "CLOUDFLARE_EMAIL or CLOUDFLARE_API_KEY not set. Assuming pre-existing Cloudflare login or credentials."
    echo "Ensure ${TUNNEL_CRED_DIR}/cert.pem and ${TUNNEL_CRED_DIR}/config.yml exist if using this method."
fi

# 获取 Tunnel ID
TUNNEL_ID=""
if [[ -f "${TUNNEL_CRED_DIR}/config.yml" ]]; then
    TUNNEL_ID=$(cat "${TUNNEL_CRED_DIR}/config.yml" | grep "tunnel:" | awk '{print $2}')
fi

if [[ -z "${TUNNEL_ID}" && -n "${CLOUDFLARE_TUNNEL_NAME}" ]]; then
    echo "Trying to create or fetch Cloudflare Tunnel '${CLOUDFLARE_TUNNEL_NAME}'..."
    # 使用 `cloudflared tunnel create` 创建或获取现有 tunnel 的信息
    # 注意：这里需要 cloudflared 能够访问你的 Cloudflare 账户，通常通过 /etc/cloudflared/cert.pem
    TUNNEL_INFO=$(${CLOUDFLARED_BIN} tunnel create "${CLOUDFLARE_TUNNEL_NAME}" --cred-file "${TUNNEL_CRED_DIR}/cert.pem" 2>&1)
    echo "$TUNNEL_INFO"

    # 从输出中提取 Tunnel ID
    TUNNEL_ID=$(echo "$TUNNEL_INFO" | grep "Tunnel ID:" | awk '{print $3}')
    if [[ -z "$TUNNEL_ID" ]]; then
        echo "Error: Could not create or find Cloudflare Tunnel ID for name '${CLOUDFLARE_TUNNEL_NAME}'. Exiting."
        exit 1
    fi
    echo "Cloudflare Tunnel ID: ${TUNNEL_ID}"

    # 保存 Tunnel 信息到 config.yml (如果 config.yml 还不存在或不完整)
    # cloudflared tunnel create 命令通常会更新 .cloudflared 目录下的 config.yml
    # 所以这一步通常是自动完成的，这里主要是为了确保我们有 ID
    if ! grep -q "tunnel: ${TUNNEL_ID}" "${TUNNEL_CRED_DIR}/config.yml"; then
        echo "Updating tunnel ID in ${TUNNEL_CRED_DIR}/config.yml"
        echo "tunnel: ${TUNNEL_ID}" >> "${TUNNEL_CRED_DIR}/config.yml"
        echo "credentials-file: ${TUNNEL_CRED_DIR}/${TUNNEL_ID}.json" >> "${TUNNEL_CRED_DIR}/config.yml"
    fi
fi

if [[ -z "${TUNNEL_ID}" ]]; then
    echo "Error: Cloudflare Tunnel ID not found. Please ensure CLOUDFLARE_TUNNEL_NAME is set or credentials are present."
    exit 1
fi

# 配置 Cloudflare Tunnel 的 ingress 规则
TUNNEL_CONFIG_FILE="${INSTALL_DIR}/tunnel_config.yml"
cat <<EOF > "$TUNNEL_CONFIG_FILE"
tunnel: ${TUNNEL_ID}
credentials-file: ${TUNNEL_CRED_DIR}/${TUNNEL_ID}.json

ingress:
  - hostname: ${CLOUDFLARE_TUNNEL_SUBDOMAIN}.${CLOUDFLARE_TUNNEL_DOMAIN}
    service: https://localhost:${VLESS_PORT}
    originRequest:
      noTLSVerify: true # 允许 Cloudflare Tunnel 信任自签证书
      disableChunkedEncoding: true # 解决某些客户端连接问题
  - service: http_status:404
EOF
echo "Cloudflare Tunnel configuration generated at ${TUNNEL_CONFIG_FILE}"

# 为 Cloudflare Tunnel 配置 DNS 记录 (如果需要，通常在创建 Tunnel 时会自动完成)
# 这一步通常在你第一次创建 Tunnel 且指定了 hostname 时自动完成
# 但是，如果你只是创建 Tunnel 而没有指定 hostname，或者想独立管理 DNS 记录，可以手动添加
# 如果你希望脚本自动创建 DNS CNAME 记录，这会更复杂，需要 Cloudflare API 权限
# 并且需要 CLOUDFLARE_ZONE_ID。这里我们假设 DNS CNAME 记录已经存在，或者由 cloudflared 自动处理。
echo "Ensure a CNAME record exists for ${CLOUDFLARE_TUNNEL_SUBDOMAIN}.${CLOUDFLARE_TUNNEL_DOMAIN} pointing to ${CLOUDFLARED_BIN} (e.g., tunnel.yourdomain.com -> uuid.cfargotunnel.com)."


# --- 5. 生成 VLESS-WS-TLS 链接 ---
VLESS_LINK="vless://${VLESS_UUID}@${CLOUDFLARE_TUNNEL_SUBDOMAIN}.${CLOUDFLARE_TUNNEL_DOMAIN}:${VLESS_PORT}?encryption=none&security=tls&type=ws&path=${VLESS_PATH}#AGSB_VLESS_WS_TLS"
echo "========================================"
echo "VLESS-WS-TLS Client Link:"
echo "${VLESS_LINK}"
echo "========================================"

# --- 6. 启动 sing-box 和 cloudflared ---
echo "Starting sing-box..."
${SINGBOX_BIN} run -C "$SBOX_CONFIG_FILE" &
SINGBOX_PID=$!

echo "Starting cloudflared tunnel..."
# cloudflared tunnel run 会保持在前台运行
${CLOUDFLARED_BIN} tunnel run --config "$TUNNEL_CONFIG_FILE" --cred-file "${TUNNEL_CRED_DIR}/${TUNNEL_ID}.json" "${CLOUDFLARE_TUNNEL_NAME}" &
CLOUDFLARED_PID=$!

# 等待 sing-box 和 cloudflared 退出
wait $SINGBOX_PID
wait $CLOUDFLARED_PID

echo "Services stopped."
