#import <apr-1/apr_pools.h>
#import <JavaScriptCore/JSContextRef.h>

void CydgetPoolParse(apr_pool_t *remote, const uint16_t **data, size_t *size);
void CYSetupContext(JSGlobalContextRef context);
