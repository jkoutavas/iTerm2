//
//  iTermFullScreenUpdateDetector.m
//  iTerm2
//
//  Created by George Nachman on 4/23/15.
//
//

#import "iTermTemporaryDoubleBufferedGridController.h"
#import "DebugLogging.h"
#import "VT100Grid.h"

@interface iTermTemporaryDoubleBufferedGridController()
@property(nonatomic, retain) VT100Grid *savedGrid;
@end

@implementation iTermTemporaryDoubleBufferedGridController {
    NSTimer *_timer;
    VT100Grid *_savedGrid;
}

- (void)dealloc {
    [_savedGrid release];
    [super dealloc];
}

- (void)start {
    if (_explicit) {
        return;
    }
    if (!_savedGrid) {
        [self snapshot];
    }
}

- (void)startExplicitly {
    if (_savedGrid) {
        [self scheduleTimer];
    } else {
        _explicit = YES;
        [self snapshot];
    }
}

- (void)reset {
    if (_explicit) {
        return;
    }
    DLog(@"Reset saved grid (delegate=%@)", _delegate);
    BOOL hadSavedGrid = _savedGrid != nil;
    self.savedGrid = nil;
    [_timer invalidate];
    _timer = nil;
    if (hadSavedGrid && _drewSavedGrid) {
        [_delegate temporaryDoubleBufferedGridDidExpire];
    }
}

- (void)resetExplicitly {
    _explicit = NO;
    [self reset];
}

#pragma mark - Private

- (void)snapshot {
    DLog(@"Take a snapshot of the grid because cursor was hidden (delegate=%@)", _delegate);
    self.savedGrid = [_delegate temporaryDoubleBufferedGridCopy];

    [self scheduleTimer];
    _drewSavedGrid = NO;
}

- (void)scheduleTimer {
    static const NSTimeInterval kTimeToKeepSavedGrid = 0.2;
    static const NSTimeInterval kExplicitSaveTime = 1.0;

    [_timer invalidate];
    _timer = [NSTimer scheduledTimerWithTimeInterval:_explicit ? kExplicitSaveTime : kTimeToKeepSavedGrid
                                              target:self
                                            selector:@selector(savedGridExpirationTimer:)
                                            userInfo:nil
                                             repeats:NO];
}

- (void)savedGridExpirationTimer:(NSTimer *)timer {
    DLog(@"Saved grid expired. (delegate=%@)", _delegate);
    _timer = nil;
    [self resetExplicitly];
}

@end
