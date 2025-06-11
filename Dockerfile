# 使用基础镜像
FROM debian:bookworm-slim

# 设置环境变量（可在 docker run -e 中覆盖）
ENV PORT=2777
ENV uuid=""
ENV token=""
ENV domain=""

# 安装必要依赖
RUN apt-get update && apt-get install -y \
    curl wget unzip ca-certificates gnupg \
    coreutils procps bash \
 && rm -rf /var/lib/apt/lists/*

# 安装 sing-box（替换为你需要的版本）
ENV SING_BOX_VERSION=1.9.0
RUN curl -L -o /tmp/sb.tar.gz https://github.com/SagerNet/sing-box/releases/download/v${SING_BOX_VERSION}/sing-box-${SING_BOX_VERSION}-linux-amd64.tar.gz \
 && tar -xzf /tmp/sb.tar.gz -C /tmp \
 && mv /tmp/sing-box-${SING_BOX_VERSION}-linux-amd64/sing-box /usr/local/bin/sing-box \
 && chmod +x /usr/local/bin/sing-box \
 && rm -rf /tmp/*

# 安装 cloudflared（使用官方静态构建）
RUN curl -L -o /usr/local/bin/cloudflared https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-linux-amd64 \
 && chmod +x /usr/local/bin/cloudflared

# 拷贝启动脚本
COPY seven.sh /app/seven.sh
RUN chmod +x /app/seven.sh

# 设置工作目录
WORKDIR /app

# 启动入口点
ENTRYPOINT ["/app/seven.sh"]
