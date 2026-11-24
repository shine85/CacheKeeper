#pragma once
// The Runtime's single shared folder is redirected to this process-owned fixture.
NSString *axs_cachekeeper_image_runtime_fixture_folder(void);
#define jbroot(path) axs_cachekeeper_image_runtime_fixture_folder()
