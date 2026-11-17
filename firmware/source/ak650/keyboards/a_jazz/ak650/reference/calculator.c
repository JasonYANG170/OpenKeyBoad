// SPDX-License-Identifier: GPL-2.0-or-later
#include "calculator.h"

#include <stdio.h>
#include <string.h>

#define SCALE INT64_C(100000000)
#define LIMIT INT64_C(99999999999900)
#define OUTPUT_SCALE INT64_C(1000000)
#define GUARD_SCALE (SCALE / OUTPUT_SCALE)
#define MAX_NESTING 6

typedef struct {
    const char *next;
    uint8_t depth;
    bool error;
} parser_t;

static bool is_digit(char c) {
    return c >= '0' && c <= '9';
}

static int64_t checked(parser_t *p, int64_t value) {
    if (value >= -LIMIT && value <= LIMIT) return value;
    p->error = true;
    return 0;
}

static int64_t sum(parser_t *p);

static int64_t number(parser_t *p) {
    bool negative = *p->next == '-';
    if (negative || *p->next == '+') ++p->next;

    if (*p->next == '(') {
        if (p->depth == MAX_NESTING) {
            p->error = true;
            return 0;
        }
        ++p->next;
        ++p->depth;
        int64_t value = sum(p);
        --p->depth;
        if (*p->next == ')') ++p->next;
        else p->error = true;
        return negative ? -value : value;
    }

    int64_t value = 0;
    bool digit = false;
    while (is_digit(*p->next)) {
        value = checked(p, value * 10 + (*p->next++ - '0') * SCALE);
        digit = true;
    }
    if (*p->next == '.') {
        ++p->next;
        int32_t place = SCALE / 10;
        while (is_digit(*p->next)) {
            if (place < GUARD_SCALE) p->error = true;
            value = checked(p, value + (*p->next++ - '0') * place);
            place /= 10;
            digit = true;
        }
    }
    if (!digit) p->error = true;
    return negative ? -value : value;
}

static int64_t magnitude(int64_t value) {
    return value < 0 ? -value : value;
}

static int64_t multiply(parser_t *p, int64_t left, int64_t right) {
    // Split the mantissas so rounding the fractional product fits int64_t.
    int64_t whole = left / SCALE;
    if (whole && right > LIMIT / whole) {
        p->error = true;
        return 0;
    }
    int64_t low = left % SCALE;
    return whole * right + low * (right / SCALE) + (low * (right % SCALE) + SCALE / 2) / SCALE;
}

static int64_t divide(parser_t *p, int64_t left, int64_t right) {
    if (!right || left / right > LIMIT / SCALE) {
        p->error = true;
        return 0;
    }
    int64_t whole = left / right;
    int64_t remainder = left % right;
    int64_t fraction = 0;
    // Extract one decimal digit at a time so the numerator never exceeds int64_t.
    for (int64_t place = SCALE; place > 1 && remainder; place /= 10) {
        remainder *= 10;
        fraction += (remainder / right) * (place / 10);
        remainder %= right;
    }
    return whole * SCALE + fraction + (remainder * 2 >= right);
}

static int64_t product(parser_t *p) {
    int64_t value = number(p);
    while (!p->error && (*p->next == '*' || *p->next == '/')) {
        char op = *p->next++;
        int64_t rhs = number(p);
        bool negative = (value < 0) != (rhs < 0);
        int64_t left = magnitude(value), right = magnitude(rhs);
        int64_t result = op == '*' ? multiply(p, left, right) : divide(p, left, right);
        value = checked(p, negative ? -result : result);
    }
    return value;
}

static int64_t sum(parser_t *p) {
    int64_t value = product(p);
    while (!p->error && (*p->next == '+' || *p->next == '-')) {
        char op = *p->next++;
        int64_t rhs = product(p);
        value = checked(p, value + (op == '+' ? rhs : -rhs));
    }
    return value;
}

static void evaluate(rs2_calculator_t *calc) {
    parser_t p = { .next = calc->expression };
    int64_t value = sum(&p);
    calc->error = p.error || *p.next;
    if (calc->error) {
        calc->result[0] = '\0';
        return;
    }
    int64_t absolute = (magnitude(value) + GUARD_SCALE / 2) / GUARD_SCALE;
    unsigned fraction = absolute % OUTPUT_SCALE;
    if (fraction) {
        int len = snprintf(calc->result, sizeof(calc->result), "%s%lu.%06u",
                           value < 0 ? "-" : "", (unsigned long)(absolute / OUTPUT_SCALE), fraction);
        while (calc->result[len - 1] == '0') calc->result[--len] = '\0';
    } else {
        snprintf(calc->result, sizeof(calc->result), "%s%lu",
                 value < 0 && absolute ? "-" : "", (unsigned long)(absolute / OUTPUT_SCALE));
    }
}

void rs2_calculator_key(rs2_calculator_t *calc, char key) {
    if (key == 'C') {
        memset(calc, 0, sizeof(*calc));
        return;
    }
    if (key == '=') {
        if (!calc->length || calc->evaluated) return;
        calc->evaluated = true;
        if (!calc->error) evaluate(calc);
        return;
    }
    if (key == '\b') {
        calc->error = calc->evaluated = false;
        if (calc->length) calc->expression[--calc->length] = '\0';
        return;
    }
    bool op = key == '+' || key == '-' || key == '*' || key == '/';
    if (!(op || is_digit(key) || key == '.' || key == '(' || key == ')')) return;
    if (calc->error && !calc->evaluated) return;
    if (calc->evaluated) {
        if (op && !calc->error) {
            strcpy(calc->expression, calc->result);
            calc->length = strlen(calc->result);
        } else {
            calc->length = 0;
        }
        calc->evaluated = false;
        calc->error = false;
        calc->result[0] = '\0';
    }
    if (calc->length >= sizeof(calc->expression) - 1) {
        calc->error = true;
        return;
    }
    calc->expression[calc->length++] = key;
    calc->expression[calc->length] = '\0';
}
