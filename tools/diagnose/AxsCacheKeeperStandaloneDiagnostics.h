#pragma once
#import <Foundation/Foundation.h>

// All output is technical metadata; callers supply only collector-owned output folders.
NSDictionary *axs_cachekeeper_diagnose_saved(NSString *folder,NSArray<NSString *> *requested);
NSDictionary *axs_cachekeeper_diagnose_fault_metadata(NSArray<NSString *> *folders);
NSDictionary *axs_cachekeeper_diagnose_processes(void);
NSDictionary *axs_cachekeeper_diagnose_capacity(NSString *folder,NSDictionary *(^provider)(NSError **),NSTimeInterval seconds);
NSDictionary *axs_cachekeeper_diagnose_system_plan(NSError **error);
BOOL axs_cachekeeper_diagnose_write_json(NSDictionary *report,NSString *directory,NSError **error);
int axs_cachekeeper_diagnose_collect(NSString *outputBase,NSString *pluginFolder,NSArray<NSString *> *faultFolders,
                                   NSTimeInterval duration,int readyDescriptor);
