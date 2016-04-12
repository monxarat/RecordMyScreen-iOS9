//
//  CSScreenRecorder.m
//  RecordMyScreen
//
//  Created by Aditya KD on 02/04/13.
//  Copyright (c) 2013 CoolStar Organization. All rights reserved.
//

#import "CSScreenRecorder.h"

#import <IOMobileFrameBuffer.h>
#import <CoreVideo/CVPixelBuffer.h>
#import <QuartzCore/QuartzCore.h>

#include <IOSurface.h>
#include <sys/time.h>

#include "Utilities.h"
#include "mediaserver.h"
#include "mp4v2/mp4v2.h"

void CARenderServerRenderDisplay(kern_return_t a, CFStringRef b, IOSurfaceRef surface, int x, int y);

@interface CSScreenRecorder ()
{
@private
    BOOL                _isRecording;
    int                 _kbps;
    int                 _fps;
    
    //surface
    IOSurfaceRef        _surface;
    int                 _bytesPerRow;
    int                 _width;
    int                 _height;
    
    dispatch_queue_t    _videoQueue;
    
    NSLock             *_pixelBufferLock;
    NSTimer            *_recordingTimer;
    NSDate             *_recordStartDate;
    
    AVAudioRecorder    *_audioRecorder;
    AVAssetWriter      *_videoWriter;
    AVAssetWriterInput *_videoWriterInput;
    AVAssetWriterInputPixelBufferAdaptor *_pixelBufferAdaptor;
}

- (void)_setupVideoContext;
- (void)_setupAudio;
- (void)_setupVideoAndStartRecording;
//- (void)_captureShot:(CMTime)frameTime;
//- (IOSurfaceRef)_createScreenSurface;
- (void)_finishEncoding;

- (void)_sendDelegateTimeUpdate:(NSTimer *)timer;

@end

@implementation CSScreenRecorder

- (instancetype)init
{
    if ((self = [super init])) {
        _pixelBufferLock = [NSLock new];
        
        //video queue
        _videoQueue = dispatch_queue_create("video_queue", DISPATCH_QUEUE_SERIAL);
        //frame rate
        _fps = 24;
        //encoding kbps
        _kbps = 5000;
    }
    return self;
}

- (void)dealloc
{
    CFRelease(_surface);
    _surface = NULL;
    
    dispatch_release(_videoQueue);
    _videoQueue = NULL;
    
    [_pixelBufferLock release];
    _pixelBufferLock = nil;
    
    [_videoOutPath release];
    _videoOutPath = nil;
    
    _recordingTimer = nil;
    // These are released when capture stops, etc, but what if?
    // You don't want to leak memory!
    [_recordStartDate release];
    _recordStartDate = nil;
    
    [_audioRecorder release];
    _audioRecorder = nil;
    
    [_videoWriter release];
    _videoWriter = nil;
    
    [_videoWriterInput release];
    _videoWriterInput = nil;
    
    [_pixelBufferAdaptor release];
    _pixelBufferAdaptor = nil;
    
    [super dealloc];
}


MP4FileHandle hMp4file = MP4_INVALID_FILE_HANDLE;
MP4TrackId    m_videoId = MP4_INVALID_TRACK_ID;
MP4TrackId    m_audioId = MP4_INVALID_TRACK_ID;
static int    mp4_init_flag = 0;

#define SAVE_264_ENABLE 0


#if SAVE_264_ENABLE
FILE  *m_handle = NULL;
#endif


void video_open(void *cls,int width,int height,const void *buffer, int buflen, int payloadtype, double timestamp)
{
    
    
    int		    rLen;
    int			nalSize;
    unsigned    char *data;
    
    int spscnt;
    int spsnalsize;
    unsigned char *sps;
    int ppscnt;
    int ppsnalsize;
    unsigned char *pps;
    
    //rLen = 0;
    data = (unsigned char *)buffer ;
    
    spscnt = data[5] & 0x1f;
    spsnalsize = ((uint32_t)data[6] << 8) | ((uint32_t)data[7]);
    ppscnt = data[8 + spsnalsize];
    ppsnalsize = ((uint32_t)data[9 + spsnalsize] << 8) | ((uint32_t)data[10 + spsnalsize]);
    
    sps = (unsigned char *)malloc(spsnalsize );
    pps = (unsigned char *)malloc(ppsnalsize);
    
    
    memcpy(sps, data + 8, spsnalsize);
    
    
    
    memcpy(pps, data + 11 + spsnalsize, ppsnalsize);
    
    
    
    
    
    
    
    //int i;
    
    NSString *fileName;
    
    

    
    fileName = [Utilities documentsPath:[NSString stringWithFormat:@"XinDawnRec-%04d.mp4",rand()]];
    
    
    hMp4file = MP4Create([fileName cStringUsingEncoding: NSUTF8StringEncoding],0);
    
    
    
    MP4SetTimeScale(hMp4file, 90000);
    
    
    
    m_videoId = MP4AddH264VideoTrack
    (hMp4file,
     90000,
     90000 / 60,
     width, // width
     height,// height
     sps[1], // sps[1] AVCProfileIndication
     sps[2], // sps[2] profile_compat
     sps[3], // sps[3] AVCLevelIndication
     3);           // 4 bytes length before each NAL unit
    if (m_videoId == MP4_INVALID_TRACK_ID)
    {
        printf("add video track failed.\n");
        //return false;
    }
    MP4SetVideoProfileLevel(hMp4file, 0x7f); //  Simple Profile @ Level 3
    
    // write sps
    MP4AddH264SequenceParameterSet(hMp4file, m_videoId, sps, spsnalsize);
    
    
    
    // write pps
    MP4AddH264PictureParameterSet(hMp4file, m_videoId, pps, ppsnalsize);
    
    
    
    free(sps);
    free(pps);
    
    
    
    unsigned char eld_conf[2] = { 0x12, 0x10 };
    
    m_audioId = MP4AddAudioTrack(hMp4file, 44100, 1024, MP4_MPEG4_AUDIO_TYPE);  //sampleDuration.
    if (m_audioId == MP4_INVALID_TRACK_ID)
    {
        printf("add video track failed.\n");
        //return false;
    }
    
    
    MP4SetAudioProfileLevel(hMp4file, 0x0F);
    MP4SetTrackESConfiguration(hMp4file, m_audioId, &eld_conf[0], 2);
    
    
    
#if SAVE_264_ENABLE
    {
        NSString *fileName264 = [Utilities documentsPath:[NSString stringWithFormat:@"XinDawnRec-%04d.264",rand()]];
        
        m_handle = fopen([fileName264 cStringUsingEncoding: NSUTF8StringEncoding], "wb");
        
        
        
        int spscnt;
        int spsnalsize;
        int ppscnt;
        int ppsnalsize;
        
        unsigned    char *head = (unsigned  char *)buffer;
        
        
        
        
        spscnt = head[5] & 0x1f;
        spsnalsize = ((uint32_t)head[6] << 8) | ((uint32_t)head[7]);
        ppscnt = head[8 + spsnalsize];
        ppsnalsize = ((uint32_t)head[9 + spsnalsize] << 8) | ((uint32_t)head[10 + spsnalsize]);
        
        
        unsigned char *data = (unsigned char *)malloc(4 + spsnalsize + 4 + ppsnalsize);
        
        
        data[0] = 0;
        data[1] = 0;
        data[2] = 0;
        data[3] = 1;
        
        memcpy(data + 4, head + 8, spsnalsize);
        
        data[4 + spsnalsize] = 0;
        data[5 + spsnalsize] = 0;
        data[6 + spsnalsize] = 0;
        data[7 + spsnalsize] = 1;
        
        memcpy(data + 8 + spsnalsize, head + 11 + spsnalsize, ppsnalsize);
        
        
        fwrite(data,1,4 + spsnalsize + 4 + ppsnalsize,m_handle);
        
        
        free(data);
        
        
    }
    
#endif
    
    
    
    
    mp4_init_flag = 1;
    
    
}


void video_process(void *cls,const void *buffer, int buflen, int payloadtype, double timestamp)
{
    int		    rLen;
    int			nalSize;
    unsigned    char *data;
    
    while (!mp4_init_flag)
    {
        usleep(1000);
    }
    
    if (payloadtype == 0)
    {
        
        rLen = 0;
        data = (unsigned char *)buffer + rLen;
        
        while (rLen < buflen)
        {
            
            rLen += 4;
            nalSize = (((uint32_t)data[0] << 24) | ((uint32_t)data[1] << 16) | ((uint32_t)data[2] << 8) | (uint32_t)data[3]);
            rLen += nalSize;
            
            MP4WriteSample(hMp4file, m_videoId, data, nalSize + 4, MP4_INVALID_DURATION, 0, 1);
            
            data = (unsigned char *)buffer + rLen;
        }
        
        
#if SAVE_264_ENABLE
        {
            
            
            int		    rLen;
            unsigned    char *head;
            
            
            
            unsigned char *data = (unsigned char *)malloc(buflen);
            memcpy(data, buffer, buflen);
            
            
            
            rLen = 0;
            head = (unsigned char *)data + rLen;
            while (rLen < buflen)
            {
                rLen += 4;
                rLen += (((uint32_t)head[0] << 24) | ((uint32_t)head[1] << 16) | ((uint32_t)head[2] << 8) | (uint32_t)head[3]);
                
                head[0] = 0;
                head[1] = 0;
                head[2] = 0;
                head[3] = 1;
                
                head = (unsigned char *)data + rLen;
            }
            
            
            
            fwrite(data,1,buflen,m_handle);
            
            free(data);
            
            
        }
#endif
        
    }
#if 0
    else if (payloadtype == 1)
    {
        int spscnt;
        int spsnalsize;
        unsigned char *sps;
        int ppscnt;
        int ppsnalsize;
        unsigned char *pps;
        
        //rLen = 0;
        data = (unsigned char *)buffer ;
        
        spscnt = data[5] & 0x1f;
        spsnalsize = ((uint32_t)data[6] << 8) | ((uint32_t)data[7]);
        ppscnt = data[8 + spsnalsize];
        ppsnalsize = ((uint32_t)data[9 + spsnalsize] << 8) | ((uint32_t)data[10 + spsnalsize]);
        
        sps = (unsigned char *)malloc(spsnalsize + 4 );
        pps = (unsigned char *)malloc(ppsnalsize + 4);
        
        
        memcpy(sps + 4, data + 8, spsnalsize);
        
        sps[0] = 0;
        sps[1] = 0;
        sps[2] = 0;
        sps[3] = spsnalsize;
        
        MP4WriteSample(hMp4file, m_videoId, sps, spsnalsize + 4, MP4_INVALID_DURATION, 0, 1);
        
        //MP4AddH264SequenceParameterSet(hMp4file, m_videoId, sps, spsnalsize);
        
        memcpy(pps + 4, data + 11 + spsnalsize, ppsnalsize);
        
        pps[0] = 0;
        pps[1] = 0;
        pps[2] = 0;
        pps[3] = ppsnalsize;
        
        MP4WriteSample(hMp4file, m_videoId, pps, pps + 4, MP4_INVALID_DURATION, 0, 1);
        
        //MP4AddH264PictureParameterSet(hMp4file, m_videoId, pps, ppsnalsize);
        
        free(sps);
        free(pps);
        
        
#if SAVE_264_ENABLE
        {
            int spscnt;
            int spsnalsize;
            int ppscnt;
            int ppsnalsize;
            
            unsigned    char *head = (unsigned  char *)buffer;
            
            
            
            
            spscnt = head[5] & 0x1f;
            spsnalsize = ((uint32_t)head[6] << 8) | ((uint32_t)head[7]);
            ppscnt = head[8 + spsnalsize];
            ppsnalsize = ((uint32_t)head[9 + spsnalsize] << 8) | ((uint32_t)head[10 + spsnalsize]);
            
            
            unsigned char *data = (unsigned char *)malloc(4 + spsnalsize + 4 + ppsnalsize);
            
            
            data[0] = 0;
            data[1] = 0;
            data[2] = 0;
            data[3] = 1;
            
            memcpy(data + 4, head + 8, spsnalsize);
            
            data[4 + spsnalsize] = 0;
            data[5 + spsnalsize] = 0;
            data[6 + spsnalsize] = 0;
            data[7 + spsnalsize] = 1;
            
            memcpy(data + 8 + spsnalsize, head + 11 + spsnalsize, ppsnalsize);
            
            
            fwrite(data,1,4 + spsnalsize + 4 + ppsnalsize,m_handle);
            
            
            free(data);
            
            
        }
        
#endif
        
    }
#endif
    
    

    
    
    printf("=====video====%f====\n",timestamp);
    
}

void video_stop(void *cls)
{
    
    if (hMp4file)
    {
        MP4Close(hMp4file,0);
        hMp4file = NULL;
    }
    mp4_init_flag = 0;
    
    
#if SAVE_264_ENABLE
    fclose(m_handle);
#endif
    
    printf("=====video_stop========\n");
    
}

void audio_open(void *cls, int bits, int channels, int samplerate, int isaudio)
{
    
    
}


void audio_setvolume(void *cls,int volume)
{
    printf("=====audio====%d====\n",volume);
}


void audio_process(void *cls,const void *buffer, int buflen, double timestamp, uint32_t seqnum)
{
    while (!mp4_init_flag)
    {
        usleep(1000);
    }
    
    
    MP4WriteSample(hMp4file, m_audioId, buffer, buflen, MP4_INVALID_DURATION, 0, 1);
    printf("=====audio====%f====\n",timestamp);
}


void audio_stop(void *cls)
{
    
    printf("=====audio_stop========\n");
}






- (void)startRecordingScreen
{
    // if the AVAssetWriter is NOT valid, setup video context
    //if(!_videoWriter)
    //    [self _setupVideoContext]; // this must be done before _setupVideoAndStartRecording
    _recordStartDate = [[NSDate date] retain];
    
    [self _setupAudio];
    //[self _setupVideoAndStartRecording];
    
    
    
    airplay_callbacks_t ao;
    memset(&ao,0,sizeof(airplay_callbacks_t));
    ao.cls                          = (__bridge void *)self;

    
    
    ao.AirPlayMirroring_Play     = video_open;
    ao.AirPlayMirroring_Process  = video_process;
    ao.AirPlayMirroring_Stop     = video_stop;
    
    ao.AirPlayAudio_Init         = audio_open;
    ao.AirPlayAudio_SetVolume    = audio_setvolume;
    ao.AirPlayAudio_Process      = audio_process;
    ao.AirPlayAudio_destroy      = audio_stop;
    
    

    
    int ret = XinDawn_StartMediaServer("XBMC-GAMEBOX(Xindawn)",1920, 1080, 60, 47000,7100,"000000000", &ao);
    
    
    printf("=====ret=%d========\n",ret);
    
    
}

- (void)stopRecordingScreen
{
	// Set the flag to stop recording
    _isRecording = NO;
    
     [self _finishEncoding];
    
    // Invalidate the recording time
    [_recordingTimer invalidate];
    _recordingTimer = nil;
    
    XinDawn_StopMediaServer();
    
}

- (void)_setupAudio
{
    // Setup to be able to record global sounds (preexisting app sounds)
	NSError *sessionError = nil;
    if ([[AVAudioSession sharedInstance] respondsToSelector:@selector(setCategory:withOptions:error:)])
        [[AVAudioSession sharedInstance] setCategory:AVAudioSessionCategoryPlayAndRecord withOptions:AVAudioSessionCategoryOptionDuckOthers error:&sessionError];
    else
        [[AVAudioSession sharedInstance] setCategory:AVAudioSessionCategoryPlayAndRecord error:&sessionError];
    
    // Set the audio session to be active
	[[AVAudioSession sharedInstance] setActive:YES error:&sessionError];
    
    if (sessionError && [self.delegate respondsToSelector:@selector(screenRecorder:audioSessionSetupFailedWithError:)]) {
        [self.delegate screenRecorder:self audioSessionSetupFailedWithError:sessionError];
        return;
    }
    
    // Set the number of audio channels, using defaults if necessary.
    NSNumber *audioChannels = (self.numberOfAudioChannels ? self.numberOfAudioChannels : @2);
    NSNumber *sampleRate    = (self.audioSampleRate       ? self.audioSampleRate       : @44100.f);
    
    NSDictionary *audioSettings = @{
                                    AVNumberOfChannelsKey : (audioChannels ? audioChannels : @2),
                                    AVSampleRateKey       : (sampleRate    ? sampleRate    : @44100.0f)
                                    };
    
    
    // Initialize the audio recorder
    // Set output path of the audio file
    NSError *error = nil;
    NSAssert((self.audioOutPath != nil), @"Audio out path cannot be nil!");
    _audioRecorder = [[AVAudioRecorder alloc] initWithURL:[NSURL fileURLWithPath:self.audioOutPath] settings:audioSettings error:&error];
    if (error && [self.delegate respondsToSelector:@selector(screenRecorder:audioRecorderSetupFailedWithError:)]) {
        // Let the delegate know that shit has happened.
        [self.delegate screenRecorder:self audioRecorderSetupFailedWithError:error];
        
        [_audioRecorder release];
        _audioRecorder = nil;
        
        return;
    }
    
    [_audioRecorder setDelegate:self];
    [_audioRecorder prepareToRecord];
    
    // Start recording :P
    [_audioRecorder record];
}

- (void)_setupVideoAndStartRecording
{
    // Set timer to notify the delegate of time changes every second
    _recordingTimer = [NSTimer scheduledTimerWithTimeInterval:1
                                                       target:self
                                                     selector:@selector(_sendDelegateTimeUpdate:)
                                                     userInfo:nil
                                                      repeats:YES];
    
    _isRecording = YES;

    //capture loop (In another thread)
    dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
        int targetFPS = _fps;
        int msBeforeNextCapture = 1000 / targetFPS;
        
        struct timeval lastCapture, currentTime, startTime;
        lastCapture.tv_sec = 0;
        lastCapture.tv_usec = 0;
        
        //recording start time
        gettimeofday(&startTime, NULL);
        startTime.tv_usec /= 1000;
        
        int lastFrame = -1;
        while(_isRecording)
        {
            //time passed since last capture
            gettimeofday(&currentTime, NULL);
            
            //convert to milliseconds to avoid overflows
            currentTime.tv_usec /= 1000;
            
            unsigned long long diff = (currentTime.tv_usec + (1000 * currentTime.tv_sec) ) - (lastCapture.tv_usec + (1000 * lastCapture.tv_sec) );
            
            // if enough time has passed, capture another shot
            if(diff >= msBeforeNextCapture)
            {
                //time since start
                long int msSinceStart = (currentTime.tv_usec + (1000 * currentTime.tv_sec) ) - (startTime.tv_usec + (1000 * startTime.tv_sec) );
                
                // Generate the frame number
                int frameNumber = msSinceStart / msBeforeNextCapture;
                CMTime presentTime;
                presentTime = CMTimeMake(frameNumber, targetFPS);
                
                // Frame number cannot be last frames number :P
                NSParameterAssert(frameNumber != lastFrame);
                lastFrame = frameNumber;
                
                // Capture next shot and repeat
              //  [self _captureShot:presentTime];
                lastCapture = currentTime;
            }
        }
        
        // finish encoding, using the video_queue thread
        dispatch_async(_videoQueue, ^{
            [self _finishEncoding];
        });
        
    });
}

/*
- (void)_captureShot:(CMTime)frameTime
{
    // Create an IOSurfaceRef if one does not exist
    if(!_surface) {
        _surface = [self _createScreenSurface];
    }
    
    // Lock the surface from other threads
    static NSMutableArray * buffers = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        buffers = [[NSMutableArray alloc] init];
    });
    
    IOSurfaceLock(_surface, 0, nil);
    // Take currently displayed image from the LCD
    CARenderServerRenderDisplay(0, CFSTR("LCD"), _surface, 0, 0);
    // Unlock the surface
    IOSurfaceUnlock(_surface, 0, 0);
    
    // Make a raw memory copy of the surface
    void *baseAddr = IOSurfaceGetBaseAddress(_surface);
    int totalBytes = _bytesPerRow * _height;
    
    //void *rawData = malloc(totalBytes);
    //memcpy(rawData, baseAddr, totalBytes);
    NSMutableData * rawDataObj = nil;
    if (buffers.count == 0)
        rawDataObj = [[NSMutableData dataWithBytes:baseAddr length:totalBytes] retain];
    else @synchronized(buffers) {
        rawDataObj = [buffers lastObject];
        memcpy((void *)[rawDataObj bytes], baseAddr, totalBytes);
        //[rawDataObj replaceBytesInRange:NSMakeRange(0, rawDataObj.length) withBytes:baseAddr length:totalBytes];
        [buffers removeLastObject];
    }
    
    dispatch_async(dispatch_get_main_queue(), ^{
        
        if(!_pixelBufferAdaptor.pixelBufferPool){
            NSLog(@"skipping frame: %lld", frameTime.value);
            //free(rawData);
            @synchronized(buffers) {
                //[buffers addObject:rawDataObj];
            }
            return;
        }
        
        static CVPixelBufferRef pixelBuffer = NULL;
        
        static dispatch_once_t onceToken;
        dispatch_once(&onceToken, ^{
            NSParameterAssert(_pixelBufferAdaptor.pixelBufferPool != NULL);
            [_pixelBufferLock lock];
            CVPixelBufferPoolCreatePixelBuffer (kCFAllocatorDefault, _pixelBufferAdaptor.pixelBufferPool, &pixelBuffer);
            [_pixelBufferLock unlock];
            NSParameterAssert(pixelBuffer != NULL);
        });
        
        //unlock pixel buffer data
        CVPixelBufferLockBaseAddress(pixelBuffer, 0);
        void *pixelData = CVPixelBufferGetBaseAddress(pixelBuffer);
        NSParameterAssert(pixelData != NULL);
        
        //copy over raw image data and free
        memcpy(pixelData, [rawDataObj bytes], totalBytes);
        //free(rawData);
        @synchronized(buffers) {
            [buffers addObject:rawDataObj];
        }
        
        //unlock pixel buffer data
        CVPixelBufferUnlockBaseAddress(pixelBuffer, 0);
        
        dispatch_async(_videoQueue, ^{
            // Wait until AVAssetWriterInput is ready
            while(!_videoWriterInput.readyForMoreMediaData)
                usleep(1000);
            
            // Lock from other threads
            [_pixelBufferLock lock];
            // Add the new frame to the video
            [_pixelBufferAdaptor appendPixelBuffer:pixelBuffer withPresentationTime:frameTime];
            
            // Unlock
            //CVPixelBufferRelease(pixelBuffer);
            [_pixelBufferLock unlock];
        });
    });
}


- (IOSurfaceRef)_createScreenSurface
{
    // Pixel format for Alpha Red Green Blue
    unsigned pixelFormat = 0x42475241;//'ARGB';
    
    // 4 Bytes per pixel
    int bytesPerElement = 4;
    
    // Bytes per row
    _bytesPerRow = (bytesPerElement * _width);
    
    // Properties include: SurfaceIsGlobal, BytesPerElement, BytesPerRow, SurfaceWidth, SurfaceHeight, PixelFormat, SurfaceAllocSize (space for the entire surface)
    NSDictionary *properties = [NSDictionary dictionaryWithObjectsAndKeys:
                                [NSNumber numberWithBool:YES], kIOSurfaceIsGlobal,
                                [NSNumber numberWithInt:bytesPerElement], kIOSurfaceBytesPerElement,
                                [NSNumber numberWithInt:_bytesPerRow], kIOSurfaceBytesPerRow,
                                [NSNumber numberWithInt:_width], kIOSurfaceWidth,
                                [NSNumber numberWithInt:_height], kIOSurfaceHeight,
                                [NSNumber numberWithUnsignedInt:pixelFormat], kIOSurfacePixelFormat,
                                [NSNumber numberWithInt:_bytesPerRow * _height], kIOSurfaceAllocSize,
                                nil];
    
    // This is the current surface
    return IOSurfaceCreate((CFDictionaryRef)properties);
}
 */

#pragma mark - Encoding
- (void)_setupVideoContext
{
    // Get the screen rect and scale
    CGRect screenRect = [UIScreen mainScreen].bounds;
    float scale = [UIScreen mainScreen].scale;
    
    // setup the width and height of the framebuffer for the device
    if ([[UIDevice currentDevice] userInterfaceIdiom] == UIUserInterfaceIdiomPhone) {
        // iPhone frame buffer is Portrait
        _width = screenRect.size.width * scale;
        _height = screenRect.size.height * scale;
    } else {
        // iPad frame buffer is Landscape
        _width = screenRect.size.height * scale;
        _height = screenRect.size.width * scale;
    }
    
    NSAssert((self.videoOutPath != nil) , @"A valid videoOutPath must be set before the recording starts!");
    
    NSError *error = nil;
    
    // Setup AVAssetWriter with the output path
    _videoWriter = [[AVAssetWriter alloc] initWithURL:[NSURL fileURLWithPath:self.videoOutPath]
                                             fileType:AVFileTypeMPEG4
                                                error:&error];
    // check for errors
    if(error) {
        if ([self.delegate respondsToSelector:@selector(screenRecorder:videoContextSetupFailedWithError:)]) {
            [self.delegate screenRecorder:self videoContextSetupFailedWithError:error];
        }
    }
    
    // Makes sure AVAssetWriter is valid (check check check)
    NSParameterAssert(_videoWriter);
    
    // Setup AverageBitRate, FrameInterval, and ProfileLevel (Compression Properties)
    NSMutableDictionary * compressionProperties = [NSMutableDictionary dictionary];
    [compressionProperties setObject: [NSNumber numberWithInt: _kbps * 1000] forKey: AVVideoAverageBitRateKey];
    [compressionProperties setObject: [NSNumber numberWithInt: _fps] forKey: AVVideoMaxKeyFrameIntervalKey];
    [compressionProperties setObject: AVVideoProfileLevelH264Main41 forKey: AVVideoProfileLevelKey];
    
    // Setup output settings, Codec, Width, Height, Compression
    int videowidth = _width;
    int videoheight = _height;
    if ([[NSUserDefaults standardUserDefaults] objectForKey:@"vidsize"]) {
        if (![[[NSUserDefaults standardUserDefaults] objectForKey:@"vidsize"] boolValue]){
            videowidth /= 2; //If it's set to half-size, divide both by 2.
            videoheight /= 2;
        }
    }
    NSMutableDictionary *outputSettings = [NSMutableDictionary dictionaryWithObjectsAndKeys:
                                           AVVideoCodecH264, AVVideoCodecKey,
                                           [NSNumber numberWithInt:videowidth], AVVideoWidthKey,
                                           [NSNumber numberWithInt:videoheight], AVVideoHeightKey,
                                           compressionProperties, AVVideoCompressionPropertiesKey,
                                           nil];
    
    NSParameterAssert([_videoWriter canApplyOutputSettings:outputSettings forMediaType:AVMediaTypeVideo]);
    
    // Get a AVAssetWriterInput
    // Add the output settings
    _videoWriterInput = [[AVAssetWriterInput assetWriterInputWithMediaType:AVMediaTypeVideo
                                                            outputSettings:outputSettings] retain];
	
    // Check if AVAssetWriter will take an AVAssetWriterInput
    NSParameterAssert(_videoWriterInput);
    NSParameterAssert([_videoWriter canAddInput:_videoWriterInput]);
    [_videoWriter addInput:_videoWriterInput];
    
    // Setup buffer attributes, PixelFormatType, PixelBufferWidth, PixelBufferHeight, PixelBufferMemoryAlocator
    NSDictionary *bufferAttributes = [NSDictionary dictionaryWithObjectsAndKeys:
                                      [NSNumber numberWithInt:kCVPixelFormatType_32BGRA], kCVPixelBufferPixelFormatTypeKey,
                                      [NSNumber numberWithInt:_width], kCVPixelBufferWidthKey,
                                      [NSNumber numberWithInt:_height], kCVPixelBufferHeightKey,
                                      kCFAllocatorDefault, kCVPixelBufferMemoryAllocatorKey,
                                      nil];
    
    // Get AVAssetWriterInputPixelBufferAdaptor with the buffer attributes
    _pixelBufferAdaptor = [AVAssetWriterInputPixelBufferAdaptor assetWriterInputPixelBufferAdaptorWithAssetWriterInput:_videoWriterInput
                                                                                           sourcePixelBufferAttributes:bufferAttributes];
    [_pixelBufferAdaptor retain];
    
    //FPS
    _videoWriterInput.mediaTimeScale = _fps;
    _videoWriter.movieTimeScale = _fps;
    
    //Start a session:
    [_videoWriterInput setExpectsMediaDataInRealTime:YES];
    [_videoWriter startWriting];
    [_videoWriter startSessionAtSourceTime:kCMTimeZero];
    
    NSParameterAssert(_pixelBufferAdaptor.pixelBufferPool != NULL);
}


- (void)_finishEncoding
{
	// Tell the AVAssetWriterInput were done appending buffers
    //[_videoWriterInput markAsFinished];
    
    // Tell the AVAssetWriter to finish and close the file
    //[_videoWriter finishWriting];
    
    // Make objects go away
    //[_videoWriter release];
    //[_videoWriterInput release];
    //[_pixelBufferAdaptor release];
   // _videoWriter = nil;
    //_videoWriterInput = nil;
   // _pixelBufferAdaptor = nil;
	
	// Stop the audio recording
    [_audioRecorder stop];
    
    //added by lijun
    [_audioRecorder deleteRecording];
    
    [_audioRecorder release];
    _audioRecorder = nil;
    
    [_recordStartDate release];
    _recordStartDate = nil;
	
	[self addAudioTrackToRecording];
}

- (void)addAudioTrackToRecording {
    
    /*
	double degrees = 0.0;
	NSUserDefaults *prefs = [NSUserDefaults standardUserDefaults];
	if ([prefs objectForKey:@"vidorientation"])
		degrees = [[prefs objectForKey:@"vidorientation"] doubleValue];
	
	NSString *videoPath = self.videoOutPath;
	NSString *audioPath = self.audioOutPath;
	
	NSURL *videoURL = [NSURL fileURLWithPath:videoPath];
	NSURL *audioURL = [NSURL fileURLWithPath:audioPath];
	
	AVURLAsset *videoAsset = [[AVURLAsset alloc] initWithURL:videoURL options:nil];
	AVURLAsset *audioAsset = [[AVURLAsset alloc] initWithURL:audioURL options:nil];
	
	AVAssetTrack *assetVideoTrack = nil;
	AVAssetTrack *assetAudioTrack = nil;
	
	if ([[NSFileManager defaultManager] fileExistsAtPath:videoPath]) {
		NSArray *assetArray = [videoAsset tracksWithMediaType:AVMediaTypeVideo];
		if ([assetArray count] > 0)
			assetVideoTrack = assetArray[0];
	}
	
	if ([[NSFileManager defaultManager] fileExistsAtPath:audioPath] && [prefs boolForKey:@"recordaudio"]) {
		NSArray *assetArray = [audioAsset tracksWithMediaType:AVMediaTypeAudio];
		if ([assetArray count] > 0)
			assetAudioTrack = assetArray[0];
	}
	
	AVMutableComposition *mixComposition = [AVMutableComposition composition];
	
	if (assetVideoTrack != nil) {
		AVMutableCompositionTrack *compositionVideoTrack = [mixComposition addMutableTrackWithMediaType:AVMediaTypeVideo preferredTrackID:kCMPersistentTrackID_Invalid];
		[compositionVideoTrack insertTimeRange:CMTimeRangeMake(kCMTimeZero, videoAsset.duration) ofTrack:assetVideoTrack atTime:kCMTimeZero error:nil];
		if (assetAudioTrack != nil) [compositionVideoTrack scaleTimeRange:CMTimeRangeMake(kCMTimeZero, videoAsset.duration) toDuration:audioAsset.duration];
		[compositionVideoTrack setPreferredTransform:CGAffineTransformMakeRotation(degreesToRadians(degrees))];
	}
	
	if (assetAudioTrack != nil) {
		AVMutableCompositionTrack *compositionAudioTrack = [mixComposition addMutableTrackWithMediaType:AVMediaTypeAudio preferredTrackID:kCMPersistentTrackID_Invalid];
		[compositionAudioTrack insertTimeRange:CMTimeRangeMake(kCMTimeZero, audioAsset.duration) ofTrack:assetAudioTrack atTime:kCMTimeZero error:nil];
	}

	NSString *exportPath = [videoPath substringWithRange:NSMakeRange(0, videoPath.length - 4)];
	exportPath = [NSString stringWithFormat:@"%@.mov", exportPath];
	NSURL *exportURL = [NSURL fileURLWithPath:exportPath];
	
	AVAssetExportSession *exportSession = [[AVAssetExportSession alloc] initWithAsset:mixComposition presetName:AVAssetExportPresetPassthrough];
	[exportSession setOutputFileType:AVFileTypeQuickTimeMovie];
	[exportSession setOutputURL:exportURL];
	[exportSession setShouldOptimizeForNetworkUse:NO];
	
	[exportSession exportAsynchronouslyWithCompletionHandler:^(void){
		switch (exportSession.status) {
			case AVAssetExportSessionStatusCompleted:{
				[[NSFileManager defaultManager] removeItemAtPath:videoPath error:nil];
				[[NSFileManager defaultManager] removeItemAtPath:audioPath error:nil];
                [videoAsset release];
                [audioAsset release];
				break;
			}
				
			case AVAssetExportSessionStatusFailed:
                [videoAsset release];
                [audioAsset release];
				NSLog(@"Failed: %@", exportSession.error);
				break;
				
			case AVAssetExportSessionStatusCancelled:
                [videoAsset release];
                [audioAsset release];
				NSLog(@"Canceled: %@", exportSession.error);
				break;
				
			default:
                [videoAsset release];
                [audioAsset release];
				break;
		}
		
		if ([self.delegate respondsToSelector:@selector(screenRecorderDidStopRecording:)]) {
			[self.delegate screenRecorderDidStopRecording:self];
		}
	}];*/


    [self.delegate screenRecorderDidStopRecording:self];
}


#pragma mark - Delegate Stuff
- (void)_sendDelegateTimeUpdate:(NSTimer *)timer
{
    if ([self.delegate respondsToSelector:@selector(screenRecorder:recordingTimeChanged:)]) {
        NSTimeInterval timeInterval = [[NSDate date] timeIntervalSinceDate:_recordStartDate];
        [self.delegate screenRecorder:self recordingTimeChanged:timeInterval];
    }
}

@end
