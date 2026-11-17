# Reuse the AK820 Pro panel driver and fonts.
AK820PRO_DIR := keyboards/a_jazz/ak820pro
DASHBOARD_BACKEND := qp
VPATH += $(AK820PRO_DIR)
SRC += ak820pro.c
include $(AK820PRO_DIR)/rules.mk

ENCODER_MAP_ENABLE = yes
DEBOUNCE_TYPE = sym_defer_pk
OPT_DEFS += -DAK820PRO_FLASH_HID_ENABLE=0
OPT_DEFS += -DAK650_DASHBOARD
SRC += keyboards/a_jazz/ak650/reference/dashboard.c
SRC += keyboards/a_jazz/ak650/reference/calculator.c
SRC += keyboards/a_jazz/ak650/reference/fonts/ak650_sc_16.qff.c
QUANTUM_PAINTER_NEEDS_SURFACE = yes

ifeq ($(AK650_MATRIX_TEST),yes)
    OPT_DEFS += -DAK650_MATRIX_TEST
    SRC += keyboards/a_jazz/ak650/reference/matrix_test.c
endif

SRC += companion.c
OPT_DEFS += -DCOMPANION_WIDTH=128
