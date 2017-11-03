//
//  Terminal.m
//  iSH
//
//  Created by Theodore Dubois on 10/18/17.
//

#import "Terminal.h"
#include "fs/tty.h"

@interface Terminal () <WKScriptMessageHandler>

@property WKWebView *webView;
@property struct tty *tty;
@property NSMutableData *pendingData;

@end

@interface CustomWebView : WKWebView
@end
@implementation CustomWebView
- (BOOL)becomeFirstResponder {
    return NO;
}
@end

@implementation Terminal

static Terminal *terminal = nil;

- (instancetype)init {
    if (terminal)
        return terminal;
    if (self = [super init]) {
        self.pendingData = [NSMutableData new];
        WKWebViewConfiguration *config = [WKWebViewConfiguration new];
        for (NSString *name in @[@"log"]) {
            [config.userContentController addScriptMessageHandler:self name:name];
        }
        self.webView = [[CustomWebView alloc] initWithFrame:CGRectZero configuration:config];
        self.webView.scrollView.scrollEnabled = NO;
        [self.webView loadRequest:
         [NSURLRequest requestWithURL:
          [NSBundle.mainBundle URLForResource:@"term" withExtension:@"html"]]];
        [self.webView addObserver:self forKeyPath:@"loading" options:0 context:NULL];
        terminal = self;
    }
    return self;
}

- (void)userContentController:(WKUserContentController *)userContentController didReceiveScriptMessage:(WKScriptMessage *)message {
    if ([message.name isEqualToString:@"log"]) {
        NSLog(@"%@", message.body);
    }
}

- (size_t)write:(const void *)buf length:(size_t)len {
    [self.pendingData appendData:[NSData dataWithBytes:buf length:len]];
    [self performSelectorOnMainThread:@selector(sendPendingOutput) withObject:nil waitUntilDone:NO];
    return len;
}

- (void)sendInput:(const char *)buf length:(size_t)len {
    tty_input(self.tty, buf, len);
}

- (void)observeValueForKeyPath:(NSString *)keyPath ofObject:(id)object change:(NSDictionary<NSKeyValueChangeKey,id> *)change context:(void *)context {
    if (object == self.webView && [keyPath isEqualToString:@"loading"] && !self.webView.loading) {
        [self sendPendingOutput];
        [self.webView removeObserver:self forKeyPath:@"loading"];
    }
}

- (void)sendPendingOutput {
    if (self.webView.loading)
        return;
    if (self.pendingData.length == 0)
        return;
    NSString *str = [[NSString alloc] initWithData:self.pendingData encoding:NSUTF8StringEncoding];
    self.pendingData = [NSMutableData new];
    NSError *err;
    NSData *jsonData = [NSJSONSerialization dataWithJSONObject:@[str] options:0 error:&err];
    if (err != nil)
        NSLog(@"%@", err);
    NSString *jsToEvaluate = [NSString stringWithFormat:@"output(%@[0])", [[NSString alloc] initWithData:jsonData encoding:NSUTF8StringEncoding]];
    [self.webView evaluateJavaScript:jsToEvaluate completionHandler:nil];
}

+ (Terminal *)terminalWithType:(int)type number:(int)number {
    return [Terminal new];
}

@end

static int ios_tty_open(struct tty *tty) {
    Terminal *terminal = [Terminal terminalWithType:tty->type number:tty->num];
    terminal.tty = tty;
    tty->data = (void *) CFBridgingRetain(terminal);

    // termios
    tty->termios.lflags = ISIG_ | ICANON_ | ECHO_ | ECHOE_;
    tty->termios.iflags = ICRNL_;
    tty->termios.oflags = OPOST_ | ONLCR_;
    tty->termios.cc[VINTR_] = '\x03';
    tty->termios.cc[VQUIT_] = '\x1c';
    tty->termios.cc[VERASE_] = '\x7f';
    tty->termios.cc[VKILL_] = '\x15';
    tty->termios.cc[VEOF_] = '\x04';
    tty->termios.cc[VTIME_] = 0;
    tty->termios.cc[VMIN_] = 1;
    tty->termios.cc[VSTART_] = '\x11';
    tty->termios.cc[VSTOP_] = '\x13';
    tty->termios.cc[VSUSP_] = '\x1a';
    tty->termios.cc[VEOL_] = 0;
    tty->termios.cc[VREPRINT_] = '\x12';
    tty->termios.cc[VDISCARD_] = '\x0f';
    tty->termios.cc[VWERASE_] = '\x17';
    tty->termios.cc[VLNEXT_] = '\x16';
    tty->termios.cc[VEOL2_] = 0;

    return 0;
}

static ssize_t ios_tty_write(struct tty *tty, const void *buf, size_t len) {
    Terminal *terminal = (__bridge Terminal *) tty->data;
    return [terminal write:buf length:len];
}

static void ios_tty_close(struct tty *tty) {
    CFBridgingRelease(tty->data);
}

struct tty_driver ios_tty_driver = {
    .open = ios_tty_open,
    .write = ios_tty_write,
    .close = ios_tty_close,
};