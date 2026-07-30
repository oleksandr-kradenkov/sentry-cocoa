#if __has_include(<zlib.h>)
#    import <zlib.h>
#endif

#import <dlfcn.h>

#import "SentryError.h"
#import "SentryInternalDefines.h"
#import "SentryNSDataUtils.h"

NS_ASSUME_NONNULL_BEGIN

/// The deflate entry points this file needs, resolved at runtime.
typedef struct {
    int (*deflateInit2_)(z_streamp strm, int level, int method, int windowBits, int memLevel,
        int strategy, const char *version, int stream_size);
    int (*deflate)(z_streamp strm, int flush);
    int (*deflateEnd)(z_streamp strm);
} SentryDeflateFunctions;

/// Resolves deflate out of the system zlib (`/usr/lib/libz.1.dylib`) instead of relying on whatever
/// the host image happens to link.
///
/// Some hosts statically link their own — often very old — copy of zlib. A definition inside the
/// image always wins over a dylib import, so an unqualified `deflateInit2_` call binds to that copy
/// rather than to the system library. zlib only learned the gzip wrapper (`windowBits > 15`) in
/// 1.2.0.2; against an older copy `sentry_gzippedWithData:` fails with `Z_STREAM_ERROR` and every
/// envelope is dropped. Going through the system library keeps gzip working regardless of what else
/// the host links.
///
/// Falls back to the linked symbols if the system library cannot be resolved.
static SentryDeflateFunctions
sentry_deflateFunctions(void)
{
    static SentryDeflateFunctions functions;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        functions.deflateInit2_ = deflateInit2_;
        functions.deflate = deflate;
        functions.deflateEnd = deflateEnd;

        // Intentionally never closed: the handle is needed for the lifetime of the process.
        void *handle = dlopen("/usr/lib/libz.1.dylib", RTLD_LAZY);
        if (handle == NULL) {
            return;
        }

        // All three must resolve from the same library — mixing implementations would hand a
        // z_stream allocated by one zlib to another whose internal state layout differs.
        void *systemDeflateInit2 = dlsym(handle, "deflateInit2_");
        void *systemDeflate = dlsym(handle, "deflate");
        void *systemDeflateEnd = dlsym(handle, "deflateEnd");
        if (systemDeflateInit2 == NULL || systemDeflate == NULL || systemDeflateEnd == NULL) {
            return;
        }

        functions.deflateInit2_ = systemDeflateInit2;
        functions.deflate = systemDeflate;
        functions.deflateEnd = systemDeflateEnd;
    });
    return functions;
}

@implementation SentryNSDataUtils

+ (NSData *_Nullable)sentry_gzippedWithData:(NSData *)data
                           compressionLevel:(NSInteger)compressionLevel
                                      error:(NSError *_Nullable __autoreleasing *)error
{
    uInt length = (uInt)[data length];
    if (length == 0) {
        return [NSData data];
    }

    /// Init empty z_stream
    z_stream stream;
    stream.zalloc = Z_NULL;
    stream.zfree = Z_NULL;
    stream.opaque = Z_NULL;
    stream.next_in = (Bytef *)(void *)data.bytes;
    stream.total_out = 0;
    stream.avail_out = 0;
    stream.avail_in = length;

    int err;

    SentryDeflateFunctions zlib = sentry_deflateFunctions();

    // Equivalent to the deflateInit2 macro, but through the resolved function pointer.
    err = zlib.deflateInit2_(&stream, (int)compressionLevel, Z_DEFLATED, (16 + MAX_WBITS), 9,
        Z_DEFAULT_STRATEGY, ZLIB_VERSION, (int)sizeof(z_stream));
    if (err != Z_OK) {
        if (error) {
            // Parse the zlib error code and provide a descriptive error
            NSString *errorDescription = [NSString stringWithFormat:@"deflateInit2 error: %d", err];
            switch (err) {
            case Z_MEM_ERROR:
                errorDescription = @"deflateInit2 error: not enough memory";
                break;
            case Z_STREAM_ERROR:
                errorDescription = @"deflateInit2 error: invalid parameter";
                break;
            case Z_VERSION_ERROR:
                errorDescription = @"deflateInit2 error: zlib version mismatch";
                break;
            }

            *error = NSErrorFromSentryError(kSentryErrorCompressionError, errorDescription);
        }
        return nil;
    }

    NSMutableData *compressedData = [NSMutableData dataWithLength:(NSUInteger)(length * 1.02 + 50)];
    Bytef *compressedBytes = [compressedData mutableBytes];
    NSUInteger compressedLength = [compressedData length];

    /// compress
    while (err == Z_OK) {
        stream.next_out = compressedBytes + stream.total_out;
        stream.avail_out = (uInt)(compressedLength - stream.total_out);
        err = zlib.deflate(&stream, Z_FINISH);
    }

    [compressedData setLength:stream.total_out];

    zlib.deflateEnd(&stream);
    return compressedData;
}

@end

NSData *_Nullable sentry_nullTerminated(NSData *_Nullable data)
{
    if (data == nil) {
        return nil;
    }
    NSMutableData *mutable = [NSMutableData dataWithData:SENTRY_UNWRAP_NULLABLE(NSData, data)];
    [mutable appendBytes:"\0" length:1];
    return mutable;
}

NS_ASSUME_NONNULL_END
