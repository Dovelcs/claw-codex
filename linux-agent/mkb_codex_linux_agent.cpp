#include <csignal>
#include <cerrno>
#include <cstdlib>
#include <cstring>
#include <ctime>
#include <iostream>
#include <map>
#include <string>
#include <sys/types.h>
#include <sys/wait.h>
#include <thread>
#include <unistd.h>
#include <vector>

int mkb_codex_worker_embedded_main(int argc, char** argv);
int mkb_codex_session_index_sync_embedded_main(int argc, char** argv);

namespace {

volatile sig_atomic_t g_running = 1;
pid_t g_worker_pid = -1;
pid_t g_history_pid = -1;
pid_t g_history_request_pid = -1;

const char* kInternalWorkerMode = "--mkb-internal-worker";
const char* kInternalSessionSyncMode = "--mkb-internal-session-sync";

void handle_signal(int) {
    g_running = 0;
}

std::string env_or(const char* name, const std::string& fallback = "") {
    const char* value = std::getenv(name);
    return value && *value ? value : fallback;
}

void set_env_default(const char* name, const std::string& value) {
    if (std::getenv(name) == nullptr && !value.empty()) {
        setenv(name, value.c_str(), 0);
    }
}

std::string now_string() {
    std::time_t t = std::time(nullptr);
    char buf[64]{};
    std::strftime(buf, sizeof(buf), "%Y-%m-%dT%H:%M:%S%z", std::localtime(&t));
    return buf;
}

void log_line(const std::string& message) {
    std::cerr << now_string() << " " << message << "\n";
}

std::vector<char*> argv_from_strings(std::vector<std::string>& args) {
    std::vector<char*> out;
    out.reserve(args.size() + 1);
    for (auto& arg : args) out.push_back(arg.data());
    out.push_back(nullptr);
    return out;
}

pid_t spawn_process(std::vector<std::string> args) {
    if (args.empty()) return -1;
    pid_t pid = fork();
    if (pid < 0) {
        log_line("fork failed");
        return -1;
    }
    if (pid == 0) {
        auto argv = argv_from_strings(args);
        execvp(argv[0], argv.data());
        std::cerr << "exec failed: " << args[0] << " error=" << std::strerror(errno) << "\n";
        _exit(127);
    }
    return pid;
}

int run_process(std::vector<std::string> args) {
    pid_t pid = spawn_process(std::move(args));
    if (pid <= 0) return 127;
    int status = 0;
    while (waitpid(pid, &status, 0) < 0) {
        if (errno == EINTR && g_running) continue;
        return 128;
    }
    if (WIFEXITED(status)) return WEXITSTATUS(status);
    if (WIFSIGNALED(status)) return 128 + WTERMSIG(status);
    return status;
}

void stop_child(pid_t pid, const std::string& label) {
    if (pid <= 0) return;
    if (kill(pid, SIGTERM) == 0) {
        for (int i = 0; i < 20; ++i) {
            int status = 0;
            pid_t rc = waitpid(pid, &status, WNOHANG);
            if (rc == pid) {
                log_line(label + " stopped");
                return;
            }
            std::this_thread::sleep_for(std::chrono::milliseconds(100));
        }
        kill(pid, SIGKILL);
        waitpid(pid, nullptr, 0);
    }
}

struct Options {
    std::string broker = "http://124.174.101.22:886";
    std::string agent_bin;
    std::string worker_bin;
    std::string session_sync_bin;
    std::string session_index = "~/.codex/session_index.jsonl";
    int history_interval_seconds = 300;
    int history_request_interval_ms = 100;
    bool no_worker = false;
    bool once = false;
};

std::vector<std::string> history_sync_args(const Options& options, bool requests_only = false);

Options parse_args(int argc, char** argv) {
    Options options;
    options.agent_bin = argv[0] && *argv[0] ? argv[0] : "mkb_codex_linux_agent";
    options.broker = env_or("MKB_CODEX_AGENT_BROKER", options.broker);
    options.session_index = env_or("MKB_CODEX_SESSION_INDEX", options.session_index);
    options.history_interval_seconds = std::atoi(env_or("MKB_CODEX_AGENT_HISTORY_INTERVAL", "300").c_str());
    if (options.history_interval_seconds <= 0) options.history_interval_seconds = 300;
    std::string request_interval_ms = env_or("MKB_CODEX_AGENT_HISTORY_REQUEST_INTERVAL_MS", "");
    if (!request_interval_ms.empty()) {
        options.history_request_interval_ms = std::atoi(request_interval_ms.c_str());
    } else {
        options.history_request_interval_ms = std::atoi(env_or("MKB_CODEX_AGENT_HISTORY_REQUEST_INTERVAL", "0").c_str()) * 1000;
    }
    if (options.history_request_interval_ms <= 0) options.history_request_interval_ms = 100;
    options.worker_bin = env_or("MKB_CODEX_AGENT_WORKER_BIN", "");
    options.session_sync_bin = env_or("MKB_CODEX_AGENT_SESSION_SYNC_BIN", "");

    for (int i = 1; i < argc; ++i) {
        std::string arg = argv[i];
        auto next = [&]() -> std::string {
            if (i + 1 >= argc) return "";
            return argv[++i];
        };
        if (arg == "--broker") options.broker = next();
        else if (arg == "--worker-bin") options.worker_bin = next();
        else if (arg == "--session-sync-bin") options.session_sync_bin = next();
        else if (arg == "--session-index") options.session_index = next();
        else if (arg == "--history-interval") options.history_interval_seconds = std::atoi(next().c_str());
        else if (arg == "--history-request-interval") options.history_request_interval_ms = std::atoi(next().c_str()) * 1000;
        else if (arg == "--history-request-interval-ms") options.history_request_interval_ms = std::atoi(next().c_str());
        else if (arg == "--no-worker") options.no_worker = true;
        else if (arg == "--once") options.once = true;
        else if (arg == "--help" || arg == "-h") {
            std::cout << "usage: mkb_codex_linux_agent [--broker URL] [--worker-bin PATH] [--session-sync-bin PATH]\n"
                      << "                             [--session-index PATH] [--history-interval SECONDS]\n"
                      << "                             [--history-request-interval SECONDS|--history-request-interval-ms MS]\n"
                      << "                             [--no-worker] [--once]\n";
            std::exit(0);
        }
    }
    if (options.history_interval_seconds <= 0) options.history_interval_seconds = 300;
    if (options.history_request_interval_ms <= 0) options.history_request_interval_ms = 100;
    return options;
}

void configure_worker_defaults() {
    set_env_default("MKB_CODEX_WORKER_ID", "company-linux-vscode-worker");
    set_env_default("MKB_CODEX_WORKER_LABEL", "Company Linux VS Code Codex");
    set_env_default("MKB_CODEX_WORKER_VSCODE_IPC", "1");
    set_env_default("MKB_CODEX_WORKER_VSCODE_IPC_SOCKET", "/tmp/codex-ipc/ipc-" + std::to_string(getuid()) + ".sock");
    set_env_default("MKB_CODEX_WORKER_VSCODE_IPC_CLIENT_TYPE", "vscode");
    set_env_default("MKB_CODEX_WORKER_DEFAULT_CWD", env_or("HOME", "/tmp"));
}

int run_history_sync(const Options& options) {
    auto args = history_sync_args(options, false);
    log_line("history sync start");
    int rc = run_process(args);
    log_line("history sync exit=" + std::to_string(rc));
    return rc;
}

std::vector<std::string> history_sync_args(const Options& options, bool requests_only) {
    std::vector<std::string> args;
    if (options.session_sync_bin.empty()) {
        args = {options.agent_bin, kInternalSessionSyncMode, options.broker, options.session_index};
    } else {
        args = {options.session_sync_bin, options.broker, options.session_index};
    }
    if (requests_only) args.push_back("--requests-only");
    return args;
}

std::string status_string(int status) {
    if (WIFEXITED(status)) return "exit=" + std::to_string(WEXITSTATUS(status));
    if (WIFSIGNALED(status)) return "signal=" + std::to_string(WTERMSIG(status));
    return "status=" + std::to_string(status);
}

void reap_child_if_needed(pid_t& pid, const std::string& label) {
    if (pid <= 0) return;
    int status = 0;
    pid_t rc = waitpid(pid, &status, WNOHANG);
    if (rc == pid) {
        log_line(label + " " + status_string(status));
        pid = -1;
    }
}

void reap_worker_if_needed() {
    reap_child_if_needed(g_worker_pid, "worker");
}

void reap_history_if_needed() {
    reap_child_if_needed(g_history_pid, "history sync");
}

void reap_history_request_if_needed() {
    reap_child_if_needed(g_history_request_pid, "history request sync");
}

void ensure_worker(const Options& options) {
    if (options.no_worker || g_worker_pid > 0) return;
    configure_worker_defaults();
    if (options.worker_bin.empty()) {
        g_worker_pid = spawn_process({options.agent_bin, kInternalWorkerMode, options.broker});
    } else {
        g_worker_pid = spawn_process({options.worker_bin, options.broker});
    }
    log_line("worker pid=" + std::to_string(g_worker_pid));
}

void ensure_history_sync(const Options& options) {
    if (g_history_pid > 0) return;
    g_history_pid = spawn_process(history_sync_args(options, false));
    log_line("history sync pid=" + std::to_string(g_history_pid));
}

void ensure_history_request_sync(const Options& options) {
    if (g_history_request_pid > 0) return;
    g_history_request_pid = spawn_process(history_sync_args(options, true));
    log_line("history request sync pid=" + std::to_string(g_history_request_pid));
}

} // namespace

int main(int argc, char** argv) {
    if (argc > 1 && std::string(argv[1]) == kInternalWorkerMode) {
        std::vector<char*> shifted;
        shifted.push_back(const_cast<char*>("mkb_codex_worker"));
        for (int i = 2; i < argc; ++i) shifted.push_back(argv[i]);
        shifted.push_back(nullptr);
        return mkb_codex_worker_embedded_main(static_cast<int>(shifted.size() - 1), shifted.data());
    }
    if (argc > 1 && std::string(argv[1]) == kInternalSessionSyncMode) {
        std::vector<char*> shifted;
        shifted.push_back(const_cast<char*>("mkb_codex_session_index_sync"));
        for (int i = 2; i < argc; ++i) shifted.push_back(argv[i]);
        shifted.push_back(nullptr);
        return mkb_codex_session_index_sync_embedded_main(static_cast<int>(shifted.size() - 1), shifted.data());
    }

    std::signal(SIGINT, handle_signal);
    std::signal(SIGTERM, handle_signal);
    Options options = parse_args(argc, argv);

    log_line("mkb_codex_linux_agent broker=" + options.broker);
    ensure_worker(options);
    if (options.once) {
        int last_history_rc = run_history_sync(options);
        stop_child(g_worker_pid, "worker");
        return last_history_rc;
    }
    ensure_history_sync(options);
    ensure_history_request_sync(options);

    int elapsed_ms = 0;
    int request_elapsed_ms = 0;
    const int tick_ms = 100;
    const int history_interval_ms = options.history_interval_seconds * 1000;
    while (g_running) {
        std::this_thread::sleep_for(std::chrono::milliseconds(tick_ms));
        reap_worker_if_needed();
        reap_history_if_needed();
        reap_history_request_if_needed();
        ensure_worker(options);
        elapsed_ms += tick_ms;
        request_elapsed_ms += tick_ms;
        if (elapsed_ms >= history_interval_ms) {
            elapsed_ms = 0;
            ensure_history_sync(options);
        }
        if (request_elapsed_ms >= options.history_request_interval_ms) {
            request_elapsed_ms = 0;
            ensure_history_request_sync(options);
        }
    }

    stop_child(g_history_request_pid, "history request sync");
    stop_child(g_history_pid, "history sync");
    stop_child(g_worker_pid, "worker");
    log_line("mkb_codex_linux_agent stopped");
    return 0;
}
