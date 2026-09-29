# Песочница для тестов laravel-deploy: Ubuntu 24.04 со своим Docker-демоном (dind).
# Запускается только с --privileged (см. tests/run-local.sh). Docker хоста скрипт не трогает.
FROM ubuntu:24.04

ENV DEBIAN_FRONTEND=noninteractive
RUN apt-get update -qq \
    && apt-get install -y -qq --no-install-recommends \
        docker.io docker-compose-v2 bats shellcheck python3 curl iproute2 \
        ca-certificates lsb-release iptables openssl \
    && rm -rf /var/lib/apt/lists/*

COPY tests/sandbox-entrypoint.sh /usr/local/bin/sandbox-entrypoint
RUN chmod +x /usr/local/bin/sandbox-entrypoint

VOLUME /var/lib/docker
ENTRYPOINT ["/usr/local/bin/sandbox-entrypoint"]
CMD ["unit"]
