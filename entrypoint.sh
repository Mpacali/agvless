#!/bin/sh
set -e

echo "正在准备环境变量..."

TUNNEL_TYPE="${TUNNEL_TYPE:-fixed}"
INTERNAL_LISTEN_PORT="${INTERNAL_LISTEN_PORT:-8080}"
CLOUDFLARE_TLS_PORTS=("443" "8443" "2053" "2083" "2087" "2096")

TUNNEL_DOMAIN="${TUNNEL_DOMAIN}"
TUNNEL_TOKEN="${TUNNEL_TOKEN}"

if [ "$TUNNEL_TYPE" = "fixed" ]; then
    if [ -z "$TUNNEL_DOMAIN" ] || [ -z "$TUNNEL_TOKEN" ]; then
        echo "错误：fixed 模式下必须设置 TUNNEL_DOMAIN 和 TUNNEL_TOKEN。"
        exit 1
    fi
    echo "使用固定隧道：$TUNNEL_DOMAIN"
elif [ "$TUNNEL_TYPE" = "temp" ]; then
    echo "使用临时隧道..."
    TUNNEL_DOMAIN="temporary.tunnel.domain"
else
    echo "错误：TUNNEL_TYPE 必须为 fixed 或 temp。"
    exit 1
fi

echo "监听端口: $INTERNAL_LISTEN_PORT"

# 生成 UUID 和 WS 路径
VLESS_UUID=$(cat /proc/sys/kernel/random/uuid)
VLESS_WS_PATH="/${VLESS_UUID}?ed=2048"
echo "VLESS UUID: $VLESS_UUID"
echo "WebSocket 路径: $VLESS_WS_PATH"

SINGBOX_CONFIG_FILE="/app/sing-box-config.json"
CLOUDFLARED_LOG_FILE="/app/cloudflared.log"

# 启动 cloudflared
if [ "$TUNNEL_TYPE" = "temp" ]; then
    echo "启动临时 Cloudflared 隧道..."
    /usr/local/bin/cloudflared tunnel --url "http://localhost:$INTERNAL_LISTEN_PORT${VLESS_WS_PATH}" --edge-ip-version auto --no-autoupdate --protocol http2 > "$CLOUDFLARED_LOG_FILE" 2>&1 &
    CLOUDFLARED_PID=$!
    echo "等待 Cloudflared 连接..."
    sleep 20
    if ! kill -0 "$CLOUDFLARED_PID" > /dev/null 2>&1; then
        echo "Cloudflared 启动失败。"
        cat "$CLOUDFLARED_LOG_FILE"
        exit 1
    fi
    EXTRACTED_DOMAIN=$(grep -a "trycloudflare.com" "$CLOUDFLARED_LOG_FILE" | awk 'NR==2{print}' | sed -E 's/.*(https?:\/\/[^ ]*trycloudflare\.com)\/?/\1/' | sed 's/https:\/\///g')
    if [ -z "$EXTRACTED_DOMAIN" ]; then
        echo "无法提取临时隧道域名。"
        cat "$CLOUDFLARED_LOG_FILE"
        exit 1
    fi
    TUNNEL_DOMAIN="$EXTRACTED_DOMAIN"
    echo "提取到的临时域名: $TUNNEL_DOMAIN"
else
    echo "启动固定 Cloudflared 隧道..."
    /usr/local/bin/cloudflared tunnel run --token "$TUNNEL_TOKEN" --url "http://localhost:$INTERNAL_LISTEN_PORT${VLESS_WS_PATH}" > "$CLOUDFLARED_LOG_FILE" 2>&1 &
    CLOUDFLARED_PID=$!
fi

# 创建 Sing-box 配置
echo "生成 Sing-box 配置..."
cat <<EOF > "$SINGBOX_CONFIG_FILE"
{
  "log": {
    "level": "info"
  },
  "inbounds": [
    {
      "type": "vless",
      "tag": "vless-in",
      "listen": "127.0.0.1",
      "listen_port": $INTERNAL_LISTEN_PORT,
      "users": [
        {
          "uuid": "$VLESS_UUID",
          "flow": ""
        }
      ],
      "settings": {
        "decryption": "none"
      },
      "transport": {
        "type": "ws",
        "path": "$VLESS_WS_PATH",
        "headers": {
          "Host": "$TUNNEL_DOMAIN"
        }
      },
      "sniffing": {
        "enabled": true,
        "dest_override": ["http", "tls", "quic"],
        "metadata_only": false
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
        "port": $INTERNAL_LISTEN_PORT,
        "inbound": "vless-in",
        "outbound": "direct"
      }
    ]
  }
}
EOF

# 启动 Sing-box
echo "启动 Sing-box..."
/usr/local/bin/sing-box run -c "$SINGBOX_CONFIG_FILE" > /app/singbox.log 2>&1 &
SINGBOX_PID=$!
sleep 1
if ! kill -0 "$SINGBOX_PID" > /dev/null 2>&1; then
    echo "Sing-box 启动失败："
    cat /app/singbox.log
    exit 1
fi
echo "Sing-box 成功启动 (PID: $SINGBOX_PID)"

# 输出 VLESS 链接
echo "---"
echo "VLESS 节点链接如下："
for PORT in "${CLOUDFLARE_TLS_PORTS[@]}"; do
    echo "vless://${VLESS_UUID}@www.visa.com.tw:${PORT}?encryption=none&security=tls&sni=${TUNNEL_DOMAIN}&host=${TUNNEL_DOMAIN}&fp=chrome&type=ws&path=${VLESS_WS_PATH}#cf_tunnel_vless_${PORT}"
done
echo "---"

# 保持容器运行
wait "$SINGBOX_PID"
echo "Sing-box 已退出，终止 Cloudflared..."
kill "$CLOUDFLARED_PID" 2>/dev/null || true
