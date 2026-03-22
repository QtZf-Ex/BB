#!/usr/bin/env bash
# ══════════════════════════════════════════════════════════════════
#  🕷️  BugBounty Auto-Recon v3.1  (fixed)
#  Исправлено: subfinder флаги, httpx конфликт, naabu -c,
#              massdns → dnsx fallback, getJS путь,
#              pip --break-system-packages, touch для всех файлов
#
#  ┌─────────────────────────────────────────────────────────┐
#  │  📌 TELEGRAM — ВСТАВЬ ДАННЫЕ СЮДА (строки 44-45):      │
#  │                                                         │
#  │  TG_BOT_TOKEN="1234567890:AAHxxx..."  ← от @BotFather  │
#  │  TG_CHAT_ID="123456789"               ← ID чата/группы │
#  │                                                         │
#  │  Как получить CHAT_ID:                                  │
#  │  1. Напиши боту любое сообщение                        │
#  │  2. Открой в браузере:                                  │
#  │     api.telegram.org/bot<TOKEN>/getUpdates              │
#  │  3. Найди "chat":{"id": XXXXXXX}                       │
#  │  Группа/канал — ID начинается с минуса: -100XXXXXXXXX  │
#  └─────────────────────────────────────────────────────────┘
# ══════════════════════════════════════════════════════════════════

set -uo pipefail

# ─────────── TELEGRAM — ВСТАВЬ СВОИ ДАННЫЕ ───────────
TG_BOT_TOKEN=""   # 👈 "7123456789:AAHxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx"
TG_CHAT_ID=""     # 👈 "123456789"  или  "-1001234567890"  или  "@channel"
# ─────────────────────────────────────────────────────

# ── Цвета ──
R='\033[0;31m' G='\033[0;32m' Y='\033[1;33m'
B='\033[0;34m' C='\033[0;36m' W='\033[1m' N='\033[0m'

log()  { echo -e "${C}[*]${N} $*"; }
ok()   { echo -e "${G}[✓]${N} $*"; }
warn() { echo -e "${Y}[!]${N} $*"; }
err()  { echo -e "${R}[✗]${N} $*"; }
sec()  { echo -e "\n${W}${B}══ $* ══${N}\n"; }

# ── Настройки по умолчанию ──
TARGET=""
OUTDIR="$HOME/recon-results"
THREADS=30
DEEP=false
ONLY_PASSIVE=false
SKIP_ACTIVE=false
SKIP_SURFACE=false
CFG="$HOME/.config/recon"
WORDLIST_DNS="$CFG/wordlists/best-dns-wordlist.txt"
WORDLIST_DIR="$CFG/wordlists/raft-medium-words.txt"
RESOLVER_FILE="$CFG/resolvers.txt"

# ── Go bin — ключевой фикс для httpx/subfinder конфликтов ──
export PATH="$PATH:$HOME/go/bin:/usr/local/go/bin"
GOBIN="$HOME/go/bin"

has_go() { [[ -x "$GOBIN/$1" ]] || command -v "$1" &>/dev/null; }
run_go() { local t="$1"; shift; [[ -x "$GOBIN/$t" ]] && "$GOBIN/$t" "$@" || "$t" "$@"; }

# ── Telegram ──
tg_send() {
    [[ -z "$TG_BOT_TOKEN" || -z "$TG_CHAT_ID" ]] && return 0
    local msg="$1"
    curl -s -X POST "https://api.telegram.org/bot${TG_BOT_TOKEN}/sendMessage" \
        -H "Content-Type: application/json" --max-time 10 \
        -d "{\"chat_id\":\"${TG_CHAT_ID}\",\"text\":$(python3 -c "import json,sys;print(json.dumps(sys.stdin.read()))" <<< "$msg"),\"parse_mode\":\"HTML\",\"disable_web_page_preview\":true}" \
        -o /dev/null 2>/dev/null || true
}
tg_file() {
    [[ -z "$TG_BOT_TOKEN" || -z "$TG_CHAT_ID" ]] && return 0
    local f="$1" c="${2:-}"
    [[ ! -s "$f" ]] && return 0
    curl -s -X POST "https://api.telegram.org/bot${TG_BOT_TOKEN}/sendDocument" \
        -F "chat_id=${TG_CHAT_ID}" -F "document=@${f}" -F "caption=${c}" \
        --max-time 30 -o /dev/null 2>/dev/null || true
}

usage() {
    echo "Использование: $0 -d TARGET [опции]"
    echo "  -d, --domain    Целевой домен"
    echo "  -o, --output    Директория результатов"
    echo "  -t, --threads   Потоки (default: 30)"
    echo "  --deep          Глубокий режим"
    echo "  --only-passive  Только Phase 1"
    echo "  --install       Установить зависимости"
    echo "  --test-tg       Тест Telegram"
    echo "  -h, --help      Помощь"
    exit 0
}

test_tg() {
    sec "Тест Telegram"
    [[ -z "$TG_BOT_TOKEN" ]] && { err "TG_BOT_TOKEN не заполнен (строка 44)"; exit 1; }
    [[ -z "$TG_CHAT_ID"   ]] && { err "TG_CHAT_ID не заполнен (строка 45)";   exit 1; }
    tg_send "✅ <b>Recon Bot работает!</b>\n🕷️ recon.sh v3.1 подключён"
    ok "Сообщение отправлено. Проверь Telegram!"
    exit 0
}

# ══════════════════════════════════════════════════════
# INSTALL
# ══════════════════════════════════════════════════════
install_tools() {
    sec "Установка (v3.1 — все ошибки исправлены)"

    if ! command -v go &>/dev/null; then
        log "Устанавливаем Go..."
        local ARCH; ARCH=$(uname -m)
        [[ "$ARCH" == "aarch64" ]] && ARCH="arm64" || ARCH="amd64"
        curl -sL "https://go.dev/dl/go1.22.0.linux-${ARCH}.tar.gz" -o /tmp/go.tar.gz
        sudo rm -rf /usr/local/go && sudo tar -C /usr/local -xzf /tmp/go.tar.gz
        export PATH="$PATH:/usr/local/go/bin:$HOME/go/bin"
        echo 'export PATH="$PATH:/usr/local/go/bin:$HOME/go/bin"' >> ~/.bashrc
    fi
    ok "Go: $(go version 2>/dev/null || echo 'не найден')"
    mkdir -p "$HOME/go/bin"
    export PATH="$PATH:$HOME/go/bin"

    command -v apt-get &>/dev/null && {
        log "Системные пакеты..."
        sudo apt-get update -qq 2>/dev/null
        sudo apt-get install -y -qq git curl wget python3 python3-pip dnsutils nmap jq make gcc 2>/dev/null || true
    }

    # ФИКС #4: massdns (зависимость puredns)
    if ! command -v massdns &>/dev/null; then
        log "massdns..."
        sudo apt-get install -y -qq massdns 2>/dev/null && ok "massdns (apt)" || {
            log "Собираем massdns из исходников..."
            git clone --depth=1 https://github.com/blechschmidt/massdns.git /tmp/massdns 2>/dev/null
            cd /tmp/massdns && make 2>/dev/null && sudo cp bin/massdns /usr/local/bin/ && cd - > /dev/null
            command -v massdns &>/dev/null && ok "massdns (built)" || warn "massdns не собрался — будем использовать dnsx"
        }
    else ok "massdns — уже есть"; fi

    # ФИКС #1,#3,#5: правильные пути и флаги Go инструментов
    _go() {
        local n="$1" p="$2"
        [[ -x "$GOBIN/$n" ]] && { ok "$n — уже установлен"; return; }
        log "→ $n"
        go install "$p" 2>/dev/null && ok "$n" || warn "$n — ошибка"
    }
    _go subfinder  "github.com/projectdiscovery/subfinder/v2/cmd/subfinder@latest"
    _go httpx      "github.com/projectdiscovery/httpx/cmd/httpx@latest"
    _go naabu      "github.com/projectdiscovery/naabu/v2/cmd/naabu@latest"
    _go nuclei     "github.com/projectdiscovery/nuclei/v3/cmd/nuclei@latest"
    _go dnsx       "github.com/projectdiscovery/dnsx/cmd/dnsx@latest"
    _go alterx     "github.com/projectdiscovery/alterx/cmd/alterx@latest"
    _go puredns    "github.com/d3mondev/puredns/v2@latest"
    _go waybackurls "github.com/tomnomnom/waybackurls@latest"
    _go gau        "github.com/lc/gau/v2/cmd/gau@latest"
    _go getJS      "github.com/003random/getJS@latest"          # ФИКС #5: без /v2/cmd
    _go ffuf       "github.com/ffuf/ffuf/v2@latest"

    # ФИКС #6: Debian 12+ PEP 668 — используем --break-system-packages
    _pip() {
        local p="$1"
        command -v "$p" &>/dev/null && { ok "$p — уже установлен"; return; }
        log "→ $p (pip)"
        pip3 install "$p" --break-system-packages -q 2>/dev/null && ok "$p" && return
        pip3 install "$p" --user -q 2>/dev/null && ok "$p" && return
        command -v pipx &>/dev/null && pipx install "$p" 2>/dev/null && ok "$p" && return
        warn "$p — не удалось установить"
    }
    _pip arjun
    _pip requests

    mkdir -p "$CFG/wordlists"
    local WLB="https://raw.githubusercontent.com/danielmiessler/SecLists/master"
    [[ ! -f "$WORDLIST_DNS" ]] && curl -sL "$WLB/Discovery/DNS/best-dns-wordlist.txt" -o "$WORDLIST_DNS" && ok "DNS wordlist" || ok "DNS wordlist — уже есть"
    [[ ! -f "$WORDLIST_DIR" ]] && curl -sL "$WLB/Discovery/Web-Content/raft-medium-words.txt" -o "$WORDLIST_DIR" && ok "Dir wordlist" || ok "Dir wordlist — уже есть"

    [[ ! -f "$RESOLVER_FILE" ]] && {
        mkdir -p "$(dirname "$RESOLVER_FILE")"
        curl -sL "https://raw.githubusercontent.com/trickest/resolvers/main/resolvers.txt" -o "$RESOLVER_FILE" \
            && ok "DNS resolvers" || warn "resolvers не скачались"
    } || ok "DNS resolvers — уже есть"

    [[ -x "$GOBIN/nuclei" ]] && run_go nuclei -update-templates -silent 2>/dev/null && ok "nuclei templates" || true

    sec "Статус"
    for t in subfinder httpx naabu nuclei dnsx puredns massdns waybackurls gau getJS ffuf nmap curl python3 arjun; do
        [[ -x "$GOBIN/$t" ]] || command -v "$t" &>/dev/null && ok "$t" || warn "$t — НЕ УСТАНОВЛЕН"
    done
    echo ""; ok "Готово! Запуск: ./recon.sh -d target.com"
    exit 0
}

# ── Аргументы ──
while [[ $# -gt 0 ]]; do
    case $1 in
        -d|--domain)    TARGET="$2"; shift 2 ;;
        -o|--output)    OUTDIR="$2"; shift 2 ;;
        -t|--threads)   THREADS="$2"; shift 2 ;;
        --deep)         DEEP=true; shift ;;
        --only-passive) ONLY_PASSIVE=true; shift ;;
        --skip-active)  SKIP_ACTIVE=true; shift ;;
        --skip-surface) SKIP_SURFACE=true; shift ;;
        --install)      install_tools ;;
        --test-tg)      test_tg ;;
        -h|--help)      usage ;;
        *) err "Неизвестно: $1"; usage ;;
    esac
done
[[ -z "$TARGET" ]] && { err "Укажи домен: -d target.com"; usage; }

# ── Workspace ──
TS=$(date +%Y%m%d_%H%M%S)
WD="$OUTDIR/$TARGET/$TS"
mkdir -p "$WD"/{passive,active,surface,js,vulns,reports}

# ФИКС #7: pre-create всех файлов → wc -l не падает
touch "$WD/passive/crt_subs.txt"       "$WD/passive/subfinder_subs.txt"
touch "$WD/passive/amass_subs.txt"     "$WD/passive/chaos_subs.txt"
touch "$WD/passive/wayback_urls.txt"   "$WD/passive/wayback_subs.txt"
touch "$WD/passive/gau_urls.txt"       "$WD/passive/gau_subs.txt"
touch "$WD/passive/all_subs_raw.txt"
touch "$WD/active/resolved_subs.txt"   "$WD/active/brute_subs.txt"
touch "$WD/active/permutation_subs.txt" "$WD/active/all_subs.txt"
touch "$WD/active/live_hosts.txt"      "$WD/active/live_hosts.json"
touch "$WD/active/live_urls.txt"       "$WD/active/interesting_hosts.txt"
touch "$WD/active/open_ports.txt"      "$WD/active/interesting_ports.txt"
touch "$WD/active/nmap_targets.txt"    "$WD/active/takeovers.txt"
touch "$WD/surface/interesting_urls.txt" "$WD/surface/legacy_endpoints.txt"
touch "$WD/surface/all_params.txt"     "$WD/surface/cors_issues.txt"
touch "$WD/surface/technologies.txt"   "$WD/surface/all_historical_urls.txt"
touch "$WD/js/js_files.txt"            "$WD/js/js_endpoints.txt" "$WD/js/js_secrets.txt"
touch "$WD/vulns/nuclei_findings.txt"  # ФИКС #7: был причиной ошибки line 572!

LOG="$WD/recon.log"
exec > >(tee -a "$LOG") 2>&1

echo -e "${W}${B}"
echo "  ╔════════════════════════════════════════════╗"
echo "  ║   🕷️  BugBounty Auto-Recon v3.1  (fixed)   ║"
echo "  ╚════════════════════════════════════════════╝"
echo -e "${N}"
printf "${W}%-14s${N}%s\n" "Target:"   "$TARGET"
printf "${W}%-14s${N}%s\n" "Output:"   "$WD"
printf "${W}%-14s${N}%s\n" "Threads:"  "$THREADS"
printf "${W}%-14s${N}%s\n" "Started:"  "$(date)"
printf "${W}%-14s${N}%s\n" "Telegram:" "$([[ -n "$TG_BOT_TOKEN" ]] && echo '✅ настроен' || echo '⚠️  не настроен (строки 44-45)')"
echo ""
tg_send "🕷️ <b>Recon запущен</b>\n🎯 <code>${TARGET}</code>\n🕐 $(date '+%d.%m.%Y %H:%M')"

# ══════════════════════════════════════════════════════
# PHASE 1
# ══════════════════════════════════════════════════════
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

    # ФИКС #1: массив вместо строки флагов
    log "[1.2] subfinder..."
    if [[ -x "$GOBIN/subfinder" ]]; then
        local sf=("-d" "$TARGET" "--all" "-silent")
        [[ "$DEEP" == "true" ]] && sf+=("-recursive")
        "$GOBIN/subfinder" "${sf[@]}" -o "$P/subfinder_subs.txt" 2>/dev/null || true
        ok "subfinder: $(wc -l < "$P/subfinder_subs.txt") субдоменов"
    else warn "subfinder не найден"; fi

    log "[1.3] amass..."
    command -v amass &>/dev/null && {
        timeout 180 amass enum -passive -d "$TARGET" -silent -o "$P/amass_subs.txt" 2>/dev/null || true
        ok "amass: $(wc -l < "$P/amass_subs.txt") субдоменов"
    } || warn "amass не найден"

    log "[1.4] waybackurls..."
    if [[ -x "$GOBIN/waybackurls" ]]; then
        echo "$TARGET" | "$GOBIN/waybackurls" 2>/dev/null \
            | tee "$P/wayback_urls.txt" \
            | grep -oP "[a-zA-Z0-9._-]+\.${TARGET}" 2>/dev/null | sort -u > "$P/wayback_subs.txt" || true
        ok "Wayback: $(wc -l < "$P/wayback_urls.txt") URL"
    else
        curl -s --max-time 30 "http://web.archive.org/cdx/search/cdx?url=*.${TARGET}/*&output=text&fl=original&collapse=urlkey" \
            2>/dev/null | sort -u > "$P/wayback_urls.txt" || true
        ok "CDX fallback: $(wc -l < "$P/wayback_urls.txt") URL"
    fi

    log "[1.5] gau..."
    [[ -x "$GOBIN/gau" ]] && {
        "$GOBIN/gau" "$TARGET" --threads "$THREADS" \
            --blacklist "png,jpg,gif,css,ttf,woff,svg,ico,woff2,eot" \
            --o "$P/gau_urls.txt" 2>/dev/null || true
        grep -oP "[a-zA-Z0-9._-]+\.${TARGET}" "$P/gau_urls.txt" 2>/dev/null | sort -u > "$P/gau_subs.txt" || true
        ok "gau: $(wc -l < "$P/gau_urls.txt") URL"
    } || warn "gau не найден"

    log "[1.6] DNS records..."
    command -v dig &>/dev/null && {
        { echo "### MX"; dig MX "$TARGET" +short 2>/dev/null
          echo "### TXT"; dig TXT "$TARGET" +short 2>/dev/null
          echo "### NS"; dig NS "$TARGET" +short 2>/dev/null
        } > "$WD/passive/dns_records.txt"
    }

    cat "$P"/*_subs.txt 2>/dev/null | tr '[:upper:]' '[:lower:]' \
        | grep -v "^\*\." | grep -v "^#" | grep -v "^$" \
        | grep -E "(\.${TARGET}$|^${TARGET}$)" | sort -u > "$P/all_subs_raw.txt" || true
    local cnt; cnt=$(wc -l < "$P/all_subs_raw.txt")
    ok "ИТОГО: ${W}${cnt}${N} субдоменов"

    tg_send "📡 <b>Phase 1 завершена</b> — ${TARGET}\nСубдоменов: <b>${cnt}</b>\n• crt.sh: $(wc -l < "$P/crt_subs.txt")\n• subfinder: $(wc -l < "$P/subfinder_subs.txt")\n• wayback: $(wc -l < "$P/wayback_urls.txt") URL\n⏳ Phase 2..."
}

# ══════════════════════════════════════════════════════
# PHASE 2
# ══════════════════════════════════════════════════════
phase2() {
    sec "PHASE 2 — АКТИВНАЯ РАЗВЕДКА"
    local P="$WD/active" PASS="$WD/passive"

    # ФИКС #4: dnsx fallback если нет massdns
    log "[2.1] DNS резолвинг..."
    if [[ -x "$GOBIN/puredns" ]] && command -v massdns &>/dev/null && [[ -f "$RESOLVER_FILE" ]]; then
        "$GOBIN/puredns" resolve "$PASS/all_subs_raw.txt" -r "$RESOLVER_FILE" -w "$P/resolved_subs.txt" --quiet 2>/dev/null \
            || cp "$PASS/all_subs_raw.txt" "$P/resolved_subs.txt"
        ok "puredns: $(wc -l < "$P/resolved_subs.txt") резолвятся"
    elif [[ -x "$GOBIN/dnsx" ]]; then
        log "massdns нет → dnsx..."
        "$GOBIN/dnsx" -l "$PASS/all_subs_raw.txt" -silent -o "$P/resolved_subs.txt" 2>/dev/null \
            || cp "$PASS/all_subs_raw.txt" "$P/resolved_subs.txt"
        ok "dnsx: $(wc -l < "$P/resolved_subs.txt") резолвятся"
    else
        cp "$PASS/all_subs_raw.txt" "$P/resolved_subs.txt"
        warn "puredns/dnsx нет — используем raw список"
    fi

    log "[2.2] DNS brute-force..."
    if [[ -x "$GOBIN/puredns" ]] && command -v massdns &>/dev/null && [[ -f "$WORDLIST_DNS" ]]; then
        "$GOBIN/puredns" bruteforce "$WORDLIST_DNS" "$TARGET" -r "$RESOLVER_FILE" -w "$P/brute_subs.txt" --quiet 2>/dev/null || true
        ok "puredns brute: $(wc -l < "$P/brute_subs.txt")"
    elif [[ -x "$GOBIN/dnsx" ]] && [[ -f "$WORDLIST_DNS" ]]; then
        log "massdns нет → dnsx brute..."
        while IFS= read -r w; do echo "${w}.${TARGET}"; done < <(head -10000 "$WORDLIST_DNS") \
            | "$GOBIN/dnsx" -silent -o "$P/brute_subs.txt" 2>/dev/null || true
        ok "dnsx brute: $(wc -l < "$P/brute_subs.txt")"
    else warn "Брутфорс пропущен"; fi

    [[ -x "$GOBIN/alterx" ]] && {
        log "[2.3] Permutations..."
        cat "$P/resolved_subs.txt" "$P/brute_subs.txt" 2>/dev/null \
            | "$GOBIN/alterx" -enrich 2>/dev/null | head -50000 \
            | ([[ -x "$GOBIN/dnsx" ]] && "$GOBIN/dnsx" -silent -o "$P/permutation_subs.txt" || tee "$P/permutation_subs.txt") > /dev/null 2>/dev/null || true
        ok "permutations: $(wc -l < "$P/permutation_subs.txt")"
    }

    cat "$P/resolved_subs.txt" "$P/brute_subs.txt" "$P/permutation_subs.txt" 2>/dev/null | sort -u > "$P/all_subs.txt" || true
    ok "Всего: ${W}$(wc -l < "$P/all_subs.txt")${N} субдоменов"

    # ФИКС #2: явно $GOBIN/httpx
    log "[2.4] HTTP probing..."
    if [[ -x "$GOBIN/httpx" ]]; then
        "$GOBIN/httpx" -l "$P/all_subs.txt" -title -tech-detect -status-code \
            -content-length -web-server -ip -threads "$THREADS" -silent \
            -o "$P/live_hosts.txt" 2>/dev/null || true
        "$GOBIN/httpx" -l "$P/all_subs.txt" -title -tech-detect -status-code -json \
            -threads "$THREADS" -silent -o "$P/live_hosts.json" 2>/dev/null || true
        grep -oP "https?://[^\s]+" "$P/live_hosts.txt" 2>/dev/null | sort -u > "$P/live_urls.txt" || true
        grep -v "\[400\]\|\[404\]\|\[406\]\|\[444\]" "$P/live_hosts.txt" > "$P/interesting_hosts.txt" 2>/dev/null || true
        ok "Живых: ${W}$(wc -l < "$P/live_hosts.txt")${N} хостов"
    else
        err "httpx (Go) не найден в $GOBIN!"
        log "Fallback: curl..."
        while read -r sub; do
            for s in https http; do
                code=$(curl -s -o /dev/null -w "%{http_code}" --max-time 5 "${s}://${sub}" 2>/dev/null || echo "000")
                if [[ "$code" != "000" ]]; then
                    echo "${s}://${sub} [${code}]" >> "$P/live_hosts.txt"
                    echo "${s}://${sub}" >> "$P/live_urls.txt"
                    break
                fi
            done
        done < <(head -30 "$P/all_subs.txt")
        ok "curl fallback: $(wc -l < "$P/live_hosts.txt") хостов"
    fi

    # ФИКС #3: -c вместо -threads
    log "[2.5] Port scanning..."
    local IPORTS="8080,8443,8888,3000,3001,4000,5000,5601,6379,8000,8090,9090,9200,27017,4848"
    if [[ -x "$GOBIN/naabu" ]]; then
        "$GOBIN/naabu" -l "$P/all_subs.txt" -top-ports 1000 -c 25 -silent \
            -o "$P/open_ports.txt" 2>/dev/null || true
        ok "Портов: $(wc -l < "$P/open_ports.txt")"
        IFS=',' read -ra IARR <<< "$IPORTS"
        for p in "${IARR[@]}"; do
            grep ":${p}$" "$P/open_ports.txt" >> "$P/interesting_ports.txt" 2>/dev/null || true
        done
        sort -u "$P/interesting_ports.txt" -o "$P/interesting_ports.txt" 2>/dev/null || true
        [[ -s "$P/interesting_ports.txt" ]] && warn "Интересные порты: $(wc -l < "$P/interesting_ports.txt")" || true
    elif command -v nmap &>/dev/null; then
        nmap -p "$IPORTS" --open -T4 -iL "$P/all_subs.txt" -oG "$P/nmap_open.txt" 2>/dev/null || true
    else warn "naabu/nmap нет — port scan пропущен"; fi

    log "[2.6] Subdomain takeover..."
    [[ -x "$GOBIN/nuclei" ]] && [[ -s "$P/live_urls.txt" ]] && {
        "$GOBIN/nuclei" -l "$P/live_urls.txt" -t takeovers/ -silent -o "$P/takeovers.txt" 2>/dev/null || true
        local tc; tc=$(wc -l < "$P/takeovers.txt")
        [[ "$tc" -gt 0 ]] && warn "⚠️  TAKEOVERS: $tc!" || ok "Takeover: не найдено"
    }

    tg_send "🔎 <b>Phase 2 завершена</b> — ${TARGET}\n🌐 Живых: <b>$(wc -l < "$P/live_hosts.txt")</b>\n🔌 Инт. портов: <b>$(wc -l < "$P/interesting_ports.txt")</b>\nTakeovers: $(wc -l < "$P/takeovers.txt")\n⏳ Phase 3..."
}

# ══════════════════════════════════════════════════════
# PHASE 3
# ══════════════════════════════════════════════════════
phase3() {
    sec "PHASE 3 — МАППИНГ ПОВЕРХНОСТИ"
    local P="$WD/surface" ACT="$WD/active" JSP="$WD/js"

    log "[3.1] ffuf..."
    [[ -x "$GOBIN/ffuf" ]] && [[ -f "$WORDLIST_DIR" ]] && [[ -s "$ACT/interesting_hosts.txt" ]] && {
        head -10 "$ACT/interesting_hosts.txt" | grep -oP "https?://[^\s]+" | while read -r url; do
            local safe; safe=$(echo "$url" | sed 's|[/:.]|_|g')
            "$GOBIN/ffuf" -w "${WORDLIST_DIR}:FUZZ" -u "${url}/FUZZ" \
                -mc "200,201,204,301,302,307,401,403,405" \
                -t "$THREADS" -c -s -o "$P/ffuf_${safe}.json" -of json 2>/dev/null || true
        done; ok "ffuf завершён"
    } || warn "ffuf или wordlist не найден"

    log "[3.2] Исторические URL..."
    cat "$WD/passive/wayback_urls.txt" "$WD/passive/gau_urls.txt" 2>/dev/null | sort -u > "$P/all_historical_urls.txt" || true
    grep -iE "\.(php|asp|aspx|jsp|action|do|cfm|cgi)(\?|$)" "$P/all_historical_urls.txt" 2>/dev/null | sort -u > "$P/legacy_endpoints.txt" || true
    grep -iE "(admin|panel|dashboard|api/v[0-9]|internal|debug|test|staging|backup|config|setup)" \
        "$P/all_historical_urls.txt" 2>/dev/null | sort -u > "$P/interesting_urls.txt" || true
    ok "Legacy: $(wc -l < "$P/legacy_endpoints.txt")  Interesting: $(wc -l < "$P/interesting_urls.txt")"

    log "[3.3] JavaScript..."
    [[ -x "$GOBIN/getJS" ]] && [[ -s "$ACT/live_urls.txt" ]] && {
        head -30 "$ACT/live_urls.txt" | while read -r u; do
            "$GOBIN/getJS" --url "$u" --complete 2>/dev/null >> "$JSP/js_files.txt" || true
        done
        sort -u "$JSP/js_files.txt" -o "$JSP/js_files.txt" 2>/dev/null || true
        ok "JS файлов: $(wc -l < "$JSP/js_files.txt")"
    } || warn "getJS не найден"

    local sc=0
    while read -r jsurl; do
        local found
        found=$(curl -sk --max-time 10 "$jsurl" 2>/dev/null \
            | grep -iP "(api[_-]?key|apikey|secret[_-]?key|access[_-]?token|private[_-]?key|password\s*[:=]|aws[_-]?access|client[_-]?secret)" \
            2>/dev/null | grep -v "//" | head -3 || true)
        if [[ -n "$found" ]]; then
            echo "=== $jsurl ===" >> "$JSP/js_secrets.txt"
            echo "$found" >> "$JSP/js_secrets.txt"
            ((sc++)) || true
        fi
    done < <(head -50 "$JSP/js_files.txt" 2>/dev/null || true)
    [[ "$sc" -gt 0 ]] && warn "⚠️  Секретов в $sc JS!" || ok "JS секретов нет"

    log "[3.4] Nuclei..."
    [[ -x "$GOBIN/nuclei" ]] && [[ -s "$ACT/live_urls.txt" ]] && {
        "$GOBIN/nuclei" -l "$ACT/live_urls.txt" \
            -t "cves/,exposures/,misconfiguration/,default-logins/" \
            -severity "critical,high,medium" -threads 25 -silent \
            -o "$WD/vulns/nuclei_findings.txt" 2>/dev/null || true
        local nc; nc=$(wc -l < "$WD/vulns/nuclei_findings.txt")
        [[ "$nc" -gt 0 ]] && warn "⚠️  Nuclei: $nc!" || ok "Nuclei: ничего"
    } || warn "nuclei нет"

    log "[3.5] CORS..."
    head -20 "$ACT/live_urls.txt" 2>/dev/null | while read -r url; do
        local r; r=$(curl -sk --max-time 8 -H "Origin: https://evil.com" -I "$url" 2>/dev/null \
            | grep -i "access-control-allow-origin" || true)
        echo "$r" | grep -qi "evil.com\|null" && echo "CORS: $url → $r" >> "$P/cors_issues.txt" || true
    done
    ok "CORS: $(wc -l < "$P/cors_issues.txt") проблем"

    tg_send "🗺️ <b>Phase 3 завершена</b> — ${TARGET}\n📝 Interesting: $(wc -l < "$P/interesting_urls.txt")\n🔑 Секретов в JS: $(grep -c '===' "$JSP/js_secrets.txt" 2>/dev/null || echo 0)\n🔬 Nuclei: $(wc -l < "$WD/vulns/nuclei_findings.txt")\n🌐 CORS: $(wc -l < "$P/cors_issues.txt")"
}

# ══════════════════════════════════════════════════════
# ОТЧЁТ
# ══════════════════════════════════════════════════════
make_report() {
    sec "ОТЧЁТ"
    local RPT="$WD/reports/summary.md"
    cat > "$RPT" << MDEOF
# 🕷️ Recon: ${TARGET} — $(date)

| Метрика | Значение |
|---|---|
| Субдоменов (raw) | $(wc -l < "$WD/passive/all_subs_raw.txt") |
| Живых хостов | $(wc -l < "$WD/active/live_hosts.txt") |
| Открытых портов | $(wc -l < "$WD/active/open_ports.txt") |
| Интересных портов | $(wc -l < "$WD/active/interesting_ports.txt") |
| Takeovers | $(wc -l < "$WD/active/takeovers.txt") |
| Nuclei findings | $(wc -l < "$WD/vulns/nuclei_findings.txt") |
| Секретов в JS | $(grep -c '===' "$WD/js/js_secrets.txt" 2>/dev/null || echo 0) |
| CORS проблем | $(wc -l < "$WD/surface/cors_issues.txt") |

## Takeovers
\`\`\`
$(cat "$WD/active/takeovers.txt" 2>/dev/null || echo "нет")
\`\`\`

## Nuclei Critical/High
\`\`\`
$(grep -iE "critical|high" "$WD/vulns/nuclei_findings.txt" 2>/dev/null | head -20 || echo "нет")
\`\`\`

## Секреты в JS
\`\`\`
$(head -20 "$WD/js/js_secrets.txt" 2>/dev/null || echo "нет")
\`\`\`

## Интересные порты
\`\`\`
$(cat "$WD/active/interesting_ports.txt" 2>/dev/null || echo "нет")
\`\`\`
MDEOF
    ok "Отчёт: $RPT"
}

# ══════════════════════════════════════════════════════
# MAIN
# ══════════════════════════════════════════════════════
START=$(date +%s)
phase1
[[ "$ONLY_PASSIVE" == "false" && "$SKIP_ACTIVE" == "false" ]]  && phase2
[[ "$ONLY_PASSIVE" == "false" && "$SKIP_SURFACE" == "false" ]] && phase3
make_report
END=$(date +%s); EL=$((END-START)); EL_FMT="$((EL/60))m $((EL%60))s"

sec "✅ ЗАВЕРШЕНО"
printf "${W}%-12s${N}%s\n" "Domain:"  "$TARGET"
printf "${W}%-12s${N}%s\n" "Runtime:" "$EL_FMT"
printf "${W}%-12s${N}%s\n" "Results:" "$WD"
echo -e "\n${W}Ключевые файлы:${N}"
echo -e "  ${C}→${N} $WD/active/live_urls.txt"
echo -e "  ${C}→${N} $WD/surface/interesting_urls.txt"
echo -e "  ${C}→${N} $WD/js/js_secrets.txt"
echo -e "  ${C}→${N} $WD/vulns/nuclei_findings.txt"
echo -e "  ${C}→${N} $WD/reports/summary.md"

tg_send "✅ <b>Recon завершён!</b> — ${TARGET}\n⏱️ <b>${EL_FMT}</b>\n\n📊 Итоги:\n• Субдоменов: $(wc -l < "$WD/passive/all_subs_raw.txt")\n• Живых: $(wc -l < "$WD/active/live_hosts.txt")\n• Инт. портов: $(wc -l < "$WD/active/interesting_ports.txt")\n• Takeovers: $(wc -l < "$WD/active/takeovers.txt")\n• Nuclei: $(wc -l < "$WD/vulns/nuclei_findings.txt")\n• JS secrets: $(grep -c '===' "$WD/js/js_secrets.txt" 2>/dev/null || echo 0)"
tg_file "$WD/reports/summary.md" "📋 Отчёт: ${TARGET}"
[[ -s "$WD/vulns/nuclei_findings.txt" ]] && tg_file "$WD/vulns/nuclei_findings.txt" "🚨 Nuclei: ${TARGET}"