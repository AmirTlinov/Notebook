#include "NotebookTypesetter.h"
#include <stdio.h>
#include <stdlib.h>
#include <time.h>
static double now(void) { return clock_gettime_nsec_np(CLOCK_MONOTONIC_RAW)/1e6; }
int main(int argc,char**argv){
 if(argc!=5)return 2;
 FILE*f=fopen(argv[4],"rb");fseek(f,0,SEEK_END);size_t n=ftell(f);rewind(f);uint8_t*s=malloc(n);fread(s,1,n,f);fclose(f);
 double start=now();NBTypesetter*r=nb_typesetter_create(argv[1],argv[2],argv[3]);printf("create %.3f ms\n",now()-start);if(!r)return 3;
 NBTypesetterCancel*c=nb_typesetter_cancel_create();
 for(int i=0;i<35;i++){start=now();NBTypesetterOutput*o=nb_typesetter_svg(r,s,n,30000,c);size_t count;const uint8_t*error=nb_typesetter_output_bytes(o,3,&count);if(count){fwrite(error,1,count,stderr);return 4;}nb_typesetter_output_bytes(o,0,&count);printf("%d %.3f ms %zu pdf-bytes %zu guest-memory\n",i,now()-start,count,nb_typesetter_output_memory(o));nb_typesetter_output_destroy(o);}
 nb_typesetter_cancel_destroy(c);nb_typesetter_destroy(r);free(s);
}
