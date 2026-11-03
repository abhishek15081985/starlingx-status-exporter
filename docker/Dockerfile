# Minimal client-only image: needs curl (API), jq (JSON), openssh-client (scp).
FROM alpine:3.20

RUN apk add --no-cache \
      bash \
      curl \
      jq \
      openssh-client \
      tzdata \
    && rm -rf /var/cache/apk/*

ENV TZ=UTC
RUN ln -snf /usr/share/zoneinfo/$TZ /etc/localtime && echo $TZ > /etc/timezone

COPY scripts/export-status.sh /usr/local/bin/export-status.sh
RUN chmod 0755 /usr/local/bin/export-status.sh

ENTRYPOINT ["/usr/local/bin/export-status.sh"]
