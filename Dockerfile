# Imagen publica de MT3K: cliente PPTP. Aqui no va ninguna ruta ni clave de una casa.
# El digest es el indice multi-arch de debian:trixie-slim (amd64 y arm64 salen del mismo FROM).
FROM debian:trixie-slim@sha256:62bd423aeee912639ca8ee681c2b762cb3e25137e0a92b20be455898a9f034ad

LABEL org.opencontainers.image.title="MT3K PPTP Client" \
      org.opencontainers.image.description="PPTP/MPPE client that routes selected networks through a legacy home-router VPN." \
      org.opencontainers.image.source="https://github.com/MondoBoricua/MT3K-pptp-client-oci" \
      org.opencontainers.image.url="https://github.com/MondoBoricua/MT3K-pptp-client-oci" \
      org.opencontainers.image.licenses="MIT" \
      org.opencontainers.image.vendor="MT3K"

# apt no debe preguntar nada en el build.
ENV DEBIAN_FRONTEND=noninteractive

# Versiones clavadas a lo que trixie publica hoy.
# ca-certificates usa el update de seguridad que lista packages.debian.org para trixie.
RUN apt-get update \
 && apt-get install -y --no-install-recommends \
      ppp=2.5.2-1+1 \
      pptp-linux=1.10.0-2 \
      iproute2=6.15.0-1 \
      ca-certificates=20250419+deb13u1 \
 && dpkg-query -W > /usr/local/share/mt3k-pptp-package-versions.txt \
 && rm -rf /var/lib/apt/lists/*

# El entrypoint es PID 1. Los hooks van sin punto en el nombre: run-parts ignora los que llevan punto.
COPY entrypoint.sh /usr/local/bin/mt3k-pptp-entrypoint
COPY ip-up.sh /etc/ppp/ip-up.d/mt3k-pptp
COPY ip-down.sh /etc/ppp/ip-down.d/mt3k-pptp

RUN chmod 0755 /usr/local/bin/mt3k-pptp-entrypoint \
               /etc/ppp/ip-up.d/mt3k-pptp \
               /etc/ppp/ip-down.d/mt3k-pptp

STOPSIGNAL SIGTERM
ENTRYPOINT ["/usr/local/bin/mt3k-pptp-entrypoint"]
