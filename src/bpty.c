#include "bpty.h"
#include <stdlib.h>
#include <string.h>
#ifndef _WIN32
#include <dirent.h>
#include <errno.h>
#include <fcntl.h>
#include <limits.h>
#include <signal.h>
#include <stdio.h>
#include <sys/ioctl.h>
#include <sys/wait.h>
#include <unistd.h>
#if defined(__APPLE__) || defined(__FreeBSD__) || defined(__OpenBSD__) || defined(__NetBSD__)
#include <util.h>
#else
#include <pty.h>
#endif
#ifndef PATH_MAX
#define PATH_MAX 4096
#endif
extern char **environ;
#define IO_BUDGET (256u * 1024u)
#define QUEUE_LIMIT (32u * 1024u * 1024u)
struct bpty {
  uv_loop_t *loop;
  struct bpty *registry_next;
  uv_poll_t poll;
  uv_signal_t signal;
  uv_timer_t kill_timer;
  bterm *core;
  int master, handles;
  pid_t child;
  bool poll_init, signal_init, timer_init, released;
  bpty_status state;
  uint8_t *queue;
  size_t queue_capacity, queue_head, queue_length;
};
/* All APIs/callbacks run on their owning loop thread. Thread-local ownership
 * also covers worker Lua states without sharing a mutable global registry. */
static _Thread_local bpty *registry;
static _Thread_local uv_loop_t *shutdown_loop;
static void freed(bpty *t) {
  if (t->released && !t->handles && !t->child) {
    bpty **entry=&registry; while (*entry && *entry!=t) entry=&(*entry)->registry_next;
    if (*entry) *entry=t->registry_next;
    free(t->queue); free(t);
  }
}
static void closed(uv_handle_t *h) {
  bpty *t=h->data;
  if (h==(uv_handle_t *)&t->poll) t->poll_init=false;
  else if (h==(uv_handle_t *)&t->signal) t->signal_init=false;
  else if (h==(uv_handle_t *)&t->kill_timer) t->timer_init=false;
  t->handles--; freed(t);
}
static void close_handle(uv_handle_t *h) { if (!uv_is_closing(h)) uv_close(h,closed); }
static void stop_io(bpty *t) {
  if (t->poll_init) { uv_poll_stop(&t->poll); close_handle((uv_handle_t *)&t->poll); }
  if (t->master>=0) { close(t->master); t->master=-1; }
  t->queue_head=t->queue_length=0;
}
static void kill_deadline(uv_timer_t *h);
static void terminate_child(bpty *t) {
  if (!t->child) return;
  (void)kill(-t->child,SIGHUP);
  if (!t->timer_init || uv_timer_start(&t->kill_timer,kill_deadline,250,0)) (void)kill(t->child,SIGKILL);
}
static void failed(bpty *t,int error) {
  if (!t->state.error) t->state.error=error;
  t->state.eof=true; t->state.revision++; stop_io(t); terminate_child(t);
}
static void reap_mode(bpty *t,int flags) {
  if (!t->child) return;
  int status=0; pid_t result;
  do result=waitpid(t->child,&status,flags); while (result<0 && errno==EINTR);
  if (!result) return;
  if (result<0 && errno!=ECHILD) { if (!t->state.error) t->state.error=uv_translate_sys_error(errno); return; }
  t->child=0; t->state.exited=true; t->state.exit_status=-1;
  if (result>0) {
    if (WIFEXITED(status)) t->state.exit_status=WEXITSTATUS(status);
    if (WIFSIGNALED(status)) t->state.term_signal=WTERMSIG(status);
  } else if (!t->state.error) t->state.error=UV_ESRCH;
  t->state.revision++;
  if (t->signal_init) { uv_signal_stop(&t->signal); close_handle((uv_handle_t *)&t->signal); }
  if (t->timer_init) { uv_timer_stop(&t->kill_timer); close_handle((uv_handle_t *)&t->kill_timer); }
}
static void reap(bpty *t) { reap_mode(t,WNOHANG); }
static void child_signal(uv_signal_t *h,int signum) { (void)signum; reap(h->data); }
static void kill_deadline(uv_timer_t *h) {
  bpty *t=h->data;
  reap(t); /* Never signal a PID/group after reaping it. */
  if (t->child) { (void)kill(-t->child,SIGKILL); (void)kill(t->child,SIGKILL); }
  uv_timer_stop(h);
}
static int refresh(bpty *t);
static int flush(bpty *t) {
  size_t budget=IO_BUDGET;
  while (t->queue_length && budget) {
    size_t count=t->queue_length<budget ? t->queue_length : budget;
    ssize_t n=write(t->master,t->queue+t->queue_head,count);
    if (n>0) { t->queue_head+=(size_t)n; t->queue_length-=(size_t)n; budget-=(size_t)n; continue; }
    if (n<0 && errno==EINTR) continue;
    if (n<0 && (errno==EAGAIN || errno==EWOULDBLOCK)) break;
    int error=n<0 ? uv_translate_sys_error(errno) : UV_EIO; failed(t,error); return error;
  }
  if (!t->queue_length) t->queue_head=0;
  return refresh(t);
}
static void ready(uv_poll_t *h,int status,int events) {
  bpty *t=h->data;
  if (status<0) { failed(t,status); return; }
  if (events&UV_READABLE) {
    t->state.read_callbacks++; size_t budget=IO_BUDGET; uint8_t bytes[16384];
    while (budget && t->master>=0) {
      ssize_t n=read(t->master,bytes,sizeof bytes);
      if (n>0) {
        budget-=(size_t)n; t->state.bytes_read+=(uint64_t)n; t->state.revision++;
        if (t->core && !bterm_feed(t->core,bytes,(size_t)n)) { failed(t,UV_ENOMEM); return; }
        continue;
      }
      if (n<0 && errno==EINTR) continue;
      if (n<0 && (errno==EAGAIN || errno==EWOULDBLOCK)) break;
      if (!n || (n<0 && errno==EIO)) {
        t->state.eof=true; t->state.revision++;
        if (t->core && !bterm_finish(t->core) && !t->state.error) t->state.error=UV_ENOMEM;
        stop_io(t); return;
      }
      failed(t,uv_translate_sys_error(errno)); return;
    }
  }
  if ((events&UV_WRITABLE) && t->master>=0) (void)flush(t);
}
static int refresh(bpty *t) {
  if (t->master<0 || !t->poll_init) return UV_EPIPE;
  int error=uv_poll_start(&t->poll,UV_READABLE|(t->queue_length ? UV_WRITABLE : 0),ready);
  if (error) failed(t,error);
  return error;
}
int bpty_write(bpty *t,const uint8_t *bytes,size_t length) {
  if (!t || t->master<0 || t->released || t->state.error) return UV_EPIPE;
  if (length && !bytes) return UV_EINVAL;
  if (length>QUEUE_LIMIT-t->queue_length) return UV_ENOBUFS;
  if (!length) return 0;
  size_t needed=t->queue_length+length;
  if (needed>t->queue_capacity) {
    size_t capacity=t->queue_capacity ? t->queue_capacity : 4096;
    while (capacity<needed) capacity*=2;
    uint8_t *next=malloc(capacity); if (!next) return UV_ENOMEM;
    if (t->queue_length) memcpy(next,t->queue+t->queue_head,t->queue_length);
    free(t->queue); t->queue=next; t->queue_capacity=capacity; t->queue_head=0;
  } else if (length>t->queue_capacity-t->queue_head-t->queue_length) {
    memmove(t->queue,t->queue+t->queue_head,t->queue_length); t->queue_head=0;
  }
  memcpy(t->queue+t->queue_head+t->queue_length,bytes,length); t->queue_length+=length;
  /* Once accepted, completion/errors are asynchronous state, never a partial
   * success return that could make the caller resend already-written bytes. */
  (void)flush(t); return 0;
}
typedef struct { bpty *term; unsigned columns,rows; int error; } resize_request;
static bool resize_kernel(void *context) {
  resize_request *r=context; struct winsize size={0};
  size.ws_col=(unsigned short)r->columns; size.ws_row=(unsigned short)r->rows;
  if (ioctl(r->term->master,TIOCSWINSZ,&size)<0) { r->error=uv_translate_sys_error(errno); return false; }
  return true;
}
int bpty_resize(bpty *t,unsigned columns,unsigned rows) {
  if (!columns || !rows || columns>4096 || rows>4096) return UV_EINVAL;
  if (!t || t->master<0 || t->released || !t->core) return UV_EPIPE;
  resize_request request={t,columns,rows,0};
  if (!bterm_resize_guarded(t->core,columns,rows,resize_kernel,&request)) return request.error ? request.error : UV_ENOMEM;
  t->state.revision++; return 0;
}
int bpty_foreground_group(const bpty *t,int64_t *group) {
  if (!group) return UV_EINVAL;
  if (!t || t->master<0 || t->released || t->state.exited) return UV_EPIPE;
  pid_t pid=tcgetpgrp(t->master);
  if (pid<0) return uv_translate_sys_error(errno);
  *group=pid; return 0;
}
bpty_status bpty_state(const bpty *t) {
  if (!t) return (bpty_status){.error=UV_EINVAL,.exited=true,.eof=true,.exit_status=-1};
  bpty_status state=t->state; state.queued_bytes=t->queue_length; return state;
}
void bpty_destroy(bpty *t) {
  if (!t || t->released) return;
  t->released=true; t->core=NULL;
  if (t->child && t->master>=0) {
    pid_t foreground=tcgetpgrp(t->master);
    if (foreground>0 && foreground!=t->child) (void)kill(-foreground,SIGHUP);
  }
  stop_io(t); reap(t);
  if (t->child) terminate_child(t);
  else {
    if (t->signal_init) close_handle((uv_handle_t *)&t->signal);
    if (t->timer_init) close_handle((uv_handle_t *)&t->kill_timer);
  }
  freed(t);
}
void bpty_shutdown(uv_loop_t *loop) {
  shutdown_loop=loop;
  for (bpty *t=registry;t;t=t->registry_next) if (t->loop==loop) {
    t->core=NULL; t->state.eof=true; t->state.revision++; stop_io(t);
    reap(t);
    if (t->child) {
      (void)kill(-t->child,SIGKILL); (void)kill(t->child,SIGKILL);
      reap_mode(t,0); /* Exit-only synchronous reap, never another child's PID. */
    }
    if (t->signal_init) { uv_signal_stop(&t->signal); close_handle((uv_handle_t *)&t->signal); }
    if (t->timer_init) { uv_timer_stop(&t->kill_timer); close_handle((uv_handle_t *)&t->kill_timer); }
  }
  for (;;) {
    bool pending=false;
    for (bpty *t=registry;t;t=t->registry_next) if (t->loop==loop && t->handles) { pending=true; break; }
    if (!pending) break;
    uv_run(loop,UV_RUN_NOWAIT);
  }
  shutdown_loop=NULL;
}
/* Prepare all allocation/environment/path work before fork. The child uses
 * only close/chdir/signal syscalls, execve, write and _exit after forkpty. */
static int command_path(bpty_options options,char out[PATH_MAX]) {
  char working[PATH_MAX];
  if (!getcwd(working,sizeof working)) return uv_translate_sys_error(errno);
  if (options.cwd) {
    char absolute[PATH_MAX];
    int n=options.cwd[0]=='/' ? snprintf(absolute,sizeof absolute,"%s",options.cwd)
      : snprintf(absolute,sizeof absolute,"%s/%s",working,options.cwd);
    if (n<0 || (size_t)n>=sizeof absolute) return UV_ENAMETOOLONG;
    memcpy(working,absolute,(size_t)n+1);
  }
  const char *command=options.command;
  if (strchr(command,'/')) {
    int n=command[0]=='/' ? snprintf(out,PATH_MAX,"%s",command) : snprintf(out,PATH_MAX,"%s/%s",working,command);
    return n<0 || n>=PATH_MAX ? UV_ENAMETOOLONG : 0;
  }
  const char *path=getenv("PATH"); if (!path) path="/usr/bin:/bin";
  int last=UV_ENOENT;
  for (;;) {
    const char *end=strchr(path,':'); size_t n=end ? (size_t)(end-path) : strlen(path);
    if (n<PATH_MAX) {
      int size=path[0]=='/' ? snprintf(out,PATH_MAX,"%.*s/%s",(int)n,path,command)
        : snprintf(out,PATH_MAX,"%s/%.*s%s%s",working,(int)n,path,n ? "/" : "",command);
      if (size>=0 && size<PATH_MAX) { if (!access(out,X_OK)) return 0; if (errno==EACCES) last=UV_EACCES; }
      else last=UV_ENAMETOOLONG;
    } else last=UV_ENAMETOOLONG;
    if (!end) return last;
    path=end+1;
  }
}
static int inherited_fds(int **out,size_t *count,int keep) {
  DIR *dir=opendir("/dev/fd");
  if (!dir) dir=opendir("/proc/self/fd");
  if (!dir) return uv_translate_sys_error(errno);
  size_t capacity=32; int *fds=malloc(capacity*sizeof *fds);
  if (!fds) { closedir(dir); return UV_ENOMEM; }
  *count=0; struct dirent *entry;
  for (;;) {
    errno=0; entry=readdir(dir);
    if (!entry) {
      if (errno) { int error=uv_translate_sys_error(errno); free(fds); closedir(dir); return error; }
      break;
    }
    char *end; long fd=strtol(entry->d_name,&end,10);
    if (*end || fd<3 || fd>INT_MAX || fd==keep || fd==dirfd(dir)) continue;
    if (*count==capacity) {
      if (capacity>SIZE_MAX/2/sizeof *fds) { free(fds); closedir(dir); return UV_ENOMEM; }
      capacity*=2; int *next=realloc(fds,capacity*sizeof *fds);
      if (!next) { free(fds); closedir(dir); return UV_ENOMEM; } fds=next;
    }
    fds[(*count)++]=(int)fd;
  }
  closedir(dir); *out=fds; return 0;
}
bpty *bpty_open(uv_loop_t *loop,bterm *core,bpty_options options,int *error_out) {
  int error=UV_EINVAL; bpty *t=NULL; int pipefd[2]={-1,-1},*fds=NULL; size_t count=0; char **environment=NULL;
  if (loop && loop==shutdown_loop) { error=UV_ECANCELED; goto done; }
  if (!loop || !core || !options.command || !*options.command || !options.argv || !options.argv[0]) goto done;
  char command[PATH_MAX]; if ((error=command_path(options,command))) goto done;
  size_t env_count=0; while (environ[env_count]) env_count++;
  if (env_count>(SIZE_MAX/sizeof *environment)-3) { error=UV_ENOMEM; goto done; }
  environment=malloc((env_count+3)*sizeof *environment); if (!environment) { error=UV_ENOMEM; goto done; }
  size_t used=0;
  for (size_t i=0;i<env_count;i++) if (strncmp(environ[i],"TERM=",5) && strncmp(environ[i],"COLORTERM=",10)) environment[used++]=environ[i];
  environment[used++]="TERM=xterm-256color"; environment[used++]="COLORTERM=truecolor"; environment[used]=NULL;
  t=calloc(1,sizeof *t); if (!t) { error=UV_ENOMEM; goto done; }
  t->loop=loop; t->registry_next=registry; registry=t;
  t->master=-1; t->core=core; t->state.exit_status=-1;
  if ((error=uv_signal_init(loop,&t->signal))) goto done;
  t->signal_init=true; t->handles++; t->signal.data=t;
  if ((error=uv_signal_start(&t->signal,child_signal,SIGCHLD))) goto done;
  if ((error=uv_timer_init(loop,&t->kill_timer))) goto done;
  t->timer_init=true; t->handles++; t->kill_timer.data=t;
  if (pipe(pipefd)<0) { error=uv_translate_sys_error(errno); goto done; }
  if (fcntl(pipefd[0],F_SETFD,FD_CLOEXEC)<0 || fcntl(pipefd[1],F_SETFD,FD_CLOEXEC)<0) { error=uv_translate_sys_error(errno); goto done; }
  if ((error=inherited_fds(&fds,&count,pipefd[1]))) goto done;
  const lpage_screen *screen=bterm_screen(core); struct winsize size={0};
  size.ws_col=(unsigned short)lpage_columns(screen); size.ws_row=(unsigned short)lpage_rows(screen);
  pid_t child=forkpty(&t->master,NULL,NULL,&size);
  if (child<0) { error=uv_translate_sys_error(errno); goto done; }
  if (!child) {
    const int signals[]={SIGINT,SIGQUIT,SIGTERM,SIGHUP,SIGPIPE,SIGCHLD,SIGTSTP,SIGTTIN,SIGTTOU,SIGWINCH};
    struct sigaction action={0}; action.sa_handler=SIG_DFL; sigemptyset(&action.sa_mask);
    for (size_t i=0;i<sizeof signals/sizeof *signals;i++) sigaction(signals[i],&action,NULL);
    sigset_t mask; sigemptyset(&mask); sigprocmask(SIG_SETMASK,&mask,NULL);
    for (size_t i=0;i<count;i++) close(fds[i]);
    if (options.cwd && chdir(options.cwd)<0) goto child_error;
    execve(command,options.argv,environment);
child_error: {
      int child_errno=errno; const char *bytes=(const char *)&child_errno; size_t left=sizeof child_errno;
      while (left) { ssize_t n=write(pipefd[1],bytes,left); if (n>0) { bytes+=n; left-=(size_t)n; } else if (n<0 && errno==EINTR) continue; else break; }
      _exit(127);
    }
  }
  t->child=child; t->state.pid=child;
  close(pipefd[1]); pipefd[1]=-1;
  int child_errno=0; size_t received=0;
  while (received<sizeof child_errno) {
    ssize_t n=read(pipefd[0],(char *)&child_errno+received,sizeof child_errno-received);
    if (n>0) { received+=(size_t)n; continue; }
    if (n<0 && errno==EINTR) continue;
    if (n<0) { error=uv_translate_sys_error(errno); goto done; }
    break;
  }
  if (received) { error=received==sizeof child_errno ? uv_translate_sys_error(child_errno) : UV_EIO; goto done; }
  if (fcntl(t->master,F_SETFD,FD_CLOEXEC)<0) { error=uv_translate_sys_error(errno); goto done; }
  if ((error=uv_poll_init(loop,&t->poll,t->master))) goto done;
  t->poll_init=true; t->handles++; t->poll.data=t;
  if ((error=refresh(t))) goto done;
  reap(t); /* One startup race check; no frame-time child polling. */
done:
  if (pipefd[0]>=0) close(pipefd[0]); if (pipefd[1]>=0) close(pipefd[1]); free(fds); free(environment);
  if (error && t) { bpty_destroy(t); t=NULL; }
  if (error_out) *error_out=error;
  return t;
}
#else
struct bpty { int unused; };
bpty *bpty_open(uv_loop_t *loop,bterm *core,bpty_options options,int *error) { (void)loop;(void)core;(void)options;if(error)*error=UV_ENOSYS;return NULL; }
void bpty_destroy(bpty *t) { (void)t; }
void bpty_shutdown(uv_loop_t *loop) { (void)loop; }
int bpty_write(bpty *t,const uint8_t *bytes,size_t n) { (void)t;(void)bytes;(void)n;return UV_ENOSYS; }
int bpty_resize(bpty *t,unsigned c,unsigned r) { (void)t;(void)c;(void)r;return UV_ENOSYS; }
bpty_status bpty_state(const bpty *t) { (void)t;return (bpty_status){.error=UV_ENOSYS,.exited=true,.eof=true,.exit_status=-1}; }
int bpty_foreground_group(const bpty *t,int64_t *group) { (void)t;(void)group;return UV_ENOSYS; }
#endif
