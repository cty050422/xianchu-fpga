#include "mobile_view.h"
#include <cstdio>
int main(){xc::MobileView v;v.valid=true;v.length=16;v.transport=2;v.voices=3;v.target=5;v.step=2;v.dx=512;v.dy=-512;v.bendRatio=34000;v.depth=1024;v.health=31;
 for(unsigned mode=0;mode<3;mode++){v.mode=mode;v.preset=mode;v.octave=mode==0;v.expression=mode==1?1:2;
  uint8_t b[1024];xc::renderPerformance(v,b);char n[32];snprintf(n,sizeof(n),"oled_%u.bin",mode);FILE*f=fopen(n,"wb");fwrite(b,1,1024,f);fclose(f);}
}
