# pxe-lab

Laboratorio reproducible de arranque e instalación por red (**PXE**) con **Terraform**, **Ansible** y **libvirt/KVM**.

Despliega una VM **servidor** (NAT + DHCP + TFTP + HTTP + PXE) y una VM **cliente** que arranca por red, descarga la ISO de Ubuntu Server 22.04 y se instala de forma **desatendida** usando `autoinstall`.

---

## Arquitectura

```
+--------------------------------------------------+
|                  Host (KVM/libvirt)              |
|                                                  |
|  +------------------+        +----------------+  |
|  |   servidor       |        |    cliente     |  |
|  | 192.168.122.208 |        | 192.168.50.x   |  |
|  | (red default)    |<------>| (red internal) |  |
|  | 192.168.50.1     |  DHCP  |                |  |
|  | TFTP / HTTP / PXE|<------>|                |  |
|  +------------------+        +----------------+  |
+--------------------------------------------------+
```

- **Red `default`**: acceso del servidor a Internet y al host.
- **Red `internal`**: red aislada 192.168.50.0/24 entre servidor y cliente.
- **dnsmasq** en el servidor da DHCP/TFTP en `internal`.
- **nginx** sirve la ISO y los ficheros `user-data` / `meta-data`.
- El cliente PXE descarga `vmlinuz`/`initrd` por TFTP y la ISO por HTTP.

---

## Requisitos

- Sistema operativo tipo Linux con **KVM** habilitado (se probó en Arch/Omarchy).
- Paquetes base: `qemu-desktop`, `libvirt`, `dnsmasq`, `terraform`, `ansible`, `git`.
- Usuario añadido al grupo `libvirt`.
- Red `default` de libvirt activa:
  ```bash
  sudo systemctl enable --now libvirtd
  sudo virsh net-start default
  sudo virsh net-autostart default
  ```
- Proyecto clonado en **`~/pxe-lab`** (hay rutas relativas a `$HOME/pxe-lab` en Ansible/Terraform).

---

## Estructura del proyecto

```
~/pxe-lab/
├── ansible/
│   ├── inventory.ini          # Generado por Terraform
│   ├── site.yml               # Playbook principal
│   └── roles/
│       ├── nat/               # nftables + IP forwarding
│       ├── dnsmasq/           # DHCP/TFTP/DNS
│       ├── http/              # nginx
│       └── pxe/               # pxelinux, kernel/initrd, ISO, autoinstall
├── scripts/
│   ├── pxe-install-client.sh  # Instala el cliente por PXE y rearranca desde disco
│   └── start-client.sh        # Arranca el cliente ya instalado desde disco
├── terraform/
│   ├── main.tf                # Infraestructura libvirt
│   ├── outputs.tf
│   ├── user-data.yaml.tmpl    # cloud-init del servidor
│   ├── network-config.yaml
│   └── inventory.ini.tmpl
├── id_pxe / id_pxe.pub        # Claves SSH generadas localmente (no subir a git)
└── images/                    # Volúmenes y pools de libvirt (no subir a git)
```

---

## Uso rápido

### 1. Clonar y generar claves SSH

```bash
cd ~
git clone https://github.com/<tu-usuario>/pxe-lab.git
# o git@github.com:<tu-usuario>/pxe-lab.git

cd pxe-lab
ssh-keygen -t ed25519 -f id_pxe -N "" -C "pxe-lab"
```

### 2. Desplegar infraestructura

```bash
cd terraform
terraform init
terraform apply -auto-approve
```

Esto crea:
- El pool de almacenamiento `pxe-lab`.
- La red interna `internal`.
- El disco base `server.qcow2` (Ubuntu cloud image) y el disco vacío `cliente.qcow2`.
- La VM `servidor` con dos interfaces de red.
- El inventario `ansible/inventory.ini`.

### 3. Configurar el servidor PXE

```bash
cd ../ansible
ansible-playbook -i inventory.ini site.yml
```

Ansible instala y configura nftables, dnsmasq, nginx, pxelinux y el autoinstall del cliente.

### 4. Instalar el cliente por PXE

```bash
cd ~/pxe-lab
./scripts/pxe-install-client.sh --wipe
```

El script:
1. Rearranca el cliente con **red primero**.
2. Espera a que termine la instalación y la VM se apague (`shutdown: poweroff`).
3. Cambia el orden de arranque a **disco primero**.
4. Arranca el cliente desde disco y espera a que responda por SSH.

Tarda aproximadamente **8-12 minutos** dependiendo de la conexión.

### 5. Acceder al cliente

```bash
SERVER_IP=$(cd ~/pxe-lab/terraform && terraform output -raw servidor_ip)
CLIENT_IP=$(ssh -i ~/pxe-lab/id_pxe ubuntu@$SERVER_IP \
  "awk '/ cliente /{print \$3; exit} END{print \$3}' /var/lib/misc/dnsmasq.leases")

ssh -i ~/pxe-lab/id_pxe \
  -o ProxyCommand="ssh -W %h:%p -i ~/pxe-lab/id_pxe ubuntu@$SERVER_IP" \
  ubuntu@$CLIENT_IP
```

---

## Reinstalación limpia

Si quieres volver a instalar el cliente desde cero:

```bash
cd ~/pxe-lab
./scripts/pxe-install-client.sh --wipe
```

Esto borra el volumen `cliente.qcow2`, lo recrea con Terraform y lanza la instalación PXE.

---

## Notas importantes

- **No subas `id_pxe` ni `images/` a Git**; están en `.gitignore`.
- El autoinstall usa `shutdown: poweroff` para evitar que el cliente reinstale en bucle al reiniciar. Después del apagado, el script cambia el orden de arranque a disco.
- El orden de arranque del dominio `cliente` está marcado con `ignore_changes = [os]` en Terraform para que los cambios hechos por los scripts no sean revertidos.
- La RAM del cliente está en **6144 MiB** porque la ISO de ~2,1 GB se carga en tmpfs durante el arranque.

---

## Solución de problemas

### El cliente se queda en la pantalla de idioma
- Revisa `/srv/http/autoinstall/user-data` en el servidor.
- Asegúrate de que tenga la clave `autoinstall:` correctamente indentada y sin bloques anidados.

### “Failed to find matching device” en el instalador
- Comprueba que el disco del cliente tenga 20 GB visibles desde el guest:
  ```bash
  sudo virsh -c qemu:///system vol-info cliente.qcow2 pxe-lab
  ```
- Verifica que el XML del dominio tenga `driver type='qcow2'` para el disco.

### El cliente reinstala en bucle
- El orden de arranque sigue siendo `network` primero. Usa `./scripts/start-client.sh` o cambia el orden a `hd` con `virsh edit`.

### No hay red en el cliente
- En el servidor, revisa que dnsmasq y nftables estén activos:
  ```bash
  sudo systemctl status dnsmasq
  sudo nft list ruleset
  ```

---

## Licencia

MIT. Usa, modifica y comparte libremente.
