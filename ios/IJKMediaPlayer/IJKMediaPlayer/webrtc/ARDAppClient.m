/*
 *  Copyright 2014 The WebRTC Project Authors. All rights reserved.
 *
 *  Use of this source code is governed by a BSD-style license
 *  that can be found in the LICENSE file in the root of the source
 *  tree. An additional intellectual property rights grant can be found
 *  in the file PATENTS.  All contributing project authors may
 *  be found in the AUTHORS file in the root of the source tree.
 */

#import "ARDAppClient+Internal.h"

#import <WebRTC/RTCAudioTrack.h>
#import <WebRTC/RTCCameraVideoCapturer.h>
#import <WebRTC/RTCConfiguration.h>
#import <WebRTC/RTCDefaultVideoDecoderFactory.h>
#import <WebRTC/RTCDefaultVideoEncoderFactory.h>
#import <WebRTC/RTCFileLogger.h>
#import <WebRTC/RTCFileVideoCapturer.h>
#import <WebRTC/RTCIceServer.h>
#import <WebRTC/RTCLogging.h>
#import <WebRTC/RTCMediaConstraints.h>
#import <WebRTC/RTCMediaStream.h>
#import <WebRTC/RTCPeerConnectionFactory.h>
#import <WebRTC/RTCRtpSender.h>
#import <WebRTC/RTCRtpTransceiver.h>
#import <WebRTC/RTCTracing.h>
#import <WebRTC/RTCVideoSource.h>
#import <WebRTC/RTCVideoTrack.h>

#import "ARDAppEngineClient.h"
#import "ARDExternalSampleCapturer.h"
#import "ARDJoinResponse.h"
#import "ARDMessageResponse.h"
#import "ARDSettingsModel.h"
#import "ARDSignalingMessage.h"
#import "ARDTURNClient+Internal.h"
#import "ARDUtilities.h"
#import "ARDWebSocketChannel.h"
#import "RTCIceCandidate+JSON.h"
#import "RTCSessionDescription+JSON.h"
#import "Nebula_interface.h"

static NSString * const kARDIceServerRequestUrl = @"https://appr.tc/params";

static NSString * const kARDAppClientErrorDomain = @"ARDAppClient";
static NSInteger const kARDAppClientErrorUnknown = -1;
static NSInteger const kARDAppClientErrorRoomFull = -2;
static NSInteger const kARDAppClientErrorCreateSDP = -3;
static NSInteger const kARDAppClientErrorSetSDP = -4;
static NSInteger const kARDAppClientErrorInvalidClient = -5;
static NSInteger const kARDAppClientErrorInvalidRoom = -6;
static NSString * const kARDMediaStreamId = @"ARDAMS";
static NSString * const kARDAudioTrackId = @"ARDAMSa0";
static NSString * const kARDVideoTrackId = @"ARDAMSv0";
static NSString * const kARDVideoTrackKind = @"video";

#if NEBULA_TRTC
#define IS_DEBUG 1
static NSNumber * kRtcId = nil;
static dispatch_queue_t tutk_queue;
#endif
// TODO(tkchin): Add these as UI options.
#if defined(WEBRTC_IOS)
static BOOL const kARDAppClientEnableTracing = NO;
static BOOL const kARDAppClientEnableRtcEventLog = YES;
static int64_t const kARDAppClientAecDumpMaxSizeInBytes = 5e6;  // 5 MB.
static int64_t const kARDAppClientRtcEventLogMaxSizeInBytes = 5e6;  // 5 MB.
#endif
static int const kKbpsMultiplier = 1000;

// We need a proxy to NSTimer because it causes a strong retain cycle. When
// using the proxy, |invalidate| must be called before it properly deallocs.
@interface ARDTimerProxy : NSObject

- (instancetype)initWithInterval:(NSTimeInterval)interval
                         repeats:(BOOL)repeats
                    timerHandler:(void (^)(void))timerHandler;
- (void)invalidate;

@end

@implementation ARDTimerProxy {
  NSTimer *_timer;
  void (^_timerHandler)(void);
}

- (instancetype)initWithInterval:(NSTimeInterval)interval
                         repeats:(BOOL)repeats
                    timerHandler:(void (^)(void))timerHandler {
  NSParameterAssert(timerHandler);
  if (self = [super init]) {
    _timerHandler = timerHandler;
    _timer = [NSTimer scheduledTimerWithTimeInterval:interval
                                              target:self
                                            selector:@selector(timerDidFire:)
                                            userInfo:nil
                                             repeats:repeats];
  }
  return self;
}

- (void)invalidate {
  [_timer invalidate];
}

- (void)timerDidFire:(NSTimer *)timer {
  _timerHandler();
}

@end

@implementation ARDAppClient {
  RTC_OBJC_TYPE(RTCFileLogger) * _fileLogger;
  ARDTimerProxy *_statsTimer;
  ARDSettingsModel *_settings;
  RTC_OBJC_TYPE(RTCVideoTrack) * _localVideoTrack;
  const NebulaAPI *_nebulaAPI;
}

@synthesize shouldGetStats = _shouldGetStats;
@synthesize state = _state;
@synthesize delegate = _delegate;
@synthesize roomServerClient = _roomServerClient;
@synthesize channel = _channel;
@synthesize loopbackChannel = _loopbackChannel;
@synthesize turnClient = _turnClient;
@synthesize peerConnection = _peerConnection;
@synthesize factory = _factory;
@synthesize messageQueue = _messageQueue;
@synthesize isTurnComplete = _isTurnComplete;
@synthesize hasReceivedSdp  = _hasReceivedSdp;
@synthesize roomId = _roomId;
@synthesize clientId = _clientId;
@synthesize isInitiator = _isInitiator;
@synthesize iceServers = _iceServers;
@synthesize webSocketURL = _websocketURL;
@synthesize webSocketRestURL = _websocketRestURL;
@synthesize defaultPeerConnectionConstraints =
    _defaultPeerConnectionConstraints;
@synthesize isLoopback = _isLoopback;
@synthesize broadcast = _broadcast;
#if NEBULA_TRTC
@synthesize nebulaCtx = _nebulaCtx;
@synthesize iceGatherState = _iceGatherState;
@synthesize iceCandidates = _iceCandidates;
#endif

- (instancetype)init {
    self = [super init];
    return self;
}

- (instancetype)initWithDelegate:(id<ARDAppClientDelegate>)delegate
                    andNebulaAPI:(const NebulaAPI *)nebulaAPI
{
  if (self = [super init]) {
    _roomServerClient = [[ARDAppEngineClient alloc] init];
    _delegate = delegate;
    NSURL *turnRequestURL = [NSURL URLWithString:kARDIceServerRequestUrl];
    _turnClient = [[ARDTURNClient alloc] initWithURL:turnRequestURL];
#if NEBULA_TRTC
    _iceCandidates = [[NSMutableArray alloc] init];
    tutk_queue = dispatch_queue_create("com.tutk.rtc", nil);
    _nebulaAPI = nebulaAPI;
#endif
    [self configure];
  }
  return self;
}

// TODO(tkchin): Provide signaling channel factory interface so we can recreate
// channel if we need to on network failure. Also, make this the default public
// constructor.
- (instancetype)initWithRoomServerClient:(id<ARDRoomServerClient>)rsClient
                        signalingChannel:(id<ARDSignalingChannel>)channel
                              turnClient:(id<ARDTURNClient>)turnClient
                                delegate:(id<ARDAppClientDelegate>)delegate {
  NSParameterAssert(rsClient);
  NSParameterAssert(channel);
  NSParameterAssert(turnClient);
  if (self = [super init]) {
    _roomServerClient = rsClient;
    _channel = channel;
    _turnClient = turnClient;
    _delegate = delegate;
#if NEBULA_TRTC
    _iceCandidates = [[NSMutableArray alloc] init];
    tutk_queue = dispatch_queue_create("com.tutk.rtc", nil);
#endif
    [self configure];
  }
  return self;
}

- (void)configure {
  _messageQueue = [NSMutableArray array];
  _iceServers = [NSMutableArray array];
  _fileLogger = [[RTC_OBJC_TYPE(RTCFileLogger) alloc] init];
  [_fileLogger start];
}

- (void)dealloc {
  self.shouldGetStats = NO;
  [self disconnect];
}

- (void)setShouldGetStats:(BOOL)shouldGetStats {
  if (_shouldGetStats == shouldGetStats) {
    return;
  }
  if (shouldGetStats) {
    __weak ARDAppClient *weakSelf = self;
    _statsTimer = [[ARDTimerProxy alloc] initWithInterval:1
                                                  repeats:YES
                                             timerHandler:^{
      ARDAppClient *strongSelf = weakSelf;
      [strongSelf.peerConnection statsForTrack:nil
                              statsOutputLevel:RTCStatsOutputLevelDebug
                             completionHandler:^(NSArray *stats) {
        dispatch_async(dispatch_get_main_queue(), ^{
          ARDAppClient *strongSelf = weakSelf;
          [strongSelf.delegate appClient:strongSelf didGetStats:stats];
        });
      }];
    }];
  } else {
    [_statsTimer invalidate];
    _statsTimer = nil;
  }
  _shouldGetStats = shouldGetStats;
}

- (void)setState:(ARDAppClientState)state {
  if (_state == state) {
    return;
  }
  _state = state;
  [_delegate appClient:self didChangeState:_state];
}
#if NEBULA_TRTC
- (NSMutableArray*)buildIceServer {
  NSLog(@"USing google ice server");
  NSString *iceServer = @"{ \
    \"lifetimeDuration\": \"86400s\", \
    \"iceServers\": [ \
      { \
        \"urls\": [ \
          \"stun:64.233.188.127:19302\", \
          \"stun:[2404:6800:4008:c06::7f]:19302\" \
        ] \
      }, \
      { \
        \"urls\": [ \
          \"turn:172.253.117.127:19305?transport=udp\", \
          \"turn:[2607:f8b0:400e:c0a::7f]:19305?transport=udp\", \
          \"turn:172.253.117.127:19305?transport=tcp\", \
          \"turn:[2607:f8b0:400e:c0a::7f]:19305?transport=tcp\" \
        ], \
        \"username\": \"CJmukfQFEgaF6vEDwuIYzc/s6OMTIICjBQ\", \
        \"credential\": \"XE+YlZDCoTHYxinn+yZhntLs3SM=\", \
        \"maxRateKbps\": \"8000\" \
      } \
    ], \
    \"blockStatus\": \"NOT_BLOCKED\", \
    \"iceTransportPolicy\": \"all\" \
  }";
  NSError *error = nil;
  NSData *iceData = [iceServer dataUsingEncoding:NSUTF8StringEncoding];
  NSMutableArray *array = [[NSMutableArray alloc] init];
  NSDictionary *iceDict = [NSJSONSerialization JSONObjectWithData:iceData options:NSJSONReadingMutableContainers error:&error];
  for(NSString *key in iceDict){
    if([key isEqualToString:@"iceServers"]) {
      NSArray *iceServers = [iceDict objectForKey:@"iceServers"];
      int i;
      for(i = 0;i < [iceServers count];i++) {
        NSMutableArray *serverArray = [[NSMutableArray alloc] init];
        NSDictionary *servers = iceServers[i];
        NSArray *urls = [servers objectForKey:@"urls"];
        int j;
        for(j = 0;j < [urls count];j++) {
          [serverArray addObject:urls[j]];
        }
        NSString *username = [servers objectForKey:@"username"];
        NSString *credential = [servers objectForKey:@"credential"];
        [array addObject:[[RTCIceServer alloc] initWithURLStrings:serverArray username:username credential:credential]];
      }
    }
  }
  return array;
}

-(NSMutableArray *)buildIceServer:(NSDictionary *)json {
  /**
          {
             "RTC_ID": <RTC_ID>,
             "username": "<USERNAME>",
             "password": "<PASSWORD>",
             "ttl": <TIME_TO_LIVE_SEC>,
             "uris": [
               "<TURN_URI>"
             ]
           }
   */
    
    NSString *username = json[@"username"];
    NSString *password = json[@"password"];
    NSArray *uris = json[@"uris"];
    NSMutableArray *array = [[NSMutableArray alloc] init];
    NSMutableArray *serverArray = [[NSMutableArray alloc] init];
    for(int i = 0;i < uris.count; i++) {
        [serverArray addObject:uris[i]];
    }
    [array addObject:[[RTCIceServer alloc] initWithURLStrings:serverArray username:username credential:password]];
    return array;
}

- (NSString *)genStartWebRTC:(NSString *)amToken
                       realm:(NSString *)realm
                        info:(NSDictionary *)info{
  NSString *json = nil;
  NSMutableDictionary *dict = [[NSMutableDictionary alloc] init];
  [dict setValue:@"startWebRTC" forKey:@"func"];
  NSMutableDictionary *argsDict = [[NSMutableDictionary alloc] init];
  [argsDict setValue:amToken forKey:@"am_token"];
  [argsDict setValue:realm forKey:@"realm"];
  if(info != nil) {
    [argsDict setValue:info forKey:@"info"];
  }
  [dict setValue:argsDict forKey:@"args"];
  
  NSError *error;
  NSData *data = [NSJSONSerialization dataWithJSONObject:dict options:kNilOptions error:&error];
  json = [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding];
  return json;
}

- (NSString *)genStopWebRTC {
  NSString *json = nil;
  NSMutableDictionary *dict = [[NSMutableDictionary alloc] init];
  [dict setValue:@"stopWebRTC" forKey:@"func"];
  NSMutableDictionary *argsDict = [[NSMutableDictionary alloc] init];
  [argsDict setValue:kRtcId forKey:@"RTC_ID"];
  [dict setValue:argsDict forKey:@"args"];
  
  NSError *error;
  NSData *data = [NSJSONSerialization dataWithJSONObject:dict options:kNilOptions error:&error];
  json = [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding];
  return json;
}

- (NSString *)genExchangeSdp:(NSString *)sdp type:(NSString *)type {
  NSString *json = nil;
  NSMutableDictionary *dict = [[NSMutableDictionary alloc] init];
  [dict setValue:@"exchangeSdp" forKey:@"func"];
  NSMutableDictionary *argsDict = [[NSMutableDictionary alloc] init];
  [argsDict setValue:type forKey:@"type"];
  [argsDict setValue:sdp forKey:@"sdp"];
  [argsDict setValue:kRtcId forKey:@"RTC_ID"];
  [dict setValue:argsDict forKey:@"args"];
  
  NSError *error;
  NSData *data = [NSJSONSerialization dataWithJSONObject:dict options:kNilOptions error:&error];
  json = [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding];
  return json;
}

- (NSString *)combineOfferWithIceCandidate:(NSString *)sdp {
  NSMutableString *candidates = [[NSMutableString alloc] init];
  NSMutableString *offer = [[NSMutableString alloc] initWithString:sdp];
  for(RTCIceCandidate *candidate in _iceCandidates) {
    [candidates appendString:@"a="];
    [candidates appendString:[candidate sdp]];
    [candidates appendString:@"\r\n"];
  }
  NSRange firstRange = [offer rangeOfString:@"m=" options:NSLiteralSearch];
  NSRange secondRange;
  NSUInteger len;
  if(firstRange.length > 0) {
    len = firstRange.length+firstRange.location;
    secondRange = [offer rangeOfString:@"\r\n" options:NSLiteralSearch range:NSMakeRange(len, [offer length]-len)];
    if(secondRange.length > 0) {
      secondRange.location+=2;
      [offer insertString:candidates atIndex:secondRange.location];
    }
  }
  secondRange.location += [candidates length];
  len = secondRange.length+secondRange.location;
  firstRange = [offer rangeOfString:@"m=" options:NSLiteralSearch range:NSMakeRange(len, [offer length]-len)];
  if(firstRange.length > 0) {
    len = firstRange.length+firstRange.location;
    secondRange = [offer rangeOfString:@"\r\n" options:NSLiteralSearch range:NSMakeRange(len, [offer length]-len)];
    if(secondRange.length > 0) {
      secondRange.location+=2;
      [offer insertString:candidates atIndex:secondRange.location];
    }
  }
  return offer;
}

- (void)separateIceCandidateWithAnswer:(NSString *)sdp {
  if(sdp == nil) {
    NSLog(@"sdp = nil");
    return;
  }
  NSLog(@"start to separate ice candidate");
  NSMutableArray *candidates = [[NSMutableArray alloc] init];
  NSArray *subStr = [sdp componentsSeparatedByString:@"\n"];
  for(NSString *str in subStr) {
    if([str hasPrefix:@"a=candidate:"]) {
      [candidates addObject:[str substringFromIndex:[@"a=" length]]];
    } else if([str hasPrefix:@"a=mid:"]) {
      NSString *strMid = [str substringFromIndex:[@"a=mid:" length]];
      for(NSString *candidate in candidates) {
        RTCIceCandidate *c = [[RTCIceCandidate alloc] initWithSdp:candidate sdpMLineIndex:0 sdpMid:strMid];
        ARDICECandidateMessage *msg = [[ARDICECandidateMessage alloc] initWithCandidate:c];
        [_messageQueue addObject:msg];
      }
      [candidates removeAllObjects];
    }
  }
}

- (char *)sendCommand:(NSString *)cmd {
#if IS_DEBUG
  NSLog(@"send command: %@", cmd);
#endif
  char *response;
  int ret = _nebulaAPI->Send_Command(_nebulaCtx, [cmd UTF8String], &response, 10000);
  if(ret < 0) {
    NSLog(@"Failed to Nebula_Client_Send_Command %@, errno: %d", cmd, ret);
    return nil;
  }
#if IS_DEBUG
  NSLog(@"sendcmd response: %s", response);
#endif
  return response;
}

- (long)getWebRTCApi {
  if(_factory != nil) {
    return [_factory getWebRTCApi];
  }
  return 0;
}
#endif

- (long)connectToRoomWithId:(NSString *)roomId
                   settings:(ARDSettingsModel *)settings
                 isLoopback:(BOOL)isLoopback {
  NSParameterAssert(roomId.length);
  NSParameterAssert(_state == kARDAppClientStateDisconnected);
  _settings = settings;
  _isLoopback = isLoopback;
  self.state = kARDAppClientStateConnecting;

  RTC_OBJC_TYPE(RTCDefaultVideoDecoderFactory) *decoderFactory =
      [[RTC_OBJC_TYPE(RTCDefaultVideoDecoderFactory) alloc] init];
  RTC_OBJC_TYPE(RTCDefaultVideoEncoderFactory) *encoderFactory =
      [[RTC_OBJC_TYPE(RTCDefaultVideoEncoderFactory) alloc] init];
  encoderFactory.preferredCodec = [settings currentVideoCodecSettingFromStore];
  _factory =
      [[RTC_OBJC_TYPE(RTCPeerConnectionFactory) alloc] initWithEncoderFactory:encoderFactory
                                                               decoderFactory:decoderFactory];
#if defined(WEBRTC_IOS)
  if (kARDAppClientEnableTracing) {
    NSString *filePath = [self documentsFilePathForFileName:@"webrtc-trace.txt"];
    RTCStartInternalCapture(filePath);
  }
#endif

#if NEBULA_TRTC
    //dispatch_async(tutk_queue, ^{
        int ret;
        long ctx;
        ret = _nebulaAPI->Client_New([settings.udid UTF8String], [settings.credential UTF8String], &ctx);
        if (ret < 0) {
            NSLog(@"clien new from string failed");
            return 0;
        }
        self.nebulaCtx = ctx;
        //Start WebRTC
        NSString *startWebRtcCmd = [self genStartWebRTC:settings.amToken realm:settings.realm info:settings.info];
        char *obj = [self sendCommand:startWebRtcCmd];
        if(obj == nil) {
            NSLog(@"sendCommand start webrtc failed");
            return 0;
        }
        NSDictionary *json = [NSDictionary dictionaryWithJSONString:@(obj)];
        NSNumber *statusCode = json[@"statusCode"];
        if(statusCode.intValue != 200) {
            NSLog(@"start webrtc failed status: %d", statusCode.intValue);
            return 0;
        }
        NSDictionary *content = json[@"content"];
        kRtcId = content[@"RTC_ID"];
        [self.iceServers addObjectsFromArray:[self buildIceServer:content]];
        self.isTurnComplete = YES;
        self.isInitiator = TRUE;
        return [self startSignalingIfReady];
    //});
#else
  // Request TURN.
  __weak ARDAppClient *weakSelf = self;
  [_turnClient requestServersWithCompletionHandler:^(NSArray *turnServers,
                                                     NSError *error) {
    if (error) {
      RTCLogError(@"Error retrieving TURN servers: %@", error.localizedDescription);
    }
    ARDAppClient *strongSelf = weakSelf;
    [strongSelf.iceServers addObjectsFromArray:turnServers];
    strongSelf.isTurnComplete = YES;
    [strongSelf startSignalingIfReady];
  }];

  // Join room on room server.
  [_roomServerClient joinRoomWithRoomId:roomId
                             isLoopback:isLoopback
      completionHandler:^(ARDJoinResponse *response, NSError *error) {
    ARDAppClient *strongSelf = weakSelf;
    if (error) {
      [strongSelf.delegate appClient:strongSelf didError:error];
      return;
    }
    NSError *joinError =
        [[strongSelf class] errorForJoinResultType:response.result];
    if (joinError) {
      RTCLogError(@"Failed to join room:%@ on room server.", roomId);
      [strongSelf disconnect];
      [strongSelf.delegate appClient:strongSelf didError:joinError];
      return;
    }
    RTCLog(@"Joined room:%@ on room server.", roomId);
    strongSelf.roomId = response.roomId;
    strongSelf.clientId = response.clientId;
    strongSelf.isInitiator = response.isInitiator;
    for (ARDSignalingMessage *message in response.messages) {
      if (message.type == kARDSignalingMessageTypeOffer ||
          message.type == kARDSignalingMessageTypeAnswer) {
        strongSelf.hasReceivedSdp = YES;
        [strongSelf.messageQueue insertObject:message atIndex:0];
      } else {
        [strongSelf.messageQueue addObject:message];
      }
    }
    strongSelf.webSocketURL = response.webSocketURL;
    strongSelf.webSocketRestURL = response.webSocketRestURL;
    [strongSelf registerWithColliderIfReady];
    [strongSelf startSignalingIfReady];
  }];
#endif
}

- (void)disconnect {
  if (_state == kARDAppClientStateDisconnected) {
    return;
  }
#if NEBULA_TRTC
  [self sendCommand:[self genStopWebRTC]];
#else
  if (self.hasJoinedRoomServerRoom) {
    [_roomServerClient leaveRoomWithRoomId:_roomId
                                  clientId:_clientId
                         completionHandler:nil];
  }
#endif
  if (_channel) {
    if (_channel.state == kARDSignalingChannelStateRegistered) {
      // Tell the other client we're hanging up.
      ARDByeMessage *byeMessage = [[ARDByeMessage alloc] init];
      [_channel sendMessage:byeMessage];
    }
    // Disconnect from collider.
    _channel = nil;
  }
  _clientId = nil;
  _roomId = nil;
  _isInitiator = NO;
  _hasReceivedSdp = NO;
  _messageQueue = [NSMutableArray array];
  _localVideoTrack = nil;
#if defined(WEBRTC_IOS)
  [_factory stopAecDump];
  [_peerConnection stopRtcEventLog];
#endif
  [_peerConnection close];
  _peerConnection = nil;
  self.state = kARDAppClientStateDisconnected;
#if defined(WEBRTC_IOS)
  if (kARDAppClientEnableTracing) {
    RTCStopInternalCapture();
  }
#endif
}

#pragma mark - ARDSignalingChannelDelegate

- (void)channel:(id<ARDSignalingChannel>)channel
    didReceiveMessage:(ARDSignalingMessage *)message {
  switch (message.type) {
    case kARDSignalingMessageTypeOffer:
    case kARDSignalingMessageTypeAnswer:
      // Offers and answers must be processed before any other message, so we
      // place them at the front of the queue.
      _hasReceivedSdp = YES;
      [_messageQueue insertObject:message atIndex:0];
      break;
    case kARDSignalingMessageTypeCandidate:
    case kARDSignalingMessageTypeCandidateRemoval:
      [_messageQueue addObject:message];
      break;
    case kARDSignalingMessageTypeBye:
      // Disconnects can be processed immediately.
      [self processSignalingMessage:message];
      return;
  }
  [self drainMessageQueueIfReady];
}

- (void)channel:(id<ARDSignalingChannel>)channel
    didChangeState:(ARDSignalingChannelState)state {
  switch (state) {
    case kARDSignalingChannelStateOpen:
      break;
    case kARDSignalingChannelStateRegistered:
      break;
    case kARDSignalingChannelStateClosed:
    case kARDSignalingChannelStateError:
      // TODO(tkchin): reconnection scenarios. Right now we just disconnect
      // completely if the websocket connection fails.
      [self disconnect];
      break;
  }
}

#pragma mark - RTC_OBJC_TYPE(RTCPeerConnectionDelegate)
// Callbacks for this delegate occur on non-main thread and need to be
// dispatched back to main queue as needed.

- (void)peerConnection:(RTC_OBJC_TYPE(RTCPeerConnection) *)peerConnection
    didChangeSignalingState:(RTCSignalingState)stateChanged {
  RTCLog(@"Signaling state changed: %ld", (long)stateChanged);
}

- (void)peerConnection:(RTC_OBJC_TYPE(RTCPeerConnection) *)peerConnection
          didAddStream:(RTC_OBJC_TYPE(RTCMediaStream) *)stream {
  RTCLog(@"Stream with %lu video tracks and %lu audio tracks was added.",
         (unsigned long)stream.videoTracks.count,
         (unsigned long)stream.audioTracks.count);
}

- (void)peerConnection:(RTC_OBJC_TYPE(RTCPeerConnection) *)peerConnection
    didStartReceivingOnTransceiver:(RTC_OBJC_TYPE(RTCRtpTransceiver) *)transceiver {
  RTC_OBJC_TYPE(RTCMediaStreamTrack) *track = transceiver.receiver.track;
  RTCLog(@"Now receiving %@ on track %@.", track.kind, track.trackId);
}

- (void)peerConnection:(RTC_OBJC_TYPE(RTCPeerConnection) *)peerConnection
       didRemoveStream:(RTC_OBJC_TYPE(RTCMediaStream) *)stream {
  RTCLog(@"Stream was removed.");
}

- (void)peerConnectionShouldNegotiate:(RTC_OBJC_TYPE(RTCPeerConnection) *)peerConnection {
  RTCLog(@"WARNING: Renegotiation needed but unimplemented.");
}

- (void)peerConnection:(RTC_OBJC_TYPE(RTCPeerConnection) *)peerConnection
    didChangeIceConnectionState:(RTCIceConnectionState)newState {
  RTCLog(@"ICE state changed: %ld", (long)newState);
  dispatch_async(dispatch_get_main_queue(), ^{
    [self.delegate appClient:self didChangeConnectionState:newState];
  });
}

- (void)peerConnection:(RTC_OBJC_TYPE(RTCPeerConnection) *)peerConnection
    didChangeConnectionState:(RTCPeerConnectionState)newState {
  RTCLog(@"ICE+DTLS state changed: %ld", (long)newState);
}

- (void)peerConnection:(RTC_OBJC_TYPE(RTCPeerConnection) *)peerConnection
    didChangeIceGatheringState:(RTCIceGatheringState)newState {
  RTCLog(@"ICE gathering state changed: %ld", (long)newState);
#if NEBULA_TRTC
    self.iceGatherState = newState;
#endif
}

- (void)peerConnection:(RTC_OBJC_TYPE(RTCPeerConnection) *)peerConnection
    didGenerateIceCandidate:(RTC_OBJC_TYPE(RTCIceCandidate) *)candidate {
#if NEBULA_TRTC
    [_iceCandidates addObject:candidate];
#else
  dispatch_async(dispatch_get_main_queue(), ^{
    ARDICECandidateMessage *message =
        [[ARDICECandidateMessage alloc] initWithCandidate:candidate];
    [self sendSignalingMessage:message];
  });
#endif
}

- (void)peerConnection:(RTC_OBJC_TYPE(RTCPeerConnection) *)peerConnection
    didRemoveIceCandidates:(NSArray<RTC_OBJC_TYPE(RTCIceCandidate) *> *)candidates {
  dispatch_async(dispatch_get_main_queue(), ^{
    ARDICECandidateRemovalMessage *message =
        [[ARDICECandidateRemovalMessage alloc]
            initWithRemovedCandidates:candidates];
    [self sendSignalingMessage:message];
  });
}

- (void)peerConnection:(RTC_OBJC_TYPE(RTCPeerConnection) *)peerConnection
     didChangeLocalCandidate:(RTC_OBJC_TYPE(RTCIceCandidate) *)local
    didChangeRemoteCandidate:(RTC_OBJC_TYPE(RTCIceCandidate) *)remote
              lastReceivedMs:(int)lastDataReceivedMs
               didHaveReason:(NSString *)reason {
  RTCLog(@"ICE candidate pair changed because: %@", reason);
}

- (void)peerConnection:(RTC_OBJC_TYPE(RTCPeerConnection) *)peerConnection
    didOpenDataChannel:(RTC_OBJC_TYPE(RTCDataChannel) *)dataChannel {
}

#pragma mark - RTCSessionDescriptionDelegate
// Callbacks for this delegate occur on non-main thread and need to be
// dispatched back to main queue as needed.

- (void)peerConnection:(RTC_OBJC_TYPE(RTCPeerConnection) *)peerConnection
didCreateSessionDescription:(RTC_OBJC_TYPE(RTCSessionDescription) *)sdp
                 error:(NSError *)error {
    dispatch_async(dispatch_get_main_queue(), ^{
        if (error) {
            NSLog(@"Failed to create session description. Error: %@", error);
            [self disconnect];
            NSDictionary *userInfo = @{
                NSLocalizedDescriptionKey: @"Failed to create session description.",
            };
            NSError *sdpError =
            [[NSError alloc] initWithDomain:kARDAppClientErrorDomain
                                       code:kARDAppClientErrorCreateSDP
                                   userInfo:userInfo];
            [self.delegate appClient:self didError:sdpError];
            return;
        }
        __weak ARDAppClient *weakSelf = self;
        [self.peerConnection setLocalDescription:sdp
                               completionHandler:^(NSError *error) {
            ARDAppClient *strongSelf = weakSelf;
            [strongSelf peerConnection:strongSelf.peerConnection
     didSetSessionDescriptionWithError:error];
        }];
        
#if NEBULA_TRTC
        int count = 0;
        NSUInteger size = 0;
        while(self.iceGatherState != RTCIceGatheringStateComplete) {
            if([self.iceCandidates count] != size) {
                size = [self.iceCandidates count];
                count = 0;
            }else {
                if(count == 5) {
                    break;
                }else {
                    count++;
                }
            }
            usleep(200000);
        }
        NSString *offer = [self combineOfferWithIceCandidate:sdp.sdp];
#if IS_DEBUG
        NSLog(@"offer sdp=%@", offer);
#endif
        NSString *exchangeSDPCmd = [self genExchangeSdp:offer type:@"offer"];
        char *response = [self sendCommand:exchangeSDPCmd];
        if(response != nil) {
            NSDictionary *json = [NSDictionary dictionaryWithJSONString:@(response)];
            NSNumber *statusCode = json[@"statusCode"];
            if(statusCode.intValue != 200) {
                NSLog(@"Failed to get execute exchangeSdp command statusCode=%d", statusCode.intValue);
                return;
            }
            NSDictionary *dictContent = json[@"content"];
            NSString *type = dictContent[@"type"];
            if(strncmp(type.UTF8String, "answer", 6) == 0) {
                NSString *answer = dictContent[@"sdp"];
                NSString *content = dictContent.description;
#if IS_DEBUG
                NSLog(@"answer=%@", answer);
#endif
                RTCSessionDescription *ansSdp = [RTCSessionDescription descriptionFromJSONDictionary:dictContent];
                ARDSessionDescriptionMessage *msg = [[ARDSessionDescriptionMessage alloc] initWithDescription:ansSdp];
                self.hasReceivedSdp = true;
                [self.messageQueue addObject:msg];
                [self separateIceCandidateWithAnswer:answer];
                [self drainMessageQueueIfReady];
            }
        }else {
            NSLog(@"Failed to exchageSDP");
            return;
        }
#else
        ARDSessionDescriptionMessage *message =
        [[ARDSessionDescriptionMessage alloc] initWithDescription:sdp];
        [self sendSignalingMessage:message];
#endif
        [self setMaxBitrateForPeerConnectionVideoSender];
    });
}

- (void)peerConnection:(RTC_OBJC_TYPE(RTCPeerConnection) *)peerConnection
    didSetSessionDescriptionWithError:(NSError *)error {
  dispatch_async(dispatch_get_main_queue(), ^{
    if (error) {
      NSLog(@"Failed to set session description. Error: %@", error);
      [self disconnect];
      NSDictionary *userInfo = @{
        NSLocalizedDescriptionKey: @"Failed to set session description.",
      };
      NSError *sdpError =
          [[NSError alloc] initWithDomain:kARDAppClientErrorDomain
                                     code:kARDAppClientErrorSetSDP
                                 userInfo:userInfo];
      [self.delegate appClient:self didError:sdpError];
      return;
    }
    // If we're answering and we've just set the remote offer we need to create
    // an answer and set the local description.
    if (!self.isInitiator && !self.peerConnection.localDescription) {
      RTC_OBJC_TYPE(RTCMediaConstraints) *constraints = [self defaultAnswerConstraints];
      __weak ARDAppClient *weakSelf = self;
      [self.peerConnection
          answerForConstraints:constraints
             completionHandler:^(RTC_OBJC_TYPE(RTCSessionDescription) * sdp, NSError * error) {
               ARDAppClient *strongSelf = weakSelf;
               [strongSelf peerConnection:strongSelf.peerConnection
                   didCreateSessionDescription:sdp
                                         error:error];
             }];
    }
  });
}

#pragma mark - Private

#if defined(WEBRTC_IOS)

- (NSString *)documentsFilePathForFileName:(NSString *)fileName {
  NSParameterAssert(fileName.length);
  NSArray *paths = NSSearchPathForDirectoriesInDomains(
      NSDocumentDirectory, NSUserDomainMask, YES);
  NSString *documentsDirPath = paths.firstObject;
  NSString *filePath =
      [documentsDirPath stringByAppendingPathComponent:fileName];
  return filePath;
}

#endif

- (BOOL)hasJoinedRoomServerRoom {
#if NEBULA_TRTC
  return [kRtcId intValue] > 0;
#else
  return _clientId.length;
#endif
}

// Begins the peer connection connection process if we have both joined a room
// on the room server and tried to obtain a TURN server. Otherwise does nothing.
// A peer connection object will be created with a stream that contains local
// audio and video capture. If this client is the caller, an offer is created as
// well, otherwise the client will wait for an offer to arrive.
- (long)startSignalingIfReady {
  if (!_isTurnComplete || !self.hasJoinedRoomServerRoom) {
    return 0;
  }
  self.state = kARDAppClientStateConnected;

  // Create peer connection.
  RTC_OBJC_TYPE(RTCMediaConstraints) *constraints = [self defaultPeerConnectionConstraints];
  RTC_OBJC_TYPE(RTCConfiguration) *config = [[RTC_OBJC_TYPE(RTCConfiguration) alloc] init];
  RTC_OBJC_TYPE(RTCCertificate) *pcert = [RTC_OBJC_TYPE(RTCCertificate)
      generateCertificateWithParams:@{@"expires" : @100000, @"name" : @"RSASSA-PKCS1-v1_5"}];
  config.iceServers = _iceServers;
  config.sdpSemantics = RTCSdpSemanticsUnifiedPlan;
  config.certificate = pcert;

  _peerConnection = [_factory peerConnectionWithConfiguration:config
                                                  constraints:constraints
                                                     delegate:self];
  long pc_id = [_peerConnection getPeerConnectionId];
  // Create AV senders.
  [self createMediaSenders];
  if (_isInitiator) {
    // Send offer.
    __weak ARDAppClient *weakSelf = self;
    [_peerConnection
        offerForConstraints:[self defaultOfferConstraints]
          completionHandler:^(RTC_OBJC_TYPE(RTCSessionDescription) * sdp, NSError * error) {
            ARDAppClient *strongSelf = weakSelf;
            [strongSelf peerConnection:strongSelf.peerConnection
                didCreateSessionDescription:sdp
                                      error:error];
          }];
  } else {
    // Check if we've received an offer.
    [self drainMessageQueueIfReady];
  }
#if defined(WEBRTC_IOS)
  // Start event log.
  if (kARDAppClientEnableRtcEventLog) {
    NSString *filePath = [self documentsFilePathForFileName:@"webrtc-rtceventlog"];
    if (![_peerConnection startRtcEventLogWithFilePath:filePath
                                 maxSizeInBytes:kARDAppClientRtcEventLogMaxSizeInBytes]) {
      RTCLogError(@"Failed to start event logging.");
    }
  }

  // Start aecdump diagnostic recording.
  if ([_settings currentCreateAecDumpSettingFromStore]) {
    NSString *filePath = [self documentsFilePathForFileName:@"webrtc-audio.aecdump"];
    if (![_factory startAecDumpWithFilePath:filePath
                             maxSizeInBytes:kARDAppClientAecDumpMaxSizeInBytes]) {
      RTCLogError(@"Failed to start aec dump.");
    }
  }
#endif
  return pc_id;
}

// Processes the messages that we've received from the room server and the
// signaling channel. The offer or answer message must be processed before other
// signaling messages, however they can arrive out of order. Hence, this method
// only processes pending messages if there is a peer connection object and
// if we have received either an offer or answer.
- (void)drainMessageQueueIfReady {
  if (!_peerConnection || !_hasReceivedSdp) {
    return;
  }
  for (ARDSignalingMessage *message in _messageQueue) {
    [self processSignalingMessage:message];
  }
  [_messageQueue removeAllObjects];
}

// Processes the given signaling message based on its type.
- (void)processSignalingMessage:(ARDSignalingMessage *)message {
  NSParameterAssert(_peerConnection ||
      message.type == kARDSignalingMessageTypeBye);
  switch (message.type) {
    case kARDSignalingMessageTypeOffer:
    case kARDSignalingMessageTypeAnswer: {
      ARDSessionDescriptionMessage *sdpMessage =
          (ARDSessionDescriptionMessage *)message;
      RTC_OBJC_TYPE(RTCSessionDescription) *description = sdpMessage.sessionDescription;
      __weak ARDAppClient *weakSelf = self;
      [_peerConnection setRemoteDescription:description
                          completionHandler:^(NSError *error) {
                            ARDAppClient *strongSelf = weakSelf;
                            [strongSelf peerConnection:strongSelf.peerConnection
                                didSetSessionDescriptionWithError:error];
                          }];
      break;
    }
    case kARDSignalingMessageTypeCandidate: {
      ARDICECandidateMessage *candidateMessage =
          (ARDICECandidateMessage *)message;
      [_peerConnection addIceCandidate:candidateMessage.candidate];
      break;
    }
    case kARDSignalingMessageTypeCandidateRemoval: {
      ARDICECandidateRemovalMessage *candidateMessage =
          (ARDICECandidateRemovalMessage *)message;
      [_peerConnection removeIceCandidates:candidateMessage.candidates];
      break;
    }
    case kARDSignalingMessageTypeBye:
      // Other client disconnected.
      // TODO(tkchin): support waiting in room for next client. For now just
      // disconnect.
      [self disconnect];
      break;
  }
}

// Sends a signaling message to the other client. The caller will send messages
// through the room server, whereas the callee will send messages over the
// signaling channel.
- (void)sendSignalingMessage:(ARDSignalingMessage *)message {
  if (_isInitiator) {
    __weak ARDAppClient *weakSelf = self;
    [_roomServerClient sendMessage:message
                         forRoomId:_roomId
                          clientId:_clientId
                 completionHandler:^(ARDMessageResponse *response,
                                     NSError *error) {
      ARDAppClient *strongSelf = weakSelf;
      if (error) {
        [strongSelf.delegate appClient:strongSelf didError:error];
        return;
      }
      NSError *messageError =
          [[strongSelf class] errorForMessageResultType:response.result];
      if (messageError) {
        [strongSelf.delegate appClient:strongSelf didError:messageError];
        return;
      }
    }];
  } else {
    [_channel sendMessage:message];
  }
}

- (void)setMaxBitrateForPeerConnectionVideoSender {
  for (RTC_OBJC_TYPE(RTCRtpSender) * sender in _peerConnection.senders) {
    if (sender.track != nil) {
      if ([sender.track.kind isEqualToString:kARDVideoTrackKind]) {
        [self setMaxBitrate:[_settings currentMaxBitrateSettingFromStore] forVideoSender:sender];
      }
    }
  }
}

- (void)setMaxBitrate:(NSNumber *)maxBitrate forVideoSender:(RTC_OBJC_TYPE(RTCRtpSender) *)sender {
  if (maxBitrate.intValue <= 0) {
    return;
  }

  RTC_OBJC_TYPE(RTCRtpParameters) *parametersToModify = sender.parameters;
  for (RTC_OBJC_TYPE(RTCRtpEncodingParameters) * encoding in parametersToModify.encodings) {
    encoding.maxBitrateBps = @(maxBitrate.intValue * kKbpsMultiplier);
  }
  [sender setParameters:parametersToModify];
}

- (RTC_OBJC_TYPE(RTCRtpTransceiver) *)videoTransceiver {
  for (RTC_OBJC_TYPE(RTCRtpTransceiver) * transceiver in _peerConnection.transceivers) {
    if (transceiver.mediaType == RTCRtpMediaTypeVideo) {
      return transceiver;
    }
  }
  return nil;
}

- (void)createMediaSenders {
  RTC_OBJC_TYPE(RTCMediaConstraints) *constraints = [self defaultMediaAudioConstraints];
  RTC_OBJC_TYPE(RTCAudioSource) *source = [_factory audioSourceWithConstraints:constraints];
  RTC_OBJC_TYPE(RTCAudioTrack) *track = [_factory audioTrackWithSource:source
                                                               trackId:kARDAudioTrackId];
  [_peerConnection addTrack:track streamIds:@[ kARDMediaStreamId ]];
  _localVideoTrack = [self createLocalVideoTrack];
  if (_localVideoTrack) {
    [_peerConnection addTrack:_localVideoTrack streamIds:@[ kARDMediaStreamId ]];
    [_delegate appClient:self didReceiveLocalVideoTrack:_localVideoTrack];
    // We can set up rendering for the remote track right away since the transceiver already has an
    // RTC_OBJC_TYPE(RTCRtpReceiver) with a track. The track will automatically get unmuted and
    // produce frames once RTP is received.
    RTC_OBJC_TYPE(RTCVideoTrack) *track =
        (RTC_OBJC_TYPE(RTCVideoTrack) *)([self videoTransceiver].receiver.track);
    [_delegate appClient:self didReceiveRemoteVideoTrack:track];
  }
}

- (RTC_OBJC_TYPE(RTCVideoTrack) *)createLocalVideoTrack {
  if ([_settings currentAudioOnlySettingFromStore]) {
    return nil;
  }

  RTC_OBJC_TYPE(RTCVideoSource) *source = [_factory videoSource];

#if !TARGET_IPHONE_SIMULATOR
  if (self.isBroadcast) {
    ARDExternalSampleCapturer *capturer =
        [[ARDExternalSampleCapturer alloc] initWithDelegate:source];
    [_delegate appClient:self didCreateLocalExternalSampleCapturer:capturer];
  } else {
    RTC_OBJC_TYPE(RTCCameraVideoCapturer) *capturer =
        [[RTC_OBJC_TYPE(RTCCameraVideoCapturer) alloc] initWithDelegate:source];
    [_delegate appClient:self didCreateLocalCapturer:capturer];
  }
#else
#if defined(__IPHONE_11_0) && (__IPHONE_OS_VERSION_MAX_ALLOWED >= __IPHONE_11_0)
  if (@available(iOS 10, *)) {
    RTC_OBJC_TYPE(RTCFileVideoCapturer) *fileCapturer =
        [[RTC_OBJC_TYPE(RTCFileVideoCapturer) alloc] initWithDelegate:source];
    [_delegate appClient:self didCreateLocalFileCapturer:fileCapturer];
  }
#endif
#endif

  return [_factory videoTrackWithSource:source trackId:kARDVideoTrackId];
}

#pragma mark - Collider methods

- (void)registerWithColliderIfReady {
  if (!self.hasJoinedRoomServerRoom) {
    return;
  }
  // Open WebSocket connection.
  if (!_channel) {
    _channel =
        [[ARDWebSocketChannel alloc] initWithURL:_websocketURL
                                         restURL:_websocketRestURL
                                        delegate:self];
    if (_isLoopback) {
      _loopbackChannel =
          [[ARDLoopbackWebSocketChannel alloc] initWithURL:_websocketURL
                                                   restURL:_websocketRestURL];
    }
  }
  [_channel registerForRoomId:_roomId clientId:_clientId];
  if (_isLoopback) {
    [_loopbackChannel registerForRoomId:_roomId clientId:@"LOOPBACK_CLIENT_ID"];
  }
}

#pragma mark - Defaults

- (RTC_OBJC_TYPE(RTCMediaConstraints) *)defaultMediaAudioConstraints {
  NSDictionary *mandatoryConstraints = @{};
  RTC_OBJC_TYPE(RTCMediaConstraints) *constraints =
      [[RTC_OBJC_TYPE(RTCMediaConstraints) alloc] initWithMandatoryConstraints:mandatoryConstraints
                                                           optionalConstraints:nil];
  return constraints;
}

- (RTC_OBJC_TYPE(RTCMediaConstraints) *)defaultAnswerConstraints {
  return [self defaultOfferConstraints];
}

- (RTC_OBJC_TYPE(RTCMediaConstraints) *)defaultOfferConstraints {
  NSDictionary *mandatoryConstraints = @{
    @"OfferToReceiveAudio" : @"true",
    @"OfferToReceiveVideo" : @"true"
  };
  RTC_OBJC_TYPE(RTCMediaConstraints) *constraints =
      [[RTC_OBJC_TYPE(RTCMediaConstraints) alloc] initWithMandatoryConstraints:mandatoryConstraints
                                                           optionalConstraints:nil];
  return constraints;
}

- (RTC_OBJC_TYPE(RTCMediaConstraints) *)defaultPeerConnectionConstraints {
  if (_defaultPeerConnectionConstraints) {
    return _defaultPeerConnectionConstraints;
  }
  NSString *value = _isLoopback ? @"false" : @"true";
  NSDictionary *optionalConstraints = @{ @"DtlsSrtpKeyAgreement" : value };
  RTC_OBJC_TYPE(RTCMediaConstraints) *constraints =
      [[RTC_OBJC_TYPE(RTCMediaConstraints) alloc] initWithMandatoryConstraints:nil
                                                           optionalConstraints:optionalConstraints];
  return constraints;
}

#pragma mark - Errors

+ (NSError *)errorForJoinResultType:(ARDJoinResultType)resultType {
  NSError *error = nil;
  switch (resultType) {
    case kARDJoinResultTypeSuccess:
      break;
    case kARDJoinResultTypeUnknown: {
      error = [[NSError alloc] initWithDomain:kARDAppClientErrorDomain
                                         code:kARDAppClientErrorUnknown
                                     userInfo:@{
        NSLocalizedDescriptionKey: @"Unknown error.",
      }];
      break;
    }
    case kARDJoinResultTypeFull: {
      error = [[NSError alloc] initWithDomain:kARDAppClientErrorDomain
                                         code:kARDAppClientErrorRoomFull
                                     userInfo:@{
        NSLocalizedDescriptionKey: @"Room is full.",
      }];
      break;
    }
  }
  return error;
}

+ (NSError *)errorForMessageResultType:(ARDMessageResultType)resultType {
  NSError *error = nil;
  switch (resultType) {
    case kARDMessageResultTypeSuccess:
      break;
    case kARDMessageResultTypeUnknown:
      error = [[NSError alloc] initWithDomain:kARDAppClientErrorDomain
                                         code:kARDAppClientErrorUnknown
                                     userInfo:@{
        NSLocalizedDescriptionKey: @"Unknown error.",
      }];
      break;
    case kARDMessageResultTypeInvalidClient:
      error = [[NSError alloc] initWithDomain:kARDAppClientErrorDomain
                                         code:kARDAppClientErrorInvalidClient
                                     userInfo:@{
        NSLocalizedDescriptionKey: @"Invalid client.",
      }];
      break;
    case kARDMessageResultTypeInvalidRoom:
      error = [[NSError alloc] initWithDomain:kARDAppClientErrorDomain
                                         code:kARDAppClientErrorInvalidRoom
                                     userInfo:@{
        NSLocalizedDescriptionKey: @"Invalid room.",
      }];
      break;
  }
  return error;
}

@end
