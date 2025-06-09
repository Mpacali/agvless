# Use a minimal Alpine Linux image
FROM alpine:latest

# Install necessary tools
RUN apk add --no-cache curl unzip openssl bash coreutils

# Download and install Sing-box
ARG SINGBOX_VERSION="1.9.0"
RUN curl -LO "https://github.com/SagerNet/sing-box/releases/download/v${SINGBOX_VERSION}/sing-box-${SINGBOX_VERSION}-linux-amd64.tar.gz" && \
    tar -xzf "sing-box-${SINGBOX_VERSION}-linux-amd64.tar.gz" -C /usr/local/bin && \
    mv /usr/local/bin/sing-box-*/sing-box /usr/local/bin/sing-box && \
    rm "sing-box-${SINGBOX_VERSION}-linux-amd64.tar.gz"

# Download and install Cloudflared (指定 2025.5.0 版本)
ARG CLOUDFLARED_VERSION="2025.5.0" 
RUN curl -fLO "https://github.com/cloudflare/cloudflared/releases/download/${CLOUDFLARED_VERSION}/cloudflared-linux-amd64" && \
    mv cloudflared-linux-amd64 /usr/local/bin/cloudflared && \
    chmod +x /usr/local/bin/cloudflared && \
    /usr/local/bin/cloudflared --version || { echo "Cloudflared executable check failed!"; exit 1; }

# Create working directory
WORKDIR /app

# Copy entrypoint.sh
COPY entrypoint.sh /app/entrypoint.sh
RUN chmod +x /app/entrypoint.sh

# Expose Sing-box's internal listening port (used by cloudflared)
EXPOSE 8080

# Define command to run when the container starts
ENTRYPOINT ["/app/entrypoint.sh"]
