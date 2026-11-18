// SPDX-License-Identifier: GPL-2.0-or-later
#include QMK_KEYBOARD_H
#include "ak650.h"
#include "calculator.h"
#include "companion.h"
#include "device_settings.h"
#include "connection.h"
#include "bluetooth/ch582f_ajazz.h"
#include "graphics/display.h"
#include "graphics/lcd_bus.h"
#include <lib/lib8tion/lib8tion.h>
#include "media/media.h"
#include "qp_surface.h"
#include "wear_leveling_efl_config.h"
#include "fonts/ak650_sc_16.qff.h"
#include "fonts/online_ascii_10.qff.h"

#include <stdio.h>
#include <string.h>
#include <stdlib.h>

#define KNOB_HOLD_MS 450
#define BOOT_HOLD_MS 1200
#define MENU_IDLE_MS 20000
#define LEGACY_PREFERENCES_SIGNATURE 0x414B6500u
#define PREFERENCES_SIGNATURE 0x414C0000u
#define PREFERENCES_MASK 0x3FFFu
#define LANGUAGE_SHIFT 4
#define APPEARANCE_SHIFT 5
#define BACKLIGHT_SHIFT 7
#define SLEEP_SHIFT 10
#define NUMBER_ROW_SHIFT 13
#define KNOB_ROW 1
#define KNOB_COL 14
#define RESET_HOLD_MS 3000
#define RESET_FLASH_MS 180

// The stock V1.05 power-state routine samples B17 (external power) and B16
// (charge complete with external power present). Leave both as inputs.
#define CHARGE_PRESENT_PIN B17
#define CHARGE_COMPLETE_PIN B16

enum setting {
    APPEARANCE,
    ACCENT,
    SCREEN_TIMEOUT,
    LANGUAGE,
    DEVELOPER,
    EXIT,
    MENU_COUNT,
    LIGHTING,
    EFFECT,
    BRIGHTNESS,
    COLOR,
    SPEED,
    BACKLIGHT,
};

enum view { HOME, MENU, EDIT };
enum dashboard_page { PAGE_HOME, PAGE_CALC, PAGE_BRIGHTNESS, PAGE_RGB, PAGE_BATTERY, PAGE_DEVICE, PAGE_SETTINGS, PAGE_MONITOR, PAGE_WEATHER, PAGE_LYRICS, PAGE_NETWORK, PAGE_TIMER, PAGE_COUNT };
static bool page_detail;
enum page_control { BROWSE, FIRST_CONTROL, SECOND_CONTROL, THIRD_CONTROL, FOURTH_CONTROL, FIFTH_CONTROL };

typedef struct { const char *en, *zh; } translation_t;

static const translation_t settings[MENU_COUNT] = {
    [APPEARANCE] = {"Theme", "主题"}, [ACCENT] = {"Accent", "配色"},
    [SCREEN_TIMEOUT] = {"Sleep", "熄屏"}, [LANGUAGE] = {"Lang", "语言"},
    [DEVELOPER] = {"ISP", "刷机"}, [EXIT] = {"Back", "返回"},
};
static const enum setting rgb_controls[] = {BRIGHTNESS, COLOR, EFFECT, SPEED, LIGHTING};
static const struct {
    uint8_t mode;
    translation_t name;
} effects[] = {
    {RGB_MATRIX_SOLID_COLOR, {"Solid", "常亮"}},
    {RGB_MATRIX_BREATHING, {"Breathe", "呼吸"}},
    {RGB_MATRIX_CYCLE_ALL, {"Cycle", "变色"}},
    {RGB_MATRIX_CYCLE_LEFT_RIGHT, {"Wave", "彩虹波"}},
    {RGB_MATRIX_CYCLE_PINWHEEL, {"Pinwheel", "旋转"}},
    {RGB_MATRIX_JELLYBEAN_RAINDROPS, {"Raindrops", "雨滴"}},
    {RGB_MATRIX_TYPING_HEATMAP, {"Heatmap", "热力"}},
};
static const struct {
    uint8_t hue, saturation;
    translation_t name;
} colors[] = {
    {0, 0, {"White", "白色"}}, {4, 215, {"Coral", "珊瑚"}}, {31, 255, {"Amber", "琥珀"}},
    {108, 188, {"Mint", "薄荷"}}, {136, 222, {"Ice", "冰蓝"}}, {169, 250, {"Blue", "深蓝"}},
    {203, 190, {"Lilac", "丁香"}},
};

enum appearance { DARK, LIGHT, SAND };
static const translation_t appearances[] = {
    [DARK] = {"Dark", "深色"}, [LIGHT] = {"Light", "浅色"}, [SAND] = {"Sand", "暖沙"},
};

static const struct {
    uint8_t hue, saturation;
    translation_t label;
} accents[] = {
    {135, 199, {"Ice", "冰蓝"}}, {29, 205, {"Amber", "琥珀"}},
    {0, 206, {"Red", "红色"}}, {14, 225, {"Orange", "橙色"}},
    {43, 210, {"Gold", "金黄"}}, {61, 197, {"Lime", "青柠"}},
    {88, 210, {"Green", "草绿"}}, {102, 180, {"Mint", "薄荷"}},
    {120, 190, {"Teal", "青绿"}}, {152, 205, {"Sky", "天蓝"}},
    {170, 220, {"Blue", "宝蓝"}}, {188, 186, {"Indigo", "靛蓝"}},
    {203, 189, {"Lilac", "丁香"}}, {219, 195, {"Purple", "紫色"}},
    {236, 183, {"Rose", "玫红"}}, {250, 125, {"Coral", "珊瑚"}},
};

static const struct {
    uint32_t milliseconds;
    translation_t label;
} screen_timeouts[] = {
    {30u * 1000u, {"30 sec", "30 秒"}},
    {60u * 1000u, {"1 min", "1 分钟"}},
    {3u * 60u * 1000u, {"3 min", "3 分钟"}},
    {5u * 60u * 1000u, {"5 min", "5 分钟"}},
    {10u * 60u * 1000u, {"10 min", "10 分钟"}},
    {0, {"Always on", "常亮"}},
};

static enum view view = HOME;
static enum dashboard_page page;
static enum page_control control;
static bool screen_interaction;
static rs2_calculator_t calculator;
static matrix_row_t calculator_keys_down[MATRIX_ROWS];
static uint8_t selected;
static bool redraw = true;
static bool preferences_loaded;
static uint8_t accent_color;
static bool english;
static uint8_t appearance;
static uint8_t backlight = DISPLAY_BACKLIGHT_LEVELS;
static uint8_t screen_timeout = 2; // 3 minutes, matching the previous default.
static bool preferences_pending;
static uint32_t activity;
static uint32_t knob_started;
static uint16_t knob_tap;
static bool knob_handled;
static bool knob_held;
static bool fkeys_first;
static bool grave_held;
static uint8_t remapped_number_row[12];
static bool reset_held;
static bool reset_confirmed;
static uint32_t reset_started;
static uint32_t reset_flash_started;

enum charge_state { ON_BATTERY, CHARGING, CHARGE_COMPLETE };
static enum charge_state charge_state;

void keyboard_post_init_user(void) {
    gpio_set_pin_input(CHARGE_PRESENT_PIN);
    gpio_set_pin_input(CHARGE_COMPLETE_PIN);
}

static void update_charge_state(void) {
    static enum charge_state sample;
    static uint32_t sample_since;
    enum charge_state current = ON_BATTERY;
    if (gpio_read_pin(CHARGE_PRESENT_PIN)) {
        current = gpio_read_pin(CHARGE_COMPLETE_PIN) ? CHARGE_COMPLETE : CHARGING;
    }
    if (current != sample) {
        sample = current;
        sample_since = timer_read32();
    } else if (timer_elapsed32(sample_since) >= 50) {
        charge_state = sample;
    }
}




bool openkeyboard_media_enabled(void);
void openkeyboard_set_media(bool enabled);
uint8_t openkeyboard_wireless_profile(void);
bool openkeyboard_set_wireless_profile(uint8_t value);
static bool board_media_enabled(void) { return openkeyboard_media_enabled(); }
static void board_set_media(bool enabled) { openkeyboard_set_media(enabled); }
static bool board_screen_enabled(void) { return display_get_power(); }
static void board_set_screen(bool enabled) { display_set_power(enabled); }
static uint8_t board_wireless_profile(void) { return openkeyboard_wireless_profile(); }
static bool board_set_wireless_profile(uint8_t value) { return openkeyboard_set_wireless_profile(value); }

uint16_t device_settings_supported(void) { return 0xFFFFu; }
uint16_t device_settings_writable(void) { return openkeyboard_wireless_profile() == 0 ? 0x1BFFu : 0x1FFFu; }
uint8_t device_settings_actions(void) { return connection_get_host() == CONNECTION_HOST_USB ? 0x37u : 0x3Fu; }

uint8_t device_setting_read(uint8_t field) {
    switch (field) {
        case DS_THEME: return appearance;
        case DS_ACCENT: return accent_color;
        case DS_TIMEOUT: return screen_timeout;
        case DS_ENGLISH: return english;
        case DS_BACKLIGHT: return backlight;
        case DS_RGB_ENABLED: return rgb_matrix_is_enabled();
        case DS_MAC: return keymap_config.swap_lalt_lgui;
        case DS_GUI_LOCK: return keymap_config.no_gui;
        case DS_ENCODER: return screen_interaction;
        case DS_MEDIA: return board_media_enabled();
        case DS_PROFILE: return board_wireless_profile();
        case DS_FKEYS: return fkeys_first;
        case DS_SCREEN: return board_screen_enabled();
        case DS_WIRED: return connection_get_host() == CONNECTION_HOST_USB;
        case DS_BATTERY: return ch582_get_battery();
        case DS_CONNECTION: return ch582_get_conn_state();
        default: return 255;
    }
}

bool device_setting_write(uint8_t field, uint8_t value) {
    switch (field) {
        case DS_THEME: appearance = value; preferences_pending = true; break;
        case DS_ACCENT: accent_color = value; preferences_pending = true; break;
        case DS_TIMEOUT: screen_timeout = value; preferences_pending = true; break;
        case DS_ENGLISH: english = value; preferences_pending = true; break;
        case DS_BACKLIGHT:
            backlight = value; display_set_backlight_level(value); preferences_pending = true; break;
        case DS_RGB_ENABLED:
            if (value) rgb_matrix_enable_noeeprom(); else rgb_matrix_disable_noeeprom();
            rgb_settle_arm(); break;
        case DS_MAC:
            clear_keyboard();
            keymap_config.swap_lalt_lgui = value; keymap_config.swap_ralt_rgui = value;
            eeconfig_update_keymap(&keymap_config); break;
        case DS_GUI_LOCK:
            clear_keyboard(); keymap_config.no_gui = value;
            eeconfig_update_keymap(&keymap_config); break;
        case DS_ENCODER:
            screen_interaction = value; view = HOME; control = BROWSE; page_detail = false; break;
        case DS_MEDIA: board_set_media(value); break;
        case DS_PROFILE: return board_set_wireless_profile(value);
        case DS_FKEYS: fkeys_first = value; preferences_pending = true; break;
        case DS_SCREEN: board_set_screen(value); break;
        default: return false;
    }
    activity = timer_read32(); redraw = true;
    return true;
}

bool device_action_run(uint8_t action) {
    switch (action) {
        case DA_DIM: tap_code16(KC_BRID); break;
        case DA_BRIGHTEN: tap_code16(KC_BRIU); break;
        case DA_WAKE:
            board_set_screen(true); companion.screen_activity = timer_read32(); break;
        case DA_PAIR:
            // Pair the remembered wireless profile without changing USB routing.
            ch582_pair((ch582_profile_t)(0x30 + board_wireless_profile())); break;
        case DA_ISP: reset_keyboard(); break;
        case DA_RESET: eeconfig_disable(); soft_reset_keyboard(); break;
        default: return false;
    }
    return true;
}

static const char *translated(translation_t value) { return english ? value.en : value.zh; }
static const char *tr(const char *en, const char *zh) { return translated((translation_t){en, zh}); }

uint32_t display_idle_timeout_ms(void) {
    uint32_t timeout = screen_timeouts[screen_timeout].milliseconds;
    return timeout && companion_alive(companion.screen_activity, timeout) ? 0 : timeout;
}

static uint8_t next_index(uint8_t current, uint8_t count, bool forward) {
    return (current + count + (forward ? 1 : -1)) % count;
}

static int8_t effect_index(void) {
    for (uint8_t i = 0; i < ARRAY_SIZE(effects); ++i) {
        if (effects[i].mode == rgb_matrix_get_mode()) return i;
    }
    return -1;
}

static int8_t color_index(void) {
    hsv_t hsv = rgb_matrix_get_hsv();
    for (uint8_t i = 0; i < ARRAY_SIZE(colors); ++i) {
        if (colors[i].saturation == hsv.s && (!hsv.s || colors[i].hue == hsv.h)) return i;
    }
    return -1;
}

static uint8_t next_choice(int8_t current, uint8_t count, bool forward) {
    if (current < 0) return forward ? 0 : count - 1;
    return next_index(current, count, forward);
}

static uint8_t adjusted(uint8_t value, uint8_t max, bool increase) {
    int16_t step = (max + 9) / 10;
    int16_t result = value + (increase ? step : -step);
    if (result <= 0) return 0;
    if (result >= max) return max;
    return result;
}

static void adjust_setting(enum setting setting, bool clockwise) {
    activity = timer_read32();
    redraw = true;
    switch (setting) {
        case LIGHTING:
            if (clockwise) rgb_matrix_enable_noeeprom();
            else rgb_matrix_disable_noeeprom();
            break;
        case EFFECT:
            rgb_matrix_mode_noeeprom(effects[next_choice(effect_index(), ARRAY_SIZE(effects), clockwise)].mode);
            break;
        case BRIGHTNESS: {
            hsv_t hsv = rgb_matrix_get_hsv();
            rgb_matrix_sethsv_noeeprom(hsv.h, hsv.s, adjusted(hsv.v, RGB_MATRIX_MAXIMUM_BRIGHTNESS, clockwise));
            break;
        }
        case COLOR: {
            uint8_t i = next_choice(color_index(), ARRAY_SIZE(colors), clockwise);
            rgb_matrix_sethsv_noeeprom(colors[i].hue, colors[i].saturation, rgb_matrix_get_val());
            break;
        }
        case SPEED:
            rgb_matrix_set_speed_noeeprom(adjusted(rgb_matrix_get_speed(), UINT8_MAX, clockwise));
            break;
        case ACCENT:
            accent_color = next_index(accent_color, ARRAY_SIZE(accents), clockwise);
            preferences_pending = true;
            return;
        case APPEARANCE:
            appearance = next_index(appearance, ARRAY_SIZE(appearances), clockwise);
            preferences_pending = true;
            return;
        case BACKLIGHT:
            if (clockwise && backlight < DISPLAY_BACKLIGHT_LEVELS) {
                ++backlight;
            } else if (!clockwise && backlight > 1) {
                --backlight;
            } else {
                return;
            }
            display_set_backlight_level(backlight);
            preferences_pending = true;
            return;
        case SCREEN_TIMEOUT:
            screen_timeout = next_index(screen_timeout, ARRAY_SIZE(screen_timeouts), clockwise);
            preferences_pending = true;
            return;
        case LANGUAGE:
            english = !english;
            preferences_pending = true;
            return;
        default:
            return;
    }
    rgb_settle_arm();
}

static void turn(bool clockwise) {
    activity = timer_read32();
    redraw = true;
    if (view == MENU) {
        selected = next_index(selected, MENU_COUNT, clockwise);
    } else if (view == EDIT) {
        adjust_setting(selected, clockwise);
    } else if (control == BROWSE) {
        page_detail = false;
        page = next_index(page, PAGE_COUNT, clockwise);
    } else if (page == PAGE_BRIGHTNESS) {
        if (control == FIRST_CONTROL) tap_code16(clockwise ? KC_BRIU : KC_BRID);
        else adjust_setting(BACKLIGHT, clockwise);
    } else if (page == PAGE_RGB) {
        adjust_setting(rgb_controls[control - FIRST_CONTROL], clockwise);
    }
}

static void toggle_encoder_mode(void) {
    screen_interaction = !screen_interaction;
    if (screen_interaction) display_set_power(true);
    view = HOME;
    control = BROWSE;
    redraw = true;
}

static void click(void) {
    activity = timer_read32();
    redraw = true;
    if (view == HOME) {
        if (page == PAGE_MONITOR || page == PAGE_WEATHER || page == PAGE_NETWORK) page_detail = !page_detail;
        if (page == PAGE_BRIGHTNESS) control = next_index(control, 3, true);
        if (page == PAGE_RGB) control = next_index(control, ARRAY_SIZE(rgb_controls) + 1, true);
        if (page == PAGE_SETTINGS) {
            selected = APPEARANCE;
            view = MENU;
        }
    } else if (view == EDIT) {
        view = MENU;
    } else if (selected == EXIT) {
        view = HOME;
    } else {
        view = EDIT;
    }
}

static bool confirming_boot(void) {
    return view == EDIT && selected == DEVELOPER;
}

static bool knob_hold_elapsed(void) {
    return timer_elapsed32(knob_started) >= (confirming_boot() ? BOOT_HOLD_MS : KNOB_HOLD_MS);
}

// Accept legacy VIA maps that assigned the screen keycode to the knob.
static bool is_knob_mode_key(uint16_t keycode) {
    return keycode == AK650_ENCODER || keycode == SCR_TOG;
}

static bool knob_can_hold(void) {
    return knob_handled && !is_knob_mode_key(knob_tap) && (view != HOME || control != BROWSE || page_detail);
}

static void hold(void) {
    if (confirming_boot()) {
        reset_keyboard();
        return;
    }
    activity = timer_read32();
    redraw = true;
    if (view == HOME) {
        control = BROWSE; page_detail = false;
    } else {
        view = view == EDIT ? MENU : HOME;
    }
}

static char calculator_symbol(uint16_t keycode) {
    uint8_t mods = get_mods() | get_weak_mods() | get_oneshot_mods();
    if (IS_QK_MODS(keycode)) {
        uint8_t mapped = QK_MODS_GET_MODS(keycode);
        mods |= mapped & 0x10 ? (mapped & 0x0f) << 4 : mapped;
        keycode = QK_MODS_GET_BASIC_KEYCODE(keycode);
    }
    if (mods & (MOD_MASK_CTRL | MOD_MASK_ALT | MOD_MASK_GUI)) return 0;
    if (mods & MOD_MASK_SHIFT) {
        switch (keycode) {
            case KC_8: return '*';
            case KC_9: return '(';
            case KC_0: return ')';
            case KC_EQL: return '+';
            default: return 0;
        }
    }
    if (keycode >= KC_1 && keycode <= KC_9) return '1' + keycode - KC_1;
    switch (keycode) {
        case KC_0: return '0';
        case KC_EQL:
        case KC_ENT: return '=';
        case KC_MINS: return '-';
        case KC_SLSH: return '/';
        case KC_DOT: return '.';
        case KC_ESC: return 'C';
        case KC_BSPC: return '\b';
        default: return 0;
    }
}

static bool calculator_event(uint16_t keycode, keyevent_t event) {
    matrix_row_t mask = (matrix_row_t)1 << event.key.col;
    matrix_row_t *held = &calculator_keys_down[event.key.row];
    if (!event.pressed) {
        bool handled = *held & mask;
        *held &= ~mask;
        return handled;
    }
    if (!screen_interaction || view != HOME || page != PAGE_CALC) return false;
    char symbol = calculator_symbol(keycode);
    if (!symbol) return false;
    *held |= mask;
    rs2_calculator_key(&calculator, symbol);
    redraw = true;
    return true;
}

bool pre_process_record_user(uint16_t keycode, keyrecord_t *record) {
    keyevent_t event = record->event;
    if (IS_ENCODEREVENT(event) && screen_interaction) {
        if (event.pressed) turn(event.type == ENCODER_CW_EVENT);
        return false;
    }
    if (!IS_KEYEVENT(event)) return true;
    if (calculator_event(keycode, event)) return false;
    if (event.key.row != KNOB_ROW || event.key.col != KNOB_COL) return true;

    if (event.pressed) {
        if (!screen_interaction && !is_knob_mode_key(keycode)) return true;
        knob_handled = true;
        knob_held = false;
        knob_tap = keycode;
        knob_started = activity = timer_read32();
    } else {
        if (!knob_handled) return true;
        bool long_press = knob_can_hold() && knob_hold_elapsed();
        knob_handled = false;
        if (knob_held) return false;
        if (is_knob_mode_key(knob_tap)) {
            toggle_encoder_mode();
        } else if (long_press) {
            hold();
        } else {
            click();
        }
    }
    return false;
}

bool process_record_user(uint16_t keycode, keyrecord_t *record) {
    bool pressed = record->event.pressed;
    switch (keycode) {
        case AK650_ENCODER:
            if (pressed) toggle_encoder_mode();
            return false;
        case AK650_FN_ESC:
            if (pressed) {
                if (get_mods() & MOD_MASK_SHIFT) {
                    fkeys_first = !fkeys_first;
                    preferences_pending = true;
                    activity = timer_read32();
                } else {
                    grave_held = true;
                    register_code(KC_GRV);
                }
            } else if (grave_held) {
                grave_held = false;
                unregister_code(KC_GRV);
            }
            return false;
        case AK650_RESET:
            reset_held = pressed;
            if (pressed) reset_started = timer_read32();
            return false;
        case AK650_ZH:
        case AK650_EN:
            if (pressed) {
                english = keycode == AK650_EN;
                preferences_pending = true;
                activity = timer_read32();
                redraw = true;
            }
            return false;
    }

    uint8_t col = record->event.key.col;
    if (!IS_KEYEVENT(record->event) || record->event.key.row != 1 || col < 1 || col > 12) return true;

    static const uint8_t numbers[] = {
        KC_1, KC_2, KC_3, KC_4, KC_5, KC_6, KC_7, KC_8, KC_9, KC_0, KC_MINS, KC_EQL,
    };
    uint8_t index = col - 1;
    uint8_t *mapped = &remapped_number_row[index];
    if (!pressed && *mapped) {
        unregister_code(*mapped);
        *mapped = 0;
        return false;
    }
    if (!pressed || !fkeys_first) return true;
    uint8_t function = KC_F1 + index;
    if (keycode == numbers[index]) {
        *mapped = function;
    } else if (keycode == function) {
        *mapped = numbers[index];
    } else {
        return true; // A VIA override takes precedence.
    }
    register_code(*mapped);
    return false;
}

bool rgb_matrix_indicators_kb(void) {
    if (reset_confirmed) {
        uint8_t white = (timer_elapsed32(reset_flash_started) / RESET_FLASH_MS) % 2 == 0 ? 80 : 0;
        rgb_matrix_set_color_all(white, white, white);
        return false;
    }
    companion_indicators();
    if (ch582_is_usb()) return rgb_matrix_indicators_user();

    static ch582_conn_state_t last_state;
    static uint8_t last_col;
    static uint32_t changed;
    static const rgb_t colors[] = {{0, 0, 255}, {0, 220, 255}, {155, 0, 255}, {0, 255, 0}};
    uint8_t col = ch582_is_24g() ? 4 : ch582_get_target_slot();
    ch582_conn_state_t state = ch582_get_conn_state();
    if (state != last_state || col != last_col) {
        changed = timer_read32();
        last_state = state;
        last_col = col;
    }
    if (col < 1 || col > ARRAY_SIZE(colors)) return rgb_matrix_indicators_user();
    uint32_t elapsed = timer_elapsed32(changed);
    bool pairing = state == CH582_CONN_PAIRING && elapsed < 30000;
    bool linking = state == CH582_CONN_LINKING && elapsed < 10000;
    if (pairing || linking || (state == CH582_CONN_CONNECTED && elapsed < 1000)) {
        bool on = !(pairing || linking) || (elapsed / (pairing ? 150u : 500u)) % 2 == 0;
        uint8_t brightness = on ? MAX(32, rgb_matrix_get_val()) : 0;
        rgb_t color = colors[col - 1];
        uint8_t index = g_led_config.matrix_co[2][col]; // Q, W, E, R.
        if (index < RGB_MATRIX_LED_COUNT) {
            rgb_matrix_set_color(index, scale8(color.r, brightness), scale8(color.g, brightness),
                                scale8(color.b, brightness));
        }
    }
    return rgb_matrix_indicators_user();
}

void housekeeping_task_user(void) {
    device_settings_task();
    if (companion.page_request != 255) {
        static const enum dashboard_page remote_pages[] = {PAGE_HOME, PAGE_MONITOR, PAGE_WEATHER, PAGE_LYRICS, PAGE_NETWORK, PAGE_TIMER};
        enum dashboard_page requested = remote_pages[companion.page_request];
        companion.page_request = 255;
        if (page != requested || !screen_interaction || view != HOME) {
            page = requested;
            screen_interaction = true;
            view = HOME;
            control = BROWSE;
            redraw = true;
        }
    }
    update_charge_state();
    if (!reset_confirmed && reset_held && timer_elapsed32(reset_started) >= RESET_HOLD_MS) {
        reset_confirmed = true;
        reset_flash_started = timer_read32();
        rgb_matrix_enable_noeeprom();
    }
    if (reset_confirmed && timer_elapsed32(reset_flash_started) >= 6 * RESET_FLASH_MS && !lcd_blit_busy()) {
        eeconfig_disable();
        soft_reset_keyboard();
        return;
    }
    if (!preferences_loaded) {
        uint32_t saved = eeconfig_read_user();
        bool current_format = (saved & ~PREFERENCES_MASK) == PREFERENCES_SIGNATURE;
        if (current_format) {
            accent_color = saved & 15u;
            english = saved & (1u << LANGUAGE_SHIFT);
            uint8_t theme = (saved >> APPEARANCE_SHIFT) & 3u;
            if (theme < ARRAY_SIZE(appearances)) appearance = theme;
            uint8_t level = (saved >> BACKLIGHT_SHIFT) & 7u;
            if (level >= 1 && level <= DISPLAY_BACKLIGHT_LEVELS) backlight = level;
            uint8_t timeout = (saved >> SLEEP_SHIFT) & 7u;
            if (timeout < ARRAY_SIZE(screen_timeouts)) screen_timeout = timeout;
            fkeys_first = saved & (1u << NUMBER_ROW_SHIFT);
        } else if ((saved & ~0x3Fu) == LEGACY_PREFERENCES_SIGNATURE) {
            accent_color = saved & 1u;
            english = saved & 2u;
            appearance = saved & 4u ? LIGHT : DARK;
            uint8_t level = (saved >> 3) & 7u;
            if (level >= 1 && level <= DISPLAY_BACKLIGHT_LEVELS) backlight = level;
        }
        display_set_backlight_level(backlight);
        preferences_loaded = true;
        redraw = true;
    }
    if (knob_can_hold() && !knob_held && knob_hold_elapsed()) {
        knob_held = true;
        hold();
    }
    if ((view != HOME || control != BROWSE || page_detail) && timer_elapsed32(activity) >= MENU_IDLE_MS) {
        view = HOME;
        control = BROWSE;
        redraw = true;
    }
    if (!reset_confirmed && preferences_pending && timer_elapsed32(activity) >= 900 && !lcd_blit_busy()) {
        preferences_pending = false;
        eeconfig_update_user(PREFERENCES_SIGNATURE | accent_color | (english << LANGUAGE_SHIFT) |
                             (appearance << APPEARANCE_SHIFT) |
                             (backlight << BACKLIGHT_SHIFT) | (screen_timeout << SLEEP_SHIFT) |
                             (fkeys_first << NUMBER_ROW_SHIFT));
    }
    display_pump_ak650();
}

typedef struct { uint8_t h, s, v; } ink_t;
typedef struct {
    ink_t background, card, rule, foreground, muted;
    uint8_t accent_value, selection_saturation, selection_value;
} palette_t;
typedef struct {
    painter_device_t panel, tile;
    painter_font_handle_t large, small, tiny;
    const palette_t *palette;
    ink_t accent, selected;
} canvas_t;

#define SCREEN_WIDTH 128
#define SCREEN_HEIGHT 128
#define TILE_HEIGHT 34
#define SPI_SLICE_ROWS 4
#define HEADER_HEIGHT 28
#define MENU_COLUMNS 3
#define HERO_Y HEADER_HEIGHT
#define DETAIL_Y (HERO_Y + TILE_HEIGHT)
#define STATUS_Y 84
#define TALL_DETAIL_Y (STATUS_Y - TILE_HEIGHT)
#define FOOTER_Y 106
#define CONTENT_RIGHT (SCREEN_WIDTH - 7)

static uint16_t tile_pixels[SCREEN_WIDTH * TILE_HEIGHT];
static struct {
    uint8_t top, height, sent;
} tile_transfer;
static const palette_t palettes[] = {
    [DARK] = {
        .background = {158, 157, 25}, .card = {156, 149, 45}, .rule = {153, 132, 76},
        .foreground = {145, 16, 252}, .muted = {150, 69, 174},
        .accent_value = 255, .selection_saturation = 170, .selection_value = 79,
    },
    [LIGHT] = {
        .background = {148, 8, 250}, .card = {145, 24, 232}, .rule = {153, 34, 175},
        .foreground = {158, 145, 47}, .muted = {154, 93, 112},
        .accent_value = 120, .selection_saturation = 61, .selection_value = 249,
    },
    [SAND] = {
        .background = {26, 38, 231}, .card = {29, 28, 249}, .rule = {23, 76, 166},
        .foreground = {21, 126, 53}, .muted = {25, 119, 108},
        .accent_value = 118, .selection_saturation = 82, .selection_value = 245,
    },
};

// 12 × 12 monochrome symbols, tinted by the active screen palette.
static const uint16_t icon_usb[] = {0x060, 0x0f0, 0x060, 0x060, 0x266, 0x266, 0x3e6, 0x07e, 0x060, 0x0f0, 0x0f0, 0x000};
static const uint16_t icon_bt[] = {0x040, 0x060, 0x250, 0x148, 0x0d0, 0x060, 0x0d0, 0x148, 0x250, 0x060, 0x040, 0x000};
static const uint16_t icon_radio[] = {0x000, 0x1f8, 0x204, 0x402, 0x0f0, 0x108, 0x000, 0x060, 0x090, 0x060, 0x060, 0x000};
static const uint16_t icon_windows[] = {0x000, 0x79e, 0x79e, 0x79e, 0x79e, 0x000, 0x79e, 0x79e, 0x79e, 0x79e, 0x000, 0x000};
static const uint16_t icon_mac[] = {0x018, 0x030, 0x020, 0x39c, 0x7fe, 0x7fc, 0x7f8, 0x7fc, 0x7fe, 0x3fc, 0x1d8, 0x000};
static const uint16_t icon_caps[] = {0x060, 0x0f0, 0x1f8, 0x3fc, 0x0f0, 0x0f0, 0x0f0, 0x000, 0x3fc, 0x3fc, 0x000, 0x000};
static const uint16_t icon_lower[] = {0, 0, 0x1f8, 0x30c, 0x00c, 0x1fc, 0x30c, 0x30c, 0x30c, 0x1fc, 0, 0};
static const uint16_t icon_light[] = {0x060, 0x462, 0x204, 0x0f0, 0x1f8, 0xdfb, 0xdfb, 0x1f8, 0x0f0, 0x204, 0x462, 0x060};
static const uint16_t icon_lock[] = {0x0f0, 0x198, 0x108, 0x108, 0x3fc, 0x3fc, 0x39c, 0x39c, 0x39c, 0x3fc, 0x3fc, 0x000};
static const uint16_t icon_unlock[] = {0x0f0, 0x198, 0x108, 0x100, 0x3fc, 0x3fc, 0x39c, 0x39c, 0x39c, 0x3fc, 0x3fc, 0};
static const uint16_t icon_monitor[] = {0, 0x7fe, 0x402, 0x402, 0x402, 0x402, 0x402, 0x7fe, 0x060, 0x060, 0x1f8, 0};
static const uint16_t icon_volume[] = {0, 0x108, 0x30c, 0x70a, 0xf2a, 0xf2a, 0xf2a, 0xf2a, 0x70a, 0x30c, 0x108, 0};
static const uint16_t icon_keypad[] = {0, 0x7fe, 0x402, 0x7fe, 0x402, 0x552, 0x402, 0x552, 0x402, 0x552, 0x7fe, 0};
static const uint16_t icon_gear[] = {0x060, 0x060, 0x3fc, 0x798, 0x30c, 0xf0f, 0xf0f, 0x30c, 0x19e, 0x3fc, 0x060, 0x060};
static const uint16_t icon_clock[] = {0x0f0, 0x30c, 0x402, 0x462, 0x462, 0x47a, 0x402, 0x402, 0x30c, 0x0f0, 0, 0};
static const uint16_t icon_power[] = {0x060, 0x060, 0x060, 0x264, 0x462, 0x402, 0x402, 0x402, 0x30c, 0x0f0, 0, 0};
static const uint16_t icon_back[] = {0, 0x040, 0x080, 0x100, 0x200, 0x7fc, 0x200, 0x100, 0x080, 0x040, 0, 0};
static const uint16_t icon_language[] = {0, 0x180, 0x240, 0x240, 0x3c0, 0x240, 0x258, 0x024, 0x03c, 0x024, 0x03c, 0};

static const uint16_t icon_cloud[] = {0,0,0x0e0,0x190,0x308,0x604,0xc02,0x802,0x802,0x7fc,0,0};
static const uint16_t icon_rain[] = {0,0x0e0,0x190,0x308,0x604,0xc02,0x7fc,0,0x248,0x490,0x248,0};
static const uint16_t icon_snow[] = {0x060,0x264,0x168,0x0f0,0x7fe,0x0f0,0x168,0x264,0x060,0,0,0};
static const uint16_t icon_storm[] = {0,0x0e0,0x190,0x308,0x604,0xc02,0x7fc,0x080,0x100,0x3e0,0x040,0x080};
static const uint16_t icon_fog[] = {0,0,0x3fc,0,0x7fe,0,0x3fc,0,0x7fe,0,0,0};
static const uint16_t icon_drop[] = {0x060,0x060,0x0f0,0x0f0,0x198,0x198,0x30c,0x30c,0x30c,0x198,0x0f0,0};
static const uint16_t icon_note[] = {0x01e,0x012,0x012,0x012,0x012,0x012,0x072,0x0f2,0x0ee,0x00e,0,0};
static const uint16_t icon_play[] = {0,0x200,0x300,0x380,0x3c0,0x3e0,0x3c0,0x380,0x300,0x200,0,0};
static const uint16_t icon_pause[] = {0,0x198,0x198,0x198,0x198,0x198,0x198,0x198,0x198,0x198,0,0};

static void box(const canvas_t *ui, uint8_t left, uint8_t top, uint8_t right, uint8_t bottom, ink_t fill) {
    qp_rect(ui->tile, left, top, right, bottom, fill.h, fill.s, fill.v, true);
}

enum { ROUND_TOP = 1, ROUND_BOTTOM = 2, ROUND_ALL = ROUND_TOP | ROUND_BOTTOM };

static void rounded_box(const canvas_t *ui, uint8_t l, uint8_t t, uint8_t r, uint8_t b, uint8_t corners, ink_t fill) {
    int top = t, bottom = b;
    if (corners & ROUND_TOP) {
        box(ui, l + 3, t, r - 3, t, fill);
        box(ui, l + 1, t + 1, r - 1, t + 2, fill);
        top += 3;
    }
    if (corners & ROUND_BOTTOM) {
        box(ui, l + 3, b, r - 3, b, fill);
        box(ui, l + 1, b - 2, r - 1, b - 1, fill);
        bottom -= 3;
    }
    if (top <= bottom) box(ui, l, top, r, bottom, fill);
}

static void draw_scaled_icon(const canvas_t *ui, uint8_t x, uint8_t y, const uint16_t *icon, ink_t color, uint8_t scale) {
    for (uint8_t row = 0; row < 12; ++row) {
        for (uint8_t col = 0; col < 12;) {
            uint8_t start = col;
            while (col < 12 && (icon[row] & (0x800u >> col))) ++col;
            if (col > start) box(ui, x + start * scale, y + row * scale, x + col * scale - 1, y + (row + 1) * scale - 1, color);
            else ++col;
        }
    }
}

static void draw_icon(const canvas_t *ui, uint8_t x, uint8_t y, const uint16_t *icon, ink_t color) {
    draw_scaled_icon(ui, x, y, icon, color, 1);
}

static void text(const canvas_t *ui, painter_font_handle_t font, uint8_t x, uint8_t y, const char *s, ink_t fg, ink_t bg) {
    qp_drawtext_recolor(ui->tile, x, y, font, s, fg.h, fg.s, fg.v, bg.h, bg.s, bg.v);
}

static void center(const canvas_t *ui, painter_font_handle_t font, uint8_t y, const char *s, ink_t fg, ink_t bg) {
    uint16_t width = qp_textwidth(font, s);
    if (width <= SCREEN_WIDTH) text(ui, font, (SCREEN_WIDTH - width) / 2, y, s, fg, bg);
}

static void clear_tile(const canvas_t *ui, uint8_t height) {
    box(ui, 0, 0, SCREEN_WIDTH - 1, height - 1, ui->palette->background);
}

// The tile stays in RAM until its final slice is sent. Only finished pixels
// reach the panel, and the keyboard task runs between separate SPI slices.
static void stage_tile(uint8_t y, uint8_t height) {
    tile_transfer.top = y;
    tile_transfer.height = height;
    tile_transfer.sent = 0;
}

typedef struct {
    uint8_t connection, slot, battery, flags, effect, speed;
    hsv_t rgb;
    enum charge_state charge;
    char title[8], date[8];
} home_t;

enum { MAC = 1, CAPS = 2, WIN_LOCK = 4, RGB_ON = 8, NOW_PLAYING = 16, PLAYING = 32, LINKED = 64 };

static home_t home_state(bool mac, uint8_t connection, bool media) {
    bool wireless_link = connection && ch582_is_connected();
    led_t leds = {.raw = connection ? (wireless_link ? ch582_get_host_leds() : 0) : host_keyboard_leds()};
    home_t home = {
        .connection = connection,
        .slot = connection == 1 ? ch582_get_target_slot() : 0,
        .battery = ch582_get_battery(),
        .charge = charge_state,
        .effect = rgb_matrix_get_mode(),
        .speed = rgb_matrix_get_speed(),
        .rgb = rgb_matrix_get_hsv(),
        .flags = (mac ? MAC : 0) | (leds.caps_lock ? CAPS : 0) |
                 (keymap_config.no_gui ? WIN_LOCK : 0) |
                 (rgb_matrix_is_enabled() && !rgb_matrix_get_suspend_state() ? RGB_ON : 0) |
                 (media ? NOW_PLAYING : 0) | (media && media_playing() ? PLAYING : 0) |
                 (!connection || wireless_link ? LINKED : 0),
        .title = "AK650",
    };
    rtc_time_t time;
    if (rtc_get_time(&time)) {
        snprintf(home.title, sizeof(home.title), "%02u:%02u", time.hours, time.minutes);
        snprintf(home.date, sizeof(home.date), "%02u/%02u", time.month, time.day);
    }
    return home;
}

static void draw_header(canvas_t *ui, const home_t *home) {
    clear_tile(ui, HEADER_HEIGHT);
    if (view == HOME) {
        const uint16_t *link = home->connection == 1 ? icon_bt : home->connection == 2 ? icon_radio : icon_usb;
        ink_t link_color = home->flags & LINKED ? ui->accent : ui->palette->muted;
        draw_icon(ui, 4, 7, link, link_color);
        if (home->slot >= 1 && home->slot <= 3) {
            char slot[] = {'0' + home->slot, 0};
            text(ui, ui->small, 17, 2, slot, link_color, ui->palette->background);
        }
        draw_icon(ui, 99, 7, screen_interaction ? icon_monitor : icon_volume, ui->accent);
        draw_icon(ui, 113, 7, home->flags & MAC ? icon_mac : icon_windows, ui->palette->foreground);
        static const translation_t titles[PAGE_COUNT] = {
            {"Home", "主页"}, {"Calc", "计算器"}, {"Light", "亮度"}, {"RGB", "灯光"},
            {"Battery", "电池"}, {"AK650", "AK650"}, {"Setup", "设置"}, {"Stats", "监控"}, {"Sky", "天气"}, {"Lyrics", "歌词"}, {"Net", "网速"}, {"Focus", "番茄钟"},
        };
        center(ui, ui->small, 2, translated(titles[screen_interaction ? page : PAGE_HOME]),
               ui->palette->foreground, ui->palette->background);
    } else {
        const char *title = view == MENU ? tr("SETTINGS", "设置") : translated(settings[selected]);
        center(ui, ui->small, 2, title, ui->palette->foreground, ui->palette->background);
    }
    box(ui, 6, 25, CONTENT_RIGHT, 25, ui->palette->rule);
    box(ui, 6, 25, 24, 26, ui->accent);
    stage_tile(0, HEADER_HEIGHT);
}

static void draw_footer(canvas_t *ui, uint8_t y, const char *hint) {
    uint8_t height = SCREEN_HEIGHT - y;
    clear_tile(ui, height);
    center(ui, ui->small, 0, hint, ui->palette->muted, ui->palette->background);
    stage_tile(y, height);
}

static void draw_media_line(const canvas_t *ui, uint8_t index) {
    char line[12];
    snprintf(line, sizeof(line), "%.11s", media_line(index));
    center(ui, ui->small, index ? 0 : 8, line, index ? ui->palette->muted : ui->palette->foreground, ui->palette->card);
}

enum { BAND_HEADER = 1, BAND_FIRST = 2, BAND_SECOND = 4, BAND_THIRD = 8, BAND_FOOTER = 16, BAND_PROGRESS = 32 };
#define PAGE_BANDS (BAND_HEADER | BAND_FIRST | BAND_SECOND | BAND_THIRD | BAND_FOOTER)
#define MENU_ITEM_BANDS (BAND_FIRST | BAND_SECOND | BAND_THIRD)

static void draw_navigation(canvas_t *ui) {
    clear_tile(ui, SCREEN_HEIGHT - FOOTER_Y);
    if (screen_interaction && page_detail) {
        draw_icon(ui, SCREEN_WIDTH / 2 - 27, 4, icon_back, ui->accent);
        text(ui, ui->tiny, SCREEN_WIDTH / 2 - 8, 2, "Back", ui->accent, ui->palette->background);
    } else if (screen_interaction) {
        for (uint8_t i = 0; i < PAGE_COUNT; ++i) {
            uint8_t x = 9 + (SCREEN_WIDTH - 18) * i / (PAGE_COUNT - 1);
            ink_t color = i == page ? ui->accent : ui->palette->rule;
            if (i == page) box(ui, x - 4, 8, x + 4, 12, color);
            else qp_circle(ui->tile, x, 10, 2, color.h, color.s, color.v, true);
        }
    }
    stage_tile(FOOTER_Y, SCREEN_HEIGHT - FOOTER_Y);
}

static void center_in(canvas_t *ui, painter_font_handle_t font, uint8_t x, uint8_t width, uint8_t y,
                      const char *label, ink_t color, ink_t background) {
    uint16_t pixels = qp_textwidth(font, label);
    if (pixels <= width) text(ui, font, x + (width - pixels) / 2, y, label, color, background);
}

static void gauge(canvas_t *ui, uint8_t x, uint8_t y, uint8_t width, uint8_t percent, ink_t color) {
    const uint8_t segments = 10;
    uint8_t lit = (percent + 9) / 10;
    for (uint8_t i = 0; i < segments; ++i) {
        uint8_t left = x + i * width / segments;
        uint8_t right = x + (i + 1) * width / segments - 2;
        box(ui, left, y, right, y + 2, i < lit ? color : ui->palette->rule);
    }
}

static ink_t battery_tint(const canvas_t *ui, const home_t *home) {
    if (home->charge == CHARGING) return (ink_t){27, 232, ui->accent.v};
    if (home->charge == CHARGE_COMPLETE) return (ink_t){91, 220, ui->accent.v};
    return ui->accent;
}

static void draw_home(canvas_t *ui, const home_t *home, uint8_t progress, uint8_t band) {
    bool media = home->flags & NOW_PLAYING;
    switch (band) {
        case BAND_HEADER: draw_header(ui, home); break;
        case BAND_FIRST:
            clear_tile(ui, TILE_HEIGHT);
            rounded_box(ui, 6, 2, CONTENT_RIGHT, TILE_HEIGHT - 1, ROUND_TOP, ui->palette->card);
            if (media) draw_media_line(ui, 0);
            else center(ui, ui->large, 1, home->title, ui->palette->foreground, ui->palette->card);
            stage_tile(HERO_Y, TILE_HEIGHT);
            break;
        case BAND_SECOND: {
            clear_tile(ui, STATUS_Y - DETAIL_Y);
            rounded_box(ui, 6, 0, CONTENT_RIGHT, STATUS_Y - DETAIL_Y - 1, ROUND_BOTTOM, ui->palette->card);
            if (media) {
                draw_media_line(ui, 1);
            } else {
                char value[8] = "--";
                if (home->battery <= 100) snprintf(value, sizeof(value), "%u%%", home->battery);
                center_in(ui, ui->small, 7, 64, 0, home->date[0] ? home->date : "VIA", ui->palette->muted, ui->palette->card);
                center_in(ui, ui->small, 72, 48, 0, value, battery_tint(ui, home), ui->palette->card);
            }
            stage_tile(DETAIL_Y, STATUS_Y - DETAIL_Y);
            break;
        }
        case BAND_PROGRESS:
            clear_tile(ui, 3);
            rounded_box(ui, 6, 0, CONTENT_RIGHT, 2, ROUND_BOTTOM, ui->palette->card);
            if (progress != UINT8_MAX) {
                box(ui, 14, 0, 113, 2, ui->palette->rule);
                if (progress) box(ui, 14, 0, 13 + progress, 2, home->flags & PLAYING ? ui->accent : ui->palette->muted);
            }
            stage_tile(STATUS_Y - 3, 3);
            break;
        case BAND_THIRD:
            clear_tile(ui, FOOTER_Y - STATUS_Y);
            for (uint8_t x = 6; x < 90; x += 40) rounded_box(ui, x, 2, x + 35, 19, ROUND_ALL, ui->palette->card);
            draw_icon(ui, 18, 5, home->flags & CAPS ? icon_caps : icon_lower, home->flags & CAPS ? ui->accent : ui->palette->muted);
            draw_icon(ui, 58, 5, home->flags & RGB_ON ? icon_light : icon_power, home->flags & RGB_ON ? ui->accent : ui->palette->muted);
            draw_icon(ui, 98, 5, home->flags & WIN_LOCK ? icon_lock : icon_unlock, home->flags & WIN_LOCK ? ui->accent : ui->palette->muted);
            stage_tile(STATUS_Y, FOOTER_Y - STATUS_Y);
            break;
        case BAND_FOOTER: draw_navigation(ui); break;
    }
}

static void compact_number(canvas_t *ui, uint8_t right, uint8_t y, const char *value, ink_t color) {
    static const uint8_t glyphs[][5] = {
        {7,5,5,5,7}, {2,6,2,2,7}, {7,1,7,4,7}, {7,1,7,1,7}, {5,5,7,1,1},
        {7,4,7,1,7}, {7,4,7,5,7}, {7,1,1,1,1}, {7,5,7,5,7}, {7,5,7,1,7},
        {0,0,0,0,2}, {0,0,7,0,0}, {1,1,2,4,4},
    };
    uint8_t x = right - 8 * strlen(value);
    for (const char *c = value; *c; ++c, x += 8) {
        uint8_t glyph = *c == '.' ? 10 : *c == '-' ? 11 : *c == '/' ? 12 : *c - '0';
        for (uint8_t row = 0; row < 5; ++row) {
            for (uint8_t col = 0; col < 3; ++col) {
                if (glyphs[glyph][row] & (4 >> col)) box(ui, x + 2 * col, y + 2 * row, x + 2 * col + 1, y + 2 * row + 1, color);
            }
        }
    }
}

static void draw_calculator(canvas_t *ui, uint8_t band) {
    if (band == BAND_FIRST) {
        char expression[sizeof(calculator.expression) + 3];
        const char *tail = calculator.expression;
        uint16_t width;
        do {
            snprintf(expression, sizeof(expression), "%s%s%s",
                     tail == calculator.expression ? "" : "...", tail, calculator.evaluated ? "=" : "");
            width = qp_textwidth(ui->small, expression);
        } while (width > SCREEN_WIDTH - 20 && *tail++);
        rounded_box(ui, 8, 1, CONTENT_RIGHT, TALL_DETAIL_Y - HERO_Y - 1, ROUND_TOP, ui->palette->card);
        text(ui, ui->small, CONTENT_RIGHT - 8 - width, 1, expression, ui->palette->muted, ui->palette->card);
    } else if (band == BAND_SECOND) {
        box(ui, 8, 0, CONTENT_RIGHT, TILE_HEIGHT - 1, ui->palette->card);
        const char *result = calculator.evaluated ? calculator.result : calculator.length ? "" : "0";
        painter_font_handle_t font = ui->large;
        if (calculator.error) {
            result = tr("Error", "错误");
            if (!english) font = ui->small;
        }
        uint16_t width = qp_textwidth(font, result);
        if (!calculator.error && width > SCREEN_WIDTH - 20) {
            compact_number(ui, CONTENT_RIGHT - 2, 11, result, ui->accent);
        } else {
            text(ui, font, CONTENT_RIGHT - 5 - width, 1, result, ui->accent, ui->palette->card);
        }
    } else {
        rounded_box(ui, 8, 0, CONTENT_RIGHT, FOOTER_Y - STATUS_Y - 3, ROUND_BOTTOM, ui->palette->card);
        draw_icon(ui, 13, 5, icon_keypad, ui->accent);
        center_in(ui, ui->small, 26, 96, 0, "Enter = ", ui->palette->foreground, ui->palette->card);
    }
}

static ink_t control_fill(const canvas_t *ui, enum page_control target) {
    return target == control ? ui->selected : ui->palette->card;
}

static void draw_brightness(canvas_t *ui, uint8_t band) {
    ink_t host = control_fill(ui, FIRST_CONTROL);
    ink_t keyboard = control_fill(ui, SECOND_CONTROL);
    uint8_t percent = backlight * 100 / DISPLAY_BACKLIGHT_LEVELS;
    if (band == BAND_FIRST) {
        rounded_box(ui, 6, 2, 61, TILE_HEIGHT - 1, ROUND_TOP, host);
        rounded_box(ui, 66, 2, CONTENT_RIGHT, TILE_HEIGHT - 1, ROUND_TOP, keyboard);
        draw_scaled_icon(ui, 22, 6, icon_monitor, ui->accent, 2);
        draw_scaled_icon(ui, 82, 6, icon_light, ui->accent, 2);
    } else if (band == BAND_SECOND) {
        box(ui, 6, 0, 61, STATUS_Y - DETAIL_Y - 1, host);
        box(ui, 66, 0, CONTENT_RIGHT, STATUS_Y - DETAIL_Y - 1, keyboard);
        center_in(ui, ui->small, 6, 56, 0, tr("Host", "电脑"), ui->palette->foreground, host);
        center_in(ui, ui->small, 66, 56, 0, tr("Keys", "键盘"), ui->palette->foreground, keyboard);
    } else {
        rounded_box(ui, 6, 0, 61, 19, ROUND_BOTTOM, host);
        rounded_box(ui, 66, 0, CONTENT_RIGHT, 19, ROUND_BOTTOM, keyboard);
        center_in(ui, ui->small, 6, 56, 0, "-  +", ui->accent, host);
        gauge(ui, 73, 7, 42, percent, ui->accent);
    }
}

static void draw_rgb(canvas_t *ui, const home_t *home, uint8_t band) {
    static const uint16_t *const icons[] = {icon_light, NULL, icon_gear, icon_clock, icon_power};
    static const translation_t labels[] = {
        {"Brightness", "亮度"}, {"Color", "颜色"}, {"Effect", "灯效"}, {"Speed", "速度"}, {"Power", "开关"},
    };
    bool enabled = home->flags & RGB_ON;
    if (band == BAND_FIRST) {
        for (uint8_t i = 0; i < ARRAY_SIZE(icons); ++i) {
            uint8_t x = 7 + 23 * i;
            rounded_box(ui, x, 3, x + 21, 30, ROUND_ALL, control_fill(ui, FIRST_CONTROL + i));
            if (icons[i]) {
                ink_t tint = i == FIFTH_CONTROL - FIRST_CONTROL && !enabled ? ui->palette->muted : ui->accent;
                draw_icon(ui, x + 5, 11, icons[i], tint);
            } else {
                qp_circle(ui->tile, x + 11, 16, 5, home->rgb.h, home->rgb.s, 255, true);
            }
        }
    } else if (band == BAND_SECOND) {
        const char *label = control == BROWSE ? tr("RGB", "灯光") : translated(labels[control - FIRST_CONTROL]);
        center(ui, ui->small, 0, label, ui->palette->muted, ui->palette->background);
    } else if (control == FIRST_CONTROL || control == FOURTH_CONTROL) {
        uint8_t percent = control == FIRST_CONTROL ? (uint16_t)home->rgb.v * 100 / RGB_MATRIX_MAXIMUM_BRIGHTNESS :
                                                     (uint16_t)home->speed * 100 / UINT8_MAX;
        char value[8];
        snprintf(value, sizeof(value), "%u%%", percent);
        gauge(ui, 8, 8, 67, percent, ui->accent);
        center_in(ui, ui->small, 77, 47, 0, value, ui->palette->foreground, ui->palette->background);
    } else {
        const char *value;
        if (control == FIFTH_CONTROL || (control == BROWSE && !enabled)) {
            value = enabled ? tr("On", "开启") : tr("Off", "关闭");
        } else if (control == SECOND_CONTROL) {
            int8_t index = color_index();
            value = index < 0 ? tr("Custom", "自定义") : translated(colors[index].name);
        } else {
            int8_t index = effect_index();
            value = index < 0 ? tr("Custom", "自定义") : translated(effects[index].name);
        }
        center(ui, ui->small, 0, value, ui->accent, ui->palette->background);
    }
}

static void draw_battery(canvas_t *ui, const home_t *home, uint8_t band) {
    bool known = home->battery <= 100;
    if (band == BAND_FIRST) {
        rounded_box(ui, 8, 2, CONTENT_RIGHT, TILE_HEIGHT - 1, ROUND_TOP, ui->palette->card);
        char value[8] = "--";
        if (known) snprintf(value, sizeof(value), "%u%%", home->battery);
        center(ui, ui->large, 1, value, ui->palette->foreground, ui->palette->card);
    } else if (band == BAND_SECOND) {
        rounded_box(ui, 8, 0, CONTENT_RIGHT, STATUS_Y - DETAIL_Y - 1, ROUND_BOTTOM, ui->palette->card);
        gauge(ui, 15, 5, 98, known ? home->battery : 0, battery_tint(ui, home));
    } else {
        const char *state = home->charge == CHARGING ? tr("Charging", "充电中") :
                            home->charge == CHARGE_COMPLETE ? tr("Charged", "已充满") : tr("Battery", "电池供电");
        center(ui, ui->small, 0, state, battery_tint(ui, home), ui->palette->background);
    }
}

// ChibiOS linker boundaries account for static variables, reserved stacks, and the load image.
extern const uint8_t __ram0_base__, __ram0_end__, __heap_base__;
extern const uint8_t __flash0_base__, __flash0_end__, __flash0_free__;

static void storage_meter(canvas_t *ui, const char *label, uintptr_t used, uintptr_t total, bool decimal) {
    uint8_t height = STATUS_Y - DETAIL_Y;
    rounded_box(ui, 6, 0, CONTENT_RIGHT, height - 1, ROUND_ALL, ui->palette->card);
    text(ui, ui->small, 10, 0, label, ui->palette->muted, ui->palette->card);
    unsigned tenths = (used * 10 + 512) / 1024;
    char value[20];
    if (decimal) snprintf(value, sizeof(value), "%u.%u/%u", tenths / 10, tenths % 10, (unsigned)(total / 1024));
    else snprintf(value, sizeof(value), "%u/%u", (unsigned)((used + 512) / 1024), (unsigned)(total / 1024));
    compact_number(ui, 119, 4, value, ui->palette->foreground);
    gauge(ui, 13, height - 3, 102, MIN(100, used * 100 / total), ui->accent);
}

static void draw_device(canvas_t *ui, uint8_t band) {
    if (band == BAND_FIRST) {
        char version[18];
        snprintf(version, sizeof(version), "v%X.%X.%X KiB", DEVICE_VER >> 8, (DEVICE_VER >> 4) & 0xf, DEVICE_VER & 0xf);
        center(ui, ui->small, 0, "SN32F299F", ui->palette->foreground, ui->palette->background);
        center(ui, ui->small, 14, version, ui->accent, ui->palette->background);
    } else if (band == BAND_SECOND) {
        uintptr_t ram = (uintptr_t)&__ram0_base__;
        storage_meter(ui, "RAM", (uintptr_t)&__heap_base__ - ram, (uintptr_t)&__ram0_end__ - ram, true);
    } else {
        uintptr_t flash = (uintptr_t)&__flash0_base__;
        storage_meter(ui, "Flash", (uintptr_t)&__flash0_free__ - flash + WEAR_LEVELING_BACKING_SIZE, (uintptr_t)&__flash0_end__ - flash, false);
    }
}

static void draw_settings_entry(canvas_t *ui, uint8_t band) {
    if (band == BAND_FIRST) {
        rounded_box(ui, 6, 2, CONTENT_RIGHT, TILE_HEIGHT - 1, ROUND_TOP, ui->selected);
        draw_scaled_icon(ui, 52, 6, icon_gear, ui->accent, 2);
    } else if (band == BAND_SECOND) {
        rounded_box(ui, 6, 0, CONTENT_RIGHT, STATUS_Y - DETAIL_Y - 1, ROUND_BOTTOM, ui->selected);
        center(ui, ui->small, 0, tr("Click knob", "按下进入"), ui->palette->foreground, ui->selected);
    } else {
        draw_icon(ui, 19, 5, icon_monitor, ui->palette->muted);
        draw_icon(ui, 58, 5, icon_clock, ui->palette->muted);
        draw_icon(ui, 97, 5, icon_language, ui->palette->muted);
    }
}

static void metric(canvas_t *ui, uint8_t x, uint8_t width, const char *label, uint8_t value) {
        text(ui, ui->small, x, 0, label, ui->palette->foreground, ui->palette->background);
    char number[5] = "--";
    if (value <= 100) snprintf(number, sizeof(number), "%u", value);
    compact_number(ui, x + width, 4, number, ui->accent);
    gauge(ui, x + 3, 17, width - 6, value <= 100 ? value : 0, ui->accent);
}

static const uint16_t icon_net_down[] = {0x060,0x060,0x060,0x060,0x366,0x1fc,0x0f8,0x070,0x020,0,0x7fe,0};
static const uint16_t icon_net_up[] = {0x020,0x070,0x0f8,0x1fc,0x366,0x060,0x060,0x060,0x060,0,0x7fe,0};

static uint32_t history_peak(const uint32_t *values) {
    uint32_t peak = 1; for (uint8_t i = 0; i < 12; ++i) if (values[i] > peak) peak = values[i]; return peak;
}
static void speed_text(uint32_t speed, char *value, size_t size, const char **unit) {
    uint32_t scale = speed >= 1048576 ? 1048576 : speed >= 1024 ? 1024 : 1;
    *unit = scale == 1048576 ? "MB/s" : scale == 1024 ? "KB/s" : "B/s";
    if (scale > 1) snprintf(value, size, "%lu.%lu", (unsigned long)(speed / scale), (unsigned long)((uint64_t)speed * 10 / scale % 10));
    else snprintf(value, size, "%lu", (unsigned long)speed);
}
static void trend(canvas_t *ui, const uint32_t *values, uint8_t x, uint8_t y, uint8_t width, uint8_t height, ink_t color) {
    uint32_t peak = history_peak(values); uint8_t step = width / 12;
    for (uint8_t i = 0; i < 12; ++i) {
        uint8_t h = (uint64_t)values[i] * (height - 1) / peak + 1;
        box(ui, x + step * i, y + height - h, x + step * i + (step > 1 ? step - 2 : 0), y + height - 1, color);
    }
}
static void network_cards(canvas_t *ui, uint8_t band, bool detail) {
    bool fresh = companion_alive(companion.network_time, 5000) && companion.network_ready;
    ink_t upload = {(uint8_t)(ui->accent.h + 55), ui->accent.s, ui->accent.v};
    if (detail && (band == BAND_FIRST || band == BAND_SECOND)) {
        bool rx = band == BAND_FIRST; const uint32_t *values = rx ? companion.rx_history : companion.tx_history;
        text(ui, ui->tiny, 8, 0, rx ? "DOWNLOAD / 12 samples" : "UPLOAD / 12 samples", rx ? ui->accent : upload, ui->palette->background);
        trend(ui, values, 8, 15, SCREEN_WIDTH - 16, rx ? 17 : 7, rx ? ui->accent : upload);
        return;
    }
    for (uint8_t i = 0; i < 2; ++i) {
        uint8_t x = i ? SCREEN_WIDTH / 2 + 3 : 6, width = (SCREEN_WIDTH - 18) / 2;
        uint32_t speed = i ? companion.upload : companion.download;
        const uint32_t *values = i ? companion.tx_history : companion.rx_history;
        ink_t color = i ? upload : ui->accent; char value[20]; const char *unit;
        speed_text(speed, value, sizeof(value), &unit);
        if (!fresh) strcpy(value, "--");
        if (band == BAND_FIRST) {
            rounded_box(ui, x, 0, x + width - 1, TILE_HEIGHT - 1, ROUND_TOP, ui->palette->card);
            draw_icon(ui, x + 5, 0, i ? icon_net_up : icon_net_down, color);
            text(ui, ui->tiny, x + 21, 0, SCREEN_WIDTH > 128 ? (i ? "UPLOAD" : "DOWNLOAD") : (i ? "TX" : "RX"), color, ui->palette->card);
            painter_font_handle_t font = qp_textwidth(ui->small, value) <= width - 8 ? ui->small : ui->tiny;
            center_in(ui, font, x + 3, width - 6, 12, value, ui->palette->foreground, ui->palette->card);
        } else if (band == BAND_SECOND) {
            box(ui, x, 0, x + width - 1, STATUS_Y - DETAIL_Y - 1, ui->palette->card);
            center_in(ui, ui->tiny, x + 3, width - 6, 0, fresh ? unit : "Offline", color, ui->palette->card);
            trend(ui, values, x + 6, 15, width - 12, 6, color);
        } else {
            rounded_box(ui, x, 0, x + width - 1, FOOTER_Y - STATUS_Y - 3, ROUND_BOTTOM, ui->palette->card);
            speed_text(history_peak(values), value, sizeof(value), &unit);
            char peak[28]; snprintf(peak, sizeof(peak), "P %s%c", value, *unit == 'M' ? 'M' : *unit == 'K' ? 'K' : 'B');
            center_in(ui, ui->tiny, x + 2, width - 4, 3, fresh ? peak : "--", color, ui->palette->card);
        }
    }
}
static void monitor_details(canvas_t *ui, uint8_t band) {
    if (band == BAND_FIRST || band == BAND_SECOND) {
        bool cpu = band == BAND_FIRST; uint32_t values[12];
        const uint8_t *history = cpu ? companion.cpu_history : companion.ram_history;
        for (uint8_t i = 0; i < 12; ++i) values[i] = history[i] <= 100 ? history[i] : 0;
        text(ui, ui->tiny, 8, 0, cpu ? "CPU / recent samples" : "RAM / recent samples", ui->accent, ui->palette->background);
        trend(ui, values, 8, 15, SCREEN_WIDTH - 16, cpu ? 17 : 7, ui->accent);
    } else {
        uint8_t cpu = 0, ram = 0;
        for (uint8_t i = 0; i < 12; ++i) { if (companion.cpu_history[i] <= 100 && companion.cpu_history[i] > cpu) cpu = companion.cpu_history[i]; if (companion.ram_history[i] <= 100 && companion.ram_history[i] > ram) ram = companion.ram_history[i]; }
        char value[32]; snprintf(value, sizeof(value), "Peak CPU %u RAM %u", cpu, ram);
        center(ui, ui->tiny, 3, value, ui->palette->muted, ui->palette->background);
    }
}
static void weather_details(canvas_t *ui, uint8_t band) {
    for (uint8_t i = 0; i < 2; ++i) {
        uint8_t x = i ? SCREEN_WIDTH / 2 + 3 : 6, width = (SCREEN_WIDTH - 18) / 2;
        char value[20] = "--";
        if (band == BAND_FIRST) {
            rounded_box(ui, x, 0, x + width - 1, TILE_HEIGHT - 1, ROUND_ALL, ui->palette->card);
            center_in(ui, ui->tiny, x, width, 0, i ? "MAX UV" : "RAIN", ui->palette->muted, ui->palette->card);
            if (i && companion.uv != 255) snprintf(value, sizeof(value), "%u.%u", companion.uv / 10, companion.uv % 10);
            if (!i && companion.rain <= 100) snprintf(value, sizeof(value), "%u%%", companion.rain);
        } else if (band == BAND_SECOND) {
            rounded_box(ui, x, 1, x + width - 1, STATUS_Y - DETAIL_Y - 1, ROUND_TOP, ui->palette->card);
            center_in(ui, ui->tiny, x, width, 2, i ? "PM2.5" : "US AQI", ui->palette->muted, ui->palette->card); continue;
        } else {
            rounded_box(ui, x, 0, x + width - 1, FOOTER_Y - STATUS_Y - 3, ROUND_BOTTOM, ui->palette->card);
            if (i && companion.pm25 != 65535) snprintf(value, sizeof(value), "%u.%u", companion.pm25 / 10, companion.pm25 % 10);
            if (!i && companion.aqi != 65535) snprintf(value, sizeof(value), "%u", companion.aqi);
        }
        if (!companion_alive(companion.weather_time, 3600000)) strcpy(value, "--");
        painter_font_handle_t font = qp_textwidth(ui->small, value) <= width - 8 ? ui->small : ui->tiny;
        center_in(ui, font, x + 3, width - 6, band == BAND_FIRST ? 12 : 0, value, ui->accent, ui->palette->card);
    }
}

static void draw_companion_page(canvas_t *ui, enum dashboard_page current, uint8_t band) {
    if (current == PAGE_NETWORK) {
        network_cards(ui, band, page_detail);
    } else if (current == PAGE_TIMER) {
        uint32_t remaining = companion_timer_remaining();
        if (band == BAND_FIRST) {
            char value[20]; snprintf(value, sizeof(value), "%02lu:%02lu", (unsigned long)(remaining / 60), (unsigned long)(remaining % 60));
            center(ui, ui->large, 0, value, ui->accent, ui->palette->background);
        } else if (band == BAND_SECOND) {
            uint8_t percent = companion.timer_duration ? 100 - (uint64_t)remaining * 100 / companion.timer_duration : 0;
            gauge(ui, 14, 3, SCREEN_WIDTH - 28, percent, ui->accent);
        } else {
            const char *label = !remaining && companion.timer_state ? "Done" : companion.timer_state == 2 ? "Paused" : companion.timer_rest ? "Break" : "Focus";
            center(ui, ui->small, 0, label, ui->palette->foreground, ui->palette->background);
        }
    } else if (current == PAGE_MONITOR) {
        if (page_detail) { monitor_details(ui, band); return; }
        bool fresh = companion_alive(companion.monitor_time, 10000);
        uint8_t width = SCREEN_WIDTH / 2 - 10;
        if (band == BAND_FIRST) {
            metric(ui, 6, width, "CPU", fresh ? companion.cpu : 255);
            metric(ui, SCREEN_WIDTH / 2 + 2, width, "RAM", fresh ? companion.memory : 255);
        } else if (band == BAND_SECOND) {
            // This strip is 22 px high; gauges share its bottom three rows.
            metric(ui, 6, width, "GPU", fresh ? companion.gpu : 255);
            metric(ui, SCREEN_WIDTH / 2 + 2, width, "DSK", fresh ? companion.disk : 255);
        } else {
            center(ui, ui->small, 0, fresh ? tr("LIVE", "实时监控") : tr("Offline", "等待主机"),
                   ui->accent, ui->palette->background);
        }
    } else if (current == PAGE_WEATHER) {
        if (page_detail) { weather_details(ui, band); return; }
        bool fresh = companion_alive(companion.weather_time, 3600000);
        uint8_t code = companion.weather_code;
        const uint16_t *icon = code == 0 ? icon_light : code <= 3 ? icon_cloud :
            code < 50 ? icon_fog : code < 70 || (code >= 80 && code < 85) ? icon_rain : code < 95 ? icon_snow : icon_storm;
        if (band == BAND_FIRST) {
            rounded_box(ui, 6, 1, SCREEN_WIDTH - 7, TILE_HEIGHT - 1, ROUND_TOP, ui->palette->card);
            draw_scaled_icon(ui, 13, 6, icon, fresh ? ui->accent : ui->palette->muted, 2);
            char value[16] = "--";
            int t = companion.temperature;
            if (fresh) snprintf(value, sizeof(value), "%s%d.%d", t < 0 ? "-" : "", abs(t) / 10, abs(t) % 10);
            if (SCREEN_WIDTH > 128) center_in(ui, ui->large, 50, SCREEN_WIDTH - 86, 0, value, ui->accent, ui->palette->card);
            else center_in(ui, ui->small, 42, 68, 4, value, ui->accent, ui->palette->card);
            text(ui, ui->small, SCREEN_WIDTH - 24, 3, "C", ui->palette->muted, ui->palette->card);
        } else if (band == BAND_SECOND) {
            rounded_box(ui, 6, 0, SCREEN_WIDTH - 7, STATUS_Y - DETAIL_Y - 1, ROUND_BOTTOM, ui->palette->card);
            char details[32];
            if (companion.minimum != 32767 && companion.maximum != 32767) snprintf(details, sizeof(details), "LOW %d  /  HIGH %d C", companion.minimum / 10, companion.maximum / 10);
            else strcpy(details, "LOW --  /  HIGH -- C");
            center(ui, ui->tiny, 3, fresh ? details : "Waiting for weather", ui->palette->foreground, ui->palette->card);
        } else {
            char value[32]; snprintf(value, sizeof(value), "RH %u%%   %02u:%02u", companion.humidity, companion.weather_hour, companion.weather_minute);
            draw_icon(ui, 7, 2, icon_drop, ui->accent);
            center_in(ui, ui->tiny, 23, SCREEN_WIDTH - 31, 3, fresh ? value : "Offline", ui->palette->muted, ui->palette->background);
        }
    } else {
        bool fresh = companion_alive(companion.lyric_time, 15000);
        if (fresh && (band == BAND_FIRST || band == BAND_SECOND)) {
            const uint8_t *bits = band == BAND_FIRST ? companion.title : companion.bitmap;
            uint8_t height = band == BAND_FIRST ? 20 : COMPANION_LYRIC_HEIGHT;
            uint8_t top = band == BAND_FIRST ? 1 : 7;
            ink_t color = band == BAND_FIRST ? ui->palette->muted : ui->palette->foreground;
            for (uint8_t y = 0; y < height; ++y) {
                for (uint8_t x = 0; x < SCREEN_WIDTH; ++x) {
                    uint16_t bit = y * SCREEN_WIDTH + x;
                    if (bits[bit / 8] & (0x80 >> (bit % 8))) box(ui, x, y + top, x, y + top, color);
                }
            }
        } else if (!fresh && band == BAND_FIRST) {
            draw_icon(ui, SCREEN_WIDTH / 2 - 6, 5, icon_note, ui->accent);
        } else if (!fresh && band == BAND_SECOND) {
            center(ui, ui->small, 6, tr("Waiting", "等待主机"), ui->palette->muted, ui->palette->background);
        }
        if (band == BAND_THIRD) {
            if (fresh) for (uint8_t y = 0; y < 18; ++y) for (uint8_t x = 0; x < SCREEN_WIDTH - 20; ++x) {
                uint16_t bit = y * SCREEN_WIDTH + x;
                if (companion.artist[bit / 8] & (0x80 >> (bit % 8))) box(ui, x, y, x, y, ui->palette->muted);
            }
            draw_icon(ui, SCREEN_WIDTH - 16, 2, fresh && companion.playing ? icon_play : icon_pause, ui->accent);
            uint8_t y = FOOTER_Y - STATUS_Y - 4, width = SCREEN_WIDTH - 16;
            box(ui, 8, y, SCREEN_WIDTH - 9, y + 2, ui->palette->rule);
            uint8_t fill = fresh ? (uint32_t)companion.progress * width / 1000 : 0;
            if (fill) box(ui, 8, y, 7 + fill, y + 2, ui->accent);
        }
    }
}

static void draw_page(canvas_t *ui, const home_t *home, enum dashboard_page current, uint8_t band) {
    if (band == BAND_HEADER) {
        draw_header(ui, home);
        return;
    }
    if (band == BAND_FOOTER) {
        draw_navigation(ui);
        return;
    }
    uint8_t detail = (current == PAGE_CALC || current == PAGE_LYRICS) ? TALL_DETAIL_Y : DETAIL_Y;
    uint8_t top = band == BAND_FIRST ? HERO_Y : band == BAND_SECOND ? detail : STATUS_Y;
    uint8_t bottom = band == BAND_FIRST ? detail : band == BAND_SECOND ? STATUS_Y : FOOTER_Y;
    clear_tile(ui, bottom - top);
    switch (current) {
        case PAGE_CALC: draw_calculator(ui, band); break;
        case PAGE_BRIGHTNESS: draw_brightness(ui, band); break;
        case PAGE_RGB: draw_rgb(ui, home, band); break;
        case PAGE_BATTERY: draw_battery(ui, home, band); break;
        case PAGE_DEVICE: draw_device(ui, band); break;
        case PAGE_SETTINGS: draw_settings_entry(ui, band); break;
        case PAGE_MONITOR:
        case PAGE_WEATHER:
        case PAGE_NETWORK:
        case PAGE_TIMER:
        case PAGE_LYRICS: draw_companion_page(ui, current, band); break;
        default: break;
    }
    stage_tile(top, bottom - top);
}

static const char *setting_value(enum setting setting) {
    switch (setting) {
        case APPEARANCE: return translated(appearances[appearance]);
        case ACCENT: return translated(accents[accent_color].label);
        case SCREEN_TIMEOUT: return translated(screen_timeouts[screen_timeout].label);
        case LANGUAGE: return tr("English", "简体中文");
        case DEVELOPER: return tr("Bootloader", "进入刷机");
        default: return tr("Back to pages", "返回页面");
    }
}

static void draw_menu(canvas_t *ui, uint8_t band) {
    if (band == BAND_HEADER) {
        draw_header(ui, NULL);
        return;
    }
    if (band == BAND_FOOTER) {
        draw_footer(ui, FOOTER_Y, translated(settings[selected]));
        return;
    }
    if (band == BAND_THIRD) {
        uint8_t top = HERO_Y + 2 * TILE_HEIGHT;
        clear_tile(ui, FOOTER_Y - top);
        box(ui, 8, 7, CONTENT_RIGHT, 7, ui->palette->rule);
        stage_tile(top, FOOTER_Y - top);
        return;
    }
    static const uint16_t *const icons[MENU_COUNT] = {
        [APPEARANCE] = icon_monitor, [ACCENT] = icon_light, [SCREEN_TIMEOUT] = icon_clock,
        [LANGUAGE] = icon_language, [DEVELOPER] = icon_usb, [EXIT] = icon_back,
    };
    uint8_t row = band == BAND_FIRST ? 0 : 1;
    clear_tile(ui, TILE_HEIGHT);
    for (uint8_t col = 0; col < MENU_COLUMNS; ++col) {
        uint8_t item = row * MENU_COLUMNS + col;
        uint8_t x = 6 + 40 * col;
        bool focused = item == selected;
        ink_t fill = focused ? ui->selected : ui->palette->card;
        rounded_box(ui, x, 1, x + 35, TILE_HEIGHT - 1, ROUND_ALL, fill);
        draw_scaled_icon(ui, x + 6, 4, icons[item], focused ? ui->accent : ui->palette->muted, 2);
        if (focused) box(ui, x + 13, 29, x + 22, 30, ui->accent);
    }
    stage_tile(HERO_Y + row * TILE_HEIGHT, TILE_HEIGHT);
}

static void draw_edit(canvas_t *ui, uint8_t band) {
    if (band == BAND_HEADER) {
        draw_header(ui, NULL);
        return;
    }
    if (band == BAND_FOOTER) {
        draw_footer(ui, FOOTER_Y, confirming_boot() ? tr("HOLD FLASH", "长按确认") : tr("PRESS DONE", "按下完成"));
        return;
    }
    if (band == BAND_THIRD) {
        clear_tile(ui, FOOTER_Y - STATUS_Y);
        stage_tile(STATUS_Y, FOOTER_Y - STATUS_Y);
        return;
    }

    if (band == BAND_SECOND) {
        clear_tile(ui, STATUS_Y - DETAIL_Y);
        rounded_box(ui, 8, 0, CONTENT_RIGHT, 18, ROUND_BOTTOM, ui->palette->card);
        if (selected == ACCENT) {
            rounded_box(ui, SCREEN_WIDTH / 2 - 27, 4, SCREEN_WIDTH / 2 + 26, 12, ROUND_ALL,
                        (ink_t){accents[accent_color].hue, accents[accent_color].saturation, 240});
        } else if (selected == DEVELOPER) {
            center(ui, ui->small, 0, tr("TAP BACK", "短按返回"), ui->palette->muted, ui->palette->card);
        }
        stage_tile(DETAIL_Y, STATUS_Y - DETAIL_Y);
        return;
    }

    clear_tile(ui, TILE_HEIGHT);
    rounded_box(ui, 8, 2, CONTENT_RIGHT, TILE_HEIGHT - 1, ROUND_TOP, ui->palette->card);
    center(ui, ui->small, 9, setting_value(selected), ui->palette->foreground, ui->palette->card);
    stage_tile(HERO_Y, TILE_HEIGHT);
}

static struct {
    canvas_t ui;
    home_t home;
    enum view view;
    enum dashboard_page page;
    uint8_t pending, progress, selected, accent, appearance;
    companion_view_t companion_view;
    bool english, retry, screen_interaction;
} refresh;

static uint8_t home_changes(const home_t *home, uint8_t progress, bool media_changed) {
    const home_t *last = &refresh.home;
    uint8_t flags = home->flags ^ last->flags;
    bool playing = home->flags & NOW_PLAYING;
    uint8_t bands = 0;
    if (flags & (MAC | LINKED) || home->connection != last->connection || home->slot != last->slot) bands |= BAND_HEADER;
    if (flags & NOW_PLAYING || (playing ? media_changed : strcmp(home->title, last->title))) bands |= BAND_FIRST;
    if (flags & NOW_PLAYING || (playing ? media_changed : strcmp(home->date, last->date))) bands |= BAND_SECOND;
    if (playing && ((bands & BAND_SECOND) || (flags & PLAYING) || progress != refresh.progress)) bands |= BAND_PROGRESS;
    if (flags & (CAPS | WIN_LOCK | RGB_ON)) bands |= BAND_THIRD;
    if (!playing && (home->battery != last->battery || home->charge != last->charge)) bands |= BAND_SECOND;
    return bands;
}

static uint8_t page_changes(enum dashboard_page current, const home_t *home) {
    const home_t *last = &refresh.home;
    uint8_t flags = home->flags ^ last->flags;
    uint8_t bands = 0;
    if ((flags & (MAC | LINKED)) || home->connection != last->connection || home->slot != last->slot) bands |= BAND_HEADER;
    if (redraw && (current == PAGE_NETWORK || current == PAGE_WEATHER || current == PAGE_MONITOR)) bands |= MENU_ITEM_BANDS | BAND_FOOTER;
    if (redraw && current == PAGE_CALC) bands |= BAND_FIRST | BAND_SECOND;
    if (redraw && (current == PAGE_BRIGHTNESS || current == PAGE_RGB)) bands |= MENU_ITEM_BANDS;
    if (current == PAGE_BATTERY && home->battery != last->battery) bands |= BAND_FIRST | BAND_SECOND;
    if (current == PAGE_BATTERY && home->charge != last->charge) bands |= BAND_SECOND | BAND_THIRD;
    if (current == PAGE_RGB && ((flags & RGB_ON) || home->effect != last->effect ||
                             home->rgb.h != last->rgb.h || home->rgb.s != last->rgb.s ||
                             home->rgb.v != last->rgb.v || home->speed != last->speed)) {
        bands |= BAND_FIRST | BAND_THIRD;
    }
    return bands;
}

void display_render_ak650_dashboard(painter_device_t panel, painter_font_handle_t large, painter_font_handle_t small,
                                   bool mac, uint8_t connection, bool media, bool force) {
    static painter_device_t surface;
    static painter_font_handle_t chinese, tiny;
    if (!surface) {
        surface = qp_make_rgb565_surface(SCREEN_WIDTH, TILE_HEIGHT, tile_pixels);
        if (!surface || !qp_init(surface, QP_ROTATION_0)) {
            surface = NULL;
            return;
        }
        chinese = qp_load_font_mem(font_ak650_sc_16);
        tiny = qp_load_font_mem(font_online_ascii_10);
        force = true;
    }
    if (!large || !small || !chinese || !tiny) return;

    const palette_t *palette = &palettes[appearance];
    uint8_t hue = accents[accent_color].hue;
    refresh.ui = (canvas_t){
        .panel = panel, .tile = surface, .large = large, .small = english ? small : chinese, .tiny = tiny,
        .palette = palette,
        .accent = {hue, accents[accent_color].saturation, palette->accent_value},
        .selected = {hue, palette->selection_saturation, palette->selection_value},
    };
    enum dashboard_page current = screen_interaction ? page : PAGE_HOME;
    bool all = force || refresh.retry || refresh.view != view || refresh.english != english ||
               refresh.accent != accent_color || refresh.appearance != appearance ||
               refresh.page != current || refresh.screen_interaction != screen_interaction ||
               (view == EDIT && refresh.selected != selected);
    if (all) {
        refresh.pending = PAGE_BANDS;
        tile_transfer.height = 0;
    }
    if (view == MENU) {
        if (!all && selected != refresh.selected) {
            refresh.pending |= (BAND_FIRST << (selected / MENU_COLUMNS)) |
                               (BAND_FIRST << (refresh.selected / MENU_COLUMNS)) | BAND_FOOTER;
        }
    } else if (view == EDIT) {
        if (!all && redraw) {
            refresh.pending |= BAND_FIRST;
            if (selected == ACCENT) refresh.pending |= BAND_SECOND;
        }
    } else {
        home_t home = home_state(mac, connection, media);
        bool media_changed = media_take_dirty();
        uint8_t progress = UINT8_MAX;
        if (current == PAGE_HOME && media) {
            uint32_t duration = media_duration_ms();
            uint32_t elapsed = media_elapsed_ms();
            if (duration) progress = elapsed >= duration ? 100 : (uint64_t)elapsed * 100 / duration;
        }
        if (!media) refresh.pending &= ~BAND_PROGRESS;
        if (current == PAGE_HOME) {
            refresh.pending |= all ? (media ? BAND_PROGRESS : 0) : home_changes(&home, progress, media_changed);
        } else if (!all) {
            refresh.pending |= page_changes(current, &home);
        }
        refresh.home = home;
        refresh.progress = progress;
    }
    uint8_t companion_bands = companion_changed(&refresh.companion_view,
        view == HOME && current >= PAGE_MONITOR ? current - PAGE_MONITOR + 1 : 0);
    if (companion_bands & 1) refresh.pending |= BAND_FIRST;
    if (companion_bands & 2) refresh.pending |= BAND_SECOND;
    if (companion_bands & 4) refresh.pending |= BAND_THIRD;
    refresh.retry = false;
    redraw = false;
    refresh.view = view;
    refresh.page = current;
    refresh.screen_interaction = screen_interaction;
    refresh.selected = selected;
    refresh.english = english;
    refresh.accent = accent_color;
    refresh.appearance = appearance;
}

void display_send_ak650_slice(void) {
    if (redraw || !refresh.ui.tile) return;

    if (tile_transfer.height) {
        uint8_t rows = MIN(SPI_SLICE_ROWS, tile_transfer.height - tile_transfer.sent);
        uint8_t y = tile_transfer.top + tile_transfer.sent;
        painter_device_t panel = refresh.ui.panel;
        if (!qp_viewport(panel, 0, y, SCREEN_WIDTH - 1, y + rows - 1) ||
            !qp_pixdata(panel, tile_pixels + SCREEN_WIDTH * tile_transfer.sent, SCREEN_WIDTH * rows)) {
            refresh.retry = true;
            refresh.pending = 0;
            tile_transfer.height = 0;
            return;
        }
        tile_transfer.sent += rows;
        if (tile_transfer.sent == tile_transfer.height) tile_transfer.height = 0;
        return;
    }
    if (!refresh.pending) return;
    uint8_t pending = refresh.pending;
    if (refresh.view == MENU && (pending & MENU_ITEM_BANDS)) pending &= MENU_ITEM_BANDS;
    uint8_t band = pending & -pending;
    refresh.pending &= ~band;
    switch (refresh.view) {
        case HOME:
            if (refresh.page == PAGE_HOME) draw_home(&refresh.ui, &refresh.home, refresh.progress, band);
            else draw_page(&refresh.ui, &refresh.home, refresh.page, band);
            break;
        case MENU: draw_menu(&refresh.ui, band); break;
        case EDIT: draw_edit(&refresh.ui, band); break;
    }
}

bool display_ak650_needs_redraw(void) {
    return redraw;
}
