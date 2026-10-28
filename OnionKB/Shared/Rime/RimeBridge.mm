#import "RimeBridge.h"
#import "rime_api.h"

@implementation RimeCandidateObj
@end

@implementation RimeCompositionEvidence
@end

static RimeApi *Api(void) { return rime_get_api(); }

@implementation RimeBridge {
  RimeSessionId _session;
  BOOL _ready;
}

- (instancetype)initWithSharedDir:(NSString *)shared
                          userDir:(NSString *)user
                       prebuiltDir:(NSString *)prebuilt {
  if (self = [super init]) {
    [[NSFileManager defaultManager] createDirectoryAtPath:user
                              withIntermediateDirectories:YES
                                               attributes:nil error:nil];
    RimeApi *api = Api();
    RIME_STRUCT(RimeTraits, traits);
    traits.shared_data_dir   = strdup(shared.UTF8String);
    traits.user_data_dir     = strdup(user.UTF8String);
    traits.prebuilt_data_dir = strdup(prebuilt.UTF8String);
    traits.distribution_name      = "OnionKB";
    traits.distribution_code_name = "onionkb";
    traits.distribution_version   = "0.1";
    traits.app_name               = "rime.onionkb";
    traits.min_log_level          = 3;   // FATAL only（鍵盤擴充省日誌）
    api->setup(&traits);
    api->initialize(&traits);
    // 有 prebuilt → 通常不重編；若觸發部署則等其完成再開 session。
    if (api->start_maintenance(False)) {
      api->join_maintenance_thread();
    }
    _session = api->create_session();
    _ready = (_session != 0);
  }
  return self;
}

- (BOOL)isReady { return _ready; }

- (BOOL)processKey:(int)keycode {
  if (!_ready) return NO;
  return Api()->process_key(_session, keycode, 0) ? YES : NO;
}

- (nullable NSString *)takeCommit {
  if (!_ready) return nil;
  RIME_STRUCT(RimeCommit, commit);
  NSString *result = nil;
  if (Api()->get_commit(_session, &commit) && commit.text) {
    result = [NSString stringWithUTF8String:commit.text];
    Api()->free_commit(&commit);
  }
  return result;
}

- (NSString *)preedit {
  if (!_ready) return @"";
  RIME_STRUCT(RimeContext, ctx);
  NSString *p = @"";
  if (Api()->get_context(_session, &ctx)) {
    if (ctx.composition.preedit) p = [NSString stringWithUTF8String:ctx.composition.preedit];
    Api()->free_context(&ctx);
  }
  return p;
}

- (NSString *)rawInput {
  if (!_ready) return @"";
  const char *in = Api()->get_input(_session);
  return in ? [NSString stringWithUTF8String:in] : @"";
}

- (RimeCompositionEvidence *)compositionEvidence {
  RimeCompositionEvidence *e = [RimeCompositionEvidence new];
  e.rawInput = [self rawInput];
  e.preedit = @"";
  e.commitPreview = @"";
  e.selectionStart = 0;
  e.selectionEnd = 0;
  e.cursorPosition = 0;
  if (!_ready) return e;
  RIME_STRUCT(RimeContext, ctx);
  if (Api()->get_context(_session, &ctx)) {
    if (ctx.composition.preedit)
      e.preedit = [NSString stringWithUTF8String:ctx.composition.preedit];
    if (ctx.commit_text_preview)
      e.commitPreview = [NSString stringWithUTF8String:ctx.commit_text_preview];
    e.selectionStart = ctx.composition.sel_start;
    e.selectionEnd = ctx.composition.sel_end;
    e.cursorPosition = ctx.composition.cursor_pos;
    Api()->free_context(&ctx);
  }
  return e;
}

- (NSArray<RimeCandidateObj *> *)candidates {
  NSMutableArray<RimeCandidateObj *> *arr = [NSMutableArray array];
  if (!_ready) return arr;
  RIME_STRUCT(RimeContext, ctx);
  if (Api()->get_context(_session, &ctx)) {
    for (int i = 0; i < ctx.menu.num_candidates; i++) {
      RimeCandidateObj *c = [RimeCandidateObj new];
      const char *t = ctx.menu.candidates[i].text;
      const char *cm = ctx.menu.candidates[i].comment;
      c.text = t ? [NSString stringWithUTF8String:t] : @"";
      c.comment = cm ? [NSString stringWithUTF8String:cm] : nil;
      [arr addObject:c];
    }
    Api()->free_context(&ctx);
  }
  return arr;
}

- (BOOL)selectCandidate:(int)index {
  if (!_ready) return NO;
  return Api()->select_candidate_on_current_page(_session, (size_t)index);
}

- (NSArray<RimeCandidateObj *> *)allCandidates {
  NSMutableArray<RimeCandidateObj *> *arr = [NSMutableArray array];
  if (!_ready) return arr;
  RimeCandidateListIterator it;
  memset(&it, 0, sizeof(it));
  if (Api()->candidate_list_begin(_session, &it)) {
    while (Api()->candidate_list_next(&it)) {
      RimeCandidateObj *c = [RimeCandidateObj new];
      const char *t = it.candidate.text;
      const char *cm = it.candidate.comment;
      c.text = t ? [NSString stringWithUTF8String:t] : @"";
      c.comment = cm ? [NSString stringWithUTF8String:cm] : nil;
      [arr addObject:c];
      if (arr.count >= 200) break;            // 上限防爆（§89）
    }
    Api()->candidate_list_end(&it);
  }
  return arr;
}

- (BOOL)selectCandidateAbsolute:(int)index {
  if (!_ready) return NO;
  return Api()->select_candidate(_session, (size_t)index);
}

- (BOOL)syncUserData {
  if (!_ready) return NO;
  return Api()->sync_user_data() ? YES : NO;
}

- (void)clear {
  if (_ready) Api()->clear_composition(_session);
}

- (void)setOption:(NSString *)name value:(BOOL)value {
  if (_ready) Api()->set_option(_session, name.UTF8String, value ? True : False);
}

- (BOOL)getOption:(NSString *)name {
  if (!_ready) return NO;
  return Api()->get_option(_session, name.UTF8String) ? YES : NO;
}

+ (BOOL)deployWithSharedDir:(NSString *)shared
                    userDir:(NSString *)user
                prebuiltDir:(NSString *)prebuilt {
  [[NSFileManager defaultManager] createDirectoryAtPath:user
                            withIntermediateDirectories:YES attributes:nil error:nil];
  RimeApi *api = Api();
  RIME_STRUCT(RimeTraits, t);
  t.shared_data_dir   = strdup(shared.UTF8String);
  t.user_data_dir     = strdup(user.UTF8String);
  t.prebuilt_data_dir = strdup(prebuilt.UTF8String);
  t.distribution_name      = "OnionKB";
  t.distribution_code_name = "onionkb";
  t.distribution_version   = "0.1";
  t.app_name               = "rime.onionkb.deploy";
  t.min_log_level          = 2;
  api->setup(&t);
  api->deployer_initialize(&t);
  BOOL ok = api->deploy() ? YES : NO;   // 全量部署：編譯含自訂詞庫到 user/build
  api->finalize();
  return ok;
}

@end
