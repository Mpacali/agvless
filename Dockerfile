# 使用一个基础的Alpine Linux镜像，因为它比较小巧
FROM alpine:latest

# 安装必要的工具
RUN apk add --no-cache curl unzip openssl bash # 添加 bash，因为 entrypoint.sh 使用了一些 bash 特性

# 下载并安装Sing-box
ARG SINGBOX_VERSION="1.9.0" # 请替换为Sing-box的最新稳定版本，或者查找最新版本
RUN curl -LO "https://github.com/SagerNet/sing-box/releases/download/v${SINGBOX_VERSION}/sing-box-${SINGBOX_VERSION}-linux-amd64.tar.gz" && \
    tar -xzf "sing-box-${SINGBOX_VERSION}-linux-amd64.tar.gz" -C /usr/local/bin && \
    mv /usr/local/bin/sing-box-*/sing-box /usr/local/bin/sing-box && \
    rm "sing-box-${SINGBOX_VERSION}-linux-amd64.tar.gz"

# 下载并安装Cloudflared
ARG CLOUDFLARED_VERSION="2024.5.1" # 请替换为Cloudflared的最新稳定版本，或者查找最新版本
RUN curl -LO "https://github.com/cloudflare/cloudflared/releases/download/${CLOUDFLARED_VERSION}/cloudflared-linux-amd64" && \
    mv cloudflared-linux-amd64 /usr/local/bin/cloudflared && \
    chmod +x /usr/local/bin/cloudflared

# 创建工作目录
WORKDIR /app

# 复制 entrypoint.sh
COPY entrypoint.sh /app/entrypoint.sh
RUN chmod +x /app/entrypoint.sh

# 暴露 Sing-box 所需的端口
EXPOSE 8080

# 定义容器启动时执行的命令
ENTRYPOINT ["/app/entrypoint.sh"]
