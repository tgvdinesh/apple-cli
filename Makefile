BIN = apple
SRC = apple.swift
PREFIX ?= /usr/local/bin

build:
	swiftc $(SRC) -o $(BIN)

install: build
	cp $(BIN) $(PREFIX)/$(BIN)
	@echo "Installed to $(PREFIX)/$(BIN)"

uninstall:
	rm -f $(PREFIX)/$(BIN)

clean:
	rm -f $(BIN)

.PHONY: build install uninstall clean
