# Serie di patch FreeBSD per AnyPS5

Commit di riferimento: `9c16c9b09e5be534780503689411404e68f670be`, quello che lo stage verifica.

**Disposizione delle cartelle.** Gli script di stage stanno in `stage/`. Si copiano nella cartella di lavoro
(`BASE_DIR`, quella dello script), accanto a questo repository clonato col nome `anyps5_freebsd_patches`:

    BASE_DIR/
        anyps5_freebsd_stage1_v1_2.sh   relinker nativo e correzioni CMake della fase 1
        anyps5_freebsd_stage2.sh        suite di test e audit di portabilita'
        anyps5_freebsd_stage3_v1_3.sh   patch, FFmpeg, configure e build del runtime
        anyps5_freebsd_patches/         questo repository
        AnyPS5-work/                    creata dagli stage (checkout e build)

Ordine: stage 1 (relinker), stage 2 (test e audit della build del relinker, facoltativo), stage 3 (`patch`,
`configure`, `build`).

**Come si applica.** Le applica `anyps5_freebsd_stage3_v1_3.sh`, nelle modalita `patch`, `configure` e `build`, in
ordine numerico. Ogni patch e' un `git diff` con percorsi relativi al checkout `AnyPS5-work/source`.
- Una patch gia' applicata si riconosce con `git apply --reverse --check` e si salta.
- Una patch nuova si applica se passa `git apply --check`.
- Se una patch non passa nessuno dei due controlli, lo stage si ferma senza toccare nulla.

Nel checkout non si fa nessun commit: resta sul commit collaudato. La patch libusb del CMake resta a parte, in
Python dentro lo script, come dalla v1.2. Lo stesso vale per le correzioni CMake della fase 1.

**Ripristino:** `git -C AnyPS5-work/source apply -R NNNN-...patch`, dall'ultima alla prima.

**Verifica (21/11/2026):** la serie, applicata da zero a una copia pulita del commit (`git archive`), ricostruisce
identici tutti i 178 file modificati con la serie 0001-0024. Le patch superate sono in `superate-2026112*/`.

**Richiesta all'host:** `kern.proc_vmmap_skip_resident_count=1` (sysctl.conf). Su FreeBSD i controlli di accesso alla
memoria guest leggono `kern.proc.vmmap`, e senza la sysctl il kernel conta i residenti di ogni voce con una ricerca
per pagina da 4 KiB (il write watch impedisce le superpagine): ~5 ms a chiamata con 450 MB residenti. Con la sysctl
`agc_driver_graphics` passa da oltre 300 s a 49 s. Cambia solo la colonna RES di `procstat -v` (`kve_resident`).

| patch | contenuto |
|---|---|
| 0001-libc-libcxxrt-cxxabi | `CxxAbi.hpp`: il runtime C++ di FreeBSD e' libcxxrt. Il suo `<cxxabi.h>` include `<unwind.h>`, che si scontra con l'ABI di unwind del PS5; si dichiara solo il necessario, come gia' per libc++abi, Emscripten e Apple. |
| 0002-libc-freebsd-tm_zone | `libc/src/Time.cpp`: `char *tm_zone`, come su macOS. |
| 0003-freebsd-compat-headers | Nuovi `specifics/freebsd/Compat.hpp` e `HostMemory.hpp`, piu' `ElfTypes.hpp`. Compat: `gettid`, `dladdr1(RTLD_DL_LINKMAP)`, `pthread_getattr_np`, `CLOCK_MONOTONIC_RAW`. HostMemory: `kern.proc.vmmap`, `MapNoReplace` (`MAP_FIXED\|MAP_EXCL`, EINVAL tradotto in EEXIST). ElfTypes: FreeBSD usa il `<link.h>` vero. |
| 0004-libc-guest-memory | GuestArena via HostMemory; niente copia anonima dell'immagine (serve solo a userfaultfd, come su Apple); `gettid` in HeapDiagnostics. |
| 0005-libkernel-posix-basics | `alloca`, `statfs`/`MNT_NOEXEC`, `sem_clockwait_np`, `getdents`/`d_fileno`, `pthread_attr_get_np`, `pthread_main_np` (il tid del thread principale non e' il pid), `gettid`. inotify c'e' (FreeBSD 16). |
| 0006-libkernel-exceptions-and-faults | Registri ospite/host su `mcontext_t` FreeBSD; RFLAGS limitato a `PSL_USERCHANGE`. Riflessione dei fault ospite: `mc_trapno` (numeri `T_*` di FreeBSD) tradotto nei vettori x86, `mc_addr` (CR2), `mc_err`. |
| 0007-libkernel-direct-memory | Ramo Linux (`memfd_create`, sigilli); `/proc/self/maps` e `MAP_FIXED_NOREPLACE` via HostMemory. |
| 0008-libkernel-shared-memory | `shm_open`/`memfd`; riconoscimento con `F_KINFO` = `KF_TYPE_SHM` (`kf_path` e' vuoto per i memfd); `flock` sulla cartella temporanea; `shm_unlink` controlla i permessi con un `shm_open(O_RDWR)`. |
| 0009-libkernel-dynamic-loader | Include di Compat in DynamicLoader, ModuleInfo e Rtld. |
| 0010-libSceAgcDriver-freebsd | Driver GPU: `MapNoReplace`, udmabuf assente come su Apple, priorita' dei thread con `rtprio_thread(2)` (`rt`; `high` rifiutato perche' FreeBSD non ha un nice per thread), include di Compat. |
| 0011-webkit-libcxx-abi | `HexResult`: il libc++ di FreeBSD tiene `std::pair` non banalmente copiabile (`_LIBCPP_DEPRECATED_ABI_DISABLE_PAIR_TRIVIAL_COPY_CTOR`, attivo per `__FreeBSD__`), il che cambierebbe la convenzione di ritorno all'ospite: si usa una struct banale con lo stesso layout. `CacheControl`: traits Latin-1, perche' libc++ 19 ha tolto il `char_traits` generico. |
| 0012-libraries-portability | `<sys/socket.h>` in Http2; `MAP_NORESERVE` condizionato in Fiber; cast `int` della velocita' libusb in Usbd. |
| 0013-cmake-freebsd-link | CMake principale: `add_link_options(-pthread)`, perche' su FreeBSD i thread stanno in libthr; `--exclude-libs` per FFmpeg. In piu' 30 blocchi `--exclude-libs`, da «Linux» a «Linux o FreeBSD», in 27 file CMake. Senza, ogni libreria esporta i simboli delle sue dipendenze statiche: errori PC32 e NID duplicati (es. FreeType `Xxtq+Qr5lzI`). AgcDriver si collega a libexecinfo (`find_package(Backtrace)`): `backtrace()` su FreeBSD non sta in libc, e senza il simbolo resta irrisolto. |
| 0014-relinker-freebsd-output | Relinker, opzione `--freebsd`: la stessa immagine ELF dell'uscita Linux, con `EI_OSABI` = FreeBSD, `PT_INTERP` = `/libexec/ld-elf.so.1` e senza la dipendenza da `ld-linux-x86-64.so.2` (su FreeBSD `__tls_get_addr` lo esporta rtld). Incompatibile con `--windows` e `--macos`. Nel resoconto della conversione scrive «System: FreeBSD». |
| 0015-libkernel-freebsd-program-variables | libkernel definisce `environ` e `__progname`. Su FreeBSD li definisce crt1, non libc.so.7, e un eseguibile rilinkato non ha crt1: senza, libc.so.7 non si carica (`Undefined symbol "environ"`). rtld li trova fra gli oggetti caricati all'avvio e li riempie prima degli inizializzatori. Il suffisso `_nid_no_patch_cut` fa esportare a nid_patcher i nomi semplici. |
| 0016-libkernel-freebsd-guest-stacks | Stack degli ospiti dentro l'arena, come su Linux: il thread principale passa allo stack della console (cima `0x7eeffc000`) con `EnterGuestMainStack`, che lo stub d'ingresso del titolo rilinkato chiama; i thread creati ricevono uno stack nell'arena. `/proc/self/task/<tid>` (thread finito?) diventa `thr_kill(tid, 0)` = ESRCH. Abilitato anche il test `guest_main_stack`, con i permessi letti da `kern.proc.vmmap`. |
| 0017-tests-freebsd | Solo sorgenti di test (13) e un header per i test. `specifics/freebsd/LinuxMmapFlags.hpp`: `MAP_NORESERVE` = 0, `MAP_FIXED_NOREPLACE` = `MAP_FIXED\|MAP_EXCL`, inclusi dai 10 test di AgcDriver che li usano. `TableIndexValidation`: niente `mremap`, la sostituzione del blocco si fa come su macOS (mmap `MAP_FIXED` sopra). `RegistrationPrepareStack`: `pthread_getattr_np` di Compat. `GuestBoundsChecking`: `std::basic_string<std::uint16_t>` non compila con libc++ 19 (niente `char_traits` generico), sostituito da un vettore terminato con gli stessi `size`/`data`/`c_str`. |
| 0018-libc-freebsd-runtime | Il codice compilava ma su FreeBSD cadeva nei rami `#else` (condizioni scritte per Linux e macOS). Gli interventi: unwinder delle eccezioni ospite (prima erano stub con `abort`); `LibcCaptureRegisters`; `dl_iterate_phdr` per l'ospite; copie controllate con GuestFaultCopy (prima lanciavano); HostMapping su `kern.proc.vmmap` (`specifics/freebsd/HostMapping.hpp`); `MainProgram.hpp`, perche' il programma principale su FreeBSD ha un nome e `AT_PHDR` non c'e'; parametri di processo e heap ospite; GuestWriteWatch col modello a protezione di macOS (`APS5_PROTECTION_WRITE_WATCH`); `HostExecutable::Own`/`Arguments` (`kern.proc.pathname`/`args`); rete BSD. Inoltre: libc.prx e' il runtime C++ delle eccezioni di tutto il processo, quindi alias anche su FreeBSD piu' i 4 di `exception_ptr`; `LibraryAtExit`, perche' su FreeBSD `atexit` di una libreria e' globale; `__stack_chk_guard_nid_postfix`. Infine due difetti generali: SP del landing pad senza `DW_CFA_GNU_args_size`, e `strtol` con l'EINVAL della libc BSD. Libc/libm di FreeBSD 16 diverse dall'ospite: prefisso `0b` del C23 in `strtol`/scanf, float di scanf che tornano indietro all'ultimo prefisso valido o si fermano a 512 byte (per `%i` e i float si usa lo scanner interno), `mktime` che lascia `EOVERFLOW`, libm che non imposta errno (`HostMath`), `tgamma` sopra 171.6244 e sui NaN, byte di una scrittura fallita su stream non bufferizzato (`fpurge`), `ifi_hdrlen` 18 dei driver VLAN; immagini ospite riconosciute anche negli eseguibili a indirizzo fisso (`dlpi_addr` 0); `__cxa_demangle` con libLLVMDemangle (libcxxrt accetta prefissi); `GuestWritable` con una sonda di scrittura `lock or $0` invece di `kern.proc.vmmap`, che copiava l'intera mappa a ogni carattere (guest_icu_utf8: 118 s di sistema); `__gxx_personality_v0`/`__gcc_personality_v0` con il nome dell'host passano alla personalità dell'host i contesti del suo unwinder (libthr svolge `pthread_exit` con libgcc_s); `rename` su un link penzolante (libc++ risponde `not_supported`). Write watch: le scritture proprie del driver (`GuestWriteWatchBegin/EndOwnStore`) fermano il fault-ahead alla fine della loro finestra (con le pagine da 4 KiB le pagine aperte in anticipo finivano prese per scritture della CPU); HostMapping riusa il buffer di `kern.proc.vmmap` (una chiamata invece di due). |
| 0019-libkernel-freebsd-runtime | Rami FreeBSD in libkernel: TLS, init dei moduli ospite, fault (`si_code` FreeBSD), GuestCode, mmap di file, Time/Process/Stdio/Udp con le copie controllate, sysarch (`amd64_set_gsbase`, nome `sysarch_nid_postfix`: la `sysarch` di libc FreeBSD veniva sostituita), exec/LoadExec con OSABI 9, EdgeWatch e pipe con kqueue, VirtualQuery dell'host, `F_KINFO` per i percorsi dei descrittori, EVFILT_VNODE. Inoltre: orologio di CPU del thread stesso con `CLOCK_THREAD_CPUTIME_ID` (quello per TID si ferma all'ultimo cambio di contesto); stack principale senza la pagina di guardia e cresciuto prima di un `mprotect` nella riserva (che spezza la voce di gap); connect/sendto a 0.0.0.0 verso 127.0.0.1; id dei moduli confrontati con la `link_map` di `dlinfo`; eccezioni sollevate su un thread sospeso fuse in una (FreeBSD accoda anche i segnali standard); scritture su pipe da 8 KiB in su spezzate (FreeBSD le consegna dirette e lo scrittore aspetta il lettore); ECONNRESET su uno stream reso come EPIPE; SOCK_SEQPACKET con `MSG_EOR` a ogni invio e il resto di un record troncato scartato; linger riletto senza segno (16 bit); `waitpid` senza la tabella dei segnali di Linux; nome dei file creati messo nella namecache (per `F_KINFO`); un troncamento visto da inotify come `IN_ATTRIB` più `IN_MODIFY`. |
| 0020-libraries-freebsd-runtime | AgcDriver (GuestMemory su HostMapping, read trap del watch; il driver NVIDIA FreeBSD dopo UNA allocazione rifiutata rifiuta quasi tutte le successive, quindi: import solo di intervalli scrivibili, con il watch che lascia andare le pagine prima del pin, e nessuna allocazione di memoria di sistema da 256 MiB in su, che il driver rifiuta sempre; il suo compilatore di shader va in stallo se più thread compilano insieme quando si inizializza, quindi alla creazione del dispositivo si compila da solo uno shader con costante di specializzazione casuale; PerformanceOverlay e cache degli shader su disco senza `/proc`; errno salvato prima di `std::filesystem::space` in SystemService; libSceNet manda gli stream bloccanti a pezzi da 64 KiB come su macOS, perché un invio BSD che fallisce a metà perde il conteggio dei byte accodati; dichiarazione di `sce_net_in6addr_loopback_nid_postfix` allineata come la definizione; `describePages` combina la protezione dell'host col record del watch solo dove il watch la restringe (protezione in scrittura, trappole di lettura); `storeOwn` racchiude le sue scritture nel recinto del fault-ahead; il controllo di scrivibilita' dell'import rilegge la mappa solo sugli intervalli sorvegliati; `UnitFlags::assign` oltre la capacita' costruisce un vettore nuovo), SystemService, LibcInternal, NetCtl (routing con `SA_SIZE`), VideoOut, Font, NpEntitlement, Fiber. |
| 0021-tests-freebsd-runtime | Test (e il CMake di libSceUlt, che su FreeBSD esclude i due casi che intercettano un `std::mutex::lock` inline): fixture dei parametri di processo, ApplicationHeap, GuestSysmodule, GuestSysarch, collegamenti a libexecinfo, include mancanti; `FE_DENORMAL` escluso dai confronti dei flag (la `FE_ALL_EXCEPT` di FreeBSD lo comprende); interfacce di rete con i rami BSD; `malloc` cercata in libc.so.7 negli eseguibili a indirizzo fisso; riserva di crescita dello stack vista come scrivibile; `TCP_NODELAY` nella gara dei lettori di net_dontwait (Nagle con l'ACK ritardato di FreeBSD); kqueue e poll: le pipe FreeBSD, come quelle del PS5, sono bidirezionali; lo sconfinamento di un `mprotect` sotto lo stack fallisce come su Linux; `sce_net_in6addr_linklocal_allnodes` dichiarato allineato a 4 come la definizione (con la regola dei 16 byte il compilatore usava un caricamento SSE allineato, che dava SIGBUS dove la copy relocation lo metteva); il percorso di 1023 byte escluso come su macOS. Inoltre, come su macOS (watch a protezione): etichetta non registrata sulla GPU, store di completamento dei target lineari, flush ordinato delle etichette; in ImageTablePacked i programmi restano vivi per tutto il ciclo (jemalloc riusa l'indirizzo del vettore liberato, le quattro righe di avvelenamento diventano identiche e il log coalescente tace la quarta). |
| 0022-cmake-freebsd-pie | Eseguibili PIE su FreeBSD (`CMAKE_POSITION_INDEPENDENT_CODE` e `check_pie_supported`), come li fanno i compilatori delle distribuzioni Linux: niente copy relocation dei dati delle librerie nell'eseguibile e niente indirizzo fisso 0x200000 del clang dei ports. |
| 0023-relinker-freebsd-load-pages | Relinker, uscita `--freebsd`: (1) un PT_LOAD non allineato che condivide la prima pagina con il segmento sotto (bss mappato fino a fine pagina) parte dall'inizio della pagina, e i segmenti sotto finiscono li': l'attivatore d'immagini di FreeBSD rifiuta la sovrapposizione (exec EINVAL dopo aver distrutto lo spazio d'indirizzi = SIGABRT senza un messaggio), dove Linux mappa sopra; i byte del file prima del segmento riproducono gia' quelli dei segmenti sotto. (2) Niente `DT_PLTGOT` con BIND_NOW: il rtld di FreeBSD scrive GOT[1] e GOT[2] dopo le altre rilocazioni anche con BIND_NOW, e li' c'erano dati dell'ospite (i limiti di init_array del crt di un homebrew). Provato con CD Player (PPSA98427). |
| 0024-cmake-freebsd-sdl-vulkan | CMake principale: la SDL2 inclusa ammette Vulkan solo su Android, Apple, Linux e Windows (`dep_option`) e altrove lo spegne, quindi la finestra X11 non aveva superficie Vulkan (`DisplayWindow: Vulkan support is either not configured in SDL`). Su FreeBSD si imposta `SDL_VULKAN_ISSET`, il valore preimpostato che `cmake_dependent_option` usa al posto del test. Il sottomodulo resta intatto. |

**FFmpeg** non e' una patch. Lo costruisce la modalita' `ffmpeg` dello stage, che `configure` chiama da sola.
- **Perche':** il pacchetto precompilato Linux usa simboli glibc, quindi su FreeBSD non serve.
- **Come:** stesso sorgente della build Linux, sha256 verificato, con la sua riga di configure senza le opzioni di
  piattaforma.
- **Controlli:** gli stessi 56 componenti di Linux e zero simboli glibc.
- **Dove:** `AnyPS5-work/externals-freebsd/ffmpeg-9ac4cfd195f1-freebsd-x64`, passato al CMake come
  `FFMPEG_PREBUILT_DIR`.

## Stato al 21/11/2026 (serie 0001-0024 verificata da zero su 178 file)

Compilano tutti i target dello stage:
- `nid_patcher`, `libc`, `libkernel`;
- `libs`: 413 librerie PS5 su 413, normali e con i NID, zero errori e zero NID duplicati;
- `relinker`, con l'uscita `--freebsd`.

Controllo dei simboli: per ognuna delle 413 librerie, ogni simbolo indefinito si risolve nelle sue dipendenze o in rtld. Fanno eccezione `environ` (4 librerie, corretto dalla 0015) e `backtrace` (AgcDriver, corretto dalla 0013). Controprova della 0015: un eseguibile senza crt1 che dipende da libkernel.prx parte, e `getenv`/`getprogname` funzionano. Con la libkernel senza la correzione, rtld lo rifiuta con `Undefined symbol "environ"`.

Verificato: la serie, applicata da zero a una copia pulita (`git archive` piu' il CMake dopo fase 1 e libusb),
ricostruisce identici tutti i file (57 con la serie 0001-0013, 178 con la 0001-0024 del 21/11).

**Primo avvio di un eseguibile rilinkato** (in una cartella di prova fuori dal checkout): un ELF PS5 minimo, fatto come la fixture di `ConversionTests.cpp` (ingresso = `ret`, dipendenza `libkernel.prx`), viene convertito con `relinker --freebsd` ed eseguito. Prima della 0015 rtld lo rifiutava (`environ`), prima della 0016 pure (`EnterGuestMainStack_nid_no_patch`). Ora:
- rtld carica il titolo, libkernel e libc;
- girano gli inizializzatori;
- `EnterGuestMainStack` mappa lo stack della console;
- il codice ospite viene eseguito e ritorna.

Il processo finisce col SIGILL atteso: il `ud2` dopo `call *%rdx` in `Aps5CallOnGuestMainStack` (verificato con gdb, `rsp = 0x7eeffbff0`), perche' un vero ingresso PS5 non ritorna mai. Nessun titolo vero e' ancora stato eseguito.

**Chiamate ospite→host attraverso le importazioni** (`fixture_ps5_import.py`, nella stessa cartella). Il codice ospite chiama `puts(messaggio)` ed `exit(42)` di libc.prx. Il collegamento passa per:
- simboli `YQ0navp+YIc#A#A` e `uMei1W9uyNo#A#A` (i NID di `puts` ed `exit`, calcolati come `Nid::ComputeNid`);
- il tag modulo `0x61000045` = `libc`;
- due rilocazioni `R_X86_64_GLOB_DAT`.

Dopo `relinker --freebsd` l'eseguibile dipende da `libc.prx` e `libkernel.prx`, e importa `YQ0navp+YIc`, `uMei1W9uyNo` ed `EnterGuestMainStack_nid_no_patch`. Eseguito, stampa il messaggio ed esce con 42: risoluzione dei NID in rtld, ABI della chiamata e uscita ordinata funzionano.

Da fare:
- **Test:** i 36 non grafici e i grafici rimasti, uno per uno.
- **Avvisi:** da classificare.
- **Lacuna nota:** `kinfo_vmentry` non distingue una mappatura anonima `MAP_SHARED` da una privata.
- **Limiti del kernel FreeBSD:** un socket UDP disconnesso (connect AF_UNSPEC) esce dalla tabella hash e non riceve più, né si può rilegare (EINVAL): guest_udp e guest_sce_net; `utimensat` ignora `tv_sec == -1` (VNOVAL); i percorsi dell'ospite di 1023 byte superano MAXPATHLEN (1024) una volta prefissati con la directory dell'host.

**Test (ctest, 6170):** passati il 31%, poi l'82%, l'87% e l'88%. Al 20/11 pomeriggio: con la 0022 (eseguibili PIE) i non grafici
sono 4239 su 4247 (ctest-9: restano i limiti del kernel elencati sotto, `SO_BROADCAST` su TCP e il margine nullo di
guest_getrusage); i grafici sulla RTX 2080 Ti 1910 su 1919 (ctest-rtx-8, tre in parallelo con la VM Windows spenta; erano 1859 prima della guardia sulle
allocazioni NVIDIA e 1900 prima di PIE e del riscaldamento del compilatore). **Al 21/11: grafici 1919 su 1919**
(ctest-rtx-11, tre in parallelo, con la sysctl dei residenti); non grafici 4238 su 4247 (ctest-10): gli 8 di ctest-9 piu'
guest_video_out_window_margins_bounds, che prima si saltava sotto i 20 s e ora ne impiega 25: 640 inizializzazioni di SDL
verso X, ~187 andate e ritorno con il server ciascuna, col desktop carico (thunar e il bus di sessione a 9000 messaggi/s). I grafici vanno eseguiti sulla RTX 2080 Ti: `VK_DRIVER_FILES=/usr/local/lib/nvidia-595-vulkan/nvidia_icd.json`,
`LD_LIBRARY_PATH=/usr/local/lib/nvidia-595-vulkan`, `DISPLAY` impostato (senza X il Vulkan NVIDIA non parte) e
`SDL_VIDEODRIVER=offscreen`. Senza, i test usano da soli la Intel UHD 630.
