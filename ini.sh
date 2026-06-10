#!/bin/bash
# proxmox_deploy_all.sh - Ejecuta deploy_monitor.sh en todos los CT y VM desde el host Proxmox
# Ejecutar como root en el nodo Proxmox

REMOTE_SCRIPT_URL="https://raw.githubusercontent.com/dennispradas/Demo-Monitor/main/deploy_monitor.sh"
SCRIPT_CONTENT=$(cat << 'INNERSCRIPT'
#!/bin/bash
set -e
REPO_URL="https://github.com/dennispradas/Demo-Monitor.git"
DEST_DIR="/src/exporter"

# ─── Asegurar que git está instalado ────────────────────────────
if ! command -v git &>/dev/null; then
    echo ">>> git no encontrado, instalando..."
    if command -v apt-get &>/dev/null; then
        apt-get update -qq && apt-get install -y -qq git
    elif command -v yum &>/dev/null; then
        yum install -y -q git
    elif command -v dnf &>/dev/null; then
        dnf install -y -q git
    elif command -v apk &>/dev/null; then
        apk add --no-cache git
    else
        echo "    [ERROR] No se reconoce el gestor de paquetes. Instala git manualmente."
        exit 1
    fi
    echo "    [OK] git instalado: $(git --version)"
else
    echo ">>> git ya disponible: $(git --version)"
fi

echo ">>> Preparando directorio $DEST_DIR..."
rm -rf "$DEST_DIR"
mkdir -p "$DEST_DIR"
echo ">>> Clonando repositorio..."
git clone "$REPO_URL" "$DEST_DIR"
echo ">>> Levantando Docker Compose..."
cd "$DEST_DIR"
docker compose up -d --build
echo ">>> Done!"
docker compose ps
INNERSCRIPT
)

# ─── CONTAINERS LXC ─────────────────────────────────────────────
echo "======================================"
echo " DESPLEGANDO EN CONTAINERS LXC"
echo "======================================"

for CTID in $(pct list | awk 'NR>1 {print $1}'); do
    STATUS=$(pct status "$CTID" | awk '{print $2}')
    NAME=$(pct list | awk -v id="$CTID" '$1==id {print $3}')

    if [ "$STATUS" != "running" ]; then
        echo ">>> [CT $CTID - $NAME] No está running (estado: $STATUS), saltando..."
        continue
    fi

    echo ">>> [CT $CTID - $NAME] Ejecutando deploy..."
    pct exec "$CTID" -- bash -c "$SCRIPT_CONTENT" \
        && echo "    [OK] CT $CTID desplegado" \
        || echo "    [ERROR] CT $CTID falló"
done

# ─── VIRTUAL MACHINES (QEMU) ────────────────────────────────────
echo ""
echo "======================================"
echo " DESPLEGANDO EN VMs QEMU"
echo "======================================"

for VMID in $(qm list | awk 'NR>1 {print $1}'); do
    STATUS=$(qm status "$VMID" | awk '{print $2}')
    NAME=$(qm list | awk -v id="$VMID" '$1==id {print $2}')

    if [ "$STATUS" != "running" ]; then
        echo ">>> [VM $VMID - $NAME] No está running (estado: $STATUS), saltando..."
        continue
    fi

    # Requiere qemu-guest-agent instalado en la VM
    echo ">>> [VM $VMID - $NAME] Ejecutando deploy via qemu-guest-agent..."
    qm guest exec "$VMID" -- bash -c "$SCRIPT_CONTENT" \
        && echo "    [OK] VM $VMID desplegada" \
        || echo "    [ERROR] VM $VMID falló (¿tiene qemu-guest-agent?)"
done

echo ""
echo "======================================"
echo " Proceso completado"
echo "======================================"
