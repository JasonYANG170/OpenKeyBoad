// SPDX-License-Identifier: GPL-2.0-or-later
#include "companion.h"
#include "rtc/rtc.h"

companion_state_t companion = {.cpu = 255, .memory = 255, .gpu = 255, .disk = 255, .page_request = 255};
static rgb_t palette[RGB_MATRIX_LED_COUNT];
static uint8_t light_mode, intensity = 255;
static uint32_t light_heartbeat;
static bool title_changed, bitmap_changed;

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
        p[4] = RGB_MATRIX_LED_COUNT; p[5] = light_mode; p[6] = 3;
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
            if (companion.cpu != p[0] || companion.memory != p[1] || companion.gpu != p[2] || companion.disk != p[3] ||
                !companion_alive(companion.monitor_time, 10000)) ++companion.monitor_revision;
            companion.cpu = p[0]; companion.memory = p[1]; companion.gpu = p[2]; companion.disk = p[3];
            companion.monitor_time = companion.screen_activity = timer_read32();
            ++companion.revision;
            return true;
        case 4: {
            int16_t temperature = (int16_t)((p[0] << 8) | p[1]);
            if (temperature < -1000 || temperature > 800 || p[2] > 100 || p[3] > 99 || p[4] > 23 || p[5] > 59) break;
            if (companion.temperature != temperature || companion.humidity != p[2] || companion.weather_code != p[3] ||
                companion.weather_hour != p[4] || companion.weather_minute != p[5] ||
                !companion_alive(companion.weather_time, 3600000)) ++companion.weather_revision;
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
            uint8_t *target = (op == 5 ? companion.bitmap : companion.title) + offset;
            if (memcmp(target, p + 3, count)) {
                if (op == 5) bitmap_changed = true;
                else title_changed = true;
                memcpy(target, p + 3, count);
            }
            return true;
        }
        case 6:
            if (p[0] > 1 || ((p[1] << 8) | p[2]) > 1000) break;
            if (title_changed) { ++companion.title_revision; title_changed = false; }
            if (bitmap_changed) { ++companion.lyric_revision; bitmap_changed = false; }
            if (companion.playing != p[0] || companion.progress != ((p[1] << 8) | p[2])) ++companion.playback_revision;
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

uint8_t companion_changed(companion_view_t *view, uint8_t remote_page) {
    companion_view_t current = {
        .monitor = companion.monitor_revision, .weather = companion.weather_revision,
        .title = companion.title_revision, .lyric = companion.lyric_revision, .playback = companion.playback_revision,
        .fresh = (companion_alive(companion.monitor_time, 10000) ? 1 : 0) |
                 (companion_alive(companion.weather_time, 3600000) ? 2 : 0) |
                 (companion_alive(companion.lyric_time, 15000) ? 4 : 0),
    };
    uint8_t bands = 0;
    if (remote_page == 1 && view->monitor != current.monitor) bands |= 3;
    if (remote_page == 2 && view->weather != current.weather) bands |= 7;
    if (remote_page == 3) {
        if (view->title != current.title) bands |= 1;
        if (view->lyric != current.lyric) bands |= 2;
        if (view->playback != current.playback) bands |= 4;
    }
    if (remote_page >= 1 && remote_page <= 3 && ((view->fresh ^ current.fresh) & (1 << (remote_page - 1)))) bands |= 7;
    *view = current;
    return bands;
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
