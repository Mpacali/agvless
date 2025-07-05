#!/bin/bash

# 确保必要的命令存在
command -v /usr/local/bin/sgx >/dev/null 2>&1 || { echo "错误：未找到 sing-box。"; exit 1; }
command -v /usr/local/bin/cdx >/dev/null 2>&1 || { echo "错误：未找到 cloudflared。"; exit 1; }
command -v /usr/local/bin/wals >/dev/null 2>&1 || { echo "错误：未找到 wals。"; exit 1; }
command -v base64 >/dev/null 2>&1 || { echo "错误：未找到 base64 (是否缺少 coreutils？)。"; exit 1; }

# --- UUID 处理 ---
EFFECTIVE_UUID=""
if [ -n "$uuid" ]; then
    EFFECTIVE_UUID="$uuid"
    echo "--------------------------------------------------"
    echo "检测到用户提供的 UUID: $EFFECTIVE_UUID"
else
    EFFECTIVE_UUID=$(/usr/local/bin/sgx generate uuid)
    echo "--------------------------------------------------"
    echo "未提供 UUID，已自动生成: $EFFECTIVE_UUID"
fi
echo "--------------------------------------------------"

# --- sing-box 配置 ---
cat > seven.json <<EOF
{
  "log": { "disabled": false, "level": "info", "timestamp": true },
  "inbounds": [
    { "type": "vless", "tag": "proxy", "listen": "::", "listen_port": 2777,
      "users": [ { "uuid": "${EFFECTIVE_UUID}", "flow": "" } ],
      "transport": { "type": "ws", "path": "/${EFFECTIVE_UUID}", "max_early_data": 2048, "early_data_header_name": "Sec-WebSocket-Protocol" }
    }
  ],
  "outbounds": [ {"type": "socks","tag": "socks-out","server": "127.0.0.1","port": 8086 } ]
}
EOF
echo "seven.json 已创建 (端口: 2777)。"

nohup /usr/local/bin/sgx run -c seven.json > /dev/null 2>&1 &
sleep 2
ps | grep "sgx" | grep -v 'grep'
echo "sing-box 已启动。"
echo "--------------------------------------------------"


# --- Cloudflare Tunnel 处理 ---
TUNNEL_MODE=""
FINAL_DOMAIN=""
TUNNEL_CONNECTED=false

# 检查是否使用固定隧道
if [ -n "$token" ] && [ -n "$domain" ]; then
    TUNNEL_MODE="固定隧道 (Fixed Tunnel)"
    FINAL_DOMAIN="$domain"
    echo "检测到 token 和 domain 环境变量，将使用【固定隧道模式】。"
    echo "隧道域名将是: $FINAL_DOMAIN"
    echo "Cloudflare Tunnel Token: [已隐藏]"
    echo "正在启动固定的 Cloudflare 隧道..."
    nohup /usr/local/bin/cdx tunnel --no-autoupdate run --token "${token}" > ./seven.log 2>&1 &

    echo "正在等待 Cloudflare 固定隧道连接... (最多 30 秒)"
    for attempt in $(seq 1 15); do
        sleep 2
        if grep -q -E "Registered tunnel connection|Connected to .*, an Argo Tunnel an edge" ./seven.log; then
            TUNNEL_CONNECTED=true
            break
        fi
        echo -n "."
    done
    echo ""

else
    TUNNEL_MODE="临时隧道 (Temporary Tunnel)"
    echo "未提供 token 和/或 domain 环境变量，将使用【临时隧道模式】。"
    echo "正在启动临时的 Cloudflare 隧道..."
    nohup /usr/local/bin/cdx tunnel --url http://localhost:2777 --edge-ip-version auto --no-autoupdate --protocol http2 > ./seven.log 2>&1 &

    echo "正在等待 Cloudflare 临时隧道 URL... (最多 30 秒)"
    for attempt in $(seq 1 15); do
        sleep 2
        TEMP_TUNNEL_URL=$(grep -o 'https://[a-zA-Z0-9-]*\.trycloudflare.com' ./seven.log | head -n 1)
        if [ -n "$TEMP_TUNNEL_URL" ]; then
            FINAL_DOMAIN=$(echo $TEMP_TUNNEL_URL | awk -F'//' '{print $2}')
            TUNNEL_CONNECTED=true
            break
        fi
        echo -n "."
    done
    echo ""
fi

# --- 输出结果 ---
if [ "$TUNNEL_CONNECTED" = "true" ]; then
    echo "--------------------------------------------------"
    echo "$TUNNEL_MODE 已成功连接！"
    echo "公共访问域名: $FINAL_DOMAIN"
    echo "--------------------------------------------------"
    echo ""

    LINKS_FILE="vless_links.txt"
    name="cf_tunnel" # 通用名称
    path_encoded="%2F${EFFECTIVE_UUID}%3Fed%3D2048"

    echo "vless://${EFFECTIVE_UUID}@www.visa.com.tw:443?encryption=none&security=tls&sni=${FINAL_DOMAIN}&host=${FINAL_DOMAIN}&fp=chrome&type=ws&path=${path_encoded}#${name}_visa_tw_443" > $LINKS_FILE
    echo "vless://${EFFECTIVE_UUID}@www.visa.com.hk:2053?encryption=none&security=tls&sni=${FINAL_DOMAIN}&host=${FINAL_DOMAIN}&fp=chrome&type=ws&path=${path_encoded}#${name}_visa_hk_2053" >> $LINKS_FILE
    echo "vless://${EFFECTIVE_UUID}@www.visa.com.br:8443?encryption=none&security=tls&sni=${FINAL_DOMAIN}&host=${FINAL_DOMAIN}&fp=chrome&type=ws&path=${path_encoded}#${name}_visa_br_8443" >> $LINKS_FILE
    echo "vless://${EFFECTIVE_UUID}@www.visaeurope.ch:443?encryption=none&security=tls&sni=${FINAL_DOMAIN}&host=${FINAL_DOMAIN}&fp=chrome&type=ws&path=${path_encoded}#${name}_visa_ch_443" >> $LINKS_FILE
    echo "vless://${EFFECTIVE_UUID}@usa.visa.com:2053?encryption=none&security=tls&sni=${FINAL_DOMAIN}&host=${FINAL_DOMAIN}&fp=chrome&type=ws&path=${path_encoded}#${name}_visa_us_2053" >> $LINKS_FILE
    echo "vless://${EFFECTIVE_UUID}@icook.hk:8443?encryption=none&security=tls&sni=${FINAL_DOMAIN}&host=${FINAL_DOMAIN}&fp=chrome&type=ws&path=${path_encoded}#${name}_icook_hk_8443" >> $LINKS_FILE
    echo "vless://${EFFECTIVE_UUID}@icook.tw:443?encryption=none&security=tls&sni=${FINAL_DOMAIN}&host=${FINAL_DOMAIN}&fp=chrome&type=ws&path=${path_encoded}#${name}_icook_tw_443" >> $LINKS_FILE

    echo "--- 单个节点链接 (可逐个复制) ---"
    cat $LINKS_FILE
    echo ""

    echo "--- 聚合链接文本 (复制整段导入全部) ---"
    base64 -w 0 $LINKS_FILE
    echo ""
    echo ""

    echo "--- 如何使用 ---"
    echo " - 如果你只需要 1-2 个节点，请从【单个节点链接】中选择并复制。"
    echo " - 如果你想一次导入全部 7 个节点，请复制【聚合链接文本】的整段内容。"
    echo "   >> 复制技巧: 在聚合文本上【连续点击鼠标三次】(三击)可快速选中整行！"
    echo "   >> (注意：如果只双击，可能只会选中一部分文本，推荐三击！)           <<"
    echo " - 复制后，在你的客户端尝试“从剪贴板导入”。"
    echo "--------------------------------------------------"
    echo ""
    echo "正在显示隧道日志 (seven.log)："
    tail -f ./seven.log
    
    echo "--------------------------------------------------"
    nohup /usr/local/bin/wals > /dev/null 2>&1 &
    sleep 2
    ps | grep "wals" | grep -v 'grep'
    echo "sing-box 已启动。"
    echo "--------------------------------------------------"
else
    echo "!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!"
    echo "Cloudflare $TUNNEL_MODE 连接失败 (超时 30 秒)。"
    echo "请检查 seven.log 日志以获取错误信息，并确认你的配置正确无误。"
    if [ "$TUNNEL_MODE" = "固定隧道 (Fixed Tunnel)" ]; then
        echo "对于固定隧道，请确保 Token 和域名正确，并且已在 Cloudflare Dashboard 正确配置。"
    fi
    echo "!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!"
    cat ./seven.log
    exit 1
