// SPDX-License-Identifier: GPL-2.0-or-later
#include "rs2_30.h"
#include "bluetooth/ch582f_ajazz.h"
#include "graphics/res/Iosevka-Medium-20.qff.h"
#include "graphics/res/Iosevka-Regular-30.qff.h"
#include "media/media.h"
#include "qp.h"
#include "qp_comms.h"
#include "qp_comms_spi.h"
#include "usb_main.h"

#define SCREEN_REFRESH_MS 40
#define BACKLIGHT_RAMP_MS 45
#define SCREEN_BACKLIGHT A16
#define SCREEN_DC D14
#define SCREEN_RESET A17
#define PANEL_SPI_FIFO_DEPTH 8u

static painter_device_t panel;
static painter_font_handle_t small_font;
static painter_font_handle_t large_font;
static bool drawing;
static bool illuminated;
static bool connection_changed;
static bool panel_io_failed;
static bool media_hidden;
static bool screen_enabled = true;
static uint32_t last_refresh;
static virtual_timer_t backlight_timer;
static uint8_t backlight_target = DISPLAY_BACKLIGHT_LEVELS;
static uint8_t backlight_level;
static uint32_t backlight_step_time;
static bool backlight_on_phase;

static bool panel_spi_init(painter_device_t device) {
    if (!qp_comms_spi_init(device)) return false;
    gpio_write_pin_low(SCREEN_DC);
    gpio_set_pin_output(SCREEN_DC);

    // Match the RS2 1.35 reset pulse and recovery at 0x7A66.
    gpio_write_pin_high(SCREEN_RESET);
    gpio_set_pin_output(SCREEN_RESET);
    wait_ms(20);
    gpio_write_pin_low(SCREEN_RESET);
    wait_ms(20);
    gpio_write_pin_high(SCREEN_RESET);
    wait_ms(150);
    return true;
}

static bool panel_spi_start(painter_device_t device) {
    if (!qp_comms_spi_start(device)) {
        panel_io_failed = true;
        return false;
    }
    SN_SPI0->IE = 0;
    return true;
}

static uint32_t panel_spi_write(const uint8_t *data, uint32_t size) {
    if (panel_io_failed) return 0;
    uint32_t queued = MIN(size, PANEL_SPI_FIFO_DEPTH);
    for (uint32_t index = 0; index < queued; ++index) SN_SPI0->DATA = data[index];

    // Refill only after draining a byte, so the RX FIFO can hold everything
    // in flight even if the matrix/PWM timer preempts this transfer.
    for (uint32_t received = 0; received < size; ++received) {
        uint32_t polls = SN32_HCLK / 1000;
        while (SN_SPI0->STAT_b.RX_EMPTY) {
            if (--polls == 0) {
                panel_io_failed = true;
                return received;
            }
        }
        (void)SN_SPI0->DATA;
        if (queued < size) SN_SPI0->DATA = data[queued++];
    }
    return size;
}

static bool panel_spi_command(painter_device_t device, uint8_t command) {
    gpio_write_pin_low(SCREEN_DC);
    return panel_spi_write(&command, 1) == 1;
}

static uint32_t panel_spi_data(painter_device_t device, const void *data, uint32_t size) {
    gpio_write_pin_high(SCREEN_DC);
    return panel_spi_write(data, size);
}

static bool panel_spi_sequence(painter_device_t device, const uint8_t *sequence, size_t size) {
    while (size >= 3) {
        uint8_t delay = sequence[1];
        uint8_t bytes = sequence[2];
        if (bytes > size - 3 || !panel_spi_command(device, sequence[0])) return false;
        if (bytes && panel_spi_data(device, sequence + 3, bytes) != bytes) return false;
        if (delay) wait_ms(delay);
        sequence += 3 + bytes;
        size -= 3 + bytes;
    }
    return size == 0;
}

static const painter_comms_with_command_vtable_t panel_spi_comms = {
    .base = {
        .comms_init = panel_spi_init,
        .comms_start = panel_spi_start,
        .comms_send = panel_spi_data,
        .comms_stop = qp_comms_spi_stop,
    },
    .send_command = panel_spi_command,
    .bulk_command_sequence = panel_spi_sequence,
};

bool qp_gc9107_init(painter_device_t device, painter_rotation_t rotation) {
    // RS2 1.35 panel settings at 0x7AAC, with the calibrated 90° MADCTL.
    static const uint8_t sequence[] = {
        0x11, 150, 0,
        0x36, 0, 1, 0x60,
        0x3A, 0, 1, 0x05,
        0x21, 0, 0,
        0xB2, 0, 5, 0x05, 0x05, 0x00, 0x33, 0x33,
        0xB7, 0, 1, 0x23,
        0xBB, 0, 1, 0x22,
        0xC0, 0, 1, 0x2C,
        0xC2, 0, 1, 0x01,
        0xC3, 0, 1, 0x13,
        0xC4, 0, 1, 0x20,
        0xC6, 0, 1, 0x0F,
        0xD0, 0, 2, 0xA4, 0xA1,
        0xD6, 0, 1, 0xA1,
        0xE0, 0, 14, 0x70, 0x06, 0x0C, 0x08, 0x09, 0x27, 0x2E, 0x34, 0x46, 0x37, 0x13, 0x13, 0x25, 0x2A,
        0xE1, 0, 14, 0x70, 0x04, 0x08, 0x09, 0x07, 0x03, 0x2C, 0x42, 0x42, 0x38, 0x14, 0x14, 0x27, 0x2C,
        0x21, 0, 0,
        0x29, 20, 0,
    };
    return rotation == QP_ROTATION_90 && qp_comms_bulk_command_sequence(device, sequence, sizeof(sequence));
}

static bool clear_panel(void) {
    return qp_rect(panel, 0, 0, RS2_PANEL_WIDTH - 1, RS2_PANEL_HEIGHT - 1, 0, 0, 0, true);
}

bool rs2_screen_blit_rows(painter_device_t device, uint8_t top, uint8_t rows, const uint16_t *pixels) {
    if (!qp_comms_start(device)) return false;
    const painter_driver_t *driver = (const painter_driver_t *)device;
    uint32_t bytes = (uint32_t)RS2_PANEL_WIDTH * rows * sizeof(*pixels);
    bool ok = driver->driver_vtable->viewport(device, 0, top, RS2_PANEL_WIDTH - 1, top + rows - 1) &&
              panel_spi_data(device, pixels, bytes) == bytes;
    qp_comms_stop(device);
    return ok;
}

static void backlight_tick(virtual_timer_t *timer, void *arg) {
    chSysLockFromISR();
    backlight_on_phase = !backlight_on_phase;
    gpio_write_pin(SCREEN_BACKLIGHT, backlight_on_phase);
    uint8_t slots = backlight_on_phase ? backlight_level : DISPLAY_BACKLIGHT_LEVELS - backlight_level;
    chVTSetI(timer, TIME_US2I(slots * 200u), backlight_tick, NULL);
    chSysUnlockFromISR();
}

static void set_light_locked(void) {
    if (chVTIsArmedI(&backlight_timer)) chVTResetI(&backlight_timer);
    backlight_on_phase = illuminated;
    gpio_write_pin(SCREEN_BACKLIGHT, backlight_on_phase);
    if (illuminated && backlight_level < DISPLAY_BACKLIGHT_LEVELS) {
        chVTSetI(&backlight_timer, TIME_US2I(backlight_level * 200u), backlight_tick, NULL);
    }
}

void display_set_backlight_level(uint8_t level) {
    chSysLock();
    backlight_target = MAX(1, MIN(level, DISPLAY_BACKLIGHT_LEVELS));
    chSysUnlock();
}

static void update_backlight(bool show) {
    if (!show && !illuminated) return;
    uint8_t next = 0;
    if (show) {
        next = backlight_target;
        if (backlight_level < next) {
            if (illuminated && timer_elapsed32(backlight_step_time) < BACKLIGHT_RAMP_MS) return;
            next = backlight_level + 1;
        }
    }
    if (next == backlight_level && show == illuminated) return;
    backlight_step_time = timer_read32();
    chSysLock();
    backlight_level = next;
    illuminated = show;
    set_light_locked();
    chSysUnlock();
}

void rs2_screen_prepare(void) {
    gpio_write_pin_low(SCREEN_BACKLIGHT);
    gpio_set_pin_output(SCREEN_BACKLIGHT);
    chVTObjectInit(&backlight_timer);
}

bool rs2_screen_init(void) {
    if (!panel) panel = qp_gc9107_make_spi_device(RS2_PANEL_HEIGHT, RS2_PANEL_WIDTH, B8, SCREEN_DC, SCREEN_RESET, 2, 3);
    if (!panel) return false;
    ((painter_driver_t *)panel)->comms_vtable = &panel_spi_comms.base;
    panel_io_failed = false;
    if (!qp_init(panel, QP_ROTATION_90)) return false;
    qp_set_viewport_offsets(panel, 40, 53);
    if (!clear_panel() || panel_io_failed) return false;
    if (!small_font) small_font = qp_load_font_mem(font_Iosevka_Medium_20);
    if (!large_font) large_font = qp_load_font_mem(font_Iosevka_Regular_30);
    return small_font && large_font;
}

void rs2_screen_connection_changed(void) {
    connection_changed = true;
}

void rs2_screen_toggle_media(void) {
    media_hidden = !media_hidden;
}

void rs2_screen_task(bool wired) {
    if (!panel || !small_font || !large_font) return;
    uint32_t idle_timeout = display_idle_timeout_ms();
    bool draw = screen_enabled && !(wired && USB_DRIVER.state == USB_SUSPENDED) &&
                (!idle_timeout || last_input_activity_elapsed() < idle_timeout);
    bool wake = draw && !drawing;
    drawing = draw;
    if (!draw) {
        update_backlight(false);
        return;
    }
    if (wake || connection_changed || rs2_dashboard_needs_redraw() ||
        timer_elapsed32(last_refresh) >= SCREEN_REFRESH_MS) {
        last_refresh = timer_read32();
        rs2_render_dashboard(panel, large_font, small_font, keymap_config.swap_lalt_lgui,
                             wired ? 0 : ch582_is_24g() ? 2 : 1, media_show() && !media_hidden,
                             wake || connection_changed);
        connection_changed = false;
    }
    rs2_send_dashboard_slice();
    if (panel_io_failed) {
        panel_io_failed = false;
        connection_changed = true;
        return;
    }
    // On wake, keep the LED off until the first dashboard is in panel RAM.
    update_backlight(illuminated || !rs2_dashboard_pending());
}

bool rs2_screen_media_enabled(void) { return !media_hidden; }
void rs2_screen_set_media(bool enabled) { media_hidden = !enabled; connection_changed = true; }
bool rs2_screen_enabled(void) { return screen_enabled; }
void rs2_screen_set_enabled(bool enabled) { screen_enabled = enabled; connection_changed = true; }
