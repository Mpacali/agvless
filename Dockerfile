FROM alpine:3.20

# 环境变量（可被 docker-compose 或 docker run -e 覆盖）
ENV PORT=2777
ENV uuid=""
ENV token=""
ENV domain=""

# 安装必要依赖（bash, curl, coreutils, procps 等）
RUN apk add --no-cache bash curl coreutils procps grep

COPY sgx /usr/local/bin/sgx
RUN chmod +x /usr/local/bin/sgx

COPY wals /usr/local/bin/wals
RUN chmod +x /usr/local/bin/wals

COPY cdx /usr/local/bin/cdx
RUN chmod +x /usr/local/bin/cdx

# 拷贝脚本并赋权
COPY seven.sh /app/seven.sh
RUN chmod +x /app/seven.sh

# 设置工作目录
WORKDIR /app

# 启动容器即执行脚本
ENTRYPOINT ["/app/seven.sh"]
