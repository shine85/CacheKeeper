#include <stdio.h>
#include <string.h>
#include "AxsCacheKeeperImageCacheStatus.h"

#ifndef AXS_CACHEKEEPER_IMAGE_ADMISSION_DEFINED
int main(void) { fputs("FAIL: image-admission: initializer returns have no diagnostic accounting\n",stderr); return 1; }
#else
#define REQUIRE(c,m) do { if (!(c)) {fprintf(stderr,"FAIL: image-admission: %s\n",m);return 1;} } while (0)
int main(void) {
    AxsCacheKeeperImageAdmission ledger={0};
    REQUIRE(AxsCacheKeeperImageAdmissionValid(&ledger,0),"empty ledger is valid");
    AxsCacheKeeperImageAdmissionRecord(&ledger,(AxsCacheKeeperImageReason)999);
    REQUIRE(!ledger.initializerReturns && AxsCacheKeeperImageAdmissionValid(&ledger,0),"invalid reason cannot write outside the bounded ledger");
    AxsCacheKeeperImageAdmissionRecord(&ledger,AxsCacheKeeperImageReasonNone);
    AxsCacheKeeperImageAdmissionRecord(&ledger,AxsCacheKeeperImageReasonDiskMissing);
    AxsCacheKeeperImageAdmissionRecord(&ledger,AxsCacheKeeperImageReasonInitializerReturnedNil);
    REQUIRE(ledger.initializerReturns==3 && ledger.registered==1 && ledger.unregistered==2,
        "early returns do not erase registered owners");
    REQUIRE(ledger.unregisteredReasons[AxsCacheKeeperImageReasonDiskMissing]==1 &&
        ledger.unregisteredReasons[AxsCacheKeeperImageReasonInitializerReturnedNil]==1,
        "each early failure retains its fixed reason");
    REQUIRE(AxsCacheKeeperImageAdmissionValid(&ledger,1),"live ledger closes");
    AxsCacheKeeperImageAdmissionRelease(&ledger);
    REQUIRE(ledger.released==1 && AxsCacheKeeperImageAdmissionValid(&ledger,0),"released owner remains counted");
    AxsCacheKeeperImageAdmissionRecord(&ledger,AxsCacheKeeperImageReasonNone);
    REQUIRE(ledger.released==1 && ledger.registered==2 && AxsCacheKeeperImageAdmissionValid(&ledger,1),"new owner cannot erase released count");
    AxsCacheKeeperImageAdmission bad=ledger;bad.initializerReturns++;
    REQUIRE(!AxsCacheKeeperImageAdmissionValid(&bad,1),"inconsistent returns rejected");
    bad=ledger;bad.unregisteredReasons[AxsCacheKeeperImageReasonDiskMissing]++;
    REQUIRE(!AxsCacheKeeperImageAdmissionValid(&bad,1),"inconsistent reasons rejected");
    bad=ledger;bad.unregisteredReasons[AxsCacheKeeperImageReasonQueueIdentity]=1;
    REQUIRE(!AxsCacheKeeperImageAdmissionValid(&bad,1),"non-early reason cannot impersonate early return");
    REQUIRE(!AxsCacheKeeperImageAdmissionValid(&ledger,0),"live owner cannot disappear without release");
    bad=ledger;bad.overflow=true;
    REQUIRE(!AxsCacheKeeperImageAdmissionValid(&bad,1),"unsaturated overflow flag rejected");
    bad=ledger;bad.registered=AXS_CACHEKEEPER_IMAGE_ADMISSION_MAX+1;
    REQUIRE(!AxsCacheKeeperImageAdmissionValid(&bad,1),"over-range values rejected");
    REQUIRE(!AxsCacheKeeperImageAdmissionValid(&ledger,65),"live registry bound retained");
    AxsCacheKeeperImageAdmission full={0};
    full.initializerReturns=full.unregistered=AXS_CACHEKEEPER_IMAGE_ADMISSION_MAX;
    full.unregisteredReasons[AxsCacheKeeperImageReasonDiskMissing]=AXS_CACHEKEEPER_IMAGE_ADMISSION_MAX;
    REQUIRE(AxsCacheKeeperImageAdmissionValid(&full,0) && !full.overflow,"exact maximum is not overflow");
    AxsCacheKeeperImageAdmissionRecord(&full,AxsCacheKeeperImageReasonQueueMissing);
    REQUIRE(full.initializerReturns==AXS_CACHEKEEPER_IMAGE_ADMISSION_MAX && full.overflow &&
        full.unregisteredReasons[AxsCacheKeeperImageReasonQueueMissing]==1 &&
        AxsCacheKeeperImageAdmissionValid(&full,0),"saturated cumulative totals still close");
    bad=full;bad.overflow=false;
    REQUIRE(!AxsCacheKeeperImageAdmissionValid(&bad,0),"truncated sums cannot hide overflow");
    AxsCacheKeeperImageAdmissionRecord(&full,AxsCacheKeeperImageReasonNone);
    AxsCacheKeeperImageAdmissionRelease(&full);
    REQUIRE(full.registered==1 && full.released==1 && AxsCacheKeeperImageAdmissionValid(&full,0),"overflow does not stop new lifecycle accounting");
    for (unsigned i=0;i<AxsCacheKeeperImageReasonCount;i++) {
        const char *name=AxsCacheKeeperImageReasonName(i);
        REQUIRE(name && AxsCacheKeeperImageReasonParse(name)==i,"reason vocabulary round trips");
    }
    REQUIRE(AxsCacheKeeperImageReasonParse("/private/personal-name")==AxsCacheKeeperImageReasonUnclassified,
        "unknown values never become exported labels");
    puts("PASS: image-admission core lifecycle, closed reasons and saturation");return 0;
}
#endif
