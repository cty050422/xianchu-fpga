#include "authorization.h"
#include <cassert>
int main(){xc::Authorization a;a.armUSB(0,true,3);assert(!a.permitsBLE(1,true,true,true,3,3));
 a.armBLE(0,true,true,3);for(unsigned t=5000;t<=1800000;t+=5000){assert(a.permitsBLE(t,true,true,true,3,3));a.activity(t);}
 assert(!a.permitsBLE(1800001,true,true,true,4,3));a.armBLE(10,true,true,4);
 assert(!a.permitsBLE(60010,true,true,true,4,4));}
