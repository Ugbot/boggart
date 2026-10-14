#include "bpty.h"
#include <errno.h>
#include <fcntl.h>
#include <signal.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/ioctl.h>
#include <termios.h>
#include <unistd.h>
#define CHECK(c) do { if (!(c)) { fprintf(stderr,"line %d: %s (errno %d)\n",__LINE__,#c,errno); exit(1); } } while (0)
#define INPUT_BYTES (2u*1024u*1024u)
/* Compile the actual transport under test-only allocation/ioctl interception;
 * these definitions replace its archive object. Product hooks stay absent. */
static size_t allocation_count,allocation_failure;
static bool allocation_fails(void) { return ++allocation_count==allocation_failure; }
static void *pty_malloc(size_t n) { return allocation_fails() ? NULL : malloc(n); }
static void *pty_calloc(size_t n,size_t size) { return allocation_fails() ? NULL : calloc(n,size); }
static void *pty_realloc(void *p,size_t n) { return allocation_fails() ? NULL : realloc(p,n); }
static bool ioctl_failure;
static int pty_ioctl(int fd,unsigned long request,void *arg) {
  if (ioctl_failure && request==TIOCSWINSZ) { errno=EIO; return -1; }
  return ioctl(fd,request,arg);
}
#define malloc pty_malloc
#define calloc pty_calloc
#define realloc pty_realloc
#define ioctl pty_ioctl
#include "../../src/bpty.c"
#undef malloc
#undef calloc
#undef realloc
#undef ioctl
static void output(const void *data,size_t length) {
  const char *bytes=data;
  while (length) { ssize_t n=write(1,bytes,length); if (n<0 && errno==EINTR) continue; CHECK(n>0); bytes+=n; length-=(size_t)n; }
}
static int child(const char *mode) {
  CHECK(isatty(0) && isatty(1) && isatty(2)); CHECK(getpgrp()==getpid() && tcgetpgrp(0)==getpid());
  CHECK(fcntl(200,F_GETFD)<0 && errno==EBADF);
  struct termios term; CHECK(!tcgetattr(0,&term)); cfmakeraw(&term); CHECK(!tcsetattr(0,TCSANOW,&term));
  if (!strcmp(mode,"hang")) signal(SIGHUP,SIG_IGN);
  output("READY\r\n",7);
  if (!strcmp(mode,"flood")) {
    char bytes[8192]; memset(bytes,'x',sizeof bytes); bytes[sizeof bytes-1]='\n';
    for (unsigned i=0;i<128;i++) output(bytes,sizeof bytes);
    output("\r\nFINAL",7); return 7;
  }
  if (!strcmp(mode,"hang")) { for (;;) pause(); }
  if (!strcmp(mode,"resize")) {
    char token; CHECK(read(0,&token,1)==1); struct winsize size; CHECK(!ioctl(0,TIOCGWINSZ,&size));
    char line[80]; int n=snprintf(line,sizeof line,"COLUMNS=%u ROWS=%u",size.ws_col,size.ws_row); output(line,(size_t)n); return 7;
  }
  if (!strcmp(mode,"echo")) {
    size_t received=0; unsigned char bytes[8192];
    while (received<INPUT_BYTES) {
      ssize_t n=read(0,bytes,sizeof bytes); if (n<0 && errno==EINTR) continue; CHECK(n>0);
      for (ssize_t i=0;i<n;i++) CHECK(bytes[i]==(uint8_t)((received+(size_t)i)*37+11));
      received+=(size_t)n;
    }
    CHECK(received==INPUT_BYTES); output("INPUT_OK",8); return 7;
  }
  return 0;
}
static void timeout(uv_timer_t *timer) { (void)timer; fprintf(stderr,"PTY test deadline expired\n"); exit(1); }
typedef struct { uv_loop_t loop; uv_timer_t deadline; bterm *core; bpty *pty; } fixture;
static void begin(fixture *f) {
  memset(f,0,sizeof *f); CHECK(!uv_loop_init(&f->loop));
  CHECK(!uv_timer_init(&f->loop,&f->deadline)); CHECK(!uv_timer_start(&f->deadline,timeout,5000,0)); uv_unref((uv_handle_t *)&f->deadline);
  f->core=bterm_create(80,24,100,NULL,NULL); CHECK(f->core);
}
static void end(fixture *f) {
  bpty_destroy(f->pty); f->pty=NULL; bterm_destroy(f->core); f->core=NULL;
  uv_timer_stop(&f->deadline); uv_close((uv_handle_t *)&f->deadline,NULL);
  uv_run(&f->loop,UV_RUN_DEFAULT); CHECK(!uv_loop_close(&f->loop));
}
static void spawn(fixture *f,const char *self,const char *mode) {
  char *args[]={(char *)self,"--child",(char *)mode,NULL}; int error;
  f->pty=bpty_open(&f->loop,f->core,(bpty_options){self,NULL,args},&error); CHECK(f->pty && !error);
}
static void ready_child(fixture *f) {
  while (bpty_state(f->pty).bytes_read<7 && !bpty_state(f->pty).eof) uv_run(&f->loop,UV_RUN_ONCE);
  CHECK(bpty_state(f->pty).bytes_read>=7);
  int64_t group; CHECK(!bpty_foreground_group(f->pty,&group) && group==bpty_state(f->pty).pid);
  /* Status reads must not advance I/O or reap children. */
  bpty_status before=bpty_state(f->pty);
  for (unsigned i=0;i<1000;i++) CHECK(bpty_state(f->pty).read_callbacks==before.read_callbacks);
}
static bool contains(bterm *core,const char *needle) {
  const lpage_screen *screen=bterm_screen(core);
  for (size_t y=0;y<lpage_rows(screen);y++) {
    const lpage_row *row=lpage_visible(screen,y); size_t match=0;
    for (size_t x=0;x<lpage_columns(screen);x++) {
      if (lpage_codepoint(screen,&row->cells[x])==(unsigned char)needle[match]) { if (!needle[++match]) return true; }
      else match=0;
    }
  }
  return false;
}
static void completed(fixture *f) {
  uv_run(&f->loop,UV_RUN_DEFAULT); bpty_status status=bpty_state(f->pty);
  CHECK(status.exited && status.eof && status.exit_status==7 && !status.term_signal && !status.error);
  CHECK(status.queued_bytes==0);
}
static void transport(const char *self) {
  /* Deliberately non-CLOEXEC host fd must be absent in the shell. */
  int fd=open("/dev/null",O_RDONLY); CHECK(fd>=0); CHECK(dup2(fd,200)==200); close(fd);
  fixture f; begin(&f); spawn(&f,self,"echo"); ready_child(&f);
  uint8_t *input=malloc(INPUT_BYTES); CHECK(input);
  for (size_t i=0;i<INPUT_BYTES;i++) input[i]=(uint8_t)(i*37+11);
  CHECK(!bpty_write(f.pty,input,INPUT_BYTES)); free(input);
  CHECK(bpty_state(f.pty).queued_bytes>0); bpty_status before=bpty_state(f.pty);
  allocation_failure=allocation_count+1;
  CHECK(bpty_write(f.pty,(const uint8_t *)"x",INPUT_BYTES)==UV_ENOMEM);
  CHECK(bpty_state(f.pty).queued_bytes==before.queued_bytes); allocation_failure=0;
  CHECK(bpty_write(f.pty,(const uint8_t *)"x",32u*1024u*1024u+1)==UV_ENOBUFS);
  CHECK(bpty_state(f.pty).queued_bytes==before.queued_bytes);
  completed(&f); CHECK(contains(f.core,"INPUT_OK")); end(&f);
  begin(&f); spawn(&f,self,"resize"); ready_child(&f);
  ioctl_failure=true; CHECK(bpty_resize(f.pty,123,45)==UV_EIO); ioctl_failure=false;
  CHECK(lpage_columns(bterm_screen(f.core))==80 && lpage_rows(bterm_screen(f.core))==24);
  struct winsize old_size; CHECK(!ioctl(f.pty->master,TIOCGWINSZ,&old_size) && old_size.ws_col==80 && old_size.ws_row==24);
  CHECK(bpty_resize(f.pty,0,45)==UV_EINVAL); CHECK(!bpty_resize(f.pty,123,45));
  CHECK(lpage_columns(bterm_screen(f.core))==123 && lpage_rows(bterm_screen(f.core))==45);
  CHECK(!bpty_write(f.pty,(const uint8_t *)"R",1));
  completed(&f); CHECK(contains(f.core,"COLUMNS=123 ROWS=45")); end(&f);
  begin(&f); spawn(&f,self,"flood"); completed(&f);
  CHECK(contains(f.core,"FINAL") && bpty_state(f.pty).bytes_read==7+128*8192+7);
  CHECK(bpty_state(f.pty).read_callbacks>=4); end(&f);
  begin(&f); spawn(&f,self,"hang"); ready_child(&f); int64_t pid=bpty_state(f.pty).pid;
  end(&f); CHECK(kill((pid_t)pid,0)<0 && errno==ESRCH);
  begin(&f); spawn(&f,self,"hang"); ready_child(&f); pid=bpty_state(f.pty).pid;
  bpty_shutdown(&f.loop); CHECK(bpty_state(f.pty).exited && bpty_state(f.pty).eof && bpty_state(f.pty).term_signal==SIGKILL);
  CHECK(kill((pid_t)pid,0)<0 && errno==ESRCH); end(&f);
  close(200);
}
static bool uv_exited;
static void release_after_loop(void) {
  uv_loop_t *loop=malloc(sizeof *loop); CHECK(loop && !uv_loop_init(loop));
  bterm *core=bterm_create(80,24,0,NULL,NULL); CHECK(core);
  char *args[]={"/bin/sh","-c","sleep 30",NULL}; int error;
  bpty *pty=bpty_open(loop,core,(bpty_options){args[0],NULL,args},&error); CHECK(pty && !error);
  bpty_shutdown(loop); CHECK(bpty_state(pty).exited && bpty_state(pty).eof);
  CHECK(!uv_loop_close(loop)); free(loop);
  /* Retained transport objects must not touch a destroyed loop at release. */
  bpty_destroy(pty); bterm_destroy(core);
}
static bool reject_terminal_reply(void *context,const uint8_t *bytes,size_t size) {
  (void)context;(void)bytes;(void)size;return false;
}
static void feed_failure(void) {
  fixture f; begin(&f); bterm_destroy(f.core);
  f.core=bterm_create(80,24,0,reject_terminal_reply,NULL); CHECK(f.core);
  char *args[]={"/bin/sh","-c","trap '' HUP; printf '\033[6n'; while :; do sleep 1; done",NULL}; int error;
  f.pty=bpty_open(&f.loop,f.core,(bpty_options){args[0],NULL,args},&error); CHECK(f.pty && !error);
  uv_run(&f.loop,UV_RUN_DEFAULT); bpty_status status=bpty_state(f.pty);
  CHECK(status.error==UV_ENOMEM && status.eof && status.exited && status.term_signal==SIGKILL);
  end(&f);
}
static void uv_exit(uv_process_t *process,int64_t status,int signal_number) {
  CHECK(status==23 && !signal_number); uv_exited=true; uv_close((uv_handle_t *)process,NULL);
}
static void coexist(void) {
  fixture f; begin(&f); uv_process_t process; memset(&process,0,sizeof process);
  char *other_args[]={"/bin/sh","-c","exit 23",NULL}; uv_process_options_t options={0};
  options.file=other_args[0]; options.args=other_args; options.exit_cb=uv_exit; CHECK(!uv_spawn(&f.loop,&process,&options));
  char *args[]={"/bin/sh","-c","printf ONE; exit 7",NULL}; int error;
  f.pty=bpty_open(&f.loop,f.core,(bpty_options){args[0],NULL,args},&error); CHECK(f.pty && !error);
  bterm *second=bterm_create(80,24,0,NULL,NULL); CHECK(second);
  char *args2[]={"/bin/sh","-c","printf TWO; exit 9",NULL};
  bpty *pty2=bpty_open(&f.loop,second,(bpty_options){args2[0],NULL,args2},&error); CHECK(pty2 && !error);
  completed(&f); CHECK(uv_exited && contains(f.core,"ONE") && contains(second,"TWO"));
  CHECK(bpty_state(pty2).exited && bpty_state(pty2).eof && bpty_state(pty2).exit_status==9 && !bpty_state(pty2).error);
  bpty_destroy(pty2); bterm_destroy(second); end(&f);
}
static void errors(void) {
  const char *commands[]={"/no/such/bmux-command","no-such-bmux-command","/bin/sh","/bin/sh"};
  const char *directories[]={NULL,NULL,"/no/such/bmux-directory",NULL};
  for (unsigned i=0;i<4;i++) {
    fixture f; begin(&f); char *args[]={(char *)commands[i],"-c","exit 0",NULL}; int error;
    if (i==3) { args[0]="/dev/null"; commands[i]="/dev/null"; }
    f.pty=bpty_open(&f.loop,f.core,(bpty_options){commands[i],directories[i],args},&error);
    CHECK(!f.pty && error<0); end(&f);
  }
  for (size_t point=1;point<=3;point++) {
    fixture f; begin(&f); char *args[]={"/bin/sh","-c","exit 0",NULL}; int error;
    allocation_count=0; allocation_failure=point;
    f.pty=bpty_open(&f.loop,f.core,(bpty_options){args[0],NULL,args},&error);
    CHECK(!f.pty && error==UV_ENOMEM); allocation_failure=0; end(&f);
  }
}
int main(int argc,char **argv) {
  if (argc==3 && !strcmp(argv[1],"--child")) return child(argv[2]);
  errors(); transport(argv[0]); coexist(); feed_failure(); release_after_loop();
  puts("native PTY controlling tty, queued input, resize, exit/EOF, fd cleanup, deferred close and uv_spawn coexistence pass"); return 0;
}
