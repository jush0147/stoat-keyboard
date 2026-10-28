#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/// 單一候選（librime → Swift 的最小資料）。
@interface RimeCandidateObj : NSObject
@property (nonatomic, copy) NSString *text;
@property (nonatomic, copy, nullable) NSString *comment;
@end

/// librime C API 的 Objective-C++ 薄包裝（SPEC §15.3 RimeEngine 的真實作）。
/// 用 prebuilt_data_dir 指向 bundle 內預編譯 .bin（§5.8）→ 免裝置部署。
@interface RimeBridge : NSObject

/// shared＝源 schema/dict/default（bundle RimeData/shared）；
/// user＝可寫 userdb 目錄；prebuilt＝bundle RimeData/build（預編譯 .bin）。
- (instancetype)initWithSharedDir:(NSString *)shared
                          userDir:(NSString *)user
                       prebuiltDir:(NSString *)prebuilt;

- (BOOL)isReady;
- (BOOL)processKey:(int)keycode;          // ASCII / XK keycode
- (nullable NSString *)takeCommit;        // 有上字文字則回傳並清除
- (NSString *)preedit;                    // 組字串（librime 格式化，依候選變動）
- (NSString *)rawInput;                    // 原始輸入（大千鍵序，§32 #1 自繪 preedit 用）
- (NSArray<RimeCandidateObj *> *)candidates;
- (NSArray<RimeCandidateObj *> *)allCandidates;   // 全候選列舉（展開面板，§89；上限 200）
- (BOOL)selectCandidate:(int)index;       // 當前頁索引
- (BOOL)selectCandidateAbsolute:(int)index;       // 全列絕對索引（展開面板，§89）
/// Explicit user dictionary sync for cloud persistence experiments.
- (BOOL)syncUserData;
- (void)clear;

// schema 選項開關（ascii_mode / full_shape / ascii_punct / simplification 等，§24 #2）
- (void)setOption:(NSString *)name value:(BOOL)value;
- (BOOL)getOption:(NSString *)name;

/// 容器 App 用：部署（編譯自訂詞庫到 user/build）。SPEC §17.5。
/// 同步阻塞直到部署完成；回 YES 表成功。
+ (BOOL)deployWithSharedDir:(NSString *)shared
                    userDir:(NSString *)user
                prebuiltDir:(NSString *)prebuilt;

@end

NS_ASSUME_NONNULL_END
