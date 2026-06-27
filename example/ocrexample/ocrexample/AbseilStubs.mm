#import <TargetConditionals.h>

#if TARGET_OS_SIMULATOR && defined(__arm64__)

#import <string>

namespace MLKITx_absl {

enum LogSeverityAtLeast {
    kLogInfo = 0,
    kLogWarning = 1,
    kLogError = 2,
    kLogFatal = 3,
};

enum LogSeverityAtMost {
    kLogVerbose = -1,
    kLogInfoAtMost = 0,
    kLogWarningAtMost = 1,
    kLogErrorAtMost = 2,
    kLogAlways = 3,
};

struct string_view {
    const char* data_;
    size_t size_;
    string_view() : data_(""), size_(0) {}
    string_view(const char* s) : data_(s), size_(strlen(s)) {}
    string_view(const char* s, size_t n) : data_(s), size_(n) {}
    const char* data() const { return data_; }
    size_t size() const { return size_; }
};

namespace strings_internal {
    extern const char kBase64Chars[];
    extern const char kWebSafeBase64Chars[];
    const char kBase64Chars[] = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/";
    const char kWebSafeBase64Chars[] = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_";

    size_t Base64EscapeInternal(const unsigned char* src, size_t sz, char* dest, size_t dest_sz, const char* chars, bool do_padding) {
        return 0;
    }
    size_t CalculateBase64EscapedLenInternal(size_t len, bool do_padding) {
        return (len + 2) / 3 * 4;
    }
}

namespace log_internal {

class LogMessage {
public:
    enum { kNoLog = 0 };
    LogMessage(const char*, int, int) {}
    ~LogMessage() { Flush(); }
    void Flush() {}
    void LogBacktraceIfNeeded() {}
    std::string& stream() { static std::string s; return s; }
};

struct LogEntry {};

class LogSink {
public:
    virtual ~LogSink() = default;
    virtual void Send(const LogEntry&) {}
};

class StderrLogSink : public LogSink {
public:
    void Send(const LogEntry&) override {}
};

static int g_min_log_level = 0;

void RawSetMinLogLevel(LogSeverityAtLeast severity) {}
void RawEnableLogPrefix(bool enable) {}
bool ShouldLogBacktraceAt(string_view, int) { return false; }
void RawSetStderrThreshold(LogSeverityAtLeast) {}
void RawSetLogBufferingLevel(LogSeverityAtMost) {}
void SetLoggingGlobalsListener(void (*)()) {}

}

LogSeverityAtLeast MinLogLevel() { return kLogWarning; }
LogSeverityAtLeast StderrThreshold() { return kLogWarning; }
LogSeverityAtMost LogBufferingLevel() { return kLogAlways; }
void SetStderrThreshold(LogSeverityAtLeast) {}
bool ShouldPrependLogPrefix() { return false; }
void SetLogBacktraceLocation(string_view, int) {}
void ClearLogBacktraceLocation() {}

}

#endif
