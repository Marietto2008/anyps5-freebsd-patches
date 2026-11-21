#!/bin/sh
# AnyPS5 / FreeBSD - Fase 3 v1.3: preparazione e build incrementale runtime.
# Modalita: audit | fetch | patch | configure | build | targets
# NON apre o modifica GTA6_PS5; NON aggiorna il commit di AnyPS5.
# NON installa pacchetti. Patch FreeBSD idempotenti: libusb (CMake principale) e, dalla v1.3, la serie
# git in anyps5_freebsd_patches/ (libcxxrt, tm_zone, GuestArena, gettid, ...).
# Le modalita patch, configure e build applicano le patch prima di lavorare.
set -eu

SCRIPT_DIR=$(CDPATH= cd -P "$(dirname "$0")" && pwd)
BASE_DIR=${BASE_DIR:-$SCRIPT_DIR}
WORKROOT=${WORKROOT:-$BASE_DIR/AnyPS5-work}
SRC="$WORKROOT/source"
RELINKER_BUILD="$WORKROOT/build-relinker"
BUILD="$WORKROOT/build-runtime"
LOGDIR="$WORKROOT/logs/stage3"
PATCHDIR=${PATCHDIR:-$BASE_DIR/anyps5_freebsd_patches}
EXPECTED_COMMIT=9c16c9b09e5be534780503689411404e68f670be
JOBS=${JOBS:-4}
MODE=${1:-audit}

say() { printf '\n[%s] %s\n' "$1" "$2"; }
fail() { printf '[ERRORE] %s\n' "$1" >&2; exit 1; }
usage() {
    cat <<'USAGE'
Uso: ./anyps5_freebsd_stage3_v1_3.sh audit|fetch|patch|ffmpeg|configure|build|targets
  audit      Stato host, submodule e preflight; non cambia i sorgenti.
  fetch      Scarica i submodule fissati dal commit esistente (puo essere molto grande).
  patch      Adatta a FreeBSD: CMake (libusb) e la serie anyps5_freebsd_patches/.
  ffmpeg     Costruisce FFmpeg per FreeBSD (stesso sorgente e componenti della build Linux).
  configure  Applica le patch, costruisce FFmpeg se manca e configura il runtime separato.
  build      Applica le patch e compila nid_patcher, libc, libkernel e libs (le 413 librerie PS5).
  targets    Elenca i target CMake della build runtime configurata.

Opzioni ambientali:
  BASE_DIR=<cartella dello script>  (vi stanno AnyPS5-work/ e anyps5_freebsd_patches/)
  WORKROOT=$BASE_DIR/AnyPS5-work
  JOBS=4
  BUILD_TARGETS='nid_patcher libc libkernel libs'  (solo per build)

Non installa pacchetti, non decripta PKG e non altera build relinker o submodule.
Per ripristinare il CMake principale, vedi backup in logs/stage3.
USAGE
}

case "$MODE" in audit|fetch|patch|ffmpeg|configure|build|targets) : ;; -h|--help|help) usage; exit 0 ;; *) usage >&2; exit 2 ;; esac
case "$JOBS" in ''|*[!0-9]*|0) fail 'JOBS deve essere un intero positivo.' ;; esac
[ "$(uname -s)" = FreeBSD ] || fail 'Fase 3 pensata esclusivamente per FreeBSD.'
[ -d "$SRC/.git" ] || fail "Checkout mancante: $SRC (esegui prima fase 1)."
command -v git >/dev/null 2>&1 || fail 'git assente'
commit=$(git -C "$SRC" rev-parse HEAD)
[ "$commit" = "$EXPECTED_COMMIT" ] || fail "Commit $commit diverso da quello collaudato ($EXPECTED_COMMIT): nessun aggiornamento automatico."
mkdir -p "$LOGDIR"
say HOST "$(uname -srmp)"
say COMMIT "$commit"
say PERCORSI "SOURCE=$SRC | BUILD=$BUILD | LOGS=$LOGDIR"
printf '[ARCHIVIO] GTA6_PS5 non viene letto ne modificato.\n'

# Le modifiche sperimentali create nella fase 1 devono essere preservate.
# Rileva la patch di link dinamico FreeBSD senza applicarla al checkout.
if grep -Fq 'elseif(NOT APPLE AND NOT CMAKE_SYSTEM_NAME STREQUAL "FreeBSD")' "$SRC/CMakeLists.txt"; then
    printf '[PATCH] Correzione di link dinamico FreeBSD gia presente.\n'
else
    fail 'Patch link FreeBSD non trovata. Riesegui fase 1 v1.2 sullo stesso checkout prima di procedere.'
fi

submodules_report() {
    git -C "$SRC" submodule status --recursive 2>&1
}
# QuickJS-NG contiene il submodule test262 usato per test di conformita JS.
# Se il suo .gitmodules imposta update=none, Git NON lo inizializza per scelta.
# Escludiamo ESCLUSIVAMENTE la riga '- ... 3rdparty/quickjs/test262'
# dal controllo delle dipendenze runtime; altri submodule assenti (+, -, U)
# continuano ad essere errori. Non modifica configurazioni Git o sorgenti.
quickjs_test262_optional() {
    [ -f "$SRC/3rdparty/quickjs/.gitmodules" ] || return 1
    policy=$(git -C "$SRC/3rdparty/quickjs" config -f .gitmodules --get submodule.test262.update 2>/dev/null || true)
    [ "$policy" = none ]
}
optional_skipped() {
    if quickjs_test262_optional; then
        submodules_report | awk 'substr($0,1,1)=="-" && $2=="3rdparty/quickjs/test262" {print}'
    fi
}
missing_submodules() {
    if quickjs_test262_optional; then
        submodules_report | awk '
            substr($0,1,1) ~ /^[-+U]$/ && !(substr($0,1,1)=="-" && $2=="3rdparty/quickjs/test262") {print}
        '
    else
        submodules_report | awk '/^[-+U]/ {print}'
    fi
}
announce_optional() {
    optional=$(optional_skipped)
    if [ -n "$optional" ]; then
        printf '[SUBMODULE OPZIONALE] QuickJS test262 omesso (update=none): non blocca il runtime.\n'
        printf '[SUBMODULE OPZIONALE] %s\n' "$optional"
    fi
}
show_failure() {
    logfile=$1
    printf '\n[DIAGNOSI] Prime righe con errori individuate:\n' >&2
    grep -Ein 'CMake Error|fatal error:|(^|[[:space:]])error:|FAILED:|Unsupported target platform|No such file' "$logfile" | head -n 35 >&2 || true
    printf '\n[DIAGNOSI] Ultime 55 righe:\n' >&2
    tail -n 55 "$logfile" >&2 || true
    printf '[LOG] %s\n' "$logfile" >&2
}
run_audit() {
    report="$LOGDIR/audit.txt"
    {
        echo '# AnyPS5 / FreeBSD — Fase 3 — preflight'
        date -u '+Data UTC: %Y-%m-%dT%H:%M:%SZ'
        uname -a
        echo "Commit: $commit"
        echo "Source: $SRC"
        echo "Relinker build: $RELINKER_BUILD"
        echo "Runtime build: $BUILD"
        echo
        echo '## Spazio del filesystem di lavoro'
        df -h "$WORKROOT"
        echo
        echo '## Stato checkout (non aggiornato)'
        git -C "$SRC" status --short
        echo
        echo '## Toolchain (se presente)'
        for tool in cmake ninja clang clang++ cc c++ python3 pkg-config pkgconf git; do
            if command -v "$tool" >/dev/null 2>&1; then
                printf '%-12s %s\n' "$tool" "$(command -v "$tool")"
            else
                printf '%-12s %s\n' "$tool" ASSENTE
            fi
        done
        echo
        echo '## Submodule obbligatori incompleti o non inizializzati (-, +, U)'
        missing_submodules || true
        echo
        echo '## Submodule opzionali saltati per update=none'
        optional_skipped || true
        echo
        echo '## Stato submodule, primi 60 record'
        submodules_report | head -n 60 || true
        echo
        echo '## Pacchetti FreeBSD disponibili (lettura sola)'
        if command -v pkg >/dev/null 2>&1; then
            pkg info 2>/dev/null | grep -Ei 'sdl2|vulkan|glslang|spirv|freetype|ffmpeg|cmake|ninja|libusb|wayland|xorg|libXrandr' || true
        fi
        echo
        echo '## Relinker Fase 1'
        if [ -x "$RELINKER_BUILD/core/relinker/relinker" ]; then
            file "$RELINKER_BUILD/core/relinker/relinker"
        else
            echo 'Non trovato'
        fi
        echo
        echo '## Nota'
        echo 'La suite da 1036 test della fase 2 e della build relinker-only;'
        echo 'non e una validazione del runtime PS5 o di GTA VI.'
    } >"$report" 2>&1
    say AUDIT "Report: $report"
    announce_optional
    printf '[SUBMODULE] Record non pronti: '
    missing_submodules | wc -l | tr -d ' '
    printf '[DISCO] '; df -h "$WORKROOT" | tail -n 1
    printf '[PROSSIMO] Se mancano i submodule: %s fetch\n' "$0"
}
run_fetch() {
    command -v git >/dev/null 2>&1 || fail 'git assente'
    logfile="$LOGDIR/submodules.log"
    say FETCH 'Inizializzo SOLO i submodule previsti dal commit corrente; nessun git pull.'
    printf '[AVVISO] Questa operazione usa la rete e puo scaricare molti GB.\n'
    printf '[LOG] %s\n' "$logfile"
    if ! GIT_TERMINAL_PROMPT=0 git -C "$SRC" submodule update --init --recursive --jobs "$JOBS" >"$logfile" 2>&1; then
        show_failure "$logfile"
        fail 'Fetch submodule incompleto: puoi rieseguire fetch per riprenderlo.'
    fi
    announce_optional
    if [ -n "$(missing_submodules)" ]; then
        missing_submodules
        fail 'Non tutti i submodule risultano al commit atteso.'
    fi
    say FETCH 'Submodule inizializzati. Ora esegui configure.'
}
# La build bundled libusb-cmake non ha un backend FreeBSD (Unsupported target platform).
# FreeBSD fornisce gia la libreria 1.0 compatibile nel sistema di base; il target
# INTERFACE mantiene il nome usb-1.0 atteso da AnyPS5, propagando include e link.
# Non tentiamo di compilare backend Linux/NetBSD su FreeBSD.
patch_freebsd_system_libusb() {
    command -v python3 >/dev/null 2>&1 || fail 'python3 richiesto per patch atomica CMake.'
    cmake_main="$SRC/CMakeLists.txt"
    [ -f "$cmake_main" ] || fail "CMake principale non trovato: $cmake_main"
    backup="$LOGDIR/CMakeLists.before-system-libusb.cmake"
    patchlog="$LOGDIR/freebsd-system-libusb.patch"
    if ! python3 - "$cmake_main" "$backup" "$patchlog" <<'PYLIBUSB'
import difflib
import os
import pathlib
import sys
import tempfile

path, backup, patchlog = [pathlib.Path(a) for a in sys.argv[1:]]
old = path.read_bytes()
anchor = (b'add_subdirectory(3rdparty/libusb-cmake EXCLUDE_FROM_ALL)\n'
          b'set_target_properties(usb-1.0 PROPERTIES POSITION_INDEPENDENT_CODE ON)')
marker = b'# AnyPS5 FreeBSD system-libusb adapter v1.2'
replacement = b'''# AnyPS5 FreeBSD system-libusb adapter v1.2
if(CMAKE_SYSTEM_NAME STREQUAL "FreeBSD")
    # FreeBSD base libusb implements the libusb 1.0 compatible API.
    # Fail at configure time if its development headers/library are absent.
    find_path(ANYPS5_FREEBSD_LIBUSB_INCLUDE_DIR NAMES libusb.h
        PATHS /usr/include /usr/local/include
        PATH_SUFFIXES libusb-1.0)
    find_library(ANYPS5_FREEBSD_LIBUSB_LIBRARY NAMES usb usb-1.0 libusb
        PATHS /usr/lib /usr/local/lib)
    if(NOT ANYPS5_FREEBSD_LIBUSB_INCLUDE_DIR OR NOT ANYPS5_FREEBSD_LIBUSB_LIBRARY)
        message(FATAL_ERROR "FreeBSD libusb not found (header libusb.h and library libusb). Check FreeBSD base headers and libraries.")
    endif()
    add_library(usb-1.0 INTERFACE)
    add_library(libusb::usb-1.0 ALIAS usb-1.0)
    target_include_directories(usb-1.0 INTERFACE "${ANYPS5_FREEBSD_LIBUSB_INCLUDE_DIR}")
    target_link_libraries(usb-1.0 INTERFACE "${ANYPS5_FREEBSD_LIBUSB_LIBRARY}")
    message(STATUS "AnyPS5 FreeBSD: using system libusb: ${ANYPS5_FREEBSD_LIBUSB_LIBRARY}")
else()
    add_subdirectory(3rdparty/libusb-cmake EXCLUDE_FROM_ALL)
    set_target_properties(usb-1.0 PROPERTIES POSITION_INDEPENDENT_CODE ON)
endif()'''
if marker in old:
    if replacement not in old:
        sys.exit('ERROR: FreeBSD libusb marker found, but the patch differs; review manually')
    print('[PATCH] FreeBSD libusb gia configurata (idempotente).')
    sys.exit(0)
if old.count(anchor) != 1:
    sys.exit('ERROR: expected libusb CMake anchor not found exactly once. No file changed.')
new = old.replace(anchor, replacement, 1)
backup.parent.mkdir(parents=True, exist_ok=True)
if backup.exists():
    # On repeated invocations never overwrite the original, and reject divergence.
    if backup.read_bytes() != old:
        sys.exit('ERROR: existing pre-patch backup differs from current source; no file changed.')
else:
    # Exclusive create, keeping the exact previous CMake bytes.
    with backup.open('xb') as f:
        f.write(old)
textdiff = ''.join(difflib.unified_diff(old.decode().splitlines(True),
    new.decode().splitlines(True), fromfile='CMakeLists.txt.before',
    tofile='CMakeLists.txt.FreeBSD'))
patchlog.write_text(textdiff)
fd, temp = tempfile.mkstemp(prefix='.CMakeLists.anyps5-', dir=path.parent)
try:
    with os.fdopen(fd, 'wb') as f:
        f.write(new)
        f.flush()
        os.fsync(f.fileno())
    os.chmod(temp, path.stat().st_mode & 0o777)
    os.replace(temp, path)
finally:
    if os.path.exists(temp):
        os.unlink(temp)
print('[PATCH] CMake principale adattato a FreeBSD base libusb; submodule intatti.')
print('[BACKUP]', backup)
print('[DIFF]', patchlog)
PYLIBUSB
    then
        fail 'Patch libusb non applicata. File sorgente non modificato oppure errore da esaminare.'
    fi
}
# v1.3: le correzioni FreeBSD ai sorgenti sono una SERIE DI PATCH git in $PATCHDIR (NNNN-nome.patch,
# percorsi relativi al checkout), applicate in ordine. Una patch gia applicata si riconosce con
# `git apply --reverse --check` e si salta; una che non si applica ne all'avanti ne all'indietro ferma
# tutto senza toccare nulla. Il checkout resta sul commit collaudato (nessun commit, solo il working tree).
# Ripristino: git -C "$SRC" apply -R <patch>, in ordine inverso.
apply_freebsd_patch_series() {
    [ -d "$PATCHDIR" ] || fail "Cartella delle patch FreeBSD assente: $PATCHDIR"
    applied_log="$LOGDIR/freebsd-patch-series.log"
    for patch in "$PATCHDIR"/[0-9][0-9][0-9][0-9]-*.patch; do
        [ -f "$patch" ] || continue
        name=$(basename "$patch")
        if git -C "$SRC" apply --reverse --check "$patch" >/dev/null 2>&1; then
            printf '[PATCH] %s gia applicata.\n' "$name"
        elif git -C "$SRC" apply --check "$patch" >"$LOGDIR/check-$name.log" 2>&1; then
            git -C "$SRC" apply "$patch" || fail "Applicazione di $name fallita dopo il controllo."
            printf '%s %s applicata\n' "$(date '+%F %T')" "$name" >>"$applied_log"
            printf '[PATCH] %s applicata.\n' "$name"
        else
            cat "$LOGDIR/check-$name.log" >&2
            fail "La patch $name non si applica al checkout (ne gia applicata): nessun file cambiato da questa patch."
        fi
    done
}
# v1.3: FFmpeg. Il CMake scarica un pacchetto precompilato e su ogni Unix non Apple prende quello Linux: librerie
# statiche glibc (riferimenti a __errno_location, __isoc99_sscanf, __*_chk, open64...) inutilizzabili su FreeBSD.
# Si costruisce lo stesso FFmpeg per FreeBSD: il sorgente esatto della build Linux (release KytyPS5/ext-ffmpeg-core
# 9ac4cfd195f1, FFmpeg n7.1.1 con le patch vcpkg, sha256 verificato) configurato con la SUA riga FFMPEG_CONFIGURATION,
# tolte solo le opzioni di piattaforma; poi il CMake lo usa tramite FFMPEG_PREBUILT_DIR.
FFMPEG_SRC_URL=https://github.com/KytyPS5/ext-ffmpeg-core/releases/download/9ac4cfd195f1/ffmpeg-source-linux-x64.tar.gz
FFMPEG_SRC_SHA256=6faecaa6aafb7f29af2ba50ec3b320ded1f6dd4ec4b1b2209da747c808389aaf
FFMPEG_DIR="$WORKROOT/externals-freebsd/ffmpeg-9ac4cfd195f1-freebsd-x64"
FFMPEG_WORK="$WORKROOT/ffmpeg-freebsd-build"
build_freebsd_ffmpeg() {
    if [ -f "$FFMPEG_DIR/lib/libavcodec.a" ] && [ -f "$FFMPEG_DIR/share/ffmpeg/SOURCE.txt" ]; then
        printf '[FFMPEG] FreeBSD gia costruito: %s\n' "$FFMPEG_DIR"
        return 0
    fi
    for tool in fetch sha256 gmake nasm pkgconf cc; do command -v "$tool" >/dev/null 2>&1 || fail "Comando mancante per FFmpeg: $tool"; done
    mkdir -p "$FFMPEG_WORK"
    tarball="$FFMPEG_WORK/ffmpeg-source-linux-x64.tar.gz"
    [ -f "$tarball" ] || fetch -q -o "$tarball" "$FFMPEG_SRC_URL" || fail "Download del sorgente FFmpeg fallito: $FFMPEG_SRC_URL"
    [ "$(sha256 -q "$tarball")" = "$FFMPEG_SRC_SHA256" ] || fail "sha256 del sorgente FFmpeg diverso da quello atteso ($FFMPEG_SRC_SHA256)"
    [ -d "$FFMPEG_WORK/ffmpeg" ] || tar -xzf "$tarball" -C "$FFMPEG_WORK" || fail 'Estrazione del sorgente FFmpeg fallita'
    original="$FFMPEG_WORK/configuration/x64-linux-release-rel"
    [ -f "$original/config.h" ] || fail "Configurazione Linux originale assente nel pacchetto: $original/config.h"
    options=$(grep -m1 'FFMPEG_CONFIGURATION' "$original/config.h" | sed -E 's/^#define FFMPEG_CONFIGURATION "(.*)"$/\1/' |
        tr ' ' '\n' | grep -v -E '^--(prefix|target-os|enable-cross-compile|pkg-config|extra-ldflags)=?' | tr '\n' ' ')
    mkdir -p "$FFMPEG_WORK/build"
    say FFMPEG "configure (opzioni della build Linux, senza quelle di piattaforma)"
    # shellcheck disable=SC2086
    (cd "$FFMPEG_WORK/build" && sh ../ffmpeg/configure --prefix="$FFMPEG_DIR" --pkg-config="$(command -v pkgconf)" $options) \
        >"$LOGDIR/ffmpeg-configure.log" 2>&1 || { tail -20 "$LOGDIR/ffmpeg-configure.log" >&2; fail 'configure di FFmpeg fallito'; }
    pattern='^#define CONFIG_[A-Z0-9_]+_(DECODER|ENCODER|DEMUXER|MUXER|PARSER|PROTOCOL|BSF) 1'
    grep -E "$pattern" "$original/config_components.h" | sort >"$LOGDIR/ffmpeg-components-linux.txt"
    grep -E "$pattern" "$FFMPEG_WORK/build/config_components.h" | sort >"$LOGDIR/ffmpeg-components-freebsd.txt"
    cmp -s "$LOGDIR/ffmpeg-components-linux.txt" "$LOGDIR/ffmpeg-components-freebsd.txt" ||
        fail "Componenti FFmpeg diversi dalla build Linux: diff $LOGDIR/ffmpeg-components-linux.txt $LOGDIR/ffmpeg-components-freebsd.txt"
    say FFMPEG "compilazione, job=$JOBS ($(wc -l <"$LOGDIR/ffmpeg-components-freebsd.txt" | tr -d ' ') componenti come Linux)"
    (cd "$FFMPEG_WORK/build" && gmake -j"$JOBS" && gmake install) >"$LOGDIR/ffmpeg-build.log" 2>&1 ||
        { tail -20 "$LOGDIR/ffmpeg-build.log" >&2; fail 'compilazione di FFmpeg fallita'; }
    glibc=$(nm "$FFMPEG_DIR"/lib/*.a 2>/dev/null | awk '$1 == "U" {print $2}' |
        grep -c -E '^(__errno_location|__isoc|__[a-z]*_chk$|stat64|fstat64|lseek64|open64|mmap64)' || true)
    [ "$glibc" = 0 ] || fail "FFmpeg costruito fa ancora riferimento a $glibc simboli glibc"
    mkdir -p "$FFMPEG_DIR/share/ffmpeg"
    cp "$FFMPEG_WORK/build-info/copyright" "$FFMPEG_DIR/share/ffmpeg/copyright"
    printf 'FFmpeg per AnyPS5 su FreeBSD (stage3 v1.3, %s).\nSorgente: %s\n  sha256 %s\nRicetta: FFMPEG_CONFIGURATION della build Linux senza --target-os/--enable-cross-compile/--pkg-config/--extra-ldflags.\nCompilatore: %s\n' \
        "$(date '+%F')" "$FFMPEG_SRC_URL" "$FFMPEG_SRC_SHA256" "$(cc --version | head -1)" >"$FFMPEG_DIR/share/ffmpeg/SOURCE.txt"
    say FFMPEG "installato: $FFMPEG_DIR"
}
run_configure() {
    patch_freebsd_system_libusb
    apply_freebsd_patch_series
    build_freebsd_ffmpeg
    for tool in cmake ninja clang clang++ git; do
        command -v "$tool" >/dev/null 2>&1 || fail "Comando mancante: $tool"
    done
    announce_optional
    missing=$(missing_submodules)
    if [ -n "$missing" ]; then
        printf '%s\n' "$missing" | head -n 25 >&2
        fail 'Submodule mancanti/non allineati. Esegui fetch prima di configure.'
    fi
    logfile="$LOGDIR/configure-runtime.log"
    say CMAKE 'Configurazione runtime separata; FreeBSD usa libusb di sistema, senza test; relinker intatto.'
    if ! cmake -S "$SRC" -B "$BUILD" -G Ninja \
        -DCMAKE_BUILD_TYPE=Release \
        -DCMAKE_C_COMPILER=clang \
        -DCMAKE_CXX_COMPILER=clang++ \
        -DCMAKE_PREFIX_PATH=/usr/local \
        -DCMAKE_EXPORT_COMPILE_COMMANDS=ON \
        -DANYPS5_RELINKER_ONLY=OFF \
        -DANYPS5_USE_SYSTEM_DEPS=OFF \
        -DANYPS5_ENABLE_SPIRV_TOOLS=OFF \
        -DFFMPEG_PREBUILT_DIR="$FFMPEG_DIR" \
        -DBUILD_TESTING=OFF >"$logfile" 2>&1; then
        show_failure "$logfile"
        fail 'La configurazione si e fermata: serve correggere il primo blocker del CMake.'
    fi
    say CMAKE "Configurazione riuscita: $BUILD"
    printf '[PROSSIMO] %s build\n' "$0"
}
run_targets() {
    [ -f "$BUILD/build.ninja" ] || fail 'Runtime non configurato. Esegui configure.'
    logfile="$LOGDIR/targets.txt"
    if ! cmake --build "$BUILD" --target help >"$logfile" 2>&1; then
        show_failure "$logfile"
        fail 'Impossibile elencare i target.'
    fi
    say TARGETS "$logfile"
    grep -E '(^|[/: ])(nid_patcher|libc|libkernel)([: .]|$)' "$logfile" | head -n 25 || true
}
run_build() {
    command -v cmake >/dev/null 2>&1 || fail 'cmake assente'
    [ -f "$BUILD/build.ninja" ] || fail 'Runtime non configurato. Esegui configure.'
    apply_freebsd_patch_series
    # Sequenza intenzionalmente limitata per ottenere un primo blocker nel runtime.
    # Non tentare di compilare l'intero albero finche libc/libkernel non funzionano.
    targets=${BUILD_TARGETS:-nid_patcher libc libkernel libs}
    for target in $targets; do
        case "$target" in *[!a-zA-Z0-9_+.-]*|'') fail "Nome target non valido: $target" ;; esac
        logfile="$LOGDIR/build-$target.log"
        say BUILD "Target=$target, job=$JOBS"
        if ! cmake --build "$BUILD" --target "$target" --parallel "$JOBS" >"$logfile" 2>&1; then
            show_failure "$logfile"
            fail "Target $target fallito. Le patch FreeBSD note sono gia applicate: questo e un blocker nuovo."
        fi
        printf '[PASS] %s\n' "$target"
    done
    say BUILD 'I target richiesti hanno compilato; non implica che il runtime completo possa eseguire titoli PS5.'
    printf '[LOGS] %s\n' "$LOGDIR"
}

case "$MODE" in
    audit) run_audit ;;
    fetch) run_fetch ;;
    patch) patch_freebsd_system_libusb; apply_freebsd_patch_series ;;
    ffmpeg) build_freebsd_ffmpeg ;;
    configure) run_configure ;;
    targets) run_targets ;;
    build) run_build ;;
esac
