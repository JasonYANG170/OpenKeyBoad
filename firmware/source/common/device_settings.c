// SPDX-License-Identifier: GPL-2.0-or-later
#include "quantum.h"
#include "device_settings.h"

static uint8_t pending_action = 255;
static uint32_t action_started;
static const uint8_t minimum[DS_COUNT] = {0,0,0,0,1};
static const uint8_t maximum[DS_COUNT] = {2,15,5,1,5,1,1,1,1,1,3,1,1,1,100,4};

static void snapshot(uint8_t *p, uint8_t status) {
    uint16_t supported = device_settings_supported(), writable = device_settings_writable();
    memset(p, 0, 29);
    p[0] = 1; p[1] = status;
    p[2] = supported >> 8; p[3] = supported;
    p[4] = writable >> 8; p[5] = writable;
    p[6] = device_settings_actions();
    for (uint8_t i = 0; i < DS_COUNT; ++i) p[7+i] = supported & (1u << i) ? device_setting_read(i) : 255;
}

bool device_settings_command(uint8_t *data, uint8_t length) {
    if (length != 32 || data[1] != 0x51 || (data[0] != 7 && data[0] != 8)) return false;
    uint8_t *p = data + 3;
    if (data[2] == 17) {
        if (data[0] == 8) { snapshot(p, 0); return true; }
        uint8_t field = p[0], value = p[1], expected = p[2], status = 1;
        if (field < DS_COUNT && (device_settings_writable() & (1u << field)) &&
            value >= minimum[field] && value <= maximum[field]) {
            // Preserve a setting changed on the keyboard/another controller.
            if (device_setting_read(field) != expected) status = 2;
            else status = device_setting_write(field, value) ? 0 : 3;
        }
        snapshot(p, status);
        return true;
    }
    if (data[2] == 18 && data[0] == 7) {
        uint8_t action = p[0];
        p[3] = 1;
        if (action > DA_RESET || p[1] != 0xa5 || p[2] != 0x5a ||
            !(device_settings_actions() & (1u << action))) return true;
        if (pending_action != 255) { p[3] = 3; return true; }
        if (action >= DA_ISP) {
            // Let the HID acknowledgement leave USB before changing devices.
            pending_action = action;
            action_started = timer_read32();
            p[3] = 0;
        } else p[3] = device_action_run(action) ? 0 : 3;
        return true;
    }
    return false;
}

void device_settings_task(void) {
    if (pending_action != 255 && timer_elapsed32(action_started) >= 250) {
        uint8_t action = pending_action;
        pending_action = 255;
        device_action_run(action);
    }
}
