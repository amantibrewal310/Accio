#include <stdint.h>
#include <stdbool.h>
typedef struct { int64_t value; bool isNil; } OptInt;
OptInt call_from_string(void *fn, uint64_t w0, uint64_t w1);
