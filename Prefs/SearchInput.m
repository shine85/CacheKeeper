#import "SearchInput.h"
#import "SearchDiagnostics.h"
#include <math.h>

@interface AxsCacheKeeperSearchInput () <UITextFieldDelegate,UIGestureRecognizerDelegate>
@property(nonatomic,strong) UITextField *axs_cachekeeper_field;
@property(nonatomic,strong) UIButton *axs_cachekeeper_cancel_button;
@end

@implementation AxsCacheKeeperSearchInput
- (instancetype)initWithFrame:(CGRect)frame {
    if (!(self=[super initWithFrame:frame])) return nil;
    self.axs_cachekeeper_field=[UITextField new];
    self.axs_cachekeeper_field.delegate=self;
    self.axs_cachekeeper_field.placeholder=@"搜索应用";
    self.axs_cachekeeper_field.accessibilityLabel=@"搜索应用";
    self.axs_cachekeeper_field.accessibilityIdentifier=@"CacheKeeperAppSearch";
    self.axs_cachekeeper_field.borderStyle=UITextBorderStyleNone;
    self.axs_cachekeeper_field.backgroundColor=UIColor.tertiarySystemFillColor;
    self.axs_cachekeeper_field.layer.cornerRadius=10;
    UIView *leading=[[UIView alloc] initWithFrame:CGRectMake(0,0,36,44)];
    leading.userInteractionEnabled=NO;
    UIImageView *glass=[[UIImageView alloc] initWithImage:[UIImage systemImageNamed:@"magnifyingglass"]];
    glass.frame=CGRectMake(12,14,16,16);glass.contentMode=UIViewContentModeScaleAspectFit;
    glass.autoresizingMask=UIViewAutoresizingFlexibleTopMargin|UIViewAutoresizingFlexibleBottomMargin;
    glass.tintColor=UIColor.secondaryLabelColor;glass.isAccessibilityElement=NO;
    [leading addSubview:glass];
    self.axs_cachekeeper_field.leftView=leading;
    self.axs_cachekeeper_field.leftViewMode=UITextFieldViewModeAlways;
    self.axs_cachekeeper_field.font=[UIFont preferredFontForTextStyle:UIFontTextStyleBody];
    self.axs_cachekeeper_field.adjustsFontForContentSizeCategory=YES;
    self.axs_cachekeeper_field.clearButtonMode=UITextFieldViewModeWhileEditing;
    self.axs_cachekeeper_field.returnKeyType=UIReturnKeySearch;
    self.axs_cachekeeper_field.autocorrectionType=UITextAutocorrectionTypeNo;
    self.axs_cachekeeper_field.autocapitalizationType=UITextAutocapitalizationTypeNone;
    [self.axs_cachekeeper_field addTarget:self action:@selector(axs_cachekeeper_changed) forControlEvents:UIControlEventEditingChanged];
    self.axs_cachekeeper_cancel_button=[UIButton buttonWithType:UIButtonTypeSystem];
    [self.axs_cachekeeper_cancel_button setTitle:@"取消" forState:UIControlStateNormal];
    [self.axs_cachekeeper_cancel_button addTarget:self action:@selector(axs_cachekeeper_cancel) forControlEvents:UIControlEventTouchUpInside];
    self.axs_cachekeeper_cancel_button.hidden=YES;
    self.axs_cachekeeper_cancel_button.titleLabel.font=[UIFont preferredFontForTextStyle:UIFontTextStyleBody];
    self.axs_cachekeeper_cancel_button.titleLabel.adjustsFontForContentSizeCategory=YES;
    NSLayoutConstraint *cancelWidth=[self.axs_cachekeeper_cancel_button.widthAnchor constraintGreaterThanOrEqualToConstant:44];
    cancelWidth.priority=UILayoutPriorityDefaultHigh;cancelWidth.active=YES;
    [self.axs_cachekeeper_cancel_button setContentHuggingPriority:UILayoutPriorityRequired forAxis:UILayoutConstraintAxisHorizontal];
    [self.axs_cachekeeper_cancel_button setContentCompressionResistancePriority:UILayoutPriorityRequired forAxis:UILayoutConstraintAxisHorizontal];
    UIStackView *stack=[[UIStackView alloc] initWithArrangedSubviews:@[self.axs_cachekeeper_field,self.axs_cachekeeper_cancel_button]];
    stack.spacing=8;stack.alignment=UIStackViewAlignmentFill;stack.translatesAutoresizingMaskIntoConstraints=NO;
    [self addSubview:stack];
    [NSLayoutConstraint activateConstraints:@[
        [stack.leadingAnchor constraintEqualToAnchor:self.leadingAnchor constant:16],
        [stack.trailingAnchor constraintEqualToAnchor:self.trailingAnchor constant:-16],
        [stack.topAnchor constraintEqualToAnchor:self.topAnchor constant:6],
        [stack.bottomAnchor constraintEqualToAnchor:self.bottomAnchor constant:-6]]];
    // Padding/icon-area taps explicitly request the real text field; do not consume its touches.
    UITapGestureRecognizer *tap=[[UITapGestureRecognizer alloc] initWithTarget:self action:@selector(axs_cachekeeper_tapped)];
    tap.cancelsTouchesInView=NO;tap.delaysTouchesBegan=NO;tap.delegate=self;[self addGestureRecognizer:tap];
    return self;
}
- (CGSize)intrinsicContentSize {
    return CGSizeMake(UIViewNoIntrinsicMetric,MAX(44,ceil(self.axs_cachekeeper_field.font.lineHeight)+12)+12);
}
- (void)traitCollectionDidChange:(UITraitCollection *)previousTraitCollection {
    [super traitCollectionDidChange:previousTraitCollection];
    self.axs_cachekeeper_field.font=[UIFont preferredFontForTextStyle:UIFontTextStyleBody compatibleWithTraitCollection:self.traitCollection];
    [self invalidateIntrinsicContentSize];
}
- (NSString *)axs_cachekeeper_text { return self.axs_cachekeeper_field.text ?: @""; }
- (BOOL)axs_cachekeeper_focus {
    [self.axs_cachekeeper_diagnostics axs_cachekeeper_record:AxsCacheKeeperSearchEventFocus];
    if (!self.window) { [self.axs_cachekeeper_diagnostics axs_cachekeeper_record:AxsCacheKeeperSearchEventFocusNoWindow];return NO; }
    if (!self.userInteractionEnabled) { [self.axs_cachekeeper_diagnostics axs_cachekeeper_record:AxsCacheKeeperSearchEventFocusDisabled];return NO; }
    if (self.hidden) { [self.axs_cachekeeper_diagnostics axs_cachekeeper_record:AxsCacheKeeperSearchEventFocusHidden];return NO; }
    BOOL accepted=[self.axs_cachekeeper_field becomeFirstResponder];
    [self.axs_cachekeeper_diagnostics axs_cachekeeper_record:accepted ? AxsCacheKeeperSearchEventFocusAccepted : AxsCacheKeeperSearchEventFocusRejected];
    if (!accepted && self.axs_cachekeeper_focus_failed) self.axs_cachekeeper_focus_failed();
    return accepted;
}
- (void)axs_cachekeeper_dismiss_keyboard {
    [self.axs_cachekeeper_diagnostics axs_cachekeeper_record:AxsCacheKeeperSearchEventDismiss];
    [self.axs_cachekeeper_field resignFirstResponder];
}
- (void)axs_cachekeeper_tapped { [self axs_cachekeeper_focus]; }
- (BOOL)gestureRecognizer:(UIGestureRecognizer *)recognizer shouldReceiveTouch:(UITouch *)touch {
    (void)recognizer;
    return touch.view!=self.axs_cachekeeper_cancel_button && ![touch.view isDescendantOfView:self.axs_cachekeeper_cancel_button];
}
- (BOOL)textFieldShouldBeginEditing:(UITextField *)textField {
    if (textField==self.axs_cachekeeper_field) [self.axs_cachekeeper_diagnostics axs_cachekeeper_record:AxsCacheKeeperSearchEventShouldBegin];
    return textField==self.axs_cachekeeper_field;
}
- (void)textFieldDidBeginEditing:(UITextField *)textField {
    (void)textField;self.axs_cachekeeper_cancel_button.hidden=NO;
    [self.axs_cachekeeper_diagnostics axs_cachekeeper_record:AxsCacheKeeperSearchEventDidBegin];
}
- (void)textFieldDidEndEditing:(UITextField *)textField {
    (void)textField;self.axs_cachekeeper_cancel_button.hidden=YES;
    [self.axs_cachekeeper_diagnostics axs_cachekeeper_record:AxsCacheKeeperSearchEventDidEnd];
}
- (BOOL)textFieldShouldReturn:(UITextField *)textField { [textField resignFirstResponder];return YES; }
- (void)axs_cachekeeper_changed { if (self.axs_cachekeeper_changed_handler) self.axs_cachekeeper_changed_handler(); }
- (void)axs_cachekeeper_cancel {
    self.axs_cachekeeper_field.text=@"";[self axs_cachekeeper_dismiss_keyboard];[self axs_cachekeeper_changed];
}
@end
