// SPDX-License-Identifier: GPL-2.0-or-later
#pragma once
#include <stdint.h>
#include <stdbool.h>

enum device_setting {
    DS_THEME, DS_ACCENT, DS_TIMEOUT, DS_ENGLISH, DS_BACKLIGHT,
    DS_RGB_ENABLED, DS_MAC, DS_GUI_LOCK, DS_ENCODER, DS_MEDIA,
    DS_PROFILE, DS_FKEYS, DS_SCREEN, DS_WIRED, DS_BATTERY, DS_CONNECTION,
    DS_COUNT
};
enum device_action { DA_DIM, DA_BRIGHTEN, DA_WAKE, DA_PAIR, DA_ISP, DA_RESET };
bool device_settings_command(uint8_t *data, uint8_t length);
void device_settings_task(void);

// Board adapters expose capabilities rather than manufacturing unsupported
// controls on the host. DS_WIRED/BATTERY/CONNECTION are read-only status.
uint16_t device_settings_supported(void);
uint16_t device_settings_writable(void);
uint8_t device_settings_actions(void);
uint8_t device_setting_read(uint8_t field);
bool device_setting_write(uint8_t field, uint8_t value);
bool device_action_run(uint8_t action);
