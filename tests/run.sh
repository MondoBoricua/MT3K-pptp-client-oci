#!/bin/bash
# Pruebas del cliente sin Docker y sin pppd de verdad.
# Corre en el bash 3.2 de macOS: bash -n, shellcheck si esta, y --check.

set -euo pipefail

root=$(cd "$(dirname "$0")/.." && pwd)
cd "$root"
entry="${root}/entrypoint.sh"

echo "bash -n"
for f in "$root"/*.sh "$root"/tests/*.sh; do
  /bin/bash -n "$f"
  echo "ok $f"
done

if command -v shellcheck >/dev/null 2>&1; then
  echo "shellcheck"
  shellcheck "$root/entrypoint.sh" "$root/ip-up.sh" "$root/ip-down.sh" "$root/tests/run.sh"
  echo "shellcheck ok"
else
  echo "shellcheck not installed"
fi

# --check con un entorno limpio, para que no se cuele un PPTP_* del shell.
run_check() {
  env -i PATH="$PATH" HOME="${HOME:-/tmp}" /bin/bash "$entry" --check
}

assert_fail() {
  local name="$1" rc=0 out
  shift
  set +e
  out=$(env -i PATH="$PATH" HOME="${HOME:-/tmp}" "$@" /bin/bash "$entry" --check 2>&1)
  rc=$?
  set -e
  if [ "$rc" -eq 0 ]; then
    printf 'FAIL %s: expected exit 1\n%s\n' "$name" "$out" >&2
    exit 1
  fi
  printf '%s\n' "$out"
}

assert_ok() {
  local name="$1" out
  shift
  out=$(env -i PATH="$PATH" HOME="${HOME:-/tmp}" "$@" /bin/bash "$entry" --check 2>&1)
  printf '%s\n' "$out"
  printf '%s' "$out"
}

echo "case: missing server"
out=$(assert_fail missing PPTP_USER=pptp-user PPTP_PASS=from-env-secret-xyz)
printf '%s\n' "$out" | grep -q 'PPTP_SERVER is required'
echo "ok missing server"

echo "case: invalid CIDR"
out=$(assert_fail cidr PPTP_SERVER=vpn.example.com PPTP_USER=pptp-user PPTP_PASS=from-env-secret-xyz PPTP_ROUTES=not-a-cidr)
printf '%s\n' "$out" | grep -q 'invalid CIDR'
echo "ok invalid CIDR"

file_secret=from-file-secret-xyz
env_secret=from-env-secret-xyz
pass_file=$(mktemp)
printf '%s\n' "$file_secret" > "$pass_file"
file_len=${#file_secret}

echo "case: PASS_FILE wins"
out=$(assert_ok passfile \
  PPTP_SERVER=vpn.example.com \
  PPTP_USER=pptp-user \
  PPTP_PASS="$env_secret" \
  PPTP_PASS_FILE="$pass_file" \
  PPTP_ROUTES='192.0.2.0/24,198.51.100.0/24')
printf '%s\n' "$out" | grep -q 'password_source=file'
printf '%s\n' "$out" | grep -q "password_length=${file_len}"
if printf '%s\n' "$out" | grep -F -q "$file_secret"; then
  echo "FAIL password from file leaked" >&2
  exit 1
fi
if printf '%s\n' "$out" | grep -F -q "$env_secret"; then
  echo "FAIL password from env leaked" >&2
  exit 1
fi
echo "ok PASS_FILE wins and secrets stay hidden"

echo "case: MPPE off"
out=$(assert_ok mppe \
  PPTP_SERVER=vpn.example.com \
  PPTP_USER=pptp-user \
  PPTP_PASS="$env_secret" \
  PPTP_MPPE=off)
printf '%s\n' "$out" | grep -q 'nomppe'
if printf '%s\n' "$out" | grep -q 'require-mppe-128'; then
  echo "FAIL nomppe config still requires mppe-128" >&2
  exit 1
fi
if printf '%s\n' "$out" | grep -F -q "$env_secret"; then
  echo "FAIL env password leaked in mppe case" >&2
  exit 1
fi
echo "ok MPPE off"

echo "case: multiple routes"
out=$(assert_ok routes \
  PPTP_SERVER=vpn.example.com \
  PPTP_USER=pptp-user \
  PPTP_PASS="$env_secret" \
  PPTP_ROUTES='192.0.2.0/24 198.51.100.0/24')
printf '%s\n' "$out" | grep -q '192.0.2.0/24'
printf '%s\n' "$out" | grep -q '198.51.100.0/24'
echo "ok multiple routes"

echo "case: MT3K_PPTP_CHECK=1"
out=$(env -i PATH="$PATH" HOME="${HOME:-/tmp}" \
  PPTP_SERVER=vpn.example.com PPTP_USER=pptp-user PPTP_PASS="$env_secret" \
  MT3K_PPTP_CHECK=1 /bin/bash "$entry" 2>&1)
printf '%s\n' "$out" | grep -q 'require-mppe-128'
if printf '%s\n' "$out" | grep -F -q "$env_secret"; then
  echo "FAIL env password leaked in CHECK=1" >&2
  exit 1
fi
echo "ok MT3K_PPTP_CHECK"

# El supervisor no debe llamar al pppd del sistema. Un pppd falso sale 19
# y el entrypoint se queda en pausa hasta que le llega SIGTERM.
echo "case: fatal auth pause then SIGTERM"
work=$(mktemp -d)
py=$(command -v python3)
printf '%s\n' '#!/bin/sh' 'exit 0' > "$work/getent"
printf '%s\n' '#!/bin/sh' 'exit 19' > "$work/pppd"
# setsid de mentira: nueva sesion y ejecuta pppd, para no matar el grupo del test.
cat > "$work/setsid" <<EOF
#!${py}
import os, sys
os.setsid()
os.execvp(sys.argv[1], sys.argv[1:])
EOF
cat > "$work/findmnt" <<'EOF'
#!/bin/sh
echo tmpfs
exit 0
EOF
cat > "$work/mount" <<'EOF'
#!/bin/sh
exit 1
EOF
chmod 0755 "$work/getent" "$work/pppd" "$work/setsid" "$work/findmnt" "$work/mount"

log="$work/out"
# Sesion aparte, PATH con los binarios falsos, y secretos fuera de /etc/ppp del Mac.
env -i PATH="${work}:/usr/bin:/bin:/usr/sbin:/sbin" HOME="${HOME:-/tmp}" \
  PPTP_SERVER=vpn.example.com \
  PPTP_USER=pptp-user \
  PPTP_PASS="$env_secret" \
  PPTP_NET_WAIT=5 \
  MT3K_PPTP_RUN_DIR="${work}/run" \
  MT3K_PPTP_CHAP_PATH="${work}/chap-link" \
  "$py" -c 'import os,sys; os.setsid(); os.execvp(sys.argv[1], sys.argv[1:])' \
  /bin/bash "$entry" \
  >"$log" 2>&1 &
pid=$!
# El python de arriba es el que hace setsid; el pid que tenemos es ese python,
# que se reemplaza por bash. Esperamos el mensaje de pausa.
seen=0
i=0
while [ "$i" -lt 30 ]; do
  if grep -q 'Will not retry' "$log" 2>/dev/null; then
    seen=1
    break
  fi
  i=$((i + 1))
  sleep 0.2
done
if [ "$seen" -ne 1 ]; then
  echo "FAIL did not pause on pppd exit 19" >&2
  cat "$log" >&2 || true
  kill -TERM "$pid" 2>/dev/null || true
  exit 1
fi
kill -TERM "$pid" 2>/dev/null || true
wait_rc=0
wait "$pid" || wait_rc=$?
if [ "$wait_rc" -ne 0 ]; then
  echo "FAIL SIGTERM exit was ${wait_rc}" >&2
  cat "$log" >&2 || true
  exit 1
fi
if grep -q 'retrying' "$log"; then
  echo "FAIL fatal exit retried" >&2
  cat "$log" >&2
  exit 1
fi
if grep -F -q "$env_secret" "$log"; then
  echo "FAIL password leaked in supervisor log" >&2
  exit 1
fi
echo "ok fatal pause and SIGTERM"
echo "ALL PASSED"
