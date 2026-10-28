#!/bin/sh
# Cuando el tunel sube, pppd llama a /etc/ppp/ip-up y ese script corre esto.
# pppd borra el entorno antes, asi que las rutas salen del archivo en /run,
# no de PPTP_ROUTES. La clave no vive aqui.

set -eu

iface="${1:-${PPP_IFACE:-}}"
case "$iface" in
  ppp[0-9]*) ;;
  *)
    echo "[mt3k-pptp] ip-up: la interfaz no es ppp (${iface:-vacia})" >&2
    exit 1
    ;;
esac

routes_file=/run/mt3k-pptp/routes
if [ ! -f "$routes_file" ]; then
  echo "[mt3k-pptp] ip-up: no hay lista de rutas; no agrego nada" >&2
  exit 0
fi

# replace no truena si la ruta ya estaba (el tunel se cae y vuelve).
while IFS= read -r cidr; do
  [ -n "$cidr" ] || continue
  case "$cidr" in
    \#*) continue ;;
  esac
  ip route replace "$cidr" dev "$iface"
  echo "[mt3k-pptp] ip-up: ruta ${cidr} por ${iface}"
done < "$routes_file"
