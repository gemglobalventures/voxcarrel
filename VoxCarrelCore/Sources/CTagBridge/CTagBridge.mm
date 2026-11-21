#import "CTagBridge.h"

#include <taglib/attachedpictureframe.h>
#include <taglib/chapterframe.h>
#include <taglib/commentsframe.h>
#include <taglib/id3v2header.h>
#include <taglib/id3v2tag.h>
#include <taglib/mp4coverart.h>
#include <taglib/mp4file.h>
#include <taglib/mp4item.h>
#include <taglib/mp4properties.h>
#include <taglib/mp4tag.h>
#include <taglib/mpegfile.h>
#include <taglib/mpegproperties.h>
#include <taglib/textidentificationframe.h>
#include <taglib/tstringlist.h>

NSErrorDomain const CTBErrorDomain = @"CTagBridge";

using namespace TagLib;

static NSString *NS(const String &s) {
    return [NSString stringWithUTF8String:s.toCString(true)] ?: @"";
}
static String TL(NSString *s) { return String(s.UTF8String, String::UTF8); }
static NSArray<NSString *> *NSList(const StringList &l) {
    NSMutableArray *a = [NSMutableArray array];
    for (const auto &s : l) [a addObject:NS(s)];
    return a;
}
static StringList TLList(NSArray<NSString *> *a) {
    StringList l;
    for (NSString *s in a) l.append(TL(s));
    return l;
}
static NSData *NSDataFrom(const ByteVector &v) {
    return [NSData dataWithBytes:v.data() length:v.size()];
}
static ByteVector BV(NSData *d) {
    return ByteVector(static_cast<const char *>(d.bytes), static_cast<unsigned int>(d.length));
}
static BOOL Fail(NSError **error, NSInteger code, NSString *message) {
    if (error) *error = [NSError errorWithDomain:CTBErrorDomain code:code
                                        userInfo:@{NSLocalizedDescriptionKey: message}];
    return NO;
}

@implementation CTBChapter
- (instancetype)initWithStartSeconds:(double)startSeconds title:(NSString *)title {
    if ((self = [super init])) { _startSeconds = startSeconds; _title = [title copy]; }
    return self;
}
@end

@implementation CTBSnapshot
- (instancetype)init {
    if ((self = [super init])) { _items = @{}; _chapters = @[]; }
    return self;
}
@end

@implementation CTBChanges
- (instancetype)init {
    if ((self = [super init])) { _setItems = @{}; }
    return self;
}
@end

@implementation CTBTagFile

// MARK: MP4

+ (nullable CTBSnapshot *)readMP4AtPath:(NSString *)path error:(NSError **)error {
    MP4::File file(path.fileSystemRepresentation, true, AudioProperties::Average);
    if (!file.isValid() || !file.tag()) { Fail(error, 1, @"Not a readable MP4 file"); return nil; }

    CTBSnapshot *snap = [CTBSnapshot new];
    NSMutableDictionary *items = [NSMutableDictionary dictionary];
    for (const auto &[key, item] : file.tag()->itemMap()) {
        NSString *k = NS(key);
        switch (item.type()) {
        case MP4::Item::Type::StringList: items[k] = NSList(item.toStringList()); break;
        case MP4::Item::Type::Bool: items[k] = @[item.toBool() ? @"1" : @"0"]; break;
        case MP4::Item::Type::Int: items[k] = @[@(item.toInt()).stringValue]; break;
        case MP4::Item::Type::UInt: items[k] = @[@(item.toUInt()).stringValue]; break;
        case MP4::Item::Type::LongLong: items[k] = @[@(item.toLongLong()).stringValue]; break;
        case MP4::Item::Type::Byte: items[k] = @[@(item.toByte()).stringValue]; break;
        case MP4::Item::Type::IntPair: {
            auto p = item.toIntPair();
            items[k] = @[[NSString stringWithFormat:@"%d/%d", p.first, p.second]];
            break;
        }
        case MP4::Item::Type::CoverArtList: {
            auto covers = item.toCoverArtList();
            if (!covers.isEmpty() && !snap.coverData) {
                const auto &c = covers.front();
                snap.coverData = NSDataFrom(c.data());
                snap.coverMIME = c.format() == MP4::CoverArt::PNG ? @"image/png" : @"image/jpeg";
            }
            break;
        }
        default: break; // ByteVectorList, Stem, Void: not needed
        }
    }
    snap.items = items;

    if (auto *p = file.audioProperties()) {
        snap.durationSeconds = p->lengthInMilliseconds() / 1000.0;
        snap.bitrateKbps = p->bitrate();
        snap.sampleRate = p->sampleRate();
        snap.channels = p->channels();
    }

    MP4::ChapterList chapters = file.qtChapters();
    if (chapters.isEmpty()) chapters = file.neroChapters();
    NSMutableArray *out = [NSMutableArray array];
    for (const auto &c : chapters)
        [out addObject:[[CTBChapter alloc] initWithStartSeconds:c.startTime() / 1000.0 title:NS(c.title())]];
    snap.chapters = out;
    return snap;
}

+ (BOOL)writeMP4AtPath:(NSString *)path changes:(CTBChanges *)changes error:(NSError **)error {
    MP4::File file(path.fileSystemRepresentation, false);
    if (!file.isValid() || !file.tag()) return Fail(error, 1, @"Not a readable MP4 file");
    if (file.readOnly()) return Fail(error, 2, @"File is read-only");
    MP4::Tag *tag = file.tag();

    static NSSet *intKeys, *boolKeys, *byteKeys, *pairKeys;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        intKeys = [NSSet setWithObjects:@"©mvi", @"©mvc", @"tmpo", nil];
        boolKeys = [NSSet setWithObjects:@"shwm", @"pgap", @"cpil", @"pcst", nil];
        byteKeys = [NSSet setWithObjects:@"stik", @"rtng", nil];
        pairKeys = [NSSet setWithObjects:@"trkn", @"disk", nil];
    });

    for (NSString *key in changes.setItems) {
        NSArray<NSString *> *values = changes.setItems[key];
        String k = TL(key);
        if (values.count == 0) { tag->removeItem(k); continue; }
        NSString *first = values.firstObject;
        if ([intKeys containsObject:key]) tag->setItem(k, MP4::Item(first.intValue));
        else if ([boolKeys containsObject:key]) tag->setItem(k, MP4::Item(static_cast<bool>(first.boolValue)));
        else if ([byteKeys containsObject:key]) tag->setItem(k, MP4::Item(static_cast<unsigned char>(first.intValue)));
        else if ([pairKeys containsObject:key]) {
            NSArray<NSString *> *parts = [first componentsSeparatedByString:@"/"];
            tag->setItem(k, MP4::Item(parts[0].intValue, parts.count > 1 ? parts[1].intValue : 0));
        } else tag->setItem(k, MP4::Item(TLList(values)));
    }

    if (changes.replaceCover) {
        if (changes.coverData.length > 0) {
            auto format = [changes.coverMIME isEqualToString:@"image/png"] ? MP4::CoverArt::PNG : MP4::CoverArt::JPEG;
            MP4::CoverArtList covers;
            covers.append(MP4::CoverArt(format, BV(changes.coverData)));
            tag->setItem("covr", MP4::Item(covers));
        } else {
            tag->removeItem("covr");
        }
    }
    if (!file.save()) return Fail(error, 3, @"TagLib could not save the MP4 file");
    return YES;
}

+ (BOOL)setMP4Chapters:(NSArray<CTBChapter *> *)chapters quickTime:(BOOL)quickTime
                atPath:(NSString *)path error:(NSError **)error {
    MP4::File file(path.fileSystemRepresentation, false);
    if (!file.isValid()) return Fail(error, 1, @"Not a readable MP4 file");
    MP4::ChapterList list;
    for (CTBChapter *c in chapters)
        list.append(MP4::Chapter(TL(c.title), static_cast<long long>(c.startSeconds * 1000.0)));
    if (quickTime) file.setQtChapters(list); else file.setNeroChapters(list);
    if (!file.save()) return Fail(error, 3, @"TagLib could not save the MP4 file");
    return YES;
}

// MARK: MP3 (ID3v2)

+ (nullable CTBSnapshot *)readMP3AtPath:(NSString *)path error:(NSError **)error {
    MPEG::File file(path.fileSystemRepresentation, true, AudioProperties::Average);
    if (!file.isValid()) { Fail(error, 1, @"Not a readable MPEG audio file"); return nil; }

    CTBSnapshot *snap = [CTBSnapshot new];
    NSMutableDictionary *items = [NSMutableDictionary dictionary];
    NSMutableArray *chapters = [NSMutableArray array];
    if (file.hasID3v2Tag()) {
        ID3v2::Tag *tag = file.ID3v2Tag();
        snap.id3v2MajorVersion = tag->header()->majorVersion();
        NSData *anyCover = nil; NSString *anyMIME = nil;
        for (auto *frame : tag->frameList()) {
            if (auto *user = dynamic_cast<ID3v2::UserTextIdentificationFrame *>(frame)) {
                StringList fields = user->fieldList();
                if (!fields.isEmpty()) fields.erase(fields.begin()); // first field is the description
                items[[@"TXXX:" stringByAppendingString:NS(user->description())]] = NSList(fields);
            } else if (auto *text = dynamic_cast<ID3v2::TextIdentificationFrame *>(frame)) {
                items[NSDataFrom(text->frameID()).length == 4
                          ? [[NSString alloc] initWithData:NSDataFrom(text->frameID()) encoding:NSISOLatin1StringEncoding]
                          : @"?"] = NSList(text->fieldList());
            } else if (auto *comment = dynamic_cast<ID3v2::CommentsFrame *>(frame)) {
                if (comment->description().isEmpty() && !items[@"COMM"]) items[@"COMM"] = @[NS(comment->text())];
            } else if (auto *pic = dynamic_cast<ID3v2::AttachedPictureFrame *>(frame)) {
                if (pic->type() == ID3v2::AttachedPictureFrame::FrontCover && !snap.coverData) {
                    snap.coverData = NSDataFrom(pic->picture());
                    snap.coverMIME = NS(pic->mimeType());
                } else if (!anyCover) {
                    anyCover = NSDataFrom(pic->picture());
                    anyMIME = NS(pic->mimeType());
                }
            } else if (auto *chap = dynamic_cast<ID3v2::ChapterFrame *>(frame)) {
                String title;
                const auto &titles = chap->embeddedFrameList("TIT2");
                if (!titles.isEmpty()) title = titles.front()->toString();
                [chapters addObject:[[CTBChapter alloc] initWithStartSeconds:chap->startTime() / 1000.0 title:NS(title)]];
            }
        }
        if (!snap.coverData) { snap.coverData = anyCover; snap.coverMIME = anyMIME; }
    }
    snap.items = items;
    [chapters sortUsingComparator:^NSComparisonResult(CTBChapter *a, CTBChapter *b) {
        return [@(a.startSeconds) compare:@(b.startSeconds)];
    }];
    snap.chapters = chapters;
    if (auto *p = file.audioProperties()) {
        snap.durationSeconds = p->lengthInMilliseconds() / 1000.0;
        snap.bitrateKbps = p->bitrate();
        snap.sampleRate = p->sampleRate();
        snap.channels = p->channels();
    }
    return snap;
}

+ (BOOL)writeMP3AtPath:(NSString *)path changes:(CTBChanges *)changes error:(NSError **)error {
    MPEG::File file(path.fileSystemRepresentation, false);
    if (!file.isValid()) return Fail(error, 1, @"Not a readable MPEG audio file");
    if (file.readOnly()) return Fail(error, 2, @"File is read-only");

    // Keep an existing ID3v2.3 tag as 2.3; anything else is written as 2.4.
    BOOL hadV23 = file.hasID3v2Tag() && file.ID3v2Tag()->header()->majorVersion() == 3;
    ID3v2::Tag *tag = file.ID3v2Tag(true);

    for (NSString *key in changes.setItems) {
        NSArray<NSString *> *values = changes.setItems[key];
        if ([key hasPrefix:@"TXXX:"]) {
            String description = TL([key substringFromIndex:5]);
            while (auto *old = ID3v2::UserTextIdentificationFrame::find(tag, description)) tag->removeFrame(old);
            if (values.count > 0) {
                auto *frame = new ID3v2::UserTextIdentificationFrame(String::UTF8);
                frame->setDescription(description);
                frame->setText(TLList(values));
                tag->addFrame(frame);
            }
        } else if ([key isEqualToString:@"COMM"]) {
            ID3v2::FrameList comments = tag->frameList("COMM"); // copy: we mutate the tag below
            for (auto *f : comments) {
                auto *c = dynamic_cast<ID3v2::CommentsFrame *>(f);
                if (c && c->description().isEmpty()) tag->removeFrame(f);
            }
            if (values.count > 0) {
                auto *frame = new ID3v2::CommentsFrame(String::UTF8);
                frame->setLanguage("eng");
                frame->setText(TL(values.firstObject));
                tag->addFrame(frame);
            }
        } else {
            NSData *idData = [key dataUsingEncoding:NSISOLatin1StringEncoding];
            if (idData.length != 4) return Fail(error, 4, [@"Bad ID3v2 frame ID: " stringByAppendingString:key]);
            ByteVector frameID = BV(idData);
            tag->removeFrames(frameID);
            if (values.count > 0) {
                auto *frame = new ID3v2::TextIdentificationFrame(frameID, String::UTF8);
                frame->setText(TLList(values));
                tag->addFrame(frame);
            }
        }
    }

    if (changes.replaceCover) {
        tag->removeFrames("APIC");
        if (changes.coverData.length > 0) {
            auto *pic = new ID3v2::AttachedPictureFrame;
            pic->setType(ID3v2::AttachedPictureFrame::FrontCover);
            pic->setMimeType(TL(changes.coverMIME ?: @"image/jpeg"));
            pic->setPicture(BV(changes.coverData));
            tag->addFrame(pic);
        }
    }

    // StripNone: leave any ID3v1/APE tag in place rather than deleting user data.
    if (!file.save(MPEG::File::ID3v2, File::StripNone, hadV23 ? ID3v2::v3 : ID3v2::v4, File::DoNotDuplicate))
        return Fail(error, 3, @"TagLib could not save the MP3 file");
    return YES;
}

@end
