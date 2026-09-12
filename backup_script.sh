#!/bin/bash

LOG_FILE="/var/log/restic-backup.log"
exec >> "$LOG_FILE" 2>&1
echo "=== Backup started at $(date) ==="

# Lista progetti docker
DOCKER_C=$(docker compose ls -q)
# Calcolo giorno dell'anno (001-365)
DAY_OF_YEAR=$(date +%j)
FULL_BACKUP=false
FREQUENCY="${FREQUENCY:-1}"

# Change dir
SCRIPT_DIR="$(dirname "$(realpath "$0")")"
cd "$SCRIPT_DIR" || {
    echo "Errore: impossibile entrare in $SCRIPT_DIR"
    exit 1
}

# Load config
GENERAL_CONFIG_FILE="config/general_config.sh"
if [[ -f "$GENERAL_CONFIG_FILE" ]]; then
    source "$GENERAL_CONFIG_FILE"
else
    echo "$(date) - ERROR: Config file not found: $GENERAL_CONFIG_FILE"
    exit 1
fi

if (( DAY_OF_YEAR % FREQUENCY == 0 )); then
    FULL_BACKUP=true
    echo "Full backup day: ignoring exclude list"
else
    echo "Regular backup day: applying exclude list: ${DAY_OF_YEAR} % ${FREQUENCY} = $(( DAY_OF_YEAR % FREQUENCY ))"
    exit 1
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

pause_exec() {
        echo "$(date) - Pausa di ${1} secondi prima della prossima attività di post-backup"
        if [[ -n $1 ]]; then
            sleep "$1"
        fi
}

############################################
# FUNZIONE: LOAD CONFIG + SECRETS PER SITE
############################################
load_site_env() {
    local SITE="$1"

    local CONFIG_FILE="config/${SITE}.sh"
    local SECRETS_FILE="secrets/${SITE}.env"

    echo "$(date) - Loading config for ${SITE}"

    if [[ -f "$CONFIG_FILE" ]]; then
        source "$CONFIG_FILE"
    else
        echo "$(date) - ERROR: Config file not found: $CONFIG_FILE"
        return 1
    fi

    echo "$(date) - Loading secrets for ${SITE}"

    if [[ -f "$SECRETS_FILE" ]]; then
        source "$SECRETS_FILE"
    else
        echo "$(date) - ERROR: Secrets file not found: $SECRETS_FILE"
        return 1
    fi

    return 0
}


reset_this_vars() {
    for var in "$@"; do
        unset "$var"
    done
}

reset_vars() {
    secret_vars=("RESTIC_REPOSITORY" "RESTIC_PASSWORD_FILE" "RESTIC_PASSWORD" "AWS_ACCESS_KEY_ID" "AWS_SECRET_ACCESS_KEY" "UPTIME_URL")
    config_vars=("TAG" "FOLDERS" "RETENTION_FULL_LAST_N" "RETENTION_FULL_N_MONTH" "RETENTION_REGULAR_N_DAYS" "RETENTION_DRY_RUN" "RECHECK_DATA_PERC")
    reset_this_vars "${secret_vars[@]}" "${config_vars[@]}"
    
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

    if ! load_site_env "$SITE"; then
        echo "$(date) - Skipping backup - SITE ${SITE} due to missing config/secrets"
        continue
    fi

    ############################################
    # BACKUP
    ############################################
    if [[ "$FULL_BACKUP" == true ]]; then
        echo "$(date) - Site ${SITE} - Full-backup - tags: ${TAG}"
        if /usr/bin/restic backup "${FOLDERS[@]}" --tag "${TAG}" --tag full-backup; then
            echo "$(date) - Site ${SITE} - Full backup completato"
            notify_kuma "up" "Full-backup ${SITE} completato"
        else
            echo "$(date) - Site ${SITE} - Full backup FALLITO"
            notify_kuma "down" "Full-backup ${SITE} FALLITO"
        fi
    else
        echo "$(date) - Site ${SITE} - Backup giornaliero - tag: ${TAG}"
        if /usr/bin/restic backup "${FOLDERS[@]}" --tag "${TAG}"; then
            echo "$(date) - Site ${SITE} - Backup giornaliero completato"
            notify_kuma "up" "Backup giornaliero ${SITE} completato"
        else
            echo "$(date) - Site ${SITE} - Backup giornaliero FALLITO"
            notify_kuma "down" "Backup giornaliero ${SITE} FALLITO"
        fi
    fi
    reset_vars
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

############################################
# OPERAZIONI POST BACKUP
############################################

for SITE in "${SITES[@]}"; do

    if ! load_site_env "$SITE"; then
        echo "$(date) - Skipping post-backup - SITE ${SITE} due to missing config/secrets"
        continue
    fi

    if [[ "$FULL_BACKUP" == true ]]; then
    ### RETENTION BACKUP ###
        if [[ -n "$RETENTION_FULL_LAST_N" ]] || \
        [[ -n "$RETENTION_FULL_N_MONTH" ]] || \
        [[ -n "$RETENTION_REGULAR_N_DAYS" ]]; then
            RETENTION_DRY_RUN="${RETENTION_DRY_RUN:-false}"
            DRY_RUN=""
            if [[ "$RETENTION_DRY_RUN" == "true" ]]; then
                DRY_RUN="--dry-run"
            fi

            if [[ -n "$RETENTION_FULL_LAST_N" ]] && \
            [[ -n "$RETENTION_FULL_N_MONTH" ]]; then
                echo "$(date) - Site ${SITE} - Applicazione della retention policy full-backup"
                pause_exec "$PAUSE_BETWEEN_CHECKS"
                /usr/bin/restic forget \
                    --tag full-backup \
                    --keep-last ${RETENTION_FULL_LAST_N:-4} \
                    --keep-monthly ${RETENTION_FULL_N_MONTH:-12} ${DRY_RUN}
            else
                echo "$(date) - Site ${SITE} - Nessuna retention policy per i full-backup"
            fi


            if [[ -n "$RETENTION_REGULAR_N_DAYS" ]]; then
                # Incrementali: ultimi 30 giorni di calendario
                echo "$(date) - Site ${SITE} - Applicazione della retention policy backup giornalieri"
                pause_exec "$PAUSE_BETWEEN_CHECKS"
                /usr/bin/restic forget \
                    --tag "${TAG}" \
                    --keep-daily ${RETENTION_REGULAR_N_DAYS:-30} ${DRY_RUN}
            else
                echo "$(date) - Site ${SITE} - Nessuna retention policy per i backup giornalieri"
            fi

            # Prune una sola volta
            if [[ "$RETENTION_DRY_RUN" != "true" ]]; then
                echo "$(date) - Site ${SITE} - Pulizia dei vecchi dati"
                pause_exec "$PAUSE_BETWEEN_CHECKS"
                /usr/bin/restic prune
            else
                echo "$(date) - Site ${SITE} - Dry-run - Nessuna pulizia"
            fi
        else
            echo "$(date) - Site ${SITE} - Nessuna retention policy definita definita, skip"
        fi
    fi
    
    ### RICONTROLLO DEI DATI ###
    if [[ -z "$RECHECK_DATA_PERC" ]]; then
        echo "$(date) - Site ${SITE} - RECHECK_DATA_PERC non definito, skip recheck"        
    elif ! [[ "$RECHECK_DATA_PERC" =~ ^[0-9]+([.][0-9]+)?$ ]]; then
        echo "$(date) - ERROR: RECHECK_DATA_PERC deve essere un numero (int o float). Valore ricevuto: '$RECHECK_DATA_PERC'"
    elif (( $(echo "$RECHECK_DATA_PERC < 0" | bc -l) )) || (( $(echo "$RECHECK_DATA_PERC > 100" | bc -l) )); then
        echo "$(date) - ERROR: RECHECK_DATA_PERC deve essere tra 0 e 100. Valore ricevuto: $RECHECK_DATA_PERC"
    else
        echo "$(date) - Site ${SITE} - Rifaccio il check del ${RECHECK_DATA_PERC}% dei dati"
        pause_exec "$PAUSE_BETWEEN_CHECKS"
        /usr/bin/restic check --read-data-subset="${RECHECK_DATA_PERC}%"
    fi

    reset_vars
done

echo "=== Backup ended at $(date) ==="

