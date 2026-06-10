#!/bin/bash
# update_prometheus_targets.sh
# Obtiene las IPs de todos los CT y VM de Proxmox y añade DOS jobs al prometheus.yml:
#   - node_exporter  → IP:9100/
#   - cadvisor       → IP:9100/advisor
# Ejecutar como root en el nodo Proxmox

# ══════════════════════════════════════════════
#  CONFIGURACIÓN — edita estos valores
# ══════════════════════════════════════════════
PROMETHEUS_CTID=103                              # CTID o VMID donde corre Prometheus
PROMETHEUS_YML="/etc/prometheus/prometheus.yml"  # Ruta dentro de ese CT/VM
EXPORTER_PORT=9100                               # Puerto del exporter en cada nodo
JOB_NODE="ne"                         # Job para /  (node_exporter)
JOB_ADVISOR="ca"                           # Job para /advisor
# ══════════════════════════════════════════════

TARGETS=()

# ─── Recoger IPs de LXC Containers ──────────────────────────────
echo ">>> Escaneando LXC containers..."
for CTID in $(pct list | awk 'NR>1 {print $1}'); do
    STATUS=$(pct status "$CTID" | awk '{print $2}')
    NAME=$(pct list | awk -v id="$CTID" '$1==id {print $3}')

    if [ "$STATUS" != "running" ]; then
        echo "    [SKIP] CT $CTID ($NAME) no está running"
        continue
    fi

    IP=$(pct exec "$CTID" -- hostname -I 2>/dev/null | awk '{print $1}')
    if [ -z "$IP" ]; then
        echo "    [WARN] CT $CTID ($NAME) sin IP detectada, saltando"
        continue
    fi

    echo "    [CT $CTID - $NAME] IP: $IP"
    TARGETS+=("$IP")
done

# ─── Recoger IPs de VMs QEMU ────────────────────────────────────
echo ">>> Escaneando VMs QEMU..."
for VMID in $(qm list | awk 'NR>1 {print $1}'); do
    STATUS=$(qm status "$VMID" | awk '{print $2}')
    NAME=$(qm list | awk -v id="$VMID" '$1==id {print $2}')

    if [ "$STATUS" != "running" ]; then
        echo "    [SKIP] VM $VMID ($NAME) no está running"
        continue
    fi

    IP=$(qm guest cmd "$VMID" network-get-interfaces 2>/dev/null \
        | python3 -c "
import sys, json
data = json.load(sys.stdin)
for iface in data:
    if iface.get('name') == 'lo':
        continue
    for addr in iface.get('ip-addresses', []):
        if addr.get('ip-address-type') == 'ipv4':
            print(addr['ip-address'])
            sys.exit()
" 2>/dev/null)

    if [ -z "$IP" ]; then
        echo "    [WARN] VM $VMID ($NAME) sin IP detectada (¿guest-agent activo?)"
        continue
    fi

    echo "    [VM $VMID - $NAME] IP: $IP"
    TARGETS+=("$IP")
done

if [ ${#TARGETS[@]} -eq 0 ]; then
    echo ">>> No se encontraron targets. Abortando."
    exit 1
fi

echo ""
echo ">>> IPs recogidas: ${TARGETS[*]}"

# ─── Construir bloques YAML para cada job ───────────────────────
TARGETS_YAML=""
for IP in "${TARGETS[@]}"; do
    TARGETS_YAML+="        - '${IP}:${EXPORTER_PORT}'"$'\n'
done

NEW_JOBS="  - job_name: '${JOB_NODE}'
    metrics_path: /
    static_configs:
      - targets:
${TARGETS_YAML}  - job_name: '${JOB_ADVISOR}'
    metrics_path: /advisor
    static_configs:
      - targets:
${TARGETS_YAML}"

# Codificar en base64 para evitar problemas de quoting al pasar por pct/qm exec
NEW_JOBS_B64=$(printf '%s' "$NEW_JOBS" | base64 -w0)

# ─── Aplicar en el CT/VM de Prometheus ──────────────────────────
echo ""
echo ">>> Actualizando prometheus.yml en CT/VM $PROMETHEUS_CTID..."

IS_CT=$(pct list 2>/dev/null | awk -v id="$PROMETHEUS_CTID" '$1==id {print $1}')

run_remote() {
    if [ -n "$IS_CT" ]; then
        pct exec "$PROMETHEUS_CTID" -- bash -c "$1"
    else
        qm guest exec "$PROMETHEUS_CTID" -- bash -c "$1"
    fi
}

# Backup
run_remote "cp $PROMETHEUS_YML ${PROMETHEUS_YML}.bak.\$(date +%Y%m%d%H%M%S)"
echo "    [OK] Backup creado"

# Reemplazar/insertar ambos jobs via Python (bloque pasado en base64)
run_remote "
python3 - << 'PYEOF'
import re, base64

yml_path    = '$PROMETHEUS_YML'
job_node    = '$JOB_NODE'
job_advisor = '$JOB_ADVISOR'
new_jobs    = base64.b64decode('$NEW_JOBS_B64').decode()

with open(yml_path, 'r') as f:
    content = f.read()

def remove_job(content, name):
    pattern = r'[ \t]*- job_name:[ \t]*[\"\']?' + re.escape(name) + r'[\"\']?(.*?)(?=\n[ \t]*- job_name:|\Z)'
    return re.sub(pattern, '', content, flags=re.DOTALL)

content = remove_job(content, job_node)
content = remove_job(content, job_advisor)
content = content.rstrip()

if 'scrape_configs:' not in content:
    content += '\n\nscrape_configs:'

content = content + '\n' + new_jobs + '\n'

with open(yml_path, 'w') as f:
    f.write(content)

print('    [OK] prometheus.yml actualizado con ambos jobs')
PYEOF
"

# Validar la config antes de recargar (si promtool existe)
run_remote "
if command -v promtool &>/dev/null; then
    promtool check config $PROMETHEUS_YML && echo '    [OK] Config validada por promtool' || { echo '    [ERROR] Config inválida, revisa el yml'; exit 1; }
fi
"

# Recargar Prometheus sin downtime
run_remote "
if command -v systemctl &>/dev/null && systemctl is-active prometheus &>/dev/null; then
    systemctl reload prometheus && echo '    [OK] Prometheus recargado (systemctl reload)'
elif curl -s -X POST http://localhost:9090/-/reload &>/dev/null; then
    echo '    [OK] Prometheus recargado (HTTP /-/reload)'
else
    echo '    [WARN] No se pudo recargar Prometheus automáticamente. Hazlo manualmente.'
fi
"

echo ""
echo "══════════════════════════════════════════════════════"
echo " Jobs configurados:"
echo "   [$JOB_NODE]   → :$EXPORTER_PORT/"
echo "   [$JOB_ADVISOR] → :$EXPORTER_PORT/advisor"
echo ""
echo " Targets:"
for IP in "${TARGETS[@]}"; do echo "   • $IP"; done
echo "══════════════════════════════════════════════════════"
