#pragma once
#include <stdbool.h>
#include <stddef.h>
#include <string.h>

// Structural labels only. No paths, ownership, recovery or deletion authority.
typedef enum { AxsCacheKeeperResourceLayoutPlatform, AxsCacheKeeperResourceLayoutSwiftgramGroup } AxsCacheKeeperResourceLayout;
typedef enum {
    AxsCacheKeeperResourceUnknown, AxsCacheKeeperResourceDocuments, AxsCacheKeeperResourceLibrary,
    AxsCacheKeeperResourceCaches, AxsCacheKeeperResourceSupport, AxsCacheKeeperResourceTemporary,
    AxsCacheKeeperResourcePostbox, AxsCacheKeeperResourcePostboxDatabase, AxsCacheKeeperResourcePostboxMedia,
    AxsCacheKeeperResourcePostboxCache, AxsCacheKeeperResourceLogs, AxsCacheKeeperResourceCategoryCount
} AxsCacheKeeperResourceCategory;
typedef struct { const unsigned char *bytes; size_t length; } AxsCacheKeeperResourcePart;
static inline bool axs_cachekeeper_resource_part_is(AxsCacheKeeperResourcePart part,const char *text) {
    size_t length=strlen(text);return part.bytes && part.length==length && memcmp(part.bytes,text,length)==0;
}
static inline const char *axs_cachekeeper_resource_category_name(AxsCacheKeeperResourceCategory category) {
    static const char * const names[]={"unknown","Documents","Library","Caches","Application Support","tmp",
        "postbox","postboxDatabase","postboxMedia","postboxMediaCache","logs"};
    return (unsigned)category<AxsCacheKeeperResourceCategoryCount ? names[category] : NULL;
}
static inline size_t axs_cachekeeper_resource_node_depth(AxsCacheKeeperResourceLayout layout) {
    return layout==AxsCacheKeeperResourceLayoutSwiftgramGroup ? 5 : 3;
}
static inline AxsCacheKeeperResourceCategory axs_cachekeeper_resource_category(AxsCacheKeeperResourceLayout layout,
        const AxsCacheKeeperResourcePart *parts,size_t depth) {
    if (!parts || !depth) return AxsCacheKeeperResourceUnknown;
    if (layout==AxsCacheKeeperResourceLayoutSwiftgramGroup) {
        if (depth==2 && axs_cachekeeper_resource_part_is(parts[1],"logs")) return AxsCacheKeeperResourceLogs;
        if (depth>=3 && axs_cachekeeper_resource_part_is(parts[2],"postbox")) {
            if (depth==3) return AxsCacheKeeperResourcePostbox;
            if (depth==4 && axs_cachekeeper_resource_part_is(parts[3],"db")) return AxsCacheKeeperResourcePostboxDatabase;
            if (axs_cachekeeper_resource_part_is(parts[3],"media")) {
                if (depth==4) return AxsCacheKeeperResourcePostboxMedia;
                if (depth==5 && axs_cachekeeper_resource_part_is(parts[4],"cache")) return AxsCacheKeeperResourcePostboxCache;
            }
        }
    }
    if (depth==1) {
        if (axs_cachekeeper_resource_part_is(parts[0],"Documents")) return AxsCacheKeeperResourceDocuments;
        if (axs_cachekeeper_resource_part_is(parts[0],"Library")) return AxsCacheKeeperResourceLibrary;
        if (axs_cachekeeper_resource_part_is(parts[0],"tmp")) return AxsCacheKeeperResourceTemporary;
    }
    if (depth==2 && axs_cachekeeper_resource_part_is(parts[0],"Library")) {
        if (axs_cachekeeper_resource_part_is(parts[1],"Caches")) return AxsCacheKeeperResourceCaches;
        if (axs_cachekeeper_resource_part_is(parts[1],"Application Support")) return AxsCacheKeeperResourceSupport;
    }
    return AxsCacheKeeperResourceUnknown;
}
static inline bool axs_cachekeeper_resource_node_valid(AxsCacheKeeperResourceLayout layout,
        AxsCacheKeeperResourceCategory category,AxsCacheKeeperResourceCategory parent,size_t depth) {
    if (layout!=AxsCacheKeeperResourceLayoutPlatform && layout!=AxsCacheKeeperResourceLayoutSwiftgramGroup) return false;
    if (depth>axs_cachekeeper_resource_node_depth(layout)) return false;
    if (category==AxsCacheKeeperResourceUnknown) return depth<=3;
    if (layout==AxsCacheKeeperResourceLayoutSwiftgramGroup) {
        if (depth==2 && category==AxsCacheKeeperResourceLogs) return true;
        if (depth==3 && category==AxsCacheKeeperResourcePostbox) return true;
        if (depth==4 && parent==AxsCacheKeeperResourcePostbox && (category==AxsCacheKeeperResourcePostboxDatabase || category==AxsCacheKeeperResourcePostboxMedia)) return true;
        if (depth==5 && parent==AxsCacheKeeperResourcePostboxMedia && category==AxsCacheKeeperResourcePostboxCache) return true;
    }
    if (depth==1 && (category==AxsCacheKeeperResourceDocuments || category==AxsCacheKeeperResourceLibrary || category==AxsCacheKeeperResourceTemporary)) return true;
    return depth==2 && parent==AxsCacheKeeperResourceLibrary && (category==AxsCacheKeeperResourceCaches || category==AxsCacheKeeperResourceSupport);
}
