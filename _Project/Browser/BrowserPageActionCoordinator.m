#import "BrowserPageActionCoordinator.h"

#import "BrowserDOMInteractionService.h"
#import "BrowserNavigationService.h"
#import "BrowserVideoPlaybackCoordinator.h"
#import "BrowserWebView.h"

@interface BrowserPageActionCoordinator ()

@property (nonatomic, weak) id<BrowserPageActionCoordinatorHost> host;
@property (nonatomic) BrowserDOMInteractionService *domInteractionService;
@property (nonatomic) BrowserNavigationService *navigationService;
@property (nonatomic) BrowserVideoPlaybackCoordinator *videoPlaybackCoordinator;
@property (nonatomic) UITextField *activeEditableField;

- (void)commitEditableText:(NSString *)text
                   atPoint:(CGPoint)point
                   webView:(BrowserWebView *)webView
                submitForm:(BOOL)submitForm;

@end

@implementation BrowserPageActionCoordinator

- (instancetype)initWithHost:(id<BrowserPageActionCoordinatorHost>)host
       domInteractionService:(BrowserDOMInteractionService *)domInteractionService
           navigationService:(BrowserNavigationService *)navigationService
    videoPlaybackCoordinator:(BrowserVideoPlaybackCoordinator *)videoPlaybackCoordinator {
    self = [super init];
    if (self) {
        _host = host;
        _domInteractionService = domInteractionService;
        _navigationService = navigationService;
        _videoPlaybackCoordinator = videoPlaybackCoordinator;
    }
    return self;
}

- (BOOL)handleTargetBlankLinkAtDOMPoint:(CGPoint)point webView:(BrowserWebView *)webView {
    NSDictionary *linkInfo = [self.domInteractionService linkInfoAtDOMPoint:point webView:webView];
    NSString *href = [linkInfo[@"href"] isKindOfClass:[NSString class]] ? linkInfo[@"href"] : @"";
    NSString *target = [linkInfo[@"target"] isKindOfClass:[NSString class]] ? linkInfo[@"target"] : @"";

    if (href.length == 0 || ![target isEqualToString:@"_blank"]) {
        return NO;
    }

    NSURLRequest *request = [self.navigationService requestForURLString:href];
    if (request == nil) {
        return NO;
    }

    return [self.host browserPageActionCoordinatorCreateNewTabWithRequest:request];
}

- (void)presentEditableFieldPromptForFieldType:(NSString *)fieldType
                                         point:(CGPoint)point
                                       webView:(BrowserWebView *)webView {
    NSString *fieldTitle = [self.domInteractionService evaluateEditableElementJavaScriptAtPoint:point
                                                                                         webView:webView
                                                                                            body:@"var target = browserEditableTarget();"
                                                                                                 "if (!target) { return ''; }"
                                                                                                 "return target.title || target.getAttribute('aria-label') || target.name || target.placeholder || '';"];
    if ([fieldTitle isEqualToString:@""]) {
        fieldTitle = fieldType;
    }
    NSString *placeholder = [self.domInteractionService evaluateEditableElementJavaScriptAtPoint:point
                                                                                          webView:webView
                                                                                             body:@"var target = browserEditableTarget();"
                                                                                                  "if (!target) { return ''; }"
                                                                                                  "return target.placeholder || target.getAttribute('aria-label') || '';"];
    if ([placeholder isEqualToString:@""]) {
        placeholder = [fieldTitle isEqualToString:fieldType] ? @"Text Input" : [NSString stringWithFormat:@"%@ Input", fieldTitle];
    }
    NSString *initialValue = [self.domInteractionService evaluateEditableElementJavaScriptAtPoint:point
                                                                                          webView:webView
                                                                                             body:@"var target = browserEditableTarget();"
                                                                                                  "if (!target) { return ''; }"
                                                                                                  "if (typeof target.value !== 'undefined') { return target.value; }"
                                                                                                  "return target.textContent || '';"];

    UIView *container = [self.host browserPageActionCoordinatorContainerView];
    if (container == nil) {
        return;
    }

    // Si quedo un campo previo, retirarlo antes de crear el nuevo.
    [self.activeEditableField removeFromSuperview];
    self.activeEditableField = nil;

    // Campo de texto invisible (fuera de pantalla): solo sirve para que tvOS
    // presente el teclado a pantalla completa. Asi no aparece ningun modal.
    UITextField *hiddenField = [[UITextField alloc] initWithFrame:CGRectMake(-2000.0, -2000.0, 320.0, 44.0)];
    if ([fieldType isEqualToString:@"url"]) {
        hiddenField.keyboardType = UIKeyboardTypeURL;
    } else if ([fieldType isEqualToString:@"email"]) {
        hiddenField.keyboardType = UIKeyboardTypeEmailAddress;
    } else if ([fieldType isEqualToString:@"tel"] ||
               [fieldType isEqualToString:@"number"] ||
               [fieldType isEqualToString:@"date"] ||
               [fieldType isEqualToString:@"datetime"] ||
               [fieldType isEqualToString:@"datetime-local"]) {
        hiddenField.keyboardType = UIKeyboardTypeNumbersAndPunctuation;
    } else {
        hiddenField.keyboardType = UIKeyboardTypeDefault;
    }
    NSString *displayPlaceholder = [placeholder capitalizedString];
    if (displayPlaceholder.length > 40) {
        displayPlaceholder = [[[displayPlaceholder substringToIndex:40] stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceCharacterSet]] stringByAppendingString:@"…"];
    }
    hiddenField.placeholder = displayPlaceholder;
    hiddenField.secureTextEntry = [fieldType isEqualToString:@"password"];
    hiddenField.text = initialValue;
    hiddenField.returnKeyType = UIReturnKeyDone;
    [container addSubview:hiddenField];
    self.activeEditableField = hiddenField;

    __weak typeof(self) weakSelf = self;
    // Al salir del teclado se escribe en la pagina y se retira el campo.
    if (@available(tvOS 14.0, *)) {
        [hiddenField addAction:[UIAction actionWithHandler:^(__unused UIAction *action) {
            typeof(self) strongSelf = weakSelf;
            UITextField *field = strongSelf.activeEditableField;
            if (field == nil) {
                return;
            }
            strongSelf.activeEditableField = nil;
            [strongSelf commitEditableText:field.text atPoint:point webView:webView submitForm:NO];
            [field removeFromSuperview];
        }] forControlEvents:UIControlEventEditingDidEnd];
    }

    // Abrir el teclado de inmediato (en el siguiente runloop).
    dispatch_async(dispatch_get_main_queue(), ^{
        [weakSelf.activeEditableField becomeFirstResponder];
    });
}

- (void)commitEditableText:(NSString *)text
                   atPoint:(CGPoint)point
                   webView:(BrowserWebView *)webView
                submitForm:(BOOL)submitForm {
    NSString *escapedText = [self.domInteractionService javaScriptEscapedString:text];
    NSString *submitClause = submitForm ? @"if (target.form) { target.form.submit(); }" : @"";
    [self.domInteractionService evaluateEditableElementJavaScriptAtPoint:point
                                                                 webView:webView
                                                                    body:[NSString stringWithFormat:@"var v = '%@';"
                                                                          "var target = browserEditableTarget();"
                                                                          "if (!target) { return 'false'; }"
                                                                          "if (typeof target.value !== 'undefined') {"
                                                                              "var proto = (window.HTMLTextAreaElement && target instanceof window.HTMLTextAreaElement) ? window.HTMLTextAreaElement.prototype : window.HTMLInputElement.prototype;"
                                                                              "var desc = Object.getOwnPropertyDescriptor(proto, 'value');"
                                                                              "if (desc && desc.set) { desc.set.call(target, v); } else { target.value = v; }"
                                                                          "} else { target.textContent = v; }"
                                                                          "if (target.dispatchEvent) {"
                                                                              "target.dispatchEvent(new Event('input', { bubbles: true }));"
                                                                              "target.dispatchEvent(new Event('change', { bubbles: true }));"
                                                                          "}"
                                                                          "%@"
                                                                          "return 'true';", escapedText, submitClause]];
}

- (void)handlePageSelectionAtDOMPoint:(CGPoint)point webView:(BrowserWebView *)webView {
    __weak BrowserWebView *weakWebView = webView;
    [self.videoPlaybackCoordinator handleSelectPressForVideoAtDOMPoint:point completion:^(BOOL handled) {
        BrowserWebView *strongWebView = weakWebView;
        if (handled || strongWebView == nil) {
            return;
        }
        [self handlePageClickAtDOMPoint:point webView:strongWebView];
    }];
}

- (void)handlePageClickAtDOMPoint:(CGPoint)point webView:(BrowserWebView *)webView {
    if ([self handleTargetBlankLinkAtDOMPoint:point webView:webView]) {
        return;
    }

    NSString *fieldType = [self.domInteractionService evaluateResolvedElementJavaScriptAtPoint:point
                                                                                        webView:webView
                                                                                           body:@"function browserEditableTargetAtPoint() {"
                                                                                                "var candidate = editableElement;"
                                                                                                "if (!candidate && resolvedElement && resolvedElement.matches) {"
                                                                                                    "if (resolvedElement.matches(editableSelector) || resolvedElement.matches('textarea, select')) {"
                                                                                                        "candidate = resolvedElement;"
                                                                                                    "}"
                                                                                                "}"
                                                                                                "if (!candidate) { return null; }"
                                                                                                "window.__browserLastEditableElement = candidate;"
                                                                                                "return candidate;"
                                                                                                "}"
                                                                                                "var target = browserEditableTargetAtPoint();"
                                                                                                "if (!target) { return ''; }"
                                                                                                "var tagName = target.tagName ? target.tagName.toLowerCase() : '';"
                                                                                                "var type = (target.type || '').toLowerCase();"
                                                                                                "if (tagName === 'textarea' || target.isContentEditable) { return 'text'; }"
                                                                                                "if (tagName === 'input' && !type) { return 'text'; }"
                                                                                                "return type;"];
    [self.domInteractionService dispatchResolvedElementJavaScriptAtPoint:point
                                                                 webView:webView
                                                                    body:@"var target = editableElement || resolvedElement || interactiveElement;"
                                                                         "if (!target) { return 'false'; }"
                                                                         "try { if (target.focus) { target.focus(); } } catch (error) {}"
                                                                         "function dispatchPointerLikeEvent(type, constructorName) {"
                                                                             "try {"
                                                                                 "var Constructor = window[constructorName];"
                                                                                 "if (Constructor) {"
                                                                                     "var event = new Constructor(type, { bubbles: true, cancelable: true, composed: true, view: window, clientX: x, clientY: y, screenX: x, screenY: y, button: 0, buttons: 1, pointerType: 'mouse' });"
                                                                                     "return target.dispatchEvent(event);"
                                                                                 "}"
                                                                             "} catch (error) {}"
                                                                             "var mouseEvent = document.createEvent('MouseEvents');"
                                                                             "mouseEvent.initMouseEvent(type, true, true, window, 1, x, y, x, y, false, false, false, false, 0, null);"
                                                                             "return target.dispatchEvent(mouseEvent);"
                                                                         "}"
                                                                         "dispatchPointerLikeEvent('pointerdown', 'PointerEvent');"
                                                                         "dispatchPointerLikeEvent('mousedown', 'MouseEvent');"
                                                                         "dispatchPointerLikeEvent('pointerup', 'PointerEvent');"
                                                                         "dispatchPointerLikeEvent('mouseup', 'MouseEvent');"
                                                                         "if (typeof target.click === 'function') { target.click(); }"
                                                                         "else { dispatchPointerLikeEvent('click', 'MouseEvent'); }"
                                                                         "return 'true';"];
    fieldType = fieldType.lowercaseString;
    if ([fieldType isEqualToString:@"date"] ||
        [fieldType isEqualToString:@"datetime"] ||
        [fieldType isEqualToString:@"datetime-local"] ||
        [fieldType isEqualToString:@"email"] ||
        [fieldType isEqualToString:@"month"] ||
        [fieldType isEqualToString:@"number"] ||
        [fieldType isEqualToString:@"password"] ||
        [fieldType isEqualToString:@"search"] ||
        [fieldType isEqualToString:@"tel"] ||
        [fieldType isEqualToString:@"text"] ||
        [fieldType isEqualToString:@"time"] ||
        [fieldType isEqualToString:@"url"] ||
        [fieldType isEqualToString:@"week"]) {
        [self presentEditableFieldPromptForFieldType:fieldType point:point webView:webView];
    }
}

@end
