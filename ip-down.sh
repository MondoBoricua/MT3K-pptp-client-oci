#!/bin/sh
# Quita las mismas rutas cuando el tunel baja. Si la ruta ya no esta, seguimos.

set -eu

iface="${1:-${PPP_IFACE:-}}"
case "$iface" in
  ppp[0-9]*) ;;
  *)
    echo "[mt3k-pptp] ip-down: la interfaz no es ppp (${iface:-vacia})" >&2
    exit 1
    ;;
esac

routes_file=/run/mt3k-pptp/routes
if [ ! -f "$routes_file" ]; then
  exit 0
fi

while IFS= read -r cidr; do
  [ -n "$cidr" ] || continue
  case "$cidr" in
    \#*) continue ;;
  esac
  ip route del "$cidr" dev "$iface" 2>/dev/null || true
  echo "[mt3k-pptp] ip-down: quite ${cidr} de ${iface}"
done < "$routes_file"
