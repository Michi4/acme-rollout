FROM alpine:3.20

# Version and checksums belong together: a moved tag fails the build. Update
# with ./scripts/bump-acme.sh.
ARG ACME_VERSION=3.1.7
ARG ACME_SHA256=35bf6b947478666be137f938f77c5089954f120798220e6fff390949c5ea5692
ARG DNS_ACMEDNS_SHA256=8a325d23ad708b7abcbd13e9d5d42aab70aa9e4a81095f709f56448064660f7a

RUN apk add --no-cache \
        bash \
        ca-certificates \
        curl \
        openssh-client \
        openssl \
        tar \
        tzdata \
    && mkdir -p /opt/acme/dnsapi \
    && curl -fsSL "https://raw.githubusercontent.com/acmesh-official/acme.sh/${ACME_VERSION}/acme.sh" \
        -o /tmp/acme.sh \
    && curl -fsSL "https://raw.githubusercontent.com/acmesh-official/acme.sh/${ACME_VERSION}/dnsapi/dns_acmedns.sh" \
        -o /tmp/dns_acmedns.sh \
    && printf '%s  %s\n' "$ACME_SHA256" /tmp/acme.sh | sha256sum -c - \
    && printf '%s  %s\n' "$DNS_ACMEDNS_SHA256" /tmp/dns_acmedns.sh | sha256sum -c - \
    && mv /tmp/acme.sh /opt/acme/acme.sh \
    && mv /tmp/dns_acmedns.sh /opt/acme/dnsapi/dns_acmedns.sh \
    && chmod 0755 /opt/acme/acme.sh \
    && chmod 0644 /opt/acme/dnsapi/dns_acmedns.sh

COPY entrypoint.sh /entrypoint.sh
RUN chmod 0755 /entrypoint.sh

# The dns_acmedns plugin would otherwise fall back to auth.acme-dns.io.
ENV ACMEDNS_BASE_URL=https://auth.example.com
ENV LE_WORKING_DIR=/data
ENTRYPOINT ["/entrypoint.sh"]
