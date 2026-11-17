// SPDX-License-Identifier: GPL-2.0-or-later
#include "quantum.h"
#include "raw_hid.h"

#ifdef VIA_ENABLE
enum test_state {
    TEST_IDLE,
    TEST_WAIT_RELEASE,
    TEST_ARMED,
    TEST_CAPTURED,
    TEST_MULTIPLE,
};

static enum test_state state;
static uint32_t armed_at;
static uint8_t captured_row;
static uint8_t captured_col;

void matrix_scan_kb(void) {
    if (state == TEST_ARMED || state == TEST_WAIT_RELEASE) {
        if (timer_elapsed32(armed_at) >= 30000) {
            state = TEST_IDLE;
        } else {
            bool pressed = false;
            bool multiple = false;
            for (uint8_t row = 0; row < MATRIX_ROWS; ++row) {
                matrix_row_t bits = matrix_get_row(row);
                if (!bits) {
                    continue;
                }
                if (pressed || (bits & (bits - 1))) {
                    multiple = true;
                    break;
                }
                pressed = true;
                captured_row = row;
                for (captured_col = 0; (bits >> captured_col) != 1; ++captured_col) {
                }
            }
            if (state == TEST_WAIT_RELEASE && !pressed && !multiple) {
                state = TEST_ARMED;
            } else if (state == TEST_ARMED && (pressed || multiple)) {
                state = multiple ? TEST_MULTIPLE : TEST_CAPTURED;
            }
        }
    }
    matrix_scan_user();
}

bool via_command_kb(uint8_t *data, uint8_t length) {
    if (length != 32 || data[0] != 0xE1 || data[1] != 0x65 || data[2] != 0xA7) {
        return false;
    }
    switch (data[3]) {
        case 0: // Read one result. Normal key processing is untouched.
            data[4] = state;
            if (state == TEST_CAPTURED) {
                data[5] = captured_row;
                data[6] = captured_col;
            }
            if (state == TEST_CAPTURED || state == TEST_MULTIPLE) {
                state = TEST_IDLE;
            }
            break;
        case 1:
            armed_at = timer_read32();
            state = TEST_WAIT_RELEASE;
            break;
        case 2:
            state = TEST_IDLE;
            break;
        default:
            return false;
    }
    raw_hid_send(data, length);
    return true;
}
#endif
