# Sandbox for the laraship tests: Ubuntu 24.04 with its own Docker daemon (dind).
# Runs only with --privileged (see tests/run-local.sh). The host's Docker is not touched.
FROM docker:29.8.2-cli AS docker-cli
FROM ubuntu:24.04

ENV DEBIAN_FRONTEND=noninteractive
RUN apt-get update -qq \
    && apt-get install -y -qq --no-install-recommends \
        docker.io docker-compose-v2 bats shellcheck git python3 curl iproute2 sudo postgresql mysql-server \
        procps util-linux ca-certificates lsb-release iptables openssl openssh-server zip \
    && rm -rf /var/lib/apt/lists/*

COPY tests/sandbox-entrypoint.sh /usr/local/bin/sandbox-entrypoint
COPY --from=docker-cli /usr/local/libexec/docker/cli-plugins/docker-buildx /usr/local/libexec/docker/cli-plugins/docker-buildx
RUN chmod +x /usr/local/bin/sandbox-entrypoint
ENV DOCKER_BUILDKIT=1

VOLUME /var/lib/docker
ENTRYPOINT ["/usr/local/bin/sandbox-entrypoint"]
CMD ["unit"]
