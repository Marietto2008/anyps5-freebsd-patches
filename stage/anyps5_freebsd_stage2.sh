#!/bin/sh
# AnyPS5 / FreeBSD - Stage 2: full CTest suite and portability audit.
# Does not modify GTA6_PS5, Git working tree, CMake cache or binaries.
# Usage: ./anyps5_freebsd_stage2.sh audit|test|both
# Optional: BASE_DIR=/... WORKROOT=/... JOBS=4 TEST_TIMEOUT=180
set -eu

SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd -P)
BASE_DIR=${BASE_DIR:-$SCRIPT_DIR}
WORKROOT=${WORKROOT:-$BASE_DIR/AnyPS5-work}
SOURCE=$WORKROOT/source
BUILD=$WORKROOT/build-relinker
RELINKER=$BUILD/core/relinker/relinker
LOGDIR=$WORKROOT/logs/stage2
JOBS=${JOBS:-4}
TEST_TIMEOUT=${TEST_TIMEOUT:-180}
MODE=${1:-audit}

case "$MODE" in audit|test|both) ;; *)
    printf 'Uso: %s {audit|test|both}\n' "$0" >&2
    exit 2 ;;
esac
case "$JOBS" in ''|*[!0-9]*|0) echo 'JOBS deve essere un intero positivo' >&2; exit 2 ;; esac
case "$TEST_TIMEOUT" in ''|*[!0-9]*|0) echo 'TEST_TIMEOUT deve essere un intero positivo (secondi)' >&2; exit 2 ;; esac
command -v git >/dev/null 2>&1 || { echo '[ERRORE] git non trovato' >&2; exit 1; }
command -v cmake >/dev/null 2>&1 || { echo '[ERRORE] cmake non trovato' >&2; exit 1; }
command -v ctest >/dev/null 2>&1 || { echo '[ERRORE] ctest non trovato' >&2; exit 1; }
[ -d "$SOURCE/.git" ] || { echo "[ERRORE] Checkout mancante: $SOURCE" >&2; exit 1; }
[ -d "$BUILD" ] || { echo "[ERRORE] Directory build mancante: $BUILD" >&2; exit 1; }
[ -x "$RELINKER" ] || { echo "[ERRORE] Relinker nativo mancante: $RELINKER" >&2; exit 1; }
mkdir -p "$LOGDIR"

printf '[HOST] %s\n' "$(uname -srm)"
printf '[PERCORSI] BASE_DIR=%s\n' "$BASE_DIR"
printf '[SORGENTI] %s\n' "$SOURCE"
printf '[BUILD] %s\n' "$BUILD"
printf '[COMMIT] %s\n' "$(git -C "$SOURCE" rev-parse HEAD)"
printf '[ARCHIVIO] GTA VI non viene aperto, modificato o analizzato.\n'

run_audit() {
    report=$LOGDIR/audit.txt
    {
        echo '# AnyPS5 FreeBSD - audit preliminare non invasivo'
        date -u '+Data UTC: %Y-%m-%dT%H:%M:%SZ'
        uname -a
        echo
        echo '## Checkout e modifiche locali'
        git -C "$SOURCE" rev-parse HEAD
        git -C "$SOURCE" status --short
        echo
        echo '## Eseguibile relinker'
        file "$RELINKER"
        echo
        echo '## Librerie dinamiche del relinker'
        ldd "$RELINKER" || true
        echo
        echo '## Configurazione CMake (estratto)'
        cmake -N -LA "$BUILD" 2>&1 | grep -E '^(ANYPS5_|BUILD_TESTING|CMAKE_BUILD_TYPE|CMAKE_CXX_COMPILER|CMAKE_EXE_LINKER_FLAGS)' || true
        echo
        echo '## Test CTest registrati (riepilogo)'
        ctest --test-dir "$BUILD" -N 2>&1 | tail -n 5
        echo
        echo '## Punti di dipendenza OS (campione, non esaustivo)'
        echo 'Riferimenti a Linux/FreeBSD nel CMake principale e sotto core/libs, max 120 righe:'
        grep -R -n -E 'CMAKE_SYSTEM_NAME|__linux__|__FreeBSD__|SYS_(mmap|epoll|futex)|/proc/self' \
             "$SOURCE/CMakeLists.txt" "$SOURCE/core/libs" 2>/dev/null | head -n 120 || true
        echo
        echo '## Nota'
        echo 'Il relinker nativo FreeBSD produce output Linux ELF/Windows PE/macOS Mach-O;'
        echo 'questo controllo non dimostra il funzionamento delle librerie PS5 su FreeBSD.'
    } > "$report" 2>&1
    printf '[AUDIT] Report: %s\n' "$report"
    printf '[AUDIT] Riepilogo test registrati:\n'
    ctest --test-dir "$BUILD" -N 2>&1 | tail -n 2
}

run_test() {
    out=$LOGDIR/ctest-full.log
    printf '[TEST] Avvio suite CTest completa; JOBS=%s, limite per singolo test=%ss\n' "$JOBS" "$TEST_TIMEOUT"
    printf '[TEST] Log: %s\n' "$out"
    # No pipes here: preserve CTest exit status. No rebuild or reconfigure.
    status=0
    ctest --test-dir "$BUILD" --parallel "$JOBS" --timeout "$TEST_TIMEOUT" --output-on-failure > "$out" 2>&1 || status=$?
    printf '\n[TEST] Ultime 55 righe del risultato:\n'
    tail -n 55 "$out"
    if [ "$status" -ne 0 ]; then
        printf '\n[TEST] CTest ha rilevato uno o piu errori (exit %s).\n' "$status" >&2
        printf '[TEST] Per inviare il log: %s\n' "$out"
        return "$status"
    fi
    printf '\n[TEST] Suite completata senza errori segnalati da CTest.\n'
}

case "$MODE" in
    audit) run_audit ;;
    test) run_test ;;
    both) run_audit; run_test ;;
esac
