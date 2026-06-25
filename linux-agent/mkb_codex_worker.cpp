#include <arpa/inet.h>
#include <dirent.h>
#include <fcntl.h>
#include <netdb.h>
#include <sys/select.h>
#include <sys/socket.h>
#include <sys/un.h>
#include <sys/wait.h>
#include <unistd.h>

#include <algorithm>
#include <atomic>
#include <chrono>
#include <csignal>
#include <cctype>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <ctime>
#include <fstream>
#include <iostream>
#include <regex>
#include <sstream>
#include <set>
#include <string>
#include <thread>
#include <vector>

using namespace std::chrono_literals;

namespace {

std::atomic<bool> g_running{true};

struct Url {
    std::string host;
    int port = 80;
    std::string base_path;
};

struct HttpResponse {
    int status = 0;
    std::string body;
    std::string error;
};

struct TaskPayload {
    std::string task_id;
    std::string session_id;
    std::string project_alias;
    std::string prompt;
    std::string mode;
    std::string model;
    std::string reasoning_effort;
    std::string project_path;
    std::string thread_id;
    std::string active_turn_id;
    bool cancelled = false;
};

struct CodexSpawn {
    pid_t pid = -1;
    int stdin_fd = -1;
    int stdout_fd = -1;
    int stderr_fd = -1;
    std::string error;
};

struct CommandResult {
    int status = -1;
    std::string output;
};

struct AppServerEndpoint {
    std::string scheme;
    std::string host = "127.0.0.1";
    int port = 0;
    std::string path = "/";
    std::string unix_path;
};

std::string env_or(const char* key, const std::string& fallback = "") {
    const char* value = std::getenv(key);
    return value && *value ? std::string(value) : fallback;
}

std::string shell_quote(const std::string& value) {
    std::string quoted = "'";
    for (char c : value) {
        if (c == '\'') quoted += "'\\''";
        else quoted.push_back(c);
    }
    quoted.push_back('\'');
    return quoted;
}

std::string applescript_quote(const std::string& value) {
    std::string quoted = "\"";
    for (char c : value) {
        if (c == '\\') quoted += "\\\\";
        else if (c == '"') quoted += "\\\"";
        else quoted.push_back(c);
    }
    quoted.push_back('"');
    return quoted;
}

CommandResult run_command_capture(const std::string& command, int timeout_seconds = 8) {
    CommandResult result;
    int pipe_fd[2];
    if (pipe(pipe_fd) != 0) {
        result.output = "pipe failed";
        return result;
    }

    pid_t pid = fork();
    if (pid < 0) {
        close(pipe_fd[0]);
        close(pipe_fd[1]);
        result.output = "fork failed";
        return result;
    }
    if (pid == 0) {
        close(pipe_fd[0]);
        dup2(pipe_fd[1], STDOUT_FILENO);
        dup2(pipe_fd[1], STDERR_FILENO);
        close(pipe_fd[1]);
        std::string shell_command = command + " 2>&1";
        execl("/bin/sh", "sh", "-c", shell_command.c_str(), static_cast<char*>(nullptr));
        _exit(127);
    }

    close(pipe_fd[1]);
    fcntl(pipe_fd[0], F_SETFL, fcntl(pipe_fd[0], F_GETFL, 0) | O_NONBLOCK);

    auto deadline = std::chrono::steady_clock::now() + std::chrono::seconds(timeout_seconds);
    bool child_exited = false;
    int child_status = 0;
    while (true) {
        char buffer[4096];
        ssize_t n = read(pipe_fd[0], buffer, sizeof(buffer));
        if (n > 0) {
            result.output.append(buffer, static_cast<size_t>(n));
            continue;
        }

        pid_t wait_result = waitpid(pid, &child_status, WNOHANG);
        if (wait_result == pid) {
            child_exited = true;
            break;
        }

        if (std::chrono::steady_clock::now() >= deadline) {
            kill(pid, SIGKILL);
            waitpid(pid, &child_status, 0);
            result.status = 124;
            if (!result.output.empty() && result.output.back() != '\n') result.output.push_back('\n');
            result.output += "command timed out";
            close(pipe_fd[0]);
            return result;
        }

        fd_set readfds;
        FD_ZERO(&readfds);
        FD_SET(pipe_fd[0], &readfds);
        timeval tv{};
        tv.tv_sec = 0;
        tv.tv_usec = 100000;
        select(pipe_fd[0] + 1, &readfds, nullptr, nullptr, &tv);
    }

    while (true) {
        char buffer[4096];
        ssize_t n = read(pipe_fd[0], buffer, sizeof(buffer));
        if (n > 0) result.output.append(buffer, static_cast<size_t>(n));
        else break;
    }
    close(pipe_fd[0]);

    if (child_exited && WIFEXITED(child_status)) result.status = WEXITSTATUS(child_status);
    else if (child_exited) result.status = child_status;
    return result;
}

std::string truncate_for_event(const std::string& value, size_t limit = 1200) {
    if (value.size() <= limit) return value;
    return value.substr(0, limit) + "...";
}

std::string json_escape(const std::string& s) {
    std::ostringstream out;
    for (unsigned char c : s) {
        switch (c) {
        case '\\': out << "\\\\"; break;
        case '"': out << "\\\""; break;
        case '\n': out << "\\n"; break;
        case '\r': out << "\\r"; break;
        case '\t': out << "\\t"; break;
        default:
            if (c < 0x20) {
                const char* hex = "0123456789abcdef";
                out << "\\u00" << hex[(c >> 4) & 0xf] << hex[c & 0xf];
            } else {
                out << c;
            }
        }
    }
    return out.str();
}

std::string q(const std::string& s) {
    return "\"" + json_escape(s) + "\"";
}

std::string url_encode(const std::string& s) {
    std::ostringstream out;
    const char* hex = "0123456789ABCDEF";
    for (unsigned char c : s) {
        if ((c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z') || (c >= '0' && c <= '9') || c == '-' || c == '_' || c == '.' || c == '~') {
            out << c;
        } else {
            out << '%' << hex[(c >> 4) & 0xf] << hex[c & 0xf];
        }
    }
    return out.str();
}

std::string json_string_field(const std::string& body, const std::string& key, const std::string& fallback = "") {
    std::regex re("\"" + key + "\"\\s*:\\s*\"((?:\\\\.|[^\"])*)\"");
    std::smatch m;
    if (!std::regex_search(body, m, re)) return fallback;
    std::string raw = m[1].str();
    std::string out;
    for (size_t i = 0; i < raw.size(); ++i) {
        if (raw[i] == '\\' && i + 1 < raw.size()) {
            char n = raw[++i];
            if (n == 'n') out.push_back('\n');
            else if (n == 'r') out.push_back('\r');
            else if (n == 't') out.push_back('\t');
            else out.push_back(n);
        } else {
            out.push_back(raw[i]);
        }
    }
    return out;
}

bool json_has(const std::string& body, const std::string& needle) {
    return body.find(needle) != std::string::npos;
}

bool json_bool_field(const std::string& body, const std::string& key, bool fallback = false) {
    std::regex re("\"" + key + "\"\\s*:\\s*(true|false)");
    std::smatch m;
    if (!std::regex_search(body, m, re)) return fallback;
    return m[1].str() == "true";
}

long long json_long_field(const std::string& body, const std::string& key, long long fallback = 0) {
    std::regex re("\"" + key + "\"\\s*:\\s*(-?[0-9]+)");
    std::smatch m;
    if (!std::regex_search(body, m, re)) return fallback;
    try {
        return std::stoll(m[1].str());
    } catch (...) {
        return fallback;
    }
}

bool should_emit_diagnostic(const std::string& line) {
    if (env_or("MKB_CODEX_WORKER_DIAGNOSTICS") == "1") return true;
    if (line.find(" WARN codex_core_plugins::manifest:") != std::string::npos) return false;
    if (line.find(" WARN codex_core_skills::loader:") != std::string::npos) return false;
    return !line.empty();
}

Url parse_url(const std::string& input) {
    std::string url = input;
    const std::string http = "http://";
    if (url.rfind(http, 0) == 0) url = url.substr(http.size());
    Url result;
    auto slash = url.find('/');
    std::string authority = slash == std::string::npos ? url : url.substr(0, slash);
    result.base_path = slash == std::string::npos ? "" : url.substr(slash);
    auto colon = authority.rfind(':');
    if (colon == std::string::npos) {
        result.host = authority;
    } else {
        result.host = authority.substr(0, colon);
        result.port = std::atoi(authority.substr(colon + 1).c_str());
    }
    if (result.base_path == "/") result.base_path.clear();
    return result;
}

int connect_tcp(const std::string& host, int port, std::string& error) {
    addrinfo hints{};
    hints.ai_family = AF_UNSPEC;
    hints.ai_socktype = SOCK_STREAM;
    addrinfo* res = nullptr;
    int rc = getaddrinfo(host.c_str(), std::to_string(port).c_str(), &hints, &res);
    if (rc != 0) {
        error = gai_strerror(rc);
        return -1;
    }
    int fd = -1;
    for (addrinfo* p = res; p; p = p->ai_next) {
        fd = socket(p->ai_family, p->ai_socktype, p->ai_protocol);
        if (fd < 0) continue;
        if (connect(fd, p->ai_addr, p->ai_addrlen) == 0) break;
        close(fd);
        fd = -1;
    }
    freeaddrinfo(res);
    if (fd < 0) error = "connect failed";
    return fd;
}

HttpResponse http_request(const Url& base, const std::string& method, const std::string& path, const std::string& body = "") {
    HttpResponse response;
    std::string error;
    int fd = connect_tcp(base.host, base.port, error);
    if (fd < 0) {
        response.error = error;
        return response;
    }

    std::string full_path = base.base_path + path;
    if (full_path.empty()) full_path = "/";
    std::ostringstream req;
    req << method << " " << full_path << " HTTP/1.1\r\n";
    req << "Host: " << base.host << "\r\n";
    req << "User-Agent: mkb-codex-worker/0.1\r\n";
    req << "Connection: close\r\n";
    if (method == "POST") {
        req << "Content-Type: application/json\r\n";
        req << "Content-Length: " << body.size() << "\r\n";
    }
    req << "\r\n";
    req << body;
    std::string wire = req.str();
    const char* ptr = wire.data();
    size_t remaining = wire.size();
    while (remaining > 0) {
        ssize_t n = send(fd, ptr, remaining, MSG_NOSIGNAL);
        if (n <= 0) {
            response.error = "send failed";
            close(fd);
            return response;
        }
        ptr += n;
        remaining -= static_cast<size_t>(n);
    }

    std::string raw;
    char buf[8192];
    while (true) {
        ssize_t n = recv(fd, buf, sizeof(buf), 0);
        if (n > 0) raw.append(buf, n);
        else break;
    }
    close(fd);

    auto header_end = raw.find("\r\n\r\n");
    if (header_end == std::string::npos) {
        response.error = "bad http response";
        return response;
    }
    std::string header = raw.substr(0, header_end);
    std::istringstream hs(header);
    std::string http_version;
    hs >> http_version >> response.status;
    response.body = raw.substr(header_end + 4);
    return response;
}

AppServerEndpoint parse_app_server_endpoint(const std::string& raw) {
    AppServerEndpoint endpoint;
    if (raw.rfind("unix://", 0) == 0) {
        endpoint.scheme = "unix";
        endpoint.unix_path = raw.substr(7);
        endpoint.path = "/";
        return endpoint;
    }
    if (raw.rfind("ws://", 0) == 0) {
        endpoint.scheme = "ws";
        std::string rest = raw.substr(5);
        auto slash = rest.find('/');
        std::string authority = slash == std::string::npos ? rest : rest.substr(0, slash);
        endpoint.path = slash == std::string::npos ? "/" : rest.substr(slash);
        auto colon = authority.rfind(':');
        if (colon == std::string::npos) {
            endpoint.host = authority;
            endpoint.port = 80;
        } else {
            endpoint.host = authority.substr(0, colon);
            endpoint.port = std::atoi(authority.substr(colon + 1).c_str());
        }
    }
    return endpoint;
}

int connect_unix_socket(const std::string& path, std::string& error) {
    int fd = socket(AF_UNIX, SOCK_STREAM, 0);
    if (fd < 0) {
        error = "socket failed";
        return -1;
    }
    sockaddr_un addr{};
    addr.sun_family = AF_UNIX;
    if (path.size() >= sizeof(addr.sun_path)) {
        close(fd);
        error = "unix socket path too long";
        return -1;
    }
    std::strncpy(addr.sun_path, path.c_str(), sizeof(addr.sun_path) - 1);
    if (connect(fd, reinterpret_cast<sockaddr*>(&addr), sizeof(addr)) != 0) {
        error = std::strerror(errno);
        close(fd);
        return -1;
    }
    return fd;
}

bool send_all(int fd, const std::string& data) {
    const char* ptr = data.data();
    size_t remaining = data.size();
    while (remaining > 0) {
        ssize_t n = send(fd, ptr, remaining, MSG_NOSIGNAL);
        if (n <= 0) return false;
        ptr += n;
        remaining -= static_cast<size_t>(n);
    }
    return true;
}

int recv_exact(int fd, char* buffer, size_t size, int timeout_ms) {
    size_t offset = 0;
    while (offset < size) {
        fd_set readfds;
        FD_ZERO(&readfds);
        FD_SET(fd, &readfds);
        timeval tv{};
        tv.tv_sec = timeout_ms / 1000;
        tv.tv_usec = (timeout_ms % 1000) * 1000;
        int ready = select(fd + 1, &readfds, nullptr, nullptr, &tv);
        if (ready == 0) return 0;
        if (ready < 0) return -1;
        ssize_t n = recv(fd, buffer + offset, size - offset, 0);
        if (n <= 0) return -1;
        offset += static_cast<size_t>(n);
    }
    return 1;
}

std::string websocket_key() {
    static const char* alphabet = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/";
    unsigned char bytes[16];
    for (unsigned char& byte : bytes) byte = static_cast<unsigned char>(std::rand() & 0xff);
    std::string out;
    for (size_t i = 0; i < sizeof(bytes); i += 3) {
        unsigned int value = bytes[i] << 16;
        if (i + 1 < sizeof(bytes)) value |= bytes[i + 1] << 8;
        if (i + 2 < sizeof(bytes)) value |= bytes[i + 2];
        out.push_back(alphabet[(value >> 18) & 0x3f]);
        out.push_back(alphabet[(value >> 12) & 0x3f]);
        out.push_back(i + 1 < sizeof(bytes) ? alphabet[(value >> 6) & 0x3f] : '=');
        out.push_back(i + 2 < sizeof(bytes) ? alphabet[value & 0x3f] : '=');
    }
    return out;
}

bool websocket_handshake(int fd, const AppServerEndpoint& endpoint, std::string& error) {
    std::ostringstream req;
    req << "GET " << (endpoint.path.empty() ? "/" : endpoint.path) << " HTTP/1.1\r\n";
    req << "Host: " << (endpoint.scheme == "unix" ? "localhost" : endpoint.host) << "\r\n";
    req << "Upgrade: websocket\r\n";
    req << "Connection: Upgrade\r\n";
    req << "Sec-WebSocket-Key: " << websocket_key() << "\r\n";
    req << "Sec-WebSocket-Version: 13\r\n\r\n";
    if (!send_all(fd, req.str())) {
        error = "websocket handshake send failed";
        return false;
    }
    std::string header;
    char c = 0;
    while (header.find("\r\n\r\n") == std::string::npos && header.size() < 8192) {
        int rc = recv_exact(fd, &c, 1, 5000);
        if (rc <= 0) {
            error = "websocket handshake read failed";
            return false;
        }
        header.push_back(c);
    }
    if (header.find("101") == std::string::npos || header.find("websocket") == std::string::npos) {
        error = "websocket upgrade rejected: " + truncate_for_event(header, 400);
        return false;
    }
    return true;
}

bool websocket_send_frame(int fd, unsigned char opcode, const std::string& payload) {
    std::string frame;
    frame.push_back(static_cast<char>(0x80 | opcode));
    size_t n = payload.size();
    if (n < 126) {
        frame.push_back(static_cast<char>(0x80 | n));
    } else if (n <= 0xffff) {
        frame.push_back(static_cast<char>(0x80 | 126));
        frame.push_back(static_cast<char>((n >> 8) & 0xff));
        frame.push_back(static_cast<char>(n & 0xff));
    } else {
        frame.push_back(static_cast<char>(0x80 | 127));
        for (int i = 7; i >= 0; --i) frame.push_back(static_cast<char>((n >> (i * 8)) & 0xff));
    }
    unsigned char mask[4];
    for (unsigned char& byte : mask) byte = static_cast<unsigned char>(std::rand() & 0xff);
    frame.append(reinterpret_cast<char*>(mask), 4);
    for (size_t i = 0; i < payload.size(); ++i) frame.push_back(static_cast<char>(static_cast<unsigned char>(payload[i]) ^ mask[i % 4]));
    return send_all(fd, frame);
}

bool websocket_send_text(int fd, const std::string& payload) {
    return websocket_send_frame(fd, 0x1, payload);
}

int websocket_read_text(int fd, std::string& text, int timeout_ms) {
    unsigned char header[2];
    int rc = recv_exact(fd, reinterpret_cast<char*>(header), 2, timeout_ms);
    if (rc <= 0) return rc;
    unsigned char opcode = header[0] & 0x0f;
    uint64_t length = header[1] & 0x7f;
    if (length == 126) {
        unsigned char ext[2];
        if (recv_exact(fd, reinterpret_cast<char*>(ext), 2, timeout_ms) <= 0) return -1;
        length = (static_cast<uint64_t>(ext[0]) << 8) | ext[1];
    } else if (length == 127) {
        unsigned char ext[8];
        if (recv_exact(fd, reinterpret_cast<char*>(ext), 8, timeout_ms) <= 0) return -1;
        length = 0;
        for (unsigned char b : ext) length = (length << 8) | b;
    }
    bool masked = (header[1] & 0x80) != 0;
    unsigned char mask[4] = {0, 0, 0, 0};
    if (masked && recv_exact(fd, reinterpret_cast<char*>(mask), 4, timeout_ms) <= 0) return -1;
    if (length > 16 * 1024 * 1024) return -1;
    std::string payload(static_cast<size_t>(length), '\0');
    if (length && recv_exact(fd, payload.data(), static_cast<size_t>(length), timeout_ms) <= 0) return -1;
    if (masked) {
        for (size_t i = 0; i < payload.size(); ++i) payload[i] = static_cast<char>(static_cast<unsigned char>(payload[i]) ^ mask[i % 4]);
    }
    if (opcode == 0x8) return -1;
    if (opcode == 0x9) {
        websocket_send_frame(fd, 0xA, payload);
        return 2;
    }
    if (opcode != 0x1) return 2;
    text = payload;
    return 1;
}

int connect_app_server(const AppServerEndpoint& endpoint, std::string& error) {
    int fd = -1;
    if (endpoint.scheme == "unix") {
        fd = connect_unix_socket(endpoint.unix_path, error);
    } else if (endpoint.scheme == "ws") {
        fd = connect_tcp(endpoint.host, endpoint.port, error);
    } else {
        error = "unsupported app-server url";
        return -1;
    }
    if (fd < 0) return -1;
    if (!websocket_handshake(fd, endpoint, error)) {
        close(fd);
        return -1;
    }
    return fd;
}

std::string latest_vscode_extension_codex_bin() {
    std::string home = env_or("HOME");
    if (home.empty()) return "";
    std::string root = home + "/.vscode-server/extensions";
    DIR* dir = opendir(root.c_str());
    if (!dir) return "";

    std::string best;
    while (auto* entry = readdir(dir)) {
        std::string name = entry->d_name;
        if (name.rfind("openai.chatgpt-", 0) != 0) continue;
        std::string candidate = root + "/" + name + "/bin/linux-x86_64/codex";
        if (access(candidate.c_str(), X_OK) != 0) continue;
        if (best.empty() || candidate > best) best = candidate;
    }
    closedir(dir);
    return best;
}

std::string codex_bin() {
    auto configured = env_or("MKB_CODEX_WORKER_CODEX_BIN");
    if (!configured.empty()) return configured;
    const std::string app_bin = "/Applications/Codex.app/Contents/Resources/codex";
    if (access(app_bin.c_str(), X_OK) == 0) return app_bin;
    auto vscode_bin = latest_vscode_extension_codex_bin();
    if (!vscode_bin.empty()) return vscode_bin;
    return "codex";
}

std::string default_cwd() {
    auto configured = env_or("MKB_CODEX_WORKER_DEFAULT_CWD");
    if (!configured.empty()) return configured;
    char buf[4096];
    if (getcwd(buf, sizeof(buf))) return buf;
    return ".";
}

bool resume_desktop_thread_mode() {
    return !env_or("MKB_CODEX_WORKER_RESUME_THREAD_ID").empty();
}

int set_nonblocking(int fd) {
    int flags = fcntl(fd, F_GETFL, 0);
    if (flags < 0) return -1;
    return fcntl(fd, F_SETFL, flags | O_NONBLOCK);
}

CodexSpawn spawn_codex_process(const TaskPayload& task) {
    CodexSpawn result;
    int in_pipe[2] = {-1, -1};
    int out_pipe[2] = {-1, -1};
    int err_pipe[2] = {-1, -1};
    if (pipe(in_pipe) || pipe(out_pipe) || pipe(err_pipe)) {
        result.error = "pipe failed";
        return result;
    }

    std::string cwd = task.project_path.empty() ? default_cwd() : task.project_path;
    std::string bin = codex_bin();
    std::string sandbox = env_or("MKB_CODEX_WORKER_SANDBOX", "workspace-write");
    std::string model = task.model.empty() ? env_or("MKB_CODEX_WORKER_MODEL") : task.model;
    std::string reasoning_effort = task.reasoning_effort.empty() ? env_or("MKB_CODEX_WORKER_REASONING_EFFORT") : task.reasoning_effort;
    bool bypass = env_or("MKB_CODEX_WORKER_BYPASS") == "1";
    std::string resume_thread_id = env_or("MKB_CODEX_WORKER_RESUME_THREAD_ID");
    bool resume = !task.thread_id.empty();

    std::vector<std::string> args;
    args.push_back(bin);
    args.push_back("exec");
    if (!resume_thread_id.empty()) {
        args.push_back("resume");
        args.push_back("--json");
        args.push_back("--skip-git-repo-check");
        if (!model.empty()) {
            args.push_back("-m");
            args.push_back(model);
        }
        if (!reasoning_effort.empty()) {
            args.push_back("-c");
            args.push_back("model_reasoning_effort=" + reasoning_effort);
        }
        if (bypass) args.push_back("--dangerously-bypass-approvals-and-sandbox");
        args.push_back(resume_thread_id);
        args.push_back("-");
    } else if (resume) {
        args.push_back("resume");
        args.push_back("--json");
        args.push_back("--skip-git-repo-check");
        if (!model.empty()) {
            args.push_back("-m");
            args.push_back(model);
        }
        if (!reasoning_effort.empty()) {
            args.push_back("-c");
            args.push_back("model_reasoning_effort=" + reasoning_effort);
        }
        if (bypass) args.push_back("--dangerously-bypass-approvals-and-sandbox");
        args.push_back(task.thread_id);
        args.push_back("-");
    } else {
        args.push_back("--json");
        args.push_back("--color");
        args.push_back("never");
        args.push_back("-C");
        args.push_back(cwd);
        if (!bypass) {
            args.push_back("--sandbox");
            args.push_back(sandbox);
        } else {
            args.push_back("--dangerously-bypass-approvals-and-sandbox");
        }
        args.push_back("--skip-git-repo-check");
        if (!model.empty()) {
            args.push_back("-m");
            args.push_back(model);
        }
        if (!reasoning_effort.empty()) {
            args.push_back("-c");
            args.push_back("model_reasoning_effort=" + reasoning_effort);
        }
        args.push_back("-");
    }

    pid_t pid = fork();
    if (pid < 0) {
        result.error = "fork failed";
        return result;
    }
    if (pid == 0) {
        setpgid(0, 0);
        dup2(in_pipe[0], STDIN_FILENO);
        dup2(out_pipe[1], STDOUT_FILENO);
        dup2(err_pipe[1], STDERR_FILENO);
        close(in_pipe[0]);
        close(in_pipe[1]);
        close(out_pipe[0]);
        close(out_pipe[1]);
        close(err_pipe[0]);
        close(err_pipe[1]);
        if (chdir(cwd.c_str()) != 0) {
            std::cerr << "chdir failed for " << cwd << ": " << std::strerror(errno) << "\n";
            _exit(126);
        }
        std::vector<char*> argv;
        argv.reserve(args.size() + 1);
        for (auto& arg : args) argv.push_back(const_cast<char*>(arg.c_str()));
        argv.push_back(nullptr);
        execvp(bin.c_str(), argv.data());
        std::cerr << "execvp failed for " << bin << ": " << std::strerror(errno) << "\n";
        _exit(127);
    }

    setpgid(pid, pid);
    close(in_pipe[0]);
    close(out_pipe[1]);
    close(err_pipe[1]);
    set_nonblocking(out_pipe[0]);
    set_nonblocking(err_pipe[0]);
    result.pid = pid;
    result.stdin_fd = in_pipe[1];
    result.stdout_fd = out_pipe[0];
    result.stderr_fd = err_pipe[0];
    return result;
}

void post_event(const Url& broker, const std::string& worker_id, const TaskPayload& task, const std::string& type, const std::string& message, const std::string& data_json = "{}", const std::string& extra = "") {
    std::string body = "{\"worker_id\":" + q(worker_id) + ",\"task_id\":" + q(task.task_id) +
                       ",\"session_id\":" + q(task.session_id) + ",\"type\":" + q(type) +
                       ",\"message\":" + q(message) + ",\"data_json\":" + q(data_json);
    if (!extra.empty()) body += "," + extra;
    body += "}";
    auto res = http_request(broker, "POST", "/api/workers/events", body);
    if (res.status < 200 || res.status >= 300) {
        std::cerr << "event post failed type=" << type << " status=" << res.status << " error=" << res.error << "\n";
    }
}

struct ControlState {
    bool cancelled = false;
    long long steer_id = 0;
    std::string steer_text;
};

ControlState fetch_control(const Url& broker, const TaskPayload& task) {
    auto res = http_request(broker, "GET", "/api/workers/control?task_id=" + url_encode(task.task_id));
    ControlState state;
    if (res.status != 200) return state;
    state.cancelled = json_bool_field(res.body, "cancelled", false);
    state.steer_id = json_long_field(res.body, "steer_id", 0);
    state.steer_text = json_string_field(res.body, "steer_text");
    return state;
}

bool control_cancelled(const Url& broker, const TaskPayload& task) {
    return fetch_control(broker, task).cancelled;
}

bool transcript_user_matched(const Url& broker, const TaskPayload& task, int timeout_ms = 25000) {
    auto deadline = std::chrono::steady_clock::now() + std::chrono::milliseconds(timeout_ms);
    while (std::chrono::steady_clock::now() < deadline) {
        auto res = http_request(broker, "GET", "/api/events?tail=240");
        if (res.status == 200 &&
            res.body.find("\"task_id\":" + q(task.task_id)) != std::string::npos &&
            res.body.find("\"type\":\"transcript.user.matched\"") != std::string::npos &&
            res.body.find("\"message\":" + q(task.prompt)) != std::string::npos) {
            return true;
        }
        std::this_thread::sleep_for(500ms);
    }
    return false;
}

bool task_has_output_event(const Url& broker, const TaskPayload& task) {
    auto res = http_request(broker, "GET", "/api/events?target=" + url_encode(task.task_id) + "&tail=120");
    if (res.status != 200) return false;
    return res.body.find("\"type\":\"codex.output.delta\"") != std::string::npos ||
           res.body.find("\"type\":\"codex.turn.completed\"") != std::string::npos ||
           res.body.find("\"type\":\"codex.error\"") != std::string::npos;
}

std::string default_vscode_ipc_socket_path() {
    std::string uid = std::to_string(getuid());
    std::string override_path = env_or("MKB_CODEX_WORKER_VSCODE_IPC_SOCKET");
    if (!override_path.empty()) return override_path;
    std::string tmp = env_or("TMPDIR", "/tmp");
    while (tmp.size() > 1 && tmp.back() == '/') tmp.pop_back();
    std::string candidate = tmp + "/codex-ipc/ipc-" + uid + ".sock";
    if (access(candidate.c_str(), F_OK) == 0) return candidate;
    return "/tmp/codex-ipc/ipc-" + uid + ".sock";
}

std::string ipc_request_id(const std::string& method) {
    static int counter = 0;
    std::string safe = method;
    for (char& c : safe) {
        if (!std::isalnum(static_cast<unsigned char>(c))) c = '-';
    }
    return "mkb-" + std::to_string(getpid()) + "-" + std::to_string(++counter) + "-" + safe;
}

int vscode_ipc_method_version(const std::string& method) {
    if (method == "initialize") return 0;
    if (method == "thread-follower-interrupt-turn") return 2;
    return 1;
}

bool vscode_ipc_send_message(int fd, const std::string& body) {
    uint32_t len = static_cast<uint32_t>(body.size());
    std::string frame;
    frame.resize(4);
    frame[0] = static_cast<char>(len & 0xff);
    frame[1] = static_cast<char>((len >> 8) & 0xff);
    frame[2] = static_cast<char>((len >> 16) & 0xff);
    frame[3] = static_cast<char>((len >> 24) & 0xff);
    frame += body;
    return send_all(fd, frame);
}

bool drain_fd_bytes(int fd, uint32_t len, int timeout_ms) {
    std::array<char, 64 * 1024> buffer{};
    uint32_t remaining = len;
    while (remaining > 0) {
        size_t chunk = std::min<size_t>(buffer.size(), remaining);
        int rc = recv_exact(fd, buffer.data(), chunk, timeout_ms);
        if (rc <= 0) return false;
        remaining -= static_cast<uint32_t>(chunk);
    }
    return true;
}

bool vscode_ipc_read_message(int fd, std::string& body, int timeout_ms = 20000) {
    char header[4];
    int rc = recv_exact(fd, header, sizeof(header), timeout_ms);
    if (rc <= 0) return false;
    uint32_t len = static_cast<unsigned char>(header[0]) |
                   (static_cast<unsigned char>(header[1]) << 8) |
                   (static_cast<unsigned char>(header[2]) << 16) |
                   (static_cast<unsigned char>(header[3]) << 24);
    if (len == 0) return false;
    if (len > 64 * 1024 * 1024) {
        drain_fd_bytes(fd, len, timeout_ms);
        body.clear();
        return true;
    }
    body.assign(len, '\0');
    return recv_exact(fd, body.data(), len, timeout_ms) > 0;
}

std::string vscode_ipc_send_request(int fd, const std::string& method, const std::string& params_json,
                                    const std::string& source_client_id = "") {
    std::string request_id = ipc_request_id(method);
    std::string body = "{\"type\":\"request\",\"requestId\":" + q(request_id) +
                       ",\"version\":" + std::to_string(vscode_ipc_method_version(method)) +
                       ",\"method\":" + q(method);
    if (!source_client_id.empty()) body += ",\"sourceClientId\":" + q(source_client_id);
    body += ",\"params\":" + params_json + "}";
    if (!vscode_ipc_send_message(fd, body)) return "";
    return request_id;
}

void vscode_ipc_handle_side_message(int fd, const std::string& msg, const std::string& source_client_id) {
    if (msg.find("\"type\":\"client-discovery-request\"") != std::string::npos) {
        std::string discovery_id = json_string_field(msg, "requestId");
        std::string target = json_string_field(msg, "sourceClientId");
        std::string discovery = "{\"type\":\"client-discovery-response\",\"requestId\":" + q(discovery_id) +
                                ",\"sourceClientId\":" + q(source_client_id) +
                                ",\"targetClientId\":" + q(target) +
                                ",\"method\":" + q(json_string_field(msg, "method")) +
                                ",\"canHandle\":false}";
        vscode_ipc_send_message(fd, discovery);
        return;
    }
    if (msg.find("\"type\":\"request\"") != std::string::npos) {
        std::string nested_id = json_string_field(msg, "requestId");
        std::string failure = "{\"type\":\"response\",\"requestId\":" + q(nested_id) +
                              ",\"method\":" + q(json_string_field(msg, "method")) +
                              ",\"handledByClientId\":" + q(source_client_id) +
                              ",\"resultType\":\"failure\",\"error\":{\"message\":\"MKB worker has no VS Code IPC request handler\"}}";
        vscode_ipc_send_message(fd, failure);
    }
}

bool vscode_ipc_response_is_success(const std::string& msg) {
    std::string result_type = json_string_field(msg, "resultType");
    if (result_type == "success") return true;
    if (result_type == "failure" || result_type == "error") return false;
    return msg.find("\"error\"") == std::string::npos;
}

bool is_current_vscode_bridge_session(const std::string& value) {
    return value == "linux-vscode-main" || value == "codex-vscode-current";
}

bool looks_like_codex_thread_id(const std::string& value) {
    if (value.size() != 36) return false;
    for (size_t i = 0; i < value.size(); ++i) {
        char c = value[i];
        if (i == 8 || i == 13 || i == 18 || i == 23) {
            if (c != '-') return false;
            continue;
        }
        if (!std::isxdigit(static_cast<unsigned char>(c))) return false;
    }
    return true;
}

bool can_resume_fixed_history_task(const TaskPayload& task) {
    if (is_current_vscode_bridge_session(task.session_id)) return false;
    if (looks_like_codex_thread_id(task.thread_id)) return true;
    return task.thread_id.empty() && looks_like_codex_thread_id(task.session_id);
}

TaskPayload history_resume_task(TaskPayload task) {
    if (task.thread_id.empty() && looks_like_codex_thread_id(task.session_id)) {
        task.thread_id = task.session_id;
    }
    return task;
}

std::string vscode_ipc_discover_active_conversation(int fd,
                                                    const std::string& source_client_id,
                                                    const std::string& ignored_conversation_id,
                                                    int timeout_ms = 2500) {
    auto deadline = std::chrono::steady_clock::now() + std::chrono::milliseconds(timeout_ms);
    std::string candidate;
    while (std::chrono::steady_clock::now() < deadline) {
        std::string msg;
        if (!vscode_ipc_read_message(fd, msg, 500)) continue;
        if (msg.empty()) continue;
        if (msg.find("\"thread-stream-state-changed\"") != std::string::npos) {
            std::string conversation_id = json_string_field(msg, "conversationId");
            if (!conversation_id.empty() && conversation_id != ignored_conversation_id) {
                candidate = conversation_id;
            }
        }
        vscode_ipc_handle_side_message(fd, msg, source_client_id);
    }
    return candidate;
}

bool vscode_ipc_request(int fd, const std::string& method, const std::string& params_json,
                        std::string& response, const std::string& source_client_id = "") {
    std::string request_id = vscode_ipc_send_request(fd, method, params_json, source_client_id);
    if (request_id.empty()) return false;

    auto deadline = std::chrono::steady_clock::now() + 20s;
    while (std::chrono::steady_clock::now() < deadline) {
        std::string msg;
        if (!vscode_ipc_read_message(fd, msg, 2000)) continue;
        if (msg.empty()) continue;
        if (msg.find("\"type\":\"response\"") != std::string::npos &&
            msg.find("\"requestId\":" + q(request_id)) != std::string::npos) {
            response = msg;
            return vscode_ipc_response_is_success(msg);
        }
        vscode_ipc_handle_side_message(fd, msg, source_client_id);
    }
    return false;
}

std::string vscode_text_input_json(const std::string& text) {
    return "[{\"type\":\"text\",\"text\":" + q(text) + ",\"text_elements\":[]}]";
}

std::string vscode_restore_message_json(const TaskPayload& task) {
    std::string cwd = task.project_path.empty() ? default_cwd() : task.project_path;
    if (cwd.empty()) cwd = "/";
    std::string meta = "{\"workspace_kind\":\"project\"}";
    return "{\"cwd\":" + q(cwd) +
           ",\"context\":{\"workspaceRoots\":[" + q(cwd) + "],\"collaborationMode\":null}" +
           ",\"responsesapiClientMetadata\":" + meta + "}";
}

std::string vscode_steer_params_json(const std::string& conversation_id,
                                     const TaskPayload& task,
                                     const std::string& text,
                                     const std::string& client_message_id) {
    return "{\"conversationId\":" + q(conversation_id) +
           ",\"clientUserMessageId\":" + q(client_message_id) +
           ",\"input\":" + vscode_text_input_json(text) +
           ",\"serviceTier\":null,\"attachments\":[]" +
           ",\"restoreMessage\":" + vscode_restore_message_json(task) + "}";
}

bool vscode_ipc_message_for_conversation(const std::string& msg, const std::string& conversation_id) {
    return msg.find("\"conversationId\":" + q(conversation_id)) != std::string::npos;
}

bool vscode_ipc_message_marks_turn_done(const std::string& msg, const std::string& conversation_id) {
    if (!vscode_ipc_message_for_conversation(msg, conversation_id)) return false;
    if (msg.find("\"thread-stream-state-changed\"") == std::string::npos) return false;
    return msg.find("\"status\":\"completed\"") != std::string::npos ||
           msg.find("\"status\":\"failed\"") != std::string::npos ||
           msg.find("\"status\":\"interrupted\"") != std::string::npos ||
           msg.find("\\\"status\\\":\\\"completed\\\"") != std::string::npos ||
           msg.find("\\\"status\\\":\\\"failed\\\"") != std::string::npos ||
           msg.find("\\\"status\\\":\\\"interrupted\\\"") != std::string::npos;
}

bool run_vscode_ipc_task(const Url& broker, const std::string& worker_id, const TaskPayload& task) {
    std::string socket_path = default_vscode_ipc_socket_path();
    std::string error;
    int fd = connect_unix_socket(socket_path, error);
    if (fd < 0) {
        post_event(broker, worker_id, task, "vscode.ipc.unavailable",
                   "VS Code Codex IPC socket unavailable: " + socket_path + " (" + error + ")",
                   "{\"socket\":" + q(socket_path) + ",\"error\":" + q(error) + "}");
        return false;
    }

    post_event(broker, worker_id, task, "codex.thinking.delta",
               "Forwarding prompt through VS Code Codex IPC",
               "{\"delta\":\"Forwarding prompt through VS Code Codex IPC\",\"transport\":\"vscode-ipc\"}");
    std::string init_response;
    std::string client_type = env_or("MKB_CODEX_WORKER_VSCODE_IPC_CLIENT_TYPE", "codex-desktop");
    if (!vscode_ipc_request(fd, "initialize", "{\"clientType\":" + q(client_type) + "}", init_response)) {
        close(fd);
        post_event(broker, worker_id, task, "vscode.ipc.failed", "VS Code IPC initialize failed",
                   "{\"response\":" + q(truncate_for_event(init_response)) + "}");
        return false;
    }
    std::string client_id = json_string_field(init_response, "clientId");
    std::string conversation_id = task.thread_id.empty() ? task.session_id : task.thread_id;
    if (is_current_vscode_bridge_session(task.session_id)) {
        std::string placeholder_id = task.session_id;
        std::string discovered_conversation_id = vscode_ipc_discover_active_conversation(fd, client_id, placeholder_id);
        if (!discovered_conversation_id.empty()) {
            post_event(broker, worker_id, task, "vscode.ipc.conversation.selected",
                       "Selected active VS Code Codex conversation",
                       "{\"transport\":\"vscode-ipc\",\"placeholder\":" + q(placeholder_id) +
                       ",\"conversation_id\":" + q(discovered_conversation_id) + "}");
            conversation_id = discovered_conversation_id;
        } else {
            post_event(broker, worker_id, task, "vscode.ipc.conversation.missing",
                       "No active VS Code Codex conversation broadcast observed",
                       "{\"transport\":\"vscode-ipc\",\"placeholder\":" + q(placeholder_id) +
                       ",\"fallback_conversation_id\":" + q(conversation_id) + "}");
        }
    }
    std::string params = "{\"conversationId\":" + q(conversation_id) +
                         ",\"turnStartParams\":{\"input\":" + vscode_text_input_json(task.prompt) + "}}";
    std::string start_request_id = vscode_ipc_send_request(fd, "thread-follower-start-turn", params, client_id);
    if (start_request_id.empty()) {
        close(fd);
        post_event(broker, worker_id, task, "vscode.ipc.failed", "VS Code IPC start turn send failed",
                   "{\"conversation_id\":" + q(conversation_id) + "}");
        return false;
    }

    bool start_acknowledged = false;
    bool saw_stream_change = false;
    bool done_seen = false;
    auto started_at = std::chrono::steady_clock::now();
    auto last_activity = started_at;
    auto last_control = started_at - 2s;
    auto last_done_check = started_at - 2s;
    auto last_output_check = started_at - 2s;
    int active_ms = std::atoi(env_or("MKB_CODEX_WORKER_VSCODE_ACTIVE_MS", "300000").c_str());
    int idle_after_ack_ms = std::atoi(env_or("MKB_CODEX_WORKER_VSCODE_IDLE_AFTER_ACK_MS", "15000").c_str());
    int guide_grace_ms = std::atoi(env_or("MKB_CODEX_WORKER_VSCODE_GUIDE_GRACE_MS", "45000").c_str());
    if (active_ms < 10000) active_ms = 10000;
    if (idle_after_ack_ms < 1000) idle_after_ack_ms = 1000;
    if (guide_grace_ms < 5000) guide_grace_ms = 5000;

    post_event(broker, worker_id, task, "vscode.ipc.sent", "Prompt sent through VS Code Codex IPC",
               "{\"transport\":\"vscode-ipc\",\"socket\":" + q(socket_path) +
               ",\"conversation_id\":" + q(conversation_id) + "}");

    while (true) {
        auto now = std::chrono::steady_clock::now();
        if (now - last_control > 750ms) {
            last_control = now;
            ControlState control = fetch_control(broker, task);
            if (control.cancelled) {
                std::string interrupt_params = "{\"conversationId\":" + q(conversation_id) + "}";
                std::string interrupt_request_id = vscode_ipc_send_request(
                    fd, "thread-follower-interrupt-turn", interrupt_params, client_id);
                bool sent = !interrupt_request_id.empty();
                post_event(broker, worker_id, task, sent ? "task.interrupted" : "task.failed",
                           sent ? "Task interrupted by mobile client" : "VS Code IPC interrupt send failed",
                           "{\"transport\":\"vscode-ipc\",\"conversation_id\":" + q(conversation_id) +
                           ",\"request_id\":" + q(interrupt_request_id) + "}");
                close(fd);
                return sent;
            }
            if (control.steer_id > 0 && !control.steer_text.empty()) {
                std::string steer_params = vscode_steer_params_json(
                    conversation_id, task, control.steer_text,
                    task.task_id + "-steer-" + std::to_string(control.steer_id));
                std::string steer_request_id = vscode_ipc_send_request(
                    fd, "thread-follower-steer-turn", steer_params, client_id);
                bool steered = !steer_request_id.empty();
                post_event(broker, worker_id, task,
                           steered ? "turn.steer.sent" : "turn.steer.failed",
                           steered ? control.steer_text : "VS Code IPC steer send failed",
                           "{\"transport\":\"vscode-ipc\",\"conversation_id\":" + q(conversation_id) +
                           ",\"steer_id\":" + std::to_string(control.steer_id) +
                           ",\"request_id\":" + q(steer_request_id) + "}");
                if (steered) done_seen = false;
                last_activity = std::chrono::steady_clock::now();
            }
        }

        std::string msg;
        if (vscode_ipc_read_message(fd, msg, 250)) {
            if (msg.empty()) continue;
            last_activity = std::chrono::steady_clock::now();
            if (msg.find("\"type\":\"response\"") != std::string::npos &&
                msg.find("\"requestId\":" + q(start_request_id)) != std::string::npos) {
                if (!vscode_ipc_response_is_success(msg)) {
                    close(fd);
                    post_event(broker, worker_id, task, "vscode.ipc.failed", "VS Code IPC start turn failed",
                               "{\"conversation_id\":" + q(conversation_id) +
                               ",\"response\":" + q(truncate_for_event(msg)) + "}");
                    return false;
                }
                start_acknowledged = true;
                continue;
            }
            if (vscode_ipc_message_for_conversation(msg, conversation_id) &&
                msg.find("\"thread-stream-state-changed\"") != std::string::npos) {
                saw_stream_change = true;
            }
            if (vscode_ipc_message_marks_turn_done(msg, conversation_id)) {
                done_seen = true;
                continue;
            }
            vscode_ipc_handle_side_message(fd, msg, client_id);
        }

        now = std::chrono::steady_clock::now();
        if (now - last_output_check > 2s) {
            last_output_check = now;
            if (task_has_output_event(broker, task)) {
                close(fd);
                post_event(broker, worker_id, task, "task.completed", "Task completed");
                return true;
            }
        }
        if (done_seen && now - last_done_check > 2s) {
            last_done_check = now;
            if (task_has_output_event(broker, task)) {
                close(fd);
                post_event(broker, worker_id, task, "task.completed", "Task completed");
                return true;
            }
        }
        if (now - started_at > std::chrono::milliseconds(active_ms)) {
            close(fd);
            post_event(broker, worker_id, task, "task.completed", "VS Code IPC active window ended",
                       "{\"transport\":\"vscode-ipc\",\"conversation_id\":" + q(conversation_id) +
                       ",\"timeout_ms\":" + std::to_string(active_ms) + "}");
            return true;
        }
        if (done_seen && now - started_at > std::chrono::milliseconds(guide_grace_ms)) {
            close(fd);
            post_event(broker, worker_id, task, "task.completed", "VS Code IPC done grace ended",
                       "{\"transport\":\"vscode-ipc\",\"conversation_id\":" + q(conversation_id) +
                       ",\"grace_ms\":" + std::to_string(guide_grace_ms) + "}");
            return true;
        }
        if (start_acknowledged && !saw_stream_change &&
            now - last_activity > std::chrono::milliseconds(idle_after_ack_ms)) {
            close(fd);
            post_event(broker, worker_id, task, "task.completed", "VS Code IPC task accepted",
                       "{\"transport\":\"vscode-ipc\",\"conversation_id\":" + q(conversation_id) + "}");
            return true;
        }
    }

    close(fd);
    return true;
}

void consume_codex_stdout_line(const Url& broker, const std::string& worker_id, const TaskPayload& task, const std::string& line) {
    if (line.empty()) return;
    if (line.front() != '{') {
        post_event(broker, worker_id, task, "codex.diagnostic", line, "{\"stream\":\"stdout\"}");
        return;
    }
    std::string top_type = json_string_field(line, "type");
    if (json_has(line, "\"type\":\"thread.started\"")) {
        auto thread_id = json_string_field(line, "thread_id");
        post_event(broker, worker_id, task, "codex.thread.started", thread_id, "{\"thread_id\":" + q(thread_id) + "}", "\"thread_id\":" + q(thread_id));
        return;
    }
    if (json_has(line, "\"type\":\"turn.started\"")) {
        post_event(broker, worker_id, task, "codex.thinking.delta", "Codex started on local worker", "{\"delta\":\"Codex started on local worker\"}");
        return;
    }
    if (json_has(line, "\"type\":\"item.completed\"") && json_has(line, "\"type\":\"agent_message\"")) {
        auto text = json_string_field(line, "text");
        if (!text.empty()) {
            post_event(broker, worker_id, task, "codex.output.delta", text, "{\"delta\":" + q(text) + "}");
        }
        return;
    }
    if (json_has(line, "\"type\":\"item.completed\"") && json_has(line, "\"type\":\"error\"")) {
        post_event(broker, worker_id, task, "codex.diagnostic", truncate_for_event(line), "{\"stream\":\"stdout\",\"raw\":" + q(truncate_for_event(line)) + "}");
        return;
    }
    if (json_has(line, "\"type\":\"turn.completed\"")) {
        post_event(broker, worker_id, task, "codex.turn.completed", "Codex turn completed");
        return;
    }
    if (top_type == "turn.failed" || top_type == "error") {
        post_event(broker, worker_id, task, "codex.error", line, "{\"raw\":" + q(line) + "}");
        return;
    }
}

std::string turn_started_turn_id(const std::string& body) {
    std::regex re("\"turn\"\\s*:\\s*\\{[^\\}]*\"id\"\\s*:\\s*\"((?:\\\\.|[^\"])*)\"");
    std::smatch m;
    if (!std::regex_search(body, m, re)) return "";
    return m[1].str();
}

std::string resume_active_turn_id(const std::string& body) {
    std::smatch m;
    std::regex id_then_status("\"turn\"\\s*:\\s*\\{[^\\}]*\"id\"\\s*:\\s*\"((?:\\\\.|[^\"])*)\"[^\\}]*\"status\"\\s*:\\s*\"inProgress\"");
    if (std::regex_search(body, m, id_then_status)) return m[1].str();
    std::regex status_then_id("\"turn\"\\s*:\\s*\\{[^\\}]*\"status\"\\s*:\\s*\"inProgress\"[^\\}]*\"id\"\\s*:\\s*\"((?:\\\\.|[^\"])*)\"");
    if (std::regex_search(body, m, status_then_id)) return m[1].str();
    return "";
}

std::string appserver_request(int id, const std::string& method, const std::string& params_json) {
    return "{\"id\":" + std::to_string(id) + ",\"method\":" + q(method) + ",\"params\":" + params_json + "}";
}

bool appserver_is_response_for(const std::string& msg, int id) {
    return msg.find("\"id\":" + std::to_string(id)) != std::string::npos ||
           msg.find("\"id\": " + std::to_string(id)) != std::string::npos;
}

bool appserver_has_top_level_error(const std::string& msg) {
    bool in_string = false;
    bool escape = false;
    int depth = 0;
    for (size_t i = 0; i < msg.size(); ++i) {
        char c = msg[i];
        if (in_string) {
            if (escape) {
                escape = false;
            } else if (c == '\\') {
                escape = true;
            } else if (c == '"') {
                in_string = false;
            }
            continue;
        }
        if (c == '"') {
            size_t end = i + 1;
            bool key_escape = false;
            for (; end < msg.size(); ++end) {
                char kc = msg[end];
                if (key_escape) {
                    key_escape = false;
                } else if (kc == '\\') {
                    key_escape = true;
                } else if (kc == '"') {
                    break;
                }
            }
            if (depth == 1 && end < msg.size() && msg.compare(i + 1, end - i - 1, "error") == 0) {
                size_t j = end + 1;
                while (j < msg.size() && std::isspace(static_cast<unsigned char>(msg[j]))) ++j;
                if (j < msg.size() && msg[j] == ':') ++j;
                while (j < msg.size() && std::isspace(static_cast<unsigned char>(msg[j]))) ++j;
                return msg.compare(j, 4, "null") != 0;
            }
            i = end;
            continue;
        }
        if (c == '{') ++depth;
        else if (c == '}') --depth;
    }
    return false;
}

void handle_appserver_notification(const Url& broker, const std::string& worker_id, const TaskPayload& task, const std::string& msg, std::string& active_turn_id, bool& completed, bool& failed) {
    if (json_has(msg, "\"method\":\"turn/started\"")) {
        std::string thread_id = json_string_field(msg, "threadId", task.thread_id);
        std::string turn_id = turn_started_turn_id(msg);
        if (!turn_id.empty()) active_turn_id = turn_id;
        post_event(broker, worker_id, task, "codex.turn.started", "Codex turn started",
                   "{\"thread_id\":" + q(thread_id) + ",\"turn_id\":" + q(turn_id) + "}",
                   "\"thread_id\":" + q(thread_id) + ",\"turn_id\":" + q(turn_id));
        return;
    }
    if (json_has(msg, "\"method\":\"item/agentMessage/delta\"")) {
        std::string delta = json_string_field(msg, "delta");
        if (!delta.empty()) post_event(broker, worker_id, task, "codex.output.delta", delta, "{\"delta\":" + q(delta) + "}");
        return;
    }
    if (json_has(msg, "\"method\":\"turn/completed\"")) {
        completed = true;
        post_event(broker, worker_id, task, "codex.turn.completed", "Codex turn completed");
        return;
    }
    if (json_has(msg, "\"method\":\"error\"") || appserver_has_top_level_error(msg)) {
        failed = true;
        post_event(broker, worker_id, task, "codex.error", truncate_for_event(msg), "{\"raw\":" + q(truncate_for_event(msg)) + "}");
    }
}

bool appserver_call(int fd, int id, const std::string& method, const std::string& params_json,
                    const Url& broker, const std::string& worker_id, const TaskPayload& task,
                    std::string& active_turn_id, bool& completed, bool& failed,
                    std::string* response = nullptr, int timeout_ms = 30000) {
    if (!websocket_send_text(fd, appserver_request(id, method, params_json))) return false;
    auto deadline = std::chrono::steady_clock::now() + std::chrono::milliseconds(timeout_ms);
    while (std::chrono::steady_clock::now() < deadline) {
        std::string msg;
        int rc = websocket_read_text(fd, msg, 500);
        if (rc == 0) continue;
        if (rc < 0) return false;
        if (rc == 2) continue;
        if (appserver_is_response_for(msg, id)) {
            if (response) *response = msg;
            if (appserver_has_top_level_error(msg)) {
                failed = true;
                post_event(broker, worker_id, task, "codex.error", truncate_for_event(msg), "{\"raw\":" + q(truncate_for_event(msg)) + "}");
                return false;
            }
            return true;
        }
        handle_appserver_notification(broker, worker_id, task, msg, active_turn_id, completed, failed);
    }
    return false;
}

bool run_appserver_task(const Url& broker, const std::string& worker_id, const TaskPayload& task) {
    std::string endpoint_url = env_or("MKB_CODEX_WORKER_APP_SERVER_URL");
    if (endpoint_url.empty()) return false;
    std::string thread_id = env_or("MKB_CODEX_WORKER_THREAD_ID", env_or("MKB_CODEX_WORKER_RESUME_THREAD_ID", task.thread_id));
    if (thread_id.empty()) {
        post_event(broker, worker_id, task, "task.failed", "App-server mode requires a Codex thread id", "{\"error\":\"missing thread id\"}");
        return true;
    }

    std::string error;
    AppServerEndpoint endpoint = parse_app_server_endpoint(endpoint_url);
    int fd = connect_app_server(endpoint, error);
    if (fd < 0) {
        post_event(broker, worker_id, task, "task.failed", "Failed to connect app-server: " + error, "{\"error\":" + q(error) + "}");
        return true;
    }

    post_event(broker, worker_id, task, "codex.thinking.delta", "Connected to Codex app-server", "{\"delta\":\"Connected to Codex app-server\"}");
    std::string active_turn_id = task.active_turn_id;
    bool completed = false;
    bool failed = false;
    int id = 1;
    std::string response;
    std::string init_params = "{\"clientInfo\":{\"name\":\"mkb-codex-worker\",\"title\":\"MKB Codex Worker\",\"version\":\"0.1\"},\"capabilities\":{\"experimentalApi\":true,\"requestAttestation\":false}}";
    if (!appserver_call(fd, id++, "initialize", init_params, broker, worker_id, task, active_turn_id, completed, failed, &response)) {
        close(fd);
        post_event(broker, worker_id, task, "task.failed", "Codex app-server initialize failed");
        return true;
    }
    websocket_send_text(fd, "{\"method\":\"initialized\"}");

    std::string resume_params = "{\"threadId\":" + q(thread_id);
    std::string cwd = task.project_path.empty() ? default_cwd() : task.project_path;
    if (!cwd.empty()) resume_params += ",\"cwd\":" + q(cwd);
    if (!task.model.empty()) resume_params += ",\"model\":" + q(task.model);
    resume_params += "}";
    if (!appserver_call(fd, id++, "thread/resume", resume_params, broker, worker_id, task, active_turn_id, completed, failed, &response)) {
        close(fd);
        post_event(broker, worker_id, task, "task.failed", "Codex app-server thread/resume failed");
        return true;
    }
    if (active_turn_id.empty()) {
        active_turn_id = resume_active_turn_id(response);
    }
    post_event(broker, worker_id, task, "codex.thread.started", thread_id, "{\"thread_id\":" + q(thread_id) + "}", "\"thread_id\":" + q(thread_id));

    auto make_input = [](const std::string& text) {
        return "[{\"type\":\"text\",\"text\":" + q(text) + ",\"text_elements\":[]}]";
    };
    std::string input = make_input(task.prompt);
    std::string method;
    auto make_start_params = [&]() {
        std::string params = "{\"threadId\":" + q(thread_id) + ",\"clientUserMessageId\":" + q(task.task_id) +
                             ",\"input\":" + input;
        if (!cwd.empty()) params += ",\"cwd\":" + q(cwd);
        if (!task.model.empty()) params += ",\"model\":" + q(task.model);
        if (!task.reasoning_effort.empty()) params += ",\"effort\":" + q(task.reasoning_effort);
        params += "}";
        return params;
    };
    auto make_steer_params = [&]() {
        return "{\"threadId\":" + q(thread_id) + ",\"clientUserMessageId\":" + q(task.task_id) +
               ",\"input\":" + input + ",\"expectedTurnId\":" + q(active_turn_id) + "}";
    };
    std::string turn_params;
    if ((task.mode == "insert" || task.mode == "normal") && !active_turn_id.empty()) {
        method = "turn/steer";
        turn_params = make_steer_params();
    } else {
        method = "turn/start";
        turn_params = make_start_params();
    }
    int pending_request_id = id++;
    if (!websocket_send_text(fd, appserver_request(pending_request_id, method, turn_params))) {
        close(fd);
        post_event(broker, worker_id, task, "task.failed", "Failed to send " + method + " to Codex app-server");
        return true;
    }

    auto last_control = std::chrono::steady_clock::now() - 2s;
    while (!completed && !failed) {
        auto now = std::chrono::steady_clock::now();
        if (now - last_control > 750ms) {
            last_control = now;
            ControlState control = fetch_control(broker, task);
            if (control.cancelled) {
                if (!active_turn_id.empty()) {
                    std::string params = "{\"threadId\":" + q(thread_id) + ",\"turnId\":" + q(active_turn_id) + "}";
                    websocket_send_text(fd, appserver_request(id++, "turn/interrupt", params));
                }
                post_event(broker, worker_id, task, "task.interrupted", "Task interrupted by mobile client");
                close(fd);
                return true;
            }
            if (control.steer_id > 0 && !control.steer_text.empty()) {
                if (active_turn_id.empty()) {
                    post_event(broker, worker_id, task, "turn.steer.failed", "No active turn to steer",
                               "{\"steer_id\":" + std::to_string(control.steer_id) + "}");
                } else {
                    std::string steer_params = "{\"threadId\":" + q(thread_id) +
                                               ",\"clientUserMessageId\":" + q(task.task_id + "-steer-" + std::to_string(control.steer_id)) +
                                               ",\"input\":" + make_input(control.steer_text) +
                                               ",\"expectedTurnId\":" + q(active_turn_id) + "}";
                    if (websocket_send_text(fd, appserver_request(id++, "turn/steer", steer_params))) {
                        post_event(broker, worker_id, task, "turn.steer.sent", control.steer_text,
                                   "{\"steer_id\":" + std::to_string(control.steer_id) +
                                   ",\"turn_id\":" + q(active_turn_id) + "}");
                    } else {
                        post_event(broker, worker_id, task, "turn.steer.failed", "Failed to send turn/steer",
                                   "{\"steer_id\":" + std::to_string(control.steer_id) + "}");
                    }
                }
            }
        }
        std::string msg;
        int rc = websocket_read_text(fd, msg, 500);
        if (rc == 0 || rc == 2) continue;
        if (rc < 0) {
            failed = true;
            break;
        }
        if (appserver_is_response_for(msg, pending_request_id) && appserver_has_top_level_error(msg)) {
            if (method == "turn/steer" && msg.find("no active turn") != std::string::npos) {
                post_event(broker, worker_id, task, "codex.diagnostic", "No active turn to steer; retrying as a new turn", "{\"transport\":\"app-server\",\"fallback\":\"turn/start\"}");
                method = "turn/start";
                turn_params = make_start_params();
                failed = false;
                completed = false;
                pending_request_id = id++;
                if (!websocket_send_text(fd, appserver_request(pending_request_id, method, turn_params))) {
                    failed = true;
                    post_event(broker, worker_id, task, "task.failed", "Failed to send turn/start to Codex app-server");
                }
                continue;
            }
            failed = true;
            post_event(broker, worker_id, task, "codex.error", truncate_for_event(msg), "{\"raw\":" + q(truncate_for_event(msg)) + "}");
            continue;
        }
        handle_appserver_notification(broker, worker_id, task, msg, active_turn_id, completed, failed);
    }

    close(fd);
    if (completed) {
        post_event(broker, worker_id, task, "task.completed", "Task completed");
        return true;
    }
    post_event(broker, worker_id, task, "task.failed", "Codex app-server turn failed or disconnected");
    return true;
}

bool inject_prompt_into_codex_desktop(const Url& broker, const std::string& worker_id, const TaskPayload& task) {
    post_event(broker, worker_id, task, "codex.thinking.delta", "Forwarding prompt to Codex Desktop", "{\"delta\":\"Forwarding prompt to Codex Desktop\"}");

    std::string script_path = "/tmp/mkb_codex_inject_" + std::to_string(getpid()) + "_" + task.task_id + ".applescript";
    {
        std::ofstream script(script_path);
        script
            << "set the clipboard to " << applescript_quote(task.prompt) << "\n"
            << "tell application \"Codex\" to activate\n"
            << "delay 0.25\n"
            << "tell application \"System Events\"\n"
            << "  tell process \"Codex\"\n"
            << "    set frontmost to true\n"
            << "    key code 53\n"
            << "    delay 0.1\n"
            << "    set p to position of window 1\n"
            << "    set s to size of window 1\n"
            << "    click at {((item 1 of p) + ((item 1 of s) / 2)), ((item 2 of p) + (item 2 of s) - 105)}\n"
            << "    delay 0.2\n"
            << "    keystroke \"v\" using command down\n"
            << "    delay 0.2\n"
            << "    key code 36\n"
            << "  end tell\n"
            << "end tell\n";
    }

    CommandResult result = run_command_capture("/usr/bin/osascript " + shell_quote(script_path));
    if (result.status != 0) {
        std::string command = "/bin/launchctl asuser " + std::to_string(getuid()) + " /usr/bin/osascript " + shell_quote(script_path);
        CommandResult fallback = run_command_capture(command);
        if (fallback.status == 0) result = fallback;
        else result.output = "direct osascript: " + truncate_for_event(result.output, 600) + "\nlaunchctl asuser: " + truncate_for_event(fallback.output, 600);
        result.status = fallback.status;
    }

    std::this_thread::sleep_for(500ms);
    unlink(script_path.c_str());

    if (result.status != 0) {
        std::string detail = truncate_for_event(result.output.empty() ? "osascript failed without output" : result.output);
        post_event(broker, worker_id, task, "task.failed", "Failed to inject prompt into Codex Desktop: " + detail,
                   "{\"error\":" + q(detail) + "}");
        return false;
    }
    std::string detail = truncate_for_event(result.output);
    post_event(broker, worker_id, task, "desktop.injected", "Prompt injected into Codex Desktop",
               "{\"target\":\"Codex Desktop\",\"method\":\"osascript\",\"output\":" + q(detail) + "}");
    if (!transcript_user_matched(broker, task)) {
        post_event(broker, worker_id, task, "task.failed",
                   "Desktop UI injection did not appear in Codex transcript",
                   "{\"error\":\"missing transcript.user.matched after desktop.injected\"}");
        return false;
    }
    return true;
}

bool run_codex_task(const Url& broker, const std::string& worker_id, const TaskPayload& task) {
    if (!env_or("MKB_CODEX_WORKER_APP_SERVER_URL").empty()) {
        return run_appserver_task(broker, worker_id, task);
    }

    TaskPayload effective_task = task;
    bool fixed_history_resume = false;
    std::string vscode_ipc_mode = env_or("MKB_CODEX_WORKER_VSCODE_IPC");
    std::string vscode_ipc_socket = default_vscode_ipc_socket_path();
    if (vscode_ipc_mode == "1" || (!vscode_ipc_mode.empty() && vscode_ipc_mode != "0") || access(vscode_ipc_socket.c_str(), F_OK) == 0) {
        if (run_vscode_ipc_task(broker, worker_id, task)) return true;
        fixed_history_resume = can_resume_fixed_history_task(task);
        if (fixed_history_resume) {
            effective_task = history_resume_task(task);
            post_event(broker, worker_id, task, "codex.diagnostic",
                       "VS Code IPC follower unavailable; resuming fixed Codex history thread",
                       "{\"transport\":\"codex-cli-resume\",\"thread_id\":" + q(effective_task.thread_id) + "}");
        } else if (env_or("MKB_CODEX_WORKER_DESKTOP_INJECT") != "1") {
            post_event(broker, worker_id, task, "task.failed", "No usable Codex transport after VS Code IPC failed");
            return false;
        }
        post_event(broker, worker_id, task, "codex.diagnostic", "VS Code IPC unavailable; falling back to configured transport", "{\"transport\":\"vscode-ipc\"}");
    }
    if (env_or("MKB_CODEX_WORKER_DESKTOP_INJECT") == "1") {
        return inject_prompt_into_codex_desktop(broker, worker_id, task);
    }
    if (resume_desktop_thread_mode()) {
        post_event(broker, worker_id, task, "codex.thinking.delta", "Forwarding prompt to current Codex Desktop thread", "{\"delta\":\"Forwarding prompt to current Codex Desktop thread\"}");
    } else {
        post_event(broker, worker_id, task, "codex.thinking.delta", "Local worker accepted task", "{\"delta\":\"Local worker accepted task\"}");
    }
    CodexSpawn child = spawn_codex_process(effective_task);
    if (child.pid < 0) {
        post_event(broker, worker_id, task, "task.failed", child.error);
        return false;
    }

    std::string prompt = task.prompt;
    if (!resume_desktop_thread_mode()) {
        prompt += "\n\n[Mobile worker context]\n";
        prompt += "task_id=" + task.task_id + "\n";
        prompt += "project_alias=" + task.project_alias + "\n";
        prompt += "session_id=" + task.session_id + "\n";
        prompt += "mode=" + task.mode + "\n";
        if (!task.model.empty()) prompt += "model=" + task.model + "\n";
        if (!task.reasoning_effort.empty()) prompt += "reasoning_effort=" + task.reasoning_effort + "\n";
        prompt += "worker_id=" + worker_id + "\n";
    }
    const char* write_ptr = prompt.data();
    size_t remaining = prompt.size();
    while (remaining > 0) {
        ssize_t n = write(child.stdin_fd, write_ptr, remaining);
        if (n <= 0) break;
        write_ptr += n;
        remaining -= static_cast<size_t>(n);
    }
    close(child.stdin_fd);

    std::string out_buffer;
    std::string err_buffer;
    bool stdout_open = child.stdout_fd >= 0;
    bool stderr_open = child.stderr_fd >= 0;
    auto last_control = std::chrono::steady_clock::now() - 2s;
    bool cancelled = false;

    auto drain = [&](int fd, std::string& buffer, bool is_stderr) {
        char tmp[4096];
        while (true) {
            ssize_t n = read(fd, tmp, sizeof(tmp));
            if (n > 0) {
                buffer.append(tmp, n);
                size_t pos;
                while ((pos = buffer.find('\n')) != std::string::npos) {
                    std::string line = buffer.substr(0, pos);
                    if (!line.empty() && line.back() == '\r') line.pop_back();
                    buffer.erase(0, pos + 1);
                    if (is_stderr) {
                        if (should_emit_diagnostic(line)) post_event(broker, worker_id, task, "codex.diagnostic", line, "{\"stream\":\"stderr\"}");
                    } else {
                        consume_codex_stdout_line(broker, worker_id, task, line);
                    }
                }
            } else if (n == 0) {
                if (is_stderr) stderr_open = false; else stdout_open = false;
                close(fd);
                break;
            } else {
                if (errno == EAGAIN || errno == EWOULDBLOCK) break;
                if (is_stderr) stderr_open = false; else stdout_open = false;
                close(fd);
                break;
            }
        }
    };

    while (stdout_open || stderr_open) {
        auto now = std::chrono::steady_clock::now();
        if (now - last_control > 750ms) {
            last_control = now;
            if (control_cancelled(broker, task)) {
                cancelled = true;
                kill(-child.pid, SIGTERM);
            }
        }
        fd_set readfds;
        FD_ZERO(&readfds);
        int max_fd = -1;
        if (stdout_open) {
            FD_SET(child.stdout_fd, &readfds);
            max_fd = std::max(max_fd, child.stdout_fd);
        }
        if (stderr_open) {
            FD_SET(child.stderr_fd, &readfds);
            max_fd = std::max(max_fd, child.stderr_fd);
        }
        timeval tv{};
        tv.tv_sec = 0;
        tv.tv_usec = 250000;
        int ready = select(max_fd + 1, &readfds, nullptr, nullptr, &tv);
        if (ready > 0) {
            if (stdout_open && FD_ISSET(child.stdout_fd, &readfds)) drain(child.stdout_fd, out_buffer, false);
            if (stderr_open && FD_ISSET(child.stderr_fd, &readfds)) drain(child.stderr_fd, err_buffer, true);
        }
    }
    if (!out_buffer.empty()) consume_codex_stdout_line(broker, worker_id, task, out_buffer);
    if (should_emit_diagnostic(err_buffer)) post_event(broker, worker_id, task, "codex.diagnostic", err_buffer, "{\"stream\":\"stderr\"}");

    int status = 0;
    waitpid(child.pid, &status, 0);
    if (cancelled) {
        post_event(broker, worker_id, task, "task.interrupted", "Task interrupted by mobile client");
        return true;
    }
    if (WIFEXITED(status) && WEXITSTATUS(status) == 0) {
        post_event(broker, worker_id, task, "task.completed", "Task completed");
        return true;
    }
    post_event(broker, worker_id, task, "task.failed", "Codex process exited with status " + std::to_string(status));
    return false;
}

bool parse_task(const std::string& body, TaskPayload& task) {
    if (json_has(body, "\"task\":null")) return false;
    task.task_id = json_string_field(body, "task_id");
    task.session_id = json_string_field(body, "session_id");
    task.project_alias = json_string_field(body, "project_alias");
    task.prompt = json_string_field(body, "prompt");
    task.mode = json_string_field(body, "mode");
    task.model = json_string_field(body, "model");
    task.reasoning_effort = json_string_field(body, "reasoning_effort", json_string_field(body, "reasoning", ""));
    task.project_path = json_string_field(body, "path");
    task.thread_id = json_string_field(body, "thread_id", json_string_field(body, "threadId", ""));
    task.active_turn_id = json_string_field(body, "active_turn_id");
    task.cancelled = json_bool_field(body, "cancelled");
    return !task.task_id.empty();
}

std::string task_fingerprint(const TaskPayload& task) {
    return task.task_id + "\n" + task.session_id + "\n" + task.prompt;
}

std::string hostname_string() {
    char buf[256];
    if (gethostname(buf, sizeof(buf)) == 0) return buf;
    return "mac-worker";
}

void on_signal(int) {
    g_running = false;
}

} // namespace

int main(int argc, char** argv) {
    std::srand(static_cast<unsigned int>(std::time(nullptr) ^ getpid()));
    std::signal(SIGINT, on_signal);
    std::signal(SIGTERM, on_signal);
    std::signal(SIGPIPE, SIG_IGN);

    std::string broker_url = argc > 1 ? argv[1] : env_or("MKB_CODEX_WORKER_BROKER", "http://124.174.101.22:886");
    Url broker = parse_url(broker_url);
    std::string worker_id = env_or("MKB_CODEX_WORKER_ID", hostname_string() + "-" + std::to_string(getpid()));
    std::string label = env_or("MKB_CODEX_WORKER_LABEL", "Mac Codex Worker");
    int idle_sleep_ms = std::atoi(env_or("MKB_CODEX_WORKER_IDLE_MS", "1500").c_str());
    if (idle_sleep_ms <= 0) idle_sleep_ms = 1500;

    std::cerr << "mkb_codex_worker connecting to " << broker_url << " as " << worker_id << "\n";
    std::string register_body = "{\"worker_id\":" + q(worker_id) + ",\"label\":" + q(label) + "}";
    auto reg = http_request(broker, "POST", "/api/workers/register", register_body);
    if (reg.status < 200 || reg.status >= 300) {
        std::cerr << "worker register failed status=" << reg.status << " error=" << reg.error << " body=" << reg.body << "\n";
        return 1;
    }
    std::cerr << "registered: " << reg.body << "\n";

    std::set<std::string> completed_task_fingerprints;
    while (g_running.load()) {
        std::string path = "/api/workers/tasks?worker_id=" + url_encode(worker_id);
        auto res = http_request(broker, "GET", path);
        if (res.status != 200) {
            std::cerr << "task poll failed status=" << res.status << " error=" << res.error << "\n";
            std::this_thread::sleep_for(3s);
            continue;
        }
        TaskPayload task;
        if (!parse_task(res.body, task)) {
            http_request(broker, "POST", "/api/workers/heartbeat", "{\"worker_id\":" + q(worker_id) + ",\"label\":" + q(label) + ",\"status\":\"online\"}");
            std::this_thread::sleep_for(std::chrono::milliseconds(idle_sleep_ms));
            continue;
        }
        std::cerr << "accepted task " << task.task_id << " session=" << task.session_id << " project=" << task.project_alias << "\n";
        if (task.cancelled) {
            post_event(broker, worker_id, task, "task.interrupted", "Task interrupted by mobile client");
            std::this_thread::sleep_for(std::chrono::milliseconds(idle_sleep_ms));
            continue;
        }
        std::string fingerprint = task_fingerprint(task);
        if (completed_task_fingerprints.count(fingerprint)) {
            post_event(broker, worker_id, task, "task.completed", "Task completed");
            std::this_thread::sleep_for(std::chrono::milliseconds(idle_sleep_ms));
            continue;
        }
        if (run_codex_task(broker, worker_id, task)) {
            completed_task_fingerprints.insert(fingerprint);
        }
    }

    std::cerr << "mkb_codex_worker stopped\n";
    return 0;
}
