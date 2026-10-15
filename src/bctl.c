/* Native shell/hook client. Runs before Lua/store/model startup. */
#include "bctl.h"
#include <curl/curl.h>
#include "cJSON.h"
#include "uv.h"
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <signal.h>
#ifndef _WIN32
#include <errno.h>
#include <sys/stat.h>
#include <unistd.h>
#endif
#define RESPONSE_LIMIT 65536u
typedef struct {char *data;size_t length;} response;
typedef struct {
  const char *socket,*pane,*token;char agent[160],lease[128];
  uv_loop_t loop;uv_process_t process;uv_timer_t timer;uv_signal_t signals[3];
  int timers,signal_count,exit_status,term_signal,heartbeat_failed;
} wrapper;
static size_t receive(void *bytes,size_t size,size_t count,void *context) {
  response *r=context;
  if(size && count>RESPONSE_LIMIT/size)return 0;
  size_t n=size*count;if(n>RESPONSE_LIMIT-r->length)return 0;
  char *next=realloc(r->data,r->length+n+1);if(!next)return 0;r->data=next;
  memcpy(r->data+r->length,bytes,n);r->length+=n;r->data[r->length]=0;return n;
}
static int private_socket(const char *path) {
#ifdef _WIN32
  (void)path;return 0;
#else
  struct stat info;
  if(!path || path[0]!='/' || lstat(path,&info) || !S_ISSOCK(info.st_mode) || info.st_uid!=geteuid() || (info.st_mode&077))return 0;
  char parent[4096];size_t n=strlen(path);if(n>=sizeof parent)return 0;memcpy(parent,path,n+1);
  char *slash=strrchr(parent,'/');if(!slash || slash==parent)return 0;*slash=0;
  return !lstat(parent,&info) && S_ISDIR(info.st_mode) && info.st_uid==geteuid() && !(info.st_mode&077);
#endif
}
static int request(const char *socket,const char *path,cJSON *body,response *out) {
  if(!private_socket(socket))return -1;
  CURL *curl=curl_easy_init();if(!curl)return -1;
  char url[256];snprintf(url,sizeof url,"http://localhost%s",path);
  char *encoded=body ? cJSON_PrintUnformatted(body) : NULL;
  if(body && !encoded){curl_easy_cleanup(curl);return -1;}
  struct curl_slist *headers=curl_slist_append(NULL,"Content-Type: application/json");
  curl_easy_setopt(curl,CURLOPT_URL,url);curl_easy_setopt(curl,CURLOPT_UNIX_SOCKET_PATH,socket);
  curl_easy_setopt(curl,CURLOPT_PROXY,"");curl_easy_setopt(curl,CURLOPT_NOSIGNAL,1L);
  curl_easy_setopt(curl,CURLOPT_TIMEOUT_MS,1500L);curl_easy_setopt(curl,CURLOPT_CONNECTTIMEOUT_MS,500L);
  curl_easy_setopt(curl,CURLOPT_PROTOCOLS_STR,"http");curl_easy_setopt(curl,CURLOPT_HTTPHEADER,headers);
  curl_easy_setopt(curl,CURLOPT_WRITEFUNCTION,receive);curl_easy_setopt(curl,CURLOPT_WRITEDATA,out);
  if(encoded){curl_easy_setopt(curl,CURLOPT_POSTFIELDS,encoded);curl_easy_setopt(curl,CURLOPT_POSTFIELDSIZE,(long)strlen(encoded));}
  CURLcode error=curl_easy_perform(curl);long status=0;curl_easy_getinfo(curl,CURLINFO_RESPONSE_CODE,&status);
  curl_slist_free_all(headers);free(encoded);curl_easy_cleanup(curl);
  return error==CURLE_OK ? (int)status : -1;
}
static cJSON *context(wrapper *w) {
  cJSON *body=cJSON_CreateObject();if(!body)return NULL;
  cJSON_AddStringToObject(body,"pane",w->pane);cJSON_AddStringToObject(body,"pane_token",w->token);
  if(w->agent[0]){cJSON_AddStringToObject(body,"agent_id",w->agent);cJSON_AddStringToObject(body,"lease",w->lease);}
  return body;
}
static int report(wrapper *w,const char *path,int finish) {
  cJSON *body=context(w);if(!body)return -1;
  cJSON_AddNumberToObject(body,"pid",w->process.pid);
  if(finish){cJSON_AddNumberToObject(body,"exit_status",w->exit_status);cJSON_AddNumberToObject(body,"term_signal",w->term_signal);}
  response out={0};int status=request(w->socket,path,body,&out);free(out.data);cJSON_Delete(body);return status;
}
static void heartbeat(uv_timer_t *timer) {
  wrapper *w=timer->data;int status=report(w,"/bmux/agents/heartbeat",0);
  if(status!=200 && !w->heartbeat_failed){fputs("bmux: Fleet connection lost; command continues\n",stderr);w->heartbeat_failed=1;}
  if(status==200)w->heartbeat_failed=0;
}
static void signal_received(uv_signal_t *signal,int signum) {
  wrapper *w=signal->data;
  /* Terminal INT/QUIT reaches the entire foreground group already. Forwarding
   * it again would turn an agent's first interrupt into a second quit. */
  if(signum==SIGTERM)uv_process_kill(&w->process,signum);
}
static void close_support(wrapper *w) {
  if(w->timers){uv_timer_stop(&w->timer);uv_close((uv_handle_t *)&w->timer,NULL);w->timers=0;}
  for(int i=0;i<w->signal_count;i++){uv_signal_stop(&w->signals[i]);uv_close((uv_handle_t *)&w->signals[i],NULL);}w->signal_count=0;
}
static void exited(uv_process_t *process,int64_t status,int signal) {
  wrapper *w=process->data;w->exit_status=(int)status;w->term_signal=signal;
  uv_close((uv_handle_t *)process,NULL);close_support(w);
}
static int copy_field(cJSON *object,const char *key,char *out,size_t capacity) {
  cJSON *value=cJSON_GetObjectItemCaseSensitive(object,key);
  if(!cJSON_IsString(value) || !value->valuestring || !*value->valuestring || strlen(value->valuestring)>=capacity)return 0;
  memcpy(out,value->valuestring,strlen(value->valuestring)+1);return 1;
}
/* Explicit wrapping must not re-enter an automatic wrapper. Only the root
 * executable lookup skips the private bin; children retain PATH for nested
 * agents. Directory identity also handles aliases/trailing slashes in PATH. */
static const char *command_file(const char *command,char resolved[4096]) {
#ifndef _WIN32
  const char *bin=getenv("BOGGART_AGENT_BIN");struct stat wrapper_dir;
  if(bin && !stat(bin,&wrapper_dir) && S_ISDIR(wrapper_dir.st_mode)) {
    const char *slash=strrchr(command,'/');
    if(slash) {
      size_t length=(size_t)(slash-command);char directory[4096];struct stat info;
      if(length>=sizeof directory)return command;
      if(!length){directory[0]='/';length=1;}else memcpy(directory,command,length);
      directory[length]=0;
      if(stat(directory,&info) || info.st_dev!=wrapper_dir.st_dev || info.st_ino!=wrapper_dir.st_ino)return command;
      command=slash+1;
    }
    const char *path=getenv("PATH");if(!path)path="/usr/bin:/bin";
    for(;;) {
      const char *end=strchr(path,':');size_t n=end ? (size_t)(end-path) : strlen(path);
      if(n<4096) {
        char directory[4096];memcpy(directory,path,n);directory[n]=0;
        struct stat info;const char *dir=n ? directory : ".";
        int wrapper=!stat(dir,&info) && info.st_dev==wrapper_dir.st_dev && info.st_ino==wrapper_dir.st_ino;
        int size=snprintf(resolved,4096,"%s/%s",dir,command);
        if(!wrapper && size>0 && size<4096 && !stat(resolved,&info) && S_ISREG(info.st_mode) && !access(resolved,X_OK))return resolved;
      }
      if(!end)break;path=end+1;
    }
    /* The injected boggart command also exists when no installation is on PATH. */
    size_t size=4096;if(!strcmp(command,"boggart") && !uv_exepath(resolved,&size))return resolved;
    return NULL;
  }
#else
  (void)resolved;
#endif
  return command;
}
static int unregistered(char **argv) {
  fputs("bmux: Fleet unavailable; starting agent without registration\n",stderr);
#ifndef _WIN32
  char resolved[4096];const char *file=command_file(argv[0],resolved);
  if(file)execvp(file,argv);
  fprintf(stderr,"bmux: launch failed: %s\n",file ? strerror(errno) : "command not found");return 127;
#else
  (void)argv;return 125;
#endif
}
static int run(wrapper *w,const char *provider,const char *name,char **argv,int best_effort) {
  cJSON *body=context(w);if(!body)return best_effort ? unregistered(argv) : 125;
  cJSON_AddStringToObject(body,"provider",provider);cJSON_AddStringToObject(body,"name",name);
  char cwd[4096];size_t size=sizeof cwd;if(!uv_cwd(cwd,&size))cJSON_AddStringToObject(body,"cwd",cwd);
  response out={0};int status=request(w->socket,"/bmux/agents/register",body,&out);cJSON_Delete(body);
  cJSON *result=out.data ? cJSON_ParseWithLength(out.data,out.length) : NULL;
  int valid=status==201 && result && copy_field(result,"agent_id",w->agent,sizeof w->agent) && copy_field(result,"lease",w->lease,sizeof w->lease);
  cJSON_Delete(result);free(out.data);
  if(!valid){if(best_effort)return unregistered(argv);fputs("bmux: agent registration unavailable\n",stderr);return 125;}
  if(uv_loop_init(&w->loop)){w->exit_status=127;report(w,"/bmux/agents/finish",1);return 127;}
  uv_stdio_container_t stdio[3]={0};for(int i=0;i<3;i++){stdio[i].flags=UV_INHERIT_FD;stdio[i].data.fd=i;}
  char resolved[4096];uv_process_options_t opts={0};opts.file=command_file(argv[0],resolved);opts.args=argv;opts.stdio=stdio;opts.stdio_count=3;opts.exit_cb=exited;
  w->process.data=w;
  int error=opts.file ? uv_spawn(&w->loop,&w->process,&opts) : UV_ENOENT;
  if(error) {
    fprintf(stderr,"bmux: launch failed: %s\n",uv_strerror(error));w->exit_status=127;
    if(w->process.type==UV_PROCESS)uv_close((uv_handle_t *)&w->process,NULL);
  } else {
    if(!uv_timer_init(&w->loop,&w->timer)){w->timers=1;w->timer.data=w;uv_timer_start(&w->timer,heartbeat,0,1000);}
#ifndef _WIN32
    const int signals[]={SIGINT,SIGQUIT,SIGTERM};
    for(unsigned i=0;i<3;i++) {
      uv_signal_t *handle=&w->signals[w->signal_count];
      if(uv_signal_init(&w->loop,handle))break;w->signal_count++;handle->data=w;
      uv_signal_start(handle,signal_received,signals[i]);
    }
#endif
  }
  uv_run(&w->loop,UV_RUN_DEFAULT);uv_loop_close(&w->loop);
  (void)report(w,"/bmux/agents/finish",1);
  return w->term_signal ? 128+w->term_signal : w->exit_status;
}
static int usage(void) {
  fputs("usage: boggart ctl [--socket PATH] health|agents\n"
        "       boggart ctl [--socket PATH] agents [--offset N] [--limit N]\n"
        "       boggart ctl [--socket PATH] run [--best-effort] [--provider NAME] [--name LABEL] -- COMMAND [ARG...]\n",stderr);return 2;
}
static int run_command(wrapper *w,int argc,char **argv,int i) {
  const char *provider="custom",*name=NULL;int best_effort=0;
  while(i<argc && strcmp(argv[i],"--")) {
    if(!strcmp(argv[i],"--provider") && i+1<argc){provider=argv[i+1];i+=2;}
    else if(!strcmp(argv[i],"--name") && i+1<argc){name=argv[i+1];i+=2;}
    else if(!strcmp(argv[i],"--best-effort")){best_effort=1;i++;}
    else break;
  }
  if(i>=argc || strcmp(argv[i],"--") || ++i>=argc || argc-i>1024 || !*provider || strlen(provider)>128)return usage();
  if(!name){const char *slash=strrchr(argv[i],'/');name=slash ? slash+1 : argv[i];}
  if(!*name || strlen(name)>256)return usage();
  if(!private_socket(w->socket) || !w->pane || !*w->pane || strlen(w->pane)>128 || !w->token || !*w->token || strlen(w->token)>128) {
    if(best_effort)return unregistered(&argv[i]);
    fputs("bmux: private control socket or pane context unavailable\n",stderr);return 125;
  }
  if(curl_global_init(CURL_GLOBAL_DEFAULT)!=CURLE_OK){if(best_effort)return unregistered(&argv[i]);return 125;}
  int code=run(w,provider,name,&argv[i],best_effort);curl_global_cleanup();return code;
}
int boggart_ctl_main(int argc,char **argv) {
  wrapper w={0};w.socket=getenv("BOGGART_SOCKET");w.pane=getenv("BOGGART_PANE_ID");w.token=getenv("BOGGART_PANE_TOKEN");
  int i=0;if(argc>1 && !strcmp(argv[0],"--socket")){w.socket=argv[1];i=2;}
  if(i>=argc)return usage();const char *verb=argv[i++];
  if(!strcmp(verb,"--help") || !strcmp(verb,"help")){usage();return 0;}
  if(!strcmp(verb,"run"))return run_command(&w,argc,argv,i);
  if(!w.socket || !private_socket(w.socket)){fputs("bmux: private control socket unavailable\n",stderr);return 1;}
  if(curl_global_init(CURL_GLOBAL_DEFAULT)!=CURLE_OK)return 1;
  int code=1;
  if(!strcmp(verb,"health") && i==argc) {
    response out={0};int status=request(w.socket,"/health",NULL,&out);
    if(status==200){if(out.data)fwrite(out.data,1,out.length,stdout);fputc('\n',stdout);code=0;}
    else fprintf(stderr,"bmux: health request failed (%d)\n",status);
    free(out.data);
  } else if(!w.pane || !*w.pane || strlen(w.pane)>128 || !w.token || !*w.token || strlen(w.token)>128){fputs("bmux: this shell has no valid pane context\n",stderr);code=2;}
  else if(!strcmp(verb,"agents")) {
    long offset=0,limit=64;int valid=1;
    while(i<argc) {
      const char *option=argv[i++];if(i>=argc){valid=0;break;}
      char *end=NULL;const char *value=argv[i++];long number=strtol(value,&end,10);
      if(!*value || *end || number<0 || number>4096){valid=0;break;}
      if(!strcmp(option,"--offset"))offset=number;
      else if(!strcmp(option,"--limit") && number>=1 && number<=64)limit=number;
      else {valid=0;break;}
    }
    if(!valid){curl_global_cleanup();return usage();}
    cJSON *body=context(&w);if(body){cJSON_AddNumberToObject(body,"offset",offset);cJSON_AddNumberToObject(body,"limit",limit);}
    response out={0};int status=body ? request(w.socket,"/bmux/agents/list",body,&out) : -1;
    cJSON_Delete(body);if(status==200){if(out.data)fwrite(out.data,1,out.length,stdout);fputc('\n',stdout);code=0;}
    else fprintf(stderr,"bmux: agent list failed (%d)\n",status);free(out.data);
  } else code=usage();
  curl_global_cleanup();return code;
}
