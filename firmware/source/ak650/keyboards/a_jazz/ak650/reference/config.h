// SPDX-License-Identifier: GPL-2.0-or-later
#pragma once

#include "../../ak820pro/config.h"

#undef LED_WINLOCK_PIN
#define LED_WINLOCK_PIN B18
#define AK820PRO_DISCRETE_WIN_LED 1
#define AK820PRO_DISCRETE_CHARGE_LED 0
#define BT_PAIR_HOLD_MS 3000
#define AK820PRO_OS_SWITCH_INVERTED 1
#define AK820PRO_LCD_ROTATION QP_ROTATION_180
// GC9107's 128x128 active area in this orientation starts at column 2, row 1.
#define LCD_OFFSET_X 2
#define LCD_OFFSET_Y 1

#ifdef AK650_MATRIX_TEST
#    define DEVICE_VER 0x0031
#endif
