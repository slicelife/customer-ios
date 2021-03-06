//
//  KUSPushClient.m
//  Kustomer
//
//  Created by Daniel Amitay on 8/20/17.
//  Copyright © 2017 Kustomer. All rights reserved.
//

#import "KUSPushClient.h"

#import <Pusher/Pusher.h>
#import <Pusher/PTPusherConnection.h>

#import "KUSAudio.h"
#import "KUSLog.h"
#import "KUSNotificationWindow.h"
#import "KUSUserSession.h"

static const NSTimeInterval KUSLazyPollingTimerInterval = 45.0;
static const NSTimeInterval KUSActivePollingTimerInterval = 7.5;

@interface KUSPushClient () <KUSObjectDataSourceListener, KUSPaginatedDataSourceListener, PTPusherDelegate> {
    __weak KUSUserSession *_userSession;

    NSTimer *_pollingTimer;

    PTPusher *_pusherClient;
    PTPusherChannel *_pusherChannel;

    NSMutableDictionary<NSString *, KUSChatSession *> *_previousChatSessions;
}

@end

@implementation KUSPushClient

#pragma mark - Lifecycle methods

- (instancetype)initWithUserSession:(KUSUserSession *)userSession
{
    self = [super init];
    if (self) {
        _userSession = userSession;

        [_userSession.chatSessionsDataSource addListener:self];
        [_userSession.chatSettingsDataSource addListener:self];
        [_userSession.trackingTokenDataSource addListener:self];

        [self _connectToChannelsIfNecessary];
    }
    return self;
}

- (void)dealloc
{
    [_pollingTimer invalidate];
    [_pusherClient unsubscribeAllChannels];
    [_pusherClient disconnect];
}

#pragma mark - Channel constructors

- (NSURL *)_pusherAuthURL
{
    return [_userSession.requestManager URLForEndpoint:@"/c/v1/pusher/auth"];
}

- (NSString *)_pusherChannelName
{
    KUSTrackingToken *trackingTokenObj = _userSession.trackingTokenDataSource.object;
    if (trackingTokenObj.trackingId) {
        return [NSString stringWithFormat:@"presence-external-%@-tracking-%@", _userSession.orgId, trackingTokenObj.trackingId];
    }
    return nil;
}

#pragma mark - Internal methods

- (void)_connectToChannelsIfNecessary
{
    KUSChatSettings *chatSettings = _userSession.chatSettingsDataSource.object;
    if (_pusherClient == nil && chatSettings.pusherAccessKey) {
        _pusherClient = [PTPusher pusherWithKey:chatSettings.pusherAccessKey delegate:self encrypted:YES];
        _pusherClient.authorizationURL = [self _pusherAuthURL];
    }

    // Connect or disconnect from pusher
    if (_pusherClient && [self _shouldBeConnectedToPusher]) {
        [_pusherClient connect];

        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(KUSLazyPollingTimerInterval * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            [self _connectToChannelsIfNecessary];
        });
    } else {
        [_pusherClient disconnect];
    }

    NSString *pusherChannelName = [self _pusherChannelName];
    if (pusherChannelName && _pusherChannel == nil) {
        _pusherChannel = [_pusherClient subscribeToChannelNamed:pusherChannelName];
        [_pusherChannel bindToEventNamed:@"kustomer.app.chat.message.send"
                                            target:self
                                            action:@selector(_onPusherChatMessageSend:)];
    }

    [self _updatePollingTimer];
}

- (void)_updatePollingTimer
{
    // Connect or disconnect from pusher
    if ([self _shouldBeConnectedToPusher]) {
        if (_pusherClient.connection.connected) {
            // Stop polling
            if (_pollingTimer) {
                [_pollingTimer invalidate];
                _pollingTimer = nil;
                KUSLogPusher(@"Stopped polling timer");
            }
        } else {
            // We are not yet connected to pusher, setup an active polling timer
            // (in the event that connecting to pusher fails)
            if (_pollingTimer == nil || _pollingTimer.timeInterval != KUSActivePollingTimerInterval) {
                [_pollingTimer invalidate];
                _pollingTimer = [NSTimer timerWithTimeInterval:KUSActivePollingTimerInterval
                                                        target:self
                                                      selector:@selector(_onPollTick)
                                                      userInfo:nil
                                                       repeats:YES];
                _pollingTimer.tolerance = _pollingTimer.timeInterval / 10.0;
                [[NSRunLoop mainRunLoop] addTimer:_pollingTimer forMode:NSRunLoopCommonModes];
                KUSLogPusher(@"Started active polling timer");
            }
        }
    } else if (_userSession.chatSessionsDataSource.count > 0) {
        // Make sure we're polling lazily
        if (_pollingTimer == nil || _pollingTimer.timeInterval != KUSLazyPollingTimerInterval) {
            [_pollingTimer invalidate];
            _pollingTimer = [NSTimer timerWithTimeInterval:KUSLazyPollingTimerInterval
                                                    target:self
                                                  selector:@selector(_onPollTick)
                                                  userInfo:nil
                                                   repeats:YES];
            _pollingTimer.tolerance = _pollingTimer.timeInterval / 10.0;
            [[NSRunLoop mainRunLoop] addTimer:_pollingTimer forMode:NSRunLoopCommonModes];
            KUSLogPusher(@"Started lazy polling timer");

            // Tick immediately
            [_pollingTimer fire];
        }
    }
}

- (void)_onPollTick
{
    KUSTrackingToken *trackingToken = _userSession.trackingTokenDataSource.object;
    if (trackingToken.customerId.length == 0 || !_userSession.chatSessionsDataSource.didFetch) {
        return;
    }

    [_userSession.chatSessionsDataSource fetchLatest];
}

- (void)_notifyForUpdatedChatSession:(NSString *)chatSessionId
{
    if (self.supportViewControllerPresented) {
        [KUSAudio playMessageReceivedSound];
    } else {
        KUSChatSession *chatSession = [[_userSession chatSessionsDataSource] objectWithId:chatSessionId];
        if ([_userSession.delegateProxy shouldDisplayInAppNotification] && chatSession) {
            [KUSAudio playMessageReceivedSound];
            [[KUSNotificationWindow sharedInstance] showChatSession:chatSession];
        }
    }
}

- (BOOL)_shouldBeConnectedToPusher
{
    if (_supportViewControllerPresented) {
        return YES;
    }
    NSDate *lastMessageAt = _userSession.chatSessionsDataSource.lastMessageAt;
    return lastMessageAt && [lastMessageAt timeIntervalSinceNow] > -KUSLazyPollingTimerInterval;
}

#pragma mark - Property methods

- (void)setSupportViewControllerPresented:(BOOL)supportViewControllerPresented
{
    _supportViewControllerPresented = supportViewControllerPresented;
    [self _connectToChannelsIfNecessary];
}

#pragma mark - Pusher event methods

- (void)_onPusherChatMessageSend:(PTPusherEvent *)event
{
    KUSLogPusher(@"Received chat message from Pusher");

    NSArray<KUSChatMessage *> *chatMessages = [KUSChatMessage objectsWithJSON:event.data[@"data"]];
    KUSChatMessage *chatMessage = chatMessages.firstObject;
    KUSChatMessagesDataSource *messagesDataSource = [_userSession chatMessagesDataSourceForSessionId:chatMessage.sessionId];

    // Upsert the messages, but don't notify if we already have the objects
    BOOL doesNotAlreadyContainMessage = ![messagesDataSource objectWithId:chatMessage.oid];
    [messagesDataSource upsertNewMessages:chatMessages];
    if (doesNotAlreadyContainMessage) {
        [self _notifyForUpdatedChatSession:chatMessage.sessionId];
    }
}

#pragma mark - KUSObjectDataSourceListener methods

- (void)objectDataSourceDidLoad:(KUSObjectDataSource *)dataSource
{
    [self _connectToChannelsIfNecessary];

    KUSTrackingToken *trackingToken = _userSession.trackingTokenDataSource.object;
    if (trackingToken.customerId.length && !_userSession.chatSessionsDataSource.didFetch) {
        [_userSession.chatSessionsDataSource fetchLatest];
    }
}

#pragma mark - KUSPaginatedDataSourceListener methods

- (void)paginatedDataSourceDidChangeContent:(KUSPaginatedDataSource *)dataSource
{
    if (dataSource == _userSession.chatSessionsDataSource) {
        [self _connectToChannelsIfNecessary];

        // Only consider new messages here if we're actively polling
        if (_pollingTimer == nil) {
            return;
        }

        NSString *updatedSessionId = nil;
        NSArray<KUSChatSession *> *newChatSessions = _userSession.chatSessionsDataSource.allObjects;
        for (KUSChatSession *chatSession in newChatSessions) {
            KUSChatSession *previousChatSession = [_previousChatSessions objectForKey:chatSession.oid];
            if (previousChatSession) {
                KUSChatMessagesDataSource *messagesDataSource = [_userSession chatMessagesDataSourceForSessionId:chatSession.oid];
                KUSChatMessage *latestChatMessage = messagesDataSource.allObjects.firstObject;
                BOOL isUpdatedSession = [chatSession.lastMessageAt compare:previousChatSession.lastMessageAt] == NSOrderedDescending;
                NSDate *sessionLastSeenAt = [_userSession.chatSessionsDataSource lastSeenAtForSessionId:chatSession.oid];
                BOOL lastSeenBeforeMessage = [chatSession.lastMessageAt compare:sessionLastSeenAt] == NSOrderedDescending;
                BOOL lastMessageAtNewerThanLocalLastMessage = latestChatMessage == nil || [chatSession.lastMessageAt compare:latestChatMessage.createdAt] == NSOrderedDescending;
                if (isUpdatedSession && lastSeenBeforeMessage && lastMessageAtNewerThanLocalLastMessage) {
                    updatedSessionId = chatSession.oid;
                    [messagesDataSource fetchLatest];
                }
            }
        }

        _previousChatSessions = [[NSMutableDictionary alloc] init];
        for (KUSChatSession *chatSession in newChatSessions) {
            [_previousChatSessions setObject:chatSession forKey:chatSession.oid];
        }

        if (updatedSessionId) {
            [self _notifyForUpdatedChatSession:updatedSessionId];
            updatedSessionId = nil;
        }
    }
}

#pragma mark - PTPusherDelegate methods

- (void)pusher:(PTPusher *)pusher connectionDidConnect:(PTPusherConnection *)connection
{
    KUSLogPusher(@"Pusher connection did connect");

    [self _updatePollingTimer];
}

- (void)pusher:(PTPusher *)pusher connection:(PTPusherConnection *)connection didDisconnectWithError:(NSError *)error willAttemptReconnect:(BOOL)willAttemptReconnect
{
    if (error) {
        KUSLogPusherError(@"Pusher connection did disconnect with error: %@", error);
    } else {
        KUSLogPusher(@"Pusher connection did disconnect");
    }

    [self _updatePollingTimer];
}

- (void)pusher:(PTPusher *)pusher connection:(PTPusherConnection *)connection failedWithError:(NSError *)error
{
    KUSLogPusherError(@"Pusher connection failed with error: %@", error);

    [self _updatePollingTimer];
}

- (void)pusher:(PTPusher *)pusher willAuthorizeChannel:(PTPusherChannel *)channel
withAuthOperation:(PTPusherChannelAuthorizationOperation *)operation
{
    [operation.mutableURLRequest setValue:_userSession.trackingTokenDataSource.currentTrackingToken
                       forHTTPHeaderField:kKustomerTrackingTokenHeaderKey];

    NSDictionary<NSString *, NSString *> *genericHTTPHeaderValues = [_userSession.requestManager genericHTTPHeaderValues];
    for (NSString *key in genericHTTPHeaderValues) {
        [operation.mutableURLRequest setValue:genericHTTPHeaderValues[key] forHTTPHeaderField:key];
    }
}

- (void)pusher:(PTPusher *)pusher didSubscribeToChannel:(PTPusherChannel *)channel
{
    KUSLogPusher(@"Pusher did subscribe to channel: %@", channel.name);
}

- (void)pusher:(PTPusher *)pusher didFailToSubscribeToChannel:(PTPusherChannel *)channel withError:(NSError *)error
{
    KUSLogPusherError(@"Pusher did fail to subscribe to channel: %@ with error: %@", channel.name, error);
}

@end
