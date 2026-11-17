// SPDX-License-Identifier: GPL-2.0-or-later
#include "companion.h"
#include "rtc/rtc.h"
#include "raw_hid.h"


companion_state_t companion = {.cpu = 255, .memory = 255, .gpu = 255, .disk = 255, .page_request = 255};
static rgb_t palette[RGB_MATRIX_LED_COUNT];
static uint8_t light_mode, intensity = 255;
static uint32_t light_heartbeat;

bool companion_alive(uint32_t stamp, uint32_t lifetime) {
    return stamp && timer_elapsed32(stamp) < lifetime;
}

static bool valid_time(const rtc_time_t *t) {
    static const uint8_t days[] = {31, 28, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31};
    if (t->year < 2000 || t->year > 2099 || t->month < 1 || t->month > 12) return false;
    uint8_t max = days[t->month - 1] + (t->month == 2 && t->year % 4 == 0);
    return t->day >= 1 && t->day <= max && t->hours < 24 && t->minutes < 60 && t->seconds < 60 && t->weekday < 7;
}

bool companion_command(uint8_t *data, uint8_t length) {
    if (length != 32 || data[1] != COMPANION_CHANNEL || (data[0] != 7 && data[0] != 8)) return false;
    uint8_t op = data[2];
    uint8_t *p = data + 3;
    if (data[0] == 8 && op == 0) {
        p[0] = 1; p[1] = 0x7f; p[2] = COMPANION_WIDTH; p[3] = 20;
        p[4] = RGB_MATRIX_LED_COUNT; p[5] = light_mode; p[6] = 2;
        return true;
    }
    if (data[0] == 8 && op == 10) {
        p[0] = (uint16_t)companion.temperature >> 8; p[1] = companion.temperature & 255;
        p[2] = companion.humidity; p[3] = companion.weather_code;
        p[4] = companion_alive(companion.weather_time, 3600000);
        p[5] = companion.weather_hour; p[6] = companion.weather_minute;
        return true;
    }
    if (data[0] != 7) { data[0] = 0xff; return true; }
    switch (op) {
        case 1: {
            uint8_t start = p[0], count = p[1];
            if (!count || count > 8 || start + count > RGB_MATRIX_LED_COUNT) break;
            for (uint8_t i = 0; i < count; ++i) {
                palette[start + i] = (rgb_t){p[2 + i * 3], p[3 + i * 3], p[4 + i * 3]};
            }
            return true;
        }
        case 2:
            if (p[0] > 2) break;
            light_mode = p[0]; intensity = p[1];
            light_heartbeat = timer_read32();
            return true;
        case 3:
            for (uint8_t i = 0; i < 4; ++i) if (p[i] > 100 && p[i] != 255) { data[0] = 0xff; return true; }
            companion.cpu = p[0]; companion.memory = p[1]; companion.gpu = p[2]; companion.disk = p[3];
            companion.monitor_time = companion.screen_activity = timer_read32();
            ++companion.revision;
            return true;
        case 4: {
            int16_t temperature = (int16_t)((p[0] << 8) | p[1]);
            if (temperature < -1000 || temperature > 800 || p[2] > 100 || p[3] > 99 || p[4] > 23 || p[5] > 59) break;
            companion.temperature = temperature; companion.humidity = p[2]; companion.weather_code = p[3];
            companion.weather_hour = p[4]; companion.weather_minute = p[5];
            companion.weather_time = companion.screen_activity = timer_read32();
            ++companion.revision;
            return true;
        }
        case 5:
        case 11: {
            uint16_t offset = (p[0] << 8) | p[1];
            uint8_t count = p[2];
            if (!count || count > 26 || offset + count > (op == 5 ? sizeof(companion.bitmap) : sizeof(companion.title))) break;
            memcpy((op == 5 ? companion.bitmap : companion.title) + offset, p + 3, count);
            return true;
        }
        case 6:
            if (p[0] > 1 || ((p[1] << 8) | p[2]) > 1000) break;
            companion.playing = p[0]; companion.progress = (p[1] << 8) | p[2];
            companion.lyric_time = companion.screen_activity = timer_read32();
            ++companion.revision;
            return true;
        case 7: {
            rtc_time_t t = {.year = 2000 + p[0], .month = p[1], .day = p[2], .weekday = p[3],
                            .hours = p[4], .minutes = p[5], .seconds = p[6]};
            if (!valid_time(&t)) break;
            p[7] = rtc_set_time(&t) ? 1 : 0;
            return true;
        }
        case 8:
            if (p[0] > 3) break;
            companion.page_request = p[0];
            companion.screen_activity = timer_read32();
            ++companion.revision;
            return true;
        default: break;
    }
    data[0] = 0xff;
    return true;
}

void companion_indicators(void) {
    if (!light_mode || !rgb_matrix_is_enabled() || rgb_matrix_get_suspend_state()) return;
    if (light_mode == 2 && !companion_alive(light_heartbeat, 2500)) return;
    uint16_t level = rgb_matrix_get_val();
    if (light_mode == 2) level = level * intensity / 255;
    for (uint8_t i = 0; i < RGB_MATRIX_LED_COUNT; ++i) {
        rgb_matrix_set_color(i, (uint16_t)palette[i].r * level / 255,
                            (uint16_t)palette[i].g * level / 255, (uint16_t)palette[i].b * level / 255);
    }
}

bool via_command_kb(uint8_t *data, uint8_t length) {
    if (!companion_command(data, length)) return false;
    raw_hid_send(data, length);
    return true;
}
