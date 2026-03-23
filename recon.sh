#!/usr/bin/env bash
# =================================================================
#  BugBounty Auto-Recon v3.4
#
#  FIX v3.4:
#   - attack_urls: правильная схема (http:80, https:443, оба для остальных)
#   - JS: katana ограничен 10 хостами, 50 файлами, timeout 60s
#   - Отчёт: JS раздел показывает только НАЙДЕННЫЕ секреты
#   - Отчёт: убран бесполезный список js_files.txt
# =================================================================

set -uo pipefail

R='\033[0;31m' G='\033[0;32m' Y='\033[1;33m'
B='\033[0;34m' C='\033[0;36m' W='\033[1m' N='\033[0m'
log()  { echo -e "${C}[*]${N} $*"; }
ok()   { echo -e "${G}[+]${N} $*"; }
warn() { echo -e "${Y}[!]${N} $*"; }
err()  { echo -e "${R}[x]${N} $*"; }
sec()  { echo -e "\n${W}${B}=== $* ===${N}\n"; }

# ── TELEGRAM ──────────────────────────────────────────────────
TG_BOT_TOKEN=""   # <- токен от @BotFather
TG_CHAT_ID=""     # <- ID чата/группы/канала
# ──────────────────────────────────────────────────────────────

TARGET=""
OUTDIR="$HOME/recon-results"
THREADS=30
DEEP=false
ONLY_PASSIVE=false
SKIP_ACTIVE=false
SKIP_SURFACE=false
HEADERS_FILE=""
declare -a EXTRA_HEADERS

CFG="$HOME/.config/recon"
WORDLIST_DNS="$CFG/wordlists/best-dns-wordlist.txt"
WORDLIST_DIR="$CFG/wordlists/raft-medium-words.txt"
RESOLVER_FILE="$CFG/resolvers.txt"

export PATH="$HOME/go/bin:/usr/local/go/bin:$PATH"
GOBIN="$HOME/go/bin"
has_go() { [[ -x "$GOBIN/$1" ]]; }

tg_send() {
    [[ -z "$TG_BOT_TOKEN" || -z "$TG_CHAT_ID" ]] && return 0
    local raw="$1" msg json
    printf -v msg '%b' "$raw"
    json=$(python3 -c "import json,sys;print(json.dumps(sys.stdin.read()))" <<< "$msg")
    curl -s -X POST "https://api.telegram.org/bot${TG_BOT_TOKEN}/sendMessage" \
         -H "Content-Type: application/json" --max-time 10 \
         -d "{\"chat_id\":\"${TG_CHAT_ID}\",\"text\":${json},\
\"parse_mode\":\"HTML\",\"disable_web_page_preview\":true}" \
         -o /dev/null 2>/dev/null || true
}

tg_file() {
    [[ -z "$TG_BOT_TOKEN" || -z "$TG_CHAT_ID" || ! -s "${1:-}" ]] && return 0
    curl -s -X POST "https://api.telegram.org/bot${TG_BOT_TOKEN}/sendDocument" \
         -F "chat_id=${TG_CHAT_ID}" -F "document=@${1}" -F "caption=${2:-}" \
         --max-time 30 -o /dev/null 2>/dev/null || true
}

load_headers() {
    EXTRA_HEADERS=()
    [[ -z "$HEADERS_FILE" || ! -f "$HEADERS_FILE" ]] && return
    while IFS= read -r line; do
        [[ -z "$line" || "$line" == \#* ]] && continue
        EXTRA_HEADERS+=("-H" "$line")
    done < "$HEADERS_FILE"
    [[ ${#EXTRA_HEADERS[@]} -gt 0 ]] && ok "Заголовков: $((${#EXTRA_HEADERS[@]}/2))"
}

usage() {
    cat << EOF
Использование: $0 -d TARGET [опции]
  -d, --domain DOMAIN      Целевой домен
  -o, --output DIR         Результаты (default: ~/recon-results)
  -t, --threads N          Потоки (default: 30)
  --headers-file FILE      HTTP заголовки (один на строку)
  --deep                   Глубокий режим
  --only-passive           Только Phase 1
  --skip-active            Пропустить Phase 2
  --skip-surface           Пропустить Phase 3
  --install                Установить зависимости
  --test-tg                Тест Telegram
  -h, --help               Помощь
EOF
    exit 0
}

test_tg() {
    [[ -z "$TG_BOT_TOKEN" ]] && { err "TG_BOT_TOKEN пуст (~строка 52)"; exit 1; }
    [[ -z "$TG_CHAT_ID"   ]] && { err "TG_CHAT_ID пуст (~строка 53)"; exit 1; }
    tg_send "✅ <b>Recon Bot v3.4 активен!</b>\nTelegram настроен корректно"
    ok "Проверь Telegram — сообщение должно было прийти!"; exit 0
}

# =================================================================
# INSTALL
# =================================================================
install_tools() {
    sec "Установка зависимостей v3.4"
    if ! command -v go &>/dev/null; then
        local ARCH; ARCH=$(uname -m)
        [[ "$ARCH" == aarch64 ]] && ARCH=arm64 || ARCH=amd64
        curl -sL "https://go.dev/dl/go1.22.0.linux-${ARCH}.tar.gz" -o /tmp/go.tar.gz
        sudo rm -rf /usr/local/go && sudo tar -C /usr/local -xzf /tmp/go.tar.gz
        export PATH="$HOME/go/bin:/usr/local/go/bin:$PATH"
        echo 'export PATH="$HOME/go/bin:/usr/local/go/bin:$PATH"' >> ~/.bashrc
    fi
    ok "Go: $(go version 2>/dev/null)"
    mkdir -p "$GOBIN"; export PATH="$GOBIN:/usr/local/go/bin:$PATH"

    command -v apt-get &>/dev/null && {
        sudo apt-get update -qq 2>/dev/null
        sudo apt-get install -y -qq git curl wget python3 python3-pip \
            dnsutils nmap jq make gcc 2>/dev/null || true
    }

    if ! command -v massdns &>/dev/null; then
        sudo apt-get install -y -qq massdns 2>/dev/null && ok "massdns" || {
            git clone --depth=1 https://github.com/blechschmidt/massdns.git /tmp/massdns 2>/dev/null
            make -C /tmp/massdns 2>/dev/null && sudo cp /tmp/massdns/bin/massdns /usr/local/bin/
            command -v massdns &>/dev/null && ok "massdns" || warn "massdns — dnsx fallback"
        }
    else ok "massdns"; fi

    if ! command -v amass &>/dev/null && ! has_go amass; then
        sudo apt-get install -y -qq amass 2>/dev/null && ok "amass" || \
        sudo snap install amass 2>/dev/null && ok "amass" || warn "amass пропущен"
    else ok "amass"; fi

    _go() {
        has_go "$1" && { ok "$1"; return; }
        log "-> $1"; go install "$2" 2>/dev/null && ok "$1" || warn "$1 — ошибка"
    }
    _go subfinder   "github.com/projectdiscovery/subfinder/v2/cmd/subfinder@latest"
    _go httpx       "github.com/projectdiscovery/httpx/cmd/httpx@latest"
    _go naabu       "github.com/projectdiscovery/naabu/v2/cmd/naabu@latest"
    _go nuclei      "github.com/projectdiscovery/nuclei/v3/cmd/nuclei@latest"
    _go dnsx        "github.com/projectdiscovery/dnsx/cmd/dnsx@latest"
    _go alterx      "github.com/projectdiscovery/alterx/cmd/alterx@latest"
    _go katana      "github.com/projectdiscovery/katana/cmd/katana@latest"
    _go puredns     "github.com/d3mondev/puredns/v2@latest"
    _go waybackurls "github.com/tomnomnom/waybackurls@latest"
    _go gau         "github.com/lc/gau/v2/cmd/gau@latest"
    _go ffuf        "github.com/ffuf/ffuf/v2@latest"

    _pip() {
        command -v "$1" &>/dev/null && { ok "$1"; return; }
        pip3 install "$1" --break-system-packages -q 2>/dev/null && ok "$1" && return
        pip3 install "$1" --user -q 2>/dev/null && ok "$1" && return
        warn "$1 — не установлен"
    }
    _pip arjun

    mkdir -p "$CFG/wordlists"
    local WLB="https://raw.githubusercontent.com/danielmiessler/SecLists/master"
    [[ ! -f "$WORDLIST_DNS" ]] && curl -sL "$WLB/Discovery/DNS/best-dns-wordlist.txt" -o "$WORDLIST_DNS" && ok "DNS wordlist"
    [[ ! -f "$WORDLIST_DIR" ]] && curl -sL "$WLB/Discovery/Web-Content/raft-medium-words.txt" -o "$WORDLIST_DIR" && ok "Dir wordlist"
    [[ ! -f "$RESOLVER_FILE" ]] && {
        mkdir -p "$(dirname "$RESOLVER_FILE")"
        curl -sL "https://raw.githubusercontent.com/trickest/resolvers/main/resolvers.txt" -o "$RESOLVER_FILE" && ok "DNS resolvers"
    }
    has_go nuclei && "$GOBIN/nuclei" -update-templates -silent 2>/dev/null && ok "nuclei templates" || true

    sec "Статус инструментов"
    for t in subfinder httpx naabu nuclei dnsx puredns massdns waybackurls gau katana ffuf nmap curl python3 arjun amass; do
        has_go "$t" || command -v "$t" &>/dev/null && ok "$t" || warn "$t — НЕТ"
    done
    echo; ok "Готово! ./recon.sh -d target.com"; exit 0
}

# ── Аргументы
while [[ $# -gt 0 ]]; do
    case $1 in
        -d|--domain)     TARGET="$2";       shift 2 ;;
        -o|--output)     OUTDIR="$2";       shift 2 ;;
        -t|--threads)    THREADS="$2";      shift 2 ;;
        --headers-file)  HEADERS_FILE="$2"; shift 2 ;;
        --deep)          DEEP=true;          shift ;;
        --only-passive)  ONLY_PASSIVE=true;  shift ;;
        --skip-active)   SKIP_ACTIVE=true;   shift ;;
        --skip-surface)  SKIP_SURFACE=true;  shift ;;
        --install)       install_tools ;;
        --test-tg)       test_tg ;;
        -h|--help)       usage ;;
        *) err "Неизвестно: $1"; usage ;;
    esac
done
[[ -z "$TARGET" ]] && { err "Укажи домен: -d target.com"; usage; }

load_headers

TS=$(date +%Y%m%d_%H%M%S)
WD="$OUTDIR/$TARGET/$TS"
mkdir -p "$WD"/{passive,active,surface,js,vulns,reports}

# pre-touch все файлы
touch \
    "$WD/passive/crt_subs.txt"        "$WD/passive/subfinder_subs.txt" \
    "$WD/passive/amass_subs.txt"      "$WD/passive/wayback_urls.txt" \
    "$WD/passive/wayback_subs.txt"    "$WD/passive/gau_urls.txt" \
    "$WD/passive/gau_subs.txt"        "$WD/passive/all_subs_raw.txt" \
    "$WD/active/resolved_subs.txt"    "$WD/active/brute_subs.txt" \
    "$WD/active/permutation_subs.txt" "$WD/active/all_subs.txt" \
    "$WD/active/live_hosts.txt"       "$WD/active/live_hosts.json" \
    "$WD/active/live_urls.txt"        "$WD/active/interesting_hosts.txt" \
    "$WD/active/open_ports.txt"       "$WD/active/interesting_ports.txt" \
    "$WD/active/nmap_targets.txt"     "$WD/active/nmap_services.xml" \
    "$WD/active/nmap_services.txt"    "$WD/active/attack_urls.txt" \
    "$WD/active/takeovers.txt" \
    "$WD/surface/interesting_urls.txt" "$WD/surface/legacy_endpoints.txt" \
    "$WD/surface/all_historical_urls.txt" "$WD/surface/cors_issues.txt" \
    "$WD/js/js_files.txt" "$WD/js/js_secrets.txt" \
    "$WD/vulns/nuclei_findings.txt"

LOG="$WD/recon.log"
exec > >(tee -a "$LOG") 2>&1

echo -e "${W}${B}"
echo "  +============================================+"
echo "  |  BugBounty Auto-Recon v3.4               |"
echo "  +============================================+"
echo -e "${N}"
printf "${W}%-16s${N}%s\n" "Target:"   "$TARGET"
printf "${W}%-16s${N}%s\n" "Output:"   "$WD"
printf "${W}%-16s${N}%s\n" "Threads:"  "$THREADS"
printf "${W}%-16s${N}%s\n" "Headers:"  "${HEADERS_FILE:-нет}"
printf "${W}%-16s${N}%s\n" "Started:"  "$(date)"
printf "${W}%-16s${N}%s\n" "Telegram:" "$([[ -n "$TG_BOT_TOKEN" ]] && echo 'OK' || echo 'нет (строки 52-53)')"
echo

tg_send "<b>Recon запущен</b>\n🎯 <code>${TARGET}</code>\n🕐 $(date '+%d.%m.%Y %H:%M')"

# =================================================================
# PHASE 1
# =================================================================
phase1() {
    sec "PHASE 1 — ПАССИВНАЯ РАЗВЕДКА"
    local P="$WD/passive"

    log "[1.1] crt.sh..."
    curl -s --max-time 30 "https://crt.sh/?q=%.${TARGET}&output=json" 2>/dev/null \
    | python3 -c "
import sys,json
try:
    d=json.load(sys.stdin); s=set()
    for i in d:
        for n in i.get('name_value','').split('\n'):
            n=n.strip().lstrip('*.').lower()
            if n.endswith('${TARGET}') and ' ' not in n and n: s.add(n)
    print('\n'.join(sorted(s)))
except: pass" > "$P/crt_subs.txt" 2>/dev/null || true
    ok "crt.sh: $(wc -l < "$P/crt_subs.txt") субдоменов"

    log "[1.2] subfinder..."
    if has_go subfinder; then
        local sf=("-d" "$TARGET" "--all" "-silent")
        [[ "$DEEP" == true ]] && sf+=("-recursive")
        "$GOBIN/subfinder" "${sf[@]}" -o "$P/subfinder_subs.txt" 2>/dev/null || true
        ok "subfinder: $(wc -l < "$P/subfinder_subs.txt") субдоменов"
    else warn "subfinder нет"; fi

    log "[1.3] amass..."
    if command -v amass &>/dev/null || has_go amass; then
        local am; has_go amass && am="$GOBIN/amass" || am="amass"
        timeout 180 "$am" enum -passive -d "$TARGET" -silent \
            -o "$P/amass_subs.txt" 2>/dev/null || true
        ok "amass: $(wc -l < "$P/amass_subs.txt") субдоменов"
    else warn "amass нет"; fi

    log "[1.4] waybackurls..."
    if has_go waybackurls; then
        echo "$TARGET" | "$GOBIN/waybackurls" 2>/dev/null \
            | tee "$P/wayback_urls.txt" \
            | grep -oP "[a-zA-Z0-9._-]+\.${TARGET}" 2>/dev/null \
            | sort -u > "$P/wayback_subs.txt" || true
        ok "Wayback: $(wc -l < "$P/wayback_urls.txt") URL"
    else
        curl -s --max-time 30 \
            "http://web.archive.org/cdx/search/cdx?url=*.${TARGET}/*&output=text&fl=original&collapse=urlkey" \
            2>/dev/null | sort -u > "$P/wayback_urls.txt" || true
        ok "CDX: $(wc -l < "$P/wayback_urls.txt") URL"
    fi

    log "[1.5] gau..."
    if has_go gau; then
        "$GOBIN/gau" "$TARGET" --threads "$THREADS" \
            --blacklist "png,jpg,gif,css,ttf,woff,svg,ico,woff2,eot" \
            --o "$P/gau_urls.txt" 2>/dev/null || true
        grep -oP "[a-zA-Z0-9._-]+\.${TARGET}" "$P/gau_urls.txt" 2>/dev/null \
            | sort -u > "$P/gau_subs.txt" || true
        ok "gau: $(wc -l < "$P/gau_urls.txt") URL"
    else warn "gau нет"; fi

    command -v dig &>/dev/null && {
        { echo "### MX";  dig MX  "$TARGET" +short 2>/dev/null
          echo "### TXT"; dig TXT "$TARGET" +short 2>/dev/null
          echo "### NS";  dig NS  "$TARGET" +short 2>/dev/null
        } > "$P/dns_records.txt"
        ok "DNS records"
    }

    cat "$P"/*_subs.txt 2>/dev/null \
        | tr '[:upper:]' '[:lower:]' \
        | grep -v "^\*.\|^#\|^$" \
        | grep -E "(\.${TARGET}$|^${TARGET}$)" \
        | sort -u > "$P/all_subs_raw.txt" || true

    local cnt; cnt=$(wc -l < "$P/all_subs_raw.txt")
    ok "ИТОГО: ${cnt} субдоменов"
    tg_send "<b>Phase 1</b> — ${TARGET}\nСубдоменов: <b>${cnt}</b> | wayback: $(wc -l < "$P/wayback_urls.txt") URL\n⏳ Phase 2..."
}

# =================================================================
# PHASE 2
# =================================================================
phase2() {
    sec "PHASE 2 — АКТИВНАЯ РАЗВЕДКА"
    local P="$WD/active" PASS="$WD/passive"

    # DNS Resolution
    log "[2.1] DNS резолвинг..."
    if has_go puredns && command -v massdns &>/dev/null && [[ -f "$RESOLVER_FILE" ]]; then
        "$GOBIN/puredns" resolve "$PASS/all_subs_raw.txt" \
            -r "$RESOLVER_FILE" -w "$P/resolved_subs.txt" --quiet 2>/dev/null \
            || cp "$PASS/all_subs_raw.txt" "$P/resolved_subs.txt"
        ok "puredns: $(wc -l < "$P/resolved_subs.txt") резолвятся"
    elif has_go dnsx; then
        "$GOBIN/dnsx" -l "$PASS/all_subs_raw.txt" -silent \
            -o "$P/resolved_subs.txt" 2>/dev/null \
            || cp "$PASS/all_subs_raw.txt" "$P/resolved_subs.txt"
        ok "dnsx: $(wc -l < "$P/resolved_subs.txt") резолвятся"
    else
        cp "$PASS/all_subs_raw.txt" "$P/resolved_subs.txt"
        warn "puredns/dnsx нет"
    fi

    # Brute-force
    log "[2.2] DNS brute-force..."
    if has_go puredns && command -v massdns &>/dev/null && [[ -f "$WORDLIST_DNS" ]]; then
        "$GOBIN/puredns" bruteforce "$WORDLIST_DNS" "$TARGET" \
            -r "$RESOLVER_FILE" -w "$P/brute_subs.txt" --quiet 2>/dev/null || true
        ok "brute: $(wc -l < "$P/brute_subs.txt")"
    elif has_go dnsx && [[ -f "$WORDLIST_DNS" ]]; then
        while IFS= read -r w; do echo "${w}.${TARGET}"; done \
            < <(head -10000 "$WORDLIST_DNS") \
            | "$GOBIN/dnsx" -silent -o "$P/brute_subs.txt" 2>/dev/null || true
        ok "dnsx brute: $(wc -l < "$P/brute_subs.txt")"
    else warn "brute пропущен"; fi

    has_go alterx && {
        cat "$P/resolved_subs.txt" "$P/brute_subs.txt" 2>/dev/null \
            | "$GOBIN/alterx" -enrich 2>/dev/null | head -50000 \
            | (has_go dnsx && "$GOBIN/dnsx" -silent -o "$P/permutation_subs.txt" \
               || tee "$P/permutation_subs.txt") > /dev/null 2>/dev/null || true
        ok "permutations: $(wc -l < "$P/permutation_subs.txt")"
    }

    cat "$P/resolved_subs.txt" "$P/brute_subs.txt" \
        "$P/permutation_subs.txt" 2>/dev/null | sort -u > "$P/all_subs.txt" || true
    ok "Всего субдоменов: $(wc -l < "$P/all_subs.txt")"

    # Port scanning
    log "[2.3] Port scanning (naabu top-1000)..."
    if has_go naabu; then
        "$GOBIN/naabu" -l "$P/all_subs.txt" -top-ports 1000 -c 25 -silent \
            -o "$P/open_ports.txt" 2>/dev/null || true
        ok "Открытых портов: $(wc -l < "$P/open_ports.txt")"
        grep -vE ":80$|:443$" "$P/open_ports.txt" 2>/dev/null \
            | sort -u > "$P/interesting_ports.txt" || true
        ok "Нестандартных портов: $(wc -l < "$P/interesting_ports.txt")"
        cut -d: -f1 "$P/open_ports.txt" | sort -u > "$P/nmap_targets.txt" 2>/dev/null || true
    elif command -v nmap &>/dev/null; then
        warn "naabu нет -> nmap..."
        nmap -p "1-1000" --open -T4 -iL "$P/all_subs.txt" \
            -oG "$P/nmap_open.txt" 2>/dev/null || true
    else warn "naabu/nmap нет — port scan пропущен"; fi

    # nmap service detection — на ВСЕХ хостах с открытыми портами
    if command -v nmap &>/dev/null && [[ -s "$P/nmap_targets.txt" ]]; then
        log "[2.4] nmap service detection..."
        local all_ports
        all_ports=$(cut -d: -f2 "$P/open_ports.txt" 2>/dev/null | sort -un | tr '\n' ',' | sed 's/,$//')
        [[ -z "$all_ports" ]] && all_ports="1-1000"
        nmap -sV -sC -p "${all_ports}" --open -T4 \
            -iL "$P/nmap_targets.txt" \
            -oX "$P/nmap_services.xml" \
            -oN "$P/nmap_services.txt" \
            2>/dev/null || true
        ok "nmap: $P/nmap_services.txt"
    fi

    # HTTP probing — httpx на субдоменах + IP:PORT из naabu
    log "[2.5] HTTP probing..."
    local httpx_input="$P/httpx_input.txt"
    cp "$P/all_subs.txt" "$httpx_input" 2>/dev/null || touch "$httpx_input"

    # FIX v3.4: правильная генерация URL из open_ports
    # - порт 80  → http://host
    # - порт 443 → https://host
    # - остальные → https://host:PORT и http://host:PORT
    while IFS=: read -r host port; do
        case "$port" in
            80)  echo "http://${host}" ;;
            443) echo "https://${host}" ;;
            8443|4443|8843|9443) echo "https://${host}:${port}" ;;
            *)   echo "https://${host}:${port}"
                 echo "http://${host}:${port}" ;;
        esac
    done < "$P/open_ports.txt" >> "$httpx_input"
    sort -u "$httpx_input" -o "$httpx_input"

    if has_go httpx; then
        "$GOBIN/httpx" -l "$httpx_input" \
            -title -tech-detect -status-code \
            -content-length -web-server -ip \
            -threads "$THREADS" -silent \
            "${EXTRA_HEADERS[@]:-}" \
            -o "$P/live_hosts.txt" 2>/dev/null || true

        "$GOBIN/httpx" -l "$httpx_input" \
            -title -tech-detect -status-code -json \
            -threads "$THREADS" -silent \
            "${EXTRA_HEADERS[@]:-}" \
            -o "$P/live_hosts.json" 2>/dev/null || true

        grep -oP "https?://[^\s]+" "$P/live_hosts.txt" 2>/dev/null \
            | sort -u > "$P/live_urls.txt" || true
        grep -v "\[400\]\|\[404\]\|\[406\]\|\[444\]" \
            "$P/live_hosts.txt" > "$P/interesting_hosts.txt" 2>/dev/null || true
        ok "Живых хостов: $(wc -l < "$P/live_hosts.txt")"
        ok "Live URLs: $(wc -l < "$P/live_urls.txt")"
    else
        err "httpx нет. Установи: go install github.com/projectdiscovery/httpx/cmd/httpx@latest"
    fi

    # FIX v3.4: attack_urls — правильные схемы
    log "[2.6] Генерация attack_urls.txt..."
    cp "$P/live_urls.txt" "$P/attack_urls.txt" 2>/dev/null || true
    # Добавляем прямые IP:PORT с правильными схемами
    while IFS=: read -r host port; do
        case "$port" in
            80)  echo "http://${host}" ;;
            443) echo "https://${host}" ;;
            8443|4443|8843|9443) echo "https://${host}:${port}" ;;
            *)   echo "https://${host}:${port}"
                 echo "http://${host}:${port}" ;;
        esac
    done < "$P/open_ports.txt" >> "$P/attack_urls.txt"
    sort -u "$P/attack_urls.txt" -o "$P/attack_urls.txt"
    ok "Attack URLs: $(wc -l < "$P/attack_urls.txt")"

    # Subdomain takeover
    log "[2.7] Takeover check..."
    if has_go nuclei && [[ -s "$P/live_urls.txt" ]]; then
        "$GOBIN/nuclei" -l "$P/live_urls.txt" -t takeovers/ -silent \
            -o "$P/takeovers.txt" 2>/dev/null || true
        local tc; tc=$(wc -l < "$P/takeovers.txt")
        [[ "$tc" -gt 0 ]] && warn "TAKEOVERS: $tc!" || ok "Takeover: нет"
    fi

    tg_send "<b>Phase 2</b> — ${TARGET}\n🌐 Живых: <b>$(wc -l < "$P/live_hosts.txt")</b>\n🔌 Нестанд. портов: <b>$(wc -l < "$P/interesting_ports.txt")</b>\n⚡ Attack URLs: <b>$(wc -l < "$P/attack_urls.txt")</b>\nTakeovers: $(wc -l < "$P/takeovers.txt")\n$([ "$(wc -l < "$P/interesting_ports.txt")" -gt 0 ] && echo "\n<code>$(head -5 "$P/interesting_ports.txt")</code>" || true)\n⏳ Phase 3..."
}

# =================================================================
# PHASE 3
# =================================================================
phase3() {
    sec "PHASE 3 — МАППИНГ ПОВЕРХНОСТИ"
    local P="$WD/surface" ACT="$WD/active" JSP="$WD/js"

    # Content discovery — тихий режим
    log "[3.1] ffuf..."
    if has_go ffuf && [[ -f "$WORDLIST_DIR" ]] && [[ -s "$ACT/interesting_hosts.txt" ]]; then
        head -10 "$ACT/interesting_hosts.txt" \
            | grep -oP "https?://[^\s]+" \
            | while read -r url; do
                local safe; safe=$(echo "$url" | sed 's|[/:.]|_|g')
                timeout 180 "$GOBIN/ffuf" \
                    -w "${WORDLIST_DIR}:FUZZ" -u "${url}/FUZZ" \
                    -mc "200,201,204,301,302,307,401,403" \
                    -t "$THREADS" -rate 30 -s \
                    "${EXTRA_HEADERS[@]:-}" \
                    -o "$P/ffuf_${safe}.json" -of json \
                    >/dev/null 2>/dev/null || true
              done
        ok "ffuf завершён"
    else warn "ffuf/wordlist нет"; fi

    # Исторические URL
    log "[3.2] Исторические URL..."
    cat "$WD/passive/wayback_urls.txt" "$WD/passive/gau_urls.txt" \
        2>/dev/null | sort -u > "$P/all_historical_urls.txt" || true
    grep -iE "\.(php|asp|aspx|jsp|action|do|cfm|cgi)(\?|$)" \
        "$P/all_historical_urls.txt" 2>/dev/null | sort -u > "$P/legacy_endpoints.txt" || true
    grep -iE "(admin|panel|dashboard|api/v[0-9]|internal|debug|test|staging|backup|config|setup)" \
        "$P/all_historical_urls.txt" 2>/dev/null | sort -u > "$P/interesting_urls.txt" || true
    ok "Legacy: $(wc -l < "$P/legacy_endpoints.txt")  Interesting: $(wc -l < "$P/interesting_urls.txt")"

    # FIX v3.4: JS анализ — ТОЛЬКО секреты, никакого шума
    log "[3.3] JS анализ (только секреты)..."
    local crawl_input="$ACT/attack_urls.txt"
    [[ ! -s "$crawl_input" ]] && crawl_input="$ACT/live_urls.txt"

    if has_go katana && [[ -s "$crawl_input" ]]; then
        # Ограничение: только первые 10 хостов, depth=1, timeout=60s на хост
        head -10 "$crawl_input" | while read -r url; do
            timeout 60 "$GOBIN/katana" \
                -u "$url" \
                -d 1 \
                -silent \
                -jc \
                2>/dev/null \
                | grep -iE "\.js(\?|$)" \
                | head -20 \
                >> "$JSP/js_files.txt" || true
        done
        sort -u "$JSP/js_files.txt" -o "$JSP/js_files.txt" 2>/dev/null || true
        # Ограничение: только первые 50 JS файлов
        local js_count; js_count=$(wc -l < "$JSP/js_files.txt")
        ok "JS файлов: ${js_count} (анализируем первые 50)"
    fi

    # Поиск секретов — только в первых 50 файлах
    local sc=0
    while read -r jsurl; do
        local found
        found=$(curl -sk --max-time 8 "$jsurl" 2>/dev/null \
            | grep -iP "(api[_\-]?key\s*[:=]|apikey\s*[:=]|secret[_\-]?key\s*[:=]|access[_\-]?token\s*[:=]|private[_\-]?key\s*[:=]|password\s*=|aws[_\-]?access_key|client[_\-]?secret\s*[:=]|bearer\s+[a-zA-Z0-9]{20})" \
            2>/dev/null \
            | grep -v "^\s*//\|^\s*\*\|placeholder\|example\|your[_\-]\|xxxx\|XXXX" \
            | head -3 || true)
        if [[ -n "$found" ]]; then
            echo "=== $jsurl ===" >> "$JSP/js_secrets.txt"
            echo "$found" >> "$JSP/js_secrets.txt"
            ((sc++)) || true
        fi
    done < <(head -50 "$JSP/js_files.txt" 2>/dev/null || true)

    [[ "$sc" -gt 0 ]] && warn "⚠️ Секретов найдено в $sc JS файлах!" || ok "JS: секретов нет"

    # Nuclei — на attack_urls
    log "[3.4] Nuclei scan..."
    local nuclei_input="$ACT/attack_urls.txt"
    [[ ! -s "$nuclei_input" ]] && nuclei_input="$ACT/live_urls.txt"
    if has_go nuclei && [[ -s "$nuclei_input" ]]; then
        "$GOBIN/nuclei" -l "$nuclei_input" \
            -t "cves/,exposures/,misconfiguration/,default-logins/" \
            -severity "critical,high,medium" \
            "${EXTRA_HEADERS[@]:-}" \
            -threads 25 -silent \
            -o "$WD/vulns/nuclei_findings.txt" 2>/dev/null || true
        local nc; nc=$(wc -l < "$WD/vulns/nuclei_findings.txt")
        [[ "$nc" -gt 0 ]] && warn "⚠️ Nuclei: $nc findings!" || ok "Nuclei: ничего"
    else warn "nuclei нет"; fi

    # CORS check
    log "[3.5] CORS check..."
    head -20 "$ACT/live_urls.txt" 2>/dev/null | while read -r url; do
        local r
        r=$(curl -sk --max-time 8 -H "Origin: https://evil.com" \
            "${EXTRA_HEADERS[@]:-}" -I "$url" 2>/dev/null \
            | grep -i "access-control-allow-origin" || true)
        echo "$r" | grep -qi "evil.com\|null" && \
            echo "CORS: $url -> $r" >> "$P/cors_issues.txt" || true
    done
    ok "CORS: $(wc -l < "$P/cors_issues.txt") проблем"

    tg_send "<b>Phase 3</b> — ${TARGET}\n📝 Interesting URLs: $(wc -l < "$P/interesting_urls.txt")\n🔑 JS secrets: $(grep -c '===' "$JSP/js_secrets.txt" 2>/dev/null)\n🔬 Nuclei: $(wc -l < "$WD/vulns/nuclei_findings.txt")\n🌐 CORS: $(wc -l < "$P/cors_issues.txt")"
}

# =================================================================
# ОТЧЁТ
# =================================================================
make_report() {
    sec "ГЕНЕРАЦИЯ ОТЧЁТА"
    local RPT="$WD/reports/summary.md"

    cat > "$RPT" << MDEOF
# Recon Report: ${TARGET}
**Дата:** $(date)  |  **Директория:** \`${WD}\`

## Статистика
| Метрика | Значение |
|---|---|
| Субдоменов (raw) | $(wc -l < "$WD/passive/all_subs_raw.txt") |
| Живых хостов | $(wc -l < "$WD/active/live_hosts.txt") |
| Открытых портов (naabu) | $(wc -l < "$WD/active/open_ports.txt") |
| Нестандартных портов | $(wc -l < "$WD/active/interesting_ports.txt") |
| Attack URLs | $(wc -l < "$WD/active/attack_urls.txt") |
| Subdomain Takeovers | $(wc -l < "$WD/active/takeovers.txt") |
| Nuclei Findings | $(wc -l < "$WD/vulns/nuclei_findings.txt") |
| Секретов в JS | $(grep -c '===' "$WD/js/js_secrets.txt" 2>/dev/null) |
| CORS проблем | $(wc -l < "$WD/surface/cors_issues.txt") |

## Все открытые порты (naabu)
\`\`\`
$(cat "$WD/active/open_ports.txt" 2>/dev/null || echo нет)
\`\`\`

## Attack URLs (копировать в Burp)
\`\`\`
$(cat "$WD/active/attack_urls.txt" 2>/dev/null || echo нет)
\`\`\`

## Takeovers
\`\`\`
$(cat "$WD/active/takeovers.txt" 2>/dev/null || echo нет)
\`\`\`

## Nuclei Critical/High
\`\`\`
$(grep -iE 'critical|high' "$WD/vulns/nuclei_findings.txt" 2>/dev/null | head -20 || echo нет)
\`\`\`

## JS Секреты (только найденные)
\`\`\`
$(cat "$WD/js/js_secrets.txt" 2>/dev/null || echo нет)
\`\`\`

## CORS Проблемы
\`\`\`
$(cat "$WD/surface/cors_issues.txt" 2>/dev/null || echo нет)
\`\`\`

MDEOF

    # Таблицы сервисов через Python
    python3 << PYEOF >> "$RPT"
import json, sys

json_file = "$WD/active/live_hosts.json"
xml_file  = "$WD/active/nmap_services.xml"

print("\n## Live Hosts & Technologies\n")
print("| URL | Status | Server | Technologies | IP |")
print("|---|---|---|---|---|")
try:
    with open(json_file) as f:
        for line in f:
            try:
                h = json.loads(line.strip())
                if not h: continue
                url  = h.get('url', '')
                code = h.get('status-code', '')
                srv  = h.get('webserver', '') or ''
                tech = ', '.join(h.get('technologies', []))[:80]
                ip   = h.get('host', '')
                print(f"| [{url}]({url}) | {code} | {srv} | {tech} | {ip} |")
            except: pass
except Exception as e:
    print(f"| *(ошибка live_hosts.json: {e})* | | | | |")

print("\n## Open Ports & Service Versions (nmap)\n")
print("| Host | IP | Port | Service | Version |")
print("|---|---|---|---|---|")
try:
    import xml.etree.ElementTree as ET
    tree = ET.parse(xml_file)
    root = tree.getroot()
    for host in root.findall('host'):
        addr_el = host.find('address[@addrtype="ipv4"]')
        ip = addr_el.get('addr','') if addr_el is not None else ''
        hn = next((h.get('name','') for h in host.findall('.//hostname')
                   if h.get('type') in ('PTR','user')), '')
        display = hn or ip
        for port in host.findall('.//port'):
            state_el = port.find('state')
            svc_el   = port.find('service')
            if state_el is not None and state_el.get('state') == 'open':
                pid     = port.get('portid','')
                sname   = svc_el.get('name','')    if svc_el is not None else ''
                product = svc_el.get('product','') if svc_el is not None else ''
                ver     = svc_el.get('version','') if svc_el is not None else ''
                full    = f"{product} {ver}".strip()
                print(f"| {display} | {ip} | **{pid}** | {sname} | {full} |")
except Exception as e:
    print(f"| *(nmap XML: {e})* | | | | |")
PYEOF

    cat >> "$RPT" << MDEOF

## Phase 4 — с чего начать
1. Скопируй **Attack URLs** выше прямо в Burp Suite → ручной анализ
2. **Nuclei findings** → немедленная проверка
3. **nmap версии** → поиск CVE (searchsploit, Exploit-DB)
4. Нестандартные порты: Redis 6379? ES 9200? Jenkins 8080? → часто без auth
5. **JS секреты** → API ключи, токены
6. Historical URLs → XSS/SQLi/SSTI/IDOR
MDEOF

    ok "Отчёт: $RPT"
}

# =================================================================
# MAIN
# =================================================================
START=$(date +%s)
phase1
[[ "$ONLY_PASSIVE" == false && "$SKIP_ACTIVE"  == false ]] && phase2
[[ "$ONLY_PASSIVE" == false && "$SKIP_SURFACE" == false ]] && phase3
make_report

END=$(date +%s); EL=$((END-START))
EL_FMT="$((EL/60))m $((EL%60))s"

sec "ЗАВЕРШЕНО v3.4"
printf "${W}%-14s${N}%s\n" "Domain:"      "$TARGET"
printf "${W}%-14s${N}%s\n" "Runtime:"     "$EL_FMT"
printf "${W}%-14s${N}%s\n" "Results:"     "$WD"
printf "${W}%-14s${N}%s\n" "Attack URLs:" "$(wc -l < "$WD/active/attack_urls.txt")"
echo
for f in "active/attack_urls.txt" "active/open_ports.txt" \
         "active/live_hosts.txt" "surface/interesting_urls.txt" \
         "js/js_secrets.txt" "vulns/nuclei_findings.txt" "reports/summary.md"; do
    echo -e "  ${C}->  ${N}$WD/$f"
done

tg_send "<b>✅ Recon завершён!</b> — ${TARGET}\n⏱ <b>${EL_FMT}</b>\n\nИтоги:\n• Субдоменов: $(wc -l < "$WD/passive/all_subs_raw.txt")\n• Живых хостов: $(wc -l < "$WD/active/live_hosts.txt")\n• Открытых портов: $(wc -l < "$WD/active/open_ports.txt")\n• Attack URLs: $(wc -l < "$WD/active/attack_urls.txt")\n• Nuclei: $(wc -l < "$WD/vulns/nuclei_findings.txt")\n• JS secrets: $(grep -c '===' "$WD/js/js_secrets.txt" 2>/dev/null)\n• CORS: $(wc -l < "$WD/surface/cors_issues.txt")"

tg_file "$WD/reports/summary.md" "Отчёт: ${TARGET}"
[[ -s "$WD/vulns/nuclei_findings.txt" ]] && \
    tg_file "$WD/vulns/nuclei_findings.txt" "Nuclei: ${TARGET}"
[[ -s "$WD/active/attack_urls.txt" ]] && \
    tg_file "$WD/active/attack_urls.txt" "Attack URLs: ${TARGET}"
