#import <Foundation/Foundation.h>
#import "AxsCacheKeeperStandaloneDiagnostics.h"
#include <roothide.h>
#include <mach-o/dyld.h>
#include <sys/types.h>
#include <sys/wait.h>
#include <sys/stat.h>
#include <poll.h>
#include <fcntl.h>
#include <signal.h>
#include <unistd.h>
#include <errno.h>
#include <limits.h>
#include <math.h>
#include <stdlib.h>
#include <string.h>

// Fork before any Foundation work, then exec a fresh worker. No Objective-C state
// or dispatch queue crosses fork; the launcher only waits for a persisted report.
static int AxsCacheKeeperDiagnoseBackground(int argc,char *argv[]) {
    char executable[PATH_MAX];uint32_t length=sizeof(executable);
    if(_NSGetExecutablePath(executable,&length))return 30;
    int channel[2];if(pipe(channel))return 31;
    pid_t child=fork();
    if(child<0){close(channel[0]);close(channel[1]);return 32;}
    if(!child){
        close(channel[0]);if(setsid()<0)_exit(33);
        int null=open("/dev/null",O_RDWR);if(null<0)_exit(34);
        if(dup2(null,STDIN_FILENO)<0 || dup2(null,STDOUT_FILENO)<0 || dup2(null,STDERR_FILENO)<0)_exit(34);
        if(null>STDERR_FILENO)close(null);
        char descriptor[32];snprintf(descriptor,sizeof(descriptor),"%d",channel[1]);
        char **arguments=calloc((size_t)argc+3,sizeof(char *));if(!arguments)_exit(35);
        arguments[0]=executable;arguments[1]="--worker-fd";arguments[2]=descriptor;int offset=3;
        for(int i=1;i<argc;i++)if(strcmp(argv[i],"--background"))arguments[offset++]=argv[i];
        arguments[offset]=NULL;execv(executable,arguments);_exit(36);
    }
    close(channel[1]);char response[8192];size_t used=0;BOOL complete=NO;
    for(int rounds=0;rounds<150 && used<sizeof(response)-1;rounds++){
        struct pollfd ready={channel[0],POLLIN|POLLHUP,0};int result=poll(&ready,1,100);
        if(result<0 && errno==EINTR)continue;if(result<0)break;
        if(result>0){ssize_t count=read(channel[0],response+used,sizeof(response)-1-used);if(count<0 && errno==EINTR)continue;if(count<=0)break;used+=(size_t)count;if(memchr(response,'\n',used)){complete=YES;break;}}
    }
    close(channel[0]);
    if(!complete){
        // This is only our newly created child, never a target application.
        kill(child,SIGTERM);
        for(int attempts=0;attempts<20;attempts++){
            pid_t done=waitpid(child,NULL,WNOHANG);if(done==child || (done<0 && errno==ECHILD))break;usleep(50000);
        }
        fputs("Collector did not acknowledge a writable report; collection was not started.\n",stderr);return 37;
    }
    response[used]=0;fwrite(response,1,used,stdout);return 0;
}
int main(int argc,char *argv[]) {
    BOOL background=NO;int ready=-1;const char *output=NULL;double seconds=90;
    for(int i=1;i<argc;i++){
        if(!strcmp(argv[i],"--background"))background=YES;
        else if(!strcmp(argv[i],"--worker-fd") && i+1<argc){char *end=NULL;long value=strtol(argv[++i],&end,10);if(!end || *end || value<3 || value>INT_MAX)return 10;ready=(int)value;}
        else if(!strcmp(argv[i],"--output") && i+1<argc)output=argv[++i];
        else if(!strcmp(argv[i],"--duration") && i+1<argc){char *end=NULL;seconds=strtod(argv[++i],&end);if(!end || *end || !isfinite(seconds) || seconds<1 || seconds>600)return 10;}
        else {fputs("Usage: ckdiagnose --background --output ABSOLUTE_DIRECTORY [--duration 90]\n",stderr);return 10;}
    }
    if(!output || output[0]!='/' || strchr(output,'\n') || strchr(output,'\r') || (background && ready>=0))return 10;
    if(background)return AxsCacheKeeperDiagnoseBackground(argc,argv);
    if(ready<0){fputs("Use --background to start the bounded collector.\n",stderr);return 10;}
    @autoreleasepool {
        NSString *base=[NSString stringWithUTF8String:output];if(!base)return 10;
        return axs_cachekeeper_diagnose_collect(base,jbroot(@"/var/mobile/Library/CacheKeeper"),
            @[@"/var/mobile/Library/Logs/CrashReporter",@"/Library/Logs/CrashReporter"],seconds,ready);
    }
}
