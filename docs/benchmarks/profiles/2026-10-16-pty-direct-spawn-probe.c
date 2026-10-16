#include <util.h>
#include <spawn.h>
#include <unistd.h>
#include <sys/wait.h>
#include <sys/ioctl.h>
#include <stdio.h>
#include <string.h>
#include <signal.h>
#include <fcntl.h>
extern char **environ;
int main(int argc,char **argv){
 if(argc==2){int ok=isatty(0)&&isatty(1)&&isatty(2)&&getsid(0)==getpid()&&getpgrp()==getpid()&&tcgetpgrp(0)==getpid();dprintf(1,"session=%d pgid=%d tty_group=%d self=%d\r\n",getsid(0),getpgrp(),tcgetpgrp(0),getpid());return ok?0:1;}
 int master,slave;struct winsize size={.ws_col=80,.ws_row=24};char path[1024];
 if(openpty(&master,&slave,NULL,NULL,&size)||ttyname_r(slave,path,sizeof path))return 2;
 posix_spawn_file_actions_t actions;posix_spawnattr_t attr;int e;
 if((e=posix_spawn_file_actions_init(&actions))||(e=posix_spawnattr_init(&attr)))return 3;
 if((e=posix_spawn_file_actions_addopen(&actions,0,path,O_RDWR,0))||(e=posix_spawn_file_actions_adddup2(&actions,0,1))||(e=posix_spawn_file_actions_adddup2(&actions,0,2)))return 4;
 if((e=posix_spawnattr_setflags(&attr,POSIX_SPAWN_SETSID|POSIX_SPAWN_CLOEXEC_DEFAULT)))return 5;
 char *args[]={argv[0],"--child",NULL};pid_t pid;
 e=posix_spawn(&pid,argv[0],&actions,&attr,args,environ);close(slave);
 if(e){fprintf(stderr,"spawn errno=%d\n",e);return 6;}
 char b[1024];ssize_t n;while((n=read(master,b,sizeof b))>0)write(1,b,n);
 int status;if(waitpid(pid,&status,0)<0)return 7;
 return WIFEXITED(status)?WEXITSTATUS(status):8;
}
