#ifndef SMC_PARAM_STRUCT_H
#define SMC_PARAM_STRUCT_H

#include <stdint.h>
#include <IOKit/IOTypes.h>
#include <IOKit/IOKitLib.h>

__BEGIN_DECLS

enum {
    kSMCSuccess = 0,
    kSMCError = 1
};

enum {
    kSMCUserClientOpen = 0,
    kSMCUserClientClose = 1,
    kSMCHandleYPCEvent = 2,
    kSMCReadKey = 5,
    kSMCWriteKey = 6,
    kSMCGetKeyInfo = 9
};

typedef struct {
    uint32_t dataSize;
    uint32_t dataType;
    uint8_t dataAttributes;
} SMCKeyInfoData;

typedef struct {
    uint32_t key;
    uint8_t version[8];
    uint16_t pLimitVersion;
    uint16_t pLimitLength;
    uint32_t cpuPLimit;
    uint32_t gpuPLimit;
    uint32_t memPLimit;
    SMCKeyInfoData keyInfo;
    uint8_t result;
    uint8_t status;
    uint8_t data8;
    uint32_t data32;
    uint8_t bytes[32];
} SMCParamStruct;

__END_DECLS

#endif
