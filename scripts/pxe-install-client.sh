#!/usr/bin/env bash
# Instala el cliente por PXE y, tras apagarse, lo rearranca desde disco.
set -euo pipefail

PROJECT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
TERRAFORM_DIR="$PROJECT_DIR/terraform"
SSH_KEY="$PROJECT_DIR/id_pxe"
DOMAIN="cliente"

cd "$PROJECT_DIR"

WIPE=0
while [[ $# -gt 0 ]]; do
  case "$1" in
    --wipe) WIPE=1; shift ;;
    -h|--help)
      echo "Uso: $0 [--wipe]"
      echo "  --wipe  Recrea el disco del cliente antes de instalar"
      exit 0
      ;;
    *) echo "Opcion desconocida: $1"; exit 1 ;;
  esac
done

SUDO=""
if [[ $EUID -ne 0 ]]; then
  SUDO="sudo"
fi

set_boot_dev() {
  local dev="$1"
  local tmp_xml
  tmp_xml="$(mktemp)"
  $SUDO virsh -c qemu:///system dumpxml "$DOMAIN" > "$tmp_xml"
  # Reemplaza cualquier <boot dev='...'/> por <boot dev='$dev'/>
  sed -i "s/<boot dev='[^']*'\/>/<boot dev='$dev'\/>/g" "$tmp_xml"
  $SUDO virsh -c qemu:///system define "$tmp_xml"
  rm -f "$tmp_xml"
}

wait_for_state() {
  local expected="$1"
  echo -n "Esperando que $DOMAIN este '$expected'"
  while [[ "$($SUDO virsh -c qemu:///system domstate "$DOMAIN" 2>/dev/null | tr -d '\n')" != "$expected" ]]; do
    sleep 10
    echo -n "."
  done
  echo " OK"
}

get_client_ip() {
  local server_ip
  server_ip="$(cd "$TERRAFORM_DIR" && terraform output -raw servidor_ip)"
  # Busca la lease con hostname 'cliente'; si no, la ultima linea
  ssh -o IdentitiesOnly=yes -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
      -i "$SSH_KEY" "ubuntu@$server_ip" \
      "awk '/ cliente /{print \$3; exit} END{print \$3}' /var/lib/misc/dnsmasq.leases" 2>/dev/null || true
}

wait_for_ssh() {
  local server_ip client_ip proxy
  server_ip="$(cd "$TERRAFORM_DIR" && terraform output -raw servidor_ip)"
  proxy="ssh -W %h:%p -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -i $SSH_KEY ubuntu@$server_ip"
  echo -n "Esperando SSH en el cliente"
  client_ip=""
  while [[ -z "$client_ip" ]]; do
    client_ip="$(get_client_ip)"
    sleep 5
    echo -n "."
  done
  until ssh -o IdentitiesOnly=yes -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
            -i "$SSH_KEY" -o ProxyCommand="$proxy" \
            "ubuntu@$client_ip" hostname >/dev/null 2>&1; do
    sleep 5
    echo -n "."
  done
  echo " OK"
  echo "Cliente accesible: ubuntu@$client_ip (a traves de $server_ip)"
}

if [[ "$WIPE" -eq 1 ]]; then
  echo "[1/6] Destruyendo dominio y volumen del cliente..."
  $SUDO virsh -c qemu:///system destroy "$DOMAIN" 2>/dev/null || true
  $SUDO virsh -c qemu:///system vol-delete "${DOMAIN}.qcow2" pxe-lab 2>/dev/null || true
  echo "[2/6] Recreando volumen y dominio con Terraform..."
  (cd "$TERRAFORM_DIR" && terraform apply -auto-approve)
else
  echo "[1/6] Asegurando orden de arranque PXE (red primero)..."
  set_boot_dev network
fi

echo "[3/6] Iniciando instalacion PXE del cliente..."
$SUDO virsh -c qemu:///system start "$DOMAIN"

echo "[4/6] Esperando a que la instalacion termine y apague la VM..."
wait_for_state "shut off"

echo "[5/6] Cambiando orden de arranque a disco duro..."
set_boot_dev hd

echo "[6/6] Arrancando cliente desde disco..."
$SUDO virsh -c qemu:///system start "$DOMAIN"

echo "Esperando a que el cliente termine de arrancar..."
wait_for_ssh

echo "Cliente instalado y listo."
