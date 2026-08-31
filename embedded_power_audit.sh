#!/usr/bin/env bash

# Embedded Linux power audit utility.
# Current platform detection targets NXP i.MX6 / i.MX8 / i.MX93,
# Raspberry Pi, and Qualcomm Linux platforms including QRB2210 / Arduino UNO Q.
# The script name and comments are intentionally generic so new SoC / SoM
# families can be added without renaming the project.
#
# Usage:
#   ./embedded_power_audit.sh
#   ./embedded_power_audit.sh --json
#   ./embedded_power_audit.sh --suggest-only
#   ./embedded_power_audit.sh --log audit.log
#   ./embedded_power_audit.sh --profile ./power_profiles/imx8.heuristic.conf

set -o pipefail

SCRIPT_DIR="$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)"

JSON_OUTPUT=0
LOG_FILE=""
SUGGEST_ONLY=0
PROFILE_FILE=""
TIMESTAMP="$(date +"%Y-%m-%dT%H:%M:%S%z")"

TEMP_WARN_MODERATE=65
TEMP_WARN_HIGH=75
TEMP_WARN_CRIT=85

declare -a SUGGESTIONS=()

log() {
    local msg="$1"
    if [ -n "$LOG_FILE" ]; then
        echo "[$TIMESTAMP] $msg" >> "$LOG_FILE"
    fi
    echo "$msg"
}

safe_cat() {
    local f="$1"
    if [ -n "$f" ] && [ -r "$f" ]; then
        cat "$f"
    else
        echo ""
    fi
}

num_or_zero() {
    local v="$1"
    if [[ "$v" =~ ^[0-9]+$ ]]; then
        echo "$v"
    else
        echo 0
    fi
}

json_escape() {
    local s="$1"
    s=${s//\\/\\\\}
    s=${s//\"/\\\"}
    s=${s//$'\n'/\\n}
    s=${s//$'\r'/}
    s=${s//$'\t'/\\t}
    printf '%s' "$s"
}

find_first_matching_file() {
    local base="$1"
    local name="$2"
    [ -d "$base" ] || return 1
    find "$base" -type f -name "$name" 2>/dev/null | head -n 1
}

short_sys_path() {
    local p="$1"
    p="${p#/sys/}"
    printf '%s' "$p"
}

parse_vcgencmd_temp_c() {
    local raw="$1"
    # temp=54.8'C
    raw="${raw#temp=}"
    raw="${raw%%\'C*}"
    raw="${raw%%.*}"
    if [[ "$raw" =~ ^-?[0-9]+$ ]]; then
        echo "$raw"
    else
        echo -1
    fi
}

parse_vcgencmd_clock_mhz() {
    local raw="$1"
    local hz
    # frequency(48)=600000000
    hz="${raw##*=}"
    if [[ "$hz" =~ ^[0-9]+$ ]]; then
        echo $((hz / 1000000))
    else
        echo 0
    fi
}

parse_vcgencmd_throttled_hex() {
    local raw="$1"
    # throttled=0x50005
    raw="${raw#throttled=}"
    raw="${raw#0x}"
    if [[ "$raw" =~ ^[0-9a-fA-F]+$ ]]; then
        echo "$((16#$raw))"
    else
        echo 0
    fi
}

bit_is_set() {
    local value="$1"
    local bit="$2"
    [ $(( value & (1 << bit) )) -ne 0 ] && echo 1 || echo 0
}

detect_platform_family() {
    local model="$1"
    local compatible="$2"
    local soc_id="$3"

    # Extend this function with additional boards / SoC families.
    # Example:
    #   elif echo "$model $compatible" | grep -qi 'am62'; then
    #       echo "TI AM62"
    #   elif echo "$model $compatible" | grep -qi 'rk3588'; then
    #       echo "Rockchip RK3588"

    if echo "$model $compatible $soc_id" | grep -Eqi 'arduino[ ,_-]*uno[ ,_-]*q|qrb2210|qcom,qrb2210'; then
        echo "Qualcomm QRB2210"
    elif echo "$model $compatible $soc_id" | grep -Eqi 'qualcomm|(^|[ ,])qcom[, -]'; then
        echo "Qualcomm"
    elif echo "$model $compatible $soc_id" | grep -Eqi 'raspberry|bcm27'; then
        echo "Raspberry Pi"
    elif echo "$model $compatible $soc_id" | grep -qi 'imx93'; then
        echo "i.MX93"
    elif echo "$model $compatible $soc_id" | grep -qi 'imx8'; then
        echo "i.MX8"
    elif echo "$model $compatible $soc_id" | grep -qi 'imx6'; then
        echo "i.MX6"
    else
        echo "unknown"
    fi
}

clamp_pct() {
    local v
    v="$(num_or_zero "$1")"
    [ "$v" -lt 0 ] && v=0
    [ "$v" -gt 100 ] && v=100
    echo "$v"
}

max_from_list() {
    local s="$1"
    local max=0
    local n
    for n in $s; do
        n="$(num_or_zero "$n")"
        [ "$n" -gt "$max" ] && max="$n"
    done
    echo "$max"
}

saturating_pct() {
    local value sat
    value="$(num_or_zero "$1")"
    sat="$(num_or_zero "$2")"
    if [ "$sat" -le 0 ]; then
        echo 0
        return
    fi
    if [ "$value" -ge "$sat" ]; then
        echo 100
    else
        echo $((100 * value / sat))
    fi
}

count_runtime_matches() {
    local regex="$1"
    local total=0
    local active=0
    local f status dev_dir

    for f in /sys/bus/*/devices/*/power/runtime_status; do
        [ -r "$f" ] || continue
        dev_dir="$(dirname "$(dirname "$f")")"
        if printf '%s\n' "$dev_dir" | grep -Eqi "$regex"; then
            total=$((total + 1))
            status="$(safe_cat "$f")"
            [ "$status" = "active" ] && active=$((active + 1))
        fi
    done
    echo "$active $total"
}

sum_net_bytes() {
    local total=0
    local ifc rx tx
    for ifc in /sys/class/net/*; do
        [ -d "$ifc" ] || continue
        [ "$(basename "$ifc")" = "lo" ] && continue
        rx="$(num_or_zero "$(safe_cat "$ifc/statistics/rx_bytes")")"
        tx="$(num_or_zero "$(safe_cat "$ifc/statistics/tx_bytes")")"
        total=$((total + rx + tx))
    done
    echo "$total"
}

count_up_net_ifaces() {
    local cnt=0
    local ifc state
    for ifc in /sys/class/net/*; do
        [ -d "$ifc" ] || continue
        [ "$(basename "$ifc")" = "lo" ] && continue
        state="$(safe_cat "$ifc/operstate")"
        [ "$state" = "up" ] && cnt=$((cnt + 1))
    done
    echo "$cnt"
}

sum_storage_bytes_estimate() {
    awk '
        $3 ~ /^(mmcblk|sd[a-z]|nvme[0-9]+n[0-9]+)$/ {
            sectors_read=$6
            sectors_written=$10
            sum += (sectors_read + sectors_written) * 512
        }
        END { print sum+0 }
    ' /proc/diskstats 2>/dev/null
}

backlight_activity_pct() {
    local best=0
    local b cur max pct
    for b in /sys/class/backlight/*; do
        [ -d "$b" ] || continue
        cur="$(num_or_zero "$(safe_cat "$b/brightness")")"
        max="$(num_or_zero "$(safe_cat "$b/max_brightness")")"
        [ "$max" -le 0 ] && continue
        pct=$((100 * cur / max))
        [ "$pct" -gt "$best" ] && best="$pct"
    done
    echo "$best"
}

load_power_profile() {
    local candidate="$1"

    PROFILE_SOURCE="generic-fallback"
    GENERIC_FALLBACK=1
    RECOMMENDED_PROFILE=""

    if [ -n "$candidate" ] && [ -r "$candidate" ]; then
        # shellcheck disable=SC1090
        . "$candidate"
        PROFILE_SOURCE="explicit"
        GENERIC_FALLBACK=0
        return 0
    fi

    case "$PLATFORM_FAMILY" in
        "Qualcomm QRB2210")
            [ -r "$SCRIPT_DIR/power_profiles/qrb2210.heuristic.conf" ] && \
                RECOMMENDED_PROFILE="$SCRIPT_DIR/power_profiles/qrb2210.heuristic.conf"
            ;;

        "Qualcomm")
            [ -r "$SCRIPT_DIR/power_profiles/qualcomm.heuristic.conf" ] && \
                RECOMMENDED_PROFILE="$SCRIPT_DIR/power_profiles/qualcomm.heuristic.conf"
            ;;

        "Raspberry Pi")
            [ -r "$SCRIPT_DIR/power_profiles/raspberrypi.heuristic.conf" ] && \
                RECOMMENDED_PROFILE="$SCRIPT_DIR/power_profiles/raspberrypi.heuristic.conf"
            ;;

        "i.MX93")
            [ -r "$SCRIPT_DIR/power_profiles/imx93.heuristic.conf" ] && \
                RECOMMENDED_PROFILE="$SCRIPT_DIR/power_profiles/imx93.heuristic.conf"
            ;;

        "i.MX6")
            [ -r "$SCRIPT_DIR/power_profiles/imx6.heuristic.conf" ] && \
                RECOMMENDED_PROFILE="$SCRIPT_DIR/power_profiles/imx6.heuristic.conf"
            ;;
        "i.MX8")
            [ -r "$SCRIPT_DIR/power_profiles/imx8.heuristic.conf" ] && \
                RECOMMENDED_PROFILE="$SCRIPT_DIR/power_profiles/imx8.heuristic.conf"
            ;;
    esac

    PROFILE_NAME="generic-heuristic"
    BASELINE_IDLE_MW=260
    CPU_DYN_MW=1000
    DDR_DYN_MW=260
    DISPLAY_DYN_MW=620
    USB_DYN_MW=140
    NET_DYN_MW=150
    STORAGE_DYN_MW=90
    AUDIO_DYN_MW=50
    BACKGROUND_DYN_MW=30
    USB_IRQ_SAT=300
    DISPLAY_IRQ_SAT=300
    NET_BPS_SAT=20000000
    STORAGE_BPS_SAT=10000000
}

json_print_estimate_entry() {
    local name="$1"
    local mw="$2"
    local pct="$3"
    local confidence="$4"
    local comma="$5"
    printf '    "%s":{"estimated_mw":%d,"estimated_pct":%d,"confidence":"%s"}%s\n' \
        "$(json_escape "$name")" "$mw" "$pct" "$(json_escape "$confidence")" "$comma"
}

confidence_from_pct() {
    local pct="$1"
    local generic="$2"

    if [ "$generic" -eq 1 ]; then
        if [ "$pct" -ge 70 ]; then
            echo "medium"
        else
            echo "low"
        fi
    else
        if [ "$pct" -ge 70 ]; then
            echo "high"
        elif [ "$pct" -ge 35 ]; then
            echo "medium"
        else
            echo "low"
        fi
    fi
}

compute_confidences() {
    CPU_CONF="$(confidence_from_pct "$CPU_USAGE_PCT" "$GENERIC_FALLBACK")"
    DDR_CONF="low"
    DISPLAY_CONF="$(confidence_from_pct "$DISPLAY_EVIDENCE_PCT" "$GENERIC_FALLBACK")"
    USB_CONF="$(confidence_from_pct "$USB_EVIDENCE_PCT" "$GENERIC_FALLBACK")"
    NET_CONF="$(confidence_from_pct "$NET_EVIDENCE_PCT" "$GENERIC_FALLBACK")"
    STORAGE_CONF="$(confidence_from_pct "$STORAGE_EVIDENCE_PCT" "$GENERIC_FALLBACK")"
    AUDIO_CONF="$(confidence_from_pct "$AUDIO_EVIDENCE_PCT" "$GENERIC_FALLBACK")"
    BACKGROUND_CONF="low"
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        -j|--json)
            JSON_OUTPUT=1
            shift
            ;;
        -l|--log)
            LOG_FILE="$2"
            shift 2
            ;;
        -s|--suggest-only)
            SUGGEST_ONLY=1
            shift
            ;;
        -p|--profile)
            PROFILE_FILE="$2"
            shift 2
            ;;
        -h|--help)
            echo "Usage: $0 [-j|--json] [-l|--log FILE] [-s|--suggest-only] [-p|--profile FILE]"
            exit 0
            ;;
        *)
            echo "Unknown arg: $1"
            exit 2
            ;;
    esac
done

HOSTNAME="$(hostname 2>/dev/null)"
KERNEL="$(uname -r 2>/dev/null)"
ARCH="$(uname -m 2>/dev/null)"
UPTIME_STR="$(awk '{print $1}' /proc/uptime 2>/dev/null)"
MEM_TOTAL="$(awk '/MemTotal/ {print $2}' /proc/meminfo 2>/dev/null)"
MEM_FREE="$(awk '/MemAvailable/ {print $2}' /proc/meminfo 2>/dev/null)"

MODEL=""
if [ -r /proc/device-tree/model ]; then
    MODEL="$(tr -d '\000' < /proc/device-tree/model)"
fi

COMPATIBLE=""
if [ -r /proc/device-tree/compatible ]; then
    COMPATIBLE="$(tr '\000' ' ' < /proc/device-tree/compatible)"
fi

SOC_ID=""
for soc_id_file in /sys/devices/soc0/soc_id /sys/devices/system/soc/soc0/id; do
    if [ -r "$soc_id_file" ]; then
        SOC_ID="$(safe_cat "$soc_id_file")"
        [ -n "$SOC_ID" ] && break
    fi
done

PLATFORM_FAMILY="$(detect_platform_family "$MODEL" "$COMPATIBLE" "$SOC_ID")"

QCOM_DEVFREQ_COUNT=0
QCOM_REMOTEPROC_COUNT=0
QCOM_DEVFREQ_SAMPLE=""
if [ "$PLATFORM_FAMILY" = "Qualcomm QRB2210" ] || [ "$PLATFORM_FAMILY" = "Qualcomm" ]; then
    if [ -d /sys/class/devfreq ]; then
        QCOM_DEVFREQ_COUNT="$(find /sys/class/devfreq -mindepth 1 -maxdepth 1 \( -type l -o -type d \) 2>/dev/null | wc -l | tr -d ' ')"
        QCOM_DEVFREQ_COUNT="$(num_or_zero "$QCOM_DEVFREQ_COUNT")"
        QCOM_DEVFREQ_SAMPLE="$(find /sys/class/devfreq -mindepth 1 -maxdepth 1 \( -type l -o -type d \) -printf '%f\n' 2>/dev/null | head -n 8)"
    fi
    if [ -d /sys/class/remoteproc ]; then
        QCOM_REMOTEPROC_COUNT="$(find /sys/class/remoteproc -mindepth 1 -maxdepth 1 \( -type l -o -type d \) 2>/dev/null | wc -l | tr -d ' ')"
        QCOM_REMOTEPROC_COUNT="$(num_or_zero "$QCOM_REMOTEPROC_COUNT")"
    fi
fi

RPI_VCGENCMD_PRESENT=0
RPI_TEMP_C=-1
RPI_ACTUAL_FREQ_MHZ=0
RPI_THROTTLED_VALUE=0

RPI_UNDERVOLT_NOW=0
RPI_FREQ_CAPPED_NOW=0
RPI_THROTTLED_NOW=0
RPI_SOFT_TEMP_NOW=0
RPI_UNDERVOLT_OCCURRED=0
RPI_FREQ_CAPPED_OCCURRED=0
RPI_THROTTLED_OCCURRED=0
RPI_SOFT_TEMP_OCCURRED=0

if [ "$PLATFORM_FAMILY" = "Raspberry Pi" ] && command -v vcgencmd >/dev/null 2>&1; then
    RPI_VCGENCMD_PRESENT=1

    VC_TEMP_RAW="$(vcgencmd measure_temp 2>/dev/null)"
    VC_CLOCK_RAW="$(vcgencmd measure_clock arm 2>/dev/null)"
    VC_THROTTLED_RAW="$(vcgencmd get_throttled 2>/dev/null)"

    RPI_TEMP_C="$(parse_vcgencmd_temp_c "$VC_TEMP_RAW")"
    RPI_ACTUAL_FREQ_MHZ="$(parse_vcgencmd_clock_mhz "$VC_CLOCK_RAW")"
    RPI_THROTTLED_VALUE="$(parse_vcgencmd_throttled_hex "$VC_THROTTLED_RAW")"

    RPI_UNDERVOLT_NOW="$(bit_is_set "$RPI_THROTTLED_VALUE" 0)"
    RPI_FREQ_CAPPED_NOW="$(bit_is_set "$RPI_THROTTLED_VALUE" 1)"
    RPI_THROTTLED_NOW="$(bit_is_set "$RPI_THROTTLED_VALUE" 2)"
    RPI_SOFT_TEMP_NOW="$(bit_is_set "$RPI_THROTTLED_VALUE" 3)"
    RPI_UNDERVOLT_OCCURRED="$(bit_is_set "$RPI_THROTTLED_VALUE" 16)"
    RPI_FREQ_CAPPED_OCCURRED="$(bit_is_set "$RPI_THROTTLED_VALUE" 17)"
    RPI_THROTTLED_OCCURRED="$(bit_is_set "$RPI_THROTTLED_VALUE" 18)"
    RPI_SOFT_TEMP_OCCURRED="$(bit_is_set "$RPI_THROTTLED_VALUE" 19)"
fi

CPU_FREQ_FILE="$(find_first_matching_file /sys/devices/system/cpu scaling_cur_freq)"
CPU_GOV_FILE="$(find_first_matching_file /sys/devices/system/cpu scaling_governor)"
CPU_AVAIL_FREQ_FILE="$(find_first_matching_file /sys/devices/system/cpu scaling_available_frequencies)"
CPU_TIME_IN_STATE_FILE="$(find_first_matching_file /sys/devices/system/cpu time_in_state)"
CPU_MAX_FREQ_FILE="$(find_first_matching_file /sys/devices/system/cpu cpuinfo_max_freq)"

TEMP_FILE=""
for z in /sys/class/thermal/thermal_zone*; do
    [ -d "$z" ] || continue
    ttype="$(safe_cat "$z/type")"
    case "$ttype" in
        *cpu*|*CPU*|*soc*|*SoC*|*imx*|*qcom*|*tsens*|*thermal*)
            if [ -r "$z/temp" ]; then
                TEMP_FILE="$z/temp"
                break
            fi
            ;;
    esac
done

if [ -z "$TEMP_FILE" ]; then
    for z in /sys/class/thermal/thermal_zone*; do
        [ -r "$z/temp" ] || continue
        TEMP_FILE="$z/temp"
        break
    done
fi

TEMP_TYPE=""
if [ -n "$TEMP_FILE" ]; then
    TEMP_TYPE="$(safe_cat "$(dirname "$TEMP_FILE")/type")"
fi

REGULATOR_FILE=""
REGULATOR_NAME=""
REGULATOR_MV=0
REGULATOR_IS_CPU_LIKE=0

for mv in /sys/class/regulator/*/microvolts; do
    [ -r "$mv" ] || continue
    REGULATOR_FILE="$mv"
    REG_DIR="$(dirname "$mv")"
    if [ -r "$REG_DIR/name" ]; then
        REGULATOR_NAME="$(safe_cat "$REG_DIR/name")"
    else
        REGULATOR_NAME="$(basename "$REG_DIR")"
    fi
    REGULATOR_UV="$(num_or_zero "$(safe_cat "$mv")")"
    if [ "$REGULATOR_UV" -gt 0 ]; then
        REGULATOR_MV=$((REGULATOR_UV / 1000))
    fi
    case "$REGULATOR_NAME" in
        *cpu*|*CPU*|*arm*|*ARM*|*vddarm*|*VDDARM*|*vdd_cpu*|*VDD_CPU*|*buck*cpu*|*buck*arm*)
            REGULATOR_IS_CPU_LIKE=1
            ;;
    esac
    break
done

FREQ="$(num_or_zero "$(safe_cat "$CPU_FREQ_FILE")")"
GOV="$(safe_cat "$CPU_GOV_FILE")"
VOLT="$(num_or_zero "$(safe_cat "$REGULATOR_FILE")")"
CPU_SCALING_AVAILABLE="$(safe_cat "$CPU_AVAIL_FREQ_FILE")"
CPU_STATS="$(safe_cat "$CPU_TIME_IN_STATE_FILE")"
CPU_MAX_FREQ="$(num_or_zero "$(safe_cat "$CPU_MAX_FREQ_FILE")")"
MEM_TOTAL="$(num_or_zero "$MEM_TOTAL")"
MEM_FREE="$(num_or_zero "$MEM_FREE")"

if [ "$CPU_MAX_FREQ" -eq 0 ]; then
    CPU_MAX_FREQ="$(max_from_list "$CPU_SCALING_AVAILABLE")"
fi

TEMP_RAW="$(num_or_zero "$(safe_cat "$TEMP_FILE")")"
TEMP_C=-1
if [ "$TEMP_RAW" -ge 1000 ]; then
    TEMP_C=$((TEMP_RAW / 1000))
elif [ "$TEMP_RAW" -gt 0 ]; then
    TEMP_C=$TEMP_RAW
fi

FREQ_MHZ=0
VOLT_MV=0
[ "$FREQ" -gt 0 ] && FREQ_MHZ=$((FREQ / 1000))
[ "$VOLT" -gt 0 ] && VOLT_MV=$((VOLT / 1000))

REQUESTED_FREQ_MHZ="$FREQ_MHZ"

if [ "$PLATFORM_FAMILY" = "Raspberry Pi" ] && [ "$RPI_VCGENCMD_PRESENT" -eq 1 ]; then
    [ "$RPI_TEMP_C" -ge 0 ] && TEMP_C="$RPI_TEMP_C"
    [ "$RPI_ACTUAL_FREQ_MHZ" -gt 0 ] && FREQ_MHZ="$RPI_ACTUAL_FREQ_MHZ"
fi

NET_BYTES_PREV="$(num_or_zero "$(sum_net_bytes)")"
STORAGE_BYTES_PREV="$(num_or_zero "$(sum_storage_bytes_estimate)")"
read -r cpu_prev_idle cpu_prev_total < <(
    awk '/^cpu / {idle=$5; total=0; for(i=2;i<=NF;i++) total+=$i; print idle, total}' /proc/stat
)
sleep 0.5
NET_BYTES_CUR="$(num_or_zero "$(sum_net_bytes)")"
STORAGE_BYTES_CUR="$(num_or_zero "$(sum_storage_bytes_estimate)")"
read -r cpu_idle cpu_total < <(
    awk '/^cpu / {idle=$5; total=0; for(i=2;i<=NF;i++) total+=$i; print idle, total}' /proc/stat
)

NET_BYTES_DELTA=$((NET_BYTES_CUR - NET_BYTES_PREV))
STORAGE_BYTES_DELTA=$((STORAGE_BYTES_CUR - STORAGE_BYTES_PREV))
[ "$NET_BYTES_DELTA" -lt 0 ] && NET_BYTES_DELTA=0
[ "$STORAGE_BYTES_DELTA" -lt 0 ] && STORAGE_BYTES_DELTA=0

cpu_prev_idle="$(num_or_zero "$cpu_prev_idle")"
cpu_prev_total="$(num_or_zero "$cpu_prev_total")"
cpu_idle="$(num_or_zero "$cpu_idle")"
cpu_total="$(num_or_zero "$cpu_total")"

cpu_delta=$((cpu_total - cpu_prev_total))
idle_delta=$((cpu_idle - cpu_prev_idle))
CPU_USAGE_PCT=0
if [ "$cpu_delta" -gt 0 ]; then
    CPU_USAGE_PCT=$(((100 * (cpu_delta - idle_delta)) / cpu_delta))
fi

IDLE_INFO=""
CPUIDLE_BASE=""
if [ -d /sys/devices/system/cpu/cpuidle ]; then
    CPUIDLE_BASE="/sys/devices/system/cpu/cpuidle"
elif [ -d /sys/devices/system/cpu/cpu0/cpuidle ]; then
    CPUIDLE_BASE="/sys/devices/system/cpu/cpu0/cpuidle"
fi

if [ -n "$CPUIDLE_BASE" ]; then
    for s in "$CPUIDLE_BASE"/state*; do
        [ -d "$s" ] || continue
        [ -r "$s/name" ] || continue
        nm="$(safe_cat "$s/name")"
        lat="$(num_or_zero "$(safe_cat "$s/latency")")"
        time_spent="$(num_or_zero "$(safe_cat "$s/time")")"
        usage="$(num_or_zero "$(safe_cat "$s/usage")")"
        disable="$(safe_cat "$s/disable")"
        disable="${disable:-0}"
        IDLE_INFO+="$nm|lat=$lat|time=$time_spent|usage=$usage|disable=$disable"$'\n'
    done
fi

TOP_INTERRUPTS="$({
    awk 'NR>1 {
        sum=0
        for (i=2; i<=NF-1; i++) {
            if ($i ~ /^[0-9]+$/) sum+=$i
        }
        if (sum > 0) print sum, $NF
    }' /proc/interrupts 2>/dev/null | sort -rn | head -n 5
} || true)"

USB_INTERRUPTS="$({
    awk 'BEGIN{IGNORECASE=1; sum=0}
         /usb/ {
             for (i=2; i<=NF-1; i++) if ($i ~ /^[0-9]+$/) sum+=$i
         }
         END{print sum+0}' /proc/interrupts 2>/dev/null
} || echo 0)"

DISPLAY_INTERRUPTS="$({
    awk 'BEGIN{IGNORECASE=1; sum=0}
         /ipu|dpu|dcss|lcdif|mipi|drm|hdmi|lvds|mdss|sde|dsi/ {
             for (i=2; i<=NF-1; i++) if ($i ~ /^[0-9]+$/) sum+=$i
         }
         END{print sum+0}' /proc/interrupts 2>/dev/null
} || echo 0)"

USB_AUTOSUSPEND_STATUS=""
for d in /sys/bus/usb/devices/*/power/control; do
    [ -r "$d" ] || continue
    val="$(safe_cat "$d")"
    USB_AUTOSUSPEND_STATUS+="$d:$val"$'\n'
done

SYSTEMD_PRESENT=0
SYSTEMD_SUSPEND_AVAILABLE=0
SYSTEMD_INHIBITORS=""
if command -v systemctl >/dev/null 2>&1; then
    SYSTEMD_PRESENT=1
    if systemctl list-unit-files 2>/dev/null | grep -Eq '^(sleep|suspend|hybrid-sleep)\.target'; then
        SYSTEMD_SUSPEND_AVAILABLE=1
    fi
    if command -v systemd-inhibit >/dev/null 2>&1; then
        SYSTEMD_INHIBITORS="$(systemd-inhibit --list 2>/dev/null || true)"
    fi
fi

PS_POWER=""
for p in /sys/class/power_supply/*; do
    [ -d "$p" ] || continue
    if [ -r "$p/power_now" ]; then
        PS_POWER+="$p: power_now=$(safe_cat "$p/power_now")"$'\n'
    elif [ -r "$p/current_now" ] || [ -r "$p/voltage_now" ]; then
        PS_POWER+="$p: current_now=$(safe_cat "$p/current_now") voltage_now=$(safe_cat "$p/voltage_now")"$'\n'
    fi
done

NET_IRQS="$(grep -Ei 'eth|fec|eqos|stmmac|wifi|wlan|rtl|ath|brcm|cnss|wcn|ipa|rmnet|qrtr' /proc/interrupts 2>/dev/null || true)"

# Runtime PM inventory
RPM_TOTAL=0
RPM_ACTIVE=0
RPM_SUSPENDED=0
RPM_SUSPENDING=0
RPM_RESUMING=0
RPM_UNSUPPORTED=0
RPM_UNKNOWN=0
RPM_ACTIVE_SAMPLE=""
RPM_ACTIVE_SAMPLE_COUNT=0

for f in /sys/bus/*/devices/*/power/runtime_status; do
    [ -r "$f" ] || continue
    status="$(safe_cat "$f")"
    RPM_TOTAL=$((RPM_TOTAL + 1))

    case "$status" in
        active) RPM_ACTIVE=$((RPM_ACTIVE + 1)) ;;
        suspended) RPM_SUSPENDED=$((RPM_SUSPENDED + 1)) ;;
        suspending) RPM_SUSPENDING=$((RPM_SUSPENDING + 1)) ;;
        resuming) RPM_RESUMING=$((RPM_RESUMING + 1)) ;;
        unsupported) RPM_UNSUPPORTED=$((RPM_UNSUPPORTED + 1)) ;;
        *) RPM_UNKNOWN=$((RPM_UNKNOWN + 1)) ;;
    esac

    if [ "$status" = "active" ] && [ "$RPM_ACTIVE_SAMPLE_COUNT" -lt 15 ]; then
        power_dir="$(dirname "$f")"
        dev_dir="$(dirname "$power_dir")"
        ctrl="$(safe_cat "$power_dir/control")"
        wakeup="$(safe_cat "$power_dir/wakeup")"
        runtime_enabled="$(safe_cat "$power_dir/runtime_enabled")"
        RPM_ACTIVE_SAMPLE+="$(short_sys_path "$dev_dir")|status=$status|control=${ctrl:-n/d}|wakeup=${wakeup:-n/d}|runtime_enabled=${runtime_enabled:-n/d}"$'\n'
        RPM_ACTIVE_SAMPLE_COUNT=$((RPM_ACTIVE_SAMPLE_COUNT + 1))
    fi
done

# Wakeup-enabled devices inventory
WAKEUP_DEV_TOTAL=0
WAKEUP_DEV_ENABLED=0
WAKEUP_DEV_DISABLED=0
WAKEUP_DEV_SAMPLE=""
WAKEUP_DEV_SAMPLE_COUNT=0

for f in /sys/bus/*/devices/*/power/wakeup; do
    [ -r "$f" ] || continue
    val="$(safe_cat "$f")"
    WAKEUP_DEV_TOTAL=$((WAKEUP_DEV_TOTAL + 1))
    case "$val" in
        enabled)
            WAKEUP_DEV_ENABLED=$((WAKEUP_DEV_ENABLED + 1))
            if [ "$WAKEUP_DEV_SAMPLE_COUNT" -lt 15 ]; then
                power_dir="$(dirname "$f")"
                dev_dir="$(dirname "$power_dir")"
                ctrl="$(safe_cat "$power_dir/control")"
                status="$(safe_cat "$power_dir/runtime_status")"
                WAKEUP_DEV_SAMPLE+="$(short_sys_path "$dev_dir")|wakeup=enabled|control=${ctrl:-n/d}|runtime_status=${status:-n/d}"$'\n'
                WAKEUP_DEV_SAMPLE_COUNT=$((WAKEUP_DEV_SAMPLE_COUNT + 1))
            fi
            ;;
        disabled)
            WAKEUP_DEV_DISABLED=$((WAKEUP_DEV_DISABLED + 1))
            ;;
    esac
done

# Kernel wakeup sources (debugfs)
WAKEUP_SOURCES_AVAILABLE=0
WAKEUP_TOP=""
TOP_WAKEUP_NAME=""
TOP_WAKEUP_EVENTS=0

if [ -r /sys/kernel/debug/wakeup_sources ]; then
    WAKEUP_SOURCES_AVAILABLE=1
    WAKEUP_TOP="$(
        awk '
            NR == 1 { next }
            NF >= 3 {
                name=$1
                active=$2
                event=$3
                if (active ~ /^[0-9]+$/ && event ~ /^[0-9]+$/) {
                    print event, active, name
                }
            }' /sys/kernel/debug/wakeup_sources 2>/dev/null | sort -rn | head -n 10
    )"
    TOP_WAKEUP_EVENTS="$(echo "$WAKEUP_TOP" | awk 'NR==1 {print $1}')"
    TOP_WAKEUP_NAME="$(echo "$WAKEUP_TOP" | awk 'NR==1 {print $3}')"
    TOP_WAKEUP_EVENTS="$(num_or_zero "$TOP_WAKEUP_EVENTS")"
fi

# Heuristic suggestions
if [ -z "$GOV" ]; then
    SUGGESTIONS+=("Governor non disponibile: verificare supporto cpufreq/cpufreq-dt nel kernel e nel device tree.")
elif [ "$GOV" != "powersave" ] && [ "$CPU_USAGE_PCT" -lt 20 ]; then
    SUGGESTIONS+=("CPU a basso carico (${CPU_USAGE_PCT}%). Valuta governor 'powersave' o policy equivalente per ridurre i consumi.")
fi

TEMP_WARN_MODERATE_LOCAL="$TEMP_WARN_MODERATE"
TEMP_WARN_HIGH_LOCAL="$TEMP_WARN_HIGH"
TEMP_WARN_CRIT_LOCAL="$TEMP_WARN_CRIT"

if [ "$PLATFORM_FAMILY" = "Raspberry Pi" ]; then
    TEMP_WARN_MODERATE_LOCAL=70
    TEMP_WARN_HIGH_LOCAL=80
    TEMP_WARN_CRIT_LOCAL=85
fi

if [ "$TEMP_C" -lt 0 ]; then
    SUGGESTIONS+=("Temperatura non disponibile: verificare thermal_zone o vcgencmd.")
elif [ "$TEMP_C" -ge "$TEMP_WARN_CRIT_LOCAL" ]; then
    SUGGESTIONS+=("Temperatura alta (${TEMP_C}°C): possibile throttling o margine termico ridotto. Verificare dissipazione e carico.")
elif [ "$TEMP_C" -ge "$TEMP_WARN_HIGH_LOCAL" ]; then
    SUGGESTIONS+=("Temperatura sostenuta (${TEMP_C}°C): controllare dissipazione, airflow e carico CPU/GPU.")
elif [ "$TEMP_C" -ge "$TEMP_WARN_MODERATE_LOCAL" ]; then
    SUGGESTIONS+=("Temperatura moderata (${TEMP_C}°C): monitorare il comportamento termico sotto carico prolungato.")
fi

if [ "$PLATFORM_FAMILY" = "Raspberry Pi" ] && [ "$RPI_VCGENCMD_PRESENT" -eq 1 ]; then
    if [ "$RPI_UNDERVOLT_NOW" -eq 1 ]; then
        SUGGESTIONS+=("Raspberry Pi: under-voltage rilevato adesso. Verificare alimentatore, cavo e cadute di tensione.")
    elif [ "$RPI_UNDERVOLT_OCCURRED" -eq 1 ]; then
        SUGGESTIONS+=("Raspberry Pi: eventi di under-voltage rilevati dal boot. Verificare alimentatore e cavo.")
    fi

    if [ "$RPI_FREQ_CAPPED_NOW" -eq 1 ] || [ "$RPI_FREQ_CAPPED_OCCURRED" -eq 1 ]; then
        SUGGESTIONS+=("Raspberry Pi: frequency cap rilevato dal firmware. Controllare alimentazione e condizioni termiche.")
    fi

    if [ "$RPI_THROTTLED_NOW" -eq 1 ] || [ "$RPI_THROTTLED_OCCURRED" -eq 1 ]; then
        SUGGESTIONS+=("Raspberry Pi: throttling rilevato dal firmware. Verificare temperatura, alimentazione e raffreddamento.")
    fi

    if [ "$RPI_SOFT_TEMP_NOW" -eq 1 ] || [ "$RPI_SOFT_TEMP_OCCURRED" -eq 1 ]; then
        SUGGESTIONS+=("Raspberry Pi: soft temperature limit attivo o occorso. Migliorare dissipazione o ridurre il carico.")
    fi
fi

if [ "$PLATFORM_FAMILY" = "Qualcomm QRB2210" ] || [ "$PLATFORM_FAMILY" = "Qualcomm" ]; then
    if [ "$QCOM_DEVFREQ_COUNT" -gt 0 ]; then
        SUGGESTIONS+=("Qualcomm: devfreq disponibile su ${QCOM_DEVFREQ_COUNT} device. Verificare governor e frequenze di GPU/DDR/interconnect durante idle e carico.")
    fi

    if grep -Eqi 'cnss|wcn|ipa|rmnet|qrtr' /proc/interrupts 2>/dev/null; then
        SUGGESTIONS+=("Qualcomm: rilevate IRQ riconducibili a WLAN/modem/IPA/QRTR. Controllare che radio e servizi di connettività non necessari possano entrare in runtime suspend.")
    fi

    [ "$QCOM_REMOTEPROC_COUNT" -gt 0 ] && \
        SUGGESTIONS+=("Qualcomm: ${QCOM_REMOTEPROC_COUNT} remoteproc rilevati. DSP/modem coprocessor possono incidere sul consumo anche con CPU A53 poco carica.")
fi

if [ -z "$REGULATOR_FILE" ]; then
    SUGGESTIONS+=("Nessun regolatore con microvolts leggibile: la telemetria PMIC può non essere esposta in sysfs su questa board.")
elif [ "$REGULATOR_IS_CPU_LIKE" -eq 1 ] && [ "$REGULATOR_MV" -gt 1300 ]; then
    SUGGESTIONS+=("Il regolatore '$REGULATOR_NAME' sembra un rail CPU/core e riporta ${REGULATOR_MV} mV: verificare DVFS, OPP e vincoli del regulator.")
fi

if [ -z "$IDLE_INFO" ]; then
    SUGGESTIONS+=("C-states non disponibili: abilitare/verificare CPU idle nel kernel e controllare driver che impediscono il low-power idle.")
else
    deep_used=0
    total_time=0
    while IFS= read -r line; do
        [ -n "$line" ] || continue
        time_val="$(echo "$line" | sed -n 's/.*|time=\([0-9][0-9]*\).*/\1/p')"
        name="$(echo "$line" | cut -d'|' -f1)"
        time_val="$(num_or_zero "$time_val")"
        total_time=$((total_time + time_val))
        if echo "$name" | grep -Eqi 'deep|retention|suspend|low-power|lp'; then
            deep_used=$((deep_used + time_val))
        fi
    done <<< "$IDLE_INFO"

    if [ "$total_time" -gt 0 ] && [ "$deep_used" -lt $((total_time / 10)) ]; then
        SUGGESTIONS+=("Gli stati idle profondi risultano poco usati; verificare wakeup source, timer periodici e configurazione tickless/nohz.")
    fi
fi

if [ -n "$USB_AUTOSUSPEND_STATUS" ]; then
    sample_auto="$(echo "$USB_AUTOSUSPEND_STATUS" | grep -c ':auto$')"
    sample_on="$(echo "$USB_AUTOSUSPEND_STATUS" | grep -c ':on$')"
    if [ "$sample_auto" -eq 0 ] && [ "$sample_on" -gt 0 ]; then
        SUGGESTIONS+=("I device USB campionati risultano tutti in 'on'. Dove possibile, impostare 'auto' su /sys/bus/usb/devices/.../power/control.")
    else
        SUGGESTIONS+=("Controllare quali device USB devono restare in 'on' e quali possono essere lasciati in autosuspend.")
    fi
else
    SUGGESTIONS+=("Percorsi USB power/control non leggibili: verificare supporto runtime PM USB nel kernel e nei driver.")
fi

SUGGESTIONS+=("Per rendere persistente l'autosuspend USB, usare una regola udev o un servizio systemd oneshot al boot.")

if [ "$SYSTEMD_PRESENT" -eq 1 ]; then
    if [ "$SYSTEMD_SUSPEND_AVAILABLE" -eq 1 ]; then
        SUGGESTIONS+=("systemd presente con target di sleep/suspend disponibili. Testare il suspend e verificare eventuali inhibitor attivi.")
        if [ -n "$SYSTEMD_INHIBITORS" ] && ! echo "$SYSTEMD_INHIBITORS" | grep -q '^No inhibitors\.$'; then
            SUGGESTIONS+=("Sono presenti inhibitor systemd; controllare i processi che bloccano suspend o idle.")
        fi
    else
        SUGGESTIONS+=("systemd presente ma i target di sleep/suspend non risultano disponibili: verificare configurazione distro e supporto PM della board.")
    fi
else
    SUGGESTIONS+=("systemd non rilevato: gestire suspend/resume con gli strumenti della distro o script custom.")
fi

if ls /sys/class/regulator >/dev/null 2>&1; then
    SUGGESTIONS+=("Per undervolting o tuning DVFS, preferire modifiche al device tree/regulator constraints invece di path hardcoded come regulator.1.")
else
    SUGGESTIONS+=("/sys/class/regulator non disponibile: il driver PMIC potrebbe non esporre i rail in sysfs.")
fi

if [ -n "$NET_IRQS" ]; then
    SUGGESTIONS+=("Sono presenti IRQ di rete: verificare wake-on-lan, polling, link management e driver che generano wakeup inutili.")
fi

if [ "$DISPLAY_INTERRUPTS" -gt 0 ]; then
    SUGGESTIONS+=("Sono state rilevate IRQ display/video (${DISPLAY_INTERRUPTS}). Se il display è attivo è normale; in modalità low-power conviene spegnere pipeline video non necessarie.")
fi

if [ "$CPU_USAGE_PCT" -gt 50 ]; then
    SUGGESTIONS+=("CPU molto occupata (${CPU_USAGE_PCT}%): identificare i processi più attivi e valutare limiti di frequenza o ottimizzazioni applicative.")
fi

if [ "$RPM_TOTAL" -gt 0 ] && [ "$RPM_ACTIVE" -gt 0 ]; then
    SUGGESTIONS+=("Runtime PM: ${RPM_ACTIVE}/${RPM_TOTAL} device risultano 'active'. Controllare i device sempre attivi e valutare 'power/control=auto' dove supportato.")
fi

if [ "$WAKEUP_DEV_ENABLED" -gt 0 ]; then
    NONTRIVIAL_WAKEUP=0
    while IFS= read -r line; do
        [ -n "$line" ] || continue
        case "$line" in
            *snvs-rtc*|*alarmtimer*)
                ;;
            *)
                NONTRIVIAL_WAKEUP=1
                ;;
        esac
    done <<< "$WAKEUP_DEV_SAMPLE"

    if [ "$NONTRIVIAL_WAKEUP" -eq 1 ]; then
        SUGGESTIONS+=("Wakeup abilitato su ${WAKEUP_DEV_ENABLED} device. Disabilitare il wakeup sui device non necessari può ridurre risvegli indesiderati.")
    fi
fi

if [ "$WAKEUP_SOURCES_AVAILABLE" -eq 0 ]; then
    SUGGESTIONS+=("wakeup_sources non disponibile. Se serve analisi più profonda, montare debugfs e verificare /sys/kernel/debug/wakeup_sources.")
elif [ "$TOP_WAKEUP_EVENTS" -gt 100 ]; then
    SUGGESTIONS+=("Wakeup source più attiva: '${TOP_WAKEUP_NAME}' con ${TOP_WAKEUP_EVENTS} eventi. Verificare se genera risvegli periodici non necessari.")
fi

mem_used_pct=0
if [ "$MEM_TOTAL" -gt 0 ] && [ "$MEM_FREE" -ge 0 ]; then
    mem_used_pct=$((100 - (100 * MEM_FREE / MEM_TOTAL)))
    if [ "$mem_used_pct" -gt 80 ]; then
        SUGGESTIONS+=("Memoria usata circa ${mem_used_pct}%: ridurre il footprint applicativo ed evitare swap aggressivo su storage lento.")
    fi
fi

load_power_profile "$PROFILE_FILE"

read -r usb_active usb_total < <(count_runtime_matches '/sys/bus/usb/')
read -r display_active display_total < <(count_runtime_matches 'drm|dcss|dpu|ipu|lcdif|mipi|hdmi|lvds|mdss|sde|dsi')
read -r audio_active audio_total < <(count_runtime_matches 'audio|sound|snd|i2s|sai|esai|spdif|pcm|lpass|q6afe|q6asm')

CPU_FREQ_RATIO_PCT=100
if [ "$CPU_MAX_FREQ" -gt 0 ] && [ "$FREQ" -gt 0 ]; then
    CPU_FREQ_RATIO_PCT=$((100 * FREQ / CPU_MAX_FREQ))
    CPU_FREQ_RATIO_PCT="$(clamp_pct "$CPU_FREQ_RATIO_PCT")"
fi

USB_ACTIVE_PCT=0
if [ "$usb_total" -gt 0 ]; then
    USB_ACTIVE_PCT=$((100 * usb_active / usb_total))
fi
USB_IRQ_PCT="$(saturating_pct "$USB_INTERRUPTS" "$USB_IRQ_SAT")"
USB_ACTIVITY_PCT=$(((2 * USB_ACTIVE_PCT + USB_IRQ_PCT) / 3))
USB_ACTIVITY_PCT="$(clamp_pct "$USB_ACTIVITY_PCT")"

DISPLAY_ACTIVE_PCT=0
if [ "$display_total" -gt 0 ]; then
    DISPLAY_ACTIVE_PCT=$((100 * display_active / display_total))
fi
DISPLAY_IRQ_PCT="$(saturating_pct "$DISPLAY_INTERRUPTS" "$DISPLAY_IRQ_SAT")"
BACKLIGHT_PCT="$(backlight_activity_pct)"
DISPLAY_ACTIVITY_PCT=$(((DISPLAY_ACTIVE_PCT + DISPLAY_IRQ_PCT + BACKLIGHT_PCT) / 3))
DISPLAY_ACTIVITY_PCT="$(clamp_pct "$DISPLAY_ACTIVITY_PCT")"

NET_BPS=$((NET_BYTES_DELTA * 2))
NET_TRAFFIC_PCT="$(saturating_pct "$NET_BPS" "$NET_BPS_SAT")"
NET_UP_IFACES="$(count_up_net_ifaces)"
NET_LINK_PCT=0
[ "$NET_UP_IFACES" -gt 0 ] && NET_LINK_PCT=100
NET_ACTIVITY_PCT=$(((2 * NET_TRAFFIC_PCT + NET_LINK_PCT) / 3))
NET_ACTIVITY_PCT="$(clamp_pct "$NET_ACTIVITY_PCT")"

STORAGE_BPS=$((STORAGE_BYTES_DELTA * 2))
STORAGE_ACTIVITY_PCT="$(saturating_pct "$STORAGE_BPS" "$STORAGE_BPS_SAT")"
STORAGE_ACTIVITY_PCT="$(clamp_pct "$STORAGE_ACTIVITY_PCT")"

AUDIO_ACTIVE_PCT=0
if [ "$audio_total" -gt 0 ]; then
    AUDIO_ACTIVE_PCT=$((100 * audio_active / audio_total))
fi
AUDIO_ACTIVITY_PCT="$(clamp_pct "$AUDIO_ACTIVE_PCT")"

DDR_ACTIVITY_PCT=$((
    (35 * CPU_USAGE_PCT +
     25 * DISPLAY_ACTIVITY_PCT +
     20 * STORAGE_ACTIVITY_PCT +
     20 * NET_ACTIVITY_PCT) / 100
))
DDR_ACTIVITY_PCT="$(clamp_pct "$DDR_ACTIVITY_PCT")"

USB_ON_COUNT="$(printf '%s\n' "$USB_AUTOSUSPEND_STATUS" | grep -c ':on$' 2>/dev/null || true)"
[ -z "$USB_ON_COUNT" ] && USB_ON_COUNT=0

DISPLAY_SIGNAL=0
if [ "$DISPLAY_ACTIVE_PCT" -gt 0 ] || [ "$DISPLAY_IRQ_PCT" -gt 5 ] || [ "$BACKLIGHT_PCT" -gt 0 ]; then
    DISPLAY_SIGNAL=1
fi

MMC_HINT=0
if echo "$TOP_INTERRUPTS" | grep -qi 'mmc'; then
    MMC_HINT=1
fi

if [ "$GENERIC_FALLBACK" -eq 1 ]; then
    if [ "$DISPLAY_SIGNAL" -eq 1 ] && [ "$DISPLAY_ACTIVITY_PCT" -lt 35 ]; then
        DISPLAY_ACTIVITY_PCT=35
    fi

    if [ "$USB_ON_COUNT" -gt 0 ]; then
        usb_floor=$((20 + USB_ON_COUNT * 8))
        [ "$usb_floor" -gt 60 ] && usb_floor=60
        [ "$USB_ACTIVITY_PCT" -lt "$usb_floor" ] && USB_ACTIVITY_PCT="$usb_floor"
    fi

    if [ "$MMC_HINT" -eq 1 ] && [ "$STORAGE_ACTIVITY_PCT" -lt 5 ]; then
        STORAGE_ACTIVITY_PCT=5
    fi
fi

CPU_EST_MW=$((CPU_DYN_MW * CPU_USAGE_PCT * CPU_FREQ_RATIO_PCT / 10000))
DDR_EST_MW=$((DDR_DYN_MW * DDR_ACTIVITY_PCT / 100))
DISPLAY_EST_MW=$((DISPLAY_DYN_MW * DISPLAY_ACTIVITY_PCT / 100))
USB_EST_MW=$((USB_DYN_MW * USB_ACTIVITY_PCT / 100))
NET_EST_MW=$((NET_DYN_MW * NET_ACTIVITY_PCT / 100))
STORAGE_EST_MW=$((STORAGE_DYN_MW * STORAGE_ACTIVITY_PCT / 100))
AUDIO_EST_MW=$((AUDIO_DYN_MW * AUDIO_ACTIVITY_PCT / 100))
BACKGROUND_EST_MW=$((BASELINE_IDLE_MW + BACKGROUND_DYN_MW))

USB_EVIDENCE_PCT="$USB_ACTIVITY_PCT"
DISPLAY_EVIDENCE_PCT="$DISPLAY_ACTIVITY_PCT"
NET_EVIDENCE_PCT="$NET_ACTIVITY_PCT"
STORAGE_EVIDENCE_PCT="$STORAGE_ACTIVITY_PCT"
AUDIO_EVIDENCE_PCT="$AUDIO_ACTIVITY_PCT"

EST_TOTAL_MW=$((CPU_EST_MW + DDR_EST_MW + DISPLAY_EST_MW + USB_EST_MW + NET_EST_MW + STORAGE_EST_MW + AUDIO_EST_MW + BACKGROUND_EST_MW))
[ "$EST_TOTAL_MW" -le 0 ] && EST_TOTAL_MW=1

if [ "$GENERIC_FALLBACK" -eq 1 ]; then
    generic_cap=$((EST_TOTAL_MW / 4))
    [ "$generic_cap" -lt 220 ] && generic_cap=220
    [ "$BACKGROUND_EST_MW" -gt "$generic_cap" ] && BACKGROUND_EST_MW="$generic_cap"
    EST_TOTAL_MW=$((CPU_EST_MW + DDR_EST_MW + DISPLAY_EST_MW + USB_EST_MW + NET_EST_MW + STORAGE_EST_MW + AUDIO_EST_MW + BACKGROUND_EST_MW))
    [ "$EST_TOTAL_MW" -le 0 ] && EST_TOTAL_MW=1
fi

CPU_EST_PCT=$((100 * CPU_EST_MW / EST_TOTAL_MW))
DDR_EST_PCT=$((100 * DDR_EST_MW / EST_TOTAL_MW))
DISPLAY_EST_PCT=$((100 * DISPLAY_EST_MW / EST_TOTAL_MW))
USB_EST_PCT=$((100 * USB_EST_MW / EST_TOTAL_MW))
NET_EST_PCT=$((100 * NET_EST_MW / EST_TOTAL_MW))
STORAGE_EST_PCT=$((100 * STORAGE_EST_MW / EST_TOTAL_MW))
AUDIO_EST_PCT=$((100 * AUDIO_EST_MW / EST_TOTAL_MW))
BACKGROUND_EST_PCT=$((100 * BACKGROUND_EST_MW / EST_TOTAL_MW))

compute_confidences

if [ "$JSON_OUTPUT" -eq 1 ]; then
    printf '{\n'
    printf '  "host":"%s",\n' "$(json_escape "$HOSTNAME")"
    printf '  "kernel":"%s",\n' "$(json_escape "$KERNEL")"
    printf '  "arch":"%s",\n' "$(json_escape "$ARCH")"
    printf '  "platform_family":"%s",\n' "$(json_escape "$PLATFORM_FAMILY")"
    printf '  "model":"%s",\n' "$(json_escape "$MODEL")"
    printf '  "soc_id":"%s",\n' "$(json_escape "$SOC_ID")"
    if [ "$PLATFORM_FAMILY" = "Qualcomm QRB2210" ] || [ "$PLATFORM_FAMILY" = "Qualcomm" ]; then
        printf '  "qualcomm":{"devfreq_devices":%d,"remoteproc_devices":%d},\n' \
            "$QCOM_DEVFREQ_COUNT" "$QCOM_REMOTEPROC_COUNT"
    else
        printf '  "qualcomm":null,\n'
    fi
    printf '  "temp_zone_type":"%s",\n' "$(json_escape "$TEMP_TYPE")"
    printf '  "cpu":{"freq_mhz":%d,"governor":"%s","usage_pct":%d},\n' \
        "$FREQ_MHZ" "$(json_escape "${GOV:-unknown}")" "$CPU_USAGE_PCT"

    if [ -n "$REGULATOR_FILE" ]; then
        printf '  "regulator_sample":{"name":"%s","mv":%d,"cpu_like":%d},\n' \
            "$(json_escape "$REGULATOR_NAME")" "$REGULATOR_MV" "$REGULATOR_IS_CPU_LIKE"
    else
        printf '  "regulator_sample":null,\n'
    fi

    if [ "$TEMP_C" -ge 0 ]; then
        printf '  "temp_c":%d,\n' "$TEMP_C"
    else
        printf '  "temp_c":null,\n'
    fi

    printf '  "mem_used_pct":%d,\n' "$mem_used_pct"
    printf '  "usb_interrupts":%d,\n' "$(num_or_zero "$USB_INTERRUPTS")"
    printf '  "display_interrupts":%d,\n' "$(num_or_zero "$DISPLAY_INTERRUPTS")"
    printf '  "runtime_pm":{"total":%d,"active":%d,"suspended":%d,"suspending":%d,"resuming":%d,"unsupported":%d,"unknown":%d},\n' \
        "$RPM_TOTAL" "$RPM_ACTIVE" "$RPM_SUSPENDED" "$RPM_SUSPENDING" "$RPM_RESUMING" "$RPM_UNSUPPORTED" "$RPM_UNKNOWN"
    printf '  "wakeup_devices":{"total":%d,"enabled":%d,"disabled":%d},\n' \
        "$WAKEUP_DEV_TOTAL" "$WAKEUP_DEV_ENABLED" "$WAKEUP_DEV_DISABLED"
    printf '  "wakeup_sources_available":%d,\n' "$WAKEUP_SOURCES_AVAILABLE"
    printf '  "power_estimation_profile":"%s",\n' "$(json_escape "$PROFILE_NAME")"
    printf '  "power_estimation_profile_source":"%s",\n' "$(json_escape "$PROFILE_SOURCE")"
    printf '  "power_estimation_mode":"heuristic",\n'
    printf '  "recommended_profile":"%s",\n' "$(json_escape "$RECOMMENDED_PROFILE")"
    printf '  "power_estimation_total_mw":%d,\n' "$EST_TOTAL_MW"
    printf '  "power_estimation":{\n'
    json_print_estimate_entry "cpu" "$CPU_EST_MW" "$CPU_EST_PCT" "$CPU_CONF" ","
    json_print_estimate_entry "ddr" "$DDR_EST_MW" "$DDR_EST_PCT" "$DDR_CONF" ","
    json_print_estimate_entry "display" "$DISPLAY_EST_MW" "$DISPLAY_EST_PCT" "$DISPLAY_CONF" ","
    json_print_estimate_entry "usb" "$USB_EST_MW" "$USB_EST_PCT" "$USB_CONF" ","
    json_print_estimate_entry "net" "$NET_EST_MW" "$NET_EST_PCT" "$NET_CONF" ","
    json_print_estimate_entry "storage" "$STORAGE_EST_MW" "$STORAGE_EST_PCT" "$STORAGE_CONF" ","
    json_print_estimate_entry "audio" "$AUDIO_EST_MW" "$AUDIO_EST_PCT" "$AUDIO_CONF" ","
    json_print_estimate_entry "background" "$BACKGROUND_EST_MW" "$BACKGROUND_EST_PCT" "$BACKGROUND_CONF" ""
    printf '  },\n'
    printf '  "suggestions":[\n'
    for i in "${!SUGGESTIONS[@]}"; do
        sep=","
        [ "$i" -eq $((${#SUGGESTIONS[@]} - 1)) ] && sep=""
        printf '    "%s"%s\n' "$(json_escape "${SUGGESTIONS[$i]}")" "$sep"
    done
    printf '  ]\n'
    printf '}\n'
else
    if [ "$SUGGEST_ONLY" -ne 1 ]; then
        log "=================================================="
        log " Embedded Linux Power Audit"
        log "=================================================="
        log "[SYSTEM] Host: $HOSTNAME"
        log "[SYSTEM] Kernel: $KERNEL  Arch: $ARCH  Uptime(s): ${UPTIME_STR:-n/d}"
        log "[SYSTEM] Platform: $PLATFORM_FAMILY"
        [ -n "$MODEL" ] && log "[SYSTEM] Model: $MODEL"
        [ -n "$SOC_ID" ] && log "[SYSTEM] SoC ID: $SOC_ID"
        if [ "$PLATFORM_FAMILY" = "Qualcomm QRB2210" ]; then
            log "[SYSTEM] Qualcomm/Arduino Linux target detected (QRB2210 family)"
            log "[QUALCOMM] devfreq devices: $QCOM_DEVFREQ_COUNT  remoteproc devices: $QCOM_REMOTEPROC_COUNT"
            if [ -n "$QCOM_DEVFREQ_SAMPLE" ]; then
                log "[QUALCOMM] devfreq sample: $(echo "$QCOM_DEVFREQ_SAMPLE" | tr '\n' ' ')"
            fi
        elif [ "$PLATFORM_FAMILY" = "Qualcomm" ]; then
            log "[SYSTEM] Generic Qualcomm Linux target detected"
            log "[QUALCOMM] devfreq devices: $QCOM_DEVFREQ_COUNT  remoteproc devices: $QCOM_REMOTEPROC_COUNT"
        fi
        [ -n "$TEMP_TYPE" ] && log "[SYSTEM] Thermal zone type: $TEMP_TYPE"
        log ""
        if [ "$PLATFORM_FAMILY" = "Raspberry Pi" ] && [ "$RPI_VCGENCMD_PRESENT" -eq 1 ]; then
            log "[CPU] Requested freq: ${REQUESTED_FREQ_MHZ} MHz  Actual freq: ${FREQ_MHZ} MHz  Governor: ${GOV:-n/d}  Usage: ${CPU_USAGE_PCT}%"
        else
            log "[CPU] Freq: ${FREQ_MHZ} MHz  Governor: ${GOV:-n/d}  Usage: ${CPU_USAGE_PCT}%"
        fi

        if [ -n "$REGULATOR_FILE" ]; then
            if [ "$REGULATOR_IS_CPU_LIKE" -eq 1 ]; then
                log "[REGULATOR SAMPLE] ${REGULATOR_MV} mV  ($REGULATOR_NAME, CPU-like rail)"
            else
                log "[REGULATOR SAMPLE] ${REGULATOR_MV} mV  ($REGULATOR_NAME)"
            fi
        else
            log "[REGULATOR SAMPLE] non disponibile"
        fi

        if [ "$TEMP_C" -ge 0 ]; then
            log "[TEMP] ${TEMP_C} °C"
        else
            log "[TEMP] temperatura non disponibile"
        fi

        if [ "$PLATFORM_FAMILY" = "Raspberry Pi" ] && [ "$RPI_VCGENCMD_PRESENT" -eq 1 ]; then
            log "[RPI THROTTLING] undervolt_now=$RPI_UNDERVOLT_NOW freq_capped_now=$RPI_FREQ_CAPPED_NOW throttled_now=$RPI_THROTTLED_NOW soft_temp_now=$RPI_SOFT_TEMP_NOW undervolt_occurred=$RPI_UNDERVOLT_OCCURRED freq_capped_occurred=$RPI_FREQ_CAPPED_OCCURRED throttled_occurred=$RPI_THROTTLED_OCCURRED soft_temp_occurred=$RPI_SOFT_TEMP_OCCURRED"
        fi
        
        log "[MEM] Used: ${mem_used_pct}%"

        log "[POWER ESTIMATE] Profile: $PROFILE_NAME  Total(est): ${EST_TOTAL_MW} mW"

        if [ "$GENERIC_FALLBACK" -eq 1 ]; then
            log "[POWER ESTIMATE] Generic fallback profile in use: estimates are coarse and comparative-only."
            [ -n "$RECOMMENDED_PROFILE" ] && \
                log "[POWER ESTIMATE] Recommended profile available: $RECOMMENDED_PROFILE"
        fi

        log "  cpu=${CPU_EST_PCT}% (${CPU_EST_MW} mW, conf=$CPU_CONF)"
        log "  ddr=${DDR_EST_PCT}% (${DDR_EST_MW} mW, conf=$DDR_CONF)"
        log "  display=${DISPLAY_EST_PCT}% (${DISPLAY_EST_MW} mW, conf=$DISPLAY_CONF)"
        log "  usb=${USB_EST_PCT}% (${USB_EST_MW} mW, conf=$USB_CONF)"
        log "  net=${NET_EST_PCT}% (${NET_EST_MW} mW, conf=$NET_CONF)"
        log "  storage=${STORAGE_EST_PCT}% (${STORAGE_EST_MW} mW, conf=$STORAGE_CONF)"
        log "  audio=${AUDIO_EST_PCT}% (${AUDIO_EST_MW} mW, conf=$AUDIO_CONF)"
        log "  background=${BACKGROUND_EST_PCT}% (${BACKGROUND_EST_MW} mW, conf=$BACKGROUND_CONF)"
        log ""
        log "[IDLE STATES]"
        if [ -n "$IDLE_INFO" ]; then
            while IFS= read -r line; do
                [ -n "$line" ] || continue
                log "Stato: $line"
            done <<< "$IDLE_INFO"
        else
            log "Stati idle non disponibili."
        fi

        log ""
        log "[TOP INTERRUPTS]"
        if [ -n "$TOP_INTERRUPTS" ]; then
            while IFS=$'\t' read -r cnt desc; do
                [ -n "$cnt" ] || continue
                log "$cnt $desc"
            done <<< "$TOP_INTERRUPTS"
        else
            log "Nessun dato disponibile."
        fi

        log ""
        log "[USB AUTOSUSPEND SAMPLE]"
        if [ -n "$USB_AUTOSUSPEND_STATUS" ]; then
            echo "$USB_AUTOSUSPEND_STATUS" | head -n 20 | while IFS= read -r l; do
                [ -n "$l" ] || continue
                log "$l"
            done
        else
            log "Nessun path autosuspend leggibile."
        fi

        log ""
        log "[RUNTIME PM]"
        log "Totale: $RPM_TOTAL  Active: $RPM_ACTIVE  Suspended: $RPM_SUSPENDED  Suspending: $RPM_SUSPENDING  Resuming: $RPM_RESUMING  Unsupported: $RPM_UNSUPPORTED  Unknown: $RPM_UNKNOWN"
        if [ -n "$RPM_ACTIVE_SAMPLE" ]; then
            log "Device attivi (sample):"
            echo "$RPM_ACTIVE_SAMPLE" | head -n 15 | while IFS= read -r l; do
                [ -n "$l" ] || continue
                log "  $l"
            done
        else
            log "Nessun sample disponibile."
        fi

        log ""
        log "[WAKEUP DEVICES]"
        log "Totale: $WAKEUP_DEV_TOTAL  Enabled: $WAKEUP_DEV_ENABLED  Disabled: $WAKEUP_DEV_DISABLED"
        if [ -n "$WAKEUP_DEV_SAMPLE" ]; then
            log "Wakeup enabled (sample):"
            echo "$WAKEUP_DEV_SAMPLE" | head -n 15 | while IFS= read -r l; do
                [ -n "$l" ] || continue
                log "  $l"
            done
        else
            log "Nessun device con wakeup enabled trovato o supporto non esposto."
        fi

        log ""
        log "[WAKEUP SOURCES]"
        if [ "$WAKEUP_SOURCES_AVAILABLE" -eq 1 ]; then
            if [ -n "$WAKEUP_TOP" ]; then
                log "Top wakeup source (event_count active_count name):"
                echo "$WAKEUP_TOP" | while IFS= read -r l; do
                    [ -n "$l" ] || continue
                    log "  $l"
                done
            else
                log "wakeup_sources presente ma non parsabile o vuoto."
            fi
        else
            log "wakeup_sources non disponibile."
            log "Suggerimento: mount -t debugfs none /sys/kernel/debug"
        fi

        log ""
        log "[POWER SUPPLY]"
        if [ -n "$PS_POWER" ]; then
            while IFS= read -r l; do
                [ -n "$l" ] || continue
                log "$l"
            done <<< "$PS_POWER"
        else
            log "Nessuna telemetria power_supply disponibile."
        fi

        log ""
        log "[SYSTEMD SUSPEND]"
        if [ "$SYSTEMD_PRESENT" -eq 1 ]; then
            log "systemd rilevato."
            if [ "$SYSTEMD_SUSPEND_AVAILABLE" -eq 1 ]; then
                log "Target sleep/suspend disponibili."
            else
                log "Target sleep/suspend non rilevati."
            fi
            if [ -n "$SYSTEMD_INHIBITORS" ]; then
                log "Inhibitors (prime righe):"
                echo "$SYSTEMD_INHIBITORS" | sed -n '1,10p' | while IFS= read -r l; do
                    [ -n "$l" ] || continue
                    log "  $l"
                done
            fi
        else
            log "systemd non rilevato."
        fi

        log ""
        log "--------------------------------------------------"
        log ">>>> SUGGERIMENTI PER L'OTTIMIZZAZIONE <<<<"
        log "--------------------------------------------------"

        if [ ${#SUGGESTIONS[@]} -eq 0 ]; then
            log "Nessun suggerimento immediato."
        else
            for s in "${SUGGESTIONS[@]}"; do
                log "[!] $s"
            done
        fi

        log "=================================================="
    else
        if [ ${#SUGGESTIONS[@]} -eq 0 ]; then
            echo "Nessun suggerimento immediato."
        else
            for s in "${SUGGESTIONS[@]}"; do
                echo "$s"
            done
        fi
    fi
fi

exit 0