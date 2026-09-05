📌 Scopo
La cartella `config/` contiene tutte le configurazioni **non sensibili** utilizzate dallo script di backup.  
Ogni file rappresenta un *site* (es. `MI.sh`, `1F.sh`) e definisce:

- Cartelle da includere nel backup
- Tag Restic
- Parametri operativi del site
- Liste di esclusione
- Altre impostazioni non sensibili

Questi file **non devono contenere password, token o credenziali**.

---

📦 Struttura dei file
Ogni file deve seguire la convenzione:

`TAG_<SITE>`
`FOLDERS_<SITE>`
`EXCLUDE_LIST` (opzionale)

Esempio:
```bash
TAG_MI="mc-bck"

FOLDERS_MI=(
    "/home/user"
    "/media/user/HDD"
)

EXCLUDE_LIST="network storage traefik-mc"
```
---

🔄 Caricamento
Lo script principale esegue:

    source config/<SITE>.sh

per ogni site presente nell’array:

    SITES=("MI" "MC")

---

🛠️ Linee guida
- Mantieni ogni site nel proprio file (`MI.sh`, `MC.sh`, ecc.)
- Non inserire credenziali o token
- Mantieni la stessa struttura per tutti i site
- Usa nomi coerenti: `TAG_MI`, `FOLDERS_MI`, ecc.

