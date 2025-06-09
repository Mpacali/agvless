#!/bin/sh

# Exit immediately if a command exits with a non-zero status.
set -e

echo "正在生成 Sing-box 配置..."

# 1. Read Environment Variables
# TUNNEL_TYPE: 'fixed' for pre-configured tunnel, 'temp' for temporary tunnel. Default to 'fixed'.
TUNNEL_TYPE="${TUNNEL_TYPE:-fixed}"

# INTERNAL_LISTEN_PORT is the port Sing-box listens on internally, and cloudflared connects to.
INTERNAL_LISTEN_PORT="${INTERNAL_LISTEN_PORT:-8080}" # Default to 8080, but can be changed.

# The TUNNEL_PORT is the public port clients will connect to (usually 443 for HTTPS)
TUNNEL_PORT="${TUNNEL_PORT:-443}" # Default to 443 if not set

# Variables for fixed tunnel (only used if TUNNEL_TYPE is 'fixed')
TUNNEL_DOMAIN="${TUNNEL_DOMAIN}"
TUNNEL_TOKEN="${TUNNEL_TOKEN}"

# Validation based on TUNNEL_TYPE
if [ "$TUNNEL_TYPE" = "fixed" ]; then
    if [ -z "$TUNNEL_DOMAIN" ] || [ -z "$TUNNEL_TOKEN" ]; then
        echo "错误：当 TUNNEL_TYPE 为 'fixed' 时，必须设置 TUNNEL_DOMAIN 和 TUNNEL_TOKEN 环境变量。"
        echo "  - TUNNEL_DOMAIN: 你在 Cloudflare Zero Trust 配置的公共主机名 (例如: vless.yourdomain.com)"
        echo "  - TUNNEL_TOKEN: 你在 Cloudflare Zero Trust 获取的隧道 Token (例如: eyJhIjoi...)"
        echo "示例：docker run -e TUNNEL_TYPE=fixed -e TUNNEL_DOMAIN=vless.yourdomain.com -e TUNNEL_TOKEN=YOUR_TOKEN ..."
        exit 1
    fi
    echo "使用固定隧道配置："
    echo "  隧道域名: $TUNNEL_DOMAIN"
    echo "  隧道端口 (公共): $TUNNEL_PORT"
elif [ "$TUNNEL_TYPE" = "temp" ]; then
    echo "使用临时隧道配置："
    echo "  隧道端口 (公共): $TUNNEL_PORT (Cloudflare 临时隧道通常强制使用 443 端口，但 VLESS 链接中仍包含此值)"
    # For temporary tunnels, TUNNEL_DOMAIN will be dynamically assigned and TUNNEL_TOKEN is not needed.
    # Set TUNNEL_DOMAIN to a placeholder until it's extracted.
    TUNNEL_DOMAIN="temporary.tunnel.domain"
else
    echo "错误：TUNNEL_TYPE 环境变量必须是 'fixed' 或 'temp'。"
    exit 1
fi

echo "  Sing-box 内部监听端口: $INTERNAL_LISTEN_PORT"

# UUID for VLESS
VLESS_UUID=$(cat /proc/sys/kernel/random/uuid)
echo "生成的 VLESS UUID: $VLESS_UUID"

# WebSocket path (random string)
VLESS_WS_PATH="/$(head /dev/urandom | tr -dc A-Za-z0-9 | head -c 16)"
echo "生成的 WebSocket 路径: $VLESS_WS_PATH"

# Sing-box internal listening port
SINGBOX_LISTEN_PORT=$INTERNAL_LISTEN_PORT
echo "Sing-box 监听端口: $SINGBOX_LISTEN_PORT"

# 2. Generate Self-Signed TLS Certificate and Key for Sing-box
# This is for Sing-box's internal TLS listener. Cloudflare handles external TLS.
echo "正在生成自签名 TLS 证书和密钥..."
CERT_PATH="/app/cert.pem"
KEY_PATH="/app/key.pem"
# For temporary tunnels, we still use the VLESS domain as a placeholder for the certificate CN/SAN
# For fixed tunnels, it's the actual TUNNEL_DOMAIN.
SELF_SIGNED_DOMAIN="${TUNNEL_DOMAIN}"

openssl genrsa -out "$KEY_PATH" 2048
openssl req -new -x509 -key "$KEY_PATH" -out "$CERT_PATH" -days 3650 \
  -subj "/C=US/ST=CA/L=SF/O=SelfSignedOrg/OU=IT/CN=$SELF_SIGNED_DOMAIN" \
  -addext "subjectAltName = DNS:$SELF_SIGNED_DOMAIN"

if [ $? -ne 0 ]; then
    echo "错误：无法生成自签名证书。请检查 openssl 命令。"
    exit 1
fi

echo "自签名证书已生成：$CERT_PATH 和 $KEY_PATH"


# 3. Generate Sing-box Configuration File
SINGBOX_CONFIG_FILE="/app/sing-box-config.json"

cat <<EOF > "$SINGBOX_CONFIG_FILE"
{
  "log": {
    "level": "info"
  },
  "inbounds": [
    {
      "type": "vless",
      "tag": "vless-in",
      "listen": "0.0.0.0",
      "listen_port": $SINGBOX_LISTEN_PORT,
      "users": [
        {
          "uuid": "$VLESS_UUID",
          "flow": ""
        }
      ],
      "tls": {
        "enabled": true,
        "certificate_path": "$CERT_PATH",
        "key_path": "$KEY_PATH",
        "server_name": "$TUNNEL_DOMAIN", # Use the provided tunnel domain for TLS server_name
        "min_version": "1.2",
        "insecure": true
      },
      "transport": {
        "type": "ws",
        "path": "$VLESS_WS_PATH",
        "headers": {
          "Host": "$TUNNEL_DOMAIN" # Use the provided tunnel domain for Host header
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
  ],
  "route": {
    "rules": [
      {
        "port": $SINGBOX_LISTEN_PORT,
        "inbound": "vless-in",
        "outbound": "direct"
      }
    ]
  }
}
EOF

echo "Sing-box 配置已生成到 $SINGBOX_CONFIG_FILE"

# 4. Start Sing-box
echo "正在启动 Sing-box..."
# Redirect Sing-box output to a log file for debugging
/usr/local/bin/sing-box run -c "$SINGBOX_CONFIG_FILE" > /app/singbox.log 2>&1 &
SINGBOX_PID=$! # Get Sing-box's process ID

# Check if Sing-box started successfully
sleep 1 # Give it a moment to start
if ! kill -0 "$SINGBOX_PID" > /dev/null 2>&1; then
    echo "错误：Sing-box 启动失败。请检查 Sing-box 配置或日志。"
    echo "Sing-box 启动日志内容："
    cat /app/singbox.log # Print detailed Sing-box startup logs
    exit 1
fi
echo "Sing-box 已启动 (PID: $SINGBOX_PID)"


# 5. Start Cloudflared Tunnel
CLOUDFLARED_LOG_FILE="/app/cloudflared.log"

if [ "$TUNNEL_TYPE" = "fixed" ]; then
    echo "正在启动 Cloudflared 固定隧道..."
    /usr/local/bin/cloudflared tunnel run --token "$TUNNEL_TOKEN" --url "http://localhost:$SINGBOX_LISTEN_PORT" > "$CLOUDFLARED_LOG_FILE" 2>&1 &
elif [ "$TUNNEL_TYPE" = "temp" ]; then
    echo "正在启动 Cloudflared 临时隧道并获取域名..."
    # For temporary tunnels, cloudflared prints the domain to stdout/stderr.
    # We capture it in a log file.
    /usr/local/bin/cloudflared tunnel --url "http://localhost:$SINGBOX_LISTEN_PORT" --edge-ip-version auto --no-autoupdate --protocol http2 > "$CLOUDFLARED_LOG_FILE" 2>&1 &
fi
CLOUDFLARED_PID=$!

echo "Cloudflared PID: $CLOUDFLARED_PID"

# Wait a bit for Cloudflared to establish the tunnel
echo "等待 Cloudflared 隧道建立连接 (约 15-25 秒)..."
sleep 20 # Give it more time for temporary tunnel to get the domain

# Check if Cloudflared is still running
if ! kill -0 "$CLOUDFLARED_PID" > /dev/null 2>&1; then
    echo "错误：Cloudflared 隧道启动失败或已退出。请检查 $CLOUDFLARED_LOG_FILE 以获取详细信息。"
    cat "$CLOUDFLARED_LOG_FILE"
    exit 1
fi
echo "Cloudflared 隧道正在运行。"

# For temporary tunnel, extract the domain from the log file
if [ "$TUNNEL_TYPE" = "temp" ]; then
    echo "正在从 Cloudflared 日志中提取临时隧道域名..."
    # Grep the log for the trycloudflare.com domain. Look for lines like "https://[domain].trycloudflare.com"
    # Using awk to get the second line that matches, as the first might be a warning/info
    EXTRACTED_DOMAIN=$(grep -a "trycloudflare.com" "$CLOUDFLARED_LOG_FILE" | awk 'NR==2{print}' | sed -E 's/.*(https?:\/\/[^ ]*trycloudflare\.com)\/?/\1/' | sed 's/https:\/\///g') # Remove https://
    
    if [ -z "$EXTRACTED_DOMAIN" ]; then
        echo "错误：无法从 Cloudflared 日志中提取临时隧道域名。请检查 $CLOUDFLARED_LOG_FILE。"
        cat "$CLOUDFLARED_LOG_FILE"
        exit 1
    fi
    TUNNEL_DOMAIN="$EXTRACTED_DOMAIN"
    echo "已获取临时隧道域名: $TUNNEL_DOMAIN"

    # Since the Sing-box config was generated with a placeholder,
    # we need to re-generate it with the actual temporary domain.
    echo "重新生成 Sing-box 配置以更新临时域名..."
    # Kill existing Sing-box process
    kill "$SINGBOX_PID" 2>/dev/null || true
    sleep 1

    cat <<EOF > "$SINGBOX_CONFIG_FILE"
{
  "log": {
    "level": "info"
  },
  "inbounds": [
    {
      "type": "vless",
      "tag": "vless-in",
      "listen": "0.0.0.0",
      "listen_port": $SINGBOX_LISTEN_PORT,
      "users": [
        {
          "uuid": "$VLESS_UUID",
          "flow": ""
        }
      ],
      "tls": {
        "enabled": true,
        "certificate_path": "$CERT_PATH",
        "key_path": "$KEY_PATH",
        "server_name": "$TUNNEL_DOMAIN", # Use the EXTRACTED temporary domain for TLS server_name
        "min_version": "1.2",
        "insecure": true
      },
      "transport": {
        "type": "ws",
        "path": "$VLESS_WS_PATH",
        "headers": {
          "Host": "$TUNNEL_DOMAIN" # Use the EXTRACTED temporary domain for Host header
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
  ],
  "route": {
    "rules": [
      {
        "port": $SINGBOX_LISTEN_PORT,
        "inbound": "vless-in",
        "outbound": "direct"
      }
    ]
  }
}
EOF
    # Restart Sing-box with updated config
    echo "重启 Sing-box (PID: $SINGBOX_PID) ..."
    /usr/local/bin/sing-box run -c "$SINGBOX_CONFIG_FILE" > /app/singbox.log 2>&1 &
    SINGBOX_PID=$!
    sleep 1
    if ! kill -0 "$SINGBOX_PID" > /dev/null 2>&1; then
        echo "错误：Sing-box 重新启动失败。请检查 Sing-box 配置或日志。"
        cat /app/singbox.log
        exit 1
    fi
    echo "Sing-box 已重新启动 (PID: $SINGBOX_PID)"
fi

# 6. Construct VLESS Link
# Use the provided TUNNEL_DOMAIN and TUNNEL_PORT for the VLESS link
VLESS_LINK="vless://${VLESS_UUID}@www.visa.com.tw:${TUNNEL_PORT}?encryption=none&security=tls&sni=${TUNNEL_DOMAIN}&host=${TUNNEL_DOMAIN}&fp=chrome&type=ws&path=/${VLESS_UUID}?ed=2048#cf_tunnel_visa_tw_443"

echo "---"
echo "您的 VLESS 节点链接已生成："
echo "$VLESS_LINK"
echo "---"

# Keep the container running by waiting for Sing-box to finish
wait "$SINGBOX_PID"
echo "Sing-box 进程已终止。"
# Also ensure cloudflared is killed when sing-box exits
kill "$CLOUDFLARED_PID" 2>/dev/null || true
echo "Cloudflared 进程已终止。"
