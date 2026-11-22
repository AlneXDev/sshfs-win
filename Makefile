# SSHFS-Win modern - Cygwin/WinFsp build driver
#
# Run from a Cygwin shell (not cmd.exe / PowerShell).
# Upstream sshfs 3.7.7 is vendored as a tarball so builds are reproducible.
# FUSE comes from WinFsp's FUSE3-for-Cygwin package (fuse3.pc, version 3.2),
# which satisfies upstream's `fuse3 >= 3.1.0' requirement.

SSHFS_VERSION = 3.7.7

MyProductName    = "SSHFS-Win"
MyCompanyName    = "Open Source"
MyDescription    = "SSHFS for Windows (upstream $(SSHFS_VERSION))"
MyProductVersion = $(SSHFS_VERSION)
MyProductStage   = "Beta"
# Stable MSI version: a date-stamped version makes stamp-based `make dist`
# fail on a later day, when the stamp is unchanged but the filename is not.
MyVersion        = $(SSHFS_VERSION).1

ifeq ($(shell uname -m),x86_64)
	MyArch = x64
else
	MyArch = x86
endif

PrjDir  = $(shell pwd)
BldDir  = .build/$(MyArch)
DistDir = $(BldDir)/dist
SrcDir  = $(BldDir)/src
RootDir = $(BldDir)/root
WixDir  = $(BldDir)/wix
Status  = $(BldDir)/status
BuildDir = $(SrcDir)/sshfs/build

# Cygwin/meson may emit either "sshfs" or "sshfs.exe"; resolve it lazily so the
# build directory exists by the time this is expanded in a recipe.
SSHFS_BIN = $(or $(firstword $(wildcard $(BuildDir)/sshfs $(BuildDir)/sshfs.exe)),$(BuildDir)/sshfs)

# Extra Cygwin executables to bundle next to sshfs.exe
BinExtra = ssh

# WiX v3 tools (candle, heat, light) are only needed for the `msi' target.
ifneq ($(strip $(WIX)),)
export PATH := $(shell cygpath -au "$(WIX)")/bin:$(PATH)
endif

.PHONY: all check msi dist clean
all: check $(Status)/sshfs-win

check:
	@command -v meson >/dev/null 2>&1 || { echo "ERROR: install Cygwin package 'meson'" 1>&2; exit 1; }
	@command -v ninja >/dev/null 2>&1 || { echo "ERROR: install Cygwin package 'ninja'" 1>&2; exit 1; }
	@command -v patch >/dev/null 2>&1 || { echo "ERROR: install Cygwin package 'patch'" 1>&2; exit 1; }
	@command -v pkg-config >/dev/null 2>&1 || { echo "ERROR: install Cygwin package 'pkg-config'" 1>&2; exit 1; }
	@for t in gcc cygcheck ldd strip tar xargs date; do \
		command -v $$t >/dev/null 2>&1 || { echo "ERROR: missing tool '$$t'" 1>&2; exit 1; }; \
	done
	@pkg-config --exists fuse3 || { echo "ERROR: FUSE for Cygwin not installed. See BUILDING.md." 1>&2; exit 1; }
	@pkg-config --atleast-version=3.1.0 fuse3 || { echo "ERROR: fuse3 too old (need >= 3.1.0)" 1>&2; exit 1; }
	@echo "fuse3 version: $$(pkg-config --modversion fuse3)"

$(Status):
	mkdir -p $(Status)

$(Status)/extract: vendor/sshfs-$(SSHFS_VERSION).tar.xz | $(Status)
	mkdir -p $(SrcDir)
	tar -xf $< -C $(SrcDir)
	mv $(SrcDir)/sshfs-$(SSHFS_VERSION) $(SrcDir)/sshfs
	touch $@

PATCHES = $(wildcard patches/*.patch)

$(Status)/patch: $(Status)/extract $(PATCHES)
	# Re-extract so a forced rebuild never applies patches twice.
	rm -rf $(SrcDir)/sshfs
	tar -xf vendor/sshfs-$(SSHFS_VERSION).tar.xz -C $(SrcDir)
	mv $(SrcDir)/sshfs-$(SSHFS_VERSION) $(SrcDir)/sshfs
	cd $(SrcDir)/sshfs && for f in "$(PrjDir)"/patches/*.patch; do \
		patch --binary -p1 < "$$f" || exit 1; \
	done
	touch $@

$(Status)/config: $(Status)/patch
	mkdir -p $(BuildDir)
	if [ -f $(BuildDir)/meson-info/intro-buildoptions.json ]; then \
		meson setup --wipe $(BuildDir) $(SrcDir)/sshfs; \
	else \
		meson setup $(BuildDir) $(SrcDir)/sshfs; \
	fi
	touch $@

$(Status)/make: $(Status)/config
	ninja -C $(BuildDir)
	touch $@

$(Status)/root: $(Status)/make
	mkdir -p $(RootDir)/bin $(RootDir)/dev/mqueue $(RootDir)/dev/shm $(RootDir)/etc
	(cygcheck $(SSHFS_BIN); for f in $(BinExtra); do cygcheck /usr/bin/$$f; done) | \
		tr -d '\r' | tr '\\' / | xargs cygpath -au | grep '^/usr/bin/' | sort -u | \
		while read f; do cp "$$f" $(RootDir)/bin; done
	# cygcheck only sees /usr/bin; a locally built cygfuse shim lives elsewhere.
	ldd $(SSHFS_BIN) | grep cygfuse | sed 's/^.*=> //; s/ (0x.*$$//' | \
		while read f; do cp "$$f" $(RootDir)/bin; done
	# Always install as sshfs.exe: sshfs-win.c hardcodes /usr/bin/sshfs.exe.
	cp $(SSHFS_BIN) $(RootDir)/bin/sshfs.exe
	strip $(RootDir)/bin/sshfs.exe
	for f in $(BinExtra); do cp /usr/bin/$$f $(RootDir)/bin; done
	cp -R "$(PrjDir)/etc" $(RootDir)
	touch $@

$(Status)/sshfs-win: $(Status)/root sshfs-win.c
	gcc -O2 -o $(RootDir)/bin/sshfs-win.exe sshfs-win.c
	strip $(RootDir)/bin/sshfs-win.exe
	touch $@

msi: $(Status)/wix

$(Status)/wix: $(Status)/sshfs-win sshfs-win.wxs
	mkdir -p $(WixDir)
	cp sshfs-win.wxs $(WixDir)/
	candle -nologo -arch $(MyArch) -pedantic \
		-dMyProductName=$(MyProductName) \
		-dMyCompanyName=$(MyCompanyName) \
		-dMyDescription=$(MyDescription) \
		-dMyProductVersion=$(MyProductVersion) \
		-dMyProductStage=$(MyProductStage) \
		-dMyVersion=$(MyVersion) \
		-dMyArch=$(MyArch) \
		-o "$(shell cygpath -aw $(WixDir)/sshfs-win.wixobj)" \
		"$(shell cygpath -aw $(WixDir)/sshfs-win.wxs)"
	heat dir "$(shell cygpath -aw $(RootDir))" \
		-nologo -dr INSTALLDIR -cg C.Main -srd -ke -sreg -gg -sfrag \
		-o "$(shell cygpath -aw $(WixDir)/root.wxs)"
	candle -nologo -arch $(MyArch) -pedantic \
		-dMyProductName=$(MyProductName) \
		-dMyCompanyName=$(MyCompanyName) \
		-dMyDescription=$(MyDescription) \
		-dMyProductVersion=$(MyProductVersion) \
		-dMyProductStage=$(MyProductStage) \
		-dMyVersion=$(MyVersion) \
		-dMyArch=$(MyArch) \
		-o "$(shell cygpath -aw $(WixDir)/root.wixobj)" \
		"$(shell cygpath -aw $(WixDir)/root.wxs)"
	light -nologo \
		-o "$(shell cygpath -aw $(WixDir)/sshfs-win-$(MyVersion)-$(MyArch).msi)" \
		-ext WixUIExtension \
		-b "$(shell cygpath -aw $(RootDir))" \
		"$(shell cygpath -aw $(WixDir)/root.wixobj)" \
		"$(shell cygpath -aw $(WixDir)/sshfs-win.wixobj)"
	touch $@

dist: $(Status)/wix
	mkdir -p $(DistDir)
	cp "$(shell cygpath -aw $(WixDir)/sshfs-win-$(MyVersion)-$(MyArch).msi)" $(DistDir)

clean:
	rm -rf $(BldDir)
