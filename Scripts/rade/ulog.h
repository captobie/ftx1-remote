// Stand-in for freedv-backend's util/logging/ulog.h when Scripts/build-rade.sh
// compiles rade_text.cpp/ldpc_*.cpp: the app logs through os.Logger, and
// rade_text logs every end-of-over at info level, so all of it is dropped.
#pragma once
#define log_trace(...) ((void)0)
#define log_debug(...) ((void)0)
#define log_info(...) ((void)0)
#define log_warn(...) ((void)0)
#define log_error(...) ((void)0)
#define log_fatal(...) ((void)0)
