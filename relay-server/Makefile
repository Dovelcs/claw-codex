CXX ?= c++
CXXFLAGS ?= -std=c++17 -O2 -Wall -Wextra -pthread
TARGET ?= mkb_codex_relay

.PHONY: all clean run

all: $(TARGET)

$(TARGET): mkb_codex_relay.cpp
	$(CXX) $(CXXFLAGS) $< -o $@

run: $(TARGET)
	./$(TARGET) 127.0.0.1 18992

clean:
	rm -f $(TARGET)
