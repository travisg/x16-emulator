##################################################################################################
#
# COMMANDER X16 EMULATOR MAKEFILE
#
##################################################################################################

# the mingw-w64 path on macOS installed through homebrew
ifndef MINGW32
	MINGW32=/opt/homebrew/Cellar/mingw-w64/9.0.0_4/toolchain-x86_64/x86_64-w64-mingw32
endif
# the Windows SDL2 path on macOS installed through
# ./configure  --host=x86_64-w64-mingw32 --prefix=... && make && make install
ifndef WIN_SDL2
	WIN_SDL2=~/tmp/sdl2-win32
endif

ifeq ($(CROSS_COMPILE_WINDOWS),1)
	SDL2CONFIG?=$(WIN_SDL2)/bin/sdl2-config --prefix=$(WIN_SDL2)
else
	SDL2CONFIG=sdl2-config
endif

CFLAGS=-std=c99 -O3 -Wall -Werror -g $(shell $(SDL2CONFIG) --cflags) -Isrc/extern/include -Isrc/extern/src
LDFLAGS=$(shell $(SDL2CONFIG) --libs) -lm -lz

# build with link time optimization
ifdef LTO
	CFLAGS+=-flto
	LDFLAGS+=-flto
endif

X16_ODIR = build/x16emu
X16_SDIR = src

MAKECART_ODIR = build/makecart
MAKECART_SDIR = src

ifdef TRACE
	CFLAGS+=-D TRACE
endif

X16_OUTPUT=x16emu
MAKECART_OUTPUT=makecart

GIT_REV=$(shell git diff --quiet && echo -n $$(git rev-parse --short=8 HEAD || /bin/echo "00000000") || /bin/echo -n $$( /bin/echo -n $$(git rev-parse --short=7 HEAD || /bin/echo "0000000"); /bin/echo -n '+'))

CFLAGS+=-D GIT_REV='"$(GIT_REV)"'

ifeq ($(MAC_STATIC),1)
	LIBSDL_FILE?=/opt/homebrew/Cellar/sdl2/2.0.20/lib/libSDL2.a
	LDFLAGS=$(LIBSDL_FILE) -lm -liconv -lz -Wl,-framework,CoreAudio -Wl,-framework,AudioToolbox -Wl,-framework,ForceFeedback -lobjc -Wl,-framework,CoreVideo -Wl,-framework,Cocoa -Wl,-framework,Carbon -Wl,-framework,IOKit -Wl,-weak_framework,QuartzCore -Wl,-weak_framework,Metal -Wl,-weak_framework,CoreHaptics -Wl,-weak_framework,GameController
endif

ifeq ($(CROSS_COMPILE_WINDOWS),1)
	LDFLAGS+=-L$(MINGW32)/lib
	# this enables printf() to show, but also forces a console window
	LDFLAGS+=-Wl,--subsystem,console
ifeq ($(TARGET_CPU),x86)
	CC=i686-w64-mingw32-gcc
else
	CC=x86_64-w64-mingw32-gcc
endif
endif

ifdef EMSCRIPTEN
	LDFLAGS+=--shell-file webassembly/x16emu-template.html --preload-file rom.bin -s TOTAL_MEMORY=32MB -s ASSERTIONS=1 -s DISABLE_DEPRECATED_FIND_EVENT_TARGET_BEHAVIOR=1
	# To the Javascript runtime exported functions
	LDFLAGS+=-s EXPORTED_FUNCTIONS='["_j2c_reset", "_j2c_paste", "_j2c_start_audio", _main]' -s EXTRA_EXPORTED_RUNTIME_METHODS='["ccall", "cwrap"]' -s USE_ZLIB=1 -s EXIT_RUNTIME=1
	CFLAGS+=-s USE_ZLIB=1
	X16_OUTPUT=x16emu.html
	MAKECART_OUTPUT=makecart.html
endif

_X16_OBJS = cpu/fake6502.o memory.o disasm.o video.o i2c.o smc.o rtc.o via.o serial.o ieee.o vera_spi.o audio.o vera_pcm.o vera_psg.o sdcard.o main.o debugger.o javascript_interface.o joystick.o rendertext.o keyboard.o icon.o timing.o wav_recorder.o testbench.o files.o cartridge.o
_X16_OBJS += extern/src/ym2151.o
X16_OBJS = $(patsubst %,$(X16_ODIR)/%,$(_X16_OBJS))
X16_DEPS := $(X16_OBJS:.o=.d)

_MAKECART_OBJS = makecart.o files.o cartridge.o makecart_javascript_interface.o

MAKECART_OBJS = $(patsubst %,$(X16_ODIR)/%,$(_MAKECART_OBJS))
MAKECART_DEPS := $(MAKECART_OBJS:.o=.d)

.PHONY: all clean wasm
all: x16emu makecart

x16emu: $(X16_OBJS)
	$(CC) -o $(X16_OUTPUT) $(X16_OBJS) $(LDFLAGS)

$(X16_ODIR)/%.o: $(X16_SDIR)/%.c
	@mkdir -p $$(dirname $@)
	$(CC) $(CFLAGS) -c $< -MD -MT $@ -MF $(@:%o=%d) -o $@

makecart: $(MAKECART_OBJS)
	$(CC) -o $(MAKECART_OUTPUT) $(MAKECART_OBJS) $(LDFLAGS)

$(MAKECART_ODIR)/%.o: $(MAKECART_SDIR)/%.c
	@mkdir -p $$(dirname $@)
	$(CC) $(CFLAGS) -c $< -MD -MT $@ -MF $(@:%o=%d) -o $@

cpu/tables.h cpu/mnemonics.h: cpu/buildtables.py cpu/6502.opcodes cpu/65c02.opcodes
	cd cpu && python buildtables.py

# Empty rules so that renames of header files do not trigger a failure to compile
$(X16_SDIR)/%.h:;
$(MAKECART_SDIR)/%.h:;

# WebASssembly/emscripten target
#
# See webassembly/WebAssembly.md
wasm:
	emmake make

clean:
	rm -rf $(X16_ODIR) $(MAKECART_ODIR) x16emu x16emu.exe x16emu.js x16emu.wasm x16emu.data x16emu.worker.js x16emu.html x16emu.html.mem makecart makecart.exe makecart.js makecart.wasm makecart.data makecart.worker.js makecart.html makecart.html.mem

ifeq ($(filter $(MAKECMDGOALS), clean),)
-include $(X16_DEPS)
-include $(MAKECART_DEPS)
endif

##################################################################################################

##################################################################################################
#
# PACKAGING
#
# Packaging is tricky and partially depends on Michael's specific setup. :/
#
# * The Mac build is done on a Mac.
# * The Windows build is cross-compiled on the Mac using mingw. For more info, see:
#   https://blog.wasin.io/2018/10/21/cross-compile-sdl2-library-and-app-on-windows-from-macos.html
# * The Linux build is done by sshing into a VMware Ubuntu machine that has the same
#   directory tree mounted. Since unlike on Windows and Mac, there are 0 libraries guaranteed
#   to be present, a static build would mean linking everything that is not the kernel. And since
#   there are always 3 ways of doing something on Linux, it would mean including three graphics
#   and three sounds backends. Therefore, the Linux build uses dynamic linking, requires libsdl2
#   to be installed and might only work on the version of Linux I used for building, which is the
#   current version of Ubuntu.
# * For converting the documentation from Markdown to HTML, pandoc is required:
#   brew install pandoc
#
##################################################################################################

# hostname of the Linux VM
LINUX_COMPILE_HOST = ubuntu.local
# path to the equivalent of `pwd` on the Mac
LINUX_BASE_DIR = /tmp/

TMPDIR_NAME=TMP-x16emu-package

define add_extra_files_to_package
	# ROMs
	cp ../x16-rom/build/x16/rom.bin $(TMPDIR_NAME)
	cp ../x16-rom/build/x16/kernal.sym  $(TMPDIR_NAME)
	cp ../x16-rom/build/x16/keymap.sym  $(TMPDIR_NAME)
	cp ../x16-rom/build/x16/dos.sym     $(TMPDIR_NAME)
	cp ../x16-rom/build/x16/geos.sym    $(TMPDIR_NAME)
	cp ../x16-rom/build/x16/basic.sym   $(TMPDIR_NAME)
	cp ../x16-rom/build/x16/monitor.sym $(TMPDIR_NAME)
	cp ../x16-rom/build/x16/charset.sym $(TMPDIR_NAME)

	# Empty SD card image
	cp sdcard.img.zip $(TMPDIR_NAME)

	# Documentation
	mkdir $(TMPDIR_NAME)/docs
	pandoc --from gfm --to html -c github-pandoc.css --standalone --metadata pagetitle="Commander X16 Emulator" README.md --output $(TMPDIR_NAME)/docs/README.html
	pandoc --from gfm --to html -c github-pandoc.css --standalone --metadata pagetitle="Commander X16 KERNAL/BASIC/DOS ROM"  ../x16-rom/README.md --output $(TMPDIR_NAME)/docs/KERNAL-BASIC.html
	pandoc --from gfm --to html -c github-pandoc.css --standalone --metadata pagetitle="Commander X16 Programmer's Reference Guide"  ../x16-docs/Commander\ X16\ Programmer\'s\ Reference\ Guide.md --output $(TMPDIR_NAME)/docs/Programmer\'s\ Reference\ Guide.html --lua-filter=mdtohtml.lua
	for IN in ../x16-docs/X16\ Reference\ *; do \
		OUT=$$(basename "$$IN" .md).html; \
		pandoc --from gfm --to html -c github-pandoc.css --standalone --metadata pagetitle="Commander X16 Programmer's Reference Guide" "$$IN" --output "$(TMPDIR_NAME)/docs/$$OUT" --lua-filter=mdtohtml.lua; \
	done
	pandoc --from gfm --to html -c github-pandoc.css --standalone --metadata pagetitle="VERA Programmer's Reference.md"  ../x16-docs/VERA\ Programmer\'s\ Reference.md --output $(TMPDIR_NAME)/docs/VERA\ Programmer\'s\ Reference.html
	cp github-pandoc.css $(TMPDIR_NAME)/docs
endef

package: package_mac package_win package_linux
	make clean

package_mac:
	(cd ../x16-rom/; make clean all)
	MAC_STATIC=1 make clean all
	rm -rf $(TMPDIR_NAME) x16emu_mac.zip
	mkdir $(TMPDIR_NAME)
	cp x16emu makecart $(TMPDIR_NAME)
	$(call add_extra_files_to_package)
	(cd $(TMPDIR_NAME)/; zip -r "../x16emu_mac.zip" *)
	rm -rf $(TMPDIR_NAME)

package_win:
	(cd ../x16-rom/; make clean all)
	CROSS_COMPILE_WINDOWS=1 make clean all
	rm -rf $(TMPDIR_NAME) x16emu_win.zip
	mkdir $(TMPDIR_NAME)
	cp x16emu.exe makecart.exe $(TMPDIR_NAME)
	cp $(WIN_SDL2)/bin/SDL2.dll $(TMPDIR_NAME)/
	$(call add_extra_files_to_package)
	(cd $(TMPDIR_NAME)/; zip -r "../x16emu_win.zip" *)
	rm -rf $(TMPDIR_NAME)

package_linux:
	(cd ../x16-rom/; make clean all)
	(cd ..; tar cp x16-rom x16-emulator x16-docs | ssh $(LINUX_COMPILE_HOST) "cd $(LINUX_BASE_DIR); tar xp")
	ssh $(LINUX_COMPILE_HOST) "cd $(LINUX_BASE_DIR)/x16-emulator; make clean all"
	rm -rf $(TMPDIR_NAME) x16emu_linux.zip
	mkdir $(TMPDIR_NAME)
	scp $(LINUX_COMPILE_HOST):$(LINUX_BASE_DIR)/x16-emulator/x16emu $(LINUX_COMPILE_HOST):$(LINUX_BASE_DIR)/x16-emulator/makecart $(TMPDIR_NAME)
	$(call add_extra_files_to_package)
	(cd $(TMPDIR_NAME)/; zip -r "../x16emu_linux.zip" *)
	rm -rf $(TMPDIR_NAME)
