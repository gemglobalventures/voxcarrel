#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

extern NSErrorDomain const CTBErrorDomain;

@interface CTBChapter : NSObject
@property (nonatomic, readonly) double startSeconds;
@property (nonatomic, readonly, copy) NSString *title;
- (instancetype)initWithStartSeconds:(double)startSeconds title:(NSString *)title;
@end

/// Everything read from one file. `items` keys are raw container names:
///  MP4: atom names ("©nam", "aART", "----:com.apple.iTunes:SERIES").
///  MP3: ID3v2 frame IDs ("TIT2"), "TXXX:<DESCRIPTION>" for user text frames, "COMM" for the
///       comment with an empty descriptor.
@interface CTBSnapshot : NSObject
@property (nonatomic, copy) NSDictionary<NSString *, NSArray<NSString *> *> *items;
@property (nonatomic, copy, nullable) NSData *coverData;
@property (nonatomic, copy, nullable) NSString *coverMIME;
@property (nonatomic) double durationSeconds;
@property (nonatomic) NSInteger bitrateKbps;
@property (nonatomic) NSInteger sampleRate;
@property (nonatomic) NSInteger channels;
/// MP4 only: QuickTime chapter track if present, else Nero `chpl`. MP3: ID3v2 CHAP frames.
@property (nonatomic, copy) NSArray<CTBChapter *> *chapters;
/// MP3 only: major version of the ID3v2 tag found (3 or 4), 0 if none.
@property (nonatomic) NSInteger id3v2MajorVersion;
@end

@interface CTBChanges : NSObject
/// Key -> values. An empty array removes the item/frame. Keys not mentioned are left untouched.
@property (nonatomic, copy) NSDictionary<NSString *, NSArray<NSString *> *> *setItems;
/// When YES the cover is replaced by `coverData` (nil removes it). When NO the cover is untouched.
@property (nonatomic) BOOL replaceCover;
@property (nonatomic, copy, nullable) NSData *coverData;
@property (nonatomic, copy, nullable) NSString *coverMIME; // "image/jpeg" or "image/png"
@end

@interface CTBTagFile : NSObject
+ (nullable CTBSnapshot *)readMP4AtPath:(NSString *)path error:(NSError **)error;
+ (BOOL)writeMP4AtPath:(NSString *)path changes:(CTBChanges *)changes error:(NSError **)error;
+ (nullable CTBSnapshot *)readMP3AtPath:(NSString *)path error:(NSError **)error;
+ (BOOL)writeMP3AtPath:(NSString *)path changes:(CTBChanges *)changes error:(NSError **)error;
/// Used by the spike only to build a chaptered fixture. `quickTime` NO writes a Nero `chpl` atom.
/// Tests only. Never call on a user's file: it changed audio length in testing.
+ (BOOL)setMP4Chapters:(NSArray<CTBChapter *> *)chapters quickTime:(BOOL)quickTime
                atPath:(NSString *)path error:(NSError **)error;
@end

NS_ASSUME_NONNULL_END
