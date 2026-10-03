# SpliX for macOS — Xerox Phaser 3140 / 3155

The Xerox Phaser 3140 and 3155 have no working driver on current macOS. They
are host-based printers: they understand neither PostScript nor PCL, only
Samsung's **QPDL/SPL** page language, so the generic drivers macOS offers
produce nothing, and being USB-only they cannot use AirPrint.

An open-source driver for them does exist. [SpliX](https://github.com/OpenPrinting/splix)
is a CUPS filter (`rastertoqpdl`) that speaks QPDL and ships a PPD for these
models. It has only ever been packaged for Linux and the BSDs.

This repository builds it for macOS.

## Supported printers

| Model | Status |
|---|---|
| Xerox Phaser 3140 | **Tested** — USB, Apple Silicon, macOS 26 (Tahoe) |
| Xerox Phaser 3155 | Expected to work: it reports the same USB identity (`Phaser 3140 and 3155`) and its PPD is identical apart from the name. Untested. |

`install.sh --list` shows every SpliX PPD that needs no JBIG compression — 68
in all, the two above included (Samsung, Xerox, Dell, Toshiba, Lexmark) — and
which this build can therefore drive in principle. **None of the other 66 has
been tried.** If you test one, please open an issue with the result.

## Requirements

- macOS with CUPS (present as of macOS 26)
- Xcode Command Line Tools — `xcode-select --install`

Nothing else: no Homebrew, no libjbig.

## Install

Switch the printer on, connect it, then:

```bash
git clone https://github.com/besirhamarat/splix-macos.git
cd splix-macos
bash install.sh
```

The script finds the printer, fetches a pinned SpliX revision, applies the
patches below, compiles `rastertoqpdl`, installs the filter and the PPD, and
creates the print queue. It uses `sudo` twice — to look up the printer and to
install — so expect a password prompt.

```bash
bash install.sh --list                 # PPDs this build can drive
bash install.sh --ppd ml1910 --uri "usb://..."   # another model, by hand
bash install.sh --queue Office_Xerox   # choose the queue name
bash install.sh --uninstall            # remove the filter
```

If the printer is not found, `sudo lpinfo -v` lists the device addresses
macOS can see. No `usb://` line there means macOS does not see the printer at
all — check the cable, and accept the "Allow accessory to connect?" prompt
that Apple Silicon laptops show for new USB devices.

## What the patches do

SpliX is portable C++, so little is needed:

1. **Temporary files honour `TMPDIR`** (`patches/0001-cache-honour-TMPDIR.patch`).
   SpliX swaps pages to a hard-coded `/tmp/splixV2-pageXXXXXX` once a job holds
   more pages than its cache (30). On macOS, CUPS runs filters in a sandbox
   with a restricted set of writable directories and exports `TMPDIR` pointing
   at one the filter may use. This is a precaution: a short job never reaches
   the swap path, so a build without the patch would look fine until a long
   document was printed.

2. **`include/semaphore.h` renamed to `splixsem.h`.** SpliX has its own
   `Semaphore` class in a header that carries the same name as the system
   `<semaphore.h>`. With `-Iinclude` on the command line it shadows the system
   header for every file in the build.

3. **JBIG compiled out** (`-DDISABLE_JBIG`). The Phaser 3140/3155 PPD requests
   `cupsCompression 17` (algorithm 0x11, banded). The JBIG algorithms (0x13,
   0x15) are never selected, so the dependency on libjbig can be dropped
   entirely. The installer refuses any PPD that does ask for JBIG.

SpliX's own build system is bypassed; the 21 source files of `rastertoqpdl`
are compiled directly with the two defines its makefile would have supplied
(`THREADS=2`, `CACHESIZE=30`). The patched build was checked against an
unpatched one on Linux: the generated QPDL stream is byte-identical.

The installer pins the SpliX revision the patches were written against
(`4854286`), so a later upstream change cannot silently break them.

## What works

Everything the PPD exposes: 23 paper sizes, 14 paper types, tray / manual
feed, 600 and 1200×600 dpi, toner density, toner save, power-save timer, jam
recovery, altitude adjustment.

- **Duplex** is manual — the hardware has no duplex unit. The driver prints
  one side, you turn the stack over.
- **No toner level or status monitoring.** That lived in the vendor's utility
  and has no open-source counterpart.
- The PPD defaults to US Letter. If margins look shifted on A4:
  `sudo lpadmin -p Xerox_Phaser_3140 -o PageSize=A4`

## Caveats

- A major macOS update can empty `/usr/libexec/cups/filter/`. Re-run
  `install.sh` — the source and the compiled binary are cached under
  `~/Library/Caches/splix-macos`, so it takes seconds.
- Apple has deprecated printer drivers and PPDs. They work today; a future
  macOS release may remove the mechanism this relies on.

## License

GPL-2.0-only, the license of SpliX itself (© Aurélien Croc and contributors,
maintained by OpenPrinting). The installer and patch in this repository are
released under the same terms. See `LICENSE`.

Not affiliated with or endorsed by Xerox, Samsung or OpenPrinting.

---

## Türkçe özet

Xerox Phaser 3140 ve 3155 için güncel macOS'ta çalışan bir sürücü yok. Bu
yazıcılar PostScript ya da PCL değil, yalnızca Samsung'un **QPDL/SPL** dilini
anlıyor; bu yüzden macOS'un genel sürücüleri çıktı vermiyor.

Açık kaynak **SpliX** sürücüsü bu modelleri destekliyor, ancak bugüne kadar
yalnızca Linux için paketlenmiş. Bu depo onu macOS için derliyor.

Gereken tek şey Xcode komut satırı araçları (`xcode-select --install`).
Yazıcıyı açıp USB'ye taktıktan sonra:

```bash
bash install.sh
```

Betik yazıcıyı bulur, SpliX kaynağını indirir, macOS yamalarını uygular,
derler ve kurar. Yalnızca Phaser 3140 üzerinde (USB, Apple Silicon, macOS 26)
denenmiştir.

Çift taraflı baskı elle çevirmelidir; toner seviyesi izleme yoktur.
