FROM alpine:3.20


ENV PORT=2777
ENV uuid=""
ENV token=""
ENV domain=""


RUN apk add --no-cache bash curl coreutils procps grep


COPY seven.sh /app/seven.sh
RUN chmod +x /app/seven.sh


WORKDIR /app


ENTRYPOINT ["/app/seven.sh"]
