#include <arpa/inet.h>
#include <fcntl.h>
#include <netinet/in.h>
#include <sys/select.h>
#include <sys/socket.h>
#include <sys/wait.h>
#include <unistd.h>

#include <algorithm>
#include <atomic>
#include <chrono>
#include <condition_variable>
#include <cctype>
#include <csignal>
#include <cstdlib>
#include <cstring>
#include <ctime>
#include <fstream>
#include <iostream>
#include <map>
#include <mutex>
#include <regex>
#include <set>
#include <sstream>
#include <string>
#include <sys/stat.h>
#include <thread>
#include <vector>

using namespace std::chrono_literals;

namespace {

struct Endpoint {
    std::string endpoint_id = "company-main";
    std::string label = "Company Codex Relay";
    std::string status = "online";
};

struct Project {
    std::string alias = "codex-database";
    std::string endpoint_id = "company-main";
    std::string path;
    std::string mode = "headless";
};

struct Session {
    std::string session_id;
    std::string endpoint_id = "company-main";
    std::string source = "mkb";
    std::string title;
    std::string cwd;
    std::string status = "idle";
    std::string thread_id;
    std::string active_turn_id;
    std::string updated_at;
};

struct TaskRecord {
    std::string task_id;
    std::string endpoint_id = "company-main";
    std::string project_alias = "codex-database";
    std::string session_id;
    std::string prompt;
    std::string mode = "normal";
    std::string model;
    std::string reasoning_effort;
    std::string status = "queued";
    std::string phase = "queued";
    std::string last_summary;
    std::string profile = "home-codex";
    std::string chat_channel = "mkb";
    std::string chat_id = "mkb-ios";
    bool cancelled = false;
    pid_t child_pid = -1;
};

struct SteerControl {
    long long steer_id = 0;
    std::string text;
};

struct Worker {
    std::string worker_id;
    std::string label = "Codex Worker";
    std::string status = "online";
    std::string active_task_id;
    std::string last_seen_at;
};

struct Binding {
    std::string channel = "mkb";
    std::string chat_id = "mkb-ios";
    std::string profile = "home-codex";
    std::string endpoint_id = "company-main";
    std::string project_alias = "codex-database";
    std::string session_id;
    std::string title = "MKB iOS";
    std::string session_policy = "project-default";
};

struct HistoryLoadRequest {
    std::string endpoint_id;
    std::string session_id;
    std::string requested_at;
};

struct Event {
    long long event_id = 0;
    std::string endpoint_id = "company-main";
    std::string task_id;
    std::string session_id;
    std::string type;
    std::string message;
    std::string data_json = "{}";
    std::string created_at;
};

struct Request {
    std::string method;
    std::string target;
    std::string path;
    std::map<std::string, std::string> query;
    std::string body;
};

struct Response {
    int status = 200;
    std::string content_type = "application/json; charset=utf-8";
    std::string body = "{}";
};

Response make_response(int status, const std::string& body, const std::string& type = "application/json; charset=utf-8");
void persist_state_locked();
std::string lower_ascii_copy(std::string value);
Event append_event_locked(const std::string& type, const std::string& task_id, const std::string& session_id, const std::string& message, const std::string& data_json);
bool event_exists_locked(const std::string& type, const std::string& task_id, const std::string& session_id, const std::string& message);

std::mutex g_mu;
std::condition_variable g_events_cv;
std::atomic<bool> g_running{true};
int g_server_fd = -1;
long long g_next_event_id = 1;
long long g_next_task_id = 1;
long long g_next_session_id = 1;
long long g_next_v1_command_id = 1;
long long g_next_steer_id = 1;
Endpoint g_endpoint;
std::map<std::string, Project> g_projects;
std::map<std::string, Session> g_sessions;
std::map<std::string, TaskRecord> g_tasks;
std::map<std::string, Binding> g_bindings;
std::map<std::string, std::string> g_profile_project;
std::map<std::string, std::string> g_profile_session;
std::map<std::string, std::string> g_transcript_last_task;
std::map<std::string, std::string> g_mobile_prompt_task;
std::map<std::string, std::string> g_suppressed_session_alias;
std::set<std::string> g_history_loaded_sessions;
std::map<std::string, HistoryLoadRequest> g_history_load_requests;
std::map<std::string, Worker> g_workers;
std::map<std::string, std::vector<SteerControl>> g_task_steers;
std::vector<Event> g_events;
std::string g_state_path;
bool g_state_loaded = false;
int g_persist_defer_depth = 0;
bool g_persist_deferred = false;

struct PersistDeferral {
    PersistDeferral() {
        ++g_persist_defer_depth;
    }

    ~PersistDeferral() {
        if (g_persist_defer_depth > 0) --g_persist_defer_depth;
        if (g_persist_defer_depth == 0 && g_persist_deferred) {
            g_persist_deferred = false;
            persist_state_locked();
        }
    }
};

std::string trim_copy(const std::string& value) {
    size_t start = 0;
    while (start < value.size() && std::isspace(static_cast<unsigned char>(value[start]))) ++start;
    size_t end = value.size();
    while (end > start && std::isspace(static_cast<unsigned char>(value[end - 1]))) --end;
    return value.substr(start, end - start);
}

std::string now_iso() {
    std::time_t t = std::time(nullptr);
    std::tm tm{};
    gmtime_r(&t, &tm);
    char buf[32];
    std::strftime(buf, sizeof(buf), "%Y-%m-%dT%H:%M:%SZ", &tm);
    return buf;
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
                out << "\\u";
                const char* hex = "0123456789abcdef";
                out << "00" << hex[(c >> 4) & 0xf] << hex[c & 0xf];
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

std::string pct_decode(const std::string& in) {
    std::string out;
    for (size_t i = 0; i < in.size(); ++i) {
        if (in[i] == '%' && i + 2 < in.size()) {
            char hex[3] = {in[i + 1], in[i + 2], 0};
            out.push_back(static_cast<char>(std::strtol(hex, nullptr, 16)));
            i += 2;
        } else if (in[i] == '+') {
            out.push_back(' ');
        } else {
            out.push_back(in[i]);
        }
    }
    return out;
}

std::map<std::string, std::string> parse_query(const std::string& target, std::string& path) {
    std::map<std::string, std::string> query;
    auto pos = target.find('?');
    path = pos == std::string::npos ? target : target.substr(0, pos);
    if (pos == std::string::npos) return query;
    std::string qs = target.substr(pos + 1);
    size_t start = 0;
    while (start <= qs.size()) {
        auto amp = qs.find('&', start);
        auto part = qs.substr(start, amp == std::string::npos ? std::string::npos : amp - start);
        auto eq = part.find('=');
        if (!part.empty()) {
            query[pct_decode(part.substr(0, eq))] = eq == std::string::npos ? "" : pct_decode(part.substr(eq + 1));
        }
        if (amp == std::string::npos) break;
        start = amp + 1;
    }
    return query;
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

std::vector<std::string> json_object_array_field(const std::string& body, const std::string& key) {
    std::vector<std::string> objects;
    std::regex re("\"" + key + "\"\\s*:\\s*\\[");
    std::smatch m;
    if (!std::regex_search(body, m, re)) return objects;

    size_t pos = static_cast<size_t>(m.position(0) + m.length(0));
    bool in_string = false;
    bool escape = false;
    int depth = 0;
    size_t object_start = std::string::npos;

    for (; pos < body.size(); ++pos) {
        char c = body[pos];
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
            in_string = true;
            continue;
        }
        if (c == ']') {
            if (depth == 0) break;
            continue;
        }
        if (c == '{') {
            if (depth == 0) object_start = pos;
            ++depth;
            continue;
        }
        if (c == '}') {
            if (depth <= 0) continue;
            --depth;
            if (depth == 0 && object_start != std::string::npos) {
                objects.push_back(body.substr(object_start, pos - object_start + 1));
                object_start = std::string::npos;
            }
        }
    }
    return objects;
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

bool json_bool_field(const std::string& body, const std::string& key, bool fallback = false) {
    std::regex re("\"" + key + "\"\\s*:\\s*(true|false)");
    std::smatch m;
    if (!std::regex_search(body, m, re)) return fallback;
    return m[1].str() == "true";
}

std::string env_or(const char* key, const std::string& fallback = "") {
    const char* value = std::getenv(key);
    return value && *value ? std::string(value) : fallback;
}

bool file_executable(const std::string& path) {
    return !path.empty() && access(path.c_str(), X_OK) == 0;
}

std::string codex_bin() {
    auto configured = env_or("MKB_CODEX_RELAY_CODEX_BIN");
    if (!configured.empty()) return configured;
    const std::string app_bin = "/Applications/Codex.app/Contents/Resources/codex";
    if (file_executable(app_bin)) return app_bin;
    return "codex";
}

bool force_mock_backend() {
    auto backend = env_or("MKB_CODEX_RELAY_BACKEND", "codex");
    return backend == "mock" || backend == "simulate" || backend == "simulation";
}

std::string backend_mode() {
    return env_or("MKB_CODEX_RELAY_BACKEND", "codex");
}

bool broker_backend() {
    auto backend = backend_mode();
    return backend == "broker" || backend == "relay" || backend == "forward";
}

std::string relay_default_cwd() {
    char buf[4096];
    if (getcwd(buf, sizeof(buf))) return buf;
    return ".";
}

std::string json_extract_string(const std::string& line, const std::string& key) {
    return json_string_field(line, key, "");
}

bool json_line_has(const std::string& line, const std::string& needle) {
    return line.find(needle) != std::string::npos;
}

bool should_emit_diagnostic(const std::string& line) {
    if (env_or("MKB_CODEX_RELAY_DIAGNOSTICS") == "1") return true;
    if (line.find(" WARN codex_core_plugins::manifest:") != std::string::npos) return false;
    if (line.find(" WARN codex_core_skills::loader:") != std::string::npos) return false;
    return !line.empty();
}

int set_nonblocking(int fd) {
    int flags = fcntl(fd, F_GETFL, 0);
    if (flags < 0) return -1;
    return fcntl(fd, F_SETFL, flags | O_NONBLOCK);
}

std::string binding_key(const std::string& channel, const std::string& chat_id) {
    return channel + ":" + chat_id;
}

std::string mobile_prompt_key(const std::string& session_id, const std::string& prompt) {
    return session_id + "\n" + prompt;
}

std::string history_key(const std::string& endpoint_id, const std::string& session_id) {
    return endpoint_id + "\n" + session_id;
}

bool is_history_source(const std::string& source) {
    std::string lower = lower_ascii_copy(source);
    return lower.find("codex") != std::string::npos && lower.find("vscode") != std::string::npos;
}

bool is_history_session_locked(const std::string& session_id) {
    auto it = g_sessions.find(session_id);
    return it != g_sessions.end() && is_history_source(it->second.source);
}

bool session_history_loaded_locked(const std::string& endpoint_id, const std::string& session_id) {
    return g_history_loaded_sessions.count(history_key(endpoint_id, session_id)) > 0;
}

constexpr size_t kV1HistorySessionsPerEndpointLimit = 300;

bool contains_synthetic_mkb_test_marker(const std::string& text) {
    return text.find("MKBHISTORYTEST") != std::string::npos ||
           text.find("MKBHISTORYOK") != std::string::npos ||
           text.find("MKBAPPSEND") != std::string::npos ||
           text.find("MKBAPPOK") != std::string::npos;
}

HistoryLoadRequest loaded_history_request_from_key_locked(const std::string& key) {
    HistoryLoadRequest request;
    auto split = key.find('\n');
    if (split == std::string::npos) return request;
    request.endpoint_id = key.substr(0, split);
    request.session_id = key.substr(split + 1);
    auto session = g_sessions.find(request.session_id);
    request.requested_at = session == g_sessions.end() || session->second.updated_at.empty()
        ? now_iso()
        : session->second.updated_at;
    return request;
}

void mark_history_loaded_locked(const std::string& endpoint_id, const std::string& session_id) {
    std::string key = history_key(endpoint_id, session_id);
    g_history_loaded_sessions.insert(key);
    g_history_load_requests.erase(key);
}

bool should_gate_history_task_locked(const TaskRecord& task) {
    if (contains_synthetic_mkb_test_marker(task.prompt) ||
        contains_synthetic_mkb_test_marker(task.last_summary)) {
        return true;
    }
    if (task.mode != "desktop-thread") return false;
    if (!is_history_session_locked(task.session_id)) return false;
    return !session_history_loaded_locked(task.endpoint_id, task.session_id);
}

HistoryLoadRequest queue_history_load_locked(const std::string& endpoint_id, const std::string& session_id, bool force = false) {
    HistoryLoadRequest request;
    request.endpoint_id = endpoint_id;
    request.session_id = session_id;
    request.requested_at = now_iso();
    if (!session_id.empty() && (force || !session_history_loaded_locked(endpoint_id, session_id))) {
        g_history_load_requests[history_key(endpoint_id, session_id)] = request;
        persist_state_locked();
    }
    return request;
}

std::string endpoint_json(const Endpoint& e) {
    return "{\"endpoint_id\":" + q(e.endpoint_id) + ",\"label\":" + q(e.label) +
           ",\"status\":" + q(e.status) + ",\"capabilities\":{\"stream\":true,\"interrupt\":true,\"insert_task\":true,\"workspace_switch\":true,\"new_conversation\":true},\"last_seen_at\":" + q(now_iso()) + "}";
}

std::string project_json(const Project& p) {
    return "{\"alias\":" + q(p.alias) + ",\"endpoint_id\":" + q(p.endpoint_id) +
           ",\"path\":" + q(p.path) + ",\"mode\":" + q(p.mode) + "}";
}

std::string session_timestamp_hint(const Session& s) {
    std::string haystack = s.session_id + "\n" + s.title;
    std::smatch match;
    std::regex dashed("(20[0-9]{2}-[0-9]{2}-[0-9]{2})T([0-9]{2})-([0-9]{2})-([0-9]{2})");
    if (std::regex_search(haystack, match, dashed) && match.size() >= 5) {
        return match[1].str() + "T" + match[2].str() + ":" + match[3].str() + ":" + match[4].str() + "Z";
    }
    std::regex iso("(20[0-9]{2}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z?)");
    if (std::regex_search(haystack, match, iso) && match.size() >= 2) {
        std::string value = match[1].str();
        if (!value.empty() && value.back() != 'Z') value += "Z";
        return value;
    }
    return "";
}

std::string session_updated_at_locked(const Session& s) {
    if (!s.updated_at.empty()) return s.updated_at;
    std::string hinted = session_timestamp_hint(s);
    std::string latest_event;
    for (const auto& event : g_events) {
        bool matches_session = event.session_id == s.session_id;
        if (!matches_session && !event.task_id.empty()) {
            auto task = g_tasks.find(event.task_id);
            matches_session = task != g_tasks.end() && task->second.session_id == s.session_id;
        }
        if (matches_session && event.created_at > latest_event) latest_event = event.created_at;
    }
    bool runtime_session = s.session_id == "linux-vscode-main" || s.session_id == "session-default" || hinted.empty();
    if (runtime_session && !latest_event.empty()) return latest_event;
    if (!hinted.empty()) return hinted;
    return latest_event.empty() ? now_iso() : latest_event;
}

std::string session_json(const Session& s) {
    return "{\"session_id\":" + q(s.session_id) + ",\"endpoint_id\":" + q(s.endpoint_id) +
           ",\"source\":" + q(s.source) + ",\"title\":" + q(s.title) +
           ",\"cwd\":" + q(s.cwd) + ",\"rollout_path\":" + q(s.cwd) +
           ",\"status\":" + q(s.status) + ",\"thread_id\":" + q(s.thread_id) +
           ",\"active_turn_id\":" + q(s.active_turn_id) +
           ",\"updated_at\":" + q(session_updated_at_locked(s)) + "}";
}

bool ignored_transcript_message(const std::string& message) {
    std::string text = trim_copy(message);
    if (text.empty()) return true;
    if (text.find("codex-fleet-monitor.prompt") != std::string::npos) return true;
    if (text.find("/home/donovan/.codex-bridge/codex-fleet-monitor.prompt") != std::string::npos) return true;
    if (text == "VPS_PERSIST_MULTI_USER") return true;
    return false;
}

std::string task_json(const TaskRecord& t) {
    return "{\"task_id\":" + q(t.task_id) + ",\"endpoint_id\":" + q(t.endpoint_id) +
           ",\"project_alias\":" + q(t.project_alias) + ",\"session_id\":" + q(t.session_id) +
           ",\"prompt\":" + q(t.prompt) + ",\"mode\":" + q(t.mode) +
           ",\"model\":" + q(t.model) + ",\"reasoning_effort\":" + q(t.reasoning_effort) +
           ",\"status\":" + q(t.status) + ",\"phase\":" + q(t.phase) +
           ",\"last_summary\":" + q(t.last_summary) + ",\"profile\":" + q(t.profile) +
           ",\"chat_channel\":" + q(t.chat_channel) + ",\"chat_id\":" + q(t.chat_id) +
           ",\"updated_at\":" + q(now_iso()) + "}";
}

std::string binding_json(const Binding& b) {
    return "{\"channel\":" + q(b.channel) + ",\"chat_id\":" + q(b.chat_id) +
           ",\"profile\":" + q(b.profile) + ",\"endpoint_id\":" + q(b.endpoint_id) +
           ",\"project_alias\":" + q(b.project_alias) + ",\"session_id\":" + q(b.session_id) +
           ",\"title\":" + q(b.title) + ",\"session_policy\":" + q(b.session_policy) +
           ",\"updated_at\":" + q(now_iso()) + "}";
}

std::string worker_json(const Worker& w) {
    return "{\"worker_id\":" + q(w.worker_id) + ",\"label\":" + q(w.label) +
           ",\"status\":" + q(w.status) + ",\"active_task_id\":" + q(w.active_task_id) +
           ",\"last_seen_at\":" + q(w.last_seen_at) + "}";
}

std::string event_json(const Event& e) {
    return "{\"event_id\":" + std::to_string(e.event_id) + ",\"endpoint_id\":" + q(e.endpoint_id) +
           ",\"task_id\":" + q(e.task_id) + ",\"session_id\":" + q(e.session_id) +
           ",\"type\":" + q(e.type) + ",\"message\":" + q(e.message) +
           ",\"data\":" + e.data_json + ",\"created_at\":" + q(e.created_at) + "}";
}

std::string history_load_request_json(const HistoryLoadRequest& request) {
    return "{\"endpoint_id\":" + q(request.endpoint_id) +
           ",\"session_id\":" + q(request.session_id) +
           ",\"requested_at\":" + q(request.requested_at) + "}";
}

void ensure_parent_dirs(const std::string& path) {
    auto slash = path.find('/');
    while (slash != std::string::npos) {
        if (slash > 0) {
            std::string dir = path.substr(0, slash);
            if (!dir.empty()) mkdir(dir.c_str(), 0755);
        }
        slash = path.find('/', slash + 1);
    }
}

void persist_state_locked() {
    if (!g_state_loaded || g_state_path.empty()) return;
    if (g_persist_defer_depth > 0) {
        g_persist_deferred = true;
        return;
    }
    ensure_parent_dirs(g_state_path);
    std::string tmp_path = g_state_path + ".tmp";
    std::ofstream out(tmp_path, std::ios::trunc);
    if (!out) {
        std::cerr << "persist open failed: " << tmp_path << "\n";
        return;
    }
    out << "{\"record\":\"counters\",\"next_event_id\":" << g_next_event_id
        << ",\"next_task_id\":" << g_next_task_id
        << ",\"next_session_id\":" << g_next_session_id
        << ",\"next_v1_command_id\":" << g_next_v1_command_id << "}\n";
    for (const auto& kv : g_projects) {
        const auto& p = kv.second;
        out << "{\"record\":\"project\",\"alias\":" << q(p.alias)
            << ",\"endpoint_id\":" << q(p.endpoint_id)
            << ",\"path\":" << q(p.path)
            << ",\"mode\":" << q(p.mode) << "}\n";
    }
    for (const auto& kv : g_sessions) {
        const auto& s = kv.second;
        out << "{\"record\":\"session\",\"session_id\":" << q(s.session_id)
            << ",\"endpoint_id\":" << q(s.endpoint_id)
            << ",\"source\":" << q(s.source)
            << ",\"title\":" << q(s.title)
            << ",\"cwd\":" << q(s.cwd)
            << ",\"status\":" << q(s.status)
            << ",\"thread_id\":" << q(s.thread_id)
            << ",\"active_turn_id\":" << q(s.active_turn_id)
            << ",\"updated_at\":" << q(s.updated_at) << "}\n";
    }
    for (const auto& kv : g_tasks) {
        const auto& t = kv.second;
        out << "{\"record\":\"task\",\"task_id\":" << q(t.task_id)
            << ",\"endpoint_id\":" << q(t.endpoint_id)
            << ",\"project_alias\":" << q(t.project_alias)
            << ",\"session_id\":" << q(t.session_id)
            << ",\"prompt\":" << q(t.prompt)
            << ",\"mode\":" << q(t.mode)
            << ",\"model\":" << q(t.model)
            << ",\"reasoning_effort\":" << q(t.reasoning_effort)
            << ",\"status\":" << q(t.status)
            << ",\"phase\":" << q(t.phase)
            << ",\"last_summary\":" << q(t.last_summary)
            << ",\"profile\":" << q(t.profile)
            << ",\"chat_channel\":" << q(t.chat_channel)
            << ",\"chat_id\":" << q(t.chat_id)
            << ",\"cancelled\":" << (t.cancelled ? "true" : "false") << "}\n";
    }
    for (const auto& kv : g_bindings) {
        const auto& b = kv.second;
        out << "{\"record\":\"binding\",\"channel\":" << q(b.channel)
            << ",\"chat_id\":" << q(b.chat_id)
            << ",\"profile\":" << q(b.profile)
            << ",\"endpoint_id\":" << q(b.endpoint_id)
            << ",\"project_alias\":" << q(b.project_alias)
            << ",\"session_id\":" << q(b.session_id)
            << ",\"title\":" << q(b.title)
            << ",\"session_policy\":" << q(b.session_policy) << "}\n";
    }
    for (const auto& kv : g_profile_project) {
        out << "{\"record\":\"profile\",\"profile\":" << q(kv.first)
            << ",\"project\":" << q(kv.second)
            << ",\"session\":" << q(g_profile_session[kv.first]) << "}\n";
    }
    for (const auto& kv : g_transcript_last_task) {
        out << "{\"record\":\"transcript_last\",\"session_id\":" << q(kv.first)
            << ",\"task_id\":" << q(kv.second) << "}\n";
    }
    for (const auto& kv : g_mobile_prompt_task) {
        auto sep = kv.first.find('\n');
        std::string session_id = sep == std::string::npos ? "" : kv.first.substr(0, sep);
        std::string prompt = sep == std::string::npos ? kv.first : kv.first.substr(sep + 1);
        out << "{\"record\":\"mobile_prompt\",\"session_id\":" << q(session_id)
            << ",\"prompt\":" << q(prompt)
            << ",\"task_id\":" << q(kv.second) << "}\n";
    }
    for (const auto& key : g_history_loaded_sessions) {
        auto sep = key.find('\n');
        std::string endpoint_id = sep == std::string::npos ? "" : key.substr(0, sep);
        std::string session_id = sep == std::string::npos ? key : key.substr(sep + 1);
        out << "{\"record\":\"history_loaded\",\"endpoint_id\":" << q(endpoint_id)
            << ",\"session_id\":" << q(session_id) << "}\n";
    }
    for (const auto& kv : g_history_load_requests) {
        const auto& request = kv.second;
        out << "{\"record\":\"history_request\",\"endpoint_id\":" << q(request.endpoint_id)
            << ",\"session_id\":" << q(request.session_id)
            << ",\"requested_at\":" << q(request.requested_at) << "}\n";
    }
    for (const auto& e : g_events) {
        out << "{\"record\":\"event\",\"event_id\":" << e.event_id
            << ",\"endpoint_id\":" << q(e.endpoint_id)
            << ",\"task_id\":" << q(e.task_id)
            << ",\"session_id\":" << q(e.session_id)
            << ",\"type\":" << q(e.type)
            << ",\"message\":" << q(e.message)
            << ",\"data_json\":" << q(e.data_json)
            << ",\"created_at\":" << q(e.created_at) << "}\n";
    }
    out.close();
    if (rename(tmp_path.c_str(), g_state_path.c_str()) != 0) {
        std::cerr << "persist rename failed: " << std::strerror(errno) << "\n";
    }
}

void load_state_locked() {
    if (g_state_path.empty()) return;
    std::ifstream in(g_state_path);
    if (!in) return;
    std::string line;
    while (std::getline(in, line)) {
        std::string record = json_string_field(line, "record");
        if (record == "counters") {
            g_next_event_id = std::max(g_next_event_id, json_long_field(line, "next_event_id", g_next_event_id));
            g_next_task_id = std::max(g_next_task_id, json_long_field(line, "next_task_id", g_next_task_id));
            g_next_session_id = std::max(g_next_session_id, json_long_field(line, "next_session_id", g_next_session_id));
            g_next_v1_command_id = std::max(g_next_v1_command_id, json_long_field(line, "next_v1_command_id", g_next_v1_command_id));
        } else if (record == "project") {
            Project p;
            p.alias = json_string_field(line, "alias", p.alias);
            p.endpoint_id = json_string_field(line, "endpoint_id", p.endpoint_id);
            p.path = json_string_field(line, "path");
            p.mode = json_string_field(line, "mode", p.mode);
            g_projects[p.alias] = p;
        } else if (record == "session") {
            Session s;
            s.session_id = json_string_field(line, "session_id");
            if (s.session_id.empty()) continue;
            s.endpoint_id = json_string_field(line, "endpoint_id", s.endpoint_id);
            s.source = json_string_field(line, "source", s.source);
            s.title = json_string_field(line, "title");
            s.cwd = json_string_field(line, "cwd");
            s.status = json_string_field(line, "status", s.status);
            s.thread_id = json_string_field(line, "thread_id");
            s.active_turn_id = json_string_field(line, "active_turn_id");
            s.updated_at = json_string_field(line, "updated_at");
            g_sessions[s.session_id] = s;
        } else if (record == "task") {
            TaskRecord t;
            t.task_id = json_string_field(line, "task_id");
            if (t.task_id.empty()) continue;
            t.endpoint_id = json_string_field(line, "endpoint_id", t.endpoint_id);
            t.project_alias = json_string_field(line, "project_alias", t.project_alias);
            t.session_id = json_string_field(line, "session_id");
            t.prompt = json_string_field(line, "prompt");
            t.mode = json_string_field(line, "mode", t.mode);
            t.model = json_string_field(line, "model");
            t.reasoning_effort = json_string_field(line, "reasoning_effort");
            t.status = json_string_field(line, "status", t.status);
            t.phase = json_string_field(line, "phase", t.phase);
            t.last_summary = json_string_field(line, "last_summary");
            t.profile = json_string_field(line, "profile", t.profile);
            t.chat_channel = json_string_field(line, "chat_channel", t.chat_channel);
            t.chat_id = json_string_field(line, "chat_id", t.chat_id);
            t.cancelled = json_bool_field(line, "cancelled", false);
            t.child_pid = -1;
            g_tasks[t.task_id] = t;
            if (!t.prompt.empty()) g_mobile_prompt_task[mobile_prompt_key(t.session_id, t.prompt)] = t.task_id;
        } else if (record == "binding") {
            Binding b;
            b.channel = json_string_field(line, "channel", b.channel);
            b.chat_id = json_string_field(line, "chat_id", b.chat_id);
            b.profile = json_string_field(line, "profile", b.profile);
            b.endpoint_id = json_string_field(line, "endpoint_id", b.endpoint_id);
            b.project_alias = json_string_field(line, "project_alias", b.project_alias);
            b.session_id = json_string_field(line, "session_id");
            b.title = json_string_field(line, "title", b.title);
            b.session_policy = json_string_field(line, "session_policy", b.session_policy);
            g_bindings[binding_key(b.channel, b.chat_id)] = b;
        } else if (record == "profile") {
            std::string profile = json_string_field(line, "profile", "home-codex");
            g_profile_project[profile] = json_string_field(line, "project");
            g_profile_session[profile] = json_string_field(line, "session");
        } else if (record == "transcript_last") {
            g_transcript_last_task[json_string_field(line, "session_id")] = json_string_field(line, "task_id");
        } else if (record == "mobile_prompt") {
            g_mobile_prompt_task[mobile_prompt_key(json_string_field(line, "session_id"), json_string_field(line, "prompt"))] = json_string_field(line, "task_id");
        } else if (record == "history_loaded") {
            std::string endpoint_id = json_string_field(line, "endpoint_id");
            std::string session_id = json_string_field(line, "session_id");
            if (!endpoint_id.empty() && !session_id.empty()) {
                g_history_loaded_sessions.insert(history_key(endpoint_id, session_id));
            }
        } else if (record == "history_request") {
            HistoryLoadRequest request;
            request.endpoint_id = json_string_field(line, "endpoint_id");
            request.session_id = json_string_field(line, "session_id");
            request.requested_at = json_string_field(line, "requested_at", now_iso());
            if (!request.endpoint_id.empty() && !request.session_id.empty()) {
                g_history_load_requests[history_key(request.endpoint_id, request.session_id)] = request;
            }
        } else if (record == "event") {
            Event e;
            e.event_id = json_long_field(line, "event_id", 0);
            e.endpoint_id = json_string_field(line, "endpoint_id", e.endpoint_id);
            e.task_id = json_string_field(line, "task_id");
            e.session_id = json_string_field(line, "session_id");
            e.type = json_string_field(line, "type");
            e.message = json_string_field(line, "message");
            e.data_json = json_string_field(line, "data_json", "{}");
            e.created_at = json_string_field(line, "created_at", now_iso());
            if (e.event_id > 0 && !e.type.empty()) {
                g_events.push_back(e);
                g_next_event_id = std::max(g_next_event_id, e.event_id + 1);
            }
        }
    }
    std::cerr << "loaded relay state: sessions=" << g_sessions.size()
              << " tasks=" << g_tasks.size() << " events=" << g_events.size() << "\n";
}

std::string v1_endpoint_json(const std::string& endpoint_id) {
    Endpoint endpoint = g_endpoint;
    endpoint.endpoint_id = endpoint_id.empty() ? g_endpoint.endpoint_id : endpoint_id;
    if (endpoint.endpoint_id != g_endpoint.endpoint_id) endpoint.label = endpoint.endpoint_id;
    return endpoint_json(endpoint);
}

long long trailing_number(const std::string& value, long long fallback) {
    long long multiplier = 1;
    long long result = 0;
    bool any = false;
    for (auto it = value.rbegin(); it != value.rend(); ++it) {
        if (!std::isdigit(static_cast<unsigned char>(*it))) break;
        any = true;
        result += (*it - '0') * multiplier;
        multiplier *= 10;
    }
    return any ? result : fallback;
}

long long task_message_base_seq(const TaskRecord& task) {
    if (auto pos = task.task_id.find("-line-"); pos != std::string::npos) {
        return trailing_number(task.task_id.substr(pos + 6), trailing_number(task.task_id, g_next_task_id)) * 2 - 1;
    }
    long long first_event_id = 0;
    for (const auto& event : g_events) {
        if (event.task_id != task.task_id) continue;
        if (event.type != "task.created" && event.type != "task.inserted" && event.type != "task.steered" && event.type != "transcript.user.matched") continue;
        if (first_event_id == 0 || event.event_id < first_event_id) first_event_id = event.event_id;
    }
    if (first_event_id > 0) return first_event_id * 2 - 1;
    return trailing_number(task.task_id, g_next_task_id) * 2 - 1;
}

std::string assistant_text_for_task_locked(const TaskRecord& task) {
    if (!task.last_summary.empty()) return task.last_summary;
    std::string joined;
    for (const auto& event : g_events) {
        if (event.task_id == task.task_id && event.type == "codex.output.delta") joined += event.message;
    }
    if (joined.empty() && task.status == "interrupted") return "任务已打断";
    if (joined.empty() && task.status == "failed") return "任务失败";
    return joined;
}

bool can_repair_mobile_task_from_transcript(const TaskRecord& task) {
    if (task.mode == "desktop-thread") return false;
    if (trim_copy(task.prompt).empty()) return false;
    if (task.status == "interrupted") return false;
    if (task.status == "completed" && !trim_copy(task.last_summary).empty()) return false;
    if (task.status == "running" || task.status == "queued") return true;
    if (task.status == "failed") {
        std::string summary = trim_copy(task.last_summary);
        return summary.empty() ||
               summary.find("No usable Codex transport") == 0 ||
               summary.find("Codex 已结束但没有返回内容") == 0;
    }
    return false;
}

bool normalize_cancelled_tasks_locked() {
    bool changed = false;
    for (auto& kv : g_tasks) {
        auto& task = kv.second;
        if (!task.cancelled) continue;
        if (task.status != "queued" && task.status != "running") continue;
        task.status = "interrupted";
        task.phase = "interrupted";
        changed = true;
        if (!event_exists_locked("task.interrupted", task.task_id, task.session_id, "Task interrupted by mobile client")) {
            append_event_locked("task.interrupted", task.task_id, task.session_id, "Task interrupted by mobile client",
                                "{\"normalized\":true}");
        }
    }
    if (changed) persist_state_locked();
    return changed;
}

bool repair_mobile_tasks_from_transcript_locked(const std::string& logical_session_id,
                                                const std::string& transcript_session_id) {
    if (logical_session_id.empty() || transcript_session_id.empty() ||
        logical_session_id == transcript_session_id) {
        return false;
    }

    std::map<std::string, std::pair<std::string, std::string>> completed_by_prompt;
    for (const auto& kv : g_tasks) {
        const auto& transcript = kv.second;
        if (transcript.session_id != transcript_session_id) continue;
        if (transcript.mode != "desktop-thread") continue;
        std::string prompt_key = trim_copy(transcript.prompt);
        if (prompt_key.empty()) continue;
        std::string assistant = trim_copy(assistant_text_for_task_locked(transcript));
        if (assistant.empty()) continue;
        completed_by_prompt[prompt_key] = {assistant, transcript.task_id};
    }
    if (completed_by_prompt.empty()) return false;

    bool repaired = false;
    for (auto& kv : g_tasks) {
        auto& mobile = kv.second;
        if (mobile.session_id != logical_session_id) continue;
        if (!can_repair_mobile_task_from_transcript(mobile)) continue;
        auto completed = completed_by_prompt.find(trim_copy(mobile.prompt));
        if (completed == completed_by_prompt.end()) continue;

        mobile.last_summary = completed->second.first;
        mobile.status = "completed";
        mobile.phase = "completed";
        mobile.cancelled = false;
        g_transcript_last_task[transcript_session_id] = mobile.task_id;
        repaired = true;

        if (!event_exists_locked("codex.output.delta", mobile.task_id, logical_session_id, mobile.last_summary)) {
            append_event_locked("codex.output.delta", mobile.task_id, logical_session_id, mobile.last_summary,
                                "{\"role\":\"assistant\",\"source\":\"desktop-thread\",\"repaired_from\":" +
                                    q(completed->second.second) + "}");
        }
        if (!event_exists_locked("task.completed", mobile.task_id, logical_session_id, "Task completed")) {
            append_event_locked("task.completed", mobile.task_id, logical_session_id, "Task completed", "{}");
        }
    }
    if (repaired) persist_state_locked();
    return repaired;
}

std::string v1_task_message_status(const TaskRecord& task, bool assistant) {
    if (task.status == "completed") return "completed";
    if (task.cancelled || task.status == "interrupted") return "interrupted";
    if (task.status == "failed") return "failed";
    if (task.status == "running" || task.status == "queued") return assistant ? "streaming" : "completed";
    return "completed";
}

std::string v1_message_json(const TaskRecord& task,
                            const std::string& message_id,
                            long long seq,
                            const std::string& role,
                            const std::string& text,
                            const std::string& status,
                            const std::string& exposed_session_id = "") {
    std::string visible_session_id = exposed_session_id.empty() ? task.session_id : exposed_session_id;
    return "{\"endpoint_id\":" + q(task.endpoint_id) +
           ",\"session_id\":" + q(visible_session_id) +
           ",\"message_id\":" + q(message_id) +
           ",\"turn_id\":" + q(task.task_id) +
           ",\"seq\":" + std::to_string(seq) +
           ",\"role\":" + q(role) +
           ",\"text\":" + q(text) +
           ",\"status\":" + q(status) +
           ",\"updated_at\":" + q(now_iso()) + "}";
}

std::string v1_message_state_json(const TaskRecord& task,
                                  const std::string& message_id,
                                  const std::string& status,
                                  const std::string& detail = "",
                                  const std::string& exposed_session_id = "") {
    std::string visible_session_id = exposed_session_id.empty() ? task.session_id : exposed_session_id;
    return "{\"endpoint_id\":" + q(task.endpoint_id) +
           ",\"session_id\":" + q(visible_session_id) +
           ",\"message_id\":" + q(message_id) +
           ",\"turn_id\":" + q(task.task_id) +
           ",\"status\":" + q(status) +
           ",\"detail\":" + q(detail) +
           ",\"updated_at\":" + q(now_iso()) + "}";
}

std::vector<std::string> v1_messages_locked(const std::string& endpoint_id, const std::string& session_id, long long after_seq) {
    std::vector<std::pair<long long, std::string>> rows;
    std::string aliased_session_id;
    if (!session_id.empty() && g_sessions.count(session_id)) {
        aliased_session_id = g_sessions[session_id].thread_id;
    }
    repair_mobile_tasks_from_transcript_locked(session_id, aliased_session_id);
    for (const auto& kv : g_tasks) {
        const auto& task = kv.second;
        if (!endpoint_id.empty() && task.endpoint_id != endpoint_id) continue;
        bool session_matches = session_id.empty() || task.session_id == session_id ||
                               (!aliased_session_id.empty() && task.session_id == aliased_session_id);
        if (!session_matches) continue;
        if (should_gate_history_task_locked(task)) continue;
        std::string exposed_session_id = (!session_id.empty() && task.session_id == aliased_session_id) ? session_id : "";
        long long base = task_message_base_seq(task);
        if (!trim_copy(task.prompt).empty() && base > after_seq) {
            rows.push_back({base, v1_message_json(task, task.task_id + ":user", base, "user", task.prompt, "completed", exposed_session_id)});
        }
        std::string assistant = assistant_text_for_task_locked(task);
        bool should_show_assistant = !trim_copy(assistant).empty() || task.status == "running" || task.status == "queued" ||
                                     task.status == "interrupted" || task.status == "failed";
        if (should_show_assistant && base + 1 > after_seq) {
            rows.push_back({base + 1, v1_message_json(task, task.task_id + ":assistant", base + 1, "assistant", assistant, v1_task_message_status(task, true), exposed_session_id)});
        }
    }
    std::sort(rows.begin(), rows.end(), [](const auto& lhs, const auto& rhs) {
        if (lhs.first != rhs.first) return lhs.first < rhs.first;
        return lhs.second < rhs.second;
    });
    std::vector<std::string> out;
    for (const auto& row : rows) out.push_back(row.second);
    return out;
}

std::vector<std::string> v1_message_states_locked(const std::string& endpoint_id, const std::string& session_id) {
    std::vector<std::pair<long long, std::string>> rows;
    std::string aliased_session_id;
    if (!session_id.empty() && g_sessions.count(session_id)) {
        aliased_session_id = g_sessions[session_id].thread_id;
    }
    repair_mobile_tasks_from_transcript_locked(session_id, aliased_session_id);
    for (const auto& kv : g_tasks) {
        const auto& task = kv.second;
        if (!endpoint_id.empty() && task.endpoint_id != endpoint_id) continue;
        bool session_matches = session_id.empty() || task.session_id == session_id ||
                               (!aliased_session_id.empty() && task.session_id == aliased_session_id);
        if (!session_matches) continue;
        if (should_gate_history_task_locked(task)) continue;
        std::string exposed_session_id = (!session_id.empty() && task.session_id == aliased_session_id) ? session_id : "";
        long long base = task_message_base_seq(task);
        if (!trim_copy(task.prompt).empty()) {
            rows.push_back({base, v1_message_state_json(task, task.task_id + ":user", "completed", "", exposed_session_id)});
        }
        std::string assistant = assistant_text_for_task_locked(task);
        if (!trim_copy(assistant).empty() || task.status == "running" || task.status == "queued" ||
            task.status == "interrupted" || task.status == "failed") {
            rows.push_back({base + 1, v1_message_state_json(task, task.task_id + ":assistant", v1_task_message_status(task, true), task.phase, exposed_session_id)});
        }
    }
    std::sort(rows.begin(), rows.end(), [](const auto& lhs, const auto& rhs) {
        if (lhs.first != rhs.first) return lhs.first < rhs.first;
        return lhs.second < rhs.second;
    });
    std::vector<std::string> out;
    for (const auto& row : rows) out.push_back(row.second);
    return out;
}

std::vector<Session> v1_sessions_limited_locked() {
    std::vector<Session> keep;
    std::map<std::string, std::vector<Session>> history_by_endpoint;
    for (const auto& kv : g_sessions) {
        const auto& session = kv.second;
        if (is_history_source(session.source)) {
            history_by_endpoint[session.endpoint_id].push_back(session);
        } else {
            keep.push_back(session);
        }
    }
    auto newer = [](const Session& lhs, const Session& rhs) {
        std::string left = session_updated_at_locked(lhs);
        std::string right = session_updated_at_locked(rhs);
        if (left != right) return left > right;
        return lhs.session_id > rhs.session_id;
    };
    for (auto& kv : history_by_endpoint) {
        auto& sessions = kv.second;
        std::sort(sessions.begin(), sessions.end(), newer);
        if (sessions.size() > kV1HistorySessionsPerEndpointLimit) sessions.resize(kV1HistorySessionsPerEndpointLimit);
        keep.insert(keep.end(), sessions.begin(), sessions.end());
    }
    std::sort(keep.begin(), keep.end(), newer);
    return keep;
}

template <typename T, typename F>
std::string json_array(const T& items, F encode) {
    std::string out = "[";
    bool first = true;
    for (const auto& item : items) {
        if (!first) out += ",";
        first = false;
        out += encode(item);
    }
    out += "]";
    return out;
}

Event append_event_locked(const std::string& type, const std::string& task_id, const std::string& session_id, const std::string& message, const std::string& data_json = "{}") {
    Event e;
    e.event_id = g_next_event_id++;
    if (!task_id.empty() && g_tasks.count(task_id)) {
        e.endpoint_id = g_tasks[task_id].endpoint_id;
    } else if (!session_id.empty() && g_sessions.count(session_id)) {
        e.endpoint_id = g_sessions[session_id].endpoint_id;
    } else {
        e.endpoint_id = g_endpoint.endpoint_id;
    }
    e.task_id = task_id;
    e.session_id = session_id;
    e.type = type;
    e.message = message;
    e.data_json = data_json;
    e.created_at = now_iso();
    g_events.push_back(e);
    if (g_events.size() > 2000) g_events.erase(g_events.begin(), g_events.begin() + 500);
    g_events_cv.notify_all();
    persist_state_locked();
    return e;
}

std::string ensure_session_locked(const std::string& project_alias, const std::string& requested = "") {
    if (!requested.empty() && g_sessions.count(requested)) return requested;
    std::string sid = requested.empty() ? "session-" + std::to_string(g_next_session_id++) : requested;
    Session s;
    s.session_id = sid;
    s.title = "MKB " + sid;
    s.cwd = g_projects.count(project_alias) ? g_projects[project_alias].path : "";
    g_sessions[sid] = s;
    return sid;
}

std::string safe_id_part(std::string value) {
    for (char& c : value) {
        if (!std::isalnum(static_cast<unsigned char>(c)) && c != '-' && c != '_') c = '-';
    }
    if (value.empty()) return "item";
    return value;
}

bool event_exists_locked(const std::string& type, const std::string& task_id, const std::string& session_id, const std::string& message) {
    for (const auto& e : g_events) {
        if (e.type == type && e.task_id == task_id && e.session_id == session_id && e.message == message) return true;
    }
    return false;
}

bool is_terminal_status(const std::string& status) {
    return status == "completed" || status == "interrupted" || status == "failed";
}

std::string lower_ascii_copy(std::string value) {
    for (char& c : value) c = static_cast<char>(std::tolower(static_cast<unsigned char>(c)));
    return value;
}

std::string normalized_history_key(const std::string& text) {
    std::istringstream in(text);
    std::string line;
    std::string picked;
    while (std::getline(in, line)) {
        std::string candidate = trim_copy(line);
        if (candidate.empty()) continue;
        std::string lowered = lower_ascii_copy(candidate);
        if (lowered.rfind("<environment_context>", 0) == 0 ||
            lowered.rfind("# agents.md", 0) == 0 ||
            lowered.rfind("memory hits:", 0) == 0 ||
            lowered.rfind("memory writes:", 0) == 0) {
            continue;
        }
        auto judge_pos = candidate.find("判断");
        if (judge_pos != std::string::npos) candidate = candidate.substr(judge_pos);
        picked = trim_copy(candidate);
        break;
    }
    if (picked.empty()) picked = trim_copy(text);
    if (picked.size() > 180) picked.resize(180);
    return lower_ascii_copy(picked);
}

std::string first_user_prompt_locked(const std::string& session_id) {
    std::vector<std::pair<long long, std::string>> prompts;
    for (const auto& kv : g_tasks) {
        const auto& task = kv.second;
        if (task.session_id != session_id) continue;
        if (trim_copy(task.prompt).empty()) continue;
        prompts.push_back({task_message_base_seq(task), task.prompt});
    }
    std::sort(prompts.begin(), prompts.end(), [](const auto& lhs, const auto& rhs) {
        if (lhs.first != rhs.first) return lhs.first < rhs.first;
        return lhs.second < rhs.second;
    });
    return prompts.empty() ? "" : prompts.front().second;
}

std::string canonical_history_session_locked(const std::vector<std::string>& session_ids) {
    std::string best;
    long long best_messages = -1;
    long long best_text = -1;
    for (const auto& session_id : session_ids) {
        long long messages = 0;
        long long text_size = 0;
        for (const auto& kv : g_tasks) {
            const auto& task = kv.second;
            if (task.session_id != session_id) continue;
            if (!trim_copy(task.prompt).empty()) {
                ++messages;
                text_size += static_cast<long long>(task.prompt.size());
            }
            std::string assistant = assistant_text_for_task_locked(task);
            if (!trim_copy(assistant).empty()) {
                ++messages;
                text_size += static_cast<long long>(assistant.size());
            }
        }
        if (messages > best_messages ||
            (messages == best_messages && text_size > best_text) ||
            (messages == best_messages && text_size == best_text && session_id > best)) {
            best = session_id;
            best_messages = messages;
            best_text = text_size;
        }
    }
    return best;
}

[[maybe_unused]] std::string find_duplicate_history_session_locked(const std::string& endpoint_id,
                                                                   const std::string& source,
                                                                   const std::string& incoming_session_id,
                                                                   const std::string& first_prompt) {
    std::string key = normalized_history_key(first_prompt);
    if (key.empty()) return "";
    std::vector<std::string> matches;
    for (const auto& kv : g_sessions) {
        const auto& session = kv.second;
        if (session.session_id == incoming_session_id) continue;
        if (session.endpoint_id != endpoint_id) continue;
        if (session.source != source) continue;
        if (normalized_history_key(first_user_prompt_locked(session.session_id)) == key) {
            matches.push_back(session.session_id);
        }
    }
    if (matches.empty()) return "";
    return canonical_history_session_locked(matches);
}

struct HistoryCompactResult {
    int scanned = 0;
    int removed_sessions = 0;
    int removed_tasks = 0;
    int removed_events = 0;
    int duplicate_groups = 0;
};

[[maybe_unused]] HistoryCompactResult compact_history_locked(const std::string& endpoint_id) {
    HistoryCompactResult result;
    std::map<std::string, std::vector<std::string>> groups;

    for (const auto& kv : g_sessions) {
        const auto& session = kv.second;
        if (!endpoint_id.empty() && session.endpoint_id != endpoint_id) continue;
        if (session.source == "mkb" || session.source == "codex-relay" || session.session_id == "session-default") continue;
        ++result.scanned;
        std::string key = normalized_history_key(first_user_prompt_locked(session.session_id));
        if (key.empty()) continue;
        groups[session.endpoint_id + "\n" + session.source + "\n" + key].push_back(session.session_id);
    }

    std::map<std::string, std::string> replacement;
    for (const auto& kv : groups) {
        if (kv.second.size() < 2) continue;
        ++result.duplicate_groups;
        std::string keep = canonical_history_session_locked(kv.second);
        for (const auto& session_id : kv.second) {
            if (session_id == keep) continue;
            replacement[session_id] = keep;
            g_suppressed_session_alias[session_id] = keep;
        }
    }

    std::set<std::string> removed_sessions;
    for (const auto& kv : replacement) removed_sessions.insert(kv.first);
    if (removed_sessions.empty()) return result;

    std::set<std::string> removed_tasks;
    for (auto it = g_tasks.begin(); it != g_tasks.end();) {
        if (removed_sessions.count(it->second.session_id)) {
            removed_tasks.insert(it->first);
            it = g_tasks.erase(it);
            ++result.removed_tasks;
        } else {
            ++it;
        }
    }

    for (auto it = g_events.begin(); it != g_events.end();) {
        if (removed_sessions.count(it->session_id) || removed_tasks.count(it->task_id)) {
            it = g_events.erase(it);
            ++result.removed_events;
        } else {
            ++it;
        }
    }

    for (auto it = g_sessions.begin(); it != g_sessions.end();) {
        if (removed_sessions.count(it->first)) {
            it = g_sessions.erase(it);
            ++result.removed_sessions;
        } else {
            ++it;
        }
    }

    for (auto& kv : g_bindings) {
        auto rep = replacement.find(kv.second.session_id);
        if (rep != replacement.end() && !rep->second.empty()) kv.second.session_id = rep->second;
    }
    for (auto& kv : g_profile_session) {
        auto rep = replacement.find(kv.second);
        if (rep != replacement.end() && !rep->second.empty()) kv.second = rep->second;
    }
    for (auto it = g_transcript_last_task.begin(); it != g_transcript_last_task.end();) {
        if (removed_sessions.count(it->first) || removed_tasks.count(it->second)) {
            it = g_transcript_last_task.erase(it);
        } else {
            ++it;
        }
    }
    for (auto it = g_mobile_prompt_task.begin(); it != g_mobile_prompt_task.end();) {
        auto sep = it->first.find('\n');
        std::string session_id = sep == std::string::npos ? "" : it->first.substr(0, sep);
        if (removed_sessions.count(session_id) || removed_tasks.count(it->second)) {
            it = g_mobile_prompt_task.erase(it);
        } else {
            ++it;
        }
    }

    persist_state_locked();
    return result;
}

Response import_transcript_session_locked(const std::string& body) {
    std::string session_id = json_string_field(body, "session_id", "codex-desktop-current");
    std::string endpoint_id = json_string_field(body, "endpoint_id", g_endpoint.endpoint_id);
    std::string title = json_string_field(body, "title", session_id);
    std::string cwd = json_string_field(body, "cwd", "");
    std::string source = json_string_field(body, "source", "codex-vscode");
    std::string updated_at = json_string_field(body, "updated_at", "");
    std::string project_alias = json_string_field(body, "project_alias", "codex-database");
    if (session_id.empty()) return make_response(400, "{\"error\":\"empty_session_id\"}");

    std::string sid = ensure_session_locked(project_alias, session_id);
    auto& session = g_sessions[sid];
    session.endpoint_id = endpoint_id.empty() ? g_endpoint.endpoint_id : endpoint_id;
    session.source = source.empty() ? "codex-vscode" : source;
    session.title = title.empty() ? sid : title;
    if (!cwd.empty()) session.cwd = cwd;
    session.status = "indexed";
    if (!updated_at.empty()) session.updated_at = updated_at;
    if (is_history_source(session.source)) {
        session.thread_id = sid;
    }
    persist_state_locked();
    return make_response(200, "{\"ok\":true,\"session\":" + session_json(session) +
        ",\"loaded\":" + std::string(session_history_loaded_locked(session.endpoint_id, sid) ? "true" : "false") + "}");
}

Response import_transcript_message_locked(const std::string& body) {
    std::string session_id = json_string_field(body, "session_id", "codex-desktop-current");
    std::string endpoint_id = json_string_field(body, "endpoint_id", g_endpoint.endpoint_id);
    std::string title = json_string_field(body, "title", "当前 Codex 对话");
    std::string cwd = json_string_field(body, "cwd", "");
    std::string source = json_string_field(body, "source", "codex-desktop");
    std::string role = json_string_field(body, "role", "");
    std::string message = json_string_field(body, "message", "");
    std::string ordinal = json_string_field(body, "ordinal", std::to_string(g_next_task_id));
    std::string updated_at = json_string_field(body, "updated_at", "");
    bool bind_current = json_string_field(body, "bind_current", "true") != "false";
    std::string profile = json_string_field(body, "profile", "home-codex");
    std::string channel = json_string_field(body, "channel", "mkb");
    std::string chat_id = json_string_field(body, "chat_id", "mkb-ios");
    std::string project_alias = json_string_field(body, "project_alias", g_profile_project[profile].empty() ? "codex-database" : g_profile_project[profile]);

    if (message.empty()) return make_response(400, "{\"error\":\"empty_message\"}");
    if (ignored_transcript_message(message)) {
        return make_response(200, "{\"ok\":true,\"ignored\":true,\"reason\":\"non_user_history_noise\"}");
    }

    std::string effective_endpoint_id = endpoint_id.empty() ? g_endpoint.endpoint_id : endpoint_id;
    std::string effective_source = source.empty() ? "codex-desktop" : source;

    std::string sid = ensure_session_locked(project_alias, session_id);
    auto& session = g_sessions[sid];
    session.endpoint_id = effective_endpoint_id;
    session.source = effective_source;
    session.title = title.empty() ? sid : title;
    if (!cwd.empty()) session.cwd = cwd;
    session.status = "synced";
    if (!updated_at.empty()) session.updated_at = updated_at;
    if (is_history_source(effective_source)) {
        session.thread_id = sid;
        mark_history_loaded_locked(effective_endpoint_id, sid);
    }

    if (bind_current) {
        g_profile_project[profile] = project_alias;
        g_profile_session[profile] = sid;
        Binding b;
        b.channel = channel;
        b.chat_id = chat_id;
        b.profile = profile;
        b.endpoint_id = session.endpoint_id;
        b.project_alias = project_alias;
        b.session_id = sid;
        b.title = title.empty() ? "当前 Codex 对话" : title;
        b.session_policy = "fixed-session";
        g_bindings[binding_key(channel, chat_id)] = b;
    }

    if (role == "user") {
        auto mobile_it = g_mobile_prompt_task.find(mobile_prompt_key(sid, message));
        if (mobile_it == g_mobile_prompt_task.end()) {
            for (const auto& kv : g_sessions) {
                if (kv.second.thread_id != sid) continue;
                mobile_it = g_mobile_prompt_task.find(mobile_prompt_key(kv.first, message));
                if (mobile_it != g_mobile_prompt_task.end()) break;
            }
        }
        if (mobile_it != g_mobile_prompt_task.end() && g_tasks.count(mobile_it->second)) {
            auto& task = g_tasks[mobile_it->second];
            if (!is_terminal_status(task.status)) {
                task.status = "running";
                task.phase = "desktop";
            } else if (task.status == "failed") {
                task.status = "completed";
                task.phase = "completed";
            }
            g_transcript_last_task[sid] = task.task_id;
            if (!event_exists_locked("transcript.user.matched", task.task_id, sid, message)) {
                append_event_locked("transcript.user.matched", task.task_id, sid, message, "{\"role\":\"user\",\"source\":\"desktop-thread\",\"matched_mobile\":true}");
            }
            persist_state_locked();
            return make_response(200, "{\"ok\":true,\"matched_mobile\":true,\"session\":" + session_json(session) + ",\"task\":" + task_json(task) + "}");
        }
        TaskRecord t;
        t.task_id = "transcript-" + safe_id_part(sid) + "-" + safe_id_part(ordinal);
        t.endpoint_id = session.endpoint_id;
        t.project_alias = project_alias;
        t.session_id = sid;
        t.prompt = message;
        t.mode = "desktop-thread";
        t.status = "completed";
        t.phase = "completed";
        t.profile = profile;
        t.chat_channel = channel;
        t.chat_id = chat_id;
        auto existing = g_tasks.find(t.task_id);
        if (existing == g_tasks.end()) {
            g_tasks.emplace(t.task_id, t);
        } else {
            existing->second.prompt = t.prompt;
            existing->second.status = "completed";
            existing->second.phase = "completed";
        }
        g_transcript_last_task[sid] = t.task_id;
        if (!event_exists_locked("transcript.user", t.task_id, sid, message)) {
            append_event_locked("transcript.user", t.task_id, sid, message, "{\"role\":\"user\"}");
        }
        return make_response(200, "{\"ok\":true,\"session\":" + session_json(session) + ",\"task\":" + task_json(g_tasks[t.task_id]) + "}");
    }

    if (role == "assistant") {
        std::string task_id = g_transcript_last_task[sid];
        if (!task_id.empty() && g_tasks.count(task_id)) {
            const auto& previous = g_tasks[task_id];
            bool can_complete_mobile_task = previous.mode != "desktop-thread" &&
                                            previous.status == "running" &&
                                            previous.phase == "desktop";
            bool can_repair_mobile_task = previous.mode != "desktop-thread" &&
                                          previous.status == "completed" &&
                                          trim_copy(previous.last_summary).find("No usable Codex transport") == 0;
            bool can_append_desktop_task = previous.mode == "desktop-thread";
            if (previous.mode != "desktop-thread" &&
                previous.status == "completed" &&
                trim_copy(previous.last_summary) == trim_copy(message)) {
                return make_response(200, "{\"ok\":true,\"duplicate_mobile_final\":true,\"session\":" + session_json(session) + ",\"task\":" + task_json(previous) + "}");
            }
            if (!can_complete_mobile_task && !can_repair_mobile_task && !can_append_desktop_task) {
                task_id.clear();
            }
        }
        if (task_id.empty() || !g_tasks.count(task_id)) {
            TaskRecord t;
            t.task_id = "transcript-" + safe_id_part(sid) + "-" + safe_id_part(ordinal);
            t.endpoint_id = session.endpoint_id;
            t.project_alias = project_alias;
            t.session_id = sid;
            t.prompt = "";
            t.mode = "desktop-thread";
            t.status = "completed";
            t.phase = "completed";
            t.profile = profile;
            t.chat_channel = channel;
            t.chat_id = chat_id;
            g_tasks.emplace(t.task_id, t);
            task_id = t.task_id;
            g_transcript_last_task[sid] = task_id;
        }
        auto& task = g_tasks[task_id];
        task.last_summary = message;
        task.status = "completed";
        task.phase = "completed";
        task.cancelled = false;
        if (!event_exists_locked("codex.output.delta", task_id, sid, message)) {
            append_event_locked("codex.output.delta", task_id, sid, message, "{\"role\":\"assistant\",\"source\":\"desktop-thread\"}");
        }
        if (!event_exists_locked("task.completed", task_id, sid, "Task completed")) {
            append_event_locked("task.completed", task_id, sid, "Task completed");
        }
        return make_response(200, "{\"ok\":true,\"session\":" + session_json(session) + ",\"task\":" + task_json(task) + "}");
    }

    return make_response(400, "{\"error\":\"bad_role\"}");
}

Response import_transcript_messages_locked(const std::string& body) {
    std::string session_id = json_string_field(body, "session_id", "codex-desktop-current");
    std::string endpoint_id = json_string_field(body, "endpoint_id", g_endpoint.endpoint_id);
    std::string title = json_string_field(body, "title", "当前 Codex 对话");
    std::string cwd = json_string_field(body, "cwd", "");
    std::string source = json_string_field(body, "source", "codex-desktop");
    std::string updated_at = json_string_field(body, "updated_at", "");
    std::string bind_current = json_string_field(body, "bind_current", "false");
    std::string profile = json_string_field(body, "profile", "home-codex");
    std::string channel = json_string_field(body, "channel", "mkb");
    std::string chat_id = json_string_field(body, "chat_id", "mkb-ios");
    std::string project_alias = json_string_field(body, "project_alias", g_profile_project[profile].empty() ? "codex-database" : g_profile_project[profile]);
    auto messages = json_object_array_field(body, "messages");
    if (session_id.empty()) return make_response(400, "{\"error\":\"empty_session_id\"}");
    if (messages.empty()) return make_response(400, "{\"error\":\"empty_messages\"}");

    PersistDeferral persist_once;
    int imported = 0;
    int ignored = 0;
    for (size_t i = 0; i < messages.size(); ++i) {
        const auto& item = messages[i];
        std::string role = json_string_field(item, "role", "");
        std::string message = json_string_field(item, "message", "");
        std::string ordinal = json_string_field(item, "ordinal", std::to_string(i + 1));
        if (message.empty()) {
            ++ignored;
            continue;
        }
        std::string one = "{\"session_id\":" + q(session_id) +
            ",\"endpoint_id\":" + q(endpoint_id) +
            ",\"title\":" + q(title) +
            ",\"cwd\":" + q(cwd) +
            ",\"source\":" + q(source) +
            ",\"role\":" + q(role) +
            ",\"message\":" + q(message) +
            ",\"ordinal\":" + q(ordinal) +
            ",\"updated_at\":" + q(updated_at) +
            ",\"bind_current\":" + q(bind_current) +
            ",\"profile\":" + q(profile) +
            ",\"channel\":" + q(channel) +
            ",\"chat_id\":" + q(chat_id) +
            ",\"project_alias\":" + q(project_alias) + "}";
        Response res = import_transcript_message_locked(one);
        if (res.status >= 400) {
            return make_response(400, "{\"error\":\"batch_item_failed\",\"index\":" + std::to_string(i) +
                ",\"status\":" + std::to_string(res.status) +
                ",\"body\":" + q(res.body) + "}");
        }
        if (res.body.find("\"ignored\":true") != std::string::npos) ++ignored;
        else ++imported;
    }
    persist_state_locked();
    return make_response(200, "{\"ok\":true,\"session_id\":" + q(session_id) +
        ",\"endpoint_id\":" + q(endpoint_id) +
        ",\"imported\":" + std::to_string(imported) +
        ",\"ignored\":" + std::to_string(ignored) + "}");
}

void run_mock_task(std::string task_id) {
    const std::vector<std::pair<std::string, std::string>> script = {
        {"codex.thinking.delta", "正在读取移动端任务、工作区和会话目标。"},
        {"codex.thinking.delta", "正在建立公司 Codex 中转链路，并准备流式输出。"},
        {"codex.output.delta", "已接收任务，relay 正在以流式事件同步到 MKB。"},
        {"codex.output.delta", "支持：思考流、打断、运行中引导、切换工作区、新开对话。"},
        {"codex.output.delta", "下一步可以把 worker 替换为真实 Codex CLI/PTY 适配器。"}
    };

    std::string output;
    for (const auto& [type, text] : script) {
        std::this_thread::sleep_for(650ms);
        std::lock_guard<std::mutex> lock(g_mu);
        auto it = g_tasks.find(task_id);
        if (it == g_tasks.end()) return;
        if (it->second.cancelled) {
            it->second.status = "interrupted";
            it->second.phase = "interrupted";
            it->second.last_summary = output.empty() ? "任务已被移动端打断" : output;
            append_event_locked("task.interrupted", task_id, it->second.session_id, "Task interrupted by mobile client");
            return;
        }
        if (type == "codex.output.delta") output += (output.empty() ? "" : "\n") + text;
        it->second.phase = type.find("thinking") != std::string::npos ? "thinking" : "output";
        it->second.last_summary = output.empty() ? text : output;
        append_event_locked(type, task_id, it->second.session_id, text, "{\"delta\":" + q(text) + "}");
    }

    std::lock_guard<std::mutex> lock(g_mu);
    auto it = g_tasks.find(task_id);
    if (it == g_tasks.end()) return;
    it->second.status = "completed";
    it->second.phase = "completed";
    append_event_locked("task.completed", task_id, it->second.session_id, "Task completed");
}

struct CodexSpawn {
    pid_t pid = -1;
    int stdin_fd = -1;
    int stdout_fd = -1;
    int stderr_fd = -1;
    std::string error;
};

CodexSpawn spawn_codex_process(const Session& session, const Project& project, const TaskRecord& task) {
    CodexSpawn result;
    int in_pipe[2] = {-1, -1};
    int out_pipe[2] = {-1, -1};
    int err_pipe[2] = {-1, -1};
    if (pipe(in_pipe) || pipe(out_pipe) || pipe(err_pipe)) {
        result.error = "pipe failed";
        return result;
    }

    std::string cwd = project.path.empty() ? session.cwd : project.path;
    if (cwd.empty()) cwd = relay_default_cwd();
    std::string bin = codex_bin();
    std::string sandbox = env_or("MKB_CODEX_RELAY_SANDBOX", "workspace-write");
    std::string model = task.model.empty() ? env_or("MKB_CODEX_RELAY_MODEL") : task.model;
    std::string reasoning_effort = task.reasoning_effort.empty() ? env_or("MKB_CODEX_RELAY_REASONING_EFFORT") : task.reasoning_effort;
    bool bypass = env_or("MKB_CODEX_RELAY_BYPASS") == "1";
    bool resume = !session.active_turn_id.empty();

    std::vector<std::string> args;
    args.push_back(bin);
    args.push_back("exec");
    if (resume) {
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
        if (bypass) {
            args.push_back("--dangerously-bypass-approvals-and-sandbox");
        }
        args.push_back(session.active_turn_id);
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

void append_task_event(const std::string& type, const std::string& task_id, const std::string& session_id, const std::string& message, const std::string& data_json = "{}") {
    std::lock_guard<std::mutex> lock(g_mu);
    append_event_locked(type, task_id, session_id, message, data_json);
}

void consume_codex_stdout_line(const std::string& line, const std::string& task_id, const std::string& session_id, std::string& output) {
    if (line.empty()) return;
    if (line.front() != '{') {
        append_task_event("codex.diagnostic", task_id, session_id, line, "{\"stream\":\"stdout\"}");
        return;
    }
    if (json_line_has(line, "\"type\":\"thread.started\"")) {
        auto thread_id = json_extract_string(line, "thread_id");
        {
            std::lock_guard<std::mutex> lock(g_mu);
            if (g_sessions.count(session_id) && !thread_id.empty()) {
                g_sessions[session_id].thread_id = thread_id;
            }
        }
        append_task_event("codex.thread.started", task_id, session_id, thread_id, "{\"thread_id\":" + q(thread_id) + "}");
        return;
    }
    if (json_line_has(line, "\"type\":\"turn.started\"")) {
        append_task_event("codex.thinking.delta", task_id, session_id, "Codex 已开始处理任务", "{\"delta\":\"Codex 已开始处理任务\"}");
        return;
    }
    if (json_line_has(line, "\"type\":\"item.completed\"") && json_line_has(line, "\"type\":\"agent_message\"")) {
        auto text = json_extract_string(line, "text");
        if (!text.empty()) {
            output += (output.empty() ? "" : "\n") + text;
            {
                std::lock_guard<std::mutex> lock(g_mu);
                if (g_tasks.count(task_id)) {
                    g_tasks[task_id].phase = "output";
                    g_tasks[task_id].last_summary = output;
                }
                append_event_locked("codex.output.delta", task_id, session_id, text, "{\"delta\":" + q(text) + "}");
            }
        }
        return;
    }
    if (json_line_has(line, "\"type\":\"turn.completed\"")) {
        append_task_event("codex.turn.completed", task_id, session_id, "Codex turn completed");
        return;
    }
    if (json_line_has(line, "\"type\":\"turn.failed\"") || json_line_has(line, "\"type\":\"error\"")) {
        append_task_event("codex.error", task_id, session_id, line, "{\"raw\":" + q(line) + "}");
        return;
    }
}

void consume_codex_stream(CodexSpawn& child, const TaskRecord& snapshot) {
    std::string out_buffer;
    std::string err_buffer;
    std::string output;
    bool stdout_open = child.stdout_fd >= 0;
    bool stderr_open = child.stderr_fd >= 0;

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
                        if (should_emit_diagnostic(line)) append_task_event("codex.diagnostic", snapshot.task_id, snapshot.session_id, line, "{\"stream\":\"stderr\"}");
                    } else {
                        consume_codex_stdout_line(line, snapshot.task_id, snapshot.session_id, output);
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
        {
            std::lock_guard<std::mutex> lock(g_mu);
            if (g_tasks.count(snapshot.task_id) && g_tasks[snapshot.task_id].cancelled && child.pid > 0) {
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
    if (!out_buffer.empty()) consume_codex_stdout_line(out_buffer, snapshot.task_id, snapshot.session_id, output);
    if (should_emit_diagnostic(err_buffer)) append_task_event("codex.diagnostic", snapshot.task_id, snapshot.session_id, err_buffer, "{\"stream\":\"stderr\"}");
}

void run_codex_task(std::string task_id) {
    TaskRecord snapshot;
    Session session;
    Project project;
    {
        std::lock_guard<std::mutex> lock(g_mu);
        if (!g_tasks.count(task_id)) return;
        snapshot = g_tasks[task_id];
        session = g_sessions.count(snapshot.session_id) ? g_sessions[snapshot.session_id] : Session{};
        project = g_projects.count(snapshot.project_alias) ? g_projects[snapshot.project_alias] : Project{};
        g_tasks[task_id].phase = "thinking";
        append_event_locked("codex.backend.selected", task_id, snapshot.session_id, "codex exec", "{\"backend\":\"codex\"}");
    }

    CodexSpawn child = spawn_codex_process(session, project, snapshot);
    if (child.pid < 0) {
        std::lock_guard<std::mutex> lock(g_mu);
        if (g_tasks.count(task_id)) {
            g_tasks[task_id].status = "failed";
            g_tasks[task_id].phase = "failed";
            g_tasks[task_id].last_summary = child.error;
        }
        append_event_locked("task.failed", task_id, snapshot.session_id, child.error);
        return;
    }
    {
        std::lock_guard<std::mutex> lock(g_mu);
        if (g_tasks.count(task_id)) g_tasks[task_id].child_pid = child.pid;
    }
    std::string prompt = snapshot.prompt;
    prompt += "\n\n[Mobile relay context]\n";
    prompt += "task_id=" + snapshot.task_id + "\n";
    prompt += "project_alias=" + snapshot.project_alias + "\n";
    prompt += "session_id=" + snapshot.session_id + "\n";
    prompt += "mode=" + snapshot.mode + "\n";
    if (!snapshot.model.empty()) prompt += "model=" + snapshot.model + "\n";
    if (!snapshot.reasoning_effort.empty()) prompt += "reasoning_effort=" + snapshot.reasoning_effort + "\n";
    const char* write_ptr = prompt.data();
    size_t remaining = prompt.size();
    while (remaining > 0) {
        ssize_t n = write(child.stdin_fd, write_ptr, remaining);
        if (n <= 0) break;
        write_ptr += n;
        remaining -= static_cast<size_t>(n);
    }
    close(child.stdin_fd);

    consume_codex_stream(child, snapshot);

    int status = 0;
    waitpid(child.pid, &status, 0);
    std::lock_guard<std::mutex> lock(g_mu);
    if (!g_tasks.count(task_id)) return;
    g_tasks[task_id].child_pid = -1;
    if (g_tasks[task_id].cancelled) {
        g_tasks[task_id].status = "interrupted";
        g_tasks[task_id].phase = "interrupted";
        append_event_locked("task.interrupted", task_id, snapshot.session_id, "Task interrupted by mobile client");
    } else if (WIFEXITED(status) && WEXITSTATUS(status) == 0) {
        g_tasks[task_id].status = "completed";
        g_tasks[task_id].phase = "completed";
        append_event_locked("task.completed", task_id, snapshot.session_id, "Task completed");
    } else {
        g_tasks[task_id].status = "failed";
        g_tasks[task_id].phase = "failed";
        append_event_locked("task.failed", task_id, snapshot.session_id, "Codex process exited with status " + std::to_string(status));
    }
}

void run_task(std::string task_id) {
    {
        std::lock_guard<std::mutex> lock(g_mu);
        auto it = g_tasks.find(task_id);
        if (it == g_tasks.end()) return;
        it->second.status = "running";
        it->second.phase = "thinking";
        append_event_locked("task.started", task_id, it->second.session_id, "Codex task started");
    }
    if (force_mock_backend()) {
        run_mock_task(task_id);
    } else {
        run_codex_task(task_id);
    }
}

TaskRecord create_task_locked(const std::string& body, const Binding* binding) {
    TaskRecord t;
    t.task_id = "task-" + std::to_string(g_next_task_id++);
    t.profile = binding ? binding->profile : json_string_field(body, "profile", "home-codex");
    t.chat_channel = binding ? binding->channel : json_string_field(body, "channel", "mkb");
    t.chat_id = binding ? binding->chat_id : json_string_field(body, "chat_id", "mkb-ios");
    t.project_alias = binding ? binding->project_alias : json_string_field(body, "project_alias", g_profile_project[t.profile].empty() ? "codex-database" : g_profile_project[t.profile]);
    t.endpoint_id = binding ? binding->endpoint_id : json_string_field(body, "endpoint_id", "company-main");
    t.prompt = json_string_field(body, "prompt", "");
    t.mode = json_string_field(body, "mode", json_string_field(body, "insert_mode", "normal"));
    t.model = json_string_field(body, "model");
    t.reasoning_effort = json_string_field(body, "reasoning_effort", json_string_field(body, "reasoning", ""));
    auto requested_session = binding ? binding->session_id : json_string_field(body, "session_selector", g_profile_session[t.profile]);
    t.session_id = ensure_session_locked(t.project_alias, requested_session);
    if (g_sessions.count(t.session_id)) {
        g_sessions[t.session_id].endpoint_id = t.endpoint_id;
        if (g_sessions[t.session_id].source == "mkb") g_sessions[t.session_id].source = "codex-relay";
    }
    g_tasks.emplace(t.task_id, t);
    g_mobile_prompt_task[mobile_prompt_key(t.session_id, t.prompt)] = t.task_id;
    std::string created_type = "task.created";
    if (t.mode == "insert") created_type = "task.inserted";
    if (t.mode == "steer") created_type = "task.steered";
    append_event_locked(created_type, t.task_id, t.session_id, t.prompt, "{\"mode\":" + q(t.mode) + ",\"model\":" + q(t.model) + ",\"reasoning_effort\":" + q(t.reasoning_effort) + "}");
    if (broker_backend()) {
        append_event_locked("codex.backend.selected", t.task_id, t.session_id, "broker relay", "{\"backend\":\"broker\"}");
        append_event_locked("task.queued", t.task_id, t.session_id, "Task queued for external worker");
    } else {
        std::thread(run_task, t.task_id).detach();
    }
    return g_tasks[t.task_id];
}

TaskRecord create_steer_marker_locked(const std::string& endpoint_id,
                                      const std::string& session_id,
                                      const std::string& project_alias,
                                      const std::string& prompt,
                                      const std::string& model,
                                      const std::string& reasoning_effort) {
    TaskRecord t;
    t.task_id = "steer-" + std::to_string(g_next_task_id++);
    t.profile = "home-codex";
    t.chat_channel = "mkb";
    t.chat_id = "mkb-ios";
    t.endpoint_id = endpoint_id.empty() ? g_endpoint.endpoint_id : endpoint_id;
    t.project_alias = project_alias.empty() ? (g_profile_project[t.profile].empty() ? "codex-database" : g_profile_project[t.profile]) : project_alias;
    t.session_id = ensure_session_locked(t.project_alias, session_id);
    t.prompt = prompt;
    t.mode = "steer";
    t.model = model;
    t.reasoning_effort = reasoning_effort;
    t.status = "completed";
    t.phase = "completed";
    if (g_sessions.count(t.session_id)) {
        g_sessions[t.session_id].endpoint_id = t.endpoint_id;
        if (g_sessions[t.session_id].source == "mkb") g_sessions[t.session_id].source = "codex-relay";
    }
    g_tasks.emplace(t.task_id, t);
    g_mobile_prompt_task[mobile_prompt_key(t.session_id, t.prompt)] = t.task_id;
    append_event_locked("task.steered", t.task_id, t.session_id, t.prompt,
                        "{\"mode\":\"steer\",\"model\":" + q(t.model) + ",\"reasoning_effort\":" + q(t.reasoning_effort) + "}");
    return g_tasks[t.task_id];
}

std::string worker_task_payload_locked(const TaskRecord& t) {
    std::string project = g_projects.count(t.project_alias) ? project_json(g_projects[t.project_alias]) : "null";
    std::string session = g_sessions.count(t.session_id) ? session_json(g_sessions[t.session_id]) : "null";
    return "{\"task\":" + task_json(t) + ",\"project\":" + project +
           ",\"session\":" + session + ",\"cancelled\":" + std::string(t.cancelled ? "true" : "false") + "}";
}

void finish_worker_task_locked(const std::string& worker_id, const std::string& task_id) {
    auto wit = g_workers.find(worker_id);
    if (wit != g_workers.end() && wit->second.active_task_id == task_id) {
        wit->second.active_task_id.clear();
        wit->second.status = "online";
        wit->second.last_seen_at = now_iso();
    }
}

Response make_response(int status, const std::string& body, const std::string& type) {
    return Response{status, type, body};
}

Response handle_request(const Request& req) {
    std::lock_guard<std::mutex> lock(g_mu);
    if (req.path == "/health") {
        return make_response(200, "{\"ok\":true,\"service\":\"mkb-codex-relay\",\"version\":\"0.1.0\",\"backend\":" + q(backend_mode()) + ",\"workers\":" + std::to_string(g_workers.size()) + "}");
    }
    if (req.path == "/api/admin/history/compact" && req.method == "POST") {
        return make_response(410, "{\"error\":\"history_compact_disabled\",\"reason\":\"prompt-based compaction hides real recent sessions\"}");
    }
    normalize_cancelled_tasks_locked();
    if (req.path == "/v1/state" && req.method == "GET") {
        std::set<std::string> endpoint_ids = {g_endpoint.endpoint_id};
        std::vector<Project> projects;
        for (auto& kv : g_projects) {
            projects.push_back(kv.second);
            endpoint_ids.insert(kv.second.endpoint_id);
        }
        std::vector<Session> sessions = v1_sessions_limited_locked();
        for (const auto& session : sessions) endpoint_ids.insert(session.endpoint_id);
        std::vector<std::string> endpoints;
        for (const auto& endpoint_id : endpoint_ids) endpoints.push_back(v1_endpoint_json(endpoint_id));
        auto messages = v1_messages_locked("", "", 0);
        auto states = v1_message_states_locked("", "");
        return make_response(200, "{\"endpoints\":" + json_array(endpoints, [](const std::string& item) { return item; }) +
            ",\"projects\":" + json_array(projects, project_json) +
            ",\"sessions\":" + json_array(sessions, session_json) +
            ",\"message_count\":" + std::to_string(messages.size()) +
            ",\"message_state_count\":" + std::to_string(states.size()) +
            ",\"event_count\":" + std::to_string(g_events.size()) +
            ",\"next_event_id\":" + std::to_string(g_next_event_id) + "}");
    }
    if (req.path == "/v1/messages" && req.method == "GET") {
        std::string endpoint_id = req.query.count("endpoint_id") ? req.query.at("endpoint_id") : "";
        std::string session_id = req.query.count("session_id") ? req.query.at("session_id") : "";
        long long after_seq = req.query.count("after_seq") ? std::stoll(req.query.at("after_seq")) : 0;
        auto messages = v1_messages_locked(endpoint_id, session_id, after_seq);
        return make_response(200, "{\"messages\":" + json_array(messages, [](const std::string& item) { return item; }) + "}");
    }
    if (req.path == "/v1/message_states" && req.method == "GET") {
        std::string endpoint_id = req.query.count("endpoint_id") ? req.query.at("endpoint_id") : "";
        std::string session_id = req.query.count("session_id") ? req.query.at("session_id") : "";
        auto states = v1_message_states_locked(endpoint_id, session_id);
        return make_response(200, "{\"states\":" + json_array(states, [](const std::string& item) { return item; }) + "}");
    }
    if (req.path == "/v1/events" && req.method == "GET") {
        std::string endpoint_id = req.query.count("endpoint_id") ? req.query.at("endpoint_id") : "";
        std::string session_id = req.query.count("session_id") ? req.query.at("session_id") : "";
        long long after = req.query.count("after") ? std::stoll(req.query.at("after")) : 0;
        std::vector<Event> selected;
        for (const auto& event : g_events) {
            if (event.event_id <= after) continue;
            if (!endpoint_id.empty() && event.endpoint_id != endpoint_id) continue;
            if (!session_id.empty() && event.session_id != session_id) continue;
            selected.push_back(event);
        }
        return make_response(200, "{\"events\":" + json_array(selected, event_json) + "}");
    }
    if (req.path == "/v1/commands" && req.method == "POST") {
        PersistDeferral persist_once;
        long long command_id = g_next_v1_command_id++;
        std::string endpoint_id = json_string_field(req.body, "endpoint_id", g_endpoint.endpoint_id);
        std::string session_id = json_string_field(req.body, "session_id", g_profile_session["home-codex"]);
        std::string type = json_string_field(req.body, "type", "turn.send");
        std::string payload_json = json_string_field(req.body, "payload_json", "{}");
        std::string project_alias = json_string_field(payload_json, "project_alias", g_profile_project["home-codex"].empty() ? "codex-database" : g_profile_project["home-codex"]);
        if (type == "conversation.new") {
            std::string sid = ensure_session_locked(project_alias);
            g_sessions[sid].endpoint_id = endpoint_id;
            g_sessions[sid].source = "codex-relay";
            g_profile_session["home-codex"] = sid;
            append_event_locked("conversation.created", "", sid, "New conversation created", "{\"command_id\":" + std::to_string(command_id) + "}");
            return make_response(200, "{\"command_id\":" + std::to_string(command_id) +
                ",\"endpoint_id\":" + q(endpoint_id) + ",\"session_id\":" + q(sid) +
                ",\"type\":" + q(type) + ",\"status\":\"handled\"}");
        }
        if (type == "turn.interrupt") {
            std::string target;
            for (auto& kv : g_tasks) {
                auto& task = kv.second;
                if (task.session_id != session_id) continue;
                if (task.status == "running" || task.status == "queued") target = task.task_id;
            }
            if (!target.empty() && g_tasks.count(target)) {
                auto& task = g_tasks[target];
                task.cancelled = true;
                if (task.status == "queued" || task.status == "running") {
                    task.status = "interrupted";
                    task.phase = "interrupted";
                }
                if (task.child_pid > 0) kill(-task.child_pid, SIGTERM);
                append_event_locked("task.interrupt.requested", target, task.session_id, "Interrupt requested", "{\"command_id\":" + std::to_string(command_id) + "}");
            }
            return make_response(200, "{\"command_id\":" + std::to_string(command_id) +
                ",\"endpoint_id\":" + q(endpoint_id) + ",\"session_id\":" + q(session_id) +
                ",\"type\":" + q(type) + ",\"status\":\"handled\",\"target\":" + q(target) + "}");
        }
        std::string prompt = json_string_field(payload_json, "text", "");
        if (prompt.empty()) return make_response(400, "{\"error\":\"empty_prompt\"}");
        if (type == "turn.steer") {
            std::string target;
            for (auto& kv : g_tasks) {
                auto& task = kv.second;
                if (task.session_id != session_id) continue;
                if (task.status == "running") target = task.task_id;
            }
            if (target.empty()) {
                return make_response(409, "{\"error\":\"no_active_task\",\"command_id\":" + std::to_string(command_id) +
                    ",\"endpoint_id\":" + q(endpoint_id) + ",\"session_id\":" + q(session_id) +
                    ",\"type\":" + q(type) + "}");
            }
            SteerControl steer;
            steer.steer_id = g_next_steer_id++;
            steer.text = prompt;
            g_task_steers[target].push_back(steer);
            TaskRecord marker = create_steer_marker_locked(
                endpoint_id,
                session_id,
                project_alias,
                prompt,
                json_string_field(payload_json, "model", ""),
                json_string_field(payload_json, "reasoning_effort", "")
            );
            append_event_locked("turn.steer.queued", target, session_id, prompt,
                                "{\"command_id\":" + std::to_string(command_id) +
                                ",\"steer_id\":" + std::to_string(steer.steer_id) +
                                ",\"marker_task_id\":" + q(marker.task_id) + "}");
            return make_response(200, "{\"command_id\":" + std::to_string(command_id) +
                ",\"endpoint_id\":" + q(endpoint_id) + ",\"session_id\":" + q(session_id) +
                ",\"type\":" + q(type) + ",\"status\":\"handled\",\"target\":" + q(target) +
                ",\"task_id\":" + q(marker.task_id) +
                ",\"steer_id\":" + std::to_string(steer.steer_id) + "}");
        }
        std::string mode = type == "turn.insert" ? "insert" : json_string_field(payload_json, "mode", "normal");
        std::string task_body = "{\"profile\":\"home-codex\",\"channel\":\"mkb\",\"chat_id\":\"mkb-ios\",\"endpoint_id\":" + q(endpoint_id) +
            ",\"project_alias\":" + q(project_alias) +
            ",\"session_selector\":" + q(session_id) +
            ",\"prompt\":" + q(prompt) +
            ",\"mode\":" + q(mode) +
            ",\"model\":" + q(json_string_field(payload_json, "model", "")) +
            ",\"reasoning_effort\":" + q(json_string_field(payload_json, "reasoning_effort", "")) + "}";
        TaskRecord task = create_task_locked(task_body, nullptr);
        append_event_locked("command.queued", task.task_id, task.session_id, "Command queued: " + type, "{\"command_id\":" + std::to_string(command_id) + "}");
        return make_response(200, "{\"command_id\":" + std::to_string(command_id) +
            ",\"endpoint_id\":" + q(endpoint_id) + ",\"session_id\":" + q(task.session_id) +
            ",\"type\":" + q(type) + ",\"status\":\"queued\",\"task_id\":" + q(task.task_id) + "}");
    }
    if (req.path == "/api/state" && req.method == "GET") {
        std::vector<Endpoint> endpoints = {g_endpoint};
        std::vector<Project> projects;
        std::vector<Session> sessions;
        std::vector<TaskRecord> tasks;
        for (auto& kv : g_projects) projects.push_back(kv.second);
        for (auto& kv : g_sessions) sessions.push_back(kv.second);
        for (auto it = g_tasks.rbegin(); it != g_tasks.rend(); ++it) tasks.push_back(it->second);
        std::vector<Worker> workers;
        for (auto& kv : g_workers) workers.push_back(kv.second);
        return make_response(200, "{\"endpoints\":" + json_array(endpoints, endpoint_json) +
            ",\"projects\":" + json_array(projects, project_json) +
            ",\"sessions\":" + json_array(sessions, session_json) +
            ",\"tasks\":" + json_array(tasks, task_json) +
            ",\"workers\":" + json_array(workers, worker_json) + "}");
    }
    if (req.path == "/api/summary" && req.method == "GET") {
        std::string profile = req.query.count("profile") ? req.query.at("profile") : "home-codex";
        std::vector<TaskRecord> active, recent;
        for (auto it = g_tasks.rbegin(); it != g_tasks.rend(); ++it) {
            if (it->second.status == "running" || it->second.status == "queued") active.push_back(it->second);
            if (recent.size() < 10) recent.push_back(it->second);
        }
        std::string context = "{\"profile\":" + q(profile) + ",\"project_alias\":" + q(g_profile_project[profile]) + ",\"session_id\":" + q(g_profile_session[profile]) + ",\"updated_at\":" + q(now_iso()) + "}";
        return make_response(200, "{\"context\":" + context + ",\"endpoints\":[" + endpoint_json(g_endpoint) +
            "],\"active_tasks\":" + json_array(active, task_json) +
            ",\"recent_tasks\":" + json_array(recent, task_json) +
            ",\"counts\":{\"active\":" + std::to_string(active.size()) + ",\"recent\":" + std::to_string(recent.size()) + ",\"sessions\":" + std::to_string(g_sessions.size()) + "}}");
    }
    if (req.path == "/api/events" && req.method == "GET") {
        std::string target = req.query.count("target") ? req.query.at("target") : "";
        int tail = req.query.count("tail") ? std::stoi(req.query.at("tail")) : 50;
        std::vector<Event> selected;
        for (auto it = g_events.rbegin(); it != g_events.rend() && static_cast<int>(selected.size()) < tail; ++it) {
            if (target.empty() || it->task_id == target || it->session_id == target) selected.push_back(*it);
        }
        std::reverse(selected.begin(), selected.end());
        return make_response(200, "{\"events\":" + json_array(selected, event_json) + "}");
    }
    if (req.path == "/api/workers/register" && req.method == "POST") {
        Worker w;
        w.worker_id = json_string_field(req.body, "worker_id", "worker-default");
        w.label = json_string_field(req.body, "label", "Codex Worker");
        w.status = "online";
        w.last_seen_at = now_iso();
        auto existing = g_workers.find(w.worker_id);
        if (existing != g_workers.end()) {
            w.active_task_id = existing->second.active_task_id;
        }
        g_workers[w.worker_id] = w;
        append_event_locked("worker.online", "", "", "Worker online: " + w.worker_id, "{\"worker_id\":" + q(w.worker_id) + "}");
        return make_response(200, worker_json(w));
    }
    if (req.path == "/api/workers/heartbeat" && req.method == "POST") {
        std::string worker_id = json_string_field(req.body, "worker_id", "worker-default");
        auto& w = g_workers[worker_id];
        if (w.worker_id.empty()) w.worker_id = worker_id;
        w.label = json_string_field(req.body, "label", w.label);
        w.status = json_string_field(req.body, "status", w.status.empty() ? "online" : w.status);
        w.last_seen_at = now_iso();
        return make_response(200, worker_json(w));
    }
    if (req.path == "/api/workers/tasks" && req.method == "GET") {
        std::string worker_id = req.query.count("worker_id") ? req.query.at("worker_id") : "worker-default";
        auto& w = g_workers[worker_id];
        if (w.worker_id.empty()) {
            w.worker_id = worker_id;
            w.label = "Codex Worker";
        }
        w.last_seen_at = now_iso();
        if (!w.active_task_id.empty() && g_tasks.count(w.active_task_id)) {
            return make_response(200, worker_task_payload_locked(g_tasks[w.active_task_id]));
        }
        for (auto& kv : g_tasks) {
            auto& task = kv.second;
            if (task.status != "queued") continue;
            task.status = "running";
            task.phase = "thinking";
            w.status = "busy";
            w.active_task_id = task.task_id;
            append_event_locked("task.started", task.task_id, task.session_id, "Worker accepted task", "{\"worker_id\":" + q(worker_id) + "}");
            return make_response(200, worker_task_payload_locked(task));
        }
        w.status = "online";
        return make_response(200, "{\"task\":null,\"cancelled\":false}");
    }
    if (req.path == "/api/workers/control" && req.method == "GET") {
        std::string task_id = req.query.count("task_id") ? req.query.at("task_id") : "";
        bool cancelled = !task_id.empty() && g_tasks.count(task_id) && g_tasks[task_id].cancelled;
        long long steer_id = 0;
        std::string steer_text;
        auto sit = g_task_steers.find(task_id);
        if (sit != g_task_steers.end() && !sit->second.empty()) {
            SteerControl steer = sit->second.front();
            sit->second.erase(sit->second.begin());
            if (sit->second.empty()) g_task_steers.erase(sit);
            steer_id = steer.steer_id;
            steer_text = steer.text;
        }
        return make_response(200, "{\"task_id\":" + q(task_id) +
            ",\"cancelled\":" + std::string(cancelled ? "true" : "false") +
            ",\"steer_id\":" + std::to_string(steer_id) +
            ",\"steer_text\":" + q(steer_text) + "}");
    }
    if (req.path == "/api/workers/events" && req.method == "POST") {
        std::string worker_id = json_string_field(req.body, "worker_id", "worker-default");
        std::string task_id = json_string_field(req.body, "task_id", "");
        std::string type = json_string_field(req.body, "type", "worker.event");
        std::string message = json_string_field(req.body, "message", "");
        std::string data_json = json_string_field(req.body, "data_json", "{}");
        if (data_json.empty() || data_json.front() != '{') data_json = "{}";
        std::string session_id = g_tasks.count(task_id) ? g_tasks[task_id].session_id : json_string_field(req.body, "session_id", "");
        if (g_workers.count(worker_id)) g_workers[worker_id].last_seen_at = now_iso();
        if (g_tasks.count(task_id)) {
            auto& task = g_tasks[task_id];
            bool terminal = is_terminal_status(task.status);
            if (terminal && (type == "task.completed" || type == "task.interrupted" ||
                             type == "task.failed" || type == "codex.error")) {
                std::string original_type = type;
                type = "worker.late_terminal_event";
                message = "Ignored late " + original_type + " after task " + task.status +
                    (message.empty() ? "" : ": " + message);
                data_json = "{\"original_type\":" + q(original_type) +
                    ",\"preserved_status\":" + q(task.status) + "}";
                finish_worker_task_locked(worker_id, task_id);
                append_event_locked(type, task_id, session_id, message, data_json);
                return make_response(200, "{\"ok\":true,\"ignored_late_terminal\":true}");
            }
            if (!terminal && type == "codex.thinking.delta") task.phase = "thinking";
            if (!terminal && type == "codex.output.delta") {
                task.phase = "output";
                task.last_summary += message;
            }
            if (type == "vscode.ipc.conversation.selected" && g_sessions.count(task.session_id)) {
                auto conversation_id = json_string_field(data_json, "conversation_id", "");
                if (!conversation_id.empty()) {
                    g_sessions[task.session_id].thread_id = conversation_id;
                    g_sessions[task.session_id].status = "running";
                }
            }
            if (type == "codex.thread.started") {
                auto thread_id = json_string_field(req.body, "thread_id", "");
                if (!thread_id.empty() && g_sessions.count(task.session_id)) g_sessions[task.session_id].thread_id = thread_id;
            }
            if (type == "codex.turn.started" && g_sessions.count(task.session_id)) {
                auto thread_id = json_string_field(req.body, "thread_id", "");
                auto turn_id = json_string_field(req.body, "turn_id", "");
                if (!thread_id.empty()) g_sessions[task.session_id].thread_id = thread_id;
                if (!turn_id.empty()) g_sessions[task.session_id].active_turn_id = turn_id;
                g_sessions[task.session_id].status = "running";
            }
            if ((type == "codex.turn.completed" || type == "task.completed" || type == "task.interrupted" ||
                 type == "task.failed" || type == "codex.error") && g_sessions.count(task.session_id)) {
                g_sessions[task.session_id].active_turn_id.clear();
                g_sessions[task.session_id].status = "idle";
            }
            if (!terminal && (type == "desktop.injected" || type == "vscode.ipc.sent")) {
                task.status = "running";
                task.phase = "desktop";
                finish_worker_task_locked(worker_id, task_id);
            } else if (type == "task.completed") {
                if (trim_copy(task.last_summary).empty() && task.phase == "desktop") {
                    type = "task.awaiting_output";
                    message = "Waiting for Codex transcript output";
                    data_json = "{\"reason\":\"completed_without_output\",\"deferred\":true}";
                    task.status = "running";
                    task.phase = "desktop";
                    finish_worker_task_locked(worker_id, task_id);
                } else if (trim_copy(task.last_summary).empty()) {
                    task.status = "failed";
                    task.phase = "failed";
                    task.last_summary = "Codex 已结束但没有返回内容";
                    type = "task.failed";
                    message = task.last_summary;
                    data_json = "{\"reason\":\"completed_without_output\"}";
                    finish_worker_task_locked(worker_id, task_id);
                } else {
                    task.status = "completed";
                    task.phase = "completed";
                    finish_worker_task_locked(worker_id, task_id);
                }
            } else if (type == "task.interrupted") {
                task.status = "interrupted";
                task.phase = "interrupted";
                task.cancelled = true;
                finish_worker_task_locked(worker_id, task_id);
            } else if (type == "task.failed" || type == "codex.error") {
                task.status = "failed";
                task.phase = "failed";
                if (!message.empty()) task.last_summary = message;
                finish_worker_task_locked(worker_id, task_id);
            }
        }
        append_event_locked(type, task_id, session_id, message, data_json);
        return make_response(200, "{\"ok\":true}");
    }
    if (req.path == "/api/projects" && req.method == "POST") {
        Project p;
        p.alias = json_string_field(req.body, "alias", "codex-database");
        p.endpoint_id = json_string_field(req.body, "endpoint_id", "company-main");
        p.path = json_string_field(req.body, "path", "");
        p.mode = json_string_field(req.body, "mode", "headless");
        g_projects[p.alias] = p;
        persist_state_locked();
        return make_response(200, project_json(p));
    }
    if ((req.path == "/api/context/project" || req.path == "/api/workspaces/switch") && req.method == "POST") {
        std::string profile = json_string_field(req.body, "profile", "home-codex");
        std::string alias = json_string_field(req.body, "project_alias", json_string_field(req.body, "alias", "codex-database"));
        g_profile_project[profile] = alias;
        append_event_locked("workspace.switched", "", g_profile_session[profile], "Workspace switched to " + alias, "{\"project_alias\":" + q(alias) + "}");
        return make_response(200, "{\"profile\":" + q(profile) + ",\"project_alias\":" + q(alias) + ",\"session_id\":" + q(g_profile_session[profile]) + ",\"updated_at\":" + q(now_iso()) + "}");
    }
    if (req.path == "/api/context/session" && req.method == "POST") {
        std::string profile = json_string_field(req.body, "profile", "home-codex");
        std::string selector = json_string_field(req.body, "session_selector", "");
        std::string sid = ensure_session_locked(g_profile_project[profile].empty() ? "codex-database" : g_profile_project[profile], selector);
        auto& session = g_sessions[sid];
        std::string thread_id = json_string_field(req.body, "thread_id", json_string_field(req.body, "threadId", ""));
        std::string title = json_string_field(req.body, "title", "");
        std::string cwd = json_string_field(req.body, "cwd", "");
        std::string source = json_string_field(req.body, "source", "");
        if (!thread_id.empty()) session.thread_id = thread_id;
        if (!title.empty()) session.title = title;
        if (!cwd.empty()) session.cwd = cwd;
        if (!source.empty()) session.source = source;
        g_profile_session[profile] = sid;
        append_event_locked("session.switched", "", sid, "Session switched to " + sid);
        return make_response(200, "{\"profile\":" + q(profile) + ",\"project_alias\":" + q(g_profile_project[profile]) + ",\"session_id\":" + q(sid) + ",\"updated_at\":" + q(now_iso()) + "}");
    }
    if (req.path == "/api/context/clear" && req.method == "POST") {
        std::string profile = json_string_field(req.body, "profile", "home-codex");
        g_profile_project.erase(profile);
        g_profile_session.erase(profile);
        persist_state_locked();
        return make_response(200, "{\"profile\":" + q(profile) + ",\"project_alias\":\"\",\"session_id\":\"\",\"updated_at\":" + q(now_iso()) + "}");
    }
    if (req.path == "/api/conversations" && req.method == "POST") {
        std::string project = json_string_field(req.body, "project_alias", "codex-database");
        std::string profile = json_string_field(req.body, "profile", "home-codex");
        std::string sid = ensure_session_locked(project);
        g_profile_session[profile] = sid;
        append_event_locked("conversation.created", "", sid, "New conversation created");
        return make_response(200, session_json(g_sessions[sid]));
    }
    if (req.path == "/api/chat-bindings" && req.method == "GET") {
        std::string key = binding_key(req.query.count("channel") ? req.query.at("channel") : "mkb", req.query.count("chat_id") ? req.query.at("chat_id") : "mkb-ios");
        auto it = g_bindings.find(key);
        std::string binding = it == g_bindings.end() ? "null" : binding_json(it->second);
        std::string active = "null";
        std::vector<TaskRecord> recent;
        std::set<std::string> seen_recent;
        for (auto rit = g_tasks.rbegin(); rit != g_tasks.rend(); ++rit) {
            if (rit->second.chat_channel + ":" + rit->second.chat_id != key) continue;
            if ((rit->second.status == "running" || rit->second.status == "queued") && active == "null") {
                active = task_json(rit->second);
            }
        }
        for (auto eit = g_events.rbegin(); eit != g_events.rend() && recent.size() < 20; ++eit) {
            if (eit->task_id.empty() || seen_recent.count(eit->task_id) || !g_tasks.count(eit->task_id)) continue;
            const auto& task = g_tasks[eit->task_id];
            if (task.chat_channel + ":" + task.chat_id != key) continue;
            recent.push_back(task);
            seen_recent.insert(eit->task_id);
        }
        return make_response(200, "{\"binding\":" + binding + ",\"active_task\":" + active + ",\"recent_tasks\":" + json_array(recent, task_json) + "}");
    }
    if (req.path == "/api/chat-bindings" && req.method == "POST") {
        Binding b;
        b.channel = json_string_field(req.body, "channel", "mkb");
        b.chat_id = json_string_field(req.body, "chat_id", "mkb-ios");
        b.profile = json_string_field(req.body, "profile", "home-codex");
        b.project_alias = json_string_field(req.body, "project_alias", "codex-database");
        b.endpoint_id = json_string_field(req.body, "endpoint_id", "company-main");
        b.session_policy = json_string_field(req.body, "session_policy", "project-default");
        b.session_id = b.session_policy == "fixed-session" ? ensure_session_locked(b.project_alias, g_profile_session[b.profile]) : ensure_session_locked(b.project_alias);
        g_bindings[binding_key(b.channel, b.chat_id)] = b;
        return make_response(200, binding_json(b));
    }
    if (req.path == "/api/chat-bindings/clear" && req.method == "POST") {
        g_bindings.erase(binding_key(json_string_field(req.body, "channel", "mkb"), json_string_field(req.body, "chat_id", "mkb-ios")));
        return make_response(200, "{\"ok\":true}");
    }
    if (req.path == "/api/session-chats" && req.method == "GET") {
        std::vector<std::string> rows;
        int n = 1;
        for (auto& kv : g_bindings) {
            std::string session = kv.second.session_id.empty() || !g_sessions.count(kv.second.session_id) ? "null" : session_json(g_sessions[kv.second.session_id]);
            rows.push_back("{\"number\":" + std::to_string(n++) + ",\"binding\":" + binding_json(kv.second) + ",\"session\":" + session + "}");
        }
        return make_response(200, "{\"mappings\":" + json_array(rows, [](const std::string& s) { return s; }) + "}");
    }
    if (req.path == "/api/session-chats/sync" && req.method == "POST") {
        return make_response(200, "{\"ok\":true,\"synced\":" + std::to_string(g_bindings.size()) + "}");
    }
    if (req.path == "/api/transcript/session" && req.method == "POST") {
        return import_transcript_session_locked(req.body);
    }
    if (req.path == "/api/history/load" && req.method == "POST") {
        std::string endpoint_id = json_string_field(req.body, "endpoint_id", g_endpoint.endpoint_id);
        std::string session_id = json_string_field(req.body, "session_id", "");
        bool force = json_bool_field(req.body, "force", false);
        if (session_id.empty()) return make_response(400, "{\"error\":\"empty_session_id\"}");
        bool loaded = session_history_loaded_locked(endpoint_id, session_id);
        HistoryLoadRequest request = loaded && !force
            ? HistoryLoadRequest{endpoint_id, session_id, now_iso()}
            : queue_history_load_locked(endpoint_id, session_id, force);
        return make_response(200, "{\"ok\":true,\"status\":" + q(loaded && !force ? "loaded" : "queued") +
            ",\"forced\":" + std::string(force ? "true" : "false") +
            ",\"request\":" + history_load_request_json(request) + "}");
    }
    if (req.path == "/api/history/requests" && req.method == "GET") {
        std::string endpoint_id = req.query.count("endpoint_id") ? req.query.at("endpoint_id") : "";
        int limit = req.query.count("limit") ? std::stoi(req.query.at("limit")) : 20;
        bool include_loaded = req.query.count("include_loaded") &&
            (req.query.at("include_loaded") == "1" || req.query.at("include_loaded") == "true");
        if (limit <= 0) limit = 20;
        std::vector<HistoryLoadRequest> requests;
        std::set<std::string> seen;
        for (const auto& kv : g_history_load_requests) {
            if (!endpoint_id.empty() && kv.second.endpoint_id != endpoint_id) continue;
            requests.push_back(kv.second);
            seen.insert(history_key(kv.second.endpoint_id, kv.second.session_id));
        }
        if (include_loaded) {
            for (const auto& key : g_history_loaded_sessions) {
                if (seen.count(key)) continue;
                HistoryLoadRequest request = loaded_history_request_from_key_locked(key);
                if (request.session_id.empty()) continue;
                if (!endpoint_id.empty() && request.endpoint_id != endpoint_id) continue;
                requests.push_back(request);
            }
        }
        std::sort(requests.begin(), requests.end(), [](const HistoryLoadRequest& lhs, const HistoryLoadRequest& rhs) {
            if (lhs.requested_at != rhs.requested_at) return lhs.requested_at > rhs.requested_at;
            return lhs.session_id < rhs.session_id;
        });
        if (static_cast<int>(requests.size()) > limit) requests.resize(limit);
        return make_response(200, "{\"requests\":" + json_array(requests, history_load_request_json) + "}");
    }
    if (req.path == "/api/history/complete" && req.method == "POST") {
        std::string endpoint_id = json_string_field(req.body, "endpoint_id", g_endpoint.endpoint_id);
        std::string session_id = json_string_field(req.body, "session_id", "");
        if (session_id.empty()) return make_response(400, "{\"error\":\"empty_session_id\"}");
        mark_history_loaded_locked(endpoint_id, session_id);
        persist_state_locked();
        return make_response(200, "{\"ok\":true,\"status\":\"loaded\",\"endpoint_id\":" + q(endpoint_id) +
            ",\"session_id\":" + q(session_id) + "}");
    }
    if (req.path == "/api/transcript/message" && req.method == "POST") {
        return import_transcript_message_locked(req.body);
    }
    if (req.path == "/api/transcript/messages" && req.method == "POST") {
        return import_transcript_messages_locked(req.body);
    }
    if (req.path == "/api/tasks" && req.method == "POST") {
        PersistDeferral persist_once;
        return make_response(200, task_json(create_task_locked(req.body, nullptr)));
    }
    if (req.path == "/api/chat-bindings/task" && req.method == "POST") {
        PersistDeferral persist_once;
        auto key = binding_key(json_string_field(req.body, "channel", "mkb"), json_string_field(req.body, "chat_id", "mkb-ios"));
        auto it = g_bindings.find(key);
        Binding fallback;
        fallback.channel = json_string_field(req.body, "channel", "mkb");
        fallback.chat_id = json_string_field(req.body, "chat_id", "mkb-ios");
        const Binding* b = it == g_bindings.end() ? &fallback : &it->second;
        return make_response(200, task_json(create_task_locked(req.body, b)));
    }
    if ((req.path == "/api/stop" || req.path == "/api/chat-bindings/stop") && req.method == "POST") {
        std::string target = json_string_field(req.body, "target", "");
        if (target.empty() && req.path == "/api/chat-bindings/stop") {
            std::string key = binding_key(json_string_field(req.body, "channel", "mkb"), json_string_field(req.body, "chat_id", "mkb-ios"));
            for (auto& kv : g_tasks) {
                if (kv.second.chat_channel + ":" + kv.second.chat_id == key && kv.second.status == "running") target = kv.first;
            }
        }
        if (!target.empty() && g_tasks.count(target)) {
            g_tasks[target].cancelled = true;
            if (g_tasks[target].child_pid > 0) {
                kill(-g_tasks[target].child_pid, SIGTERM);
            }
            append_event_locked("task.interrupt.requested", target, g_tasks[target].session_id, "Interrupt requested");
        }
        return make_response(200, "{\"ok\":true,\"target\":" + q(target) + "}");
    }
    return make_response(404, "{\"error\":\"not_found\",\"path\":" + q(req.path) + "}");
}

bool read_request(int fd, Request& req) {
    std::string data;
    char buf[4096];
    while (data.find("\r\n\r\n") == std::string::npos) {
        ssize_t n = recv(fd, buf, sizeof(buf), 0);
        if (n <= 0) return false;
        data.append(buf, n);
        if (data.size() > 1024 * 1024) return false;
    }
    auto header_end = data.find("\r\n\r\n");
    std::string header = data.substr(0, header_end);
    std::istringstream hs(header);
    hs >> req.method >> req.target;
    req.query = parse_query(req.target, req.path);
    int content_length = 0;
    std::string line;
    while (std::getline(hs, line)) {
        if (!line.empty() && line.back() == '\r') line.pop_back();
        auto colon = line.find(':');
        if (colon == std::string::npos) continue;
        std::string key = line.substr(0, colon);
        std::string val = line.substr(colon + 1);
        if (key == "Content-Length" || key == "content-length") content_length = std::stoi(val);
    }
    req.body = data.substr(header_end + 4);
    while (static_cast<int>(req.body.size()) < content_length) {
        ssize_t n = recv(fd, buf, sizeof(buf), 0);
        if (n <= 0) return false;
        req.body.append(buf, n);
    }
    if (static_cast<int>(req.body.size()) > content_length) req.body.resize(content_length);
    return !req.method.empty();
}

void send_http(int fd, const Response& res) {
    std::ostringstream out;
    out << "HTTP/1.1 " << res.status << (res.status == 200 ? " OK" : " Error") << "\r\n";
    out << "Content-Type: " << res.content_type << "\r\n";
    out << "Access-Control-Allow-Origin: *\r\n";
    out << "Access-Control-Allow-Headers: Authorization, Content-Type\r\n";
    out << "Content-Length: " << res.body.size() << "\r\n";
    out << "Connection: close\r\n\r\n";
    out << res.body;
    auto s = out.str();
    send(fd, s.data(), s.size(), MSG_NOSIGNAL);
}

void send_sse_event(int fd, const Event& e) {
    std::string payload = "id: " + std::to_string(e.event_id) + "\n";
    payload += "event: " + e.type + "\n";
    payload += "data: " + event_json(e) + "\n\n";
    send(fd, payload.data(), payload.size(), MSG_NOSIGNAL);
}

void handle_sse(int fd, const Request& req) {
    std::string header = "HTTP/1.1 200 OK\r\nContent-Type: text/event-stream; charset=utf-8\r\nCache-Control: no-cache\r\nConnection: keep-alive\r\nAccess-Control-Allow-Origin: *\r\n\r\n";
    send(fd, header.data(), header.size(), MSG_NOSIGNAL);
    std::string target = req.query.count("target") ? req.query.at("target") : "";
    long long cursor = req.query.count("cursor") ? std::stoll(req.query.at("cursor")) : 0;
    while (g_running.load()) {
        std::unique_lock<std::mutex> lock(g_mu);
        g_events_cv.wait_for(lock, 15s, [&] {
            for (const auto& e : g_events) {
                if (e.event_id > cursor && (target.empty() || e.task_id == target || e.session_id == target)) return true;
            }
            return !g_running.load();
        });
        std::vector<Event> pending;
        for (const auto& e : g_events) {
            if (e.event_id > cursor && (target.empty() || e.task_id == target || e.session_id == target)) pending.push_back(e);
        }
        if (pending.empty()) {
            lock.unlock();
            std::string ping = ": keepalive\n\n";
            if (send(fd, ping.data(), ping.size(), MSG_NOSIGNAL) <= 0) break;
            continue;
        }
        lock.unlock();
        for (const auto& e : pending) {
            send_sse_event(fd, e);
            cursor = e.event_id;
        }
    }
}

void handle_client(int fd) {
    Request req;
    if (!read_request(fd, req)) {
        close(fd);
        return;
    }
    if (req.method == "OPTIONS") {
        send_http(fd, make_response(204, ""));
    } else if (req.path == "/api/stream" && req.method == "GET") {
        handle_sse(fd, req);
    } else {
        send_http(fd, handle_request(req));
    }
    close(fd);
}

void seed_state() {
    std::lock_guard<std::mutex> lock(g_mu);
    if (!g_projects.count("codex-database")) g_projects["codex-database"] = Project{};
    auto sid = ensure_session_locked("codex-database", "session-default");
    if (g_sessions[sid].source.empty() || g_sessions[sid].source == "mkb") g_sessions[sid].source = "codex-relay";
    if (g_sessions[sid].title.empty() || g_sessions[sid].title == "MKB session-default") g_sessions[sid].title = "MKB Codex 默认会话";
    if (g_profile_project["home-codex"].empty()) g_profile_project["home-codex"] = "codex-database";
    if (g_profile_session["home-codex"].empty()) g_profile_session["home-codex"] = sid;
    Binding b;
    b.session_id = sid;
    auto bkey = binding_key(b.channel, b.chat_id);
    if (!g_bindings.count(bkey)) g_bindings[bkey] = b;
    if (!event_exists_locked("relay.ready", "", sid, "MKB Codex relay ready")) {
        append_event_locked("relay.ready", "", sid, "MKB Codex relay ready");
    } else {
        persist_state_locked();
    }
}

void on_signal(int) {
    g_running = false;
    if (g_server_fd >= 0) close(g_server_fd);
    g_events_cv.notify_all();
}

} // namespace

int main(int argc, char** argv) {
    std::signal(SIGINT, on_signal);
    std::signal(SIGTERM, on_signal);
    std::signal(SIGPIPE, SIG_IGN);
    std::string host = argc > 1 ? argv[1] : "127.0.0.1";
    int port = argc > 2 ? std::atoi(argv[2]) : 18992;

    g_state_path = env_or("MKB_CODEX_RELAY_STATE", "/var/lib/mkb-codex-relay/state.jsonl");
    {
        std::lock_guard<std::mutex> lock(g_mu);
        load_state_locked();
        g_state_loaded = true;
    }
    seed_state();

    int server = socket(AF_INET, SOCK_STREAM, 0);
    if (server < 0) {
        std::cerr << "socket failed\n";
        return 1;
    }
    g_server_fd = server;
    int yes = 1;
    setsockopt(server, SOL_SOCKET, SO_REUSEADDR, &yes, sizeof(yes));

    sockaddr_in addr{};
    addr.sin_family = AF_INET;
    addr.sin_port = htons(static_cast<uint16_t>(port));
    if (inet_pton(AF_INET, host.c_str(), &addr.sin_addr) != 1) {
        std::cerr << "invalid host: " << host << "\n";
        return 1;
    }
    if (bind(server, reinterpret_cast<sockaddr*>(&addr), sizeof(addr)) != 0) {
        std::cerr << "bind failed: " << std::strerror(errno) << "\n";
        return 1;
    }
    if (listen(server, 64) != 0) {
        std::cerr << "listen failed\n";
        return 1;
    }
    std::cerr << "mkb_codex_relay listening on " << host << ":" << port << "\n";

    while (g_running.load()) {
        sockaddr_in client{};
        socklen_t len = sizeof(client);
        int fd = accept(server, reinterpret_cast<sockaddr*>(&client), &len);
        if (fd < 0) {
            if (errno == EINTR) continue;
            break;
        }
        std::thread(handle_client, fd).detach();
    }
    close(server);
    g_server_fd = -1;
    return 0;
}
