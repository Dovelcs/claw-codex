CXX ?= c++
CXXFLAGS ?= -std=c++17 -O2 -Wall -Wextra -pthread
TARGET ?= mkb_codex_linux_agent
OBJS = mkb_codex_linux_agent.o mkb_codex_worker.embedded.o mkb_codex_session_index_sync.embedded.o

.PHONY: all clean run

all: $(TARGET)

$(TARGET): $(OBJS)
	$(CXX) $(CXXFLAGS) $^ -o $@

mkb_codex_linux_agent.o: mkb_codex_linux_agent.cpp
	$(CXX) $(CXXFLAGS) -c $< -o $@

mkb_codex_worker.embedded.o: mkb_codex_worker.cpp
	$(CXX) $(CXXFLAGS) -Dmain=mkb_codex_worker_embedded_main -c $< -o $@

mkb_codex_session_index_sync.embedded.o: mkb_codex_session_index_sync.cpp
	$(CXX) $(CXXFLAGS) -Dmain=mkb_codex_session_index_sync_embedded_main -c $< -o $@

run: $(TARGET)
	./$(TARGET) --broker http://124.174.101.22:886

clean:
	rm -f $(TARGET) mkb_codex_worker mkb_codex_session_index_sync $(OBJS)
