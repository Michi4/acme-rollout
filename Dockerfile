FROM alpine:3.20

ARG ACME_VERSION=3.1.6

RUN apk add --no-cache \
        bash \
        ca-certificates \
        curl \
        openssh-client \
        openssl \
        tar \
    && mkdir -p /opt/acme/dnsapi \
    && curl -fsSL "https://raw.githubusercontent.com/acmesh-official/acme.sh/${ACME_VERSION}/acme.sh" \
        -o /opt/acme/acme.sh \
    && curl -fsSL "https://raw.githubusercontent.com/acmesh-official/acme.sh/${ACME_VERSION}/dnsapi/dns_acmedns.sh" \
        -o /opt/acme/dnsapi/dns_acmedns.sh \
    && chmod 0755 /opt/acme/acme.sh \
    && chmod 0644 /opt/acme/dnsapi/dns_acmedns.sh

COPY entrypoint.sh /entrypoint.sh
RUN chmod 0755 /entrypoint.sh

# Das dns_acmedns-Plugin wuerde sonst auf auth.acme-dns.io zurueckfallen.
ENV ACMEDNS_BASE_URL=https://auth.example.com
ENV LE_WORKING_DIR=/data
ENTRYPOINT ["/entrypoint.sh"]
