// SPDX-License-Identifier: GPL-2.0-or-later
#include <string.h>

#include "gpio.h"
#include "matrix.h"
#include "timer.h"
#include "wait.h"
#include "rs2_30.h"

static const pin_t row_pins[MATRIX_ROWS] = MATRIX_ROW_PINS;
static const pin_t col_pins[MATRIX_COLS] = MATRIX_COL_PINS;
#ifdef RGB_MATRIX_ENABLE
static matrix_row_t pulse_sample[MATRIX_ROWS];
static matrix_row_t pulse_complete[MATRIX_ROWS];
static uint8_t pulse_col;
static bool pulse_ready;
#endif

void matrix_init_custom(void) {
    for (uint8_t row = 0; row < MATRIX_ROWS; row++) {
        gpio_set_pin_input_low(row_pins[row]);
    }
    for (uint8_t col = 0; col < MATRIX_COLS; col++) {
        gpio_write_pin_low(col_pins[col]);
        gpio_set_pin_output(col_pins[col]);
    }
}

#ifdef RGB_MATRIX_ENABLE
void rs2_matrix_scan_pulse(void) {
    // Called with RGB blanked and its column PWM outputs disconnected.
    gpio_write_pin_high(col_pins[pulse_col]);
    wait_cpuclock((CPU_CLOCK / 1000000) * 6);
    for (uint8_t row = 0; row < MATRIX_ROWS; row++) {
        if (gpio_read_pin(row_pins[row])) pulse_sample[row] |= (matrix_row_t)1 << pulse_col;
    }
    gpio_write_pin_low(col_pins[pulse_col]);
    if (++pulse_col == MATRIX_COLS) {
        memcpy(pulse_complete, pulse_sample, sizeof(pulse_sample));
        memset(pulse_sample, 0, sizeof(pulse_sample));
        pulse_col = 0;
        pulse_ready = true;
    }
}
#endif

bool matrix_scan_custom(matrix_row_t current_matrix[]) {
#ifdef RGB_MATRIX_ENABLE
    if (rs2_rgb_is_running()) {
        chSysLock();
        bool changed = pulse_ready && memcmp(current_matrix, pulse_complete, sizeof(pulse_complete)) != 0;
        if (changed) memcpy(current_matrix, pulse_complete, sizeof(pulse_complete));
        pulse_ready = false;
        chSysUnlock();
        return changed;
    }
#endif

    static uint32_t last_scan;
    static bool scanned;
    const uint32_t now = timer_read32();
    if (scanned && last_scan == now) return false;
    last_scan = now;
    scanned = true;

    matrix_row_t sample[MATRIX_ROWS] = {0};

    for (uint8_t col = 0; col < MATRIX_COLS; col++) {
        // The stock scan drives one column high and reads active-high rows.
        gpio_write_pin_high(col_pins[col]);
        wait_us(10);
        for (uint8_t row = 0; row < MATRIX_ROWS; row++) {
            if (gpio_read_pin(row_pins[row])) {
                sample[row] |= (matrix_row_t)1 << col;
            }
        }
        gpio_write_pin_low(col_pins[col]);
    }

    const bool changed = memcmp(current_matrix, sample, sizeof(sample)) != 0;
    memcpy(current_matrix, sample, sizeof(sample));
    return changed;
}
