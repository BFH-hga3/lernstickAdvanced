# MSE gfxboot theme — rebranding workflow

Your VirtualBox (BIOS) boot uses **gfxboot**; your USB key (UEFI) uses **GRUB2**.
This package covers the gfxboot side. The `bootlogo` you extracted is *compiled
output* — you don't decompile it, you rebuild it from source.

## Source repository

**https://github.com/Lernstick/xmlboot**

- `script/xmlboot.bc` + `*.inc` → compiled into `bootlogo.dir/init` (the menu **engine**).
  You do **not** need to touch this for MSE branding.
- `examples/lernstick_debian8_exam/` → the template closest to your exam use case
  (Swiss-first language/keyboard config, `boot=live persistence-encryption=luks,none`,
  Europe/Zurich). Menu content lives in editable **`xmlboot.config`** (XML).

The MSE look = your splash set + rebranded header logos + (optional) icons +
edited `xmlboot.config` text. The engine stays stock.

## What's in this package

- `mse_exam/` — a self-contained copy of the exam example with **MSE assets already
  dropped in** (six `splash_WxH.jpg`, plus `splash_xmlboot*.jpg` / `splash_linux*.jpg`
  header logos). Symlinks dereferenced to real files.
- `splashes-only/` — just the MSE images, if you prefer to drop them straight into an
  existing `bootlogo.dir` without rebuilding.
- `bootlogo.prebuilt` — a **ready, packed** MSE bootlogo archive built here on
  Debian 13, so you can test immediately in VirtualBox before setting up your own build.

## Build dependencies (Debian 13 build host)

    sudo apt install gfxboot gfxboot-dev itstool translate-toolkit gettext

`gfxboot-dev` (4.5.73-2) is present in Debian 13 and provides `gfxboot-compile`,
`gfxboot-font`, and `unpack_bootlogo`.

## Build from source (the proper path)

Place `mse_exam/` inside a clone of the xmlboot tree so the relative paths in its
Makefile (`../common`, `../../script`) resolve:

    git clone https://github.com/Lernstick/xmlboot.git
    cp -r mse_exam xmlboot/examples/
    cd xmlboot/examples/mse_exam
    make

The Makefile runs, in order:

    make -C po                  # compile *.po → *.translation (de_CH, fr_CH, it_CH, ...)
    make -C ../common/fonts     # build bitmap fonts (.fnt) from DejaVu
    make -C ../../script        # compile xmlboot.bc → bootlogo.dir/init
    cp -a ../../script/bootlogo.dir .
    cp *jpg *fnt po/*translation xmlboot.config bootlogo.dir
    gfxboot --archive bootlogo.dir --pack-archive bootlogo   # → packed 'bootlogo'

Output: a packed `bootlogo` archive. That is the file your live-build ISOLINUX
config references (`gfxboot bootlogo`).

## JPEG constraints (important — gfxboot is picky)

All splash/icon JPGs MUST be:

- **RGB** (not grayscale)
- **baseline / non-progressive**
- **4:2:0 chroma subsampling**

The MSE images in this package are already encoded to that spec. If you regenerate
any from GIMP: File → Export As → .jpg → uncheck *Progressive*, set subsampling to
*4:2:0*. From Pillow:

    im.convert('RGB').save(f, 'JPEG', quality=90, progressive=False, subsampling=2)

Also note the xmlboot bug warning in the config header: **filenames must be longer
than 12 characters** (the `findfile` command silently ignores shorter names), so keep
the `splash_*` / `icon_*` naming.

## Quick test (no rebuild)

Drop `bootlogo.prebuilt` in as your `bootlogo` and boot the VirtualBox image.
Or preview on a build host with a VM installed:

    gfxtest --type boot        # needs qemu/kvm/virtualbox present

## Going further — full MSE menu chrome

The splash backgrounds and header logos are now MSE. The **menu box styling, text
colors, and layout** are drawn by the engine (`script/*.inc`) plus the `.fnt` fonts,
not by the images. If you want MSE-colored menu boxes/highlights you'd edit the
drawing logic in `script/menu.inc` / `video.inc` and recompile `init`. That's a
larger source-level job and usually unnecessary — the background + logo rebrand
carries the identity.

## What to edit in xmlboot.config

- `<splash>splash_xmlboot.jpg</splash>` — the header logo shown on the menu.
- Menu entry `<text>` strings — reword to MSE exam wording.
- Language/keyboard `<option>` blocks — already Swiss-first; trim the long tail of
  locales you don't need for MSE exams if you want a shorter menu.
- `<syslinux_defaults ... label="linux boot=live ...">` — your kernel/boot params.

## Remember: this is the BIOS path only

Your UEFI USB boot renders the **GRUB2** `mse` theme (theme.txt / .pf2 / stylebox
slices) instead — gfxboot doesn't run under UEFI GRUB2 at all. Keep both in sync
visually by exporting from one master MSE artwork: native-res background for GRUB2,
these fixed sizes for gfxboot.
