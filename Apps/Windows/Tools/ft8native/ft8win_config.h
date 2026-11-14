// Force-included (/FI) into every ft8_lib translation unit. Silences
// common/monitor.c, which hardcodes LOG_LEVEL and would otherwise print
// "Block size = ..." to stderr on every monitor_init (same reason as the
// Swift package's -DLOG_PRINTF(...)= flag). The vendored source is not edited.
#define LOG_PRINTF(...)
#define _CRT_SECURE_NO_WARNINGS
