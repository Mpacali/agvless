#!/bin/sh
set -e

echo "启动 VLESS + Cloudflare 隧道配置"

# 默认参数
TUNNEL_TYPE="${TUNNEL_TYPE:-fixed}"
INTERNAL_LISTEN_PORT="${INTERNAL_LISTEN_PORT:-8080}"
CLOUDFLARE_TLS_PORTS="443 8443 2053 2083 2087 2096"

TUNNEL_DOMAIN="${TUNNEL_DOMAIN}"
TUNNEL_TOKEN="${TUNNEL_TOKEN}"

# 校验模式
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

# UUID 与路径
VLESS_UUID=$(cat /proc/sys/kernel/random/uuid)
VLESS_WS_PATH="/${VLESS_UUID}?ed=2048"
echo "UUID: $VLESS_UUID"
echo "WebSocket 路径: $VLESS_WS_PATH"
echo "监听端口：$INTERNAL_LISTEN_PORT"

SINGBOX_CONFIG_FILE="/app/sing-box-config.json"
CLOUDFLARED_LOG_FILE="/app/cloudflared.log"

# 生成 Sing-box 配置（无 Host 字段）
echo "生成 Sing-box 配置..."
cat <<EOF > "$SINGBOX_CONFIG_FILE"
{
  "log": {
    "level": "info",
    "timestamp": true
  },
  "inbounds": [
    {
      "type": "vmess",
      "tag": "vmess-in",
      "listen": "127.0.0.1",
      "listen_port": $INTERNAL_LISTEN_PORT,
      "tcp_fast_open": true,
      "sniff": true,
      "sniff_override_destination": true,
      "proxy_protocol": false,
      "users": [
        {
          "uuid": "$VLESS_UUID",
          "alterId": 0
        }
      ],
      "transport": {
        "type": "ws",
        "path": "$VLESS_WS_PATH",
        "max_early_data": 2048,
        "early_data_header_name": "Sec-WebSocket-Protocol"
      }
    }
  ],
  "outbounds": [
    {
      "type": "direct",
      "tag": "direct"
    }
  ]
}
EOF

# 启动 Sing-box
echo "启动 Sing-box..."
/usr/local/bin/sing-box run -c "$SINGBOX_CONFIG_FILE" > /app/singbox.log 2>&1 &
SINGBOX_PID=$!
sleep 1
if ! kill -0 "$SINGBOX_PID" > /dev/null 2>&1; then
    echo "Sing-box 启动失败"
    cat /app/singbox.log
    exit 1
fi
echo "Sing-box 成功启动 (PID: $SINGBOX_PID)"

# 启动 Cloudflared（在 Sing-box 启动之后）
if [ "$TUNNEL_TYPE" = "temp" ]; then
    echo "启动临时 Cloudflared 隧道..."
    /usr/local/bin/cloudflared tunnel --url "http://localhost:$INTERNAL_LISTEN_PORT${VLESS_WS_PATH}" --edge-ip-version auto --no-autoupdate --protocol http2 > "$CLOUDFLARED_LOG_FILE" 2>&1 &
    CLOUDFLARED_PID=$!
    sleep 20
    if ! kill -0 "$CLOUDFLARED_PID" > /dev/null 2>&1; then
        echo "Cloudflared 启动失败"
        cat "$CLOUDFLARED_LOG_FILE"
        exit 1
    fi
    EXTRACTED_DOMAIN=$(grep -a "trycloudflare.com" "$CLOUDFLARED_LOG_FILE" | awk 'NR==2{print}' | sed -E 's/.*(https?:\/\/[^ ]*trycloudflare\.com)\/?/\1/' | sed 's/https:\/\///g')
    if [ -z "$EXTRACTED_DOMAIN" ]; then
        echo "未能提取临时域名"
        cat "$CLOUDFLARED_LOG_FILE"
        exit 1
    fi
    TUNNEL_DOMAIN="$EXTRACTED_DOMAIN"
    echo "获取到临时域名：$TUNNEL_DOMAIN"
else
    echo "启动固定 Cloudflared 隧道..."
    /usr/local/bin/cloudflared tunnel run --token "$TUNNEL_TOKEN" --url "http://localhost:$INTERNAL_LISTEN_PORT${VLESS_WS_PATH}" > "$CLOUDFLARED_LOG_FILE" 2>&1 &
    CLOUDFLARED_PID=$!
fi

generate_vmess_link() {
  ps="$1"
  add="$2"
  port="$3"
  id="$4"
  aid="$5"
  net="$6"
  type="$7"
  host="$8"
  path="$9"
  tls="${10}"
  sni="${11}"

  vmess_json=$(jq -n \
    --arg v "2" \
    --arg ps "$ps" \
    --arg add "$add" \
    --arg port "$port" \
    --arg id "$id" \
    --arg aid "$aid" \
    --arg net "$net" \
    --arg type "$type" \
    --arg host "$host" \
    --arg path "$path" \
    --arg tls "$tls" \
    --arg sni "$sni" \
    '{
      v: $v,
      ps: $ps,
      add: $add,
      port: $port,
      id: $id,
      aid: $aid,
      net: $net,
      type: $type,
      host: $host,
      path: $path,
      tls: $tls,
      sni: $sni
    }'
  )

  vmess_b64=$(echo "$vmess_json" | base64 -w 0)
  echo "vmess://$vmess_b64"
}

# 生成链接
generate_links() {
  TUNNEL_DOMAIN="$1"
  PORT_VM_WS="$2"
  VLESS_UUID="$3"

  WS_PATH="/${VLESS_UUID}-vm"
  WS_PATH_FULL="${WS_PATH}?ed=2048"
  HOSTNAME=$(hostname)

  echo "生成链接: TUNNEL_DOMAIN=${TUNNEL_DOMAIN}, PORT=${PORT_VM_WS}, UUID=${VLESS_UUID}"
  echo "WebSocket路径: ${WS_PATH_FULL}"

  PS="vmess-ws-tls-argo-${HOSTNAME}-443"
  ADD="104.16.0.0"
  PORT="443"
  AID="0"
  NET="ws"
  TYPE="none"
  HOST="$TUNNEL_DOMAIN"
  PATH="$WS_PATH_FULL"
  TLS="tls"
  SNI="$TUNNEL_DOMAIN"

  VMESS_LINK=$(generate_vmess_link "$PS" "$ADD" "$PORT" "$VLESS_UUID" "$AID" "$NET" "$TYPE" "$HOST" "$PATH" "$TLS" "$SNI")

  echo ""
  echo "=== 生成的 VMess 链接 ==="
  echo "$VMESS_LINK"
  echo ""
}

# 示例调用（可以改为从环境变量或入参获取）
# 参数: TUNNEL_DOMAIN PORT_VM_WS VLESS_UUID
generate_links "$TUNNEL_DOMAIN" "$TUNNEL_PORT" "$VLESS_UUID"

# 保持运行
wait "$SINGBOX_PID"
kill "$CLOUDFLARED_PID" 2>/dev/null || true
