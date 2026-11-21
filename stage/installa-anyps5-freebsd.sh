#!/bin/sh
# installa-anyps5-freebsd.sh - installa AnyPS5 su FreeBSD 16 amd64 da zero: pacchetti, sorgenti al commit
# collaudato, serie di patch FreeBSD, FFmpeg, runtime (413 librerie PS5) e relinker con l'uscita --freebsd.
#
# Uso:  sh installa-anyps5-freebsd.sh [--senza-pacchetti] [--con-test]
#   BASE_DIR=<cartella di lavoro>   default: la cartella corrente. Vi finiscono gli script di stage,
#                                   anyps5_freebsd_patches/ e AnyPS5-work/ (sorgenti e build).
#   JOBS=<n>                        default: il numero di CPU.
#   --senza-pacchetti               non installa nulla con pkg (pacchetti gia' presenti).
#   --con-test                      dopo il relinker esegue anche lo stage 2 (test e audit), lento.
#
# Va eseguito come utente normale: per pkg usa sudo, se c'e', altrimenti chiede di installare a mano.
# Non estrae ne' decifra pacchetti PS5: il relinker converte ELF gia' estratti e decifrati.
set -eu

REPO_ANYPS5=https://github.com/boykopovar/AnyPS5.git
COMMIT=9c16c9b09e5be534780503689411404e68f670be
REPO_PATCH=https://github.com/Marietto2008/anyps5-freebsd-patches.git
BASE_DIR=${BASE_DIR:-$(pwd)}
JOBS=${JOBS:-$(sysctl -n hw.ncpu)}
SPAZIO_GB=60	# stima: sorgenti con i submodule, FFmpeg, build del runtime e del relinker

# Pacchetti: strumenti di build, poi le librerie che il CMake di AnyPS5 (SDL inclusa) trova sull'host di
# riferimento, poi quelle che servono a tempo d'esecuzione (Vulkan, X).
PACCHETTI="git cmake-core ninja pkgconf python3 llvm19 gmake nasm
	libX11 libXext libXcursor libXi libXrandr libXfixes libXrender libXScrnSaver libxkbcommon
	wayland libdecor libdrm libglvnd mesa-libs dbus libunwind libsamplerate
	alsa-lib pulseaudio jackit sndio pipewire nas
	vulkan-loader"

CON_PACCHETTI=1
CON_TEST=0
for a in "$@"; do
	case "$a" in
	--senza-pacchetti) CON_PACCHETTI=0 ;;
	--con-test) CON_TEST=1 ;;
	-h|--help) sed -n '2,13p' "$0"; exit 0 ;;
	*) echo "argomento sconosciuto: $a (vedi --help)" >&2; exit 2 ;;
	esac
done

passo() { printf '\n==== %s\n' "$1"; }
fail() { printf '[ERRORE] %s\n' "$1" >&2; exit 1; }

# ---- controlli ----
passo "Controlli"
[ "$(uname -s)" = FreeBSD ] || fail "serve FreeBSD"
[ "$(uname -m)" = amd64 ] || fail "serve amd64 (uname -m: $(uname -m))"
case "$(uname -r)" in 16.*) ;; *) fail "serve FreeBSD 16 (uname -r: $(uname -r)): AnyPS5 e' collaudato su 16.0-CURRENT" ;; esac
[ "$(id -u)" -ne 0 ] || fail "eseguilo come utente normale, non come root"
case "$JOBS" in ''|*[!0-9]*|0) fail "JOBS deve essere un intero positivo" ;; esac
mkdir -p "$BASE_DIR"
BASE_DIR=$(CDPATH= cd -P "$BASE_DIR" && pwd)
libero=$(df -k "$BASE_DIR" | awk 'NR==2 {print int($4/1048576)}')
[ "$libero" -ge "$SPAZIO_GB" ] || fail "spazio libero in $BASE_DIR: ${libero} GB, ne servono circa $SPAZIO_GB"
echo "BASE_DIR=$BASE_DIR  JOBS=$JOBS  spazio libero ${libero} GB"

# kern.proc.vmmap conta le pagine residenti di ogni mappatura a ogni chiamata: AnyPS5 la legge a ogni controllo
# di accesso alla memoria guest, e senza questa sysctl i titoli e i test grafici rallentano molto.
if [ "$(sysctl -n kern.proc_vmmap_skip_resident_count 2>/dev/null || echo 0)" != 1 ]; then
	echo "[AVVISO] kern.proc_vmmap_skip_resident_count non e' 1. Consigliato (cambia solo la colonna RES di procstat -v):"
	echo "         sysctl kern.proc_vmmap_skip_resident_count=1   e la stessa riga in /etc/sysctl.conf"
fi

# ---- pacchetti ----
if [ "$CON_PACCHETTI" -eq 1 ]; then
	passo "Pacchetti"
	# pkg install salta da solo i pacchetti gia' presenti (da utente pkg non puo' interrogare il database)
	if command -v sudo >/dev/null 2>&1; then
		sudo pkg install -y $PACCHETTI
	else
		fail "manca sudo: installa da root  pkg install $(echo $PACCHETTI)  e rilancia con --senza-pacchetti"
	fi
fi
for c in git cmake ninja pkgconf python3 clang clang++ gmake nasm; do
	command -v "$c" >/dev/null 2>&1 || fail "comando mancante: $c"
done

# ---- serie di patch e script di stage ----
passo "Serie di patch FreeBSD"
cd "$BASE_DIR"
if [ -d anyps5_freebsd_patches/.git ]; then
	echo "anyps5_freebsd_patches/ c'e' gia': la uso cosi' com'e'"
else
	[ ! -e anyps5_freebsd_patches ] || fail "anyps5_freebsd_patches/ esiste ma non e' un clone git"
	git clone -q "$REPO_PATCH" anyps5_freebsd_patches
fi
for s in anyps5_freebsd_stage1_v1_2.sh anyps5_freebsd_stage2.sh anyps5_freebsd_stage3_v1_3.sh; do
	cp anyps5_freebsd_patches/stage/$s "$BASE_DIR/$s"
done

# ---- sorgenti AnyPS5 al commit collaudato ----
# Lo stage 1 clonerebbe l'ultimo main, che lo stage 3 rifiuta: il checkout si prepara qui al commit esatto
# (lo stage 1 riusa un checkout esistente).
passo "Sorgenti AnyPS5 ($COMMIT)"
SRC="$BASE_DIR/AnyPS5-work/source"
if [ -d "$SRC/.git" ]; then
	[ "$(git -C "$SRC" rev-parse HEAD)" = "$COMMIT" ] || fail "$SRC e' su un altro commit: spostalo o toglilo"
	echo "checkout gia' presente"
else
	[ ! -e "$SRC" ] || fail "$SRC esiste ma non e' un checkout git"
	mkdir -p "$SRC"
	git -C "$SRC" init -q
	git -C "$SRC" remote add origin "$REPO_ANYPS5"
	git -C "$SRC" fetch -q --depth 1 origin "$COMMIT"
	git -C "$SRC" checkout -q -b main FETCH_HEAD
fi

# ---- build ----
cd "$BASE_DIR"
passo "Stage 1: correzioni CMake e relinker"
JOBS=$JOBS sh ./anyps5_freebsd_stage1_v1_2.sh
passo "Stage 3: submodule (scaricamento grande)"
JOBS=$JOBS sh ./anyps5_freebsd_stage3_v1_3.sh fetch
passo "Stage 3: serie di patch"
JOBS=$JOBS sh ./anyps5_freebsd_stage3_v1_3.sh patch
# Lo stage 1 ha compilato il relinker prima delle patch: senza questa ricompilazione manca --freebsd.
passo "Relinker con le patch FreeBSD"
cmake --build "$BASE_DIR/AnyPS5-work/build-relinker" --target relinker --parallel "$JOBS"
RELINKER="$BASE_DIR/AnyPS5-work/build-relinker/core/relinker/relinker"
"$RELINKER" --help 2>&1 | grep -q -- --freebsd || fail "il relinker non ha l'opzione --freebsd: patch non applicate?"
if [ "$CON_TEST" -eq 1 ]; then
	passo "Stage 2: test e audit"
	JOBS=$JOBS sh ./anyps5_freebsd_stage2.sh both
fi
passo "Stage 3: FFmpeg e configurazione del runtime"
JOBS=$JOBS sh ./anyps5_freebsd_stage3_v1_3.sh configure
passo "Stage 3: compilazione del runtime"
JOBS=$JOBS sh ./anyps5_freebsd_stage3_v1_3.sh build
LIBS="$BASE_DIR/AnyPS5-work/build-runtime/core/libs/libs"
[ -f "$LIBS/libkernel.prx" ] || fail "librerie non trovate in $LIBS"

passo "Fatto"
cat <<FINE_ISTRUZIONI
Relinker:  $RELINKER
Librerie:  $LIBS  ($(ls "$LIBS"/*.prx | wc -l | tr -d ' ') .prx)

Per un titolo (ELF gia' estratto e decifrato; tools/unwrap_self.py sbusta eboot.bin e i .prx):
  "$RELINKER" --freebsd --to-intel --sce-module-path <cartella-con-sce_module> eboot.elf <uscita>/app.elf
  ln -s "$LIBS" <uscita>/libs        # piu' i file del titolo in <uscita>/app0/ (eboot.bin originale, sce_sys, ...)
  cd <uscita> && ./app.elf
--to-intel serve sulle CPU Intel (istruzioni SSE4a delle CPU AMD). Con una scheda NVIDIA usare il driver nativo
FreeBSD (pacchetto nvidia-driver con nvidia-kmod della STESSA versione) e lo schermo collegato a quella scheda.
FINE_ISTRUZIONI
