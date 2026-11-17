// SPDX-License-Identifier: GPL-2.0-or-later
#include QMK_KEYBOARD_H
#include "ak650.h"

enum layers {
    WIN_BASE,
    WIN_FN,
    MAC_BASE,
    MAC_FN,
};

#define AK650_BASE(gui, alt, right_alt, fn) LAYOUT_67_ansi( \
    KC_ESC,  KC_1,    KC_2,    KC_3,    KC_4,    KC_5,    KC_6,    KC_7,    KC_8,    KC_9,    KC_0,    KC_MINS, KC_EQL,  KC_BSPC, KC_MUTE, \
    KC_TAB,  KC_Q,    KC_W,    KC_E,    KC_R,    KC_T,    KC_Y,    KC_U,    KC_I,    KC_O,    KC_P,    KC_LBRC, KC_RBRC, KC_BSLS, KC_DEL,  \
    KC_CAPS, KC_A,    KC_S,    KC_D,    KC_F,    KC_G,    KC_H,    KC_J,    KC_K,    KC_L,    KC_SCLN, KC_QUOT, KC_ENT,  KC_PGUP,          \
    KC_LSFT, KC_Z,    KC_X,    KC_C,    KC_V,    KC_B,    KC_N,    KC_M,    KC_COMM, KC_DOT,  KC_SLSH, KC_RSFT, KC_UP,   KC_PGDN,          \
    KC_LCTL, gui,     alt,                      KC_SPC,                    right_alt, MO(fn),                  KC_LEFT, KC_DOWN, KC_RGHT)

#define AK650_FN LAYOUT_67_ansi( \
    AK650_FN_ESC, KC_F1, KC_F2, KC_F3, KC_F4, KC_F5, KC_F6, KC_F7, KC_F8, KC_F9, KC_F10, KC_F11, KC_F12, _______, AK650_ENCODER, \
    _______, BT1,     BT2,     BT3,     BT24G,   BT_PAIR,  _______, _______, KC_PSCR, KC_SCRL, KC_PAUS, RM_SPDU, RM_SPDD, RM_NEXT, _______, \
    _______, _______, _______, _______, _______, _______, _______, KC_HOME, KC_END,  KC_DEL,  _______, _______, _______, _______,          \
    _______, _______, RM_TOGG, AK650_ZH, AK650_EN, _______, SCR_TOG, _______, _______, _______, _______, _______, RM_VALU, _______,         \
    _______, GU_TOGG, _______,                   AK650_RESET,                _______, _______,                  _______, RM_VALD, RM_HUEU)

const uint16_t PROGMEM keymaps[][MATRIX_ROWS][MATRIX_COLS] = {
    [WIN_BASE] = AK650_BASE(KC_LGUI, KC_LALT, KC_RALT, WIN_FN),
    [WIN_FN]   = AK650_FN,
    [MAC_BASE] = AK650_BASE(KC_LALT, KC_LGUI, KC_RGUI, MAC_FN),
    [MAC_FN]   = AK650_FN,
};

const uint16_t PROGMEM encoder_map[][NUM_ENCODERS][NUM_DIRECTIONS] = {
    [WIN_BASE] = {ENCODER_CCW_CW(KC_VOLD, KC_VOLU)},
    [WIN_FN]   = {ENCODER_CCW_CW(KC_VOLD, KC_VOLU)},
    [MAC_BASE] = {ENCODER_CCW_CW(KC_VOLD, KC_VOLU)},
    [MAC_FN]   = {ENCODER_CCW_CW(KC_VOLD, KC_VOLU)},
};

bool dip_switch_update_user(uint8_t index, bool active) {
    if (index == 0) {
        default_layer_set(1UL << (active ? WIN_BASE : MAC_BASE));
    }
    return true;
}
