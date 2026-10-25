#ifndef __MATH_H
#define __MATH_H

// 数学の関数（libc/math.c）。long double は double と同じ

#define HUGE_VAL (1.0 / 0.0)
#define HUGE_VALF (1.0f / 0.0f)
#define HUGE_VALL (1.0L / 0.0L)
#define INFINITY (1.0f / 0.0f)
#define NAN (0.0f / 0.0f)

#define M_E 2.7182818284590452354
#define M_LOG2E 1.4426950408889634074
#define M_LOG10E 0.43429448190325182765
#define M_LN2 0.69314718055994530942
#define M_LN10 2.30258509299404568402
#define M_PI 3.14159265358979323846
#define M_PI_2 1.57079632679489661923
#define M_PI_4 0.78539816339744830962
#define M_1_PI 0.31830988618379067154
#define M_2_PI 0.63661977236758134308
#define M_2_SQRTPI 1.12837916709551257390
#define M_SQRT2 1.41421356237309504880
#define M_SQRT1_2 0.70710678118654752440

#define FP_NAN 0
#define FP_INFINITE 1
#define FP_ZERO 2
#define FP_SUBNORMAL 3
#define FP_NORMAL 4

int __mycpu_signbit(double x);
int __mycpu_isinf(double x);
int __mycpu_isnan(double x);
int __mycpu_isfinite(double x);

#define isnan(x) __mycpu_isnan(x)
#define isinf(x) __mycpu_isinf(x)
#define isfinite(x) __mycpu_isfinite(x)
#define signbit(x) __mycpu_signbit(x)
#define isnormal(x) (fpclassify(x) == FP_NORMAL)
#define fpclassify(x) __mycpu_fpclassify(x)
static inline int __mycpu_fpclassify(double x) {
  if (x != x) return FP_NAN;
  if (__mycpu_isinf(x)) return FP_INFINITE;
  if (x == 0) return FP_ZERO;
  return (x < 0 ? -x : x) < 2.2250738585072014e-308 ? FP_SUBNORMAL : FP_NORMAL;
}
#define isgreater(x, y) ((x) > (y))
#define isgreaterequal(x, y) ((x) >= (y))
#define isless(x, y) ((x) < (y))
#define islessequal(x, y) ((x) <= (y))
#define isunordered(x, y) ((x) != (x) || (y) != (y))

double fabs(double x);
double copysign(double x, double y);
double trunc(double x);
double floor(double x);
double ceil(double x);
double round(double x);
double nearbyint(double x);
double rint(double x);
long lround(double x);
long lrint(double x);
double modf(double x, double *ip);
double ldexp(double x, int n);
double scalbn(double x, int n);
double frexp(double x, int *ep);
double sqrt(double x);
double fmod(double x, double y);
double remainder(double x, double y);
double exp(double x);
double exp2(double x);
double expm1(double x);
double log(double x);
double log10(double x);
double log2(double x);
double log1p(double x);
double pow(double x, double y);
double cbrt(double x);
double hypot(double x, double y);
double sin(double x);
double cos(double x);
double tan(double x);
double asin(double x);
double acos(double x);
double atan(double x);
double atan2(double y, double x);
double sinh(double x);
double cosh(double x);
double tanh(double x);
double asinh(double x);
double acosh(double x);
double atanh(double x);
double fmax(double x, double y);
double fmin(double x, double y);
double fdim(double x, double y);
double fma(double x, double y, double z);

float fabsf(float x);
float sqrtf(float x);
float floorf(float x);
float ceilf(float x);
float truncf(float x);
float roundf(float x);
float fmodf(float x, float y);
float expf(float x);
float logf(float x);
float log10f(float x);
float log2f(float x);
float powf(float x, float y);
float sinf(float x);
float cosf(float x);
float tanf(float x);
float atanf(float x);
float atan2f(float y, float x);
float asinf(float x);
float acosf(float x);
float sinhf(float x);
float coshf(float x);
float tanhf(float x);
float hypotf(float x, float y);
float cbrtf(float x);
float ldexpf(float x, int n);
float frexpf(float x, int *e);
float copysignf(float x, float y);
float fmaxf(float x, float y);
float fminf(float x, float y);

// long double の版は double と同じ
#define fabsl fabs
#define sqrtl sqrt
#define floorl floor
#define ceill ceil
#define truncl trunc
#define roundl round
#define fmodl fmod
#define expl exp
#define logl log
#define log10l log10
#define powl pow
#define sinl sin
#define cosl cos
#define tanl tan
#define atanl atan
#define atan2l atan2
#define ldexpl ldexp
#define frexpl frexp
#define modfl modf
#define copysignl copysign

#endif
