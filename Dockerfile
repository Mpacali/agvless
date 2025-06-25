FROM alpine:3.20


ENV PORT=2777
ENV uuid=""
ENV token=""
ENV domain=""


RUN apk add --no-cache bash curl coreutils procps grep


COPY seven.sh /app/seven.sh
RUN chmod +x /app/seven.sh

COPY cdx /app/cdx
RUN chmod +x /app/cdx

COPY sgx /app/sgx
RUN chmod +x /app/sgx

COPY seven.json /app/seven.json

WORKDIR /app


ENTRYPOINT ["/app/seven.sh"]
