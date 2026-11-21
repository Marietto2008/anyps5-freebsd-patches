#!/bin/sh
# AnyPS5 FreeBSD Stage 1 v1.2: relinker nativo, diagnostica, test minimi.
# I PKG sono solo conteggiati; nessun dato del gioco viene alterato.
set -eu

# Per default le directory sono relative alla posizione dello script,
# indipendentemente dalla directory da cui viene lanciato.
SCRIPT_DIR=$(CDPATH= cd -P "$(dirname "$0")" && pwd)
BASE_DIR=${BASE_DIR:-$SCRIPT_DIR}
ARCHIVE=${ARCHIVE:-${BASE_DIR}/GTA6_PS5}
WORKROOT=${WORKROOT:-${BASE_DIR}/AnyPS5-work}
JOBS=${JOBS:-4}
BUILD_ALL_TESTS=${BUILD_ALL_TESTS:-0}
REPO=https://github.com/boykopovar/AnyPS5.git
SRC="$WORKROOT/source"
BUILD="$WORKROOT/build-relinker"
LOGS="$WORKROOT/logs"

say() { printf '\n[%s] %s\n' "$1" "$2"; }
fail() { printf '[ERRORE] %s\n' "$1" >&2; exit 1; }

[ "$(uname -s)" = FreeBSD ] || fail 'Questo script e\047 destinato a FreeBSD.'
case "$JOBS" in ''|*[!0-9]*) fail 'JOBS deve essere un intero positivo.' ;; esac
[ "$JOBS" -gt 0 ] || fail 'JOBS deve essere > 0.'
case "$BUILD_ALL_TESTS" in 0|1) : ;; *) fail 'BUILD_ALL_TESTS deve essere 0 oppure 1.' ;; esac

say HOST "$(uname -srmp)"
sysctl -n hw.model 2>/dev/null || true
say PERCORSI "BASE_DIR=$BASE_DIR | ARCHIVE=$ARCHIVE | WORKROOT=$WORKROOT"

if [ "$(id -u)" -eq 0 ]; then
    printf '[AVVISO] Eseguire preferibilmente come utente normale.\n' >&2
fi

if [ -d "$ARCHIVE" ]; then
    count=$(find "$ARCHIVE" -type f -name '*.pkg' -print | wc -l | tr -d ' ')
    say ARCHIVIO "Trovati $count PKG (non verranno modificati)."
    if [ -f "$ARCHIVE/manifest.json" ]; then
        printf 'Manifest locale SHA-256: '
        sha256 -q "$ARCHIVE/manifest.json"
    fi
else
    printf '[AVVISO] PKG non presenti in %s; il relinker si puo\047 comunque compilare.\n' "$ARCHIVE"
fi

missing=''
for prog in git cmake ninja clang++ ctest python3; do
    command -v "$prog" >/dev/null 2>&1 || missing="$missing $prog"
done
[ -z "$missing" ] || fail "Comandi mancanti:$missing (pkg install git cmake ninja python3)"

mkdir -p "$LOGS"
if [ -d "$SRC/.git" ]; then
    origin=$(git -C "$SRC" remote get-url origin)
    case "$origin" in
        "$REPO"|https://github.com/boykopovar/AnyPS5) : ;;
        *) fail "Checkout con origin differente: $origin" ;;
    esac
    say GIT 'Riutilizzo il checkout locale senza aggiornarlo.'
else
    [ ! -e "$SRC" ] || fail "Percorso esistente non Git: $SRC"
    say GIT "Clono $REPO"
    if ! git clone --depth 1 --single-branch --branch main "$REPO" "$SRC" >"$LOGS/clone.log" 2>&1; then
        tail -n 50 "$LOGS/clone.log" >&2
        fail "Clone fallito: $LOGS/clone.log"
    fi
fi
printf 'Commit: '; git -C "$SRC" rev-parse HEAD

# La versione esaminata di AnyPS5 forza -static globalmente su tutti
# i sistemi non-Apple. Su FreeBSD i test con std::thread/pthread_create
# possono fallire al link. Evitiamo -static SOLO sul FreeBSD, senza
# modificare la logica su Linux/Windows/macOS.
# Inoltre colleghiamo esplicitamente pthread al test pad_command_file.
say PATCH 'Adattamento CMake locale per FreeBSD (link dinamico e Threads).'
if ! python3 - "$SRC/CMakeLists.txt" <<'PY'
import pathlib, sys
p = pathlib.Path(sys.argv[1])
s = p.read_text()
old = '''elseif(NOT APPLE)
    set(CMAKE_EXE_LINKER_FLAGS "${CMAKE_EXE_LINKER_FLAGS} -static -static-libgcc -static-libstdc++")'''
new = '''elseif(NOT APPLE AND NOT CMAKE_SYSTEM_NAME STREQUAL "FreeBSD")
    set(CMAKE_EXE_LINKER_FLAGS "${CMAKE_EXE_LINKER_FLAGS} -static -static-libgcc -static-libstdc++")'''
if old in s:
    if s.count(old) != 1:
        raise SystemExit('Più sezioni di link statico trovate: patch non applicata')
    s = s.replace(old, new, 1)
elif new not in s:
    raise SystemExit('CMakeLists.txt cambiato: sezione di link statico non riconosciuta')

old_test = '''    add_test_executable(pad_command_file_tests core/libs/prx/libScePad/tests/InputCommandFile.cpp)
    target_include_directories(pad_command_file_tests PRIVATE core/libs)'''
new_test = '''    add_test_executable(pad_command_file_tests core/libs/prx/libScePad/tests/InputCommandFile.cpp)
    if(CMAKE_SYSTEM_NAME STREQUAL "FreeBSD")
        find_package(Threads REQUIRED)
        target_link_libraries(pad_command_file_tests PRIVATE Threads::Threads)
    endif()
    target_include_directories(pad_command_file_tests PRIVATE core/libs)'''
if old_test in s:
    if s.count(old_test) != 1:
        raise SystemExit('Più target pad_command_file_tests: patch non applicata')
    s = s.replace(old_test, new_test, 1)
elif new_test not in s:
    raise SystemExit('Target pad_command_file_tests cambiato: patch non applicata')
p.write_text(s)
print('Patch CMake presente (idempotente).')
PY
then
    fail 'Patch FreeBSD CMake non applicata. Non sovrascrivo file inattesi.'
fi
git -C "$SRC" diff -- CMakeLists.txt >"$LOGS/freebsd-cmake.patch"

say CMAKE 'Configurazione relinker-only con Clang e test registrati.'
if ! cmake -S "$SRC" -B "$BUILD" -G Ninja \
    -DCMAKE_BUILD_TYPE=Release \
    -DCMAKE_C_COMPILER=clang \
    -DCMAKE_CXX_COMPILER=clang++ \
    -DANYPS5_RELINKER_ONLY=ON \
    -DBUILD_TESTING=ON \
    >"$LOGS/configure.log" 2>&1; then
    tail -n 90 "$LOGS/configure.log" >&2
    fail "Configurazione fallita: $LOGS/configure.log"
fi

# Per evitare il rebuild di tutti i test (355 target nella prova precedente)
# compiliamo prima l'obiettivo che realmente interessa: relinker.
say BUILD "Compilo il solo target relinker, $JOBS job."
if ! cmake --build "$BUILD" --target relinker --parallel "$JOBS" >"$LOGS/build-relinker.log" 2>&1; then
    tail -n 90 "$LOGS/build-relinker.log" >&2
    fail "Relinker non compilato: $LOGS/build-relinker.log"
fi
RELINKER="$BUILD/core/relinker/relinker"
[ -x "$RELINKER" ] || fail "Target compilato ma eseguibile non trovato: $RELINKER"
say OUTPUT "$RELINKER"
file "$RELINKER" || true

say TEST 'Smoke test: input_magic, input_preservation, elf_header, input_file.'
if ctest --test-dir "$BUILD" --output-on-failure \
    -R '^(input_magic|input_preservation|elf_header|input_file)$' \
    >"$LOGS/ctest-smoke.log" 2>&1; then
    cat "$LOGS/ctest-smoke.log"
else
    cat "$LOGS/ctest-smoke.log" >&2
    printf '[AVVISO] Uno o piu\047 smoke test non sono passati: %s\n' "$LOGS/ctest-smoke.log" >&2
fi

# Opt-in: compila tutti i target dei test (utile per il porting sistematico).
if [ "$BUILD_ALL_TESTS" -eq 1 ]; then
    say BUILD 'BUILD_ALL_TESTS=1: build completa dei test (potrebbero emergere altri problemi FreeBSD).'
    if ! cmake --build "$BUILD" --parallel "$JOBS" >"$LOGS/build-all.log" 2>&1; then
        tail -n 90 "$LOGS/build-all.log" >&2
        fail "Build dei test fallita: $LOGS/build-all.log"
    fi
    say TEST 'Esecuzione test pad_command_file dopo link con Threads::Threads.'
    if ctest --test-dir "$BUILD" --output-on-failure -R '^pad_command_file$' \
        >"$LOGS/ctest-pad.log" 2>&1; then
        cat "$LOGS/ctest-pad.log"
    else
        cat "$LOGS/ctest-pad.log" >&2
        fail "Test pad_command_file fallito: $LOGS/ctest-pad.log"
    fi
fi

say FINE 'Prima fase terminata: relinker nativo compilato, non e\047 un runtime PS5.'
printf 'File di log: %s\n' "$LOGS"
printf 'Diff FreeBSD: %s\n' "$LOGS/freebsd-cmake.patch"
