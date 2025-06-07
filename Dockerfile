# 阶段 1: 构建 (用于下载和准备二进制文件)
FROM alpine:latest as builder

# 安装必要的工具：curl (下载), tar (解压), jq (JSON 解析), bash (脚本执行)
RUN apk update && apk add --no-cache curl tar unzip jq bash

# 设置安装目录
ENV INSTALL_DIR="/opt/.agsb"
RUN mkdir -p ${INSTALL_DIR}

WORKDIR ${INSTALL_DIR}

# --- 下载 sing-box (AMD64 1.11.11 版本) ---
ENV SBOX_VERSION="1.11.11" # 指定 sing-box 版本
RUN echo "Downloading sing-box-${SBOX_VERSION}-linux-amd64.tar.gz..." && \
    curl -L -o sing-box.tar.gz "https://github.com/SagerNet/sing-box/releases/download/v${SBOX_VERSION}/sing-box-${SBOX_VERSION}-linux-amd64.tar.gz" || \
    curl -L -o sing-box.tar.gz "https://cdn.jsdelivr.net/gh/SagerNet/sing-box@v${SBOX_VERSION}/sing-box-${SBOX_VERSION}-linux-amd64.tar.gz" && \
    \
    # 解压并移动 sing-box 到安装目录
    tar -zxvf sing-box.tar.gz && \
    mv sing-box-${SBOX_VERSION}-linux-amd64/sing-box sing-box && \
    chmod +x sing-box && \
    \
    # 清理安装包
    rm -rf sing-box-${SBOX_VERSION}-linux-amd64 sing-box.tar.gz

# --- 下载 cloudflared (AMD64 2025.5.0 版本) ---
ENV CF_VERSION="2025.5.0" # 指定 cloudflared 版本
RUN echo "Downloading cloudflared-${CF_VERSION}-linux-amd64 binary..." && \
    curl -L -o cloudflared "https://github.com/cloudflare/cloudflared/releases/download/${CF_VERSION}/cloudflared-linux-amd64" || \
    curl -L -o cloudflared "https://cdn.jsdelivr.net/gh/cloudflare/cloudflared/releases/download/${CF_VERSION}/cloudflared-linux-amd64" && \
    \
    chmod +x cloudflared

# 阶段 2: 最终镜像 (更小的运行环境)
FROM alpine:latest

# 安装 bash 和 jq (运行时需要)
RUN apk update && apk add --no-cache bash jq

# 设置安装目录
ENV INSTALL_DIR="/opt/.agsb"
WORKDIR ${INSTALL_DIR}

# 从构建阶段复制必要的文件
COPY --from=builder ${INSTALL_DIR}/sing-box ${INSTALL_DIR}/sing-box
COPY --from=builder ${INSTALL_DIR}/cloudflared ${INSTALL_DIR}/cloudflared

# 复制 entrypoint 脚本
COPY entrypoint.sh .

# 赋予 entrypoint.sh 执行权限
RUN chmod +x entrypoint.sh

# 暴露端口 (虽然 Cloudflare Tunnel 会处理，但作为文档还是加上)
EXPOSE 80 443 8080 8880 2053 2083 2087 2096 8443

# 定义容器启动时执行的命令
ENTRYPOINT ["./entrypoint.sh"]
