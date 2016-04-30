PREFIX          ?= /usr/local
#PREFIX         ?= =/usr/fa

LIB                     ?= $(PREFIX)/lib
BIN                     ?= $(PREFIX)/bin
TCLSH           ?= tclsh

PACKAGE=fiberbundle-core
TARGET=$(LIB)/$(PACKAGE)
FILES=*.tcl

all:
	@echo "'make install' to install"

install:
	echo "pkg_mkIndex ." | $(TCLSH)
	@install -o root -g wheel -m 0755 -d $(TARGET)
	@install -o root -g wheel -m 0644 $(FILES) $(TARGET)/
	@echo "Installed $(PACKAGE) package to $(LIB)"
