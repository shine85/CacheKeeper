#include "AxsCacheKeeperResourceLayout.h"
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#define REQUIRE(value, message) do { if (!(value)) { fprintf(stderr,"FAIL: resource-layout: %s\n",message); return 1; } } while (0)
static AxsCacheKeeperResourcePart part(const char *p) { return (AxsCacheKeeperResourcePart){(const unsigned char *)p,strlen(p)}; }
int main(void) {
    AxsCacheKeeperResourcePart p[]={part("PRIVATE_OUTER"),part("PRIVATE_ACCOUNT"),part("postbox"),part("media"),part("cache")};
    REQUIRE(axs_cachekeeper_resource_category(AxsCacheKeeperResourceLayoutPlatform,p,4)==AxsCacheKeeperResourceUnknown,"other app never gains private classification");
    REQUIRE(axs_cachekeeper_resource_category(AxsCacheKeeperResourceLayoutSwiftgramGroup,p,3)==AxsCacheKeeperResourcePostbox,"nested Postbox structure classified");
    REQUIRE(axs_cachekeeper_resource_category(AxsCacheKeeperResourceLayoutSwiftgramGroup,p,4)==AxsCacheKeeperResourcePostboxMedia,"media separated from database");
    REQUIRE(axs_cachekeeper_resource_category(AxsCacheKeeperResourceLayoutSwiftgramGroup,p,5)==AxsCacheKeeperResourcePostboxCache,"cache descendants retain exact structure");
    p[4]=part("short-cache");
    AxsCacheKeeperResourceCategory shortCache=axs_cachekeeper_resource_category(AxsCacheKeeperResourceLayoutSwiftgramGroup,p,5);
    REQUIRE(!strcmp(axs_cachekeeper_resource_category_name(shortCache),"postboxMediaShortCache"),"short-lived representation directory classified separately");
    REQUIRE(axs_cachekeeper_resource_node_valid(AxsCacheKeeperResourceLayoutSwiftgramGroup,shortCache,AxsCacheKeeperResourcePostboxMedia,5),"short cache has a valid media parent");
    REQUIRE(!axs_cachekeeper_resource_node_valid(AxsCacheKeeperResourceLayoutPlatform,shortCache,AxsCacheKeeperResourcePostboxMedia,5),"platform profile never accepts short cache");
    REQUIRE(!axs_cachekeeper_resource_node_valid(AxsCacheKeeperResourceLayoutSwiftgramGroup,shortCache,AxsCacheKeeperResourcePostboxDatabase,5),"short cache cannot use database parent");
    p[4]=part("animation-cache");
    AxsCacheKeeperResourceCategory animationCache=axs_cachekeeper_resource_category(AxsCacheKeeperResourceLayoutSwiftgramGroup,p,5);
    REQUIRE(!strcmp(axs_cachekeeper_resource_category_name(animationCache),"postboxMediaAnimationCache"),"animation representation directory classified separately");
    REQUIRE(axs_cachekeeper_resource_node_valid(AxsCacheKeeperResourceLayoutSwiftgramGroup,animationCache,AxsCacheKeeperResourcePostboxMedia,5),"animation cache has a valid media parent");
    p[3]=part("db");
    REQUIRE(axs_cachekeeper_resource_category(AxsCacheKeeperResourceLayoutSwiftgramGroup,p,5)==AxsCacheKeeperResourceUnknown,"animation marker in database rejected");
    p[4]=part("short-cache");
    REQUIRE(axs_cachekeeper_resource_category(AxsCacheKeeperResourceLayoutSwiftgramGroup,p,5)==AxsCacheKeeperResourceUnknown,"short marker in database rejected");
    p[4]=part("cache");
    p[3]=part("db");
    REQUIRE(axs_cachekeeper_resource_category(AxsCacheKeeperResourceLayoutSwiftgramGroup,p,4)==AxsCacheKeeperResourcePostboxDatabase,"database kept distinct");
    REQUIRE(axs_cachekeeper_resource_category(AxsCacheKeeperResourceLayoutSwiftgramGroup,p,5)==AxsCacheKeeperResourceUnknown,"cache name inside database is not media cache");
    p[1]=part("logs");
    REQUIRE(axs_cachekeeper_resource_category(AxsCacheKeeperResourceLayoutSwiftgramGroup,p,2)==AxsCacheKeeperResourceLogs,"nested logs identified by structure only");
    p[1]=part("PRIVATE_ACCOUNT");p[2]=part("postbox-backup");p[3]=part("media");
    REQUIRE(axs_cachekeeper_resource_category(AxsCacheKeeperResourceLayoutSwiftgramGroup,p,4)==AxsCacheKeeperResourceUnknown,"similar prefixes rejected");
    p[2]=part("postbox");p[4]=part("cache-private-name");
    REQUIRE(axs_cachekeeper_resource_category(AxsCacheKeeperResourceLayoutSwiftgramGroup,p,5)==AxsCacheKeeperResourceUnknown,"unknown name not exported as category");
    unsigned char raw[]={0xff,0x80};p[0]=(AxsCacheKeeperResourcePart){raw,sizeof(raw)};
    REQUIRE(axs_cachekeeper_resource_category(AxsCacheKeeperResourceLayoutSwiftgramGroup,p,4)==AxsCacheKeeperResourcePostboxMedia,"opaque prefix bytes do not require UTF8");
    p[2]=(AxsCacheKeeperResourcePart){(const unsigned char *)"postbox\0hidden",14};
    REQUIRE(axs_cachekeeper_resource_category(AxsCacheKeeperResourceLayoutSwiftgramGroup,p,4)==AxsCacheKeeperResourceUnknown,"embedded NUL cannot impersonate fixed marker");
    AxsCacheKeeperResourcePart platform[]={part("Library"),part("Caches")};
    REQUIRE(axs_cachekeeper_resource_category(AxsCacheKeeperResourceLayoutPlatform,platform,2)==AxsCacheKeeperResourceCaches,"platform categories unchanged");
    REQUIRE(axs_cachekeeper_resource_node_valid(AxsCacheKeeperResourceLayoutSwiftgramGroup,AxsCacheKeeperResourcePostboxMedia,AxsCacheKeeperResourcePostbox,4),"schema accepts supported parent and depth");
    REQUIRE(!axs_cachekeeper_resource_node_valid(AxsCacheKeeperResourceLayoutPlatform,AxsCacheKeeperResourcePostboxMedia,AxsCacheKeeperResourcePostbox,4),"legacy profile rejects private category");
    REQUIRE(!axs_cachekeeper_resource_node_valid(AxsCacheKeeperResourceLayoutSwiftgramGroup,AxsCacheKeeperResourcePostboxMedia,AxsCacheKeeperResourceUnknown,4),"schema rejects forged media parent");
    REQUIRE(!axs_cachekeeper_resource_node_valid(AxsCacheKeeperResourceLayoutSwiftgramGroup,AxsCacheKeeperResourcePostboxMedia,AxsCacheKeeperResourcePostbox,3),"schema rejects wrong depth");
    REQUIRE(axs_cachekeeper_resource_node_depth(AxsCacheKeeperResourceLayoutPlatform)==3 && axs_cachekeeper_resource_node_depth(AxsCacheKeeperResourceLayoutSwiftgramGroup)==5,"only supported layout expands node depth");
    for (int i=0;i<AxsCacheKeeperResourceCategoryCount;i++) REQUIRE(axs_cachekeeper_resource_category_name((AxsCacheKeeperResourceCategory)i)!=NULL,"all categories have fixed labels");
    REQUIRE(axs_cachekeeper_resource_category_name((AxsCacheKeeperResourceCategory)999)==NULL,"invalid category has no label");
    REQUIRE(!axs_cachekeeper_resource_node_valid((AxsCacheKeeperResourceLayout)999,AxsCacheKeeperResourceUnknown,AxsCacheKeeperResourceUnknown,1),"invalid layout does not inherit platform validation");
    REQUIRE(!axs_cachekeeper_resource_node_valid(AxsCacheKeeperResourceLayoutSwiftgramGroup,AxsCacheKeeperResourceUnknown,AxsCacheKeeperResourcePostboxMedia,5),"unknown media shards do not consume expanded node budget");
    puts("PASS: resource-layout: structural classification, schema positions, opaque bytes and profile isolation");return 0;
}
