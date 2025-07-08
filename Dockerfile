FROM alpine:3.20

# 环境变量（可被 docker-compose 或 docker run -e 覆盖）
ENV PORT=2777
ENV uuid=""
ENV token=""
ENV domain=""

# 安装必要依赖（bash, curl, coreutils, procps 等）
RUN apk add --no-cache bash curl coreutils procps grep

# 安装 sing-box
ENV SING_BOX_VERSION=1.9.0
RUN curl -L -o /tmp/sb.tar.gz https://github.com/SagerNet/sing-box/releases/download/v${SING_BOX_VERSION}/sing-box-${SING_BOX_VERSION}-linux-amd64.tar.gz \
 && tar -xzf /tmp/sb.tar.gz -C /tmp \
 && mv /tmp/sing-box-${SING_BOX_VERSION}-linux-amd64/sing-box /usr/local/bin/sing-box \
 && chmod +x /usr/local/bin/sing-box \
 && rm -rf /tmp/*

# 安装 cloudflared
RUN curl -L -o /usr/local/bin/cloudflared https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-linux-amd64 \
 && chmod +x /usr/local/bin/cloudflared

# 拷贝脚本并赋权
COPY seven.sh /app/seven.sh
RUN chmod +x /app/seven.sh

# 设置工作目录
WORKDIR /app

# 启动容器即执行脚本
ENTRYPOINT ["/app/seven.sh"]
