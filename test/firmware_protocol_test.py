"""Host-build the shared protocol to check independent state and dirty bands."""
from pathlib import Path
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parents[1]
QUANTUM = r'''
#pragma once
#include <stdint.h>
#include <stdbool.h>
#include <string.h>
typedef struct {uint8_t r,g,b;} rgb_t;
uint32_t timer_read32(void);
uint32_t timer_elapsed32(uint32_t);
bool rgb_matrix_is_enabled(void);
bool rgb_matrix_get_suspend_state(void);
uint8_t rgb_matrix_get_val(void);
void rgb_matrix_set_color(int,uint8_t,uint8_t,uint8_t);
'''
RTC = r'''
#pragma once
#include <stdint.h>
#include <stdbool.h>
typedef struct {uint8_t seconds,minutes,hours,day,weekday,month;uint16_t year;} rtc_time_t;
bool rtc_set_time(const rtc_time_t*);
'''
TEST = r'''
#include "companion.h"
#include "rtc/rtc.h"
#include <assert.h>
static uint32_t clock_ms=100;
uint32_t timer_read32(void){return clock_ms;}
uint32_t timer_elapsed32(uint32_t stamp){return clock_ms-stamp;}
bool rgb_matrix_is_enabled(void){return true;}
bool rgb_matrix_get_suspend_state(void){return false;}
uint8_t rgb_matrix_get_val(void){return 160;}
void rgb_matrix_set_color(int i,uint8_t r,uint8_t g,uint8_t b){(void)i;(void)r;(void)g;(void)b;}
bool rtc_set_time(const rtc_time_t*t){(void)t;return true;}
void raw_hid_send(uint8_t *p,uint8_t n){(void)p;(void)n;}
static void send(uint8_t *p){assert(companion_command(p,32));assert(p[0]!=255);}
int main(void){
 companion_view_t view={0};
 uint8_t caps[32]={8,81,0};send(caps);assert(caps[9]==3&&caps[7]==RGB_MATRIX_LED_COUNT);
 assert(companion_changed(&view,1)==0);
 uint8_t monitor[32]={7,81,3,17,36,42,68};send(monitor);assert(companion_changed(&view,1)==7);
 clock_ms+=100;send(monitor);assert(companion_changed(&view,1)==0);
 uint8_t weather[32]={7,81,4,0,243,96,3,18,30};send(weather);
 assert(companion_changed(&view,1)==0);assert(companion.cpu==17&&companion.temperature==243);
 uint8_t bitmap[32]={7,81,5,0,0,1,128};send(bitmap);
 uint8_t title[32]={7,81,11,0,0,1,64};send(title);
 uint8_t commit[32]={7,81,6,1,0,100};send(commit);
 assert(companion_changed(&view,1)==0);assert(companion.memory==36&&companion.humidity==96&&companion.bitmap[0]==128);
 clock_ms+=100;send(commit);assert(companion_changed(&view,3)==0);
 bitmap[6]=192;send(bitmap);send(commit);assert(companion_changed(&view,3)==2);
 commit[5]=120;send(commit);assert(companion_changed(&view,3)==4);
 title[6]=32;send(title);send(commit);assert(companion_changed(&view,3)==1);
 send(title);send(bitmap);send(commit);assert(companion_changed(&view,3)==0);
 monitor[3]=99;send(monitor);assert(companion_changed(&view,3)==0);
 assert(companion.temperature==243&&companion.playing==1);
 clock_ms+=100;send(weather);assert(companion_changed(&view,2)==0);
 weather[5]=88;send(weather);assert(companion_changed(&view,2)==7);
 clock_ms+=16000;assert(companion_changed(&view,3)==7);assert(companion_changed(&view,3)==0);
 assert(companion_changed(&view,2)==0); // monitor/lyrics expiry never repaints fresh weather
 uint16_t size=sizeof(companion.title);title[3]=(size-1)>>8;title[4]=(size-1)&255;send(title);
 title[4]=size&255;title[3]=size>>8;companion_command(title,32);assert(title[0]==255);
 uint8_t bad[32]={7,81,6,1,3,233};companion_command(bad,32);assert(bad[0]==255&&companion.progress==120);
 return 0;
}
'''
def main():
    with tempfile.TemporaryDirectory(prefix='openkeyboard-protocol-') as folder:
        tmp=Path(folder)
        (tmp/'rtc').mkdir()
        (tmp/'quantum.h').write_text(QUANTUM)
        (tmp/'rtc/rtc.h').write_text(RTC)
        (tmp/'raw_hid.h').write_text('#include <stdint.h>\nvoid raw_hid_send(uint8_t*,uint8_t);\n')
        (tmp/'test.c').write_text(TEST)
        for model, board, width, leds in [
            ('rs2','jamesdonkey/rs2_30',240,98),('ak650','a_jazz/ak650',128,66),
        ]:
            source=ROOT/'firmware/source'/model/'keyboards'/board/'reference'
            output=tmp/model
            subprocess.run(['gcc','-std=c11','-Wall','-Wextra','-Werror','-fsanitize=address,undefined',
                f'-DCOMPANION_WIDTH={width}',f'-DRGB_MATRIX_LED_COUNT={leds}',
                '-I',str(tmp),'-I',str(source),str(tmp/'test.c'),str(source/'companion.c'),'-o',str(output)],check=True)
            subprocess.run([str(output)],check=True)
            print(model+': independent data, stable heartbeats, dirty bands, expiry and bounds verified')
if __name__=='__main__':main()
