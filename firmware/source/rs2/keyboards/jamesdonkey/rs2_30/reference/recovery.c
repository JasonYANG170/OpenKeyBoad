// SPDX-License-Identifier: GPL-2.0-or-later
#include "quantum.h"
#include "bootloader.h"

void keyboard_pre_init_user(void) {
    // Probe RS2 Esc directly, before the AK650 matrix and peripherals start.
    gpio_set_pin_input_low(B14);
    gpio_write_pin_high(A4);
    gpio_set_pin_output(A4);
    wait_ms(5);
    const bool held = gpio_read_pin(B14);
    gpio_write_pin_low(A4);
    gpio_set_pin_input(A4);
    if (held) bootloader_jump();
}
