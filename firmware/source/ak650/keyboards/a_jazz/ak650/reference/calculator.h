// SPDX-License-Identifier: GPL-2.0-or-later
#pragma once

#include <stdbool.h>
#include <stdint.h>

typedef struct {
    char expression[40];
    char result[16];
    uint8_t length;
    bool evaluated;
    bool error;
} rs2_calculator_t;

void rs2_calculator_key(rs2_calculator_t *calc, char key);
