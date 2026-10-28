#!/usr/bin/env bash
# PID 1 del cliente PPTP de MT3K.
# Lee todo por variables de entorno, escribe la config en /run (modo 600)
# y nunca imprime la clave. --check solo valida y muestra la config enmascarada.
# Compatible con bash 3.2 (el bash de macOS) para poder correr --check sin Docker.

set -euo pipefail
# Sin glob: un CIDR malo no puede expandirse a archivos del directorio.
set -f

umask 077

prefix='[mt3k-pptp]'
# Estos dos solo los cambian las pruebas. En el contenedor quedan asi.
run_dir="${MT3K_PPTP_RUN_DIR:-/run/mt3k-pptp}"
chap_path="${MT3K_PPTP_CHAP_PATH:-/etc/ppp/chap-secrets}"

shutdown=0
child=''
password=''
password_source=''
peer_text=''
routes=''

# Mensaje normal. Nunca le pases la clave a esta funcion.
log() {
  printf '%s %s\n' "$prefix" "$*"
}

# Error visible y salida 1. Tampoco va la clave aqui.
die() {
  printf '%s %s\n' "$prefix" "$*" >&2
  exit 1
}

# true/false en minuscula, sin depender de bash 4.
lower() {
  printf '%s' "$1" | tr '[:upper:]' '[:lower:]'
}

# IPv4 de verdad: cada octeto 0-255. 10# evita que 08 reviente como octal.
valid_ipv4() {
  local ip="$1" o1='' o2='' o3='' o4='' extra='' o
  IFS=. read -r o1 o2 o3 o4 extra <<EOF
$ip
EOF
  [ -z "$extra" ] || return 1
  [ -n "$o1" ] && [ -n "$o2" ] && [ -n "$o3" ] && [ -n "$o4" ] || return 1
  for o in "$o1" "$o2" "$o3" "$o4"; do
    case "$o" in
      ''|*[!0-9]*) return 1 ;;
    esac
    if [ "$((10#$o))" -gt 255 ]; then
      return 1
    fi
  done
  return 0
}

# CIDR IPv4. El prefijo va de 0 a 32.
valid_cidr() {
  local cidr="$1" ip prefix
  case "$cidr" in
    */*) ;;
    *) return 1 ;;
  esac
  ip=${cidr%/*}
  prefix=${cidr#*/}
  case "$prefix" in
    ''|*[!0-9]*) return 1 ;;
  esac
  valid_ipv4 "$ip" || return 1
  if [ "$((10#$prefix))" -gt 32 ]; then
    return 1
  fi
  return 0
}

# Host o IPv4. Nada de comillas ni espacios: esto entra en pty "pptp ...".
valid_server() {
  local s="$1"
  if valid_ipv4 "$s"; then
    return 0
  fi
  case "$s" in
    ''|-*|*.|*..*|*[!A-Za-z0-9.-]*) return 1 ;;
  esac
  [ "${#s}" -le 253 ]
}

# Entero dentro de un rango. Rechaza vacio y basura.
need_int() {
  local name="$1" val="$2" min="$3" max="$4"
  case "$val" in
    ''|*[!0-9]*) die "${name} must be an integer" ;;
  esac
  if [ "$val" -lt "$min" ] || [ "$val" -gt "$max" ]; then
    die "${name} must be between ${min} and ${max}"
  fi
}

# true o false. Si viene vacio, usa el default.
parse_bool() {
  local name="$1" raw="$2" def="$3" v
  if [ -z "$raw" ]; then
    printf '%s' "$def"
    return
  fi
  v=$(lower "$raw")
  case "$v" in
    true|false) printf '%s' "$v" ;;
    *) die "${name} must be true or false" ;;
  esac
}

# Escapa comillas y backslash para una linea de chap-secrets. No imprime nada.
escape_chap() {
  printf '%s' "$1" | sed 's/\\/\\\\/g; s/"/\\"/g'
}

# Arma el archivo de opciones de pppd. La clave NO entra aqui.
build_peer() {
  # Mismas opciones que el cliente que lleva meses en produccion: sin IP local por hostname,
  # aceptar las direcciones que proponga el servidor, sin IPv6 ni compresion (chocan con MPPE).
  peer_text="pty \"pptp ${server} --nolaunchpppd --nobuffer --loglevel 0\"
name \"${user}\"
remotename \"${peer}\"
linkname ${peer}
noauth
noipdefault
ipcp-accept-local
ipcp-accept-remote
noproxyarp
noipv6
nobsdcomp
nodeflate
mtu ${mtu}
mru ${mtu}
lcp-echo-interval 20
lcp-echo-failure 3
maxfail 1
"
  # La ruta por defecto la pone pppd, no el hook de rutas.
  if [ "$default_route" = true ]; then
    peer_text="${peer_text}defaultroute
replacedefaultroute
"
  else
    peer_text="${peer_text}nodefaultroute
"
  fi

  # required: MPPE-128; los refuse-* dejan solo MS-CHAPv2 para autenticarNOS, que es de donde salen
  #   las llaves MPPE. OJO: require-mschap-v2 NO va aqui: en pppd significa "exige que el PEER se
  #   autentique", y con noauth aborta con exit 1 ("remote system is required to authenticate itself").
  # optional: deja que el peer negocie MPPE y el metodo de auth, sin nomppe ni require-mppe-128.
  # off: nomppe, para un servidor viejo que no cifra.
  case "$mppe" in
    required)
      peer_text="${peer_text}require-mppe-128
refuse-pap
refuse-eap
refuse-chap
refuse-mschap
"
      ;;
    optional)
      ;;
    off)
      peer_text="${peer_text}nomppe
"
      ;;
  esac

  if [ "$dns" = true ]; then
    peer_text="${peer_text}usepeerdns
"
  fi
  if [ "$debug" = true ]; then
    peer_text="${peer_text}debug
logfd 2
"
  fi
  peer_text="${peer_text}nodetach
"
}

# Lo que ven las pruebas: la config, con la clave tapada, y de donde salio.
emit_check() {
  log "check: configuration (password masked)"
  printf '%s' "$peer_text"
  printf 'chap-secrets: "%s" "%s" "********" *\n' "$user" "$peer"
  printf 'password_source=%s\n' "$password_source"
  printf 'password_length=%s\n' "${#password}"
  printf 'routes:%s\n' "$routes"
}

# Lee y valida. check_mode=1 no toca la red ni /run.
load_config() {
  local raw_routes cidr mppe_raw n

  server=${PPTP_SERVER-}
  user=${PPTP_USER-}
  if [ -z "$server" ]; then
    die "PPTP_SERVER is required"
  fi
  if ! valid_server "$server"; then
    die "PPTP_SERVER is not a hostname or IPv4 address"
  fi
  if [ -z "$user" ]; then
    die "PPTP_USER is required"
  fi
  case "$user" in
    *[!A-Za-z0-9._@+-]*) die "PPTP_USER has unsupported characters" ;;
  esac

  # Si el archivo existe en la variable, gana sobre PPTP_PASS. Si lo pediste y no abre, paramos.
  password=''
  password_source='environment'
  if [ -n "${PPTP_PASS_FILE:-}" ]; then
    if [ ! -f "$PPTP_PASS_FILE" ] || [ ! -r "$PPTP_PASS_FILE" ]; then
      die "PPTP_PASS_FILE is set but cannot be read"
    fi
    # awk cuenta lineas igual en macOS y en Debian, con o sin newline final.
    n=$(awk 'END { print NR + 0 }' "$PPTP_PASS_FILE")
    if [ "${n:-0}" -gt 1 ]; then
      die "PPTP_PASS_FILE must contain a single line"
    fi
    password=''
    IFS= read -r password < "$PPTP_PASS_FILE" || true
    if [ -z "$password" ]; then
      die "PPTP_PASS_FILE is empty"
    fi
    password_source='file'
  else
    password=${PPTP_PASS-}
    if [ -z "$password" ]; then
      die "PPTP_PASS or PPTP_PASS_FILE is required"
    fi
  fi
  case "$password" in
    *'
'*) die "password must be a single line" ;;
  esac

  raw_routes=$(printf '%s' "${PPTP_ROUTES-}" | tr ',' ' ')
  routes=''
  for cidr in $raw_routes; do
    if ! valid_cidr "$cidr"; then
      die "invalid CIDR in PPTP_ROUTES: ${cidr}"
    fi
    routes="${routes} ${cidr}"
  done

  default_route=$(parse_bool PPTP_DEFAULT_ROUTE "${PPTP_DEFAULT_ROUTE-}" false)
  dns=$(parse_bool PPTP_DNS "${PPTP_DNS-}" false)
  debug=$(parse_bool PPTP_DEBUG "${PPTP_DEBUG-}" false)

  mppe_raw=$(lower "${PPTP_MPPE:-required}")
  case "$mppe_raw" in
    required|optional|off) mppe=$mppe_raw ;;
    *) die "PPTP_MPPE must be required, optional, or off" ;;
  esac

  mtu=${PPTP_MTU:-1400}
  need_int PPTP_MTU "$mtu" 576 1500

  peer=${PPTP_PEER_NAME:-mt3k-pptp}
  case "$peer" in
    ''|*[!A-Za-z0-9._-]*) die "PPTP_PEER_NAME has unsupported characters" ;;
  esac
  case "$peer" in
    [A-Za-z0-9]*) ;;
    *) die "PPTP_PEER_NAME must start with a letter or digit" ;;
  esac
  if [ "${#peer}" -gt 64 ]; then
    die "PPTP_PEER_NAME is too long"
  fi

  retry_min=${PPTP_RETRY_MIN:-30}
  retry_max=${PPTP_RETRY_MAX:-300}
  need_int PPTP_RETRY_MIN "$retry_min" 1 86400
  need_int PPTP_RETRY_MAX "$retry_max" 1 86400
  if [ "$retry_min" -gt "$retry_max" ]; then
    die "PPTP_RETRY_MIN must be less than or equal to PPTP_RETRY_MAX"
  fi

  net_wait=${PPTP_NET_WAIT:-120}
  need_int PPTP_NET_WAIT "$net_wait" 0 3600

  build_peer
}

# Duerme por pedazos de 1s para que SIGTERM no espere el backoff entero.
sleep_interruptible() {
  local remain="$1"
  while [ "$remain" -gt 0 ] && [ "$shutdown" -eq 0 ]; do
    sleep 1 || true
    remain=$((remain - 1))
  done
}

# SIGTERM: mata el grupo de ESTE intento y sal 0. No reintentes.
# shellcheck disable=SC2329 # la llama trap, no un llamado directo
on_term() {
  shutdown=1
  if [ -n "$child" ]; then
    kill -TERM -- "-$child" 2>/dev/null || kill -TERM "$child" 2>/dev/null || true
  fi
}

# Codigos de pppd que no se curan reintentando.
# man pppd EXIT STATUS: 2 opciones, 3 sin privilegio, 11 el peer no se autentica, 19 nosotros fallamos.
# Tambien 1 (fatal de una vez), 4 (el kernel no tiene PPP) y 9 (no corrio el pty): reintentar es bucle.
fatal_pppd() {
  case "$1" in
    1|2|3|4|9|11|19) return 0 ;;
    *) return 1 ;;
  esac
}

# Espera DNS, o una ruta por defecto si el server ya es una IP.
wait_for_network() {
  local deadline=$((SECONDS + net_wait)) ok=0
  while [ "$shutdown" -eq 0 ]; do
    if valid_ipv4 "$server"; then
      if ip -4 route show default 2>/dev/null | grep -q '^default'; then
        ok=1
        break
      fi
    else
      if getent ahostsv4 "$server" >/dev/null 2>&1; then
        ok=1
        break
      fi
    fi
    if [ "$SECONDS" -ge "$deadline" ]; then
      break
    fi
    sleep 2 || true
  done
  if [ "$shutdown" -eq 1 ]; then
    log "stopped while waiting for network"
    exit 0
  fi
  if [ "$ok" -ne 1 ]; then
    die "network not ready: could not resolve ${server} within ${net_wait}s (getaddrinfo)"
  fi
  log "network ready for ${server}"
}

# Config y chap-secrets en /run, modo 600. pppd no tiene opcion chapfile (man de trixie),
# asi que el archivo de secretos vive en /run y /etc/ppp/chap-secrets es un enlace.
write_runtime_files() {
  local esc fstype='' cidr
  mkdir -p "$run_dir"
  chmod 0700 "$run_dir"

  if command -v findmnt >/dev/null 2>&1; then
    fstype=$(findmnt -n -o FSTYPE -T "$run_dir" 2>/dev/null || true)
  fi
  if [ "$fstype" != tmpfs ]; then
    if mount -t tmpfs -o mode=0700,nosuid,nodev,noexec,size=1m tmpfs "$run_dir" 2>/dev/null; then
      log "mounted tmpfs on ${run_dir}"
    else
      log "warning: ${run_dir} is not a tmpfs; secrets stay mode 0600 and are not in the image"
    fi
  fi

  printf '%s' "$peer_text" > "${run_dir}/peer"
  chmod 0600 "${run_dir}/peer"

  esc=$(escape_chap "$password")
  printf '"%s" "%s" "%s" *\n' "$user" "$peer" "$esc" > "${run_dir}/chap-secrets"
  chmod 0600 "${run_dir}/chap-secrets"
  # Ya quedo en disco. Sacamos la clave de la memoria del shell y del entorno de pppd.
  password=''
  esc=''
  unset PPTP_PASS || true

  : > "${run_dir}/routes"
  for cidr in $routes; do
    printf '%s\n' "$cidr" >> "${run_dir}/routes"
  done
  chmod 0600 "${run_dir}/routes"

  ln -sfn "${run_dir}/chap-secrets" "$chap_path"
}

# Un intento = un grupo de procesos. Si pppd sale por auth o config, nos quedamos en pausa.
supervise() {
  local delay="$retry_min" rc=0 started=0 ran=0 pppd_bin sig
  pppd_bin=$(command -v pppd || true)
  if [ -z "$pppd_bin" ]; then
    die "pppd is not installed"
  fi
  if ! command -v setsid >/dev/null 2>&1; then
    die "setsid is not installed"
  fi

  while [ "$shutdown" -eq 0 ]; do
    log "starting pppd"
    started=$SECONDS
    set +e
    setsid "$pppd_bin" file "${run_dir}/peer" &
    child=$!
    wait "$child"
    rc=$?
    set -e
    child=''
    if [ "$shutdown" -eq 1 ]; then
      log "stopped"
      exit 0
    fi
    if [ "$rc" -gt 128 ]; then
      sig=$((rc - 128))
      if [ "$sig" -eq 15 ] || [ "$sig" -eq 2 ]; then
        log "pppd got signal ${sig}"
        exit 0
      fi
    fi
    if fatal_pppd "$rc"; then
      log "pppd exit ${rc} is fatal (authentication or configuration). Pausing. Will not retry."
      while [ "$shutdown" -eq 0 ]; do
        sleep_interruptible 300
        if [ "$shutdown" -eq 0 ]; then
          log "still paused after pppd exit ${rc}. Fix the configuration and recreate the container."
        fi
      done
      log "stopped"
      exit 0
    fi
    ran=$((SECONDS - started))
    # Si el tunel aguanto, el siguiente fallo empieza otra vez desde el minimo.
    if [ "$ran" -ge "$retry_min" ]; then
      delay=$retry_min
    fi
    log "pppd exit ${rc}; retrying in ${delay}s"
    sleep_interruptible "$delay"
    if [ "$shutdown" -eq 1 ]; then
      log "stopped"
      exit 0
    fi
    if [ "$delay" -lt "$retry_max" ]; then
      delay=$((delay * 2))
      if [ "$delay" -gt "$retry_max" ]; then
        delay=$retry_max
      fi
    fi
  done
  exit 0
}

check_mode=0
if [ "${1:-}" = "--check" ] || [ "${MT3K_PPTP_CHECK:-}" = 1 ]; then
  check_mode=1
fi

load_config

if [ "$check_mode" -eq 1 ]; then
  emit_check
  exit 0
fi

trap on_term TERM INT
wait_for_network
write_runtime_files
supervise
