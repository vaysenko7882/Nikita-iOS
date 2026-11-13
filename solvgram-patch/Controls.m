#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <objc/runtime.h>
#import <mach-o/dyld.h>
#import <dlfcn.h>
#import "SGRequestLogic.h"
#import "SessionShim.h"
#import "PreviewCallbacks.h"

extern char *SGCatalogCopyJSON(const void *, int64_t);
extern void *SGPreviewCreateContext(int64_t, uint64_t);
extern void SGPreviewReleaseContext(void *);
typedef struct { void *object; void *witness; } SGDisposable;
extern SGDisposable SGNativeStart(void *, void *, void *, void *, void *);
extern void SGNativeDispose(void *, void *);
extern void SGNativePreviewNext(void);
extern void SGNativePreviewCompleted(void);

static uintptr_t SGCoreBase;
static uintptr_t SGSignalBase;
static NSMutableDictionary<NSNumber *, id> *SGPreviews;
static NSMutableDictionary<NSString *, NSDictionary *> *SGCatalogs;
static uint64_t SGPreviewIdentifier;
static void (*SGSwiftRelease)(void *);
static void *(*SGSwiftRetain)(void *);
static void (*SGUnknownRelease)(void *);

@interface SGPreviewRequest : NSObject
@property uint64_t identifier;
@property(copy) void (^handler)(NSDictionary *);
@property SGDisposable disposable;
@property BOOL finished;
@end
@implementation SGPreviewRequest @end

static NSDictionary *SGReadCatalog(char *bytes) {
    if (!bytes) return nil;
    NSData *data = [NSData dataWithBytes:bytes length:strlen(bytes)];
    free(bytes);
    id parsed = [NSJSONSerialization JSONObjectWithData:data options:0 error:nil];
    return [parsed isKindOfClass:NSDictionary.class] ? parsed : nil;
}

void SGPreviewResult(uint64_t identifier, const char *json) {
    NSData *copy = json ? [NSData dataWithBytes:json length:strlen(json)] : nil;
    dispatch_async(dispatch_get_main_queue(), ^{
        SGPreviewRequest *state = SGPreviews[@(identifier)];
        if (!state || !state.handler) return;
        id parsed = copy ? [NSJSONSerialization JSONObjectWithData:copy options:0 error:nil] : nil;
        if ([parsed isKindOfClass:NSDictionary.class]) {
            NSDictionary *catalog = parsed;
            NSString *key = catalog[@"giftId"];
            if (key) SGCatalogs[key] = catalog;
            state.handler(catalog);
            state.handler = nil;
        }
    });
}

void SGPreviewFinished(uint64_t identifier) {
    dispatch_async(dispatch_get_main_queue(), ^{
        SGPreviewRequest *state = SGPreviews[@(identifier)];
        if (!state) return;
        state.finished = YES;
        if (state.handler) { state.handler(nil); state.handler = nil; }
        if (state.disposable.object && SGUnknownRelease) SGUnknownRelease(state.disposable.object);
        [SGPreviews removeObjectForKey:@(identifier)];
    });
}

static void SGFetchCatalog(int64_t giftID, void *account, void (^completion)(NSDictionary *)) {
    NSCAssert(NSThread.isMainThread, @"catalog UI queue");
    NSString *key = [NSString stringWithFormat:@"%lld", (long long)giftID];
    if (SGCatalogs[key]) { completion(SGCatalogs[key]); return; }
    if (!SGCoreBase || !SGSignalBase) { completion(nil); return; }
    void *cache = *(void **)(SGCoreBase + 0xe436f0);
    NSDictionary *cached = SGReadCatalog(SGCatalogCopyJSON(cache, giftID));
    if (cached) { SGCatalogs[key] = cached; completion(cached); return; }
    if (!account) { completion(nil); return; }
    // The original native send Signal retains this Account while its HTTP task
    // is deferred. Native preview fetching retains it for its own operation.
    void *(*fetch)(void *, int64_t) = (void *)(SGCoreBase + 0x72d018);
    void *signal = fetch(account, giftID);
    if (!signal) { completion(nil); return; }
    SGPreviewRequest *state = [SGPreviewRequest new];
    state.identifier = ++SGPreviewIdentifier;
    state.handler = completion;
    SGPreviews[@(state.identifier)] = state;
    void *context = SGPreviewCreateContext(giftID, state.identifier);
    state.disposable = SGNativeStart(signal, SGNativePreviewNext, SGNativePreviewCompleted,
                                    context, (void *)(SGSignalBase + 0x15294));
    SGPreviewReleaseContext(context);
    if (SGSwiftRelease) SGSwiftRelease(signal);
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 15 * NSEC_PER_SEC), dispatch_get_main_queue(), ^{
        if (!SGPreviews[@(state.identifier)]) return;
        [SGPreviews removeObjectForKey:@(state.identifier)];
        if (state.handler) { state.handler(nil); state.handler = nil; }
        if (state.disposable.object) {
            SGNativeDispose(state.disposable.object, state.disposable.witness);
            if (SGUnknownRelease) SGUnknownRelease(state.disposable.object);
            state.disposable = (SGDisposable){0};
        }
    });
}

static UIViewController *SGTopController(void) {
    UIWindow *selected = nil;
    for (UIScene *scene in UIApplication.sharedApplication.connectedScenes) {
        if (![scene isKindOfClass:UIWindowScene.class]) continue;
        for (UIWindow *window in ((UIWindowScene *)scene).windows) {
            if (window.isKeyWindow && window.rootViewController) { selected = window; break; }
            if (!selected && !window.hidden && window.rootViewController) selected = window;
        }
    }
    UIViewController *controller = selected.rootViewController;
    while (controller) {
        if (controller.presentedViewController && !controller.presentedViewController.isBeingDismissed) {
            controller = controller.presentedViewController;
        } else if ([controller isKindOfClass:UINavigationController.class]) {
            controller = ((UINavigationController *)controller).visibleViewController;
        } else if ([controller isKindOfClass:UITabBarController.class]) {
            controller = ((UITabBarController *)controller).selectedViewController;
        } else break;
    }
    return controller;
}

static void SGNotice(NSString *title, NSString *message) {
    UIViewController *top = SGTopController();
    if (!top) return;
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:title message:message preferredStyle:UIAlertControllerStyleAlert];
    [alert addAction:[UIAlertAction actionWithTitle:@"OK" style:UIAlertActionStyleDefault handler:nil]];
    [top presentViewController:alert animated:YES completion:nil];
}

@interface SGChoiceController : UITableViewController <UISearchResultsUpdating>
@property(copy) NSArray<NSDictionary *> *options;
@property(copy) NSArray<NSDictionary *> *filtered;
@property NSInteger selected;
@property(copy) void (^choose)(NSInteger);
@property UISearchController *search;
@end
@implementation SGChoiceController
- (void)viewDidLoad {
    [super viewDidLoad];
    self.search = [[UISearchController alloc] initWithSearchResultsController:nil];
    self.search.searchResultsUpdater = self;
    self.search.obscuresBackgroundDuringPresentation = NO;
    self.search.searchBar.placeholder = @"Поиск";
    self.navigationItem.searchController = self.search;
    self.navigationItem.hidesSearchBarWhenScrolling = NO;
    self.definesPresentationContext = YES;
    self.filtered = self.options;
}
- (void)updateSearchResultsForSearchController:(UISearchController *)controller {
    NSString *query = controller.searchBar.text ?: @"";
    self.filtered = query.length ? [self.options filteredArrayUsingPredicate:[NSPredicate predicateWithBlock:^BOOL(NSDictionary *option, NSDictionary *bindings) {
        return [option[@"name"] localizedCaseInsensitiveContainsString:query];
    }]] : self.options;
    [self.tableView reloadData];
}
- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section { return self.filtered.count + 1; }
- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)path {
    UITableViewCell *cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleDefault reuseIdentifier:nil];
    NSInteger index = path.row == 0 ? -1 : [self.filtered[path.row - 1][@"index"] integerValue];
    cell.textLabel.text = path.row == 0 ? @"Рандом" : self.filtered[path.row - 1][@"name"];
    cell.accessoryType = self.selected == index ? UITableViewCellAccessoryCheckmark : UITableViewCellAccessoryNone;
    if (path.row > 0 && self.filtered[path.row - 1][@"innerColor"]) {
        uint32_t rgb = [self.filtered[path.row - 1][@"innerColor"] unsignedIntValue];
        UIView *swatch = [[UIView alloc] initWithFrame:CGRectMake(0, 0, 26, 26)];
        swatch.backgroundColor = [UIColor colorWithRed:((rgb >> 16) & 255)/255.0 green:((rgb >> 8) & 255)/255.0 blue:(rgb & 255)/255.0 alpha:1];
        swatch.layer.cornerRadius = 13;
        cell.accessoryView = swatch;
        if (self.selected == index) cell.textLabel.text = [@"✓  " stringByAppendingString:cell.textLabel.text];
    }
    return cell;
}
- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)path {
    NSInteger index = path.row == 0 ? -1 : [self.filtered[path.row - 1][@"index"] integerValue];
    self.choose(index);
    [self.navigationController popViewControllerAnimated:YES];
}
@end

@class SGDeferredTask;
@interface SGSettingsController : UITableViewController <UITextFieldDelegate, UIAdaptivePresentationControllerDelegate>
@property(weak) SGDeferredTask *owner;
@property NSDictionary *catalog;
@property NSDictionary *body;
@property NSInteger quantity;
@property NSInteger model;
@property NSInteger backdrop;
@property BOOL loading;
@property UITextField *quantityField;
@end

typedef NSURLSessionDataTask *(^SGRawTaskFactory)(NSURLRequest *, void (^)(NSData *, NSURLResponse *, NSError *));
@interface SGDeferredTask : NSObject
@property(copy) NSURLRequest *originalRequest;
@property(copy) NSDictionary *body;
@property(copy) SGRawTaskFactory factory;
@property(copy) void (^completion)(NSData *, NSURLResponse *, NSError *);
@property BOOL resumed;
@property BOOL canceled;
@property BOOL finished;
@property BOOL begun;
@property BOOL captureValid;
@property void *nativeAccount;
@property NSInteger quantity;
@property NSInteger model;
@property NSInteger backdrop;
@property NSInteger started;
@property NSInteger succeeded;
@property NSInteger inFlight;
@property int64_t cost;
@property int64_t balanceAccount;
@property NSData *preparedBody;
@property NSData *firstData;
@property NSURLResponse *firstResponse;
@property NSError *lastError;
@property NSMutableSet<NSURLSessionDataTask *> *running;
@property UINavigationController *configuration;
@property UIAlertController *progress;
- (void)beginWithQuantity:(NSInteger)quantity model:(NSInteger)model backdrop:(NSInteger)backdrop;
- (void)cancel;
- (void)finish;
- (void)pump;
@end

static int64_t SGBalance(int64_t accountID) {
    if (!SGCoreBase) return 0;
    int64_t (*balance)(int64_t) = (void *)(SGCoreBase + 0x9420b8);
    return balance(accountID);
}
static void SGSetBalance(int64_t balance, int64_t accountID) {
    void (*set)(int64_t, int64_t) = (void *)(SGCoreBase + 0x9427ec);
    set(balance, accountID);
}

@implementation SGSettingsController
- (void)viewDidLoad {
    [super viewDidLoad];
    self.title = @"Фантомный подарок";
    self.navigationItem.leftBarButtonItem = [[UIBarButtonItem alloc] initWithTitle:@"Отмена" style:UIBarButtonItemStylePlain target:self action:@selector(cancelPressed)];
    self.navigationItem.rightBarButtonItem = [[UIBarButtonItem alloc] initWithTitle:@"Отправить" style:UIBarButtonItemStyleDone target:self action:@selector(sendPressed)];
    self.quantityField = [[UITextField alloc] initWithFrame:CGRectMake(0, 0, 80, 34)];
    self.quantityField.keyboardType = UIKeyboardTypeNumberPad;
    self.quantityField.textAlignment = NSTextAlignmentRight;
    self.quantityField.text = [NSString stringWithFormat:@"%ld", (long)self.quantity];
    self.quantityField.delegate = self;
    [self.quantityField addTarget:self action:@selector(quantityChanged) forControlEvents:UIControlEventEditingChanged];
    UIToolbar *toolbar = [[UIToolbar alloc] initWithFrame:CGRectMake(0, 0, 320, 44)];
    toolbar.items = @[[[UIBarButtonItem alloc] initWithBarButtonSystemItem:UIBarButtonSystemItemFlexibleSpace target:nil action:nil], [[UIBarButtonItem alloc] initWithTitle:@"Готово" style:UIBarButtonItemStyleDone target:self action:@selector(endEditing)]];
    self.quantityField.inputAccessoryView = toolbar;
    [self loadCatalog];
}
- (void)endEditing { [self.view endEditing:YES]; }
- (void)quantityChanged { self.quantity = self.quantityField.text.integerValue; }
- (void)loadCatalog {
    if (![self.body[@"upgrade"] boolValue]) { self.model = -1; self.backdrop = -1; return; }
    self.loading = YES;
    [self.tableView reloadData];
    __weak typeof(self) weak = self;
    SGFetchCatalog([self.body[@"gift"] longLongValue], self.owner.nativeAccount, ^(NSDictionary *catalog) {
        typeof(self) strong = weak;
        if (!strong || !strong.owner || strong.owner.finished) return;
        strong.loading = NO;
        strong.catalog = catalog;
        if (strong.model >= (NSInteger)[catalog[@"models"] count]) strong.model = -1;
        if (strong.backdrop >= (NSInteger)[catalog[@"backdrops"] count]) strong.backdrop = -1;
        [strong.tableView reloadData];
    });
}
- (void)cancelPressed { [self.owner cancel]; }
- (void)presentationControllerDidDismiss:(UIPresentationController *)presentationController { [self.owner cancel]; }
- (void)sendPressed {
    [self.view endEditing:YES];
    NSString *text = self.quantityField.text ?: @"";
    self.quantity = text.integerValue;
    if (!text.length || [text rangeOfCharacterFromSet:NSCharacterSet.decimalDigitCharacterSet.invertedSet].location != NSNotFound || self.quantity < 1 || self.quantity > 1000) {
        SGNotice(@"Количество подарков", @"Введите целое число от 1 до 1000."); return;
    }
    [self.owner beginWithQuantity:self.quantity model:self.model backdrop:self.backdrop];
}
- (NSInteger)numberOfSectionsInTableView:(UITableView *)tableView { return 3; }
- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section { return section == 0 ? 1 : (section == 1 ? 2 : 1); }
- (NSString *)tableView:(UITableView *)tableView titleForFooterInSection:(NSInteger)section {
    if (section == 0) return @"От 1 до 1000 за одно нажатие. Во время отправки отображается фактический прогресс.";
    if (section == 1) {
        if (![self.body[@"upgrade"] boolValue]) return @"Для выбора модели и фона включите улучшение подарка на предыдущем экране.";
        if (self.loading) return @"Загружаются варианты выбранного подарка…";
        if (!self.catalog) return @"Не удалось загрузить варианты. Нажмите «Загрузить варианты» или оставьте «Рандом».";
        return @"Модель и фон выбираются независимо. Выбранное оформление видно в этой версии Solvgram.";
    }
    return @"Используются встроенные фантомные подарки и звёзды Solvgram.";
}
- (NSString *)optionTitle:(NSString *)key index:(NSInteger)index {
    if (index < 0) return @"Рандом";
    for (NSDictionary *entry in self.catalog[key]) if ([entry[@"index"] integerValue] == index) return entry[@"name"];
    return @"Рандом";
}
- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)path {
    UITableViewCell *cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleValue1 reuseIdentifier:nil];
    if (path.section == 0) {
        cell.textLabel.text = @"Количество";
        cell.accessoryView = self.quantityField;
        cell.selectionStyle = UITableViewCellSelectionStyleNone;
    } else if (path.section == 1) {
        cell.textLabel.text = path.row == 0 ? @"Модель" : @"Фон";
        cell.detailTextLabel.text = [self optionTitle:path.row == 0 ? @"models" : @"backdrops" index:path.row == 0 ? self.model : self.backdrop];
        cell.accessoryType = UITableViewCellAccessoryDisclosureIndicator;
        BOOL enabled = [self.body[@"upgrade"] boolValue] && self.catalog && !self.loading;
        cell.userInteractionEnabled = enabled;
        cell.textLabel.enabled = enabled;
    } else {
        cell.textLabel.text = @"Загрузить варианты";
        cell.textLabel.textColor = self.view.tintColor;
        cell.userInteractionEnabled = !self.loading && [self.body[@"upgrade"] boolValue];
        cell.textLabel.enabled = cell.userInteractionEnabled;
        if (self.loading) {
            UIActivityIndicatorView *spinner = [[UIActivityIndicatorView alloc] initWithActivityIndicatorStyle:UIActivityIndicatorViewStyleMedium];
            [spinner startAnimating]; cell.accessoryView = spinner;
        }
    }
    return cell;
}
- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)path {
    [tableView deselectRowAtIndexPath:path animated:YES];
    if (path.section == 2) { [self loadCatalog]; return; }
    if (path.section != 1 || !self.catalog) return;
    SGChoiceController *choice = [[SGChoiceController alloc] initWithStyle:UITableViewStyleInsetGrouped];
    choice.title = path.row == 0 ? @"Модель" : @"Фон";
    choice.options = self.catalog[path.row == 0 ? @"models" : @"backdrops"];
    choice.selected = path.row == 0 ? self.model : self.backdrop;
    __weak typeof(self) weak = self;
    choice.choose = ^(NSInteger value) {
        if (path.row == 0) weak.model = value; else weak.backdrop = value;
        [weak.tableView reloadData];
    };
    [self.navigationController pushViewController:choice animated:YES];
}
@end

static NSMutableArray<SGDeferredTask *> *SGPending;
static SGDeferredTask *SGActive;
static void SGShowNext(void);

@implementation SGDeferredTask
- (void)dealloc {
    if (_nativeAccount && SGSwiftRelease) SGSwiftRelease(_nativeAccount);
}
- (NSURLRequest *)currentRequest { return self.originalRequest; }
- (NSURLSessionTaskState)state { return self.finished ? NSURLSessionTaskStateCompleted : (self.resumed ? NSURLSessionTaskStateRunning : NSURLSessionTaskStateSuspended); }
- (NSUInteger)taskIdentifier { return (NSUInteger)(__bridge void *)self; }
- (NSURLResponse *)response { return self.firstResponse; }
- (NSError *)error { return self.lastError; }
- (void)resume {
    @synchronized (self) { if (self.resumed || self.finished) return; self.resumed = YES; }
    dispatch_async(dispatch_get_main_queue(), ^{
        if (self.canceled) { [self finish]; return; }
        [SGPending addObject:self]; SGShowNext();
    });
}
- (void)suspend { }
- (void)cancel {
    dispatch_async(dispatch_get_main_queue(), ^{
        if (self.finished || self.canceled) return;
        self.canceled = YES;
        self.lastError = [NSError errorWithDomain:NSURLErrorDomain code:NSURLErrorCancelled userInfo:nil];
        for (NSURLSessionTask *task in self.running.copy) [task cancel];
        if (self.inFlight == 0) [self finish];
    });
}
- (void)beginWithQuantity:(NSInteger)quantity model:(NSInteger)model backdrop:(NSInteger)backdrop {
    if (self.begun || self.canceled || self.finished) return;
    if (![self.body[@"upgrade"] boolValue]) { model = -1; backdrop = -1; }
    NSError *error;
    NSData *body = SGPrepareSendBody(self.originalRequest.HTTPBody, model, backdrop, &error);
    if (!body) { SGNotice(@"Проверьте параметры", error.localizedDescription); return; }
    if (quantity > 1 && (!self.captureValid || self.cost < 0 || !self.balanceAccount)) {
        SGNotice(@"Не удалось подготовить пакет", @"Закройте это окно и выберите подарок заново."); return;
    }
    if (self.cost > 0 && (quantity - 1 > INT64_MAX / self.cost || SGBalance(self.balanceAccount) < (quantity - 1) * self.cost)) {
        SGNotice(@"Недостаточно фантомных звёзд", @"Пополните звёзды Solvgram или уменьшите количество подарков."); return;
    }
    self.begun = YES;
    self.configuration.topViewController.navigationItem.rightBarButtonItem.enabled = NO;
    self.quantity = quantity; self.model = model; self.backdrop = backdrop; self.preparedBody = body;
    NSString *key = [@"SGGiftControls.Options." stringByAppendingString:[self.body[@"gift"] description]];
    [NSUserDefaults.standardUserDefaults setObject:@{@"count":@(quantity), @"model":@(model), @"backdrop":@(backdrop)} forKey:key];
    [self.configuration dismissViewControllerAnimated:YES completion:^{
        self.configuration = nil;
        if (self.finished) return;
        if (self.canceled) { [self finish]; return; }
        self.progress = [UIAlertController alertControllerWithTitle:@"Отправка подарков" message:@"Отправлено 0" preferredStyle:UIAlertControllerStyleAlert];
        __weak typeof(self) weak = self;
        [self.progress addAction:[UIAlertAction actionWithTitle:@"Остановить" style:UIAlertActionStyleCancel handler:^(UIAlertAction *action) { [weak cancel]; }]];
        UIViewController *top = SGTopController();
        if (top && !top.isBeingPresented && !top.isBeingDismissed && ![top isKindOfClass:UIAlertController.class]) {
            [top presentViewController:self.progress animated:YES completion:^{ [self pump]; }];
        } else {
            self.progress = nil;
            [self pump];
        }
    }];
}
- (void)pump {
    if (self.finished) return;
    if ((self.canceled || self.lastError || self.started >= self.quantity) && self.inFlight == 0) { [self finish]; return; }
    if (self.canceled || self.lastError) return;
    // First request completes before parallel extras: native code receives that
    // one result even if later requests stop, so its original debit stays exact.
    NSInteger limit = self.succeeded == 0 ? 1 : 4;
    while (!self.canceled && !self.lastError && self.inFlight < limit && self.started < self.quantity) {
        BOOL extra = self.started > 0;
        if (extra && self.cost > 0) {
            int64_t balance = SGBalance(self.balanceAccount);
            if (balance < self.cost) {
                self.lastError = [NSError errorWithDomain:@"SolvgramGiftControls" code:2 userInfo:@{NSLocalizedDescriptionKey:@"Недостаточно фантомных звёзд."}];
                break;
            }
            SGSetBalance(balance - self.cost, self.balanceAccount);
        }
        self.started++; self.inFlight++;
        NSMutableURLRequest *request = self.originalRequest.mutableCopy;
        request.HTTPBody = self.preparedBody;
        [request setValue:[NSString stringWithFormat:@"%lu", (unsigned long)self.preparedBody.length] forHTTPHeaderField:@"Content-Length"];
        __block NSURLSessionDataTask *nativeTask;
        nativeTask = self.factory(request, ^(NSData *data, NSURLResponse *response, NSError *error) {
            dispatch_async(dispatch_get_main_queue(), ^{
                [self.running removeObject:nativeTask];
                nativeTask = nil;
                self.inFlight--;
                NSInteger status = [response isKindOfClass:NSHTTPURLResponse.class] ? ((NSHTTPURLResponse *)response).statusCode : 0;
                id json = data ? [NSJSONSerialization JSONObjectWithData:data options:0 error:nil] : nil;
                BOOL hasGift = [json isKindOfClass:NSDictionary.class] && ([json[@"gift"] isKindOfClass:NSDictionary.class] || (json[@"id"] && json[@"owner"]));
                BOOL success = !error && status >= 200 && status < 300 && hasGift;
                if (success) {
                    self.succeeded++;
                    NSDictionary *instance = [json[@"gift"] isKindOfClass:NSDictionary.class] ? json[@"gift"] : json;
                    if (instance[@"id"]) SGRememberGiftStyle([instance[@"id"] description], self.model, self.backdrop);
                    NSData *updated = SGRewriteGiftResponse(data, nil);
                    if (!self.firstData) { self.firstData = updated; self.firstResponse = response; }
                } else {
                    if (extra && self.cost > 0) {
                        int64_t balance = SGBalance(self.balanceAccount);
                        if (balance <= INT64_MAX - self.cost) SGSetBalance(balance + self.cost, self.balanceAccount);
                    }
                    self.lastError = error ?: [NSError errorWithDomain:@"SolvgramGiftControls" code:status ?: 3 userInfo:@{NSLocalizedDescriptionKey:[NSString stringWithFormat:@"Сервер остановил отправку (HTTP %ld).", (long)status]}];
                    if (!self.firstData) { self.firstData = data; self.firstResponse = response; }
                }
                self.progress.message = [NSString stringWithFormat:@"Отправлено %ld из %ld", (long)self.succeeded, (long)self.quantity];
                [self pump];
            });
        });
        if (!nativeTask) {
            self.inFlight--;
            if (extra && self.cost > 0) SGSetBalance(SGBalance(self.balanceAccount) + self.cost, self.balanceAccount);
            self.lastError = [NSError errorWithDomain:NSURLErrorDomain code:NSURLErrorUnknown userInfo:nil];
            break;
        }
        [self.running addObject:nativeTask];
        [nativeTask resume];
        if (self.succeeded == 0) break;
    }
    if (self.inFlight == 0 && self.lastError) [self finish];
}
- (void)finish {
    if (self.finished || self.inFlight > 0) return;
    self.finished = YES;
    [SGPending removeObject:self];
    UIViewController *modal = self.configuration ?: self.progress;
    void (^done)(void) = ^{
        self.configuration = nil; self.progress = nil;
        void (^callback)(NSData *, NSURLResponse *, NSError *) = self.completion;
        self.completion = nil;
        if (callback) callback(self.firstData, self.firstResponse, self.succeeded > 0 ? nil : self.lastError ?: [NSError errorWithDomain:NSURLErrorDomain code:NSURLErrorCancelled userInfo:nil]);
        if (SGActive == self) SGActive = nil;
        if (self.quantity > 0) {
            NSString *message = [NSString stringWithFormat:@"Отправлено %ld из %ld.%@", (long)self.succeeded, (long)self.quantity,
                                 self.succeeded == self.quantity ? @"" : [@"\n" stringByAppendingString:self.lastError.localizedDescription ?: @"Отправка остановлена."]];
            SGNotice(@"Фантомные подарки", message);
        }
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, NSEC_PER_SEC), dispatch_get_main_queue(), ^{ SGShowNext(); });
    };
    if (modal.presentingViewController) [modal dismissViewControllerAnimated:YES completion:done]; else done();
}
@end

static void SGShowNext(void) {
    if (SGActive || !SGPending.count) return;
    SGDeferredTask *task = SGPending.firstObject;
    [SGPending removeObjectAtIndex:0];
    if (task.finished) { SGShowNext(); return; }
    if (task.canceled) { [task finish]; return; }
    UIViewController *top = SGTopController();
    if (!top || top.isBeingPresented || [top isKindOfClass:UIAlertController.class]) {
        [SGPending insertObject:task atIndex:0];
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, NSEC_PER_SEC / 2), dispatch_get_main_queue(), ^{ SGShowNext(); }); return;
    }
    SGActive = task;
    SGSettingsController *controller = [[SGSettingsController alloc] initWithStyle:UITableViewStyleInsetGrouped];
    controller.owner = task; controller.body = task.body;
    NSDictionary *saved = [NSUserDefaults.standardUserDefaults dictionaryForKey:[@"SGGiftControls.Options." stringByAppendingString:[task.body[@"gift"] description]]];
    controller.quantity = MAX(1, MIN(1000, [saved[@"count"] integerValue] ?: 1));
    controller.model = saved[@"model"] ? MAX(-1, MIN(4095, [saved[@"model"] integerValue])) : -1;
    controller.backdrop = saved[@"backdrop"] ? MAX(-1, MIN(4095, [saved[@"backdrop"] integerValue])) : -1;
    task.configuration = [[UINavigationController alloc] initWithRootViewController:controller];
    task.configuration.modalInPresentation = YES;
    [top presentViewController:task.configuration animated:YES completion:nil];
    task.configuration.presentationController.delegate = controller;
}

id SGReviewGiftSend(NSURLSession *session, NSURLRequest *request, SGGiftSendCompletion completion) {
    SGDeferredTask *deferred = [SGDeferredTask new];
    deferred.originalRequest = request;
    deferred.body = SGParseRequest(request);
    deferred.factory = ^NSURLSessionDataTask *(NSURLRequest *input, void (^handler)(NSData *, NSURLResponse *, NSError *)) {
        return [session dataTaskWithRequest:input completionHandler:handler];
    };
    deferred.completion = completion;
    deferred.running = [NSMutableSet set];
    if (SGCoreBase) {
        uintptr_t *slots = (uintptr_t *)(SGCoreBase + 0xf06000);
        deferred.captureValid = slots[0] && SGSwiftRetain && SGSwiftRelease &&
            (int64_t)slots[1] == [deferred.body[@"gift"] longLongValue];
        if (deferred.captureValid) {
            deferred.nativeAccount = SGSwiftRetain((void *)slots[0]);
            deferred.cost = (int64_t)slots[2];
            deferred.balanceAccount = (int64_t)slots[3];
        }
    }
    [deferred resume];
    return deferred;
}

void SGCancelGiftSend(id operation) {
    if ([operation isKindOfClass:SGDeferredTask.class]) [(SGDeferredTask *)operation cancel];
}

static void SGInitialize(void) {
    SGPreviews = [NSMutableDictionary dictionary];
    SGCatalogs = [NSMutableDictionary dictionary];
    SGPending = [NSMutableArray array];
    for (uint32_t index = 0; index < _dyld_image_count(); ++index) {
        const char *name = _dyld_get_image_name(index);
        if (strstr(name, "/TelegramCoreFramework.framework/TelegramCoreFramework")) SGCoreBase = (uintptr_t)_dyld_get_image_header(index);
        if (strstr(name, "/SwiftSignalKitFramework.framework/SwiftSignalKitFramework")) SGSignalBase = (uintptr_t)_dyld_get_image_header(index);
    }
    SGSwiftRelease = dlsym(RTLD_DEFAULT, "swift_release");
    SGSwiftRetain = dlsym(RTLD_DEFAULT, "swift_retain");
    SGUnknownRelease = dlsym(RTLD_DEFAULT, "swift_unknownObjectRelease");

}

__attribute__((constructor)) static void SGLoad(void) {
    @autoreleasepool { SGInitialize(); }
}
