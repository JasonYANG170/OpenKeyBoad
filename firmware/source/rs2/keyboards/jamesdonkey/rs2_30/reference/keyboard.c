#include "companion.h"
// SPDX-License-Identifier: GPL-2.0-or-later
#include "rs2_30.h"
#include "bluetooth/ch582f_ajazz.h"
#include "connection.h"
#include "host.h"
#include "media/media.h"
#include "rtc/rtc.h"
#include "usb_main.h"
#include "watchdog.h"

#define PAIR_HOLD_MS 3000
#define MODE_SWITCH_PIN B12
#define MODE_DEBOUNCE_MS 20
#define WIRELESS_LCD_SETTLE_MS 850
#define WIRELESS_RGB_DELAY_MS 400

static bool wired = true;
static bool sampled_wired;
static uint32_t mode_changed;
static ch582_profile_t profile = CH582_PROFILE_BT_1;
static uint16_t pairing_key;
static uint32_t pairing_started;
static uint32_t rgb_changed;
static bool rgb_needs_save;
static enum { START_CLOCK, START_DISPLAY, START_RGB, START_COMPLETE } startup;
static uint32_t startup_timestamp;
static bool display_retried;
static uint8_t reset_status;

void early_hardware_init_post(void) {
    // Use the SPI0 pin routing verified during the RS2 display test.
    SN_PFPA->SPI_b.MISO0 = 0b11;
    SN_PFPA->SPI_b.MOSI0 = 0b11;
    SN_PFPA->SPI_b.SCK0 = 0b11;
    SN_PFPA->UART_b.UTXD2 = 0b11;
    SN_PFPA->UART_b.URXD2 = 0b11;

    // Match the RS2 1.35 board bring-up at 0x8E96 for both static outputs.
    gpio_write_pin_high(B0);
    gpio_write_pin_high(B18);
    gpio_set_pin_output(B0);
    gpio_set_pin_output(B18);
}

static bool valid_profile(uint32_t value) {
    return value == CH582_PROFILE_PEER_24G || (value >= CH582_PROFILE_BT_1 && value <= CH582_PROFILE_BT_3);
}

static void set_wired_mode(bool enabled) {
    wired = enabled;
    pairing_key = KC_NO;
    if (wired) {
        ch582_cancel_connect();
        connection_set_host_noeeprom(CONNECTION_HOST_USB);
    } else {
        ch582_set_profile(profile);
        connection_set_host_noeeprom(CONNECTION_HOST_BLUETOOTH);
    }
    rs2_screen_connection_changed();
}

void keyboard_post_init_kb(void) {
    reset_status = SN_SYS0->RSTST;
    watchdog_boot_check();
    SN_SYS0->RSTST = 0;
    rs2_screen_prepare();
    uint32_t stored = 0;
    eeconfig_read_kb_datablock(&stored, 0, sizeof(stored));
    profile = valid_profile(stored) ? (ch582_profile_t)stored : CH582_PROFILE_BT_1;
    // Factory 1.35 configures B12 as an input with no internal pull-up and
    // enables USB when the pin is low. The board supplies the bias.
    gpio_set_pin_input(MODE_SWITCH_PIN);
    sampled_wired = !gpio_read_pin(MODE_SWITCH_PIN);
    set_wired_mode(sampled_wired);
    keyboard_post_init_user();
    watchdog_start();
    startup_timestamp = timer_read32();
}

bool process_record_kb(uint16_t keycode, keyrecord_t *record) {
    if (!process_record_user(keycode, record)) return false;
    if (keycode == RS2_ENCODER) {
        if (record->event.pressed) rs2_encoder_toggle_mode();
        return false;
    }
    if (keycode == RS2_MEDIA) {
        if (record->event.pressed) rs2_screen_toggle_media();
        return false;
    }
    if (keycode < RS2_BT1 || keycode > RS2_24G) return true;
    if (wired) return false;
    if (record->event.pressed) {
        ch582_profile_t next = keycode == RS2_24G ? CH582_PROFILE_PEER_24G : CH582_PROFILE_BT_1 + (keycode - RS2_BT1);
        if (profile != next) {
            uint32_t stored = next;
            profile = next;
            eeconfig_update_kb_datablock(&stored, 0, sizeof(stored));
        }
        ch582_set_profile(profile);
        rs2_screen_connection_changed();
        pairing_key = keycode;
        pairing_started = timer_read32();
    } else if (pairing_key == keycode) {
        pairing_key = KC_NO;
    }
    return false;
}

void housekeeping_task_kb(void) {
    bool next_wired = !gpio_read_pin(MODE_SWITCH_PIN);
    if (sampled_wired != next_wired) {
        sampled_wired = next_wired;
        mode_changed = timer_read32();
    } else if (wired != sampled_wired && timer_elapsed32(mode_changed) >= MODE_DEBOUNCE_MS) {
        set_wired_mode(sampled_wired);
    }
    // On battery, let the wireless module and panel supply settle before
    // resetting the LCD. Matrix scanning and wireless reports already run.
    uint16_t startup_delay = 30;
    if (!wired && startup == START_DISPLAY) startup_delay = WIRELESS_LCD_SETTLE_MS;
    if (!wired && startup == START_RGB) startup_delay = WIRELESS_RGB_DELAY_MS;
    if (startup != START_COMPLETE && timer_elapsed32(startup_timestamp) >= startup_delay) {
        switch (startup) {
            case START_CLOCK: rtc_init(); break;
            case START_DISPLAY:
                if (!rs2_screen_init() && !display_retried) {
                    display_retried = true;
                    startup_timestamp = timer_read32();
                    watchdog_kick();
                    return;
                }
                break;
            case START_RGB: rs2_rgb_start(); break;
            case START_COMPLETE: break;
        }
        startup++;
        startup_timestamp = timer_read32();
    }
    if (pairing_key != KC_NO && timer_elapsed32(pairing_started) >= PAIR_HOLD_MS) {
        pairing_key = KC_NO;
        ch582_enter_pairing();
    }
    rgb_matrix_set_suspend_state((wired && USB_DRIVER.state == USB_SUSPENDED) ||
                                 last_input_activity_elapsed() >= 5 * 60 * 1000);
    if (rgb_needs_save && timer_elapsed32(rgb_changed) >= 750) {
        rgb_needs_save = false;
        eeconfig_update_rgb_matrix(&rgb_matrix_config);
    }
    if (startup > START_CLOCK) rtc_task();
    if (startup > START_DISPLAY) rs2_screen_task(wired);
    watchdog_kick();
}

bool via_command_kb(uint8_t *data, uint8_t length) {
    if (length != 32 || data[0] != 0xE2 || data[1] != 0x52 || data[2] != 0x32) return false;
    data[3] = startup;
    data[4] = wired;
    data[5] = ch582_get_battery();
    data[6] = profile;
    data[7] = rgb_matrix_get_suspend_state();
    uint32_t sweeps = rs2_rgb_get_sweep_count();
    memcpy(data + 8, &sweeps, sizeof(sweeps));
    uint32_t uptime = timer_read32();
    memcpy(data + 12, &uptime, sizeof(uptime));
    uint32_t port_b = SN_GPIO1->DATA;
    memcpy(data + 16, &port_b, sizeof(port_b));
    data[20] = reset_status;
    data[21] = ch582_get_conn_state();
    host_driver_t *usb = host_get_driver();
    if (usb && usb->send_raw_hid) usb->send_raw_hid(data, length);
    return true;
}

void rgb_settle_arm(void) {
    rgb_changed = timer_read32();
    rgb_needs_save = true;
}

void via_custom_value_command_kb(uint8_t *data, uint8_t length) {
    if (companion_command(data, length)) return;
    if (length >= 10 && data[0] == 0x07 && data[1] == 0x10 && data[2] == 0x01) {
        rtc_time_t time = {
            .year = 2000 + data[3], .month = data[4], .day = data[5], .weekday = data[6],
            .hours = data[7], .minutes = data[8], .seconds = data[9],
        };
        if (time.month >= 1 && time.month <= 12 && time.day >= 1 && time.day <= 31 &&
            time.weekday <= 6 && time.hours <= 23 && time.minutes <= 59 && time.seconds <= 59) {
            rtc_set_time(&time);
            return;
        }
    } else if (length >= 3 && data[0] == 0x07 && data[1] == MEDIA_CHANNEL) {
        media_hid_command(data, length);
        return;
    }
    data[0] = 0xff;
}

bool rgb_matrix_indicators_user(void) {
    companion_indicators();
    return true;
}
