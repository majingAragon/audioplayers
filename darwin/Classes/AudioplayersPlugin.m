#import "AudioplayersPlugin.h"
#import <AVKit/AVKit.h>
#import <AVFoundation/AVFoundation.h>

#if TARGET_OS_IPHONE
    #import <UIKit/UIKit.h>
    #import <MediaPlayer/MediaPlayer.h>
#endif

static NSString *const CHANNEL_NAME = @"xyz.luan/audioplayers";
NSString *const AudioplayersPluginStop = @"AudioplayersPluginStop";


static NSMutableDictionary * players;

@interface AudioplayersPlugin()
-(void) pause: (NSString *) playerId;
-(void) stop: (NSString *) playerId;
-(void) seek: (NSString *) playerId time: (CMTime) time;
-(void) onSoundComplete: (NSString *) playerId;
-(void) updateDuration: (NSString *) playerId;
-(void) onTimeInterval: (NSString *) playerId time: (CMTime) time;
@end

@implementation AudioplayersPlugin {
  FlutterResult _result;
}

typedef void (^VoidCallback)(NSString * playerId);

NSMutableSet *timeobservers;
FlutterMethodChannel *_channel_audioplayer;
bool _isDealloc = false;

NSObject<FlutterPluginRegistrar> *_registrar;
int64_t _updateHandleMonitorKey;

#if TARGET_OS_IPHONE
    FlutterEngine *_headlessEngine;
    FlutterMethodChannel *_callbackChannel;
    bool headlessServiceInitialized = false;

    NSString *_currentPlayerId; // to be used for notifications command center
    MPNowPlayingInfoCenter *_infoCenter;
    MPRemoteCommandCenter *remoteCommandCenter;
    
    NSString *osName = @"iOS";
#else
    NSString *osName = @"macOS";
#endif

NSString *_title;
NSString *_albumTitle;
NSString *_artist;
NSString *_imageUrl;
int _duration;
const float _defaultPlaybackRate = 1.0;
const NSString *_defaultPlayingRoute = @"speakers";
// 0 audio 1 radio
NSString *_playerIndex;
NSMutableDictionary * imageDict;
BOOL isPlayingState = NO;

+ (void)registerWithRegistrar:(NSObject<FlutterPluginRegistrar>*)registrar {
  _registrar = registrar;
  FlutterMethodChannel* channel = [FlutterMethodChannel
                                   methodChannelWithName:CHANNEL_NAME
                                   binaryMessenger:[registrar messenger]];
  AudioplayersPlugin* instance = [[AudioplayersPlugin alloc] init];
  [registrar addMethodCallDelegate:instance channel:channel];
  _channel_audioplayer = channel;
}

- (id)init {
  self = [super init];
  if (self) {
      _isDealloc = false;
      players = [[NSMutableDictionary alloc] init];
      imageDict = [[NSMutableDictionary alloc] initWithCapacity:0];
      [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(needStop) name:AudioplayersPluginStop object:nil];
      [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(handleInterruption:) name:AVAudioSessionInterruptionNotification object:[AVAudioSession sharedInstance]];
             
      [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(handleRouteChange:) name:AVAudioSessionRouteChangeNotification object:[AVAudioSession sharedInstance]];
      
      
    #if TARGET_OS_IPHONE
          // this method is used to listen to audio playpause event
          // from the notification area in the background.
          _headlessEngine = [[FlutterEngine alloc] initWithName:@"AudioPlayerIsolate"
                                                        project:nil];
          // This is the method channel used to communicate with
          // `_backgroundCallbackDispatcher` defined in the Dart portion of our plugin.
          // Note: we don't add a MethodCallDelegate for this channel now since our
          // BinaryMessenger needs to be initialized first, which is done in
          // `startHeadlessService` below.
          _callbackChannel = [FlutterMethodChannel
              methodChannelWithName:@"xyz.luan/audioplayers_callback"
                    binaryMessenger:_headlessEngine];
    #endif
  }
  return self;
}


- (void)needStop {
    _isDealloc = true;
    [self destroy];
}

- (void)handleInterruption:(NSNotification *)notification
{
    if([_playerIndex isEqualToString:@"1"]){
        return;
    }
    NSDictionary *info = notification.userInfo;
    AVAudioSessionInterruptionType type = [info[AVAudioSessionInterruptionTypeKey] unsignedIntegerValue];
    
    //AVAudioSessionInterruptionWasSuspendedKey
    bool _isPlaying = false;
    NSString * playerState;
    if (type == AVAudioSessionInterruptionTypeBegan) {
        if (@available(iOS 10.3, *)) {
            if([info.allKeys containsObject:AVAudioSessionInterruptionWasSuspendedKey]){
                BOOL isSuspend = [info[AVAudioSessionInterruptionWasSuspendedKey] boolValue];
                if(isSuspend){
                    return;
                }
            }
        } else {
            // Fallback on earlier versions
        }
        //to pause
        _isPlaying = false;
        playerState = @"paused";
    }else{
        AVAudioSessionInterruptionOptions options = [info[AVAudioSessionInterruptionOptionKey] unsignedIntegerValue];
        if (options == AVAudioSessionInterruptionOptionShouldResume) {
            // to play
            _isPlaying = true;
            playerState = @"playing";
            [self resume:_currentPlayerId];
        }
    }
    if(playerState != nil){
        [_channel_audioplayer invokeMethod:@"audio.onNotificationPlayerStateChanged" arguments:[NSDictionary dictionaryWithObjectsAndKeys:_currentPlayerId,@"playerId",@(_isPlaying),@"value",nil]];
        
        if (headlessServiceInitialized) {
          [_callbackChannel invokeMethod:@"audio.onNotificationBackgroundPlayerStateChanged" arguments:[NSDictionary dictionaryWithObjectsAndKeys:_currentPlayerId,@"playerId",@(_updateHandleMonitorKey),@"updateHandleMonitorKey",playerState,@"value",nil]];
            
        }
    }
    
}


- (void)handleRouteChange:(NSNotification *)notification
{
    if([_playerIndex isEqualToString:@"1"]){
        return;
    }
    if(_currentPlayerId == nil || @(_updateHandleMonitorKey) == nil){
        return;
    }
    NSDictionary *info = notification.userInfo;
    AVAudioSessionRouteChangeReason reason = [info[AVAudioSessionRouteChangeReasonKey] unsignedIntegerValue];
    if (reason == AVAudioSessionRouteChangeReasonOldDeviceUnavailable) {  //旧音频设备断开
        //获取上一线路描述信息
        AVAudioSessionRouteDescription *previousRoute = info[AVAudioSessionRouteChangePreviousRouteKey];
        //获取上一线路的输出设备类型
        AVAudioSessionPortDescription *previousOutput = previousRoute.outputs[0];
        NSString *portType = previousOutput.portType;
        if ([portType isEqualToString:AVAudioSessionPortHeadphones]
            || [portType isEqualToString:AVAudioSessionPortBluetoothLE]
            || [portType isEqualToString:AVAudioSessionPortBluetoothHFP]
            || [portType isEqualToString:AVAudioSessionPortBluetoothA2DP]) {
            [_channel_audioplayer invokeMethod:@"audio.onNotificationPlayerStateChanged" arguments:[NSDictionary dictionaryWithObjectsAndKeys:_currentPlayerId,@"playerId",@(NO),@"value",nil]];
            
            if (headlessServiceInitialized) {
              [_callbackChannel invokeMethod:@"audio.onNotificationBackgroundPlayerStateChanged" arguments:[NSDictionary dictionaryWithObjectsAndKeys:_currentPlayerId,@"playerId",@(_updateHandleMonitorKey),@"updateHandleMonitorKey",@"paused",@"value",nil]];
                
            }
        }
    }
}

#if TARGET_OS_IPHONE
    // Initializes and starts the background isolate which will process audio
    // events. `handle` is the handle to the callback dispatcher which we specified
    // in the Dart portion of the plugin.
    - (void)startHeadlessService:(int64_t)handle {
        // Lookup the information for our callback dispatcher from the callback cache.
        // This cache is populated when `PluginUtilities.getCallbackHandle` is called
        // and the resulting handle maps to a `FlutterCallbackInformation` object.
        // This object contains information needed by the engine to start a headless
        // runner, which includes the callback name as well as the path to the file
        // containing the callback.
        FlutterCallbackInformation *info = [FlutterCallbackCache lookupCallbackInformation:handle];
        NSAssert(info != nil, @"failed to find callback");
        NSString *entrypoint = info.callbackName;
        NSString *uri = info.callbackLibraryPath;

        // Here we actually launch the background isolate to start executing our
        // callback dispatcher, `_backgroundCallbackDispatcher`, in Dart.
        headlessServiceInitialized = [_headlessEngine runWithEntrypoint:entrypoint libraryURI:uri];
        if (headlessServiceInitialized) {
            // The headless runner needs to be initialized before we can register it as a
            // MethodCallDelegate or else we get an illegal memory access. If we don't
            // want to make calls from `_backgroundCallDispatcher` back to native code,
            // we don't need to add a MethodCallDelegate for this channel.
            [_registrar addMethodCallDelegate:self channel:_callbackChannel];
        }
    }
#endif

- (void)handleMethodCall:(FlutterMethodCall*)call result:(FlutterResult)result {
  NSString * playerId = call.arguments[@"playerId"];
  NSLog(@"%@ => call %@, playerId %@", osName, call.method, playerId);

  typedef void (^CaseBlock)(void);

  // Squint and this looks like a proper switch!
  NSDictionary *methods = @{
                @"startHeadlessService":
                  ^{
                      #if TARGET_OS_IPHONE
                          if (call.arguments[@"handleKey"] == nil)
                              result(0);
                          [self startHeadlessService:[call.arguments[@"handleKey"][0] longValue]];
                      #else
                          result(FlutterMethodNotImplemented);
                      #endif
                  },
                @"monitorNotificationStateChanges":
                  ^{
                    if (call.arguments[@"handleMonitorKey"] == nil)
                        result(0);
                    _updateHandleMonitorKey = [call.arguments[@"handleMonitorKey"][0] longLongValue];
                  },
                @"play":
                  ^{
                    NSLog(@"play!");
                    NSString *url = call.arguments[@"url"];
                    if (url == nil)
                        result(0);
                    if (call.arguments[@"isLocal"] == nil)
                        result(0);
                    if (call.arguments[@"volume"] == nil)
                        result(0);
                    if (call.arguments[@"position"] == nil)
                        result(0);
                    if (call.arguments[@"respectSilence"] == nil)
                        result(0);
                    if (call.arguments[@"recordingActive"] == nil)
                        result(0);
                    int isLocal = [call.arguments[@"isLocal"]intValue] ;
                    float volume = (float)[call.arguments[@"volume"] doubleValue] ;
                    int milliseconds = call.arguments[@"position"] == [NSNull null] ? 0.0 : [call.arguments[@"position"] intValue] ;
                    bool respectSilence = [call.arguments[@"respectSilence"] boolValue];
                    bool recordingActive = [call.arguments[@"recordingActive"] boolValue];
                    bool duckAudio = [call.arguments[@"duckAudio"]boolValue] ;

                    CMTime time = CMTimeMakeWithSeconds(milliseconds / 1000,NSEC_PER_SEC);
                    NSLog(@"isLocal: %d %@", isLocal, call.arguments[@"isLocal"] );
                    NSLog(@"volume: %f %@", volume, call.arguments[@"volume"] );
                    NSLog(@"position: %d %@", milliseconds, call.arguments[@"positions"] );
                    [self play:playerId url:url isLocal:isLocal volume:volume time:time isNotification:respectSilence duckAudio:duckAudio recordingActive:recordingActive];
                  },
                @"pause":
                  ^{
                    NSLog(@"pause");
                    [self pause:playerId];
                  },
                @"resume":
                  ^{
                    NSLog(@"resume");
                    [self resume:playerId];
                  },
                @"stop":
                  ^{
                    NSLog(@"stop");
                    [self stop:playerId];
                  },
                @"release":
                    ^{
                        NSLog(@"release");
                        [self stop:playerId];
                    },
                @"seek":
                  ^{
                    NSLog(@"seek");
                    if (!call.arguments[@"position"]) {
                      result(0);
                    } else {
                      int milliseconds = [call.arguments[@"position"] intValue];
                      NSLog(@"Seeking to: %d milliseconds", milliseconds);
                      [self seek:playerId time:CMTimeMakeWithSeconds(milliseconds / 1000,NSEC_PER_SEC)];
                    }
                  },
                @"setUrl":
                  ^{
                    NSLog(@"setUrl");
                    NSString *url = call.arguments[@"url"];
                    int isLocal = [call.arguments[@"isLocal"]intValue];
                    bool respectSilence = [call.arguments[@"respectSilence"]boolValue] ;
                    bool recordingActive = [call.arguments[@"recordingActive"]boolValue] ;
                    [ self setUrl:url
                          isLocal:isLocal
                          isNotification:respectSilence
                          playerId:playerId
                          recordingActive: recordingActive
                          onReady:^(NSString * playerId) {
                            result(@(1));
                          }
                    ];
                  },
                @"getDuration":
                    ^{
                        
                        int duration = [self getDuration:playerId];
                        NSLog(@"getDuration: %i ", duration);
                        result(@(duration));
                    },
                @"setVolume":
                  ^{
                    NSLog(@"setVolume");
                    float volume = (float)[call.arguments[@"volume"] doubleValue];
                    [self setVolume:volume playerId:playerId];
                  },
                @"getCurrentPosition":
                  ^{
                      int currentPosition = [self getCurrentPosition:playerId];
                      NSLog(@"getCurrentPosition: %i ", currentPosition);
                      result(@(currentPosition));
                  },
                @"setPlaybackRate":
                  ^{
                    NSLog(@"setPlaybackRate");
                    float playbackRate = (float)[call.arguments[@"playbackRate"] doubleValue];
                    [self setPlaybackRate:playbackRate playerId:playerId];
                  },
                @"setNotification":
                  ^{
                      #if TARGET_OS_IPHONE
                          NSLog(@"setNotification");
                          NSString *title = call.arguments[@"title"];
                          NSString *albumTitle = call.arguments[@"albumTitle"];
                          NSString *artist = call.arguments[@"artist"];
                          NSString *imageUrl = call.arguments[@"imageUrl"];

                          int forwardSkipInterval = [call.arguments[@"forwardSkipInterval"] intValue];
                          int backwardSkipInterval = [call.arguments[@"backwardSkipInterval"] intValue];
                          int duration = [call.arguments[@"duration"] intValue];
                          int elapsedTime = [call.arguments[@"elapsedTime"] intValue];
                          bool enablePreviousTrackButton = [call.arguments[@"hasPreviousTrack"] boolValue];
                          bool enableNextTrackButton = [call.arguments[@"hasNextTrack"] boolValue];
                      bool isPlay = [call.arguments[@"isPlay"] boolValue];
                          [self setNotification:title
                                     albumTitle:albumTitle
                                         artist:artist
                                       imageUrl:imageUrl
                            forwardSkipInterval:forwardSkipInterval
                           backwardSkipInterval:backwardSkipInterval
                                       duration:duration
                                    elapsedTime:elapsedTime
                           enablePreviousTrackButton:enablePreviousTrackButton
                          enableNextTrackButton:enableNextTrackButton
                                       playerId:playerId isPlay:isPlay];
                      #else
                          result(FlutterMethodNotImplemented);
                      #endif
                  },
                @"setReleaseMode":
                  ^{
                    NSLog(@"setReleaseMode");
                    NSString *releaseMode = call.arguments[@"releaseMode"];
                    bool looping = [releaseMode hasSuffix:@"LOOP"];
                    [self setLooping:looping playerId:playerId];
                  },
                @"earpieceOrSpeakersToggle":
                  ^{
                    NSLog(@"earpieceOrSpeakersToggle");
                    NSString *playingRoute = call.arguments[@"playingRoute"];
                    [self setPlayingRoute:playingRoute playerId:playerId];
                  },
                @"setCurrentPlyer":
                 ^{
                     NSString *playerIndex = call.arguments[@"playerIndex"];
                     // 0 audio 1 radio
                     _playerIndex = playerIndex;
                     MPRemoteCommand *pauseCommand = [remoteCommandCenter pauseCommand];
                     [pauseCommand setEnabled:YES];
                     MPRemoteCommand *playCommand = [remoteCommandCenter playCommand];
                     [playCommand setEnabled:YES];
                     MPRemoteCommand *togglePlayPauseCommand = [remoteCommandCenter togglePlayPauseCommand];
                     [togglePlayPauseCommand setEnabled:YES];
                     if([playerIndex isEqualToString:@"1"]){
                         
                           [pauseCommand removeTarget:self action:@selector(playOrPauseEvent:)];
                         
                           [playCommand removeTarget:self action:@selector(playOrPauseEvent:)];

                         [togglePlayPauseCommand removeTarget:self action:@selector(playOrPauseEvent:)];
                     }else{
                         [pauseCommand removeTarget:self];
                         [playCommand removeTarget:self];
                         [togglePlayPauseCommand removeTarget:self];
                         [pauseCommand addTarget:self action:@selector(playOrPauseEvent:)];
                       
                         [playCommand addTarget:self action:@selector(playOrPauseEvent:)];

                       [togglePlayPauseCommand addTarget:self action:@selector(playOrPauseEvent:)];
                     }
                 }
                };

  [ self initPlayerInfo:playerId ];
  CaseBlock c = methods[call.method];
  if (c) c(); else {
    NSLog(@"not implemented");
    result(FlutterMethodNotImplemented);
  }
  if(![call.method isEqualToString:@"setUrl"]) {
      if([call.method isEqualToString:@"play"]){
          isPlayingState = YES;
      }else if([call.method isEqualToString:@"pause"]){
          isPlayingState = NO;
      }
    result(@(1));
  }
}

-(void) initPlayerInfo: (NSString *) playerId {
  NSMutableDictionary * playerInfo = players[playerId];
  if (!playerInfo) {
    players[playerId] = [[NSDictionary dictionaryWithObjectsAndKeys:@false,@"isPlaying",@(1.0),@"volume",@(_defaultPlaybackRate),@"rate",@(false),@"looping",_defaultPlayingRoute,@"playingRoute",nil] mutableCopy];
      
  }
}

#if TARGET_OS_IPHONE
    -(void) setNotification: (NSString *) title
            albumTitle:  (NSString *) albumTitle
            artist:  (NSString *) artist
            imageUrl:  (NSString *) imageUrl
            forwardSkipInterval:  (int) forwardSkipInterval
            backwardSkipInterval:  (int) backwardSkipInterval
            duration:  (int) duration
            elapsedTime:  (int) elapsedTime
            enablePreviousTrackButton: (BOOL)enablePreviousTrackButton
            enableNextTrackButton: (BOOL)enableNextTrackButton
            playerId: (NSString*) playerId
                     isPlay:(bool)isPlay{
        _title = title;
        _albumTitle = albumTitle;
        _artist = artist;
        _imageUrl = imageUrl;
        _duration = duration;

        _infoCenter = [MPNowPlayingInfoCenter defaultCenter];
        
        [ self updateNotification:elapsedTime isPlay:isPlay];

        if (remoteCommandCenter == nil) {
          remoteCommandCenter = [MPRemoteCommandCenter sharedCommandCenter];

            MPRemoteCommand *pauseCommand = [remoteCommandCenter pauseCommand];
            [pauseCommand setEnabled:YES];
              [pauseCommand addTarget:self action:@selector(playOrPauseEvent:)];

            MPRemoteCommand *playCommand = [remoteCommandCenter playCommand];
            [playCommand setEnabled:YES];
              [playCommand addTarget:self action:@selector(playOrPauseEvent:)];

            MPRemoteCommand *togglePlayPauseCommand = [remoteCommandCenter togglePlayPauseCommand];
            [togglePlayPauseCommand setEnabled:YES];
            [togglePlayPauseCommand addTarget:self action:@selector(playOrPauseEvent:)];
        }
        
        if (forwardSkipInterval > 0 || backwardSkipInterval > 0) {
          MPSkipIntervalCommand *skipBackwardIntervalCommand = [remoteCommandCenter skipBackwardCommand];
          [skipBackwardIntervalCommand setEnabled:YES];
          [skipBackwardIntervalCommand addTarget:self action:@selector(skipBackwardEvent:)];
          skipBackwardIntervalCommand.preferredIntervals = @[@(backwardSkipInterval)];  // Set your own interval

          MPSkipIntervalCommand *skipForwardIntervalCommand = [remoteCommandCenter skipForwardCommand];
          skipForwardIntervalCommand.preferredIntervals = @[@(forwardSkipInterval)];  // Max 99
          [skipForwardIntervalCommand setEnabled:YES];
          [skipForwardIntervalCommand addTarget:self action:@selector(skipForwardEvent:)];
        }
        else {  // if skip interval not set using next and previous
          MPRemoteCommand *nextTrackCommand = [remoteCommandCenter nextTrackCommand];
          [nextTrackCommand setEnabled:enableNextTrackButton];
          [nextTrackCommand addTarget:self action:@selector(nextTrackEvent:)];
          
          MPRemoteCommand *previousTrackCommand = [remoteCommandCenter previousTrackCommand];
          [previousTrackCommand setEnabled:enablePreviousTrackButton];
          [previousTrackCommand addTarget:self action:@selector(previousTrackEvent:)];
        }
        
        if (@available(iOS 9.1, *)) {
            MPRemoteCommand* changePlaybackPositionCommand = [remoteCommandCenter changePlaybackPositionCommand];
            [changePlaybackPositionCommand setEnabled:YES];
            [changePlaybackPositionCommand addTarget:self action:@selector(onChangePlaybackPositionCommand:)];
        } else {
            // Fallback on earlier versions
        }
    }

    -(MPRemoteCommandHandlerStatus) skipBackwardEvent: (MPSkipIntervalCommandEvent *) skipEvent {
        NSLog(@"Skip backward by %f", skipEvent.interval);
        NSMutableDictionary * playerInfo = players[_currentPlayerId];
        AVPlayer *player = playerInfo[@"player"];
        AVPlayerItem *currentItem = player.currentItem;
        CMTime currentTime = currentItem.currentTime;
        CMTime newTime = CMTimeSubtract(currentTime, CMTimeMakeWithSeconds(skipEvent.interval, NSEC_PER_SEC));
        // if CMTime is negative, set it to zero
        if (CMTimeGetSeconds(newTime) < 0) {
          [ self seek:_currentPlayerId time:CMTimeMakeWithSeconds(0,1) ];
        } else {
          [ self seek:_currentPlayerId time:newTime ];
        }
        return MPRemoteCommandHandlerStatusSuccess;
    }

    -(MPRemoteCommandHandlerStatus) skipForwardEvent: (MPSkipIntervalCommandEvent *) skipEvent {
        NSLog(@"Skip forward by %f", skipEvent.interval);
        NSMutableDictionary * playerInfo = players[_currentPlayerId];
        AVPlayer *player = playerInfo[@"player"];
        AVPlayerItem *currentItem = player.currentItem;
        CMTime currentTime = currentItem.currentTime;
        CMTime maxDuration = currentItem.duration;
        CMTime newTime = CMTimeAdd(currentTime, CMTimeMakeWithSeconds(skipEvent.interval, NSEC_PER_SEC));
        // if CMTime is more than max duration, limit it
        if (CMTimeGetSeconds(newTime) > CMTimeGetSeconds(maxDuration)) {
          [ self seek:_currentPlayerId time:maxDuration ];
        } else {
          [ self seek:_currentPlayerId time:newTime ];
        }
        return MPRemoteCommandHandlerStatusSuccess;
    }

    -(MPRemoteCommandHandlerStatus) nextTrackEvent: (MPRemoteCommandEvent *) nextTrackEvent {
       NSLog(@"nextTrackEvent");

       [_channel_audioplayer invokeMethod:@"audio.onGotNextTrackCommand" arguments:[NSDictionary dictionaryWithObjectsAndKeys:_currentPlayerId,@"playerId",nil]];
        
       return MPRemoteCommandHandlerStatusSuccess;
    }

    -(MPRemoteCommandHandlerStatus) previousTrackEvent: (MPRemoteCommandEvent *) previousTrackEvent {
      NSLog(@"previousTrackEvent");

        [_channel_audioplayer invokeMethod:@"audio.onGotPreviousTrackCommand" arguments:[NSDictionary dictionaryWithObjectsAndKeys:_currentPlayerId,@"playerId",nil]];
        
        return MPRemoteCommandHandlerStatusSuccess;
    }

-(MPRemoteCommandHandlerStatus) playOrPauseEvent: (MPRemoteCommandEvent *) playOrPauseEvent {
    // judge current player is audio or not
//    if([_playerIndex isEqualToString:@"1"]){
//        return MPRemoteCommandHandlerStatusCommandFailed;
//    }

    NSMutableDictionary * playerInfo = players[_currentPlayerId];
    AVPlayer *player = playerInfo[@"player"];
    bool _isPlaying = false;
    NSString *playerState = @"";
    if (@available(iOS 10.0, *)) {
        if (player.timeControlStatus == AVPlayerTimeControlStatusPlaying) {
            [ self pause:_currentPlayerId ];
            _isPlaying = false;
            playerState = @"paused";
        } else if (player.timeControlStatus == AVPlayerTimeControlStatusPaused) {
            // player is paused and resume it
            [ self resume:_currentPlayerId ];
            _isPlaying = true;
            playerState = @"playing";
        }
    } else {
        // Fallback on earlier versions
    }
    [_channel_audioplayer invokeMethod:@"audio.onNotificationPlayerStateChanged" arguments:[NSDictionary dictionaryWithObjectsAndKeys:_currentPlayerId,@"playerId",@(_isPlaying),@"value",nil]];
    
    if (headlessServiceInitialized) {
      [_callbackChannel invokeMethod:@"audio.onNotificationBackgroundPlayerStateChanged" arguments:[NSDictionary dictionaryWithObjectsAndKeys:_currentPlayerId,@"playerId",@(_updateHandleMonitorKey),@"updateHandleMonitorKey",playerState,@"value",nil]];
        
    }
    return MPRemoteCommandHandlerStatusSuccess;
}

    -(MPRemoteCommandHandlerStatus) onChangePlaybackPositionCommand: (MPChangePlaybackPositionCommandEvent *) changePositionEvent {
        NSLog(@"changePlaybackPosition to %f", changePositionEvent.positionTime);
        CMTime newTime = CMTimeMakeWithSeconds(changePositionEvent.positionTime, NSEC_PER_SEC);
        [ self seek:_currentPlayerId time:newTime ];
        return MPRemoteCommandHandlerStatusSuccess;
    }

-(void) updateNotification: (int) elapsedTime isPlay:(bool)isPlay{
      NSMutableDictionary *playingInfo = [NSMutableDictionary dictionary];
      playingInfo[MPMediaItemPropertyTitle] = _title;
      playingInfo[MPMediaItemPropertyAlbumTitle] = _albumTitle;
      playingInfo[MPMediaItemPropertyArtist] = _artist;
    
    playingInfo[MPMediaItemPropertyPlaybackDuration] = [NSNumber numberWithInt: _duration];
      // From `MPNowPlayingInfoPropertyElapsedPlaybackTime` docs -- it is not recommended to update this value frequently. Thus it should represent integer seconds and not an accurate `CMTime` value with fractions of a second
    
    float rate = isPlay ? 1.0 : 0.0;
    playingInfo[MPNowPlayingInfoPropertyPlaybackRate] = @(rate);
    
    playingInfo[MPNowPlayingInfoPropertyElapsedPlaybackTime] = [NSNumber numberWithInt: elapsedTime];
    NSLog(@"setNotification done");

    
      
      // fetch notification image in async fashion to avoid freezing UI
          NSURL *url = [[NSURL alloc] initWithString:_imageUrl];
         
          if([_imageUrl hasPrefix:@"http"]){
              if([imageDict.allKeys containsObject:_imageUrl]){
                  UIImage * image = imageDict[_imageUrl];
                  MPMediaItemArtwork *albumArt = [[MPMediaItemArtwork alloc] initWithImage: image];
                  playingInfo[MPMediaItemPropertyArtwork] = albumArt;
                  if (_infoCenter != nil) {
                    _infoCenter.nowPlayingInfo = playingInfo;
                  }
              }else{
                  if (_infoCenter != nil) {
                    _infoCenter.nowPlayingInfo = playingInfo;
                  }
                  [self downloadImage:url completion:^(UIImage *image,NSString*urlStr) {
                      if(image){
                          MPMediaItemArtwork *albumArt = [[MPMediaItemArtwork alloc] initWithImage:image];
                          [imageDict setObject:image forKey:urlStr];
                          if([_playerIndex isEqualToString:@"1"]){
                              return;
                          }
                          if(![urlStr isEqualToString:_imageUrl]){
                              return;
                          }
                          NSMutableDictionary *dict = [NSMutableDictionary dictionaryWithDictionary:[_infoCenter nowPlayingInfo]];
                          
                                        [dict setObject:albumArt forKey:MPMediaItemPropertyArtwork];
                                        [_infoCenter setNowPlayingInfo:dict];
                      }
                      
                  }];
              }
              
                  
          }else{
              UIImage* image = [UIImage imageWithContentsOfFile:_imageUrl];
              if(image){
                  MPMediaItemArtwork *albumArt = [[MPMediaItemArtwork alloc] initWithImage: image];
                  playingInfo[MPMediaItemPropertyArtwork] = albumArt;
              }
              if (_infoCenter != nil) {
                _infoCenter.nowPlayingInfo = playingInfo;
              }
          }
    
    }
#endif

-(void)downloadImage:(NSURL*)url completion:(void(^)(UIImage * image,NSString * urlStr))completion{
    [[[NSURLSession sharedSession] dataTaskWithURL:url completionHandler:^(NSData * _Nullable data, NSURLResponse * _Nullable response, NSError * _Nullable error) {
        dispatch_async(dispatch_get_main_queue(), ^{
            completion([UIImage imageWithData:data],url.absoluteString);
        });
        }] resume];
}

-(void) setUrl: (NSString*) url
       isLocal: (bool) isLocal
       isNotification: (bool) respectSilence
       playerId: (NSString*) playerId
       recordingActive: (bool) recordingActive
       onReady:(VoidCallback)onReady
{
  NSMutableDictionary * playerInfo = players[playerId];
  AVPlayer *player = playerInfo[@"player"];
  NSMutableSet *observers = playerInfo[@"observers"];
  AVPlayerItem *playerItem;
    
  NSLog(@"setUrl %@", url);
    
  #if TARGET_OS_IPHONE
      // code moved from play() to setUrl() to fix the bug of audio not playing in ios background
      NSError *error = nil;
      BOOL success = false;
    
      AVAudioSessionCategory category;
      if (recordingActive) {
        category = AVAudioSessionCategoryPlayAndRecord;
      } else {
        category = respectSilence ? AVAudioSessionCategoryAmbient : AVAudioSessionCategoryPlayback;
      }
      // When using AVAudioSessionCategoryPlayback, by default, this implies that your app’s audio is nonmixable—activating your session
      // will interrupt any other audio sessions which are also nonmixable. AVAudioSessionCategoryPlayback should not be used with
      // AVAudioSessionCategoryOptionMixWithOthers option. If so, it prevents infoCenter from working correctly.
      if (respectSilence) {
        success = [[AVAudioSession sharedInstance] setCategory:category withOptions:AVAudioSessionCategoryOptionMixWithOthers error:&error];
      } else {
        success = [[AVAudioSession sharedInstance] setCategory:category error:&error];
//        [[UIApplication sharedApplication] beginReceivingRemoteControlEvents];
      }
      
      if ([playerInfo[@"playingRoute"] isEqualToString:@"earpiece"]) {
        // Use earpiece speaker to play audio.
        success = [[AVAudioSession sharedInstance] setCategory:AVAudioSessionCategoryPlayAndRecord error:&error];
      }

      if (!success) {
        NSLog(@"Error setting speaker: %@", error);
      }
      [[AVAudioSession sharedInstance] setActive:YES error:&error];
  #endif
    
//  BOOL playbackFailed = ([[player currentItem] status] == AVPlayerItemStatusFailed);
    
//  if (!playerInfo || ![url isEqualToString:playerInfo[@"url"]] || playbackFailed) {
    if (isLocal) {
      playerItem = [ [ AVPlayerItem alloc ] initWithURL:[ NSURL fileURLWithPath:url ]];
    } else {
      playerItem = [ [ AVPlayerItem alloc ] initWithURL:[ NSURL URLWithString:url ]];
    }
      
    if (playerInfo[@"url"]) {
      [[player currentItem] removeObserver:self forKeyPath:@"status" ];
//        [[player currentItem] removeObserver:self forKeyPath:@"playbackBufferEmpty" ];
      [ playerInfo setObject:url forKey:@"url" ];

      for (id ob in observers) {
         [ [ NSNotificationCenter defaultCenter ] removeObserver:ob ];
      }
      [ observers removeAllObjects ];
      [ player replaceCurrentItemWithPlayerItem: playerItem ];
    } else {
      player = [[ AVPlayer alloc ] initWithPlayerItem: playerItem ];
//        if (@available(iOS 10.0, *)) {
//            player.automaticallyWaitsToMinimizeStalling = NO;
//        } else {
//            // Fallback on earlier versions
//        }

      observers = [[NSMutableSet alloc] init];

      [ playerInfo setObject:player forKey:@"player" ];
      [ playerInfo setObject:url forKey:@"url" ];
      [ playerInfo setObject:observers forKey:@"observers" ];

      // stream player position
//      CMTime interval = CMTimeMakeWithSeconds(0.2, NSEC_PER_SEC);
//      id timeObserver = [ player  addPeriodicTimeObserverForInterval: interval queue: nil usingBlock:^(CMTime time){
//        [self onTimeInterval:playerId time:time];
//      }];
//        [timeobservers addObject:@{@"player":player, @"observer":timeObserver}];
    }
      
    id anobserver = [[ NSNotificationCenter defaultCenter ] addObserverForName: AVPlayerItemDidPlayToEndTimeNotification
                                                                        object: playerItem
                                                                         queue: nil
                                                                    usingBlock:^(NSNotification* note){
                                                                        [self onSoundComplete:playerId];
                                                                    }];
    [observers addObject:anobserver];
      
    // is sound ready
    [playerInfo setObject:onReady forKey:@"onReady"];
    [playerItem addObserver:self
                          forKeyPath:@"status"
                          options:0
                          context:(void*)playerId];
//    [playerItem addObserver:self forKeyPath:@"playbackBufferEmpty" options:0 context:(void*)playerId];
      
//  } else {
//    if ([[player currentItem] status ] == AVPlayerItemStatusReadyToPlay) {
//        onReady(playerId);
//        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.2 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
//            [self updateDuration:playerId];
//        });
//    }
//  }
}

-(void) play: (NSString*) playerId
         url: (NSString*) url
     isLocal: (bool) isLocal
      volume: (float) volume
        time: (CMTime) time
      isNotification: (bool) respectSilence
      duckAudio: (bool) duckAudio
recordingActive: (bool) recordingActive
{
  NSError *error = nil;
  AVAudioSessionCategory category = respectSilence ? AVAudioSessionCategoryAmbient : AVAudioSessionCategoryPlayback;
    
  BOOL success = false;
  if (duckAudio) {
    success = [[AVAudioSession sharedInstance]
                    setCategory: category
            withOptions: AVAudioSessionCategoryOptionDuckOthers
                    error:&error];
  } else {
    success = [[AVAudioSession sharedInstance]
                    setCategory: category
                    error:&error];
  }

  if (!success) {
    NSLog(@"Error setting speaker: %@", error);
  }
  [[AVAudioSession sharedInstance] setActive:YES error:&error];

  [ self setUrl:url
         isLocal:isLocal
         isNotification:respectSilence
         playerId:playerId
         recordingActive: recordingActive
         onReady:^(NSString * playerId) {
           NSMutableDictionary * playerInfo = players[playerId];
           AVPlayer *player = playerInfo[@"player"];
           [ player setVolume:volume ];
           [ player seekToTime:time ];

           if (@available(iOS 10.0, *)) {
             float playbackRate = [playerInfo[@"rate"] floatValue];
             [player playImmediatelyAtRate:playbackRate];
           } else {
             [player play];
           }

           [ playerInfo setObject:@true forKey:@"isPlaying" ];
         }
  ];
  #if TARGET_OS_IPHONE
    _currentPlayerId = playerId; // to be used for notifications command center
  #endif
}

-(void) updateDuration: (NSString *) playerId
{
  NSMutableDictionary * playerInfo = players[playerId];
  AVPlayer *player = playerInfo[@"player"];

  CMTime duration = [[[player currentItem]  asset] duration];
  NSLog(@"%@ -> updateDuration...%f", osName, CMTimeGetSeconds(duration));
  if(CMTimeGetSeconds(duration)>0){
    NSLog(@"%@ -> invokechannel", osName);
    int mseconds = [self getMillisecondsFromCMTime:duration];
    [_channel_audioplayer invokeMethod:@"audio.onDuration" arguments:[NSDictionary dictionaryWithObjectsAndKeys:playerId,@"playerId",@(mseconds),@"value",nil]];
  }
}

-(int) getDuration: (NSString *) playerId {
    NSMutableDictionary * playerInfo = players[playerId];
    AVPlayer *player = playerInfo[@"player"];
    
    CMTime duration = [[[player currentItem]  asset] duration];
    int mseconds = [self getMillisecondsFromCMTime:duration];
    return mseconds;
}

-(int) getCurrentPosition: (NSString *) playerId {
    NSMutableDictionary * playerInfo = players[playerId];
    AVPlayer *player = playerInfo[@"player"];

    CMTime duration = [player currentTime];
    int mseconds = [self getMillisecondsFromCMTime:duration];
    return mseconds;
}

// No need to spam the logs with every time interval update
-(void) onTimeInterval: (NSString *) playerId
                  time: (CMTime) time {
    // NSLog(@"%@ -> onTimeInterval...", osName);
    if (_isDealloc) {
        return;
    }
    int mseconds = [self getMillisecondsFromCMTime:time];
    
    [_channel_audioplayer invokeMethod:@"audio.onCurrentPosition" arguments:[NSDictionary dictionaryWithObjectsAndKeys:playerId,@"playerId",@(mseconds),@"value",nil]];
}

-(void) pause: (NSString *) playerId {
  NSMutableDictionary * playerInfo = players[playerId];
  AVPlayer *player = playerInfo[@"player"];

  [ player pause ];
  [playerInfo setObject:@false forKey:@"isPlaying"];
}

-(void) resume: (NSString *) playerId {
  NSMutableDictionary * playerInfo = players[playerId];
  AVPlayer *player = playerInfo[@"player"];
  float playbackRate = [playerInfo[@"rate"] floatValue];

  #if TARGET_OS_IPHONE
    _currentPlayerId = playerId; // to be used for notifications command center
  #endif

  if (@available(iOS 10.0, *)) {
    [player playImmediatelyAtRate:playbackRate];
  } else {
    [player play];
  }
  [playerInfo setObject:@true forKey:@"isPlaying"];
}

-(void) setVolume: (float) volume
        playerId:  (NSString *) playerId {
  NSMutableDictionary *playerInfo = players[playerId];
  AVPlayer *player = playerInfo[@"player"];
  playerInfo[@"volume"] = @(volume);
  [ player setVolume:volume ];
}

-(void) setPlaybackRate: (float) playbackRate
        playerId:  (NSString *) playerId {
  NSLog(@"%@ -> calling setPlaybackRate", osName);
  
  NSMutableDictionary *playerInfo = players[playerId];
  AVPlayer *player = playerInfo[@"player"];
  playerInfo[@"rate"] = @(playbackRate);
  [ player setRate:playbackRate ];
  #if TARGET_OS_IPHONE
      if (_infoCenter != nil) {
        AVPlayerItem *currentItem = player.currentItem;
        CMTime currentTime = currentItem.currentTime;
          BOOL isPlay = [playerInfo[@"isPlaying"] boolValue];
        [ self updateNotification:CMTimeGetSeconds(currentTime) isPlay:isPlay];
      }
  #endif
}

-(void) setLooping: (bool) looping
        playerId:  (NSString *) playerId {
  NSMutableDictionary *playerInfo = players[playerId];
  [playerInfo setObject:@(looping) forKey:@"looping"];
}

-(void) setPlayingRoute: (NSString *) playingRoute
               playerId: (NSString *) playerId {
  NSLog(@"%@ -> calling setPlayingRoute", osName);
  NSMutableDictionary *playerInfo = players[playerId];
  [playerInfo setObject:(playingRoute) forKey:@"playingRoute"];

  BOOL success = false;
  NSError *error = nil;
  if ([playingRoute isEqualToString:@"earpiece"]) {
    // Use earpiece speaker to play audio.
    success = [[AVAudioSession sharedInstance] setCategory:AVAudioSessionCategoryPlayAndRecord error:&error];
  } else {
    success = [[AVAudioSession sharedInstance] setCategory:AVAudioSessionCategoryPlayback error:&error];
  }
  if (!success) {
    NSLog(@"Error setting playing route: %@", error);
  }
}

-(void) stop: (NSString *) playerId {
  NSMutableDictionary * playerInfo = players[playerId];

  if ([playerInfo[@"isPlaying"] boolValue]) {
    [ self pause:playerId ];
    [ self seek:playerId time:CMTimeMake(0, 1) ];
    [playerInfo setObject:@false forKey:@"isPlaying"];
  }
}

-(void) seek: (NSString *) playerId
        time: (CMTime) time {
  NSMutableDictionary * playerInfo = players[playerId];
  AVPlayer *player = playerInfo[@"player"];
  #if TARGET_OS_IPHONE
  [[player currentItem] seekToTime:time completionHandler:^(BOOL finished) {
      if (finished) {
          NSLog(@"ios -> seekComplete...");
          int seconds = CMTimeGetSeconds(time);
          if (_infoCenter != nil) {
              bool isPlay = [playerInfo[@"isPlaying"] boolValue];
            [ self updateNotification:seconds isPlay:isPlay];
          }
          [ _channel_audioplayer invokeMethod:@"audio.onSeekComplete" arguments:[NSDictionary dictionaryWithObjectsAndKeys:playerId,@"playerId",@(YES),@"value",nil]];
          
          [ _channel_audioplayer invokeMethod:@"audio.onSeekPosition" arguments:[NSDictionary dictionaryWithObjectsAndKeys:playerId,@"playerId",@(seconds*1000),@"value",nil]];
          
      }else{
          NSLog(@"ios -> seekCancelled...");
          [ _channel_audioplayer invokeMethod:@"audio.onSeekComplete" arguments:[NSDictionary dictionaryWithObjectsAndKeys:playerId,@"playerId",@(NO),@"value",nil]];
          
      }
  }];
  #else
  [[player currentItem] seekToTime:time];
  #endif
}

-(void) onSoundComplete: (NSString *) playerId {
  NSLog(@"%@ -> onSoundComplete...", osName);
  NSMutableDictionary * playerInfo = players[playerId];

  if (![playerInfo[@"isPlaying"] boolValue]) {
    return;
  }

  [ self pause:playerId ];
    [ self seek:playerId time:CMTimeMakeWithSeconds(0,1) ];

  if ([ playerInfo[@"looping"] boolValue]) {
    [ self seek:playerId time:CMTimeMakeWithSeconds(0,1) ];
    [ self resume:playerId ];
  }

  [ _channel_audioplayer invokeMethod:@"audio.onComplete" arguments:[NSDictionary dictionaryWithObjectsAndKeys:playerId,@"playerId",nil]];
    
  NSError *error = nil;
    [[AVAudioSession sharedInstance] setActive:NO error:&error];
  #if TARGET_OS_IPHONE
      if (headlessServiceInitialized) {
          [_callbackChannel invokeMethod:@"audio.onNotificationBackgroundPlayerStateChanged" arguments:[NSDictionary dictionaryWithObjectsAndKeys:playerId,@"playerId",@(_updateHandleMonitorKey),@"updateHandleMonitorKey",@"completed",@"value",nil]];
          
      }
  #endif
}
    
-(int) getMillisecondsFromCMTime: (CMTime) time {
    Float64 seconds = CMTimeGetSeconds(time);
    int milliseconds = seconds * 1000;
    return milliseconds;
}

-(void)observeValueForKeyPath:(NSString *)keyPath
                     ofObject:(id)object
                       change:(NSDictionary *)change
                      context:(void *)context {
  if ([keyPath isEqualToString: @"status"]) {
    NSString *playerId = (__bridge NSString*)context;
    NSMutableDictionary * playerInfo = players[playerId];
    AVPlayer *player = playerInfo[@"player"];

    NSLog(@"player status: %ld",(long)[[player currentItem] status ]);

    // Do something with the status...
    if ([[player currentItem] status ] == AVPlayerItemStatusReadyToPlay) {
        if([_playerIndex isEqualToString:@"1"]){
            return;
        }
      [self updateDuration:playerId];

      VoidCallback onReady = playerInfo[@"onReady"];
      if (onReady != nil && isPlayingState) {
        [playerInfo removeObjectForKey:@"onReady"];
        onReady(playerId);
      }
    } else if ([[player currentItem] status ] == AVPlayerItemStatusFailed) {
      [_channel_audioplayer invokeMethod:@"audio.onError" arguments:[NSDictionary dictionaryWithObjectsAndKeys:playerId,@"playerId",@"AVPlayerItemStatus.failed",@"value",nil]];
        
    }
//  }else if([keyPath isEqualToString:@"playbackBufferEmpty"]){
//      NSMutableDictionary * playerInfo = players[_currentPlayerId];
//      AVPlayer *player = playerInfo[@"player"];
//      if([player currentItem].playbackBufferEmpty == YES){
//          NSLog(@"========== error  2");
//          [_channel_audioplayer invokeMethod:@"audio.onError" arguments:@{@"playerId": _currentPlayerId, @"value": @"AVPlayerItemStatus.failed"}];
//          NSMutableDictionary *dict = [NSMutableDictionary dictionaryWithDictionary:[_infoCenter nowPlayingInfo]];
//          [dict setObject:@(CMTimeGetSeconds(player.currentTime)) forKey:MPNowPlayingInfoPropertyElapsedPlaybackTime];
//
//              [dict setObject:@(0) forKey:MPNowPlayingInfoPropertyPlaybackRate];
//              [_infoCenter setNowPlayingInfo:dict];
//      }
  }else {
    // Any unrecognized context must belong to super
    [super observeValueForKeyPath:keyPath
                         ofObject:object
                           change:change
                          context:context];
  }
}

- (void)destroy {
    for (id value in timeobservers)
    [value[@"player"] removeTimeObserver:value[@"observer"]];
    timeobservers = nil;
    
    for (NSString* playerId in players) {
        NSMutableDictionary * playerInfo = players[playerId];
        NSMutableSet * observers = playerInfo[@"observers"];
        for (id ob in observers)
        [[NSNotificationCenter defaultCenter] removeObserver:ob];
    }
    players = nil;
}
    
- (void)dealloc {
    [self destroy];
    [[NSNotificationCenter defaultCenter] removeObserver:self];
}


@end
