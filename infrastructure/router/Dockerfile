# Site router: a minimal Linux router (routing + WireGuard + iptables firewall).
# One instance runs per site. Its configuration is rendered by Ansible into
# build/routers/<site>/ and mounted read-only at /lab.
FROM alpine:3.22
RUN apk add --no-cache iproute2 wireguard-tools-wg iptables tcpdump bind-tools \
 && rm -rf /var/cache/apk/*
LABEL org.opencontainers.image.title="msha-router" \
      org.opencontainers.image.description="Multi-site HA lab site router"
ENTRYPOINT ["/bin/sh", "/lab/router.sh"]
