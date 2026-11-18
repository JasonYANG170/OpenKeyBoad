// SPDX-License-Identifier: GPL-2.0-or-later
#pragma once

#include "quantum.h"
#include "qp.h"

enum rs2_keycodes {
    RS2_BT1 = QK_KB_0,
    RS2_BT2,
    RS2_BT3,
    RS2_24G,
    RS2_ENCODER,
    RS2_MEDIA,
};

#define DISPLAY_BACKLIGHT_LEVELS 5
#define RS2_PANEL_WIDTH 240
#define RS2_PANEL_HEIGHT 135

void rs2_screen_prepare(void);
bool rs2_screen_init(void);
void rs2_screen_connection_changed(void);
void rs2_screen_task(bool wired);
void rs2_encoder_toggle_mode(void);
void rs2_screen_toggle_media(void);
bool rs2_screen_blit_rows(painter_device_t device, uint8_t top, uint8_t rows, const uint16_t *pixels);
void display_set_backlight_level(uint8_t level);
uint32_t display_idle_timeout_ms(void);
void rs2_render_dashboard(painter_device_t panel, painter_font_handle_t large, painter_font_handle_t small,
                          bool mac, uint8_t connection, bool media, bool force);
void rs2_send_dashboard_slice(void);
bool rs2_dashboard_needs_redraw(void);
bool rs2_dashboard_pending(void);
void rgb_settle_arm(void);
void rs2_rgb_start(void);
uint32_t rs2_rgb_get_sweep_count(void);
bool rs2_rgb_is_running(void);
void rs2_matrix_scan_pulse(void);

bool rs2_screen_media_enabled(void);
void rs2_screen_set_media(bool enabled);
bool rs2_screen_enabled(void);
void rs2_screen_set_enabled(bool enabled);
uint8_t rs2_wireless_profile(void);
bool rs2_set_wireless_profile(uint8_t value);
