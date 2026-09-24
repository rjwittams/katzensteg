#include <windows.h>
#include <stdio.h>
#include <string.h>
static const char payload[] =
  "BEGIN\r\n"
  "\x1b_Ga=T,f=24,s=1,v=1;AAAA\x1b\\"  "<AFTER-APC>\r\n"
  "\x1bPq#0;2;100;0;0#0~~~~\x1b\\" "<AFTER-SIXEL>\r\n"
  "\x1b]1337;File=inline=1:AAAA\x07" "<AFTER-OSC1337>\r\n"
  "END\r\n";
int child(void){
  HANDLE h=GetStdHandle(STD_OUTPUT_HANDLE); DWORD m=0; GetConsoleMode(h,&m);
  SetConsoleMode(h,m|ENABLE_VIRTUAL_TERMINAL_PROCESSING|DISABLE_NEWLINE_AUTO_RETURN);
  DWORD w; WriteFile(h,payload,sizeof(payload)-1,&w,NULL); Sleep(500); return 0;}
static void dump(const char*buf,DWORD n){for(DWORD i=0;i<n;i++){unsigned char c=buf[i]; if(c==0x1b)printf("<ESC>");else if(c==7)printf("<BEL>");else if(c<32&&c!='\n')printf("<%02x>",c);else putchar(c);} }
typedef HRESULT (WINAPI *CreateFn)(COORD,HANDLE,HANDLE,DWORD,HPCON*); typedef VOID (WINAPI *CloseFn)(HPCON); static CreateFn pCreate; static CloseFn pClose;
int run(DWORD flags){
  HANDLE inR,inW,outR,outW; CreatePipe(&inR,&inW,NULL,0); CreatePipe(&outR,&outW,NULL,0);
  HPCON pc; HRESULT hr=pCreate((COORD){80,25},inR,outW,flags,&pc);
  printf("=== flags=0x%lx hr=0x%08lx\n",flags,(unsigned long)hr); if(hr<0) return 1;
  STARTUPINFOEXW si={0}; si.StartupInfo.cb=sizeof(si); si.StartupInfo.dwFlags=STARTF_USESTDHANDLES; SIZE_T sz=0;
  InitializeProcThreadAttributeList(NULL,1,0,&sz); si.lpAttributeList=HeapAlloc(GetProcessHeap(),0,sz);
  InitializeProcThreadAttributeList(si.lpAttributeList,1,0,&sz);
  UpdateProcThreadAttribute(si.lpAttributeList,0,PROC_THREAD_ATTRIBUTE_PSEUDOCONSOLE,pc,sizeof(pc),NULL,NULL);
  wchar_t exe[MAX_PATH]; GetModuleFileNameW(NULL,exe,MAX_PATH); wchar_t cmd[MAX_PATH+16]; swprintf(cmd,MAX_PATH+16,L"\"%s\" child",exe);
  PROCESS_INFORMATION pi; if(!CreateProcessW(NULL,cmd,NULL,NULL,FALSE,EXTENDED_STARTUPINFO_PRESENT,NULL,NULL,&si.StartupInfo,&pi)){printf("cp fail %lu\n",GetLastError());return 1;}
  CloseHandle(inR); CloseHandle(outW);
  WaitForSingleObject(pi.hProcess,5000); Sleep(300); pClose(pc);
  char buf[65536]; DWORD n,tot=0; while(ReadFile(outR,buf+tot,sizeof(buf)-tot,&n,NULL)&&n){tot+=n;}
  dump(buf,tot); printf("\n"); return 0;}
int main(int argc,char**argv){ if(argc>1&&!strcmp(argv[1],"child")) return child(); HMODULE m=LoadLibraryW(L"conpty.dll"); pCreate=(CreateFn)GetProcAddress(m,"ConptyCreatePseudoConsole"); pClose=(CloseFn)GetProcAddress(m,"ConptyClosePseudoConsole"); if(!pCreate){printf("no conpty.dll");return 1;} run(0); return 0;}
