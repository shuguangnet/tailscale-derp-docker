ARG GO_VERSION=1.26
FROM golang:${GO_VERSION}-alpine AS builder

ARG TAILSCALE_VERSION=v1.98.9
RUN apk add --no-cache git ca-certificates \
    && GOBIN=/out go install tailscale.com/cmd/derper@${TAILSCALE_VERSION}

FROM alpine:3.23
RUN apk add --no-cache ca-certificates tzdata su-exec \
    && mkdir -p /var/lib/derper \
    && chown 65532:65532 /var/lib/derper
COPY --from=builder /out/derper /usr/local/bin/derper
COPY docker-entrypoint.sh /usr/local/bin/docker-entrypoint.sh
ENTRYPOINT ["/usr/local/bin/docker-entrypoint.sh"]
