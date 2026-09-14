#import "SwiftBridgeCore.h"
#import "em_proxy.h"
#import "minimuxer.h"
#include "libimobiledevice/libimobiledevice.h"
#include "libimobiledevice/diagnostics_relay.h"
#include "libimobiledevice/mobilebackup2.h"
#include "libimobiledevice/installation_proxy.h"
#include "plist/plist.h"

int idevicebackup2_main(int argc, char *argv[]);