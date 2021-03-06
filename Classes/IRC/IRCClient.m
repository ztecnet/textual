// Created by Satoshi Nakagawa <psychs AT limechat DOT net> <http://github.com/psychs/limechat>
// Modifications by Codeux Software <support AT codeux DOT com> <https://github.com/codeux/Textual>
// You can redistribute it and/or modify it under the new BSD license.
// Converted to ARC Support on June 21, 2012

#import "TextualApplication.h"

#import <arpa/inet.h>
#import <mach/mach_time.h>

#import <BlowfishEncryption/BlowfishEncryption.h>

#define _timeoutInterval			360
#define _pingInterval				270
#define _retryInterval				240
#define _reconnectInterval			20
#define _isonCheckIntervalL			30
#define _trialPeriodInterval		7200
#define _autojoinDelayInterval		2
#define _pongCheckInterval			30

static NSDateFormatter *dateTimeFormatter = nil;

@interface IRCClient (Private)
- (void)setKeywordState:(id)target;
- (void)setNewTalkState:(id)target;
- (void)setUnreadState:(id)target;

- (void)receivePrivmsgAndNotice:(IRCMessage *)message;
- (void)receiveJoin:(IRCMessage *)message;
- (void)receivePart:(IRCMessage *)message;
- (void)receiveKick:(IRCMessage *)message;
- (void)receiveQuit:(IRCMessage *)message;
- (void)receiveKill:(IRCMessage *)message;
- (void)receiveNick:(IRCMessage *)message;
- (void)receiveMode:(IRCMessage *)message;
- (void)receiveTopic:(IRCMessage *)message;
- (void)receiveInvite:(IRCMessage *)message;
- (void)receiveError:(IRCMessage *)message;
- (void)receivePing:(IRCMessage *)message;
- (void)receiveNumericReply:(IRCMessage *)message;

- (void)receiveInit:(IRCMessage *)message;
- (void)receiveText:(IRCMessage *)m command:(NSString *)cmd text:(NSString *)text identified:(BOOL)identified;
- (void)receiveCTCPQuery:(IRCMessage *)message text:(NSString *)text;
- (void)receiveCTCPReply:(IRCMessage *)message text:(NSString *)text;
- (void)receiveErrorNumericReply:(IRCMessage *)message;
- (void)receiveNickCollisionError:(IRCMessage *)message;

- (void)tryAnotherNick;
- (void)changeStateOff;
- (void)performAutoJoin;

- (void)addCommandToCommandQueue:(TLOTimerCommand *)m;
- (void)clearCommandQueue;

- (void)handleUserTrackingNotification:(IRCAddressBook *)ignoreItem 
							  nickname:(NSString *)nick
							  hostmask:(NSString *)host
							  langitem:(NSString *)localKey;
@end

@implementation IRCClient

@synthesize uid;
@synthesize log;
@synthesize connectDelay;
@synthesize autoJoinTimer;
@synthesize autojoinInitialized;
@synthesize banExceptionSheet;
@synthesize chanBanListSheet;
@synthesize channelListDialog;
@synthesize channels;
@synthesize commandQueue;
@synthesize commandQueueTimer;
@synthesize config;
@synthesize conn;
@synthesize connectType;
@synthesize disconnectType;
@synthesize encoding;
@synthesize hasIRCopAccess;
@synthesize highlights;
@synthesize pendingCaps;
@synthesize acceptedCaps;
@synthesize userhostInNames;
@synthesize multiPrefix;
@synthesize identifyCTCP;
@synthesize identifyMsg;
@synthesize inWhoInfoRun;
@synthesize inWhoWasRun;
@synthesize inFirstISONRun;
@synthesize inputNick;
@synthesize inviteExceptionSheet;
@synthesize isAway;
@synthesize isConnected;
@synthesize isConnecting;
@synthesize isLoggedIn;
@synthesize isQuitting;
@synthesize isonTimer;
@synthesize isupport;
@synthesize lastLagCheck;
@synthesize lastSelectedChannel;
@synthesize logDate;
@synthesize logFile;
@synthesize myHost;
@synthesize myNick;
@synthesize pongTimer;
@synthesize rawModeEnabled;
@synthesize reconnectEnabled;
@synthesize reconnectTimer;
@synthesize retryEnabled;
@synthesize retryTimer;
@synthesize sentNick;
@synthesize sendLagcheckToChannel;
@synthesize isIdentifiedWithSASL;
@synthesize serverHasNickServ;
@synthesize serverHostname;
@synthesize trackedUsers;
@synthesize tryingNickNumber;
@synthesize whoisChannel;
@synthesize inSASLRequest;
@synthesize lastMessageReceived;
@synthesize capPaused;
@synthesize world;

#ifdef IS_TRIAL_BINARY
@synthesize trialPeriodTimer;
#endif

#pragma mark -
#pragma mark Initialization

- (id)init
{
	if ((self = [super init])) {
		self.tryingNickNumber	= -1;
		self.capPaused			= 0;
		
		self.isAway				= NO;
		self.userhostInNames	= NO;
		self.multiPrefix		= NO;
		self.identifyMsg		= NO;
		self.identifyCTCP		= NO;
		self.hasIRCopAccess		= NO;
		
		self.channels		= [NSMutableArray new];
		self.highlights		= [NSMutableArray new];
		self.commandQueue	= [NSMutableArray new];
		self.acceptedCaps	= [NSMutableArray new];
		self.pendingCaps	= [NSMutableArray new];
		
		self.trackedUsers	= [NSMutableDictionary new];
		
		self.isupport = [IRCISupportInfo new];
		
		self.reconnectTimer				= [TLOTimer new];
		self.reconnectTimer.delegate	= self;
		self.reconnectTimer.reqeat		= NO;
		self.reconnectTimer.selector	= @selector(onReconnectTimer:);
		
		self.retryTimer				= [TLOTimer new];
		self.retryTimer.delegate	= self;
		self.retryTimer.reqeat		= NO;
		self.retryTimer.selector	= @selector(onRetryTimer:);
		
		self.autoJoinTimer				= [TLOTimer new];
		self.autoJoinTimer.delegate		= self;
		self.autoJoinTimer.reqeat		= YES;
		self.autoJoinTimer.selector		= @selector(onAutoJoinTimer:);
		
		self.commandQueueTimer				= [TLOTimer new];
		self.commandQueueTimer.delegate		= self;
		self.commandQueueTimer.reqeat		= NO;
		self.commandQueueTimer.selector		= @selector(onCommandQueueTimer:);
		
		self.pongTimer				= [TLOTimer new];
		self.pongTimer.delegate		= self;
		self.pongTimer.reqeat		= YES;
		self.pongTimer.selector		= @selector(onPongTimer:);
		
		self.isonTimer				= [TLOTimer new];
		self.isonTimer.delegate		= self;
		self.isonTimer.reqeat		= YES;
		self.isonTimer.selector		= @selector(onISONTimer:);
		
#ifdef IS_TRIAL_BINARY
		self.trialPeriodTimer				= [TLOTimer new];
		self.trialPeriodTimer.delegate		= self;
		self.trialPeriodTimer.reqeat		= NO;
		self.trialPeriodTimer.selector		= @selector(onTrialPeriodTimer:);	
#endif
	}
	
	return self;
}

- (void)dealloc
{
	[self.autoJoinTimer		stop];
	[self.commandQueueTimer stop];
	[self.isonTimer			stop];
	[self.pongTimer			stop];
	[self.reconnectTimer	stop];
	[self.retryTimer		stop];
	
	[self.conn close];
	
#ifdef IS_TRIAL_BINARY
	[self.trialPeriodTimer stop];
#endif
	
}

- (void)setup:(IRCClientConfig *)seed
{
	self.config = [seed mutableCopy];
}

- (void)updateConfig:(IRCClientConfig *)seed
{
	self.config = nil;
	self.config = [seed mutableCopy];
	
	NSArray *chans = self.config.channels;
	
	NSMutableArray *ary = [NSMutableArray array];
	
	for (IRCChannelConfig *i in chans) {
		IRCChannel *c = [self findChannel:i.name];
		
		if (c) {
			[c updateConfig:i];
			
			[ary safeAddObject:c];
			
			[self.channels removeObjectIdenticalTo:c];
		} else {
			c = [self.world createChannel:i client:self reload:NO adjust:NO];
			
			[ary safeAddObject:c];
		}
	}
	
	for (IRCChannel *c in self.channels) {
		if (c.isChannel) {
			[self partChannel:c];
		} else {
			[ary safeAddObject:c];
		}
	}
	
	[self.channels removeAllObjects];
	[self.channels addObjectsFromArray:ary];
	
	[self.config.channels removeAllObjects];
	
	[self.world reloadTree];
	[self.world adjustSelection];
}

- (IRCClientConfig *)storedConfig
{
	IRCClientConfig *u = [self.config mutableCopy];
	
	[u.channels removeAllObjects];
	
	for (IRCChannel *c in self.channels) {
		if (c.isChannel) {
			[u.channels safeAddObject:[c.config mutableCopy]];
		}
	}
	
	return u;
}

- (NSMutableDictionary *)dictionaryValue
{
	NSMutableDictionary *dic = [self.config dictionaryValue];
	
	NSMutableArray *ary = [NSMutableArray array];
	
	for (IRCChannel *c in self.channels) {
		if (c.isChannel) {
			[ary safeAddObject:[c dictionaryValue]];
		}
	}
	
	[dic setObject:ary forKey:@"channelList"];
	
	return dic;
}

#pragma mark -
#pragma mark Properties

- (NSString *)name
{
	return self.config.name;
}

- (BOOL)IRCopStatus
{
	return self.hasIRCopAccess;
}

- (BOOL)isNewTalk
{
	return NO;
}

- (BOOL)isReconnecting
{
	return (self.reconnectTimer && self.reconnectTimer.isActive);
}

#pragma mark -
#pragma mark User Tracking

- (void)handleUserTrackingNotification:(IRCAddressBook *)ignoreItem 
							  nickname:(NSString *)nick
							  hostmask:(NSString *)host
							  langitem:(NSString *)localKey
{
	if ([ignoreItem notifyJoins] == YES) {
		NSString *text = TXTFLS(localKey, host, ignoreItem.hostmask);
		
		[self notifyEvent:TXNotificationAddressBookMatchType
				 lineType:TVCLogLineNoticeType
				   target:nil
					 nick:nick
					 text:text];
	}
}

- (void)populateISONTrackedUsersList:(NSMutableArray *)ignores
{
	if (self.hasIRCopAccess) return;
	if (self.isLoggedIn == NO) return;
	
	if (PointerIsEmpty(self.trackedUsers)) {
		self.trackedUsers = [NSMutableDictionary new];
	}
	
	if (NSObjectIsNotEmpty(self.trackedUsers)) {
		NSMutableDictionary *oldEntries = [NSMutableDictionary dictionary];
		NSMutableDictionary *newEntries = [NSMutableDictionary dictionary];
		
		for (NSString *lname in self.trackedUsers) {
			[oldEntries setObject:[self.trackedUsers objectForKey:lname] forKey:lname];
		}
		
		for (IRCAddressBook *g in ignores) {
			if (g.notifyJoins) {
				NSString *lname = [g trackingNickname];
				
				if ([lname isNickname]) {
					if ([oldEntries containsKeyIgnoringCase:lname]) {
						[newEntries setObject:[oldEntries objectForKey:lname] forKey:lname];
					} else {
						[newEntries setBool:NO forKey:lname];
					}
				}
			}
		}
		
		self.trackedUsers = newEntries;
	} else {
		for (IRCAddressBook *g in ignores) {
			if (g.notifyJoins) {
				NSString *lname = [g trackingNickname];
				
				if ([lname isNickname]) {
					[self.trackedUsers setBool:NO forKey:[g trackingNickname]];
				}
			}
		}
	}
	
	if (NSObjectIsNotEmpty(self.trackedUsers)) {
		[self performSelector:@selector(startISONTimer)];
	} else {
		[self performSelector:@selector(stopISONTimer)];
	}
}

- (void)startISONTimer
{
	if (self.isonTimer.isActive) return;
	
	[self.isonTimer start:_isonCheckIntervalL];
}

- (void)stopISONTimer
{
	[self.isonTimer stop];
    
	[self.trackedUsers removeAllObjects];
}

- (void)onISONTimer:(id)sender
{
	if (self.isLoggedIn) {
		if (NSObjectIsEmpty(self.trackedUsers) || self.hasIRCopAccess) {
			return [self stopISONTimer];
		}
		
		NSMutableString *userstr = [NSMutableString string];
		
		for (NSString *name in self.trackedUsers) {
			[userstr appendFormat:@" %@", name];
		}
		
		[self send:IRCCommandIndexIson, userstr, nil];
	}
}

#pragma mark -
#pragma mark Utilities

- (void)autoConnect:(NSInteger)delay
{
	connectDelay = delay;
	
	[self connect];
}

- (void)terminate
{
	[self quit];
	[self closeDialogs];
	
	for (IRCChannel *c in self.channels) {
		[c terminate];
	}
	
	[self disconnect];
}

- (void)closeDialogs
{
	[self.channelListDialog close];
}

- (void)preferencesChanged
{
	self.log.maxLines = [TPCPreferences maxLogLines];
	
	for (IRCChannel *c in self.channels) {
		[c preferencesChanged];
	}
}

- (void)reloadTree
{
	[self.world reloadTree];
}

- (IRCAddressBook *)checkIgnoreAgainstHostmask:(NSString *)host withMatches:(NSArray *)matches
{
	host = [host lowercaseString];
	
	for (IRCAddressBook *g in self.config.ignores) {
		if ([g checkIgnore:host]) {
			NSDictionary *ignoreDict = [g dictionaryValue];
			
			NSInteger totalMatches = 0;
			
			for (NSString *matchkey in matches) {
				if ([ignoreDict boolForKey:matchkey] == YES) {
					totalMatches++;
				}
			}
			
			if (totalMatches > 0) {
				return g;
			}
		}
	}
	
	return nil;
}


- (BOOL)outputRuleMatchedInMessage:(NSString *)raw inChannel:(IRCChannel *)chan withLineType:(TVCLogLineType)type
{
	if ([TPCPreferences removeAllFormatting]) {
		raw = [raw stripEffects];
	}
	
	NSString *rulekey = [TVCLogLine lineTypeString:type];
	
	NSDictionary *rules = self.world.bundlesWithOutputRules;
	
	if (NSObjectIsNotEmpty(rules)) {
		NSDictionary *ruleData = [rules dictionaryForKey:rulekey];
		
		if (NSObjectIsNotEmpty(ruleData)) {
			for (NSString *ruleRegex in ruleData) {
				if ([TLORegularExpression string:raw isMatchedByRegex:ruleRegex]) {
					NSArray *regexData = [ruleData arrayForKey:ruleRegex];
					
					BOOL console = [regexData boolAtIndex:0];
					BOOL channel = [regexData boolAtIndex:1];
					BOOL queries = [regexData boolAtIndex:2];
					
					if ([chan isKindOfClass:[IRCChannel class]]) {
						if ((chan.isTalk && queries) || (chan.isChannel && channel) || (chan.isClient && console)) {
							return YES;
						}
					} else {
						if (console) {
							return YES;
						}
					}
				}
			}
		}
	}
	
	return NO;
}

#pragma mark -
#pragma mark Channel Ban List Dialog

- (void)createChanBanListDialog
{
	if (PointerIsEmpty(self.chanBanListSheet)) {
		IRCClient *u = [self.world selectedClient];
		IRCChannel *c = [self.world selectedChannel];
		
		if (PointerIsEmpty(u) || PointerIsEmpty(c)) return;
		
		self.chanBanListSheet = [TDChanBanSheet new];
		self.chanBanListSheet.delegate = self;
		self.chanBanListSheet.window = self.world.window;
	} else {
		[self.chanBanListSheet ok:nil];
		
		self.chanBanListSheet = nil;
		
		[self createChanBanListDialog];
		
		return;
	}
	
	[self.chanBanListSheet show];
}

- (void)chanBanDialogOnUpdate:(TDChanBanSheet *)sender
{
    [sender.list removeAllObjects];
    
	[self send:IRCCommandIndexMode, [self.world.selectedChannel name], @"+b", nil];
}

- (void)chanBanDialogWillClose:(TDChanBanSheet *)sender
{
    if (NSObjectIsNotEmpty(sender.modes)) {
        for (NSString *mode in sender.modes) {
            [self sendLine:[NSString stringWithFormat:@"%@ %@ %@", IRCCommandIndexMode, [self.world selectedChannel].name, mode]];
        }
    }
	
	self.chanBanListSheet = nil;
}

#pragma mark -
#pragma mark Channel Invite Exception List Dialog

- (void)createChanInviteExceptionListDialog
{
	if (self.inviteExceptionSheet) {
		[self.inviteExceptionSheet ok:nil];
		
		self.inviteExceptionSheet = nil;
		
		[self createChanInviteExceptionListDialog];
	} else {
		IRCClient *u = [self.world selectedClient];
		IRCChannel *c = [self.world selectedChannel];
		
		if (PointerIsEmpty(u) || PointerIsEmpty(c)) return;
		
		self.inviteExceptionSheet = [TDChanInviteExceptionSheet new];
		self.inviteExceptionSheet.delegate = self;
		self.inviteExceptionSheet.window = self.world.window;
		[self.inviteExceptionSheet show];
	}
}

- (void)chanInviteExceptionDialogOnUpdate:(TDChanInviteExceptionSheet *)sender
{
    [sender.list removeAllObjects];
    
	[self send:IRCCommandIndexMode, [self.world.selectedChannel name], @"+I", nil];
}

- (void)chanInviteExceptionDialogWillClose:(TDChanInviteExceptionSheet *)sender
{
    if (NSObjectIsNotEmpty(sender.modes)) {
        for (NSString *mode in sender.modes) {
            [self sendLine:[NSString stringWithFormat:@"%@ %@ %@", IRCCommandIndexMode, [self.world selectedChannel].name, mode]];
        }
    }
	
	self.inviteExceptionSheet = nil;
}

#pragma mark -
#pragma mark Chan Ban Exception List Dialog

- (void)createChanBanExceptionListDialog
{
	if (PointerIsEmpty(self.banExceptionSheet)) {
		IRCClient *u = [self.world selectedClient];
		IRCChannel *c = [self.world selectedChannel];
		
		if (PointerIsEmpty(u) || PointerIsEmpty(c)) return;
		
		self.banExceptionSheet = [TDChanBanExceptionSheet new];
		self.banExceptionSheet.delegate = self;
		self.banExceptionSheet.window = self.world.window;
	} else {
		[self.banExceptionSheet ok:nil];
		
		self.banExceptionSheet = nil;
		
		[self createChanBanExceptionListDialog];
		
		return;
	}
	
	[self.banExceptionSheet show];
}

- (void)chanBanExceptionDialogOnUpdate:(TDChanBanExceptionSheet *)sender
{
    [sender.list removeAllObjects];
    
	[self send:IRCCommandIndexMode, [self.world.selectedChannel name], @"+e", nil];
}

- (void)chanBanExceptionDialogWillClose:(TDChanBanExceptionSheet *)sender
{
    if (NSObjectIsNotEmpty(sender.modes)) {
        for (NSString *mode in sender.modes) {
            [self sendLine:[NSString stringWithFormat:@"%@ %@ %@", IRCCommandIndexMode, [self.world selectedChannel].name, mode]];
        }
    }
	
	self.banExceptionSheet = nil;
}

#pragma mark -
#pragma mark Network Channel List Dialog

- (void)createChannelListDialog
{
	if (PointerIsEmpty(self.channelListDialog)) {
		self.channelListDialog = [TDCListDialog new];
		self.channelListDialog.delegate = self;
		[self.channelListDialog start];
	} else {
		[self.channelListDialog show];
	}
}

- (void)listDialogOnUpdate:(TDCListDialog *)sender
{
    [sender.list removeAllObjects];
    
	[self sendLine:IRCCommandIndexList];
}

- (void)listDialogOnJoin:(TDCListDialog *)sender channel:(NSString *)channel
{
	[self joinUnlistedChannel:channel];
}

- (void)listDialogWillClose:(TDCListDialog *)sender
{
	self.channelListDialog = nil;
}

#pragma mark -
#pragma mark Timers

- (void)startPongTimer
{
	if (self.pongTimer.isActive) return;
	
	[self.pongTimer start:_pongCheckInterval];
}

- (void)stopPongTimer
{
	if (self.pongTimer.isActive) {
		[self.pongTimer stop];
	}
}

- (void)onPongTimer:(id)sender
{
	if (self.isConnected == NO) {
		return [self stopPongTimer];
	}
	
	NSInteger timeSpent = [NSDate secondsSinceUnixTimestamp:self.lastMessageReceived];
	NSInteger minsSpent = (timeSpent / 60);
	
	if (timeSpent >= _timeoutInterval) {
		[self printDebugInformation:TXTFLS(@"IRCDisconnectedByTimeout", minsSpent) channel:nil];
		
		[self disconnect];
	} else if (timeSpent >= _pingInterval) {
		[self send:IRCCommandIndexPing, self.serverHostname, nil];
	}
}

- (void)startReconnectTimer
{
	if (self.config.autoReconnect) {
		if (self.reconnectTimer.isActive) return;
		
		[self.reconnectTimer start:_reconnectInterval];
	}
}

- (void)stopReconnectTimer
{
	[self.reconnectTimer stop];
}

- (void)onReconnectTimer:(id)sender
{
	[self connect:IRCNormalReconnectionMode];
}

- (void)startRetryTimer
{
	if (self.retryTimer.isActive) return;
	
	[self.retryTimer start:_retryInterval];
}

- (void)stopRetryTimer
{
	[self.retryTimer stop];
}

- (void)onRetryTimer:(id)sender
{
	[self disconnect];
	[self connect:IRCConnectionRetryMode];
}

- (void)startAutoJoinTimer
{
	[self.autoJoinTimer stop];
	[self.autoJoinTimer start:_autojoinDelayInterval];
}

- (void)stopAutoJoinTimer
{
	[self.autoJoinTimer stop];
}

- (void)onAutoJoinTimer:(id)sender
{
	if ([TPCPreferences autojoinWaitForNickServ] == NO || NSObjectIsEmpty(self.config.nickPassword)) {
		[self performAutoJoin];
		
		self.autojoinInitialized = YES;
	} else {
		if (self.serverHasNickServ) {
			if (self.autojoinInitialized) {
				[self performAutoJoin];
				
				self.autojoinInitialized = YES;
			}
		} else {
			[self performAutoJoin];
			
			self.autojoinInitialized = YES;
		}
	}
	
	[self.autoJoinTimer stop];
}

#pragma mark -
#pragma mark Commands

- (void)connect
{
	[self connect:IRCConnectNormalMode];
}

- (void)connect:(IRCConnectMode)mode
{
	[self stopReconnectTimer];
	
	self.connectType    = mode;
	self.disconnectType = IRCDisconnectNormalMode;
	
	if (self.isConnected) {
		[self.conn close];
	}
	
	self.retryEnabled     = YES;
	self.isConnecting     = YES;
	self.reconnectEnabled = YES;
	
	NSString *host = self.config.host;
	
	switch (mode) {
		case IRCConnectNormalMode:
			[self printSystemBoth:nil text:TXTFLS(@"IRCIsConnecting", host, self.config.port)];
			break;
		case IRCNormalReconnectionMode:
			[self printSystemBoth:nil text:TXTLS(@"IRCIsReconnecting")];
			[self printSystemBoth:nil text:TXTFLS(@"IRCIsConnecting", host, self.config.port)];
			break;
		case IRCConnectionRetryMode:
			[self printSystemBoth:nil text:TXTLS(@"IRCIsRetryingConnection")];
			[self printSystemBoth:nil text:TXTFLS(@"IRCIsConnecting", host, self.config.port)];
			break;
		default: break;
	}
	
    if (PointerIsEmpty(self.conn)) {
        self.conn = [IRCConnection new];
		self.conn.delegate = self;
	}
    
	self.conn.host		= host;
	self.conn.port		= self.config.port;
	self.conn.useSSL	= self.config.useSSL;
	self.conn.encoding	= self.config.encoding;
	
	switch (self.config.proxyType) {
		case TXConnectionSystemSocksProxyType:
			self.conn.useSystemSocks = YES;
		case TXConnectionSocks4ProxyType:
		case TXConnectionSocks5ProxyType:
			self.conn.useSocks			= YES;
			self.conn.socksVersion		= self.config.proxyType;
			self.conn.proxyHost			= self.config.proxyHost;
			self.conn.proxyPort			= self.config.proxyPort;
			self.conn.proxyUser			= self.config.proxyUser;
			self.conn.proxyPassword		= self.config.proxyPassword;
			break;
		default: break;
	}
	
	[self.conn open];
	
	[self reloadTree];
}

- (void)disconnect
{
	if (self.conn) {
		[self.conn close];
	}
	
	[self stopPongTimer];
	[self changeStateOff];
}

- (void)quit
{
	[self quit:nil];
}

- (void)quit:(NSString *)comment
{
	if (self.isLoggedIn == NO) {
		[self disconnect];
        
		return;
	}
	
	[self stopPongTimer];
	
	self.isQuitting			= YES;
	self.reconnectEnabled	= NO;
	
	[self.conn clearSendQueue];
	
	if (NSObjectIsEmpty(comment)) {
		comment = self.config.leavingComment;
	}
	
	[self send:IRCCommandIndexQuit, comment, nil];
	
	[self performSelector:@selector(disconnect) withObject:nil afterDelay:2.0];
}

- (void)cancelReconnect
{
	[self stopReconnectTimer];
}

- (void)changeNick:(NSString *)newNick
{
	if (self.isConnected == NO) return;
	
	self.inputNick = newNick;
	self.sentNick = newNick;
	
	[self send:IRCCommandIndexNick, newNick, nil];
}

- (void)_joinKickedChannel:(IRCChannel *)channel
{
	if (PointerIsNotEmpty(channel)) {
		if (channel.status == IRCChannelTerminated) {
			return;
		}
		
		[self joinChannel:channel];
	}
}

- (void)joinChannel:(IRCChannel *)channel
{
	return [self joinChannel:channel password:nil];
}

- (void)joinUnlistedChannel:(NSString *)channel
{
	[self joinUnlistedChannel:channel password:nil];
}

- (void)partUnlistedChannel:(NSString *)channel
{
	[self partUnlistedChannel:channel withComment:nil];
}

- (void)partChannel:(IRCChannel *)channel 
{
	[self partChannel:channel withComment:nil];
}

- (void)joinChannel:(IRCChannel *)channel password:(NSString *)password
{
	if (self.isLoggedIn == NO) return;
	
	if (channel.isActive) return;
	if (channel.isChannel == NO) return;
	
	channel.status = IRCChannelJoining;
	
	if (NSObjectIsEmpty(password)) password = channel.config.password;
	if (NSObjectIsEmpty(password)) password = nil;
	
	[self forceJoinChannel:channel.name password:password];
}

- (void)joinUnlistedChannel:(NSString *)channel password:(NSString *)password
{
	if ([channel isChannelName]) {
		IRCChannel *chan = [self findChannel:channel];
		
		if (chan) {
			return [self joinChannel:chan password:password];
		}
		
		[self forceJoinChannel:channel password:password];
	} else {
        if ([channel isEqualToString:@"0"]) {
            [self forceJoinChannel:channel password:password];
        }
    }
}

- (void)forceJoinChannel:(NSString *)channel password:(NSString *)password
{
	[self send:IRCCommandIndexJoin, channel, password, nil];
}

- (void)partUnlistedChannel:(NSString *)channel withComment:(NSString *)comment
{
	if ([channel isChannelName]) {
		IRCChannel *chan = [self findChannel:channel];
		
		if (chan) {
			chan.status = IRCChannelParted;
			
			return [self partChannel:chan withComment:comment];
		}
	}
}

- (void)partChannel:(IRCChannel *)channel withComment:(NSString *)comment
{
	if (self.isLoggedIn == NO) return;
	
	if (channel.isActive == NO) return;
	if (channel.isChannel == NO) return;
	
	channel.status = IRCChannelParted;
	
	if (NSObjectIsEmpty(comment)) {
		comment = self.config.leavingComment;
	}
	
	[self send:IRCCommandIndexPart, channel.name, comment, nil];
}

- (void)sendWhois:(NSString *)nick
{
	if (self.isLoggedIn == NO) return;
	
	[self send:IRCCommandIndexWhois, nick, nick, nil];
}

- (void)changeOp:(IRCChannel *)channel users:(NSArray *)inputUsers mode:(char)mode value:(BOOL)value
{
	if (self.isLoggedIn == NO ||
		PointerIsEmpty(channel) ||
		channel.isActive == NO ||
		channel.isChannel == NO ||
		channel.isOp == NO) return;
	
	NSMutableArray *users = [NSMutableArray array];
	
	for (IRCUser *user in inputUsers) {
		IRCUser *m = [channel findMember:user.nick];
		
		if (m) {
			if (NSDissimilarObjects(value, [m hasMode:mode])) {
				[users safeAddObject:m];
			}
		}
	}
	
	NSInteger max = self.isupport.modesCount;
	
	while (users.count) {
		NSArray *ary = [users subarrayWithRange:NSMakeRange(0, MIN(max, users.count))];
		
		NSMutableString *s = [NSMutableString string];
		
		[s appendFormat:@"%@ %@ %c", IRCCommandIndexMode, channel.name, ((value) ? '+' : '-')];
		
		for (NSInteger i = (ary.count - 1); i >= 0; --i) {
			[s appendFormat:@"%c", mode];
		}
		
		for (IRCUser *m in ary) {
			[s appendString:NSStringWhitespacePlaceholder];
			[s appendString:m.nick];
		}
		
		[self sendLine:s];
		
		[users removeObjectsInRange:NSMakeRange(0, ary.count)];
	}
}

- (void)kick:(IRCChannel *)channel target:(NSString *)nick
{
	[self send:IRCCommandIndexKick, channel.name, nick, [TPCPreferences defaultKickMessage], nil];
}

- (void)quickJoin:(NSArray *)chans
{
	NSMutableString *target = [NSMutableString string];
	NSMutableString *pass   = [NSMutableString string];
	
	for (IRCChannel *c in chans) {
		NSMutableString *prevTarget = [target mutableCopy];
		NSMutableString *prevPass   = [pass mutableCopy];
        
        c.status = IRCChannelJoining;
		
		if (NSObjectIsNotEmpty(target)) {
			[target appendString:@","];
		}
		
		[target appendString:c.name];
		
		if (NSObjectIsNotEmpty(c.password)) {
			if (NSObjectIsNotEmpty(pass)) {
				[pass appendString:@","];
			}
			
			[pass appendString:c.password];
		}
		
		NSStringEncoding enc = self.conn.encoding;
		
		if (enc == 0x0000) {
			enc = NSUTF8StringEncoding;
		}
		
		NSData *targetData = [target dataUsingEncoding:enc];
		NSData *passData   = [pass dataUsingEncoding:enc];
		
		if ((targetData.length + passData.length) > TXMaximumIRCBodyLength) {
			if (NSObjectIsEmpty(prevTarget)) {
				if (NSObjectIsEmpty(prevPass)) {
					[self send:IRCCommandIndexJoin, prevTarget, nil];
				} else {
					[self send:IRCCommandIndexJoin, prevTarget, prevPass, nil];
				}
				
				[target setString:c.name];
				[pass	setString:c.password];
			} else {
				if (NSObjectIsEmpty(c.password)) {
					[self joinChannel:c];
				} else {
					[self joinChannel:c password:c.password];
				}
				
				[target setString:NSStringEmptyPlaceholder];
				[pass	setString:NSStringEmptyPlaceholder];
			}
		}
	}
	
	if (NSObjectIsNotEmpty(target)) {
		if (NSObjectIsEmpty(pass)) {
			[self send:IRCCommandIndexJoin, target, nil];
		} else {
			[self send:IRCCommandIndexJoin, target, pass, nil];
		}
	}
}

- (void)updateAutoJoinStatus
{
	self.autojoinInitialized = NO;
}

- (void)performAutoJoin
{
	NSMutableArray *ary = [NSMutableArray array];
	
	for (IRCChannel *c in self.channels) {
		if (c.isChannel && c.config.autoJoin) {
			if (c.isActive == NO) {
				[ary safeAddObject:c];
			}
		}
	}
	
	[self joinChannels:ary];
	
	[self performSelector:@selector(updateAutoJoinStatus) withObject:nil afterDelay:5.0];
}

- (void)joinChannels:(NSArray *)chans
{
	NSMutableArray *ary = [NSMutableArray array];
	
	BOOL pass = YES;
	
	for (IRCChannel *c in chans) {
		BOOL hasPass = NSObjectIsNotEmpty(c.password);
		
		if (pass) {
			pass = hasPass;
			
			[ary safeAddObject:c];
		} else {
			if (hasPass) {
				[self quickJoin:ary];
				
				[ary removeAllObjects];
				
				pass = hasPass;
			}
			
			[ary safeAddObject:c];
		}
		
		if (ary.count >= [TPCPreferences autojoinMaxChannelJoins]) {
			[self quickJoin:ary];
			
			[ary removeAllObjects];
			
			pass = YES;
		}
	}
	
	if (NSObjectIsNotEmpty(ary)) {
		[self quickJoin:ary];
	}
    
    [self.world reloadTree];
}

#pragma mark -
#pragma mark Trial Period Timer

#ifdef IS_TRIAL_BINARY

- (void)startTrialPeriodTimer
{
	if (self.trialPeriodTimer.isActive) return;
	
	[self.trialPeriodTimer start:_trialPeriodInterval];
}

- (void)stopTrialPeriodTimer
{
	[self.trialPeriodTimer stop];
}

- (void)onTrialPeriodTimer:(id)sender
{
	if (self.isLoggedIn) {
		self.disconnectType = IRCTrialPeriodDisconnectMode;
		
		[self quit];
	}
}

#endif

#pragma mark -
#pragma mark Encryption and Decryption Handling

- (BOOL)encryptOutgoingMessage:(NSString **)message channel:(IRCChannel *)chan
{
	if ([chan isKindOfClass:[IRCChannel class]]) {
		if (PointerIsEmpty(chan) == NO && *message) {
			if ([chan isChannel] || [chan isTalk]) {
				if (NSObjectIsNotEmpty(chan.config.encryptionKey)) {
					NSString *newstr = [CSFWBlowfish encodeData:*message
															key:chan.config.encryptionKey
													   encoding:self.config.encoding];
					
					if ([newstr length] < 5) {
						[self printDebugInformation:TXTLS(@"BlowfishEncryptionFailed") channel:chan];
						
						return NO;
					} else {
						*message = newstr;
					}
				}
			}
		}
	}
	
	return YES;
}

- (void)decryptIncomingMessage:(NSString **)message channel:(IRCChannel *)chan
{
	if ([chan isKindOfClass:[IRCChannel class]]) {
		if (PointerIsEmpty(chan) == NO && *message) {
			if ([chan isChannel] || [chan isTalk]) {
				if (NSObjectIsNotEmpty(chan.config.encryptionKey)) {
					NSString *newstr = [CSFWBlowfish decodeData:*message
															key:chan.config.encryptionKey
													   encoding:self.config.encoding];
					
					if (NSObjectIsNotEmpty(newstr)) {
						*message = newstr;
					}
				}
			}
		}
	}
}

#pragma mark -
#pragma mark Plugins and Scripts

- (void)executeTextualCmdScript:(NSDictionary *)details 
{
	if ([details containsKey:@"path"] == NO) {
		return;
	}
    
    NSString *scriptPath = [details valueForKey:@"path"];
	
#ifdef TXUserScriptsFolderAvailable
	BOOL MLNonsandboxedScript = NO;
	
	if ([scriptPath contains:[TPCPreferences whereScriptsUnsupervisedPath]]) {
		MLNonsandboxedScript = YES;
	}
#endif
    
    if ([scriptPath hasSuffix:@".scpt"]) {
		/* /////////////////////////////////////////////////////// */
		/* Event Descriptor */
		/* /////////////////////////////////////////////////////// */
		
		NSAppleEventDescriptor *firstParameter	= [NSAppleEventDescriptor descriptorWithString:[details objectForKey:@"input"]];
		NSAppleEventDescriptor *parameters		= [NSAppleEventDescriptor listDescriptor];
		
		[parameters insertDescriptor:firstParameter atIndex:1];
		
		ProcessSerialNumber psn = { 0, kCurrentProcess };
		
		NSAppleEventDescriptor *target = [NSAppleEventDescriptor descriptorWithDescriptorType:typeProcessSerialNumber
																						bytes:&psn
																					   length:sizeof(ProcessSerialNumber)];
		
		NSAppleEventDescriptor *handler = [NSAppleEventDescriptor descriptorWithString:@"textualcmd"];
		NSAppleEventDescriptor *event	= [NSAppleEventDescriptor appleEventWithEventClass:kASAppleScriptSuite
																				 eventID:kASSubroutineEvent
																		targetDescriptor:target
																				returnID:kAutoGenerateReturnID
																		   transactionID:kAnyTransactionID];
		
		[event setParamDescriptor:handler		forKeyword:keyASSubroutineName];
		[event setParamDescriptor:parameters	forKeyword:keyDirectObject];
		
		/* /////////////////////////////////////////////////////// */
		/* Execute Event — Mountain Lion, Non-sandboxed Script */
		/* /////////////////////////////////////////////////////// */
		
#ifdef TXUserScriptsFolderAvailable
		if (MLNonsandboxedScript) {
			if ([TPCPreferences featureAvailableToOSXMountainLion]) {
				NSError *aserror = [NSError new];
				
				NSUserAppleScriptTask *applescript = [[NSUserAppleScriptTask alloc] initWithURL:[NSURL fileURLWithPath:scriptPath] error:&aserror];
				
				if (PointerIsEmpty(applescript)) {
					NSLog(TXTLS(@"ScriptExecutionFailure"), [aserror localizedDescription]);
				} else {
					[applescript executeWithAppleEvent:event
									 completionHandler:^(NSAppleEventDescriptor *result, NSError *error) {
										 
										 if (PointerIsEmpty(result)) {
											 NSLog(TXTLS(@"ScriptExecutionFailure"), [error localizedDescription]);
										 } else {	
											 NSString *finalResult = [result stringValue].trim;
											 
											 if (NSObjectIsNotEmpty(finalResult)) {
												 [self.world.iomt inputText:finalResult command:IRCCommandIndexPrivmsg];
											 }
										 }
									 }];
				}
				
			}
			
			return;
		}
#endif
		
		/* /////////////////////////////////////////////////////// */
		/* Execute Event — All Other */
		/* /////////////////////////////////////////////////////// */
		
		NSDictionary *errors = [NSDictionary dictionary];
		
		NSAppleScript *appleScript = [[NSAppleScript alloc] initWithContentsOfURL:[NSURL fileURLWithPath:scriptPath] error:&errors];
        
        if (appleScript) {
            NSAppleEventDescriptor *result = [appleScript executeAppleEvent:event error:&errors];
            
            if (errors && PointerIsEmpty(result)) {
                NSLog(TXTLS(@"ScriptExecutionFailure"), errors);
            } else {	
                NSString *finalResult = [result stringValue].trim;
                
                if (NSObjectIsNotEmpty(finalResult)) {
                    [self.world.iomt inputText:finalResult command:IRCCommandIndexPrivmsg];
                }
            }
        } else {
            NSLog(TXTLS(@"ScriptExecutionFailure"), errors);	
        }
        
    } else {
		/* /////////////////////////////////////////////////////// */
		/* Execute Shell Script */
		/* /////////////////////////////////////////////////////// */
		
        NSMutableArray *args  = [NSMutableArray array];
		
        NSString *input = [details valueForKey:@"input"];
        
        for (NSString *i in [input componentsSeparatedByCharactersInSet:[NSCharacterSet whitespaceCharacterSet]]) {
            [args addObject:i];
        }
        
        NSTask *scriptTask = [NSTask new];
        NSPipe *outputPipe = [NSPipe pipe];
        
        if ([_NSFileManager() isExecutableFileAtPath:scriptPath] == NO) {
            NSArray *chmodArguments = [NSArray arrayWithObjects:@"+x", scriptPath, nil];
            
			NSTask *chmod = [NSTask launchedTaskWithLaunchPath:@"/bin/chmod" arguments:chmodArguments];
            
            [chmod waitUntilExit];
        }
        
        [scriptTask setStandardOutput:outputPipe];
        [scriptTask setLaunchPath:scriptPath];
        [scriptTask setArguments:args];
        
        NSFileHandle *filehandle = [outputPipe fileHandleForReading];
        
        [scriptTask launch];
        [scriptTask waitUntilExit];
        
        NSData *outputData    = [filehandle readDataToEndOfFile];
		
		NSString *outputString  = [NSString stringWithData:outputData encoding:NSUTF8StringEncoding];
        
        if (NSObjectIsNotEmpty(outputString)) {
            [self.world.iomt inputText:outputString command:IRCCommandIndexPrivmsg];
        }
        
    }
}

- (void)processBundlesUserMessage:(NSArray *)info
{
	NSString *command = NSStringEmptyPlaceholder;
	NSString *message = [info safeObjectAtIndex:0];
	
	if ([info count] == 2) {
		command = [info safeObjectAtIndex:1];
		command = [command uppercaseString];
	}
	
	[NSBundle sendUserInputDataToBundles:self.world message:message command:command client:self];
}

- (void)processBundlesServerMessage:(IRCMessage *)msg
{
	[NSBundle sendServerInputDataToBundles:self.world client:self message:msg];
}

#pragma mark -
#pragma mark Sending Text

- (BOOL)inputText:(id)str command:(NSString *)command
{
	if (self.isConnected == NO) {
		if (NSObjectIsEmpty(str)) {
			return NO;
		}
	}
	
	id sel = self.world.selected;
	
	if (PointerIsEmpty(sel)) {
        return NO;
    }
	
    if ([str isKindOfClass:[NSString class]]) {
        str = [NSAttributedString emptyStringWithBase:str];
    }
    
    NSArray *lines = [str performSelector:@selector(splitIntoLines)];
	
	for (__strong NSAttributedString *s in lines) {
		if (NSObjectIsEmpty(s)) {
            continue;
        }
        
        NSRange chopRange = NSMakeRange(1, (s.string.length - 1));
		
		if ([sel isClient]) {
			if ([s.string hasPrefix:@"/"]) {
                s = [s attributedSubstringFromRange:chopRange];
			}
			
			[self sendCommand:s];
		} else {
			IRCChannel *channel = (IRCChannel *)sel;
			
			if ([s.string hasPrefix:@"/"] && [s.string hasPrefix:@"//"] == NO) {
                s = [s attributedSubstringFromRange:chopRange];
				
				[self sendCommand:s];
			} else {
				if ([s.string hasPrefix:@"/"]) {
                    s = [s attributedSubstringFromRange:chopRange];
				}
				
				[self sendText:s command:command channel:channel];
			}
		}
	}
	
	return YES;
}

- (void)sendPrivmsgToSelectedChannel:(NSString *)message
{
    NSAttributedString *new = [NSAttributedString emptyStringWithBase:message];
    
	[self sendText:new command:IRCCommandIndexPrivmsg channel:[self.world selectedChannelOn:self]];
}

- (void)sendText:(NSAttributedString *)str command:(NSString *)command channel:(IRCChannel *)channel
{
	if (NSObjectIsEmpty(str)) {
        return;
    }
	
	TVCLogLineType type;
	
	if ([command isEqualToString:IRCCommandIndexNotice]) {
		type = TVCLogLineNoticeType;
	} else if ([command isEqualToString:IRCCommandIndexAction]) {
		type = TVCLogLineActionType;
	} else {
		type = TVCLogLinePrivateMessageType;
	}
	
	if ([self.world.bundlesForUserInput containsKey:command]) {
		[self.invokeInBackgroundThread processBundlesUserMessage:[NSArray arrayWithObjects:str.string, nil, nil]];
	}
	
	NSArray *lines = [str performSelector:@selector(splitIntoLines)];
	
	for (NSAttributedString *line in lines) {
		if (NSObjectIsEmpty(line)) {
            continue;
        }
		
        NSMutableAttributedString *str = [line mutableCopy];
		
		while (NSObjectIsNotEmpty(str)) {
            NSString *newstr = [str attributedStringToASCIIFormatting:&str
															 lineType:type
															  channel:channel.name
															 hostmask:self.myHost];
			
			[self printBoth:channel type:type nick:self.myNick text:newstr identified:YES];
			
			if ([self encryptOutgoingMessage:&newstr channel:channel] == NO) {
				continue;
			}
			
			NSString *cmd = command;
			
			if (type == TVCLogLineActionType) {
				cmd = IRCCommandIndexPrivmsg;
                
				newstr = [NSString stringWithFormat:@"%c%@ %@%c", 0x01, IRCCommandIndexAction, newstr, 0x01];
			} else if (type == TVCLogLinePrivateMessageType) {
				[channel detectOutgoingConversation:newstr];
			}
			
			[self send:cmd, channel.name, newstr, nil];
		}
	}
}

- (void)sendCTCPQuery:(NSString *)target command:(NSString *)command text:(NSString *)text
{
	if (NSObjectIsEmpty(command)) {
		return;
	}
	
	NSString *trail;
	
	if (NSObjectIsNotEmpty(text)) {
		trail = [NSString stringWithFormat:@"%c%@ %@%c", 0x01, command, text, 0x01];
	} else {
		trail = [NSString stringWithFormat:@"%c%@%c", 0x01, command, 0x01];
	}
	
	[self send:IRCCommandIndexPrivmsg, target, trail, nil];
}

- (void)sendCTCPReply:(NSString *)target command:(NSString *)command text:(NSString *)text
{
	NSString *trail;
	
	if (NSObjectIsNotEmpty(text)) {
		trail = [NSString stringWithFormat:@"%c%@ %@%c", 0x01, command, text, 0x01];
	} else {
		trail = [NSString stringWithFormat:@"%c%@%c", 0x01, command, 0x01];
	}
	
	[self send:IRCCommandIndexNotice, target, trail, nil];
}

- (void)sendCTCPPing:(NSString *)target
{
	[self sendCTCPQuery:target command:IRCCommandIndexPing text:[NSString stringWithFormat:@"%qu", mach_absolute_time()]];
}

- (BOOL)sendCommand:(id)str
{
	return [self sendCommand:str completeTarget:YES target:nil];
}

- (BOOL)sendCommand:(id)str completeTarget:(BOOL)completeTarget target:(NSString *)targetChannelName
{
    NSMutableAttributedString *s = [NSMutableAttributedString alloc];
    
    if ([str isKindOfClass:[NSString class]]) {
        s = [s initWithString:str];
    } else {
        if ([str isKindOfClass:[NSAttributedString class]]) {
            s = [s initWithAttributedString:str];
        }
    }
	
	NSString *cmd = [s.getToken.string uppercaseString];
	
	if (NSObjectIsEmpty(cmd)) return NO;
	if (NSObjectIsEmpty(str)) return NO;
	
	IRCClient  *u = [self.world selectedClient];
	IRCChannel *c = [self.world selectedChannel];
	
	IRCChannel *selChannel = nil;
	
	if ([cmd isEqualToString:IRCCommandIndexMode] && ([s.string hasPrefix:@"+"] || [s.string hasPrefix:@"-"]) == NO) {
		// Do not complete for /mode #chname ...
	} else if (completeTarget && targetChannelName) {
		selChannel = [self findChannel:targetChannelName];
	} else if (completeTarget && u == self && c) {
		selChannel = c;
	}
	
	BOOL cutColon = NO;
	
	if ([s.string hasPrefix:@"/"]) {
		cutColon = YES;
		
        [s deleteCharactersInRange:NSMakeRange(0, 1)];
	}
	
	switch ([TPCPreferences indexOfIRCommand:cmd]) {
		case 3: // Command: AWAY
		{
            NSString *msg = s.string;
            
			if (NSObjectIsEmpty(s) && cutColon == NO) {
                if (self.isAway == NO) {
                    msg = TXTLS(@"IRCAwayCommandDefaultReason");
                }
			}
			
			if ([TPCPreferences awayAllConnections]) {
				for (IRCClient *u in [self.world clients]) {
					if (u.isConnected == NO) continue;
					
					[u.client send:cmd, msg, nil];
				}
			} else {
				if (self.isConnected == NO) return NO;
				
				[self send:cmd, msg, nil];
			}
			
			return YES;
			break;
		}
		case 5: // Command: INVITE
		{
			/* invite nick[ nick[ ...]] [channel] */
			
			if (NSObjectIsEmpty(s)) {
				return NO;
			}
			
            NSMutableArray *nicks = [NSMutableArray arrayWithArray:[s.mutableString componentsSeparatedByString:NSStringWhitespacePlaceholder]];
			
			if ([nicks count] && [nicks.lastObject isChannelName]) {
				targetChannelName = [nicks lastObject];
				
				[nicks removeLastObject];
			} else if (c) {
				targetChannelName = c.name;
			} else {
				return NO;
			}
			
			for (NSString *nick in nicks) {
				[self send:cmd, nick, targetChannelName, nil];
			}
			
			return YES;
			break;
		}
		case 51: // Command: J
		case 7:  // Command: JOIN
		{
			if (selChannel && selChannel.isChannel && NSObjectIsEmpty(s)) {
				targetChannelName = selChannel.name;
			} else {
                if (NSObjectIsEmpty(s)) {
                    return NO;
                }
                
				targetChannelName = s.getToken.string;
				
				if ([targetChannelName isChannelName] == NO && [targetChannelName isEqualToString:@"0"] == NO) {
					targetChannelName = [@"#" stringByAppendingString:targetChannelName];
				}
			}
			
			[self send:IRCCommandIndexJoin, targetChannelName, s.string, nil];
			
			return YES;
			break;
		}
		case 8: // Command: KICK
		{
			if (selChannel && selChannel.isChannel) {
				targetChannelName = selChannel.name;
			} else {
                if (NSObjectIsEmpty(s)) {
                    return NO;
                }
                
				targetChannelName = s.getToken.string;
			}
			
			NSString *peer = s.getToken.string;
			
			if (peer) {
				NSString *reason = [s.string trim];
				
				if (NSObjectIsEmpty(reason)) {
					reason = [TPCPreferences defaultKickMessage];
				}
				
				[self send:cmd, targetChannelName, peer, reason, nil];
			}
			
			return YES;
			break;
		}
		case 9: // Command: KILL
		{
			NSString *peer = s.getToken.string;
			
			if (peer) {
				NSString *reason = [s.string trim];
				
				if (NSObjectIsEmpty(reason)) {
					reason = [TPCPreferences IRCopDefaultKillMessage];
				}
				
				[self send:IRCCommandIndexKill, peer, reason, nil];
			}
			
			return YES;
			break;
		}
		case 10: // Command: LIST
		{
			if (PointerIsEmpty(self.channelListDialog)) {
				[self createChannelListDialog];
			}
			
			[self send:IRCCommandIndexList, s.string, nil];
			
			return YES;
			break;
		}
		case 13: // Command: NICK
		{
			NSString *newnick = s.getToken.string;
			
			if ([TPCPreferences nickAllConnections]) {
				for (IRCClient *u in [self.world clients]) {
					if ([u isConnected] == NO) continue;
					
					[u.client changeNick:newnick];
				}
			} else {
				if (self.isConnected == NO) return NO;
				
				[self changeNick:newnick];
			}
			
			return YES;
			break;
		}
		case 14: // Command: NOTICE
		case 19: // Command: PRIVMSG
		case 27: // Command: ACTION
		case 38: // Command: OMSG
		case 39: // Command: ONOTICE
		case 54: // Command: ME
		case 55: // Command: MSG
		case 92: // Command: SME
		case 93: // Command: SMSG
		{
			BOOL opMsg      = NO;
			BOOL secretMsg  = NO;
			
			if ([cmd isEqualToString:IRCCommandIndexMsg]) {
				cmd = IRCCommandIndexPrivmsg;
			} else if ([cmd isEqualToString:IRCCommandIndexOmsg]) {
				opMsg = YES;
                
				cmd = IRCCommandIndexPrivmsg;
			} else if ([cmd isEqualToString:IRCCommandIndexOnotice]) {
				opMsg = YES;
                
				cmd = IRCCommandIndexNotice;
			} else if ([cmd isEqualToString:IRCCommandIndexSme]) {
				secretMsg = YES;
                
				cmd = IRCCommandIndexMe;
			} else if ([cmd isEqualToString:IRCCommandIndexSmsg]) {
				secretMsg = YES;
                
				cmd = IRCCommandIndexPrivmsg;
			} 
			
			if ([cmd isEqualToString:IRCCommandIndexPrivmsg] || 
				[cmd isEqualToString:IRCCommandIndexNotice] || 
				[cmd isEqualToString:IRCCommandIndexAction]) {
				
				if (opMsg) {
					if (selChannel && selChannel.isChannel && [s.string isChannelName] == NO) {
						targetChannelName = selChannel.name;
					} else {
						targetChannelName = s.getToken.string;
					}
				} else {
					targetChannelName = s.getToken.string;
				}
			} else if ([cmd isEqualToString:IRCCommandIndexMe]) {
				cmd = IRCCommandIndexAction;
				
				if (selChannel) {
					targetChannelName = selChannel.name;
				} else {
					targetChannelName = s.getToken.string;
				}
			}
			
			if ([cmd isEqualToString:IRCCommandIndexPrivmsg] ||
				[cmd isEqualToString:IRCCommandIndexNotice]) {
				
				if ([s.string hasPrefix:@"\x01"]) {
					cmd = (([cmd isEqualToString:IRCCommandIndexPrivmsg]) ? IRCCommandIndexCtcp : IRCCommandIndexCtcpreply);
					
                    [s deleteCharactersInRange:NSMakeRange(0, 1)];
					
					NSRange r = [s.string rangeOfString:@"\x01"];
					
					if (NSDissimilarObjects(r.location, NSNotFound)) {
						NSInteger len = (s.length - r.location);
						
						if (len > 0) {
                            [s deleteCharactersInRange:NSMakeRange(r.location, len)];
						}
					}
				}
			}
			
			if ([cmd isEqualToString:IRCCommandIndexCtcp]) {
                NSMutableAttributedString *t = s.mutableCopy;
				
                NSString *subCommand = [t.getToken.string uppercaseString];
				
				if ([subCommand isEqualToString:IRCCommandIndexAction]) {
					cmd = IRCCommandIndexAction;
                    
					s = t;
                    
					targetChannelName = s.getToken.string;
				} else {
					NSString *subCommand = [s.getToken.string uppercaseString];
					
					if (NSObjectIsNotEmpty(subCommand)) {
						targetChannelName = s.getToken.string;
						
						if ([subCommand isEqualToString:IRCCommandIndexPing]) {
							[self sendCTCPPing:targetChannelName];
						} else {
							[self sendCTCPQuery:targetChannelName command:subCommand text:s.string];
						}
					}
					
					return YES;
				}
			}
			
			if ([cmd isEqualToString:IRCCommandIndexCtcpreply]) {
				targetChannelName = s.getToken.string;
				
				NSString *subCommand = s.getToken.string;
				
				[self sendCTCPReply:targetChannelName command:subCommand text:s.string];
				
				return YES;
			}
			
			if ([cmd isEqualToString:IRCCommandIndexPrivmsg] || 
				[cmd isEqualToString:IRCCommandIndexNotice] || 
				[cmd isEqualToString:IRCCommandIndexAction]) {
				
				if (NSObjectIsEmpty(s))                 return NO;
				if (NSObjectIsEmpty(targetChannelName)) return NO;
				
				TVCLogLineType type;
				
				if ([cmd isEqualToString:IRCCommandIndexNotice]) {
					type = TVCLogLineNoticeType;
				} else if ([cmd isEqualToString:IRCCommandIndexAction]) {
					type = TVCLogLineActionType;
				} else {
					type = TVCLogLinePrivateMessageType;
				}
                
				while (NSObjectIsNotEmpty(s)) {
					NSArray *targets = [targetChannelName componentsSeparatedByString:@","];
                    
                    NSString *t = [s attributedStringToASCIIFormatting:&s
															  lineType:type
															   channel:targetChannelName
															  hostmask:self.myHost];
					
					for (__strong NSString *chname in targets) {
						if (NSObjectIsEmpty(chname)) {
                            continue;
                        }
						
						BOOL opPrefix = NO;
						
						if ([chname hasPrefix:@"@"]) {
							opPrefix = YES;
                            
							chname = [chname safeSubstringFromIndex:1];
						}
						
						IRCChannel *c = [self findChannel:chname];
						
						if (PointerIsEmpty(c) && secretMsg == NO && [chname isChannelName] == NO) {
							if (type == TVCLogLineNoticeType) {
                                NSString *msg;
                                msg = [NSString stringWithFormat:@">-%@", chname ];
								[self printBoth:[world selectedChannelOn:self] type:type nick:msg text:t identified:YES];
                                //c = (id)self;
							} else {
								c = [self.world createTalk:chname client:self];
							}
						}
						
						if (c) {
							[self printBoth:c type:type nick:self.myNick text:t identified:YES];
							
							if ([self encryptOutgoingMessage:&t channel:c] == NO) {
								continue;
							}
						}
						
						if ([chname isChannelName]) {
							if (opMsg || opPrefix) {
								chname = [@"@" stringByAppendingString:chname];
							}
						}
						
						NSString *localCmd = cmd;
						
						if ([localCmd isEqualToString:IRCCommandIndexAction]) {
							localCmd = IRCCommandIndexPrivmsg;
							
							t = [NSString stringWithFormat:@"\x01%@ %@\x01", IRCCommandIndexAction, t];
						}
						
						[self send:localCmd, chname, t, nil];
						
                        if (c && [TPCPreferences giveFocusOnMessage]) {
                            [self.world select:c];
                        }
					}
				}
			} 
			
			return YES;
			break;
		}
		case 15: // Command: PART
		case 52: // Command: LEAVE
		{
			if (selChannel && selChannel.isChannel && [s.string isChannelName] == NO) {
				targetChannelName = selChannel.name;
			} else if (selChannel && selChannel.isTalk && [s.string isChannelName] == NO) {
				[self.world destroyChannel:selChannel];
				
				return YES;
			} else {
				targetChannelName = s.getToken.string;
			}
			
			if (targetChannelName) {
				NSString *reason = [s.string trim];
				
				if (NSObjectIsEmpty(s) && cutColon == NO) {
					reason = [self.config leavingComment];
				}
				
				[self partUnlistedChannel:targetChannelName withComment:reason];
			}
			
			return YES;
			break;
		}
		case 20: // Command: QUIT
		{
			[self quit:s.string.trim];
			
			return YES;
			break;
		}
		case 21: // Command: TOPIC
		case 61: // Command: T
		{
			if (selChannel && selChannel.isChannel && [s.string isChannelName] == NO) {
				targetChannelName = selChannel.name;
			} else {
				targetChannelName = s.getToken.string;
			}
			
			if (targetChannelName) {
				NSString *topic = [s attributedStringToASCIIFormatting];
                
				if (NSObjectIsEmpty(topic)) {
					topic = nil;
				}
				
				IRCChannel *c = [self findChannel:targetChannelName];
				
				if ([self encryptOutgoingMessage:&topic channel:c] == YES) {
					[self send:IRCCommandIndexTopic, targetChannelName, topic, nil];
				}
			}
			
			return YES;
			break;
		}
		case 23: // Command: WHO
		{
			self.inWhoInfoRun = YES;
			
			[self send:IRCCommandIndexWho, s.string, nil];
			
			return YES;
			break;
		}
		case 24: // Command: WHOIS
		{
			NSString *peer = s.string;
			
			if (NSObjectIsEmpty(peer)) {
				IRCChannel *c = self.world.selectedChannel;
				
				if (c.isTalk) {
					peer = c.name;
				} else {
					return NO;
				}
			}
			
			if ([s.string contains:NSStringWhitespacePlaceholder]) {
				[self sendLine:[NSString stringWithFormat:@"%@ %@", IRCCommandIndexWhois, peer]];
			} else {
				[self send:IRCCommandIndexWhois, peer, peer, nil];
			}
			
			return YES;
			break;
		}
		case 32: // Command: CTCP
		{ 
			targetChannelName = s.getToken.string;
			
			if (NSObjectIsNotEmpty(targetChannelName)) {
				NSString *subCommand = [s.getToken.string uppercaseString];
				
				if ([subCommand isEqualToString:IRCCommandIndexPing]) {
					[self sendCTCPPing:targetChannelName];
				} else {
					[self sendCTCPQuery:targetChannelName command:subCommand text:s.string];
				}
			}
			
			return YES;
			break;
		}
		case 33: // Command: CTCPREPLY
		{
			targetChannelName = s.getToken.string;
			
			NSString *subCommand = s.getToken.string;
			
			[self sendCTCPReply:targetChannelName command:subCommand text:s.string];
			
			return YES;
			break;
		}
		case 41: // Command: BAN
		case 64: // Command: UNBAN
		{
			if (c) {
				NSString *peer = s.getToken.string;
				
				if (peer) {
					IRCUser *user = [c findMember:peer];
                    
					NSString *host = ((user) ? [user banMask] : peer);
					
					if ([cmd isEqualToString:IRCCommandIndexBan]) {
						[self sendCommand:[NSString stringWithFormat:@"MODE +b %@", host] completeTarget:YES target:c.name];
					} else {
						[self sendCommand:[NSString stringWithFormat:@"MODE -b %@", host] completeTarget:YES target:c.name];
					}
				}
			}
			
			return YES;
			break;
		}
		case 11: // Command: MODE
		case 45: // Command: DEHALFOP
		case 46: // Command: DEOP
		case 47: // Command: DEVOICE
		case 48: // Command: HALFOP
		case 56: // Command: OP
		case 63: // Command: VOICE
		case 66: // Command: UMODE
		case 53: // Command: M
		{
			if ([cmd isEqualToString:IRCCommandIndexM]) {
				cmd = IRCCommandIndexMode;
			}
			
			if ([cmd isEqualToString:IRCCommandIndexMode]) {
				if (selChannel && selChannel.isChannel && [s.string isModeChannelName] == NO) {
					targetChannelName = selChannel.name;
				} else if (([s.string hasPrefix:@"+"] || [s.string hasPrefix:@"-"]) == NO) {
					targetChannelName = s.getToken.string;
				}
			} else if ([cmd isEqualToString:IRCCommandIndexUmode]) {
                [s insertAttributedString:[NSAttributedString emptyStringWithBase:NSStringWhitespacePlaceholder]	atIndex:0];
                [s insertAttributedString:[NSAttributedString emptyStringWithBase:self.myNick]						atIndex:0];
			} else {
				if (selChannel && selChannel.isChannel && [s.string isModeChannelName] == NO) {
					targetChannelName = selChannel.name;
				} else {
					targetChannelName = s.getToken.string;
				}
				
				NSString *sign;
				
				if ([cmd hasPrefix:@"DE"] || [cmd hasPrefix:@"UN"]) {
					sign = @"-";
                    
					cmd = [cmd safeSubstringFromIndex:2];
				} else {
					sign = @"+";
				}
				
				NSArray *params = [s.string componentsSeparatedByCharactersInSet:[NSCharacterSet whitespaceCharacterSet]];
				
				if (NSObjectIsEmpty(params)) {
					return YES;
				} else {
					NSMutableString *ms = [NSMutableString stringWithString:sign];
                    
					NSString *modeCharStr;
					
                    modeCharStr = [cmd safeSubstringToIndex:1];
                    modeCharStr = [modeCharStr lowercaseString];
                    
					for (NSInteger i = (params.count - 1); i >= 0; --i) {
						[ms appendString:modeCharStr];
					}
					
					[ms appendString:NSStringWhitespacePlaceholder];
					[ms appendString:s.string];
					
                    [s setAttributedString:[NSAttributedString emptyStringWithBase:ms]];
				}
			}
			
			NSMutableString *line = [NSMutableString string];
			
			[line appendString:IRCCommandIndexMode];
			
			if (NSObjectIsNotEmpty(targetChannelName)) {
				[line appendString:NSStringWhitespacePlaceholder];
				[line appendString:targetChannelName];
			}
			
			if (NSObjectIsNotEmpty(s)) {
				[line appendString:NSStringWhitespacePlaceholder];
				[line appendString:s.string];
			}
			
			[self sendLine:line];
			
			return YES;
			break;
		}
		case 42: // Command: CLEAR
		{
			if (c) {
				[self.world clearContentsOfChannel:c inClient:self];
				
				[c setDockUnreadCount:0];
				[c setTreeUnreadCount:0];
				[c setKeywordCount:0];
			} else if (u) {
				[self.world clearContentsOfClient:self];
				
				[u setDockUnreadCount:0];
				[u setTreeUnreadCount:0];
				[u setKeywordCount:0];
			}
			
			[self.world updateIcon];
			[self.world reloadTree];
			
			return YES;
			break;
		}
		case 43: // Command: CLOSE
		case 77: // Command: REMOVE
		{
			NSString *nick = s.getToken.string;
			
			if (NSObjectIsNotEmpty(nick)) {
				c = [self findChannel:nick];
			}
			
			if (c) {
				[self.world destroyChannel:c];
			}
			
			return YES;
			break;
		}
		case 44: // Command: REJOIN
		case 49: // Command: CYCLE
		case 58: // Command: HOP
		{
			if (c) {
				NSString *pass = nil;
				
				if ([c.mode modeIsDefined:@"k"]) {
					pass = [c.mode modeInfoFor:@"k"].param;
				}
				
				[self partChannel:c];
				[self forceJoinChannel:c.name password:pass];
			}
			
			return YES;
			break;
		}
		case 50: // Command: IGNORE
		case 65: // Command: UNIGNORE
		{
			if (NSObjectIsEmpty(s)) {
				[self.world.menuController showServerPropertyDialog:self ignore:@"--"];
			} else {
				NSString *n = s.getToken.string;
                
				IRCUser  *u = [c findMember:n];
				
				if (PointerIsEmpty(u)) {
					[self.world.menuController showServerPropertyDialog:self ignore:n];
					
					return YES;
				}
				
				NSString *hostmask = [u banMask];
				
				IRCAddressBook *g = [IRCAddressBook new];
				
				g.hostmask = hostmask;
                
				g.ignorePublicMsg       = YES;
				g.ignorePrivateMsg      = YES;
				g.ignoreHighlights      = YES;
				g.ignorePMHighlights    = YES;
				g.ignoreNotices         = YES;
				g.ignoreCTCP            = YES;
				g.ignoreJPQE            = YES;
				g.notifyJoins           = NO;
				
				[g processHostMaskRegex];
				
				if ([cmd isEqualToString:IRCCommandIndexIgnore]) {
					BOOL found = NO;
					
					for (IRCAddressBook *e in self.config.ignores) {
						if ([g.hostmask isEqualToString:e.hostmask]) {
							found = YES;
                            
							break;
						}
					}
					
					if (found == NO) {
						[self.config.ignores safeAddObject:g];
                        
						[self.world save];
					}
				} else {
					NSMutableArray *ignores = self.config.ignores;
					
					for (NSInteger i = (ignores.count - 1); i >= 0; --i) {
						IRCAddressBook *e = [ignores safeObjectAtIndex:i];
						
						if ([g.hostmask isEqualToString:e.hostmask]) {
							[ignores safeRemoveObjectAtIndex:i];
							
							[self.world save];
							
							break;
						}
					}
				}
			}
			
			return YES;
			break;
		}
		case 57: // Command: RAW
		case 60: // Command: QUOTE
		{
			[self sendLine:s.string];
			
			return YES;
			break;
		}
		case 59: // Command: QUERY
		{
			NSString *nick = s.getToken.string;
			
			if (NSObjectIsEmpty(nick)) {
				if (c && c.isTalk) {
					[self.world destroyChannel:c];
				}
			} else {
				IRCChannel *c = [self findChannelOrCreate:nick useTalk:YES];
				
				[self.world select:c];
			}
			
			return YES;
			break;
		}
		case 62: // Command: TIMER
		{	
			NSInteger interval = [s.getToken.string integerValue];
			
			if (interval > 0) {
				TLOTimerCommand *cmd = [TLOTimerCommand new];
				
				if ([s.string hasPrefix:@"/"]) {
                    [s deleteCharactersInRange:NSMakeRange(0, 1)];
				}
				
				cmd.input = s.string;
				cmd.cid   = ((c) ? c.uid : -1);
				cmd.time  = (CFAbsoluteTimeGetCurrent() + interval);
				
				[self addCommandToCommandQueue:cmd];
			} else {
				[self printBoth:[self.world selectedChannelOn:self] type:TVCLogLineErrorReplyType text:TXTLS(@"IRCTimerCommandRequiresInteger")];
			}
			
			return YES;
			break;
		}
		case 68: // Command: WEIGHTS
		{
			if (c) {
				NSInteger tc = 0;
				
				for (IRCUser *m in c.members) {
					if (m.totalWeight > 0) {
						NSString *text = TXTFLS(@"IRCWeightsCommandResultRow", m.nick, m.incomingWeight, m.outgoingWeight, m.totalWeight);
						
						tc++;
						
						[self printBoth:[self.world selectedChannelOn:self] type:TVCLogLineReplyType text:text];
					}
				}
				
				if (tc == 0) {
					[self printBoth:[self.world selectedChannelOn:self] type:TVCLogLineReplyType text:TXTLS(@"IRCWeightsCommandNoResults")];
				}
			}
			
			return YES;
			break;
		}
		case 69: // Command: ECHO
		case 70: // Command: DEBUG
		{
			if ([s.string isEqualNoCase:@"raw on"]) {
				self.rawModeEnabled = YES;
				
				[self printBoth:[self.world selectedChannelOn:self] type:TVCLogLineReplyType text:TXTLS(@"IRCRawModeIsEnabled")];
			} else if ([s.string isEqualNoCase:@"raw off"]) {
				self.rawModeEnabled = NO;	
				
				[self printBoth:[self.world selectedChannelOn:self] type:TVCLogLineReplyType text:TXTLS(@"IRCRawModeIsDisabled")];
			} else {
				[self printBoth:[self.world selectedChannelOn:self] type:TVCLogLineReplyType text:s.string];
			}
			
			return YES;
			break;
		}
		case 71: // Command: CLEARALL
		{
			if ([TPCPreferences clearAllOnlyOnActiveServer]) {
				[self.world clearContentsOfClient:self];
				
				for (IRCChannel *c in self.channels) {
					[self.world clearContentsOfChannel:c inClient:self];
					
					[c setDockUnreadCount:0];
					[c setTreeUnreadCount:0];
					[c setKeywordCount:0];
				}
			} else {
				for (IRCClient *u in [self.world clients]) {
					[world clearContentsOfClient:u];
					
					for (IRCChannel *c in [u channels]) {
						[self.world clearContentsOfChannel:c inClient:u];
						
						[c setDockUnreadCount:0];
						[c setTreeUnreadCount:0];
						[c setKeywordCount:0];
					}
				}
			}
			
			[self.world updateIcon];
			[self.world reloadTree];
			[self.world markAllAsRead];
			
			return YES;
			break;
		}
		case 72: // Command: AMSG
		{
            [s insertAttributedString:[NSAttributedString emptyStringWithBase:@"MSG "] atIndex:0];
            
			if ([TPCPreferences amsgAllConnections]) {
				for (IRCClient *u in [self.world clients]) {
					if ([u isConnected] == NO) continue;
					
					for (IRCChannel *c in [u channels]) {
						c.isUnread = YES;
                        
						[u.client sendCommand:s completeTarget:YES target:c.name];
					}
				}
			} else {
				if (self.isConnected == NO) return NO;
				
				for (IRCChannel *c in self.channels) {
					c.isUnread = YES;
                    
					[self sendCommand:s completeTarget:YES target:c.name];
				}
			}
			
			[self reloadTree];
			
			return YES;
			break;
		}
		case 73: // Command: AME
		{
            [s insertAttributedString:[NSAttributedString emptyStringWithBase:@"ME "] atIndex:0];
            
			if ([TPCPreferences amsgAllConnections]) {
				for (IRCClient *u in [self.world clients]) {
					if ([u isConnected] == NO) continue;
					
					for (IRCChannel *c in [u channels]) {
						c.isUnread = YES;
						
						[u.client sendCommand:s completeTarget:YES target:c.name];
					}
				}
			} else {
				if (self.isConnected == NO) return NO;
				
				for (IRCChannel *c in self.channels) {
					c.isUnread = YES;
					
                    [u.client sendCommand:s completeTarget:YES target:c.name];
				}
			}
			
			[self reloadTree];
			
			return YES;
			break;
		}
		case 78: // Command: KB
		case 79: // Command: KICKBAN 
		{
			if (c) {
				NSString *peer = s.getToken.string;
				
				if (peer) {
					NSString *reason = [s.string trim];
					
					IRCUser *user = [c findMember:peer];
                    
					NSString *host = ((user) ? [user banMask] : peer);
					
					if (NSObjectIsEmpty(reason)) {
						reason = [TPCPreferences defaultKickMessage];
					}
					
					[self send:IRCCommandIndexMode, c.name, @"+b", host, nil];
					[self send:IRCCommandIndexKick, c.name, user.nick, reason, nil];
				}
			}
			
			return YES;
			break;
		}
		case 81: // Command: ICBADGE
		{
			if ([s.string contains:NSStringWhitespacePlaceholder] == NO) return NO;
			
			NSArray *data = [s.string componentsSeparatedByCharactersInSet:[NSCharacterSet whitespaceCharacterSet]];
			
			[TVCDockIcon drawWithHilightCount:[data integerAtIndex:0] 
								 messageCount:[data integerAtIndex:1]];
			
			return YES;
			break;
		}
		case 82: // Command: SERVER
		{
			if (NSObjectIsNotEmpty(s)) {
				[self.world createConnection:s.string chan:nil];
			}
			
			return YES;
			break;
		}
		case 83: // Command: CONN
		{
			if (NSObjectIsNotEmpty(s)) {
				[self.config setHost:s.getToken.string];
			}
			
			if (self.isConnected) [self quit];
			
			[self performSelector:@selector(connect) withObject:nil afterDelay:2.0];
			
			return YES;
			break;
		}
		case 84: // Command: MYVERSION
		{
			NSString *ref  = [TPCPreferences gitBuildReference];
			NSString *name = [TPCPreferences applicationName];
			NSString *vers = [[TPCPreferences textualInfoPlist] objectForKey:@"CFBundleVersion"];
			
			NSString *text = [NSString stringWithFormat:TXTLS(@"IRCCTCPVersionInfo"), name, vers, ((NSObjectIsEmpty(ref)) ? TXTLS(@"Unknown") : ref)];
			
			if (c.isChannel == NO && c.isTalk == NO) {
				[self printDebugInformationToConsole:text];
			} else {
				text = TXTFLS(@"IRCCTCPVersionTitle", text);
				
				[self sendPrivmsgToSelectedChannel:text];
			}
			
			return YES;
			break;
		}
		case 74: // Command: MUTE
		{
			if (self.world.soundMuted) {
				[self printBoth:[self.world selectedChannelOn:self] type:TVCLogLineReplyType text:TXTLS(@"SoundIsAlreadyMuted")];
			} else {
				[self printBoth:[self.world selectedChannelOn:self] type:TVCLogLineReplyType text:TXTLS(@"SoundIsNowMuted")];
				
				[self.world setSoundMuted:YES];
			}
			
			return YES;
			break;
		}
		case 75: // Command: UNMUTE
		{
			if (self.world.soundMuted) {
				[self printBoth:[self.world selectedChannelOn:self] type:TVCLogLineReplyType text:TXTLS(@"SoundIsNoLongerMuted")];
				
				[self.world setSoundMuted:NO];
			} else {
				[self printBoth:[self.world selectedChannelOn:self] type:TVCLogLineReplyType text:TXTLS(@"SoundIsNotMuted")];
			}
			
			return YES;
			break;
		}
		case 76: // Command: UNLOAD_PLUGINS
		{
			[NSBundle.invokeInBackgroundThread deallocBundlesFromMemory:self.world];
			
			return YES;
			break;
		}
		case 91: // Command: LOAD_PLUGINS
		{
			[NSBundle.invokeInBackgroundThread loadBundlesIntoMemory:self.world];
			
			return YES;
			break;
		}
		case 94: // Command: LAGCHECK
		case 95: // Command: MYLAG
		{
			self.lastLagCheck = CFAbsoluteTimeGetCurrent();
			
			if ([cmd isEqualNoCase:IRCCommandIndexMylag]) {
				self.sendLagcheckToChannel = YES;
			}
			
			[self sendCTCPQuery:self.myNick command:IRCCommandIndexLagcheck text:[NSString stringWithDouble:self.lastLagCheck]];
			
			[self printDebugInformation:TXTLS(@"LagCheckRequestSentMessage")];
			
			return YES;
			break;
		}
		case 96: // Command: ZLINE
		case 97: // Command: GLINE
		case 98: // Command: GZLINE
		{
			NSString *peer = s.getToken.string;
			
			if ([peer hasPrefix:@"-"]) {
				[self send:cmd, peer, s.string, nil];
			} else {
				NSString *time   = s.getToken.string;
				NSString *reason = s.string;
				
				if (peer) {
					reason = [reason trim];
					
					if (NSObjectIsEmpty(reason)) {
						reason = [TPCPreferences IRCopDefaultGlineMessage];
						
						if ([reason contains:NSStringWhitespacePlaceholder]) {
							NSInteger spacePos = [reason stringPosition:NSStringWhitespacePlaceholder];
							
							if (NSObjectIsEmpty(time)) {
								time = [reason safeSubstringToIndex:spacePos];
							}
							
							reason = [reason safeSubstringAfterIndex:spacePos];
						}
					}
					
					[self send:cmd, peer, time, reason, nil];
				}
			}
			
			return YES;
			break;
		}
		case 99:  // Command: SHUN
		case 100: // Command: TEMPSHUN
		{
			NSString *peer = s.getToken.string;
			
			if ([peer hasPrefix:@"-"]) {
				[self send:cmd, peer, s.string, nil];
			} else {
				if (peer) {
					if ([cmd isEqualToString:IRCCommandIndexTempshun]) {
						NSString *reason = s.getToken.string.trim;
						
						if (NSObjectIsEmpty(reason)) {
							reason = [TPCPreferences IRCopDefaultShunMessage];
							
							if ([reason contains:NSStringWhitespacePlaceholder]) {
								NSInteger spacePos = [reason stringPosition:NSStringWhitespacePlaceholder];
								
								reason = [reason safeSubstringAfterIndex:spacePos];
							}
						}
						
						[self send:cmd, peer, reason, nil];
					} else {
						NSString *time   = s.getToken.string;
						NSString *reason = s.string.trim;
						
						if (NSObjectIsEmpty(reason)) {
							reason = [TPCPreferences IRCopDefaultShunMessage];
							
							if ([reason contains:NSStringWhitespacePlaceholder]) {
								NSInteger spacePos = [reason stringPosition:NSStringWhitespacePlaceholder];
								
								if (NSObjectIsEmpty(time)) {
									time = [reason safeSubstringToIndex:spacePos];
								}
								
								reason = [reason safeSubstringAfterIndex:spacePos];
							}
						}
						
						[self send:cmd, peer, time, reason, nil];
					}
				}
			}
			
			return YES;
			break;
		}
		case 102: // Command: CAP
		case 103: // Command: CAPS
		{
			if (NSObjectIsNotEmpty(acceptedCaps)) {
				NSString *caps = [self.acceptedCaps componentsJoinedByString:@", "];
				
				[self printBoth:[self.world selectedChannelOn:self] type:TVCLogLineReplyType text:TXTFLS(@"IRCCapCurrentlyEnbaled", caps)];
			} else {
				[self printBoth:[self.world selectedChannelOn:self] type:TVCLogLineReplyType text:TXTLS(@"IRCCapCurrentlyEnabledNone")];
			}
			
			return YES;
			break;
		}
		case 104: // Command: CCBADGE
		{
			NSString *chan = s.getToken.string;
			
			if (NSObjectIsEmpty(chan)) {
				return NO;
			}
			
			NSInteger count = [s.getToken.string integerValue];
			
			IRCChannel *c = [self findChannel:chan];
			
			if (PointerIsNotEmpty(c)) {
				[c setTreeUnreadCount:count];
				
				NSString *hlt = s.getToken.string;
				
				if (NSObjectIsNotEmpty(hlt)) {
					if ([hlt isEqualToString:@"-h"]) {
						[c setIsKeyword:YES];
						
						[c setKeywordCount:1];
					}
				}
				
				[self.world reloadTree];
			}
			
			return YES;
			break;
		}
		default:
		{	
            NSString *command = [cmd lowercaseString];
			
            NSArray *extensions = [NSArray arrayWithObjects:@".scpt", @".py", @".pyc", @".rb", @".pl", @".sh", @".bash", @"", nil];
			NSArray *scriptPaths = [NSArray arrayWithObjects:
									
#ifdef TXUserScriptsFolderAvailable
									[TPCPreferences whereScriptsUnsupervisedPath],
#endif
									
									[TPCPreferences whereScriptsLocalPath],
									[TPCPreferences whereScriptsPath], nil];
			
            NSString *scriptPath = [NSString string];
            
            BOOL scriptFound = NO;
			
			for (NSString *path in scriptPaths) {
				if (scriptFound == YES) {
					break;
				}
				
				for (NSString *i in extensions) {
					NSString *filename = [NSString stringWithFormat:@"%@%@", command, i];
					
					scriptPath  = [path stringByAppendingPathComponent:filename];
					scriptFound = [_NSFileManager() fileExistsAtPath:scriptPath];
					
					if (scriptFound == YES) {
						break;
					}
				}
            }
			
			BOOL pluginFound = BOOLValueFromObject([self.world.bundlesForUserInput objectForKey:cmd]);
			
			if (pluginFound && scriptFound) {
				NSLog(TXTLS(@"PluginCommandClashErrorMessage") ,cmd);
			} else {
				if (pluginFound) {
					[self.invokeInBackgroundThread processBundlesUserMessage:
					 [NSArray arrayWithObjects:[NSString stringWithString:s.string], cmd, nil]];
					
					return YES;
				} else {
					if (scriptFound) {
                        NSDictionary *inputInfo = [NSDictionary dictionaryWithObjectsAndKeys:
												   c.name, @"channel",
												   scriptPath, @"path",
												   s.string, @"input",
                                                   NSNumberWithBOOL(completeTarget), @"completeTarget",
												   targetChannelName, @"target", nil];
                        
                        [self.invokeInBackgroundThread executeTextualCmdScript:inputInfo];
                        
                        return YES;
					}
				}
			}
			
			if (cutColon) {
                [s insertAttributedString:[NSAttributedString emptyStringWithBase:@":"] atIndex:0];
			}
			
			if ([s length]) {
                [s insertAttributedString:[NSAttributedString emptyStringWithBase:NSStringWhitespacePlaceholder] atIndex:0];
			}
			
            [s insertAttributedString:[NSAttributedString emptyStringWithBase:cmd] atIndex:0];
			
			[self sendLine:s.string];
			
			return YES;
			break;
		}
	}
	
	return NO;
}

- (void)sendLine:(NSString *)str
{
	[self.conn sendLine:str];
	
	if (self.rawModeEnabled) {
		NSLog(@" << %@", str);
	}
	
	self.world.messagesSent++;
	self.world.bandwidthOut += [str length];
}

- (void)send:(NSString *)str, ...
{
	NSMutableArray *ary = [NSMutableArray array];
	
	id obj;
	
	va_list args;
	va_start(args, str);
	
	while ((obj = va_arg(args, id))) {
		[ary safeAddObject:obj];
	}
	
	va_end(args);
	
	NSMutableString *s = [NSMutableString stringWithString:str];
	
	NSInteger count = ary.count;
	
	for (NSInteger i = 0; i < count; i++) {
		NSString *e = [ary safeObjectAtIndex:i];
		
		[s appendString:NSStringWhitespacePlaceholder];
		
		if (i == (count - 1) && (NSObjectIsEmpty(e) || [e hasPrefix:@":"] ||
								 [e contains:NSStringWhitespacePlaceholder])) {
			
			[s appendString:@":"];
		}
		
		[s appendString:e];
	}
	
	[self sendLine:s];
}

#pragma mark -
#pragma mark Find Channel

- (IRCChannel *)findChannel:(NSString *)name
{
	for (IRCChannel *c in self.channels) {
		if ([c.name isEqualNoCase:name]) {
			return c;
		}
	}
	
	return nil;
}

- (IRCChannel *)findChannelOrCreate:(NSString *)name
{
	IRCChannel *c = [self findChannel:name];
	
	if (PointerIsEmpty(c)) {
		return [self findChannelOrCreate:name useTalk:NO];
	}
	
	return c;
}

- (IRCChannel *)findChannelOrCreate:(NSString *)name useTalk:(BOOL)doTalk
{
	IRCChannel *c = [self findChannel:name];
	
	if (PointerIsEmpty(c)) {
		if (doTalk) {
			return [self.world createTalk:name client:self];
		} else {
			IRCChannelConfig *seed = [IRCChannelConfig new];
			
			seed.name = name;
			
			return [self.world createChannel:seed client:self reload:YES adjust:YES];
		}
	}
	
	return c;
}

- (NSInteger)indexOfTalkChannel
{
	NSInteger i = 0;
	
	for (IRCChannel *e in self.channels) {
		if (e.isTalk) return i;
		
		++i;
	}
	
	return -1;
}

#pragma mark -
#pragma mark Command Queue

- (void)processCommandsInCommandQueue
{
	CFAbsoluteTime now = CFAbsoluteTimeGetCurrent();
	
	while (self.commandQueue.count) {
		TLOTimerCommand *m = [self.commandQueue safeObjectAtIndex:0];
		
		if (m.time <= now) {
			NSString *target = nil;
			
			IRCChannel *c = [self.world findChannelByClientId:uid channelId:m.cid];
			
			if (c) {
				target = c.name;
			}
			
			[self sendCommand:m.input completeTarget:YES target:target];
			
			[self.commandQueue safeRemoveObjectAtIndex:0];
		} else {
			break;
		}
	}
	
	if (self.commandQueue.count) {
		TLOTimerCommand *m = [self.commandQueue safeObjectAtIndex:0];
		
		CFAbsoluteTime delta = (m.time - CFAbsoluteTimeGetCurrent());
		
		[self.commandQueueTimer start:delta];
	} else {
		[self.commandQueueTimer stop];
	}
}

- (void)addCommandToCommandQueue:(TLOTimerCommand *)m
{
	BOOL added = NO;
	
	NSInteger i = 0;
	
	for (TLOTimerCommand *c in self.commandQueue) {
		if (m.time < c.time) {
			added = YES;
			
			[self.commandQueue safeInsertObject:m atIndex:i];
			
			break;
		}
		
		++i;
	}
	
	if (added == NO) {
		[self.commandQueue safeAddObject:m];
	}
	
	if (i == 0) {
		[self processCommandsInCommandQueue];
	}
}

- (void)clearCommandQueue
{
	[self.commandQueueTimer stop];
	[self.commandQueue removeAllObjects];
}

- (void)onCommandQueueTimer:(id)sender
{
	[self processCommandsInCommandQueue];
}

#pragma mark -
#pragma mark Window Title

- (void)updateClientTitle
{
	[self.world updateClientTitle:self];
}

- (void)updateChannelTitle:(IRCChannel *)c
{
	[self.world updateChannelTitle:c];
}

#pragma mark -
#pragma mark Growl

- (BOOL)notifyText:(TXNotificationType)type lineType:(TVCLogLineType)ltype target:(id)target nick:(NSString *)nick text:(NSString *)text
{
	if ([self.myNick isEqual:nick]) {
		return NO;
	}
	
	if ([self outputRuleMatchedInMessage:text inChannel:target withLineType:ltype] == YES) {
		return NO;
	}
	
	IRCChannel *channel = nil;
	
	NSString *chname = nil;
	
	if (target) {
		if ([target isKindOfClass:[IRCChannel class]]) {
			channel = (IRCChannel *)target;
			chname = channel.name;
			
			if (type == TXNotificationHighlightType) {
				if (channel.config.ignoreHighlights) {
					return YES;
				}
			} else if (channel.config.growl == NO) {
				return YES;
			}
		} else {
			chname = (NSString *)target;
		}
	}
	
	if (NSObjectIsEmpty(chname)) {
		chname = self.name;
	}
    
	[TLOSoundPlayer play:[TPCPreferences soundForEvent:type] isMuted:self.world.soundMuted];
	
	if ([TPCPreferences growlEnabledForEvent:type] == NO) return YES;
	if ([TPCPreferences stopGrowlOnActive] && [self.world.window isOnCurrentWorkspace]) return YES;
	if ([TPCPreferences disableWhileAwayForEvent:type] == YES && self.isAway == YES) return YES;
	
	NSDictionary *info = nil;
	
	NSString *title = chname;
	NSString *desc;
	
	if (ltype == TVCLogLineActionType || ltype == TVCLogLineActionNoHighlightType) {
		desc = [NSString stringWithFormat:@"• %@: %@", nick, text];
	} else {
		desc = [NSString stringWithFormat:@"<%@> %@", nick, text];
	}
	
	if (channel) {
		info = [NSDictionary dictionaryWithObjectsAndKeys:[NSNumber numberWithInteger:self.uid], @"client", [NSNumber numberWithInteger:channel.uid], @"channel", nil];
	} else {
		info = [NSDictionary dictionaryWithObjectsAndKeys:[NSNumber numberWithInteger:self.uid], @"client", nil];
	}
	
	[self.world notifyOnGrowl:type title:title desc:desc userInfo:info];
	
	return YES;
}

- (BOOL)notifyEvent:(TXNotificationType)type lineType:(TVCLogLineType)ltype
{
	return [self notifyEvent:type lineType:ltype target:nil nick:NSStringEmptyPlaceholder text:NSStringEmptyPlaceholder];
}

- (BOOL)notifyEvent:(TXNotificationType)type lineType:(TVCLogLineType)ltype target:(id)target nick:(NSString *)nick text:(NSString *)text
{
	if ([self outputRuleMatchedInMessage:text inChannel:target withLineType:ltype] == YES) {
		return NO;
	}
	
	[TLOSoundPlayer play:[TPCPreferences soundForEvent:type] isMuted:self.world.soundMuted];
	
	if ([TPCPreferences growlEnabledForEvent:type] == NO) return YES;
	if ([TPCPreferences stopGrowlOnActive] && [self.world.window isOnCurrentWorkspace]) return YES;
	if ([TPCPreferences disableWhileAwayForEvent:type] == YES && self.isAway == YES) return YES;
	
	IRCChannel *channel = nil;
	
	if (target) {
		if ([target isKindOfClass:[IRCChannel class]]) {
			channel = (IRCChannel *)target;
			
			if (channel.config.growl == NO) {
				return YES;
			}
		}
	}
	
	NSString *title = NSStringEmptyPlaceholder;
	NSString *desc  = NSStringEmptyPlaceholder;
	
	switch (type) {
		case TXNotificationConnectType:				title = self.name; break;
		case TXNotificationDisconnectType:			title = self.name; break;
		case TXNotificationAddressBookMatchType:	desc = text; break;
		case TXNotificationKickType:
		{
			title = channel.name;
			
			desc = TXTFLS(@"NotificationKickedMessageDescription", nick, text);
			
			break;
		}
		case TXNotificationInviteType:
		{
			title = self.name;
			
			desc = TXTFLS(@"NotificationInvitedMessageDescriptioni", nick, text);
			
			break;
		}
		default: return YES;
	}
	
	NSDictionary *info = nil;
	
	if (channel) {
		info = [NSDictionary dictionaryWithObjectsAndKeys:[NSNumber numberWithInteger:self.uid], @"client", [NSNumber numberWithInteger:channel.uid], @"channel", nil];
	} else {
		info = [NSDictionary dictionaryWithObjectsAndKeys:[NSNumber numberWithInteger:self.uid], @"client", nil];
	}
	
	[self.world notifyOnGrowl:type title:title desc:desc userInfo:info];
	
	return YES;
}

#pragma mark -
#pragma mark Channel States

- (void)setKeywordState:(id)t
{
	BOOL isActiveWindow = [self.world.window isOnCurrentWorkspace];
	
	if ([t isKindOfClass:[IRCChannel class]]) {
		if ([t isChannel] == YES || [t isTalk] == YES) {
			if (NSDissimilarObjects(self.world.selected, t) || isActiveWindow == NO) {
				[t setKeywordCount:([t keywordCount] + 1)];
				
				[self.world updateIcon];
			}
		}
	}
	
	if ([t isUnread] || (isActiveWindow && self.world.selected == t)) {
		return;
	}
	
	[t setIsKeyword:YES];
	
	[self reloadTree];
	
	if (isActiveWindow == NO) {
		[NSApp requestUserAttention:NSInformationalRequest];
	}
}

- (void)setNewTalkState:(id)t
{
	BOOL isActiveWindow = [self.world.window isOnCurrentWorkspace];
	
	if ([t isUnread] || (isActiveWindow && self.world.selected == t)) {
		return;
	}
	
	[t setIsNewTalk:YES];
	
	[self reloadTree];
	
	if (isActiveWindow == NO) {
		[NSApp requestUserAttention:NSInformationalRequest];
	}
	
	[self.world updateIcon];
}

- (void)setUnreadState:(id)t
{
	BOOL isActiveWindow = [self.world.window isOnCurrentWorkspace];
	
	if ([t isKindOfClass:[IRCChannel class]]) {
		if ([TPCPreferences countPublicMessagesInIconBadge] == NO) {
			if ([t isTalk] == YES && [t isClient] == NO) {
				if (NSDissimilarObjects(self.world.selected, t) || isActiveWindow == NO) {
					[t setDockUnreadCount:([t dockUnreadCount] + 1)];
					
					[self.world updateIcon];
				}
			}
		} else {
			if (NSDissimilarObjects(self.world.selected, t) || isActiveWindow == NO) {
				[t setDockUnreadCount:([t dockUnreadCount] + 1)];
				
				[self.world updateIcon];
			}	
		}
	}
	
    if (isActiveWindow == NO || (NSDissimilarObjects(self.world.selected, t) && isActiveWindow)) {
		[t setTreeUnreadCount:([t treeUnreadCount] + 1)];
	}
	
	if (isActiveWindow && self.world.selected == t) {
		return;
	} else {
		[t setIsUnread:YES];
		
		[self reloadTree];
	}
}

#pragma mark -
#pragma mark Print

- (BOOL)printBoth:(id)chan type:(TVCLogLineType)type text:(NSString *)text
{
	return [self printBoth:chan type:type nick:nil text:text identified:NO];
}

- (BOOL)printBoth:(id)chan type:(TVCLogLineType)type text:(NSString *)text receivedAt:(NSDate *)receivedAt
{
	return [self printBoth:chan type:type nick:nil text:text identified:NO receivedAt:receivedAt];
}

- (BOOL)printBoth:(id)chan type:(TVCLogLineType)type nick:(NSString *)nick text:(NSString *)text identified:(BOOL)identified
{
	return [self printBoth:chan type:type nick:nick text:text identified:identified receivedAt:[NSDate date]];
}

- (BOOL)printBoth:(id)chan type:(TVCLogLineType)type nick:(NSString *)nick text:(NSString *)text identified:(BOOL)identified receivedAt:(NSDate *)receivedAt
{
	return [self printChannel:chan type:type nick:nick text:text identified:identified receivedAt:receivedAt];
}

- (NSString *)formatNick:(NSString *)nick channel:(IRCChannel *)channel
{
	NSString *format = [TPCPreferences themeNickFormat];

	if (NSObjectIsNotEmpty(self.world.viewTheme.other.nicknameFormat)) {
		format = self.world.viewTheme.other.nicknameFormat;
	}
	
	if (NSObjectIsEmpty(format)) {
		format = TXLogLineUndefinedNicknameFormat;
	}
    
    if ([format contains:@"%n"]) {
        format = [format stringByReplacingOccurrencesOfString:@"%n" withString:nick];
    }
	
	if ([format contains:@"%@"]) {
		if (channel && channel.isClient == NO && channel.isChannel) {
			IRCUser *m = [channel findMember:nick];
			
			if (m) {
				NSString *mark = [NSString stringWithChar:m.mark];
				
				if ([mark isEqualToString:NSStringWhitespacePlaceholder] || NSObjectIsEmpty(mark)) {
					format = [format stringByReplacingOccurrencesOfString:@"%@" withString:NSStringEmptyPlaceholder];
				} else {
					format = [format stringByReplacingOccurrencesOfString:@"%@" withString:mark];
				}
			} else {
				format = [format stringByReplacingOccurrencesOfString:@"%@" withString:NSStringEmptyPlaceholder];	
			}
		} else {
			format = [format stringByReplacingOccurrencesOfString:@"%@" withString:NSStringEmptyPlaceholder];	
		}
	}
	
	return format;
}

- (BOOL)printChannel:(id)chan type:(TVCLogLineType)type nick:(NSString *)nick text:(NSString *)text identified:(BOOL)identified
{
	return [self printChannel:chan type:type nick:nil text:text identified:identified receivedAt:[NSDate date]];
}

- (BOOL)printChannel:(id)chan type:(TVCLogLineType)type text:(NSString *)text receivedAt:(NSDate *)receivedAt
{
	return [self printChannel:chan type:type nick:nil text:text identified:NO receivedAt:receivedAt];
}

- (BOOL)printAndLog:(TVCLogLine *)line withHTML:(BOOL)rawHTML
{
	BOOL result = [self.log print:line withHTML:rawHTML];
	
	if (self.isConnected == NO) return NO;
	
	if ([TPCPreferences logTranscript]) {
		if (PointerIsEmpty(self.logFile)) {
			self.logFile = [TLOFileLogger new];
			self.logFile.client = self;
		}
		
		NSString *comp = [NSString stringWithFormat:@"%@", [[NSDate date] dateWithCalendarFormat:@"%Y%m%d%H%M%S" timeZone:nil]];
		
		if (self.logDate) {
			if ([self.logDate isEqualToString:comp] == NO) {
				self.logDate = comp;
				
				[self.logFile reopenIfNeeded];
			}
		} else {
			self.logDate = comp;
		}
		
		NSString *nickStr = NSStringEmptyPlaceholder;
		
		if (line.nick) {
			nickStr = [NSString stringWithFormat:@"%@: ", line.nickInfo];
		}
		
		NSString *s = [NSString stringWithFormat:@"%@%@%@", line.time, nickStr, line.body];
		
		[self.logFile writeLine:s];
	}
	
	return result;
}

- (BOOL)printRawHTMLToCurrentChannel:(NSString *)text receivedAt:(NSDate *)receivedAt
{
	return [self printRawHTMLToCurrentChannel:text withTimestamp:YES receivedAt:receivedAt];
}

- (BOOL)printRawHTMLToCurrentChannelWithoutTime:(NSString *)text receivedAt:(NSDate *)receivedAt
{
	return [self printRawHTMLToCurrentChannel:text withTimestamp:NO receivedAt:receivedAt];
}

- (BOOL)printRawHTMLToCurrentChannel:(NSString *)text withTimestamp:(BOOL)showTime receivedAt:(NSDate *)receivedAt
{
	TVCLogLine *c = [TVCLogLine new];
	
	IRCChannel *channel = [self.world selectedChannelOn:self];
	
	c.body       = text;
	c.lineType   = TVCLogLineReplyType;
	c.memberType = TVCLogMemberNormalType;
	
	if (showTime) {
		NSString *time = TXFormattedTimestampWithOverride(receivedAt, [TPCPreferences themeTimestampFormat], self.world.viewTheme.other.timestampFormat);
		
		if (NSObjectIsNotEmpty(time)) {
			time = [time stringByAppendingString:NSStringWhitespacePlaceholder];
		}
		
		c.time = time;
	}
	
	if (channel) {
		return [channel print:c withHTML:YES];
	} else {
		return [self.log print:c withHTML:YES];
	}
}

- (BOOL)printChannel:(id)chan type:(TVCLogLineType)type nick:(NSString *)nick text:(NSString *)text identified:(BOOL)identified receivedAt:(NSDate *)receivedAt
{
	if ([self outputRuleMatchedInMessage:text inChannel:chan withLineType:type] == YES) {
		return NO;
	}
	
	NSString *nickStr = nil;
	NSString *time    = TXFormattedTimestampWithOverride(receivedAt,
														 [TPCPreferences themeTimestampFormat],
														 self.world.viewTheme.other.timestampFormat);
	
	IRCChannel *channel = nil;
    
	TVCLogMemberType memberType = TVCLogMemberNormalType;
	
	NSInteger colorNumber = 0;
	
	NSArray *keywords     = nil;
	NSArray *excludeWords = nil;
    
	TVCLogLine *c = [TVCLogLine new];
	
	if (nick && [nick isEqualToString:self.myNick]) {
		memberType = TVCLogMemberLocalUserType;
	}
	
	if ([chan isKindOfClass:[IRCChannel class]]) {
		channel = chan;
	} else if ([chan isKindOfClass:[NSString class]]) {
        if (NSObjectIsNotEmpty(chan)) {
            return NO;
        }
	}
	
	if (type == TVCLogLinePrivateMessageType || type == TVCLogLineActionType) {
		if (NSDissimilarObjects(memberType, TVCLogMemberLocalUserType)) {
			if (channel && channel.config.ignoreHighlights == NO) {
				keywords     = [TPCPreferences keywords];
				excludeWords = [TPCPreferences excludeWords];
				
				if (NSDissimilarObjects([TPCPreferences keywordMatchingMethod],
										TXNicknameHighlightRegularExpressionMatchType)) {
					
                    if ([TPCPreferences keywordCurrentNick]) {
                        NSMutableArray *ary = [keywords mutableCopy];
                        
                        [ary safeInsertObject:self.myNick atIndex:0];
                        
                        keywords = ary;
                    }
                }
			}
		}
	}
	
	if (type == TVCLogLineActionNoHighlightType) {
		type = TVCLogLineActionType;
	} else if (type == TVCLogLinePrivateMessageNoHighlightType) {
		type = TVCLogLinePrivateMessageType;
	}
	
	if (NSObjectIsNotEmpty(time)) {
		time = [time stringByAppendingString:NSStringWhitespacePlaceholder];
	}
	
	if (NSObjectIsNotEmpty(nick)) {
		if (type == TVCLogLineActionType) {
			nickStr = [NSString stringWithFormat:TXLogLineActionNicknameFormat, nick];
		} else if (type == TVCLogLineNoticeType) {
			nickStr = [NSString stringWithFormat:TXLogLineNoticeNicknameFormat, nick];
		} else {
			nickStr = [self formatNick:nick channel:channel];
		}
	}
	
	if (nick && channel && (type == TVCLogLinePrivateMessageType || type == TVCLogLineActionType)) {
		IRCUser *user = [channel findMember:nick];
		
		if (user) {
			colorNumber = user.colorNumber;
		}
	}
	
	c.time = time;
	c.nick = nickStr;
	c.body = text;
	
	c.lineType			= type;
	c.memberType		= memberType;
	c.nickInfo			= nick;
	c.identified		= identified;
	c.nickColorNumber	= colorNumber;
	
	c.keywords		= keywords;
	c.excludeWords	= excludeWords;
	
	if (channel) {
		if ([TPCPreferences autoAddScrollbackMark]) {
			if (NSDissimilarObjects(channel, self.world.selectedChannel) || [self.world.window isOnCurrentWorkspace] == NO) {
				if (channel.isUnread == NO) {
					if (type == TVCLogLinePrivateMessageType || type == TVCLogLineActionType || type == TVCLogLineNoticeType) {
						[channel.log unmark];
						[channel.log mark];
					}
				}
			}
		}
		
		return [channel print:c];
	} else {
		if ([TPCPreferences logTranscript]) {
			return [self printAndLog:c withHTML:NO];
		} else {
			return [self.log print:c];
		}
	}
}

- (void)printSystem:(id)channel text:(NSString *)text
{
	[self printChannel:channel type:TVCLogLineSystemType text:text receivedAt:[NSDate date]];
}

- (void)printSystem:(id)channel text:(NSString *)text receivedAt:(NSDate *)receivedAt
{
	[self printChannel:channel type:TVCLogLineSystemType text:text receivedAt:receivedAt];
}

- (void)printSystemBoth:(id)channel text:(NSString *)text 
{
	[self printSystemBoth:channel text:text receivedAt:[NSDate date]];
}

- (void)printSystemBoth:(id)channel text:(NSString *)text receivedAt:(NSDate *)receivedAt
{
	[self printBoth:channel type:TVCLogLineSystemType text:text receivedAt:receivedAt];
}

- (void)printReply:(IRCMessage *)m
{
	[self printBoth:nil type:TVCLogLineReplyType text:[m sequence:1] receivedAt:m.receivedAt];
}

- (void)printUnknownReply:(IRCMessage *)m
{
	[self printBoth:nil type:TVCLogLineReplyType text:[m sequence:1] receivedAt:m.receivedAt];
}

- (void)printDebugInformation:(NSString *)m
{
	[self printDebugInformation:m channel:[self.world selectedChannelOn:self]];
}

- (void)printDebugInformationToConsole:(NSString *)m
{
	[self printDebugInformation:m channel:nil];
}

- (void)printDebugInformation:(NSString *)m channel:(IRCChannel *)channel
{
	[self printBoth:channel type:TVCLogLineDebugType text:m];
}

- (void)printErrorReply:(IRCMessage *)m
{
	[self printErrorReply:m channel:nil];
}

- (void)printErrorReply:(IRCMessage *)m channel:(IRCChannel *)channel
{
	NSString *text = TXTFLS(@"IRCHadRawError", m.numericReply, [m sequence]);
	
	[self printBoth:channel type:TVCLogLineErrorReplyType text:text receivedAt:m.receivedAt];
}

- (void)printError:(NSString *)error
{
	[self printBoth:nil type:TVCLogLineErrorType text:error];
}

#pragma mark -
#pragma mark IRCTreeItem

- (BOOL)isClient
{
	return YES;
}

- (BOOL)isActive
{
	return self.isLoggedIn;
}

- (IRCClient *)client
{
	return self;
}

- (NSInteger)numberOfChildren
{
	return self.channels.count;
}

- (id)childAtIndex:(NSInteger)index
{
	return [self.channels safeObjectAtIndex:index];
}

- (NSString *)label
{
	return self.config.name;
}

#pragma mark -
#pragma mark Protocol Handlers

- (void)receivePrivmsgAndNotice:(IRCMessage *)m
{
	NSString *text = [m paramAt:1];
	
	BOOL identified = NO;
	
	if (self.identifyCTCP && ([text hasPrefix:@"+\x01"] || [text hasPrefix:@"-\x01"])) {
		identified = [text hasPrefix:@"+"];
		
		text = [text safeSubstringFromIndex:1];
	} else if (self.identifyMsg && ([text hasPrefix:@"+"] || [text hasPrefix:@"-"])) {
		identified = [text hasPrefix:@"+"];
		
		text = [text safeSubstringFromIndex:1];
	}
	
	if ([text hasPrefix:@"\x01"]) {
		text = [text safeSubstringFromIndex:1];
		
		NSInteger n = [text stringPosition:@"\x01"];
		
		if (n >= 0) {
			text = [text safeSubstringToIndex:n];
		}
		
		if ([m.command isEqualToString:IRCCommandIndexPrivmsg]) {
			if ([[text uppercaseString] hasPrefix:@"ACTION "]) {
				text = [text safeSubstringFromIndex:7];
				
				[self receiveText:m command:IRCCommandIndexAction text:text identified:identified];
			} else {
				[self receiveCTCPQuery:m text:text];
			}
		} else {
			[self receiveCTCPReply:m text:text];
		}
	} else {
		[self receiveText:m command:m.command text:text identified:identified];
	}
}

- (void)receiveText:(IRCMessage *)m command:(NSString *)cmd text:(NSString *)text identified:(BOOL)identified
{
	NSString *anick  = m.sender.nick;
	NSString *target = [m paramAt:0];
	
	TVCLogLineType type = TVCLogLinePrivateMessageType;
	
	if ([cmd isEqualToString:IRCCommandIndexNotice]) {
		type = TVCLogLineNoticeType;
	} else if ([cmd isEqualToString:IRCCommandIndexAction]) {
		type = TVCLogLineActionType;
	}
	
	if ([target hasPrefix:@"@"]) {
		target = [target safeSubstringFromIndex:1];
	}
	
	IRCAddressBook *ignoreChecks = [self checkIgnoreAgainstHostmask:m.sender.raw 
														withMatches:[NSArray arrayWithObjects:
																	 @"ignoreHighlights",
																	 @"ignorePMHighlights",
																	 @"ignoreNotices", 
																	 @"ignorePublicMsg", 
																	 @"ignorePrivateMsg", nil]];
	
	
	if ([target isChannelName]) {
		if ([ignoreChecks ignoreHighlights] == YES) {
			if (type == TVCLogLineActionType) {
				type = TVCLogLineActionNoHighlightType;
			} else if (type == TVCLogLinePrivateMessageType) {
				type = TVCLogLinePrivateMessageNoHighlightType;
			}
		}
		
		if (type == TVCLogLineNoticeType) {
			if ([ignoreChecks ignoreNotices] == YES) {
				return;
			}
		} else {
			if ([ignoreChecks ignorePublicMsg] == YES) {
				return;
			}
		}
		
		IRCChannel *c = [self findChannel:target];
		
		if (PointerIsEmpty(c)) {
			return;
		}
		
		[self decryptIncomingMessage:&text channel:c];
		
		if (type == TVCLogLineNoticeType) {     
			[self printBoth:c type:type nick:anick text:text identified:identified receivedAt:m.receivedAt];
			
			[self notifyText:TXNotificationChannelNoticeType lineType:type target:c nick:anick text:text];
		} else {
			BOOL highlight = [self printBoth:c type:type nick:anick text:text identified:identified receivedAt:m.receivedAt];
			BOOL postevent = NO;
			
			if (highlight) {
				postevent = [self notifyText:TXNotificationHighlightType lineType:type target:c nick:anick text:text];
				
				if (postevent) {
					[self setKeywordState:c];
				}
			} else {
				postevent = [self notifyText:TXNotificationChannelMessageType lineType:type target:c nick:anick text:text];
			}
			
			if (postevent && (highlight || c.config.growl)) {
				[self setUnreadState:c];
			}
			
			if (c) {
				IRCUser *sender = [c findMember:anick];
				
				if (sender) {
					NSString *trimmedMyNick = [self.myNick stringByTrimmingCharactersInSet:[NSCharacterSet characterSetWithCharactersInString:@"_"]];
					
					if ([text stringPositionIgnoringCase:trimmedMyNick] >= 0) {
						[sender outgoingConversation];
					} else {
						[sender conversation];
					}
				}
			}
		}
	} else {
		BOOL targetOurself = [target isEqualNoCase:self.myNick];
		
		if ([ignoreChecks ignorePMHighlights] == YES) {
			if (type == TVCLogLineActionType) {
				type = TVCLogLineActionNoHighlightType;
			} else if (type == TVCLogLinePrivateMessageType) {
				type = TVCLogLinePrivateMessageNoHighlightType;
			}
		}
		
		if (targetOurself && [ignoreChecks ignorePrivateMsg]) {
			return;
		}
		
		if (NSObjectIsEmpty(anick)) {
			[self printBoth:nil type:type text:text receivedAt:m.receivedAt];
		} else if ([anick isNickname] == NO) {
			if (type == TVCLogLineNoticeType) {
				if (self.hasIRCopAccess) {
					if ([text hasPrefix:@"*** Notice -- Client connecting"] || 
						[text hasPrefix:@"*** Notice -- Client exiting"] || 
						[text hasPrefix:@"*** You are connected to"] || 
						[text hasPrefix:@"Forbidding Q-lined nick"] || 
						[text hasPrefix:@"Exiting ssl client"]) {
						
						[self printBoth:nil type:type text:text receivedAt:m.receivedAt];
						
						BOOL processData = NO;
						
						NSInteger match_math = 0;
						
						if ([text hasPrefix:@"*** Notice -- Client connecting at"]) {
							processData = YES;
						} else if ([text hasPrefix:@"*** Notice -- Client connecting on port"]) {
							processData = YES;
							
							match_math = 1;
						}
						
						if (processData) {	
							NSString *host = nil;
							NSString *snick = nil;
							
							NSArray *chunks = [text componentsSeparatedByCharactersInSet:[NSCharacterSet whitespaceCharacterSet]];
							
							host  = [chunks safeObjectAtIndex:(8 + match_math)];
							snick = [chunks safeObjectAtIndex:(7 + match_math)];
							
							host = [host safeSubstringFromIndex:1];
							host = [host safeSubstringToIndex:(host.length - 1)];
							
							ignoreChecks = [self checkIgnoreAgainstHostmask:[snick stringByAppendingFormat:@"!%@", host]
																withMatches:[NSArray arrayWithObjects:@"notifyJoins", nil]];
							
							[self handleUserTrackingNotification:ignoreChecks 
														nickname:snick 
														hostmask:host
														langitem:@"UserTrackingHostmaskConnected"];
						}
					} else {
						if ([TPCPreferences handleServerNotices]) {
                            [self printBoth:[world selectedChannelOn:self] type:type text:text];
						} else {
                            [self printBoth:nil type:type text:text receivedAt:m.receivedAt];
                        }
					}
				} else {
					[self printBoth:nil type:type text:text receivedAt:m.receivedAt];
				}
			} else {
				[self printBoth:nil type:type text:text receivedAt:m.receivedAt];
			}
		} else {
			IRCChannel *c;
			
			if (targetOurself) {
				c = [self findChannel:anick];
			} else {
				c = [self findChannel:target];
			}
			
			[self decryptIncomingMessage:&text channel:c];
			
			BOOL newTalk = NO;
			
			if (PointerIsEmpty(c) && NSDissimilarObjects(type, TVCLogLineNoticeType)) {
				if (targetOurself) {
					c = [self.world createTalk:anick client:self];
				} else {
					c = [self.world createTalk:target client:self];
				}
				
				newTalk = YES;
			}
			
			if (type == TVCLogLineNoticeType) {
				if ([ignoreChecks ignoreNotices] == YES) {
					return;
				}
				
				if ([TPCPreferences locationToSendNotices] == TXNoticeSendCurrentChannelType) {
					c = [self.world selectedChannelOn:self];
				}
				
				[self printBoth:c type:type nick:anick text:text identified:identified receivedAt:m.receivedAt];
				
				if ([anick isEqualNoCase:@"NickServ"]) {
					if ([text hasPrefix:@"This nickname is registered"]) {
						if (NSObjectIsNotEmpty(self.config.nickPassword) && self.isIdentifiedWithSASL == NO) {
							self.serverHasNickServ = YES;
							
							[self send:IRCCommandIndexPrivmsg, @"NickServ",
							 [NSString stringWithFormat:@"IDENTIFY %@", self.config.nickPassword], nil];
						}
					} else if ([text hasPrefix:@"This nick is owned by someone else"]) {
						if ([self.config.server hasSuffix:@"dal.net"]) {
							if (NSObjectIsNotEmpty(self.config.nickPassword)) {
								self.serverHasNickServ = YES;
								
								[self send:IRCCommandIndexPrivmsg, @"NickServ@services.dal.net", [NSString stringWithFormat:@"IDENTIFY %@", self.config.nickPassword], nil];
							}
						}
					} else {
						if ([TPCPreferences autojoinWaitForNickServ]) {
							if ([text hasPrefix:@"You are now identified"] ||
								[text hasPrefix:@"You are already identified"] ||
								[text hasSuffix:@"you are now recognized."] ||
								[text hasPrefix:@"Password accepted for"]) {
								
								if (self.autojoinInitialized == NO && self.serverHasNickServ) {
									self.autojoinInitialized = YES;
									
									[self performAutoJoin];
								}
							}
						} else {
							self.autojoinInitialized = YES;
						}
					}
				}
				
				if (targetOurself) {
					[self setUnreadState:c];
					
					[self notifyText:TXNotificationQueryNoticeType lineType:type target:c nick:anick text:text];
				}
			} else {
				BOOL highlight = [self printBoth:c type:type nick:anick text:text identified:identified receivedAt:m.receivedAt];
				BOOL postevent = NO;
				
				if (highlight) {
					postevent = [self notifyText:TXNotificationHighlightType lineType:type target:c nick:anick text:text];
					
					if (postevent) {
						[self setKeywordState:c];
					}
				} else if (targetOurself) {
					if (newTalk) {
						postevent = [self notifyText:TXNotificationNewQueryType lineType:type target:c nick:anick text:text];
						
						if (postevent) {
							[self setNewTalkState:c];
						}
					} else {
						postevent = [self notifyText:TXNotificationQueryMessageType lineType:type target:c nick:anick text:text];
					}
				}
				
				if (postevent) {
					[self setUnreadState:c];
				}
				
				NSString *hostTopic = m.sender.raw;
				
				if ([hostTopic isEqualNoCase:c.topic] == NO) {
					[c		setTopic:hostTopic];
					[c.log	setTopic:hostTopic];
				}
			}
		}
	}
}

- (void)receiveCTCPQuery:(IRCMessage *)m text:(NSString *)text
{
	NSString *nick = m.sender.nick;
	
	NSMutableString *s = text.mutableCopy;
	
	NSString *command = s.getToken.uppercaseString;
	
	if ([TPCPreferences replyToCTCPRequests] == NO) {
		[self printDebugInformationToConsole:TXTFLS(@"IRCCTCPRequestIgnored", command, nick)];
		
		return;
	}
	
	IRCAddressBook *ignoreChecks = [self checkIgnoreAgainstHostmask:m.sender.raw 
														withMatches:[NSArray arrayWithObjects:@"ignoreCTCP", nil]];
	
	if ([ignoreChecks ignoreCTCP] == YES) {
		return;
	}
	
	if ([command isEqualToString:IRCCommandIndexDcc]) {
		[self printDebugInformationToConsole:TXTLS(@"DCCRequestErrorMessage")];
	} else {
		IRCChannel *target = nil;
		
		if ([TPCPreferences locationToSendNotices] == TXNoticeSendCurrentChannelType) {
			target = [self.world selectedChannelOn:self];
		}
		
		NSString *text = TXTFLS(@"IRCRecievedCTCPRequest", command, nick);
		
		if ([command isEqualToString:IRCCommandIndexLagcheck] == NO) {
			[self printBoth:target type:TVCLogLineCTCPType text:text receivedAt:m.receivedAt];
		}
		
		if ([command isEqualToString:IRCCommandIndexPing]) {
			[self sendCTCPReply:nick command:command text:s];
		} else if ([command isEqualToString:IRCCommandIndexTime]) {
			[self sendCTCPReply:nick command:command text:[[NSDate date] descriptionWithLocale:[NSLocale currentLocale]]];
		} else if ([command isEqualToString:IRCCommandIndexVersion]) {
			NSString *fakever = [TPCPreferences masqueradeCTCPVersion];
			
			if (NSObjectIsNotEmpty(fakever)) {
				[self sendCTCPReply:nick command:command text:fakever];
			} else {
				NSString *ref  = [TPCPreferences gitBuildReference];
				NSString *name = [TPCPreferences applicationName];
				NSString *vers = [[TPCPreferences textualInfoPlist] objectForKey:@"CFBundleVersion"];
				
				NSString *text = [NSString stringWithFormat:TXTLS(@"IRCCTCPVersionInfo"), name, vers, ((NSObjectIsEmpty(ref)) ? TXTLS(@"Unknown") : ref)];
				
				[self sendCTCPReply:nick command:command text:text];
			}
		} else if ([command isEqualToString:IRCCommandIndexUserinfo]) {
			[self sendCTCPReply:nick command:command text:NSStringEmptyPlaceholder];
		} else if ([command isEqualToString:IRCCommandIndexClientinfo]) {
			[self sendCTCPReply:nick command:command text:TXTLS(@"IRCCTCPSupportedReplies")];
		} else if ([command isEqualToString:IRCCommandIndexLagcheck]) {
			if (self.lastLagCheck == 0) {
				[self printDebugInformationToConsole:TXTFLS(@"IRCCTCPRequestIgnored", command, nick)];
			}
			
			TXNSDouble time = CFAbsoluteTimeGetCurrent();
			
			if (time >= self.lastLagCheck) {
				TXNSDouble delta = (time - self.lastLagCheck);
				
				text = TXTFLS(@"LagCheckRequestReplyMessage", self.config.server, delta);
			} else {
				text = TXTLS(@"LagCheckRequestUnknownReply");
			}
			
			if (self.sendLagcheckToChannel) {
				[self sendPrivmsgToSelectedChannel:text];
				
				self.sendLagcheckToChannel = NO;
			} else {
				[self printDebugInformation:text];
			}
			
			self.lastLagCheck = 0;
		}
	}
}

- (void)receiveCTCPReply:(IRCMessage *)m text:(NSString *)text
{
	NSString *nick = m.sender.nick;
	
	NSMutableString *s = text.mutableCopy;
	
	NSString *command = s.getToken.uppercaseString;
	
	IRCAddressBook *ignoreChecks = [self checkIgnoreAgainstHostmask:m.sender.raw 
														withMatches:[NSArray arrayWithObjects:@"ignoreCTCP", nil]];
	
	if ([ignoreChecks ignoreCTCP] == YES) {
		return;
	}
	
	IRCChannel *c = nil;
	
	if ([TPCPreferences locationToSendNotices] == TXNoticeSendCurrentChannelType) {
		c = [self.world selectedChannelOn:self];
	}
	
	if ([command isEqualToString:IRCCommandIndexPing]) {
		uint64_t delta = (mach_absolute_time() - [s longLongValue]);
		
		mach_timebase_info_data_t info;
		mach_timebase_info(&info);
		
		TXNSDouble nano = (1e-9 * ((TXNSDouble)info.numer / (TXNSDouble)info.denom));
		TXNSDouble seconds = ((TXNSDouble)delta * nano);
		
		text = TXTFLS(@"IRCRecievedCTCPPingReply", nick, command, seconds);
	} else {
		text = TXTFLS(@"IRCRecievedCTCPReply", nick, command, s);
	}
	
	[self printBoth:c type:TVCLogLineCTCPType text:text receivedAt:m.receivedAt];
}

- (void)requestUserHosts:(IRCChannel *)c 
{
	if ([c.name isChannelName]) {
		[c setIsModeInit:YES];
		
		[self send:IRCCommandIndexMode, c.name, nil];
		
		if (self.userhostInNames == NO) {
			// We can skip requesting WHO, we already have this information.
			
			[self send:IRCCommandIndexWho, c.name, nil, nil];
		}
	}
}

- (void)receiveJoin:(IRCMessage *)m
{
	NSString *nick   = m.sender.nick;
	NSString *chname = [m paramAt:0];
	
	BOOL njoin  = NO;
	BOOL myself = [nick isEqualNoCase:self.myNick];
	
	if ([chname hasSuffix:@"\x07o"]) {
		njoin  = YES;
		
		chname = [chname safeSubstringToIndex:(chname.length - 2)];
	}
	
	IRCChannel *c = [self findChannelOrCreate:chname];
	
	if (myself) {
		[c activate];
		
		[self reloadTree];
		
		self.myHost = m.sender.raw;
		
		if (self.autojoinInitialized == NO && [self.autoJoinTimer isActive] == NO) {
			[self.world select:c];
            [self.world.serverList expandItem:c];
		}
		
		if (NSObjectIsNotEmpty(c.config.encryptionKey)) {
			[c.client printDebugInformation:TXTLS(@"BlowfishEncryptionStarted") channel:c];
		}
	}
	
	if (PointerIsEmpty([c findMember:nick])) {
		IRCUser *u = [IRCUser new];
		
		u.o           = njoin;
		u.nick        = nick;
		u.username    = m.sender.user;
		u.address	  = m.sender.address;
		u.supportInfo = self.isupport;
		
		[c addMember:u];
	}
	
    IRCAddressBook *ignoreChecks = [self checkIgnoreAgainstHostmask:m.sender.raw 
														withMatches:[NSArray arrayWithObjects:@"ignoreJPQE", @"notifyJoins", nil]];
    
    if ([ignoreChecks ignoreJPQE] == YES && myself == NO) {
        return;
    }
    
    if (self.hasIRCopAccess == NO) {
        if ([ignoreChecks notifyJoins] == YES) {
            NSString *tracker = [ignoreChecks trackingNickname];
            
            BOOL ison = [self.trackedUsers boolForKey:tracker];
            
            if (ison == NO) {					
                [self handleUserTrackingNotification:ignoreChecks 
                                            nickname:m.sender.nick 
                                            hostmask:[m.sender.raw hostmaskFromRawString] 
                                            langitem:@"UserTrackingHostmaskNowAvailable"];
                
                [self.trackedUsers setBool:YES forKey:tracker];
            }
        }
    }
    
	if ([TPCPreferences showJoinLeave]) {
        if (c.config.ignoreJPQActivity) {
            return;
        }
        
		NSString *text = TXTFLS(@"IRCUserJoinedChannel", nick, m.sender.user, m.sender.address);
		
		[self printBoth:c type:TVCLogLineJoinType text:text receivedAt:m.receivedAt];
	}
}

- (void)receivePart:(IRCMessage *)m
{
	NSString *nick = m.sender.nick;
	NSString *chname = [m paramAt:0];
	NSString *comment = [m paramAt:1].trim;
	
	IRCChannel *c = [self findChannel:chname];
	
	if (c) {
		if ([nick isEqualNoCase:self.myNick]) {
			[c deactivate];
			
			[self reloadTree];
		}
		
		[c removeMember:nick];
		
		if ([TPCPreferences showJoinLeave]) {
            if (c.config.ignoreJPQActivity) {
                return;
            }
            
			IRCAddressBook *ignoreChecks = [self checkIgnoreAgainstHostmask:m.sender.raw 
																withMatches:[NSArray arrayWithObjects:@"ignoreJPQE", nil]];
			
			if ([ignoreChecks ignoreJPQE] == YES) {
				return;
			}
			
			NSString *message = TXTFLS(@"IRCUserPartedChannel", nick, m.sender.user, m.sender.address);
			
			if (NSObjectIsNotEmpty(comment)) {
				message = [message stringByAppendingFormat:@" (%@)", comment];
			}
			
			[self printBoth:c type:TVCLogLinePartType text:message receivedAt:m.receivedAt];
		}
	}
}

- (void)receiveKick:(IRCMessage *)m
{
	NSString *nick = m.sender.nick;
	NSString *chname = [m paramAt:0];
	NSString *target = [m paramAt:1];
	NSString *comment = [m paramAt:2].trim;
	
	IRCChannel *c = [self findChannel:chname];
	
	if (c) {
		[c removeMember:target];
		
		if ([TPCPreferences showJoinLeave]) {
            if (c.config.ignoreJPQActivity) {
                return;
            }
            
			IRCAddressBook *ignoreChecks = [self checkIgnoreAgainstHostmask:m.sender.raw 
																withMatches:[NSArray arrayWithObjects:@"ignoreJPQE", nil]];
			
			if ([ignoreChecks ignoreJPQE] == YES) {
				return;
			}
			
			NSString *message = TXTFLS(@"IRCUserKickedFromChannel", nick, target, comment);
			
			[self printBoth:c type:TVCLogLineKickType text:message receivedAt:m.receivedAt];
		}
		
		if ([target isEqualNoCase:self.myNick]) {
			[c deactivate];
			
			[self reloadTree];
			
			[self notifyEvent:TXNotificationKickType lineType:TVCLogLineKickType target:c nick:nick text:comment];
			
			if ([TPCPreferences rejoinOnKick] && c.errLastJoin == NO) {
				[self printDebugInformation:TXTLS(@"IRCChannelPreparingRejoinAttempt") channel:c];
				
				[self performSelector:@selector(_joinKickedChannel:) withObject:c afterDelay:3.0];
			}
		}
	}
}

- (void)receiveQuit:(IRCMessage *)m
{
	NSString *nick    = m.sender.nick;
	NSString *comment = [m paramAt:0].trim;
	
	BOOL myself = [nick isEqualNoCase:self.myNick];
	
	IRCAddressBook *ignoreChecks = [self checkIgnoreAgainstHostmask:m.sender.raw 
														withMatches:[NSArray arrayWithObjects:@"ignoreJPQE", nil]];
	
	NSString *text = TXTFLS(@"IRCUserDisconnected", nick, m.sender.user, m.sender.address);
	
	if (NSObjectIsNotEmpty(comment)) {
		if ([TLORegularExpression string:comment 
						isMatchedByRegex:@"^((([a-zA-Z0-9-_\\.\\*]+)\\.([a-zA-Z0-9-_]+)) (([a-zA-Z0-9-_\\.\\*]+)\\.([a-zA-Z0-9-_]+)))$"]) {
			
			comment = TXTFLS(@"IRCServerHadNetsplitQuitMessage", comment);
		}
		
		text = [text stringByAppendingFormat:@" (%@)", comment];
	}
	
	for (IRCChannel *c in self.channels) {
		if ([c findMember:nick]) {
			if ([TPCPreferences showJoinLeave] && c.config.ignoreJPQActivity == NO && [ignoreChecks ignoreJPQE] == NO) {
				[self printChannel:c type:TVCLogLineQuitType text:text receivedAt:m.receivedAt];
			}
			
			[c removeMember:nick];
			
			if (myself) {
				[c deactivate];
			}
		}
	}
	
	if (myself == NO) {
		if ([nick isEqualNoCase:self.config.nick]) {
			[self changeNick:self.config.nick];
		}
	}
	
	[self.world reloadTree];
	
	if (self.hasIRCopAccess == NO) {
		if ([ignoreChecks notifyJoins] == YES) {
			NSString *tracker = [ignoreChecks trackingNickname];
			
			BOOL ison = [self.trackedUsers boolForKey:tracker];
			
			if (ison) {					
				[self.trackedUsers setBool:NO forKey:tracker];
				
				[self handleUserTrackingNotification:ignoreChecks 
											nickname:m.sender.nick 
											hostmask:[m.sender.raw hostmaskFromRawString]
											langitem:@"UserTrackingHostmaskNoLongerAvailable"];
			}
		}
	}
}

- (void)receiveKill:(IRCMessage *)m
{
	NSString *target = [m paramAt:0];
	
	for (IRCChannel *c in self.channels) {
		if ([c findMember:target]) {
			[c removeMember:target];
		}
	}
}

- (void)receiveNick:(IRCMessage *)m
{
	IRCAddressBook *ignoreChecks;
	
	NSString *nick   = m.sender.nick;
	NSString *toNick = [m paramAt:0];
    
    if ([nick isEqualToString:toNick]) {
        return;
    }
	
	BOOL myself = [nick isEqualNoCase:self.myNick];
	
	if (myself) {
		self.myNick = toNick;
	} else {
		ignoreChecks = [self checkIgnoreAgainstHostmask:m.sender.raw 
											withMatches:[NSArray arrayWithObjects:@"ignoreJPQE", nil]];
		
		if (self.hasIRCopAccess == NO) {
			if ([ignoreChecks notifyJoins] == YES) {
				NSString *tracker = [ignoreChecks trackingNickname];
				
				BOOL ison = [self.trackedUsers boolForKey:tracker];
				
				if (ison) {					
					[self handleUserTrackingNotification:ignoreChecks 
												nickname:m.sender.nick 
												hostmask:[m.sender.raw hostmaskFromRawString]
												langitem:@"UserTrackingHostmaskNoLongerAvailable"];
				} else {				
					[self handleUserTrackingNotification:ignoreChecks 
												nickname:m.sender.nick 
												hostmask:[m.sender.raw hostmaskFromRawString]
												langitem:@"UserTrackingHostmaskNowAvailable"];
				}
				
				[self.trackedUsers setBool:BOOLReverseValue(ison) forKey:tracker];
			}
		}
	}
	
	for (IRCChannel *c in self.channels) {
		if ([c findMember:nick]) { 
			if ((myself == NO && [ignoreChecks ignoreJPQE] == NO) || myself == YES) {
				NSString *text = TXTFLS(@"IRCUserChangedNickname", nick, toNick);
				
				[self printChannel:c type:TVCLogLineNickType text:text receivedAt:m.receivedAt];
			}
			
			[c renameMember:nick to:toNick];
		}
	}
	
	IRCChannel *c = [self findChannel:nick];
	
	if (c) {
		IRCChannel *t = [self findChannel:toNick];
		
		if (t) {
			[self.world destroyChannel:t];
		}
		
		c.name = toNick;
		
		[self reloadTree];
	}
}

- (void)receiveMode:(IRCMessage *)m
{
	NSString *nick = m.sender.nick;
	NSString *target = [m paramAt:0];
	NSString *modeStr = [m sequence:1];
	
	if ([target isChannelName]) {
		IRCChannel *c = [self findChannel:target];
		
		if (c) {
			NSArray *info = [c.mode update:modeStr];
			
			BOOL performWho = NO;
			
			for (IRCModeInfo *h in info) {
				[c changeMember:h.param mode:h.mode value:h.plus];
				
				if (h.plus == NO && self.multiPrefix == NO) {
					performWho = YES;
				}
			}
			
			if (performWho) {
				[self send:IRCCommandIndexWho, c.name, nil, nil];
			}
			
			[self printBoth:c type:TVCLogLineModeType text:TXTFLS(@"IRCModeSet", nick, modeStr) receivedAt:m.receivedAt];
		}
	} else {
		[self printBoth:nil type:TVCLogLineModeType text:TXTFLS(@"IRCModeSet", nick, modeStr) receivedAt:m.receivedAt];
	}
}

- (void)receiveTopic:(IRCMessage *)m
{
	NSString *nick = m.sender.nick;
	NSString *chname = [m paramAt:0];
	NSString *topic = [m paramAt:1];
	
	IRCChannel *c = [self findChannel:chname];
	
	[self decryptIncomingMessage:&topic channel:c];
	
	if (c) {
		[c		setTopic:topic];
		[c.log	setTopic:topic];
		
		[self printBoth:c type:TVCLogLineTopicType text:TXTFLS(@"IRCChannelTopicChanged", nick, topic) receivedAt:m.receivedAt];
	}
}

- (void)receiveInvite:(IRCMessage *)m
{
	NSString *nick = m.sender.nick;
	NSString *chname = [m paramAt:1];
	
	NSString *text = TXTFLS(@"IRCUserInvitedYouToJoinChannel", nick, m.sender.user, m.sender.address, chname);
	
	[self printBoth:[self.world selectedChannelOn:self] type:TVCLogLineInviteType text:text receivedAt:m.receivedAt];
	
	[self notifyEvent:TXNotificationInviteType lineType:TVCLogLineInviteType target:nil nick:nick text:chname];
	
	if ([TPCPreferences autoJoinOnInvite]) {
		[self joinUnlistedChannel:chname];
	}
}

- (void)receiveError:(IRCMessage *)m
{
	[self printError:m.sequence];
}

#pragma mark -
#pragma mark Server CAP

- (void)sendNextCap 
{
	if (self.capPaused == NO) {
		if (self.pendingCaps && [self.pendingCaps count]) {
			NSString *cap = [self.pendingCaps lastObject];
			
			[self send:IRCCommandIndexCap, @"REQ", cap, nil];
			
			[self.pendingCaps removeLastObject];
		} else {
			[self send:IRCCommandIndexCap, @"END", nil];
		}
	}
}

- (void)pauseCap 
{
	self.capPaused++;
}

- (void)resumeCap 
{
	self.capPaused--;
	
	[self sendNextCap];
}

- (BOOL)isCapAvailable:(NSString*)cap 
{
	return ([cap isEqualNoCase:@"identify-msg"] ||
			[cap isEqualNoCase:@"identify-ctcp"] ||
			[cap isEqualNoCase:@"multi-prefix"] ||
			[cap isEqualNoCase:@"userhost-in-names"] ||
			//[cap isEqualNoCase:@"znc.in/server-time"] ||
			([cap isEqualNoCase:@"sasl"] && NSObjectIsNotEmpty(self.config.nickPassword)));
}

- (void)cap:(NSString*)cap result:(BOOL)supported 
{
	if (supported) {
		if ([cap isEqualNoCase:@"sasl"]) {
			self.inSASLRequest = YES;
			
			[self pauseCap];
			[self send:IRCCommandIndexAuthenticate, @"PLAIN", nil];
		} else if ([cap isEqualNoCase:@"userhost-in-names"]) {
			self.userhostInNames = YES;
		} else if ([cap isEqualNoCase:@"multi-prefix"]) {
			self.multiPrefix = YES;
		} else if ([cap isEqualNoCase:@"identify-msg"]) {
			self.identifyMsg = YES;
		} else if ([cap isEqualNoCase:@"identify-ctcp"]) {
			self.identifyCTCP = YES;
		}
	}
}

- (void)receiveCapacityOrAuthenticationRequest:(IRCMessage *)m
{
    /* Implementation based off Colloquy's own. */
    
    NSString *command = [m command];
    NSString *star    = [m paramAt:0];
    NSString *base    = [m paramAt:1];
    NSString *action  = [m sequence:2];
    
    star   = [star trim];
    action = [action trim];
    
    if ([command isEqualNoCase:IRCCommandIndexCap]) {
        if ([base isEqualNoCase:@"LS"]) {
            NSArray *caps = [action componentsSeparatedByCharactersInSet:[NSCharacterSet whitespaceCharacterSet]];
			
            for (NSString *cap in caps) {
				if ([self isCapAvailable:cap]) {
					[self.pendingCaps addObject:cap];
				}
            }
        } else if ([base isEqualNoCase:@"ACK"]) {
			NSArray *caps = [action componentsSeparatedByCharactersInSet:[NSCharacterSet whitespaceCharacterSet]];
			
            for (NSString *cap in caps) {
				[self.acceptedCaps addObject:cap];
				
				[self cap:cap result:YES];
			}
		} else if ([base isEqualNoCase:@"NAK"]) {
			NSArray *caps = [action componentsSeparatedByCharactersInSet:[NSCharacterSet whitespaceCharacterSet]];
			
            for (NSString *cap in caps) {
				[self cap:cap result:NO];
			}
		}
		
		[self sendNextCap];
    } else {
        if ([star isEqualToString:@"+"]) {
            NSData *usernameData = [self.config.nick dataUsingEncoding:self.config.encoding allowLossyConversion:YES];
            
            NSMutableData *authenticateData = [usernameData mutableCopy];
			
            [authenticateData appendBytes:"\0" length:1];
            [authenticateData appendData:usernameData];
            [authenticateData appendBytes:"\0" length:1];
            [authenticateData appendData:[self.config.nickPassword dataUsingEncoding:self.config.encoding allowLossyConversion:YES]];
            
            NSString *authString = [authenticateData base64EncodingWithLineLength:400];
            NSArray *authStrings = [authString componentsSeparatedByCharactersInSet:[NSCharacterSet newlineCharacterSet]];
            
            for (NSString *string in authStrings) {
                [self send:IRCCommandIndexAuthenticate, string, nil];
            }
            
            if (NSObjectIsEmpty(authStrings) || [(NSString *)[authStrings lastObject] length] == 400) {
                [self send:IRCCommandIndexAuthenticate, @"+", nil];
            }
        }
    }
}

- (void)receivePing:(IRCMessage *)m
{
	[self send:IRCCommandIndexPong, [m sequence:0], nil];
}

- (void)receiveInit:(IRCMessage *)m
{
	[self startPongTimer];
	[self stopRetryTimer];
	[self stopAutoJoinTimer];
	
	self.sendLagcheckToChannel = self.serverHasNickServ			= NO;
	self.isLoggedIn = self.conn.loggedIn = self.inFirstISONRun	= YES;
	self.isAway = self.isConnecting = self.hasIRCopAccess		= NO;
	
	self.tryingNickNumber	= -1;
	
	self.serverHostname		= m.sender.raw;
	self.myNick				= [m paramAt:0];
	
	[self notifyEvent:TXNotificationConnectType lineType:TVCLogLineSystemType];
	
	for (__strong NSString *s in self.config.loginCommands) {
		if ([s hasPrefix:@"/"]) {
			s = [s safeSubstringFromIndex:1];
		}
		
		[self sendCommand:s completeTarget:NO target:nil];
	}
	
	for (IRCChannel *c in self.channels) {
		if (c.isTalk) {
			[c activate];
			
			IRCUser *m;
			
			m = [IRCUser new];
			m.supportInfo = self.isupport;
			m.nick = self.myNick;
			[c addMember:m];
			
			m = [IRCUser new];
			m.supportInfo = self.isupport;
			m.nick = c.name;
			[c addMember:m];
		}
	}
	
	[self reloadTree];
	[self populateISONTrackedUsersList:self.config.ignores];
	
#ifdef IS_TRIAL_BINARY
	[self startTrialPeriodTimer];
#endif
	
	[self startAutoJoinTimer];
}

- (void)receiveNumericReply:(IRCMessage *)m
{
	NSInteger n = m.numericReply; 
	
	if (400 <= n && n < 600 && 
		NSDissimilarObjects(n, 403) && 
		NSDissimilarObjects(n, 422)) {
		
		return [self receiveErrorNumericReply:m];
	}
	
	switch (n) {
		case 1: 
		{
			[self receiveInit:m];
			[self printReply:m];
			
			break;
		}
		case 2 ... 4:
		{
			if ([m.sender.nick isNickname] == NO) {
				[self.config setServer:m.sender.nick];
			}
			
			[self printReply:m];
			
			break;
		}
		case 5:
		{
			[self.isupport update:[m sequence:1] client:self];
			
			[self.config setNetwork:TXTFLS(@"IRCServerNetworkName", self.isupport.networkName)];
			
			[self.world updateTitle];
			
			break;
		}
		case 10:
		case 20:
		case 42:
		case 250 ... 255:
		case 265 ... 266:
		{
			[self printReply:m];
			
			break;
		}
		case 372:
		case 375:
		case 376:	 
		case 422:	
		{
			if ([TPCPreferences displayServerMOTD]) {
				[self printReply:m];
			}
			
			break;
		}
		case 221:
		{
			NSString *modeStr = [m paramAt:1];
			
			if ([modeStr isEqualToString:@"+"]) return;
			
			[self printBoth:nil type:TVCLogLineReplyType text:TXTFLS(@"IRCUserHasModes", modeStr) receivedAt:m.receivedAt];
			
			break;
		}
		case 290:
		{
			NSString *kind = [[m paramAt:1] lowercaseString];
			
			if ([kind isEqualToString:@"identify-msg"]) {
				self.identifyMsg = YES;
			} else if ([kind isEqualToString:@"identify-ctcp"]) {
				self.identifyCTCP = YES;
			}
			
			[self printReply:m];
			
			break;
		}
		case 301:
		{
			NSString *nick = [m paramAt:1];
			NSString *comment = [m paramAt:2];
			
			IRCChannel *c = [self findChannel:nick];
			IRCChannel *sc = [self.world selectedChannelOn:self];
			
			NSString *text = TXTFLS(@"IRCUserIsAway", nick, comment);
			
			if (c) {
				[self printBoth:(id)nick type:TVCLogLineReplyType text:text receivedAt:m.receivedAt];
			}
			
			if (self.whoisChannel && [self.whoisChannel isEqualTo:c] == NO) {
				[self printBoth:self.whoisChannel type:TVCLogLineReplyType text:text receivedAt:m.receivedAt];
			} else {		
				if ([sc isEqualTo:c] == NO) {
					[self printBoth:sc type:TVCLogLineReplyType text:text receivedAt:m.receivedAt];
				}
			}
			
			break;
		}
		case 305: 
		{
			self.isAway = NO;
			
			[self printUnknownReply:m];
			
			break;
		}
		case 306: 
		{
			self.isAway = YES;
			
			[self printUnknownReply:m];
			
			break;
		}
		case 307:
		case 310:
		case 313:
		case 335:
		case 378:
		case 379:
		case 671:
		{
			NSString *text = [NSString stringWithFormat:@"%@ %@", [m paramAt:1], [m paramAt:2]];
			
			if (self.whoisChannel) {
				[self printBoth:self.whoisChannel type:TVCLogLineReplyType text:text receivedAt:m.receivedAt];
			} else {		
				[self printBoth:[self.world selectedChannelOn:self] type:TVCLogLineReplyType text:text receivedAt:m.receivedAt];
			}
			
			break;
		}
		case 338:
		{
			NSString *text = [NSString stringWithFormat:@"%@ %@ %@", [m paramAt:1], [m sequence:3], [m paramAt:2]];
			
			if (self.whoisChannel) {
				[self printBoth:self.whoisChannel type:TVCLogLineReplyType text:text receivedAt:m.receivedAt];
			} else {		
				[self printBoth:[self.world selectedChannelOn:self] type:TVCLogLineReplyType text:text receivedAt:m.receivedAt];
			}
			
			break;
		}
		case 311:
		case 314:
		{
			NSString *nick = [m paramAt:1];
			NSString *username = [m paramAt:2];
			NSString *address = [m paramAt:3];
			NSString *realname = [m paramAt:5];
			
			NSString *text = nil;
			
			self.inWhoWasRun = (m.numericReply == 314);
			
			if ([realname hasPrefix:@":"]) {
				realname = [realname safeSubstringFromIndex:1];
			}
			
			if (self.inWhoWasRun) {
				text = TXTFLS(@"IRCUserWhowasHostmask", nick, username, address, realname);
			} else {
				text = TXTFLS(@"IRCUserWhoisHostmask", nick, username, address, realname);
			}	
			
			if (self.whoisChannel) {
				[self printBoth:self.whoisChannel type:TVCLogLineReplyType text:text receivedAt:m.receivedAt];
			} else {		
				[self printBoth:[self.world selectedChannelOn:self] type:TVCLogLineReplyType text:text receivedAt:m.receivedAt];
			}
			
			break;
		}
		case 312:
		{
			NSString *nick = [m paramAt:1];
			NSString *server = [m paramAt:2];
			NSString *serverInfo = [m paramAt:3];
			
			NSString *text = nil;
			
			if (self.inWhoWasRun) {
				text = TXTFLS(@"IRCUserWhowasConnectedFrom", nick, server,
							  [dateTimeFormatter stringFromDate:[NSDate dateWithNaturalLanguageString:serverInfo]]);
			} else {
				text = TXTFLS(@"IRCUserWhoisConnectedFrom", nick, server, serverInfo);
			}
			
			if (self.whoisChannel) {
				[self printBoth:self.whoisChannel type:TVCLogLineReplyType text:text receivedAt:m.receivedAt];
			} else {		
				[self printBoth:[self.world selectedChannelOn:self] type:TVCLogLineReplyType text:text receivedAt:m.receivedAt];
			}
			
			break;
		}
		case 317:
		{
			NSString *nick = [m paramAt:1];
			
			NSInteger idleStr = [m paramAt:2].doubleValue;
			NSInteger signOnStr = [m paramAt:3].doubleValue;
			
			NSString *idleTime = TXReadableTime(idleStr);
			NSString *dateFromString = [dateTimeFormatter stringFromDate:[NSDate dateWithTimeIntervalSince1970:signOnStr]];
			
			NSString *text = TXTFLS(@"IRCUserWhoisUptime", nick, dateFromString, idleTime);
			
			if (self.whoisChannel) {
				[self printBoth:self.whoisChannel type:TVCLogLineReplyType text:text receivedAt:m.receivedAt];
			} else {		
				[self printBoth:[self.world selectedChannelOn:self] type:TVCLogLineReplyType text:text receivedAt:m.receivedAt];
			}
			
			break;
		}
		case 319:
		{
			NSString *nick = [m paramAt:1];
			NSString *trail = [m paramAt:2].trim;
			
			NSString *text = TXTFLS(@"IRCUserWhoisChannels", nick, trail);
			
			if (self.whoisChannel) {
				[self printBoth:self.whoisChannel type:TVCLogLineReplyType text:text receivedAt:m.receivedAt];
			} else {		
				[self printBoth:[self.world selectedChannelOn:self] type:TVCLogLineReplyType text:text receivedAt:m.receivedAt];
			}
			
			break;
		}
		case 318:
		{
			self.whoisChannel = nil;
			
			break;
		}
		case 324:
		{
			NSString *chname = [m paramAt:1];
			NSString *modeStr;
			
			modeStr = [m sequence:2];
			modeStr = [modeStr stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceCharacterSet]];
			
			if ([modeStr isEqualToString:@"+"]) return;
			
			IRCChannel *c = [self findChannel:chname];
			
			if (c.isModeInit == NO || NSObjectIsEmpty([c.mode allModes])) {
				if (c && c.isActive) {
					[c.mode clear];
					[c.mode update:modeStr];
					
					c.isModeInit = YES;
				}
				
				[self printBoth:c type:TVCLogLineModeType text:TXTFLS(@"IRCChannelHasModes", modeStr) receivedAt:m.receivedAt];
			}
			
			break;
		}
		case 332:
		{
			NSString *chname = [m paramAt:1];
			NSString *topic = [m paramAt:2];
			
			IRCChannel *c = [self findChannel:chname];
			
			[self decryptIncomingMessage:&topic channel:c];
			
			if (c && c.isActive) {
				[c		setTopic:topic];
				[c.log	setTopic:topic];
				
				[self printBoth:c type:TVCLogLineTopicType text:TXTFLS(@"IRCChannelHasTopic", topic) receivedAt:m.receivedAt];
			}
			
			break;
		}
		case 333:	
		{
			NSString *chname = [m paramAt:1];
			NSString *setter = [m paramAt:2];
			NSString *timeStr = [m paramAt:3];
			
			long long timeNum = [timeStr longLongValue];
			
			NSRange r = [setter rangeOfCharacterFromSet:[NSCharacterSet characterSetWithCharactersInString:@"!@"]];
			
			if (NSDissimilarObjects(r.location, NSNotFound)) {
				setter = [setter safeSubstringToIndex:r.location];
			}
			
			IRCChannel *c = [self findChannel:chname];
			
			if (c) {
				NSString *text = [NSString stringWithFormat:TXTLS(@"IRCChannelHasTopicAuthor"), setter, 
								  [dateTimeFormatter stringFromDate:[NSDate dateWithTimeIntervalSince1970:timeNum]]];
				
				[self printBoth:c type:TVCLogLineTopicType text:text receivedAt:m.receivedAt];
			}
			
			break;
		}
		case 341:
		{
			NSString *nick = [m paramAt:1];
			NSString *chname = [m paramAt:2];
			
			IRCChannel *c = [self findChannel:chname];
			
			[self printBoth:c type:TVCLogLineReplyType text:TXTFLS(@"IRCUserInvitedToJoinChannel", nick, chname) receivedAt:m.receivedAt];
			
			break;
		}
		case 303:
		{
			if (self.hasIRCopAccess) {
				[self printUnknownReply:m];
			} else {
				NSArray *users = [[m sequence] componentsSeparatedByCharactersInSet:[NSCharacterSet whitespaceCharacterSet]];
				
				for (NSString *name in self.trackedUsers) {
					NSString *langkey = nil;
					
					BOOL ison = [self.trackedUsers boolForKey:name];
					
					if (ison) {
						if ([users containsObjectIgnoringCase:name] == NO) {
							if (self.inFirstISONRun == NO) {
								langkey = @"UserTrackingNicknameNoLongerAvailable";
							}
							
							[self.trackedUsers setBool:NO forKey:name];
						}
					} else {
						if ([users containsObjectIgnoringCase:name]) {
							langkey = ((self.inFirstISONRun) ? @"UserTrackingNicknameIsAvailable" : @"UserTrackingNicknameNowAvailable");
							
							[self.trackedUsers setBool:YES forKey:name];
						}
					}
					
					if (NSObjectIsNotEmpty(langkey)) {
						for (IRCAddressBook *g in self.config.ignores) {
							NSString *trname = [g trackingNickname];
							
							if ([trname isEqualNoCase:name]) {
								[self handleUserTrackingNotification:g nickname:name hostmask:name langitem:langkey];
							}
						}
					}
				}
				
				if (self.inFirstISONRun) {
					self.inFirstISONRun = NO;
				}
			}
			
			break;
		}
		case 315:
		{
			NSString *chname = [m paramAt:1];
			
			IRCChannel *c = [self findChannel:chname];
			
			if (c && c.isModeInit) {
				[c setIsModeInit:NO];
			} 
			
			if (self.inWhoInfoRun) {
				[self printUnknownReply:m];
				
				self.inWhoInfoRun = NO;
			}
			
			break;
		}
		case 352: 
		{
			NSString *chname = [m paramAt:1];
			
			IRCChannel *c = [self findChannel:chname];
			
			if (c) {
				NSString *nick		= [m paramAt:5];
				NSString *hostmask	= [m paramAt:3];
				NSString *username	= [m paramAt:2];
				NSString *fields    = [m paramAt:6];
				
				BOOL isIRCOp = NO;
				
				// fields = G|H *| chanprefixes
				// strip G or H (away status)
				fields = [fields substringFromIndex:1];
				
				if ([fields hasPrefix:@"*"]) {
					// The nick is an oper
					fields = [fields substringFromIndex:1];
					
					isIRCOp = YES;
				}
				
				IRCUser *u = [c findMember:nick];
				
				if (PointerIsEmpty(u)) {
					IRCUser *u = [IRCUser new];
					
					u.nick			= nick;
					u.isIRCOp		= isIRCOp;
					u.supportInfo	= self.isupport;
				}
				
				NSInteger i;
				
				for (i = 0; i < fields.length; i++) {
					NSString *prefix = [fields safeSubstringWithRange:NSMakeRange(i, 1)];
					
					if ([prefix isEqualTo:self.isupport.userModeYPrefix]) {
                        u.y = YES;
                    } else if ([prefix isEqualTo:self.isupport.userModeQPrefix]) {
						u.q = YES;
					} else if ([prefix isEqualTo:self.isupport.userModeAPrefix]) {
						u.a = YES;
					} else if ([prefix isEqualTo:self.isupport.userModeOPrefix]) {
						u.o = YES;
					} else if ([prefix isEqualTo:self.isupport.userModeHPrefix]) {
						u.h = YES;
					} else if ([prefix isEqualTo:self.isupport.userModeVPrefix]) {
						u.v = YES;
					} else {
						break;
					}
				}
				
				if (NSObjectIsEmpty(u.address)) {
					[u setAddress:hostmask];
					[u setUsername:username];
				}
				
				[c updateOrAddMember:u];
				[c reloadMemberList];
			} 
			
			if (self.inWhoInfoRun) {
				[self printUnknownReply:m];	
			}
			
			break;
		}
		case 353:
		{
			NSString *chname = [m paramAt:2];
			NSString *trail  = [m paramAt:3];
			
			IRCChannel *c = [self findChannel:chname];
			
			if (c) {
				NSArray *ary = [trail componentsSeparatedByCharactersInSet:[NSCharacterSet whitespaceCharacterSet]];
				
				for (__strong NSString *nick in ary) {
					nick = [nick trim];
					
					if (NSObjectIsEmpty(nick)) continue;
					
					IRCUser *m = [IRCUser new];
					
					NSInteger i;
					
					for (i = 0; i < nick.length; i++) {
						NSString *prefix = [nick safeSubstringWithRange:NSMakeRange(i, 1)];
						
						if ([prefix isEqualTo:self.isupport.userModeYPrefix]) {
							m.y = YES;
                        } else if ([prefix isEqualTo:self.isupport.userModeQPrefix]) {
							m.q = YES;
						} else if ([prefix isEqualTo:self.isupport.userModeAPrefix]) {
							m.a = YES;
						} else if ([prefix isEqualTo:self.isupport.userModeOPrefix]) {
							m.o = YES;
						} else if ([prefix isEqualTo:self.isupport.userModeHPrefix]) {
							m.h = YES;
						} else if ([prefix isEqualTo:self.isupport.userModeVPrefix]) {
							m.v = YES;
						} else {
							break;
						}
					}
					
					nick = [nick substringFromIndex:i];
					
					m.nick		= [nick nicknameFromHostmask];
					m.username	= [nick identFromHostmask];
					m.address	= [nick hostFromHostmask];
					
					m.supportInfo = self.isupport;
					m.isMyself    = [nick isEqualNoCase:self.myNick];
					
					[c addMember:m reload:NO];
					
					if (m.isMyself) {
						c.isOp     = (m.q || m.a | m.o | m.y);
						c.isHalfOp = (m.h || c.isOp);
					}
				}
				
				[c reloadMemberList];
			} 
			
			break;
		}
		case 366:
		{
			NSString *chname = [m paramAt:1];
			
			IRCChannel *c = [self findChannel:chname];
			
			if (c) {
				if ([c numberOfMembers] <= 1 && c.isOp) {
					NSString *m = c.config.mode;
					
					if (NSObjectIsNotEmpty(m)) {
						NSString *line = [NSString stringWithFormat:@"%@ %@ %@", IRCCommandIndexMode, chname, m];
						
						[self sendLine:line];
					}
					
					c.isModeInit = YES;
				}
				
				if ([c numberOfMembers] <= 1 && [chname isModeChannelName] && c.isOp) {
					NSString *topic = c.storedTopic;
					
					if (NSObjectIsEmpty(topic)) {
						topic = c.config.topic;
					}
					
					if (NSObjectIsNotEmpty(topic)) {
						if ([self encryptOutgoingMessage:&topic channel:c] == YES) {
							[self send:IRCCommandIndexTopic, chname, topic, nil];
						}
					}
				}
				
				if ([TPCPreferences processChannelModes]) {
					[self requestUserHosts:c];
				}
			}
			
			break;
		}
		case 320:
		{
			NSString *text = [NSString stringWithFormat:@"%@ %@", [m paramAt:1], [m sequence:2]];
			
			if (self.whoisChannel) {
				[self printBoth:self.whoisChannel type:TVCLogLineReplyType text:text receivedAt:m.receivedAt];
			} else {		
				[self printBoth:[self.world selectedChannelOn:self] type:TVCLogLineReplyType text:text receivedAt:m.receivedAt];
			}
			
			break;
		}
		case 321:
		{
			if (self.channelListDialog) {
				[self.channelListDialog clear];
			}
			
			break;
		}
		case 322:
		{
			NSString *chname	= [m paramAt:1];
			NSString *countStr	= [m paramAt:2];
			NSString *topic		= [m sequence:3];
			
			if (self.channelListDialog) {
				[self.channelListDialog addChannel:chname count:[countStr integerValue] topic:topic];
			}
			
			break;
		}
		case 323:	
		case 329:
		case 368:
		case 347:
		case 349:
		{
			return;
			break;
		}
		case 330:
		{
			NSString *text = [NSString stringWithFormat:@"%@ %@ %@", [m paramAt:1], [m sequence:3], [m paramAt:2]];
			
			if (self.whoisChannel) {
				[self printBoth:self.whoisChannel type:TVCLogLineReplyType text:text receivedAt:m.receivedAt];
			} else {		
				[self printBoth:[self.world selectedChannelOn:self] type:TVCLogLineReplyType text:text receivedAt:m.receivedAt];
			}
			
			break;
		}
		case 367:
		{
			NSString *mask = [m paramAt:2];
			NSString *owner = [m paramAt:3];
			
			long long seton = [[m paramAt:4] longLongValue];
			
			if (self.chanBanListSheet) {
				[self.chanBanListSheet addBan:mask tset:[dateTimeFormatter stringFromDate:[NSDate dateWithTimeIntervalSince1970:seton]] setby:owner];
			}
			
			break;
		}
		case 346:
		{
			NSString *mask = [m paramAt:2];
			NSString *owner = [m paramAt:3];
			
			long long seton = [[m paramAt:4] longLongValue];
			
			if (self.inviteExceptionSheet) {
				[self.inviteExceptionSheet addException:mask tset:[dateTimeFormatter stringFromDate:[NSDate dateWithTimeIntervalSince1970:seton]] setby:owner];
			}
			
			break;
		}
		case 348:
		{
			NSString *mask = [m paramAt:2];
			NSString *owner = [m paramAt:3];
			
			long long seton = [[m paramAt:4] longLongValue];
			
			if (self.banExceptionSheet) {
				[self.banExceptionSheet addException:mask tset:[dateTimeFormatter stringFromDate:[NSDate dateWithTimeIntervalSince1970:seton]] setby:owner];
			}
			
			break;
		}
		case 381:
		{
			if (self.hasIRCopAccess == NO) {
                /* If we are already an IRCOp, then we do not need to see this line again. 
                 We will assume that if we are seeing it again, then it is the result of a
                 user opening two connections to a single bouncer session. */
                
                [self printBoth:nil type:TVCLogLineReplyType text:TXTFLS(@"IRCUserIsNowIRCOperator", m.sender.nick) receivedAt:m.receivedAt];
                
                self.hasIRCopAccess = YES;
            }
			
			break;
		}
		case 328:
		{
			NSString *chname = [m paramAt:1];
			NSString *website = [m paramAt:2];
			
			IRCChannel *c = [self findChannel:chname];
			
			if (c && website) {
				[self printBoth:c type:TVCLogLineWebsiteType text:TXTFLS(@"IRCChannelHasWebsite", website) receivedAt:m.receivedAt];
			}
			
			break;
		}
		case 369:
		{
			self.inWhoWasRun = NO;
			
			[self printBoth:[self.world selectedChannelOn:self] type:TVCLogLineReplyType text:[m sequence] receivedAt:m.receivedAt];
			
			break;
		}
        case 900:
        {
            self.isIdentifiedWithSASL = YES;
            
            [self printBoth:self type:TVCLogLineReplyType text:[m sequence:3] receivedAt:m.receivedAt];
            
            break;
        }
        case 903:
        case 904:
        case 905:
        case 906:
        case 907:
        {
            if (n == 903) { // success 
                [self printBoth:self type:TVCLogLineNoticeType text:[m sequence:1] receivedAt:m.receivedAt];
            } else {
                [self printReply:m];
            }
            
            if (self.inSASLRequest) {
                self.inSASLRequest = NO;
				
                [self resumeCap];
            }
            
            break;
        }
		default:
		{
			if ([self.world.bundlesForServerInput containsKey:[NSString stringWithInteger:m.numericReply]]) {
				break;
			}
			
			[self printUnknownReply:m];
			
			break;
		}
	}
}

- (void)receiveErrorNumericReply:(IRCMessage *)m
{
	NSInteger n = m.numericReply;
	
	switch (n) {
		case 401:	
		{
			IRCChannel *c = [self findChannel:[m paramAt:1]];
			
			if (c && c.isActive) {
				[self printErrorReply:m channel:c];
				
				return;
			} else {
				[self printErrorReply:m];
			}
			
			return;
			break;
		}
		case 433:	
		case 437:   
        {
			if (self.isLoggedIn) break;
			
			[self receiveNickCollisionError:m];
			
			return;
			break;
        }
		case 402:   
		{
			NSString *text = TXTFLS(@"IRCHadRawError", m.numericReply, [m sequence:1]);
			
			[self printBoth:[world selectedChannelOn:self] type:TVCLogLineReplyType text:text receivedAt:m.receivedAt];
			
			return;
			break;
		}
		case 404:	
		{
			NSString *chname = [m paramAt:1];
			NSString *text	 = TXTFLS(@"IRCHadRawError", m.numericReply, [m sequence:2]);
			
			[self printBoth:[self findChannel:chname] type:TVCLogLineReplyType text:text receivedAt:m.receivedAt];
			
			return;
			break;
		}
		case 405:	
		case 471:
		case 473:
		case 474:
		case 475:
		case 477:
		case 485:
		{
			IRCChannel *c = [self findChannel:[m paramAt:1]];
			
			if (c) {
				c.errLastJoin = YES;
			}
		}
	}
	
	[self printErrorReply:m];
}

- (void)receiveNickCollisionError:(IRCMessage *)m
{
	if (self.config.altNicks.count && self.isLoggedIn == NO) {
		++self.tryingNickNumber;
		
		NSArray *altNicks = self.config.altNicks;
		
		if (self.tryingNickNumber < altNicks.count) {
			NSString *nick = [altNicks safeObjectAtIndex:self.tryingNickNumber];
			
			[self send:IRCCommandIndexNick, nick, nil];
		} else {
			[self tryAnotherNick];
		}
	} else {
		[self tryAnotherNick];
	}
}

- (void)tryAnotherNick
{
	if (self.sentNick.length >= self.isupport.nickLen) {
		NSString *nick = [self.sentNick safeSubstringToIndex:self.isupport.nickLen];
		
		BOOL found = NO;
		
		for (NSInteger i = (nick.length - 1); i >= 0; --i) {
			UniChar c = [nick characterAtIndex:i];
			
			if (NSDissimilarObjects(c, '_')) {
				found = YES;
				
				NSString *head = [nick safeSubstringToIndex:i];
				
				NSMutableString *s = [head mutableCopy];
				
				for (NSInteger i = (self.isupport.nickLen - s.length); i > 0; --i) {
					[s appendString:@"_"];
				}
				
				self.sentNick = s;
				
				break;
			}
		}
		
		if (found == NO) {
			self.sentNick = @"0";
		}
	} else {
		self.sentNick = [self.sentNick stringByAppendingString:@"_"];
	}
	
	[self send:IRCCommandIndexNick, self.sentNick, nil];
}

#pragma mark -
#pragma mark IRCConnection Delegate

- (void)changeStateOff
{
	if (self.isLoggedIn == NO && self.isConnecting == NO) return;
	
	BOOL prevConnected = self.isConnected;
	
	[self.acceptedCaps removeAllObjects];
	self.capPaused = 0;
	
	self.userhostInNames	= NO;
	self.multiPrefix		= NO;
	self.identifyMsg		= NO;
	self.identifyCTCP		= NO;
	
	self.conn = nil;
    
    for (IRCChannel *c in self.channels) {
        c.status = IRCChannelParted;
    }
	
	[self clearCommandQueue];
	[self stopRetryTimer];
	[self stopISONTimer];
	
	if (self.reconnectEnabled) {
		[self startReconnectTimer];
	}
	
	self.sendLagcheckToChannel = self.isIdentifiedWithSASL = NO;
	self.isConnecting = self.isConnected = self.isLoggedIn = self.isQuitting = NO;
	self.hasIRCopAccess = self.serverHasNickServ = self.autojoinInitialized = NO;
	
	self.myNick   = NSStringEmptyPlaceholder;
	self.sentNick = NSStringEmptyPlaceholder;
	
	self.tryingNickNumber = -1;
	
	NSString *disconnectTXTLString = nil;
	
	switch (self.disconnectType) {
		case IRCDisconnectNormalMode:      disconnectTXTLString = @"IRCDisconnectedFromServer"; break;
        case IRCSleepModeDisconnectMode:   disconnectTXTLString = @"IRCDisconnectedBySleepMode"; break;
		case IRCTrialPeriodDisconnectMode: disconnectTXTLString = @"IRCDisconnectedByTrialPeriodTimer"; break;
		default: break;
	}
	
	if (disconnectTXTLString) {
		for (IRCChannel *c in self.channels) {
			if (c.isActive) {
				[c deactivate];
				
				[self printSystem:c text:TXTLS(disconnectTXTLString)];
			}
		}
		
		[self printSystemBoth:nil text:TXTLS(disconnectTXTLString)];
		
		if (prevConnected) {
			[self notifyEvent:TXNotificationDisconnectType lineType:TVCLogLineSystemType];
		}
	}
	
#ifdef IS_TRIAL_BINARY
	[self stopTrialPeriodTimer];
#endif
	
	[self reloadTree];
	
	self.isAway = NO;
}

- (void)ircConnectionDidConnect:(IRCConnection *)sender
{
	[self startRetryTimer];
	
	if (NSDissimilarObjects(self.connectType, IRCBadSSLCertificateReconnectMode)) {
		[self printSystemBoth:nil text:TXTLS(@"IRCConnectedToServer")];
	}
	
	self.isLoggedIn		= NO;
	self.isConnected	= self.reconnectEnabled = YES;
	
	self.encoding = self.config.encoding;
	
	if (NSObjectIsEmpty(self.inputNick)) {
		self.inputNick = self.config.nick;
	}
	
	self.sentNick = self.inputNick;
	self.myNick   = self.inputNick;
	
	[self.isupport reset];
	
	NSInteger modeParam = ((self.config.invisibleMode) ? 8 : 0);
	
	NSString *user		= self.config.username;
	NSString *realName	= self.config.realName;
	
	if (NSObjectIsEmpty(user)) {
        user = self.config.nick;
    }
    
	if (NSObjectIsEmpty(realName)) {
        realName = self.config.nick;
    }
    
    [self send:IRCCommandIndexCap, @"LS", nil];
	
	if (NSObjectIsNotEmpty(self.config.password)) {
        [self send:IRCCommandIndexPass, self.config.password, nil];
    }
	
	[self send:IRCCommandIndexNick, self.sentNick, nil];
	
	if (self.config.bouncerMode) { // Fuck psybnc — use ZNC
		[self send:IRCCommandIndexUser, user, [NSString stringWithDouble:modeParam], @"*", [@":" stringByAppendingString:realName], nil];
	} else {
		[self send:IRCCommandIndexUser, user, [NSString stringWithDouble:modeParam], @"*", realName, nil];
	}
	
	[self.world reloadTree];
}

- (void)ircConnectionDidDisconnect:(IRCConnection *)sender
{
	if (self.disconnectType == IRCBadSSLCertificateDisconnectMode) {
		NSString *supkeyHead = TXPopupPromptSuppressionPrefix;
		NSString *supkeyBack = [NSString stringWithFormat:@"cert_trust_error.@", self.config.guid];
		
		if (self.config.isTrustedConnection == NO) {
			BOOL status = [TLOPopupPrompts dialogWindowWithQuestion:TXTLS(@"SocketBadSSLCertificateErrorMessage") 
															  title:TXTLS(@"SocketBadSSLCertificateErrorTitle") 
													  defaultButton:TXTLS(@"TrustButton") 
													alternateButton:TXTLS(@"CancelButton")
														otherButton:nil
													 suppressionKey:supkeyBack
													suppressionText:@"-"];
			
			[_NSUserDefaults() setBool:status forKey:[supkeyHead stringByAppendingString:supkeyBack]];
			
			if (status) {
				self.config.isTrustedConnection = status;
				
				[self connect:IRCBadSSLCertificateReconnectMode];
				
				return;
			}
		}
	}
	
	[self changeStateOff];
}

- (void)ircConnectionDidError:(NSString *)error
{
	[self printError:error];
}

- (void)ircConnectionDidReceive:(NSData *)data
{
	self.lastMessageReceived = [NSDate epochTime];
	
	NSString *s = [NSString stringWithData:data encoding:self.encoding];
	
	if (PointerIsEmpty(s)) {
		s = [NSString stringWithData:data encoding:self.config.fallbackEncoding];
		
		if (PointerIsEmpty(s)) {
			s = [NSString stringWithData:data encoding:NSUTF8StringEncoding];
			
			if (PointerIsEmpty(s)) {
				NSLog(@"NSData decode failure. (%@)", data);
				
				return;
			}
		}
	}
	
	self.world.messagesReceived++;
	self.world.bandwidthIn += [s length];
	
	if (self.rawModeEnabled) {
		NSLog(@" >> %@", s);
	}
	
	if ([TPCPreferences removeAllFormatting]) {
		s = [s stripEffects];
	}
	
	IRCMessage *m = [[IRCMessage alloc] initWithLine:s];
	
	NSString *cmd = m.command;
	
	if (m.numericReply > 0) { 
		[self receiveNumericReply:m];
	} else {
		switch ([TPCPreferences indexOfIRCommand:cmd]) {	
			case 4: // Command: ERROR
            {
				[self receiveError:m];
				break;
            }
			case 5: // Command: INVITE
            {
				[self receiveInvite:m];
				break;
            }
			case 7: // Command: JOIN
            {
				[self receiveJoin:m];
				break;
            }
			case 8: // Command: KICK
            {
				[self receiveKick:m];
				break;
            }
			case 9: // Command: KILL
            {
				[self receiveKill:m];
				break;
            }
			case 11: // Command: MODE
            {
				[self receiveMode:m];
				break;
            }
			case 13: // Command: NICK
            {
				[self receiveNick:m];
				break;
            }
			case 14: // Command: NOTICE
			case 19: // Command: PRIVMSG
            {
				[self receivePrivmsgAndNotice:m];
				break;
            }
			case 15: // Command: PART
            {
				[self receivePart:m];
				break;
            }
            case 17: // Command: PING
            {
                [self receivePing:m];
                break;
            }
            case 20: // Command: QUIT
            {
                [self receiveQuit:m];
                break;
            }
            case 21: // Command: TOPIC
            {
                [self receiveTopic:m];
                break;
            }
            case 80: // Command: WALLOPS
            case 85: // Command: CHATOPS
            case 86: // Command: GLOBOPS
            case 87: // Command: LOCOPS
            case 88: // Command: NACHAT
            case 89: // Command: ADCHAT
            {
                [m.params safeInsertObject:m.sender.nick atIndex:0];
                
                NSString *text = [m.params safeObjectAtIndex:1];
                
                [m.params safeRemoveObjectAtIndex:1];
                [m.params safeInsertObject:[NSString stringWithFormat:@"[%@]: %@", m.command, text] atIndex:1];
                
                m.command = IRCCommandIndexNotice;
                
                [self receivePrivmsgAndNotice:m];
                
                break;
            }
            case 101: // Command: AUTHENTICATE
            case 102: // Command: CAP
            {
                [self receiveCapacityOrAuthenticationRequest:m];
                break;
            }
        }
    }
    
    if ([self.world.bundlesForServerInput containsKey:cmd]) {
        [self.invokeInBackgroundThread processBundlesServerMessage:m];
    }
    
    [self.world updateTitle];
}

- (void)ircConnectionWillSend:(NSString *)line
{
}

#pragma mark -
#pragma mark Init

+ (void)load
{
	if (NSDissimilarObjects(self, [IRCClient class])) return;
	
	@autoreleasepool {
		dateTimeFormatter = [NSDateFormatter new];
		[dateTimeFormatter setDateStyle:NSDateFormatterLongStyle];
		[dateTimeFormatter setTimeStyle:NSDateFormatterLongStyle];
	}
}

@end
