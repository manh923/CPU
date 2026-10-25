// 時間：MyCPU には時計がないので、2026-01-01 00:00:00 から起動後の秒数だけ進んだことにする。
// clock() はタイマー（1µs ごとに増える。入出力の 0x10010）
#include <time.h>
#include <string.h>
#include <stdio.h>

#define TIMER_COUNT ((volatile unsigned *)0x00010010)
#define BOOT_TIME 1767225600L            // 2026-01-01 00:00:00（UTC）

clock_t clock(void) {
  return *TIMER_COUNT & 0x7fffffff;
}

time_t time(time_t *t) {
  time_t v = BOOT_TIME + *TIMER_COUNT / 1000000;
  if (t)
    *t = v;
  return v;
}

static int leap(int y) {
  return (y % 4 == 0 && y % 100 != 0) || y % 400 == 0;
}

struct tm *gmtime(const time_t *t) {
  static struct tm tm;
  static int mdays[] = {31, 28, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31};
  unsigned long v = *t;
  tm.tm_sec = v % 60;
  v /= 60;
  tm.tm_min = v % 60;
  v /= 60;
  tm.tm_hour = v % 24;
  v /= 24;                              // 1970-01-01 からの日数
  tm.tm_wday = (v + 4) % 7;             // 1970-01-01 は木曜
  int y = 1970;
  while (v >= (unsigned long)(leap(y) ? 366 : 365)) {
    v -= leap(y) ? 366 : 365;
    y++;
  }
  tm.tm_year = y - 1900;
  tm.tm_yday = v;
  int m = 0;
  for (;; m++) {
    int d = mdays[m] + (m == 1 && leap(y));
    if (v < (unsigned long)d)
      break;
    v -= d;
  }
  tm.tm_mon = m;
  tm.tm_mday = v + 1;
  tm.tm_isdst = 0;
  return &tm;
}

struct tm *localtime(const time_t *t) {
  return gmtime(t);
}

size_t strftime(char *buf, size_t n, const char *fmt, const struct tm *tm) {
  static char *mon[] = {"Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec"};
  static char *wday[] = {"Sun", "Mon", "Tue", "Wed", "Thu", "Fri", "Sat"};
  size_t len = 0;
  char tmp[32];
  for (; *fmt; fmt++) {
    char *s = tmp;
    if (*fmt != '%') {
      tmp[0] = *fmt;
      tmp[1] = 0;
    } else {
      switch (*++fmt) {
      case 'Y': snprintf(tmp, sizeof(tmp), "%d", tm->tm_year + 1900); break;
      case 'm': snprintf(tmp, sizeof(tmp), "%02d", tm->tm_mon + 1); break;
      case 'd': snprintf(tmp, sizeof(tmp), "%02d", tm->tm_mday); break;
      case 'e': snprintf(tmp, sizeof(tmp), "%2d", tm->tm_mday); break;
      case 'H': snprintf(tmp, sizeof(tmp), "%02d", tm->tm_hour); break;
      case 'M': snprintf(tmp, sizeof(tmp), "%02d", tm->tm_min); break;
      case 'S': snprintf(tmp, sizeof(tmp), "%02d", tm->tm_sec); break;
      case 'b': s = mon[tm->tm_mon]; break;
      case 'a': s = wday[tm->tm_wday]; break;
      case '%': s = "%"; break;
      default: tmp[0] = 0;
      }
    }
    for (; *s; s++) {
      if (len + 1 >= n)
        return 0;
      buf[len++] = *s;
    }
  }
  if (n)
    buf[len] = 0;
  return len;
}

// "Thu Jan  1 00:00:00 2026\n" の形
char *asctime(const struct tm *tm) {
  static char buf[32];
  static const char *wd = "SunMonTueWedThuFriSat", *mn = "JanFebMarAprMayJunJulAugSepOctNovDec";
  snprintf(buf, sizeof(buf), "%.3s %.3s %2d %02d:%02d:%02d %d\n", wd + tm->tm_wday * 3, mn + tm->tm_mon * 3,
           tm->tm_mday, tm->tm_hour, tm->tm_min, tm->tm_sec, tm->tm_year + 1900);
  return buf;
}

char *ctime(const time_t *t) { return asctime(localtime(t)); }

char *ctime_r(const time_t *t, char *buf) { return strcpy(buf, ctime(t)); }
