#include <windows.h>
#include <stdio.h>
#include <string.h>
#include <stdlib.h>
int child(int size){
  HANDLE h=GetStdHandle(STD_OUTPUT_HANDLE); DWORD m=0; GetConsoleMode(h,&m);
  SetConsoleMode(h,m|ENABLE_VIRTUAL_TERMINAL_PROCESSING|DISABLE_NEWLINE_AUTO_RETURN);
  char*p=malloc(size+64); int n=sprintf(p,"\x1b]5522;"); memset(p+n,'A',size); n+=size; n+=sprintf(p+n,"\x1b\<END>\r\n");
  DWORD w; WriteFile(h,p,n,&w,NULL); Sleep(800); return 0;}
int run(int size){
  HANDLE inR,inW,outR,outW; CreatePipe(&inR,&inW,NULL,0); CreatePipe(&outR,&outW,NULL,1<<20);
  HPCON pc; CreatePseudoConsole((COORD){80,25},inR,outW,0,&pc);
  STARTUPINFOEXW si={0}; si.StartupInfo.cb=sizeof(si); si.StartupInfo.dwFlags=STARTF_USESTDHANDLES; SIZE_T sz=0;
  InitializeProcThreadAttributeList(NULL,1,0,&sz); si.lpAttributeList=HeapAlloc(GetProcessHeap(),0,sz);
  InitializeProcThreadAttributeList(si.lpAttributeList,1,0,&sz);
  UpdateProcThreadAttribute(si.lpAttributeList,0,PROC_THREAD_ATTRIBUTE_PSEUDOCONSOLE,pc,sizeof(pc),NULL,NULL);
  wchar_t exe[MAX_PATH]; GetModuleFileNameW(NULL,exe,MAX_PATH); wchar_t cmd[MAX_PATH+32]; swprintf(cmd,MAX_PATH+32,L"\"%s\" child %d",exe,size);
  PROCESS_INFORMATION pi; CreateProcessW(NULL,cmd,NULL,NULL,FALSE,EXTENDED_STARTUPINFO_PRESENT,NULL,NULL,&si.StartupInfo,&pi);
  CloseHandle(inR); CloseHandle(outW);
  static char buf[1<<23]; DWORD n,tot=0;
  /* drain concurrently-ish: read until child exits */
  HANDLE t=pi.hProcess; for(;;){ DWORD avail=0; PeekNamedPipe(outR,NULL,0,NULL,&avail,NULL); if(avail){ReadFile(outR,buf+tot,avail,&n,NULL);tot+=n;} else if(WaitForSingleObject(t,50)==WAIT_OBJECT_0){ Sleep(200); PeekNamedPipe(outR,NULL,0,NULL,&avail,NULL); if(!avail)break;} }
  ClosePseudoConsole(pc);
  size_t as=0; for(DWORD i=0;i<tot;i++) if(buf[i]=='A') as++;
  char*o=strstr(buf,"\x1b]5522;");
  printf("tail:"); for(DWORD i=(tot>120?tot-120:0);i<tot;i++){unsigned char c=buf[i]; if(c==27)printf("<ESC>"); else if(c<32)printf("<%02x>",c); else putchar(c);} printf("\n");
  printf("size=%d out=%lu As=%zu osc_intro=%s end=%s\n",size,tot,as,o?"yes":"no",strstr(buf,"<END>")?"yes":"no"); return 0;}
int main(int argc,char**argv){ if(argc>2&&!strcmp(argv[1],"child")) return child(atoi(argv[2])); int s[]={1000,4<<20}; for(int i=0;i<2;i++) run(s[i]); return 0;}
