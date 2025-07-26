FROM alpine:latest
RUN apk add --no-cache curl
CMD ["sh", "-c", "curl -s ifconfig.me"]
