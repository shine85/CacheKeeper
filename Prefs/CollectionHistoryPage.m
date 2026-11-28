#import "CollectionHistoryPage.h"
#import "../AxsCacheKeeperCollectionHistory.h"
#import "../AxsCacheKeeperCollectionSession.h"
@interface AxsCacheKeeperCollectionHistoryPage ()
@property(nonatomic,copy) NSString *directory;
@property(nonatomic,strong) AxsCacheKeeperCollectionHistory *history;
@property(nonatomic,copy) NSArray *records;
@property(nonatomic,copy) void (^selection)(AxsCacheKeeperCollectionSession *);
@property(nonatomic,copy) dispatch_block_t create;
@property(nonatomic,strong) dispatch_queue_t work;
@property(nonatomic) NSUInteger generation;
@property(nonatomic) BOOL busy;
@end
@implementation AxsCacheKeeperCollectionHistoryPage
- (instancetype)initWithDirectory:(NSString *)directory selection:(void (^)(AxsCacheKeeperCollectionSession *))selection create:(dispatch_block_t)create {
    if(!(self=[super initWithStyle:UITableViewStyleInsetGrouped]))return nil;_directory=[directory copy];_history=[[AxsCacheKeeperCollectionHistory alloc] initWithDirectory:directory];_selection=[selection copy];_create=[create copy];_work=dispatch_queue_create("dev.local.cachekeeper.collection.history",DISPATCH_QUEUE_SERIAL);return self;
}
- (void)viewDidLoad {
    [super viewDidLoad];self.title=@"采集会话";
    self.navigationItem.rightBarButtonItem=[[UIBarButtonItem alloc] initWithTitle:@"新建" style:UIBarButtonItemStylePlain target:self action:@selector(axs_new)];[self axs_reload];
}
- (void)axs_message:(NSString *)message {
    UIAlertController *alert=[UIAlertController alertControllerWithTitle:@"采集会话" message:message preferredStyle:UIAlertControllerStyleAlert];
    [alert addAction:[UIAlertAction actionWithTitle:@"好" style:UIAlertActionStyleCancel handler:nil]];[self presentViewController:alert animated:YES completion:nil];
}
- (void)axs_reload {
    self.busy=YES;self.navigationItem.rightBarButtonItem.enabled=NO;NSUInteger generation=++self.generation;__weak typeof(self) weak=self;AxsCacheKeeperCollectionHistory *history=self.history;
    dispatch_async(self.work,^{NSError *error=nil;NSArray *records=[history records:&error];dispatch_async(dispatch_get_main_queue(),^{
        typeof(self) page=weak;if(!page || page.generation!=generation)return;page.busy=NO;page.navigationItem.rightBarButtonItem.enabled=YES;page.records=records ?: @[];[page.tableView reloadData];
        UILabel *empty=[UILabel new];empty.text=error ? @"会话读取失败" : @"没有保存的采集会话";empty.textAlignment=NSTextAlignmentCenter;page.tableView.backgroundView=page.records.count ? nil : empty;
        if(error && page.view.window)[page axs_message:@"会话列表读取失败，原文件保持。"];
    });});
}
- (void)axs_new {dispatch_block_t action=self.create;[self.navigationController popViewControllerAnimated:NO];if(action)action();}
- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section {(void)tableView;(void)section;return self.records.count;}
- (NSString *)axs_title:(NSDictionary *)row {
    NSDateFormatter *format=[NSDateFormatter new];format.dateFormat=@"MM-dd HH:mm";
    NSString *date=[format stringFromDate:[NSDate dateWithTimeIntervalSince1970:[row[@"createdAt"] doubleValue]]];
    NSString *identifier=row[@"sessionID"] ?: @"未知会话";
    return [NSString stringWithFormat:@"%@ · %@",date,identifier.length>8 ? [identifier substringToIndex:8] : identifier];
}
- (NSString *)axs_state:(NSDictionary *)row {return @{@"idle":@"尚未开始",@"running":@"采集中",@"pending":@"等待响应",@"complete":@"已完成",@"partial":@"已有部分结果",@"interrupted":@"已中断",@"cancelled":@"已取消",@"failed":@"执行失败",@"blockedByCapability":@"缺少所需能力"}[row[@"state"]] ?: @"状态不可用";}
- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath {
    UITableViewCell *cell=[tableView dequeueReusableCellWithIdentifier:@"session"] ?: [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleSubtitle reuseIdentifier:@"session"];
    NSDictionary *row=self.records[indexPath.row];cell.textLabel.text=[self axs_title:row];cell.detailTextLabel.text=[self axs_state:row];cell.accessoryType=UITableViewCellAccessoryDisclosureIndicator;return cell;
}
- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath {
    [tableView deselectRowAtIndexPath:indexPath animated:YES];if(self.busy)return;NSDictionary *row=self.records[indexPath.row];
    NSString *file=row[@"file"];if(![file isEqual:file.lastPathComponent]){[self axs_message:@"会话记录无效，无法打开。"];return;}
    self.busy=YES;self.navigationItem.rightBarButtonItem.enabled=NO;NSString *path=[self.directory stringByAppendingPathComponent:file];__weak typeof(self) weak=self;
    dispatch_async(self.work,^{NSError *error=nil;AxsCacheKeeperCollectionSession *session=[AxsCacheKeeperCollectionSession openSessionAtPath:path error:&error];dispatch_async(dispatch_get_main_queue(),^{
        typeof(self) page=weak;if(!page)return;page.busy=NO;page.navigationItem.rightBarButtonItem.enabled=YES;
        if(!session || ![session.sessionID isEqual:row[@"sessionID"]]){[page axs_message:@"会话已变化或无法读取，请重新打开列表。"];return;}
        if(page.navigationController.topViewController!=page)return;void (^selection)(AxsCacheKeeperCollectionSession *)=page.selection;[page.navigationController popViewControllerAnimated:NO];if(selection)selection(session);
    });});
}
- (UISwipeActionsConfiguration *)tableView:(UITableView *)tableView trailingSwipeActionsConfigurationForRowAtIndexPath:(NSIndexPath *)indexPath {
    (void)tableView;if(self.busy)return nil;NSDictionary *row=self.records[indexPath.row];__weak typeof(self) weak=self;
    UIContextualAction *remove=[UIContextualAction contextualActionWithStyle:UIContextualActionStyleDestructive title:@"删除" handler:^(UIContextualAction *action,UIView *view,void (^completion)(BOOL)){
        (void)action;(void)view;completion(NO);typeof(self) page=weak;if(!page)return;
        if(![row[@"deletable"] boolValue]){[page axs_message:@"此会话正在采集或等待恢复确认，请先返回会话结束并确认恢复后再删除。"];return;}
        UIAlertController *confirm=[UIAlertController alertControllerWithTitle:@"删除此采集会话？" message:[NSString stringWithFormat:@"%@\n状态：%@\n只删除插件内的会话和图片阶段记录，已导出的报告不受影响。",[page axs_title:row],[page axs_state:row]] preferredStyle:UIAlertControllerStyleAlert];
        [confirm addAction:[UIAlertAction actionWithTitle:@"取消" style:UIAlertActionStyleCancel handler:nil]];
        [confirm addAction:[UIAlertAction actionWithTitle:@"删除" style:UIAlertActionStyleDestructive handler:^(UIAlertAction *answer){
            (void)answer;page.busy=YES;page.navigationItem.rightBarButtonItem.enabled=NO;
            dispatch_async(page.work,^{NSError *error=nil;NSDictionary *result=[page.history deleteRecord:row confirmed:YES error:&error];dispatch_async(dispatch_get_main_queue(),^{
                [page axs_reload];if(![result[@"state"] isEqual:@"deleted"] && page.view.window)[page axs_message:[result[@"state"] isEqual:@"partial"] ? @"部分记录未能删除，请刷新后重试；未把部分删除当作完成。" : @"会话状态已变化或无法删除，记录保留。"];
            });});
        }]];[page presentViewController:confirm animated:YES completion:nil];
    }];UISwipeActionsConfiguration *configuration=[UISwipeActionsConfiguration configurationWithActions:@[remove]];configuration.performsFirstActionWithFullSwipe=NO;return configuration;
}
@end
