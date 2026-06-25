#include <algorithm>
#include <arpa/inet.h>
#include <cstdlib>
#include <cstring>
#include <filesystem>
#include <fstream>
#include <iostream>
#include <map>
#include <netdb.h>
#include <set>
#include <sstream>
#include <string>
#include <sys/socket.h>
#include <unistd.h>
#include <vector>

namespace fs = std::filesystem;

struct Url {
    std::string scheme = "http";
    std::string host = "127.0.0.1";
    int port = 80;
    std::string base_path;
};

struct HttpResponse {
    int status = 0;
    std::string body;
    std::string error;
};

struct IndexRow {
    std::string id;
    std::string title;
    std::string updated_at;
    std::string rollout_path;
};

struct HistoryRequest {
    std::string endpoint_id;
    std::string session_id;
};

struct TranscriptMessage {
    std::string role;
    std::string message;
    long line_no = 0;
};

std::string env_or(const char* name, const std::string& fallback = "") {
    const char* value = std::getenv(name);
    return value && *value ? value : fallback;
}

std::string home_expand(const std::string& path) {
    if (path.empty() || path[0] != '~') return path;
    return env_or("HOME", "") + path.substr(1);
}

Url parse_url(std::string raw) {
    Url result;
    auto scheme_pos = raw.find("://");
    if (scheme_pos != std::string::npos) {
        result.scheme = raw.substr(0, scheme_pos);
        raw = raw.substr(scheme_pos + 3);
    }
    auto path_pos = raw.find('/');
    std::string authority = path_pos == std::string::npos ? raw : raw.substr(0, path_pos);
    result.base_path = path_pos == std::string::npos ? "" : raw.substr(path_pos);
    auto colon = authority.rfind(':');
    if (colon != std::string::npos) {
        result.host = authority.substr(0, colon);
        result.port = std::atoi(authority.substr(colon + 1).c_str());
    } else {
        result.host = authority;
        result.port = result.scheme == "https" ? 443 : 80;
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
    req << "User-Agent: mkb-codex-session-index-sync/0.1\r\n";
    req << "Connection: close\r\n";
    if (method == "POST") {
        req << "Content-Type: application/json\r\n";
        req << "Content-Length: " << body.size() << "\r\n";
    }
    req << "\r\n" << body;

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
    std::istringstream hs(raw.substr(0, header_end));
    std::string version;
    hs >> version >> response.status;
    response.body = raw.substr(header_end + 4);
    return response;
}

std::string json_escape(const std::string& input) {
    std::ostringstream out;
    for (unsigned char c : input) {
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
                out << static_cast<char>(c);
            }
        }
    }
    return out.str();
}

std::string json_unescape_at(const std::string& input, size_t quote_pos, size_t* end_pos = nullptr) {
    std::string out;
    if (quote_pos == std::string::npos || quote_pos >= input.size() || input[quote_pos] != '"') return out;
    for (size_t i = quote_pos + 1; i < input.size(); ++i) {
        char c = input[i];
        if (c == '"') {
            if (end_pos) *end_pos = i + 1;
            return out;
        }
        if (c != '\\') {
            out.push_back(c);
            continue;
        }
        if (++i >= input.size()) break;
        char e = input[i];
        switch (e) {
        case '"': out.push_back('"'); break;
        case '\\': out.push_back('\\'); break;
        case '/': out.push_back('/'); break;
        case 'b': out.push_back('\b'); break;
        case 'f': out.push_back('\f'); break;
        case 'n': out.push_back('\n'); break;
        case 'r': out.push_back('\r'); break;
        case 't': out.push_back('\t'); break;
        case 'u':
            out += "\\u";
            for (int j = 0; j < 4 && i + 1 < input.size(); ++j) out.push_back(input[++i]);
            break;
        default:
            out.push_back(e);
        }
    }
    if (end_pos) *end_pos = input.size();
    return out;
}

std::string field_string(const std::string& line, const std::string& key) {
    std::string needle = "\"" + key + "\":";
    auto pos = line.find(needle);
    if (pos == std::string::npos) return "";
    pos = line.find('"', pos + needle.size());
    if (pos == std::string::npos) return "";
    return json_unescape_at(line, pos);
}

std::string trim(const std::string& input) {
    size_t start = 0;
    while (start < input.size() && std::isspace(static_cast<unsigned char>(input[start]))) ++start;
    size_t end = input.size();
    while (end > start && std::isspace(static_cast<unsigned char>(input[end - 1]))) --end;
    return input.substr(start, end - start);
}

bool starts_with(const std::string& value, const std::string& prefix) {
    return value.rfind(prefix, 0) == 0;
}

bool ignored_transcript_message(const std::string& message) {
    std::string text = trim(message);
    if (text.empty()) return true;
    if (text.find("codex-fleet-monitor.prompt") != std::string::npos) return true;
    if (text.find("/home/donovan/.codex-bridge/codex-fleet-monitor.prompt") != std::string::npos) return true;
    if (text == "VPS_PERSIST_MULTI_USER") return true;
    return false;
}

std::vector<std::string> text_fields(const std::string& line) {
    std::vector<std::string> texts;
    std::string needle = "\"text\":";
    size_t pos = 0;
    while ((pos = line.find(needle, pos)) != std::string::npos) {
        size_t quote = line.find('"', pos + needle.size());
        size_t end = std::string::npos;
        std::string text = json_unescape_at(line, quote, &end);
        if (!text.empty()) texts.push_back(text);
        pos = end == std::string::npos ? pos + needle.size() : end;
    }
    return texts;
}

bool visible_message_line(const std::string& line) {
    return line.find("\"type\":\"response_item\"") != std::string::npos &&
           line.find("\"type\":\"message\"") != std::string::npos;
}

bool event_user_message_line(const std::string& line) {
    return line.find("\"type\":\"event_msg\"") != std::string::npos &&
           line.find("\"type\":\"user_message\"") != std::string::npos;
}

bool event_agent_message_line(const std::string& line) {
    return line.find("\"type\":\"event_msg\"") != std::string::npos &&
           line.find("\"type\":\"agent_message\"") != std::string::npos;
}

bool visible_rollout_line(const std::string& line) {
    return visible_message_line(line) || event_user_message_line(line) || event_agent_message_line(line);
}

std::string message_role(const std::string& line) {
    if (event_user_message_line(line)) return "user";
    if (event_agent_message_line(line)) return "assistant";
    auto payload = line.find("\"payload\":");
    auto role_pos = line.find("\"role\":", payload == std::string::npos ? 0 : payload);
    if (role_pos == std::string::npos) return "";
    auto quote = line.find('"', role_pos + 7);
    return json_unescape_at(line, quote);
}

std::string message_phase(const std::string& line) {
    if (event_agent_message_line(line)) return field_string(line, "phase");
    auto payload = line.find("\"payload\":");
    auto phase_pos = line.find("\"phase\":", payload == std::string::npos ? 0 : payload);
    if (phase_pos == std::string::npos) return "";
    auto quote = line.find('"', phase_pos + 8);
    return json_unescape_at(line, quote);
}

std::string session_cwd_from_meta(const std::string& line) {
    if (line.find("\"type\":\"session_meta\"") == std::string::npos) return "";
    return field_string(line, "cwd");
}

std::vector<IndexRow> read_index(const std::string& path) {
    std::ifstream in(path);
    std::vector<IndexRow> rows;
    std::string line;
    while (std::getline(in, line)) {
        IndexRow row;
        row.id = field_string(line, "id");
        row.title = field_string(line, "thread_name");
        row.updated_at = field_string(line, "updated_at");
        if (!row.id.empty()) rows.push_back(row);
    }
    std::sort(rows.begin(), rows.end(), [](const IndexRow& a, const IndexRow& b) {
        return a.updated_at > b.updated_at;
    });
    return rows;
}

std::string find_rollout_path(const std::string& sessions_root, const IndexRow& row) {
    std::vector<fs::path> roots;
    if (row.updated_at.size() >= 10) {
        roots.push_back(fs::path(sessions_root) / row.updated_at.substr(0, 4) / row.updated_at.substr(5, 2) / row.updated_at.substr(8, 2));
    }
    roots.push_back(fs::path(sessions_root));
    for (const auto& root : roots) {
        std::error_code ec;
        if (!fs::exists(root, ec)) continue;
        for (fs::recursive_directory_iterator it(root, fs::directory_options::skip_permission_denied, ec), end; it != end && !ec; it.increment(ec)) {
            if (!it->is_regular_file(ec)) continue;
            std::string name = it->path().filename().string();
            if (name.find(row.id) != std::string::npos && name.find(".jsonl") != std::string::npos) {
                return it->path().string();
            }
        }
    }
    return "";
}

bool post_transcript(const Url& broker,
                     const IndexRow& row,
                     const std::string& endpoint_id,
                     const std::string& project_alias,
                     const std::string& source,
                     const std::string& cwd,
                     const std::string& role,
                     const std::string& message,
                     long line_no) {
    std::ostringstream body;
    body << "{\"session_id\":\"" << json_escape(row.id)
         << "\",\"endpoint_id\":\"" << json_escape(endpoint_id)
         << "\",\"title\":\"" << json_escape(row.title.empty() ? row.id : row.title)
         << "\",\"cwd\":\"" << json_escape(cwd)
         << "\",\"source\":\"" << json_escape(source)
         << "\",\"role\":\"" << json_escape(role)
         << "\",\"message\":\"" << json_escape(message)
         << "\",\"ordinal\":\"line-" << line_no
         << "\",\"updated_at\":\"" << json_escape(row.updated_at)
         << "\",\"bind_current\":\"false"
         << "\",\"profile\":\"home-codex\",\"channel\":\"mkb\",\"chat_id\":\"mkb-ios\",\"project_alias\":\"" << json_escape(project_alias) << "\"}";
    auto res = http_request(broker, "POST", "/api/transcript/message", body.str());
    if (res.status >= 200 && res.status < 300) return true;
    std::cerr << "post failed session=" << row.id << " line=" << line_no << " role=" << role
              << " status=" << res.status << " error=" << res.error << " body=" << res.body << "\n";
    return false;
}

bool post_transcripts_batch(const Url& broker,
                            const IndexRow& row,
                            const std::string& endpoint_id,
                            const std::string& project_alias,
                            const std::string& source,
                            const std::string& cwd,
                            const std::vector<TranscriptMessage>& messages) {
    if (messages.empty()) return true;
    std::ostringstream body;
    body << "{\"session_id\":\"" << json_escape(row.id)
         << "\",\"endpoint_id\":\"" << json_escape(endpoint_id)
         << "\",\"title\":\"" << json_escape(row.title.empty() ? row.id : row.title)
         << "\",\"cwd\":\"" << json_escape(cwd)
         << "\",\"source\":\"" << json_escape(source)
         << "\",\"updated_at\":\"" << json_escape(row.updated_at)
         << "\",\"bind_current\":\"false"
         << "\",\"profile\":\"home-codex\",\"channel\":\"mkb\",\"chat_id\":\"mkb-ios\",\"project_alias\":\""
         << json_escape(project_alias) << "\",\"messages\":[";
    for (size_t i = 0; i < messages.size(); ++i) {
        const auto& item = messages[i];
        if (i) body << ",";
        body << "{\"role\":\"" << json_escape(item.role)
             << "\",\"message\":\"" << json_escape(item.message)
             << "\",\"ordinal\":\"line-" << item.line_no << "\"}";
    }
    body << "]}";

    auto res = http_request(broker, "POST", "/api/transcript/messages", body.str());
    if (res.status >= 200 && res.status < 300) return true;

    std::cerr << "batch post failed session=" << row.id << " messages=" << messages.size()
              << " status=" << res.status << " error=" << res.error
              << " body=" << res.body << "; falling back to per-message posts\n";
    for (const auto& item : messages) {
        if (!post_transcript(broker, row, endpoint_id, project_alias, source, cwd, item.role, item.message, item.line_no)) {
            return false;
        }
    }
    return true;
}

bool post_session(const Url& broker,
                  const IndexRow& row,
                  const std::string& endpoint_id,
                  const std::string& project_alias,
                  const std::string& source) {
    std::ostringstream body;
    body << "{\"session_id\":\"" << json_escape(row.id)
         << "\",\"endpoint_id\":\"" << json_escape(endpoint_id)
         << "\",\"title\":\"" << json_escape(row.title.empty() ? row.id : row.title)
         << "\",\"source\":\"" << json_escape(source)
         << "\",\"updated_at\":\"" << json_escape(row.updated_at)
         << "\",\"project_alias\":\"" << json_escape(project_alias) << "\"}";
    auto res = http_request(broker, "POST", "/api/transcript/session", body.str());
    if (res.status >= 200 && res.status < 300) return true;
    std::cerr << "post session failed session=" << row.id << " status=" << res.status
              << " error=" << res.error << " body=" << res.body << "\n";
    return false;
}

std::vector<HistoryRequest> fetch_history_requests(const Url& broker,
                                                   const std::string& endpoint_id,
                                                   int limit) {
    std::vector<HistoryRequest> requests;
    std::ostringstream path;
    path << "/api/history/requests?endpoint_id=" << endpoint_id
         << "&limit=" << limit;
    auto res = http_request(broker, "GET", path.str());
    if (res.status < 200 || res.status >= 300) {
        std::cerr << "fetch history requests failed status=" << res.status
                  << " error=" << res.error << " body=" << res.body << "\n";
        return requests;
    }
    size_t pos = 0;
    while ((pos = res.body.find("\"session_id\"", pos)) != std::string::npos) {
        size_t object_start = res.body.rfind('{', pos);
        size_t object_end = res.body.find('}', pos);
        if (object_start == std::string::npos || object_end == std::string::npos) break;
        std::string object = res.body.substr(object_start, object_end - object_start + 1);
        HistoryRequest request;
        request.endpoint_id = field_string(object, "endpoint_id");
        request.session_id = field_string(object, "session_id");
        if (!request.session_id.empty()) requests.push_back(request);
        pos = object_end + 1;
    }
    return requests;
}

bool post_history_complete(const Url& broker,
                           const std::string& endpoint_id,
                           const std::string& session_id) {
    std::ostringstream body;
    body << "{\"endpoint_id\":\"" << json_escape(endpoint_id)
         << "\",\"session_id\":\"" << json_escape(session_id) << "\"}";
    auto res = http_request(broker, "POST", "/api/history/complete", body.str());
    if (res.status >= 200 && res.status < 300) return true;
    std::cerr << "history complete failed session=" << session_id << " status=" << res.status
              << " error=" << res.error << " body=" << res.body << "\n";
    return false;
}

bool sync_rollout(const Url& broker,
                  const IndexRow& row,
                  const std::string& endpoint_id,
                  const std::string& project_alias,
                  const std::string& source) {
    std::ifstream in(row.rollout_path);
    if (!in) {
        std::cerr << "missing rollout for " << row.id << "\n";
        return false;
    }
    std::string line;
    std::string cwd;
    std::string last_role;
    std::string last_message;
    std::vector<TranscriptMessage> messages;
    long line_no = 0;
    while (std::getline(in, line)) {
        ++line_no;
        if (cwd.empty()) {
            cwd = session_cwd_from_meta(line);
        }
        if (!visible_rollout_line(line)) continue;
        std::string role = message_role(line);
        if (role != "user" && role != "assistant") continue;
        if (role == "assistant" && message_phase(line) != "final_answer") continue;
        std::string message;
        if (event_user_message_line(line) || event_agent_message_line(line)) {
            message = trim(field_string(line, "message"));
        } else {
            auto texts = text_fields(line);
            std::ostringstream combined;
            for (size_t i = 0; i < texts.size(); ++i) {
                if (i) combined << "\n";
                combined << texts[i];
            }
            message = trim(combined.str());
        }
        if (starts_with(message, "# AGENTS.md instructions") ||
            starts_with(message, "<environment_context>") ||
            ignored_transcript_message(message)) {
            continue;
        }
        if (role == last_role && message == last_message) continue;
        TranscriptMessage item;
        item.role = role;
        item.message = message;
        item.line_no = line_no;
        messages.push_back(item);
        last_role = role;
        last_message = message;
    }
    if (!post_transcripts_batch(broker, row, endpoint_id, project_alias, source, cwd, messages)) return false;
    std::cerr << "synced session=" << row.id << " title=" << row.title << " messages=" << messages.size() << "\n";
    return true;
}

int main(int argc, char** argv) {
    Url broker = parse_url(argc > 1 ? argv[1] : env_or("MKB_CODEX_TRANSCRIPT_BROKER", "http://124.174.101.22:886"));
    std::string index_path = home_expand(argc > 2 ? argv[2] : env_or("MKB_CODEX_SESSION_INDEX", "~/.codex/session_index.jsonl"));
    bool requests_only = env_or("MKB_CODEX_HISTORY_REQUESTS_ONLY") == "1";
    for (int i = 3; i < argc; ++i) {
        std::string arg = argv[i];
        if (arg == "--requests-only") requests_only = true;
    }
    std::string sessions_root = home_expand(env_or("MKB_CODEX_SESSIONS_ROOT", "~/.codex/sessions"));
    std::string endpoint_id = env_or("MKB_CODEX_TRANSCRIPT_ENDPOINT", "quectel-lnx");
    std::string project_alias = env_or("MKB_CODEX_TRANSCRIPT_PROJECT", "codex-database");
    std::string source = env_or("MKB_CODEX_TRANSCRIPT_SOURCE", "codex-vscode");
    int limit = std::atoi(env_or("MKB_CODEX_HISTORY_LIMIT", "500").c_str());
    if (limit <= 0) limit = 500;
    int request_limit = std::atoi(env_or("MKB_CODEX_HISTORY_REQUEST_LIMIT", "20").c_str());
    if (request_limit <= 0) request_limit = 20;

    auto rows = read_index(index_path);
    std::map<std::string, IndexRow> by_id;
    for (const auto& row : rows) by_id[row.id] = row;
    int indexed = 0;
    int synced = 0;

    if (!requests_only) {
        int scanned = 0;
        for (auto& row : rows) {
            if (scanned++ >= limit) break;
            if (post_session(broker, row, endpoint_id, project_alias, source)) ++indexed;
        }
        std::cerr << "session-index sync done indexed=" << indexed
                  << " requests=0 synced=0\n";
        return 0;
    }

    auto requests = fetch_history_requests(broker, endpoint_id, request_limit);
    for (const auto& request : requests) {
        auto it = by_id.find(request.session_id);
        if (it == by_id.end()) {
            std::cerr << "requested session not found in index session=" << request.session_id << "\n";
            continue;
        }
        auto row = it->second;
        row.rollout_path = find_rollout_path(sessions_root, row);
        if (row.rollout_path.empty()) {
            std::cerr << "rollout not found session=" << row.id << " title=" << row.title << "\n";
            continue;
        }
        std::string effective_endpoint = request.endpoint_id.empty() ? endpoint_id : request.endpoint_id;
        if (sync_rollout(broker, row, effective_endpoint, project_alias, source)) {
            ++synced;
            post_history_complete(broker, effective_endpoint, row.id);
        }
    }
    std::cerr << "session-index sync done indexed=" << indexed
              << " requests=" << requests.size() << " synced=" << synced << "\n";
    return 0;
}
