/* Development-only per-PID sampling. Never linked into the product. */
#define _DEFAULT_SOURCE
#define _DARWIN_C_SOURCE
#define _POSIX_C_SOURCE 200809L
#include <uv.h>
#include <errno.h>
#include <inttypes.h>
#include <limits.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#if defined(__APPLE__)
#include <libproc.h>
#include <mach/mach_time.h>
#include <sys/resource.h>
#elif !defined(__linux__)
#error process_sample requires macOS or Linux
#endif

typedef struct {
  int pid;
  uint64_t sampled_ns, start_ticks, user_ns, system_ns, rss_bytes;
} Sample;
static uint64_t numerator,denominator;

static int convert(uint64_t ticks,uint64_t *ns) {
  uint64_t whole=ticks/denominator,rest=ticks%denominator;
  if (whole>UINT64_MAX/numerator || rest>UINT64_MAX/numerator) return -1;
  uint64_t fraction=rest*numerator/denominator;
  if (whole*numerator>UINT64_MAX-fraction) return -1;
  *ns=whole*numerator+fraction;return 0;
}
static int sample(int pid,Sample *out) {
  *out=(Sample){.pid=pid};
#if defined(__APPLE__)
  struct rusage_info_v0 info={0};
  if (proc_pid_rusage(pid,RUSAGE_INFO_V0,(rusage_info_t *)&info)) return -1;
  if (info.ri_proc_exit_abstime || !info.ri_resident_size) return -1;
  if (convert(info.ri_user_time,&out->user_ns) || convert(info.ri_system_time,&out->system_ns)) return -1;
  out->start_ticks=info.ri_proc_start_abstime;out->rss_bytes=info.ri_resident_size;
#else
  char path[64],line[8192];
  snprintf(path,sizeof path,"/proc/%d/stat",pid);
  FILE *f=fopen(path,"r");if (!f) return -1;
  size_t n=fread(line,1,sizeof line-1,f);int failed=ferror(f);fclose(f);
  if (failed || !n || n==sizeof line-1) return -1;
  line[n]=0;
  /* comm can contain spaces, newlines and parentheses; fields follow its LAST
   * closing parenthesis. Do not split the whole file on whitespace. */
  char *end=strrchr(line,')'),*save=NULL;
  if (!end || end[1]!=' ') return -1;
  char *token=strtok_r(end+2," \n",&save);unsigned field=3,found=0;
  uint64_t user=0,system=0,pages=0;
  for (;token;token=strtok_r(NULL," \n",&save),field++) {
    if (field==3 && (!strcmp(token,"Z") || !strcmp(token,"X"))) return -1;
    if (field!=14 && field!=15 && field!=22 && field!=24) continue;
    if (*token<'0' || *token>'9') return -1;
    errno=0;char *tail;uint64_t value=strtoull(token,&tail,10);
    if (errno || *tail) return -1;
    if (field==14) user=value;
    if (field==15) system=value;
    if (field==22) out->start_ticks=value;
    if (field==24) pages=value;
    found++;
  }
  long page_size=sysconf(_SC_PAGESIZE);
  if (found!=4 || page_size<=0 || !pages || pages>UINT64_MAX/(uint64_t)page_size) return -1;
  out->rss_bytes=pages*(uint64_t)page_size;
  if (convert(user,&out->user_ns) || convert(system,&out->system_ns)) return -1;
#endif
  out->sampled_ns=uv_hrtime();return 0;
}
static int self_test(void) {
  Sample before,after;size_t rss=0;
  if (sample((int)getpid(),&before) || uv_resident_set_memory(&rss) || !rss) return 1;
  volatile uint64_t work=1;uint64_t start=uv_hrtime();
  while (uv_hrtime()-start<200000000) work=work*1664525+1013904223;
  (void)work;
  if (sample((int)getpid(),&after)) return 1;
  uint64_t cpu=after.user_ns+after.system_ns-before.user_ns-before.system_ns;
  /* This fails on Apple Silicon if Mach ticks are mislabeled nanoseconds.
   * Wide bounds tolerate a loaded test host; this is a units check, not a
   * production performance budget. */
  if (cpu<20000000 || cpu>1000000000 || before.start_ticks!=after.start_ticks ||
      before.rss_bytes<rss/4 || before.rss_bytes>rss*4) return 1;
  puts("process sampler: native RSS, stable identity, monotonic timestamps and CPU units passed");return 0;
}
int main(int argc,char **argv) {
#if defined(__APPLE__)
  mach_timebase_info_data_t timebase;
  if (mach_timebase_info(&timebase)!=KERN_SUCCESS) return 1;
  numerator=timebase.numer;denominator=timebase.denom;
  const char *source="macOS proc_pid_rusage v0; CPU Mach ticks converted with mach_timebase_info; RSS bytes";
#else
  long hz=sysconf(_SC_CLK_TCK);if (hz<=0) return 1;
  numerator=1000000000;denominator=(uint64_t)hz;
  const char *source="Linux /proc/PID/stat; CPU clock ticks converted with _SC_CLK_TCK; RSS pages times _SC_PAGESIZE";
#endif
  if (!numerator || !denominator) return 1;
  if (argc==2 && !strcmp(argv[1],"--self-test")) return self_test();
  if (argc<2 || argc>259) { fputs("usage: termbench_sample PID... (up to 258)\n",stderr);return 2; }
  Sample samples[258];
  for (int i=1;i<argc;i++) {
    errno=0;char *tail;long pid=strtol(argv[i],&tail,10);
    if (errno || argv[i][0]<'0' || argv[i][0]>'9' || *tail || pid<1 || pid>INT_MAX) return 2;
    for (int j=0;j<i-1;j++) if (samples[j].pid==pid) return 2;
    if (sample((int)pid,&samples[i-1])) { fprintf(stderr,"cannot sample live PID %ld\n",pid);return 1; }
  }
  printf("{\"schema\":1,\"source\":\"%s\",\"cpu_timebase_numer\":%"PRIu64",\"cpu_timebase_denom\":%"PRIu64",\"processes\":[",source,numerator,denominator);
  for (int i=0;i<argc-1;i++) {
    Sample *s=&samples[i];
    printf("%s{\"pid\":%d,\"sampled_ns\":%"PRIu64",\"start_ticks\":%"PRIu64",\"user_ns\":%"PRIu64",\"system_ns\":%"PRIu64",\"rss_bytes\":%"PRIu64"}",
      i ? "," : "",s->pid,s->sampled_ns,s->start_ticks,s->user_ns,s->system_ns,s->rss_bytes);
  }
  puts("]}");return 0;
}
