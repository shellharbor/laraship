# syntax=docker/dockerfile:1
FROM docker:29.8.2-cli AS docker-cli
FROM ubuntu:24.04
ARG TARGETARCH
ARG KUBECTL_VERSION=v1.37.0
RUN apt-get update -qq && apt-get install -y -qq --no-install-recommends \
      bash ca-certificates curl git openssh-client openssl python3 iproute2 \
      util-linux procps zip unzip coreutils gawk \
    && rm -rf /var/lib/apt/lists/*
COPY --from=docker-cli /usr/local/bin/docker /usr/local/bin/docker
COPY --from=docker-cli /usr/local/libexec/docker/cli-plugins/ /usr/local/libexec/docker/cli-plugins/
RUN curl -fsSLo /usr/local/bin/kubectl "https://dl.k8s.io/release/${KUBECTL_VERSION}/bin/linux/${TARGETARCH}/kubectl" \
    && curl -fsSLo /tmp/kubectl.sha256 "https://dl.k8s.io/release/${KUBECTL_VERSION}/bin/linux/${TARGETARCH}/kubectl.sha256" \
    && printf '%s  /usr/local/bin/kubectl\n' "$(cat /tmp/kubectl.sha256)" | sha256sum -c - \
    && chmod 755 /usr/local/bin/kubectl && rm /tmp/kubectl.sha256
WORKDIR /opt/laraship
# Explicit allowlist: no credentials, local AI files, tests or Git history in the image.
COPY *.sh VERSION versions.env ./
COPY docker-preflight.py ./
COPY lib/ ./lib/
COPY modules/ ./modules/
COPY presets/ ./presets/
COPY laravel/ ./laravel/
COPY nginxproxy/ ./nginxproxy/
COPY kubernetes/ ./kubernetes/
COPY docker/entrypoint.sh /usr/local/bin/laraship
RUN chmod 755 /usr/local/bin/laraship
ENV LARASHIP_CONTAINER=1 LARASHIP_ARCHIVE_DIR=/var/backups/laraship
LABEL org.opencontainers.image.title="LaraShip" \
      org.opencontainers.image.source="https://github.com/shellharbor/laraship"
# Root is needed only by the Linux Compose adapter. Kubernetes render/deploy can use --user.
ENTRYPOINT ["/usr/local/bin/laraship"]
CMD ["--help"]
