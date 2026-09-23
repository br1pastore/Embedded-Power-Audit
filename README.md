# 🔋 Embedded Power Audit

Utility Bash per eseguire un audit rapido dei consumi e degli indizi di power management su sistemi Linux embedded.

Nasce da un caso d'uso su piattaforme **NXP i.MX6 / i.MX8**, ma oggi include supporto e rilevazione per più famiglie SoC / SoM, mantenendo un approccio il più possibile generico basato sulle interfacce Linux standard (`/proc`, `/sys`, IIO, runtime PM).

## Cosa fa

Lo script raccoglie informazioni da `sysfs`, `procfs` e, quando disponibile, da `systemd` per offrire una vista sintetica su:

- frequenza CPU e governor
- **CPUFreq multi-policy** per SoC con cluster eterogenei
- temperatura da `thermal_zone` e fallback **IIO/XADC** su piattaforme Xilinx compatibili
- tensione/regulator sample quando esposto dal kernel
- idle states / cpuidle
- interrupt più frequenti
- autosuspend USB
- runtime PM dei device
- wakeup abilitati e wakeup sources
- telemetria power supply
- disponibilità del suspend lato systemd
- diagnostica Qualcomm tramite `devfreq` e `remoteproc`, quando disponibili
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
- `power_profiles/imx6.heuristic.conf` — profilo euristico per i.MX6
- `power_profiles/imx8.heuristic.conf` — profilo euristico per i.MX8
- eventuali profili aggiuntivi in `power_profiles/` — selezionati automaticamente quando presenti
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
- numero di policy CPUFreq rilevate
- riepilogo delle singole `policy*` con CPU associate, frequenza corrente, frequenza massima, governor e rapporto percentuale

Su SoC eterogenei, per esempio piattaforme Qualcomm moderne con cluster differenti, lo script evita di ridurre l'intera CPU a una sola frequenza e usa le policy disponibili per produrre una vista più rappresentativa.

### Temperatura

Lo script cerca automaticamente una `thermal_zone` adatta, compatibile anche con casi come:

- `imx_thermal_zone`
- zone con nome contenente `cpu`
- zone con nome contenente `soc`
- zone Qualcomm / TSENS quando esposte dal kernel

Se non trova una temperatura valida tramite il framework thermal standard, può usare fallback specifici di piattaforma.

Su **Xilinx Zynq-7000**, quando presente un device IIO `xadc`, legge:

- `in_temp0_raw`
- `in_temp0_offset`
- `in_temp0_scale`

e calcola la temperatura di giunzione tramite i parametri esposti dal driver IIO.

Il report indica anche la sorgente, per esempio:

```text
[TEMP] 80 °C  (source: iio:xadc)
```

Se la temperatura non è leggibile, il report la segnala come **non disponibile** invece di mostrare `0 °C`.

### Warning termici

Le soglie usate sono:

- **65°C**: temperatura moderata, da monitorare
- **75°C**: warning
- **85°C**: warning alto / possibile throttling

Queste soglie sono conservative e pensate per audit preliminare. Il limite reale dipende dal SoC, dalla variante commerciale/industrial, dal package, dal dissipatore e dall'ambiente operativo.

### Idle states

Se il kernel espone `cpuidle`, lo script individua la directory che contiene realmente gli `state*` e legge:

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

### Qualcomm / Dragonwing

Quando viene rilevata una piattaforma Qualcomm, lo script raccoglie anche informazioni aggiuntive quando esposte dal kernel:

- device presenti in `/sys/class/devfreq`
- frequenza corrente / minima / massima dei device devfreq
- governor devfreq
- numero e stato dei `remoteproc`
- IRQ riconducibili a WLAN, modem, IPA, QRTR e sottosistemi Qualcomm
- policy CPUFreq multiple sui SoC con cluster eterogenei

Queste informazioni sono particolarmente utili su piattaforme con CPU, GPU, DSP, NPU e altri coprocessori che possono rimanere attivi anche quando il carico CPU è basso.

Il supporto specifico a **Qualcomm Dragonwing IQ8 / QCS8275 / Toradex Aquila IQ8** è predisposto nello script, ma va considerato **experimental fino alla validazione su hardware reale**.

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
- rapporto tra frequenza corrente e massima; sui sistemi multi-policy viene usata una sintesi delle policy CPUFreq disponibili
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
[REGULATOR SAMPLE] 950 mV
[TEMP] 49 °C  (source: thermal:imx_thermal_zone)
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

La **rilevazione della piattaforma** riconosce automaticamente:

| Famiglia | Stato |
|---|---|
| NXP i.MX6 | supportata |
| NXP i.MX8 | supportata |
| NXP i.MX93 | supportata |
| Raspberry Pi | supportata |
| Xilinx Zynq-7000 / MicroZed / ZedBoard /SOM-MY | supportata |
| Qualcomm QRB2210 / Arduino UNO Q | **experimental / hardware validation wanted** |
| Qualcomm generico | supporto generico |
| Qualcomm Dragonwing IQ8 / QCS8275 / Toradex Aquila IQ8 | **experimental / hardware validation wanted** |

Il resto dello script rimane volutamente basato su interfacce Linux generiche (`/proc`, `/sys`, runtime PM, CPUFreq, devfreq, IIO) e quindi può essere utile anche su piattaforme non riconosciute esplicitamente.

Quando non è disponibile un profilo euristico dedicato, viene usato il profilo `generic-heuristic`: in questo caso la stima dei consumi va interpretata come **comparativa e a bassa confidenza**, non come misura assoluta.

## Come estendere il supporto ad altre SoC / SoM

Il punto principale da estendere è la funzione:

```bash
detect_platform_family()
```

Dentro questa funzione puoi aggiungere nuovi pattern basati su `model`, `compatible` e, quando utile, `soc_id`. Conviene riconoscere prima le piattaforme specifiche e lasciare per ultimo il fallback generico della famiglia. Per esempio:

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

## Hardware validation wanted

Il progetto è aperto a test su nuove piattaforme embedded Linux.

In particolare è utile raccogliere output reali da:
- **Qualcomm QRB2210 / Arduino UNO Q**
- **Qualcomm Dragonwing IQ8 / QCS8275**
- **Toradex Aquila IQ8**
- altre piattaforme Qualcomm recenti
- nuovi SoC / SoM che espongono CPUFreq, devfreq, runtime PM, thermal o IIO

Per una prima validazione sono sufficienti:

```bash
./embedded_power_audit.sh
./embedded_power_audit.sh --json > audit.json
```

Bug report, output di test e pull request sono benvenuti.

## Limitazioni

- alcuni path in `sysfs` possono non essere esposti dalla tua board o dal tuo kernel
- il valore di tensione letto potrebbe non corrispondere al rail CPU se il primo regolatore disponibile non è quello corretto
- non tutti i BSP espongono CPUFreq, devfreq, thermal, IIO o remoteproc nello stesso modo
- `wakeup_sources` richiede spesso `debugfs`
- la stima percentuale è **modellata**, non misurata
- DDR, acceleratori, coprocessori e background sono in genere le componenti meno precise senza sensori reali
- il supporto QCS8275 / Aquila IQ8 è predisposto ma deve ancora essere validato su hardware reale

## Idee per evoluzioni future

- mapping per famiglie SoC aggiuntive
- profili board-specifici opzionali, incluso un futuro profilo validato per QCS8275
- campionamento degli interrupt come **IRQ/s** per evidenziare interrupt storm
- telemetria più specifica per GPU / NPU / DSP quando esposta dal kernel
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
