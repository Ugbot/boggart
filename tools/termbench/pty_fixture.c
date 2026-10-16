/* One raw input byte paints cell 1,1 with (byte,64,192). No shell or echo. */
#define _DEFAULT_SOURCE
#include <errno.h>
#include <stdio.h>
#include <termios.h>
#include <unistd.h>

static int paint(unsigned char byte) {
  char output[96];
  int n=snprintf(output,sizeof output,"\033[?25l\033[H\033[48;2;%u;64;192m \033[0m",byte);
  size_t at=0;
  while (at<(size_t)n) {
    ssize_t written=write(STDOUT_FILENO,output+at,(size_t)n-at);
    if (written<0 && errno==EINTR) continue;
    if (written<=0) return 1;
    at+=(size_t)written;
  }
  return 0;
}
int main(void) {
  struct termios saved,raw;
  if (tcgetattr(STDIN_FILENO,&saved)) return 2;
  raw=saved; cfmakeraw(&raw);
  if (tcsetattr(STDIN_FILENO,TCSANOW,&raw)) return 3;
  int status=paint(0);
  while (!status) {
    unsigned char byte;
    ssize_t n=read(STDIN_FILENO,&byte,1);
    if (n<0 && errno==EINTR) continue;
    if (n<=0) { status=n<0 ? 4 : 0; break; }
    status=paint(byte);
  }
  tcsetattr(STDIN_FILENO,TCSANOW,&saved);
  return status;
}
