#!/usr/bin/env bash
# =================================================================
#  BugBounty Auto-Recon v3.2
#
#  FIX #1: TG \n literal  -> printf '%b' interprets \n as newline
#  FIX #2: grep -c || echo 0  -> double output bug fixed
#  FIX #3: ffuf hang  -> timeout 180 + -rate + >/dev/null
#  FIX #4: massdns missing  -> dnsx fallback
#  FIX #5: getJS  -> replaced with katana (PD)
#  FIX #6: pip PEP668  -> --break-system-packages
#  FIX #7: missing files  -> touch all upfront
#  NEW: --headers-file support (pass to httpx/ffuf/nuclei/curl)
#  NEW: Services & Versions section in report (httpx JSON + nmap XML)
#
#  TELEGRAM:
#    Строка 47:  TG_BOT_TOKEN="..."
#    Строка 48:  TG_CHAT_ID="..."
#
#  Использование:
#    ./recon.sh -d target.com
#    ./recon.sh -d target.com --headers-file /path/headers.txt
#    ./recon.sh --install
#    ./recon.sh --test-tg
# =================================================================

set -uo pipefail

# ── Цвета
R='\033[0;31m' G='\033[0;32m' Y='\033[1;33m'
B='\033[0;34m' C='\033[0;36m' W='\033[1m' N='\033[0m'
log()  { echo -e "${C}[*]${N} $*"; }
ok()   { echo -e "${G}[+]${N} $*"; }
warn() { echo -e "${Y}[!]${N} $*"; }
err()  { echo -e "${R}[x]${N} $*"; }
sec()  { echo -e "\n${W}${B}=== $* ===${N}\n"; }

# ── TELEGRAM — ВСТАВЬ СВОИ ДАННЫЕ ────────────────────────
TG_BOT_TOKEN=""   # <- "1234567890:AAHxxxxxxxxxxxxxxxxxxxxxxxx"
TG_CHAT_ID=""     # <- "123456789"  /  "-1001234567890"  /  "@channel"
# ─────────────────────────────────────────────────────────

# ── Defaults
TARGET=""
OUTDIR="$HOME/recon-results"
THREADS=30
DEEP=false
ONLY_PASSIVE=false
SKIP_ACTIVE=false
SKIP_SURFACE=false
HEADERS_FILE=""           # --headers-file
declare -a EXTRA_HEADERS  # заполняется из файла

CFG="$HOME/.config/recon"
WORDLIST_DNS="$CFG/wordlists/best-dns-wordlist.txt"
WORDLIST_DIR="$CFG/wordlists/raft-medium-words.txt"
RESOLVER_FILE="$CFG/resolvers.txt"

# Go bin – первым в PATH чтобы не конфликтовать с Python httpx
export PATH="$HOME/go/bin:/usr/local/go/bin:$PATH"
GOBIN="$HOME/go/bin"

has_go() { [[ -x "$GOBIN/$1" ]]; }

# ── FIX #1: tg_send — printf '%b' интерпретирует \n как перевод строки
tg_send() {
    [[ -z "$TG_BOT_TOKEN" || -z "$TG_CHAT_ID" ]] && return 0
    local raw="$1"
    local msg
    printf -v msg '%b' "$raw"   # \n -> newline, \t -> tab
    local json
    json=$(python3 -c "import json,sys;print(json.dumps(sys.stdin.read()))" <<< "$msg")
    curl -s -X POST "https://api.telegram.org/bot${TG_BOT_TOKEN}/sendMessage" \
         -H "Content-Type: application/json" --max-time 10 \
         -d "{\"chat_id\":\"${TG_CHAT_ID}\",\"text\":${json},\
\"parse_mode\":\"HTML\",\"disable_web_page_preview\":true}" \
         -o /dev/null 2>/dev/null || true
}

tg_file() {
    [[ -z "$TG_BOT_TOKEN" || -z "$TG_CHAT_ID" ]] && return 0
    [[ ! -s "${1:-}" ]] && return 0
    curl -s -X POST "https://api.telegram.org/bot${TG_BOT_TOKEN}/sendDocument" \
         -F "chat_id=${TG_CHAT_ID}" -F "document=@${1}" -F "caption=${2:-}" \
         --max-time 30 -o /dev/null 2>/dev/null || true
}

# ── Загрузить заголовки из файла
load_headers() {
    EXTRA_HEADERS=()
    [[ -z "$HEADERS_FILE" || ! -f "$HEADERS_FILE" ]] && return
    while IFS= read -r line; do
        [[ -z "$line" || "$line" == \#* ]] && continue
        EXTRA_HEADERS+=("-H" "$line")
    done < "$HEADERS_FILE"
    [[ ${#EXTRA_HEADERS[@]} -gt 0 ]] && ok "Заголовков загружено: $((${#EXTRA_HEADERS[@]}/2))"
}

usage() {
    echo "Использование: $0 -d TARGET [опции]"
    echo "  -d, --domain DOMAIN      Целевой домен"
    echo "  -o, --output DIR         Результаты (default: ~/recon-results)"
    echo "  -t, --threads N          Потоки (default: 30)"
    echo "  --headers-file FILE      Файл с HTTP заголовками (один на строку)"
    echo "  --deep                   Глубокий режим"
    echo "  --only-passive           Только Phase 1"
    echo "  --skip-active            Пропустить Phase 2"
    echo "  --skip-surface           Пропустить Phase 3"
    echo "  --install                Установить зависимости"
    echo "  --test-tg                Тест Telegram"
    echo "  -h, --help               Помощь"
    exit 0
}

test_tg() {
    sec "Тест Telegram"
    [[ -z "$TG_BOT_TOKEN" ]] && { err "TG_BOT_TOKEN не заполнен (строка 47)"; exit 1; }
    [[ -z "$TG_CHAT_ID"   ]] && { err "TG_CHAT_ID не заполнен (строка 48)";   exit 1; }
    tg_send "✅ <b>Recon Bot подключён!</b>\nv3.2 работает корректно"
    ok "Если сообщение пришло — Telegram настроен!"
    exit 0
}

# ── INSTALL
install_tools() {
    sec "Установка зависимостей v3.2"

    # Go
    if ! command -v go &>/dev/null; then
        local ARCH; ARCH=$(uname -m)
        [[ "$ARCH" == aarch64 ]] && ARCH=arm64 || ARCH=amd64
        curl -sL "https://go.dev/dl/go1.22.0.linux-${ARCH}.tar.gz" -o /tmp/go.tar.gz
        sudo rm -rf /usr/local/go && sudo tar -C /usr/local -xzf /tmp/go.tar.gz
        export PATH="$HOME/go/bin:/usr/local/go/bin:$PATH"
        echo 'export PATH="$HOME/go/bin:/usr/local/go/bin:$PATH"' >> ~/.bashrc
    fi
    ok "Go: $(go version 2>/dev/null)"
    mkdir -p "$GOBIN"
    export PATH="$GOBIN:/usr/local/go/bin:$PATH"

    # Системные пакеты
    if command -v apt-get &>/dev/null; then
        sudo apt-get update -qq 2>/dev/null
        sudo apt-get install -y -qq git curl wget python3 python3-pip \
            dnsutils nmap jq make gcc 2>/dev/null || true
    fi

    # massdns (FIX #4)
    if ! command -v massdns &>/dev/null; then
        log "massdns..."
        sudo apt-get install -y -qq massdns 2>/dev/null && ok "massdns (apt)" || {
            git clone --depth=1 https://github.com/blechschmidt/massdns.git /tmp/massdns 2>/dev/null
            make -C /tmp/massdns 2>/dev/null && sudo cp /tmp/massdns/bin/massdns /usr/local/bin/
            command -v massdns &>/dev/null && ok "massdns (built)" || warn "massdns — будет dnsx fallback"
        }
    else ok "massdns"; fi

    # amass (через apt — самый надёжный способ)
    if ! command -v amass &>/dev/null && ! has_go amass; then
        log "amass..."
        sudo apt-get install -y -qq amass 2>/dev/null && ok "amass (apt)" || \
        sudo snap install amass 2>/dev/null && ok "amass (snap)" || \
        warn "amass — пропущен (subfinder покрывает большинство источников)"
    else ok "amass"; fi

    # Go инструменты
    _go() {
        has_go "$1" && { ok "$1"; return; }
        log "-> $1"
        go install "$2" 2>/dev/null && ok "$1" || warn "$1 — ошибка"
    }
    _go subfinder   "github.com/projectdiscovery/subfinder/v2/cmd/subfinder@latest"
    _go httpx       "github.com/projectdiscovery/httpx/cmd/httpx@latest"
    _go naabu       "github.com/projectdiscovery/naabu/v2/cmd/naabu@latest"
    _go nuclei      "github.com/projectdiscovery/nuclei/v3/cmd/nuclei@latest"
    _go dnsx        "github.com/projectdiscovery/dnsx/cmd/dnsx@latest"
    _go alterx      "github.com/projectdiscovery/alterx/cmd/alterx@latest"
    _go katana      "github.com/projectdiscovery/katana/cmd/katana@latest"  # FIX #5: вместо getJS
    _go puredns     "github.com/d3mondev/puredns/v2@latest"
    _go waybackurls "github.com/tomnomnom/waybackurls@latest"
    _go gau         "github.com/lc/gau/v2/cmd/gau@latest"
    _go ffuf        "github.com/ffuf/ffuf/v2@latest"

    # Python (FIX #6: --break-system-packages)
    _pip() {
        command -v "$1" &>/dev/null && { ok "$1"; return; }
        log "-> $1 (pip)"
        pip3 install "$1" --break-system-packages -q 2>/dev/null && ok "$1" && return
        pip3 install "$1" --user -q 2>/dev/null && ok "$1" && return
        command -v pipx &>/dev/null && pipx install "$1" 2>/dev/null && ok "$1" && return
        warn "$1 — не установлен"
    }
    _pip arjun

    # Wordlists
    mkdir -p "$CFG/wordlists"
    local WLB="https://raw.githubusercontent.com/danielmiessler/SecLists/master"
    [[ ! -f "$WORDLIST_DNS" ]] && \
        curl -sL "$WLB/Discovery/DNS/best-dns-wordlist.txt" -o "$WORDLIST_DNS" && ok "DNS wordlist" || ok "DNS wordlist (уже есть)"
    [[ ! -f "$WORDLIST_DIR" ]] && \
        curl -sL "$WLB/Discovery/Web-Content/raft-medium-words.txt" -o "$WORDLIST_DIR" && ok "Dir wordlist" || ok "Dir wordlist (уже есть)"
    [[ ! -f "$RESOLVER_FILE" ]] && {
        mkdir -p "$(dirname "$RESOLVER_FILE")"
        curl -sL "https://raw.githubusercontent.com/trickest/resolvers/main/resolvers.txt" -o "$RESOLVER_FILE" \
            && ok "DNS resolvers" || warn "resolvers — не скачались"
    } || ok "DNS resolvers (уже есть)"

    has_go nuclei && "$GOBIN/nuclei" -update-templates -silent 2>/dev/null && ok "nuclei templates" || true

    sec "Статус"
    for t in subfinder httpx naabu nuclei dnsx puredns massdns waybackurls gau katana ffuf nmap curl python3 arjun amass; do
        if has_go "$t" || command -v "$t" &>/dev/null; then ok "$t"
        else warn "$t — НЕ УСТАНОВЛЕН"; fi
    done
    echo; ok "Готово! Запуск: ./recon.sh -d target.com"
    exit 0
}

# ── Аргументы
while [[ $# -gt 0 ]]; do
    case $1 in
        -d|--domain)       TARGET="$2";       shift 2 ;;
        -o|--output)       OUTDIR="$2";       shift 2 ;;
        -t|--threads)      THREADS="$2";      shift 2 ;;
        --headers-file)    HEADERS_FILE="$2"; shift 2 ;;
        --deep)            DEEP=true;          shift ;;
        --only-passive)    ONLY_PASSIVE=true;  shift ;;
        --skip-active)     SKIP_ACTIVE=true;   shift ;;
        --skip-surface)    SKIP_SURFACE=true;  shift ;;
        --install)         install_tools ;;
        --test-tg)         test_tg ;;
        -h|--help)         usage ;;
        *) err "Неизвестно: $1"; usage ;;
    esac
done
[[ -z "$TARGET" ]] && { err "Укажи домен: -d target.com"; usage; }

load_headers

# ── Workspace
TS=$(date +%Y%m%d_%H%M%S)
WD="$OUTDIR/$TARGET/$TS"
mkdir -p "$WD"/{passive,active,surface,js,vulns,reports}

# FIX #7: pre-touch все файлы
touch \
    "$WD/passive/crt_subs.txt"      "$WD/passive/subfinder_subs.txt" \
    "$WD/passive/amass_subs.txt"    "$WD/passive/wayback_urls.txt" \
    "$WD/passive/wayback_subs.txt"  "$WD/passive/gau_urls.txt" \
    "$WD/passive/gau_subs.txt"      "$WD/passive/all_subs_raw.txt" \
    "$WD/active/resolved_subs.txt"  "$WD/active/brute_subs.txt" \
    "$WD/active/permutation_subs.txt" "$WD/active/all_subs.txt" \
    "$WD/active/live_hosts.txt"     "$WD/active/live_hosts.json" \
    "$WD/active/live_urls.txt"      "$WD/active/interesting_hosts.txt" \
    "$WD/active/open_ports.txt"     "$WD/active/interesting_ports.txt" \
    "$WD/active/nmap_targets.txt"   "$WD/active/nmap_services.xml" \
    "$WD/active/takeovers.txt" \
    "$WD/surface/interesting_urls.txt" "$WD/surface/legacy_endpoints.txt" \
    "$WD/surface/all_historical_urls.txt" "$WD/surface/cors_issues.txt" \
    "$WD/js/js_files.txt"           "$WD/js/js_endpoints.txt" \
    "$WD/js/js_secrets.txt" \
    "$WD/vulns/nuclei_findings.txt"

LOG="$WD/recon.log"
exec > >(tee -a "$LOG") 2>&1

echo -e "${W}${B}"
echo "  +==========================================+"
echo "  |  BugBounty Auto-Recon v3.2  (fixed)     |"
echo "  +==========================================+"
echo -e "${N}"
printf "${W}%-16s${N}%s\n" "Target:"       "$TARGET"
printf "${W}%-16s${N}%s\n" "Output:"       "$WD"
printf "${W}%-16s${N}%s\n" "Threads:"      "$THREADS"
printf "${W}%-16s${N}%s\n" "Headers file:" "${HEADERS_FILE:-не задан}"
printf "${W}%-16s${N}%s\n" "Started:"      "$(date)"
printf "${W}%-16s${N}%s\n" "Telegram:"     "$([[ -n "$TG_BOT_TOKEN" ]] && echo 'OK' || echo 'не настроен (строки 47-48)')"
echo

tg_send "<b>Recon запущен</b>\n🎯 <code>${TARGET}</code>\n🕐 $(date '+%d.%m.%Y %H:%M')"

# =================================================================
# PHASE 1 — ПАССИВНАЯ РАЗВЕДКА
# =================================================================
phase1() {
    sec "PHASE 1 — ПАССИВНАЯ РАЗВЕДКА"
    local P="$WD/passive"

    # 1.1 crt.sh
    log "[1.1] crt.sh Certificate Transparency..."
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

    # 1.2 subfinder — FIX #1: массив, не строка
    log "[1.2] subfinder..."
    if has_go subfinder; then
        local sf=("-d" "$TARGET" "--all" "-silent")
        [[ "$DEEP" == true ]] && sf+=("-recursive")
        "$GOBIN/subfinder" "${sf[@]}" -o "$P/subfinder_subs.txt" 2>/dev/null || true
        ok "subfinder: $(wc -l < "$P/subfinder_subs.txt") субдоменов"
    else warn "subfinder нет"; fi

    # 1.3 amass
    log "[1.3] amass..."
    if command -v amass &>/dev/null || has_go amass; then
        local amass_cmd; has_go amass && amass_cmd="$GOBIN/amass" || amass_cmd="amass"
        timeout 180 "$amass_cmd" enum -passive -d "$TARGET" -silent \
            -o "$P/amass_subs.txt" 2>/dev/null || true
        ok "amass: $(wc -l < "$P/amass_subs.txt") субдоменов"
    else warn "amass нет — пропускаем"; fi

    # 1.4 waybackurls
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
        ok "CDX fallback: $(wc -l < "$P/wayback_urls.txt") URL"
    fi

    # 1.5 gau
    log "[1.5] gau..."
    if has_go gau; then
        "$GOBIN/gau" "$TARGET" --threads "$THREADS" \
            --blacklist "png,jpg,gif,css,ttf,woff,svg,ico,woff2,eot" \
            --o "$P/gau_urls.txt" 2>/dev/null || true
        grep -oP "[a-zA-Z0-9._-]+\.${TARGET}" "$P/gau_urls.txt" 2>/dev/null \
            | sort -u > "$P/gau_subs.txt" || true
        ok "gau: $(wc -l < "$P/gau_urls.txt") URL"
    else warn "gau нет"; fi

    # 1.6 DNS records
    command -v dig &>/dev/null && {
        { echo "### MX";  dig MX  "$TARGET" +short 2>/dev/null
          echo "### TXT"; dig TXT "$TARGET" +short 2>/dev/null
          echo "### NS";  dig NS  "$TARGET" +short 2>/dev/null
        } > "$P/dns_records.txt"
        ok "DNS records"
    }

    # 1.7 Merge
    cat "$P"/*_subs.txt 2>/dev/null \
        | tr '[:upper:]' '[:lower:]' \
        | grep -v "^\*.\|^#\|^$" \
        | grep -E "(\.${TARGET}$|^${TARGET}$)" \
        | sort -u > "$P/all_subs_raw.txt" || true

    local cnt; cnt=$(wc -l < "$P/all_subs_raw.txt")
    ok "ИТОГО: ${cnt} субдоменов"

    tg_send "<b>Phase 1 завершена</b> — ${TARGET}\nСубдоменов: <b>${cnt}</b>\n• crt.sh: $(wc -l < "$P/crt_subs.txt")\n• subfinder: $(wc -l < "$P/subfinder_subs.txt")\n• wayback URLs: $(wc -l < "$P/wayback_urls.txt")\n⏳ Phase 2..."
}

# =================================================================
# PHASE 2 — АКТИВНАЯ РАЗВЕДКА
# =================================================================
phase2() {
    sec "PHASE 2 — АКТИВНАЯ РАЗВЕДКА"
    local P="$WD/active" PASS="$WD/passive"

    # 2.1 DNS Resolution — FIX #4: dnsx если нет massdns
    log "[2.1] DNS резолвинг..."
    if has_go puredns && command -v massdns &>/dev/null && [[ -f "$RESOLVER_FILE" ]]; then
        "$GOBIN/puredns" resolve "$PASS/all_subs_raw.txt" \
            -r "$RESOLVER_FILE" -w "$P/resolved_subs.txt" --quiet 2>/dev/null \
            || cp "$PASS/all_subs_raw.txt" "$P/resolved_subs.txt"
        ok "puredns: $(wc -l < "$P/resolved_subs.txt") резолвятся"
    elif has_go dnsx; then
        log "massdns нет -> dnsx fallback"
        "$GOBIN/dnsx" -l "$PASS/all_subs_raw.txt" -silent \
            -o "$P/resolved_subs.txt" 2>/dev/null \
            || cp "$PASS/all_subs_raw.txt" "$P/resolved_subs.txt"
        ok "dnsx: $(wc -l < "$P/resolved_subs.txt") резолвятся"
    else
        cp "$PASS/all_subs_raw.txt" "$P/resolved_subs.txt"
        warn "puredns/dnsx нет — raw список"
    fi

    # 2.2 Brute-force
    log "[2.2] DNS brute-force..."
    if has_go puredns && command -v massdns &>/dev/null && [[ -f "$WORDLIST_DNS" ]]; then
        "$GOBIN/puredns" bruteforce "$WORDLIST_DNS" "$TARGET" \
            -r "$RESOLVER_FILE" -w "$P/brute_subs.txt" --quiet 2>/dev/null || true
        ok "puredns brute: $(wc -l < "$P/brute_subs.txt")"
    elif has_go dnsx && [[ -f "$WORDLIST_DNS" ]]; then
        log "massdns нет -> dnsx brute (top 10k)..."
        while IFS= read -r w; do echo "${w}.${TARGET}"; done \
            < <(head -10000 "$WORDLIST_DNS") \
            | "$GOBIN/dnsx" -silent -o "$P/brute_subs.txt" 2>/dev/null || true
        ok "dnsx brute: $(wc -l < "$P/brute_subs.txt")"
    else warn "brute-force пропущен"; fi

    # 2.3 Permutations
    if has_go alterx; then
        log "[2.3] Permutations..."
        cat "$P/resolved_subs.txt" "$P/brute_subs.txt" 2>/dev/null \
            | "$GOBIN/alterx" -enrich 2>/dev/null \
            | head -50000 \
            | (has_go dnsx && "$GOBIN/dnsx" -silent -o "$P/permutation_subs.txt" \
               || tee "$P/permutation_subs.txt") > /dev/null 2>/dev/null || true
        ok "permutations: $(wc -l < "$P/permutation_subs.txt")"
    fi

    cat "$P/resolved_subs.txt" "$P/brute_subs.txt" \
        "$P/permutation_subs.txt" 2>/dev/null | sort -u > "$P/all_subs.txt" || true
    ok "Всего: $(wc -l < "$P/all_subs.txt") субдоменов"

    # 2.4 HTTP Probing — FIX #2: явно $GOBIN/httpx
    log "[2.4] HTTP probing..."
    if has_go httpx; then
        "$GOBIN/httpx" \
            -l "$P/all_subs.txt" \
            -title -tech-detect -status-code \
            -content-length -web-server -ip \
            -threads "$THREADS" -silent \
            "${EXTRA_HEADERS[@]:-}" \
            -o "$P/live_hosts.txt" 2>/dev/null || true

        "$GOBIN/httpx" \
            -l "$P/all_subs.txt" \
            -title -tech-detect -status-code -json \
            -threads "$THREADS" -silent \
            "${EXTRA_HEADERS[@]:-}" \
            -o "$P/live_hosts.json" 2>/dev/null || true

        grep -oP "https?://[^\s]+" "$P/live_hosts.txt" 2>/dev/null \
            | sort -u > "$P/live_urls.txt" || true
        grep -v "\[400\]\|\[404\]\|\[406\]\|\[444\]" \
            "$P/live_hosts.txt" > "$P/interesting_hosts.txt" 2>/dev/null || true
        ok "Живых: $(wc -l < "$P/live_hosts.txt") хостов"
    else
        err "httpx (Go) не найден. Установи: go install github.com/projectdiscovery/httpx/cmd/httpx@latest"
        # curl fallback
        while read -r sub; do
            for s in https http; do
                code=$(curl -s -o /dev/null -w "%{http_code}" --max-time 5 \
                    "${EXTRA_HEADERS[@]/#/-H }" \
                    "${s}://${sub}" 2>/dev/null || echo "000")
                [[ "$code" != "000" ]] && {
                    echo "${s}://${sub} [${code}]" >> "$P/live_hosts.txt"
                    echo "${s}://${sub}" >> "$P/live_urls.txt"
                    break
                }
            done
        done < <(head -50 "$P/all_subs.txt")
        ok "curl fallback: $(wc -l < "$P/live_hosts.txt") хостов"
    fi

    # 2.5 Port scanning — FIX #3: -c вместо -threads
    log "[2.5] Port scanning..."
    local IPORTS="8080,8443,8888,3000,3001,4000,5000,5601,6379,8000,8090,9090,9200,27017,4848,2375,4243"
    if has_go naabu; then
        "$GOBIN/naabu" -l "$P/all_subs.txt" -top-ports 1000 -c 25 -silent \
            -o "$P/open_ports.txt" 2>/dev/null || true
        ok "Портов: $(wc -l < "$P/open_ports.txt")"
        IFS=',' read -ra IARR <<< "$IPORTS"
        for p in "${IARR[@]}"; do
            grep ":${p}$" "$P/open_ports.txt" >> "$P/interesting_ports.txt" 2>/dev/null || true
        done
        sort -u "$P/interesting_ports.txt" -o "$P/interesting_ports.txt" 2>/dev/null || true
        [[ -s "$P/interesting_ports.txt" ]] && {
            warn "ИНТЕРЕСНЫЕ ПОРТЫ: $(wc -l < "$P/interesting_ports.txt")"
            cut -d: -f1 "$P/interesting_ports.txt" | sort -u > "$P/nmap_targets.txt"
        }
    elif command -v nmap &>/dev/null; then
        warn "naabu нет -> nmap..."
        nmap -p "$IPORTS" --open -T4 -iL "$P/all_subs.txt" \
            -oG "$P/nmap_open.txt" 2>/dev/null || true
    else warn "naabu/nmap нет — port scan пропущен"; fi

    # 2.6 nmap service detection (XML для парсинга в отчёте)
    if command -v nmap &>/dev/null && [[ -s "$P/nmap_targets.txt" ]]; then
        log "[2.6] nmap service detection..."
        nmap -sV -sC -p "$IPORTS" --open -T4 \
            -iL "$P/nmap_targets.txt" \
            -oX "$P/nmap_services.xml" \
            -oN "$P/nmap_services.txt" 2>/dev/null || true
        ok "nmap XML: $P/nmap_services.xml"
    fi

    # 2.7 Subdomain takeover
    log "[2.7] Takeover check..."
    if has_go nuclei && [[ -s "$P/live_urls.txt" ]]; then
        "$GOBIN/nuclei" -l "$P/live_urls.txt" -t takeovers/ -silent \
            -o "$P/takeovers.txt" 2>/dev/null || true
        local tc; tc=$(wc -l < "$P/takeovers.txt")
        [[ "$tc" -gt 0 ]] && warn "TAKEOVERS: $tc!" || ok "Takeover: нет"
    fi

    local live; live=$(wc -l < "$P/live_hosts.txt")
    local iports; iports=$(wc -l < "$P/interesting_ports.txt")
    local tak; tak=$(wc -l < "$P/takeovers.txt")

    # FIX #2: убрали || echo 0 — grep -c сам выводит 0
    tg_send "<b>Phase 2 завершена</b> — ${TARGET}\n🌐 Живых: <b>${live}</b>\n🔌 Инт. портов: <b>${iports}</b>\nTakeovers: ${tak}\n$([ "$iports" -gt 0 ] && echo "\n<code>$(head -5 "$P/interesting_ports.txt" 2>/dev/null)</code>" || true)\n⏳ Phase 3..."
}

# =================================================================
# PHASE 3 — МАППИНГ ПОВЕРХНОСТИ
# =================================================================
phase3() {
    sec "PHASE 3 — МАППИНГ ПОВЕРХНОСТИ"
    local P="$WD/surface" ACT="$WD/active" JSP="$WD/js"

    # 3.1 Content discovery — FIX #3: timeout + rate + >/dev/null
    log "[3.1] ffuf content discovery..."
    if has_go ffuf && [[ -f "$WORDLIST_DIR" ]] && [[ -s "$ACT/interesting_hosts.txt" ]]; then
        head -10 "$ACT/interesting_hosts.txt" \
            | grep -oP "https?://[^\s]+" \
            | while read -r url; do
                local safe; safe=$(echo "$url" | sed 's|[/:.]|_|g')
                # FIX #3: timeout 180 + -rate 30 + stdout -> /dev/null (результат в JSON)
                timeout 180 "$GOBIN/ffuf" \
                    -w "${WORDLIST_DIR}:FUZZ" \
                    -u "${url}/FUZZ" \
                    -mc "200,201,204,301,302,307,401,403" \
                    -t "$THREADS" \
                    -rate 30 \
                    -s \
                    "${EXTRA_HEADERS[@]:-}" \
                    -o "$P/ffuf_${safe}.json" -of json \
                    >/dev/null 2>/dev/null || true
              done
        ok "ffuf завершён"
    else warn "ffuf или wordlist нет — пропускаем"; fi

    # 3.2 Исторические URL
    log "[3.2] Исторические URL..."
    cat "$WD/passive/wayback_urls.txt" "$WD/passive/gau_urls.txt" \
        2>/dev/null | sort -u > "$P/all_historical_urls.txt" || true

    grep -iE "\.(php|asp|aspx|jsp|action|do|cfm|cgi)(\?|$)" \
        "$P/all_historical_urls.txt" 2>/dev/null | sort -u > "$P/legacy_endpoints.txt" || true
    grep -iE "(admin|panel|dashboard|api/v[0-9]|internal|debug|test|staging|backup|config|setup)" \
        "$P/all_historical_urls.txt" 2>/dev/null | sort -u > "$P/interesting_urls.txt" || true

    ok "Legacy: $(wc -l < "$P/legacy_endpoints.txt")  Interesting: $(wc -l < "$P/interesting_urls.txt")"

    # 3.3 JS — katana (заменяет getJS) FIX #5
    log "[3.3] JS crawling (katana)..."
    if has_go katana && [[ -s "$ACT/live_urls.txt" ]]; then
        head -20 "$ACT/live_urls.txt" | while read -r url; do
            "$GOBIN/katana" -u "$url" -d 2 -silent \
                -jc -kf all \
                "${EXTRA_HEADERS[@]/#/--header }" \
                2>/dev/null | grep -E "\.js(\?|$)" \
                >> "$JSP/js_files.txt" || true
        done
        sort -u "$JSP/js_files.txt" -o "$JSP/js_files.txt" 2>/dev/null || true
        ok "JS файлов: $(wc -l < "$JSP/js_files.txt")"
    else warn "katana нет"; fi

    # Поиск секретов в JS
    log "[3.3b] Поиск секретов..."
    local sc=0
    while read -r jsurl; do
        local found
        found=$(curl -sk --max-time 10 "${EXTRA_HEADERS[@]/#/-H }" "$jsurl" 2>/dev/null \
            | grep -iP "(api[_-]?key|apikey|secret[_-]?key|access[_-]?token|private[_-]?key|password\s*[:=]|aws[_-]?access|client[_-]?secret|bearer\s)" \
            2>/dev/null | grep -v "^\s*//" | head -3 || true)
        if [[ -n "$found" ]]; then
            { echo "=== $jsurl ==="; echo "$found"; } >> "$JSP/js_secrets.txt"
            ((sc++)) || true
        fi
    done < <(head -50 "$JSP/js_files.txt" 2>/dev/null || true)
    [[ "$sc" -gt 0 ]] && warn "Секретов в JS: $sc файлах" || ok "Секретов нет"

    # 3.4 Nuclei
    log "[3.4] Nuclei scan..."
    if has_go nuclei && [[ -s "$ACT/live_urls.txt" ]]; then
        "$GOBIN/nuclei" \
            -l "$ACT/live_urls.txt" \
            -t "cves/,exposures/,misconfiguration/,default-logins/" \
            -severity "critical,high,medium" \
            "${EXTRA_HEADERS[@]:-}" \
            -threads 25 -silent \
            -o "$WD/vulns/nuclei_findings.txt" 2>/dev/null || true
        local nc; nc=$(wc -l < "$WD/vulns/nuclei_findings.txt")
        [[ "$nc" -gt 0 ]] && warn "Nuclei findings: $nc" || ok "Nuclei: ничего"
    else warn "nuclei нет"; fi

    # 3.5 CORS
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

    # FIX #2: убрали || echo 0 — grep -c сам пишет 0
    local vuln; vuln=$(wc -l < "$WD/vulns/nuclei_findings.txt")
    local jsec; jsec=$(grep -c '===' "$JSP/js_secrets.txt" 2>/dev/null)
    local cors; cors=$(wc -l < "$P/cors_issues.txt")

    tg_send "<b>Phase 3 завершена</b> — ${TARGET}\n📝 Interesting: $(wc -l < "$P/interesting_urls.txt")\n🔑 Секретов JS: <b>${jsec}</b>\n🔬 Nuclei: <b>${vuln}</b>\n🌐 CORS: <b>${cors}</b>"
}

# =================================================================
# SERVICES REPORT (httpx JSON + nmap XML)
# =================================================================
generate_services_report() {
    python3 - "$WD/active/live_hosts.json" "$WD/active/nmap_services.xml" << 'PYEOF'
import json, sys, os

json_file = sys.argv[1] if len(sys.argv) > 1 else ""
xml_file  = sys.argv[2] if len(sys.argv) > 2 else ""

out = []
out.append("\n## Live Hosts & Technologies\n")
out.append("| URL | Status | Server | Technologies | IP |")
out.append("|---|---|---|---|---|")

try:
    with open(json_file) as f:
        for line in f:
            try:
                h = json.loads(line.strip())
                if not h: continue
                url    = h.get('url', '')
                status = h.get('status-code', '')
                server = h.get('webserver', '') or ''
                tech   = ', '.join(h.get('technologies', []))[:60]
                ip     = h.get('host', '')
                out.append(f"| {url} | {status} | {server} | {tech} | {ip} |")
            except: pass
except Exception as e:
    out.append(f"| *(ошибка: {e})* | | | | |")

out.append("\n## Open Ports & Service Versions\n")
out.append("| Host | Port | Protocol | Service | Version | State |")
out.append("|---|---|---|---|---|---|")

try:
    import xml.etree.ElementTree as ET
    tree = ET.parse(xml_file)
    root = tree.getroot()
    for host in root.findall('host'):
        addr_el = host.find('address[@addrtype="ipv4"]')
        ip = addr_el.get('addr','') if addr_el is not None else ''
        hn_el = host.find('.//hostname[@type="PTR"]')
        hostname = hn_el.get('name','') if hn_el is not None else ''
        display = hostname or ip
        for port in host.findall('.//port'):
            pid   = port.get('portid','')
            proto = port.get('protocol','')
            state = port.find('state')
            svc   = port.find('service')
            if state is not None and state.get('state') == 'open':
                sname   = svc.get('name','')    if svc is not None else ''
                product = svc.get('product','') if svc is not None else ''
                version = svc.get('version','') if svc is not None else ''
                full    = f"{product} {version}".strip()
                out.append(f"| {display} | {pid} | {proto} | {sname} | {full} | open |")
except Exception as e:
    out.append(f"| *(nmap XML: {e})* | | | | | |")

print('\n'.join(out))
PYEOF
}

# =================================================================
# ОТЧЁТ
# =================================================================
make_report() {
    sec "ОТЧЁТ"
    local RPT="$WD/reports/summary.md"

    cat > "$RPT" << MDEOF
# Recon Report: ${TARGET}
**Дата:** $(date)  |  **Директория:** \`${WD}\`

## Статистика
| Метрика | Значение |
|---|---|
| Субдоменов (raw) | $(wc -l < "$WD/passive/all_subs_raw.txt") |
| Живых хостов | $(wc -l < "$WD/active/live_hosts.txt") |
| Открытых портов | $(wc -l < "$WD/active/open_ports.txt") |
| Интересных портов | $(wc -l < "$WD/active/interesting_ports.txt") |
| Subdomain Takeovers | $(wc -l < "$WD/active/takeovers.txt") |
| Nuclei Findings | $(wc -l < "$WD/vulns/nuclei_findings.txt") |
| Секретов в JS | $(grep -c '===' "$WD/js/js_secrets.txt" 2>/dev/null) |
| CORS проблем | $(wc -l < "$WD/surface/cors_issues.txt") |

## Takeovers
\`\`\`
$(cat "$WD/active/takeovers.txt" 2>/dev/null || echo нет)
\`\`\`

## Nuclei Critical/High
\`\`\`
$(grep -iE 'critical|high' "$WD/vulns/nuclei_findings.txt" 2>/dev/null | head -20 || echo нет)
\`\`\`

## Секреты в JS
\`\`\`
$(head -20 "$WD/js/js_secrets.txt" 2>/dev/null || echo нет)
\`\`\`

## Интересные порты
\`\`\`
$(cat "$WD/active/interesting_ports.txt" 2>/dev/null || echo нет)
\`\`\`

## CORS Проблемы
\`\`\`
$(cat "$WD/surface/cors_issues.txt" 2>/dev/null || echo нет)
\`\`\`
MDEOF

    # Добавить секцию Services
    generate_services_report >> "$RPT"

    cat >> "$RPT" << MDEOF

## Phase 4 — с чего начать
1. **takeovers.txt** + **nuclei_findings.txt** — быстрые победы
2. **interesting_ports.txt** — Redis 6379? ES 9200? Jenkins 8080? Часто без auth!
3. **js_secrets.txt** — любой API ключ = готовый отчёт
4. Burp Suite на **interesting_urls.txt** с Autorize extension
5. Все параметры из historical URLs -> XSS/SQLi/SSTI
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

END=$(date +%s)
EL=$((END-START))
EL_FMT="$((EL/60))m $((EL%60))s"

sec "ЗАВЕРШЕНО"
printf "${W}%-14s${N}%s\n" "Domain:"  "$TARGET"
printf "${W}%-14s${N}%s\n" "Runtime:" "$EL_FMT"
printf "${W}%-14s${N}%s\n" "Results:" "$WD"
echo
echo -e "${W}Ключевые файлы:${N}"
for f in "active/live_urls.txt" "active/interesting_ports.txt" \
         "surface/interesting_urls.txt" "js/js_secrets.txt" \
         "vulns/nuclei_findings.txt" "reports/summary.md"; do
    echo -e "  ${C}->  ${N}$WD/$f"
done

tg_send "<b>Recon завершён!</b> — ${TARGET}\n⏱ <b>${EL_FMT}</b>\n\nИтоги:\n• Субдоменов: $(wc -l < "$WD/passive/all_subs_raw.txt")\n• Живых: $(wc -l < "$WD/active/live_hosts.txt")\n• Инт. портов: $(wc -l < "$WD/active/interesting_ports.txt")\n• Takeovers: $(wc -l < "$WD/active/takeovers.txt")\n• Nuclei: $(wc -l < "$WD/vulns/nuclei_findings.txt")\n• JS secrets: $(grep -c '===' "$WD/js/js_secrets.txt" 2>/dev/null)\n• CORS: $(wc -l < "$WD/surface/cors_issues.txt")"

tg_file "$WD/reports/summary.md" "Отчёт: ${TARGET}"
[[ -s "$WD/vulns/nuclei_findings.txt" ]] && \
    tg_file "$WD/vulns/nuclei_findings.txt" "Nuclei findings: ${TARGET}"
