#ifndef __TIME_H
#define __TIME_H

#include <stddef.h>

// MyCPU には時計がないので、time() は 2026-01-01 00:00:00 に起動からの秒数を足したもの。clock() はタイマー（µs）
typedef long time_t;
typedef long clock_t;
#define CLOCKS_PER_SEC 1000000

struct tm {
  int tm_sec, tm_min, tm_hour, tm_mday, tm_mon, tm_year, tm_wday, tm_yday, tm_isdst;
};

time_t time(time_t *t);
clock_t clock(void);
struct tm *localtime(const time_t *t);
struct tm *gmtime(const time_t *t);
size_t strftime(char *buf, size_t n, const char *fmt, const struct tm *tm);

#endif
