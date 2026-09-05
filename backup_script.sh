#!/bin/bash

LOG_FILE="/var/log/restic-backup.log"
exec >> "$LOG_FILE" 2>&1

SCRIPT_DIR="$(dirname "$(realpath "$0")")"
cd "$SCRIPT_DIR" || {
    echo "Errore: impossibile entrare in $SCRIPT_DIR"
    exit 1
}


echo "=== Backup started at $(date) ==="
source "config/general_config.sh"

# Lista progetti docker
DOCKER_C=$(docker compose ls -q)
# Calcolo giorno dell'anno (001-365)
DAY_OF_YEAR=$(date +%j)

FULL_BACKUP=false
if (( DAY_OF_YEAR % FREQUENCY == 0 )); then
    FULL_BACKUP=true
    echo "Full backup day: ignoring exclude list"
else
    echo "Regular backup day: applying exclude list"
fi

# Funzione per verificare se un valore è nella lista
is_excluded() {
    local ITEM="$1"
    for EX in ${EXCLUDE_LIST}; do
        if [[ "$EX" == "$ITEM" ]]; then
            return 0
        fi
    done
    return 1
}

notify_kuma() {
    local status="$1"   # up / down
    local message="$2"  # messaggio opzionale

    if [[ -z "$UPTIME_URL" ]]; then
        echo "$(date) - UPTIME_URL non definita, impossibile inviare notifica"
        return
    fi
    curl -s -X GET "${UPTIME_URL}?status=${status}&msg=$(printf "%s" "$message" | sed 's/ /%20/g')" >/dev/null
    echo "$(date) - Notifica inviata a Uptime Kuma: status=${status}, msg=${message}"
}

# Filtra i compose
DOCKER_C_FILTERED=""
for PROJECT in ${DOCKER_C}; do
    if [[ "$FULL_BACKUP" == true ]]; then
        # Nessuna esclusione
        DOCKER_C_FILTERED="${DOCKER_C_FILTERED} ${PROJECT}"
    else
        # Applica exclude list
        if is_excluded "${PROJECT}"; then
            echo "Skipping project '${PROJECT}'"
        else
            DOCKER_C_FILTERED="${DOCKER_C_FILTERED} ${PROJECT}"
        fi
    fi
done

# Conta solo quelli filtrati
DOCKER_C_LIST=$(echo ${DOCKER_C_FILTERED} | wc -w)


############################################
# STOP CONTAINER (solo se STOP_DOCKER=true)
############################################
if [[ "$STOP_DOCKER" == true ]]; then
    echo "Stopping ${DOCKER_C_LIST} projects"
    for PROJECT in ${DOCKER_C_FILTERED}; do
        echo "Stopping project ${PROJECT}"
        docker compose -p ${PROJECT} stop
    done
else
    echo "Skipping docker stop because STOP_DOCKER=false"
fi

############################################
# BACKUP MULTI-SITE
############################################

echo "$(date) - Starting multi-site backup..."

for SITE in "${SITES[@]}"; do
    echo "--------------------------------------------"
    echo "$(date) - Processing site: ${SITE}"

    ############################################
    # LOAD CONFIG
    ############################################
    echo "$(date) - Loading config for ${SITE}"
    source "config/${SITE}.sh"

    ############################################
    # LOAD SECRETS
    ############################################
    echo "$(date) - Loading secrets for ${SITE}"
    source "secrets/${SITE}.env"

    ############################################
    # BACKUP
    ############################################
    if [[ "$FULL_BACKUP" == true ]]; then
        echo "$(date) - Running FULL backup (${SITE}) with tags: ${TAG}, full-backup"
        if /usr/bin/restic backup "${FOLDERS[@]}" --tag "${TAG}" --tag full-backup; then
            echo "$(date) - Full backup ${SITE} completato"
            notify_kuma "up" "Full backup ${SITE} completato"
        else
            echo "$(date) - Full backup ${SITE} FALLITO, ma i container verranno comunque riavviati"
            notify_kuma "down" "Full backup ${SITE} FALLITO"
        fi
    else
        echo "$(date) - Running regular backup (${SITE}) with tag: ${TAG}"
        if /usr/bin/restic backup "${FOLDERS[@]}" --tag "${TAG}"; then
            echo "$(date) - Backup incrementale ${SITE} completato"
            notify_kuma "up" "Backup incrementale ${SITE} completato"
        else
            echo "$(date) - Backup incrementale ${SITE} FALLITO, ma i container verranno comunque riavviati"
            notify_kuma "down" "Backup incrementale ${SITE} FALLITO"
        fi
    fi
done

echo "$(date) - Multi-site backup completed."

############################################
# RIAVVIO (solo se STOP_DOCKER=true)
############################################
if [[ "$STOP_DOCKER" == true ]]; then
    echo "Restarting ${DOCKER_C_LIST} projects"
    for PROJECT in ${DOCKER_C_FILTERED}; do
        echo "Starting project ${PROJECT}"
        docker compose -p ${PROJECT} start
    done
else
    echo "Skipping docker restart because STOP_DOCKER=false"
fi

echo "=== Backup ended at $(date) ==="

