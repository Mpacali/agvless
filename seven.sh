#!/bin/bash




EFFECTIVE_UUID="fdfc6cef-a888-4423-8f18-6bab27391f75"

echo "UUID: $EFFECTIVE_UUID"



nohup sgx run -c seven.json > /dev/null 2>&1 &
sleep 2
ps | grep "sgx" | grep -v 'grep'
echo "sgx is on"
echo "--------------------------------------------------"

TUNNEL_MODE=""
FINAL_DOMAIN=""
TUNNEL_CONNECTED=false

if [ -n "$token" ] && [ -n "$domain" ]; then
    TUNNEL_MODE="Fixed Tun"
    FINAL_DOMAIN="$domain"
    echo "get token & domain，used fixd"
    echo "domain: $FINAL_DOMAIN"
    echo "Starting..."
    nohup cdx tunnel --no-autoupdate run --token "${token}" > /dev/null 2>&1 &

    echo "Waiting 30s"
    TUNNEL_CONNECTED=true
    for attempt in $(seq 1 15); do
        sleep 2
        echo -n "."
    done
    echo ""

else
    echo "Please used fixed"
    echo ""
fi

if [ "$TUNNEL_CONNECTED" = "true" ]; then
    echo "--------------------------------------------------"
    echo "$TUNNEL_MODE suceed"
    echo "domain: $FINAL_DOMAIN"
    echo "--------------------------------------------------"
    echo ""


    name="hug" 
    path_encoded="%2F${EFFECTIVE_UUID}%3Fed%3D2048"

    echo "vless://${EFFECTIVE_UUID}@www.visa.com.tw:443?encryption=none&security=tls&sni=${FINAL_DOMAIN}&host=${FINAL_DOMAIN}&fp=chrome&type=ws&path=${path_encoded}#${name}_visa_tw_443"
    echo "vless://${EFFECTIVE_UUID}@www.visa.com.hk:2053?encryption=none&security=tls&sni=${FINAL_DOMAIN}&host=${FINAL_DOMAIN}&fp=chrome&type=ws&path=${path_encoded}#${name}_visa_hk_2053"
    echo "vless://${EFFECTIVE_UUID}@www.visa.com.br:8443?encryption=none&security=tls&sni=${FINAL_DOMAIN}&host=${FINAL_DOMAIN}&fp=chrome&type=ws&path=${path_encoded}#${name}_visa_br_8443"
    echo "vless://${EFFECTIVE_UUID}@www.visaeurope.ch:443?encryption=none&security=tls&sni=${FINAL_DOMAIN}&host=${FINAL_DOMAIN}&fp=chrome&type=ws&path=${path_encoded}#${name}_visa_ch_443"
    echo "vless://${EFFECTIVE_UUID}@usa.visa.com:2053?encryption=none&security=tls&sni=${FINAL_DOMAIN}&host=${FINAL_DOMAIN}&fp=chrome&type=ws&path=${path_encoded}#${name}_visa_us_2053"
    echo "vless://${EFFECTIVE_UUID}@icook.hk:8443?encryption=none&security=tls&sni=${FINAL_DOMAIN}&host=${FINAL_DOMAIN}&fp=chrome&type=ws&path=${path_encoded}#${name}_icook_hk_8443"
    echo "vless://${EFFECTIVE_UUID}@icook.tw:443?encryption=none&security=tls&sni=${FINAL_DOMAIN}&host=${FINAL_DOMAIN}&fp=chrome&type=ws&path=${path_encoded}#${name}_icook_tw_443" 




    echo "--------------------------------------------------"
    echo ""

else
    echo "!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!"
    echo "Cloudflare $TUNNEL_MODE Failed"
else
    echo "!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!"
    echo "Cloudflare $TUNNEL_MODE Failed"
    exit 1
fi

exit 0
