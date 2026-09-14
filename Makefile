# Magic Trackpad USB-C su macOS Catalina
#
#   make            compila tutto in ./build
#   make bridge     solo il daemon
#   make run        compila e avvia il daemon
#   make triage     diagnostica del sistema
#   make clean

BUILD   := build
CC      := clang
CFLAGS  := -Wall -Wextra -O2 -mmacosx-version-min=10.15
FW_HID  := -framework IOKit -framework CoreFoundation
FW_CG   := -framework ApplicationServices

TOOLS   := $(BUILD)/mt_desc_dump $(BUILD)/mt_enable $(BUILD)/mt_sweep
BRIDGE  := $(BUILD)/mammetta_bridge

.PHONY: all bridge tools run triage clean

all: $(BRIDGE) $(TOOLS)

bridge: $(BRIDGE)
tools: $(TOOLS)

$(BUILD):
	@mkdir -p $(BUILD)

$(BUILD)/mammetta_bridge: src/mammetta_bridge.m | $(BUILD)
	$(CC) $(CFLAGS) -fobjc-arc $(FW_HID) $(FW_CG) -o $@ $<

$(BUILD)/%: tools/%.c | $(BUILD)
	$(CC) $(CFLAGS) $(FW_HID) -o $@ $<

run: $(BRIDGE)
	$(BRIDGE) -v

triage:
	@./tools/triage.sh

clean:
	rm -rf $(BUILD)
