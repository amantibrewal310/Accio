#include "shim.h"
OptInt call_from_string(void *fn, uint64_t w0, uint64_t w1) { return ((OptInt (*)(uint64_t, uint64_t))fn)(w0, w1); }
