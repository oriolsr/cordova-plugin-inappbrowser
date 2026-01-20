/*
 Licensed to the Apache Software Foundation (ASF) under one
 or more contributor license agreements.  See the NOTICE file
 distributed with this work for additional information
 regarding copyright ownership.  The ASF licenses this file
 to you under the Apache License, Version 2.0 (the
 "License"); you may not use this file except in compliance
 with the License.  You may obtain a copy of the License at

 http://www.apache.org/licenses/LICENSE-2.0

 Unless required by applicable law or agreed to in writing,
 software distributed under the License is distributed on an
 "AS IS" BASIS, WITHOUT WARRANTIES OR CONDITIONS OF ANY
 KIND, either express or implied.  See the License for the
 specific language governing permissions and limitations
 under the License.
 */

#import <Foundation/Foundation.h>
#import "CDVWKInAppBrowser.h"
#import <Cordova/NSDictionary+CordovaPreferences.h>
#import <Cordova/CDVWebViewProcessPoolFactory.h>
#import <Cordova/CDVPluginResult.h>

#define    kInAppBrowserTargetSelf @"_self"
#define    kInAppBrowserTargetSystem @"_system"
#define    kInAppBrowserTargetBlank @"_blank"

#define    kInAppBrowserToolbarBarPositionBottom @"bottom"
#define    kInAppBrowserToolbarBarPositionTop @"top"

#define    IAB_BRIDGE_NAME @"cordova_iab"

#define    TOOLBAR_HEIGHT 44.0
#define    LOCATIONBAR_HEIGHT 21.0
#define    FOOTER_HEIGHT ((TOOLBAR_HEIGHT) + (LOCATIONBAR_HEIGHT))

#pragma mark CDVWKInAppBrowser

@implementation CDVWKInAppBrowser

static CDVWKInAppBrowser* instance = nil;

+ (id) getInstance{
    return instance;
}

- (void)pluginInitialize
{
    instance = self;
    _callbackIdPattern = nil;
    _beforeload = @"";
    _waitForBeforeload = NO;
}

- (void)onReset
{
    [self close:nil];
}

- (void)close:(CDVInvokedUrlCommand*)command
{
    if (self.inAppBrowserViewController == nil) {
        NSLog(@"IAB.close() called but it was already closed.");
        return;
    }

    // Things are cleaned up in browserExit.
    [self.inAppBrowserViewController close];
}

- (BOOL) isSystemUrl:(NSURL*)url
{
    if ([[url host] isEqualToString:@"itunes.apple.com"]) {
        return YES;
    }

    return NO;
}

- (void)open:(CDVInvokedUrlCommand*)command
{
    CDVPluginResult* pluginResult;

    NSString* url = [command argumentAtIndex:0];
    NSString* target = [command argumentAtIndex:1 withDefault:kInAppBrowserTargetSelf];
    NSString* options = [command argumentAtIndex:2 withDefault:@"" andClass:[NSString class]];

    self.callbackId = command.callbackId;

    if (url != nil) {
        NSURL* baseUrl = [self.webViewEngine URL];
        NSURL* absoluteUrl = [[NSURL URLWithString:url relativeToURL:baseUrl] absoluteURL];

        if ([self isSystemUrl:absoluteUrl]) {
            target = kInAppBrowserTargetSystem;
        }

        if ([target isEqualToString:kInAppBrowserTargetSelf]) {
            [self openInCordovaWebView:absoluteUrl withOptions:options];
        } else if ([target isEqualToString:kInAppBrowserTargetSystem]) {
            [self openInSystem:absoluteUrl];
        } else { // _blank or anything else
            [self openInInAppBrowser:absoluteUrl withOptions:options];
        }

        pluginResult = [CDVPluginResult resultWithStatus:CDVCommandStatus_OK];
    } else {
        pluginResult = [CDVPluginResult resultWithStatus:CDVCommandStatus_ERROR messageAsString:@"incorrect number of arguments"];
    }

    [pluginResult setKeepCallback:[NSNumber numberWithBool:YES]];
    [self.commandDelegate sendPluginResult:pluginResult callbackId:command.callbackId];
}

- (void)openInInAppBrowser:(NSURL*)url withOptions:(NSString*)options
{
    CDVInAppBrowserOptions* browserOptions = [CDVInAppBrowserOptions parseOptions:options];

    WKWebsiteDataStore* dataStore = [WKWebsiteDataStore defaultDataStore];
    if (browserOptions.cleardata) {

        NSDate* dateFrom = [NSDate dateWithTimeIntervalSince1970:0];
        [dataStore removeDataOfTypes:[WKWebsiteDataStore allWebsiteDataTypes] modifiedSince:dateFrom completionHandler:^{
            NSLog(@"Removed all WKWebView data");
            self.inAppBrowserViewController.webView.configuration.processPool = [[WKProcessPool alloc] init]; // create new process pool to flush all data
        }];
    }

    if (browserOptions.clearcache) {
        // Deletes all cookies
        WKHTTPCookieStore* cookieStore = dataStore.httpCookieStore;
        [cookieStore getAllCookies:^(NSArray* cookies) {
            NSHTTPCookie* cookie;
            for(cookie in cookies){
                [cookieStore deleteCookie:cookie completionHandler:nil];
            }
        }];
    }

    if (browserOptions.clearsessioncache) {
        // Deletes session cookies
        WKHTTPCookieStore* cookieStore = dataStore.httpCookieStore;
        [cookieStore getAllCookies:^(NSArray* cookies) {
            NSHTTPCookie* cookie;
            for(cookie in cookies){
                if(cookie.sessionOnly){
                    [cookieStore deleteCookie:cookie completionHandler:nil];
                }
            }
        }];
    }

    if (self.inAppBrowserViewController == nil) {
        self.inAppBrowserViewController = [[CDVWKInAppBrowserViewController alloc] initWithBrowserOptions: browserOptions andSettings:self.commandDelegate.settings];
        self.inAppBrowserViewController.navigationDelegate = self;

        if ([self.viewController conformsToProtocol:@protocol(CDVScreenOrientationDelegate)]) {
            self.inAppBrowserViewController.orientationDelegate = (UIViewController <CDVScreenOrientationDelegate>*)self.viewController;
        }
    }

    // [self.inAppBrowserViewController showLocationBar:browserOptions.location];
    [self.inAppBrowserViewController showToolBar:browserOptions.toolbar :browserOptions.toolbarposition];
    if (browserOptions.closebuttoncaption != nil || browserOptions.closebuttoncolor != nil) {
        int closeButtonIndex = browserOptions.lefttoright ? (browserOptions.hidenavigationbuttons ? 1 : 4) : 0;
        [self.inAppBrowserViewController setCloseButtonTitle:browserOptions.closebuttoncaption :browserOptions.closebuttoncolor :closeButtonIndex];
    }
    // Set Presentation Style
    UIModalPresentationStyle presentationStyle = UIModalPresentationFullScreen; // default
    if (browserOptions.presentationstyle != nil) {
        if ([[browserOptions.presentationstyle lowercaseString] isEqualToString:@"pagesheet"]) {
            presentationStyle = UIModalPresentationPageSheet;
        } else if ([[browserOptions.presentationstyle lowercaseString] isEqualToString:@"formsheet"]) {
            presentationStyle = UIModalPresentationFormSheet;
        }
    }
    self.inAppBrowserViewController.modalPresentationStyle = presentationStyle;

    // Set Transition Style
    UIModalTransitionStyle transitionStyle = UIModalTransitionStyleCoverVertical; // default
    if (browserOptions.transitionstyle != nil) {
        if ([[browserOptions.transitionstyle lowercaseString] isEqualToString:@"fliphorizontal"]) {
            transitionStyle = UIModalTransitionStyleFlipHorizontal;
        } else if ([[browserOptions.transitionstyle lowercaseString] isEqualToString:@"crossdissolve"]) {
            transitionStyle = UIModalTransitionStyleCrossDissolve;
        }
    }
    self.inAppBrowserViewController.modalTransitionStyle = transitionStyle;

    //prevent webView from bouncing
    if (browserOptions.disallowoverscroll) {
        if ([self.inAppBrowserViewController.webView respondsToSelector:@selector(scrollView)]) {
            ((UIScrollView*)[self.inAppBrowserViewController.webView scrollView]).bounces = NO;
        } else {
            for (id subview in self.inAppBrowserViewController.webView.subviews) {
                if ([[subview class] isSubclassOfClass:[UIScrollView class]]) {
                    ((UIScrollView*)subview).bounces = NO;
                }
            }
        }
    }

    // use of beforeload event
    if([browserOptions.beforeload isKindOfClass:[NSString class]]){
        _beforeload = browserOptions.beforeload;
    }else{
        _beforeload = @"yes";
    }
    _waitForBeforeload = ![_beforeload isEqualToString:@""];

    [self.inAppBrowserViewController navigateTo:url];
    if (!browserOptions.hidden) {
        [self show:nil withNoAnimate:browserOptions.hidden];
    }
}

- (void)show:(CDVInvokedUrlCommand*)command{
    [self show:command withNoAnimate:NO];
}

- (void)show:(CDVInvokedUrlCommand*)command withNoAnimate:(BOOL)noAnimate
{
    BOOL initHidden = NO;
    if(command == nil && noAnimate == YES){
        initHidden = YES;
    }

    if (self.inAppBrowserViewController == nil) {
        NSLog(@"Tried to show IAB after it was closed.");
        return;
    }

    __block CDVInAppBrowserNavigationController* nav = [[CDVInAppBrowserNavigationController alloc]
                                                        initWithRootViewController:self.inAppBrowserViewController];
    nav.orientationDelegate = self.inAppBrowserViewController;
    nav.navigationBarHidden = YES;
    nav.modalPresentationStyle = self.inAppBrowserViewController.modalPresentationStyle;
    nav.presentationController.delegate = self.inAppBrowserViewController;

    __weak CDVWKInAppBrowser* weakSelf = self;

    // Run later to avoid the "took a long time" log message.
    dispatch_async(dispatch_get_main_queue(), ^{
        if (weakSelf.inAppBrowserViewController != nil) {
            float osVersion = [[[UIDevice currentDevice] systemVersion] floatValue];
            __strong __typeof(weakSelf) strongSelf = weakSelf;
            if (!strongSelf->tmpWindow) {
                if (@available(iOS 13.0, *)) {
                    UIWindowScene *scene = strongSelf.viewController.view.window.windowScene;
                    if (scene) {
                        strongSelf->tmpWindow = [[UIWindow alloc] initWithWindowScene:scene];
                    }
                }

                if (!strongSelf->tmpWindow) {
                    CGRect frame = [[UIScreen mainScreen] bounds];
                    if(initHidden && osVersion < 11){
                       frame.origin.x = -10000;
                    }
                    strongSelf->tmpWindow = [[UIWindow alloc] initWithFrame:frame];
                }
            }
            UIViewController *tmpController = [[UIViewController alloc] init];
            [strongSelf->tmpWindow setRootViewController:tmpController];
            [strongSelf->tmpWindow setWindowLevel:UIWindowLevelNormal];

            if(!initHidden || osVersion < 11){
                [self->tmpWindow makeKeyAndVisible];
            }
            [tmpController presentViewController:nav animated:!noAnimate completion:nil];
        }
    });
}

- (void)hide:(CDVInvokedUrlCommand*)command
{
    // Set tmpWindow to hidden to make main webview responsive to touch again
    // https://stackoverflow.com/questions/4544489/how-to-remove-a-uiwindow
    self->tmpWindow.hidden = YES;
    self->tmpWindow = nil;

    if (self.inAppBrowserViewController == nil) {
        NSLog(@"Tried to hide IAB after it was closed.");
        return;


    }

    // Run later to avoid the "took a long time" log message.
    dispatch_async(dispatch_get_main_queue(), ^{
        if (self.inAppBrowserViewController != nil) {
            [self.inAppBrowserViewController.presentingViewController dismissViewControllerAnimated:YES completion:nil];
        }
    });
}

- (void)openInCordovaWebView:(NSURL*)url withOptions:(NSString*)options
{
    NSURLRequest* request = [NSURLRequest requestWithURL:url];
    // the webview engine itself will filter for this according to <allow-navigation> policy
    // in config.xml
    [self.webViewEngine loadRequest:request];
}

- (void)openInSystem:(NSURL*)url
{
    [[UIApplication sharedApplication] openURL:url options:@{} completionHandler:^(BOOL success) {
        if (!success) {
            [[NSNotificationCenter defaultCenter] postNotification:[NSNotification notificationWithName:CDVPluginHandleOpenURLNotification object:url]];
        }
    }];
}

- (void)loadAfterBeforeload:(CDVInvokedUrlCommand*)command
{
    NSString* urlStr = [command argumentAtIndex:0];

    if ([_beforeload isEqualToString:@""]) {
        NSLog(@"unexpected loadAfterBeforeload called without feature beforeload=get|post");
    }
    if (self.inAppBrowserViewController == nil) {
        NSLog(@"Tried to invoke loadAfterBeforeload on IAB after it was closed.");
        return;
    }
    if (urlStr == nil) {
        NSLog(@"loadAfterBeforeload called with nil argument, ignoring.");
        return;
    }

    NSURL* url = [NSURL URLWithString:urlStr];
    //_beforeload = @"";
    _waitForBeforeload = NO;
    [self.inAppBrowserViewController navigateTo:url];
}

// This is a helper method for the inject{Script|Style}{Code|File} API calls, which
// provides a consistent method for injecting JavaScript code into the document.
//
// If a wrapper string is supplied, then the source string will be JSON-encoded (adding
// quotes) and wrapped using string formatting. (The wrapper string should have a single
// '%@' marker).
//
// If no wrapper is supplied, then the source string is executed directly.

- (void)injectDeferredObject:(NSString*)source withWrapper:(NSString*)jsWrapper
{
    // Ensure a message handler bridge is created to communicate with the CDVWKInAppBrowserViewController
    [self evaluateJavaScript: [NSString stringWithFormat:@"(function(w){if(!w._cdvMessageHandler) {w._cdvMessageHandler = function(id,d){w.webkit.messageHandlers.%@.postMessage({d:d, id:id});}}})(window)", IAB_BRIDGE_NAME]];

    if (jsWrapper != nil) {
        NSData* jsonData = [NSJSONSerialization dataWithJSONObject:@[source] options:0 error:nil];
        NSString* sourceArrayString = [[NSString alloc] initWithData:jsonData encoding:NSUTF8StringEncoding];
        if (sourceArrayString) {
            NSString* sourceString = [sourceArrayString substringWithRange:NSMakeRange(1, [sourceArrayString length] - 2)];
            NSString* jsToInject = [NSString stringWithFormat:jsWrapper, sourceString];
            [self evaluateJavaScript:jsToInject];
        }
    } else {
        [self evaluateJavaScript:source];
    }
}


//Synchronus helper for javascript evaluation
- (void)evaluateJavaScript:(NSString *)script {
    __block NSString* _script = script;
    [self.inAppBrowserViewController.webView evaluateJavaScript:script completionHandler:^(id result, NSError *error) {
        if (error == nil) {
            if (result != nil) {
                NSLog(@"%@", result);
            }
        } else {
            NSLog(@"evaluateJavaScript error : %@ : %@", error.localizedDescription, _script);
        }
    }];
}

- (void)injectScriptCode:(CDVInvokedUrlCommand*)command
{
    NSString* jsWrapper = nil;

    if ((command.callbackId != nil) && ![command.callbackId isEqualToString:@"INVALID"]) {
        jsWrapper = [NSString stringWithFormat:@"_cdvMessageHandler('%@',JSON.stringify([eval(%%@)]));", command.callbackId];
    }
    [self injectDeferredObject:[command argumentAtIndex:0] withWrapper:jsWrapper];
}

- (void)injectScriptFile:(CDVInvokedUrlCommand*)command
{
    NSString* jsWrapper;

    if ((command.callbackId != nil) && ![command.callbackId isEqualToString:@"INVALID"]) {
        jsWrapper = [NSString stringWithFormat:@"(function(d) { var c = d.createElement('script'); c.src = %%@; c.onload = function() { _cdvMessageHandler('%@'); }; d.body.appendChild(c); })(document)", command.callbackId];
    } else {
        jsWrapper = @"(function(d) { var c = d.createElement('script'); c.src = %@; d.body.appendChild(c); })(document)";
    }
    [self injectDeferredObject:[command argumentAtIndex:0] withWrapper:jsWrapper];
}

- (void)injectStyleCode:(CDVInvokedUrlCommand*)command
{
    NSString* jsWrapper;

    if ((command.callbackId != nil) && ![command.callbackId isEqualToString:@"INVALID"]) {
        jsWrapper = [NSString stringWithFormat:@"(function(d) { var c = d.createElement('style'); c.innerHTML = %%@; c.onload = function() { _cdvMessageHandler('%@'); }; d.body.appendChild(c); })(document)", command.callbackId];
    } else {
        jsWrapper = @"(function(d) { var c = d.createElement('style'); c.innerHTML = %@; d.body.appendChild(c); })(document)";
    }
    [self injectDeferredObject:[command argumentAtIndex:0] withWrapper:jsWrapper];
}

- (void)injectStyleFile:(CDVInvokedUrlCommand*)command
{
    NSString* jsWrapper;

    if ((command.callbackId != nil) && ![command.callbackId isEqualToString:@"INVALID"]) {
        jsWrapper = [NSString stringWithFormat:@"(function(d) { var c = d.createElement('link'); c.rel='stylesheet'; c.type='text/css'; c.href = %%@; c.onload = function() { _cdvMessageHandler('%@'); }; d.body.appendChild(c); })(document)", command.callbackId];
    } else {
        jsWrapper = @"(function(d) { var c = d.createElement('link'); c.rel='stylesheet', c.type='text/css'; c.href = %@; d.body.appendChild(c); })(document)";
    }
    [self injectDeferredObject:[command argumentAtIndex:0] withWrapper:jsWrapper];
}

- (BOOL)isValidCallbackId:(NSString *)callbackId
{
    NSError *err = nil;
    // Initialize on first use
    if (self.callbackIdPattern == nil) {
        self.callbackIdPattern = [NSRegularExpression regularExpressionWithPattern:@"^InAppBrowser[0-9]{1,10}$" options:0 error:&err];
        if (err != nil) {
            // Couldn't initialize Regex; No is safer than Yes.
            return NO;
        }
    }
    if ([self.callbackIdPattern firstMatchInString:callbackId options:0 range:NSMakeRange(0, [callbackId length])]) {
        return YES;
    }
    return NO;
}

/**
 * The message handler bridge provided for the InAppBrowser is capable of executing any oustanding callback belonging
 * to the InAppBrowser plugin. Care has been taken that other callbacks cannot be triggered, and that no
 * other code execution is possible.
 */
- (void)webView:(WKWebView *)theWebView decidePolicyForNavigationAction:(WKNavigationAction *)navigationAction decisionHandler:(void (^)(WKNavigationActionPolicy))decisionHandler {

    NSURL* url = navigationAction.request.URL;
    NSURL* mainDocumentURL = navigationAction.request.mainDocumentURL;
    BOOL isTopLevelNavigation = [url isEqual:mainDocumentURL];
    BOOL shouldStart = YES;
    BOOL useBeforeLoad = NO;
    NSString* httpMethod = navigationAction.request.HTTPMethod;
    NSString* errorMessage = nil;

    if([_beforeload isEqualToString:@"post"]){
        //TODO handle POST requests by preserving POST data then remove this condition
        errorMessage = @"beforeload doesn't yet support POST requests";
    }
    else if(isTopLevelNavigation && (
           [_beforeload isEqualToString:@"yes"]
       || ([_beforeload isEqualToString:@"get"] && [httpMethod isEqualToString:@"GET"])
    // TODO comment in when POST requests are handled
    // || ([_beforeload isEqualToString:@"post"] && [httpMethod isEqualToString:@"POST"])
    )){
        useBeforeLoad = YES;
    }

    // When beforeload, on first URL change, initiate JS callback. Only after the beforeload event, continue.
    if (_waitForBeforeload && useBeforeLoad) {
        CDVPluginResult* pluginResult = [CDVPluginResult resultWithStatus:CDVCommandStatus_OK
                                                      messageAsDictionary:@{@"type":@"beforeload", @"url":[url absoluteString]}];
        [pluginResult setKeepCallback:[NSNumber numberWithBool:YES]];

        [self.commandDelegate sendPluginResult:pluginResult callbackId:self.callbackId];
        decisionHandler(WKNavigationActionPolicyCancel);
        return;
    }

    if(errorMessage != nil){
        NSLog(errorMessage);
        CDVPluginResult* pluginResult = [CDVPluginResult resultWithStatus:CDVCommandStatus_ERROR
                                                      messageAsDictionary:@{@"type":@"loaderror", @"url":[url absoluteString], @"code": @"-1", @"message": errorMessage}];
        [pluginResult setKeepCallback:[NSNumber numberWithBool:YES]];
        [self.commandDelegate sendPluginResult:pluginResult callbackId:self.callbackId];
    }

    //if is an app store, tel, sms, mailto or geo link, let the system handle it, otherwise it fails to load it
    NSArray * allowedSchemes = @[@"itms-appss", @"itms-apps", @"tel", @"sms", @"mailto", @"geo"];
    if ([allowedSchemes containsObject:[url scheme]]) {
        [theWebView stopLoading];
        [self openInSystem:url];
        shouldStart = NO;
    }
    else if ((self.callbackId != nil) && isTopLevelNavigation) {
        // Send a loadstart event for each top-level navigation (includes redirects).
        CDVPluginResult* pluginResult = [CDVPluginResult resultWithStatus:CDVCommandStatus_OK
                                                      messageAsDictionary:@{@"type":@"loadstart", @"url":[url absoluteString]}];
        [pluginResult setKeepCallback:[NSNumber numberWithBool:YES]];

        [self.commandDelegate sendPluginResult:pluginResult callbackId:self.callbackId];
    }

    if (useBeforeLoad) {
        _waitForBeforeload = YES;
    }

    if(shouldStart){
        // Fix GH-417 & GH-424: Handle non-default target attribute
        // Based on https://stackoverflow.com/a/25713070/777265
        if (!navigationAction.targetFrame){
            [theWebView loadRequest:navigationAction.request];
            decisionHandler(WKNavigationActionPolicyCancel);
        }else{
            decisionHandler(WKNavigationActionPolicyAllow);
        }
    }else{
        decisionHandler(WKNavigationActionPolicyCancel);
    }
}

#pragma mark WKScriptMessageHandler delegate
- (void)userContentController:(nonnull WKUserContentController *)userContentController didReceiveScriptMessage:(nonnull WKScriptMessage *)message {

    CDVPluginResult* pluginResult = nil;

    if([message.body isKindOfClass:[NSDictionary class]]){
        NSDictionary* messageContent = (NSDictionary*) message.body;
        NSString* scriptCallbackId = messageContent[@"id"];

        if([messageContent objectForKey:@"d"]){
            NSString* scriptResult = messageContent[@"d"];
            NSError* __autoreleasing error = nil;
            NSData* decodedResult = [NSJSONSerialization JSONObjectWithData:[scriptResult dataUsingEncoding:NSUTF8StringEncoding] options:kNilOptions error:&error];
            if ((error == nil) && [decodedResult isKindOfClass:[NSArray class]]) {
                pluginResult = [CDVPluginResult resultWithStatus:CDVCommandStatus_OK messageAsArray:(NSArray*)decodedResult];
            } else {
                pluginResult = [CDVPluginResult resultWithStatus:CDVCommandStatus_JSON_EXCEPTION];
            }
        } else {
            pluginResult = [CDVPluginResult resultWithStatus:CDVCommandStatus_OK messageAsArray:@[]];
        }
        [self.commandDelegate sendPluginResult:pluginResult callbackId:scriptCallbackId];
    }else if(self.callbackId != nil){
        // Send a message event
        NSString* messageContent = (NSString*) message.body;
        NSError* __autoreleasing error = nil;
        NSData* decodedResult = [NSJSONSerialization JSONObjectWithData:[messageContent dataUsingEncoding:NSUTF8StringEncoding] options:kNilOptions error:&error];
        if (error == nil) {
            NSMutableDictionary* dResult = [NSMutableDictionary new];
            [dResult setValue:@"message" forKey:@"type"];
            [dResult setObject:decodedResult forKey:@"data"];
            CDVPluginResult* pluginResult = [CDVPluginResult resultWithStatus:CDVCommandStatus_OK messageAsDictionary:dResult];
            [pluginResult setKeepCallback:[NSNumber numberWithBool:YES]];
            [self.commandDelegate sendPluginResult:pluginResult callbackId:self.callbackId];
        }
    }
}

- (void)didStartProvisionalNavigation:(WKWebView*)theWebView
{
//    self.inAppBrowserViewController.currentURL = theWebView.URL;
}

- (void)didFinishNavigation:(WKWebView*)theWebView
{
    if (self.callbackId != nil) {
        NSString* url = [theWebView.URL absoluteString];
        if(url == nil){
            if(self.inAppBrowserViewController.currentURL != nil){
                url = [self.inAppBrowserViewController.currentURL absoluteString];
            }else{
                url = @"";
            }
        }
        CDVPluginResult* pluginResult = [CDVPluginResult resultWithStatus:CDVCommandStatus_OK
                                                      messageAsDictionary:@{@"type":@"loadstop", @"url":url}];
        [pluginResult setKeepCallback:[NSNumber numberWithBool:YES]];

        [self.commandDelegate sendPluginResult:pluginResult callbackId:self.callbackId];
    }
}

- (void)webView:(WKWebView*)theWebView didFailNavigation:(NSError*)error
{
    if (self.callbackId != nil) {
        NSString* url = [theWebView.URL absoluteString];
        if(url == nil){
            if(self.inAppBrowserViewController.currentURL != nil){
                url = [self.inAppBrowserViewController.currentURL absoluteString];
            }else{
                url = @"";
            }
        }
        CDVPluginResult* pluginResult = [CDVPluginResult resultWithStatus:CDVCommandStatus_ERROR
                                                      messageAsDictionary:@{@"type":@"loaderror", @"url":url, @"code": [NSNumber numberWithInteger:error.code], @"message": error.localizedDescription}];
        [pluginResult setKeepCallback:[NSNumber numberWithBool:YES]];

        [self.commandDelegate sendPluginResult:pluginResult callbackId:self.callbackId];
    }
}

- (void)browserExit
{
    if (self.callbackId != nil) {
        CDVPluginResult* pluginResult = [CDVPluginResult resultWithStatus:CDVCommandStatus_OK
                                                      messageAsDictionary:@{@"type":@"exit"}];
        [self.commandDelegate sendPluginResult:pluginResult callbackId:self.callbackId];
        self.callbackId = nil;
    }

    [self.inAppBrowserViewController.configuration.userContentController removeScriptMessageHandlerForName:IAB_BRIDGE_NAME];
    self.inAppBrowserViewController.configuration = nil;

    [self.inAppBrowserViewController.webView stopLoading];
    [self.inAppBrowserViewController.webView removeFromSuperview];
    [self.inAppBrowserViewController.webView setUIDelegate:nil];
    [self.inAppBrowserViewController.webView setNavigationDelegate:nil];
    self.inAppBrowserViewController.webView = nil;

    // Set navigationDelegate to nil to ensure no callbacks are received from it.
    self.inAppBrowserViewController.navigationDelegate = nil;
    self.inAppBrowserViewController = nil;

    // Set tmpWindow to hidden to make main webview responsive to touch again
    // Based on https://stackoverflow.com/questions/4544489/how-to-remove-a-uiwindow
    self->tmpWindow.hidden = YES;
    self->tmpWindow = nil;
}

@end //CDVWKInAppBrowser

#pragma mark CDVWKInAppBrowserViewController

@implementation CDVWKInAppBrowserViewController

@synthesize currentURL;

CGFloat lastReducedStatusBarHeight = 0.0;
BOOL isExiting = FALSE;

- (id)initWithBrowserOptions: (CDVInAppBrowserOptions*) browserOptions andSettings:(NSDictionary *)settings
{
    self = [super init];
    if (self != nil) {
        _browserOptions = browserOptions;
        _settings = settings;
        self.webViewUIDelegate = [[CDVWKInAppBrowserUIDelegate alloc] initWithTitle:[[NSBundle mainBundle] objectForInfoDictionaryKey:@"CFBundleDisplayName"]];
        [self.webViewUIDelegate setViewController:self];

        [self createViews];
    }

    return self;
}

-(void)dealloc {
    //NSLog(@"dealloc");
}

- (void)createViews
{
    // We create the views in code for primarily for ease of upgrades and not requiring an external .xib to be included

    CGFloat bottomPadding = 0;
    if (@available(iOS 11.0, *)) {
        UIWindow *window = UIApplication.sharedApplication.windows.firstObject;
        bottomPadding = window.safeAreaInsets.bottom;
    }

    CGRect webViewBounds = self.view.bounds;
    BOOL toolbarIsAtBottom = false; // ![_browserOptions.toolbarposition isEqualToString:kInAppBrowserToolbarBarPositionTop];
    if (!_browserOptions.hidenavigationbuttons) {
        webViewBounds.size.height = webViewBounds.size.height - TOOLBAR_HEIGHT - TOOLBAR_HEIGHT - bottomPadding;
    } else {
        webViewBounds.size.height = webViewBounds.size.height - TOOLBAR_HEIGHT;
    }

    WKUserContentController* userContentController = [[WKUserContentController alloc] init];

    WKWebViewConfiguration* configuration = [[WKWebViewConfiguration alloc] init];

    NSString *userAgent = configuration.applicationNameForUserAgent;
    if (
        [self settingForKey:@"OverrideUserAgent"] == nil &&
        [self settingForKey:@"AppendUserAgent"] != nil
        ) {
        userAgent = [NSString stringWithFormat:@"%@ %@", userAgent, [self settingForKey:@"AppendUserAgent"]];
    }
    configuration.applicationNameForUserAgent = userAgent;
    configuration.userContentController = userContentController;
#if __has_include(<Cordova/CDVWebViewProcessPoolFactory.h>)
    configuration.processPool = [[CDVWebViewProcessPoolFactory sharedFactory] sharedProcessPool];
#elif __has_include("CDVWKProcessPoolFactory.h")
    configuration.processPool = [[CDVWKProcessPoolFactory sharedFactory] sharedProcessPool];
#endif
    [configuration.userContentController addScriptMessageHandler:self name:IAB_BRIDGE_NAME];

    //WKWebView options
    configuration.allowsInlineMediaPlayback = _browserOptions.allowinlinemediaplayback;
    configuration.ignoresViewportScaleLimits = _browserOptions.enableviewportscale;
    if(_browserOptions.mediaplaybackrequiresuseraction == YES){
        configuration.mediaTypesRequiringUserActionForPlayback = WKAudiovisualMediaTypeAll;
    }else{
        configuration.mediaTypesRequiringUserActionForPlayback = WKAudiovisualMediaTypeNone;
    }

    if (@available(iOS 13.0, *)) {
        NSString *contentMode = [self settingForKey:@"PreferredContentMode"];
        if ([contentMode isEqual: @"mobile"]) {
            configuration.defaultWebpagePreferences.preferredContentMode = WKContentModeMobile;
        } else if ([contentMode  isEqual: @"desktop"]) {
            configuration.defaultWebpagePreferences.preferredContentMode = WKContentModeDesktop;
        }

    }


    self.webView = [[WKWebView alloc] initWithFrame:webViewBounds configuration:configuration];

#if __IPHONE_OS_VERSION_MAX_ALLOWED >= 160400
    // With the introduction of iOS 16.4 the webview is no longer inspectable by default.
    // We'll honor that change for release builds, but will still allow inspection on debug builds by default.
    // We also introduce an override option, so consumers can influence this decision in their own build.
    if (@available(iOS 16.4, *)) {
#ifdef DEBUG
        BOOL allowWebviewInspectionDefault = YES;
#else
        BOOL allowWebviewInspectionDefault = NO;
#endif
        self.webView.inspectable = [_settings cordovaBoolSettingForKey:@"InspectableWebview" defaultValue:allowWebviewInspectionDefault];
    }
#endif


    [self.view addSubview:self.webView];
    [self.view sendSubviewToBack:self.webView];


    self.webView.navigationDelegate = self;
    self.webView.UIDelegate = self.webViewUIDelegate;
    self.webView.backgroundColor = [UIColor whiteColor];
    if ([self settingForKey:@"OverrideUserAgent"] != nil) {
        self.webView.customUserAgent = [self settingForKey:@"OverrideUserAgent"];
    }

    self.webView.clearsContextBeforeDrawing = YES;
    self.webView.clipsToBounds = YES;
    self.webView.contentMode = UIViewContentModeScaleToFill;
    self.webView.multipleTouchEnabled = YES;
    self.webView.opaque = YES;
    self.webView.userInteractionEnabled = YES;
    self.automaticallyAdjustsScrollViewInsets = YES ;
    [self.webView setAutoresizingMask:UIViewAutoresizingFlexibleHeight | UIViewAutoresizingFlexibleWidth];
    self.webView.allowsLinkPreview = NO;
    self.webView.allowsBackForwardNavigationGestures = NO;

    // For iOS 26, allow automatic content inset adjustment for safe areas
    if ([self isIOS26OrLater]) {
        [self.webView.scrollView setContentInsetAdjustmentBehavior:UIScrollViewContentInsetAdjustmentAutomatic];
    } else {
        [self.webView.scrollView setContentInsetAdjustmentBehavior:UIScrollViewContentInsetAdjustmentNever];
    }

    self.spinner = [[UIActivityIndicatorView alloc] initWithActivityIndicatorStyle:UIActivityIndicatorViewStyleGray];
    self.spinner.alpha = 1.000;
    self.spinner.autoresizesSubviews = YES;
    self.spinner.autoresizingMask = (UIViewAutoresizingFlexibleLeftMargin | UIViewAutoresizingFlexibleTopMargin | UIViewAutoresizingFlexibleBottomMargin | UIViewAutoresizingFlexibleRightMargin);
    self.spinner.clearsContextBeforeDrawing = NO;
    self.spinner.clipsToBounds = NO;
    self.spinner.contentMode = UIViewContentModeScaleToFill;
    self.spinner.frame = CGRectMake(CGRectGetMidX(self.webView.frame), CGRectGetMidY(self.webView.frame), 20.0, 20.0);
    self.spinner.hidden = NO;
    self.spinner.hidesWhenStopped = YES;
    self.spinner.multipleTouchEnabled = NO;
    self.spinner.opaque = NO;
    self.spinner.userInteractionEnabled = NO;
    [self.spinner stopAnimating];

    // Create the close button with custom caption/color if provided
    // For iOS 26, we create it properly from the start to avoid showing the checkmark
    if (_browserOptions.closebuttoncaption != nil || _browserOptions.closebuttoncolor != nil) {
        // Custom title provided
        NSString* title = _browserOptions.closebuttoncaption;
        NSString* colorString = _browserOptions.closebuttoncolor;
        
        self.closeButton = title != nil ?
            [[UIBarButtonItem alloc] initWithTitle:title style:UIBarButtonItemStylePlain target:self action:@selector(close)] :
            [[UIBarButtonItem alloc] initWithBarButtonSystemItem:UIBarButtonSystemItemDone target:self action:@selector(close)];
        self.closeButton.enabled = YES;
        self.closeButton.tintColor = colorString != nil ?
            [self colorFromHexString:colorString] :
            [UIColor colorWithRed:60.0 / 255.0 green:136.0 / 255.0 blue:230.0 / 255.0 alpha:1];
    } else {
        // No custom title - use system Done button
        self.closeButton = [[UIBarButtonItem alloc] initWithBarButtonSystemItem:UIBarButtonSystemItemDone target:self action:@selector(close)];
        self.closeButton.enabled = YES;
    }

    UIBarButtonItem* flexibleSpaceButton = [[UIBarButtonItem alloc] initWithBarButtonSystemItem:UIBarButtonSystemItemFlexibleSpace target:nil action:nil];

    UIBarButtonItem* fixedSpaceButton = [[UIBarButtonItem alloc] initWithBarButtonSystemItem:UIBarButtonSystemItemFixedSpace target:nil action:nil];
    fixedSpaceButton.width = 20;

    UIBarButtonItem* fixedSpaceOppositeButton = [[UIBarButtonItem alloc] initWithBarButtonSystemItem:UIBarButtonSystemItemFixedSpace target:nil action:nil];
    fixedSpaceOppositeButton.width = 20;
    if (_browserOptions.closebuttoncaption != nil) {
        NSUInteger closeButtonCaptionLength = [_browserOptions.closebuttoncaption length];
        fixedSpaceOppositeButton.width = closeButtonCaptionLength * 10;
    }
    
    // For iOS 26, skip toolbar creation entirely - we'll only use a floating close button
    if (![self isIOS26OrLater]) {
        // Add extra spacing for older iOS where buttons might be larger
        CGFloat ios26ButtonSpacing = 0.0;

        float toolbarY = toolbarIsAtBottom ? self.view.bounds.size.height - TOOLBAR_HEIGHT : 0.0;
        CGRect toolbarFrame = CGRectMake(0.0, toolbarY, self.view.bounds.size.width, TOOLBAR_HEIGHT);

        self.toolbar = [[UIToolbar alloc] initWithFrame:toolbarFrame];
        self.toolbar.alpha = 1.000;
        self.toolbar.autoresizesSubviews = YES;
        self.toolbar.autoresizingMask = toolbarIsAtBottom ? (UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleTopMargin) : UIViewAutoresizingFlexibleWidth;
        self.toolbar.barStyle = UIBarStyleBlackOpaque;
        
        self.toolbar.clearsContextBeforeDrawing = NO;
        self.toolbar.clipsToBounds = NO;
        self.toolbar.contentMode = UIViewContentModeScaleToFill;
        self.toolbar.hidden = NO;
        self.toolbar.multipleTouchEnabled = NO;
        self.toolbar.opaque = NO;
        self.toolbar.userInteractionEnabled = YES;
        
        if (_browserOptions.toolbarcolor != nil) { // Set toolbar color if user sets it in options
          self.toolbar.barTintColor = [self colorFromHexString:_browserOptions.toolbarcolor];
        }

        // For older iOS: enable overlay/transparent top bar only if explicitly requested
        BOOL toolbarOverlayEnabled = _browserOptions.toolbaroverlay;
        
        if (toolbarOverlayEnabled) {
            // Explicit overlay option for older iOS
            self.toolbar.translucent = YES;
            if (@available(iOS 15.0, *)) {
                UIToolbarAppearance* appearance = [[UIToolbarAppearance alloc] init];
                [appearance configureWithTransparentBackground];
                appearance.backgroundEffect = [UIBlurEffect effectWithStyle:UIBlurEffectStyleSystemChromeMaterial];
                self.toolbar.standardAppearance = appearance;
                self.toolbar.scrollEdgeAppearance = appearance;
                self.toolbar.compactAppearance = appearance;
            } else if (@available(iOS 13.0, *)) {
                UIToolbarAppearance* appearance = [[UIToolbarAppearance alloc] init];
                [appearance configureWithTransparentBackground];
                appearance.backgroundEffect = [UIBlurEffect effectWithStyle:UIBlurEffectStyleRegular];
                self.toolbar.standardAppearance = appearance;
            }
            self.toolbar.layer.mask = nil;
        } else {
            // Non-overlay toolbar
            if (!_browserOptions.toolbartranslucent) {
                self.toolbar.translucent = NO;
            }
            // Rounded corners for non-overlay toolbar
            CAShapeLayer * maskLayer = [CAShapeLayer layer];
            maskLayer.path = [UIBezierPath bezierPathWithRoundedRect: self.toolbar.bounds byRoundingCorners: UIRectCornerTopLeft | UIRectCornerTopRight cornerRadii: (CGSize){10.0, 10.}].CGPath;
            self.toolbar.layer.mask = maskLayer;
        }
    }

    float locationBarY = toolbarIsAtBottom ? self.view.bounds.size.height - FOOTER_HEIGHT : self.view.bounds.size.height - TOOLBAR_HEIGHT;

    self.addressLabel = [[UILabel alloc] initWithFrame:CGRectMake(20, locationBarY, 220, LOCATIONBAR_HEIGHT)];
    // For iOS 26, use smaller font size with centered text and ellipsis
    if ([self isIOS26OrLater]) {
        self.addressLabel.font = [UIFont systemFontOfSize:13 weight:UIFontWeightMedium];
        // Use iOS system blue (same as close button)
        self.addressLabel.textColor = [UIColor colorWithRed:60.0 / 255.0 green:136.0 / 255.0 blue:230.0 / 255.0 alpha:1];
        self.addressLabel.textAlignment = NSTextAlignmentCenter;
        self.addressLabel.lineBreakMode = NSLineBreakByTruncatingTail; // Ellipsis at the end
        
        // Add shadow for readability over any background (like system UI)
        self.addressLabel.layer.shadowColor = [[UIColor blackColor] CGColor];
        self.addressLabel.layer.shadowOffset = CGSizeMake(0, 1);
        self.addressLabel.layer.shadowOpacity = 0.4;
        self.addressLabel.layer.shadowRadius = 2;
        self.addressLabel.layer.masksToBounds = NO;
    } else {
        self.addressLabel.font = [UIFont systemFontOfSize:self.addressLabel.font.pointSize weight:UIFontWeightSemibold];
        self.addressLabel.textColor = [UIColor colorWithWhite:1.000 alpha:1.000];
    }
    self.addressLabel.text = NSLocalizedString(@"Loading...", nil);
    self.addressLabel.clipsToBounds = NO; // Allow shadow to show

    NSString *base64String = @"data:image/png;base64,iVBORw0KGgoAAAANSUhEUgAAAGAAAABgCAMAAADVRocKAAABMlBMVEUAAAD///////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////8t10FaAAAAZXRSTlMAAgMECAkKCwwNFRYZGhscHR4gISMkJidERkdISUpMTU5QWFpbXGJjZGdpamtsbW5vkJGSk5SYmZqbnJ6ipKaqr7G1tre4xMXGy83Oz9fY2drb4eLj5OXq7O3x8vP0+Pn6+/z9/hZ3hm4AAAABYktHRGW13YifAAAB2ElEQVRo3u2ZV1MCMRSFFywUEbAgChZsWGgKVlRUFAvI2lARFqWY//8XdLIrg7jMJDd5cJx7Hu+ZOd9N5u7OJqsozPJFM4XXer1cyETGFenqW7oiHbpctMrND96RLqlTEuMH08REewOy8ofyxFTXTkn5KukhVQphsN3/Qyrgt9n8ga3H9hr6JQC+978Ubg+OdeXJKO5ImB8j6sTeWXWcGuVJ4fk35nPT8rNuSer1oujzsGz0b+k2LMYaFgQB+vNbsv92HM/UuhDL9+lths28VWp9jAkBIvp8mm60tUTNNSFAhmakzM1tah4JAW5oRtDcnKFmXghQphkT5qafmi9CgHeaYTc37dR8EwLoQwRzEYAABCAAAQhAAAL+CWAknlNrhEE1NRfzcse7d5uEQ63jUb78eY1wqhriyd9oEW61Ehz9A/K/CMxr8GgEpOowI+CAALXPOJ9NKKDpYQIkCFhRJsA5HJBlAtzDASoTQIMDNI4XHEwIQAACEIAABCAAAQhAAAIkfb5XmAC3cEDxbxyhYnDAOhPACz7GNtiOsUoaCmD9P+6uAmfIxXpZMQ3apNYc+3VLAnKdE+e5MApx71Jllu/Ky5lscLV/6FJ45YmeFZneGloxG+k9n59e1Kzb8nzyBQAAAABJRU5ErkJggg==";

    // For iOS 26, calculate customView width based on screen width
    // Layout: [8px footer padding | back(44px) | 8px | location | 8px | forward(44px) | 8px footer padding]
    CGFloat customViewWidth;
    if ([self isIOS26OrLater]) {
        CGFloat screenWidth = self.view.bounds.size.width;
        // location width = screen width - (8px + 44px + 8px + 8px + 44px + 8px) = screen width - 120px
        customViewWidth = screenWidth - 168;
        if (customViewWidth < 100) customViewWidth = 100; // Minimum width
    } else {
        customViewWidth = 131;
    }
    
    UIView *customView = [[UIView alloc] initWithFrame:CGRectMake(0, 0, customViewWidth, 20)];
    customView.clipsToBounds = NO; // Allow shadow to show for iOS 26
    
    if ([self isIOS26OrLater]) {
        // For iOS 26: no icon, label with 4px padding on both sides (inner padding)
        self.addressLabel.frame = CGRectMake(4, 0, customViewWidth - 8, 20);
        self.addressLabel.autoresizingMask = UIViewAutoresizingFlexibleWidth;
        
        [customView addSubview:self.addressLabel];
    } else {
        // Original layout for older iOS
        NSURL *url = [NSURL URLWithString:base64String];
        NSData *imageData = [NSData dataWithContentsOfURL:url];
        UIImageView *imageView = [[UIImageView alloc] initWithImage:[UIImage imageWithData:imageData]];
        imageView.frame = CGRectMake(0, 0, 20, 20);
        self.addressLabel.frame = CGRectMake(25, 0, 111, 20);
        self.addressLabel.autoresizingMask = UIViewAutoresizingFlexibleWidth;
        [customView addSubview:imageView];
        [customView addSubview:self.addressLabel];
    }
    
    customView.autoresizingMask = UIViewAutoresizingFlexibleWidth;

    self.addressButton = [[UIBarButtonItem alloc] initWithCustomView:customView];

    NSString *base64ArrowLeftString = @"data:image/png;base64,iVBORw0KGgoAAAANSUhEUgAAAEAAAABABAMAAABYR2ztAAAALVBMVEUAAABQk/9Qk/9Plf9Ok/9Pk/9Olf9Ok/9PlP9PlP9PlP9PlP9PlP9PlP////9ofB/lAAAADXRSTlMASVBUVVdbXOLj5Pv8zg0BTAAAAAFiS0dEDm+9ME8AAABlSURBVEjHY2AYvkBrIX551r038SuIvnuTgAF3N+FV4H33TgI+eZa9d4+NGjBqAO0N0L57OwCvgrV3tzJQpoCgFcx77x7Hb4T13TsFo0aMGjEQRhAszAlWB0AjbhCokjQbh1kdCwDe9HXz+dfFzgAAAABJRU5ErkJggg==";
    NSURL *arrowLeftUrl = [NSURL URLWithString:base64ArrowLeftString];
    NSData *arrowLeftimageData = [NSData dataWithContentsOfURL:arrowLeftUrl];
    UIImage *arrowLeftImage = [UIImage imageWithData:arrowLeftimageData];
    // UIImageView *imageArrowLeftView = [[UIImageView alloc] initWithImage:[UIImage imageWithData:arrowLeftimageData]];
    // imageArrowLeftView.frame = CGRectMake(0, 0, 20, 20);
    CGSize targetSize = CGSizeMake(20, 20);
    // Create a new UIImage with the desired dimensions
    UIGraphicsBeginImageContextWithOptions(targetSize, NO, 0.0);
    [arrowLeftImage drawInRect:CGRectMake(0, 0, targetSize.width, targetSize.height)];
    UIImage *arrowLeftResizedImage = UIGraphicsGetImageFromCurrentImageContext();
    UIGraphicsEndImageContext();

    NSString *base64ArrowRightString = @"data:image/png;base64,iVBORw0KGgoAAAANSUhEUgAAAEAAAABABAMAAABYR2ztAAAAMFBMVEUAAABQk/9PlP9Qk/9Plf9Ok/9Pk/9Olf9Ok/9PlP9PlP9PlP9PlP9PlP9PlP////+HZFwHAAAADnRSTlMASUpQVFVXW1zi4+T7/MQrXuAAAAABYktHRA8YugDZAAAAYElEQVRIx2NgGF5AezMBBfveJBBQ8O4YfgU27wgYwXLu3Q38Rvi8e9swasSoEQNhBNu5d4fxG5Hz7hVlCghaEfPubQE+edZz766PGjBqAO0NIFiYE6wOCFYoUpMZhi8AALkege7oAWZaAAAAAElFTkSuQmCC";
    NSURL *arrowRightUrl = [NSURL URLWithString:base64ArrowRightString];
    NSData *arrowRightimageData = [NSData dataWithContentsOfURL:arrowRightUrl];
    UIImage *arrowRightImage = [UIImage imageWithData:arrowRightimageData];
    // Create a new UIImage with the desired dimensions
    UIGraphicsBeginImageContextWithOptions(targetSize, NO, 0.0);
    [arrowRightImage drawInRect:CGRectMake(0, 0, targetSize.width, targetSize.height)];
    UIImage *arrowRightResizedImage = UIGraphicsGetImageFromCurrentImageContext();
    UIGraphicsEndImageContext();

    // For iOS 26, use system chevron buttons for a native look
    if ([self isIOS26OrLater]) {
        if (@available(iOS 13.0, *)) {
            UIImage *chevronLeft = [UIImage systemImageNamed:@"chevron.left"];
            UIImage *chevronRight = [UIImage systemImageNamed:@"chevron.right"];
            
            // Create custom button views with explicit size to avoid constraint conflicts
            UIButton *backBtn = [UIButton buttonWithType:UIButtonTypeSystem];
            [backBtn setImage:chevronLeft forState:UIControlStateNormal];
            backBtn.frame = CGRectMake(0, 0, 44, 44);
            [backBtn addTarget:self action:@selector(goBack:) forControlEvents:UIControlEventTouchUpInside];
            
            UIButton *forwardBtn = [UIButton buttonWithType:UIButtonTypeSystem];
            [forwardBtn setImage:chevronRight forState:UIControlStateNormal];
            forwardBtn.frame = CGRectMake(0, 0, 44, 44);
            [forwardBtn addTarget:self action:@selector(goForward:) forControlEvents:UIControlEventTouchUpInside];
            
            self.backButton = [[UIBarButtonItem alloc] initWithCustomView:backBtn];
            self.forwardButton = [[UIBarButtonItem alloc] initWithCustomView:forwardBtn];
        } else {
            // Fallback for iOS < 13 (shouldn't happen on iOS 26, but for safety)
            self.backButton = [[UIBarButtonItem alloc] initWithImage:arrowLeftResizedImage style:UIBarButtonItemStylePlain target:self action:@selector(goBack:)];
            self.forwardButton = [[UIBarButtonItem alloc] initWithImage:arrowRightResizedImage style:UIBarButtonItemStylePlain target:self action:@selector(goForward:)];
        }
    } else {
        // Use custom images for older iOS versions
        self.forwardButton = [[UIBarButtonItem alloc] initWithImage:arrowRightResizedImage style:UIBarButtonItemStylePlain target:self action:@selector(goForward:)];
        self.backButton = [[UIBarButtonItem alloc] initWithImage:arrowLeftResizedImage style:UIBarButtonItemStylePlain target:self action:@selector(goBack:)];
    }
    
    // Enable buttons and set properties
    if ([self isIOS26OrLater] && self.forwardButton.customView) {
        UIButton *forwardBtn = (UIButton *)self.forwardButton.customView;
        [forwardBtn setEnabled:YES];
        
        // Add shadow for readability over any background (like system UI)
        forwardBtn.layer.shadowColor = [[UIColor blackColor] CGColor];
        forwardBtn.layer.shadowOffset = CGSizeMake(0, 1);
        forwardBtn.layer.shadowOpacity = 0.3;
        forwardBtn.layer.shadowRadius = 3;
        forwardBtn.layer.masksToBounds = NO;
    } else {
        self.forwardButton.enabled = YES;
        self.forwardButton.imageInsets = UIEdgeInsetsZero;
    }
    if (_browserOptions.navigationbuttoncolor != nil) { // Set button color if user sets it in options
        if ([self isIOS26OrLater] && self.forwardButton.customView) {
            // For iOS 26 with custom view, set tint on the UIButton
            [(UIButton *)self.forwardButton.customView setTintColor:[self colorFromHexString:_browserOptions.navigationbuttoncolor]];
        } else {
            self.forwardButton.tintColor = [self colorFromHexString:_browserOptions.navigationbuttoncolor];
        }
    } else if ([self isIOS26OrLater] && self.forwardButton.customView) {
        // Use iOS system blue (same as close button)
        [(UIButton *)self.forwardButton.customView setTintColor:[UIColor colorWithRed:60.0 / 255.0 green:136.0 / 255.0 blue:230.0 / 255.0 alpha:1]];
    }

    if ([self isIOS26OrLater] && self.backButton.customView) {
        UIButton *backBtn = (UIButton *)self.backButton.customView;
        [backBtn setEnabled:YES];
        
        // Add shadow for readability over any background (like system UI)
        backBtn.layer.shadowColor = [[UIColor blackColor] CGColor];
        backBtn.layer.shadowOffset = CGSizeMake(0, 1);
        backBtn.layer.shadowOpacity = 0.3;
        backBtn.layer.shadowRadius = 3;
        backBtn.layer.masksToBounds = NO;
    } else {
        self.backButton.enabled = YES;
        self.backButton.imageInsets = UIEdgeInsetsZero;
    }
    if (_browserOptions.navigationbuttoncolor != nil) { // Set button color if user sets it in options
        if ([self isIOS26OrLater] && self.backButton.customView) {
            // For iOS 26 with custom view, set tint on the UIButton
            [(UIButton *)self.backButton.customView setTintColor:[self colorFromHexString:_browserOptions.navigationbuttoncolor]];
        } else {
            self.backButton.tintColor = [self colorFromHexString:_browserOptions.navigationbuttoncolor];
        }
    } else if ([self isIOS26OrLater] && self.backButton.customView) {
        // Use iOS system blue (same as close button)
        [(UIButton *)self.backButton.customView setTintColor:[UIColor colorWithRed:60.0 / 255.0 green:136.0 / 255.0 blue:230.0 / 255.0 alpha:1]];
    }

    NSString *base64CloseString = @"data:image/png;base64,iVBORw0KGgoAAAANSUhEUgAAAEAAAABABAMAAABYR2ztAAAALVBMVEUAAABQk/9Qk/9Plf9Ok/9Pk/9Olf9Ok/9PlP9PlP9PlP9PlP9PlP9PlP////9ofB/lAAAADXRSTlMASVBUVVdbXOLj5Pv8zg0BTAAAAAFiS0dEDm+9ME8AAAEASURBVEjH7dW7DcIwEAbgSJAhYANghIxAQ0/DCKwAm0BPg0TpFlYgSm4XZFn2vR3Rx5UdW58s32+naeZW2vpufd3eSvcxHPR8G3pcAC+94Ajf0t+BJtoAzzJYBPjIBXsYTzjqYDzz+WWANxlqggOaEIAmJCAJBUhCA5wwAE5YACVMgBI2gIQDIOEBmXCBTPhAIipAImpAjNkQrPhRogrEXVR2kM5Ap1MESaXzr03GM+hqRDwD647wIFWIdIg+kavgErkKHoFldAgso03QHJgEzYFF8CAZBA+SJmQSFSGTKAkdZUHoKHPCuguMmHxInae4n3rM8a1eXa3ybi7zjxLbD/8a07ETLUOlAAAAAElFTkSuQmCC";
    NSURL *closeUrl = [NSURL URLWithString:base64CloseString];
    NSData *closeImageData = [NSData dataWithContentsOfURL:closeUrl];
    UIImage *closeImage = [UIImage imageWithData:closeImageData];
    // Create a new UIImage with the desired dimensions
    UIGraphicsBeginImageContextWithOptions(targetSize, NO, 0.0);
    [closeImage drawInRect:CGRectMake(0, 0, targetSize.width, targetSize.height)];
    UIImage *closeResizedImage = UIGraphicsGetImageFromCurrentImageContext();
    UIGraphicsEndImageContext();

    // For older iOS only: create toolbar items
    if (![self isIOS26OrLater]) {
        UIBarButtonItem *closeButton = [[UIBarButtonItem alloc] initWithImage:closeResizedImage style:UIBarButtonItemStylePlain target:self action:@selector(close)];
        closeButton.enabled = YES;
        closeButton.imageInsets = UIEdgeInsetsZero;
        if (_browserOptions.navigationbuttoncolor != nil) { // Set button color if user sets it in options
            closeButton.tintColor = [self colorFromHexString:_browserOptions.navigationbuttoncolor];
        }

        // Filter out Navigation Buttons if user requests so
        if (_browserOptions.hidenavigationbuttons) {
            if (_browserOptions.lefttoright) {
                [self.toolbar setItems:@[flexibleSpaceButton, self.closeButton]];
            } else {
                [self.toolbar setItems:@[self.closeButton, flexibleSpaceButton]];
            }
        } else if (_browserOptions.lefttoright) {
            [self.toolbar setItems:@[self.backButton, fixedSpaceButton, self.forwardButton, flexibleSpaceButton, self.closeButton]];
        } else {
            [self.toolbar setItems:@[self.closeButton, flexibleSpaceButton, self.addressButton]];
        }
    }

    // For iOS 26, position footer with small gap from bottom; for older iOS, above safe area
    float footerY;
    if ([self isIOS26OrLater]) {
        footerY = self.view.bounds.size.height - TOOLBAR_HEIGHT - 20.0; // 10px gap from bottom
    } else {
        footerY = self.view.bounds.size.height - TOOLBAR_HEIGHT - bottomPadding; // Above safe area
    }
    CGRect footerFrame = CGRectMake(0.0, footerY, self.view.bounds.size.width, TOOLBAR_HEIGHT);
    self.footer = [[UIToolbar alloc] initWithFrame:footerFrame];
    self.footer.alpha = 1.000;
    self.footer.autoresizesSubviews = YES;
    self.footer.autoresizingMask = (UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleTopMargin);
    
    // For iOS 26, make footer translucent with blur like Safari; for older iOS, use the configured style
    if ([self isIOS26OrLater]) {
        self.footer.barStyle = UIBarStyleDefault;
        self.footer.translucent = YES;
        
        // Safari-style blur effect with white tint
        if (@available(iOS 15.0, *)) {
            UIToolbarAppearance* appearance = [[UIToolbarAppearance alloc] init];
            [appearance configureWithDefaultBackground];
            appearance.backgroundEffect = [UIBlurEffect effectWithStyle:UIBlurEffectStyleSystemThinMaterial];
            appearance.backgroundColor = [[UIColor whiteColor] colorWithAlphaComponent:0.85];
            self.footer.standardAppearance = appearance;
            self.footer.scrollEdgeAppearance = appearance;
            self.footer.compactAppearance = appearance;
        } else {
            self.footer.backgroundColor = [[UIColor whiteColor] colorWithAlphaComponent:0.9];
        }
        
        // Add subtle top border
        CALayer *topBorder = [CALayer layer];
        topBorder.frame = CGRectMake(0, 0, self.view.bounds.size.width, 0.5);
        topBorder.backgroundColor = [[UIColor blackColor] colorWithAlphaComponent:0.1].CGColor;
        [self.footer.layer addSublayer:topBorder];
    } else {
        self.footer.barStyle = UIBarStyleBlackOpaque;
        if (_browserOptions.toolbarcolor != nil) { // Set toolbar color if user sets it in options
          self.footer.barTintColor = [self colorFromHexString:_browserOptions.toolbarcolor];
        }
        if (!_browserOptions.toolbartranslucent) { // Set toolbar translucent to no if user sets it in options
          self.footer.translucent = NO;
        }
    }
    
    self.footer.clearsContextBeforeDrawing = NO;
    self.footer.clipsToBounds = NO;
    self.footer.contentMode = UIViewContentModeScaleToFill;
    self.footer.hidden = NO;
    self.footer.multipleTouchEnabled = NO;
    self.footer.userInteractionEnabled = YES;
    
    // For iOS 26, make footer truly transparent with new layout: back/forward closer together, location on right
    if ([self isIOS26OrLater]) {
        self.footer.opaque = NO;
        self.footer.translucent = YES;
        // Set a completely transparent background
        [self.footer setBackgroundImage:[UIImage new] forToolbarPosition:UIBarPositionAny barMetrics:UIBarMetricsDefault];
        [self.footer setShadowImage:[UIImage new] forToolbarPosition:UIBarPositionAny];
        
        // iOS 26 layout: [8px | back | 8px | location | 8px | forward | flex | 8px]
        UIBarButtonItem* leadingPad = [[UIBarButtonItem alloc] initWithBarButtonSystemItem:UIBarButtonSystemItemFixedSpace target:nil action:nil];
        leadingPad.width = 8;
        
        UIBarButtonItem* space1 = [[UIBarButtonItem alloc] initWithBarButtonSystemItem:UIBarButtonSystemItemFixedSpace target:nil action:nil];
        space1.width = 8;
        
        UIBarButtonItem* space2 = [[UIBarButtonItem alloc] initWithBarButtonSystemItem:UIBarButtonSystemItemFixedSpace target:nil action:nil];
        space2.width = 8;
        
        UIBarButtonItem* flexSpace = [[UIBarButtonItem alloc] initWithBarButtonSystemItem:UIBarButtonSystemItemFlexibleSpace target:nil action:nil];
        
        UIBarButtonItem* trailingPad = [[UIBarButtonItem alloc] initWithBarButtonSystemItem:UIBarButtonSystemItemFixedSpace target:nil action:nil];
        trailingPad.width = 8;
        
        [self.footer setItems:@[leadingPad, self.backButton, space1, self.addressButton, space2, self.forwardButton, flexSpace, trailingPad]];
    } else {
        self.footer.opaque = NO;
        [self.footer setItems:@[self.backButton, fixedSpaceButton, self.forwardButton, flexibleSpaceButton]];
    }

    float safeBottomY = self.view.bounds.size.height - bottomPadding;
    // For iOS 26, no horizontal padding (matches footer)
    CGRect safeBottomFrame = CGRectMake(0.0, safeBottomY, self.view.bounds.size.width, bottomPadding);
    self.safeBottom = [[UIToolbar alloc] initWithFrame:safeBottomFrame];
    
    // For iOS 26, hide safeBottom (footer blur extends to cover it); for older iOS, use the configured color
    if ([self isIOS26OrLater]) {
        self.safeBottom.hidden = YES;
    } else {
        self.safeBottom.hidden = NO;
        if (_browserOptions.toolbarcolor != nil) { // Set toolbar color if user sets it in options
            self.safeBottom.barTintColor = [self colorFromHexString:_browserOptions.toolbarcolor];
        }
    }

    self.view.backgroundColor = [UIColor clearColor];
    
    // For iOS 26, create a floating close button instead of toolbar
    if ([self isIOS26OrLater]) {
        // Create a floating close button in iOS 26 style (circular with white background)
        UIButton* floatingCloseButton = [UIButton buttonWithType:UIButtonTypeSystem];
        [floatingCloseButton setTitle:_browserOptions.closebuttoncaption ? _browserOptions.closebuttoncaption : @"Cancel" forState:UIControlStateNormal];
        if (_browserOptions.closebuttoncolor != nil) {
            [floatingCloseButton setTintColor:[self colorFromHexString:_browserOptions.closebuttoncolor]];
        }
        floatingCloseButton.titleLabel.font = [UIFont systemFontOfSize:18 weight:UIFontWeightSemibold];
        [floatingCloseButton addTarget:self action:@selector(close) forControlEvents:UIControlEventTouchUpInside];
        
        // iOS 26 style: white background with subtle shadow
        if (@available(iOS 13.0, *)) {
            UIView* whiteBackgroundView = [[UIView alloc] init];
            whiteBackgroundView.backgroundColor = [UIColor whiteColor];
            whiteBackgroundView.layer.cornerRadius = 24;
            whiteBackgroundView.layer.masksToBounds = NO;
            whiteBackgroundView.layer.shadowColor = [UIColor blackColor].CGColor;
            whiteBackgroundView.layer.shadowOpacity = 0.15;
            whiteBackgroundView.layer.shadowOffset = CGSizeMake(0, 2);
            whiteBackgroundView.layer.shadowRadius = 8;
            whiteBackgroundView.translatesAutoresizingMaskIntoConstraints = NO;
            [self.view addSubview:whiteBackgroundView];
            
            floatingCloseButton.backgroundColor = [UIColor clearColor];
            floatingCloseButton.translatesAutoresizingMaskIntoConstraints = NO;
            [whiteBackgroundView addSubview:floatingCloseButton];
            
            // Position white background view at the top right with 10px top padding
            if (@available(iOS 11.0, *)) {
                CGFloat topInset = self.view.safeAreaInsets.top;
                [NSLayoutConstraint activateConstraints:@[
                    [whiteBackgroundView.topAnchor constraintEqualToAnchor:self.view.topAnchor constant:10],
                    [whiteBackgroundView.trailingAnchor constraintEqualToAnchor:self.view.safeAreaLayoutGuide.trailingAnchor constant:-12],
                    [whiteBackgroundView.heightAnchor constraintEqualToConstant:44 + topInset],
                    // Position button content below safe area
                    [floatingCloseButton.topAnchor constraintEqualToAnchor:whiteBackgroundView.topAnchor constant:topInset],
                    [floatingCloseButton.leadingAnchor constraintEqualToAnchor:whiteBackgroundView.leadingAnchor constant:18],
                    [floatingCloseButton.trailingAnchor constraintEqualToAnchor:whiteBackgroundView.trailingAnchor constant:-18],
                    [floatingCloseButton.heightAnchor constraintEqualToConstant:44]
                ]];
            } else {
                [NSLayoutConstraint activateConstraints:@[
                    [whiteBackgroundView.topAnchor constraintEqualToAnchor:self.view.topAnchor constant:10],
                    [whiteBackgroundView.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor constant:-12],
                    [whiteBackgroundView.heightAnchor constraintEqualToConstant:68],
                    [floatingCloseButton.topAnchor constraintEqualToAnchor:whiteBackgroundView.topAnchor constant:20],
                    [floatingCloseButton.leadingAnchor constraintEqualToAnchor:whiteBackgroundView.leadingAnchor constant:18],
                    [floatingCloseButton.trailingAnchor constraintEqualToAnchor:whiteBackgroundView.trailingAnchor constant:-18],
                    [floatingCloseButton.heightAnchor constraintEqualToConstant:48]
                ]];
            }
        } else {
            // Fallback for older iOS (shouldn't happen on iOS 26, but for safety)
            floatingCloseButton.backgroundColor = [[UIColor blackColor] colorWithAlphaComponent:0.3];
            floatingCloseButton.layer.cornerRadius = 20;
            floatingCloseButton.contentEdgeInsets = UIEdgeInsetsMake(8, 16, 8, 16);
            floatingCloseButton.translatesAutoresizingMaskIntoConstraints = NO;
            [self.view addSubview:floatingCloseButton];
            
            [NSLayoutConstraint activateConstraints:@[
                [floatingCloseButton.topAnchor constraintEqualToAnchor:self.view.topAnchor constant:32],
                [floatingCloseButton.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor constant:-12],
                [floatingCloseButton.heightAnchor constraintEqualToConstant:40]
            ]];
        }
    } else {
        // For older iOS: add toolbar to view
        [self.view addSubview:self.toolbar];
    }
    
    if (!_browserOptions.hidenavigationbuttons) {
        [self.view addSubview:self.footer];
        [self.view addSubview:self.safeBottom];
    }
    [self.view addSubview:self.spinner];
}

- (id)settingForKey:(NSString*)key
{
    return [_settings objectForKey:[key lowercaseString]];
}

- (void) setWebViewFrame : (CGRect) frame {
    NSLog(@"Setting the WebView's frame to %@", NSStringFromCGRect(frame));
    [self.webView setFrame:frame];
}

- (void)setCloseButtonTitle:(NSString*)title : (NSString*) colorString : (int) buttonIndex
{
    // For iOS 26, the close button was already created properly in createViews, so skip this to avoid duplicates
    if ([self isIOS26OrLater]) {
        return;
    }
    
    // the advantage of using UIBarButtonSystemItemDone is the system will localize it for you automatically
    // but, if you want to set this yourself, knock yourself out (we can't set the title for a system Done button, so we have to create a new one)
    self.closeButton = nil;
    // Initialize with title if title is set, otherwise the title will be 'Done' localized
    self.closeButton = title != nil ? [[UIBarButtonItem alloc] initWithTitle:title style:UIBarButtonItemStylePlain target:self action:@selector(close)] : [[UIBarButtonItem alloc] initWithBarButtonSystemItem:UIBarButtonSystemItemDone target:self action:@selector(close)];
    self.closeButton.enabled = YES;
    // If color on closebutton is requested then initialize with that that color, otherwise use initialize with default
    self.closeButton.tintColor = colorString != nil ? [self colorFromHexString:colorString] : [UIColor colorWithRed:60.0 / 255.0 green:136.0 / 255.0 blue:230.0 / 255.0 alpha:1];

    NSMutableArray* items = [self.toolbar.items mutableCopy];
    [items replaceObjectAtIndex:buttonIndex withObject:self.closeButton];
    [self.toolbar setItems:items];
}

- (void)showLocationBar:(BOOL)show
{
    CGRect locationbarFrame = self.addressLabel.frame;

    BOOL toolbarVisible = !self.toolbar.hidden;

    // prevent double show/hide
    if (show == !(self.addressLabel.hidden)) {
        return;
    }

    if (show) {
        self.addressLabel.hidden = NO;

        if (toolbarVisible) {
            // toolBar at the bottom, leave as is
            // put locationBar on top of the toolBar

            CGRect webViewBounds = self.view.bounds;
            webViewBounds.size.height -= FOOTER_HEIGHT;
            [self setWebViewFrame:webViewBounds];

            locationbarFrame.origin.y = webViewBounds.size.height;
            self.addressLabel.frame = locationbarFrame;
        } else {
            // no toolBar, so put locationBar at the bottom

            CGRect webViewBounds = self.view.bounds;
            webViewBounds.size.height -= LOCATIONBAR_HEIGHT;
            [self setWebViewFrame:webViewBounds];

            locationbarFrame.origin.y = webViewBounds.size.height;
            self.addressLabel.frame = locationbarFrame;
        }
    } else {
        self.addressLabel.hidden = YES;

        if (toolbarVisible) {
            // locationBar is on top of toolBar, hide locationBar

            // webView take up whole height less toolBar height
            CGRect webViewBounds = self.view.bounds;
            webViewBounds.size.height -= TOOLBAR_HEIGHT;
            [self setWebViewFrame:webViewBounds];
        } else {
            // no toolBar, expand webView to screen dimensions
            [self setWebViewFrame:self.view.bounds];
        }
    }
}

- (void)showToolBar:(BOOL)show : (NSString *) toolbarPosition
{
    CGRect toolbarFrame = self.toolbar.frame;
    CGRect locationbarFrame = self.addressLabel.frame;

    BOOL locationbarVisible = false; // !self.addressLabel.hidden;

    // prevent double show/hide
    if (show == !(self.toolbar.hidden)) {
        return;
    }

    if (show) {
        self.toolbar.hidden = NO;
        CGRect webViewBounds = self.view.bounds;

        if (locationbarVisible) {
            // locationBar at the bottom, move locationBar up
            // put toolBar at the bottom
            webViewBounds.size.height -= FOOTER_HEIGHT;
            locationbarFrame.origin.y = webViewBounds.size.height;
            self.addressLabel.frame = locationbarFrame;
            self.toolbar.frame = toolbarFrame;
        } else {
            // no locationBar, so put toolBar at the bottom
            CGRect webViewBounds = self.view.bounds;
            webViewBounds.size.height -= TOOLBAR_HEIGHT;
            self.toolbar.frame = toolbarFrame;
        }

        if ([toolbarPosition isEqualToString:kInAppBrowserToolbarBarPositionTop]) {
            toolbarFrame.origin.y = 0;
            webViewBounds.origin.y += toolbarFrame.size.height;
            [self setWebViewFrame:webViewBounds];
        } else {
            toolbarFrame.origin.y = (webViewBounds.size.height + LOCATIONBAR_HEIGHT);
        }
        // [self setWebViewFrame:webViewBounds];
        [self setWebViewFrame:self.view.bounds];

    } else {
        self.toolbar.hidden = YES;

        if (locationbarVisible) {
            // locationBar is on top of toolBar, hide toolBar
            // put locationBar at the bottom

            // webView take up whole height less locationBar height
            CGRect webViewBounds = self.view.bounds;
            // webViewBounds.size.height -= LOCATIONBAR_HEIGHT;
            [self setWebViewFrame:webViewBounds];

            // move locationBar down
            locationbarFrame.origin.y = webViewBounds.size.height;
            self.addressLabel.frame = locationbarFrame;
        } else {
            // no locationBar, expand webView to screen dimensions
            [self setWebViewFrame:self.view.bounds];
        }
    }
}

- (void)viewDidLoad
{
    [super viewDidLoad];
}

- (void)viewSafeAreaInsetsDidChange
{
    [super viewSafeAreaInsetsDidChange];
    
    // For iOS 26, set additional safe area insets to ensure content doesn't hide under floating bars
    // Only set once to avoid feedback loops
    if ([self isIOS26OrLater] && UIEdgeInsetsEqualToEdgeInsets(self.additionalSafeAreaInsets, UIEdgeInsetsZero)) {
        CGFloat topInset = 0;
        CGFloat bottomInset = 0;
        
        // Only reserve top space if navigation buttons are hidden (no footer)
        if (!_browserOptions.hidenavigationbuttons) {
            // Top: Button height (48px) + padding (12px) - safe area is already accounted for by the button position
            topInset = 48.0 + 12.0 + 12.0;
        }
        
        // Reserve bottom space if navigation buttons are shown (footer is visible)
        if (!_browserOptions.hidenavigationbuttons) {
            bottomInset = TOOLBAR_HEIGHT;
        }
        
        self.additionalSafeAreaInsets = UIEdgeInsetsMake(topInset, 0, bottomInset, 0);
    }
}

- (void)viewDidDisappear:(BOOL)animated
{
    [super viewDidDisappear:animated];
    if (isExiting && (self.navigationDelegate != nil) && [self.navigationDelegate respondsToSelector:@selector(browserExit)]) {
        [self.navigationDelegate browserExit];
        isExiting = FALSE;
    }
}

- (UIStatusBarStyle)preferredStatusBarStyle
{
    NSString* statusBarStylePreference = [self settingForKey:@"InAppBrowserStatusBarStyle"];
    if (statusBarStylePreference && [statusBarStylePreference isEqualToString:@"lightcontent"]) {
        return UIStatusBarStyleLightContent;
    } else if (statusBarStylePreference && [statusBarStylePreference isEqualToString:@"darkcontent"]) {
        if (@available(iOS 13.0, *)) {
            return UIStatusBarStyleDarkContent;
        } else {
            return UIStatusBarStyleDefault;
        }
    } else {
        return UIStatusBarStyleDefault;
    }
}

- (BOOL)prefersStatusBarHidden {
    return NO;
}

- (void)close
{
    self.currentURL = nil;

    __weak UIViewController* weakSelf = self;

    // Run later to avoid the "took a long time" log message.
    dispatch_async(dispatch_get_main_queue(), ^{
        isExiting = TRUE;
        lastReducedStatusBarHeight = 0.0;
        if ([weakSelf respondsToSelector:@selector(presentingViewController)]) {
            [[weakSelf presentingViewController] dismissViewControllerAnimated:YES completion:nil];
        } else {
            [[weakSelf parentViewController] dismissViewControllerAnimated:YES completion:nil];
        }
    });
}

- (void)navigateTo:(NSURL*)url
{
    if ([url.scheme isEqualToString:@"file"]) {
        [self.webView loadFileURL:url allowingReadAccessToURL:url];
    } else {
        NSURLRequest* request = [NSURLRequest requestWithURL:url];
        [self.webView loadRequest:request];
    }
}

- (void)goBack:(id)sender
{
    [self.webView goBack];
}

- (void)goForward:(id)sender
{
    [self.webView goForward];
}

- (void)viewWillAppear:(BOOL)animated
{
    [self rePositionViews];

    [super viewWillAppear:animated];
}

- (void)viewDidLayoutSubviews
{
    [super viewDidLayoutSubviews];
    [self rePositionViews];
}

- (BOOL)isIOS26OrLater
{
    // Runtime check (doesn't require building with an iOS 26 SDK).
    NSOperatingSystemVersion v = [[NSProcessInfo processInfo] operatingSystemVersion];
    return v.majorVersion >= 26;
}

- (float) getStatusBarOffset {
    // Prefer safe-area insets on modern iOS to avoid double-counting
    // when UIKit already accounts for status bar / notch.
    if (@available(iOS 11.0, *)) {
        return (float) self.view.safeAreaInsets.top;
    }
    return (float) [[UIApplication sharedApplication] statusBarFrame].size.height;
}

- (void) rePositionViews {
    if (!self.webView) {
        return;
    }

    CGRect bounds = self.view.bounds;
    CGFloat topInset = [self getStatusBarOffset];
    CGFloat bottomInset = 0.0;
    if (@available(iOS 11.0, *)) {
        bottomInset = self.view.safeAreaInsets.bottom;
    }

    BOOL hideNavButtons = _browserOptions.hidenavigationbuttons;
    
    // For older iOS only: handle toolbar positioning
    if (![self isIOS26OrLater] && self.toolbar) {
        BOOL toolbarAtTop = (_browserOptions.toolbar) && ([_browserOptions.toolbarposition isEqualToString:kInAppBrowserToolbarBarPositionTop]);
        BOOL toolbarOverlay = toolbarAtTop && _browserOptions.toolbaroverlay;
        
        // Position toolbars relative to safe-area insets.
        if (toolbarAtTop) {
            if (toolbarOverlay) {
                // Cover the safe-area region so the bar looks like a native overlay.
                self.toolbar.frame = CGRectMake(0.0, 0.0, bounds.size.width, TOOLBAR_HEIGHT + topInset);
            } else {
                self.toolbar.frame = CGRectMake(0.0, topInset, bounds.size.width, TOOLBAR_HEIGHT);
            }
        }
    }

    if (!hideNavButtons && self.footer) {
        // For iOS 26, footer with 10px gap from bottom; for older iOS, above safe area
        CGFloat footerY = [self isIOS26OrLater] ?
            (bounds.size.height - TOOLBAR_HEIGHT - 20.0) :
            (bounds.size.height - TOOLBAR_HEIGHT - bottomInset);
        self.footer.frame = CGRectMake(0.0, footerY, bounds.size.width, TOOLBAR_HEIGHT);
    }

    if (!hideNavButtons && self.safeBottom) {
        // For iOS 26, no horizontal padding (matches footer)
        self.safeBottom.frame = CGRectMake(0.0, bounds.size.height - bottomInset, bounds.size.width, bottomInset);
    }

    // Compute web view frame (avoid statusBarFrame-based double offsets on newer iOS).
    CGFloat webY;
    CGFloat reservedBottom;
    
    if ([self isIOS26OrLater]) {
        // For iOS 26, webview takes full screen - footer and cancel button float over
        // Content respects safe area via additionalSafeAreaInsets set in viewDidLoad
        webY = 0.0;
        reservedBottom = 0.0; // Don't reserve space in frame
        
        // Don't update additionalSafeAreaInsets here to avoid layout feedback loop
        // It's set once in viewDidLoad
    } else {
        BOOL toolbarAtTop = (_browserOptions.toolbar) && ([_browserOptions.toolbarposition isEqualToString:kInAppBrowserToolbarBarPositionTop]);
        BOOL toolbarOverlay = toolbarAtTop && _browserOptions.toolbaroverlay;
        webY = toolbarOverlay ? 0.0 : (topInset + (toolbarAtTop ? TOOLBAR_HEIGHT : 0.0));
        reservedBottom = (!hideNavButtons ? (TOOLBAR_HEIGHT + bottomInset) : 0.0);
    }
    
    CGFloat webH = bounds.size.height - webY - reservedBottom;
    if (webH < 0) {
        webH = 0;
    }

    self.webView.frame = CGRectMake(0.0, webY, bounds.size.width, webH);
}

// Helper function to convert hex color string to UIColor
// Assumes input like "#00FF00" (#RRGGBB).
// Taken from https://stackoverflow.com/questions/1560081/how-can-i-create-a-uicolor-from-a-hex-string
- (UIColor *)colorFromHexString:(NSString *)hexString {
    unsigned rgbValue = 0;
    NSScanner *scanner = [NSScanner scannerWithString:hexString];
    [scanner setScanLocation:1]; // bypass '#' character
    [scanner scanHexInt:&rgbValue];
    return [UIColor colorWithRed:((rgbValue & 0xFF0000) >> 16)/255.0 green:((rgbValue & 0xFF00) >> 8)/255.0 blue:(rgbValue & 0xFF)/255.0 alpha:1.0];
}

#pragma mark WKNavigationDelegate

- (void)webView:(WKWebView *)theWebView didStartProvisionalNavigation:(WKNavigation *)navigation{

    // loading url, start spinner, update back/forward

    self.addressLabel.text = NSLocalizedString(@"Loading...", nil);
    
    // For iOS 26, calculate dynamic width based on screen size with 4px inner padding
    if ([self isIOS26OrLater]) {
        CGFloat screenWidth = self.view.bounds.size.width;
        CGFloat customViewWidth = screenWidth - 168; // Total space minus buttons and spacing
        if (customViewWidth < 100) customViewWidth = 100;
        
        self.addressLabel.frame = CGRectMake(4, 0, customViewWidth - 8, 20); // 4px inner padding left/right
        self.addressButton.customView.frame = CGRectMake(0, 0, customViewWidth, 20);
    } else {
        NSUInteger length = [self.addressLabel.text length];
        self.addressLabel.frame = CGRectMake(25, 0, 111, 20);
        self.addressButton.customView.frame = CGRectMake(25, 0, 131, 20);
    }
    
    // Update button states (handle custom view buttons for iOS 26)
    if ([self isIOS26OrLater] && self.backButton.customView) {
        [(UIButton *)self.backButton.customView setEnabled:theWebView.canGoBack];
    } else {
        self.backButton.enabled = theWebView.canGoBack;
    }
    
    if ([self isIOS26OrLater] && self.forwardButton.customView) {
        [(UIButton *)self.forwardButton.customView setEnabled:theWebView.canGoForward];
    } else {
        self.forwardButton.enabled = theWebView.canGoForward;
    }

    if(!_browserOptions.hidespinner) {
        [self.spinner startAnimating];
    }

    return [self.navigationDelegate didStartProvisionalNavigation:theWebView];
}

- (void)webView:(WKWebView *)theWebView decidePolicyForNavigationAction:(WKNavigationAction *)navigationAction decisionHandler:(void (^)(WKNavigationActionPolicy))decisionHandler
{
    NSURL *url = navigationAction.request.URL;
    NSURL *mainDocumentURL = navigationAction.request.mainDocumentURL;

    BOOL isTopLevelNavigation = [url isEqual:mainDocumentURL];

    if (isTopLevelNavigation) {
        self.currentURL = url;
    }

    [self.navigationDelegate webView:theWebView decidePolicyForNavigationAction:navigationAction decisionHandler:decisionHandler];
}

- (void)webView:(WKWebView *)theWebView didFinishNavigation:(WKNavigation *)navigation
{
    // update url, stop spinner, update back/forward
    self.addressLabel.text = self.currentURL.host;
    
    // For iOS 26, calculate dynamic width based on screen size with 4px inner padding
    if ([self isIOS26OrLater]) {
        CGFloat screenWidth = self.view.bounds.size.width;
        CGFloat customViewWidth = screenWidth - 168; // Total space minus buttons and spacing
        if (customViewWidth < 100) customViewWidth = 100;
        
        self.addressLabel.frame = CGRectMake(4, 0, customViewWidth - 8, 20); // 4px inner padding left/right
        self.addressButton.customView.frame = CGRectMake(0, 0, customViewWidth, 20);
    } else {
        NSUInteger length = [self.addressLabel.text length];
        if (length > 20) {
            length = 20;
        }
        self.addressLabel.frame = CGRectMake(25, 0, length * 11, 20);
        self.addressButton.customView.frame = CGRectMake(25, 0, (length * 11) + 20, 20);
    }
    
    // Update button states (handle custom view buttons for iOS 26)
    if ([self isIOS26OrLater] && self.backButton.customView) {
        [(UIButton *)self.backButton.customView setEnabled:theWebView.canGoBack];
    } else {
        self.backButton.enabled = theWebView.canGoBack;
    }
    
    if ([self isIOS26OrLater] && self.forwardButton.customView) {
        [(UIButton *)self.forwardButton.customView setEnabled:theWebView.canGoForward];
    } else {
        self.forwardButton.enabled = theWebView.canGoForward;
    }
    
    // For iOS 26, maintain the bottom content inset; for older iOS, reset to zero
    if (![self isIOS26OrLater]) {
        theWebView.scrollView.contentInset = UIEdgeInsetsZero;
    }

    [self.spinner stopAnimating];

    [self.navigationDelegate didFinishNavigation:theWebView];
}

- (void)webView:(WKWebView*)theWebView failedNavigation:(NSString*) delegateName withError:(nonnull NSError *)error{
    // Update button states (handle custom view buttons for iOS 26)
    if ([self isIOS26OrLater] && self.backButton.customView) {
        [(UIButton *)self.backButton.customView setEnabled:theWebView.canGoBack];
    } else {
        self.backButton.enabled = theWebView.canGoBack;
    }
    
    if ([self isIOS26OrLater] && self.forwardButton.customView) {
        [(UIButton *)self.forwardButton.customView setEnabled:theWebView.canGoForward];
    } else {
        self.forwardButton.enabled = theWebView.canGoForward;
    }
    
    [self.spinner stopAnimating];

    self.addressLabel.text = NSLocalizedString(@"Load Error", nil);
    
    // For iOS 26, calculate dynamic width based on screen size with 4px inner padding
    if ([self isIOS26OrLater]) {
        CGFloat screenWidth = self.view.bounds.size.width;
        CGFloat customViewWidth = screenWidth - 168; // Total space minus buttons and spacing
        if (customViewWidth < 100) customViewWidth = 100;
        
        self.addressLabel.frame = CGRectMake(4, 0, customViewWidth - 8, 20); // 4px inner padding left/right
        self.addressButton.customView.frame = CGRectMake(0, 0, customViewWidth, 20);
    } else {
        self.addressLabel.frame = CGRectMake(25, 0, 111, 20);
        self.addressButton.customView.frame = CGRectMake(25, 0, 131, 20);
    }

    [self.navigationDelegate webView:theWebView didFailNavigation:error];
}

- (void)webView:(WKWebView*)theWebView didFailNavigation:(null_unspecified WKNavigation *)navigation withError:(nonnull NSError *)error
{
    [self webView:theWebView failedNavigation:@"didFailNavigation" withError:error];
}

- (void)webView:(WKWebView*)theWebView didFailProvisionalNavigation:(null_unspecified WKNavigation *)navigation withError:(nonnull NSError *)error
{
    [self webView:theWebView failedNavigation:@"didFailProvisionalNavigation" withError:error];
}

#pragma mark WKScriptMessageHandler delegate
- (void)userContentController:(nonnull WKUserContentController *)userContentController didReceiveScriptMessage:(nonnull WKScriptMessage *)message {
    if (![message.name isEqualToString:IAB_BRIDGE_NAME]) {
        return;
    }
    [self.navigationDelegate userContentController:userContentController didReceiveScriptMessage:message];
}

#pragma mark CDVScreenOrientationDelegate

- (BOOL)shouldAutorotate
{
    if ((self.orientationDelegate != nil) && [self.orientationDelegate respondsToSelector:@selector(shouldAutorotate)]) {
        return [self.orientationDelegate shouldAutorotate];
    }
    return YES;
}

- (UIInterfaceOrientationMask)supportedInterfaceOrientations
{
    if ((self.orientationDelegate != nil) && [self.orientationDelegate respondsToSelector:@selector(supportedInterfaceOrientations)]) {
        return [self.orientationDelegate supportedInterfaceOrientations];
    }

    return 1 << UIInterfaceOrientationPortrait;
}

- (void)viewWillTransitionToSize:(CGSize)size withTransitionCoordinator:(id<UIViewControllerTransitionCoordinator>)coordinator
{
    [coordinator animateAlongsideTransition:^(id<UIViewControllerTransitionCoordinatorContext> context)
    {
        [self rePositionViews];
    } completion:^(id<UIViewControllerTransitionCoordinatorContext> context)
    {

    }];

    [super viewWillTransitionToSize:size withTransitionCoordinator:coordinator];
}

#pragma mark UIAdaptivePresentationControllerDelegate

- (void)presentationControllerWillDismiss:(UIPresentationController *)presentationController {
    isExiting = TRUE;
}

@end //CDVWKInAppBrowserViewController
