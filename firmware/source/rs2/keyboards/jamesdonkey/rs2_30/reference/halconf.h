// SPDX-License-Identifier: GPL-2.0-or-later
#pragma once

#define HAL_USE_SERIAL TRUE
#define HAL_USE_SPI TRUE
#define HAL_USE_RTC TRUE
#define HAL_USE_I2C TRUE
#define HAL_USE_WDG TRUE
#define HAL_USE_PWM TRUE
#define SW_I2C_USE_I2C1 TRUE
#define SW_I2C_USE_OPENDRAIN FALSE
#define SW_I2C_USE_OSAL_DELAY FALSE

#include_next <halconf.h>
