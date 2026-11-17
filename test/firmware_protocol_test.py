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
 uint8_t caps[32]={8,81,0};send(caps);assert(caps[9]==5&&caps[7]==RGB_MATRIX_LED_COUNT);
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

 uint8_t network[32]={7,81,12,0,16,0,0,0,0,4,0,1};send(network);
 assert(companion.download==1048576&&companion.upload==1024);
 assert(companion_changed(&view,2)==0);assert(companion_changed(&view,4)==0);
 network[6]=1;send(network);assert(companion_changed(&view,4)==7);
 send(network);assert(companion_changed(&view,4)==0);
 clock_ms+=6000;assert(companion_changed(&view,4)==7);assert(companion_changed(&view,4)==0);
 uint8_t countdown[32]={7,81,13,1,0,0,0,60,0,0,0,60,0,0};send(countdown);
 assert(companion_timer_remaining()==60);assert(companion_changed(&view,5)==7);
 clock_ms+=1500;assert(companion_timer_remaining()==59);assert(companion_changed(&view,5)==3);
 assert(companion_changed(&view,2)==0);
 countdown[3]=2;countdown[7]=59;send(countdown);assert(companion_changed(&view,5)==7);
 clock_ms+=10000;assert(companion_timer_remaining()==59);assert(companion_changed(&view,5)==0);
 countdown[3]=1;send(countdown);clock_ms+=60000;assert(companion_timer_remaining()==0);
 countdown[7]=61;companion_command(countdown,32);assert(countdown[0]==255);
 uint8_t detail[32]={7,81,14,255,106,0,200,80,42,0,95,0,128};send(detail);
 assert(companion.minimum==-150&&companion.maximum==200&&companion.aqi==95&&companion.pm25==128);
 assert(companion_changed(&view,2)==7);send(detail);assert(companion_changed(&view,2)==0);
 detail[7]=101;companion_command(detail,32);assert(detail[0]==255&&companion.rain==80);
 uint8_t audio[32]={7,81,15,2,128,255,100,80,60,40,20,0,0};send(audio);companion_indicators();
 assert(companion_changed(&view,2)==0);
 uint8_t select_page[32]={7,81,8,5};send(select_page);assert(companion.page_request==5);
 select_page[3]=6;companion_command(select_page,32);assert(select_page[0]==255);

 uint8_t owned[32]={7,81,13,1,0,0,0,60,0,0,0,60,0,0,1,0,0,0,42};send(owned);
 assert(companion.timer_owner==42);clock_ms+=1500;assert(companion_timer_remaining()==59);
 uint8_t idle_tab[32]={7,81,13,0,0,0,5,220,0,0,5,220};send(idle_tab);
 assert(idle_tab[14]==2&&companion.timer_state==1&&companion_timer_remaining()==59);
 uint8_t other[32]={7,81,13,1,0,0,0,60,0,0,0,60,0,0,0,0,0,0,43};send(other);assert(other[14]==2&&companion.timer_owner==42);
 other[14]=1;send(other);assert(companion.timer_owner==43);
 owned[14]=0;send(owned);assert(owned[14]==2&&companion.timer_owner==43);
 uint8_t read_timer[32]={8,81,13};send(read_timer);assert(read_timer[3]==1&&read_timer[11]==43);
 send(commit);companion_changed(&view,3);
 uint8_t artist[32]={7,81,16,0,0,1,128};send(artist);send(commit);assert(companion_changed(&view,3)==4);
 uint16_t artist_size=sizeof(companion.artist);artist[3]=artist_size>>8;artist[4]=artist_size&255;companion_command(artist,32);assert(artist[0]==255);
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
