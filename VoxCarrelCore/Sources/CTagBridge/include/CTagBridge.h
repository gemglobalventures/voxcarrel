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
///  MP3: ID3v2 frame IDs ("TIT2"), "TXXX:<DESCRIPTION>" for user text frames (description as
///       stored, any case), "COMM" for the comment with an empty descriptor.
@interface CTBSnapshot : NSObject
@property (nonatomic, copy) NSDictionary<NSString *, NSArray<NSString *> *> *items;
@property (nonatomic, copy, nullable) NSData *coverData;
/// The type as the file labels it, which is often wrong or oddly spelt ("image/jpg", "JPG", "").
/// Judge the type from `coverData` instead.
@property (nonatomic, copy, nullable) NSString *coverMIME;
/// MP3 only: the ID3v2 picture type of every APIC frame, in file order (3 is the front cover).
@property (nonatomic, copy) NSArray<NSNumber *> *pictureTypes;
/// 0 when the file has no audio stream TagLib can measure.
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
/// A "TXXX:<DESCRIPTION>" key replaces every user text frame whose description matches it
/// without regard to case.
@property (nonatomic, copy) NSDictionary<NSString *, NSArray<NSString *> *> *setItems;
/// When YES the cover is replaced by `coverData` (nil removes it). When NO the cover is untouched.
/// MP3: only front-cover pictures are replaced or removed, or, when the tag has no front cover,
/// its first picture (the one a read reports as the cover). Other picture types are kept.
@property (nonatomic) BOOL replaceCover;
@property (nonatomic, copy, nullable) NSData *coverData;
@property (nonatomic, copy, nullable) NSString *coverMIME; // "image/jpeg", "image/png", "image/gif" or "image/bmp"
@end

/// Every method reports failure through `error`; C++ and Objective-C exceptions raised inside
/// are caught and returned the same way (code 5) rather than ending the process.
/// Error codes: 1 not readable as the format, 2 read-only, 3 save failed, 4 bad frame ID,
/// 5 exception.
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

/// What the system's own media framework (AVFoundation) makes of a file: the players
/// that come with the Mac go by it. Independent of TagLib.
@interface CTBMediaProbe : NSObject
/// How long the file plays, in seconds, with precise timing asked for. A negative number
/// when the file cannot be opened as media or its length is not known.
/// Blocks while the file is examined: never call it on the main thread.
+ (double)preciseDurationAtPath:(NSString *)path;
@end

NS_ASSUME_NONNULL_END
