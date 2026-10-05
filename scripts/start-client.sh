#!/usr/bin/env bash
# Arranca el cliente ya instalado desde el disco duro.
set -euo pipefail

DOMAIN="cliente"
SUDO=""
if [[ $EUID -ne 0 ]]; then
  SUDO="sudo"
fi

tmp_xml="$(mktemp)"
$SUDO virsh -c qemu:///system dumpxml "$DOMAIN" > "$tmp_xml"
sed -i "s/<boot dev='[^']*'\/>/<boot dev='hd'\/>/g" "$tmp_xml"
$SUDO virsh -c qemu:///system define "$tmp_xml"
rm -f "$tmp_xml"

$SUDO virsh -c qemu:///system start "$DOMAIN"
echo "Cliente arrancado desde disco."
