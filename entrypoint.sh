#!/bin/sh

echo "正在生成 Sing-box 配置..."

# 1. 生成随机参数
# UUID
VLESS_UUID=$(cat /proc/sys/kernel/random/uuid)
echo "生成的 UUID: $VLESS_UUID"

# WebSocket 路径 (随机字符串)
VLESS_WS_PATH="/$(head /dev/urandom | tr -dc A-Za-z0-9 | head -c 16)"
echo "生成的 WebSocket 路径: $VLESS_WS_PATH"

# Sing-box 监听端口
SINGBOX_LISTEN_PORT=8080
echo "Sing-box 监听端口: $SINGBOX_LISTEN_PORT"

# 2. 生成自签名 TLS 证书和密钥
# 这里我们使用一个占位符域名来生成证书，因为最终的访问域名是 Cloudflared 临时隧道给的
# 实际连接时，客户端会通过 Cloudflare 的域名连接，而 Sing-box 内部会使用这个自签名证书
# 但由于 Cloudflare 隧道已处理外部 TLS，这里的证书主要是为了满足 Sing-box 的 TLS 配置要求
echo "正在生成自签名 TLS 证书和密钥..."
CERT_PATH="/app/cert.pem"
KEY_PATH="/app/key.pem"
SELF_SIGNED_DOMAIN="example.com" # 证书中的通用名称，可以是一个占位符，不影响Cloudflare隧道

openssl genrsa -out "$KEY_PATH" 2048
openssl req -new -x509 -key "$KEY_PATH" -out "$CERT_PATH" -days 3650 \
  -subj "/C=US/ST=CA/L=SF/O=SelfSignedOrg/OU=IT/CN=$SELF_SIGNED_DOMAIN" \
  -addext "subjectAltName = DNS:$SELF_SIGNED_DOMAIN"

if [ $? -ne 0 ]; then
    echo "错误：无法生成自签名证书。请检查 openssl 命令。"
    exit 1
fi

echo "自签名证书已生成：$CERT_PATH 和 $KEY_PATH"


# 3. 生成 Sing-box 配置文件
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
        "server_name": "YOUR_DOMAIN_PLACEHOLDER", # 占位符，将在 VLESS 链接中替换
        "min_version": "1.2",
        "insecure": true # 对于自签名证书，客户端通常需要设置 insecure 或跳过证书验证
      },
      "transport": {
        "type": "ws",
        "path": "$VLESS_WS_PATH",
        "headers": {
          "Host": "YOUR_DOMAIN_PLACEHOLDER" # 占位符，将在 VLESS 链接中替换
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
    ],
    "default_outbound": "direct"
  }
}
EOF

echo "Sing-box 配置已生成到 $SINGBOX_CONFIG_FILE"

# 4. 启动 Sing-box
echo "正在启动 Sing-box..."
/usr/local/bin/sing-box run -c "$SINGBOX_CONFIG_FILE" &
SINGBOX_PID=$! # 获取 Sing-box 的进程 ID

echo "Sing-box 已启动 (PID: $SINGBOX_PID)"

# 确保 Sing-box 已经开始监听，短暂等待
sleep 2

# 5. 启动 Cloudflared 临时隧道
echo "正在启动 Cloudflared 临时隧道..."
CLOUDFLARED_OUTPUT=$(stdbuf -oL /usr/local/bin/cloudflared tunnel --url "http://localhost:$SINGBOX_LISTEN_PORT" 2>&1)
echo "$CLOUDFLARED_OUTPUT" # 打印 Cloudflared 的所有输出，方便调试

TUNNEL_URL=$(echo "$CLOUDFLARED_OUTPUT" | grep -oE "https://[^[:space:]]+" | head -n 1)

if [ -z "$TUNNEL_URL" ]; then
    echo "错误：未能获取 Cloudflared 隧道 URL。请检查 Cloudflared 日志。"
    exit 1
fi

TUNNEL_HOST=$(echo "$TUNNEL_URL" | sed -E 's|https://([^/]+).*|\1|')
echo "Cloudflared 隧道 URL: $TUNNEL_URL"
echo "Cloudflared 隧道域名: $TUNNEL_HOST"

# 6. 构建 VLESS 链接
# 对于自签名证书，我们需要在 VLESS 链接中添加 "allowInsecure=1" 或等效参数
# Sing-box 客户端通常通过 "tls.insecure = true" 来处理
# 这里我们假设客户端可以直接识别 "allowInsecure=1" 或者您手动设置
VLESS_LINK="vless://${VLESS_UUID}@${TUNNEL_HOST}:443?security=tls&type=ws&path=${VLESS_WS_PATH}&fp=random&alpn=h2,http/1.1&flow=xtls-rprx-vision&tls.insecure=true#Cloudflare_Tunnel_SelfSigned_VLESS_Node"

echo "---"
echo "您的 VLESS 节点链接已生成："
echo "$VLESS_LINK"
echo "---"

# 将 Sing-box 配置中的占位符替换为实际的域名
sed -i "s|YOUR_DOMAIN_PLACEHOLDER|$TUNNEL_HOST|g" "$SINGBOX_CONFIG_FILE"

# 保持容器运行，等待 Sing-box 进程结束
wait "$SINGBOX_PID"
echo "Sing-box 进程已终止。"
