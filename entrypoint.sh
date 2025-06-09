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

  # 拼接 JSON（无 jq）
  vmess_json=$(cat <<EOF
{
  "v": "2",
  "ps": "$ps",
  "add": "$add",
  "port": "$port",
  "id": "$id",
  "aid": "$aid",
  "net": "$net",
  "type": "$type",
  "host": "$host",
  "path": "$path",
  "tls": "$tls",
  "sni": "$sni"
}
EOF
)

  # 使用 openssl 进行 base64 编码（无换行）
  vmess_b64=$(echo "$vmess_json" | openssl base64 -A)
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
