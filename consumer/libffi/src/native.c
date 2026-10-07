#include <stdint.h>

/* Separate C translation unit: both calls must cross the libffi C ABI. */
int32_t zlua_ffi_signed(int32_t left, int32_t right) {
    return left * 3 + right;
}

double zlua_ffi_mixed(int32_t left, double scale, int32_t right, double offset) {
    return left * scale + right * offset;
}

int64_t zlua_ffi_signed64(int64_t left, int64_t right) {
    return left * 2 + right;
}

typedef double (*zlua_mixed_fn)(int32_t, double, int32_t, double);
zlua_mixed_fn zlua_ffi_get_mixed(void) {
    return zlua_ffi_mixed;
}
