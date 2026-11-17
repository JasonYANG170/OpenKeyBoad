// SPDX-License-Identifier: GPL-2.0-or-later
#include "rs2_30.h"
#include "rgb_matrix.h"
#include "rgb_matrix_drivers.h"

#define LED_ROWS 6
#define LED_COLS 19
#define STOCK_LED_COLS 21
#define COLOR_COUNT 3
#define PWM_CLOCK 2000000
#define PWM_PERIOD (RGB_MATRIX_MAXIMUM_BRIGHTNESS + 1)

static const uint8_t stock_led_index[] = {
#include "rgb-map.inc"
};
_Static_assert(ARRAY_SIZE(stock_led_index) == RGB_MATRIX_LED_COUNT, "RGB mapping count");

// The 1.35 image selects R rows, G rows and then B rows. Its 98 mapped
// keys occupy the first six rows and nineteen columns of each plane.
static const pin_t select_pins[COLOR_COUNT * LED_ROWS] = {
    A11, A8, D9, D12, D17, C11,
    B5, D8, D11, D16, C10, C13,
    B4, A9, D10, D13, D18, C12,
};

typedef struct { PWMDriver *driver; uint8_t channel; } pwm_column_t;
// Match register order from the original RS2 routine at 0x5B70, in
// MATRIX_COL_PINS order. CT16B1 covers A0..A7 and three C pins.
static const pwm_column_t columns[LED_COLS] = {
    {&PWMD1, 4}, {&PWMD1, 5}, {&PWMD1, 8}, {&PWMD2, 1}, {&PWMD2, 2}, {&PWMD2, 3},
    {&PWMD1, 6}, {&PWMD1, 7}, {&PWMD1, 9}, {&PWMD2, 0}, {&PWMD0, 0}, {&PWMD1, 10},
    {&PWMD0, 3}, {&PWMD0, 2}, {&PWMD0, 1},
    {&PWMD1, 0}, {&PWMD1, 1}, {&PWMD1, 2}, {&PWMD1, 3},
};

static rgb_t colors[RGB_MATRIX_LED_COUNT];
static uint8_t frames[2][COLOR_COUNT * LED_ROWS][LED_COLS];
static uint32_t lit_rows[2];
static uint8_t active_frame;
static uint8_t active_row;
static bool ready;
static volatile uint32_t sweeps;
static uint32_t pwm0_no_output;
static uint32_t pwm2_no_output;

static void blank_rows(void) {
    SN_GPIO0->BCLR = 0x0B00;
    SN_GPIO1->BCLR = 0x0030;
    SN_GPIO2->BCLR = 0x3C00;
    SN_GPIO3->BCLR = 0x73F00;
}

static void disconnect_columns(void) {
    SN_CT16B0->PWMCTRL = pwm0_no_output;
    SN_CT16B1->PWMIOENB = 0;
    SN_CT16B2->PWMCTRL = pwm2_no_output;
    PWMD0.enabled = 0;
    PWMD1.enabled = 0;
    PWMD2.enabled = 0;
}

static void apply_row(void) {
    bool lit = lit_rows[active_frame] & (1u << active_row);
    if (lit) {
        const uint8_t *row = frames[active_frame][active_row];
        for (uint8_t col = 0; col < LED_COLS; ++col) {
            // The preceding blanking step already disconnected every channel.
            if (row[col]) pwmEnableChannelI(columns[col].driver, columns[col].channel, row[col]);
        }
    }
    // Restart all three timers at the same edge, as on the AK650 PWM driver.
    pwm_lld_change_counter(&PWMD0, UINT16_MAX);
    pwm_lld_change_counter(&PWMD1, UINT16_MAX);
    pwm_lld_change_counter(&PWMD2, UINT16_MAX);
    if (lit) gpio_write_pin_high(select_pins[active_row]);
}

static void scan_tick(PWMDriver *driver) {
    chSysLockFromISR();
    blank_rows();
    disconnect_columns();
    SN_GPIO0->BCLR = 0xFF;
    SN_GPIO2->BCLR = 0x43FF;
    rs2_matrix_scan_pulse();

    if (++active_row == ARRAY_SIZE(select_pins)) {
        active_row = 0;
        ++sweeps;
    }
    apply_row();
    chSysUnlockFromISR();
}

uint32_t rs2_rgb_get_sweep_count(void) {
    return sweeps;
}

bool rs2_rgb_is_running(void) {
    return ready;
}

static void rgb_init(void) {
    blank_rows();
    for (uint8_t i = 0; i < ARRAY_SIZE(select_pins); ++i) gpio_set_pin_output(select_pins[i]);
}

void rs2_rgb_start(void) {
    static PWMConfig pwm0 = {.frequency = PWM_CLOCK, .period = PWM_PERIOD};
    static PWMConfig pwm1 = {.frequency = PWM_CLOCK, .period = PWM_PERIOD, .callback = scan_tick};
    static PWMConfig pwm2 = {.frequency = PWM_CLOCK, .period = PWM_PERIOD};

    for (uint8_t col = 0; col < LED_COLS; ++col) {
        const pwm_column_t *pwm = &columns[col];
        PWMConfig *config = pwm->driver == &PWMD0 ? &pwm0 : pwm->driver == &PWMD1 ? &pwm1 : &pwm2;
        config->channels[pwm->channel].mode = PWM_OUTPUT_ACTIVE_LOW;
    }
    // Original RS2 1.35 pin-function assignments at 0x0CCC.
    SN_PFPA->CT16B0 = 0x3302;
    SN_PFPA->CT16B1 = 0x0700;
    SN_PFPA->CT16B2 = 0x0001;
    pwmStart(&PWMD0, &pwm0);
    pwmStart(&PWMD1, &pwm1);
    pwmStart(&PWMD2, &pwm2);
    chSysLock();
    // CT16B0/B2 store the four channel output-enable bits in PWMCTRL.
    // Keep the active-low mode and the PWM enable bits when releasing the pins.
    pwm0_no_output = CT16_PWM_UNLOCK(SN_CT16B0->PWMCTRL & ~(0xFu << 20));
    pwm2_no_output = CT16_PWM_UNLOCK(SN_CT16B2->PWMCTRL & ~(0xFu << 20));
    disconnect_columns();
    ready = true;
    apply_row();
    pwmEnablePeriodicNotificationI(&PWMD1);
    chSysUnlock();
}

static void set_color(int index, uint8_t red, uint8_t green, uint8_t blue) {
    if (index >= 0 && index < RGB_MATRIX_LED_COUNT) colors[index] = (rgb_t){red, green, blue};
}

static void set_color_all(uint8_t red, uint8_t green, uint8_t blue) {
    for (uint8_t i = 0; i < RGB_MATRIX_LED_COUNT; ++i) set_color(i, red, green, blue);
}

static void flush(void) {
    uint8_t next = active_frame ^ 1;
    uint32_t rows = 0;
    memset(frames[next], 0, sizeof(frames[next]));
    for (uint8_t i = 0; i < RGB_MATRIX_LED_COUNT; ++i) {
        uint8_t row = stock_led_index[i] / STOCK_LED_COLS;
        uint8_t col = stock_led_index[i] % STOCK_LED_COLS;
        frames[next][row][col] = colors[i].r;
        frames[next][LED_ROWS + row][col] = colors[i].g;
        frames[next][2 * LED_ROWS + row][col] = colors[i].b;
        if (colors[i].r) rows |= 1u << row;
        if (colors[i].g) rows |= 1u << (LED_ROWS + row);
        if (colors[i].b) rows |= 1u << (2 * LED_ROWS + row);
    }
    lit_rows[next] = rows;
    chSysLock();
    active_frame = next;
    chSysUnlock();
}

const rgb_matrix_driver_t rgb_matrix_driver = {
    .init = rgb_init,
    .flush = flush,
    .set_color = set_color,
    .set_color_all = set_color_all,
};
