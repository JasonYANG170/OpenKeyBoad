CUSTOM_MATRIX = lite
DEBOUNCE_TYPE = sym_defer_pk
SRC += matrix.c keyboard.c screen.c rgb.c dashboard.c calculator.c recovery.c fonts/ak650_sc_16.qff.c
EEPROM_DRIVER = wear_leveling
WEAR_LEVELING_DRIVER = embedded_flash

WIRELESS_DONOR := keyboards/a_jazz/ak820pro
BLUETOOTH_ENABLE = yes
BLUETOOTH_DRIVER = custom
VPATH += $(WIRELESS_DONOR)
SRC += bluetooth/ch582f_ajazz.c
USE_HAL_I2C_FALLBACK = yes
SRC += rtc/rtc.c media/media.c watchdog.c

QUANTUM_PAINTER_ENABLE = yes
QUANTUM_PAINTER_DRIVERS = gc9107_spi
QUANTUM_PAINTER_NEEDS_SURFACE = yes
SRC += graphics/res/Iosevka-Medium-20.qff.c
SRC += graphics/res/Iosevka-Regular-30.qff.c

SRC += companion.c
OPT_DEFS += -DCOMPANION_WIDTH=240
