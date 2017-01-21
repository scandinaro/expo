// Copyright 2015-present 650 Industries. All rights reserved.

#import "EXCachedResource.h"
#import "EXKernelReactAppManager.h"
#import "EXReactAppManager+Private.h"
#import "EXDevMenuViewController.h"
#import "EXExceptionHandler.h"
#import "EXKernel.h"
#import "EXLog.h"
#import "EXShellManager.h"
#import "EXVersionManager.h"
#import "EXVersions.h"

#import <React/RCTUtils.h>

NSString * const kEXKernelLaunchUrlDefaultsKey = @"EXKernelLaunchUrlDefaultsKey";
NSString *kEXKernelBundleResourceName = @"kernel.ios";
NSString *kEXKernelManifestResourceName = @"kernel-manifest";

@interface EXKernelReactAppManager ()

// we retain this because RCTExceptionsManager won't retain it
@property (nonatomic, strong) EXExceptionHandler *exceptionHandler;

@end

@implementation EXKernelReactAppManager

- (instancetype)initWithLaunchOptions:(NSDictionary *)launchOptions
{
  if (self = [super init]) {
    _launchOptions = launchOptions;
  }
  return self;
}

- (void)setLaunchOptions:(NSDictionary *)launchOptions
{
  if (self.reactBridge) {
    DDLogError(@"%s: Setting launch options while bridge is already running. These won't take effect until you reload the ReactAppManager.", __PRETTY_FUNCTION__);
  }
  _launchOptions = launchOptions;
}

+ (NSDictionary * _Nullable)kernelManifest
{
  NSString *manifestJson = nil;
#ifdef BUILD_MACHINE_KERNEL_MANIFEST
  // if developing, use development manifest from generateDynamicMacros.js
  if ([self _isDevelopingKernel]) {
    manifestJson = BUILD_MACHINE_KERNEL_MANIFEST;
  }
#endif
  // otherwise use published manifest
  if (!manifestJson) {
    NSString *manifestPath = [[NSBundle mainBundle] pathForResource:kEXKernelManifestResourceName ofType:@"json"];
    if (manifestPath) {
      NSError *error;
      manifestJson = [NSString stringWithContentsOfFile:manifestPath encoding:NSUTF8StringEncoding error:&error];
      if (error) {
        manifestJson = nil;
      }
    }
  }
  
  if (manifestJson) {
    id manifest = RCTJSONParse(manifestJson, nil);
    if ([manifest isKindOfClass:[NSDictionary class]]) {
      return manifest;
    }
  }
  return nil;
}

+ (NSURL *)kernelBundleUrl
{
  NSDictionary *localManifest = [self kernelManifest];
  if (localManifest) {
    NSURL *bundleUrl = [NSURL URLWithString:localManifest[@"bundleUrl"]];
    if (bundleUrl) {
      return bundleUrl;
    }
  }
  // TODO: remove
  return [NSURL URLWithString:@"https://exp.host/~exponent/kernel"];
}

- (BOOL)isReadyToLoad
{
  return YES;
}

- (void)computeVersionSymbolPrefix
{
  NSDictionary *detachedVersions = [EXVersions sharedInstance].versions[@"detachedNativeVersions"];
  if (detachedVersions) {
    self.validatedVersion = detachedVersions[@"kernel"];
  } else {
    self.validatedVersion = nil;
  }
  self.versionSymbolPrefix = [[EXVersions sharedInstance] symbolPrefixForSdkVersion:self.validatedVersion isKernel:YES];
}

- (NSString *)bundleNameForJSResource
{
  return kEXKernelBundleResourceName;
}

- (EXCachedResourceBehavior)cacheBehaviorForJSResource
{
  if ([[self class] _isDevelopingKernel]) {
    // to prevent running dev native code against prod js.
    return kEXCachedResourceNoCache;
  } else {
    return [[NSUserDefaults standardUserDefaults] boolForKey:kEXSkipCacheUserDefaultsKey] ?
      kEXCachedResourceNoCache :
      kEXCachedResourceUseCacheImmediately;
  }
}

- (NSDictionary * _Nullable)launchOptionsForBridge
{
  return _launchOptions;
}

- (NSDictionary * _Nullable)initialPropertiesForRootView
{
  NSMutableDictionary *props = [NSMutableDictionary dictionary];
  if ([EXShellManager sharedInstance].isShell) {
    [props addEntriesFromDictionary:@{
                                      @"shell": @YES,
                                      @"shellManifestUrl": [EXShellManager sharedInstance].shellManifestUrl,
                                      }];
  }
  // TODO: do we want to use this for anything? needed for exponent-sdk to function
  props[@"exp"] = @{};
  
  return props;
}

- (NSString *)applicationKeyForRootView
{
  return @"main";
}

- (RCTLogFunction)logFunction
{
  return EXGetKernelRCTLogFunction();
}

- (RCTLogLevel)logLevel
{
  return RCTLogLevelInfo;
}

- (void)registerBridge
{
  [[EXKernel sharedInstance].bridgeRegistry registerKernelBridge:self.reactBridge];
}

- (void)unregisterBridge
{
  [[EXKernel sharedInstance].bridgeRegistry unregisterKernelBridge];
  _exceptionHandler = nil;
}

#pragma mark - RCTBridgeDelegate

- (NSURL *)sourceURLForBridge:(RCTBridge *)bridge
{
  return [[self class] kernelBundleUrl];
}

- (NSArray *)extraModulesForBridge:(RCTBridge *)bridge
{
  _exceptionHandler = [[EXExceptionHandler alloc] initWithBridge:self.reactBridge];
  NSMutableArray *modules = [NSMutableArray array];
  
  if ([self.versionManager respondsToSelector:@selector(extraModulesWithParams:)]) {
    NSDictionary *manifest = [[self class] kernelManifest];
    // TODO: common constants impl?
    NSMutableDictionary *params = [@{
                                     @"constants": @{
                                         @"deviceId": [EXKernel deviceInstallUUID],
                                         @"linkingUri": @"exp://",
                                         @"manifest": manifest,
                                         @"appOwnership": @"exponent",
                                         },
                                     @"kernel": [EXKernel sharedInstance],
                                     @"supportedSdkVersions": [EXVersions sharedInstance].versions[@"sdkVersions"],
                                     @"exceptionsManagerDelegate": _exceptionHandler,
                                     @"isDeveloper": @([[self class] _isDevelopingKernel]),
                                     @"manifest": manifest,
                                     } mutableCopy];

    // used by appetize - override the kernel initial url if there's something in NSUserDefaults
    NSURL *initialKernelUrl;
    NSString *kernelInitialUrlDefaultsValue = [[NSUserDefaults standardUserDefaults] stringForKey:kEXKernelLaunchUrlDefaultsKey];
    if (kernelInitialUrlDefaultsValue) {
      initialKernelUrl = [NSURL URLWithString:kernelInitialUrlDefaultsValue];
      [[NSUserDefaults standardUserDefaults] removeObjectForKey:kEXKernelLaunchUrlDefaultsKey];
      [[NSUserDefaults standardUserDefaults] synchronize];
    } else {
      initialKernelUrl = [EXKernel initialUrlFromLaunchOptions:_launchOptions];
    }
    params[@"initialUri"] = initialKernelUrl;
    
    [modules addObjectsFromArray:[self.versionManager extraModulesWithParams:params]];
  }
  
  return modules;
}

#pragma mark - internal

+ (BOOL)_isDevelopingKernel
{
  // if we're in detached state (i.e. ExponentView) then never expect local kernel
  BOOL isDetachedKernel = ([[EXVersions sharedInstance].versions objectForKey:@"detachedNativeVersions"] != nil);
  if (isDetachedKernel) {
    return NO;
  }

  // otherwise, expect local kernel when we are attached to xcode
#if DEBUG
  return YES;
#endif
  return NO;
}

@end
