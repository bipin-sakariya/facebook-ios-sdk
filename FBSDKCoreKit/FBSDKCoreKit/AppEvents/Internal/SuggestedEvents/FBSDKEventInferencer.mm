// Copyright (c) 2014-present, Facebook, Inc. All rights reserved.
//
// You are hereby granted a non-exclusive, worldwide, royalty-free license to use,
// copy, modify, and distribute this software in source code or binary form for use
// in connection with the web services and APIs provided by Facebook.
//
// As with any software that integrates with the Facebook platform, your use of
// this software is subject to the Facebook Developer Principles and Policies
// [http://developers.facebook.com/policy/]. This copyright notice shall be
// included in all copies or substantial portions of the software.
//
// THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
// IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY, FITNESS
// FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE AUTHORS OR
// COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER LIABILITY, WHETHER
// IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM, OUT OF OR IN
// CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE SOFTWARE.

#import "TargetConditionals.h"

#if !TARGET_OS_TV

#import "FBSDKEventInferencer.h"

#import <Foundation/Foundation.h>

#import "FBSDKFeatureExtractor.h"
#import "FBSDKModelManager.h"
#import "FBSDKModelParser.h"
#import "FBSDKModelRuntime.hpp"
#import "FBSDKModelUtility.h"
#import "FBSDKViewHierarchyMacros.h"

#include<stdexcept>

static NSString *const MODEL_INFO_KEY= @"com.facebook.sdk:FBSDKModelInfo";
static NSString *const THRESHOLDS_KEY = @"thresholds";
static NSString *const SUGGESTED_EVENT[4] = {@"fb_mobile_add_to_cart", @"fb_mobile_complete_registration", @"other", @"fb_mobile_purchase"};
static NSDictionary<NSString *, NSString *> *const DEFAULT_PREDICTION = @{SUGGEST_EVENT_KEY: SUGGESTED_EVENTS_OTHER};

static std::unordered_map<std::string, mat::MTensor> _weights;

@implementation FBSDKEventInferencer : NSObject

+ (void)loadWeightsForKey:(NSString *)useCaseKey
{
  NSString *path = [FBSDKModelManager getWeightsPath:useCaseKey];
  if (!path) {
    return;
  }
  NSData *latestData = [NSData dataWithContentsOfFile:path
                                              options:NSDataReadingMappedIfSafe
                                                error:nil];
  if (!latestData) {
    return;
  }
  std::unordered_map<std::string, mat::MTensor> weights = [FBSDKModelParser parseWeightsData:latestData];
  if ([FBSDKModelParser validateWeights:weights forTask:FBSDKMTMLTaskAppEventPred]) {
    _weights = weights;
  }
}

+ (NSDictionary<NSString *, NSString *> *)predict:(NSString *)buttonText
                                         viewTree:(NSMutableDictionary *)viewTree
                                          withLog:(BOOL)isPrint
{
  if (buttonText.length == 0 || _weights.size() == 0) {
    return DEFAULT_PREDICTION;
  }
  try {
    // Get bytes tensor
    NSString *textFeature = [FBSDKModelUtility normalizeText:[FBSDKFeatureExtractor getTextFeature:buttonText withScreenName:viewTree[@"screenname"]]];
    if (textFeature.length == 0) {
      return DEFAULT_PREDICTION;
    }
    const char *bytes = [textFeature UTF8String];
    if ((int)strlen(bytes) == 0) {
      return DEFAULT_PREDICTION;
    }

    // Get dense tensor
    std::vector<int64_t> dense_tensor_shape;
    dense_tensor_shape.push_back(1);
    dense_tensor_shape.push_back(30);
    mat::MTensor dense_tensor = mat::mempty(dense_tensor_shape);
    float *dense_tensor_data = dense_tensor.data<float>();
    float *dense_data = [FBSDKFeatureExtractor getDenseFeatures:viewTree];
    if (!dense_data) {
      return DEFAULT_PREDICTION;
    }

    NSMutableDictionary<NSString *, NSString *> *result = [[NSMutableDictionary alloc] init];

    // Get dense feature string
    NSMutableArray *denseDataArray = [NSMutableArray array];
    for (int i=0; i < 30; i++) {
      [denseDataArray addObject:[NSNumber numberWithFloat: dense_data[i]]];
    }
    [result setObject:[denseDataArray componentsJoinedByString:@","] forKey:DENSE_FEATURE_KEY];

    memcpy(dense_tensor_data, dense_data, sizeof(float) * 30);
    free(dense_data);
    float *res = mat1::predictOnText(bytes, _weights, dense_tensor_data);
    NSMutableDictionary<NSString *, id> *modelInfo = [[NSUserDefaults standardUserDefaults] objectForKey:MODEL_INFO_KEY];
    if (!modelInfo) {
      return DEFAULT_PREDICTION;
    }
    NSDictionary<NSString *, id> * suggestedEventModelInfo = [modelInfo objectForKey:SUGGEST_EVENT_KEY];
    if (!suggestedEventModelInfo) {
      return DEFAULT_PREDICTION;
    }
    NSMutableArray *thresholds = [suggestedEventModelInfo objectForKey:THRESHOLDS_KEY];
    if (thresholds.count < 4) {
      return DEFAULT_PREDICTION;
    }

    for (int i = 0; i < thresholds.count; i++){
      if ((float)res[i] >= (float)[thresholds[i] floatValue]) {
        [result setObject:SUGGESTED_EVENT[i] forKey:SUGGEST_EVENT_KEY];
        return result;
      }
    }
  } catch (const std::exception &e) {}
  return DEFAULT_PREDICTION;
}

@end

#endif
