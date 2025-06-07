# 使用一个基础的Alpine Linux镜像，因为它比较比较小巧
FROM alpine:latest

# 安装必要的工具
# 添加 bash 和 coreutils
RUN apk add --no-cache curl unzip openssl bash coreutils

# 下载并安装Sing-box
ARG SINGBOX_VERSION="1.9.0" # 建议替换为Sing-box的最新稳定版本
RUN curl -LO "https://github.com/SagerNet/sing-box/releases/download/v${SINGBOX_VERSION}/sing-box-${SINGBOX_VERSION}-linux-amd64.tar.gz" && \
    tar -xzf "sing-box-${SINGBOX_VERSION}-linux-amd64.tar.gz" -C /usr/local/bin && \
    mv /usr/local/bin/sing-box-*/sing-box /usr/local/bin/sing-box && \
    rm "sing-box-${SINGBOX_VERSION}-linux-amd64.tar.gz"

# 下载并安装Cloudflared (使用旧版本)
ARG CLOUDFLARED_VERSION="2023.10.0" # <-- 使用一个已知会输出 trycloudflare.com 的旧版本
# 确保下载正确的 AMD64 版本
RUN curl -fLO "https://github.com/cloudflare/cloudflared/releases/download/${CLOUDFLARED_VERSION}/cloudflared-linux-amd64" && \
    mv cloudflared-linux-amd64 /usr/local/bin/cloudflared && \
    chmod +x /usr/local/bin/cloudflared && \
    # 额外检查：验证文件是否可执行，并初步测试其行为
    /usr/local/bin/cloudflared --version || { echo "Cloudflared 无法执行，请检查下载或权限"; exit 1; } && \
    # 进一步测试：尝试运行一个简单的隧道并检查输出中是否包含 trycloudflare.com
    echo "测试 Cloudflared ${CLOUDFLARED_VERSION} 临时隧道行为..." && \
    TEST_OUTPUT=$(/usr/local/bin/cloudflared tunnel --url "http://localhost:8080" --hello-world 2>&1 | grep -oE "https://[a-zA-Z0-9-]+\.trycloudflare\.com" || true) && \
    if [ -z "$TEST_OUTPUT" ]; then \
        echo "警告：Cloudflared ${CLOUDFLARED_VERSION} 版本似乎不直接输出 trycloudflare.com 链接。请尝试更旧的版本。" && \
        exit 1; \
    else \
        echo "Cloudflared ${CLOUDFLARED_VERSION} 版本确认支持临时隧道 URL 提取。"; \
    fi


# 创建工作目录
WORKDIR /app

# 复制 entrypoint.sh
COPY entrypoint.sh /app/entrypoint.sh
RUN chmod +x /app/entrypoint.sh

# 暴露 Sing-box 所需的端口
EXPOSE 8080

# 定义容器启动时执行的命令
ENTRYPOINT ["/app/entrypoint.sh"]
