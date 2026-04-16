# 🔋 Embedded Power Audit

Utility Bash per eseguire un audit rapido dei consumi e degli indizi di power management su sistemi Linux embedded.

Nasce da un caso d'uso su piattaforme **NXP i.MX6 / i.MX8**, ma il progetto è stato rinominato e documentato in modo da poter crescere facilmente verso **altre famiglie SoC / SoM** senza cambiare naming o struttura del repository.

## Cosa fa

Lo script raccoglie informazioni da `sysfs`, `procfs` e, quando disponibile, da `systemd` per offrire una vista sintetica su:

- frequenza CPU e governor
- temperatura e tensione disponibili via sysfs
- idle states / cpuidle
- interrupt più frequenti
- autosuspend USB
- runtime PM dei device
- wakeup abilitati e wakeup sources
- telemetria power supply
- disponibilità del suspend lato systemd
- **stima percentuale del contributo ai consumi per sottosistema**
- suggerimenti pratici per ottimizzare i consumi

Lo script **non modifica** la configurazione del sistema: esegue solo letture e produce un report testuale o JSON.

## Requisiti

- Linux embedded con accesso a `/proc` e `/sys`
- `bash`
- utility standard presenti in quasi tutte le distro embedded:
  - `awk`
  - `grep`
  - `find`
  - `sort`
  - `head`
  - `sed`
  - `hostname`
  - `uname`

Opzionali:

- `systemctl`
- `systemd-inhibit`
- `debugfs` montato su `/sys/kernel/debug` per analizzare `wakeup_sources`

## File principali

- `embedded_power_audit.sh` — script principale
- `power_profiles/imx6.heuristic.conf` — profilo euristico iniziale per i.MX6
- `power_profiles/imx8.heuristic.conf` — profilo euristico iniziale per i.MX8
- `README.md` — documentazione del progetto

## 🚀 Utilizzo

Rendi eseguibile lo script:

```bash
chmod +x embedded_power_audit.sh
```

Esegui il report completo:

```bash
./embedded_power_audit.sh
```

Output JSON:

```bash
./embedded_power_audit.sh --json
```

Solo suggerimenti:

```bash
./embedded_power_audit.sh --suggest-only
```

Salvataggio su file di log:

```bash
./embedded_power_audit.sh --log audit.log
```

Uso di un profilo specifico:

```bash
./embedded_power_audit.sh --profile ./power_profiles/imx8.heuristic.conf
```

Aiuto:

```bash
./embedded_power_audit.sh --help
```

### CPU

- frequenza corrente
- governor attivo
- utilizzo su campione breve
- frequenze disponibili, se esposte
- `time_in_state`, se disponibile

### Temperatura

Lo script cerca automaticamente una `thermal_zone` adatta, compatibile anche con casi come:

- `imx_thermal_zone`
- zone con nome contenente `cpu`
- zone con nome contenente `soc`

Se la temperatura non è leggibile, il report la segnala come **non disponibile** invece di mostrare `0 °C`.

### Warning termici

Le soglie usate sono:

- **65°C**: temperatura moderata, da monitorare
- **75°C**: warning
- **85°C**: warning alto / possibile throttling

Queste soglie sono conservative e pensate per audit preliminare. Il limite reale dipende dal SoC, dalla variante commerciale/industrial, dal package, dal dissipatore e dall'ambiente operativo.

### Idle states

Se il kernel espone `cpuidle`, lo script legge:

- nome stato
- latenza
- tempo trascorso nello stato
- usage count
- stato di enable/disable

Se il kernel non espone `cpuidle`, il report lo indica chiaramente.

### USB

Controlla:

- interrupt USB
- `power/control` dei device USB

Questo aiuta a capire quali periferiche sono ancora in `on` invece che in `auto`.

### Runtime PM

Legge `power/runtime_status` per i device esposti in sysfs e mostra:

- quanti risultano `active`
- quanti risultano `suspended`
- quanti risultano `suspending` / `resuming`
- un sample dei device attivi

### Wakeup

Lo script controlla:

- device con `power/wakeup=enabled`
- `wakeup_sources` dal kernel, se disponibile in debugfs

Questo aiuta a capire se esistono sorgenti di wakeup rumorose o periferiche che possono impedire il raggiungimento di stati low-power.

### Stima del contributo ai consumi

Lo script include una sezione **Estimated Power Share** che produce una stima relativa per questi sottosistemi:

- `cpu`
- `ddr`
- `display`
- `usb`
- `net`
- `storage`
- `audio`
- `background`

La stima non deriva da sensori fisici: usa indicatori di attività letti dal sistema, come:

- `%` di utilizzo CPU
- rapporto tra frequenza corrente e massima
- `runtime_status` dei device
- interrupt USB / display
- traffico rete campionato in una breve finestra
- I/O storage da `/proc/diskstats`
- backlight quando disponibile

L'output è utile per:

- confrontare run diversi sulla **stessa board**
- capire quali sottosistemi pesano di più
- tarare progressivamente i coefficienti del profilo

Non va interpretato come misura elettrica certificata in watt per singolo device.

## Esempio di output

```text
==================================================
 Embedded Linux Power Audit
==================================================
[SYSTEM] Host: my-board
[SYSTEM] Kernel: 6.1.x  Arch: aarch64  Uptime(s): 12345.67
[SYSTEM] Platform: i.MX8

[CPU] Freq: 1200 MHz  Governor: powersave  Usage: 7%
[VOLTAGE/TEMP] 950 mV  49 °C
[MEM] Used: 38%
[POWER ESTIMATE] Profile: imx8-heuristic  Total(est): 1240 mW
  cpu=18% (225 mW, conf=medium)
  ddr=10% (130 mW, conf=low)
  display=24% (298 mW, conf=low)
  usb=4% (55 mW, conf=medium)
  net=7% (92 mW, conf=medium)
  storage=2% (31 mW, conf=medium)
  audio=0% (0 mW, conf=low)
  background=35% (409 mW, conf=low)
...
```

## Supporto attuale

Al momento la **rilevazione della piattaforma** riconosce automaticamente:

- `i.MX6`
- `i.MX8`

Il resto dello script è volutamente basato su interfacce Linux generiche (`/proc`, `/sys`, `systemd`) e quindi può essere utile anche su altre piattaforme, purché espongano informazioni compatibili.

## Come estendere il supporto ad altre SoC / SoM

Il punto principale da estendere è la funzione:

```bash
detect_platform_family()
```

Dentro questa funzione puoi aggiungere nuovi pattern basati su `model` e `compatible`, per esempio:

```bash
elif echo "$model $compatible" | grep -qi 'am62'; then
    echo "TI AM62"
elif echo "$model $compatible" | grep -qi 'rk3588'; then
    echo "Rockchip RK3588"
```

### Linee guida consigliate

- mantieni il nome del progetto generico
- aggiungi la logica di detection in un solo punto
- evita path hardcoded specifici di una board quando possibile
- preferisci controlli basati su feature disponibili in `sysfs`
- quando una metrica non è disponibile, continua a produrre un report utile invece di fallire

## Come tarare i profili

I file in `power_profiles/` contengono pesi euristici, per esempio:

```bash
PROFILE_NAME="imx8-heuristic"
BASELINE_IDLE_MW=420
CPU_DYN_MW=1800
DDR_DYN_MW=500
DISPLAY_DYN_MW=900
USB_DYN_MW=180
NET_DYN_MW=250
STORAGE_DYN_MW=120
AUDIO_DYN_MW=80
BACKGROUND_DYN_MW=100
USB_IRQ_SAT=500
DISPLAY_IRQ_SAT=500
NET_BPS_SAT=50000000
STORAGE_BPS_SAT=20000000
```

Per migliorare la stima:

- aumenta `DISPLAY_DYN_MW` se il display sembra pesare troppo poco
- riduci `BACKGROUND_DYN_MW` se il baseline domina sempre il totale
- aumenta o riduci le soglie `*_SAT` in base ai volumi reali di traffico/IRQ della tua board
- crea un profilo separato per board o per variante hardware

## Limitazioni

- alcuni path in `sysfs` possono non essere esposti dalla tua board o dal tuo kernel
- il valore di tensione letto potrebbe non corrispondere al rail CPU se il primo regolatore disponibile non è quello corretto
- `wakeup_sources` richiede spesso `debugfs`
- la stima percentuale è **modellata**, non misurata
- DDR e background sono in genere le componenti meno precise senza sensori reali

## Idee per evoluzioni future

- mapping per famiglie SoC aggiuntive
- profili board-specifici opzionali
- output JSON più strutturato per integrazione CI / telemetry
- filtri per sottosistemi specifici
- export CSV o Markdown
- modalità confronto prima/dopo una modifica di power tuning
- supporto a profili esterni caricati da file `.conf`

## Quando usarlo

Utile per:

- bring-up di nuove board
- analisi preliminare dei consumi
- verifica di runtime PM e wakeup sources
- regressioni di power management dopo update kernel / device tree
- raccolta rapida di informazioni prima di un tuning più mirato
- confronto tra build o configurazioni kernel differenti

## Avvertenza

Questo tool è pensato come **audit iniziale**. Non sostituisce misure strumentali esterne, analisi con oscilloscopio/power analyzer o profilazioni specifiche del PMIC.

##  📄 License

This project is licensed under the MIT License. See the `LICENSE` file for details.
