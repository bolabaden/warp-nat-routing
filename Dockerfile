FROM alpine:latest
RUN apk update && apk add \
    bash bc docker-cli ipcalc iproute2 iptables jq util-linux && \
    rm -rf /var/cache/apk/*
COPY warp-nat-setup.sh /usr/local/bin/warp-nat-setup.sh
CMD ["/bin/bash", "/usr/local/bin/warp-nat-setup.sh"]