// SPDX-License-Identifier: GPL-2.0-or-later
#pragma once
#include "quantum.h"

#define COMPANION_CHANNEL 0x51
#ifndef COMPANION_WIDTH
#    define COMPANION_WIDTH 240
#endif
#define COMPANION_LYRIC_HEIGHT 20
#define COMPANION_BITMAP_SIZE (COMPANION_WIDTH * COMPANION_LYRIC_HEIGHT / 8)

typedef struct {
    uint8_t cpu, memory, gpu, disk;
    uint8_t humidity, weather_code, weather_hour, weather_minute;
    uint8_t playing;
    uint16_t progress;
    int16_t temperature;
    uint32_t monitor_time, weather_time, lyric_time, screen_activity;
    uint16_t revision;
    uint8_t page_request;
    uint8_t bitmap[COMPANION_BITMAP_SIZE];
    uint8_t title[COMPANION_WIDTH * 12 / 8];
} companion_state_t;

extern companion_state_t companion;
bool companion_command(uint8_t *data, uint8_t length);
void companion_indicators(void);
bool companion_alive(uint32_t stamp, uint32_t lifetime);
