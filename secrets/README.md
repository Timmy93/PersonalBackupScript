🔐 Scopo
La cartella `secrets/` contiene tutte le variabili **sensibili** utilizzate dallo script di backup, una per ogni site:

- Password Restic
- File `.env` Restic
- Token Uptime Kuma
- API keys
- Credenziali varie

Questi file **non devono mai essere versionati**.

---

📦 Struttura dei file
Ogni file deve seguire la convenzione:

`SECRETS_<SITE>`
`UPTIME_URL` (opzionale)

Esempio:
```bash
SECRETS_MI="/home/timmy/Documents/backup_tools/restic-env.sh"
UPTIME_URL="https://uptime.kuma/push/XXXXXXXX"
```
---

🔄 Caricamento
Lo script principale esegue:

    source secrets/<SITE>.env

per ogni site presente nell’array:

    SITES=("MI" "MC")

---

🛠️ Linee guida
- Mantieni ogni site nel proprio file (`MI.env`, `MC.env`, ecc.)
- Non inserire configurazioni non sensibili
- Mantieni la stessa struttura per tutti i site
- Usa nomi coerenti: `SECRETS_MI`, `SECRETS_MC`, ecc.
