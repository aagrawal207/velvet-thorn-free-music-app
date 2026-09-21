// SPDX-License-Identifier: LGPL-2.1-or-later

#include "FFmpegBridge.h"

#include <errno.h>
#include <fcntl.h>
#include <limits.h>
#include <pthread.h>
#include <stdarg.h>
#include <stdint.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>
#include <time.h>
#include <unistd.h>

#include <libavcodec/avcodec.h>
#include <libavformat/avformat.h>
#include <libavutil/error.h>
#include <libavutil/intreadwrite.h>
#include <libavutil/mem.h>

#define GB_MAX_FILE_BYTES (INT64_C(64) * 1024 * 1024)
#define GB_MAX_PACKET_BYTES (64 * 1024)
#define GB_MAX_PACKETS 400000U
#define GB_MAX_SAMPLES (INT64_C(48000) * 7200)
#define GB_IO_BUFFER_BYTES (32 * 1024)
#define GB_DEADLINE_NS (INT64_C(30) * 1000000000)

typedef struct GBOperation {
    GBRemuxInterrupt interrupt;
    void *context;
    int64_t started_ns;
    int error;
    int ffmpeg_error;
} GBOperation;

typedef struct GBIO {
    GBOperation *operation;
    const uint8_t *data;
    int fd;
    int64_t position;
    int64_t size;
    int64_t transferred;
} GBIO;

typedef struct GBProgress {
    unsigned packets;
    unsigned initial_skip;
    int64_t samples;
    int64_t end_skip;
    int64_t last_dts;
} GBProgress;

static const AVRational gb_sample_time_base = {1, 48000};
static pthread_once_t gb_once = PTHREAD_ONCE_INIT;
static _Thread_local GBOperation *gb_current_operation;

static void gb_log(void *context, int level, const char *format, va_list args)
{
    (void)context;
    (void)format;
    (void)args;
    // A recovered demux/parser error must not become success, and messages may contain private data.
    if (level <= AV_LOG_ERROR && gb_current_operation)
        gb_current_operation->ffmpeg_error = AVERROR_INVALIDDATA;
}

static void gb_initialize(void)
{
    // These globals belong to the hidden, privately linked FFmpeg instance.
    av_log_set_callback(gb_log);
    av_log_set_level(AV_LOG_ERROR);
    av_max_alloc(32 * 1024 * 1024);
}

static int64_t gb_monotonic_ns(void)
{
    struct timespec now;
    if (clock_gettime(CLOCK_MONOTONIC, &now) < 0)
        return -1;
    return (int64_t)now.tv_sec * 1000000000 + now.tv_nsec;
}

static int gb_status(GBOperation *operation)
{
    int64_t now;
    if (operation->interrupt && operation->interrupt(operation->context))
        operation->error = AVERROR_EXIT;
    if (operation->error)
        return operation->error;
    now = gb_monotonic_ns();
    if (now < 0)
        operation->error = AVERROR(EIO);
    else if (now - operation->started_ns >= GB_DEADLINE_NS)
        operation->error = AVERROR(ETIMEDOUT);
    return operation->error ? operation->error : operation->ffmpeg_error;
}

static int gb_interrupted(void *opaque)
{
    return gb_status(opaque) < 0;
}

static int gb_fail_io(GBIO *io, int error)
{
    if (!io->operation->error)
        io->operation->error = error;
    return error;
}

static int gb_read_packet(void *opaque, uint8_t *buffer, int size)
{
    GBIO *io = opaque;
    int result = gb_status(io->operation);
    if (result < 0)
        return result;
    if (size <= 0)
        return gb_fail_io(io, AVERROR(EINVAL));
    if (io->position == io->size)
        return AVERROR_EOF;
    if (size > io->size - io->position)
        size = (int)(io->size - io->position);
    if (io->transferred + size > 4 * GB_MAX_FILE_BYTES)
        return gb_fail_io(io, AVERROR(EFBIG));
    memcpy(buffer, io->data + io->position, size);
    io->position += size;
    io->transferred += size;
    return size;
}

static int gb_write_packet(void *opaque, const uint8_t *buffer, int size)
{
    GBIO *io = opaque;
    int written = 0;
    int result = gb_status(io->operation);
    if (result < 0)
        return result;
    if (size <= 0 || io->position > GB_MAX_FILE_BYTES - size ||
        io->transferred > 2 * GB_MAX_FILE_BYTES - size)
        return gb_fail_io(io, AVERROR(EFBIG));
    while (written < size) {
        ssize_t count;
        if ((result = gb_status(io->operation)) < 0)
            return result;
        count = pwrite(io->fd, buffer + written, size - written, io->position);
        if (count < 0 && errno == EINTR)
            continue;
        if (count <= 0)
            return gb_fail_io(io, AVERROR(count < 0 ? errno : EIO));
        written += (int)count;
        io->position += count;
        io->transferred += count;
        io->size = FFMAX(io->size, io->position);
    }
    return written;
}

static int64_t gb_seek(void *opaque, int64_t offset, int whence)
{
    GBIO *io = opaque;
    int64_t base, limit = io->data ? io->size : GB_MAX_FILE_BYTES;
    int result = gb_status(io->operation);
    if (result < 0)
        return result;
    if (whence == AVSEEK_SIZE)
        return io->size;
    switch (whence & ~AVSEEK_FORCE) {
        case SEEK_SET: base = 0; break;
        case SEEK_CUR: base = io->position; break;
        case SEEK_END: base = io->size; break;
        default: return gb_fail_io(io, AVERROR(EINVAL));
    }
    if (offset < -base || offset > limit - base)
        return gb_fail_io(io, AVERROR(EINVAL));
    io->position = base + offset;
    return io->position;
}

static AVIOContext *gb_make_io(GBIO *io)
{
    uint8_t *buffer = av_malloc(GB_IO_BUFFER_BYTES);
    AVIOContext *context;
    if (!buffer)
        return NULL;
    context = avio_alloc_context(buffer, GB_IO_BUFFER_BYTES, !io->data, io,
                                 io->data ? gb_read_packet : NULL,
                                 io->data ? NULL : gb_write_packet, gb_seek);
    if (!context)
        av_free(buffer);
    return context;
}

static int gb_refuse_open(AVFormatContext *format, AVIOContext **io,
                          const char *url, int flags, AVDictionary **options)
{
    (void)format;
    (void)io;
    (void)url;
    (void)flags;
    (void)options;
    return AVERROR(EPERM);
}

static int gb_path_valid(const char *path)
{
    return path && path[0] == '/' && strnlen(path, PATH_MAX) < PATH_MAX;
}

static int gb_snapshot(GBOperation *operation, const char *path, uint8_t **data, int64_t *size)
{
    struct stat before, after;
    int fd, result = 0;
    int64_t position = 0;
    fd = open(path, O_RDONLY | O_CLOEXEC | O_NOFOLLOW | O_NONBLOCK);
    if (fd < 0)
        return AVERROR(errno);
    if (fstat(fd, &before) < 0) {
        result = AVERROR(errno);
        goto done;
    }
    if (!S_ISREG(before.st_mode) || before.st_size <= 0) {
        result = AVERROR_INVALIDDATA;
        goto done;
    }
    if (before.st_size > GB_MAX_FILE_BYTES) {
        result = AVERROR(EFBIG);
        goto done;
    }
    *size = before.st_size;
    *data = malloc((size_t)*size);
    if (!*data) {
        result = AVERROR(ENOMEM);
        goto done;
    }
    while (position < *size) {
        size_t wanted = (size_t)FFMIN(*size - position, GB_IO_BUFFER_BYTES);
        ssize_t count;
        if ((result = gb_status(operation)) < 0)
            goto done;
        count = pread(fd, *data + position, wanted, position);
        if (count < 0 && errno == EINTR)
            continue;
        if (count <= 0) {
            result = AVERROR(count < 0 ? errno : EIO);
            goto done;
        }
        position += count;
    }
    if (fstat(fd, &after) < 0) {
        result = AVERROR(errno);
        goto done;
    }
    if (before.st_size != after.st_size ||
        before.st_mtimespec.tv_sec != after.st_mtimespec.tv_sec ||
        before.st_mtimespec.tv_nsec != after.st_mtimespec.tv_nsec ||
        before.st_ctimespec.tv_sec != after.st_ctimespec.tv_sec ||
        before.st_ctimespec.tv_nsec != after.st_ctimespec.tv_nsec)
        result = AVERROR_INVALIDDATA;
done:
    if (close(fd) < 0 && result == 0)
        result = AVERROR(errno);
    return result;
}

static int gb_restricted_side_data(const AVPacketSideData *side_data, int count)
{
    for (int i = 0; i < count; i++) {
        enum AVPacketSideDataType type = side_data[i].type;
        if (type == AV_PKT_DATA_ENCRYPTION_INIT_INFO || type == AV_PKT_DATA_ENCRYPTION_INFO ||
            type == AV_PKT_DATA_NEW_EXTRADATA || type == AV_PKT_DATA_PARAM_CHANGE)
            return 1;
    }
    return 0;
}

static int gb_validate_stream(const AVFormatContext *input, const AVCodecParameters *original)
{
    if (input->nb_streams != 1 || input->nb_stream_groups)
        return AVERROR_INVALIDDATA;
    const AVStream *stream = input->streams[0];
    const AVCodecParameters *parameters = stream->codecpar;
    const uint8_t *head = parameters->extradata;
    if (parameters->codec_type != AVMEDIA_TYPE_AUDIO || parameters->codec_id != AV_CODEC_ID_OPUS ||
        parameters->sample_rate != 48000 || parameters->ch_layout.nb_channels < 1 ||
        parameters->ch_layout.nb_channels > 2 || !av_channel_layout_check(&parameters->ch_layout) ||
        !head || parameters->extradata_size != 19 || memcmp(head, "OpusHead", 8) ||
        head[8] != 1 || head[9] != parameters->ch_layout.nb_channels || head[18] != 0 ||
        parameters->initial_padding < 0 || parameters->initial_padding > 65535 ||
        parameters->trailing_padding < 0 || parameters->trailing_padding > 5760 ||
        parameters->seek_preroll < 0 || stream->time_base.num <= 0 || stream->time_base.den <= 0 ||
        av_dict_get(stream->metadata, "enc_key_id", NULL, 0) ||
        gb_restricted_side_data(parameters->coded_side_data, parameters->nb_coded_side_data))
        return AVERROR_INVALIDDATA;
    if (original && (memcmp(head, original->extradata, 19) ||
        parameters->ch_layout.nb_channels != original->ch_layout.nb_channels ||
        parameters->initial_padding != original->initial_padding ||
        parameters->trailing_padding != original->trailing_padding ||
        parameters->seek_preroll != original->seek_preroll))
        return AVERROR_INVALIDDATA;
    return 0;
}

static int gb_validate_packet(const AVStream *stream, const AVPacket *packet, GBProgress *progress)
{
    // Without probing or a GENPTS queue, the complete-frame parser describes the returned packet.
    const AVCodecParserContext *parser = av_stream_get_parser(stream);
    if (!packet->data || packet->size <= 0 || packet->size > GB_MAX_PACKET_BYTES ||
        packet->stream_index != 0 || (packet->flags & AV_PKT_FLAG_CORRUPT) ||
        packet->pts == AV_NOPTS_VALUE || packet->dts == AV_NOPTS_VALUE || packet->duration <= 0 ||
        (progress->packets && packet->dts <= progress->last_dts) ||
        gb_restricted_side_data(packet->side_data, packet->side_data_elems) ||
        !parser || !(parser->flags & PARSER_FLAG_COMPLETE_FRAMES) ||
        parser->duration <= 0 || parser->duration > 5760)
        return AVERROR_INVALIDDATA;
    int64_t pts = av_rescale_q(packet->pts, stream->time_base, gb_sample_time_base);
    int64_t dts = av_rescale_q(packet->dts, stream->time_base, gb_sample_time_base);
    int64_t duration = av_rescale_q(packet->duration, stream->time_base, gb_sample_time_base);
    if (dts < -2 * 48000 || pts < dts || pts > GB_MAX_SAMPLES + 2 * 48000 ||
        duration <= 0 || duration > 48000)
        return AVERROR_INVALIDDATA;

    size_t skip_size = 0;
    const uint8_t *skip = av_packet_get_side_data(packet, AV_PKT_DATA_SKIP_SAMPLES, &skip_size);
    if (skip) {
        if (skip_size < 10)
            return AVERROR_INVALIDDATA;
        unsigned start_skip = AV_RL32(skip), end_skip = AV_RL32(skip + 4);
        if (start_skip > 65535 || (start_skip && progress->packets) ||
            end_skip > (unsigned)parser->duration)
            return AVERROR_INVALIDDATA;
        progress->initial_skip = FFMAX(progress->initial_skip, start_skip);
        progress->end_skip += end_skip;
    }
    progress->samples += parser->duration;
    progress->last_dts = packet->dts;
    if (++progress->packets > GB_MAX_PACKETS || progress->samples > GB_MAX_SAMPLES + 65535)
        return AVERROR(EFBIG);
    return parser->duration;
}

int gb_remux_opus(const char *input_path, const char *output_path,
                  GBRemuxInterrupt interrupt, void *context)
{
    GBOperation operation = {.interrupt = interrupt, .context = context};
    GBIO source = {.operation = &operation, .fd = -1};
    GBIO destination = {.operation = &operation, .fd = -1};
    GBProgress progress = {0};
    AVFormatContext *input = NULL, *output = NULL;
    AVIOContext *input_io = NULL, *output_io = NULL;
    AVPacket *packet = NULL;
    AVDictionary *options = NULL;
    uint8_t *snapshot = NULL;
    int result, status;

    if (!gb_path_valid(input_path) || !gb_path_valid(output_path))
        return AVERROR(EINVAL);
    if (gb_current_operation)
        return AVERROR(EBUSY);
    result = pthread_once(&gb_once, gb_initialize);
    if (result)
        return AVERROR(result);
    operation.started_ns = gb_monotonic_ns();
    if (operation.started_ns < 0)
        return AVERROR(EIO);
    gb_current_operation = &operation;
    if ((result = gb_status(&operation)) < 0 ||
        (result = gb_snapshot(&operation, input_path, &snapshot, &source.size)) < 0)
        goto done;

    source.data = snapshot;
    input_io = gb_make_io(&source);
    input = avformat_alloc_context();
    packet = av_packet_alloc();
    if (!input_io || !input || !packet) {
        result = AVERROR(ENOMEM);
        goto done;
    }
    input->pb = input_io;
    // FFmpeg's header parser supplies laced-packet timestamps and Opus durations without decoding.
    input->flags = AVFMT_FLAG_CUSTOM_IO | AVFMT_FLAG_IGNIDX;
    input->error_recognition = AV_EF_CRCCHECK | AV_EF_BITSTREAM | AV_EF_BUFFER | AV_EF_EXPLODE;
    input->max_streams = 1;
    input->max_index_size = 128 * 1024;
    input->probesize = GB_IO_BUFFER_BYTES;
    input->interrupt_callback = (AVIOInterruptCB){gb_interrupted, &operation};
    input->io_open = gb_refuse_open;
    const AVInputFormat *demuxer = av_find_input_format("matroska");
    if (!demuxer) {
        result = AVERROR_DEMUXER_NOT_FOUND;
        goto done;
    }
    if ((result = avformat_open_input(&input, "", demuxer, NULL)) < 0 ||
        (result = gb_status(&operation)) < 0 ||
        (result = gb_validate_stream(input, NULL)) < 0)
        goto done;

    AVStream *input_stream = input->streams[0];
    AVRational input_time_base = input_stream->time_base;
    progress.initial_skip = FFMAX(input_stream->codecpar->initial_padding,
                                  AV_RL16(input_stream->codecpar->extradata + 10));
    if ((result = avformat_alloc_output_context2(&output, NULL, "mp4", NULL)) < 0)
        goto done;
    if (!output) {
        result = AVERROR(ENOMEM);
        goto done;
    }
    output->flags = AVFMT_FLAG_CUSTOM_IO | AVFMT_FLAG_BITEXACT;
    output->avoid_negative_ts = AVFMT_AVOID_NEG_TS_DISABLED;
    output->interrupt_callback = (AVIOInterruptCB){gb_interrupted, &operation};
    output->io_open = gb_refuse_open;
    AVStream *output_stream = avformat_new_stream(output, NULL);
    if (!output_stream) {
        result = AVERROR(ENOMEM);
        goto done;
    }
    if ((result = avcodec_parameters_copy(output_stream->codecpar, input_stream->codecpar)) < 0)
        goto done;
    output_stream->codecpar->codec_tag = 0;
    output_stream->time_base = input_time_base;
    if ((result = av_dict_set(&options, "use_editlist", "1", 0)) < 0 ||
        (result = av_dict_set(&options, "movie_timescale", "48000", 0)) < 0)
        goto done;
    destination.fd = open(output_path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0600);
    if (destination.fd < 0) {
        result = AVERROR(errno);
        goto done;
    }
    output_io = gb_make_io(&destination);
    if (!output_io) {
        result = AVERROR(ENOMEM);
        goto done;
    }
    output->pb = output_io;
    if ((result = avformat_write_header(output, &options)) < 0 ||
        (result = gb_status(&operation)) < 0)
        goto done;
    if (av_dict_count(options)) {
        result = AVERROR(EINVAL);
        goto done;
    }

    while (1) {
        if ((result = gb_status(&operation)) < 0)
            goto done;
        result = av_read_frame(input, packet);
        if ((status = gb_status(&operation)) < 0) {
            result = status;
            goto done;
        }
        if (result == AVERROR_EOF)
            break;
        if (result < 0 || (result = gb_validate_stream(input, output_stream->codecpar)) < 0)
            goto done;
        if (av_cmp_q(input_stream->time_base, input_time_base)) {
            result = AVERROR_INVALIDDATA;
            goto done;
        }
        result = gb_validate_packet(input_stream, packet, &progress);
        if (result < 0)
            goto done;
        // The MOV muxer needs coded frame_size to apply SKIP_SAMPLES tail trim, including variable durations.
        output_stream->codecpar->frame_size = result;
        av_packet_rescale_ts(packet, input_time_base, output_stream->time_base);
        packet->pos = -1;
        result = av_write_frame(output, packet);
        av_packet_unref(packet);
        if (result < 0 || (result = gb_status(&operation)) < 0)
            goto done;
        if (output_io->error < 0) {
            result = output_io->error;
            goto done;
        }
    }
    if (!progress.packets || progress.samples <= progress.initial_skip + progress.end_skip) {
        result = AVERROR_INVALIDDATA;
        goto done;
    }
    if (progress.samples - progress.initial_skip - progress.end_skip > GB_MAX_SAMPLES) {
        result = AVERROR(EFBIG);
        goto done;
    }
    if (input_io->error < 0 && input_io->error != AVERROR_EOF) {
        result = input_io->error;
        goto done;
    }
    if ((result = av_write_trailer(output)) < 0 || (result = gb_status(&operation)) < 0)
        goto done;
    avio_flush(output_io);
    if (output_io->error < 0) {
        result = output_io->error;
        goto done;
    }
    struct stat final_stat;
    if (fsync(destination.fd) < 0 || fstat(destination.fd, &final_stat) < 0) {
        result = AVERROR(errno);
        goto done;
    }
    if (!S_ISREG(final_stat.st_mode) || final_stat.st_size <= 0 ||
        final_stat.st_size != destination.size || final_stat.st_size > GB_MAX_FILE_BYTES) {
        result = AVERROR_INVALIDDATA;
        goto done;
    }
    result = gb_status(&operation);

done:
    av_dict_free(&options);
    av_packet_free(&packet);
    avformat_close_input(&input);
    avformat_free_context(output);
    if (input_io)
        av_freep(&input_io->buffer);
    avio_context_free(&input_io);
    if (output_io)
        av_freep(&output_io->buffer);
    avio_context_free(&output_io);
    if (destination.fd >= 0 && close(destination.fd) < 0 && result == 0)
        result = AVERROR(errno);
    free(snapshot);
    if ((status = gb_status(&operation)) < 0)
        result = status;
    gb_current_operation = NULL;
    return result;
}

const char *gb_ffmpeg_version(void)
{
    return av_version_info();
}
