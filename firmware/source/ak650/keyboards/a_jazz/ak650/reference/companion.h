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
    uint32_t download, upload, network_time;
    uint8_t network_ready, timer_state, timer_cycles, timer_rest;
    uint32_t timer_remaining, timer_duration, timer_time;
    int16_t minimum, maximum;
    uint16_t aqi, pm25;
    uint8_t rain, uv;
    uint16_t network_revision, timer_revision;
    uint8_t humidity, weather_code, weather_hour, weather_minute;
    uint8_t playing;
    uint16_t progress;
    int16_t temperature;
    uint32_t monitor_time, weather_time, lyric_time, screen_activity;
    uint16_t revision;
    uint16_t monitor_revision, weather_revision, title_revision, lyric_revision, playback_revision;
    uint8_t page_request;
    uint8_t bitmap[COMPANION_BITMAP_SIZE];
    uint8_t title[COMPANION_WIDTH * 12 / 8];
} companion_state_t;

extern companion_state_t companion;
bool companion_command(uint8_t *data, uint8_t length);
void companion_indicators(void);
bool companion_alive(uint32_t stamp, uint32_t lifetime);

// Bits 0/1/2 represent the title/content/status display bands.
typedef struct {
    uint16_t monitor, weather, title, lyric, playback, network, timer;
    uint32_t remaining;
    uint8_t fresh;
} companion_view_t;
uint8_t companion_changed(companion_view_t *view, uint8_t remote_page);

uint32_t companion_timer_remaining(void);
